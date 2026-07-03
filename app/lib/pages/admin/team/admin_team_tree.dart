import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';
import 'admin_user_detail_sheet.dart';
import '../../../widgets/twemoji.dart';

/// 分销团队搜索页面
class AdminTeamTreePage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminTeamTreePage({super.key, this.adminKey, this.token});

  @override
  State<AdminTeamTreePage> createState() => _AdminTeamTreePageState();
}

class _AdminTeamTreePageState extends State<AdminTeamTreePage> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _members = [];
  bool _loading = false;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final q = _searchCtrl.text.trim();
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/team${q.isNotEmpty ? '?search=${Uri.encodeComponent(q)}' : ''}');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _members = (data['team'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _showUserDetail(String userId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => AdminUserDetailSheet(
        userId: userId,
        adminKey: widget.adminKey,
        token: widget.token,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // 搜索框
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingMd, AppTheme.spacingSm),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: '搜索 display_name / referral_code',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: _search,
              ),
            ],
          ),
        ),
        // 结果
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _members.isEmpty
                  ? Center(
                      child: TextButton(
                          onPressed: _search,
                          child: Tw('暂无数据，点击刷新')))
                  : ListView.builder(
                      itemCount: _members.length,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.spacingMd),
                      itemBuilder: (_, i) {
                        final m = _members[i];
                        final code = m['referral_code'] as String? ?? '';
                        return Card(
                          margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cs.primary.withValues(alpha: 0.15),
                              child: Tw(
                                (m['display_name'] as String? ?? '?')
                                    .substring(0, 1)
                                    .toUpperCase(),
                                style: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            title: Text(m['display_name'] as String? ?? '',
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text('推广码: $code',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _showUserDetail(m['id'] as String),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
