# 测试覆盖度扩展计划

当前状态：核心链路已通，缺口集中在科目/学段扩展、概念卡验证和差异化复习。

## 缺口总览

```
覆盖度层级              当前状态
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
核心链路 (P0)          ████████████████████████████████ 已完成
  ├── 计划生命周期       ✅ 01-05, 07-08
  ├── 错误恢复           ✅ 03
  ├── 卡片导入           ✅ 10, 11-Phase2
  └── 复习流             ✅ 11-Phase3

科目扩展 (P1)          ████████░░░░░░░░░░░░░░░░░░░░░░  ~25%
  ├── 语文阅读 5 学段    🟡 g1-2+g7-9 已覆盖, g3-4/g5-6/g10-12 待补
  ├── 结构化 14 科目     ❌ 仅测通用逻辑, 未跑质量评估
  └── Free 模式          ❌

深度测试 (P2)          ██████░░░░░░░░░░░░░░░░░░░░░░░░  ~20%
  ├── 概念卡 (ColdPath 1) ❌
  ├── verify + judge 验证 ❌
  └── 差异化复习          ❌

边界测试 (P3)          ██░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ~5%
  ├── 多轮 FSRS          ❌
  ├── verification=fail  ❌
  └── CP1+CP2 竞态       ❌
```

## Phase 1: 科目扩展 (P1, 预期 1-2 天)

### 1.1 语文阅读补齐 (4 个缺口)

现状：`run_eval_session` 已参数化，只需在 `e2e_live_11_teaching_quality` 的 matrix 中增加：

```python
# 当前 (2 sessions):
- (reading, chinese, g1-2)
- (reading, chinese, g7-9)

# 目标 (5 sessions):
- (reading, chinese, g1-2)
- (reading, chinese, g3-4)
- (reading, chinese, g5-6)
- (reading, chinese, g7-9)
- (reading, chinese, g10-12)
```

chinese.json 的 `reading_plans` 包含全部 5 个 grade_band，直接可用。

**工作量**: 修改 Test 11 测试矩阵 → 约 5 行代码
**风险**: 低，`run_eval_session` 已参数化
**耗时**: 新增 3 个 session × ~3 分钟/个 ≈ +10 分钟测试时间

### 1.2 结构化模式质量评估 (14 科目)

需要新增 `run_eval_session_structured()` 或复用现有框架。结构化模式不走 `reading_loader`，而是：

```
1. 用户随机选一个 K12 主题 (从 plan JSON 取 stage/task)
2. 导师用 `chat_system_structured` prompt 教学
3. CP2 (`analyze_plan_progress`) 管理推进
4. Phase 2+3 用同一套卡片/复习验证
```

**可选子集**（不必全 14 科同时跑）:
- MVP: 数学 (math.json, 80 tasks, g3-4) + 物理 (physics.json, 103 tasks, g7-9)
- 覆盖不同学段：数学(g3-4) + 物理(g7-9) + 政治(g10-12)
- 全量：14 科

**工作量**: 
- 新增 `run_eval_session_structured()` ≈ 60 行
- 与 reading 模式共享 Phase 2+3 逻辑
- 选择 3 个代表性科目做 MVP

**风险**: 中 — 结构化模式的学生 LLM prompt 需要新建（与阅读模式不同）

### 1.3 Free 模式质量评估

最简单——不创建计划，直接让师生自由对话 N 轮，然后检查 `cards` 表和概念提取。

**工作量**: 新增 `run_eval_session_free()` ≈ 30 行
**风险**: 低

---

## Phase 2: 深度验证 (P2, 预期 2-3 天)

### 2.1 概念卡验证 (ColdPath 1)

ColdPath 1 在 ws.rs 中通过 `tokio::spawn` + channel 异步运行。直接调用 `extract_concepts()` 函数即可：

