# 管线 E2E 测试框架 · 设计文档

> 日期：2026-05-21
> 动机：现有单次 E2E 测试（e2e_live_llm_plan_lifecycle）一次运行耗时过长，且无法拆分复用
> 方案：阶段化 CLI 测试工具，每阶段独立运行、结果持久化、可链式/单独执行

---

## 一、问题分析

### 当前痛点

| 问题 | 影响 |
|------|------|
| 单次 E2E 测试耗时 120s+ | CI 超时被打断，无法获得阶段结果 |
| 测试失败丢失全部进度 | 无法从断点续跑 |
| 无指标记录 | 无法追踪成功率、延迟变化 |
| 只测通用管线 | math / language 管线从未被验证 |
| 无原始 LLM 日志 | prompt 调优缺乏数据支撑 |

### 目标

1. **可拆解**：每个阶段独立可跑，不依赖前序阶段的运行状态
2. **可持久化**：阶段结果写入文件/DB，支持断点续跑
3. **可度量**：每个阶段产出指标（成功率、耗时、计数）
4. **可分析**：保留 LLM 原始请求/响应，支持 prompt 调优

---

## 二、测试阶段设计

```
Phase 0: 环境准备
  ├─ 创建测试 SQLite DB
  ├─ 创建 test user + conversation
  └─ 写入测试配置

Phase 1: 计划创建（路由验证）
  ├─ 发送 "我想学数学" → 验证 domain = "math"
  ├─ 发送 "我想学英语" → 验证 domain = "language"
  ├─ 发送 "我想学历史" → 验证 domain = "" (general)
  ├─ 统计: 每轮 plan_update JSON 中的 domain 匹配率
  └─ 输出: plan_creation_results.json

Phase 2: 计划推进（结构化学习测试）
  ├─ 在已有计划上推进教学
  ├─ 统计: current_task_complete 触发率、阶段推进次数
  ├─ 统计: task_sub_steps 完整性
  ├─ 统计: 考核 assessment 触发率和通过率
  └─ 输出: plan_progression_results.json

Phase 3: 概念提取（管线 prompt 测试）
  ├─ 输入对话内容 → 调用 concept_extractor
  ├─ 统计: 各 domain 的候选概念数量
  ├─ 统计: card_type 分布（vocabulary vs concept）
  ├─ 统计: domain 字段填充率
  └─ 输出: concept_extraction_results.json

Phase 4: 验证策略（验证方式测试）
  ├─ 基于已有卡片提交验证
  ├─ 统计: spelling / ai_dialogue 验证正确率
  └─ 输出: verification_results.json

Phase 5: 报表生成
  ├─ 汇总 Phase 1-4 结果
  ├─ 生成指标表格
  └─ 输出: report_YYYY-MM-DD_HHMMSS.md
```

### 阶段依赖关系

```
Phase 0 (准备)
   │
   ├──→ Phase 1 (计划创建) ──独立可跑──→
   │                                  │
   │    Phase 1 输出: domain 分配      │
   │                                  │
   ├──→ Phase 2 (计划推进) ←──────────┘
   │       依赖 Phase 1 建立的计划
   │
   ├──→ Phase 3 (概念提取) ──独立可跑──→
   │       不需要计划，直接喂对话
   │
   ├──→ Phase 4 (验证策略) ←────────────
   │       依赖 Phase 3 建立的卡片
   │
   └──→ Phase 5 (报表) ←───────────────
            聚合 Phase 1-4 数据
```

---

## 三、数据持久化

### 3.1 测试结果 Schema

每个阶段的结果存为一个 JSON 文件：

```json
{
  "phase": "plan_creation",
  "pipeline_version": "2026-05-21_v2",
  "run_id": "2026-05-21_023000",
  "started_at": "2026-05-21T02:30:00+08:00",
  "completed_at": "2026-05-21T02:31:15+08:00",
  "duration_ms": 75000,
  "status": "passed",
  "metrics": {
    "total_attempts": 3,
    "successful": 3,
    "domain_accuracy": {
      "math": { "expected": "math", "actual": "math", "match": true },
      "language": { "expected": "language", "actual": "language", "match": true },
      "history": { "expected": "", "actual": "", "match": true }
    },
    "avg_plan_creation_ms": 25000
  },
  "llm_logs": [
    {
      "phase": "plan_creation",
      "step": "create_plan_math",
      "system_prompt_preview": "你是一个AI学习助手...",
      "user_message": "我想系统学习数学，从基础开始",
      "raw_llm_response": "...",
      "plan_update_parsed": { "domain": "math", ... },
      "duration_ms": 25000,
      "token_count": null
    }
  ],
  "errors": []
}
```

### 3.2 存储位置

```
docs/test-results/
  ├── YYYY-MM-DD_HHMMSS/
  │   ├── config.json                    ← 测试配置（LLM model, pipelines）
  │   ├── phase-1-plan-creation.json     ← Phase 1 结果
  │   ├── phase-2-plan-progression.json  ← Phase 2 结果
  │   ├── phase-3-concept-extraction.json ← Phase 3 结果
  │   ├── phase-4-verification.json      ← Phase 4 结果
  │   └── report.md                      ← Phase 5 聚合报表
  └── latest/ → YYYY-MM-DD_HHMMSS/      ← symlink 或 copy
```

