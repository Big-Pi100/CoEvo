// CoEvo · **分享图预览弹层** —— 先看再发，点「分享」才渲染导出。
//
// # 🔑 为什么必须先弹预览（不直接分享）
// 图是**给别人看的**，用户该先看到再决定发不发（同族先例：「**先有可看的目标**」）。
// 而且预览页顺带承担两件事：
// · **切换底色**（规格 §5.7.3 要求「深色/浅色双版本」⇒ 用户自己挑）
// · **失败出口**（渲染/分享失败时把原因**显示出来**，不是静默 —— 本项目大忌「静默失败 + 无出口」）
//
// # 🔴 渲染管线的两个关键点
// 1. **卡片尺寸恒定**：`RepaintBoundary` 内**始终**是 `kShareCardWidth × kShareCardHeight`
//    （`FittedBox` 给 child 无界约束 ⇒ child 按自己尺寸布局，再由 FittedBox 缩放显示）。
//    ⇒ 不同手机导出的图**尺寸一致**（1080×1440）。
//    ⚠️ **不能用 `Transform.scale` 代替 `FittedBox`**（2026-10-06 实测踩过）：
//       `Transform` **不改布局约束** ⇒ 父 `SizedBox(360*scale)` 会把卡片**压小** ⇒
//       `RepaintBoundary.size` 变成 `360*scale` ⇒ **导出尺寸随屏幕变化**。
//       （同族先例：`reading_tab_screen.dart:161` / `subscribe_screen.dart:376` 用 `FittedBox`。）
// 2. **导出走 `exportPngBytes`**（`utils/image_export.dart`）—— 它内部是
//    「写临时文件 → `share_plus` 唤起系统面板」，这是**原生平台唯一可行**的路径
//    （`XFile.fromData` 在 iOS/Android 没有真实路径，会失败）。
//
// # 🔴 `ByteData` 的 import（一次真机编译才暴露的错）
// `Image.toByteData()` 返回 `Future<ByteData?>`，而 **`ByteData` 来自 `dart:typed_data`**，
// 不在 `dart:ui` —— 写成 `ui.ByteData` 会报 **`'ByteData' isn't a type`**。
// （本机跑不了 flutter ⇒ 这类错只在真机构建时暴露。）
//
// # 🔴 与旧实现的关系（2026-10-06）
// 旧 `stats_card._share()` 是「**纯文字** + `?ref=<推荐码>` 链接」。本次改为：
// · **生成图片**（用上了此前 0 调用方的 `exportPngBytes`）
// · **移除 `?ref=`** —— 规格 §5.7.3 明说「不加二维码…不如只放品牌名，让用户主动搜索」，
//   带推广链接同样会被社交平台判为营销 ⇒ 与「只放品牌名」冲突
//
// 设计稿：`docs/design/share-card-2026-10-06.html`

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/share_card_data.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../utils/image_export.dart';
import 'share_card.dart';

/// 弹出分享图预览。
///
/// [data] 由调用方用 `ShareCardData.fromMetrics(...)` 构造（它会自动判定里程碑）。
Future<void> showShareCardPreview(
  BuildContext context, {
  required ShareCardData data,
}) {
  return showDialog<void>(
    context: context,
    // 对话框自身的背景由本组件自绘（要放固定尺寸的卡片，AlertDialog 的约束不好用）
    builder: (_) => _ShareCardPreview(data: data),
  );
}

class _ShareCardPreview extends StatefulWidget {
  final ShareCardData data;

  const _ShareCardPreview({required this.data});

  @override
  State<_ShareCardPreview> createState() => _ShareCardPreviewState();
}

class _ShareCardPreviewState extends State<_ShareCardPreview> {
  /// 截图锚点 —— 必须包在**固定尺寸**的卡片外（见文件头「两个关键点」）。
  final GlobalKey _cardKey = GlobalKey();

  /// 当前底色风格（规格要求深/浅双版本 ⇒ 让用户切）。
  ShareCardStyle _style = ShareCardStyle.solid;

  /// 正在导出（防连点）。
  bool _busy = false;

  /// 上一次失败原因（`null` = 无错）。
  String? _error;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final media = MediaQuery.of(context);
    // 缩放只影响显示；导出尺寸由 kShareCardPixelRatio 决定（恒定）
    final scale = shareCardPreviewScale(
      screenW: media.size.width,
      screenH: media.size.height,
    );

