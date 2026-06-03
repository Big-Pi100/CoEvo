//! CoEvo Backend — Entry Point
//!
//! Runs as a localhost API server inside the Android APK,
//! or directly on a VPS for development/testing.
//! Paths are configurable via environment variables.

#![allow(clippy::type_complexity)]
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
    subject TEXT,
    grade_band TEXT,
    deleted_at TEXT,
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
    conversation_id TEXT,
    subject TEXT,
    grade_band TEXT,
    k12_card_id TEXT,
    gold_cr_id TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'pending', 'skipped', 'archived')),
    origin TEXT DEFAULT 'extracted'
        CHECK(origin IN ('extracted', 'prebuilt')),
    plan_type TEXT,
    plan_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
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
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL
        CHECK(verification_type IN ('spelling', 'typing', 'ai_dialogue')),
    verification_result TEXT NOT NULL
        CHECK(verification_result IN ('pass', 'fail')),
    reviewed_at INTEGER NOT NULL,
    details_json TEXT,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
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
CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards(user_id);
CREATE INDEX IF NOT EXISTS idx_cards_user_domain ON cards(user_id, domain);
CREATE INDEX IF NOT EXISTS idx_cards_conversation_id ON cards(conversation_id);
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE TABLE IF NOT EXISTS plan_templates (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    subject_key TEXT NOT NULL UNIQUE,
    grade_band TEXT NOT NULL,
    goal TEXT NOT NULL,
    plan_content TEXT NOT NULL,
    version INTEGER DEFAULT 1,
    updated_at INTEGER NOT NULL,
    UNIQUE(subject_key, grade_band)
);
CREATE TABLE IF NOT EXISTS conversation_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,
    goal TEXT NOT NULL,
    domain TEXT DEFAULT 'general',
    plan_content TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_conversation_plans_user ON conversation_plans(user_id);
CREATE TABLE IF NOT EXISTS user_plan_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_type TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    task_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'in_progress', 'done', 'skipped')),
    score REAL,
    attempt_count INTEGER DEFAULT 0,
    started_at INTEGER,
    completed_at INTEGER,
    updated_at INTEGER NOT NULL,
    UNIQUE(plan_id, task_key),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_upp_user_plan ON user_plan_progress(user_id, plan_type, plan_id);