### 3.3 断点续跑逻辑

```
启动时:
  └─ 检查 docs/test-results/latest/ 是否存在
      ├─ 存在 → 读取 config.json → 检查已完成哪些 phase
      │          └─ 跳过已完成 phase，从下一 phase 继续
      └─ 不存在 → 从头开始
```

---

## 四、CLI 接口设计

### 4.1 命令结构

```bash
# 完整流水线（从 phase 1 到 phase 5）
cargo run --bin e2e-pipeline-test

# 只跑特定阶段
cargo run --bin e2e-pipeline-test -- --phase plan-creation
cargo run --bin e2e-pipeline-test -- --phase concept-extraction

# 从指定阶段开始（跳过之前的）
cargo run --bin e2e-pipeline-test -- --from phase-2

# 只跑特定 domain
cargo run --bin e2e-pipeline-test -- --domain math

# 指定 LLM 模型
cargo run --bin e2e-pipeline-test -- --model deepseek-v4-flash

# 强制重跑（忽略已有结果）
cargo run --bin e2e-pipeline-test -- --force

# 生成报表（不跑测试，只汇总已有结果）
cargo run --bin e2e-pipeline-test -- --report-only
```

### 4.2 退出码

| 退出码 | 含义 |
|:------:|------|
| 0 | 全部通过 |
| 1 | 部分阶段失败 |
| 2 | 严重错误（配置/DB/LLM 不可用） |

---

## 五、指标定义

### 5.1 计划创建指标

| 指标 | 计算方式 | 理想值 |
|------|---------|:------:|
| `domain_accuracy` | 正确 domain 分配数 / 总请求数 | 100% |
| `plan_has_stages` | 有 stages 数组的计划数 / 总计划数 | 100% |
| `avg_stages_per_plan` | 平均 stage 数量 | 3-5 |
| `avg_tasks_per_stage` | 平均 task 数量 | 2-4 |
| `avg_creation_time_ms` | 平均 LLM 响应时间 | < 30s |
| `front_empty_rate` | front 字段为空的卡片占比 | 0% |

### 5.2 计划推进指标

| 指标 | 计算方式 | 理想值 |
|------|---------|:------:|
| `task_complete_rate` | 成功推进的任务数 / 尝试推进次数 | ≥ 80% |
| `stage_advance_rate` | 成功推进的阶段数 / 尝试次数 | ≥ 80% |
| `assessment_trigger_rate` | 触发考核的对话轮次 / 总轮次 | ≥ 50% |
| `assessment_pass_rate` | assessment.passed=true 次数 / 总 assessment 次数 | ≥ 60% |
| `sub_steps_completeness` | task_sub_steps 全部 done 后才 complete 的比例 | 100% |

### 5.3 概念提取指标

| 指标 | 计算方式 | 理想值 |
|------|---------|:------:|
| `candidates_per_turn` | 平均每轮提取的候选概念数 | 1-5 |
| `card_type_vocabulary_ratio` | vocabulary 卡片占比（英语对话时） | ≥ 50% |
| `card_type_concept_ratio` | concept 卡片占比（通用对话时） | ≥ 80% |
| `domain_fill_rate` | domain 字段不为空的卡片占比 | ≥ 90% |
| `source_sentence_rate` | 有 source_sentence 的卡片占比 | ≥ 80% |
| `llm_timeout_rate` | LLM 调用超时率 | < 5% |

### 5.4 验证策略指标

| 指标 | 计算方式 | 理想值 |
|------|---------|:------:|
| `spelling_positive_accuracy` | 正确输入验证通过率 | 100% |
| `spelling_negative_accuracy` | 错误输入验证拒绝率 | 100% |
| `ai_dialogue_pass_rate` | AI 快问快答通过率 | ≥ 60% |

---

## 六、与现有评估工具的关系

```
现有 evaluate.rs:
  评估概念提取 prompt 的精准率/召回率
  7 个预定义用例 × 3 个变体
  输出 precision_recall 指标

新 e2e-pipeline-test:
  评估完整管线的端到端运行
  支持多 domain / 多 phase
  输出成功率 / 延迟 / 各阶段指标

关系：互补而非替代
  评估 prompt 质量 → evaluate.rs
  评估管线集成 → e2e-pipeline-test
```

---

## 七、实施步骤

### Step 1: 测试框架基础设施（半天）

1. `backend/src/bin/e2e_pipeline_test.rs` — 主入口 + CLI 参数解析
2. `backend/crates/api_server/src/e2e_runner.rs` — 共享测试逻辑
3. 测试结果目录管理 + JSON 读写

### Step 2: Phase 1 — 计划创建（半天）

1. 多 domain 计划创建测试（math / language / general）
2. domain 字段验证
3. plan_json 结构完整性检查

### Step 3: Phase 2 — 计划推进（半天）

1. 基于已有计划的多轮对话测试
2. task_complete / stage_advance 验证
3. assessment 触发验证

### Step 4: Phase 3 — 概念提取（半天）

1. 多 domain 对话的概念提取
2. card_type / domain 字段正确性验证
3. 与 evaluate.rs 结果的对照

### Step 5: Phase 4 + 5 — 验证 + 报表（半天）

1. 验证策略分类测试
2. 报表生成

---

*文档状态：V1 · 提案*
*下一步：实现 Step 1 — 测试框架基础设施*
