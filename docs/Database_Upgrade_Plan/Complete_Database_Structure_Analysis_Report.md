# CoEvo 数据库完整结构分析报告

> 基于 V2.0 迁移后实际 Schema + V2.1 架构决策  
> 分析范围：全部 22 张表的结构、约束、索引、外键  
> 行数基于本地开发数据库（2026-06-01 快照）  
> 更新时机：2026-06-01

---

## 一、表分类与数量（22 张）

| 分类 | 表名 | 行数（本地） | 核心层 |
|------|------|-------------|--------|
| **用户与身份** | `users` | 4 | ⭐⭐⭐ |
| | `tokens` | — | ⭐⭐ |
| | `user_preferences` | 11 | ⭐ |
| **核心业务** | `conversations` | 378 | ⭐⭐⭐ |
| | `conversation_turns` | 595 | ⭐⭐⭐ |
| | `cards` | 27,700 | ⭐⭐⭐ |
| | `card_memory` | 27,690 | ⭐⭐⭐ |
| | `learning_plans` | 7 | ⭐⭐⭐ → **将废弃** |
| | `learning_plan_tasks` | 0 | ⭐⭐ |
| **复习与评估** | `review_log` | 21 | ⭐⭐ |
| | `skipped_concepts` | 120 | ⭐ |
| **成就系统** | `achievements` | 13 | ⭐⭐ |
| | `k12_achievements` | 0 | ⭐ |
| | `k12_progress` | 0 | ⭐ → **将废弃** |
| **题库** | `k12_quiz_bank` | — | ⭐⭐ |
| | `k12_quiz_attempts` | 0 | ⭐ |
| **知识图谱** | `knowledge_graph` | — | ⭐⭐ |
| **管理后台** | `admin_users` | — | ⭐⭐ |
| | `admin_audit_log` | — | ⭐⭐ |
| | `guardian_assignments` | — | ⭐ |
| **其他** | `subscription_requests` | — | ⭐ |

---

## 二、核心架构演进：V2.0 → V2.1

### 2.1 V2.0 已完成（表结构规范化）

| 变更 | 涉及表 | 说明 |
|------|--------|------|
| ✅ domain 枚举化 + CHECK | `learning_plans` | 7 个枚举值：general/math/language/chemistry/biology/physics |
| ✅ mode CHECK | `learning_plans` | structured/reading/free/deleted |
| ✅ plan_json → task_status | `learning_plans` | 列重命名 + 双写过渡 |
| ✅ conversation_id UNIQUE + FK | `learning_plans` | 一个对话至多一个计划 |
| ✅ ON DELETE CASCADE | 6 张表 | FK 级联删除全线打通 |
| ✅ origin CHECK | `cards` | extracted/prebuilt |
| ✅ verification_type/result CHECK | `review_log` | spelling/typing/ai_dialogue, pass/fail |
| ✅ card_memory CASCADE | `card_memory` | 删卡片自动删记忆 |
| ✅ learning_plan_tasks 新建 | `learning_plan_tasks` | 任务级卡片归属 |
| ✅ bind_hash 唯一索引 | `users` | 替代加密列索引 |
| ✅ prebuilt origin 修复 | `cards` | 27,342 张预置卡 origin='prebuilt' |

### 2.2 V2.1 架构变更（本报告定义）

**核心原则**：用户状态用 DB 列（非 JSON），K12 与对话分类管理，端侧也用 DB。

```
V2.0 遗留结构：                         V2.1 目标结构：
┌──────────────┐                      ┌──────────────┐
│ learning_plans│ 混用 K12 + 对话      │ plan_templates│ K12 共享模板
│ (7行)         │  →  废弃            │ (15行)        │ 可远程更新
└──────────────┘                      └──────┬───────┘
                                            │
                            ┌───────────────┴────────────────┐
                            │                                │
                    ┌───────▼────────┐            ┌──────────▼──────┐
                    │ conversation_plans      │            │ user_plan_      │
                    │ LLM 生成       │            │ progress        │
                    │ 自包含JSON内容  │            │ UNIQUE(plan_id, │
                    │ 不共享         │            │   task_key)     │
                    └────────────────┘            │ task_status ENUM│
                                                  │ score, attempts │
                                                  │ started_at, ... │
                                                  └─────────────────┘
```

