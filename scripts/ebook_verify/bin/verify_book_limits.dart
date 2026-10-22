// 电子书体积上限 —— **端 / 服 常量一致性**验收（纯 Dart · 零依赖 · 本机可跑）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_book_limits.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 这个脚本为什么必须存在（一次真实的静默故障）
//
// 2026-10-21 审计发现：端侧 `kMaxBookBytes = 50 MB`，后端 `MAX_BOOK_BYTES = 32 MB`，
// 而端侧那行的注释写着「**与后端同值 —— 改一处必须改两处**」。
//
// 后果链（每一步都不报错）：
//   32–50 MB 的书 → 端侧校验通过 → 解析/落库成功 → 上传被后端拒（413）
//   → 端侧把 413 归成「配额满」→ 上传队列 `_cancelled = true` ⇒ **整队停摆**
//   → 用户看到「云端空间不足」，而实际是体积超限，且其余正常的书也传不上去。
//
// ⇒ **「注释里写必须同值」守不住这件事**（已证）。必须让机器每次都去比。
//
// # 顺带锁住的两条「配套约束」
//
// ① `MAX_BOOK_BYTES` 能取 50 MB 的**前提是上传已流式**。若有人把 handler 改回
//    整块 `Vec<u8>`，50 MB × 并发就会 OOM —— 所以这里同时断言「流式实现还在」。
// ② `CLOUD_BOOK_QUOTA_BYTES`（2 GB）也是跨语言常量，一并比。
//
// ⚠️ 本脚本**故意**从源码文本里抠数字而不是 import：那是唯一能跨语言比的办法。
//    抠不到就判失败（而不是跳过）—— 静默跳过等于没有断言。

import 'dart:io';

import '../../../app/lib/services/ebook/book_blob_parse.dart';
import '../../../app/lib/services/ebook/book_text.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail == null ? name : '$name —— $detail');
  }
}

/// 从仓库根往下找文件（脚本可能从任意 cwd 启动）。
File? _locate(String rel) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/$rel');
    if (f.existsSync()) return f;
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

String _read(String rel) {
  final f = _locate(rel);
  if (f == null) return '';
  return f.readAsStringSync();
}

/// 从形如 `NAME: i64 = 50 * 1024 * 1024;` 的声明里抠出字节数。
/// 只认 `N * 1024 * 1024` / `N * 1024 * 1024 * 1024` 两种写法。
int? _parseMiBOrGiB(String src, String name) {
  final re = RegExp(
    '\\b$name\\b\\s*:[^=]*=\\s*(\\d+)\\s*\\*\\s*1024\\s*\\*\\s*1024(\\s*\\*\\s*1024)?',
  );
  final m = re.firstMatch(src);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return m.group(2) != null ? n * 1024 * 1024 * 1024 : n * 1024 * 1024;
}

