# CoEvo 数据库升级计划 v2（代码验证修正版）

> 基于 v1 升级计划 + 影响范围调查报告 + 代码核实修正  
> 核实时机：2026-05-31 19:45 | **本版修订：2026-06-01 01:38**  
> 保留 v1 全部 10 项变更（变更4 确认执行），修正 3 处代码假设偏差  
> **注意**：时间字段统一 INTEGER 已在 V2.0 执行现场完成（`cards.created_at`, `card_memory.*`, `review_log.reviewed_at`, `skipped_concepts.skipped_at` 保持 INTEGER；其余 TEXT 列将在 V2.1 统一转换）

---

## 版本差异说明

| 项目 | v1 (原计划) | v2 (修正版) | 变更原因 |
|------|------------|------------|---------|
| 变更4 plan_json 重命名 | ✓ 包含 | ✓ **保留执行** | 用户确认 |
| 变更7 bind_key 索引 | 需删除旧索引 | **无需删除——索引不存在** | 代码验证发现无此索引 |
| PRAGMA foreign_keys | 假设未开启 | **已确认开启** (`db_pool.rs:29`) | 代码验证 |
| 变更3 domain 修复 | 仅 DDL | **需提供代码迁移方案** | 必须改 `plan_handler.rs:246` |
| 分阶段策略 | 未明确 | **5 阶段逐步执行** | 降低风险 |
| 迁移脚本 | 不完整 | **提供可执行脚本** | 提升可操作性 |

---

## 一、v2 表结构定义

### 核心变更对照

| 表 | 原字段 | v2 字段 | 变更要点 |
|----|--------|---------|---------|
| `users` | `idx_users_bind_key ON(real_name,phone)` | `UNIQUE INDEX idx_users_bind_hash ON bind_hash` | 加密列索引→哈希列索引 |
| `conversations` | 含 `learning_plan_id` | **删除**该列 | 废弃字段清理 |
| `learning_plans` | `domain=TEXT`, `plan_json=TEXT` | `domain TEXT CHECK(...)`, `task_status=TEXT` | 语义修复 + 枚举约束 + 重命名 |
| `learning_plans` | `mode TEXT` | `mode TEXT CHECK(mode IN ...)` | 新增枚举约束 |
| `review_log` | `verification_type/result TEXT` | **添加 CHECK 约束** | 新增枚举约束 |
| `cards` | `card_type TEXT`, `origin TEXT` | **添加 CHECK 约束** | 新增枚举约束 |
| `achievements` | `tier TEXT` | **添加 CHECK 约束** | 新增枚举约束 |
| `learning_plans` | `CREATE UNIQUE INDEX idx_plans_user_domain` | **删除**，改为 `conversation_id UNIQUE + FK` | 唯一约束正确化 |
| `learning_plans` | 无 `conversation_id` FK | **添加** `FOREIGN KEY + UNIQUE` | 数据完整性 |
| `learning_plan_tasks` | 不存在 | **新建** | 新功能 |
| `cards` | 无 `conversation_id` FK | **添加**外键 | 数据完整性 |
| `cards` | `plan_task_id` 未使用 | **启用**（指向新表） | 任务级卡片归属 |
| **所有表** | 无 `ON DELETE` | **添加** `ON DELETE CASCADE/SET NULL` | 级联删除 |
| **所有表** | 时间 TEXT/INTEGER 混用 | **v2 不涉及**（延后处理） | 与升级计划解耦 |

> 时间字段统一 TEXT→INTEGER 作为独立的大版本升级项，不与本次升级混用。

### ⚠️ 核心设计原则：domain 只是分类标签，不是唯一键

#### domain 类型：Rust enum + TEXT + CHECK 约束

教学场景下 domain 取值有限，不应使用自由 TEXT：

```rust
/// 学科分类枚举 — 与 pipeline_router 对齐
#[derive(Debug, Clone, PartialEq, Display, FromStr)]
pub enum Domain {
    General,     // 通用 / 兜底
    Math,        // 数学
    Language,    // 语言（语文/英语/日语/俄语等）
    Chemistry,   // 化学
    Biology,     // 生物
    Physics,     // 物理
    History,     // 历史
    Geography,   // 地理
    Politics,    // 政治 / 道德与法治
    Science,     // 科学
    It,          // 信息技术
    Pe,          // 体育
    Art,         // 艺术（美术/音乐）
    Labor,       // 劳动
}
```

