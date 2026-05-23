# 质量评估管线设计文档

> 版本：V2 — 2026-05-22
> 对齐对象：`evaluation-framework.md`（V1）
> 架构：Pipeline 1（测试线）→ Pipeline 2（评估线）

---

## 一、两线架构

```
Pipeline 1：测试线（已完工 ✅）
================================
  k12-runner / e2e-pipeline-test
       │
       ▼
  每用例 LifecycleLog JSON（30 个）
  ├── llm_calls[].system_prompt  ← 完整保存
  ├── llm_calls[].user_content   ← 完整保存
  ├── llm_calls[].response       ← 完整保存
  ├── plan_events[]
  ├── card_events[]
  └── achievements[]
       │
       ▼
  docs/k12-results/<run_id>/


Pipeline 2：评估线（待建设 🚧）
================================
  e2e-quality-eval
       │
       ▼
  读取 LifecycleLog JSON
       │
       ├── L1 自动计算（plan / review）
       └── L2 第二条 LLM 评估
              ├── teacher 维度  ← 1 LLM 调用/用例
              ├── card 维度     ← 1 LLM 调用/用例
              └── student 维度  ← 1 LLM 调用/用例（待双 LLM 数据就绪）
       │
       ▼
  QualityEval JSON（30 个，与 LifecycleLog 一一对应）
       │
       ▼
  综合报告 quality-report.md
```

### 设计原则

| 原则 | 说明 |
|------|------|
| **只读** | 评估管线只读取 LifecycleLog JSON，不写入测试数据 |
| **增量** | 先跑已有维度（教师/卡片/计划），其余补全后再开 |
| **可重入** | 同一份日志多次评估结果一致（LLM 温度=0） |
| **成本可控** | 当前 30 用例 × 2 LLM ≈ 60 次评估调用 ≈ 30 分钟 |

---

## 二、评估维度

5 个维度，严格对齐 `evaluation-framework.md`：

```
维度                     LLM 调用    L1/L2    当前状态
──────────────────────────────────────────────────────
1. 教师回答质量 (Teacher)   1/用例     L2       ✅ 可评估
2. 学生模拟质量 (Student)  1/用例     L2       ⏳ 需双 LLM 数据恢复后可用
3. 计划执行度 (Plan)       0        L1       ✅ 可评估
4. 卡片提取质量 (Card)     1/用例     L2       ✅ 可评估
5. 复习全链路 (Review)     0        L1       ⏳ 需 K12 触发 review 后可用
```

### 2.1 教师回答质量（Teacher）

**L2 评估**：将教学对话送入第二条 LLM 打分。

| 指标 | 类型 | 权重 | 说明 |
|------|:----:|:----:|------|
| T1 内容正确性 | L2 | 30% | 讲解内容是否有知识性错误 |
| T2 年级适配度 | L2 | 20% | 难度和语言是否符合目标年级 |
| T3 结构清晰度 | L2 | 20% | 是否按"讲解→举例→练习→考核"推进 |
| T4 概念覆盖 | L1 | 15% | 教学轮中提出的关键概念数 |
| T5 plan_update 频率 | L1 | 15% | plan_update 次数 / 教学轮数 |

**LLM 评估 prompt：**
```
你是一位教育评估专家。以下是 AI 教师在 {subject}（{grade_band} 水平）
教学中的对话。请从以下维度评分（每项 0-100）：

1. 内容正确性（correctness）：讲解内容有没有知识性错误？
2. 年级适配度（grade_fit）：难度和语言是否符合 {grade_band} 学生？
3. 结构清晰度（structure）：是否按"讲解→举例→练习→考核"推进？

教学对话：
{4 轮教学对话，含 user 和 assistant 轮次}

只返回 JSON：
{"correctness": 85, "grade_fit": 70, "structure": 90,
 "issues": ["具体问题1", "具体问题2"]}
```

### 2.2 学生模拟质量（Student）

**L2 评估**：将学生回答送入第二条 LLM，评估自然度。当前 K12 runner 使用固定学生回答（4 句模板），此维度暂不可用。

| 指标 | 类型 | 权重 | 说明 |
|------|:----:|:----:|------|
| S1 错误率 | L2 | 25% | 学生犯错占比（真实学生不会全对） |
| S2 语域自然度 | L2 | 25% | 口语化、短句、填充词 |
| S3 追问率 | L2 | 20% | "为什么""能再举个例子吗" |
| S4 多样性 | L1 | 15% | 句式和长度变化 |
| S5 理解深度 | L2 | 15% | 机械复述还是真理解 |

**前置条件**：K12 runner 恢复双 LLM 师生对聊模式。

### 2.3 计划执行度（Plan）

**L1 自动计算**：从 `plan_events` 和 `llm_calls` 中提取。无需额外 LLM 调用。

