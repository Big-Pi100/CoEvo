// ignore_for_file: invalid_null_aware_operator, unnecessary_cast
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fl_chart/fl_chart.dart' as fl;
import '../utils/math_expr.dart';

/// 图表调色板（8 色）
const _chartColors = [
  Color(0xFF378ADD),
  Color(0xFFD85A30),
  Color(0xFF639922),
  Color(0xFF7F77DD),
  Color(0xFFEF9F27),
  Color(0xFF1D9E75),
  Color(0xFFD4537E),
  Color(0xFF5F5E5A),
];

/// 内联图形渲染组件 — 优先渲染 SVG，降级解析 `<graph>` JSON
class GraphWidget extends StatelessWidget {
  final String jsonStr;

  const GraphWidget({super.key, required this.jsonStr});

  @override
  Widget build(BuildContext context) {
    final _cs = Theme.of(context).colorScheme;
    final content = jsonStr.trim();

    // 检测是否为 SVG
    if (content.startsWith('<svg') || content.startsWith('<svg ') || content.startsWith('<?xml')) {
      return _buildSvg(content, _cs);
    }

    // 否则按 JSON 解析（原有逻辑）
    return _buildJsonGraph(content, _cs, context);
  }

  /// SVG 渲染
  Widget _buildSvg(String svgContent, ColorScheme cs) {
    try {
      // 提取 <svg>...</svg>
      final start = svgContent.indexOf('<svg');
      final end = svgContent.lastIndexOf('</svg>');
      if (start < 0 || end < 0) return _buildError('SVG 格式不正确', cs);
      var cleanSvg = svgContent.substring(start, end + 6);
      // 兜底：所有 <text> 加上 paint-order（LLM 可能忘记加），不加描边
      if (!cleanSvg.contains('paint-order="stroke fill"') && !cleanSvg.contains('paint-order="fill"')) {
        cleanSvg = cleanSvg.replaceAllMapped(
          RegExp(r'<text\b', caseSensitive: false),
          (m) => '${m.group(0)} paint-order="fill"',
        );
      }
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SvgPicture.string(
            cleanSvg,
            width: double.infinity,
            height: 240,
            fit: BoxFit.contain,
            placeholderBuilder: (_) => const SizedBox(height: 240, child: Center(child: Text('加载中...'))),
          ),
        ),
      );
    } catch (e) {
      return _buildError('SVG 渲染失败: $e', cs);
    }
  }

  /// JSON 图形渲染（原有 fl_chart + canvas 逻辑）
  Widget _buildJsonGraph(String content, ColorScheme cs, BuildContext context) {
    Map<String, dynamic> data;
    try {
      String cleaned = content;
      cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?', multiLine: true), '');
      cleaned = cleaned.replaceAll('```', '').trim();
      final braceStart = cleaned.indexOf('{');
      final braceEnd = cleaned.lastIndexOf('}');
      if (braceStart >= 0 && braceEnd > braceStart) {
        cleaned = cleaned.substring(braceStart, braceEnd + 1);
      }
      data = jsonDecode(cleaned) as Map<String, dynamic>;
      data = _normalize(data);
    } catch (e) {
      return _buildError('图形数据解析失败\n$e', cs);
    }

    final type = data['type'] as String?;
    if (type == null) return _buildError('缺少 type 字段', cs);

    try {
      switch (type) {
        case 'line':
          return _buildGraphicLine(data, cs);
        case 'bar':
          return _buildGraphicBar(data, cs);
        case 'scatter':
          return _buildGraphicScatter(data, cs);
        case 'pie':
          return _buildGraphicPie(data, cs);
        case 'polygon':
          return _buildPolygon(data, context);
        case 'circle':
          return _buildCircle(data, context);
        case 'arrow':
          return _buildArrowChart(data, context);
        case 'canvas':
          return _buildCanvas(data, context);
        case 'function':
          return _buildFunctionGraph(data, context);
        default:
          return _buildError('不支持的图形类型: $type', cs);
      }
    } catch (e) {
      return _buildError('图形渲染失败: $e', cs);
    }
  }

  // ── fl_chart 折线图 ──
  Widget _buildGraphicLine(Map<String, dynamic> data, ColorScheme cs) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', cs);
    final title = data['title'] as String? ?? '';
    final xlabel = data['xlabel'] as String? ?? '';
    final ylabel = data['ylabel'] as String? ?? '';

    // 支持 datasets 数组（多组折线）或单组 data
    final rawDataSets = _safeList(data['datasets']);
    final hasMultiple = rawDataSets.length >= 2;

    List<fl.LineChartBarData> lineBars;
    if (hasMultiple) {
      lineBars = rawDataSets.asMap().entries.map((e) {
        final ds = e.value as Map<String, dynamic>;
        final pts = _safeList(ds['data']).map((p) {
          final m = p as Map<String, dynamic>;
          return fl.FlSpot(_safeDouble(m['x']), _safeDouble(m['y']));
        }).toList();
        return fl.LineChartBarData(
          spots: pts,
          isCurved: true,
          color: _chartColors[e.key % _chartColors.length],
          barWidth: 2,
          dotData: const fl.FlDotData(show: false),
          belowBarData: fl.BarAreaData(show: true, color: _chartColors[e.key % _chartColors.length].withAlpha(25)),
        );
      }).toList();
    } else {
      final spots = list.map((p) {
        final m = p as Map<String, dynamic>;
        return fl.FlSpot(_safeDouble(m['x']), _safeDouble(m['y']));
      }).toList();
      lineBars = [
        fl.LineChartBarData(
          spots: spots,
          isCurved: true,
          color: cs.primary,
          barWidth: 2,
          dotData: fl.FlDotData(show: spots.length <= 20),
          belowBarData: fl.BarAreaData(show: true, color: cs.primary.withAlpha(25)),
        ),
      ];
    }

    // 计算范围
    final allSpots = lineBars.expand((b) => b.spots).toList();
    if (allSpots.isEmpty) return _buildError('无数据点', cs);
    final xVals = allSpots.map((s) => s.x);
    final yVals = allSpots.map((s) => s.y);
    final xMin = xVals.reduce((a, b) => a < b ? a : b);
    final xMax = xVals.reduce((a, b) => a > b ? a : b);
    final yMin = yVals.reduce((a, b) => a < b ? a : b);
    final yMax = yVals.reduce((a, b) => a > b ? a : b);
    final xPad = (xMax - xMin) * 0.05;
    final yPad = (yMax - yMin) * 0.1;
    if (xPad == 0 && yPad == 0) { /* single point */ }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(4, 12, 16, 8),
      decoration: _chartBoxDeco(cs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: fl.LineChart(
              fl.LineChartData(
                minX: xMin - xPad,
                maxX: xMax + xPad,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                gridData: fl.FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  horizontalInterval: _niceInterval(yMax - yMin),
                  verticalInterval: _niceInterval(xMax - xMin),
                  getDrawingHorizontalLine: (_) => fl.FlLine(color: cs.outlineVariant.withAlpha(60), strokeWidth: 0.5),
                  getDrawingVerticalLine: (_) => fl.FlLine(color: cs.outlineVariant.withAlpha(60), strokeWidth: 0.5),
                ),
                titlesData: fl.FlTitlesData(
                  bottomTitles: fl.AxisTitles(
                    axisNameWidget: xlabel.isEmpty ? null : Text(xlabel, style: TextStyle(fontSize: 11, color: cs.outline)),
                    sideTitles: fl.SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      interval: _niceInterval(xMax - xMin),
                      getTitlesWidget: (v, _) => Text(_fmtTick(v), style: TextStyle(fontSize: 11, color: cs.outline)),
                    ),
                  ),
                  leftTitles: fl.AxisTitles(
                    axisNameWidget: ylabel.isEmpty ? null : Text(ylabel, style: TextStyle(fontSize: 11, color: cs.outline)),
                    sideTitles: fl.SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      interval: _niceInterval(yMax - yMin),
                      getTitlesWidget: (v, _) => Text(_fmtTick(v), style: TextStyle(fontSize: 11, color: cs.outline)),
                    ),
                  ),
                  topTitles: fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                  rightTitles: fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                ),
                lineBarsData: lineBars,
                lineTouchData: fl.LineTouchData(
                  touchTooltipData: fl.LineTouchTooltipData(
                    getTooltipItems: (spots) => spots.map((s) =>
                      fl.LineTooltipItem('(${_fmtTick(s.x)}, ${_fmtTick(s.y)})',
                        const TextStyle(fontSize: 11, color: Colors.white))).toList(),
                  ),
                ),
                borderData: fl.FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 柱状图 ──
  Widget _buildGraphicBar(Map<String, dynamic> data, ColorScheme cs) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', cs);
    final title = data['title'] as String? ?? '';
    final labels = list.map((p) => (p as Map<String, dynamic>)['label'] as String? ?? '').toList();
    final groups = list.asMap().entries.map((e) {
      final m = e.value as Map<String, dynamic>;
      return fl.BarChartGroupData(
        x: e.key,
        barRods: [fl.BarChartRodData(
          toY: _safeDouble(m['value']),
          color: _chartColors[e.key % _chartColors.length],
          width: 16,
        )],
      );
    }).toList();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(4, 12, 16, 8),
      decoration: _chartBoxDeco(cs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: fl.BarChart(
              fl.BarChartData(
                barGroups: groups,
                gridData: const fl.FlGridData(show: true, drawVerticalLine: false),
                titlesData: fl.FlTitlesData(
                  bottomTitles: fl.AxisTitles(
                    sideTitles: fl.SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        return i < labels.length
                            ? Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(labels[i], style: TextStyle(fontSize: 10, color: cs.outline)),
                              )
                            : const SizedBox();
                      },
                    ),
                  ),
                  leftTitles: fl.AxisTitles(
                    sideTitles: fl.SideTitles(showTitles: true, reservedSize: 32,
                      getTitlesWidget: (v, _) => Text(_fmtTick(v), style: TextStyle(fontSize: 11, color: cs.outline))),
                  ),
                  topTitles: const fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                  rightTitles: const fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                ),
                borderData: fl.FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 散点图 ──
  Widget _buildGraphicScatter(Map<String, dynamic> data, ColorScheme cs) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', cs);
    final title = data['title'] as String? ?? '';
    final spots = list.asMap().entries.map((e) {
      final m = e.value as Map<String, dynamic>;
      return fl.ScatterSpot(_safeDouble(m['x']), _safeDouble(m['y']));
    }).toList();
    final xVals = spots.map((s) => s.x);
    final yVals = spots.map((s) => s.y);
    final xMin = xVals.reduce((a, b) => a < b ? a : b);
    final xMax = xVals.reduce((a, b) => a > b ? a : b);
    final yMin = yVals.reduce((a, b) => a < b ? a : b);
    final yMax = yVals.reduce((a, b) => a > b ? a : b);
    final xPad = (xMax - xMin) * 0.1;
    final yPad = (yMax - yMin) * 0.1;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(4, 12, 16, 8),
      decoration: _chartBoxDeco(cs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: fl.ScatterChart(
              fl.ScatterChartData(
                scatterSpots: spots,
                minX: xMin - xPad,
                maxX: xMax + xPad,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                gridData: const fl.FlGridData(show: true, drawVerticalLine: true),
                titlesData: fl.FlTitlesData(
                  bottomTitles: fl.AxisTitles(
                    sideTitles: fl.SideTitles(showTitles: true, reservedSize: 32,
                      getTitlesWidget: (v, _) => Text(_fmtTick(v), style: TextStyle(fontSize: 11, color: cs.outline))),
                  ),
                  leftTitles: fl.AxisTitles(
                    sideTitles: fl.SideTitles(showTitles: true, reservedSize: 36,
                      getTitlesWidget: (v, _) => Text(_fmtTick(v), style: TextStyle(fontSize: 11, color: cs.outline))),
                  ),
                  topTitles: const fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                  rightTitles: const fl.AxisTitles(sideTitles: fl.SideTitles(showTitles: false)),
                ),
                borderData: fl.FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── fl_chart 饼图 ──
  Widget _buildGraphicPie(Map<String, dynamic> data, ColorScheme cs) {
    final list = _safeList(data['data']);
    if (list.isEmpty) return _buildError('无数据', cs);
    final title = data['title'] as String? ?? '';
    final sections = list.asMap().entries.map((e) {
      final m = e.value as Map<String, dynamic>;
      return fl.PieChartSectionData(
        value: _safeDouble(m['value']),
        title: '${m['label'] ?? ''}\n${_fmtTick(_safeDouble(m['value']))}',
        color: _chartColors[e.key % _chartColors.length],
        radius: 55,
        titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
      );
    }).toList();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(4, 12, 16, 8),
      decoration: _chartBoxDeco(cs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          SizedBox(height: 200,
            child: fl.PieChart(
              fl.PieChartData(sections: sections),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTick(double v) {
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

  BoxDecoration _chartBoxDeco(ColorScheme cs) {
    return BoxDecoration(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.outlineVariant),
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

  // ── 函数图像 (function type) — 用纯 Dart 求值器计算函数值，生成 SVG ──
  Widget _buildFunctionGraph(Map<String, dynamic> data, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    try {
      final xRange = data['xRange'] as List? ?? [-5, 5];
      final yRange = data['yRange'] as List? ?? [-5, 5];
      final xMin = _safeDouble(xRange[0], -5);
      final xMax = _safeDouble(xRange[1], 5);
      final yMin = _safeDouble(yRange[0], -5);
      final yMax = _safeDouble(yRange[1], 5);
      final rawFuncs = _safeList(data['functions']);
      if (rawFuncs.isEmpty) return _buildError('函数图像：无函数表达式', cs);
      final specialPoints = _safeList(data['specialPoints']);
      final showGrid = data['grid'] != false;
      final funcColors = ['#4285F4', '#EA4335', '#34A853', '#FBBC04', '#A142F4', '#46BDC6'];
      // 计算物理像素范围
      const pad = 50;
      const w = 360 - pad * 2;
      const h = 280 - pad * 2;
      // SVG 坐标系 (0,0) 对应 (pad, pad+h)
      double toSvgX(double x) => pad + ((x - xMin) / (xMax - xMin)) * w;
      double toSvgY(double y) => (pad + h) - ((y - yMin) / (yMax - yMin)) * h;
      var svg = '<svg viewBox="0 0 360 280" xmlns="http://www.w3.org/2000/svg">';
      // 坐标轴
      final ox = toSvgX(0).clamp(pad.toDouble(), (pad + w).toDouble());
      final oy = toSvgY(0).clamp(pad.toDouble(), (pad + h).toDouble());
      svg += '<line x1="$pad" y1="$oy" x2="${pad + w}" y2="$oy" stroke="#333" stroke-width="1.5"/>';
      svg += '<line x1="$ox" y1="$pad" x2="$ox" y2="${pad + h}" stroke="#333" stroke-width="1.5"/>';
      svg += '<text x="${pad + w + 4}" y="${oy + 4}" font-size="11" fill="#333">x</text>';
      svg += '<text x="${ox + 4}" y="${pad - 4}" font-size="11" fill="#333">y</text>';
      // 网格
      if (showGrid) {
        for (var x = (xMin / 1).ceil() * 1.0; x <= xMax; x += 1) {
          final sx = toSvgX(x);
          if (sx >= pad && sx <= pad + w) {
            svg += '<line x1="$sx" y1="$pad" x2="$sx" y2="${pad + h}" stroke="#ddd" stroke-width="0.5" stroke-dasharray="2,2"/>';
            if (x != 0) svg += '<text x="$sx" y="${oy + 14}" text-anchor="middle" font-size="9" fill="#999">${x.toInt()}</text>';
          }
        }
        for (var y = (yMin / 1).ceil() * 1.0; y <= yMax; y += 1) {
          final sy = toSvgY(y);
          if (sy >= pad && sy <= pad + h) {
            svg += '<line x1="$pad" y1="$sy" x2="${pad + w}" y2="$sy" stroke="#ddd" stroke-width="0.5" stroke-dasharray="2,2"/>';
            if (y != 0) svg += '<text x="${ox - 8}" y="${sy + 3}" text-anchor="end" font-size="9" fill="#999">${y.toInt()}</text>';
          }
        }
      }
      // 函数曲线
      const sampleCount = 40;
      for (var fi = 0; fi < rawFuncs.length; fi++) {
        final f = rawFuncs[fi] as Map<String, dynamic>;
        final expr = f['expr'] as String? ?? '';
        final color = f['color'] as String? ?? funcColors[fi % funcColors.length];
        final label = f['label'] as String? ?? '';
        // 采样点（用纯 Dart 求值器，替代原 web-only 的 `js.context.eval`）
        final pts = <String>[];
        for (var i = 0; i <= sampleCount; i++) {
          final x = xMin + (xMax - xMin) * i / sampleCount;
          final y = evalMathExpr(expr, x);
          if (y != null && y.isFinite && y >= yMin && y <= yMax) {
            pts.add('${toSvgX(x).toStringAsFixed(1)},${toSvgY(y).toStringAsFixed(1)}');
          }
        }
        if (pts.length >= 2) {
          svg += '<polyline points="${pts.join(' ')}" fill="none" stroke="$color" stroke-width="2"/>';
          if (label.isNotEmpty) {
            // 在曲线末端附近标注
            final lastX = xMin + (xMax - xMin) * 0.85;
            final lastY = evalMathExpr(expr, lastX);
            if (lastY != null && lastY.isFinite) {
              final ly = lastY.clamp(yMin, yMax);
              svg += '<text x="${toSvgX(lastX) + 6}" y="${toSvgY(ly) + 4}" fill="$color" font-size="11" paint-order="stroke fill" stroke="white" stroke-width="1.5">$label</text>';
            }
          }
        }
      }
      // 特殊点
      for (final sp in specialPoints) {
        final arr = sp as List;
        if (arr.length >= 2) {
          final sx = toSvgX(_safeDouble(arr[0]));
          final sy = toSvgY(_safeDouble(arr[1]));
          svg += '<circle cx="$sx" cy="$sy" r="4" fill="#D32F2F"/>';
          svg += '<text x="${sx + 6}" y="${sy + 4}" font-size="10" fill="#D32F2F" paint-order="stroke fill" stroke="white" stroke-width="1.5">(${arr[0]}, ${arr[1]})</text>';
        }
      }
      svg += '</svg>';
      // 用已有 SVG 渲染器
      return _buildSvg(svg, cs);
    } catch (e) {
      return _buildError('函数图像渲染失败: $e', cs);
    }
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

  // ── Canvas: 复合图形容器（scripts 数组），LLM 用于几何教学组合图 ──
  Widget _buildCanvas(Map<String, dynamic> data, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scripts = _safeList(data['scripts']);
    if (scripts.isEmpty) return _buildError('canvas 无 scripts', cs);

    // 收集所有坐标用于自动缩放
    var xMin = double.infinity, xMax = double.negativeInfinity;
    var yMin = double.infinity, yMax = double.negativeInfinity;
    for (final s in scripts) {
      final m = s as Map<String, dynamic>;
      final t = m['type'] as String?;
      if (t == 'line') {
        final start = m['start'] as List? ?? [];
        final end = m['end'] as List? ?? [];
        if (start.length >= 2) { final x = _safeDouble(start[0]); final y = _safeDouble(start[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        if (end.length >= 2) { final x = _safeDouble(end[0]); final y = _safeDouble(end[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
      } else if (t == 'polygon' || t == 'polyline') {
        final verts = _safeList(m['vertices'] ?? m['points']);
        for (final v in verts) {
          final arr = v as List;
          if (arr.length >= 2) { final x = _safeDouble(arr[0]); final y = _safeDouble(arr[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        }
      } else if (t == 'circle') {
        final center = m['center'] as List? ?? [];
        if (center.length >= 2) { final x = _safeDouble(center[0]); final y = _safeDouble(center[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        final r = _safeDouble(m['radius'], 1);
        if (xMin < double.infinity) { xMin -= r; xMax += r; yMin -= r; yMax += r; }
      } else if (t == 'arrow') {
        final from = m['from'] as List? ?? [];
        final to = m['to'] as List? ?? [];
        if (from.length >= 2) { final x = _safeDouble(from[0]); final y = _safeDouble(from[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        if (to.length >= 2) { final x = _safeDouble(to[0]); final y = _safeDouble(to[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
      } else if (t == 'rect') {
        final tl = m['topLeft'] as List? ?? m['p1'] as List?;
        final br = m['bottomRight'] as List? ?? m['p2'] as List?;
        if (tl != null && tl.length >= 2) { final x = _safeDouble(tl[0]); final y = _safeDouble(tl[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        if (br != null && br.length >= 2) { final x = _safeDouble(br[0]); final y = _safeDouble(br[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
      } else if (t == 'ellipse') {
        final center = m['center'] as List? ?? [];
        if (center.length >= 2) { final x = _safeDouble(center[0]); final y = _safeDouble(center[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
        final rx = _safeDouble(m['rx'] ?? m['radiusX'], 1);
        final ry = _safeDouble(m['ry'] ?? m['radiusY'], 1);
        if (xMin < double.infinity) { xMin -= rx; xMax += rx; yMin -= ry; yMax += ry; }
      } else if (t == 'point') {
        final pos = m['position'] as List? ?? m['pos'] as List?;
        if (pos != null && pos.length >= 2) { final x = _safeDouble(pos[0]); final y = _safeDouble(pos[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
      } else if (t == 'text') {
        final pos = m['position'] as List? ?? m['pos'] as List?;
        if (pos != null && pos.length >= 2) { final x = _safeDouble(pos[0]); final y = _safeDouble(pos[1]); if (x < xMin) xMin = x; if (x > xMax) xMax = x; if (y < yMin) yMin = y; if (y > yMax) yMax = y; }
      }
    }
    if (xMin == double.infinity) { xMin = 0; xMax = 200; yMin = 0; yMax = 200; }
    final pad = (xMax - xMin + yMax - yMin) * 0.1 + 1;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: SizedBox(
        height: 240,
        child: CustomPaint(
          size: const Size(double.infinity, 240),
          painter: _CanvasPainter(
            cs: cs,
            scripts: scripts,
            xMin: xMin - pad, xMax: xMax + pad,
            yMin: yMin - pad, yMax: yMax + pad,
          ),
        ),
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

/// Canvas 绘制器：遍历 scripts 数组，渲染组合图形
class _CanvasPainter extends CustomPainter {
  final ColorScheme cs;
  final List<dynamic> scripts;
  final double xMin, xMax, yMin, yMax;

  _CanvasPainter({
    required this.cs,
    required this.scripts,
    required this.xMin, required this.xMax,
    required this.yMin, required this.yMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 40.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    final xRange = xMax - xMin;
    final yRange = yMax - yMin;
    final scaleX = xRange == 0 ? 1 : w / xRange;
    final scaleY = yRange == 0 ? 1 : h / yRange;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final cx = pad + w / 2 - (xMin + xRange / 2) * scale;
    final cy = pad + h / 2 + (yMin + yRange / 2) * scale;

    Offset toScreen(double x, double y) => Offset(cx + x * scale, cy - y * scale);

    for (final raw in scripts) {
      final m = raw as Map<String, dynamic>;
      final t = m['type'] as String? ?? '';
      final color = _parseColor(m['color'] as String?, cs);
      final label = m['label'] as String?;
      final filled = m['filled'] == true;
      final opacity = _safeDouble(m['opacity'], 1.0);
      final dash = m['dash'] == true;
      final thick = m['thick'] == true;
      final strokeWidth = thick ? 3.5 : 2.0;

      try {
        switch (t) {
          case 'point': {
            final pos = _safeList(m['position'] ?? m['pos']);
            if (pos.length >= 2) {
              final pt = toScreen(_safeDouble(pos[0]), _safeDouble(pos[1]));
              canvas.drawCircle(pt, 4, Paint()..color = color..style = PaintingStyle.fill);
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, pt + const Offset(10, -10), color);
              }
            }
            break;
          }
          case 'line': {
            final start = _safeList(m['start']);
            final end = _safeList(m['end']);
            if (start.length >= 2 && end.length >= 2) {
              final p1 = toScreen(_safeDouble(start[0]), _safeDouble(start[1]));
              final p2 = toScreen(_safeDouble(end[0]), _safeDouble(end[1]));
              final paint = Paint()
                ..color = color
                ..strokeWidth = strokeWidth
                ..strokeCap = StrokeCap.round;
              if (dash) {
                _drawDashedLine(canvas, p1, p2, paint);
              } else {
                canvas.drawLine(p1, p2, paint);
              }
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, (p1 + p2) / 2 + const Offset(0, -14), color);
              }
            }
            break;
          }
          case 'polygon':
          case 'polyline': {
            final verts = _safeList(m['vertices'] ?? m['points']);
            if (verts.length >= 2) {
              final pts = verts.map((v) {
                final arr = v as List;
                return toScreen(_safeDouble(arr[0]), _safeDouble(arr[1]));
              }).toList();
              final path = Path()..moveTo(pts[0].dx, pts[0].dy);
              for (var i = 1; i < pts.length; i++) {
                path.lineTo(pts[i].dx, pts[i].dy);
              }
              final closePath = t == 'polygon';
              if (closePath) path.close();
              final drawPaint = Paint()
                ..color = color.withAlpha((opacity * 255).round())
                ..strokeWidth = strokeWidth
                ..style = closePath && filled ? PaintingStyle.fill : PaintingStyle.stroke;
              canvas.drawPath(path, drawPaint);
              // 描边
              if (!closePath || !filled || dash) {
                canvas.drawPath(path, Paint()
                  ..color = color
                  ..strokeWidth = strokeWidth
                  ..style = PaintingStyle.stroke);
              }
              if (label != null && label.isNotEmpty) {
                final center = pts.fold(Offset.zero, (a, b) => a + b) / pts.length.toDouble();
                _drawCanvasLabel(canvas, label, center + const Offset(0, -16), color);
              }
            }
            break;
          }
          case 'circle': {
            final centerArr = _safeList(m['center']);
            if (centerArr.length >= 2) {
              final cc = toScreen(_safeDouble(centerArr[0]), _safeDouble(centerArr[1]));
              final r = _safeDouble(m['radius'], 1) * scale;
              final paint = Paint()
                ..color = color.withAlpha((opacity * 255).round())
                ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
                ..strokeWidth = strokeWidth;
              if (dash) {
                _drawDashedCircle(canvas, cc, r, paint);
                if (filled) {
                  canvas.drawCircle(cc, r, Paint()
                    ..color = color.withAlpha((opacity * 100).round())
                    ..style = PaintingStyle.fill);
                }
              } else {
                canvas.drawCircle(cc, r, paint);
                if (filled) {
                  canvas.drawCircle(cc, r, Paint()
                    ..color = color..style = PaintingStyle.stroke..strokeWidth = strokeWidth);
                }
              }
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, cc + Offset(r + 10, 0), color);
              }
            }
            break;
          }
          case 'arrow': {
            // 兼容 start/end 和 from/to
            final fromArr = _safeList(m['from'] ?? m['start']);
            final toArr = _safeList(m['to'] ?? m['end']);
            if (fromArr.length >= 2 && toArr.length >= 2) {
              final fp = toScreen(_safeDouble(fromArr[0]), _safeDouble(fromArr[1]));
              final tp = toScreen(_safeDouble(toArr[0]), _safeDouble(toArr[1]));
              canvas.drawLine(fp, tp, Paint()..color = color..strokeWidth = strokeWidth..strokeCap = StrokeCap.round);
              // 箭头头
              final dx = tp.dx - fp.dx;
              final dy = tp.dy - fp.dy;
              final len = math.sqrt(dx * dx + dy * dy);
              if (len > 0) {
                final ux = dx / len, uy = dy / len;
                const al = 10.0;
                const aa = 0.45;
                final ax1 = tp.dx - al * (ux * math.cos(aa) - uy * math.sin(aa));
                final ay1 = tp.dy - al * (ux * math.sin(aa) + uy * math.cos(aa));
                final ax2 = tp.dx - al * (ux * math.cos(aa) + uy * math.sin(aa));
                final ay2 = tp.dy - al * (-ux * math.sin(aa) + uy * math.cos(aa));
                canvas.drawPath(
                  Path()..moveTo(tp.dx, tp.dy)..lineTo(ax1, ay1)..lineTo(ax2, ay2)..close(),
                  Paint()..color = color..style = PaintingStyle.fill,
                );
              }
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, (fp + tp) / 2 + const Offset(0, -14), color);
              }
            }
            break;
          }
          case 'rect': {
            final tl = _safeList(m['topLeft'] ?? m['p1']);
            final br = _safeList(m['bottomRight'] ?? m['p2']);
            if (tl.length >= 2 && br.length >= 2) {
              final p1 = toScreen(_safeDouble(tl[0]), _safeDouble(tl[1]));
              final p2 = toScreen(_safeDouble(br[0]), _safeDouble(br[1]));
              final rect = Rect.fromPoints(p1, p2);
              final paint = Paint()
                ..color = color.withAlpha(filled ? (opacity * 255).round() : 255)
                ..strokeWidth = strokeWidth
                ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
              canvas.drawRect(rect, paint);
              if (!filled) {
                canvas.drawRect(rect, Paint()..color = color..strokeWidth = strokeWidth..style = PaintingStyle.stroke);
              }
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, (p1 + p2) / 2 + const Offset(0, -16), color);
              }
            }
            break;
          }
          case 'ellipse': {
            final centerArr = _safeList(m['center']);
            if (centerArr.length >= 2) {
              final cc = toScreen(_safeDouble(centerArr[0]), _safeDouble(centerArr[1]));
              final rx = _safeDouble(m['rx'] ?? m['radiusX'], 1) * scale;
              final ry = _safeDouble(m['ry'] ?? m['radiusY'], 1) * scale;
              final rect = Rect.fromCenter(center: cc, width: rx * 2, height: ry * 2);
              canvas.drawOval(rect, Paint()
                ..color = color.withAlpha(filled ? (opacity * 255).round() : 255)
                ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
                ..strokeWidth = strokeWidth);
              if (label != null && label.isNotEmpty) {
                _drawCanvasLabel(canvas, label, cc + Offset(rx + 8, 0), color);
              }
            }
            break;
          }
          case 'text': {
            final posArr = _safeList(m['position'] ?? m['pos']);
            if (posArr.length >= 2 && label != null && label.isNotEmpty) {
              final pt = toScreen(_safeDouble(posArr[0]), _safeDouble(posArr[1]));
              final txt = m['text'] as String? ?? label;
              _drawCanvasLabel(canvas, txt, pt, color);
            }
            break;
          }
        }
      } catch (_) {
        // 单个 script 渲染失败不影响其他
      }
    }
  }

  void _drawCanvasLabel(Canvas canvas, String text, Offset pos, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final bg = Rect.fromLTWH(pos.dx - tp.width / 2 - 4, pos.dy - 1, tp.width + 8, tp.height + 3);
    canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(4)),
        Paint()..color = Colors.white.withAlpha(230));
    canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(4)),
        Paint()..color = color.withAlpha(25)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy));
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) => true;

  // ── 安全类型转换辅助 ──
  double _safeDouble(dynamic value, [double fallback = 0]) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) { final d = double.tryParse(value); if (d != null) return d; }
    return fallback;
  }

  List<dynamic> _safeList(dynamic value) {
    if (value == null) return <dynamic>[];
    if (value is List) return value as List<dynamic>;
    return <dynamic>[];
  }

  Color _parseColor(String? hex, ColorScheme cs) {
    if (hex == null || hex.isEmpty) return cs.primary;
    // Named color support
    switch (hex.toLowerCase()) {
      case 'red': return Colors.red;
      case 'blue': return Colors.blue;
      case 'green': return Colors.green;
      case 'gray': case 'grey': return Colors.grey.shade600;
      case 'black': return Colors.black;
      case 'white': return Colors.white;
      case 'yellow': return Colors.yellow.shade700;
      case 'orange': return Colors.orange;
      case 'purple': return Colors.purple;
      case 'pink': return Colors.pink;
      case 'brown': return Colors.brown;
      case 'cyan': return Colors.cyan;
      case 'teal': return Colors.teal;
    }
    // Hex support
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
    return cs.primary;
  }

  /// 绘制虚线（线段）
  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint,
      {double dashLen = 6, double gapLen = 4}) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len, uy = dy / len;
    double pos = 0;
    while (pos < len) {
      final seg = (pos + dashLen < len) ? dashLen : len - pos;
      canvas.drawLine(
        Offset(from.dx + ux * pos, from.dy + uy * pos),
        Offset(from.dx + ux * (pos + seg), from.dy + uy * (pos + seg)),
        paint,
      );
      pos += dashLen + gapLen;
    }
  }

  /// 绘制虚线圆
  void _drawDashedCircle(Canvas canvas, Offset center, double radius, Paint paint,
      {int segments = 24}) {
    final path = Path();
    for (var i = 0; i <= segments; i++) {
      final angle = 2 * math.pi * i / segments;
      final x = center.dx + radius * math.cos(angle);
      final y = center.dy + radius * math.sin(angle);
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    path.close();
    canvas.drawPath(path, paint);
  }
}
