# 「订阅已到期」覆盖层：弹出条件 + 「查看订阅」不跳转 —— 根因调查（2026-10-09）

> 白哥原话：「订阅到期窗口弹出的条件是什么，点击查看订阅只是关闭弹窗，并没有跳转到订阅页面」
>
> 类型：**调查（未改任何代码）** · 端侧为主 · 后端一处语义问题
> 相关代码：`app/lib/app.dart`（`_checkSubscription` / `_applyExpired` / `_buildSubExpiredOverlay`）
> · `app/lib/providers/subscription_provider.dart` · `backend/crates/api_server/src/routes.rs:1123`

---

## 一、弹出条件（逐条，附代码位置）

### 1.1 什么时候「检查」

| 触发 | 位置 |
|---|---|
| 启动后 **3 秒** 一次 | `app.dart:669` `Future.delayed(3s, _checkSubscription)` |
| 之后**每 5 分钟**一次 | `app.dart:671-672` `Timer.periodic(5min)` |
| **每次 `build()`** 一次（`Future.microtask`） | `app.dart:813` |

### 1.2 用谁判定 —— **两条路径，条件完全不同**

```
_checkSubscription()                                   app.dart:702
  ├─ ① IAP 可用（iOS / StoreKit 就绪）
  │     expired := iap.entitlement == IapEntitlementStatus.expired
  │                 ↑ resolveEntitlement()（iap_plan.dart:283）
  │                   · 到期时间在未来      → active
  │                   · 有购买记录 + 已过期 → expired
  │                   · **从未购买**        → none   ← 🔑 不弹
  │
  └─ ② IAP 不可用（**安卓真机测试包走这条**）
        先 fetch 后端 /api/user/{id}/subscription，再取 subscriptionProvider.isExpired
        ↑ 后端 `user_subscription_handler`（routes.rs:1136-1148）：
             subscription_expires = NULL  →  expired = **true**   ← 🔴 关键
             有值但解析失败                →  expired = true
```

### 1.3 另外四道门槛（`_applyExpired`，app.dart:726）

1. **试用账号永不弹**：`isTrial = (auth.username ?? '').startsWith('trial_')` → `&& !isTrial`（app.dart:705/737）
2. **回退路径要求已登录**：`!auth.isAuthenticated || userId == null` → 直接 return（app.dart:716）
3. **关闭后有 backoff**：按关闭次数递增等待 **10 / 30 / 60 / 120 / 360 分钟**（`_backoffMinutes`，app.dart:650）
4. 已显示时不重复 `setState`（只在 false→true / true→false 跳变时动）

### 1.4 实测：**为什么你会看到它**

直查线上 `coevo.db`（`users` 表 · 2026-10-09）：

| 账号 | username | subscription_expires | 后端返回 `expired` | 会被弹吗 |
|---|---|---|---|---|
| `1133f074…` | `trial_1133f074` | `2026-10-02T04:09:11Z`（= 建号时间，已过） | true | ❌ 被 `isTrial` 拦住 |
| `b5b3a29d…` | `u_b5b3a29d151f`（690861018@qq.com） | **NULL** | **true** | ✅ **弹** |
| `145f2f18…` | `apple_145f2f189a73`（mr.bigpi@foxmail.com） | **NULL** | **true** | ✅ **弹** |

`iap_transactions` 表 **0 行**（从未有过任何 IAP 交易）。

🔑 两条结论：
- **凡不是 `trial_*` 的账号，在后端都是 `expired = true`** —— 因为「**没有订阅记录**」被当成了「**已到期**」。
- 安卓包上 StoreKit 不存在（`InAppPurchase.instance.isAvailable()` 为假）⇒ 走回退路径
  ⇒ 你登的正式账号（Apple / 邮箱）**必然弹**。端侧那条路径反而不会弹（从未购买 → `none`）。

---

## 二、「查看订阅」只关弹窗、不跳转 —— 根因

### 2.1 现象对应的代码（app.dart:783-791）

```dart
FilledButton(
  onPressed: () {
    _lastDismissed = DateTime.now();
    _dismissCount++;
    setState(() => _showSubExpired = false);   // ← 先执行：弹窗关掉了
    context.push('/subscribe');                // ← 再执行：这里抛异常
  },
  child: const Text('查看订阅'),
),
```

