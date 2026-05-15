//! N11: Database access — connection pool via r2d2-sqlite
//!
//! Uses a pool of up to 30 SQLite connections so every request
//! doesn't pay the cost of opening a new file handle.
//!
//! PRAGMA busy_timeout=5000 is applied once per connection at creation
//! time via `with_init()`, avoiding redundant PRAGMA calls on every
//! checkout.

use std::sync::OnceLock;
use std::time::Duration;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

/// Re-export the pooled connection type so callers see the same interface.
pub type DbConn = r2d2::PooledConnection<SqliteConnectionManager>;

static DB_POOL: OnceLock<Pool<SqliteConnectionManager>> = OnceLock::new();

/// Initialize the connection pool. Call once at startup.
pub fn init(db_path: &str) -> Result<(), String> {
    let manager = SqliteConnectionManager::file(db_path)
        .with_init(|conn| {
            conn.execute_batch("PRAGMA busy_timeout=5000;")
        });
    let pool = Pool::builder()
        .max_size(30)
        .build(manager)
        .map_err(|e| format!("DB pool init: {}", e))?;

    // Enable WAL mode — persistent across all connections once set.
    {
        let conn = pool.get().map_err(|e| format!("Pool get: {}", e))?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| format!("DB pragma: {}", e))?;
    }

    DB_POOL.set(pool)
        .map_err(|_| "DB pool already initialized".to_string())
}

/// Get a connection from the pool. Panics if pool not initialized.
///
/// Returns a `PooledConnection` that derefs to `rusqlite::Connection`,
/// so all existing code using `conn.execute` / `conn.prepare` /
/// `conn.query_row` works unchanged.
///
/// Uses `get_timeout(10s)` instead of blocking `get()` — in an async
/// context (tokio), a blocked thread starves the runtime. The 10-second
/// timeout gives the pool ample time to recycle an in-use connection
/// while avoiding indefinite blocking.
pub fn get_conn() -> DbConn {
    DB_POOL
        .get()
        .expect("DB pool not initialized — call init() first")
        .get_timeout(Duration::from_secs(10))
        .expect("Failed to get DB connection from pool (timeout after 10s)")
}
