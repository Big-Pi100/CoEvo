# 真机反馈（第二批）：复习状态/学习记录/成就不一致 · 同步后 UI 不刷新

> **日期**：2026-10-10 22:54（真机：后端 22:18 上线 · iOS 22:40 出包）
> **触发**：白哥「两端复习状态不一致、学习记录不一致、成就不一致；iOS 第一次同步失败、第二次成功但 UI 不刷新、重开才刷新；复习状态依然不一致」
> **状态**：🔴 **只调查，未改任何代码**（按铁律先报告 → 请示 → 再改）
> ⚠️ 本文不含明文 IP / 域名。

---

## 零、结论先行

| # | 症状 | 根因 | 证据强度 |
|---|---|---|---|
| 1 | 🔴 **学习记录 / 成就「不一致」（两端）** | `achievementSnapshotProvider` / `achievementUnlockTimesProvider` **没有订阅 `userDbRevisionProvider`** ⇒ 同步写库后**快照永不重算**；两端各自显示「进入 App 那一刻」的值 ⇒ 看起来不一致 | ✅ **代码级确凿**（且 `git log -S` 证明**从未**存在过）|
| 2 | 🔴 **同步后 UI 不刷新，重开才刷新** | 同 #1（`StatsCard` / 成就墙）；**结束同步后没有任何地方 invalidate 这两个 provider** | ✅ 代码级确凿 |
| 3 | 🔴 **复习状态「依然」不一致** | `pull` 带 `device_id` **排除本设备** ⇒ 本端曾推上去的事件**永远拉不回来**。该优化的前提是「本端推的，本端一定有」—— **实测该前提在数据被清后不成立** | 🟠 **强证据**（服务端计数差 = 现场）|
| 4 | 🟠 第一次同步失败、第二次成功 | 22:48 之前有 **4 次 401**（多端登录上线前的「互相踢」），22:48 之后 **0 次** | 🟢 已由上一批（B）覆盖 |
| 5 | 🟡 10-10 全天**零条** review / lookup / read 上传 | **待确认**：白哥 10-10 是否真的做了复习 / 划词 | ⚠️ **分叉点**，见 §四 |

🔑 **一句话**：**#1 是本轮唯一「确凿且一行可修」的缺陷**；#3 是**结构性**的、需要产品/协议层面决定；
#5 必须拿到设备侧证据才能定性。

---

## 一、服务端硬事实（只读核实）

### 1.1 ✅ 多端登录**已生效**

```
tokens 表 · 用户 b5b3a29d…
  token 7a9df1df…  created_at 1791638643
  token 53cd0aac…  created_at 1791643706
  token 956b91af…  created_at 1791643803
```
**3 行**（上限 3）· 且 **22:00 之后 401 = 0 条**（此前 18:45 / 19:36 / 21:31 / 21:49 各一次，都是 iOS 的
「互相踢」）⇒ **B 的修复在真机上确认有效**。

### 1.2 🔴 两端 pull 的计数差 = **6**，恰好是 iOS 自己推过的那 6 条

```
14:48:27  pull  since=1970-01-01T00:00:00Z  device=dev_37999cab…(iOS)   review=133
14:50:03  pull  since=1970-01-01T00:00:00Z  device=dev_a84d55c8…(安卓)  review=139
```

服务端 `sync_review_log` 的 device 分布：

```
dev_dac9009348be228eee9640580f25c91f   133 条  (09-28 ~ 10-08)
dev_37999cabe859f34c86afe9000d0a69dd     6 条  (10-09)
```

⇒ **133 = 139 − 6**，而 6 正是 `dev_3799…`（**iOS 自己**）推的那 6 条。
⇒ 服务端按 `device_id` **排除了 iOS 自己的数据**（设计如此：「本端推的，本端已经有了」）。

🔴 **这个前提在本端数据被清空过时不成立** —— 而 `pull` **没有任何兜底**：
既不会因为「本地行数对不上」而重拉，也没有「强制全量重建」的入口。
⇒ 该端**永久少 6 条**，**且全程不报错**。

