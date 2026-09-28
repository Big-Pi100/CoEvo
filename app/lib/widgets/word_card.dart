/// 复习词卡 —— **四段结构 + 四键自评**（复习页的翻卡态）。
///
/// # 🔴 界面锚点（L1 · 逐条对应）
/// `docs/design/visual-word-card-target-2026-09-26.html`
///
/// ```
/// ① 词根词缀 · ② 词源故事 · ③ 释义 · ④ 语境原句
/// ```
/// > 「卡片只显示四样……同源串记与词根族是聚合页，**不铺在卡上**」
///
/// ## 槽位不在这里算 —— 读 `word_mnemonic_profile` 的**已有结果**
/// `①` = `profile.primaryCode`、`②` = `profile.secondaryCode`，
/// 段内容从 `WordCard.sections` 里按 code 取。
///
/// 🔑 **为什么不按 `mnemonic_type.priority` 自己排**：那是**制卡时**的配置，
///    而每个词的分配**早已算好并存进库**（11,523 行全有），
///    且带抑制规则（设计稿 §06「② 对可拆词 78.3% 与 ① 重复」→ 那些词的 ② 刻意留空）。
///    运行时重排 = 把算好的结果再猜一遍，还会与制卡结果不一致。
///    详见 `WordQueryService.profileOf` 的文档。
///
/// ## ⚠️ 三种「取不到就不渲染」的降级（都是数据现状，不是 bug）
/// | 情况 | 例子（实测） | 处理 |
/// |---|---|---|
/// | ② 被指定为 `context` | `laser` | `context` 是 ④ 的位置 → **过滤掉，不显示 ②** |
/// | ① 指向的段不存在 | `traffic jam`（①= `image`，image 无数据源） | **不留空段**，直接渲染 ③④ |
/// | ② 指向的段不存在 | `courage`（②= `cognate`，但无该段） | 同上 |
///
/// > 「① 无内容 → ③④ 直接渲染，**不留空段**」（设计稿 §03）
///
/// ## 🔴 字号铁律：**线索不压过答案**
/// 记忆法（①②）是**线索**，释义（③）是**答案** → 释义字号**最大**
/// （`defText` 16.5 > `mnemMain` 15.5）。权重靠**强调色 + 凹陷底色 + 拆分结构**，
/// **不靠字号**（见 `design-system-spec` 的字号层级）。
library;

import 'package:flutter/material.dart';

