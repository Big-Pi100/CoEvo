# IAP 订阅接入 —— 实施设计（2026-10-04）

> 前置：`docs/review/payment-iap-assessment-2026-10-03.md`（调查报告 · 方案 A 已批准）
> 本文是**实施依据**：表结构、接口契约、边界规则定到可直接编码。
> 🔴 全部结论来自**实测**（SSH 直查生产库 + 读代码），非文档转述。

> ═══════════════════════════════════════════════════════════════════════
> ## 🔴🔴 2026-10-12 口径变更（**最新**）：订阅**必须先登录**
>
> 白哥定案原话：「**订阅肯定要先登录，才能保证用户的订阅跟着账号走，
> 订阅与账号一一绑定**」。
>
> ⇒ 本文 §四「未登录购买」那一整段设计**已作废**（本节是现行规格，优先于下文）：
>
> | 项 | 本文原设计（2026-10-04） | **现行（2026-10-12 起）** |
> |---|---|---|
> | 未登录能否购买/恢复 | ✅ 能（StoreKit 走 Apple ID；登录后补报） | ❌ **不能** —— 点购买/恢复**先引导登录**，登录成功后自动继续 |
> | 交易归属 | 未登录 ⇒ **无绑定**，靠「首次上报」确立 | **必带绑定**：`PurchaseParam.applicationUserName` = 当前 `userId`（Apple 签成 `appAccountToken`）|
> | 端侧「无绑定」权益 | 未登录时**算**（"本机权益"） | **一律不算**（无绑定 = 异常残留，交服务端对账）|
>
> **三处落点（缺一不可）**：
> ① **UI 引导** —— `subscribe_screen` / `profile_screen` 点购买·恢复 ⇒ `AuthDialog.show()`
> ② **服务层硬拦截** —— `IapService.buy()` 未登录**直接拒绝**（不产生交易）
> ③ **判定层** —— `iapEntitlementBelongsToAccount` 无绑定一律 false
>
> 断言见 `scripts/iap_verify` ⑯ / ⑰ 组（已证伪：删任一处 ⇒ 对应断言变红）。
> 落点与理由（含 Apple 3.1.1「恢复购买入口」如何仍然满足）见
> `app/lib/services/iap_service.dart` 文件头硬规则 ③、`iap_plan.dart` 的对应文档。
>
> ⚠️ **下文凡写「未登录购买」「购买不需要登录」「无绑定靠首次上报」处，
>    一律按上表已作废阅读** —— 保留原文仅为留档（记录当初为何那样设计）。
> ═══════════════════════════════════════════════════════════════════════

---

## 一、实测现状（生产库 + 代码）

| 项 | 实测值 | 来源 |
|---|---|---|
| `payment_orders` 行数 | **0** | SSH 直查 `/opt/coevo/data/coevo.db` |
| `users` | 1 条 · 其中 1 条有 `subscription_expires` | 同上 |
| `subscription_plans` | 3 档**微信定价**（¥120 / ¥350 / ¥1280）· 全部 `is_active=1` | 同上 |
| `iap_transactions` | ❌ **不存在** | `sqlite_master` |
| 相关表 | `subscription_plans` · `payment_orders` · `subscription_audit_log` · `subscription_requests` | 同上 |
| `payment_orders` 列 | 含 `prepay_id`(微信) · `refund_reason` · `refund_id` | `PRAGMA table_info` |
| 生产机 SQLite | **3.45.1** ⇒ **支持 `DROP COLUMN`**（需 ≥3.35）| 生产机 python3 |
| rusqlite | 0.32.1 | `Cargo.lock` |

**代码侧**：

