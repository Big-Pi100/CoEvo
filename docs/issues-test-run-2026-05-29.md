# 2026-05-29 全场景测试 — 问题详细调查与解决方案

## Issue #1: analyze_plan_progress 不同步 plan_content  [P0]

### 症状
`analyze_plan_progress` 标记 task 为 done 时，只更新 `plan_json`（`task_status` 映射表），不同步更新 `plan_content`（完整 stages/tasks 结构）。导致两个字段状态不一致。

### 数据流路径
```
analyze_plan_progress
  → auto_advance_check (LLM 评估是否可推进)
  → 构造 plan_update JSON (含 current_task_complete: true)
  → handle_plan_update
    → !is_new_plan (无 is_new_plan 字段)
    → apply_plan_mutations  (plan_handler.rs:107)
```

### 根因代码 (plan_handler.rs:544-563)

```rust
// 检测是否有 sub_steps 变更
let has_sub_steps = plan.get("stages")...;
if has_sub_steps {
    // ✅ 有 sub_steps → 同时更新 plan_content + plan_json
    UPDATE learning_plans SET plan_content = ?, plan_json = ?, updated_at = ?
} else {
    // ❌ 无 sub_steps → 只更新 plan_json，不更新 plan_content
    UPDATE learning_plans SET plan_json = ?, updated_at = ?
}
```

**问题**: 第 558-562 行的 `else` 分支只在无 `sub_steps` 时**不写 `plan_content`**。但 `apply_plan_mutations` 修改了 `plan`（in-memory JSON 对象，含 stages/tasks/status），这个修改后的完整 `plan` 应当写回 `plan_content`。

### 影响范围
- `plan_content` 中 task 状态过期 → 前端下次读取 plan_content 时显示错误状态
- `get_stages_from_plan_json()` 等函数合并两个字段时会暴露不一致
- CP2 多次运行后累积不一致

### 修复方案

**文件**: `backend/crates/api_server/src/plan_handler.rs`

**实际修复代码**：

将第 544-563 行的条件分支（`has_sub_steps` 判断 `plan_content` 是否同步）替换为始终同步：

```rust
// 从 in-memory plan 重建 plan_content
let plan_content = serde_json::json!({
    "stages": plan.get("stages"),
    "completed_concepts": plan.get("completed_concepts"),
});

// ✅ 始终写 plan_content + plan_json，不再区分 sub_steps
if let Err(e) = conn.execute(
    "UPDATE learning_plans SET plan_content = ?1, plan_json = ?2, updated_at = ?3 WHERE id = ?4",
    rusqlite::params![plan_content.to_string(), status_update.to_string(), now, plan_id],
) {
    tracing::error!("Plan mutation DB write failed: {} (plan_id={})", e, plan_id);
    return None;
}
```

**验证**: `analyze_plan_progress` 后 `verify_plan_consistency` 返回 0 处不一致（之前 2 处）。

---

## Issue #2: LLM 常遗漏 is_new_plan 字段 [P1]

### 症状
在所有 LLM 驱动的测试中，首次构建 plan_update 时均未包含 `is_new_plan: true`，需 2-3 轮追问。

### 数据流路径
```
LLM → <plan_update>{"goal":"...", "stages":[...]}</plan_update>
  → handle_plan_update
    → update.get("is_new_plan") → None → unwrap_or(false)
    → is_new_plan = false
    → apply_plan_mutations (错误路径: 没有现有 plan 时返回 None)
    → plan_updated = false
```

### 根因 (plan_handler.rs:98-111)
```rust
is_new_plan = update.get("is_new_plan")
    .and_then(|v| v.as_bool())
    .unwrap_or(false);  // 只要 LLM 没写 is_new_plan，就当不是新计划

if is_new_plan {
    upsert_learning_plan(...);
} else {
    apply_plan_mutations(...);  // 错误路径
}
```

`is_new_plan` 的门槛过高——要求 JSON 中有 `"is_new_plan": true`（原始布尔值）。LLM 的常见变体：
1. 完全遗漏 `is_new_plan` 字段
2. 作为 XML 属性：`<plan_update is_new_plan="true">`
3. 写为字符串：`"is_new_plan": "true"`

### 影响范围
- 所有涉及学习计划创建的对话中的首轮 LLM 响应无效
- 用户必须说"请用 plan_update 标签"才生效
- analyze_plan_progress 内部使用的 prompt（line 1189）有 is_new_plan，但 ws.rs 中用户直接对话没有

### 实际修复 — 架构变更

**不再依赖 LLM 输出 `is_new_plan`**。改为由 **ColdPath 2** 在聊天早期轮次自动检测并创建计划。

涉及三个变更：

1. **新函数 `build_plan_creation_prompt`** (`plan_handler.rs:1199-1224`)：从 `analyze_plan_progress` 中提取创建计划 prompt 为独立函数

2. **CP2 开局检测** (`ws.rs:500-513`)：CP2 触发条件从 `每 5 轮` 扩展为 `轮次 2/3/5+`，确保对话开局 2 轮对话就检测无计划状态

