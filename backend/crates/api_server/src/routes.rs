//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::http::{header, HeaderMap, StatusCode};
use axum::{
    extract::Path,
    response::IntoResponse,
    routing::{get, post, put},
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::sync::OnceLock;
use tower_http::trace::TraceLayer;

// 🔴 2026-10-06：`use crate::admin_handlers::*` 已删 —— 58 条 `/api/admin/*` 路由随
//    admin 链一并退役（见 `docs/review/backend-dead-route-cleanup-2026-10-06.md`）。
use crate::error::AppError;

/// 提供 Flutter Web 构建的静态文件（SPA 模式：未匹配路径返回 index.html）
const FLUTTER_WEB_DIR: &str = "../app/build/web";

async fn serve_flutter_web(Path(path): Path<String>) -> impl IntoResponse {
    let base = std::path::Path::new(FLUTTER_WEB_DIR);
    let file_path = if path.is_empty() || path == "index.html" || !path.contains('.') {
        // 无扩展名路径 → SPA fallback
        base.join("index.html")
    } else {
        let p = base.join(&path);
        if p.starts_with(base) && p.is_file() {
            p
        } else {
            base.join("index.html")
        }
    };

    // 尝试读取文件
    match tokio::fs::read(&file_path).await {
        Ok(data) => {
            let ext = file_path.extension().and_then(|e| e.to_str()).unwrap_or("");
            let mime = match ext {
                "html" => "text/html; charset=utf-8",
                "js" | "mjs" => "application/javascript",
                "css" => "text/css",
                "png" => "image/png",
                "jpg" | "jpeg" => "image/jpeg",
                "svg" => "image/svg+xml",
                "json" => "application/json",
                "wasm" => "application/wasm",
                "ico" => "image/x-icon",
                "map" => "application/json",
                _ => "application/octet-stream",
            };
            (StatusCode::OK, [(header::CONTENT_TYPE, mime)], data).into_response()
        }
        Err(_) if file_path.ends_with("index.html") => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
            b"<h1>App not built</h1><p>Run: cd app && flutter build web</p>" as &[u8],
        )
            .into_response(),
        Err(_) => {
            // 文件不存在 → SPA fallback
            match tokio::fs::read(base.join("index.html")).await {
                Ok(data) => (
                    StatusCode::OK,
                    [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
                    data,
                )
                    .into_response(),
                Err(_) => (StatusCode::NOT_FOUND, "App not built").into_response(),
            }
        }
    }
}

/// Helper: convert an AppError into a Json error response (for handlers returning Json<Value>)
pub(crate) fn auth_json(e: AppError) -> Json<serde_json::Value> {
    Json(serde_json::json!({"error": e.to_string()}))
}

/// Helper: run a DB query that returns Vec<T>, or return a Json error
fn query_vec<T, F>(
    conn: &rusqlite::Connection,
    sql: &str,
    params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<Vec<T>, Json<serde_json::Value>>
where
    F: Fn(&rusqlite::Row) -> rusqlite::Result<T>,
{
    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB prepare: {}", e)})))?;
    let rows: Vec<T> = stmt
        .query_map(params, map)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB query: {}", e)})))?
        .filter_map(|r| r.ok())
        .collect();
    Ok(rows)
}

/// Helper: run a query_row that returns a single value, or return a Json error
#[allow(dead_code)]
fn query_one<T, F>(
    conn: &rusqlite::Connection,
    sql: &str,
    params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<T, Json<serde_json::Value>>
where
    F: Fn(&rusqlite::Row) -> rusqlite::Result<T>,
{
    conn.query_row(sql, params, map)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB query: {}", e)})))
}

use chat_engine::llm_caller::LlmConfig;

pub fn build_router(llm_config: LlmConfig) -> Router {
    // 存储 LLM 配置供 routes 使用
    crate::llm::init(llm_config);

    Router::new()
        // ── Health ──
        .route("/health", get(health_check))
        // ── Public ──
        .route(
            "/api/public/qrcode",
            get(crate::public_assets::qrcode_handler),
        )
        // ── Payment & Subscription ──
        .route(
            "/api/pay/plans",
            get(crate::plans_handlers::plans_list_handler),
        )
        // 🔴 2026-10-04：Apple IAP 服务端验证
        //    替代了微信时代的 `/api/pay/native`（下单）+ `/api/pay/notify`（回调）两条端点 ——
        //    IAP 下服务端不参与下单，只做「端侧上报 → 主动查证 → 记账」这一条。
        //    ⚠️ 需要登录（`user_id` 必须与 token 对得上），见 `iap_handlers` 的模块文档。
        .route(
            "/api/iap/verify",
            post(crate::iap_handlers::iap_verify_handler),
        )
        .route(
            "/api/pay/orders",
            get(crate::pay_handlers::user_orders_handler),
        )
        .route(
            "/api/pay/orders/{id}",
            get(crate::pay_handlers::order_status_handler),
        )
        // ── Auth ──
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
        .route("/api/auth/verify", post(auth_verify))
        // 🆕 2026-10-05 修改密码（需登录 · 只认 token，不接受 body 里的 user_id）
        .route("/api/auth/change-password", post(auth_change_password))
        // 🆕 2026-10-05 找回密码「忘记密码」（**无需登录** · 邮件 6 位码）
        // 🔑 与上面那条是「账号维护功能」的两半：已登录的人走 change-password，
        //    进不来的人走这里。两条路径的旧会话处理**相反**（保留当前 vs 全删）。
        .route("/api/auth/forgot-password", post(auth_forgot_password))
        .route("/api/auth/reset-password", post(auth_reset_password))
        // 🆕 2026-10-07 修改邮箱（**需登录** · 两步：先发码到新邮箱，再用码换绑）
        // 🔑 为什么是两步而不是一条：换邮箱要证明的是「**新**邮箱属于你」
        //    ⇒ 那个证明只能在「收到新邮箱的信」之后成立 ⇒ 必须先发、后验。
        // 🔴 第 1 步除 token 外**还要当前密码** —— 见 `auth::issue_email_change_code`
        //    的文档（只验新邮箱 ⇒ 拿到已解锁设备者可换绑后用「忘记密码」接管账号）。
        .route("/api/auth/change-email/code", post(auth_change_email_code))
        .route("/api/auth/change-email", post(auth_change_email))
        // 🆕 2026-10-07 Sign in with Apple（**无需登录** · 带 Authorization 头则视为「绑定」）
        // 🔑 一个端点覆盖两种情况：
        //    · 无 token ⇒ 建号 / 登录（全新用户）
        //    · 有 token ⇒ 把 Apple 身份**绑到当前账号**（= 认领，学习记录不丢）
        .route("/api/auth/apple", post(auth_apple))
        // 🆕 2026-10-06 云端同步（订阅权益 · 白哥批准的决策③：**校验有效订阅**）
        //
        // 🔴 这是**唯一**需要「登录 + 订阅」双重要求的业务接口 ——
        //    其余接口要么不需登录（读信息流），要么只需登录（账号维护）。
        //    判据：**服务端也要能拒绝**（只靠端侧不显示入口 = 协议上不设防）。
        // ⚠️ 未订阅回 **403**（不是 401）—— 401 会让端侧以为 token 失效而**把用户登出**。
        // 📄 设计：`docs/design/sync-implementation-assessment-2026-10-04.md` §四
        .route("/api/sync/push", post(crate::sync_handlers::sync_push))
        .route("/api/sync/pull", get(crate::sync_handlers::sync_pull))
        // ── 🔴 2026-09-29 已退役：/api/review/* · /api/cards/* · /api/history · /api/conversations/* ──
        //     学习状态已整体迁到端侧 `user.db`（`card_review_state` / `review_log` / `user_word`）：
        //       · `/api/review/*` 与 `/api/cards/*` 原由后端 FSRS（crate `card_engine`）驱动
        //       · `/api/history` 与 `/api/conversations/*` 属对话链（依赖 `conversation_turns`）
        //     这些接口的唯一调用方是 app 的 `chat_client`，而 app 内 `/chat` **无 UI 入口**。
        //     → 相关表已从 `coevo.db` 删除；模块 `card_engine` / `review_handler` / `ws` 一并退役。
        // ── User Profile ──
        .route("/api/user/{user_id}/profile", get(profile_handler))
        // 🔴 2026-09-29 已退役：`PUT /api/user/{id}/profile`（更新 real_name / phone）——
        //    两列已删，handler `update_user_profile_handler` 同步移除。
        .route(
            "/api/user/{user_id}/display-name",
            post(update_display_name_handler),
        )
        .route(
            "/api/user/{user_id}/avatar",
            post(avatar_upload_handler).get(avatar_get_handler),
        )
        // 🔴 2026-09-29 已退役：/api/user/*/achievements-all · plan-achievements（表 achievements 已删；成就改为「端侧计算」）
        .route(
            "/api/user/{user_id}/preferences",
            get(preferences_get_handler).put(preferences_put_handler),
        )
        .route(
            "/api/user/{user_id}/subscription",
            get(user_subscription_handler),
        )
        // 🆕 账号注销（Apple 5.1.1(v)：支持注册的 App **必须**能 App 内注销）
        //
        // 🔑 路径用 `/api/user/me/delete` 而不是 `/api/user/{user_id}/delete`：
        //    后者会让「删谁」变成**客户端参数**。本接口只认 token 里的身份
        //    （见 `user_purge::resolve_uid_from_token`）⇒ 协议上无法指定他人。
        .route(
            "/api/user/me/delete",
            post(crate::user_purge::delete_me_handler),
        )
        .route("/api/stt/transcribe", post(stt_transcribe_handler))
        // ── 词库外生词兜底（LLM 在线制卡）──
        // 🔴 **不需登录** —— 产品原则「除生词表上限外不验证登录态」：
        //    读内容/划词/生成卡片都不得被登录态阻塞。
        .route("/api/generate-card", post(generate_card_handler))
        // 🆕 信息流（内容源 · 2026-09-29）—— 🔴 **不验证登录态**：
        //    读信息流/打开文章属「内容渲染」，不得被登录态阻塞（产品原则）
        .route("/api/feed", get(crate::content_handler::feed_list_handler))
        .route(
            "/api/feed/{id}",
            get(crate::content_handler::feed_detail_handler),
        )
        // 🔴 2026-09-29 已退役：`POST /api/user/bind-lookup`（凭姓名 + 手机号查用户）——
        //    依赖已删的 `real_name` / `phone` / `bind_hash`。
        // ── Learning Plans ──
        // 🔴 2026-09-29 已退役：/api/plans（依赖 plan_runs / user_plan_progress，表已删）
        // 🔴 2026-09-29 已退役：学习报表（learning-report / activity / weekly-report）
        //     与 WebSocket（/ws）—— 依赖已迁端侧的学习状态（user_cards / review_log / conversation_turns）
        // 🔴 2026-09-29 已退役：/ws（WebSocket chat —— app 内无 UI 入口）
        // ── 试用（trial）──  ⚠️ 去留待定，见 docs/review/backend-dead-route-cleanup-2026-10-06.md §4.2
        .route("/api/trial/start", post(crate::trial_handler::start))
        .route("/api/trial/claim", put(crate::trial_handler::claim))
        // ── 通知中心（用户通知 · 非营销推送）—— 数据源 user_notifications
        .route(
            "/api/notifications",
            get(crate::notification_handler::list_notifications),
        )
        .route(
            "/api/notifications/{id}/read",
            post(crate::notification_handler::mark_read),
        )
        .route(
            "/api/notifications/read-all",
            post(crate::notification_handler::mark_read_all),
        )
        // ── Flutter Web App 静态文件（SPA 路由） ──
        .route("/app/{*path}", get(serve_flutter_web))
        // ── 全局中间件：HTTP 请求/响应日志 ──
        .layer(TraceLayer::new_for_http())
}

// ════════════════════════════════════════════
// Handlers (stubs — will be filled in later)
// ════════════════════════════════════════════

/// GET /health — 服务器健康检查
/// 请求: 无
/// 响应: "CoEvo API — OK"
async fn health_check() -> &'static str {
    "CoEvo API — OK"
}

#[derive(Deserialize)]
pub struct AuthInput {
    /// 注册 / 登录标识 = **邮箱**（2026-09-29 起）。
    ///
    /// 🔴 此前是 `username` + `real_name?` + `phone?`（微信时代的实名 + 手机号）。
    ///    三个字段一起收敛为 `email` —— 白哥 2026-09-29：
    ///    「注册不要真实姓名和手机号，用邮箱注册+密码注册」。
    pub email: String,
    pub password: String,
    pub referral: Option<crate::auth::ReferralInfo>,
}

/// 修改密码的请求体（`POST /api/auth/change-password`）。
///
/// 🔑 刻意**不复用** `AuthInput`：那个带 `email` 与 `referral`，
///    语义不同（改密码不需要、也不该接受邮箱参数 —— 账号由 token 确定）。
///    判据：**复用结构体要看语义是否同一件事**，不是「字段长得像就共用」。
#[derive(Deserialize)]
pub struct ChangePasswordInput {
    pub old_password: String,
    pub new_password: String,
}

/// POST /api/auth/register — 注册新用户
/// 请求: {"email": "str", "password": "str", "referral?": {"code": "str"}}
/// 响应: {"user_id": "uuid", "token": "str", "email": "str"} 或 {"error": "str"}
/// 限流: 20 次/分钟/IP
///
/// # 两个注册入口的分工（2026-09-29 明确）
///
/// | 场景 | 走哪 | 为什么 |
/// |---|---|---|
/// | **未登录**（用户退出过登录 / 新设备） | **本接口** | 没有可认领的账号，直接新建 |
/// | **已登录的匿名试用账号**（想同步 / 付费） | `/api/trial/claim` | **认领**：保留该账号已有的学习记录 |
///
/// 🔑 这两条路**语义不同**，不能混用 —— 原先 `ClaimDialog` 不论是否已登录都调
///    `trial/claim`，于是未登录时会因 `userId` 为 null 而报一句英文机器话。
///    📄 详见 `docs/design/email-registration-2026-09-29.md` §4。
async fn auth_register(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!(
        "auth_register: email={}, referral={:?}",
        input.email,
        input.referral
    );

    // Rate limit: 20 reg/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 20, 60) {
        return resp;
    }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::register(
            &conn,
            &crate::auth::RegisterRequest {
                email: input.email,
                password: input.password,
                referral: input.referral,
            },
        )
    };
    match result {
        Ok(resp) => Json(serde_json::json!(resp)).into_response(),
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
    }
}

