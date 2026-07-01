import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';

/// Tree node types for the plans tree.
enum _NodeType { plan, stage, task }

/// Data held by each tree node.
class _PlanTreeNode {
  final _NodeType type;
  final String label;
  final String? subtitle;
  final Map<String, dynamic> data; // raw JSON for this node
  final String subject;

  const _PlanTreeNode({
    required this.type,
    required this.label,
    this.subtitle,
    required this.data,
    required this.subject,
  });
}

/// Tree entry (lazy-loaded children).
class _TreeEntry extends StatefulWidget {
  final _PlanTreeNode node;
  final int depth;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final Future<List<_PlanTreeNode>> Function() loadChildren;

  const _TreeEntry({
    super.key,
    required this.node,
    required this.depth,
    required this.selectedId,
    required this.onSelect,
    required this.loadChildren,
  });

  @override
  State<_TreeEntry> createState() => _TreeEntryState();
}

class _TreeEntryState extends State<_TreeEntry> {
  bool _expanded = false;
  bool _loading = false;
  List<_PlanTreeNode>? _children;

  void _toggle() async {
    if (widget.node.type == _NodeType.task) {
      widget.onSelect(_itemId(widget.node));
      return;
    }
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    if (_children == null) {
      setState(() => _loading = true);
      try {
        _children = await widget.loadChildren();
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
    widget.onSelect(_itemId(widget.node));
  }

  String _itemId(_PlanTreeNode n) {
    if (n.type == _NodeType.plan) return 'plan:${n.subject}';
    final id = n.data['id'] as String? ?? '';
    if (n.type == _NodeType.stage) return 'stage:$id';
    return 'task:$id';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = _itemId(widget.node) == widget.selectedId;
    final isPlan = widget.node.type == _NodeType.plan;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        onTap: _toggle,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 20.0, top: 4, bottom: 4, right: 4),
          decoration: BoxDecoration(
            color: isSelected ? cs.primaryContainer.withValues(alpha: 0.4) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            Icon(
              widget.node.type == _NodeType.plan
                  ? Icons.school
                  : widget.node.type == _NodeType.stage
                      ? Icons.folder_open
                      : Icons.description,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.node.label,
                style: TextStyle(fontSize: isPlan ? 14 : 13, fontWeight: isPlan ? FontWeight.w600 : FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.node.subtitle != null)
              Text(widget.node.subtitle!, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            if (_loading)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            else if (widget.node.type != _NodeType.task)
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
      if (_expanded && _children != null && !_loading)
        ..._children!.map((child) => _TreeEntry(
              key: ValueKey(_itemId(child)),
              node: child,
              depth: widget.depth + 1,
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
              loadChildren: () async {
                if (child.type == _NodeType.stage) {
                  final tasks = child.data['tasks'] as List? ?? [];
                  return tasks.map((t) => _PlanTreeNode(
                    type: _NodeType.task,
                    label: (t['name'] as String?)?.isNotEmpty == true
                        ? t['name'] as String
                        : (t['task_key'] as String?) ?? 'unnamed',
                    subtitle: '${(t['card_ids'] as List?)?.length ?? 0}张 · ${t['task_key'] ?? ''}',
                    data: t as Map<String, dynamic>,
                    subject: child.subject,
                  )).toList();
                }
                return [];
              },
            )),
    ]);
  }
}

/// Curriculum Plans Page — left tree + right editor.
class CurriculumPlansPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const CurriculumPlansPage({super.key, this.adminKey, this.token});

  @override
  State<CurriculumPlansPage> createState() => _CurriculumPlansPageState();
}

class _CurriculumPlansPageState extends State<CurriculumPlansPage> {
  List<Map<String, dynamic>> _subjects = [];
  Map<String, Map<String, dynamic>> _planCache = {};
  String? _selectedId;
  Map<String, dynamic>? _selectedData; // ← 直接存储选中数据，不遍历缓存查找
  bool _loading = false;

