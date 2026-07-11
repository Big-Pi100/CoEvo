# 课程数据管理后台设计

> 文档版本：v2.1 | 2026-06-11

## 一、背景与目标

当前 `curriculum_loader::init()` 在服务器启动时自动运行。存在以下问题：

1. **不可控**：每次重启都重新加载，无法选择性加载科目
2. **数据质量参差**：非英语/语文科目的卡片质量低，不应在生产中展示
3. **无版本管理**：数据变更不可追溯

**目标**：将课程数据管理做成专业的 admin 后台，支持可视化编辑、按需加载、变更追溯。

---

## 二、数据规范

### 2.1 字段枚举约束

`domain` 和 `subject` 为**枚举字段**，Rust 层强校验 + SQLite CHECK 约束（后续迁移时加），禁止随意填入字符串。

#### Domain（领域）

| 枚举值（JSON/DB） | 中文显示 | 说明 |
|:------------------|:---------|:-----|
| `language` | 语言 | 词汇、语法、发音 |
| `science` | 科学 | 概念、定理、公式 |
| `literature` | 文学 | 文本、诗词、赏析 |
| `humanities` | 人文 | 历史、地理、政治 |

#### Subject（学科）

| 枚举值（JSON/DB） | 中文显示 | 说明 |
|:------------------|:---------|:-----|
| `english` | 英语 | — |
| `chinese` | 语文 | — |
| `math` | 数学 | — |
| `physics` | 物理 | — |
| `chemistry` | 化学 | — |
| `biology` | 生物 | — |
| `history` | 历史 | — |
| `geography` | 地理 | — |
| `politics` | 政治 | — |
| `science` | 科学 | 小学科学（综合） |
| `it` | 信息技术 | — |
| `pe` | 体育 | — |
| `art` | 艺术 | — |
| `labor` | 劳动 | — |
| `russian` | 俄语 | — |
| `japanese` | 日语 | — |
| `general` | 通用 | 非 K12 的通用对话 |

> 新增 subject 需要同步更新 Rust 枚举和文档，不允许通过 admin 面板随意创建新 subject。

### 2.2 数据存储规则

| 层面 | 语言 | 示例 |
|:-----|:-----|:------|
| **JSON 文件** | 英文 | `"subject": "english"` |
| **SQLite DB** | 英文 | `subject = 'english'` |
| **admin 界面** | 中文 | 下拉框显示「英语」，保存时传 `"english"` |
| **前端用户界面** | 中文 | tab 显示「英语 G1-2」|

### 2.3 标签（Tags）

`prebuilt_cards.card_type` 为枚举，统一为以下三个值：

| 枚举值（JSON/DB） | 中文显示 | 说明 |
|:------------------|:---------|:-----|
| `vocabulary` | 词汇 | 单词/词组，带音标、词性、释义、短语 |
| `text` | 文本 | 各类阅读材料（对话、书信、报道、说明文、诗词等，统一归类） |
| `concept` | 概念 | 知识点（预置概念卡或 CP1 提取） |

> **备注：** 当前 JSON 文件中 language domain 仍存在 `dialogue`、`informational`、`opinion` 等旧细分类型（共 48 张），science/humanities 使用 `concept`，literature 使用 `poem` 等。这些细分类型在 admin 编辑面板上线后统一迁移——读取时按旧值处理，保存时强制转为 `text` 或 `concept`。

### 2.4 Domain 特定数据结构（子表）

卡片按 `domain` 落入不同的子表。`prebuilt_cards` 主表记录共有字段，子表记录 domain 专属字段。

**主表公共字段：** `id`, `card_type`, `domain`, `subject`, **`grade_band`**, `front`, `difficulty`

> `grade_band` 标记该卡片适用的学段（如 `"g1-2"`），每张 card JSON 中独立存储。admin 编辑时应显示此字段。

**子表字段：**

| Domain | 子表 | 专用字段 | 前端编辑表单 |
|:-------|:-----|:---------|:------------|
| `language` | `prebuilt_language_cards` | `pronunciation`, `pos`, `definitions`, `related_phrases`, `structure_meta`, `level` | 词汇表单（音标 · 词性 · 释义 · 短语） |
| `science` | `prebuilt_science_cards` | `definition`, `key_elements`, `applications`, `related_concepts`, `formula`, `graph`, `source` | 科学概念表单（定义 · 要素 · 应用 · 公式） |
| `literature` | `prebuilt_literature_cards` | `full_text`, `translation`, `author`, `genre` | 文学文本表单（原文 · 译文 · 作者 · 体裁） |
| `humanities` | `prebuilt_humanities_cards` | `node_type`, `body`, `period`, `region`, `tags` | 人文条目表单（类型 · 正文 · 时期 · 地域） |

### 2.5 Prebuilt Plans 扩展字段

`prebuilt_plans` 表结构：

| 字段 | 类型 | JSON 文件来源 | DB 列 | 说明 |
|:-----|:-----|:-------------|:------|:-----|
| `id` | string | JSON 顶层 `id`（无则 `new_v4()`） | `id TEXT PK` | 固化 ID |
| `subject` | string | **从文件名推断**（`english.json` → `"english"`），JSON 中不存储 | `subject TEXT` | 学科代码 |
| `title` | string | JSON 顶层 `title` | `title TEXT` | 计划主标题 |
| `goal` | string | JSON 顶层 `goal` | `goal TEXT` | 副标题/描述 |
| `author` | string | JSON 顶层 `author` | `author TEXT` | 编制方 |
| `domain` | string | JSON 顶层 `domain` | `domain TEXT` | 领域 |
| `grade_band` | string | JSON 顶层 `grade_band` | `grade_band TEXT` | 学段范围 |
| `display_name` | string | JSON 顶层 `display_name` | `display_name TEXT` | 中文显示名 |
| `visible` | boolean | JSON 顶层 `visible` | `visible INTEGER DEFAULT 1` | 前端的 K12 网格可见性 |
| `theme_color` | string | JSON 顶层 `theme_color` | `theme_color TEXT` | hex 色值 |
| `theme_icon` | string | JSON 顶层 `theme_icon` | `theme_icon TEXT` | Material icon 名 |
| `plan_content` | string | loader 自动生成（全量 stages/tasks JSON blob） | `plan_content TEXT` | 冗余备份，不靠此字段 |

> `subject` 从文件名推断：`data/curriculum/v4/plans/{subject}.json`。当前 JSON 文件顶层没有 `subject` 字段，loader 通过文件名确定。后续新增/导入时沿用此约定。
> 同一 `subject` 下可存在多个 plan（如不同出版社），通过 `title` 区分。

