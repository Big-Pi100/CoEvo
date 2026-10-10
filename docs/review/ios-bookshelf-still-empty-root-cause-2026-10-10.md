# iOS 书架依然为空 · 根因（2026-10-10）

> 触发：白哥装了新出的 iOS 包（`E:\CoEvo_backups\coevo_app.ipa`），书架**还是没东西**
> 状态：🔴 **只调查，未改任何代码**
> 一句话：**P0 修的是「上传能发起」，但「发起上传的设备必须持有原始文件」——
> iOS 上没有这本书的原始文件（它不是导入方）⇒ 它一个请求都不会发（这是**正确行为**）。
> 云端那本书的文件从未上传成功 ⇒ iOS 装任何包都看不到。**

---

## 零、先回答：云端**到底存不存**书文件？

> 白哥问：「你一直只是同步书架目录？而没有在服务器上储存书籍的文件？」

**答：设计上要存，代码也全实现了 —— 但至今没有成功存过一份。**

### ① 设计：**存原始文件**（不是只存目录）

`docs/design/visual-cloud-bookshelf-2026-10-07.html` 原文：

| 项 | 文档原文 |
|---|---|
| **存什么** | **原始文件**（`.epub` / `.txt`）—— **不存解析后的章节** |
| **存哪** | 本地盘 `data/book_blobs/{user_id}/{content_hash}.{ext}`；生产路径 **`/opt/coevo/data/book_blobs/`** |
| **配额** | `SUM(blob_size)`，`CLOUD_BOOK_QUOTA_BYTES = 2 GB`，`MAX_BOOK_BYTES = 32 MB` |
| **删书** | 同时删云端文件（`blob_size` 归零、配额退还）|
| **书单同步** | **元数据**（书名/作者/指纹/章节数）走**现有 sync 通道**（`sync_book` 表）|
| 对外说法 | 「**云端存储 · 换机不丢**」「已备份到云端」「从云端取回」|

⇒ **元数据与文件是两条通道**（有意分离：文件几十 MB，不能塞进 sync 的 JSON）。
所以「只在**表里**看到目录」≠「设计只做目录」—— 文件本来就该在**另一个地方**。

### ② 实现：三层全在（不是只有目录那半边）

| 层 | 文件 | 做了什么 |
|---|---|---|
| 端侧读+传 | `services/ebook/book_raw_store.dart` · `book_upload_queue.dart` · `api/book_blob_client.dart` | 原始文件落盘 `books_raw/{hash}.{ext}` → multipart 上传 |
| 服务端落盘 | `book_blob_handler.rs` · `book_storage.rs` | `trait BlobStore` + **`LocalDiskStore`**（真 `fs::create_dir_all` → `fs::write` 临时 → `fs::rename` 原子落盘）|
| 取回 | `providers/book_cloud_provider.dart#downloadCloudBook` | 下载 → **复用导入管线**落库 |

时间线：后端 `3874735`（**10-08**「书架上云 + 整段翻译（后端全链）」）· 端侧 `86bb0ce`（10-09）→ `5d1895e`（10-10 修断链）。

### ③ 现状：**一次都没存成过**

| 判据 | 实测 |
|---|---|
| `/opt/coevo/data/book_blobs` | 🔴 **不存在**（`ls` 报 No such file）|
| `/opt/coevo/data/` 下所有内容 | 只有 `.db` / `backups` / `logs` / 两张图 —— **没有任何书文件** |
| `sync_book.blob_size` | `0`（唯一那行）|
| `POST /api/books/blob` | **0 条 App 请求**（nginx 近一月，只有我的 curl）|

⇒ **结论：不是「只做了目录」，是「文件这条链做好了，但从未被执行过一次」。**

### ④ 🔴 我的疏忽（该记的教训）

这条链我**写过断言、也跑绿过**（`verify_book_cloud` 等），但**端到端从未真跑通过一次** ——
本机不能跑 Flutter、没有真机、服务端**从未收到过一个上传请求**。
⇒ 「代码全在 + 断言全绿」**推不出**「功能可用」。
📌 这比「写了没人跑」更狠一层：**写了、也自测过、但从未真跑过** —— 而它的表现与「坏了」**完全一样**。

---

## 一、三层硬证据（全部实测）

