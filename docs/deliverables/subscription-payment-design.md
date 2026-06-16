# CoEvo 订阅与支付系统设计文档

版本: v2.0 | 日期: 2026-06-15 | 更新: 消除所有硬编码套餐引用，数据流统一走 DB

---

## 1. 概述

CoEvo 当前通过 `user_preferences` 键值表管理订阅到期日（key=`subscription_expires`），无支付系统，订阅需管理员手动操作。本文档设计完整的用户自主订阅支付体系。

**铁律：不允许任何套餐 ID、时长、价格的硬编码。所有套餐数据必须从 `subscription_plans` 表查询。**

---

## 2. 数据库设计

### 2.1 subscription_plans（订阅套餐）

```sql
CREATE TABLE IF NOT EXISTS subscription_plans (
    id              TEXT PRIMARY KEY,         -- '30d', '365d', 'lifetime', 'free_trial'
    name            TEXT NOT NULL,            -- '月度会员', '年度会员', '终身会员', '新用户免费试用'
    duration_days   INTEGER,                  -- 30, 365, 3650(lifetime), 3(free_trial)
    price           INTEGER NOT NULL,         -- 分（20000=200元），0 表免费
    max_uses        INTEGER,                  -- 总库存上限（NULL=不限量）
    used_count      INTEGER DEFAULT 0,        -- 已售/已使用数
    available_from  TEXT,                     -- 开售时间（NULL=不限），ISO 8601
    available_until TEXT,                     -- 停售时间（NULL=不限），ISO 8601
    sort_order      INTEGER DEFAULT 0,
    is_active       INTEGER DEFAULT 1,        -- 手动上架/下架
    created_at      TEXT NOT NULL             -- ISO 8601
);
```

**套餐可用性检查（服务端统一逻辑）：**

```rust
fn is_plan_purchasable(plan: &PlanRow) -> bool {
    if plan.is_active != 1 { return false; }
    if let Some(max) = plan.max_uses {
        if plan.used_count >= max { return false; }
    }
    if let Some(from) = &plan.available_from {
        if now < from { return false; }
    }
    if let Some(until) = &plan.available_until {
        if now > until { return false; }
    }
    true
}
```

**初始化数据全部从 DB 插入，不允许代码硬编码：**

```sql
INSERT INTO subscription_plans
    (id, name, duration_days, price, max_uses, used_count, sort_order, is_active, created_at)
VALUES
    ('free_trial', '新用户免费试用', 3,    0,      NULL, 0, 0, 1, datetime('now')),
    ('30d',       '月度会员',       30,   20000, NULL, 0, 1, 1, datetime('now')),
    ('365d',      '年度会员',       365,  128000, NULL, 0, 2, 1, datetime('now')),
    ('lifetime',  '终身会员',       3650, 128000, 100,  0, 3, 1, datetime('now'));
```

### 2.2 payment_orders（支付订单）

```sql
CREATE TABLE IF NOT EXISTS payment_orders (
    id              TEXT PRIMARY KEY,        -- 商户订单号 out_trade_no
    user_id         TEXT NOT NULL,
    plan_id         TEXT NOT NULL,           -- 关联 subscription_plans.id
    amount          INTEGER NOT NULL,        -- 分
    currency        TEXT DEFAULT 'CNY',
    status          TEXT DEFAULT 'NOTPAY',   -- NOTPAY / SUCCESS / CLOSED / REFUND
    prepay_id       TEXT,
    transaction_id  TEXT,                    -- 微信支付单号
    paid_at         TEXT,
    created_at      TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX idx_payment_orders_status ON payment_orders(status);
```

### 2.3 subscription_audit_log（订阅操作审计）

```sql
CREATE TABLE IF NOT EXISTS subscription_audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    action          TEXT NOT NULL,           -- 'free_trial'/'pay'/'set'/'extend'/'batch'/'approve'
    operator_id     TEXT,                    -- 操作 admin，系统操作（注册/支付回调）为 NULL
    target_user_id  TEXT NOT NULL,
    old_expires     TEXT,
    new_expires     TEXT NOT NULL,
    amount          INTEGER DEFAULT 0,
    order_id        TEXT,                    -- 关联订单 ID
    note            TEXT,
    created_at      TEXT NOT NULL,
    FOREIGN KEY (target_user_id) REFERENCES users(id)
);

CREATE INDEX idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX idx_audit_created ON subscription_audit_log(created_at);
```

---

## 3. 到期日计算核心函数

**所有延期操作（支付成功、管理员设置、注册赠送）统一走此函数，从 DB 查套餐时长，不写死任何数字：**

```rust
/// 唯一延期入口 — 禁止直接写 user_preferences
fn extend_subscription(
    conn: &Connection,
    user_id: &str,
    plan_id: &str,              // 从 subscription_plans 表查 duration_days
    operator_id: Option<&str>,  // NULL = 系统自动
    order_id: Option<&str>,
    note: Option<&str>,
) -> Result<()> {
    // ❌ 不允许：match plan_id { "30d" => 30, "365d" => 365, ... }
    // ✅ 必须查表：
    let plan = conn.query_row(
        "SELECT duration_days, price FROM subscription_plans WHERE id = ?1",
        params![plan_id],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
    )?;

    let old_expires = get_current_expires(conn, user_id);
    let base = match old_expires {
        Some(d) if d > today => d,
        _ => today,
    };
    let new_expires = base + Duration::days(plan.duration_days);

    set_expires(conn, user_id, new_expires);           // 写 user_preferences
    increment_used_count(conn, plan_id);                // 更新已售数
    insert_audit_log(conn, action, operator_id, ...);   // 写审计日志
}
```

