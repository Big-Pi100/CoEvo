import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/twemoji.dart';

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

  // 🔴 2026-10-06：原 `_openH5InNewTab` + `_openExternal` 两个方法已删 ——
  //    前者调 `/api/referral/generate-h5`（已随分销链退役，调用必然 404），
  //    后者（`url_launcher` + `Clipboard`）只服务前者。
  //    见 `docs/review/backend-dead-route-cleanup-2026-10-06.md`

  void _navigateByType(BuildContext context, Map<String, dynamic> n) {
    final type = n['notification_type'] as String?;
    _markRead(n['id'] as String);

    // 🔴 2026-10-06：原「活动推送 / 分享类通知 → 打开 H5 分享页」分支已删
    //    （依赖已退役的 `/api/referral/generate-h5` 与 `/share/` 落地页）。
    //    ⚠️ 库里可能仍有历史 `campaign_push` 通知 → 下面 `_iconFor` **保留**其图标映射，
    //       点击时落进 `default`（不跳转），不会报错。

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
    final t = CoEvoTokensExt.of(context);

    // 🔴 2026-10-09：外壳统一 —— 本页原先是**全库唯一**用 Material `AppBar` 的页面
    //    （`grep -rl "appBar: AppBar(" app/lib` ⇒ 只有它）⇒ 换成与**收藏页同一套**
    //    自绘标题行（设计稿 `visual-feed-bookmark-2026-09-25.html:174-176` 的 `.bm-hd`：
    //    `display:flex; justify-content:space-between` · 左 `h2` 23/w600/字距-.015em ·
    //    右 `.back` 12 / accent / w600）。
    //
    // ⚠️ **必须一起补返回入口**：原来的「返回」是 `AppBar` 在路由可 pop 时**隐式**插入的
    //    ⇒ 只换外壳会让本页**失去唯一返回入口**。
    //    📌 同类事故有过：`bookmark_list_screen` 记录白哥实测「收藏列表根本没有返回按钮」
    //    （那次也是「照着 mockup 认为不需要返回」，而设计稿 CSS 里本就有 `.back`）。
    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 🔑 这是**独立 push 页**（`MaterialPageRoute`）⇒ **要**避让底部安全区
        //    （home indicator）。⚠️ 别照抄 `bookmark_list_screen` 的 `bottom: false` ——
        //    那一页在 shell 内，底部由自绘粘土 tabbar 接管。
        //    参照物是**同类页** `achievements_screen`（它写的就是裸 `SafeArea(`）。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题栏（照设计稿 `.bm-hd`）──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '通知中心',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 23 * -0.015,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  // 设计稿 `.bm-hd .back{font-size:12px;color:var(--accent);font-weight:600}`
                  InkWell(
                    onTap: () => context.pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      // 撑够点击区（12px 小字太窄），视觉上仍是纯文字链接
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '返回',
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(t.accent.argb32),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── 批量动作（原在 `AppBar.actions` 里）──
            //  🔑 **搬位置 ≠ 删**：文案 / 动作 / 条件渲染三者逐字保留；
            //     形态从 `TextButton` 换成与「返回」同族的文字链接（12/accent/w600）——
            //     项目里「动作」的统一形态就是它（`TextButton` 是 Material 的口径）。
            if (unreadCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    InkWell(
                      onTap: _markAllRead,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Tw('全部已读 ($unreadCount)',
                            style: TextStyle(
                              fontFamily: CoFonts.uiSans,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(t.accent.argb32),
                            )),
                      ),
                    ),
                  ],
                ),
              ),

            // ── 主体（原 `body:` 的内容，**逐字未动**）──
            Expanded(
              child: _loading
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
                                const SizedBox(height: CoSpacing.md),
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
                              horizontal: CoSpacing.md,
                              vertical: 3),
                          child: InkWell(
                            onTap: () => _navigateByType(context, n),
                            child: Padding(
                              padding: const EdgeInsets.all(
                                  CoSpacing.md),
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
                                  const SizedBox(width: CoSpacing.sm),
                                  Icon(
                                    _typeIcon(
                                        n['notification_type'] as String?),
                                    size: 20,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: CoSpacing.sm),
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
              ), // 收 RefreshIndicator
            ), // 收 Expanded
          ], // 收 children 列表
        ), // 收 Column
      ), // 收 SafeArea
    );
  }
}

