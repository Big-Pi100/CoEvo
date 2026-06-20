import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';

/// 批次明细页
class AdminBatchDetailPage extends StatefulWidget {
  final String batchId;
  final String? adminKey;
  final String? token;

  const AdminBatchDetailPage({
    super.key,
    required this.batchId,
    this.adminKey,
    this.token,
  });

  @override
  State<AdminBatchDetailPage> createState() => _AdminBatchDetailPageState();
}

class _AdminBatchDetailPageState extends State<AdminBatchDetailPage> {
  Map<String, dynamic>? _batch;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _markingPaid = false;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) {
      return {'Authorization': 'Bearer ${widget.token}'};
    }
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
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchId}');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _batch = data['batch'] as Map<String, dynamic>?;
        _items = (data['items'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markPaid() async {
    final noteCtrl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标记已打款'),
        content: TextField(
          controller: noteCtrl,
          decoration: const InputDecoration(
              labelText: '打款备注（可选）',
              border: OutlineInputBorder(),
              isDense: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim()),
              child: const Text('确认打款')),
        ],
      ),
    );
    if (note == null && mounted) return;
    if (!mounted) return;

    setState(() => _markingPaid = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchId}/mark-paid');
      final resp = await http
          .post(uri,
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode({'note': note ?? ''}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _load();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已标记打款')));
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _markingPaid = false);
  }

  Future<void> _exportCsv() async {
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchId}/export');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final csvContent = resp.body;
        // Web: download via Blob
        final blob = html.Blob([csvContent], 'text/csv');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', 'batch_${widget.batchId}.csv')
          ..click();
        html.Url.revokeObjectUrl(url);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('CSV 已下载')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPending = _batch?['status']?.toString() == 'pending';

    return Scaffold(
      appBar: AppBar(title: Text(_batch?['batch_no'] as String? ?? '批次明细')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _batch == null
              ? const Center(child: Text('批次不存在'))
              : ListView(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  children: [
                    // 批次信息头部
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppTheme.spacingMd),
                        child: Column(
                          children: [
                            Text(
                              _batch!['batch_no'] as String? ?? '',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: AppTheme.spacingSm),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _infoCol(cs, '总金额',
                                    '¥${(_batch!['total_amount'] as num?)?.toDouble() ?? 0}'),
                                _infoCol(cs, '条数',
                                    '${_batch!['commission_count'] ?? 0}'),
                                _infoCol(cs, '状态',
                                    _batch!['status'] as String? ?? ''),
                              ],
                            ),
                            if (_batch!['paid_at'] != null) ...[
                              const SizedBox(height: AppTheme.spacingSm),
                              Text(
                                '打款时间: ${_batch!['paid_at']}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    // 操作按钮
                    if (isPending)
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              icon: _markingPaid
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.check_circle, size: 16),
                              onPressed: _markingPaid ? null : _markPaid,
                              label: const Text('标记已打款',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ),
                          const SizedBox(width: AppTheme.spacingSm),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.download, size: 16),
                              onPressed: _exportCsv,
                              label: const Text('导出 CSV',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ),
                        ],
                      ),
                    if (!isPending)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.download, size: 16),
                        onPressed: _exportCsv,
                        label: const Text('导出 CSV',
                            style: TextStyle(fontSize: 13)),
                      ),
                    const SizedBox(height: AppTheme.spacingMd),
                    // 佣金明细列表
                    Text('佣金明细 (${_items.length})',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                            fontSize: 13)),
                    const SizedBox(height: AppTheme.spacingSm),
                    ..._items.map(
                      (item) => Card(
                        margin:
                            const EdgeInsets.only(bottom: AppTheme.spacingXs),
                        child: Padding(
                          padding: const EdgeInsets.all(AppTheme.spacingSm),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        item['earner_name'] as String? ?? '',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500)),
                                    Text(
                                      '金额: ¥${(item['amount'] as num?)?.toDouble() ?? 0} · 等级: ${item['level'] ?? 0}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant),
                                    ),
                                    Text(
                                      (item['created_at'] as String? ?? '')
                                          .replaceAll(RegExp(r'T.*'), ''),
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _infoCol(ColorScheme cs, String label, String value) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: cs.primary)),
        Text(label,
            style:
                TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
  }
}
