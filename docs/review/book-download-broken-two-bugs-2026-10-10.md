# 下载书籍失败 · 两个 bug（2026-10-10）

> 触发：白哥贴出两张截图 —— 安卓下载 `The Mom Test` 报 `notEpub`；iOS 下载 `Alice` 报 `UNIQUE constraint failed: book_chapter.id`
> 状态：🔴 **只调查，未改任何代码**

---

## 〇、先说好消息：**上传链路第一次真跑通了**

白哥重装安卓包（含 P0）后，**两本书都上传成功** —— 这是 `book_blobs` 那条链**历史上第一次执行**：

```
sync_book（线上只读实测）
  Alice's Adventures in Wonderland   blob_size = 189249   received_at 2026-10-10T10:35:56Z
  The Mom Test 中文版（自译）        blob_size = 166745   received_at 2026-10-10T10:37:11Z

/opt/coevo/data/book_blobs/b5b3a29d-…/
  c4b8f580…af19.txt    166745 B     ← 该目录**此前不存在**
  4f81245d…4036.epub   189249 B

nginx
  10/Oct 18:35:56  POST /api/books/blob  200   （安卓，223.160.174.20）
  10/Oct 18:37:11  POST /api/books/blob  200   （iOS，124.23.133.111）
```

⇒ **P0 的三处修复全部生效**（目录在使用时取 / 上传成功写回 `blob_size` / 补触发点）。
⇒ 两台设备也**互相看到了对方的书**（各自书架上出现一本带云图标的）——**跨设备可见性也通了**。

**但「下载」这条链同样是第一次跑** —— 立刻暴露两个必然失败的 bug。

---

## 一、Bug A（安卓）：**txt 书被当成 epub 解析** ⇒ `notEpub`

### 现象

```
下载失败：解析失败（EbookParseErrorKind.notEpub）：文件头不是 zip 签名（期望 PK，实际 0x54 0x68）
```

`0x54 0x68` = `Th` ⇒ 拿到的确实是**文本**（`The Mom Test…` 的开头）。

### nginx 证明「取字节」这一步是**对的**

```
18:38:30  GET /api/books/blob/c4b8f580…?ext=epub   404   ← 先试 epub
18:38:30  GET /api/books/blob/c4b8f580…?ext=txt    200   ← 换 txt，成功拿到 166745 B
```

`downloadAuto` 的「依次试 epub/txt」**工作正常** ✅ —— 问题出在**拿到字节之后**。

### 根因：**`downloadAuto` 知道答案，却没把它传下去**

```dart
// api/book_blob_client.dart
for (final ext in const ['epub', 'txt']) {
  final r = await download(token: …, contentHash: …, ext: ext);
  if (r is BlobNotFound) { last = r; continue; }
  return r;                    // 🔴 返回 BlobDownloaded(bytes) —— **实际命中的 ext 被丢掉了**
}
```

调用方因此只能**猜**：

```dart
// providers/book_cloud_provider.dart
fileName: '${book.title}.${_guessExt(book)}',   // ← 用「猜」的扩展名拼文件名

/// 猜扩展名（**只用于生成一个像样的文件名**；真正的格式判定在解析层看魔数）。
String _guessExt(CloudBook b) => 'epub';        // 🔴 永远返回 epub
```

而 `pickFormat` 是**先魔数、后扩展名**：

```dart
EbookFormat pickFormat({required String fileName, required Uint8List bytes}) {
  if (是不是 PK 头) return EbookFormat.epub;     // ① txt 不是 PK ⇒ 不在这里返回
  final ext = fileExtension(fileName);
  if (ext == 'epub') return EbookFormat.epub;    // ② 🔴 文件名被拼成 .epub ⇒ 误判为 epub
  return EbookFormat.txt;
}
```

⇒ `parseEpub` 检查 zip 签名 ⇒ `notEpub`。

### 🔴 顺带纠正一句**错的注释**

`_guessExt` 上写着「**真正的格式判定在解析层看魔数**」——
**实测证明这半句不成立**：魔数只在「是 PK」时说话，**不是 PK 时最终由扩展名定**。
📌 与既有判据同族：**「注释里的声明」须 grep/实测才算数**。

### ✅ 修法（推荐 A1）