**现有数据 backfill 方案：**

已有 14 个科目的 JSON 文件（`data/curriculum/v4/plans/*.json`）缺少这些新字段。用脚本批量补充：

| 字段 | 公式 | 示例（english） |
|:-----|:-----|:---------------|
| `title` | `"{display_name}" + "课标"` | `"英语课标"` |
| `author` | `"课标编制组"`（统一值） | `"课标编制组"` |
| `display_name` | subject → 中文映射字典 | `"英语"` |
| `visible` | japanese/russian = `false`，其余 `true` | `true` |
| `theme_color` | 从 `k12_subjects.dart` 的 fallback 字典取 hex | `"#81C784"` |
| `theme_icon` | 从 `k12_subjects.dart` 的 fallback 字典取 icon 名 | `"language"` |

映射字典（与 `k12_subjects.dart` 一致）：

| subject | display_name | theme_color | theme_icon | visible |
|:--------|:-------------|:------------|:-----------|:--------|
| english | 英语 | `#81C784` | language | true |
| chinese | 语文 | `#64B5F6` | menu_book | true |
| math | 数学 | `#E57373` | calculate | true |
| physics | 物理 | `#FFB74D` | science | true |
| chemistry | 化学 | `#BA68C8` | biotech | true |
| biology | 生物 | `#4DB6AC` | pets | true |
| history | 历史 | `#F06292` | auto_stories | true |
| geography | 地理 | `#4FC3F7` | explore | true |
| politics | 政治 | `#A1887F` | account_balance | true |
| science | 科学 | `#90A4AE` | travel_explore | true |
| it | 信息技术 | `#7986CB` | computer | true |
| pe | 体育 | — | — | true |
| art | 艺术 | — | — | true |
| labor | 劳动 | — | — | true |
| japanese | 日语 | — | — | false |
| russian | 俄语 | — | — | false |

> 无对应 fallback 的科目（pe/art/labor/japanese/russian），`theme_color` 留空，前端使用默认灰。
> backfill 脚本路径：`scripts/backfill_plan_fields.py`

当前 JSON 文件需补充这些字段（同步更新现有 DB 数据）。注意 `subject` 不由 JSON 存储，从文件名推断：

```json
{
  "id": "...",
  "title": "人教版英语",
  "goal": "K12 英语课程标准",
  "author": "人民教育出版社",
  "display_name": "英语",
  "visible": true,
  "domain": "language",
  "grade_band": "g1-12",
  "stages": [
    {
      "id": "...",
      "name": "预备级",
      "sort": 1,
      "grade_band": "g1-2",
      "tasks": [
        {
          "id": "...",
          "task_key": "01-01",
          "name": "Hello",
          "prompt_mode": "dialogue",
          "card_ids": ["..."],
          "dependencies": [],
          "origin": "curriculum_v4",
          "sort_order": 1
        }
      ]
    }
  ]
}
```

> **字段命名差异：** DB 中 stage 排序字段为 `sort_order`，JSON 中为 `sort`。DB 中 task 的 `sort_order` 在 JSON 中为 `sort_order`。loader 处理时自动转换。

### 2.6 前端科目网格动态化

**现状：** `app/lib/config/k12_subjects.dart` 硬编码 13 个科目配置，`visible` 字段控制渲染。新增科目无法自动出现。

**目标：** 前端改为从后端获取可用计划列表。

新增 API 端点：

```
GET /api/k12/subjects
```

返回所有 `visible = 1` 的 `prebuilt_plans`：

```json
[
  {
    "title": "人教版英语",
    "goal": "K12 英语课程标准",
    "author": "人民教育出版社",
    "subject": "english",
    "display_name": "英语",
    "theme_color": "#81C784",
    "theme_icon": "language"
  }
]
```

前端改动：
1. `K12SubjectScreen` 启动时调用 `GET /api/k12/subjects` 加载可用计划列表
2. 每张计划卡片显示 `title`（主标题）+ `goal`（副标题）+ `author`（来源）
3. `k12_subjects.dart` 保留为 **fallback 配置字典**（颜色、图标映射），不再作为数据源
4. API 返回的 `display_name` 为空时，前端 fallback 到 `subject` 代码本身
5. 新 plan 导入 → admin 加载到 DB → 前端刷新后自动出现

## 三、数据文件结构

数据文件结构说明
```
data/curriculum/v4/
├── cards/
│   ├── language/         # 英语/汉语词汇
│   │   ├── prebuilt_cards.json            ← 每行含 id, card_type, domain, subject, grade_band, front
│   │   └── prebuilt_language_cards.json   ← id 关联主表，含 pronunciation, pos, definitions 等
│   ├── science/
│   ├── literature/
│   └── humanities/
├── plans/
│   ├── english.json      # subject 由文件名 "english" 推断，JSON 内不存储
│   │                     # 含 id, title, goal, author, domain, grade_band, display_name, visible
│   │                     # stages[].id, stages[].sort (DB 中为 sort_order), tasks[].id
│   │                     # tasks[].task_key, name, prompt_mode, card_ids, dependencies, origin
│   ├── chinese.json
│   └── ...
```

---

## 四、ID 策略（核心约束）

| 表 | ID 来源 | 编辑器中是否可见 |
|:---|:--------|:----------------|
| 所有预置表 | JSON 文件 `id` 字段 | ❌ **完全隐藏** |
| 新增条目 | loader 自动 `uuid::new_v4()` | 自动生成，不可手动指定 |

### 一致性保证

- loader 使用 `INSERT OR IGNORE`：ID 已存在则跳过，不存在则插入
- JSON 中的 ID 是权威来源，DB 必须与 JSON 完全一致
- **提交的数据中若出现 `id` 字段，后端直接拒绝（400）**

---

## 五、后端 API

### 5.1 状态查询

```
GET /api/admin/curriculum/status
```

返回所有科目及其 JSON 文件存在状态、DB 加载状态、卡片/计划统计。

### 5.2 按需加载

```
POST /api/admin/curriculum/load
{ "subjects": ["english", "chinese"] }
```

对每个科目：清空 DB 中该科目数据 → 从 JSON 重新加载。返回加载结果统计。

### 5.3 结构化数据 CRUD

#### 小改：单实体操作（即写即用，不触发重新加载）

```
PATCH  /api/admin/curriculum/subject/{subject}/plan/stages/{stageId}
PATCH  /api/admin/curriculum/subject/{subject}/plan/stages/{stageId}/tasks/{taskId}
PATCH  /api/admin/curriculum/subject/{subject}/cards/{cardId}
```