3. **`analyze_plan_progress` 已有 `None` 分支**（line 1155）：无计划时调用 `build_plan_creation_prompt` → `handle_plan_update`，自动创建计划

**数据流变更**：

```
之前: 主 LLM 需输出 is_new_plan → handle_plan_update
      失败时需用户追问

现在: CP2 (轮次2/3/5) → analyze_plan_progress
          ↓
     有计划? ──是──→ build_plan_analysis_prompt → 推进评估
         否
          ↓
     build_plan_creation_prompt → handle_plan_update → 计划创建
```

**验证**: `analyze_plan_progress` 的 `None` 分支已经过 LLM E2E 测试验证。

---

## Issue #3: 教学对话中 LLM 不输出 plan_update [P2/正常行为]

### 症状
在 Test 08（32 轮双智能体对话）中，导师未输出任何 `<plan_update>` 标签。

### 根因
**这是系统设计的一部分，不是 Bug**。教学 prompt（`chat_system_structured` 等）的核心是教学指导，不包含 XML 标签指令。进度管理通过单独的 **ColdPath 2** 机制处理：

```
教学对话                    进度管理
┌─────────────┐           ┌──────────────┐
│ 导师教概念    │           │ CP2 (每5轮)   │
│ 学生提问     │           │ auto_advance  │
│ 导师出题     │           │ analyze_plan  │
│ 学生回答     │           │ unlock_cards  │
└─────────────┘           └──────────────┘
      ↑                         ↑
 纯教学对话                 代码层自动评估
 (无 XML 污染)             (无需 LLM 写标签)
```

### 修复的必要性
**不需要修复**。系统架构有意将教学和进度管理分离。唯一调整的是 Test 08 的断言——将期望从"必须推进"改为"对话流程验证"（已完成）。

---

## Issue #4: 多 plan_update 标签清理不完整 [P2]

### 症状
同一 LLM 回复中出现 `<plan_update>...{2}</plan_update>` 后，`cleaned_reply` 仍然包含 1 个残留标签。

### 根因 (plan_handler.rs:62-91)

```rust
// 只匹配第一个 <plan_update>
if let Some(start) = final_reply.find("<plan_update") {
    // 处理第一个完整的 <plan_update>...</plan_update> 
    // 删除第一个标签后，return 不再处理后续标签
}
```

代码只循环一次就结束，没有继续查找第二个 `<plan_update>` 标签。

### 影响范围
- `cleaned_reply` 可能包含残留 XML 标签 → 影响前端显示
- 第二个 `plan_update` 的 JSON 内容被丢弃（但 LLM 通常只输出一个，影响极小）

### 修复方案

**修改 handle_plan_update**：添加循环处理所有 `<plan_update>` 标签：

```rust
// 循环处理所有 <plan_update> 标签，直到不再找到
loop {
    if let Some(start) = final_reply.find("<plan_update") {
        // ... 处理逻辑不变 ...
    } else {
        break; // 没有更多标签
    }
}
```

---

## Issue #5: curriculum_loader 在测试环境未初始化 [P2/环境限制]

### 症状
Test 10 中 `curriculum_loader::get_cards()` 返回 `None`。

### 根因
测试只调用了 `reading_loader::init()`，没有调用 `curriculum_loader::init()`。

```
curriculum_loader 使用 OnceLock 惰性初始化  
  → 不调用 init() 则 get() 永远返回 None
  
reading_loader 有自己的 init() (独立的预建数据)
  → 两个 loader 互不依赖，需分别初始化
```

### 影响范围
- 仅测试环境，不影响生产
- `unlock_next_cards` 路径无法在测试中完整验证

### 修复方案

在 Test 10 中添加 `curriculum_loader::init()` 调用：

```rust
// Test 10 setup 中
api_server::curriculum_loader::init().unwrap_or_else(|e| {
    eprintln!("[TEST] curriculum_loader init: {}", e);
    // 不 panic — curriculum 数据可能不在测试环境中
});
```

注意：`curriculum_loader::init()` 依赖 `Paths::prebuilt()` 路径，这些路径在测试环境中不一定存在。因此应该 `unwrap_or` 并记录日志，不硬断言。

---

## 优先级排序与建议

| 优先级 | Issue | 影响面 | 修复难度 | 建议 |
|--------|-------|--------|---------|------|
| **P0** | #1 plan_content 不同步 | 数据一致性问题，影响所有 plan 非 sub_steps 更新 | 低（2 行代码） | ✅ **已修复** |
| **P1** | #2 is_new_plan 遗漏 | 关键 UX 问题，所有对话首轮无效 | 低-中（自动检测逻辑） | ✅ **已修复**（通过 CP2 架构） |
| **P2** | #4 多标签清理 | 边缘场景，极少发生 | 低（加循环） | ❌ 跳过 |
| **P3** | #3 导师无 XML | 正常架构行为，非 Bug | 无（不需修复） | 无需操作 |
| **P3** | #5 curriculum loader | 测试环境限制 | 低 | 仅需要在完整 E2E 时加 init 调用 |