**要替换的 16 处直接读写点（全部改为调用 `extend_subscription`）：**

| # | 文件 | 行号 | 当前操作 | 改为 |
|---|------|------|---------|------|
| 1 | `auth.rs` | 113 | 硬编码写 3 天 | `extend_subscription(conn, user, "free_trial", ...)` |
| 2 | `routes.rs` | 1740 | SELECT | 保留（兼容旧 API） |
| 3 | `admin_handlers.rs` | 399 | INSERT OR REPLACE | 查套餐表 → `extend_subscription()` |
| 4 | `admin_handlers.rs` | 424 | 同上（延期） | 同上 |
| 5 | `admin_handlers.rs` | 466-469 | SELECT + INSERT（批量） | 循环调用 `extend_subscription()` |
| 6 | `admin_handlers.rs` | 511 | **硬编码 `"30d"=>30,"365d"=>365,"lifetime"=>3650`** | 查 `subscription_plans` 表 |
| 7 | `admin_handlers.rs` | 517-526 | SELECT + INSERT（审批通过） | `extend_subscription()` |
| 8 | `ws.rs` | 405 | SELECT | 保留只读（查 `user_preferences` 兼容） |

**关键的硬编码行 `admin_handlers.rs:511`：**

```rust
// ❌ 当前硬编码（必须删除）：
let days: i64 = match pkg.as_str() {
    "30d"=>30, "365d"=>365, "lifetime"=>3650,
    _ => pkg.trim_end_matches('d').parse().unwrap_or(30),
};

// ✅ 改为查表：
let (days, _price) = conn.query_row(
    "SELECT duration_days, price FROM subscription_plans WHERE id = ?1",
    params![pkg],
    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
)?;
```

---

## 4. API 路由设计

### 4.1 公开/用户端

| 方法 | 路径 | 功能 | 说明 |
|:----|:----|:----|:----|
| `GET` | `/api/plans` | 可用套餐列表 | **查 DB**，过滤 is_active + 库存 + 有效期 |
| `POST` | `/api/pay/native` | Native 下单 | 返回 `code_url` |
| `POST` | `/api/pay/jsapi` | JSAPI 下单 | 返回调起支付参数 |
| `GET` | `/api/pay/orders` | 我的订单列表 | 按 user_id 筛选 |
| `GET` | `/api/pay/orders/{id}` | 单笔订单状态 | 前端轮询用 |

### 4.2 微信回调

| 方法 | 路径 | 功能 |
|:----|:----|:----|
| `POST` | `/api/pay/notify` | 支付结果回调 → 验签 → `extend_subscription()` |

### 4.3 管理端

| 方法 | 路径 | 功能 | 权限 |
|:----|:----|:----|:----|
| `GET` | `/api/admin/plans` | 套餐列表（含 is_active/库存） | super/service |
| `POST` | `/api/admin/plans` | 新增套餐 | super |
| `PUT` | `/api/admin/plans/{id}` | 编辑套餐 | super |
| `DELETE` | `/api/admin/plans/{id}` | 下架套餐 (`is_active=0`) | super |
| `GET` | `/api/admin/pay/orders` | 全部订单（筛选） | super/service |
| `GET` | `/api/admin/users/{id}/audit-log` | 审计日志 | super/service |
| `PUT` | `/api/admin/users/{id}/subscription` | 设置到期日（现有，兼容） | super/service |
| `POST` | `/api/admin/users/{id}/quick-extend` | 快速延期（兼容） | super/service |

---

## 5. 数据流

### 5.1 用户自助支付

```
用户 → 前端打开订阅页
  ↓
前端 GET /api/plans → 渲染套餐卡片（查 DB，无硬编码）
  ↓
用户选套餐 → POST /api/pay/native { plan_id }
  ↓
后端 → 查 subscription_plans 获取 price
  → INSERT payment_orders (status=NOTPAY)
  → 调微信 Native 下单 API → 返回 code_url
  ↓
前端展示二维码 → 用户微信扫码支付
  ↓
微信 → POST /api/pay/notify（带签名）
  ↓
后端 → 验签 → UPDATE payment_orders (status=SUCCESS)
  → extend_subscription(user, plan_id)  ← 从 DB 查 duration_days
  → 返回 SUCCESS 给微信
  ↓
前端轮询 GET /api/pay/orders/{id} → 刷新订阅状态
```

### 5.2 管理员手动操作

```
管理员 → 选套餐/填日期 → PUT /api/admin/users/{id}/subscription { plan_id }
  ↓
后端 → 查 subscription_plans 获取 duration_days
  → extend_subscription(user, plan_id, operator_id=admin)
  → 写 audit_log（operator_id 记录操作人）
```

