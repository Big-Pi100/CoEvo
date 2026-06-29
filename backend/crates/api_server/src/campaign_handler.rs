//! 管理端活动 CRUD API — 真实业务逻辑
//!
//! 包括：活动列表/创建/详情/更新/删除/启停/推送/统计

use axum::{Json, http::{HeaderMap, StatusCode}, extract::{Path, Query}};
use serde::Deserialize;
use serde_json::json;
use axum::response::IntoResponse;

use crate::admin_handlers::{verify_admin, ok, err};

#[derive(Deserialize)]
pub struct CheckPushTriggerQuery {
    pub push_trigger: String,
    pub user_id: Option<String>,
}

// ── 请求结构 ──

#[derive(Deserialize)]
pub struct CampaignFilter {
    pub status: Option<String>,
}

#[derive(Deserialize)]
pub struct StatusUpdate {
    pub status: String,
}

/// GET /api/admin/campaigns — 活动列表
pub async fn list(
    headers: HeaderMap,
    Query(filter): Query<CampaignFilter>,
) -> impl IntoResponse {
    tracing::info!("campaign_list: status={:?}", filter.status);

    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    let sql = if filter.status.is_some() {
        "SELECT * FROM marketing_campaigns WHERE status = ?1 ORDER BY created_at DESC".to_string()
    } else {
        "SELECT * FROM marketing_campaigns ORDER BY created_at DESC".to_string()
    };

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("db_error: {}", e)),
    };

    let rows = if let Some(ref status) = filter.status {
        stmt.query_map(rusqlite::params![status], map_campaign_row)
    } else {
        stmt.query_map([], map_campaign_row)
    };

    let campaigns: Vec<serde_json::Value> = match rows {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("query_error: {}", e)),
    };

    ok(json!({"campaigns": campaigns}))
}

/// POST /api/admin/campaigns — 创建活动
pub async fn create(
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    tracing::info!("campaign_create");

    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    let name = payload.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let campaign_type = payload.get("campaign_type").and_then(|v| v.as_str()).unwrap_or("standard");
    let description = payload.get("description").and_then(|v| v.as_str());
    let status = payload.get("status").and_then(|v| v.as_str()).unwrap_or("draft");
    let rewards = {
        let raw = payload.get("rewards");
        match raw {
            Some(v) if v.is_string() => v.as_str().unwrap_or("[]").to_string(),
            Some(v) => v.to_string(),
            None => "[]".to_string(),
        }
    };
    let target_roles = {
        let raw = payload.get("target_roles");
        match raw {
            Some(v) if v.is_string() => v.as_str().unwrap_or("[]").to_string(),
            Some(v) => v.to_string(),
            None => "[]".to_string(),
        }
    };
    let trigger_event = payload.get("trigger_event").and_then(|v| v.as_str()).unwrap_or("registration");
    let push_trigger = payload.get("push_trigger").and_then(|v| v.as_str()).unwrap_or("manual");
    let push_cron = payload.get("push_cron").and_then(|v| v.as_str());
    let poster_prompt = payload.get("poster_prompt").and_then(|v| v.as_str());
    let attribution_window = payload.get("attribution_window").and_then(|v| v.as_i64()).unwrap_or(30);
    let valid_from = payload.get("valid_from").and_then(|v| v.as_str());
    let valid_until = payload.get("valid_until").and_then(|v| v.as_str());
    let participant_limit = payload.get("participant_limit").and_then(|v| v.as_i64());
    let per_user_limit = payload.get("per_user_limit").and_then(|v| v.as_i64());
    let qr_code_url = payload.get("qr_code_url").and_then(|v| v.as_str());

    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "INSERT INTO marketing_campaigns (id, name, campaign_type, description, status, rewards, trigger_event, target_roles, push_trigger, push_cron, poster_prompt, attribution_window, valid_from, valid_until, participant_limit, per_user_limit, qr_code_url, created_by, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
        rusqlite::params![
            id, name, campaign_type, description, status, rewards, trigger_event,
            target_roles, push_trigger, push_cron, poster_prompt, attribution_window,
            valid_from, valid_until, participant_limit, per_user_limit, qr_code_url,
            admin_id, now,
        ],
    ) {
        Ok(_) => ok(json!({"id": id, "name": name, "status": status, "created_at": now})),
        Err(e) => {
            tracing::error!("campaign_create insert failed: {} — payload: {}", e, payload);
            err(StatusCode::INTERNAL_SERVER_ERROR, &format!("insert_error: {}", e))
        },
    }
}