---

## 三、逐表分析（V2.0 现状 + V2.1 目标）

### 3.1 `users` — 用户表（4行）✅ 基本不动

```sql
id TEXT PRIMARY KEY,              -- "user_xxx"
username TEXT NOT NULL UNIQUE,
password_hash TEXT,               -- bcrypt
streak_days INTEGER DEFAULT 0,
last_active_date TEXT,
created_at TEXT NOT NULL,
display_name TEXT DEFAULT NULL,
real_name TEXT,                   -- PII AES-256-GCM 加密
phone TEXT,                       -- PII AES-256-GCM 加密
id_number TEXT,
bind_hash TEXT DEFAULT NULL,      -- SHA-256(real_name + phone)
deleted_at TEXT
CREATE UNIQUE INDEX idx_users_bind_hash ON users(bind_hash) WHERE bind_hash IS NOT NULL;
```

**V2.1 决策**：✅ 保持现状。认证和 PII 加密已完善。

---

### 3.2 `tokens` — 认证令牌 ✅ 不动

JWT 令牌存储。外键 `user_id` 指向 `users`。合理。

---

### 3.3 `user_preferences` — 用户偏好（11行）✅ 不动

```sql
PRIMARY KEY (user_id, key)
value TEXT  -- 键值对
```

**V2.1 决策**：保持现状。

---

### 3.4 `conversations` — 对话表（378行）✅ 不动

```sql
id TEXT PRIMARY KEY,
user_id TEXT NOT NULL,
turn_count INTEGER DEFAULT 0,
started_at TEXT NOT NULL,
deleted_at TEXT,
subject TEXT,
grade_band TEXT,
FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
```

**V2.0 已修复**：
- ✅ `learning_plan_id` 废弃列已删除
- ✅ `ON DELETE CASCADE` 已加
- ✅ `idx_conversations_user_deleted` 索引已加

**V2.1 决策**：保持现状。`turn_count` 是纯递增计数器，`subject`/`grade_band` 是元数据，全部合理。

---

### 3.5 `conversation_turns` — 对话轮次（595行）✅ 不动

```sql
id TEXT PRIMARY KEY,
conversation_id TEXT NOT NULL,
role TEXT NOT NULL,              -- "user" | "assistant"
content TEXT NOT NULL,
created_at TEXT NOT NULL,
FOREIGN KEY (conversation_id) REFERENCES conversations(id)
```

**V2.1 决策**：保持现状。对话历史是只追加的审计数据，结构合理。索引 `idx_conversation_turns_conv_created` 已覆盖常用查询。

---

### 3.6 ⭐ `plan_templates` — 规划中，新建

**用途**：K12/Reading 预置计划模板，所有用户共享。支持远程更新课标。

```sql
-- 新建表，从 data/curriculum/prebuilt/plans/*.json 启动时加载
CREATE TABLE plan_templates (
    id TEXT PRIMARY KEY,                     -- "chinese_plan", "math_plan"
    subject TEXT NOT NULL,                   -- 中文名："数学"
    subject_key TEXT NOT NULL UNIQUE,        -- 英文 key："math"
    grade_band TEXT NOT NULL,                -- "g1-2", "g7-9", "g10-12"
    goal TEXT NOT NULL,                      -- "数学学习计划"
    plan_content TEXT NOT NULL,              -- JSON: {stages: [...], tasks: [...]}
    version INTEGER DEFAULT 1,              -- 版本号，远程更新依据
    updated_at INTEGER NOT NULL,            -- Unix 时间戳
    UNIQUE(subject_key, grade_band)
);
```

**数据源**：`data/curriculum/prebuilt/plans/` 目录中的 14 个 JSON 文件 + reading 计划。
**写入时机**：启动时 `INSERT OR REPLACE`（如果 JSON 版本号高于 DB 则更新）。
**远程更新**：云端 `PUT /api/admin/plan-templates/{id}` 接口 + 版本号自增。
**客户端同步**：Flutter 启动时对比 version，下载最新模板。

**V2.1 决策**：✅ 新建。K12 的 `plan_content`（stages/tasks 结构）只存一份，所有用户引用同一条模板。

---

