/// 聚合页 —— **词根族 / 词源族**（点卡片 ① / ② 进来的那一页）。
///
/// # 🔴 为什么它是**顶层路由**（而不是复习页里的一个状态）
/// 判据是项目已定的那条：**它是不是 tab 的内容** ——
/// 否（它是覆盖全屏的沉浸态）→ **顶层路由**。
/// 同 `/review/session`（翻卡）与 `/article/:id`（阅读器）的处理。
///
/// ⚠️ 反例（2026-09-28 踩过）：把这类界面做成「页内 `bool` 状态」时，
///    它会**静默继承**所在页面的布局约束（`extendBody` + tabbar ≈100px）
///    → 底部内容被盖住且拉不出来，而**编译器不报错**。
///
/// # 界面锚点（L1）
/// `docs/design/visual-word-card-target-2026-09-26.html` §04 / §05
/// ```
/// ‹ 返回                        cept 词根族   ← 🔄 顶栏带族名（2026-09-28）
///          cept                            ← source.form（居中 · 23px）
///     Latin · 拿取 · 22 个同族词              ← meta
///      来自 intercept 的 ① 词根词缀           ← 来处（可选）
/// ─────────────────────────────          ← 下边线
/// accept        接受，收受            ›   ← 平坦行 · 词列定宽 · 可点
///   ac-（向，加强）+ cept（拿，取）          ← 分拆法，共享词根用强调色
/// ```
///
/// ## 🔴 「每条都带分拆法」是这一页的**存在理由**
/// 设计稿原话：
/// > 「**只列单词是没意义的**：那是『22 个不相干的词』；带分拆法才是
/// >   『**一个词根 × 22 种前缀**』……分拆法可算率 **100%**，来自 `word_morpheme`。」
///
/// 所以成员行**必须**渲染分拆法；分拆法取不到时该行只显示词 + 释义
/// （数据缺失不影响整页 —— 但这种情况实测为 0）。
///
/// ## ✅ 成员**可点**（2026-09-28 白哥定 · 改了旧决定）
///
/// 旧注释写「不可点：设计稿没定义点成员去哪」—— **已作废**。
/// 白哥定：**点成员 → 查词浮层**（`LookupSheet.show`）。
///
/// 🔑 **形态随之从「粘土卡」改为「平坦行」**（同一次定案）：
/// `Clay` 在项目里的语义是「**可交互的粘土物件**」，「不可点」的先例是**平坦**。
/// 旧实现是「凸起 + 无 `onTap`」= **静默无效**（「看起来能点，点了没反应」）。
/// 现在「平坦 + 有 `onTap` + `›`」三者一致。
///
/// 🔴 **不写生词本**：`lookup()` 是**纯查询**；写库（`_writeBackLookup`）是阅读器
/// **显式调用**的。从聚合页点开一个词 = 「看看这个词」，**不是「我要学它」**
/// → 不写 `user_word`、不记 `lookup_event`。语义正确，且这是本页**唯一的可点行为**。
///
/// ⚠️ 浮层里**没有 ①② 入口** → **不会套娃**（聚合页 → 浮层 → 聚合页…）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/aggregate_page_provider.dart';
import '../providers/word_db_provider.dart';
import '../services/word_query_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/lookup_sheet.dart';

class AggregatePageScreen extends ConsumerWidget {
  const AggregatePageScreen({
    super.key,
    required this.pageId,
    this.fromWord,
    this.fromSlotLabel,
  });

  final int pageId;

  /// 来处：从哪个词点进来的（设计稿：「来自 intercept 的 ① 词根词缀」）。
  ///
  /// 🔑 这个上下文提示的作用：用户从卡片点进来时**心智还在那张卡上**，
  ///    告诉他「这是从哪展开的」，返回时才知道回到哪。
  final String? fromWord;

