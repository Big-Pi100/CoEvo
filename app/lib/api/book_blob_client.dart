// CoEvo · 书文件（blob）的 HTTP 客户端
//
// 🔴 **分层**：本文件只做 HTTP；**解析与预检在 `book_blob_parse.dart`**（零依赖 ⇒ 可断言）。
//    这里 `export` 那些类型 ⇒ 调用方 import 一处（同 `translate_client.dart` 的做法）。
//
// # 三个端点（与 `book_blob_handler.rs` 一一对应）
//
// | 方法 | 路径 | 说明 |
// |---|---|---|
// | [upload] | `POST /api/books/blob` | multipart：`content_hash` · `ext` · `file` |
// | [download] | `GET /api/books/blob/{hash}?ext=` | 返回原始字节（**二进制**，不是 JSON）|
// | [delete] | `DELETE /api/books/blob/{hash}` | 同时把服务端的 `blob_size` 归零 |
//
// # 🔴 鉴权口径：**只要登录**，不要订阅
//
// 下载 / 删除用「仅登录」（后端 `authorize_login_only`）——
// 订阅到期的人**也必须能取回和删掉自己的书**，否则「数据不丢」是假的，
// 而且配额会被他取不回的文件永久占着。（上传需要订阅 —— 那是「新增占用」。）

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../services/ebook/book_blob_parse.dart';
import 'api_config.dart';

// 把结果类型与预检函数带出去（调用方只 import 本文件即可）
export '../services/ebook/book_blob_parse.dart';

/// 上传/下载的超时。
///
/// 🔴 **不能用 `ApiConfig.longTimeout`（60 秒）** —— 实测 VPS 下行 **652 KB/s**，
///    一本 50 MB 的书要 **~80 秒**；用 60 秒会让「大书必然超时」。
///    📌 判据：**超时要按「最坏情况的数据量 / 实测带宽」算**，不能沿用 JSON 接口的值。
const Duration _blobTimeout = Duration(minutes: 5);

class BookBlobClient {
  BookBlobClient({String? baseUrl, http.Client? httpClient})
      : _base = baseUrl ?? ApiConfig.baseUrl,
        _http = httpClient ?? http.Client();

  final String _base;
  final http.Client _http;