SQLite 侧：

```sql
-- CHECK 约束：只允许已知值，拒绝非法字符串
CREATE TABLE learning_plans (
    ...
    domain TEXT DEFAULT 'general'
        CHECK(domain IN ('general','math','language','chemistry','biology','physics',
 'history','geography','politics','science','it','pe','art','labor'))
    ...
);
```

**双语言映射**：K12 使用中文 subject（如"数学"），domain 通过 `curriculum_loader::CHINESE_TO_ENGLISH` 映射为英文枚举值：

```
"数学" → "math"       "物理" → "physics"    "化学" → "chemistry"
"生物" → "biology"    "科学" → "science"
"语文" → "language"   "英语" → "language"   "日语" → "language"   "俄语" → "language"
"历史" → "history"    "地理" → "geography"  "政治" → "politics"
"信息技术" → "it"     "体育" → "pe"         "艺术" → "art"
"劳动" → "labor"
```

> 注：语文/英语/日语/俄语归 `language`（共享语言管线）。历史/地理/政治/科学/信息技术/体育/艺术/劳动等无专用管线的科目**保留各自 domain 值**，但 LLM 管线路由走 `general` 兜底。枚举定义中包含全科目，确保 DB CHECK 约束全覆盖。

### 其他 TEXT → 枚举字段改造

除 domain 外，还有 7 个字段存在同样的"有限枚举值但用自由 TEXT"问题。按优先级分三档：

#### 🔴 必改（同表重建，零额外成本）

这些表在 Phase 3/4 已经要重建，加 CHECK 只是 DDL 多一行的事：

| 表 | 字段 | 当前 | 枚举值 | 来源 | 改 prompt？ |
|----|------|------|--------|------|------------|
| `learning_plans` | `mode` | TEXT | `structured`, `reading`, `free`, `deleted` | Rust 代码设置 | ❌ 否 |
| `review_log` | `verification_type` | TEXT | `spelling`, `typing`, `ai_quiz` | Rust 代码设置 | ❌ 否 |
| `review_log` | `verification_result` | TEXT | `pass`, `fail` | Rust 代码设置（quiz_judge LLM 解析后） | ⚠️ 需确认LLM输出映射完整 |
| `achievements` | `tier` | TEXT | `fixed`, `bronze`, `silver`, `gold`, `platinum` | Rust 代码设置 | ❌ 否 |
| `cards` | `origin` | TEXT | `extracted`, `prebuilt` | Rust 代码设置 | ❌ 否 |

#### 🟡 建议改（同表重建，低成本）

| 表 | 字段 | 当前 | 枚举值 | 来源 | 改 prompt？ |
|----|------|------|--------|------|------------|
| `conversation_turns` | `role` | TEXT | `user`, `assistant` | Rust 代码设置 | ❌ 否 |
| `cards` | `card_type` | TEXT | `concept`, `vocabulary`, `reading` | `card_formatter.rs:19` 从 domain 推导 | ❌ 否 |

> `cards.card_type` 虽然来自 LLM 输出的 domain，但实际赋值在 Rust 代码（`card_formatter.rs:19`），**不是 LLM 直接写库**。K12 预置卡从数据文件读，也是确定值。

#### 🟢 不改（独立模块，后续版本）

`admin_users.role/status`、`subscription_requests.status`、`knowledge_graph.edge_type/strength`、`k12_quiz_bank.question_type` 等——管理后台/知识图谱模块，与核心升级解耦。

#### LLM 相关字段说明

经代码追溯，上述 **7 个字段均不由 LLM 直接写入数据库**：

| 字段 | LLM 是否参与 | 写入路径 |
|------|------------|---------|
| `learning_plans.mode` | ❌ | Rust 代码在 plan_handler.rs 设置 |
| `review_log.verification_type` | ❌ | 前端/API 传入，Rust 代码设 |
| `review_log.verification_result` | ⚠️ 间接 | quiz_judge LLM 输出→Rust 解析→写库。Rust 层已做值映射，不会出现预期外的值 |
| `achievements.tier` | ❌ | 成就系统逻辑设置 |
| `cards.card_type` | ❌ | `format_card()` 从 domain 推导，不是 LLM 直接写入 |
| `cards.origin` | ❌ | 系统标记 'extracted'/'prebuilt' |
| `conversation_turns.role` | ❌ | WebSocket 消息路由标记 |