  /// 来处的槽位显示名（「词根词缀」/「词源故事」…）。
  final String? fromSlotLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);
    final page = ref.watch(aggregatePageProvider(pageId));

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🔄 顶栏带族名（2026-09-28 白哥定「3 处一起改」）——
            //    锚点：`‹ 返回` 左、族名右对齐。下滑后仍知道这是哪一族。
            //    ⚠️ 加载中 `front` 为 null → 只有返回（不伪装成「没有族名」）。
            _TopBar(front: page.valueOrNull?.front),
            Expanded(
              child: page.when(
                // 首次加载 → 什么都不画（画空态会先闪一下「打不开」，是谎报）
                loading: () => const SizedBox.shrink(),
                // 失败 / 词库未就绪 → 给准确的话（不冒充「没有这个族」）
                error: (e, st) => const _Unavailable(),
                data: (p) => p == null ? const _Unavailable() : _body(context, ref, t, p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点成员 → **查词浮层**（白哥 2026-09-28 定）。
  ///
  /// 🔴🔴 **绝不写生词本** —— 这是本方法最关键的一条。
  /// `lookup()` 是纯查询；写库（`_writeBackLookup`）是阅读器**显式调用**的。
  /// 从聚合页点开 = 「看看这个词」，不是「我要学它」→ 不写 `user_word`、
  /// 不记 `lookup_event`。（v1 §八「查词即入生词本」约束的是**主动查词**，
  /// 而聚合页扫族成员是**浏览**，不是查词。）
  ///
  /// ⚠️ 词库未就绪时**给准确的话**（复用阅读器的三种文案）——
  ///    不留静默失败（本项目判据：静默失败比报错更糟）。
  ///    实测聚合页能显示成员 ⇒ 词库必然 ready ⇒ 正常路径上走不到；
  ///    但保留守卫（`aggregatePageProvider` 与 `wordQueryProvider` 是两个 provider，
  ///    不能假设它们的就绪时机永远一致）。
  Future<void> _openMember(
    BuildContext context,
    WidgetRef ref,
    String spelling,
  ) async {
    final load = ref.read(wordQueryProvider).valueOrNull;
    if (load is! WordDbReady) {
      _hint(
        context,
        switch (load) {
          WordDbUnsupported() => '查词需在手机上使用（Web 端无本地词库）',
          WordDbFailed() => '词库打开失败，请重启 App 后再试',
          _ => '词库正在准备，请稍候再试',
        },
      );
      return;
    }

    final result = await load.service.lookup(spelling);
    if (!context.mounted) return;

    // 理论上不会发生（成员都来自词库），但如实处理而不是静默什么都不做
    if (result == null) {
      _hint(context, '词库里没有「$spelling」');
      return;
    }

    await LookupSheet.show(context, result);
    // 🚫 到此为止 —— 不调 `_writeBackLookup`（见方法头）。
  }

  // ── 正文 ────────────────────────────────────────────────
  Widget _body(BuildContext context, WidgetRef ref, CoEvoTokens t, AggregatePage p) {
    final s = p.source;
    final form = (s?.form ?? '').trim();
    final meta = _metaOf(s, p);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
      children: [
        // ① 页头 —— 锚点 `.agg-src{text-align:center;padding:6px 0 13px;
        //    border-bottom:1px solid line}`。
        //
        // 🔄 2026-09-28 改三处（白哥定「3 处一起改」）：
        //    · 左对齐 → **居中**（+ 下边线）：让页头成为「头」，不与成员列表黏在一起
        //    · 词根本体 30px 朱砂 → **23px ink**（serif）：
        //      🔑 原先朱砂 + 30px 与「族名」**抢主角**，且是这一页**唯一的重色**；
        //         这一页的主角是「**词根 × 前缀的横向规律**」，不是那个词根本身
        //    · **删掉页头里的族名**（它移到顶栏）→
        //      修掉「cept 出现两次」「Latin 出现两次」的重复
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 13),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(t.line.argb32), width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (form.isNotEmpty)
                Text(
                  form,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: CoFonts.latinSerif,
                    fontSize: 23,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    color: Color(t.ink.argb32),
                  ),
                ),
              if (meta.isNotEmpty) ...[
                SizedBox(height: form.isNotEmpty ? 4 : 0),
                Text(
                  meta,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12.5,
                    height: 1.5,
                    color: Color(t.ink2.argb32),
                  ),
                ),
              ],
              // 来处（可选）—— 设计稿：「来自 intercept 的 ① 词根词缀」
              if ((fromWord ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  '来自 $fromWord 的 ${fromSlotLabel ?? '记忆法'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 11.5,
                    height: 1.5,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ],
            ],
          ),
        ),
        for (var i = 0; i < p.members.length; i++)
          _MemberRow(
            member: p.members[i],
            gloss: p.glosses[p.members[i].wordId],
            // 🔑 共享词根（本族的「公约数」）—— 分拆法里它用强调色标出。
            //    取自 `source.form`；`source` 缺失 → 空串 → 退化为「不标色」（仍渲染）。
            sharedRoot: (s?.form ?? '').trim().toLowerCase(),
            // 末行不给下分隔线（分隔线的语义是「下面还有一行」）
            showDivider: i < p.members.length - 1,
            onTap: () => _openMember(context, ref, p.members[i].spelling),
          ),
      ],
    );
  }

  /// 页头副行：`Latin · 拿取 · 22 个同族词`
  String _metaOf(AggregateSource? s, AggregatePage p) {
    final parts = <String>[
      if ((s?.origin ?? '').trim().isNotEmpty) s!.origin!.trim(),
      if ((s?.meaning ?? '').trim().isNotEmpty) s!.meaning!.trim(),
      if (p.memberCount > 0) '${p.memberCount} 个同族词',
    ];
    return parts.join(' · ');
  }
}

