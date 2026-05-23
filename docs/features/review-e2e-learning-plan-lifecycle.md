# 审查报告: `e2e_learning_plan_lifecycle.rs`

**审查日期**: 2026-05-15  
**审查人**: 齐活林 (Delivery Director)  
**审查对象**: `backend/crates/api_server/tests/e2e_learning_plan_lifecycle.rs`  
**依赖源码**: `plan_handler.rs`, `routes.rs`, `db_pool.rs`, `auth.rs`

---

## 1. 总体结论

**能否实现设计意图: 基本能，但有重要缺口。**

该测试的设计意图（文件注释所述）是验证学习计划的 8 个生命周期阶段 + 3 种成就触发。从结构上看覆盖了 FREE→STRUCTURED 转换、任务推进、阶段完成等核心路径。但与实际 `routes.rs` 中的业务流程存在关键差异，且缺少 bronze 成就验证，使得"全面分析"这一目标打了折扣。

---

## 2. 与源码对齐分析

### 2.1 核心调用链一致性

| 测试调用 | 对应源码 | 一致性 |
|---------|---------|--------|
| `plan_handler::handle_plan_update()` | `routes.rs:269` + `ws.rs` | ✅ 完全一致 |
| `plan_handler::render_plan()` | `routes.rs:278` | ✅ 完全一致 |
| `plan_handler::achievement_exists()` | `routes.rs:291` | ✅ 完全一致 |
| `plan_handler::write_achievement()` | `routes.rs:292` | ✅ 完全一致 |
| `db_pool::init()` + `db_pool::get_conn()` | 多处 | ✅ 完全一致 |
| `auth::hash_password()` | `routes.rs:82` | ✅ 完全一致 |

### 2.2 关键差异点

#### ❌ 差异 1: `build_plan_context()` 未覆盖 system_prompt 选择

```rust
// 测试: 仅返回 (mode, plan_context)
fn build_plan_context() -> (String, String) { ... }

// 源码 routes.rs:226 — 同时选择 system_prompt 模板:
(templates.chat_system_structured.clone(), ctx)   // structured 模式
(templates.chat_system_free.clone(), String::new()) // free 模式
```

**影响**: 测试仅验证了 `plan_context` 内容，但未验证 FREE 与 STRUCTURED 状态下 `system_prompt` 模板选择的正确性。这是 context 注入的完整语义的一半。

#### ❌ 差异 2: 成就触发逻辑是手动复制，非真实整合适配

```rust
// 测试 Phase 6 (lines 542-563): 手动遍历 stages、构建 key、去重写入
// 测试 Phase 7 (lines 666-694): 完全重复的成就检测代码
//
// 源码 routes.rs (lines 283-304): 在 handle_plan_update 返回后自动触发
```

**问题**:
- 测试中的成就代码与 `routes.rs:283-304` 是**相同逻辑的独立副本**，而非调用同一函数
- 如果 `routes.rs` 的成就逻辑变更（如新增 bronze、修改 key 生成规则），测试不会失败
- Phase 6 和 Phase 7 各自包含一份成就检测代码块（DRY 违反），维护成本双倍

#### ⚠️ 差异 3: 成就触发时机不同

```
源码: handle_plan_update() → 判断 plan_updated && !is_new_plan → 逐个检查 stage["status"]=="done" → 写成就
测试: handle_plan_update() → 重新 get_plan_from_db() → 手动遍历 → 写成就
```

测试多了一次 DB 读取。虽然结果一致，但不是端到端验证——源码中成就触发和 plan 更新在同一个 `conn` 上下文中，测试则是分离的。

---

## 3. 设计覆盖缺口

### 3.1 ❌ Bronze 成就: 声称覆盖但实际缺失

文件注释第 7 行:
> `4. 验证成就系统的触发 (bronze/silver/gold)`

实际测试:
- Silver: ✅ 2 个以上 (Phase 6, 7)
- Gold: ✅ 1 个以上 (Phase 7)
- **Bronze: ❌ 无任何验证**

