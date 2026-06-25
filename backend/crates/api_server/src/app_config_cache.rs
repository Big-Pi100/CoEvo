//! 运行时配置缓存
//!
//! app_config 表 — 双缓存策略:
//!   读: 查内存 Arc<RwLock<HashMap>>（微秒级）
//!   写: 同时更新 DB 和内存缓存
//!   生效: 即时生效，无需重启

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

/// 全局运行时配置缓存
static APP_CONFIG: OnceLock<Arc<RwLock<HashMap<String, ConfigEntry>>>> = OnceLock::new();

/// 配置项
#[derive(Debug, Clone)]
pub struct ConfigEntry {
    pub value: String,
    pub description: String,
}

/// 初始化配置缓存（起服时调用）
pub fn init_cache(conn: &rusqlite::Connection) -> Result<(), String> {
    let cache = Arc::new(RwLock::new(HashMap::new()));
    APP_CONFIG.set(cache.clone())
        .map_err(|_| "APP_CONFIG 已初始化".to_string())?;

    // 如果有默认配置，确保它们存在
    ensure_defaults(conn)?;

    // 全量加载
    reload(conn)
}

/// 确保默认配置存在
fn ensure_defaults(conn: &rusqlite::Connection) -> Result<(), String> {
    let defaults: &[(&str, &str, &str)] = &[
        ("prompt.history_max_chars", "20000", "对话历史截断字数"),
        ("prompt.history_max_turns", "10", "对话历史保留轮次"),
        ("prompt.concept_extract_max", "5", "概念提取最多数量"),
        ("debug_log.enabled", "true", "是否启用调试日志"),
        ("debug_log.retention_days", "7", "调试日志保留天数"),
    ];
    for (key, value, desc) in defaults {
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, description, updated_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![key, value, desc, chrono::Utc::now().timestamp()],
        ).map_err(|e| format!("插入默认配置 {} 失败: {}", key, e))?;
    }
    Ok(())
}

/// 从 DB 全量加载到缓存
pub fn reload(conn: &rusqlite::Connection) -> Result<(), String> {
    let cache = APP_CONFIG.get()
        .ok_or("APP_CONFIG 未初始化")?;

    let mut stmt = conn.prepare("SELECT key, value, description FROM app_config")
        .map_err(|e| format!("查询 app_config 失败: {}", e))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    }).map_err(|e| format!("遍历 app_config 失败: {}", e))?;

    let mut map = cache.write().unwrap();
    map.clear();
    for row in rows {
        let (key, value, description) = row.map_err(|e| format!("读取 app_config 行失败: {}", e))?;
        map.insert(key, ConfigEntry { value, description });
    }
    Ok(())
}

/// 获取配置值
pub async fn get(key: &str) -> Option<String> {
    let cache = APP_CONFIG.get()?;
    let map = cache.read().unwrap();
    map.get(key).map(|e| e.value.clone())
}

/// 获取配置值（同步版，用于非 async 上下文）
pub fn get_sync(conn: &rusqlite::Connection, key: &str) -> Result<Option<String>, String> {
    conn.query_row(
        "SELECT value FROM app_config WHERE key = ?1",
        rusqlite::params![key],
        |row| row.get::<_, String>(0),
    ).map(Some).or_else(|e| {
        if e == rusqlite::Error::QueryReturnedNoRows {
            Ok(None)
        } else {
            Err(format!("查询 app_config key={} 失败: {}", key, e))
        }
    })
}

/// 设置配置值（同时更新 DB 和缓存）
pub async fn set(key: &str, value: &str) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();
    {
        let conn = crate::db_pool::get_conn();
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, description, updated_at) VALUES (?1, ?2, COALESCE((SELECT description FROM app_config WHERE key = ?1), ''), ?3)",
            rusqlite::params![key, value, now],
        ).map_err(|e| format!("写入 app_config 失败: {}", e))?;
    }

    if let Some(cache) = APP_CONFIG.get() {
        let mut map = cache.write().unwrap();
        map.entry(key.to_string()).or_insert_with(|| ConfigEntry {
            value: String::new(),
            description: String::new(),
        }).value = value.to_string();
    }
    Ok(())
}

/// 列出所有配置
pub async fn list() -> Vec<(String, String, String)> {
    let cache = match APP_CONFIG.get() {
        Some(c) => c,
        None => return vec![],
    };
    let map = cache.read().unwrap();
    let mut result: Vec<_> = map.iter()
        .map(|(k, v)| (k.clone(), v.value.clone(), v.description.clone()))
        .collect();
    result.sort_by(|a, b| a.0.cmp(&b.0));
    result
}

/// 设置带描述的配置值
pub async fn set_with_desc(key: &str, value: &str, description: &str) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();
    {
        let conn = crate::db_pool::get_conn();
        conn.execute(
            "INSERT OR REPLACE INTO app_config (key, value, description, updated_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![key, value, description, now],
        ).map_err(|e| format!("写入 app_config 失败: {}", e))?;
    }

    if let Some(cache) = APP_CONFIG.get() {
        let mut map = cache.write().unwrap();
        map.insert(key.to_string(), ConfigEntry {
            value: value.to_string(),
            description: description.to_string(),
        });
    }
    Ok(())
}

/// 批量更新配置
pub async fn batch_update(updates: Vec<(String, String)>) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();
    {
        let conn = crate::db_pool::get_conn();
        for (key, value) in &updates {
            conn.execute(
                "INSERT OR REPLACE INTO app_config (key, value, description, updated_at) VALUES (?1, ?2, COALESCE((SELECT description FROM app_config WHERE key = ?1), ''), ?3)",
                rusqlite::params![key, value, now],
            ).map_err(|e| format!("批量更新配置失败: key={}, {}", key, e))?;
        }
    }

    if let Some(cache) = APP_CONFIG.get() {
        let mut map = cache.write().unwrap();
        for (key, value) in updates {
            map.entry(key).or_insert_with(|| ConfigEntry {
                value: String::new(),
                description: String::new(),
            }).value = value;
        }
    }
    Ok(())
}
