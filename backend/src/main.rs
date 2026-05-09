//! CoEvo Backend — Entry Point
//!
//! Loads environment configuration and starts the API server.

#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt::init();

    // Initialize DB
    api_server::db_pool::init("data/coevo.db")
        .expect("Failed to init DB pool");

    // Load prompts from files
    chat_engine::prompt_loader::init("prompts");
    tracing::info!("Prompts loaded from prompts/");

    // Load word bank (CEFR catalog)
    chat_engine::word_bank::init("cefr_catalog.json");

    chat_engine::config::ensure_db_connection();

    // Auto-schema (idempotent)
    {
        let conn = api_server::db_pool::get_conn();
        let table_count: i32 = conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('users','cards','card_memory')",
            [], |row| row.get(0),
        ).unwrap_or(0);
        if table_count < 3 {
            if let Ok(sql) = std::fs::read_to_string("schema.sql") {
                let safe_sql = sql.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS");
                if let Err(e) = conn.execute_batch(&safe_sql) {
                    tracing::error!("schema init failed: {}", e);
                } else {
                    tracing::info!("Schema initialized (9 tables)");
                }
            }
        }
        // Migrations: add columns that may be missing in older DBs
        let migrations = [
            "ALTER TABLE users ADD COLUMN streak_days INTEGER DEFAULT 0",
            "ALTER TABLE users ADD COLUMN last_active_date TEXT",
            "ALTER TABLE conversations ADD COLUMN learning_plan_id TEXT",
            "ALTER TABLE achievements ADD COLUMN tier TEXT DEFAULT 'fixed'",
            "ALTER TABLE achievements ADD COLUMN source TEXT",
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
        ];
        for sql in &migrations {
            let _ = conn.execute(sql, []);
        }
    }

    // Warm up LLM
    let llm_config = chat_engine::config::load_llm_config();
    tracing::info!("LLM: {} @ {}", llm_config.model, llm_config.base_url);
    let cfg_clone = llm_config.clone();
    tokio::spawn(async move {
        chat_engine::llm_caller::warmup_with_config(cfg_clone).await;
    });

    // Build API with CORS
    use tower_http::cors::{CorsLayer, Any};
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = api_server::routes::build_router(llm_config)
        .layer(cors);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    tracing::info!("CoEvo API on http://0.0.0.0:8080");
    axum::serve(listener, app).await.unwrap();
}
