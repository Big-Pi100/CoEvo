import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../api/api_config.dart';

/// 新建/编辑活动弹窗表单
class AdminCampaignFormDialog extends StatefulWidget {
  final String? adminKey;
  final String? token;
  final Map<String, dynamic>? campaign; // null = create, non-null = edit
  final VoidCallback onSaved;

  const AdminCampaignFormDialog({
    super.key,
    this.adminKey,
    this.token,
    this.campaign,
    required this.onSaved,
  });

  @override
  State<AdminCampaignFormDialog> createState() => _AdminCampaignFormDialogState();
}

class _AdminCampaignFormDialogState extends State<AdminCampaignFormDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _posterPromptCtrl;
  late TextEditingController _qrCtrl;
  late TextEditingController _limitCtrl;
  late TextEditingController _perUserCtrl;
  late TextEditingController _attributionCtrl;
  late TextEditingController _validFromCtrl;
  late TextEditingController _validUntilCtrl;

  String _campaignType = 'distribution';
  String _triggerEvent = 'registration';
  List<Map<String, dynamic>> _rewards = [];
  String _pushTrigger = 'manual';
  int _cronDay = 0;       // 0=每天, 1=周一 ... 7=周日
  int _cronHour = 9;
  int _cronMinute = 0;
  List<String> _targetRoles = [];
  String _displayStyle = 'both'; // notification / popup / both
  bool _saving = false;

  bool get _isEdit => widget.campaign != null;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  @override
  void initState() {
    super.initState();
    final c = widget.campaign;
    _nameCtrl = TextEditingController(text: c?['name'] as String? ?? '');
    _descCtrl = TextEditingController(text: c?['description'] as String? ?? '');
    if (c?['rewards'] is String && (c!['rewards'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(c['rewards'] as String);
        if (decoded is List) {
          _rewards = decoded.cast<Map<String, dynamic>>();
          // 清洗每个奖励字段，确保值在下拉菜单中存在
          for (final r in _rewards) {
            r['trigger'] = _validValue(r['trigger'] as String?, ['registration', 'payment', 'plan_update'], 'registration');
            r['party'] = _validValue(r['party'] as String?, ['self', 'inviter', 'invitee', 'all'], 'self');
            r['freq'] = _validValue(r['freq'] as String?, ['once', 'daily', 'hourly', 'weekly', 'monthly'], 'once');
          }
        }
      } catch (_) {
        _rewards = [];
      }
    }
    if (_rewards.isEmpty) {
      _rewards = [
        {'type': 'subscription_days', 'party': 'self', 'value': 3, 'trigger': 'registration', 'freq': 'once'}
      ];
    }
    // 解析 cron 表达式为星期+时间（cron格式: "minute hour * * day"）
    final savedCron = c?['push_cron'] as String? ?? '';
    if (savedCron.isNotEmpty) {
      final parts = savedCron.split(' ');
      if (parts.length >= 5) {
        _cronMinute = int.tryParse(parts[0]) ?? 0;
        _cronHour = int.tryParse(parts[1]) ?? 9;
        _cronDay = int.tryParse(parts[4]) ?? 0;
      }
    }
    final savedPosterPrompt = c?['poster_prompt'] as String? ?? '';
    _posterPromptCtrl = TextEditingController(text: savedPosterPrompt);
    if (savedPosterPrompt.isEmpty) {
      _loadDefaultPosterPrompt();
    }
    _qrCtrl = TextEditingController(text: c?['qr_code_url'] as String? ?? '');
    _limitCtrl = TextEditingController(
        text: c?['participant_limit']?.toString() ?? '');
    _perUserCtrl = TextEditingController(
        text: c?['per_user_limit']?.toString() ?? '');
    _attributionCtrl = TextEditingController(
        text: c?['attribution_window']?.toString() ?? '30');
    _validFromCtrl =
        TextEditingController(text: c?['valid_from'] as String? ?? '');
    _validUntilCtrl =
        TextEditingController(text: c?['valid_until'] as String? ?? '');

    _campaignType = _validValue(c?['campaign_type'] as String?, ['distribution', 'team_discount', 'bargain'], 'distribution');
    _triggerEvent = _validValue(c?['trigger_event'] as String?, ['registration', 'payment', 'plan_update', 'after_complete_review', 'login'], 'registration');
    _pushTrigger = _validValue(c?['push_trigger'] as String?, ['manual', 'registration', 'after_complete_review', 'plan_update', 'login', 'cron'], 'manual');
    _displayStyle = _validValue(c?['display_positions'] as String?, ['both', 'notification', 'popup'], 'both');
  }

  /// 确保值存在于列表中，否则用默认值（防止旧数据导致 DropdownButton 断言崩溃）
  String _validValue(String? stored, List<String> validValues, String defaultValue) {
    if (stored != null && validValues.contains(stored)) return stored;
    return defaultValue;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _posterPromptCtrl.dispose();
    _qrCtrl.dispose();
    _limitCtrl.dispose();
    _perUserCtrl.dispose();
    _attributionCtrl.dispose();
    _validFromCtrl.dispose();
    _validUntilCtrl.dispose();
    super.dispose();
  }

  void _addReward() {
    setState(() {
      _rewards.add({
        'type': 'subscription_days',
        'party': 'self',
        'value': 3,
        'trigger': 'registration',
      });
    });
  }

  void _removeReward(int index) {
    setState(() => _rewards.removeAt(index));
  }

  Future<void> _loadDefaultPosterPrompt() async {
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns/default-poster-prompt');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        final prompt = data['prompt'] as String?;
        if (prompt != null && prompt.isNotEmpty) {
          setState(() => _posterPromptCtrl.text = prompt);
        }
      }
    } catch (_) {
      // 静默失败，用户可手动输入
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final body = {
      'name': _nameCtrl.text.trim(),
      'campaign_type': _campaignType,
      'description': _descCtrl.text.trim(),
      'rewards': jsonEncode(_rewards),
      'trigger_event': _triggerEvent,
      'push_trigger': _pushTrigger,
      if (_pushTrigger == 'cron') 'push_cron': '$_cronMinute $_cronHour * * $_cronDay',
      'target_roles': jsonEncode(_targetRoles),
      'display_positions': _displayStyle,
      if (_posterPromptCtrl.text.trim().isNotEmpty)
        'poster_prompt': _posterPromptCtrl.text.trim(),
      'attribution_window':
          int.tryParse(_attributionCtrl.text.trim()) ?? 30,
      'valid_from': _validFromCtrl.text.trim().isEmpty
          ? null
          : _validFromCtrl.text.trim(),
      'valid_until': _validUntilCtrl.text.trim().isEmpty
          ? null
          : _validUntilCtrl.text.trim(),
      'participant_limit': _limitCtrl.text.trim().isEmpty
          ? null
          : int.tryParse(_limitCtrl.text.trim()),
      'per_user_limit': _perUserCtrl.text.trim().isEmpty
          ? null
          : int.tryParse(_perUserCtrl.text.trim()),
      'qr_code_url': _qrCtrl.text.trim().isEmpty
          ? null
          : _qrCtrl.text.trim(),
    };

    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/admin/campaigns${_isEdit ? '/${widget.campaign!['id']}' : ''}');
      final http.Response resp;
      if (_isEdit) {
        resp = await http
            .put(uri,
                headers: {
                  ..._headers,
                  'Content-Type': 'application/json',
                },
                body: jsonEncode(body))
            .timeout(const Duration(seconds: 10));
      } else {
        resp = await http
            .post(uri,
                headers: {
                  ..._headers,
                  'Content-Type': 'application/json',
                },
                body: jsonEncode(body))
            .timeout(const Duration(seconds: 10));
      }
      if (resp.statusCode == 200 && mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  resp.body.contains('error') ? jsonDecode(resp.body)['error'] ?? '保存失败' : '保存失败')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('网络错误: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEdit ? '编辑活动' : '新建活动'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 基本信息 ──
                Text('基本信息',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                      labelText: '活动名称',
                      border: OutlineInputBorder(),
                      isDense: true),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入活动名称' : null,
                ),
                const SizedBox(height: AppThemeSpacing.sm),
                DropdownButtonFormField<String>(
                  value: _campaignType,
                  decoration: const InputDecoration(
                      labelText: '活动类型',
                      border: OutlineInputBorder(),
                      isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'distribution', child: Text('分销模式')),
                    DropdownMenuItem(value: 'team_discount', child: Text('拼团')),
                    DropdownMenuItem(value: 'bargain', child: Text('砍价')),
                  ],
                  onChanged: (v) => setState(() => _campaignType = v ?? 'distribution'),
                ),
                const SizedBox(height: AppThemeSpacing.sm),
                TextFormField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: '活动描述',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
                // ── 时间控制 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('时间控制',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _validFromCtrl,
                        decoration: const InputDecoration(
                            labelText: '开始时间',
                            hintText: 'YYYY-MM-DD HH:MM:SS',
                            border: OutlineInputBorder(),
                            isDense: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _validUntilCtrl,
                        decoration: const InputDecoration(
                            labelText: '结束时间',
                            hintText: 'YYYY-MM-DD HH:MM:SS',
                            border: OutlineInputBorder(),
                            isDense: true),
                      ),
                    ),
                  ],
                ),
                // ── 奖励规则 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('奖励规则',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                // 奖励规则列表
                ..._rewards.asMap().entries.map((entry) {
                  final i = entry.key;
                  final reward = entry.value;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('规则 ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () => _removeReward(i),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: reward['type'] as String,
                                  decoration: const InputDecoration(
                                      labelText: '类型', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                  items: const [
                    DropdownMenuItem(value: 'subscription_days', child: Text('送天数')),
                    DropdownMenuItem(value: 'commission_pct', child: Text('佣金(比例)')),
                    DropdownMenuItem(value: 'commission_fix', child: Text('佣金(固定)')),
                    DropdownMenuItem(value: 'discount_fix', child: Text('折扣(固定金额)')),
                    DropdownMenuItem(value: 'discount_pct', child: Text('折扣(百分比)')),
                  ],
                                  onChanged: (v) => setState(() => _rewards[i]['type'] = v),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: reward['party'] as String,
                                  decoration: const InputDecoration(
                                      labelText: '对象', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                  items: const [
                                    DropdownMenuItem(value: 'self', child: Text('触发者（自己）')),
                                    DropdownMenuItem(value: 'inviter', child: Text('邀请人（推广员）')),
                                    DropdownMenuItem(value: 'invitee', child: Text('被邀请人')),
                                    DropdownMenuItem(value: 'all', child: Text('所有人')),
                                  ],
                                  onChanged: (v) => setState(() => _rewards[i]['party'] = v),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue: reward['value'].toString(),
                                  decoration: const InputDecoration(
                                      labelText: '值', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  onChanged: (v) => _rewards[i]['value'] = double.tryParse(v) ?? (int.tryParse(v) ?? 0),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: reward['trigger'] as String,
                                  decoration: const InputDecoration(
                                      labelText: '触发', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                  items: const [
                                    DropdownMenuItem(value: 'registration', child: Text('注册')),
                                    DropdownMenuItem(value: 'payment', child: Text('支付')),
                                    DropdownMenuItem(value: 'plan_update', child: Text('计划更新')),
                                  ],
                                  onChanged: (v) => setState(() => _rewards[i]['trigger'] = v),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 72,
                                child: DropdownButtonFormField<String>(
                                  value: (reward['freq'] as String?) ?? 'once',
                                  decoration: const InputDecoration(
                                      labelText: '频率', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8)),
                                  items: const [
                                    DropdownMenuItem(value: 'once', child: Text('仅1次')),
                                    DropdownMenuItem(value: 'daily', child: Text('每天1次')),
                                    DropdownMenuItem(value: 'hourly', child: Text('每小时1次')),
                                    DropdownMenuItem(value: 'weekly', child: Text('每周1次')),
                                    DropdownMenuItem(value: 'monthly', child: Text('每月1次')),
                                  ],
                                  onChanged: (v) => setState(() => _rewards[i]['freq'] = v),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (reward['type'] == 'commission_pct' || reward['type'] == 'commission_fix') ...[
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 60,
                                  child: TextFormField(
                                    initialValue: (reward['level'] ?? 1).toString(),
                                    decoration: const InputDecoration(
                                        labelText: '级', border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                    keyboardType: TextInputType.number,
                                    onChanged: (v) => _rewards[i]['level'] = int.tryParse(v) ?? 1,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: AppThemeSpacing.sm),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加奖励规则'),
                  onPressed: _addReward,
                ),
                // ── 推送设置 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('推送设置',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                DropdownButtonFormField<String>(
                  value: _pushTrigger,
                  decoration: const InputDecoration(
                      labelText: '推送方式',
                      border: OutlineInputBorder(),
                      isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'manual', child: Text('手动')),
                    DropdownMenuItem(value: 'registration', child: Text('注册时')),
                    DropdownMenuItem(value: 'after_complete_review', child: Text('复习完成后')),
                    DropdownMenuItem(value: 'plan_update', child: Text('计划更新时')),
                    DropdownMenuItem(value: 'login', child: Text('登录时')),
                    DropdownMenuItem(value: 'cron', child: Text('定时(Cron)')),
                  ],
                  onChanged: (v) =>
                      setState(() => _pushTrigger = v ?? 'manual'),
                ),
                if (_pushTrigger == 'cron') ...[
                  const SizedBox(height: AppThemeSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _cronDay,
                          decoration: const InputDecoration(
                              labelText: '执行日期',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('每天')),
                            DropdownMenuItem(value: 1, child: Text('周一')),
                            DropdownMenuItem(value: 2, child: Text('周二')),
                            DropdownMenuItem(value: 3, child: Text('周三')),
                            DropdownMenuItem(value: 4, child: Text('周四')),
                            DropdownMenuItem(value: 5, child: Text('周五')),
                            DropdownMenuItem(value: 6, child: Text('周六')),
                            DropdownMenuItem(value: 7, child: Text('周日')),
                          ],
                          onChanged: (v) => setState(() => _cronDay = v ?? 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _cronHour,
                          decoration: const InputDecoration(
                              labelText: '小时',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                          items: List.generate(24, (h) =>
                            DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00'))),
                          onChanged: (v) => setState(() => _cronHour = v ?? 9),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: _cronMinute,
                          decoration: const InputDecoration(
                              labelText: '分钟',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                          items: [0, 15, 30, 45].map((m) =>
                            DropdownMenuItem(value: m, child: Text('${m.toString().padLeft(2, '0')}分'))).toList(),
                          onChanged: (v) => setState(() => _cronMinute = v ?? 0),
                        ),
                      ),
                    ],
                  ),
                ],
                // ── 展示方式 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('展示方式',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                DropdownButtonFormField<String>(
                  value: _displayStyle,
                  decoration: const InputDecoration(
                      labelText: '展示方式',
                      border: OutlineInputBorder(),
                      isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'notification', child: Text('通知中心')),
                    DropdownMenuItem(value: 'popup', child: Text('弹窗')),
                    DropdownMenuItem(value: 'both', child: Text('通知+弹窗')),
                  ],
                  onChanged: (v) =>
                      setState(() => _displayStyle = v ?? 'both'),
                ),
                // ── 目标限制 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('目标限制',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 13)),
                const SizedBox(height: AppThemeSpacing.sm),
                _buildRoleChips(),
                const SizedBox(height: AppThemeSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _limitCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: '参与人数上限',
                            border: OutlineInputBorder(),
                            isDense: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _perUserCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: '每人参与上限',
                            border: OutlineInputBorder(),
                            isDense: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppThemeSpacing.sm),
                TextFormField(
                  controller: _attributionCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '归因窗口(天)',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
                // ── 海报系统提示 ──
                const SizedBox(height: AppThemeSpacing.lg),
                Text('海报系统提示',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                        fontSize: 14)),
                const SizedBox(height: AppThemeSpacing.sm),
                Text(
                  '自定义海报生成的系统提示。留空则使用默认提示。',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: AppThemeSpacing.sm),
                TextFormField(
                  controller: _posterPromptCtrl,
                  maxLines: 15,
                  decoration: const InputDecoration(
                    hintText: '留空则使用默认系统提示...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: AppThemeSpacing.sm),
                TextFormField(
                  controller: _qrCtrl,
                  decoration: const InputDecoration(
                      labelText: '二维码图片 URL（可选）',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildRoleChips() {
    const allRoles = ['student', 'teacher', 'guardian'];
    return Wrap(
      spacing: 6,
      children: allRoles.map((role) {
        final selected = _targetRoles.contains(role);
        String label;
        switch (role) {
          case 'student':
            label = '学生';
            break;
          case 'teacher':
            label = '教师';
            break;
          case 'guardian':
            label = '家长';
            break;
          default:
            label = role;
        }
        return FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: selected,
          onSelected: (v) {
            setState(() {
              if (v) {
                _targetRoles.add(role);
              } else {
                _targetRoles.remove(role);
              }
            });
          },
          visualDensity: VisualDensity.compact,
        );
      }).toList(),
    );
  }
}

/// Shared spacing values used by campaign form
class AppThemeSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}
