import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';
import 'admin_campaign_form.dart';
import '../../../widgets/twemoji.dart';

/// 活动详情页 — 展示完整信息 + 操作按钮 + 统计
class AdminCampaignDetailPage extends StatefulWidget {
  final String campaignId;
  final String? adminKey;
  final String? token;

  const AdminCampaignDetailPage({
    super.key,
    required this.campaignId,
    this.adminKey,
    this.token,
  });

  @override
  State<AdminCampaignDetailPage> createState() =>
      _AdminCampaignDetailPageState();
}

class _AdminCampaignDetailPageState extends State<AdminCampaignDetailPage> {
  Map<String, dynamic>? _campaign;
  Map<String, dynamic>? _stats;
  bool _loading = true;
  bool _pushLoading = false;
  bool _generatingH5 = false;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadStats();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final uri =
          Uri.parse('${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        _campaign = data is Map<String, dynamic> ? data : null;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}/stats');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _stats = jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'active':
        return Colors.green;
      case 'paused':
        return Colors.orange;
      case 'ended':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'active':
        return '进行中';
      case 'paused':
        return '已暂停';
      case 'ended':
        return '已结束';
      case 'draft':
        return '草稿';
      default:
        return status ?? '未知';
    }
  }

  Future<void> _toggleStatus() async {
    if (_campaign == null) return;
    final current = _campaign!['status'] as String? ?? 'draft';
    String newStatus;
    if (current == 'active') {
      newStatus = 'paused';
    } else if (current == 'paused') {
      newStatus = 'active';
    } else if (current == 'draft') {
      newStatus = 'active';
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已结束的活动无法修改状态')));
      return;
    }

    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}/status');
      final resp = await http.patch(
        uri,
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'status': newStatus}),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _campaign!['status'] = newStatus;
        setState(() {});
        _snack('状态已更新为 ${_statusLabel(newStatus)}');
      } else if (mounted) {
        _snack('状态更新失败');
      }
    } catch (e) {
      if (mounted) _snack('网络错误: $e');
    }
  }

  Future<void> _delete() async {
    if (_campaign == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('确认删除'),
        content: Text('确定要删除活动「${_campaign!['name']}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Tw('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Tw('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}');
      final resp = await http
          .delete(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _snack('活动已删除');
        Navigator.of(context).pop();
      } else if (mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _snack(data['error'] as String? ?? '删除失败');
      }
    } catch (e) {
      if (mounted) _snack('网络错误: $e');
    }
  }

  Future<void> _push() async {
    setState(() => _pushLoading = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}/push');
      final resp = await http
          .post(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final count = data['pushed'] ?? 0;
        _snack('已推送 $count 条通知');
      } else if (mounted) {
        _snack('推送失败');
      }
    } catch (e) {
      if (mounted) _snack('网络错误: $e');
    }
    if (mounted) setState(() => _pushLoading = false);
  }

  Future<void> _generateH5Template() async {
    setState(() => _generatingH5 = true);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}/generate-h5-template');
      final resp = await http.post(uri, headers: _headers).timeout(const Duration(seconds: 120));
      if (resp.statusCode == 200 && mounted) {
        _snack('H5 模板已生成');
        _load();
      } else if (mounted) {
        final body = jsonDecode(resp.body);
        _snack('生成失败: ${body['error'] ?? resp.body}');
      }
    } catch (e) {
      if (mounted) _snack('网络错误: $e');
    }
    if (mounted) setState(() => _generatingH5 = false);
  }

  void _edit() {
    showDialog(
      context: context,
      builder: (ctx) => AdminCampaignFormDialog(
        adminKey: widget.adminKey,
        token: widget.token,
        campaign: _campaign,
        onSaved: () => _load(),
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_campaign?['name'] as String? ?? '活动详情'),
        actions: [
          if (_campaign != null)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor(_campaign!['status'] as String?),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Tw(
                _statusLabel(_campaign!['status'] as String?),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _campaign == null
              ? const Center(child: Text('活动不存在'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 操作按钮行 ──
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            icon: Icon(
                              _campaign!['status'] == 'active'
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 16,
                            ),
                            onPressed: _toggleStatus,
                            label: Text(
                              _campaign!['status'] == 'active' ? '暂停' : '启动',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.edit, size: 16),
                            onPressed: _edit,
                            label:
                                Tw('编辑', style: TextStyle(fontSize: 12)),
                          ),
                          if (_campaign!['status'] != 'active')
                            OutlinedButton.icon(
                              icon: const Icon(Icons.delete, size: 16),
                              onPressed: _delete,
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red),
                              label: Tw('删除',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          FilledButton.tonalIcon(
                            icon: _pushLoading
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.notifications, size: 16),
                            onPressed: _pushLoading ? null : _push,
                            label: Tw('手动推送',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTheme.spacingLg),
                      // ── 统计卡片 ──
                      if (_stats != null) ...[
                        Text('统计数据',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: cs.primary,
                                fontSize: 13)),
                        const SizedBox(height: AppTheme.spacingSm),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _statCard(
                                '点击次数', '${_stats!['clicks'] ?? 0}', Icons.touch_app),
                            _statCard(
                                '注册转化', '${_stats!['registrations'] ?? 0}', Icons.person_add),
                            _statCard(
                                '佣金总额', '${_stats!['commission_total'] ?? 0}', Icons.monetization_on),
                            _statCard(
                                '拼团成员', '${_stats!['member_count'] ?? 0}', Icons.group),
                            _statCard(
                                '已支付', '${_stats!['paid_count'] ?? 0}', Icons.payment),
                          ],
                        ),
                        const SizedBox(height: AppTheme.spacingLg),
                      ],
                      // ── 基本信息卡片 ──
                      _infoSection(cs, tt, '基本信息', [
                        _infoRow('活动名称', _campaign!['name'] as String? ?? ''),
                        _infoRow('活动类型',
                            _campaignTypeLabel(_campaign!['campaign_type'] as String? ?? '')),
                        _infoRow('状态',
                            _statusLabel(_campaign!['status'] as String?)),
                        _infoRow('描述',
                            _campaign!['description'] as String? ?? '无'),
                      ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── 时间信息卡片 ──
                      _infoSection(cs, tt, '时间信息', [
                        _infoRow('开始时间',
                            _campaign!['valid_from'] as String? ?? '不限'),
                        _infoRow('结束时间',
                            _campaign!['valid_until'] as String? ?? '不限'),
                        _infoRow('创建时间',
                            _campaign!['created_at'] as String? ?? ''),
                      ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── 奖励规则卡片 ──
                      _infoSection(cs, tt, '奖励规则', [
                        _infoRow('触发事件',
                            _campaign!['trigger_event'] as String? ?? ''),
                        _infoRow('归因窗口(天)',
                            '${_campaign!['attribution_window'] ?? 30}'),
                        ..._formatRewards(_campaign!['rewards'] as String? ?? '[]'),
                      ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── 推送设置卡片 ──
                      _infoSection(cs, tt, '推送设置', [
                        _infoRow('推送方式',
                            _campaign!['push_trigger'] as String? ?? 'manual'),
                        _infoRow('Cron', _campaign!['push_cron'] as String? ?? '无'),
                        _infoRow(
                          '展示位置',
                          _formatDisplayPositions(_campaign!['display_positions'] as String? ?? '[]'),
                        ),
                      ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── H5 Prompt ──
                      if ((_campaign!['h5_prompt'] as String? ?? '').isNotEmpty)
                        _infoSection(cs, tt, '自定义 Prompt', [
                          if ((_campaign!['h5_prompt'] as String? ?? '').isNotEmpty)
                            _infoRow('H5 Prompt', _campaign!['h5_prompt'] as String),
                        ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── 模板管理卡片 ──
                      _infoSection(cs, tt, '模板管理', [
                        _templateRow('H5 模板', _campaign!['h5_template'] as String?,
                            _generatingH5, _generateH5Template),
                      ]),
                      const SizedBox(height: AppTheme.spacingMd),
                      // ── 目标限制卡片 ──
                      _infoSection(cs, tt, '目标限制', [
                        _infoRow('目标角色',
                            _campaign!['target_roles'] as String? ?? '[]'),
                        _infoRow('参与上限',
                            '${_campaign!['participant_limit'] ?? '不限'}'),
                        _infoRow('每人上限',
                            '${_campaign!['per_user_limit'] ?? '不限'}'),
                      ]),
                      if (_campaign!['llm_prompt_hint'] != null &&
                          (_campaign!['llm_prompt_hint'] as String).isNotEmpty) ...[
                        const SizedBox(height: AppTheme.spacingMd),
                        _infoSection(cs, tt, 'LLM 提示', [
                          _infoRow('Prompt',
                              _campaign!['llm_prompt_hint'] as String),
                        ]),
                      ],
                      if (_campaign!['qr_code_url'] != null &&
                          (_campaign!['qr_code_url'] as String).isNotEmpty) ...[
                        const SizedBox(height: AppTheme.spacingMd),
                        _infoSection(cs, tt, '扩展', [
                          _infoRow('二维码 URL',
                              _campaign!['qr_code_url'] as String),
                        ]),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _infoSection(
      ColorScheme cs, TextTheme tt, String title, List<Widget> rows) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                    fontSize: 13)),
            const Divider(),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Tw(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13)),
          ),
          Expanded(
            child: Tw(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 140,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            children: [
              Icon(icon, size: 24, color: cs.primary),
              const SizedBox(height: AppTheme.spacingXs),
              Text(value,
                  style: TextStyle(
                      fontSize: 20,
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

  Widget _templateRow(String label, String? template, bool generating, VoidCallback onGenerate) {
    final exists = template != null && template.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Tw(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13)),
          ),
          if (generating)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Expanded(
              child: Row(
                children: [
                  Icon(exists ? Icons.check_circle : Icons.hourglass_empty,
                      size: 16, color: exists ? Colors.green : Colors.grey),
                  const SizedBox(width: 4),
                  Text(exists ? '已生成' : '未生成',
                      style: TextStyle(fontSize: 12, color: exists ? Colors.green : Colors.grey)),
                  const Spacer(),
                  if (exists)
                    SizedBox(
                      height: 28,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.visibility, size: 14),
                        label: Tw('预览', style: TextStyle(fontSize: 11)),
                        onPressed: () => _showTemplatePreview(template),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 28,
                    child: OutlinedButton.icon(
                      icon: Icon(exists ? Icons.refresh : Icons.add, size: 14),
                      label: Text(exists ? '重新生成' : '生成', style: const TextStyle(fontSize: 11)),
                      onPressed: onGenerate,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showTemplatePreview(String content) {
    _showH5Preview();
  }

  void _showH5Preview() {
    // 调 API 获取替换变量后的 H5 内容
    showDialog(
      context: context,
      builder: (ctx) => _H5PreviewDialog(
        campaignId: widget.campaignId,
        headers: _headers,
      ),
    );
  }

  String _formatDisplayPositions(String jsonStr) {
    try {
      final list = (jsonDecode(jsonStr) as List).cast<String>();
      if (list.isEmpty) return '无';
      return list.map((p) {
        switch (p) {
          case 'achievement_tab': return '成就页推广 Tab';
          case 'review_completion': return '复习完成弹窗';
          case 'notification': return '通知中心推送';
          default: return p;
        }
      }).join('、');
    } catch (_) {
      return '无';
    }
  }

  List<Widget> _formatRewards(String jsonStr) {
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.asMap().entries.map((entry) {
        final r = entry.value as Map<String, dynamic>;
        final type = _rewardTypeLabel(r['type'] as String? ?? '');
        final party = _rewardPartyLabel(r['party'] as String? ?? '');
        final value = r['value'] ?? '';
        return _infoRow('规则 ${entry.key + 1}', '$type · $party · 值: $value');
      }).toList();
    } catch (_) {
      return [];
    }
  }

  String _rewardTypeLabel(String type) {
    switch (type) {
      case 'subscription_days': return '送天数';
      case 'commission_pct': return '佣金(比例)';
      case 'commission_fix': return '佣金(固定)';
      case 'discount_fix': return '折扣(固定金额)';
      case 'discount_pct': return '折扣(百分比)';
      default: return type;
    }
  }

  String _rewardPartyLabel(String party) {
    switch (party) {
      case 'self': return '推广员';
      case 'inviter': return '下线';
      case 'all': return '所有人';
      default: return party;
    }
  }

  String _campaignTypeLabel(String type) {
    switch (type) {
      case 'distribution': return '分销模式';
      case 'team_discount': return '拼团';
      case 'bargain': return '砍价';
      default: return type;
    }
  }
}

/// 海报预览弹窗 — 调 API 获取渲染后的 SVG+PNG，双 Tab 展示
class _H5PreviewDialog extends StatefulWidget {
  final String campaignId;
  final Map<String, String> headers;

  const _H5PreviewDialog({
    required this.campaignId,
    required this.headers,
  });

  @override
  State<_H5PreviewDialog> createState() => _H5PreviewDialogState();
}

class _H5PreviewDialogState extends State<_H5PreviewDialog> {
  String? _html;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/campaigns/${widget.campaignId}/preview-h5');
      final resp = await http.post(uri, headers: widget.headers).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (mounted) setState(() { _html = data['html'] as String?; _loading = false; });
      } else {
        if (mounted) setState(() { _error = 'HTTP ${resp.statusCode}'; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Tw('H5 预览',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Text('加载失败: $_error', style: const TextStyle(color: Colors.red))
            else if (_html == null)
              Tw('无内容')
            else
              _buildPreview(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final viewId = 'h5-preview-${widget.campaignId}-${DateTime.now().millisecondsSinceEpoch}';
    final frame = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '375px'
      ..style.height = '100%'
      ..srcdoc = _html!;
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(viewId, (int id) => frame);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 500),
      child: HtmlElementView(viewType: viewId),
    );
  }
}
