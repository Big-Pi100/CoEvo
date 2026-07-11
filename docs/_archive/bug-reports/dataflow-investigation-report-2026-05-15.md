# CoEvo 前端-后端数据流深度调查报告

> **调查日期**：2026-05-15
> **调查范围**：Flutter 前端 ↔ Rust 后端 全链路数据流
> **问题触发**：test4/test123456 登录后 admin 搜不到用户、profile 无订阅、chat 无法对话、历史加载缓慢

---

## TL;DR

**根因是 Admin 错误处理链路断裂**。订阅需由管理员手动激活是产品的线下推广设计（非缺陷），但 Admin 页面存在两处关键 Bug：

1. **后端**：鉴权失败返回 HTTP 200（应为 401）
2. **前端**：不检查响应体中的 `error` 字段，鉴权失败被误解为"无搜索结果"

两者叠加形成**死锁**：管理员搜不到用户 → 无法激活订阅 → Chat 不可用。订阅检查本身功能正确，但被 Admin 的错误处理阻断。

---

## 一、问题全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        数据流问题全景                                 │
│                                                                     │
│  test4 登录 ──✅──→ AuthState (userId + token)                       │
│       │                                                             │
│       ├── Admin 搜 "test4" ──🔴──→ BIG#1+#2: 鉴权失败误显为"无结果" │
│       │                                                             │
│       ├── Profile ──✅──→  "未激活"（设计如此，线下推广模式）          │
│       │                                                             │
│       ├── Chat WS ──✅──→  订阅检查拒绝（功能正确，但被 Admin Bug 阻断）│
│       │                                                             │
│       └── History API ──🟡──→ 能加载但慢 (auth retry loop + 竞态)     │
│                                                                     │
│  死锁成因：Admin 错误处理 Bug → 管理员无法激活订阅 → Chat 不可用       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 二、问题 1：Admin 管理页搜不到 test4 用户

### 2.1 Admin 页面入口机制

Admin 页面采用**纯前端门禁**——密钥输入阶段不做任何后端校验：

```dart
// admin_screen.dart:136-138
onPressed: () {
    final key = _keyController.text.trim();
    if (key.isNotEmpty) setState(() => _adminKey = key);  // ← 任何非空字符串即可通过！
},
```

这意味着：**无论输入什么 key，都能进入管理后台的管理界面**。真正的鉴权只在搜索时发生。

### 2.2 数据流追踪

```
Flutter Admin Screen                    Rust Backend
─────────────────                      ────────────
用户输入 admin key: "xxx"
    │
    ▼
GET /api/admin/users?q=test4       →   headers.get("x-admin-key")
X-Admin-Key: xxx                       vs env("COEVO_ADMIN_KEY")
                                        │
                                    ┌───┴───┐
                                    │ 匹配？  │
                                    ├───┬───┤
                                   YES  NO (或未配置)
                                    │    │
                                    ▼    ▼
                              SQL 查询   {"error":"unauthorized"}
                              返回用户   HTTP 200 ← ⚠️ 始终200！
```

### 2.3 关键代码分析

**后端** (`routes.rs` — admin_users_handler)：

```rust
let admin_key = std::env::var("COEVO_ADMIN_KEY").unwrap_or_default();
let got = headers.get("x-admin-key").and_then(|v| v.to_str().ok()).unwrap_or("");

if admin_key.is_empty() || got != admin_key {
    return Json(json!({"error": "unauthorized"}));  // ⚠️ HTTP 200，不是 401！
}
```

**BIG #1**：鉴权失败返回 HTTP 200。HTTP 200 本应表示"成功"，但此处 payload 却是错误信息，违反 HTTP 语义。

**前端** (`admin_screen.dart:21-40`)：

```dart
Future<void> _search() async {
    final resp = await http.get(uri, headers: {'X-Admin-Key': _adminKey!});
    if (resp.statusCode != 200) {  // ← 后端永远返回 200，此分支永远不会进入
        setState(() { _error = '查询失败 (${resp.statusCode})'; });
        return;
    }
    final data = jsonDecode(resp.body);
    final users = (data['users'] as List?)?.cast<Map>() ?? [];  // ← 未检查 data['error']
    setState(() { _users = users; });  // ← 鉴权失败时 users = []
}
```