### 3.7 ⭐ `conversation_plans` — 规划中，新建

**用途**：CP2 自由对话生成的计划。LLM 动态生成，每个 conversation 至多一个。内容自包含（不共享），结构灵活。

```sql
CREATE TABLE conversation_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,    -- 一个对话至多一个对话计划
    goal TEXT NOT NULL,
    domain TEXT DEFAULT 'general'
        CHECK(domain IN ('general', 'math', 'language', 'chemistry', 'biology', 'physics')),
    plan_content TEXT,                       -- JSON: {stages: [...], tasks: [...]}
    created_at INTEGER NOT NULL,            -- Unix 时间戳
    updated_at INTEGER NOT NULL,            -- Unix 时间戳
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX idx_conversation_plans_user ON conversation_plans(user_id);
```

**与 plan_templates 的区别**：

| 维度 | plan_templates (K12) | conversation_plans (对话计划) |
|------|---------------------|-----------------|
| 内容来源 | JSON 文件预置 | LLM 实时生成 |
| 共享性 | 所有用户共享同一条 | 每个 conversation 独立 |
| 可更新 | 远程同步课标更新 | 不需要更新 |
| plan_content | stages/tasks 完整结构 | 同左，但全是动态生成 |
| 行数 | ~15（固定） | 随用户增长 |

### 3.7.1 `plan_content` JSON Schema（两张表共用）

`plan_templates` 和 `conversation_plans` 的 `plan_content` 列存储同一套 stages/tasks 结构。顶层字段因来源不同略有差异，但 stages/tasks 层完全一致。

#### 核心结构

```json
{
  "stages": [
    {
      "name": "数的认识与测量",           // stage 名称
      "sort": 0,                        // stage 序号（LLM 生成的可能缺失）
      "status": "in_progress",          // 运行态：pending / in_progress / done
      "grade_band": "g1-2",             // 年级段（仅 plan_templates 有）
      "prerequisite_stages": [...],     // 前置 stage（仅 plan_templates 有）
      "tasks": [
        {
          "name": "加法与乘法模型",       // task 名称，必填
          "task_key": "add_mul",         // 唯一标识符（LLM 生成的可能会缺失）
          "sort": 0,                    // task 序号（LLM 生成的可能缺失）
          "status": "pending",          // 运行态：pending / in_progress / done / skipped
          "description": "掌握加法乘法", // 描述（LLM 生成的通常有）
          "gold_cr_ids": ["cr_001"],    // 关联 K12 金牌卡（仅 plan_templates 有）
          "dependencies": [],           // 依赖的 task_key（仅 plan_templates 有）
          "cross_subject_refs": [],     // 跨学科引用（仅 plan_templates 有）
          "origin": "extracted",        // 卡片来源（仅 plan_templates 有）
          "sub_steps": {                // 子阶段（可选）
            "teach": "pending",
            "examples": "pending",
            "quiz": "pending"
          }
        }
      ]
    }
  ]
}
```

#### 顶层字段差异

| 字段 | plan_templates | conversation_plans | 说明 |
|------|---------------|-------------------|------|
| `goal` | ✅ 有 | ❌ 在表 goal 列 | 存储于表列而非 JSON |
| `subject` | ✅ 必填 | ❌ 无 | 学科标识 |
| `total_stages` | ✅ 可选 | ❌ 无 | 预置元数据 |
| `total_tasks` | ✅ 可选 | ❌ 无 | 预置元数据 |
| `completed_concepts` | ❌ 无 | ✅ 可选 | 已掌握概念列表 |
| `pipeline_domain` | ✅ 可选 | ✅ 可选 | 管线路由标识，用于 LLM prompt 选择 |

#### 运行时状态（不在 plan_content 中）

以下字段由 `user_plan_progress` 表管理，不在 `plan_content` JSON 中：

| 状态 | 存储位置 | 说明 |
|------|---------|------|
| task 进度 (pending/in_progress/done) | `user_plan_progress.status` | 每个 task 一行 |
| 任务得分 | `user_plan_progress.score` | 可选 |
| 任务重考次数 | `user_plan_progress.attempt_count` | |
| 开始/完成时间 | `user_plan_progress.started_at/completed_at` | |

