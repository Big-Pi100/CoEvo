# 部署、分发与付费方案

> **前提**: 当前为单人 SaaS（单租户 SQLite + Flutter Web）
> **目标**: 最小成本启动 → 验证付费意愿 → 按需升级架构

---

## 一、架构现状与部署约束

| 组件 | 当前 | 部署方案 |
|:--|:--|:--|
| **前端** | Flutter 3.x (Web) | 静态文件（Nginx / CDN） |
| **后端** | Rust axum (单进程, 含 SQLite) | 单台 VPS 或 Docker |
| **数据库** | SQLite (文件嵌入后端进程) | 随后端部署，定期备份 |
| **WebSocket** | 后端直连 8080 端口 | 需要 WebSocket 代理支持 |
| **LLM API** | OpenAI 兼容接口 | 后端调用，API Key 放环境变量 |

---

## 二、部署方案

### 2.1 MVP 架构（一票制，单机部署）

```
用户浏览器                    VPS (2C4G, ~$10/月)
┌──────┐    ┌──────────────────────────────────┐
│Flutter│───→│  Nginx (反代 + TLS + WS 代理)     │
│  Web  │    │  ┌──────┐  ┌──────────────────┐  │
└──────┘    │  │cdn/  │  │coevo_server       │  │
            │  │*.js  │  │(Rust 二进制)       │  │
            │  │*.wasm│  │  + SQLite          │  │
            │  └──────┘  │  + data/avatars/   │  │
            │            └──────────────────┘  │
            └──────────────────────────────────┘
                              ↓
                     ┌──────────────────┐
                     │  OpenAI API       │
                     └──────────────────┘
```

**Nginx 配置要点**：

```nginx
server {
    listen 443 ssl;
    server_name coevo.app;

    # 前端静态文件
    root /var/www/coevo;
    index index.html;

    # REST API 代理
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    # WebSocket 代理
    location /ws {
        proxy_pass http://127.0.0.1:8080/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 头像文件缓存
    location /api/user/*/avatar {
        proxy_pass http://127.0.0.1:8080;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
}
```

**部署步骤**：

```bash
# 1. 构建前端
cd app && flutter build web --release

# 2. 构建后端
cd backend && cargo build --release

# 3. 将产物推送到 VPS
scp -r app/build/web root@vps:/var/www/coevo/
scp backend/target/release/coevo_backend root@vps:/opt/coevo/

# 4. 启动后端（systemd 守护）
# /etc/systemd/system/coevo.service
[Unit]
Description=CoEvo Learning API
After=network.target

[Service]
Type=simple
User=coevo
WorkingDirectory=/opt/coevo
Environment=LLM_API_KEY=sk-xxx
Environment=LLM_BASE_URL=https://api.openai.com/v1
ExecStart=/opt/coevo/coevo_backend
Restart=always

[Install]
WantedBy=multi-user.target
```

### 2.2 成本估算（MVP）

| 项目 | 月成本 | 说明 |
|:--|:--|:-:|
| VPS (2C4G) | ~$10 | DigitalOcean / 阿里云 / 腾讯云 |
| 域名 | ~$1 | coevo.app / coevo.cn |
| LLM API（10用户×每天50轮） | ~$30 | GPT-4o-mini 约 $0.15/1M token |
| SSL 证书 | 免费 | Let's Encrypt / 云厂商免费证书 |
| **合计** | **~$41/月** | |

---

## 三、付费方案

### 3.1 核心假设

- **单人 SaaS，无多租户**：当前 SQLite 单库
- **主力成本在 LLM API 调用**：后端按 token 计费
- **付费意愿验证点**：用户是否愿意为 AI 驱动的学习方法付费

### 3.2 定价策略

```
免费层（体验核心功能）
┌──────────────────────────────────────┐
│ ✅ 每日 20 轮 AI 对话                  │
│ ✅ 每次对话提取 ≤3 个概念              │
│ ✅ 每日复习 ≤10 张卡片                 │
│ ✅ TTS 朗读                           │
│ ❌ 学习计划                            │
│ ❌ 学习报告 / 日历 / 成就              │
└──────────────────────────────────────┘

Pro 层 ¥29/月（核心价值）
┌──────────────────────────────────────┐
│ ✅ 无限对话                            │
│ ✅ 无限概念提取 + 制卡                 │
│ ✅ 无限复习 + 考试                     │
│ ✅ 学习计划 + 子任务栈                  │
│ ✅ 学习报告 + 每日日志                  │
│ ✅ 优先使用更强 LLM 模型               │
└──────────────────────────────────────┘
```

### 3.3 计费逻辑实现（后端）

**方案 A（MVP）：简单开关 + 软限制**

在 `user_preferences` 表中存一个 key：

```
user_preferences: user_id="xxx", key="subscription_tier", value="free" | "pro"
```

API 层检查（`auth_middleware.rs` 或各 handler 前置）：

```rust
fn check_subscription(conn: &Connection, user_id: &str) -> SubscriptionTier {
    let tier: Option<String> = conn.query_row(
        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_tier'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).ok().flatten();
    match tier.as_deref() {
        Some("pro") => SubscriptionTier::Pro,
        _ => SubscriptionTier::Free,
    }
}
```

