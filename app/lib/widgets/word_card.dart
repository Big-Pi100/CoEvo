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
/// ## 🔴 朗读喇叭：**每张卡 3 类、最多 5 个**（2026-09-28 21:4x 接通）
/// 依据 **v1 §6.2（L0）**：`front`（单词）· `context`（英文例句）·
/// `collocation`（英文搭配）✅ 朗读；`definition`/`root`/`etymology` ❌（**含中文**）。
/// > 🔑 **原则：只朗读纯英文文本** —— 所以中文释义、词根词缀、词源故事**都不给喇叭**。
///
/// | 位置 | 尺寸 | 锚点依据 |
/// |---|---|---|
/// | 词头（跟在音标后） | 26 圆形凸起 | `.spk` |
/// | ④ 语境原句（跟在例句后） | 22 inline | `.ctx .spk` |
/// | 搭配**每条**词组后 | 22 inline | 同 `.ctx .spk`（锚点未画搭配，沿用同规格） |
///
/// 实现统一走 `widgets/speak_button.dart`（**全库唯一一处定义**）——
/// 5 处各写一份会「一处改了、另一处没改」而**编译器与断言都抓不到**。
///
/// ## 🔴 字号铁律：**线索不压过答案**
/// 记忆法（①②）是**线索**，释义（③）是**答案** → 释义字号**最大**
/// （`defText` 16.5 > `mnemMain` 15.5）。权重靠**强调色 + 凹陷底色 + 拆分结构**，
/// **不靠字号**（见 `design-system-spec` 的字号层级）。
library;

import 'package:flutter/material.dart';

import '../services/word_query_service.dart';
import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'speak_button.dart';

class WordCardView extends StatelessWidget {
  const WordCardView({
    super.key,
    required this.card,
    required this.profile,
    required this.mnemonicNames,
    this.onOpenAggregate,
    this.scrollController,
    this.footer,
  });

  final WordCard card;

  /// 槽位分配（`null` = 该词无 profile，罕见 → ① ② 都不渲染，只剩释义 + 语境）
  final WordMnemonicProfile? profile;

  /// `mnemonic_type.code → 显示名`（从库读，见 `WordQueryService.mnemonicTypeNames`）
  final Map<String, String> mnemonicNames;

  // 🔄 2026-09-28 21:4x：**删掉 `onSpeak` 参数**。
  //
  // 🔑 原因：朗读从「1 处（词头）」扩到「**5 处**」（词头 + ④ 语境 + 搭配 3 条
  //    + 浮层 2 处），且白哥定为**播放/停止切换** —— 那需要每个喇叭
  //    **知道「当前在播的是不是自己」**（否则 5 个喇叭会一起亮）。
  //    用「页面传 `VoidCallback`」做不到这点（回调不带状态），
  //    只有让 `SpeakButton` 自己 `watch` TTS 服务才行。
  // → 于是喇叭变成**自包含组件**（`widgets/speak_button.dart`，全库唯一一处定义），
  //    本组件不再需要外部注入。这也顺带满足「同一个东西实现里就该是一处」。
  //
  // ⚠️ 关于「考核态不能念出答案」：`WordPromptView` 本来就不含词头/语境，
  //    天然没有喇叭 —— 不需要再用「传不传参数」来控制。

  /// 点 ① / ② 展开**聚合页**（词根族 / 词源族）。
  ///
  /// 🔑 白哥原话（`mnemonic-layer-separation-2026-09-26.md` §188）：
  /// > 「同源串记是个聚合页面**不应该直接显示在卡片上**，卡片上应该显示的是
  /// >   『**词源故事**』而**点击词源故事展开同源串记聚合页**；**词根词缀也是一样**。」
  ///
  /// 即：**族成员列表不进卡片，而是点开看** —— 卡片只留「这一段讲了什么」
  /// + 一个带族规模的入口。
  ///
  /// ⚠️ 与 `footer` 同一取舍：**组件不认识路由**，
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

  // ── 锚点里**写死的两个几何量**（2026-09-28 · 方案 A）──────────────
  //
  // 🔑 为什么不走 token 档位：锚点里它们是写死的 px，不是主题变量 ——
  //    这与项目既有处理一致（`HeaderChip` 的 13 / `_ClayTabBar` 的 17 /
  //    `BookmarkButton` 的 10）：**设计稿写死 = 三档共用**。