> ⚠️ **如实标注**：我**无法直接读设备**。本节成立需要「iOS 本地确实缺那 6 条」。
> **可证伪的验证**（见 §五）：iOS 与安卓对比「累计复习次数」——
> 若 iOS = 133、安卓 = 139 ⇒ 证实。

### 1.3 🟡 10-10 全天没有新的 review / lookup / article_read

| 表 | 行数 | 最新 `received_at` |
|---|---|---|
| `sync_review_log` | 139 | **2026-10-09T14:08:28Z** |
| `sync_lookup_event` | **1** | 2026-10-10T13:23:13Z |
| `sync_article_read` | 46 | **2026-10-09T02:30:09Z** |
| `sync_user_word` | 46 | **2026-10-09T16:50:33Z** |
| `sync_setting` | 2 | 2026-10-10T14:49:43Z |
| `sync_achievement_unlock` | 5 | 2026-10-10T13:23:13Z |

且所有 push 日志里 `review=0` **恒成立**（两端、每次）：

```
14:49:43 push device=dev_a84d…(安卓)  review=0 word=0 read=0 … set=1
14:51:51 push device=dev_a84d…(安卓)  review=0 …
14:52:37 push device=dev_a84d…(安卓)  review=0 …
```

🔑 **这是「分叉点」**：它**要么**说明「白哥 10-10 没做新复习」（正常），
**要么**说明「做了但端侧没采集到」（严重）。**见 §四**。

---

## 二、🔴 确凿缺陷 #1：成就快照**从未**订阅 revision（症状 1 + 2 的直接根因）

`app/lib/providers/achievement_provider.dart`：

```dart
final achievementSnapshotProvider =
    FutureProvider<AchievementSnapshot>((ref) async {
  final db = await ref.watch(userDbProvider.future);   // ← 只 watch「库实例」
  return AchievementService(db).snapshot(now: DateTime.now());
});

final achievementUnlockTimesProvider =
    FutureProvider<Map<String, DateTime>>((ref) async {
  final db = await ref.watch(userDbProvider.future);   // ← 同上
  return AchievementService(db).loadUnlocks();
});
```

**全仓 `userDbRevisionProvider` 的订阅点**（读端）里**没有这两个 provider**：

```
bookmark_provider · highlight_provider ×3 · review_list_provider ×2 · sync_provider(写端 bump) · word_db_provider(写端)
```

**且没有任何地方在同步结束后 invalidate 它们** ——
唯一的 `ref.invalidate` 在 `checkAndRefreshAchievements`（`:67`）里，
**只在该函数发现「新解锁」时才调用**。

⇒ **同步把数据写进库之后，学习记录卡与成就墙都不会重算** ⇒ 用户看到的是
「**进入 App 那一刻**」的值 ⇒ **重开 App 才刷新**（provider 重建）
⇒ 两端各自显示**不同时刻的陈旧快照** ⇒ **「不一致」**。

### 🔴🔴 更要紧的一点：**上一轮报告说这个已修，但代码里没有**

`git log -S "userDbRevisionProvider" -- app/lib/providers/achievement_provider.dart`
→ **空**（该文件**从未**出现过这个标识符）。

而 `docs/review/achievement-stats-not-syncing-2026-10-10.md`（10-10 下午）写着：
> **修法**：**P0 = 1 行**（加 `ref.watch(userDbRevisionProvider)`）

📌 **判据**：**「写了声明」≠「落到了代码」** —— 这正是那条
「**「注释/记忆里的声明」须 `grep` 才算数**」的又一实例，而且这次连**报告本身**也是声明。

> ✅ **附带的好消息**：`reviewListProvider` 与 `reviewDueCountProvider`
> **都有** `ref.watch(userDbRevisionProvider)` ⇒ **复习页本身会跟随刷新**。

---

## 三、🟠 结构性缺陷 #2：「排除本设备」缺少兜底（症状 3）

服务端 `pull` 按 `device_id` 排除本设备推的数据（省流量、避免回声）。
**判据「本端推的 ⇒ 本端一定有」** 在下列情形**不成立**：

