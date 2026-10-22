// CoEvo · 书文件（blob）接口的**解析与本地预检** —— 零依赖层
//
// 🔴 零 Flutter / 零 http ⇒ **本机可验**（同 `translate_parse.dart` 的分层理由）：
//    「服务返回什么形状」「配额怎么算」是这个功能最容易错、又最难在真机复现的部分。
//
// # 后端契约（实测自 `book_blob_handler.rs` · 2026-10-08）
//
// | 端点 | 成功返回 | 失败 |
// |---|---|---|
// | `POST /api/books/blob`（multipart：`content_hash` · `ext` · `file`）| `{ok, blob_size, usage, quota}` | 401 未登录 · **400**（见下）|
// | `GET /api/books/blob/{hash}?ext=` | 文件字节 | 401 · 404（云端没这个文件）|
// | `DELETE /api/books/blob/{hash}` | `{ok, freed_bytes}` | 401 · 404 |
//
// # 🔴 后端的 400 承载了**三种**语义（这是接口瑕疵，端侧要自己兜住）
//
// | 文案 | 真实含义 | 用户该做什么 |
// |---|---|---|
// | 「这本书还没在书单里，请先同步书单再上传」| 内部顺序问题 | 重试（先同步书单）|
// | 「这本书超过单本上限（N MB）」| 这本书太大 | 换文件（无解也得说清）|
// | 「云端空间不足（已用 X MB / 共 Y MB）」| **配额满** | 删书 / 订阅 |
//
// ⇒ 三种的**用户动作完全不同**，却挤在同一个状态码里。
//   端侧对策：**上传前先本地预检**（[precheckUpload]）避免大多数情况走到 400；
//   真收到 400 时按**文案前缀**区分，匹配不到就归到「普通失败」（不猜）。
//   📌 待办：后端应把「配额满」改回 **403**（与「订阅权益」同族），见本轮报告。
//
// 📄 设计依据：`docs/design/visual-cloud-bookshelf-2026-10-07.html`

import 'dart:convert';
import 'dart:typed_data';

/// 单本书的字节上限（**必须**与后端 `MAX_BOOK_BYTES` 同值）。
///
/// 🔴 2026-10-21：这两处**曾经不同值**（端 50 MB / 服 32 MB），而注释还写着
///    「同值 —— 改一处必须改两处」。后果不是报错，而是**静默的**：
///    32–50 MB 的书能导入、能解析、能落库，上传时才被后端拒 → 用户看到
///    「云端空间不足」（因为 413 被当成配额满），而且**整个上传队列停摆**。
///
/// 📌 现在由 `scripts/ebook_verify/bin/verify_book_limits.dart` 从**两端源码里
///    各抠出这个数字**做断言 —— 光靠注释写「必须同值」是守不住的（已证）。
/// ⚠️ 改这个值要同时确认：后端 `book_storage.rs::MAX_BOOK_BYTES` 与
///    `book_text.dart::kMaxEbookBytes`（导入解析上限，语义不同但必须同值）。
const int kMaxBookBytes = 50 * 1024 * 1024;

/// 云端配额（与后端 `CLOUD_BOOK_QUOTA_BYTES` 同值）。
const int kCloudQuotaBytes = 2 * 1024 * 1024 * 1024;

/// 一次 blob 操作的结果。**用 sealed 而不是「返回 null + 错误变量」** ——
/// 后者不会在编译期暴露「少判了一种情况」（`translate_parse.dart` 同族教训）。
sealed class BlobResult {
  const BlobResult();
}

/// 上传成功。
class BlobUploaded extends BlobResult {
  const BlobUploaded({required this.blobSize, required this.usage});

  /// 云端**实际存储**的字节数（服务端权威）。
  final int blobSize;

  /// 上传后服务端算出的**总用量**（端侧可直接用来刷新配额条）。
  final int usage;
}

/// 下载成功。
class BlobDownloaded extends BlobResult {
  const BlobDownloaded({
    required this.bytes,
    required this.contentType,
    required this.ext,
  });

  final Uint8List bytes;

  /// 服务端的 `Content-Type`（用它**推测扩展名**时只能当参考 —— 见 `extFromName`）。
  final String? contentType;

  /// 🔑 **本次下载实际使用**的扩展名（`epub` / `txt`），由 `download(ext:)` 带下来。
  ///
  /// # 🔴 为什么必须带出来（2026-10-10 · 真机实测的 bug）
  ///
  /// 后端书单（`sync_book`）**没有 `ext` 列** ⇒ [`downloadAuto`] 只能**依次试**
  /// `epub` / `txt`。而「只有云端」的书**本地没有任何记录** ⇒ 下载方
  /// **必须知道最终命中的是哪个**，否则只能猜。
  ///
  /// 实测后果：一本 **txt** 书被猜成 `epub` ⇒ 文件名拼成 `.epub`
  /// ⇒ [`pickFormat`] 按扩展名判 epub ⇒ `parseEpub` 报
  /// 「文件头不是 zip 签名（期望 PK，实际 0x54 0x68）」⇒ **下载失败**。
  ///
  /// 📌 判据：**答案本来就在手上**（`downloadAuto` 的循环变量），**不要往外丢**。
  ///    同 [`extFromName`] 的注释：「推不出时返回 null 而不是猜一个」——
  ///    这里更进一步：**连「推」都不需要**。
  final String ext;
}