  /// ①② 凹陷块圆角 —— 锚点 `.mnem{border-radius:16px}`。
  static final BorderRadius _mnemRadius = BorderRadius.circular(16);

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Column(
      children: [
        // 内容区可滚（词源链可能很长），底部操作区**固定**（不随内容滚）
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            // 🔴 卡片内边距 = 锚点 `.card{padding:20px 19px}`（2026-09-28 16:5x 回到方案 A）。
            //    ⚠️ 中途曾是 `22, 4, 22, 18`（上 4 下 18 + 末尾留白 18 → 实际下 36）——
            //       上下呼吸不对称，锚点是均匀的 20/19。
            padding: const EdgeInsets.fromLTRB(19, 20, 19, 20),
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
  //
  // 🔴 **居中**（2026-09-28 16:5x 白哥定「还是方案 A 比较好」→ 回到锚点原文）。
  //    ⚠️ 中途曾按 Q1 改成左对齐（当时的理由：长词居中会左右参差）—— **已撤回**：
  //       锚点 `.w-head{text-align:center}`、音标行 `.w-meta{justify-content:center}`。
  //       🔑 词头是这张卡的主题 → 居中才有「词条」的仪式感。
  //    📄 逐项差异见 `docs/design/word-card-layout-refine-2026-09-28.html` §3.6。
  //
  // 🔑 分隔线（分层）与居中（排布）是**两件独立的事** —— 中途只撤回居中、保留分隔线，
  //    也印证了这一点。
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
        // 锚点 `text-align:center`
        crossAxisAlignment: CrossAxisAlignment.center,
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
          // 🔑 `ipa` 实测 **100% 覆盖**（11,523/11,523，2026-09-28 查）→
          //    这一行恒存在，喇叭总是有位置。
          //    ⚠️ 若将来真出现无音标的词：该行不渲染，此时仍可从 ④ 语境 / 搭配朗读。
          if (ipa.isNotEmpty) ...[
            // 锚点 `.w-meta{margin-top:6px}`（原 7）
            const SizedBox(height: 6),
              Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
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
                // 🔴 喇叭（锚点 `.w-meta` 里的 `spk`）= **26×26 圆形凸起**。
                //    🔄 21:4x 起改用共用组件 `SpeakButton`（5 处喇叭**唯一**实现）——
                //       它自己知道「当前在播的是不是这段话」，并能切换播放/停止。
                //    🔑 **间距交给 `gapBefore`**（而不是在外面垫 `SizedBox`）：
                //       设置里关了朗读时 `SpeakButton` 返回 0 宽，**间距会一起消失**
                //       → 音标仍精确居中，行内不留一段空洞。
                SpeakButton(text: card.spelling, gapBefore: 9),
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
    // 🔴 2026-09-28 16:5x：**删掉**了这里原先的「末尾留白 18」。
    //    ⚠️ 它曾被保留的理由是「不在定案 4 处内，不擅自改」——
    //       但它与卡片内边距**叠加**：padding 下 18 + 18 = 36，而上是 4。
    //       既然内边距已回到锚点的 20/19（上下均匀），这 18 就没有存在理由了
    //       （锚点末尾只有 `.card` 的 padding，没有额外留白）。
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
        // 🔑 与 ①② 的关系（16:5x 后）：**不再需要「五处差异」** ——
        //    ①② 是**凹陷底块**（另一种形状），④ 是**左侧竖线**，形状本身就分开了。
        leftBar: Color(t.accentBright.argb32),
        leftBarWidth: 2,
        leftBarInset: 12,
        // 🔴 语境原句**要有喇叭** —— 锚点 `.ctx .spk{width:22px;height:22px;
        //    margin-left:6px;vertical-align:-8px}`，且 v1 §6.2（L0）明确
        //    `context` ✅ 朗读（「只朗读纯英文文本」）。
        //    ⚠️ 此前漏做（ARCHIVE §2.5 记的「每卡 2 个喇叭」只接了词头那个）。
        //
        // 🔑 用 `Text.rich` + `WidgetSpan` 而不是 `Row`：
        //    `Row` 会让喇叭**独占一行右侧**（脱离文字流）；WidgetSpan 则让喇叭
        //    **跟着文字的最后一格走**（例句换行时自然跟到末尾）—— 这正是锚点
        //    `display:inline-flex; vertical-align:-8px` 的语义。
        //    对应用 `PlaceholderAlignment.middle`（22px 圆在 14.5px 行内垂直居中，
        //    近似锚点的 `-8px`；用 `middle` 更稳，不随行高变化而偏）。
        child: Text.rich(
          TextSpan(
            text: ctxText,
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SpeakButton(
                  text: ctxText,
                  size: SpeakSize.inline,
                  gapBefore: SpeakSize.inlineGap,
                ),
              ),
            ],
          ),
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
      // 🔴 ①② **凹陷底块**（2026-09-28 16:5x 白哥定「还是方案 A 比较好」→ 回到锚点原文）。
      //
      // 锚点 `.mnem{background:var(--sunken); border-radius:16px; padding:14px 14px 13px;
      //             box-shadow: inset 3px 3px 9px shade, inset -3px -3px 8px light}`
      //
      // 🔑 它的作用**不是装饰，而是分类**：③④ 留白（答案）、①② 有底（线索）——
      //    spec §5.2：「① ② 独占 `--sunken`，**全卡唯一有底色的段**」。
      //
      // ⚠️ 中途曾改成「左侧色条」，问题随之而来：④ 语境**本来就有**左侧竖线 →
      //    两者都是「左侧一条竖线」，只能靠「粗细 / 色相 / 内边距 / 标签色 / 有无箭头」
      //    五个参数硬分（设计稿 §3.5）。**凹陷块是另一种形状 —— 不用比参数。**
      // 📄 逐项差异见 `docs/design/word-card-layout-refine-2026-09-28.html` §3.6。
      sunken: true,
      // 锚点 `.mnem-head{margin-bottom:8px}`（③④ 用的 `.lab` 是 **4px** —— 两者不同）
      labelGap: 8,
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
        // 🔴 2026-09-28 起**不可达**：`cognate` 已从数据层整层摘除
        //    （`mnemonic_type` 行删除 · `profile` 清空 · 2,988 个卡片段删除）——
        //    而且即使有人把它塞回数据，`CardSlots.offCard` 仍会拦住它。
        // ⚠️ 本分支**保留为空壳**只为「万一数据回潮时不静默吞掉」——
        //    它渲染一个明确的提示，而不是让卡片少一段却毫无线索。
        return Text(
          '（该词的记忆法数据异常：出现了已废弃的 cognate 段）',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: t.type.mnemNote,
            color: Color(t.ink3.argb32),
          ),
        );

      case 'collocation':
        final items = s.collocations;
        if (items.isEmpty) return const SizedBox.shrink();
        // 🔴 **词组与中文各占一行**（2026-09-28 20:5x 白哥定：
        //    「搭配整记的搭配词组应该**保证显示在一行**，可以**中文一行、搭配词组一行**
        //      这样，现在的排列方式**把词组分成了两行**」）。
        //
        // # 为什么原来会把词组折行
        // 原实现是 `Row` + 两个 `Flexible`（词组 ｜ 中文**同行**）——
        // 🔑 `Flexible` 的默认 `fit: loose` 允许子项**被压窄**，
        //    而 `Text` 被压窄时**软换行**（不自量力地硬塞）：
        //    实测 `a cocky attitude` + `自大的态度` 挤在一行放不下 →
        //    **词组自己折成 `a cocky` / `attitude`**，中文再跟在后面。
        //
        // 改成分行后，词组独占整行宽（卡片内容宽 ≈ 300pt）——
        //   实测 31,334 条搭配：词组 p99 = 29 字符（≈ 220pt）→ **99.7% 一行放得下**；
        //   ⚠️ 仍有 103 条（0.3%）> 32 字符（最长 44，如
        //   `Fountain of the Four Rivers in Piazza Navona`）会自然折行 ——
        //   这是**有意保留**的：截断（`ellipsis`）会让用户看不到完整搭配，比折行更糟。
        //
        // 🔑 为什么中文放**下面**而不是上面：词组是「要记的东西」（答案），
        //    中文是它的解释（线索）；与卡片其余部分一致 —— **答案在前、解释在后**。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              // 条与条之间 10px（原为 7）—— 🔑 每条从 1 行变 2 行后，
              // 「词组 ↔ 中文」（2px）与「条 ↔ 条」（10px）必须**拉开差距**，
              // 否则读者分不清「哪两行是同一条搭配」。
              if (i > 0) const SizedBox(height: 10),
              // 🔴 **每条搭配各带一个喇叭**（白哥 2026-09-28 21:4x 定）——
              //    v1 §6.2（L0）明确 `collocation` ✅ 朗读（英文搭配）；
              //    每条一个 = 「想听哪条点哪条」，与语境段同一手法。
              // 🔑 仍用 `Text.rich` + `WidgetSpan`（**不引入 `Row`**）——
              //    20:5x 定的「词组必须显示在一行」靠的是「词组独占整行宽」，
              //    一旦包成 `Row` 又会与喇叭抢宽度（＝折行的老问题）。
              //    WidgetSpan 跟着文字流走，长词组折行时喇叭自然跟到末尾。
              // ⚠️ 中文那行**不给喇叭** —— v1 §6.2：只朗读纯英文文本。
              Text.rich(
                TextSpan(
                  text: items[i].phrase,
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: SpeakButton(
                        text: items[i].phrase,
                        size: SpeakSize.inline,
                        gapBefore: SpeakSize.inlineGap,
                      ),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontFamily: CoFonts.latinSerif,
                  fontSize: t.type.mnemMain,
                  color: Color(t.ink.argb32),
                ),
              ),
              // zh 实测 31,334 条**全非空**（0%）→ 这个守卫只为防未来数据回潮
              if ((items[i].zh ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  items[i].zh,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: t.type.mnemNote,
                    color: Color(t.ink2.argb32),
                  ),
                ),
              ],
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
          // 锚点 `.def-en{margin-top:3px}`（原 6）—— 英文释义是**同一段内**的补充，
          // 上距要明显小于段间（14/15），否则它读起来像一个新段落。
          const SizedBox(height: 3),
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
  /// # 三种「容器」形态（2026-09-28 · 方案 A）
  /// | 形态 | 用在哪 | 手段 |
  /// |---|---|---|
  /// | [sunken] **凹陷底块** | ①② 记忆法（**线索**） | `Clay(pressed)` + `--sunken` 底 + radius 16 |
  /// | [leftBar] 左侧竖线 | ④ 语境原句（引文） | `Border.left` |
  /// | 无 | ③ 释义（答案正文） | 留白 |
  ///
  /// 🔑 为什么都包**整节**（标签行 + 内容）而不是只包内容：
  /// · 语义上「这一节是记忆法 / 这一节是引文」—— 节 = 标签 + 内容
  /// · 代码上**只有一处实现**（若 ①② 包整节、④ 只包内容，就是两套逻辑要各自维护）
  ///
  /// 🔴 **①② 与 ④ 靠「形状」区分，不靠参数**：
  ///    中途 ①② 改用过色条（与 ④ 同形）→ 只能靠「粗细 / 色相 / 左内边距 / 标签色 /
  ///    有无 `›`」五处硬分（那正是设计稿 §3.5 在救的场）。
  ///    回到凹陷块后，**形状本身**就分开了 —— ③④ 留白、①② 有底。
  ///
  /// [labelGap] = 标签行与内容之间的距离。锚点里这两处**本来就不同**：
  ///   · ①② → `.mnem-head{margin-bottom:8px}`
  ///   · ③④ → `.lab{margin-bottom:4px}`
  ///   🔑 所以它不是一个「可以统一起来」的值。
  Widget _block(
    CoEvoTokens t, {
    required String label,
    required bool accentLabel,
    required Widget child,
    String? trailing,
    VoidCallback? onTap,
    Color? leftBar,
    /// 默认值 = **④ 语境**那一组（2026-09-28 后 [leftBar] 的唯一消费者）。
    /// ⚠️ 原默认是 3 / 14（那是 ①② 色条版的值）—— ①② 改回凹陷块后，
    ///    留着旧默认值是**残留**：它会让下一个用 [leftBar] 的人拿到一组没人用过的数字。
    double leftBarWidth = 2,
    double leftBarInset = 12,
    bool sunken = false,
    double labelGap = 4,
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
        // 🔑 标签下距要**明显小于**段间（14/15），否则标签读起来像独立一段，
        //    而不是「它下面那段的名字」。⚠️ 但 ①②（8）与 ③④（4）**不同**
        //    —— 见 [labelGap] 的说明。
        SizedBox(height: labelGap),
        child,
      ],
    );

    // ① 凹陷底块（①② 记忆法）—— 见 `_mnemonicBlock`
    if (sunken) {
      return Clay(
        state: ClayState.pressed,
        // ⚠️ 必须显式给 `sunken`：`Clay` 默认填充是 `clayFill`（= `card`），
        //    而锚点这里的底是 `--sunken`。同 `HeaderChip` / `BookmarkButton`。
        fill: t.sunken,
        // 锚点 `.mnem{border-radius:16px}` —— 写死，不走 token 档位
        borderRadius: _mnemRadius,
        // 🔑 点击交给 `Clay`（而不是外面再包一层 `GestureDetector`）——
        //    这样才有按下回弹（spec §3.8：「缺了动效，粘土只是个圆角卡片」）。
        //    传 `null` = 不可点（该词无族页）→ 它自动退化成**静态**底块。
        onTap: onTap,
        // 锚点 `.mnem{padding:14px 14px 13px}`
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
        child: content,
      );
    }

    // ② 左侧竖线（④ 语境原句）
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
