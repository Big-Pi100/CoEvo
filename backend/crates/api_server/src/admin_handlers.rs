//! Admin API handlers
use axum::{
    extract::{Path, Query},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
// 🔴 2026-09-29：`sha2::Digest` / `guard_user!` 随 K12 guardian 退役而不再需要
use crate::encryption;

pub(crate) fn ok(v: serde_json::Value) -> axum::response::Response {
    Json(v).into_response()
}
pub(crate) fn err(code: StatusCode, msg: &str) -> axum::response::Response {
    (code, Json(serde_json::json!({"error": msg}))).into_response()
}

fn conn() -> crate::db_pool::DbConn {
    crate::db_pool::get_conn()
}

/// 验证 admin_users 身份（super/service）。guardian/tutor 已移入 users 表，不走此路径。
pub fn verify_admin(headers: &HeaderMap) -> Result<(String, String), axum::response::Response> {
    let admin_key = std::env::var("COEVO_ADMIN_KEY").unwrap_or_default();
    if !admin_key.is_empty()
        && headers
            .get("x-admin-key")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            == admin_key
    {
        return Ok(("super".into(), "super".into()));
    }
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if token.is_empty() {
        return Err(err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    let result: Option<(String, String, String)> = conn()
        .query_row(
            "SELECT id, role, status FROM admin_users WHERE password_hash=?1",
            rusqlite::params![token],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .ok();
    match result {
        Some((id, role, status)) => {
            if status == "active" {
                Ok((id, role))
            } else {
                Err(err(StatusCode::FORBIDDEN, "pending_approval"))
            }
        }
        None => Err(err(StatusCode::UNAUTHORIZED, "unauthorized")),
    }
}

/// 验证 guardian/tutor 用户身份（从 users 表和 tokens 表认证）。
/// guardian/tutor 通过 /api/auth/login 登录，使用 tokens 表中的 token。
/// 同时兼容 admin_users（super/service）的旧认证路径。
pub fn verify_guardian_or_admin(
    headers: &HeaderMap,
) -> Result<(String, String), axum::response::Response> {
    // 先尝试 admin_users 认证（super/service）
    let admin_key = std::env::var("COEVO_ADMIN_KEY").unwrap_or_default();
    if !admin_key.is_empty()
        && headers
            .get("x-admin-key")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            == admin_key
    {
        return Ok(("super".into(), "super".into()));
    }
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if token.is_empty() {
        return Err(err(StatusCode::UNAUTHORIZED, "unauthorized"));
    }

    // 1. 检查 admin_users（super/service）
    if let Some(result) = conn()
        .query_row::<(String, String, String), _, _>(
            "SELECT id, role, status FROM admin_users WHERE password_hash=?1",
            rusqlite::params![token],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .ok()
    {
        let (id, role, status) = result;
        if status == "active" {
            return Ok((id, role));
        }
        return Err(err(StatusCode::FORBIDDEN, "pending_approval"));
    }

    // 2. 检查 users 表（guardian/tutor）—— 从 tokens 表验证 token，然后查 role
    if let Ok(token_row) = conn().query_row::<String, _, _>(
        "SELECT t.user_id FROM tokens t WHERE t.token = ?1",
        rusqlite::params![token],
        |row| Ok(row.get(0)?),
    ) {
        // token 有效，查 users 表的 role
        if let Ok(role) = conn().query_row(
            "SELECT role FROM users WHERE id = ?1 AND (role = 'guardian' OR role = 'tutor')",
            rusqlite::params![token_row],
            |row| row.get::<_, String>(0),
        ) {
            return Ok((token_row, role));
        }
        return Err(err(StatusCode::FORBIDDEN, "not_guardian_or_tutor"));
    }

    Err(err(StatusCode::UNAUTHORIZED, "unauthorized"))
}

fn require_role(
    headers: &HeaderMap,
    allowed: &[&str],
) -> Result<(String, String), axum::response::Response> {
    let (id, role) = verify_admin(headers)?;
    if allowed.contains(&role.as_str()) || role == "super" {
        Ok((id, role))
    } else {
        Err(err(StatusCode::FORBIDDEN, "forbidden"))
    }
}

macro_rules! guard {
    // admin_users 专用
    ($headers:expr, $allowed:expr) => {
        match require_role($headers, $allowed) {
            Ok(r) => r,
            Err(e) => return e,
        }
    };
    ($headers:expr) => {
        match verify_admin($headers) {
            Ok(r) => r,
            Err(e) => return e,
        }
    };
}

fn mask_phone(p: &str) -> String {
    if p.len() >= 7 {
        format!("{}****{}", &p[..3], &p[p.len() - 4..])
    } else {
        "***".into()
    }
}
fn mask_name(n: &str) -> String {
    n.chars()
        .next()
        .map(|c| format!("{}*", c))
        .unwrap_or("*".into())
}

/// 邮箱脱敏（`zhangsan@example.com` → `z***@example.com`）。
///
/// 🔑 **与 `mask_phone` / `mask_name` 同族**（管理端的 PII 脱敏），所以放在一起。
///    2026-09-29「改用邮箱注册」后，它取代了原来对 `real_name` / `phone` 的脱敏。
///
/// 🔑 `pub(crate)` —— `distribution_handler` 的分销列表也用它
///    （**一处权威**：两处各写一份脱敏规则，迟早会出现「同一个人在两页脱敏方式不同」）。
pub(crate) fn mask_email(email: &str) -> String {
    match email.split_once('@') {
        Some((local, domain)) => {
            let first = local.chars().next().unwrap_or('*');
            format!("{}***@{}", first, domain)
        }
        // 不像邮箱（存量/异常数据）→ 只留首字符
        None => email
            .chars()
            .next()
            .map(|c| format!("{}***", c))
            .unwrap_or_else(|| "***".into()),
    }
}

/// Decrypt a PII field if it looks encrypted; return as-is if already plaintext.
fn decrypt_maybe(enc: &str) -> String {
    if encryption::is_encrypted(enc) {
        let dec = encryption::decrypt(enc);
        if dec.is_empty() {
            tracing::warn!("Failed to decrypt PII field, falling back to placeholder");
            "***".to_string()
        } else {
            dec
        }
    } else {
        enc.to_string()
    }
}

// ── Login ──
#[derive(Deserialize)]
pub struct AdminLoginInput {
    pub username: String,
    pub password: String,
}
pub async fn admin_login(Json(input): Json<AdminLoginInput>) -> impl IntoResponse {
    tracing::info!("admin_login: username={}", input.username);
    let c = conn();
    let r: Option<(String, String, String, String)> = c
        .query_row(
            "SELECT id,role,status,password_hash FROM admin_users WHERE username=?1",
            rusqlite::params![input.username],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .ok();
    match r {
        Some((id, role, status, hash)) => {
            let hash_prefix = if hash.len() > 12 { &hash[..12] } else { &hash };
            tracing::info!(
                "admin_login: id={}, role={}, status={}, hash_prefix={}",
                id,
                role,
                status,
                hash_prefix
            );
            if status == "active" && bcrypt::verify(&input.password, &hash).unwrap_or(false) {
                ok(serde_json::json!({"token":hash,"role":role,"admin_id":id}))
            } else if status == "active" {
                err(StatusCode::UNAUTHORIZED, "invalid_credentials")
            } else if status == "pending" {
                err(StatusCode::FORBIDDEN, "pending_approval")
            } else if status == "rejected" {
                err(StatusCode::FORBIDDEN, "rejected")
            } else {
                err(StatusCode::UNAUTHORIZED, "invalid_credentials")
            }
        }
        None => err(StatusCode::UNAUTHORIZED, "invalid_credentials"),
    }
}

// ── Register ──
// 注意: self-register endpoint。guardian/tutor 已移入 users 表，
// admin_users 只保留 super/service，均由超管创建。
#[derive(Deserialize)]
pub struct AdminRegisterInput {
    pub username: String,
    pub password: String,
    pub role: String,
    pub real_name: String,
    pub phone: String,
    pub id_number: Option<String>,
    pub apply_reason: Option<String>,
    pub registered_from: Option<String>,
    pub guardian_declaration: Option<String>,
}
pub async fn admin_register(Json(input): Json<AdminRegisterInput>) -> impl IntoResponse {
    tracing::info!("admin_register: username={}", input.username);
    // admin_users 只允许 super/service，guardian/tutor 已移入 users 表
    return err(
        StatusCode::BAD_REQUEST,
        "self_register_disabled_contact_admin",
    );
}
// ── User Search ──
#[derive(Deserialize)]
pub struct AdminUsersQuery {
    pub q: String,
    pub page: Option<i64>,
    pub sort: Option<String>,
    pub include_deleted: Option<bool>,
}
pub async fn admin_users_handler(
    headers: HeaderMap,
    Query(query): Query<AdminUsersQuery>,
) -> impl IntoResponse {
    tracing::info!("admin_users_handler: q={}, page={:?}", query.q, query.page);
    // Rate limit: 30 requests per minute per admin
    if let Err(e) = crate::rate_limiter::check_rate_limit(&headers, 30, 60) {
        return e;
    }
    let (_, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => {
            return e;
        }
    };
    if role == "guardian" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let page = query.page.unwrap_or(1).max(1);
    let sort = query.sort.unwrap_or_default();
    let limit: i64 = 20;
    let offset = (page - 1) * limit;

    // Build WHERE clause
    let mut where_parts: Vec<String> = Vec::new();
    if !query.include_deleted.unwrap_or(false) {
        where_parts.push("u.deleted_at IS NULL".to_string());
    }
    if !query.q.is_empty() {
        let p = query.q.replace('\'', "''");
        where_parts.push(format!(
            "(u.id LIKE '%{}%' OR u.username LIKE '%{}%' OR u.display_name LIKE '%{}%')",
            p, p, p
        ));
    }
    let where_clause = if where_parts.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", where_parts.join(" AND "))
    };

    // Count total
    let total: i64 = c
        .query_row(
            &format!("SELECT COUNT(*) FROM users u {}", where_clause),
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    // Sort: expiring soon first. ORDER BY 1) null expires last, 2) expires ASC
    let no_search = query.q.is_empty();
    let (join_clause, order_clause) = if sort == "expiring" || no_search {
        (
            String::new(),
            "ORDER BY u.subscription_expires IS NULL, u.subscription_expires ASC".to_string(),
        )
    } else {
        (String::new(), "ORDER BY u.created_at DESC".to_string())
    };

    let sql = format!("SELECT u.id,u.username,u.display_name,u.email,u.created_at,u.streak_days,u.deleted_at FROM users u {} {} {} LIMIT ?1 OFFSET ?2", join_clause, where_clause, order_clause);
    tracing::debug!("admin_users SQL: {}", sql);
    let mut stmt = match c.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("admin_users prepare failed: {} — SQL: {}", e, sql);
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("SQL error: {}", e),
            );
        }
    };
    let users: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![limit, offset], |row| {
        let uid: String = row.get(0)?;
        // 🔴 2026-09-29：学习状态已迁端侧 `user.db` → 后端不再持有卡片/复习数据，统计恒为 0
        let cards: i64 = 0;
        let reviews: i64 = 0;
        let expires: Option<String> = c.query_row("SELECT subscription_expires FROM users WHERE id=?1", rusqlite::params![&uid], |r| r.get(0)).ok();
        let is_super = role == "super";
        // 🔴 2026-09-29：原 `real_name` + `phone` 两列 → `email` 一列。
        //    「super 看完整 / 其他角色看脱敏」这层**分级可见性语义保持不变**，
        //    只是对象从实名+手机号换成了邮箱。
        let email: Option<String> = row.get(3)?;
        // 🔴 2026-09-29 已退役：guardian / tutor 绑定查询（依赖已删除的 `guardian_assignments` 表）
        //     JSON 字段保留（值为 null），兼容 admin 前端。
        let (g_id, t_id): (Option<String>, Option<String>) = (None, None);
        let (g_name_dec, g_phone_dec, t_name_dec, t_phone_dec): (Option<String>, Option<String>, Option<String>, Option<String>) = (None, None, None, None);
        Ok(serde_json::json!({
            "user_id":uid, "username": row.get::<_,String>(1)?, "display_name": row.get::<_,Option<String>>(2)?,
            "email": if is_super { email.clone() } else { email.as_ref().map(|e| mask_email(e)) },
            "email_masked": email.as_ref().map(|e| mask_email(e)),
            "created_at": row.get::<_,String>(4)?, "streak_days": row.get::<_,i32>(5)?, "deleted_at": row.get::<_,Option<String>>(6)?,
            "card_count": cards, "review_count": reviews, "subscription_expires": expires,
            "guardian_id": g_id, "guardian_name": g_name_dec, "guardian_phone_masked": g_phone_dec.as_ref().map(|p| mask_phone(p)),
            "tutor_id": t_id, "tutor_name": t_name_dec, "tutor_phone_masked": t_phone_dec.as_ref().map(|p| mask_phone(p)),
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();
    let total_pages = ((total + limit - 1) / limit).max(1);
    ok(serde_json::json!({"users":users, "total":total, "page":page, "total_pages":total_pages}))
}

// ── User Detail ──
pub async fn admin_user_detail(headers: HeaderMap, Path(uid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_user_detail: user_id={}", uid);
    let _ = verify_admin(&headers);
    let c = conn();
    let u: Option<serde_json::Value> = c.query_row("SELECT id,username,display_name,email,created_at,streak_days,last_active_date FROM users WHERE id=?1", rusqlite::params![&uid], |row| {
        let uid2: String = row.get(0)?;
        // 🔴 2026-09-29：学习状态已迁端侧 → 统计恒为 0
        let cards: i64 = 0;
        let reviews: i64 = 0;
        // 🔴 2026-09-29：`real_name` + `phone` → `email`（详情页是超管视角，不做脱敏）
        let email: Option<String> = row.get(3)?;
        let expires: Option<String> = c.query_row("SELECT subscription_expires FROM users WHERE id=?1", rusqlite::params![&uid2], |r| r.get(0)).ok();
        Ok(serde_json::json!({"user_id":uid2,"username":row.get::<_,String>(1)?,"display_name":row.get::<_,Option<String>>(2)?,
            "email":email,
            "created_at":row.get::<_,String>(4)?,"streak_days":row.get::<_,i32>(5)?,"last_active_date":row.get::<_,Option<String>>(6)?,"card_count":cards,"review_count":reviews,"subscription_expires":expires}))
    }).ok();
    match u {
        Some(v) => ok(v),
        None => err(StatusCode::NOT_FOUND, "not_found"),
    }
}

pub async fn admin_delete_user(headers: HeaderMap, Path(uid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_delete_user: user_id={}", uid);
    let (_, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => {
            return e;
        }
    };
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let now = chrono::Utc::now().timestamp().to_string();
    let rows = c
        .execute(
            "UPDATE users SET deleted_at=?1 WHERE id=?2 AND deleted_at IS NULL",
            rusqlite::params![now, &uid],
        )
        .unwrap_or(0);
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'soft_delete_user',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), "super", &uid, serde_json::json!({"deleted_at":now}).to_string(), now]);
    if rows > 0 {
        ok(serde_json::json!({"status":"deleted","deleted_at":now}))
    } else {
        err(StatusCode::NOT_FOUND, "already_deleted_or_not_found")
    }
}

pub async fn admin_restore_user(headers: HeaderMap, Path(uid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_restore_user: user_id={}", uid);
    let (_, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => {
            return e;
        }
    };
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let rows = c
        .execute(
            "UPDATE users SET deleted_at=NULL WHERE id=?1 AND deleted_at IS NOT NULL",
            rusqlite::params![&uid],
        )
        .unwrap_or(0);
    if rows > 0 {
        let now = chrono::Utc::now().timestamp().to_string();
        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'restore_user',?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "super", &uid, serde_json::json!({"restored_at":now}).to_string(), now]);
        ok(serde_json::json!({"status":"restored"}))
    } else {
        err(StatusCode::NOT_FOUND, "not_found_or_not_deleted")
    }
}

/// POST /api/admin/users/{user_id}/hard-delete — 超管永久删除用户（清库+归档）
/// 归档记录写入 data/deleted_users.ndjson 文件，不留在数据库内
pub async fn admin_hard_delete_user(
    headers: HeaderMap,
    Path(uid): Path<String>,
) -> impl IntoResponse {
    tracing::info!("admin_hard_delete_user: user_id={}", uid);
    let (_, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => {
            return e;
        }
    };
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let now = chrono::Utc::now().timestamp().to_string();
    let now_rfc = chrono::Utc::now().to_rfc3339();

    // 1. 读取用户归档信息（在删除之前）
    //
    // 🔴 2026-09-29：`u.phone_hash` → `u.email`（硬删除归档时留个可辨识的登录标识）。
    //    ⚠️ 原来存的是 **phone_hash（哈希）**，现在直接存 email（明文）——
    //       这是有意放宽，不是疏漏：归档文件 `deleted_users.ndjson` 是**运维私有的本地文件**，
    //       而 phone_hash 那种「存哈希只为让运维自己也认不出是谁」的做法，
    //       在改邮箱后会让归档条目**完全没有辨识度**（只剩 username，而它只是 `u_xxx` 内部 id）。
    let user_info: Result<(String, Option<String>, Option<String>, Option<String>, Option<String>), _> = c.query_row(
        "SELECT u.username, u.display_name, u.email, u.subscription_expires, up_act.value
         FROM users u
         LEFT JOIN user_preferences up_act ON u.id=up_act.user_id AND up_act.key='subscription_activated_at'
         WHERE u.id=?1",
        rusqlite::params![&uid],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
        )),
    );

    let (username, display_name, email, sub_expires, sub_activated) = match user_info {
        Ok(info) => info,
        Err(_) => return err(StatusCode::NOT_FOUND, "user_not_found"),
    };

    // 2. 写入归档文件 data/deleted_users.ndjson
    let archive_id = uuid::Uuid::new_v4().to_string();
    let archive_entry = serde_json::json!({
        "archive_id": archive_id,
        "original_user_id": uid,
        "username": username,
        "display_name": display_name,
        "email": email,
        "subscription_expires": sub_expires,
        "subscription_activated_at": sub_activated,
        "deleted_by": "super",
        "deleted_at": now,
        "deleted_at_rfc3339": now_rfc,
    });
    let _ = std::fs::write(
        std::path::Path::new("data").join("deleted_users.ndjson"),
        format!(
            "{}\n",
            serde_json::to_string(&archive_entry).unwrap_or_default()
        ),
    );

    // 3. 删除关联数据（按外键顺序防止约束冲突）
    // 🔴 2026-09-29：旧学习链（user_cards / card_memory / review_log / conversations /
    //     plan_runs / user_plan_progress / guardian_assignments / achievements）已退役，
    //     这些表已删除 → 级联删除只剩现役表。
    let tables = [
        "DELETE FROM user_preferences WHERE user_id=?1",
        "DELETE FROM tokens WHERE user_id=?1",
        "DELETE FROM users WHERE id=?1",
    ];
    for sql in &tables {
        let _ = c.execute(sql, rusqlite::params![&uid]);
    }

    // 4. 审计日志
    let _ = c.execute(
        "INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'hard_delete_user',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), "super", &uid, serde_json::json!({"archive_id": archive_id, "deleted_at": now}).to_string(), now],
    );

    ok(serde_json::json!({"status":"hard_deleted", "archive_id": archive_id}))
}

// 🔴 2026-09-29 已退役：`admin_reveal_phone`（两步揭看手机号）+ `RevealPhoneQuery`
//
// 它唯一的用途是「管理端看清用户的手机号」（先脱敏、再二次揭看明文并写审计日志）。
// `users.phone` 列已删 → 无数据可揭看 → 整块退役，路由同步移除。
//
// 🔑 这顺带消掉了一处**最敏感的隐私能力**（把用户手机号明文展示给运营），
//    与「改用邮箱注册」的方向一致。

/// 天数增量延期：读取当前到期日，从原值或今天累加天数，写入 DB
fn apply_days_extension(c: &rusqlite::Connection, uid: &str, days: i64) -> Result<String, String> {
    let current: String = c
        .query_row(
            "SELECT COALESCE(subscription_expires,'') FROM users WHERE id=?1",
            rusqlite::params![uid],
            |row| row.get(0),
        )
        .unwrap_or_default();

    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let base = if current.is_empty() || current.as_str() < today.as_str() {
        today.clone()
    } else {
        current.clone()
    };
    let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
    let new_date = base_date + chrono::Duration::days(days);
    let new_expires = new_date.format("%Y-%m-%d").to_string();

    c.execute(
        "UPDATE users SET subscription_expires=?1 WHERE id=?2",
        rusqlite::params![new_expires, uid],
    )
    .map_err(|e| format!("db_update: {e}"))?;
    Ok(new_expires)
}

// ── Set Subscription ──
// Super: direct apply. Service: creates pending request.
#[derive(Deserialize)]
pub struct SetSubInput {
    pub subscription_expires: String,
    pub days: Option<i64>,
}

/// 验证并规范化到期日期字符串，返回 %Y-%m-%d 格式或 None
fn normalize_expires(input: &str) -> Option<String> {
    // 支持 YYYY-MM-DD 和 YYYY-MM-DDThh:mm:ssZ
    if input.len() == 10 && input.as_bytes().get(4) == Some(&b'-') {
        return Some(input.to_string());
    }
    chrono::NaiveDateTime::parse_from_str(input, "%Y-%m-%dT%H:%M:%S")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(input, "%Y-%m-%dT%H:%M:%SZ"))
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(input, "%Y-%m-%d %H:%M:%S"))
        .ok()
        .map(|dt| dt.format("%Y-%m-%d").to_string())
}

fn has_permission(admin_id: &str, perm_key: &str) -> bool {
    let perms_str: Option<String> = conn()
        .query_row(
            "SELECT permissions FROM admin_users WHERE id=?1",
            rusqlite::params![admin_id],
            |row| row.get(0),
        )
        .ok()
        .flatten();
    let perms: serde_json::Value = perms_str
        .as_ref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or(serde_json::Value::Object(Default::default()));
    perms
        .get(perm_key)
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

pub async fn admin_set_subscription(
    headers: HeaderMap,
    Path(uid): Path<String>,
    Json(input): Json<SetSubInput>,
) -> impl IntoResponse {
    tracing::info!("admin_set_subscription: user_id={}", uid);
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    // service with permission applies directly like super
    let can_direct =
        role == "super" || (role == "service" && has_permission(&admin_id, "set_expiry"));
    if role == "service" && !has_permission(&admin_id, "set_expiry") {
        return err(StatusCode::FORBIDDEN, "no_permission");
    }

    let c = conn();
    let now = chrono::Utc::now().timestamp();

    if can_direct {
        // 有 days 参数 → 走增量累加（安全路径）
        if let Some(days) = input.days {
            if days > 0 {
                match apply_days_extension(&c, &uid, days) {
                    Ok(new_expires) => {
                        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'set_subscription',?3,?4,?5)",
                            rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"days":days,"expires":new_expires}).to_string(), now]);
                        return ok(serde_json::json!({"status":"ok","expires":new_expires}));
                    }
                    Err(e) => {
                        return err(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            &format!("extend_failed: {e}"),
                        )
                    }
                }
            }
        }

        // 无 days 参数 → 校验格式后直接设值（覆盖模式）
        let normalized = normalize_expires(&input.subscription_expires);
        let normalized = match normalized {
            Some(d) => d,
            None => return err(StatusCode::BAD_REQUEST, "invalid_date_format"),
        };
        let _ = c.execute(
            "UPDATE users SET subscription_expires=?1 WHERE id=?2",
            rusqlite::params![normalized, uid],
        );
        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'set_subscription',?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"expires":normalized}).to_string(), now]);
        ok(serde_json::json!({"status":"ok"}))
    } else {
        // Create pending request
        let req_id = uuid::Uuid::new_v4().to_string();
        let pkg = "custom";
        let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,'admin',?5,'pending',?6)",
            rusqlite::params![req_id, uid, admin_id, pkg, serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
        ok(serde_json::json!({"request_id":req_id,"status":"pending"}))
    }
}

