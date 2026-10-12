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
    let avatar_dir =
        std::env::var("COEVO_AVATAR_DIR").unwrap_or_else(|_| "data/avatars".to_string());
    let prompts_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    let wordbank_path =
        std::env::var("COEVO_WORDBANK_PATH").unwrap_or_else(|_| "cefr_catalog.json".to_string());
    let host = std::env::var("COEVO_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port: u16 = std::env::var("COEVO_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8080);

    // Initialize DB
    api_server::db_pool::init(&db_path).expect("Failed to init DB pool");
    tracing::info!("DB: {}", db_path);

    // 启动后台定时任务（佣金解锁 + NOTPAY 关单，每 5 分钟执行）
    api_server::maintenance::start_scheduler(&db_path);
    tracing::info!("Maintenance scheduler started (interval: 5 min)");

    // 🆕 内容抓取（信息流数据源 · 2026-09-29 白哥定「先做后端」）
    // 🔑 自带 runtime 的独立线程（见 `content_fetch::start_fetch_scheduler` 的说明）——
    //    不依赖「调用方恰好处于 tokio runtime 上下文」这个隐含前提。
    // 关掉：`COEVO_FETCH_INTERVAL_SECS=0`
    api_server::content_fetch::start_fetch_scheduler();

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
            // 🆕 2026-10-05 `password_reset`（找回密码的验证码表）。
            // 🔴 **必须与 `schema.rs` 里的那份同时存在**（判据：改 schema 必查两处）：
            //    `schema.rs` 管**新库**，这里管**老库升级**。只改一处的结果是
            //    「新装的有表、已上线的库没有」—— 而生产库正是后者。
            //    定义以 `schema.rs` 为准（含完整注释），此处保持逐字一致。
            "CREATE TABLE IF NOT EXISTS password_reset (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_password_reset_user ON password_reset(user_id, created_at)",
            // 🆕 2026-10-07 `email_change`（修改邮箱的验证码表）。
            // 🔴 **必须与 `schema.rs` 里的那份同时存在**（同 `password_reset` 的理由）：
            //    `schema.rs` 管**新库**，这里管**老库升级** —— 只改一处 =
            //    「新装的有表、已上线的库没有」，而生产库正是后者。
            // 📌 **刻意与 `password_reset` 分表**（不是重复建设）：
            //    验证对象不同（本表证「**新**邮箱是你的」）+ 用途必须隔离
            //    （共用一张 ⇒ 「找回密码」的码可升级成「改邮箱」的凭据）。详见 `schema.rs`。
            "CREATE TABLE IF NOT EXISTS email_change (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                new_email TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_email_change_user ON email_change(user_id, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_email_change_new_email ON email_change(new_email, created_at)",
            // 🆕 2026-10-07 Apple 登录的稳定标识（`sub`）。
            // 🔴 与 `schema.rs` 的 `CREATE TABLE users` 成对：那里管新库，这里管老库。
            "ALTER TABLE users ADD COLUMN apple_user_id TEXT DEFAULT NULL",
            // 唯一索引也要在老库上补（`ALTER` 只加列，不会带来索引）。
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_user_id ON users(apple_user_id) WHERE apple_user_id IS NOT NULL",
            // 🔴 2026-09-29 已删 4 条：`real_name` · `phone` · `id_number` · `bind_hash`
            //
            // 🔑 **为什么必须删**（否则本轮所有后端改动都会被静默撤销）：
            //    这段代码跑在 `init_database`（含 `schema.rs` 的删列迁移）**之后** ——
            //    留着它 = 前脚刚删掉 5 列，后脚又把其中 4 列**加回来**。
            //    而代码已不再写这 4 列 → 它们会变成「表里有、永远为 NULL」的幽灵列：
            //    既违背「改用邮箱注册」这个决策，又会在后续开发中被误认为「还能用」。
            //
            //    📄 同族判据：「删数据」**≠**「让它不再产生」—— 建表语句与**迁移列表**
            //       都要一起清（这正是本轮踩到的第二处「还有别的地方在产生它」）。
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
            // 支付订单（🔴 2026-10-04：微信 → Apple IAP，删 `prepay_id`）
            // ⚠️ 这里是**第二份**建表定义（第一份在 `api_server/src/schema.rs` 的
            //    `SCHEMA_SQL`）。主初始化路径是 `schema::init_database()`（由
            //    `db_pool.rs` 无条件调用）；本列表是**其后的补充迁移**。
            //    ⇒ 改 schema 必须**两处都改**，否则新库/老库行为不一致。
            //    ⚠️ 已存在的库不受本 CREATE 影响（`IF NOT EXISTS` 见到表就跳过）——
            //       删列由 `schema.rs` 的 `drop_column_if_exists` 负责。
            "CREATE TABLE IF NOT EXISTS payment_orders (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                plan_id TEXT NOT NULL,
                amount INTEGER NOT NULL,
                currency TEXT DEFAULT 'CNY',
                status TEXT DEFAULT 'NOTPAY',
                transaction_id TEXT,
                paid_at TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id)",
            "CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status)",
            // 🆕 Apple IAP 交易明细（2026-10-04）
            // 🔑 `original_transaction_id`：同一订阅的所有续期共享它 ⇒ 恢复购买靠它；
            //    `transaction_id` 每期续费会变，**不能**用它标识「同一个订阅」。
            "CREATE TABLE IF NOT EXISTS iap_transactions (
                transaction_id          TEXT PRIMARY KEY,
                original_transaction_id TEXT NOT NULL,
                user_id                 TEXT,
                product_id              TEXT NOT NULL,
                purchase_date           INTEGER,
                expires_date            INTEGER,
                environment             TEXT,
                app_account_token       TEXT,
                raw_payload             TEXT,
                created_at              TEXT NOT NULL,
                updated_at              TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_iap_original ON iap_transactions(original_transaction_id)",
            "CREATE INDEX IF NOT EXISTS idx_iap_user ON iap_transactions(user_id)",
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
            // 初始化订阅产品（🔴 2026-10-04：微信档位 → Apple IAP 自动续期订阅）
            // ⚠️ 价格权威在 **App Store Connect**，本表 `price` 仅作离线展示兜底 /
            //    分销算佣金的「原价」参照。若与 ASC 不一致，以 ASC 为准。
            // 🔑 用 `INSERT OR IGNORE`：管理端可改套餐（`plans_handlers`），
            //    无条件 UPDATE 会**覆盖管理员改动**。改价走 ASC，不依赖本 seed。
            // 🔑 id 直接用 Apple Product ID，省掉「本地 id ↔ productId」映射层。
            "INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at) VALUES ('com.coevo.coevoApp.pro.monthly', '记忆笔记 专业版 · 月度', 30, 600, 0, 1, datetime('now'))",
            "INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at) VALUES ('com.coevo.coevoApp.pro.yearly', '记忆笔记 专业版 · 年度', 365, 5800, 1, 1, datetime('now'))",
            // 🔴 2026-10-11 补：**老库的名字要单独 UPDATE 一次**。
            //    上面两条是 `INSERT OR IGNORE` ⇒ 对**已存在的行是空操作**
            //    ⇒ 老库的 `name` 会**永久停在改名前的旧值**（2026-10-11 之前线上就是这种）。
            //    📌 判据：**配置类 seed 若是唯一权威，不能只靠 `OR IGNORE`/`DO NOTHING`**
            //       —— 必须配一条 `UPDATE ... WHERE 有变化`，否则老库永远漂移。
            //    （`WHERE name <> 新值` 让它在已更新后成为 0 行影响的空操作 ⇒ 幂等。）
            // 🔴 2026-10-12：再次改名（产品名 `记忆之书` → **`记忆笔记`**，ICP 备案要求）。
            //    ⇒ 上面两条 INSERT 与下面两条 UPDATE 的 `name` 串**同时**改成新值；
            //      靠这条 UPDATE 把**已部署的老库**从「记忆之书 专业版 · *」刷成新名。
            "UPDATE subscription_plans SET name = '记忆笔记 专业版 · 月度' WHERE id = 'com.coevo.coevoApp.pro.monthly' AND name <> '记忆笔记 专业版 · 月度'",
            "UPDATE subscription_plans SET name = '记忆笔记 专业版 · 年度' WHERE id = 'com.coevo.coevoApp.pro.yearly' AND name <> '记忆笔记 专业版 · 年度'",
            // 🔴 2026-10-11 同样补：**价格**在老库也要 UPDATE 一次。
            //    理由同上（`INSERT OR IGNORE` 对已存在的行是空操作）。
            //    ⚠️ 与上面那条注释（「无条件 UPDATE 会覆盖管理员改动」）的取舍：
            //       这里**不是**无条件 —— 带 `WHERE price <> 新值`，
            //       只有与目标值不一致时才写（已一致 ⇒ 0 行受影响 ⇒ 幂等）。
            //       之所以要写：本表的 `price` 被 `iap_handlers::fallback_price_fen`
            //       当作**订单金额**用（Apple 交易里没有价时），
            //       停在旧值会让 `payment_orders` **记错金额**（且不报错）。
            //    📌 权威仍是 ASC；本表是它的镜像 ⇒ 必须跟着走。
            //    ⚠️ 若将来真的用管理端改价，这条会在下次重启时改回来（届时删掉它）。
            "UPDATE subscription_plans SET price = 600 WHERE id = 'com.coevo.coevoApp.pro.monthly' AND price <> 600",
            "UPDATE subscription_plans SET price = 5800 WHERE id = 'com.coevo.coevoApp.pro.yearly' AND price <> 5800",
            // 🔴 微信「买断 N 天」档位**下架**（不是删除）——
            //    `distribution_handler.rs` 会按 plan_id 查 price 算佣金原价，删行会断链。
            //    幂等：已下架的档位再跑一次 `is_active` 已是 0 ⇒ 0 行受影响。
            "UPDATE subscription_plans SET is_active = 0 WHERE id IN ('30d', '90d', '365d') AND is_active = 1",
            // 🔴 2026-10-04：删 `payment_orders.prepay_id`（微信专有）由
            //    `api_server::schema::init_database` 的 `drop_column_if_exists` 负责 ——
            //    它跑在本列表**之前**，故此处不重复。
            // 🔴 2026-09-29 已删两条（`UPDATE ... phone_hash` 去重 + `idx_users_phone_hash`）：
            //    `phone_hash` 列已移除。留着它们会在**启动时直接报 `no such column: phone_hash`**
            //    → 服务起不来。（这段的容错只放行 `duplicate column` / `already exists`，
            //    所以它会**炸出来**而不是被吞 —— 这比静默更好。）
            //
            // 🆕 2026-10-11 `sync_highlight.translation` —— 划线卡的中文译文（复习提示之一）。
            // 🔴 **必须与 `schema.rs` 那份同时存在**（同 `password_reset` 的理由）：
            //    `schema.rs` 管**新库**，这里管**老库升级** —— 而生产库正是后者。
            //    顺序安全：`sync_highlight` 由 `schema::init_database()` 无条件建出
            //    （它跑在本列表**之前**）⇒ 此处 ALTER 时表必定已存在。
            //    ⚠️ 服务端**没有** `duplicate column` 之外的容错 ⇒ 列名写错会**炸出来**，
            //       不会静默（这正是我们要的）。
            "ALTER TABLE sync_highlight ADD COLUMN translation TEXT",
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
                    if !err_msg.contains("duplicate column") && !err_msg.contains("already exists")
                    {
                        tracing::error!("Migration failed critically: {} — SQL: {}", err_msg, sql);
                        panic!("Migration failed: {} — SQL: {}", err_msg, sql);
                    }
                    tracing::debug!("Migration skipped (already applied): {}", err_msg);
                }
            }
        }

        // 运行时配置表（debug_trackers / debug_logs 已于 2026-09-29 随旧学习链退役）
        for sql in &["CREATE TABLE IF NOT EXISTS app_config (
                key TEXT PRIMARY KEY, value TEXT NOT NULL,
                description TEXT DEFAULT '', updated_at INTEGER NOT NULL)"]
        {
            match conn.execute(sql, []) {
                Ok(_) => {}
                Err(e) => {
                    let err_msg = e.to_string();
                    // 🔴 同上：这里只跑 `CREATE TABLE IF NOT EXISTS app_config(...)`（独立表、无外键），
                    //    不可能报 `no such table` → 一并收紧。
                    if !err_msg.contains("duplicate column") && !err_msg.contains("already exists")
                    {
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
    use tower_http::cors::{Any, CorsLayer};
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