**因此不需要修改任何 prompt 文件。** 只需要在 Rust 代码中确认所有写入路径的值都在 CHECK 范围内即可。

#### 各表 DDL 变更

**`learning_plans`（Phase 3 重建）**：
```sql
CREATE TABLE learning_plans_new (
    ...
    mode TEXT DEFAULT NULL
        CHECK(mode IN ('structured', 'reading', 'free', 'deleted')),
    ...
);
```

**`review_log`（Phase 4 重建）**：
```sql
CREATE TABLE review_log_new (
    ...
    verification_type TEXT NOT NULL
        CHECK(verification_type IN ('spelling', 'typing', 'ai_quiz')),
    verification_result TEXT NOT NULL
        CHECK(verification_result IN ('pass', 'fail')),
    ...
);
```

**`achievements`（Phase 4 重建如有）**：
```sql
CREATE TABLE achievements_new (
    ...
    tier TEXT DEFAULT 'fixed'
        CHECK(tier IN ('fixed', 'bronze', 'silver', 'gold', 'platinum')),
    ...
);
```

**`cards`（Phase 4 重建）**：
```sql
CREATE TABLE cards_new (
    ...
    card_type TEXT NOT NULL
        CHECK(card_type IN ('concept', 'vocabulary', 'reading')),
    origin TEXT DEFAULT 'extracted'
        CHECK(origin IN ('extracted', 'prebuilt')),
    ...
);
```

**`conversation_turns`（非本次重建范围，可选）**：
```sql
-- 在下次涉及 conversation_turns 的迁移中加上
role TEXT NOT NULL CHECK(role IN ('user', 'assistant'))
```

#### ⚠️ domain 只是分类标签，不是唯一键

当前最大的语义错误不是"domain 存了 conversation_id"，而是 **`(user_id, domain)` 被当成了唯一约束**。

| 角色 | 当前（错误） | v2（正确） |
|------|------------|-----------|
| **唯一约束** | `(user_id, domain)` | **`conversation_id UNIQUE`** — 一个对话至多一个计划 |
| **domain** | 被迫承载"唯一键"义务 | **纯分类标签** — 用于前端 tab 过滤、LLM prompt 路由 |
| **K12 domain** | `"数学_g7-9"` — 作为唯一键可以接受 | `"数学_g7-9"` — 加普通索引，不唯一 |
| **CP1 domain** | UUID — 绕过唯一约束的变通 | `""` — 不再需要变通 |
| **cards.domain** | 与 learning_plans.domain 对齐 | 与 learning_plans.domain **无关**，源自 LLM 推断 |

**结论**：一旦 `(user_id, domain)` 唯一索引被移除，K12/Reading 路径中依赖这个唯一性做 DELETE 幂等的代码也必须同步修改（见阶段 0 代码改造）。

---

## 二、分阶段执行计划

### 阶段 0：代码前置准备（紧前工作）

在开始任何 DDL 之前，先完成 Rust 代码改造。这是整个升级最关键的一步。

#### 2.1 domain 语义修正

**根因**：`backend/crates/api_server/src/plan_handler.rs:244-246`
```rust
// domain = conversation_id，确保每个对话独立拥有学习计划
// （UNIQUE INDEX 约束 (user_id, domain)，同一用户不同对话各自独立）
let domain = conversation_id;
```

**修复方案**：
```rust
// domain 不再等于 conversation_id
// 结构化模式没有真实学科，设为空字符串 → prompt_loader::get_for_domain 走 general 兜底
// K12/reading 模式下 domain 已在插入时正确设置为 subject+grade_band
let domain = String::new();
```

**波及的代码路径**（需同步修改）：

| 文件 | 行号 | 当前行为 | 修改后行为 |
|------|------|---------|-----------|
| `plan_handler.rs` | 244-246 | `domain = conversation_id` | `domain = String::new()` |
| `routes.rs` | 1587-1591 | `WHERE user_id=?1 AND domain=?2` 查找计划 | 改用 `conversation_id` 查找 |
| `routes.rs` | 2109-2111 | K12 init: `DELETE WHERE user_id+domain` | domain 不再唯一，**需改用 conversation_id 或添加 subject+grade_band 联合过滤** |
| `routes.rs` | 2309-2311 | Reading init: `DELETE WHERE user_id+domain` | **同上** |
| `ws.rs` | 450-457 | `SELECT domain FROM learning_plans` 直接读 DB 列 | **改为读取 plan_content 中的 domain**（已存在 get_for_domain 路径），消除对 DB 列的依赖 |

