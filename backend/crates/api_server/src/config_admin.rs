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

use crate::admin_handlers::{err, ok, verify_admin};
use axum::{
    extract::Query,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::json;

fn conn() -> crate::db_pool::DbConn {
    crate::db_pool::get_conn()
}

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
    let result: Vec<serde_json::Value> = configs
        .into_iter()
        .map(|(key, value, description)| {
            json!({
                "key": key,
                "value": value,
                "description": description,
            })
        })
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
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("读取模板失败: {}", e),
        ),
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
            if !cat_entry.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            let cat_name = cat_entry.file_name().to_string_lossy().to_string();
            if cat_name == "format" {
                continue;
            } // 共享格式池不单独显示
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
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("创建目录失败: {}", e),
                );
            }
        }
    }

    // 原子写入：写 temp 文件后 rename
    let temp_path = file_path.with_extension("md.tmp");
    match std::fs::write(&temp_path, content) {
        Ok(()) => {}
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("写入临时文件失败: {}", e),
            )
        }
    }
    if let Err(e) = std::fs::rename(&temp_path, &file_path) {
        // 清理临时文件
        let _ = std::fs::remove_file(&temp_path);
        return err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("重命名文件失败: {}", e),
        );
    }

    ok(json!({
        "status": "ok",
        "path": path,
        "char_count": content.chars().count(),
    }))
}

// ════════════════════════════════════════════
// 🔴 2026-09-29 已退役：调试跟踪 + 调试日志
// ════════════════════════════════════════════
//
// 原 `debug_track_handler` / `debug_untrack_handler` / `debug_tracks_handler` /
// `debug_logs_handler` / `debug_log_detail_handler` —— 依赖已删除的表
// `debug_trackers` / `debug_logs`，且只服务 admin 调试面板。
// → 路由 `/api/admin/debug/*` 已同步移除；模块 `debug_logger` /
//   `debug_trackers_cache` 一并退役。

// ════════════════════════════════════════════
// 公共端点
// ════════════════════════════════════════════

/// GET /api/public/qrcode — 返回管理员微信二维码图片
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