/// 顶栏：`‹ 返回` + **族名**（右对齐）。
///
/// 🔄 2026-09-28：加族名（白哥定「3 处一起改」）—— 锚点 `.agg-bar` 右侧就是族名。
/// 🔑 为什么需要它：成员列表可以滚很长（最多 63 个成员），**下滑后页头滚走了**，
///    顶栏若没有族名，用户就**失去页面身份**（不知道自己在哪一族）。
///    ⚠️ 页头里的族名已随之**删掉** → 顺带修掉「cept 出现两次」「Latin 出现两次」。
///
/// ⚠️ **做成独立 widget 而不是页面的实例方法**（2026-09-28 编译错误后改）：
///    实例方法 `Widget _topBar(CoEvoTokens t)` **拿不到 `context`** ——
///    而返回按钮要 `context.pop()` → `Error: The getter 'context' isn't defined`。
///    🔑 独立 widget 的 `build(context)` **天然有 context**，且与项目惯例一致
///    （本文件的 `_MemberRow` / `_Split` / `_Unavailable`，
///      复习页的 `_SearchIconButton` / `_SortChip` 都是独立 widget）。
///
/// 📌 **教训**：这类「未定义符号」错误 `dart format`（纯语法解析）**抓不到** ——
///    只有语义分析能发现。已补 `scripts/static_check`（见该目录 README）。
class _TopBar extends StatelessWidget {
  const _TopBar({this.front});

  /// 族名（来自 `AggregatePage.front`，如「cept 词根族（Latin）」）。
  /// 只取括号前的部分（「cept 词根族」）—— 括号里的语源已在页头 meta 显示。
  /// `null`（加载中）→ 只有返回按钮。
  final String? front;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final name = (front ?? '').trim();
    // 「cept 词根族（Latin）」→「cept 词根族」（全角/半角括号都处理）
    final short = name.isEmpty
        ? ''
        : name.split('（').first.split('(').first.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 18, 8),
      child: Row(
        children: [
          // 返回：点击区域比图标大（图标 20 + padding 10×2 = 40 起）
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '‹',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 20,
                      height: 1,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '返回',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (short.isNotEmpty) ...[
            const Spacer(),
            Flexible(
              child: Text(
                short,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(t.ink.argb32),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一个族成员：**词 + 释义 + 分拆法** —— 一行「表」里的记录。
///
/// 🔑 分拆法是这一行存在的意义（见文件头）——
///    它把「22 个不相干的词」变成「一个词根 × 22 种前缀」。
///
/// # 🔄 2026-09-28：从「粘土卡」改为**平坦行**（白哥定）
///
/// | | 旧 | 新 |
/// |---|---|---|
/// | 容器 | `Clay`（凸起粘土卡，圆角 26） | **平坦**（无底色）+ **细下分隔线** |
/// | 词列 | `Flexible`（挤在一起） | **最小宽 96px**（`min-width`，长词自然加宽） |
/// | 释义 | 紧跟在词后 | **右对齐**（`max-width 118`） |
/// | 可点 | ❌ 无 | ✅ `InkWell` + **`›`** |
///
/// 🔴 **为什么必须一起改**：`Clay` 的语义是「可交互的粘土物件」，
/// 项目里「不可点」的先例是**平坦**。旧实现「凸起 + 无 `onTap`」=
/// **静默无效**（看起来能点、点了没反应）—— 本项目已定为禁忌。
/// 改平坦 + 加 `onTap` + 给 `›`，**三者一致**。
///
/// 🔑 **为什么改平坦是对的（不只是为了可点）**：
/// 20+ 行每行一张浮起的卡 = 20+ 个独立物件，视觉噪声大，
/// 而且这一页要读的是**横向规律**（同一词根 × 不同前缀）——
/// **一张表**比**一堆卡**更贴合这件事。
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.gloss,
    required this.sharedRoot,
    required this.onTap,
    this.showDivider = true,
  });

  final AggregateMember member;

  /// 中文释义（来自 `AggregatePage.glosses`；`null` = 该成员没有 → 不渲染那一段）
  final String? gloss;

  /// 本族共享词根（**已小写**）—— 分拆法里它用强调色
  final String sharedRoot;

  /// 点这一行 → 查词浮层（由页面注入，见 `_openMember`）。
  /// ⚠️ 必填 —— 「有 `›` 就一定点得动」不允许出现「可选但没传」的组合。
  final VoidCallback onTap;

  /// 末行不给分隔线（分隔线的语义是「下面还有一行」）
  final bool showDivider;

  /// 词列最小宽 —— 锚点 `.agg-w{min-width:96px}`。
  ///
  /// 🔑 用 **min** 而不是固定宽：长词（`contraception` / `responsibility`）
  ///    会自然加宽，**不会被截断**；短词则对齐到同一列，
  ///    让 20+ 行能**竖着扫**（这才是「表」的价值）。
  static const double _wordMinWidth = 96;

  /// 释义最大宽 —— 锚点 `.agg-z{max-width:118px}`，防止长释义挤掉词列。
  static const double _glossMaxWidth = 118;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final g = (gloss ?? '').trim();

    return InkWell(
      onTap: onTap,
      // 按下反馈 —— 锚点 `.agg-item:active{background:var(--sunken)}`。
      // 🔑 平坦行没有「凸起」这个可点信号，按下反馈就是它唯一的触摸反馈，
      //    必须有（否则又是「平坦且看不出能点」）。
      highlightColor: Color(t.sunken.argb32),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 11, 8, 11),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(t.line.argb32), width: 1),
                ),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // 词列 —— 最小宽 96（锚点 `.agg-w`），字号 14.5（锚点）
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: _wordMinWidth),
                  child: Text(
                    member.spelling,
                    style: TextStyle(
                      fontFamily: CoFonts.latinSerif,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                ),
                // 释义 —— 右对齐、占满剩余（限宽 118）
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: _glossMaxWidth),
                      child: Text(
                        g,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12.5,
                          height: 1.4,
                          color: Color(t.ink2.argb32),
                        ),
                      ),
                    ),
                  ),
                ),
                // 可点指示 —— 锚点 `.agg-go`。
                // 🔑 与 `InkWell.onTap` **必然同时存在**（本 widget 两者都必填/必有），
                //    所以不存在「有箭头点不动」的组合。
                const SizedBox(width: 6),
                Text(
                  '›',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 13,
                    height: 1,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ],
            ),
            if (member.morphology.isNotEmpty) ...[
              const SizedBox(height: 5),
              _Split(t: t, member: member, sharedRoot: sharedRoot),
            ],
          ],
        ),
      ),
    );
  }
}

