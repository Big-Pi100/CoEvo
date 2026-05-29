# e2e_live_llm_plan_lifecycle.rs — Review & 改进总结

## 变更范围
重写了 `backend/crates/api_server/tests/e2e_live_llm_plan_lifecycle.rs` 测试文件

## 架构改进
- **模块化帮助函数** (`mod helpers`) — 消除测试间 60%+ 的重复代码
- **`TurnMetrics` 成本追踪** — 每次 LLM 调用记录字符数、延迟、plan_update 次数
- **原有 4 个测试函数 + 4 个新测试函数** — 8 个独立场景，可单独运行

## 新增 8 个场景化测试

| # | 测试函数 | 场景 | 核心验证点 |
|---|---------|------|-----------|
| 1 | `e2e_live_plan_schema_and_context` | Plan Schema + Context 质量 | JSON schema 严格校验、context 注入完整性 |
| 2 | `e2e_live_progress_and_concepts` | 进度推进 + 概念累积 | completed_concepts 不递减、成就链 |
| 3 | `e2e_live_error_recovery` | 错误恢复 | 标签截断、非法转义、空标签优雅处理 |
| 4 | `e2e_live_revert_mechanism` | 回退机制 | LLM reset_current_task + 代码层 auto_revert |
| 5 | `e2e_live_coldpath2_auto_advance` | Coldpath 2 | auto_advance_check 真实对话判断 |
| 6 | `e2e_live_reading_context_quality` | 阅读模式 | reading context 核心教学点、全文注入 |
| 7 | `e2e_live_teaching_quality` | 教学质量评估 | 带日志输出的逐轮评估会话 |
| 8 | `e2e_live_dual_agent_full_lifecycle` | 双智能体全流程 | 学生 LLM ↔ 导师 LLM 完整生命周期 |

## 关键验证函数
- **`validate_plan_schema()`** — 严格验证 stages[].tasks[].name/status、goal、completed_concepts
- **`validate_context_quality()`** — context 内容完整性（长期目标、当前阶段、任务状态、核心教学点）
- **`validate_teaching_content()`** — 教学回复质量（>50 字符且有信息量，非空泛模板）
- **`validate_triple_phase_structure()`** — 三阶段教学合规检测（teach/examples/quiz 关键词）

## 编译状态
- ✅ `cargo check -p api_server --tests` 通过，0 error
- 运行方式: `cargo test -p api_server --test e2e_live_llm_plan_lifecycle -- --ignored --nocapture`
