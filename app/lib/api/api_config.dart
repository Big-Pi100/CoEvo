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
/// ## VPS 部署
/// ```bash
/// flutter build apk --dart-define=API_HOST=<OLD_VPS_IP> --dart-define=API_PORT=8080
/// ```
class ApiConfig {
  /// API 服务器地址 — 通过 `--dart-define` 在编译时注入
  ///
  /// 默认: http://localhost:8080（本地开发）
  static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
  static const String _port = String.fromEnvironment('API_PORT', defaultValue: '8080');

  /// HTTP base URL (REST + WebSocket 共用)
  static String get baseUrl => 'http://$_host:$_port';

  /// Production URL placeholder
  static const String productionUrl = 'https://api.coevo.app';

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