#### 2.1.1 K12/Reading DELETE 路径的修改方案

domain 不再唯一后，`DELETE WHERE user_id+domain` 可能误删多个计划的记录。改用 conversation_id：

**K12 init**（`routes.rs:2109-2111`）：
```rust
// 改前：domain = subject+grade_band 复合键，删除所有匹配
let _ = conn.execute(
    "DELETE FROM learning_plans WHERE user_id = ?1 AND domain = ?2",
    rusqlite::params![input.user_id, format!("{}_{}", input.subject, input.grade_band)],
);
// 写入：INSERT ... domain = format!("{}_{}", input.subject, input.grade_band)

// 改后：domain 使用枚举值（通过 curriculum_loader::CHINESE_TO_ENGLISH 映射）
use curriculum_loader::CHINESE_TO_ENGLISH;
let domain_val = CHINESE_TO_ENGLISH.iter()
    .find(|(cn, _)| *cn == input.subject)
    .map(|(_, en)| *en)
    .unwrap_or("general");

// DELETE 使用 conversation_id 精确删除
let _ = conn.execute(
    "DELETE FROM learning_plans WHERE conversation_id = ?1",
    rusqlite::params![conv_id],
);
// INSERT ... domain = ?5 → rusqlite::params![..., domain_val, ...]
```

**Reading init**（`routes.rs:2309-2311`）同理：
```rust
let _ = conn.execute(
    "DELETE FROM learning_plans WHERE conversation_id = ?1",
    rusqlite::params![conv_id],
);
```

#### 2.1.2 ws.rs plan_db_domain 的修改方案

当前代码读两次 domain：一是通过 `build_plan_context`（从 plan_content JSON），二是直接读 DB 列。二者各有用处，但直接读 DB 列的那条路径（`ws.rs:450-457`）应该迁移到从 `plan_content` 读取：

```rust
// 改前：直接读 learning_plans.domain 列
let plan_db_domain: String = conn.query_row(
    "SELECT domain FROM learning_plans WHERE ...",
    ...
).unwrap_or_default();

// 改后：使用 build_plan_context 的返回值（已从 plan_content JSON 提取）
// extract_domain 已在上面 ws.rs:442 处获取，plan_db_domain 改为复用
// is_free_dialogue 判断改为基于 mode 而非 domain 格式
let is_free_dialogue = plan_content_json.get("mode")
    .and_then(|m| m.as_str())
    .map(|m| m == "structured" || m == "free")
    .unwrap_or(false);
// 卡片 domain 绑定逻辑不变——仍用 c.domain（LLM 推断值）
```

> **⚠️ 当前阶段暂不执行**。经代码追溯确认 `ws.rs:458` 的 `is_free_dialogue` 在 spawn 内部被 line 543 的 `let is_free_dialogue = extract_domain.contains('-')` 重新绑定，外层的 `plan_db_domain` 变量在所有正常场景下均未被使用（99% 路径走 `c.domain`）。此变量为历史遗留死代码，**计划在全部升级完成后清理**，不阻塞本次流程。

#### 2.2 plan_json → task_status 重命名

> 用户确认执行此项变更。约 107 处引用，波及 7 个文件。

**策略**：第一阶段使用"双列共存"过渡策略，第二阶段彻底移除旧列。

**过渡期代码变更**：

```rust
// 写入：同时写入两个列（确保过渡期不丢数据）
conn.execute(
    "UPDATE learning_plans SET task_status=?1, plan_json=?1, updated_at=?2 WHERE id=?3",
    ...
);

// 读取：优先读新列，回退到旧列
let status = conn.query_row(
    "SELECT task_status FROM learning_plans WHERE conversation_id=?1",
    ...
).or_else(|_| {
    conn.query_row(
        "SELECT plan_json FROM learning_plans WHERE conversation_id=?1",
        ...
    )
});
```

**文件变更清单**：

