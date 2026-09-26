import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  /// Dart 侧对应的 MethodChannel 名称（见 `lib/services/open_with_handler.dart`）
  private static let channelName = "coevo/open_with"

  private var channel: FlutterMethodChannel?

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

    // 冷启动：文件随 launchOptions 传入（此时 engine 未就绪，只缓存）
    if let url = launchOptions?[.url] as? URL {
      enqueue(url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // 兜底：首次可能因 window 未就绪而建失败
    setupChannel()
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
}
