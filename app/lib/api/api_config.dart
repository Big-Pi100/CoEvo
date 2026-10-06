/// CoEvo API Configuration
///
/// 🔑 **平台定位**（先说清，避免被误解为矛盾）：
/// · **iOS = 产品形态**（仅 iOS 分发，不做 Web / 不做 Android 分发）
/// · **Android = 真机验证的载体**（本机无 Mac ⇒ 出不了 iOS 包，
///   所以「构建 APK → 装到 Android 手机」是**唯一**能上真机的方式）
///
/// ## 本机调试（模拟器，后端也跑在本机）
/// ```bash
/// flutter run            # 默认 host=localhost / port=8080
/// ```
///
/// ## 真机调试（连**开发机**上的后端）
/// ```bash
/// # 真机访问不到 localhost → 必须换成开发机的局域网 IP
/// flutter run --dart-define=API_HOST=192.168.1.100 --dart-define=API_PORT=8080
/// ```
///
/// ## 🔴 真机连**生产后端**（2026-10-02 起 api 子域已上线）
/// ```bash
/// flutter run --dart-define=API_HOST=api.keyievolution.fun
/// # ⚠️ 不注入就默认 localhost:8080 → 表现为「首页空 / 划词提示连不上服务」
/// ```
///
/// ## 🔴 出包命令（**改这里要同步** `docs/review/a2-device-verification-checklist-2026-10-02.md` §〇）
///
/// ### Android —— 真机验证用（**日常实际跑的是这条**）
/// ```bat
/// cd E:\CoEvo\app
/// :: 🔴 必须【全路径】—— 裸调 flutter 会解析到 D:\flutter_flutter（鸿蒙分支 3.27.5）
/// ::    → 症状：BUILD FAILED in 59s（2026-09-29 实测踩过）
/// :: 🔴 必须加 --dart-define —— 否则默认 localhost:8080 ⇒ 真机连不上后端
/// :: --target-platform android-arm64 → 只打 arm64（真机架构）→ 体积 82.6 → 43.9 MB
/// D:\flutter\bin\flutter.bat build apk --release ^
///   --target-platform android-arm64 ^
///   --dart-define=API_HOST=api.keyievolution.fun
/// ```
/// 产物 `app\build\app\outputs\flutter-apk\app-release.apk` → **装到 Android 手机**。
/// · 若报 `ProcessException: 231`（Dart 创建不了子进程）→ 追加 `--no-version-check`
///   （⚠️ 实测**只能绕过其中一步** —— 在 **AI 沙箱终端**里仍不可用；
///    **普通终端（白哥的）不需要它**。📌 注意措辞：是「**我的执行环境**跑不了」，
///    不是「本机跑不了」—— 后者会被误读成「这台机器不能构建」）
/// · 要验「分享 / 二维码」再加 `--dart-define=PUBLIC_BASE_URL=https://keyievolution.fun`
///   （不加则指向 `http://localhost:3000`）
///
/// ### iOS —— 正式发布
/// ```bash
/// flutter build ipa \
///   --dart-define=API_HOST=api.keyievolution.fun \
///   --dart-define=PUBLIC_BASE_URL=https://keyievolution.fun
/// ```
///
/// 📄 完整验证流程与「为什么这么定」见
/// [`docs/review/a2-device-verification-checklist-2026-10-02.md`](../../../docs/review/a2-device-verification-checklist-2026-10-02.md) §〇
///
/// ⚠️ 历史残留（**已作废**，勿再照抄）：本文件曾写着 `flutter build web`
/// 与 IP 直连 `<OLD_VPS_IP>` —— 那是「Web + IP 直连」时代的写法，
/// 与「仅 iOS」「走 api 子域 + TLS」的现状矛盾。
class ApiConfig {
  /// API 服务器地址 — 通过 `--dart-define` 在编译时注入
  ///
  /// 默认: http://localhost:8080（本地开发）
  static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
  static const String _port = String.fromEnvironment('API_PORT', defaultValue: '8080');

  /// 前端公开域名（分享链接、二维码指向的地址）
  ///
  /// 通过 `--dart-define=PUBLIC_BASE_URL=xxx` 注入。
  ///
  /// ⚠️ 它**不是** API 地址（那是 [baseUrl]）—— 两者刻意分开：
  /// API 走 `api.keyievolution.fun`，而对用户可见的分享链接走主域。
  static const String publicBaseUrl = String.fromEnvironment(
      'PUBLIC_BASE_URL', defaultValue: 'http://localhost:3000');

  /// HTTP base URL (REST + WebSocket 共用)
  ///
  /// 自动判断：
  /// - 域名（如 keyievolution.fun）→ https://，不追加端口（443 默认）
  /// - IP 或 localhost → http://，追加 _port
  static String get baseUrl {
    if (_isDomain(_host)) {
      return 'https://$_host';
    }
    return 'http://$_host:$_port';
  }

  /// 判断是否为域名（含点号但非纯数字 IP）
  static bool _isDomain(String host) {
    if (!host.contains('.')) return false;
    return !RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
  }

  /// Request timeout for normal API calls
  static const Duration requestTimeout = Duration(seconds: 10);

  /// Timeout for long-running operations (LLM streaming)
  static const Duration longTimeout = Duration(seconds: 60);

  /// HTTP headers for JSON APIs
  static Map<String, String> headers({String? token}) => {
    'Content-Type': 'application/json',
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
}
