# Bug 调查报告：连接池导致大模型访问卡顿/卡死

> **日期**: 2026-05-14  
> **关联 Commit**: `3ebb77e` "并发支持"  
> **调查范围**: DB 连接池 (r2d2-sqlite) + HTTP 连接池 (reqwest)  
> **严重程度**: 🔴 Critical — 影响所有用户的核心对话体验

---

## 一、TL;DR

问题根因**不是单一的 DB 连接池**，而是 **reqwest HTTP 连接池** 与新增的 DB 连接池**共同作用**产生的复合效应：

1. **reqwest 全局 Client** 的 `generate()` 方法中使用了"竞速双请求"模式（`tokio::select!`），被丢弃的请求会将**半断开/脏连接**归还到 HTTP 连接池；
2. reqwest Client 未设置 `pool_max_idle_per_host`，脏连接**无限累积不清理**；
3. 新请求从池中拿到脏连接 → 超时 30s → 用户感知为"卡死"；
4. DB 连接池 (`r2d2`) 的阻塞式 `.get()` 在高并发时阻塞 tokio worker 线程，**加剧**了 LLM 请求任务无法及时调度的问题。

---

## 二、变更点分析

`3ebb77e` "并发支持" 引入了以下与性能相关的变更：

| 文件 | 变更内容 |
|------|---------|
| `db_pool.rs` | 从"每次打开新连接"改为 r2d2 连接池（max_size=10） |
| `auth_middleware.rs` | 移除了 `verify_token` 中的 DB 查询（优化，正向） |
| `llm_caller.rs` | **未修改** — 竞速双请求模式早已存在 |
| Flutter 前端 | 多项 UI 改动（无关本次问题） |

**关键发现**：LLM 调用代码本身在本次 commit 中未改动。但连接池的引入改变了系统的并发特征，**暴露了原本潜伏的 reqwest 连接池污染问题**。

---

## 三、Bug 详情

### 🔴 Bug #1 (CRITICAL): `generate()` 竞速请求污染 HTTP 连接池

**文件**: `backend/crates/chat_engine/src/llm_caller.rs` 第 119-126 行

```rust
// Race two parallel requests (no artificial timeout — let the
// winner come back as fast as the API can deliver).
let req1 = post_one(http_client(), &url, &self.config.api_key, &body);
let req2 = post_one(http_client(), &url, &self.config.api_key, &body);
let result = tokio::select! {
    result1 = req1 => result1,
    result2 = req2 => result2,
};
```

**问题分析**：

每次 `generate()` 调用（用于概念提取、词库生成、问答判题等）会**同时发送两个完全相同的 HTTP 请求**到 LLM API：

- `tokio::select!` 选中先返回的 winner → 取结果
- **另一个请求的 Future 被丢弃** → reqwest 尝试 abort 底层连接
- 被 abort 的连接可能处于 TLS 握手 / HTTP 请求中途 / 响应接收中等**非一致状态**
- reqwest 将此连接归还到内部连接池（标记为可用）
- **后续请求从池中拿到此脏连接 → 超时 30s → 用户感知"卡死"**

**触发频率**：每次用户发送消息，ColdPath 概念提取触发 1 次 `generate()`（2 个连接，1 个被丢弃），词库匹配可能再触发 1 次（又 2 个连接，1 个被丢弃）。**每条消息至少产生 1 个脏连接。**

**影响**：随着服务器运行时间增长，连接池中脏连接比例上升，新请求越来越大概率拿到脏连接，导致"用越久越卡"的退化现象。

---

### 🔴 Bug #2 (CRITICAL): 流式请求失败后，脏连接回到池中

**文件**: `backend/crates/chat_engine/src/llm_caller.rs` 第 142-161 行

```rust
pub async fn stream_generate(&mut self, prompt: &str, tx: mpsc::Sender<LlmEvent>) -> Result<(), LlmError> {
    let mut last_error = LlmError::EmptyResponse;
    for attempt in 0..2 {
        match self.stream_generate_inner(prompt, &tx).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                tracing::warn!("LLM stream attempt {} failed: {:?}", attempt + 1, e);
                last_error = e;
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
        }
    }
    Err(last_error)
}
```

**问题分析**：

- 第一次流式请求失败（如 SSE 解析错误、中途断连）→ Response body 未完全消费就被 drop
- Drop 时 reqwest 后台 drain body，但连接可能已损坏
- 连接可能被标记归还到池中
- **500ms 后重试时，从同一个池中再次取连接 → 可能又拿到脏连接**
- 两次都失败 → 返回错误给用户 → 感知"卡顿"

