# 主流程 E2E 测试文档

**文件**: `backend/crates/api_server/tests/e2e_main_lifecycle.rs`

## 用途

这是 CoEvo 项目的**核心验收测试**，验证整个数据流链路在生产代码路径上正确运行。不模拟 WebSocket 层，但所有业务逻辑函数和数据库操作均走生产代码。

## 测试的数据流

```
[测试] 发消息 → cp2_turn()
             ├─ 1. 写入 conversation_turns (保存对话)
             ├─ 2. build_plan_ctx() (读已有计划/空)
             ├─ 3. caller.generate() (调真实 LLM)
             ├─ 4. 写入 conversation_turns (保存回复)
             └─ 5. analyze_turn_progress() (CP2 分析 DB 中全部对话记录)
                    → 检测学习意图 → 创建计划(conversation_plans + user_plan_progress)
                    → 检测通关信号 → 推进 task 状态
[重复 1-5] 3 轮 → 计划创建
[重复 1-5] 4 轮 → 教学对话 + 任务推进

[Phase 3] 调 extract_concepts() ← 生产 CP1 函数
          → 写入 cards 表 (conversation_id 绑定)
          → 写入 card_memory
          → user_plan_progress 验证 (当前 task + in_progress)

[Phase 4] 验证 plan 存在 + 列出全部 task/status + achievements
```

## 各步骤详解

```
Step 1: helpers::setup()
        创建 SQLite DB + users 表 + 对话 test-main-conv

Step 2: cp2_turn("你好，我想学习勾股定理")
  └─ insert_turn("user", msg)                → conversation_turns 新增
  └─ build_plan_ctx()                         → 空（无计划）
  └─ caller.generate(chat_system_free, ...)   → LLM 回复
  └─ insert_turn("assistant", reply)          → conversation_turns 新增
  └─ analyze_turn_progress(TEST_CONV_ID...)   → 读全部 conversation_turns
       CP2 检测到学习意图 → 创建 plan
       → INSERT conversation_plans (goal+plan_content)
       → INSERT user_plan_progress (每个 task 一行)

Step 3-4: 再 cp2_turn 2 次
  （无兜底——CP2 必须在 3 轮内创建计划，否则测试 FAIL）

Step 5-10: 双 LLM 自然对话（最多 6 轮）
  └─ 学生 LLM 扮演困惑/易错的中学生
  └─ 教师 LLM 带计划上下文教学
  └─ 每轮 cp2_turn 返回 TurnDiag（教师 prompt + 输入上下文 + CP2 决策详情）
  └─ 学生只看对话历史，看不到计划结构
  └─ 每轮检查 CP2 是否检测到通关信号 (🎉)

Step 11: Phase 3 — CP1
  └─ 取 conversation_turns 最早 4 条 (前 2 轮对话)
  └─ extract_concepts(user_msg, ai_reply, existing_fronts...) → 生产 CP1
  └─ 记录 CP1 输入上下文（用户消息、教师回复、去重 fronts 数）
  └─ INSERT INTO cards (conversation_id=TEST_CONV_ID)
  └─ INSERT INTO card_memory
  └─ 验证 COUNT(cards WHERE conversation_id=TEST_CONV_ID)
  └─ user_plan_progress 中 status='in_progress' 的 task_key
  └─ 显示当前任务名 + 提取到的概念名

Step 12: Phase 4 — 最终验证
  └─ plan 存在
  └─ 列出所有 task + status
  └─ achievements 列表
  └─ user_plan_progress 行数 > 0

## 诊断信息

每轮 `cp2_turn` 返回 `TurnDiag` 结构体，记录在报告中：

| 字段 | 内容 | 用途 |
|------|------|------|
| `teacher_system_prompt` | 教师 LLM 的 system prompt（截断） | 验证用的 prompt 是否正确（free vs structured） |
| `teacher_input_context` | 发给教师 LLM 的完整上下文（历史+计划） | 确认教师看到了什么 |
| `teacher_reply_truncated` | 教师回复（截断） | 确认教师回复质量 |
| `cp2_detailed_event` | CP2 决策详情 | 为什么 CP2 选择推进或跳过 |

CP1 诊断记录了输入的用户消息、教师回复和去重 fronts 数，方便排查提取结果偏差。
```

## 禁止兜底

> **本测试中不允许任何形式的兜底（fallback）。**

| 场景 | 禁止的做法 | 要求的做法 |
|------|-----------|-----------|
| CP2 未创建计划 | 用 `handle_plan_update` 注入计划 | **直接 FAIL**，暴露 CP2 或 prompt 的问题 |
| 任务未推进 | 直接调 `handle_plan_update` 模拟通关 | **保持原状**，在报告中记录推进状态 |
| 学生卡住 | 硬编码 "请继续下一个任务" 作为回复 | **结束对话**，在报告中记录轮次 |

