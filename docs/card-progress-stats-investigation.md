# 学习计划卡片进度统计 — 调查报告

## 一、成就页面数据来源

成就页面加载时调用 4 个 API，其中影响"卡片进度"和"词汇掌握度"的有 3 个：

| API | 后端 Handler | 用途 |
|-----|-------------|------|
| `getProfile()` | `profile_handler` | 统计卡片、成就、CEFR词汇 |
| `getK12Progress()` | `k12_progress_handler` | 每计划的卡片/Task进度 |
| `getLearningReport()` | `learning_report_handler` | 每计划的Task进度（不含卡片） |

---

## 二、三条数据线的详细追踪

### 线1：K12 学习计划进度 → `_buildK12Progress`

**数据来源**：`getK12Progress()` → `_k12Progress`

**渲染字段**：
- `total_tasks`: 来自 `plan_content` JSON 解析（stages 下 tasks 长度求和）
- `done_tasks`: `SELECT COUNT(*) FROM user_plan_progress WHERE plan_id=?1 AND status='done'`
- `total_cards`: `SELECT COUNT(*) FROM cards WHERE plan_id=?1`
- `mastered_cards`: `SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.plan_id=?1 AND cm.state=2 AND cm.reps>=3`

**问题**：✅ 逻辑本身正确。`total_cards` 只统计已 `copy_prebuilt_card` 插入的卡片。但只有第一阶段激活的卡片会被统计（见下方"什么时候插卡"）。

### 线2：统计概览 → `_buildHeader` + `_buildStatsGrid`

**数据来源**：`getProfile()` → `_data['stats']`

**渲染字段**：
- `total_cards`: `SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id=?1 AND cm.status='active'`
- `total_reviews`: `SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id=c.id WHERE c.user_id=?1`
- `today_reviews`: 同上 + `AND r.reviewed_at > (now - 86400)`

**问题**：⚠️ `total_cards` 通过 `JOIN card_memory` + `cm.status='active'` 过滤。如果某些卡片的 `card_memory` 被软删除（`status != 'active'`），则不计入。但正常流程中卡片插入时 `status='active'`，不会被更改。

### 线3：词汇掌握度 → `_buildCefrSection`

**数据来源**：`getProfile()` → `_data['cefr_stats']`

**渲染字段**：
- `max_count`: 来自 `chat_engine::word_bank::get_cefr_catalog_stats()`（课标总词汇量）
- `count`: `SELECT c.front FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id=?1 AND c.card_type='vocabulary' AND cm.state=2 AND cm.status='active'` → 逐词查 `word_bank::lookup_cefr()` 按等级分组

**问题**：⚠️ `max_count` 是课标全量（如英语 A1=1,401 词），但用户的 `count` 只统计 **state=2（Review态）** 的卡片。刚插入的卡片 state=0（New），不计入。所以初始是 "0/1,401"，让人误以为数据错了。

---

## 三、卡片插入机制（什么时候 `copy_prebuilt_card`）

| 触发时机 | 文件位置 | 插入范围 | 说明 |
|----------|---------|---------|------|
| K12 Init | `routes.rs:2186` | **仅第1个stage**的所有task的`card_ids` | 启动会话时调用 |
| 计划创建 | `plan_handler.rs:868` | **仅第1个stage**的所有task的`card_ids` | `force_plan_creation`中 |
| Task推进 | `plan_handler.rs:1367` | 下一in_progress task的`card_ids` | 当前task完成后激活下一task的卡 |

**关键发现**：第2阶段+的卡片，只有当用户推进到该阶段的具体 task 时，才会通过 `plan_handler.rs:1367` 逐 task 插入。`activate_stage_cards`（line 1530）是**空实现**。

---

## 四、可能错了的地方

### 1. `total_cards` 在 init 后远小于预期

| 计划的卡片总数 | 初始 `total_cards` | 原因 |
|--------------|-------------------|------|
| 英语 12,791 | ~237（A1第1个stage） | 只插入了第1阶段的task |
| 语文 2,714 | 取决于第1阶段大小 | 同上 |

→ **这其实是设计如此**，不是bug。卡片是随进度逐步插入的。

### 2. `mastered_cards` 永远是 0

`cm.state=2 AND cm.reps>=3` → 刚插入的卡片 state=0，从未被复习。

→ **正常**，复习后才会有变化。

### 3. `cefr_stats` 的 `count` 显示 0

`lookup_cefr` 基于 `card.front` 逐词查找 CEFR 等级。如果卡片插入但未复习（state=0），不会被计入 `count`。

→ **正常**，这是"掌握度"而非"拥有度"。

### 4. profile 的 `total_cards` 可能包含多个计划的卡片

`WHERE c.user_id=?1 AND cm.status='active'` → 不做 plan 过滤。如果用户同时有英语计划（~237卡）和语文计划（~X卡），统计会两个计划的卡片都计入。

→ 这可能令人困惑，因为显示在"英语计划"卡片进度旁的却是全局统计。

---

## 五、结论

**核心问题不是 SQL 算错了，而是数据理解上的差异**：

| 用户看到 | 实际含义 | 是否合理 |
|---------|---------|---------|
| "卡片总数 200 / 12,791" | 当前已激活阶段（A1）的卡片数 | ✅ 设计如此 |
| "掌握 0 / 200" | 0张卡复习≥3次且进入Review态 | ✅ 新计划正常 |
| "A1 词汇 0/1,401" | 0张卡处于Review态 | ✅ 新计划正常 |

**改进建议**：

1. **`total_cards` 改为全量**：用 `plan_content` JSON 统计所有 stage 的 `card_ids` 总数，而非 DB 中已插入的卡片数
2. **`cefr_stats` 补充 total/have/mastered**：三个指标而非两个