### 2.2 为什么 `context.push` 会抛（**两处上游源码为证**）

覆盖层不是挂在某个页面里，而是挂在 **`MaterialApp.router` 的 `builder:`** 里（app.dart:859-884）：

```
MaterialApp.router(
  routerConfig: goRouter,
  builder: (context, child) => Stack([ child!, AchievementUnlockOverlay(), _buildSubExpiredOverlay() ]),
)
```

| 事实 | 出处（本机源码） |
|---|---|
| `builder` 的 `context` **在 Router 之上** —— `child` 参数就是 Router 本身 | Flutter SDK `packages/flutter/lib/src/widgets/app.dart:1723` → `widget.builder!(context, routing)` |
| go_router 把 `InheritedGoRouter` 包在 **Navigator 周围**（即 builder 上下文的**下面**） | go_router 14.8.1 `lib/src/router.dart:246-249` → `builderWithNav: (ctx, child) => InheritedGoRouter(goRouter: this, child: child)` |
| `context.push` ⇒ `GoRouter.of(context)` ⇒ `maybeOf(context)!`（还带 assert） | 同文件 `router.dart:519-523` |

⇒ 在 builder 上下文里查 `InheritedGoRouter` **必然拿不到** ⇒
**debug**：`assert` 抛「No GoRouter found in context」；
**release**（你装的包）：assert 被剥掉 → `inherited!` 空值 → **`Null check operator used on a null value`**。

而 `setState` 在它**之前**已经跑完 ⇒ **弹窗关闭 + 导航从未发生** —— 与你的描述逐字一致。

📌 判据：**`MaterialApp.builder` 的上下文在 Navigator 之上** ——
在那里面只能放「不需要 Navigator / GoRouter」的东西。
（需要导航时必须持 `GoRouter` / `navigatorKey` 实例，**不能靠 `context`**。）

---

## 三、连带发现的四处问题（都没动）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| **a** | 🔴 **同一个坑还埋着第二处**：`DialogOverlay._showDialog` 在**同一个 builder 上下文**里调 `showDialog(context: context)`（内部是 `Navigator.of(context, rootNavigator: true)`）⇒ 同样会抛，但被 `catch (e) {}` **吞掉了** | `widgets/dialog_overlay.dart:56-79` | 目前**无症状** —— 因为 `dialogQueueProvider.enqueue` **全库零调用方** ⇒ 整套 `DialogOverlay` 是**死代码**（判据：零消费者 = 死代码）。一旦有人开始用它，弹窗会**静默不出现** |
| **b** | 🔴 **判据残留**：`isTrial` 仍用 `(auth.username ?? '').startsWith('trial_')` 猜试用账号 —— 这正是 `auth_provider` 里 **2026-09-29 已废弃并删除**的 `isTrialAccount` 那套写法（「靠 `trial_` 前缀猜，改用户名即失效」）。项目已统一为 **`!auth.isRegistered`（邮箱非空）** | `app.dart:705` vs `auth_provider.dart:65` | ① 认领后的正式账号（`username` 仍是 `trial_*`）被**误判为试用** ⇒ 该弹不弹；② 口径与全库不一致，改一处漏一处 |
| **c** | 🔴 **「没有订阅记录」被判成「已到期」**：后端 `None => true` | `routes.rs:1147` | 免费用户（从未订阅）看到「**订阅已到期**」—— 与「免费已全量」冲突，且是**虚假陈述**（他没有东西过期）。客户端的 `SubscriptionStatus.required`（未激活）**从未被设置**：`fetch` 只写 `expired`/`active` ⇒ 枚举里有一条**到不了的分支** |
| **d** | ⚠️ **这段逻辑零断言覆盖**：全库 `scripts/` 搜 `_showSubExpired` / `查看订阅` / `订阅已到期` → **0 命中** | grep | 这次的 bug 没有任何门禁能拦住；改动也无回归防线 |

---

## 四、修法选项（待批）

