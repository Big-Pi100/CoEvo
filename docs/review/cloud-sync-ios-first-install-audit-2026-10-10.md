# 云端同步审计 · iOS 首装「书架空 / 复习卡不一致 / 收藏要重开才刷」（2026-10-10）

> 触发：白哥真机（iOS）实测 —— 端侧翻译 OK，但**书架完全没同步（iOS 端空）· 复习卡片不一致 ·
> 收藏一致但要关闭后刷新才同步**；要求「检查云端同步是否真实实现」+「同步到本地要有进度显示」。
> 状态：✅ **已批准实施**（白哥「同意建议」）。报告先按白哥后续补充的事实**更正一处推断**（见 §二①）。
> 补充事实（白哥 01:08）：「**安卓上也只有一本书，但 iOS 一本都没有**」
> ⇒ 修正：云端 `sync_book = 1` 行**是正确的**（安卓本来就只有 1 本），**指纹不是本 case 的原因**；
>    真正的问题是 **iOS 连这 1 本都没有** ⇒ 精确链路见 §二①（`blob_size = 0` 使它**两边都不渲染**）。

## 〇、三句话结论

| 症状 | 根因（已验证） | 性质 |
|---|---|---|
| **iOS 书架空** | ① `blob_size = 0` ⇒ 那本书记录**两侧都不渲染**（本地没有 + 云端列表只认 `blob_size > 0`）② 书文件**上传从未发起过**（队列拿到的 `rawDir` 是空串）⇒ 永远修不成 `blob_size > 0` | **断在「上传」，不是拉取** |
| **复习卡片不一致** | `card_review_state` 被设计为**纯派生态**（不参与同步），新设备只能靠重放 `review_log` 重建 ⇒ 「加了没复习」的词与「孤儿划线卡」过不去（实测各 1 个）。**从云端推算 iOS 应显示 31 张** | 设计取舍 + 历史划线未上云 |
| **收藏要重开才刷** | `bookmark_provider` **0 处**订阅 `userDbRevisionProvider` —— 其余 5 类读端**都订阅了** | **1 行可修** |

## 一、实测事实（线上只读 · 2026-10-10 00:5x）

账号 `690861018@qq.com` = `b5b3a29d-151f-4330-b293-ee2c9b7b90d5`（`subscription_expires = 2027-10-09`）

| 表 | 该账号行数 | 最新 `received_at` |
|---|---|---|
| `sync_review_log` | **139** | 10-09 14:08Z |
| `sync_user_word` | **46**（未删 32 / 已删 14） | 10-09 16:50Z |
| `sync_article_read` | **46** | 10-09 02:30Z |
| `sync_bookmark` | **3** | 10-09 02:30Z |
| `sync_highlight` | **1** | 10-09 11:38Z |
| **`sync_book`** | 🔴 **1** | 10-09 09:41Z |
| `sync_book_progress` | **1** | 10-09 11:47Z |

**三条硬事实**：

1. `sync_book` 那唯一 1 行 = 《Alice's Adventures in Wonderland》，**`blob_size = 0`**（= 云端**没有**这本书的文件）
2. 服务端**整个文件系统里不存在任何 blob 目录** —— `book_storage.rs:137` 的缺省是
   `data/book_blobs`（`WorkingDirectory=/opt/coevo`）；我全盘搜 `/opt /var /srv /home /tmp`
   里名字含 `blob` / `book` 的目录 ⇒ **0 命中**
3. **nginx access log（15 个文件 · 覆盖近一个月）里 `POST /api/books/blob` 只有我自己的 curl 记录**
   （UA = `curl/8.x`）⇒ **App 从未请求过一次上传**

> 📌 结论先行：**同步不是假的** —— push 真的在工作（7 张表都有数据）。**断的是「书文件上传」这一环**，
> 而且它**从未跑通过一次**。「接线存在」≠「跑通过」。

## 二、书架：断在「上传」，且三层原因叠加

### ① 🔴 iOS「一本都没有」的精确链路（已按白哥补充事实更正）

