//! Admin API handlers
use axum::{extract::{Path, Query}, http::{HeaderMap, StatusCode}, Json, response::IntoResponse};
use serde::Deserialize;
use sha2::{Sha256, Digest};
use crate::encryption;

fn ok(v: serde_json::Value) -> axum::response::Response { Json(v).into_response() }
fn err(code: StatusCode, msg: &str) -> axum::response::Response { (code, Json(serde_json::json!({"error": msg}))).into_response() }

fn conn() -> crate::db_pool::DbConn { crate::db_pool::get_conn() }

pub fn verify_admin(headers: &HeaderMap) -> Result<(String, String), axum::response::Response> {
    let admin_key = std::env::var("COEVO_ADMIN_KEY").unwrap_or_default();
    if !admin_key.is_empty() && headers.get("x-admin-key").and_then(|v| v.to_str().ok()).unwrap_or("") == admin_key {
        return Ok(("super".into(), "super".into()));
    }
    let token = headers.get("authorization").and_then(|v| v.to_str().ok()).and_then(|v| v.strip_prefix("Bearer ")).unwrap_or("");
    if token.is_empty() { return Err(err(StatusCode::UNAUTHORIZED, "unauthorized")); }
    let result: Option<(String, String, String)> = conn().query_row(
        "SELECT id, role, status FROM admin_users WHERE password_hash=?1", rusqlite::params![token],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))).ok();
    match result {
        Some((id, role, status)) => {
            if status == "active" { Ok((id, role)) }
            else { Err(err(StatusCode::FORBIDDEN, "pending_approval")) }
        }
        None => Err(err(StatusCode::UNAUTHORIZED, "unauthorized")),
    }
}

fn require_role(headers: &HeaderMap, allowed: &[&str]) -> Result<(String, String), axum::response::Response> {
    let (id, role) = verify_admin(headers)?;
    if allowed.contains(&role.as_str()) || role == "super" { Ok((id, role)) }
    else { Err(err(StatusCode::FORBIDDEN, "forbidden")) }
}

macro_rules! guard {
    ($headers:expr, $allowed:expr) => {
        match require_role($headers, $allowed) { Ok(r) => r, Err(e) => return e }
    };
    ($headers:expr) => {
        match verify_admin($headers) { Ok(r) => r, Err(e) => return e }
    };
}

