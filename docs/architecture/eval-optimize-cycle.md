# 教学质量评估与 Prompt 优化循环

## 目标

构建完整的"测试→日志→评审→优化"闭环，实现可量化的教学质量持续优化。

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  E2E 测试  │ → │ 上下文日志  │ → │ 规则检查器 │ → │ LLM 评审  │ → │ Prompt 优化 │
│ (双智能体) │    │ (JSON 证据) │    │ (静态分析) │    │ (6 维度)   │    │ (迭代改进) │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

## 一、测试改造（e2e_live_llm_plan_lifecycle.rs 增强）

### 新增：`e2e_live_teaching_quality` 测试函数

覆盖管线：语文阅读(g7-9, g1-2)、K12结构化(数学·g7-9)

### 日志输出

```
data/eval_runs/{run_id}/
├── meta.json                   # 管线、学段、预期任务列表、时间、token 统计
├── turn_001/
│   ├── user.txt                # 学生消息
│   ├── system_prompt.txt       # 注入的 system prompt
│   ├── plan_context.txt        # build_plan_context 输出（含 reading 卡）
│   ├── llm_reply_raw.txt       # LLM 原始回复
│   ├── plan_state.json         # 处理后 plan_json（task_status）
│   └── llm_metadata.json       # prompt_tokens、completion_tokens、latency_ms
├── turn_002/ ...
├── precheck.json               # 规则检查器输出（状态变更、卡片命中、回复长度）
└── aggregate.json              # 全局指标汇总
```

### 关键数据采集点

| 采集点 | 数据 | 用途 |
|:------|:-----|:-----|
| `build_plan_context()` 输出 | 注入 LLM 的全部 context | 检查 context 完整性 |
| plan_json 前后对比 | task_status 变更 | 规则检查器输入 |
| LLM 原始回复 | 完整 assistant 消息 | 评审教学质量 |
| 学生回复 | 完整 user 消息 | 评审交互质量 |
| prompt 内容 | system_prompt 全文 | 检查 prompt 注入 |
| token 消耗 | prompt/completion tokens | 成本 + 回复长度预警 |

## 二、评审架构

### 评审流程（两阶段）

```
阶段 1 — 规则检查器（Python，离线）
  输入: data/eval_runs/{run_id}/
  输出: precheck.json
  内容:
  - 对比每轮 plan_state.json，检测 task_status 变更（谁→pending→done）
  - TK 匹配教师回复命中 reading 卡关键词的次数
  - 统计各轮回复长度，超出学段建议范围（g1-2 >500, g7-9 >2000）时标记
  - 检测 reading_update / plan_update 标签的出现轮次

阶段 2 — LLM 评审（DeepSeek V4 Flash，temperature=0，CoT）
  输入: precheck.json + data/eval_runs/{run_id}/
  输出: quality_report_{run_id}.md
  流程:
  1. 读取 meta.json 确定管线 + 学段
  2. 逐轮阅读 llm_reply_raw.txt 和 plan_context.txt
  3. 输出每轮每个维度的评分 + 原文证据
  4. 聚合所有轮次 → 维度总分 + 高频缺陷模式
```

### 6 维度（推进合规为门禁）

| 维度 | 制 | 说明 |
|:----|:--|:-----|
| **推进合规** | 门禁 🔴 | 若 task_status 无任何变化，直接判定不通过。<60 分不参与总分平均，强制修复 |
| **教学点覆盖** | L2 | focus 是否全程覆盖，extra_points 引入顺序 |
| **流程执行** | L2 | 引文→精读→赏析→主旨→巩固 5 步 |
| **卡片利用** | L2 | 引用卡片中原文/赏析/手法 |
| **交互质量** | L2 | 学生追问质量和教师回应 |
| **学段适应性** | L2 | 基准 70，超出预期(+)，偏低龄扣分 |

### 学段适应性评分标准

