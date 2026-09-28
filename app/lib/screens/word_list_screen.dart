/// 生词本 —— 「阅读」tab 内的**子视图**，从信息流标题栏右侧「生词 N」进入。
///
/// # 🔴 设计依据（**如实说明：没有页面稿**）
/// 核实过 `docs/design/*.html`：**没有任何生词本页面的设计稿**
/// （只有 `visual-feed-bookmark` 里「与『生词本不能硬删』不同」这一句 DDL 理由）。
///
/// 所以本页版式来自**两处有据可依的来源**：
/// 1. **L0** `v1-final-design-authoritative-2026-09-25.md` §1.1 / §1.2 ——
///    生词本是核心链路的一环（「阅读文章 → 画线查词 → **生词本** → 间隔重复复习」），
///    且属免费层能力（§可用性表「生词本 ✅ 本地」）→ **它必须在主链路里可见**
/// 2. **同族页面** `bookmark_list_screen`（收藏清单）—— 两者是同一类东西
///    （「阅读过程中攒下的东西」）→ 标题栏 / 副标题 / 空状态 / 底部避让
///    **全部沿用它的版式语言**；只有列表项形态不同（收藏是文章卡，生词是词条行）
///
/// # 🔑 为什么是「子路由」而不是独立全屏页
/// 判据与收藏清单**完全相同**（`app.dart` 里已写明）：**「它是不是 tab 的内容」**。
/// 是 → 挂 `/home/words`（本页），渲染在该分支的 Navigator 里 →
/// **底部 tabbar 保留** + **右滑可返回**。
///
/// # 🔴 为什么入口在「阅读」tab 而**不是「我的」**
/// 产品原则（白哥 2026-09-27）：「**除了生词表限制以外，不验证用户登录状态**」。
/// `profile_screen`（「我的」tab）**整体依赖登录态**（未登录直接不渲染内容）→
/// 把生词本入口放那里，等于给一个**本地免费能力**套上登录门槛。
/// 而「阅读」tab 是**无条件渲染**的（见 `home_screen.build` 的说明）→ 符合原则。
/// 且查词发生在阅读流程里 → 用户回到「阅读」tab 找回来是最自然的路径。
///
/// # 列表项显示什么（**刻意保守**）
/// 只显示 **单词 + 加入时间**，不显示释义。
/// 🔑 理由：`user_word` 表**只冗余 `spelling`**（见 `user_db_schema.sql` 的说明 ——
/// 释义在 `word.db`，一条 ~1.2 KB，复制 11,523 条 = ~14 MB）。
/// 要在本页显示释义就得**逐词去 `word.db` 查**（43 µs/词，但需批量 + 异步编排）。
/// → 第一版**不做**：本页的目标是「**让查过的词可见**」，释义属于
/// 「点进去看词卡」（`3.7` 卡片）的职责。**不为了好看先塞半成品。**
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/user_word_provider.dart';
import '../services/user_word_repository.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class WordListScreen extends ConsumerWidget {
  const WordListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);

    // 🔑 只用 `watch` 一个 provider —— 计数**从列表长度取**（`valueOrNull?.length`），
    //    不另读 `userWordCountProvider`。
    //    理由：两个数据源各自查库 → 理论上会出现「列表 3 条、计数显示 4」的瞬时不一致；
    //    而列表**本来就只含未移出的**（仓储 `WHERE deleted = 0`）→ 长度就是口径本身。
    final list = ref.watch(userWordListProvider);
    final count = list.valueOrNull?.length;
    final atLimit = count != null && count >= kUserWordLimitFree;

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理，这里只避让状态栏
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题栏（版式同收藏清单 `.bm-hd`：左 23/w600，右 12/accent/w600）──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '生词本',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 23 * -0.015,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  InkWell(
                    onTap: () => context.pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      // 撑够点击区（12px 小字太窄），视觉上仍是纯文字链接
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '返回',
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(t.accent.argb32),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── 副标题 ──
            // ⚠️ 计数**只在这里出现一次**（不重复放到列表里）。
            //    未就绪（`count == null`）时显示引导文案而**不显示 0** ——
            //    那时「0」可能是谎报（库还没读出来）。
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
              child: Text(
                count == null
                    ? '在文章里划词查询，词会自动收进这里。'
                    : atLimit
                        ? '已收集 $count / $kUserWordLimitFree 个词 · '
                            '已达上限，新查到的词不再收进'
                        : '已收集 $count / $kUserWordLimitFree 个词。'
                            '在文章里划词，词会自动收进这里。',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  height: 1.6,
                  // 达上限是**需要用户注意**的状态（关系到订阅）→ 用品牌色而非 ink3
                  color: Color(atLimit ? t.accent.argb32 : t.ink3.argb32),
                ),
              ),
            ),

            // ── 内容 ──
            Expanded(
              child: list.when(
                // 首次加载（通常 < 100ms）→ **什么都不画**。
                // 🔴 不能在这里画空状态 —— 那会在有生词时先闪一下
                //    「还没有生词」，是**对用户的谎报**（同收藏清单的处理）。
                loading: () => const SizedBox.shrink(),
                // 读失败 → 给一句**准确**的话，不冒充「还没有生词」。
                error: (e, st) => const _Unavailable(),
                data: (words) => words.isEmpty
                    ? const _EmptyState()
                    : _list(context, words),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 词条列表（间距与收藏清单一致：左右 16 + 项间 13）。
  Widget _list(BuildContext context, List<UserWord> words) {
    return ListView.separated(
      // 底部留出 tabbar 高度 —— `_ShellScaffold` 开了 `extendBody: true`。
      padding: const EdgeInsets.fromLTRB(16, 0, 16, CoSpacing.tabBarClearance),
      itemCount: words.length,
      separatorBuilder: (_, __) => const SizedBox(height: 13),
      // 🔑 **按返回顺序渲染，不重排** —— 顺序由仓储 `ORDER BY added_at DESC`
      //    保证（走 `idx_uw_time`）。两处排序定义 = 漂移源。
      itemBuilder: (_, i) => _WordRow(word: words[i]),
    );
  }
}

/// 一条生词 —— 单词 + 加入时间 + 移出。
///
/// 🔑 单词字号 **19 / Literata / w500** —— 取自**同族页面** `FeedCard` 的标题层级
/// （设计稿 `.fc h3` 的 `Literalata 19 / w500`）。生词在这里的角色就是「条目标题」，
/// 与文章标题同级是合理的；本页没有自己的设计稿，故不另造数值。
class _WordRow extends ConsumerWidget {
  const _WordRow({required this.word});

  final UserWord word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);

    // `Clay` 默认态即「凸起实体」，与 `FeedCard` 同一材质语言（不加 `state` 参数）。
    // ⚠️ 不传 `onTap` —— 行本身不可点（点进去看词卡属 3.7，尚未实现；
    //    给一个点了没反应的行是「静默无效的操作」，比不可点更糟）。
    return Clay(
      padding: const EdgeInsets.fromLTRB(18, 15, 12, 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  word.spelling,
                  style: TextStyle(
                    fontFamily: CoFonts.latinSerif,
                    fontSize: 19,
                    fontWeight: FontWeight.w500,
                    height: 1.31,
                    letterSpacing: 19 * -0.011,
                    color: Color(t.ink.argb32),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${_fmtDate(word.addedAt)} 加入',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: t.type.label,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RemoveButton(onTap: () => _remove(context, ref)),
        ],
      ),
    );
  }

  /// 移出生词本（🔴 **软删** —— `deleted = 1`，学习数据保留，再次查词会**复活**）。
  ///
  /// 🔑 失败只记日志 + 不改界面状态 —— **不能**因为写库失败就把这一行从列表里抹掉
  /// （那会让用户以为「移出成功了」，而下次打开它又回来了 → 「这 App 有 bug」）。
  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(userWordProvider.future);
      final changed = await repo.remove(word.wordId);

      // `false` = 本来就已经是移出状态（本次无动作）→ **不刷界面、不提示**
      // （为一次没发生的操作弹提示，是另一种谎报）
      if (!changed) return;

      // 🔑 列表与计数都要失效：它们读的是同一张表的同一条件，
      //    只刷一个会出现「列表没了但数字还是旧的」。
      ref.invalidate(userWordListProvider);
      ref.invalidate(userWordCountProvider);

      // ⚠️ 文案刻意说「再次查词会回来」—— 移出是**软删**，这对用户是有用信息
      //    （否则他会以为这个词被永久删掉了）。
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已移出「${word.spelling}」，再次查词就会重新收进来。'),
          duration: const Duration(seconds: 2),
        ));
    } catch (e, st) {
      debugPrint('[word_list] 移出生词失败 wordId=${word.wordId}：$e\n$st');
    }
  }
}

