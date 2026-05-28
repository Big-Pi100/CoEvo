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
    display_name TEXT DEFAULT NULL,
    real_name TEXT DEFAULT NULL,
    phone TEXT DEFAULT NULL,
    id_number TEXT DEFAULT NULL,
    bind_hash TEXT DEFAULT NULL,
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
    plan_content TEXT DEFAULT NULL,
    plan_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();

    // ── Logging: file-based with daily rotation ──
    // On Android APK, stdout is invisible; logs go to files instead.
    // Set COEVO_LOG_STDOUT=1 for dev to also see logs on console.
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

    // 启动时显式输出 K12 数据路径（不受 tracing 影响，一定看得到）
    let prebuilt = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "docs/curriculum/prebuilt".to_string());
    eprintln!("[K12] data dir: {}", prebuilt);

    tracing::info!("CoEvo backend starting, logs: {}/coevo.log.*", log_dir);

    // --- Paths from environment (with hardcoded defaults for dev) ---
    let db_path = std::env::var("COEVO_DB_PATH").unwrap_or_else(|_| "data/coevo.db".to_string());
    let avatar_dir = std::env::var("COEVO_AVATAR_DIR").unwrap_or_else(|_| "data/avatars".to_string());
    let prompts_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    let pipelines_dir = std::env::var("COEVO_PIPELINES_DIR").unwrap_or_else(|_| "pipelines".to_string());
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

    // Load prompts from files (general + pipelines)
    chat_engine::prompt_loader::init(&prompts_dir, &pipelines_dir);
    tracing::info!("Prompts: {} (general), {} (pipelines)", prompts_dir, pipelines_dir);

    // Load word bank (CEFR catalog)
    chat_engine::word_bank::init(&wordbank_path);
    tracing::info!("Wordbank: {}", wordbank_path);

    // Load curriculum guide
    api_server::curriculum_loader::init().unwrap_or_else(|e| tracing::warn!("K12 loader: {}", e));
    api_server::reading_loader::init().unwrap_or_else(|e| {
        eprintln!("[READING] init failed: {}", e);
        tracing::error!("READING loader: {}", e);
    });
    tracing::info!("Data loaders initialized");
    tracing::info!("Knowledge graph loaded");

    // K12 quiz bank — 需要 DB 连接
    {
        let conn = api_server::db_pool::get_conn();
        match api_server::k12_quiz_loader::load_quiz_bank(&conn, "docs/curriculum/prebuilt") {
            Ok(n) => tracing::info!("K12 quiz bank: {} quizzes loaded", n),
            Err(e) => tracing::warn!("K12 quiz bank: {}", e),
        }
    }

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
            tracing::info!("Schema initialized (10 tables, tokens + migrations to follow)");
        }

        let migrations: &[&str] = &[
            "ALTER TABLE users ADD COLUMN streak_days INTEGER DEFAULT 0",
            "ALTER TABLE users ADD COLUMN last_active_date TEXT",
            "ALTER TABLE conversations ADD COLUMN learning_plan_id TEXT",
            "ALTER TABLE achievements ADD COLUMN tier TEXT DEFAULT 'fixed'",
            "ALTER TABLE achievements ADD COLUMN source TEXT",
            "ALTER TABLE learning_plans ADD COLUMN conversation_id TEXT",
            "ALTER TABLE learning_plans ADD COLUMN plan_content TEXT DEFAULT NULL",
            "CREATE TABLE IF NOT EXISTS learning_plans (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                conversation_id TEXT,
                goal TEXT NOT NULL,
                domain TEXT NOT NULL,
                mode TEXT DEFAULT NULL,
                plan_content TEXT DEFAULT NULL,
                plan_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_learning_plans_user ON learning_plans(user_id)",
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
            // 清理重复的学习计划（保留每个 user_id+domain 最新的一条）
            "DELETE FROM learning_plans WHERE id IN (SELECT l1.id FROM learning_plans l1 WHERE EXISTS (SELECT 1 FROM learning_plans l2 WHERE l2.user_id = l1.user_id AND l2.domain = l1.domain AND (l2.updated_at > l1.updated_at OR (l2.updated_at = l1.updated_at AND l2.id > l1.id))))",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_plans_user_domain ON learning_plans(user_id, domain)",
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
            // K12 支持 — 添加 cards 表字段
            "ALTER TABLE cards ADD COLUMN subject TEXT DEFAULT NULL",
            "ALTER TABLE cards ADD COLUMN grade_band TEXT DEFAULT NULL",
            "ALTER TABLE cards ADD COLUMN k12_card_id TEXT DEFAULT NULL",
            // K12 进度追踪
            "CREATE TABLE IF NOT EXISTS k12_progress (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                subject TEXT NOT NULL,
                grade_band TEXT NOT NULL,
                plan_json TEXT,
                mastered_cards INTEGER DEFAULT 0,
                total_cards INTEGER DEFAULT 0,
                started_at TEXT NOT NULL,
                last_activity_at TEXT,
                completed_at TEXT,
                FOREIGN KEY (user_id) REFERENCES users(id),
                UNIQUE(user_id, subject, grade_band)
            )",
            "CREATE TABLE IF NOT EXISTS k12_achievements (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                achievement_id TEXT NOT NULL,
                unlocked_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id),
                UNIQUE(user_id, achievement_id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_k12_progress_user ON k12_progress(user_id)",
            "CREATE INDEX IF NOT EXISTS idx_k12_achievements_user ON k12_achievements(user_id)",
            // K12 — conversations 表加 subject/grade_band 列
            "ALTER TABLE conversations ADD COLUMN subject TEXT DEFAULT NULL",
            "ALTER TABLE conversations ADD COLUMN grade_band TEXT DEFAULT NULL",
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

            // V2.2 知识图谱支持
            // cards 表新增字段
            "ALTER TABLE cards ADD COLUMN gold_cr_id TEXT DEFAULT NULL",
            "ALTER TABLE cards ADD COLUMN plan_task_id TEXT DEFAULT NULL",
            "ALTER TABLE cards ADD COLUMN origin TEXT DEFAULT 'extracted'",
            // k12_quiz_bank 新增关联字段
            "ALTER TABLE k12_quiz_bank ADD COLUMN assessment_item_id TEXT DEFAULT NULL",
            "ALTER TABLE k12_quiz_bank ADD COLUMN plan_stage_id TEXT DEFAULT NULL",
            "ALTER TABLE k12_quiz_bank ADD COLUMN plan_task_id TEXT DEFAULT NULL",
            // 知识图谱边表
            "CREATE TABLE IF NOT EXISTS knowledge_graph (
                id TEXT PRIMARY KEY,
                source_subject TEXT NOT NULL,
                source_stage TEXT,
                source_task TEXT,
                target_subject TEXT NOT NULL,
                target_stage TEXT,
                target_task TEXT,
                edge_type TEXT NOT NULL,
                strength TEXT DEFAULT 'medium',
                note TEXT,
                created_at TEXT NOT NULL
            )",
            "CREATE INDEX IF NOT EXISTS idx_kg_source ON knowledge_graph(source_subject, source_stage)",
            "CREATE INDEX IF NOT EXISTS idx_kg_target ON knowledge_graph(target_subject, target_stage)",

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

    // --- PII 加密迁移：加密现有明文数据 + 计算 bind_hash ---
    {
        let conn = api_server::db_pool::get_conn();
        // Users table — encrypt real_name and phone, compute bind_hash
        let mut stmt = conn.prepare("SELECT id, real_name, phone FROM users WHERE real_name IS NOT NULL OR phone IS NOT NULL").unwrap();
        let rows: Vec<(String, Option<String>, Option<String>)> = stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        }).unwrap().filter_map(|r| r.ok()).collect();
        for (uid, rn, ph) in &rows {
            let needs_update = rn.as_ref().map_or(false, |v| !api_server::encryption::is_encrypted(v))
                || ph.as_ref().map_or(false, |v| !api_server::encryption::is_encrypted(v));
            if needs_update {
                let enc_rn = rn.as_ref().map(|v| {
                    if api_server::encryption::is_encrypted(v) { v.clone() }
                    else { api_server::encryption::encrypt(v) }
                });
                let enc_ph = ph.as_ref().map(|v| {
                    if api_server::encryption::is_encrypted(v) { v.clone() }
                    else { api_server::encryption::encrypt(v) }
                });
                let bh = api_server::encryption::bind_hash(
                    rn.as_deref().unwrap_or(""),
                    ph.as_deref().unwrap_or(""),
                );
                let _ = conn.execute(
                    "UPDATE users SET real_name=?1, phone=?2, bind_hash=?3 WHERE id=?4",
                    rusqlite::params![enc_rn, enc_ph, bh, uid],
                );
                tracing::info!("Encrypted PII for user {}", uid);
            }
        }
        // Admin users table — encrypt real_name, phone, id_number, guardian_declaration
        let mut stmt2 = conn.prepare("SELECT id, real_name, phone, id_number, guardian_declaration FROM admin_users WHERE real_name IS NOT NULL OR phone IS NOT NULL").unwrap();
        let admins: Vec<(String, Option<String>, Option<String>, Option<String>, Option<String>)> = stmt2.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
        }).unwrap().filter_map(|r| r.ok()).collect();
        for (aid, rn, ph, idn, gd) in &admins {
            let needs_enc = |v: &Option<String>| v.as_ref().map_or(false, |s| !api_server::encryption::is_encrypted(s));
            if needs_enc(rn) || needs_enc(ph) || needs_enc(idn) || needs_enc(gd) {
                let enc_rn = rn.as_ref().map(|v| if api_server::encryption::is_encrypted(v) { v.clone() } else { api_server::encryption::encrypt(v) });
                let enc_ph = ph.as_ref().map(|v| if api_server::encryption::is_encrypted(v) { v.clone() } else { api_server::encryption::encrypt(v) });
                let enc_idn = idn.as_ref().map(|v| if api_server::encryption::is_encrypted(v) { v.clone() } else { api_server::encryption::encrypt(v) });
                let enc_gd = gd.as_ref().map(|v| if api_server::encryption::is_encrypted(v) { v.clone() } else { api_server::encryption::encrypt(v) });
                let _ = conn.execute(
                    "UPDATE admin_users SET real_name=?1, phone=?2, id_number=?3, guardian_declaration=?4 WHERE id=?5",
                    rusqlite::params![enc_rn, enc_ph, enc_idn, enc_gd, aid],
                );
                tracing::info!("Encrypted PII for admin user {}", aid);
            }
        }
    }

    // --- Plan JSON 迁移：将旧格式（含 stages）拆分为 plan_content + plan_json(task_status) ---
    {
        let conn = api_server::db_pool::get_conn();
        let mut stmt = conn.prepare(
            "SELECT id, plan_json FROM learning_plans WHERE plan_content IS NULL AND plan_json LIKE '%\"stages\"%'"
        ).unwrap();
        let rows: Vec<(String, String)> = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).unwrap().filter_map(|r| r.ok()).collect();

        let count = rows.len();
        if count > 0 {
            tracing::info!("Migrating {} learning_plans to plan_content + plan_json(task_status)", count);
            let mut migrated = 0u32;
            for (pid, plan_json_str) in &rows {
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(plan_json_str) {
                    // 提取 task_status
                    let mut status_map = serde_json::Map::new();
                    if let Some(stages) = plan.get("stages").and_then(|s| s.as_array()) {
                        for stage in stages {
                            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                                for task in tasks {
                                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                        let status = task.get("status").and_then(|s| s.as_str()).unwrap_or("pending");
                                        status_map.insert(name.to_string(), serde_json::json!(status));
                                    }
                                }
                            }
                        }
                    }
                    let new_plan_json = serde_json::json!({"task_status": status_map});
                    if let Err(e) = conn.execute(
                        "UPDATE learning_plans SET plan_content=?1, plan_json=?2 WHERE id=?3",
                        rusqlite::params![plan_json_str, new_plan_json.to_string(), pid],
                    ) {
                        tracing::error!("Migrate plan {} failed: {}", pid, e);
                    } else {
                        migrated += 1;
                    }
                }
            }
            tracing::info!("Plan JSON migration: {}/{} done", migrated, count);
        } else {
            tracing::info!("Plan JSON migration: no old-format plans found");
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