| | 做法 | 说明 |
|---|---|---|
| **A1** ⭐ | **让 `downloadAuto` 把实际命中的 `ext` 带出来** —— 给 `BlobDownloaded` 加 `ext` 字段（`download(ext:)` 本来就拿着它）；`downloadCloudBook` 用它拼文件名 | 治本、最小改动；**消除「猜」这个来源** |
| A2 | `pickFormat` 在「魔数不是 PK 但扩展名说 epub」时**不信扩展名** | 更鲁棒（文件名可能骗人），但会掩盖「真 epub 却损坏」的诊断 |
| A3 | 后端给 `sync_book` 加 `ext` 列 | 最干净（现有注释里的「待办」就是这个），但**要改后端 + 迁移** |

📌 我推荐 **A1**。**A2 我明确不建议做** —— 见下面这节。

---

### ❓ 为什么不选 A2（白哥问：「A2 不是更彻底吗」）

**A2 = 在「魔数不是 PK 但扩展名说 epub」时改判 txt。**

#### ① 它会打红一条**已定案**的断言 —— 而理由就写在它旁边

`scripts/ebook_verify/bin/verify_book_import_plan.dart`：

```dart
// 🔴 反向：叫 .epub 但不是 zip ⇒ **仍按 epub 解析**，好让解析器报「这不是有效的 EPUB」
//    （要是改判 txt，用户会看到一本乱码书 —— 比报错更糟）
check('🔴 非 zip + .epub → 仍判 epub（交给解析器报明确错）',
    pickFormat(fileName: 'book.epub', bytes: textBytes) == EbookFormat.epub);
```

⇒ 这条断言**就是 A2 的反面**，而且**理由已经写明**。

#### ② 实测确认：A2 会把「准确报错」变成「误导报错」

| | 走向 | 用户看到的话 |
|---|---|---|
| **现状** | 判 epub → `parseEpub` 的 PK 检查拦下 | ✅ 「**文件头不是 zip 签名（期望 PK，实际 0x54 0x68）**」—— 准确 |
| **A2 之后** | 判 txt → `parseTxt` → `decodeTextBytes` 返回 null | 🔴 「不是合法 UTF-8…**可能是 GBK/GB18030 等编码**」—— **对一个 zip 文件谈编码，纯误导** |

实测（拿真 epub 的字节跑）：**epub 的字节不是合法 UTF-8**（`invalid start byte @ byte 132`）
⇒ A2 之后**必然**落进那条误导分支。

#### ③ 两个场景在 `pickFormat` 这一层**无法区分**

- 「txt 内容 + 名字 .epub」（我们这次的 bug）
- 「真 epub 但魔数坏了」（截断/损坏）

在「**魔数不是 PK + 扩展名 epub**」这个输入上**长得完全一样**。
⇒ A2 必然二选一：要么给出误导性报错（②），要么退化成现状。

#### ④ 你的直觉对在哪 —— 但正解不是 A2

「**不该让格式判定依赖一个可能错的输入**」—— 这句话**是对的**。
但实现它的正确方式是**让坏输入产生不出来**，而不是**让判据容忍坏输入**：

| | 做法 | 代价 |
|---|---|---|
| **A1** | ext 取自**可靠来源**（`downloadAuto` 实际命中的那个，它本来就拿着）| 无 |
| **A1'** ⭐ | **A1 ＋ 删掉 `_guessExt`**（改成必须传 ext）⇒ **编译期**就不可能出现「猜」| 无（顺带消掉一个死函数）|
| A3 | 后端 `sync_book` 加 `ext` ⇒ 端侧连试错都不用 | 要改后端 + 迁移 + 部署 |
| **A2** | 让判据容忍错文件名 | ❌ **牺牲诊断准确性** |

📌 这正是项目既有判据的正面应用：**「补丁 ≠ 修法 —— 判据有洞时先问『还有哪些地方有』，再一次性改全」**。

⇒ **建议：A1'（A1 + 删 `_guessExt`）＋ B1** —— 不留「猜」的入口。

---

### 🔑 顺带查到一条「没接完的设计」

`book_blob_parse.dart` 里有一个**现成的** `extFromName(fileName)`，
它的注释写着：

> 从文件名推扩展名（对象键与后端 `is_valid_ext` 只认 `epub` / `txt`）。
> ⚠️ 推不出时**返回 null 而不是猜一个** ……而正确的做法是**让调用方决定**
> （例如按 `source_format` 取）。

