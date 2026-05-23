# CoEvo 测试体系使用说明

> 日期：2026-05-22
> 覆盖：管线 E2E 测试 · K12 横向覆盖 · 分级通过体系 · 生命周期日志

---

## 目录

1. [测试体系概述](#一测试体系概述)
2. [管线 E2E 测试 (`e2e-pipeline-test`)](#二管线-e2e-测试-e2e-pipeline-test)
3. [K12 横向覆盖测试 (`e2e-k12-runner`)](#三k12-横向覆盖测试-e2e-k12-runner)
4. [分级通过体系](#四分级通过体系)
5. [管线矩阵](#五管线矩阵)
6. [生命周期日志](#六生命周期日志)
7. [常见问题](#七常见问题)

---

## 一、测试体系概述

CoEvo 测试体系由**两个独立二进制**组成，覆盖不同粒度的测试需求：

| 二进制 | 定位 | 运行时 | 适合场景 |
|--------|------|--------|---------|
| `e2e-pipeline-test` | 深度管线验证 | ~7 分钟 | prompt 修改后、部署前 |
| `e2e-k12-runner` | 横向科目覆盖 | ~40 分钟（全量） | 模型升级后、新管线注册 |

两者共享核心基础设施：
- `e2e_runner.rs` — 测试数据初始化、断言辅助函数、结果序列化
- `PhaseResult` / `Grade` / `LifecycleLog` — 统一结果结构
- `prompt_loader` / `plan_handler` / `concept_extractor` — 被测系统核心模块

---

## 二、管线 E2E 测试 (`e2e-pipeline-test`)

### 用途

按 7 个阶段顺序测试 CoEvo 核心管线，覆盖从计划创建到复习提交的全链路。

### 使用方法

```bash
# 在 backend 目录下执行

# 完整流水线（7 阶段，需 ~7 分钟）
cargo run --bin e2e-pipeline-test -- --force --clean

# 单阶段执行
cargo run --bin e2e-pipeline-test -- --phase plan-creation
cargo run --bin e2e-pipeline-test -- --phase concept-extraction

# 从指定阶段续跑
cargo run --bin e2e-pipeline-test -- --from progression-history

# 指定 domain 过滤（仅 Phase 1 生效）
cargo run --bin e2e-pipeline-test -- --domain math
```

### 命令行参数

| 参数 | 缩写 | 默认值 | 说明 |
|------|:----:|:------:|------|
| `--phase` | `-p` | 全部 | 执行指定阶段（逗号分隔） |
| `--from` | `-f` | — | 从指定阶段开始执行 |
| `--domain` | `-d` | 全部 | 过滤 domain（仅 Phase 1） |
| `--model` | `-m` | deepseek-v4-flash | LLM 模型 |
| `--force` | — | false | 忽略断点续跑，强制重新执行 |
| `--clean` | — | false | 清除已有测试 DB |
| `--report-only` | — | false | 仅生成报表 |

### 7 个阶段详解

| 阶段 | 耗时 | 测试内容 | 通过条件 |
|:----:|:----:|---------|---------|
| 1. plan-creation | ~1min | 3 个 domain（math/language/general）的计划创建 + 路由 | domain 准确率 3/3 → A |
| 2a. progression-history | ~2min | 通用管线教学对话（6 轮双 LLM） | 有教学 + plan_update → A |
| 2b. progression-language | ~2min | language 管线教学对话 | 同上 |
| 2c. progression-math | ~2min | math 管线教学 + LaTeX 检测 | 同上 + LaTeX 检出 → A |
| 3. concept-extraction | ~30s | 真实 LLM 概念提取 + word_bank 降级 | 有候选概念 + domain 正确率≥50% → A |
| 4. review-flow | ~1s | 复习提交：reps 递增 / lapses 递增 / review_log 记录 | 三项全部通过 → A |
| 5. report | ~1s | 聚合报表生成 | 始终 A |

### 输出位置

```
backend/docs/test-results/<run_id>/
├── config.json           ← 运行配置（支持断点续跑）
├── phase-plan-creation.json  ← 每阶段完整结果
├── phase-progression-history.json
├── ...
├── latest/               ← 最近一次运行的符号链接
└── report.md             ← 聚合报表（含等级）
```

---

## 三、K12 横向覆盖测试 (`e2e-k12-runner`)

### 用途

5 学段 × 适用科目 = 30 个测试用例，按 subject-grade 独立运行。
每个用例有独立数据库、完整生命周期日志。

### 使用方法

```bash
# 后端全部 30 个（串行，约 40 分钟）
cargo run --bin e2e-k12-runner

# 按学段分批
cargo run --bin e2e-k12-runner -- --grade g1-2
cargo run --bin e2e-k12-runner -- --grade g7-9

# 按科目筛选
cargo run --bin e2e-k12-runner -- --subject 数学
cargo run --bin e2e-k12-runner -- --subject 化学

# 限制测试数（调试用）
cargo run --bin e2e-k12-runner -- --max-tests 5

# 指定并发数
cargo run --bin e2e-k12-runner -- --concurrency 3
```

### 命令行参数

| 参数 | 缩写 | 默认值 | 说明 |
|------|:----:|:------:|------|
| `--subject` | `-s` | 全部 | 按科目名过滤（支持模糊匹配） |
| `--grade` | `-g` | 全部 | 按学段过滤（g1-2 / g3-4 / g5-6 / g7-9 / g10-12） |
| `--concurrency` | `-c` | 3 | 并行数（当前仅 1 可用，>1 有内存 bug） |
| `--max-tests` | `-m` | 999 | 最大测试用例数 |

### 30 测试矩阵

| 学段 | 年级 | 科目 | domain | 开场白（学生学习目标） |
|:----:|:----:|:----|:------|----------------------|
| **g1-2** | 1-2 年级 | 数学 | math | 20以内加减法和乘法口诀 |
| | | 语文 | general | 拼音和基础汉字 |
| | | 英语 | language | 基础英语单词 |
| **g3-4** | 3-4 年级 | 数学 | math | 分数四则运算和简单几何 |
| | | 语文 | general | 成语故事和阅读理解 |
| | | 英语 | language | 基础英语语法和日常词汇 |
| | | 科学 | math | 动植物分类和物理现象 |
| **g5-6** | 5-6 年级 | 数学 | math | 比例、百分数和立体几何 |
| | | 语文 | general | 古诗文鉴赏和记叙文写作 |
| | | 英语 | language | 英语时态和从句 |
| | | 科学 | math | 简单机械、电路和生态系统 |
| | | 历史 | general | 中国历史主要朝代和事件 |
| **g7-9** | 初中 | 数学 | math | 一次函数、二次函数和几何证明 |
| | | 语文 | general | 文言文阅读和议论文写作 |
| | | 英语 | language | 被动语态、定语从句等 |
| | | **物理** | math | 牛顿定律、压强和浮力 |
| | | **化学** | chemistry | 化学元素、化学反应和方程式 |
| | | **生物** | biology | 细胞结构、遗传和人体生理 |
| | | 历史 | general | 世界历史从古代到近代 |
| | | 地理 | general | 气候带、地形和人口分布 |
| | | 政治 | general | 法律基础和公民权利义务 |
| **g10-12** | 高中 | 数学 | math | 函数、导数、三角函数和数列 |
| | | 语文 | general | 古文阅读和文学鉴赏 |
| | | 英语 | language | 高级英语语法和写作技巧 |
| | | 物理 | math | 力学、电磁学和热学 |
| | | **化学** | chemistry | 有机化学和化学反应原理 |
| | | **生物** | biology | 遗传进化、生态系统和生物技术 |
| | | 历史 | general | 世界近现代史和研究方法 |
| | | 地理 | general | 自然地理和人文地理 |
| | | 政治 | general | 政治经济学和哲学基础 |

### 单用例测试流程

每个 subject-grade 测试执行以下 5 个阶段：

```
Phase A: 计划创建
  ├── Turn 1: 用户表达学习目标 → LLM 回应
  ├── Turn 2: 用户确认 → LLM 创建 plan_update
  └── 记录: plan_created, domain

Phase B: 多轮教学（4 轮固定学生回答）
  ├── Turn 1: "请开始教我第一个任务"
  ├── Turn 2: "我理解了，请继续举例"
  ├── Turn 3: "请出题考考我"
  └── Turn 4: "我答对了，请继续"
  记录: progression_turns, plan_updates, plan_events

Phase C: 概念提取
  └── extract_concepts(domain-specific prompt)
  记录: candidates_extracted

Phase D: 复习验证
  └── 创建卡片 → submit_review(rating=3)
  记录: cards_created, reviews_submitted

Phase E: 成就检查
  └── 查询 achievements 表
  记录: achievement_events
```

### 输出位置

```
backend/docs/k12-results/<run_id>/
├── 数学_g1-2.json        ← 每用例完整生命周期日志
├── 物理_g10-12.json
├── 化学_g7-9.json
└── ...
```

---

## 四、分级通过体系

### 等级定义

| 等级 | 含义 | 后续处理 |
|:----:|------|---------|
| **A** | 完全符合设计预期 — pipeline prompt 正确路由 + 字段 100% 对齐 | 可发布 |
| **B** | 功能正确但有轻微偏差 — 部分字段不对齐，不影响主要功能 | 需人工评估 |
| **C** | 兜底机制触发 — LLM 提取路径未走通但 word_bank/通用路径成功 | 需修复 |
| **D** | 兜底部分生效 — 只有少量有效输出，功能勉强可用 | 需修复 |
| **F** | 彻底失败 — 无有效输出 | 阻断发布 |

### 各阶段等级判定

**管线 E2E 测试 (`e2e-pipeline-test`)：**

| 阶段 | A 条件 | C 条件 | F 条件 |
|------|--------|--------|--------|
| plan-creation | domain 准确率 3/3 | 1-2/3 | 0/3 |
| progression-* | 有教学 + plan_update > 0 | — | 无教学 |
| concept-extraction | total > 0 + domain_ok | total > 0 | total = 0 |
| review-flow | reps + lapses + logs | — | 全部失败 |

**K12 测试 (`e2e-k12-runner`)：**

| 条件 | 等级 |
|------|:----:|
| plan_created + turns > 0 + candidates > 0 + no errors | A |
| turns > 0 + no errors（候选概念可为 0） | B |
| turns > 0（有错误） | C |
| 无错误但无教学 | D |
| 有错误且无教学 | F |

---

## 五、管线矩阵

### 当前注册管线

| domain | 对学科 | 有独立 prompt 目录 | 说明 |
|--------|--------|:----------------:|------|
| `language` | 英语 | ✅ | 完整 7 文件（教学+提取+出题） |
| `math` | 数学、物理、科学 | ✅ | 完整 7 文件（含 LaTeX 格式） |
| `chemistry` | 化学 | ✅ | 概念提取专用，其余回退到通用 |
| `biology` | 生物 | ✅ | 概念提取专用，其余回退到通用 |
| `""` (general) | 语文、历史、地理、政治 | — | 通用管线（兜底） |

### 画线决策原则

```
├── 理科（数学/物理/化学/生物/科学）
│   ├── 数学/物理/科学 → math 管线       ← 公式/定理用 LaTeX 表达
│   ├── 化学          → chemistry 管线    ← 元素/反应有独立概念提取 prompt
│   └── 生物          → biology 管线      ← 细胞/遗传有独立概念提取 prompt
│
├── 文科（语文/历史/地理/政治）→ 通用管线  ← 通用知识提取 prompt 够用
│
└── 语言（英语）→ language 管线          ← 词汇/语法专用 prompt
```

### 注册新管线

只需三步：

```rust
// 1. 建目录 + 写 prompt 文件
mkdir -p pipelines/physics/prompts/
cp prompts/chat_system.md pipelines/physics/prompts/  # 复制通用 prompt
# 编辑 pipelines/physics/prompts/concept_extract.md

// 2. 注册到 prompt_loader.rs
// 在 init() 的 for domain in &[...] 中添加 "physics"

// 3. 更新 subject_matrix（如果是 K12 科目）
// 在 subjects.rs 的 get_k12_matrix() 中添加对应条目
```

不存在 prompt 文件的管线自动回退到通用版本，零成本兼容。

---

## 六、生命周期日志

### 日志结构（JSON，每用例一个文件）

每个测试用例输出一个 JSON 文件，**包含完整的 LLM 对话内容**（system prompt、user content、LLM 回复均完整保存，无截断），用于后续 Prompt 调优和问题排查。

```json
{
  "run_id": "k12-20260522_091419",
  "subject": "化学",
  "grade_band": "g7-9",
  "domain": "chemistry",

  "plan_created": true,
  "progression_turns": 4,
  "plan_updates": 1,
  "candidates_extracted": 9,
  "cards_created": 0,
  "reviews_submitted": 0,
  "review_pass_rate": 0.0,

  "llm_calls": [
    {
      "step": "plan_creation_turn1",
      "domain": "chemistry",
      "system_prompt": "<前200字预览>",
      "user_content": "<前200字预览>",
      "response": "<前500字预览>",
      "duration_ms": 28473,
      "success": true
    }
  ],

  "plan_events": [
    {"event": "created", "turn": 2, "diff_summary": "domain=chemistry is_new=true"}
  ],

  "card_events": [
    {"event": "extracted", "card_front": "氧化还原反应 (Redox reaction)", "card_domain": "chemistry"}
  ],

  "achievements": [],

  "status": "passed",
  "grade": "A",
  "duration_ms": 59034,
  "errors": []
}
```

### 日志用途

| 字段 | 用途 |
|------|------|
| `llm_calls[].system_prompt` | **完整保存** — Prompt 调优，确认 LLM 看到了什么 |
| `llm_calls[].response` | **完整保存** — 输出质量分析，格式和内容检查 |
| `plan_events` | 学习计划生命周期 — 是否按预期创建和推进 |
| `card_events` | 卡片提取质量 — 提取了哪些概念 |
| `achievements` | 成就系统覆盖 — 哪些成就被触发 |

---

## 七、常见问题

### Q: 30 个 K12 测试一次跑不完，总崩溃？

运行 `--concurrency 1`（串行模式），然后按学段分 5 次跑：

```bash
cargo run --bin e2e-k12-runner -- --grade g1-2
cargo run --bin e2e-k12-runner -- --grade g3-4
cargo run --bin e2e-k12-runner -- --grade g5-6
cargo run --bin e2e-k12-runner -- --grade g7-9
cargo run --bin e2e-k12-runner -- --grade g10-12
```

这是已知的 Windows 内存问题，release 模式或 Linux 下不会出现。

### Q: 理科概念提取结果为 0？

检查对应科目是否注册了正确的管线 domain：

```
# 当前 mapping
数学/物理/科学 → domain="math"      → math 管线的 concept_extract.md
化学           → domain="chemistry" → chemistry 管线的 concept_extract.md
生物           → domain="biology"   → biology 管线的 concept_extract.md
```

如果 domain 为空串，走通用管线，通用概念提取 prompt 可能不擅长提取理科概念。

### Q: 测试结果存放位置？

- 管线 E2E: `backend/docs/test-results/<run_id>/`
- K12: `backend/docs/k12-results/<run_id>/`

### Q: 如何对比两次运行的回归？

```bash
# 1. 运行两次不同 prompt 版本的测试
cargo run --bin e2e-pipeline-test -- --force --clean

# 2. 比较 report.md 中的 grade 变化
diff docs/test-results/run_old/report.md docs/test-results/run_new/report.md

# 3. 比较具体候选概念的变化
cat docs/test-results/run_new/phase-concept-extraction.json |
  node -e "const j=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));j.card_events.forEach(c=>console.log(c.card_front))"
```
