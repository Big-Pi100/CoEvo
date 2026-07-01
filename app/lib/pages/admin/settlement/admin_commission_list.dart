import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';
import 'admin_batch_detail.dart';

/// 佣金结算页面 — 待结算佣金 + 创建批次 + 批次列表
class AdminCommissionListPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminCommissionListPage({super.key, this.adminKey, this.token});

  @override
  State<AdminCommissionListPage> createState() =>
      _AdminCommissionListPageState();
}

class _AdminCommissionListPageState extends State<AdminCommissionListPage>
    with SingleTickerProviderStateMixin {
  late TabController _subTabCtrl;

  @override
  void initState() {
    super.initState();
    _subTabCtrl = TabController(length: 2, vsync: this);
    _subTabCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subTabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _subTabCtrl,
          tabs: const [
            Tab(text: '待结算佣金'),
            Tab(text: '已结批次'),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: _subTabCtrl.index,
            children: [
              _PendingCommissionsTab(
                  adminKey: widget.adminKey, token: widget.token),
              _BatchListTab(
                  adminKey: widget.adminKey, token: widget.token),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 待结算佣金 ──
class _PendingCommissionsTab extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const _PendingCommissionsTab({this.adminKey, this.token});

  @override
  State<_PendingCommissionsTab> createState() =>
      _PendingCommissionsTabState();
}

class _PendingCommissionsTabState extends State<_PendingCommissionsTab> {
  List<Map<String, dynamic>> _commissions = [];
  final Set<String> _selected = {};
  bool _loading = false;

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
          '${ApiConfig.baseUrl}/api/admin/settlement/pending-commissions');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _commissions = (data['commissions'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _settleSelected() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    html.File? selectedFile;
    String? previewUrl;
    final noteCtrl = TextEditingController();
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setDlgState) {
        return AlertDialog(
          title: const Text('上传打款凭证'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (previewUrl != null)
                Image.network(previewUrl!, height: 200, fit: BoxFit.contain),
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注（可选）', border: OutlineInputBorder(), isDense: true),
                maxLines: 2,
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: selectedFile == null ? null : () => Navigator.pop(ctx, true), child: const Text('确认打款')),
          ],
        );
      }),
    );
    if (picked != true || !mounted) return;

    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/complete-payment');
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers);
      request.fields['expense_ids'] = ids.join(',');
      request.fields['note'] = noteCtrl.text.trim();
      final reader = html.FileReader();
      reader.readAsArrayBuffer(selectedFile!);
      await reader.onLoad.first;
      final bytes = reader.result as Uint8List;
      request.files.add(http.MultipartFile.fromBytes('image', bytes, filename: selectedFile!.name));
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200 && mounted) {
        _selected.clear();
        _load();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('结算完成')));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('结算失败: ${resp.body}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('可结算佣金 (${_commissions.length})',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                      fontSize: 13)),
              Row(children: [
                if (_selected.isNotEmpty)
                  Row(children: [
                    Text('已选 ${_selected.length} 项',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                    const SizedBox(width: AppTheme.spacingSm),
                    FilledButton.icon(
                      icon: const Icon(Icons.check_circle, size: 16),
                      onPressed: _settleSelected,
                      label: const Text('结算选中',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ]),
              ]),
                          ]),
        ),
        const SizedBox(height: AppTheme.spacingXs),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _commissions.isEmpty
                  ? Center(
                      child: TextButton(
                          onPressed: _load,
                          child: const Text('暂无待结算佣金，点击刷新')))
                  : ListView.builder(
                      itemCount: _commissions.length,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.spacingMd),
                      itemBuilder: (_, i) {
                        final c = _commissions[i];
                        final cid = c['id'] as String;
                        final selected = _selected.contains(cid);
                        return Card(
                          margin:
                              const EdgeInsets.only(bottom: AppTheme.spacingXs),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                if (selected) {
                                  _selected.remove(cid);
                                } else {
                                  _selected.add(cid);
                                }
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(AppTheme.spacingSm),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: selected,
                                    onChanged: (v) {
                                      setState(() {
                                        if (v == true) {
                                          _selected.add(cid);
                                        } else {
                                          _selected.remove(cid);
                                        }
                                      });
                                    },
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Text(c['earner_name'] as String? ?? '',
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500)),
                                          const Spacer(),
                                          Text(
                                              '¥${((c['amount'] as num?)?.toDouble() ?? 0) / 100}',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: cs.primary)),
                                        ]),
                                        const SizedBox(height: 2),
                                        Text(
                                          '手续费 ¥${((c['fee'] as num?)?.toDouble() ?? 0) / 100} · 到账 ¥${((c['actual_amount'] as num?)?.toDouble() ?? 0) / 100}',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: cs.onSurfaceVariant),
                                        ),
                                        Text(
                                          (c['created_at'] as String? ?? '')
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
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// ── 已结批次列表 ──
class _BatchListTab extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const _BatchListTab({this.adminKey, this.token});

  @override
  State<_BatchListTab> createState() => _BatchListTabState();
}

