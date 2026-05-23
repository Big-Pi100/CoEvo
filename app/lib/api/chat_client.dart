import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
    String? baseUrl,
    this.userId = 'default_user',
    this.conversationId = 'default_conv',
    this.token,
  }) : baseUrl = baseUrl ?? ApiConfig.baseUrl;

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
    // D4: token no longer in URL — sent as first message payload instead
    // 竞态修复: 控制器在连接前创建，监听器在发消息前注册，确保不丢事件
    final controller = StreamController<WsEvent>.broadcast();

    final wsUrl = '$baseUrl/ws';
    final uri = Uri.parse(wsUrl.replaceFirst('http', 'ws'));
    debugPrint('🌐 streamChat: connecting to $uri');
    final channel = WebSocketChannel.connect(uri);
    debugPrint('🌐 streamChat: WS connected, controller.hasListener=${controller.hasListener}');

    channel.stream.listen(
      (data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        final event = WsEvent.fromJson(json);
        debugPrint('🌐 WS raw event: type=${event.type} hasListener=${controller.hasListener}');
        controller.add(event);
      },
      onError: (error) {
        debugPrint('🌐 WS channel error: $error');
        controller.addError(error);
      },
      onDone: () {
        debugPrint('🌐 WS channel closed');
        controller.close();
      },
    );

    // Token 已包含在 ChatRequest payload 中，无需额外握手消息
    // （额外的 auth 消息会导致后端解析失败 → 前端误处理为流错误，吞噬 done 回复）
    final req = jsonEncode(ChatRequest(
      userId: userId,
      conversationId: conversationId,
      message: message,
      token: token,
    ).toJson());
    debugPrint('🌐 streamChat: sending request (len=${req.length})');
    channel.sink.add(req);

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
    String? detailsJson,  // JSON 字符串: [{question, correct, feedback}]
  }) async {
    final body = <String, dynamic>{
      'user_id': userId,
      'card_id': cardId,
      'rating': rating,
      'verification_type': verificationType,
      'verification_result': verificationResult,
    };
    if (detailsJson != null) body['details'] = detailsJson;
    final resp = await http.post(
      Uri.parse('$baseUrl/api/review/submit'),
      headers: _authHeaders,
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Review submit error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 获取卡片最近一次考试详情
  Future<Map<String, dynamic>?> getLastReview(String cardId) async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/cards/$cardId/last-review'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('getLastReview error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> verifyQuestions(String cardId, String front, String back) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/review/verify'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'card_id': cardId,
        'front': front,
        'back': back,
      }),
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
      body: jsonEncode({
        'user_id': userId,
        'card_id': cardId,
        'questions': questions,
      }),
    ).timeout(ApiConfig.longTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Judge error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 正向语义验证：LLM 判断用户翻译是否等价于正确答案
  Future<String> verifyTranslation({
    required String front,
    required String back,
    required String userInput,
  }) async {
    final body = <String, dynamic>{
      'front': front,
      'back': back,
      'user_input': userInput,
    };
    final resp = await http.post(
      Uri.parse('$baseUrl/api/verify-translation'),
      headers: _authHeaders,
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Verify translation error: ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['result'] as String;
  }

  /// 语法验证：LLM 判断用户的语法答案是否正确
  Future<String> verifyGrammar({
    required String front,
    required String back,
    required String userInput,
  }) async {
    final body = <String, dynamic>{
      'front': front,
      'back': back,
      'user_input': userInput,
    };
    final resp = await http.post(
      Uri.parse('$baseUrl/api/verify-translation'),
      headers: _authHeaders,
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Verify grammar error: ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['result'] as String;
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
  /// includeDeleted: "only"=仅已删除, "true"=全部, 默认=仅活跃
  Future<Map<String, dynamic>> getConversationList({
    int limit = 50,
    String? includeDeleted,
  }) async {
    final params = <String, String>{
      'user_id': userId,
      'limit': limit.toString(),
    };
    if (includeDeleted != null) params['include_deleted'] = includeDeleted;
    final uri = Uri.parse('$baseUrl/api/history').replace(queryParameters: params);
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('History API: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 获取指定对话的轮次（支持分页，offset=0 为最新）
  /// 返回 {turns, total}
  Future<Map<String, dynamic>> getConversationTurns(String convId, {int limit = 50, int offset = 0}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/history').replace(queryParameters: {
        'user_id': userId,
        'conversation_id': convId,
        'limit': limit.toString(),
        'offset': offset.toString(),
      });
      final resp = await http.get(uri, headers: _authHeaders)
          .timeout(ApiConfig.requestTimeout);
      if (resp.statusCode != 200) return {'turns': [], 'total': 0};
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data.containsKey('error')) return {'turns': [], 'total': 0};
      return {
        'turns': (data['turns'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [],
        'total': data['total'] as int? ?? 0,
      };
    } catch (e) {
      debugPrint('getConversationTurns error: $e');
      return {'turns': [], 'total': 0};
    }
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

  // ── Conversation Management ──

  /// 软删除对话（移至回收站）
  Future<Map<String, dynamic>?> deleteConversation(String convId) async {
    try {
      final uri = Uri.parse('$baseUrl/api/conversations/$convId')
          .replace(queryParameters: {'user_id': userId});
      final resp = await http.delete(uri, headers: _authHeaders)
          .timeout(ApiConfig.requestTimeout);
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('deleteConversation error: $e');
    }
    return null;
  }

  /// 恢复已删除对话
  Future<bool> restoreConversation(String convId) async {
    try {
      final uri = Uri.parse('$baseUrl/api/conversations/$convId/restore')
          .replace(queryParameters: {'user_id': userId});
      final resp = await http.post(uri, headers: _authHeaders)
          .timeout(ApiConfig.requestTimeout);
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('restoreConversation error: $e');
      return false;
    }
  }

  /// 彻底删除对话（不可恢复）
  Future<bool> permanentDeleteConversation(String convId) async {
    try {
      final uri = Uri.parse('$baseUrl/api/conversations/$convId/permanent')
          .replace(queryParameters: {'user_id': userId});
      final resp = await http.delete(uri, headers: _authHeaders)
          .timeout(ApiConfig.requestTimeout);
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('permanentDeleteConversation error: $e');
      return false;
    }
  }

  // ── Health ──

  Future<bool> healthCheck() async {
    try {
      final resp = await http.get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('healthCheck error: $e');
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
    } catch (e) {
      debugPrint('getPlans error: $e');
    }
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
    } catch (e) {
      debugPrint('createPlan error: $e');
    }
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
    } catch (e) {
      debugPrint('getLearningReport error: $e');
    }
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
    } catch (e) {
      debugPrint('getActivity error: $e');
    }
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
    } catch (e) {
      debugPrint('getWeeklyReport error: $e');
    }
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
    } catch (e) {
      debugPrint('updateDisplayName error: $e');
      return false;
    }
  }

  /// 获取用户偏好
  Future<Map<String, String>> getPreferences() async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/user/$userId/preferences'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (e) {
      debugPrint('getPreferences error: $e');
    }
    return {};
  }

  /// 保存用户偏好（批量）
  Future<bool> savePreferences(Map<String, String> prefs) async {
    try {
      final resp = await http.put(
        Uri.parse('$baseUrl/api/user/$userId/preferences'),
        headers: _authHeaders,
        body: jsonEncode(prefs),
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('savePreferences error: $e');
      return false;
    }
  }
}
