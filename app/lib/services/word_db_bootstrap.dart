/// `word.db` 首次落盘 —— **决策逻辑纯 Dart，IO 由调用方注入**。
///
/// # 为什么必须复制（不能直接用 assets）
/// `assets/` 是**打包资源**：Flutter 通过 `rootBundle` 给你**字节**，不是可 `open` 的文件路径。
/// 而 SQLite 需要一个**真实文件**（iOS 的 bundle 只读，且打开时会尝试建 WAL）。
/// → 所以：**首次启动把 assets 里的库复制到可写目录**，之后从那里只读打开。
///
/// ```
/// assets/word.db ──rootBundle.load──► ByteData(31.4 MB)
///                                        │ 写盘（仅首次 / 词库变更时）
///                                        ▼
///                 getApplicationDocumentsDirectory()/word.db ──► SQLite(只读)
/// ```
///
/// # 🔴 本文件为什么是「纯 Dart」
/// 「要不要复制」是个**有边界的判断**，而它出错的方式**没有任何运行时症状**：
///
/// | 判断错了 | 后果 |
/// |---|---|
/// | 该复制时没复制 | App 升级后用户**一直用旧词库**，查词结果陈旧，**不报错** |
/// | 不该复制时复制了 | 每次启动白等 ~1 s 复制 31 MB |
/// | 复制了一半 | 库损坏（SQLite 打开报错，或更糟：**能打开但读出错数据**） |
///
/// 所以把判断抽出来、**让脚本能直接断言它**（见 `scripts/query_verify/bin/verify_worddb_bootstrap.dart`）——
/// 与 `word_query_service.dart` / `user_db.dart` 同一套做法（见 skill `verifiable-core-logic`）。
///
/// # 🆕 判断依据已从「只看大小」升级为「版本号 或 大小」（2026-10-01）
///
/// **原来的限制**（本文件此前自述，保留作决策史）：
/// > 「判断依据是**文件大小** —— 这是**启发式**……若将来真出现〔同大小不同内容〕，
/// >  应改为「随词库生成的**版本号文件**」（`word_db.version`）。**现在不预先加**」
///
/// 🔑 **那个「将来」已经到了** —— 一旦有词库回流（LLM 制卡 → 回灌 `word.db`），
///    「词库更新」从**罕见**变成**常态**（每次发版都可能变）；
///    而**发版收敛**（把 `ext:<spelling>` 收敛成正式 `w…`、清掉已回流的端侧缓存）
///    正要**依赖「我知道词库换了」这个信号**。
///    若新版恰好大小相同 → 判 `skipped` → **词库不更新 + 用户数据不收敛**，且**静默**。
///
/// **现在的规则**（两信号取**并集**，任一不同就复制 —— 宁可多复制一次，不可漏更新）：
/// | asset 有版本? | 判定 |
/// |---|---|
/// | ✅ | `target.version != asset.version` → 复制（含 `target.version == null`：**首轮引入版本机制**，须复制一次以对齐）|
/// | ✅（版本相同）| 再比大小兜底：`size` 不同仍复制 |
/// | ❌ | 退回**纯大小比较**（保留原能力，不至于因为版本文件缺失就完全失能）|
///
/// ⚠️ **`assetSize <= 0` 的防线不变**：资产读出 0 字节时**仍然不覆盖**（见 `needsCopy`）。
///    版本号再准，也不能让「用坏资产盖掉好库」变得可能。
///
/// 📄 版本文件由 `scripts/gen_word_db_version.py` 从 `word.db` 生成
///    （**纯内容指纹** —— 不含生成时间，否则每天都会判「变了」、白复制 31 MB）。
library;

import 'dart:typed_data';

/// 目标文件（可写目录里的 `word.db`）的状态。
class TargetState {
  const TargetState({required this.exists, required this.size, this.version});

  /// 不存在。
  const TargetState.missing() : exists = false, size = 0, version = null;

  final bool exists;
  final int size;

  /// 🆕 **上次落盘时记录的词库版本**（`word_db.version` 的内容）。
  ///
  /// 🔴 `null` 有两种含义，**不要混为一谈**（判定时按「与 asset 版本不同」处理，
  ///    即**都会触发一次复制** —— 这是有意的）：
  /// | 情形 | 为何要复制一次 |
  /// |---|---|
  /// | **旧版 App 落的盘**（那时还没有版本机制）| 对齐到版本机制；此后正常 |
  /// | 版本文件被删/损坏 | 宁可多复制一次，也不要把「库可能不一致」留成静默状态 |
  ///
  /// ⚠️ 但 `exists == false` 时它也是 `null` —— 那种情况由 `created` 分支先兜住，不会到比较。
  final String? version;

