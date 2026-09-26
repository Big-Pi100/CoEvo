# 预制卡数据修复 + domain/subject 字段统一计划

**日期**: 2026-06-07
**状态**: ✅ Phase 1-5 全部完成

---

## 一、决策记录

| # | 决策 | 说明 |
|---|------|------|
| 1 | `domain` 改为大类 | `language`/`math`/`physics`/...，与 `subject_to_domain()` 对齐 |
| 2 | 课标路由/FSRS调度/卡片查询改为查 `subject` | `domain` 不再参与路由和查询 |
| 3 | 成就系统仍用 `domain` | `domains_covered` 按大类统计，语义正确 |
| 4 | `domain` 和 `subject` 统一用英文 | 消除中英文混用 |
| 5 | `curriculum_guide.json` / `knowledge_graph.json` 相关代码 | 直接删掉（死代码，文件不存在，函数从未被调用） |

### 完整的 `subject → domain` 映射（改后）

此映射对应 `subject_router.rs` 中 `subject_to_domain()` 函数的新版实现（输入为英文 subject）：

| 英文 subject | domain（大类） | 说明 |
|-------------|---------------|------|
| `"chinese"` | `"language"` | 语文 → 语言大类 |
| `"english"` | `"language"` | 英语 → 语言大类 |
| `"japanese"` | `"language"` | 日语 → 语言大类 |
| `"russian"` | `"language"` | 俄语 → 语言大类 |
| `"math"` | `"math"` | 数学（独大类） |
| `"physics"` | `"physics"` | 物理（独大类） |
| `"chemistry"` | `"chemistry"` | 化学（独大类） |
| `"biology"` | `"biology"` | 生物（独大类） |
| `"history"` | `"history"` | 历史（独大类） |
| `"geography"` | `"geography"` | 地理（独大类） |
| `"politics"` | `"politics"` | 政治/道法（独大类） |
| `"science"` | `"science"` | 科学（独大类） |
| `"it"` | `"it"` | 信息技术/信息科技 |
| `"pe"` | `"pe"` | 体育/体育与健康 |
| `"art"` | `"art"` | 美术/音乐/艺术（合并） |
| `"labor"` | `"labor"` | 劳动（独大类） |
| 其他/`"_"` | `"general"` | 未知科目兜底 |

> 对应新版 `subject_to_domain()` 函数体：
> ```rust
> fn subject_to_domain(subject: &str) -> &'static str {
>     match subject {
>         "chinese" | "english" | "japanese" | "russian" => "language",
>         "math" => "math",
>         "physics" => "physics",
>         "chemistry" => "chemistry",
>         "biology" => "biology",
>         "history" => "history",
>         "geography" => "geography",
>         "politics" => "politics",
>         "science" => "science",
>         "it" => "it",
>         "pe" => "pe",
>         "art" | "music" => "art",
>         "labor" => "labor",
>         _ => "general",
>     }
> }
> ```

---

## 二、现状调查

### 2.1 `domain` 字段现状

| 文件 | 当前 `domain` | 改后 `domain` | `subject` | `subject` 正确？ |
|------|----------------|---------------|----------|----------------|
| `chinese_compulsory.json` | `"语文"` | `"language"` | `"chinese"` | ✅ |
| `japanese_compulsory.json` | `"日语"` | `"language"` | `"japanese"` | ✅ |
| `russian_compulsory.json` | `"俄语"` | `"language"` | `"russian"` | ✅ |
| `english_compulsory.json` | `"english"` | `"language"` | `"english"` | ✅ |
| `english_senior.json` | `"english"` | `"language"` | `"english"` | ✅ |
| 其他理科/文科 JSON | `"math"` / `"physics"` / ... | 同 `subject`（不变） | 同 `domain` | ✅ |

### 2.2 `reading/` 目录卡片问题

| 问题 | 说明 |
|------|------|
| 缺 `domain`/`subject` 字段 | 802 张卡片完全没有这两个字段 |
| `grade_band` 不标准 | 用了 `"小学1-6年级"` 等描述文字，非系统标准值 |
| 从未被加载 | `curriculum_loader.rs` 非递归读取，`reading/` 子目录被跳过 |

### 2.3 `subject_router.rs` 当前状态

**死代码已删除**（2026-06-07 执行）：

