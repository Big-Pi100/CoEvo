//! CoEvo Backend — Entry Point
//!
//! Runs as a localhost API server inside the Android APK,
//! or directly on a VPS for development/testing.
//! Paths are configurable via environment variables.
//!
//! Schema & migration errors are propagated — the process will exit
//! on critical failures to avoid running in a broken state.

/// 内联数据库 Schema（替代 schema.sql 文件，确保 APK 部署不依赖文件系统）
const SCHEMA_SQL: &str = r#"
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    learning_plan_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,
    card_type TEXT NOT NULL,
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER DEFAULT 0,
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL,
    verification_result TEXT NOT NULL,
    reviewed_at INTEGER NOT NULL,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',
    source TEXT,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards(user_id);
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE TABLE learning_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    goal TEXT NOT NULL,
    domain TEXT NOT NULL,
    mode TEXT DEFAULT NULL,
    plan_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt::init();

    // --- Paths from environment (with hardcoded defaults for dev) ---
    let db_path = std::env::var("COEVO_DB_PATH").unwrap_or_else(|_| "data/coevo.db".to_string());
    let avatar_dir = std::env::var("COEVO_AVATAR_DIR").unwrap_or_else(|_| "data/avatars".to_string());
    let prompts_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    let wordbank_path = std::env::var("COEVO_WORDBANK_PATH").unwrap_or_else(|_| "cefr_catalog.json".to_string());
    let host = std::env::var("COEVO_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port: u16 = std::env::var("COEVO_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8080);

    // Initialize DB
    api_server::db_pool::init(&db_path)
        .expect("Failed to init DB pool");
    tracing::info!("DB: {}", db_path);

    // Load prompts from files
    chat_engine::prompt_loader::init(&prompts_dir);
    tracing::info!("Prompts: {}", prompts_dir);

    // Load word bank (CEFR catalog)
    chat_engine::word_bank::init(&wordbank_path);
    tracing::info!("Wordbank: {}", wordbank_path);

    chat_engine::config::ensure_db_connection();

    // --- Auto-schema + Migrations ---
    {
        let conn = api_server::db_pool::get_conn();
        let table_count: i32 = conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('users','cards','card_memory')",
            [], |row| row.get(0),
        ).unwrap_or(0);
        if table_count < 3 {
            let safe_sql = SCHEMA_SQL.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS");
            // Critical: schema init failure should prevent startup
            conn.execute_batch(&safe_sql)
                .unwrap_or_else(|e| {
                    tracing::error!("Schema init failed critically: {}", e);
                    panic!("Schema init failed: {}", e);
                });
            tracing::info!("Schema initialized (9 tables)");
        }

        let migrations: &[&str] = &[
            "ALTER TABLE users ADD COLUMN streak_days INTEGER DEFAULT 0",
            "ALTER TABLE users ADD COLUMN last_active_date TEXT",
            "ALTER TABLE conversations ADD COLUMN learning_plan_id TEXT",
            "ALTER TABLE achievements ADD COLUMN tier TEXT DEFAULT 'fixed'",
            "ALTER TABLE achievements ADD COLUMN source TEXT",
            "ALTER TABLE learning_plans ADD COLUMN conversation_id TEXT",
            "CREATE TABLE IF NOT EXISTS learning_plans (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                conversation_id TEXT,
                goal TEXT NOT NULL,
                domain TEXT NOT NULL,
                mode TEXT DEFAULT NULL,
                plan_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_learning_plans_user ON learning_plans(user_id)",
            "ALTER TABLE users ADD COLUMN display_name TEXT DEFAULT NULL",
            "CREATE TABLE IF NOT EXISTS user_preferences (
                user_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (user_id, key),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "ALTER TABLE review_log ADD COLUMN details_json TEXT DEFAULT NULL",
            "CREATE TABLE IF NOT EXISTS tokens (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                token TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at)",
            "CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_cards_user_domain ON cards(user_id, domain)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_plans_user_domain ON learning_plans(user_id, domain)",
        ];

        for sql in migrations {
            match conn.execute(sql, []) {
                Ok(_) => {}
                Err(e) => {
                    let err_msg = e.to_string();
                    if err_msg.contains("duplicate column") || err_msg.contains("already exists") {
                        tracing::debug!("Migration skipped (already applied): {}", err_msg);
                    } else {
                        // Propagate critical migration errors — fail startup
                        tracing::error!("Migration failed critically: {} — SQL: {}", err_msg, sql);
                        panic!("Migration failed: {} — SQL: {}", err_msg, sql);
                    }
                }
            }
        }
    }

    // --- Configure avatar dir (routes.rs uses OnceLock) ---
    api_server::routes::set_avatar_dir(&avatar_dir);
    tracing::info!("Avatars: {}", avatar_dir);

    // --- LLM Config ---
    let llm_config = chat_engine::config::load_llm_config();
    tracing::info!("LLM: {} @ {}", llm_config.model, llm_config.base_url);
    let cfg_clone = llm_config.clone();
    tokio::spawn(async move {
        chat_engine::llm_caller::warmup_with_config(cfg_clone).await;
    });

    // --- Router ---
    use tower_http::cors::{CorsLayer, Any};
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = api_server::routes::build_router(llm_config)
        .layer(cors);

    let bind_addr = format!("{}:{}", host, port);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await.unwrap();
    tracing::info!("CoEvo ready on http://{}", bind_addr);
    axum::serve(listener, app).await.unwrap();
}
