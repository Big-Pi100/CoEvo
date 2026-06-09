# Prebuilt Schema 重构设计

**日期**: 2026-06-09  
**状态**: V2.2 — 定稿  
**关联**: DB 架构 V2.2 / K12 初始化性能优化 / 存储优化

---

## 1. 动机

当前 `k12_init` 为每个用户完整复制卡片内容到 `cards` 表，导致：

- **存储浪费**: 英语 12871 张卡的 front/back 内容对所有用户完全一样，却重复存储 N 份
- **初始化慢**: 每次 `k12_init` 要执行数千次 INSERT，复制完整内容
- **热更新困难**: 修改卡片内容需要跑 migration，不能直接热替换 JSON 文件

## 2. 设计原则

1. **结构一致**: `prebuilt_*` 与 `user_*` 表列结构对齐，不引入两套 schema
2. **两条数据流**: 预置卡走 `prebuilt_*` 子表；CP1 自定义卡走 `user_*` 子表（列结构相同）
3. **domain 硬枚举**: `science/language/literature/humanities` 决定路由到哪张子表
4. **用户状态用 DB 列，内容用 JSON**: 保持现有原则

## 3. 新增表

### 3.1 `prebuilt_plans` — 全局共享计划（模板）

```sql
CREATE TABLE IF NOT EXISTS prebuilt_plans (
    id          TEXT PRIMARY KEY,
    subject     TEXT NOT NULL,
    domain      TEXT NOT NULL,          -- ENUM: science/language/literature/humanities
    grade_band  TEXT NOT NULL DEFAULT '',
    goal        TEXT NOT NULL DEFAULT '',
    plan_content TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_prebuilt_plans_subject ON prebuilt_plans(subject, grade_band);
```

> **语义**: `prebuilt_plans.plan_content` 是模板原文，启动时一次性从 JSON 文件导入，不可变。

### 3.1a `prebuilt_stages` — 全局共享 stage 明细

```sql
CREATE TABLE IF NOT EXISTS prebuilt_stages (
    id          TEXT PRIMARY KEY,
    plan_id     TEXT NOT NULL,
    sort        TEXT NOT NULL DEFAULT '',
    name        TEXT NOT NULL DEFAULT '',
    grade_band  TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (plan_id) REFERENCES prebuilt_plans(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_prebuilt_stages_plan ON prebuilt_stages(plan_id, sort);
```

### 3.1b `prebuilt_tasks` — 全局共享 task 明细

```sql
CREATE TABLE IF NOT EXISTS prebuilt_tasks (
    id          TEXT PRIMARY KEY,
    stage_id    TEXT NOT NULL,
    task_key    TEXT NOT NULL DEFAULT '',
    name        TEXT NOT NULL DEFAULT '',
    prompt_mode TEXT NOT NULL DEFAULT '',
    card_ids    TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (stage_id) REFERENCES prebuilt_stages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_prebuilt_tasks_stage ON prebuilt_tasks(stage_id, task_key);
```

> **启动时导入**: `curriculum_loader::init()` 解析 JSON → 写入 `prebuilt_plans` → 拆解写入 `prebuilt_stages` + `prebuilt_tasks` + `prebuilt_cards`。`plan_content` 保留完整 JSON 供前端一次性返回。

### 3.2 `prebuilt_cards` — 全局卡片注册表（父表）

```sql
CREATE TABLE IF NOT EXISTS prebuilt_cards (
    id              TEXT PRIMARY KEY,
    card_type       TEXT NOT NULL,          -- concept/vocabulary/poem/timeline...
    domain          TEXT NOT NULL,          -- ENUM: science/language/literature/humanities
    subject         TEXT NOT NULL DEFAULT '',
    grade_band      TEXT NOT NULL DEFAULT '',
    front           TEXT NOT NULL DEFAULT '',
    difficulty      REAL DEFAULT 0.5,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
```

> **`domain` 是硬枚举**，决定路由到哪张子表。**`front` 是所有子卡的统一名称字段**（vocabulary 的词、concept 的概念名、literature 的标题、humanities 的节点名），子表中不存名称。

### 3.2a `prebuilt_science_cards` — 理科子表

