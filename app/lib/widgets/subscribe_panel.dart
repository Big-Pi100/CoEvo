import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../providers/auth_provider.dart' show authProvider;
import '../../theme/app_theme.dart';

/// 订阅套餐面板 — 卡片式套餐展示，支持下单跳转支付
class SubscribePanel extends ConsumerStatefulWidget {
  const SubscribePanel({super.key});

  @override
  ConsumerState<SubscribePanel> createState() => _SubscribePanelState();
}

class _SubscribePanelState extends ConsumerState<SubscribePanel> {
  List<Map<String, dynamic>>? _plans;
  bool _loading = true;
  String? _error;
  String? _orderingPlan;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    setState(() => _loading = true);
    try {
      final auth = ref.read(authProvider);
      final userId = auth.userId;
      final url = userId != null
          ? '${ApiConfig.baseUrl}/api/pay/plans?user_id=$userId'
          : '${ApiConfig.baseUrl}/api/pay/plans';
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _plans = (data['plans'] as List)
            .map((e) => e as Map<String, dynamic>)
            .toList();
      } else {
        _error = '加载套餐失败';
      }
    } catch (e) {
      _error = '网络错误';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createOrder(String planId) async {
    setState(() => _orderingPlan = planId);
    try {
      final auth = ref.read(authProvider);
      if (auth.userId == null) {
        _showError('请先登录');
        return;
      }
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/pay/native'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': auth.userId, 'plan_id': planId}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final orderId = data['order_id'] as String;
        final codeUrl = data['code_url'] as String;
        context.push('/pay', extra: {
          'order_id': orderId,
          'code_url': codeUrl,
          'plan_id': planId,
        });
      } else if (mounted) {
        _showError('下单失败');
      }
    } catch (e) {
      _showError('网络错误');
    } finally {
      if (mounted) setState(() => _orderingPlan = null);
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _fmtPrice(int fen) {
    final y = fen / 100.0;
    if (y == y.roundToDouble()) return '¥${y.toInt()}';
    return '¥${y.toStringAsFixed(2)}';
  }

  String _durationText(Map<String, dynamic> plan) {
    final days = plan['duration_days'] as int?;
    if (days == null) return '';
    if (days >= 3650) return '永久有效';
    if (days >= 365) return '${days ~/ 365}年';
    return '$days天';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) ...[
            const SizedBox(height: AppTheme.spacingXl),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: AppTheme.spacingXl),
          ] else if (_error != null) ...[
            const SizedBox(height: AppTheme.spacingLg),
            Center(
              child: Column(
                children: [
                  Icon(Icons.cloud_off, size: 36, color: cs.error),
                  const SizedBox(height: AppTheme.spacingSm),
                  Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
                  const SizedBox(height: AppTheme.spacingMd),
                  TextButton.icon(
                    onPressed: _loadPlans,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ] else if (_plans == null || _plans!.isEmpty) ...[
            const SizedBox(height: AppTheme.spacingXl),
            Center(
              child: Text('暂无可用的套餐',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            ),
          ] else ...[
            const SizedBox(height: AppTheme.spacingSm),
            ..._plans!.asMap().entries.map((entry) =>
                _PlanCard(
                  plan: entry.value,
                  priceText: _fmtPrice(entry.value['price'] as int),
                  durationText: _durationText(entry.value),
                  loading: _orderingPlan == entry.value['id'],
                  onPay: () => _createOrder(entry.value['id'] as String),
                )),
          ],
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final String priceText;
  final String durationText;
  final bool loading;
  final VoidCallback onPay;

  const _PlanCard({
    required this.plan,
    required this.priceText,
    required this.durationText,
    required this.loading,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final name = plan['name'] as String? ?? '';
    final price = plan['price'] as int? ?? 0;
    final maxUses = plan['max_uses'] as int?;
    final usedCount = plan['used_count'] as int? ?? 0;
    final isLifetime = (plan['duration_days'] as int?) == null ||
        (plan['duration_days'] as int?)! >= 3650;

    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withAlpha(80),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: loading ? null : onPay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // 左侧：套餐信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 套餐名
                      Text(name,
                          style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      // 价格 + 时长 一行
                      Row(
                        children: [
                          Text(priceText,
                              style: tt.titleMedium?.copyWith(
                                  color: cs.primary, fontWeight: FontWeight.bold)),
                          const SizedBox(width: AppTheme.spacingSm),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.primary.withAlpha(15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(durationText,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.primary,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                      // 限量/限时标识
                      if (maxUses != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(Icons.local_offer, size: 12, color: cs.tertiary),
                              const SizedBox(width: 4),
                              Text('限量 ${maxUses - usedCount} 份',
                                  style: TextStyle(fontSize: 11, color: cs.tertiary)),
                            ],
                          ),
                        ),
                      if (isLifetime && maxUses == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('一次付费，永久使用',
                              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppTheme.spacingSm),
                // 右侧：订阅按钮
                SizedBox(
                  height: 34,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    onPressed: loading ? null : onPay,
                    child: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(price == 0 ? '开通' : '订阅'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