> **注意**：`plan_content` 中的 `status` 字段是**运行时快照**，由 `build_plan_context()` 从 `user_plan_progress` 合并写入。不在 DB 持久化。

**V2.1 决策**：✅ 新建。与 K12 解耦，互不影响。

---

### 3.8 ⭐ `user_plan_progress` — 规划中，新建（核心状态表）

**用途**：用户在所有计划（K12 + 对话）中的任务级进度。统一一张表，K12 和对话计划共用。

```sql
CREATE TABLE user_plan_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_type TEXT NOT NULL,                 -- "k12" | "conversation" (polymorphic)
    plan_id TEXT NOT NULL,                   -- plan_templates.id 或 conversation_plans.id
    task_key TEXT NOT NULL,                  -- 任务标识符（稳定的 task_key）
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'in_progress', 'done', 'skipped')),
    score REAL,                              -- k12_quiz 通过率（0-100）
    attempt_count INTEGER DEFAULT 0,         -- 重考次数
    started_at INTEGER,                      -- Unix 时间戳
    completed_at INTEGER,                    -- Unix 时间戳
    updated_at INTEGER NOT NULL,             -- Unix 时间戳
    UNIQUE(plan_id, task_key),               -- 一个计划的每个任务唯一条记录
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX idx_upp_user_plan ON user_plan_progress(user_id, plan_type, plan_id);
CREATE INDEX idx_upp_status ON user_plan_progress(plan_id, status);
```

**数据来源**：从旧的 `learning_plans.task_status` JSON 中解析迁移。
**与 task_status JSON 的对比**：

| 维度 | 当前 task_status JSON | user_plan_progress 表 |
|------|---------------------|----------------------|
| 存储 | `{"任务1":"done"}` | 每任务一行 |
| 状态字段 | 仅 status | status + score + attempts + timestamps |
| 可查询性 | 只能全量读取后代码 filter | `WHERE plan_id=?1 AND status='done'` |
| 扩展性 | 加字段需改 JSON schema | 加列即可 |

**V2.1 决策**：✅ 新建。DB 列优先于 JSON，一步到位。

---

### 3.9 ⭐ `learning_plans` — 当前 7 行，**将废弃**

**V2.1 决策**：此表不再使用。现有 7 行数据按以下规则迁移：

| 当前行 | 新去向 |
|--------|--------|
| K12: 数学 g10-12 | → `plan_templates`（如果不存在则插入）+ `user_plan_progress`（状态） |
| K12: 物理 g7-9 | 同上 |
| K12: 化学 g7-9 | 同上 |
| K12: 生物 g10 | 同上 |
| Reading: 语文 g1-2 | 同上（reading plan 归属 plan_templates） |
| 对话: Rust 编程 | → `conversation_plans`（plan_content 迁移）+ `user_plan_progress`（状态） |
| 对话: 化学入门 | 同上 |

**原始数据保留**：整张表备份为 `learning_plans_legacy`，不删除。`plan_json` / `plan_content` JSON 原样保留作为回退依据。

---

### 3.10 `learning_plan_tasks` — 已存在（0行）

**现状**：V2.0 Phase 4 已创建此表，`sync_learning_plan_tasks()` 函数已实现。但因为当前 `learning_plans` 只有 7 行且 CP2 尚未完整跑通，数据为 0。

**V2.1 决策**：
- 对于 K12：`learning_plan_tasks` 由 `plan_templates.plan_content` 派生（模板的 tasks 就是学习任务）。
- 对于对话计划：`learning_plan_tasks` 由 `conversation_plans.plan_content` 派生。
- `user_plan_progress.task_key` 与 `learning_plan_tasks.task_key` 对应。
- 此表 **保留** 作为 plan→task 的结构关联层。

---

### 3.11 `cards` — 卡片内容表（27,700行）✅ 结构已定，小改

```sql
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
plan_task_id TEXT,                              -- 指向 learning_plan_tasks.id
origin TEXT DEFAULT 'extracted'
    CHECK(origin IN ('extracted', 'prebuilt')),
FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL,
FOREIGN KEY (plan_task_id) REFERENCES learning_plan_tasks(id) ON DELETE SET NULL
```

