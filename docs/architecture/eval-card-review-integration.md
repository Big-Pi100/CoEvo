# 教学质量评估 — 卡片-复习流集成方案

## 问题诊断

当前 Test 11 只覆盖了对话教学流的前半段。卡片-复习流存在两个缺口：

### 缺口 1: 词卡从未被导入

`unlock_next_cards()`（`plan_handler.rs:1211-1288`）只处理 `gold_cr_ids` 类型的卡片，但语文阅读计划中有 **680 个任务**通过 `vocab_card_ids` 引用 **6,779 张词卡**。这些词卡在 task 推进时从未被导入 `cards` 表。

数据流：
```
task 完成 → unlock_next_cards()
  ├── gold_cr_ids → curriculum_loader → INSERT cards ✅
  ├── reading_card_id → ??? → ??? ❌（不在此路径处理）
  └── vocab_card_ids → ??? → ??? ❌（从未被处理）
```

### 缺口 2: 三管道的复习机制完全不同

| 管道 | 卡片来源 | 创建时机 | 复习格式 | 验证方式 |
|------|---------|---------|---------|---------|
| **概念卡** | ColdPath 1 | 对话中提取 | 正面→背面 recall | LLM verify |
| **词卡** | 预置 JSON | task 完成时导入 | 默写/组词/造句/听写 | 字形匹配 + LLM 造句判断 |
| **课文卡** | 预置 JSON | 初始化时导入（reading_loader） | 主旨/手法/赏析 | LLM 问答 |

### 缺口 3: 对话中谈及"卡片"不会触发词卡创建

ColdPath 1 的概念提取器只从对话内容中提取概念，不会查询预置词表。即使用户说"这个字怎么写"，也不会关联到 `vocab_card_ids` 中的预置词卡。词卡只在 task 推进时通过 `unlock_next_cards` 触发——但这个函数根本就没处理 `vocab_card_ids`。

---

## 集成方案

### Test 11 三阶段架构

每个 eval session 的日志目录从单阶段扩展为三阶段：

```
data/eval_runs/{run_id}_{subject}_{grade}/
├── meta.json                    # 管线元信息
├── turn_001~N/                  # Phase 1: 对话教学（已有）
├── cards_summary.json           # Phase 2: 卡片验证（新增）
├── cards_imported.json          # Phase 2: 被导入的卡片详情（新增）
├── review_session.json          # Phase 3: 复习验证（新增）
├── review_verification.json     # Phase 3: verify 结果（新增）
└── aggregate.json               # 全局指标
```

### Phase 1: 对话教学（现状）

不变。师生对话 → CP2 推进 → task 完成。

### Phase 2: 卡片解锁验证（新增）

对话结束后，查询 `cards` 表并按管道分别验证：

```
Phase 2 验证矩阵:
  ├── 总卡片数: COUNT(*) FROM cards WHERE user_id = ?
  ├── 概念卡: COUNT(*) FROM cards WHERE card_type = 'concept'
  ├── 词卡:   COUNT(*) FROM cards WHERE card_type = 'vocab'
  └── 课文卡: COUNT(*) FROM cards WHERE card_type = 'reading'
```

对于阅读模式 session，额外验证：
- 已完成 task 对应的 `vocab_card_ids` 是否在 `cards` 表中？
- `reading_card_id` 是否被正确导入？
- `card_memory` 表是否有对应的 FSRS 状态行？

### Phase 3: 基本复习流验证（新增）

从 `cards` 表取一张卡片，模拟复习流程：

```
Phase 3 复习步骤:
  1. get_due_cards() → 拿一张到期卡片
  2. verify() → LLM 生成验证问题（3 道）
  3. 模拟学生回答 + judge() → LLM 判断正确性
  4. submit_review(rating) → FSRS state transition
  5. 验证 card_memory 状态迁移:
     - state: 0(New) → 1(Learning) / 2(Review)
     - reps +1
     - due > last_review
```

---

## 需要修复的问题

### Fix 1: unlock_next_cards 增加词卡导入

`plan_handler.rs:1211-1288` 的 `unlock_next_cards` 函数目前只处理 `gold_cr_ids`。

需要增加 `vocab_card_ids` 处理分支：

```
task 完成 → 下一 task 的 vocab_card_ids
  → 从 vocab_enriched JSON 查找 card_id
  → INSERT INTO cards (带 card_type='vocab', subject, grade_band)
  → INSERT INTO card_memory (FSRS initial state)
```

### Fix 2: reading_loader 初始化时导入课文卡

当前 `reading_loader::init()` 加载卡片到内存（775 张），但不导入 `cards` 表。需要在 reading plan 初始化时或 task 首次激活时，将 `reading_card_id` 对应的卡片导入 `cards` 表。

### Fix 3: 对话中触发词卡查询（远期）

当对话涉及具体生字/词时，ColdPath 1 或新增的 ColdPath 3 应查询 `vocab_enriched` 索引，将相关词卡加入候选列表。这步不在此次改动范围。

---

## 实施顺序

| 步骤 | 内容 | 优先级 |
|------|------|--------|
| 1 | Fix 1: unlock_next_cards 增加 `vocab_card_ids` 导入 | P0 |
| 2 | Test 11 Phase 2: 卡片验证日志追加 | P0 |
| 3 | Fix 2: reading_loader 导入课文卡到 `cards` 表 | P1 |
| 4 | Test 11 Phase 3: 复习流验证 | P1 | ✅ **已完成** — 完整 5 步骤：get_due → submit_review → FSRS 状态迁移 (0→1) → reps+1 → due 推进 → review_log 写入 |
| 5 | Phase 3 日志写入 quality_review.py 评审维度 | P2 | ✅ **已完成** — `card_analysis()` 新增卡片导入完整性/复习就绪度/多样性指标 |
| 6 | Fix 3: 对话中词卡查询（远期） | P3 | ⏳ 待规划 |