  @override
  String toString() => exists
      ? '存在(${_mb(size)}${version == null ? "" : " · $version"})'
      : '不存在';
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// 落盘动作 —— 供调用方打日志与测试断言。
enum BootstrapAction {
  /// 目标不存在 → 复制（**首次启动**）。
  created,

  /// 目标存在但大小不同 → 覆盖（**词库更新 / App 升级**）。
  replaced,

  /// 大小相同 → 跳过（**绝大多数启动**）。
  skipped,
}

/// 🆕 版本信号是否构成「必须复制」的理由。
///
/// 🔑 单独抽出来，是为了让 `needsCopy` / `planBootstrap` / `describe`
///    **三处用同一个判据** —— 否则「要不要复制」与「为什么」会各说各话。
bool _versionChanged({required TargetState target, String? assetVersion}) {
  // 资产没带版本（或为空）→ 本路信号不成立，**退回比大小**（保留原有能力）
  if (assetVersion == null || assetVersion.isEmpty) return false;
  // ⚠️ `target.version == null` 也算「变了」：见 TargetState.version 的两种含义
  return target.version != assetVersion;
}

/// 🔑 **纯函数**：要不要复制。
///
/// | 输入 | 输出 | 理由 |
/// |---|---|---|
/// | 目标不存在 | `true` | 首次启动 |
/// | `assetSize <= 0` | `false` | 🔴 **资产异常时不覆盖** —— 宁可没有库，也不要**用空文件盖掉好库** |
/// | **版本不同**（两信号取并集）| `true` | 🆕 这才是「**大小相同但内容不同**」的解药 |
/// | 大小不同 | `true` | 兜底 |
/// | 都相同 | `false` | 同一个库 |
bool needsCopy({
  required TargetState target,
  required int assetSize,
  String? assetVersion,
}) {
  if (!target.exists) return true;
  // 🔴 防御：assets 读出来 0 字节（打包事故 / 文件被清空）→ **不要覆盖**已有的好库。
  //    这个分支反直觉但重要：**「用坏数据盖掉好数据」比「不更新」糟得多**。
  //    ⚠️ 它**优先于**版本判断 —— 见文件头的说明。
  if (assetSize <= 0) return false;
  if (_versionChanged(target: target, assetVersion: assetVersion)) return true;
  return target.size != assetSize;
}

/// 决策的**唯一输出口**（把「要不要」与「为什么」一起给出，便于日志与断言）。
BootstrapAction planBootstrap({
  required TargetState target,
  required int assetSize,
  String? assetVersion,
}) {
  if (!target.exists) return BootstrapAction.created;
  if (assetSize <= 0) return BootstrapAction.skipped;
  if (_versionChanged(target: target, assetVersion: assetVersion)) {
    return BootstrapAction.replaced;
  }
  if (target.size != assetSize) return BootstrapAction.replaced;
  return BootstrapAction.skipped;
}

// ─────────────────────────────────────────────────────────────
// IO 抽象 —— 由调用方（Flutter 或脚本）注入
// ─────────────────────────────────────────────────────────────

/// 读 assets 里的 `word.db` 字节。
typedef AssetReader = Future<Uint8List> Function();

/// 探测目标文件状态（不存在返回 `TargetState.missing()`）。
typedef TargetProbe = TargetState Function();

/// 把字节写到目标路径。
typedef TargetWriter = Future<void> Function(Uint8List bytes);

/// 🆕 读**资产**带的版本号（无该文件时返回 `null` —— 允许缺失，退回比大小）。
typedef AssetVersionReader = Future<String?> Function();

/// 🆕 把版本号写到**目标侧**（供下次启动比较）。
typedef TargetVersionWriter = Future<void> Function(String version);

/// 落盘结果（含诊断信息）。
class BootstrapResult {
  const BootstrapResult({
    required this.action,
    required this.assetSize,
    required this.targetBefore,
    this.assetVersion,
  });

  final BootstrapAction action;
  final int assetSize;
  final TargetState targetBefore;

  /// 🆕 资产带的版本（无版本文件时为 `null`）。
  final String? assetVersion;

