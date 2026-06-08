# 跨代码影响分析报告

> 分析时间: 2026-06-01 20:10
> 工具: GitNexus 知识图谱 (HEAD 对齐, 9103 nodes, 16805 edges)

---

## 一、卡片状态重构的变动范围

### 1.1 新增/修改 API

| 当前路由 | 当前 Handler | 改后 |
|---------|-------------|------|
| `POST /api/cards/skip` | `cards_skip_handler` (行666) | **删除** |
| `GET /api/cards/skipped` | `cards_skipped_handler` (行691) | **删除** |
| `DELETE /api/cards/skipped/{id}` | `cards_skip_delete_handler` (行722) | **删除** |
| `POST /api/cards/batch-create` | `cards_batch_create_handler` (行810) | 改为 `PATCH /api/cards/status` — 批量更新 status |
| `GET /api/cards/all` | `cards_all_handler` (行903) | **加 `WHERE status='active'`** |
| `POST /api/review/due` | `review_due_handler` (fsrs_scheduler.rs:36) | **加 `WHERE status='active'`** |

### 1.2 `cards` 表查询分布（需加 `WHERE status='active'` 或 `status IS NOT 'pending'` 的 23 处）

所有涉及 `FROM cards` 的查询需要评估。按是否需要加 status 过滤分类：

**必须加 `status NOT IN ('pending', 'skipped')` 的（面向用户）：**

| 位置 | 查询 | 用途 |
|------|------|------|
| `routes.rs:914-926` | `cards_all_handler` 主查询 | 卡片列表页 |
| `routes.rs:1005` | `SELECT DISTINCT domain FROM cards` | 筛选面板 |
| `routes.rs:1012` | `SELECT DISTINCT subject FROM cards` | 筛选面板 |
| `routes.rs:858` | `SELECT COUNT(*) FROM cards` | 成就计数 |
| `routes.rs:870` | `SELECT COUNT(DISTINCT domain)` | 成就 domain 覆盖 |
| `routes.rs:1284` | `SELECT COUNT(*) FROM cards` | profile 卡片总数 |
| `routes.rs:1296` | `SELECT COUNT(DISTINCT domain)` | profile domain 覆盖 |
| `routes.rs:1710` | `SELECT COUNT(*) FROM cards` | 学习报告 |
| `routes.rs:1714` | `SELECT COUNT(*) FROM review_log WHERE card_id IN (SELECT id FROM cards ...)` | 学习报告 |
| `routes.rs:1817` | `FROM cards WHERE created_at >= ?1` | 学习报告 |
| `routes.rs:1858` | `SELECT COUNT(*) FROM cards WHERE created_at >= ?1` | 学习报告 |
| `ws.rs:424` | `SELECT COUNT(*) FROM cards` | WebSocket 状态 |
| `ws.rs:478` | `SELECT LOWER(front) FROM cards` | 去重检查（应全量） |
| `fsrs_scheduler.rs:36` | `FROM cards c JOIN card_memory cm` | 复习到期查询 |
| `fsrs_scheduler.rs:60` | `SELECT COUNT(*) FROM cards c` | 复习状态 |
| `fsrs_scheduler.rs:163` | `SELECT COUNT(*) FROM cards` | 复习统计 |
| `fsrs_scheduler.rs:167` | `SELECT COUNT(DISTINCT domain) FROM cards` | 复习统计 |
| `admin_handlers.rs:151,195,590,1052` | `SELECT COUNT(*) FROM cards` | 管理后台 |

**无需加 status 过滤的（全量统计）：**

| 位置 | 原因 |
|------|------|
| `routes.rs:254` | `SELECT LOWER(front)` 用于去重建议，应包含 skipped |
| `card_repository.rs:57-70` | `insert_card` 内部去重扫描，应包含所有 status |

**涉及 K12 预生成卡片的（`origin='prebuilt'` → `status='active'` 迁移）：**

| 位置 | 影响 |
|------|------|
| `routes.rs:2149-2174` | k12_init 写入 cards |
| `routes.rs:2362-2397` | reading_init 写入卡片 |
| `plan_handler.rs:1947-2014` | CP2 task 同步导入卡片 |

### 1.3 前端影响链路

```
chat_concept_dialog.dart                          card_list_screen.dart           review_screen.dart
  │                                                     │                             │
  ├─ batchCreateCards() ← 需改为 updateStatus()           ├─ skipConcept() ← 改为 updateStatus()
  └─ skipConcept() ← 改为 updateStatus()                  └─ _doSkipCard() ← 链式调用
                                                          └─ _buildBody() ← 内联调用
skipped_list_screen.dart
  └─ getSkippedConcepts() ← **删除整个文件**
```

### 1.4 测试影响

| 测试文件 | 影响 |
|---------|------|
| `card_repository.rs` 测试 | `test_skip_concept_writes` → 删除；`test_insert_new_card` → 要加 status 默认值断言；新增 `test_update_card_status` |
| `e2e_card_pipeline.rs` | 跳过概念相关断言改为 status='skipped' 检查 |
| `e2e_main_lifecycle.rs:130,158` | `CREATE TABLE IF NOT EXISTS skipped_concepts` → 删除 |
| `e2e_learning_plan_lifecycle.rs:125` | 同上 |
| `e2e_live_llm_plan_lifecycle.rs` | 多处硬编码中文 subject + 跳过相关断言 |

---

## 二、科目标识统一的影响范围

（之前已详细分析，此处略，仅列出 GitNexus 验证结果）

| 符号 | GitNexus 验证 | 影响 |
|------|-------------|------|
| `CHINESE_TO_ENGLISH` const | const 不在图追踪范围 | 3 处手动确认：curriculum_loader, reading_loader, plan_handler |
| `Domain::from_chinese` | ✅ routes.rs → pipeline_router | 2 个 handler 调用 |
| `subject_to_domain` | ✅ subject_router.rs 内 | 仅 route() 调用 |
| `K12InitInput` struct | ✅ routes.rs:2012 | 前端传递 subject 值 |
| `get_plan()` | ✅ curriculum_loader.rs | 2 个 handler + plan_handler |
| `get_cards()` | ✅ curriculum_loader.rs | 2 个 handler + plan_handler |
| `insert_card` | card_repository.rs:45 | 1 个 handler + 2 个测试（插入时 domain 来自 candidate，无需额外改动） |

---

## 三、分级风险总结

| 风险级 | 项数 | 说明 |
|-------|------|------|
| **CRITICAL** | 0 | 无不可逆数据丢失风险 |
| **HIGH** | 2 | ① `cards.domain` 迁移前必须先做（否则 plan_handler get_cards 查不到）② `insert_card` 的去重扫描包含所有 status（设计就是全量，无需改，但不能误加过滤） |
| **MEDIUM** | 3 | ① 23 处 `FROM cards` 查询需逐处评估是否加 status 过滤 ② `origin 'prebuilt' → status 'active'` 迁移不能丢标签 ③ admin 面板统计是否需要包含 skipped |
| **LOW** | 5 | 前端 5 处调用点适配新 API |
