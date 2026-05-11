import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/coevo_models.dart';
import 'api_config.dart';

class ChatClient {
  final String baseUrl;
  final String userId;
  final String conversationId;
  final String? token;

  ChatClient({
    this.baseUrl = ApiConfig.baseUrl,
    this.userId = 'default_user',
    this.conversationId = 'default_conv',
    this.token,
  });

  Map<String, String> get _authHeaders {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  // ── REST Chat ──

  Future<Map<String, dynamic>> sendMessage(String message) async {
    final body = ChatRequest(
      userId: userId,
      conversationId: conversationId,
      message: message,
    );

    final resp = await http.post(
      Uri.parse('$baseUrl/api/chat'),
      headers: _authHeaders,
      body: jsonEncode(body.toJson()),
    ).timeout(ApiConfig.longTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Chat API error: ${resp.statusCode} ${resp.body}');
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── WebSocket Chat ──

  WsChatSession streamChat(String message) {
    final wsUrl = token != null
        ? '$baseUrl/ws?token=$token'
        : '$baseUrl/ws';
    final uri = Uri.parse(wsUrl.replaceFirst('http', 'ws'));
    final channel = WebSocketChannel.connect(uri);
    final controller = StreamController<WsEvent>.broadcast();

    channel.sink.add(jsonEncode(ChatRequest(
      userId: userId,
      conversationId: conversationId,
      message: message,
    ).toJson()));

    channel.stream.listen(
      (data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        final event = WsEvent.fromJson(json);
        controller.add(event);
      },
      onError: (error) => controller.addError(error),
      onDone: () => controller.close(),
    );

    return WsChatSession(controller.stream, channel);
  }

  // ── Review API ──

  Future<Map<String, dynamic>> getDueCards() async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/review/due').replace(queryParameters: {'user_id': userId}),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Review API error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> submitReview({
    required String cardId,
    required int rating,
    required String verificationType,
    required String verificationResult,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/review/submit'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'card_id': cardId,
        'rating': rating,
        'verification_type': verificationType,
        'verification_result': verificationResult,
      }),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Review submit error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> verifyQuestions(String cardId, String front, String back) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/review/verify'),
      headers: _authHeaders,
      body: jsonEncode({'card_id': cardId, 'front': front, 'back': back}),
    ).timeout(ApiConfig.longTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Verify error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> judgeAnswers({
    required String cardId,
    required List<Map<String, String>> questions,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/review/judge'),
      headers: _authHeaders,
      body: jsonEncode({'card_id': cardId, 'questions': questions}),
    ).timeout(ApiConfig.longTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Judge error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Skip API ──

  Future<void> skipConcept(String front, String sourceText) async {
    await http.post(
      Uri.parse('$baseUrl/api/cards/skip'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'front': front,
        'source_text': sourceText,
      }),
    );
  }

  // ── Profile API ──

  Future<Map<String, dynamic>> getProfile() async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/user/$userId/profile'),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('Profile API: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── History API ──

  /// 获取对话列表（不含具体轮次）
  Future<Map<String, dynamic>> getConversationList({int limit = 50}) async {
    final uri = Uri.parse('$baseUrl/api/history').replace(queryParameters: {
      'user_id': userId,
      'limit': limit.toString(),
    });
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('History API: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 获取指定对话的轮次
  Future<List<Map<String, dynamic>>> getConversationTurns(String convId) async {
    final uri = Uri.parse('$baseUrl/api/history').replace(queryParameters: {
      'user_id': userId,
      'conversation_id': convId,
      'limit': '50',
    });
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['turns'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
  }

  // ── All Cards API ──

  // ── Skipped Concepts ──

  Future<Map<String, dynamic>> getSkippedConcepts() async {
    final uri = Uri.parse('$baseUrl/api/cards/skipped').replace(queryParameters: {
      'user_id': userId,
    });
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('Skipped API: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> deleteSkipped(String skipId) async {
    final resp = await http.delete(
      Uri.parse('$baseUrl/api/cards/skipped/$skipId'),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('Delete skipped: ${resp.statusCode}');
  }

  // ── All Cards API ──

  Future<Map<String, dynamic>> getAllCards({
    String? query,
    int? state,
    String? domain,
    String? sort,
  }) async {
    final params = <String, String>{'user_id': userId};
    if (query != null && query.isNotEmpty) params['q'] = query;
    if (state != null) params['state'] = state.toString();
    if (domain != null && domain.isNotEmpty) params['domain'] = domain;
    if (sort != null) params['sort'] = sort;

    final uri = Uri.parse('$baseUrl/api/cards/all').replace(queryParameters: params);
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Cards API error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Batch Create Cards ──

  Future<Map<String, dynamic>> batchCreateCards(
    List<Map<String, dynamic>> candidates,
  ) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/cards/batch-create'),
      headers: _authHeaders,
      body: jsonEncode({'user_id': userId, 'candidates': candidates}),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Batch create error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Health ──

  Future<bool> healthCheck() async {
    try {
      final resp = await http.get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

class WsChatSession {
  final Stream<WsEvent> events;
  final WebSocketChannel _channel;

  WsChatSession(this.events, this._channel);

  /// 通过已有连接发送消息（复用 WS）
  void send(String userId, String conversationId, String message) {
    _channel.sink.add(jsonEncode(ChatRequest(
      userId: userId,
      conversationId: conversationId,
      message: message,
    ).toJson()));
  }

  void cancel() {
    _channel.sink.close();
  }
}

// ── Learning Plan API (ChatClient extension) ──

extension PlanApi on ChatClient {
  Future<List<Map<String, dynamic>>> getPlans({String? conversationId}) async {
    try {
      final queryParams = conversationId != null
          ? 'conversation_id=$conversationId'
          : 'user_id=$userId';
      final resp = await http.get(
        Uri.parse('$baseUrl/api/plans?$queryParams'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['plans'] as List?)
            ?.cast<Map<String, dynamic>>()
            .where((p) => p['mode'] != 'deleted')
            .toList() ?? [];
      }
    } catch (_) {}
    return [];
  }

  Future<Map<String, dynamic>?> createPlan({
    required String goal,
    required String domain,
    required Map<String, dynamic> planJson,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/plans'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          'goal': goal,
          'domain': domain,
          'plan_json': planJson,
        }),
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 获取学习报告（Phase 3 家长看板数据）
  Future<Map<String, dynamic>?> getLearningReport() async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/user/$userId/learning-report'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 获取学习活动数据（热力图用）
  Future<Map<String, dynamic>?> getActivity({int days = 30}) async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/user/$userId/activity?days=$days'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 获取周报数据
  Future<Map<String, dynamic>?> getWeeklyReport() async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/user/$userId/weekly-report'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// 更新显示昵称到后端
  Future<bool> updateDisplayName(String name) async {
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/user/$userId/display-name'),
        headers: _authHeaders,
        body: jsonEncode({'display_name': name}),
      );
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
