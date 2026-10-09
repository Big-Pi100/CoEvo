import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
// `Database` 类型来自 `sqflite_common`（与 `user_db_provider.dart` 同一处理）
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../services/external_word_cache_repository.dart';
import '../services/external_word_card.dart';
import '../services/review_spelling.dart';
import '../services/word_db_bootstrap.dart';
import '../services/word_id_convergence.dart';
import '../services/word_query_service.dart';
import 'device_id_provider.dart';
import 'generate_card_provider.dart';
import 'user_db_provider.dart';

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
    final service = await WordQueryService.open(
      sqflite.databaseFactory,
      targetPath,
      // 🆕 词库外词的卡片来源（`ext:` 回落到 `user.db` 的 `external_word_cache`）
      externalCardLoader: _externalCardLoader(ref),
    );
    ref.onDispose(service.close);

    // ── ③ 🆕 发版收敛（词库**变了**才做）──
    //    把端侧的 `ext:<拼写>` 收敛为正式 `word.id`（见 `word_id_convergence.dart`）
    if (result.didWrite) {
      await _convergeExternalWordIds(ref, service);
    }

    // ── ④ 🆕 修复被写成内部 ID 的拼写（**每次词库就绪都做**，幂等）──
    //
    // 🔴 为什么**不能**和 ③ 一起挂在 `didWrite` 上：
    //    ③ 是「词库变了才需要做的数据迁移」；而「`card_review_state.spelling`
    //    里存着 ID」这条路**词库没变也一样存在**（它是**同步 pull 写坏的**，
    //    见 `review_spelling.dart` 文件头）。挂上去 ⇒ 词库不更新时**永远不修**。
    //
    // 🔑 代价可忽略：候选是「扫一遍 `card_review_state`」（单用户几百行），
    //    且**候选为 0 就直接返回**（连事务都不开）—— 与 ③ 同一种性质。
    // ⚠️ 顺序：放在 ③ **之后** —— 收敛会把 `ext:xxx` 改成 `w0xxxxx`，
    //    改完 spelling 还可能是旧的 `ext:xxx`，正好由 ④ 一起修掉。
    await _repairStaleSpellings(ref, service);

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

/// 🆕 发版收敛 —— 把 `ext:<拼写>` 收敛为正式 `word.id`（2026-10-01 · A2 阶段 ①）。
///
/// # 何时触发
/// **只在词库被真的写入时**（`result.didWrite` = `created` 或 `replaced`）——
/// 因为只有那时「词库里可能多了些词」。每次启动都扫是白扫
/// （绝大多数启动是 `skipped`）。
///
/// # 🔴 容错：`user.db` 打不开**不能**影响词库
/// 与 `_externalCardLoader` 同一条理由：词库是**主体**、收敛是**维护动作**。
/// 收敛失败最坏的结果是「同一个词暂时有两个身份」（下次启动会再试），
/// 而**不该**让整个 App 查不了词。
/// 📌 同产品原则：**增强不该有能力阻断主体**。
///
/// # ⚠️ 它会不会拖慢进阅读器？
/// 会在**首次装/升级的那一次**多花一点时间，量级：
/// · 候选查询：三张小表 `LIKE 'ext:%'`（单用户几百行）
/// · 候选通常为 **0**（词库外生词本来就少）→ `planConvergence` 立即返回空计划
/// → 有 `pairs.isEmpty` 早退**且不开始事务**。
/// 🔑 而且它**只在词库变化时**跑 —— 不是每次进阅读器。
Future<void> _convergeExternalWordIds(Ref ref, WordQueryService wordDb) async {
  // 🔑 `final` + 在 catch 里 `return` → Dart 的**确定赋值**保证下面拿到的是非空值
  //    （比「声明成 `Database?` 再到处 `!`」更安全：漏一个 `!` 就是运行时崩溃）
  final Database userDb;
  try {
    // ⚠️ 用 `read`（不订阅）—— 本 provider 不该因 user.db 变化而重建
    userDb = await ref.read(userDbProvider.future);
  } catch (e) {
    debugPrint('[word_db] 收敛跳过（user.db 不可用）：$e');
    return;
  }

  try {
    final candidates = await externalWordIdsIn(userDb);
    if (candidates.isEmpty) return;   // 🔑 绝大多数情况走这里（连事务都不开）

    final pairs = await planConvergence(
      externalWordIds: candidates,
      // 🔑 拼写当桥：查新词库有没有这个词（有 = 已回流 = 可以收敛）
      resolve: wordDb.idOfSpelling,
    );
    if (pairs.isEmpty) {
      debugPrint('[word_db] 收敛：${candidates.length} 个词库外生词，'
          '但都还没回流 → 全部保留');
      return;
    }

    final r = await convergeExternalWordIds(userDb: userDb, pairs: pairs);
    debugPrint('[word_db] ${r.describe()}');
    // 🔑 收敛改了 `user.db` → 必须让读端重算（否则复习页还显示旧 id）
    ref.read(userDbRevisionProvider.notifier).bump();
  } catch (e, st) {
    // 收敛失败**只记日志** —— 下次词库变化时会重来（幂等，见 `planConvergence`）
    debugPrint('[word_db] 收敛失败（不影响词库使用）：$e\n$st');
  }
}

