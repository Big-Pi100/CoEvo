import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';

/// 提现审核列表页
class AdminWithdrawalListPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminWithdrawalListPage({super.key, this.adminKey, this.token});

  @override
  State<AdminWithdrawalListPage> createState() => _AdminWithdrawalListPageState();
}

class _AdminWithdrawalListPageState extends State<AdminWithdrawalListPage> {
  List<Map<String, dynamic>> _withdrawals = [];
  bool _loading = false;
  String? _processingId;

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
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/withdrawals');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _withdrawals = (data['withdrawals'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ?? [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _approve(String id) async {
    setState(() => _processingId = id);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/withdrawals/$id/approve');
      final resp = await http.post(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _load();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过，批次: ${data['batch_no'] ?? ''}')),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('审核通过失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _processingId = null);
  }

  Future<void> _reject(String id) async {
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('驳回原因'),
        content: TextField(
          controller: reasonCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '请输入驳回原因',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, reasonCtrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认驳回'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;

    setState(() => _processingId = id);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/withdrawals/$id/reject');
      final resp = await http.post(
        uri,
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'note': reason}),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _load();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已驳回')));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('驳回失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _processingId = null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingXs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('待审核提现 (${_withdrawals.length})',
                  style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary, fontSize: 13)),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _load,
                label: const Text('刷新', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _withdrawals.isEmpty
                  ? Center(child: TextButton(onPressed: _load, child: const Text('暂无待审核提现，点击刷新')))
                  : ListView.builder(
                      itemCount: _withdrawals.length,
                      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
                      itemBuilder: (_, i) {
                        final w = _withdrawals[i];
                        final wid = w['id'] as String;
                        final isProcessing = _processingId == wid;
                        return Card(
                          margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                          child: Padding(
                            padding: const EdgeInsets.all(AppTheme.spacingMd),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(w['earner_name'] as String? ?? '',
                                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                        Text('¥${(w['amount'] as num?)?.toDouble() ?? 0}',
                                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.primary)),
                                      ],
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: AppTheme.spacingXs),
                                Text(
                                  '申请时间: ${(w['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}',
                                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                                ),
                                const SizedBox(height: AppTheme.spacingSm),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.close, size: 16),
                                      onPressed: isProcessing ? null : () => _reject(wid),
                                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                                      label: const Text('驳回', style: TextStyle(fontSize: 12)),
                                    ),
                                    const SizedBox(width: AppTheme.spacingSm),
                                    FilledButton.icon(
                                      icon: isProcessing
                                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                          : const Icon(Icons.check, size: 16),
                                      onPressed: isProcessing ? null : () => _approve(wid),
                                      label: const Text('通过', style: TextStyle(fontSize: 12)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