/// POST /api/auth/login — 用户登录
/// 请求: {"email": "str", "password": "str"}
/// 响应: {"user_id": "uuid", "token": "str", "email": "str"} 或 {"error": "str"}
/// 限流: 10 次/分钟/IP
async fn auth_login(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!("auth_login: email={}", input.email);

    // Rate limit: 10 login/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) {
        return resp;
    }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::login(
            &conn,
            &crate::auth::LoginRequest {
                email: input.email,
                password: input.password,
            },
        )
    };
    match result {
        Ok(resp) => {
            // 🔴 2026-09-29 已退役：踢同用户其他 WS 连接（WebSocket chat 已退役，无需再踢）
            Json(serde_json::json!(resp)).into_response()
        }
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
    }
}

/// POST /api/auth/change-password — **修改密码**（需登录）
///
/// 请求头: `Authorization: Bearer <token>`
/// 请求体: `{"old_password": "str", "new_password": "str"}`
/// 响应: `{"ok": true}` 或 `{"error": "str"}`
/// 限流: 10 次/分钟/IP（与 `login` 同档 —— 都要跑 bcrypt，是 CPU 敏感操作）
///
/// # 为什么它和「忘记密码」必须**两个都有**
///
/// 它们在「账号维护功能」清单里是并列项：
/// · 只有「忘记密码」⇒ 记得密码的人**改不了**（想换强密码也做不到）
/// · 只有「修改密码」⇒ 忘了密码的人**进不去**（没有出口）
///
/// # 🔴 鉴权只认 token（**不接受任何请求体里的 user_id**）
///
/// 与 `POST /api/user/me/delete` 同一条判据：**改谁的密码只能由 token 决定**。
/// 若允许 body 传 `user_id`，就等于开了一个「改别人密码」的口子。
/// （`ChangePasswordInput` 因此**只有** old/new 两个字段。）
async fn auth_change_password(
    headers: HeaderMap,
    Json(input): Json<ChangePasswordInput>,
) -> axum::response::Response {
    // Rate limit: 10 次/分钟/IP（bcrypt 开销大，且防「拿旧密码反复试」）
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) {
        return resp;
    }

    // ① 取当前 token（**唯一实现**在 `user_purge::extract_bearer_token`）
    let token = match crate::user_purge::extract_bearer_token(&headers) {
        Ok(t) => t,
        Err(e) => return auth_json(e).into_response(),
    };

    let result = {
        let conn = crate::db_pool::get_conn();
        // ② token → uid（**唯一实现**在 `auth::uid_by_token`）
        match crate::auth::uid_by_token(&conn, &token) {
            // ③ 改密码（内部：验原密码 → 更新 hash → 失效其他会话、保留当前）
            Ok(uid) => crate::auth::change_password(
                &conn,
                &uid,
                &token,
                &crate::auth::ChangePasswordRequest {
                    old_password: input.old_password,
                    new_password: input.new_password,
                },
            ),
            Err(e) => Err(e),
        }
    };

    match result {
        Ok(()) => {
            tracing::info!("auth_change_password: 修改成功");
            Json(serde_json::json!({"ok": true})).into_response()
        }
        Err(e) => {
            // ⚠️ **不打印密码**（即使是日志）—— 只记「失败」这件事。
            tracing::warn!("auth_change_password: 失败 —— {}", e);
            Json(serde_json::json!({"error": e})).into_response()
        }
    }
}