受限制的端点检查 tiers：

```rust
fn enforce_daily_limit(conn: &Connection, user_id: &str, limit: i64) -> bool {
    if check_subscription(conn, user_id) == SubscriptionTier::Pro {
        return true; // Pro 无限制
    }
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM conversation_turns
         WHERE conversation_id IN (SELECT id FROM conversations WHERE user_id = ?1)
         AND created_at LIKE ?2",
        rusqlite::params![user_id, format!("{}%", today)],
        |row| row.get(0),
    ).unwrap_or(0);
    count < limit
}
```

**方案 B（稳定后）：真实支付 + 密钥下发**

```
用户 → 支付（Stripe/微信支付）→ 获取 license_key
     → 输入到应用 → 验证 license_key → user_preferences 写入 pro
```

### 3.4 计费点矩阵

| 功能点 | Free | Pro | 技术限制方式 |
|:--|:--:|:--:|:--|
| AI 对话轮次/天 | 20 | ∞ | `conversation_turns` 日计数 |
| 概念提取/对话 | ≤3 | ∞ | `cards` 批次计数 |
| 复习卡片/天 | ≤10 | ∞ | `review_log` 日计数 |
| 学习计划 | ❌ | ✅ | 前端隐藏 + API 403 |
| 学习日历 | ❌ | ✅ | 前端隐藏 + API 403 |
| 每日日志 | ❌ | ✅ | 前端隐藏 |
| TTS 朗读 | ✅ | ✅ | 不限 |
| 头像上传 | ✅ | ✅ | 不限 |

---

## 四、分发渠道

### 4.1 Web（首选，零分发成本）

```
用户 → 浏览器打开 https://coevo.app → PWA 可安装到桌面
       ↓
Flutter Web 构建产物 ≈ 2MB (gzip)
首屏加载 ≈ 1.5s (CDN)
```

**PWA 配置**（`manifest.json` + Service Worker 内置）：

```json
{
  "name": "刻意进化学习",
  "short_name": "CoEvo",
  "display": "standalone",
  "start_url": "/",
  "icons": [{ "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" }]
}
```

**优点**：无需应用商店审核，更新即部署，用户零安装
**缺点**：无法使用手机原生推送通知

### 4.2 小程序（可选增量渠道）

```
微信 / 支付宝小程序
  → 分包加载 ≈ 500KB 核心包
  → 需适配小程序的 WXML 组件库
  → 支付通道可直接用微信支付
  → 推送通知天然支持
```

**转化成本**：前端核心逻辑重写为小程序 DSL，约 1 周工作量。

### 4.3 APK / IPA（长期方向）

```
Flutter 编译 → Android APK / iOS IPA
  → 本地 SQLite 支持离线复习
  → 原生推送通知
  → 应用商店曝光
```

**转化成本**：`flutter build apk/ios` 即可，当前代码兼容。

---

## 五、阶段规划

### Phase A（现在 — 1 周）" 发布 MVP "

| 任务 | 说明 |
|:--|:--|
| **VPS 搭建** | 购买域名+VPS，配置 Nginx+TLS |
| **自动化部署脚本** | Makefile + rsync 一键推送 |
| **环境变量化** | LLM API Key、Base URL 从环境变量读取 |
| **PWA 配置** | manifest + Service Worker + 应用图标 |
| **免费/Pro 开关** | 后端 `user_preferences` 软限制（3个限频点） |
| **种子用户邀请** | 管理员手动设置 subscription_tier=pro |

### Phase B（1-2 周）" 支付接入 "

| 任务 | 说明 |
|:--|:--|
| **支付对接** | 微信支付 / Stripe |
| **license_key 生成+验证** | 购买后下发唯一码 |
| **用户自助订阅页面** | 前端展示定价 + 输入激活码 |
| **使用量仪表盘** | 后端统计 + 前端显示剩余次数 |

### Phase C（按需）" 多端扩展 "

| 任务 | 说明 |
|:--|:--|
| **Flutter 编译 APK** | Android 版本发布 |
| **小程序适配** | 微信小程序入口 |
| **多租户 PostgreSQL 迁移** | 当前 SQLite 单库上限 ≈ 100 用户 |

---

## 六、风险与缓解

| 风险 | 影响 | 缓解 |
|:--|:--|:--|
| SQLite 并发瓶颈 | 用户 > 50 时写入冲突 | Phase C 换 PostgreSQL |
| LLM API 成本失控 | 免费用户滥用 | 日限频 + 超限弹窗引导升级 |
| WebSocket 长连接 | 单进程连接数上限 | 上云时换 WebSocket Serverless / 轮询降级 |
| 国内访问 LLM API | 延迟高 + 被墙 | 支持配置国内 API 中转地址 |
| 用户数据隐私 | SQLite 文件含全部用户数据 | 全盘加密 + 定时异地备份 |

---

*版本: v1 · 2026-05-11*
*文档: docs/deployment-monetization-plan.md*