- 同时更新 DB 对应行 + JSON 文件中对应条目
- 不触发 curriculum_loader，即时生效
- `id` 字段不可传，传则 400

#### 新增/删除：单实体操作（同时写 JSON + DB）

```
POST   /api/admin/curriculum/subject/{subject}/plan/stages
POST   /api/admin/curriculum/subject/{subject}/plan/stages/{stageId}/tasks
POST   /api/admin/curriculum/subject/{subject}/cards
POST   /api/admin/curriculum/plan                                ← 新增完整计划
DELETE /api/admin/curriculum/subject/{subject}/plan/stages/{stageId}
DELETE /api/admin/curriculum/subject/{subject}/plan/stages/{stageId}/tasks/{taskId}
DELETE /api/admin/curriculum/subject/{subject}/cards/{cardId}
```

新增计划 `POST /api/admin/curriculum/plan`：

```json
{
  "subject": "english",
  "title": "人教版英语",
  "goal": "K12 英语课程标准",
  "author": "人民教育出版社",
  "display_name": "英语",
  "visible": true,
  "domain": "language"
}
```

- 后端自动生成 `id`（`new_v4()`），补充空 `stages: []` 结构
- 创建 JSON 文件 `data/curriculum/v4/plans/{subject}.json`（如已存在则拒绝——使用导入做全量替换）
- 不触发加载，新 plan 显示为「未加载」
- 其他新增/删除同样自动生成 `id`，同时写 DB + JSON

#### 大改：批量操作（写 JSON → 按科目重新加载）

```
PUT /api/admin/curriculum/subject/{subject}/plan
PUT /api/admin/curriculum/subject/{subject}/cards?domain=language
```

流程：
1. 将提交的完整数据写入 JSON 文件
2. 自动触发该科目的全量重新加载（清空 DB → 从 JSON 重新导入）
3. 由于 ID 已固化，`plan_runs.prebuilt_plan_id` 不受影响

### 5.4 JSON 模板下载

提供 JSON 模版文件下载，用于离线编辑后导入：

```
GET  /api/admin/curriculum/templates/plan               → plan JSON 模版（stages → tasks 结构）
GET  /api/admin/curriculum/templates/cards?domain=language  → language 卡片 JSON 模版
GET  /api/admin/curriculum/templates/cards?domain=science   → science 卡片 JSON 模版
GET  /api/admin/curriculum/templates/cards?domain=literature  → literature 卡片 JSON 模版
GET  /api/admin/curriculum/templates/cards?domain=humanities  → humanities 卡片 JSON 模版
```

模版内容为含类型标注的空结构示例（每 domain 2-3 条示例数据，`id` 字段不出现），标注字段名、类型 、是否必填。

### 5.5 JSON 数据导入

```
POST /api/admin/curriculum/subject/{subject}/plan/import      → 导入 plan JSON 文件
POST /api/admin/curriculum/subject/{subject}/cards/import?domain=language  → 导入卡片 JSON 文件
```

**导入规则（严格验证）：**

| 检查项 | 规则 |
|:-------|:-----|
| 字段名匹配 | JSON 中的 key 必须与模版完全一致，多余/缺失字段均拒绝 |
| 字段类型匹配 | 字符串字段必须为 string，数组字段必须为 array，数字字段必须为 number |
| `id` 字段 | 导入数据中**不能包含** `id` 字段（所有 ID 由后端自动生成） |
| 必填字段 | 模版中标记为 required 的字段缺失则拒绝 |
| domain 一致性 | 导入时指定的 `domain` 必须与数据实际内容匹配 |
| subject 一致性 | 导入时指定的 `subject` 必须与数据中的 `subject` 值匹配 |

**导入流程：**
1. 后端读取导入 JSON，对照 domain 的 JSON Schema 逐字段校验
2. 字段名不匹配 → 返回 400 + 具体错误（哪个字段、预期什么）
3. 字段类型不匹配 → 返回 400 + 具体错误（预期 string 但收到 number）
4. 验证通过 → 写入 JSON 文件：
   - **卡片导入**：追加到该 domain 的对应 JSON 文件中（`{subject}/cards/{domain}/prebuilt_cards.json`）
   - **计划导入（已有科目）**：**全量替换**该科目的 JSON 文件（`plans/{subject}.json`）
   - **计划导入（新科目）**：创建新 JSON 文件（`plans/{subject}.json`）
5. **不触发重新加载**。导入的数据在科目列表页显示为「未加载」，由 admin 勾选后手动点击「加载选中科目」才写入 DB

所有写操作自动 `git add && git commit`。

---

## 六、Admin 前端设计（重点）

整体风格：**简洁、信息密集、可操作性强**。参考 Notion / Linear / Vercel 的设计语言。

### 5.1 布局

```
┌─────────────────────────────────────────────────────────────┐
│  CoEvo Admin                                   头像 ▼      │  ← 顶栏
├──────────┬──────────────────────────────────────────────────┤
│          │                                                  │
│  仪表盘   │  内容区域                                         │
│  用户管理  │                                                  │
│  课程数据  │                                                  │  ← 主内容
│  ...      │                                                  │
│          │                                                  │
├──────────┴──────────────────────────────────────────────────┤
│  状态栏                                                      │  ← 底栏
└─────────────────────────────────────────────────────────────┘
```

### 5.2 科目列表页（课程数据入口）