fn mask_phone(p: &str) -> String { if p.len()>=7 { format!("{}****{}", &p[..3], &p[p.len()-4..]) } else { "***".into() } }
fn mask_name(n: &str) -> String { n.chars().next().map(|c| format!("{}*",c)).unwrap_or("*".into()) }

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
#[derive(Deserialize)] pub struct AdminLoginInput { pub username: String, pub password: String }
pub async fn admin_login(Json(input): Json<AdminLoginInput>) -> impl IntoResponse {
    let c = conn();
    let r: Option<(String,String,String,String)> = c.query_row("SELECT id,role,status,password_hash FROM admin_users WHERE username=?1", rusqlite::params![input.username], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?))).ok();
    match r {
        Some((id,role,status,hash)) => {
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
#[derive(Deserialize)] pub struct AdminRegisterInput { pub username: String, pub password: String, pub role: String, pub real_name: String, pub phone: String, pub id_number: Option<String>, pub apply_reason: Option<String>, pub registered_from: Option<String>, pub guardian_declaration: Option<String> }
pub async fn admin_register(Json(input): Json<AdminRegisterInput>) -> impl IntoResponse {
    if !["service","tutor","guardian"].contains(&input.role.as_str()) { return err(StatusCode::BAD_REQUEST,"invalid_role"); }
    if input.username.len() < 5 || !input.username.chars().all(|c| c.is_ascii_alphanumeric()) { return err(StatusCode::BAD_REQUEST, "username_5_alphanumeric"); }
    if input.password.len() < 6 || !input.password.chars().any(|c| c.is_ascii_alphabetic()) || !input.password.chars().any(|c| c.is_ascii_digit()) { return err(StatusCode::BAD_REQUEST, "password_6_alpha_numeric"); }
    if input.real_name.is_empty() || input.real_name.chars().count() > 4 || !input.real_name.chars().all(|c| ('\u{4e00}'..='\u{9fff}').contains(&c) || c == '·') { return err(StatusCode::BAD_REQUEST, "real_name_chinese_4chars"); }
    if !input.phone.chars().all(|c| c.is_ascii_digit()) || input.phone.len() != 11 || !input.phone.starts_with('1') { return err(StatusCode::BAD_REQUEST, "invalid_phone"); }
    if input.role == "service" { return err(StatusCode::FORBIDDEN, "service_accounts_must_be_created_by_admin"); }
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let hash = bcrypt::hash(&input.password, 12).unwrap_or_default();
    // Encrypt PII fields before storing
    let enc_real_name = encryption::encrypt(&input.real_name);
    let enc_phone = encryption::encrypt(&input.phone);
    let enc_id_number = input.id_number.as_ref().map(|v| encryption::encrypt(v));
    let enc_guardian_decl = input.guardian_declaration.as_ref().map(|v| encryption::encrypt(v));
    match conn().execute(
        "INSERT INTO admin_users (id,username,password_hash,role,status,real_name,phone,id_number,apply_reason,registered_from,guardian_declaration,created_at) VALUES (?1,?2,?3,?4,'approved',?5,?6,?7,?8,?9,?10,?11)",
        rusqlite::params![id, input.username, hash, input.role, enc_real_name, enc_phone, enc_id_number, input.apply_reason, input.registered_from, enc_guardian_decl, now],
    ) {
        Ok(_) => ok(serde_json::json!({"admin_id":id,"status":"approved"})),
        Err(e) if e.to_string().contains("UNIQUE") => err(StatusCode::CONFLICT, "username_exists"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    }
}
// ── User Search ──
#[derive(Deserialize)] pub struct AdminUsersQuery { pub q: String, pub page: Option<i64>, pub sort: Option<String>, pub include_deleted: Option<bool> }
pub async fn admin_users_handler(headers: HeaderMap, Query(query): Query<AdminUsersQuery>) -> impl IntoResponse {
    // Rate limit: 30 requests per minute per admin
    if let Err(e) = crate::rate_limiter::check_rate_limit(&headers, 30, 60) { return e; }
    let (_, role) = match verify_admin(&headers) { Ok(r) => r, Err(e) => { return e; } };
    if role == "guardian" { return err(StatusCode::FORBIDDEN, "forbidden"); }
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
        let p = format!("%{}%", query.q);
        where_parts.push(format!("(u.id LIKE '{}' OR u.username LIKE '{}' OR u.display_name LIKE '{}')", p, p, p));
    }
    let where_clause = if where_parts.is_empty() { String::new() } else { format!("WHERE {}", where_parts.join(" AND ")) };

    // Count total
    let total: i64 = c.query_row(&format!("SELECT COUNT(*) FROM users u {}", where_clause), [], |r| r.get(0)).unwrap_or(0);

    // Sort: expiring soon first. ORDER BY 1) null expires last, 2) expires ASC
    let no_search = query.q.is_empty();
    let (join_clause, order_clause) = if sort == "expiring" || no_search {
        ("LEFT JOIN user_preferences up ON u.id=up.user_id AND up.key='subscription_expires'".to_string(), "ORDER BY up.value IS NULL, up.value ASC".to_string())
    } else { (String::new(), "ORDER BY u.created_at DESC".to_string()) };

    let sql = format!("SELECT u.id,u.username,u.display_name,u.real_name,u.phone,u.created_at,u.streak_days,u.deleted_at FROM users u {} {} {} LIMIT ?1 OFFSET ?2", join_clause, where_clause, order_clause);
    eprintln!("SQL: {}", sql);
    let mut stmt = c.prepare(&sql).unwrap();
    let users: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![limit, offset], |row| {
        let uid: String = row.get(0)?;
        let cards: i64 = c.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND status='active'", rusqlite::params![&uid], |r| r.get(0)).unwrap_or(0);
        let reviews: i64 = c.query_row("SELECT COUNT(*) FROM review_log rl JOIN cards cd ON rl.card_id=cd.id WHERE cd.user_id=?1", rusqlite::params![&uid], |r| r.get(0)).unwrap_or(0);
        let expires: Option<String> = c.query_row("SELECT value FROM user_preferences WHERE user_id=?1 AND key='subscription_expires'", rusqlite::params![&uid], |r| r.get(0)).ok();
        let is_super = role == "super";
        let rname_raw: Option<String> = row.get(3)?;
        let phone_raw: Option<String> = row.get(4)?;
        let rname_dec = rname_raw.as_ref().map(|v| decrypt_maybe(v));
        let phone_dec = phone_raw.as_ref().map(|v| decrypt_maybe(v));
        // Guardian info (first guardian for this student)
        let (g_id, g_name, g_phone): (Option<String>, Option<String>, Option<String>) = c.query_row(
            "SELECT au.id, au.real_name, au.phone FROM guardian_assignments ga JOIN admin_users au ON ga.guardian_admin_id=au.id WHERE ga.student_user_id=?1 AND ga.is_active=1 AND au.role='guardian' LIMIT 1",
            rusqlite::params![&uid], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        ).unwrap_or((None, None, None));
        let g_name_dec = g_name.as_ref().map(|v| decrypt_maybe(v));
        let g_phone_dec = g_phone.as_ref().map(|v| decrypt_maybe(v));
        // Tutor info (first tutor for this student)
        let (t_id, t_name, t_phone): (Option<String>, Option<String>, Option<String>) = c.query_row(
            "SELECT au.id, au.real_name, au.phone FROM guardian_assignments ga JOIN admin_users au ON ga.guardian_admin_id=au.id WHERE ga.student_user_id=?1 AND ga.is_active=1 AND au.role='tutor' LIMIT 1",
            rusqlite::params![&uid], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        ).unwrap_or((None, None, None));
        let t_name_dec = t_name.as_ref().map(|v| decrypt_maybe(v));
        let t_phone_dec = t_phone.as_ref().map(|v| decrypt_maybe(v));
        Ok(serde_json::json!({
            "user_id":uid, "username": row.get::<_,String>(1)?, "display_name": row.get::<_,Option<String>>(2)?,
            "real_name": if is_super { rname_dec.clone() } else { rname_dec.as_ref().map(|n| mask_name(n)) },
            "real_name_masked": rname_dec.as_ref().map(|n| mask_name(n)),
            "phone": if is_super { phone_dec.clone() } else { phone_dec.as_ref().map(|p| mask_phone(p)) },
            "phone_masked": phone_dec.as_ref().map(|p| mask_phone(p)),
            "created_at": row.get::<_,String>(5)?, "streak_days": row.get::<_,i32>(6)?, "deleted_at": row.get::<_,Option<String>>(7)?,
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
    let _ = verify_admin(&headers);
    let c = conn();
    let u: Option<serde_json::Value> = c.query_row("SELECT id,username,display_name,real_name,phone,created_at,streak_days,last_active_date FROM users WHERE id=?1", rusqlite::params![&uid], |row| {
        let uid2: String = row.get(0)?;
        let cards: i64 = c.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND status='active'", rusqlite::params![&uid2],|r|r.get(0)).unwrap_or(0);
        let reviews: i64 = c.query_row("SELECT COUNT(*) FROM review_log rl JOIN cards cd ON rl.card_id=cd.id WHERE cd.user_id=?1", rusqlite::params![&uid2],|r|r.get(0)).unwrap_or(0);
        let rn_raw: Option<String> = row.get(3)?;
        let ph_raw: Option<String> = row.get(4)?;
        let expires: Option<String> = c.query_row("SELECT value FROM user_preferences WHERE user_id=?1 AND key='subscription_expires'", rusqlite::params![&uid2], |r| r.get(0)).ok();
        Ok(serde_json::json!({"user_id":uid2,"username":row.get::<_,String>(1)?,"display_name":row.get::<_,Option<String>>(2)?,
            "real_name":rn_raw.as_ref().map(|v|decrypt_maybe(v)),"phone":ph_raw.as_ref().map(|v|decrypt_maybe(v)),
            "created_at":row.get::<_,String>(5)?,"streak_days":row.get::<_,i32>(6)?,"last_active_date":row.get::<_,Option<String>>(7)?,"card_count":cards,"review_count":reviews,"subscription_expires":expires}))
    }).ok();
    match u { Some(v) => ok(v), None => err(StatusCode::NOT_FOUND, "not_found") }
}

pub async fn admin_delete_user(headers: HeaderMap, Path(uid): Path<String>) -> impl IntoResponse {
    let (_, role) = match verify_admin(&headers) { Ok(r) => r, Err(e) => { return e; } };
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn();
    let now = chrono::Utc::now().timestamp().to_string();
    let rows = c.execute("UPDATE users SET deleted_at=?1 WHERE id=?2 AND deleted_at IS NULL", rusqlite::params![now, &uid]).unwrap_or(0);
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'soft_delete_user',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), "super", &uid, serde_json::json!({"deleted_at":now}).to_string(), now]);
    if rows > 0 { ok(serde_json::json!({"status":"deleted","deleted_at":now})) }
    else { err(StatusCode::NOT_FOUND, "already_deleted_or_not_found") }
}

pub async fn admin_restore_user(headers: HeaderMap, Path(uid): Path<String>) -> impl IntoResponse {
    let (_, role) = match verify_admin(&headers) { Ok(r) => r, Err(e) => { return e; } };
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn();
    let rows = c.execute("UPDATE users SET deleted_at=NULL WHERE id=?1 AND deleted_at IS NOT NULL", rusqlite::params![&uid]).unwrap_or(0);
    if rows > 0 {
        let now = chrono::Utc::now().timestamp().to_string();
        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'restore_user',?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "super", &uid, serde_json::json!({"restored_at":now}).to_string(), now]);
        ok(serde_json::json!({"status":"restored"}))
    } else { err(StatusCode::NOT_FOUND, "not_found_or_not_deleted") }
}

// ── Reveal Phone (两步揭看) ──
#[derive(Deserialize)] pub struct RevealPhoneQuery { pub full: Option<bool> }
pub async fn admin_reveal_phone(headers: HeaderMap, Path(uid): Path<String>, Query(query): Query<RevealPhoneQuery>) -> impl IntoResponse {
    // Rate limit: 20 requests per minute
    if let Err(e) = crate::rate_limiter::check_rate_limit(&headers, 20, 60) { return e; }
    let (admin_id, _) = match require_role(&headers, &["service"]) { Ok(r) => r, Err(e) => { return e; } };
    let c = conn();
    let phone: Option<String> = c.query_row("SELECT phone FROM users WHERE id=?1", rusqlite::params![&uid], |row| row.get(0)).ok().flatten();
    match phone {
        Some(p) => {
            let decrypted = decrypt_maybe(&p);
            let masked = mask_phone(&decrypted);
            // Fetch target username for audit detail
            let target_info: String = c.query_row("SELECT COALESCE(display_name,username,'') FROM users WHERE id=?1", rusqlite::params![&uid], |row| row.get(0)).unwrap_or_default();
            if query.full.unwrap_or(false) {
                // Step 2: return full phone with audit log
                let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'reveal_phone_full',?3,?4,?5)",
                    rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"target":target_info,"masked":masked}).to_string(), chrono::Utc::now().timestamp()]);
                ok(serde_json::json!({"phone":decrypted, "full":true}))
            } else {
                // Step 1: return masked phone with audit log
                let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'reveal_phone_masked',?3,?4,?5)",
                    rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"target":target_info,"masked":masked}).to_string(), chrono::Utc::now().timestamp()]);
                ok(serde_json::json!({"phone":mask_phone(&decrypted), "full":false}))
            }
        }
        None => err(StatusCode::NOT_FOUND, "no_phone"),
    }
}

// ── Set Subscription ──
// Super: direct apply. Service: creates pending request.
#[derive(Deserialize)] pub struct SetSubInput { pub subscription_expires: String, pub days: Option<i64> }

fn has_permission(admin_id: &str, perm_key: &str) -> bool {
    let perms_str: Option<String> = conn().query_row("SELECT permissions FROM admin_users WHERE id=?1", rusqlite::params![admin_id], |row| row.get(0)).ok().flatten();
    let perms: serde_json::Value = perms_str.as_ref().map(|s| serde_json::from_str(s).unwrap_or_default()).unwrap_or(serde_json::Value::Object(Default::default()));
    perms.get(perm_key).and_then(|v| v.as_bool()).unwrap_or(false)
}