🔴 但实测：**`extFromName` 全库 0 处调用（死代码）**，
而真正在用的 `_guessExt` **恰恰就是「猜一个」**（硬编码 `'epub'`）—— **正好违背了这条注释**。
⇒ 设计意图（「不要猜，让调用方拿真实值」）是对的，**只是没接完**；A1 就是把它接上。

---

## 二、Bug B（iOS）：**所有章节共用同一个 id** ⇒ 主键冲突

### 现象

```
DatabaseException(… Code=1555 "UNIQUE constraint failed: book_chapter.id")
sql 'INSERT INTO book_chapter (id, book_id, idx, title, text, char_count) VALUES (?,?,?,?,?,?)'
args [00d6532e-38d7-41c2-9277-8356e2a2b7ed,   ← id
      00d6532e-38d7-41c2-9277-8356e2a2b7ed,   ← book_id（🔴 与 id 完全相同）
      1, 'CHAPTER I.\nDown the Rabbit-Hole', …, 11514]
```

### 根因：**`newId` 被传成了「常量」而不是「生成器」**

`buildImportPlan` 会对**每一章**和**书本身**都调一次 `newId()`：

```dart
for (var i = 0; i < draft.chapters.length; i++) {
  rows.add(ChapterRow(id: newId(), idx: i, …));   // 每章一个 id
}
return BookImportPlan(bookId: newId(), …);        // 书一个 id
```

而下载路径传的是**常量闭包**：

```dart
// providers/book_cloud_provider.dart
final result = await importBook(
  …
  newId: () => newId,        // 🔴 newId 是 String 参数 ⇒ 这个闭包**每次返回同一个字符串**
);
```

调用方也传的是**值**：

```dart
// screens/book_library_screen.dart
newId: const Uuid().v4(),    // 🔴 生成一次，得到一个固定字符串
```

⇒ **书 id == 第 0 章 id == 第 1 章 id == …**
⇒ `book_chapter.id` 是主键 ⇒ **第 0 章插入成功，第 1 章立刻冲突**
（args 里 `idx=1` 且 id 与 book_id 相同 ⇒ 完全吻合）。

### ✅ 修法（推荐 B1）

| | 做法 | 说明 |
|---|---|---|
| **B1** ⭐ | 把 `downloadCloudBook` 的参数从 `String newId` 改成 **`String Function() newId`**，内部**直接透传**给 `importBook`；调用方传 `const Uuid().v4`（**函数引用**，不是调用）| 与 `importBook` 的既有约定一致（「id 生成器 —— 注入」）；**正常导入路径本来就是这么传的** |
| B2 | 内部写死 `() => const Uuid().v4()` | 能修，但让 `book_cloud_provider` 依赖 uuid，且丢掉「可注入」这个测试能力 |

📌 我推荐 **B1**。

### 🔑 这个 bug 为什么能藏这么久

**正常导入路径传的是生成器（对的），只有下载路径传了常量（错的）** ——
而下载路径**从未被执行过一次**（云端一直没有文件，无书可下）。
⇒ 与昨日那条判据**逐字吻合**：**「写了 + 自测过 + 从未真跑过」**（表现与「坏了」完全一样）。

---

## 三、两个 bug 的关系（都要修，缺一不可）

| | Bug A | Bug B |
|---|---|---|
| 触发条件 | **云端文件是 txt** | **任何**下载（必现）|
| 失败阶段 | 解析（`pickFormat`）| 写库（`book_chapter.id`）|
| 本次表现 | 安卓下载 txt 书 ⇒ `notEpub` | iOS 下载 epub 书 ⇒ `UNIQUE` |
| 修后 | 能过解析 | 能过写库 |

⚠️ 安卓这次**只暴露了 A**（在解析阶段就挂了，还没走到写库）；
**修好 A 之后，安卓同样会撞上 B**。⇒ **两个必须一起修**。

**另：`importBook` 的「单事务」保证是好的** —— 下载失败**没有留下半本书**
（两台的界面里那本书仍显示「云端 · 点按下载」，说明 `book` 行确实回滚了 ✅）。

---

## 四、请示

两处都是**明确的代码 bug**，修法清楚、改动面小（各 1–2 个文件）：