/// 删除成功。
class BlobDeleted extends BlobResult {
  const BlobDeleted({required this.freedBytes});

  /// 释放的云端字节数（服务端算的）。
  final int freedBytes;
}

/// 未登录（**不是失败** —— 用户的下一步是「去登录」，不是「重试」）。
class BlobNeedLogin extends BlobResult {
  const BlobNeedLogin();
}

/// 配额/单本超限 —— **与「失败」分开**：用户的下一步是「删书 / 换文件」，不是重试。
class BlobQuotaExceeded extends BlobResult {
  const BlobQuotaExceeded(this.message);
  final String message;
}

/// 🆕 2026-10-21：**这一本太大**（超过服务端单本上限）—— 与「配额满」分开。
///
/// # 🔴 为什么必须再分一类（一个真实的放大事故）
///
/// 原先 413 与「超过单本上限」都被归成 [BlobQuotaExceeded]，而队列对这个结果的
/// 处理是 `_cancelled = true`（**整队停下**，理由是「配额满了再传也是白传」）。
/// 于是**一本大书**会让**其余所有书**都传不上去 —— 而且提示是「云端空间不足」，
/// 用户明明 2 GB 一点没用。
///
/// 🔑 判据：**「这本书不行」≠「这个人不行」**。
///    · 配额满 → 整个账号都传不了 ⇒ 停下合理
///    · 单本超限 → 只有这一本传不了 ⇒ **跳过它、继续传下一本**
class BlobTooLarge extends BlobResult {
  const BlobTooLarge(this.message);
  final String message;
}

/// 云端没有这个文件（下载/删除时）。⚠️ 与「失败」不同：它是**确定的状态**。
class BlobNotFound extends BlobResult {
  const BlobNotFound();
}

/// 其它失败（网络 / 5xx / 解析不了）。
class BlobFailed extends BlobResult {
  const BlobFailed(this.message);
  final String message;
}

/// 上传的**本地预检**结果。
sealed class UploadPrecheck {
  const UploadPrecheck();
}

class UploadOk extends UploadPrecheck {
  const UploadOk();
}

class UploadTooLarge extends UploadPrecheck {
  const UploadTooLarge(this.bookBytes);
  final int bookBytes;
}

class UploadQuotaShort extends UploadPrecheck {
  const UploadQuotaShort({required this.used, required this.incoming});
  final int used;
  final int incoming;
}

/// **上传前**的本地预检（避免大多数情况走到后端的 400）。
///
/// 🔑 为什么端侧能做准：云端清单（`cloud_book`）是**整体替换**的 ⇒
///    对 `blob_size` 求和**就是**服务端的 `used`（同一口径）。
/// ⚠️ 但它依赖「书单已同步」；从未同步过的账号算出来是 0 ——
///    此时预检**必然通过**，真正的兜底是后端那 400。
///
/// [usedBytes] = 当前云端用量（调用方从 `cloud_book` 求和传入）
/// [incomingBytes] = 本次要传的文件字节数
/// [isOverwrite] = 这本书云端已有文件（覆盖不额外占额度 ⇒ 要先减掉它自己）
/// [existingBytes] = 该书已在云端占用的字节数（仅 `isOverwrite` 时有意义）
UploadPrecheck precheckUpload({
  required int usedBytes,
  required int incomingBytes,
  bool isOverwrite = false,
  int existingBytes = 0,
}) {
  if (incomingBytes > kMaxBookBytes) {
    return UploadTooLarge(incomingBytes);
  }
  // 🔑 与后端同一口径：判据是**净增量**（覆盖式上传不额外占额度）——
  //    否则一本 5 MB 的书重传两次会把 2 GB 额度算成用了 10 MB。
  final net = usedBytes - (isOverwrite ? existingBytes : 0);
  // ⚠️ 恰好等于上限 ⇒ **允许**（与后端一样用 `>` 而不是 `>=`）
  if (net + incomingBytes > kCloudQuotaBytes) {
    return UploadQuotaShort(used: net < 0 ? 0 : net, incoming: incomingBytes);
  }
  return const UploadOk();
}