/// 🆕 把 `card_review_state.spelling` 里**被写成内部 ID** 的行修回真拼写。
///
/// 一句话根因见 `review_spelling.dart` 文件头：同步 pull 时拼写解析不出来、
/// 退回了 `word_id` 占位，而那个占位被**持久化**成了复习列表的标题
/// （用户看到 `w000129` / `hl:<uuid>` / `ext:fixtures`）。
///
/// # 为什么放在「词库就绪后」
/// 解析的第 ⑤ 级要查 `word.db`。词库没就绪时，**正式词**那条修不了 ——
/// 放在启动早期跑会把本来能修好的都漏掉。
///
/// # 取向（与 ③ 收敛一致）
/// · **幂等**：已正确的行不会被重复写（`repairAll` 内部判 `isWordIdShaped`）
/// · **失败只记日志**：不因为它而让词库不可用（增强不该阻断主体）
/// · **改了就 `bump()`**：否则复习页还显示旧值（读端靠 revision 重算）
Future<void> _repairStaleSpellings(Ref ref, WordQueryService wordDb) async {
  final Database userDb;
  try {
    // ⚠️ 用 `read`（不订阅）—— 本 provider 不该因 user.db 变化而重建
    userDb = await ref.read(userDbProvider.future);
  } catch (e) {
    debugPrint('[word_db] 拼写修复跳过（user.db 不可用）：$e');
    return;
  }

  try {
    final resolver = ReviewSpellingResolver(
      userDb,
      // 🔑 复用同一个词库查询（`id → spelling` 只读一列）
      wordLookup: wordDb.spellingOfId,
      onLog: (m) => debugPrint('[word_db] $m'),
    );
    final fixed = await resolver.repairAll();
    if (fixed > 0) {
      debugPrint('[word_db] 拼写修复：$fixed 行（曾显示成内部 ID）');
      // 🔑 改了 `user.db` ⇒ 必须让读端重算
      ref.read(userDbRevisionProvider.notifier).bump();
    }
  } catch (e, st) {
    // 失败**只记日志** —— 下次词库就绪时会重来（幂等）
    debugPrint('[word_db] 拼写修复失败（不影响词库使用）：$e\n$st');
  }
}

/// 🆕 造一个「词库外词卡片」的读取器 —— 复习页/查词时 `ext:` 前缀的回落。
///
/// # 🔴 四条设计要点（都不是随手写的）
///
/// ## ① **回落服务端**（2026-10-09 补）—— 端侧缓存**不是**唯一来源
/// 已定文档（`sync-implementation-assessment-2026-10-04.md:152`）判定本表
/// **不同步**，理由写的是「它是缓存不是资产：**词卡可按需向服务端再取**」——
/// 而本回调原先**只读端侧缓存**，那句话**从来没有落地**：
/// 端侧缓存一丢（重装 / 清数据 / 换账号），这些词就**永久打不开**
/// （2026-10-09 白哥真机：重装后「LLM 生词」卡片显示「这张卡暂时打不开」），
/// 而服务端全局缓存里**本来就有**那份卡（实测该账号 **8/8 命中**
/// ⇒ 回落是**零 LLM 成本、毫秒级**的）。
/// ⇒ 现在：端侧未命中 → `resolveExternalWordCard`（服务端缓存优先）→ **写回端侧缓存**。
/// 📌 判据：**「不同步」的正当性挂在另一条能力上时，必须验证那条能力真的存在**。
///
/// ## ② **容错**：`user.db` 打不开**不能**影响词库
/// 「读端侧缓存失败」被降级成「当作没有缓存」（继续走服务端），**不是**取卡失败；
/// 「缓存写不回去」只记日志，**不影响本次展示**。
/// 🔑 理由不变：词库（`word.db`）是**主体**，`user.db` 是**增强** ——
/// 若让它的失败冒泡到 `wordQueryProvider`，就会变成 `WordDbFailed`
/// → 🔴 **整个 App 查不了词**（连词库内的词也查不了），只因用户库读不出来。
/// 📌 同产品原则：「**增强不该有能力阻断主体**」。
///
/// ## ③ ⚠️ 「真的取不到卡」会**抛** [ExternalCardUnavailable]（带原因 + 能否重试）
/// 这是**刻意**的：旧实现只返回 `null`，界面因此**分不出**
/// 「词库还在准备」与「联网取卡失败」，只好把原因猜成前者
/// —— 于是 `ext:`（**词库外**）的卡提示「可能是词库还在准备」，用户等到天黑也不会好。
/// ⚠️ 它**不会**冒泡到词库 provider：本回调只在 `cardById` 被调用时执行，
///    而 `cardById` ← `reviewCardOf` ← `cardBundleProvider` ——
///    **每一处都只有一个调用方**（`verify_external_word_card.dart` 用计数断言守着）。
///
/// ## ④ **惰性**：用 `read` 且在**被调用时**才取库
/// 回调体只在真正遇到 `ext:` 词时才执行 → **打开词库不依赖 user.db 就绪**
/// （若在这里 `await`，词库打开就会被用户库的初始化时间拖住）。
/// 用 `read`（不订阅）是对的 —— 本 provider 不该因 user.db 变化而重建。
ExternalCardLoader _externalCardLoader(Ref ref) {
  return (String spelling) async {
    final client = ref.read(generateCardClientProvider);
    // 🔑 `device_id` 是**可选统计信号**（服务端算 `distinct_user_count`）：
    //    取不到就传 `null` —— **不阻断取卡**（同划词路径的判据）。
    final deviceId = await deviceIdOrNullFrom(ref);

    return resolveExternalWordCard(
      spelling: spelling,
      readCache: (sp) async {
        final db = await ref.read(userDbProvider.future);
        return ExternalWordCacheRepository(db).contentOf(sp);
      },
      writeCache: (sp, content) async {
        final db = await ref.read(userDbProvider.future);
        await ExternalWordCacheRepository(db).put(sp, content);
      },
      generate: (sp) async =>
          externalCardReplyOf(await client.generate(sp, deviceId: deviceId)),
      onWarn: (m) => debugPrint('[word_db] $m'),
    );
  };
}
