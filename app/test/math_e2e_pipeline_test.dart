import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

/// 端到端管道测试：模拟完整 LLM → 后端 → WebSocket → 前端 路径
///
/// 测试场景：建立三角函数学习计划，LLM 输出包含大量数学公式
/// 验证：JSON 往返逃逸、正则匹配、流式分片下的最终渲染正确性

/// 与 _buildRichContent 中完全相同的正则
final mathRegex = RegExp(r'\\[\(\[](.+?)\\[[)\]]', dotAll: true);

/// ---------------------------------------------------------------------------
/// 模拟后端 ws.rs 的 token 事件发送
/// ---------------------------------------------------------------------------

/// 模拟 serde_json::json!({"type":"token","content":...}) 的 JSON 序列化
String backendToken(String content) {
  return jsonEncode({'type': 'token', 'content': content});
}

/// 模拟 serde_json::json!({"type":"done","reply":...})
String backendDone(String reply) {
  return jsonEncode({'type': 'done', 'reply': reply});
}

/// ---------------------------------------------------------------------------
/// 模拟前端 chat_screen.dart _handleWsEvent + _buildRichContent
/// ---------------------------------------------------------------------------

class StreamingPipeline {
  String _buffer = '';
  final List<String> _allTokens = [];
  bool _isStreaming = true;

  /// 接收一个 token 事件（模拟 _handleWsEvent case 'token'）
  void receiveToken(String rawJson) {
    final event = jsonDecode(rawJson) as Map<String, dynamic>;
    final content = event['content'] as String;
    _buffer += content;
    _allTokens.add(content);
  }

  /// 接收 done 事件（模拟 _handleWsEvent case 'done'）
  void receiveDone(String rawJson) {
    final event = jsonDecode(rawJson) as Map<String, dynamic>;
    final reply = event['reply'] as String?;
    if (reply != null) _buffer = reply;
    _isStreaming = false;
  }

  /// 当前是否在流式输出中
  bool get isStreaming => _isStreaming;

  /// 累积的完整文本
  String get fullText => _buffer;

  /// 收到的 token 列表
  List<String> get tokens => List.unmodifiable(_allTokens);

  /// 渲染内容（模拟 _buildRichContent）
  /// isStreaming=true  → 纯文本（修复后行为）
  /// isStreaming=false → 正则解析
  List<_FormulaMatch> render() {
    if (_isStreaming) {
      // 修复：流式期间纯文本
      return [];
    }

    final matches = mathRegex.allMatches(_buffer).toList();
    return matches.map((m) => _FormulaMatch(
      fullMatch: m.group(0)!,
      content: m.group(1)!.trim(),
      isDisplay: m.group(0)![1] == '[',
      start: m.start,
      end: m.end,
    )).toList();
  }
}

class _FormulaMatch {
  final String fullMatch;
  final String content;
  final bool isDisplay;
  final int start;
  final int end;

  _FormulaMatch({
    required this.fullMatch,
    required this.content,
    required this.isDisplay,
    required this.start,
    required this.end,
  });

  @override
  String toString() => '${isDisplay ? "DISPLAY" : "INLINE"} "$content" [$start-$end]';
}

/// ---------------------------------------------------------------------------
/// 真实 LLM 会输出的三角函数教学内容
/// ---------------------------------------------------------------------------