```sql
CREATE TABLE IF NOT EXISTS prebuilt_science_cards (
    id                TEXT PRIMARY KEY,
    definition        TEXT NOT NULL DEFAULT '',
    key_elements      TEXT NOT NULL DEFAULT '',
    applications      TEXT NOT NULL DEFAULT '',
    related_concepts  TEXT NOT NULL DEFAULT '',
    formula           TEXT NOT NULL DEFAULT '',  -- LaTeX
    graph             TEXT NOT NULL DEFAULT '',  -- GraphWidget JSON
    source            TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
```

> **`formula`**: LaTeX 语法，flutter_math_fork 渲染。**`graph`**: 与 chat prompt `<graph>` 标签同格式 JSON（7 种类型：line/bar/scatter/pie/polygon/circle/arrow），GraphWidget 渲染。

### 3.2b `prebuilt_language_cards` — 语言子表

```sql
CREATE TABLE IF NOT EXISTS prebuilt_language_cards (
    id                TEXT PRIMARY KEY,
    pronunciation     TEXT NOT NULL DEFAULT '',
    pos               TEXT NOT NULL DEFAULT '',
    definitions       TEXT NOT NULL DEFAULT '[]', -- JSON: [{pos, meaning, example}]
    related_phrases   TEXT NOT NULL DEFAULT '',
    structure_meta    TEXT NOT NULL DEFAULT '',    -- JSON: {radical, strokes} 中文专用
    level             TEXT NOT NULL DEFAULT '',    -- CEFR: A1/A2/B1/B2/C1/C2
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
```

### 3.2c `prebuilt_literature_cards` — 文章子表

```sql
CREATE TABLE IF NOT EXISTS prebuilt_literature_cards (
    id                TEXT PRIMARY KEY,
    full_text         TEXT NOT NULL DEFAULT '',
    translation       TEXT NOT NULL DEFAULT '',
    author            TEXT NOT NULL DEFAULT '',
    genre             TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
```

> **精简原则**: theme/technique/imagery/key_grammar 等教学元数据不进卡片结构，由 LLM 提示词或 CP1 处理。**translation**: 外语→中文，中文→英文。

### 3.2d `prebuilt_humanities_cards` — 文科子表（节点即卡片）

```sql
-- 节点即卡片，名称统一由父表 prebuilt_cards.front 承担
CREATE TABLE IF NOT EXISTS prebuilt_humanities_cards (
    id                TEXT PRIMARY KEY,
    node_type         TEXT NOT NULL DEFAULT '',   -- event|concept|person|place|period
    body              TEXT NOT NULL DEFAULT '',
    period            TEXT NOT NULL DEFAULT '',
    region            TEXT NOT NULL DEFAULT '',
    tags              TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE
);
```

### 3.2e `card_relations` — 通用卡片关系图

连接任意卡片（全局或用户自定义）的关系网络。一张表覆盖四种连接：全局↔全局、全局↔用户卡、用户卡↔用户卡。

```sql
CREATE TABLE IF NOT EXISTS card_relations (
    id                TEXT PRIMARY KEY,
    from_type         TEXT NOT NULL,          -- 'prebuilt' | 'user'
    from_id           TEXT NOT NULL,          -- prebuilt_cards.id 或 user_cards.id
    to_type           TEXT NOT NULL,          -- 'prebuilt' | 'user'
    to_id             TEXT NOT NULL,          -- prebuilt_cards.id 或 user_cards.id
    relation_type     TEXT NOT NULL,          -- cause|oppose|influence|precede|contemporary_of|locate|contain
    description       TEXT NOT NULL DEFAULT '',
    metadata          TEXT NOT NULL DEFAULT '{}',  -- JSON: {strength, evidence, start_year, ...}
    user_id           TEXT,                   -- NULL=全局预置关系；非NULL=用户私有关系
    sort_order        INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_card_relations_from ON card_relations(from_type, from_id);
CREATE INDEX IF NOT EXISTS idx_card_relations_to ON card_relations(to_type, to_id);
CREATE INDEX IF NOT EXISTS idx_card_relations_user ON card_relations(user_id);
CREATE INDEX IF NOT EXISTS idx_card_relations_type ON card_relations(relation_type);
```

> **所有权规则**:
> - **`from_type='prebuilt' AND to_type='prebuilt' AND user_id IS NULL`** → 全局预置关系（启动时从 JSON 导入，所有用户共享，只读）。
> - **其余所有情况**（涉及任何 `user` 类型卡片，或 `user_id` 非 NULL）→ **用户私有**，`user_id` 指定归属，级联删除。
> - **无 FK 约束**: `from_id`/`to_id` 可能引用 `prebuilt_cards.id` 或 `user_cards.id`，无法用 FK 强制，应用层保证。

