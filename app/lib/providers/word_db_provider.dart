import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../services/word_db_bootstrap.dart';
import '../services/word_query_service.dart';

/// `word.db` 的 assets 键。
const String kWordDbAsset = 'assets/word.db';

/// 词库落盘后的文件名。
const String kWordDbFileName = 'word.db';

/// 🆕 词库**版本号**的 assets 键（由 `scripts/gen_word_db_version.py` 生成）。
///
/// 🔴 **必须在 `pubspec.yaml` 的 `assets:` 里声明** —— 漏声明**不会编译报错**，
///    只在运行时 `loadString` 抛异常（本项目已因此踩过一次）。
///    ⚠️ 本代码对该异常**做了容错**（缺失 → 退回比大小），所以漏声明表现为
///    「静默退化为旧行为」而非崩溃 —— **更难发现**，故此处特别标注。
const String kWordDbVersionAsset = 'assets/word_db.version';

/// 🆕 落盘后，版本号在可写目录里的文件名（与 `word.db` 同级）。
const String kWordDbVersionFileName = 'word_db.version';

/// 词库加载的**终态**。
///
/// # 🔑 为什么不是一个 `WordQueryService?`
/// 返回裸 `null` 会把**三种语义**糊在一起，而它们对用户完全不同：
///
/// | 实际语义 | 用户能等到吗 |
/// |---|---|
/// | 正在首次落盘/打开 | ✅ 能（约 0.5–2 s） |
/// | **当前平台没有本地 SQLite**（web） | ❌ **永远等不到** |
/// | 真机上落盘/打开失败 | ❌ 等不到（需重启） |
///
/// 三者若都显示「正在准备，请稍候再试」→ 后两种是**空头承诺**
/// （用户会一直重试，且以为是自己的问题）。所以让类型**必须说明原因**。
///
/// ⚠️ **加载中不在这里** —— 那是 `AsyncLoading`（`valueOrNull == null`）。
///    本类型只表达「future 已经完成」的三种结局。
sealed class WordDbLoad {
  const WordDbLoad();
}

/// ✅ 可用。
final class WordDbReady extends WordDbLoad {
  final WordQueryService service;
  const WordDbReady(this.service);
}

/// ❌ 当前平台没有本地 SQLite（web）。
///
/// 🔴 **这是永久状态，不是「等一会」** ——
/// 三项依赖都没有 web 实现（实测插件声明）：
/// `sqflite` 只声明 `android/ios/macos` · `path_provider` 无 web ·
/// `dart:io` 的 `File` 在 web 上是 stub。
final class WordDbUnsupported extends WordDbLoad {
  const WordDbUnsupported();
}

/// ❌ 真机上落盘或打开失败 → 需重启 / 上报。
final class WordDbFailed extends WordDbLoad {
  /// 原始异常（供日志与上报；不直接展示给用户）。
  final Object error;
  const WordDbFailed(this.error);
}

