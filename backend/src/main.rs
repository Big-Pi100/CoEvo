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

    // 启动后台定时任务（佣金解锁 + NOTPAY 关单，每 5 分钟执行）
    api_server::campaign_scheduler::start_scheduler(&db_path);
    tracing::info!("Campaign scheduler started (interval: 5 min)");

    // 成就引擎已于 2026-09-29 退役（成就方向定为「端侧计算」→ 后端这份不再使用）

    // Load prompts from files (general + pipelines)
    chat_engine::prompt_loader::init(&prompts_dir);
    tracing::info!("Prompts: {}", prompts_dir);

    // 创建分享目录（存放 LLM 生成的 H5 推广页面）
    let _ = std::fs::create_dir_all("data/share");
    tracing::info!("Share dir: data/share");

    // Load word bank (CEFR catalog)
    chat_engine::word_bank::init(&wordbank_path);
    tracing::info!("Wordbank: {}", wordbank_path);

    // Load curriculum guide (deferred — manual POST /api/admin/curriculum/load)
    tracing::info!("Data loaders initialized");

    chat_engine::config::ensure_db_connection(&db_path);

    // --- Auto-schema ---
    //
    // 🔴 **建表入口只有一处**：上面的 `api_server::db_pool::init(&db_path)`
    //     （`db_pool.rs` 里 `init()` **无条件**调用 `schema::init_database()`）。
    //
    // 🗑 2026-09-29 已删除此处的 `if table_count < 3 { init_database() }` 守卫 ——
    //     它**恒不成立**（`db_pool::init()` 先跑过，`users`/`tokens`/`payment_orders`
    //     必然都已存在 → `table_count` 恒 = 3），是**死逻辑**：
    //       · 实测：空库启动 → 20 张表全建好，但那条 `info!("Schema initialized")` **从不打印**
    //       · 危害：读者（含我本人）会以为**这里**是建表入口 → 改错地方、
    //         甚至据此报出「新表永远建不出来」这种**不存在的问题**
    //
    // 🔑 判据：**「两处实现、其中一处永不执行」是危险结构** → 删掉死的那处，只留一处权威。
    //    ⚠️ 改 schema 请去 `crates/api_server/src/schema.rs`，**不要**在这里加 CREATE/ALTER。
    {
        let conn = api_server::db_pool::get_conn();

        // 老库补列 / 建表（幂等）。⚠️ 只放**本库升级**用；新表定义一律写在 `schema.rs`。
        // 🔴 容错**只放行 `duplicate column` / `already exists`**（真的已应用过）——
        //    不再吞 `no such table` / `no such index`（那会**掩盖真错**：表名/列名/顺序写错都不报）。
        let migrations: &[&str] = &[
            "ALTER TABLE users ADD COLUMN streak_days INTEGER DEFAULT 0",
            "ALTER TABLE users ADD COLUMN last_active_date TEXT",
            "ALTER TABLE users ADD COLUMN display_name TEXT DEFAULT NULL",
            "CREATE TABLE IF NOT EXISTS user_preferences (
                user_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (user_id, key),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE TABLE IF NOT EXISTS tokens (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                token TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
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
            "CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status)",
            "CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status)",
            "CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at)",
            "ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}'",
            // 订阅套餐
            // 🔴 **必须先建表** —— 本表之后有 `ALTER`（once_per_user）与 3 条 `INSERT` 依赖它。
            "CREATE TABLE IF NOT EXISTS subscription_plans (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                duration_days INTEGER,
                price INTEGER NOT NULL,
                max_uses INTEGER,
                used_count INTEGER DEFAULT 0,
                once_per_user INTEGER DEFAULT 0,
                available_from TEXT,
                available_until TEXT,
                sort_order INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 1,
                created_at TEXT NOT NULL
            )",
            // ⚠️ 2026-09-29 修正：这条 `ALTER` **原先排在上面的 `CREATE` 之前** ——
            //    老库若缺 `subscription_plans`（守卫只保证 users/tokens/payment_orders 存在），
            //    它会报 `no such table` 并被下面的容错**静默吞掉**，
            //    靠紧随其后的 `CREATE TABLE IF NOT EXISTS` 兜住。
            //    🔑 这正是「容错吞掉真错」的实例：**顺序本身就是错的，只是被掩盖了**。
            //    收紧容错（不再吞 `no such table`）前必须先把顺序改对，否则启动会直接炸。
            "ALTER TABLE subscription_plans ADD COLUMN once_per_user INTEGER DEFAULT 0",
            // 支付订单
            "CREATE TABLE IF NOT EXISTS payment_orders (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                plan_id TEXT NOT NULL,
                amount INTEGER NOT NULL,
                currency TEXT DEFAULT 'CNY',
                status TEXT DEFAULT 'NOTPAY',
                prepay_id TEXT,
                transaction_id TEXT,
                paid_at TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id)",
            "CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status)",
            // 订阅操作审计
            "CREATE TABLE IF NOT EXISTS subscription_audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                action TEXT NOT NULL,
                operator_id TEXT,
                target_user_id TEXT NOT NULL,
                old_expires TEXT,
                new_expires TEXT NOT NULL,
                amount INTEGER DEFAULT 0,
                order_id TEXT,
                note TEXT,
                created_at TEXT NOT NULL
            )",
            "CREATE INDEX IF NOT EXISTS idx_audit_target ON subscription_audit_log(target_user_id)",
            "CREATE INDEX IF NOT EXISTS idx_audit_created ON subscription_audit_log(created_at)",
            // 初始化套餐（三档默认定价，其他特殊定价走营销活动）
            "INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at) VALUES ('30d', '月度会员', 30, 12000, 0, 1, datetime('now'))",
            "INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at) VALUES ('90d', '季度会员', 90, 35000, 1, 1, datetime('now'))",
            "INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at) VALUES ('365d', '年度会员', 365, 128000, 2, 1, datetime('now'))",
            // 手机号唯一性约束（先清理重复值再建索引）
            "UPDATE users SET phone_hash = NULL WHERE id NOT IN (SELECT MIN(id) FROM users WHERE phone_hash IS NOT NULL AND phone_hash != '' GROUP BY phone_hash)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL",

        ];

        for sql in migrations {
            match conn.execute(sql, []) {
                Ok(_) => {}
                Err(e) => {
                    let err_msg = e.to_string();
                    // ⚠️ 容错**只在真的已经改过**时放行：`duplicate column` / `already exists`。
                    //
                    // 🔴 2026-09-29 收紧：**不再吞 `no such table` / `no such index`**。
                    //    原写法看着无害，实则**掩盖真错** —— 表名/列名写错、语句顺序写错，
                    //    全都会被当成「已应用」静默跳过，只留一行 debug 日志。
                    //    （实例：`ALTER TABLE subscription_plans` 原排在它的 `CREATE` **之前**，
                    //      老库缺该表时报 `no such table` 被吞掉 → 顺序错一直被掩盖。）
                    //    🔑 现在列表里的每条 ALTER 目标表都由**本块之前的 CREATE**（或守卫星的
                    //       users/tokens/payment_orders）保证存在 → `no such table` = **真 bug**，
                    //       必须让启动**立刻失败**（fail fast），而不是带着坏 schema 继续服务。
                    if !err_msg.contains("duplicate column") && !err_msg.contains("already exists") {
                        tracing::error!("Migration failed critically: {} — SQL: {}", err_msg, sql);
                        panic!("Migration failed: {} — SQL: {}", err_msg, sql);
                    }
                    tracing::debug!("Migration skipped (already applied): {}", err_msg);
                }
            }
        }

        // 运行时配置表（debug_trackers / debug_logs 已于 2026-09-29 随旧学习链退役）
        for sql in &[
            "CREATE TABLE IF NOT EXISTS app_config (
                key TEXT PRIMARY KEY, value TEXT NOT NULL,
                description TEXT DEFAULT '', updated_at INTEGER NOT NULL)",
        ] {
            match conn.execute(sql, []) {
                Ok(_) => {}
                Err(e) => {
                    let err_msg = e.to_string();
                    // 🔴 同上：这里只跑 `CREATE TABLE IF NOT EXISTS app_config(...)`（独立表、无外键），
                    //    不可能报 `no such table` → 一并收紧。
                    if !err_msg.contains("duplicate column") && !err_msg.contains("already exists") {
                        tracing::error!("Table creation failed: {} — SQL: {}", err_msg, sql);
                        panic!("Table creation failed: {}", err_msg);
                    }
                }
            }
        }

        // 初始化运行时配置缓存
        if let Err(e) = api_server::app_config_cache::init_cache(&conn) {
            tracing::warn!("app_config cache init: {}", e);
        } else {
            tracing::info!("app_config cache initialized");
        }

        // 调试跟踪器缓存已于 2026-09-29 退役（debug_trackers / debug_logs 表已删）

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
        .layer(cors)
        .layer(axum::extract::DefaultBodyLimit::max(10 * 1024 * 1024)); // 10MB for ASR audio

    let bind_addr = format!("{}:{}", host, port);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await.unwrap();
    tracing::info!("CoEvo ready on http://{}", bind_addr);
    axum::serve(listener, app).await.unwrap();
}
