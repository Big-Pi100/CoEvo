import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';
import 'admin_batch_detail.dart';

/// 批次列表页（独立页面）
class AdminBatchListPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminBatchListPage({super.key, this.adminKey, this.token});

  @override
  State<AdminBatchListPage> createState() => _AdminBatchListPageState();
}

class _AdminBatchListPageState extends State<AdminBatchListPage> {
  List<Map<String, dynamic>> _batches = [];
  bool _loading = false;

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
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/batches');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _batches = (data['batches'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ?? [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _openDetail(Map<String, dynamic> batch) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminBatchDetailPage(
          batchId: batch['id'] as String,
          adminKey: widget.adminKey,
          token: widget.token,
        ),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('结算批次')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _batches.isEmpty
              ? Center(
                  child: TextButton(
                      onPressed: _load, child: const Text('暂无批次，点击刷新')))
              : ListView.builder(
                  itemCount: _batches.length,
                  padding: const EdgeInsets.all(AppTheme.spacingMd),
                  itemBuilder: (_, i) {
                    final b = _batches[i];
                    final status = b['status'] as String? ?? '';
                    final isPaid = status == 'paid';
                    return Card(
                      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                      child: ListTile(
                        title: Row(children: [
                          Text(b['batch_no'] as String? ?? '',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isPaid
                                  ? Colors.green.withValues(alpha: 0.15)
                                  : Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              isPaid ? '已打款' : '待打款',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: isPaid ? Colors.green : Colors.orange,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                        ]),
                        subtitle: Text(
                          '¥${(b['total_amount'] as num?)?.toDouble() ?? 0} · ${b['commission_count'] ?? 0}条 · ${(b['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}',
                          style:
                              TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => _openDetail(b),
                      ),
                    );
                  },
                ),
    );
  }
}
