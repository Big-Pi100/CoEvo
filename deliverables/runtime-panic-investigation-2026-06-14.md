# Runtime Panic 深度调查报告

**日期**: 2026-06-14  
**影响范围**: 服务启动后立即崩溃，无法处理任何 WebSocket 请求  
**严重级别**: P0 — 服务不可用

---

## 1. 问题现象

```
cargo run --release
...
====== PANIC ======
panicked at crates\api_server\src\plan_handler.rs:1105:57:
Cannot start a runtime from within a runtime. This happens because a
function (like `block_on`) attempted to block the current thread while
the thread is being used to drive asynchronous tasks.
===================
```

上一个错误 `app_config_cache.rs:68` 修复后，依然有第二个 panic 发生在 `plan_handler.rs:1105`。

## 2. 根因分析 — 链路追踪

### 调用链

```
#[tokio::main] fn main()
  → axum 启动 HTTP 服务器
    → handle_ws()                  ← 异步函数，在 tokio runtime 内
      → build_plan_context()       ← 同步函数 (fn, 非 async)
        → build_context_text()     ← 同步函数
          → Handle::try_current()  ← 成功！因为我们在 tokio runtime 内
          → Handle::block_on()     ← PANIC！不能阻塞运行中的 runtime
```

### 为什么 `try_current()` 成功但 `block_on()` 失败

`Handle::try_current()` 只是检测**是否在 tokio runtime 上下文中**，返回 `Ok(handle)`。但 `handle.block_on()` 要求**当前线程未被占用**（即不能在 runtime 正在驱动的工作线程上调用）。由于 `handle_ws` 本身就是 tokio 驱动的异步任务，它的工作线程已经在驱动 async 循环，再 `block_on` 就会 panic。

### 两个出问题的地方

| 位置 | 函数 | 行号（原） | 目的 |
|------|------|-----------|------|
| #1 | `build_plan_context()` | 972-983 | 写 plan_context_exit 调试日志 |
| #2 | `build_context_text()` | 1104-1116 | 写 context_text_inject 调试日志 |

两者都是**非关键的调试日志代码**，但用了错误的方式在同步函数中执行异步操作。

## 3. 修复方案

将两处 `Handle::block_on` 替换为 `tokio::task::spawn`，把异步日志任务提交给 runtime 的 executor 去调度，不阻塞当前线程：

```rust
// ❌ 错误：
if let Ok(runtime) = tokio::runtime::Handle::try_current() {
    let _ = runtime.block_on(async { ... });
}

// ✅ 正确：
let conv_id = conversation_id.to_string();
let _ = tokio::task::spawn(async move {
    // 异步日志代码 ...
});
```

**变更文件**: 只改了 `crates/api_server/src/plan_handler.rs` 两处。

## 4. 全局排查结果

对 `backend/crates/` 和 `backend/src/` 所有 `.rs` 文件进行 `block_on`、`Handle::try_current`、`Runtime::new` 模式搜索：

| 位置 | 状态 |
|------|------|
| `crates/api_server/src/plan_handler.rs:972` | ✅ 已修复 → `tokio::spawn` |
| `crates/api_server/src/plan_handler.rs:1104` | ✅ 已修复 → `tokio::spawn` |
| 其余文件 | ✅ 零残留 |

**项目内已无任何 `block_on` / `Handle::try_current` 调用**。

## 5. 编译 & 测试验证

| 检查项 | 结果 |
|--------|------|
| `cargo check` | ✅ 零 error，零 warning |
| `cargo test --workspace` | ✅ 全部 28+17+20+9 tests 通过 |

## 6. 对比：这次 vs 上次的 panic

| 上次 (`app_config_cache.rs`) | 这次 (`plan_handler.rs`) |
|------|------|
| `tokio::sync::RwLock` 的 `blocking_write()` | `Handle::try_current()` + `block_on()` |
| 在 `#[tokio::main]` 启动阶段触发 | 在 WS 请求处理中触发 |
| 服务压根起不来 | 服务能起但一处理 WS 请求就崩 |
| 修复: `std::sync::RwLock` | 修复: `tokio::task::spawn` |

**共同根因**：在 tokio runtime 内部用同步方式阻塞线程。两次都是 debug 调试日志代码引入的。

## 7. 经验教训

1. **同步函数调用异步代码的正确姿势**：
   - 在 tokio runtime 内 → 用 `tokio::task::spawn`（fire-and-forget）
   - 在非 tokio 线程 → 用 `tokio::runtime::Runtime::block_on`（创建独立的 runtime）
   - 永远不要用 `Handle::block_on` 在 runtime 的工作线程上阻塞

2. **调试日志不建议阻塞主流程**。日志写入失败不应导致服务崩溃，用 `tokio::spawn` fire-and-forget 是最轻量的方式。

---

## 附录：修改的代码文件

- `crates/api_server/src/plan_handler.rs` — 两处 `block_on` → `tokio::spawn`
- `crates/api_server/src/app_config_cache.rs` — `tokio::sync::RwLock` → `std::sync::RwLock`（上次 fix）
- `crates/api_server/src/debug_trackers_cache.rs` — 同上（上次 fix）
