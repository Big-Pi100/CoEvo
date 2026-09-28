import 'package:flutter/material.dart';

import '../services/pos_display.dart';
import '../services/word_query_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 划词查词浮层 —— **基础信息四要素：音标 / 词性 / 释义 / 例句**。
///
/// # 🔴 浮层 = 查词，不是学词（白哥 2026-09-27 定）
/// > 「浮层应该显示的是**基础信息**而不是**优化记忆**」
///
/// | | **划词浮层（本组件）** | **复习卡片**（3.7） |
/// |---|---|---|
/// | 场景 | 我在读文章，这个词什么意思？ | 我要记住这个词 |
/// | 内容 | **音标 / 词性 / 释义 / 例句** | ① 记忆法 ② 释义 ③ 语境 |
/// | 诉求 | **快**（不打断阅读） | **记住**（一页记忆方案） |
/// | 用 `mnemonic_type.priority`？ | ❌ **不用** | ✅ 用 |
///
/// ⚠️ 这修正了 `visual-word-card-target` §07（它把浮层画成「词卡的紧凑版」，
/// 含「① 记忆法」）—— 该节已加修正标注。v1（L0）§九对「显示什么」**未作规定**，
/// 故本修正**不违反 L0**。
///
/// # 🔴 零粘土（spec §八：「阅读区容器内不得出现粘土类」）
/// 浮层是**阅读场景的一部分** —— 用 `card` 底 + 轻阴影表达层级，
/// 不用粘土（粘土是「交互」语汇：卡片、按钮、tabbar）。
///
/// # 字号依据
/// | 元素 | 值 | 依据 |
/// |---|---|---|
/// | 单词 | **21** | 🔑 **L1 §07 浮层的 inline 值**（`font-size:21px`）—— 比 `compact.word`（28.8）小得多，因为浮层宽度受限。与 `_ClayTabBar` 圆角 17 同做法：**照设计稿、硬编码、注释说明** |
/// | 释义 | `compact.defText`（14.85） | spec §5.2「浮层整体 ×0.9」（L1 的 inline 是 15 ✅ 几乎相同） |
/// | 英文释义 | `compact.defEn`（11.7） | 同上 |
/// | 例句 | `compact.ctxText`（13.05） | 同上 |
/// | 音标 | `compact.ipa`（13.5） | spec §5.2「×0.9」｜⚠️ L1 浮层未缩（用 15）→ **1.5px 偏差**，真机目视后可调 |
/// | 词性标签 | `label`（11，**不缩**） | spec §5.2 的 `compact` 明确只对字号缩、label 保持 |
class LookupSheet extends StatelessWidget {
  const LookupSheet({super.key, required this.result});

  final WordLookupResult result;

  /// L1 §07 浮层的单词字号（见类文档的「字号依据」）。
  static const double _wordSize = 21;

  /// 弹出浮层。
  ///
  /// 🔑 **`barrierColor` 用轻遮罩（12% 黑）而不是默认的 54%** ——
  /// 默认遮罩会把正文压得很暗，像「跳到了另一个界面」；
  /// 而这一步的意图是**不打断阅读**（v1：浮层 → 聚合页 → 回到浮层）。
  static Future<void> show(BuildContext context, WordLookupResult result) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x1F000000),
      builder: (_) => LookupSheet(result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final card = result.card;
    final typo = t.type;
    final compact = typo.compact;

    final defi = card.sectionOfType('definition');
    final ctx = card.sectionOfType('context');

    final pos = normalizePos(defi?.pos);
    final zh = defi?.zh?.trim() ?? '';
    final en = defi?.en?.trim() ?? '';
    final example = ctx?.text?.trim() ?? '';
    final ipa = card.ipa?.trim() ?? '';

    return Container(
      decoration: BoxDecoration(
        color: Color(t.card.argb32),
        // 只圆上面两角（bottom sheet 的惯例）
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.clay.radius)),
      ),
      // 底部避让 Home Indicator
      padding: EdgeInsets.fromLTRB(
        22, 18, 22, 24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── ① 词 + 音标 ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  card.spelling,
                  style: TextStyle(
                    fontFamily: CoFonts.latinSerif,
                    fontSize: _wordSize,
                    fontWeight: FontWeight.w500,
                    color: Color(t.ink.argb32),
                  ),
                ),
              ),
              if (ipa.isNotEmpty) ...[
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    ipa,
                    style: TextStyle(
                      // 🔴 **元素级指定 CharisSIL** —— 音标必须整条同字体
                      //    （挂 fallback 链会让 93.9% 的音标「一条音标两种字体」，见 spec §4.1.1）
                      fontFamily: CoFonts.ipaSerif,
                      fontSize: compact.ipa,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                ),
              ],
            ],
          ),

          // ── ② 词性（`normalizePos` 把 47 种写法归一到词典惯例缩写）──
          if (pos.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              pos,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: typo.label,
                letterSpacing: typo.label * 0.05,
                color: Color(t.ink3.argb32),
              ),
            ),
          ],

          // ── ③ 释义 ──
          if (zh.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              zh,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: compact.defText,
                fontWeight: FontWeight.w500,
                height: 1.45,
                color: Color(t.ink.argb32),
              ),
            ),
          ],
          if (en.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              en,
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: compact.defEn,
                height: 1.5,
                color: Color(t.ink2.argb32),
              ),
            ),
          ],

          // ── ④ 例句 ──
          // ⚠️ 32 个词（0.3%）无例句 → 整段省略，**不留空行**
          //    （空行会让用户以为「加载失败」而不是「这个词没有例句」）
          if (example.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.only(left: 11),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(t.line.argb32), width: 2),
                ),
              ),
              child: Text(
                example,
                style: TextStyle(
                  fontFamily: CoFonts.latinSerif,
                  fontSize: compact.ctxText,
                  height: 1.55,
                  color: Color(t.ink2.argb32),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
