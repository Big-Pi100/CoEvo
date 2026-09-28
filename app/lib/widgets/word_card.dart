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

import '../services/word_query_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class WordCardView extends StatelessWidget {
  const WordCardView({
    super.key,
    required this.card,
    required this.profile,
    required this.mnemonicNames,
    this.onSpeak,
    this.onOpenAggregate,
    this.scrollController,
    this.footer,
  });

  final WordCard card;

  /// 槽位分配（`null` = 该词无 profile，罕见 → ① ② 都不渲染，只剩释义 + 语境）
  final WordMnemonicProfile? profile;

  /// `mnemonic_type.code → 显示名`（从库读，见 `WordQueryService.mnemonicTypeNames`）
  final Map<String, String> mnemonicNames;

  /// 朗读单词（点音标旁的喇叭）。
  ///
  /// 🔑 **设计稿里就有它**：`visual-word-card-target` 的词头结构是
  /// `w-word` / `w-meta`(`w-ipa` + **`spk`**)——`spk` 是一个内联 SVG 喇叭。
  /// ⚠️ 我 2026-09-28 上一轮误判为「设计稿卡片上无喇叭」并据此没做，已纠正。
  ///
  /// 传 `null` = 不显示喇叭（如未来某处复用本组件但不提供朗读）。
  /// ⚠️ 考核态**不传**（喇叭会念出答案）。
  final VoidCallback? onSpeak;

  /// 点 ① / ② 展开**聚合页**（词根族 / 词源族）。
  ///
  /// 🔑 白哥原话（`mnemonic-layer-separation-2026-09-26.md` §188）：
  /// > 「同源串记是个聚合页面**不应该直接显示在卡片上**，卡片上应该显示的是
  /// >   『**词源故事**』而**点击词源故事展开同源串记聚合页**；**词根词缀也是一样**。」
  ///
  /// 即：**族成员列表不进卡片，而是点开看** —— 卡片只留「这一段讲了什么」
  /// + 一个带族规模的入口。
  ///
  /// ⚠️ 与 `footer` / `onSpeak` 同一取舍：**组件不认识路由**，
  ///    由页面注入「点开哪一页」。这样卡片在考核态（不该有聚合入口）也能复用。
  /// ⚠️ 传 `null` = 不可点（也**不显示箭头** —— 见 `_mnemonicBlock`）。
  ///
  /// 第二个参数是该槽位的**显示名**（「词根词缀」/「词源故事」…）——
  /// 聚合页要用它写来处（「来自 intercept 的 ① 词根词缀」）。
  /// 🔑 由本组件提供而不是让页面自己查：显示名来自 `mnemonicNames`，
  ///    而那是本组件持有的（页面再查一次 = 两处定义）。
  final void Function(int pageId, String slotLabel)? onOpenAggregate;

  /// 内容区的滚动控制器（由页面持有 —— 换卡时要 `jumpTo(0)` 回顶部）。
  final ScrollController? scrollController;

  /// 底部**固定区**（不随内容滚动）—— 由页面注入。
  ///
  /// # 🔑 为什么是注入而不是内置（2026-09-28 改）
  /// 这一区**原先**硬编码为「FSRS 四键自评」。但白哥把评分方式改成了
  /// **拼写考核**（对/错由判定器给，不需要用户点四档）→ 底部该放什么
  /// **取决于页面的阶段**：
  /// · 考核前 → 没有底部区（操作在输入框那里）
  /// · 判定后 → 「下一个 →」
  /// · 浏览未到期的词 → 「下一个 →」
  ///
  /// → 组件**不该知道**底部是什么，只负责把它固定在底部。
  ///   （同 `FeedCard` 不认识收藏逻辑的做法：「是否已收藏 / 点击做什么」由父层注入。）
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Column(
      children: [
        // 内容区可滚（词源链可能很长），底部操作区**固定**（不随内容滚）
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _head(t),
                // 🔑 锚点 `.def{margin-top:15px}`（原 18）—— 词头 → 释义段
                const SizedBox(height: 15),
                // 🔴 顺序（白哥 2026-09-28 定）：**释义 + 语境原句在上，记忆法在下**。
                //
                // 与设计稿原稿（①② 记忆法在上、③④ 在下）**相反** ——
                // 这是白哥明确要求的调整，理由是：
                // · 释义是**答案**、是用户查这个词的目的 → 先看到
                // · 记忆法（词根/词源）是**线索**，服务于理解释义
                // 🔑 顺序变了，但「线索不压过答案」的**字号铁律不变**
                //    （`defText` 16.5 > `mnemMain` 15.5）——
                //    两者是**独立的两条规则**，不要因为顺序变了就顺手反转字号。
                ..._answerSlots(t),
                ..._mnemonicSlots(t),
              ],
            ),
          ),
        ),
        // 底部固定区（由页面注入；见 `footer` 的说明）
        if (footer != null) footer!,
      ],
    );
  }

  // ── 词头：单词 + 音标 + 喇叭 ───────────────────────────────
  //
  // 🔴 词头下的**分隔线**（2026-09-28 排版整理）——
  //    锚点 `.w-head{padding-bottom:15px; border-bottom:1px solid var(--line)}`。
  //
  // 🔑 它是「让词头成为头」的关键：没有它，词头就是「下面第一段的一个大字号行」，
  //    与内容黏在一起（这正是白哥说的「乱」的来源之一）。
  //    ⚠️ 白哥在 Q1 选了**保持左对齐**（不居中）→ 分隔线**保留** ——
  //       两者是独立的：居中与否是排布，分隔线是分层。
  Widget _head(CoEvoTokens t) {
    final ipa = (card.ipa ?? '').trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 15),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(t.line.argb32), width: 1),
        ),
      ),
      child: Column(
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
      ),
    );
  }

  // ── ① ② 记忆法（线索）────────────────────────────────────
  //
  // 🔴 2026-09-28 改：槽位不再直接读 `profile.primaryCode` / `secondaryCode`，
  //    改为走 `CardSlots.resolve` —— 因为它排除 `context`（= ④ 固定段，
  //    否则**重复显示**）与 `cognate`（= 聚合页，只有族标签）。
  //    详见 `CardSlots` 的文档。
  //
  // ⚠️ 用 `if (s != null)` 收集 → 段取不到就**不留空段**（设计稿 §03）。
  List<Widget> _mnemonicSlots(CoEvoTokens t) {
    final slots = CardSlots.resolve(card: card, profile: profile);
    if (slots.isEmpty) return const [];

    final out = <Widget>[];
    // 🔑 记忆法组与上方（答案区）之间 —— **类别切换**，比段间更大（20 vs 14/15）。
    //
    // 白哥 2026-09-28 把顺序改成「答案解析在上、记忆法在下」之后，
    // 这里成了一次**类别切换**（不是同类段落的继续）→ 间距要能读出来。
    // ⚠️ 锚点的 `.mnem{margin-top:14px}` 是「记忆法在上、答案在下」时的值
    //    （那时 14 是段间，且下方还有 .def 的 15）→ 顺序换了，这个值要重新定。
    out.add(const SizedBox(height: 20));
    for (var i = 0; i < slots.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 14)); // 锚点 `.mnem{margin-top:14px}`
      out.add(_mnemonicBlock(t, slot: slots[i]));
    }
    // ⚠️ 末尾留白 18 **保持原值** —— 它不在本次诊断的 4 条内（未与白哥讨论过），
    //    不擅自改。⚠️ 但要如实记一笔：卡片 padding 是 `22,4,22,18`，
    //    再加这 18 → **下边距 36 vs 上边距 4**，上下呼吸不对称（锚点是均匀 20）。
    //    → 待白哥看真机后定（见报告「未做」）。
    out.add(const SizedBox(height: 18));
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
      // 锚点 `.ctx{margin-top:14px}`（原 18）
      if (out.isNotEmpty) out.add(const SizedBox(height: 14));
      out.add(_block(
        t,
        label: '语境原句',
        accentLabel: false,
        // 🔴 色条改用 `accentBright`（2026-09-28 白哥定 Q4）。
        //    原用 `line`（#EFE9DE）在浅纸上**几乎看不见** —— 等于白设了这条竖线。
        //    ⚠️ 与 ①② 的色条靠五处差异区分（粗细 2 vs 3 · 色相亮 vs 深 ·
        //       左内边距 12 vs 14 · 标签色 ink3 vs accent · 有没有 `›`）。
        leftBar: Color(t.accentBright.argb32),
        leftBarWidth: 2,
        leftBarInset: 12,
        child: Text(
          ctxText,
          style: TextStyle(
            fontFamily: CoFonts.latinSerif,
            fontSize: t.type.ctxText,
            height: 1.55,
            color: Color(t.ink2.argb32),
          ),
        ),
      ));
    }

    return out;
  }

  // ── 渲染：记忆法块（①②）────────────────────────────────
  //
  // 权重靠**强调色标签 + 凹陷底**建立，不靠字号（字号 ≤ 释义）。
  Widget _mnemonicBlock(CoEvoTokens t, {required CardSlot slot}) {
    final e = slot.entry;
    final label = mnemonicNames[slot.code] ?? slot.code;
    final trailing = e == null
        ? null
        // 设计稿：「入口标出族规模（『词根族 22 词』）」
        : (e.memberCount > 0 ? '${e.title} · ${e.memberCount} 词' : e.title);

    // 🔴 **有族页才可点、才给箭头**（`onOpenAggregate` 未注入时同样不可点）。
    //
    // 🔑 判据：「显示箭头却点不动」= **静默无效**（本项目已定为禁忌）。
    //    所以箭头由 `onTap` 是否存在**推导**，而不是单独一个 bool ——
    //    两者分开写迟早会出现「有箭头没回调」。
    final onTap = (e == null || onOpenAggregate == null)
        ? null
        : () => onOpenAggregate!(e.pageId, label);

    return _block(
      t,
      label: label,
      accentLabel: true,
      trailing: trailing,
      onTap: onTap,
      // 🔴 ①② 左侧色条（2026-09-28 白哥定：**用色条，不用凹陷底块**）。
      //    ⚠️ 规格冲突已记录：spec §5.2 原写「①② 独占 sunken，全卡唯一有底色」
      //       → 改色条后卡片上**没有任何段有底色**，那条描述已失效，需同步改 spec。
      leftBar: Color(t.accent.argb32),
      leftBarWidth: 3,
      leftBarInset: 14,
      child: _sectionBody(t, slot.section),
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
  ///
  /// # 🆕 段落色条（2026-09-28 排版整理）
  /// [leftBar] 非空时，给**整节**（标签行 + 内容）加一条左侧竖线 ——
  /// 这是「建立层级」的手段之一：**不靠排得松一点，靠容器与分隔**。
  ///
  /// 🔑 为什么色条包**整节**（而不是只包内容）：
  /// · 语义上「这一节是记忆法 / 这一节是引文」—— 节 = 标签 + 内容
  /// · 代码上**只有一处实现**（若 ①② 包整节、④ 只包内容，就是两套逻辑要各自维护）
  ///
  /// ⚠️ ①②（`accent` 3px）与 ④（`accentBright` 2px）**都是色条** ——
  ///    形态会撞，靠**五处差异**分开：粗细 / 色相 / 左内边距 / 标签色 / 有没有 `›`。
  ///    详见 `docs/design/word-card-layout-refine-2026-09-28.html` §3.5。
  Widget _block(
    CoEvoTokens t, {
    required String label,
    required bool accentLabel,
    required Widget child,
    String? trailing,
    VoidCallback? onTap,
    Color? leftBar,
    double leftBarWidth = 3,
    double leftBarInset = 14,
  }) {
    // ⚠️ 必须显式声明 `Widget`（不能用 `var`）—— 否则类型被推断为 `Column`，
    //    下面赋 `Container`（加色条时）会报
    //    `A value of type 'Container' can't be assigned to a variable of type 'Column'`。
    //    🔑 这类错误 `dart format` 抓不到（纯语法），只有语义分析能发现
    //       → 由 `scripts/static_check` 捕获（2026-09-28 首次实战）。
    Widget content = Column(
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
            // 🔴 箭头**由 `onTap` 推导** —— 见 `_mnemonicBlock` 的说明：
            //    「显示箭头却点不动」= 静默无效，所以两者绝不能各写各的。
            if (onTap != null)
              Text(
                '›',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: t.type.label + 2,
                  height: 1,
                  color: Color(t.ink3.argb32),
                ),
              ),
          ],
        ),
        // 🔑 4px（锚点 `.lab{margin-bottom:4px}`）—— 原为 8px。
        //    「标签下距」这一档要**明显小于**段内其他间距（8），
        //    否则标签读起来像独立一段，而不是「它下面那段的名字」。
        const SizedBox(height: 4),
        child,
      ],
    );

    if (leftBar != null) {
      content = Container(
        padding: EdgeInsets.only(left: leftBarInset),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: leftBar, width: leftBarWidth),
          ),
        ),
        child: content,
      );
    }

    if (onTap == null) return content;

    // 整块可点（大点击目标 —— 段内还有文字，只有标题行可点会很难点中）
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 考核提示（拼写考核的「题面」）
// ════════════════════════════════════════════════════════════════