删除内容：
- `CurriculumGuide` / `KnowledgeGraph` / `KGNode` / `KGEdge` 结构体
- `CURRICULUM` / `KNOWLEDGE_GRAPH` OnceLock 静态变量
- `GRADE_ORDER` / `COMPULSORY_CATEGORY` / `HIGH_SCHOOL_CATEGORY` 常量
- `init_curriculum()` / `init_knowledge_graph()` 初始化函数
- `get_knowledge_paths()` / `get_band_items()` / `get_curriculum_bounds()` / `get_curriculum_hint()` 查询函数

保留内容：
- `RoutingResult` 结构体（`curriculum_hint` 字段保留但填 `String::new()`）
- `subject_to_domain()` 函数（输入仍为中文，待后续改为英文）
- `grade_to_band()` 函数（不变）
- `build_routing_prompt()` / `parse_routing_response()` / `route()` 函数（`curriculum_hint` 已改为 `String::new()`）

### 2.4 代码引用现状

#### `domain` 字段在代码中的用途

| 位置 | 用途 | 改后 |
|------|------|------|
| `growth.rs` → `domains_covered` | 成就：按 `domain` 去重统计 | ✅ 不改（正是我们要的效果） |
| `fsrs_scheduler.rs` → 读 `c.domain` | FSRS 调度：读入但**不用于过滤** | ✅ 无影响 |
| `card_repository.rs` → INSERT | 写卡时写入 `domain` | 改为写大类（`"language"` 等） |
| `routes.rs` → `WHERE c.domain = ?` | 卡片查询可按 domain 过滤 | ⚠️ 改为按 `subject` 过滤 |
| `prompt_loader.rs` → `get_chat(domain)` | 后向兼容：支持用 domain 查 prompt | ⚠️ 改为传 `subject` |
| `subject_router.rs` → `RoutingResult.domain` | 路由结果中的 domain | 改为英文大类 |
| `achievement_engine.rs` → `c.domain LIKE 'EN::%'` | 统计语言覆盖数 | ⚠️ 需同步修改 |

#### `subject` 字段在代码中的用途

| 位置 | 用途 | 改后 |
|------|------|------|
| `subject_router.rs` → `RoutingResult.subject` | 路由结果中的 subject（目前是中文） | 改为英文 |
| `prompt_loader.rs` → `get_chat(subject)` | 按 subject 加载 `prompts/{category}/{subject}/*.md` | ✅ prompt 目录名已是英文 |
| `routes.rs` → `conversation_plans.subject` | 学习计划存储 subject | ✅ 改为英文 |

### 2.5 补充发现

| 发现 | 说明 |
|------|------|
| `cards` 表缺 `subject` 列 | `schema.sql` 中 `cards` 表有 `domain` 字段但没有 `subject` 字段；需要加列才能按 `subject` 查询 |
| 计划 JSON 文件位置 | 当前 `data/curriculum/v3/*.json`（14 个计划文件）在根目录下；`Paths::prebuilt()` 已有 `plans/` 子目录检测逻辑，但返回路径有 bug |
| `prompts/chat/` 目录 | 已有 14 个英文 subject 子目录，和科目一一对应，无需修改 |

---

## 三、代码影响范围

### 已完成的修改（2026-06-07）

| 文件 | 修改内容 |
|------|---------|
| `subject_router.rs` | 删除 140 行死代码（结构体、静态变量、init/get 函数）；`route()` 中 `get_curriculum_hint()` 改为 `String::new()`；清理文件头注释和未使用 import |
| `main.rs` | 删除 "Knowledge graph loaded" 日志；删除 `CREATE TABLE knowledge_graph` 迁移 SQL（4 条语句） |
| `schema.sql` | knowledge_graph 表定义和索引标记为"已废弃" |

### 待修改的 Rust 文件

| 文件 | 修改内容 |
|------|---------|
| `subject_router.rs` | 1. `subject_to_domain()` 输入改为英文 subject；2. `parse_routing_response()` 解析英文 subject；3. LLM routing prompt 改为要求返回英文 subject |
| `routes.rs` | 卡片查询：`WHERE c.domain = ?` → `WHERE c.subject = ?`；`domains_covered` 统计不变（仍用 `domain`） |
| `ws.rs` / `plan_handler.rs` | `RoutingResult.subject`（英文）传入 `conversation_plans.subject`；`build_plan_context` 使用 `subject` 查询 |
| `card_repository.rs` | INSERT 时 `domain` 写大类（`"language"` 等） |
| `fsrs_scheduler.rs` | 读 `c.domain` 不变（成就统计用） |
| `achievement_engine.rs` | `c.domain LIKE 'EN::%'` 改为按新 `domain` 值判断 |
| `curriculum_loader.rs` | `Paths::prebuilt()` 中 `return dev_path` → `return dev_path.join("plans")`（如果 `plans/` 子目录存在） |
| `schema.sql` / 数据库迁移 | `cards` 表增加 `subject` 列 |

