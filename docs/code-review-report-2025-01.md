# CoEvo 代码审查报告

> **日期**: 2025-01-20  
> **范围**: 全栈代码审查（Backend Rust + Frontend Flutter）  
> **版本**: post-connection-pool-fix  
> **结论**: 发现 4 个严重安全缺陷 + 3 个数据一致性缺陷 + 4 个性能/质量缺陷 + 4 个前端问题

---

## 总览

| 分类 | 数量 | 严重程度 |
|------|------|----------|
| 🔴 安全缺陷 | 4 | Critical |
| 🟠 数据一致性 | 3 | High |
| 🟡 性能/代码质量 | 4 | Medium |
| 🟢 前端问题 | 4 | Low-Medium |

---

## 🔴 A. 安全缺陷 (Critical)

### A1. 密码使用裸 SHA-256，无盐值

**文件**: `backend/crates/api_server/src/auth.rs:28-32`

```rust
fn hash_password(password: &str) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    hasher.finalize().to_vec()
}
```

**问题**: SHA-256 无盐哈希极易受到彩虹表攻击。相同密码产生相同哈希，一旦数据库泄露，所有用户密码均可被批量破解。

**建议**: 使用 `bcrypt` 或 `argon2` crate。最低限度应使用 HMAC-SHA256 + 随机盐。

**风险**: 🔴 Critical

---

### A2. Token 认证形同虚设

**文件**: `backend/crates/api_server/src/auth.rs:96-98`

```rust
pub fn verify_token(_conn: &rusqlite::Connection, _user_id: &str, _token: &str) -> bool {
    // MVP: trust the client. Future: JWT or stored tokens.
    !_token.is_empty()
}
```

**问题**:
- Token 生成后**从未存储到数据库**
- 验证仅检查 token 是否非空字符串
- **任何** Bearer token 都能通过任何用户的认证
- 没有 user_id 与 token 的绑定校验

**后果**: 攻击者只需在请求头中填入任意 `Bearer anything` 即可冒充任意用户访问所有 API。

**建议**: 必须实现以下之一:
- JWT (推荐): 使用 `jsonwebtoken` crate，token 自带签名和过期时间
- 服务端 Session: token 存入 DB 并关联 user_id，验证时查表

**风险**: 🔴 Critical

---

### A3. 多个 API 端点缺少认证检查

| 端点 | 文件位置 | 风险 |
|------|---------|------|
| `GET /api/cards/skipped` | `routes.rs:423` | 可通过 user_id 查看任意用户的跳过记录 |
| `DELETE /api/cards/skipped/{skip_id}` | `routes.rs:443` | 可取消任意用户的跳过记录并为其创建卡片 |
| `POST /api/review/verify` | `routes.rs:296` | 可消耗 LLM 配额为他人出题 |
| `POST /api/review/judge` | `routes.rs:339` | 可消耗 LLM 配额为他人批改 |
| `GET /api/cards/{card_id}/last-review` | `routes.rs:709` | 可查看任意卡片的最近复习详情 |

**问题**: 这些端点要么完全没有调用 `verify_auth`，要么未获取 `HeaderMap`。在 A2 未修复的情况下影响有限，但一旦修复 A2，这些端点将成为新的漏洞。

**风险**: 🔴 Critical (与 A2 叠加)

---

### A4. Token 明文存储在 SharedPreferences（Flutter 端）

**文件**: `app/lib/providers/auth_provider.dart:54-55`

```dart
final prefs = await SharedPreferences.getInstance();
final token = prefs.getString(_tokenKey);
```

**问题**: Android 上 `SharedPreferences` 存储在可被 root 读取的 XML 文件中。Token 泄露后攻击者可无限期冒充用户。

**建议**: 使用 `flutter_secure_storage` 替代，将 token 存入 Android Keystore / iOS Keychain。

**风险**: 🟠 High

---

## 🟠 B. 数据一致性缺陷 (High)

### B1. `plan_upsert_handler`: ON CONFLICT 永不触发

**文件**: `backend/crates/api_server/src/routes.rs:1020-1028`

```rust
let id = uuid::Uuid::new_v4().to_string();  // 每次都是新的 UUID

conn.execute(
    "INSERT INTO learning_plans (...) VALUES (...)
     ON CONFLICT(id) DO UPDATE SET plan_json=?5, updated_at=?6",
    rusqlite::params![id, ...],
)
```

**问题**: 每次调用都生成全新 UUID，`ON CONFLICT(id)` 永远不会触发，导致：
- 同用户同领域产生重复学习计划
- 标注为 "upsert" 实际永远只 insert
- 注释说 "检查是否已有同 domain 的 plan"，但代码未实现此逻辑

**修复**: 将冲突检测改为 `ON CONFLICT(user_id, domain) DO UPDATE`，并添加唯一约束 `CREATE UNIQUE INDEX idx_plans_user_domain ON learning_plans(user_id, domain) WHERE mode != 'deleted'`

**风险**: 🟠 High

