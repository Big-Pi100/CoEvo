# LLM 调用链路问题排查与修复 — 2026-06-25

## 概述

本次修复覆盖了 CoEvo 后端的 LLM 调用链路全部关键节点，涉及 5 个文件、10+ 处改动。修复前计划创建成功率约为 0%，修复后可稳定创建 81 章规模的大计划。

---

## 问题一：SSE 流式解析导致内容重复/截断

### 根因

`llm_caller.rs` 中新增的 `stream_history_inner()` 方法的 SSE 帧解析逻辑存在 bug。与经过验证的 `stream_generate_inner()` 不同，`stream_history_inner` **每次新 chunk 到达时重新解析整个 buffer**，而非按 `\n\n` 帧分割并移除已处理部分。

```rust
// ❌ Buggy: 每次新 chunk 重新遍历整个 buffer
buffer.extend_from_slice(&chunk);
let text = std::str::from_utf8(&buffer).unwrap_or_default();
for line in text.lines() {
    // 已处理过的行又被处理一遍，内容重复追加
}

// ✅ 正确: 按 \n\n 分割 SSE 帧，每帧只处理一次
while let Some(pos) = buffer.windows(2).position(|w| w == b"\n\n") {
    let block = buffer[..pos + 2].to_vec();
    buffer = buffer[pos + 2..].to_vec();  // 处理完从 buffer 移除
    ...
}
```

### 表现

| 场景 | 效果 | 原因 |
|:-----|:-----|:-----|
| 大量 chunk 快速到达 | 回复内容重复膨胀（如 1027 字 → 79855 字） | buffer 反复追加已读行 |
| chunk 到达时序不同 | 回复内容被截断（如 3820 字 → 208 字） | buffer 状态错乱导致提前终止 |

### 修复

`stream_history_inner` 的 SSE 解析改为与 `stream_generate_inner` 一致的按帧分割逻辑。

### 涉及文件

- `backend/crates/chat_engine/src/llm_caller.rs` — `stream_history_inner()` 方法

---

## 问题二：对话历史截断策略导致全部历史丢失

### 根因

`ws.rs` 中的滑动窗口截断逻辑（在 role-based 消息结构中）从头开始累加字符数，如果**第一条（最新的）消息就超过 `max_chars`**，全部历史被丢弃。

```rust
// ❌ Buggy: 第一条消息超限 → 全部丢弃
let next = char_total + content.len();
if next > max_chars { break; }  // char_total=0, content_len=5094 > max_chars=5000
```

日志表现为：
```
HISTORY_DEBUG: STOP by max_chars: char_total=0, next=5094, max_chars=5000
HISTORY_DEBUG: included 0 history turns (0 chars)
```

### 修复一：滑动窗口算法

改为先算**总字数**，从最旧的开始丢弃直到总字数 <= `max_chars`，同时受 `max_turns` 约束。

```rust
// ✅ 先算总字数，从旧到新丢弃
let total_chars: usize = context.iter().map(|(_, c)| c.len()).sum();
let start = if total_chars > max_chars {
    let mut acc = 0usize;
    context.iter().position(|(_, c)| { acc += c.len(); acc > max_chars }).unwrap_or(0) + 1
} else { 0 };
let keep_from = std::cmp::max(start, context.len().saturating_sub(max_turns));
```

### 修复二：DB 配置旧值覆盖代码默认值

`app_config_cache` 默认 `max_chars=20000`，但 DB 里有 `INSERT OR IGNORE` 写入的旧值 `5000`，代码默认值无法生效。

- 修复 `INSERT OR IGNORE` → `INSERT OR REPLACE`
- DB 直接 UPDATE 为 `20000`

### 涉及文件

- `backend/crates/api_server/src/ws.rs` — 滑动窗口截断逻辑
- `backend/crates/api_server/src/app_config_cache.rs` — 配置写入策略

---

## 问题三：CP2 阻塞用户消息 + 计划创建超时

### 根因

`ws.rs` 的 CP2 spawn 使用 `cp2_done.notified().await` **无限等待**，CP2 执行计划创建时 LLM 调用耗时过长，导致用户消息被永久阻塞。

### 修复

`cp2_done.notified()` 改为带超时的等待（500ms），超时后放弃等待让用户继续发消息。

### 涉及文件

- `backend/crates/api_server/src/ws.rs` — CP2 阻塞等待逻辑

---

## 问题四：HTTP 客户端 30s 超时对长输入请求不足

### 根因

`llm_caller.rs` 全局 `http_client()` 使用 `.timeout(Duration::from_secs(30))`，计划创建的 prompt 有 10000+ 字，LLM 需要 30s+ 时间消化上下文并开始输出第一个 token，客户端提前断开连接。

```
日志:
LLM request (non-history): model=deepseek-v4-flash, user_chars=11330
(30 秒后)
WARN LLM stream_history attempt 1 failed: ApiError("Stream decode failed (HTTP unknown): ... Raw buffer: 0 bytes")
```

### 修复

