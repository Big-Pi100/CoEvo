import 'package:flutter/material.dart';

import '../models/feed_item.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../theme/clay.dart';
import 'bookmark_button.dart';
/// 信息流卡片 —— **信息流与收藏清单共用的同一套组件**。
///
/// 设计稿 §03 ②：「不做新的列表样式。**同一套卡片组件，只是数据源筛选过**」
/// → 所以本组件**不认识数据源、也不认识收藏逻辑**：
/// 「是否已收藏」与「点击做什么」都由父层注入（见 [bookmarked] / [onToggleBookmark]）。
/// 这样 3.5 的收藏清单可以直接复用，一行都不用改。
///
/// # 卡片上只有四个元素（设计稿原文）
/// `分类·时长 / 标题 / 摘要 / 收藏`
///
/// 🔴 刻意**没有**「N 个生词」和「已读 / 未读」—— 两者都已在设计稿里作废。
///
/// # 字号与字体（数值逐项取自设计稿 CSS，不自行调整）
/// | 元素 | CSS 选择器 | 值 |
/// |---|---|---|
/// | 分类·时长 | `.fc .cat` | 10.5 / w600 / 字距 .07em / 大写 / `accent` |
/// | 标题 | `.fc h3` | Literata 19 / w500 / 行高 1.31 / 字距 -.011em / `ink` |
/// | 摘要 | `.fc .ex` | Literata 13.5 / 行高 1.7 / 最多 3 行 / `ink2` |
/// | 内边距 | `.fc` | 19 / 18 / 17 / 18 |
/// | 内间距 | `.fc-top` margin-bottom | 11 |
///
/// ⚠️ 设计稿的 `--round`（Quicksand）项目**未打包**，元信息行改用 `CoFonts.uiSans`。
/// 这是有意的取舍：为一行 10.5px 的标签再引一个字体文件不划算（+~100 KB）。
class FeedCard extends StatelessWidget {
  const FeedCard({
    super.key,
    required this.item,
    this.bookmarked = false,
    this.onToggleBookmark,
    this.onTap,
  });

  final FeedItem item;

  /// 是否已收藏。
  final bool bookmarked;

  /// 点击书签时调用。
  ///
  /// 🔴 **`null` = 书签不可点**（`bookmarkProvider` 未就绪 / 打开失败时由父层传 `null`）。
  /// 这与「传一个有逻辑的回调」语义不同：前者让按钮**视觉上就禁用**，
  /// 用户不会点到一个没反应的按钮（3.22 的教训：别让用户面对静默无效的操作）。
  final VoidCallback? onToggleBookmark;

  /// 点击卡片 → 打开阅读界面（**3.4** 接入）。传 `null` 时不可点（也不带按下动效）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Clay(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(18, 19, 18, 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 元信息行：分类·时长（左） + 书签（右）──
          // 设计稿 `.fc-top{display:flex;align-items:center;justify-content:space-between;gap:12px}`
          Row(
            children: [
              Expanded(
                child: Text(
                  // 设计稿 `text-transform: uppercase`
                  item.meta.toUpperCase(),
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 10.5 * 0.07,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 🔑 书签放在**右上角**：设计稿的理由是「拇指可达」
              BookmarkButton(
                bookmarked: bookmarked,
                onPressed: onToggleBookmark,
              ),
            ],
          ),
          const SizedBox(height: 11),
          Text(
            item.title,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 19,
              fontWeight: FontWeight.w500,
              height: 1.31,
              letterSpacing: 19 * -0.011,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            item.excerpt,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 13.5,
              height: 1.7,
              color: Color(t.ink2.argb32),
            ),
          ),
        ],
      ),
    );
  }
}
