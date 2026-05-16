import 'package:flutter_test/flutter_test.dart';
import 'package:coevo_app/models/coevo_models.dart';

void main() {
  group('ConceptCandidate', () {
    test('fromJson parses valid JSON', () {
      final json = {
        'front': 'Machine Learning',
        'back': 'A subset of AI',
        'source_sentence': 'ML is powerful',
        'domain': 'tech',
      };
      final candidate = ConceptCandidate.fromJson(json);
      expect(candidate.front, 'Machine Learning');
      expect(candidate.back, 'A subset of AI');
      expect(candidate.sourceSentence, 'ML is powerful');
      expect(candidate.domain, 'tech');
    });

    test('fromJson handles missing optional fields', () {
      final json = {'front': 'Test'};
      final candidate = ConceptCandidate.fromJson(json);
      expect(candidate.front, 'Test');
      expect(candidate.back, isNull);
      expect(candidate.domain, isNull);
    });

    test('fromJson accepts concept alias', () {
      final json = {'concept': 'Neural Network'};
      final candidate = ConceptCandidate.fromJson(json);
      expect(candidate.front, 'Neural Network');
    });
  });

  group('DueCard', () {
    test('fromJson parses valid card JSON', () {
      final json = {
        'id': 'card_abc',
        'front': 'Neural Network',
        'back': 'A network of neurons',
        'domain': 'ai',
        'card_type': 'concept',
        'source_sentence': 'NNs are powerful',
        'created_at': 1712345678,
        'state': 0,
        'difficulty': 5.0,
        'due': 1712345678,
        'reps': 0,
        'lapses': 0,
      };
      final card = DueCard.fromJson(json);
      expect(card.id, 'card_abc');
      expect(card.front, 'Neural Network');
      expect(card.state, 0);
      expect(card.cardType, 'concept');
      expect(card.difficulty, 5.0);
    });

    test('fromJson handles missing fields with defaults', () {
      final json = {
        'id': 'card_min',
        'front': 'Minimal',
        'back': 'Minimal back',
      };
      final card = DueCard.fromJson(json);
      expect(card.state, 0);
      expect(card.cardType, 'concept');
      expect(card.difficulty, 5.0);
      expect(card.reps, 0);
    });
  });

  group('VerifyQuestion', () {
    test('fromJson parses valid question', () {
      final json = {
        'question': 'What is ML?',
        'expected_answer': 'Machine Learning',
      };
      final q = VerifyQuestion.fromJson(json);
      expect(q.question, 'What is ML?');
      expect(q.expectedAnswer, 'Machine Learning');
    });
  });

  group('JudgeResult', () {
    test('fromJson parses correct result', () {
      final json = {'correct': true, 'feedback': 'Well done!'};
      final r = JudgeResult.fromJson(json);
      expect(r.correct, true);
      expect(r.feedback, 'Well done!');
    });

    test('fromJson parses incorrect result', () {
      final json = {'correct': false, 'feedback': 'Try again'};
      final r = JudgeResult.fromJson(json);
      expect(r.correct, false);
    });
  });

  group('ChatRequest', () {
    test('toJson serializes correctly', () {
      final req = ChatRequest(
        userId: 'user_1',
        conversationId: 'conv_1',
        message: 'Hello',
      );
      final json = req.toJson();
      expect(json['user_id'], 'user_1');
      expect(json['conversation_id'], 'conv_1');
      expect(json['message'], 'Hello');
      expect(json.containsKey('token'), false);
    });

    test('toJson includes token when provided', () {
      final req = ChatRequest(
        userId: 'user_1',
        conversationId: 'conv_1',
        message: 'Hello',
        token: 'tok_123',
      );
      final json = req.toJson();
      expect(json['token'], 'tok_123');
    });
  });

  group('Message', () {
    test('constructor stores all fields', () {
      final now = DateTime(2026, 5, 16, 12, 0);
      final msg = Message(
        role: 'user',
        content: 'Hello world',
        timestamp: now,
        concepts: ['AI', 'ML'],
      );
      expect(msg.role, 'user');
      expect(msg.content, 'Hello world');
      expect(msg.timestamp, now);
      expect(msg.concepts, ['AI', 'ML']);
    });
  });
}
