---
title: "LECTOR: LLM-Enhanced Concept-based Test-Oriented Repetition for Adaptive Spaced Learning"
authors: ["Zhao J."]
year: 2025
journal: "arXiv"
tags: ["spaced repetition", "LLM", "semantic analysis", "adaptive learning", "FSRS", "vocabulary"]
relevance:
  - module: "FSRS调度"
    impact: "LLM语义分析+个性化间隔的融合方向，与CoEvo FSRS-5实现互补，提示未来进化方向"
    priority: "P1"
  - module: "概念提取(CP1)"
    impact: "语义相似性评估与大模型分析方法可借鉴到概念激活的抗干扰策略"
    priority: "P2"
  - module: "语言学习(词库)"
    impact: "LECTOR专为语言考试场景设计，语义混淆问题是CoEvo词库的潜在优化空间"
    priority: "P2"
key_findings: |
  1. LECTOR将LLM语义分析与间隔重复结合，处理语义相近概念的混淆问题
  2. 与6种基线算法（SSP-MMC、SM2、HLR、FSRS、ANKI、THRESHOLD）对比
  3. 在100个模拟学习者×100天的测试中，LECTOR成功率90.2%，最好基线SSP-MMC为88.4%
  4. 语义感知调度显著减少因语义混淆导致的错误
  5. 动态个性化学习画像与多维度优化（难度、掌握度、复习历史、语义关系）
methodology: "算法设计与模拟实验：100模拟学习者×100天，对比6种基线算法"
sample_size: "100个模拟学习者"
---
## 摘要

LECTOR（LLM-Enhanced Concept-based Test-Oriented Repetition）是一种新型自适应间隔调度算法，专门面向以考试为导向的学习场景设计。该算法利用大语言模型进行语义分析，同时整合个性化学习画像，解决了现有间隔重复算法（包括FSRS）忽略语义关系的核心问题。实验表明，LECTOR在成功率上超越包括FSRS在内的所有基线算法。

## 关键发现

1. 现有算法（包括FSRS）将每个学习项视为独立个体，忽略语义关系
2. 语义混淆是语言考试场景中最大的记忆障碍
3. LECTOR的语义感知调度减少混淆错误，同时保持计算效率
4. 语言类学习（如TOEFL/IELTS/GRE词汇）中语义关系建模尤为关键

## 对 CoEvo 的影响

### 已验证的设计
- CoEvo采用FSRS-5是实现高效间隔复习的正确基础选择
- 英语/汉语词库静态激活机制需要应对语义混淆问题

### 设计差距
- LECTOR提示FSRS语义感知是一个值得关注的进化方向
- CoEvo的词库复习可在未来考虑引入语义相似度分析，避免"形近词"或"近义词"混淆
- LLM语义分析作为FSRS的增强层，是区别于竞品（纯算法SRS）的潜在优势