**BIG #2**：前端仅凭 HTTP 状态码判断成败，不检查响应体中 `error` 字段。鉴权失败时 `data['users']` 不存在，`users` 变为空列表。

### 2.4 用户体验路径

```
用户打开 /admin
  → 看到"输入管理员密钥"页面
  → 输入任意非空字符串（如"123"）→ 进入后台界面 ✅
  → 搜索框输入"test4"→ 点击"查找"
  → 后端校验 X-Admin-Key: "123" ≠ COEVO_ADMIN_KEY → 返回 HTTP 200 + {"error":"unauthorized"}
  → 前端：statusCode==200 → 不报错 → data['users']==null → _users=[]
  → UI 显示："输入用户名或 ID 搜索"（看起来像"没搜到"）
  → 用户困惑："明明有 test4 用户，为什么搜不到？"
```

**死锁形成**：搜不到 → 无法设置订阅 → Chat 不可用 → 用户无法使用产品。

### 2.5 根因判定

| 层级 | 问题 | 严重度 |
|------|------|--------|
| 后端 | 鉴权失败返回 HTTP 200 而非 401 | 🔴 P0 |
| 前端 | 不检查 `data['error']`，空列表无差异化提示 | 🔴 P0 |
| 交互 | 密钥输入页无任何提示（应告知正确 key 的获取方式） | 🟡 P1 |

### 2.6 修复建议

```dart
// admin_screen.dart _search() 方法中添加：
final data = jsonDecode(resp.body) as Map<String, dynamic>;
if (data.containsKey('error')) {
    setState(() {
        _error = data['error'] == 'unauthorized'
            ? '管理员密钥错误，请重新输入'
            : '查询失败: ${data['error']}';
        _isLoading = false;
    });
    return;
}
```

```rust
// routes.rs admin_users_handler 中：
// 鉴权失败应返回 HTTP 401
if admin_key.is_empty() || got != admin_key {
    return (StatusCode::UNAUTHORIZED,
        Json(json!({"error": "unauthorized"}))).into_response();
}
```

同时建议在 Admin 密钥输入页添加提示：`"请联系开发人员获取管理员密钥"` 或展示 `.env` 中 key 的线索。

---

## 三、问题 2：Profile 显示"没有订阅"

### 3.1 行为定性

**这不是 Bug，而是产品设计**。CoEvo 采用线下推广模式，用户订阅由管理员手动激活——新用户注册后默认无 `subscription_expires` 记录，Profile 页展示"未激活"是正确的预期行为。

### 3.2 数据流追踪（验证正确性）

```
Profile Screen._load()                    后端 API
────────────────────                      ───────
Future.wait([
    client.getProfile(),          →  GET /api/user/{id}/profile
    client.getLearningReport(),   →  GET /api/user/{id}/learning-report
    client.getActivity(days:90),  →  GET /api/user/{id}/activity?days=90
    client.getWeeklyReport(),     →  GET /api/user/{id}/weekly-report
    client.getPreferences(),      →  GET /api/user/{id}/preferences
])
    │
    ▼
serverPrefs['subscription_expires']  →  null (新用户无此记录)
    │
    ▼
_subscriptionExpires = null
    │
    ▼
_buildSubscriptionCard():
  isActivated = false  →  "未激活 — 请联系服务人员开通"
```

### 3.3 结论

数据流正确：后端正确查询、前端正确渲染。Profile 显示"未激活"是线下推广模式的预期行为——用户需要联系服务人员（管理员）开通订阅。当前问题的实质是 Admin 页面无法正常工作导致管理员无法完成激活操作。

---

## 四、问题 3：Chat 无法连接对话

### 4.1 订阅检查逻辑确认（功能正确）

WebSocket 处理器的订阅检查逻辑是**正确的产品行为**：

