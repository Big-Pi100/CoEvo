import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../providers/auth_provider.dart' show authProvider;

/// 订单历史 — 可折叠下拉，展示**已购记录**。
///
/// 🔴 2026-10-04（支付批次）：删掉了「未完成订单可继续支付」这条能力 ——
///    它调的是**已删除**的 `POST /api/pay/native`（微信 Native 下单）。
///    Apple IAP 下**不存在「我们侧待支付的订单」**（订阅只由 StoreKit 发起）。
///    ⚠️ 列表本身保留：IAP 的交易也会写进 `payment_orders`
///       （见 `backend/crates/api_server/src/iap_handlers.rs` 的 `ensure_order`），
///       所以这里有真实数据可看（白哥 2026-10-04 决策：保留列表、去掉支付按钮）。
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
      if (userId == null) {
        setState(() => _loading = false);
        return;
      }
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
                  Text('历史订单',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  if (_orders != null)
                    Text('（${_orders!.length}）',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child:
                          Icon(Icons.expand_more, color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildOrderList(cs),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
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
        child: Text('暂无订单',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
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
    final planName =
        order['plan_name'] as String? ?? order['plan_id'] as String? ?? '';
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
                Text(planName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                Text(_fmtPrice(amount),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Text(statusLabel, style: TextStyle(fontSize: 12, color: statusColor)),
          const SizedBox(width: 8),
          // 🗑 2026-10-04：原为「未完成订单 → 继续支付」的 `ClayButton`
          //    （调 `POST /api/pay/native` 换二维码）。微信支付已移除；
          //    IAP 下也没有「继续支付一笔旧订单」这个概念 ——
          //    订阅只由 StoreKit 发起，我们侧不存在待支付订单。
          //    ⇒ 该按钮与 `_continuePay()` 一并删除（连同 `go_router` / `clay_button`
          //      两个 import —— 删按钮后它们在本文件失去全部使用者）。
        ],
      ),
    );
  }
}
