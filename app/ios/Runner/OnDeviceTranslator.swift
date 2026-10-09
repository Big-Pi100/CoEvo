import Flutter
import SwiftUI
import Translation
import UIKit

/// 端侧翻译桥 —— iOS 18+ 的 `Translation.framework`。
///
/// # 🔴 为什么要「贴一个不可见视图」这种绕法
///
/// `TranslationSession` 在 **iOS 18–25 上无法在无 UI 的场景构造**：
/// 官方的无界面初始化子 `TranslationSession(installedSource:target:)`
/// **要到 iOS 26 才有**。
///
/// iOS 18–25 唯一可用的入口是 SwiftUI 的 `.translationTask` 修饰符 ——
/// 它把 session 交给闭包。⇒ 所以这里临时贴一个 **1×1 的 SwiftUI 视图**、
/// 从它的 `.translationTask` 取 session，用完**立刻移除**。
///
/// 📌 Apple 工程师在开发者论坛明确推荐过「用 `UIHostingController` 承载 SwiftUI
///    来在 UIKit 应用里用 Translation API」⇒ 这不是私有手段，是官方认可的路径。
///
/// # ⚠️ 模拟器不支持
/// `Translation` 框架在模拟器上**不工作** ⇒ 本文件只能**真机验证**。
///
/// # 🔑 失败一律回 `nil`，绝不抛给 Dart
/// 端侧翻译是**加速层**：它失败的正确反应是「回落服务端」，不是「让翻译不可用」。
/// ⇒ 所有错误路径都收敛成 `result(nil)`，由 Dart 侧决定回落。
///
/// ⚠️ 整个类标 `@available(iOS 18.0, *)` —— 它内部的 `Box` 引用了
///    `TranslationSession.Configuration`（iOS 18+），不给类加标注是**编译不过**的。
@available(iOS 18.0, *)
final class OnDeviceTranslator {

    /// 单例（通道处理器只需要一个实例）。
    static let shared = OnDeviceTranslator()

    /// 与 Dart 侧 `OnDeviceTranslateClient.channelName` **必须一致**。
    static let channelName = "coevo/ondevice_translate"

    enum TranslatorError: Error {
        case busy
        case noWindow
    }

    private init() {}

    /// SwiftUI 状态盒：用它驱动 `.translationTask(configuration:)`。
    ///
    /// 🔑 `@Published` 的 `configuration` 变化 ⇒ SwiftUI 重新求值该修饰符 ⇒
    ///    触发 `action`。这是「让 UIKit 侧主动发起一次翻译」的唯一手动开关。
    private final class Box: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        var action: ((TranslationSession) async -> Void)?
    }

    private var host: UIHostingController<AnyView>?
    private var box: Box?
    private var pending: ((Result<[String], Error>) -> Void)?
    /// 串行化：同一时刻只挂一个不可见视图（并发挂多个会互相干扰）。
    private var inFlight = false

    // ══════════════════════════════════════════════════════════════
    // 可用性
    // ══════════════════════════════════════════════════════════════

    /// 查语言对状态：`installed` / `supported` / `unsupported`。
    ///
    /// 🔑 与 Dart 侧 `OnDeviceTranslateStatus` 的字符串**逐字对应**。
    @available(iOS 18.0, *)
    func status(source: String, target: String) async -> String {
        let availability = LanguageAvailability()
        let s = await availability.status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch s {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unavailable"
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 批量翻译
    // ══════════════════════════════════════════════════════════════

    /// 批量翻译，**保持与入参同序**。
    ///
    /// ⚠️ 用 `translations(from:)` 而**不是** `translate(batch:)`：
    ///    前者**保序**、一次性返回；后者是流式（`AsyncSequence`）且**不保序**，
    ///    需要自己用 `clientIdentifier` 配对。保序对我们更省事也更安全
    ///    （错位会把译文贴到别的句子上 —— 比失败更糟）。
    @available(iOS 18.0, *)
    func translate(
        _ texts: [String],
        source: String,
        target: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !inFlight else {
            completion(.failure(TranslatorError.busy))
            return
        }
        guard !texts.isEmpty else {
            completion(.success([]))
            return
        }
        guard let window = Self.hostWindow() else {
            completion(.failure(TranslatorError.noWindow))
            return
        }

        inFlight = true
        pending = completion

        let box = Box()
        box.action = { [weak self] session in
            do {
                let requests = texts.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)
                self?.finish(.success(responses.map { $0.targetText }))
            } catch {
                self?.finish(.failure(error))
            }
        }
        self.box = box

        // 1×1 的不可见宿主视图
        let root = Color.clear
            .frame(width: 1, height: 1)
            .translationTask(box.configuration) { session in
                await box.action?(session)
            }
        let controller = UIHostingController(rootView: AnyView(root))
        controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        // 🔴 不能用 alpha = 0：完全透明的视图可能不被渲染 ⇒ `.translationTask` 永远不触发
        //    （踩点：这类「不报错、只是什么都不发生」的坑最难查。）
        controller.view.alpha = 0.01
        controller.view.isUserInteractionEnabled = false
        window.addSubview(controller.view)
        host = controller

        // 触发一次
        var cfg = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        // 🔑 `invalidate()`：让「与上次相同的语言对」也能**重新触发**闭包。
        //    没有它，第二次翻译同样的语言对时 SwiftUI 认为配置没变 ⇒ 不执行 ⇒ 永远没有回调。
        cfg.invalidate()
        box.configuration = cfg
    }

    /// 收尾（**必须**：移除视图 + 复位状态，否则下一次 translate 会被 busy 挡住）。
    @available(iOS 18.0, *)
    private func finish(_ result: Result<[String], Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.host?.view.removeFromSuperview()
            self.host = nil
            self.box = nil
            self.inFlight = false
            let cb = self.pending
            self.pending = nil
            cb?(result)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 通道
    // ══════════════════════════════════════════════════════════════

    /// 处理 Dart 侧的方法调用。
    ///
    /// ⚠️ 本方法**只在 iOS 18+ 注册**（见 `AppDelegate.setupTranslateChannel`）——
    ///    iOS 18 以下 Dart 侧会收到 `MissingPluginException`，
    ///    而 Dart 侧把它吞成 `unavailable` ⇒ 走服务端回落。**这是预期行为**。
    @available(iOS 18.0, *)
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        let source = (args["source"] as? String) ?? "en"
        let target = (args["target"] as? String) ?? "zh-Hans"

        switch call.method {
        case "status":
            Task {
                let s = await self.status(source: source, target: target)
                DispatchQueue.main.async { result(s) }
            }

        case "translate":
            guard let texts = args["texts"] as? [String] else {
                result(FlutterError(code: "bad_args",
                                    message: "texts 缺失或不是字符串数组",
                                    details: nil))
                return
            }
            self.translate(texts, source: source, target: target) { r in
                switch r {
                case .success(let out):
                    result(out)
                case .failure:
                    // 🔑 一切失败都回 `nil` ⇒ Dart 侧回落服务端（见文件头）
                    result(nil)
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 找一个可以挂宿主视图的 window（`UIApplication.shared.keyWindow` 自 iOS 13 起废弃）。
    private static func hostWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = ws.windows.first { return first }
        }
        return nil
    }
}
