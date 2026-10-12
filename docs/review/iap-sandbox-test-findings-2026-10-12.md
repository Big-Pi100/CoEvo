# IAP 沙盒首测 · 三项发现调查报告

**日期**：2026-10-12 18:45 – 19:05
**触发**：白哥用新测试账号 `baixu100@qq.com`（TestFlight build 3）完成首次沙盒订阅购买后报告：
> 「订阅显示成功，但订阅状态的（到期日）只增加了一天，而且还会弹出未订阅的提醒弹窗」

**方法**：SSH 直查生产库 + 后端日志 + nginx access log + 读端侧/后端源码 + Apple 官方文档。
**状态**：🔴 **仅调查，未改任何代码/数据** —— 按项目铁律等白哥批准。

---

## 0. 摘要（先说结论）

| # | 现象 | 定性 | 严重度 |
|---|---|---|---|
| ① | 到期日只 +1 天（应为 1 个月）| ✅ **不是 bug** —— Apple **TestFlight 环境的官方行为** | — |
| ② | 弹出「订阅已到期」 | 🔴 **真 bug** —— 端侧权益判定**恒为"已到期"** | **P0** |
| ③ | 🆕 本次新发现：**一笔交易给两个账号开了订阅** | 🔴🔴 **权益串号 / 计费漏洞** | **P0（安全）** |

③ 是**查①时顺带撞出来的** —— 白哥没报，但它比①严重得多。

---

## 1. 现象①：到期日 +1 天 —— 这是 Apple 的正常行为

### 硬证据（生产库 + Apple 签名的原始载荷）

| 字段 | 值 | 换算 |
|---|---|---|
| `iap_transactions.purchase_date` | `1791801455000` | 2026-10-12T10:37:35Z |
| `iap_transactions.expires_date` | `1791887855000` | **2026-10-13T10:37:35Z** |
| 差 | `86400000` ms | **正好 1 天** |

🔑 **关键**：这个 `expiresDate` **是 Apple 自己签发的 JWS 里带的**（解 `raw_payload` 可见 `"expiresDate":1791887855000`），
**不是我们后端算的**。后端第 6 步是 `set_expires(body.user_id, tx.expires_date)` —— **照抄 Apple 的值**（代码注释也写明「直接写 Apple 的值，不是加 N 天」）。

### Apple 官方（`developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight`）

> When testing your app's subscriptions in **TestFlight**, the renewal rate is accelerated.
> Each subscription is **renewed daily**, up to 6 times within a 1-week period,
> **regardless of the subscription's duration**.

官方表格：`1 周 / 1 个月 / 2 个月 / 3 个月 / 6 个月 / 1 年` → **续期速率一律 = 1 Day**。

官方举例：2 月 1 日开始 1 个月订阅 ⇒ 2 月 2/3/4/5/6/7 日各续一次，**2 月 8 日停止续期**。

⇒ ✅ **1 天到期是设计如此，不是我们的 bug。**
⚠️ 但要知道后果：**这一笔订阅会在 6 次续期后自动终止**（约 10-18 前后），届时端侧会真的看到"已到期"。
📌 若想在沙盒里测**真实的续期速率**（5 分钟 / 1 小时等），要在手机上用**沙盒 Apple 账户设置**改续期速率
（`设置 → 开发者 → 沙盒 Apple 账户 → 管理`），而不是 TestFlight 的默认按天。

---

## 2. 现象②：误弹「订阅已到期」—— 根因是「注释与实现相反」

### 2.1 链路（读码）

```
覆盖层显示条件（app.dart:773）
  iap.entitlement == IapEntitlementStatus.expired
      ↑
IapService._deliver() 里赋值（iap_service.dart:328-338）
  final expires = _parseExpiry(pd);
  entitlement: resolveEntitlement(expiresAtUtc: expires, hasAnyPurchase: true, …)
      ↑
_parseExpiry 的实现（iap_service.dart:431）
  DateTime? _parseExpiry(PurchaseDetails pd) => null;      ← 🔴 硬编码返回 null
      ↑
resolveEntitlement（iap_plan.dart:459-469）
  if (expiresAtUtc != null && expiresAtUtc.isAfter(nowUtc)) return active;
  if (hasAnyPurchase) return expired;        ← 🔴 null 落到这一行 ⇒ 恒为 expired
  return none;
```

