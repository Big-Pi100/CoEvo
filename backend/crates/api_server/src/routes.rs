//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, put, delete, patch}, Json, extract::Path, response::IntoResponse};
use axum::http::{HeaderMap, StatusCode, header};
use tower_http::trace::TraceLayer;
use std::collections::HashMap;
use std::sync::OnceLock;
use serde::Deserialize;
use serde_json::json;

use crate::error::AppError;
use crate::admin_handlers::*;

/// 提供 Flutter Web 构建的静态文件（SPA 模式：未匹配路径返回 index.html）
const FLUTTER_WEB_DIR: &str = "../app/build/web";

async fn serve_flutter_web(Path(path): Path<String>) -> impl IntoResponse {
    let base = std::path::Path::new(FLUTTER_WEB_DIR);
    let file_path = if path.is_empty() || path == "index.html" || !path.contains('.') {
        // 无扩展名路径 → SPA fallback
        base.join("index.html")
    } else {
        let p = base.join(&path);
        if p.starts_with(base) && p.is_file() { p } else { base.join("index.html") }
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
        Err(_) if file_path.ends_with("index.html") => {
            (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")], b"<h1>App not built</h1><p>Run: cd app && flutter build web</p>" as &[u8]).into_response()
        }
        Err(_) => {
            // 文件不存在 → SPA fallback
            match tokio::fs::read(base.join("index.html")).await {
                Ok(data) => (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")], data).into_response(),
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
    conn: &rusqlite::Connection, sql: &str, params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<Vec<T>, Json<serde_json::Value>>
where F: Fn(&rusqlite::Row) -> rusqlite::Result<T>
{
    let mut stmt = conn.prepare(sql).map_err(|e| Json(serde_json::json!({"error": format!("DB prepare: {}", e)})))?;
    let rows: Vec<T> = stmt.query_map(params, map)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB query: {}", e)})))?
        .filter_map(|r| r.ok()).collect();
    Ok(rows)
}

/// Helper: run a query_row that returns a single value, or return a Json error
#[allow(dead_code)]
fn query_one<T, F>(
    conn: &rusqlite::Connection, sql: &str, params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<T, Json<serde_json::Value>>
where F: Fn(&rusqlite::Row) -> rusqlite::Result<T>
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
        .route("/api/public/qrcode", get(crate::config_admin::qrcode_handler))
        // ── Payment & Subscription ──
        .route("/api/pay/plans", get(crate::plans_handlers::plans_list_handler))
        .route("/api/pay/native", post(crate::pay_handlers::native_pay_handler))
        .route("/api/pay/notify", post(crate::pay_handlers::pay_notify_handler))
        .route("/api/pay/orders", get(crate::pay_handlers::user_orders_handler))
        .route("/api/pay/orders/{id}", get(crate::pay_handlers::order_status_handler))
        // ── Auth ──
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
        .route("/api/auth/verify", post(auth_verify))
        // ── 🔴 2026-09-29 已退役：/api/review/* · /api/cards/* · /api/history · /api/conversations/* ──
        //     学习状态已整体迁到端侧 `user.db`（`card_review_state` / `review_log` / `user_word`）：
        //       · `/api/review/*` 与 `/api/cards/*` 原由后端 FSRS（crate `card_engine`）驱动
        //       · `/api/history` 与 `/api/conversations/*` 属对话链（依赖 `conversation_turns`）
        //     这些接口的唯一调用方是 app 的 `chat_client`，而 app 内 `/chat` **无 UI 入口**。
        //     → 相关表已从 `coevo.db` 删除；模块 `card_engine` / `review_handler` / `ws` 一并退役。
        // ── User Profile ──
        .route("/api/user/{user_id}/profile", get(profile_handler))
        .route("/api/user/{user_id}/profile", put(update_user_profile_handler))
        .route("/api/user/{user_id}/display-name", post(update_display_name_handler))
        .route("/api/user/{user_id}/avatar", post(avatar_upload_handler).get(avatar_get_handler))
        // 🔴 2026-09-29 已退役：/api/user/*/achievements-all · plan-achievements（表 achievements 已删；成就改为「端侧计算」）
        .route("/api/user/{user_id}/preferences", get(preferences_get_handler).put(preferences_put_handler))
        .route("/api/user/{user_id}/subscription", get(user_subscription_handler))
        .route("/api/stt/transcribe", post(stt_transcribe_handler))
        // ── 词库外生词兜底（LLM 在线制卡）──
        // 🔴 **不需登录** —— 产品原则「除生词表上限外不验证登录态」：
        //    读内容/划词/生成卡片都不得被登录态阻塞。
        .route("/api/generate-card", post(generate_card_handler))
        .route("/api/user/bind-lookup", post(bind_lookup_handler))
        // ── Learning Plans ──
        // 🔴 2026-09-29 已退役：/api/plans（依赖 plan_runs / user_plan_progress，表已删）
        // 🔴 2026-09-29 已退役：学习报表（learning-report / activity / weekly-report）
        //     与 WebSocket（/ws）—— 依赖已迁端侧的学习状态（user_cards / review_log / conversation_turns）
        // 🔴 2026-09-29 已退役：/ws（WebSocket chat —— app 内无 UI 入口）
        // ── Verify Translation (V1 forward mode) ──
        .route("/api/verify-translation", post(verify_translation_handler))
        // ── Admin ──
        .route("/api/admin/login", post(admin_login))
        .route("/api/admin/dashboard", get(admin_dashboard))
        .route("/api/admin/register", post(admin_register))
        .route("/api/admin/users", get(admin_users_handler))
        .route("/api/admin/users/expiring", get(admin_expiring_users))
        .route("/api/admin/users/export", get(admin_users_export))
        .route("/api/admin/users/batch-subscription", post(admin_batch_subscription))
        .route("/api/admin/users/{user_id}", get(admin_user_detail).delete(admin_delete_user))
        .route("/api/admin/users/{user_id}/hard-delete", delete(admin_hard_delete_user))
        .route("/api/admin/users/{user_id}/restore", post(admin_restore_user))
        .route("/api/admin/users/{user_id}/reveal-phone", post(admin_reveal_phone))
        .route("/api/admin/users/{user_id}/subscription", put(admin_set_subscription))
        .route("/api/admin/users/{user_id}/quick-extend", post(admin_quick_extend))
        .route("/api/admin/subscription-requests", get(admin_list_subscription_requests).post(admin_create_subscription_request))
        .route("/api/admin/subscription-requests/{req_id}/approve", post(admin_approve_request))
        .route("/api/admin/subscription-requests/{req_id}/reject", post(admin_reject_request))
        // ── Admin: 支付 & 套餐管理 ──
        .route("/api/admin/plans", get(crate::plans_handlers::admin_plans_list_handler).post(crate::plans_handlers::admin_plan_create_handler))
        .route("/api/admin/plans/{id}", put(crate::plans_handlers::admin_plan_update_handler))
        .route("/api/admin/pay/orders", get(crate::pay_handlers::admin_orders_handler))
        // ── Admin: Audit Log ──
        .route("/api/admin/users/{user_id}/audit-log", get(admin_audit_log_handler))
        .route("/api/admin/admins", get(admin_list_admins).post(admin_create_admin))
        .route("/api/admin/admins/{admin_id}/approve", post(admin_approve_admin))
        .route("/api/admin/admins/{admin_id}/reject", post(admin_reject_admin))
        .route("/api/admin/admins/{admin_id}/password", post(admin_reset_password))
        .route("/api/admin/admins/{admin_id}/permissions", put(admin_set_permissions))
        .route("/api/admin/admins/{admin_id}/disable", delete(admin_disable_admin))
        .route("/api/admin/admins/{admin_id}/enable", post(admin_enable_admin))
        .route("/api/admin/audit-log", get(admin_audit_log))
        // ── 🔴 2026-09-29 已退役：Admin K12 后台（Guardian + Curriculum，41 个路由）──
        //     依赖的表已删（`guardian_assignments` / `prebuilt_*` / `card_relations` /
        //     `plan_runs` / `user_plan_progress`）→ 模块 `curriculum_admin` / `curriculum_loader` 一并退役。
        // ── Admin: Config & Debug ──
        .route("/api/admin/config", get(crate::config_admin::get_config_handler).post(crate::config_admin::post_config_handler))
        .route("/api/admin/prompt/template", get(crate::config_admin::get_template_handler).post(crate::config_admin::post_template_handler))
        .route("/api/admin/prompt/templates", get(crate::config_admin::list_templates_handler))
        // 🔴 2026-09-29 已退役：/api/admin/debug/*（依赖已删表 debug_logs / debug_trackers）
        // ── Distribution & Marketing ──
        // 用户端 API
        .route("/api/campaigns/check-push-trigger", get(crate::campaign_handler::check_push_trigger))
        .route("/api/referral/click", post(crate::referral_handler::click))
        .route("/api/referral/my-code", get(crate::referral_handler::my_code))
        .route("/api/referral/my-stats", get(crate::referral_handler::my_stats))
        .route("/api/referral/my-team", get(crate::referral_handler::my_team))
        .route("/api/referral/my-commissions", get(crate::referral_handler::my_commissions))
        .route("/api/referral/generate-poster", post(crate::referral_handler::generate_poster))
        .route("/api/referral/generate-h5", post(crate::referral_handler::generate_h5))
        .route("/api/referral/user-portrait", get(crate::referral_handler::user_portrait))
        .route("/api/referral/qrcode", get(crate::referral_handler::get_qrcode))
        .route("/api/campaign/join", post(crate::campaign_member_handler::join))
        .route("/api/trial/start", post(crate::trial_handler::start))
        .route("/api/trial/claim", put(crate::trial_handler::claim))
        // 用户端提现
        .route("/api/referral/withdraw", post(crate::distribution_handler::user_withdraw))
        .route("/api/referral/my-withdrawals", get(crate::distribution_handler::user_withdrawals))
        // 推广落地页
        .route("/share/{code}", get(crate::referral_handler::share_landing))
        .route("/share/", get(crate::referral_handler::share_landing_home))
        .route("/share", get(crate::referral_handler::share_landing_home))
        .route("/go/{code}", get(crate::referral_handler::share_landing))
        .route("/go/", get(crate::referral_handler::share_landing_home))
        .route("/go", get(crate::referral_handler::share_landing_home))
        .route("/api/pay/calculate", post(crate::distribution_handler::calculate))
        .route("/api/referral/user-campaign", get(crate::distribution_handler::user_campaign))
        .route("/api/notifications", get(crate::distribution_handler::list_notifications))
        .route("/api/notifications/{id}/read", post(crate::distribution_handler::mark_read))
        .route("/api/notifications/read-all", post(crate::distribution_handler::mark_read_all))
        // 管理端活动 API
        .route("/api/admin/campaigns", get(crate::campaign_handler::list).post(crate::campaign_handler::create))
        .route("/api/admin/campaigns/default-poster-prompt", get(crate::campaign_handler::default_poster_prompt))
        .route("/api/admin/campaigns/{id}", get(crate::campaign_handler::get).put(crate::campaign_handler::update).delete(crate::campaign_handler::delete))
        .route("/api/admin/campaigns/{id}/status", patch(crate::campaign_handler::toggle_status))
        .route("/api/admin/campaigns/{id}/push", post(crate::campaign_handler::push))
        .route("/api/admin/campaigns/{id}/stats", get(crate::campaign_handler::stats))
        .route("/api/admin/campaigns/{id}/generate-poster-template", post(crate::campaign_handler::generate_poster_template))
        .route("/api/admin/campaigns/{id}/generate-h5-template", post(crate::campaign_handler::generate_h5_template))
        .route("/api/admin/campaigns/{id}/preview-poster", post(crate::campaign_handler::preview_poster))
        .route("/api/admin/campaigns/{id}/preview-h5", post(crate::campaign_handler::preview_h5))
        // 管理端结算 API
        .route("/api/admin/settlement/pending-commissions", get(crate::distribution_handler::pending_commissions))
        .route("/api/admin/settlement/batches/export-all", get(crate::distribution_handler::export_all_batches))
        .route("/api/admin/settlement/batches", get(crate::distribution_handler::list_batches))
        .route("/api/admin/settlement/batches/{batch_no}", get(crate::distribution_handler::get_batch))
        .route("/api/admin/settlement/batches/{batch_no}/export", get(crate::distribution_handler::export_batch))
        .route("/api/admin/settlement/complete-payment", post(crate::distribution_handler::mark_paid))
        .route("/api/admin/settlement/pending-export", get(crate::distribution_handler::export_pending_csv))
        // 管理端提现 API
        .route("/api/admin/withdrawals", get(crate::distribution_handler::list_withdrawals))
        .route("/api/admin/withdrawals/{id}/approve", post(crate::distribution_handler::approve_withdrawal))
        .route("/api/admin/withdrawals/{id}/reject", post(crate::distribution_handler::reject_withdrawal))
        // 管理端团队 API
        .route("/api/admin/team", get(crate::distribution_handler::admin_team))
        .route("/api/admin/team/{user_id}", get(crate::distribution_handler::admin_team_user))
        // 管理端统计 API
        .route("/api/admin/distribution/stats", get(crate::distribution_handler::admin_stats))
        .route("/api/admin/distribution/funnel", get(crate::distribution_handler::admin_funnel))
        .route("/api/admin/distribution/summary", get(crate::distribution_handler::admin_summary))
        .route("/api/admin/distribution/monthly-stats", get(crate::distribution_handler::admin_monthly_stats))
        .route("/api/admin/distribution/ranking", get(crate::distribution_handler::admin_ranking))
        .route("/api/admin/distribution/export", get(crate::distribution_handler::admin_export))
        // 退款 API
        .route("/api/admin/refund/{order_id}", post(crate::distribution_handler::admin_refund))
        .route("/api/webhook/refund", post(crate::distribution_handler::webhook_refund))
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
    pub username: String,
    pub password: String,
    pub real_name: Option<String>,
    pub phone: Option<String>,
    pub referral: Option<crate::auth::ReferralInfo>,
}

/// POST /api/auth/register — 注册新用户
/// 请求: {"username": "str", "password": "str", "real_name?": "str", "phone?": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
/// 限流: 5 次/分钟/IP
async fn auth_register(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!("auth_register: user_id={}, referral={:?}", input.username, input.referral);

    // Rate limit: 20 reg/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 20, 60) { return resp; }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::register(&conn, &crate::auth::RegisterRequest {
            username: input.username,
            password: input.password,
            real_name: input.real_name,
            phone: input.phone,
            referral: input.referral,
        })
    };
    match result {
        Ok(resp) => Json(serde_json::json!(resp)).into_response(),
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
    }
}

/// POST /api/auth/login — 用户登录
/// 请求: {"username": "str", "password": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
/// 注意: 登录后会踢掉同一用户的其他 WebSocket 连接（单设备登录）
/// 限流: 10 次/分钟/IP
async fn auth_login(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!("auth_login: user_id={}", input.username);

    // Rate limit: 10 login/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) { return resp; }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::login(&conn, &crate::auth::LoginRequest {
            username: input.username,
            password: input.password,
        })
    };
    match result {
        Ok(resp) => {
            // 🔴 2026-09-29 已退役：踢同用户其他 WS 连接（WebSocket chat 已退役，无需再踢）
            Json(serde_json::json!(resp)).into_response()
        },
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
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
    let real_name: Option<String> = if valid {
        conn.query_row(
            "SELECT real_name FROM users WHERE id = ?1",
            rusqlite::params![input.user_id],
            |row| row.get(0),
        ).ok().flatten()
    } else {
        None
    };
    Json(serde_json::json!({"valid": valid, "real_name": real_name}))
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
    pub details: Option<String>,  // JSON 数组: [{question, correct, feedback}]
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
    let prompt = tpl.translation
        .replace("{front}", &input.front)
        .replace("{back}", &input.back)
        .replace("{user_input}", &input.user_input);

    let config = crate::llm::get_config();
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);
    match caller.generate("", &prompt).await {
        Ok(reply) => {
            let result = if reply.to_lowercase().contains("pass") { "pass" } else { "fail" };
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
    pub q: Option<String>,         // 搜索关键词 (匹配 front/back)
    pub state: Option<i32>,        // 按 FSRS state 过滤
    pub subject: Option<String>,   // 按科目过滤 (替代 domain)
    pub sort: Option<String>,      // "front" | "created" | "state" | "due"
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
        return (axum::http::StatusCode::UNAUTHORIZED, axum::Json(serde_json::json!({"error": "unauthorized"}))).into_response();
    }

    let display_name: Option<String> = conn.query_row(
        "SELECT display_name FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    let subscription_expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    let real_name_raw: Option<String> = conn.query_row(
        "SELECT real_name FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    let phone_raw: Option<String> = conn.query_row(
        "SELECT phone FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    // Decrypt PII fields — now stored as AES-256-GCM
    let real_name = real_name_raw.as_ref().map(|v| {
        if crate::encryption::is_encrypted(v) { crate::encryption::decrypt(v) } else { v.clone() }
    });
    let phone = phone_raw.as_ref().map(|v| {
        if crate::encryption::is_encrypted(v) { crate::encryption::decrypt(v) } else { v.clone() }
    });
    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    (axum::http::StatusCode::OK, axum::Json(serde_json::json!({
        "user_id": user_id,
        "display_name": display_name,
        "real_name": real_name,
        "phone": phone,
        "subscription_expires": subscription_expires,
        "streak_days": streak_days,
    }))).into_response()
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
    let name = input.get("display_name").and_then(|v| v.as_str()).unwrap_or("");
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
async fn user_subscription_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).ok().flatten();

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
async fn stt_transcribe_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    use axum::http::StatusCode;

    let audio = match payload.get("audio").and_then(|v| v.as_str()) {
        Some(a) if !a.is_empty() => a,
        _ => {
            tracing::warn!("stt_transcribe: audio field missing or empty");
            return (StatusCode::BAD_REQUEST, "audio 不能为空").into_response();
        }
    };
    let data_len = payload.get("data_len").and_then(|v| v.as_i64()).unwrap_or(0) as usize;
    let engine = payload.get("engine").and_then(|v| v.as_str()).unwrap_or("16k_zh");
    let format = payload.get("format").and_then(|v| v.as_str()).unwrap_or("wav");

    tracing::info!("stt_transcribe: len={} engine={} format={}", data_len, engine, format);

    match crate::tencent_asr::recognize(audio, data_len, engine, format).await {
        Ok(text) => {
            tracing::info!("stt_transcribe OK: result_len={}", text.len());
            (StatusCode::OK, serde_json::json!({"text": text}).to_string()).into_response()
        }
        Err(e) => {
            tracing::error!("stt_transcribe failed: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("ASR 识别失败: {}", e)).into_response()
        }
    }
}

// ── Preferences ──

async fn preferences_get_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("preferences_get_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT key, value FROM user_preferences WHERE user_id = ?1"
    ).unwrap();
    let mut prefs = serde_json::Map::new();
    for row in stmt.query_map(rusqlite::params![user_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }).unwrap().filter_map(|r| r.ok()) {
        prefs.insert(row.0, serde_json::Value::String(row.1));
    }
    // 合并 users 表的 subscription_expires（user_preferences 已去除订阅功能）
    let sub_expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    if let Some(exp) = sub_expires {
        prefs.insert("subscription_expires".to_string(), serde_json::Value::String(exp));
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
    AVATAR_DIR.get().map(|s| s.as_str()).unwrap_or("data/avatars")
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
        return Json(serde_json::json!({"status": "ok", "url": format!("/api/user/{}/avatar", user_id)}));
    }
    Json(serde_json::json!({"error": "No file uploaded"}))
}

async fn avatar_get_handler(
    Path(user_id): Path<String>,
) -> Result<(axum::http::StatusCode, [(&'static str, &'static str); 1], Vec<u8>), (axum::http::StatusCode, &'static str)> {
    tracing::info!("avatar_get_handler: user_id={}", user_id);

    let path = format!("{}/{}.png", avatar_dir(), user_id);
    match tokio::fs::read(&path).await {
        Ok(data) => Ok((axum::http::StatusCode::OK, [("Content-Type", "image/png")], data)),
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
async fn generate_card_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
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
                spelling, r.from_cache, r.hit_count
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
                spelling, st.as_u16(), e.message()
            );
            (
                st,
                serde_json::json!({"ok": false, "error": e.message()}).to_string(),
            )
                .into_response()
        }
    }
}