/// 「已发送」的统一文案。
///
/// 🔑 前端应原样显示这句，不要自己再写一遍（同一句话两处维护会漂移）。
///
/// 📌 2026-10-05 白哥定「**明说**」后，这句不再承担「含糊（防枚举）」的职责 ——
///    未注册邮箱走的是 `error` 分支（「该邮箱尚未注册」）。
///    保留统一文案的价值在于：**同一条消息只有一个出处**（改动时不会漏）。
const FORGOT_SENT_MSG: &str = "验证码已发送，请查收邮件";

/// 「忘记密码」第 1 步的请求体（`POST /api/auth/forgot-password`）。
#[derive(Deserialize)]
pub struct ForgotPasswordInput {
    pub email: String,
}

/// 「忘记密码」第 2 步的请求体（`POST /api/auth/reset-password`）。
///
/// 🔑 与 `ChangePasswordInput` **刻意不共用**（判据：复用结构体看语义是否同一件事）：
///    · `ChangePasswordInput` = 已登录 + **验原密码** + 保留当前会话
///    · 本结构 = 未登录 + **验邮箱码** + 删除全部会话
///    字段长得像（都有一个「新密码」），但它们是两套不同的凭据体系。
#[derive(Deserialize)]
pub struct ResetPasswordInput {
    pub email: String,
    pub code: String,
    pub new_password: String,
}