| 项 | 实况 | 位置 |
|---|---|---|
| 两份迁移列表 | `schema.rs` L305 / `main.rs` L218 | grep 确认 |
| 套餐 seed 方式 | `INSERT OR IGNORE` ⇒ ⚠️ **老库永久漂移** | `schema.rs` L338 · `main.rs` L249 |
| 订阅模型 | **买断 N 天**（`extend_subscription` 按 `duration_days` 累加）| `subscription.rs` L190 |
| `set_expires()` | ✅ 已存在 —— IAP 可直接复用 | `subscription.rs` L136 |
| `is_subscription_active` | ✅ 兼容 `%Y-%m-%d` **与** RFC3339 | `subscription.rs` L119-133 |
| `refund_reason`/`refund_id` | 由 **ALTER 迁移**加（不在 CREATE 里）| `schema.rs` L1050-1051 |
| `pay_handlers.rs` 注释 | 🔴 四处引用 **不存在的 `iap_handlers.rs`** | L20 / L34 / L141 / L143 |
| `prepay_id` 业务读取 | **0 处**（仅 schema/迁移/断言）| grep 全 `backend/` |

> 🔑 **`payment_orders` 0 行 + `users` 1 条 ⇒ 零真实交易**，改表结构**无迁移成本**。

---

## 二、🔴 关键耦合点（改 `payment_orders` 前必看）

`distribution_handler.rs:1882`（**分销系统**，白哥定「单独立项」不删）：

```rust
"UPDATE payment_orders SET status = 'REFUND', refund_reason = ?1 WHERE id = ?2 AND status = 'SUCCESS'"
```

⇒ 分销退款**依赖** `payment_orders.status` 与 `refund_reason`。
⇒ **本次改动不得删除或改变这两个字段的语义**。
⇒ 📌 判据：**动共享表前先找「谁在读」** —— 裁剪字段是**跨模块**影响，不是局部清理。

---

## 三、表设计

### 3.1 新增 `iap_transactions`（Apple 交易明细）

```sql
CREATE TABLE IF NOT EXISTS iap_transactions (
    transaction_id          TEXT PRIMARY KEY,   -- Apple transactionId · 幂等键
    original_transaction_id TEXT NOT NULL,      -- 跨续期稳定 ID（恢复购买/查状态靠它）
    user_id                 TEXT,               -- 可空：未登录购买时先留空
    product_id              TEXT NOT NULL,      -- com.coevo.coevoApp.pro.monthly
    purchase_date           INTEGER,            -- Apple 毫秒时间戳
    expires_date            INTEGER,            -- Apple 毫秒时间戳（权威到期）
    environment             TEXT,               -- Sandbox | Production
    app_account_token       TEXT,               -- 端侧可回传，用于绑定我方账号
    raw_payload             TEXT,               -- 原始响应留档（排障用）
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_iap_original ON iap_transactions(original_transaction_id);
CREATE INDEX IF NOT EXISTS idx_iap_user ON iap_transactions(user_id);
```

**为什么独立表（而非塞进 `payment_orders`）**：

| 理由 | 说明 |
|---|---|
| `original_transaction_id` 是订阅的**核心标识** | 恢复购买、查订阅状态、二期通知都靠它 |
| 职责分离 | `payment_orders` = **用户视角的订单**；`iap_transactions` = **Apple 视角的交易明细** |
| 二期扩展 | Server Notifications V2 会写入大量事件（续期/退款/宽限期）⇒ 独立表更干净 |
| 避免语义混杂 | `payment_orders` 已有 `prepay_id`/`refund_*` 等**微信语义**列，再混 Apple 概念会更乱 |

### 3.2 `payment_orders` 变更

| 动作 | 字段 | 理由 |
|---|---|---|
| 🔴 **删除** | `prepay_id` | 微信专有 · 业务代码 **0 读取** · SQLite 3.45 支持 `DROP COLUMN` |
| 🆕 **新增** | `iap_original_transaction_id TEXT` | 便于与 `iap_transactions` 联查（未登录补报时定位） |
| ✅ **保留** | `transaction_id` | 存 Apple `transactionId`（语义从微信流水号平滑迁移）|
| ✅ **保留** | `refund_reason` / `refund_id` | 🔴 **分销系统在用**（见 §二）|
| ✅ **保留** | `status` / `amount` / `plan_id` | `user_orders_handler` 与分销依赖 |