    return Dialog(
      backgroundColor: Color(t.card.argb32),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CoSpacing.lg, CoSpacing.lg, CoSpacing.lg, CoSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '分享学习记录',
              style: TextStyle(
                fontFamily: CoFonts.cjk,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.md),

            // ── 卡片预览（缩放显示 · 渲染尺寸恒定）──
            //
            // 🔴 这里必须用 `FittedBox` 而**不是** `Transform.scale`（2026-10-06 实测踩过）
            //
            // 原因：`Transform.scale` **不改变布局约束** —— 它把父给的
            // `tight(360*scale, 480*scale)` **原样传给 child** ⇒ 里面 `SizedBox(360,480)`
            // 会被**压成** `360*scale × 480*scale`（`RenderConstrainedBox` 会
            // `enforce(parentConstraints)`）⇒ 于是：
            //   · 卡片**渲染成小尺寸**（不是"渲染大再缩小"）
            //   · `RepaintBoundary.size` = `360*scale × 480*scale`
            //   · ⇒ `toImage(pixelRatio: 3)` **随屏幕变化**
            //      ← 正是本文件想防的那件事，而且**断言查不出**（这是运行时的约束行为）
            //
            // ✅ `FittedBox` 会给 child **无界约束** ⇒ child 按**自己的 360×480** 布局，
            //    再由 FittedBox 缩放到父约束 ⇒ `RepaintBoundary.size` **恒为 360×480**
            //    ⇒ 导出恒为 **1080×1440**。
            //    ⚠️ 前提：FittedBox 的**父约束必须有界**（这里是外层 `SizedBox` ✓）——
            //       无界时 FittedBox 会报错。
            // 📌 先例：`reading_tab_screen.dart:161` / `subscribe_screen.dart:376` 同用 `FittedBox`。
            Center(
              child: SizedBox(
                width: kShareCardWidth * scale,
                height: kShareCardHeight * scale,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: RepaintBoundary(
                    key: _cardKey,
                    child: ShareCard(
                      data: widget.data,
                      tokens: t,
                      style: _style,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: CoSpacing.md),

            // ── 底色切换（规格：深色/浅色双版本）──
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StyleChip(
                  tokens: t,
                  label: '实心',
                  selected: _style == ShareCardStyle.solid,
                  onTap: () => setState(() => _style = ShareCardStyle.solid),
                ),
                const SizedBox(width: CoSpacing.sm),
                _StyleChip(
                  tokens: t,
                  label: '素雅',
                  selected: _style == ShareCardStyle.paper,
                  onTap: () => setState(() => _style = ShareCardStyle.paper),
                ),
              ],
            ),

            // ── 失败出口（不静默）──
            if (_error != null) ...[
              const SizedBox(height: CoSpacing.sm),
              Text(
                '生成失败：$_error',
                style: TextStyle(
                  fontFamily: CoFonts.cjk,
                  fontSize: 11.5,
                  color: Color(t.accent.argb32),
                ),
              ),
            ],

            const SizedBox(height: CoSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: CoSpacing.sm),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 16),
                  label: Text(_busy ? '生成中…' : '分享'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 把预览中的卡片渲染成 PNG → 唤起系统分享面板。
  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // ① 从 RepaintBoundary 取图。
      //    ⚠️ `currentContext` 为 null 说明卡片已不在树上（用户在渲染中关了弹层）
      final ctx = _cardKey.currentContext;
      if (ctx == null) return;
      final boundary = ctx.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        setState(() => _error = '取不到渲染对象');
        return;
      }

      final ui.Image image =
          await boundary.toImage(pixelRatio: kShareCardPixelRatio);
      // ⚠️ `ByteData` 来自 **`dart:typed_data`**（不是 `dart:ui`）——
      //    `Image.toByteData()` 的签名是 `Future<ByteData?>`（**裸类型**）。
      //    🔴 2026-10-06 实测踩过：写成 `ui.ByteData` ⇒ **编译期报
      //    `'ByteData' isn't a type`**（本机跑不了 flutter，只在真机构建时暴露）
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose(); // 及时释放（图片内存不小）

      if (bytes == null) {
        setState(() => _error = '编码 PNG 失败');
        return;
      }

      // ② 落盘 + 系统分享（原生平台唯一可行路径）
      final err = await exportPngBytes(
        bytes.buffer.asUint8List(),
        fileName: shareFileName(DateTime.now()),
        // 🔴 文案里**不含 URL**（规格 §5.7.3）—— 有断言守
        shareText: shareText(widget.data),
      );

      if (!mounted) return;
      if (err != null) {
        setState(() => _error = err);
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 底色风格的小圆角 chip（选中态用 accent 描边 + 浅底）。
class _StyleChip extends StatelessWidget {
  final CoEvoTokens tokens;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StyleChip({
    required this.tokens,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Color(tokens.accent.argb32);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: selected ? accent : Color(tokens.line.argb32),
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? accent : Color(tokens.ink2.argb32),
          ),
        ),
      ),
    );
  }
}