/// POST /api/auth/forgot-password — **忘记密码**第 1 步：发送验证码
///
/// 请求体: `{"email": "str"}`
/// 响应: `{"ok": true, "message": "若该邮箱已注册，验证码已发送"}` 或 `{"error": "str"}`
/// 限流: **5 次/分钟/IP**（比 login 更严 —— 每次都会**真发一封邮件**）
///
/// # 🔴 「邮箱未注册」**显式报错**（白哥 2026-10-05 定「明说」）
///
/// 这与 `login`（统一回「邮箱或密码错误」）**有意不同**，取舍写在
/// `auth::issue_reset_code` 的文档里：那边泄露的是「密码对不对」（威胁已有账号），
/// 这边只泄露「这个邮箱在本站注册过」（不涉凭据）；
/// 而含糊的代价是**打错一个字就要干等十分钟**（且用户会以为系统坏了）。
///
/// # ⚠️ 发信失败也必须如实报错
///
/// 若把失败吞掉当成功，用户会一直等一封永远不来的验证码
/// （「静默失效」—— 本项目的主要敌人）。⚠️ 但错误信息**不透技术细节**。
async fn auth_forgot_password(
    headers: HeaderMap,
    Json(input): Json<ForgotPasswordInput>,
) -> axum::response::Response {
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 5, 60) {
        return resp;
    }

    // ── ① 签发（同步 · 落库）──
    // 未注册邮箱、格式非法、60 秒内重复申请 —— 都在这里返回 `Err`，
    // 由下面统一转成 `{"error": ...}`（白哥定「明说」⇒ 未注册也走 error 分支）。
    let code = {
        let conn = crate::db_pool::get_conn();
        match crate::auth::issue_reset_code(&conn, &input.email) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("auth_forgot_password: 拒绝 —— {}", e);
                return Json(serde_json::json!({"error": e})).into_response();
            }
        }
    };

    // ── ② 发信（异步）──
    match crate::tencent_ses::send_verification_code(input.email.trim(), &code).await {
        Ok(()) => Json(serde_json::json!({"ok": true, "message": FORGOT_SENT_MSG})).into_response(),
        Err(e) => {
            // 内部细节只进日志（可能是「模板 ID 错」「余额不足」等，不该给终端用户看）
            tracing::error!("auth_forgot_password: 发信失败 —— {}", e);
            Json(serde_json::json!({"error": "验证码发送失败，请稍后再试"})).into_response()
        }
    }
}

/// POST /api/auth/reset-password — **忘记密码**第 2 步：用验证码重置密码
///
/// 请求体: `{"email": "str", "code": "str", "new_password": "str"}`
/// 响应: `{"user_id","token","message","email"}`（**与 login 同形 ⇒ 前端可直接自动登录**）
///        或 `{"error": "str"}`
/// 限流: 10 次/分钟/IP（与 `login` / `change-password` 同档 —— 都要跑 bcrypt）
///
/// # 🔴 无鉴权（不需要 token）
///
/// 这正是本接口存在的意义：**用户此刻登不进来**。
/// 凭据是「能收到该邮箱验证码」—— 即「确实拥有这个邮箱」。
async fn auth_reset_password(
    headers: HeaderMap,
    Json(input): Json<ResetPasswordInput>,
) -> axum::response::Response {
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) {
        return resp;
    }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::reset_password(&conn, &input.email, &input.code, &input.new_password)
    };

    match result {
        Ok(resp) => {
            tracing::info!("auth_reset_password: 重置成功并自动登录");
            Json(serde_json::json!(resp)).into_response()
        }
        Err(e) => {
            // ⚠️ **不打印密码/验证码**（即使是日志）—— 只记「失败」这件事。
            tracing::warn!("auth_reset_password: 失败 —— {}", e);
            Json(serde_json::json!({"error": e})).into_response()
        }
    }
}

// ── 修改邮箱（两步）──────────────────────────────────────────────────────
//
// 📄 设计依据（为什么需要「当前密码 + 新邮箱码」两道）→ `auth::issue_email_change_code`
// 📌 复用的是找回密码那条通道（`tencent_ses::send_verification_code`），
//    但**表、端点、限流档位各自独立** —— 见 `schema.rs` 的 `email_change` 注释。

/// 「修改邮箱」第 1 步的请求体（`POST /api/auth/change-email/code`）。
///
/// 🔑 与 `ForgotPasswordInput` **刻意不共用**：那个只需 `email`（未登录），
///    这里需要 `password`（已登录 + 证明是本人）+ 目标 `new_email`。
#[derive(Deserialize)]
pub struct ChangeEmailCodeInput {
    pub password: String,
    pub new_email: String,
}

/// 「修改邮箱」第 2 步的请求体（`POST /api/auth/change-email`）。
#[derive(Deserialize)]
pub struct ChangeEmailInput {
    pub new_email: String,
    pub code: String,
}

/// 「已发送」的统一文案（同 `FORGOT_SENT_MSG` 的做法：**同一条消息只有一个出处**）。
const EMAIL_CHANGE_SENT_MSG: &str = "验证码已发送至新邮箱，请查收";