/// 模拟 token-by-token 流：每个 token 是 LLM 实际可能输出的片段
/// 这些是 DeepSeek / Qwen 在教三角函数时实际会输出的 token 模式
List<String> trigLessonTokens() {
  // 模拟 LLM tokenizer 行为：中文 1-2 字，英文/符号 1-3 字符，
  // LaTeX 定界符独立，命令整体
  return [
    // "三角函数是数学中非常重要的一个分支。"
    '三角', '函数', '是数学', '中非常', '重要的', '一个', '分支', '。',

    // "\n\n首先，我们来看最基本的定义："
    '\n\n', '首先', '，我们', '来看', '最基本', '的定义', '：',

    // "\n\n**正弦函数**：\( \sin\theta = \frac{\text{对边}}{\text{斜边}} \)"
    '\n\n', '**正弦', '函数**', '：', '\\(', ' \\', 'sin', '\\', 'theta', ' = ',
    '\\', 'frac', '{', '\\', 'text', '{对边', '}}{', '\\', 'text', '{斜边', '}}', '\\)',

    // "\n**余弦函数**：\( \cos\theta = \frac{\text{邻边}}{\text{斜边}} \)"
    '\n', '**余弦', '函数**', '：', '\\(', ' \\', 'cos', '\\', 'theta', ' = ',
    '\\', 'frac', '{', '\\', 'text', '{邻边', '}}{', '\\', 'text', '{斜边', '}}', '\\)',

    // "\n\n最重要的恒等式："
    '\n\n', '最重要', '的恒等', '式：',

    // "\[ \sin^2\theta + \cos^2\theta = 1 \]"
    '\\[', ' \\', 'sin', '^2', '\\', 'theta', ' + ',
    '\\', 'cos', '^2', '\\', 'theta', ' = 1', ' \\]',

    // "\n\n还有倍角公式："
    '\n\n', '还有', '倍角', '公式', '：',

    // "\( \sin(2\theta) = 2\sin\theta\cos\theta \)"
    '\\(', ' \\', 'sin', '(2', '\\', 'theta', ') = 2',
    '\\', 'sin', '\\', 'theta', '\\', 'cos', '\\', 'theta', '\\)',

    // " 和 \( \cos(2\theta) = \cos^2\theta - \sin^2\theta \)"
    ' 和 ', '\\(', ' \\', 'cos', '(2', '\\', 'theta', ') = ',
    '\\', 'cos', '^2', '\\', 'theta', ' - ',
    '\\', 'sin', '^2', '\\', 'theta', '\\)',

    // "\n\n这些公式在解题中非常常用。"
    '\n\n', '这些', '公式', '在解题', '中非常', '常用', '。',
  ];
}

/// ---------------------------------------------------------------------------
/// 测试
/// ---------------------------------------------------------------------------

