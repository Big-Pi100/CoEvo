//! 统一数据库 Schema — 生产与测试共用同一份定义
//!
//! 包含核心表 + 管理端表，所有 CREATE/ALTER/INDEX 均通过 `init_database()` 一次性执行。

/// 核心数据表（用户、对话、卡片、复习、计划等）
pub const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT DEFAULT NULL,
    real_name TEXT DEFAULT NULL,
    phone TEXT DEFAULT NULL,
    phone_hash TEXT DEFAULT NULL,
    id_number TEXT DEFAULT NULL,
    bind_hash TEXT DEFAULT NULL,
    deleted_at TEXT DEFAULT NULL,
    subscription_expires TEXT DEFAULT NULL,
    referral_code TEXT UNIQUE,
    referred_by TEXT REFERENCES users(id),
    referred_campaign_id TEXT REFERENCES marketing_campaigns(id),
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
-- 🔴 2026-09-29 已退役：`conversations` / `conversation_turns`（对话链）·
--    `card_memory` / `review_log`（后端 FSRS 复习状态）· `achievements`（成就改为端侧计算）
-- ── 已移除：K12 课程体系（2026-09-28 白哥决定 · 整体清退）──
-- 🔴 `user_plan_progress` / `prebuilt_plans` / `prebuilt_stages` / `prebuilt_tasks` / `plan_runs`
--    的建表语句**必须一并移除** —— 否则全新库初始化时会把**空表建回来**。
--    （`init_database` 由 `main.rs` 的守卫触发。🔴 该守卫**已于 2026-09-29 改**：
--      原查 `users`/`user_cards`/`card_memory` —— 后两者随旧学习链退役后守卫会**恒成立**
--      → 每次启动都跑 init。现改查 `users`/`tokens`/`payment_orders`（现役业务表）。）
-- 🔑 判据：**「删掉数据」与「让它不再产生」是两件事** —— 只 DROP TABLE 是治标。
-- 📄 决策与执行记录 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

-- ── 已移除：词卡内容表（`prebuilt_cards` + 4 张域子表）──
-- 🔴 理由（2026-09-28 白哥决定）：**维护两份词库既无意义又易互相污染**。
--    端侧词库已完全独立（app 只读 `assets/word.db`），后端的词卡接口
--    （`/api/cards/*`）**已无现役消费者**（只被死代码 `chat_client` → `pipelines`(K12) 调）。
-- 🔴 **必须与 `user_cards` 的外键一并去掉** —— 实测：`user_cards` 有 4,998 行引用
--    `prebuilt_cards`，直接 `DROP TABLE prebuilt_cards` 会报 `FOREIGN KEY constraint failed`
--    （后端启用 `PRAGMA foreign_keys = ON`，见 `db_pool.rs:29`）。
--    数据层已通过重建 `user_cards` 去掉该外键（见 `scripts/purge_coevo_wordcards.py`）。
-- 🔄 后续（2026-09-29）：`user_cards` **整表已退役**（学习状态迁端侧 `user.db`），
--    故上条「列保留」已不再适用 —— 见下方「已退役：user_cards 一族」。
-- 📄 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