---

### B2. `insert_card`: 去重与写入之间存在竞态条件

**文件**: `backend/crates/card_engine/src/card_repository.rs:20-94`

```
时间线:
  线程A: SELECT front (无重复)       线程B: SELECT front (无重复)
  线程A: BEGIN TRANSACTION           线程B: BEGIN TRANSACTION
  线程A: INSERT (成功)               线程B: INSERT (成功) ← 重复!
```

**问题**:
1. 去重查询和事务开始之间存在 TOCTOU 窗口
2. `execute_batch("BEGIN TRANSACTION")` 不是 rusqlite 推荐的事务方式（应使用 `conn.execute("BEGIN IMMEDIATE", [])` 确保写锁）

**修复**:
- 使用 `conn.execute("BEGIN IMMEDIATE", [])` 获取写锁
- 在事务**内部**做去重检查（或将去重和插入放在同一个事务中）

**风险**: 🟠 High

---

### B3. `created_at` 字段时间格式不一致

**文件**: `routes.rs:211` vs `ws.rs:358`

| 位置 | 值 | 格式 |
|------|-----|------|
| `routes.rs:165` (user message) | `now_str` = `2025-01-20T10:30:00+00:00` | RFC3339 |
| `routes.rs:211` (assistant message) | `now_ts.to_string()` = `1737369600` | Unix timestamp |
| `ws.rs:358` (assistant message) | `now_str` = `2025-01-20T10:30:00+00:00` | RFC3339 |

**问题**: 同一张表 (`conversation_turns`) 的 `created_at` 列混用了 RFC3339 和 Unix timestamp 两种格式。REST API (`routes.rs`) 的 assistant 消息写入的是 Unix timestamp，而 WebSocket (`ws.rs`) 写入的是 RFC3339。

**影响**: `history_handler` 中的 `ORDER BY created_at ASC` 排序可能不正确（字符串比较 "1" < "2" 但 "1737..." > "2025..."）。

**修复**: 统一使用一种格式。推荐 RFC3339 字符串（与 `conversation_turns` 和 `conversations` 表的其他列保持一致）。

**风险**: 🟠 High

---

## 🟡 C. 性能与代码质量 (Medium)

### C1. `stt_handler`: 每次请求创建新的 HTTP Client

**文件**: `backend/crates/api_server/src/routes.rs:1391`

```rust
let client = reqwest::Client::new();  // 每个 STT 请求都新建
```

**问题**: 与之前已修复的 `llm_caller.rs` 相同模式——每次 STT 请求都新建 `Client`，无法复用连接池和 TLS session。

**修复**: 使用 `OnceLock<reqwest::Client>` 或传入共享的 `Client` 实例。

**风险**: 🟡 Medium

---

### C2. `stt_handler`: async 上下文中使用阻塞 I/O

**文件**: `backend/crates/api_server/src/routes.rs:1347, 1364`

```rust
let _ = std::fs::write(&in_path, &body);    // 阻塞!
let data = std::fs::read(&out_path)...       // 阻塞!
```

**问题**: `std::fs::write` 和 `std::fs::read` 在 tokio 的 async 上下文中是阻塞调用，会占用整个 worker 线程。在 1 核 VPS 上可能导致其他请求饥饿。

**修复**: 使用 `tokio::fs::write` 和 `tokio::fs::read`。

**风险**: 🟡 Medium

---

### C3. `word_bank::match_text`: O(n×m) 匹配算法

**文件**: `backend/crates/chat_engine/src/word_bank.rs:94-125`

```rust
for (id, entry) in catalog.iter() {   // ~100K 词
    // ... 对每个词检查是否在文本中
    if words.windows(parts.len()).any(...)  // O(m) per word
}
```

**问题**: 对 500 词 AI 回复 + 100K 词库 ≈ 5000万次字符串比较。这在每次对话后执行。

**优化建议**: 对单次词使用 `HashSet` 查找（已实现），对多词短语构建前缀树（Trie）或 Aho-Corasick 自动机。

**风险**: 🟡 Medium (依赖词库大小)

---

### C4. 数据库迁移静默吞错

**文件**: `backend/src/main.rs:178-180`

```rust
for sql in &migrations {
    let _ = conn.execute(sql, []);  // 忽略所有错误
}
```

**问题**: 
- ALTER TABLE ADD COLUMN 在列已存在时失败，但错误被静默忽略
- 如果某条迁移因其他原因失败（如语法错误），没有任何日志
- 建议至少用 `tracing::warn!` 记录失败

**风险**: 🟡 Medium

---

### C5. `compute_next_state`: 冗余的独立查询

**文件**: `backend/crates/card_engine/src/fsrs_scheduler.rs:190-200`

```rust
let current_state: i32 = conn.query_row(
    "SELECT state FROM card_memory WHERE card_id = ?1", ...).unwrap_or(0);

let reps: i32 = conn.query_row(
    "SELECT reps FROM card_memory WHERE card_id = ?1", ...).unwrap_or(0);
```