### ① IPA **确实含 P0 修复** —— 不是「又忘了出包」

从 IPA 里解出 Dart AOT（`App.framework/App`，11.6 MB），搜 P0 独有的特征串：

| 特征串 | 来源 | IPA 中 |
|---|---|---|
| `markUploadedBlob` | P0 新增（`CloudBookRepository`）| ✅ 1 次 |
| `pendingUploadCount` | P0 新增（provider）| ✅ 2 次 |
| `未上云`（UTF-16）| P0 新增 UI 文案 | ✅ 1 次 |
| `重试上传`（UTF-16）| P0 新增 UI 文案 | ✅ 1 次 |
| `上传失败`（UTF-16）| 既有文案 | ✅ 4 次 |

📌 时间线也吻合：**P0 提交 `5d1895e` = 10-10 01:21** ＜ **IPA 构建 10-10 09:54**。
（`CFBundleShortVersionString 1.0.0` / build `2` / `com.coevo.coevoApp`）

🔑 撇开一个方法论坑：Dart AOT 里**中文是 UTF-16LE**，用 UTF-8 `grep` 一律 0 命中
（我先按 UTF-8 搜 `未上云` 得到 0，差点误判成「不含修复」）。

### ② 云端**没有书文件**

```
sync_book（该账号唯一的 1 行）
  content_hash  = 4f81245d31380ac1…78…4036
  title         = Alice's Adventures in Wonderland
  chapter_count = 14
  blob_size     = 0        ← 🔴 服务端实际存储 0 字节
  size_bytes    = 0
  received_at   = 2026-10-09T09:41:49.499Z
```

服务端**全盘扫描 `/opt /var /srv /home` ⇒ 没有任何 blob 目录**
（`/opt/coevo/data/book_blobs` 等均不存在）。

### ③ 上传**一次都没发生**

翻遍 nginx 全部 access log（含 `.gz`）：

```
POST /api/books/blob → 3 条，UA 全是 curl
  111.230.197.4  09/Oct 15:15  curl/8.5.0     ← 我的探测
  124.23.133.168 10/Oct 00:58  curl/8.21.0    ← 我的探测
  （无任何 App 的 User-Agent，0 条）
```

⇒ **App 从未向 `/api/books/blob` 发过请求。**

---

## 二、🔴 为什么 iOS 装什么包都不会有书

这是本次调查最关键的一条 —— 之前（包括 P0 的修复）都默认了
「装了新包 ⇒ 会重新上传」，**这个默认是错的**。

### 上传的候选从哪来

```dart
// kickBookUpload（providers/book_cloud_provider.dart）
final pending = await CloudBookRepository.pendingUploadHashes(db);   // ← 候选
if (candidates.isEmpty) return;                                      // ← iOS 走这里
```

```sql
-- pendingUploadHashes：本地有指纹 且 云端没有文件
SELECT b.content_hash FROM book b
LEFT JOIN cloud_book c ON c.content_hash = b.content_hash AND c.blob_size > 0
WHERE b.content_hash IS NOT NULL AND b.content_hash <> ''
  AND c.content_hash IS NULL          -- 云端没有 ⇒ 待上传
```

⇒ 候选 = **「本地 book 表里有、云端没有文件」的书**。

### 而 iOS 上那本书**根本不在本地**

| | 安卓（导入方）| iOS |
|---|---|---|
| 本地 `book` 表 | **有**（hash `4f81245d…`）| **空**（没导入过这本书）|
| 原始文件 `{rawDir}/{hash}.epub` | 有（导入时 `raw_book_store` 保存）| **没有** |
| `pendingUploadHashes` | 返回这 1 条 ⇒ **有候选可传** | **返回空 ⇒ 0 候选 ⇒ 不发请求** |

⇒ **iOS 装 P0 包后，`kickBookUpload` 每次都在 `candidates.isEmpty` 处返回**。
**不是 bug** —— 一台没有这本书的设备，本来就没有东西可上传。

### ⇒ 结论

> **「书文件上传」这个动作，只能由「持有原始文件的那台设备」发起。**
> iOS 上这本书从来不存在 ⇒ **它永远不会有候选** ⇒
> **要在 iOS 看到书架，唯一路径是「云端先有文件」，而云端有文件只能靠安卓传上去。**

---

