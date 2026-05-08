//! N11: Database access
//!
//! WAL-mode connections are cheap. Each request opens its own short-lived
//! connection — no global lock, no contention.

use std::sync::OnceLock;
use rusqlite::Connection;

static DB_PATH: OnceLock<String> = OnceLock::new();

/// Initialize. Call once at startup.
pub fn init(db_path: &str) -> Result<(), String> {
    let conn = Connection::open(db_path).map_err(|e| format!("DB open: {}", e))?;
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")
        .map_err(|e| format!("DB pragma: {}", e))?;
    DB_PATH.set(db_path.to_string())
        .map_err(|_| "DB already initialized".to_string())
}

/// Open a new connection. Panics if not initialized.
pub fn get_conn() -> Connection {
    let path = DB_PATH.get().expect("DB not initialized — call init() first");
    Connection::open(path).expect("Failed to open DB connection")
}