### 3.3 `plan_runs` — 用户计划实例（替代 `conversation_plans`）

```sql
CREATE TABLE IF NOT EXISTS plan_runs (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    prebuilt_plan_id TEXT,                 -- 引用 prebuilt_plans.id
    subject         TEXT NOT NULL DEFAULT '',
    domain          TEXT NOT NULL,          -- ENUM
    grade_band      TEXT NOT NULL DEFAULT '',
    goal            TEXT NOT NULL DEFAULT '',
    plan_content    TEXT,                   -- NULL=引用 prebuilt；非 NULL=自定义/LLM 修改
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id),
    FOREIGN KEY (prebuilt_plan_id) REFERENCES prebuilt_plans(id)
);
CREATE INDEX IF NOT EXISTS idx_plan_runs_user ON plan_runs(user_id, status);
CREATE INDEX IF NOT EXISTS idx_plan_runs_conv ON plan_runs(conversation_id);
```

### 3.4 `user_cards` — 用户卡片实例（替代 `cards` 表）

```sql
CREATE TABLE IF NOT EXISTS user_cards (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL,
    plan_run_id     TEXT NOT NULL,
    prebuilt_card_id TEXT,                -- NULL=CP1 自定义卡
    domain          TEXT NOT NULL,         -- ENUM
    front           TEXT,                  -- NULL=引用 prebuilt；非 NULL=CP1 自定义
    status          TEXT NOT NULL DEFAULT 'active',
    task_key        TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (plan_run_id) REFERENCES plan_runs(id),
    FOREIGN KEY (prebuilt_card_id) REFERENCES prebuilt_cards(id)
);
CREATE INDEX IF NOT EXISTS idx_user_cards_user_plan ON user_cards(user_id, plan_run_id, status);
CREATE INDEX IF NOT EXISTS idx_user_cards_prebuilt ON user_cards(prebuilt_card_id);
```

> **`user_cards` 只做用户关联**，不存内容。卡片内容统一存放在 domain 子表中：
> - `prebuilt_card_id≠NULL` → JOIN `prebuilt_*` 子表
> - `prebuilt_card_id=NULL` → JOIN `user_*` 子表（CP1 自创卡）

### 3.5 `user_*_cards` — 用户私有子表（CP1 卡片内容）

4 张子表列结构与对应的 `prebuilt_*` 子表**完全一致**，唯一的区别是 FK 指向 `user_cards.id` 而非 `prebuilt_cards.id`。

```sql
CREATE TABLE IF NOT EXISTS user_science_cards (
    id                TEXT PRIMARY KEY,   -- REFERENCES user_cards.id
    definition        TEXT NOT NULL DEFAULT '',
    key_elements      TEXT NOT NULL DEFAULT '',
    applications      TEXT NOT NULL DEFAULT '',
    related_concepts  TEXT NOT NULL DEFAULT '',
    formula           TEXT NOT NULL DEFAULT '',
    graph             TEXT NOT NULL DEFAULT '',
    source            TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_language_cards (
    id                TEXT PRIMARY KEY,
    pronunciation     TEXT NOT NULL DEFAULT '',
    pos               TEXT NOT NULL DEFAULT '',
    definitions       TEXT NOT NULL DEFAULT '[]',
    related_phrases   TEXT NOT NULL DEFAULT '',
    structure_meta    TEXT NOT NULL DEFAULT '',
    level             TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_literature_cards (
    id                TEXT PRIMARY KEY,
    full_text         TEXT NOT NULL DEFAULT '',
    translation       TEXT NOT NULL DEFAULT '',
    author            TEXT NOT NULL DEFAULT '',
    genre             TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_humanities_cards (
    id                TEXT PRIMARY KEY,
    node_type         TEXT NOT NULL DEFAULT '',
    body              TEXT NOT NULL DEFAULT '',
    period            TEXT NOT NULL DEFAULT '',
    region            TEXT NOT NULL DEFAULT '',
    tags              TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE
);
```

> **结构统一**：`prebuilt_science_cards` 和 `user_science_cards` 列完全一样，只有 FK 目标不同。所有子表不存名称——名称统一在父表 `front` 字段。

