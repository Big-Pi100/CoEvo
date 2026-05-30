/// CoEvo API Configuration
///
/// ## 本地测试
/// ```bash
/// # Android 模拟器 (默认 localhost:8080)
/// flutter run
///
/// # 真机调试 (用电脑局域网 IP)
/// flutter run --dart-define=API_HOST=192.168.1.100 --dart-define=API_PORT=8080
/// ```
///
/// ## VPS 部署（IP 直连）
/// ```bash
/// flutter build web --dart-define=API_HOST=<OLD_VPS_IP> --dart-define=API_PORT=8080
/// ```
///
/// ## 正式域名部署
/// ```bash
/// flutter build web --dart-define=API_HOST=keyievolution.fun
/// ```
class ApiConfig {
  /// API 服务器地址 — 通过 `--dart-define` 在编译时注入
  ///
  /// 默认: http://localhost:8080（本地开发）
  static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
  static const String _port = String.fromEnvironment('API_PORT', defaultValue: '8080');

  /// HTTP base URL (REST + WebSocket 共用)
  ///
  /// 自动判断：
  /// - 如果 _host 包含点号（域名），使用 https:// 且不追加端口（443 默认）
  /// - 否则（localhost 或 IP），使用 http:// 并追加 _port
  static String get baseUrl {
    if (_host.contains('.')) {
      // 域名 → HTTPS, 默认端口 443
      return 'https://$_host';
    }
    // IP 或 localhost → HTTP + 端口
    return 'http://$_host:$_port';
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
