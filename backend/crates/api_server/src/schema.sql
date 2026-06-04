-- CoEvo test schema — 完整对齐生产 DDL (backend/src/main.rs SCHEMA_SQL + 运行时迁移)
-- 生成时间: 2026-06-03

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
    deleted_at TEXT DEFAULT NULL,
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
    stage_name TEXT,
    plan_task_id TEXT,
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
CREATE TABLE plan_templates (
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
CREATE TABLE conversation_plans (
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
CREATE TABLE user_plan_progress (
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
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE admin_users (
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
    approved_at TEXT,
    permissions TEXT DEFAULT '{}'
);
CREATE TABLE subscription_requests (
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
CREATE TABLE admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,
    assigned_by TEXT,
    assigned_at TEXT NOT NULL,
    is_active INTEGER DEFAULT 1,
    UNIQUE(guardian_admin_id, student_user_id)
);
CREATE TABLE k12_progress (
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
);
CREATE TABLE k12_achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_id TEXT NOT NULL,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, achievement_id)
);
CREATE TABLE k12_quiz_bank (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    grade_band TEXT NOT NULL,
    task_name TEXT,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    question_type TEXT,
    options TEXT,
    source_dataset TEXT,
    difficulty REAL DEFAULT 0.5,
    assessment_item_id TEXT,
    plan_stage_id TEXT
);
CREATE TABLE k12_quiz_attempts (
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
CREATE TABLE knowledge_graph (
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
);

-- Indexes (完整对齐生产)
CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards(user_id);
CREATE INDEX IF NOT EXISTS idx_cards_user_domain ON cards(user_id, domain);
CREATE INDEX IF NOT EXISTS idx_cards_conversation_id ON cards(conversation_id);
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory(due);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_conversation_plans_user ON conversation_plans(user_id);
CREATE INDEX IF NOT EXISTS idx_upp_user_plan ON user_plan_progress(user_id, plan_type, plan_id);
CREATE INDEX IF NOT EXISTS idx_upp_status ON user_plan_progress(plan_id, status);
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_achievements_user ON achievements(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX IF NOT EXISTS idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX IF NOT EXISTS idx_guardian_assignments_student ON guardian_assignments(student_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON admin_audit_log(action, created_at);
CREATE INDEX IF NOT EXISTS idx_k12_progress_user ON k12_progress(user_id);
CREATE INDEX IF NOT EXISTS idx_k12_achievements_user ON k12_achievements(user_id);
CREATE INDEX IF NOT EXISTS idx_k12_quiz_bank_subject_grade ON k12_quiz_bank(subject, grade_band);
CREATE INDEX IF NOT EXISTS idx_k12_quiz_attempts_user_quiz ON k12_quiz_attempts(user_id, quiz_id);
CREATE INDEX IF NOT EXISTS idx_kg_source ON knowledge_graph(source_subject, source_stage);
CREATE INDEX IF NOT EXISTS idx_kg_target ON knowledge_graph(target_subject, target_stage);