class _BatchListTabState extends State<_BatchListTab> {
  List<Map<String, dynamic>> _batches = [];
  bool _loading = false;
  Map<String, List<Map<String, dynamic>>> _batchItems = {};
  bool _markingPaid = false;
  final Set<String> _selectedBatches = {};

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
          '${ApiConfig.baseUrl}/api/admin/settlement/batches');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _batches = (data['batches'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ?? [];
        // 一次性加载所有批次的明细
        for (final b in _batches) {
          final bn = b['batch_no'] as String? ?? '';
          if (bn.isNotEmpty) {
            try {
              final detailUri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/batches/$bn');
              final detailResp = await http.get(detailUri, headers: _headers).timeout(const Duration(seconds: 10));
              if (detailResp.statusCode == 200) {
                final detailData = jsonDecode(detailResp.body) as Map<String, dynamic>;
                _batchItems[bn] = (detailData['items'] as List?)
                    ?.map((e) => e as Map<String, dynamic>)
                    .toList() ?? [];
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markPaid(String batchNo) async {
    if (_markingPaid) return;
    
    // 图片选择
    html.File? selectedFile;
    String? previewUrl;
    final noteCtrl = TextEditingController();
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setDlgState) {
        return AlertDialog(
          title: const Text('上传打款凭证'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (previewUrl != null)
                Image.network(previewUrl!, height: 200, fit: BoxFit.contain),
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注（可选）', border: OutlineInputBorder(), isDense: true),
                maxLines: 2,
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: selectedFile == null ? null : () => Navigator.pop(ctx, true), child: const Text('确认打款')),
          ],
        );
      }),
    );
    if (picked != true || !mounted) return;

    setState(() => _markingPaid = true);
    try {
      // 收集该批次所有 expense 的 ID
      final expenseIds = (_batchItems[batchNo] ?? [])
          .map((item) => item['id'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .join(',');
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/complete-payment');
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers);
      request.fields['expense_ids'] = expenseIds;
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: ${resp.body}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _markingPaid = false);
  }

  Future<void> _exportCsv(String batchNo) async {
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/batches/$batchNo/export');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final bytes = resp.bodyBytes;
        final b64 = base64Encode(bytes);
        final uri = 'data:application/zip;base64,$b64';
        html.AnchorElement(href: uri)
          ..setAttribute('download', 'batch_$batchNo.zip')
          ..click();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ZIP 已下载')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Future<void> _exportAllBatches(List<String> selected) async {
    try {
      final params = selected.isEmpty ? '' : '?batch_no=${selected.join(',')}';
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/settlement/batches/export-all$params');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200 && mounted) {
        final bytes = resp.bodyBytes;
        final b64 = base64Encode(bytes);
        final dataUri = 'data:application/zip;base64,$b64';
        html.AnchorElement(href: dataUri)
          ..setAttribute('download', 'settlement_export.zip')
          ..click();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ZIP 已下载')));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: ${resp.body}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
  }

  void _revealPhone(String uid) {
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
            if (resp.statusCode == 200 && mounted) {
              final data = jsonDecode(resp.body) as Map<String, dynamic>;
              if (mounted) {
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
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('结算批次 (${_batches.length})',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                      fontSize: 13)),
              Row(children: [
                if (_selectedBatches.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.download, size: 16),
                    onPressed: () => _exportAllBatches(_selectedBatches.toList()),
                    label: Text('导出选中 (${_selectedBatches.length})', style: TextStyle(fontSize: 12)),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  onPressed: () => _exportAllBatches([]),
                  label: const Text('导出全部', style: TextStyle(fontSize: 12)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: _load,
                  label: const Text('刷新', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _batches.isEmpty
                  ? Center(
                      child: TextButton(
                          onPressed: _load,
                          child: const Text('暂无批次，点击刷新')))
                  : ListView.builder(
                      itemCount: _batches.length,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.spacingMd),
                      itemBuilder: (_, i) {
                        final b = _batches[i];
                        final batchNo = b['batch_no'] as String? ?? '';
                        final items = _batchItems[batchNo] ?? [];
                        final checked = _selectedBatches.contains(batchNo);
                        return Card(
                          margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                          child: Column(
                            children: [
                              CheckboxListTile(
                                dense: true,
                                value: checked,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) { _selectedBatches.add(batchNo); }
                                    else { _selectedBatches.remove(batchNo); }
                                  });
                                },
                                title: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Text(batchNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                          const SizedBox(width: AppTheme.spacingXs),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.green.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: const Text('已打款', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.w500)),
                                          ),
                                        ]),
                                        Text('共 ${b['item_count'] ?? 0} 条 · ¥${((b['total_amount'] as num?)?.toDouble() ?? 0) / 100}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                                      ],
                                    ),
                                  ),
                                ]),
                              ),
                              const Divider(height: 1),
                              // 明细始终显示
                              ...items.map((item) => Padding(
                                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingXs),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(item['earner_name'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                                              GestureDetector(
                                                onTap: () {
                                                  final full = item['real_name_full'] as String?;
                                                  final masked = item['real_name'] as String? ?? '';
                                                  if (full != null && full != masked && context.mounted) {
                                                    showDialog(context: context, builder: (ctx) => AlertDialog(
                                                      title: const Text('真实姓名'), content: Text(full),
                                                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
                                                    ));
                                                  }
                                                },
                                                child: Text('${item['real_name'] as String? ?? ''} @${item['username'] as String? ?? ''}', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                                              ),
                                              if ((item['phone'] as String? ?? '').isNotEmpty)
                                                GestureDetector(
                                                  onTap: () => _revealPhone(item['earner_id'] as String),
                                                  child: Text('📞 ${item['phone'] as String}', style: TextStyle(fontSize: 10, color: cs.primary, decoration: TextDecoration.underline)),
                                                ),
                                              Text('金额: ¥${((item['amount'] as num?)?.toDouble() ?? 0) / 100} · 类型: ${item['expense_type'] as String? ?? ''} · 状态: ${item['status'] as String? ?? ''}', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                                            ],
                                          ),
                                        ),
                                      ]),
                                      const Divider(height: 1),
                                    ],
                                  ),
                                )),
                              ],
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