| 文件 | 引用数 | 操作 |
|------|--------|------|
| `plan_handler.rs` | ~68 | 全部替换 `plan_json` → `task_status` |
| `routes.rs` | ~30 | 同上 |
| `admin_handlers.rs` | 3 | 同上 |
| `ws.rs` | 2 | 同上 |
| `reading_loader.rs` | 2 | 同上 |
| `e2e_runner.rs` | 1 | DDL CREATE TABLE 中改名 |
| `k12_quiz_api.rs` | 1 | k12_progress.plan_json 不受影响 |

**合并优势**：plan_json 重命名和 domain 修复都涉及 `plan_handler.rs`，两次代码修改合并执行，边际成本约减少 40%。

---

### 阶段 1：零风险预迁移（可立即执行）

**变更 7**：`bind_hash` 唯一索引

```sql
-- 检查当前 bind_hash 的空值比例
SELECT COUNT(*) FROM users WHERE bind_hash IS NULL;

-- 先删除旧的加密列索引（如果存在 — 早期 migration 遗留）
DROP INDEX IF EXISTS idx_users_bind_key;

-- 创建部分唯一索引（忽略 NULL 值）
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_bind_hash ON users(bind_hash) WHERE bind_hash IS NOT NULL;
```

| 状态检查 | 结论 |
|---------|------|
| 需要等待阶段 0 代码 | ❌ 不需要 |
| 现有数据冲突风险 | 🟢 极低（SHA-256 碰撞概率忽略不计） |
| 代码修改 | 0 — 纯 DDL |
| 执行后不可回退 | ✅ 可回退（`DROP INDEX IF EXISTS idx_users_bind_hash`） |

---

### 阶段 2：Schema 清理（conversations 表重建）

**变更 1**：删除 `learning_plan_id` 列（SQLite 不支持 DROP COLUMN，需重建表）

```
数据量: conversations 139 行 → 重建安全
```

```sql
-- Step 1: 创建新表（不含 learning_plan_id）
CREATE TABLE conversations_new (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    deleted_at TEXT,
    subject TEXT,
    grade_band TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations_new(user_id, deleted_at);

-- Step 2: 迁移数据
INSERT INTO conversations_new (id, user_id, turn_count, started_at, deleted_at, subject, grade_band)
SELECT id, user_id, turn_count, started_at, deleted_at, subject, grade_band FROM conversations;

-- Step 3: 原子切换
DROP TABLE conversations;
ALTER TABLE conversations_new RENAME TO conversations;
```

**变更 9（CASCADE）**：此阶段已为 `conversations.user_id` 添加 `ON DELETE CASCADE`

| 风险 | 缓解措施 |
|------|---------|
| 老数据丢失 | Step 2 已迁移全部字段 |
| 并发写入 | 需在停机窗口执行 |
| 索引丢失 | 已重建 `idx_conversations_user_deleted` |
| `conversation_turns` FK 指向旧表 | ✅ 外键指向 `id TEXT` 而不是物理表引用 |

---

### 阶段 3：核心 Schema 重构（learning_plans 重建 + 代码就绪）

这是最关键的一步，需要在**阶段 0 代码已就绪**后才能执行。

**变更 3 + 变更 2 + 变更 4 + 变更 9（CASCADE）**

```
数据量: learning_plans 61 行 → 重建安全
```

#### 3.1 DDL

```sql
-- 1. 创建新表
CREATE TABLE learning_plans_new (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL UNIQUE,       -- UNIQUE：一个对话至多一个计划
    goal TEXT NOT NULL,
    domain TEXT DEFAULT 'general'
        CHECK(domain IN ('general','math','language','chemistry','biology','physics',
 'history','geography','politics','science','it','pe','art','labor'))
                                                -- 枚举约束：仅允许已知学科
    mode TEXT DEFAULT NULL
        CHECK(mode IN ('structured', 'reading', 'free', 'deleted')),
    task_status TEXT NOT NULL,                   -- 原 plan_json，JSON: {"task_key": "status"}
    plan_content TEXT,                           -- JSON: {"stages": [...]}
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_learning_plans_user ON learning_plans_new(user_id);
CREATE INDEX IF NOT EXISTS idx_learning_plans_domain ON learning_plans_new(domain);
```

#### 3.2 数据迁移