pub async fn admin_set_subscription(headers: HeaderMap, Path(uid): Path<String>, Json(input): Json<SetSubInput>) -> impl IntoResponse {
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    // service with permission applies directly like super
    let can_direct = role == "super" || (role == "service" && has_permission(&admin_id, "set_expiry"));
    if role == "service" && !has_permission(&admin_id, "set_expiry") { return err(StatusCode::FORBIDDEN, "no_permission"); }
    let c = conn(); let now = chrono::Utc::now().timestamp();
    if can_direct {
        // Direct apply
        let _ = c.execute("INSERT OR REPLACE INTO user_preferences (user_id,key,value,updated_at) VALUES (?1,'subscription_expires',?2,?3)", rusqlite::params![uid, input.subscription_expires, now]);
        let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'set_subscription',?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
        ok(serde_json::json!({"status":"ok"}))
    } else {
        // Create pending request
        let req_id = uuid::Uuid::new_v4().to_string();
        let pkg = "custom"; // custom expiry via set
        let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,'admin',?5,'pending',?6)",
            rusqlite::params![req_id, uid, admin_id, pkg, serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
        ok(serde_json::json!({"request_id":req_id,"status":"pending"}))
    }
}

// ── Quick extend (creates request for non-super) ──
pub async fn admin_quick_extend(headers: HeaderMap, Path(uid): Path<String>, Json(input): Json<SetSubInput>) -> impl IntoResponse {
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    if role == "service" {
        let days = input.days.unwrap_or(7);
        let perm_key = match days { 1..=7 => "extend_7d", 8..=30 => "extend_30d", _ => "extend_365d" };
        if has_permission(&admin_id, perm_key) {
            // Has permission — direct apply like super
            let c = conn(); let now = chrono::Utc::now().timestamp();
            let _ = c.execute("INSERT OR REPLACE INTO user_preferences (user_id,key,value,updated_at) VALUES (?1,'subscription_expires',?2,?3)", rusqlite::params![uid, input.subscription_expires, now]);
            let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend',?3,?4,?5)",
                rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"expires":input.subscription_expires,"days":days}).to_string(), now]);
            return ok(serde_json::json!({"status":"ok"}));
        }
    }
    // Fallback: service without permission → create pending request
    let c = conn(); let now = chrono::Utc::now().timestamp();
    if role == "service" {
        let days = input.days.unwrap_or(7);
        let pkg = format!("{}d", days);
        let req_id = uuid::Uuid::new_v4().to_string();
        let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,'admin',?5,'pending',?6)",
            rusqlite::params![req_id, uid, admin_id, pkg, serde_json::json!({"expires":input.subscription_expires}).to_string(), now]);
        return ok(serde_json::json!({"request_id":req_id,"status":"pending"}));
    }
    // Super: direct extend
    let _ = c.execute("INSERT OR REPLACE INTO user_preferences (user_id,key,value,updated_at) VALUES (?1,'subscription_expires',?2,?3)", rusqlite::params![uid, input.subscription_expires, now]);
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'quick_extend',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, uid, serde_json::json!({"expires":input.subscription_expires,"days":input.days}).to_string(), now]);
    ok(serde_json::json!({"status":"ok"}))
}

#[derive(Deserialize)] pub struct CreateSubReqInput { pub target_user_id: String, pub package: String, pub channel: Option<String>, pub note: Option<String> }
pub async fn admin_create_subscription_request(headers: HeaderMap, Json(input): Json<CreateSubReqInput>) -> impl IntoResponse {
    let (admin_id, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn(); let id = uuid::Uuid::new_v4().to_string(); let now = chrono::Utc::now().timestamp();
    let _ = c.execute("INSERT INTO subscription_requests (id,target_user_id,requested_by,package,channel,note,status,requested_at) VALUES (?1,?2,?3,?4,?5,?6,'pending',?7)",
        rusqlite::params![id, input.target_user_id, admin_id, input.package, input.channel, input.note, now]);
    ok(serde_json::json!({"request_id":id,"status":"pending"}))
}

// ── Batch extend ──
#[derive(Deserialize)] pub struct BatchSubInput { pub user_ids: Vec<String>, pub days: i64 }
pub async fn admin_batch_subscription(headers: HeaderMap, Json(input): Json<BatchSubInput>) -> impl IntoResponse {
    let (admin_id, role) = guard!(&headers, &[]);
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn(); let now = chrono::Utc::now().timestamp();
    for uid in &input.user_ids {
        let current: String = c.query_row("SELECT value FROM user_preferences WHERE user_id=?1 AND key='subscription_expires'", rusqlite::params![uid], |row| row.get(0)).unwrap_or_default();
        let new_exp = if current.is_empty() { (chrono::Utc::now()+chrono::Duration::days(input.days)).format("%Y-%m-%d").to_string() }
            else { (chrono::DateTime::parse_from_rfc3339(&current).unwrap()+chrono::Duration::days(input.days)).format("%Y-%m-%d").to_string() };
        let _ = c.execute("INSERT OR REPLACE INTO user_preferences (user_id,key,value,updated_at) VALUES (?1,'subscription_expires',?2,?3)", rusqlite::params![uid, new_exp, now]);
    }
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'batch_set_subscription',?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, format!("{} users",input.user_ids.len()), serde_json::json!({"ids":input.user_ids,"days":input.days}).to_string(), now]);
    ok(serde_json::json!({"status":"ok","count":input.user_ids.len()}))
}

#[derive(Deserialize)] pub struct ListReqsQuery { pub status: Option<String> }
pub async fn admin_list_subscription_requests(headers: HeaderMap, Query(q): Query<ListReqsQuery>) -> impl IntoResponse {
    let _ = verify_admin(&headers);
    let filter = q.status.unwrap_or_else(|| "%".into());
    let c2 = conn(); let mut stmt = c2.prepare("SELECT sr.id,sr.target_user_id,sr.requested_by,sr.package,sr.channel,sr.note,sr.status,sr.reject_reason,sr.requested_at,sr.reviewed_at,u.username,au.real_name FROM subscription_requests sr JOIN users u ON sr.target_user_id=u.id JOIN admin_users au ON sr.requested_by=au.id WHERE CASE WHEN ?1='%' THEN 1 ELSE sr.status=?1 END ORDER BY sr.requested_at DESC LIMIT 50").unwrap();
    let reqs: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![filter], |row| {
        let rname_raw: Option<String> = row.get(11)?;
        Ok(serde_json::json!({
        "id":row.get::<_,String>(0)?,"target_user_id":row.get::<_,String>(1)?,"requested_by":row.get::<_,String>(2)?,"package":row.get::<_,String>(3)?,"channel":row.get::<_,Option<String>>(4)?,"note":row.get::<_,Option<String>>(5)?,"status":row.get::<_,String>(6)?,"reject_reason":row.get::<_,Option<String>>(7)?,"requested_at":row.get::<_,String>(8)?,"reviewed_at":row.get::<_,Option<String>>(9)?,"target_username":row.get::<_,String>(10)?,"requester_name":rname_raw.as_ref().map(|v|decrypt_maybe(v))
    }))}).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"requests":reqs}))
}

// ── Approve/Reject ──
#[derive(Deserialize)] pub struct ReviewInput { pub reject_reason: Option<String> }
pub async fn admin_approve_request(headers: HeaderMap, Path(req_id): Path<String>) -> impl IntoResponse { review_subscription(&headers, &req_id, "approved", None).await }
pub async fn admin_reject_request(headers: HeaderMap, Path(req_id): Path<String>, Json(input): Json<ReviewInput>) -> impl IntoResponse { review_subscription(&headers, &req_id, "rejected", input.reject_reason).await }

