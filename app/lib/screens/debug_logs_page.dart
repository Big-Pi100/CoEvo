import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import '../theme/co_spacing.dart';

class DebugLogsPage extends StatefulWidget {
  final Map<String, String> headers;
  const DebugLogsPage({super.key, required this.headers});

  @override
  State<DebugLogsPage> createState() => _DebugLogsPageState();
}

class _DebugLogsPageState extends State<DebugLogsPage>
    with TickerProviderStateMixin {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  late TabController _tabCtrl;

  // ── Debug Logs ──
  final _userIdCtrl = TextEditingController();
  final _convIdCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _limitCtrl = TextEditingController(text: '50');
  List<Map<String, dynamic>> _logs = [];
  bool _logsLoading = false;

  // ── Tracks ──
  List<Map<String, dynamic>> _tracks = [];
  bool _tracksLoading = false;
  bool _tracksLoaded = false;

  Future<Map<String, dynamic>> _api(String method, String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final h = widget.headers;
    final req = method == 'GET'
        ? http.get(uri, headers: h)
        : method == 'POST'
            ? http.post(uri,
                headers: {...h, 'Content-Type': 'application/json'},
                body: jsonEncode(body ?? {}))
            : http.delete(uri, headers: h);
    final resp = await req.timeout(const Duration(seconds: 10));
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'error': '${resp.statusCode}'};
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted) setState(() {});
      if (_tabCtrl.index == 1 && !_tracksLoaded) {
        _loadTracks();
      }
    });
    // 进入页面时自动加载所有日志（无需手动输入查询条件）
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLogs());
  }

  @override
  void dispose() {
    _userIdCtrl.dispose();
    _convIdCtrl.dispose();
    _dateCtrl.dispose();
    _limitCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  String _formatDetails(dynamic details) {
    if (details == null) return '';
    if (details is String) return details;
    if (details is Map) {
      return details.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    }
    return details.toString();
  }

  // ═══ Debug Logs ═══

  Future<void> _loadLogs() async {
    setState(() => _logsLoading = true);
    final params = <String>[];
    final uid = _userIdCtrl.text.trim();
    final cid = _convIdCtrl.text.trim();
    final date = _dateCtrl.text.trim();
    final limit = _limitCtrl.text.trim();
    if (uid.isNotEmpty) params.add('user_id=${Uri.encodeComponent(uid)}');
    if (cid.isNotEmpty)
      params.add('conversation_id=${Uri.encodeComponent(cid)}');
    if (date.isNotEmpty) params.add('date=${Uri.encodeComponent(date)}');
    if (limit.isNotEmpty) params.add('limit=$limit');
    final suffix = params.isEmpty ? '' : '?${params.join('&')}';
    final resp = await _api('GET', '/api/admin/debug/logs$suffix');
    setState(() {
      _logs = (resp['logs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _logsLoading = false;
    });
  }

  Future<void> _showLogDetail(Map<String, dynamic> log) async {
    final id = log['id'] as String? ?? '';
    if (id.isEmpty) return;
    final resp = await _api('GET', '/api/admin/debug/logs/$id');
    if (!mounted) return;
    final entries =
        (resp['entries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('日志详情 #${id.substring(0, id.length > 8 ? 8 : id.length)}',
            style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 600,
          child: entries.isEmpty
              ? const Text('无条目数据')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: CoSpacing.sm),
                      child: Padding(
                        padding: const EdgeInsets.all(CoSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _cs.primaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    e['phase'] as String? ?? '',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: _cs.onPrimaryContainer),
                                  ),
                                ),
                                const SizedBox(width: CoSpacing.sm),
                                Text(
                                  e['step'] as String? ?? '',
                                  style: _tt.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  (e['timestamp'] as String? ?? '')
                                      .substring(11, 19),
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: _cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                            const SizedBox(height: CoSpacing.xs),
                            Text(
                              _formatDetails(e['details']),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))
        ],
      ),
    );
  }

  // ═══ Tracks ═══

  Future<void> _loadTracks() async {
    setState(() => _tracksLoading = true);
    final resp = await _api('GET', '/api/admin/debug/tracks');
    setState(() {
      _tracks = (resp['tracks'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _tracksLoading = false;
      _tracksLoaded = true;
    });
  }

  Future<void> _createTrack() async {
    final userIdCtrl = TextEditingController();
    final convIdCtrl = TextEditingController();
    final subjectCtrl = TextEditingController();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建跟踪'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userIdCtrl,
              decoration: const InputDecoration(
                labelText: '用户 ID',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: CoSpacing.sm),
            TextField(
              controller: convIdCtrl,
              decoration: const InputDecoration(
                labelText: '会话 ID (可选)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: CoSpacing.sm),
            TextField(
              controller: subjectCtrl,
              decoration: const InputDecoration(
                labelText: '主题 (可选)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final body = <String, dynamic>{'user_id': userIdCtrl.text.trim()};
              final cid = convIdCtrl.text.trim();
              final subj = subjectCtrl.text.trim();
              if (cid.isNotEmpty) body['conversation_id'] = cid;
              if (subj.isNotEmpty) body['subject'] = subj;
              final resp =
                  await _api('POST', '/api/admin/debug/track', body: body);
              if (resp.containsKey('id')) {
                _snack('跟踪已创建');
                _loadTracks();
              } else {
                _snack(resp['error'] ?? '创建失败');
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _closeTrack(String id) async {
    final resp = await _api('DELETE', '/api/admin/debug/track/$id');
    if (resp.containsKey('status')) {
      _snack('跟踪已关闭');
      _loadTracks();
    } else {
      _snack(resp['error'] ?? '关闭失败');
    }
  }

  // ═══ Build ═══

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: '调试日志'),
            Tab(text: '用户跟踪'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildLogsTab(),
              _buildTracksTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLogsTab() {
    return Column(
      children: [
        // Search fields
        Padding(
          padding: const EdgeInsets.fromLTRB(
              CoSpacing.md, CoSpacing.md, CoSpacing.md, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _userIdCtrl,
                      decoration: const InputDecoration(
                        hintText: '用户 ID',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: CoSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _convIdCtrl,
                      decoration: const InputDecoration(
                        hintText: '会话 ID',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CoSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _dateCtrl,
                      decoration: const InputDecoration(
                        hintText: '日期 (2026-06-13)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: CoSpacing.sm),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: _limitCtrl,
                      decoration: const InputDecoration(
                        hintText: '50',
                        isDense: true,
                        border: OutlineInputBorder(),
                        labelText: '条数',
                      ),
                      style: const TextStyle(fontSize: 13),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: CoSpacing.sm),
                  FilledButton(
                    onPressed: _logsLoading ? null : _loadLogs,
                    child: const Text('查询', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: CoSpacing.sm),
        // Results count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CoSpacing.md),
          child: Row(
            children: [
              Text('${_logs.length} 条记录',
                  style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant)),
            ],
          ),
        ),
        // Log list
        Expanded(
          child: _logsLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _logs.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志数据',
                        style: TextStyle(color: _cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: CoSpacing.md),
                      itemCount: _logs.length,
                      itemBuilder: (_, i) {
                        final l = _logs[i];
                        final sizeBytes = l['file_size_bytes'];
                        String sizeStr = '';
                        if (sizeBytes != null) {
                          final bytes = int.tryParse(sizeBytes.toString()) ?? 0;
                          sizeStr = bytes > 1024
                              ? '${(bytes / 1024).toStringAsFixed(1)} KB'
                              : '$bytes B';
                        }
                        return Card(
                          margin:
                              const EdgeInsets.only(bottom: CoSpacing.sm),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _showLogDetail(l),
                            child: Padding(
                              padding: const EdgeInsets.all(CoSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          l['subject'] as String? ?? '(无主题)',
                                          style: _tt.titleSmall?.copyWith(
                                              fontWeight: FontWeight.w600),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (sizeStr.isNotEmpty)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: _cs.surfaceContainerLow,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(sizeStr,
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: _cs.onSurfaceVariant)),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: CoSpacing.xs),
                                  Text(
                                    '${l['user_id'] ?? ''}  ·  会话: ${(l['conversation_id'] as String? ?? '').substring(0, ((l['conversation_id'] as String? ?? '').length).clamp(0, 12))}',
                                    style: _tt.bodySmall
                                        ?.copyWith(color: _cs.onSurfaceVariant),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        l['date'] as String? ?? '',
                                        style: _tt.labelSmall?.copyWith(
                                            color: _cs.onSurfaceVariant),
                                      ),
                                      if (l['entry_count'] != null) ...[
                                        const SizedBox(
                                            width: CoSpacing.sm),
                                        Text(
                                          '${l['entry_count']} 条目',
                                          style: _tt.labelSmall
                                              ?.copyWith(color: _cs.primary),
                                        ),
                                      ],
                                    ],
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

  Widget _buildTracksTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              CoSpacing.md, CoSpacing.md, CoSpacing.md, 0),
          child: Row(
            children: [
              Text(
                '活跃跟踪 (${_tracks.length})',
                style: _tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                onPressed: _createTrack,
                label: const Text('新建跟踪', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: CoSpacing.sm),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _loadTracks,
                label: const Text('刷新', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _tracksLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _tracks.isEmpty
                  ? Center(
                      child: Text(
                        '暂无活跃跟踪',
                        style: TextStyle(color: _cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: CoSpacing.md),
                      itemCount: _tracks.length,
                      itemBuilder: (_, i) {
                        final t = _tracks[i];
                        return Card(
                          margin:
                              const EdgeInsets.only(bottom: CoSpacing.sm),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              // 点击跟踪项 → 跳转到调试日志 tab 并填入用户 ID 自动查询
                              final uid = t['user_id'] as String? ?? '';
                              _userIdCtrl.text = uid;
                              _tabCtrl.animateTo(0);
                              _loadLogs();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: CoSpacing.md,
                                  vertical: CoSpacing.sm),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t['subject'] as String? ?? '(无主题)',
                                          style: _tt.titleSmall?.copyWith(
                                              fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '用户: ${t['user_id'] ?? ''}',
                                          style: _tt.bodySmall?.copyWith(
                                              color: _cs.onSurfaceVariant),
                                        ),
                                        if (t['conversation_id'] != null)
                                          Text(
                                            '会话: ${t['conversation_id']}',
                                            style: _tt.labelSmall?.copyWith(
                                                color: _cs.onSurfaceVariant),
                                          ),
                                        if (t['created_at'] != null)
                                          Text(
                                            '创建: ${t['created_at']}',
                                            style: _tt.labelSmall?.copyWith(
                                                color: _cs.onSurfaceVariant),
                                          ),
                                      ],
                                    ),
                                  ),
                                  FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _cs.errorContainer,
                                      foregroundColor: _cs.onErrorContainer,
                                    ),
                                    onPressed: () =>
                                        _closeTrack(t['id'] as String? ?? ''),
                                    child: const Text('关闭',
                                        style: TextStyle(fontSize: 12)),
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