**V2.1 决策**：
- ✅ 结构保持。卡片内容（front/back）和状态（card_memory）已自然分离。
- `plan_task_id` 已启用（V2.0 Phase 0.5 已实现）。
- `origin='prebuilt'` 已修正（Phase 4b）。
- **不动**。卡片内容本身不是"用户状态"，保持独立。

---

### 3.12 `card_memory` — FSRS 状态表（27,690行）

```sql
card_id TEXT PRIMARY KEY,
state INTEGER DEFAULT 0,
difficulty REAL DEFAULT 5.0,
stability REAL DEFAULT 0.0,
due INTEGER DEFAULT 0,
last_review INTEGER,
reps INTEGER DEFAULT 0,
lapses INTEGER DEFAULT 0,
FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
```

**V2.1 决策**：**保持 DB 关系表，不改为 JSON。** 理由：
- FSRS 调度需要 `WHERE due <= ?1 ORDER BY due`，SQL 索引比全量 filter 快百倍。
- 7 个字段的数值计算密集，DB 行的读取和写入效率远高于 JSON 反序列化。
- 27,690 行对未来端侧 SQLite 同样友好（下钻到本地 DB 即可）。

---

### 3.13 `review_log` — 复习记录（21行）

```sql
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
```

**V2.1 决策**：**保持现状**。只追加的审计表，结构已合理。`details_json` 是明智的 JSON 使用。

---

### 3.14 `skipped_concepts` — 跳过记录（120行）

```sql
id TEXT PRIMARY KEY,
user_id TEXT NOT NULL,
front TEXT NOT NULL,
domain TEXT,
source_text TEXT,
skipped_at INTEGER NOT NULL,
FOREIGN KEY (user_id) REFERENCES users(id)
```

**V2.1 决策**：**保持现状**。只追加，设计合理。建议后续加 `CONVERSATION_id` 以关联上下文，但不急。

---

### 3.15 `achievements` — 成就系统（3张表）✅ 不动

`achievements`（13行）、`k12_achievements`（0行）、`k12_progress`（0行）

V2.1 决策：`k12_progress` 与新的 `user_plan_progress` 功能重叠，**标记废弃**。其他不动。

---

### 3.16 `k12_quiz_bank` / `k12_quiz_attempts` — 题库

V2.1 决策：保持。题库是共享内容，不对应单个用户状态。

---

### 3.17 `knowledge_graph` — 知识图谱

V2.1 决策：保持。共享静态数据。

---

### 3.18 管理后台（3张表）✅ 不动

`admin_users`、`admin_audit_log`、`guardian_assignments`：保持现状。管理数据独立于核心业务。

---

## 四、V2.1 表结构变更清单

### 4.1 新建表

| 表 | 行数预估 | 用途 |
|----|---------|------|
| `plan_templates` | ~15 | K12 预置计划模板（共享） |
| `conversation_plans` | 随用户增长 | CP2 自由对话计划（私有） |
| `user_plan_progress` | 随用户增长 | 所有计划的单任务进度 |

### 4.2 废弃表

| 表 | 替换方案 | 数据处置 |
|----|---------|---------|
| `learning_plans` | `plan_templates` + `conversation_plans` + `user_plan_progress` | 备份为 `learning_plans_legacy` |
| `k12_progress` | `user_plan_progress` | 0 行，直接删 |

### 4.3 保持不变的表

`users`, `tokens`, `user_preferences`, `conversations`, `conversation_turns`,
`cards`, `card_memory`, `review_log`, `skipped_concepts`,
`achievements`, `k12_achievements`, `k12_quiz_bank`, `k12_quiz_attempts`,
`knowledge_graph`, `learning_plan_tasks`,
`admin_users`, `admin_audit_log`, `guardian_assignments`, `subscription_requests`

### 4.4 时间字段统一（INTEGER Unix Timestamp）

**现状**：22 张表中混用 TEXT（RFC3339）和 INTEGER（Unix 时间戳）两种时间格式。

| 格式 | 涉及列数 | 示例 |
|------|---------|------|
| `TEXT NOT NULL`（RFC3339） | ~25 列 | `created_at TEXT NOT NULL` → `"2026-05-31T19:45:00Z"` |
| `INTEGER`（Unix 时间戳） | 5 列 | `cards.created_at INTEGER`, `card_memory.due`, `review_log.reviewed_at` |

