//! 配置管理 + 调试跟踪 + 调试日志查询 API
//!
//! - GET/POST /api/admin/config — 运行时配置 CRUD
//! - GET/POST /api/admin/prompt/template — 模板读取/保存（super 权限）
//! - POST /api/admin/debug/track — 开始跟踪
//! - GET /api/public/qrcode — 联系管理员二维码
//! - DELETE /api/admin/debug/track/{id} — 关闭
//! - GET /api/admin/debug/tracks — 列出跟踪
//! - GET /api/admin/debug/logs — 搜索日志
//! - GET /api/admin/debug/logs/{id} — 日志详情

use axum::{extract::{Path, Query}, http::{HeaderMap, StatusCode}, Json, response::IntoResponse};
use serde_json::json;
use crate::admin_handlers::{verify_admin, ok, err};

fn conn() -> crate::db_pool::DbConn { crate::db_pool::get_conn() }

// ════════════════════════════════════════════
// 运行时配置
// ════════════════════════════════════════════

/// GET /api/admin/config — 列出所有配置项
pub async fn get_config_handler(headers: HeaderMap) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let configs = crate::app_config_cache::list().await;
    let result: Vec<serde_json::Value> = configs.into_iter()
        .map(|(key, value, description)| json!({
            "key": key,
            "value": value,
            "description": description,
        }))
        .collect();
    ok(json!({"configs": result}))
}

/// POST /api/admin/config — 批量更新配置
pub async fn post_config_handler(
    headers: HeaderMap,
    Json(body): Json<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let updates: Vec<(String, String)> = body.into_iter().collect();
    match crate::app_config_cache::batch_update(updates).await {
        Ok(()) => ok(json!({"status": "ok"})),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

// ════════════════════════════════════════════
// Prompt 模板
// ════════════════════════════════════════════

/// GET /api/admin/prompt/template — 读取模板文件内容
pub async fn get_template_handler(
    headers: HeaderMap,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let path = match params.get("path") {
        Some(p) => p.trim().trim_start_matches('/'),
        None => return err(StatusCode::BAD_REQUEST, "缺少 path 参数"),
    };

    // 安全校验：不允许 ../ 越权
    if path.contains("..") {
        return err(StatusCode::BAD_REQUEST, "路径不能包含 ..");
    }

    let prompts_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    let file_path = std::path::Path::new(&prompts_dir).join(path);

    if !file_path.exists() {
        return err(StatusCode::NOT_FOUND, "模板文件不存在");
    }

    match std::fs::read_to_string(&file_path) {
        Ok(content) => ok(json!({
            "path": path,
            "content": content,
            "char_count": content.chars().count(),
        })),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("读取模板失败: {}", e)),
    }
}

/// GET /api/admin/prompt/templates — 列出所有可编辑的 prompt 模板文件
pub async fn list_templates_handler(headers: HeaderMap) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let prompts_dir = "prompts";
    let mut files: Vec<String> = Vec::new();
    if let Ok(base) = std::fs::read_dir(prompts_dir) {
        for cat_entry in base.flatten() {
            if !cat_entry.file_type().map_or(false, |t| t.is_dir()) { continue; }
            let cat_name = cat_entry.file_name().to_string_lossy().to_string();
            if cat_name == "format" { continue; } // 共享格式池不单独显示
            scan_md_files(cat_entry.path(), &format!("{}/", cat_name), &mut files);
        }
    }
    files.sort();
    ok(json!({"files": files, "count": files.len()}))
}

/// 递归扫描目录下的 .md 文件
fn scan_md_files(dir: std::path::PathBuf, prefix: &str, files: &mut Vec<String>) {
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let fname = entry.file_name().to_string_lossy().to_string();
            if fname == "format" || fname == "signal" {
                continue;
            }
            let ftype = match entry.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            if ftype.is_dir() {
                scan_md_files(entry.path(), &format!("{}{}/", prefix, fname), files);
            } else if fname.ends_with(".md") {
                files.push(format!("{}{}", prefix, fname));
            }
        }
    }
}