  Map<String, String> get _headers {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null) return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  Future<Map<String, dynamic>> _api(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final h = _headers;
    final req = switch (method) {
      'GET' => http.get(uri, headers: h),
      'POST' => http.post(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})),
      'PUT' => http.put(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})),
      'PATCH' => http.patch(uri, headers: {...h, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})),
      'DELETE' => http.delete(uri, headers: h),
      _ => http.get(uri, headers: h),
    };
    final resp = await req.timeout(const Duration(seconds: 10));
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'error': '${resp.statusCode}'};
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  Future<void> _loadSubjects() async {
    setState(() => _loading = true);
    final resp = await _api('GET', '/api/admin/curriculum/status');
    final list = (resp['subjects'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    setState(() {
      _subjects = list;
      _loading = false;
    });
  }

  Future<Map<String, dynamic>> _loadPlan(String subject) async {
    if (_planCache.containsKey(subject)) return _planCache[subject]!;
    final resp = await _api('GET', '/api/admin/curriculum/subject/$subject/plan');
    _planCache[subject] = resp;
    return resp;
  }

  Map<String, dynamic>? _currentEditData() {
    return _selectedData;
  }

  void _refreshNode(String subject) {
    _planCache.remove(subject);
    setState(() {});
  }

  // ── Create Plan Dialog ──

  void _showNewPlanDialog() {
    final subjCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final goalCtrl = TextEditingController();
    final authorCtrl = TextEditingController();
    final domainCtrl = TextEditingController();
    final displayCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增计划'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: subjCtrl, decoration: const InputDecoration(labelText: 'subject (en)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'title', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: goalCtrl, decoration: const InputDecoration(labelText: 'goal', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: authorCtrl, decoration: const InputDecoration(labelText: 'author', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: domainCtrl, decoration: const InputDecoration(labelText: 'domain (en)', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: displayCtrl, decoration: const InputDecoration(labelText: 'display_name', isDense: true, border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final resp = await _api('POST', '/api/admin/curriculum/plan', body: {
                'subject': subjCtrl.text.trim(),
                'title': titleCtrl.text.trim(),
                'goal': goalCtrl.text.trim(),
                'author': authorCtrl.text.trim(),
                'domain': domainCtrl.text.trim(),
                'display_name': displayCtrl.text.trim(),
              });
              if (resp['status'] == 'created') {
                _snack('计划已创建');
                _loadSubjects();
              } else {
                _snack(resp['error'] ?? '创建失败');
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  // ── Add Stage Dialog ──

  void _showNewStageDialog(String subject) {
    final nameCtrl = TextEditingController();
    final gradeCtrl = TextEditingController();
    final sortCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增阶段'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'name *', isDense: true, border: OutlineInputBorder()), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: gradeCtrl, decoration: const InputDecoration(labelText: 'grade_band', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: sortCtrl, decoration: const InputDecoration(labelText: 'sort', isDense: true, border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              final body = <String, dynamic>{'name': nameCtrl.text.trim()};
              if (gradeCtrl.text.trim().isNotEmpty) body['grade_band'] = gradeCtrl.text.trim();
              if (sortCtrl.text.trim().isNotEmpty) body['sort'] = sortCtrl.text.trim();
              final resp = await _api('POST', '/api/admin/curriculum/subject/$subject/plan/stages', body: body);
              if (resp['status'] == 'ok') {
                _snack('阶段已添加');
                _refreshNode(subject);
              } else {
                _snack(resp['error'] ?? '添加失败');
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // ── Add Task Dialog ──

  void _showNewTaskDialog(String subject, String stageId) {
    final nameCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final modeCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增任务'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: 'task_key', isDense: true, border: OutlineInputBorder()), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'name *', isDense: true, border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(controller: modeCtrl, decoration: const InputDecoration(labelText: 'prompt_mode', isDense: true, border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty && keyCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              final body = <String, dynamic>{
                'name': nameCtrl.text.trim(),
                'task_key': keyCtrl.text.trim(),
              };
              if (modeCtrl.text.trim().isNotEmpty) body['prompt_mode'] = modeCtrl.text.trim();
              final resp = await _api('POST', '/api/admin/curriculum/subject/$subject/plan/stages/$stageId/tasks', body: body);
              if (resp['status'] == 'ok') {
                _snack('任务已添加');
                _refreshNode(subject);
              } else {
                _snack(resp['error'] ?? '添加失败');
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // ── Edit panels ──

  Widget _buildPlanEditor(Map<String, dynamic> data) {
    final subject = data['_subject'] as String? ?? '';
    final planData = _planCache[subject] ?? data;
    final titleCtrl = TextEditingController(text: (planData['title'] as String?) ?? '');
    final goalCtrl = TextEditingController(text: (planData['goal'] as String?) ?? '');
    final authorCtrl = TextEditingController(text: (planData['author'] as String?) ?? '');
    final displayCtrl = TextEditingController(text: (planData['display_name'] as String?) ?? '');
    final themeColorCtrl = TextEditingController(text: (planData['theme_color'] as String?) ?? '');
    final themeIconCtrl = TextEditingController(text: (planData['theme_icon'] as String?) ?? '');
    final visible = (planData['visible'] as bool?) ?? true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('编辑: ${planData['display_name'] ?? subject}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: subject,
          decoration: const InputDecoration(labelText: 'subject', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: titleCtrl,
          decoration: const InputDecoration(labelText: 'title', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: goalCtrl,
          decoration: const InputDecoration(labelText: 'goal', isDense: true, border: OutlineInputBorder()),
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: authorCtrl,
          decoration: const InputDecoration(labelText: 'author', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: displayCtrl,
          decoration: const InputDecoration(labelText: 'display_name', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('visible: '),
          Switch(
            value: visible,
            onChanged: (v) {
              _api('PATCH', '/api/admin/curriculum/subject/$subject/plan', body: {'visible': v}).then((r) {
                if (r['status'] == 'ok') {
                  _snack('已更新');
                  _refreshNode(subject);
                } else {
                  _snack(r['error'] ?? '失败');
                }
              });
            },
          ),
        ]),
        const SizedBox(height: 12),
        TextFormField(
          controller: themeColorCtrl,
          decoration: const InputDecoration(labelText: 'theme_color', isDense: true, border: OutlineInputBorder(), hintText: '#81C784'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: themeIconCtrl,
          decoration: const InputDecoration(labelText: 'theme_icon', isDense: true, border: OutlineInputBorder(), hintText: 'language'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: planData['domain'] as String? ?? '',
          decoration: const InputDecoration(labelText: 'domain', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: (planData['grade_band'] as String?) ?? '',
          decoration: const InputDecoration(labelText: 'grade', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            _api('PATCH', '/api/admin/curriculum/subject/$subject/plan', body: {
              'title': titleCtrl.text.trim(),
              'goal': goalCtrl.text.trim(),
              'author': authorCtrl.text.trim(),
              'display_name': displayCtrl.text.trim(),
              'theme_color': themeColorCtrl.text.trim(),
              'theme_icon': themeIconCtrl.text.trim(),
            }).then((r) {
              if (r['status'] == 'ok') {
                _snack('已保存');
                _refreshNode(subject);
              } else {
                _snack(r['error'] ?? '保存失败');
              }
            });
          },
          child: const Text('保存'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          onPressed: () => _showNewStageDialog(subject),
          label: const Text('添加阶段'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('确认删除'),
                content: Text('删除计划「${planData['display_name'] ?? subject}」？\n所有阶段和任务将被永久移除。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                  FilledButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final r = await _api('DELETE', '/api/admin/curriculum/subject/$subject/plan');
                      if (r['status'] == 'deleted') {
                        _snack('计划已删除');
                        setState(() { _selectedId = null; _selectedData = null; });
                        _planCache.remove(subject);
                        _loadSubjects();
                      } else {
                        _snack(r['error'] ?? '删除失败');
                      }
                    },
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    child: const Text('删除'),
                  ),
                ],
              ),
            );
          },
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          label: const Text('删除计划'),
        ),
      ]),
    );
  }

  Widget _buildStageEditor(Map<String, dynamic> data) {
    final subject = data['_subject'] as String? ?? '';
    final stageId = data['id'] as String? ?? '';
    final nameCtrl = TextEditingController(text: data['name'] as String? ?? '');
    final sortCtrl = TextEditingController(text: (data['sort'] as String? ?? data['sort_order'] as String? ?? ''));
    final gradeCtrl = TextEditingController(text: (data['grade_band'] as String?) ?? '');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('编辑: ${data['name'] ?? stageId}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextFormField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'name', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: sortCtrl,
          decoration: const InputDecoration(labelText: 'sort', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: gradeCtrl,
          decoration: const InputDecoration(labelText: 'grade_band', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        Row(children: [
          FilledButton(
            onPressed: () {
              _api('PATCH', '/api/admin/curriculum/subject/$subject/plan/stages/$stageId', body: {
                'name': nameCtrl.text.trim(),
                'sort': sortCtrl.text.trim(),
                'grade_band': gradeCtrl.text.trim(),
              }).then((r) {
                if (r['status'] == 'ok') {
                  _snack('已保存');
                  _refreshNode(subject);
                } else {
                  _snack(r['error'] ?? '保存失败');
                }
              });
            },
            child: const Text('保存'),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('确认删除'),
                  content: Text('删除阶段「${data['name'] ?? stageId}」？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final r = await _api('DELETE', '/api/admin/curriculum/subject/$subject/plan/stages/$stageId');
                        if (r['status'] == 'deleted') {
                          _snack('已删除');
                          setState(() { _selectedId = null; _selectedData = null; });
                          _refreshNode(subject);
                        } else {
                          _snack(r['error'] ?? '删除失败');
                        }
                      },
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('删除阶段', style: TextStyle(color: Colors.red)),
          ),
        ]),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          onPressed: () => _showNewTaskDialog(subject, stageId),
          label: const Text('添加任务'),
        ),
      ]),
    );
  }

  Widget _buildTaskEditor(Map<String, dynamic> data) {
    final subject = data['_subject'] as String? ?? '';
    final stageId = data['_stageId'] as String? ?? '';
    final taskId = data['id'] as String? ?? '';
    final nameCtrl = TextEditingController(text: data['name'] as String? ?? '');
    final modeCtrl = TextEditingController(text: data['prompt_mode'] as String? ?? '');
    final sortCtrl = TextEditingController(text: (data['sort_order'] as String?) ?? '');
    final cardIds = data['card_ids'];
    String cardIdsStr = '';
    if (cardIds is List) {
      cardIdsStr = '${cardIds.length} 张卡片';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('编辑: ${data['task_key'] ?? ''} ${data['name'] ?? ''}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: data['task_key'] as String? ?? '',
          decoration: const InputDecoration(labelText: 'task_key', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'name', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: modeCtrl,
          decoration: const InputDecoration(labelText: 'prompt_mode', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: sortCtrl,
          decoration: const InputDecoration(labelText: 'sort_order', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: data['origin'] as String? ?? '',
          decoration: const InputDecoration(labelText: 'origin', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: cardIdsStr,
          decoration: const InputDecoration(labelText: 'card_ids', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        Row(children: [
          FilledButton(
            onPressed: () {
              _api('PATCH', '/api/admin/curriculum/subject/$subject/plan/stages/$stageId/tasks/$taskId', body: {
                'name': nameCtrl.text.trim(),
                'prompt_mode': modeCtrl.text.trim(),
                'sort_order': sortCtrl.text.trim(),
              }).then((r) {
                if (r['status'] == 'ok') {
                  _snack('已保存');
                  _refreshNode(subject);
                } else {
                  _snack(r['error'] ?? '保存失败');
                }
              });
            },
            child: const Text('保存'),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('确认删除'),
                  content: Text('删除任务「${data['name'] ?? taskId}」？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final r = await _api('DELETE', '/api/admin/curriculum/subject/$subject/plan/stages/$stageId/tasks/$taskId');
                        if (r['status'] == 'deleted') {
                          _snack('已删除');
                          setState(() { _selectedId = null; _selectedData = null; });
                          _refreshNode(subject);
                        } else {
                          _snack(r['error'] ?? '删除失败');
                        }
                      },
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('删除任务', style: TextStyle(color: Colors.red)),
          ),
        ]),
      ]),
    );
  }

  Widget _buildEditor() {
    final data = _currentEditData();
    if (data == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.arrow_back, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text('从左侧选择一个项目进行编辑', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );
    }
    final type = data['_type'] as String;
    if (type == 'plan') return _buildPlanEditor(data);
    if (type == 'stage') return _buildStageEditor(data);
    return _buildTaskEditor(data);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      SizedBox(
        width: 280,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: cs.surfaceContainerHighest,
            child: Row(children: [
              const Icon(Icons.school, size: 18),
              const SizedBox(width: 6),
              Text('学习计划 (${_subjects.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: _showNewPlanDialog,
                tooltip: '新增计划',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _subjects.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('暂无计划', style: TextStyle(color: cs.onSurfaceVariant)),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _loadSubjects, child: const Text('刷新')),
                        ]),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: _subjects.map((s) {
                          final subj = s['subject'] as String? ?? '';
                          final loaded = s['loaded'] == true;
                          return _TreeEntry(
                            key: ValueKey('plan:$subj'),
                            node: _PlanTreeNode(
                              type: _NodeType.plan,
                              label: s['display_name'] as String? ?? subj,
                              subtitle: loaded ? '${s['stages_count'] ?? 0}段' : '(未加载)',
                              data: {},
                              subject: subj,
                            ),
                            depth: 0,
                            selectedId: _selectedId,
                            onSelect: (id) {
                              setState(() => _selectedId = id);
                              if (id.startsWith('plan:')) {
                                final subject = id.split(':')[1];
                                _loadPlan(subject).then((plan) {
                                  _selectedData = {'_type': 'plan', '_subject': subject, ...plan};
                                  if (mounted) setState(() {});
                                });
                              } else if (id.startsWith('stage:')) {
                                final stageId = id.split(':')[1];
                                for (final entry in _planCache.entries) {
                                  final stages = entry.value['stages'] as List? ?? [];
                                  for (final s in stages) {
                                    final sMap = s as Map<String, dynamic>;
                                    if (sMap['id'] == stageId) {
                                      _selectedData = {'_type': 'stage', '_subject': entry.key, ...sMap};
                                      if (mounted) setState(() {});
                                      return;
                                    }
                                  }
                                }
                              } else if (id.startsWith('task:')) {
                                final taskId = id.split(':')[1];
                                for (final entry in _planCache.entries) {
                                  final stages = entry.value['stages'] as List? ?? [];
                                  for (final s in stages) {
                                    final sMap = s as Map<String, dynamic>;
                                    final tasks = sMap['tasks'] as List? ?? [];
                                    for (final t in tasks) {
                                      final tMap = t as Map<String, dynamic>;
                                      if (tMap['id'] == taskId) {
                                        _selectedData = {'_type': 'task', '_subject': entry.key, '_stageId': sMap['id'], ...tMap};
                                        if (mounted) setState(() {});
                                        return;
                                      }
                                    }
                                  }
                                }
                              }
                            },
                            loadChildren: () async {
                              final plan = await _loadPlan(subj);
                              final stages = plan['stages'] as List? ?? [];
                              return stages.map((st) {
                                final stMap = st as Map<String, dynamic>;
                                final tasks = stMap['tasks'] as List? ?? [];
                                return _PlanTreeNode(
                                  type: _NodeType.stage,
                                  label: stMap['name'] as String? ?? 'unknown',
                                  subtitle: '${tasks.length}任务',
                                  data: stMap,
                                  subject: subj,
                                );
                              }).toList();
                            },
                          );
                        }).toList(),
                      ),
          ),
        ]),
      ),
      VerticalDivider(width: 1, color: cs.outlineVariant),
      Expanded(child: KeyedSubtree(key: ValueKey(_selectedId), child: _buildEditor())),
    ]);
  }
}