```
┌──────────────────────────────────────────────────────────────┐
│  课程数据管理                            最后加载: 刚刚       │
│                                                                  │
│  ┌─── 搜索科目 ────────────────────────────────────────────┐  │
│  │  🔍  输入科目名称...                    [+ 新增计划]     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  [学习计划]  [卡片数据]                                         │  ← Tab 切换
│                                                                  │
│  ──── 学习计划 tab ────────────────────────────────────────── │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  □  全选                              [加载选中科目]      │  │
│  ├──────────────────────────────────────────────────────────┤  │
│  │  ☑  🟢 英语    已加载  ▸  4 stages · 80 tasks           │  │
│  │        人教版英语 · 课标编制组 · 最后加载: 2026-06-11         │  │
│  │                                                          │  │
│  │  ☑  🔵 语文    已加载  ▸  131 stages · 649 tasks        │  │
│  │        语文课标 · 课标编制组 · 最后加载: 2026-06-11          │  │
│  │                                                          │  │
│  │  ☐  🔴 数学    未加载  ▸  JSON 存在 (249 cards)          │  │
│  │        数学课标 · 课标编制组                                │  │
│  │                                                          │  │
│  │  ☐  🟠 物理    未加载  ▸  JSON 存在 (260 cards)          │  │
│  │  ☐  🟣 化学    未加载  ▸  JSON 存在                     │  │
│  │  ☐  🟢 生物    未加载  ▸  JSON 存在                     │  │
│  │  ☐  🩷 历史    未加载  ▸  JSON 存在                     │  │
│  │  ☐   🩵 地理   未加载  ▸  JSON 存在                     │  │
│  │  ☐  🤎 政治    未加载  ▸  JSON 存在                     │  │
│  │  ☐  ⬜ 科学    未加载  ▸  JSON 存在                     │  │
│  │  ☐  🩶 信息技  未加载  ▸  JSON 存在                     │  │
│  │  ☐  ⬜ 体育    未加载  ▸  JSON 存在                     │  │
│  │  ☐  ⬜ 艺术    未加载  ▸  JSON 存在                     │  │
│  │  ☐  ⬜ 劳动    未加载  ▸  JSON 存在                     │  │
│  │  ☐  ⬜ 日语    未加载  ▸  JSON 存在 (hidden)            │  │
│  │  ☐  ⬜ 俄语    未加载  ▸  JSON 存在 (hidden)            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ──── 卡片数据 tab ────────────────────────────────────────── │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  ☑ 全选                         [加载选中科目]            │  │
│  ├──────────┬────────┬──────────────┬──────────────────────┤  │
│  │ 科目     │ 已加载  │ domain       │ 卡片数               │  │
│  ├──────────┼────────┼──────────────┼──────────────────────┤  │
│  │ 🟢 英语  │ ✅     │ language     │ 12,791 张            │  │
│  │          │ ✅     │ literature   │ 58 张                │  │
│  ├──────────┼────────┼──────────────┼──────────────────────┤  │
│  │ 🔵 语文  │ ✅     │ language     │ 2,714 张             │  │
│  │          │ ✅     │ literature   │ 731 张               │  │
│  ├──────────┼────────┼──────────────┼──────────────────────┤  │
│  │ 🔴 数学  │ ❌     │ science      │ 249 张 (未加载)      │  │
│  │ 🟠 物理  │ ❌     │ science      │ 260 张 (未加载)      │  │
│  │ 🟣 化学  │ ❌     │ science      │ (未加载)              │  │
│  │ 🟢 生物  │ ❌     │ science      │ (未加载)              │  │
│  │ 🩷 历史  │ ❌     │ humanities   │ (未加载)              │  │
│  │ 🩵 地理  │ ❌     │ humanities   │ (未加载)              │  │
│  │ 🤎 政治  │ ❌     │ humanities   │ (未加载)              │  │
│  │ ⬜ 科学  │ ❌     │ science      │ (未加载)              │  │
│  │ 🩶 信息技术│ ❌   │ science      │ (未加载)              │  │
│  │ ⬜ 体育  │ ❌     │ science      │ (未加载)              │  │
│  │ ⬜ 艺术  │ ❌     │ humanities   │ (未加载)              │  │
│  │ ⬜ 劳动  │ ❌     │ humanities   │ (未加载)              │  │
│  │ ⬜ 日语  │ ❌     │ language     │ (未加载)              │  │
│  │ ⬜ 俄语  │ ❌     │ language     │ (未加载)              │  │
│  └──────────┴────────┴──────────────┴──────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  最近变更                                                    │  │
│  │  2026-06-11 22:00  english: 修改 5 条 vocabulary 释义      │  │
│  │  2026-06-10 15:30  math: 新增 3 个 concept 卡片            │  │
│  │  2026-06-09 10:00  init: curriculum v4 baseline             │  │
│  │  [查看全部 git log]                                         │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

#### 交互行为

- 每行可 hover，显示操作按钮（加载/编辑/详情）
- 搜索科目实时过滤列表
- 勾选后「加载选中科目」按钮出现，点击后显示进度
- **学习计划 tab**：按科目展示 stages/tasks 加载状态
- **卡片数据 tab**：按科目 + domain 细分展示各类型卡片数量及加载状态
- 搜索框旁的 **[+ 新增计划]** 按钮，点击打开创建表单

#### 新增计划对话框

```
┌── 新增计划 ───────────────────────────────────────────────┐
│                                                              │
│  * Subject  [english ▼]         (从已有 subject 选择，决定文件名) │
│  * Title    人教版英语                                       │
│  * Goal     K12 英语课程标准                                 │
│    Author   人民教育出版社                                   │
│    Display  英语                    (中文显示名)              │
│    Visible  ☑ 在 K12 网格中展示                              │
│    Domain   [language ▼]                                    │
│                                                              │
│  主题色:  [■■■■■■■■■■■■■■■]  🎨 拾色器                    │
│           ┌──────────────────────────┐                       │
│           │ #81C784                  │                       │
│           └──────────────────────────┘                       │
│  图标:    [🔍 搜索图标...]  [language ▼]                    │
│           ▸ 预览:  🟢 英语                                   │
│                                                              │
│  创建后将自动生成:                                            │
│  - 空 JSON 文件: plans/english.json                         │
│  - 空结构和 ID（stages/tasks 后续通过编辑面板添加）          │
│                                                              │
│  [取消]                          [创建计划]                 │
└──────────────────────────────────────────────────────────────┘
```

**创建流程：**
1. 选择 `subject`（从已有 subject 枚举中选择，或输入新值需同步更新 Rust 枚举）
2. 填写 `title`, `goal`, `author`, `display_name`, `visible`, `domain`
3. 提交后后端生成 `id`（`new_v4()`），创建完整 JSON 文件：`data/curriculum/v4/plans/{subject}.json`
4. 文件包含空的 `stages: []` 结构
5. 新计划出现在科目列表页，状态为「未加载」
6. admin 勾选后点击「加载选中科目」写入 DB

> 新增 `subject`（首次出现的学科）需同步更新 Rust 枚举和文档。同 subject 下新增不同 `title` 的 plan 则不需要。

### 5.3 科目详情页（编辑入口）

从列表点击某科目进入。

```
┌──────────────────────────────────────────────────────────────┐
│  ←  课程数据管理                                              │
│                                                                  │
│  🟢 英语（人教版英语）                      [重新加载此科目]  │
│  G1-12 · 已加载 · 课标编制组 · 最后修改: 2026-06-11           │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  学习计划                              4 stages · 80 tasks│  │
│  │  ──────────────────────────────────────────────────────── │  │
│  │  ▸  预备级（A1）       15 tasks                          │  │
│  │  ▸  基础级（A2）       20 tasks                          │  │
│  │  ▸  进阶级（B1）       25 tasks                          │  │
│  │  ▸  高级（B2）         20 tasks                          │  │
│  │                                                          │  │
│  │  [+ 新增 Stage]                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  卡片数据                                                 │  │
│  │  ┌──────────┬───────┬──────────┬──────────┐              │  │
│  │  │ domain   │ 类型  │ 数量     │ 操作     │              │  │
│  │  ├──────────┼───────┼──────────┼──────────┤              │  │
│  │  │ language │ vocab │ 12,791   │ [管理]   │              │  │
│  │  │ literature│ poem │ 6        │ [管理]   │              │  │
│  │  │ ...      │       │          │          │              │  │
│  │  └──────────┴───────┴──────────┴──────────┘              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  版本历史                                                    │  │
│  │  2026-06-11  22:00  english: 修改 5 条 vocabulary 释义      │  │
│  │  2026-06-09  10:00  init: curriculum v4 baseline             │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### 5.4 Stage 编辑面板