/// GET /api/admin/campaigns/{id} — 活动详情
pub async fn get(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    tracing::info!("campaign_get: id={}", id);

    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    match conn.query_row(
        "SELECT * FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![id],
        map_campaign_row,
    ) {
        Ok(campaign) => ok(json!(campaign)),
        Err(_) => err(StatusCode::NOT_FOUND, "campaign_not_found"),
    }
}

/// PUT /api/admin/campaigns/{id} — 更新活动
pub async fn update(
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    tracing::info!("campaign_update: id={}", id);

    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    // 构建动态 UPDATE
    let mut fields: Vec<String> = Vec::new();
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    let updatable = [
        "name", "campaign_type", "description", "status", "rewards",
        "trigger_event", "target_roles", "push_trigger", "push_cron",
        "poster_prompt", "h5_prompt", "attribution_window", "valid_from", "valid_until",
        "participant_limit", "per_user_limit", "qr_code_url", "display_positions",
    ];

    for field in &updatable {
        if let Some(val) = payload.get(*field) {
            fields.push(format!("{} = ?{}", field, params.len() + 1));
            params.push(match val {
                serde_json::Value::String(s) => Box::new(s.clone()) as Box<dyn rusqlite::types::ToSql>,
                serde_json::Value::Number(n) => {
                    if let Some(i) = n.as_i64() {
                        Box::new(i)
                    } else if let Some(f) = n.as_f64() {
                        Box::new(f)
                    } else {
                        continue;
                    }
                }
                serde_json::Value::Null => Box::new(Option::<String>::None),
                other => Box::new(other.to_string()),
            });
        }
    }

    if fields.is_empty() {
        return err(StatusCode::BAD_REQUEST, "no_fields_to_update");
    }

    fields.push(format!("updated_at = ?{}", params.len() + 1));
    params.push(Box::new(now.clone()));

    fields.push(format!("updated_by = ?{}", params.len() + 1));
    params.push(Box::new(admin_id));

    let sql = format!(
        "UPDATE marketing_campaigns SET {} WHERE id = ?{}",
        fields.join(", "),
        params.len() + 1,
    );
    params.push(Box::new(id.clone()));

    let conn = crate::db_pool::get_conn();
    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    match conn.execute(&sql, param_refs.as_slice()) {
        Ok(rows) if rows > 0 => ok(json!({"status": "updated", "id": id})),
        Ok(_) => err(StatusCode::NOT_FOUND, "campaign_not_found"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("update_error: {}", e)),
    }
}

/// DELETE /api/admin/campaigns/{id} — 删除活动（仅 draft 状态可删除）
pub async fn delete(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    tracing::info!("campaign_delete: id={}", id);

    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    // 先检查状态，非 active 才可删
    let status: Option<String> = conn.query_row(
        "SELECT status FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![id],
        |row| row.get(0),
    ).ok();
    match status.as_deref() {
        Some("active") => return err(StatusCode::BAD_REQUEST, "active_campaign_cannot_be_deleted"),
        None => return err(StatusCode::NOT_FOUND, "campaign_not_found"),
        _ => {} // draft / paused / ended 均可删
    }

    // 删除关联子表数据（FK 约束要求先删子表）
    if let Err(e) = conn.execute("DELETE FROM reward_fulfillments WHERE campaign_id = ?1", rusqlite::params![id]) {
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("delete_child_failed: {}", e));
    }
    if let Err(e) = conn.execute("DELETE FROM referral_clicks WHERE campaign_id = ?1", rusqlite::params![id]) {
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("delete_child_failed: {}", e));
    }
    if let Err(e) = conn.execute("DELETE FROM distribution_commissions WHERE campaign_id = ?1", rusqlite::params![id]) {
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("delete_child_failed: {}", e));
    }
    if let Err(e) = conn.execute("DELETE FROM campaign_members WHERE campaign_id = ?1", rusqlite::params![id]) {
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("delete_child_failed: {}", e));
    }

    match conn.execute(
        "DELETE FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![id],
    ) {
        Ok(rows) if rows > 0 => ok(json!({"status": "deleted"})),
        Ok(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "delete_failed"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("delete_error: {}", e)),
    }
}

