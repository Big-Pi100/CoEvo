---
title: "The Protégé Effect: Learning by Teaching"
authors: ["Koh, A. W. L.", "Lee, S. C.", "Lim, S. W. H."]
year: 2018
journal: "Educational Psychology Review"
tags: ["费曼学习法", "教学效应", "学习策略", "生成学习"]
key_findings: "预期需要教别人（即使不实际教）即可显著提升学习表现，教学效应通过检索练习和元认知监控双通道发挥作用"
methodology: "系统性综述 + 元分析"
sample_size: "综合多项研究"
relevance:
  - module: "llm_prompt"
    impact: "AI 可扮演需要被教的学生角色，引导用户用自己的话解释概念，触发 protégé effect"
    priority: "P0"
  - module: "concept_extraction"
    impact: "ColdPath 提取概念后，可以用「费曼模式」让用户验证是否真正理解"
    priority: "P1"
  - module: "conversation_flow"
    impact: "对话系统中可增加「教我」模式：AI 扮演不懂的学生向用户提问"
    priority: "P1"
---

## 摘要

Koh 等 2018 年发表在 Educational Psychology Review 上的元分析系统性地考察了"学习通过教学"（learning by teaching）效应，即 protégé effect。研究发现，仅仅是预期需要向他人传授知识就足以提升学习者的学习表现（效应量中等偏上）。这种效应的认知机制包括：① 检索练习（准备教时需要主动回忆）② 元认知监控（意识到自己的知识缺口）③ 对材料的深度加工。

## 关键发现

1. **预期效应**：即使不实际教，仅仅预期需要教就带来学习收益（10-20% 的成绩提升）
2. **双通道机制**：教学效应 = 检索练习（回忆材料）+ 元认知监控（识别缺口）
3. **跨领域一致**：科学、数学、语言学习等多个领域都验证了该效应
4. **教学对象不重要**：对着真人教学、对着录音机讲、甚至对着想象中的观众解释都有效
5. **费曼法的认知科学基础**：简化解释 + 识别缺口 + 重新学习 = 理想困难的另一种形式

## 对 CoEvo 的影响

### 已验证的设计
- AI 对话的问答模式部分实现了"教学"的互动性
- 复习系统的翻卡机制涉及主动回忆（protégé effect 的通道之一）

### 设计差距
- **缺少专门的「费曼模式」**：AI 可以扮演需要被教的学生，要求用户解释刚学到的概念
- AI 目前的角色是"老师"，而不是"学生"——角色反转能触发 protégé effect
- 概念卡片可通过「教我验证」环节确认用户是否真正理解
- 元认知监控机制缺失：用户识别知识缺口的过程是学习的关键，应有系统性支持

## 相关研究
- Fiorella, L., & Mayer, R. E. (2016). "Eight Ways to Promote Generative Learning." Educational Psychology Review.
- Rozenblit, L., & Keil, F. (2002). "The Misunderstood Limits of Folk Science: An Illusion of Explanatory Depth." Cognitive Science.
- Kobayashi, K. (2018). "Learning by Teaching: A Meta-Analysis." Japanese Psychological Research.