-- 🔴 2026-09-29 已退役：`user_cards` / `user_{science,language,literature,humanities}_cards` /
--    `card_relations` —— 学习状态已整体迁到端侧 `user.db`（`card_review_state` 等）
CREATE TABLE IF NOT EXISTS trial_ip_log (
    id TEXT PRIMARY KEY,
    ip TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_trial_ip_log_ip_created ON trial_ip_log(ip, created_at);
"#;

/// 分销营销表（依赖 admin_users、payment_orders 等管理端表，需要在 ADMIN_SCHEMA_SQL 之后执行）
pub const DISTRIBUTION_SCHEMA_SQL: &str = r#"
-- ── Distribution & Marketing Tables ──
CREATE TABLE IF NOT EXISTS marketing_campaigns (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    campaign_type TEXT DEFAULT 'standard',
    description TEXT,
    status TEXT DEFAULT 'draft',
    rewards TEXT NOT NULL DEFAULT '[]',
    trigger_event TEXT NOT NULL DEFAULT 'registration',
    target_roles TEXT DEFAULT '[]',
    push_trigger TEXT DEFAULT 'manual',
    push_cron TEXT,
    attribution_window INTEGER DEFAULT 30,
    valid_from TEXT,
    valid_until TEXT,
    participant_limit INTEGER,
    per_user_limit INTEGER,
    qr_code_url TEXT,
    created_by TEXT,                          -- "super"（管理密钥）或 admin_users.id
    created_at TEXT NOT NULL,
    updated_by TEXT,                          -- 最后修改者
    updated_at TEXT,
    poster_prompt TEXT,                        -- 自定义海报系统提示（主prompt）
    poster_template TEXT,                      -- LLM 生成的海报 SVG 模板（含 {变量}）
    h5_template TEXT,                          -- LLM 生成的 H5 HTML 模板（含 {变量}）
    h5_prompt TEXT,                            -- 自定义 H5 系统提示
    display_positions TEXT DEFAULT '[]',       -- 展示方式：notification（通知中心）/ popup（弹窗）/ both（两者），默认空='both'
    min_member_count INTEGER DEFAULT 1,        -- party=all 时的最小成团人数，默认 1 人人即发
    FOREIGN KEY (created_by) REFERENCES admin_users(id),
    FOREIGN KEY (updated_by) REFERENCES admin_users(id)
);
CREATE TABLE IF NOT EXISTS referral_clicks (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    referrer_id TEXT NOT NULL,
    clicker_anonymous_id TEXT,
    share_channel TEXT,
    landed_page TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (referrer_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_clicks_campaign ON referral_clicks(campaign_id);
CREATE INDEX IF NOT EXISTS idx_clicks_referrer ON referral_clicks(referrer_id);
CREATE INDEX IF NOT EXISTS idx_clicks_anonymous ON referral_clicks(clicker_anonymous_id);
-- 佣金表（只 INSERT 不修改，所有资金操作通过 distribution_expenses 追溯）
CREATE TABLE IF NOT EXISTS distribution_commissions (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    earner_id TEXT NOT NULL,
    buyer_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    order_amount INTEGER NOT NULL,
    rate_applied REAL NOT NULL,
    amount INTEGER NOT NULL,
    level INTEGER DEFAULT 1,
    status TEXT DEFAULT 'locked',
    batch_id TEXT,
    batch_settled_at TEXT,
    paid_at TEXT,
    unlocked_at TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (buyer_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id)
);
CREATE INDEX IF NOT EXISTS idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX IF NOT EXISTS idx_commission_batch ON distribution_commissions(batch_id);
-- 支出记录表（所有资金操作只 INSERT，永不修改原始佣金记录）
-- expense_type: 'subscription' | 'withdrawal'
-- status:
--   subscription: pending → confirmed
--   withdrawal:   pending → confirmed(已审批) → paid(已打款)
CREATE TABLE IF NOT EXISTS distribution_expenses (
    id TEXT PRIMARY KEY,
    earner_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    expense_type TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    fee INTEGER DEFAULT 0,
    actual_amount INTEGER,
    ref_commission_id TEXT,
    handled_by TEXT,
    handled_at TEXT,
    batch_no TEXT,
    batch_paid_at TEXT,
    note TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (earner_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_expenses_earner ON distribution_expenses(earner_id, status);
CREATE INDEX IF NOT EXISTS idx_expenses_batch_no ON distribution_expenses(batch_no);

-- 用户净可用余额视图（统一公式，避免多处重复 SQL）
CREATE VIEW IF NOT EXISTS v_user_available_balance AS
SELECT dc.earner_id,
       COALESCE(SUM(dc.amount), 0)
       - COALESCE((
           SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses
           WHERE earner_id = dc.earner_id AND expense_type = 'withdrawal' AND status NOT IN ('cancelled')
       ), 0)
       - COALESCE((
           SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses
           WHERE ref_commission_id IN (
               SELECT id FROM distribution_commissions
               WHERE earner_id = dc.earner_id AND status = 'available'
           ) AND expense_type = 'subscription' AND status = 'confirmed'
       ), 0) AS available_balance
FROM distribution_commissions dc
WHERE dc.status = 'available'
GROUP BY dc.earner_id;

CREATE TABLE IF NOT EXISTS user_notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    notification_type TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    read INTEGER DEFAULT 0,
    action_url TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON user_notifications(user_id, read, created_at);
CREATE TABLE IF NOT EXISTS reward_fulfillments (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    referral_click_id TEXT,
    order_id TEXT,
    user_id TEXT NOT NULL,
    party TEXT NOT NULL,
    reward_type TEXT NOT NULL,
    reward_value TEXT NOT NULL,
    trigger_event TEXT NOT NULL,
    level INTEGER DEFAULT 1,
    status TEXT DEFAULT 'pending',
    fulfilled_at TEXT,
    error_msg TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id),
    FOREIGN KEY (referral_click_id) REFERENCES referral_clicks(id)
);
CREATE INDEX IF NOT EXISTS idx_fulfillment_campaign ON reward_fulfillments(campaign_id, trigger_event);
CREATE INDEX IF NOT EXISTS idx_fulfillment_conversion ON reward_fulfillments(referral_click_id);
CREATE INDEX IF NOT EXISTS idx_fulfillment_order ON reward_fulfillments(order_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_fulfillment_unique ON reward_fulfillments(campaign_id, user_id, trigger_event, party, reward_type, order_id);
-- ── 拼团/砍价活动成员表 ──
CREATE TABLE IF NOT EXISTS campaign_members (
    campaign_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    role TEXT DEFAULT 'member',
    created_at TEXT NOT NULL,
    PRIMARY KEY (campaign_id, user_id),
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_campaign_members_campaign ON campaign_members(campaign_id);
CREATE INDEX IF NOT EXISTS idx_campaign_members_user ON campaign_members(user_id);
"#;

/// 管理端表（管理员、订阅审计、监护人等）
pub const ADMIN_SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS admin_users (
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
);
CREATE TABLE IF NOT EXISTS subscription_requests (
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
);
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);
-- ── 已移除：`guardian_assignments`（家长-学生绑定 · K12 遗留）──
-- 随 K12 体系一并清退（2026-09-28）。索引 `idx_guardian_assignments_*` 同删。
-- 📄 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`

CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at);
ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}';

-- 订阅套餐表
CREATE TABLE IF NOT EXISTS subscription_plans (
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
);

-- 支付订单表
CREATE TABLE IF NOT EXISTS payment_orders (
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
);
CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status);

-- 订阅操作审计表
CREATE TABLE IF NOT EXISTS subscription_audit_log (
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
);
CREATE INDEX IF NOT EXISTS idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON subscription_audit_log(created_at);

-- 初始化套餐数据（三档默认定价，其他特殊定价走营销活动）
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('30d', '月度会员', 30, 12000, 0, 1, datetime('now'));
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('90d', '季度会员', 90, 35000, 1, 1, datetime('now'));
INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('365d', '年度会员', 365, 128000, 2, 1, datetime('now'));

-- 运行时配置表
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT DEFAULT '',
    updated_at INTEGER NOT NULL
);

-- 🔴 2026-09-29 已退役：`debug_trackers` / `debug_logs`（只服务 admin 调试面板）
"#;

/// 用户偏好表（部分测试创建，统一放在此处）
pub const USER_PREFERENCES_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id TEXT NOT NULL, key TEXT NOT NULL,
    value TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

/// 初始化完整数据库 schema（核心表 + 管理表 + 偏好表 + 额外索引）
pub fn init_database(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute_batch(SCHEMA_SQL)
        .map_err(|e| format!("core schema: {}", e))?;
    // ADMIN_SCHEMA_SQL 可能包含已在迁移中存在的列（如 permissions）
    // 此时 IF NOT EXISTS 仍可接受，捕获 duplicate column 错误
    match conn.execute_batch(ADMIN_SCHEMA_SQL) {
        Ok(_) => {}
        Err(e) => {
            let msg = e.to_string();
            if !msg.contains("duplicate column") {
                return Err(format!("admin schema: {}", msg));
            }
        }
    }
    conn.execute_batch(DISTRIBUTION_SCHEMA_SQL)
        .map_err(|e| format!("distribution schema: {}", e))?;
    conn.execute_batch(USER_PREFERENCES_SQL)
        .map_err(|e| format!("preferences table: {}", e))?;
    // 额外索引（部分核心索引已在 SCHEMA_SQL 中创建，这里补充交叉表索引）
    conn.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL;"
    ).map_err(|e| format!("extra indexes: {}", e))?;

    // ── 渐进式迁移 ──
    run_migrations_inner(conn)?;

    // ── 初始化默认数据 ──
    // 管理密钥认证（X-Admin-Key）返回的 admin_id="super" 需要存在于 admin_users 表中
    // 以满足 marketing_campaigns.created_by 等字段的 FK 约束
    let _ = conn.execute(
        "INSERT OR IGNORE INTO admin_users (id, username, password_hash, role, status, created_at) VALUES ('super', 'super', '', 'super', 'active', datetime('now'))",
        [],
    );

    Ok(())
}

/// 仅运行渐进式迁移（不重建表）。
/// 适用于已有生产 DB 的测试场景。
pub fn run_migrations(conn: &rusqlite::Connection) -> Result<(), String> {
    run_migrations_inner(conn)
}

fn run_migrations_inner(conn: &rusqlite::Connection) -> Result<(), String> {
    let migrations: &[&str] = &[
        "ALTER TABLE users ADD COLUMN phone_hash TEXT DEFAULT NULL",
        "ALTER TABLE card_memory ADD COLUMN status TEXT NOT NULL DEFAULT 'active'",
        "ALTER TABLE user_cards ADD COLUMN language TEXT DEFAULT NULL",
        "ALTER TABLE user_cards ADD COLUMN level TEXT DEFAULT NULL",
        "ALTER TABLE prebuilt_plans ADD COLUMN title TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE prebuilt_plans ADD COLUMN author TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE prebuilt_plans ADD COLUMN display_name TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE prebuilt_plans ADD COLUMN visible INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE prebuilt_plans ADD COLUMN theme_color TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE prebuilt_plans ADD COLUMN theme_icon TEXT NOT NULL DEFAULT ''",
        // 分销模块新字段（已有数据库升级）
        "ALTER TABLE users ADD COLUMN subscription_expires TEXT DEFAULT NULL",
        "ALTER TABLE users ADD COLUMN referral_code TEXT",
        "ALTER TABLE users ADD COLUMN referred_by TEXT",
        "ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}'",
        // 退款支持字段
        "ALTER TABLE payment_orders ADD COLUMN refund_reason TEXT DEFAULT NULL",
        "ALTER TABLE payment_orders ADD COLUMN refund_id TEXT DEFAULT NULL",
        // 营销活动自定义海报系统提示
        "ALTER TABLE marketing_campaigns ADD COLUMN poster_prompt TEXT DEFAULT NULL",
        // users 表增加 referred_campaign_id：追踪注册来源活动
        "ALTER TABLE users ADD COLUMN referred_campaign_id TEXT DEFAULT NULL",
        // 唯一索引加入 order_id：同一用户不同订单可获多次佣金，登记注册只触发一次
        "DROP INDEX IF EXISTS idx_fulfillment_unique",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_fulfillment_unique ON reward_fulfillments(campaign_id, user_id, trigger_event, party, reward_type, order_id)",
        // 活动最小成团人数
        "ALTER TABLE marketing_campaigns ADD COLUMN min_member_count INTEGER DEFAULT 1",
        // 🔴 2026-09-29 已退役：defer_queue（V5/V6）—— 复习推迟调度改在端侧
    ];
    for sql in migrations {
        match conn.execute(sql, []) {
            Ok(_) => {}
            Err(e) => {
                let err_msg = e.to_string();
                if !err_msg.contains("duplicate column") && !err_msg.contains("already exists") && !err_msg.contains("no such table") {
                    return Err(format!("migration failed: {} — SQL: {}", err_msg, sql));
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    const EXPECTED_NEW_TABLES: &[&str] = &[
        "achievements", "admin_audit_log", "admin_users",
        "subscription_plans", "payment_orders", "subscription_audit_log",
        "card_memory", "card_relations",
        "conversation_turns", "conversations",
        "distribution_commissions", "distribution_expenses",
        "guardian_assignments",
        "marketing_campaigns",
        "plan_runs",
        "prebuilt_cards", "prebuilt_humanities_cards", "prebuilt_language_cards",
        "prebuilt_literature_cards", "prebuilt_plans", "prebuilt_science_cards",
        "prebuilt_stages", "prebuilt_tasks",
        "referral_clicks", "reward_fulfillments", "review_log",
        "subscription_requests", "tokens",
        "trial_ip_log",
        "user_cards", "user_humanities_cards", "user_language_cards",
        "user_literature_cards", "user_notifications", "user_plan_progress", "user_preferences",
        "user_science_cards", "users",
        "defer_queue",
    ];

    const FORBIDDEN_OLD_TABLES: &[&str] = &["cards", "conversation_plans", "learning_plans"];

    /// 验证完整 init_database() 后所有新表存在、旧表已清除
    #[test]
    fn test_full_schema_all_tables_present() {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        let mut stmt = conn.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").unwrap();
        let actual: Vec<String> = stmt.query_map([], |row| row.get(0)).unwrap()
            .filter_map(|r| r.ok())
            .collect();

        for tbl in EXPECTED_NEW_TABLES {
            assert!(actual.contains(&tbl.to_string()), "新表 {} 不存在", tbl);
        }

        for tbl in FORBIDDEN_OLD_TABLES {
            assert!(!actual.contains(&tbl.to_string()), "旧表 {} 仍然存在", tbl);
        }

        assert!(actual.len() >= 30, "表数量不足: {} < 30", actual.len());
    }

    /// 验证核心新表的关键列结构
    #[test]
    fn test_core_table_columns() {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        // user_cards: 必须无 back / source_sentence
        let cols = table_columns(&conn, "user_cards");
        assert!(cols.contains(&"plan_run_id".to_string()), "user_cards 缺 plan_run_id");
        assert!(cols.contains(&"prebuilt_card_id".to_string()), "user_cards 缺 prebuilt_card_id");
        assert!(cols.contains(&"front".to_string()), "user_cards 缺 front");
        assert!(!cols.contains(&"back".to_string()), "user_cards 不应有 back");
        assert!(!cols.contains(&"source_sentence".to_string()), "user_cards 不应有 source_sentence");

        // plan_runs: 必须有 domain
        let cols = table_columns(&conn, "plan_runs");
        assert!(cols.contains(&"domain".to_string()), "plan_runs 缺 domain");

        // card_memory: 必须含 user_card_id
        let cols = table_columns(&conn, "card_memory");
        assert!(cols.contains(&"user_card_id".to_string()), "card_memory 缺 user_card_id");

        // card_relations: 必须含 from_type / to_type / user_id
        let cols = table_columns(&conn, "card_relations");
        assert!(cols.contains(&"from_type".to_string()), "card_relations 缺 from_type");
        assert!(cols.contains(&"to_type".to_string()), "card_relations 缺 to_type");
        assert!(cols.contains(&"user_id".to_string()), "card_relations 缺 user_id");

        // prebuilt_plans: 必须含新增字段
        let cols = table_columns(&conn, "prebuilt_plans");
        assert!(cols.contains(&"title".to_string()), "prebuilt_plans 缺 title");
        assert!(cols.contains(&"author".to_string()), "prebuilt_plans 缺 author");
        assert!(cols.contains(&"display_name".to_string()), "prebuilt_plans 缺 display_name");
        assert!(cols.contains(&"visible".to_string()), "prebuilt_plans 缺 visible");
        assert!(cols.contains(&"theme_color".to_string()), "prebuilt_plans 缺 theme_color");
        assert!(cols.contains(&"theme_icon".to_string()), "prebuilt_plans 缺 theme_icon");

        // review_log: 必须含 user_card_id
        let cols = table_columns(&conn, "review_log");
        assert!(cols.contains(&"user_card_id".to_string()), "review_log 缺 user_card_id");
    }

    fn table_columns(conn: &Connection, table: &str) -> Vec<String> {
        let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", table)).unwrap();
        stmt.query_map([], |row| row.get::<_, String>(1)).unwrap()
            .filter_map(|r| r.ok())
            .collect()
    }
}