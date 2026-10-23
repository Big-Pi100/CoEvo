import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// 「底层 WebView 宿主」的抽象 —— **两套实现**：
///
/// | 实现 | 用在哪 | 为什么 |
/// |---|---|---|
/// | [FlutterWebViewHost] | 非 iOS | 沿用 `webview_flutter`，零改动 |
/// | [NativeWebViewHost] | **iOS** | 走我们自绘的 `WKWebView` 子类（见 `ios/Runner/CoEvoWebView.swift`）|
///
/// # 🔴 为什么 iOS 必须自绘（2026-10-23）
///
/// iOS 长按选词会弹**系统菜单**（Copy / Look Up / Translate），盖住我们的菜单。
/// 它**无法用 JS 关**（不是 DOM 事件），只能用 `-webkit-user-select: none` ——
/// 但那会把「选择能力」一起废掉（划词就没了）。
/// 唯一正解是子类化 `WKWebView` + `buildMenu(with:)` 移除 `.standardEdit`，
/// 而 `webview_flutter` 4.14.1 是 Pigeon 架构（`WKWebView` 由 Dart 侧创建），
/// **Swift 侧没有可改的实例化点** ⇒ 只能自绘 PlatformView。
abstract class FoliateWebHost {
  Future<void> loadAsset(String relativePath);
  Future<void> runJavaScript(String js);
  Future<Object?> runJavaScriptReturning(String js);
}

/// 非 iOS：`webview_flutter` 的薄封装。
class FlutterWebViewHost implements FoliateWebHost {
  FlutterWebViewHost(this._c);
  final WebViewController _c;

  @override
  Future<void> loadAsset(String relativePath) =>
      _c.loadFlutterAsset(relativePath);

  @override
  Future<void> runJavaScript(String js) => _c.runJavaScript(js);

  @override
  Future<Object?> runJavaScriptReturning(String js) =>
      _c.runJavaScriptReturningResult(js);
}

/// iOS：自绘 `CoEvoWKWebView` 的通道封装（`ios/Runner/CoEvoWebView.swift`）。
class NativeWebViewHost implements FoliateWebHost {
  NativeWebViewHost(this._channel);
  final MethodChannel _channel;

  @override
  Future<void> loadAsset(String relativePath) =>
      _channel.invokeMethod<void>('loadAsset', {'path': relativePath});

  @override
  Future<void> runJavaScript(String js) =>
      _channel.invokeMethod<void>('runJavaScript', {'js': js});

  @override
  Future<Object?> runJavaScriptReturning(String js) =>
      _channel.invokeMethod<Object?>('runJavaScriptReturning', {'js': js});
}

class FoliateReaderController {
  FoliateWebHost? _web;

  final ValueNotifier<FoliatePosition> position =
      ValueNotifier(const FoliatePosition());
  final ValueNotifier<String?> selectedText = ValueNotifier<String?>(null);

  /// 🆕 2026-10-23：选区**文本 + 矩形**（矩形用于把菜单摆在选区上方）。
  ///
  /// ⚠️ 坐标是 **iframe 内的 CSS px**，不是屏幕坐标 —— 调用方要自己加上
  ///    WebView 在屏幕里的偏移（我们外层有 `Padding(top: safeArea.top)`）。
  final ValueNotifier<FoliateSelection?> selection =
      ValueNotifier<FoliateSelection?>(null);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 正文被**单击**了一次（用来切换顶栏/底栏）。
  /// 🔑 用递增计数而不是 bool：连续单击两次要能各自触发一次 toggle。
  final ValueNotifier<int> tapTick = ValueNotifier<int>(0);

  /// JS 侧「进行到哪一步」—— 白屏时看它就知道卡在哪（真机没有控制台）。
  final ValueNotifier<String> lastStage = ValueNotifier<String>('');

  /// 字体加载结果（`Literata=OK NotoCJK=OK count=5`）。
  /// 🔑 用 `font-display: swap` 时加载失败会**静默回退**，光看字形判断不了。
  final ValueNotifier<String> fontsStatus = ValueNotifier<String>('');

  bool _ready = false;
  List<String> _pendingChapters = const [];

  bool get isReady => _ready;

  void _attach(FoliateWebHost web) {
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
    final raw = await _web!.runJavaScriptReturning('window.__reader.status();');
    return raw as String?;
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
            charOffset: (m['offset'] as num?)?.toInt() ?? 0,
            totalChars: (m['total'] as num?)?.toInt() ?? 0,
          );
        case 'select':
          final text = (m['text'] as String?)?.trim();
          selectedText.value = text;
          if (text == null || text.isEmpty) {
            selection.value = null;
          } else {
            selection.value = FoliateSelection(
              text: text,
              x: (m['x'] as num?)?.toDouble() ?? 0,
              y: (m['y'] as num?)?.toDouble() ?? 0,
              w: (m['w'] as num?)?.toDouble() ?? 0,
              h: (m['h'] as num?)?.toDouble() ?? 0,
            );
          }
        case 'tap':
          tapTick.value = tapTick.value + 1;
        case 'error':
          // JS 侧自己 catch 到的错误（含阶段名）—— 直接显示出来，
          // 因为真机上没有控制台，`Script error.` 又是脱敏的。
          lastError.value = (m['detail'] as String?) ?? 'JS 未知错误';
        case 'stage':
          lastStage.value = (m['detail'] as String?) ?? '';
        case 'fonts':
          fontsStatus.value = (m['detail'] as String?) ?? '';
        default:
          break;
      }
    } catch (e) {
      lastError.value = '桥消息解析失败：$e';
    }
  }
}

