# Pipeline 1（测试线）完善计划

> 目标：使测试线产出的 LifecycleLog 能支撑评估线全部 5 个维度的评估
> 当前产出可用维度：教师 ✅ 卡片 ✅ 计划 ✅
> 待补充维度：学生 ❌ 复习 ❌

---

## 一、当前缺口

```
Pipeline 1 产出                          Pipeline 2 需要
══════════════════════════════           ══════════════════════════════
llm_calls[]（教师回答 + 学生回答）        teacher → 教师质量  ✅ 已够
plan_events（plan_update 记录）          plan → 计划执行    ✅ 已够
card_events（提取的 candidates）          card → 卡片质量    ✅ 已够
─────────────────────────────            ─────────────────────────────
学生回答：4 句固定模板                    student → 学生质量 ❌ 不够
无卡片创建 / 无复习提交                   review → 复习流程 ❌ 不够
```

### 缺口 1：学生模拟——4 句固定回答不够

当前 K12 runner 的学生回答：
```
Turn 1: "好的，请开始教我当前学习计划的第一个任务吧。"
Turn 2: "我理解了刚才讲解的内容，请继续举例。"
Turn 3: "例子我明白了，请出题考考我。"
Turn 4: "我答对了！请继续下一个任务。"
```

问题：
- 从不犯错（真实学生会答错）
- 从不追问（真实学生会问"为什么"）
- 语言太正式（真实学生用语更口语化）
- 每轮长度一样（真实学生回答长度有变化）

评估线的 student 维度需要这些指标：错误率、语域自然度、追问率、多样性。

**修复方案**：恢复双 LLM 模式，用第二个 LLM 实时生成学生回答。  
（管线 E2E 测试已经有这个模式——`generate_student_answer()` 函数，直接复用。）

### 缺口 2：review 流程——测试未触发复习

当前 K12 runner 逻辑：
```
提取 candidates → 创建卡片 → 停止
                              ↑
                         没有 submit_review
```

评估线的 review 维度需要：制卡成功率、FSRS state 迁移、review_log 写入。

**修复方案**：在 cards_created > 0 后补充 2-3 轮 submit_review（rating=1/3/4）。

---

## 二、完善任务列表

### Task A：恢复双 LLM 学生模拟

**目标**：K12 runner 的 progression 阶段用第二个 LLM 生成学生回答，替换固定模板。

**改动位置**：`backend/src/bin/e2e_k12_runner.rs`

**改动内容**：

1. 在 `run_single_test` 中创建第二个 `LlmCaller`（学生 LLM）
2. 每轮教学：先等教师 LLM 回复 → 把教师回复发给学生 LLM → 用学生 LLM 回复作为下一轮用户输入
3. 记录学生 LLM 调用到 `LifecycleLog.llm_calls`
4. 添加 `student_prompt` 字段（可选）用于 student 评估

**学生 LLM prompt：**
```
你正在学习{subject}，你的水平是{grade_band}。
当前 AI 教师正在教你，请作为学生自然回应。

规则：
- 你是真实学生，不是完美的——有时会犯错、会记错
- 用口语化表达，简短回答（20-80 字）
- 偶尔追问"为什么""能再举个例子吗"
- 小测时如果不会就瞎猜一个（不要故意全对）
- 回答不要每次都一模一样

教师最新消息：
{teacher_reply}

你的回答：
```

**集成方式**：在 `run_single_test` 中把固定 `student_responses` 数组替换为动态生成。

**影响**：
- 每个用例增加 4 次 LLM 调用（30 用例 → +120 次，共 ~330 次）
- 单用例耗时从 ~1min → ~2min（翻倍）
- 第一个就绪后 student 维度可评估

**可用复用**：管线 E2E 测试的 `generate_student_answer()` 函数。

### Task B：补充 review 流程

**目标**：candidates 提取 → 卡片创建 → submit_review 2-3 轮。

**改动位置**：`backend/src/bin/e2e_k12_runner.rs`（Phase D 之后）

**改动内容**：

```rust
// 当前：提取后只创建卡片
if log.cards_created > 0 {
    // 新增：复习 2 轮
    // 第 1 轮：rating=3（正确）
    // 第 2 轮：rating=1（遗忘）
    // 验证 reps/lapses/review_log
}
```

**影响**：
- 零额外 LLM 调用（review 是纯数据库操作）
- 单用例增加 ~0s
- 立即解锁 review 维度评估

### Task C：修复 30 测试内存问题

**目标**：`cargo run --bin e2e-k12-runner` 能一次跑完 30 个用例。

**方案**：用 release 模式跑（当前 debug 模式在 Windows 下有栈溢出）。  
或增加 `--batch` 参数内部自动分批。

**记录到文档**：已知限制。

### Task D：管线 E2E 补充 chemistry/biology domain

**目标**：`e2e-pipeline-test` 的 Phase 1 覆盖 5 个 domain（当前只有 math/language/general）。

**改动位置**：`backend/src/bin/e2e_pipeline_test.rs`

**改动内容**：在 `ALL_PHASES` 或 `create_plan` 的 domain 列表中添加 chemistry/biology。

---

## 三、实施顺序

| 优先级 | 任务 | 估计 | 解锁的评估维度 |
|:------:|------|:----:|:--------------:|
| **P0** | **B: 补充 review 流程** | 0.5h | 复习 ✅ |
| **P1** | **A: 恢复双 LLM 学生模拟** | 2h | 学生 ✅ |
| P2 | D: 管线 E2E 补充 domain | 0.5h | 测试覆盖 |
| P3 | C: 修复内存问题 | 1h | 运行稳定性 |

### 实施顺序决策

**先做 P0（review）**：改动最小（0.5h），无额外 LLM 成本，立即解锁一个评估维度。

**再做 P1（学生模拟）**：改动最大（2h），但这是评估框架五维中最核心的一维——**教学是师生对话**，没有好的学生模拟，教师质量也测不真实。

**P2/D（domain 补充）**：放在后面，不影响评估线的运行。

**P3/C（内存修复）**：低优先级，因为 release 模式和分批跑已经是可行的 workaround。

---

## 四、完成标准

| 检查项 | 标准 |
|--------|------|
| 学生模拟 | K12 测试中学生 LLM 回答包含错误、追问、口语化表达 |
| review 流程 | 每用例至少 2 轮 submit_review，card_memory 有 state 变化 |
| Pipeline 1 → 2 对接 | `e2e-quality-eval --input <dir> --all` 产出 5 维度评分 |
| 内存稳定 | release 模式下 30 用例一次跑完不崩溃 |