/// POST /api/admin/prompt/template — 保存模板文件内容（super 权限）
pub async fn post_template_handler(
    headers: HeaderMap,
    Json(body): Json<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let (_admin_id, role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    // 仅 super 可编辑模板
    if role != "super" {
        return err(StatusCode::FORBIDDEN, "仅 super 管理员可编辑模板");
    }

    let path = match body.get("path") {
        Some(p) => p.trim().trim_start_matches('/'),
        None => return err(StatusCode::BAD_REQUEST, "缺少 path 参数"),
    };
    let content = match body.get("content") {
        Some(c) => c,
        None => return err(StatusCode::BAD_REQUEST, "缺少 content 参数"),
    };

    // 安全校验：不允许 ../ 越权
    if path.contains("..") {
        return err(StatusCode::BAD_REQUEST, "路径不能包含 ..");
    }

    let prompts_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    let file_path = std::path::Path::new(&prompts_dir).join(path);

    if let Some(parent) = file_path.parent() {
        if !parent.exists() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("创建目录失败: {}", e));
            }
        }
    }

    // 原子写入：写 temp 文件后 rename
    let temp_path = file_path.with_extension("md.tmp");
    match std::fs::write(&temp_path, content) {
        Ok(()) => {}
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("写入临时文件失败: {}", e)),
    }
    if let Err(e) = std::fs::rename(&temp_path, &file_path) {
        // 清理临时文件
        let _ = std::fs::remove_file(&temp_path);
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("重命名文件失败: {}", e));
    }

    ok(json!({
        "status": "ok",
        "path": path,
        "char_count": content.chars().count(),
    }))
}

// ════════════════════════════════════════════
// 调试跟踪
// ════════════════════════════════════════════

/// POST /api/admin/debug/track — 开始跟踪某用户
pub async fn debug_track_handler(
    headers: HeaderMap,
    Json(body): Json<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let user_id = match body.get("user_id") {
        Some(u) => u,
        None => return err(StatusCode::BAD_REQUEST, "缺少 user_id"),
    };
    let conversation_id = body.get("conversation_id").map(|s| s.as_str()).unwrap_or("");
    let subject = body.get("subject").map(|s| s.as_str()).unwrap_or("");

    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();

    match conn().execute(
        "INSERT INTO debug_trackers (id, user_id, conversation_id, subject, status, created_at) VALUES (?1, ?2, ?3, ?4, 'active', ?5)",
        rusqlite::params![id, user_id,
            if conversation_id.is_empty() { None::<String> } else { Some(conversation_id.to_string()) },
            if subject.is_empty() { None::<String> } else { Some(subject.to_string()) },
            now],
    ) {
        Ok(_) => {
            // 更新内存缓存
            crate::debug_trackers_cache::add_tracker(
                crate::debug_trackers_cache::TrackerEntry {
                    id: id.clone(),
                    user_id: user_id.to_string(),
                    conversation_id: if conversation_id.is_empty() { None } else { Some(conversation_id.to_string()) },
                    subject: if subject.is_empty() { None } else { Some(subject.to_string()) },
                    created_at: now,
                }
            );
            ok(json!({"id": id, "status": "active"}))
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("创建跟踪失败: {}", e)),
    }
}

/// DELETE /api/admin/debug/track/{id} — 关闭跟踪
pub async fn debug_untrack_handler(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    match conn().execute(
        "UPDATE debug_trackers SET status = 'stopped' WHERE id = ?1",
        rusqlite::params![id],
    ) {
        Ok(_) => {
            crate::debug_trackers_cache::remove_tracker(&id);
            ok(json!({"status": "stopped"}))
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("关闭跟踪失败: {}", e)),
    }
}

/// GET /api/admin/debug/tracks — 列出当前活跃的跟踪
pub async fn debug_tracks_handler(headers: HeaderMap) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let tracks = crate::debug_trackers_cache::list_active();
    let result: Vec<serde_json::Value> = tracks.into_iter()
        .map(|t| json!({
            "id": t.id,
            "user_id": t.user_id,
            "conversation_id": t.conversation_id,
            "subject": t.subject,
            "created_at": t.created_at,
        }))
        .collect();
    ok(json!({"tracks": result, "count": result.len()}))
}

// ════════════════════════════════════════════
// 调试日志查询
// ════════════════════════════════════════════

