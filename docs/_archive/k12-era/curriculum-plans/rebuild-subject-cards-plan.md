# 非语言科目卡片重建计划

## 问题

旧管线的卡片分配逻辑导致跨 task 的概念污染：每个科目只有少量卡片（~200-250），却被复用到所有 task 里，三角函数卡片跑到了平面几何 task 中。

## 目标

每 task 的 card_ids 只包含语义相关的概念卡片，不跨 topic 泄露。

## 方法

**不重新生成卡片**（现有卡片的 front/back 是对的），而是用 LLM **为每科重分配 card_ids**：

```
对每个 subject：
  1. 读取该科目的 plan（所有 task）
  2. 读取该科目的 card 文件（所有卡片）
  3. 逐 task 用 LLM 判断哪些卡片与该 task 相关
  4. 更新 plan 的 card_ids
  5. 验证
```

## 执行顺序（从简到繁）

| 优先级 | 科目 | 总 card_ids | 卡片数 | 预估 LLM 调用 | 预估时间 |
|--------|------|------------|--------|--------------|---------|
| P0 | math | 1,958 | 249 | 80 次（每 task） | 5 min |
| P1 | physics | 1,428 | 260 | 103 次 | 7 min |
| P1 | chemistry | 576 | 184 | 40 次 | 3 min |
| P1 | biology | 932 | 225 | 55 次 | 4 min |
| P2 | geography | 806 | 183 | 38 次 | 3 min |
| P2 | history | 1,653 | 146 | 48 次 | 3 min |
| P2 | it | 542 | 125 | 26 次 | 2 min |
| P3 | politics | 270 | 48 | 24 次 | 2 min |
| P3 | science | 219 | 75 | 25 次 | 2 min |
| P3 | pe | 381 | 92 | 21 次 | 2 min |

## 脚本设计

单脚本 `scripts/rebuild_subject_cards/assign_cards_by_task.py`，参数：`--subject math`

逻辑：
1. 读 `plans/{subject}.json` → 所有 task
2. 读 `cards/{subject}.json` → 所有卡片
3. 每 task 构造 prompt（task 名 + 现有 card_ids 的 front 列表）
4. LLM 输出：保留/移除哪些 card_ids
5. 更新 plan，写回文件
6. 每科目完成后对比：总 card_ids 变化、覆盖度

## 验证

每科目完成后：
- ✅ 每 task 的 card_ids 不为空
- ✅ 所有 card_ids 在 card 文件中存在
- ✅ 可疑卡片（front 含跨 topic 关键词）不超过 5%
- ✅ 对比前后 card_ids 去重总数（应有增加 = 更多 task 专属卡片）
