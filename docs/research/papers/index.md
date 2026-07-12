# CoEvo 教育研究知识库

> 所有创作和产品设计的基础。每日更新。

## 目录结构

```
papers/
  {topic}/
    {paper-slug}.md          # 单篇论文全文（格式见下）
  index.md                    # 主索引（本文件）
  topics.md                   # 主题标签索引
```

## 单篇论文格式

```yaml
---
title: "论文标题"
authors: ["作者1", "作者2"]
year: 2026
journal: "期刊名"
doi: "10.xxx/xxxxx"
url: "https://..."
tags: ["认知科学", "间隔重复", "FSRS"]
relevance:
  - module: "fsrs_scheduler"    # 影响的具体模块
    impact: "验证了FSRS参数设定"  # 具体影响
  - module: "achievement_engine"
    impact: "成就系统设计参考"
key_findings: |
  核心发现的详细描述...
methodology: "RCT，371名初中生，6周实验"
sample_size: 371
---
## 摘要

论文原文摘要...

## 关键发现

1. 发现一...
2. 发现二...

## 对 CoEvo 产品的影响

### 已验证的设计
- ...

### 设计差距
- ...

## 相关论文
- [[other-paper-slug]] - 关联说明
```

## 当前论文数

（由每日自动化管线维护，自动计数）
