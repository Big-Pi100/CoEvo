import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'api_config.dart';

/// Auth API client — /api/auth/register and /api/auth/login
class AuthClient {
  /// Register a new user. Returns {user_id, token} or throws.
  Future<Map<String, dynamic>> register(String username, String password, {String? realName, String? phone, String? referralCode}) async {
    final body = <String, dynamic>{'username': username, 'password': password, 'real_name': realName, 'phone': phone};
    if (referralCode != null && referralCode.isNotEmpty) {
      body['referral'] = {'code': referralCode};
    }
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
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

  /// Verify that a stored token is still valid on the server.
  /// Returns true if the token is valid, false otherwise.
  Future<bool> verifyToken(String userId, String token) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/auth/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'token': token}),
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data['valid'] == true;
      }
    } catch (e) {
      // Network error — don't invalidate, assume valid
      debugPrint('verifyToken: network error: $e');
    }
    return true; // Be lenient on network errors
  }

  /// Create a trial account. Returns {user_id, token}.
  Future<Map<String, dynamic>> trialStart({String? referralCode}) async {
    final body = <String, String>{};
    if (referralCode != null && referralCode.isNotEmpty) {
      body['referral_code'] = referralCode;
    }
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/trial/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Trial start failed');
    }
    return data;
  }

  /// Claim a trial account. Returns {token}.
  Future<Map<String, dynamic>> trialClaim(
    String userId,
    String token,
    String username,
    String password, {
    String? realName,
    String? phone,
    String? referralCode,
  }) async {
    final body = <String, dynamic>{
      'user_id': userId,
      'username': username,
      'password': password,
    };
    if (realName != null && realName.isNotEmpty) body['real_name'] = realName;
    if (phone != null && phone.isNotEmpty) body['phone'] = phone;
    if (referralCode != null && referralCode.isNotEmpty) body['referral_code'] = referralCode;
    final resp = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/api/trial/claim'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Trial claim failed');
    }
    return data;
  }
}
