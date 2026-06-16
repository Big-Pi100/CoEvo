import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import '../../api/api_config.dart';

/// 支付页 — 展示二维码 + 轮询订单状态
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key});

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  String? _orderId;
  String? _codeUrl;
  Timer? _pollTimer;
  String _status = 'NOTPAY';
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extra = GoRouterState.of(context).extra as Map<String, dynamic>?;
      if (extra != null) {
        setState(() {
          _orderId = extra['order_id'] as String?;
          _codeUrl = extra['code_url'] as String?;
        });
        _startPolling();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_orderId != null) _checkOrder();
    });
    // 10 分钟后超时
    Timer(const Duration(minutes: 10), () {
      _pollTimer?.cancel();
      if (mounted && _status != 'SUCCESS') {
        setState(() => _expired = true);
      }
    });
  }

  Future<void> _checkOrder() async {
    try {
      final resp = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/pay/orders/${_orderId!}'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final status = data['status'] as String? ?? '';
        if (status == 'SUCCESS' && mounted) {
          setState(() => _status = 'SUCCESS');
          _pollTimer?.cancel();
          // 2 秒后自动返回
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) context.pop(true);
          });
        } else if (status == 'CLOSED' && mounted) {
          setState(() => _status = 'CLOSED');
          _pollTimer?.cancel();
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('支付')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(cs),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_expired) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_off, size: 64, color: cs.error),
          const SizedBox(height: 16),
          const Text('支付超时', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text('订单已过期，请重新选择套餐', style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => context.pop(), child: const Text('返回')),
        ],
      );
    }

    if (_status == 'SUCCESS') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 64, color: Colors.green),
          const SizedBox(height: 16),
          const Text('支付成功', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('订阅已激活，即将返回...', style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      );
    }

    if (_status == 'CLOSED') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cancel, size: 64, color: cs.error),
          const SizedBox(height: 16),
          const Text('订单已关闭', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => context.pop(), child: const Text('返回')),
        ],
      );
    }

    if (_codeUrl == null) {
      return const CircularProgressIndicator();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('请使用微信扫码支付', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child:             QrImageView(
            data: _codeUrl!,
            size: 220,
            eyeStyle: QrEyeStyle(color: Colors.black),
            dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
          ),
        ),
        const SizedBox(height: 16),
        const SizedBox(
          width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 8),
        Text('请在10分钟之内支付', style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text('订单号: ${_orderId ?? ""}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
  }
}
