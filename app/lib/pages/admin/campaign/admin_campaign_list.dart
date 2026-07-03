import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';
import '../../../theme/app_theme.dart';
import 'admin_campaign_form.dart';
import 'admin_campaign_detail.dart';
import '../../../widgets/twemoji.dart';

/// 活动列表页 — 卡片式展示全部活动
class AdminCampaignListPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const AdminCampaignListPage({super.key, this.adminKey, this.token});

  @override
  State<AdminCampaignListPage> createState() => _AdminCampaignListPageState();
}

class _AdminCampaignListPageState extends State<AdminCampaignListPage> {
  List<Map<String, dynamic>> _campaigns = [];
  bool _loading = false;
  String _filter = 'all'; // all | active | ended | draft

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
    setState(() => _loading = true);
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/admin/campaigns');
      final resp = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _campaigns = (data['campaigns'] as List?)
                ?.map((e) => e as Map<String, dynamic>)
                .toList() ??
            [];
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _filtered {
    if (_filter == 'all') return _campaigns;
    return _campaigns.where((c) => c['status'] == _filter).toList();
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

  void _showCreateDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AdminCampaignFormDialog(
        adminKey: widget.adminKey,
        token: widget.token,
        onSaved: () => _load(),
      ),
    );
  }

  void _openDetail(Map<String, dynamic> campaign) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminCampaignDetailPage(
          campaignId: campaign['id'] as String,
          adminKey: widget.adminKey,
          token: widget.token,
        ),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final filtered = _filtered;

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingMd,
              AppTheme.spacingMd, AppTheme.spacingXs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('活动管理 (${filtered.length})',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.primary)),
              Row(children: [
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  onPressed: _showCreateDialog,
                  label: Tw('新建活动', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: AppTheme.spacingSm),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: _load,
                  label: Tw('刷新', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ],
          ),
        ),
        // Filter chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd),
          child: Wrap(
            spacing: 6,
            children: [
              _filterChip('全部', 'all', _campaigns.length),
              _filterChip('进行中', 'active',
                  _campaigns.where((c) => c['status'] == 'active').length),
              _filterChip('已暂停', 'paused',
                  _campaigns.where((c) => c['status'] == 'paused').length),
              _filterChip('已结束', 'ended',
                  _campaigns.where((c) => c['status'] == 'ended').length),
              _filterChip('草稿', 'draft',
                  _campaigns.where((c) => c['status'] == 'draft').length),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spacingXs),
        // Campaign list
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? Center(
                      child: TextButton(
                          onPressed: _load,
                          child: Tw('暂无活动，点击刷新')))
                  : ListView.builder(
                      itemCount: filtered.length,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.spacingMd,
                          vertical: AppTheme.spacingXs),
                      itemBuilder: (_, i) => _buildCampaignCard(
                          context, cs, tt, filtered[i]),
                    ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, String value, int count) {
    final selected = _filter == value;
    return FilterChip(
      label: Text('$label ($count)',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: selected ? Theme.of(context).colorScheme.surface : null)),
      selected: selected,
      onSelected: (_) => setState(() => _filter = value),
      visualDensity: VisualDensity.compact,
      selectedColor: Theme.of(context).colorScheme.secondary,
      checkmarkColor: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs),
    );
  }

  Widget _buildCampaignCard(
      BuildContext context, ColorScheme cs, TextTheme tt, Map<String, dynamic> c) {
    final status = c['status'] as String?;
    final desc = c['description'] as String? ?? '';
    final createdAt = (c['created_at'] as String? ?? '').replaceAll(RegExp(r'T.*'), '');

    return Card(
      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      child: InkWell(
        onTap: () => _openDetail(c),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Tw(
                      c['name'] as String? ?? '',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Tw(
                      _statusLabel(status),
                      style: TextStyle(
                          fontSize: 11,
                          color: _statusColor(status),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spacingXs),
                Text(desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
              const SizedBox(height: AppTheme.spacingSm),
              Text('创建于 $createdAt',
                  style: tt.labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