// ── Quick extend (creates request for non-super) ──
pub async fn admin_quick_extend(
    headers: HeaderMap,
    Path(uid): Path<String>,
    Json(input): Json<SetSubInput>,
) -> impl IntoResponse {
    tracing::info!("admin_quick_extend: user_id={}, days={:?}", uid, input.days);
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }

    let c = conn();
    let now = chrono::Utc::now().timestamp();

    // 有 days 参数 → 后端算到期日（增量累加，避免前端计算错误）
    if let Some(days) = input.days {
        if days <= 0 {
            return err(StatusCode::BAD_REQUEST, "days_must_be_positive");
        }

        if role == "super" {
            match apply_days_extension(&c, &uid, days) {
                Ok(new_expires) => {
                    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend',?3,?4,?5)",
                        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"days":days,"expires":new_expires}).to_string(), now]);
                    return ok(serde_json::json!({"status":"ok","expires":new_expires}));
                }
                Err(e) => {
                    return err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        &format!("extend_failed: {e}"),
                    )
                }
            }
        }

        // service: check permission by day range
        let perm_key = match days {
            1..=7 => "extend_7d",
            8..=30 => "extend_30d",
            _ => "extend_365d",
        };
        if has_permission(&admin_id, perm_key) {
            match apply_days_extension(&c, &uid, days) {
                Ok(new_expires) => {
                    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend',?3,?4,?5)",
                        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"days":days,"expires":new_expires}).to_string(), now]);
                    return ok(serde_json::json!({"status":"ok","expires":new_expires}));
                }
                Err(e) => {
                    return err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        &format!("extend_failed: {e}"),
                    )
                }
            }
        }

        // service without permission: create pending request
        let pkg = format!("{}d", days);
        let req_id = uuid::Uuid::new_v4().to_string();
        let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,'admin',?5,'pending',?6)",
            rusqlite::params![req_id, uid, admin_id, pkg, serde_json::json!({"days":days}).to_string(), now]);
        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend_pending',?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"days":days}).to_string(), now]);
        return ok(serde_json::json!({"request_id":req_id,"status":"pending"}));
    }

    // 无 days 参数 → 降级：转为 pending request，让有权限的人审批
    let req_id = uuid::Uuid::new_v4().to_string();
    let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,'admin',?5,'pending',?6)",
        rusqlite::params![req_id, uid, admin_id, "custom", serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend_pending',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
    ok(serde_json::json!({"request_id":req_id,"status":"pending"}))
}