**理由**：兜底会掩盖真实问题。如果 CP2 检测不到学习信号、教师 LLM 不输出通关、学生 LLM 不会正确回答——这些都是需要修复的真实 Bug，不是可以跳过的测试噪音。

### 例外

唯一允许的"模拟"是 CP1 调用本身（`extract_concepts()` 直接函数调用而非通过 ws.rs spawn）。这是有意的——测试的目标是验证 CP1 概念提取 + 卡片写入 + 绑定逻辑，而非验证 ws.rs 的 WebSocket 生命周期。该例外在文档中有明确标注。

## 运行方式

```bash
cd backend
cargo test -- --ignored e2e_main_lifecycle
```

需要 `DEEPSEEK_API_KEY` 环境变量（后端 `.env` 文件中）。

## 各阶段验证内容

### Phase 1: CP2 驱动计划创建

| 验证项 | 方法 | 断言 |
|--------|------|------|
| CP2 自动创建计划 | 3 轮自然对话让 CP2 检测学习意图 | `plan_created == true` |
| 计划结构完整性 | 读 `plan_content` 的 JSON 结构 | 有 `stages` 和 `goal` |
| 至少 1 个 stage | JSON 数组长度检查 | `stages.len() > 0` |
| 兜底机制 | CP2 未创建时通过 `handle_plan_update` 注入 | `is_new_plan == true` |

### Phase 2: 多轮对话 + 任务推进

| 验证项 | 方法 | 断言 |
|--------|------|------|
| CP2 推进逻辑 | 每轮调用 `analyze_turn_progress` | `cp2_updated` 由 LLM 输出决定 |
| 任务状态累积 | 每 2 轮检查 done 任务数 | 非严格断言（LLM 输出不稳定） |

### Phase 3: CP1 概念提取验证

| 验证项 | 方法 | 断言 |
|--------|------|------|
| CP1 调用 | 取前 2 轮对话，调 `extract_concepts` | 返回 `candidates.len() > 0` |
| 卡片写入 | INSERT INTO cards + card_memory | 写入行数 = 候选概念数 |
| 会话绑定 | 检查 cards.conversation_id | `COUNT(*)==inserted` 且 `conversation_id=TEST_CONV_ID` |
| 去重逻辑 | 再次调用 CP1 + 已有 fronts | 新候选与已有 fronts 的相交判断 |
| card_memory 初始化 | 每张新卡对应一条 card_memory | `state=0,difficulty=0.3,stability=1.0` |

### Phase 4: 最终状态

| 验证项 | 方法 | 断言 |
|--------|------|------|
| 计划存在 | `helpers::get_plan()` | `is_some()` |
| 任务进度 | 从 `task_status` 解析 stages | 输出已完成任务数 |
| 成就触发 | `achievements` 表查询 | 输出所有成就 |
| user_plan_progress | progress 表计数 | `count > 0` |
| 最少 API 调用 | 对话轮次计数 | 由 LLM 调用次数决定 |

## 生产代码覆盖率

| 代码路径 | 是否覆盖 | 说明 |
|---------|---------|------|
| `handle_plan_update` → `upsert_learning_plan` | ✅ | 通过 CP2 或兜底调用 |
| `analyze_turn_progress` (CP2) | ✅ | 每轮对话后自动调用 |
| `build_plan_context` | ✅ | 每轮对话构建 plan_ctx |
| `concept_extractor::extract_concepts` (CP1) | ✅ | Phase 3 直接调用 |
| `fsrs_scheduler` | ❌ | 由 `e2e_card_pipeline` 覆盖 |
| `reading_loader` | ❌ | 由 `e2e_learning_plan_lifecycle` 覆盖 |
| `k12_quiz` | ❌ | 由单独测试覆盖 |
| `routes.rs` API handlers | ❌ | 直接调 business logic |

## 与旧 08 测试的区别

| 维度 | 旧 Test 08 | 新主流程测试 |
|------|-----------|------------|
| 计划创建 | 人工提示 LLM 输出 `<plan_update>` XML | CP2 `analyze_turn_progress` 自动检测 |
| CP1 调用 | 仅在最后跑一次，无 DB 写入验证 | Phase 3 独立验证，检查写入 + 绑定 + 去重 |
| 去重验证 | 无 | 二次调用 + 已有 fronts 对比 |
| 卡片绑定 | 无 | 验证 `conversation_id` 和 `card_type` |
| user_plan_progress | 无 | 最终阶段检查 progress 表 |
| 独立性 | 混在 `e2e_live_llm_plan_lifecycle.rs` 中 | 独立测试文件 |