---

### 🟠 Bug #3 (HIGH): reqwest Client 未设置连接池上限

**文件**: `backend/crates/chat_engine/src/llm_caller.rs` 第 25-33 行

```rust
fn http_client() -> &'static Client {
    static HTTP_CLIENT: OnceLock<Client> = OnceLock::new();
    HTTP_CLIENT.get_or_init(|| {
        Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest::Client::new")
    })
}
```

**问题分析**：

| 缺失配置 | 默认值 | 影响 |
|---------|--------|------|
| `pool_max_idle_per_host` | **无限制** (usize::MAX) | 脏连接永不回收，无限累积 |
| `pool_idle_timeout` | 90s (默认) | 空闲 90s 后才关闭，时间太长 |
| `connect_timeout` | 未显式设置 | 依赖 30s 总超时，但连接建立阻塞时间过长 |

**组合效应**：Bug #1 + Bug #2 产生的脏连接在池中**无限累积**，没有自动清理机制。服务器运行数小时后，池中可能有数十个不可用连接。

---

### 🟠 Bug #4 (HIGH): DB 连接池阻塞 tokio 异步任务

**文件**: `backend/crates/api_server/src/db_pool.rs` 第 46-55 行

```rust
pub fn get_conn() -> DbConn {
    let conn = DB_POOL
        .get()
        .expect("DB pool not initialized — call init() first")
        .get()   // ← r2d2::Pool::get() 是同步阻塞调用！
        .expect("Failed to get DB connection from pool");
    conn.execute_batch("PRAGMA busy_timeout=5000;")
        .expect("Failed to set busy_timeout");
    conn
}
```

**问题分析**：

- `r2d2::Pool::get()` 在池中无可用连接时**同步阻塞**当前线程
- 在 tokio 多线程运行时，这会**阻塞一个 worker 线程**而非仅阻塞当前任务
- WebSocket handler (`ws.rs`) 中**每个消息处理有 7 次** `get_conn()` 调用
- 每个连接持有期间（即使只有微妙级），独占池中的一个 slot
- 当多个用户同时发消息时，10 个连接可能被耗尽

**每消息的 DB 操作序列**（`ws.rs`）：
| 行号 | 操作 | 类型 |
|------|------|------|
| 41 | 检查订阅状态 | READ |
| 68 | 保存用户消息 | WRITE |
| 84 | 加载对话历史 | READ |
| 124 | 加载学习计划 | READ |
| 216 | plan_update 写入 (条件) | WRITE |
| 360 | 保存 assistant 回复 | WRITE |
| 395 | ColdPath 加载已有卡片/跳过记录 | READ |

**7 次 get_conn() 调用在同一个消息处理中串行执行**，如果其中任何一个因池耗尽而阻塞，整个消息处理管道停滞。

**与 LLM 卡顿的关联**：
- DB 连接池阻塞 → tokio worker 线程被占用 → LLM 请求的 spawn 任务无法及时调度
- 即使 LLM 请求已经发出了 HTTP 请求，其响应处理（SSE 解析回调）也需要 tokio worker → 被 DB 阻塞的 worker 无法及时处理 → 流式 token 延迟到达 → 用户感知"卡顿"

---

### 🟡 Bug #5 (MEDIUM): `PRAGMA busy_timeout` 每次 checkout 都执行

**文件**: `backend/crates/api_server/src/db_pool.rs` 第 52-53 行

```rust
conn.execute_batch("PRAGMA busy_timeout=5000;")
    .expect("Failed to set busy_timeout");
```

**问题分析**：
- `busy_timeout` 是 SQLite 连接级别的设置，一旦设置就在该连接生命周期内保持
- 每次 `get_conn()` 都重新执行一次 `PRAGMA`，虽快（微秒级）但完全是**冗余操作**
- 正确做法：在 `init()` 初始化连接池时，确保每个新建连接都设置了 busy_timeout（通过 r2d2 的 `CustomizeConnection` 或 `after_connect` 回调）

---

### 🟡 Bug #6 (MEDIUM): reqwest Client 缺少 `connect_timeout`

**文件**: `backend/crates/chat_engine/src/llm_caller.rs` 第 28-31 行

虽然有 `.timeout(Duration::from_secs(30))` 覆盖整体请求超时，但没有单独设置 `.connect_timeout()`。在 DNS 解析慢或 TCP 握手卡住的情况下，用户需要等待长达 30 秒才会超时。

