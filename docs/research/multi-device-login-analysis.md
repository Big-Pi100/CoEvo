# 同一账号多端登录 · 影响分析报告

> 日期：2026-05-16
> 调查范围：认证、WebSocket、数据库读写、前端状态

---

## 一、结论摘要

| 严重度 | 问题 | 现状 |
|--------|------|------|
| 🔴 P0 | 后登录设备会踢掉前设备的 token | 前设备的 REST API 全部 401 |
| 🟡 P1 | 两端消息不可见 | 各看各的，刷新后才同步 |
| 🟡 P1 | 无并发连接数限制 | 资源不可控 |
| 🟢 P2 | 数据库写入安全 | SQLite 行级锁，无脏写风险 |

---

## 二、逐层分析

### 2.1 认证层 — Token 互踢

```
设备 A 登录 → token T1 存入 tokens 表
    ↓
设备 B 登录 → login() 第 106 行调用 cleanup_old_tokens()
    ↓
DELETE FROM tokens WHERE user_id = ?   ← T1 被删！
    ↓
INSERT INTO tokens ... → token T2 存入库
    ↓
设备 A 发起 HTTP 请求 → auth_middleware → verify_token(T1) → 失败 → 401
```

**代码位置**：`backend/crates/api_server/src/auth.rs:106`

```rust
fn cleanup_old_tokens(conn: &rusqlite::Connection, user_id: &str) {
    conn.execute("DELETE FROM tokens WHERE user_id = ?1", ...);
}
```

**影响**：
- 设备 A 的 HTTP 请求全部返回 401（加载历史、卡片列表、复习队列等）
- WebSocket 连接不受影响（只在首条消息验证一次，连接期间不再检查）
- 用户体验：设备 A 看起来"一直连着"但功能逐渐失效

### 2.2 WebSocket 层 — 连接可并存但互相不知

```
设备 A ──WS── 后端 WS handler (token T1, 已验证)
设备 B ──WS── 后端 WS handler (token T2, 已验证)
```

两个 WS 连接独立运行：
- ✅ 各自可以发送消息、收到 AI 回复
- ❌ 设备 A 发的消息不会推送给设备 B
- ❌ 设备 B 发的消息不会推送给设备 A
- ⚠️ 两端都在同一 `conversation_id` 下写入 `conversation_turns`
- ⚠️ `turn_count` 原子递增（`UPDATE ... SET turn_count = turn_count + 1`）——数据正确，但两端 UI 看不到对方

**代码位置**：`backend/crates/api_server/src/ws.rs:52-57`（token 仅验证一次）

### 2.3 数据库层 — 写入安全

| 操作 | 并发安全性 | 说明 |
|------|-----------|------|
| `INSERT INTO conversation_turns` | ✅ 安全 | 每条消息独立 UUID，无冲突 |
| `UPDATE conversations SET turn_count = turn_count + 1` | ✅ 原子 | SQL 级别原子操作 |
| `INSERT OR IGNORE INTO conversations` | ✅ 安全 | 幂等，首次创建不冲突 |
| 卡片/复习写入 | ✅ 安全 | 各自独立的数据行 |

**结论**：数据库层面无正确性问题。数据不会损坏。

### 2.4 前端层 — 无跨端同步

| 场景 | 行为 |
|------|------|
| 设备 A 发消息 | 仅在设备 A 的聊天列表显示 |
| 设备 B 发消息 | 仅在设备 B 的聊天列表显示 |
| 设备 A 刷新页面 | 重新加载历史 → 看到设备 B 的消息 |
| 设备 A 切换对话再切回来 | `getConversationTurns` → 看到设备 B 的消息 |
| 设备 A 调用 REST API | token T1 已失效 → 401 → 功能崩溃 |

### 2.5 无并发限制

当前无任何机制限制单个用户的并发连接数：
- 用户可以同时在 N 个浏览器窗口打开
- 每个窗口创建一个独立的 WebSocket 连接
- 每个 WebSocket 会携带 LLM 调用的成本

---

## 三、问题矩阵

| # | 问题 | 严重度 | 修复优先级 | 影响范围 |
|---|------|--------|-----------|---------|
| 1 | Token 互踢 | 🔴 P0 | 立即 | 已登录设备功能崩溃 |
| 2 | 跨端消息不可见 | 🟡 P1 | 本周 | 多端体验撕裂 |
| 3 | 无连接数限制 | 🟡 P1 | 本周 | 资源/成本不可控 |
| 4 | 数据库无脏写 | 🟢 OK | — | 无需处理 |

---

## 四、修复建议

### 4.1 Token 互踢（P0）

**方案 A**：支持多 token，不删除旧 token
```diff
- cleanup_old_tokens(conn, &user_id);
+ // 允许多端登录，不删除旧 token
```
影响：需要在其他地方处理 token 过期/清理（如定时任务清理 30 天前的 token）。

**方案 B**：保留当前单 token 逻辑，但在前端提示"已在其他设备登录"
- 前端发现 401 → 弹出提示 → 跳转登录页

### 4.2 跨端消息同步（P1）

**方案 A（推荐）**：WebSocket 广播
- 后端维护 `user_id → [WS sender]` 映射表
- 当某连接收到用户消息时，广播 `new_message` 事件给同 user_id 的其他连接
- 其他客户端收到事件后，刷新消息列表

**方案 B**：轮询（简单但性能差）
- 客户端每 3-5 秒轮询 `/api/history` 检查新消息

### 4.3 连接数限制（P1）

- 后端：每个 user_id 最多 3 个并发 WebSocket
- 超限时返回 `{"type":"error","content":"too_many_connections"}`

---

## 五、当前临时规避

在修复 P0 之前，建议：
- **不要多端同时登录同一账号**
- 切换设备前先退出登录
- 如遇 401 错误，刷新页面重新登录
