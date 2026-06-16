import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../providers/auth_provider.dart' show authProvider;

/// 订阅套餐卡片面板 — 从 /api/pay/plans 加载，支持选套餐下单
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
      // 获取当前用户 ID（可选，用于过滤已购买的 once_per_user 套餐）
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
        _error = '加载套餐失败: ${resp.statusCode}';
      }
    } catch (e) {
      _error = '网络错误: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createOrder(String planId) async {
    setState(() => _orderingPlan = planId);
    try {
      // 先获取当前用户 ID（从 local storage 或 provider）
      // 这里简单起见用 provider 获取
      final auth = ref.read(authProvider);
      if (auth.userId == null) {
        _showError('请先登录');
        return;
      }

      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/pay/native'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': auth.userId,
              'plan_id': planId,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final orderId = data['order_id'] as String;
        final codeUrl = data['code_url'] as String;

        // 跳转到支付页
        context.push('/pay', extra: {
          'order_id': orderId,
          'code_url': codeUrl,
          'plan_id': planId,
        });
      } else if (mounted) {
        _showError('下单失败: ${resp.body}');
      }
    } catch (e) {
      _showError('网络错误: $e');
    } finally {
      if (mounted) setState(() => _orderingPlan = null);
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _formatPrice(int priceFen) {
    final yuan = priceFen / 100.0;
    if (yuan == yuan.roundToDouble()) {
      return '¥${yuan.toInt()}';
    }
    return '¥${yuan.toStringAsFixed(2)}';
  }

  String _durationText(Map<String, dynamic> plan) {
    final days = plan['duration_days'] as int?;
    if (days == null) return '';
    if (days >= 3650) return '永久';
    if (days >= 365) return '${days ~/ 365}年';
    return '$days天';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: cs.error),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: cs.error)),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadPlans, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_plans == null || _plans!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text('暂无可用的套餐', style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('选择订阅套餐', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        ..._plans!.map((plan) => _PlanCard(
              plan: plan,
              priceText: _formatPrice(plan['price'] as int),
              durationText: _durationText(plan),
              loading: _orderingPlan == plan['id'],
              onPay: () => _createOrder(plan['id'] as String),
            )),
      ],
    );
  }
}

/// 单张套餐卡片
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
    final name = plan['name'] as String? ?? '';
    final maxUses = plan['max_uses'] as int?;
    final usedCount = plan['used_count'] as int? ?? 0;
    final isFree = (plan['price'] as int?) == 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(durationText, style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
                      if (maxUses != null) ...[
                        const SizedBox(width: 8),
                        Text('剩余 ${maxUses - usedCount} 份', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      ],
                    ],
                  ),
                  if (isFree)
                    const Text('免费', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600))
                  else
                    Text(priceText, style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: cs.primary, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            FilledButton(
              onPressed: loading ? null : onPay,
              child: loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(isFree ? '开通' : '订阅'),
            ),
          ],
        ),
      ),
    );
  }
}
