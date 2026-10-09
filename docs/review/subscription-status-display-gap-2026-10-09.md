# 订阅状态显示 / 权益文案 / 同步状态 —— 根因调查（2026-10-09）

> 白哥原话：「订阅状态没有显现已订阅，现在进入订阅状态还是未订阅的页面，另外订阅页面的权益
> 应该也要更新了，最后没有看到云端同步的状态」
>
> 类型：**调查（未改任何代码）** · 端侧为主 · 服务端零改动
> 相关：`app/lib/screens/subscribe_screen.dart` · `app/lib/screens/profile_screen.dart`
> · `app/lib/services/iap_plan.dart` · `app/lib/services/sync_service.dart`

---

## 一、问题① 服务端已开的订阅，App 里仍显示「未订阅」

### 根因：**两处订阅 UI 都只读端侧 IAP，没读服务端**

| 位置 | 判据 |
|---|---|
| `subscribe_screen.dart:113` | `final snap = iapSnapshotOf(ref);` → `snap.isActive`（`entitlement == active`）|
| `profile_screen.dart:417` | `versionLabel(iapSnapshotOf(ref).isActive)`（副标题的「免费版 / 订阅版」）|

而「端侧 IAP」在**安卓上永远是 `none`**：
`InAppPurchase.instance.isAvailable()` 依赖 StoreKit / Play Billing，
安卓测试包上不为 available ⇒ `entitlement` 停在 `unknown`/`none`。

⇒ **服务端 `users.subscription_expires` 改成 2027 也没用** —— 界面根本不看它。
（`subscriptionProvider` 只被 `_checkSubscription` 用来决定**弹不弹覆盖层**，
两处订阅 UI 都没有消费它。）

📌 这不是「测试数据的坑」，而是一条**真实的架构缺口**：
「端侧权威（StoreKit）+ 服务端只对账」在**没有商店的载体**上（安卓验证机 / 将来可能的
后台授予、优惠赠送）会表现为「**权益明明有，界面说没有**」。

### 可选的判据

| 方案 | 做法 | 代价 |
|---|---|---|
| **A（推荐）** | 「订阅有效」= `端侧 isActive **或** 服务端 isActive`，抽成**唯一判据**（一处权威） | OR 是安全的一侧：不误伤付费用户。⚠️ 语义上「端侧过期望而服务端还有效」也会显示有效 —— 但那正是对账值的含义 |
| B | 仅在**非 iOS** 平台用服务端兜底，iOS 保持纯端侧 | 保住「端侧权威」在 iOS 的纯粹性；但多一个平台分支，且后台授予在 iOS 仍不可见 |

---

## 二、问题② 订阅页权益文案过时，且**漏了两条已实现的权益**

`iap_plan.dart:198-216` 的 `benefits` 现在**只有一条**：

```dart
static const List<String> benefits = ['生词与复习进度跨设备同步'];
```

且它上面的注释还写着「**该功能目前零实现** ⇒ 上架前必须先做出来」——
🔴 **这句已过时**：云端同步全链（push/pull + 游标 + 合并）**已实现**，
今天还实测过闸门（已订阅 200 / 未订阅 403）。

### 后端「订阅闸门」实际保护的权益（`is_subscription_active` 的三个消费点）

| # | 权益 | 实现 | 免费层 | 证据 |
|---|---|---|---|---|
| 1 | **跨设备同步**（生词 / 复习进度 / 阅读记录 / 收藏 / 书进度） | ✅ 已实现 | **完全不可用**（403） | `sync_handlers.rs:332` |
| 2 | **云端书架**（电子书备份到云端） | ✅ 已实现 | **上传**不可用（403）；**下载不加闸门** ⇒ 到期后已备份的书**仍能下载** | `book_blob_handler.rs:157`（写）· `:323-329`（读，仅登录） |
| 3 | **整段翻译** | ✅ 已实现 | **每月 10 次**（`FREE_MONTHLY_LIMIT = 10`） | `translation.rs:59 / 375` |

⇒ 现状是「**实现了 3 条、只写了 1 条**」，且注释说它零实现。
按项目判据「订阅页必须与**已实现的能力**逐一对应」，两条都错：
- 少写 ⇒ 订阅价值说不清（用户看不出为什么要付钱）
- 注释错 ⇒ 后来人会以为同步还没做

---

## 三、问题③ 「云端同步状态」在界面上**不存在**

全库 grep `syncStatus|lastSync|上次同步|同步状态|syncing` → **0 命中**。

现状：
- `sync_provider.dart` 只暴露**副作用**：`runSyncAfterLogin` / `flushBeforeLogout` / `pushWhenAppPaused`
- `sync_service.dart` 的 `SyncReport`（pushed/pulled 各类计数、`isEmpty`）**只在调用点局部变量里**，
  没有任何 provider 持有它
- 持久化的只有**游标**：`coevo_sync_since.<userId>`（prefs）—— 只有"拉到哪"，
  **没有「上次成功同步的时间」**

⇒ 用户（和测试）**无从判断同步有没有在跑、跑成功没有**。
这正好撞上项目最忌的那条：**「静默失败 + 无出口」** —— 同步失败只 `debugPrint`，界面上完全看不出来。