`routes.rs` 中的成就检测逻辑（lines 283-304）本身也只检查 `done` 的 stage → silver，和 `all done` → gold，没有 bronze 逻辑。因此 bronze 成就的触发机制在**整个系统中都未实现**——这是一个产品缺口，不仅是测试缺口。

### 3.2 ⚠️ 全部阶段完成后 system_prompt 状态

测试 Phase 9 (lines 750-759) 正确指出了"所有阶段完成后 context 无当前阶段"的现象，但**未验证此时系统会选择什么 system_prompt**。

源码 `routes.rs:204-232` 中，只要 DB 中存在 `mode='structured'` 的计划，就会使用 `chat_system_structured` 模板——即使所有阶段都已完成。这可能不是最优设计，应有一个 "COMPLETED" 状态或回退到 FREE 模式的 system_prompt。

### 3.3 ⚠️ 缺少的边界场景

| 场景 | 是否覆盖 | 备注 |
|------|---------|------|
| 截断的 `<plan_update` (无闭合标签) | ✅ Phase 10a | |
| 无 `<plan_update>` 的普通回复 | ✅ Phase 10b | |
| 空 stages 的 render_plan | ✅ Phase 10c | |
| 重复创建 (upsert) | ✅ Phase 10d | |
| 无学习计划时发送 `current_task_complete: true` | ❌ | 会触发 `None?` (apply_plan_mutations:134) |
| `next_stage_suggestion` 不匹配任何 stage | ❌ | 模糊匹配可能产生意外结果 |
| 并发写入同一 plan (连接池竞态) | ❌ | 仅用 SQLite 单写锁，但未测试 |
| assessment 中 `passed: false` | ❌ | 仅测试了 4/4 通过 |
| `mode='deleted'` 的计划过滤 | ❌ | 未测试 upsert 的 `mode != 'deleted'` 条件 |
| 超过 2 轮的成就去重 | ❌ | `achievement_exists` 在手动代码中调用，但未验证 INSERT OR IGNORE 本身 |

### 3.4 ❌ Assessment 评估链路断裂 — 用户回答与 LLM 判断无因果关联

当前 Phase 5 的结构：

```
用户回答（硬编码）──→ LLM评估结果（硬编码）──→ handle_plan_update() ──→ 断言
     │                      │
     └─ 无因果关联 ─────────┘
```

**问题**: 两个硬编码字符串之间没有任何因果关系。测试成立的前提是"我们假设 LLM 会输出这个 JSON"，而不是"给定这个用户回答，系统应该生成正确的评估"。这使得以下场景无法测试：

| 场景 | 当前可测 |
|------|---------|
| 用户完美回答 → 4/4 通过 | ✅ (仅此一种) |
| 用户部分回答 → 2/4 通过，2 盲点 | ❌ |
| 用户答错 → 0/4 不通过，任务不回退 | ❌ |
| assessment JSON 格式变更 → 测试无感知 | ❌ |

**改进方案**: 引入 `AssessmentSimulator` — 接收用户回答文本，与任务知识点关键词匹配，自动生成 assessment JSON。这建立了回答→评估的因果链，并解锁多场景测试。

---

## 4. 代码质量问题

### 4.1 结构化问题

1. **Phase 6/7 成就代码重复**: 两处几乎相同的成就检测逻辑 (lines 542-563 和 lines 666-694)。应抽取为辅助函数。

2. **`plan_update_*` 字符串硬编码**: 每个 Phase 的 `<plan_update>` JSON 都是内联字符串。建议使用一个 `fn make_plan_update(json!({...}))` 工厂函数，减少转义和格式错误风险。

3. **连接获取不明确**: 多处使用 `let conn = api_server::db_pool::get_conn();` 后立即 drop。在 Phase 6/7 的成就代码中，存在嵌套的 conn 获取，使得连接生命周期难以追踪。

### 4.2 可维护性问题