### 2.2 根因：**注释说要"先解锁"，实现判的是"已到期"** —— 语义相反

`_parseExpiry` 的注释（iap_service.dart:423-430）原文：

> ⚠️ `in_app_purchase` 的通用 API **不直接给订阅到期时间** …
> ⇒ 这里返回 null（=「不知道」），交给 `resolveEntitlement` 判为「**有购买史**」。
> 🔑 这是**有意的**：与其在端侧**猜**一个到期日（可能错），不如承认不知道。
> **而「有购买史 + 服务端之后会确认」足以让 UI 先解锁。**

⇒ 作者的意图是「**先解锁**」。但 `resolveEntitlement` 把「null + 有购买史」判成 **`expired`（已到期）** ⇒ **UI 不是解锁，是报已到期**。

**且这条错误语义被断言锁死了**（`scripts/iap_verify/bin/verify_iap_plan.dart:340-344`）：

```dart
check('无到期时间但有购买史 → expired（不是 none）',
    resolveEntitlement(expiresAtUtc: null, hasAnyPurchase: true, nowUtc: now)
        == IapEntitlementStatus.expired);
```

⇒ 属于本项目已记过的判据：**「断言会保护错误」** —— 改对了反而会红。

### 2.3 为什么页面说"订阅中"、弹窗说"已到期"（截图里的自相矛盾）

| 位置 | 判据 | 本次取值 |
|---|---|---|
| 订阅卡 / 副标题（截图 1、2）| `subscriptionActiveNow()` = **端侧 OR 服务端** | 端侧 false **或** 服务端 true = ✅ 订阅中 |
| 「已到期」覆盖层（截图 3）| **只看端侧** `iap.entitlement == expired` | 🔴 恒 expired ⇒ **必弹** |

⇒ 两个现象完全自洽。

### 2.4 影响范围（比"多弹一个窗"严重）

| 影响 | 说明 |
|---|---|
| 🔴 **覆盖层必弹** | 对**所有曾购买过的用户**。虽然只在 App 启动/恢复时检查且有 backoff，但**每次冷启都会出现** |
| 🔴🔴 **端侧"权威"从未生效** | `IapSnapshot.isActive` **恒为 false** ⇒ 设计原则「端侧权威 + 服务端只对账」**实际靠服务端单腿走路**。服务端一旦对账不上（**未登录购买** / 网络失败 / 换设备），**买了却显示未订阅** |
| ⚠️ 到期后不降级 | 反向也被这条锁死（永远 expired，永远不会显示"订阅中"）|

> 📌 未登录购买是**明确支持的场景**（`_pendingReports` 积压 + 登录后补报）——
> 但那段时间端侧既拿不到到期日、服务端也没有记录 ⇒ `subscriptionActiveNow` = false ⇒ **付了钱看不到权益**。

### 2.5 修复方案（≥2 选项）

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A2（推荐·主）** | **从 `pd.verificationData.serverVerificationData` 解析到期日**。`in_app_purchase ^3.3.1` 在 iOS 上走 **StoreKit 2** ⇒ 该字段是 **JWS**，payload 是 base64url JSON，里面有 `expiresDate`（ms）。**不验签**（只用于本地 UI；权威仍在服务端）| 购买瞬间即知 · **不依赖网络/登录** · 覆盖未登录场景 | 需新增 base64url+JSON 解析；不验签（攻击者只能骗自己）；StoreKit 1 下该字段是 receipt（格式不同，需回退到 null）|
| **A1（推荐·配套）** | **实现注释承诺的「服务端回填」**：`report()` **解析** 后端返回的 `expiresAt`（后端**已经**返回了，见 §3.3），回填到 `IapService` | 与注释承诺一致 · 服务端已验签 ⇒ 权威 · 无需端侧解 JWS | 依赖网络+登录 |
| **A3（不推荐）** | 改 `resolveEntitlement`：「null + 有购买史」判为 `active`（fail-open）| 改动最小（1 行）| 🔴 **订阅真过期也不降级**（因为永远拿不到到期日）⇒ 等于**永久白嫖**；且覆盖层永不弹。**从一个极端跳到另一个极端** |