#[derive(Deserialize)]
pub struct CreateSubReqInput {
    pub target_user_id: String,
    pub package: String,
    pub channel: Option<String>,
    pub note: Option<String>,
}
pub async fn admin_create_subscription_request(
    headers: HeaderMap,
    Json(input): Json<CreateSubReqInput>,
) -> impl IntoResponse {
    tracing::info!(
        "admin_create_subscription_request: target_user_id={}, pkg={}",
        input.target_user_id,
        input.package
    );
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,?5,?6,'pending',?7)",
        rusqlite::params![id, input.target_user_id, admin_id, input.package, input.channel, input.note, now]);
    ok(serde_json::json!({"request_id":id,"status":"pending"}))
}

// ── Batch extend ──
#[derive(Deserialize)]
pub struct BatchSubInput {
    pub user_ids: Vec<String>,
    pub days: i64,
}
pub async fn admin_batch_subscription(
    headers: HeaderMap,
    Json(input): Json<BatchSubInput>,
) -> impl IntoResponse {
    tracing::info!(
        "admin_batch_subscription: user_count={}, days={}",
        input.user_ids.len(),
        input.days
    );
    let (admin_id, role) = guard!(&headers, &[]);
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let now = chrono::Utc::now().timestamp();
    for uid in &input.user_ids {
        let current: String = c
            .query_row(
                "SELECT COALESCE(subscription_expires,'') FROM users WHERE id=?1",
                rusqlite::params![uid],
                |row| row.get(0),
            )
            .unwrap_or_default();
        let new_exp = if current.is_empty() {
            (chrono::Utc::now() + chrono::Duration::days(input.days))
                .format("%Y-%m-%d")
                .to_string()
        } else {
            (chrono::NaiveDate::parse_from_str(&current, "%Y-%m-%d")
                .unwrap_or_else(|_| chrono::Utc::now().date_naive())
                + chrono::Duration::days(input.days))
            .format("%Y-%m-%d")
            .to_string()
        };
        let _ = c.execute(
            "UPDATE users SET subscription_expires=?1 WHERE id=?2",
            rusqlite::params![new_exp, uid],
        );
    }
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'batch_set_subscription',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, format!("{} users",input.user_ids.len()), serde_json::json!({"ids":input.user_ids,"days":input.days}).to_string(), now]);
    ok(serde_json::json!({"status":"ok","count":input.user_ids.len()}))
}

