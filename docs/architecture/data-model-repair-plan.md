# 数据结构修复计划

> 2026-06-02 | v3 — 最终定稿，一次性全量修复

---

## 一、核心问题

**根因 1：`cards` 表缺少 `plan_type` + `plan_id`**
- 卡片无法关联到所属计划，前端复习页无法按计划筛选
- CP1 卡片缺 `conversation_id`，完全断连
- K12 预生成卡片缺 `status` 列写入

**根因 2：`learning_plans` 冗余表污染全链路**
- 15 处引用散布在 routes.rs、plan_handler.rs、admin_handlers.rs
- K12 重复检测、计划 CRUD、管理统计都依赖它
- `conversations` 表本身已有 `subject` + `grade_band`，完全能替代

**根因 3：测试 SCHEMA_SQL 与生产 DDL 不同步**
- 缺 `status` 列 → CP1 INSERT 静默失败
- 缺 HECK、NOT NULL、ON DELETE CASCADE

---

## 二、修复方案（三阶段并进）

### Phase A: `cards` 加列 + 关联修复

```sql
ALTER TABLE cards ADD COLUMN plan_type TEXT;   -- 'plan_templates' | 'conversation_plans'
ALTER TABLE cards ADD COLUMN plan_id TEXT;     -- plan_templates.id / conversation_plans.id
```

**5 处 INSERT 统一写入**:

| # | 位置 | 卡片来源 | plan_type | plan_id | conversation_id | 其他修复 |
|---|------|---------|-----------|---------|-----------------|---------|
| 1 | `routes.rs:1963` | K12 预生成 | `'plan_templates'` | `subject + '_plan'` | ✅ 已有 | 补 `status='active'` |
| 2 | `routes.rs:2163` | K12 reading 课文 | `'plan_templates'` | `subject + '_plan'` | ✅ 已有 | 补 `status`，停写 `plan_task_id` |
| 3 | `routes.rs:2184` | K12 reading 词汇 | `'plan_templates'` | `subject + '_plan'` | ✅ 已有 | 补 `status`，停写 `/plan_task_id` |
| 4 | `ws.rs:528` | CP1 概念提取 | `'conversation_plans'` | `SELECT id FROM conversation_plans WHERE conversation_id=?` | **补 conv_id** | — |
| 5 | 测试 Phase 2b | CP1 batch | 同 ws.rs | 同 ws.rs | **补 conv_id** | — |

### Phase B: 废弃 `learning_plans`

`learning_plans` 的所有功能都能被 `conversations` + `plan_templates` + `conversation_plans` 替代。

**B1: K12 init 重复检测** (routes.rs:1851)

```sql
-- 改前:
SELECT c.id FROM conversations c
INNER JOIN learning_plans lp ON lp.conversation_id = c.id
WHERE c.user_id=?1 AND c.subject=?2 AND c.grade_band=?3

-- 改后:
SELECT id FROM conversations
WHERE user_id=?1 AND subject=?2 AND grade_band=?3 AND deleted_at IS NULL
```

删除 `learning_plans` 的 INSERT (routes.rs:1889-1921) 和 DELETE (routes.rs:1915)。

**B2: K12 reading init 同理** (routes.rs:2013, 2110, 2114)

**B3: `build_plan_context` 回退路径** (plan_handler.rs:1088)

删掉 `learning_plans` 的 legacy 回退查询，新路径无数据时返回空。

**B4: plan CRUD HTTP API** (routes.rs:1382-1448)

直接删除——开发阶段无人用此接口。

**B5: 对话级联操作** (routes.rs:1012-1065)

删除 `learning_plans` 的级联 UPDATE/DELETE，仅操作 `conversations`。

**B6: admin_handlers 统计** (:594-706)

从 `learning_plans` 改为 `conversation_plans` 查询。

### Phase C: 测试 SCHEMA_SQL 同步

- 测试 `cards` 加 `plan_type TEXT, plan_id TEXT, status TEXT NOT NULL CHECK(...)`
- 测试同步 `conversation_plans`、`plan_templates`、`user_plan_progress` 三张新表
- 去掉旧 CP1 INSERT 中的 `status` 列写入（表已有此列）

---

## 三、改后数据模型

```
conversations (id, user_id, subject, grade_band, deleted_at)
    │ conversation_id
    ├─────────────────────┬──────────────────┐
    │                     │                  │
learning_plans         conversation_plans   plan_templates
(废弃，不再写)             (CP2 自由对话)       (K12 共享模板)
                          │ plan_id           │ plan_id='{subject}_plan'
                          └────────┬──────────┘
                                   │
                            user_plan_progress
                            (plan_type, plan_id, task_key, status)
                                   │
                              cards (plan_type, plan_id, conversation_id,
                                     subject, status, origin)
                                   │ card_id
                              card_memory (FSRS)
                                   │
                              review_log
```

---

## 四、实施顺序

```
       Phase A (cards加列+INSERT改)
       Phase B (learning_plans废弃)     ← 并行推进
       Phase C (测试同步)
            ↓
       编译验证
            ↓
       cargo test e2e_main_lifecycle
            ↓
       检查报告 → 完成
```
