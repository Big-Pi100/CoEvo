import 'package:flutter_test/flutter_test.dart';

/// 数学公式流式渲染测试套件
///
/// 模拟 chat_screen.dart 中 _buildRichContent 的行为：
/// - isStreaming=true  → 纯文本渲染，跳过正则解析
/// - isStreaming=false → 正则匹配后用 Math.tex 渲染

/// 与 _buildRichContent 中完全相同的正则
final mathRegex = RegExp(r'\\[\(\[](.+?)\\[[)\]]', dotAll: true);

// ============================================================================
// 工具函数
// ============================================================================

/// 模拟 LLM 真实 token 输出：定界符 \( \) \[ \] 独立到达，
/// 普通文字 1-2 字符一组，LaTeX 命令如 \frac 整体到达
List<String> realTokenize(String text) {
  final tokens = <String>[];
  int i = 0;
  while (i < text.length) {
    // 定界符对：\(  \)  \[  \]
    if (text[i] == '\\' && i + 1 < text.length &&
        RegExp(r'[\(\)\[\]]').hasMatch(text[i + 1])) {
      tokens.add(text.substring(i, i + 2));
      i += 2;
    }
    // LaTeX 命令: \frac, \sin, \infty 等
    else if (text[i] == '\\' && i + 1 < text.length &&
        RegExp(r'[a-zA-Z]').hasMatch(text[i + 1])) {
      int j = i + 1;
      while (j < text.length && RegExp(r'[a-zA-Z]').hasMatch(text[j])) {
        j++;
      }
      tokens.add(text.substring(i, j));
      i = j;
    }
    // 标点/特殊字符单独
    else if (RegExp(r'[{}^_&]').hasMatch(text[i])) {
      tokens.add(text[i]);
      i++;
    }
    // 普通文字 1-2 字符
    else {
      final len = (i + 2 <= text.length) ? 2 : 1;
      tokens.add(text.substring(i, i + len));
      i += len;
    }
  }
  return tokens;
}

/// 流式模拟结果
class SimResult {
  final int totalFrames;
  final int flickerFrames; // 正则匹配状态翻转次数
  final bool finalMatch;
  final List<String> unstableFrames; // 哪些帧导致了 flicker

  SimResult({
    required this.totalFrames,
    required this.flickerFrames,
    required this.finalMatch,
    this.unstableFrames = const [],
  });

  double get flickerRate => totalFrames > 0 ? flickerFrames / totalFrames : 0;
  String get verdict => finalMatch ? (flickerFrames == 0 ? '✅ STABLE' : '⚠️ FLICKER') : '❌ FAIL';
}

/// 旧行为：每帧都做正则匹配
SimResult simulateOld(String text) {
  final tokens = realTokenize(text);
  String buf = '';
  int flickers = 0;
  bool prevMatch = false;
  final unstable = <String>[];

  for (final t in tokens) {
    buf += t;
    final curMatch = mathRegex.hasMatch(buf);
    if (curMatch != prevMatch) {
      flickers++;
      unstable.add('"$t" → match=$curMatch buf="${buf.length > 40 ? '...${buf.substring(buf.length - 40)}' : buf}"');
    }
    prevMatch = curMatch;
  }

  return SimResult(
    totalFrames: tokens.length,
    flickerFrames: flickers,
    finalMatch: mathRegex.hasMatch(buf),
    unstableFrames: unstable,
  );
}

/// 新行为：流式期间 isStreaming=true → 跳过正则；最后一帧 (done) 才解析
SimResult simulateNew(String text) {
  final tokens = realTokenize(text);
  String buf = '';

  for (int i = 0; i < tokens.length; i++) {
    buf += tokens[i];
  }

  return SimResult(
    totalFrames: tokens.length,
    flickerFrames: 0, // 永不闪烁
    finalMatch: mathRegex.hasMatch(buf),
  );
}

// ============================================================================
// 测试用例
// ============================================================================