**我的建议**：**A2 为主 + A1 为配套**（A2 保证离线即时可用，A1 保证服务端权威校正）。
**不建议单独用 A3** —— 它把"永远误报已到期"换成"永远误报未到期"，后者是**漏收**（更贵）。

⚠️ 无论选哪个，**必须同时改 `verify_iap_plan.dart` 那条断言**（它现在锁死 expired）。

---

## 3. 🔴🔴 现象③（新发现）：一笔交易给**两个账号**开了订阅

### 3.1 硬证据

| 表 | user_id | 归属账号 |
|---|---|---|
| `iap_transactions` | `c96e3b62…` | **`baixu100@qq.com`** ← 本次测试账号 |
| `payment_orders` | `b5b3a29d…` | **`690861018@qq.com`** ← **另一个账号** |

且 **两个账号的 `users.subscription_expires` 都被写成同一个值 `2026-10-13T10:37:35Z`** ——
`690861018@qq.com` **从未付款，却拿到了订阅权益**。

### 3.2 nginx access log 铁证：**同一笔交易被上报了两次**

```
124.23.134.25 - - [12/Oct/2026:18:38:35 +0800] "POST /api/iap/verify HTTP/1.1" 200 140
124.23.134.25 - - [12/Oct/2026:18:40:20 +0800] "POST /api/iap/verify HTTP/1.1" 200 140
```

后端日志给出的完整时间线：

| 时刻 (UTC) | 事件 |
|---|---|
| 10:37:35 | Apple 交易发生（`purchase_date`）|
| **10:38:33** | `auth_login: email=690861018@qq.com` ← **登录老账号** |
| **10:38:35** | **第 1 次 `/api/iap/verify`**（身份 = 690861018）→ 建 `payment_orders`(690861018) |
| 10:39:54 | `auth_register: email=baixu100@qq.com` ← **注册新账号** |
| **10:40:20** | **第 2 次 `/api/iap/verify`**（身份 = baixu100）→ 改写 `iap_transactions.user_id` + `set_expires`(baixu100) |

⇒ **两次上报间隔 105 秒，两次身份不同。**

### 3.3 代码为什么会让"两个 id"各自留下痕迹

后端 `iap_verify_handler` **每一处写入都用同一个 `body.user_id`**，且第 1 步 `verify_auth(&body.user_id, &headers)` 已校验「`body.user_id` 必须与 token 匹配」⇒ **后端自身不可能写出两个 id**。问题在**两张表的幂等键不同**：

| 函数 | 幂等键 | 冲突行为 | 后果 |
|---|---|---|---|
| `upsert_transaction` | `transaction_id` | `DO UPDATE SET user_id = excluded.user_id` ⇒ **会改写归属** | 保留**最后一次**上报的 id ⇒ baixu100 |
| `ensure_order` | `transaction_id` | `if exists { return }` ⇒ **不动** | 保留**第一次**上报的 id ⇒ 690861018 |
| `set_expires` | 无 | **无条件 UPDATE** | **两次都写** ⇒ **两个账号都拿到权益** 🔴 |

⇒ **一笔付款 = 两个账号开通会员。**

### 3.4 端侧为什么会用两个账号上报同一笔交易

`IapService` 是**单例**，`report()` 用 `ref.read(authProvider).userId`（**当前登录账号**）作为交易归属。
而交易本身**不携带账号绑定**：实测 `iap_transactions.app_account_token = None`（我们购买时**没传** `applicationUserName`）。

⇒ 同一台设备**换账号后**，同一笔 StoreKit 交易只要**再次被投递**，就会被记到**新账号**名下。
"再次投递"的触发路径（**本节为推断，未取证**，按可能性排序）：