## 三、两条出路（都不需要 iOS 端再改代码）

| | 做法 | 一次到位？|
|---|---|---|
| **A** ⭐ | **在安卓端装含 P0 的包**，打开 App（保持登录）⇒ 同步流程会 `_kickUploadIfNeeded` ⇒ 这本书进候选 ⇒ 上传 ⇒ 云端 `blob_size > 0` ⇒ **iOS 下次同步就能看到（云图标 · 可下载）** | 是（根治）|
| **B** | 在 **iOS 上重新导入**这本书（需要一份 epub：从安卓导出 / 原下载源）⇒ iOS 自己就有原始文件 ⇒ P0 会立即上传 ⇒ 两台设备都能看到 | 是（但需手工搬一份文件）|

**验证 A 是否成功**：看 nginx 有没有 App 的 `POST /api/books/blob`；
再看 `sync_book.blob_size` 是否 > 0。**这一步我可以随时帮你查。**

⚠️ **下一道必然踩的坎（实测确认，不是推测）**：**两处上限不一致** ——

| 层 | 上限 | 出处 |
|---|---|---|
| 服务端 | **32 MB**（`MAX_BOOK_BYTES`）| `book_storage.rs:304` |
| **nginx** | 🔴 **2 MB**（`client_max_body_size 2m`）| `/etc/nginx/sites-available/zz-coevo:113` |

nginx 那行的注释还写着「**请求体很小（一个单词 / 登录表单）；头像上传略大 → 2m 足够**」
—— 那是**头像时代**的注释，做云端书架时**忘了同步放行**。

⇒ **任何 > 2 MB 的书，上传会被 nginx 直接 413**（服务端那 32 MB 的额度**根本用不上**），
且端侧只会看到一句「上传失败」（服务端注释自己也提过：「原因藏在 413 里」）。
Alice 的 Gutenberg epub 通常 < 1 MB，所以**这次可能不会撞上**；但换一本带插图的就会。
🔧 修它要改 nginx 并 `reload` —— 属**生产变更**，需单独批准。

---

## 四、🔴 实时证据（10-10 18:00 · 白哥正在用 app）

翻 nginx 全量日志（**按时间戳重排** —— 文件名字典序拼接的时间线是错的）：

```
10-10 18:00:57  124.23.133.111  POST /api/sync/push                  200
10-10 18:00:58  124.23.134.237  POST /api/sync/push                  200
10-10 18:00:58  124.23.134.237  GET  /api/sync/pull?since=2026-10-09T16:50:33Z
                                     &device_id=dev_4dbbac37858b6d…   200
10-10 18:02:02  124.23.133.111  POST /api/sync/push                  200
```

### 三条推论（都很硬）

1. ✅ **App 的同步链路完全正常** —— 两台设备（两个 IP）push/pull 都 200。
   所以「书架空」**不是同步坏了**。
2. 🔴 **`/api/books/blob` 依然 0 次** ⇒ 没有任何设备发起过书文件上传。
3. 🔴🔴 **`sync_book.received_at` 仍停在 `2026-10-09T09:41:49Z`** ——
   而 `_pendingBooks()` 是**全量推**「本地所有有指纹的书」⇒ **只要任何一台设备本地还有那本书，
   push 就必然把它带上并刷新 `received_at`**。
   ⇒ **10-10 活动过的设备，本地都没有这本书。**

⇒ 这把 §二 的结论**收紧了一层**：不只是「iOS 没有原料」，
而是**当前在用的设备上都没有那本书的原始文件**（或那台有书的设备今天没活动/没装新包）。

### ⚠️ 由此多出一个必须排除的可能：**那本书本地已经不存在了**

若安卓被**重装 / 清数据 / 卸载**，本地 `book` 表与 `books_raw/{hash}.epub` 会一起消失
（而云端只有元数据、**没有文件**）⇒ **这本书的两端都没有可上传的原料**。
⇒ 这种情况下唯一出路是**重新导入一份 epub**（见 §三 出路 B）。

📌 还有一个需要一并核实的**次生可能**：导入时 `_safeRawDir()` 返回 `null` 时
`importBook(rawDir: null)` **不保存原始文件**（代码注释：「拿不到目录也不影响导入」）——
若 10-09 导入那本书时恰好走了这条，则**本地从来没有过原始文件**，
装什么包都传不了（队列会判 `skippedNoRaw`）。