要做「同步状态」，**至少要新增**：一个持有「上次同步时间 / 是否正在同步 / 最近结果（含失败原因）」
的 provider + 一处可见入口。（游标只能告诉你"拉到哪"，不能告诉你"上次什么时候拉、成没成"。）

---

## 四、请示（三项，选完一次做完）

1. **订阅状态判据**：按 A（端侧 **或** 服务端，抽成唯一判据）还是 B（仅非 iOS 兜底）？
2. **权益清单**：是否按后端闸门**如实**更新为三条（跨设备同步 / 云端书架 / 整段翻译不限量）？
   —— 这是对用户的**承诺**，写上去就要兑现，所以请你点头（内容我按代码事实拟）。
3. **同步状态**：放哪 + 显示什么？
   - 位置：订阅页已订阅卡内 / 「我的」页订阅行 / 两处
   - 内容：上次同步时间 · 同步中 · 失败原因（失败时给个重试）

⚠️ **未改任何代码**。

---

## 五、执行结果（2026-10-09 · 白哥批准后实施）

### 白哥的三个决定

| # | 决定 |
|---|---|
| ① 订阅判据 | **端侧或服务端**（推荐方案 A）|
| ② 权益文案 | **三条如实 + 额度对比** |
| ③ 同步状态 | 🔑 **「在卡片上加云朵图标就行了，不用加新页面」**（自定义答案）|

### 改动清单（新增 3 个文件 · 改 6 个）

| 文件 | 改动 |
|---|---|
| `services/sync_status.dart` 🆕 | 纯 Dart 状态模型：`SyncPhase`（含**独立的 `skipped`**）+ `relativeSyncLabel`（自然日换算）+ `syncStatusSummary` |
| `providers/sync_status_provider.dart` 🆕 | 持有状态；`begin/finishOk/finishFailed/finishSkipped` |
| `widgets/sync_cloud_badge.dart` 🆕 | **云朵标**（四态、未订阅自隐藏、点击给一句话，失败带「重试」）|
| `services/iap_plan.dart` | 新增 `subscriptionActive`（判据）/ `subscriptionLapsed`（**「已到期」≠「从未订阅」**）/ `subscriptionExpiryLabel` / `shortPitch()`；`benefits` → **三条**；`freeTierNote`/`freeIncludes`/`afterExpiry` 按后端闸门补全 |
| `providers/iap_provider.dart` | 新增 `subscriptionActiveNow` / `subscriptionLapsedNow`（**唯一判据**）；更正「端侧唯一判据」的旧口径注释 |
| `providers/sync_provider.dart` | 三处自动时机 + 一个**手动**入口并入唯一的 `_runSync`（执行与**状态上报**同源）；`_friendlySyncError` 给用户人话 |
| `screens/subscribe_screen.dart` | 状态分派改用唯一判据；已订阅卡挂云朵标；到期日走唯一换算点 |
| `screens/profile_screen.dart` | 版本标签与订阅卡改用唯一判据；卡上挂云朵标；**修掉「无限生词本 · 文章朗读」这句虚假陈述** |
| `app.dart` | `_checkSubscription` 的**对账不再以「IAP 不可用」为前提**（否则 iOS 上服务端那一侧永远 `unknown`，兜底形同虚设）——判定仍以端侧为权威，一字未改 |

### 🔴 顺带修掉的两处（都不是本次要求，但都是真错）

1. **「我的」页订阅卡写着「无限生词本 · 文章朗读」** —— 这两个能力**早已免费**
   （生词上限 2026-10-01 取消；朗读已免费全量）。把它们说成订阅权益是**方向相反的错**
   （不是漏写，是错写）⇒ 改为引用 `shortPitch()`，并加断言锁「短标语每一项都能在权益清单里找到」。
2. **`verify_sync` 里两条断言锁的是「实现拼写」而非意图** —— `_pushOnly` 并入 `_runSync` 后**假红**
   （而它要守的「口径一处」根本没变）⇒ 改成从各自切片里抽函数名比较。

### 验证

| 项 | 结果 |
|---|---|
| 静态分析 | **error=0 · warning=0**（170 文件）|
| `verify_iap_plan` | **117 → 147 项全绿**（+30：判据真值表 6 · 到期日 3 · 接线 5 · 短标语同源 2 · 相对时间 5 · summary 4 · 单入口/单写入方 2 · 云朵 3）|
| `verify_sync` | **61 → 62 项全绿**（两条改写后拆成三条）|
| **逐条证伪** | 本批 7 条 + `verify_sync` 3 条 ⇒ **全部变红**，恢复后零红 |
| 其余断言 | 全过；`tokens_verify` 仍 **690 / 8**（存量红，与基线逐条一致）|

### 📌 证伪抓到的一个**假绿**（值得记）

「同步状态只有一个写入方」这条断言的第一版**只扫了 `sync_provider.dart` 自己**。
把 `syncStatusProvider.notifier` 注入 `sync_cloud_badge.dart` 时 —— **它照样绿**。

⇒ 判据：**断言的作用域必须覆盖它声称的语义范围**。
说「唯一」就得**全库扫**；只扫一个文件，只能证明「这个文件里没写两次」。
✅ 已改成扫 `app/lib` 全目录（170 个文件）。