/// POST /api/auth/change-email/code — 修改邮箱第 1 步：发验证码到**新邮箱**
///
/// 请求头: `Authorization: Bearer <token>`
/// 请求体: `{"password": "str", "new_email": "str"}`
/// 响应: `{"ok": true, "message": "验证码已发送至新邮箱，请查收"}` 或 `{"error": "str"}`
/// 限流: **5 次/分钟/IP**（与 forgot-password 同档 —— 每次都会**真发一封邮件**）
async fn auth_change_email_code(
    headers: HeaderMap,
    Json(input): Json<ChangeEmailCodeInput>,
) -> axum::response::Response {
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 5, 60) {
        return resp;
    }

    // ① 取当前 token（**唯一实现**在 `user_purge::extract_bearer_token`）
    let token = match crate::user_purge::extract_bearer_token(&headers) {
        Ok(t) => t,
        Err(e) => return auth_json(e).into_response(),
    };

    // ② 签发（同步 · 落库）
    let code = {
        let conn = crate::db_pool::get_conn();
        // token → uid（**唯一实现**在 `auth::uid_by_token`）
        let uid = match crate::auth::uid_by_token(&conn, &token) {
            Ok(u) => u,
            Err(e) => {
                tracing::warn!("auth_change_email_code: 鉴权失败 —— {}", e);
                return Json(serde_json::json!({"error": e})).into_response();
            }
        };
        match crate::auth::issue_email_change_code(&conn, &uid, &input.password, &input.new_email) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("auth_change_email_code: 拒绝 —— {}", e);
                return Json(serde_json::json!({"error": e})).into_response();
            }
        }
    };

    // ③ 发信（异步）—— 🔴 发到**新邮箱**（凭据就是「能收到那个邮箱的信」）
    match crate::tencent_ses::send_verification_code(input.new_email.trim(), &code).await {
        Ok(()) => {
            Json(serde_json::json!({"ok": true, "message": EMAIL_CHANGE_SENT_MSG})).into_response()
        }
        Err(e) => {
            // 内部细节只进日志（模板 ID 错 / 余额不足 等不该给终端用户看）
            tracing::error!("auth_change_email_code: 发信失败 —— {}", e);
            Json(serde_json::json!({"error": "验证码发送失败，请稍后再试"})).into_response()
        }
    }
}

/// POST /api/auth/change-email — 修改邮箱第 2 步：用验证码换绑
///
/// 请求头: `Authorization: Bearer <token>`
/// 请求体: `{"new_email": "str", "code": "str"}`
/// 响应: `{"ok": true, "email": "<新邮箱>"}` 或 `{"error": "str"}`
/// 限流: 10 次/分钟/IP（要跑 bcrypt，且防「对验证码反复试」）
///
/// ⚠️ **不改 token、不踢会话** —— 与改密码**有意不同**：
///    token 按 `user_id` 关联，换邮箱不影响任何会话的有效性；
///    而强行踢会话会让用户「改个邮箱就被登出」，收益为零。
async fn auth_change_email(
    headers: HeaderMap,
    Json(input): Json<ChangeEmailInput>,
) -> axum::response::Response {
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) {
        return resp;
    }

    let token = match crate::user_purge::extract_bearer_token(&headers) {
        Ok(t) => t,
        Err(e) => return auth_json(e).into_response(),
    };

    let result = {
        let conn = crate::db_pool::get_conn();
        match crate::auth::uid_by_token(&conn, &token) {
            Ok(uid) => crate::auth::change_email(&conn, &uid, &input.new_email, &input.code),
            Err(e) => Err(e),
        }
    };

    match result {
        Ok(new_email) => {
            tracing::info!("auth_change_email: 修改成功");
            Json(serde_json::json!({"ok": true, "email": new_email})).into_response()
        }
        Err(e) => {
            // ⚠️ **不打印验证码**（即使是日志）—— 只记「失败」这件事。
            tracing::warn!("auth_change_email: 失败 —— {}", e);
            Json(serde_json::json!({"error": e})).into_response()
        }
    }
}

// ── Sign in with Apple ────────────────────────────────────────────────────

/// Sign in with Apple 的请求体（`POST /api/auth/apple`）。
///
/// 🔑 只有 `identity_token`：
///    · **不需要** `.p8` / Key ID（那是 `client_secret` 的事，本模块不做）
///    · ⚠️ 也**不收** `authorization_code` —— 它的唯一用途是换 refresh token
///      以支持「注销时向 Apple 撤销授权」。既然本批不做撤销，收下一个**无法使用**
///      （短时效）的字段就是**死参数**。将来启用撤销时，客户端与服务端一起改。
#[derive(Deserialize)]
pub struct AppleLoginInput {
    /// Apple 返回的 `identityToken`（JWS，RS256）。
    pub identity_token: String,
}

/// POST /api/auth/apple — Sign in with Apple
///
/// 请求体: `{"identity_token": "str"}`
/// 请求头: `Authorization: Bearer <token>` **可选** ——
///   带 ⇒ 把 Apple 身份**绑到当前账号**（认领：保留学习记录）；不带 ⇒ 建号 / 登录。
/// 响应: `{"user_id","token","message","email"}`（**与 login 同形**）或 `{"error": "str"}`
/// 限流: 20 次/分钟/IP（与 `register` 同档 —— 两者都是「建号/登录」入口）
///
/// # 🔴 鉴权在 claims 里，不在请求体里
///
/// 用户身份完全由**验签通过的** `identityToken` 决定 ——
/// 请求体里没有任何「我是谁」的可自证字段（那会被随便伪造）。
async fn auth_apple(
    headers: HeaderMap,
    Json(input): Json<AppleLoginInput>,
) -> axum::response::Response {
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 20, 60) {
        return resp;
    }

    // ── ① 验 identityToken（内部会取 Apple 公钥并验签；失败一律拒绝）──
    let claims = match crate::apple_auth::verify_identity_token(
        &input.identity_token,
        &crate::apple_auth::apple_client_id(),
    )
    .await
    {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("auth_apple: identityToken 验证失败 —— {}", e);
            return Json(serde_json::json!({"error": e})).into_response();
        }
    };

    // ── ② 可选：带了 Authorization 头 ⇒ 「已登录用户绑定 Apple」──
    // ⚠️ 取不到有效 uid **不是错误** —— 那就是「未登录用户走 Apple 登录」的正常路径。
    let current_uid: Option<String> = match crate::user_purge::extract_bearer_token(&headers) {
        Ok(token) => {
            let conn = crate::db_pool::get_conn();
            crate::auth::uid_by_token(&conn, &token).ok()
        }
        Err(_) => None,
    };

    // ── ③ 建号 / 登录 / 绑定 ──
    let result = {
        let conn = crate::db_pool::get_conn();
        crate::apple_auth::apple_login(&conn, &claims, current_uid.as_deref())
    };

    match result {
        Ok(resp) => {
            tracing::info!("auth_apple: 成功（user_id={}）", resp.user_id);
            Json(serde_json::json!(resp)).into_response()
        }
        Err(e) => {
            // ⚠️ 不打印 identityToken（即使是日志）—— 它是可重放的凭据。
            tracing::warn!("auth_apple: 失败 —— {}", e);
            Json(serde_json::json!({"error": e})).into_response()
        }
    }
}

