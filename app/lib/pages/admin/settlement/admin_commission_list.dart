import 'dart:convert';
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
  bool _creating = false;

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

  Future<void> _createBatch() async {
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先勾选要结算的佣金')));
      return;
    }
    setState(() => _creating = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/settlement/create-batch');
      final resp = await http
          .post(uri,
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode({'commission_ids': _selected.toList()}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _selected.clear();
        _load();
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '批次 ${data['batch_no']} 已创建 (¥${(data['total_amount'] as num?)?.toDouble() ?? 0})')));
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('创建批次失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _creating = false);
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
                  Text('已选 ${_selected.length} 项',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(width: AppTheme.spacingSm),
                FilledButton.icon(
                  icon: _creating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.fact_check, size: 16),
                  onPressed: _creating ? null : _createBatch,
                  label: const Text('创建结算批次',
                      style: TextStyle(fontSize: 12)),
                ),
              ]),
            ],
          ),
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
                                              '¥${(c['amount'] as num?)?.toDouble() ?? 0}',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: cs.primary)),
                                        ]),
                                        const SizedBox(height: 2),
                                        Text(
                                          '订单: ${c['order_id'] as String? ?? ''} · ${c['plan_id'] as String? ?? ''}',
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
                .toList() ??
            [];
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
                        final status = b['status'] as String? ?? '';
                        final isPaid = status == 'paid';
                        return Card(
                          margin:
                              const EdgeInsets.only(bottom: AppTheme.spacingSm),
                          child: ListTile(
                            title: Row(children: [
                              Text(b['batch_no'] as String? ?? '',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
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
                                      color: isPaid
                                          ? Colors.green
                                          : Colors.orange,
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            ]),
                            subtitle: Text(
                              '¥${(b['total_amount'] as num?)?.toDouble() ?? 0} · ${b['commission_count'] ?? 0}条 · ${(b['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '')}',
                              style: TextStyle(
                                  fontSize: 11, color: cs.onSurfaceVariant),
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _openDetail(b),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
