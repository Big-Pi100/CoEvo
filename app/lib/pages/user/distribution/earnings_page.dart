import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/twemoji.dart';

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
  List<Map<String, dynamic>> _withdrawals = [];
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
        http.get(
          Uri.parse('${ApiConfig.baseUrl}/api/referral/my-withdrawals?user_id=$_userId'),
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
        if (results[2].statusCode == 200) {
          final data = jsonDecode(results[2].body) as Map<String, dynamic>;
          _withdrawals = (data['withdrawals'] as List?)
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

  /// 根据 status 返回金额显示符号：available/locked→+，paid→−，其他→空
  String _amountPrefix(String? status) {
    switch (status) {
      case 'available':
      case 'locked':
        return '+';
      case 'paid':
        return '\u2212'; // 减号 −
      default:
        return '';
    }
  }

  /// 根据 status 返回金额颜色：available/locked→绿色，used/settled/paid→红色，其他→默认
  Color _amountColor(String? status, ColorScheme cs) {
    switch (status) {
      case 'available':
      case 'locked':
        return Colors.green;
      case 'used':
      case 'settled':
      case 'paid':
        return Colors.red;
      default:
        return cs.onSurface;
    }
  }

  /// 计算锁定佣金的解锁提示（created_at + 30天）
  String _unlockHint(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '结算期30天';
    try {
      final dt = DateTime.parse(createdAt.replaceAll(' ', 'T'));
      final unlockAt = dt.add(const Duration(days: 30));
      final remaining = unlockAt.difference(DateTime.now());
      if (remaining.isNegative) return '即将解锁';
      final days = remaining.inDays;
      if (days > 0) return '预计 ${days}天后自动解锁';
      final hours = remaining.inHours;
      if (hours > 0) return '预计 ${hours}小时后自动解锁';
      return '即将解锁';
    } catch (_) {
      return '结算期30天';
    }
  }

  /// 佣金明细卡片
  Widget _commissionCard(Map<String, dynamic> c, ColorScheme cs) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(
                        '${_amountPrefix(c['status'] as String?)}¥${((c['amount'] as num?)?.toDouble() ?? 0) / 100}',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: _amountColor(c['status'] as String?, cs))),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _statusColor(c['status'] as String?).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Tw(
                        _statusLabel(c['status'] as String?),
                        style: TextStyle(fontSize: 10, color: _statusColor(c['status'] as String?), fontWeight: FontWeight.w500),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '来源: 套餐 ${(c['plan_id'] as String? ?? '').replaceAll(RegExp(r'^.{8}'), '')}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  if ((c['status'] as String?) == 'locked')
                    Text(_unlockHint(c['created_at'] as String?),
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 提现记录卡片
  Widget _withdrawalCard(Map<String, dynamic> w, ColorScheme cs) {
    final amount = ((w['amount'] as num?)?.toDouble() ?? 0) / 100;
    final fee = ((w['fee'] as num?)?.toDouble() ?? 0) / 100;
    final actual = ((w['actual_amount'] as num?)?.toDouble() ?? 0) / 100;
    String statusLabel;
    switch (w['status'] as String? ?? '') {
      case 'pending': statusLabel = '审核中'; break;
      case 'confirmed': statusLabel = '已通过'; break;
      case 'rejected': statusLabel = '已驳回'; break;
      case 'paid': statusLabel = '已打款'; break;
      default: statusLabel = w['status'] as String? ?? '未知';
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('\u2212¥$amount',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.red)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withAlpha(25),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Tw(statusLabel,
                          style: const TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w500)),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text('提现: 手续费 ¥$fee, 到账 ¥$actual',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  Text((w['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), ''),
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Tw('收益面板')),
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
                            '¥${((_stats?['total_earned'] as num?)?.toDouble() ?? 0) / 100}',
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
                  if (_commissions.isEmpty && _withdrawals.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppTheme.spacingXxl),
                        child: Tw('暂无记录',
                            style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant)),
                      ),
                    )
                  else ...[
                    ..._commissions.map((c) => _commissionCard(c, cs)),
                    if (_withdrawals.isNotEmpty) ...[
                      const SizedBox(height: AppTheme.spacingMd),
                      Text('提现记录',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.red.shade400,
                              fontSize: 13)),
                      const SizedBox(height: AppTheme.spacingSm),
                      ..._withdrawals.map((w) => _withdrawalCard(w, cs)),
                    ],
                  ],
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
