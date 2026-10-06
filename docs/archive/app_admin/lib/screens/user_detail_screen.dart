import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:coevo_shared/api/api_config.dart';
import '../theme/app_theme.dart';

class UserDetailScreen extends StatefulWidget {
  final String userId;
  final String? adminKey;
  final String? token;
  final String role;
  const UserDetailScreen({super.key, required this.userId, this.adminKey, this.token, required this.role});

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> with TickerProviderStateMixin {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _cards = [];
  List<Map<String, dynamic>> _convs = [];
  bool _loading = true;
  bool? _isTracked;
  int _tabIdx = 0;

  Map<String, String> _headers() {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  Future<Map<String, dynamic>> _api(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final h = _headers();
    final req = method == 'GET'
        ? http.get(uri, headers: h)
        : http.post(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
    final resp = await req.timeout(const Duration(seconds: 10));
    try { return jsonDecode(resp.body) as Map<String, dynamic>; } catch (_) { return {'error': '${resp.statusCode}'}; }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final user = await _api('GET', '/api/admin/users/${widget.userId}');
      final cards = await _api('GET', '/api/admin/guardian/students/${widget.userId}/cards');
      final convs = await _api('GET', '/api/admin/guardian/students/${widget.userId}/conversations');
      if (mounted) setState(() {
        _user = user;
        _cards = (cards['cards'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _convs = (convs['conversations'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _loadTrackStatus();
  }

  Future<void> _loadTrackStatus() async {
    try {
      final resp = await _api('GET', '/api/admin/debug/tracks');
      if (resp.containsKey('tracks')) {
        final tracks = resp['tracks'] as List;
        final found = tracks.any((t) => t is Map && t['user_id'] == widget.userId);
        if (mounted) setState(() => _isTracked = found);
      }
    } catch (_) {}
  }

  Future<void> _startTrack() async {
    final resp = await _api('POST', '/api/admin/debug/track', body: {'user_id': widget.userId});
    if (resp.containsKey('id')) {
      if (mounted) {
        setState(() => _isTracked = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已开始跟踪该用户')));
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(resp['error'] ?? '跟踪失败')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_user?['display_name'] ?? _user?['username'] ?? '用户详情'),
        actions: [
          if (_isTracked == true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSm),
              child: Chip(
                avatar: Icon(Icons.track_changes, size: 14, color: _cs.primary),
                label: const Text('正在跟踪', style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            )
          else if (_isTracked == false)
            TextButton.icon(
              icon: const Icon(Icons.track_changes, size: 16),
              onPressed: _startTrack,
              label: const Text('跟踪', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _user == null
          ? const Center(child: Text('加载失败'))
          : Column(children: [
              // Basic info
              Card(
                margin: const EdgeInsets.all(AppTheme.spacingMd),
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('ID: ${_user!['user_id'] ?? ''}', style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant)),
                    const SizedBox(height: AppTheme.spacingXs),
                    Text('用户名: ${_user!['username'] ?? ''}', style: const TextStyle(fontSize: 13)),
                    Text('真实姓名: ${_user!['real_name'] ?? '—'}', style: const TextStyle(fontSize: 13)),
                    Text('手机号: ${_user!['phone'] ?? '—'}', style: const TextStyle(fontSize: 13)),
                    Text('注册: ${_user!['created_at']?.toString().replaceAll(RegExp(r'T.*'), '') ?? ''}', style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant)),
                    const SizedBox(height: AppTheme.spacingSm),
                    Wrap(spacing: 8, children: [
                      _statBadge('卡片', '${_user!['card_count'] ?? 0}'),
                      _statBadge('复习', '${_user!['review_count'] ?? 0}'),
                      _statBadge('连续', '${_user!['streak_days'] ?? 0}天'),
                      _statBadge('订阅', _user!['subscription_expires'] != null ? '${_user!['subscription_expires']}' : '未激活'),
                    ]),
                  ]),
                ),
              ),
              // Tab bar for cards/conversations
              TabBar(
                tabs: const [Tab(text: '卡片'), Tab(text: '对话')],
                controller: TabController(length: 2, vsync: this, initialIndex: _tabIdx),
                onTap: (i) => setState(() => _tabIdx = i),
              ),
              Expanded(child: _tabIdx == 0 ? _buildCardsTab() : _buildConvsTab()),
            ]),
    );
  }

  Widget _statBadge(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: AppTheme.spacingXs),
      decoration: BoxDecoration(color: _cs.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
      child: Text('$label: $value', style: _tt.bodySmall!),
    );
  }

  Widget _buildCardsTab() {
    if (_cards.isEmpty) return const Center(child: Text('暂无卡片'));
    final states = ['新', '学习', '复习', '重学'];
    return ListView.builder(itemCount: _cards.length, itemBuilder: (_, i) {
      final c = _cards[i];
      return ListTile(
        dense: true,
        title: Text(c['front'] ?? '', style: _tt.bodyMedium!),
        subtitle: Text('${states[c['state'] ?? 0]} · 复习${c['reps']}次'),
        trailing: Icon(Icons.circle, size: 10, color: [_cs.outline, _cs.tertiary, _cs.primary, _cs.error][(c['state'] ?? 0).clamp(0, 3)]),
      );
    });
  }

  Widget _buildConvsTab() {
    if (_convs.isEmpty) return const Center(child: Text('暂无对话'));
    return ListView.builder(itemCount: _convs.length, itemBuilder: (_, i) {
      final conv = _convs[i];
      return ListTile(
        title: Text(conv['title'] ?? '', maxLines: 2),
        subtitle: Text('${conv['turn_count']}轮 · ${(conv['started_at'] ?? '').toString().replaceAll(RegExp(r'T.*'), '')}'),
      );
    });
  }
}