## 4. 保留不变的表

| 表 | 说明 |
|:--|:--|
| `card_memory` | `user_card_id` 引用 `user_cards.id`，列结构不变 |
| `review_log` | `user_card_id` 引用 `user_cards.id` |
| `user_plan_progress` | `plan_id` 引用 `plan_runs.id` |
| `conversations` | 完全不变 |
| `conversation_turns` | 完全不变 |
| `users` / `tokens` | 完全不变 |
| `achievements` | 完全不变 |
| `admin_users` / `subscription_requests` / `admin_audit_log` / `guardian_assignments` | 完全不变 |

## 5. 核心查询模式

### 5.1 取用户某张卡（含内容）

```sql
-- 统一路由：先查 user_cards，再根据 prebuilt_card_id 和 domain 分支
SELECT uc.id, uc.domain, uc.status, uc.prebuilt_card_id, uc.front,
       cm.difficulty, cm.stability, cm.due
FROM user_cards uc
LEFT JOIN card_memory cm ON cm.user_card_id = uc.id
WHERE uc.id = ?;

-- 应用层路由：
-- prebuilt_card_id IS NOT NULL AND domain = science → prebuilt_science_cards
-- prebuilt_card_id IS NULL     AND domain = science → user_science_cards
-- （其他 domain 同理）
```

### 5.2 取用户某个 plan 的所有卡

```sql
SELECT uc.id, uc.domain, uc.prebuilt_card_id,
       COALESCE(uc.front, pc.front) AS front, pc.card_type,
       cm.difficulty, cm.stability, cm.due
FROM user_cards uc
LEFT JOIN prebuilt_cards pc ON uc.prebuilt_card_id = pc.id
LEFT JOIN card_memory cm ON cm.user_card_id = uc.id
WHERE uc.user_id = ? AND uc.plan_run_id = ?
ORDER BY uc.created_at;
```

### 5.3 复习到期卡

```sql
-- 预置卡
SELECT uc.id, pc.front, pc.card_type, pc.domain,
       cm.difficulty, cm.stability, cm.due
FROM user_cards uc
JOIN prebuilt_cards pc ON uc.prebuilt_card_id = pc.id
JOIN card_memory cm ON cm.user_card_id = uc.id
LEFT JOIN user_plan_progress upp ON uc.plan_run_id=upp.plan_id AND uc.task_key=upp.task_key
WHERE uc.user_id=? AND uc.status='active' AND cm.due<=? AND upp.status IN ('in_progress','done')
UNION ALL
-- CP1 自定义卡
SELECT uc.id, uc.front, NULL AS card_type, uc.domain,
       cm.difficulty, cm.stability, cm.due
FROM user_cards uc
JOIN card_memory cm ON cm.user_card_id = uc.id
LEFT JOIN user_plan_progress upp ON uc.plan_run_id=upp.plan_id AND uc.task_key=upp.task_key
WHERE uc.user_id=? AND uc.status='active' AND cm.due<=? AND upp.status IN ('in_progress','done')
  AND uc.prebuilt_card_id IS NULL;
```

## 6. k12_init 流程

### 6.1 当前流程

```
JSON 解析 → INSERT conversations
           → INSERT conversation_plans (完整 plan JSON)
           → INSERT cards (front/back 内容 × N 张)
           → INSERT card_memory (FSRS)
           → INSERT user_plan_progress
```

### 6.2 改后流程

```
JSON 解析 → INSERT conversations
           → INSERT plan_runs (1 行, plan_content=NULL → 引用 prebuilt_plans)
           → INSERT user_cards (N 行, prebuilt_card_id≠NULL)
           → INSERT card_memory (FSRS, 引用 user_cards.id)
           → INSERT user_plan_progress
           → INSERT plan_stats (初始值: total_tasks, total_cards)
```

**节省**: 英语 12871 张卡从 ~6MB INSERT 降为 ~200KB INSERT（仅写引用）。

## 7. 切换策略：干净切分

### 原则
1. 旧表 `cards` / `conversation_plans` 保留 DDL 不动，但所有读写一次性切换到新表
2. 不存在双写过渡期
3. 回滚方式 = `git revert → cargo build → systemctl restart`

### 旧表数据
VPS 刚清库重部署，无真实用户数据。上线后执行：
```sql
DROP TABLE IF EXISTS cards;
DROP TABLE IF EXISTS conversation_plans;
```