async fn review_subscription(headers: &HeaderMap, req_id: &str, status: &str, reason: Option<String>) -> axum::response::Response {
    let (admin_id, role) = guard!(headers);
    // Check permission: super always ok, service needs can_approve
    if role != "super" {
        let perms_str: Option<String> = conn().query_row("SELECT permissions FROM admin_users WHERE id=?1", rusqlite::params![admin_id], |row| row.get(0)).ok().flatten();
        let perms: serde_json::Value = perms_str.as_ref().map(|s| serde_json::from_str(s).unwrap_or_default()).unwrap_or(serde_json::Value::Object(Default::default()));
        let can_approve = perms.get("can_approve").and_then(|v| v.as_bool()).unwrap_or(false);
        if !can_approve { return err(StatusCode::FORBIDDEN, "forbidden"); }
    }
    let c = conn(); let now = chrono::Utc::now().timestamp();
    let info: Option<(String,String)> = c.query_row("SELECT target_user_id,package FROM subscription_requests WHERE id=?1 AND status='pending'", rusqlite::params![req_id], |row| Ok((row.get(0)?,row.get(1)?))).ok();
    match info {
        Some((uid, pkg)) => {
            let _ = c.execute("UPDATE subscription_requests SET status=?1,reviewed_by=?2,reject_reason=?3,reviewed_at=?4 WHERE id=?5", rusqlite::params![status,admin_id,reason,now,req_id]);
            if status == "approved" {
                let days: i64 = match pkg.as_str() { "30d"=>30,"365d"=>365,"lifetime"=>3650,_ => {
                    // Try parsing "Xd" format (7d, 14d, etc.), fallback to 30
                    let trimmed = pkg.trim_end_matches('d');
                    trimmed.parse::<i64>().unwrap_or(30)
                }};
                // Calculate from current expiry, not from today
                let current: String = c.query_row("SELECT value FROM user_preferences WHERE user_id=?1 AND key='subscription_expires'", rusqlite::params![&uid], |row| row.get(0)).unwrap_or_default();
                let exp = if current.is_empty() {
                    (chrono::Utc::now()+chrono::Duration::days(days)).format("%Y-%m-%d").to_string()
                } else {
                    // Parse current expiry, add days
                    let parsed = chrono::NaiveDate::parse_from_str(&current, "%Y-%m-%d")
                        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
                    (parsed + chrono::Duration::days(days)).format("%Y-%m-%d").to_string()
                };
                let _ = c.execute("INSERT OR REPLACE INTO user_preferences (user_id,key,value,updated_at) VALUES (?1,'subscription_expires',?2,?3)", rusqlite::params![&uid, &exp, now]);
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
    let (reviewer, role) = guard!(&headers);
    if role == "observer" { return err(StatusCode::FORBIDDEN, "observer_readonly"); }
    // 家长/辅导申请：服务人员+超管可审批；管理员申请：仅超管
    let target_role: Option<String> = conn().query_row("SELECT role FROM admin_users WHERE id=?1 AND status='pending'", rusqlite::params![&aid], |row| row.get(0)).ok();
    match target_role {
        Some(ref r) if r == "guardian" || r == "tutor" || role == "super" => {
            let now = chrono::Utc::now().timestamp();
            let c = conn();
            let _ = c.execute("UPDATE admin_users SET status='active',approved_at=?1,created_by=?2 WHERE id=?3 AND status='pending'", rusqlite::params![now,reviewer,aid]);
            // 如果是家长通过审批，自动创建监护绑定
            if r == "guardian" {
                let decl: Option<String> = c.query_row("SELECT guardian_declaration FROM admin_users WHERE id=?1", rusqlite::params![&aid], |row| row.get(0)).ok().flatten();
                if let Some(d) = decl {
                    // Decrypt guardian_declaration if encrypted
                    let decl_plain = if encryption::is_encrypted(&d) { encryption::decrypt(&d) } else { d };
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&decl_plain) {
                        if let Some(sid) = v.get("student_user_id").and_then(|v| v.as_str()) {
                            let guardian_name_enc: Option<String> = c.query_row("SELECT real_name FROM admin_users WHERE id=?1", rusqlite::params![&aid], |row| row.get(0)).ok();
                            let student_name_enc: Option<String> = c.query_row("SELECT real_name FROM users WHERE id=?1", rusqlite::params![sid], |row| row.get(0)).ok();
                            // Decrypt names for bind_key generation
                            let guardian_name = guardian_name_enc.as_ref().map(|v| if encryption::is_encrypted(v) { encryption::decrypt(v) } else { v.clone() });
                            let student_name = student_name_enc.as_ref().map(|v| if encryption::is_encrypted(v) { encryption::decrypt(v) } else { v.clone() });
                            // SHA-256(guardian_name + student_name) as bind_key
                            let bind_key = {
                                let mut hasher = Sha256::new();
                                hasher.update(guardian_name.as_deref().unwrap_or("").as_bytes());
                                hasher.update(student_name.as_deref().unwrap_or("").as_bytes());
                                hex::encode(hasher.finalize())
                            };
                            let bind_id = uuid::Uuid::new_v4().to_string();
                            let _ = c.execute("INSERT OR IGNORE INTO guardian_assignments (id, guardian_admin_id, student_user_id, bind_key, assigned_by, assigned_at, is_active) VALUES (?1,?2,?3,?4,?5,?6,1)",
                                rusqlite::params![bind_id, aid, sid, bind_key, reviewer, now]);
                        }
                    }
                }
            }
            ok(serde_json::json!({"status":"approved"}))
        }
        Some(_) => err(StatusCode::FORBIDDEN, "only_super_admin_approval"),
        None => err(StatusCode::NOT_FOUND, "not_found"),
    }
}
pub async fn admin_reject_admin(headers: HeaderMap, Path(aid): Path<String>, Json(input): Json<ReviewInput>) -> impl IntoResponse {
    let (reviewer, role) = guard!(&headers);
    if role == "observer" { return err(StatusCode::FORBIDDEN, "observer_readonly"); }
    let target_role: Option<String> = conn().query_row("SELECT role FROM admin_users WHERE id=?1 AND status='pending'", rusqlite::params![&aid], |row| row.get(0)).ok();
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
    guard!(&headers, &[]);
    let _ = conn().execute("UPDATE admin_users SET status='disabled' WHERE id=?1", rusqlite::params![aid]);
    ok(serde_json::json!({"status":"disabled"}))
}

pub async fn admin_enable_admin(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    guard!(&headers, &[]);
    let _ = conn().execute("UPDATE admin_users SET status='active' WHERE id=?1", rusqlite::params![aid]);
    ok(serde_json::json!({"status":"active"}))
}

#[derive(Deserialize)] pub struct CreateAdminInput { pub username: String, pub password: String, pub real_name: String, pub phone: String, pub role: String }
pub async fn admin_create_admin(headers: HeaderMap, Json(input): Json<CreateAdminInput>) -> impl IntoResponse {
    let (_admin_id, role) = guard!(&headers);
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    if !["service","super"].contains(&input.role.as_str()) { return err(StatusCode::BAD_REQUEST, "role_must_be_service_or_super"); }
    if input.username.len() < 5 { return err(StatusCode::BAD_REQUEST, "username_5"); }
    if input.password.len() < 6 { return err(StatusCode::BAD_REQUEST, "password_6"); }
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

#[derive(Deserialize)] pub struct ResetPasswordInput { pub password: String }
pub async fn admin_reset_password(headers: HeaderMap, Path(aid): Path<String>, Json(input): Json<ResetPasswordInput>) -> impl IntoResponse {
    let (_, role) = guard!(&headers);
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    if input.password.len() < 6 { return err(StatusCode::BAD_REQUEST, "password_6"); }
    let hash = bcrypt::hash(&input.password, 12).unwrap_or_default();
    let _ = conn().execute("UPDATE admin_users SET password_hash=?1 WHERE id=?2", rusqlite::params![hash, aid]);
    ok(serde_json::json!({"status":"updated"}))
}

#[derive(Deserialize)] pub struct SetPermissionsInput { pub permissions: serde_json::Value }
pub async fn admin_set_permissions(headers: HeaderMap, Path(aid): Path<String>, Json(input): Json<SetPermissionsInput>) -> impl IntoResponse {
    let (_, role) = guard!(&headers);
    if role != "super" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let perms_str = input.permissions.to_string();
    let _ = conn().execute("UPDATE admin_users SET permissions=?1 WHERE id=?2", rusqlite::params![perms_str, aid]);
    ok(serde_json::json!({"status":"updated"}))
}

// ── Audit Log ──
#[derive(Deserialize)] pub struct AuditLogQuery {
    #[serde(default)] pub user_id: Option<String>, #[serde(default)] pub admin_id: Option<String>, #[serde(default)] pub action: Option<String>,
    #[serde(default)] pub date_from: Option<String>, #[serde(default)] pub date_to: Option<String>, #[serde(default)] pub q: Option<String>,
}
pub async fn admin_audit_log(headers: HeaderMap, Query(query): Query<AuditLogQuery>) -> impl IntoResponse {
    let (_, role) = guard!(&headers);
    if role!="super" && role!="service" && role!="observer" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c2 = conn();
    let mut conditions = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
    if let Some(ref uid) = query.user_id { conditions.push(format!("al.target_user_id LIKE ?{}", params.len()+1)); params.push(Box::new(format!("%{}%", uid))); }
    if let Some(ref aid) = query.admin_id { conditions.push(format!("al.admin_id LIKE ?{}", params.len()+1)); params.push(Box::new(format!("%{}%", aid))); }
    if let Some(ref a) = query.action { conditions.push(format!("al.action LIKE ?{}", params.len()+1)); params.push(Box::new(format!("%{}%", a))); }
    if let Some(ref d) = query.date_from { conditions.push(format!("al.created_at >= ?{}", params.len()+1)); params.push(Box::new(d.clone())); }
    if let Some(ref d) = query.date_to { conditions.push(format!("al.created_at <= ?{}", params.len()+1)); params.push(Box::new(format!("{}T23:59:59Z", d))); }
    if let Some(ref q) = query.q { 
        conditions.push(format!("(al.action LIKE ?{} OR al.target_user_id LIKE ?{} OR al.detail LIKE ?{} OR au.real_name LIKE ?{})", params.len()+1, params.len()+2, params.len()+3, params.len()+4));
        let pq: String = format!("%{}%", q);
        params.push(Box::new(pq.clone())); params.push(Box::new(pq.clone())); params.push(Box::new(pq.clone())); params.push(Box::new(pq));
    }
    let where_clause = if conditions.is_empty() { String::new() } else { format!(" WHERE {}", conditions.join(" AND ")) };
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

// ── Guardian ──
pub async fn guardian_students(headers: HeaderMap) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role!="guardian" && role!="tutor" && role!="super" { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c = conn();
    let now = chrono::Utc::now();
    let seven_days_ago = (now - chrono::Duration::days(7)).to_rfc3339();
    let one_day_ago = (now - chrono::Duration::days(1)).to_rfc3339();
    let mut stmt = c.prepare("SELECT ga.student_user_id,u.display_name,u.real_name,u.phone,u.streak_days,u.last_active_date FROM guardian_assignments ga JOIN users u ON ga.student_user_id=u.id WHERE ga.guardian_admin_id=?1 AND ga.is_active=1").unwrap();
    let students: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![gid], |row| {
        let uid: String = row.get(0)?;
        let _cards: i64 = c.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND status='active'",rusqlite::params![&uid],|r|r.get(0)).unwrap_or(0);
        let _reviews: i64 = c.query_row("SELECT COUNT(*) FROM review_log rl JOIN cards cd ON rl.card_id=cd.id WHERE cd.user_id=?1",rusqlite::params![&uid],|r|r.get(0)).unwrap_or(0);
        let _mastery: f64 = c.query_row("SELECT CAST(SUM(CASE WHEN cm.state=2 THEN 1 ELSE 0 END) AS REAL)/MAX(1,COUNT(*)) FROM card_memory cm JOIN cards cd ON cm.card_id=cd.id WHERE cd.user_id=?1",rusqlite::params![&uid],|r|r.get(0)).unwrap_or(0.0);
        // Plan stats
        let total_plans: i64 = c.query_row("SELECT COUNT(*) FROM learning_plans WHERE user_id=?1 AND mode != 'deleted'", rusqlite::params![&uid], |r| r.get(0)).unwrap_or(0);
        let active_7d: i64 = c.query_row("SELECT COUNT(*) FROM learning_plans WHERE user_id=?1 AND mode != 'deleted' AND updated_at >= ?2", rusqlite::params![&uid, &seven_days_ago], |r| r.get(0)).unwrap_or(0);
        let today_active: i64 = c.query_row("SELECT COUNT(*) FROM learning_plans WHERE user_id=?1 AND mode != 'deleted' AND updated_at >= ?2", rusqlite::params![&uid, &one_day_ago], |r| r.get(0)).unwrap_or(0);
        let rn_raw: Option<String> = row.get(2)?;
        let ph_raw: Option<String> = row.get(3)?;
        let rn_decrypted = rn_raw.as_ref().map(|v| decrypt_maybe(v));
        let ph_decrypted = ph_raw.as_ref().map(|v| decrypt_maybe(v));
        // Guardian info (for tutor role)
        let (g_aid, guardian_name, guardian_phone) = if role == "tutor" {
            let g: (Option<String>, Option<String>, Option<String>) = c.query_row(
                "SELECT ga2.guardian_admin_id, au.real_name, au.phone FROM guardian_assignments ga2 JOIN admin_users au ON ga2.guardian_admin_id=au.id WHERE ga2.student_user_id=?1 AND ga2.is_active=1 LIMIT 1",
                rusqlite::params![&uid], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            ).unwrap_or((None, None, None));
            (g.0, g.1.as_ref().map(|v| decrypt_maybe(v)), g.2.as_ref().map(|v| decrypt_maybe(v)))
        } else { (None, None, None) };
        Ok(serde_json::json!({
            "student_user_id":uid,
            "display_name":row.get::<_,Option<String>>(1)?,
            "real_name":rn_decrypted,
            "phone_masked":ph_decrypted.as_ref().map(|p| if p.len() >= 7 { format!("{}****{}", &p[..3], &p[p.len()-4..]) } else { "***".into() }),
            "streak_days":row.get::<_,i32>(4)?,
            "last_active":row.get::<_,Option<String>>(5)?,
            "plan_total":total_plans,"plan_active_7d":active_7d,"plan_today":today_active,
            "guardian_admin_id":g_aid,
            "guardian_name":guardian_name,
            "guardian_phone_masked":guardian_phone.as_ref().map(|p| if p.len() >= 7 { format!("{}****{}", &p[..3], &p[p.len()-4..]) } else { "***".into() }),
        }))
    }).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"students":students}))
}

