import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:coevo_shared/api/api_config.dart';

/// Tree node types.
enum _CardNodeType { subject, domain, card }

/// Tree node data.
class _CardTreeNode {
  final _CardNodeType type;
  final String label;
  final String? subtitle;
  final Map<String, dynamic> data;
  final Future<List<_CardTreeNode>> Function()? loadChildren;
  const _CardTreeNode({
    required this.type,
    required this.label,
    this.subtitle,
    required this.data,
    this.loadChildren,
  });
}

/// Domain metadata for card editing.
const _domainMeta = {
  'language': {
    'label': '语言',
    'fields': ['pronunciation', 'pos', 'definitions', 'related_phrases', 'structure_meta', 'level'],
  },
  'science': {
    'label': '科学',
    'fields': ['definition', 'key_elements', 'applications', 'related_concepts', 'formula', 'graph', 'source'],
  },
  'literature': {
    'label': '文学',
    'fields': ['full_text', 'translation', 'author', 'genre'],
  },
  'humanities': {
    'label': '人文',
    'fields': ['node_type', 'body', 'period', 'region', 'tags'],
  },
};

/// Tree entry widget with lazy loading.
class _CardsTreeEntry extends StatefulWidget {
  final _CardTreeNode node;
  final int depth;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final Future<List<_CardTreeNode>> Function() loadChildren;

  const _CardsTreeEntry({
    required this.node,
    required this.depth,
    required this.selectedId,
    required this.onSelect,
    required this.loadChildren,
  });

  @override
  State<_CardsTreeEntry> createState() => _CardsTreeEntryState();
}

class _CardsTreeEntryState extends State<_CardsTreeEntry> {
  bool _expanded = false;
  bool _loading = false;
  List<_CardTreeNode>? _children;

  String _itemId(_CardTreeNode n) {
    if (n.type == _CardNodeType.subject) return 'subj:${n.data['subject']}';
    if (n.type == _CardNodeType.domain) return 'dom:${n.data['subject']}:${n.data['domain']}';
    return 'card:${n.data['id']}';
  }

  void _toggle() async {
    if (widget.node.type == _CardNodeType.card) {
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = _itemId(widget.node) == widget.selectedId;
    final isSubject = widget.node.type == _CardNodeType.subject;

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
              isSubject ? Icons.school : widget.node.type == _CardNodeType.domain ? Icons.folder : Icons.style,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.node.label,
                style: TextStyle(fontSize: isSubject ? 14 : 13, fontWeight: isSubject ? FontWeight.w600 : FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.node.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(widget.node.subtitle!, style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              ),
            if (_loading)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            else if (widget.node.type != _CardNodeType.card)
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
      if (_expanded && _children != null && !_loading)
        ..._children!.map((child) => _CardsTreeEntry(
              node: child,
              depth: widget.depth + 1,
              selectedId: widget.selectedId,
              onSelect: widget.onSelect,
              loadChildren: child.loadChildren ?? (() async => []),
            )),
    ]);
  }
}

/// Curriculum Cards Page — left tree + right editor.
class CurriculumCardsPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const CurriculumCardsPage({super.key, this.adminKey, this.token});

  @override
  State<CurriculumCardsPage> createState() => _CurriculumCardsPageState();
}

class _CurriculumCardsPageState extends State<CurriculumCardsPage> {
  List<Map<String, dynamic>> _subjects = [];
  Map<String, List<Map<String, dynamic>>> _cardCache = {};
  String? _selectedId;
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