/// 考核提示 —— **只给足以回忆的线索，绝不给答案**。
///
/// # 🔴 与 [WordCardView] 的关键差别：这个组件**必须不能泄露答案**
/// 白哥 2026-09-28 定：「**看释义拼词**」。
/// 于是考核时**只说释义**（+ 音标作辅助），以下三样**一律不显示**：
///
/// | 不能显示 | 为什么 |
/// |---|---|
/// | **单词本身** | 它就是答案 |
/// | **① ② 记忆法** | 词根词缀/词源故事**就是为记这个词服务的** → 给了等于给答案（`dis-` + `organ` + `-ized` 等于把拼写拆给你看） |
/// | **④ 语境原句** | 🔴 **最隐蔽的一处**：语境句里**通常含这个词本身**（"The office was completely **disorganized** after the move."）→ 等于把答案印在题面上 |
///
/// 🔑 这三条各有断言守着（§17「考核态不得泄露答案」）——
///    因为**多加一段内容在代码上毫无阻力**，而泄露答案会让整个考核失效，
///    且**看不出来**（用户会「答对」，但那不代表他记得）。
///
/// # 🔴 也不提供朗读
/// 喇叭会**把单词念出来** = 直接给答案。
/// （`WordCardView` 的喇叭在**判定之后**才出现 —— 那时已经答完了。）
class WordPromptView extends StatelessWidget {
  const WordPromptView({
    super.key,
    required this.card,
    this.scrollController,
  });

  final WordCard card;

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final defs = card.sectionsOfType('definition');
    final ipa = (card.ipa ?? '').trim();

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '看释义，拼出这个单词',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: t.type.label,
              letterSpacing: t.type.label * 0.06,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: 16),

          // ── 释义（主线索）──
          if (defs.isEmpty)
            Text(
              // 无释义段（罕见）→ 不能空着，否则用户无从下手
              '（这个词没有释义数据，直接凭记忆拼）',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: t.type.defText,
                color: Color(t.ink3.argb32),
              ),
            )
          else
            for (var i = 0; i < defs.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _promptDefinition(t, defs[i]),
            ],

          // ── 音标（辅助线索）──
          if (ipa.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              ipa,
              style: TextStyle(
                fontFamily: CoFonts.ipaSerif,
                fontSize: t.type.ipa,
                color: Color(t.ink2.argb32),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _promptDefinition(CoEvoTokens t, WordSection s) {
    final zh = (s.zh ?? '').trim();
    final pos = (s.pos ?? '').trim();
    return Row(
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
                // 释义是题面主体 → 用内容层最大字号（与卡片上的释义同级）
                fontSize: t.type.defText,
                fontWeight: FontWeight.w500,
                height: 1.45,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
      ],
    );
  }
}