fn is_guardian_of(gid: &str, sid: &str) -> bool {
    conn().query_row("SELECT 1 FROM guardian_assignments WHERE guardian_admin_id=?1 AND student_user_id=?2 AND is_active=1", rusqlite::params![gid,sid], |_| Ok(())).is_ok()
}

#[derive(Deserialize)] pub struct GuardianBindInput { pub student_user_id: String }
pub async fn guardian_bind_request(headers: HeaderMap, Json(input): Json<GuardianBindInput>) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role != "guardian" && role != "tutor" { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c = conn();
    let now = chrono::Utc::now().timestamp().to_string();
    let bind_id = uuid::Uuid::new_v4().to_string();
    if let Err(e) = c.execute(
        "INSERT INTO guardian_assignments (id, guardian_admin_id, student_user_id, bind_key, assigned_by, assigned_at, is_active) VALUES (?1,?2,?3,'auto',?4,?5,1)",
        rusqlite::params![bind_id, gid, input.student_user_id, gid, now],
    ) { return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("DB: {}", e)); }
    ok(serde_json::json!({"success":true,"assignment_id":bind_id}))
}

pub async fn guardian_reveal_phone(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    let (admin_id, role) = guard!(&headers);
    if role != "tutor" && role != "super" && role != "service" { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c = conn();
    let phone_enc: Option<String> = c.query_row("SELECT phone FROM admin_users WHERE id=?1", rusqlite::params![aid], |row| row.get(0)).unwrap_or(None);
    let phone = match phone_enc { Some(ref enc) if !enc.is_empty() => decrypt_maybe(enc), _ => return err(StatusCode::NOT_FOUND, "phone not found") };
    let now = chrono::Utc::now().timestamp().to_string();
    let _ = c.execute("INSERT INTO admin_audit_log (id,admin_id,action,target_user_id,detail,created_at) VALUES (?1,?2,'reveal_guardian_phone',?3,'Phone revealed by tutor',?4)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), admin_id, aid, now]);
    ok(serde_json::json!({"phone":phone}))
}

pub async fn guardian_student_cards(headers: HeaderMap, Path(sid): Path<String>) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role != "super" && role != "service" && !is_guardian_of(&gid, &sid) { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c2 = conn(); let mut stmt = c2.prepare("SELECT c.id,c.front,c.back,c.domain,cm.state,cm.reps,cm.last_review,c.conversation_id FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id=?1 ORDER BY cm.state,cm.due").unwrap();
    let cards: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![sid], |row| Ok(serde_json::json!({
        "id":row.get::<_,String>(0)?,"front":row.get::<_,String>(1)?,"back":row.get::<_,String>(2)?,"domain":row.get::<_,Option<String>>(3)?,"state":row.get::<_,i32>(4)?,"reps":row.get::<_,i32>(5)?,"last_review":row.get::<_,Option<i64>>(6)?,"conversation_id":row.get::<_,Option<String>>(7)?
    }))).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"cards":cards}))
}
pub async fn guardian_student_conversations(headers: HeaderMap, Path(sid): Path<String>) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role != "super" && role != "service" && !is_guardian_of(&gid, &sid) { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c = conn();
    // Get conversations with first user message + learning plan title as combined title
    let mut stmt = c.prepare(
        "SELECT c.id, c.started_at,
         COALESCE((SELECT content FROM conversation_turns t WHERE t.conversation_id=c.id AND t.role='user' ORDER BY t.created_at LIMIT 1), c.id),
         (SELECT COUNT(*) FROM conversation_turns t WHERE t.conversation_id=c.id),
         COALESCE((SELECT goal FROM learning_plans lp WHERE lp.conversation_id=c.id LIMIT 1), '')
         FROM conversations c WHERE c.user_id=?1 AND c.deleted_at IS NULL ORDER BY c.started_at DESC LIMIT 20"
    ).unwrap();
    let convs: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![sid], |row| {
        let first_msg: String = row.get::<_,String>(2).unwrap_or_default();
        let plan_goal: String = row.get::<_,String>(4).unwrap_or_default();
        let truncated = if first_msg.len() > 25 { format!("{}...", &first_msg[..25]) } else { first_msg };
        let title = if plan_goal.is_empty() { truncated } else { format!("【{}】{}", plan_goal, truncated) };
        Ok(serde_json::json!({"id":row.get::<_,String>(0)?,"title":title,"started_at":row.get::<_,String>(1)?,"turn_count":row.get::<_,i64>(3)?}))
    }).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"conversations":convs}))
}
pub async fn guardian_student_conversation_detail(headers: HeaderMap, Path((sid, cid)): Path<(String,String)>) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role != "super" && role != "service" && !is_guardian_of(&gid, &sid) { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c2 = conn(); let mut stmt = c2.prepare("SELECT role,content,created_at FROM conversation_turns WHERE conversation_id=?1 ORDER BY created_at").unwrap();
    let turns: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![cid], |row| Ok(serde_json::json!({
        "role":row.get::<_,String>(0)?,"content":row.get::<_,String>(1)?,"created_at":row.get::<_,String>(2)?
    }))).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"turns":turns}))
}

