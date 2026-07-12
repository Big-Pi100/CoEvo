# 论文设计审查 — 产品迭代方案

> 综合 13 篇已发表博客的首轮研读结果，汇总为统一的产品改进路线图。
> 每日自动化管线（08:00）持续新增审查笔记到 `paper-reviews/` 目录。

---

## 当前迭代优先级汇总

### 🔴 P0 — 核心缺陷（修复 QR 码就已造成业务损失的级别）

| 改进 | 来源论文 | 影响模块 |
|:-----|:---------|:---------|
| [P0] 无效 campaign_id 入库修复 | —（巡检发现）| ✅ 已修复：`trial_handler.rs` + `auth.rs` |

### 🔴 P1 — 显著影响用户体验和学习效果

| # | 改进 | 来源 | 影响模块 | 简述 |
|:-:|:-----|:-----|:---------|:------|
| 1 | **答错追问"为什么错"** | 刻意练习 / 测试效应 | `review_screen.dart` → `ws.rs` | 答错后不直接给答案，让用户再试一次 + LLM解释差异 |
| 2 | **复习队列交错排序** | 交替练习 | `fsrs_scheduler.rs` | 排序约束：每5张卡片至少来自2个不同domain，防集中练习 |
| 3 | **mini_quiz 出题质量校验** | 自动出题研究 | `prompts/quiz/` → `ws.rs` | 生成后第二遍LLM校验答案正确性，错题自动重出 |
| 4 | **quiz 难度匹配 FSRS 状态** | 自动出题研究 | `prompts/quiz/` → `fsrs_scheduler.rs` | 新学卡片出基础题，高稳定性卡片出应用题 |
| 5 | **心流/焦虑/无聊状态检测** | 心流理论 | `fsrs_scheduler.rs` + `ws.rs` | 连续快正确 → 加难度；连续错 → 减难度/回溯 |
| 6 | **动机激励产品化补足** | LLM 家教效能 | `achievement_engine.rs` + styles | AI情感弱，用成就系统/streak/社交排名补 |
| 7 | **不答答案只引导思考** | LLM 家教效能 | `prompts/chat/*/structured.md` | 用户问"答案多少"→反问"你先说说思路" |
| 8 | **mini_quiz 随机抽考题库** | 元认知偏差 | `plan_handler.rs` (CP2) | 同知识点每次出不同题，防记忆题目顺序 |
| 9 | **prompt 加"用自己的话复述"环节** | 详细阐述编码 | `prompts/chat/*/structured.md` | teach阶段增加用户自己解释环节 |

### 🟡 P2 — 提升用户感知和粘性

| # | 改进 | 来源 | 影响模块 |
|:-:|:-----|:-----|:---------|
| 10 | 成就系统增加"过程性成就" | 成长型思维 | `achievement_engine.rs` |
| 11 | 自我评估 vs 实际表现对比 | 元认知偏差 | `review_screen.dart` |
| 12 | FSRS 效率对比展示 | FSRS vs 艾宾浩斯 | `review_screen.dart` |
| 13 | 跨概念联系引导 | 详细阐述编码 | `prompts/chat/*/structured.md` |
| 14 | "睡前快速复习"模式 | 睡眠记忆 | `review_screen.dart` |
| 15 | 用户自定学习目标 | 自我调节学习 | `plan_handler.rs` |
| 16 | "AI依赖度"检测 | AI教育影响 | `ws.rs` (B2 hot path) |
| 17 | 学习趋势可视化 | AI代写 / 自我决定 | `profile_screen.dart` |
| 18 | 概念关联图谱 | 详细阐述编码 | `concept_engine.rs` |
| 19 | 社交学习元素 | 自我决定理论 | `distribution_handler.rs` |
| 20 | B2 追问推理过程 | AI代写 | `ws.rs` (B2 hot path) |

---

## 论文来源索引

| 论文/研究 | 博客文章 | 审查笔记 |
|:----------|:---------|:---------|
| CEPR DP21577 (AI教育影响) | `article-01-ai-education-impact` | `2026-07-11-ai-education-impact.md` |
| Agarwal 测试效应 | `article-03-testing-effect` | `2026-07-11-testing-effect.md` |
| FSRS vs 艾宾浩斯 | `article-02-fsrs-vs-ebbinghaus` | `2026-07-11-fsrs-vs-ebbinghaus.md` |
| Ericsson 刻意练习 | `deliberate-practice` | `2026-07-11-deliberate-practice.md` |
| Craik & Lockhart 深度加工 | `elaborative-encoding` | `2026-07-11-elaborative-encoding.md` |
| Bjork 交错练习 | `interleaved-practice` | `2026-07-11-interleaved-practice.md` |
| Csikszentmihalyi 心流 | `flow-theory-learning` | `2026-07-11-flow-theory-learning.md` |
| LLM Tutor 效能研究 | `llm-tutor-effectiveness` | `2026-07-11-llm-tutor-effectiveness.md` |
| Koriat 元认知偏差 | `metacognitive-bias` | `2026-07-11-metacognitive-bias.md` |
| Karpicke 检索练习 | `retrieval-vs-rereading` | `2026-07-11-retrieval-practice.md` |
| Deci & Ryan 自我决定 | `self-determination-theory` | `2026-07-11-self-determination-theory.md` |
| Walker 睡眠记忆 | `sleep-memory-learning` | `2026-07-11-sleep-memory-learning.md` |
| Dweck 成长型思维 | `article-04-growth-mindset` | `2026-07-11-growth-mindset.md` |
| AI出题系统研究 | `auto-quiz-effectiveness` | `2026-07-11-auto-quiz-effectiveness.md` |
| AI代写研究 | `ai-homework-cheating` | `2026-07-11-ai-homework-cheating.md` |
| SRL RCT (EPR 2026) | `2026-07-12-ai-self-regulated-learning` | `2026-07-12-self-regulated-learning.md` |