1. **用户点「恢复购买」**（截图 2 里就有这个按钮）⇒ `restorePurchases()` 重投交易
2. **App 重启**：StoreKit 重投**未 `completePurchase`** 的交易（`_complete()` 会吞异常 ⇒ 若那次 complete 失败，交易滞留）
3. `reportEntitlementsIfSignedIn()` 补报积压（**但** `_pendingReports` 在首次成功后已 `remove`，本次路径存疑）

⚠️ **`_pendingReports` 是跨账号共享的内存状态，登出/换账号时不清空** —— 这本身是一个独立隐患。

📌 **暂无法从后端成功路径取证**（`iap_verify` 成功时**不打日志**，只有 warn/error 才打）—— 建议本次一并加一条 INFO 日志。

### 3.5 影响范围（生产环境下）

| 影响 | 说明 |
|---|---|
| 🔴🔴 **计费漏洞** | 一笔真实付款可给**任意多个账号**开会员（同设备切账号 + 触发重投）|
| 🔴 **任意账号白拿权益** | `set_expires` 无条件写 ⇒ 只要有人拿着别人的 transactionId 上报（**需要登录态，但可以是自己的账号**），就能给自己开会员 |
| 🔴 **交易归属漂移** | `iap_transactions.user_id` 会被最后一次上报覆盖 ⇒ 无法判断真实买家 |
| ✅ 解释截图 2 的「历史订单 (0)」 | 端侧按**当前** `user_id` 查 `payment_orders` ⇒ 那行属于 690861018 ⇒ **baixu100 看到 0 条** |

### 3.6 修复方案（≥2 选项）

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **B2（推荐·止血）** | **后端拒绝"交易已归属他人"**：`upsert_transaction` 发现已存在且 `user_id` 不同 ⇒ 返回 **409**，不改写、不 `set_expires` | 改动小、立刻堵住扩散 | 不解决"第一次就记错"（但至少不扩散）⚠️ 需确认原设计为何要 `DO UPDATE SET user_id`（可能是为纠错）|
| **B1（推荐·根治）** | **用 `appAccountToken` 绑定账号**：端侧购买时传 `applicationUserName`（= `userId` 的稳定派生值），后端比对 `tx.app_account_token` 与 `body.user_id` 的派生值，**不符即拒** | 从根上确定"这笔交易属于谁" | 需端侧+后端同改；**存量交易无 token**（需兼容策略）|
| **B3（配套）** | **`_pendingReports` 按账号隔离 + 登出时清空**（或丢弃非当前账号的积压）| 堵住"跨账号补报"这条路径 | 解决不了 StoreKit 自行重投 |
| **B4（配套·防御纵深）** | `set_expires` 加**前置条件**：只有当该 `user_id` 确有对应（且未被他人占用）的交易时才写 | 防"凭空开会员" | 不能替代 B1/B2 |

**我的建议**：**B2 止血 + B1 根治 + B3/B4 配套**。
另需**一次性清理**本次产生脏数据：`690861018@qq.com` 的 `subscription_expires` 应回滚为 NULL
（⚠️ **改生产数据，需单独批准**）。

---

## 4. 建议的处置顺序

| # | 动作 | 谁 | 需批准 |
|---|---|---|---|
| 1 | 🔴 清理脏数据：`690861018@qq.com` 的 `subscription_expires` → NULL | 我 | ✅ 生产数据 |
| 2 | 🔴 修 B2（交易归属冲突拒绝）—— 止血 | 我 | ✅ 代码 |
| 3 | 🔴 修 A2+A1（端侧拿到真实到期日）—— 消除误弹 | 我 | ✅ 代码 |
| 4 | 修 B1（`appAccountToken` 绑定）+ B3/B4 | 我 | ✅ 代码 |
| 5 | 加 `iap_verify` 成功日志（便于下次取证）| 我 | ✅ 代码 |
| 6 | 改 `verify_iap_plan.dart` 的过期断言 + **反向证伪** | 我 | 随 2/3 |
| 7 | 重新出包 + 真机复测 | 我 | ✅ 出包 |