## 8. 实施顺序（一次上线）

| # | 任务 | 范围 | 重点关注 |
|:-:|:--|:--|:--|
| 1 | schema.rs 建 10 张新表 + 明细表 + 删旧表 | schema.rs | 建表顺序：先 `prebuilt_cards` 父表，再子表（FK 依赖）；`card_relations` 无 FK 约束 |
| 2 | 启动时导入 prebuilt_* | curriculum_loader.rs | **先 `prebuilt_cards` 父表，再 `prebuilt_*_cards` 子表**（FK 顺序）；`card_relations` 只导入 `from_type=to_type='prebuilt', user_id=NULL` 的全局关系 |
| 3 | 改 k12_init_handler | routes.rs | INSERT `plan_runs` + `user_cards`（不写子表，复习时 JOIN 预置子表） |
| 4 | 改 copy_prebuilt_card | plan_handler.rs | 只写 `user_cards` + `card_memory`，内容通过 `prebuilt_card_id` 引用 |
| 5 | 改 plan_handler 所有读写 | plan_handler.rs | `conversation_plans` → `plan_runs` |
| 6 | 改 fsrs_scheduler | card_engine/ | 复习核心，`cards` → `user_cards` + 两条数据流分支 |
| 7 | 改 routes.rs 全部查询 | routes.rs | ~35 处 SQL，全部 `cards` → `user_cards` |
| 8 | 改 ws.rs CP1 制卡 | ws.rs | **原子性写入**：`user_cards` + `user_*_cards` 子表 + `card_memory` 必须在同一事务 |
| 9 | 改 admin_handlers.rs | admin_handlers.rs | 管理后台查询走新表 |
| 10 | 改 achievement_engine.rs | achievement_engine.rs | 成就统计改 JOIN |
| 11 | 改 e2e_runner.rs 测试 | e2e_runner.rs | 测试数据写入新表 |
| 12 | 数据迁移：JSON 卡片重生成 + humanities 按 plan 重生成 | scripts/ | 86% 程序化迁移（science/language/literature）；14% 按 plan 重生成（humanities 46 张） |
| 13 | 编译 + 测试 | — | `cargo test` 全部通过 |
| 14 | 部署到 VPS | — | 全量重新编译 + 替换二进制 + 导入新数据 |

## 11. 数据迁移方案

### 11.1 迁移范围

| 数据 | 操作 | 工具 |
|:--|:--|:--:|
| 14 个科目 JSON 卡片（19,861 张） | 旧格式 → 新格式，按 domain 拆分为独立文件 | `scripts/migrate_cards_to_new_schema.py` |
| 14 个 JSON 计划文件 | 加 `domain` 字段 | 同上脚本 |
| `id_mapping.json` / `stage_grade_filter.json` | 废弃（新 schema 不再需要） | 删除 |
| 本地 `coevo.db`（旧 schema 测试数据） | 直接删除重建 | VPS 已清库 |

### 11.2 卡片映射规则（card_type → domain → 子表字段）

#### Science 卡（concept, 1,541 张）

旧 `back` 是结构化 Markdown，正则提取：

```
定义:(.*?)\n关键要素:(.*?)\n应用:(.*?)\n关联:(.*?)(?:\n|$)
  → definition, key_elements, applications, related_concepts
formula: 从 definition 中检测 LaTeX 模式 \(...\) 或 \[...\] 提取
graph: 从 definition 中检测 <graph>...</graph> 提取
source: 直接映射旧字段 source_sentence
```

#### Language 卡（vocabulary, 17,390 张）

旧 `back` 已是 JSON，字段重映射：

| 旧 JSON 字段 | 新表字段 |
|:--|:--|
| `pinyin` / `phonetic` | `pronunciation` |
| `pos` | `pos` |
| `definitions[{pos,meaning,example,translation?}]` | `definitions`（JSON 直通） |
| `common_words` / `collocations` | `related_phrases` |
| `radical` + `strokes` | `structure_meta`（JSON 包装） |
| `cefr_level`（卡片级字段） | `level` |

#### Literature 卡（poem/classical/vernacular/nursery_rhyme/阅读文本, 884 张）

旧 `back` 已是 JSON，精简选取：

