//! e2e 测试工具函数
//!
//! 所有 e2e 测试共用，确保 API 响应解析方式统一。
//! 原则：不静默吞错误 → JSON 解析失败直接 panic。
//!
//! # body_json()
//!
//! 读取 HTTP 响应的完整 body，尝试 JSON 解析：
//! - 解析成功：返回 `serde_json::Value`
//! - 状态码非 200 或响应含 `error`：额外打印警告（不 panic，让测试断言捕住）
//! - 解析失败：**直接 panic**，打印完整响应体
//!
//! # init_tracing()
//!
//! 初始化 tracing 日志到 `backend/data/logs/` 文件，与 production 一致的路径。
//! 通过 CARGO_MANIFEST_DIR 定位项目根目录，确保测试和生产日志写在同一目录。
//! 幂等：仅第一次有效，后续调用静默跳过。

use serde_json::Value;
use std::sync::Mutex;
use std::sync::OnceLock;

/// 日志文件句柄（通过 init_tracing 初始化）
static LOG_FILE: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// Init once flag
static TRACING_INITED: std::sync::Once = std::sync::Once::new();

/// 解析日志目录：优先依 COEVO_LOG_DIR，否则默认到 CWD 的 data/logs
fn resolve_log_dir() -> std::path::PathBuf {
    if let Ok(dir) = std::env::var("COEVO_LOG_DIR") {
        return std::path::PathBuf::from(dir);
    }
    // CWD 兜底（运行测试时 CWD = backend/，data/logs = backend/data/logs/）
    std::path::PathBuf::from("data/logs")
}

/// 解析公共数据库路径：优先依 COEVO_DB_PATH，否则用与 production 一致的 `backend/data/coevo.db`
pub fn resolve_db_path() -> std::path::PathBuf {
    if let Ok(dir) = std::env::var("COEVO_DB_PATH") {
        return std::path::PathBuf::from(dir);
    }
    // 开发模式：从 CARGO_MANIFEST_DIR 定位到 backend/data/
    let dev_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../data/coevo.db");
    if dev_path.parent().map(|p| p.exists()).unwrap_or(false) {
        return dev_path;
    }
    // CWD 兜底
    std::path::PathBuf::from("data/coevo.db")
}

/// 初始化 tracing 日志到 `backend/data/logs/` 文件（与 production 一致的路径）。
///
/// 幂等：仅第一次有效。
pub fn init_tracing() {
    TRACING_INITED.call_once(|| {
        let log_dir = resolve_log_dir();
        let _ = std::fs::create_dir_all(&log_dir);
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let log_path = log_dir.join(format!("coevo.log.{}", today));
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .expect("open log file");
        let _ = LOG_FILE.set(Mutex::new(file));

        // 初始化 tracing subscriber
        let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

        let _ = tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_writer(|| LOG_FILE.get().unwrap().lock().unwrap().try_clone().unwrap())
            .with_ansi(false)
            .try_init();
    });
}

/// 解析 HTTP 响应为 JSON Value。
///
/// 与旧版 `unwrap_or(json!({"raw": "parse failed"}))` 不同，本函数不兜底：
/// 如果 body 不是合法 JSON，直接 panic 并打印 body 内容。
pub async fn body_json(resp: reqwest::Response) -> Value {
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();

    let val: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            let preview: String = text.chars().take(500).collect();
            panic!(
                "[body_json] HTTP {} response is not valid JSON.\nError: {}\nBody preview (500 chars):\n{}",
                status, e, preview
            );
        }
    };

    if status != 200 || val.get("error").is_some() {
        eprintln!(
            "[body_json] HTTP {} body (first 300): {}",
            status,
            &text.chars().take(300).collect::<String>()
        );
    }

    val
}

/// 解析 HTTP 响应为 JSON Value，失败时返回默认值。
///
/// 仅在测试**数据准备阶段**使用（如注册用户可能已存在时），
/// 逻辑验证阶段应始终使用 `body_json()`。
pub async fn body_json_or(resp: reqwest::Response, default: Value) -> Value {
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();

    let val: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            eprintln!(
                "[body_json_or] HTTP {} parse failed (using default): {}\nbody: {}",
                status,
                e,
                &text.chars().take(200).collect::<String>()
            );
            return default;
        }
    };

    if status != 200 || val.get("error").is_some() {
        eprintln!(
            "[body_json_or] HTTP {} body (first 200): {}",
            status,
            &text.chars().take(200).collect::<String>()
        );
    }

    val
}
