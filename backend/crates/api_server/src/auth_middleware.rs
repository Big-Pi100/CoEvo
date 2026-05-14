//! Token verification middleware helper
//!
//! Validates `Authorization: Bearer <token>` headers against user_id.
//! Used as a helper function in route handlers — not an Axum middleware layer
//! (to avoid body consumption issues with POST/WS endpoints).

use axum::http::HeaderMap;

/// Verify that the Authorization header contains a valid Bearer token for the given user.
///
/// Returns `Ok(())` if valid, `Err(message)` otherwise.
/// Note: MVP trusts any non-empty token; future versions should verify against stored tokens.
pub fn verify_auth(user_id: &str, headers: &HeaderMap) -> Result<(), String> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(|| "Missing or invalid Authorization header".to_string())?;

    // MVP: verify_token is a pure check (non-empty token), no DB access needed
    if crate::auth::verify_token_no_db(user_id, token) {
        Ok(())
    } else {
        Err("Invalid or expired token".to_string())
    }
}

/// Routes that don't require auth
pub fn needs_auth(path: &str) -> bool {
    !path.starts_with("/api/auth/") && path != "/health"
}