#[derive(Deserialize)]
pub struct ListReqsQuery {
    pub status: Option<String>,
}
pub async fn admin_list_subscription_requests(
    headers: HeaderMap,
    Query(q): Query<ListReqsQuery>,
) -> impl IntoResponse {
    tracing::info!("admin_list_subscription_requests: status={:?}", q.status);
    let _ = verify_admin(&headers);
    let filter = q.status.unwrap_or_else(|| "%".into());
    let c2 = conn();
    let mut stmt = c2.prepare("SELECT sr.id,sr.target_user_id,sr.requested_by,sr.package,sr.channel,sr.note,sr.status,sr.reject_reason,sr.requested_at,sr.reviewed_at,u.username,au.real_name FROM subscription_requests sr JOIN users u ON sr.target_user_id=u.id JOIN admin_users au ON sr.requested_by=au.id WHERE CASE WHEN ?1='%' THEN 1 ELSE sr.status=?1 END ORDER BY sr.requested_at DESC LIMIT 50").unwrap();
    let reqs: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![filter], |row| {
        let rname_raw: Option<String> = row.get(11)?;
        Ok(serde_json::json!({
        "id":row.get::<_,String>(0)?,"target_user_id":row.get::<_,String>(1)?,"requested_by":row.get::<_,String>(2)?,"package":row.get::<_,String>(3)?,"channel":row.get::<_,Option<String>>(4)?,"note":row.get::<_,Option<String>>(5)?,"status":row.get::<_,String>(6)?,"reject_reason":row.get::<_,Option<String>>(7)?,"requested_at":row.get::<_,String>(8)?,"reviewed_at":row.get::<_,Option<String>>(9)?,"target_username":row.get::<_,String>(10)?,"requester_name":rname_raw.as_ref().map(|v|decrypt_maybe(v))
    }))}).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"requests":reqs}))
}