/// PATCH /api/admin/campaigns/{id}/status — 启停活动
pub async fn toggle_status(
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<StatusUpdate>,
) -> impl IntoResponse {
    tracing::info!("campaign_toggle_status: id={}, status={}", id, body.status);

    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    // 校验合法状态
    match body.status.as_str() {
        "active" | "paused" | "ended" => {}
        _ => return err(StatusCode::BAD_REQUEST, "invalid_status_must_be_active_paused_or_ended"),
    }

    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let conn = crate::db_pool::get_conn();

    match conn.execute(
        "UPDATE marketing_campaigns SET status = ?1, updated_at = ?2, updated_by = ?3 WHERE id = ?4",
        rusqlite::params![body.status, now, admin_id, id],
    ) {
        Ok(rows) if rows > 0 => ok(json!({"status": body.status, "id": id})),
        Ok(_) => err(StatusCode::NOT_FOUND, "campaign_not_found"),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("update_error: {}", e)),
    }
}

/// POST /api/admin/campaigns/{id}/push — 手动推送
///
/// 按 target_roles 匹配目标用户，为每个用户创建营销通知。
/// 上限 100 条以防止过量推送。
pub async fn push(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    tracing::info!("campaign_push: id={}", id);

    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    // 1. 查活动信息（名称、target_roles、description）
    let campaign = match conn.query_row(
        "SELECT id, name, target_roles, description FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        },
    ) {
        Ok(c) => c,
        Err(_) => return err(StatusCode::NOT_FOUND, "campaign_not_found"),
    };

    let (campaign_id, campaign_name, target_roles_json, description) = campaign;

    // 2. 按 target_roles 匹配用户
    // 先检查 role 列是否存在，不存在则回退到全量用户
    let has_role_col: bool = conn
        .prepare("SELECT role FROM users WHERE 1=0")
        .is_ok();

    // 构建目标用户 SQL 和参数
    let (sql, params): (String, Vec<String>) = if has_role_col {
        match target_roles_json {
            Some(ref roles_json) if roles_json != "[]" && roles_json != "null" => {
                if let Ok(roles) = serde_json::from_str::<Vec<String>>(roles_json) {
                    if !roles.is_empty() {
                        let placeholders: Vec<String> = (0..roles.len())
                            .map(|i| format!("?{}", i + 1))
                            .collect();
                        (
                            format!(
                                "SELECT id FROM users WHERE role IN ({}) AND deleted_at IS NULL LIMIT 100",
                                placeholders.join(", ")
                            ),
                            roles,
                        )
                    } else {
                        ("SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100".to_string(), vec![])
                    }
                } else {
                    ("SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100".to_string(), vec![])
                }
            }
            _ => ("SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100".to_string(), vec![]),
        }
    } else {
        ("SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100".to_string(), vec![])
    };

    // 3. 查询目标用户
    let user_ids = if params.is_empty() {
        // 无角色参数，直接查询全部用户
        match query_user_ids(&conn, &sql, &[]) {
            Ok(ids) => ids,
            Err(e) => return e,
        }
    } else {
        // 带角色参数，尝试角色匹配查询
        match conn.prepare(&sql) {
            Ok(mut stmt) => {
                let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter()
                    .map(|r| r as &dyn rusqlite::types::ToSql)
                    .collect();
                match stmt.query_map(param_refs.as_slice(), |row| row.get::<_, String>(0)) {
                    Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                    Err(_) => {
                        // role 查询失败，查全部用户
                        match query_user_ids(&conn, "SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100", &[]) {
                            Ok(ids) => ids,
                            Err(e) => return e,
                        }
                    }
                }
            }
            Err(_) => {
                // role 列不存在，查全部用户
                match query_user_ids(&conn, "SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100", &[]) {
                    Ok(ids) => ids,
                    Err(e) => return e,
                }
            }
        }
    };

    // 4. 为每个匹配用户创建通知
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let title = format!("新活动: {}", campaign_name);
    let body = description
        .as_deref()
        .filter(|d| !d.is_empty())
        .unwrap_or(&format!("「{}」活动已上线，快来参与吧!", campaign_name))
        .to_string();
    let action_url = format!("share?campaign_id={}", campaign_id);

    let mut pushed_count = 0i64;
    for user_id in &user_ids {
        if pushed_count >= 100 {
            break;
        }
        let notif_id = uuid::Uuid::new_v4().to_string();
        if conn.execute(
            "INSERT INTO user_notifications (id, user_id, notification_type, title, body, read, action_url, created_at) VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7)",
            rusqlite::params![notif_id, user_id, "marketing_campaign", title, body, action_url, now],
        ).is_ok() {
            pushed_count += 1;
        }
    }

    ok(json!({"pushed": pushed_count, "campaign_id": campaign_id}))
}

