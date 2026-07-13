---
title: "Self-Explanations: How Students Study and Use Examples in Learning to Solve Problems"
authors: ["Chi, M. T. H.", "Bassok, M.", "Lewis, M. W.", "Reimann, P.", "Glaser, R."]
year: 1989
journal: "Cognitive Science"
tags: ["自我解释", "示例学习", "问题解决", "生成学习", "策略"]
key_findings: "学习者在研究示例时自发进行'自我解释'（用自己的话解释每一步为什么这样做）是深度理解的关键机制，高成就学生会自动做而低成就学生不做"
methodology: "出声思维法，学生研究生学习物理学示例"
sample_size: "多项对照实验"
relevance:
  - module: "llm_prompt"
    impact: "AI 对话应主动引导用户进行自我解释——'为什么这样？你用自己的话说说'"
    priority: "P1"
  - module: "verification_system"
    impact: "客观验证环节可要求用户解释答案而不只是给出答案——识别真懂 vs 背答案"
    priority: "P1"
---
## 摘要
Chi 等的经典研究发现：学生在学习物理学示例时，成功的解题者会自发产生大量"自我解释"——用自己的语言阐释示例中每一步的推理过程。失败的解题者不会做自我解释，而只是被动读示例。当引导所有学生做自我解释时，学习效果显著提升。自我解释使学习者从被动接收转为主动建构——这是生成学习（generative learning）的核心机制。

## 关键发现
1. **自然差异**：优等生在学习时自发自我解释，差生不会
2. **可训练性**：简单地告诉学生"解释给自己听"就能显著提升效果
3. **质量>数量**：高质量的自我解释（涉及推理）比大量的低质解释更重要
4. **缺口监控**：自我解释迫使学习者发现自己的知识缺口——这是元认知的基础

## 对 CoEvo 的影响
- 复习卡片翻到背面之前，AI 应引导用户先"解释给自己听"
- AI 对话可要求"用你自己的话说一遍"
- 客观验证的"解释验证"模式比选择题更能检验真实理解