新增 `long_http_client()`（300s 超时），仅 `stream_generate_inner`（即 `generate_streamed`）使用。主聊天的 `stream_history_inner` 仍用 30s 超时的普通客户端。

### 涉及文件

- `backend/crates/chat_engine/src/llm_caller.rs` — 新增 `long_http_client()` 函数

---

## 问题五：plan_marker prompt 使用双花括号导致信号解析失败

### 根因

`prompts/plan/general/signal/signal.md` 中的 JSON 输出格式示例使用了**双花括号** `{{"has_task": false}}`。LLM 按示例格式输出后，代码按单花括号解析永远失败。

```markdown
// ❌ 双花括号（Tera 模板转义没有被正确处理）
{{"has_task": false}}
```

### 修复

改为单花括号。

### 涉及文件

- `backend/prompts/plan/general/signal/signal.md`

---

## 问题六：热路径 `**goal` 标记大小写不匹配

### 根因

`ws.rs` 的热路径检测使用 `final_reply.contains("**goal")`（全小写），但 `plan-marker.md` prompt 中输出的标记是大写开头：`**Goal学习计划创建✅ 已完成`。大小写不匹配导致热路径永远不触发。

### 修复

检测改为大小写不敏感：`final_reply.to_lowercase().contains("**goal")`

### 涉及文件

- `backend/crates/api_server/src/ws.rs`

---

## 问题七：force_plan_creation 使用非流式调用

### 根因

`plan_handler.rs` 的 `force_plan_creation()` 在 `generate_streamed()` 可用后仍使用 `caller.generate("", &prompt)`（非流式），与 `generate_streamed` 不一致，导致 API 拒收。

### 修复

`force_plan_creation` 改为调用 `generate_streamed`。

### 涉及文件

- `backend/crates/api_server/src/plan_handler.rs` — `force_plan_creation()` 函数

---

## 问题八：plan creation prompt 中 task name 输出格式

### 根因

`prompts/format/plan/creation.md` 中的 name 格式要求过于模糊（"name必须是有完整语义的概念"），LLM 直接复制对话历史中的章节编号作为 task name（如 `"第38章"`、`"德经第1章（王弼第38章）"`）。

### 修复

明确要求：
- name 必须回答"学什么"（如"勾股定理"、"道可道非常道"），不是"在哪里"
- **禁止**出现序号、章节编号、书目名、页码范围
- 不知道标题时用自己的知识提炼

### 涉及文件

- `backend/prompts/format/plan/creation.md`

---

## 问题九：plan creation prompt 中 JSON 输出模板的双花括号

### 说明

观察 `prompts/format/plan/creation.md` 第 12 行的 JSON 示例：
```
{{"is_new_plan": true, "goal": "...", ...}}
```

`{{ }}` 是 Tera 模板引擎的转义写法，实际发送给 LLM 时会渲染为单花括号 `{ }`。这本身不是 bug，但如果未来改用其他模板引擎或不支持 Tera 转义的渲染方式时需要留意。

**当前状态**: 正常运行，暂不需要修复。

---

## 其他改进

| 改进项 | 文件 | 说明 |
|:-------|:-----|:------|
| CP2 超时从 60s → 120s → 300s | `ws.rs` | 为 81 章计划留足时间 |
| CP2 计划创建 LLM 调用日志 | `llm_caller.rs` | 进入/退出 + 耗时 + 输出长度 + SSE chunk/frame 计数 |
| CP2 信号检测日志 | `plan_handler.rs` | 入口日志 + 输入预览 + 信号结果 |
| CP2 plan creation 日志 | `plan_handler.rs` | 输入长度 + LLM 响应预览 + handle_plan_update 结果 |
| force_plan_creation 日志 | `plan_handler.rs` | 同上完整日志 |
| 对话历史截断 DEBUG 日志 | `ws.rs` | `history_len`、`max_turns`、`max_chars` 每一步决策 |
| 删除 trial_ 30 秒轮询 | `chat_screen.dart` | 后端未实现的 `/progress/done-count` 滚动刷 404 |
| plan_updated → 触发注册弹窗 | `chat_screen.dart` | 后端 WS 推送时触发 `_maybeShowClaimDialog` |

---

## 改动文件清单

| 文件 | 改动性质 |
|:-----|:---------|
| `backend/crates/chat_engine/src/llm_caller.rs` | bugfix + 日志增强 + 新客户端 |
| `backend/crates/api_server/src/ws.rs` | bugfix ×3 + 日志增强 |
| `backend/crates/api_server/src/plan_handler.rs` | bugfix + 日志增强 |
| `backend/crates/api_server/src/app_config_cache.rs` | bugfix |
| `backend/prompts/plan/general/signal/signal.md` | bugfix |
| `backend/prompts/format/plan/creation.md` | prompt 优化 |
| `app/lib/screens/chat_screen.dart` | 功能增强 |
| `backend/crates/api_server/src/campaign_scheduler.rs` | 策略简化 |
| `backend/crates/api_server/src/auth.rs` | 策略简化 |
| `backend/crates/api_server/src/test_helpers.rs` | 路径 bugfix |