### 待修改的数据文件

| 文件 | 修改内容 |
|------|---------|
| `data/curriculum/v3/cards/chinese_compulsory.json` | 1. `domain` 改为 `"language"`；2. 合并 `reading/` 下 4 个文件的卡片 |
| `data/curriculum/v3/cards/english_compulsory.json` | `domain` 改为 `"language"` |
| `data/curriculum/v3/cards/english_senior.json` | `domain` 改为 `"language"` |
| `data/curriculum/v3/cards/japanese_compulsory.json` | `domain` 改为 `"language"` |
| `data/curriculum/v3/cards/russian_compulsory.json` | `domain` 改为 `"language"` |
| `data/curriculum/v3/reading/chinese_reading.json` | 合并到 `chinese_compulsory.json` 后删除；合并前需补全 `domain`/`subject`/`grade_band` |
| `data/curriculum/v3/reading/chinese_reading_extended.json` | 同上 |
| `data/curriculum/v3/reading/chinese_reading_missing.json` | 同上 |
| `data/curriculum/v3/reading/chinese_reading_primary.json` | 同上 |

### 已删除（死代码，文件不存在）

| 文件 | 说明 |
|------|------|
| ~~`data/curriculum/v3/curriculum_guide.json`~~ | 文件不存在，相关代码已删除 |
| ~~`data/curriculum/v3/knowledge_graph.json`~~ | 文件不存在，相关代码已删除 |

---

## 四、实施步骤

### Phase 1: 数据文件修复

- [x] **Step 1.1** — 修复 `domain` 字段（语言类 5 个 JSON 文件）
  - 执行方式：Python 脚本批量修改 `cards[].domain`
  - 映射规则：
    | 文件 | 当前值 | 改后值 |
    |------|--------|--------|
    | `chinese_compulsory.json` | `"语文"` | `"language"` |
    | `english_compulsory.json` | `"english"` | `"language"` |
    | `english_senior.json` | `"english"` | `"language"` |
    | `japanese_compulsory.json` | `"日语"` | `"language"` |
    | `russian_compulsory.json` | `"俄语"` | `"language"` |
  - 验证：修改后 grep 确认无中文 domain 值

- [x] **Step 1.2** — 为 `reading/` 卡片补全 `domain`/`subject` 字段
  - 涉及文件：`reading/chinese_reading.json`、`reading/chinese_reading_extended.json`、`reading/chinese_reading_missing.json`、`reading/chinese_reading_primary.json`
  - 每张卡补全两个字段：
    - `domain`: `"language"`
    - `subject`: `"chinese"`
  - 注意：当前这些字段为 `null`（缺失），不是错误值，直接写入即可
  - 验证：修改后每张卡均有 `domain` 和 `subject` 字段

- [x] **Step 1.3** — 修复 `reading/` 卡片的 `grade_band`（非标准值 → 标准值）
  - 标准值枚举：`"g1-2"` / `"g3-4"` / `"g5-6"` / `"g7-9"` / `"g10-12"` / `""`
  - 各文件映射规则：
    | 文件 | 当前 `grade_band` | 映射为 |
    |------|------------------|--------|
    | `chinese_reading.json` | `"小学1-6年级"` | 按 `card_type` 判断：poem→`"g1-6"`，classical→`"g7-9"`，需逐张校验 |
    | `chinese_reading.json` | `"初中7-9年级"` | `"g7-9"` |
    | `chinese_reading.json` | `"高中必修"` / `"高中选修"` / `"高中选择性必修"` | `"g10-12"` |
    | `chinese_reading_extended.json` | `"初中外国名篇"` / `"初中整本书阅读"` / `"初中白话文"` | `"g7-9"` |
    | `chinese_reading_extended.json` | `"高中外国名篇"` / `"高中整本书阅读"` / `"高中白话文"` | `"g10-12"` |
    | `chinese_reading_missing.json` | 已是标准值（`"g7-9"` / `"g10-12"`） | 跳过 |
    | `chinese_reading_primary.json` | 已是标准值 | 跳过 |
  - 执行方式：Python 脚本，按文件逐张映射后写回

