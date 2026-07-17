---
title: "Adaptive Cognitive Intervention Architecture: An Exploratory Computational Framework for Precision Reading Comprehension in Higher Education"
authors: ["ACIA Research Group"]
year: 2026
journal: "Journal of Intelligence (MDPI)"
tags: ["metacognition", "reading comprehension", "adaptive learning", "precision education", "learner heterogeneity"]
relevance:
  - module: "元认知"
    impact: "验证元认知监控对阅读理解的促进作用，支持CoEvo的元认知训练模块设计"
    priority: "P1"
  - module: "学习策略"
    impact: "学习者表型分型揭示4类学习响应模式，支持CoEvo个性化学习策略推荐"
    priority: "P2"
  - module: "AI个性化"
    impact: "XGBoost预测阅读理解提升(R²=0.61)，贝叶斯自适应推理框架与CoEvo的AI教学策略相似"
    priority: "P2"
key_findings: "8周元认知阅读干预后，4类学习者表型（高响应者/策略改进者/监控依赖者/低响应者）表现出异质性学习轨迹，XGBoost准确预测个体化理解增长(R²=0.61)，Markov迁移模型揭示干预后学习者状态再分布模式"
methodology: "准实验纵向设计，8周结构化元认知阅读干预，潜剖面分析+可解释机器学习+Markov迁移分析+贝叶斯自适应推理"
sample_size: "未明确给出总样本量（多所高校）"
---
## 摘要

阅读理解是高等教育中的关键认知能力，但学生对元认知教学干预的响应存在显著异质性。本研究提出自适应元认知阅读系统（ACIA），整合潜变量学习者响应表型分型、可解释机器学习、Markov迁移分析、贝叶斯自适应推理和强化学习优化。

## 关键发现

1. **四类学习者表型**: 高响应者、策略改进者、监控依赖者、低响应者——学习策略干预不能一刀切
2. **XGBoost预测有效**: 预测阅读理解增长R²=0.61，可解释性强
3. **元认知监控可训练**: 计划/监控/评估/策略灵活性/阅读SRL活动均能改善
4. **MAI量表可靠性高**: Cronbach's α 0.83-0.89，验证了元认知觉知测量的信度

## 对 CoEvo 的影响

### 已验证的设计
- CoEvo个性化学习路径（根据学习者类型定制）方向正确——存在可检测的学习者表型差异
- 元认知监控训练模块有研究支撑（计划→监控→评估→策略调整）

### 设计差距
- CoEvo当前缺少显式的元认知策略训练模块
- 学习者表型分型可作为用户画像的补充维度
- 强化学习优化框架可启发CoEvo的自适应推送策略