/// POST /api/admin/campaigns/{id}/generate-poster-template — 生成海报模板
pub async fn generate_poster_template(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    // 查活动名称和奖励
    let (campaign_name, rewards): (String, String) = match conn.query_row(
        "SELECT name, COALESCE(rewards, '[]') FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![&id], |row| Ok((row.get(0)?, row.get(1)?)),
    ) {
        Ok(r) => r,
        Err(_) => return err(StatusCode::NOT_FOUND, "campaign_not_found"),
    };
    // conn dropped here — no non-Send type held across await

    let base_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());

    match crate::poster_template::generate_template_via_llm(&base_dir, &campaign_name, &rewards).await {
        Ok(svg) => {
            let _ = conn.execute(
                "UPDATE marketing_campaigns SET poster_template = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![svg, chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(), &id],
            );
            ok(json!({"status": "ok"}))
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("template_generation_failed: {}", e)),
    }
}

/// POST /api/admin/campaigns/{id}/generate-h5-template — 生成 H5 模板
pub async fn generate_h5_template(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    // 查活动名称和 rewards（同步查询，不跨 await）
    let campaign_name: String = match conn.query_row(
        "SELECT name FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![&id], |row| row.get(0),
    ) {
        Ok(n) => n,
        Err(_) => return err(StatusCode::NOT_FOUND, "campaign_not_found"),
    };
    let rewards: String = conn.query_row(
        "SELECT COALESCE(rewards, '[]') FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![&id], |row| row.get(0),
    ).unwrap_or_else(|_| "[]".to_string());

    let base_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());

    match crate::h5_template::generate_h5_template_via_llm(&base_dir, &campaign_name, &rewards).await {
        Ok(html) => {
            let _ = conn.execute(
                "UPDATE marketing_campaigns SET h5_template = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![html, chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(), &id],
            );
            ok(json!({"status": "ok"}))
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("h5_template_generation_failed: {}", e)),
    }
}

/// 查询目标用户 ID 列表，返回 Vec<String> 或转换为 Response 错误
fn query_user_ids(
    conn: &rusqlite::Connection,
    sql: &str,
    params: &[&dyn rusqlite::types::ToSql],
) -> Result<Vec<String>, axum::response::Response> {
    let mut stmt = conn.prepare(sql)
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &format!("db_error: {}", e)))?;
    let ids: Vec<String> = stmt.query_map(params, |row| row.get::<_, String>(0))
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &format!("query_error: {}", e)))?
        .filter_map(|r| r.ok())
        .collect();
    Ok(ids)
}

/// GET /api/admin/campaigns/{id}/stats — 活动统计
pub async fn stats(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    tracing::info!("campaign_stats: id={}", id);

    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();

    let clicks: i64 = conn.query_row(
        "SELECT COUNT(*) FROM referral_clicks WHERE campaign_id = ?1",
        rusqlite::params![id], |row| row.get(0),
    ).unwrap_or(0);

    // 活动带来的注册数：通过 referral_clicks 找到点击者中后来注册的用户
    let registrations: i64 = conn.query_row(
        r#"SELECT COUNT(DISTINCT u.id) FROM users u
           JOIN referral_clicks rc ON u.referred_by = rc.referrer_id
           WHERE rc.campaign_id = ?1 AND u.deleted_at IS NULL"#,
        rusqlite::params![id], |row| row.get(0),
    ).unwrap_or(0);

    let commission_total: i64 = conn.query_row(
        "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE campaign_id = ?1 AND status NOT IN ('cancelled')",
        rusqlite::params![id], |row| row.get(0),
    ).unwrap_or(0);

    let member_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM campaign_members WHERE campaign_id = ?1",
        rusqlite::params![id], |row| row.get(0),
    ).unwrap_or(0);

    let paid_count: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT buyer_id) FROM distribution_commissions WHERE campaign_id = ?1 AND status NOT IN ('cancelled')",
        rusqlite::params![id], |row| row.get(0),
    ).unwrap_or(0);

    ok(json!({
        "clicks": clicks,
        "registrations": registrations,
        "commission_total": commission_total,
        "member_count": member_count,
        "paid_count": paid_count,
    }))
}

