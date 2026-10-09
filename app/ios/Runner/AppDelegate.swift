import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// Dart 侧对应的 MethodChannel 名称（见 `lib/services/open_with_handler.dart`）
  private static let channelName = "coevo/open_with"

  private var channel: FlutterMethodChannel?

  /// 🆕 端侧翻译通道（iOS 18+ 才注册，见 `setupTranslateChannel`）
  private var translateChannel: FlutterMethodChannel?

  /// 待处理的外部文件 URL。
  /// 采用「缓存 + 信号」模型：Swift 只负责攒着，由 Dart 侧主动拉取（pull），
  /// 避免冷启动时 Flutter engine 尚未就绪导致推送丢失。
  private var pendingURLs: [URL] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    setupChannel()
    setupTranslateChannel()

    // 冷启动：文件随 launchOptions 传入（此时 engine 未就绪，只缓存）
    if let url = launchOptions?[.url] as? URL {
      enqueue(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // 兜底：首次可能因 window 未就绪而建失败
    setupChannel()
    setupTranslateChannel()
    super.applicationDidBecomeActive(application)
  }

  /// 热启动：App 已在运行时从「文件」等 App 以「用 CoEvo 打开」传入文件。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    enqueue(url)
    // 仅作唤醒信号，不带数据 —— Dart 侧收到后统一走 pull，避免重复
    channel?.invokeMethod("onFileAvailable", arguments: nil)
    return super.application(app, open: url, options: options)
  }

  private func setupChannel() {
    guard channel == nil,
          let controller = window?.rootViewController as? FlutterViewController else { return }

    let ch = FlutterMethodChannel(name: AppDelegate.channelName,
                                  binaryMessenger: controller.binaryMessenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result([])
        return
      }
      switch call.method {
      case "getPendingFiles":
        // 取出即清空，保证同一个文件不会被处理两次
        let paths = self.pendingURLs.map { $0.path }
        self.pendingURLs.removeAll()
        result(paths)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  private func enqueue(_ url: URL) {
    guard !pendingURLs.contains(url) else { return }
    pendingURLs.append(url)
  }

  /// 🆕 端侧翻译通道（iOS 18+ 的 `Translation.framework`）。
  ///
  /// # 🔴 **只在 iOS 18+ 注册** —— 这是**有意**的
  /// iOS 18 以下不注册 ⇒ Dart 侧调 `status`/`translate` 会收到
  /// `MissingPluginException`，而 Dart 侧把它吞成 `unavailable`
  /// ⇒ 自动回落服务端 LLM。**这就是「老机型功能不缺失」的实现方式**，
  /// 不是漏配。
  ///
  /// ⚠️ 与 `setupChannel()` 一样在「冷启动 + becomeActive」两处调用：
  ///    首次可能因 window 尚未就绪而失败。
  private func setupTranslateChannel() {
    guard #available(iOS 18.0, *) else { return }
    guard translateChannel == nil,
          let controller = window?.rootViewController as? FlutterViewController else { return }

    let ch = FlutterMethodChannel(name: OnDeviceTranslator.channelName,
                                  binaryMessenger: controller.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      OnDeviceTranslator.shared.handle(call, result: result)
    }
    translateChannel = ch
  }
}
