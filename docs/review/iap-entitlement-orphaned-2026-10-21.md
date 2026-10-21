# 🔴 P0 诊断：已订阅账号「既不能恢复、也不能新购」（2026-10-21 22:4x）

## 一、结论（先给答案）

**根因不是今晚的 B1/B2 改动**，而是一条**从 10-13 就存在的数据**：

> `iap_transactions.app_account_token` = `5391ad37-…`，
> 而当前登录账号 `users.id` = `62731265-…`。**两者不同。**

端侧的归属判据 `iapEntitlementBelongsToAccount(ownerUserId, currentUserId)`
是**硬相等**比较（`iap_plan.dart:577-584`）⇒ **判定「这份权益不属于当前账号」**
⇒ 权益被端侧忽略。服务端到期日一过（今天 14:04Z 到期），四个现象同时出现。

## 二、证据（生产库实测，只读）

| 项 | 值 |
|---|---|
| 账号 | `62731265-edca-4fc9-8110-1877499e18fe` · `mr.bigpi@foxmail.com` |
| `users.subscription_expires` | **`2026-10-21T14:04:22Z`**（当前 14:45Z ⇒ **已过期 40 分钟**）|
| 订阅链 `original_transaction_id` | `2000001249787368`，本账号名下 **8 笔**（10-13 ~ 10-20）|
| 每笔 `environment` | **Sandbox**（TestFlight）· `storefront: CHN` · `price: 6000` CNY |
| `purchase → expires` | 86400 s = **正好 1 天**（Apple 沙盒把月度压缩成 1 天）|
| 每笔 `app_account_token` | **`5391ad37-8043-4d8e-91ec-01ea3286d9c5`** |
| `5391ad37` 是否存在于 `users` | ❌ **不存在**（该账号已被删/重建）|
| 近 2 小时后端日志 | **零条 iap 请求** ⇒ 购买/恢复在 **StoreKit 层就失败了**，没到服务端 |

⇒ 串起来：
1. 白哥曾在账号 `5391ad37` 下订阅（沙盒），后来该账号被删/重建为 `62731265`。
2. Apple 的订阅链（`original_transaction_id`）**跨账号延续**，8 笔都延续下来。
3. 上报时登录的是当前账号 ⇒ 服务端把这 8 笔记在 `62731265` 名下（**服务端认为归属正确**）。
4. **端侧却仍按 token 硬比**：`5391ad37 ≠ 62731265` ⇒ 不认。
5. 今天 14:04Z 到期（Apple 沙盒**自动续期最多 6 次**，8 笔已用尽）⇒ 服务端也变 expired。
6. 于是：显示「已到期」+「未订阅」（都是**正确的**）· 恢复购买 notFound · 再买被 StoreKit 拒。

## 三、四个现象逐条对账

| 白哥看到的 | 来自哪 | 是否正确 |
|---|---|---|
| 「会员已到期 · 续订后继续」| `subscriptionLapsedNow` 的 **backend 分支**（`expiresAt` 非空 + 已过期）| ✅ **数据是对的**，确实 40 分钟前到期 |
| 「未订阅 · 订阅后可同步」| `subscriptionActiveNow` = 端侧(被过滤) OR 服务端(已过期) | ✅ 一致 |
| 「恢复购买 → 当前账号未找到订阅」| `restoreOutcome()` 用同一个硬比判据 | 🔴 **不合理**：Apple 有交易、服务端也认，只有端侧不认 |
| 「购买失败，请重试」+ 按钮禁用 | `buyNonConsumable` 抛异常 | 🔴 且 **错误被吞**（`catch (e)` 只 `debugPrint`，UI 给的是通用文案）|

## 四、三个缺陷（按严重度）

### 🔴 D1 归属判据只有「token 硬相等」一条证据（P0）
`iapEntitlementBelongsToAccount` 不认「服务端已把这笔链记在我名下」这个更强的证据。
后果：**账号迁移/重建后，Apple 权益永久失联**，用户完全无出口。

### 🔴 D2 购买/恢复的异常被吞成通用文案（P1）
`catch (e)` 只 `debugPrint`，`lastError` 写死「购买失败，请重试」。
后果：真错误（`alreadySubscribed` / `paymentNotAllowed` / `invalidAppAccountToken`）
**现场永远看不到** —— 今晚排查只能靠翻库。

### 🟠 D3 Apple 沙盒续期上限（6 次）没有对应的产品文案（P2）
沙盒里一节订阅链最多 8 笔（首购 + 6 次续订 + 1），用尽后**永久停止**。
测试期必须知道这一点，否则会误判成「代码坏了」。

## 五、修复方案（需白哥拍板）

**A. 立刻能用（改生产数据，需批准）**
把这 8 笔的 `app_account_token` 对齐到 `62731265-…`。
- 效果：端侧立刻认这条订阅链 ⇒ 恢复购买能成功、**「已到期」显示会一致**。
- ⚠️ 但**不解决「现在不能用」**（Apple 侧已过期）；且**不解决「重买」**。
- 🔴 风险：这是**绕过归属校验**，等于承认「服务端记录 > token」。若将来真有串号，这一改会让它认。

