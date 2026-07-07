import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import '../../api/api_config.dart';
import '../../providers/auth_provider.dart';

/// 支付页 — 支持佣金抵扣 + 微信扫码支付
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key});

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  // ── 订单 / 支付状态 ──
  String? _orderId;
  String? _codeUrl;
  Timer? _pollTimer;
  String _status = 'NOTPAY';
  bool _expired = false;
  bool _paying = false;

  // ── 佣金抵扣 ──
  int? _availableCommission; // 单位：分
  bool _useCommission = false;
  int _commissionDiscount = 0; // 用户选择的抵扣金额（分）

  // ── 套餐信息 ──
  String? _planId;
  int? _actualPrice;
  int _planPrice = 0;
  String _planName = '';

  String? _userId;
  String? _token;

  bool get _commissionMode => _planId != null && _orderId == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = ref.read(authProvider);
      _userId = auth.userId;
      _token = auth.token;

      final extra = GoRouterState.of(context).extra as Map<String, dynamic>?;
      if (extra == null) return;

      final orderId = extra['order_id'] as String?;
      final codeUrl = extra['code_url'] as String?;
      final planId = extra['plan_id'] as String?;

      if (orderId != null) {
        // 传统模式：已有订单，直接展示二维码
        setState(() {
          _orderId = orderId;
          _codeUrl = codeUrl;
          _planId = planId;
        });
        _startPolling();
      } else if (planId != null) {
        // 佣金模式：需先选择抵扣再下单
        setState(() {
          _planId = planId;
          _actualPrice = extra['actual_price'] as int?;
          _planPrice = extra['plan_price'] as int? ?? 0;
          _planName = extra['plan_name'] as String? ?? '';
        });
        _loadPlanPrice();
        _loadAvailableCommission();
      }
    });
  }

  Map<String, String> get _headers {
    if (_token != null) return {'Authorization': 'Bearer $_token'};
    return {};
  }

  /// 查套餐价格（如果 extras 未提供 plan_price）
  Future<void> _loadPlanPrice() async {
    if (_planPrice > 0) return;
    try {
      final authHeaders = <String, String>{};
      if (_token != null) authHeaders['Authorization'] = 'Bearer $_token';
      final resp = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/pay/plans?user_id=$_userId'), headers: authHeaders)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        final plans = data['plans'] as List? ?? [];
        for (final p in plans) {
          if (p['id'] == _planId) {
            setState(() {
              _planPrice = p['price'] as int? ?? 0;
              _planName = p['name'] as String? ?? '';
            });
            break;
          }
        }
      }
    } catch (_) {}
  }

  /// 查可用佣金
  Future<void> _loadAvailableCommission() async {
    if (_userId == null) return;
    try {
      final resp = await http
          .get(
            Uri.parse(
                '${ApiConfig.baseUrl}/api/referral/my-stats?user_id=$_userId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final available = data['available_commission'] as int? ?? 0;
        setState(() {
          _availableCommission = available;
          _commissionDiscount = available; // 默认全部抵扣
        });
      }
    } catch (_) {}
  }

  /// 下单支付（含佣金抵扣）
  Future<void> _pay() async {
    if (_userId == null || _planId == null || _paying) return;
    setState(() => _paying = true);

    try {
      final body = <String, dynamic>{
        'user_id': _userId,
        'plan_id': _planId,
      };
      if (_actualPrice != null && _actualPrice! > 0) {
        body['actual_price'] = _actualPrice;
      }
      if (_useCommission && _commissionDiscount > 0) {
        final basePrice = _actualPrice ?? _planPrice;
        body['commission_discount'] = _commissionDiscount.clamp(0, basePrice);
      }

      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/pay/native'),
            headers: {
              'Content-Type': 'application/json',
              if (_token != null) 'Authorization': 'Bearer $_token',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final paid = data['paid'] as bool? ?? false;

        if (paid) {
          // 纯佣金抵扣 / 免费：直接成功
          setState(() {
            _status = 'SUCCESS';
            _codeUrl = null;
          });
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) context.go('/home');
          });
        } else {
          // 混合支付：显示微信二维码
          setState(() {
            _orderId = data['order_id'] as String?;
            _codeUrl = data['code_url'] as String?;
          });
          _startPolling();
        }
      } else {
        _showError(resp.body);
      }
    } catch (e) {
      _showError('网络错误');
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) context.go('/home');
          });
        } else if (status == 'CLOSED' && mounted) {
          setState(() => _status = 'CLOSED');
          _pollTimer?.cancel();
        }
      }
    } catch (_) {}
  }

  String _fmtPrice(int fen) {
    final y = fen / 100.0;
    if (y == y.roundToDouble()) return '¥${y.toInt()}';
    return '¥${y.toStringAsFixed(2)}';
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
          Text('订单已过期，请重新选择套餐',
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton(
              onPressed: () => context.pop(), child: const Text('返回')),
        ],
      );
    }

    if (_status == 'SUCCESS') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 64, color: Colors.green),
          const SizedBox(height: 16),
          const Text('支付成功',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('订阅已激活，即将返回...',
              style: TextStyle(color: cs.onSurfaceVariant)),
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
          FilledButton(
              onPressed: () => context.pop(), child: const Text('返回')),
        ],
      );
    }

    // 有二维码 → 展示微信支付 QR（混合支付或传统模式）
    if (_codeUrl != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('请使用微信扫码支付',
              style: TextStyle(fontSize: 16)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: _codeUrl!,
              size: 220,
              eyeStyle: QrEyeStyle(color: Colors.black),
              dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
            ),
          ),
          const SizedBox(height: 16),
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 8),
          Text('请在10分钟之内支付',
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('订单号: ${_orderId ?? ""}',
              style:
                  TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      );
    }

    // 佣金模式：显示套餐信息 + 佣金抵扣选项 + 支付按钮
    if (_commissionMode) {
      if (_planPrice == 0 && _actualPrice == null) {
        // 套餐价格尚未加载
        return const CircularProgressIndicator();
      }

      final basePrice = _actualPrice ?? _planPrice;
      final finalPrice =
          _useCommission ? (basePrice - _commissionDiscount).clamp(0, basePrice) : basePrice;

      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 套餐信息
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(_planName,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Text(
                      _fmtPrice(basePrice),
                      style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: cs.primary),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 佣金抵扣区域
            if (_availableCommission != null && _availableCommission! > 0) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.monetization_on,
                              size: 20, color: Colors.amber.shade700),
                          const SizedBox(width: 8),
                          Text('可用佣金 ${_fmtPrice(_availableCommission!)}',
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('使用佣金抵扣',
                            style: TextStyle(fontSize: 14)),
                        value: _useCommission,
                        onChanged: (v) {
                          setState(() {
                            _useCommission = v;
                            if (v) {
                              final basePrice = _actualPrice ?? _planPrice;
                              _commissionDiscount = _availableCommission! < basePrice
                                  ? _availableCommission!
                                  : basePrice;
                            } else {
                              _commissionDiscount = 0;
                            }
                          });
                        },
                      ),
                      if (_useCommission) ...[
                        const SizedBox(height: 8),
                        Text('抵扣金额',
                            style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value: _commissionDiscount
                                    .toDouble()
                                    .clamp(0, _availableCommission!.toDouble()),
                                min: 0,
                                max: basePrice < _availableCommission!
                                    ? basePrice.toDouble()
                                    : _availableCommission!.toDouble(),
                                divisions: _availableCommission! > 100
                                    ? (_availableCommission! / 100)
                                        .round()
                                        .clamp(1, 1000)
                                    : _availableCommission,
                                label: _fmtPrice(_commissionDiscount),
                                onChanged: (v) {
                                  setState(() {
                                    _commissionDiscount = v.round();
                                  });
                                },
                              ),
                            ),
                            SizedBox(
                              width: 80,
                              child: Text(
                                _fmtPrice(_commissionDiscount),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 合计 / 实付
              if (_useCommission) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('优惠减免',
                            style: TextStyle(fontSize: 14)),
                        Text('-${_fmtPrice(_commissionDiscount)}',
                            style: const TextStyle(
                                fontSize: 14, color: Colors.green)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: cs.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('实付金额',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        Text(
                          finalPrice > 0
                              ? _fmtPrice(finalPrice)
                              : '免费',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: finalPrice > 0
                                  ? cs.primary
                                  : Colors.green),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ],

            // 支付按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _paying ? null : _pay,
                child: _paying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        finalPrice > 0
                            ? '确认支付 ${_fmtPrice(finalPrice)}'
                            : '确认开通',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    // 兜底：加载中
    return const CircularProgressIndicator();
  }
}