点击 Stage 行展开，显示 tasks 列表。**字段命名注意：** DB 列名为 `sort_order`（TEXT），JSON 文件中存为 `sort`（number）。后端 loader 读写时自动转换。

```
┌──────────────────────────────────────────────────────────────┐
│  ▸  预备级（A1）                    [收起] [编辑名称] [删除]    │
│                                                                  │
│  ┌──────────┬──────────────┬──────────┬──────────┐           │
│  │ task_key │ name         │ prompt   │ 关联卡片  │           │
│  ├──────────┼──────────────┼──────────┼──────────┤           │
│  │ 01-01    │ Hello        │ dialogue │ 12 张   │  [编辑]   │
│  │ 01-02    │ Numbers      │ quiz     │ 8 张    │  [编辑]   │
│  │ ...      │              │          │         │           │
│  └──────────┴──────────────┴──────────┴──────────┘           │
│                                                                  │
│  [+ 新增 Task]                                                 │
└──────────────────────────────────────────────────────────────┘
```

#### 卡片-任务绑定（Task 编辑核心）

点击 task 的 [编辑] 打开表单，**卡片绑定区域**如下：

```
┌── 编辑 Task: 01-01 Hello ─────────────────────────────────┐
│                                                              │
│  Task Key   01-01                                            │
│  Name       Hello                                            │
│  Prompt     dialogue                                         │
│  Sort Order 1                       (JSON: \"sort\": 1)      │
│  Dependencies []                     (JSON: \"dependencies\") │
│  Origin     curriculum_v4            (JSON: \"origin\")       │
│                                                              │
│  ── 卡片绑定 ──────────────────────────────────────────── │
│                                                              │
│  当前绑定的卡片:                              12 张          │
│  ┌────────────────────────────────────────────────────┐     │
│  │  hello        vocabulary  A1            [解除绑定]  │     │
│  │  goodbye      vocabulary  A1            [解除绑定]  │     │
│  │  how are you  vocabulary  A1            [解除绑定]  │     │
│  │  ...                                               │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  添加卡片:                                                    │
│  ┌─── 搜索 ─────────────────────────────────────────────┐  │
│  │  🔍  输入 front 或释义...                            │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐     │
│  │  ☐  hello (A1) — 当前已被 01-02 Numbers 绑定  ⚠️  │     │
│  │  ☐  world (A1) — 未绑定                           │     │
│  │  ☐  teacher (A1) — 未绑定                         │     │
│  │  ...                                               │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  [取消]                          [保存]                    │
└──────────────────────────────────────────────────────────────┘
```

#### 卡片-计划绑定规则

| 操作 | 规则 |
|:-----|:-----|
| **绑定卡片到 task** | 只能选择**当前未被其他 task 绑定**的卡片。已被绑定的卡片显示 ⚠️ 且不可勾选 |
| **解除绑定** | 点击卡片旁的 [解除绑定]，该卡片立即从当前 task 的 `card_ids` 中移除 |
| **重新绑定** | 必须先解除旧绑定，再搜索并勾选新 task |
| **唯一性校验** | 后端在保存时校验：同 `prebuilt_card_id` 不能出现在同科目的多个 task 的 `card_ids` 中 |
| **跨科目** | 不涉及。每张卡片属于特定 `subject`，数据集天然隔离，不存在跨科目绑定的场景 |

#### 绑定变更流程示例

```
场景: 想把 "hello" 从 task 01-01 移到 task 01-02
步骤:
  1. 打开 task 01-01 编辑 → 点击 "hello" 旁 [解除绑定]
  2. 打开 task 01-02 编辑 → 搜索 "hello" → 勾选 → 保存
  3. 后端校验通过 → 写入 JSON + DB
```

这也从机制上解决了此前 `card_ids` 跨 task 重复的问题——\*\*同一张卡片无法同时绑定到同一个科目的两个 task。\*\*

### 5.5 卡片管理页

从科目详情页点击某个 domain 的 [管理] 进入。每张卡片由 `(subject, domain)` 唯一确定，不同 domain 的卡片数据结构不同，表格列和编辑表单随 domain 自动切换。

**进入路径示例：**

| 科目 | domain | URL/面包屑 | 卡片数 |
|:-----|:-------|:-----------|:-------|
| 🟢 英语 | language | `英语 / language 词汇` | 12,791 |
| 🟢 英语 | literature | `英语 / literature 文本` | 58 |
| 🔵 语文 | language | `语文 / language 词汇` | 2,714 |
| 🔵 语文 | literature | `语文 / literature 文本` | 731 |

#### language 词汇表（示例表格）

```
┌──────────────────────────────────────────────────────────────┐
│  ←  🟢 英语 / language 词汇                   12,791 张      │
│                                                                  │
│  ┌─── 搜索 ────────────────────┬─── 过滤 ────────────────┐  │
│  │  🔍  输入 front 或释义...    │  Level: [All ▼]          │  │
│  └──────────────────────────────┴────────────────────────┘  │
│                                                                  │
│  ┌──────┬──────────┬────────────┬────────┬──────────┐      │
│  │ front│ 音标     │ 词性       │ 释义   │ level   │      │
│  ├──────┼──────────┼────────────┼────────┼──────────┤      │
│  │ be   │ /biː/   │ v.         │ 是     │ A1      │  ⋮   │
│  │ happy│ /ˈhæpi/ │ adj.       │ 快乐   │ A1      │  ⋮   │
│  │ ...  │          │            │        │          │      │
│  └──────┴──────────┴────────────┴────────┴──────────┘      │
│                                                                  │
│  [ + 新增卡片 ]                             1-20 / 12,791   │
└──────────────────────────────────────────────────────────────┘
```