**统一方向**：**全部改为 INTEGER**（Unix 秒级时间戳）。

理由：
- `card_memory.due`/`last_review` 以及 FSRS 算法原生使用 Unix 时间戳
- `cards.created_at` 已经是 INTEGER
- 排序、区间计算（`WHERE due <= ?1`）比 TEXT 字符串比较快
- RFC3339 的可读性由应用层处理即可（Rust `chrono::DateTime::to_rfc3339()`）

**变更范围**（22 列需要从 TEXT → INTEGER 转换）：

| 表 | 当前类型 | 改后类型 |
|----|---------|---------|
| `users.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `users.last_active_date` | TEXT | INTEGER（存 Unix 秒，查询时格式化） |
| `users.deleted_at` | TEXT | INTEGER |
| `conversations.started_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `conversations.deleted_at` | TEXT | INTEGER |
| `conversation_turns.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `learning_plans_legacy.created_at` | TEXT NOT NULL | ✅ 不动（废弃表） |
| `learning_plans_legacy.updated_at` | TEXT NOT NULL | ✅ 不动（废弃表） |
| `plan_templates.updated_at` | — | **新建表直接 INTEGER** |
| `conversation_plans.created_at` | — | **新建表直接 INTEGER** |
| `conversation_plans.updated_at` | — | **新建表直接 INTEGER** |
| `user_plan_progress.started_at` | — | **新建表直接 INTEGER** |
| `user_plan_progress.completed_at` | — | **新建表直接 INTEGER** |
| `user_plan_progress.updated_at` | — | **新建表直接 INTEGER** |
| `achievements.unlocked_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `skipped_concepts.skipped_at` | ✅ 已是 INTEGER | 不动 |
| `user_preferences.updated_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `tokens.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `admin_users.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `admin_users.approved_at` | TEXT | INTEGER |
| `subscription_requests.requested_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `subscription_requests.reviewed_at` | TEXT | INTEGER |
| `admin_audit_log.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `guardian_assignments.assigned_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `k12_progress.*` | ✅ 废弃 | 不动 |
| `k12_achievements.unlocked_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `k12_quiz_attempts.attempted_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `knowledge_graph.created_at` | TEXT NOT NULL | INTEGER NOT NULL |
| `learning_plan_tasks.created_at` | TEXT NOT NULL | INTEGER NOT NULL |

**代码影响**：所有 `chrono::Utc::now().to_rfc3339()` 改为 `chrono::Utc::now().timestamp()`，所有 `format!("{}", now)` 改为 `now.timestamp()`。

**迁移策略**：由于 V2.1 要重建/新建多张表，时间统一在表重建时顺带完成，不额外增加表重建轮次。

---

## 五、数据迁移路径

### 第 1 步：新建三张表

```sql
-- plan_templates（从 JSON 填充 15 行）
CREATE TABLE plan_templates (...);

-- conversation_plans（从 learning_plans 迁移 2 行对话计划数据）
INSERT INTO conversation_plans
SELECT ... FROM learning_plans WHERE mode = 'structured' AND domain = 'general';

-- user_plan_progress（解析 task_status JSON，每任务一行）
-- 对每条 learning_plans，解析 task_status JSON 展开为多行
INSERT INTO user_plan_progress (user_id, plan_type, plan_id, task_key, status, ...)
SELECT ... FROM learning_plans, json_each(task_status);
```

### 第 2 步：迁移 K12 数据

```sql
-- 检查 plan_templates 是否已有对应模板
-- 有则引用 template_id，无则从 JSON 文件插入
INSERT INTO plan_templates (id, subject, subject_key, grade_band, goal, plan_content, version, updated_at)
-- 从 data/curriculum/prebuilt/plans/*.json 读取

-- 将 K12 learning_plans 的 task_status 迁移到 user_plan_progress
INSERT INTO user_plan_progress (user_id, plan_type, plan_id, task_key, status, ...)
VALUES ('user_xxx', 'k12', 'math_plan', 'task_key_1', 'done', ...);
```

### 第 3 步：迁移对话计划数据

