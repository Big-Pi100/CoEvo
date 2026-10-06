//! 套餐管理 Handler — **用户端**
//!
//! 🔴 2026-10-06：管理端三个 handler（`admin_plans_list` / `admin_plan_create` /
//!    `admin_plan_update`）随 58 条 `/api/admin/*` 路由一并删除。
//!    本文件只留用户端 `plans_list_handler`（`GET /api/pay/plans` → app 订阅页）。
//!    见 `docs/review/backend-dead-route-cleanup-2026-10-06.md`

use axum::{extract::Query, http::StatusCode, response::IntoResponse};
use serde::Deserialize;
use serde_json::json;

use crate::subscription;

/// GET /api/pay/plans?user_id=xxx — 用户端：获取可购买套餐列表
#[derive(Deserialize)]
pub struct PlansQuery {
    pub user_id: Option<String>,
}

pub async fn plans_list_handler(Query(query): Query<PlansQuery>) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    match subscription::get_available_plans(&conn, query.user_id.as_deref()) {
        Ok(plans) => (StatusCode::OK, json!({"plans": plans}).to_string()).into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("查询套餐失败: {}", e),
        )
            .into_response(),
    }
}