**更正**：我原先推断「其余书没有指纹」——**错了**。白哥确认**安卓本来就只有 1 本**，
所以云端 `sync_book = 1` 行是**正确**的，指纹不是本 case 的原因。

书架页的书单 = 两个来源（`book_library_screen.dart:90/95`）：

| 来源 | 内容 | 这本书在不在里面 |
|---|---|---|
| `bookListProvider` | **本地** `book` 表 | ❌ iOS 是新装、本地无书 |
| `cloudOnlyBooksProvider` | 只取 `presence[hash] == CloudPresence.cloudOnly` | ❌ 而 `presenceByHash` **只认 `blob_size > 0`**，它是 **0** |

⇒ **两侧都不渲染 ⇒ 书架完全空** ✅ 这就是「一本都没有」的全部原因。

📌 **它不是 bug，是「正确地把一个坏状态藏起来了」**：10-09 那次改动的**目的**正是
「不许显示『云端有』却下不来」（点下载会 404）。所以它**有意**不显示。
🔴 **但它缺一个出口** —— 用户**看不到任何提示**，不知道：
「这本书在书单里 / 云端没有文件 / 需要回源设备重传」。⇒ 见 §七 P1「补齐出口」。

### ⑤ 好消息：一旦能上传，字段契约是对的（我核过）

### ② 🔴 上传从未发起 —— 代码级根因（最硬的一条）

```dart
// book_cloud_provider.dart:47
final bookUploadQueueProvider = Provider<BookUploadQueue>((ref) {
  final rawDir = ref.watch(bookRawDirProvider).valueOrNull ?? '';   // ← 首次必为 null
  ...
});
```

- `bookRawDirProvider` 是 **FutureProvider**（`book_raw_dir_provider.dart:28`）
- 全库**只有 1 处读取** `bookUploadQueueProvider`：`book_import_flow.dart:299`（导入后上传）
  ⇒ **它第一次被构造，就是「要上传」的那一刻**
- 那一刻 `bookRawDirProvider` 刚被 `watch` 触发、**还没完成** ⇒ `valueOrNull == null` ⇒ `rawDir = ''`
- 队列里立刻用它跑：`readRawBook(rawDir: '')` = `File('/<hash>.epub')`（`book_raw_store.dart:33`）
  ⇒ 文件不存在 ⇒ `bytes == null` ⇒ **`skippedNoRaw++` 跳过**（`book_upload_queue.dart:157-163`）
  ⇒ **一个 HTTP 请求都不会发** ✅ 与 nginx 证据**逐条吻合**

（`readRawBook` 只 `exists()` 判断，不抛异常 ⇒ 整段**静默**，只计入 `skippedNoRaw`。）

### ③ 注释承诺的 3 个触发点，只实现了 1 个

`kickBookUpload` 的文档写着「调用时机：① 导入成功后 ② 书单同步后 ③ 用户手动重试」。
实测调用点**只有 ①**（`book_import_flow.dart:146/297`）：
- ②「书单同步后」—— **没有**（`_runSync` 里没有 kick）
- ③「手动重试」—— **没有**（书架页只有「下载云端书」，无上传/重试入口）

⇒ 因为 ② 的缺失，②本该覆盖的「导入时未登录 / rawDir 空 / 网络失败」这三种情形
**在之后永远不会自动重试** ⇒ **无自愈路径**。

> 📌 判据：**「文档里承诺的触发点」必须逐个 grep 调用点**。
> 这一条正是本项目反复记的「写了没人跑」——只不过这次是「**写了一半**」。

### ④ 即使修好上传，iOS 也下载不了（新口径下没有「云图标」）

`presenceByHash` 自 2026-10-09 起**只认 `blob_size > 0`**（我昨天刚修的那个）。
当前 `blob_size = 0` ⇒ 那本书**连「云图标」都不会显示** ⇒ 书架看起来「完全空」。

### ⑤ 好消息：一旦能上传，字段契约是对的（我核过）

