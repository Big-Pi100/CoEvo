# 数据列写入来源调查报告

> 2026-06-02 | 覆盖 cards, card_memory, conversation_plans, user_plan_progress, plan_templates

---

## 一、cards 表 — 业务写入来源（5 处）

| # | 文件:行 | 函数 | 写入类型 | 写入列 | 缺哪些列 |
|---|---------|------|---------|--------|---------|
| 1 | `routes.rs:1963` | `k12_init_handler` | INSERT OR IGNORE | id, user_id, domain, card_type, front, back, source_sentence, **conversation_id**, created_at, subject, grade_band, k12_card_id, origin='prebuilt' | **status**, **plan_task_id** |
| 2 | `routes.rs:2163` | `k12_reading_init_handler` | INSERT OR IGNORE | id, user_id, domain, card_type='reading', front, back, conversation_id, created_at, subject, grade_band, k12_card_id, origin='prebuilt' | **source_sentence**, **status**, **plan_task_id** |
| 3 | `routes.rs:2184` | `k12_reading_init_handler` | INSERT OR IGNORE | id, user_id, domain, card_type='vocabulary', front, back, conversation_id, created_at, subject, grade_band, k12_card_id, origin='prebuilt', **plan_task_id=''** | **source_sentence**, **status** |
| 4 | `ws.rs:528` | `handle_ws` (ColdPath) | INSERT OR IGNORE | id, user_id, domain, card_type='concept', front, back, source_sentence, created_at, **status='pending'** | **conversation_id**, **subject**, **grade_band**, **plan_task_id** |
| 5 | `main.rs:638` | `main` (Phase 4) | INSERT INTO SELECT | 全列拷贝（迁移重建） | — |

### 问题

- **CP1 卡片（ws.rs:528）没有 `conversation_id`** — 卡片无法定位到任何会话
- **k12_init（#1, #2, #3）没有 `status`** — ws.rs 有 `status='pending'` 但不一致
- **`plan_task_id` 列仅 reading 词汇表（#3）写入空字符串 ''** — 其他写入不涉及此列
- **所有写入都不含 `plan_type` 或 `plan_id`** — 目前不存在这两列

---

## 二、card_memory 表 — 写入来源（7 处）

| # | 文件:行 | 函数 | difficulty | stability | due |
|---|---------|------|-----------|----------|-----|
| 1 | `ws.rs:534` | `handle_ws` (ColdPath) | **0.3** | **1.0** | `now` |
| 2 | `routes.rs:1971` | `k12_init_handler` | **0.3** | **1.0** | `now_ts` |
| 3 | `routes.rs:2169` | `k12_reading_init_handler` (reading) | **5.0** | **0.0** | `now_ts` |
| 4 | `routes.rs:2190` | `k12_reading_init_handler` (vocab) | **5.0** | **0.0** | `now_ts` |
| 5 | `plan_handler.rs:1930` | `unlock_next_cards` (管道A) | **0.3** | **1.0** | `now_ts` |
| 6 | `plan_handler.rs:1956` | `unlock_next_cards` (管道B) | **0.3** | **1.0** | `now_ts` |
| 7 | `plan_handler.rs:1986` | `unlock_next_cards` (管道C) | **0.3** | **1.0** | `now_ts` |

> ⚠️ **不一致**: reading 模式使用 `difficulty=5.0, stability=0.0`，其余地方用 `0.3, 1.0`

---

## 三、conversation_plans — 写入来源（2 处）

| # | 文件:行 | 函数 | 说明 |
|---|---------|------|------|
| 1 | `plan_handler.rs:371` | `upsert_learning_plan` | **业务写入**：CP2 创建计划时触发。填写 id, user_id, conversation_id, goal, domain, plan_content, created_at, updated_at |
| 2 | `main.rs:853` | `main` (V2.1 Phase 3) | **迁移**：从 `learning_plans` 复制数据 |

---

## 四、user_plan_progress — 写入来源（3 处）

| # | 文件:行 | 函数 | 操作 | 说明 |
|---|---------|------|------|------|
| 1 | `plan_handler.rs:123` | `handle_plan_update` | `UPDATE ... SET status=?` | **业务写入**：CP2 每轮检测到通关信号后更新对应 task_key 的状态 |
| 2 | `plan_handler.rs:417` | `upsert_learning_plan` | `INSERT OR REPLACE` | **业务写入**：CP2 展开 plan_content 中的 tasks，每 task 一条记录 |
| 3 | `main.rs:891` | `main` (V2.1 Phase 3) | `INSERT OR IGNORE` | **迁移**：从 `learning_plans.task_status` JSON 迁移 |

### `plan_type` 值不一致

| 位置 | plan_type |
|------|----------|
| `plan_handler.rs:419`（CP2 创建） | `"conversation"` |
| `plan_handler.rs:419`（K12 创建） | `"k12"` |
| `main.rs:894`（迁移） | `"k12"` 或 `"conversation"` |
| `main.rs:156`（DDL CHECK） | 无 CHECK 约束 |

⚠️ **DDL 无 CHECK**：`user_plan_progress.plan_type TEXT NOT NULL` 没有 CHECK 约束。代码写 `"conversation"`，但审计建议统一为 `"cp2"`。

---

## 五、plan_templates — 写入来源（1 处）

| # | 文件:行 | 函数 | 说明 |
|---|---------|------|------|
| 1 | `main.rs:864` | `main` (V2.1 Phase 3) | **迁移**：从 K12 `learning_plans` 复制，subject_key 用中文→英文映射转换 |

仅迁移写入，运行时无 INSERT。

---

## 六、总结：缺失列分布

```
                    K12预生成   K12阅读   K12词汇   CP1提取
                    (1963)     (2163)   (2184)   (ws:528)
conversation_id      ✅         ✅       ✅       ❌
subject              ✅         ✅       ✅       ❌
grade_band           ✅         ✅       ✅       ❌
source_sentence      ✅         ❌       ❌       ✅
status               ❌         ❌       ❌       ✅ ('pending')
plan_task_id         ❌         ❌       ⚠️ ('')   ❌
origin='prebuilt'    ✅         ✅       ✅       ❌ (origin 走 DEFAULT)
```

**最大断裂**: **CP1 卡片（ws.rs）缺 conversation_id** → 所有 CP1 卡片无法定位到会话/计划。

**最大冗余**: **reading 词汇表**（#3）写入弃用的 `plan_task_id=''`——代码残留。