```
Flutter Chat Screen                         Rust WS Handler
─────────────────                          ─────────────────
_sendMessage()
    │
    ▼
ChatClient.streamChat(text)
    │
    ▼
WebSocketChannel.connect("ws://localhost:8080/ws")   →  WS 连接建立
    │
    ▼
channel.sink.add(jsonEncode({
    user_id, conversation_id,                RawChatRequest {
    message, token                               user_id, conversation_id,
}))                                               message, token
    │                                               │
    │                                     ┌─ 关卡1: Token验证 ───┐
    │                                     │ verify_token(conn,   │
    │                                     │   user_id, token)    │
    │                                     │   ✅ test4 验证通过   │
    │                                     └──────────────────────┘
    │                                               │
    │                                     ┌─ 关卡2: 订阅检查 ───┐
    │                                     │ SELECT value FROM   │
    │                                     │ user_preferences    │
    │                                     │ WHERE key =         │
    │                                     │ 'subscription_      │
    │                                     │ expires'            │
    │                                     │   → None (无记录)   │
    │                                     │   → expired = true  │
    │                                     └──────────────────────┘
    │                                               │
    │                                     {"type":"error",
    │  ← ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   "content":"subscription_
    │                                      required"}
    ▼
_handleWsEvent(event.type == 'error')
    │
    ├── content == "subscription_required"
    │   → _subscriptionRequired = true
    │   → _showSubscriptionDialog("需要激活")
    │
    └── dialog: "请联系你的服务人员续费。续费后刷新页面即可恢复使用。"
        → 用户只能点"我知道了"关闭 → 死胡同！
```

### 4.2 关键代码

**后端** (`ws.rs:81-115`)：

```rust
// 检查订阅状态
let expires: Option<String> = conn.query_row(
    "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
    rusqlite::params![chat_req.user_id],
    |row| row.get(0),
).ok().flatten();

let expired = match &expires {
    Some(e) => { /* 解析日期，判断是否过期 */ },
    None => true,   // ⚠️ 无记录 = 未付费 → 直接拒绝！
};

if expired {
    let msg = if expires.is_some() {
        "subscription_expired".to_string()
    } else {
        "subscription_required".to_string()
    };
    ws.send(Message::Text(json!({"type":"error","content": msg}))).await;
    continue;  // ← 跳过 LLM 调用，消息不会被处理
}
```

**分析**：`None => true` 是产品设计——线下推广模式下，用户必须由管理员激活。此逻辑本身正确，但在当前场景下，由于 Admin 页面无法正常使用（见问题 1），管理员无法完成激活操作，导致 Chat 不可用。**这不是订阅检查的 Bug，而是 Admin 错误处理 Bug 的连锁反应。**

### 4.3 前端处理

**前端** (`chat_screen.dart:450-473`)：

```dart
case 'error':
    if (event.content == 'subscription_expired') {
        // 显示"订阅已到期"弹窗
    } else if (event.content == 'subscription_required') {
        // 显示"需要激活"弹窗
    }
```

弹窗只有一个"我知道了"按钮，关闭后不执行任何操作。没有引导用户如何激活订阅。而且弹窗设置 `barrierDismissible: false`，用户无法忽略。

### 4.4 REST Chat 端点缺少订阅检查（不一致）

`POST /api/chat` (非流式) 仅做了 Bearer token 鉴权，未检查订阅：

```rust
async fn chat_handler(headers: HeaderMap, Json(input): Json<ChatInput>) -> Json<Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return Json(json!({"error": e}));
    }
    // ⚠️ 没有订阅检查！只用 Bearer token 鉴权
    // ... LLM 调用 ...
}
```

**BIG #3**（原 BIG #4）：REST `/api/chat` 端点**不检查订阅状态**，而 WebSocket `/ws` 端点**检查订阅状态**。两者行为不一致——如果用户通过 REST 方式发送消息，可以绕过订阅检查。目前 Flutter 前端优先使用 WebSocket（`streamChat`），所以实际被拦截，但这是一个安全缺口，应在 REST 端点也加入订阅检查以保证一致性。

---

## 四、问题 4：历史对话加载缓慢

### 4.4 数据流追踪

```dart
// chat_screen.dart _init() 方法
Future<void> _init() async {
    // Step 1: 等待 auth restore (最多 3 秒)
    for (int retry = 0; retry < 20; retry++) {
        if (auth.userId != null) break;
        await Future.delayed(const Duration(milliseconds: 150));
    }

    // Step 2: 初始化 ChatClient
    _client = ChatClient(userId: userId, conversationId: _convId, token: token);

    // Step 3: 加载学习计划 (FIRE-AND-FORGET，不 await！)
    _loadPlan();

    // Step 4: 检查订阅 (FIRE-AND-FORGET，不 await！)
    _checkSubscription();

    // Step 5: 加载历史 (阻塞等待)
    final history = await _client!.getConversationTurns(_convId);
    // ... 处理历史消息 ...

    // Step 6: 标记初始化完成
    setState(() => _isInitializing = false);
}
```