### 5.3 注册赠送试用

```
用户注册
  ↓
后端 → INSERT payment_orders (plan_id='free_trial', status='SUCCESS')
  → extend_subscription(user, 'free_trial', operator=NULL)
```

---

## 6. 前端订阅弹窗改造方案

**核心思路**：不逐个改文案，而是改 `GET /api/public/qrcode` 这个接口。

### 6.1 后端：`config_admin.rs` qrcode_handler

```rust
// 当前：返回管理员微信二维码图片
// 改为：返回可用套餐列表
async fn qrcode_handler() -> Json<Value> {
    let plans = conn.query_all(
        "SELECT id, name, price, duration_days, max_uses, used_count,
                available_from, available_until
         FROM subscription_plans
         WHERE is_active = 1
           AND (max_uses IS NULL OR used_count < max_uses)
           AND (available_from IS NULL OR available_from <= datetime('now'))
           AND (available_until IS NULL OR available_until > datetime('now'))
         ORDER BY sort_order ASC"
    )?;
    Json(json!({ "type": "subscribe", "plans": plans }))
}
```

### 6.2 前端：抽取 `SubscribePanel` 公共组件

所有弹窗里的 `Image(NetworkImage('/api/public/qrcode'))` 替换为：

```dart
// 复用组件：展示套餐列表 + 去支付按钮
Consumer(builder: (_, ref, __) {
  return FutureBuilder(
    future: http.get('${ApiConfig.baseUrl}/api/public/qrcode'),
    builder: (ctx, snap) {
      final plans = snap.data?['plans'] as List? ?? [];
      return Column(children: [
        for (final p in plans)
          PlanCard(plan: p, onPay: () => _createOrder(p['id'])),
      ]);
    },
  );
});
```

改动范围：

| 文件 | 当前 | 改为 |
|:----|:----|:----|
| `app.dart:274` | "联系管理员" + 二维码图 | 引用 `SubscribePanel` |
| `chat_screen.dart:516` | 同上 | 同上 |
| `review_screen.dart:783` | 同上 | 同上 |
| `config_admin.rs:437` | 返回二维码图片 | 返回套餐 JSON |

---

## 7. 部署配置（.env）

```env
# 微信支付
WECHAT_MCH_ID=1114056630
WECHAT_API_V3_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
WECHAT_APP_ID=wx0000000000000000
WECHAT_API_CLIENT_CERT_PATH=/opt/coevo/certs/apiclient_key.pem
WECHAT_PLATFORM_CERT_PATH=/opt/coevo/certs/wechatpay_platform_cert.pem
WECHAT_NOTIFY_URL=https://keyievolution.fun/api/pay/notify

# 注意：套餐定价不在此处配置，全部从 subscription_plans 表读取
```

---

## 8. 硬编码清理清单

| 位置 | 当前 | 改为 |
|:----|:----|:-----|
| `admin_handlers.rs:511` | `"30d"=>30,"365d"=>365,"lifetime"=>3650` | 查 `subscription_plans.duration_days` |
| `auth.rs:110` | `Duration::days(3)` 硬写 3 天 | 查 `free_trial` 套餐的 `duration_days` |
| 前端套餐卡片 | 无（当前无支付页） | 渲染 `GET /api/plans` 返回的数据 |
| `.env` 套餐价格 | 不存在 | 不走 .env，全部从 DB 读 |

---

## 9. 文件清单

### 后端新增（5 文件）

| 文件 | 内容 |
|:----|:----|
| `subscription.rs` | 套餐 CRUD + `extend_subscription()` 核心函数 |
| `payment_orders.rs` | 订单表 CRUD |
| `wechat_pay.rs` | 微信支付 API v3：签名、下单、回调验签 |
| `pay_handlers.rs` | 下单/回调/订单查询 handler |
| `plans_handlers.rs` | 套餐 handler（用户端 `GET /api/plans` + 管理端 CRUD） |

### 后端修改（5 文件）

| 文件 | 修改 |
|:----|:----|
| `lib.rs` | 注册新模块 |
| `routes.rs` | 注册新路由 |
| `schema.rs` | 建表 SQL（3 张新表）|
| `auth.rs:113` | 注册试用 → `extend_subscription(conn, uid, "free_trial", ...)` |
| `admin_handlers.rs:399-526` | 6 处读写点改为 `extend_subscription()`；511 行硬编码删掉 |
| `config_admin.rs:437` | `qrcode_handler` 改为返回套餐 JSON |

### 前端新增（3 文件）

| 文件 | 内容 |
|:----|:----|
| `widgets/subscribe_panel.dart` | 套餐列表公共组件 |
| `subscribe_screen.dart` | 完整订阅页 |
| `payment_result_screen.dart` | 支付结果页 |

### 前端修改（4 文件）

| 文件 | 修改 |
|:----|:----|
| `app.dart:274` | 二维码图 → `SubscribePanel` |
| `chat_screen.dart:516` | 同上 |
| `review_screen.dart:783` | 同上 |
| `admin_screen.dart` | 新增套餐管理 tab + 订单列表 tab |