void main() {
  group('端到端管道 — 三角函数教学', () {
    late StreamingPipeline pipeline;

    setUp(() {
      pipeline = StreamingPipeline();
    });

    test('阶段0：JSON 往返逃逸验证', () {
      // 验证 LaTeX 命令经过 serde_json → jsonEncode → jsonDecode 后完整
      final testTokens = [
        r'\(',
        r' \sin\theta = \frac{a}{b}',
        r'\)',
      ];

      for (final t in testTokens) {
        final json = backendToken(t);
        final decoded = (jsonDecode(json) as Map)['content'] as String;
        expect(decoded, equals(t),
            reason: 'Token "$t" should survive JSON roundtrip');
      }

      // done 事件同理
      final fullReply = r'公式 \(\sin\theta = \frac{a}{b}\) 是基础';
      final doneJson = backendDone(fullReply);
      final decodedReply = (jsonDecode(doneJson) as Map)['reply'] as String;
      expect(decodedReply, equals(fullReply),
          reason: 'Done reply should survive JSON roundtrip');
    });

    test('阶段1：流式接收所有 token', () {
      final tokens = trigLessonTokens();
      for (final t in tokens) {
        pipeline.receiveToken(backendToken(t));
      }

      expect(pipeline.tokens.length, equals(tokens.length));
      expect(pipeline.isStreaming, isTrue);
      // 流式期间不应渲染公式
      expect(pipeline.render(), isEmpty,
          reason: 'Streaming mode should not produce formula matches');
    });

    test('阶段2：done 事件后渲染', () {
      // 流式
      for (final t in trigLessonTokens()) {
        pipeline.receiveToken(backendToken(t));
      }

      // done
      pipeline.receiveDone(backendDone(pipeline.fullText));

      expect(pipeline.isStreaming, isFalse);

      final formulas = pipeline.render();
      print('\n===== 三角函数完整渲染结果 =====');
      print('完整文本 (${pipeline.fullText.length} 字符):');
      print(pipeline.fullText);
      print('\n提取的公式 (${formulas.length} 个):');
      for (final f in formulas) {
        print('  $f');
      }

      // 共 5 个公式：4 inline + 1 display
      expect(formulas.length, greaterThanOrEqualTo(5));

      // 逐个验证
      final contents = formulas.map((f) => f.content).toList();

      expect(contents, contains(r'\sin\theta = \frac{\text{对边}}{\text{斜边}}'));
      expect(contents, contains(r'\cos\theta = \frac{\text{邻边}}{\text{斜边}}'));
      expect(contents, contains(r'\sin^2\theta + \cos^2\theta = 1'));
      expect(contents, contains(r'\sin(2\theta) = 2\sin\theta\cos\theta'));
      expect(contents, contains(r'\cos(2\theta) = \cos^2\theta - \sin^2\theta'));

      // 独立公式 vs 行内公式
      final display = formulas.where((f) => f.isDisplay).toList();
      final inline = formulas.where((f) => !f.isDisplay).toList();

      expect(display.length, equals(1),
          reason: 'Only sin²+cos²=1 should be display formula');
      expect(display.first.content, r'\sin^2\theta + \cos^2\theta = 1');

      expect(inline.length, equals(4));
    });

    test('阶段3：流式期间的中间状态 — 验证旧行为会闪烁', () {
      final tokens = trigLessonTokens();
      String buffer = '';
      int flickerCount = 0;
      bool prevMatch = false;
      final flickerDetails = <String>[];

      for (final t in tokens) {
        buffer += t;
        final curMatch = mathRegex.hasMatch(buffer);
        if (curMatch != prevMatch) {
          flickerCount++;
          flickerDetails.add(
              'Frame #${tokens.indexOf(t)}: "$t" → match=$curMatch');
        }
        prevMatch = curMatch;
      }

      print('\n===== 旧行为闪烁分析 =====');
      print('总帧数: ${tokens.length}, 闪烁次数: $flickerCount');
      for (final d in flickerDetails.take(10)) {
        print('  $d');
      }
      if (flickerDetails.length > 10) {
        print('  ... 还有 ${flickerDetails.length - 10} 次');
      }

      expect(flickerCount, greaterThan(0),
          reason: '旧行为在分片流式下必然有闪烁');
    });

    test('阶段4：流式中间帧不会匹配不完整公式', () {
      final tokens = trigLessonTokens();
      String buffer = '';

      for (int i = 0; i < tokens.length; i++) {
        buffer += tokens[i];
        final matches = mathRegex.allMatches(buffer);

        for (final m in matches) {
          final full = m.group(0)!;
          // 每个匹配的公式必须有完整的定界符对
          final hasOpen = full.startsWith(r'\(') || full.startsWith(r'\[');
          final hasClose = full.endsWith(r'\)') || full.endsWith(r'\]');
          expect(hasOpen && hasClose, isTrue,
              reason: 'Frame $i: match "$full" should have complete delimiters');
        }
      }
    });
  });

  group('端到端 — 边界公式', () {
    test('f(x) 内嵌括号不干扰匹配', () {
      final pipe = StreamingPipeline();
      final tokens = [
        '函数', ' ', '\\(', ' f(x', ') = ', 'x^2', ' + 2x', ' + 1', '\\)',
        ' 的定义', '域为', '全体', '实数', '。',
      ];

      for (final t in tokens) {
        pipe.receiveToken(backendToken(t));
      }
      pipe.receiveDone(backendDone(pipe.fullText));

      final formulas = pipe.render();
      expect(formulas.length, equals(1));
      expect(formulas.first.content, 'f(x) = x^2 + 2x + 1');
    });

    test('多个公式混合中文 — 数量和顺序正确', () {
      final pipe = StreamingPipeline();
      final tokens = [
        '已知', ' ', '\\(', ' a^2', ' + ', 'b^2', ' = ', 'c^2', '\\)',
        ' 和 ', '\\[', ' E =', ' mc', '^2', ' \\]',
        ' ，求', '解。',
      ];

      for (final t in tokens) {
        pipe.receiveToken(backendToken(t));
      }
      pipe.receiveDone(backendDone(pipe.fullText));

      final formulas = pipe.render();
      expect(formulas.length, equals(2));
      expect(formulas[0].content, 'a^2 + b^2 = c^2');
      expect(formulas[0].isDisplay, isFalse);
      expect(formulas[1].content, 'E = mc^2');
      expect(formulas[1].isDisplay, isTrue);
    });

    test('公式紧邻无空格 — 每个独立提取', () {
      final pipe = StreamingPipeline();
      // LLM 可能输出紧邻公式
      final tokens = [
        '\\(', 'x=', '1', '\\)', '\\(', 'y=', '2', '\\)',
      ];

      for (final t in tokens) {
        pipe.receiveToken(backendToken(t));
      }
      pipe.receiveDone(backendDone(pipe.fullText));

      final formulas = pipe.render();
      expect(formulas.length, equals(2));
      expect(formulas[0].content, 'x=1');
      expect(formulas[1].content, 'y=2');
    });

    test('LaTeX 特殊字符 — \times \div \sqrt \frac \infty', () {
      final pipe = StreamingPipeline();
      final formula = r'\(\sqrt{a^2+b^2} \times \frac{c}{d} \div \infty\)';
      // 模拟 token 分片
      final tokens = <String>[];
      int i = 0;
      while (i < formula.length) {
        if (formula[i] == '\\' && i + 1 < formula.length) {
          int j = i + 1;
          if (RegExp(r'[\(\)\[\]]').hasMatch(formula[j])) {
            tokens.add(formula.substring(i, i + 2)); // \( 等
            i += 2;
          } else {
            while (j < formula.length && RegExp(r'[a-zA-Z]').hasMatch(formula[j])) {
              j++;
            }
            tokens.add(formula.substring(i, j)); // \sqrt \times 等
            i = j;
          }
        } else {
          final len = (formula.length - i).clamp(1, 2);
          tokens.add(formula.substring(i, i + len));
          i += len;
        }
      }

      for (final t in tokens) {
        pipe.receiveToken(backendToken(t));
      }
      pipe.receiveDone(backendDone(pipe.fullText));

      final formulas = pipe.render();
      expect(formulas.length, equals(1));
      expect(formulas.first.content,
          r'\sqrt{a^2+b^2} \times \frac{c}{d} \div \infty');
    });

    test('矩阵公式 — \begin{pmatrix} ... \end{pmatrix}', () {
      final pipe = StreamingPipeline();
      final formula = r'\(A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}\)';
      final tokens = <String>[];
      int i = 0;
      while (i < formula.length) {
        if (formula[i] == '\\' && i + 1 < formula.length) {
          int j = i + 1;
          if (RegExp(r'[\(\)\[\]]').hasMatch(formula[j])) {
            tokens.add(formula.substring(i, i + 2));
            i += 2;
          } else {
            while (j < formula.length && RegExp(r'[a-zA-Z]').hasMatch(formula[j])) {
              j++;
            }
            tokens.add(formula.substring(i, j));
            i = j;
          }
        } else {
          final len = (formula.length - i).clamp(1, 2);
          tokens.add(formula.substring(i, i + len));
          i += len;
        }
      }

      for (final t in tokens) {
        pipe.receiveToken(backendToken(t));
      }
      pipe.receiveDone(backendDone(pipe.fullText));

      final formulas = pipe.render();
      expect(formulas.length, equals(1));
      expect(formulas.first.content,
          r'A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}');
    });
  });
}
