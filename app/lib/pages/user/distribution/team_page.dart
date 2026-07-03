import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/twemoji.dart';

/// 团队页面 — 树形展示下线成员（最多 2 级）
class TeamPage extends ConsumerWidget {
  const TeamPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _TeamPageBody(auth: auth);
  }
}

class _TeamPageBody extends StatefulWidget {
  final AuthState auth;
  const _TeamPageBody({required this.auth});

  @override
  State<_TeamPageBody> createState() => _TeamPageBodyState();
}

class _TeamPageBodyState extends State<_TeamPageBody> {
  List<Map<String, dynamic>> _team = [];
  bool _loading = true;
  final Set<String> _expanded = {};

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

  Future<void> _load() async {
    if (_userId.isEmpty) return;
    setState(() => _loading = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/my-team?user_id=$_userId');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _team = (data['team'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Tw('我的团队')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _team.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.people_outline,
                                    size: 64,
                                    color: cs.onSurfaceVariant),
                                const SizedBox(height: AppTheme.spacingMd),
                                Text('暂无团队成员',
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: cs.onSurfaceVariant)),
                                const SizedBox(height: AppTheme.spacingSm),
                                Text('分享推广码邀请好友加入吧',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(AppTheme.spacingMd),
                      children: [
                        Text('团队成员 (${_team.length})',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.primary)),
                        const SizedBox(height: AppTheme.spacingSm),
                        ..._buildTree(cs),
                      ],
                    ),
            ),
    );
  }

  List<Widget> _buildTree(ColorScheme cs) {
    final level1 = _team.where((m) => m['level'] == 1).toList();
    final level2 = _team.where((m) => m['level'] == 2).toList();

    final widgets = <Widget>[];
    for (final m1 in level1) {
      final m1id = m1['id'] as String;
      final hasChildren = _team.any(
          (m) => m['level'] == 2 && m['referred_by'] == m1id);

      widgets.add(_memberTile(cs, m1, 0));
      if (hasChildren) {
        final collapsed = !_expanded.contains(m1id);
        if (collapsed) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 4),
              child: InkWell(
                onTap: () => setState(() => _expanded.add(m1id)),
                child: Row(
                  children: [
                    Icon(Icons.expand_more,
                        size: 16, color: cs.onSurfaceVariant),
                    Text('展开下级成员',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          );
        } else {
          for (final m2 in level2.where((m) => m['referred_by'] == m1id)) {
            widgets.add(_memberTile(cs, m2, 1));
          }
          // Collapse button
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 4),
              child: InkWell(
                onTap: () => setState(() => _expanded.remove(m1id)),
                child: Row(
                  children: [
                    Icon(Icons.expand_less,
                        size: 16, color: cs.onSurfaceVariant),
                    Text('收起',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }
    return widgets;
  }

  Widget _memberTile(ColorScheme cs, Map<String, dynamic> m, int depth) {
    final name = m['display_name'] as String? ?? '';
    final refCount = m['referral_count'] ?? 0;
    final level = m['level'] as int? ?? 1;

    return Padding(
      padding: EdgeInsets.only(left: 16.0 * depth, bottom: 4),
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: cs.primary.withValues(alpha: 0.15),
            child: Tw(
              name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
              style:
                  TextStyle(fontSize: 14, color: cs.primary, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(name, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            'Level $level · 邀请 ${refCount}人',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