### 3.3 `subscription_plans` —— ⏳ 待白哥决策（见 §七）

---

## 四、接口契约

### 4.1 `POST /api/iap/verify`（新增 · 在 `iap_handlers.rs`）

**请求**：
```json
{
  "transactionId": "2000000123456789",
  "productId": "com.coevo.coevoApp.pro.monthly",
  "appAccountToken": "可选 · 端侧生成的账号关联 token"
}
```
Header：`Authorization: Bearer <token>`（**可选** —— 有则用 token 里的 userId，无则视为未登录）

**服务端流程**：
```
1. 调 Apple: GET https://api.storekit.itunes.apple.com/inApps/v1/transactions/{id}
   Header: Authorization: Bearer <ES256 JWT>（用 ASC 的 .p8 + KeyID + IssuerID 签）
   ⚠️ 沙盒走 https://api.storekit-sandbox.itunes.apple.com
2. 校验三件事：
   · productId ∈ {com.coevo.coevoApp.pro.monthly, .pro.yearly}
   · bundleId == "com.coevo.coevoApp"
   · environment 与当前配置一致（sandbox/production 不混）
3. 写 iap_transactions（幂等）：
   INSERT ... ON CONFLICT(transaction_id) DO UPDATE SET
     expires_date=excluded.expires_date, updated_at=excluded.updated_at
   WHERE iap_transactions.expires_date IS NOT excluded.expires_date
   🔑 用 DO UPDATE + WHERE 有变化（不是 DO NOTHING）—— 续期要能更新到期日
4. 写 payment_orders（仅在首次插入时 · 靠 affected rows 判断）
   status='SUCCESS', transaction_id=Apple txId, paid_at=购入时间
5. 若已登录：set_expires(user_id, Apple 的 expiresDate → RFC3339)
6. 返回 { isActive, expiresAt, productId, originalTransactionId }
```

**响应**：
```json
{
  "isActive": true,
  "expiresAt": "2026-11-04T12:33:00Z",
  "productId": "com.coevo.coevoApp.pro.monthly",
  "originalTransactionId": "2000000123456789"
}
```

**幂等规则**：以 `transaction_id` 为唯一键。**重复上报同一笔 → 结果完全一致**（不重复延期、不重复写订单）。

### 4.2 一期不依赖 JWS 验签

**我们主动** `GET /inApps/v1/transactions/{id}` ⇒ 响应走 **HTTPS/TLS** ⇒ 中间人无法伪造
⇒ **可不验 JWS 签名**（JWS 验签的必要场景是「Apple 主动 POST 给我们」= 二期 Server Notifications V2）

⇒ **一期不需要** `SignedDataVerifier` / `x509-validator` ⇒ 绕开社区库的验签风险面。

---

## 五、边界与原则

### 5.1 🔴 端侧是权威，服务端只对账

| 判断 | 由谁做 | 说明 |
|---|---|---|
| **「当前是否是会员」** | **端侧**（StoreKit 2 `Transaction.currentEntitlements`）| 离线可用 · 不依赖网络 |
| 「服务端记录了什么」 | 服务端 `iap_transactions` + `users.subscription_expires` | **对账/留档**，不是权益来源 |

⇒ 权益解锁**不得**被「服务端请求失败」阻塞（否则违反产品原则）。

### 5.2 🔴 购买不被登录阻塞（对齐产品原则）

产品原则：**除生词本上限外不验证登录态** ⇒ 订阅购买流程**不得**要求先登录。

- StoreKit 购买由 **Apple ID** 完成 ⇒ 与我们的账号无关
- 「恢复购买」= `restorePurchases()` ⇒ 同样从 **Apple ID** 取回，**不依赖我们的账号**
- **未登录购买**：端侧已解锁（端侧权威）· 服务端**暂不对账**
  → **登录后补报**（端侧检查 `currentEntitlements` 并上报）
