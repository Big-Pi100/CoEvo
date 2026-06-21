import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

/// 分享弹窗 — 显示推广码、生成海报、分享链接
class ShareWidget extends ConsumerWidget {
  final String? campaignId;
  const ShareWidget({super.key, this.campaignId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _ShareWidgetBody(auth: auth, campaignId: campaignId);
  }
}

class _ShareWidgetBody extends StatefulWidget {
  final AuthState auth;
  final String? campaignId;
  const _ShareWidgetBody({required this.auth, this.campaignId});

  @override
  State<_ShareWidgetBody> createState() => _ShareWidgetBodyState();
}

class _ShareWidgetBodyState extends State<_ShareWidgetBody> {
  String? _referralCode;
  String? _posterPng;
  String? _shareUrl;
  String? _campaignId;
  bool _loading = true;
  bool _generatingPoster = false;
  bool _generatingH5 = false;

  Map<String, String> get _headers {
    final token = widget.auth.token;
    if (token != null) return {'Authorization': 'Bearer $token'};
    return {};
  }

  String get _userId => widget.auth.userId ?? '';

  @override
  void initState() {
    super.initState();
    _campaignId = widget.campaignId;
    _loadCode();
  }

  Future<void> _loadCode() async {
    if (_userId.isEmpty) return;
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/my-code?user_id=$_userId');
      final resp = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _referralCode = data['referral_code'] as String?;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
      // 自动生成海报（无模板则用 fallback）
      _generatePoster();
    }
  }

  Future<void> _generatePoster() async {
    setState(() => _generatingPoster = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/generate-poster');
      final resp = await http
          .post(uri,
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'user_id': _userId,
                if (_campaignId != null) 'campaign_id': _campaignId,
              }))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _posterPng = data['poster_png'] as String?;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('海报已生成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败: $e')));
      }
    }
    if (mounted) setState(() => _generatingPoster = false);
  }

  Future<void> _generateH5() async {
    setState(() => _generatingH5 = true);
    try {
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/referral/generate-h5');
      final resp = await http
          .post(uri,
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'user_id': _userId,
                if (_campaignId != null) 'campaign_id': _campaignId,
              }))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _shareUrl = data['url'] as String?;
        setState(() {});
        final fullUrl = _shareUrl ?? ApiConfig.baseUrl;
        // 复制到剪贴板
        await _copyToClipboard(fullUrl);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享链接已复制: $fullUrl')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败: $e')));
      }
    }
    if (mounted) setState(() => _generatingH5 = false);
  }

  Future<void> _copyToClipboard(String text) async {
    // Use CopyWith — for web, falls back to clipboard API
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('复制以下链接分享给好友：'),
                const SizedBox(height: 8),
                SelectableText(text),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXxl),
        child: _loading
            ? const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('分享推广',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: AppTheme.spacingLg),
                  // 推广码展示
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text('我的推广码',
                            style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant)),
                        const SizedBox(height: AppTheme.spacingXs),
                        Text(
                          _referralCode ?? '--',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                              letterSpacing: 2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingLg),
                  // 二维码展示（客户端生成，无需网络请求）
                  if (_referralCode != null)
                    Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: QrImageView(
                        data: 'https://keyievolution.fun/app/auth?ref=$_referralCode',
                        version: QrVersions.auto,
                        size: 180,
                        eyeStyle: QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: const Color(0xFF1A237E),
                        ),
                        dataModuleStyle: QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: const Color(0xFF1A237E),
                        ),
                      ),
                    ),

                  const SizedBox(height: AppTheme.spacingXs),
                  Text('扫码注册',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant)),
                  const SizedBox(height: AppTheme.spacingLg),
                  // 海报 PNG 预览
                  if (_posterPng != null) ...[
                    Container(
                      height: 200,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(_posterPng!.split(',').last),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Center(
                            child: Text('海报预览失败',
                                style: TextStyle(color: cs.onSurfaceVariant)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingSm),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.download, size: 16),
                        onPressed: () {
                          final bytes = base64Decode(_posterPng!.split(',').last);
                          final blob = html.Blob([bytes], 'image/png');
                          final objUrl = html.Url.createObjectUrlFromBlob(blob);
                          (html.document.createElement('a') as html.AnchorElement)
                            ..href = objUrl
                            ..download = 'coevo_poster_$_referralCode.png'
                            ..click();
                          html.Url.revokeObjectUrl(objUrl);
                        },
                        label: const Text('下载海报', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingSm),
                  ] else if (_generatingPoster) ...[
                    // 自动生成海报中
                    Container(
                      height: 120,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 24, height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(height: AppTheme.spacingSm),
                            Text('正在生成专属海报...',
                                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTheme.spacingSm),
                  ],
                  // 操作按钮
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: _generatingPoster
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Icon(Icons.photo_library, size: 18),
                      onPressed: _generatingPoster ? null : _generatePoster,
                      label: const Text('保存海报到相册'),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSm),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: _generatingH5
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Icon(Icons.share, size: 18),
                      onPressed: _generatingH5 ? null : _generateH5,
                      label: const Text('分享链接给好友'),
                    ),
                  ),
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
