//! 公共资源托管 API
//!
//! - `GET /api/public/qrcode` —— 微信共读群二维码
//!
//! 🔄 **2026-10-06 由 `config_admin.rs` 改名而来**：原文件同时承载
//! 「admin 运行时配置 / prompt 模板 CRUD」+「公共二维码」两组职责；
//! 前两组随 58 条 `/api/admin/*` 路由一并退役，只留二维码
//! ⇒ 文件名已与内容不符（既不管 config 也不管 admin）⇒ 改名为 `public_assets`。
//!
//! 📄 退役依据：`docs/review/backend-dead-route-cleanup-2026-10-06.md`

use axum::response::IntoResponse;

/// `GET /api/public/qrcode` —— 返回服务器上的群二维码图片
///
/// 读 `data/service_weixin.jpg`（生产 `WorkingDirectory=/opt/coevo`
/// ⇒ 实际路径 `/opt/coevo/data/service_weixin.jpg`）。
///
/// 🔑 **传图即换码** —— 换群只需替换服务器上的文件，**无需改代码、无需发版**。
/// ⚠️ 微信群二维码 **7 天过期**，需定期更换（`docs/operations/wechat-study-group-plan-2026-10-04.md`）。
/// 🔴 失败时**不要**返回 404 —— 端侧会当成「功能坏了」；返回可读文案更清楚。
pub async fn qrcode_handler() -> impl IntoResponse {
    let img_path = "data/service_weixin.jpg";
    match tokio::fs::read(img_path).await {
        Ok(data) => axum::response::Response::builder()
            .header(axum::http::header::CONTENT_TYPE, "image/jpeg")
            .body(axum::body::Body::from(data))
            .unwrap(),
        Err(_) => axum::response::Response::builder()
            .header(
                axum::http::header::CONTENT_TYPE,
                "text/plain; charset=utf-8",
            )
            .body(axum::body::Body::from("二维码图片未配置，请联系管理员。"))
            .unwrap(),
    }
}