- ⚠️ 与 `claim_dialog.dart` 的文案「登录后可…找回已购订阅」一致 ✅

### 5.3 🔴 到期时间由 Apple 决定（不是「加 N 天」）

| 微信时代 | IAP |
|---|---|
| `extend_subscription()` 按 `duration_days` **累加 N 天** | `set_expires()` **直接写入 Apple 的 `expiresDate`** |

⇒ 一期 **IAP 链路不走 `extend_subscription`**（它是买断语义，会在续期/宽限期/退款下算错）。
⇒ 写入格式：**完整 RFC3339**（如 `2026-11-04T12:33:00Z`）—— `is_subscription_active` 已兼容 ✅
⚠️ 保留 `extend_subscription` 供 **admin 手工设置**用（管理端仍需要「给人加 N 天」）。

---

## 六、实施顺序

| # | 步骤 | 依赖 |
|---|---|---|
| 1 | 新增 `iap_transactions` 表（**两份迁移列表都加**）| 无 |
| 2 | `payment_orders` 删 `prepay_id` + 加 `iap_original_transaction_id` | 无 |
| 3 | 新建 `iap_handlers.rs`（`/api/iap/verify`）| 需 ASC 的 .p8（白哥）|
| 4 | 注册路由 + 删掉「引用不存在文件」的注释 | 3 |
| 5 | 前端 `in_app_purchase` 接入 + 订阅页重做 | 产品 ID 已定 ⇒ 可先做 |
| 6 | 沙盒联调 | 需白哥的 ASC 就绪 |

> 🔑 步骤 1/2 **完全不被 ASC 阻塞** ⇒ 可以立刻做。
> 步骤 3 可以先写**代码框架 + 单元测试**（Apple API 调用注入 trait，测试用 mock）。

---

## 七、⏳ 待白哥决策

### 决策 1：`subscription_plans` 表怎么处理？

现状：3 档**微信定价**，被 `payment_orders.plan_id` 引用，被 `/api/pay/plans` 暴露。

| 选项 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A** ⭐ 改造为「IAP 产品注册表」 | id 改为 `com.coevo.coevoApp.pro.monthly` / `.yearly`；price 保留但标「非权威」 | FK 不断 · 前端接口不变 · 改动最小 | 价格**双源**（ASC 权威 / 本地兜底）需写清楚 |
| **B** 退役表 | 前端产品列表改从 StoreKit 取 · `/api/pay/plans` 下线 | 单一权威（ASC）| 要动 FK + admin 端点 · 工作量更大 |
| **C** 保留不动 | 3 档微信定价留着 | 零改动 | 🔴 **语义残留** —— 后续开发会把微信套餐加回来 |

**推荐 A**（理由：IAP 下价格权威在 ASC，但我们需要一张「产品 ID ↔ 展示信息」的本地兜底表用于离线/降级场景；退役（B）省下的收益不值改动成本）。

### 决策 2：未登录购买时，服务端要不要接受「无 user_id」的上报？

- **选项 1** ⭐ 上报**必须**有 user_id（未登录不上报，登录后补报）
  - ✅ 避免归属污染 · 符合「端侧权威」（购买已解锁，不差这一次对账）
- **选项 2** 允许无 user_id 上报（先写 `iap_transactions` 但不关联用户）
  - ✅ 交易留档更完整
  - ⚠️ 需要「事后绑定」逻辑，复杂度上升

**推荐 1**。

> ✅ **白哥 2026-10-04 决策**：决策 1 选 **A（改造为 IAP 产品表）** · 决策 2 选 **1（必须有 user_id）**。

---

## 八、实施记录 ① 后端（2026-10-04 · 已完成并验证）