| 项 | 选项 | 代价 |
|---|---|---|
| **按钮不跳转** | **A（推荐）**：`context.push('/subscribe')` → **`goRouter.push('/subscribe')`**（同文件顶层 `GoRouter` 实例，直调不依赖 context） | 1 行 |
| | B：把覆盖层从 `MaterialApp.builder` 移进 Router 内部（如 shell 的 Stack 子节点） | 改动大、影响所有路由 |
| | C：给 `GoRouter` 传 `navigatorKey`，用 `navigatorKey.currentState` 推 | 多一层间接，且要动 router 构造 |
| **`isTrial` 判据（b）** | 换成 `!auth.isRegistered`（与全库统一口径） | 1 行 |
| **「未订阅」口径（c）** | ① 后端 `None => false`（未订阅 ≠ 过期） | 1 行（后端，需部署） |
| | ② 前端改用 `required` 状态并换文案（「订阅」引导而非「已到期」） | 客户端 + 文案 |
| | ③ 维持现状（若这是**有意的**付费墙） | 0 |
| **断言（d）** | 补结构断言（判据走 `isRegistered` · 导航不依赖 builder 上下文 · 后端 `None` 的口径） | 一批 |
| **DialogOverlay（a）** | 删（死代码）或修（改走 router / navigatorKey） | 删=小 · 修=中 |

⚠️ **未改任何代码**，等指示。

---

## 五、执行结果（2026-10-09 · 白哥批准后实施）

**白哥的选择**：修 **4 项**（按钮不跳转 · isTrial 判据统一 · 补断言 · DialogOverlay 死代码）；
「从未订阅」的口径 **维持现状**（后端的 `None => true` **不动**）。

| # | 改动 | 文件 |
|---|---|---|
| ① | `context.push('/subscribe')` → **`goRouter.push('/subscribe')`**（直调顶层实例） | `app/lib/app.dart` |
| ② | 判据 `username.startsWith('trial_')` → **`!auth.isRegistered`**；局部变量 `isTrial` → `isAnonymous`，`_applyExpired` 参数同步改名 | `app/lib/app.dart` |
| ③ | 新增 §⑩ 断言 8 项（导航不经 context · 切片前提 · 判据口径 · 死代码不得复活） | `scripts/iap_verify/bin/verify_iap_plan.dart` |
| ④ | **删除死代码**：`widgets/dialog_overlay.dart` + `providers/dialog_queue_provider.dart`；`app.dart` 去掉 `DialogOverlay` 包裹；文档同步标注 3 处 | 见下 |

### ④ 为什么是「删」而不是「修」

`DialogOverlay` 的职责（全局弹窗队列）像是「将来要用」，但它：
- **零消费者**（`enqueue` 全库无调用方）；
- 建在**已退役的概念**上（`DialogPriority.P0_PAYMENT` / `P1_SHARE` / `P2_CP1_CONCEPT`）；
- 且它是个**陷阱**：`_showDialog` 在 builder 上下文（Navigator 之上）调 `showDialog`，
  异常被自己的 `catch` 吞掉 ⇒ 真用起来会**静默不出现**。

🔑 判据：**「写了没人跑 = 迟早失效」** —— 修好一个零调用方的机制，只是**再一次**「写了没人跑」；
删掉它则**消除一个「看起来能用、一用就静默失败」的装置**。
（代价写在文档里：将来重建时**不要**再挂在 `MaterialApp.builder` 里做需要 Navigator 的事。）

**文档同步**（删代码必须清理语义残留）：
`docs/system_design.md` §1.3 + §2.3 表 · `docs/prd_in_chat_review.md` §4.4 —— 各加一条带日期的删除标注。

### 验证

| 项 | 结果 |
|---|---|
| 静态分析（`scripts/analyze_inproc`） | **error=0**（166→167 文件，删 2 个） |
| `verify_iap_plan` | **109 → 117 项全绿**（+8） |
| 逐条证伪 | 注入 4 种回归（改回 `context.push` / 改回 `trial_` 前缀 / 包回 `DialogOverlay` / **把切片搞失效**）⇒ **全部变红**，恢复后零红 |
| 其余引用 `app.dart` 的断言 | `verify_review_tab` 23 · `verify_sync` 61 · `ebook/verify_reading_tab` 78 · `verify_auth_entry` 97 · 其余 5 个 —— **全过** |
| `tokens_verify` | **690 / 8**（存量红，与基线逐条一致） |

