import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../providers/auth_provider.dart' show authProvider;
import 'clay_button.dart';

/// 订单历史 — 可折叠下拉，展示支付记录 + 未完成订单可继续支付
class OrderHistory extends ConsumerStatefulWidget {
  const OrderHistory({super.key});

  @override
  ConsumerState<OrderHistory> createState() => _OrderHistoryState();
}

class _OrderHistoryState extends ConsumerState<OrderHistory> {
  List<Map<String, dynamic>>? _orders;
  bool _loading = true;
  String? _error;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    try {
      final auth = ref.read(authProvider);
      final userId = auth.userId;
      if (userId == null) { setState(() => _loading = false); return; }
      final resp = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/pay/orders?user_id=$userId'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _orders = (data['orders'] as List)
            .map((e) => e as Map<String, dynamic>)
            .toList();
      } else {
        _error = '加载失败';
      }
    } catch (e) {
      _error = '网络错误';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _fmtPrice(int amount) {
    final y = amount / 100.0;
    if (y == y.roundToDouble()) return '¥${y.toInt()}';
    return '¥${y.toStringAsFixed(2)}';
  }

  bool _isExpired(Map<String, dynamic> order) {
    if (order['status'] != 'NOTPAY') return false;
    final created = DateTime.tryParse(order['created_at'] as String? ?? '');
    if (created == null) return false;
    return DateTime.now().difference(created).inMinutes > 10;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.receipt_long, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('历史订单', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  if (_orders != null)
                    Text('（${_orders!.length}）',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.expand_more, color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildOrderList(cs),
            crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderList(ColorScheme cs) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
      );
    }
    if (_orders == null || _orders!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text('暂无订单', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: _orders!.map((o) => _buildRow(o, cs)).toList(),
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> order, ColorScheme cs) {
    final status = order['status'] as String? ?? '';
    final planName = order['plan_name'] as String? ?? order['plan_id'] as String? ?? '';
    final amount = order['amount'] as int? ?? 0;
    final expired = _isExpired(order);

    String statusLabel;
    Color statusColor;
    IconData statusIcon;

    if (status == 'SUCCESS') {
      statusLabel = '已支付';
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
    } else if (expired || status == 'CLOSED') {
      statusLabel = '未支付';
      statusColor = cs.error;
      statusIcon = Icons.cancel;
    } else {
      statusLabel = '待支付';
      statusColor = Colors.orange;
      statusIcon = Icons.pending;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(planName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(_fmtPrice(amount),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Text(statusLabel, style: TextStyle(fontSize: 12, color: statusColor)),
          const SizedBox(width: 8),
          if (status == 'NOTPAY' && !expired)
            // 🔑 与订阅卡的「续费」**同一个组件** —— 两者同屏（订阅卡正下方
            //    就是订单历史），若一个粘土一个 Material，会读作「两套体系」。
            // 🔴 原先外面套了 `SizedBox(height: 26)` 把它压到 26px ——
            //    那是为了迁就 Material 按钮的最小高度；粘土按钮需要
            //    `inset` 表现体积（§3.5 硬规则：< 24px 就得去掉 inset），
            //    压缩高度等于砍掉它的语言，故去掉该约束让它取自然高度。
            ClayButton(
              label: '支付',
              onTap: () => _continuePay(order),
            ),
        ],
      ),
    );
  }

  void _continuePay(Map<String, dynamic> oldOrder) async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    if (userId == null) return;
    try {
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/pay/native'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': userId, 'plan_id': oldOrder['plan_id']}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        context.push('/pay', extra: {
          'order_id': data['order_id'],
          'code_url': data['code_url'],
        });
      }
    } catch (_) {}
  }
}