### 8.1 落地清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `crates/api_server/src/schema.rs` | `SCHEMA_SQL`：删 `payment_orders.prepay_id` · 新增 `iap_transactions` 表 · `subscription_plans` seed 换 IAP 两档 |
| 2 | `crates/api_server/src/schema.rs` | 迁移：`drop_column_if_exists(payment_orders, prepay_id)` · 旧档下架 UPDATE |
| 3 | `crates/api_server/src/schema.rs` | 断言：`prepay_id` **反向断言（必须不存在）** · `iap_transactions` 列表断言 · 登记表补 `iap_transactions` |
| 4 | `src/main.rs`（**第二份迁移列表**）| 与 ① 同步：删 `prepay_id` · 新增 `iap_transactions` · seed 换 IAP 两档 · 旧档下架 |
| 5 | `crates/api_server/src/iap_handlers.rs` 🆕 | **508 行**：解析 JWS · 校验 · 幂等 upsert · 订单记账 · ES256 JWT · `/api/iap/verify` handler + **13 个测试** |
| 6 | `crates/api_server/src/lib.rs` · `routes.rs` | 注册模块 + 路由 `POST /api/iap/verify` |
| 7 | `crates/api_server/Cargo.toml` | 加 `ring = "0.17"`（ES256 签名）|

### 8.2 🔑 `subscription_plans` 的实施方式：**下架，不删**

原计划「改造」，实施时发现一处**跨模块耦合**：

```
distribution_handler.rs:250  SELECT price FROM subscription_plans WHERE id = ?1
                              ↑ 分销按 plan_id 查「原价」算佣金
```

⇒ 删旧档会让历史订单的参照**断链**。故改为：
- 旧档 `30d`/`90d`/`365d` → `is_active = 0`（下架，保留行）
- 新档 `com.coevo.coevoApp.pro.monthly`/`.yearly` → `is_active = 1`
- 前端 `/api/pay/plans` 只返回 `is_active = 1`（`subscription.rs::get_available_plans` 的既有 WHERE）

📌 判据：**动共享表前先找「谁在读」** —— 裁剪字段/行是**跨模块**影响。

### 8.3 过程中踩到的三处（如实记录）

| # | 现象 | 根因 | 教训 |
|---|---|---|---|
| 1 | `from_pkcs8` 编译失败：参数个数不对 | **ring 0.17 是三参数**（多一个 `&dyn SecureRandom`），0.16 是两参数 | 照抄旧示例会挂；**版本差异要查本机源码**（`registry/src/.../ring-0.17.14`）|
| 2 | 找不到 `ECDSA_P256_SHA256_FIXED_VERIFICATION` | ring 里验证算法叫 **`ECDSA_P256_SHA256_FIXED`**（无 `_VERIFICATION` 后缀）| 常量名不能靠猜 |
| 3 | 测试 `多出未登记的表: ["iap_transactions"]` | `EXPECTED_TABLES` 是白名单，加表必须登记 | ✅ **这是有效断言** —— 它主动拦住了「加了表但没登记」|

### 8.4 为什么用 `ring`（**不是偏好，是实测约束**）

`jsonwebtoken` / `p256` **都不在 `Cargo.lock`**；而 `ring 0.17.14` **已在 lock + 本地 crate 缓存**
（reqwest 的间接依赖）⇒ 显式声明为直接依赖**不触发拉取索引** ⇒ `--offline` 可构建。

⚠️ 项目 `Cargo.toml` 已记录过同类判据（`roxmltree` 那条）：
**本机 `cargo check` 会卡在「Updating crates.io index」** ⇒ 选包必须看「在不在 lock 里」。

### 8.5 验证（全绿）

| 项 | 结果 |
|---|---|
| `cargo check -p api_server --lib --offline` | ✅ |
| `cargo fmt --check` | ✅ |
| `cargo clippy --workspace --all-targets --offline -- -D warnings` | ✅ 0 警告 |
| `cargo test --workspace --offline` | ✅ **209 passed / 0 failed**（api_server 189 + chat_engine 20）|

> ⚠️ 命令要加 `--offline`：本机拉 crates.io 索引会超时。
> ⚠️ clippy 的正确写法是 `cargo clippy ... -- -D warnings`（`-D` 前要有 `--`），
>    否则 cargo 把 `-D` 当自己的参数 ⇒ 报 `unexpected argument '-D'`。