/// GET /api/campaigns/check-push-trigger — 检查是否有匹配的推送活动（仅返回弹窗可用活动）
pub async fn check_push_trigger(
    Query(query): Query<CheckPushTriggerQuery>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    let result: Option<(String, String)> = conn.query_row(
        "SELECT id, name FROM marketing_campaigns \
         WHERE status='active' AND push_trigger=?1 \
         AND (display_positions IS NULL OR display_positions NOT IN ('notification')) \
         AND (valid_from IS NULL OR valid_from <= datetime('now')) \
         AND (valid_until IS NULL OR valid_until > datetime('now')) \
         LIMIT 1",
        rusqlite::params![query.push_trigger],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).ok();

    match result {
        Some((id, name)) => ok(json!({
            "has_active": true,
            "campaign_id": id,
            "campaign_name": name,
        })),
        None => ok(json!({
            "has_active": false,
            "campaign_id": null,
            "campaign_name": null,
        })),
    }
}

/// GET /api/admin/campaigns/default-poster-prompt — 获取默认海报系统提示模板
pub async fn default_poster_prompt() -> impl IntoResponse {
    let base_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    match crate::referral_handler::load_combined_prompt(&base_dir, "poster") {
        Ok(prompt) => ok(json!({"prompt": prompt})),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": e}))).into_response(),
    }
}

/// POST /api/admin/campaigns/{id}/preview-poster — 生成预览海报（admin 专用）
pub async fn preview_poster(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    let demo_user_id: Option<String> = conn.query_row(
        "SELECT id FROM users WHERE subscription_expires IS NOT NULL ORDER BY created_at DESC LIMIT 1",
        [], |row| row.get(0),
    ).ok();

    let uid = match demo_user_id {
        Some(u) => u,
        None => return (StatusCode::NOT_FOUND, Json(json!({"error": "no_demo_user"}))).into_response(),
    };

    // 查询模板并生成海报（内联实现，避免跨函数类型推断问题）
    let template: Option<String> = conn.query_row(
        "SELECT poster_template FROM marketing_campaigns WHERE id = ?1",
        rusqlite::params![&id],
        |row| row.get(0),
    ).ok().flatten();

    let (svg, copy) = if let Some(ref tpl) = template {
        let data = match crate::poster_template::build_user_poster_data(&conn, &uid, &id) {
            Ok(d) => d,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response(),
        };
        (crate::poster_template::replace_template_variables(tpl, &data), crate::poster_template::fallback_copy())
    } else {
        let data = match crate::poster_template::build_user_poster_data(&conn, &uid, "") {
            Ok(d) => d,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response(),
        };
        (crate::poster_template::replace_template_variables(&crate::poster_template::fallback_poster_svg(&data), &data), crate::poster_template::fallback_copy())
    };

    crate::referral_handler::poster_json_response_inline(&svg, &copy)
}

/// POST /api/admin/campaigns/{id}/preview-h5 — 生成预览 H5（admin 专用，变量已替换）
pub async fn preview_h5(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    let demo_user_id: Option<String> = conn.query_row(
        "SELECT id FROM users WHERE subscription_expires IS NOT NULL ORDER BY created_at DESC LIMIT 1",
        [], |row| row.get(0),
    ).ok();

    match demo_user_id {
        Some(uid) => {
            let template: Option<String> = conn.query_row(
                "SELECT h5_template FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![&id],
                |row| row.get(0),
            ).ok().flatten();

            let html = match template {
                Some(tpl) => {
                    let data = match crate::poster_template::build_user_poster_data(&conn, &uid, &id) {
                        Ok(d) => d,
                        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response(),
                    };
                    crate::poster_template::replace_template_variables(&tpl, &data)
                }
                None => {
                    "<!DOCTYPE html><html><body style='display:flex;justify-content:center;align-items:center;min-height:100vh;font-family:sans-serif;'><h2>暂无 H5 模板</h2></body></html>".to_string()
                }
            };
            (StatusCode::OK, Json(json!({"html": html, "url": format!("/share/{}/", uid)}))).into_response()
        }
        None => (StatusCode::NOT_FOUND, Json(json!({"error": "no_demo_user"}))).into_response(),
    }
}