  /// 上传一本书的原始文件。
  ///
  /// 🔴 **前提：服务端书单行已存在**（后端会校验，否则 400）。
  ///    ⇒ 调用方必须**先推书单**（`sync_service` 的 books）再传文件。
  Future<BlobResult> upload({
    required String token,
    required String contentHash,
    required String ext,
    required Uint8List bytes,
    required String fileName,
  }) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_base/api/books/blob'))
        ..headers.addAll(ApiConfig.headers(token: token))
        ..fields['content_hash'] = contentHash
        ..fields['ext'] = ext
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ));
      // ⚠️ 不要手动设 Content-Type —— `MultipartRequest` 要自己写 boundary。
      final streamed = await _http.send(req).timeout(_blobTimeout);
      final resp = await http.Response.fromStream(streamed);
      return parseUploadResponse(resp.statusCode, resp.body);
    } on TimeoutException {
      return const BlobFailed('上传超时（网络慢或文件太大）');
    } catch (e) {
      debugPrint('bookBlob.upload 失败: $e');
      return BlobFailed('上传失败：$e');
    }
  }

  /// 下载一本书的原始文件。
  ///
  /// ⚠️ **一次性读入内存**：导入管线（`importBook(bytes:)`）本来就要 `Uint8List`
  ///    ⇒ 流式写盘的收益只是省一次拷贝，却要多一条临时文件生命周期。
  ///    单本上限 50 MB ⇒ 这个取舍成立。
  ///
  /// 🆕 2026-10-21：**先看 `Content-Length` 再决定要不要收**。
  ///    原实现直接 `get()`（= 把 body 全收完），若服务端文件异常大
  ///    （历史数据 / 将来放宽上限 / 被替换的响应），端侧直接 OOM 崩掉。
  ///    现在用 `send()` 拿到 `StreamedResponse`（**body 还没被消费**），
  ///    长度超限就丢弃 —— 代价是多了几行，收益是「大文件不会再打死 App」。
  Future<BlobResult> download({
    required String token,
    required String contentHash,
    required String ext,
  }) async {
    try {
      final uri = Uri.parse('$_base/api/books/blob/$contentHash?ext=$ext');
      final req = http.Request('GET', uri)
        ..headers.addAll(ApiConfig.headers(token: token));
      final streamed = await _http.send(req).timeout(_blobTimeout);

      // 🔴 长度检查必须在**读 body 之前** —— 读完再判等于内存已经花掉了。
      final declared = streamed.contentLength;
      if (declared != null && declared > kMaxBookBytes) {
        // 主动丢弃这个响应（不消费 body）—— 连接由底层池回收。
        return BlobTooLarge(
          '云端文件 ${declared ~/ (1024 * 1024)} MB，超过单本上限 '
          '${kMaxBookBytes ~/ (1024 * 1024)} MB',
        );
      }

      final bytes = await streamed.stream.toBytes().timeout(_blobTimeout);
      // ⚠️ 这里必须用**原始字节**而不是字符串（`body` 会按 UTF-8 解码 ⇒ 二进制被破坏）
      return parseDownloadResponse(
        streamed.statusCode,
        bytes,
        streamed.headers['content-type'],
        // 🔑 把**本次实际用的** ext 带出来 —— 根因见 `BlobDownloaded.ext` 的长说明：
        //    下载方（`downloadCloudBook`）不能猜格式，否则 txt 书会被当 epub 解析。
        ext: ext,
      );
    } on TimeoutException {
      return const BlobFailed('下载超时（网络慢）');
    } catch (e) {
      debugPrint('bookBlob.download 失败: $e');
      return BlobFailed('下载失败：$e');
    }
  }

  /// 删除云端文件。
  ///
  /// ⚠️ 它是「两步删书」的**第二步**（第一步是推 `sync_book.deleted=1`）——
  ///    端侧删书时**两步都要做**；只做第一步会让文件留在云端占配额
  ///    （后端已把已删书排除在配额之外，所以用户不受影响，但空间不会释放）。
  Future<BlobResult> delete({
    required String token,
    required String contentHash,
  }) async {
    try {
      final uri = Uri.parse('$_base/api/books/blob/$contentHash');
      final resp = await _http
          .delete(uri, headers: ApiConfig.headers(token: token))
          .timeout(ApiConfig.longTimeout);
      return parseDeleteResponse(resp.statusCode, resp.body);
    } on TimeoutException {
      return const BlobFailed('删除超时');
    } catch (e) {
      debugPrint('bookBlob.delete 失败: $e');
      return BlobFailed('删除失败：$e');
    }
  }

  /// 下载**不知道扩展名**的书（「只有云端」的书就是这种情况）。
  ///
  /// 🔴 为什么会有「不知道扩展名」：对象键是 `{hash}.{ext}`，而后端的
  ///    `sync_book` 表（书单）**没有 `ext` 字段**（2026-10-08 实测）——
  ///    于是「本地已经导入的书」（能从 `book.source_format` 知道）
  ///    与「只有云端的书」（本地没有任何记录）命运不同：后者拿不到 ext。
  ///
  /// ⇒ 本方法**依次试** `epub` / `txt`（书籍格式只有这两种）。
  ///    代价是 txt 的书会多一次 404（**最坏 2 次请求**），换来**零后端改动**。
  ///    📌 待办：后端给 `sync_book` 加 `ext` 列更干净（见本轮报告）——
  ///       那时本方法可以退化成「直接带 ext 下载」。
  ///
  /// ⚠️ 只把 **404** 当成「换下一个格式试」；401 / 网络失败 / 5xx **立即返回**
  ///    （继续试只会重复同样的错误，还会把「未登录」拖成两次请求）。
  Future<BlobResult> downloadAuto({
    required String token,
    required String contentHash,
  }) async {
    BlobResult last = const BlobNotFound();
    for (final ext in const ['epub', 'txt']) {
      final r = await download(
        token: token,
        contentHash: contentHash,
        ext: ext,
      );
      if (r is BlobNotFound) {
        last = r;
        continue;
      }
      return r;
    }
    return last;
  }

  void dispose() => _http.close();
}