| 旧 JSON 字段 | 新表字段 |
|:--|:--|
| `full_text` | `full_text` |
| `translation` | `translation` |
| `author` | `author` |
| `card_type`（→ `genre` 映射） | `genre` |
| `theme`/`technique`/`imagery`/`famous_lines`/`common_mistakes`/`key_grammar`/`key_sentence_patterns`/`vocabulary_focus` | **丢弃**（教学元数据，进提示词） |

#### Humanities 卡（timeline/relationship/rule/skill, 46 张）

数据量极小，且旧 `back` 内容简单（短语列表/关系链），不值得写迁移逻辑。改为**根据 plan 的 task 列表重新生成**：

```python
# 流程：遍历各 humanity 科目的 plan
# 对每个 task，根据 task.name + prompt_mode 生成 humanities_cards 条目
# body = task.name 的扩展说明（提示词模式决定）
# node_type = "event" (timeline) / "concept" (relationship/rule/skill)
```

具体方式：
- `timeline` 卡：从 plan 中按时间顺序提取 task，`node_type=event`，`body` 从 LLM/规则补充关键描述
- `relationship`/`rule`/`skill` 卡：`node_type=concept`，`body` 取 task 的说明文本

46 张卡可在迁移脚本中直接硬编码或由一个独立的 `generate_humanities.py` 脚本生成。

### 11.3 计划文件更新

```diff
 {
+  "domain": "science",           // 新增，按 subject 映射
   "goal": "生物",
   "stages": [...]
 }
```

Subject → domain 映射表：

| subject | domain |
|:--|:--|
| physics/chemistry/biology/math/science/pe | science |
| chinese/english/japanese/russian（vocab 卡） | language |
| chinese/english/japanese/russian（阅读卡） | literature |
| history/geography/politics/it（非 concept 卡） | humanities |

### 11.4 脚本输出目录结构

```
data/curriculum/v4/              ← 新版本目录
├── cards/
│   ├── science/                 ← 按 domain 分目录
│   │   ├── physics.json
│   │   ├── chemistry.json
│   │   └── ...
│   ├── language/
│   │   ├── english.json
│   │   └── ...
│   ├── literature/
│   │   ├── chinese.json
│   │   └── ...
│   └── humanities/
│       ├── history.json
│       └── ...
├── plans/                       ← 计划文件（加 domain 字段）
│   ├── physics.json
│   ├── chemistry.json
│   └── ...
└── relations/                   ← 预置关系（预留，初始为空）
    └── prebuilt.json
```

> **迁移脚本与后端代码交替开发**：脚本在 #12 实施，但需早于 #2（启动时导入），确保导入时读的是新格式。
| 14 | 部署到 VPS | — |

## 9. 数据所有权矩阵

### 全局共享（一份数据，所有用户共用）

| 表 | 写入时机 |
|:--|:--:|
| `prebuilt_cards` | 服务启动时从 JSON 导入 |
| `prebuilt_science_cards` | 服务启动时从 JSON 导入 |
| `prebuilt_language_cards` | 服务启动时从 JSON 导入 |
| `prebuilt_literature_cards` | 服务启动时从 JSON 导入 |
| `prebuilt_humanities_cards` | 服务启动时从 JSON 导入 |
| `card_relations` | 仅 `prebuilt↔prebuilt` 关系全局导入；涉及 user 的全部私有 |
| `prebuilt_plans` | 服务启动时从 JSON 导入 |
| `prebuilt_stages` | 服务启动时解析写入 |
| `prebuilt_tasks` | 服务启动时解析写入 |
| `achievements` | 服务启动时从 TOML 导入 |
| `k12_quiz_bank` | 服务启动时从 JSON 导入 |

> **特点**: 只读，热更新 = 替换文件 + 重启。

### 用户私有（每个用户独立一份）

| 表 | 与全局的关联 |
|:--|:--|
| `user_cards` | `prebuilt_card_id` → `prebuilt_cards.id` |
| `user_science_cards` | `id` → `user_cards.id`（与 `prebuilt_science_cards` 列结构相同） |
| `user_language_cards` | `id` → `user_cards.id` |
| `user_literature_cards` | `id` → `user_cards.id` |
| `user_humanities_cards` | `id` → `user_cards.id` |
| `card_memory` | `user_card_id` → `user_cards.id` |
| `review_log` | `user_card_id` → `user_cards.id` |
| `plan_runs` | `prebuilt_plan_id` → `prebuilt_plans.id` |
| `user_plan_progress` | `plan_id` → `plan_runs.id` |
| `conversations` | — |
| `conversation_turns` | `conversation_id` → `conversations.id` |
| `users` / `tokens` | — |
| `user_preferences` | `user_id` → `users.id` |
| `k12_quiz_attempts` | — |
| `user_stats` | `user_id` → `users.id` |
| `plan_stats` | `plan_id` → `plan_runs.id` |