| 指标 | 计算公式 | 权重 |
|------|---------|:----:|
| P1 命令解析率 | 成功解析的 plan_update / 总尝试 | 30% |
| P2 stage 推进 | 有 stage 推进的回合 / 总回合 | 25% |
| P3 task 完成 | task_complete=true 的回合 / 总回合 | 20% |
| P4 plan 持久化 | plan_json 有写入 DB | 15% |
| P5 路由一致性 | plan domain 与用例 domain 一致 | 10% |

### 2.4 卡片提取质量（Card）

**L2 评估**：将提取的 candidates 送入第二条 LLM 打分。

| 指标 | 类型 | 权重 | 说明 |
|------|:----:|:----:|------|
| C1 候选概念数 | L1 | 15% | 原始提取数量 |
| C2 domain 准确率 | L1 | 15% | domain 与管线一致的比例 |
| C3 front 质量 | L2 | 25% | 概念名是否恰当、不是问句 |
| C4 back 质量 | L2 | 25% | 释义是否完整、有结构 |
| C5 去重正确率 | L1 | 10% | 重复提取是否有效抑制 |
| C6 有用率 | L2 | 10% | 提取的概念有多少真正有复习价值 |

**LLM 评估 prompt：**
```
以下是从 AI 教学对话中提取的复习卡片。请评估每张卡片的质量。

教学语境（最后 1 轮 AI 回答，前 2000 字）：
{ai_reply 截取}

提取的卡片：
{card_events 中 extracted 事件列表}

评分规则：
1. front_quality：概念名称是否恰当、是否适合作为记忆卡片（0-100）
2. back_quality：释义是否有实质内容、有结构（0-100）
3. useful_rate：多少比例的卡片有复习价值（0-1）
4. missing_concepts：对话中出现了但未被提取的重要概念

输出 JSON：
{"front_quality": 80, "back_quality": 75, "useful_rate": 0.85,
 "missing_concepts": ["概念A", "概念B"],
 "comment": "整体提取质量较好，但缺少xxx"}
```

### 2.5 复习全链路（Review）

**L1 自动计算**：从 `card_events` 和 test 指标中提取。当前 K12 测试未触发 review 流程，此维度暂不可用。

| 指标 | 计算公式 | 权重 |
|------|---------|:----:|
| R1 制卡成功率 | 写入 DB 的卡片 / 总候选概念 | 20% |
| R2 FSRS 正确性 | submit_review 后 state/due 正确变更 | 25% |
| R3 review_log | 每次复习是否写入 review_log | 20% |
| R4 验证匹配 | card_type 对应的验证策略是否激活 | 15% |
| R5 多轮一致性 | 多次复习后 reps 递增 / lapses 递增 | 20% |

---

## 三、综合评分模型

### 维度计分

```
Teacher = T1×0.30 + T2×0.20 + T3×0.20 + T4×0.15 + T5×0.15
Student = S1×0.25 + S2×0.25 + S3×0.20 + S4×0.15 + S5×0.15
Plan    = P1×0.30 + P2×0.25 + P3×0.20 + P4×0.15 + P5×0.10
Card    = C1×0.15 + C2×0.15 + C3×0.25 + C4×0.25 + C5×0.10 + C6×0.10
Review  = R1×0.20 + R2×0.25 + R3×0.20 + R4×0.15 + R5×0.20
```

### 综合加权

```
总评分 = Teacher×0.30 + Student×0.20 + Plan×0.15 + Card×0.25 + Review×0.10

权重来源：教学里教师最重要 → 30%，卡片是产品核心 → 25%，
          学生模拟是测试工具 → 20%，计划是运行保障 → 15%，
          复习是闭环但依赖功能触发 → 10%
```

### 不可用维度的处理

| 场景 | 处理方式 |
|------|---------|
| Student 不可用（无双 LLM） | 权重 20% 分摊到 Teacher (+10%) 和 Card (+10%) |
| Review 不可用 | 权重 10% 均摊到 Plan 和 Card |
| 两者都不可用 | Teacher 40% + Card 35% + Plan 25% |

### 评级映射

| 综合得分 | 评级 | 含义 |
|:-------:|:----:|------|
| ≥ 85 | A | 教学质量优秀 |
| ≥ 70 | B | 良好 |
| ≥ 55 | C | 及格 |
| ≥ 40 | D | 需改进 |
| < 40 | F | 不合格 |

---

## 四、输出格式

### 每用例 QualityEval JSON

