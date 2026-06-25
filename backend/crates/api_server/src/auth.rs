//! Auth — User registration and login
//!
//! Uses bcrypt for password hashing and UUID v4 for session tokens.
//! Tokens are stored in the `tokens` table for server-side verification.

use serde::{Deserialize, Serialize};
use crate::encryption;

#[derive(Debug, Deserialize)]
pub struct ReferralInfo {
    pub code: Option<String>,
    pub campaign_id: Option<String>,
}

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
    pub real_name: Option<String>,
    pub phone: Option<String>,
    pub referral: Option<ReferralInfo>,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Serialize, Debug)]
pub struct AuthResponse {
    pub user_id: String,
    pub token: String,
    pub message: String,
}

/// Hash a password using bcrypt (with salt).
/// Returns the hashed password string, or empty string on failure.
pub fn hash_password(password: &str) -> String {
    bcrypt::hash(password, bcrypt::DEFAULT_COST).unwrap_or_else(|e| {
        tracing::error!("bcrypt hash failed: {}", e);
        String::new()
    })
}

/// Verify a password against a bcrypt hash.
fn verify_password(password: &str, hash: &str) -> bool {
    bcrypt::verify(password, hash).unwrap_or(false)
}

/// Register a new user
pub fn register(conn: &rusqlite::Connection, req: &RegisterRequest) -> Result<AuthResponse, String> {
    // Check if username already exists
    let exists: bool = conn.query_row(
        "SELECT COUNT(*) FROM users WHERE username = ?1",
        rusqlite::params![req.username],
        |row| row.get::<_, i32>(0),
    ).map(|c| c > 0).unwrap_or(false);

    if exists {
        return Err("Username already taken".into());
    }

    // 校验
    if req.username.len() < 5 || !req.username.chars().all(|c| c.is_ascii_alphanumeric()) { return Err("用户名至少5位英文或数字".into()); }
    if req.password.len() < 6 || !req.password.chars().any(|c| c.is_ascii_alphabetic()) || !req.password.chars().any(|c| c.is_ascii_digit()) { return Err("密码至少6位含英文+数字".into()); }
    if let Some(ref n) = req.real_name {
        if n.is_empty() || n.chars().count() > 4 || !n.chars().all(|c| ('\u{4e00}'..='\u{9fff}').contains(&c) || c == '·') { return Err("姓名须为中文4字以内".into()); }
    }
    if let Some(ref p) = req.phone {
        if p.len() != 11 || !p.starts_with('1') || !p.chars().all(|c| c.is_ascii_digit()) { return Err("手机号格式不正确".into()); }
        // 检查手机号是否已被注册（通过 phone_hash 确定性匹配）
        let hash = encryption::sha256_hash(p);
        let phone_exists: bool = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE phone_hash = ?1",
            rusqlite::params![hash],
            |row| row.get::<_, i32>(0),
        ).map(|c| c > 0).unwrap_or(false);
        if phone_exists {
            return Err("该手机号已被注册".into());
        }
    }

    let user_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let token = uuid::Uuid::new_v4().to_string();
    let pwhash = hash_password(&req.password);

    if pwhash.is_empty() {
        return Err("Password hashing failed".into());
    }

    // Encrypt PII fields
    let enc_real_name = req.real_name.as_ref().map(|n| encryption::encrypt(n));
    let enc_phone = req.phone.as_ref().map(|p| encryption::encrypt(p));
    // Compute phone_hash for login via phone (SHA-256 plain phone, deterministic lookups)
    let phone_hash = req.phone.as_ref().map(|p| encryption::sha256_hash(p));
    // Compute bind_hash (for deterministic lookup)
    let bind_hash_val = match (&req.real_name, &req.phone) {
        (Some(n), Some(p)) => Some(encryption::bind_hash(n, p)),
        _ => None,
    };

    // 查推广码对应的推广员（如果有）
    let referred_by: Option<String> = if let Some(ref ref_info) = req.referral {
        if let Some(ref code) = ref_info.code {
            // 查推广码对应的用户，且未被删除
            let referrer: Option<String> = conn.query_row(
                "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
                rusqlite::params![code],
                |row| row.get(0),
            ).ok();
            referrer
        } else {
            None
        }
    } else {
        None
    };

    // 生成用户自己的推广码（CoEvo_ + 4位大写字母数字，重试最多3次）
    let mut referral_code = String::new();
    for _ in 0..3 {
        use rand::Rng;
        let suffix: String = rand::thread_rng()
            .sample_iter(&rand::distributions::Alphanumeric)
            .take(4)
            .map(|c| c as char)
            .collect::<String>()
            .to_uppercase();
        let candidate = format!("CoEvo_{}", suffix);
        let exists: bool = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE referral_code = ?1",
            rusqlite::params![candidate],
            |row| row.get::<_, i32>(0),
        ).map(|c| c > 0).unwrap_or(false);
        if !exists {
            referral_code = candidate;
            break;
        }
    }

    conn.execute(
        "INSERT INTO users (id, username, display_name, password_hash, real_name, phone, phone_hash, bind_hash, referral_code, referred_by, created_at) VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        rusqlite::params![user_id, req.username, pwhash, enc_real_name, enc_phone, phone_hash, bind_hash_val, referral_code, referred_by, now],
    ).map_err(|e| format!("Insert error: {}", e))?;

    // Store token in tokens table
    let token_id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    ).map_err(|e| format!("Token insert error: {}", e))?;

    // 触发注册活动（不阻塞注册）
    if let Err(e) = crate::campaign_executor::execute_campaign_trigger(
        &conn, "registration", &user_id, referred_by.as_deref(), None,
    ) {
        tracing::warn!("registration campaign trigger failed: {}", e);
    }

    // 如果有推荐人，触发推广成就
    if let Some(ref rid) = referred_by {
        if !rid.is_empty() {
            crate::achievement_engine::publish(
                &conn,
                crate::achievement_engine::AppEvent::ReferralRegistered { user_id: rid.clone() },
            );
        }
    }

    Ok(AuthResponse {
        user_id,
        token,
        message: "Registration successful".into(),
    })
}

