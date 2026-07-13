---
title: "Training Language Models to Follow Instructions with Human Feedback"
authors: ["Ouyang, L.", "Wu, J.", "Jiang, X.", et al.]
year: 2022
journal: "NeurIPS"
tags: ["RLHF", "指令微调", "人机对齐", "价值观校准", "反馈学习"]
key_findings: "基于人类反馈的强化学习（RLHF）可以显著提升语言模型遵循指令的能力，减少有害输出，使其与人类价值观对齐"
methodology: "大规模RLHF实验：SFT → 奖励建模 → PPO优化"
sample_size: "标注员提供数十万条偏好数据"
relevance:
  - module: "llm_prompt"
    impact: "RLHF 的'人类反馈校准'机制与教育中'教师反馈如何塑造学生'有深刻的类比意义"
    priority: "P1"
  - module: "achievement_engine"
    impact: "反馈的质量和频率对行为塑造至关重要——不只是'对或错'，而是'好/更好/最好'的渐进式评价"
    priority: "P1"
  - module: "verification_system"
    impact: "客观验证的本质也是反馈校准——准确及时的反馈是学习的关键"
    priority: "P1"
---

## 摘要

InstructGPT/ChatGPT 的核心训练方法。RLHF 分为三步：① 监督微调（SFT）：在人工示范数据上微调预训练模型 ② 奖励建模（RM）：训练一个模型预测人类偏好 ③ 强化学习（PPO）：用奖励模型优化策略。RLHF 的核心贡献：让人工反馈直接参与模型行为塑造，使模型输出与人类价值观对齐。

## 关键发现

1. **反馈的有效性**：人类偏好数据虽稀疏且噪声大，但足够引导模型行为和价值观转变
2. **奖励黑客的防止**：奖励模型需要避免被"利用"——即模型发现取巧方式而非真正提升
3. **逐级训练**：SFT（知识）→ RM（判断基准）→ PPO（行为优化）——与"知识→价值观→行为"的教育路径一致
4. **反馈的层次**：直接纠错 < 偏好比较 < 原理教导——RLHF 使用了偏好比较（Pairwise）作为高效的反馈形式
5. **对齐税**：对齐训练可能降低部分能力——教育的"规范化"也有类似成本

## 对教育模式的启示

### RLHF → 教育反馈设计

| RLHF 组件 | 教育对应 | 启示 |
|:----------|:---------|:------|
| 奖励模型（RM） | 教师评价标准 | 评价标准需要清晰和一致 |
| PPO 优化 | 学生的试错调整 | 允许试错 + 及时反馈 → 最优学习 |
| 偏好数据（Pairwise） | "这个好那个更好"的评价 | 比较级反馈比绝对评价更有效 |
| 对齐税 | 标准化教育的代价 | 标准框架下个体创造力可能受损 |

### 设计差距
- CoEvo 的反馈系统可以借鉴 RLHF 的 pairwise 比较——让用户对比两个答案的好坏，而不是简单打分
- 奖励模型对应 CoEvo 的"怎么算学会了"——需要更精细的评价维度
- 对齐税提示我们：用户教育不能过度模式化

## 相关研究
- Christiano, P., et al. (2017). "Deep Reinforcement Learning from Human Preferences." NeurIPS.
- Bai, Y., et al. (2022). "Constitutional AI: Harmlessness from AI Feedback." arXiv.