CREATE INDEX IF NOT EXISTS idx_upp_status ON user_plan_progress(plan_id, status);
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
    let prebuilt = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/prebuilt".to_string());
    eprintln!("[K12] data dir: {}", prebuilt);

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

    // Load prompts from files (general + pipelines)
    chat_engine::prompt_loader::init(&prompts_dir);
    tracing::info!("Prompts: {}", prompts_dir);

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
        match api_server::k12_quiz_loader::load_quiz_bank(&conn, &prebuilt) {
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
            tracing::info!("Schema initialized (9 tables, tokens + migrations to follow)");
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
            "ALTER TABLE cards ADD COLUMN origin TEXT DEFAULT 'extracted'",
            // k12_quiz_bank 新增关联字段
            "ALTER TABLE k12_quiz_bank ADD COLUMN assessment_item_id TEXT DEFAULT NULL",
            "ALTER TABLE k12_quiz_bank ADD COLUMN plan_stage_id TEXT DEFAULT NULL",
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

        // ── V2.0 migrations: conversations table rebuild (drop learning_plan_id) ──
        {
            let has_old_col: bool = conn
                .prepare("SELECT learning_plan_id FROM conversations LIMIT 1")
                .is_ok();
            if has_old_col {
                tracing::info!("Migration V2.0: rebuilding conversations table (drop learning_plan_id)");
                // 临时关闭 FK 检查以允许 DROP TABLE + RENAME
                conn.execute_batch("PRAGMA foreign_keys=OFF;").unwrap();
                conn.execute_batch("
                    BEGIN TRANSACTION;
                    CREATE TABLE conversations_new (
                        id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        turn_count INTEGER DEFAULT 0,
                        started_at TEXT NOT NULL,
                        deleted_at TEXT,
                        subject TEXT,
                        grade_band TEXT,
                        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    );
                    INSERT INTO conversations_new (id, user_id, turn_count, started_at, deleted_at, subject, grade_band)
                        SELECT id, user_id, turn_count, started_at, deleted_at, subject, grade_band FROM conversations;
                    DROP TABLE conversations;
                    ALTER TABLE conversations_new RENAME TO conversations;
                    CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
                    COMMIT;
                ").unwrap_or_else(|e| {
                    tracing::error!("Migration V2.0 failed: {}", e);
                    panic!("Migration V2.0 failed: {}", e);
                });
                conn.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
                tracing::info!("Migration V2.0: conversations rebuilt successfully");
            } else {
                tracing::debug!("Migration V2.0: conversations already migrated (no learning_plan_id column)");
            }
        }

        {
            // 检测条件：cards 是否已有 origin 列（判断 Phase 4 是否已运行）
            let has_origin: bool = conn
                .prepare("SELECT origin FROM cards LIMIT 1")
                .is_ok();
            if !has_origin {
                tracing::info!("Migration V2.0 Phase4: rebuilding cards/review_log/card_memory");
                conn.execute_batch("PRAGMA foreign_keys=OFF;").unwrap();
                conn.execute_batch(r#"
                    BEGIN TRANSACTION;

                    -- 1. cards 重建（FK + origin CHECK）
                    CREATE TABLE cards_new (
                        id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        domain TEXT,
                        card_type TEXT NOT NULL,
                        front TEXT NOT NULL,
                        back TEXT NOT NULL,
                        source_sentence TEXT,
                        created_at INTEGER NOT NULL,
                        conversation_id TEXT,
                        subject TEXT,
                        grade_band TEXT,
                        k12_card_id TEXT,
                        gold_cr_id TEXT,
                        origin TEXT DEFAULT 'extracted'
                            CHECK(origin IN ('extracted', 'prebuilt')),
                        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
                    );
                    INSERT INTO cards_new SELECT * FROM cards;
                    DROP TABLE cards;
                    ALTER TABLE cards_new RENAME TO cards;
                    CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards(user_id);
                    CREATE INDEX IF NOT EXISTS idx_cards_user_domain ON cards(user_id, domain);
                    CREATE INDEX IF NOT EXISTS idx_cards_conversation_id ON cards(conversation_id);

                    -- 3. card_memory 重建（ON DELETE CASCADE）
                    CREATE TABLE card_memory_new (
                        card_id TEXT PRIMARY KEY,
                        state INTEGER DEFAULT 0,
                        difficulty REAL DEFAULT 5.0,
                        stability REAL DEFAULT 0.0,
                        due INTEGER DEFAULT 0,
                        last_review INTEGER,
                        reps INTEGER DEFAULT 0,
                        lapses INTEGER DEFAULT 0,
                        FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
                    );
                    INSERT INTO card_memory_new SELECT * FROM card_memory;
                    DROP TABLE card_memory;
                    ALTER TABLE card_memory_new RENAME TO card_memory;
                    CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);

                    -- 4. review_log 重建（CHECK 约束）
                    CREATE TABLE review_log_new (
                        id TEXT PRIMARY KEY,
                        card_id TEXT NOT NULL,
                        rating INTEGER NOT NULL,
                        verification_type TEXT NOT NULL
                            CHECK(verification_type IN ('spelling', 'typing', 'ai_dialogue')),
                        verification_result TEXT NOT NULL
                            CHECK(verification_result IN ('pass', 'fail')),
                        reviewed_at INTEGER NOT NULL,
                        details_json TEXT,
                        FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
                    );
                    INSERT INTO review_log_new SELECT * FROM review_log;
                    DROP TABLE review_log;
                    ALTER TABLE review_log_new RENAME TO review_log;
                    CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);

                    COMMIT;
                "#).unwrap_or_else(|e| {
                    tracing::error!("Migration V2.0 Phase4 failed: {}", e);
                    panic!("Migration V2.0 Phase4 failed: {}", e);
                });
                conn.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
                tracing::info!("Migration V2.0 Phase4: rebuild complete (cards: FK+origin CHECK, card_memory: CASCADE, review_log: CHECK)");
            } else {
                tracing::debug!("Migration V2.0 Phase4: already applied (cards have origin column)");
            }
        }

        // ── V2.0 Phase 4b: 预置卡 origin 标记修复 ──
        // Phase 4 迁移时旧数据（k12_prebuilt）被统一标记为 origin='extracted'，
        // 修正为 origin='prebuilt'
        {
            let need_fix: i64 = conn.query_row(
                "SELECT COUNT(*) FROM cards WHERE k12_card_id IS NOT NULL AND origin = 'extracted'",
                [], |row| row.get(0),
            ).unwrap_or(0);
            if need_fix > 0 {
                tracing::info!("Migration V2.0 Phase4b: fixing {} prebuilt cards' origin to 'prebuilt'", need_fix);
                conn.execute(
                    "UPDATE cards SET origin = 'prebuilt' WHERE k12_card_id IS NOT NULL AND origin = 'extracted'",
                    [],
                ).unwrap_or_else(|e| {
                    tracing::error!("Migration V2.0 Phase4b failed: {}", e);
                    0
                });
                tracing::info!("Migration V2.0 Phase4b: prebuilt card origin fixed");
            } else {
                tracing::debug!("Migration V2.0 Phase4b: no prebuilt cards need fixing");
            }
        }
    }

    // ── V2.1 Phase 0: 清理 learning_plan_tasks（已废弃，任务列表从 plan_content 运行时解析） ──
    {
        let conn = api_server::db_pool::get_conn();
        let has_tasks_table: bool = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='learning_plan_tasks'")
            .is_ok_and(|mut s| s.query_row([], |_| Ok(())).is_ok());
        if has_tasks_table {
            tracing::info!("Migration V2.1 Phase0: dropping deprecated learning_plan_tasks table");
            conn.execute_batch(r#"
                PRAGMA foreign_keys=OFF;
                DROP TABLE IF EXISTS learning_plan_tasks;
                PRAGMA foreign_keys=ON;
            "#).unwrap_or_else(|e| {
                tracing::error!("Migration V2.1 Phase0 failed: {}", e);
            });
            tracing::info!("Migration V2.1 Phase0: learning_plan_tasks dropped");
        } else {
            tracing::debug!("Migration V2.1 Phase0: already clean");
        }
    }

    // ── V2.1 Phase 1: 新建 plan_templates + conversation_plans + user_plan_progress ──
    {
        let conn = api_server::db_pool::get_conn();
        let has_plan_templates: bool = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='plan_templates'")
            .is_ok_and(|mut s| s.query_row([], |_| Ok(())).is_ok());
        if !has_plan_templates {
            tracing::info!("Migration V2.1 Phase1: creating plan_templates, conversation_plans, user_plan_progress");
            conn.execute_batch(r#"
                BEGIN TRANSACTION;

                CREATE TABLE IF NOT EXISTS plan_templates (
                    id TEXT PRIMARY KEY,
                    subject TEXT NOT NULL,
                    subject_key TEXT NOT NULL UNIQUE,
                    grade_band TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    plan_content TEXT NOT NULL,
                    version INTEGER DEFAULT 1,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(subject_key, grade_band)
                );

                CREATE TABLE IF NOT EXISTS conversation_plans (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL UNIQUE,
                    goal TEXT NOT NULL,
                    domain TEXT DEFAULT 'general'
                        CHECK(domain IN ('general','math','language','chemistry','biology','physics',
                                         'history','geography','politics','science','it','pe','art','labor')),
                    plan_content TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_conversation_plans_user ON conversation_plans(user_id);

                CREATE TABLE IF NOT EXISTS user_plan_progress (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    plan_type TEXT NOT NULL,
                    plan_id TEXT NOT NULL,
                    task_key TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending', 'in_progress', 'done', 'skipped')),
                    score REAL,
                    attempt_count INTEGER DEFAULT 0,
                    started_at INTEGER,
                    completed_at INTEGER,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(plan_id, task_key),
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_upp_user_plan ON user_plan_progress(user_id, plan_type, plan_id);
                CREATE INDEX IF NOT EXISTS idx_upp_status ON user_plan_progress(plan_id, status);

                COMMIT;
            "#).unwrap_or_else(|e| {
                tracing::error!("Migration V2.1 Phase1 failed: {}", e);
                panic!("Migration V2.1 Phase1 failed: {}", e);
            });
            tracing::info!("Migration V2.1 Phase1: 3 tables created successfully");
        } else {
            tracing::debug!("Migration V2.1 Phase1: already applied (plan_templates exists)");
        }
    }

    // ── V2.1 Phase 2: 重命名 cp1_plans → conversation_plans ──
    {
        let conn = api_server::db_pool::get_conn();
        let has_old_name: bool = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cp1_plans'")
            .is_ok_and(|mut s| s.query_row([], |_| Ok(())).is_ok());
        if has_old_name {
            let has_new_name: bool = conn
                .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='conversation_plans'")
                .is_ok_and(|mut s| s.query_row([], |_| Ok(())).is_ok());
            if !has_new_name {
                tracing::info!("Migration V2.1 Phase2: renaming cp1_plans → conversation_plans");
                conn.execute_batch(r#"
                    PRAGMA foreign_keys=OFF;
                    ALTER TABLE cp1_plans RENAME TO conversation_plans;
                    PRAGMA foreign_keys=ON;
                "#).unwrap_or_else(|e| {
                    tracing::error!("Migration V2.1 Phase2 failed: {}", e);
                    panic!("Migration V2.1 Phase2 failed: {}", e);
                });
                tracing::info!("Migration V2.1 Phase2: renamed successfully");
            } else {
                tracing::debug!("Migration V2.1 Phase2: both old and new table exist, dropping old");
                conn.execute_batch("DROP TABLE IF EXISTS cp1_plans;").unwrap();
            }
        } else {
            tracing::debug!("Migration V2.1 Phase2: already renamed (cp1_plans not found)");
        }
    }

    // ── Phase N: 加 cards.status 列 + 清理 domain/subject 中文值 + 废弃 skipped_concepts ──
    {
        let conn = api_server::db_pool::get_conn();
        // 检测条件：cards 表是否有 status 列
        let has_status: bool = conn
            .prepare("SELECT status FROM cards LIMIT 0")
            .is_ok();
        if has_status {
            tracing::debug!("Phase N: already applied (cards.status exists)");
        } else {
            tracing::info!("Phase N: adding status column, cleaning up subject codes, dropping skipped_concepts");
            conn.execute_batch(r#"
                -- 1. 加 status 列
                ALTER TABLE cards ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active', 'pending', 'skipped', 'archived'));

                -- 1b. 加 plan_type/plan_id 列（卡片→计划关联）
                ALTER TABLE cards ADD COLUMN plan_type TEXT;
                ALTER TABLE cards ADD COLUMN plan_id TEXT;

                -- 2. 迁移存量 origin='prebuilt' 为 status='active'
                UPDATE cards SET status = 'active' WHERE origin = 'prebuilt';

                -- 3. 清理 cards.domain 中文值 → 英文代码
                UPDATE cards SET domain = 'math'     WHERE domain = '数学';
                UPDATE cards SET domain = 'chinese'  WHERE domain = '语文';
                UPDATE cards SET domain = 'english'  WHERE domain = '英语';
                UPDATE cards SET domain = 'physics'  WHERE domain = '物理';
                UPDATE cards SET domain = 'chemistry'WHERE domain = '化学';
                UPDATE cards SET domain = 'biology'  WHERE domain = '生物' OR domain = '生物学';
                UPDATE cards SET domain = 'history'  WHERE domain = '历史';
                UPDATE cards SET domain = 'geography'WHERE domain = '地理';
                UPDATE cards SET domain = 'politics' WHERE domain = '政治' OR domain = '道德与法治' OR domain = '道法';
                UPDATE cards SET domain = 'science'  WHERE domain = '科学';
                UPDATE cards SET domain = 'it'        WHERE domain = '信息技术' OR domain = '信息科技';
                UPDATE cards SET domain = 'pe'        WHERE domain = '体育' OR domain = '体育与健康';
                UPDATE cards SET domain = 'art'       WHERE domain = '艺术' OR domain = '美术' OR domain = '音乐';
                UPDATE cards SET domain = 'labor'     WHERE domain = '劳动';
                UPDATE cards SET domain = 'japanese'  WHERE domain = '日语';
                UPDATE cards SET domain = 'russian'   WHERE domain = '俄语';
                UPDATE cards SET domain = 'general'   WHERE domain = '' OR domain IS NULL;

                -- 4. 清理 cards.subject 中文值 → 英文代码
                UPDATE cards SET subject = 'math'     WHERE subject = '数学';
                UPDATE cards SET subject = 'chinese'  WHERE subject = '语文';
                UPDATE cards SET subject = 'english'  WHERE subject = '英语';
                UPDATE cards SET subject = 'physics'  WHERE subject = '物理';
                UPDATE cards SET subject = 'chemistry'WHERE subject = '化学';
                UPDATE cards SET subject = 'biology'  WHERE subject = '生物' OR subject = '生物学';
                UPDATE cards SET subject = 'history'  WHERE subject = '历史';
                UPDATE cards SET subject = 'geography'WHERE subject = '地理';
                UPDATE cards SET subject = 'politics' WHERE subject = '政治' OR subject = '道德与法治';
                UPDATE cards SET subject = 'science'  WHERE subject = '科学';
                UPDATE cards SET subject = 'it'        WHERE subject = '信息技术' OR subject = '信息科技';
                UPDATE cards SET subject = 'pe'        WHERE subject = '体育';
                UPDATE cards SET subject = 'art'       WHERE subject = '艺术' OR subject = '美术' OR subject = '音乐';
                UPDATE cards SET subject = 'japanese'  WHERE subject = '日语';
                UPDATE cards SET subject = 'russian'   WHERE subject = '俄语';

                -- 5. 清理 conversations.subject 中文值 → 英文代码
                UPDATE conversations SET subject = 'math'     WHERE subject = '数学';
                UPDATE conversations SET subject = 'chinese'  WHERE subject = '语文';
                UPDATE conversations SET subject = 'english'  WHERE subject = '英语';
                UPDATE conversations SET subject = 'physics'  WHERE subject = '物理';
                UPDATE conversations SET subject = 'chemistry'WHERE subject = '化学';
                UPDATE conversations SET subject = 'biology'  WHERE subject = '生物' OR subject = '生物学';
                UPDATE conversations SET subject = 'history'  WHERE subject = '历史';
                UPDATE conversations SET subject = 'geography'WHERE subject = '地理';
                UPDATE conversations SET subject = 'politics' WHERE subject = '政治' OR subject = '道德与法治';
                UPDATE conversations SET subject = 'science'  WHERE subject = '科学';
                UPDATE conversations SET subject = 'it'        WHERE subject = '信息技术' OR subject = '信息科技';
                UPDATE conversations SET subject = 'pe'        WHERE subject = '体育';
                UPDATE conversations SET subject = 'art'       WHERE subject = '艺术' OR subject = '美术' OR subject = '音乐';
                UPDATE conversations SET subject = 'japanese'  WHERE subject = '日语';
                UPDATE conversations SET subject = 'russian'   WHERE subject = '俄语';

                -- 6. 废弃 skipped_concepts 表
                DROP TABLE IF EXISTS skipped_concepts;
            "#).unwrap_or_else(|e| {
                tracing::error!("Phase N migration failed: {}", e);
                panic!("Phase N migration failed: {}", e);
            });
            tracing::info!("Phase N: cards.status + subject code cleanup + skipped_concepts drop completed");
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