---

## 5. 附：本次未能确定的事（如实标注）

1. **第 2 次上报的触发路径**（恢复购买 / 重启重投 / 补报）—— 无日志可判，需加了日志复现。
   （现已加 `iap_verify` 成功日志，**下次复现即可定性**。）
2. **`upsert_transaction` 为何要 `DO UPDATE SET user_id`** —— 原意未能查实（无相关提交说明）。
   本次**移除**了该行为：归属一旦确定不再改写。⚠️ 若原意是「纠正错误的归属」，
   现在改由**显式冲突拒绝（409）**承担 —— 更安全（改错会连带给错权益）。
3. **测试环境特有性**：本次是 **TestFlight**（按天续期）。生产环境 1 个月订阅不会出现"1 天到期"，但
   **③ 的权益串号与 ② 的误弹与续期速率无关** ⇒ 两者在生产同样成立。

---

## 6. 处置记录（2026-10-12 19:00 起，白哥批「按建议顺序处理」）

### 6.1 已完成

| # | 动作 | 结果 |
|---|---|---|
| 1 | 🔴 **清脏数据** | 备份 `coevo.db.bak-subfix-20261012185815` → `690861018` 的 `subscription_expires` 置 NULL（`baixu100` 保留、记账表未动）|
| 2 | **B2 止血**（后端）| `upsert_transaction` 改为返回 `Ownership{Claimed/SameOwner/Conflict}`；**归属冲突 ⇒ 409、一个字都不写**；`DO UPDATE` 里**移除 `user_id`** ⇒ 归属永不被改写 |
| 3 | **B1 后端一半** | 新增 `account_binding_conflict()`：交易自带 `appAccountToken` 与上报者不符 ⇒ 409 |
| 4 | **成功日志** | `iap_verify` 成功路径加 INFO（tx / user / product / env / expires / ownership / active）|
| 5 | **A2 端侧**（真正拿到到期日）| `_parseExpiry` 由 `=> null` 改为读 **`SK2PurchaseDetails.expirationDate`**（iOS 插件**本来就给了**，不必解 JWS）；解析下沉为纯函数 `parseStoreKitExpiryMillis()`（可验证）|
| 6 | **A1 端侧**（服务端回填）| `report()` 解析响应体 `expiresAt` → `IapService.applyServerExpiry()`（**只允许向后推进**）；兑现了原注释承诺 |
| 7 | **`null` 语义修正** | `resolveEntitlement`：`null + 有购买史` 由 `expired` → **`active`（fail-open）** —— 与 `_parseExpiry` 注释的原始意图一致 |
| 8 | **B1 端侧** | `buy()` 传 `applicationUserName: _reporterAccountKey`（= 登录用户 id，UUID）⇒ 交易带上账号绑定 |
| 9 | **B3** | `setReporter(..., accountKey:)`：**换账号时丢弃积压交易**（同账号登出重登不清，避免丢对账）|
| 10 | **409 = 永久放弃** | `report()` 遇 409 **不抛**（区别于其它非 200）⇒ service 移除该笔积压、**不再无限重试** |

**验证**：后端 `cargo test` **301 passed / exit 0** · `fmt --check` ✅ · clippy 无 error；
端侧 `iap_verify` **222 项**（原 213，+9）· 类型检查 **0 error** · `query_verify` 全套 **fail=0**。
**反向证伪 3 次**（每次精确红、复原回绿、无残留）：
① `null` 分支改回 `expired` ⇒ 红 1 项；② 毫秒当秒用 ⇒ 红 3 项；③ 绑定比对改大小写敏感 ⇒ 红 1 项。

### 6.2 ⚠️ **仍未闭合**（如实列出，别当成已修）

