//! 调试跟踪器缓存
//!
//! debug_trackers 表 → Arc<RwLock<HashMap<String, TrackerEntry>>>
//! 起服时加载所有 status='active' 的跟踪记录到内存
//! 提供 is_tracked(user_id) 和 refresh_trackers() 接口

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

/// 跟踪条目
#[derive(Debug, Clone)]
pub struct TrackerEntry {
    pub id: String,
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub subject: Option<String>,
    pub created_at: i64,
}

/// 全局跟踪器缓存
static TRACKERS: OnceLock<Arc<RwLock<HashMap<String, TrackerEntry>>>> = OnceLock::new();

/// 初始化跟踪器缓存（起服时调用）
pub fn init_cache(conn: &rusqlite::Connection) -> Result<(), String> {
    let cache = Arc::new(RwLock::new(HashMap::new()));
    TRACKERS.set(cache.clone())
        .map_err(|_| "TRACKERS 已初始化".to_string())?;
    reload(conn)
}

/// 从 DB 加载所有 active 跟踪到缓存
pub fn reload(conn: &rusqlite::Connection) -> Result<(), String> {
    let cache = TRACKERS.get()
        .ok_or("TRACKERS 未初始化")?;

    let mut stmt = conn.prepare(
        "SELECT id, user_id, conversation_id, subject, created_at FROM debug_trackers WHERE status = 'active'"
    ).map_err(|e| format!("查询 debug_trackers 失败: {}", e))?;

    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, i64>(4)?,
        ))
    }).map_err(|e| format!("遍历 debug_trackers 失败: {}", e))?;

    let mut map = cache.write().unwrap();
    map.clear();
    for row in rows {
        let (id, user_id, conversation_id, subject, created_at) =
            row.map_err(|e| format!("读取 debug_trackers 行失败: {}", e))?;
        map.insert(id.clone(), TrackerEntry {
            id, user_id, conversation_id, subject, created_at,
        });
    }
    Ok(())
}

/// 检查 user_id 是否被跟踪
pub fn is_tracked(user_id: &str) -> bool {
    let cache = match TRACKERS.get() {
        Some(c) => c,
        None => return false,
    };
    let map = cache.read().unwrap();
    map.values().any(|entry| entry.user_id == user_id)
}

/// 检查 conversation_id 是否被跟踪
pub fn is_conv_tracked(conversation_id: &str) -> bool {
    let cache = match TRACKERS.get() {
        Some(c) => c,
        None => return false,
    };
    let map = cache.read().unwrap();
    map.values().any(|entry| {
        entry.conversation_id.as_deref() == Some(conversation_id)
    })
}

/// 获取所有活跃跟踪器
pub fn list_active() -> Vec<TrackerEntry> {
    let cache = match TRACKERS.get() {
        Some(c) => c,
        None => return vec![],
    };
    let map = cache.read().unwrap();
    map.values().cloned().collect()
}

/// 添加跟踪器到缓存
pub fn add_tracker(entry: TrackerEntry) {
    if let Some(cache) = TRACKERS.get() {
        let mut map = cache.write().unwrap();
        map.insert(entry.id.clone(), entry);
    }
}

/// 从缓存中移除跟踪器
pub fn remove_tracker(id: &str) {
    if let Some(cache) = TRACKERS.get() {
        let mut map = cache.write().unwrap();
        map.remove(id);
    }
}