// ── Approve/Reject ──
#[derive(Deserialize)]
pub struct ReviewInput {
    pub reject_reason: Option<String>,
}
pub async fn admin_approve_request(
    headers: HeaderMap,
    Path(req_id): Path<String>,
) -> impl IntoResponse {
    review_subscription(&headers, &req_id, "approved", None).await
}
pub async fn admin_reject_request(
    headers: HeaderMap,
    Path(req_id): Path<String>,
    Json(input): Json<ReviewInput>,
) -> impl IntoResponse {
    review_subscription(&headers, &req_id, "rejected", input.reject_reason).await
}

async fn review_subscription(
    headers: &HeaderMap,
    req_id: &str,
    status: &str,
    reason: Option<String>,
) -> axum::response::Response {
    tracing::info!("review_subscription: req_id={}, status={}", req_id, status);
    let (admin_id, role) = guard!(headers);
    // Check permission: super always ok, service needs can_approve
    if role != "super" {
        let perms_str: Option<String> = conn()
            .query_row(
                "SELECT permissions FROM admin_users WHERE id=?1",
                rusqlite::params![admin_id],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        let perms: serde_json::Value = perms_str
            .as_ref()
            .map(|s| serde_json::from_str(s).unwrap_or_default())
            .unwrap_or(serde_json::Value::Object(Default::default()));
        let can_approve = perms
            .get("can_approve")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if !can_approve {
            return err(StatusCode::FORBIDDEN, "forbidden");
        }
    }
    let c = conn();
    let now = chrono::Utc::now().timestamp();
    let info: Option<(String,String)> = c.query_row("SELECT target_user_id,package FROM subscription_requests WHERE id=?1 AND status='pending'", rusqlite::params![req_id], |row| Ok((row.get(0)?,row.get(1)?))).ok();
    match info {
        Some((uid, pkg)) => {
            let _ = c.execute("UPDATE subscription_requests SET status=?1,reviewed_by=?2,reject_reason=?3,reviewed_at=?4 WHERE id=?5", rusqlite::params![status,admin_id,reason,now,req_id]);
            if status == "approved" {
                let days: i64 = match pkg.as_str() {
                    "30d" => 30,
                    "90d" => 90,
                    "365d" => 365,
                    _ => {
                        // Try parsing "Xd" format (7d, 14d, etc.), fallback to 30
                        let trimmed = pkg.trim_end_matches('d');
                        trimmed.parse::<i64>().unwrap_or(30)
                    }
                };
                // Calculate from current expiry, not from today
                let current: String = c
                    .query_row(
                        "SELECT COALESCE(subscription_expires,'') FROM users WHERE id=?1",
                        rusqlite::params![&uid],
                        |row| row.get(0),
                    )
                    .unwrap_or_default();
                let exp = if current.is_empty() {
                    (chrono::Utc::now() + chrono::Duration::days(days))
                        .format("%Y-%m-%d")
                        .to_string()
                } else {
                    // Parse current expiry, add days
                    let parsed = chrono::NaiveDate::parse_from_str(&current, "%Y-%m-%d")
                        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
                    (parsed + chrono::Duration::days(days))
                        .format("%Y-%m-%d")
                        .to_string()
                };
                let _ = c.execute(
                    "UPDATE users SET subscription_expires=?1 WHERE id=?2",
                    rusqlite::params![&exp, &uid],
                );
            }
            let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,request_id,detail,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)",
                rusqlite::params![uuid::Uuid::new_v4().to_string(),admin_id,format!("{status}_subscription"),uid,req_id,serde_json::json!({"reason":reason}).to_string(),now]);
            ok(serde_json::json!({"status":status}))
        }
        None => err(StatusCode::NOT_FOUND, "not_found_or_already_reviewed"),
    }
}