/// POST /api/auth/verify — 验证 token 是否仍有效（用于应用重启后的会话恢复）
/// 请求: {"user_id": "str", "token": "str"}
/// 响应: {"valid": true|false}
#[derive(Deserialize)]
pub struct TokenVerifyInput {
    pub user_id: String,
    pub token: String,
}

async fn auth_verify(Json(input): Json<TokenVerifyInput>) -> Json<serde_json::Value> {
    tracing::info!("auth_verify: user_id={}", input.user_id);

    let conn = crate::db_pool::get_conn();
    let valid = crate::auth::verify_token(&conn, &input.user_id, &input.token);
    // 🔑 返回 `email` 而非 `real_name`（2026-09-29）。
    //    前端的用途从来不是「显示姓名」，而是「判断该账号**是否已完成注册**」——
    //    `None` = 仍是 trial 匿名账号 → `home_screen` 据此弹注册引导。
    //    改邮箱后这个语义**不变**（trial 账号的 email 为 NULL）。
    let email: Option<String> = if valid {
        conn.query_row(
            "SELECT email FROM users WHERE id = ?1",
            rusqlite::params![input.user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten()
    } else {
        None
    };
    Json(serde_json::json!({"valid": valid, "email": email}))
}

// ── Review Handlers ──

#[derive(Deserialize)]
pub struct DueQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub language: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

// 🔴 2026-09-29 已退役：review_due_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

#[derive(Deserialize)]
pub struct ReviewSubmitInput {
    pub user_id: String,
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,
    pub details: Option<String>, // JSON 数组: [{question, correct, feedback}]
}

// 🔴 2026-09-29 已退役：review_submit_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

#[derive(Deserialize)]
pub struct VerifyInput {
    pub user_id: String,
    pub card_id: String,
    pub front: String,
    pub back: String,
}

// 🔴 2026-09-29 已退役：review_verify_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

#[derive(Deserialize)]
pub struct JudgeInput {
    pub user_id: String,
    pub card_id: String,
    pub questions: Vec<JudgeQuestionInput>,
}

#[derive(Deserialize)]
pub struct JudgeQuestionInput {
    pub question: String,
    pub expected_answer: String,
    pub user_answer: String,
}

// 🔴 2026-09-29 已退役：review_judge_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ── Review: cards by progress ──

/// GET /api/review/cards-by-progress — 按 task 进度查询卡片
#[derive(Deserialize)]
struct CardsByProgressQuery {
    user_id: String,
}

// 🔴 2026-09-29 已退役：review_cards_by_progress_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ── Verify Translation (V1 forward mode) ──

#[derive(Deserialize)]
struct VerifyTranslationInput {
    front: String,
    back: String,
    user_input: String,
}

async fn verify_translation_handler(
    Json(input): Json<VerifyTranslationInput>,
) -> Json<serde_json::Value> {
    tracing::info!("verify_translation_handler");

    let tpl = chat_engine::prompt_loader::get_verify("general");
    let prompt = tpl
        .translation
        .replace("{front}", &input.front)
        .replace("{back}", &input.back)
        .replace("{user_input}", &input.user_input);

    let config = crate::llm::get_config();
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);
    match caller.generate("", &prompt).await {
        Ok(reply) => {
            let result = if reply.to_lowercase().contains("pass") {
                "pass"
            } else {
                "fail"
            };
            Json(serde_json::json!({"result": result}))
        }
        Err(_) => {
            // LLM fallback: simple keyword matching
            let input_lower = input.user_input.to_lowercase();
            let back_lower = input.back.to_lowercase();
            let result = if back_lower.contains(&input_lower) || input_lower.contains(&back_lower) {
                "pass"
            } else {
                "fail"
            };
            Json(serde_json::json!({"result": result}))
        }
    }
}

// ── Card Status Handlers ──

#[derive(Deserialize)]
pub struct UpdateStatusInput {
    pub user_id: String,
    pub card_id: String,
    pub status: String,
}

#[derive(Deserialize)]
pub struct BatchStatusInput {
    pub user_id: String,
    pub card_ids: Vec<String>,
    pub status: String,
}

// 🔴 2026-09-29 已退役：cards_status_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：cards_batch_status_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：ws_upgrade（依赖已删除的表 / 已退役模块，路由已同步移除）

/// GET /api/cards/all — 获取用户所有卡片 (含搜索过滤)
#[derive(Deserialize)]
pub struct AllCardsQuery {
    pub user_id: String,
    pub q: Option<String>,       // 搜索关键词 (匹配 front/back)
    pub state: Option<i32>,      // 按 FSRS state 过滤
    pub subject: Option<String>, // 按科目过滤 (替代 domain)
    pub sort: Option<String>,    // "front" | "created" | "state" | "due"
}

// 🔴 2026-09-29 已退役：cards_all_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ── Cards by Plan (grouped by conversation_plans) ──

#[derive(Deserialize)]
pub struct CardsByPlanQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    pub sort: Option<String>,
}

// 🔴 2026-09-29 已退役：cards_by_plan_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

/// GET /api/cards/search — 搜索卡片的 front/back，支持分页
#[derive(Deserialize)]
pub struct CardsSearchQuery {
    pub user_id: String,
    pub q: String,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

// 🔴 2026-09-29 已退役：cards_search_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

/// 历史查询
#[derive(Deserialize)]
pub struct HistoryQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub limit: Option<i64>,
    /// "only"=仅已删除, "true"=全部, 默认=仅活跃
    pub include_deleted: Option<String>,
    /// 分页偏移（仅 conversation_id 模式有效），默认 0
    pub offset: Option<i64>,
}

// 🔴 2026-09-29 已退役：cards_last_review_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：history_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ════════════════════════════════════════════
// 对话管理 — 软删除 / 恢复 / 彻底删除
// ════════════════════════════════════════════

#[derive(Deserialize)]
struct ConversationActionQuery {
    user_id: String,
}

// 🔴 2026-09-29 已退役：conversation_delete_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：conversation_restore_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：conversation_permanent_delete_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