```json
{
  "subject": "数学",
  "grade_band": "g7-9",
  "domain": "math",
  "source_run_id": "k12-20260522_091419",

  "scores": {
    "teacher": {
      "correctness": 92,
      "grade_fit": 85,
      "structure": 88,
      "coverage": 3,
      "plan_update_rate": 0.25,
      "overall": 86.7
    },
    "student": null,
    "student_unavailable_reason": "使用固定回答，需双LLM模式",
    "plan": {
      "parse_rate": 1.0,
      "stage_advancement": 0.75,
      "task_completion": 0.5,
      "persistence": 1.0,
      "routing_consistency": 1.0,
      "overall": 82.5
    },
    "card": {
      "candidate_count": 8,
      "domain_accuracy": 1.0,
      "front_quality": 80,
      "back_quality": 72,
      "dedup_rate": 1.0,
      "useful_rate": 0.85,
      "overall": 80.6
    },
    "review": null,
    "review_unavailable_reason": "K12测试未触发review流程",

    "composite": {
      "teacher_weighted": 26.0,
      "card_weighted": 20.2,
      "plan_weighted": 12.4,
      "student_weighted": 0,
      "review_weighted": 0,
      "total": 58.6,
      "grade": "C"
    }
  },

  "llm_eval_logs": [
    {"dimension": "teacher", "prompt": "你是一位教育评估专家...", "response": "{\"correctness\":92,...}"},
    {"dimension": "card", "prompt": "以下是从AI教学对话中...", "response": "{\"front_quality\":80,...}"}
  ],

  "issues": [
    {"severity": "warning", "category": "student", "message": "使用固定学生回答，自然度评估不可用"},
    {"severity": "warning", "category": "review", "message": "review流程未触发，FSRS正确性未验证"},
    {"severity": "info", "category": "card", "message": "back_quality偏低(72)，卡片释义可优化"}
  ]
}
```

### 聚合报告 `quality-report.md`

```
# 质量评估报告
> 运行ID: eval-20260522_120000 | 基础数据: k12-20260522_091419
> 评估维度: teacher + card + plan

## 总览
| 指标 | 值 |
|------|-----|
| 评估用例数 | 30 |
| 综合评分 A | 12 |
| 综合评分 B | 14 |
| 综合评分 C | 4 |
| 综合评分 D/F | 0 |
| 平均综合评分 | 72.3 |

## 各维度平均分
| 维度 | 平均分 | 最高 | 最低 |
|------|:----:|:----:|:----:|
| 教师质量 | 85.2 | 94 | 72 |
| 卡片质量 | 78.5 | 92 | 55 |
| 计划执行 | 82.0 | 100 | 60 |

## 按学科
| 学科 | 教师 | 卡片 | 计划 | 综合 |
|:----:|:----:|:----:|:----:|:----:|
| 数学 | 85 | 80 | 85 | 83.0 |
| 英语 | 90 | 82 | 80 | 85.5 |
| 化学 | 82 | 88 | 75 | 81.7 |

## 问题汇总
- 严重: 0
- 警告: 3（均为review未触发）
- 建议: 5（back_quality偏低等）
```

---

## 五、二进制设计

```bash
cargo run --bin e2e-quality-eval -- --input docs/k12-results/k12-20260522_091419/

# 常用组合
cargo run --bin e2e-quality-eval -- --input <dir> --dimensions teacher,card    # 先跑教师+卡片
cargo run --bin e2e-quality-eval -- --input <dir> --dimensions plan             # 计划自动(无LLM)
cargo run --bin e2e-quality-eval -- --input <dir> --all                        # 全部可用维度
cargo run --bin e2e-quality-eval -- --all-runs                                 # 全部历史数据
cargo run --bin e2e-quality-eval -- --input <dir> --report-only                # 仅生成报告
```

| 参数 | 默认 | 说明 |
|------|:----:|------|
| `--input` | 最新 run | LifecycleLog JSON 目录 |
| `--dimensions` | teacher,card | 评估维度(逗号分隔)：teacher/student/plan/card/review |
| `--all` | false | 评估全部可用维度 |
| `--all-runs` | false | 评估全部历史数据 |
| `--report-only` | false | 仅基于已有 QualityEval 生成报告 |
| `--concurrency` | 3 | LLM 并行调用数 |
| `--model` | deepseek-v4-flash | 评估用的 LLM 模型 |

### 目录结构

```
backend/
├── src/bin/e2e_quality_eval.rs       ← 二进制入口
├── crates/quality_eval/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                    ← 公共接口 + Evaluator 结构体
│       ├── reader.rs                 ← 读取 LifecycleLog JSON
│       ├── evaluator.rs              ← 逐一评估各维度
│       ├── prompts.rs                ← 各维度 LLM 评估 prompt
│       ├── score.rs                  ← 评分计算 + 加权汇总
│       └── report.rs                 ← 综合报告生成
```

---

## 六、实施排期

| 阶段 | 内容 | 模块 | LLM 调用 | 估计 |
|:----:|------|------|:--------:|:----:|
| 1 | crate 骨架 + reader | reader.rs | 0 | 30min |
| 2 | teacher 维度 | prompts.rs + evaluator.rs | 30 次 | 1h |
| 3 | card 维度 | prompts.rs + evaluator.rs | 30 次 | 1h |
| 4 | plan + review L1 | score.rs | 0 | 30min |
| 5 | report | report.rs | 0 | 30min |
| 6 | 首次全量跑 + 出报告 | — | 60 次 | 30min |

### 顺序策略

先跑 teacher + card（60 次 LLM 调用），因为这是投入产出比最高的：
- 教师质量：直接影响用户学习体验
- 卡片质量：直接影响复习效果
- plan/review 是 L1 无成本，自动附带

Student 维度留到 K12 runner 恢复双 LLM 模式后开启。