| 情形 | 后果 |
|---|---|
| 卸载重装 | 本地全清 ⇒ 自己推的事件**永远拿不回** |
| 换账号后清数据 | 同上（`local_meta.owner_user_id` 变化触发清空）|
| 库损坏 / 迁移异常重建 | 同上 |

🔴 **而本批（v11）刚修过的，正是同一族的另一个面**：
「游标与数据同生命周期」。⇒ 说明我们**已经意识到「本地可能丢数据」**，
但只堵了「游标」这一处，**没堵「排除本设备」这一处**。

### 与症状的对应

若 iOS 本地缺那 6 条 ⇒ iOS 的 `card_review_state` 重放**少 6 个事件的输入**
⇒ 部分词的「下次到期时间 / 熟练度」与安卓不同 ⇒ **复习列表不一致** ✅
⇒ 且**重开 App 也不会好**（因为事件根本不在本地）⇒ 与白哥说的「**依然不一致**」吻合。

---

## 四、🟡 待确认的分叉点：10-10 零条 review / lookup

**我已逐条排除的端侧可能**（静态核实，未发现缺陷）：

| 候选 | 核实结果 |
|---|---|
| `logReview` 写入时 `synced` 默认值错 | ✅ 正确（`{int synced = 0}`）|
| `review_log.synced` 列 DDL 默认值错 | ✅ 正确（`NOT NULL DEFAULT 0`）|
| `lookup_event.pending_push` 默认值错 | ✅ 正确（`NOT NULL DEFAULT 1`）|
| push 的 JSON 键名 / 结构与服务端不匹配（**静默传空**）| ✅ **两端一致**（`review_events` + `word_id`/`rating`/`duration_ms`/`reviewed_at`）|
| 服务端 `PushInput` 字段名错 | ✅ 一致（`#[serde(default)]` + 同名）|
| `pendingReviews` 查询条件错 | ✅ 正确（`WHERE synced = 0`）|
| `markReviewsSynced` 在 push 前被调用 | ✅ 在 `await _pushHttp(...)` **之后** |

⇒ **静态层面查不出「推不上去」的原因** ⇒ 最可能就是
**「本地确实没有待推的行」= 白哥 10-10 没做新复习**。

🔑 **判据：在两种解释都成立时，不要选更像 bug 的那个 —— 去拿能区分它们的证据。**
**最小验证动作**（见 §五）：**在 iOS 上做一次复习**，然后看服务端日志那一行是否 `review≥1`。

---

## 五、修复建议（按优先级 · 每项给选项）

### 🔴 P0 · 成就快照订阅 revision（**必修 · 2 行**）

```dart
final achievementSnapshotProvider =
    FutureProvider<AchievementSnapshot>((ref) async {
  ref.watch(userDbRevisionProvider);        // 🆕 必须放在 await 之前
  final db = await ref.watch(userDbProvider.future);
  ...
});
```
（`achievementUnlockTimesProvider` 同样加一行）

| 选项 | 做法 |
|---|---|
| **A** ⭐ | 两个 provider 各加 `ref.watch(userDbRevisionProvider)`（**与 `reviewListProvider` 同款**，口径统一）|
| B | 在 `sync_provider` 同步成功后 `ref.invalidate(...)` 这两个 —— ❌ 不推荐：又回到「写端点名读端」的**必漏结构** |

**建议 A。** 依据：写在 `review_list_provider.dart` 的注释里 ——
> 「**写端不必点名本 provider** —— 只要 `bump()` 一次 `userDbRevisionProvider`，本 provider **会自动重算**」

### 🔴 P1 · 「排除本设备」加兜底（**需先定口径**）

| 选项 | 做法 | 代价 |
|---|---|---|
| **A** ⭐ | **首次全量拉取（`since == null`）时不排除本设备** —— 「本端推的、本端一定有」在「刚重装 / 刚迁移」时**最不可靠** | 首次多拉几百条（一次性）|
| B | 加「**强制全量重建**」入口（设置页）—— 让用户能自救 | 需要 UI + 用户知道要点 |
| C | 服务端返回「**本端推的条数**」，端侧与本地行数对不上就告警/重拉 | 协议改动最大，但**能自动发现** |

