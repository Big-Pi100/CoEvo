import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';

/// 收益面板页
class EarningsPage extends ConsumerWidget {
  const EarningsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _EarningsPageBody(auth: auth);
  }
}

class _EarningsPageBody extends StatefulWidget {
  final AuthState auth;
  const _EarningsPageBody({required this.auth});

  @override
  State<_EarningsPageBody> createState() => _EarningsPageBodyState();
}

class _EarningsPageBodyState extends State<_EarningsPageBody> {
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _commissions = [];
  bool _loading = true;

  Map<String, String> get _headers {
    final token = widget.auth.token;
    if (token != null) return {'Authorization': 'Bearer $token'};
    return {};
  }

  String get _userId => widget.auth.userId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_userId.isEmpty) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/referral/my-stats?user_id=$_userId'),
          headers: _headers,
        ),
        http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/referral/my-commissions?user_id=$_userId'),
          headers: _headers,
        ),
      ]);
      if (mounted) {
        if (results[0].statusCode == 200) {
          _stats = jsonDecode(results[0].body) as Map<String, dynamic>;
        }
        if (results[1].statusCode == 200) {
          final data = jsonDecode(results[1].body) as Map<String, dynamic>;
          _commissions = (data['commissions'] as List?)
                  ?.map((e) => e as Map<String, dynamic>)
                  .toList() ?? [];
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'paid':
        return Colors.green;
      case 'settled':
        return Colors.orange;
      case 'available':
        return Colors.blue;
      case 'locked':
        return Colors.grey;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'paid':
        return '已打款';
      case 'settled':
        return '已结算';
      case 'available':
        return '可提现';
      case 'locked':
        return '锁定中';
      case 'cancelled':
        return '已取消';
      default:
        return status ?? '未知';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('收益面板')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppTheme.spacingLg),
                children: [
                  // 头部统计
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.spacingXxl),
                      child: Column(
                        children: [
                          Text('累计收益',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant)),
                          const SizedBox(height: AppTheme.spacingSm),
                          Text(
                            '¥${_stats?['total_earned'] ?? 0}',
                            style: TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.bold,
                                color: cs.primary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingMd),
                  Row(
                    children: [
                      _miniCard(cs, '团队人数',
                          '${_stats?['total_registrations'] ?? 0}'),
                      const SizedBox(width: AppTheme.spacingSm),
                      _miniCard(cs, '分享次数',
                          '${_stats?['total_clicks'] ?? 0}'),
                    ],
                  ),
                  const SizedBox(height: AppTheme.spacingLg),
                  Text('佣金明细',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                          fontSize: 13)),
                  const SizedBox(height: AppTheme.spacingSm),
                  if (_commissions.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppTheme.spacingXxl),
                        child: Text('暂无佣金记录',
                            style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant)),
                      ),
                    )
                  else
                    ..._commissions.map((c) => Card(
                          margin:
                              const EdgeInsets.only(bottom: AppTheme.spacingXs),
                          child: Padding(
                            padding: const EdgeInsets.all(AppTheme.spacingSm),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Text(
                                            '¥${(c['amount'] as num?)?.toDouble() ?? 0}',
                                            style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold)),
                                        const Spacer(),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: _statusColor(
                                                    c['status'] as String?)
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            _statusLabel(
                                                c['status'] as String?),
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: _statusColor(
                                                    c['status'] as String?),
                                                fontWeight: FontWeight.w500),
                                          ),
                                        ),
                                      ]),
                                      const SizedBox(height: 2),
                                      Text(
                                        '来源: ${(c['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: cs.onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )),
                ],
              ),
            ),
    );
  }

  Widget _miniCard(ColorScheme cs, String label, String value) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: cs.primary)),
              Text(label,
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