4. **`build_plan_context()` 是 routes.rs context 构建逻辑的副本**:
   - 测试中的 context 构建逻辑（lines 196-234）与 `routes.rs:194-226` 几乎逐行一致
   - 如果 routes.rs 的 context 格式变更（如新增字段、调整缩进），测试需手动同步
   - **建议**: 将 context 构建逻辑提取为 `plan_handler` 的公共函数，测试和路由共同调用

5. **hardcoded 中文字符串断言遍布全文**:
   ```rust
   assert!(ctx.contains("AI基础知识"));    // line 376
   assert!(ctx.contains("监督学习概念"));  // line 379
   ```
   这些字符串与 Phase 1 的 `plan_update_new` JSON 内容耦合。如果修改测试数据，需同步修改所有断言。

### 4.3 潜在运行时问题

6. **`db_pool::init()` 使用静态 `OnceLock`**:
   - `setup_test_db()` 调用 `db_pool::init()`，内部使用 `OnceLock::set()` 
   - 如果同二进制内有其他测试也调用了 `init()`，会 panic
   - **当前安全**：集成测试（`tests/` 目录）每个文件编译为独立二进制
   - **风险**：如果有朝一日将测试移到 `#[cfg(test)]` 模块内，会出现竞态

7. **测试 DB 未清理** (line 858):
   - `// let _ = fs::remove_file(TEST_DB_PATH);` 被注释
   - 连续运行会在残留数据上执行，但 `setup_test_db()` 第一步会删除旧文件，所以没有实际问题

---

## 5. 改进建议

### 5.1 高优先级

| # | 建议 | 理由 |
|---|------|------|
| 1 | **补充 bronze 成就测试** | 设计文档声称覆盖，实际缺失。需先在 `plan_handler` 或 `routes.rs` 中实现 bronze 触发逻辑（如单任务完成 → bronze），再添加测试 |
| 2 | **将 context 构建逻辑提取为公共函数** | 消除测试与 routes.rs 之间的代码重复，确保测试不会因源码 format 变更而"假通过" |
| 3 | **将成就检测抽取为测试辅助函数** | Phase 6 和 Phase 7 中重复的成就代码合并为一个 `fn check_and_record_achievements()` |

### 5.2 中优先级

| # | 建议 | 理由 |
|---|------|------|
| 4 | **添加 system_prompt 选择验证** | 扩展 `build_plan_context()` 返回三元组 `(mode, system_prompt_key, plan_context)` |
| 5 | **测试全部阶段完成后的 system_prompt 行为** | 明确"全部 done 仍用 structured 模板"是否为预期行为，添加断言 |
| 6 | **添加 `passed: false` 的 assessment 场景** | 验证考核不通过时任务不回退为 done、阶段不推进 |
| 7 | **添加 `mode='deleted'` 计划不干扰 upsert 的测试** | 验证软删除计划的正确隔离 |

### 5.3 低优先级

| # | 建议 | 理由 |
|---|------|------|
| 8 | **抽取 `make_plan_update()` 工厂函数** | 减少内联 JSON 字符串的转义维护负担 |
| 9 | **添加对 `cleaned_reply` 内容的断言** | 目前只有 Phase 10b 验证了 cleaned_reply，其他阶段未检查 |
| 10 | **启用测试 DB 清理或使用临时目录** | 避免残留文件 |

---

## 6. 总结矩阵

| 维度 | 评分 | 说明 |
|------|------|------|
| 核心路径覆盖 | ⭐⭐⭐⭐ | FREE→STRUCTURED、任务推进、阶段完成均覆盖 |
| 成就系统覆盖 | ⭐⭐ | Silver/Gold 有，Bronze 缺失；触发逻辑是副本 |
| 边界场景覆盖 | ⭐⭐⭐ | 截断/空回复/upsert 覆盖；**改进后新增 AssessmentSimulator 多场景** |
| 与源码一致性 | ⭐⭐⭐ | 调用公共 API 一致，context 构建是副本 |
| 代码质量 | ⭐⭐⭐⭐ | Phase 5 改进后消除硬编码评估；成就检测去重 |
| **综合评价** | ⭐⭐⭐⭐ | **Phase 1 对齐后: 完整覆盖 FREE 引导→结构化→考核→成就→边界** |