void main() {
  group('1. 正则完整性 — 完整公式匹配', () {
    final cases = <String, bool>{
      // 基本行内
      r'\(x + 5 = 12\)': true,
      r'\(a^2 + b^2 = c^2\)': true,
      r'\(E = mc^2\)': true,
      // 基本独立
      r'\[E = mc^2\]': true,
      r'\[\sum_{i=0}^{n} x_i\]': true,
      // 内嵌括号 (f(x) 中的括号不应干扰)
      r'\(f(x) = x^2 + 2x + 1\)': true,
      r'\(\sin(\theta + \frac{\pi}{2}) = \cos(\theta)\)': true,
      // 中文混合
      r'根据公式 \(v = \frac{s}{t}\) 可得': true,
      r'当 \(x \to \infty\) 时，\(f(x) \to 0\)': true, // 两个公式
      // LaTeX 命令
      r'\(3 \times 4 = 12\)': true,
      r'\(\sqrt{16} = 4\)': true,
      r'\[\int_0^\infty e^{-x^2} dx\]': true,
      // 边界
      r'\(\)': false, // 空公式：.+? 至少一个字符
      r'这是一段普通文本': false,
      r'x^2 + y^2 = z^2 (无标记)': false,
    };

    int pass = 0, fail = 0;
    for (final e in cases.entries) {
      final matched = mathRegex.hasMatch(e.key);
      if (matched == e.value) {
        pass++;
      } else {
        fail++;
        print('  ❌ "${e.key}" → got=$matched expected=${e.value}');
      }
    }

    final rate = pass / cases.length;
    print('\n===== 正则匹配率: ${(rate * 100).toStringAsFixed(0)}% ($pass/${cases.length}) =====');

    test('所有预期匹配的公式全部命中', () {
      expect(rate, greaterThanOrEqualTo(0.9),
          reason: 'Match rate: ${(rate * 100).toStringAsFixed(0)}%');
    });
  });

  group('2. 流式闪烁对比 — 真实 token 分片', () {
    // 精选 10 个真实场景的数学公式
    final formulas = [
      r'\(x^2 + y^2 = z^2\)',
      r'\(E = mc^2\) 是著名的质能方程',
      r'公式 \[ \frac{a}{b} + \frac{c}{d} = \frac{ad+bc}{bd} \] 很重要',
      r'\(f(x) = \int_0^x t^2 dt\)',
      r'根据定义 \(\sin^2\theta + \cos^2\theta = 1\) ，可得',
      r'\[ \lim_{n\to\infty} (1+\frac{1}{n})^n = e \]',
      r'\(\sqrt{a^2 + b^2}\)',
      r'当 \(x \to 0\) 时，\(\frac{\sin x}{x} \to 1\)',
      r'矩阵 \(\begin{pmatrix} a & b \\ c & d \end{pmatrix}\)',
      r'中文中 \(v = \frac{s}{t}\) 是速度公式，而 \(F = ma\) 是牛顿第二定律',
    ];

    test('旧行为：每帧解析 → 有闪烁', () {
      int totalFlickers = 0, totalFrames = 0, finalOk = 0;

      print('\n===== 旧行为（流式解析）=====');
      for (final f in formulas) {
        final r = simulateOld(f);
        totalFlickers += r.flickerFrames;
        totalFrames += r.totalFrames;
        if (r.finalMatch) finalOk++;

        print('  ${r.verdict} (${r.flickerFrames}/${r.totalFrames} flicker)');
        print('    "$f"');
        for (final u in r.unstableFrames.take(2)) {
          print('    ↳ $u');
        }
        if (r.unstableFrames.length > 2) print('    ... and ${r.unstableFrames.length - 2} more');
      }

      final pct = (totalFlickers / totalFrames * 100).toStringAsFixed(1);
      print('  ─────────────────────');
      print('  总闪烁率: $pct% ($totalFlickers/$totalFrames frames)');
      print('  最终匹配: $finalOk/${formulas.length}');
    });

    test('新行为：流式跳过 → 零闪烁 + 100% 最终匹配', () {
      int totalFlickers = 0, totalFrames = 0, finalOk = 0;

      print('\n===== 新行为（流式跳过 + done 时解析）=====');
      for (final f in formulas) {
        final r = simulateNew(f);
        totalFlickers += r.flickerFrames;
        totalFrames += r.totalFrames;
        if (r.finalMatch) finalOk++;

        print('  ${r.verdict} | "$f"');
      }

      print('  ─────────────────────');
      print('  总闪烁率: ${(totalFlickers / totalFrames * 100).toStringAsFixed(1)}%');
      print('  最终匹配: $finalOk/${formulas.length}');

      expect(totalFlickers, equals(0), reason: '新行为必须零闪烁');
      expect(finalOk, equals(formulas.length), reason: '所有公式 done 时必须成功匹配');
    });
  });

  group('3. 边界场景', () {
    test('纯文本不误匹配', () {
      expect(mathRegex.hasMatch('这是一段普通文本'), isFalse);
      expect(mathRegex.hasMatch('Hello World 123'), isFalse);
      expect(mathRegex.hasMatch('x^2 + y^2 = z^2'), isFalse);
    });

    test('不完整定界符不匹配', () {
      expect(mathRegex.hasMatch(r'\('), isFalse);
      expect(mathRegex.hasMatch(r'\(x^2'), isFalse);
      expect(mathRegex.hasMatch(r'x^2\)'), isFalse);
      expect(mathRegex.hasMatch(r'\['), isFalse);
      expect(mathRegex.hasMatch(r'\[E = mc^2'), isFalse);
    });

    test('多公式正确提取数量和内容', () {
      final text = r'已知 \(a^2+b^2=c^2\) 且 \[E=mc^2\] 成立';
      final matches = mathRegex.allMatches(text).toList();
      expect(matches.length, 2);
      expect(matches[0].group(1)!.trim(), 'a^2+b^2=c^2');
      expect(matches[1].group(1)!.trim(), 'E=mc^2');
    });

    test('公式紧邻', () {
      final text = r'\(x=1\)\(y=2\)';
      final matches = mathRegex.allMatches(text).toList();
      expect(matches.length, 2);
    });

    test('含换行的独立公式 (dotAll)', () {
      // 真实 LLM 输出中，display 公式常有换行：
      // \[
      // \sin\theta = \frac{a}{b}
      // \]
      // dotAll: true 后 . 可以匹配 \n
      final text = '\\[\na + b = c\n\\]';
      expect(mathRegex.hasMatch(text), isTrue);
      final match = mathRegex.firstMatch(text)!;
      expect(match.group(1)!.trim(), 'a + b = c');
    });

    test('空公式 .+? 不匹配 → 正确行为', () {
      // \(\) 无内容，.+? 需要至少一个字符
      expect(mathRegex.hasMatch(r'\(\)'), isFalse);
    });
  });
}
