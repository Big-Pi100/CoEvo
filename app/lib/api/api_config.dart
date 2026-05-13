/// CoEvo API Configuration
class ApiConfig {
  /// API 服务器地址
  /// 使用 IP 而非域名以避免移动运营商 DNS 解析问题
  static const String baseUrl = 'http://<OLD_VPS_IP>:8080';

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
