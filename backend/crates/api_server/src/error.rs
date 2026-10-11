//! Unified error types for the 记忆之书 API server.
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

    /// Authenticated but **not allowed** → 403
    ///
    /// 🔴 与 `Unauthorized` 的区别**不是**措辞，而是**客户端的反应**：
    ///    端侧收到 401 的标准处理是「token 失效 ⇒ 清凭据 ⇒ 跳登录」。
    ///    若把「已登录但没订阅」也回 401 ⇒ 用户会被**莫名登出**
    ///    （而且他会以为自己账号出了问题）。
    /// ⇒ 「谁」不对 = 401；「谁对了但这件事不让做」= 403。
    /// 首个使用点：同步接口（订阅权益 · 决策③）。
    #[error("{0}")]
    Forbidden(String),

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
            AppError::Forbidden(msg) => (StatusCode::FORBIDDEN, msg.clone()),
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

// ── 轻量响应工具 ──

/// 直接返回 JSON 的 200 响应。
///
/// 🔄 **2026-10-06 从 `admin_handlers.rs` 迁来**：它原本定义在那里，但被
/// `distribution_handler`（通知）等模块 `use` —— 删 admin 链时若跟着删掉，
/// 「通知」这类**保留功能**会一起断掉。判别依据见
/// `docs/review/backend-dead-route-cleanup-2026-10-06.md` §二 陷阱 4。
pub(crate) fn ok(v: serde_json::Value) -> Response {
    Json(v).into_response()
}

/// 返回 `{"error": msg}` 形态的指定状态码响应。
pub(crate) fn err(code: StatusCode, msg: &str) -> Response {
    (code, Json(serde_json::json!({ "error": msg }))).into_response()
}
