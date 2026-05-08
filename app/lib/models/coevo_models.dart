/// AI 对话请求
class ChatRequest {
  final String userId;
  final String conversationId;
  final String message;

  const ChatRequest({
    required this.userId,
    required this.conversationId,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'conversation_id': conversationId,
    'message': message,
  };
}

/// WebSocket 事件
class WsEvent {
  final String type;
  final String? content;
  final String? reply;
  final List<ConceptCandidate>? candidates;

  const WsEvent({
    required this.type,
    this.content,
    this.reply,
    this.candidates,
  });

  factory WsEvent.fromJson(Map<String, dynamic> json) {
    List<ConceptCandidate>? candidates;
    final raw = json['candidates'];
    if (raw is List) {
      candidates = raw.map((e) {
        if (e is String) {
          return ConceptCandidate(front: e);
        }
        return ConceptCandidate.fromJson(e as Map<String, dynamic>);
      }).toList();
    }
    return WsEvent(
      type: json['type'] as String? ?? 'error',
      content: json['content'] as String?,
      reply: json['reply'] as String?,
      candidates: candidates,
    );
  }
}

/// 到期卡片 (复习队列)
class DueCard {
  final String id;
  final String front;
  final String back;
  final String? domain;
  final String cardType;
  final String? sourceSentence;
  final int state;
  final int reps;
  final int lapses;
  final double difficulty;
  final int? createdAt;
  final int? due;

  const DueCard({
    required this.id,
    required this.front,
    required this.back,
    this.domain,
    required this.cardType,
    this.sourceSentence,
    required this.state,
    required this.reps,
    this.lapses = 0,
    this.difficulty = 5.0,
    this.createdAt,
    this.due,
  });

  factory DueCard.fromJson(Map<String, dynamic> json) => DueCard(
    id: json['id'] as String? ?? '',
    front: json['front'] as String? ?? '',
    back: json['back'] as String? ?? '',
    domain: json['domain'] as String?,
    cardType: json['card_type'] as String? ?? 'concept',
    sourceSentence: json['source_sentence'] as String?,
    state: json['state'] as int? ?? 0,
    reps: json['reps'] as int? ?? 0,
    lapses: json['lapses'] as int? ?? 0,
    difficulty: (json['difficulty'] as num?)?.toDouble() ?? 5.0,
    createdAt: json['created_at'] as int?,
    due: json['due'] as int?,
  );
}

/// 验证问题 (AI 快问快答)
class VerifyQuestion {
  final String question;
  final String expectedAnswer;

  const VerifyQuestion({
    required this.question,
    required this.expectedAnswer,
  });

  factory VerifyQuestion.fromJson(Map<String, dynamic> json) => VerifyQuestion(
    question: json['question'] as String? ?? '',
    expectedAnswer: json['expected_answer'] as String? ?? '',
  );
}

/// 判断结果
class JudgeResult {
  final bool correct;
  final String feedback;

  const JudgeResult({required this.correct, required this.feedback});

  factory JudgeResult.fromJson(Map<String, dynamic> json) => JudgeResult(
    correct: json['correct'] as bool? ?? false,
    feedback: json['feedback'] as String? ?? '',
  );
}

/// 对话消息 (UI 展示)
class Message {
  final String role;
  final String content;
  final DateTime timestamp;
  final List<String>? concepts;

  const Message({
    required this.role,
    required this.content,
    required this.timestamp,
    this.concepts,
  });
}

/// 卡片候选 (制卡弹窗)
class ConceptCandidate {
  final String front;
  final String? back;
  final String? sourceSentence;
  final String? domain;

  const ConceptCandidate({required this.front, this.back, this.sourceSentence, this.domain});

  factory ConceptCandidate.fromJson(Map<String, dynamic> json) => ConceptCandidate(
    front: json['front'] as String? ?? json['concept'] as String? ?? '',
    back: json['back'] as String?,
    sourceSentence: json['source_sentence'] as String?,
    domain: json['domain'] as String?,
  );
}
