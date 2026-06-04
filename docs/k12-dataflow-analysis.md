# K12 学习数据流分析报告

> 生成日期: 2026-06-04
>
> 背景: 修复 K12 plan 面板不显示问题过程中发现数据流设计问题。经讨论，核心洞察为：
> **K12/Reading = 带预制 plan 的自由对话**，无需通过 `subject` 字段区分。

---

## 一、涉及的表（重构后）

| 表 | 用途 | 谁写入 | 谁读取 |
|:---|:-----|:-------|:-------|
| `conversations` | 会话元数据 | **WS 唯一写入** | `build_plan_context` / `history_handler` |
| `conversation_plans` | 会话绑定的计划（**所有类型统一存储**） | `k12_init` / `reading_init` / CP2 | `build_plan_context` / `plans_list_handler` |
| `user_plan_progress` | 用户进度（每个 task 状态） | `plan_mutation_writer` | `build_plan_context` |

> **`plan_templates` 表 → 废弃**。

### 1.1 统一 ID 原则

**所有主键、外键、关联字段统一使用 UUID v4**。没有 `user_` 前缀、没有截断、没有语义编码。

### 1.2 完整表定义

#### `users` — 用户（统一身份）

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,              -- UUID v4
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    role TEXT NOT NULL DEFAULT 'student'
        CHECK(role IN ('student', 'tutor', 'guardian')),
    status TEXT NOT NULL DEFAULT 'active',
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT DEFAULT NULL,
    real_name TEXT DEFAULT NULL,
    phone TEXT DEFAULT NULL,
    id_number TEXT DEFAULT NULL,      -- 保留但不写入，未来使用必须先加密
    bind_hash TEXT DEFAULT NULL,
    deleted_at TEXT DEFAULT NULL,
    created_at TEXT NOT NULL
);
```

> **家长 (`guardian`) 和辅导老师 (`tutor`) 从 `admin_users` 移入 `users`**。绑定后通过 `guardian_assignments` 获取学生 `user_id`，所有查询直接用学生的 `user_id` 参数，无需特殊权限代码。
>
> 登录入口统一到 `/api/auth/login`，前端登录页支持切换三种身份（`student`/`tutor`/`guardian`）。`/api/admin/login` 仅保留给 `super`/`service` 使用。

#### `admin_users` — 后台管理员（仅运营人员）

```sql
CREATE TABLE admin_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'pending'
        CHECK(role IN ('super', 'service')),  -- 不再包含 tutor/guardian
    status TEXT NOT NULL DEFAULT 'pending',
    real_name TEXT,
    phone TEXT,
    ...
);
```

#### `tokens` — 认证令牌（id/token 用 UUID）

```sql
CREATE TABLE tokens (
    id TEXT PRIMARY KEY,              -- UUID v4
    user_id TEXT NOT NULL,             -- UUID v4, FK → users.id
    token TEXT NOT NULL,               -- UUID v4
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

#### `conversations` — 会话（WS 唯一写入）

```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,              -- UUID v4
    user_id TEXT NOT NULL,             -- UUID v4, FK → users.id
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    deleted_at TEXT,
    -- ❌ subject 删除（不再依赖）
    -- ❌ grade_band 删除（不再依赖）
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

#### `conversation_turns` — 对话轮次（不变）

```sql
CREATE TABLE conversation_turns (
    id TEXT PRIMARY KEY,              -- UUID v4
    conversation_id TEXT NOT NULL,     -- UUID v4, FK → conversations.id
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
```

#### `cards` — 卡片（所有类型统一存储）

```sql
CREATE TABLE cards (
    id TEXT PRIMARY KEY,              -- UUID v4
    user_id TEXT NOT NULL,             -- UUID v4, FK → users.id
    domain TEXT,                       -- 领域 (math/chinese/english...)
    card_type TEXT NOT NULL,           -- 'vocabulary' / 'concept' / 'reading' / 'poem' / 'sentence_pattern' / 'timeline' / 'rule' / 'skill' / 'relationship' / 'writing' / 'dialogue'
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    conversation_id TEXT,              -- UUID v4, FK → conversations.id
    status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active', 'pending', 'skipped', 'archived')),
    plan_id TEXT,                     -- UUID v4, FK → conversation_plans.id
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL,
    FOREIGN KEY (plan_id) REFERENCES conversation_plans(id) ON DELETE SET NULL
);
```

> 清理了 7 个冗余/过渡字段：`subject`（domain 已覆盖）、`grade_band`（可从 plan 推导）、`k12_card_id`、`gold_cr_id`、`origin`、`plan_type`、`stage_name`、`plan_task_id`。运行时不依赖这些字段。

> **`back` 字段支持结构化 JSON**：`card_type` 为 `reading` / `poem` 等复杂类型时，`back` 可存 JSON 而非纯文本。前端/LLM 根据 `card_type` 决定解析方式：
> ```json
> // reading 卡的 back 示例
> {"full_text": "横看成岭侧成峰...",
>  "author": "苏轼", "dynasty": "北宋",
>  "famous_lines": ["不识庐山真面目..."],
>  "technique": ["借景说理", "对比"],
>  "theme": "当局者迷，旁观者清"}
> ```
> vocabulary / concept 等简单卡继续保持纯文本格式。

#### `card_memory` — FSRS 复习状态（不变）

```sql
CREATE TABLE card_memory (
    card_id TEXT PRIMARY KEY,          -- UUID v4, FK → cards.id
    state INTEGER DEFAULT 0,
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
```

#### `review_log` — 复习日志（不变）

```sql
CREATE TABLE review_log (
    id TEXT PRIMARY KEY,              -- UUID v4
    card_id TEXT NOT NULL,             -- UUID v4, FK → cards.id
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL
        CHECK(verification_type IN ('spelling', 'typing', 'ai_dialogue')),
    verification_result TEXT NOT NULL
        CHECK(verification_result IN ('pass', 'fail')),
    reviewed_at INTEGER NOT NULL,
    details_json TEXT,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
```

#### `conversation_plans` — 计划（重构核心）

```sql
CREATE TABLE conversation_plans (
    id TEXT PRIMARY KEY,              -- UUID v4
    user_id TEXT NOT NULL,             -- UUID v4, FK → users.id
    conversation_id TEXT NOT NULL UNIQUE,  -- UUID v4, FK → conversations.id
    goal TEXT NOT NULL,
    plan_content TEXT,                 -- JSON（不再含 status，见 4.1 最终版 schema）
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    -- ❌ domain 删除（不再需要）
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

`plan_content` 中的 JSON 结构：

```json
{
  "goal": "学习计划",

  "stages": [
    {
      "name": "阶段名称",
      "sort": "01",                 // 两位数 stage 序号（同时作为 task_key 前缀）

      "tasks": [
        {
          "name": "任务名称",
          "task_key": "01-03",       // {stage.sort}-{task 位置:02d}

          "prompt_mode": "chinese/reading-nursery",  // {subject}/{type}

          // ── 卡片关联（全部用卡片 UUID） ──
          "card_ids": [
            "550e8400-e29b-41d4-a716-446655440000"
          ],

          // ── 教学辅助信息（可选） ──
          "focus": "入学教育·国家认同"
        },
        { "name": "任务二", "task_key": "01-02", ... }
      ]
    },
    {
      "name": "第二学段",
      "sort": "02",
      "tasks": [...]
    }
  ]
}
```

**关键原则**：
- **`plan_content` 只存结构，不存状态**。`status` 统一由 `user_plan_progress` 管理
- `stages[].sort` 是两位数序号 `"01"`，同时作为 `task_key` 的前缀。task 无 `sort`，位置由数组隐式决定
- 所有卡片引用统一用 **UUID**，运行时 `WHERE id IN (...)` 一条 SQL


#### `user_plan_progress` — 任务进度（状态唯一权威来源）

```sql
CREATE TABLE user_plan_progress (
    id TEXT PRIMARY KEY,              -- UUID v4
    user_id TEXT NOT NULL,             -- UUID v4, FK → users.id
    plan_id TEXT NOT NULL,            -- UUID v4, FK → conversation_plans.id
    task_key TEXT NOT NULL,            -- "{stage:02d}-{task:02d}": "01-03"
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'in_progress', 'done')),
    score REAL,
    attempt_count INTEGER DEFAULT 0,
    started_at INTEGER,
    completed_at INTEGER,
    updated_at INTEGER NOT NULL,
    -- ❌ plan_type 删除（已统一归入 conversation_plans）
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (plan_id) REFERENCES conversation_plans(id) ON DELETE CASCADE,
    UNIQUE(plan_id, task_key)
);
```

### 1.3 废弃的表

```sql
-- ❌ plan_templates — 不再需要，V2.1 建表后从未写入数据
DROP TABLE IF EXISTS plan_templates;
```

### 1.4 注意

- `users.id_number` 当前仅在 `admin_users` 表使用（加密写入）。**`users` 表的 `id_number` 列保留但不写入数据，如未来需要使用必须先加密再存储。**
- `users.phone` 缺少格式校验和唯一性约束，见改动清单 #15。

---

## 二、核心洞察：K12 = 带预制 plan 的自由对话

**不需要 `conversations.subject` 字段**。结构化学习和自由对话的区别只在于：

```
自由对话 → conversation_plans 无记录（CP2 后才有）
K12      → conversation_plans 预制记录（init 时写入）
Reading  → conversation_plans 预制记录（init 时写入）
```

三者在底层是同一模型，只是计划来源不同：

```
conversations 表:
  WS 唯一写入，不区分类型

conversation_plans 表:
  (conversation_id, plan_content)   ← 1:1 绑定
  
  自由对话:   无 → CP2 后 INSERT
  K12 math:  k12_init INSERT（预置 JSON → plan_content）
  Reading 语文: reading_init INSERT（课文 JSON → plan_content）
```

`build_plan_context` 简化成：

```
查 conversation_plans WHERE conversation_id = ?
  → 有 → 结构化模式（无论 prebuilt 还是 CP2）
  → 无 → 自由对话模式（尚无计划）
```

---

## 三、用户使用路径

### 3.1 WS 是 conversations 的唯一写入入口

```
自由对话:
  客户端生成 conv_id → WS 连接
    → INSERT INTO conversations (id, user_id, turn_count, started_at)
    → build_plan_context: 查 conversation_plans → 无 → 自由对话流程

K12 科目:
  首页点击 → POST /api/k12/init
    → 插入预置卡片
    → INSERT INTO conversation_plans (预制 plan_content)
    → WS 连接 → INSERT OR IGNORE conversations（幂等）
    → build_plan_context: 查 conversation_plans → 有 → 结构化流程

语文阅读:
  首页点击 → POST /api/k12/reading/init
    → 插入课文卡片
    → INSERT INTO conversation_plans (预制 plan_content)
    → WS 连接 → 同上
```

> **k12_init / reading_init 不再 INSERT conversations**。conversations 只由 WS 统一写入。
> subject/grade_band 字段可删（不再依赖）。

---

## 四、统一 plan schema 设计

### 4.1 三源一体规划

三个来源（K12 预制、Reading 预制、CP2 生成）都存到 `conversation_plans.plan_content`（TEXT/JSON），**共用同一结构（见 1.2 `conversation_plans` 节）**。

### 4.2 `prompt_mode` → prompt 文件映射

`prompt_mode` 存 `"{subject}/{type}"` 组合键，直接对映 `prompts/chat/` 下的文件：

| prompt_mode 值 | 加载的文件 |
|:---------------|:-----------|
| `"general/free"` | `prompts/chat/general/free.md` |
| `"general/structured"` | `prompts/chat/general/structured.md` |
| `"math/structured"` | `prompts/chat/math/structured.md` |
| `"chinese/reading-nursery"` | `prompts/chat/chinese/reading-nursery.md` |
| `"chinese/reading-primary"` | `prompts/chat/chinese/reading-primary.md` |
| `"chinese/reading-secondary"` | `prompts/chat/chinese/reading-secondary.md` |
| `"english/reading-nursery"` | `prompts/chat/english/reading-nursery.md` |
| ... | 各科自有 |

`prompt_loader` 启动时扫描 `prompts/chat/` 目录建立 `HashMap<"{subject}/{type}", String>`，ws.rs 直接：

```rust
let prompt = prompt_loader.get(prompt_mode)
    .unwrap_or(templates.general_free);
```

**好处**：
- 零 match 代码，新增 prompt 文件放进去就能用
- `conversation_plans.domain` 可删（从 `prompt_mode.split('/')[0]` 推导）
- 各科可复用同名文件（`structured.md` 在每个科目下内容不同）

### 4.3 废弃/删除的字段

| 字段 | 来源 | 原因 |
|:-----|:------|:------|
| `sub_steps` | CP2 schema | 冗余，LLM 提示词已管理子阶段 |
| `dependencies` | K12 JSON | 零代码消费，`sort` 足够 |
| `cross_subject_refs` | K12 JSON | 几乎全空 |
| `origin` | K12 JSON | 保留不删，数据生成标记，用于溯源 |
| `gold_cr_ids` | K12 JSON | 非卡片 ID，init 时解析为具体卡片 UUID |
| `vocab_card_ids` | Reading JSON | 并入统一的 `card_ids` |
| `concept_card_ids` | Reading JSON | 并入统一的 `card_ids` |
| `reading_card_id` | Reading JSON | 并入统一的 `card_ids` |
| `mode`（旧） | Reading JSON | 更名为 `prompt_mode` 并提升为通用字段 |

### 4.4 卡片 ID 重构

**现状**：ID 格式混乱，grade 表述不统一（`senior`/`compulsory`/`g7-9`/`g10-12`），`_v` 后缀隐含 card_type，同文件内多种格式并存。

**方案**：全部改用 **UUID v4** 作为卡片 ID。`card_type` 存在 `cards` 表列中，不再编码到 ID 字符串里。

```
改前: english_senior_0000 / english_g10-12_v0000 / chinese_g7-9_v0947
改后: 550e8400-e29b-41d4-a716-446655440000
```

`cards` 表结构不变（已有 `card_type TEXT` 列），UUID 作为主键即可。

---

## 五、当前数据流问题总结

### 5.1 `plan_templates` 空表（已废弃）

V2.1 迁移只 CREATE TABLE，无 INSERT。之前 `build_plan_context` 的 K12 路径第一站就查不到。

**最终方案**：不用 `plan_templates`。所有 plan 统一用 `conversation_plans` 存储。

### 5.2 `conversation_plans` 职责过载

| 本应用途 | 实际用途 | 最终方案 |
|:---------|:---------|:---------|
| CP2 生成的自由对话计划 | ✅ 正确 | ✅ 保留 |
| K12/Reading 模板快照 | ❌ 不应存模板 | ✅ **统一存这里**（三源合一） |
| resumed 时的计划来源 | ❌ 写时缺 | ✅ 已修：resumed 路径补齐 plan |

### 5.3 卡片引用简化

**核心思路**：所有卡在同一个 `cards` 表，`card_ids` 就是 UUID 列表。

| 改动 | 位置 | 说明 |
|:-----|:-----|:------|
| 1 | 卡片 JSON 数据 | 全部改用 UUID 作为 id |
| 2 | `plan_handler.rs` 管道 A/B/C | 统一为一条 `WHERE id IN (?)` SQL |
| 3 | `k12_init` | `gold_cr_ids` 标签 → 解析为具体卡片 UUID 后写入 plan |
| 4 | `reading_init` | `vocab_card_ids` + `reading_card_id` 合并到 `card_ids` |
| 5 | `reading_loader` | 保留，但课文卡也入 `cards` 表，用 `card_type='reading'` |

---

## 六、`build_plan_context` 简化方案

```rust
build_plan_context(conn, conversation_id)
│
├── 查 conversation_plans WHERE conversation_id = ?
│   │
│   ├── ✅ 有 → 结构化模式（K12/Reading/CP2 统一处理）
│   │   └── 合并 user_plan_progress 中的进度
│   │
│   └── ❌ 无 → 自由对话模式（尚无计划）
│
└── 生成 LLM 上下文
```

不再需要 `conversations.subject` / `plan_templates` / 降级路径 / 分叉逻辑。

---

## 七、统一 conversations 写入方案

**WS 作为唯一入口**。k12_init / reading_init 只做两件事：

1. 插入预置卡片
2. 写入 `conversation_plans`（预制 plan）

```
k12_init 重构后:
  POST /api/k12/init
    → 1. 插入预置卡片到 cards 表
    → 2. INSERT INTO conversation_plans (预制 plan_content)
    → 返回 conv_id

reading_init 同理

WS 首次消息:
  INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at)
  → 无 subject/grade_band（字段可删）
```

---

## 八、改动清单

| # | 改动 | 位置 | 说明 |
|:-:|:-----|:-----|:------|
| 1 | **所有主键/外键统一 UUID v4** | schema.sql + 所有 .rs | `users.id`, `cards.id`, `conversations.id`, `conversation_plans.id`, `user_plan_progress.id`, `tokens.id` 全部 `uuid::new_v4()`。删除 `auth.rs:67` 的 `format!("user_{}", ...)` 写法 |
| 2 | 卡片 JSON ID 改用 UUID | 所有卡片 JSON 文件 | 不再有 `english_senior_0000`、`chinese_g7-9_v0947` 等 4 套命名体系 |
| 3 | `gold_cr_ids` 解析为卡片 UUID | `k12_init` | init 时遍历课标标签 → 匹配卡片 → 写入 UUID 列表到 `card_ids` |
| 4 | `vocab_card_ids` / `reading_card_id` 合并 | `reading_init` | 全部并入 `card_ids`，不再分别存储 |
| 5 | 删除 `plan_handler.rs` 管道 A/B/C | `plan_handler.rs` | 统一为 `WHERE id IN (?)` 单条 SQL |
| 6 | `k12_init` 删掉 INSERT conversations | `routes.rs` | WS 统一写入 |
| 7 | `reading_init` 删掉 INSERT conversations | `routes.rs` | 同上 |
| 8 | `plan_templates` 表废弃 | schema.sql | 不再需要 |
| 9 | `conversations.subject/grade_band` 字段删除 | schema.sql | 不再依赖 |
| 10 | `build_plan_context` 统一读 `conversation_plans` | `plan_handler.rs` | 删掉 `plan_templates` 查询 + subject 分叉逻辑 |
| 11 | `prompt_mode` 数据驱动 | `ws.rs` | 删掉 `ctx.contains("教学模式:")` + `grade_band` 猜测 |
| 12 | `mode` JSON 字段迁移 | reading JSON 文件 | `nursery_rhyme` → `reading_nursery`, `reading_first` → `reading_primary/secondary` |
| 13 | `task_key` 改为 `{stage:02d}-{task:02d}` | `plan_handler.rs` + init 代码 | 删掉 `plan_handler.rs:303-321` 规范化猜 key 逻辑。init 和 CP2 直接按位置计算 `"01-03"` |
| 14 | `focus` 字段保留，可选项 | `plan_content` JSON | 给 LLM 的明确指令提示，没有也完全可行，不增加复杂度 |
| 15 | **phone 加校验 + 唯一性** | `auth.rs` + schema.sql | 用户注册 phone 缺格式校验和 `UNIQUE(phone)` 约束 |
| 16 | **guardian/tutor 移入 `users` 表** | schema.sql + 所有代码 + 前端登录页 | 家长/老师从 `admin_users` 移入 `users`（加 `role` 字段：`student`/`tutor`/`guardian`），绑定后所有查询走学生 `user_id`。`admin_users` 只保留 `super`/`service`，`super` 由 seed 脚本创建，`service` 由 super admin 手动创建。**删除 `/api/admin/register` 自注册入口**。登录入口统一到 `/api/auth/login`，`/api/admin/login` 仅给 `super`/`service` |
| 17 | **清理 `cards` 表冗余字段** | schema.sql + 所有 INSERT/SELECT 代码 | 删除 `subject`、`grade_band`、`k12_card_id`、`gold_cr_id`、`origin`、`plan_type`、`stage_name`、`plan_task_id`。由 20 列精简为 11 列 |
| 18 | **plan_content 删除 tasks[].sort** | `plan_handler.rs` 规范化代码 + JSON 数据 | `stages[].sort` 改为字符串 `"01"`，同时作为 `task_key` 前缀。task 无 `sort`，顺序由数组位置隐式决定 |
| 19 | **`cards.back` 支持结构化 JSON** | 卡片 JSON 数据 + 读取代码 | `reading`/`poem` 等复杂卡片的 `back` 存 JSON（`full_text`, `author`, `theme` 等），通过 `card_type` 区分解析方式。vocabulary/concept 保持纯文本 |

---

## 九、数据迁移方案

### 9.1 核心原则

JSON 文件在迁移后存储**最终要写入 DB 的格式**，init 时直接复制到用户名下，零运行时转换。

### 9.2 旧 ID → UUID 映射

所有变迁通过 `id_mapping.json` 追踪，确保绑定关系不丢失。

```json
{
  "version": "1.0",
  "generated_at": "2026-06-04T16:00:00Z",
  "mapping": {
    "english_senior_0000":    "550e8400-e29b-41d4-a716-446655440000",
    "english_g10-12_v0000":   "550e8400-e29b-41d4-a716-446655440001",
    "chinese_g7-9_v0947":     "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "chinese_compulsory_0000":"6ba7b810-9dad-11d1-80b4-00c04fd430c9",
    "reading_primary_我是中国人": "6ba7b810-9dad-11d1-80b4-00c04fd430d0",
    ...
  }
}
```

### 9.3 迁移三步走

**第一步：准备阶段（纯计算，不写入）**

```
1. 遍历所有卡片 JSON（约 2.7 万张），每张分配 UUID
2. 建立 id_mapping.json（旧 ID → 新 UUID）
3. 遍历所有 plan JSON，用映射表将引用转为 card_ids
   - gold_cr_ids → 匹配 card.gold_cr_ids → 找到旧 ID → 映射为 UUID
   - vocab_card_ids → 直接查映射表（vocab 卡片 ID 是旧 ID）
   - reading_card_id → 直接查映射表
4. 验证：所有 card_ids 的 UUID 都能在卡片 JSON 中找到 ✅
5. 验证：所有卡片 JSON 的旧 ID 都唯一映射一个 UUID ✅
```

**第二步：重写卡片 JSON**

```
每张卡：
  id = 旧ID → UUID
  删除：gold_cr_ids、origin、plan_task_id（运行时不再需要）
  保留：id, card_type, front, back, subject, grade_band, domain, source_sentence
  reading/poem 卡：back 改为 JSON（full_text, author, theme, technique 等）
  vocabulary/concept 等：back 保持纯文本格式
  → 写回原文件（或新目录）
```

**第三步：重写 plan JSON**

```
每个 plan：
  删除：gold_cr_ids、vocab_card_ids、reading_card_id、concept_card_ids、origin、
        dependencies、cross_subject_refs
  替换为：card_ids = [UUID, UUID, ...]
  mode（旧字段）→ prompt_mode：
    mode=nursery_rhyme + subject=chinese → prompt_mode=chinese/reading-nursery
    mode=nursery_rhyme + subject=english → prompt_mode=english/reading-nursery
    mode=reading_first + grade g1-4 + subject=chinese → prompt_mode=chinese/reading-primary
    mode=reading_first + grade g5+ + subject=chinese → prompt_mode=chinese/reading-secondary
    K12 科目（无 mode）→ prompt_mode={subject}/structured
    自由对话 → prompt_mode=general/free
  新增：sort 字段（两位数 stage 序号）
  tasks[].sort 删除（由数组位置隐式决定）
  → 写回原文件
```

### 9.4 迁移 + 清理策略

**现有生产 DB：直接清库重来。** 当前所有用户数据均为测试/开发数据，无真实用户。新代码启动后运行新版 schema.sql，重新 init 即可。

**废弃代码和数据保留策略：**

```
阶段一（代码重构完成，首次验证）:
  保留: curriculum_loader, reading_loader, 原始 JSON 文件
  验证: 所有 e2e 测试通过，计划/卡片/对话功能正常

阶段二（验证通过后清理）:
  删除: curriculum_loader, reading_loader, 原始 JSON 文件
  删除: 全部 plans/*.json, cards/*.json, reading_plans/*.json
  删除: plan_templates 表相关代码
  删除: curriculum_loader GradedCard/CardData/PlanData 等结构体
```

> 之所以分两阶段：旧代码虽然过渡但经过了充分测试，能跑。新代码直接删掉 loaders，万一发现 bug 需要回查原始数据就困难了。先验证再清理。

| 维度 | 迁移前 | 迁移后 |
|:-----|:-------|:-------|
| 卡片 ID | `english_senior_0000` / `chinese_g7-9_v0947`（4 套命名） | `uuid::new_v4()`（统一） |
| plan 引用卡片 | `gold_cr_ids` 标签匹配 + `vocab_card_ids` 直接 ID | `card_ids: [UUID]` 统一 |
| init 时 | 加载 JSON → 解析 gold_cr_ids → 匹配卡片 → 写入 | 加载 JSON → 直接 INSERT（零转换） |
| 运行时找卡 | `curriculum_loader` 做复杂匹配 | `WHERE id IN (?)` |
| 过渡字段 | 8 个（`gold_cr_id`, `origin`, `plan_type`...） | 0 个 |
| 绑定保障 | 无（ID 散乱，断了查不到） | `id_mapping.json` 可反查 |

---

## 十、实施计划

### 10.1 代码影响范围

#### 需要修改的核心文件

| 文件 | 行数 | 改动量 | 改动内容 |
|:-----|:----:|:------|:---------|
| `backend/src/main.rs` | 1012 | **大** | schema.sql 重建，迁移脚本删除 plan_templates，StageBinding 路径 C 调整 |
| `backend/crates/api_server/src/routes.rs` | 2306 | **大** | k12_init/reading_init 重构，cards INSERT 精简，删除 subject/grade_band 读取，phone 校验 |
| `backend/crates/api_server/src/plan_handler.rs` | 2218 | **大** | build_plan_context 简化，删除管道 A/B/C，normalize_plan 重写，activate_stage_cards 简化 |
| `backend/crates/api_server/src/ws.rs` | 621 | **中** | prompt 选择改为 prompt_loader HashMap 查询，conversations INSERT 调整 |
| `backend/crates/api_server/src/auth.rs` | 287 | **小** | user_id 改 UUID，phone 校验+唯一性 |
| `backend/crates/api_server/src/admin_handlers.rs` | 748 | **小** | guardian/tutor 移出 admin_users 的相关调整 |
| `backend/crates/chat_engine/src/prompt_loader.rs` | 490 | **中** | 新增 `HashMap<"{subject}/{type}", String>` 扫描加载 |
| `backend/crates/card_engine/src/fsrs_scheduler.rs` | 120 | ✅ 已完成 | DueCard 字段补齐 |
| `backend/schema.sql` | 352 | **中** | 全部表定义重写 |
| `backend/crates/api_server/src/schema.sql` | 286 | **中** | 同上 |

#### 阶段二删除的文件

| 文件 | 行数 | 说明 |
|:-----|:----:|:------|
| `curriculum_loader.rs` | 317 | 迁移完成后不再需要 |
| `reading_loader.rs` | 326 | 同上 |
| `data/curriculum/prebuilt/plans/*.json` | — | 全部原始 JSON |
| `data/curriculum/prebuilt/cards/*.json` | — | 全部原始卡片 JSON |
| `data/curriculum/prebuilt/reading_plans/*.json` | — | 全部阅读 JSON |
| `backend/src/main.rs` 中的 StageBinding 迁移 | ~80 行 | 不再需要 |

#### 影响较小的文件

| 文件 | 说明 |
|:-----|:------|
| `pipeline_router.rs` | 不需要改（读 plan_context 不变） |
| `shared_types/` | 可能需要调整卡片结构体 |
| `card_formatter.rs` | 可能需要适配 reading 卡 back JSON 格式 |
| `e2e_*.rs`（9 个测试文件）| 更新 INSERT 语句列数 + DB 初始化语句 |
| `student_llm/` | 不需要改 |
| `growth_engine/` | 不需要改 |

---

### 10.2 实施阶段

#### Phase A: 数据迁移脚本（独立，不涉及代码）

**估算：2-3 小时**

1. 写 Python 脚本 `scripts/migrate_v3.py`：
   - 遍历 `data/curriculum/prebuilt/cards/*.json` → 分配 UUID → 建立 `id_mapping.json`
   - 遍历 `data/curriculum/prebuilt/plans/*.json` → 解析 gold_cr_ids → 转为 card_ids（UUID）
   - 遍历 `reading_plans/*.json` → 解析 vocab_card_ids/reading_card_id → 转为 card_ids
   - mode 转 prompt_mode（含科目前缀）
   - 验证：所有 card_ids 在卡片 JSON 中存在 ✅
   - 输出：新 JSON + id_mapping.json

2. 验证映射关系完整性

**可并行：前端登录页改造**

1. 登录页加 role 选择器（student/tutor/guardian）
2. 去除 admin 登录页中的 tutor/guardian 入口

---

#### Phase B: 核心表结构 + 基础代码（4-5 小时）

**步骤 B1: schema.sql 重写**（0.5 小时）

- 按 1.2 节写所有表 DDL
- UUID 主键、清理字段、FK 约束
- `users` 加 `role`/`status` 字段
- `conversations` 删 subject/grade_band
- `cards` 精简到 11 列
- `conversation_plans` 删 domain
- `user_plan_progress` 删 plan_type
- `plan_templates` 不创建

**步骤 B2: auth.rs + admin_handlers.rs 调整**（0.5 小时）

- `auth.rs:67` 改 `uuid::new_v4().to_string()`
- `auth.rs` register 加 phone 校验（`11位+1开头`）
- schema.sql `users.phone` 加 `UNIQUE`
- admin register 去掉 guardian/tutor role 支持
- `admin_handlers.rs` 权限检查调整

**步骤 B3: routes.rs 重构 k12_init / reading_init**（1.5 小时）

- 去掉 `INSERT INTO conversations`
- 读新 JSON 格式（已有 card_ids，不解析 gold_cr_ids）
- INSERT INTO conversation_plans 写 plan_content
- 复制卡片到用户名下
- 改 cards INSERT 语句（去掉过渡字段）
- 删掉 `format!("k12_{}_plan_{}", ...)` 写法

**步骤 B4: plan_handler.rs 重构**（1.5 小时）

- `build_plan_context`：删 subject 分叉，统一查 conversation_plans + user_plan_progress
- 删管道 A/B/C（统一 `WHERE id IN (?)`）
- normalize_plan：删猜 task_key 逻辑，改为按位置填充
- activate_stage_cards：删 plan_type，简化
- `sub_steps` 相关逻辑保留但标识为废弃

**步骤 B5: ws.rs 调整**（0.5 小时）

- WS 首次消息只为自由对话创建 conversation（K12 由 init 创建）
- prompt 选择改为 `prompt_loader.get(prompt_mode)`

**步骤 B6: prompt_loader.rs 调整**（0.5 小时）

- 启动时扫描 `prompts/chat/` 建立 HashMap
- 保留原有结构化字段兼容（过渡期）

---

#### Phase C: e2e 测试适配（1-2 小时）

**步骤 C1: 测试 DB schema 同步**（0.5 小时）

- 更新所有测试中的 CREATE TABLE 语句
- 更新 INSERT 语句列数

**步骤 C2: 跑全部 e2e 测试**（0.5 小时）

- 9 个 e2e 测试 + 单元测试全部通过
- 修复失败项

---

#### Phase D: 清理（0.5 小时）

- 删除 `curriculum_loader.rs`
- 删除 `reading_loader.rs`
- 删除原始 JSON 文件
- 删除 `main.rs` 中 StageBinding 迁移代码
- 删除 `plan_templates` 所有引用

---

### 10.3 实施顺序

```
Phase A（数据迁移脚本）     → 2-3h  ← 可先做，不依赖代码
  │
Phase B1（schema.sql）     → 0.5h  ← 必须先做
  │
Phase B2（auth）            → 0.5h
  │
Phase B3（routes k12/reading）→ 1.5h
  │
Phase B4（plan_handler）    → 1.5h
  ├─ 可并行 ── B5（ws.rs）→ 0.5h
  ├─ 可并行 ── B6（prompt_loader）→ 0.5h
  │
Phase C（e2e 测试）         → 2h
  │
Phase D（清理）             → 0.5h  ← 验证通过后再做
  │
前端登录页改造（独立）       → 1-2h  ← 可随时并行
```

**总计：约 8-11 小时有效编码，可 2-3 天完成。**

---

### 10.4 风险点

| 风险 | 缓解 |
|:-----|:------|
| `id_mapping.json` 映射不完整导致 plan 引用了不存在的卡片 | 迁移脚本必须有全量验证步骤，所有 card_ids 逐一核实 |
| e2e 测试涉及大量 DB 初始化代码需同步更新 | 统一用一个测试 schema.sql 文件，9 个测试文件都引用它 |
| 现有 DB 清库后无法回滚 | 先备份 `data/` 目录和 `data/*.db` 文件，验证通过前不删除 |
| `prompt_loader` 改动影响所有 LLM 调用 | B6 保留旧字段兼容，过渡期内两种方式都支持 |