**建议 A（立刻）+ C（后续）**。B 作为兜底入口也值得有。

### 🟠 P2 · 全量拉取时应重放**全部**词

`_applyReviewEvents` 现在：

```dart
if (events.isEmpty) return 0;            // ← 没事件就完全不重放
for (final entry in byWord.entries) { … } // ← 只重放「本批拉到事件」的词
```

⇒ 若某词的 `card_review_state` 缺失 / 陈旧，而它的事件**早就在本地**（不在本批里），
**永远不会被重建**。全量拉取（`since == null`）时应把 `card_review_state` **整体重放一遍**。

### 🟢 P3 · 从「报告」到「断言」

本轮最值得记住的教训是 **#1 那份报告声称已修、代码里却从未存在**。
⇒ 建议给这条加**断言**（`verify_achievement_rules.dart` 或新建）：
> `achievement_provider.dart` 必须含 `ref.watch(userDbRevisionProvider)`

🔑 **判据：凡是「X 已修」的结论，都要落到一条能被 CI 跑的断言上；否则它只是一句话。**

---

## 六、请白哥定

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | P0（成就订阅 revision）改不改 | ✅ **改**，2 行，风险极低 |
| 2 | P1 的「排除本设备」兜底选哪个 | ✅ **A（首次全量不排除）**，可选加 B |
| 3 | P2 一起做吗 | ✅ 建议一起（同属 pull 的重建逻辑）|
| 4 | **§四 的分叉点怎么验** | 见下 |

### §四 的最小验证（**1 次复习即可定性**）

在 **iOS** 上随便复习 1 张卡 → 点同步 → 然后我查服务端日志：
- 出现 `review=1` 且 `sync_review_log` **+1 行** ⇒ 推送链路正常，本轮症状纯由 #1/#3 解释
- 仍是 `review=0` ⇒ **端侧采集有真 bug**，我按「严重」级别继续查

（若不方便做，也可以直接做下面这件事——那 #5 就直接结案。）

---

# 七、✅ 分叉点已解决 + 真正的根因 + 实施记录（2026-10-10 23:0x）

## 7.1 ✔ §四 的分叉点有答案了：**推送链路完全正常**

白哥在 iOS 上复习了 2 个词。服务端日志随即出现：

```
23:04:01  sync_push  device=dev_a84d55c8…  review=2  …  ach=1
23:04:10  sync_push  device=dev_3799cab…   review=0
```

⇒ **`review=2`** —— 那 2 个复习事件**确实推上去了**。
⇒ 我 §四「最可能是没做新复习」的**措辞需要修正**：**做了，也推上去了**；
  真正的问题在后面一节。

## 7.2 🔴🔴 **真正的根因：自动同步里**只有「登录后」会拉

看那两行日志：**两次都是 `push`，中间没有 `pull`**。

查 `sync_provider.dart` 的全部触发时机：

| 时机 | push | pull |
|---|---|---|
| `runSyncAfterLogin`（登录后）| ✅ | ✅ |
| 登出前 flush | ✅ | ❌ |
| **进后台（`paused`）** | ✅ | ❌ |
| `syncNowFromUi`（手动点云朵）| ✅ | ✅ |
| **回到前台（`resumed`）** | — | — | 🔴 **根本没有这个时机** |

而 `app.dart` 的 `didChangeAppLifecycleState` **只处理 `paused`**（且它是 `pushOnly`）。

⇒ **日常里最频繁的动作（切来切去）只推不拉**：
A 端复习 → 切到 B 端 ⇒ B 端**从不 pull** ⇒ **永远看不到 A 的改动**。

🔴🔴 **而「重开 App 就对了」正好对上**：重开走「**登录后**同步」——
**那是唯一会拉的自动时机**。症状与机制**完全吻合**。

> 🔑 **判据：`resumed`（回到前台）是「另一端可能改过」的最强信号** ——
> 用户切回来就是想看最新的，此处**必须 pull**。
> 而 `paused` 只推是有道理的（要快，不拖住退出）—— **两者刻意不同**。

