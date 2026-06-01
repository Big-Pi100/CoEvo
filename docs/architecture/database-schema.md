# CoEvo 数据库结构文档

> 生成时间: 2026-05-31 19:14  
> 数据库: SQLite, `/opt/coevo/data/coevo.db`  
> 表数量: 20 张

---

## 1. 核心业务表（3+1）

### 1.1 `users` — 用户（67 行）

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,              -- "user_xxx"
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,            -- "2026-05-30"
    created_at TEXT NOT NULL,         -- RFC 3339
    display_name TEXT DEFAULT NULL,
    real_name TEXT DEFAULT NULL,       -- PII, AES-256-GCM 加密
    phone TEXT DEFAULT NULL,           -- PII, AES-256-GCM 加密
    id_number TEXT DEFAULT NULL,
    bind_hash TEXT DEFAULT NULL,       -- SHA-256(real_name + phone)
    deleted_at TEXT
);
CREATE UNIQUE INDEX idx_users_bind_key ON users(real_name, phone);
```

唯一索引 `idx_users_bind_key` 在加密前建立，用于监护人绑定时的去重匹配。

---

### 1.2 `conversations` — 对话（139 行）

```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,              -- UUID 或 user_id
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    learning_plan_id TEXT,            -- ❌ 废弃，从未写入
    deleted_at TEXT DEFAULT NULL,
    subject TEXT DEFAULT NULL,        -- "数学" / "语文" / NULL（自由对话）
    grade_band TEXT DEFAULT NULL,     -- "g7-9" / "g1-2" / NULL
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_conversations_user_deleted ON conversations(user_id, deleted_at);
```

**问题**: `learning_plan_id` 字段存在但从未被代码写入，所有行均为 NULL。应删除。

---

### 1.3 `learning_plans` — 学习计划（61 行）

```sql
CREATE TABLE learning_plans (
    id TEXT PRIMARY KEY,              -- UUID
    user_id TEXT NOT NULL,
    conversation_id TEXT,             -- → conversations.id
    goal TEXT NOT NULL,               -- 计划标题，如"一元二次方程求解"
    domain TEXT NOT NULL,             -- 当前: conversation_id; 建议改为学科标签
    mode TEXT DEFAULT NULL,           -- "structured" / "reading"
    plan_json TEXT NOT NULL,          -- 运行时状态: {"task_status": {name: status}}
    plan_content TEXT DEFAULT NULL,   -- 结构蓝图: {"stages": [...], "completed_concepts": [...]}
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_learning_plans_user ON learning_plans(user_id);
CREATE UNIQUE INDEX idx_plans_user_domain ON learning_plans(user_id, domain);
```

**问题**:
- `domain` 被用作 UNIQUE 约束键（存 conversation_id），但语义上应该是学科标签
- `conversation_id` 没有外键约束指向 `conversations(id)`
- 唯一约束应为 `(user_id, conversation_id)` 而非 `(user_id, domain)`

---

### 1.4 `cards` — 卡片（2011 行）

```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,              -- UUID
    user_id TEXT NOT NULL,
    domain TEXT,                      -- 学科标签: "math" / "chinese" / "philosophy"
    card_type TEXT NOT NULL,          -- "concept" / "vocab" / "reading"
    front TEXT NOT NULL,              -- 卡片正面
    back TEXT NOT NULL,               -- 卡片背面
    source_sentence TEXT,             -- 来源语句
    created_at INTEGER NOT NULL,      -- Unix 时间戳
    conversation_id TEXT,             -- → conversations.id
    subject TEXT DEFAULT NULL,
    grade_band TEXT DEFAULT NULL,
    k12_card_id TEXT DEFAULT NULL,
    gold_cr_id TEXT DEFAULT NULL,
    plan_task_id TEXT DEFAULT NULL,   -- ❌ 未使用，可关联到具体任务
    origin TEXT DEFAULT 'extracted',  -- "extracted"(CP1) / "prebuilt"(预置)
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_cards_user_id ON cards(user_id);
CREATE INDEX idx_cards_user_domain ON cards(user_id, domain);
```

**问题**:
- `conversation_id` 没有外键约束
- `plan_task_id` 存在但未使用
- `domain` 是 LLM 自由推断的，与 `learning_plans.domain` 无一致性保证

---

### 1.5 `card_memory` — 卡片记忆曲线（2007 行，1:1 对应 cards）

```sql
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,         -- → cards.id
    state INTEGER DEFAULT 0,         -- 0=New, 1=Learning, 2=Review, 3=Relearning
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,           -- Unix 时间戳
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE INDEX idx_card_memory_due ON card_memory(due);
```

---

## 2. 对话与内容表（2 张）

### 2.1 `conversation_turns` — 对话轮次（939 行）

```sql
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,               -- "user" / "assistant"
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE INDEX idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
```

### 2.2 `tokens` — Token（290 行）

```sql
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,              -- UUID 格式的 auth token
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

---

## 3. 复习与评估表（2 张）

### 3.1 `review_log` — 复习记录（15 行）

```sql
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,          -- FSRS rating
    verification_type TEXT NOT NULL,  -- "typing" / "ai_quiz"
    verification_result TEXT NOT NULL, -- "pass" / "fail"
    reviewed_at INTEGER NOT NULL,
    details_json TEXT DEFAULT NULL,   -- 扩展字段: [{question, correct, feedback}]
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE INDEX idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
```

### 3.2 `skipped_concepts` — 跳过概念（37 行）

```sql
CREATE TABLE skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,              -- 被跳过的概念名
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

---

## 4. 成就系统（3 张）

### 4.1 `achievements` — 成就（34 行）

```sql
CREATE TABLE achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,      -- 唯一键
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',          -- "fixed" / "bronze" / "silver" / "gold" / "platinum"
    source TEXT,                        -- 触发来源
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 4.2 `k12_achievements` — K12 成就（0 行）

```sql
CREATE TABLE k12_achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_id TEXT NOT NULL,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, achievement_id)
);
CREATE INDEX idx_k12_achievements_user ON k12_achievements(user_id);
```

### 4.3 `k12_progress` — K12 进度（0 行）

```sql
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
CREATE INDEX idx_k12_progress_user ON k12_progress(user_id);
```

---

## 5. 题库 (2 张)

### 5.1 `k12_quiz_bank` — 题库（0 行）

```sql
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
    assessment_item_id TEXT DEFAULT NULL,
    plan_stage_id TEXT DEFAULT NULL,
    plan_task_id TEXT DEFAULT NULL
);
CREATE INDEX idx_k12_quiz_bank_subject_grade ON k12_quiz_bank(subject, grade_band);
```

### 5.2 `k12_quiz_attempts` — 答题记录（0 行）

```sql
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
CREATE INDEX idx_k12_quiz_attempts_user_quiz ON k12_quiz_attempts(user_id, quiz_id);
```

---

## 6. 知识图谱（1 张）

### 6.1 `knowledge_graph` — 知识图谱（0 行）

```sql
CREATE TABLE knowledge_graph (
    id TEXT PRIMARY KEY,
    source_subject TEXT NOT NULL,
    source_stage TEXT,
    source_task TEXT,
    target_subject TEXT NOT NULL,
    target_stage TEXT,
    target_task TEXT,
    edge_type TEXT NOT NULL,           -- "prerequisite"/"related"/"expands"
    strength TEXT DEFAULT 'medium',
    note TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX idx_kg_source ON knowledge_graph(source_subject, source_stage);
CREATE INDEX idx_kg_target ON knowledge_graph(target_subject, target_stage);
```

---

## 7. 管理后台表（3 张）

### 7.1 `admin_users` — 管理员（7 行）

```sql
CREATE TABLE admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending',
    status TEXT NOT NULL DEFAULT 'pending',
    real_name TEXT,                     -- PII, AES-256-GCM 加密
    phone TEXT,                         -- PII, AES-256-GCM 加密
    id_number TEXT,                     -- PII, AES-256-GCM 加密
    guardian_declaration TEXT,          -- PII
    apply_reason TEXT,
    reject_reason TEXT,
    registered_from TEXT,
    created_by TEXT,
    created_at TEXT NOT NULL,
    approved_at TEXT,
    permissions TEXT DEFAULT '{}'
);
CREATE INDEX idx_admin_users_role_status ON admin_users(role, status);
```

### 7.2 `admin_audit_log` — 审计日志（17 行）

```sql
CREATE TABLE admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX idx_admin_audit_log_action ON admin_audit_log(action, created_at);
```

### 7.3 `guardian_assignments` — 监护人绑定（3 行）

```sql
CREATE TABLE guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,              -- SHA-256(real_name + phone)
    assigned_by TEXT,
    assigned_at TEXT NOT NULL,
    is_active INTEGER DEFAULT 1,
    UNIQUE(guardian_admin_id, student_user_id)
);
CREATE INDEX idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX idx_guardian_assignments_student ON guardian_assignments(student_user_id);
```

---

## 8. 杂项（3 张）

### 8.1 `subscription_requests` — 订阅申请（2 行）

```sql
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
CREATE INDEX idx_subscription_requests_status ON subscription_requests(status);
```

### 8.2 `user_preferences` — 用户偏好（58 行）

```sql
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 8.3 `knowledge_graph` — 知识图谱（见 6.1）

---

## 问题汇总

| 表 | 问题 | 严重度 |
|:---|:-----|:-------|
| `conversations.learning_plan_id` | 全部 NULL，从未使用 | 🟡 可清理 |
| `learning_plans.domain` | 被误做 UNIQUE 键（存 conversation_id）| 🔴 必须改 |
| `learning_plans.conversation_id` | 无外键约束 | 🟡 建议加 |
| `cards.conversation_id` | 无外键约束 | 🟡 建议加 |
| `cards.plan_task_id` | 全部 NULL，从未使用 | 🟢 可清理或激活 |
| `cards.domain` | LLM 自由推断，无一致性保证 | 🟡 需规范 |
| `learning_plans.plan_json` 命名 | 应改为 `task_status` 或 `plan_state` | 🟢 命名问题 |
| 三表循环依赖 | `conversations` ↔ `learning_plans` 双向引用 | 🔴 必须消除 |

---

## JSON 字段汇总

| 表 | 字段 | 结构 | 用途 | 合理性 |
|:---|:-----|:------|:-----|:-------|
| `learning_plans` | `plan_json` | `{"task_status": {"任务名": "done/pending"}}` | 运行时状态映射 | ✅ 正确——key-value 映射不适合用列存 |
| `learning_plans` | `plan_content` | `{"stages": [...], "completed_concepts": [...]}` | 结构蓝图 | ✅ 正确——阶段/任务的层次结构，列存需多张表 |
| `admin_audit_log` | `detail` | `{"expires": "..."}` 或 `{"deleted_at": "..."}` | 审计详情 | ✅ 正确——不同 action 结构不同 |
| `review_log` | `details_json` | `[{"question":"","correct":true,"feedback":""}]` | 每题评分详情 | ✅ 正确——题数可变 |

**结论**: 4 个 JSON 字段各有合理用途，不需要拆分。`plan_json` 和 `plan_content` 的职责分离（状态 vs 结构）是合理设计，只是命名不佳。`plan_json` 应叫 `task_status` 或 `plan_state`。