// ── Learning Summary (家长座舱) ──
pub async fn guardian_learning_summary(headers: HeaderMap, Path(sid): Path<String>) -> impl IntoResponse {
    let (gid, role) = guard!(&headers);
    if role != "super" && role != "service" && !is_guardian_of(&gid, &sid) { return err(StatusCode::FORBIDDEN,"forbidden"); }
    let c = conn();
    let now = chrono::Utc::now();
    let now_ts = now.timestamp();
    let seven_days_ago = (now - chrono::Duration::days(7)).to_rfc3339();
    let one_day_ago = (now - chrono::Duration::days(1)).to_rfc3339();

    // 1. Get all plans for this student
    let mut plan_stmt = c.prepare("SELECT id, goal, domain, conversation_id, task_status, updated_at FROM learning_plans WHERE user_id=?1 AND mode != 'deleted' ORDER BY updated_at DESC").unwrap();
    let mut plan_results: Vec<serde_json::Value> = Vec::new();
    let mut total_active_7d = 0i64;
    let mut total_today_active = 0i64;
    let mut total_completed = 0i64;
    let mut total_all_tasks = 0i64;
    let mut total_done_tasks = 0i64;
    let mut total_all_cards = 0i64;
    let mut total_mastered_cards = 0i64;

    let rows = plan_stmt.query_map(rusqlite::params![sid], |row| -> rusqlite::Result<()> {
        let plan_id: String = row.get(0)?;
        let goal: String = row.get(1)?;
        let _domain: String = row.get(2)?;
        let conv_id: Option<String> = row.get(3)?;
        let task_status_str: String = row.get(4)?;
        let updated_at_str: String = row.get(5)?;

        // Parse plan progress
        let (total_tasks, done_tasks, current_stage, current_task) = parse_plan_progress(&task_status_str);

        // Parse updated_at as unix timestamp for activity calculation
        let updated_ts = chrono::DateTime::parse_from_rfc3339(&updated_at_str).map(|d| d.timestamp()).unwrap_or(0);
        let days_since_active = if updated_ts > 0 { (now_ts - updated_ts) / 86400 } else { 999i64 };
        let is_active_7d = updated_at_str >= seven_days_ago;
        let is_today_active = updated_at_str >= one_day_ago;
        let is_completed = total_tasks > 0 && done_tasks >= total_tasks;

        // Query cards
        let (total_cards, mastered, learning, new_cards, relearning, _last_review) = {
            let base_sql = "SELECT COUNT(*), COALESCE(SUM(CASE WHEN cm.state=2 THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN cm.state=1 THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN cm.state=0 THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN cm.state=3 THEN 1 ELSE 0 END),0), MAX(cm.last_review)
                     FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE ";
            let fallback_domain = plan_keywords_from_goal(&goal);
            let fallback_ok = !fallback_domain.is_empty();
            if let Some(cid) = &conv_id {
                let r = c.query_row(&format!("{} c.conversation_id=?1", base_sql), rusqlite::params![cid], card_stats_from_row).unwrap_or((0,0,0,0,0,None));
                if r.0 > 0 { r }
                else if fallback_ok { c.query_row(&format!("{} c.user_id=?1 AND c.domain=?2", base_sql), rusqlite::params![sid, fallback_domain], card_stats_from_row).unwrap_or((0,0,0,0,0,None)) }
                else { r }
            } else if fallback_ok { c.query_row(&format!("{} c.user_id=?1 AND c.domain=?2", base_sql), rusqlite::params![sid, fallback_domain], card_stats_from_row).unwrap_or((0,0,0,0,0,None)) }
            else { (0,0,0,0,0,None) }
        };

        // Scores
        let progress_rate = if total_tasks > 0 { done_tasks as f64 / total_tasks as f64 } else { 0.0 };
        let card_rate = if total_cards > 0 { mastered as f64 / total_cards as f64 } else { progress_rate };
        let plan_score = 0.4 * progress_rate + 0.6 * card_rate;

        // Health determination
        let (health, reason) =
            if days_since_active > 30 && done_tasks >= 3 { ("abandoned", "30天无活动已弃坑") }
            else if days_since_active > 14 { ("stale", "14天未学习") }
            else if total_cards > 0 && new_cards > 50 && days_since_active >= 7 { ("attention", "卡片积压超过50张") }
            else if progress_rate > 0.5 && card_rate < 0.2 { ("attention", "推进快但记住的少") }
            else if total_tasks == 0 && total_cards == 0 { ("not_started", "未开始") }
            else if plan_score < 0.2 && days_since_active <= 7 { ("attention", "活跃但进度缓慢") }
            else { ("good", "") };

        // Accumulate totals
        if is_active_7d { total_active_7d += 1; }
        if is_today_active { total_today_active += 1; }
        if is_completed { total_completed += 1; }
        total_all_tasks += total_tasks;
        total_done_tasks += done_tasks;
        total_all_cards += total_cards;
        total_mastered_cards += mastered;

        plan_results.push(serde_json::json!({
            "plan_id": plan_id, "goal": goal,
            "progress": {"total_tasks": total_tasks, "done_tasks": done_tasks, "current_stage": current_stage, "current_task": current_task},
            "cards": {"total": total_cards, "mastered": mastered, "learning": learning, "new": new_cards, "relearning": relearning},
            "score": (plan_score * 100.0).round() as i32,
            "health": health, "reason": reason, "days_since_active": days_since_active,
        }));
        Ok(())
    });
    if let Ok(rows) = rows { for r in rows { let _ = r; } }

    // Second pass: scatter detection
    let scatter_plans = plan_results.iter().filter(|p| {
        let prog = p["progress"]["done_tasks"].as_i64().unwrap_or(0);
        let total = p["progress"]["total_tasks"].as_i64().unwrap_or(1);
        let rate = if total > 0 { prog as f64 / total as f64 } else { 0.0 };
        rate < 0.1
    }).count();
    let global_attention = if scatter_plans >= 4 {
        Some(serde_json::json!({"type":"scatter","plans":scatter_plans,"detail":"同时开启4+个计划但每个进度不足10%"}))
    } else { None };

    // Overview
    let overall_progress = if total_all_tasks > 0 { total_done_tasks as f64 / total_all_tasks as f64 } else { 0.0 };
    let overall_cards = if total_all_cards > 0 { total_mastered_cards as f64 / total_all_cards as f64 } else { overall_progress };
    let overall_score = 0.4 * overall_progress + 0.6 * overall_cards;

    let mut resp = serde_json::json!({
        "overview": {
            "total_plans": plan_results.len(),
            "active_7d": total_active_7d,
            "today_active": total_today_active,
            "completed_plans": total_completed,
            "overall_progress": format!("{:.0}%", overall_progress * 100.0),
            "overall_cards": format!("{:.0}%", overall_cards * 100.0),
            "overall_score": (overall_score * 100.0).round() as i32,
        },
        "plans": plan_results,
    });
    if let Some(scatter) = global_attention {
        resp["overview"]["attention"] = scatter;
    }
    ok(resp)
}