/// 一次选词的结果（文本 + 在 iframe 里的矩形）。
@immutable
class FoliateSelection {
  const FoliateSelection({
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;

  @override
  String toString() => 'sel("$text" @$x,$y ${w}x$h)';
}

@immutable
class FoliatePosition {
  const FoliatePosition({
    this.sectionIndex = 0,
    this.pageInSection = 0,
    this.fraction = 0,
    this.charOffset = 0,
    this.totalChars = 0,
  });

  final int sectionIndex;
  final int pageInSection;
  final double fraction;

  /// 🆕 v6（2026-10-23）：**本章内的字符偏移**（正文纯文本，不含章节标题）。
  ///
  /// 🔑 这是翻页阅读器的**原生坐标** —— 每页起点本来就是一个字符位置。
  ///    比 `fraction`（页序号比例）精确：字号一变页数就变，`fraction` 会漂，
  ///    而字符偏移与字号无关。
  final int charOffset;

  /// 本章正文纯文本总长（与 [charOffset] 同口径），用来算章内百分比。
  final int totalChars;

  @override
  String toString() =>
      'sec=$sectionIndex page=$pageInSection f=$fraction off=$charOffset/$totalChars';
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

  bool get _useNative => !kIsWeb && Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (_useNative) {
      // iOS：什么都不做 —— 真正的实例在 `onPlatformViewCreated` 里拿到。
      // （PlatformView 由原生侧创建，Dart 只能等它的 viewId）
    } else {
      final web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..addJavaScriptChannel('CoEvoBridge', onMessageReceived: (m) {
          widget.controller._onMessage(m.message);
        })
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) => _bootstrap(),
          onWebResourceError: (e) {
            widget.onError?.call('WebView 错误：${e.description}');
          },
        ))
        ..loadFlutterAsset('assets/foliate/reader.html');

      widget.controller._attach(FlutterWebViewHost(web));
      _web = web;
    }
  }

  /// iOS 的 PlatformView 创建完成 → 建通道 → 绑消息 → 触发加载。
  Future<void> _onNativeViewCreated(int viewId) async {
    final ch = MethodChannel('coevo/webview/$viewId');
    ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'message':
          // 原生把 `CoEvoBridge.postMessage(body)` 的 body 原样转过来
          final body = call.arguments;
          widget.controller
              ._onMessage(body is String ? body : jsonEncode(body));
        case 'pageFinished':
          await _bootstrap();
        case 'error':
          widget.onError?.call('WebView 错误：${call.arguments}');
        default:
          break;
      }
      return null;
    });

    widget.controller._attach(NativeWebViewHost(ch));
    await ch.invokeMethod<void>(
        'loadAsset', {'path': 'assets/foliate/reader.html'});
  }

  /// 页面加载完后**主动轮询**，直到 `window.__reader` 就绪，再把内容推下去。
  ///
  /// 🔑 为什么不「等 JS 发 ready」：那条路依赖 `CoEvoBridge` 注入成功；
  ///    真机曾出现「页面能渲染但 bridge 从没通」⇒ `ready` 永远发不出去 ⇒ 白屏且无提示。
  ///    轮询是**原生发起的**，不依赖任何 JS→原生的通道。
  Future<void> _bootstrap() async {
    final host = widget.controller._web;
    if (host == null) return;
    for (var i = 0; i < 40; i++) {
      try {
        final raw = await host
            .runJavaScriptReturning('window.__bridgePing ? window.__bridgePing() : ""');
        final txt = raw.toString();
        if (txt.contains('"hasReader":true')) {
          widget.controller._ready = true;
          final pending = widget.controller._pendingChapters;
          if (pending.isNotEmpty) {
            await widget.controller._setContent(pending);
          }
          return;
        }
      } catch (_) {
        // 还没加载好 —— 继续等（不打断）
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    widget.onError?.call('阅读器初始化超时：window.__reader 未就绪');
  }

  @override
  Widget build(BuildContext context) {
    if (_useNative) {
      return UiKitView(
        viewType: 'coevo/foliate',
        onPlatformViewCreated: _onNativeViewCreated,
        creationParams: const <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    final web = _web;
    if (web == null) return const SizedBox.shrink();
    return WebViewWidget(controller: web);
  }
}
