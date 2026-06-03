# CoEvo 数据库完整结构分析报告

> 基于 V2.1 迁移后实际 Schema  
> 分析范围：全部 20 张有效表的结构、约束、索引、外键  
> 更新时机：2026-06-02（同步生产 DDL + 全量迁移）

---

## 一、表分类与数量（20 张有效表）

| 分类 | 表名 | 核心层 | 说明 |
|------|------|--------|------|
| **用户与身份** | `users` | ⭐⭐⭐ | 用户 + PII 加密 |
| | `tokens` | ⭐⭐ | JWT 令牌 |
| | `user_preferences` | ⭐ | 键值对 |
| **核心业务** | `conversations` | ⭐⭐⭐ | 对话 |
| | `conversation_turns` | ⭐⭐⭐ | 对话轮次 |
| | `cards` | ⭐⭐⭐ | 卡片本体 |
| | `card_memory` | ⭐⭐⭐ | FSRS 状态 |
| | `learning_plans` | ⭐⭐ | 遗留 K12 表（将被废弃） |
| **V2.1 新表** | `plan_templates` | ⭐⭐⭐ | K12 共享模板（15 行） |
| | `conversation_plans` | ⭐⭐⭐ | CP2 动态计划 |
| | `user_plan_progress` | ⭐⭐⭐ | 任务级进度（新核心） |
| **复习与评估** | `review_log` | ⭐⭐ | 复习记录 |
| **成就系统** | `achievements` | ⭐⭐ | |
| | `k12_achievements` | ⭐ | |
| | `k12_progress` | ⭐ | 将被废弃 |
| **题库** | `k12_quiz_bank` | ⭐⭐ | |
| | `k12_quiz_attempts` | ⭐ | |
| **知识图谱** | `knowledge_graph` | ⭐⭐ | |
| **管理后台** | `admin_users` | ⭐⭐ | |
| | `admin_audit_log` | ⭐⭐ | |
| | `guardian_assignments` | ⭐ | |

### 已废弃/删除的表

| 表名 | V2.1 处置 | 删除时机 |
|------|-----------|---------|
| `learning_plan_tasks` | `DROP TABLE IF EXISTS` | V2.1 Phase 0 |
| `skipped_concepts` | `DROP TABLE IF EXISTS` | Phase N |
| `cp1_plans` | 重命名为 `conversation_plans` | V2.1 Phase 2 |

---

## 二、逐表 DDL（生产最终形态）

> 以下为经过所有迁移后，生产数据库中每张表的最终结构。

### 2.1 `users`

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,              -- bcrypt
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT DEFAULT NULL,  -- 迁移 #10
    real_name TEXT,                  -- PII AES-256-GCM
    phone TEXT,                      -- PII AES-256-GCM
    id_number TEXT,                  -- PII AES-256-GCM
    bind_hash TEXT,                  -- SHA-256(real_name + phone)
    deleted_at TEXT,                 -- 软删除
    created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_users_bind_hash ON users(bind_hash) WHERE bind_hash IS NOT NULL;
```

### 2.2 `tokens`

```sql
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 2.3 `conversations`

```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    deleted_at TEXT,                 -- 软删除
    subject TEXT,                    -- K12 标记（如 'math'）
    grade_band TEXT,                 -- K12 学段（如 'chu_zhong'）
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

> **已移除**: `learning_plan_id`（V2.0 重建时删除）

### 2.4 `conversation_turns`

```sql
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,              -- "user" | "assistant"
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
```

### 2.5 `cards` — ⚠️ 注意迁移轨迹

```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,                     -- 英文代码
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
    plan_task_id TEXT,               -- ⚠️ 存在于 DDL 但 V2.1 已无 learning_plan_tasks 表
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'pending', 'skipped', 'archived')),  -- Phase N 添加
    origin TEXT DEFAULT 'extracted'
        CHECK(origin IN ('extracted', 'prebuilt')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
);
```

> **迁移轨迹说明**:
> 1. SCHEMA_SQL 初始 DDL 包含 `plan_task_id`，但无 `status`
> 2. V2.0 Phase 4 本应重建表（移除 `plan_task_id` 和 `status`），但因 `origin` 列已存在而 **跳过**
> 3. Phase N 通过 `ALTER TABLE` 添加 `status` 列 + CHECK 约束
> 4. **结果**: `plan_task_id` 列仍然存在，但指向的 `learning_plan_tasks` 已在 V2.1 Phase 0 中被删除——**虚悬列**
> 5. `reading` 模式代码（routes.rs:2184）仍在写入 `plan_task_id`（旧的遗留行为）

### 2.6 `card_memory`

```sql
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER DEFAULT 0,         -- 0:New 1:Learning 2:Review 3:Relearning
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
```

### 2.7 `review_log`

```sql
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,         -- 1-4
    verification_type TEXT NOT NULL CHECK(verification_type IN ('spelling', 'typing', 'ai_dialogue')),
    verification_result TEXT NOT NULL CHECK(verification_result IN ('pass', 'fail')),
    reviewed_at INTEGER NOT NULL,
    details_json TEXT,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