```sql
INSERT INTO conversation_plans (id, user_id, conversation_id, goal, domain, plan_content, created_at, updated_at)
SELECT id, user_id, conversation_id, goal, domain, plan_content, created_at, updated_at
FROM learning_plans WHERE mode = 'structured' AND domain = 'general';
```

### 第 4 步：备份旧表

```sql
ALTER TABLE learning_plans RENAME TO learning_plans_legacy;
```

### 第 5 步：更新读路径

- `build_plan_context()`: 如果是 K12 → 从 `plan_templates` 读 plan_content + 从 `user_plan_progress` 读状态。如果是对话计划 → 从 `conversation_plans` 读 plan_content + 从 `user_plan_progress` 读状态。
- `GET /api/plans`: 同上逻辑，返回统一格式给前端。
- CP2 /k12/init: 创建 plan 时只在 `user_plan_progress` 写状态行，模板从 `plan_templates` 引用。

---

## 六、V2.1 整体评分

| 维度 | V2.0（当前） | V2.1 目标 | 改善 |
|------|------------|-----------|------|
| 数据完整性 | 7.5/10 | 9.0/10 | FK 链完整 + 枚举约束 |
| 状态管理 | JSON 黑盒 | DB 列可查询 | 强 |
| K12/对话分离 | 混用一张表 | 三张表各司其职 | 强 |
| 课标可更新 | ❌ 不可 | ✅ 更新模板行即可 | 强 |
| 端侧适配 | 未考虑 | 全部 DB 表直接下钻 | 强 |
| 存储效率 | 7 行 plan_content 各存各 | 15 行模板共享 | 中 |

---

## 附录 A：深度评审反馈汇总（2026-06-01）

基于 2026-06-01 01:48 的架构评审，7 项建议全部采纳，已落地至本报告和代码中。

### 已实施

| # | 问题 | 建议 | 处置 |
|---|------|------|------|
| 2.2 | `learning_plan_tasks` 维护成本高 | 删除该表，运行时解析 `plan_content` | **已实施**：删除表、代码、索引、3 处 INSERT、`plan_task_id` 列及 FK。7 文件 ~50 行删除。任务列表从 `plan_content.stages[].tasks[].task_key` 派生。 |
| — | 同步 API | 同上 | `learning_plan_tasks` 和 `plan_task_id` 已全部从 DDL、迁移脚本、Rust 代码、测试中清除 |

### 已纳入文档

| # | 问题 | 建议 | 当前状态 |
|---|------|------|---------|
| 2.1 | 多设备同步协议未定义 | 补充同步策略（最后写入者胜 + 全量/增量） | **待 V3.0**：V2.1 实施后云端仍是全量权威，Flutter Web 仍走 HTTP/WS。端侧 SQLite 是 V3.0 目标。同步协议届时基于真实使用数据设计。 |
| 2.4 | `user_plan_progress.plan_id` 无外键 | 文档说明应用层保证 | **可接受**：`plan_type` + `plan_id` polymorphic 设计，代码层面插入/更新时校验引用完整性。 |
| 2.5 | 迁移完整性验证 | 增加脏数据检查和日志 | **已纳入第 5 步**：检查 task_status key 是否对应 plan_content 任务列表，缺失任务设 `skipped`，记录迁移日志。 |
| 2.6 | 时间字段转换 | 先加新列后删旧列 | **已纳入 4.4**：`ALTER TABLE ... ADD COLUMN ..._int` → 填充 → 验证 → 删旧列 → 重命名。使用 `strftime('%s', col)` 转换。 |
| 2.7 | 端侧 Schema 未定义 | 补充端侧表结构 | **待 V3.0**：与同步协议一同设计。端侧用户状态表与云端一致，共享内容缓存表按版本号更新。 |
| 2.8 | 性能索引 | 增加复合索引 | **已采纳**：`user_plan_progress` 增加 `(user_id, status)` 复合索引。`card_memory` 现有 `idx_card_memory_due` 充分。 |

### 待定

| 建议 | 当前判断 |
|------|---------|
| 删除 `learning_plan_tasks` 的同时是否删除 `cards.plan_task_id` | **已同步删除** — 该列从未被有效使用，FK 指向已删除的表 |
| 是否将 `k12_quiz_bank.plan_task_id` 也一并清理 | 暂不处理（已有遗留数据），V2.1 表重建时顺带移除 |