// ── Admin Management ──
pub async fn admin_list_admins(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("admin_list_admins");
    let (_, _role) = guard!(&headers);
    let c2 = conn();
    // 服务人员可以看到 pending 的家长/辅导申请
    // 管理员管理：超管可以看到所有管理员账号
    let sql = "SELECT id,username,role,status,real_name,phone,registered_from,created_at,approved_at,permissions FROM admin_users WHERE role!='super' ORDER BY created_at DESC";
    let mut stmt = c2.prepare(sql).unwrap();
    let admins: Vec<serde_json::Value> = stmt.query_map([], |row| {
        let rn_raw: Option<String> = row.get(4)?;
        let ph_raw: Option<String> = row.get(5)?;
        let perms_raw: Option<String> = row.get(9)?;
        let perms: serde_json::Value = perms_raw.as_ref().map(|s| serde_json::from_str(s).unwrap_or_default()).unwrap_or(serde_json::Value::Object(Default::default()));
        Ok(serde_json::json!({
            "id":row.get::<_,String>(0)?,"username":row.get::<_,String>(1)?,"role":row.get::<_,String>(2)?,"status":row.get::<_,String>(3)?,
            "real_name":rn_raw.as_ref().map(|v|decrypt_maybe(v)),"phone":ph_raw.as_ref().map(|v|decrypt_maybe(v)),
            "registered_from":row.get::<_,Option<String>>(6)?,"created_at":row.get::<_,String>(7)?,"approved_at":row.get::<_,Option<String>>(8)?,
            "permissions":perms,
        }))
    }).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"admins":admins}))
}
pub async fn admin_approve_admin(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_approve_admin: admin_id={}", aid);
    let (reviewer, role) = guard!(&headers);
    if role == "observer" {
        return err(StatusCode::FORBIDDEN, "observer_readonly");
    }
    // 家长/辅导申请：服务人员+超管可审批；管理员申请：仅超管
    let target_role: Option<String> = conn()
        .query_row(
            "SELECT role FROM admin_users WHERE id=?1 AND status='pending'",
            rusqlite::params![&aid],
            |row| row.get(0),
        )
        .ok();
    match target_role {
        Some(ref r) if r == "guardian" || r == "tutor" || role == "super" => {
            let now = chrono::Utc::now().timestamp();
            let c = conn();
            let _ = c.execute("UPDATE admin_users SET status='active',approved_at=?1,created_by=?2 WHERE id=?3 AND status='pending'", rusqlite::params![now,reviewer,aid]);
            // 🔴 2026-09-29 已退役：家长审批通过时自动创建 `guardian_assignments` 绑定
            //     （K12 体系已整体清退，该表已删除）
            ok(serde_json::json!({"status":"approved"}))
        }
        Some(_) => err(StatusCode::FORBIDDEN, "only_super_admin_approval"),
        None => err(StatusCode::NOT_FOUND, "not_found"),
    }
}
pub async fn admin_reject_admin(
    headers: HeaderMap,
    Path(aid): Path<String>,
    Json(input): Json<ReviewInput>,
) -> impl IntoResponse {
    tracing::info!("admin_reject_admin: admin_id={}", aid);
    let (reviewer, role) = guard!(&headers);
    if role == "observer" {
        return err(StatusCode::FORBIDDEN, "observer_readonly");
    }
    let target_role: Option<String> = conn()
        .query_row(
            "SELECT role FROM admin_users WHERE id=?1 AND status='pending'",
            rusqlite::params![&aid],
            |row| row.get(0),
        )
        .ok();
    match target_role {
        Some(ref r) if r == "guardian" || r == "tutor" || role == "super" => {
            let c = conn();
            let _ = c.execute("UPDATE admin_users SET status='rejected',reject_reason=?1,approved_at=?2,created_by=?3 WHERE id=?4", rusqlite::params![input.reject_reason,chrono::Utc::now().timestamp(),reviewer,aid]);
            ok(serde_json::json!({"status":"rejected"}))
        }
        Some(_) => err(StatusCode::FORBIDDEN, "only_super_admin_approval"),
        None => err(StatusCode::NOT_FOUND, "not_found"),
    }
}
pub async fn admin_disable_admin(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_disable_admin: admin_id={}", aid);
    guard!(&headers, &[]);
    let _ = conn().execute(
        "UPDATE admin_users SET status='disabled' WHERE id=?1",
        rusqlite::params![aid],
    );
    ok(serde_json::json!({"status":"disabled"}))
}

pub async fn admin_enable_admin(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_enable_admin: admin_id={}", aid);
    guard!(&headers, &[]);
    let _ = conn().execute(
        "UPDATE admin_users SET status='active' WHERE id=?1",
        rusqlite::params![aid],
    );
    ok(serde_json::json!({"status":"active"}))
}

