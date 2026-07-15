//! Review defer queue handlers
//!
//! GET  /api/review/status  — 查询用户是否在推迟期以及到期卡片数
//! POST /api/review/defer   — 将指定卡片推迟一段时间（UPSERT defer_queue 表）

use axum::{Json, extract::Query, http::HeaderMap};
use serde::Deserialize;
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};

/// 查询用户到期卡片数量
fn query_due_count(conn: &crate::db_pool::DbConn, user_id: &str, conversation_id: &Option<String>, now: i64) -> i64 {
    let (sql_where, sql_params): (&str, Vec<Box<dyn rusqlite::types::ToSql>>) =
        if let Some(ref conv_id) = conversation_id {
            if !conv_id.is_empty() {
                ("AND pr.conversation_id = ?3", vec![
                    Box::new(conv_id.clone()) as Box<dyn rusqlite::types::ToSql>,
                ])
            } else {
                ("", vec![])
            }
        } else {
            ("", vec![])
        };

    let sql = format!(
        "SELECT COUNT(*) FROM card_memory cm
         JOIN user_cards u ON cm.user_card_id = u.id
         JOIN plan_runs pr ON u.plan_run_id = pr.id
         WHERE u.user_id = ?1
           AND cm.due <= ?2
           AND cm.status = 'active'
           {}",
        sql_where
    );

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("defer status due_count prepare: {}", e);
            return 0;
        }
    };

    let mut all_params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![
        Box::new(user_id.to_string()),
    ];
    all_params.push(Box::new(now));
    all_params.extend(sql_params);

    let param_refs: Vec<&dyn rusqlite::types::ToSql> = all_params.iter().map(|b| b.as_ref()).collect();
    match stmt.query_row(param_refs.as_slice(), |row| row.get::<_, i64>(0)) {
        Ok(count) => count,
        Err(e) => {
            tracing::warn!("defer status due_count query: {}", e);
            0
        }
    }
}

/// 当前 Unix 时间戳（秒）
fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

// ── GET /api/review/status ──

#[derive(Deserialize)]
pub struct StatusQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
}

/// GET /api/review/status
///
/// 查询用户复习推迟状态 + 到期卡片数：
///   - 查 defer_queue 判断是否在推迟期
///   - 查 card_memory.due <= now 统计到期卡片数
/// 响应: {"has_due":bool, "due_count":i64, "is_deferred":bool,
///        "deferred_until":i64, "remaining_seconds":i64}
pub async fn status_handler(
    headers: HeaderMap,
    Query(query): Query<StatusQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("[review] status_handler: user_id={}, conv_id={:?}", query.user_id, query.conversation_id);
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return crate::routes::auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let now = now_secs();

    // 查 defer_queue（按会话级别查询）
    let conv_defer = match &query.conversation_id {
        Some(cid) if !cid.is_empty() => cid.clone(),
        _ => String::new(),
    };
    let (is_deferred, deferred_until): (bool, i64) = match conn.query_row(
        "SELECT deferred_until FROM defer_queue WHERE user_id = ?1 AND conversation_id = ?2",
        rusqlite::params![query.user_id, conv_defer],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(until) => (until > now, until),
        Err(_) => (false, 0),
    };

    let remaining_seconds = if is_deferred {
        deferred_until - now
    } else {
        0i64
    };

    // 查到期卡片数（card_memory.due <= now）
    let due_count: i64 = query_due_count(&conn, &query.user_id, &query.conversation_id, now);

    tracing::info!("[review] status_handler result: user_id={}, has_due={}, due_count={}, is_deferred={}", 
        query.user_id, due_count > 0, due_count, is_deferred);

    Json(json!({
        "has_due": due_count > 0,
        "due_count": due_count,
        "is_deferred": is_deferred,
        "deferred_until": deferred_until,
        "remaining_seconds": remaining_seconds,
    }))
}

// ── POST /api/review/defer ──

#[derive(Deserialize)]
pub struct DeferInput {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub defer_seconds: i64,
    pub card_ids: Vec<String>,
}

/// POST /api/review/defer
///
/// 推迟复习：
///   - UPSERT defer_queue 表（按 user_id + conversation_id）
///   - deferred_until = now + defer_seconds
/// 边界处理：
///   - defer_seconds < 60 → 强制设为 60（最小 1 分钟）
///   - defer_seconds > 86400*30 → 强制设为 86400*30（最长 30 天）
/// 请求: {"user_id":"str", "conversation_id":"str", "defer_seconds":1800, "card_ids":["c1","c2"]}
/// 响应: {"status":"ok", "deferred_until":i64, "card_ids_deferred":usize}
pub async fn defer_handler(
    headers: HeaderMap,
    Json(input): Json<DeferInput>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return crate::routes::auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let now = now_secs();

    // 边界检查：defer_seconds 必须在 60s ~ 30 天之间
    let clamped_seconds = input.defer_seconds.clamp(60, 86400 * 30);
    if clamped_seconds != input.defer_seconds {
        tracing::warn!(
            "defer_handler: defer_seconds clamped from {} to {}",
            input.defer_seconds, clamped_seconds
        );
    }

    let deferred_until = now + clamped_seconds;
    let card_ids_json = serde_json::to_string(&input.card_ids).unwrap_or_else(|_| "[]".to_string());
    let conv_id = input.conversation_id.unwrap_or_default();

    match conn.execute(
        "INSERT OR REPLACE INTO defer_queue (user_id, conversation_id, deferred_until, card_ids, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![input.user_id, conv_id, deferred_until, card_ids_json, now],
    ) {
        Ok(_) => {
            tracing::info!(
                "defer_handler: user_id={}, conv_id={}, deferred_until={}, cards={}",
                input.user_id, conv_id, deferred_until, input.card_ids.len()
            );
            Json(json!({
                "status": "ok",
                "deferred_until": deferred_until,
                "card_ids_deferred": input.card_ids.len(),
            }))
        }
        Err(e) => {
            tracing::error!("defer_handler DB error: {}", e);
            Json(json!({"error": format!("DB error: {}", e)}))
        }
    }
}