/// 解析上传响应。
BlobResult parseUploadResponse(int statusCode, String body) {
  if (statusCode == 401) return const BlobNeedLogin();
  if (statusCode == 200) {
    final j = _tryMap(body);
    if (j == null) return const BlobFailed('上传成功但返回体不是 JSON');
    return BlobUploaded(
      blobSize: _asInt(j['blob_size']),
      usage: _asInt(j['usage']),
    );
  }
  if (statusCode == 400) {
    // 🔴 后端把三种语义挤在 400 —— 按**文案前缀**区分（见文件头）。
    // ⚠️ 必须先判「单本太大」，再判「空间不足」：两者都回 400，
    //    而队列对它们的反应**相反**（跳过 vs 整队停下）。
    if (body.contains('超过单本上限')) {
      return BlobTooLarge(_messageOf(body));
    }
    if (body.contains('云端空间不足')) {
      return BlobQuotaExceeded(_messageOf(body));
    }
    return BlobFailed(_messageOf(body));
  }
  if (statusCode == 413) {
    // 413 有**两个来源**，语义完全不同：
    //
    // | 来源 | 触发条件 | 响应体 |
    // |---|---|---|
    // | nginx（反向代理）| 超过 `client_max_body_size` | **HTML** |
    // | axum（应用）| 超过 `DefaultBodyLimit`（= MAX_BOOK_BYTES + 1 MB）| 纯文本/空 |
    //
    // 🔴 2026-10-22 真机事故：nginx 的 `client_max_body_size` 还是**电子书上传
    //    上线之前**定的 **2m** ⇒ 一本 **5.5 MB** 的书被 nginx 直接 413，
    //    而这里把它归成 `BlobTooLarge` ⇒ 用户看到「超过单本上限（50 MB）」。
    //    **5.5 MB 被说成超过 50 MB** —— 而且请求根本没到后端
    //    （后端日志零记录，排查方向被彻底带偏）。
    //
    // 📌 判据：**状态码相同不代表语义相同**；能区分就区分（这里靠响应体形态）。
    //    ⇒ 靠 HTML 判断是 nginx 挡的。
    if (body.trimLeft().startsWith('<')) {
      return const BlobFailed(
        '请求被服务器拒绝（超过网关体积上限）。这不是你的文件太大的问题，请联系支持。',
      );
    }
    // axum 的 `DefaultBodyLimit` 超限 ⇒ **确实是单本太大**（>50 MB）。
    //
    // 📌 2026-10-21 之前这里归成 `BlobQuotaExceeded` ⇒ 一本 40 MB 的书会让
    //    整个上传队列停摆，而提示说「空间不足」。两者都错。
    return BlobTooLarge(_messageOf(body));
  }
  return BlobFailed('HTTP $statusCode：${_messageOf(body)}');
}

/// 解析下载响应。
///
/// ⚠️ 传的是**原始字节**而不是字符串 —— 书籍是二进制（epub 是 zip）。
///
/// [ext] = **本次请求实际使用的扩展名**（见 [BlobDownloaded.ext]）。
///   🔴 **必填**而不是可选：调用方（`download()`）本来就拿着它，
///   设成可选只会留一个「下游拿到 null 又开始猜」的口子。
BlobResult parseDownloadResponse(
  int statusCode,
  Uint8List body,
  String? contentType, {
  required String ext,
}) {
  if (statusCode == 401) return const BlobNeedLogin();
  if (statusCode == 404) return const BlobNotFound();
  if (statusCode == 200) {
    if (body.isEmpty) return const BlobFailed('云端文件是空的（0 字节）');
    return BlobDownloaded(bytes: body, contentType: contentType, ext: ext);
  }
  return BlobFailed(
      'HTTP $statusCode：${_messageOf(utf8.decode(body, allowMalformed: true))}');
}

/// 解析删除响应。
BlobResult parseDeleteResponse(int statusCode, String body) {
  if (statusCode == 401) return const BlobNeedLogin();
  if (statusCode == 404) return const BlobNotFound();
  if (statusCode == 200) {
    final j = _tryMap(body);
    return BlobDeleted(freedBytes: j == null ? 0 : _asInt(j['freed_bytes']));
  }
  return BlobFailed('HTTP $statusCode：${_messageOf(body)}');
}

/// 从文件名推扩展名（对象键与后端 `is_valid_ext` 只认 `epub` / `txt`）。
///
/// ⚠️ 推不出时**返回 null 而不是猜一个** —— 后端会因非法 ext 直接 400，
///    而正确的做法是**让调用方决定**（例如按 `source_format` 取）。
String? extFromName(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.epub')) return 'epub';
  if (lower.endsWith('.txt')) return 'txt';
  return null;
}

/// 把服务端返回的 JSON 里的错误文案取出来（失败文案要能展示给用户）。
String _messageOf(String body) {
  final j = _tryMap(body);
  if (j != null) {
    final m = j['error'] ?? j['message'] ?? j['detail'];
    if (m is String && m.isNotEmpty) return m;
  }
  // 不是 JSON ⇒ 原样截断（防把整页 HTML 塞进提示里）
  final s = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}

Map<String, Object?>? _tryMap(String body) {
  try {
    final v = jsonDecode(body);
    return v is Map ? v.map((k, v) => MapEntry('$k', v)) : null;
  } catch (_) {
    return null;
  }
}

int _asInt(Object? v) => switch (v) {
      int i => i,
      num n => n.toInt(),
      String s => int.tryParse(s) ?? 0,
      _ => 0,
    };