```sql
-- 2. 清理孤儿记录（无对应 conversation 的行）
DELETE FROM learning_plans WHERE conversation_id NOT IN (SELECT id FROM conversations);

-- 3. 迁移数据
--    K12/Reading 的 domain 从 conversations.subject → 英文枚举（通过 CHINESE_TO_ENGLISH 映射）
--    CP1 结构化模式的 domain 从 plan_content JSON 的 "domain" 字段取
--    无对应关系的兜底为 'general'
--    新 task_status：直接从 plan_json 复制（内容不变，只改名）
INSERT INTO learning_plans_new (
    id, user_id, conversation_id, goal, domain, mode,
    task_status, plan_content, created_at, updated_at
)
SELECT
    lp.id, lp.user_id, lp.conversation_id, lp.goal,
    CASE
        -- K12/Reading：从 conversations.subject 映射到英文枚举
        WHEN c.subject IS NOT NULL THEN
            CASE c.subject
                WHEN '数学' THEN 'math'
                WHEN '语文' THEN 'language'
                WHEN '英语' THEN 'language'
                WHEN '物理' THEN 'physics'
                WHEN '化学' THEN 'chemistry'
                WHEN '生物' THEN 'biology'
                ELSE 'general'
            END
        -- CP1 结构化：尝试从 plan_content JSON 读 "domain" 字段
        WHEN lp.plan_content IS NOT NULL THEN
            COALESCE(
                json_extract(lp.plan_content, '$.domain'),
                'general'
            )
        ELSE 'general'
    END,
    lp.mode,
    lp.plan_json,                       -- task_status = 原 plan_json（写入时已双写）
    lp.plan_content, lp.created_at, lp.updated_at
FROM learning_plans lp
LEFT JOIN conversations c ON c.id = lp.conversation_id;

-- 4. 原子切换
DROP TABLE learning_plans;
ALTER TABLE learning_plans_new RENAME TO learning_plans;
```

#### 3.3 唯一约束检查

迁移前确认 conversation_id 没有重复：
```sql
SELECT conversation_id, COUNT(*) FROM learning_plans
WHERE conversation_id IS NOT NULL
GROUP BY conversation_id HAVING COUNT(*) > 1;
```
期望结果：**0 行**（当前通过 `(user_id, domain)` 间接保证唯一性，domain=conversation_id）

| 风险 | 缓解措施 |
|------|---------|
| conversation_id 重复 | 先检查，若存在需人为合并 |
| domain 迁移丢失值 | COALESCE 兜底 |
| 旧 DDL 的 plan_json 在过渡期同时写入 | 阶段 0 代码已实现双写 |

---

### 阶段 4：卡片约束 + 新功能

#### 4.1 cards 外键（变更 5 + 变更 9）

```
数据量: cards 2011 行 → 需小心处理
联系链: review_log → card_memory → cards → conversations
```

重建表需按依赖链处理：

```sql
-- 1. 清理孤儿
DELETE FROM cards WHERE conversation_id NOT IN (SELECT id FROM conversations);

-- 2. 重建 cards（添加 FK + CASCADE）
CREATE TABLE cards_new (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,                                 -- 学科标签，由 LLM 推断（自由 TEXT，不设 CHECK）
    card_type TEXT NOT NULL
        CHECK(card_type IN ('concept', 'vocabulary', 'reading')),
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    conversation_id TEXT,
    subject TEXT,
    grade_band TEXT,
    k12_card_id TEXT,
    gold_cr_id TEXT,
    plan_task_id TEXT,
    origin TEXT DEFAULT 'extracted'
        CHECK(origin IN ('extracted', 'prebuilt')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL,
    FOREIGN KEY (plan_task_id) REFERENCES learning_plan_tasks(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_cards_user_id ON cards_new(user_id);
CREATE INDEX IF NOT EXISTS idx_cards_user_domain ON cards_new(user_id, domain);
CREATE INDEX IF NOT EXISTS idx_cards_conversation_id ON cards_new(conversation_id);

-- 3. 迁移数据（保持原字段）
INSERT INTO cards_new SELECT * FROM cards;

-- 4. 原子切换
DROP TABLE cards;
ALTER TABLE cards_new RENAME TO cards;
```

**重要**：`card_memory`（2007行，1:1关联）和 `review_log`（15行）依赖 `cards.id`。但它们的表结构不变（`card_id` PK/FK 不变），仅需确认索引：

