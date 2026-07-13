---
title: "Using AI to Implement Effective Teaching Strategies in Classrooms: Five Strategies, Including Prompts"
authors: ["Mollick, E. R.", "Mollick, L."]
year: 2023
journal: "SSRN (The Wharton School)"
tags: ["AI教学", "教学策略", "提示词设计", "LLM应用", "教育技术"]
key_findings: "LLM 可以可靠地实施五项核心教学策略（示例、检索、交错、反馈、生成），但需要精心设计的提示词"
methodology: "实验 + 设计框架"
sample_size: "多轮实验"
relevance:
  - module: "llm_prompt"
    impact: "CoEvo 的 prompt 设计可直接采用 Mollick 框架——五策略 + 角色设定"
    priority: "P0"
  - module: "product_strategy"
    impact: "AI 教学要实现的不只是'聊天'，而是系统性地实施认知科学验证的教学策略"
    priority: "P0"
---
## 摘要
Mollick & Mollick 提出了 AI 教学实践的开创性框架：五项基于研究的高效教学策略可以通过 LLM 可靠实施——① 提供示例和反例 ② 检索练习 ③ 交错练习 ④ 提供反馈 ⑤ 要求学生生成。关键是提示工程（prompt engineering）——不是简单地让 AI"教知识"，而是让 AI 按照确定的教学策略行动。

## 关键发现
1. **五策略框架**：AI 教学不是自由聊天，而是策略驱动的教学行为
2. **角色设定关键**：让 AI 扮演特定角色（导师、教练、学习伙伴）比开放式好
3. **模型差异**：GPT-4 在策略实施上远优于早期模型
4. **需要人工把关**：AI 仍会犯错和幻觉——教学场景需要人工监督
5. **不是替代教师**：AI 是教师的工具（增强教学）而非替代品

## 对 CoEvo 的影响
- CoEvo 的 prompt 设计框架应基于 Mollick 的五策略——不只是"解答问题"
- AI 对话中的角色设定非常关键——"AI特级教师"是有效角色
- 检索练习和反馈是 CoEvo 的核心，在对话中应有明确的 prompt 引导
- 可增加"反例"功能——展示一个常见的错误理解来加深正确理解