🔑 证伪里特意加了第 ④ 条（**把方法签名改掉 ⇒ 切片取不到 ⇒ 断言必须自己变红**）——
这是「**截不到 ⇒ 下面的反向断言会假绿**」那条防线本身的证伪。

---

## 六、附：给测试账号开通订阅（2026-10-09 · 生产数据变更）

> 白哥：「现在支付还不能用，我需要一个用来测试的订阅账号」

### 为什么必须绕过支付

**订阅权益的闸门是服务端 `is_subscription_active()`**（`subscription.rs:119`）——
它读 `users.subscription_expires`，被三处消费：

| 消费点 | 位置 |
|---|---|
| 云端同步（`/api/sync/*`） | `sync_handlers.rs:332`（403「跨设备同步是订阅权益，订阅后可开启」）|
| 书架上云（blob 上传/下载） | `book_blob_handler.rs:157` |
| 整段翻译 | `translation.rs:375` |

而 **58 条 `/api/admin/*` 路由已于 2026-10-06 随 `admin_handlers` 一并退役**（`routes.rs:18`）
⇒ **没有任何后台 / 接口可以人工授予订阅**；IAP 真购买又需要 StoreKit + 沙盒账号
（安卓测试包没有）⇒ **直接写 `users.subscription_expires` 是当前唯一可行路径**
（也正是 IAP 对账最终落库的**同一个字段**）。

### 做了什么

| 项 | 值 |
|---|---|
| 账号 | `b5b3a29d-151f-4330-b293-ee2c9b7b90d5`（**690861018@qq.com** —— 10-09 01:5x 日志显示这是白哥当时在用的账号）|
| 字段 | `users.subscription_expires` |
| 旧值 → 新值 | `NULL` → **`2027-10-09`** |
| 格式依据 | 🔑 `extend_subscription()` 的**规范输出**就是 `%Y-%m-%d`（`subscription.rs:244`）；读侧（`is_subscription_active` / `user_subscription_handler`）专门兼容这种 **10 字符**格式 ⇒ **不是我编的值**，与正式购买同字段同格式 |
| 备份 | `/opt/coevo/data/backups/coevo-before-test-subscription-20261009-101540.db`（15.2 MB · `sqlite3.backup()` 在线一致快照）|

### 验证（A/B 对照，全部只读请求）

| 账号 | `GET /api/user/{id}/subscription` | `GET /api/sync/pull` |
|---|---|---|
| **已订阅** 690861018@qq.com | `{'expired': False, 'expires_at': '2027-10-09'}` | **HTTP 200** ✅ |
| 未订阅 apple/mr.bigpi | — | HTTP **403**（订阅权益文案）|
| 未订阅 trial | — | HTTP **403** |

🔑 天然的 A/B：**同一端点、同一时刻，只差 `subscription_expires` 一个字段** ⇒
证明闸门在工作，且本次改动**就是**那 403→200 的原因。

### 🔑 为什么只开通一个账号（有意保留未订阅账号）

两个正式账号里**只开一个**，是为了让**两条路都还能测**：

| 账号 | 状态 | 可测什么 |
|---|---|---|
| 690861018@qq.com | **已订阅** | 已订阅路径：同步 / 书架上云 / 整段翻译 / 订阅覆盖层**不弹** |
| apple/mr.bigpi | 未订阅 | 未订阅路径：403 文案 / **覆盖层弹出** / 点「查看订阅」跳转（本次修的那个 bug）|
| trial（1133f074） | 未订阅 | 匿名试用账号路径（`isAnonymous` ⇒ 覆盖层不弹）|

⚠️ **不要**把三个都开成已订阅 —— 那样就没法回归「未订阅」那条路了。

### 回滚

```sql
UPDATE users SET subscription_expires = NULL
WHERE id = 'b5b3a29d-151f-4330-b293-ee2c9b7b90d5';
```
或从上面那个备份恢复。⚠️ 这是**生产数据**，仅在确需回滚时执行。

