---
title: "Language Models are Few-Shot Learners"
authors: ["Brown, T. B.", "Mann, B.", "Ryder, N.", et al.]
year: 2020
journal: "NeurIPS"
tags: ["GPT-3", "扩展法则", "少样本学习", "大语言模型", "预训练"]
key_findings: "模型性能随参数量、数据量、计算量的增加呈现可预测的对数线性提升（Scaling Law），且出现涌现能力"
methodology: "大规模预训练实验，1750 亿参数"
sample_size: "海量互联网文本数据"
relevance:
  - module: "product_strategy"
    impact: "Scaling Law 对教育有深刻启示：学习效果与'数据量（经验）'的正相关，人类的'学习曲线'也有类似规律"
    priority: "P1"
  - module: "llm_prompt"
    impact: "Few-shot（给几个例子再学习）是人类教育中'示范教学'的精确类比"
    priority: "P1"
---

## 摘要

GPT-3 论文展示了语言模型的三个关键发现：① 模型性能随规模（参数量/数据量/计算量）可预测地提升（Scaling Law）② 在足够大的规模下，模型涌现出小模型不具备的能力 ③ 通过上下文学习（In-Context Learning，即少样本提示），模型可以从几个例子中快速学习新任务，无需参数更新。

## 关键发现

1. **Scaling Law**：模型性能随规模呈幂律关系——"更多的数据和更大的模型"带来可预测的提升
2. **涌现能力**：某些能力（如推理、翻译、代码生成）只在模型达到一定规模后才"涌现"
3. **上下文学习**：模型可以通过提示中的几个例子"学会"新任务，不需要梯度更新——这类似于人类的"示范学习"
4. **预训练—微调范式**：广泛预训练 + 任务特定微调——与"通识教育 + 专业训练"同构

## 对教育模式的启示

### 与人类学习的关键对照
| AI 训练 | 人类教育 | 对应关系 |
|:--------|:---------|:---------|
| 预训练（海量数据） | K-12 通识教育 | 广泛接触各学科基础 |
| 微调（任务数据） | 本科/研究生专业 | 专注特定领域深度 |
| RLHF（人类反馈） | 道德/价值观教育 | 社会反馈校准行为 |
| 上下文学习（Few-Shot） | 课堂示范教学 | 给几个例子→学会 |

### 设计差距
- 教育的"Scaling Law"是什么？学习效果与"投入时间"和"有效策略"的关系？
- 人类学习的"涌现"现象：某些理解（如数学直觉）是否在达到一定知识量后才出现？
- 少样本教学在 CoEvo 中可系统化：给用户几个精选例子帮助理解抽象概念

## 相关研究
- Kaplan, J., et al. (2020). "Scaling Laws for Neural Language Models." arXiv.
- Wei, J., et al. (2022). "Emergent Abilities of Large Language Models." TMLR.
