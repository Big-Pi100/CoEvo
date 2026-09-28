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
/// ‹ 返回
/// cept 词根族                     ← front
/// cept                            ← source.form（大字）
/// Latin · 拿取 · 22 个同族词        ← meta
/// 来自 intercept 的 ① 词根词缀      ← 来处（可选）
/// ─────────────────────────────
/// intercept   拦截；截获
///   inter-（在…之间）+ cept（拿取）  ← 🔑 分拆法，共享词根用强调色
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
/// ## ⚠️ 成员**不可点**
/// 设计稿没定义「点成员去哪」→ 本页**不给任何可点暗示**
/// （无 `onTap`、无 `›`）。🔑 「显示箭头却点不动」= 静默无效（本项目已定为禁忌）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/aggregate_page_provider.dart';
import '../services/word_query_service.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

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
            const _TopBar(),
            Expanded(
              child: page.when(
                // 首次加载 → 什么都不画（画空态会先闪一下「打不开」，是谎报）
                loading: () => const SizedBox.shrink(),
                // 失败 / 词库未就绪 → 给准确的话（不冒充「没有这个族」）
                error: (e, st) => const _Unavailable(),
                data: (p) => p == null ? const _Unavailable() : _body(t, p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 正文 ────────────────────────────────────────────────
  Widget _body(CoEvoTokens t, AggregatePage p) {
    final s = p.source;
    final form = (s?.form ?? '').trim();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
      children: [
        // ① 页头：族名（front）
        Text(
          p.front,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            height: 1.3,
            color: Color(t.ink.argb32),
          ),
        ),
        if (form.isNotEmpty) ...[
          const SizedBox(height: 14),
          // ② 词根/词源本体（大字）—— 这一页的主角就是它
          Text(
            form,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 30,
              fontWeight: FontWeight.w500,
              height: 1.15,
              color: Color(t.accent.argb32),
            ),
          ),
        ],
        if (_metaOf(s, p).isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(
            _metaOf(s, p),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12,
              height: 1.5,
              color: Color(t.ink3.argb32),
            ),
          ),
        ],
        // ③ 来处（可选）—— 设计稿：「来自 intercept 的 ① 词根词缀」
        if ((fromWord ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            '来自 $fromWord 的 ${fromSlotLabel ?? '记忆法'}',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              color: Color(t.ink3.argb32),
            ),
          ),
        ],
        const SizedBox(height: 20),
        for (var i = 0; i < p.members.length; i++) ...[
          if (i > 0) const SizedBox(height: CoSpacing.sm + 2),
          _MemberRow(
            member: p.members[i],
            gloss: p.glosses[p.members[i].wordId],
            // 🔑 共享词根（本族的「公约数」）—— 分拆法里它用强调色标出。
            //    取自 `source.form`；`source` 缺失 → 空串 → 退化为「不标色」（仍渲染）。
            sharedRoot: (s?.form ?? '').trim().toLowerCase(),
          ),
        ],
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

/// 顶栏：`‹ 返回`。
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
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
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
        ],
      ),
    );
  }
}

/// 一个族成员：**词 + 释义 + 分拆法**。
///
/// 🔑 分拆法是这一行存在的意义（见文件头）——
///    它把「22 个不相干的词」变成「一个词根 × 22 种前缀」。
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.gloss,
    required this.sharedRoot,
  });

  final AggregateMember member;

  /// 中文释义（来自 `AggregatePage.glosses`；`null` = 该成员没有 → 不渲染那一段）
  final String? gloss;

  /// 本族共享词根（**已小写**）—— 分拆法里它用强调色
  final String sharedRoot;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final g = (gloss ?? '').trim();

    return Clay(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  member.spelling,
                  style: TextStyle(
                    fontFamily: CoFonts.latinSerif,
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    color: Color(t.ink.argb32),
                  ),
                ),
              ),
              if (g.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    g,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      height: 1.4,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (member.morphology.isNotEmpty) ...[
            const SizedBox(height: 9),
            _Split(t: t, member: member, sharedRoot: sharedRoot),
          ],
        ],
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
          fontSize: 12,
          height: 1.6,
        ),
        children: spans,
      ),
    );
  }
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
