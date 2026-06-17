//! 套餐管理 Handler — 用户端 + 管理端

use axum::{
    extract::Query,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
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
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("查询套餐失败: {}", e)).into_response(),
    }
}

/// GET /api/admin/plans — 管理端：所有套餐（含已下架）
pub async fn admin_plans_list_handler() -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT id, name, duration_days, price, max_uses, used_count,
                once_per_user, available_from, available_until, sort_order, is_active, created_at
         FROM subscription_plans ORDER BY sort_order ASC"
    ) {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "name": row.get::<_, String>(1)?,
            "duration_days": row.get::<_, Option<i64>>(2)?,
            "price": row.get::<_, i64>(3)?,
            "max_uses": row.get::<_, Option<i64>>(4)?,
            "used_count": row.get::<_, i64>(5)?,
            "once_per_user": row.get::<_, i64>(6)?,
            "available_from": row.get::<_, Option<String>>(7)?,
            "available_until": row.get::<_, Option<String>>(8)?,
            "sort_order": row.get::<_, i64>(9)?,
            "is_active": row.get::<_, i64>(10)?,
            "created_at": row.get::<_, String>(11)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    (StatusCode::OK, json!({"plans": rows}).to_string()).into_response()
}

/// POST /api/admin/plans — 新增套餐
pub async fn admin_plan_create_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let id = match payload.get("id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return (StatusCode::BAD_REQUEST, "id 不能为空").into_response(),
    };
    let name = match payload.get("name").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return (StatusCode::BAD_REQUEST, "name 不能为空").into_response(),
    };
    let duration_days = payload.get("duration_days").and_then(|v| v.as_i64());
    let price = payload.get("price").and_then(|v| v.as_i64()).unwrap_or(0);
    let max_uses = payload.get("max_uses").and_then(|v| v.as_i64());
    let once_per_user = payload.get("once_per_user").and_then(|v| v.as_i64()).unwrap_or(0);
    let sort_order = payload.get("sort_order").and_then(|v| v.as_i64()).unwrap_or(0);
    let available_from = payload.get("available_from").and_then(|v| v.as_str()).map(|s| s.to_string());
    let available_until = payload.get("available_until").and_then(|v| v.as_str()).map(|s| s.to_string());

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    if let Err(e) = conn.execute(
        "INSERT INTO subscription_plans (id, name, duration_days, price, max_uses, once_per_user, sort_order, available_from, available_until, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        rusqlite::params![id, name, duration_days, price, max_uses, once_per_user, sort_order, available_from, available_until, now],
    ) {
        return (StatusCode::CONFLICT, format!("创建套餐失败: {}", e)).into_response();
    }

    (StatusCode::CREATED, json!({"id": id}).to_string()).into_response()
}

/// PUT /api/admin/plans/{id} — 编辑套餐
pub async fn admin_plan_update_handler(
    axum::extract::Path(plan_id): axum::extract::Path<String>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // 构建动态 UPDATE
    let mut sets = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(name) = payload.get("name").and_then(|v| v.as_str()) {
        sets.push("name = ?");
        params.push(Box::new(name.to_string()));
    }
    if let Some(d) = payload.get("duration_days") {
        sets.push("duration_days = ?");
        params.push(Box::new(d.as_i64()));
    }
    if let Some(p) = payload.get("price") {
        sets.push("price = ?");
        params.push(Box::new(p.as_i64().unwrap_or(0)));
    }
    if let Some(m) = payload.get("max_uses") {
        sets.push("max_uses = ?");
        params.push(Box::new(m.as_i64()));
    }
    if let Some(o) = payload.get("once_per_user") {
        sets.push("once_per_user = ?");
        params.push(Box::new(o.as_i64().unwrap_or(0)));
    }
    if let Some(s) = payload.get("sort_order") {
        sets.push("sort_order = ?");
        params.push(Box::new(s.as_i64().unwrap_or(0)));
    }
    if let Some(v) = payload.get("is_active") {
        sets.push("is_active = ?");
        params.push(Box::new(if v.as_bool().unwrap_or(false) { 1 } else { 0 }));
    }
    if payload.get("available_from").is_some() {
        sets.push("available_from = ?");
        params.push(Box::new(payload["available_from"].as_str().map(|s| s.to_string())));
    }
    if payload.get("available_until").is_some() {
        sets.push("available_until = ?");
        params.push(Box::new(payload["available_until"].as_str().map(|s| s.to_string())));
    }

    if sets.is_empty() {
        return (StatusCode::BAD_REQUEST, "没有需要更新的字段").into_response();
    }

    let sql = format!(
        "UPDATE subscription_plans SET {} WHERE id = ?",
        sets.join(", ")
    );
    params.push(Box::new(plan_id));

    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    if let Err(e) = conn.execute(&sql, param_refs.as_slice()) {
        return (StatusCode::INTERNAL_SERVER_ERROR, format!("更新失败: {}", e)).into_response();
    }

    (StatusCode::OK, json!({"status": "ok"}).to_string()).into_response()
}
