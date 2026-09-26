import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 接收系统「用 CoEvo 打开」传入的文件（iOS）。
///
/// 工作原理：
/// - iOS 侧把文件放进 `Documents/Inbox/`，并通过 MethodChannel 通知（见 `ios/Runner/AppDelegate.swift`）
/// - 本服务把文件从 Inbox **搬进** `Documents/imports/`，然后删除 Inbox 原文件
/// - 上层通过 [files] 拿到落地后的文件，交给导入器解析
///
/// 🔴 **为什么必须搬走**：iOS 传入的文件留在 `Documents/Inbox/` 会让 Inbox 持续膨胀
/// （官方明确要求 App 自行处理后清理）。不处理的后果是 App 体积随使用不断增长。
///
/// 三条取值路径（互为兜底，靠「取出即清空」保证不重复）：
/// 1. [start] 时的首次拉取 —— 覆盖冷启动
/// 2. iOS 推送的 `onFileAvailable` 信号 —— 覆盖热启动
/// 3. App 回到前台时再拉一次 —— 兜底（信号丢失 / 非 iOS 平台）
class OpenWithHandler {
  OpenWithHandler({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 `ios/Runner/AppDelegate.swift` 中的 channel 名称一致，改动需同步。
  static const channelName = 'coevo/open_with';

  /// 导入文件的落地目录名（位于 App Documents 下）
  static const _importsDirName = 'imports';

  /// iOS 传入外部文件的暂存目录名（系统约定，不可改）
  static const _inboxDirName = 'Inbox';

  final MethodChannel _channel;
  final _controller = StreamController<File>.broadcast();

  _LifecycleWatcher? _watcher;
  Directory? _cachedImportsDir;
  Future<void>? _draining;
  bool _started = false;

  /// 已落地到 imports 目录的文件流。每导入一个文件 emit 一次。
  Stream<File> get files => _controller.stream;

  /// 开始接收。需在 `runApp` 之后调用（依赖 `WidgetsBinding`）。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler(_onMethodCall);

    _watcher = _LifecycleWatcher(_drain);
    WidgetsBinding.instance.addObserver(_watcher!);

    // 冷启动遗留的文件
    await _drain();
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onFileAvailable') {
      await _drain();
    }
    return null;
  }

  /// 拉取待处理文件并逐个落地。
  ///
  /// iOS 侧「取出即清空」，故本方法可安全重复调用而不会重复处理 ——
  /// 但**并发调用必须串行化**：若两次 `getPendingFiles` 交错（都发生在 Swift 侧清空之前），
  /// 同一个路径会被拿到两次，导致重复复制出 `book (1).epub`。
  Future<void> _drain() {
    final inflight = _draining;
    if (inflight != null) return inflight;

    final future = _doDrain().whenComplete(() => _draining = null);
    _draining = future;
    return future;
  }

  Future<void> _doDrain() async {
    List<dynamic>? paths;
    try {
      paths = await _channel.invokeMethod<List<dynamic>>('getPendingFiles');
    } on MissingPluginException {
      return; // 非 iOS 平台（无原生实现）
    } on PlatformException {
      return;
    }
    if (paths == null || paths.isEmpty) return;

    for (final path in paths) {
      if (path is String && path.isNotEmpty) {
        await _ingest(File(path));
      }
    }
  }

  /// 把外部文件复制进 imports 目录，并在安全时清理源文件。
  Future<void> _ingest(File source) async {
    try {
      if (!source.existsSync()) return;

      final dir = await _importsDir();
      final dest = _uniqueDestination(dir, _basename(source.path));

      await source.copy(dest.path);

      // 🔴 只清理 iOS 的 Inbox 暂存文件。
      // 绝不可删除其他来源的文件（例如用户从 iCloud / 文件 App 自选的原始书籍）
      // —— 那会删掉用户自己的文件。
      if (_isInboxPath(source.path)) {
        try {
          await source.delete();
        } catch (_) {}
      }

      if (!_controller.isClosed) _controller.add(dest);
    } catch (_) {
      // 单个文件失败不影响其余文件
    }
  }

  /// 目标路径重名时追加序号，避免覆盖已导入的书。
  File _uniqueDestination(Directory dir, String filename) {
    final target = File('${dir.path}/$filename');
    if (!target.existsSync()) return target;

    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final ext = dot > 0 ? filename.substring(dot) : '';

    for (var i = 1; i < 1000; i++) {
      final candidate = File('${dir.path}/$stem ($i)$ext');
      if (!candidate.existsSync()) return candidate;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return File('${dir.path}/$stem-$stamp$ext');
  }

  Future<Directory> _importsDir() async {
    final cached = _cachedImportsDir;
    if (cached != null && cached.existsSync()) return cached;

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_importsDirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    _cachedImportsDir = dir;
    return dir;
  }

  static bool _isInboxPath(String path) => path.contains('/$_inboxDirName/');

  static String _basename(String path) {
    final sep = Platform.pathSeparator;
    final idx = path.lastIndexOf(sep);
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  void dispose() {
    final watcher = _watcher;
    if (watcher != null) {
      WidgetsBinding.instance.removeObserver(watcher);
      _watcher = null;
    }
    _channel.setMethodCallHandler(null);
    if (!_controller.isClosed) _controller.close();
    _started = false;
  }
}

/// 回到前台时补拉一次，兜底信号丢失的场景。
class _LifecycleWatcher with WidgetsBindingObserver {
  _LifecycleWatcher(this._onResumed);

  final Future<void> Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }
}
