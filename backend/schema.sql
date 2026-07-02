CREATE TABLE users (
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
CREATE TABLE card_memory (
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
CREATE TABLE review_log (
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
CREATE INDEX idx_card_memory_due ON card_memory(due);
CREATE INDEX idx_card_memory_user_card ON card_memory(user_card_id);
CREATE INDEX idx_review_log_user_card ON review_log(user_card_id, reviewed_at);
CREATE INDEX idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE TABLE user_plan_progress (
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
CREATE INDEX idx_upp_user_plan ON user_plan_progress(user_id, plan_id);
CREATE INDEX idx_upp_status ON user_plan_progress(plan_id, status);
CREATE TABLE prebuilt_plans (
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
CREATE TABLE prebuilt_stages (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    name TEXT NOT NULL,
    sort_order TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (plan_id) REFERENCES prebuilt_plans(id) ON DELETE CASCADE
);
CREATE TABLE prebuilt_tasks (
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
CREATE TABLE prebuilt_cards (
    id TEXT PRIMARY KEY,
    card_type TEXT NOT NULL,
    domain TEXT NOT NULL,
    subject TEXT NOT NULL DEFAULT '',
    grade_band TEXT NOT NULL DEFAULT '',
    front TEXT NOT NULL DEFAULT '',
    difficulty REAL DEFAULT 0.5,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE prebuilt_science_cards (
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
CREATE TABLE prebuilt_language_cards (
    id TEXT PRIMARY KEY,
    pronunciation TEXT NOT NULL DEFAULT '',
    pos TEXT NOT NULL DEFAULT '',
    definitions TEXT NOT NULL DEFAULT '[]',
    related_phrases TEXT NOT NULL DEFAULT '',
    structure_meta TEXT NOT NULL DEFAULT '',
    level TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE prebuilt_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE prebuilt_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
CREATE TABLE plan_runs (
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
CREATE TABLE user_cards (
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
CREATE TABLE user_science_cards (
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
CREATE TABLE user_language_cards (
    id TEXT PRIMARY KEY,
    pronunciation TEXT NOT NULL DEFAULT '',
    pos TEXT NOT NULL DEFAULT '',
    definitions TEXT NOT NULL DEFAULT '[]',
    related_phrases TEXT NOT NULL DEFAULT '',
    structure_meta TEXT NOT NULL DEFAULT '',
    level TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE user_literature_cards (
    id TEXT PRIMARY KEY,
    full_text TEXT NOT NULL DEFAULT '',
    translation TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    genre TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE user_humanities_cards (
    id TEXT PRIMARY KEY,
    node_type TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    period TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
CREATE TABLE card_relations (
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
    approved_at TEXT
, permissions TEXT DEFAULT '{}');
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
    difficulty REAL DEFAULT 0.5
, assessment_item_id TEXT DEFAULT NULL, plan_stage_id TEXT DEFAULT NULL);
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
CREATE INDEX idx_admin_users_role_status ON admin_users(role, status);
CREATE INDEX idx_subscription_requests_status ON subscription_requests(status);
CREATE INDEX idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX idx_guardian_assignments_student ON guardian_assignments(student_user_id);
CREATE INDEX idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX idx_admin_audit_log_action ON admin_audit_log(action, created_at);
CREATE TABLE subscription_plans (
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
CREATE TABLE payment_orders (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    currency TEXT DEFAULT 'CNY',
    status TEXT DEFAULT 'NOTPAY',
    prepay_id TEXT,
    transaction_id TEXT,
    paid_at TEXT,
    created_at TEXT NOT NULL, refund_reason TEXT DEFAULT NULL, refund_id TEXT DEFAULT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX idx_payment_orders_status ON payment_orders(status);
CREATE TABLE subscription_audit_log (
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
CREATE TABLE sqlite_sequence(name,seq);
CREATE INDEX idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX idx_audit_created ON subscription_audit_log(created_at);
CREATE TABLE app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT DEFAULT '',
    updated_at INTEGER NOT NULL
);
CREATE TABLE debug_trackers (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    subject TEXT,
    status TEXT DEFAULT 'active',
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_debug_trackers_user ON debug_trackers(user_id);
CREATE TABLE debug_logs (
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
CREATE INDEX idx_debug_logs_conv ON debug_logs(conversation_id);
CREATE INDEX idx_debug_logs_date ON debug_logs(date);
CREATE TABLE marketing_campaigns (
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
    poster_prompt TEXT, poster_template TEXT DEFAULT NULL, h5_template TEXT DEFAULT NULL, h5_prompt TEXT DEFAULT NULL, display_positions TEXT DEFAULT '[]',                        -- 自定义海报系统提示（主prompt）
    FOREIGN KEY (created_by) REFERENCES admin_users(id),
    FOREIGN KEY (updated_by) REFERENCES admin_users(id)
);
CREATE TABLE referral_clicks (
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
CREATE INDEX idx_clicks_campaign ON referral_clicks(campaign_id);
CREATE INDEX idx_clicks_referrer ON referral_clicks(referrer_id);
CREATE INDEX idx_clicks_anonymous ON referral_clicks(clicker_anonymous_id);
CREATE TABLE distribution_commissions (
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
CREATE INDEX idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX idx_commission_batch ON distribution_commissions(batch_id);
CREATE TABLE user_notifications (
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
CREATE INDEX idx_notifications_user ON user_notifications(user_id, read, created_at);
CREATE TABLE reward_fulfillments (
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
CREATE INDEX idx_fulfillment_campaign ON reward_fulfillments(campaign_id, trigger_event);
CREATE INDEX idx_fulfillment_conversion ON reward_fulfillments(referral_click_id);
CREATE INDEX idx_fulfillment_order ON reward_fulfillments(order_id);
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL, key TEXT NOT NULL,
    value TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE INDEX idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
CREATE INDEX idx_user_cards_user_plan ON user_cards(user_id, plan_run_id);
CREATE INDEX idx_conversations_user_deleted ON conversations(user_id, deleted_at);
CREATE UNIQUE INDEX idx_users_phone_hash ON users(phone_hash) WHERE phone_hash IS NOT NULL;
CREATE INDEX idx_k12_quiz_bank_subject_grade ON k12_quiz_bank(subject, grade_band);
CREATE INDEX idx_k12_quiz_attempts_user_quiz ON k12_quiz_attempts(user_id, quiz_id);
CREATE TABLE campaign_members (
    campaign_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    role TEXT DEFAULT 'member',
    created_at TEXT NOT NULL,
    PRIMARY KEY (campaign_id, user_id),
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_campaign_members_campaign ON campaign_members(campaign_id);
CREATE TABLE trial_ip_log (
    id TEXT PRIMARY KEY,
    ip TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_trial_ip_log_ip_created ON trial_ip_log(ip, created_at);
CREATE UNIQUE INDEX idx_fulfillment_unique ON reward_fulfillments(campaign_id, user_id, trigger_event, party, reward_type, order_id);
CREATE INDEX idx_campaign_members_user ON campaign_members(user_id);
CREATE TABLE distribution_expenses (
    id TEXT PRIMARY KEY,
    earner_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    expense_type TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    ref_commission_id TEXT,
    ref_withdrawal_id TEXT,
    batch_id TEXT,
    note TEXT,
    created_at TEXT NOT NULL,
    handled_at TEXT, fee INTEGER DEFAULT 0, actual_amount INTEGER, handled_by TEXT, batch_no TEXT, batch_paid_at TEXT,
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id)
);
CREATE INDEX idx_expenses_earner ON distribution_expenses(earner_id, status);
CREATE INDEX idx_expenses_batch ON distribution_expenses(batch_id);
CREATE INDEX idx_expenses_batch_no ON distribution_expenses(batch_no);
