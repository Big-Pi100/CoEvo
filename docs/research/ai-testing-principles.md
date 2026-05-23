# AI 驱动的开发测试设计原则

> 日期：2026-05-21
> 来源：CoEvo 管线架构 + E2E 测试框架实践经验
> 适用：LLM 作为核心组件的应用测试

---

## 原则一：用真实 LLM，不用 Mock

**任何时候，测试 LLM 驱动的功能必须使用真实 LLM 调用。**

Mock 会隐藏以下真实问题：

```
❌ Mock 测试通过 → 上线崩溃
   └── LLM 输出的 JSON 格式与预期不符
   └── LLM 忽略了 prompt 中的某个要求
   └── LLM 返回了超长文本导致截断错误
   └── LLM 在特定 prompt 下产生幻觉
```

**例外**：纯单元测试（不涉及 LLM 行为，如数据处理、序列化）。

```
测试金字塔（传统）          测试金字塔（AI 应用）
  单元测试 (多)               单元测试 (中)
  集成测试 (中)               Prompt 评估 (多)
  E2E 测试 (少)               真实 LLM 管线测试 (核心)
```

---

## 原则二：测试必须可拆解、可续跑

**单次 E2E 测试不应超过 2 分钟。超过的必须拆分为独立阶段。**

```
坏：
  一个 300 行的 #[tokio::test] 覆盖从头到尾的完整流程
  失败一次全部重来
  每次运行耗 5 分钟

好：
  Phase 1: 计划创建 ← 独立可跑，结果写入 JSON
  Phase 2: 计划推进 ← 依赖 Phase 1 结果，读取 JSON
  Phase 3: 报表     ← 聚合 Phase 1-2
  --phase, --from, --force 参数控制执行粒度
```

**关键实践**：
- 每阶段结果持久化到文件（JSON），包含状态、指标、原始 LLM 日志
- 支持断点续跑：启动时检查已完成阶段，跳过
- 每个阶段有独立的判定标准（不依赖上一阶段的假设）

---

## 原则三：绝不假通过

**测试必须验证实际行为，不能仅检查"没有抛出异常"。**

```
// ❌ 假通过
let status = if errors.is_empty() { Passed } else { Failed };

// ✅ 真实通过
let has_meaningful_behavior = conversations > 0 && plan_updates > 0;
let status = if has_meaningful_behavior { Passed } else {
    errors.push("LLM 未产生 plan_update：prompt 或流程有问题");
    Failed
};
```

**每一行统计数据都应当被检查**，不检查的数据就没有意义：

| 统计量 | 检查方式 |
|--------|---------|
| `plan_updates` | 必须 > 0 |
| `task_completions` | 记录但不强制（分阶段学习可不触发） |
| `conversations` | 必须 > 0 |
| `errors` | 必须 < 总轮次数 |

---

## 原则四：双 LLM 模拟交互式流程

**当被测系统涉及多轮对话（教学、考核、调试等），需要用两个 LLM 分别模拟双方角色。**

```
教师 LLM（被测系统）
  ├── 输出教学内容
  ├── 输出 plan_update JSON
  └── 输出考核题目
        ↓
学生 LLM（模拟用户）
  ├── 实时阅读教师的最新消息
  ├── 根据上下文生成自然回答
  └── 有时候会出错（验证纠错能力）
```

**好处**：
- 避免硬编码学生回答（太完美或太机械）
- 自动适配教师的不同教学风格
- 覆盖更广泛的教学路径（学生可能理解对或错）
- 测试结果更接近真实使用场景

---

## 原则五：保留一切原始日志

**每次 LLM 调用都要保存完整的输入输出，用于 prompt 调优和问题排查。**

```
每次 LLM 调用记录：
  ├── system_prompt（前 200 字预览）
  ├── user_message（完整）
  ├── raw_llm_response（前 3000 字预览）
  ├── duration_ms
  └── domain / step / phase 元数据
```

**这样做的原因**：
- Prompt 调优需要知道"LLM 实际看到了什么"
- Bug 复现需要知道"LLM 实际输出了什么"
- 回归对比需要"同一个 prompt 在不同时间的结果差异"
- 多轮对话的问题往往在历史中埋藏，需要完整的对话上下文

---

## 原则六：Prompt 即代码

**Prompt 是应用程序代码的一部分，必须像代码一样管理。**

```
prompts/
  ├── chat_system.md          ← 通用管线（兜底）
  ├── concept_extract.md      ← 通用概念提取
  │
  pipelines/
    ├── math/prompts/
    │   └── concept_extract.md  ← 数学专用（公式+LaTeX）
    └── language/prompts/
        └── concept_extract.md  ← 语言专用（词汇+语法）
```

**管理规范**：
- Prompt 文件纳入版本控制（git）
- 每次修改 prompt 后必须运行对应的 E2E 测试
- Prompt 变更日志记录在测试报告中（pipeline_version 字段）
- 不存在的 prompt 文件自动回退到通用版本（零成本兼容）

