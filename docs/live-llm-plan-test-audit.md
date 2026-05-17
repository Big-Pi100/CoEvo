# 真实 LLM 学习计划生命周期测试 · 审计报告

> 日期: 2026-05-17
> 测试文件: `backend/crates/api_server/tests/e2e_live_llm_plan_lifecycle.rs`
> 审查范围: Schema、API 签名、逻辑一致性

---

## 一、总体结论

**测试与当前代码基本匹配，可以直接运行。** 存在 2 处可优化点，不影响正确性。

---

## 二、逐项比对

### 2.1 数据库 Schema ✅

| 表 | 测试 SCHEMA | 生产 main.rs | 差异 |
|----|------------|-------------|------|
| users | id, username, password_hash, streak_days, last_active_date, display_name, created_at | ✅ 一致 | display_name 有 DEFAULT NULL，测试 INSERT 不填即可 |
| tokens | id, user_id, token, created_at | ✅ 一致 | — |
| conversations | id, user_id, turn_count, started_at, learning_plan_id | ✅ 一致 | — |
| conversation_turns | id, conversation_id, role, content, created_at | ✅ 一致 | deleted_at 仅在 conversations 上 |
| learning_plans | id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at | ✅ 一致 | — |
| achievements | id, user_id, achievement_key, name, icon, tier, source, unlocked_at | ✅ 一致 | — |

> ⚠️ 测试未创建 `cards`、`skipped_concepts`、`user_preferences` 表，但 `handle_plan_update` 不访问这些表，无影响。

### 2.2 公共 API 签名 ✅

| 函数 | 测试调用 | 生产定义 | 匹配 |
|------|---------|---------|:--:|
| `plan_handler::handle_plan_update(conn, raw_reply, conv_id, user_id)` | line 304 | line 28 | ✅ |
| `plan_handler::build_plan_context(conn, conv_id)` → `(String, String)` | line 134 | line 484 | ✅ |
| `plan_handler::render_plan(plan)` → `String` | line 309 | line 526 | ✅ |
| `plan_handler::achievement_exists(conn, user_id, key)` → `bool` | line 172 | line 583 | ✅ |
| `plan_handler::write_achievement(conn, user_id, key, name, icon, tier, source)` | line 173 | line 571 | ✅ |
| `auth::hash_password(password)` → `String` | line 80 | pub fn | ✅ |
| `db_pool::init(path)` | line 72 | pub fn | ✅ |
| `db_pool::get_conn()` | line 75 | pub fn | ✅ |
| `prompt_loader::init(dir)` | line 95 | pub fn | ✅ |
| `prompt_loader::get()` | line 272 | pub fn | ✅ |
| `LlmConfig::deepseek_v4_flash(api_key)` | line 361 | line 55 | ✅ |

### 2.3 成就检测逻辑 ⚠️ 微差异

| 维度 | 测试 `record_stage_achievements` | 生产 ws.rs |
|------|------|------|
| 触发条件 | `result.plan_updated` (含新计划) | `result.plan_updated && !result.is_new_plan` |
| 效果 | 新计划中无 done 阶段 → 不写成就 → **功能等价** | 明确排除新计划 |
| gold 检查位置 | for 循环外，一次 | for 循环内，每次 done 都检查 |
| 效果 | 功能等价（每次结果相同） | 冗余但无害 |

> **风险**: 低。当前测试中 Phase1 创建新计划时 0 个 done 阶段，不会误写成就。但如果未来计划创建阶段直接包含 done 任务，测试会误报成就。建议同步 `!is_new_plan` 条件。

### 2.4 对话流模拟 vs 真实 WS

| 维度 | 测试 | 真实生产 | 影响 |
|------|------|---------|------|
| LLM 调用 | `caller.generate()` (同步) | `caller.stream_generate()` (流式) | 测试不覆盖流式路径 |
| plan_update 解析 | 直接调用 `handle_plan_update` | WS handler 内调用 | 测试不覆盖 WS 消息格式 |
| prompt 构建 | 手动拼接 history + plan_ctx | WS handler 内拼接 | 逻辑相同 |
| concept extraction | **不测试** | WS ColdPath 异步提取 | 不影响计划测试 |

---

## 三、已发现待修复问题

### 🟡 P1: 测试成就检测缺少 `!is_new_plan` 条件

**位置**: `e2e_live_llm_plan_lifecycle.rs:308`

**状态**: ✅ 已修复 — 新计划渲染正常，成就仅在 `!is_new_plan` 时检测。

### 🟡 P1: 测试未覆盖流式 LLM 调用路径

测试用 `caller.generate()`，真实生产用 `caller.stream_generate()`。两者行为差异：
- `generate` 返回完整回复，解析在拿到全部文本后
- `stream_generate` 分块返回，ws.rs 在 `done` 事件后对完整 `final_reply` 调用 `handle_plan_update`

**不影响当前测试结果**（plan_update 块在回复末尾，两种方式都能完整捕获），但如果流式解析逻辑变化（如增量解析 plan_update），测试不会捕获。

---

## 四、运行方式

```bash
cd backend
cargo test -p api_server --test e2e_live_llm_plan_lifecycle -- --ignored --nocapture
```

前置条件：`backend/.env` 中已配置 `DEEPSEEK_API_KEY`。预计耗时 3-8 分钟，API 费用 ~$0.02-0.05。

---

## 五、建议

1. **立即执行**: 运行 `e2e_live_llm_plan_lifecycle` 验证当前代码
2. **建议修复**: 在测试中加 `&& !result.is_new_plan` 条件（2 行改动）
3. **不必修复**: 流式调用路径差异 — 测试目标为计划逻辑，非传输层
