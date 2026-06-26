// ignore_for_file: invalid_null_aware_operator, unnecessary_cast
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:graphic/graphic.dart' as graphic;

/// 内联图形渲染组件 — 解析 `<graph>` JSON 并渲染对应图表
class GraphWidget extends StatelessWidget {
  final String jsonStr;

  const GraphWidget({super.key, required this.jsonStr});

  /// 截断长文本用于错误显示
  static String _shorten(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}...';
  }

  static List<dynamic> _safeList(dynamic value) {
    if (value == null) return <dynamic>[];
    if (value is List) return value as List<dynamic>;
    return <dynamic>[];
  }

  static double _safeDouble(dynamic value, [double fallback = 0]) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) {
      final d = double.tryParse(value);
      if (d != null) return d;
      final i = int.tryParse(value);
      if (i != null) return i.toDouble();
    }
    if (value is bool) return value ? 1.0 : 0.0;
    return fallback;
  }

  static int _safeInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is num) return value.toInt();
    if (value is String) {
      final i = int.tryParse(value);
      if (i != null) return i;
      final d = double.tryParse(value);
      if (d != null) return d.round();
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final _cs = Theme.of(context).colorScheme;
    Map<String, dynamic> data;
    String? rawJson;
    try {
      String cleaned = jsonStr.trim();
      rawJson = cleaned;
      // 去除可能的 markdown 代码块包裹（含前置换行的情况）
      cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?', multiLine: true), '');
      cleaned = cleaned.replaceAll('```', '').trim();
      // 容错：LLM 有时在 JSON 前后加多余字符，截取第一个 { 到最后一个 }
      final braceStart = cleaned.indexOf('{');
      final braceEnd = cleaned.lastIndexOf('}');
      if (braceStart >= 0 && braceEnd > braceStart) {
        cleaned = cleaned.substring(braceStart, braceEnd + 1);
      }
      data = jsonDecode(cleaned) as Map<String, dynamic>;
      data = _normalize(data);
    } catch (e) {
      return _buildError('图形数据解析失败: ${_shorten(rawJson ?? jsonStr, 200)}\n$e', _cs);
    }

    final type = data['type'] as String?;
    if (type == null) return _buildError('缺少 type 字段', _cs);

    try {
      switch (type) {
        case 'line':
          return _buildGraphicLine(data);
        case 'bar':
          return _buildGraphicBar(data);
        case 'scatter':
          return _buildGraphicScatter(data);
        case 'pie':
          return _buildGraphicPie(data);
        case 'polygon':
          return _buildPolygon(data, context);
        case 'circle':
          return _buildCircle(data, context);
        case 'arrow':
          return _buildArrowChart(data, context);
        default:
          return _buildError('不支持的图形类型: $type', _cs);
      }
    } catch (e) {
      return _buildError('图形渲染失败: $e', _cs);
    }
  }

  // ── graphic 折线图 ──
  Widget _buildGraphicLine(Map<String, dynamic> data) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', ThemeData().colorScheme);
    final title = data['title'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(0, 12, 16, 8),
      decoration: _chartBoxDeco(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: graphic.Chart(
              data: list,
              variables: {
                'x': graphic.Variable(accessor: (Map m) => _safeDouble(m['x'])),
                'y': graphic.Variable(accessor: (Map m) => _safeDouble(m['y'])),
              },
              marks: [graphic.LineMark()],
              axes: [graphic.Defaults.horizontalAxis, graphic.Defaults.verticalAxis],
            ),
          ),
        ],
      ),
    );
  }

  // ── graphic 柱状图 ──
  Widget _buildGraphicBar(Map<String, dynamic> data) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', ThemeData().colorScheme);
    final title = data['title'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(0, 12, 16, 8),
      decoration: _chartBoxDeco(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: graphic.Chart(
              data: list,
              variables: {
                'label': graphic.Variable(accessor: (Map m) => m['label'] as String),
                'value': graphic.Variable(accessor: (Map m) => _safeDouble(m['value'])),
              },
              marks: [graphic.IntervalMark()],
              axes: [graphic.Defaults.horizontalAxis, graphic.Defaults.verticalAxis],
            ),
          ),
        ],
      ),
    );
  }

  // ── graphic 散点图 ──
  Widget _buildGraphicScatter(Map<String, dynamic> data) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', ThemeData().colorScheme);
    final title = data['title'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(0, 12, 16, 8),
      decoration: _chartBoxDeco(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: graphic.Chart(
              data: list,
              variables: {
                'x': graphic.Variable(accessor: (Map m) => _safeDouble(m['x'])),
                'y': graphic.Variable(accessor: (Map m) => _safeDouble(m['y'])),
              },
              marks: [graphic.PointMark()],
              axes: [graphic.Defaults.horizontalAxis, graphic.Defaults.verticalAxis],
            ),
          ),
        ],
      ),
    );
  }

  // ── graphic 饼图 ──
  Widget _buildGraphicPie(Map<String, dynamic> data) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', ThemeData().colorScheme);
    final title = data['title'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(0, 12, 16, 8),
      decoration: _chartBoxDeco(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: graphic.Chart(
              data: list,
              variables: {
                'label': graphic.Variable(accessor: (Map m) => m['label'] as String),
                'value': graphic.Variable(accessor: (Map m) => _safeDouble(m['value'])),
              },
              marks: [graphic.IntervalMark()],
              coord: graphic.PolarCoord(transposed: true),
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _chartBoxDeco() {
    // placeholder — actual colors come from parent context at build time
    return BoxDecoration(
      color: const Color(0xFFF5F5F5),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE0E0E0)),
    );
  }

  // ── CustomPainter 多边形 ──
  Widget _buildPolygon(Map<String, dynamic> data, BuildContext context) {
    // [Kept unchanged from original implementation]
    final cs = Theme.of(context).colorScheme;
    final List raw = _safeList(data['points']);
    final points = raw.map((p) {
      final m = p as Map<String, dynamic>;
      return Offset(_safeDouble(m['x']), _safeDouble(m['y']));
    }).toList();
    if (points.length < 2) return _buildError('多边形至少需要 2 个点', cs);

    final title = data['title'] as String? ?? '';
    final rawLabels = _safeList(data['labels']);
    final labels = rawLabels.map((l) => l.toString()).toList();
    final rawAngles = _safeList(data['rightAngles']);
    final rightAngles = rawAngles.map((a) => _safeInt(a)).toSet();
    final rawAngleArcs = _safeList(data['angles']);
    final angleArcs = rawAngleArcs?.map((a) {
      final m = a as Map<String, dynamic>;
      return _AngleArc(
        vertexIndex: _safeInt(m['vertex']),
        label: m['label'] as String?,
        startAngle: (m['startAngle'] as num?)?.toDouble(),
        sweepAngle: (m['sweepAngle'] as num?)?.toDouble(),
      );
    }).toList() ?? <_AngleArc>[];
    final xVals = points.map((p) => p.dx);
    final yVals = points.map((p) => p.dy);
    final xMin = xVals.reduce((a, b) => a < b ? a : b);
    final xMax = xVals.reduce((a, b) => a > b ? a : b);
    final yMin = yVals.reduce((a, b) => a < b ? a : b);
    final yMax = yVals.reduce((a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          SizedBox(
            height: 200,
            child: CustomPaint(
              size: const Size(double.infinity, 200),
              painter: _GeometryPainter(
                cs: cs,
                points: points,
                xMin: xMin, xMax: xMax,
                yMin: yMin, yMax: yMax,
                drawClosed: true,
                labels: labels,
                rightAngles: rightAngles,
                angleArcs: angleArcs,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── CustomPainter 圆形 ──
  Widget _buildCircle(Map<String, dynamic> data, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final center = data['center'] as Map<String, dynamic>?;
    final cx = (center?['x'] as num?)?.toDouble() ?? 0;
    final cy = (center?['y'] as num?)?.toDouble() ?? 0;
    final radius = (data['radius'] as num?)?.toDouble() ?? 1;
    final title = data['title'] as String? ?? '';
    final rawTangents = _safeList(data['tangents']);
    final tangents = rawTangents?.map((t) {
      final m = t as Map<String, dynamic>;
      final from = m['from'] as Map<String, dynamic>;
      final to = m['to'] as Map<String, dynamic>;
      return _ArrowData(
        from: Offset(_safeDouble(from['x']), _safeDouble(from['y'])),
        to: Offset(_safeDouble(to['x']), _safeDouble(to['y'])),
        label: m['label'] as String?,
      );
    }).toList() ?? <_ArrowData>[];
    final rawAngleArcs2 = _safeList(data['angles']);
    final angleArcs2 = rawAngleArcs2?.map((a) {
      final m = a as Map<String, dynamic>;
      return _AngleArc(
        vertexIndex: _safeInt(m['vertex']),
        label: m['label'] as String?,
        startAngle: (m['startAngle'] as num?)?.toDouble(),
        sweepAngle: (m['sweepAngle'] as num?)?.toDouble(),
        centerX: (m['cx'] as num?)?.toDouble(),
        centerY: (m['cy'] as num?)?.toDouble(),
      );
    }).toList() ?? <_AngleArc>[];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          SizedBox(
            height: 200,
            child: CustomPaint(
              size: const Size(double.infinity, 200),
              painter: _GeometryPainter(
                cs: cs,
                points: const [],
                xMin: cx - radius - 0.5, xMax: cx + radius + 0.5,
                yMin: cy - radius - 0.5, yMax: cy + radius + 0.5,
                drawClosed: false,
                labels: const [],
                rightAngles: const {},
                angleArcs: angleArcs2,
                circleCenter: Offset(cx, cy),
                circleRadius: radius,
                tangentLines: tangents,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── CustomPainter 箭头图 ──
  Widget _buildArrowChart(Map<String, dynamic> data, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final List raw = _safeList(data['arrows']);
    final arrows = raw.map((a) {
      final m = a as Map<String, dynamic>;
      final from = m['from'] as Map<String, dynamic>;
      final to = m['to'] as Map<String, dynamic>;
      return _ArrowData(
        from: Offset(_safeDouble(from['x']), _safeDouble(from['y'])),
        to: Offset(_safeDouble(to['x']), _safeDouble(to['y'])),
        label: m['label'] as String?,
        color: _parseColor(m['color'] as String?, cs),
      );
    }).toList();
    if (arrows.isEmpty) return _buildError('无箭头数据', cs);

    final title = data['title'] as String? ?? '';
    var xMin = double.infinity, xMax = double.negativeInfinity;
    var yMin = double.infinity, yMax = double.negativeInfinity;
    for (final a in arrows) {
      if (a.from.dx < xMin) xMin = a.from.dx;
      if (a.from.dx > xMax) xMax = a.from.dx;
      if (a.to.dx < xMin) xMin = a.to.dx;
      if (a.to.dx > xMax) xMax = a.to.dx;
      if (a.from.dy < yMin) yMin = a.from.dy;
      if (a.from.dy > yMax) yMax = a.from.dy;
      if (a.to.dy < yMin) yMin = a.to.dy;
      if (a.to.dy > yMax) yMax = a.to.dy;
    }
    final pad = (xMax - xMin + yMax - yMin) * 0.1 + 0.5;
    xMin -= pad; xMax += pad; yMin -= pad; yMax += pad;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          SizedBox(
            height: 220,
            child: CustomPaint(
              size: const Size(double.infinity, 220),
              painter: _GeometryPainter(
                cs: cs,
                points: const [],
                xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax,
                drawClosed: false,
                arrows: arrows,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String msg, ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.error.withAlpha(51)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Text('📊 $msg', style: TextStyle(fontSize: 12, color: cs.onErrorContainer)),
        ],
      ),
    );
  }

  Color _parseColor(String? hex, ColorScheme cs) {
    if (hex == null || hex.isEmpty) return cs.primary;
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
    return cs.primary;
  }

  static Map<String, dynamic> _normalize(Map<String, dynamic> raw) {
    final m = Map<String, dynamic>.from(raw);
    if (!m.containsKey('title') && m.containsKey('label')) {
      m['title'] = m['label'];
    }
    final opts = m['options'] as Map<String, dynamic>?;
    if (opts != null) {
      if (!m.containsKey('xlabel') && opts.containsKey('xLabel')) m['xlabel'] = opts['xLabel'];
      if (!m.containsKey('ylabel') && opts.containsKey('yLabel')) m['ylabel'] = opts['yLabel'];
      if (!m.containsKey('title') && opts.containsKey('title')) m['title'] = opts['title'];
    }
    if (m['center'] is List) {
      final arr = m['center'] as List;
      if (arr.length >= 2) m['center'] = {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
    }
    if (m['data'] is List && (m['data'] as List).isNotEmpty) {
      final first = (m['data'] as List).first;
      if (first is List && first is! Map) {
        m['data'] = (m['data'] as List).map((e) {
          final arr = e as List;
          return {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
        }).toList();
      }
    }
    if (m['data'] is List) {
      m['data'] = (m['data'] as List).map((e) {
        if (e is Map) {
          final item = Map<String, dynamic>.from(e as Map);
          item['x'] ??= 0;
          item['y'] ??= 0;
          return item;
        }
        return e;
      }).toList();
    }
    if (m['points'] is List && (m['points'] as List).isNotEmpty) {
      final first = (m['points'] as List).first;
      if (first is List) {
        m['points'] = (m['points'] as List).map((e) {
          final arr = e as List;
          return {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
        }).toList();
      }
    }
    if (m['arrows'] is List) {
      m['arrows'] = (m['arrows'] as List).map((a) {
        if (a is Map) {
          final arrow = Map<String, dynamic>.from(a);
          if (arrow['from'] is List) {
            final arr = arrow['from'] as List;
            arrow['from'] = {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
          }
          if (arrow['to'] is List) {
            final arr = arrow['to'] as List;
            arrow['to'] = {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
          }
          return arrow;
        }
        return a;
      }).toList();
    }
    // strip latex from text fields
    for (final k in ['title', 'xlabel', 'ylabel']) {
      if (m[k] is String) {
        m[k] = (m[k] as String)
            .replaceAll(r'\(', '').replaceAll(r'\)', '')
            .replaceAll(r'\[', '').replaceAll(r'\]', '');
      }
    }
    return m;
  }
}

/// 箭头数据
class _ArrowData {
  final Offset from, to;
  final String? label;
  final Color? color;
  _ArrowData({required this.from, required this.to, this.label, this.color});
}

/// 角度弧线数据
class _AngleArc {
  final int? vertexIndex;
  final String? label;
  final double? startAngle, sweepAngle;
  final double? centerX, centerY;
  _AngleArc({this.vertexIndex, this.label, this.startAngle, this.sweepAngle, this.centerX, this.centerY});
}

/// 标签数据（统一收集，最后绘制）
class _LabelData {
  final String text;
  final double x, y;
  final Color color;
  final FontWeight fontWeight;
  const _LabelData(this.text, this.x, this.y, this.color, {this.fontWeight = FontWeight.normal});
}

/// 几何图形绘制器：多边形 / 圆形 / 坐标轴
class _GeometryPainter extends CustomPainter {
  final ColorScheme cs;
  final List<Offset> points;
  final double xMin, xMax, yMin, yMax;
  final bool drawClosed;
  final Offset? circleCenter;
  final double? circleRadius;
  final List<_ArrowData> arrows;
  final List<String> labels;
  final Set<int> rightAngles;
  final List<_AngleArc> angleArcs;
  final List<_ArrowData> tangentLines;

  _GeometryPainter({
    required this.cs,
    required this.points,
    required this.xMin, required this.xMax,
    required this.yMin, required this.yMax,
    required this.drawClosed,
    this.circleCenter,
    this.circleRadius,
    this.arrows = const [],
    this.labels = const [],
    this.rightAngles = const {},
    this.angleArcs = const [],
    this.tangentLines = const [],
  });

  static const _palette = <Color>[
    Color(0xFF6C63FF),
    Color(0xFFFF6B6B),
    Color(0xFF4ECDC4),
    Color(0xFFFFD93D),
    Color(0xFFA78BFA),
    Color(0xFFFB923C),
    Color(0xFF34D399),
    Color(0xFF60A5FA),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 40.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    final scaleX = (xMax - xMin) == 0 ? 1 : w / (xMax - xMin);
    final scaleY = (yMax - yMin) == 0 ? 1 : h / (yMax - yMin);
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final cx = pad + w / 2 - (xMin + (xMax - xMin) / 2) * scale;
    final cy = pad + h / 2 + (yMin + (yMax - yMin) / 2) * scale;

    Offset toScreen(double x, double y) => Offset(cx + x * scale, cy - y * scale);
    final screenPoints = points.map((p) => toScreen(p.dx, p.dy)).toList();
    final pendingLabels = <_LabelData>[];

    // grid
    final gridPaint = Paint()
      ..color = cs.outlineVariant.withAlpha(40)
      ..strokeWidth = 0.5;
    final xRange = xMax - xMin;
    final yRange = yMax - yMin;
    final xStep = _niceInterval(xRange);
    final yStep = _niceInterval(yRange);
    if (xStep > 0 && yStep > 0) {
      double gx = (xMin / xStep).ceil() * xStep;
      while (gx <= xMax) {
        final sp = toScreen(gx, 0);
        _drawDashedLine(canvas, Offset(sp.dx, pad), Offset(sp.dx, size.height - pad), gridPaint);
        gx += xStep;
      }
      double gy = (yMin / yStep).ceil() * yStep;
      while (gy <= yMax) {
        final sp = toScreen(0, gy);
        _drawDashedLine(canvas, Offset(pad, sp.dy), Offset(size.width - pad, sp.dy), gridPaint);
        gy += yStep;
      }
    }

    // axes
    final axisPaint = Paint()..color = cs.outline..strokeWidth = 1.0;
    final origin = toScreen(0, 0);
    final xAxisY = origin.dy.clamp(pad.toDouble(), (size.height - pad).toDouble());
    canvas.drawLine(Offset(pad, xAxisY), Offset(size.width - pad, xAxisY), axisPaint);
    _drawArrowHead(canvas, Offset(size.width - pad, xAxisY), Offset(size.width - pad + 8, xAxisY - 4), cs.outline);
    _drawArrowHead(canvas, Offset(pad, xAxisY), Offset(pad - 8, xAxisY - 4), cs.outline);
    final yAxisX = origin.dx.clamp(pad.toDouble(), (size.width - pad).toDouble());
    canvas.drawLine(Offset(yAxisX, pad), Offset(yAxisX, size.height - pad), axisPaint);
    _drawArrowHead(canvas, Offset(yAxisX, pad), Offset(yAxisX - 4, pad - 8), cs.outline);
    _drawArrowHead(canvas, Offset(yAxisX, size.height - pad), Offset(yAxisX - 4, size.height - pad + 8), cs.outline);

    // ticks
    final tickPaint = Paint()..color = cs.outline..strokeWidth = 0.8;
    if (xStep > 0) {
      double tx = (xMin / xStep).ceil() * xStep;
      while (tx <= xMax) {
        final sp = toScreen(tx, 0);
        if (sp.dx >= pad && sp.dx <= size.width - pad) {
          canvas.drawLine(Offset(sp.dx, xAxisY - 4), Offset(sp.dx, xAxisY + 4), tickPaint);
          pendingLabels.add(_LabelData(_formatNum(tx), sp.dx, xAxisY + 14, cs.outline));
        }
        tx += xStep;
      }
    }
    if (yStep > 0) {
      double ty = (yMin / yStep).ceil() * yStep;
      while (ty <= yMax) {
        final sp = toScreen(0, ty);
        if (sp.dy >= pad && sp.dy <= size.height - pad) {
          canvas.drawLine(Offset(yAxisX - 4, sp.dy), Offset(yAxisX + 4, sp.dy), tickPaint);
          pendingLabels.add(_LabelData(_formatNum(ty), yAxisX - 22, sp.dy - 6, cs.outline));
        }
        ty += yStep;
      }
    }

    // circle
    if (circleCenter != null && circleRadius != null) {
      final cc = toScreen(circleCenter!.dx, circleCenter!.dy);
      final r = circleRadius! * scale;
      canvas.drawCircle(cc, r, Paint()..color = cs.primary.withAlpha(40)..style = PaintingStyle.fill);
      canvas.drawCircle(cc, r, Paint()..color = cs.primary..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawCircle(cc, 3, Paint()..color = cs.primary);
      return;
    }

    // polygon
    if (points.length >= 2) {
      final path = Path();
      path.moveTo(screenPoints[0].dx, screenPoints[0].dy);
      for (var i = 1; i < screenPoints.length; i++) {
        path.lineTo(screenPoints[i].dx, screenPoints[i].dy);
      }
      if (drawClosed) path.close();
      canvas.drawPath(path, Paint()..color = cs.primary.withAlpha(30)..style = PaintingStyle.fill);
      canvas.drawPath(path, Paint()..color = cs.primary..style = PaintingStyle.stroke..strokeWidth = 2);
      for (final sp in screenPoints) {
        canvas.drawCircle(sp, 3, Paint()..color = cs.primary);
      }
      for (var i = 0; i < screenPoints.length && i < labels.length; i++) {
        final lp = screenPoints[i];
        final cxc = screenPoints.fold(Offset.zero, (a, b) => a + b) / screenPoints.length.toDouble();
        final dx = lp.dx - cxc.dx;
        final dy = lp.dy - cxc.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final ox = dist > 0 ? dx / dist * 18 : 0;
        final oy = dist > 0 ? dy / dist * 18 : 0;
        pendingLabels.add(_LabelData(labels[i], lp.dx + ox, lp.dy + oy, cs.primary, fontWeight: FontWeight.w600));
      }
      for (final ri in rightAngles) {
        if (ri < 0 || ri >= screenPoints.length) continue;
        final prev = screenPoints[(ri - 1 + screenPoints.length) % screenPoints.length];
        final curr = screenPoints[ri];
        final next = screenPoints[(ri + 1) % screenPoints.length];
        final v1 = prev - curr;
        final v2 = next - curr;
        final d1 = math.sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
        final d2 = math.sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
        if (d1 == 0 || d2 == 0) continue;
        final u1 = Offset(v1.dx / d1, v1.dy / d1);
        final u2 = Offset(v2.dx / d2, v2.dy / d2);
        const markSize = 10.0;
        final p1 = curr + u1 * markSize;
        final p2 = curr + u1 * markSize + u2 * markSize;
        final p3 = curr + u2 * markSize;
        final markPath = Path()
          ..moveTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy)
          ..lineTo(p3.dx, p3.dy);
        canvas.drawPath(markPath, Paint()..color = cs.primary..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }

    // arrows
    for (int ai = 0; ai < arrows.length; ai++) {
      final arrow = arrows[ai];
      final fp = toScreen(arrow.from.dx, arrow.from.dy);
      final tp = toScreen(arrow.to.dx, arrow.to.dy);
      final color = arrow.color ?? _palette[ai % _palette.length];
      canvas.drawLine(fp, tp, Paint()..color = color..strokeWidth = 2.5..strokeCap = StrokeCap.round);
      final dx = tp.dx - fp.dx;
      final dy = tp.dy - fp.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      final ux = dx / len;
      final uy = dy / len;
      const arrowLen = 12.0;
      const arrowAngle = 0.45;
      final ax1 = tp.dx - arrowLen * (ux * math.cos(arrowAngle) - uy * math.sin(arrowAngle));
      final ay1 = tp.dy - arrowLen * (ux * math.sin(arrowAngle) + uy * math.cos(arrowAngle));
      final ax2 = tp.dx - arrowLen * (ux * math.cos(arrowAngle) + uy * math.sin(arrowAngle));
      final ay2 = tp.dy - arrowLen * (-ux * math.sin(arrowAngle) + uy * math.cos(arrowAngle));
      final arrowPath = Path()
        ..moveTo(tp.dx, tp.dy)
        ..lineTo(ax1, ay1)
        ..lineTo(ax2, ay2)
        ..close();
      canvas.drawPath(arrowPath, Paint()..color = color..style = PaintingStyle.fill);
      canvas.drawCircle(fp, 3.5, Paint()..color = color);
      if (arrow.label != null && arrow.label!.isNotEmpty) {
        final lx = (fp.dx + tp.dx) / 2;
        final ly = (fp.dy + tp.dy) / 2 - 14;
        pendingLabels.add(_LabelData(arrow.label!, lx, ly, color, fontWeight: FontWeight.w600));
      }
    }

    // angle arcs
    for (final arc in angleArcs) {
      Offset? cnt;
      Offset? ref1, ref2;
      if (arc.centerX != null && arc.centerY != null) {
        cnt = toScreen(arc.centerX!, arc.centerY!);
        ref1 = cnt + const Offset(20, 0);
        ref2 = cnt + const Offset(0, 20);
      } else if (arc.vertexIndex != null && arc.vertexIndex! < screenPoints.length) {
        cnt = screenPoints[arc.vertexIndex!];
        final i0 = (arc.vertexIndex! - 1 + screenPoints.length) % screenPoints.length;
        final i2 = (arc.vertexIndex! + 1) % screenPoints.length;
        ref1 = screenPoints[i0];
        ref2 = screenPoints[i2];
      }
      if (cnt == null || ref1 == null || ref2 == null) continue;
      final v1 = ref1 - cnt;
      final v2 = ref2 - cnt;
      final d1 = math.sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
      final d2 = math.sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
      if (d1 == 0 || d2 == 0) continue;
      final a1 = math.atan2(v1.dy, v1.dx);
      final a2 = math.atan2(v2.dy, v2.dx);
      var sweep = a2 - a1;
      if (sweep > math.pi) sweep -= 2 * math.pi;
      if (sweep < -math.pi) sweep += 2 * math.pi;
      const arcR = 20.0;
      const n = 12;
      final arcPath = Path();
      for (var i = 0; i <= n; i++) {
        final a = a1 + sweep * i / n;
        final px = cnt.dx + arcR * math.cos(a);
        final py = cnt.dy + arcR * math.sin(a);
        if (i == 0) { arcPath.moveTo(px, py); } else { arcPath.lineTo(px, py); }
      }
      canvas.drawPath(arcPath, Paint()..color = cs.tertiary..style = PaintingStyle.stroke..strokeWidth = 1.5);
      if (arc.label != null && arc.label!.isNotEmpty) {
        final midAngle = a1 + sweep / 2;
        final lx2 = cnt.dx + (arcR + 10) * math.cos(midAngle);
        final ly2 = cnt.dy + (arcR + 10) * math.sin(midAngle);
        pendingLabels.add(_LabelData(arc.label!, lx2, ly2, cs.tertiary));
      }
    }

    // tangents
    for (final tl in tangentLines) {
      final fp2 = toScreen(tl.from.dx, tl.from.dy);
      final tp4 = toScreen(tl.to.dx, tl.to.dy);
      final dashPaint = Paint()..color = cs.outlineVariant..strokeWidth = 1.5;
      const dashLen = 6.0;
      const gapLen = 3.0;
      final ddx = tp4.dx - fp2.dx;
      final ddy = tp4.dy - fp2.dy;
      final tlen = math.sqrt(ddx * ddx + ddy * ddy);
      if (tlen == 0) continue;
      final ux3 = ddx / tlen;
      final uy3 = ddy / tlen;
      var pos = 0.0;
      while (pos < tlen) {
        final seg = (pos + dashLen < tlen) ? dashLen : tlen - pos;
        canvas.drawLine(Offset(fp2.dx + ux3 * pos, fp2.dy + uy3 * pos), Offset(fp2.dx + ux3 * (pos + seg), fp2.dy + uy3 * (pos + seg)), dashPaint);
        pos += dashLen + gapLen;
      }
      canvas.drawCircle(tp4, 3, Paint()..color = cs.onSurfaceVariant);
      if (tl.label != null && tl.label!.isNotEmpty) {
        pendingLabels.add(_LabelData(tl.label!, tp4.dx, tp4.dy - 14, cs.onSurfaceVariant));
      }
    }

    // labels with subtle outline bg
    for (final ld in pendingLabels) {
      final tp = TextPainter(
        text: TextSpan(text: ld.text, style: TextStyle(color: ld.color, fontSize: 11, fontWeight: ld.fontWeight)),
        textDirection: TextDirection.ltr,
      )..layout();
      final bgRect = Rect.fromLTWH(ld.x - tp.width / 2 - 4, ld.y - 1, tp.width + 8, tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(bgRect, const Radius.circular(3)), Paint()..color = cs.surface..style = PaintingStyle.fill);
      canvas.drawRRect(RRect.fromRectAndRadius(bgRect, const Radius.circular(3)), Paint()..color = cs.outlineVariant..style = PaintingStyle.stroke..strokeWidth = 0.5);
      tp.paint(canvas, Offset(ld.x - tp.width / 2, ld.y));
    }
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;
    double pos = 0;
    while (pos < len) {
      final segEnd = (pos + dash < len) ? pos + dash : len;
      canvas.drawLine(Offset(from.dx + ux * pos, from.dy + uy * pos), Offset(from.dx + ux * segEnd, from.dy + uy * segEnd), paint);
      pos += dash + gap;
    }
  }

  void _drawArrowHead(Canvas canvas, Offset tip, Offset base, Color color) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx, base.dy)
      ..lineTo(tip.dx, tip.dy + (base.dy - tip.dy) * 2)
      ..close();
    canvas.drawPath(path, paint);
  }

  String _formatNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }

  double _niceInterval(double range) {
    if (range <= 0) return 1;
    final rough = range / 5;
    final magnitude = _pow10((rough.abs()).toStringAsFixed(0).length - 1);
    final normalized = rough / magnitude;
    if (normalized <= 1.5) return magnitude;
    if (normalized <= 3) return 2 * magnitude;
    if (normalized <= 7) return 5 * magnitude;
    return 10 * magnitude;
  }

  double _pow10(int n) {
    double r = 1;
    for (var i = 0; i < n; i++) { r *= 10; }
    return r;
  }

  @override
  bool shouldRepaint(covariant _GeometryPainter old) => true;
}
