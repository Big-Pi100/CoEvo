-- CoEvo 刻意进化学习 — Database Schema
-- 9 tables: users, conversations, conversation_turns, cards, card_memory, review_log, achievements, skipped_concepts, learning_plans

-- 1. 用户
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    created_at TEXT NOT NULL
);

-- 2. 会话容器
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    learning_plan_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (learning_plan_id) REFERENCES learning_plans(id)
);

-- 3. 对话轮次 (N1 需要历史上下文 + N2 需要提取概念)
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,          -- "user" | "assistant"
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);

-- 4. 卡片 (N3 格式化输出 → N4 入库)
CREATE TABLE cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,
    card_type TEXT NOT NULL,     -- "vocabulary" | "concept"
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- 5. FSRS 记忆状态 (1:1 cards) (N4 初始创建 → N5 队列筛选 → N6c 更新)
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER DEFAULT 0,     -- 0:New, 1:Learning, 2:Review, 3:Relearning
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,       -- Unix timestamp
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);

-- 6. 复习日志 (N6c 写入)
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,     -- 1-4
    verification_type TEXT NOT NULL,   -- "spelling" | "ai_dialogue"
    verification_result TEXT NOT NULL, -- "pass" | "fail"
    reviewed_at INTEGER NOT NULL,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);

-- 7. 成就 (N7 写入 + 动态成就)
CREATE TABLE achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',    -- "fixed" | "bronze" | "silver" | "gold" | "platinum"
    source TEXT,                  -- "task" | "stage" | "domain" | "cross" | NULL(fixed)
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- 8. 跳过记录 (N2 去重输入 + 用户跳过 UI)
CREATE TABLE skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Indexes for performance
CREATE INDEX idx_cards_user_id ON cards(user_id);
CREATE INDEX idx_card_memory_due ON card_memory(due);
CREATE INDEX idx_card_memory_state_due ON card_memory(state, due);
CREATE INDEX idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX idx_skipped_concepts_user ON skipped_concepts(user_id);
CREATE INDEX idx_achievements_user ON achievements(user_id);

-- 9. 学习计划（结构化学习）
CREATE TABLE learning_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    goal TEXT NOT NULL,           -- "AI入门"
    domain TEXT NOT NULL,         -- "linear_algebra"
    mode TEXT DEFAULT NULL,       -- NULL(自由) / "structured" / "deleted"
    plan_json TEXT NOT NULL,      -- 完整 learning_plan JSON
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_learning_plans_user ON learning_plans(user_id);
CREATE INDEX idx_learning_plans_conv ON learning_plans(conversation_id);