---

## 原则七：定义可度量的 KPI

**每个测试阶段必须有明确的指标基线，不能只有通过/不通过。**

| 测试阶段 | KPI | 理想值 | 告警线 |
|---------|-----|:------:|:------:|
| 计划创建 | domain 准确率 | 100% | < 80% |
| 计划创建 | plan 有 stages 占比 | 100% | < 80% |
| 计划创建 | 平均创建耗时 | < 30s | > 60s |
| 计划推进 | plan_update 触发率 | ≥ 1 次/5轮 | 0 次 |
| 概念提取 | 候选概念数 | 1-5/轮 | 0 |
| 概念提取 | domain 字段填充率 | ≥ 90% | < 60% |
| 验证策略 | 正确输入通过率 | 100% | < 80% |

**作用**：
- 量化 LLM 行为变化（模型更新可能影响输出质量）
- 提示 prompt 退化（添加内容可能让 LLM 忽略其他要求）
- 辅助容量规划（LLM API 延迟和成本估算）

---

## 原则八：管线隔离，共享基础设施

**每个场景（domain）有独立的 prompt 和验证策略，但共享核心学习基础设施。**

```
共享（不变）:
  FSRS 调度 / 复习队列 / 卡片数据库表 / 对话流

独立（按 domain）:
  System prompt / 概念提取 prompt / 验证策略 / 卡片 Schema 扩展

路由层:
  learning_plans.domain → pipeline_router.resolve(domain) → 加载对应管线
```

**好处**：
- 新增场景 = 建目录 + 写 prompt + 注册管线
- 修改一个场景的 prompt 不影响其他场景
- 不需要 if-else 地狱

---

## 应用示例

CoEvo 管线测试遵循以上原则的实现：

```
cargo run --bin e2e-pipeline-test               # 完整流水线
cargo run --bin e2e-pipeline-test -- --phase plan-creation  # 单阶段
cargo run --bin e2e-pipeline-test -- --from phase-2         # 从 Phase 2 续跑
```

结果存储在:
```
  backend/docs/test-results/<run_id>/
    ├── config.json          ← 运行配置（支持断点续跑）
    ├── phase-*.json         ← 每阶段结果（含完整 LLM 日志）
    └── report.md            ← 聚合报表（含等级）
```

---

## 原则九：分级通过标准

**测试结果按 A/B/C/D/F 五级评定，只有全 A 才算完全通过。**

### 等级定义

| 等级 | 含义 | 后续处理 |
|:----:|------|---------|
| **A** | 完全符合设计预期 — pipeline prompt 正确路由 + 字段 100% 对齐 | 可发布 |
| **B** | 功能正确但有轻微偏差 — 部分字段不对齐，不影响主要功能 | 需人工评估，可发布 |
| **C** | 兜底机制触发 — LLM 提取路径未走通但 word_bank/通用路径成功 | 需修复，延迟发布 |
| **D** | 兜底部分生效 — 只有少量有效输出，功能勉强可用 | 需修复 |
| **F** | 彻底失败 — 无有效输出 | 阻断发布 |

### 各阶段等级判定逻辑

```
concept-extraction:
  A = 有 candidates + domain 正确率 ≥ 50% (LLM 路径成功)
  C = 有 candidates 但 domain 不对 (仅 word_bank 匹配)
  F = 无 candidates

progression:
  A = 有教学对话 + 有 plan_update
  B = 有教学对话但无 plan_update (LLM 行为差异)
  F = 无教学对话

plan-creation:
  A = domain 准确率 3/3
  C = domain 准确率 1/3 ~ 2/3
  F = 0/3

review-flow:
  A = reps 递增 + lapses 递增 + review_log 记录 (全覆盖)
  D = 仅部分指标通过
  F = 全部失败
```

### 实现

`PhaseResult` 结构体中 `grade: Option<Grade>` 字段在每次 phase 执行后由 `resolve_grade()` 自动判定。

```rust
pub fn resolve_grade(phase, status, metrics, errors) -> Grade {
    match status {
        Failed => Grade::F,
        Passed => {
            match phase {
                "concept-extraction" => {
                    if total > 0 && domain_ok { Grade::A }
                    else if total > 0 { Grade::C }
                    else { Grade::D }
                }
                "progression-history" | "progression-language" | "progression-math" => {
                    if plan_updates > 0 { Grade::A } else { Grade::B }
                }
                "plan-creation" => {
                    if "3/3" { Grade::A } else if "1/3"~"2/3" { Grade::C } else { Grade::D }
                }
                "review-flow" => {
                    if reps && lapses && logs { Grade::A }
                    else if reps || lapses { Grade::D }
                    else { Grade::F }
                }
                _ => Grade::C
            }
        }
    }
}
```

**`all_passed = true` 要求所有 phase 的 grade == A**。任何 B/C/D 都会导致 CI 警告或阻断。