- [x] **Step 1.4** — 合并 `reading/` → `chinese_compulsory.json`，删除 `reading/` 目录
  - 执行顺序：先完成 Step 1.2（补字段）+ Step 1.3（修 grade_band）
  - 合并逻辑：
    1. 读取 `reading/` 下 4 个 JSON 文件的所有卡片
    2. 对每张卡，尝试用 `front` 字段匹配 `data/curriculum/v3/chinese.json` 中对应 `task.name`，若匹配成功则取该 task 所在 stage 的 `grade_band` 作为标准值（覆盖 Step 1.3 的结果）
    3. 将补齐后的卡片 append 到 `chinese_compulsory.json` 的 `cards` 数组
    4. 验证合并后卡片总数 = 2714 + 802 = 3516
    5. 删除 `reading/` 目录
  - 注意：合并后 `chinese_compulsory.json` 会有多种 `card_type`（vocabulary + classical + poem + vernacular + ...），这是正常且正确的

- [x] **Step 1.5** — 删除 `chinese_compulsory.json` 中 2 张 poem 垃圾卡（跳过，无垃圾卡）
  - 现状：`chinese_compulsory.json` 当前 2714 张卡均为 `card_type=vocabulary`，无 poem 卡
  - 结论：此步骤已无需执行，标注为跳过

- [x] ~~**Step 1.6** — 修改 `curriculum_guide.json`~~ **已删除（死代码，文件不存在）**
- [x] ~~**Step 1.7** — 修改 `knowledge_graph.json`~~ **已删除（死代码，文件不存在）**

### Phase 2: Rust 代码修改

- [x] **Step 2.1** — `subject_router.rs`：`subject_to_domain()` 输入改为英文；`route()` 返回英文 `subject`；更新 LLM routing prompt
  - `subject_to_domain()`：匹配分支从中文改为英文（`"语文"` → `"chinese"`，`"数学"` → `"math"`）；返回值不变（仍为英文 domain 大类）；同步更新 `#[test] fn test_subject_mapping()`
  - `parse_routing_response()`：JSON 解析的 `subject` 字段现在是英文；降级默认值从 `"数学"` 改为 `"math"`
  - LLM routing prompt（`prompts/routing/` 下）：修改 prompt 要求返回英文 subject（`"chinese"` / `"math"` / ...）
  - 降级关键词匹配（`route()` 函数中）：中文关键词改为英文

- [x] **Step 2.2** — `prompt_loader.rs`：确认 `subject` 参数（英文）能正确加载 prompt 文件
  - 已确认：prompts 目录为英文命名，`get_chat("math")` / `get_concept("chinese")` 等正常工作
  - 检查 `get_chat(subject)` / `get_concept(subject)`：`prompts/chat/{subject}/` 目录已确认为英文命名，无须修改

- [x] **Step 2.3** — `routes.rs`：卡片查询从 `WHERE c.domain = ?` 改为 `WHERE c.subject = ?`（成就统计除外）
  - `cards_all_handler`：`WHERE c.domain = ?` → `WHERE c.subject = ?`
  - `cards_by_plan_handler`：检查是否有按 domain 过滤的逻辑，同步修改
  - 成就统计（`domains_covered`）：仍用 `c.domain`（按大类统计），不改
  - ⚠️ 前提：`cards` 表需要先加 `subject` 列

- [x] **Step 2.4** — `ws.rs` / `plan_handler.rs`：使用 `subject`（英文）写入 `conversation_plans.subject`
  - INSERT 已加 `subject` 列；plan_handler 当前写 `subject=""`（路由系统未接入，待后续完善）
  - `ws.rs`：`RoutingResult.subject`（英文）直接写入 `conversation_plans.subject`

- [x] **Step 2.5** — `achievement_engine.rs`：修改语言覆盖统计逻辑
  - 当前代码：`c.domain LIKE 'EN::%'`（旧逻辑，不正确）
  - 修改方案：按 `c.subject` 前缀统计语言覆盖（`"chinese"` / `"english"` / `"japanese"` / `"russian"`）
  - 注意：不能用 `c.domain = 'language'` 因为这样只能统计是否覆盖语言大类，不能统计覆盖了几门语言

- [x] **Step 2.6** — `card_repository.rs`：INSERT 时 `domain` 写入大类值
  - `save_card()` / `create_card()`：INSERT 的 `domain` 字段写入大类值（调用 `subject_to_domain()` 计算）