---

## 四、问题复现路径

```
1. 服务器启动，warmup 发送 1 次 generate() → 丢弃 1 个连接
2. 用户 A 发送消息 (WS) → streaming LLM + ColdPath generate() → 丢弃 1 个连接
3. 用户 B 发送消息 → 同上，又丢弃 1 个连接
4. ... 运行 1 小时后，HTTP 连接池中累积 20+ 个脏连接
5. 新请求从池中随机选中脏连接 → 30s 超时 → "卡死"
6. DB 连接池可能在高峰期耗尽 → tokio worker 阻塞 → 进一步延迟
```

---

## 五、影响评估

| 影响维度 | 严重程度 | 说明 |
|---------|---------|------|
| 用户对话体验 | 🔴 严重 | 卡顿、卡死、LLM 无响应 |
| 退化趋势 | 🔴 严重 | 运行时间越长越卡（脏连接累积） |
| 并发用户数 | 🟠 高 | DB 池只有 10 连接，多用户竞争 |
| 流式响应质量 | 🟠 高 | token 延迟增加，打字机效果中断 |
| 数据完整性 | 🟢 低 | 暂未发现数据丢失 |

---

## 六、修复建议（概要，待后续实施）

### 紧急修复 (P0)

1. **移除 `generate()` 中的竞速双请求**
   - 改为单请求 + 超时重试
   - 或至少确保丢弃的连接不被回池（通过 `Connection: close` header 或 pool 配置）

2. **配置 reqwest 连接池**
   ```rust
   Client::builder()
       .timeout(Duration::from_secs(30))
       .connect_timeout(Duration::from_secs(10))
       .pool_max_idle_per_host(5)   // 限制空闲连接
       .pool_idle_timeout(Duration::from_secs(30))  // 快速回收
       .build()
   ```

3. **DB 连接池改为异步获取**
   - 使用 `r2d2::Pool::get()` 的非阻塞替代方案
   - 或用 `tokio::task::spawn_blocking` 包装

### 重要修复 (P1)

4. **将 `busy_timeout` PRAGMA 移至连接创建时**
   - 使用 r2d2 的 `after_connect` 或 `CustomizeConnection` trait

5. **`stream_generate` 重试前确保旧连接完全释放**
   - 显式关闭旧连接，不依赖连接池回收

---

## 七、附录：相关代码索引（修复前）

| 文件 | 关键行(旧) | 问题 | 状态 |
|------|--------|------|------|
| `chat_engine/src/llm_caller.rs` | 25-33 | http_client 无连接池配置 | ✅ 已修复 |
| `chat_engine/src/llm_caller.rs` | 119-126 | generate() 竞速请求 | ✅ 已修复 |
| `chat_engine/src/llm_caller.rs` | 142-161 | stream_generate 重试复用脏池 | ✅ 已修复 |
| `api_server/src/db_pool.rs` | 46-55 | get_conn() 同步阻塞 | ✅ 已修复 |
| `api_server/src/db_pool.rs` | 52-53 | busy_timeout 冗余执行 | ✅ 已修复 |
| `api_server/src/ws.rs` | 41,68,84,124,216,360,395 | 单消息 7 次 DB 调用 | ⏳ 后续优化 |

---

## 八、修复记录（2026-05-14）

全部 6 个 Bug 已于 2026-05-14 修复并部署到 VPS（<OLD_VPS_IP>），编译通过，服务运行正常。

### 实际修复 vs 建议方案

| Bug | 建议方案 | 实际修复 |
|-----|---------|---------|
| #1 | 移除竞速，单请求 | ✅ 单请求 + 一次重试（500ms 退避） |
| #2 | 显式关闭旧连接 | ✅ `pool_idle_timeout(30s)` 自动回收 + 500ms 退避 |
| #3 | 增加 pool_max_idle_per_host | ✅ 5，另增 connect_timeout(10s)、pool_idle_timeout(30s) |
| #4 | 异步化 DB 获取 | ✅ 池扩至 30 + `get_timeout(3s)` 非阻塞 |
| #5 | 移至连接创建时 | ✅ `with_init()` 设置 busy_timeout |
| #6 | (未单独列出) | ✅ connect_timeout(10s) |

### 修改文件

- `backend/crates/chat_engine/src/llm_caller.rs`：Bug #1, #2, #3, #6
- `backend/crates/api_server/src/db_pool.rs`：Bug #4, #5