#[derive(Deserialize)]
pub struct CreateAdminInput {
    pub username: String,
    pub password: String,
    pub real_name: String,
    pub phone: String,
    pub role: String,
}
pub async fn admin_create_admin(
    headers: HeaderMap,
    Json(input): Json<CreateAdminInput>,
) -> impl IntoResponse {
    tracing::info!("admin_create_admin: username={}", input.username);
    let (_admin_id, role) = guard!(&headers);
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    if !["service", "super"].contains(&input.role.as_str()) {
        return err(StatusCode::BAD_REQUEST, "role_must_be_service_or_super");
    }
    if input.username.len() < 5 {
        return err(StatusCode::BAD_REQUEST, "username_5");
    }
    if input.password.len() < 6 {
        return err(StatusCode::BAD_REQUEST, "password_6");
    }
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let hash = bcrypt::hash(&input.password, 12).unwrap_or_default();
    let enc_real_name = encryption::encrypt(&input.real_name);
    let enc_phone = encryption::encrypt(&input.phone);
    match conn().execute(
        "INSERT INTO admin_users (id,username,password_hash,role,status,real_name,phone,created_at) VALUES (?1,?2,?3,?4,'approved',?5,?6,?7)",
        rusqlite::params![id, input.username, hash, input.role, enc_real_name, enc_phone, now],
    ) {
        Ok(_) => ok(serde_json::json!({"admin_id":id,"status":"created"})),
        Err(e) if e.to_string().contains("UNIQUE") => err(StatusCode::CONFLICT, "username_exists"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    }
}

#[derive(Deserialize)]
pub struct ResetPasswordInput {
    pub password: String,
}
pub async fn admin_reset_password(
    headers: HeaderMap,
    Path(aid): Path<String>,
    Json(input): Json<ResetPasswordInput>,
) -> impl IntoResponse {
    tracing::info!("admin_reset_password: admin_id={}", aid);
    let (_, role) = guard!(&headers);
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    if input.password.len() < 6 {
        return err(StatusCode::BAD_REQUEST, "password_6");
    }
    let hash = bcrypt::hash(&input.password, 12).unwrap_or_default();
    let _ = conn().execute(
        "UPDATE admin_users SET password_hash=?1 WHERE id=?2",
        rusqlite::params![hash, aid],
    );
    ok(serde_json::json!({"status":"updated"}))
}

#[derive(Deserialize)]
pub struct SetPermissionsInput {
    pub permissions: serde_json::Value,
}
pub async fn admin_set_permissions(
    headers: HeaderMap,
    Path(aid): Path<String>,
    Json(input): Json<SetPermissionsInput>,
) -> impl IntoResponse {
    tracing::info!("admin_set_permissions: admin_id={}", aid);
    let (_, role) = guard!(&headers);
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let perms_str = input.permissions.to_string();
    let _ = conn().execute(
        "UPDATE admin_users SET permissions=?1 WHERE id=?2",
        rusqlite::params![perms_str, aid],
    );
    ok(serde_json::json!({"status":"updated"}))
}

// ── Audit Log ──
#[derive(Deserialize)]
pub struct AuditLogQuery {
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub admin_id: Option<String>,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub date_from: Option<String>,
    #[serde(default)]
    pub date_to: Option<String>,
    #[serde(default)]
    pub q: Option<String>,
}
pub async fn admin_audit_log(
    headers: HeaderMap,
    Query(query): Query<AuditLogQuery>,
) -> impl IntoResponse {
    tracing::info!("admin_audit_log");
    let (_, role) = guard!(&headers);
    if role != "super" && role != "service" && role != "observer" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c2 = conn();
    let mut conditions = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
    if let Some(ref uid) = query.user_id {
        conditions.push(format!("al.target_user_id LIKE ?{}", params.len() + 1));
        params.push(Box::new(format!("%{}%", uid)));
    }
    if let Some(ref aid) = query.admin_id {
        conditions.push(format!("al.admin_id LIKE ?{}", params.len() + 1));
        params.push(Box::new(format!("%{}%", aid)));
    }
    if let Some(ref a) = query.action {
        conditions.push(format!("al.action LIKE ?{}", params.len() + 1));
        params.push(Box::new(format!("%{}%", a)));
    }
    if let Some(ref d) = query.date_from {
        conditions.push(format!("al.created_at >= ?{}", params.len() + 1));
        params.push(Box::new(d.clone()));
    }
    if let Some(ref d) = query.date_to {
        conditions.push(format!("al.created_at <= ?{}", params.len() + 1));
        params.push(Box::new(format!("{}T23:59:59Z", d)));
    }
    if let Some(ref q) = query.q {
        conditions.push(format!("(al.action LIKE ?{} OR al.target_user_id LIKE ?{} OR al.detail LIKE ?{} OR au.real_name LIKE ?{})", params.len()+1, params.len()+2, params.len()+3, params.len()+4));
        let pq: String = format!("%{}%", q);
        params.push(Box::new(pq.clone()));
        params.push(Box::new(pq.clone()));
        params.push(Box::new(pq.clone()));
        params.push(Box::new(pq));
    }
    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    };
    let sql = format!("SELECT al.id,al.admin_id,al.action,al.target_user_id,al.detail,al.created_at,au.real_name FROM admin_audit_log al LEFT JOIN admin_users au ON al.admin_id=au.id{} ORDER BY al.created_at DESC LIMIT 100", where_clause);
    let mut stmt = c2.prepare(&sql).unwrap();
    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let logs: Vec<serde_json::Value> = stmt.query_map(param_refs.as_slice(), |row| {
        let aname_raw: Option<String> = row.get(6)?;
        Ok(serde_json::json!({
            "id":row.get::<_,String>(0)?,"admin_id":row.get::<_,String>(1)?,"action":row.get::<_,String>(2)?,"target_user_id":row.get::<_,Option<String>>(3)?,"detail":row.get::<_,Option<String>>(4)?,"created_at":row.get::<_,String>(5)?,"admin_name":aname_raw.as_ref().map(|v|decrypt_maybe(v))
        }))
    }).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"logs":logs}))
}

// 🔴 2026-09-29 已退役：K12 Guardian（家长/导师）一族 ——
//     `guardian_students` / `guardian_bind_request` / `guardian_reveal_phone` /
//     `guardian_student_cards` / `guardian_student_conversations` /
//     `guardian_student_conversation_detail` / `guardian_learning_summary`
//     及其 helper（`is_guardian_of` / `plan_keywords_from_goal` /
//     `card_stats_from_row` / `parse_plan_progress`）。
//     依赖已删除的表：`guardian_assignments` / `user_cards` / `conversations` /
//     `plan_runs`；K12 体系已整体清退，路由亦已移除。
// 🔴 2026-09-29 已退役：`bind_lookup_handler` + `update_user_profile_handler`
//
// | 原函数 | 用途 | 为什么删 |
// |---|---|---|
// | `bind_lookup_handler` | 凭「真实姓名 + 手机号」查用户（`bind_hash`） | 客服找回账号场景 |
// | `update_user_profile_handler` | 更新用户的实名 / 手机号 | 依赖已删列 |
//
// 两者依赖的 `users.real_name` · `phone` · `phone_hash` · `bind_hash` 四列
// 已随「改用邮箱注册」一并删除（白哥 2026-09-29）→ **整块退役，路由同步移除**。
//
// 🔑 顺带说明「客服凭姓名+手机号找回账号」这个能力的消失是**有意的**、不是遗漏：
//    它建立在实名制之上（用户忘了账号 → 报姓名 + 手机号 → 后台查到）。
//    而本产品是**个人主体、没有客服团队**（记忆：产品主体 = 个人、无公司），
//    注册也已改为邮箱 → 找回路径变成「**用注册邮箱登录**」，
//    将来的「邮箱验证 / 找回密码」属登录页批次。

// 🔴 2026-09-29 已退役：Guardian Assignment 管理（超管）—— 依赖已删除的 `guardian_assignments` 表

