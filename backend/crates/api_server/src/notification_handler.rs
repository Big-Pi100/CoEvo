//! 用户通知中心 —— `user_notifications` 的读写
//!
//! | 接口 | 说明 |
//! |---|---|
//! | `GET  /api/notifications` | 最近 50 条 + 未读数 |
//! | `POST /api/notifications/{id}/read` | 标记单条已读 |
//! | `POST /api/notifications/read-all` | 全部已读 |
//!
//! ## 🔄 2026-10-06 从 `distribution_handler.rs` 拆出
//!
//! 通知与「分销佣金 / 提现 / 结算」**没有任何关系**，只是当初恰好写在同一个文件里。
//! 删除分销链时它必须留下 —— 它是通知中心（`app.dart` 的 `NotificationPanel`）
//! **唯一的数据源**。
//!
//! 🔴 **整文件删 `distribution_handler.rs` 会让通知静默失效**：
//! 编译通过、app 正常启动，只是「我的」页点进通知中心**永远空白**。
//! ⇒ 这是本次清理最重要的一处「多职责」陷阱。
//! 📄 依据：`docs/review/backend-dead-route-cleanup-2026-10-06.md` §二 陷阱 1
//!
//! ## 🔴 当前「无生产写入方」—— 这是**有意**的状态，不是遗漏
//!
//! `user_notifications` 的写入原先全部来自**营销活动**（活动推送 / cron 推送），
//! 它们随分销链一并退役 ⇒ 库里这张表暂时**不会再新增行**。
//!
//! 保留读取侧的理由：通知中心是产品功能（「我的」页入口 + 角标），
//! 后续要接的是**账号类通知**（订阅到期提醒、找回密码提示等），
//! 那些场景调用本文件的 [`write_notification`] 即可 —— **不用再建接口、不用改端侧**。
//!
//! ⚠️ 接手时注意：**不要因为「表里没数据」就把读取侧也删掉** —— 那会把端侧入口一起废掉。

use axum::response::IntoResponse;
use axum::{
    extract::{Path, Query},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::error::{err, ok};

#[derive(Deserialize)]
pub struct UserQuery {
    pub user_id: String,
}

/// `GET /api/notifications` —— 通知列表
pub async fn list_notifications(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("list_notifications: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();

    let mut stmt = match conn.prepare(
        "SELECT id, notification_type, title, body, read, action_url, created_at \
         FROM user_notifications WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 50",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let notifications: Vec<serde_json::Value> =
        match stmt.query_map(rusqlite::params![query.user_id], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "notification_type": row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                "title": row.get::<_, String>(2)?,
                "body": row.get::<_, Option<String>>(3)?,
                "read": row.get::<_, i32>(4)? != 0,
                "action_url": row.get::<_, Option<String>>(5)?,
                "created_at": row.get::<_, String>(6)?,
            }))
        }) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("query_error: {}", e),
                )
            }
        };

    let unread_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM user_notifications WHERE user_id = ?1 AND read = 0",
            rusqlite::params![query.user_id],
            |row| row.get(0),
        )
        .unwrap_or(0);

    ok(json!({"notifications": notifications, "unread_count": unread_count}))
}

/// `POST /api/notifications/{id}/read` —— 标记单条已读
pub async fn mark_read(
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("mark_read: id={}, user_id={}", id, body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE user_notifications SET read = 1 WHERE id = ?1 AND user_id = ?2",
        rusqlite::params![id, body.user_id],
    ) {
        Ok(_) => ok(json!({"status": "ok"})),
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("db_error: {}", e),
        ),
    }
}

/// `POST /api/notifications/read-all` —— 全部已读
pub async fn mark_read_all(headers: HeaderMap, Json(body): Json<UserQuery>) -> impl IntoResponse {
    tracing::info!("mark_read_all: user_id={}", body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE user_notifications SET read = 1 WHERE user_id = ?1 AND read = 0",
        rusqlite::params![body.user_id],
    ) {
        Ok(updated) => ok(json!({"status": "ok", "updated": updated})),
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("db_error: {}", e),
        ),
    }
}

/// 写一条通知 —— **供内部模块调用**（不出现在路由表里）。
///
/// 🔄 **2026-10-06 从 `campaign_executor.rs` 迁来**：原调用方是营销活动的
/// cron 推送，已随分销链退役 ⇒ 本函数**当前无生产调用方**（见模块头说明）。
///
/// 🔑 保留它的意义：后续「订阅到期提醒」等账号类通知**直接调这里**即可，
/// 不用再写 INSERT、不用再对一遍列名。
///
/// ⚠️ 它会生成新 `id` 并**无条件插入**（不去重）—— 若调用方可能重复触发，
/// 请自行在调用前查重（原 cron 推送就是在调用方做的 60 秒内去重）。
pub fn write_notification(
    conn: &rusqlite::Connection,
    user_id: &str,
    notification_type: &str,
    title: &str,
    body: &str,
    action_url: Option<&str>,
) -> Result<String, String> {
    let nid = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    conn.execute(
        "INSERT INTO user_notifications \
         (id, user_id, notification_type, title, body, action_url, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            nid,
            user_id,
            notification_type,
            title,
            body,
            action_url,
            now
        ],
    )
    .map_err(|e| format!("write notification failed: {}", e))?;
    Ok(nid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE user_notifications (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                notification_type TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT,
                read INTEGER DEFAULT 0,
                action_url TEXT,
                created_at TEXT NOT NULL
            );",
        )
        .unwrap();
        conn
    }

    #[test]
    fn write_notification_inserts_row() {
        let conn = setup();
        let id = write_notification(&conn, "u1", "system", "标题", "正文", Some("/x")).unwrap();
        let (n, read): (i64, i64) = conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(read),0) FROM user_notifications WHERE id = ?1",
                rusqlite::params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(n, 1, "应写入 1 条");
        assert_eq!(read, 0, "新通知默认未读");
    }

    #[test]
    fn write_notification_allows_null_action_url() {
        let conn = setup();
        write_notification(&conn, "u1", "system", "t", "b", None).unwrap();
        let cnt: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM user_notifications WHERE action_url IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cnt, 1);
    }

    #[test]
    fn write_notification_does_not_dedupe() {
        // 🔑 明确锁定「不去重」这个契约 —— 调用方需自行查重
        let conn = setup();
        write_notification(&conn, "u1", "system", "同标题", "b", Some("/same")).unwrap();
        write_notification(&conn, "u1", "system", "同标题", "b", Some("/same")).unwrap();
        let cnt: i64 = conn
            .query_row("SELECT COUNT(*) FROM user_notifications", [], |r| r.get(0))
            .unwrap();
        assert_eq!(cnt, 2, "两次调用应产生两行（去重是调用方的责任）");
    }
}