#### science 概念表（示例表格）

```
┌──────────────────────────────────────────────────────────────┐
│  ←  🔴 数学 / science 概念                      249 张       │
│                                                                  │
│  ┌─── 搜索 ───────────────────────────────────────────────┐  │
│  │  🔍  输入概念名称或定义...                              │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────┬──────────────┬──────────────┬───────────┐     │
│  │ front    │ 定义         │ 关键要素     │ 应用      │     │
│  ├──────────┼──────────────┼──────────────┼───────────┤     │
│  │ 数形结合 │ 通过数与形   │ 数、形、     │ 函数图像  │     │
│  │          │ 的相互转化    │ 转化关系     │          │     │
│  │ ...      │              │              │           │     │
│  └──────────┴──────────────┴──────────────┴───────────┘     │
│                                                                  │
│  [ + 新增卡片 ]                                 1-20 / 249 │
└──────────────────────────────────────────────────────────────┘
```

#### 卡片编辑弹窗

编辑弹窗的字段根据 `domain` 自动切换，只显示该 domain 子表的相关字段。

**language domain / card_type=vocabulary（词汇表单）：**

```
┌── 编辑词汇卡片 ────────────────────────────────────────────┐
│                                                              │
│  Front        hello        [🔊 发音预览]                    │
│  音标         /həˈloʊ/                                      │
│  词性         int./n./v.                                     │
│                                                              │
│  释义                                                       │
│  ┌────────────────────────────────────────────────────┐     │
│  │ [ { "meaning": "你好", "examples": ["Hello!"] } ] │     │
│  │ [ + 添加释义 ]                                     │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  常用短语/搭配                                               │
│  ┌────────────────────────────────────────────────────┐     │
│  │ say hello, hello world, hello kitty               │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  结构说明       (语法结构/构词分析，JSON: structure_meta)    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ [{"point": "感叹词", "example": "Hello!"}]        │     │
│  │ [ + 添加结构点 ]                                   │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  Level        A1                                             │
│  Grade Band   g1-2                                           │
│                                                              │
│  [删除此卡片]                    [取消]    [保存]           │
└──────────────────────────────────────────────────────────────┘
```

**science domain / card_type=concept（概念表单）：**

```
┌── 编辑概念卡片 ───────────────────────────────────────────┐
│                                                              │
│  概念名称    数形结合思想                                    │
│  定义        通过数与形的相互转化来分析和解决问题              │
│                                                              │
│  关键要素                                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 数、形、转化关系                                   │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  应用场景                                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 函数图像分析、几何证明                            │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  相关概念                                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 函数、坐标系、方程                                │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  公式         (选填)                                         │
│  图表路径     (选填, JSON: graph)                             │
│  来源         (选填, JSON: source)                            │
│  Grade Band   g7-9                                           │
│                                                              │
│  [删除此卡片]                    [取消]    [保存]           │
└──────────────────────────────────────────────────────────────┘
```

**literature domain / card_type=text（文学文本表单）：**

```
┌── 编辑文本卡片 ───────────────────────────────────────────┐
│                                                              │
│  Front       题西林壁                                         │
│  原文                                                       │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 横看成岭侧成峰，远近高低各不同。                      │     │
│  │ 不识庐山真面目，只缘身在此山中。                      │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  译文         (选填)                                         │
│  ┌────────────────────────────────────────────────────┐     │
│  │                                                    │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  作者         苏轼                                            │
│  体裁         poem                                           │
│  Grade Band   g3-4                                           │
│                                                              │
│  [删除此卡片]                    [取消]    [保存]           │
└──────────────────────────────────────────────────────────────┘
```

**language domain / card_type=text（语言文本表单——对话/书信/报道等）：**

此类卡片使用 `prebuilt_language_cards` 子表，但只填语法结构分析，不填音标/词性/释义。

```
┌── 编辑文本卡片 ───────────────────────────────────────────┐
│                                                              │
│  Front       What's Your Name?                               │
│  card_type   text                     (原值: dialogue)       │
│                                                              │
│  语法结构分析 (JSON: structure_meta)                          │
│  ┌────────────────────────────────────────────────────┐     │
│  │ [ {"point": "疑问句 What/Who",                   │     │
│  │     "example": "What's your name?" } ]           │     │
│  │ [ + 添加结构点 ]                                   │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  Level        A1                                             │
│  Grade Band   g1-2                                           │
│                                                              │
│  [删除此卡片]                    [取消]    [保存]           │
└──────────────────────────────────────────────────────────────┘
```

**humanities domain / card_type=concept（人文条目表单）：**

```
┌── 编辑人文卡片 ───────────────────────────────────────────┐
│                                                              │
│  Front       原始社会                                         │
│  正文                                                       │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 人类社会发展最初的社会形态，以生产资料公有制和平均分配    │     │
│  │ 为特征。                                              │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  条目类型     concept                                        │
│  时期         (选填)                                         │
│  地域         (选填)                                         │
│  标签                                                       │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 原始社会, 历史                                      │     │
│  └────────────────────────────────────────────────────┘     │
│  Grade Band   compulsory                                     │
│                                                              │
│  [删除此卡片]                    [取消]    [保存]           │
└──────────────────────────────────────────────────────────────┘
```

每条记录只显示所属 `(domain, card_type)` 的字段。

**literature / humanities domain** 同理按 2.4 节的字段表自动切换表单。每条记录只显示所属 domain 的字段。

- 新增卡片：打开空白弹窗，提交后后端生成 id
- 删除卡片：二次确认弹窗，确认后从 JSON 移除
- 批量删除：表格行勾选 + 「删除选中」按钮

### 5.6 加载进度

点击「加载选中科目」后显示进度弹窗：

```
┌── 正在加载课程数据 ───────────────────────────────────────┐
│                                                              │
│  🟢 英语     ✅ 已完成 (12,871 cards, 4 stages)              │
│  🔵 语文     ⏳ 正在加载计划... (131/131 stages)             │
│  🔴 数学     ⏳ 正在加载卡片... (249/249 cards)              │
│                                                              │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━░░░░░░░░  68%                   │
│                                                              │
│  [后台运行]                                                  │
└──────────────────────────────────────────────────────────────┘
```

