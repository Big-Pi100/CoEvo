import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../theme/app_theme.dart';

/// 跳过的概念页 — 展示用户主动跳过的概念列表
class SkippedScreen extends ConsumerStatefulWidget {
  const SkippedScreen({super.key});

  @override
  ConsumerState<SkippedScreen> createState() => _SkippedScreenState();
}

class _SkippedScreenState extends ConsumerState<SkippedScreen> {
  List<Map<String, dynamic>>? _cards;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final resp = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/api/cards?status=skipped'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body);
        _cards = (data['cards'] as List?)
            ?.map((e) => e as Map<String, dynamic>)
            .toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('跳过的概念')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cards == null || _cards!.isEmpty
              ? Center(
                  child: Text('暂无跳过的概念',
                      style: TextStyle(color: cs.onSurfaceVariant)))
              : ListView.builder(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  itemCount: _cards!.length,
                  itemBuilder: (_, i) {
                    final card = _cards![i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                      child: ListTile(
                        leading: Icon(Icons.skip_next, color: cs.tertiary),
                        title: Text(card['front'] as String? ?? '',
                            style: const TextStyle(fontSize: 14)),
                        subtitle: card['back'] != null
                            ? Text(card['back'] as String,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12))
                            : null,
                      ),
                    );
                  },
                ),
    );
  }
}
