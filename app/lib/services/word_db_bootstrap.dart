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
/// # ⚠️ 判断依据是「文件大小」—— 这是**启发式**，如实说明
/// 「size 相同但内容不同」在理论上可能（31 MB 的库重写后极少等长，但**不是不可能**）。
/// 若将来真出现，应改为「随词库生成的版本号文件」（`word_db.version`）。
/// **现在不预先加**（不为假设的复杂度付费），但这条限制写在这里，别让后人以为是完备的。
library;

import 'dart:typed_data';

/// 目标文件（可写目录里的 `word.db`）的状态。
class TargetState {
  const TargetState({required this.exists, required this.size});

  /// 不存在。
  const TargetState.missing() : exists = false, size = 0;

  final bool exists;
  final int size;

  @override
  String toString() => exists ? '存在(${_mb(size)})' : '不存在';
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

/// 🔑 **纯函数**：要不要复制。
///
/// | 输入 | 输出 | 理由 |
/// |---|---|---|
/// | 目标不存在 | `created` | 首次启动 |
/// | `assetSize <= 0` | `skipped` | 🔴 **资产异常时不覆盖** —— 宁可没有库，也不要**用空文件盖掉好库** |
/// | 大小不同 | `replaced` | 词库变了 |
/// | 大小相同 | `skipped` | 同一个库 |
bool needsCopy({required TargetState target, required int assetSize}) {
  if (!target.exists) return true;
  // 🔴 防御：assets 读出来 0 字节（打包事故 / 文件被清空）→ **不要覆盖**已有的好库。
  //    这个分支反直觉但重要：**「用坏数据盖掉好数据」比「不更新」糟得多**。
  if (assetSize <= 0) return false;
  return target.size != assetSize;
}

/// 决策的**唯一输出口**（把「要不要」与「为什么」一起给出，便于日志与断言）。
BootstrapAction planBootstrap({
  required TargetState target,
  required int assetSize,
}) {
  if (!target.exists) return BootstrapAction.created;
  if (assetSize <= 0) return BootstrapAction.skipped;
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

/// 落盘结果（含诊断信息）。
class BootstrapResult {
  const BootstrapResult({
    required this.action,
    required this.assetSize,
    required this.targetBefore,
  });

  final BootstrapAction action;
  final int assetSize;
  final TargetState targetBefore;

  bool get didWrite => action != BootstrapAction.skipped;

  /// 一行日志（**必须带路径与大小** —— 出问题时一眼看出判断依据）。
  String describe(String targetPath) {
    final why = switch (action) {
      BootstrapAction.created => '目标不存在',
      BootstrapAction.replaced =>
        '大小不同（目标 ${_mb(targetBefore.size)} ≠ 资产 ${_mb(assetSize)}）',
      BootstrapAction.skipped => targetBefore.exists
          ? '大小相同（${_mb(assetSize)}）'
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
Future<BootstrapResult> ensureWordDb({
  required String targetPath,
  required AssetReader readAsset,
  required TargetProbe probe,
  required TargetWriter write,
}) async {
  final before = probe();
  final bytes = await readAsset();

  final action = planBootstrap(target: before, assetSize: bytes.length);
  final result = BootstrapResult(
    action: action,
    assetSize: bytes.length,
    targetBefore: before,
  );

  if (result.didWrite) {
    await write(bytes);
  }
  return result;
}
