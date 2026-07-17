import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/twemoji.dart';

/// 通知中心页面
class NotificationPanel extends ConsumerWidget {
  const NotificationPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _NotificationPanelBody(auth: auth);
  }
}

class _NotificationPanelBody extends StatefulWidget {
  final AuthState auth;
  const _NotificationPanelBody({required this.auth});

  @override
  State<_NotificationPanelBody> createState() => _NotificationPanelBodyState();
}

class _NotificationPanelBodyState extends State<_NotificationPanelBody> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  bool _dialogOpen = false; // 防弹窗堆叠锁

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
          '${ApiConfig.baseUrl}/api/notifications?user_id=$_userId');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _notifications = (data['notifications'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ?? [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markRead(String id) async {
    try {
      await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/notifications/$id/read'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': _userId}),
      ).timeout(const Duration(seconds: 5));
      _load();
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    try {
      await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/notifications/read-all'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': _userId}),
      ).timeout(const Duration(seconds: 5));
      _load();
    } catch (_) {}
  }

  IconData _typeIcon(String? type) {
    switch (type) {
      case 'marketing_campaign':
        return Icons.campaign;
      case 'withdrawal':
        return Icons.payment;
      case 'commission':
        return Icons.monetization_on;
      case 'reward':
        return Icons.card_giftcard;
      case 'share_poster':
      case 'share_h5':
        return Icons.share;
      case 'system':
        return Icons.info_outline;
      default:
        return Icons.notifications;
    }
  }

  /// 活动/分享通知 → 调 API 获取 H5 分享链接，在新标签页打开
  Future<void> _openH5InNewTab(Map<String, dynamic> n) async {
    try {
      final auth = widget.auth;
      final userId = auth.userId;
      final token = auth.token;
      String? campaignId;
      final actionUrl = n['action_url'] as String?;
      if (actionUrl != null && actionUrl.startsWith('share?campaign_id=')) {
        campaignId = actionUrl.substring('share?campaign_id='.length);
      }
      // 调 API 获取 H5 分享 URL（含用户邀请码）
      if (userId != null && token != null && campaignId != null) {
        final resp = await http.post(
          Uri.parse('${ApiConfig.baseUrl}/api/referral/generate-h5'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'campaign_id': campaignId}),
        ).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final url = data['url'] as String?;
          if (url != null && url.isNotEmpty) {
            html.window.open(url, '_blank');
            _dialogOpen = false;
            return;
          }
        }
      }
    } catch (_) {}
    // fallback: 打开通用分享页
    try {
      html.window.open('${ApiConfig.baseUrl}/share/', '_blank');
    } catch (_) {}
    _dialogOpen = false;
  }

  void _navigateByType(BuildContext context, Map<String, dynamic> n) {
    final type = n['notification_type'] as String?;
    _markRead(n['id'] as String);

    // 活动推送和分享类通知 → 在新标签页打开 H5 分享页（避免 Flutter Web iframe 卡死）
    if (type == 'campaign_push' || type == 'share_poster' || type == 'share_h5' || type == 'marketing_campaign') {
      if (_dialogOpen) return; // 防止重复点击
      _dialogOpen = true;
      _openH5InNewTab(n);
      return;
    }

    switch (type) {
      case 'commission':
      case 'reward_earned':
        GoRouter.of(context).push('/earnings');
        break;
      case 'withdrawal':
      case 'withdrawal_status':
        GoRouter.of(context).push('/withdraw');
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unreadCount = _notifications.where((n) => n['read'] == false).length;

    return Scaffold(
      appBar: AppBar(
        title: Tw('通知中心'),
        actions: [
          if (unreadCount > 0)
            TextButton(
              onPressed: _markAllRead,
              child: Tw('全部已读 ($unreadCount)',
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _notifications.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.notifications_none,
                                    size: 64,
                                    color: cs.onSurfaceVariant),
                                const SizedBox(height: AppTheme.spacingMd),
                                Text('暂无通知',
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: _notifications.length,
                      itemBuilder: (_, i) {
                        final n = _notifications[i];
                        final isRead = n['read'] == true;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: AppTheme.spacingMd,
                              vertical: 3),
                          child: InkWell(
                            onTap: () => _navigateByType(context, n),
                            child: Padding(
                              padding: const EdgeInsets.all(
                                  AppTheme.spacingMd),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  // 未读红点
                                  if (!isRead)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      margin: const EdgeInsets.only(top: 6),
                                      decoration: const BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                    )
                                  else
                                    const SizedBox(width: 16),
                                  const SizedBox(width: AppTheme.spacingSm),
                                  Icon(
                                    _typeIcon(
                                        n['notification_type'] as String?),
                                    size: 20,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: AppTheme.spacingSm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          n['title'] as String? ?? '',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: isRead
                                                ? FontWeight.normal
                                                : FontWeight.w600,
                                          ),
                                        ),
                                        if (n['body'] is String && (n['body'] as String).isNotEmpty)
                                          Text(
                                            n['body'] as String,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: cs.onSurfaceVariant),
                                          ),
                                        const SizedBox(height: 2),
                                        Text(
                                          (n['created_at'] as String? ?? '')
                                              .replaceAll(
                                                  RegExp(r'T.*'), ''),
                                          style: TextStyle(
                                              fontSize: 10,
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
    );
  }
}

