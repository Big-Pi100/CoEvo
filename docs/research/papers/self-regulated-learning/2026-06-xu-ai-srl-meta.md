---
title: "AI support in self-regulated learning: A decade of technological evolution and meta-analysis"
authors: ["Jun Xu", "Yuying Luo", "Chengliang Wang", "Min Wang", "Yajie Wu"]
year: 2026
journal: "British Journal of Educational Technology"
tags: ["自我调节学习", "AI教育", "元分析", "生成式AI", "学习动机"]
relevance:
  - module: "ws.rs"
    impact: "AI在SRL执行阶段效果最强(g=0.574)——CoEvo对话交互设计强化执行阶段支持"
    priority: "P1"
  - module: "plan_handler.rs"
    impact: "预谋阶段(g=0.401)偏弱——需增加目标设定和计划反思"
    priority: "P1"
  - module: "pipeline_router.rs"
    impact: "生成式AI在所有阶段优于传统方法——CoEvo采用LLM是正确方向"
    priority: "P1"
  - module: "achievement_engine.rs"
    impact: "行为追踪指标(g=0.751)远优于自我报告(g=0.369)——客观验证比主观评价更可信"
    priority: "P2"
key_findings: "元分析35项研究(2013-2025)。AI支持SRL总体中等效果(g=0.507)。执行阶段最强(g=0.574)，预谋阶段最弱(g=0.401)。生成式AI在三个阶段的效应量均显著优于传统AI（预谋g=0.709，执行g=0.938，反思g=0.624）。行为追踪(e.g.停留时间、重试次数)效应量(g=0.751)是自我报告(g=0.369)的两倍多。"
methodology: "元分析，35项实证研究(2013-2025)"
sample_size: 35项研究
---
## 摘要

Xu et al. (2026) 在 British Journal of Educational Technology 发表的元分析，系统检视了35项实证研究（2013-2025），分析AI在 Zimmerman SRL 三阶段模型中的应用效果。

## 关键发现

1. **中等总体效果**：AI 支持 SRL 总体效应量 g=0.507
2. **执行阶段最强**：AI 在任务执行阶段（监控理解、调整策略）效果显著(g=0.574)，预谋阶段最弱(g=0.401)
3. **生成式AI全面领先**：ChatGPT等生成式AI在各阶段效果均显著优于传统规则/AI（预谋g=0.709，执行g=0.938，反思g=0.624）
4. **行为指标 > 自我报告**：行为追踪(e.g.停留时间、重试次数)的效应量(g=0.751)是自我报告(g=0.369)的两倍——说明客观验证更准确
5. **最佳场景**：中学 > 大学，自然科学 > 人文社科，纯在线 > 混合，2-10周中等干预时长

## 对 CoEvo 的影响

### 已验证的设计
- CoEvo 使用 LLM（生成式AI）而非传统规则系统 ✅
- 客观验证机制（测试效应、主动回忆）对应行为指标的优势 ✅
- 对话式交互覆盖执行阶段 ✅

### 设计差距
- **预谋阶段薄弱**：用户进入学习前缺乏明确的目标设定和计划制定环节
- **反思阶段自动化的机会**：学习报告可自动化生成反思引导，目前依赖用户主动回顾
- **SRL行为追踪**：可以在 pipeline_router.rs 中加入交互深度指标（停留时间、追问次数、自我解释触发率）

## 相关论文
- Zimmerman (1990) SRL 框架
- Fütterer et al. (2026) SRL×AI RCT
- 元认知框架相关论文
