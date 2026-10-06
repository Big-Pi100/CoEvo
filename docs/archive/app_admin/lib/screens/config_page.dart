import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:coevo_shared/api/api_config.dart';
import '../theme/app_theme.dart';

class ConfigPage extends StatefulWidget {
  final String? adminKey;
  final String? token;
  const ConfigPage({super.key, this.adminKey, this.token});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  List<Map<String, dynamic>> _configs = [];
  bool _loading = false;
  bool _saving = false;

  // Prompt template
  List<String> _templateFiles = [];
  String? _selectedTemplate;
  final _contentCtrl = TextEditingController();
  bool _promptSaving = false;
  bool _templatesLoading = false;

  Map<String, String> _headers() {
    if (widget.adminKey != null) return {'X-Admin-Key': widget.adminKey!};
    if (widget.token != null)
      return {'Authorization': 'Bearer ${widget.token}'};
    return {};
  }

  Future<Map<String, dynamic>> _api(String method, String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final h = _headers();
    final req = method == 'GET'
        ? http.get(uri, headers: h)
        : method == 'POST'
            ? http.post(uri,
                headers: {...h, 'Content-Type': 'application/json'},
                body: jsonEncode(body ?? {}))
            : http.put(uri,
                headers: {...h, 'Content-Type': 'application/json'},
                body: jsonEncode(body ?? {}));
    final resp = await req.timeout(const Duration(seconds: 10));
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {'error': '${resp.statusCode}'};
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void initState() {
    super.initState();
    _loadConfigs();
    _loadTemplateFiles();
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfigs() async {
    setState(() => _loading = true);
    final resp = await _api('GET', '/api/admin/config');
    setState(() {
      _configs = (resp['configs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _loading = false;
    });
  }

  Future<void> _loadTemplateFiles() async {
    setState(() => _templatesLoading = true);
    final resp = await _api('GET', '/api/admin/prompt/templates');
    setState(() {
      _templateFiles = (resp['files'] as List?)?.cast<String>() ?? [];
      _templatesLoading = false;
    });
  }

  Future<void> _saveConfigs() async {
    setState(() => _saving = true);
    final entries =
        _configs.map((c) => {'key': c['key'], 'value': c['value']}).toList();
    final resp =
        await _api('POST', '/api/admin/config', body: {'configs': entries});
    setState(() => _saving = false);
    if (resp.containsKey('status')) {
      _snack('配置已保存');
    } else {
      _snack(resp['error'] ?? '保存失败');
    }
  }

  void _editConfig(int index) {
    final entry = _configs[index];
    final ctrl = TextEditingController(text: entry['value'] as String? ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry['key'] as String? ?? ''),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry['description'] != null &&
                (entry['description'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                child: Text(entry['description'] as String,
                    style:
                        _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant)),
              ),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: '值',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              maxLines: null,
              minLines: 1,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _configs[index]['value'] = ctrl.text.trim());
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadPromptTemplateWithPath(String path) async {
    if (path.isEmpty) return;
    final resp = await _api(
        'GET', '/api/admin/prompt/template?path=${Uri.encodeComponent(path)}');
    setState(() {
      if (resp.containsKey('content')) {
        _contentCtrl.text = resp['content'] as String? ?? '';
      } else {
        _snack(resp['error'] ?? '加载失败');
      }
    });
  }

  Future<void> _savePromptTemplate() async {
    final path = _selectedTemplate;
    if (path == null || path.isEmpty) {
      _snack('请先选择模板');
      return;
    }
    setState(() => _promptSaving = true);
    final resp = await _api('POST', '/api/admin/prompt/template', body: {
      'path': path,
      'content': _contentCtrl.text,
    });
    setState(() => _promptSaving = false);
    if (resp.containsKey('status')) {
      _snack('模板已保存');
    } else {
      _snack(resp['error'] ?? '保存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Config Section ──
          Row(
            children: [
              Text('运行时配置',
                  style:
                      _tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (!_loading)
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: _loadConfigs,
                  label: const Text('刷新', style: TextStyle(fontSize: 12)),
                ),
              if (_configs.isNotEmpty)
                FilledButton.icon(
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save, size: 16),
                  onPressed: _saving ? null : _saveConfigs,
                  label: Text(_saving ? '保存中...' : '保存',
                      style: const TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.spacingMd)),
                ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingMd),
          if (_loading)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (_configs.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.spacingXxl),
                child: Center(
                  child: Text('暂无配置数据',
                      style: TextStyle(color: _cs.onSurfaceVariant)),
                ),
              ),
            )
          else
            ...List.generate(_configs.length, (i) {
              final c = _configs[i];
              return Card(
                margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _editConfig(i),
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.spacingMd),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c['key'] as String? ?? '',
                                style: _tt.labelLarge?.copyWith(
                                  color: _cs.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (c['description'] != null &&
                                  (c['description'] as String).isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    c['description'] as String,
                                    style: _tt.bodySmall
                                        ?.copyWith(color: _cs.onSurfaceVariant),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppTheme.spacingMd),
                        Expanded(
                          flex: 3,
                          child: Container(
                            padding: const EdgeInsets.all(AppTheme.spacingSm),
                            decoration: BoxDecoration(
                              color: _cs.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              c['value'] as String? ?? '',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppTheme.spacingSm),
                        Icon(Icons.edit, size: 16, color: _cs.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: AppTheme.spacingXxl),
          const Divider(),
          const SizedBox(height: AppTheme.spacingLg),

          // ── Prompt Template Section ──
          Text('Prompt 模板编辑',
              style: _tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppTheme.spacingSm),
          Text('修改模板需要 super 权限',
              style: _tt.bodySmall?.copyWith(color: _cs.error)),
          const SizedBox(height: AppTheme.spacingMd),

          Row(
            children: [
              Expanded(
                child: _templatesLoading
                    ? const SizedBox(
                        height: 40,
                        child: Center(
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))),
                      )
                    : Autocomplete<String>(
                        optionsBuilder: (textEditingValue) {
                          if (textEditingValue.text.isEmpty)
                            return _templateFiles;
                          return _templateFiles.where((f) => f
                              .toLowerCase()
                              .contains(textEditingValue.text.toLowerCase()));
                        },
                        onSelected: (selection) {
                          setState(() => _selectedTemplate = selection);
                          _loadPromptTemplateWithPath(selection);
                        },
                        fieldViewBuilder:
                            (context, controller, focusNode, onSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: const InputDecoration(
                              labelText: '选择或搜索模板',
                              hintText: 'chat/general/structured.md',
                              helperText: '输入关键词搜索，从下拉列表选择',
                              isDense: true,
                              border: OutlineInputBorder(),
                              suffixIcon: Icon(Icons.search, size: 18),
                            ),
                            style: const TextStyle(fontSize: 13),
                            onSubmitted: (_) => onSubmitted(),
                          );
                        },
                      ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _loadTemplateFiles,
                label: const Text('刷新', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingSm),
          // ── Selected file path display ──
          if (_selectedTemplate != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
              width: double.infinity,
              decoration: BoxDecoration(
                color: _cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.description,
                      size: 14, color: _cs.onSurfaceVariant),
                  const SizedBox(width: AppTheme.spacingSm),
                  Expanded(
                    child: Text(
                      _selectedTemplate!,
                      style: _tt.bodySmall?.copyWith(
                        color: _cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppTheme.spacingMd),
          TextField(
            controller: _contentCtrl,
            decoration: const InputDecoration(
              hintText: '模板内容...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLines: 15,
            minLines: 8,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
          const SizedBox(height: AppTheme.spacingSm),
          Row(
            children: [
              const Spacer(),
              FilledButton.icon(
                icon: _promptSaving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.save, size: 16),
                onPressed: _promptSaving ? null : _savePromptTemplate,
                label: Text(_promptSaving ? '保存中...' : '保存',
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