### 8.6 ⏳ 后端剩余（依赖白哥）

| 项 | 依赖 |
|---|---|
| 环境变量 `IAP_KEY_ID` / `IAP_ISSUER_ID` / `IAP_PRIVATE_KEY` / `IAP_ENVIRONMENT` | 🔴 **白哥在 ASC 生成 IAP Key（.p8 + Key ID + Issuer ID）** |
| 沙盒端到端联调 | ASC 产品 + 沙盒账号 |
| Server Notifications V2（二期）| — |

> 🔑 代码已完整实现，**只差运行时配置**。`IapConfig::from_env()` 缺配置时返回 503 + 明确原因
> （不让端侧误判为「交易无效」）。

---

## 九、实施记录 ② 前端（2026-10-04 · 已完成并验证）

### 9.1 🔴 一个关键的形态决策（白哥定）

| | **原**：弹层 | **新**：独立页 `/subscribe` |
|---|---|---|
| 载体 | `CoDialog` + `SubscribePanel`（380px）| `screens/subscribe_screen.dart` |
| 为什么换 | 法定要件放不下（要滚动）| ✅ 自动续费披露 + 2 法律链接 + 权益 + 2 档 + 恢复购买，整页才排得开 |
| | | ✅ Apple 审核截图更清晰（订阅页是审核员必看页）|
| | | ✅ 与规格用词一致（`ui-ux §4.4` 一直写「订阅**页**」）|

**另一个决策**：`order_history.dart` **保留列表、去掉支付按钮**（其交易由 IAP 写入 `payment_orders`，有数据可看）。

### 9.2 落地清单

| # | 文件 | 动作 | 说明 |
|---|---|---|---|
| 1 | `lib/services/iap_plan.dart` 🆕 | **新增** | **零 import 纯逻辑**（产品 ID 契约 · 价格 · 折扣 · 法定文案 · 状态判定 · 法律链接常量）|
| 2 | `lib/services/iap_service.dart` 🆕 | **新增** | `in_app_purchase` 封装（端侧权威 · `completePurchase` 必调 · 未登录记待补报）|
| 3 | `lib/providers/iap_provider.dart` 🆕 | **新增** | Provider + 三条接线（绑定上报器 / 登录后补报 / 启动监听）|
| 4 | `lib/screens/subscribe_screen.dart` 🆕 | **新增** | 订阅页（含全部法定要件）|
| 5 | `lib/screens/profile_screen.dart` | 改 | 订阅卡改**端侧权威** · 删微信时代文案 · 加「恢复购买」+「管理订阅」|
| 6 | `lib/app.dart` | 改 | 路由 `/pay` → `/subscribe` · 覆盖层改跳转 · **启动预热 IAP** · 判定源改端侧 |
| 7 | `lib/widgets/order_history.dart` | 改 | 删「继续支付」按钮 + `_continuePay`（含 2 个随之失效的 import）|
| 8 | `lib/screens/pay_screen.dart` | 🔴 **删** | 552 行微信扫码页（IAP 无对应物）|
| 9 | `lib/widgets/subscribe_panel.dart` | 🔴 **删** | 392 行套餐弹层（被订阅页取代）|
| 10 | `app/pubspec.yaml` | 改 | 加 `in_app_purchase: ^3.3.1` |
| 11 | `scripts/iap_verify/` 🆕 | **新增** | 79 项纯 Dart 验收（已接 CI）|

**净效果**：删 **944 行**死代码，加 **4 个新文件**。

### 9.3 三条不可省的义务（都在断言里守着）

| 义务 | 出处 | 断言 |
|---|---|---|
| **自动续费披露** | `ui-ux §4.4.2`（法定，判例 30 万罚款）| `autoRenewNotice(` + `autoRenewNoticeGeneric(` |
| **隐私政策 + 用户协议** | Apple 订阅类强制 | `kPrivacyPolicyUrl` + `kTermsOfServiceUrl` + 兜底文案 |
| **恢复购买 ×2 处** | Apple 3.1.1 + `§4.4.3` | 订阅页 `.restore()` + 「我的」页 `_restorePurchases` |