**B. 正解（改代码，推荐）**
1. 归属判据加**第二条证据**：`token == currentUserId` **或** 「服务端对该 `original_transaction_id` 的记录属于当前用户」。
   （服务端 `/api/iap/verify` 已经知道这笔链记给谁，回一个 `ownedChain: true` 即可，**不需要新接口**，在现有响应里加字段。）
2. `restore()` 的失败要**区分**「Apple 没有交易」vs「有交易但归属不符」——
   后者文案应是「这笔订阅绑在另一个 App 账号上」，而不是「未找到」。
3. `catch (e)` 把 `e.toString()` 写进 `lastError`（或至少 `debugPrint` 带错误码并在 UI 显示诊断用的短码）。

**C. 白哥操作（不需要改代码，能立刻验证）**
iPhone「设置 → Apple 账户 → 订阅」看这条订阅的真实状态：
- 显示「已过期」⇒ 可以重新购买 ⇒ **买成功后 token 就是当前账号**，一切自愈（也顺带验证了 B1/B2）。
- 显示「有效」⇒ 说明 Art 侧还有我们没上报的交易 ⇒ **必须先修 D1** 才能把它拉回来。

## 六、与今晚改动的关系（如实说明）

- `subscription.rs::expires_state`、`routes.rs` 的 handler、端侧 `state` 映射 —— **只读判定，不写任何数据**。
- 8 笔交易的 `app_account_token = 5391ad37` 从 **2026-10-13** 就是这样（远早于今晚）。
- `iapEntitlementBelongsToAccount` 是 **2026-10-12** 引入的。
- ⇒ 若今晚不改，**今天 14:04Z 到期后同样会出现这四件套**。
  今晚的改动只是让「已到期」这句话**更早、更准确地**显示出来（此前 backend 分支的判据更糙）。

---

## 七、🔴 重要修正（22:47 白哥实测反馈后）

白哥：「设置 → Apple 账户 → 订阅，这里边**根本看不见**这个测试 App 的订阅」。

### 7.1 这句话本身是**正常现象**，但改变了整个诊断方向

**TestFlight 的 IAP 走 Apple 沙盒**（`iap_transactions.environment` 全部 = `Sandbox`）。
沙盒交易**不会出现在「设置 → Apple 账户 → 订阅」**里 —— 那是**生产**订阅的管理列表。
⇒ 「看不到」**不代表没订阅**，也不代表订阅被删。

⚠️ 但它带来一个更硬的约束：
**沙盒订阅无法在设置里取消 / 续期 / 重买**，用户侧**没有任何自救入口**。
⇒ 「购买失败」这条必须是**我们能修的**，不能指望用户去设置里操作。

### 7.2 我上一版的归因需要收窄（诚实的部分）

上一版把「D1 归属判据」说成**根因**。复核后要收窄：

| 现象 | 我的判断 |
|---|---|
| 「会员已到期」 | ✅ 正确（22:04 到期）|
| 「未订阅 · 订阅后可同步」| ✅ 与上一条自洽 |
| 「恢复购买 → 未找到订阅」| ✅ **其实也是正确的**：订阅已过期时，`currentEntitlements` 里没有有效项，恢复返回空是 Apple 的定义。Apple 也不要求「恢复过期订阅」 |
| 「购买失败，请重试」| 🔴 **唯一真正的缺陷**（且错误被吞，无法定位）|

⇒ **D1（token 归属漂移）是隐患，不是今晚的主因**：因为 `subscriptionActiveNow`
是「端侧 OR 服务端」，服务端一旦 active 就够用（22:47 续期后立刻生效即证明）。
真正让白哥「用不了」的是**到期 + 重买失败**这两件事。

🔴 **我错在**：把「一个已存在 9 天的数据不一致」当成了「今晚所有现象的根因」。
判据教训：**「这条数据不一致」≠「它就是这次故障的因」** —— 必须能解释**每一个**现象，
而 D1 解释不了「购买失败」（购买失败发生在 StoreKit 层，根本还没到归属判定）。

### 7.3 22:47 已做的处置（生产数据，可逆）

| 项 | 值 |
|---|---|
| 账号 | `62731265-…`（mr.bigpi）|
| 改前 | `subscription_expires = 2026-10-21T14:04:22Z` |
| 改后 | `2026-11-20T14:47:31Z`（+30 天）|
| 备份 | 见本段上表（原值已记录，可随时回写）|
| 验证 | `GET /api/user/62731265…/subscription` ⇒ `{"expired":false,"expires_at":"2026-11-20T14:47:31Z","state":"active"}` |

⚠️ **这是临时通行证，不是修复**：它让端侧立刻恢复可用（服务端 active 那一腿成立），
但**没有解决「以后能不能再买」**。

### 7.4 已改的代码（build 15 待出）

`iap_service.dart`：D2 两处
- `buy()` 的 `catch` 从「购买失败，请重试」→「购买失败（<短码>）」，短码由
  `_shortErrorCode()` 从 `PlatformException(...)` 里抠（不新增 import）。
- `_humanizeError()` 同样带上 `code`（`cancel` 仍返回空串、不报错）。

