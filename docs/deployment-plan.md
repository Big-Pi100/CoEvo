# CoEvo 部署方案 V4 — APK 全端部署

> MVP 架构：APK 内嵌 Rust 后端，VPS 仅作 LLM 代理网关
> 讨论日期: 2026-05-12

---

## 一、架构

```
用户手机 (APK)
┌──────────────────────────────────────┐
│ Flutter App                           │
│   ↓ HTTP localhost:8080              │
│ Rust 后端 (嵌入 APK 内)               │
│  ├── SQLite → data/data/coevo/coevo.db│
│  ├── 用户认证 (本地注册/登录)         │
│  ├── 对话引擎 (不含 LLM 调用部分)     │
│  ├── 概念提取                         │
│  ├── 卡片管理与 FSRS 复习调度         │
│  ├── 成就检测                         │
│  └── 头像本地存储                     │
│       └── 需调用 LLM 时 ──HTTPS──→   │
└──────────────────────────────────────┘
                    │
                    ▼
VPS (极简 LLM 代理网关)
┌──────────────────────────────────────┐
│ 一个极简 Rust 二进制                   │
│                                      │
│ POST /api/chat                       │
│  1. 验证 API Key (请求头)            │
│  2. 查 subscription_expires          │
│  3. 有效 → 转发 DeepSeek             │
│  4. 过期 → 403 + "subscription_err"  │
│                                      │
│ POST /api/admin/set-subscription     │
│  (管理员密钥保护)                     │
│                                      │
│ SQLite: /opt/coevo-gateway/users.db  │
│  ├── api_keys (key → user_id)        │
│  └── subscriptions (user_id → expires)│
└──────────────────────────────────────┘
```

---

## 二、和当前代码的关系

| 组件 | 当前形态 | APK 方案 | 改动量 |
|:--|:--|:--|:-:|
| `chat_engine` | Rust crate | 复用，LLM 调用改为指向 VPS | 小 |
| `card_engine` | Rust crate | 复用 | 无 |
| `growth_engine` | Rust crate | 复用 | 无 |
| `api_server/routes` | HTTP 路由 | 大部分保留（本地 localhost） | 小 |
| `api_server/ws` | WebSocket | **删除**，对话不走 WS | 中 |
| `api_server/auth` | HTTP 接口 | 保留，本地 DB 注册/登录 | 小 |
| `api_server/db_pool` | 文件路径 | 路径改为 Android data dir | 小 |
| Flutter chat_screen | HTTP+WS | **改为纯 HTTP**，去掉 WS | 中 |
| VPS 服务 | — | **新建** LLM 代理网关 | 新写 |

---

## 三、APK 内的 Rust 运行方式

最简方案：Rust 在 APK 内启动一个 **localhost HTTP 服务器**。

```
APK 启动 →
  Rust 在后台线程启动 axum → 监听 127.0.0.1:8080
  Flutter 照常用 http://localhost:8080 调用

  优势：Flutter 端零改动
  劣势：多一个本地端口（对用户无感）
```

编译方式：

```bash
# 1. 安装 Android NDK + cargo-ndk
rustup target add aarch64-linux-android
cargo install cargo-ndk

# 2. 编译 Rust 到 Android
cd backend
cargo ndk -t arm64-v8a build --release

# 3. 产物: target/aarch64-linux-android/release/libcoevo_backend.so
# 4. Flutter 通过 dart:ffi 加载 .so，启动主函数
```

---

## 四、VPS 网关实现

极简 Rust 二进制，依赖：`axum + reqwest + rusqlite`（现有 workspace 已有）

```rust
// 网关核心逻辑 ≈ 80 行
POST /api/chat
  body: {messages, model, ...}
  header: X-API-Key: user_key

  1. 查 sqlite: SELECT * FROM api_keys WHERE key = ?
     → 不存在 => 401
  2. 查订阅: SELECT value FROM users_preferences WHERE key='subscription_expires'
     → 过期 => 403 json({"error":"subscription_expired"})
  3. 转发 reqwest 到 DeepSeek
  4. 流式返回
```

### VPS 网关管理

```bash
# 管理员操作：添加用户 API Key + 订阅
sqlite3 /opt/coevo-gateway/users.db "
INSERT INTO api_keys (api_key, user_id) VALUES ('sk-user-xxx', 'user_abc');
INSERT INTO user_preferences (user_id, key, value)
    VALUES ('user_abc', 'subscription_expires', '2027-12-31');
"
```

或简单 API：

```bash
curl -H "X-Admin-Key: admin-secret" \
  -d '{"user_id":"user_abc","expires":"2027-12-31"}' \
  https://coevo-gateway.app/api/admin/set-subscription
```

---

## 五、实施步骤

| 步骤 | 内容 | 预估 |
|:--|:--|:-:|
| 1 | 新建 `coevo_gateway` crate（或独立项目），实现 LLM 代理 | 1 天 |
| 2 | `config.rs` 改 LLM base_url 指向 VPS 网关 | 10 分钟 |
| 3 | 去掉 `ws.rs` 和 WS 相关代码，对话改为纯 HTTP | 1 天 |
| 4 | 配置 cargo-ndk + Android NDK，编译 Rust 为 `.so` | 1 天 |
| 5 | Flutter 端通过 `dart:ffi` 加载 `.so` 并启动 localhost 服务器 | 1 天 |
| 6 | 适配数据库路径为 Android data dir | 半天 |
| 7 | `flutter build apk --release` 验证 | 半天 |
| **合计** | | **~5 天** |

---

## 六、MVP 版本边界

| 做 | 不做 |
|:--|:--|
| Rust 嵌入 APK 本地运行 | 应用商店上架 |
| 对话改为纯 HTTP | 离线模式（无网络时不能调 LLM） |
| LLM 网关订阅拦截 | 支付系统接入 |
| 管理员手动设置订阅 | 证书过期自动续期 |
| Android arm64 | iOS / x86 模拟器 |

---

*文档: docs/deployment-plan.md · 版本: v4*