  bool get didWrite => action != BootstrapAction.skipped;

  /// 🔑 **为什么复制 / 为什么跳过** —— 抽成两个小函数，
  ///    让「判定依据」与「说明文字」共享同一个 `_versionChanged`（不会各说各话）。
  ///
  /// ⚠️ 版本号**原样打印、不套前缀** —— 它本身已是自解释的形态（如 `11523+65cd2ea4`），
  ///    再加 `v` 会变成「v11523+…」（真实踩过：测试里传 `v2` 时打印成 `vv2`）。
  String _replaceReason() {
    if (_versionChanged(target: targetBefore, assetVersion: assetVersion)) {
      return targetBefore.version == null
          ? '首次带版本号（资产 $assetVersion）→ 复制一次以对齐'
          : '版本不同（${targetBefore.version} → $assetVersion）';
    }
    return '大小不同（${_mb(targetBefore.size)} ≠ ${_mb(assetSize)}）';
  }

  String _skipReason() => assetVersion == null
      ? '大小相同（${_mb(assetSize)}）· 资产无版本号'
      : '版本与大小都相同（$assetVersion · ${_mb(assetSize)}）';

  /// 一行日志（**必须带路径与大小** —— 出问题时一眼看出判断依据）。
  String describe(String targetPath) {
    final why = switch (action) {
      BootstrapAction.created => '目标不存在',
      BootstrapAction.replaced => _replaceReason(),
      BootstrapAction.skipped => targetBefore.exists
          ? _skipReason()
          : '资产异常（assetSize=$assetSize）→ 不覆盖',
    };
    final act = switch (action) {
      BootstrapAction.created => '复制',
      BootstrapAction.replaced => '覆盖',
      BootstrapAction.skipped => '跳过',
    };
    return '[word_db] $act：$why · target=$targetPath';
  }
}

/// 落盘主流程 —— **纯逻辑**（判断 + 编排），IO 全部注入。
///
/// ```dart
/// // App：
/// await ensureWordDb(
///   targetPath: p,
///   readAsset: () async => (await rootBundle.load('assets/word.db')).buffer.asUint8List(),
///   probe: () => File(p).existsSync()
///       ? TargetState(exists: true, size: File(p).lengthSync())
///       : const TargetState.missing(),
///   write: (bytes) => File(p).writeAsBytes(bytes, flush: true),
/// );
/// ```
///
/// 🔴 **写盘用 `flush: true`**（或等价物）—— 「文件系统说写完了」和「真的落盘了」是两件事，
/// 而这里**没有第二次机会**（下次启动只会比较大小、不会校验内容）。
///
/// # 🆕 版本号的读写（2026-10-01）
/// `readAssetVersion` / `writeVersion` **都是可选**的：不传则行为与从前完全一致
/// （纯大小比较）—— 这样既有调用方与既有断言**无需一次全改**。
Future<BootstrapResult> ensureWordDb({
  required String targetPath,
  required AssetReader readAsset,
  required TargetProbe probe,
  required TargetWriter write,
  AssetVersionReader? readAssetVersion,
  TargetVersionWriter? writeVersion,
}) async {
  final before = probe();
  final bytes = await readAsset();
  // ⚠️ 版本要在**同一个 async 段里**读好（与 bytes 是同一批资产）——
  //    若放到写盘前才读，中途资产被换会导致「库是 A、版本是 B」。
  final assetVersion = readAssetVersion == null ? null : await readAssetVersion();

  final action = planBootstrap(
    target: before,
    assetSize: bytes.length,
    assetVersion: assetVersion,
  );
  final result = BootstrapResult(
    action: action,
    assetSize: bytes.length,
    targetBefore: before,
    assetVersion: assetVersion,
  );

  if (result.didWrite) {
    await write(bytes);
    // 🆕 🔴 **顺序不可颠倒：先写库，后写版本。**
    //   · 先库后版本 → 半途失败 = 「新库 + 旧版本」→ 下次启动判「版本不同」→ **再复制一次** ✅ 自愈
    //   · 先版本后库 → 半途失败 = 「旧库 + 新版本」→ 下次启动判「版本相同」→
    //     **永远不更新**，且用户毫无感知 🔴
    //   🔑 一般化：**「标记它已完成」的写入，必须排在「完成」之后。**
    if (assetVersion != null && writeVersion != null) {
      await writeVersion(assetVersion);
    }
  }
  return result;
}