- [x] **Step 2.7** — `cards` 表加 `subject` 列（Schema 迁移）
  - 在 `schema.sql` 中 `cards` 表加 `subject TEXT DEFAULT NULL`
  - 在 `main.rs` 迁移 SQL 加 `ALTER TABLE cards ADD COLUMN subject TEXT DEFAULT NULL`

### Phase 3: 卡片查询过滤 + 计划文件迁移

- [x] **Step 3.1** — `routes.rs`：`cards_all_handler` 加过滤条件，隐藏非 vocabulary 的预制卡
  - WHERE 条件追加 `AND NOT (c.conversation_id IS NULL AND c.card_type != 'vocabulary')`
  - 语义：预制卡（`conversation_id IS NULL`）且非词汇卡（`card_type != 'vocabulary'`）不返回

- [x] **Step 3.2** — 创建 `data/curriculum/v3/plans/` 目录，移动 14 个计划 JSON 到 `plans/`
  - 涉及文件：`biology.json` / `chemistry.json` / `chinese.json` / `english.json` / `geography.json` / `history.json` / `id_mapping.json` / `it.json` / `japanese.json` / `math.json` / `pe.json` / `physics.json` / `politics.json` / `russian.json` / `science.json`
  - 同时修改 `Paths::prebuilt()`：`return dev_path` → `return dev_path.join("plans")`

### Phase 4: 验证

- [x] **Step 4.1** — `cargo build` 编译通过
  - 执行：`cd E:\CoEvo\backend && cargo build --release`
  - 预期：0 error，允许已有 warning

- [x] **Step 4.2** — 单元测试：`subject_router::tests` 更新
  - `subject_to_domain("语文")` → `subject_to_domain("chinese")`
  - `subject_to_domain("英语")` → `subject_to_domain("english")`
  - 运行：`cargo test subject_router::tests`

- [x] **Step 4.3** — 手动验证：LLM 路由返回英文 subject
  - 启动后端，发测试消息（如"我想学高中语文"）
  - 查看日志，确认 `RoutingResult.subject = "chinese"`

- [x] **Step 4.4** — 手动验证：卡片查询 + 成就统计
  - 验证 1（卡片查询按 `subject` 过滤）：
    - 前端按 subject 查询卡片，确认只返回 vocabulary 卡
    - 非 vocabulary 预制卡（`conversation_id IS NULL AND card_type != 'vocabulary'`）应被过滤
  - 验证 2（成就 `domains_covered` 统计）：
    - 覆盖多门语言课，确认 `domains_covered` 按 `domain` 大类去重
    - 如学习了 chinese + english，应算 `domains_covered = 1`（都是 `domain = "language"`）

### Phase 5: 复习 tab task 级渐进式披露

**注：当前 `review_screen.dart` 已有 plan→tab 渲染架构（`_loadPlans` → TabBar per plan），但数据源是 `conversation_plans` 表（全量 plan），不是 `user_plan_progress` 表。Phase 5 是在现有骨架基础上细化过滤粒度。**

- [x] **Step 5.1** — 后端新增 API：按 task 进度查询卡片
  - 新增接口 `/api/review/cards-by-progress`
  - 输入：`user_id`（token 读取）
  - SQL：
    ```sql
    SELECT c.*, upp.status as task_status, upp.task_key
    FROM cards c
    JOIN user_plan_progress upp ON c.plan_id = upp.plan_id AND c.task_key = upp.task_key
    WHERE upp.user_id = ?1
      AND upp.status IN ('done', 'in_progress')
      AND c.status = 'active'
    ORDER BY upp.status DESC, c.created_at ASC
    ```
  - 语义：
    - `status IN ('done', 'in_progress')` — 已完成和进行中的 task 的卡片都需要复习
    - `ORDER BY upp.status DESC` — `in_progress` 优先于 `done`
    - `c.status = 'active'` — 只展示活跃卡片（不展示已归档/跳过的）

- [x] **Step 5.2** — 前端复习 tab 改造
  - `review_screen.dart`：
    - `_loadPlans()`：数据源从 `client.getPlans()`（全量 plan）改为 `client.getCardsByProgress()`（仅含 `done`/`in_progress` task 的 card）
    - `_loadCards()`：不再需要传 `conversationId` 过滤，API 已按 task 进度过滤好
    - 删除"全部卡片"tab（`const Tab(child: Text('全部卡片'))`）
    - 无活跃 plan（API 返回空）→ 复习 tab 整体隐藏，显示引导提示
  - 展示逻辑：
    - 有活跃 plan → 按 plan 分组、task 分组展示
    - 无活跃 plan → 隐藏 tab，显示引导提示
  - UI 交互：
    - 在 tab 头部或卡片区显示当前 task 名称
    - task 完成后 UX 过渡（自动刷新到下一组卡片）

