-- CoEvo 数据库 Schema V4
-- 自动生成自 crates/api_server/src/schema.rs
-- 同步日期: 2026-06-18
-- 以下 DDL 应与 schema.rs 的 SCHEMA_SQL + ADMIN_SCHEMA_SQL + USER_PREFERENCES_SQL + 额外索引 + 迁移保持完全一致

-- ═══════════════════════════════════════════════
-- 核心数据表（用户、对话、卡片、复习、计划等）
-- ═══════════════════════════════════════════════

-- ── 用户身份（学生/家长/老师 统一存储） ──
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
    created_at TEXT NOT NULL
);

-- ── 认证令牌 ──
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ── 会话 ──
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    deleted_at TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ── 对话轮次 ──
CREATE TABLE IF NOT EXISTS conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);

-- ── FSRS 复习状态 ──
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

-- ── 复习日志 ──
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

-- ── 成就 ──
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

-- ── 任务进度 ──
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

-- ═══════════════════════════════════════════════
-- V4 Prebuilt Schema（预置课程数据）
-- ═══════════════════════════════════════════════

-- ── 预置计划模板 ──
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

-- ── 预置阶段 ──
CREATE TABLE IF NOT EXISTS prebuilt_stages (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    name TEXT NOT NULL,
    sort_order TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (plan_id) REFERENCES prebuilt_plans(id) ON DELETE CASCADE
);

-- ── 预置任务 ──
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

-- ── 卡片内容注册表（全局预置） ──
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

-- ── 理科子表 ──
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

-- ── 语言子表 ──
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

-- ── 文章子表 ──
CREATE TABLE IF NOT EXISTS prebuilt_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);

-- ── 文科子表（节点即卡片） ──
CREATE TABLE IF NOT EXISTS prebuilt_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);

-- ── 计划运行实例（替代旧 conversation_plans） ──
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

-- ── 用户卡片实例（替代旧 cards） ──
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

-- ── 用户理科子表（CP1 自创卡内容） ──
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

-- ── 用户语言子表 ──
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

-- ── 用户文章子表 ──
CREATE TABLE IF NOT EXISTS user_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);

-- ── 用户文科子表 ──
CREATE TABLE IF NOT EXISTS user_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);

-- ── 通用卡片关系图 ──
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

-- ═══════════════════════════════════════════════
-- 用户偏好表
-- ═══════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ═══════════════════════════════════════════════
-- 管理端表（管理员、订阅支付、监护人、K12题库等）
-- ═══════════════════════════════════════════════

-- ── 后台管理员 ──
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

-- ── 订阅套餐表 ──
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

-- ── 支付订单表 ──
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

-- ── 订阅操作审计表 ──
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

-- ── 订阅申请（管理员代操作） ──
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

-- ── 监护人/老师 绑定关系 ──
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

-- ── 管理操作日志 ──
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);

-- ── K12 题库 ──
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

-- ── K12 答题记录 ──
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

-- ── 运行时配置表 ──
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT DEFAULT '',
    updated_at INTEGER NOT NULL
);

-- ── 调试跟踪器 ──
CREATE TABLE IF NOT EXISTS debug_trackers (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    subject TEXT,
    status TEXT DEFAULT 'active',
    created_at INTEGER NOT NULL
);

-- ── 调试日志元数据 ──
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

-- ═══════════════════════════════════════════════
-- 索引
-- ═══════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_card_memory_user_card ON card_memory(user_card_id);
CREATE INDEX IF NOT EXISTS idx_review_log_user_card ON review_log(user_card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_cards_user_plan ON user_cards(user_id, plan_run_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_upp_user_plan ON user_plan_progress(user_id, plan_id);
CREATE INDEX IF NOT EXISTS idx_upp_status ON user_plan_progress(plan_id, status);

CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_student ON guardian_assignments(student_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at);
CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status);
CREATE INDEX IF NOT EXISTS idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON subscription_audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_debug_trackers_user ON debug_trackers(user_id);
CREATE INDEX IF NOT EXISTS idx_debug_logs_conv ON debug_logs(conversation_id);
CREATE INDEX IF NOT EXISTS idx_debug_logs_date ON debug_logs(date);

-- ═══════════════════════════════════════════════
-- 渐进式迁移（ALTER TABLE）
-- 仅 admin_users.permissions 是真正的迁移（CREATE TABLE 中未包含此字段）。
-- 其余 ALTER TABLE 已在 CREATE TABLE DDL 中直接定义，仅用于已有数据库升级。
-- 如需在已有 DB 上运行迁移，请参考 schema.rs 的 run_migrations_inner()。

ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}';
-- 初始化套餐数据
-- ═══════════════════════════════════════════════

INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, once_per_user, sort_order, is_active, created_at)
VALUES ('discount_10', '新手体验', 3, 10, 1, 0, 1, datetime('now'));

INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('30d', '月度会员', 30, 20000, 1, 1, datetime('now'));

INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('365d', '年度会员', 365, 128000, 2, 1, datetime('now'));

INSERT OR IGNORE INTO subscription_plans (id, name, duration_days, price, max_uses, used_count, once_per_user, sort_order, is_active, created_at)
VALUES ('lifetime', '终身会员', 3650, 128000, 100, 0, 1, 3, 1, datetime('now'));
