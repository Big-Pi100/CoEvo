# 学习计划创建失败调查

> **调查日期**：2026-05-15
> **问题**：对话中 LLM 回复正常（自然语言），但学习计划未被创建为结构化任务列表，仅存在于对话文本中

---

## TL;DR

**根因：DeepSeek V4 Flash 模型不遵循 `<plan_update>` XML 结构化输出指令，以自然语言输出计划内容而非标签包裹的 JSON。** 后端在 `full_text` 中找不到 `<plan_update>` 标签，`handle_plan_update()` 静默跳过（无日志、无重试、无降级），计划内容永远留在对话文本中，不会写入数据库。

---

## 一、数据流追踪

### 1.1 预期流程（设计）

```
用户: "我想学Python"
  → LLM (chat_system_free.md prompt): "要不要制定计划？"
用户: "好的"
  → LLM 应输出: "没问题！<plan_update>{...JSON...}</plan_update>"
  → ws.rs stream:
      Token: "没问题！"         → 转发给客户端 ✅
      Token: "<plan_update>"   → 检测到 → is_planning=true → 发"planning"事件 ✅
      Token: "{...JSON...}"    → 累积但不转发（planning期间） ✅
      Token: "</plan_update>"  → 累积但不转发 ✅
      Done: full_text          → handle_plan_update() 解析 ✅
        → is_new_plan=true     → upsert_learning_plan() 写入 DB ✅
        → render_plan()        → 生成格式化文本 ✅
        → 发送 done 事件       → 客户端显示计划面板 ✅
```

### 1.2 实际流程（问题）

```
用户: "我想学Python"
  → LLM: "要不要制定计划？"
用户: "好的"
  → LLM 输出: "好的！我来为你制定一个Python学习计划：

              **目标：掌握Python编程**

              ### 阶段一：基础入门
              - 安装Python环境
              - 学习基本语法和数据类型

              ### 阶段二：核心进阶
              ..."

  → ws.rs stream:
      全部 Token 正常转发给客户端 ✅
      Done: full_text → handle_plan_update() 解析 ❌
        → find("<plan_update") → None → 静默跳过
        → final_reply = 原始自然语言文本（未修改）
        → plan_updated = false
        → 数据库无写入 ❌
        → 客户端显示自然语言文本（无计划面板）
```

---

## 二、关键代码分析

### 2.1 解析入口（ws.rs:238）

```rust
let result = crate::plan_handler::handle_plan_update(
    &conn, &final_reply, &chat_req.conversation_id, &chat_req.user_id,
);
```

`final_reply` 是 LLM 的完整回复文本。如果 LLM 未输出 `<plan_update>` 标签，此函数不做任何操作。

### 2.2 解析逻辑（plan_handler.rs:28-80）

```rust
pub fn handle_plan_update(...) -> PlanUpdateResult {
    let mut final_reply = raw_reply.to_string();
    // ...
    if let Some(start) = final_reply.find("<plan_update") {  // ← 关键检查
        // 解析 JSON，创建计划...
    }
    // 找不到标签 → 直接返回原始文本，plan_updated=false
    PlanUpdateResult {
        cleaned_reply: final_reply,  // ← 原始文本，未修改
        is_new_plan: false,
        plan_updated: false,
        plan_json: None,
    }
}
```

**没有任何日志**：找不到 `<plan_update>` 标签时，函数静默返回。开发者无法从日志中判断是"LLM 没输出标签"还是"标签格式错误"。

### 2.3 Prompt 指令（chat_system_free.md:10-13）

```
如果用户同意，**你的回复只需要：**
1. 一句简短的确认（如"好的！"）
2. 直接输出 `<plan_update>` JSON
3. 不要输出计划的具体内容——后端会自动渲染
```

指令本身是清晰的，但 **DeepSeek V4 Flash** 是轻量级模型，对"输出纯 XML+JSON 而非自然语言"这种约束的遵循度不稳定。

### 2.4 模型对比