- [x] **Step 5.3** — 无活跃 plan 时隐藏复习 tab
  - 前端 `review_screen.dart`：加载时先查新 API 返回是否为空
  - 无匹配记录 → 复习 tab 整体不展示，显示引导提示："还没有学习计划，去聊一节课开始吧"
  - 不降级全量显示，没有 plan 就没有卡片

- [x] **Step 5.4** — 验证测试
  - 验证 1（有活跃 plan）：
    - 创建一个有多个 task 的 plan，标记前 2 个 task 为 `done`，第 3 个为 `in_progress`
    - 确认复习 tab 只显示这 3 个 task 的卡片，不显示其他 task 或无关卡
  - 验证 2（无 plan 时）：
    - 新用户无任何 plan → 确认复习 tab 隐藏，显示引导提示
  - 验证 3（FSRS 复习不影响 task 状态）：
    - 对一个 `done` task 下的卡片做复习，确认 task 状态不变
    - task 状态只应通过 `user_plan_progress` 的显式更新来改变

---

## 五、待确认事项

1. ✅ `prompts/chat/` 目录已有英文 subject 子目录 — 已确认
2. ✅ `curriculum_guide.json` / `knowledge_graph.json` — 死代码已删除，无需修改
3. ❓ LLM routing prompt 要求返回英文 subject 后，`subject_router.rs` 的降级关键词匹配（`"数学"` → ...）也需要改为英文关键词，是否接受？
4. ✅ 非语言类的 `domain` 保持与 `subject` 相同，不合并为更大类 — 已确认

---

## 六、最终目标

### 复习 tab 的 task 级渐进式披露

此计划中的所有改动（domain 改为大类、subject 统一英文、卡片按 subject 查询、过滤非词汇预制卡、删除死代码、计划文件迁移到 `plans/` 目录）最终服务于一个核心目标：

> **复习 tab 的卡片按当前学习计划(task)渐进式展示，而非全量堆叠。**

```mermaid
flowchart LR
    A[用户打开复习tab] --> B{有激活的学习计划?}
    B -->|是| C[查 user_plan_progress<br/>status IN ('done','in_progress')]
    B -->|否| D[隐藏复习tab<br/>或显示引导提示]
    C --> E[JOIN cards 表<br/>按 plan_id + task_key]
    E --> F[展示这些卡片供复习]
    F --> G[卡片按 FSRS 调度复习<br/>task 状态不变]
    G --> H{当前 task 卡片<br/>全部复习完毕?}
    H -->|是| I[自动刷新展示下一 task]
    H -->|否| F
```

核心数据流：

```
user_plan_progress                  cards                         review_screen
┌─────────────────┐                ┌─────────────────────┐        ┌──────────────┐
│ user_id          │──JOIN plan_id→│ plan_id              │        │ 按 plan 分组 │
│ plan_id          │──JOIN task_key→│ task_key            │──→     │ 按 task 分组 │
│ task_key         │                │ ...(卡片数据)        │        │ 展示复习     │
│ status:          │                │ status = 'active'   │        │              │
│  ✅ done         │                └─────────────────────┘        └──────────────┘
│  🔄 in_progress  │
│  ⏳ pending (不显示)
└─────────────────┘
```

关键规则：
- `in_progress` 的 task 卡片 **优先展示**（ORDER BY status DESC）
- `done` 的 task 卡片 **仍展示**（FSRS 记忆曲线需要复习）
- `pending` 的 task 卡片 **不展示**（还没学到的内容）
- 卡片复习不影响 `user_plan_progress.task_key.status`（task 状态只由学习对话控制）
- 无活跃 plan 时复习 tab 隐藏（或显示引导提示），不展示任何卡片

关键需求点：
1. 复习 tab 优先展示 **当前激活计划** 的卡片，而非全部卡片
2. 只取 `user_plan_progress.status IN ('done', 'in_progress')` 的 task 对应的卡片
3. 卡片按 **task** 分组展示，`in_progress` 优先
4. 预制卡的 task 级关联（通过 `plan_id` + `task_key`）需要建立
5. 无活跃 plan 时复习 tab 整体隐藏（或显示引导提示），不展示任何卡片
6. FSRS 复习操作不影响 `user_plan_progress` 状态（task 状态由学习对话控制）
