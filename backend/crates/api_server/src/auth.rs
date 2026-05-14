//! Auth — User registration and login
//!
//! Uses SHA-256 for password hashing and UUID v4 for session tokens.
//! Adapted from LinguaFlow: uses username + password_hash (CoEvo schema).

use serde::{Deserialize, Serialize};
use sha2::{Sha256, Digest};

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

#[derive(Serialize)]
pub struct AuthResponse {
    pub user_id: String,
    pub token: String,
    pub message: String,
}

fn hash_password(password: &str) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    hasher.finalize().to_vec()
}

fn hash_to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
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
    let pwhash = hash_to_hex(&hash_password(&req.password));
    let _token_hash = hash_to_hex(&hash_password(&token));

    conn.execute(
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES (?1, ?2, ?2, ?3, ?4)",
        rusqlite::params![user_id, req.username, pwhash, now],
    ).map_err(|e| format!("Insert error: {}", e))?;

    // Store token in a simple way — re-use password_hash field for verification
    // or use a separate approach. For MVP, store token_hash in password_hash.
    // Actually for simplicity, the client holds the token and we verify it.
    // Token is not stored in DB for MVP.

    Ok(AuthResponse {
        user_id,
        token,
        message: "Registration successful".into(),
    })
}

/// Login with username and password
pub fn login(conn: &rusqlite::Connection, req: &LoginRequest) -> Result<AuthResponse, String> {
    let pwhash = hash_to_hex(&hash_password(&req.password));

    let user_id: String = conn.query_row(
        "SELECT id FROM users WHERE username = ?1 AND password_hash = ?2",
        rusqlite::params![req.username, pwhash],
        |row| row.get(0),
    ).map_err(|_| "Invalid username or password".to_string())?;

    let token = uuid::Uuid::new_v4().to_string();

    Ok(AuthResponse {
        user_id,
        token,
        message: "Login successful".into(),
    })
}

/// Verify a session token.
/// MVP: token is verified client-side only.
/// For simplicity, we accept any non-empty token.
pub fn verify_token(_conn: &rusqlite::Connection, _user_id: &str, _token: &str) -> bool {
    // MVP: trust the client. Future: JWT or stored tokens.
    !_token.is_empty()
}

/// Pure version of verify_token — no DB connection needed (MVP).
pub fn verify_token_no_db(_user_id: &str, token: &str) -> bool {
    !token.is_empty()
}