/// Map plan goal to card domain for fallback matching
fn plan_keywords_from_goal(goal: &str) -> &'static str {
    let g = goal.to_lowercase();
    if g.contains("物理") || g.contains("physics") { "physics" }
    else if g.contains("几何") || g.contains("geometry") || g.contains("三角") || g.contains("三角形") { "geometry" }
    else if g.contains("线性代数") || g.contains("linear_algebra") || g.contains("矩阵") || g.contains("向量") { "linear_algebra" }
    else if g.contains("rust") || g.contains("编程") || g.contains("tech") { "tech" }
    else if g.contains("英语") || g.contains("vocabulary") { "vocabulary" }
    else { "math" }
}

fn card_stats_from_row(row: &rusqlite::Row) -> rusqlite::Result<(i64,i64,i64,i64,i64,Option<i64>)> {
    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
}

fn parse_plan_progress(json_str: &str) -> (i64, i64, String, String) {
    let v: serde_json::Value = match serde_json::from_str(json_str) { Ok(v) => v, Err(_) => return (0,0,"".into(),"".into()) };
    let stages = v["stages"].as_array();
    let stages = match stages { Some(s) => s, None => return (0,0,"".into(),"".into()) };
    let mut total = 0i64;
    let mut done = 0i64;
    let mut current_stage = String::new();
    let mut current_task = String::new();
    for stage in stages {
        let sname = stage["name"].as_str().unwrap_or("");
        let tasks = stage["tasks"].as_array();
        if let Some(tasks) = tasks {
            for task in tasks {
                total += 1;
                let status = task["status"].as_str().unwrap_or("");
                let tname = task["name"].as_str().unwrap_or("");
                if status == "done" { done += 1; }
                else if current_task.is_empty() {
                    if current_stage.is_empty() { current_stage = sname.to_string(); }
                    current_task = tname.to_string();
                }
            }
        }
        if current_stage.is_empty() && stage["status"].as_str().unwrap_or("") != "done" {
            current_stage = sname.to_string();
        }
    }
    (total, done, current_stage, current_task)
}

// ── Bind Lookup ──
#[derive(Deserialize)] pub struct BindLookupInput { pub real_name: String, pub phone: String }
pub async fn bind_lookup_handler(headers: HeaderMap, Json(input): Json<BindLookupInput>) -> impl IntoResponse {
    // Rate limit: 5 requests per minute per IP (no auth endpoint)
    if let Err(e) = crate::rate_limiter::check_rate_limit(&headers, 5, 60) { return e; }
    let c = conn();
    // Use bind_hash (SHA-256 of real_name + phone) for deterministic lookup
    let hash = encryption::bind_hash(&input.real_name, &input.phone);
    let r: Option<(String,Option<String>)> = c.query_row("SELECT id,display_name FROM users WHERE bind_hash=?1", rusqlite::params![hash], |row| Ok((row.get(0)?,row.get(1)?))).ok();
    match r { Some((uid,dn)) => ok(serde_json::json!({"found":true,"user_id":uid,"display_name":dn})), None => ok(serde_json::json!({"found":false})) }
}

