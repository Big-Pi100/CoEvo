//! CoEvo Backend — Entry Point
//!
//! Runs as a localhost API server inside the Android APK,
//! or directly on a VPS for development/testing.
//! Paths are configurable via environment variables.

#![allow(clippy::type_complexity)]
//!
//! Schema & migration errors are propagated — the process will exit
//! on critical failures to avoid running in a broken state.

/// Panic hook：崩溃时打印信息到 stderr
fn setup_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        eprintln!("\n====== PANIC ======");
        eprintln!("{}", info);
        eprintln!("===================\n");
    }));
}

#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();
    setup_panic_hook();

    // ── Logging: file-based with daily rotation ──
    // On Android APK, stdout is invisible; logs go to files instead.
    // Default level: info. Override via RUST_LOG env var (e.g. RUST_LOG=debug).
    // Logs are written ONLY to files — not to stdout/stderr.
    let log_dir = std::env::var("COEVO_LOG_DIR").unwrap_or_else(|_| "data/logs".to_string());
    let _ = std::fs::create_dir_all(&log_dir);
    let file_appender = tracing_appender::rolling::daily(&log_dir, "coevo.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    // Keep _guard alive for the entire program — it flushes logs on drop
    std::mem::forget(_guard);

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_writer(non_blocking)
        .with_ansi(false)
        .init();

    // 启动时显式输出 K12 数据路径（日志系统已就绪，通过 tracing 输出）
    let prebuilt = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v3".to_string());
    tracing::info!("[K12] data dir: {}", prebuilt);

    tracing::info!("CoEvo backend starting, logs: {}/coevo.log.*", log_dir);

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

    // 成就引擎（TOML 数据驱动）
    {
        let ach_toml = std::env::var("COEVO_ACHIEVEMENTS_TOML")
            .unwrap_or_else(|_| "achievements.toml".to_string());
        api_server::achievement_engine::init(&ach_toml);
        tracing::info!("AchievementEngine: {}", ach_toml);
    }

    // Load prompts from files (general + pipelines)
    chat_engine::prompt_loader::init(&prompts_dir);
    tracing::info!("Prompts: {}", prompts_dir);

    // Load word bank (CEFR catalog)
    chat_engine::word_bank::init(&wordbank_path);
    tracing::info!("Wordbank: {}", wordbank_path);

    // Load curriculum guide
    api_server::curriculum_loader::init().unwrap_or_else(|e| tracing::warn!("K12 loader: {}", e));
    tracing::info!("Data loaders initialized");

    // K12 quiz bank — 需要 DB 连接
    {
        let conn = api_server::db_pool::get_conn();
        match api_server::k12_quiz_loader::load_quiz_bank(&conn, &prebuilt) {
            Ok(n) => tracing::info!("K12 quiz bank: {} quizzes loaded", n),
            Err(e) => tracing::warn!("K12 quiz bank: {}", e),
        }
    }

    chat_engine::config::ensure_db_connection();

    // --- Auto-schema ---
    {
        let conn = api_server::db_pool::get_conn();
        let table_count: i32 = conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('users','cards','card_memory')",
            [], |row| row.get(0),
        ).unwrap_or(0);
        if table_count < 3 {
            api_server::schema::init_database(&conn)
                .unwrap_or_else(|e| {
                    tracing::error!("Schema init failed critically: {}", e);
                    panic!("Schema init failed: {}", e);
                });
            tracing::info!("Schema initialized (production schema)");
        }

        let migrations: &[&str] = &[
            "ALTER TABLE users ADD COLUMN streak_days INTEGER DEFAULT 0",
            "ALTER TABLE users ADD COLUMN last_active_date TEXT",
            "ALTER TABLE achievements ADD COLUMN tier TEXT DEFAULT 'fixed'",
            "ALTER TABLE achievements ADD COLUMN source TEXT",
            "ALTER TABLE users ADD COLUMN display_name TEXT DEFAULT NULL",
            "ALTER TABLE cards ADD COLUMN conversation_id TEXT",
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
            // V2.2: cards 表加 subject 列 + 索引
            "ALTER TABLE cards ADD COLUMN subject TEXT DEFAULT NULL",
            "CREATE INDEX IF NOT EXISTS idx_cards_user_subject ON cards(user_id, subject)",
            // 对话软删除支持
            "ALTER TABLE conversations ADD COLUMN deleted_at TEXT DEFAULT NULL",
            "CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at)",
            // 管理后台重构 — PII 字段
            "ALTER TABLE users ADD COLUMN real_name TEXT DEFAULT NULL",
            "ALTER TABLE users ADD COLUMN phone TEXT DEFAULT NULL",
            "ALTER TABLE users ADD COLUMN id_number TEXT DEFAULT NULL",
            // AES-256-GCM 加密迁移 — bind_hash 用于确定性查找
            "ALTER TABLE users ADD COLUMN bind_hash TEXT DEFAULT NULL",
            // 软删除支持
            "ALTER TABLE users ADD COLUMN deleted_at TEXT DEFAULT NULL",
            // 管理员表
            "CREATE TABLE IF NOT EXISTS admin_users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'pending',
                status TEXT NOT NULL DEFAULT 'pending',
                real_name TEXT,
                phone TEXT,
                id_number TEXT,
                guardian_declaration TEXT,
                apply_reason TEXT,
                reject_reason TEXT,
                registered_from TEXT,
                created_by TEXT,
                created_at TEXT NOT NULL,
                approved_at TEXT
            )",
            // 订阅申请审批表
            "CREATE TABLE IF NOT EXISTS subscription_requests (
                id TEXT PRIMARY KEY,
                target_user_id TEXT NOT NULL,
                requested_by TEXT NOT NULL,
                reviewed_by TEXT,
                package TEXT NOT NULL,
                channel TEXT,
                note TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                reject_reason TEXT,
                requested_at TEXT NOT NULL,
                reviewed_at TEXT,
                FOREIGN KEY (target_user_id) REFERENCES users(id)
            )",
            // 操作审计日志
            "CREATE TABLE IF NOT EXISTS admin_audit_log (
                id TEXT PRIMARY KEY,
                admin_id TEXT NOT NULL,
                action TEXT NOT NULL,
                target_user_id TEXT,
                request_id TEXT,
                detail TEXT,
                created_at TEXT NOT NULL
            )",
            // 监护关系
            "CREATE TABLE IF NOT EXISTS guardian_assignments (
                id TEXT PRIMARY KEY,
                guardian_admin_id TEXT NOT NULL,
                student_user_id TEXT NOT NULL,
                bind_key TEXT NOT NULL,
                assigned_by TEXT,
                assigned_at TEXT NOT NULL,
                is_active INTEGER DEFAULT 1,
                UNIQUE(guardian_admin_id, student_user_id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status)",
            "CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status)",
            "CREATE INDEX IF NOT EXISTS idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id)",
            "CREATE INDEX IF NOT EXISTS idx_guardian_assignments_student ON guardian_assignments(student_user_id)",
            "CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at)",
            "ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}'",
            // K12 题库
            "CREATE TABLE IF NOT EXISTS k12_quiz_bank (
                id TEXT PRIMARY KEY,
                subject TEXT NOT NULL,
                grade_band TEXT NOT NULL,
                task_name TEXT,
                question TEXT NOT NULL,
                answer TEXT NOT NULL,
                question_type TEXT,
                options TEXT,
                source_dataset TEXT,
                difficulty REAL DEFAULT 0.5
            )",
            "CREATE TABLE IF NOT EXISTS k12_quiz_attempts (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                quiz_id TEXT NOT NULL,
                conversation_id TEXT,
                user_answer TEXT,
                is_correct INTEGER,
                attempted_at TEXT NOT NULL,
                task_name TEXT,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_k12_quiz_bank_subject_grade ON k12_quiz_bank(subject, grade_band)",
            "CREATE INDEX IF NOT EXISTS idx_k12_quiz_attempts_user_quiz ON k12_quiz_attempts(user_id, quiz_id)",

            // k12_quiz_bank 新增关联字段
            "ALTER TABLE k12_quiz_bank ADD COLUMN assessment_item_id TEXT DEFAULT NULL",
            "ALTER TABLE k12_quiz_bank ADD COLUMN plan_stage_id TEXT DEFAULT NULL",
            // 手机号唯一性约束（先清理重复值再建索引）
            "UPDATE users SET phone_hash = NULL WHERE id NOT IN (SELECT MIN(id) FROM users WHERE phone_hash IS NOT NULL AND phone_hash != '' GROUP BY phone_hash)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL",

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

    // ════════════════════════════════════════════
    // Start server
    // ════════════════════════════════════════════

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