void main() {
  const storageRs = 'backend/crates/api_server/src/book_storage.rs';
  const handlerRs = 'backend/crates/api_server/src/book_blob_handler.rs';

  final storage = _read(storageRs);
  final handler = _read(handlerRs);

  // ── ① 单本上限：三处必须同值 ──
  final backendMax = _parseMiBOrGiB(storage, 'MAX_BOOK_BYTES');
  check(
    '能从后端源码抠出 MAX_BOOK_BYTES',
    backendMax != null,
    backendMax == null ? '抠不到（改名了？→ 同步改本脚本）' : null,
  );

  if (backendMax != null) {
    check(
      'kMaxBookBytes == 后端 MAX_BOOK_BYTES',
      kMaxBookBytes == backendMax,
      '端侧上传上限 $kMaxBookBytes ≠ 后端 $backendMax'
          '（端侧更大 ⇒ 书能导入却永远传不上去）',
    );
    check(
      'kMaxEbookBytes == 后端 MAX_BOOK_BYTES',
      kMaxEbookBytes == backendMax,
      '端侧解析上限 $kMaxEbookBytes ≠ 后端 $backendMax',
    );
  }

  // ── ② 云端配额：两处必须同值 ──
  final backendQuota = _parseMiBOrGiB(storage, 'CLOUD_BOOK_QUOTA_BYTES');
  check(
    '能从后端源码抠出 CLOUD_BOOK_QUOTA_BYTES',
    backendQuota != null,
  );
  if (backendQuota != null) {
    check(
      'kCloudQuotaBytes == 后端 CLOUD_BOOK_QUOTA_BYTES',
      kCloudQuotaBytes == backendQuota,
      '$kCloudQuotaBytes ≠ $backendQuota',
    );
  }

  // ── ③ 50 MB 的前提：上传必须仍然流式 ──
  //
  // 🔴 这条不是「代码风格」断言 —— 它锁的是「那个数字为什么允许这么大」。
  check(
    '上传走 put_from_file（流式落盘，不是攒 Vec<u8>）',
    handler.contains('put_from_file'),
  );
  check(
    '上传路径没有把整本书攒进内存（无 `Vec<u8>` 累计块）',
    !handler.contains('buf.extend_from_slice'),
    '若改回整块读，必须把 MAX_BOOK_BYTES 降回 32 MB —— 否则并发上传会 OOM',
  );

  // ── ④ Body limit 必须由常量推导，不能写死数字 ──
  check(
    'DefaultBodyLimit 由 MAX_BOOK_BYTES 推导',
    handler.contains('MAX_BOOK_BYTES + 1024 * 1024'),
    '写死数字会让「改常量后请求仍被旧上限挡住」',
  );

  // ── ⑤ 413 必须归成 BlobTooLarge，不能归成 BlobQuotaExceeded ──
  final parseDart = _read('app/lib/services/ebook/book_blob_parse.dart');
  final idx413 = parseDart.indexOf('statusCode == 413');
  check('端侧有 413 分支', idx413 >= 0);
  if (idx413 >= 0) {
    // 取 413 分支后一段（**窗口要够长**：这个分支里现在有「先判 nginx、再判 axum」
    // 的两段注释，400 字符会把真正的 `return BlobTooLarge` 挤出窗口 ⇒ **假红**。
    // 📌 判据：滑窗类断言必须核实「目标确实落在窗口内」，否则窗口一改就误报。）
    final seg = parseDart.substring(
      idx413,
      (idx413 + 1200).clamp(0, parseDart.length),
    );
    check(
      '413 → BlobTooLarge（不是配额满）',
      seg.contains('BlobTooLarge') && !seg.contains('return BlobQuotaExceeded'),
      '归成配额满会让**整个上传队列**因一本大书停摆',
    );
  }

  // ── ⑥ 413 必须**区分来源**（nginx 的 HTML vs axum 的纯文本）──
  //
  // 🔴 2026-10-22 真机：nginx `client_max_body_size` 还是 2m（电子书上传上线前定的），
  //    一本 **5.5MB** 的书被 nginx 直接 413，而端侧把它归成「超过单本上限 50MB」
  //    —— **5.5MB 被说成超过 50MB**，且请求根本没到后端（日志零记录）。
  // 判据：**状态码相同不代表语义相同**。
  check(
    '413 分支能区分 nginx（HTML 响应体）与 axum',
    parseDart.contains("body.trimLeft().startsWith('<')"),
    '不区分 ⇒ nginx 挡下来的请求会被谎报成「超过单本上限」',
  );

  // ── ⑦ 部署侧必须知道「还有第三处上限」（nginx）──
  //
  // ⚠️ nginx 配置不在仓库里，无法机械比对 ⇒ 只能断言**文档与代码里都提到它**，
  //    让下一个改上限的人不会漏掉（这次漏掉，代价是排查了一整晚）。
  final storageDocs = _read('docs/deploy/README.md');
  check(
    '部署文档提到 client_max_body_size（第三处上限）',
    storageDocs.contains('client_max_body_size'),
    '三处上限：端侧 kMaxBookBytes / 后端 MAX_BOOK_BYTES / nginx client_max_body_size',
  );

  _report();
}

void _report() {
  final total = _pass + _fail;
  if (_failures.isNotEmpty) {
    print('\n🔴 失败 ${_failures.length} 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('\n通过 $_pass / $total');
  if (_fail == 0) {
    print('✅ 全部通过');
  }
  if (_fail > 0) {
    throw StateError('电子书体积上限一致性验收失败 $_fail 项');
  }
}