## 7.3 两处真机截图的读法（顺带纠正一个误判）

两张图我一开始以为是「iOS vs 安卓」，实际是**同一台 iOS 复习前/后**：

| | 图（复习前 / 后）|
|---|---|
| 副标题 | 「今天有 2 个该看」→「今天没有要复习的」|
| `beginning` | 19 小时后 → 18 小时后 |

🔑 `19h → 18h` 是**时间推进**（同一 `dueAt`，`now` 变晚）⇒ **两图不矛盾**，是先后关系。
⚠️ 我一度想把这 1 小时差当成「两端重放结果不同」的证据 —— **那是错的**，已纠正。

## 7.4 实施（A + B + C，全部白哥已明确要求或已确认缺陷）

| # | 改动 | 文件 | 要点 |
|---|---|---|---|
| **A** | 两个成就 provider 订阅 `userDbRevisionProvider` | `providers/achievement_provider.dart` | **2 行**；补上 §二 那个「报告说已修、代码里没有」 |
| **B** | **回前台做完整同步** | `app.dart` + `providers/sync_provider.dart` | 新增 `syncWhenAppResumed`（`pushOnly: false`）；`paused` 保持只推 |
| **C** | **复习页下拉刷新** | `screens/review_screen.dart` | 下拉**先调 `syncNowFromUi`（push+pull）** 再等读端重算；空态也可下拉 |

C 的两个细节（都不是随手写的）：
- 🔴 **下拉必须先拉云端** —— 只重算本地是「**骗人的仪式**」（用户看到的还是同一份数据）
- 🔴 **空态/错误态也要能下拉** —— `RefreshIndicator` 只在子节点**可滚动**时响应；
  「今天没有要复习的」那一屏默认**不可滚动** ⇒ 下拉失效 —— **而这正是用户最想下拉试试的场景**

## 7.5 🔑 证伪：**抓出我自己写的两条假绿**

第一版断言用「函数名 + 大窗口正则」：

```dart
RegExp(r"void syncWhenAppResumed[\s\S]{0,320}?pushOnly: false")
```

**把函数里的 `false` 改成 `true`，它照样绿** —— 正则**越过了函数边界**，
匹配到紧邻的 `syncNowFromUi`（那里也有 `pushOnly: false`）。
⇒ 改成 `between()` **切片**，边界用「**下一个函数定义**」而不是「猜一个够大的字符数」。

🔴 改完**还是假绿**，第二次的坑更深：边界串写成 `'void syncNowFromUi('`，
而真实签名是 **`Future<void> syncNowFromUi(`** ⇒ `indexOf` 返回 -1 ⇒
**切片跑到文件尾**；而我那条「切片有效」的前提只验了「非空 + 含某词」—— **过长的切片照样满足**。

✅ **最终修法（两条缺一不可）**：
1. 边界串与**真实签名逐字一致**；
2. **前提断言必须验「上界真的截住了」**：`!slice.contains(<下一个函数的名字>)`。

> 📌 判据（本族已有，本次再确认）：**「能切片」不等于「切对了」** ——
> 切片的前提断言必须同时验**下界**与**上界**，否则它会**静默退化成整文件 `contains`**。

**证伪结果**：三处改坏（A 去掉一处 watch · B 改 `pushOnly: true` · C 去掉 `await syncNowFromUi`）
⇒ **精确红 3 项** ✅

## 7.6 验证

| 项 | 结果 |
|---|---|
| `verify_sync` | **182**（原 169，+13；含【16】新段 9 条 + 3 条切片前提）|
| `analyze_inproc`（app/lib）| **error = 0** |
| 其余 query_verify / iap / ebook / trace | 见提交说明 |

## 7.7 ⏳ 仍未做（沿用 §五）

| # | 事项 | 状态 |
|---|---|---|
| P1 | `pull` 排除本设备的兜底 | ⏳ **待定**（§三，需先定口径）|
| P2 | 全量拉取时重放**全部**词 | ⏳ 待定 |
| P3 | 把「X 已修」落成 CI 断言 | ✅ **本轮已是一个实例**（§7.5 那条断言就是为它写的）|