/// 「移出」—— 版式同收藏清单的「返回」（12 / accent / w600 文字链接）。
///
/// 🔑 用 `accent` 而非 `ink3`：页面上的**可点元素必须可辨认**。
///    `ink3` 在三种底色上对比度都 < 4.5（见 `_ClayTabBar` 的实测表），
///    用在操作入口上等于把入口藏起来。
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '移出',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(t.accent.argb32),
          ),
        ),
      ),
    );
  }
}

/// 空状态 —— 教会用户「**词从哪来**」，而不只是说「没有内容」。
///
/// 🔑 版式沿用收藏清单 `.empty`（凹陷圆环 + 标题 + 说明）——
///    两页的空状态解决的是**同一个问题**（用户不知道东西是怎么攒进来的），
///    没有理由长得不一样。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 52, 22, 52),
      child: Column(
        children: [
          // 粘土**凹陷**圆环（同收藏清单：74×74 · `Clay(pressed)` · `sunken` 底）
          SizedBox(
            width: 74,
            height: 74,
            child: Clay(
              state: ClayState.pressed,
              fill: t.sunken,
              borderRadius: BorderRadius.circular(37),
              child: Center(
                child: Icon(
                  // 生词 = 词卡堆 → 用「卡片叠」的图标，与书签（收藏）区分开
                  Icons.style_outlined,
                  size: 26,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          Text(
            '还没有生词',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: 9),

          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 250),
            child: Text(
              '读文章时遇到不认识的词，长按选中就能查看释义，'
              '查过的词会自动收进这里，之后在「复习」里安排记忆。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                height: 1.7,
                color: Color(t.ink2.argb32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 库不可用 —— **设计稿未定义此态**，取最小诚实表达。
///
/// 🔴 为什么不能沿用空状态的「还没有生词」：那是**谎报** ——
/// 用户可能明明有生词，只是库暂时打不开。本项目既定原则：
/// 「**静默失败 / 误导性提示 比报错更糟**」（同 `bookmark_list_screen._Unavailable`）。
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '生词暂时读不出来，重启应用可再试。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.7,
            color: Color(t.ink3.argb32),
          ),
        ),
      ),
    );
  }
}

/// `DateTime`（**UTC**）→ 本地日期 `YYYY-MM-DD`。
///
/// 🔑 必须 `toLocal()`：库里的时间列全是 **UTC ISO8601 带 `Z`**（现库硬约束 1），
///    直接显示 UTC 会让「昨晚查的词」显示成今天/昨天错位。
///     项目未引 `intl`（pubspec 无该依赖），且这里只需一种格式 → 手写。
String _fmtDate(DateTime utc) {
  final d = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
