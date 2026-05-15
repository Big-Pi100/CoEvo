import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  String? _adminKey;
  final _searchController = TextEditingController();
  final _keyController = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = false;
  String? _error;

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() { _isLoading = true; _error = null; });

    final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/users?q=$q');
    final resp = await http.get(uri, headers: {
      'X-Admin-Key': _adminKey!,
    }).timeout(const Duration(seconds: 5));

    if (resp.statusCode != 200) {
      setState(() { _isLoading = false; _error = '查询失败 (${resp.statusCode})'; });
      return;
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final users = (data['users'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>)
        .toList() ?? [];
    setState(() { _users = users; _isLoading = false; });
  }

  Future<void> _setSubscription(String userId, String expires) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/user/$userId/preferences');
    final resp = await http.put(uri,
      headers: {
        'X-Admin-Key': _adminKey!,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'subscription_expires': expires.length == 10 ? '${expires}T00:00:00Z' : expires,
      }),
    );
    if (resp.statusCode == 200) {
      _search();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$userId 到期日设为 $expires')),
      );
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置失败: ${resp.statusCode}')),
      );
    }
  }

  void _showSetDateDialog(Map<String, dynamic> user) {
    final userId = user['user_id'] as String? ?? '';
    final username = user['username'] as String? ?? '';
    final currentExpires = user['subscription_expires'] as String?;
    final dateCtl = TextEditingController(text: currentExpires ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置到期日'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('用户: $userId', style: const TextStyle(fontSize: 13)),
            Text('昵称: $username', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: dateCtl,
              decoration: const InputDecoration(
                labelText: '到期日 (yyyy-mm-dd)',
                hintText: '如 2027-12-31',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () {
            Navigator.pop(ctx);
            _setSubscription(userId, dateCtl.text.trim());
          }, child: const Text('保存')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_adminKey == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('管理员后台')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings, size: 64, color: Colors.grey),
                const SizedBox(height: 24),
                Text('输入管理员密钥', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                TextField(
                  controller: _keyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'admin key',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    final key = _keyController.text.trim();
                    if (key.isNotEmpty) setState(() => _adminKey = key);
                  },
                  child: const Text('进入'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('管理员后台')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜索用户 (ID 或用户名)',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isLoading ? null : _search,
                  icon: _isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: const Text('查找'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _users.isEmpty
                ? Center(child: Text('输入用户名或 ID 搜索', style: TextStyle(color: Colors.grey.shade500)))
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (_, i) {
                      final u = _users[i];
                      final userId = u['user_id'] as String? ?? '';
                      final username = u['username'] as String? ?? '';
                      final expires = u['subscription_expires'] as String?;
                      final isActive = expires != null && expires.compareTo(
                        DateTime.now().toIso8601String().substring(0, 10),
                      ) >= 0;

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: ListTile(
                          title: Text(userId, style: const TextStyle(fontSize: 14)),
                          subtitle: Text(username, style: const TextStyle(fontSize: 12)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Chip(
                                label: Text(
                                  isActive ? '已激活' : '未激活',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? Colors.green : Colors.grey,
                                  ),
                                ),
                                backgroundColor: isActive
                                    ? Colors.green.shade50
                                    : Colors.grey.shade100,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.edit_calendar, size: 20),
                                onPressed: () => _showSetDateDialog(u),
                                tooltip: '设置到期日',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