| 模型 | 结构化输出能力 | 成本 |
|------|--------------|------|
| DeepSeek V4 Flash | ⚠️ 较弱，倾向自然语言 | 低 |
| DeepSeek V3 | ✅ 较好 | 中 |
| DeepSeek R1 | ✅ 最佳（推理链） | 高 |
| Qwen3 Max | ✅ 较好 | 高 |

---

## 三、问题矩阵

| 编号 | 严重度 | 问题 | 位置 |
|------|--------|------|------|
| **P1** | 🔴 P0 | LLM 不遵循 `<plan_update>` 格式，输出自然语言 | 模型行为 |
| **P2** | 🔴 P0 | 解析失败静默，无日志、无重试、无降级 | `plan_handler.rs:40` |
| **P3** | 🟡 P1 | `is_planning` 期间 Tokens 不转发，客户端只看到骨架 | `ws.rs:211-212` |
| **P4** | 🟡 P1 | plan_update JSON 解析失败时静默（`serde_json::from_str` 的 `Err` 被忽略） | `plan_handler.rs:48` |

---

## 四、修复方案

### 4.1 紧急修复：增加降级解析

当找不到 `<plan_update>` 标签时，尝试从自然语言中提取计划结构：

```rust
// plan_handler.rs handle_plan_update() 末尾
if !plan_updated {
    // 降级：尝试解析自然语言中的 Markdown 计划结构
    if let Some(plan) = extract_plan_from_markdown(raw_reply) {
        plan_json = Some(plan.clone());
        upsert_learning_plan(conn, user_id, conversation_id, &plan);
        is_new_plan = true;
        plan_updated = true;
        tracing::warn!("Plan extracted from markdown fallback for user {}", user_id);
    }
}
```

Markdown 计划格式通常为：
```
**目标：XXX**
### 阶段一：XXX
- 任务1：XXX
- 任务2：XXX
```

### 4.2 核心修复：优化 Prompt + 增加诊断日志

**Prompt 优化**（chat_system_free.md）——强调格式的强制性：

```markdown
如果用户同意，你的回复 **必须** 按照以下格式（不要输出任何其他内容）：

一句话确认
<plan_update>
{...完整 JSON...}
</plan_update>

**重要**：后端只识别 `<plan_update>` 标签内的 JSON。如果你以自然语言输出计划，计划将无法被创建！
```

**增加诊断日志**（plan_handler.rs）：

```rust
if let Some(start) = final_reply.find("<plan_update") {
    // ... existing parsing ...
} else {
    // 诊断：检查是否 LLM 输出了类似计划的内容但没有用标签包裹
    let looks_like_plan = raw_reply.contains("###") && raw_reply.contains("阶段");
    if looks_like_plan {
        tracing::warn!(
            "Plan-like content detected without <plan_update> tags. Raw (first 200 chars): {}...",
            &raw_reply[..raw_reply.len().min(200)]
        );
    }
}
```

### 4.3 中期优化：换用更适合的模型

| 方案 | 改动 | 成本 |
|------|------|------|
| DeepSeek V3 | 改 `.env` 中 `LLM_MODEL` | 约 2x 成本 |
| Qwen3 Max | 改 `.env` 中 `LLM_BASE_URL` + `LLM_MODEL` | 约 3x 成本 |
| 使用 DeepSeek 的 JSON Mode | 请求加 `response_format: {type: "json_object"}` | API 改动 |

### 4.4 长期优化：前端辅助创建

如果后端始终无法可靠地从 LLM 回复中提取计划，可以：
1. 前端检测到 LLM 输出计划内容但无 plan_updated 事件
2. 弹出"手动创建计划"界面
3. 用户确认后将计划写入后端

---

## 五、验证方法

修复后可通过以下方式验证：

```bash
# 1. 查看后端日志确认 plan_update 标签是否被检测到
RUST_LOG=debug cargo run

# 2. 手动检测 LLM 输出
# 在聊天中输入"我想学Python入门"，同意制定计划
# 查看后端日志是否有 "Learning plan created" 
# 或 "Plan-like content detected without <plan_update> tags"

# 3. 检查数据库
sqlite3 data/coevo.db "SELECT goal, plan_json FROM learning_plans;"
```

---

*报告版本: V1.0*
*调查者: 齐活林 (Delivery Director)*
