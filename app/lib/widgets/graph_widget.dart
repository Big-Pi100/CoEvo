import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

/// 内联图形渲染组件 — 解析 <graph> JSON 并渲染对应图表
class GraphWidget extends StatelessWidget {
  final String jsonStr;

  const GraphWidget({super.key, required this.jsonStr});

  /// 安全提取 List — 处理 LLM 生成的非标准 JSON（如将数组写成对象）
  static List _safeList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value;
    // LLM 可能把单元素写成对象, 或把 null/数字/字符串当成数组
    return [];
  }

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> data;
    try {
      // 容错：清理 markdown 代码块标记
      String cleaned = jsonStr.trim();
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceFirst(RegExp(r'```\w*\n?'), '');
        cleaned = cleaned.replaceFirst('```', '');
        cleaned = cleaned.trim();
      }
      data = jsonDecode(cleaned) as Map<String, dynamic>;
      data = _normalize(data);
    } catch (_) {
      return _buildError('图形数据解析失败');
    }

    final type = data['type'] as String?;
    if (type == null) return _buildError('缺少 type 字段');

    try {
      switch (type) {
        case 'line':
          return _buildLineChart(data);
        case 'bar':
          return _buildBarChart(data);
        case 'scatter':
          return _buildScatterChart(data);
        case 'pie':
          return _buildPieChart(data);
        case 'polygon':
          return _buildPolygon(data, context);
        case 'circle':
          return _buildCircle(data, context);
        case 'arrow':
          return _buildArrowChart(data, context);
        default:
          return _buildError('不支持的图形类型: $type');
      }
    } catch (e) {
      return _buildError('图形渲染失败: $e');
    }
  }

  // ── fl_chart 折线图 ──
  Widget _buildLineChart(Map<String, dynamic> data) {
    final List rawData = _safeList(data['data']);
    final spots = rawData.map((p) {
      final m = p as Map<String, dynamic>;
      return FlSpot((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    }).toList();
    if (spots.isEmpty) return _buildError('无数据');

    final title = data['title'] as String? ?? '';
    final xlabel = data['xlabel'] as String? ?? '';
    final ylabel = data['ylabel'] as String? ?? '';

    // 自动计算范围
    final xVals = spots.map((s) => s.x);
    final yVals = spots.map((s) => s.y);
    final xMin = xVals.reduce((a, b) => a < b ? a : b);
    final xMax = xVals.reduce((a, b) => a > b ? a : b);
    final yMin = yVals.reduce((a, b) => a < b ? a : b);
    final yMax = yVals.reduce((a, b) => a > b ? a : b);
    final xPad = (xMax - xMin) * 0.05;
    final yPad = (yMax - yMin) * 0.1;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
            child: LineChart(
              LineChartData(
                minX: xMin - xPad,
                maxX: xMax + xPad,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  horizontalInterval: _niceInterval(yMax - yMin),
                  verticalInterval: _niceInterval(xMax - xMin),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    axisNameWidget: xlabel.isEmpty ? null : Text(xlabel, style: const TextStyle(fontSize: 11)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: _niceInterval(xMax - xMin),
                      getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: ylabel.isEmpty ? null : Text(ylabel, style: const TextStyle(fontSize: 11)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: _niceInterval(yMax - yMin),
                      getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: const Color(0xFF6C63FF),
                    barWidth: 2,
                    dotData: FlDotData(show: spots.length <= 20),
                    belowBarData: BarAreaData(
                      show: true,
                      color: const Color(0xFF6C63FF).withAlpha(25),
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => spots.map((s) =>
                      LineTooltipItem('(${s.x.toStringAsFixed(2)}, ${s.y.toStringAsFixed(2)})',
                        const TextStyle(fontSize: 11))).toList(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 柱状图 ──
  Widget _buildBarChart(Map<String, dynamic> data) {
    final List rawData = _safeList(data['data']);
    final groups = rawData.asMap().entries.map((e) {
      final m = e.value as Map<String, dynamic>;
      return BarChartGroupData(
        x: e.key,
        barRods: [BarChartRodData(
          toY: (m['value'] as num).toDouble(),
          color: const Color(0xFF6C63FF),
          width: 16,
        )],
      );
    }).toList();
    if (groups.isEmpty) return _buildError('无数据');

    final labels = rawData.map((p) => (p as Map<String, dynamic>)['label'] as String? ?? '').toList();
    final title = data['title'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
            height: 180,
            child: BarChart(
              BarChartData(
                barGroups: groups,
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        return i < labels.length
                            ? Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(labels[i], style: const TextStyle(fontSize: 10)),
                              )
                            : const SizedBox();
                      },
                    ),
                  ),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 散点图 ──
  Widget _buildScatterChart(Map<String, dynamic> data) {
    final List rawData = _safeList(data['data']);
    final spots = rawData.map((p) {
      final m = p as Map<String, dynamic>;
      return ScatterSpot((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    }).toList();
    if (spots.isEmpty) return _buildError('无数据');

    final xVals = spots.map((s) => s.x);
    final yVals = spots.map((s) => s.y);
    final xMin = xVals.reduce((a, b) => a < b ? a : b);
    final xMax = xVals.reduce((a, b) => a > b ? a : b);
    final yMin = yVals.reduce((a, b) => a < b ? a : b);
    final yMax = yVals.reduce((a, b) => a > b ? a : b);
    final title = data['title'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
            child: ScatterChart(
              ScatterChartData(
                scatterSpots: spots,
                minX: xMin - 1,
                maxX: xMax + 1,
                minY: yMin - 1,
                maxY: yMax + 1,
                scatterTouchData: ScatterTouchData(enabled: true),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 扇形图 ──
  Widget _buildPieChart(Map<String, dynamic> data) {
    final List rawData = _safeList(data['data']);
    final colors = [0xFF6C63FF, 0xFFFF6B6B, 0xFF4ECDC4, 0xFFFFD93D, 0xFFA78BFA, 0xFFFB923C, 0xFF34D399, 0xFF60A5FA];
    final sections = rawData.asMap().entries.map((e) {
      final m = e.value as Map<String, dynamic>;
      return PieChartSectionData(
        value: (m['value'] as num).toDouble(),
        title: '${m['label'] ?? ''}\n${m['value']}',
        color: Color(colors[e.key % colors.length]),
        radius: 55,
        titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
      );
    }).toList();
    if (sections.isEmpty) return _buildError('无数据');

    final title = data['title'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
            child: PieChart(
              PieChartData(
                sections: sections,
                centerSpaceRadius: 30,
                sectionsSpace: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── CustomPainter 多边形 ──
  Widget _buildPolygon(Map<String, dynamic> data, BuildContext context) {
    final List raw = _safeList(data['points']);
    final points = raw.map((p) {
      final m = p as Map<String, dynamic>;
      return Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
    }).toList();
    if (points.length < 2) return _buildError('多边形至少需要 2 个点');

    final title = data['title'] as String? ?? '';
    // 顶点标签
    final rawLabels = _safeList(data['labels']);
    final labels = rawLabels?.map((l) => l.toString()).toList() ?? <String>[];
    // 直角顶点索引
    final rawAngles = _safeList(data['rightAngles']);
    final rightAngles = rawAngles?.map((a) => a as int).toSet() ?? <int>{};
    // 角度弧线: [{"vertex":0,"label":"30°","startAngle":0,"sweepAngle":30}]
    final rawAngleArcs = _safeList(data['angles']);
    final angleArcs = rawAngleArcs?.map((a) {
      final m = a as Map<String, dynamic>;
      return _AngleArc(
        vertexIndex: m['vertex'] as int,
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
    final center = data['center'] as Map<String, dynamic>?;
    final cx = (center?['x'] as num?)?.toDouble() ?? 0;
    final cy = (center?['y'] as num?)?.toDouble() ?? 0;
    final radius = (data['radius'] as num?)?.toDouble() ?? 1;
    final title = data['title'] as String? ?? '';
    // 切线: [{"from":{"x":-5,"y":0},"to":{"x":-3,"y":0}}]
    final rawTangents = _safeList(data['tangents']);
    final tangents = rawTangents?.map((t) {
      final m = t as Map<String, dynamic>;
      final from = m['from'] as Map<String, dynamic>;
      final to = m['to'] as Map<String, dynamic>;
      return _ArrowData(
        from: Offset((from['x'] as num).toDouble(), (from['y'] as num).toDouble()),
        to: Offset((to['x'] as num).toDouble(), (to['y'] as num).toDouble()),
        label: m['label'] as String?,
      );
    }).toList() ?? <_ArrowData>[];
    // 圆上角度弧线标记
    final rawAngleArcs2 = _safeList(data['angles']);
    final angleArcs2 = rawAngleArcs2?.map((a) {
      final m = a as Map<String, dynamic>;
      return _AngleArc(
        vertexIndex: m['vertex'] as int?,
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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

  // ── 箭头图：向量、力分析 ──
  Widget _buildArrowChart(Map<String, dynamic> data, BuildContext context) {
    final List raw = _safeList(data['arrows']);
    final arrows = raw.map((a) {
      final m = a as Map<String, dynamic>;
      final from = m['from'] as Map<String, dynamic>;
      final to = m['to'] as Map<String, dynamic>;
      return _ArrowData(
        from: Offset((from['x'] as num).toDouble(), (from['y'] as num).toDouble()),
        to: Offset((to['x'] as num).toDouble(), (to['y'] as num).toDouble()),
        label: m['label'] as String?,
        color: _parseColor(m['color'] as String?),
      );
    }).toList();
    if (arrows.isEmpty) return _buildError('无箭头数据');

    final title = data['title'] as String? ?? '';

    // 自动计算视口
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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

  Widget _buildError(String msg) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, size: 16, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Text('📊 $msg', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
        ],
      ),
    );
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
    for (var i = 0; i < n; i++) r *= 10;
    return r;
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFF6C63FF);
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
    return const Color(0xFF6C63FF);
  }

  /// 归一化 LLM 常见的格式变体
  static Map<String, dynamic> _normalize(Map<String, dynamic> raw) {
    final m = Map<String, dynamic>.from(raw);

    // label → title (当 title 缺失时)
    if (!m.containsKey('title') && m.containsKey('label')) {
      m['title'] = m['label'];
    }

    // options.xLabel → xlabel
    if (m['options'] is Map) {
      final opts = m['options'] as Map<String, dynamic>;
      if (!m.containsKey('xlabel') && opts.containsKey('xLabel')) m['xlabel'] = opts['xLabel'];
      if (!m.containsKey('ylabel') && opts.containsKey('yLabel')) m['ylabel'] = opts['yLabel'];
      if (!m.containsKey('title') && opts.containsKey('title')) m['title'] = opts['title'];
    }

    // center: [x, y] → {"x": x, "y": y}
    if (m['center'] is List) {
      final arr = m['center'] as List;
      if (arr.length >= 2) m['center'] = {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
    }

    // data: [[x, y], ...] → [{"x": x, "y": y}, ...]
    if (m['data'] is List && (m['data'] as List).isNotEmpty) {
      final first = (m['data'] as List).first;
      if (first is List && !(first is Map)) {
        m['data'] = (m['data'] as List).map((e) {
          final arr = e as List;
          return {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
        }).toList();
      }
    }

    // 归一化 data 中的元素: {x, y} 可能缺少其中一者
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

    // points: [[x, y], ...] → [{"x": x, "y": y}, ...]
    if (m['points'] is List && (m['points'] as List).isNotEmpty) {
      final first = (m['points'] as List).first;
      if (first is List) {
        m['points'] = (m['points'] as List).map((e) {
          final arr = e as List;
          return {'x': num.tryParse(arr[0].toString()) ?? 0, 'y': num.tryParse(arr[1].toString()) ?? 0};
        }).toList();
      }
    }

    // arrows: {from, to} 中的坐标也可能用数组
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

/// 几何图形绘制器：多边形 / 圆形 / 坐标轴
class _GeometryPainter extends CustomPainter {
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

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 30.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    final scaleX = (xMax - xMin) == 0 ? 1 : w / (xMax - xMin);
    final scaleY = (yMax - yMin) == 0 ? 1 : h / (yMax - yMin);
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final cx = pad + w / 2 - (xMin + (xMax - xMin) / 2) * scale;
    final cy = pad + h / 2 + (yMin + (yMax - yMin) / 2) * scale;

    Offset toScreen(double x, double y) => Offset(cx + x * scale, cy - y * scale);

    // 预先计算屏幕坐标点
    final screenPoints = points.map((p) => toScreen(p.dx, p.dy)).toList();

    // 坐标轴
    final axisPaint = Paint()..color = Colors.grey.shade400..strokeWidth = 0.5;
    final origin = toScreen(0, 0);
    canvas.drawLine(Offset(pad, origin.dy), Offset(size.width - pad, origin.dy), axisPaint);
    canvas.drawLine(Offset(origin.dx, pad), Offset(origin.dx, size.height - pad), axisPaint);

    // 圆形
    if (circleCenter != null && circleRadius != null) {
      final cc = toScreen(circleCenter!.dx, circleCenter!.dy);
      final r = circleRadius! * scale;
      final circlePaint = Paint()
        ..color = const Color(0xFF6C63FF).withAlpha(40)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(cc, r, circlePaint);
      final strokePaint = Paint()
        ..color = const Color(0xFF6C63FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(cc, r, strokePaint);
      // 圆心点
      canvas.drawCircle(cc, 3, Paint()..color = const Color(0xFF6C63FF));
      return;
    }

    // 多边形
    if (points.length >= 2) {
      final path = Path();
      path.moveTo(screenPoints[0].dx, screenPoints[0].dy);
      for (var i = 1; i < screenPoints.length; i++) {
        path.lineTo(screenPoints[i].dx, screenPoints[i].dy);
      }
      if (drawClosed) path.close();

      final fillPaint = Paint()
        ..color = const Color(0xFF6C63FF).withAlpha(30)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, fillPaint);

      final strokePaint = Paint()
        ..color = const Color(0xFF6C63FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawPath(path, strokePaint);

      // 顶点标注
      for (final sp in screenPoints) {
        canvas.drawCircle(sp, 3, Paint()..color = const Color(0xFF6C63FF));
      }

      // 顶点标签
      for (var i = 0; i < screenPoints.length && i < labels.length; i++) {
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: const TextStyle(color: Color(0xFF6C63FF), fontSize: 12, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        final lp = screenPoints[i];
        // 标签偏移到顶点外侧
        final cx2 = screenPoints.fold(Offset.zero, (a, b) => a + b) / screenPoints.length.toDouble();
        final dx = lp.dx - cx2.dx;
        final dy = lp.dy - cx2.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final ox = dist > 0 ? dx / dist * 18 : 0;
        final oy = dist > 0 ? dy / dist * 18 : 0;
        tp.paint(canvas, Offset(lp.dx + ox - tp.width / 2, lp.dy + oy - tp.height / 2));
      }

      // 直角标记
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
        canvas.drawPath(markPath, Paint()..color = const Color(0xFF6C63FF)..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }

    // ── 箭头绘制 ──
    for (final arrow in arrows) {
      final fp = toScreen(arrow.from.dx, arrow.from.dy);
      final tp = toScreen(arrow.to.dx, arrow.to.dy);
      final color = arrow.color ?? const Color(0xFF6C63FF);

      // 箭身
      canvas.drawLine(fp, tp, Paint()..color = color..strokeWidth = 2.5..strokeCap = StrokeCap.round);

      // 箭头（三角形）
      final dx = tp.dx - fp.dx;
      final dy = tp.dy - fp.dy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;      final ux = dx / len;
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

      // 起点圆点
      canvas.drawCircle(fp, 3.5, Paint()..color = color);

      // 标签
      if (arrow.label != null && arrow.label!.isNotEmpty) {
        final tp2 = TextPainter(
          text: TextSpan(text: arrow.label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = (fp.dx + tp.dx) / 2 - tp2.width / 2;
        final ly = (fp.dy + tp.dy) / 2 - tp2.height - 4;
        tp2.paint(canvas, Offset(lx, ly));
      }
    }

    // ── 角度弧线 ──
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
      canvas.drawPath(arcPath, Paint()..color = Colors.orange..style = PaintingStyle.stroke..strokeWidth = 1.5);

      // 弧线标签
      if (arc.label != null && arc.label!.isNotEmpty) {
        final midAngle = a1 + sweep / 2;
        final lx2 = cnt.dx + (arcR + 10) * math.cos(midAngle);
        final ly2 = cnt.dy + (arcR + 10) * math.sin(midAngle);
        final tp3 = TextPainter(
          text: TextSpan(text: arc.label, style: const TextStyle(color: Colors.orange, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp3.paint(canvas, Offset(lx2 - tp3.width / 2, ly2 - tp3.height / 2));
      }
    }

    // ── 切线 ──
    for (final tl in tangentLines) {
      final fp2 = toScreen(tl.from.dx, tl.from.dy);
      final tp4 = toScreen(tl.to.dx, tl.to.dy);
      final dashPaint = Paint()..color = Colors.grey.shade500..strokeWidth = 1.5;
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
        canvas.drawLine(
          Offset(fp2.dx + ux3 * pos, fp2.dy + uy3 * pos),
          Offset(fp2.dx + ux3 * (pos + seg), fp2.dy + uy3 * (pos + seg)),
          dashPaint,
        );
        pos += dashLen + gapLen;
      }
      canvas.drawCircle(tp4, 3, Paint()..color = Colors.grey.shade600);
      if (tl.label != null && tl.label!.isNotEmpty) {
        final tp5 = TextPainter(
          text: TextSpan(text: tl.label, style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp5.paint(canvas, Offset(tp4.dx - tp5.width / 2, tp4.dy - tp5.height - 6));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GeometryPainter old) => true;
}