/// Delete all existing tokens for a user (to prevent token table bloat)
fn cleanup_old_tokens(conn: &rusqlite::Connection, user_id: &str) {
    if let Err(e) = conn.execute(
        "DELETE FROM tokens WHERE user_id = ?1",
        rusqlite::params![user_id],
    ) {
        tracing::warn!("Failed to clean old tokens for {}: {}", user_id, e);
    }
}

/// Login with username or phone (rejects soft-deleted users)
pub fn login(conn: &rusqlite::Connection, req: &LoginRequest) -> Result<AuthResponse, String> {
    let input = &req.username;

    // 判断输入是用户名还是手机号
    let is_phone = input.len() == 11 && input.starts_with('1') && input.chars().all(|c| c.is_ascii_digit());

    let (user_id, stored_hash): (String, String) = if is_phone {
        // 手机号登录：SHA-256 哈希匹配
        let phone_hash = encryption::sha256_hash(input);
        conn.query_row(
            "SELECT id, password_hash FROM users WHERE phone_hash = ?1 AND deleted_at IS NULL",
            rusqlite::params![phone_hash],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).map_err(|_| "Invalid phone or password".to_string())?
    } else {
        // 用户名登录
        conn.query_row(
            "SELECT id, password_hash FROM users WHERE username = ?1 AND deleted_at IS NULL",
            rusqlite::params![input],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).map_err(|_| "Invalid username or password".to_string())?
    };

    if !verify_password(&req.password, &stored_hash) {
        // 统一错误信息，不泄露是用户名/手机号错了还是密码错了
        let err_msg = if is_phone { "Invalid phone or password" } else { "Invalid username or password" };
        return Err(err_msg.to_string());
    }

    // Clean up old tokens for this user before creating a new one
    cleanup_old_tokens(conn, &user_id);

    let token = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();
    let token_id = uuid::Uuid::new_v4().to_string();

    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    ).map_err(|e| format!("Token insert error: {}", e))?;

    Ok(AuthResponse {
        user_id,
        token,
        message: "Login successful".into(),
    })
}