| # | 改什么 | 文件 |
|---|---|---|
| **A1'** ⭐ | ① `BlobDownloaded` 带上**实际命中的 `ext`**（`download()` 本来就拿着它）② `downloadCloudBook` 用它拼文件名 ③ **删掉 `_guessExt`**（改「必须传 ext」⇒ **编译期**不留「猜」）| `api/book_blob_parse.dart` · `book_blob_client.dart` · `providers/book_cloud_provider.dart` |
| **B1** | `downloadCloudBook.newId` 由「值」改为「生成器」，透传给 `importBook` | `providers/book_cloud_provider.dart` · `screens/book_library_screen.dart` |
| ~~A2~~ | ❌ **不做** —— 会打红已定案断言 + 把准确报错变成误导（理由见上）| — |

**要我按 A1 + B1 修吗？** 流程照旧：先写断言并**逐条证伪** → 改码 → 本地全验 → 报出包。
（⚠️ 仍**不涉及服务端** —— 两处都是端侧；但**需要重新出包**，iOS 走 CI。）

---

*2026-10-10 · 方法：线上只读实测（`sync_book` / `book_blobs` 目录 / nginx 上传与下载时序）→
读端侧下载全链（`downloadAuto` → `_guessExt` → `pickFormat` → `importBook` → `buildImportPlan`）→
用报错 args 反推（`id == book_id` 直接指向 `newId` 常量闭包）*

---

## 五、实施记录（白哥「同意」后 · **A1' + B1**）

**改动面：4 个端侧文件 + 1 个验收脚本**（`backend` 一个字没动）

| 文件 | 改动 |
|---|---|
| `services/ebook/book_blob_parse.dart` | `BlobDownloaded` 加 **`required ext`**；`parseDownloadResponse` 加 **`required String ext`**（**必填**，不留「null ⇒ 下游又开始猜」的口子）|
| `api/book_blob_client.dart` | `download()` 把**本次实际用的** `ext` 传给解析器 |
| `providers/book_cloud_provider.dart` | ① 用 `BlobDownloaded.ext` 拼文件名（**不再猜**）② `newId` 类型 `String` → **`String Function()`** 并**直接透传** ③ **删掉 `_guessExt`** |
| `screens/book_library_screen.dart` | `newId: const Uuid().v4()` → **`newId: const Uuid().v4`**（**函数引用**，不带括号）|
| `scripts/query_verify/bin/verify_book_cloud.dart` | 3 处签名更新 + 🆕 **【6】下载链 9 条断言**（48 → **58** 项）|

### 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | **error=0 warning=0**（7 条 info 全是存量）|
| `verify_book_cloud` | ✅ **58/58**（原 48）|
| `query_verify` 全量 | ✅ **51 个脚本 · 0 失败** |
| `ebook_verify` 全量 | ✅ **7 个脚本 · 0 失败** |
| `tokens_verify` | ✅ **721 / 0**（= 存量基线）|
| `trace_verify` | ✅ 0 失败 |
| **证伪** | ✅ **6 条**：注入 ⇒ 变红 ⇒ **逐字节还原**，且都被**预期的那条断言**抓到 |

### 🔴 证伪当场抓到一条我自己的**假绿**（最值得记的一条）

用例 1（`download()` 不再把 ext 交给解析）**第一遍没红**。查出来是：

> `ext: ext,` 在 `book_blob_client.dart` 里**有两处** ——
> `download()` 里的**回传** + `downloadAuto()` 里的**传参**
> ⇒ 我的「整文件 `contains`」被**另一处同名行兜住** = **假绿**。

✅ 改成**切片**（只取 `download()` 方法体：从 `Future<BlobResult> download(` 到 `delete(` 之前）
＋ 一条「**能切出方法体**」的**前提断言** ⇒ 立刻变红、且被预期断言抓到。

📌 与既有判据逐字吻合：**子串断言三族假绿 ——「整文件 contains 被别处同名行兜住」**。
🔑 而**证伪是唯一能发现它的手段** —— 跑绿不代表断言有效。

### ⏭️ 出包（仍需端侧）

```bash
# 安卓（本地，不需要 CI / 不需要仓库公开）
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
```
iOS 走 CI（`iOS Archive & Upload`，`method=ad-hoc`）。**服务端无需改动**。