// ── 辅助函数 ──

/// 将 marketing_campaigns 行映射为 JSON
fn map_campaign_row(row: &rusqlite::Row) -> rusqlite::Result<serde_json::Value> {
    Ok(json!({
        "id": row.get::<_, String>(0)?,
        "name": row.get::<_, String>(1)?,
        "campaign_type": row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        "description": row.get::<_, Option<String>>(3)?,
        "status": row.get::<_, Option<String>>(4)?.unwrap_or_else(|| "draft".into()),
        "rewards": row.get::<_, String>(5)?,
        "trigger_event": row.get::<_, String>(6)?,
        "target_roles": row.get::<_, Option<String>>(7)?.unwrap_or_else(|| "[]".into()),
        "push_trigger": row.get::<_, Option<String>>(8)?.unwrap_or_else(|| "manual".into()),
        "push_cron": row.get::<_, Option<String>>(9)?,
        "attribution_window": row.get::<_, Option<i64>>(10)?.unwrap_or(30),
        "valid_from": row.get::<_, Option<String>>(11)?,
        "valid_until": row.get::<_, Option<String>>(12)?,
        "participant_limit": row.get::<_, Option<i64>>(13)?,
        "per_user_limit": row.get::<_, Option<i64>>(14)?,
        "qr_code_url": row.get::<_, Option<String>>(15)?,
        "created_by": row.get::<_, Option<String>>(16)?,
        "created_at": row.get::<_, String>(17)?,
        "updated_by": row.get::<_, Option<String>>(18)?,
        "updated_at": row.get::<_, Option<String>>(19)?,
        "poster_prompt": row.get::<_, Option<String>>(20)?,
        "poster_template": row.get::<_, Option<String>>(21)?,
        "h5_template": row.get::<_, Option<String>>(22)?,
        "h5_prompt": row.get::<_, Option<String>>(23)?,
        "display_positions": row.get::<_, Option<String>>(24)?.unwrap_or_else(|| "[]".into()),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::schema::init_database;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();
        // 插入测试用管理员（marketing_campaigns.created_by 外键依赖）
        conn.execute(
            "INSERT INTO admin_users (id, username, password_hash, role, status, created_at) \
             VALUES ('admin-1', 'admin', 'hash', 'super_admin', 'approved', datetime('now'))",
            [],
        )
        .unwrap();
        conn
    }

    /// 创建活动后查询，验证字段正确
    #[test]
    fn test_create_campaign() {
        let conn = setup_db();
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

        conn.execute(
            "INSERT INTO marketing_campaigns \
             (id, name, campaign_type, description, status, rewards, trigger_event, \
              target_roles, push_trigger, attribution_window, created_by, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            rusqlite::params![
                id, "双11大促", "standard", "双11限时折扣活动", "draft",
                r#"[{"type":"discount_pct","party":"buyer","value":0.80}]"#,
                "registration", r#"["student"]"#, "manual", 30, "admin-1", now,
            ],
        )
        .unwrap();

        let campaign: serde_json::Value = conn
            .query_row(
                "SELECT * FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![id],
                map_campaign_row,
            )
            .unwrap();

        assert_eq!(campaign["name"], "双11大促");
        assert_eq!(campaign["status"], "draft");
        assert_eq!(campaign["campaign_type"], "standard");
        assert_eq!(campaign["description"], "双11限时折扣活动");
        assert_eq!(campaign["attribution_window"], 30);
        assert_eq!(campaign["trigger_event"], "registration");
        assert_eq!(campaign["push_trigger"], "manual");
    }

    /// 删除活动测试：仅 draft 可删，active 不可删
    #[test]
    fn test_delete_campaign_only_draft() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let draft_id = uuid::Uuid::new_v4().to_string();
        let active_id = uuid::Uuid::new_v4().to_string();

        // 创建 draft 活动
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES (?1, ?2, 'draft', '[]', 'registration', 'admin-1', ?3)",
            rusqlite::params![draft_id, "草稿活动", now],
        )
        .unwrap();

        // 创建 active 活动
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES (?1, ?2, 'active', '[]', 'registration', 'admin-1', ?3)",
            rusqlite::params![active_id, "活跃活动", now],
        )
        .unwrap();

        // draft 可删除
        let deleted = conn
            .execute(
                "DELETE FROM marketing_campaigns WHERE id = ?1 AND status = 'draft'",
                rusqlite::params![draft_id],
            )
            .unwrap();
        assert_eq!(deleted, 1, "draft 状态活动应可删除");

        // 验证 draft 确实被删了
        let draft_exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![draft_id],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .unwrap_or(false);
        assert!(!draft_exists, "draft 活动应已被删除");

        // active 不可被 draft-only 删除条件删除
        let not_deleted = conn
            .execute(
                "DELETE FROM marketing_campaigns WHERE id = ?1 AND status = 'draft'",
                rusqlite::params![active_id],
            )
            .unwrap();
        assert_eq!(not_deleted, 0, "active 活动不可被 draft-only 条件删除");

        // active 活动仍然存在
        let active_status: String = conn
            .query_row(
                "SELECT status FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![active_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(active_status, "active", "active 活动应仍存在");
    }

    /// 活动启停测试：draft→active→paused 状态流转
    #[test]
    fn test_campaign_status_transitions() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let id = uuid::Uuid::new_v4().to_string();

        // 创建 draft
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES (?1, ?2, 'draft', '[]', 'registration', 'admin-1', ?3)",
            rusqlite::params![id, "测试活动", now],
        )
        .unwrap();

        // 验证初始状态为 draft
        let status: String = conn
            .query_row(
                "SELECT status FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "draft", "活动初始状态应为 draft");

        // draft → active
        conn.execute(
            "UPDATE marketing_campaigns SET status = 'active', updated_at = ?1 WHERE id = ?2",
            rusqlite::params![now, id],
        )
        .unwrap();
        let status: String = conn
            .query_row(
                "SELECT status FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "active", "draft 应可变为 active");

        // active → paused
        conn.execute(
            "UPDATE marketing_campaigns SET status = 'paused', updated_at = ?1 WHERE id = ?2",
            rusqlite::params![now, id],
        )
        .unwrap();
        let status: String = conn
            .query_row(
                "SELECT status FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "paused", "active 应可变为 paused");

        // paused → active (恢复)
        conn.execute(
            "UPDATE marketing_campaigns SET status = 'active', updated_at = ?1 WHERE id = ?2",
            rusqlite::params![now, id],
        )
        .unwrap();
        let status: String = conn
            .query_row(
                "SELECT status FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "active", "paused 应可恢复为 active");
    }

    /// 活动统计测试：创建活动后验证统计返回 0
    #[test]
    fn test_campaign_stats_zero() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let id = uuid::Uuid::new_v4().to_string();

        // 创建活动
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES (?1, ?2, 'active', '[]', 'registration', 'admin-1', ?3)",
            rusqlite::params![id, "统计测试", now],
        )
        .unwrap();

        // 验证统计全部为 0
        let clicks: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM referral_clicks WHERE campaign_id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        assert_eq!(clicks, 0, "新建活动点击数应为 0");

        let registrations: i64 = conn
            .query_row(
                r#"SELECT COUNT(DISTINCT u.id) FROM users u
                   JOIN referral_clicks rc ON u.referred_by = rc.referrer_id
                   WHERE rc.campaign_id = ?1 AND u.deleted_at IS NULL"#,
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        assert_eq!(registrations, 0, "新建活动注册数应为 0");

        let commission_total: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions \
                 WHERE campaign_id = ?1 AND status NOT IN ('cancelled')",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        assert_eq!(commission_total, 0, "新建活动佣金总额应为 0");

        let member_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM campaign_members WHERE campaign_id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        assert_eq!(member_count, 0, "新建活动成员数应为 0");

        let paid_count: i64 = conn
            .query_row(
                "SELECT COUNT(DISTINCT buyer_id) FROM distribution_commissions \
                 WHERE campaign_id = ?1 AND status NOT IN ('cancelled')",
                rusqlite::params![id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        assert_eq!(paid_count, 0, "新建活动已支付人数应为 0");
    }
}
