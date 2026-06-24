//! 活动成员管理 Handler
//!
//! 提供入会 API，用户通过活动链接进入时记录参与关系。
//! 拼团/砍价等共同活动通过此表追踪人数。

use axum::{Json, http::StatusCode, response::IntoResponse};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
pub struct JoinRequest {
    pub campaign_id: String,
    pub user_id: String,
    pub role: Option<String>,  // 'leader' | 'member'
}

/// POST /api/campaign/join — 加入活动
///
/// 记录用户参与活动的关系。幂等：同一用户同一活动只记录一次。
/// 返回当前活动总人数。
pub async fn join(
    Json(body): Json<JoinRequest>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let role = body.role.as_deref().unwrap_or("member");

    // 幂等写入：PRIMARY KEY (campaign_id, user_id) 自动防重
    if let Err(e) = conn.execute(
        "INSERT OR IGNORE INTO campaign_members (campaign_id, user_id, role, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![body.campaign_id, body.user_id, role, now],
    ) {
        tracing::warn!("campaign_members insert failed: {}", e);
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "join_failed"}))).into_response();
    }

    // 查询当前人数
    let member_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM campaign_members WHERE campaign_id = ?1",
        rusqlite::params![body.campaign_id],
        |row| row.get(0),
    ).unwrap_or(0);

    (StatusCode::OK, Json(json!({
        "status": "ok",
        "campaign_id": body.campaign_id,
        "user_id": body.user_id,
        "role": role,
        "member_count": member_count,
    }))).into_response()
}
