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
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    deleted_at TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS card_memory (
    card_id TEXT PRIMARY KEY,
    user_card_id TEXT REFERENCES user_cards(id) ON DELETE CASCADE,
    state INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'pending', 'skipped', 'archived')),
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    user_card_id TEXT REFERENCES user_cards(id) ON DELETE CASCADE,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL
        CHECK(verification_type IN ('spelling', 'typing', 'ai_dialogue')),
    verification_result TEXT NOT NULL
        CHECK(verification_result IN ('pass', 'fail')),
    reviewed_at INTEGER NOT NULL,
    details_json TEXT
);
CREATE TABLE IF NOT EXISTS achievements (
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
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_card_memory_user_card ON card_memory(user_card_id);
CREATE INDEX IF NOT EXISTS idx_review_log_user_card ON review_log(user_card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE TABLE IF NOT EXISTS user_plan_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
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
CREATE INDEX IF NOT EXISTS idx_upp_user_plan ON user_plan_progress(user_id, plan_id);
CREATE INDEX IF NOT EXISTS idx_upp_status ON user_plan_progress(plan_id, status);

-- ── V4 Prebuilt Schema ──
CREATE TABLE IF NOT EXISTS prebuilt_plans (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL DEFAULT '',
    domain TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    goal TEXT NOT NULL DEFAULT '',
    plan_content TEXT,
    title TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT '',
    visible INTEGER NOT NULL DEFAULT 1,
    theme_color TEXT NOT NULL DEFAULT '',
    theme_icon TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS prebuilt_stages (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    name TEXT NOT NULL,
    sort_order TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (plan_id) REFERENCES prebuilt_plans(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS prebuilt_tasks (
    id TEXT PRIMARY KEY,
    stage_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    name TEXT NOT NULL,
    task_key TEXT NOT NULL DEFAULT '',
    prompt_mode TEXT NOT NULL DEFAULT '',
    card_ids TEXT NOT NULL DEFAULT '[]',
    dependencies TEXT NOT NULL DEFAULT '[]',
    origin TEXT NOT NULL DEFAULT '',
    sort_order TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (stage_id) REFERENCES prebuilt_stages(id) ON DELETE CASCADE,
    FOREIGN KEY (plan_id) REFERENCES prebuilt_plans(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS prebuilt_cards (
    id TEXT PRIMARY KEY,
    card_type TEXT NOT NULL,
    domain TEXT NOT NULL,
    subject TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    front TEXT NOT NULL DEFAULT '',
    difficulty REAL DEFAULT 0.5,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS prebuilt_science_cards (
    id TEXT PRIMARY KEY,
    definition TEXT NOT NULL DEFAULT '',
    key_elements TEXT NOT NULL DEFAULT '',
    applications TEXT NOT NULL DEFAULT '',
    related_concepts TEXT NOT NULL DEFAULT '',
    formula TEXT NOT NULL DEFAULT '',
    graph TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS prebuilt_language_cards (
    id TEXT PRIMARY KEY,
    pronunciation TEXT NOT NULL DEFAULT '',
    pos TEXT NOT NULL DEFAULT '',
    definitions TEXT NOT NULL DEFAULT '[]',
    related_phrases TEXT NOT NULL DEFAULT '',
    structure_meta TEXT NOT NULL DEFAULT '',
    level TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS prebuilt_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS prebuilt_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS plan_runs (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    prebuilt_plan_id TEXT,
    subject TEXT NOT NULL DEFAULT '',
    domain TEXT NOT NULL,
    grade_band TEXT NOT NULL DEFAULT '',
    goal TEXT NOT NULL DEFAULT '',
    plan_content TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id),
    FOREIGN KEY (prebuilt_plan_id) REFERENCES prebuilt_plans(id)
);
CREATE TABLE IF NOT EXISTS user_cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_run_id TEXT DEFAULT '',
    prebuilt_card_id TEXT,
    domain TEXT NOT NULL,
    front TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    task_key TEXT,
    language TEXT,
    level TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (prebuilt_card_id) REFERENCES prebuilt_cards(id)
);
CREATE TABLE IF NOT EXISTS user_science_cards (
    id TEXT PRIMARY KEY,
    definition TEXT NOT NULL DEFAULT '',
    key_elements TEXT NOT NULL DEFAULT '',
    applications TEXT NOT NULL DEFAULT '',
    related_concepts TEXT NOT NULL DEFAULT '',
    formula TEXT NOT NULL DEFAULT '',
    graph TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS user_language_cards (
    id TEXT PRIMARY KEY,
    pronunciation TEXT NOT NULL DEFAULT '',
    pos TEXT NOT NULL DEFAULT '',
    definitions TEXT NOT NULL DEFAULT '[]',
    related_phrases TEXT NOT NULL DEFAULT '',
    structure_meta TEXT NOT NULL DEFAULT '',
    level TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS user_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS user_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS card_relations (
    id TEXT PRIMARY KEY,
    from_type TEXT NOT NULL,
    from_id TEXT NOT NULL,
    to_type TEXT NOT NULL,
    to_id TEXT NOT NULL,
    relation_type TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    metadata TEXT NOT NULL DEFAULT '{}',
    user_id TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
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
CREATE TABLE IF NOT EXISTS settlement_batches (
    id TEXT PRIMARY KEY,
    batch_no TEXT NOT NULL UNIQUE,
    total_amount INTEGER NOT NULL DEFAULT 0,
    item_count INTEGER NOT NULL DEFAULT 0,
    status TEXT DEFAULT 'pending',
    note TEXT,
    source TEXT DEFAULT 'admin',
    created_at TEXT NOT NULL,
    paid_at TEXT,
    handled_by TEXT,
    FOREIGN KEY (handled_by) REFERENCES admin_users(id)
);
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
    FOREIGN KEY (order_id) REFERENCES payment_orders(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id)
);
CREATE INDEX IF NOT EXISTS idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX IF NOT EXISTS idx_commission_batch ON distribution_commissions(batch_id);
CREATE TABLE IF NOT EXISTS distribution_withdrawals (
    id TEXT PRIMARY KEY,
    earner_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    fee INTEGER DEFAULT 0,
    actual_amount INTEGER,
    status TEXT DEFAULT 'pending',
    note TEXT,
    batch_id TEXT,
    created_at TEXT NOT NULL,
    handled_at TEXT,
    handled_by TEXT,
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id),
    FOREIGN KEY (handled_by) REFERENCES admin_users(id)
);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON distribution_withdrawals(status);
CREATE INDEX IF NOT EXISTS idx_withdrawals_earner ON distribution_withdrawals(earner_id);
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
"#;

/// 管理端表（管理员、订阅审计、监护人、K12题库等）
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
CREATE TABLE IF NOT EXISTS guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,
    assigned_by TEXT,
    assigned_at TEXT NOT NULL,
    is_active INTEGER DEFAULT 1,
    UNIQUE(guardian_admin_id, student_user_id)
);
CREATE TABLE IF NOT EXISTS k12_quiz_bank (
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
);
CREATE TABLE IF NOT EXISTS k12_quiz_attempts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    quiz_id TEXT NOT NULL,
    conversation_id TEXT,
    user_answer TEXT,
    is_correct INTEGER,
    attempted_at TEXT NOT NULL,
    task_name TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_student ON guardian_assignments(student_user_id);
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

-- 调试跟踪器
CREATE TABLE IF NOT EXISTS debug_trackers (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    subject TEXT,
    status TEXT DEFAULT 'active',
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_debug_trackers_user ON debug_trackers(user_id);

-- 调试日志元数据
CREATE TABLE IF NOT EXISTS debug_logs (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    user_id TEXT,
    subject TEXT,
    date TEXT NOT NULL,
    log_file_path TEXT NOT NULL,
    phases TEXT,
    entry_count INTEGER DEFAULT 0,
    file_size_bytes INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_debug_logs_conv ON debug_logs(conversation_id);
CREATE INDEX IF NOT EXISTS idx_debug_logs_date ON debug_logs(date);
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
        "CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
         CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
         CREATE INDEX IF NOT EXISTS idx_user_cards_user_plan ON user_cards(user_id, plan_run_id);
         CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
         CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL;"
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
        // 营销活动海报模板（LLM 生成的含 {变量} 的 SVG 模板）
        "ALTER TABLE marketing_campaigns ADD COLUMN poster_template TEXT DEFAULT NULL",
        // H5 分享页模板（LLM 生成的含 {变量} 的 HTML 模板）
        "ALTER TABLE marketing_campaigns ADD COLUMN h5_template TEXT DEFAULT NULL",
        // H5 分享页自定义 prompt
        "ALTER TABLE marketing_campaigns ADD COLUMN h5_prompt TEXT DEFAULT NULL",
        // 展示位置（JSON 数组，如 ["achievement_tab","review_completion"]）
        "ALTER TABLE marketing_campaigns ADD COLUMN display_positions TEXT DEFAULT '[]'",
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
        "distribution_commissions", "distribution_withdrawals",
        "guardian_assignments",
        "k12_quiz_attempts", "k12_quiz_bank",
        "marketing_campaigns",
        "plan_runs",
        "prebuilt_cards", "prebuilt_humanities_cards", "prebuilt_language_cards",
        "prebuilt_literature_cards", "prebuilt_plans", "prebuilt_science_cards",
        "prebuilt_stages", "prebuilt_tasks",
        "referral_clicks", "reward_fulfillments", "review_log",
        "settlement_batches",
        "subscription_requests", "tokens",
        "user_cards", "user_humanities_cards", "user_language_cards",
        "user_literature_cards", "user_notifications", "user_plan_progress", "user_preferences",
        "user_science_cards", "users",
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