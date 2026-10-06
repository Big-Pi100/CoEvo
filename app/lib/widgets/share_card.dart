// CoEvo · **分享图**（学习记录）—— 3:4 竖版，供截图导出。
//
// # 🔴 它为什么是「一个独立的、不依赖页面布局的 widget」
// 分享图要**离屏渲染成 PNG**（`RepaintBoundary + toImage`）。若它嵌在页面里、
// 依赖外层 `Row`/`Expanded` 给的宽高，那截图尺寸就**取决于当时屏幕多大** ——
// 同一份数据在不同手机上导出的图**尺寸不同**。
// ⇒ 本 widget **自带固定尺寸**（[kShareCardWidth] × [kShareCardHeight]），
//    在任何设备上都渲染出同样比例的图。
//
// # 配色：跟随三档主题（**不新造色**）
// 全部取自 `coevo_tokens.dart`：
//
// | 档 | solid 底 / 字 | paper 底 / 字 / 数字 |
// |---|---|---|
// | 墨 | `accent #B4432C` / `accentInk 白` | `page #F1EDE4` / `ink #24211C` / `accent` |
// | 格 | `accent #B4432C` / `accentInk 白` | `page #EDEEF0` / `ink #0A0A0A` / `accent` |
// | 夜 | `accent #DB7E6B` / `accentInk #2A1405` | `page #0B0D12` / `ink #EDEBE6` / `accent` |
//
// 📌 判据：**分享图的颜色应当来自 token，而不是另写一套 hex** ——
//    否则改主题色时，分享图会**留在旧色**（而它恰好是对外触点里最该跟品牌一致的）。
//
// # 🔴 不加二维码、不放链接
// 规格 §5.7.3：「小红书/微信对图片中的二维码会判定为**站外引流**，限流甚至封号」
// ⇒ 图上**只有品牌名**。文案侧的对应约束见 `services/share_card_data.dart::shareText`（有断言守）。
//
// 设计稿：`docs/design/share-card-2026-10-06.html`

import 'package:flutter/material.dart';

import '../services/share_card_data.dart';
import '../theme/coevo_tokens.dart';

/// 分享图的**底色风格**。
///
/// 规格 §5.7.3 要求「**深色/浅色双版本**」⇒ 由调用方选，两种都要能出。
enum ShareCardStyle {
  /// 品牌色实心底（朱砂）—— **醒目**，社交平台上更容易被注意到（设计稿 ① / ③）。
  solid,

  /// 页面底 + 正文色 —— **素雅**，与 App 内观感一致（设计稿 ②）。
  paper,
}

/// 一张 3:4 的分享图。**自带固定尺寸**，可直接塞进 `RepaintBoundary` 截图。
class ShareCard extends StatelessWidget {
  /// 要展示的数据（只有用户自测的三个数字）。
  final ShareCardData data;

  /// 当前档 token（墨/格/夜）—— 由调用方从 `CoEvoTokensExt.of(context)` 取。
  final CoEvoTokens tokens;

  /// 底色风格。
  final ShareCardStyle style;

  const ShareCard({
    super.key,
    required this.data,
    required this.tokens,
    this.style = ShareCardStyle.solid,
  });

  /// 底色。
  Color get _bg => style == ShareCardStyle.solid
      ? Color(tokens.accent.argb32)
      : Color(tokens.page.argb32);

  /// 主文字色。
  Color get _fg => style == ShareCardStyle.solid
      ? Color(tokens.accentInk.argb32)
      : Color(tokens.ink.argb32);

  /// 强调（数字）色。
  ///
  /// · `solid` 底：数字与其它文字**同色**（整块已经是品牌色，再换色会花）
  /// · `paper` 底：数字用 `accent` —— 否则一片灰黑，看不出重点
  Color get _num => style == ShareCardStyle.solid
      ? Color(tokens.accentInk.argb32)
      : Color(tokens.accent.argb32);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kShareCardWidth,
      height: kShareCardHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(color: _bg),
        child: Padding(
          // 安全边距 30pt（导出 1080 宽时 = 90px）—— 社交平台会裁边，内容不贴边
          padding: const EdgeInsets.fromLTRB(30, 32, 30, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 顶部：品牌字（字距拉开，像 logo 位）──
              Text(
                kShareCardBrand.toUpperCase(),
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11,
                  letterSpacing: 2.4,
                  fontWeight: FontWeight.w600,
                  color: _fg.withValues(alpha: 0.62),
                ),
              ),

              // ── 中部：主视觉 + 副数据 ──
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: data.kind == ShareCardKind.milestone
                      ? _milestoneBody()
                      : _regularBody(),
                ),
              ),

              // ── 底部：品牌名 + 副标 ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    kShareCardBrand,
                    style: TextStyle(
                      fontFamily: CoFonts.latinSerif,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: _fg,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    kShareCardTagline,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: CoFonts.cjk,
                      fontSize: 10.5,
                      height: 1.45,
                      color: _fg.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 常规版：主视觉 = **连续天数**。
  List<Widget> _regularBody() => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${data.streakDays}',
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 76,
                height: 1,
                fontWeight: FontWeight.w600,
                letterSpacing: -1.5,
                color: _num,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '天',
              style: TextStyle(
                fontFamily: CoFonts.cjk,
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: _fg.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          '连续学习',
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 13,
            letterSpacing: 0.8,
            color: _fg.withValues(alpha: 0.80),
          ),
        ),
        const SizedBox(height: 26),
        Row(
          children: [
            _MiniStat(
              value: ShareCardData.group(data.matureCards),
              label: '已掌握词',
              num: _num,
              fg: _fg,
            ),
            const SizedBox(width: 26),
            _MiniStat(
              value: ShareCardData.group(data.articlesRead),
              label: '读完文章',
              num: _num,
              fg: _fg,
            ),
          ],
        ),
      ];

  /// 里程碑版：主视觉 = **达成的档位**（数字更大，且带一行小字点明价值）。
  List<Widget> _milestoneBody() => [
        Text(
          '里程碑达成',
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 12,
            letterSpacing: 1.6,
            color: _fg.withValues(alpha: 0.80),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${data.milestoneDay ?? data.streakDays}',
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 88,
                height: 1,
                fontWeight: FontWeight.w600,
                letterSpacing: -2,
                color: _num,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              '天',
              style: TextStyle(
                fontFamily: CoFonts.cjk,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: _fg.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        Text(
          '连续学习不间断',
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 14,
            color: _fg.withValues(alpha: 0.92),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '从第 1 天到今天\n一共读了 ${ShareCardData.group(data.articlesRead)} 篇文章',
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 12.5,
            height: 1.6,
            color: _fg.withValues(alpha: 0.75),
          ),
        ),
      ];
}

/// 副数据（小号数字 + 标签）。
class _MiniStat extends StatelessWidget {
  final String value;
  final String label;
  final Color num;
  final Color fg;

  const _MiniStat({
    required this.value,
    required this.label,
    required this.num,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: 24,
            height: 1.1,
            fontWeight: FontWeight.w600,
            color: num,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 11.5,
            color: fg.withValues(alpha: 0.70),
          ),
        ),
      ],
    );
  }
}
