import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';

/// 提现页面
class WithdrawPage extends ConsumerWidget {
  const WithdrawPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _WithdrawPageBody(auth: auth);
  }
}

class _WithdrawPageBody extends StatefulWidget {
  final AuthState auth;
  const _WithdrawPageBody({required this.auth});

  @override
  State<_WithdrawPageBody> createState() => _WithdrawPageBodyState();
}

class _WithdrawPageBodyState extends State<_WithdrawPageBody> {
  final _amountCtrl = TextEditingController();
  bool _loading = true;
  bool _submitting = false;
  Map<String, dynamic>? _stats;
  final List<Map<String, dynamic>> _records = [];

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

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_userId.isEmpty) return;
    setState(() => _loading = true);
    try {
      // 加载统计数据（可提现金额）
      final statsUri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/my-stats?user_id=$_userId');
      final statsResp = await http
          .get(statsUri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (statsResp.statusCode == 200 && mounted) {
        _stats = jsonDecode(statsResp.body) as Map<String, dynamic>;
      }

      // 加载提现记录
      final recordsUri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/my-withdrawals?user_id=$_userId');
      final recordsResp = await http
          .get(recordsUri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (recordsResp.statusCode == 200 && mounted) {
        final body = jsonDecode(recordsResp.body) as Map<String, dynamic>;
        final list = (body['withdrawals'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>();
        if (list != null) {
          _records.clear();
          _records.addAll(list);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _submitWithdraw() async {
    final amountText = _amountCtrl.text.trim();
    final amount = int.tryParse(amountText);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入有效金额')));
      return;
    }

    final available = (_stats?['total_earned'] as num?)?.toInt() ?? 0;
    if (amount > available) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('可提现金额不足')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认提现'),
        content: Text('确定提现 $amount 元？\n'
            '手续费: 提现金额的 1%（最低 1 元）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认提现'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _submitting = true);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/referral/withdraw');
      final resp = await http
          .post(
            uri,
            headers: {
              ..._headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'user_id': _userId,
              'amount': amount,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('提现申请已提交，请等待审核\n'
                  '到账金额: ¥${(data['actual_amount'] as num?)?.toDouble() ?? amount}'),
            ),
          );
          _amountCtrl.clear();
          _load();
        }
      } else if (mounted) {
        final errBody = jsonDecode(resp.body) as Map<String, dynamic>;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errBody['error'] as String? ?? '提现失败')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('提交失败: $e')));
      }
    }
    if (mounted) setState(() => _submitting = false);
  }

  /// 提现状态中文显示
  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return '审核中';
      case 'approved':
        return '已通过';
      case 'rejected':
        return '已驳回';
      case 'paid':
        return '已打款';
      default:
        return status;
    }
  }

  Color _statusColor(String status, ColorScheme cs) {
    switch (status) {
      case 'pending':
        return cs.tertiary;
      case 'approved':
        return cs.primary;
      case 'rejected':
        return cs.error;
      case 'paid':
        return cs.primary;
      default:
        return cs.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('提现')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppTheme.spacingLg),
              children: [
                // 可提现金额
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.spacingXxl),
                    child: Column(
                      children: [
                        Text('可提现金额',
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
                // 提现输入
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.spacingMd),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('提现金额',
                            style: TextStyle(fontSize: 13)),
                        const SizedBox(height: AppTheme.spacingSm),
                        TextField(
                          controller: _amountCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            prefixText: '¥ ',
                            hintText: '输入提现金额',
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(height: AppTheme.spacingXs),
                        Text('手续费: 提现金额的 1%（最低 1 元）',
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant)),
                        const SizedBox(height: AppTheme.spacingMd),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            icon: _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.payment, size: 18),
                            onPressed: _submitting ? null : _submitWithdraw,
                            label: const Text('申请提现'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingLg),
                // 提现记录
                Text('提现记录',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppTheme.spacingSm),
                if (_records.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.spacingXxl),
                      child: Text('暂无提现记录',
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant)),
                    ),
                  )
                else
                  ..._records.map((r) => Card(
                        margin:
                            const EdgeInsets.only(bottom: AppTheme.spacingXs),
                        child: ListTile(
                          title: Text('¥${r['amount']}'),
                          subtitle: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: _statusColor(
                                          r['status'] as String? ?? '', cs)
                                      .withAlpha(25),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _statusLabel(r['status'] as String? ?? ''),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _statusColor(
                                        r['status'] as String? ?? '', cs),
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppTheme.spacingSm),
                              Text(
                                (r['created_at'] as String? ?? '')
                                    .replaceAll(RegExp(r'T.*'), ''),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                          trailing: Text(
                            '手续费: ¥${r['fee'] ?? 0}',
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant),
                          ),
                        ),
                      )),
              ],
            ),
    );
  }
}