  Future<List<Map<String, dynamic>>> _loadCards(String subject, String domain) async {
    final key = '$subject:$domain';
    if (_cardCache.containsKey(key)) return _cardCache[key]!;
    final resp = await _api('GET', '/api/admin/curriculum/subject/$subject/cards?domain=$domain&limit=500&offset=0');
    final cards = (resp['cards'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    _cardCache[key] = cards;
    return cards;
  }

  /// Find currently selected entity data.
  Map<String, dynamic>? _currentEditData() {
    if (_selectedId == null) return null;
    final parts = _selectedId!.split(':');
    final type = parts[0];
    if (type == 'subj') {
      final subject = parts[1];
      final s = _subjects.cast<Map<String, dynamic>?>().firstWhere(
        (s) => s?['subject'] == subject,
        orElse: () => null,
      );
      if (s == null) return null;
      return {'_type': 'subject', ...s};
    }
    if (type == 'dom') {
      final subject = parts[1];
      final domain = parts[2];
      final meta = _domainMeta[domain] as Map<String, dynamic>?;
      return {'_type': 'domain', '_subject': subject, 'domain': domain, '_label': meta?['label'] ?? domain};
    }
    // type == 'card'
    final cardId = parts[1];
    // Search all caches
    for (final entry in _cardCache.entries) {
      for (final c in entry.value) {
        if (c['id'] == cardId) {
          final keyParts = entry.key.split(':');
          return {'_type': 'card', '_subject': keyParts[0], '_domain': keyParts[1], ...c};
        }
      }
    }
    return null;
  }

  void _refreshCards(String subject, String domain) {
    _cardCache.remove('$subject:$domain');
    setState(() {});
  }

  // ── Subject editor ──

  Widget _buildSubjectEditor(Map<String, dynamic> data) {
    final subject = data['subject'] as String? ?? '';
    final displayCtrl = TextEditingController(text: data['display_name'] as String? ?? '');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('编辑: ${data['display_name'] ?? subject}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: subject,
          enabled: false,
          decoration: const InputDecoration(labelText: 'subject (只读)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: displayCtrl,
          decoration: const InputDecoration(labelText: 'display_name', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        // Note: subject-level editing for card-related metadata
        // Display name is the only editable field here, more fields may be added
        const SizedBox(height: 20),
        Text('提示: 点击 domain 节点下方的卡片进行编辑', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  // ── Domain placeholder ──

  Widget _buildDomainPlaceholder(Map<String, dynamic> data) {
    final domain = data['domain'] as String? ?? '';
    final label = data['_label'] as String? ?? domain;
    final subject = data['_subject'] as String? ?? '';
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ($domain)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('新增卡片'),
          onPressed: () => _showNewCardDialog(subject, domain),
        ),
      ]),
    );
  }

  // ── Card editor ──

  Widget _buildCardEditor(Map<String, dynamic> data) {
    final subject = data['_subject'] as String? ?? '';
    final domain = data['_domain'] as String? ?? '';
    final cardId = data['id'] as String? ?? '';
    final meta = _domainMeta[domain] as Map<String, dynamic>?;
    final domainFields = (meta?['fields'] as List<String>?) ?? [];

    final gradeCtrl = TextEditingController(text: (data['grade_band'] as String?) ?? '');
    final domainCtrls = <String, TextEditingController>{};
    for (final f in domainFields) {
      final val = data[f];
      String strVal = '';
      if (val is String) {
        strVal = val;
      } else if (val is List) {
        strVal = jsonEncode(val);
      } else if (val is Map) {
        strVal = jsonEncode(val);
      }
      domainCtrls[f] = TextEditingController(text: strVal);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('编辑: ${data['front'] ?? cardId} (${data['card_type'] ?? ''})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: data['front'] as String? ?? '',
          enabled: false,
          decoration: const InputDecoration(labelText: 'front (只读)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: data['card_type'] as String? ?? '',
          enabled: false,
          decoration: const InputDecoration(labelText: 'card_type (只读)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: subject,
          enabled: false,
          decoration: const InputDecoration(labelText: 'subject (只读)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: domain,
          enabled: false,
          decoration: const InputDecoration(labelText: 'domain (只读)', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: gradeCtrl,
          decoration: const InputDecoration(labelText: 'grade_band', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (domainFields.isNotEmpty) ...[
          Text('— $domain 字段 —', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 8),
          for (final f in domainFields) ...[
            TextFormField(
              controller: domainCtrls[f],
              decoration: InputDecoration(labelText: f, isDense: true, border: const OutlineInputBorder()),
              maxLines: f == 'definitions' || f == 'full_text' || f == 'body' || f == 'tags' ? 3 : 1,
              minLines: f == 'definitions' || f == 'full_text' || f == 'body' || f == 'tags' ? 2 : 1,
            ),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 20),
        Row(children: [
          FilledButton(
            onPressed: () {
              final body = <String, dynamic>{'grade_band': gradeCtrl.text.trim()};
              for (final f in domainFields) {
                final val = domainCtrls[f]?.text.trim() ?? '';
                if (val.isNotEmpty) body[f] = val;
              }
              _api('PATCH', '/api/admin/curriculum/subject/$subject/cards/$cardId', body: body).then((r) {
                if (r['status'] == 'ok') {
                  _snack('已保存');
                  _refreshCards(subject, domain);
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
                  content: Text('删除卡片「${data['front'] ?? cardId}」？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final r = await _api('DELETE', '/api/admin/curriculum/subject/$subject/cards/$cardId');
                        if (r['status'] == 'deleted') {
                          _snack('已删除');
                          setState(() => _selectedId = null);
                          _refreshCards(subject, domain);
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
            child: const Text('删除卡片', style: TextStyle(color: Colors.red)),
          ),
        ]),
      ]),
    );
  }

  // ── New card dialog ──

  void _showNewCardDialog(String subject, String domain) {
    final frontCtrl = TextEditingController();
    final typeCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增卡片'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: frontCtrl, decoration: const InputDecoration(labelText: 'front', isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: typeCtrl, decoration: const InputDecoration(labelText: 'card_type', isDense: true, border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final resp = await _api('POST', '/api/admin/curriculum/subject/$subject/cards', body: {
                'front': frontCtrl.text.trim(),
                'card_type': typeCtrl.text.trim(),
                'domain': domain,
                'subject': subject,
              });
              if (resp.containsKey('id')) {
                _snack('卡片已创建');
                _refreshCards(subject, domain);
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
    if (type == 'subject') return _buildSubjectEditor(data);
    if (type == 'domain') {
      return _buildDomainPlaceholder(data);
    }
    return _buildCardEditor(data);
  }

  /// Helper: create a lazy-loading child function for a domain node.
  Future<List<_CardTreeNode>> Function() _makeCardLoader(String subject, String domain) {
    return () async {
      final cards = await _loadCards(subject, domain);
      return cards.map((c) => _CardTreeNode(
        type: _CardNodeType.card,
        label: c['front']?.toString() ?? '?',
        subtitle: '[${c['level'] ?? c['card_type'] ?? ''}]',
        data: c,
      )).toList();
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      // Left: Tree
      SizedBox(
        width: 280,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: cs.surfaceContainerHighest,
            child: Row(children: [
              const Icon(Icons.style, size: 18),
              const SizedBox(width: 6),
              Text('卡片数据 (${_subjects.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () {
                  _cardCache.clear();
                  _loadSubjects();
                },
                tooltip: '刷新',
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
                          Text('暂无数据', style: TextStyle(color: cs.onSurfaceVariant)),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _loadSubjects, child: const Text('刷新')),
                        ]),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: _subjects.map((s) {
                          final subj = s['subject'] as String? ?? '';
                          final loaded = s['loaded'] == true;
                          return _CardsTreeEntry(
                            node: _CardTreeNode(
                              type: _CardNodeType.subject,
                              label: s['display_name'] as String? ?? subj,
                              subtitle: loaded ? null : '(未加载)',
                              data: {'subject': subj, 'display_name': s['display_name']},
                            ),
                            depth: 0,
                            selectedId: _selectedId,
                            onSelect: (id) => setState(() => _selectedId = id),
                            loadChildren: () async {
                              if (!loaded) return [];
                              const domains = [
                                {'key': 'language', 'label': '语言'},
                                {'key': 'science', 'label': '科学'},
                                {'key': 'literature', 'label': '文学'},
                                {'key': 'humanities', 'label': '人文'},
                              ];
                              return domains.map((d) => _CardTreeNode(
                                type: _CardNodeType.domain,
                                label: d['label']!,
                                data: {'subject': subj, 'domain': d['key']},
                                loadChildren: _makeCardLoader(subj, d['key']!),
                              )).toList();
                            },
                          );
                        }).toList(),
                      ),
          ),
        ]),
      ),
      VerticalDivider(width: 1, color: cs.outlineVariant),
      Expanded(child: _buildEditor()),
    ]);
  }
}