/// **分拆法**：`dis-（不，相反）+ organ（器官，组织）+ -ized（使…化）`
///
/// 🔑 **共享词根用强调色**（设计稿：「共享词根用强调色标出」）——
///    那是「一眼看出同一族」的视觉钩子：横向扫一遍就能看出
///    「这些词的共同点是 `organ`」。
///
/// ⚠️ 这里**逐段渲染**（用 `morphology`）而不是用既有的 `breakdown` 字符串：
///    字符串没法给其中一段单独上色。`breakdown` 仍保留 ——
///    它是给「纯文本场景」（如验收脚本打印）用的。
class _Split extends StatelessWidget {
  const _Split({
    required this.t,
    required this.member,
    required this.sharedRoot,
  });

  final CoEvoTokens t;
  final AggregateMember member;
  final String sharedRoot;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < member.morphology.length; i++) {
      final p = member.morphology[i];
      if (i > 0) {
        spans.add(TextSpan(
          text: '  +  ',
          style: TextStyle(color: Color(t.ink3.argb32)),
        ));
      }
      // 🔑 用 `surface` 比对共享词根（**不用 id**）—— 见 `AggregateSource` 的说明：
      //    `aggregate_page.group_id` 与 `word_morpheme.root_id` 不是同一个 id 空间
      //    → 用 id 匹配会**静默永不命中**（强调色永远不出现，且没人发现）。
      final shared = sharedRoot.isNotEmpty &&
          p.surface.trim().toLowerCase() == sharedRoot;
      spans.add(TextSpan(
        text: p.surface,
        style: TextStyle(
          fontFamily: CoFonts.latinSerif,
          color: Color(shared ? t.accent.argb32 : t.ink2.argb32),
          fontWeight: shared ? FontWeight.w600 : FontWeight.w400,
        ),
      ));
      final g = (p.gloss ?? '').trim();
      if (g.isNotEmpty) {
        spans.add(TextSpan(
          text: '（$g）',
          style: TextStyle(color: Color(t.ink3.argb32)),
        ));
      }
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          // 锚点 `.agg-bd{font-size:11.5px}`（原 12）
          fontSize: 11.5,
          height: 1.6,
        ),
        children: spans,
      ),
    );
  }
}

/// 轻提示（SnackBar）—— 与阅读器的 `_hint` 同一形态。
///
/// 🔑 为什么聚合页也需要它：成员行可点之后，「点下去什么都没发生」就成了可能
///    （词库未就绪 / 词典未命中）。本项目判据：**静默失败比报错更糟** ——
///    所以每种「没反应」都要有**准确的话**。
void _hint(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
}

/// 取不到内容 —— 给**准确**的话（不冒充「没有这个族」）。
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 40, 18, 18),
      child: Text(
        '这一页暂时打不开。',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 13,
          height: 1.7,
          color: Color(t.ink3.argb32),
        ),
      ),
    );
  }
}