```

### 2.8 `learning_plans` — 遗留 K12 表（将废弃）

```sql
CREATE TABLE learning_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,
    goal TEXT NOT NULL,
    domain TEXT DEFAULT 'general'
        CHECK(domain IN ('general','math','language','chemistry','biology','physics',
                         'history','geography','politics','science','it','pe','art','labor')),
    mode TEXT DEFAULT NULL CHECK(mode IN ('structured', 'reading', 'free', 'deleted')),
    plan_content TEXT DEFAULT NULL,
    plan_json TEXT NOT NULL,
    task_status TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
```

### 2.9 `plan_templates` — V2.1 新建

```sql
CREATE TABLE plan_templates (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    subject_key TEXT NOT NULL UNIQUE,
    grade_band TEXT NOT NULL,
    goal TEXT NOT NULL,
    plan_content TEXT NOT NULL,       -- JSON stages → tasks
    version INTEGER DEFAULT 1,
    updated_at INTEGER NOT NULL,
    UNIQUE(subject_key, grade_band)
);
```

### 2.10 `conversation_plans` — V2.1 新建

```sql
CREATE TABLE conversation_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,
    goal TEXT NOT NULL,
    domain TEXT DEFAULT 'general'
        CHECK(domain IN ('general','math','language','chemistry','biology','physics',
                         'history','geography','politics','science','it','pe','art','labor')),
    plan_content TEXT,               -- JSON stages → tasks
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
```

### 2.11 `user_plan_progress` — V2.1 新建（核心状态表）

```sql
CREATE TABLE user_plan_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_type TEXT NOT NULL,          -- 'k12' | 'cp2'
    plan_id TEXT NOT NULL,            -- plan_templates.id 或 conversation_plans.id
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
```

### 2.12 `achievements`

```sql
CREATE TABLE achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',        -- 'fixed'|'bronze'|'silver'|'gold'|'platinum'
    source TEXT,                      -- 'task'|'stage'|'domain'|'cross'
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 2.13 `k12_progress` — 将废弃

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
```

### 2.14 `k12_achievements`

```sql
CREATE TABLE k12_achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_id TEXT NOT NULL,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, achievement_id)
);
```

### 2.15 `k12_quiz_bank`

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
    assessment_item_id TEXT,
    plan_stage_id TEXT
);
```

### 2.16 `k12_quiz_attempts`

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
```

### 2.17 `knowledge_graph`

```sql
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
```

### 2.18 `user_preferences`

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

### 2.19 `admin_users`

```sql
CREATE TABLE admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending',
    status TEXT NOT NULL DEFAULT 'pending',
    real_name TEXT,                   -- PII AES-256-GCM
    phone TEXT,                       -- PII AES-256-GCM
    id_number TEXT,                   -- PII AES-256-GCM
    guardian_declaration TEXT,        -- PII AES-256-GCM
    apply_reason TEXT,
    reject_reason TEXT,
    registered_from TEXT,
    created_by TEXT,
    created_at TEXT NOT NULL,
    approved_at TEXT,
    permissions TEXT DEFAULT '{}'
);
```

### 2.20 `admin_audit_log`

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
```

### 2.21 `guardian_assignments`

```sql
CREATE TABLE guardian_assignments (
    id TEXT PRIMARY KEY,
    guardian_admin_id TEXT NOT NULL,
    student_user_id TEXT NOT NULL,
    bind_key TEXT NOT NULL,           -- SHA-256 哈希
    assigned_by TEXT,
    assigned_at TEXT NOT NULL,
    is_active INTEGER DEFAULT 1,
    UNIQUE(guardian_admin_id, student_user_id)
);
```

