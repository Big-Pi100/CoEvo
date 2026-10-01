//! Trial / 试用 Handler
//!
//! 提供临时账户创建和认领 API，用户无需注册即可直接试用产品。
//! 临时账户获得 1 天试用订阅，到期后由现有 is_subscription_active() 自动拦截。

use axum::{
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct StartRequest {
    pub referral_code: Option<String>,
    pub campaign_id: Option<String>,
}

#[derive(Deserialize)]
pub struct ClaimRequest {
    pub user_id: String,
    /// 注册标识 = **邮箱**（2026-09-29 起）。
    ///
    /// 🔴 取代了原来的 `username` + `real_name` + `phone` 三件套。
    ///    注意 **`username` 不再由用户提供** —— 它退化为内部标识
    ///    （trial 账号保持 `trial_*` 不变，见下面 UPDATE 的注释）。
    pub email: String,
    pub password: String,
    pub referral_code: Option<String>,
    pub campaign_id: Option<String>,
}

/// POST /api/trial/start — 创建临时账户
///
/// 创建临时用户（username = trial_xxxxx），写入 1 天试用订阅，
/// 返回 user_id + token。
pub async fn start(headers: HeaderMap, Json(body): Json<StartRequest>) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // ── IP 防滥用检测：同 IP 每日最多创建 3 个临时账户 ──
    let client_ip = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(',').next().unwrap_or("").trim())
        .or_else(|| headers.get("x-real-ip").and_then(|v| v.to_str().ok()))
        .unwrap_or("")
        .to_string();

    let uid = Uuid::new_v4().to_string();
    let short_id = &uid[..8];
    let trial_username = format!("trial_{}", short_id);
    let referral_code = format!("CoEvo_trial_{}", &uid[..4]);

    // 不可登录密码（防止 login 入口异常）
    let password_hash = bcrypt::hash(format!("trial_no_login_{}", uid), 4).unwrap_or_default();

    // 事务包裹：IP 限频检测 + users + tokens + IP 日志原子写入
    if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE") {
        tracing::error!("trial/start begin tx failed: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "create_failed"})),
        )
            .into_response();
    }

    // ── IP 防滥用检测（在事务内执行，防止 TOCTOU）──
    if !client_ip.is_empty() {
        let today_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM trial_ip_log WHERE ip = ?1 AND date(created_at) = date('now')",
            rusqlite::params![client_ip],
            |row| row.get(0),
        ).unwrap_or(0);
        if today_count >= 3 {
            conn.execute_batch("ROLLBACK").ok();
            return (
                StatusCode::TOO_MANY_REQUESTS,
                Json(json!({
                    "error": "daily_limit_reached",
                    "message": "今日创建临时账户次数已达上限"
                })),
            )
                .into_response();
        }
    }

    // 5 分钟试用订阅（测试用）
    let now = chrono::Utc::now();
    let expires = (now + chrono::Duration::hours(1))
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string();
    let created_at = now.format("%Y-%m-%d %H:%M:%S").to_string();

    if let Err(e) = conn.execute(
        "INSERT INTO users (id, username, password_hash, referral_code, subscription_expires, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![uid, trial_username, password_hash, referral_code, expires, created_at],
    ) {
        tracing::error!("trial/start insert user failed: {}", e);
        conn.execute_batch("ROLLBACK").ok();
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "create_user_failed"}))).into_response();
    }

    // ── 处理推广码（trial 创建时直接绑定推荐关系）──
    let referred_by: Option<String> = if let Some(ref code) = body.referral_code {
        if !code.is_empty() {
            conn.query_row(
                "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
                rusqlite::params![code],
                |row| row.get(0),
            )
            .ok()
        } else {
            None
        }
    } else {
        None
    };
    tracing::info!(
        "trial/start referral: referred_by={:?}, referred_campaign_id={:?}",
        referred_by,
        body.campaign_id
    );
    // 记录推荐关系（用于 trial/claim 读取和 scope check），但不加入 campaign_members
    // campaign_members 在 trial/claim 中完成，要求用户提供真实姓名和手机号
    // 防止临时试用账户成为有效「下线」
    if let Some(ref rid) = referred_by {
        if let Err(e) = conn.execute(
            "UPDATE users SET referred_by = ?1 WHERE id = ?2",
            rusqlite::params![rid, uid],
        ) {
            tracing::warn!("trial/start set referred_by failed: {}", e);
        }
        if let Some(ref cid) = body.campaign_id {
            if !cid.is_empty() && cid.len() == 36 && cid.chars().filter(|&c| c == '-').count() == 4
            {
                let _ = conn.execute(
                    "UPDATE users SET referred_campaign_id = ?1 WHERE id = ?2",
                    rusqlite::params![cid, uid],
                );
            }
        }
    }

    // 创建 token
    let token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, uid, token, created_at],
    ) {
        tracing::error!("trial/start insert token failed: {}", e);
        conn.execute_batch("ROLLBACK").ok();
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "create_token_failed"})),
        )
            .into_response();
    }

    // 记录 IP 日志
    if !client_ip.is_empty() {
        let log_id = Uuid::new_v4().to_string();
        let _ = conn.execute(
            "INSERT INTO trial_ip_log (id, ip, created_at) VALUES (?1, ?2, ?3)",
            rusqlite::params![log_id, client_ip, created_at],
        );
    }

    tracing::info!("trial/start: user_id={}, username={}", uid, trial_username);

    conn.execute_batch("COMMIT").ok();

    (
        StatusCode::OK,
        Json(json!({
            "user_id": uid,
            "token": token,
            "username": trial_username,
        })),
    )
        .into_response()
}