import '../services/fsrs_service.dart';
import '../services/word_query_service.dart';
import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class WordCardView extends StatelessWidget {
  const WordCardView({
    super.key,
    required this.card,
    required this.profile,
    required this.previews,
    required this.mnemonicNames,
    required this.onRate,
    this.onSpeak,
    this.scrollController,
    this.ratingEnabled = true,
  });

  final WordCard card;

  /// 槽位分配（`null` = 该词无 profile，罕见 → ① ② 都不渲染，只剩释义 + 语境）
  final WordMnemonicProfile? profile;

  /// 四档预览的**间隔**（`FsrsService.previewAll` 的产出）—— 按钮上的「下次 X 天」。
  final Map<ReviewRating, Duration> previews;

  /// `mnemonic_type.code → 显示名`（从库读，见 `WordQueryService.mnemonicTypeNames`）
  final Map<String, String> mnemonicNames;

  final ValueChanged<ReviewRating> onRate;

  /// 朗读单词（点音标旁的喇叭）。
  ///
  /// 🔑 **设计稿里就有它**：`visual-word-card-target` 的词头结构是
  /// `w-word` / `w-meta`(`w-ipa` + **`spk`**)——`spk` 是一个内联 SVG 喇叭。
  /// ⚠️ 我 2026-09-28 上一轮误判为「设计稿卡片上无喇叭」并据此没做，已纠正。
  ///
  /// 传 `null` = 不显示喇叭（如未来某处复用本组件但不提供朗读）。
  final VoidCallback? onSpeak;

  /// 内容区的滚动控制器（由页面持有 —— 换卡时要 `jumpTo(0)` 回顶部）。
  final ScrollController? scrollController;

  /// 提交中 → 四键禁用（防连点造成重复写库）
  final bool ratingEnabled;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Column(
      children: [
        // 内容区可滚（词源链可能很长），四键固定在底部（见类文档）
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _head(t),
                const SizedBox(height: 18),
                ..._mnemonicSlots(t),
                ..._answerSlots(t),
              ],
            ),
          ),
        ),
        _ratingBar(t),
      ],
    );
  }

  // ── 词头：单词 + 音标 + 喇叭 ───────────────────────────────
  Widget _head(CoEvoTokens t) {
    final ipa = (card.ipa ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          card.spelling,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.word, // 32
            fontWeight: FontWeight.w500,
            height: 1.15,
            color: Color(t.ink.argb32),
          ),
        ),
        if (ipa.isNotEmpty || onSpeak != null) ...[
          const SizedBox(height: 7),
          Row(
            children: [
              if (ipa.isNotEmpty)
                Flexible(
                  child: Text(
                    ipa,
                    style: TextStyle(
                      // 🔴 音标整条用 CharisSIL（元素级指定，不挂 fallback —
                      //    挂链会让一条音标出现两种字体，见 spec §4.1.1）
                      fontFamily: CoFonts.ipaSerif,
                      fontSize: t.type.ipa,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                ),
              if (onSpeak != null) ...[
                const SizedBox(width: 10),
                // 喇叭 —— 设计稿 `spk`（紧跟音标）。可点元素用 ink2（对比度）
                GestureDetector(
                  onTap: onSpeak,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.volume_up_outlined,
                      size: 18,
                      color: Color(t.accent.argb32),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  // ── ① ② 记忆法（线索）────────────────────────────────────
  //
  // ⚠️ 用 `if (s != null)` 收集 → 段取不到就**不留空段**（设计稿 §03）。
  List<Widget> _mnemonicSlots(CoEvoTokens t) {
    final p = profile;
    if (p == null) return const [];

    final out = <Widget>[];
    final first = _sectionOf(p.primaryCode);
    if (first != null) {
      out.add(_mnemonicBlock(
        t,
        code: p.primaryCode,
        section: first,
        // 「词根族 15 词」这类入口 —— ⚠️ 本次**不带 `›`**：
        // 聚合页（点击展开）属 Step 3.7，尚未实现。
        // 🔑 显示 `›` 而点不动 = 「看起来能点」的静默无效（本项目已定为禁忌）。
        entry: _entryOf(first),
      ));
    }

    final secondCode = p.secondaryCode;
    final second = secondCode == null ? null : _sectionOf(secondCode);
    if (second != null) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 16));
      out.add(_mnemonicBlock(
        t,
        code: secondCode!,
        section: second,
        entry: _entryOf(second),
      ));
    }

    if (out.isNotEmpty) out.add(const SizedBox(height: 18));
    return out;
  }

  // ── ③ 释义 · ④ 语境（辅证）──────────────────────────────
  List<Widget> _answerSlots(CoEvoTokens t) {
    final out = <Widget>[];

    final defs = card.sectionsOfType('definition');
    if (defs.isNotEmpty) {
      out.add(_block(
        t,
        label: '释义',
        accentLabel: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < defs.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _definition(t, defs[i]),
            ],
          ],
        ),
      ));
    }

    final ctx = card.sectionOfType('context');
    final ctxText = (ctx?.text ?? '').trim();
    if (ctxText.isNotEmpty) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 18));
      out.add(_block(
        t,
        label: '语境原句',
        accentLabel: false,
        child: Container(
          padding: const EdgeInsets.only(left: 11),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Color(t.line.argb32), width: 2),
            ),
          ),
          child: Text(
            ctxText,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: t.type.ctxText,
              height: 1.55,
              color: Color(t.ink2.argb32),
            ),
          ),
        ),
      ));
    }

    return out;
  }

  // ── 渲染：记忆法块（①②）────────────────────────────────
  //
  // 权重靠**强调色标签 + 凹陷底**建立，不靠字号（字号 ≤ 释义）。
  Widget _mnemonicBlock(
    CoEvoTokens t, {
    required String code,
    required WordSection section,
    String? entry,
  }) {
    return _block(
      t,
      label: mnemonicNames[code] ?? code,
      accentLabel: true,
      trailing: entry,
      child: _sectionBody(t, section),
    );
  }

  /// 段内容（按类型分派）。
  ///
  /// ⚠️ 每种形状不同（`root` 用 `parts`、`etymology` 用 `text`、
  /// `collocation` 用 `items`、`cognate` 只有族标签）→ 由 `WordSection` 的访问器取。
  Widget _sectionBody(CoEvoTokens t, WordSection s) {
    switch (s.type) {
      case 'root':
        final parts = s.parts;
        if (parts.isEmpty) return const SizedBox.shrink();
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('+',
                      style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: t.type.mnemMain,
                          color: Color(t.ink3.argb32))),
                ),
              _morphPart(t, parts[i]),
            ],
          ],
        );

      case 'etymology':
        return Text(
          (s.text ?? '').trim(),
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.mnemMain,
            height: t.type.sentenceLineHeight,
            color: Color(t.ink.argb32),
          ),
        );

      case 'cognate':
        // ⚠️ `cognate` 段**没有故事文本**（只有族标签）——
        //    同源族的成员与分拆法在**聚合页**（设计稿：「不铺在卡上」）。
        //    所以这里只陈述「它属于哪个词群」，不硬凑文本。
        final label = (s.cognateLabel ?? '').trim();
        return Text(
          label.isEmpty ? '这个词有同源词群' : label,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.mnemMain,
            height: 1.5,
            color: Color(t.ink.argb32),
          ),
        );

      case 'collocation':
        final items = s.collocations;
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 7),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      items[i].phrase,
                      style: TextStyle(
                        fontFamily: CoFonts.latinSerif,
                        fontSize: t.type.mnemMain,
                        color: Color(t.ink.argb32),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      items[i].zh,
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: t.type.mnemNote,
                        color: Color(t.ink2.argb32),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );

      default:
        // 未知类型（如未来的新 code）：显示原文而不静默吞掉
        final txt = (s.text ?? '').trim();
        return Text(
          txt,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.mnemMain,
            height: 1.5,
            color: Color(t.ink.argb32),
          ),
        );
    }
  }

  /// 词素块：`dis-`（弯曲体）+ `（不，相反）`（小字说明）
  Widget _morphPart(CoEvoTokens t, MorphPart p) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          p.surface,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.mnemMain,
            fontWeight: FontWeight.w600,
            color: Color(t.accent.argb32),
          ),
        ),
        if ((p.gloss ?? '').isNotEmpty)
          Text(
            '（${p.gloss}）',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: t.type.mnemNote,
              color: Color(t.ink2.argb32),
            ),
          ),
      ],
    );
  }

  Widget _definition(CoEvoTokens t, WordSection s) {
    final zh = (s.zh ?? '').trim();
    final en = (s.en ?? '').trim();
    final pos = (s.pos ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (pos.isNotEmpty) ...[
              Text(
                pos,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: t.type.label,
                  letterSpacing: t.type.label * 0.05,
                  color: Color(t.accent.argb32),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (zh.isNotEmpty)
              Flexible(
                child: Text(
                  zh,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    // 🔴 内容层**最大**字号 —— 答案是主角（字号铁律）
                    fontSize: t.type.defText,
                    fontWeight: FontWeight.w500,
                    height: 1.45,
                    color: Color(t.ink.argb32),
                  ),
                ),
              ),
          ],
        ),
        if (en.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            en,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: t.type.defEn,
              height: 1.5,
              color: Color(t.ink2.argb32),
            ),
          ),
        ],
      ],
    );
  }

  /// 段块 = 标签行（+ 可选右侧入口） + 内容。
  Widget _block(
    CoEvoTokens t, {
    required String label,
    required bool accentLabel,
    required Widget child,
    String? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: t.type.label, // 11
                fontWeight: FontWeight.w600,
                letterSpacing: t.type.label * 0.05,
                // 🔑 ①②（线索）用强调色；③④（辅证）用次要色 ——
                //    这就是「权重靠强调色，不靠字号」的落点。
                color: Color((accentLabel ? t.accent : t.ink3).argb32),
              ),
            ),
            if (trailing != null && trailing.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  trailing,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: t.type.label,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  /// 段的「聚合页入口」文字（如「organ 词根族（Greek）· 15 词」）。
  ///
  /// ⚠️ 本次**不带 `›`**、也不可点 —— 聚合页属 3.7（见 `_mnemonicSlots` 的说明）。
  String? _entryOf(WordSection s) {
    final e = s.entry;
    if (e == null) return null;
    final title = e.title.trim();
    if (title.isEmpty) return null;
    return e.memberCount > 0 ? '$title · ${e.memberCount} 词' : title;
  }

  WordSection? _sectionOf(String code) {
    if (code.isEmpty) return null;
    return card.sectionOfType(code);
  }

  // ── 四键自评 ──────────────────────────────────────────────
  //
  // 🔴 **每键各标「下次什么时候再见」**（设计稿原文）：
  //    「四个按钮各标出『下次什么时候再见』（数字来自端侧 FSRS 实时预览，
  //      不是写死的文案）—— 用户能看到选择的后果，而不是凭感觉点。」
  //
  // 数字由调用方用 `FsrsService.previewAll(state, now)` 算好传进来；
  // 本组件**不自己算**（它不该知道怎么调 FSRS）。
  Widget _ratingBar(CoEvoTokens t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Row(
        children: [
          for (final r in ReviewRating.values) ...[
            if (r != ReviewRating.values.first) const SizedBox(width: 7),
            Expanded(
              child: _RatingKey(
                rating: r,
                interval: previews[r],
                onTap: ratingEnabled ? () => onRate(r) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一个评分键：中文（大） / 英文（小） / **下次间隔**（数字来自 FSRS 预览）。
class _RatingKey extends StatelessWidget {
  const _RatingKey({
    required this.rating,
    required this.interval,
    required this.onTap,
  });

  final ReviewRating rating;

  /// `null` = 还没算出来（加载中）→ 不显示数字，但**键仍可见**
  final Duration? interval;

  /// `null` = 禁用（提交中）
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final disabled = onTap == null;

    return Opacity(
      // 🔴 禁用要**看得出来**（本项目教训：「不够显眼的禁用 → 用户仍读成坏了」）
      opacity: disabled ? 0.45 : 1,
      child: Clay(
        // 凹陷 —— 粘土的「可按下」形态（③④ 是辅证、四键是动作，形态要分开）
        state: ClayState.pressed,
        fill: t.sunken,
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              rating.label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              rating.code,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 9.5,
                color: Color(t.ink3.argb32),
              ),
            ),
            const SizedBox(height: 5),
            // 🔑 间隔是「选择之后会怎样」的信息 → 用强调色突出
            Text(
              interval == null ? '—' : formatInterval(interval!),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(t.accent.argb32),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