```rust
let result = chat_engine::concept_extractor::extract_concepts(
    &user_id, &user_msg, &ai_reply,
    &existing_fronts, &skipped_fronts, &config,
    &history, &domain,
).await;
```

需要：
- 在 Phase 2 增加概念卡计数（当前 Phase 2 已有 concept 类型计数）
- 在 Phase 1 对话结束后，直接调用 `extract_concepts()` 查看提取结果
- 验证提取的概念是否写入了 `cards` 表

**工作量**: 新增 Phase 2 子步骤 ≈ 30 行
**风险**: 低，直接函数调用，不依赖 WS

### 2.2 verify + judge 验证

当前 Phase 3 只测了 `submit_review`。可以补上：

```rust
// 手动构造 verify 和 judge 的 LLM prompt
let prompt = quiz_generate.replace("{front}", &front).replace("{back}", &back);
let questions = caller.generate("", &prompt).await?;
// 模拟学生回答
let answers = simulate_student_answers(&questions);
// 调用 judge
let result = judge_llm(&questions, &answers).await?;
```

**工作量**: 新增 Phase 3 子步骤 ≈ 60 行 + 学生 LLM 调用
**风险**: 中 — LLM 输出格式不稳定，需要 robust 解析

### 2.3 多轮 FSRS 复习

当前只测了单轮 0→1。可以扩展为 3 轮：

```
Round 1: submit_review(good) → state 0→1
Round 2: get_due() → submit_review(easy) → state 1→2  
Round 3: get_due() → submit_review(hard) → state 2→1 (regression)
```

**工作量**: 新增 Phase 3 循环 ≈ 40 行
**风险**: 低

---

## Phase 3: 边界场景 (P3, 预期 1 天)

### 3.1 verification=fail 场景

Phase 3 当前只测 pass 路径。增加 fail 路径验证：

```
submit_review(rating=1, verification="auto/fail")
  → card_memory: lapses+1, state→0 (return to New)
  → reps SHOULD still increment (failed but still attempted)
```

### 3.2 ColdPath 1 + CP2 竞态测试

模拟概念提取过程中 CP2 触发的场景，验证竞态控制：

```rust
// 并发触发
let cp1 = extract_concepts(...);
let cp2 = analyze_plan_progress(...);
let (r1, r2) = tokio::join!(cp1, cp2);
// 验证 cards 表 + plan_json 无冲突
```

---

## 实施路线图

```
优先级    阶段              预期耗时    依赖关系
──────────────────────────────────────────────────────────
P1    Phase 1.1: 语文 5 学段    2h     无
P1    Phase 1.2: 结构化 3 科   4-6h    无
P1    Phase 1.3: Free 模式     2h     无
──────────────────────────────────────────────────────────
P2    Phase 2.1: 概念卡验证     2h     Phase 1.1 可选
P2    Phase 2.2: verify+judge   4h     Phase 1.3 可选
P2    Phase 2.3: 多轮 FSRS      1h     无
──────────────────────────────────────────────────────────
P3    Phase 3.1: fail 路径测试  1h     Phase 2.2
P3    Phase 3.2: CP1+CP2 竞态  3h     全部前置
```

## 实测状态 (2026-05-30)

| 测试 | 场景 | 状态 | 耗时 |
|------|------|:----:|:----:|
| e2e_live_13 | Free 模式 (无计划对话) | ✅ 通过 | 45s |
| e2e_live_14 | 概念卡提取 (ColdPath 1) | ✅ 通过 | 3.5s |
| e2e_live_15 | 多轮 FSRS + fail 路径 | ✅ 通过 | 0.8s |

### 待实现
- Phase 2.2: verify + judge 验证
- Phase 3.2: CP1 + CP2 竞态测试
| e2e_live_16 | verify + judge 复习流 | ✅ 通过 | 12s |
| e2e_live_17 | CP1 + CP2 竞态测试 | ✅ 通过 | 4.9s |

**全部 17 个测试场景完成。** 路线图所有计划缺口已补全。
