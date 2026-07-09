/// 成就分享海报 — 固定模板，全屏 Overlay 展示
/// 不含 Scaffold/Navigator，适配 Flutter Web
/// 已适配系统字体缩放 + 手机小屏
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'referral_qr_code.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../shared/achievement_icons.dart';
import '../widgets/twemoji.dart';

class AchievementShareCard extends StatefulWidget {
  final String achievementKey;
  final String achievementName;
  final String? achievementDesc;
  final String tier;
  final Color iconColor;
  final String userName;
  final String? referralCode;
  final VoidCallback onClose;

  const AchievementShareCard({
    super.key,
    required this.achievementKey,
    required this.achievementName,
    this.achievementDesc,
    required this.tier,
    required this.iconColor,
    required this.userName,
    this.referralCode,
    required this.onClose,
  });

  @override
  State<AchievementShareCard> createState() => _AchievementShareCardState();
}

class _AchievementShareCardState extends State<AchievementShareCard> {
  final GlobalKey _repaintKey = GlobalKey();
  bool _saving = false;
  String? _saveFeedback;

  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('无法获取渲染边界');
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('图片编码失败');

      final Uint8List pngBytes = byteData.buffer.asUint8List();
      // Flutter Web: 使用 Blob + AnchorElement 触发下载
      final blob = html.Blob([pngBytes], 'image/png');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', 'coevo_achievement_${widget.achievementKey}.png')
        ..click();
      html.Url.revokeObjectUrl(url);

      setState(() => _saveFeedback = '海报已保存');
    } catch (e) {
      setState(() => _saveFeedback = '保存失败: $e');
    } finally {
      setState(() => _saving = false);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _saveFeedback = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconData = achievementIcon(widget.achievementKey);
    final tLabel = _tierLabel(widget.tier);
    final glowColor = _tierColor(widget.tier);
    final topPad = MediaQuery.of(context).padding.top + 8;
    // 限制文字缩放，防止海报溢出
    final textScale = MediaQuery.textScalerOf(context).clamp(minScaleFactor: 0.8, maxScaleFactor: 1.1);

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          // 海报主体（可滚动）
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    top: topPad + 40,  // 给按钮留空间
                    bottom: 24,
                    left: 16,
                    right: 16,
                  ),
                  child: RepaintBoundary(
                    key: _repaintKey,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: textScale,
                      ),
                      child: _buildPoster(cs, iconData, tLabel, glowColor),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 顶层按钮区（浮在可滚动内容之上，始终可见）
          Positioned(
            top: topPad,
            left: 0,
            right: 0,
            child: Row(
              children: [
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: widget.onClose,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _saving ? null : _saveImage,
                  icon: _saving
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.download, size: 16, color: Colors.white),
                  label: Text(
                    _saving ? '保存中...' : '保存图片',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          // 保存反馈
          if (_saveFeedback != null)
            Positioned(
              top: topPad + 44,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Tw(
                      _saveFeedback!,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPoster(
      ColorScheme cs, IconData iconData, String tLabel, Color glowColor) {
    final screenWidth = MediaQuery.of(context).size.width;
    // 海报最大宽度 340，手机小屏自适应（左右留 16px 边距）
    final posterWidth = (screenWidth - 32).clamp(280.0, 340.0);

    return Container(
      width: posterWidth,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [cs.surface, glowColor.withAlpha(18), cs.surface],
        ),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: [
          BoxShadow(
              color: glowColor.withAlpha(80), blurRadius: 40, spreadRadius: 8),
          BoxShadow(
              color: cs.shadow.withAlpha(30), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // 品牌
          Text('⟐ CoEvo',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                  color: cs.primary)),
          const SizedBox(height: 20),
          // 缎带
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: glowColor.withAlpha(30),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: glowColor.withAlpha(80)),
            ),
            child: Tw(tLabel,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: glowColor)),
          ),
          const SizedBox(height: 20),
          // 图标
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: widget.iconColor.withAlpha(20),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: widget.iconColor.withAlpha(60),
                    blurRadius: 20,
                    spreadRadius: 4),
              ],
            ),
            child: Icon(iconData, size: 40, color: widget.iconColor),
          ),
          const SizedBox(height: 16),
          Text(widget.achievementName,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: cs.onSurface),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          if (widget.achievementDesc != null &&
              widget.achievementDesc!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(widget.achievementDesc!,
                style: TextStyle(fontSize: 13, color: cs.onSurface, height: 1.3),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 20),
          Divider(
              indent: 40,
              endIndent: 40,
              color: cs.outline,
              thickness: 1, height: 1),
          const SizedBox(height: 16),
          // 用户
          if (widget.userName.isNotEmpty)
            Text(widget.userName,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text('在 CoEvo 获得「${widget.achievementName}」',
              style:
                  TextStyle(fontSize: 12, color: cs.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          // 二维码
          if (widget.referralCode != null && widget.referralCode!.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: ReferralQrCode(
                referralCode: widget.referralCode!,
                camp: 'achievement',
                size: 100,
                backgroundColor: Colors.white,
                moduleColor: Colors.black,
                eyeColor: cs.primary,
              ),
            ),
          const SizedBox(height: 8),
          Text('扫码一起学',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w500, color: cs.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          Text('keyievolution.fun',
              style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _tierLabel(String tier) {
    switch (tier) {
      case 'bronze': return '🥉 青铜';
      case 'silver': return '🥈 白银';
      case 'gold': return '🥇 黄金';
      case 'platinum': return '💎 铂金';
      case 'diamond': return '🌟 钻石';
      default: return '🏆 $tier';
    }
  }

  static Color _tierColor(String tier) {
    switch (tier) {
      case 'bronze': return const Color(0xFFCD7F32);
      case 'silver': return const Color(0xFFA0A0A0);
      case 'gold': return const Color(0xFFFFD700);
      case 'platinum': return const Color(0xFF00BFFF);
      case 'diamond': return const Color(0xFFB9F2FF);
      default: return const Color(0xFFFFD700);
    }
  }
}