### 4.5 慢的原因分析

| 阶段 | 耗时 | 问题 |
|------|------|------|
| Auth restore retry | 0~3000ms | 正常情况 auth 已恢复，但最坏情况阻塞 3 秒 |
| `getConversationTurns` | 取决于数据量 | 每次加载最多 50 条，`ApiConfig.requestTimeout` = 10s |
| `_loadPlan()` | 并发，不阻塞 | 但 setState 可能与 _init 的 setState 竞态 |
| `_checkSubscription()` | 并发，不阻塞 | 同上，且可能触发额外的 rebuild |

**BIG #5 — 竞态条件**：

```dart
// _init() 中
_loadPlan();           // fire-and-forget → 后续 setState
_checkSubscription();  // fire-and-forget → 后续 setState
final history = await _client!.getConversationTurns(_convId);
setState(() => _isInitializing = false);  // ← 可能与上面两个 setState 竞态
```

`_loadPlan()` 和 `_checkSubscription()` 在后台完成后会调用 `setState()`。如果它们在 `_init()` 的 `setState(() => _isInitializing = false)` 之后触发，会导致 UI 在渲染完成后又发生重建（订阅横幅突然出现、计划面板突然加载）。

**BIG #6 — 历史 API 无鉴权**：

```rust
// routes.rs history_handler
async fn history_handler(Query(query): Query<HistoryQuery>) -> Json<Value> {
    // ⚠️ 没有 verify_auth 调用！任何人都可以读取任何用户的历史！
    let conn = crate::db_pool::get_conn();
    // ... SQL 查询 ...
}
```

历史 API 不进行 token 鉴权，这是一个安全漏洞。但对当前问题不是主要原因。

---

## 五、附加发现的数据流问题

### 5.1 WebSocket 重连逻辑缺陷

```dart
// chat_screen.dart _sendMessage()
if (_session == null) {
    _session = _client!.streamChat(text);
    _sessionSub = _session!.events.listen(_handleWsEvent, ...);
} else {
    _session!.send(auth.userId ?? '', _convId, text);
}
```

**问题**：如果 WebSocket 连接在空闲期间被服务端关闭（无心跳机制），下次 `_session!.send()` 会抛出异常。代码有 catch 并重建的逻辑，但 `_session.send()` 不等待确认，消息可能丢失。

### 5.2 Token 仅在首条消息中发送

```dart
// chat_client.dart streamChat() 
final req = jsonEncode(ChatRequest(..., token: token).toJson());
channel.sink.add(req);
```

```dart
// WsChatSession.send() — 后续消息不传 token
void send(String userId, String conversationId, String message) {
    _channel.sink.add(jsonEncode(ChatRequest(
      userId: userId, conversationId: conversationId, message: message,
      // ⚠️ token 未传入！
    ).toJson()));
}
```

这个设计是合理的（token 只需验证一次，`token_verified` 标志位保持），但 `ChatRequest.toJson()` 中 `token` 为 null 时不序列化，与后端 `Option<String>` 兼容。

### 5.3 user_preferences 表缺少索引