/// PUT /api/trial/claim — 认领临时账户
///
/// 校验 token → 校验 username 唯一 → 更新 password_hash → 生成新 token
pub async fn claim(headers: HeaderMap, Json(body): Json<ClaimRequest>) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // 1. 校验 token
    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    // 2. 校验输入
    //
    // 🔑 与 `auth::register` **同一套判据**（邮箱格式 · 密码强度）——
    //    两处各写一份的话，「注册」与「认领」的规则会静默漂移，
    //    而用户看不出差别（都是「注册」这个动作）。
    if !crate::auth::is_valid_email(&body.email) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "邮箱格式不正确"})),
        )
            .into_response();
    }
    if body.password.len() < 6
        || !body.password.chars().any(|c| c.is_ascii_alphabetic())
        || !body.password.chars().any(|c| c.is_ascii_digit())
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "密码至少6位含英文+数字"})),
        )
            .into_response();
    }

    // 3. 校验邮箱唯一（**排除自己** —— 重复提交认领应幂等放行，而不是报「已被注册」）
    //
    // ⚠️ `COLLATE NOCASE` 必须与 `auth::register` 一致，
    //    否则 `A@x.com` 在这里通过、在那边被判重复。
    let existing: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE email = ?1 COLLATE NOCASE AND id != ?2",
            rusqlite::params![body.email.trim(), body.user_id],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap_or(false);

    if existing {
        return (
            StatusCode::CONFLICT,
            Json(json!({"error": "该邮箱已被注册"})),
        )
            .into_response();
    }
    // 🔴 2026-09-29 已删：第 4 步「校验手机号唯一」—— `phone_hash` 列已移除。
    //    用户名唯一校验也一并删除：`username` 不再是用户输入（认领不改它）。

    // 5. 密码加密
    let password_hash = match bcrypt::hash(&body.password, 4) {
        Ok(h) => h,
        Err(e) => {
            tracing::error!("trial/claim bcrypt failed: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "password_hash_failed"})),
            )
                .into_response();
        }
    };

    // 5. 处理推广码 — 仅当用户提供了真实姓名和手机号时，才记录推荐关系
    //    防止临时试用账户成为有效「下线」
    // 5. 推广关系
    //
    // 🔴 **判据换了**（2026-09-29）：
    //    · 原：`has_real_info = real_name.is_some() && phone.is_some()`
    //      —— 「防止临时试用账号成为有效下线」
    //    · 现：**无条件记录**
    //
    // 🔑 为什么可以无条件：那两个字段已随「实名 + 手机号」一并删除，而且
    //    **能走到这一步的本来就是真实用户** —— `claim` 本身就是「把匿名账号
    //    注册成正式账号」，注册成功即转化完成。原判据其实是在**用一个代理指标
    //    （填了实名 + 手机号）去判断用户真实性**，而真正的标志就是「注册」这个动作。
    //
    // ⚠️ 不改这里的后果：条件恒为 `false` → **推荐关系永远不记录** ——
    //    静默失效，不报错，只是分销数据从此全是空的。
    let referred_by: Option<String> = {
        // 优先使用请求体中的推广码
        let from_body: Option<String> = if let Some(ref code) = body.referral_code {
            if !code.is_empty() {
                conn.query_row(
                    "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
                    rusqlite::params![code],
                    |row| row.get(0),
                )
                .ok()
            } else {
                None
            }
        } else {
            None
        };
        // 请求体没有推广码，从 DB 读已有的推荐关系（用户之前已通过 trial/start 绑定）
        from_body.or_else(|| {
            conn.query_row(
                "SELECT referred_by FROM users WHERE id = ?1",
                rusqlite::params![&body.user_id],
                |row| row.get(0),
            )
            .ok()
            .flatten()
        })
    };

    let email = body.email.trim().to_string();

    // 6. 更新用户
    //
    // 🔴 `username` **不再修改** —— 它退化为内部标识，trial 账号保持 `trial_*`。
    //    判断「是否已注册」改看 `email` 是否为空。这比原来的 `isTrialAccount`
    //    （靠 `trial_` 前缀猜）更准：那个判据一旦 username 被改就失效。
    //
    // 🔴 `display_name` 只在**为空**时才填邮箱前缀 —— 用户可能早就改过昵称，
    //    认领时不能把它覆盖掉。
    //
    // 🔴 原来的「real_name / phone 一旦设置不可修改」（CASE WHEN ... IS NULL）
    //    随那两列一并删除；这里对 `display_name` 保留了同样的「只填不改」语义。
    if let Err(e) = conn.execute(
        "UPDATE users SET password_hash = ?1, email = ?2, \
         display_name = CASE WHEN display_name IS NULL OR display_name = '' THEN ?3 ELSE display_name END, \
         referred_by = COALESCE(?4, referred_by) \
         WHERE id = ?5",
        rusqlite::params![
            password_hash, email,
            crate::auth::default_display_name(&email),
            referred_by, body.user_id,
        ],
    ) {
        tracing::error!("trial/claim update user failed: {}", e);
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "update_user_failed"}))).into_response();
    }
    // 如果有推荐人和 campaign_id，同时记录 referred_campaign_id
    if referred_by.is_some() {
        if let Some(ref cid) = body.campaign_id {
            if !cid.is_empty() {
                let _ = conn.execute(
                    "UPDATE users SET referred_campaign_id = ?1 WHERE id = ?2",
                    rusqlite::params![cid, body.user_id],
                );
            }
        }
    }

    // 如果有 campaign_id，加入活动成员（仅用户提供了真实信息时才记入）
    // 加入活动成员 —— 🔴 条件已去掉（原来包在 `if has_real_info` 里）。
    // 理由同上面「推广关系」那段：能走到这里的都是已完成注册的真实用户。
    if let Some(ref cid) = body.campaign_id {
        if !cid.is_empty() {
            // 新用户以 member 身份加入
            let now_str = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
            let _ = conn.execute(
                "INSERT OR IGNORE INTO campaign_members (campaign_id, user_id, role, created_at) VALUES (?1, ?2, 'member', ?3)",
                rusqlite::params![cid, body.user_id, now_str],
            );
            // 如果有推荐人，也以 inviter 身份加入
            if let Some(ref rid) = referred_by {
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO campaign_members (campaign_id, user_id, role, created_at) VALUES (?1, ?2, 'inviter', ?3)",
                    rusqlite::params![cid, rid, now_str],
                );
            }
        }
    }

    // 8. 触发注册活动（不传 campaign_filter，scope check 由 executor 内部处理）
    if let Err(e) = crate::campaign_executor::execute_campaign_trigger(
        &conn,
        "registration",
        &body.user_id,
        referred_by.as_deref(),
        None,
        None,
    ) {
        tracing::warn!("trial/claim campaign trigger failed: {}", e);
    }

    // 9. 🔴 2026-09-29 已退役：推荐注册成就事件（成就改为「端侧计算」）

    // 9. 删除旧 token、创建新 token
    let new_token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    let _ = conn.execute(
        "DELETE FROM tokens WHERE user_id = ?1",
        rusqlite::params![body.user_id],
    );
    if let Err(e) = conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, body.user_id, new_token, now],
    ) {
        tracing::error!("trial/claim insert token failed: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "create_token_failed"})),
        )
            .into_response();
    }

    tracing::info!(
        "trial/claim: user_id={}, email={}, referred_by={:?}, campaign_id={:?}",
        body.user_id,
        body.email,
        referred_by,
        body.campaign_id
    );

    // 🔑 响应里**不再回 `username`**（它已不是用户输入的东西，回给前端只会让人以为它可改）。
    //    回 `email` —— 前端拿它可以立即更新「我的」页显示。
    (
        StatusCode::OK,
        Json(json!({
            "token": new_token,
            "email": body.email.trim(),
        })),
    )
        .into_response()
}
