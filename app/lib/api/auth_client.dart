import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';

/// Auth API client — /api/auth/register and /api/auth/login
class AuthClient {
  /// Register a new user. Returns {user_id, token} or throws.
  Future<Map<String, dynamic>> register(String username, String password) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Registration failed');
    }
    return data;
  }

  /// Login. Returns {user_id, token} or throws.
  Future<Map<String, dynamic>> login(String username, String password) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Login failed');
    }
    return data;
  }
}
