# CoEvo 订阅与支付系统设计文档

版本: v1.0 | 日期: 2026-06-15

---

## 1. 概述

CoEvo 当前通过 `user_preferences` 键值表管理订阅到期日（key=`subscription_expires`），无支付系统，订阅需管理员手动操作。本文档设计完整的用户自主订阅支付体系，包含套餐管理、订单管理、支付对接、审计追溯。

**核心原则：所有延期操作——无论是用户自助支付、管理员手动设置、注册赠送达——最终走同一段到期日计算逻辑，确保行为一致。**

---

## 2. 数据库设计

### 2.1 subscription_plans（订阅套餐）

```sql
CREATE TABLE IF NOT EXISTS subscription_plans (
    id              TEXT PRIMARY KEY,         -- '30d', '365d', 'lifetime', 'free_trial'
    name            TEXT NOT NULL,            -- '月度会员', '年度会员', '终身会员', '新用户免费试用'
    duration_days   INTEGER,                  -- 30, 365, NULL(lifetime=3650), 3(free_trial)
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

**数量限制的生效逻辑：**

```rust
fn is_plan_purchasable(plan: &Plan) -> bool {
    if plan.is_active != 1 { return false; }
    if let Some(max) = plan.max_uses {
        if plan.used_count >= max { return false; }  // 库存耗尽
    }
    if let Some(from) = &plan.available_from {
        if now < from { return false; }               // 还没开售
    }
    if let Some(until) = &plan.available_until {
        if now > until { return false; }              // 已停售
    }
    true
}
```

**初始化数据：**

```sql
-- free_trial: 不限量，永远可用
INSERT INTO subscription_plans
    (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('free_trial', '新用户免费试用', 3, 0, 0, 1, datetime('now'));

-- 30d: 不限量，永远可用
INSERT INTO subscription_plans
    (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('30d', '月度会员', 30, 20000, 1, 1, datetime('now'));

-- 365d: 不限量，永远可用
INSERT INTO subscription_plans
    (id, name, duration_days, price, sort_order, is_active, created_at)
VALUES ('365d', '年度会员', 365, 128000, 2, 1, datetime('now'));

-- lifetime: 限量 100 份
INSERT INTO subscription_plans
    (id, name, duration_days, price, max_uses, used_count,
     sort_order, is_active, created_at)
VALUES ('lifetime', '终身会员', 3650, 128000, 100, 0, 3, 1, datetime('now'));
```

**什么场景用哪些字段：**

| 场景 | is_active | max_uses | available_from/until |
|:----|:---------|:---------|:-------------------|
| 长期在售套餐（月度/年度） | 手动切换 | NULL | NULL |
| 限量优惠（终身会员前100名） | 1 | 100 | NULL |
| 限时优惠（早鸟价到X月X日） | 1 | NULL | available_until=截止日 |
| 限时限量（开售前100份） | 1 | 100 | available_from=开售日, available_until=截止日 |
| 临时下架（运营调整） | 0 → 手动改 | — | — |

### 2.2 payment_orders（支付订单）

```sql
CREATE TABLE IF NOT EXISTS payment_orders (
    id              TEXT PRIMARY KEY,        -- 商户订单号 out_trade_no
    user_id         TEXT NOT NULL,           -- 用户 ID
    plan_id         TEXT NOT NULL,           -- subscription_plans.id
    amount          INTEGER NOT NULL,        -- 分
    currency        TEXT DEFAULT 'CNY',
    status          TEXT DEFAULT 'NOTPAY',   -- NOTPAY / SUCCESS / CLOSED / REFUND
    prepay_id       TEXT,                    -- 微信 prepay_id
    transaction_id  TEXT,                    -- 微信支付单号
    paid_at         TEXT,                    -- 支付完成时间 (ISO 8601)
    created_at      TEXT NOT NULL,           -- 下单时间
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_payment_orders_user ON payment_orders(user_id);
CREATE INDEX idx_payment_orders_status ON payment_orders(status);
```

### 2.3 subscription_audit_log（订阅操作审计）

```sql
CREATE TABLE IF NOT EXISTS subscription_audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    action          TEXT NOT NULL,           -- 'free_trial' / 'pay' / 'set' / 'extend' / 'batch' / 'approve' / 'refund'
    operator_id     TEXT,                    -- 操作人（admin user_id），系统操作（注册/支付回调）为 NULL
    target_user_id  TEXT NOT NULL,           -- 被操作用户
    old_expires     TEXT,                    -- 操作前到期日
    new_expires     TEXT NOT NULL,           -- 操作后到期日
    amount          INTEGER DEFAULT 0,       -- 涉及金额（分）
    order_id        TEXT,                    -- 关联订单 ID
    note            TEXT,                    -- 备注
    created_at      TEXT NOT NULL,
    FOREIGN KEY (target_user_id) REFERENCES users(id)
);

CREATE INDEX idx_audit_target ON subscription_audit_log(target_user_id);
CREATE INDEX idx_audit_created ON subscription_audit_log(created_at);
```

---

## 3. 到期日计算逻辑（核心函数）

所有延期操作统一走此函数，确保行为一致：

```rust
/// 为指定用户延长订阅，写 audit_log
fn extend_subscription(
    conn: &Connection,
    user_id: &str,
    plan_id: &str,         // 套餐 ID → 查 duration_days
    operator_id: Option<&str>,  // None = 系统自动
    order_id: Option<&str>,
    note: Option<&str>,
) -> Result<()> {
    let plan = get_plan(conn, plan_id)?;
    let old_expires = get_current_expires(conn, user_id);
    
    // 计算新到期日
    let base = match old_expires {
        Some(d) if d > today => d,     // 未过期 → 从原到期日累加
        _ => today,                     // 过期/无 → 从今天开始
    };
    let new_expires = base + Duration::days(plan.duration_days);
    
    // 写 user_preferences
    set_expires(conn, user_id, new_expires);
    
    // 写 audit_log
    insert_audit_log(conn, action, operator_id, user_id,
                     old_expires, new_expires, plan.price, order_id, note);
}
```

**调用场景：**

| 场景 | plan_id | operator_id | order_id |
|:----|:--------|:-----------|:---------|
| 注册赠送试用 | `free_trial` | NULL | `TRIAL_...` |
| 微信支付成功 | 用户购买的套餐 | NULL | 真实订单号 |
| 管理员设置到期日 | 无（直接传日期） | admin user_id | NULL |
| 管理员快速延期 | 根据天数反推 | admin user_id | NULL |
| 审批通过 | 申请中的套餐 | admin user_id | 申请单号 |

---

## 4. API 路由设计

### 4.1 用户端（无需鉴权或用户鉴权）

| 方法 | 路径 | 功能 |
|:----|:----|:----|
| `GET` | `/api/plans` | 获取可用套餐列表（is_active=1） |
| `POST` | `/api/pay/native` | Native 下单 → 返回 `code_url`（二维码） |
| `POST` | `/api/pay/jsapi` | JSAPI 下单 → 返回调起支付参数 |
| `GET` | `/api/pay/orders` | 查询当前用户订单列表 |
| `GET` | `/api/pay/orders/{id}` | 查询单笔订单状态 |

### 4.2 微信回调（无鉴权，微信服务器调用）

| 方法 | 路径 | 功能 |
|:----|:----|:----|
| `POST` | `/api/pay/notify` | 微信支付结果回调（验签→更新到期日） |

### 4.3 管理端（admin 鉴权）

| 方法 | 路径 | 功能 | 权限 |
|:----|:----|:----|:----|
| `GET` | `/api/admin/plans` | 套餐列表（含 is_active） | super/service |
| `POST` | `/api/admin/plans` | 新增套餐 | super |
| `PUT` | `/api/admin/plans/{id}` | 编辑套餐 | super |
| `DELETE` | `/api/admin/plans/{id}` | 下架套餐 | super |
| `GET` | `/api/admin/pay/orders` | 全部订单列表（含筛选） | super/service |
| `GET` | `/api/admin/users/{id}/audit-log` | 用户订阅审计日志 | super/service |
| `PUT` | `/api/admin/users/{id}/subscription` | 设置到期日（现有） | super(直接) / service(需审批) |
| `POST` | `/api/admin/users/{id}/quick-extend` | 快速延期（现有） | super/service |
| `POST` | `/api/admin/users/batch-subscription` | 批量延期（现有） | super |

---

## 5. 数据流

### 5.1 用户自助支付

```
用户 → 前端选套餐 → POST /api/pay/native
  ↓
后端 → INSERT payment_orders (status=NOTPAY)
  → 调微信 Native下单 API → 返回 code_url
  ↓
前端展示二维码（qr_flutter）→ 用户微信扫码
  ↓
微信 → POST /api/pay/notify（带签名）
  ↓
后端 → 验签 → UPDATE payment_orders (status=SUCCESS)
  → extend_subscription(user, plan)
  → 返回 SUCCESS 给微信
  ↓
前端轮询 GET /api/pay/orders/{id} → 刷新订阅状态
```

### 5.2 管理员手动操作

```
管理员 → 填到期日 / 选天数 → PUT /api/admin/users/{id}/subscription
  ↓
后端 → 写 audit_log (action='set'/'extend', operator_id=admin)
  → UPDATE user_preferences
```

### 5.3 注册赠送试用（迁移后）

```
用户注册
  ↓
后端 → INSERT payment_orders (id='TRIAL_xxx', plan_id='free_trial', status='SUCCESS')
  → extend_subscription(user, 'free_trial', operator=NULL, order='TRIAL_xxx')
```

---

## 6. 部署配置（.env）

```env
# 微信支付（必须）
WECHAT_MCH_ID=1114056630
WECHAT_API_V3_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
WECHAT_APP_ID=wx0000000000000000        # 待开放平台审核通过
WECHAT_API_CLIENT_CERT_PATH=/opt/coevo/certs/apiclient_key.pem
WECHAT_PLATFORM_CERT_PATH=/opt/coevo/certs/wechatpay_platform_cert.pem
WECHAT_NOTIFY_URL=https://keyievolution.fun/api/pay/notify
```

---

## 7. 文件清单

### 后端新增（5 文件）

| 文件 | 内容 |
|:----|:----|
| `backend/crates/api_server/src/subscription.rs` | 套餐 CRUD + `extend_subscription()` 核心函数 |
| `backend/crates/api_server/src/payment_orders.rs` | 订单表 CRUD |
| `backend/crates/api_server/src/wechat_pay.rs` | 微信支付 API v3：签名、下单、回调验签 |
| `backend/crates/api_server/src/pay_handlers.rs` | 下单 handler / 回调 handler / 订单查询 handler |
| `backend/crates/api_server/src/plans_handlers.rs` | 套餐管理 handler（用户端+管理端） |

### 后端修改（4 文件）

| 文件 | 修改 |
|:----|:----|
| `lib.rs` | 注册新模块 |
| `routes.rs` | 注册新路由 |
| `schema.rs` | 建表 SQL（3 张新表 + 索引） |
| `auth.rs` | 注册免费试用改为走订单 |
| `admin_handlers.rs` | 进入 subscription 核心函数 + 写 audit_log |

### 前端新增（2 页面）

| 文件 | 内容 |
|:----|:----|
| `subscribe_screen.dart` | 选购套餐 → Native 二维码 / JSAPI 调起支付 |
| `payment_result_screen.dart` | 支付成功/失败页 |

### 前端修改（2 文件）

| 文件 | 修改 |
|:----|:----|
| `admin_screen.dart` | 套餐管理 tab + 订单列表 tab + 审计日志 |
| `profile_screen.dart`/`chat_screen.dart` | 订阅弹窗改为"去支付" |

---

## 8. 备注

- 支付模块等 AppID 审核通过后才能联调
- 后端框架可在 AppID 下来前完成（下单接口可以 mock）
- 后续可扩展：自动续费（签约）、发票管理、多级权益