---

## 9. Live LLM 测试对齐 (2026-05-15 更新)

### 9.1 Phase 1 对话流程对齐

**改进前（模拟测试）**:
- 2-turn: 用户一句话 → LLM 直接出 plan_update
- 缺少 FREE 模式"主动引导"的验证

**改进后（4-turn 对话）**:
1. Turn 1 (user): "我想系统地学习AI基础知识" — 模糊意图
2. Turn 2 (assistant): LLM 追问背景/偏好 — FREE 模式主动引导
3. Turn 3 (user): 补充 Python 基础、数学背景、学习偏好
4. Turn 4 (assistant/plan_update): 基于用户信息创建计划

验证点:
- Turn 2 的普通追问不会被误解析为 plan_update (`plan_updated=false`)
- Turn 1 后仍为 FREE 模式
- Turn 4 正确触发 FREE→STRUCTURED 转换

### 9.2 Live LLM 测试成就检测去重

**改进前**: `chat_turn()` 和合成回退各有一份成就检测代码（~30 行 × 2 = **重复代码**）

**改进后**: 抽取 `record_stage_achievements(conn, plan_json)` 公共函数，两处均调用同一函数

**Gold key 修复**: `pj["goal"].as_str().unwrap_or("")` → `plan_json.get("goal").unwrap_or("领域")`，防止 upsert 移除 goal 后生成空 key `_gold`

### 9.3 两测试对齐现状

| 项目 | 模拟测试 | Live 测试 | routes.rs | ws.rs |
|------|---------|-----------|-----------|-------|
| Phase 1 对话流程 | 4-turn (FREE引导) | 1-turn (直接请求) | - | - |
| 成就检测 | `record_stage_achievements()` | `record_stage_achievements()` | - | - |
| Gold key 兜底 | `.unwrap_or("领域")` | `.unwrap_or("领域")` | - | - |
| `build_plan_context()` | ✅ thin wrapper → plan_handler | ✅ thin wrapper → plan_handler | ✅ 调用 plan_handler | ✅ 调用 plan_handler |
| Bronze 成就 | 未实现 | 未实现 | 未实现 | 未实现 |

**关键改进 (2026-05-15):** `build_plan_context()` 已从 4 个内联副本（routes.rs, ws.rs, 两个测试）统一抽取为 `plan_handler::build_plan_context()` 单一权威实现。调用方只需 3 行即可获取 `(mode, plan_context)`。

---

## 附录: 快速修复清单

```rust
// 1. ✅ 抽取 context 构建为公共函数 (plan_handler.rs) — 已完成
pub fn build_plan_context(conn: &rusqlite::Connection, conversation_id: &str) 
    -> (String, String)  // (mode, plan_context)
{ ... }
// routes.rs, ws.rs, 两个测试均改用此函数

// 2. ✅ 测试辅助: 成就检测 (已实现 — record_stage_achievements)
fn record_stage_achievements(conn: &rusqlite::Connection, plan_json: &serde_json::Value) { ... }

// 3. ✅ 测试辅助: plan_update JSON 构建 (已实现 — make_plan_update)
fn make_plan_update(pre_text: &str, fields: &serde_json::Value) -> String {
    format!("{}\n\n<plan_update>\n{}\n</plan_update>", 
        pre_text, serde_json::to_string_pretty(&fields).unwrap())
}

// 4. ✅ 测试核心: AssessmentSimulator (已实现)
// 接收用户回答 → 关键词匹配 → 生成 assessment JSON
// 支持 perfect pass / partial pass / fail 三场景
struct AssessmentSimulator { ... }

// 5. ⚠️ Bronze 成就 — 等待源码支持
// 6. ⚠️ AssessmentSimulator 词边界 — 用 contains(), 已知局限性
```
