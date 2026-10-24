import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
/// \`flutter_inappwebview\` 的薄封装 —— 只包我们真正用到的 3 个能力。
///
/// # 🔑 为什么从 \`webview_flutter\` 换到它（2026-10-23）
///
/// 需求：**长按选词时不要出现 iOS 的系统编辑菜单**（Copy / Look Up / Translate），
/// 只留我们自己的「查词 / 复制 / 划线 / 翻译」。
///
/// 那个菜单**只能用子类化 \`WKWebView\` + 重写 \`buildMenu(with:)\` 去掉**
/// （\`contextmenu\` 事件无效；\`-webkit-user-select: none\` 会连选择一起废掉）。
/// \`webview_flutter\` 4.14.1 是 Pigeon 架构，\`WKWebView\` 由 Dart 侧创建，
/// **Swift 侧没有子类化入口** ⇒ 自绘 PlatformView 的路走了 5 次 CI 未能定位失败，已回滚。
///
/// \`flutter_inappwebview\` 有现成开关，且 **pub.dev 明确标注 iOS 为官方支持平台**：
/// \`\`\`dart
/// InAppWebViewSettings(disableContextMenu: true)
/// \`\`\`
/// ⇒ 一行配置，不写任何原生代码。
class InAppWebViewHost implements FoliateWebHost {
  InAppWebViewHost(this._c);
  final InAppWebViewController _c;

  @override
  Future<void> loadAsset(String relativePath) =>
      _c.loadFile(assetFilePath: relativePath);

  @override
  Future<void> runJavaScript(String js) => _c.evaluateJavascript(source: js);

  @override
  Future<Object?> runJavaScriptReturning(String js) =>
      _c.evaluateJavascript(source: js);
}

/// 底层 WebView 的能力接口（只有一个实现，但留着是为了**不把包的类型泄漏到 controller**——
/// 将来若再换包，只改这一层）。
abstract class FoliateWebHost {
  Future<void> loadAsset(String relativePath);
  Future<void> runJavaScript(String js);
  Future<Object?> runJavaScriptReturning(String js);
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

  /// 下拉的**实时进度**（0~1）—— 供页面做「跟手位移 + 转圈」。
  ///
  /// 🆕 2026-10-24 白哥：「为什么不学『今日精选』那种下拉动画？一个拉动加转圈」。
  /// 光发「触发了一次」不够 —— 没有过程就没有「拉动」的手感。
  final ValueNotifier<double?> pullRatio = ValueNotifier<double?>(null);

  /// 下拉松手**次数**（每松手一次 +1）。
  ///
  /// 🔴🔴 2026-10-24 白哥：「连续多次下拉，收藏功能就会失效（没有振动、图标不亮）」。
  ///
  /// 根因：原来这里是 `ValueNotifier<bool?>` —— **值不变就不通知**。
  ///   第一次达标设 `true` ⇒ 通知；第二次达标**还是 `true`** ⇒ `ValueNotifier` 认为
  ///   「没变化」⇒ **不触发 listener** ⇒ 不回弹、不震动、不加书签。
  ///
  /// ⇒ 改成**计数器**：每松手一次递增，值永远在变。
  ///   （同样的坑在 `tapTick` / `pullDownTick` 上已经用对了，这里漏了。）
  ///
  /// ⚠️ 教训：**事件型通知一律用计数器，不要用"状态值"**。
  ///    状态值只在一个方向上变化（false→true）时，第二次同向事件必然丢失。
  final ValueNotifier<int> pullEndTick = ValueNotifier<int>(0);

  /// 最近一次松手是否**达到阈值**（配 `pullEndTick` 用 —— tick 只负责「通知」，
  /// 这个字段负责「内容」，两者分开才能既通知到又带上语义）。
  bool pullEndArmed = false;

  /// 用户在正文上**竖直下拉**了一次（🆕 2026-10-24 白哥定：下拉 = 打/取消书签）。
  ///
  /// 🔑 为什么是「计数」而不是「事件回调」：
  ///    和 `tapTick` 同一个模式 —— 控制器不持有业务逻辑，
  ///    由页面 `addListener` 决定「下拉了要做什么」。这样换页面不用改这里。
  final ValueNotifier<int> pullDownTick = ValueNotifier<int>(0);

  /// JS 侧「进行到哪一步」—— 白屏时看它就知道卡在哪（真机没有控制台）。
  final ValueNotifier<String> lastStage = ValueNotifier<String>('');

  /// 字体加载结果（`Literata=OK NotoCJK=OK count=5`）。
  /// 🔑 用 `font-display: swap` 时加载失败会**静默回退**，光看字形判断不了。
  final ValueNotifier<String> fontsStatus = ValueNotifier<String>('');

  bool _ready = false;
  List<String> _pendingChapters = const [];

  /// 内容就绪后要跳到的**章节下标**（0 = 从头）。
  int _pendingStartAt = 0;

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

