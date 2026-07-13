---
title: "The Misunderstood Limits of Folk Science: An Illusion of Explanatory Depth"
authors: ["Rozenblit, L.", "Keil, F."]
year: 2002
journal: "Cognitive Science"
tags: ["解释深度错觉", "元认知", "费曼学习法", "知识监控"]
key_findings: "人们普遍高估自己对日常事物工作原理的理解（解释深度错觉），只有在真正尝试解释时才意识到自己的无知"
methodology: "多组实验，参与者自评理解度后在尝试解释后再评"
sample_size: "多个实验，共数百名参与者"
relevance:
  - module: "verification_system"
    impact: "客观验证设计的核心理由：用户的自我评估不可靠，必须用外部验证"
    priority: "P0"
  - module: "knowledge_tracking"
    impact: "解释深度错觉揭示了为什么AI不能只依赖用户自我报告的理解水平"
    priority: "P0"
  - module: "llm_prompt"
    impact: "AI 可以通过要求用户解释概念来帮助用户打破解释深度错觉"
    priority: "P1"
---

## 摘要

Rozenblit & Keil 2002 年在 Cognitive Science 上发表的重要研究发现了"解释深度错觉"（illusion of explanatory depth, IOED）现象。人们以为自己知道拉链、马桶、直升机等日常事物的工作原理，但当被要求给出详细的机械因果解释时，才发现自己实际上不知道。这种"以为知道但说不出来"的体验是元认知偏差的核心表现形式，也是费曼学习法之所以有效的心理机制基础。

## 关键发现

1. **普遍性**：几乎所有参与者都高估了自己的理解水平（IOED 效应）
2. **领域特异性**：对人工制品（机器、设备）的 IOED 最明显，对自然现象和叙事的 IOED 较弱
3. **顽固性**：即使用现金激励也无法消除这种高估
4. **识别即瓦解**：一旦开始尝试解释，IOED 立即被识别并降低自评
5. **教育意义**：学生经常"以为学会了"，直到考试才意识到不会

## 对 CoEvo 的影响

### 已验证的设计
- 客观验证系统（不依赖自我判断）正是针对 IOED 的设计——用户说"会了"不等于真的会
- FSRS 调度基于实际表现而非自我评估

### 设计差距
- 可增加"你会不会？解释一下"环节作为知识验证的轻量级替代
- AI 对话中可主动制造"解释挑战"：要求用户用自己的话解释概念
- 学习报告可以展示"你以为会了 vs 实际会了"的差距数据

## 相关研究
- Keil, F. C. (2003). "Folkscience: Coarse Interpretations of a Complex Reality." Trends in Cognitive Sciences.
- Mills, C. M., & Keil, F. C. (2004). "Knowing the Limits of One's Understanding." Journal of Experimental Child Psychology.
