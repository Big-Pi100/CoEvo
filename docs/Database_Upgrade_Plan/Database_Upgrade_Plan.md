## CoEvo 数据库完整重构设计（最终版）

> 基于原 `database-schema.md` 分析，修正所有已知问题。  
> 数据库：SQLite（兼容 PostgreSQL 语法，外键约束需开启 `PRAGMA foreign_keys=ON`）。  
> 时间类型统一为 `INTEGER`（Unix 时间戳，秒级），便于排序和计算。  
> 所有表均使用 `TEXT` 主键（UUID 或自定义格式），但建议逐步迁移至 `INTEGER` 自增（若性能允许）。

---

## 表结构定义（按模块分组）

### 1. 用户与身份模块

#### `users` — 用户表
```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,                        -- "user_xxx" 或 UUID
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,                         -- bcrypt/argon2
    streak_days INTEGER DEFAULT 0,
    last_active_date INTEGER,                   -- Unix 时间戳，日期零点
    created_at INTEGER NOT NULL,                -- Unix 时间戳
    display_name TEXT,
    real_name TEXT,                             -- AES-256-GCM 加密
    phone TEXT,                                 -- AES-256-GCM 加密
    id_number TEXT,                             -- AES-256-GCM 加密
    bind_hash TEXT UNIQUE,                      -- SHA-256(real_name + phone) 明文哈希，唯一索引
    deleted_at INTEGER                          -- 软删除时间戳
);
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_bind_hash ON users(bind_hash);
```

**变更说明**：
- `last_active_date`、`created_at`、`deleted_at` 改为 `INTEGER` Unix 时间戳。
- 删除原 `idx_users_bind_key`（基于加密列），新增 `bind_hash` 唯一约束。
- `bind_hash` 由应用层在插入/更新时计算并存储。

---

#### `tokens` — 认证令牌
```sql
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,                        -- UUID 格式
    created_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_tokens_user ON tokens(user_id);
CREATE INDEX idx_tokens_token ON tokens(token);
```

**变更**：`created_at` 改为 `INTEGER`。

---