/// 词库查询服务 —— **只读**，进阅读器才需要。
///
/// # 生命周期与时机
/// · **不在启动时加载** —— 31.4 MB 的落盘 + 打开不该阻塞首屏。
/// · 进阅读器时由 `reader_screen` 的 `build` **`ref.watch`** 触发，
///   首次会走「复制 → 打开」（约 0.5–2 s），之后是「跳过 → 打开」。
///
/// 🔴🔴 **消费方必须 `ref.watch`（不能只 `ref.read`）** ——
/// 只 read 的话，落盘要等到「用户第一次长按查词」那一刻才开始，
/// 而那一刻 `valueOrNull` **必然还是 null** → **第一次查词 100% 失败**。
/// （`bookmarkProvider` 也是 watch；同类东西两种做法是 bug。）
///
/// # 🔴 一条硬约束（沿用 Step 3.22 的教训）
///
/// > **不要把易失败的外部依赖放在内容渲染的前置条件上**
///
/// 所以：**词库打不开 ≠ 文章读不了**。阅读器照常渲染正文与痕迹，
/// 只是**长按查词不可用**（且给一句**准确**的提示，而不是笼统的「请稍候」）。
///
/// ## ⚠️ 消费本 provider 时的约定
/// **不要用 `when(error:)`。** 理由同 `bookmarkProvider`：
/// 那会把「库打不开」渲染成**错误整页**，而查词只是阅读的附属动作。
/// 本 provider 也**不会**产生 `AsyncError`（内部已把异常转成 [WordDbFailed]）。
final wordQueryProvider = FutureProvider<WordDbLoad>((ref) async {
  // 🔴 **web 上直接判「不支持」，不做注定失败的尝试。**
  //    三层依赖全缺（sqflite 无 web 实现 · path_provider 无 web · dart:io 是 stub），
  //    所以「试一下再 catch」只会白跑一趟，还让日志里多一条误导性的异常。
  //    ⚠️ 产品只做 iOS，web 仅开发预览 → 这是**已接受的限制**，不是待修的缺陷。
  if (kIsWeb) {
    debugPrint('[word_db] 当前平台无本地 SQLite（web）→ 查词不可用（预期行为，非缺陷）');
    return const WordDbUnsupported();
  }

  try {
    final dir = await getApplicationSupportDirectory();
    final targetPath = p.join(dir.path, kWordDbFileName);
    final versionPath = p.join(dir.path, kWordDbVersionFileName);

    // ── ① 落盘（只在首次 / 词库变更时真写）──
    final result = await ensureWordDb(
      targetPath: targetPath,
      readAsset: _readWordDbAsset,
      probe: () {
        final f = File(targetPath);
        if (!f.existsSync()) return const TargetState.missing();
        // 🆕 一并读上次记录的版本（缺失 → null → 判定里算「变了」，复制一次对齐）
        final vf = File(versionPath);
        return TargetState(
          exists: true,
          size: f.lengthSync(),
          version: vf.existsSync() ? vf.readAsStringSync().trim() : null,
        );
      },
      // 🔴 `flush: true` —— 「写完了」与「真落盘」是两件事，
      //    而这里没有第二次机会（下次启动只比大小、不校验内容）。
      write: (bytes) => File(targetPath).writeAsBytes(bytes, flush: true),
      // 🆕 版本信号：让「大小恰好相同但内容不同」也能被检出（见 bootstrap 文件头）
      readAssetVersion: _readWordDbVersionAsset,
      // ⚠️ 顺序由 `ensureWordDb` 保证：先写 `word.db`，后写它（理由见那里）
      writeVersion: (v) => File(versionPath).writeAsString('$v\n', flush: true),
    );
    // 🔑 日志带路径与大小 —— 出问题时一眼看出判断依据
    debugPrint(result.describe(targetPath));

    // ── ② 打开（只读）──
    final service = await WordQueryService.open(sqflite.databaseFactory, targetPath);
    ref.onDispose(service.close);
    return WordDbReady(service);
  } catch (e, st) {
    // ⚠️ 这里**吞掉异常并转成 [WordDbFailed]**（而不是让它成为 `AsyncError`）——
    //    因为本 provider 的失败语义是「查词功能不可用」，由调用方给**局部**提示；
    //    若成为 AsyncError 而某个消费者误用了 `when(error:)`，
    //    就会把整页变成错误界面。转成结果类型是**更安全**的默认。
    debugPrint('[word_db] 词库不可用：$e\n$st');
    return WordDbFailed(e);
  }
});

/// 读 `assets/word.db` 的字节。
///
/// 🔴 **必须用 `offsetInBytes` / `lengthInBytes`** ——
/// `rootBundle.load` 返回的 `ByteData` **不保证从 buffer 的第 0 字节开始**
/// （它可能是某个更大缓冲区的视图）。写成 `data.buffer.asUint8List()` 会拿到
/// **多出来的头部字节** → 写出的文件头不对 → SQLite 报「file is not a database」。
/// 这个错误只在**真机/真打包**下暴露，本地脚本测不出来。
Future<Uint8List> _readWordDbAsset() async {
  final data = await rootBundle.load(kWordDbAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// 🆕 读 `assets/word_db.version` 的版本号。
///
/// 🔴 **缺失不是错误**（返回 `null`）—— 三种情形都可能：
///   ① 旧版本的构建产物里还没有这个 asset（灰度/回滚期间）
///   ② `pubspec.yaml` 漏声明
///   ③ 生成脚本还没跑
/// → 一律退回「比大小」这个既有能力。**绝不让它成为词库不可用的原因** ——
///   同「增强不该阻断主体」的产品原则：版本号是**判据的增强**，不是功能本身。
Future<String?> _readWordDbVersionAsset() async {
  try {
    final raw = await rootBundle.loadString(kWordDbVersionAsset);
    final v = raw.trim();
    return v.isEmpty ? null : v;
  } catch (e) {
    debugPrint('[word_db] 读不到版本号资产（$e）→ 退回按文件大小判定');
    return null;
  }
}