- 服务端路由在 ✅（`POST /api/books/blob`：`GET` → 405、`POST` 空体 → 400，符合预期）
- multipart 字段名**逐字一致** ✅（端侧 `content_hash`/`ext`/`file` ≡ 服务端 `book_blob_handler.rs:226/234/242`）
- 服务端要求「书单行先存在」✅ —— 而书单确实先推了（`pushOnce` 里 `books` 与其余五类同一批）

## 三、复习卡：机制上是「派生态」，所以两端天然可能不同

- `card_review_state` **不参与同步**（`sync_service.dart:25` 的设计声明），新设备由
  `_applyReviewEvents` 重放 `review_log` 重建 —— 重放的是**本地全部事件**（`sync_service.dart:604-609`）
  ⇒ **状态本身算得对** ✅
- 但 **Android「加入生词本」时会立刻建一行 `card_review_state`**（`word_lookup.dart:445-446`：
  「INSERT user_word + card_review_state 是同一动作的两半」）⇒ 这类词**没有事件可重放**
  ⇒ 在新设备上**根本不出现**。实测该账号这类词 = **1 个**（`w000443`）
- 「**无主划线卡**」判据（10-09 新增）会在 iOS 上挡掉**历史划线卡**：划线同步 10-09 才接入
  ⇒ 云端 `sync_highlight` 只有 1 行；而复习日志里有 1 个 `hl:` 事件，其划线**不在云端** ⇒ 被挡。
  实测 = **1 个**（`hl:8613b24d-deff-4284-bc70-b5bfe2efb6b6`）

**📌 从云端数据推算：iOS 端应显示 31 张复习卡**（`w:` 27 · `ext:` 4 · `hl:` 0），
过滤掉 6 张（5 张生词已删/暂停 + 1 张孤儿划线卡）。

> ⚠️ **能力边界（如实说）**：我看不到你的屏幕。上面两条是**已验证的结构性差异**，量级都是 **1–2 张**。
> 若你看到的是**大面积不同**（比如 iOS 只有零头几条、或标题是 `w000129` 这种 ID），
> 那是**另一类**问题，需要你再给一句方向（多/少、哪张、标题长什么样）我才能钉死。

## 四、收藏：根因确定（**1 行可修**）

`_runSync` 里 pull 之后**已经** bump 了两个 revision（`sync_provider.dart:256-259`，10-09 修的）。
但 —— **bump 只对「订阅了它的读端」生效**：

| 读端 provider | 订阅 revision |
|---|---|
| `review_list_provider` | ✅ 3 处 |
| `highlight_provider` | ✅ 5 处 |
| `book_provider` | ✅ 3 处 |
| `word_db_provider` | ✅ 2 处 |
| **`bookmark_provider`** | 🔴 **0 处** |

⇒ 收藏数据**落了库**（所以「一致」），但内存里的 `Set<int>` **不重算** ⇒ 界面保持旧值
⇒ **「关闭后再打开才看到」** ✅ 与白哥描述**完全吻合**。

> 📌 判据：**「写端 bump」只有在「读端也订阅」时才有效**。
> 加 bump 时必须**逐个读端核对订阅** —— 这是同一个洞的另一半，
> 只补 bump 不核订阅，就会留下「6 类里恰好漏 1 类」这种最难发现的缺口。

## 五、「云端同步是否真实实现」· 逐类结论

| 能力 | 结论 | 证据 |
|---|---|---|
| **push**（端 → 云） | ✅ **真实工作** | 7 张表都有该账号数据；幂等键 + 条件 UPSERT 都在 |
| **pull**（云 → 端） | ✅ **真实工作** | `pullOnce` 七类全接线；顺序正确（`user_words`/`highlights` 先落）；游标用 `server_time`；pull 后 `_claimBookProgress` |
| 服务端 pull 返回 | ✅ 完整（**含 `books`，无 `blob_size` 过滤**） | `sync_handlers.rs` 逐段核过 |
| **书文件上传** | ❌ **从未跑通（0 次请求）** | nginx + 无 blob 目录 + 代码级根因 |
| 书文件下载 | ⚪ **无法验证**（云端本来就没有文件） | — |
| **同步进度 UI** | ❌ 只有「云朵」五态，**无阶段、无计数** | `sync_status.dart` |

