import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';

/// 分销数据统计页面
class AdminStatsDashboardPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminStatsDashboardPage({super.key, this.adminKey, this.token});

  @override
  State<AdminStatsDashboardPage> createState() => _AdminStatsDashboardPageState();
}

class _AdminStatsDashboardPageState extends State<AdminStatsDashboardPage> {
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _funnel;
  bool _loading = true;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/admin/distribution/stats'),
          headers: _headers,
        ),
        http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/admin/distribution/funnel'),
          headers: _headers,
        ),
      ]);
      if (mounted) {
        if (results[0].statusCode == 200) {
          _stats = jsonDecode(results[0].body) as Map<String, dynamic>;
        }
        if (results[1].statusCode == 200) {
          _funnel = jsonDecode(results[1].body) as Map<String, dynamic>;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return _loading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('总览指标',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 14)),
                const SizedBox(height: AppTheme.spacingSm),
                // 第一行: 活动
                _statRow(cs, [
                  _statCard(cs, '活动总数',
                      '${_stats?['total_campaigns'] ?? 0}', Icons.campaign),
                  _statCard(cs, '进行中',
                      '${_stats?['active_campaigns'] ?? 0}', Icons.play_circle),
                ]),
                const SizedBox(height: AppTheme.spacingSm),
                // 第二行: 点击/注册
                _statRow(cs, [
                  _statCard(cs, '总点击数',
                      '${_stats?['total_clicks'] ?? 0}', Icons.touch_app),
                  _statCard(cs, '总注册数',
                      '${_stats?['total_registrations'] ?? 0}', Icons.person_add),
                ]),
                const SizedBox(height: AppTheme.spacingSm),
                // 第三行: 待结算
                _statRow(cs, [
                  _statCard(cs, '待结算佣金',
                      '${_stats?['pending_commissions_count'] ?? 0}',
                      Icons.pending_actions),
                  _statCard(cs, '待结算金额',
                      '¥${_stats?['pending_commissions_amount'] ?? 0}',
                      Icons.money),
                ]),
                const SizedBox(height: AppTheme.spacingSm),
                // 第四行: 提现 + 已打款
                _statRow(cs, [
                  _statCard(cs, '待审核提现',
                      '${_stats?['pending_withdrawals_count'] ?? 0}',
                      Icons.payment),
                  _statCard(cs, '已打款总额',
                      '¥${_stats?['total_paid'] ?? 0}',
                      Icons.check_circle),
                ]),
                const SizedBox(height: AppTheme.spacingLg),
                // 漏斗图
                Text('转化漏斗',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 14)),
                const SizedBox(height: AppTheme.spacingSm),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.spacingMd),
                    child: Column(
                      children: [
                        _funnelRow(cs, '点击',
                            '${_funnel?['clicks'] ?? 0}', 1.0),
                        _funnelRow(cs, '注册',
                            '${_funnel?['registrations'] ?? 0}', _funnelRatio('registrations', 'clicks')),
                        _funnelRow(cs, '支付',
                            '${_funnel?['payments'] ?? 0}', _funnelRatio('payments', 'clicks')),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('佣金总额',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurfaceVariant)),
                            Text('¥${_funnel?['commission_amount'] ?? 0}',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: cs.primary)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
  }

  double _funnelRatio(String numerator, String denominator) {
    final n = (_funnel?[numerator] as num?)?.toDouble() ?? 0;
    final d = (_funnel?[denominator] as num?)?.toDouble() ?? 1;
    return d > 0 ? n / d : 0;
  }

  Widget _statRow(ColorScheme cs, List<Widget> cards) {
    return Row(
      children: cards.map((c) => Expanded(child: c)).toList(),
    );
  }

  Widget _statCard(ColorScheme cs, String label, String value, IconData icon) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: AppTheme.spacingXs),
              Text(label,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ]),
            const SizedBox(height: AppTheme.spacingXs),
            Text(value,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: cs.primary)),
          ],
        ),
      ),
    );
  }

  Widget _funnelRow(ColorScheme cs, String label, String value, double ratio) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 60,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13, color: cs.onSurfaceVariant))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0),
                minHeight: 20,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingSm),
          SizedBox(width: 80,
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}
