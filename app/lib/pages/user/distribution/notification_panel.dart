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
      // 从 action_url 中提取 campaign_id（格式: share?campaign_id=xxx）
      String? campaignId;
      final actionUrl = n['action_url'] as String?;
      if (actionUrl != null && actionUrl.startsWith('share?campaign_id=')) {
        campaignId = actionUrl.substring('share?campaign_id='.length);
      }
      showDialog(
        context: context,
        builder: (ctx) => _PosterDialog(campaignId: campaignId),
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

/// 海报对话框 — 只显示海报 PNG（推广码+二维码已内嵌），提供下载
class _PosterDialog extends ConsumerStatefulWidget {
  final String? campaignId;
  const _PosterDialog({this.campaignId});

  @override
  ConsumerState<_PosterDialog> createState() => _PosterDialogState();
}

class _PosterDialogState extends ConsumerState<_PosterDialog> {
  String? _posterPng;
  String? _referralCode;
  bool _loading = true;
  bool _generatingH5 = false;
  bool _campaignEnded = false;

  @override
  void initState() {
    super.initState();
    _loadPoster();
  }

  Future<void> _loadPoster() async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    final token = auth.token;
    if (userId == null || token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final codeResp = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/referral/my-code?user_id=$userId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (codeResp.statusCode == 200 && mounted) {
        _referralCode = (jsonDecode(codeResp.body) as Map<String, dynamic>)['referral_code'] as String?;
      }

      final posterResp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/referral/generate-poster'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          if (widget.campaignId != null) 'campaign_id': widget.campaignId,
        }),
      ).timeout(const Duration(seconds: 60));
      if (posterResp.statusCode == 200 && mounted) {
        final data = jsonDecode(posterResp.body) as Map<String, dynamic>;
        if (data['status'] == 'campaign_ended') {
          setState(() => _campaignEnded = true);
        } else {
          _posterPng = data['poster_png'] as String?;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _generateH5() async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    final token = auth.token;
    if (userId == null || token == null) return;
    setState(() => _generatingH5 = true);
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
        final fullUrl = (data['url'] as String?) ?? ApiConfig.baseUrl;
        await Clipboard.setData(ClipboardData(text: fullUrl));
        if (mounted) {
          setState(() => _generatingH5 = false);
          _showToast('链接已复制');
        }
      } else if (mounted) {
        setState(() => _generatingH5 = false);
      }
    } catch (e) {
      if (mounted) setState(() => _generatingH5 = false);
      if (mounted) _showToast('生成失败');
    }
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

  void _download() {
    if (_posterPng == null) return;
    try {
      final bytes = base64Decode(_posterPng!.split(',').last);
      final blob = html.Blob([bytes], 'image/png');
      final objUrl = html.Url.createObjectUrlFromBlob(blob);
      (html.document.createElement('a') as html.AnchorElement)
        ..href = objUrl
        ..download = 'coevo_poster_${_referralCode ?? 'share'}.png'
        ..click();
      html.Url.revokeObjectUrl(objUrl);
    } catch (_) {}
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
                : _posterPng != null
                ? SingleChildScrollView(
                    child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RepaintBoundary(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(context).size.height * 0.55,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              base64Decode(_posterPng!.split(',').last),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppTheme.spacingMd),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.download, size: 18),
                          onPressed: _download,
                          label: const Text('下载海报'),
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: _generatingH5
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.share, size: 18),
                          onPressed: _generatingH5 ? null : _generateH5,
                          label: const Text('分享链接到微信'),
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
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('海报生成失败，请重试'),
                      const SizedBox(height: AppTheme.spacingMd),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
      ),
    );
  }
}