### 5.7 卡片关系图（Card Relations）

`card_relations` 表存储卡片之间的关联关系，构成知识图谱的边。目前表结构已存在，数据为空。

**表结构：**

| 字段 | 类型 | 说明 |
|:-----|:-----|:------|
| `from_type` | TEXT | 源节点类型（`prebuilt_card` / `user_card` / `concept`） |
| `from_id` | TEXT | 源节点 ID |
| `to_type` | TEXT | 目标节点类型 |
| `to_id` | TEXT | 目标节点 ID |
| `relation_type` | TEXT | 关系类型（见下方枚举） |
| `description` | TEXT | 关系描述 |
| `metadata` | TEXT | 扩展信息（JSON） |
| `sort_order` | INTEGER | 排序 |

**relation_type 枚举：**

| 枚举值 | 中文显示 | 说明 |
|:-------|:---------|:-----|
| `prerequisite` | 前置知识 | A 是 B 的前置知识 |
| `related` | 相关概念 | A 与 B 相关联 |
| `part_of` | 组成部分 | A 是 B 的一部分 |
| `example_of` | 示例 | A 是 B 的一个实例 |
| `contradicts` | 对立 | A 与 B 对立/对比 |

#### 关系编辑界面

从科目详情页进入「关系图谱」tab：

```
┌──────────────────────────────────────────────────────────────┐
│  ←  🟢 英语                                               │
│                                                                  │
│  [学习计划]  [卡片数据]  [关系图谱]                              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                                                          │  │
│  │   ┌───────┐                                             │  │
│  │   │ hello │──── prerequisite ────► ┌────────┐           │  │
│  │   └───────┘                        │ goodbye │           │  │
│  │       │                            └────────┘           │  │
│  │       │ related                                           │  │
│  │       ▼                                                   │  │
│  │   ┌───────┐                                              │  │
│  │   │  hi   │                                              │  │
│  │   └───────┘                                              │  │
│  │                                                          │  │
│  │  [🖱️ 拖拽画布 · 🔍 缩放 · ➕ 添加节点 · ➖ 删除边]        │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ── 边列表（选中节点后显示） ─────────────────────────────── │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  hello  →  goodbye    prerequisite   "先学hello再学..."  │  │
│  │  hello  →  hi         related                            │  │
│  │  goodbye →  good night  part_of                         │  │
│  │                                                          │  │
│  │  [ + 添加关系 ]                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**新增关系对话框：**

```
┌── 添加关系 ───────────────────────────────────────────────┐
│                                                              │
│  源卡片   [🔍 搜索卡片...]       当前: hello                  │
│  关系     [prerequisite ▼]       前置知识                     │
│  目标卡片 [🔍 搜索卡片...]       选择目标卡片                 │
│  描述     先掌握 hello 再学习目标词汇                         │
│                                                              │
│  [取消]                          [添加]                     │
└──────────────────────────────────────────────────────────────┘
```

**交互要求：**
- 图谱画布：支持拖拽、缩放、节点自由排列
- 点击节点高亮显示关联边和邻居
- 拖拽节点调整布局
- 双击节点打开对应卡片编辑弹窗
- 边列表支持筛选（按 relation_type）/ 删除
- 数据写回 `card_relations` 表，同时写入 JSON（后续考虑知识图谱文件格式）

> ⚠️ **当前状态：** `card_relations` 表已存在但数据为空。关系图谱功能为 P3 优先级——先完成核心 card/plan CRUD，再实现图谱编辑。
```

---

## 七、可视化编辑 vs 原始 JSON

| 维度 | 结构化编辑（Step 2） | JSON 编辑器（Step 1） |
|:-----|:-------------------|:--------------------|
| 用户体验 | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| 实现周期 | 较长 | 短 |
| 防误操作 | 强（字段级校验） | 弱（全靠后端） |
| 批量操作 | 支持 | 支持 |
| ID 保护 | 天然隐藏 | 需额外 strip |

**结论：直接走 Step 2，不做 JSON 编辑器过渡。**

---

## 八、Git 版本管理

### 7.1 自动提交

每次 admin 保存数据变更后自动执行：

```bash
cd data/curriculum
git add v4/
git commit -m "curriculum: {subject} - {action} ({timestamp})"
```

### 7.2 变更历史显示

前端展示最近 5 条 git log，每条显示时间、科目、操作描述。

### 7.3 回滚

```
POST /api/admin/curriculum/rollback
{ "commit": "abc123def" }
```

流程：`git checkout` 目标 commit → 重新加载所有科目的数据 → 记录回滚日志。

---

## 九、实现优先级

| 优先级 | 内容 | 估算 |
|:-------|:-----|:-----|
| P0 | 去掉启动时 `curriculum_loader::init()` | 0.5h |
| P0 | 后端 `GET /api/admin/curriculum/status` | 1h |
| P0 | 后端 `POST /api/admin/curriculum/load`（带 subject 过滤） | 2h |
| P0 | JSON plan 文件补充 `title`, `author`, `display_name`, `visible` 等字段（所有科目） | 1h |
| P0 | DB `prebuilt_plans` 扩展字段迁移（ALTER TABLE + backfill） | 0.5h |
| P1 | 后端 `GET /api/k12/subjects`（返回 visible plans，含 title/goal/author） | 1h |
| P1 | 后端结构化 CRUD（plan/card 的 GET/PUT/PATCH/DELETE） | 4h |
| P1 | 前端科目列表页（勾选+加载+搜索+状态） | 3h |
| P1 | 前端 K12 科目网格改为动态加载（调用 GET /api/k12/subjects） | 3h |
| P1 | 前端科目详情页（stages/tasks 树形+card domain 分页） | 4h |
| P2 | 前端卡片管理表格页（搜索+过滤+行编辑+批量） | 4h |
| P2 | 前端卡片/任务编辑弹窗 | 3h |
| P2 | Git 自动提交 + 变更历史显示 | 1h |
| P3 | 加载进度弹窗 | 1h |
| P3 | 回滚功能 | 2h |
| P3 | 关系图谱编辑（card_relations 可视化 + 边管理） | 6h |

---

## 十、代码影响范围

以下为设计文档涉及的完整文件变更清单，按必要性分级。

### ✅ 已完成（本轮）