| 学段 | 认知特征 | 基准要求 | 加分项 | 扣分项 |
|:----|:---------|:---------|:-------|:-------|
| g1-2 | 具体运算前期 | 短句、重复、游戏化、多感官 | 韵律感强、互动式 | 抽象术语、长复合句 |
| g3-4 | 逻辑思维萌芽 | 半结构化、有引导分析 | 适度抽象但举例充分 | 跳过铺垫给结论 |
| g5-6 | 初步抽象 | 独立赏析、比较分析 | 引导自主发现 | 超纲术语(如"解构") |
| g7-9 | 形式运算初期 | 正式赏析、手法分析 | 多角度独立解读 | 语言过于幼稚或过于学术 |
| g10-12 | 形式运算期 | 批判性阅读、深度思辨 | 跨文本比较 | 缺乏挑战性 |

允许抽象层级示例：g7-9 允许"意象"、"铺垫"、"对比"；禁止"解构主义"、"互文性"、"能指/所指"。

### 评审输出格式

```markdown
# 教学质量评审报告 (语文·g7-9)

## 概览
- 轮次: 8 | 已完成任务: 2/145
- 推进合规门禁: ✅ 通过（task 状态有变更）
- 平均回复长度: 1280 chars | 总 token: 45K

## 维度评分

| 维度 | 评分 | 评判 | 最高缺陷轮次 |
|:----|:---:|:-----|:------------|
| 教学点覆盖 | 85/100 | ✅ focus 覆盖到位 | turn_03 |
| 流程执行 | 72/100 | ⚠️ 巩固阶段跳过 | turn_02, turn_05 |
| 卡片利用 | 90/100 | ✅ 多次引用原句 | — |
| 交互质量 | 78/100 | ✅ 有深度追问 | turn_04 |
| 推进合规 | 门禁:通过 | ✅ 2次 reading_update 合规 | — |
| 学段适应性 | 82/100 | ⚠️ 少量超过认知范围 | turn_06 |

## 关键发现
1. 🔴 [P0] 巩固阶段_skiped_2次 — prompt 未强调教学流程完整性
2. [P1] 学段_术语越界_turn_06 — 出现"象征主义"（g7-9 课标范围内，但应铺垫）

## 规则检查器摘要
- task 状态变更: 春→done ✅, 济南的冬天→in_progress ✅
- reading_update 轮次: 2✅, 5(缺失)⚠️
- 卡片关键词命中: 比喻×8, 拟人×5, 排比×3
- 回复长度预警: g1-2 轮次 3>500 字符 ❌
```

## 三、实施顺序

### Step 1：新增 e2e 日志测试函数（当前）
`e2e_live_llm_plan_lifecycle.rs` 新增 `e2e_live_teaching_quality`，复用现有工具函数，增加日志写入逻辑。

### Step 2：实现规则检查器
`scripts/eval/precheck.py` — 静态分析 plan_state 变更、TK 命中、回复长度。

### Step 3：实现 LLM 评审脚本
`scripts/eval/quality_review.py` — CoT 评审 + 证据链 + 6 维度门禁。

### Step 4：首次运行 + Prompt 优化
跑完整测试，出报告，根据发现优化 prompt。

### Step 5：回溯对比 + 自动化
`run_eval_cycle.py` 加 `--compare` 模式。

### Step 6：数据完整性审查（数据完整性审查）

**问题**：当前 `reading_plans/chinese.json` 中 g1-2（小学低年级）仅有 116 个 task，但仅一年级上册就有约 22 篇课文 + 拼音学习课程，数据存在大量缺失。

**目标**：全面检查每学段每阶段 task 的完整性，对照实际统编教材目录，补全缺失内容。

**执行方式**：

1. **联网搜索**各学段统编教材目录
   - 一年级上册：拼音课程（6 个单元）+ 课文（约 22 篇）
   - 一年级下册：课文（约 21 篇）
   - 二年级上下册：每册约 25-28 篇
   - 确认实际篇目与 task 列表的差异

2. **比对 chinese.json** 中的 task 列表，标记缺失篇目

3. **补充机制**：
   - 缺失的课文 → 用 `build_full_reading_plan.py` 脚本添加 stage + task
   - 缺失的卡片 → 调用 LLM 批量生成（参考 `add_primary_reading_plan.py`）
   - 拼音课程 → 作为 `nursery_rhyme` 或 `reading_first` 模式加入

4. **验证**：补全后重新跑 `e2e_live_teaching_quality` 验证管线不崩

**优先级**：P0 — 数据不完整会导致评估结果失真，无法判断是 prompt 问题还是数据缺失的问题。