两次查询可合并为 `SELECT state, reps FROM card_memory WHERE card_id = ?1`。

**风险**: 🟢 Low

---

### C6. `concept_extractor.rs`: 缩进误导

**文件**: `backend/crates/chat_engine/src/concept_extractor.rs:50-57`

```rust
} else {
    // 从 LLM 提取候选概念
    let mut candidates = ...;

let existing_fronts_lower: Vec<String> = ...  // ← 缩进像是顶层代码
let skipped_lower: Vec<String> = ...          // ← 实际仍在 else 块内

candidates.retain(|c| { ... });              // ← 同上
```

虽然代码正确（`rustfmt` 已处理），但视觉上容易让人误读控制流。

**风险**: 🟢 Low

---

## 🟢 D. 前端问题 (Low-Medium)

### D1. 多处 API 调用静默吞错

**文件**: `app/lib/api/chat_client.dart`

```dart
// 多处使用此模式:
try { ... } catch (_) {}
return null;  // 或 return [];
```

涉及的 API 方法: `getPlans`, `createPlan`, `getLearningReport`, `getActivity`, `getWeeklyReport`, `getPreferences`, `savePreferences`, `updateDisplayName`

**问题**: 网络错误、服务端错误全部被静默吞掉，用户完全不知道操作失败。

**建议**: 至少记录错误日志，并在 UI 层展示适当的错误提示。

**风险**: 🟡 Medium (UX)

---

### D2. `GlobalKey` 被重新赋值

**文件**: `app/lib/screens/chat_screen.dart:28`

```dart
GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
```

**问题**: `_listKey` 应该在 `initState` 中创建而非声明时赋值，否则在 `didUpdateWidget` 等场景可能产生过期的 key。

**建议**: 在 `initState` 中赋值 `_listKey = GlobalKey<AnimatedListState>()`。

**风险**: 🟢 Low

---

### D3. 登录/注册缺少输入验证

**文件**: `app/lib/screens/auth_screen.dart` & `app/lib/api/auth_client.dart`

**问题**: 前后端均未验证用户名/密码的长度和格式：
- 空密码可以通过
- 用户名无格式限制
- 无密码强度要求

**建议**: 前后端同时添加最小长度限制（密码 ≥ 6 字符，用户名 ≥ 2 字符）。

**风险**: 🟢 Low

---

### D4. WebSocket URL 中 token 通过查询参数传递

**文件**: `app/lib/api/chat_client.dart:54-56`

```dart
final wsUrl = token != null
    ? '$baseUrl/ws?token=$token'  // token 在 URL 中
    : '$baseUrl/ws';
```

**问题**: Token 出现在 URL 查询参数中，会被记录在服务器日志、代理日志中。

**建议**: 使用 WebSocket 子协议或首条消息传递 token，避免 URL 泄露。

**风险**: 🟡 Medium

---

## 📋 缺失的数据库索引

| 表 | 建议索引 | 原因 |
|----|---------|------|
| `review_log` | `(card_id, reviewed_at)` | `cards_last_review_handler` 的 `ORDER BY reviewed_at DESC LIMIT 1` |
| `conversation_turns` | `(conversation_id, created_at)` | `chat_handler` 和 `ws.rs` 的 `ORDER BY created_at DESC LIMIT 10` |
| `cards` | `(user_id, domain)` | `cards_all_handler` 的 domain 过滤 |
| `learning_plans` | `(user_id, domain)` UNIQUE | 防止 B1 的重复问题 |

---

## 📊 问题优先级排序

| 优先级 | 问题 | 预计修复工时 |
|--------|------|-------------|
| P0 (立即) | A2: Token 认证为空 | 4h |
| P0 (立即) | A1: 密码无盐哈希 | 2h |
| P1 (本周) | A3: 缺失认证检查 | 2h |
| P1 (本周) | B1: plan upsert bug | 1h |
| P1 (本周) | B2: insert_card 竞态 | 2h |
| P1 (本周) | B3: created_at 不一致 | 1h |
| P2 (本月) | C1-C3: 性能优化 | 4h |
| P2 (本月) | D1-D4: 前端修复 | 4h |
| P3 (下月) | C4-C6: 代码质量 | 2h |

---

## ✅ 已修复问题（本轮审查前）

回顾此前已修复的 6 个连接池相关 Bug：

| Bug | 描述 | 状态 |
|-----|------|------|
| #1-2 | `reqwest::Client` 无连接池 / 每次新建 | ✅ 已修复 |
| #3 | 竞速请求模式污染连接池 | ✅ 已修复 |
| #4 | r2d2 pool `max_size=10` 不足 | ✅ 已修复 |
| #5 | `busy_timeout` PRAGMA 不生效 | ✅ 已修复 |
| #6 | `get_conn()` 阻塞式等待 | ✅ 已修复 |

---

*由齐活林（Qi）交付总监整理，基于对全部 26 个 Rust 源文件和 7 个核心 Dart 文件的审查。*