## 六、🔴 实施中**又发现一处断裂**：上传成功后没人写回 `blob_size`

`book_upload_queue` 在 `case BlobUploaded()` 里只做 `done++` —— **没有任何地方**
把服务端返回的 `blob_size` 写回本地 `cloud_book`。

而 `presenceByHash` 与 `pendingUploadHashes` **都只认 `blob_size > 0`** ⇒ 后果两个，都静默：
1. **每次 kick / 每次同步都重传同一份文件**（白耗流量 + 服务端配额时间）
2. 书架**永远不显示「已上云」** ⇒ 用户以为没传成功（正好是白哥说的「不知道是 bug 还是在跑」）

⇒ 已一并修：新增 `CloudBookRepository.markUploadedBlob()` + 队列的 `onUploaded` 钩子
（`blob_size` 由服务端算，端侧只负责**记下来**）。

## 七、你要的「同步进度显示」· 方案

**现状（好消息）**：`SyncStatus` 已有 `idle / syncing / ok / failed / skipped` 五态
+ `SyncReport` 的各类计数 + 云朵标 ⇒ **地基在，缺的是「阶段 + 计数 + 进行中的可视」**。

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A ⭐** | `SyncStatus` 升级为**阶段化**：`推送到云端 → 拉取变更 → 写入本地`，每阶段带「已处理 N 条」；在**书架页 / 复习页顶部**一条**细进度条**（仅 `syncing` 时出现），完成后换成一句人话（「已同步 31 张复习卡 · 3 条收藏」） | 日常可见、成本中；**失败必须带重试按钮** |
| **B** | 云朵标点开 → 「同步详情」面板（每类推/拉条数 + 最近一次时间） | 适合诊断，**不解决「进行中不知道」** |
| **C** | **首次同步**（游标为空）走**全屏进度** | 首装要拉全量，等待感最强；日常不需要 |

**建议 A + C**（首装全屏 + 日常细条），并且**文案要写清「卡在哪一步」** ——
你现在的痛点正是「不知道是 bug 还是在进行中」；**没有出口的失败**必须一并消灭（重试按钮）。

## 七、修复建议（按优先级）

| P | 项 | 改动面 | 说明 |
|---|---|---|---|
| **P0** | `bookmark_provider` 订阅 `userDbRevisionProvider` | **1 行** | 症状「收藏要重开」立即消失 |
| **P0** | 修 `rawDir` 空串（改为 `await ref.read(bookRawDirProvider.future)`，或让队列在 run 时取目录） | 1 处 | 让上传**真的能发出请求**（当前 0 次） |
| **P0** | 补触发点 ②③：书单同步后 kick + 书架页「重新上传」入口 | 中 | 否则失败后**永远不重试**（注释已承诺但未实现） |
| **P1** | 同步进度显示（方案 A + C） | 中 | 你的明确诉求 |
| **P1** | 🆕 **补齐「隐形书」的出口**：`blob_size = 0`（书单有记录、云端无文件、本地也没有）时，书架要能看到它并给出人话（「等待上传 / 需回源设备重传」） | 小 | 否则那本书**永远隐形**（正是 iOS 一本都没有的直接观感） |
| **P2** | 老书补 `content_hash`（原始文件在 ⇒ 补算；不在 ⇒ 明示「此书无法同步」） | 中 | ⚠️ **本账号不构成问题**（安卓只有 1 本且是新导入的、有指纹）。仅对「v2 之前导入的老库」成立 —— 保留为已知缺口 |
| **P2** | 历史划线补推（10-09 才接入 ⇒ 之前的历史划线不在云端） | 小 | 影响 `hl:` 复习卡 |
| **P2** | 「加了没复习」的词在新设备不可见（pull 后为 `user_word` 建初始 state 行） | 小 | 实测 1 个 |

## 九、P0 实施记录（✅ 已完成 · 本批）

