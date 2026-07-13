---
title: "A Stochastic Shortest Path Algorithm for Optimizing Spaced Repetition Scheduling"
authors: ["Ye, J.", "Su, J.", "Cao, Y."]
year: 2022
journal: "ACM SIGKDD Conference on Knowledge Discovery and Data Mining"
tags: ["间隔重复", "FSRS", "记忆算法", "优化"]
key_findings: "提出 FSRS（Free Spaced Repetition Scheduler）算法，通过随机最短路径模型优化间隔重复调度，比传统 SM-2 算法预测精度提升 30%+"
methodology: "大规模用户复习历史数据训练 + 基准测试对比"
sample_size: "10000+ 用户复习记录"
relevance:
  - module: "fsrs_scheduler"
    impact: "核心算法依据。FSRS 是 CoEvo 复习系统的算法基础"
    priority: "P0"
  - module: "card_memory"
    impact: "FSRS 状态机（stability/difficulty/retrievability）是记忆模型核心"
    priority: "P0"
  - module: "review_queue"
    impact: "排序策略直接引用 FSRS 的 due 计算逻辑"
    priority: "P0"
---

## 摘要

本文提出 FSRS（Free Spaced Repetition Scheduler）算法，将间隔重复调度问题建模为随机最短路径问题（Stochastic Shortest Path）。与传统 SM-2 算法使用固定间隔公式不同，FSRS 通过学习用户历史复习数据中的记忆动态模式，为每张卡片动态预测最佳复习时间。

## 关键发现

1. **三参数记忆模型**：Stability（稳定性）、Difficulty（难度）、Retrievability（可提取性），比 SM-2 的单参数模型更具表现力
2. **预测精度提升**：在 10000+ 用户的实际数据上，FSRS 对回忆概率的预测误差比 SM-2 降低 30%+
3. **冷启动优化**：仅需 10-20 次复习即可稳定参数，降低新用户使用门槛
4. **跨平台验证**：在 Anki、RemNote、墨墨背单词等多个平台验证有效

## 对 CoEvo 的影响

### 已验证的设计
- fsrs5.rs 实现了 FSRS 三参数状态机，16/16 测试通过
- user_cards 表存储 stability/difficulty 参数
- 复习调度按 FSRS 算法计算 due 时间

### 设计差距
- 当前使用开源 FSRS 参数默认值，未针对 CoEvo 用户群体调优
- 缺少参数自动优化器（类似 Anki 的 FSRS optimizer）
- 冷启动阶段（前 10 次复习）的用户体验可进一步优化

## 后续研究
- Su, J., Ye, J. et al. (2023). "Optimizing Spaced Repetition Schedule by Capturing the Dynamics of Memory." IEEE TKDE. — FSRS 算法扩展，增加记忆动态捕捉