---

## 五、🆕 本次调查顺带查出的两个**真实缺口**（与本次症状直接相关）

### 缺口 1：**「隐形书」—— 书架全空，且用户无从判断**

`blob_size = 0` 的云端书（= 有记录、没文件）在书架上**两侧都不渲染**：

| 渲染来源 | 条件 | 这本 Alice |
|---|---|---|
| 本地书列表 | 本地 `book` 表 | ❌ 无 |
| `cloudOnlyBooksProvider` | `presence == cloudOnly` ← **只认 `blob_size > 0`** | ❌ `blob_size = 0` |

⇒ 结果是**书架空空如也**，而用户看到的信息量为 **0**：
分不清「没同步」「同步中」「文件没传上去」。
**这正是白哥说「不知道是 bug 还是在进行中」的**直接来源**。**

📌 这是 2026-10-09 那次改动（判据由「行存在」改为 `blob_size > 0`）的**已知取舍**：
它防住了「显示云端有 → 点下载 → 404」的静默失败，但**没有配套出口**。

### 缺口 2：**上传失败用户零感知**

`_kickBookUpload` 整段 `try/catch` 只 `debugPrint`（注释写「真正的出口在书架页」）——
但书架页那枚「未上云 N」药丸**只在有候选时才出现**（`candidates.isEmpty` 就没它）。
⇒ iOS 这种「无候选」情形下，**既没有书、也没有任何提示**。

📌 判据再次应验：**「静默失败 + 无出口」比报错更糟。**

---

## 六、建议

### ① 立刻能分清的两种情形（这一步决定后面怎么走）

在**安卓**上打开 App（确认还登录着 `690861018@qq.com`），**看两处**：

| 看什么 | 若是「有」 | 若是「无」 |
|---|---|---|
| 书架里还有没有那本 Alice | ⇒ 走 **路线 A**：装含 P0 的包 → 同步 → 自动上传 | ⇒ 走 **路线 B**：本地书已丢，只能**重新导入一份 epub** |
| 设置/书架里有没有「未上云」提示 | ⇒ 说明 P0 在跑、只是缺原始文件 | ⇒ 说明那台设备没装 P0（或没这本书）|

**判据（我随时可查）**：安卓操作后，nginx 应出现 App 的 `POST /api/books/blob`，
且 `sync_book.received_at` 会跳到今天、`blob_size > 0`。
**若这两条都没动 ⇒ 那台设备上没有可上传的原料**（不是网络问题）。

### ② 建议做（代码 · P1）—— 让「书架空」这件事**自解释**

这是白哥原话「**不知道是 bug 还是在跑**」的直接解法：

- **书架给「隐形书」出口**：`blob_size = 0` 的云端记录也显示一本书，文案说实话：
  「**云端有这本书的记录，但文件没有上传成功**」＋ 按情形给出口
  （本机有文件 ⇒「重新上传」；本机没有 ⇒「从原来源重新导入」的引导）。
- **上传失败要可见**：`_kickBookUpload` 目前整段只 `debugPrint`；
  书架页那枚「未上云 N」药丸**只在有候选时出现** ⇒ 无候选时**零提示**。
- 这两条**与本次症状直接相关**（不是附带优化）：现在「书架空」在**任何原因**下
  长得都一模一样：没同步 / 同步中 / 文件没传上 / 本机没这书 —— **四种情况、同一个空屏**。

### ③ 一个待你确认的事实

**安卓端现在装的是含 P0 的包吗？那本书还在吗？** ——
这两点决定「一次到位的自动上传」是否成立；
若那台设备已经重装/清过数据，则只能走路线 B（重新导入）。

📄 相关：`cloud-sync-ios-first-install-audit-2026-10-10.md`（P0 的根因与实施）

---

*2026-10-10 · 方法：解 IPA 取 AOT 验特征串（含 UTF-16 踩坑纠正）→ 线上只读实测
（`sync_book` / 全盘 blob 目录）→ nginx access log **按时间戳重排**全量搜 App 请求
（发现「文件名字典序拼接会伪造时间线」这个坑）→ 逐层读端侧候选组装链
（`pendingUploadHashes` → `kickBookUpload` → `readRawBook`）*
