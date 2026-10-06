import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:coevo_shared/api/api_config.dart';
import '../../../theme/app_theme.dart';

/// 批次明细页
class AdminBatchDetailPage extends StatefulWidget {
  final String batchNo;
  final String? adminKey;
  final String? token;

  const AdminBatchDetailPage({
    super.key,
    required this.batchNo,
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
          '${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchNo}');
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
    // 图片选择对话框
    html.File? selectedFile;
    String? previewUrl;
    final noteCtrl = TextEditingController();
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setDlgState) {
        return AlertDialog(
          title: const Text('上传打款凭证'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (previewUrl != null)
                  Image.network(previewUrl!, height: 200, fit: BoxFit.contain),
                const SizedBox(height: AppTheme.spacingSm),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image, size: 16),
                  onPressed: () {
                    final input = html.FileUploadInputElement()..accept = 'image/png,image/jpeg';
                    input.click();
                    input.onChange.listen((_) {
                      if (input.files!.isNotEmpty) {
                        final file = input.files![0];
                        selectedFile = file;
                        previewUrl = html.Url.createObjectUrlFromBlob(file);
                        setDlgState(() {});
                      }
                    });
                  },
                  label: const Text('选择图片 (PNG/JPEG)', style: TextStyle(fontSize: 12)),
                ),
                if (selectedFile != null)
                  Text('已选择: ${selectedFile!.name}', style: const TextStyle(fontSize: 11, color: Colors.green)),
                const SizedBox(height: AppTheme.spacingSm),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: '备注（可选）', border: OutlineInputBorder(), isDense: true),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: selectedFile == null ? null : () => Navigator.pop(ctx, true),
              child: const Text('确认打款'),
            ),
          ],
        );
      }),
    );
    if (picked != true || !mounted) return;

    setState(() => _markingPaid = true);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchNo}/mark-paid');
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers);
      request.fields['note'] = noteCtrl.text.trim();
      final reader = html.FileReader();
      reader.readAsArrayBuffer(selectedFile!);
      await reader.onLoad.first;
      final bytes = reader.result as Uint8List;
      request.files.add(http.MultipartFile.fromBytes('image', bytes, filename: selectedFile!.name));
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200 && mounted) {
        _load();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已标记打款')));
      } else if (mounted) {
        final body = resp.body;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: $body')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _markingPaid = false);
  }

  Future<void> _exportCsv() async {
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/settlement/batches/${widget.batchNo}/export');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final bytes = resp.bodyBytes;
        // Web: download as ZIP
        final b64 = base64Encode(bytes);
        final uri = 'data:application/zip;base64,$b64';
        html.AnchorElement(href: uri)
          ..setAttribute('download', 'batch_${widget.batchNo}.zip')
          ..click();
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
    final isPending = _batch?['status']?.toString() == 'pending' || _batch?['status']?.toString() == 'confirmed';

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
                                _infoCol(cs, '状态',
                                    _batch!['status'] as String? ?? ''),
                                _infoCol(cs, '条数',
                                    '${_items.length}'),
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
                    // 明细列表
                    Text('明细 (${_items.length})',
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          item['earner_name'] as String? ?? '',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                      GestureDetector(
                                        onTap: () {
                                          final full = item['real_name_full'] as String?;
                                          final masked = item['real_name'] as String? ?? '';
                                          if (full != null && full != masked && context.mounted) {
                                            showDialog(context: context, builder: (ctx) => AlertDialog(
                                              title: const Text('真实姓名'),
                                              content: Text(full),
                                              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
                                            ));
                                          }
                                        },
                                        child: Text('${item['real_name'] as String? ?? ''} @${item['username'] as String? ?? ''}',
                                            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                                      ),
                                      if ((item['phone'] as String? ?? '').isNotEmpty)
                                        GestureDetector(
                                          onTap: () {
                                            final uid = item['earner_id'] as String;
                                            showDialog(context: context, builder: (ctx) => AlertDialog(
                                              title: const Text('确认查看手机号'),
                                              content: const Text('此操作将被记录到审计日志。'),
                                              actions: [
                                                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                                                FilledButton(onPressed: () async {
                                                  Navigator.pop(ctx);
                                                  try {
                                                    final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/users/$uid/reveal-phone?full=true');
                                                    final resp = await http.post(uri, headers: _headers).timeout(const Duration(seconds: 10));
                                                    if (resp.statusCode == 200 && context.mounted) {
                                                      final data = jsonDecode(resp.body) as Map<String, dynamic>;
                                                      if (context.mounted) {
                                                        showDialog(context: context, builder: (ctx) => AlertDialog(
                                                          title: const Text('完整手机号'),
                                                          content: Text(data['phone'] as String? ?? ''),
                                                          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
                                                        ));
                                                      }
                                                    }
                                                  } catch (_) {}
                                                }, child: const Text('确认查看')),
                                              ],
                                            ));
                                          },
                                          child: Text('📞 ${item['phone'] as String}',
                                              style: TextStyle(fontSize: 11, color: cs.primary, decoration: TextDecoration.underline)),
                                        ),
                                      Text(
                                        '金额: ¥${((item['amount'] as num?)?.toDouble() ?? 0) / 100}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: cs.onSurfaceVariant),
                                      ),
                                      if (item['expense_type'] != null)
                                        Text(
                                          '类型: ${item['expense_type']}',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: cs.onSurfaceVariant),
                                        ),
                                    ],
                                  ),
                                ),
                              ]),
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