  /// 把**整本书的章节**交给分页器。
  ///
  /// # 🔴 为什么必须一次传全（2026-10-23 白哥报「章末翻不动 + 满屏红字」）
  ///
  /// foliate 把 `sections` 当**定长数组**：翻到末页再往后它会取 `sections[N+1]`。
  /// 只传当前一章 ⇒ `sections[1]` 是 `undefined` ⇒
  /// `Promise: undefined is not an object (evaluating 'this.sections[index].load')`
  /// ⇒ 翻页卡住 + 报错刷屏。
  ///
  /// `sections[i].load` 由 foliate **懒调用**（翻到才建 iframe），
  /// 所以预生成 N 个 HTML 只是内存里存字符串，不会一次性渲染。
  ///
  /// [startAt] 是**章节下标**（不是页码）。
  Future<void> setChapters(List<String> chapters, {int startAt = 0}) async {
    _pendingChapters = chapters;
    _pendingStartAt = startAt;
    if (_ready) {
      await _setContent(chapters);
      if (startAt > 0) await goToChapter(startAt);
    }
  }

  /// 跳到指定章节 —— 所有章节都已在分页器里，**不需要重灌内容**。
  Future<void> goToChapter(int index) async {
    if (_web == null || !_ready) return;
    await _web!.runJavaScript('window.__reader.goTo($index);');
  }

  /// 跳到「第 `index` 章的 `ratio` 位置」（ratio = **章内**比例 0~1）。
  ///
  /// 🆕 书签跳转用：`book_marker.scroll_ratio` 是章内比例，
  /// 而 `goToChapter` 只能到章首 ⇒ 要这个才能落到具体位置。
  Future<void> goToChapterRatio(int index, double ratio) async {
    if (_web == null || !_ready) return;
    final r = ratio.clamp(0.0, 1.0);
    await _web!.runJavaScript('window.__reader.goToAt($index, $r);');
  }

  /// 换主题 + 字号 + 行距 + 边距（三档主题由调用方换算成具体颜色）。
  Future<void> setTheme({
    required String background,
    required String foreground,
    /// 🆕 2026-10-23：链接色（朱砂）。正式页的链接就是朱砂 + 下划线，
    /// 不传的话 WebView 会用浏览器默认蓝色 —— 一眼就能看出是「另一套排版」。
    String accent = '#B4432C',
    double fontSize = 17,
    double lineHeight = 1.75,
    /// 🔴 边距必须与正式页一致：`CoSpacing.xxl = 24`（原来我写的 20 是猜的）
    double margin = 24,
  }) async {
    if (_web == null || !_ready) return;
    final t = jsonEncode(jsonEncode({
      'bg': background,
      'fg': foreground,
      'accent': accent,
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
        case 'pullProgress':
          pullRatio.value = (m['ratio'] as num?)?.toDouble() ?? 0;
        case 'pullEnd':
          // 🔑 先写「内容」再递增 tick —— 顺序反了 listener 会读到上一次的值
          pullEndArmed = ((m['dy'] as num?)?.toDouble() ?? 0) >= 60;
          pullEndTick.value = pullEndTick.value + 1;
          // ⚠️ **不在这里把 pullRatio 置 null** ——
          //    归零由页面在「转圈收尾」之后自己做（白哥要看到达标后的那一小段转圈）。
          //    这里若立即置 null，位移会瞬间归零 ⇒ 转圈收尾一闪而过。
          //    `pullCancel`（横滑放弃）才需要立即归零。
        case 'pullCancel':
          pullRatio.value = null;
        case 'pullDown':
          pullDownTick.value = pullDownTick.value + 1;
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
  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      // 🔑 `initialFile` 直接吃 pubspec 里声明的 asset 路径。
      //    它的 base URL 是 `.../flutter_assets/assets/foliate/reader.html`
      //    ⇒ `reader.html` 里 `../fonts/*.ttf` 的相对路径可用（同源）。
      initialFile: 'assets/foliate/reader.html',
      initialSettings: InAppWebViewSettings(
        // 🔴🔴 **这一行就是整个换包的目的**：去掉 iOS 长按的系统编辑菜单
        //    （Copy / Look Up / Translate）。pub.dev 标注 iOS 为官方支持平台。
        disableContextMenu: true,
        // 但不能连「选词」一起关 —— 划词是核心功能
        isTextInteractionEnabled: true,
        javaScriptEnabled: true,
        transparentBackground: true,
        allowsLinkPreview: false,
        supportZoom: false,
        // 阅读器自己管翻页，不要 WebView 的滚动
        disableVerticalScroll: true,
        disableHorizontalScroll: true,
      ),
      onWebViewCreated: (c) {
        c.addJavaScriptHandler(
          handlerName: 'CoEvoBridge',
          callback: (args) {
            if (args.isEmpty) return null;
            final body = args.first;
            widget.controller
                ._onMessage(body is String ? body : jsonEncode(body));
            return null;
          },
        );
        widget.controller._attach(InAppWebViewHost(c));
      },
      onLoadStop: (_, __) => _bootstrap(),
      onReceivedError: (_, __, error) {
        widget.onError?.call('WebView 错误：${error.description}');
      },
    );
  }

  /// 页面加载完后**主动轮询**，直到 `window.__reader` 就绪，再把内容推下去。
  ///
  /// 🔑 为什么不「等 JS 发 ready」：那条路依赖 JS→原生通道（`callHandler`）建好；
  ///    真机曾出现「页面能渲染但通道从没通」⇒ 白屏且没有任何可观察的异常。
  ///    轮询是**原生发起的**，不依赖任何 JS→原生的通道。
  Future<void> _bootstrap() async {
    final host = widget.controller._web;
    if (host == null) return;
    for (var i = 0; i < 40; i++) {
      try {
        final raw = await host.runJavaScriptReturning(
            'window.__bridgePing ? window.__bridgePing() : ""');
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
}
