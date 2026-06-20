import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';

/// 用户详情底部弹窗
class AdminUserDetailSheet extends StatefulWidget {
  final String userId;
  final String? adminKey;
  final String? token;

  const AdminUserDetailSheet({
    super.key,
    required this.userId,
    this.adminKey,
    this.token,
  });

  @override
  State<AdminUserDetailSheet> createState() => _AdminUserDetailSheetState();
}

class _AdminUserDetailSheetState extends State<AdminUserDetailSheet> {
  Map<String, dynamic>? _data;
  bool _loading = true;

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
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/team/${widget.userId}');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _data = jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scrollCtrl) => Padding(
        padding: const EdgeInsets.all(AppTheme.spacingLg),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _data == null
                ? const Center(child: Text('加载失败'))
                : ListView(
                    controller: scrollCtrl,
                    children: [
                      // 用户基本信息
                      Center(
                        child: CircleAvatar(
                          radius: 32,
                          backgroundColor: cs.primary.withValues(alpha: 0.15),
                          child: Text(
                            (_data!['user']?['display_name'] as String? ?? '?')
                                .substring(0, 1)
                                .toUpperCase(),
                            style: TextStyle(
                                fontSize: 24,
                                color: cs.primary,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      Text(
                        _data!['user']?['display_name'] as String? ?? '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: AppTheme.spacingXs),
                      Text(
                        '推广码: ${_data!['user']?['referral_code'] as String? ?? ''}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                      Text(
                        '注册时间: ${_data!['user']?['created_at'] as String? ?? ''}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppTheme.spacingLg),
                      // 统计卡片
                      Row(
                        children: [
                          _statCard(cs, '点击数',
                              '${_data!['stats']?['total_clicks'] ?? 0}'),
                          const SizedBox(width: AppTheme.spacingSm),
                          _statCard(cs, '下线人数',
                              '${_data!['stats']?['total_referrals'] ?? 0}'),
                          const SizedBox(width: AppTheme.spacingSm),
                          _statCard(cs, '佣金总额',
                              '${_data!['stats']?['total_commission'] ?? 0}'),
                        ],
                      ),
                      const SizedBox(height: AppTheme.spacingLg),
                      // 最近点击记录
                      Text('最近点击记录',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                              fontSize: 13)),
                      const SizedBox(height: AppTheme.spacingSm),
                      if ((_data!['recent_clicks'] as List?)?.isEmpty ?? true)
                        Text('暂无点击记录',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant))
                      else
                        ...(_data!['recent_clicks'] as List)
                            .take(10)
                            .map((click) => Card(
                                  margin: const EdgeInsets.only(
                                      bottom: AppTheme.spacingXs),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                        AppTheme.spacingSm),
                                    child: Row(
                                      children: [
                                        Icon(Icons.touch_app,
                                            size: 16,
                                            color: cs.onSurfaceVariant),
                                        const SizedBox(
                                            width: AppTheme.spacingSm),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '活动: ${click['campaign_id'] as String? ?? ''}',
                                                style: const TextStyle(
                                                    fontSize: 12),
                                              ),
                                              if (click['share_channel'] != null)
                                                Text(
                                                  '渠道: ${click['share_channel']}',
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          cs.onSurfaceVariant),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          (click['created_at'] as String? ??
                                                  '')
                                              .replaceAll(
                                                  RegExp(r'T.*'), ''),
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: cs.onSurfaceVariant),
                                        ),
                                      ],
                                    ),
                                  ),
                                )),
                    ],
                  ),
      ),
    );
  }

  Widget _statCard(ColorScheme cs, String label, String value) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: cs.primary)),
              Text(label,
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
