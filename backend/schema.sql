-- CoEvo 数据库 Schema V4
-- 基于 prebuilt-schema-refactor.md 文档 §3 节
-- 所有主键/外键统一 UUID v4
-- 以下 DDL 应与 crates/api_server/src/schema.rs 保持完全一致
-- 同步日期: 2026-06-12

-- ── 用户身份（学生/家长/老师 统一存储） ──
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT,
    real_name TEXT,
    phone TEXT,
    phone_hash TEXT,
    id_number TEXT,
    bind_hash TEXT,
    deleted_at TEXT,
    created_at TEXT NOT NULL
);

-- ── 后台管理员 ──
CREATE TABLE IF NOT EXISTS admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    role TEXT NOT NULL DEFAULT 'admin'
        CHECK(role IN ('admin','guardian','super_admin','sub_admin')),
    real_name TEXT,
    phone TEXT,
    id_number TEXT,
    guardian_declaration TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL
);
ALTER TABLE admin_users ADD COLUMN permissions TEXT DEFAULT '{}';

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

-- ── 卡片内容注册表（全局预置，启动时从 JSON 导入） ──
CREATE TABLE IF NOT EXISTS prebuilt_cards (
    id TEXT PRIMARY KEY,
    card_type TEXT NOT NULL,
    domain TEXT NOT NULL,             -- ENUM: science/language/literature/humanities
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

-- ── 用户卡片实例（替代旧 cards） ──
CREATE TABLE IF NOT EXISTS user_cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_run_id TEXT NOT NULL,
    prebuilt_card_id TEXT,             -- NULL = CP1 自定义卡
    domain TEXT NOT NULL,              -- ENUM: science/language/literature/humanities
    front TEXT,                        -- NULL = 引用 prebuilt；非 NULL = CP1 自定义
    status TEXT NOT NULL DEFAULT 'active',
    task_key TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (plan_run_id) REFERENCES plan_runs(id),
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
    from_type TEXT NOT NULL,           -- 'prebuilt' | 'user'
    from_id TEXT NOT NULL,             -- prebuilt_cards.id 或 user_cards.id
    to_type TEXT NOT NULL,             -- 'prebuilt' | 'user'
    to_id TEXT NOT NULL,               -- prebuilt_cards.id 或 user_cards.id
    relation_type TEXT NOT NULL,       -- prerequisite|related|part_of|example_of|contradicts
    description TEXT NOT NULL DEFAULT '',
    metadata TEXT NOT NULL DEFAULT '{}',
    user_id TEXT,                      -- NULL = 全局预置；非 NULL = 用户私有
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

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

-- ── 计划运行实例（替代旧 conversation_plans） ──
CREATE TABLE IF NOT EXISTS plan_runs (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    prebuilt_plan_id TEXT,
    subject TEXT NOT NULL DEFAULT '',
    domain TEXT NOT NULL,              -- ENUM: science/language/literature/humanities
    grade_band TEXT NOT NULL DEFAULT '',
    goal TEXT NOT NULL DEFAULT '',
    plan_content TEXT,                 -- JSON: {stages: [...], completed_concepts: [...]}
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id),
    FOREIGN KEY (prebuilt_plan_id) REFERENCES prebuilt_plans(id)
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
    achievement_type TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    earned_at TEXT NOT NULL,
    details TEXT DEFAULT '{}',
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
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

-- ── 用户偏好 ──
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ── 监护人/老师 绑定关系 ──
CREATE TABLE IF NOT EXISTS guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,
    relationship TEXT DEFAULT 'parent',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    FOREIGN KEY (guardian_admin_id) REFERENCES admin_users(id),
    FOREIGN KEY (student_user_id) REFERENCES users(id)
);

-- ── 订阅请求 ──
CREATE TABLE IF NOT EXISTS subscription_requests (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_type TEXT NOT NULL DEFAULT 'monthly',
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    reviewed_at TEXT,
    review_note TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- ── 管理日志 ──
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT,
    action TEXT NOT NULL,
    target_type TEXT,
    target_id TEXT,
    details TEXT DEFAULT '{}',
    created_at TEXT NOT NULL,
    FOREIGN KEY (admin_id) REFERENCES admin_users(id)
);

-- ── 各科测验 ──
CREATE TABLE IF NOT EXISTS k12_quiz_bank (
    id TEXT PRIMARY KEY,
    task_key TEXT NOT NULL,
    subject TEXT NOT NULL,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    options TEXT,
    difficulty INTEGER DEFAULT 1,
    created_at TEXT NOT NULL,
    UNIQUE(task_key, question)
);

CREATE TABLE IF NOT EXISTS k12_quiz_attempts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    question_id TEXT NOT NULL,
    answer TEXT NOT NULL,
    is_correct INTEGER NOT NULL,
    attempted_at TEXT NOT NULL,
    FOREIGN KEY (question_id) REFERENCES k12_quiz_bank(id)
);

-- ── 索引 ──
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_card_memory_user_card ON card_memory(user_card_id);
CREATE INDEX IF NOT EXISTS idx_review_log_user_card ON review_log(user_card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_cards_user_plan ON user_cards(user_id, plan_run_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_card_relations_from ON card_relations(from_type, from_id);
CREATE INDEX IF NOT EXISTS idx_card_relations_to ON card_relations(to_type, to_id);
CREATE INDEX IF NOT EXISTS idx_card_relations_user ON card_relations(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_student ON guardian_assignments(student_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at);