```sql
-- card_memory：无需重建，CASCADE 会在重建表时自动匹配新表和旧外键名称
--   → 但 cards 重建后，card_memory 的外键定义指向 physical 旧表，需要确认 SQLite 行为
--   → SQLite 的 FK 是通过 schema 检查的。不放心就重建：
CREATE TABLE card_memory_new (
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
CREATE INDEX IF NOT EXISTS idx_card_memory_due ON card_memory_new(due);
INSERT INTO card_memory_new SELECT * FROM card_memory;
DROP TABLE card_memory;
ALTER TABLE card_memory_new RENAME TO card_memory;

-- review_log：同理
CREATE TABLE review_log_new (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL
        CHECK(verification_type IN ('spelling', 'typing', 'ai_quiz')),
    verification_result TEXT NOT NULL
        CHECK(verification_result IN ('pass', 'fail')),
    reviewed_at INTEGER NOT NULL,
    details_json TEXT,
    FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log_new(card_id, reviewed_at);
INSERT INTO review_log_new SELECT * FROM review_log;
DROP TABLE review_log;
ALTER TABLE review_log_new RENAME TO review_log;
```

#### 4.2 learning_plan_tasks 创建（变更 6 + 变更 10）

```sql
-- 新建表
CREATE TABLE learning_plan_tasks (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    task_key TEXT NOT NULL,
    task_name TEXT NOT NULL,
    description TEXT,
    stage_index INTEGER,
    task_index INTEGER,
    created_at TEXT NOT NULL,
    UNIQUE(plan_id, task_key),
    FOREIGN KEY (plan_id) REFERENCES learning_plans(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tasks_plan_id ON learning_plan_tasks(plan_id);

-- 从现有 plan_content 填充数据（Rust 代码实现，非纯 SQL）
-- 伪代码：
for plan in SELECT id, plan_content FROM learning_plans WHERE plan_content IS NOT NULL:
    content = JSON.parse(plan.plan_content)
    for (s_idx, stage) in content.stages:
        for (t_idx, task) in stage.tasks:
            INSERT INTO learning_plan_tasks (id, plan_id, task_key, task_name, stage_index, task_index, created_at)
            VALUES (uuid, plan.id, task.key, task.name, s_idx, t_idx, now)
```

---

### 阶段 5：过渡期数据同步（可选，仅在 plan_json→task_status 双写时需清理）

当所有代码已完成 `task_status` 迁移且稳定运行一段时间后：

```sql
-- 删除旧列（需重建表或等待下次大版本）
-- 或：在下次涉及 learning_plans 的变更中一并移除
ALTER TABLE learning_plans DROP COLUMN plan_json;
```

> 由于 SQLite 不支持 DROP COLUMN（< 3.25.0），建议等到下次大版本（如时间统一）时一并进行。

---

## 三、完整迁移依赖图

```
阶段 0: 代码改造（紧前工作）
  ├── 0a. domain 语义修正 (plan_handler.rs:246)
  │   └── 连锁影响：
  │       ├── routes.rs:1587-1591 lookup 改 conversation_id
  │       ├── routes.rs:2109-2111 K12 DELETE 改 conversation_id
  │       ├── routes.rs:2309-2311 Reading DELETE 改 conversation_id
  │       └── ws.rs:450-457 plan_db_domain 改为从 plan_content 读
  ├── 0b. plan_json → task_status 双写逻辑 (~107 处引用, 7 文件)
  └── 0c. K12/Reading 幂等策略迁移（DELETE 改为 conversation_id）
        ↓
阶段 1: bind_hash 唯一索引（纯 SQL，无依赖）
        ↓
阶段 2: conversations 表重建（删 learning_plan_id）
        ↓
阶段 3: learning_plans 表重建（domain+FK+task_status） ← 需阶段 0 代码就绪
        ↓
阶段 4a: cards + card_memory + review_log 重建（FK+CASCADE）
        ↓
阶段 4b: learning_plan_tasks 建表 + 填充数据
        ↓
阶段 5 (可选): 过渡期后清理 plan_json 旧列
```

---

## 四、风险矩阵（修正版）