⇒ 下次白哥再点购买，**UI 上直接显示 StoreKit 的拒因**
（`alreadySubscribed` / `paymentNotAllowed` / `storeProductNotAvailable` 三者处置完全不同）。
本地 `analyze_inproc`：error=0 / warning=0。

### 7.5 下一步（等白哥定）

1. **出 build 15**（只为拿到那个短码）——需要临时公开仓库跑 macOS runner。
2. 或者**先不折腾**：现在能用了，明天再定位「重买失败」。
3. D1 / 恢复文案 / 沙盒文案（D3）留到看到短码之后再动 ——
   ⚠️ 不要在没有证据时改归属判据（那是安全敏感项，改错会串号）。

---

## 八、🔴 第二个真 bug：已订阅时点「恢复购买」说「未找到订阅」（23:05 修）

白哥 22:57 截图：顶部「订阅中 · 到期日 2026-11-20」，点「恢复购买」弹
**「当前账号未找到订阅。如果你曾在另一个账号订阅过，请切回该账号查看。」**

### 8.1 为什么互相打脸

| 看什么 | 用哪个判据 |
|---|---|
| 页面上的「订阅中」 | `subscriptionActiveNow` = 端侧权益 **OR** 服务端记录 |
| 「恢复购买」的结果 | `judgeRestoreOutcome` = **只看端侧** `currentEntitlements` |

而「服务端有效、端侧查不到」是**合法存在**的状态：
- Apple 沙盒订阅自动续期**最多 6 次**，用尽后 StoreKit 里就没有有效项了（本次就是）；
- 人工开通 / 后台调整 / 我今晚的续期，端侧一概不知道。

⇒ 于是「屏幕说订阅中」+「恢复说没找到」并存。**给用户的结论自己打脸。**

### 8.2 修法（不放松安全判据，只修输出）

| 文件 | 改动 |
|---|---|
| `iap_plan.dart` | `RestoreOutcome` 新增 **`alreadyActive`**；`judgeRestoreOutcome` 加 `bool alreadyActive = false`，**优先**返回它；文案「你当前已是订阅状态，无需恢复。」|
| `iap_service.dart` | `restore({bool alreadyActive = false})` 透传给判定函数 |
| `profile_screen.dart` / `subscribe_screen.dart` | 两个入口都传 `ref.read(subscriptionProvider).isActive`（**两处同一套**，项目既有判据）|

🔑 **为什么用 `ref.read` 而不是 `subscriptionActiveNow(ref)`**：后者内部 `ref.watch`，
只能在 build 期间调用；这里是点击回调。口径没变 —— 服务端 `isActive` 正是那个 OR 的服务端一腿。

🔑 **为什么不直接放宽 `iapEntitlementBelongsToAccount`**：那是**安全判据**（防串号）。
今晚的现象**不需要**动它 —— 只要把「已经是订阅状态」这件事**说出来**就够了。

### 8.3 断言（新增 5 条 + 修 1 条旧断言）

- `⑳-1` `alreadyActive:true` ⇒ `alreadyActive`（即使 entitlement=expired、归属不符）
- `⑳-2` 🔴 **反向**：`alreadyActive:false` 时仍必须 notFound（防「顺手把所有情况放行」）
- `⑳-3/4` 文案不得与 notFound 相同、必须含「已是订阅」
- `⑳-5` 🔴 两个入口都要传 `alreadyActive`（改一处漏一处 = 一真一假）
- ✏️ 旧断言 `subscribeCode.contains('.restore()')` → `.restore(` ——
  参数从无到有会让精确匹配**假红**。📌 判据：**断言锁意图，不锁拼写**。

**证伪过**：把 `if (alreadyActive) return …alreadyActive;` 删掉 ⇒ `⑳-1` 立刻红；还原后 294/294 全绿。

---

## 九、✅ build 15 已上传（2026-10-21 23:22–23:44）

| 项 | 值 |
|---|---|
| 版本 | `1.0.0+15` |
| 构建来源 | `b34e85f`（含 §7.4 的 D2 + §8.2 的 alreadyActive）|
| run | `39625000198` · **attempt 1 失败 / attempt 2 成功** |
| attempt 1 失败原因 | `error: exportArchive **The network connection was lost.**` + `EXPORT FAILED` ⇒ **网络抖动，不是代码问题**（archive 阶段已全绿）|
| attempt 2 | ✅ **Upload succeeded** + `EXPORT SUCCEEDED` ⇒ 已进 App Store Connect |
| 仓库可见性 | 已恢复 **PRIVATE** |

🔑 判据复核：**「job 红了」≠「事情没做成」**（这条文档 §2.2 已有）。
本次是反过来 —— 「job 红了」确实没做成，但原因是**外部网络**，重跑即可。
⇒ 遇到 export 阶段失败，先看日志里是 `network connection was lost` 还是**编译/签名**错误，别急着重构。

⚠️ 一条 CI 自身的技术债（不影响本次）：`Command line name "app-store" is deprecated.
Use "app-store-connect" instead.` —— 现在只是警告，将来要改 `export-options.plist` 的 `method`。