/// GET /api/user/:user_id/profile — 用户资料
///
/// 🔴 2026-09-29 已退役：原返回的 `stats` / `achievements` / `cefr_stats` 三项 ——
/// 它们都依赖**已迁到端侧**的学习状态（`user_cards` / `card_memory` / `review_log`）
/// 或已删除的表（`prebuilt_cards` / `achievements`）。
/// → 学习统计改为「**端侧计算**」（数据在 `user.db`）；成就待「成就体系重新规划」。
/// 现仅返回 `users` 表内的资料字段。
async fn profile_handler(
    headers: axum::http::HeaderMap,
    Path(user_id): Path<String>,
) -> axum::response::Response {
    tracing::info!("profile_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();

    // Verify auth: caller must be the user themselves
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return (
            axum::http::StatusCode::UNAUTHORIZED,
            axum::Json(serde_json::json!({"error": "unauthorized"})),
        )
            .into_response();
    }

    let display_name: Option<String> = conn
        .query_row(
            "SELECT display_name FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    let subscription_expires: Option<String> = conn
        .query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    // 🔴 2026-09-29：`real_name` / `phone` 两列已删（改邮箱注册）→
    //    连同这里原来的「AES 解密 PII」一并移除。
    //
    // 🔑 邮箱**不需要**那套加密：实名/手机号是**身份信息**（泄露后果严重、且平台需保护），
    //    而邮箱是**用户主动提供、且本来就要回显**的登录标识
    //    （「我的」页要显示它、找回密码要用它）。
    //    **给一个必须明文回显的字段做加密，只会制造「存的是密文、用时要解密」的绕路。**
    let email: Option<String> = conn
        .query_row(
            "SELECT email FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    let streak_days: i64 = conn
        .query_row(
            "SELECT streak_days FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .unwrap_or(0);

    (
        axum::http::StatusCode::OK,
        axum::Json(serde_json::json!({
            "user_id": user_id,
            "display_name": display_name,
            "email": email,
            "subscription_expires": subscription_expires,
            "streak_days": streak_days,
        })),
    )
        .into_response()
}

// ── Achievements All (Phase 3: 按 category 分组 + 进度) ──

// 🔴 2026-09-29 已退役：achievements_all_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：compute_progress（依赖已删除的表 / 已退役模块，路由已同步移除）

// ── Plan Achievements ──

// 🔴 2026-09-29 已退役：plan_achievements_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ── Display Name ──

async fn update_display_name_handler(
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    tracing::info!("update_display_name_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

    let conn = crate::db_pool::get_conn();
    let name = input
        .get("display_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.trim().is_empty() {
        return Json(serde_json::json!({"error": "display_name cannot be empty"}));
    }
    match conn.execute(
        "UPDATE users SET display_name = ?1 WHERE id = ?2",
        rusqlite::params![name.trim(), user_id],
    ) {
        Ok(_) => Json(serde_json::json!({"status": "ok", "display_name": name.trim()})),
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

// ════════════════════════════════════════════
// User Preferences
// ════════════════════════════════════════════

// ── Subscription check ──

/// GET /api/user/{user_id}/subscription — 轻量订阅状态检查
async fn user_subscription_handler(Path(user_id): Path<String>) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let expires: Option<String> = conn
        .query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();

    let now_ts = chrono::Utc::now().timestamp();
    let expired = match &expires {
        Some(e) => {
            let normalized = if e.len() == 10 && e.as_bytes().get(4) == Some(&b'-') {
                format!("{}T00:00:00Z", e)
            } else {
                e.clone()
            };
            chrono::DateTime::parse_from_rfc3339(&normalized)
                .map(|dt| dt.timestamp() < now_ts)
                .unwrap_or(true)
        }
        None => true,
    };

    Json(json!({
        "expired": expired,
        "expires_at": expires,
    }))
}

/// POST /api/stt/transcribe — 语音识别（腾讯云 ASR）
///
/// Body: {"audio": "<base64>", "format": "wav", "engine": "16k_zh"}
/// Returns: {"text": "识别结果"}
async fn stt_transcribe_handler(Json(payload): Json<serde_json::Value>) -> impl IntoResponse {
    use axum::http::StatusCode;

    let audio = match payload.get("audio").and_then(|v| v.as_str()) {
        Some(a) if !a.is_empty() => a,
        _ => {
            tracing::warn!("stt_transcribe: audio field missing or empty");
            return (StatusCode::BAD_REQUEST, "audio 不能为空").into_response();
        }
    };
    let data_len = payload
        .get("data_len")
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as usize;
    let engine = payload
        .get("engine")
        .and_then(|v| v.as_str())
        .unwrap_or("16k_zh");
    let format = payload
        .get("format")
        .and_then(|v| v.as_str())
        .unwrap_or("wav");

    tracing::info!(
        "stt_transcribe: len={} engine={} format={}",
        data_len,
        engine,
        format
    );

    match crate::tencent_asr::recognize(audio, data_len, engine, format).await {
        Ok(text) => {
            tracing::info!("stt_transcribe OK: result_len={}", text.len());
            (
                StatusCode::OK,
                serde_json::json!({"text": text}).to_string(),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("stt_transcribe failed: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("ASR 识别失败: {}", e),
            )
                .into_response()
        }
    }
}

// ── Preferences ──

async fn preferences_get_handler(Path(user_id): Path<String>) -> Json<serde_json::Value> {
    tracing::info!("preferences_get_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let mut stmt = conn
        .prepare("SELECT key, value FROM user_preferences WHERE user_id = ?1")
        .unwrap();
    let mut prefs = serde_json::Map::new();
    for row in stmt
        .query_map(rusqlite::params![user_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .unwrap()
        .filter_map(|r| r.ok())
    {
        prefs.insert(row.0, serde_json::Value::String(row.1));
    }
    // 合并 users 表的 subscription_expires（user_preferences 已去除订阅功能）
    let sub_expires: Option<String> = conn
        .query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    if let Some(exp) = sub_expires {
        prefs.insert(
            "subscription_expires".to_string(),
            serde_json::Value::String(exp),
        );
    }
    Json(serde_json::Value::Object(prefs))
}

async fn preferences_put_handler(
    Path(user_id): Path<String>,
    Json(input): Json<HashMap<String, String>>,
) -> Json<serde_json::Value> {
    tracing::info!("preferences_put_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().timestamp();
    for (key, value) in &input {
        if key == "subscription_expires" {
            // 拒绝普通用户自设订阅到期时间，应通过管理员后台或支付流程处理
            continue;
        }
        let _ = conn.execute(
            "INSERT INTO user_preferences (user_id, key, value, updated_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(user_id, key) DO UPDATE SET value = ?3, updated_at = ?4",
            rusqlite::params![user_id, key, value, now],
        );
    }
    Json(serde_json::json!({"status": "ok"}))
}

// ── Avatar ──

static AVATAR_DIR: OnceLock<String> = OnceLock::new();

pub fn set_avatar_dir(dir: &str) {
    let _ = AVATAR_DIR.set(dir.to_string());
}

fn avatar_dir() -> &'static str {
    AVATAR_DIR
        .get()
        .map(|s| s.as_str())
        .unwrap_or("data/avatars")
}

async fn avatar_upload_handler(
    headers: HeaderMap,
    Path(user_id): Path<String>,
    mut multipart: axum::extract::Multipart,
) -> Json<serde_json::Value> {
    tracing::info!("avatar_upload_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

    use tokio::io::AsyncWriteExt;
    let _ = tokio::fs::create_dir_all(avatar_dir()).await;
    if let Ok(Some(field)) = multipart.next_field().await {
        let data = match field.bytes().await {
            Ok(d) => d,
            Err(e) => return Json(serde_json::json!({"error": format!("Read: {}", e)})),
        };
        if data.is_empty() || data.len() > 5 * 1024 * 1024 {
            return Json(serde_json::json!({"error": "File too large (max 5MB)"}));
        }
        let path = format!("{}/{}.png", avatar_dir(), user_id);
        let mut file = match tokio::fs::File::create(&path).await {
            Ok(f) => f,
            Err(e) => return Json(serde_json::json!({"error": format!("Write: {}", e)})),
        };
        if let Err(e) = file.write_all(&data).await {
            return Json(serde_json::json!({"error": format!("Write: {}", e)}));
        }
        return Json(
            serde_json::json!({"status": "ok", "url": format!("/api/user/{}/avatar", user_id)}),
        );
    }
    Json(serde_json::json!({"error": "No file uploaded"}))
}

async fn avatar_get_handler(
    Path(user_id): Path<String>,
) -> Result<
    (
        axum::http::StatusCode,
        [(&'static str, &'static str); 1],
        Vec<u8>,
    ),
    (axum::http::StatusCode, &'static str),
> {
    tracing::info!("avatar_get_handler: user_id={}", user_id);

    let path = format!("{}/{}.png", avatar_dir(), user_id);
    match tokio::fs::read(&path).await {
        Ok(data) => Ok((
            axum::http::StatusCode::OK,
            [("Content-Type", "image/png")],
            data,
        )),
        Err(_) => Err((axum::http::StatusCode::NOT_FOUND, "No avatar")),
    }
}

// ════════════════════════════════════════════
// Learning Plan Handlers
// ════════════════════════════════════════════

// 🔴 2026-09-29 已退役：plans_list_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ════════════════════════════════════════════
// Phase 3 — Learning Report
// ════════════════════════════════════════════

// 🔴 2026-09-29 已退役：learning_report_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：compute_plan_totals（依赖已删除的表 / 已退役模块，路由已同步移除）

// ════════════════════════════════════════════
// Activity Heatmap API
// ════════════════════════════════════════════

// 🔴 2026-09-29 已退役：activity_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// ════════════════════════════════════════════
// Weekly Report API
// ════════════════════════════════════════════

// 🔴 2026-09-29 已退役：weekly_report_handler（依赖已删除的表 / 已退役模块，路由已同步移除）

// 🔴 2026-09-29 已退役：activate_first_task（依赖已删除的表 / 已退役模块，路由已同步移除）

// ══════════════════════════════════════════════════════════════════════
// 词库外生词兜底 —— LLM 在线制卡
// ══════════════════════════════════════════════════════════════════════

/// `POST /api/generate-card` —— 用户划到词库外的词时的出口。
///
/// # 请求
/// ```json
/// { "spelling": "brainstorm", "device_id": "匿名设备标识（可选）" }
/// ```
///
/// # 响应
/// ```json
/// { "ok": true, "spelling": "brainstorm", "from_cache": false,
///   "hit_count": 0, "contract_version": "v6", "card": { ... } }
/// ```
/// 失败：`{"ok": false, "error": "..."}` + 对应状态码
/// （400 参数 · 422 闸门 · 502 上游 · 503 正在生成 · 500 内部）。
///
/// # 🔴 不需要登录
/// 产品原则：「除生词表上限外**不验证登录态**」—— 内容渲染不得被登录态阻塞。
/// `device_id` 只是**匿名设备标识**（端侧生成），用于统计 `distinct_user_count`
/// （回流门槛的真信号）；**缺省时不影响生成**，只是不计 distinct。
async fn generate_card_handler(Json(payload): Json<serde_json::Value>) -> impl IntoResponse {
    use axum::http::StatusCode;

    let spelling = match payload.get("spelling").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => s,
        _ => {
            tracing::warn!("generate_card: spelling 缺失或为空");
            return (
                StatusCode::BAD_REQUEST,
                serde_json::json!({"ok": false, "error": "spelling 不能为空"}).to_string(),
            )
                .into_response();
        }
    };
    let device_id = payload.get("device_id").and_then(|v| v.as_str());

    match crate::llm_card::get_or_generate(spelling, device_id).await {
        Ok(r) => {
            tracing::info!(
                "generate_card OK spelling={} from_cache={} hits={}",
                spelling,
                r.from_cache,
                r.hit_count
            );
            (
                StatusCode::OK,
                serde_json::json!({
                    "ok": true,
                    "spelling": spelling.trim().to_lowercase(),
                    "from_cache": r.from_cache,
                    "hit_count": r.hit_count,
                    "contract_version": crate::llm_card::CONTRACT_VERSION,
                    "card": r.card,
                })
                .to_string(),
            )
                .into_response()
        }
        Err(e) => {
            let st = e.status();
            tracing::warn!(
                "generate_card FAIL spelling={} status={} msg={}",
                spelling,
                st.as_u16(),
                e.message()
            );
            (
                st,
                serde_json::json!({"ok": false, "error": e.message()}).to_string(),
            )
                .into_response()
        }
    }
}