🔑 还守了 `§4.4.2`「**不得默认勾选**」：断言「`_selectedProductId` 声明处**无初值**」——
    这是「不预选」在代码上的**形状**。

### 9.4 过程中的三个真问题（**都是工具抓到的，不是我想到的**）

| # | 问题 | 谁抓到 | 性质 |
|---|---|---|---|
| 1 | `iap_provider.dart` 有 **unused import** | `codestatic` | 🔴 **CI 致命**（warning 档）|
| 2 | `Stream.followedBy` **不存在**（那是 `Iterable` 的方法）| `codestatic` | 🔴 符号解析错误 —— **API 名靠猜**踩的 |
| 3 | 断言「无『请联系服务人员』」**假红**（命中全在注释里）| `iap_verify` | 🟠 断言范围 > 被测对象范围 |

📌 **教训**：
- **API 名不能靠猜** —— 「应该有这么个方法」必须过一遍符号解析（#2）
- **断言范围必须等于被测对象范围** —— 注释里的提及既会**假绿**（正向）也会**假红**（反向）（#3）
- **本地检查的判据必须与 CI 逐条对齐** —— #1 就是靠这条抓到的（warning 也致命）

### 9.5 ⚠️ 本机验证的**盲区**（如实记录）

| 项 | 状态 |
|---|---|
| `iap_plan.dart`（零 import）| ✅ **完整验证**（`dart run`）|
| `iap_provider` / `subscribe_screen` / `profile_screen` / `app.dart` | ✅ **符号解析通过**（`codestatic`，0 error / 0 warning）|
| `iap_service.dart` | 🟡 **本机无法解析** —— `in_app_purchase` **不在** pub 缓存，`package_config.json` 里没有 ⇒ 20 条 `Undefined name 'InAppPurchase'` 全属**假红**（CI 会 `flutter pub get` 补上）|
| **UI 渲染** | 🔴 **本机完全无法验证** —— `flutter` 命令建不了子进程（`CreateFile failed 231`）⇒ 视觉/交互只能靠 CI 编译 + 白哥真机 |

### 9.6 剩余（依赖白哥）

| 项 | 状态 |
|---|---|
| 法律链接填入真值 | ✅ **已完成** —— `https://api.keyievolution.fun/privacy` · `/terms`（2026-10-04 部署上线）|
| 沙盒端到端 | ⏳ ASC 产品 + 沙盒账号 + 4 个环境变量 |
| 审核截图 | ⏳ 订阅页**已完成**（可截：≥640×920，须是 App 内订阅页）|

### 9.7 🆕 法律链接的最终形态（方案 A）

| 项 | 值 |
|---|---|
| URL | `https://api.keyievolution.fun/privacy` · `/terms` |
| 部署 | `scripts/legal/publish_legal_pages.sh`（幂等 · nginx 静态 · 改前备份 · 失败回滚）|
| App 消费点 | `iap_plan.dart` 两个常量 → 订阅页 + 「关于」页 |
| 共享组件 | `widgets/legal_link_row.dart` —— 「url 空 → 即将上线不可点」规则**单点** |
| 联系邮箱 | `support@keyievolution.fun`（Cloudflare Email Routing → QQ，**端到端验证通过**）|

> 🔑 **抽组件的理由**：订阅页（Apple 强制）与「关于」页（ASC 要求）需要**同一条规则** ——
>    URL 为空时显示「即将上线」而不是**死链**（点不动比不放进糟糕）。
>    规则写在两处会漂 ⇒ 抽成组件，各写一份的机会被消除。
> 📌 代价：`iap_verify` 的断言目标**跟着搬了**（订阅页源码里不再有「即将上线」）——
>    抽组件后**断言的目标文件要一起改**，否则会**假红**。
