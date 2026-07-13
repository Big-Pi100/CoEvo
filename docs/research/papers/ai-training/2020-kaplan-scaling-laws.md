---
title: "Scaling Laws for Neural Language Models"
authors: ["Kaplan, J.", "McCandlish, S.", "Henighan, T.", et al.]
year: 2020
journal: "arXiv"
tags: ["扩展法则", "Scaling Law", "计算量", "模型容量", "数据量"]
key_findings: "语言模型的性能（交叉熵）随参数量、数据量和计算量呈可预测的幂律关系——存在最优分配比例"
methodology: "大规模实验，固定训练预算下的系统性对比"
sample_size: "多个不同规模的模型（768到1.5B参数）"
relevance:
  - module: "product_strategy"
    impact: "学习的投入产出比遵循类似规律——'更多的练习+更有效的策略=可预测的进步'"
    priority: "P1"
  - module: "k12_plan"
    impact: "学习计划的长度和强度设计可参考 Scaling Law 的边际效益递减原理"
    priority: "P1"
---
## 摘要
Kaplan 等的 Scaling Law 论文是大模型训练中的核心参考。他们发现三者的幂律关系：模型性能（perplexity）≈ 1/(参数量^0.07 × 数据量^0.095 × 计算量^0.05)。重要的不仅是"越大越好"，还有资源的最优分配——在固定计算预算下，模型大小和训练数据量应成比例增长。

## 关键发现
1. **幂律关系**：性能提升随资源投入边际递减（但未看到天花板）
2. **最优分配**：给定预算下，应同时增加模型大小和数据量——不是只加参数量
3. **过拟合不关键**：在 Scaling Law 下，更大的模型在更多数据上训练不会过拟合
4. **可预测性**：小规模实验可以预测大规模训练的性能

## 对 CoEvo 的启示
- 学习的"Scaling Law"：投入时间×有效策略×多样性≈学习成果
- 边际递减是自然的——不是平台期的失败而是 Scaling Law 的正常表现
- 平衡"学习量"和"学习方法"——就像平衡模型大小和数据量