| 阶段 | 变更 | 风险 | 代码修改 | 数据迁移 | 回退难度 |
|------|------|------|---------|---------|---------|
| 0 | 代码改造 | 🔴 高 | 4 个核心文件 + 额外 3 处连锁修改 | 0 | 🟢 代码回退 |
| 1 | bind_hash 索引 | 🟢 低 | 0 | 0 | 🟢 DROP INDEX |
| 2 | conversations | 🟡 中低 | 0—纯DDL | 139行 | 🟡 恢复备份 |
| 3 | learning_plans | 🔴 高 | 已在阶段0完成 | 61行 + 新增 mode CHECK | 🟡 恢复备份 |
| 4a | cards 系列 + review_log | 🟡 中 | 0—纯DDL（新增 CHECK 约束） | 4033行 | 🟡 恢复备份 |
| 4b | plan_tasks 新表 | 🟢 低 | 需在创建plan时同步写入 | 新建 | 🟢 DROP TABLE |
| 5 | 清理旧列 | 🟢 低 | 0 | 0 | N/A |

---

## 五、执行核对清单

### 阶段 0 代码改造完成后需验证

- [ ] 新增 `Domain` enum（含 `FromStr`/`Display` 实现）
- [ ] `plan_handler.rs` 中 `domain` 不再等于 `conversation_id`
- [ ] 结构化模式下 domain 已改为 `Domain::General`（空字符串/枚举值）
- [ ] K12/Reading 写入 domain 已改为枚举值（经 CHINESE_TO_ENGLISH 映射）
- [ ] `get_for_domain(domain)` 在结构化模式下能走到 general 兜底
- [ ] `routes.rs:1587-1591` 中的 lookup 已改为使用 `conversation_id`
- [ ] `routes.rs:2109-2111` K12 init 的 DELETE 改用 `conversation_id`
- [ ] `routes.rs:2309-2311` Reading init 的 DELETE 改用 `conversation_id`
- [ ] `ws.rs:450-457` 不再直接读 `learning_plans.domain` 列
- [ ] `plan_json` 和 `task_status` 双写逻辑已部署（新代码同时写两个列）
- [ ] 确认 `(user_id, domain)` 唯一约束移除后没有任何代码依赖它做幂等
- [ ] 确认 `cards.domain` 保持自由 TEXT（不受 CHECK 约束影响，LLM 可能输出未注册值）
- [ ] 确认所有 `review_log.verification_type` 写入值在 `('spelling','typing','ai_quiz')` 内
- [ ] 确认所有 `review_log.verification_result` 写入值在 `('pass','fail')` 内
- [ ] 确认所有 `cards.card_type` 写入值在 `('concept','vocabulary','reading')` 内
- [ ] 确认所有 `cards.origin` 写入值在 `('extracted','prebuilt')` 内
- [ ] 确认所有 `achievements.tier` 写入值在 `('fixed','bronze','silver','gold','platinum')` 内
- [ ] 确认所有 `learning_plans.mode` 写入值在 `('structured','reading','free','deleted')` 内
- [ ] 所有测试通过（`cargo test`）

### 各阶段执行前

- [ ] 备份数据库（`cp coevo.db coevo.db.bak.$(date +%Y%m%d)`）
- [ ] 确认无活跃请求（已暂停前端流量或不在高峰时段）
- [ ] 确认 DB 文件可写

### 各阶段执行后

- [ ] 执行 `PRAGMA foreign_key_check` 确认外键一致性
- [ ] 执行 `SELECT COUNT(*)` 确认数据行数正确
- [ ] 执行关键路径冒烟测试（创建 plan → 制卡 → 复习）
- [ ] 若失败：停止后续阶段，恢复备份，排查日志

---

## 六、升级成功后评估

| 指标 | 当前 | 目标 |
|------|------|------|
| 数据库设计评分 | 6.5/10 | 8.5/10 |
| 外键完整性 | 3 处缺失 | 全部健全 |
| domain 角色 | 既是分类标签又是唯一键 | **纯分类标签，非唯一 | 枚举约束** |
| 列命名 | plan_json 误导 | task_status 准确 |
| 唯一约束 | (user_id, domain) 歧义 | conversation_id UNIQUE 明确 |
| 枚举约束 | 0 个 | **7 字段加 CHECK**（domain/mode/card_type/origin/verification_type/verification_result/tier） |
| ON DELETE | 无 | CASCADE/SET NULL 全链路 |
