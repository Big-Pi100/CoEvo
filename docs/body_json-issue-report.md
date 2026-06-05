# 调查报告: body_json() 兜底问题

> 日期: 2026-06-05
> 调查人: Qi

---

## 问题概述

6 个 e2e 测试文件各有 1 份 `body_json()` 函数，用于解析 HTTP 响应为 JSON。所有版本都使用了兜底策略，静默吞掉 API 错误。

## 当前代码（6 份副本）

### 版本 A — 原始实现（4 个文件）

```rust
async fn body_json(resp: reqwest::Response) -> Value {
    resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
}
```

**文件**: `e2e_api_lifecycle.rs`, `e2e_cards_lifecycle.rs`, `e2e_k12_extra_lifecycle.rs`, `e2e_profile_lifecycle.rs`

### 版本 B — 带状态码日志（1 个文件，我临时改的）

```rust
async fn body_json(resp: reqwest::Response) -> Value {
    let status = resp.status();
    match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[body_json] HTTP {} parse failed: {}", status, e);
            json!({"raw": "parse failed"})
        }
    }
}
```

**文件**: `e2e_conv_lifecycle.rs`

### 版本 C — 带完整响应文本日志（1 个文件，我临时改的）

```rust
async fn body_json(resp: reqwest::Response) -> Value {
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    let val: Value = serde_json::from_str(&text).unwrap_or(json!({"raw": text, "parse_error": true}));
    if status != 200 || val.get("error").is_some() {
        eprintln!("[body_json] HTTP {} body (first 300): {}", status, &text[..text.len().min(300)]);
    }
    val
}
```

**文件**: `e2e_ws_lifecycle.rs`

---

## 问题分析

### 问题 1: `unwrap_or` 静默吞错误

```rust
resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
```

当 API 返回 500 + HTML 错误页时，`resp.json().await` 返回 `Err`（非 JSON），`unwrap_or` 返回 `{"raw": "parse failed"}`。后续代码：

```rust
let uid = reg["user_id"].as_str().expect("register uid");
```

`expect`  panic 信息只有 `"register uid"`，看不到原始 HTTP 状态码和响应体。

**真实案例** — 今天调试时，`auth::register` 返回：
```
HTTP 200 body: {"error":"Insert error: table users has no column named phone_hash"}
```

旧版 `body_json` 的表现：
1. `resp.json()` 成功（这是有效 JSON）
2. 返回 `{"error":"Insert error: ..."}`
3. `reg["user_id"]` 为 `None`
4. `.expect("register uid")` panic → 看不到真实错误
5. 需要额外在 `body_json` 加日志才能发现问题

如果 HTTP 返回非 JSON（如 500 HTML 页）：
1. `resp.json()` 失败 → `unwrap_or` 返回 `{"raw": "parse failed"}`
2. `reg["user_id"]` 为 `None`
3. `.expect("register uid")` panic → 完全不知道返回了什么

### 问题 2: 响应体只能消费一次

`resp.json().await` 消费了响应 body。如果出错了想打日志，已经没有 body 可以读了。需要用 `resp.text().await` 替代，但 `text()` 也会消费 body，只能二选一。

### 问题 3: 6 份重复代码

修改需要改 6 个文件，容易漏。任何新测试文件都会再复制一份。

---

## 修复建议

### 方案 A: 统一提取到 `api_server::test_helpers`

创建 `api_server::test_helpers` 模块（`src/test_helpers.rs`），导出唯一的 `body_json()`，所有测试引用同一份：

```rust
/// 解析 HTTP 响应为 JSON。
/// 失败时 panic 并打印 HTTP 状态码和响应体（不会静默吞错误）。
pub async fn body_json(resp: reqwest::Response) -> serde_json::Value {
    let status = resp.status();
    let text = resp.text().await
        .unwrap_or_else(|e| format!("<body read error: {}>", e));
    match serde_json::from_str::<serde_json::Value>(&text) {
        Ok(v) => {
            // 即使 parse 成功，如果 HTTP 状态码异常也打印警告
            if status != 200 || v.get("error").is_some() {
                eprintln!("[body_json] HTTP {} body (first 500): {}", status, &text[..text.len().min(500)]);
            }
            v
        }
        Err(e) => {
            // JSON parse 失败时直接 panic，暴露原始响应
            panic!(
                "body_json: HTTP {} response is not JSON\n  parse error: {}\n  body (first 500): {}",
                status, e,
                &text[..text.len().min(500)]
            );
        }
    }
}
```

### 方案 B: 保持每个文件独立但修复兜底逻辑

不改架构，仅修复 6 个文件的 `body_json()`，统一为版本 C（带完整日志）。新增测试必须手动复制。

---

## 推荐

**方案 A**，理由：
1. 消除重复代码
2. 新测试开箱即用
3. 改一处同步全部
4. 与 `schema.rs` 统一入口的思路一致

## 影响范围

| 文件 | 改动 |
|------|------|
| 新增 `src/test_helpers.rs` | 导出 `body_json()` |
| `src/lib.rs` | 加 `pub mod test_helpers;` |
| 6 个测试文件 | 删除各自的 `body_json()`，改为 `use api_server::test_helpers::body_json;` |
