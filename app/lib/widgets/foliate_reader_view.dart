import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 翻页阅读器的 **spike 外壳**（2026-10-22）。
///
/// # 这是什么
///
/// 把 foliate-js 的分页器（`assets/foliate/paginator.js`）跑在 WebView 里，
/// 由 Dart 侧控制「喂内容 / 换主题 / 翻页」，并接收「翻页位置 / 选词」回调。
///
/// # 为什么不是纯 Dart 分页
///
/// foliate 的分页**不是算法，是把活交给浏览器的 CSS 多栏**
/// （`paginator.js::columnize()` 只设 `column-width / column-gap / column-fill`）。
/// 满页、避头尾、图片不切断都是浏览器排版引擎的能力 ——
/// 移植成 Dart 等于从零实现一个排版引擎（Flutter 的 `TextPainter` 只能给总高度，
/// 给不了「第 N 页从哪个字符开始」）。⇒ 只能内嵌 WebView。
///
/// # 🔴 已知边界（spike 阶段先记下来，别当成 bug）
///
/// 1. `relocate` 里的 `fraction` 在上游是 `(page - 1) / (pages - 2)` ——
///    **页数 ≤ 2 时会除零或为负**。`reader.html` 已做 `isFinite` + clamp 兜底。
/// 2. `sections[n].load()` 必须返回**URL 字符串**（上游直接赋给 `iframe.src`）⇒
///    我们用 `URL.createObjectURL(new Blob([html]))`，**不能返回 HTML 源码**。
/// 3. 上游 README 明说 API 不稳定 —— 升级 `paginator.js` 前先读 diff。
///
/// # 用法
/// ```dart
/// final c = FoliateReaderController();
/// FoliateReaderView(controller: c, chapters: ['<p>…</p>', '…'])
/// ```
class FoliateReaderController {
  WebViewController? _web;

  final ValueNotifier<FoliatePosition> position =
      ValueNotifier(const FoliatePosition());
  final ValueNotifier<String?> selectedText = ValueNotifier<String?>(null);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 正文被**单击**了一次（用来切换顶栏/底栏）。
  /// 🔑 用递增计数而不是 bool：连续单击两次要能各自触发一次 toggle。
  final ValueNotifier<int> tapTick = ValueNotifier<int>(0);

  bool _ready = false;
  List<String> _pendingChapters = const [];

  bool get isReady => _ready;

  void _attach(WebViewController web) {
    _web = web;
  }

  Future<void> _setContent(List<String> chapters) async {
    if (_web == null) return;
    // ⚠️ 必须 JSON 转义 —— 章节里含引号/换行，直接拼字符串会把 JS 打断。
    final json = jsonEncode(chapters);
    await _web!.runJavaScript('window.__reader.setContent(${jsonEncode(json)});');
  }

  Future<void> setChapters(List<String> chapters) async {
    _pendingChapters = chapters;
    if (_ready) await _setContent(chapters);
  }

  /// 换主题 + 字号 + 行距 + 边距（三档主题由调用方换算成具体颜色）。
  Future<void> setTheme({
    required String background,
    required String foreground,
    double fontSize = 17,
    double lineHeight = 1.75,
    double margin = 20,
  }) async {
    if (_web == null || !_ready) return;
    final t = jsonEncode(jsonEncode({
      'bg': background,
      'fg': foreground,
      'fs': fontSize,
      'lh': lineHeight,
      'margin': margin,
    }));
    await _web!.runJavaScript('window.__reader.setTheme($t);');
  }

  Future<void> nextPage() async {
    if (_web == null || !_ready) return;
    await _web!.runJavaScript('window.__reader.next();');
  }

  Future<void> previousPage() async {
    if (_web == null || !_ready) return;
    await _web!.runJavaScript('window.__reader.prev();');
  }

  Future<String?> debugStatus() async {
    if (_web == null || !_ready) return null;
    return _web!.runJavaScriptReturningResult('window.__reader.status();')
        as String?;
  }

  void _onMessage(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['type']) {
        case 'ready':
          _ready = true;
          if (_pendingChapters.isNotEmpty) _setContent(_pendingChapters);
        case 'relocate':
          position.value = FoliatePosition(
            sectionIndex: (m['sec'] as num?)?.toInt() ?? 0,
            pageInSection: (m['page'] as num?)?.toInt() ?? 0,
            fraction: (m['fraction'] as num?)?.toDouble() ?? 0,
          );
        case 'select':
          selectedText.value = (m['text'] as String?)?.trim();
        case 'tap':
          tapTick.value = tapTick.value + 1;
        default:
          break;
      }
    } catch (e) {
      lastError.value = '桥消息解析失败：$e';
    }
  }
}

@immutable
class FoliatePosition {
  const FoliatePosition({
    this.sectionIndex = 0,
    this.pageInSection = 0,
    this.fraction = 0,
  });

  final int sectionIndex;
  final int pageInSection;
  final double fraction;

  @override
  String toString() => 'sec=$sectionIndex page=$pageInSection f=$fraction';
}

/// WebView 外壳 —— 只负责「装控件 + 连桥」，业务在 controller。
class FoliateReaderView extends StatefulWidget {
  const FoliateReaderView({
    super.key,
    required this.controller,
    this.onError,
  });

  final FoliateReaderController controller;

  /// 原生侧兜底（JS 没起来时至少能看到「为什么」）。
  final void Function(String message)? onError;

  @override
  State<FoliateReaderView> createState() => _FoliateReaderViewState();
}

class _FoliateReaderViewState extends State<FoliateReaderView> {
  WebViewController? _web;

  @override
  void initState() {
    super.initState();
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 🔑 必须设置背景色为透明 —— 否则默认白底会在主题切换瞬间闪一下。
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('CoEvoBridge', onMessageReceived: (m) {
        widget.controller._onMessage(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {},
        onWebResourceError: (e) {
          widget.onError?.call('WebView 错误：${e.description}');
        },
      ))
      ..loadFlutterAsset('assets/foliate/reader.html');

    widget.controller._attach(web);
    _web = web;
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    if (web == null) return const SizedBox.shrink();
    return WebViewWidget(controller: web);
  }
}
