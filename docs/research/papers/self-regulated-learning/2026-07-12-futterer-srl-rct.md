---
title: "AI 能教会孩子'学会学习'吗？——自我调节学习 RCT 实证研究"
authors: ["Fütterer", "等人"]
year: 2026
journal: "Educational Psychology Review"
tags: ["自我调节学习", "AI教育", "RCT", "学习动机"]
relevance:
  - module: "plan_handler.rs"
    impact: "SRL三阶段框架（预谋→执行→反思）应成为学习流程标准"
    priority: "P1"
  - module: "prompt_loader.rs"
    impact: "效用价值提示显著提升学习动机"
    priority: "P1"
  - module: "ws.rs"
    impact: "追问机制设计影响学习效果"
    priority: "P1"
  - module: "pipeline_router.rs"
    impact: "交互深度评分指标"
    priority: "P2"
key_findings: "AI辅助下的自我调节学习能显著提升学习动机，但效果需要更长时间才能转化为学科成绩。'效用价值组'（AI持续提示'这个知识点对你有什么用'）的学习动机显著优于对照组。深度互动（问→答→追问→反思）效果优于简单问答。"
methodology: "RCT，371名初中生，6周实验"
sample_size: 371
---
## 摘要
Fütterer 等人 2026 年在 Educational Psychology Review 发表的 RCT 研究：371 名初中生 6 周实验证实，AI 辅助下的自我调节学习（SRL）能显著提升学习动机，但其效果需要更长时间才能转化为学科成绩。

## 关键发现
1. **SRL三阶段模型有效**：预谋（设定目标/制定计划）→ 执行（监控理解/调整策略）→ 反思（评价效果/调整下一步）
2. **效用价值提示提升动机**：AI 持续提示"这个知识点对你有什么用"的学习动机显著优于对照组
3. **深度互动优于浅层问答**："问→答→追问→反思"效果显著优于"问→答→抄"
4. **效果转化需时间**：动机提升在 6 周内可见，但学科成绩提升需要更长期跟踪

## 对 CoEvo 的影响

### 已验证的设计
- CoEvo 的"学→记→验"流程覆盖了执行和反思阶段 ✅
- 追问机制已具备 ✅

### 设计差距
- **pre-planning**: 预谋阶段（目标设定）偏弱，需在 plan_handler.rs 中增加"今天要学什么？学到什么程度算掌握了？"
- **utility prompts**: prompt_loader.rs 中应在每个概念讲解前加入"为什么对你有用"的说明
- **depth scoring**: pipeline_router.rs 中应增加交互深度评分（轮次、追问次数、自我解释次数）

## 相关论文