### 2.22 `subscription_requests`

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
```

---

## 三、2026-06-02 新增发现

### 3.1 `cards` 表关联断裂问题

**现状**：三类卡片入库时的关联数据不一致。

| 卡片来源 | 代码位置 | conversation_id | plan_type/plan_id | plan_task_id |
|---------|----------|:---:|:---:|:---:|
| K12 预生成 | routes.rs:1963 | ✅ 有 | ❌ 无 | ❌ 无 |
| CP1 概念提取 | ws.rs:528 | **❌ 无** | ❌ 无 | ❌ 无 |
| 阅读模式 | routes.rs:2184 | ✅ 有 | ❌ 无 | ⚠️ 写入但表已删 |

**结论**：
- CP1 卡片与会话/计划完全断开，无法按计划筛选
- `plan_task_id` 指向的 `learning_plan_tasks` 表已删除，成为虚悬列
- 生产代码（ws.rs:528）写 `status='pending'`，但测试 schema 无此列

### 3.2 建议修复方向

给 `cards` 表加 `plan_type TEXT, plan_id TEXT` 两列：

| plan_type | plan_id 指向 | 适用场景 |
|-----------|-------------|---------|
| `'k12'` | `learning_plans.id` | K12 入口全部卡片 |
| `'cp2'` | `conversation_plans.id` | 自由对话 CP1/CP2 卡片 |
| `'reading'` | `learning_plans.id` | 阅读模式卡片 |

前端即可直接 `SELECT * FROM cards WHERE plan_type = ? AND plan_id = ?` 按计划筛选，不再需要跨表 join。

### 3.3 已知 DDL 不一致

| 问题 | 生产 | 测试 schema (SCHEMA_SQL) |
|------|------|------------------------|
| `cards.status` | ✅ 有（Phase N 添加） | ❌ 缺失 |
| `cards.plan_task_id` | ⚠️ 虚悬列（指向已删表） | ❌ 缺失 |
| FK ON DELETE CASCADE | ✅ 多处 | ❌ 缺失 |
| NOT NULL + CHECK 约束 | ✅ 多处 | ❌ 缺失（多数列可空） |

---

## 四、V2.1 架构图

```
V2.1 最终架构：

                    plan_templates (15行, 共享)
                    subject_key + grade_band UNIQUE
                    plan_content JSON (stages→tasks)
                          │
            ┌─────────────┴─────────────┐
            │ K12 init                  │ CP2 (plan_handler)
            ▼                           ▼
┌─────────────────────┐   ┌────────────────────────────┐
│ conversations       │   │ conversations              │
│ subject, grade_band │   │ 自由对话, 无 K12 标记      │
└─────────┬───────────┘   └──────────────┬─────────────┘
          │ conversation_id              │ conversation_id
          ▼                              ▼
┌─────────────────────┐   ┌────────────────────────────┐
│ learning_plans      │   │ conversation_plans          │
│ K12 plan (将废弃)   │   │ CP2 动态计划               │
│ plan_content        │   │ plan_content (LLM 生成)    │
│ task_status JSON    │   │                            │
└─────────┬───────────┘   └──────────────┬─────────────┘
          │ plan_id                      │ plan_id
          ▼                              ▼
┌──────────────────────────────────────────────────────┐
│ user_plan_progress                                    │
│ plan_type='k12'|'cp2', plan_id, task_key, status     │
│ UNIQUE(plan_id, task_key)                             │
└──────────────────────────────────────────────────────┘
          │ plan_type + plan_id（建议添加）
          ▼
┌──────────────────────────────────────────────────────┐
│ cards                                                 │
│ conversation_id, plan_type?, plan_id?, subject        │
│ status='active'|'pending'|'skipped'|'archived'       │
│ origin='extracted'|'prebuilt'                         │
│ ┌──────────────────────────────────────────────────┐  │
│ │ K12 预生成: conversation_id ✅, subject ✅      │  │
│ │ CP1 提取:    conversation_id ❌, subject ❌      │  │
│ │ 阅读模式:    conversation_id ✅, plan_task_id ⚠️│  │
│ └──────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

---

## 五、关键决策记录

| 决策 | 结论 | 日期 |
|------|------|------|
| `cards` 加 `plan_type` + `plan_id` | 待实施 | 2026-06-02 |
| `cards.status` 已有（Phase N） | 确认 | 2026-06-02 |
| `plan_task_id` 虚悬列处理 | 因 `learning_plan_tasks` 已删，代码写入被挂起 | 2026-06-02 |
| CP1 卡片加 `conversation_id` | 待实施（ws.rs:529 INSERT 缺此列） | 2026-06-02 |
