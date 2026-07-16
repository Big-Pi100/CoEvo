---
title: "When the Scaffold Stays On: AI, Practice Style, and Screening in Elite Skill Formation"
authors: ["Song Yao"]
year: 2026
journal: "arXiv:2606.06253 (Economics)"
tags: ["AI skill formation", "deliberate practice", "substitute vs complement", "competitive programming", "credentialing"]
relevance:
  - module: "AI对话引擎"
    impact: "AI辅助模式（替代型vs互补型）的分类框架为CoEvo的AI教学策略提供设计依据——如何引导用户成为complement-user而非substitute-user"
    priority: "P1"
  - module: "验证系统"
    impact: "AI禁止环境下的独立表现评估验证了客观验证的必要性，与CoEvo的验证系统设计理念一致"
    priority: "P1"
  - module: "品牌叙事"
    impact: "AI时代的深度技能形成——什么是真正的学习能力？与CoEvo品牌叙事高度契合"
    priority: "P2"
key_findings: |
  1. AI辅助存在两种截然不同的使用模式：替代型（用AI替代刻意练习）和互补型（用AI加速技能发展），同一AI输入因使用模式产生相反效果
  2. 在AI被禁止的竞赛环境中（ICPC/IOI），采用"AI风格练习模式"的选手反而表现出更强的非AI辅助表现——筛选机制区分了替代型和互补型用户
  3. AI时代需要设计新的评估门控（AI-prohibited evaluation gates）作为人力资本认证的基础
methodology: "利用国际大学生程序设计竞赛(ICPC/IOI)的AI禁止特征与Codeforces在线赛的AI允许特征，构建准实验设计。分析数百万次提交记录，构建AI提示特征签名（首次提交通过率↑、尝试次数↓、调试次数↓）"
sample_size: "百万级Codeforces提交记录，涵盖ICPC/IOI资格选手与非资格选手"
---
## 摘要

生成式AI通过完成学习者本应自己练习的任务来提高短期生产力。但这种替代是否侵蚀了前沿技能——即在AI不可用或不充分时所需的顶层能力——是一个日益紧迫的问题。本研究利用精英编程竞赛（ICPC/IOI禁止AI vs Codeforces允许AI）的自然实验，发现AI辅助存在两种截然不同的使用模式：替代型用户用AI替代刻意练习，互补型用户用AI加速技能发展。在AI禁止的环境下，采用互补型练习模式的选手反而表现出更强的非AI辅助表现。这一发现对医学、法律和专业认证等所有依赖AI时代人力资本认证的领域都有深远影响。

## 关键发现

1. **AI辅助的二元效应**：同一AI工具，替代型使用者技能退化，互补型使用者技能加速。关键在于"如何使用"而非"是否使用"
2. **筛选机制的分流作用**：在AI被禁止的竞赛中，经历过严格筛选进入的选手，其AI时代的练习模式反而预测了更好的非AI辅助表现
3. **AI时代的评估挑战**：传统的认证体系（执照、证书）需要设计AI禁止的评估门控，以区隔真正的能力
4. **跨领域推广**：编程领域的发现可推广到医学委员会、法律考试、专业认证等所有需要认证人力资本的高 stakes 场景

## 对 CoEvo 的影响

### 已验证的设计
- CoEvo的验证系统（客观验证而非自我判断）与论文揭示的"AI禁止评估门控"思路一致——只有独立于AI辅助的验证才能真正测量学会与否
- CoEvo的AI对话设计引导用户主动思考而非被动接受答案，与"互补型AI使用"模式一致

### 设计差距
- CoEvo当前缺乏对用户在AI辅助中的使用模式分类（替代型vs互补型），可以考虑在对话系统中加入使用模式检测，对替代型用户触发干预提示
- 可以将Yao(2026)的"互补型AI使用"模式设计成具体的交互策略，嵌入到AI教学对话中
