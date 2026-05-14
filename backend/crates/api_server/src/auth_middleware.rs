//! Token verification middleware helper
//!
//! Validates `Authorization: Bearer <token>` headers against user_id.
//! Used as a helper function in route handlers — not an Axum middleware layer
//! (to avoid body consumption issues with POST/WS endpoints).

use axum::http::HeaderMap;

/// Verify that the Authorization header contains a valid Bearer token for the given user.
///
/// Returns `Ok(())` if valid, `Err(message)` otherwise.
/// Performs DB lookup against the `tokens` table for real security.
pub fn verify_auth(user_id: &str, headers: &HeaderMap) -> Result<(), String> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(|| "Missing or invalid Authorization header".to_string())?;

    let conn = crate::db_pool::get_conn();
    if crate::auth::verify_token(&conn, user_id, token) {
        Ok(())
    } else {
        Err("Invalid or expired token".to_string())
    }
}

/// Routes that don't require auth
pub fn needs_auth(path: &str) -> bool {
    !path.starts_with("/api/auth/") && path != "/health"
}