### 系统/管理

| 表 | 作用 |
|:--|:--|
| `admin_users` | 管理员账号 |
| `subscription_requests` | 订阅审批请求 |
| `admin_audit_log` | 管理操作审计日志 |
| `guardian_assignments` | 家长与学生绑定关系 |

## 10. 实现注意事项

### 10.1 CP1 写入一致性

写入 CP1 自创卡时，`user_cards.front` 与 `user_*_cards` 子表内容必须在**同一事务**中写入：

```rust
// 正确做法
txn.exec("INSERT INTO user_cards (id, user_id, ..., front, ...) VALUES (?, ?, ..., ?, ...)", ...)?;
txn.exec("INSERT INTO user_science_cards (id, definition, ...) VALUES (?, ?, ...)", ...)?;
txn.commit()?;
```

违反时会出现 `user_cards.front` 有值但无子表内容的孤儿记录。

### 10.2 card_relations 无 FK 约束的清理策略

`card_relations` 的 `from_id`/`to_id` 无 FK 约束（因引用两张表），应用层必须主动清理：

| 删除场景 | 清理操作 |
|:--|:--|
| 删除 `prebuilt_cards` 行 | `DELETE FROM card_relations WHERE (from_type='prebuilt' AND from_id=?) OR (to_type='prebuilt' AND to_id=?)` |
| 删除 `user_cards` 行 | `DELETE FROM card_relations WHERE (from_type='user' AND from_id=?) OR (to_type='user' AND to_id=?)` |
| 删除用户账号 | `DELETE FROM card_relations WHERE user_id=?`（已有 CASCADE） |

建议封装为辅助函数 `cleanup_card_relations(conn, card_type, card_id)`。

### 10.3 统计缓存刷新并发

`user_stats` 和 `plan_stats` 的按需刷新+TTL 模式存在并发竞争：

```
请求 A：检查缓存过期 → 触发全量计算 → 正在计算中 ...
请求 B：检查缓存过期 → 触发全量计算 → 重复计算！
```

推荐方案：**数据库级互斥（SQLite 不支持并发写锁争用）** 或**应用层比较并写入**：

```sql
-- 方案：先读，再对比 updated_at 写入
BEGIN;
SELECT updated_at FROM user_stats WHERE user_id=?;
-- 如果当前值已较新则 ROLLBACK，否则计算新值
UPSERT INTO user_stats (user_id, ..., updated_at) VALUES (?, ..., ?);
COMMIT;
```

SQLite 的写锁自然序列化事务——第二个请求的 `BEGIN` 会等待第一个完成，读到的 `updated_at` 已是最新，判断后直接跳过计算。不需额外的互斥锁。

### 10.4 提示词同步更新

schema 变更后，直接生成/消费卡片字段的 prompt 必须同步更新：

| 风险 | Prompt 文件 | 原因 | 修改内容 |
|:--|:--|:--|:--|
| 🔴 严重 | `concept/general/extract.md` | CP1 提取，目前输出 `{front, back, source_sentence, domain}`，`back` 含定义/关键要素/应用/关联子节 | 输出格式改为对应新 schema 的子表字段，或保持 JSON 但适配新结构 |
| 🔴 严重 | `concept/general/direct.md` | CP1 直接制卡，同上输出格式 | 同上 |
| 🟡 语义 | `verify/general/translation.md` | 翻译验证，依赖 `{front}`=单词、`{back}`=释义的语义假设 | 确认新 schema 下 `{back}` 能否继续提供简洁释义；否则改用 `language_cards.definitions` |
| 🟢 轻度 | `quiz/*/generate.md` (4个) | 使用 `{front}`/`{back}` 模板变量，内容格式变化影响出题质量 | 接口不变（仍是 `{back}`），但需评估新 `back` 内容是否适合直接出题 |

**不受影响**：reading 型 prompt（12个，引用 Task/Passage 级字段）、plan 型 prompt（计划分析/创建/信号检测）、chat 型 prompt（free/structured）。