| # | 改了什么 | 文件 |
|---|---|---|
| 1 | 收藏读端**订阅修订号**（`bump` 的另一半） | `providers/bookmark_provider.dart` |
| 2 | 上传目录改为**回调、在 `run()` 时 await**（修「0 次请求」） | `services/ebook/book_upload_queue.dart` · `providers/book_cloud_provider.dart` |
| 2b | 🆕 **上传成功后写回 `blob_size`**（`markUploadedBlob` + `onUploaded` 钩子） | `services/ebook/cloud_book_repository.dart` · 队列 · provider |
| 3 | 触发点 ②：同步（pull）后**补一次上传尝试** | `providers/sync_provider.dart` |
| 4 | 触发点 ③：书架**「未上云 N」药丸 → 手动重试**（无待传时**不存在**） | `screens/reading_tab_screen.dart` · 新 `pendingUploadCountProvider` |
| 5 | 下载路径同类问题（`valueOrNull` 同步取目录）一并修 | `screens/book_library_screen.dart` |

**验证**
- `analyze_inproc`：**error=0 warning=0**（info 7 条为存量）
- `verify_book_cloud`：**48/48**（原 31 ⇒ 净增 17 条判据）
- `query_verify` **全量 51 脚本 0 失败** · `tokens_verify` **721/0**（基线不变）· `trace_verify` 0 失败
- **证伪 6 条**（全部：注入 ⇒ 变红 ⇒ **逐字节还原**）：
  撤掉收藏订阅 / 回退成构造时取目录 / 上传成功后不写回 / 删掉补传调用 /
  药丸不接重试回调 / 目录恒空（模拟旧 bug）

**🔑 本批新记的判据（都已写进记忆）**
1. **「接线存在」≠「跑通过」** —— 只能由外部痕迹回答（access log / 落库行数 / 计数）
2. **`bump` 只在「读端也订阅」时才有效** ⇒ 加 bump 必须逐个读端核对订阅
3. **`Provider` 里 `watch(FutureProvider).valueOrNull` 首次必为 null** ⇒ 必需配置在使用时 `await`
4. **上传类链路必须闭环**：成功 ⇒ 写回本地状态，否则「反复重传 + 状态永远不对」

**⚠️ 本批的预期效果（待真机验证）**
- 安卓：那本《Alice》下次同步（或点「未上云」药丸）**第一次真的把文件传上去** ⇒ 云端 `blob_size > 0`
- iOS：随后 pull 到 `blob_size > 0` ⇒ 书架显示**云图标**、可下载 ⇒ 「一本都没有」消失
- 收藏：pull 后**立即刷新**，不再需要关掉重开

## 附、原始批次的实施顺序（规划时写的，保留）

| # | 项 | 改法 |
|---|---|---|
| 1 | 收藏读端订阅 revision | `bookmark_provider` 内 `watch(userDbRevisionProvider)` |
| 2 | `rawDir` 空串 | `BookUploadQueue` 的目录改为**回调、在 `run()` 时 await** |
| 3 | 补触发点 ②③ | 同步后 kick + 书架页**可见的上传/重试入口** |
| 4 | （P1）进度显示 | `SyncStatus` 阶段化 + 首装全屏 + 日常细条；**失败必须带重试** |
| 5 | （P1）隐形书出口 | 书架显示「书单有记录但云端无文件」的书 + 人话说明 |

⏭️ **P1（同步进度显示）尚未做** —— 见 §七 方案 A+C。它是独立一批（UI + 状态模型），
   建议在真机确认 P0 的「上传第一次真的发出去」之后再动。

⚠️ 仍待白哥一句的只有一件：**复习卡不一致的方向**（推算值 31 张；若差得远则是另一类问题）。

---

*2026-10-10 · 方法：线上只读实测（7 张 `sync_*` 表 + 全盘找 blob 目录 + nginx access log 全量 20 个文件）
→ 端侧全链 grep（push/pull/apply/触发点/读端订阅/字段契约）→ 用云端数据推算 iOS 应有条数*
