import 'dart:math' as math;

/// 极简数学表达式求值器 —— 替代 `dart:js` 的 `eval`。
///
/// ## 为什么需要它
///
/// 原实现（`widgets/graph_widget.dart`）在画函数图像时，把表达式丢给
/// JavaScript 的 `eval` 求值：
///
/// ```dart
/// js.context['__cfx'] = x;
/// final y = js.context.callMethod('eval', [expr]);   // ← web-only
/// ```
///
/// `dart:js` 在 iOS/Android 不存在 → 原生编不过
/// （见 `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §1.2）。
/// 本文件用**纯 Dart 递归下降解析器**等价替换，不引入新依赖。
///
/// ## 语法支持
///
/// - 运算符：`+ - * / ^`（`^` 为幂，与原 JS 实现一致 —— 原实现内部把 `^` 换成 `**`）
/// - 括号、一元负号
/// - 变量：`x`
/// - 常量：`pi` / `e`
/// - 函数：`sin cos tan asin acos atan sinh cosh tanh sqrt abs ln log log10 exp
///   floor ceil round sign`
///
/// ## 行为约定
///
/// **解析/求值失败一律返回 `null`**（而不是抛异常）—— 调用方据此跳过该采样点；
/// 返回值**可能为 `NaN` / `Infinity`**（如 `1/0`、`sqrt(-1)`），
/// 由调用方按其绘制逻辑过滤（与原实现 `y.isFinite` 判断保持一致）。
double? evalMathExpr(String expr, double x) {
  final src = expr.trim();
  if (src.isEmpty) return null;
  return _Parser(src, x).parse();
}

class _Parser {
  _Parser(this.src, this.x);

  final String src;
  final double x;
  int _i = 0;

  static const _functions = <String, double Function(double)>{
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'asin': math.asin,
    'acos': math.acos,
    'atan': math.atan,
    'sinh': _sinh,
    'cosh': _cosh,
    'tanh': _tanh,
    'sqrt': math.sqrt,
    'abs': _abs,
    'ln': math.log,
    'log': math.log, // 与 JS Math.log 一致（自然对数）
    'log10': _log10,
    'exp': math.exp,
    'floor': _floor,
    'ceil': _ceil,
    'round': _round,
    'sign': _sign,
  };

  static double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;
  static double _cosh(double v) => (math.exp(v) + math.exp(-v)) / 2;
  static double _tanh(double v) => _sinh(v) / _cosh(v);
  static double _abs(double v) => v.abs();
  static double _log10(double v) => math.log(v) / math.ln10;
  static double _floor(double v) => v.floorToDouble();
  static double _ceil(double v) => v.ceilToDouble();
  static double _round(double v) => v.roundToDouble();
  static double _sign(double v) => v > 0 ? 1 : (v < 0 ? -1 : 0);

  /// 求值；失败返回 `null`。
  double? parse() {
    try {
      final v = _expr();
      _skipWs();
      if (_i != src.length) return null; // 有未消费的残留 → 非法表达式
      return v;
    } catch (_) {
      return null;
    }
  }

  void _skipWs() {
    while (_i < src.length && (src[_i] == ' ' || src[_i] == '\t')) {
      _i++;
    }
  }

  bool _peek(String c) {
    _skipWs();
    return _i < src.length && src[_i] == c;
  }

  bool _eat(String c) {
    if (_peek(c)) {
      _i++;
      return true;
    }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        v /= _unary();
      } else {
        return v;
      }
    }
  }

  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  /// 幂运算：右结合（`2^3^2` = `2^(3^2)`）。
  double _power() {
    final base = _atom();
    if (_eat('^')) return math.pow(base, _unary()).toDouble();
    return base;
  }

  double _atom() {
    _skipWs();
    if (_i >= src.length) throw const FormatException('表达式意外结束');

    // 括号
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw const FormatException('缺少右括号');
      return v;
    }

    // 数字（含小数）
    final c = src[_i];
    if (_isDigit(c) || c == '.') return _number();

    // 标识符：变量 / 常量 / 函数
    if (_isAlpha(c)) return _ident();

    throw FormatException('无法识别的字符: $c');
  }

  double _number() {
    final start = _i;
    while (_i < src.length && (_isDigit(src[_i]) || src[_i] == '.')) {
      _i++;
    }
    // 科学计数法：1e-3
    if (_i < src.length && (src[_i] == 'e' || src[_i] == 'E')) {
      final save = _i;
      _i++;
      if (_i < src.length && (src[_i] == '+' || src[_i] == '-')) _i++;
      if (_i < src.length && _isDigit(src[_i])) {
        while (_i < src.length && _isDigit(src[_i])) {
          _i++;
        }
      } else {
        _i = save; // 不是科学计数法（如 "2exp(" 的 e）
      }
    }
    final v = double.tryParse(src.substring(start, _i));
    if (v == null) throw FormatException('非法数字: ${src.substring(start, _i)}');
    return v;
  }

  double _ident() {
    final start = _i;
    while (_i < src.length && (_isAlpha(src[_i]) || _isDigit(src[_i]))) {
      _i++;
    }
    final name = src.substring(start, _i);
    final lower = name.toLowerCase();

    // 函数：后随 '('
    final fn = _functions[lower];
    if (fn != null) {
      if (!_eat('(')) throw FormatException('函数 $name 缺少参数括号');
      final arg = _expr();
      if (!_eat(')')) throw FormatException('函数 $name 缺少右括号');
      return fn(arg);
    }

    switch (lower) {
      case 'x':
        return x;
      case 'pi':
        return math.pi;
      case 'e':
        return math.e;
    }
    throw FormatException('未知标识符: $name');
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F;
  }
}