/// GET /api/admin/debug/logs — 搜索日志
pub async fn debug_logs_handler(
    headers: HeaderMap,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let search_user_id = params.get("user_id");
    let search_conv_id = params.get("conversation_id");
    let search_date = params.get("date");
    let limit: i64 = params.get("limit").and_then(|v| v.parse().ok()).unwrap_or(50);

    let mut sql = String::from(
        "SELECT id, conversation_id, user_id, subject, date, entry_count, file_size_bytes, created_at FROM debug_logs WHERE 1=1"
    );
    let mut bind_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(uid) = search_user_id {
        sql.push_str(" AND user_id = ?");
        bind_values.push(Box::new(uid.clone()));
    }
    if let Some(cid) = search_conv_id {
        sql.push_str(" AND conversation_id = ?");
        bind_values.push(Box::new(cid.clone()));
    }
    if let Some(d) = search_date {
        sql.push_str(" AND date = ?");
        bind_values.push(Box::new(d.clone()));
    }
    sql.push_str(" ORDER BY created_at DESC LIMIT ?");
    bind_values.push(Box::new(limit));

    let params_refs: Vec<&dyn rusqlite::types::ToSql> = bind_values.iter().map(|b| b.as_ref()).collect();

    let c = conn();
    let mut stmt = match c.prepare(&sql) {
        Ok(s) => s,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("查询日志失败: {}", e)),
    };

    let rows = match stmt.query_map(params_refs.as_slice(), |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i32>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, i64>(7)?,
        ))
    }) {
        Ok(r) => r,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("遍历日志失败: {}", e)),
    };

    let logs: Vec<serde_json::Value> = rows.filter_map(|r| {
        r.ok().map(|(id, conv_id, uid, subj, date, ec, fsz, ca)| {
            json!({
                "id": id,
                "conversation_id": conv_id,
                "user_id": uid,
                "subject": subj,
                "date": date,
                "entry_count": ec,
                "file_size_bytes": fsz,
                "created_at": ca,
            })
        })
    }).collect();

    ok(json!({"logs": logs}))
}

/// GET /api/admin/debug/logs/{id} — 日志详情
pub async fn debug_log_detail_handler(
    headers: HeaderMap,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let (_admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    // 先查元数据
    let meta = match conn().query_row(
        "SELECT id, conversation_id, user_id, subject, date, log_file_path, entry_count, file_size_bytes, created_at FROM debug_logs WHERE id = ?1",
        rusqlite::params![id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, i32>(6)?,
                row.get::<_, i64>(7)?,
                row.get::<_, i64>(8)?,
            ))
        },
    ) {
        Ok(m) => m,
        Err(rusqlite::Error::QueryReturnedNoRows) => return err(StatusCode::NOT_FOUND, "日志记录不存在"),
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("查询日志失败: {}", e)),
    };

    // 读取日志文件内容
    let (_id, conv_id, uid, subj, date, log_file_path, ec, fsz, ca) = meta;
    let entries: Vec<serde_json::Value> = match std::fs::read_to_string(&log_file_path) {
        Ok(content) => {
            content.lines()
                .filter(|l| !l.trim().is_empty())
                .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .collect()
        }
        Err(e) => {
            // 文件可能已被清理，返回空列表
            tracing::warn!("读取日志文件失败: {} — {}", log_file_path, e);
            vec![]
        }
    };

    ok(json!({
        "id": _id,
        "conversation_id": conv_id,
        "user_id": uid,
        "subject": subj,
        "date": date,
        "entry_count": ec,
        "file_size_bytes": fsz,
        "created_at": ca,
        "entries": entries,
    }))
}

// ════════════════════════════════════════════
// 公共端点
// ════════════════════════════════════════════

/// GET /api/public/qrcode — 返回管理员微信二维码图片
pub async fn qrcode_handler() -> impl IntoResponse {
    let img_path = "data/super_weixin.jpg";
    match tokio::fs::read(img_path).await {
        Ok(data) => {
            axum::response::Response::builder()
                .header(axum::http::header::CONTENT_TYPE, "image/jpeg")
                .body(axum::body::Body::from(data))
                .unwrap()
        }
        Err(_) => {
            axum::response::Response::builder()
                .header(axum::http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(axum::body::Body::from("二维码图片未配置，请联系管理员。"))
                .unwrap()
        }
    }
}
