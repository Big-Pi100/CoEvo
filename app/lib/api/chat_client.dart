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

  Future<Map<String, dynamic>> getDueCards({String? conversationId, int limit = 20, int offset = 0}) async {
    final params = <String, String>{'user_id': userId, 'limit': limit.toString(), 'offset': offset.toString()};
    if (conversationId != null && conversationId.isNotEmpty) {
      params['conversation_id'] = conversationId;
    }
    final resp = await http.get(
      Uri.parse('$baseUrl/api/review/due').replace(queryParameters: params),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('Review API error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 按 task 进度查询卡片（仅返回 done/in_progress task 对应的卡片）
  Future<Map<String, dynamic>> getCardsByProgress() async {
    final params = <String, String>{'user_id': userId};
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/review/cards-by-progress').replace(queryParameters: params),
        headers: _authHeaders,
      ).timeout(ApiConfig.requestTimeout);
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('getCardsByProgress error: $e');
    }
    return {'cards': <dynamic>[], 'count': 0};
  }

  /// 搜索卡片（全文搜索 front/back）
  Future<Map<String, dynamic>> searchCards(String query, {int limit = 20, int offset = 0}) async {
    final params = <String, String>{
      'user_id': userId, 'q': query,
      'limit': limit.toString(), 'offset': offset.toString(),
    };
    final resp = await http.get(
      Uri.parse('$baseUrl/api/cards/search').replace(queryParameters: params),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('Search API error: ${resp.statusCode}');
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

  // ── Card Status API ──

  /// 更新单张卡片状态: active / pending / skipped / archived
  Future<void> updateCardStatus(String cardId, String status) async {
    final resp = await http.patch(
      Uri.parse('$baseUrl/api/cards/status'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'card_id': cardId,
        'status': status,
      }),
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Status update error: ${resp.statusCode}');
    }
  }

  /// 批量更新卡片状态
  Future<Map<String, dynamic>> batchUpdateStatus(
    List<String> cardIds,
    String status,
  ) async {
    final resp = await http.patch(
      Uri.parse('$baseUrl/api/cards/batch-status'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'card_ids': cardIds,
        'status': status,
      }),
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Batch status update error: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
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

  // ── Cards by Plan (grouped by conversation_plans) ──

  /// 按 conversation_plan 分组获取卡片
  /// 返回 {"plans": [{id, goal, conversation_id, cards, card_count}], "total_plans": int}
  /// 按 conversation_plan 获取卡片（惰性加载）
  /// 当 [convId] 为空时：只返回 plan 元数据，cards 为空数组
  /// 当 [convId] 指定时：只加载该 plan 的完整卡片数据
  Future<Map<String, dynamic>> getCardsByPlan({String? convId, int limit = 20, int offset = 0, String sort = 'front'}) async {
    final params = <String, String>{'user_id': userId, 'limit': limit.toString(), 'offset': offset.toString(), 'sort': sort};
    if (convId != null && convId.isNotEmpty) {
      params['conversation_id'] = convId;
    }
    final uri = Uri.parse('$baseUrl/api/cards/by-plan')
        .replace(queryParameters: params);
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Cards by plan API error: ${resp.statusCode}');
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

  // ── K12 API ──

  /// 初始化 K12 结构化学习会话
  Future<Map<String, dynamic>> k12Init({
    required String subject,
    required String gradeBand,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/k12/init'),
      headers: _authHeaders,
      body: jsonEncode({
        'user_id': userId,
        'subject': subject,
        'grade_band': gradeBand,
      }),
    ).timeout(ApiConfig.requestTimeout);

    if (resp.statusCode != 200) {
      throw Exception('K12 init error: ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 获取 K12 学习进度

  /// 获取 K12 学习进度
  Future<Map<String, dynamic>> getK12Progress() async {
    final uri = Uri.parse('$baseUrl/api/k12/progress').replace(queryParameters: {
      'user_id': userId,
    });
    final resp = await http.get(uri, headers: _authHeaders)
        .timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) throw Exception('K12 progress: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
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

  /// 获取所有成就定义 + 进度（Phase 3 成就页面改版）
  Future<Map<String, dynamic>?> getAchievementsAll() async {
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/user/$userId/achievements-all'),
        headers: _authHeaders,
      );
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('getAchievementsAll error: $e');
    }
    return null;
  }
}