// ── Dashboard ──
pub async fn admin_dashboard(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("admin_dashboard");
    let _ = verify_admin(&headers);
    let c = conn();
    let now = chrono::Utc::now();
    let today_start = now.format("%Y-%m-%dT00:00:00Z").to_string();
    let _today_end = now.format("%Y-%m-%dT23:59:59Z").to_string();
    let week_end = (now + chrono::Duration::days(7))
        .format("%Y-%m-%d")
        .to_string();

    let total_users: i64 = c
        .query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))
        .unwrap_or(0);
    // 🔴 2026-09-29：旧学习链已退役（user_cards / review_log）→ 卡片/活跃/复习统计恒为 0；
    //     `users` 表相关的统计照常。
    let total_cards: i64 = 0;
    let today_users: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM users WHERE created_at >= ?1",
            rusqlite::params![today_start],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let today_active: i64 = 0;
    let today_reviews: i64 = 0;
    let expiring: Vec<serde_json::Value> = {
        let sql = "SELECT u.id, u.username, u.display_name, u.subscription_expires FROM users u WHERE u.subscription_expires IS NOT NULL AND u.subscription_expires <= ?1 AND u.subscription_expires >= date('now') ORDER BY u.subscription_expires LIMIT 20";
        let mut stmt = match c.prepare(sql) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("dashboard expiring_soon prepare failed: {}", e);
                return ok(
                    serde_json::json!({"total_users": total_users, "total_cards": total_cards, "today_new_users": today_users, "today_active_users": today_active, "today_reviews": today_reviews, "expiring_soon": []}),
                );
            }
        };
        stmt.query_map(rusqlite::params![week_end], |row| {
            Ok(serde_json::json!({
                "user_id": row.get::<_,String>(0)?,
                "username": row.get::<_,String>(1)?,
                "display_name": row.get::<_,Option<String>>(2)?,
                "expires": row.get::<_,String>(3)?,
            }))
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .collect()
    };

    ok(serde_json::json!({
        "total_users": total_users,
        "total_cards": total_cards,
        "today_new_users": today_users,
        "today_active_users": today_active,
        "today_reviews": today_reviews,
        "expiring_soon": expiring,
    }))
}

// ── Expiring Users ──
#[derive(Deserialize)]
pub struct ExpiringQuery {
    pub range: Option<String>,
}
pub async fn admin_expiring_users(
    headers: HeaderMap,
    Query(query): Query<ExpiringQuery>,
) -> impl IntoResponse {
    tracing::info!("admin_expiring_users: range={:?}", query.range);
    let _ = verify_admin(&headers);
    let range_days: i64 = match query.range.as_deref() {
        Some("today") => 0,
        Some("week") => 7,
        Some("month") => 30,
        _ => 7,
    };
    let c = conn();
    let end_offset = format!("+{} days", range_days);
    let mut stmt = c.prepare(
        "SELECT u.id, u.username, u.display_name, u.subscription_expires FROM users u \
         WHERE u.subscription_expires IS NOT NULL AND u.subscription_expires >= date('now') AND u.subscription_expires <= date('now', ?1) \
         ORDER BY u.subscription_expires LIMIT 50"
    ).unwrap();
    let users: Vec<serde_json::Value> = stmt
        .query_map(rusqlite::params![end_offset], |row| {
            Ok(serde_json::json!({
                "user_id": row.get::<_,String>(0)?,
                "username": row.get::<_,String>(1)?,
                "display_name": row.get::<_,Option<String>>(2)?,
                "expires": row.get::<_,String>(3)?,
            }))
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .collect();
    ok(serde_json::json!({"users": users}))
}

// ── CSV Export ──
pub async fn admin_users_export(
    headers: HeaderMap,
    Query(query): Query<AdminUsersQuery>,
) -> axum::response::Response {
    tracing::info!("admin_users_export: q={}", query.q);
    let (_, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => {
            return e;
        }
    };
    if role == "guardian" {
        return err(StatusCode::FORBIDDEN, "forbidden");
    }
    let c = conn();
    let pattern = if query.q.is_empty() {
        "%".to_string()
    } else {
        format!("%{}%", query.q)
    };
    let mut stmt = c.prepare(
        "SELECT u.id,u.username,u.display_name,u.email,u.created_at,u.streak_days FROM users u WHERE u.id LIKE ?1 OR u.username LIKE ?1 OR u.display_name LIKE ?1 LIMIT 200"
    ).unwrap();
    let mut csv = String::from("user_id,username,display_name,email,created_at,streak_days,card_count,review_count,subscription_expires\n");
    if let Ok(rows) = stmt.query_map(rusqlite::params![pattern], |row| {
        let uid: String = row.get(0)?;
        // 🔴 2026-09-29：学习状态已迁端侧 → 统计恒为 0（CSV 列保留，兼容前端）
        let cards: i64 = 0;
        let reviews: i64 = 0;
        let expires: String = c
            .query_row(
                "SELECT COALESCE(subscription_expires,'') FROM users WHERE id=?1",
                rusqlite::params![&uid],
                |r| r.get(0),
            )
            .unwrap_or_default();
        // 🔴 2026-09-29：`real_name` + `phone` → `email`（索引与列数同步收敛）
        let email: String = row
            .get::<_, Option<String>>(3)
            .ok()
            .flatten()
            .unwrap_or_default();
        let dn: String = row
            .get::<_, Option<String>>(2)
            .ok()
            .flatten()
            .unwrap_or_default();
        let un: String = row.get::<_, String>(1).unwrap_or_default();
        let dt: String = row.get::<_, String>(4).unwrap_or_default();
        let sd: i32 = row.get::<_, i32>(5).unwrap_or(0);
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{},{}\n",
            uid, un, dn, email, dt, sd, cards, reviews, expires
        ));
        Ok::<_, rusqlite::Error>(())
    }) {
        for _ in rows {}
    }
    (
        [
            (axum::http::header::CONTENT_TYPE, "text/csv; charset=utf-8"),
            (
                axum::http::header::CONTENT_DISPOSITION,
                "attachment; filename=\"coevo-users.csv\"",
            ),
        ],
        csv,
    )
        .into_response()
}

/// GET /api/admin/users/{user_id}/audit-log — 用户订阅操作日志
pub async fn admin_audit_log_handler(Path(user_id): Path<String>) -> impl IntoResponse {
    use axum::http::StatusCode;
    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT action, operator_id, old_expires, new_expires, amount, order_id, note, created_at
         FROM subscription_audit_log
         WHERE target_user_id = ?1
         ORDER BY created_at DESC
         LIMIT 50",
    ) {
        Ok(s) => s,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("查询失败: {}", e),
            )
                .into_response()
        }
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![user_id], |row| {
        Ok(serde_json::json!({
            "action": row.get::<_, String>(0)?,
            "operator_id": row.get::<_, Option<String>>(1)?,
            "old_expires": row.get::<_, Option<String>>(2)?,
            "new_expires": row.get::<_, String>(3)?,
            "amount": row.get::<_, i64>(4)?,
            "order_id": row.get::<_, Option<String>>(5)?,
            "note": row.get::<_, Option<String>>(6)?,
            "created_at": row.get::<_, String>(7)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("查询失败: {}", e),
            )
                .into_response()
        }
    };

    (
        StatusCode::OK,
        serde_json::json!({"logs": rows}).to_string(),
    )
        .into_response()
}