// ── User Profile Update ──
#[derive(Deserialize)] pub struct UpdateProfileInput { pub real_name: Option<String>, pub phone: Option<String> }
pub async fn update_user_profile_handler(headers: HeaderMap, Path(uid): Path<String>, Json(input): Json<UpdateProfileInput>) -> impl IntoResponse {
    // Verify auth: caller must be the user themselves or admin
    let is_admin = verify_admin(&headers).is_ok();
    if !is_admin && crate::auth_middleware::verify_auth(&uid, &headers).is_err() {
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let c = conn();
    if let Some(n) = &input.real_name {
        let enc = encryption::encrypt(n);
        let _ = c.execute("UPDATE users SET real_name=?1 WHERE id=?2", rusqlite::params![enc,uid]);
    }
    if let Some(p) = &input.phone {
        let enc = encryption::encrypt(p);
        let _ = c.execute("UPDATE users SET phone=?1 WHERE id=?2", rusqlite::params![enc,uid]);
    }
    // Update bind_hash if both real_name and phone were provided
    if input.real_name.is_some() || input.phone.is_some() {
        let current: (Option<String>, Option<String>) = c.query_row(
            "SELECT real_name, phone FROM users WHERE id=?1", rusqlite::params![uid],
            |row| Ok((row.get(0)?, row.get(1)?))
        ).unwrap_or((None, None));
        // Both fields might be encrypted, decrypt for bind_hash
        let rn = current.0.as_ref().map(|v| decrypt_maybe(v)).unwrap_or_default();
        let ph = current.1.as_ref().map(|v| decrypt_maybe(v)).unwrap_or_default();
        let bhash = encryption::bind_hash(&rn, &ph);
        let _ = c.execute("UPDATE users SET bind_hash=?1 WHERE id=?2", rusqlite::params![bhash, uid]);
    }
    ok(serde_json::json!({"status":"ok"}))
}

// ── Guardian Assignment Management (超管) ──
#[derive(Deserialize)] pub struct CreateAssignmentInput { pub guardian_admin_id: String, pub student_user_id: String }
pub async fn admin_list_assignments(headers: HeaderMap) -> impl IntoResponse {
    let (_, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn();
    let mut stmt = c.prepare(
        "SELECT ga.id, ga.guardian_admin_id, ga.student_user_id, ga.bind_key, ga.assigned_by, ga.assigned_at, ga.is_active, au.real_name, u.display_name, u.real_name
         FROM guardian_assignments ga
         JOIN admin_users au ON ga.guardian_admin_id = au.id
         JOIN users u ON ga.student_user_id = u.id
         ORDER BY ga.assigned_at DESC LIMIT 50"
    ).unwrap();
    let assignments: Vec<serde_json::Value> = stmt.query_map([], |row| {
        let aname_raw: Option<String> = row.get(7)?;
        let sname_raw: Option<String> = row.get(9)?;
        Ok(serde_json::json!({
            "id": row.get::<_,String>(0)?,
            "guardian_admin_id": row.get::<_,String>(1)?,
            "student_user_id": row.get::<_,String>(2)?,
            "bind_key": row.get::<_,String>(3)?,
            "assigned_by": row.get::<_,String>(4)?,
            "assigned_at": row.get::<_,String>(5)?,
            "is_active": row.get::<_,i32>(6)?,
            "guardian_name": aname_raw.as_ref().map(|v| decrypt_maybe(v)),
            "student_display_name": row.get::<_,Option<String>>(8)?,
            "student_real_name": sname_raw.as_ref().map(|v| decrypt_maybe(v)),
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();
    ok(serde_json::json!({"assignments": assignments}))
}

pub async fn admin_create_assignment(headers: HeaderMap, Json(input): Json<CreateAssignmentInput>) -> impl IntoResponse {
    let (reviewer, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn();
    let now = chrono::Utc::now().timestamp();
    let id = uuid::Uuid::new_v4().to_string();
    // Generate bind_key from names
    let guardian_name: String = c.query_row("SELECT COALESCE(real_name,'') FROM admin_users WHERE id=?1", rusqlite::params![&input.guardian_admin_id], |row| row.get(0)).unwrap_or_default();
    let student_name: String = c.query_row("SELECT COALESCE(real_name,'') FROM users WHERE id=?1", rusqlite::params![&input.student_user_id], |row| row.get(0)).unwrap_or_default();
    let gname = if encryption::is_encrypted(&guardian_name) { encryption::decrypt(&guardian_name) } else { guardian_name.clone() };
    let sname = if encryption::is_encrypted(&student_name) { encryption::decrypt(&student_name) } else { student_name.clone() };
    let bind_key = {
        let mut hasher = Sha256::new();
        hasher.update(gname.as_bytes());
        hasher.update(sname.as_bytes());
        hex::encode(hasher.finalize())
    };
    match c.execute(
        "INSERT INTO guardian_assignments (id,guardian_admin_id,student_user_id,bind_key,assigned_by,assigned_at,is_active) VALUES (?1,?2,?3,?4,?5,?6,1)",
        rusqlite::params![id, input.guardian_admin_id, input.student_user_id, bind_key, reviewer, now],
    ) {
        Ok(_) => ok(serde_json::json!({"id": id, "status": "created"})),
        Err(e) if e.to_string().contains("UNIQUE") => err(StatusCode::CONFLICT, "assignment_already_exists"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    }
}

pub async fn admin_remove_assignment(headers: HeaderMap, Path(aid): Path<String>) -> impl IntoResponse {
    let (_, role) = guard!(&headers);
    if role != "super" && role != "service" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let _ = conn().execute("UPDATE guardian_assignments SET is_active=0 WHERE id=?1", rusqlite::params![aid]);
    ok(serde_json::json!({"status": "disabled"}))
}

// ── Dashboard ──
pub async fn admin_dashboard(headers: HeaderMap) -> impl IntoResponse {
    let _ = verify_admin(&headers);
    let c = conn();
    let now = chrono::Utc::now();
    let today_start = now.format("%Y-%m-%dT00:00:00Z").to_string();
    let _today_end = now.format("%Y-%m-%dT23:59:59Z").to_string();
    let week_end = (now + chrono::Duration::days(7)).format("%Y-%m-%d").to_string();

    let total_users: i64 = c.query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0)).unwrap_or(0);
    let total_cards: i64 = c.query_row("SELECT COUNT(*) FROM cards", [], |r| r.get(0)).unwrap_or(0);
    let today_users: i64 = c.query_row("SELECT COUNT(*) FROM users WHERE created_at >= ?1", rusqlite::params![today_start], |r| r.get(0)).unwrap_or(0);
    let today_active: i64 = c.query_row(
        "SELECT COUNT(DISTINCT user_id) FROM (SELECT user_id FROM conversations WHERE started_at >= ?1 UNION ALL SELECT user_id FROM cards WHERE created_at >= ?2)",
        rusqlite::params![today_start, now.timestamp()], |r| r.get(0)).unwrap_or(0);
    let today_reviews: i64 = c.query_row(
        "SELECT COUNT(*) FROM review_log rl JOIN cards cd ON rl.card_id=cd.id WHERE rl.reviewed_at >= ?1",
        rusqlite::params![now.timestamp() - 86400], |r| r.get(0)).unwrap_or(0);
    let expiring: Vec<serde_json::Value> = {
        let mut stmt = c.prepare(
            "SELECT u.id, u.username, u.display_name, up.value FROM user_preferences up JOIN users u ON up.user_id=u.id WHERE up.key='subscription_expires' AND up.value <= ?1 AND up.value >= date('now') ORDER BY up.value LIMIT 20"
        ).unwrap();
        stmt.query_map(rusqlite::params![week_end], |row| Ok(serde_json::json!({
            "user_id": row.get::<_,String>(0)?,
            "username": row.get::<_,String>(1)?,
            "display_name": row.get::<_,Option<String>>(2)?,
            "expires": row.get::<_,String>(3)?,
        }))).unwrap().filter_map(|r|r.ok()).collect()
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
#[derive(Deserialize)] pub struct ExpiringQuery { pub range: Option<String> }
pub async fn admin_expiring_users(headers: HeaderMap, Query(query): Query<ExpiringQuery>) -> impl IntoResponse {
    let _ = verify_admin(&headers);
    let range_days: i64 = match query.range.as_deref() {
        Some("today") => 0, Some("week") => 7, Some("month") => 30, _ => 7,
    };
    let c = conn();
    let end_offset = format!("+{} days", range_days);
    let mut stmt = c.prepare(
        "SELECT u.id, u.username, u.display_name, up.value FROM user_preferences up JOIN users u ON up.user_id=u.id \
         WHERE up.key='subscription_expires' AND up.value >= date('now') AND up.value <= date('now', ?1) \
         ORDER BY up.value LIMIT 50"
    ).unwrap();
    let users: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![end_offset], |row| {
        Ok(serde_json::json!({
            "user_id": row.get::<_,String>(0)?,
            "username": row.get::<_,String>(1)?,
            "display_name": row.get::<_,Option<String>>(2)?,
            "expires": row.get::<_,String>(3)?,
        }))
    }).unwrap().filter_map(|r|r.ok()).collect();
    ok(serde_json::json!({"users": users}))
}



// ── CSV Export ──
pub async fn admin_users_export(headers: HeaderMap, Query(query): Query<AdminUsersQuery>) -> axum::response::Response {
    let (_, role) = match verify_admin(&headers) { Ok(r) => r, Err(e) => { return e; } };
    if role == "guardian" { return err(StatusCode::FORBIDDEN, "forbidden"); }
    let c = conn();
    let pattern = if query.q.is_empty() { "%".to_string() } else { format!("%{}%", query.q) };
    let mut stmt = c.prepare(
        "SELECT u.id,u.username,u.display_name,u.real_name,u.phone,u.created_at,u.streak_days FROM users u WHERE u.id LIKE ?1 OR u.username LIKE ?1 OR u.display_name LIKE ?1 LIMIT 200"
    ).unwrap();
    let mut csv = String::from("user_id,username,display_name,real_name,phone,created_at,streak_days,card_count,review_count,subscription_expires\n");
    if let Ok(rows) = stmt.query_map(rusqlite::params![pattern], |row| {
        let uid: String = row.get(0)?;
        let cards: i64 = c.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND status='active'", rusqlite::params![&uid], |r| r.get(0)).unwrap_or(0);
        let reviews: i64 = c.query_row("SELECT COUNT(*) FROM review_log rl JOIN cards cd ON rl.card_id=cd.id WHERE cd.user_id=?1", rusqlite::params![&uid], |r| r.get(0)).unwrap_or(0);
        let expires: String = c.query_row("SELECT COALESCE(value,'') FROM user_preferences WHERE user_id=?1 AND key='subscription_expires'", rusqlite::params![&uid], |r| r.get(0)).unwrap_or_default();
        let rn_opt: Option<String> = row.get(3).ok().flatten();
        let ph_opt: Option<String> = row.get(4).ok().flatten();
        let rn = rn_opt.as_ref().map(|v| if encryption::is_encrypted(v) { encryption::decrypt(v) } else { v.clone() }).unwrap_or_default();
        let ph = ph_opt.as_ref().map(|v| if encryption::is_encrypted(v) { encryption::decrypt(v) } else { v.clone() }).unwrap_or_default();
        let dn: String = row.get::<_,Option<String>>(2).ok().flatten().unwrap_or_default();
        let un: String = row.get::<_,String>(1).unwrap_or_default();
        let dt: String = row.get::<_,String>(5).unwrap_or_default();
        let sd: i32 = row.get::<_,i32>(6).unwrap_or(0);
        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{}\n", uid, un, dn, rn, ph, dt, sd, cards, reviews, expires));
        Ok::<_, rusqlite::Error>(())
    }) {
        for _ in rows {}
    }
    ([(axum::http::header::CONTENT_TYPE, "text/csv; charset=utf-8"), (axum::http::header::CONTENT_DISPOSITION, "attachment; filename=\"coevo-users.csv\"")], csv).into_response()
}