| 文件 | 变更内容 |
|:-----|:---------|
| `backend/schema.sql` | `prebuilt_plans` 加 6 列；`sort`→`sort_order`；`related_prompts`→`dependencies+origin`；`relation_type` 注释更新 |
| `backend/crates/api_server/src/schema.rs` | `prebuilt_plans` CREATE TABLE 加 6 列；`run_migrations_inner` 加 6 条 ALTER TABLE |
| `backend/crates/api_server/src/curriculum_loader.rs` | `PlanFile` 结构体加 6 字段；INSERT 写全列 |

### 🔴 P0 待改（数据不完整）

| # | 文件 | 行号 | 问题 |
|---|:-----|:-----|:------|
| 1 | `curriculum_loader.rs` | 534 | `prebuilt_tasks` INSERT **没写 `dependencies`、`origin`** |
| 2 | `curriculum_loader.rs` | 64 | `TaskData` 结构体 **缺 `task_key`、`prompt_mode`、`card_ids`** |
| 3 | `routes.rs` | 2244 | `prebuilt_tasks` SELECT **没读 `dependencies`、`origin`** |

### 🟡 P1 待改（新功能依赖）

| # | 文件 | 需要 |
|---|:-----|:------|
| 4 | `routes.rs`（新增 handler） | `GET /api/k12/subjects` — 查 `prebuilt_plans WHERE visible=1` |
| 5 | `app/lib/api/chat_client.dart`（新增方法） | `getK12Subjects()` |
| 6 | `app/lib/config/k12_subjects.dart` | 从硬编码改为 API 数据驱动 |
| 7 | `app/lib/screens/k12_subject_screen.dart` | 初始化改为异步加载科目列表 |
| 8 | `app/lib/screens/home_screen.dart` | 科目网格改为异步加载 |
| 9 | `app/lib/providers/plan_provider.dart` | `PlanData` 模型增 `title`/`displayName`/`author` |

### 🟢 P2 待改（测试同步）— TTD 先行

按前后端修改分两组，每组先写测试再改代码。

#### 调试日志规范

全系统日志使用 `tracing` crate，统一格式：

```rust
// 1. handler 入口日志 — 记录关键入参
tracing::info!("handler_name: user_id={}, param1={:?}, param2={}", user_id, param1, param2);

// 2. 关键分支/状态变更 — 记录决策点
tracing::info!("[模块名] 操作描述: detail1={}, detail2={:?}", d1, d2);

// 3. SQL 调试 — 仅在开发/排障时使用（`tracing::debug!` 级别）
tracing::debug!("SQL: {}", sql);

// 4. 异常/降级 — 使用 warn level，不要吞错误
tracing::warn!("[模块名] 操作失败: detail={}, err={}", detail, e);

// 5. 数据完整性校验失败 — 使用 error level
tracing::error!("[模块名] 数据异常: detail={}", detail);
```

**日志级别选择：**

| 级别 | 使用场景 | 示例 |
|:-----|:---------|:-----|
| `info!` | handler 入口/退出、关键状态变更、业务决策 | `review_due_handler: user_id=..., language=...` |
| `debug!` | SQL 语句、中间变量、排障用（默认不输出） | `DEBUG SQL: SELECT ...` |
| `warn!` | 预料内的异常、降级处理、非致命错误 | `parse failed, fallback to default` |
| `error!` | 数据不一致、不应发生的异常 | `card_memory orphan detected: id=...` |

**命名规范：**
- handler 入口用 `handler_name:` 前缀（如 `review_due_handler:`）
- 模块内通用逻辑用 `[模块名]` 前缀（如 `[CP1]`、`[K12]`、`[FSRS]`）
- 日志信息使用中文描述 + 英文变量名
- 敏感信息（用户 ID、token）仅在 info 级别记录，不写入 error 上下文

#### 后端单元测试（5 处）

| # | 文件 | 测试名 | 当前行为 | 改后需验证 |
|---|:-----|:-------|:---------|:-----------|
| 1 | `schema.rs` | `test_core_table_columns` | 验证 prebuilt_plans 含 `id/subject/domain/grade_band/goal` | **追加断言**：`title`、`author`、`display_name`、`visible`、`theme_color`、`theme_icon` 列存在 |
| 2 | `curriculum_loader.rs` | 新增 `test_plan_file_new_fields` | 无此测试 | 用 `PlanFile` 反序列化 JSON，验证 `title`/`author`/`display_name`/`visible` 可读且默认值正确 |
| 3 | `curriculum_loader.rs` | 新增 `test_plan_file_subject_from_filename` | 无此测试 | 验证 `subject` 从文件名推断，JSON 中不存储 |
| 4 | `routes.rs` | 新增 `test_k12_subjects_endpoint` | 无此测试、无此端点 | `GET /api/k12/subjects` 返回 `visible=1` 的 plans，含 `subject/display_name/title/goal/author/theme_color/theme_icon`，字段为空时使用默认值 |
| 5 | `e2e_k12_extra_lifecycle.rs` | `e2e_k12_extra_lifecycle` | 直接 `INSERT INTO plan_runs` 不含 `title` 等 | `INSERT` 不变（`plan_runs` 无新列），但进度 API 响应需验证 `subject` 与 `display_name` 可映射 |

#### 前端单元测试（2 处，非 Rust，标注待写）

| # | 文件 | 测试名 | 当前行为 | 改后需验证 |
|---|:-----|:-------|:---------|:-----------|
| 6 | `app/lib/api/chat_client.dart` | 新增 `test_getK12Subjects` | 无此方法 | 调用 `GET /api/k12/subjects` 返回合法列表 |
| 7 | `app/lib/screens/k12_subject_screen.dart` | 新增 `test_subject_grid_from_api` | 硬编码渲染 | 渲染基于 API 返回的 `display_name`/`title`/`goal`/`author`/`theme_color`，无 API 数据时 fallback 到 `subject` 代码 |

> **TTD 原则**：改代码前先跑这些测试——现有测试必须通过（回归），新增测试初始为 fail，实现代码后变 pass。

### ✅ 无需改动

| 文件 | 原因 |
|:-----|:------|
| `k12_quiz.rs` / `k12_quiz_api.rs` / `k12_quiz_loader.rs` | 只操作 `k12_quiz_bank`/`attempts` 表 |
| `subject_router.rs` | 自由对话模式学科检测，与 prebuilt 无关 |
| `plan_handler.rs` | 操作 `plan_runs` + `user_plan_progress`，不直接操作 prebuilt 表 |
| `main.rs` | 启动时调用 `curriculum_loader::init()`，自动适配 |
| `review_screen.dart` | 只读取 `PlanData` 现有字段 |
| `achievements_screen.dart` | 只消费 API 响应 |
