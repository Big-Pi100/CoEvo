//! Unified error types for CoEvo API server.
//!
//! Replaces ad-hoc `String` errors and `Json(serde_json::json!({"error": ...}))`
//! with structured, thiserror-powered error handling.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

/// Application-level error, implements `IntoResponse` for direct use in handlers.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    /// Authentication / authorization failure → 401
    #[error("{0}")]
    Unauthorized(String),

    /// Invalid input / bad request → 400
    #[error("{0}")]
    BadRequest(String),

    /// Resource not found → 404
    #[error("{0}")]
    NotFound(String),

    /// Internal server error → 500
    #[error("{0}")]
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            AppError::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg.clone()),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg.clone()),
            AppError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg.clone()),
        };
        (status, Json(serde_json::json!({"error": message}))).into_response()
    }
}

/// Convenience: convert a `Result<T, String>` into `Result<T, AppError>` with the given variant.
pub trait IntoAppError<T> {
    fn or_unauthorized(self) -> Result<T, AppError>;
    fn or_bad_request(self) -> Result<T, AppError>;
    fn or_not_found(self) -> Result<T, AppError>;
    fn or_internal(self) -> Result<T, AppError>;
}

impl<T> IntoAppError<T> for Result<T, String> {
    fn or_unauthorized(self) -> Result<T, AppError> {
        self.map_err(AppError::Unauthorized)
    }
    fn or_bad_request(self) -> Result<T, AppError> {
        self.map_err(AppError::BadRequest)
    }
    fn or_not_found(self) -> Result<T, AppError> {
        self.map_err(AppError::NotFound)
    }
    fn or_internal(self) -> Result<T, AppError> {
        self.map_err(AppError::Internal)
    }
}
