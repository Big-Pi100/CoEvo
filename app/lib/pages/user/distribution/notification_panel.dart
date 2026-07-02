import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme/app_theme.dart';

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

  void _navigateByType(BuildContext context, Map<String, dynamic> n) {
    final type = n['notification_type'] as String?;
    _markRead(n['id'] as String);

    // 分享类通知 → 弹分享弹窗（不跳转页面）
    if (type == 'reward' || type == 'share_poster' || type == 'share_h5' || type == 'marketing_campaign') {
      if (_dialogOpen) return; // 防止重复/堆叠弹窗
      _dialogOpen = true;
      // 从 action_url 中提取 campaign_id（格式: share?campaign_id=xxx）
      String? campaignId;
      final actionUrl = n['action_url'] as String?;
      if (actionUrl != null && actionUrl.startsWith('share?campaign_id=')) {
        campaignId = actionUrl.substring('share?campaign_id='.length);
      }
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          // dialog 关闭时解锁
          return PopScope(
            canPop: true,
            onPopInvokedWithResult: (didPop, _) {
              _dialogOpen = false;
            },
            child: _PosterDialog(campaignId: campaignId),
          );
        },
      );
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
        title: const Text('通知中心'),
        actions: [
          if (unreadCount > 0)
            TextButton(
              onPressed: _markAllRead,
              child: Text('全部已读 ($unreadCount)',
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

/// H5 海报对话框 — 调 API 获取 H5 内容，iframe 展示
class _PosterDialog extends ConsumerStatefulWidget {
  final String? campaignId;
  const _PosterDialog({this.campaignId});

  @override
  ConsumerState<_PosterDialog> createState() => _PosterDialogState();
}

class _PosterDialogState extends ConsumerState<_PosterDialog> {
  String? _h5Html;
  String? _shareUrl;
  String? _error;
  bool _loading = true;
  bool _campaignEnded = false;

  @override
  void initState() {
    super.initState();
    _loadH5();
  }

  Future<void> _loadH5() async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    final token = auth.token;
    if (userId == null || token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/referral/generate-h5'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          if (widget.campaignId != null) 'campaign_id': widget.campaignId,
        }),
      ).timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (data['status'] == 'campaign_ended') {
          setState(() => _campaignEnded = true);
        } else {
          _h5Html = data['html'] as String?;
          _shareUrl = data['url'] as String?;
        }
      } else {
        if (mounted) setState(() => _error = '加载失败 (${resp.statusCode})');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _loading = false);
  }

  void _copyShareLink() {
    if (_shareUrl == null) return;
    Clipboard.setData(ClipboardData(text: _shareUrl!));
    _showToast('链接已复制');
  }

  String _h5ViewId() {
    final id = 'h5-${widget.campaignId ?? 'default'}-${DateTime.now().millisecondsSinceEpoch}';
    if (_h5Html == null) return id;
    final frame = html.IFrameElement()
      ..srcdoc = _h5Html!
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = 'none';
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(id, (int _) => frame);
    return id;
  }

  void _showToast(String message) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 120,
        left: 0,
        right: 0,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () => entry.remove());
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingLg),
        child: _loading
            ? const SizedBox(height: 300, child: Center(child: CircularProgressIndicator()))
            : _campaignEnded
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.event_busy, size: 48, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('该活动已结束', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      SizedBox(height: 8),
                      Text('该活动已被管理员删除或已过期', style: TextStyle(color: Colors.grey)),
                      SizedBox(height: 24),
                    ]),
                  )
                : _h5Html != null
                ? SingleChildScrollView(
                    child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // H5 预览 — iframe 渲染
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.55,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: HtmlElementView(viewType: _h5ViewId()),
                        ),
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.share, size: 18),
                          onPressed: _copyShareLink,
                          label: const Text('复制分享链接'),
                        ),
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                )
                : _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败: $_error'),
                      const SizedBox(height: AppTheme.spacingMd),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  )
                : Padding(
                    padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('加载失败', style: TextStyle(fontSize: 16)),
                      SizedBox(height: 16),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('关闭'),
                      ),
                    ]),
                  ),
      ),
    );
  }
}
