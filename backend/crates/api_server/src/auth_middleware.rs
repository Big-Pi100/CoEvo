//! Token verification middleware helper
//!
//! Validates `Authorization: Bearer <token>` headers against user_id.
//! Used as a helper function in route handlers — not an Axum middleware layer
//! (to avoid body consumption issues with POST/WS endpoints).

use crate::error::AppError;
use axum::http::HeaderMap;

/// Verify that the Authorization header contains a valid Bearer token for the given user.
///
/// Returns `Ok(())` if valid, `Err(AppError::Unauthorized)` otherwise.
/// Performs DB lookup against the `tokens` table for real security.
pub fn verify_auth(user_id: &str, headers: &HeaderMap) -> Result<(), AppError> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(|| AppError::Unauthorized("Missing or invalid Authorization header".into()))?;

    let conn = crate::db_pool::get_conn();
    if crate::auth::verify_token(&conn, user_id, token) {
        Ok(())
    } else {
        Err(AppError::Unauthorized("Invalid or expired token".into()))
    }
}

/// Route-level auth bypass list (TODO P1-1: use with Axum middleware layer)
#[allow(dead_code)]
pub fn needs_auth(path: &str) -> bool {
    !path.starts_with("/api/auth/") && path != "/health"
}