#### `user_preferences` — 用户偏好
```sql
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

**变更**：`updated_at` 改为 `INTEGER`。

---

### 2. 对话与学习计划核心模块

#### `conversations` — 对话表
```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at INTEGER NOT NULL,
    deleted_at INTEGER,
    subject TEXT,                               -- "数学" / "语文" / NULL
    grade_band TEXT,                            -- "g7-9" / "g1-2" / NULL
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_conversations_user_deleted ON conversations(user_id, deleted_at);
```

**变更**：
- **删除** `learning_plan_id` 字段（废弃）。
- `started_at`、`deleted_at` 改为 `INTEGER`。

---

#### `learning_plans` — 学习计划表
```sql
CREATE TABLE learning_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,       -- 一个对话至多一个计划
    goal TEXT NOT NULL,
    domain TEXT,                                -- 学科标签（如 "math"、"chinese"），可由 conversations.subject 派生
    mode TEXT,                                  -- "structured" / "reading"
    task_status JSON NOT NULL,                  -- 原 plan_json，存储 {"task_key": "done/pending/in_progress"}
    plan_content JSON,                          -- 蓝图：{"stages": [...], "completed_concepts": [...], "current_task_complete": false}
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX idx_learning_plans_user ON learning_plans(user_id);
CREATE INDEX idx_learning_plans_domain ON learning_plans(domain);
```

**变更**：
- `conversation_id` 添加外键及唯一约束（原通过 `domain` 间接实现，现规范化）。
- 删除原 `domain` 中存储的 conversation_id 错误用法，新增真正的 `domain` 学科标签。
- `plan_json` 重命名为 `task_status`，类型为 `JSON`（SQLite 需使用 `TEXT`，但语义为 JSON）。
- `plan_content` 保持 JSON。
- 所有时间戳改为 `INTEGER`。

---

#### `learning_plan_tasks` — 计划任务明细表（新增）
```sql
CREATE TABLE learning_plan_tasks (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    task_key TEXT NOT NULL,                     -- 如 "task_1_1"、"task_2_3"
    task_name TEXT NOT NULL,                    -- 显示名称，如 "认识方程"
    description TEXT,
    stage_index INTEGER,                        -- 所属 stage 序号（从0开始）
    task_index INTEGER,                         -- 在 stage 内的序号
    created_at INTEGER NOT NULL,
    UNIQUE(plan_id, task_key),
    FOREIGN KEY (plan_id) REFERENCES learning_plans(id) ON DELETE CASCADE
);
CREATE INDEX idx_tasks_plan_id ON learning_plan_tasks(plan_id);
```

**说明**：将 `plan_content` 中的任务列表实体化，使 `cards.plan_task_id` 可关联到具体任务。创建学习计划时需解析 `plan_content` 并插入该表。

---

#### `conversation_turns` — 对话轮次
```sql
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,                         -- "user" / "assistant"
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX idx_conversation_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
```

**变更**：`created_at` 改为 `INTEGER`。

---

### 3. 卡片与复习模块

#### `cards` — 卡片表
```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,                                -- 学科标签，与 learning_plans.domain 一致
    card_type TEXT NOT NULL,                   -- "concept" / "vocab" / "reading"
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    conversation_id TEXT,                      -- 所属对话
    subject TEXT,
    grade_band TEXT,
    k12_card_id TEXT,                          -- 若未使用可保留，后续可清理
    gold_cr_id TEXT,
    plan_task_id TEXT,                         -- 指向具体任务，若不需要可删除，这里保留为外键
    origin TEXT DEFAULT 'extracted',           -- "extracted" / "prebuilt"
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL,
    FOREIGN KEY (plan_task_id) REFERENCES learning_plan_tasks(id) ON DELETE SET NULL
);
CREATE INDEX idx_cards_user_id ON cards(user_id);
CREATE INDEX idx_cards_user_domain ON cards(user_id, domain);
CREATE INDEX idx_cards_conversation_id ON cards(conversation_id);
CREATE INDEX idx_cards_plan_task_id ON cards(plan_task_id);
```

**变更**：
- 添加 `conversation_id` 外键约束（`ON DELETE SET NULL`）。
- 添加 `plan_task_id` 外键（指向新表 `learning_plan_tasks`），启用该字段。
- `created_at` 保持 `INTEGER`（原已是），无需改动。
- 其他字段保留，`k12_card_id`、`gold_cr_id` 可后续清理。

---

#### `card_memory` — 记忆曲线
```sql
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER DEFAULT 0,                   -- 0=New,1=Learning,2=Review,3=Relearning
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,                     -- Unix 时间戳
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
CREATE INDEX idx_card_memory_due ON card_memory(due);
```

**变更**：无，已为 `ON DELETE CASCADE`（SQLite 需显式支持，建议加上）。

---

#### `review_log` — 复习记录
```sql
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL,           -- "typing" / "ai_quiz"
    verification_result TEXT NOT NULL,         -- "pass" / "fail"
    reviewed_at INTEGER NOT NULL,
    details_json TEXT,                         -- JSON array，每道题详情
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
CREATE INDEX idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
```

**变更**：无实质变化，`reviewed_at` 已是 `INTEGER`。

---

#### `skipped_concepts` — 跳过概念
```sql
CREATE TABLE skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_skipped_concepts_user ON skipped_concepts(user_id);
```

**变更**：`skipped_at` 改为 `INTEGER`。

---

### 4. 成就系统模块

#### `achievements` — 成就
```sql
CREATE TABLE achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',                 -- "fixed"/"bronze"/"silver"/"gold"/"platinum"
    source TEXT,
    unlocked_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE(user_id, achievement_key)
);
CREATE INDEX idx_achievements_user ON achievements(user_id);
```

**变更**：`unlocked_at` 改为 `INTEGER`，添加唯一约束。

---

#### `k12_achievements` — K12 成就
```sql
CREATE TABLE k12_achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_id TEXT NOT NULL,
    unlocked_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE(user_id, achievement_id)
);
CREATE INDEX idx_k12_achievements_user ON k12_achievements(user_id);
```

**变更**：`unlocked_at` 改为 `INTEGER`。

---

#### `k12_progress` — K12 进度
```sql
CREATE TABLE k12_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    subject TEXT NOT NULL,
    grade_band TEXT NOT NULL,
    plan_json TEXT,                            -- 可存储快照，用途待明确
    mastered_cards INTEGER DEFAULT 0,
    total_cards INTEGER DEFAULT 0,
    started_at INTEGER NOT NULL,
    last_activity_at INTEGER,
    completed_at INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE(user_id, subject, grade_band)
);
CREATE INDEX idx_k12_progress_user ON k12_progress(user_id);
```

**变更**：时间字段改为 `INTEGER`。

---

### 5. 题库模块（保持原结构，仅改时间）

#### `k12_quiz_bank` — 题库
```sql
CREATE TABLE k12_quiz_bank (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    grade_band TEXT NOT NULL,
    task_name TEXT,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    question_type TEXT,
    options TEXT,                               -- JSON array 或文本
    source_dataset TEXT,
    difficulty REAL DEFAULT 0.5,
    assessment_item_id TEXT,
    plan_stage_id TEXT,                         -- 指向 learning_plan_tasks? 预留
    plan_task_id TEXT
);
CREATE INDEX idx_k12_quiz_bank_subject_grade ON k12_quiz_bank(subject, grade_band);
```

**变更**：无时间字段，保持不变。

---

#### `k12_quiz_attempts` — 答题记录
```sql
CREATE TABLE k12_quiz_attempts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    quiz_id TEXT NOT NULL,
    conversation_id TEXT,
    user_answer TEXT,
    is_correct INTEGER,
    attempted_at INTEGER NOT NULL,
    task_name TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (quiz_id) REFERENCES k12_quiz_bank(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
);
CREATE INDEX idx_k12_quiz_attempts_user_quiz ON k12_quiz_attempts(user_id, quiz_id);
```

**变更**：
- `attempted_at` 改为 `INTEGER`。
- 添加外键约束 `quiz_id` → `k12_quiz_bank(id)`，`conversation_id` → `conversations(id)`。

---

### 6. 知识图谱模块（无变化）

```sql
CREATE TABLE knowledge_graph (
    id TEXT PRIMARY KEY,
    source_subject TEXT NOT NULL,
    source_stage TEXT,
    source_task TEXT,
    target_subject TEXT NOT NULL,
    target_stage TEXT,
    target_task TEXT,
    edge_type TEXT NOT NULL,                   -- "prerequisite"/"related"/"expands"
    strength TEXT DEFAULT 'medium',
    note TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_kg_source ON knowledge_graph(source_subject, source_stage);
CREATE INDEX idx_kg_target ON knowledge_graph(target_subject, target_stage);
```

**变更**：`created_at` 改为 `INTEGER`。

---

### 7. 管理后台模块

#### `admin_users` — 管理员
```sql
CREATE TABLE admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending',
    status TEXT NOT NULL DEFAULT 'pending',
    real_name TEXT,                            -- AES-256-GCM
    phone TEXT,                                -- AES-256-GCM
    id_number TEXT,                            -- AES-256-GCM
    guardian_declaration TEXT,                 -- PII
    apply_reason TEXT,
    reject_reason TEXT,
    registered_from TEXT,
    created_by TEXT,
    created_at INTEGER NOT NULL,
    approved_at INTEGER,
    permissions TEXT DEFAULT '{}'              -- JSON
);
CREATE INDEX idx_admin_users_role_status ON admin_users(role, status);
```

**变更**：时间字段改为 `INTEGER`。

---

#### `admin_audit_log` — 审计日志
```sql
CREATE TABLE admin_audit_log (
    id TEXT PRIMARY KEY,
    admin_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_user_id TEXT,
    request_id TEXT,
    detail TEXT,                               -- JSON
    created_at INTEGER NOT NULL,
    FOREIGN KEY (admin_id) REFERENCES admin_users(id) ON DELETE CASCADE
);
CREATE INDEX idx_admin_audit_log_admin ON admin_audit_log(admin_id, created_at);
CREATE INDEX idx_admin_audit_log_action ON admin_audit_log(action, created_at);
```

**变更**：`created_at` 改为 `INTEGER`。

---

#### `guardian_assignments` — 监护人绑定
```sql
CREATE TABLE guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,                    -- SHA-256(real_name+phone)
    assigned_by TEXT,
    assigned_at INTEGER NOT NULL,
    is_active INTEGER DEFAULT 1,
    UNIQUE(guardian_admin_id, student_user_id),
    FOREIGN KEY (guardian_admin_id) REFERENCES admin_users(id) ON DELETE CASCADE,
    FOREIGN KEY (student_user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_guardian_assignments_guardian ON guardian_assignments(guardian_admin_id);
CREATE INDEX idx_guardian_assignments_student ON guardian_assignments(student_user_id);
```

**变更**：`assigned_at` 改为 `INTEGER`。

---

### 8. 其他表

#### `subscription_requests` — 订阅申请
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
    requested_at INTEGER NOT NULL,
    reviewed_at INTEGER,
    FOREIGN KEY (target_user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_subscription_requests_status ON subscription_requests(status);
```

**变更**：时间改为 `INTEGER`。

---

## 统一迁移脚本（针对现有数据库）

为从旧结构迁移到新结构，需执行以下步骤（假设已有生产数据）：

1. **备份数据库**。
2. **开启外键约束临时关闭**（SQLite 需重建表）。
3. **按顺序执行更改**：

```sql
-- 1. 添加新字段和临时列
ALTER TABLE users ADD COLUMN bind_hash TEXT;
UPDATE users SET bind_hash = hex(randomblob(32)); -- 临时值，实际应由应用计算
CREATE UNIQUE INDEX idx_users_bind_hash ON users(bind_hash);
DROP INDEX idx_users_bind_key;

-- 2. 修改 conversations
ALTER TABLE conversations DROP COLUMN learning_plan_id; -- SQLite 不支持直接删列，需重建表（略）

-- 3. 修改 learning_plans（更复杂，建议重建）
-- 创建新表，迁移数据，再删除旧表
-- 具体略，根据实际数据编写

-- 4. 创建 learning_plan_tasks
CREATE TABLE learning_plan_tasks (...);
-- 从 learning_plans.plan_content 解析并插入

-- 5. 修改 cards
-- 添加外键：先清理孤儿数据
DELETE FROM cards WHERE conversation_id NOT IN (SELECT id FROM conversations);
CREATE INDEX idx_cards_conversation_id ON cards(conversation_id);
-- 由于 SQLite 不支持 ALTER 添加外键，需重建 cards 表

-- 6. 将所有时间戳 TEXT 字段转换为 INTEGER（需逐表处理）
```

鉴于 SQLite 对 `ALTER TABLE` 的限制较多（不支持直接删除列、添加外键等），建议使用**重建表**的方式迁移。可提供详细的迁移脚本，但需根据实际数据量评估。

---

## 数据结构总结

- **总表数**：20 张（与原来一致，新增 `learning_plan_tasks` 但未删除任何表，除非清理废弃字段）。
- **外键完整性**：所有必要的跨表引用均建立了外键约束（`ON DELETE CASCADE` 或 `SET NULL`）。
- **时间统一**：全部改为 `INTEGER` Unix 时间戳，便于排序和计算。
- **命名清晰**：`plan_json` 重命名为 `task_status`，`domain` 语义修复。
- **扩展性**：`learning_plan_tasks` 支持任务级卡片归属；`cards.plan_task_id` 启用。