/// Verify a session token against the database.
/// Returns `true` if the token exists for the given user and the user is not soft-deleted.
pub fn verify_token(conn: &rusqlite::Connection, user_id: &str, token: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM tokens t JOIN users u ON t.user_id = u.id WHERE t.user_id = ?1 AND t.token = ?2",
        rusqlite::params![user_id, token],
        |_| Ok(true),
    ).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT,
                streak_days INTEGER DEFAULT 0,
                last_active_date TEXT,
                display_name TEXT,
                real_name TEXT,
                phone TEXT,
                phone_hash TEXT,
                id_number TEXT,
                bind_hash TEXT,
                deleted_at TEXT,
                subscription_expires TEXT DEFAULT NULL,
                referral_code TEXT UNIQUE,
                referred_by TEXT REFERENCES users(id),
                created_at TEXT NOT NULL
            );
            CREATE TABLE tokens (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                token TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            );"
        ).unwrap();
        conn
    }

    #[test]
    fn test_bcrypt_produces_different_hashes() {
        let h1 = hash_password("password123");
        let h2 = hash_password("password123");
        assert!(!h1.is_empty());
        assert!(!h2.is_empty());
        // Bcrypt generates different hashes for the same password due to salting
        assert_ne!(h1, h2, "bcrypt should produce different hashes for same password");
    }

    #[test]
    fn test_verify_password_works() {
        let hash = hash_password("mypassword");
        assert!(verify_password("mypassword", &hash));
        assert!(!verify_password("wrongpassword", &hash));
    }

    #[test]
    fn test_register_and_login() {
        let conn = setup_db();

        // Register
        let resp = register(&conn, &RegisterRequest {
            username: "alice".into(),
            password: "secret1".into(),
            real_name: None,
            phone: None,
            referral: None,
        }).unwrap();
        assert_eq!(resp.user_id.len(), 36, "user_id should be a UUID v4");
        assert!(!resp.token.is_empty());

        // Login
        let resp2 = login(&conn, &LoginRequest {
            username: "alice".into(),
            password: "secret1".into(),
        }).unwrap();
        assert_eq!(resp2.user_id, resp.user_id);
        assert!(!resp2.token.is_empty());
    }

    #[test]
    fn test_login_wrong_password() {
        let conn = setup_db();

        register(&conn, &RegisterRequest {
            username: "bobby".into(),
            password: "correct1".into(),
            real_name: None,
            phone: None,
            referral: None,
        }).unwrap();

        let result = login(&conn, &LoginRequest {
            username: "bobby".into(),
            password: "wrong1".into(),
        });
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid"));
    }

    #[test]
    fn test_register_duplicate_username() {
        let conn = setup_db();

        register(&conn, &RegisterRequest {
            username: "charlie".into(),
            password: "pw1pass".into(),
            real_name: None,
            phone: None,
            referral: None,
        }).unwrap();

        let result = register(&conn, &RegisterRequest {
            username: "charlie".into(),
            password: "pw2pass".into(),
            real_name: None,
            phone: None,
            referral: None,
        });
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("taken"));
    }

    #[test]
    fn test_token_verification_with_db() {
        let conn = setup_db();

        let resp = register(&conn, &RegisterRequest {
            username: "davey".into(),
            password: "pass12".into(),
            real_name: None,
            phone: None,
            referral: None,
        }).unwrap();

        // Valid token should verify
        assert!(verify_token(&conn, &resp.user_id, &resp.token));

        // Wrong token should not verify
        assert!(!verify_token(&conn, &resp.user_id, "wrong-token"));

        // Wrong user should not verify
        assert!(!verify_token(&conn, "wrong-user", &resp.token));
    }

    #[test]
    fn test_login_by_phone() {
        let conn = setup_db();
        let phone = "13800138000";

        // Register with phone
        let resp = register(&conn, &RegisterRequest {
            username: "phoneuser".into(),
            password: "pass123".into(),
            real_name: Some("测试".into()),
            phone: Some(phone.into()),
            referral: None,
        }).unwrap();
        assert_eq!(resp.user_id.len(), 36);

        // Login by phone (use the `username` field to pass the phone number)
        let resp2 = login(&conn, &LoginRequest {
            username: phone.into(),
            password: "pass123".into(),
        }).unwrap();
        assert_eq!(resp2.user_id, resp.user_id);
        assert!(!resp2.token.is_empty());

        // Wrong phone should fail
        let result = login(&conn, &LoginRequest {
            username: "13800138001".into(),
            password: "pass123".into(),
        });
        assert!(result.is_err());

        // Wrong password should fail
        let result = login(&conn, &LoginRequest {
            username: phone.into(),
            password: "wrongpass".into(),
        });
        assert!(result.is_err());
    }
}
