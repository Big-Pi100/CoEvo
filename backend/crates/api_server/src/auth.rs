//! Auth — User registration and login
//!
//! Uses bcrypt for password hashing and UUID v4 for session tokens.
//! Tokens are stored in the `tokens` table for server-side verification.

use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
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
fn hash_password(password: &str) -> String {
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

    let user_id = format!("user_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
    let now = chrono::Utc::now().to_rfc3339();
    let token = uuid::Uuid::new_v4().to_string();
    let pwhash = hash_password(&req.password);

    if pwhash.is_empty() {
        return Err("Password hashing failed".into());
    }

    conn.execute(
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES (?1, ?2, ?2, ?3, ?4)",
        rusqlite::params![user_id, req.username, pwhash, now],
    ).map_err(|e| format!("Insert error: {}", e))?;

    // Store token in tokens table
    let token_id = uuid::Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO tokens (id, user_id, token, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![token_id, user_id, token, now],
    ).map_err(|e| format!("Token insert error: {}", e))?;

    Ok(AuthResponse {
        user_id,
        token,
        message: "Registration successful".into(),
    })
}

/// Login with username and password
pub fn login(conn: &rusqlite::Connection, req: &LoginRequest) -> Result<AuthResponse, String> {
    // Fetch user id and password hash
    let (user_id, stored_hash): (String, String) = conn.query_row(
        "SELECT id, password_hash FROM users WHERE username = ?1",
        rusqlite::params![req.username],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).map_err(|_| "Invalid username or password".to_string())?;

    if !verify_password(&req.password, &stored_hash) {
        return Err("Invalid username or password".to_string());
    }

    let token = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
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
/// Returns `true` if the token exists for the given user.
pub fn verify_token(conn: &rusqlite::Connection, user_id: &str, token: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM tokens WHERE user_id = ?1 AND token = ?2",
        rusqlite::params![user_id, token],
        |_| Ok(true),
    ).unwrap_or(false)
}

/// Verify a session token without a DB connection.
/// This is a fallback that performs a basic non-empty check.
/// Prefer `verify_token` with a DB connection for real security.
pub fn verify_token_no_db(_user_id: &str, token: &str) -> bool {
    !token.is_empty()
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
            password: "secret".into(),
        }).unwrap();
        assert!(resp.user_id.starts_with("user_"));
        assert!(!resp.token.is_empty());

        // Login
        let resp2 = login(&conn, &LoginRequest {
            username: "alice".into(),
            password: "secret".into(),
        }).unwrap();
        assert_eq!(resp2.user_id, resp.user_id);
        assert!(!resp2.token.is_empty());
    }

    #[test]
    fn test_login_wrong_password() {
        let conn = setup_db();

        register(&conn, &RegisterRequest {
            username: "bob".into(),
            password: "correct".into(),
        }).unwrap();

        let result = login(&conn, &LoginRequest {
            username: "bob".into(),
            password: "wrong".into(),
        });
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid"));
    }

    #[test]
    fn test_register_duplicate_username() {
        let conn = setup_db();

        register(&conn, &RegisterRequest {
            username: "charlie".into(),
            password: "pw1".into(),
        }).unwrap();

        let result = register(&conn, &RegisterRequest {
            username: "charlie".into(),
            password: "pw2".into(),
        });
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("taken"));
    }

    #[test]
    fn test_token_verification_with_db() {
        let conn = setup_db();

        let resp = register(&conn, &RegisterRequest {
            username: "dave".into(),
            password: "pass".into(),
        }).unwrap();

        // Valid token should verify
        assert!(verify_token(&conn, &resp.user_id, &resp.token));

        // Wrong token should not verify
        assert!(!verify_token(&conn, &resp.user_id, "wrong-token"));

        // Wrong user should not verify
        assert!(!verify_token(&conn, "wrong-user", &resp.token));
    }

    #[test]
    fn test_verify_token_no_db_fallback() {
        assert!(verify_token_no_db("any", "some-token"));
        assert!(!verify_token_no_db("any", ""));
    }
}