```sql
-- 当前表结构（main.rs SCHEMA_SQL）
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

每次都按 `user_id + key` 查询，有复合主键索引，查询效率没有问题。

### 5.4 ChatScreen._checkSubscription 时机问题

订阅检查在 `_init()` 中作为 fire-and-forget 启动。用户可能在 `_checkSubscription()` 完成之前就发送消息。此时：
- 前端 `_subscriptionChecked` 为 false，不显示横幅
- 用户点击发送 → WebSocket 连接到后端 → 后端检查订阅 → 拒绝
- 用户看到"需要激活"弹窗
- 同时 `_checkSubscription()` 完成 → 横幅出现

这造成了重复提示（弹窗 + 横幅）。

---

## 六、根本原因总结

```
┌──────────────────────────────────────────────────────┐
│               Admin 错误处理链路断裂                   │
│                                                      │
│  死锁形成路径:                                        │
│                                                      │
│  后端 BIG #1: 鉴权失败返回 HTTP 200                   │
│       +                                              │
│  前端 BIG #2: 不检查 error 字段                       │
│       =                                              │
│  管理员误以为"搜不到用户"                              │
│       →                                              │
│  无法设置 subscription_expires                        │
│       →                                              │
│  WS 订阅检查 (功能正确) 拦截所有消息                    │
│       →                                              │
│  Chat 不可用                                         │
│                                                      │
│  注：订阅模型（线下激活）是产品设计，非缺陷               │
└──────────────────────────────────────────────────────┘
```

| 严重度 | 编号 | 问题 | 类型 | 影响 |
|--------|------|------|------|------|
| 🔴 P0 | BIG-1 | Admin 鉴权失败返回 HTTP 200（应为 401） | 后端 Bug | 前端无法区分鉴权失败和空结果 |
| 🔴 P0 | BIG-2 | Admin 前端不检查 `data['error']` | 前端 Bug | 鉴权失败被误解为"搜不到" |
| 🔴 P0 | BIG-3 | REST /api/chat 缺订阅检查，WS /ws 有检查 | 不一致 | 可通过 REST 绕过订阅 |
| 🟡 P1 | BIG-4 | _init() 中 fire-and-forget 竞态 | 前端 Bug | UI 闪烁，重复渲染 |
| 🟡 P1 | BIG-5 | 历史 API 无鉴权 | 安全缺口 | 任意用户可读取任意对话历史 |
| 🟢 P2 | — | Auth restore retry 最多 3 秒 | 性能 | 冷启动时额外等待 |

---

## 七、修复方案

### 7.1 紧急修复（解除死锁）

在数据库中直接为 test4 设置订阅到期日：

```bash
cd backend
sqlite3 data/coevo.db "INSERT INTO user_preferences (user_id, key, value, updated_at) VALUES ('<test4的user_id>', 'subscription_expires', '2027-12-31T00:00:00Z', datetime('now'));"
```

获取 test4 的 user_id：
```bash
sqlite3 data/coevo.db "SELECT id, username FROM users WHERE username='test4';"
```

### 7.2 短中期修复

1. **Admin 鉴权错误码**：返回 HTTP 401 而非 200
2. **Admin 前端错误提示**：检查 `data['error']` 并给用户明确提示（"密钥错误"而非"无结果"）
3. **Admin 密钥页面提示**：添加提示信息告知密钥获取方式
4. **Chat 订阅检查统一**：REST /api/chat 也加入订阅检查，与 WS 保持一致

### 7.3 长期优化

1. **前端 _init() 竞态修复**：使用 `await` 或 `Completer` 统一管理异步初始化
2. **WebSocket 心跳**：添加 ping/pong 保持连接存活
3. **历史 API 鉴权**：添加 Bearer token 验证
4. **订阅状态缓存**：登录时一次性获取订阅状态，避免每次 WS 连接都查询

---

## 八、数据流校验清单

| 数据流路径 | 鉴权 | 订阅检查 | 错误处理 | 状态 |
|-----------|------|---------|---------|------|
| POST /api/auth/login | N/A | N/A | ✅ 正确 | ✅ |
| POST /api/auth/verify | ✅ DB | N/A | ✅ 正确 | ✅ |
| WS /ws | ✅ DB token | ✅ 订阅 | ✅ 发送 error | ✅ 功能正确（设计如此） |
| POST /api/chat | ✅ Bearer | ❌ 缺失（应与 WS 一致） | ✅ | 🔴 与 WS 不一致，可绕过订阅 |
| GET /api/history | ❌ 缺失 | ❌ | — | 🔴 无鉴权 |
| GET /api/user/:id/profile | ❌ 缺失 | N/A | ✅ | 🟡 无鉴权 |
| GET /api/admin/users | ✅ X-Admin-Key | N/A | 🔴 HTTP 200 | 🔴 错误码不正确 |
| PUT /api/user/:id/preferences | ❌ 缺失 | N/A | ✅ | 🟡 无鉴权 |

---

*报告版本: V1.1 (修正版)*
*修订内容：Admin 前端门禁机制澄清、订阅模型从"缺陷"重新定性为"产品设计"、修复方案移除与设计冲突的"默认试用期"建议*
*调查者: 齐活林 (Delivery Director)*
*调查工具: 静态代码分析 (Flutter Dart + Rust Axum 全链路)*
