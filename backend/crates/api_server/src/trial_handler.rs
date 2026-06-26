//! Trial / 试用 Handler
//!
//! 提供临时账户创建和认领 API，用户无需注册即可直接试用产品。
//! 临时账户获得 1 天试用订阅，到期后由现有 is_subscription_active() 自动拦截。

use axum::{Json, http::{HeaderMap, StatusCode}, response::IntoResponse};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct ClaimRequest {
    pub user_id: String,
    pub username: String,
    pub password: String,
    pub real_name: Option<String>,
    pub phone: Option<String>,
    pub referral_code: Option<String>,
}

/// POST /api/trial/start — 创建临时账户
///
/// 创建临时用户（username = trial_xxxxx），写入 1 天试用订阅，
/// 返回 user_id + token。
pub async fn start(
    headers: HeaderMap,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // ── IP 防滥用检测：同 IP 每日最多创建 3 个临时账户 ──
    let client_ip = headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(',').next().unwrap_or("").trim())
        .or_else(|| {
            headers.get("x-real-ip")
                .and_then(|v| v.to_str().ok())
        })
        .unwrap_or("")
        .to_string();

    let uid = Uuid::new_v4().to_string();
    let short_id = &uid[..8];
    let trial_username = format!("trial_{}", short_id);
    let referral_code = format!("CoEvo_trial_{}", &uid[..4]);

    // 不可登录密码（防止 login 入口异常）
    let password_hash = bcrypt::hash(format!("trial_no_login_{}", uid), 4)
        .unwrap_or_default();

    // 事务包裹：IP 限频检测 + users + tokens + IP 日志原子写入
    if let Err(e) = conn.execute_batch("BEGIN") {
        tracing::error!("trial/start begin tx failed: {}", e);
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "create_failed"}))).into_response();
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
            return (StatusCode::TOO_MANY_REQUESTS, Json(json!({
                "error": "daily_limit_reached",
                "message": "今日创建临时账户次数已达上限"
            }))).into_response();
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

    // 创建 token
    let token = Uuid::new_v4().to_string();
    let token_id = Uuid::new_v4().to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, uid, token, created_at],
    ) {
        tracing::error!("trial/start insert token failed: {}", e);
        conn.execute_batch("ROLLBACK").ok();
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "create_token_failed"}))).into_response();
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

    (StatusCode::OK, Json(json!({
        "user_id": uid,
        "token": token,
        "username": trial_username,
    }))).into_response()
}

/// PUT /api/trial/claim — 认领临时账户
///
/// 校验 token → 校验 username 唯一 → 更新 password_hash → 生成新 token
pub async fn claim(
    headers: HeaderMap,
    Json(body): Json<ClaimRequest>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // 1. 校验 token
    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    // 2. 校验输入
    if body.password.len() < 6 {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "密码至少6位"}))).into_response();
    }
    if body.username.len() < 2 {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "用户名至少2位"}))).into_response();
    }

    // 3. 校验用户名唯一
    let existing: bool = conn.query_row(
        "SELECT COUNT(*) FROM users WHERE username = ?1 AND id != ?2",
        rusqlite::params![body.username, body.user_id],
        |row| row.get::<_, i64>(0),
    ).map(|c| c > 0).unwrap_or(false);

    if existing {
        return (StatusCode::CONFLICT, Json(json!({"error": "用户名已存在"}))).into_response();
    }

    // 4. 密码加密
    let password_hash = match bcrypt::hash(&body.password, 4) {
        Ok(h) => h,
        Err(e) => {
            tracing::error!("trial/claim bcrypt failed: {}", e);
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "password_hash_failed"}))).into_response();
        }
    };

    // 5. 处理推广码
    let referred_by: Option<String> = if let Some(ref code) = body.referral_code {
        if !code.is_empty() {
            conn.query_row(
                "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
                rusqlite::params![code],
                |row| row.get(0),
            ).ok()
        } else { None }
    } else { None };

    // 6. 加密 PII 字段
    let enc_real_name = body.real_name.as_ref().map(|n| crate::encryption::encrypt(n));
    let enc_phone = body.phone.as_ref().map(|p| crate::encryption::encrypt(p));
    let phone_hash = body.phone.as_ref().map(|p| crate::encryption::sha256_hash(p));
    let bind_hash = match (&body.real_name, &body.phone) {
        (Some(n), Some(p)) => Some(crate::encryption::bind_hash(n, p)),
        _ => None,
    };

    // 7. 更新用户
    if let Err(e) = conn.execute(
        "UPDATE users SET username = ?1, password_hash = ?2, \
         real_name = COALESCE(?3, real_name), \
         phone = COALESCE(?4, phone), \
         phone_hash = COALESCE(?5, phone_hash), \
         bind_hash = COALESCE(?6, bind_hash), \
         referred_by = COALESCE(?7, referred_by) \
         WHERE id = ?8",
        rusqlite::params![
            body.username, password_hash,
            enc_real_name, enc_phone, phone_hash, bind_hash,
            referred_by, body.user_id,
        ],
    ) {
        tracing::error!("trial/claim update user failed: {}", e);
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "update_user_failed"}))).into_response();
    }

    // 8. 触发注册活动
    if let Err(e) = crate::campaign_executor::execute_campaign_trigger(
        &conn, "registration", &body.user_id, referred_by.as_deref(), None,
    ) {
        tracing::warn!("trial/claim campaign trigger failed: {}", e);
    }

    // 9. 如果有推荐人，触发推广成就
    if let Some(ref rid) = referred_by {
        if !rid.is_empty() {
            crate::achievement_engine::publish(
                &conn,
                crate::achievement_engine::AppEvent::ReferralRegistered { user_id: rid.clone() },
            );
        }
    }

    // 10. 删除旧 token、创建新 token
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
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "create_token_failed"}))).into_response();
    }

    tracing::info!("trial/claim: user_id={}, new_username={}", body.user_id, body.username);

    (StatusCode::OK, Json(json!({
        "token": new_token,
        "username": body.username,
    }))).into_response()
}
