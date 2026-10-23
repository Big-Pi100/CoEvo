import Flutter
import UIKit
import WebKit

/// 项目自绘的 WKWebView —— **唯一目的：去掉 iOS 的系统编辑菜单**。
///
/// # 为什么必须自绘（2026-10-23）
///
/// 长按选词时 iOS 会弹系统菜单（Copy / Look Up / Translate），盖住了我们自己的
/// `SelectionMenu`（查词 / 复制 / 划线 / 翻译）。白哥要求「只要我们的菜单」。
///
/// 系统菜单**无法用 JS 关闭**：
/// * `contextmenu` 事件对它无效（它是系统原生 UI，不是 DOM 事件）
/// * `-webkit-user-select: none` 能关，但**连选择能力一起废掉**（划词就没了）
///
/// 官方做法是**子类化 `WKWebView` 并重写 `buildMenu(with:)`**：
/// ```swift
/// builder.remove(menu: .standardEdit)   // Copy / Look Up / Translate 都在这一组
/// ```
/// 但 `webview_flutter` 4.14.1 是 Pigeon 架构（`WKWebView` 由 Dart 侧 `alloc/init` 创建），
/// **Swift 侧没有可改的实例化点** ⇒ 只能自己写一个 PlatformView。
///
/// # 与 `webview_flutter` 的差异（只实现我们真正用到的能力）
///
/// | 能力 | 这里 | 说明 |
/// |---|---|---|
/// | 加载 assets 里的 html | `loadFileURL` + 目录授权 | 🔑 **同源**，字体相对路径可用 |
/// | JS → 原生 | `WKScriptMessageHandler` | 通道名 `CoEvoBridge`（与旧实现同名，JS 不用改） |
/// | 原生 → JS | `evaluateJavaScript` | 支持返回值 |
/// | 页面加载完成 | `didFinish` → 回调 Dart | 替代 `onPageFinished` |
///
/// ⚠️ **不用 `loadHTMLString`**：那会得到 opaque origin ⇒ 字体/相对路径全废
///    （这正是 10-23 当天排查了很久的那个坑）。
final class CoEvoWKWebView: WKWebView {
  /// 系统菜单里要去掉的分组。
  ///
  /// 🔑 `.standardEdit` 是 Copy / Look Up / Translate 所在组；
  ///    `.share` 是 iOS 18 上「拷贝高亮标记的链接」那一项。
  ///    见 CSDN / StackOverflow 上对 `buildMenu(with:)` 的实测（2023–2024 多篇一致）。
  // 🔴🔴 **不要加 `@available` 标注**（2026-10-23 踩了，CI 报
  //    "Overriding 'buildMenu' must be as available as declaration it overrides"）。
  //
  // `UIResponder.buildMenu(with:)` 与 `UIMenuBuilder` 都是 **iOS 13+**，
  // 我们的 deployment target 也是 13 ⇒ 直接 `override` 即可。
  // 加 `@available(iOS 14)` 反而比父类**更窄**，Swift 不允许。
  //
  // ⚠️ 更阴的是：**这个错误被 flutter 的 `Failed to build iOS app` 摘要盖住了**，
  //    外层只显示「需要 Development Team」那种误导性文案，
  //    真正的 `Swift Compiler Error` 在日志里靠前几行。**查构建失败要往下翻原始错误**。
  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    builder.remove(menu: .standardEdit)
    builder.remove(menu: .share)
  }
}

/// PlatformView 工厂 —— 给 Dart 侧 `UiKitView(viewType: 'coevo/foliate')` 用。
final class CoEvoWebViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    CoEvoWebViewPlatformView(
      frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

/// 一个 PlatformView = 一个 `CoEvoWKWebView` + 一条与 Dart 通信的 channel。
final class CoEvoWebViewPlatformView: NSObject, FlutterPlatformView,
  WKScriptMessageHandler, WKNavigationDelegate
{
  private let webView: CoEvoWKWebView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    let config = WKWebViewConfiguration()
    // 🔴 **不要**设 `allowFileAccessFromFileURLs` / `allowUniversalAccessFromFileURLs` ——
    //    那两个是 **macOS** 的 WKPreferences 键，iOS 上不存在：
    //    用 KVC 硬设会（a）无效或崩，（b）属于**私有 API**，审核有风险。
    //    iOS 上要读同目录资源，靠的是 `loadFileURL(_:allowingReadAccessTo:)` 的目录授权
    //    （见 `loadAsset`），不需要任何偏好开关。

    webView = CoEvoWKWebView(frame: frame, configuration: config)
    channel = FlutterMethodChannel(
      name: "coevo/webview/\(viewId)", binaryMessenger: messenger)

    super.init()

    webView.navigationDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    // 关掉长按预览与滚动回弹（阅读器不需要）
    webView.allowsLinkPreview = false

    // JS → 原生：通道名与旧实现（`webview_flutter` 的 `addJavaScriptChannel`）**同名**，
    // 这样 `reader.html` 里的 `CoEvoBridge.postMessage(...)` 一个字都不用改。
    let controller = webView.configuration.userContentController
    controller.add(self, name: "CoEvoBridge")

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "gone", message: "view disposed", details: nil))
        return
      }
      switch call.method {
      case "loadAsset":
        let rel = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        self.loadAsset(relativePath: rel, result: result)
      case "runJavaScript":
        let js = (call.arguments as? [String: Any])?["js"] as? String ?? ""
        self.webView.evaluateJavaScript(js) { value, error in
          if let error {
            result(FlutterError(code: "js", message: error.localizedDescription, details: nil))
          } else {
            result(value)
          }
        }
      case "runJavaScriptReturning":
        // 与上面同一个实现（`evaluateJavaScript` 本来就带返回值）；
        // 分开只是为了 Dart 侧语义清楚。
        let js = (call.arguments as? [String: Any])?["js"] as? String ?? ""
        self.webView.evaluateJavaScript(js) { value, error in
          if let error {
            result(FlutterError(code: "js", message: error.localizedDescription, details: nil))
          } else {
            result(value)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func view() -> UIView { webView }

  /// 加载 `flutter_assets` 里的页面。
  ///
  /// 🔴 **用 `loadFileURL` 而不是 `loadHTMLString`**：
  /// 后者会给页面一个 **opaque origin** ⇒ `@font-face` 的相对路径、
  /// 以及 iframe 里的同源判断全部失效（10-23 当天为此排查了很久）。
  /// `loadFileURL` + `allowingReadAccessTo` 让整棵 assets 目录可读 ⇒ **同源**。
  private func loadAsset(relativePath: String, result: @escaping FlutterResult) {
    guard let resourcePath = Bundle.main.resourcePath else {
      result(FlutterError(code: "no_assets", message: "resourcePath unavailable", details: nil))
      return
    }
    let assetsRoot = URL(fileURLWithPath: resourcePath).appendingPathComponent("flutter_assets")
    let fileURL = assetsRoot.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      result(
        FlutterError(
          code: "missing", message: "asset not found: \(fileURL.path)", details: nil))
      return
    }
    webView.loadFileURL(fileURL, allowingReadAccessTo: assetsRoot)
    result(nil)
  }

  // ── WKScriptMessageHandler ──────────────────────────────────────────
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    channel.invokeMethod("message", arguments: message.body)
  }

  // ── WKNavigationDelegate ────────────────────────────────────────────
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    channel.invokeMethod("pageFinished", arguments: nil)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    channel.invokeMethod("error", arguments: error.localizedDescription)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    channel.invokeMethod("error", arguments: error.localizedDescription)
  }
}