| # | 缺口 | 说明 |
|---|---|---|
| 1 | 🔴 **端侧冷启动后仍是空的** | StoreKit **不会重投已完成的交易** ⇒ App 重启后 `entitlement = unknown`、`expiresAtUtc = null`。「**端侧权威**」目前只在**本次会话购买/恢复过**时成立；冷启动仍靠**服务端 OR** 兜底。<br>⇒ 要真正闭合需查「当前 entitlements」（StoreKit 2 的 `Transaction.currentEntitlements`）—— 而 `in_app_purchase` 的**通用 API 不提供**，需额外机制。**未做，列为后续**。 |
| 2 | 未登录购买 ⇒ **无绑定** | 归属由「首次上报者」确立（先到先得）。这是「购买不需要登录」的**设计后果**，B2 已把它限制为**单一归属**（不会给多个账号开）。 |
| 3 | `users.created_at` 两种格式混用 | 早先发现（`chrono::timestamp()` vs `datetime('now')`）⇒ `ORDER BY` 不可信。**未改**，影响面小（零真实用户）。 |
| 4 | **Server Notifications V2 未实现** | 续期/退款 Apple 主动推送的事件收不到。与本次三项**无关**，但同为「对账」缺口。 |

### 6.3 生产部署（2026-10-12 19:38 ✅ 后端已上线）

| 判据 | 部署前 | 部署后 |
|---|---|---|
| 二进制 sha256 | `b5e8c496…` | **`4e8d2975…`** = 白哥构建产物（服务器侧 sha256 一致）|
| 阴性对照 `iap_verify: tx=` | 0 | **1** ✓ |
| 阴性对照 `IAP 归属冲突 ⇒ 拒绝开通 tx=` | 0 | **1** ✓ |
| 阴性对照 `该交易已归属其他账号，无法重复开通` | 0 | **1** ✓ |
| 阳性对照 `IF NOT EXISTS sync_book (` | 1 | **1** ✓ |
| `/health` | `记忆之书 API — OK` | **`记住一切 API — OK`**（产品名三改的连带）|

#### 🔴🔴 行为实测（比 grep 字符串硬得多）

用**另一个账号**（`appreview@keyievolution.fun`，由我建的演示账号）去上报**属于 `baixu100` 的那笔交易**：

```
POST /api/iap/verify  {transactionId: 2000001249787368, user_id: dc197948…}
→ HTTP 409
→ {"error":"该交易已归属其他账号，无法重复开通","transactionId":"2000001249787368"}
```

⚠️ 这正是**原来会串号的那条路径**（旧代码会静默改写归属并给第二个账号开通）。

后端日志（**新加的代码路径真的被执行**）：
```
WARN api_server::iap_handlers: IAP 归属冲突 ⇒ 拒绝开通
     tx=2000001249787368 上报者=dc197948… 实际归属=c96e3b62… product=…pro.monthly
```

**且 409 之后「一个字都没动」**（逐项直查）：
`baixu100` 的 `subscription_expires` 仍是 `2026-10-13T10:37:35Z` · `appreview` 仍 `NULL` ·
交易归属仍 `baixu100` · `iap_transactions` / `payment_orders` 行数不变。

对照组：无 token ⇒ **401** · 空 `transactionId` ⇒ **400** ✓

#### 其他
- 标准部署探针 `verify_v016_deploy.py`：**35 项全过** · 重启窗口 **0 条 ERROR**
- 公网：`/health` `/privacy` `/terms` 均 **200** · `/health` 内容已是 `记住一切 API — OK`
- ⚠️ **`/support` 仍是 404** —— 那页（Apple 必填的「技术支持网址」）**还没部署**
  （需往 nginx 加 `location`，属生产配置变更 ⇒ 需单独批准）
- 邻居服务 `coevo` / `vibedollar-pay` / `mailproxy` / `nginx` 全 **active**
- 回滚点：`/opt/coevo/bin/coevo_backend.prev`（`b5e8c496…`）

📌 **部署后第一条该看的日志**就是新增的 `iap_verify:` INFO —— 它会直接告出
「谁、以什么身份、把哪笔交易报了几次」（本次首测正是缺了它才要翻 nginx）。


