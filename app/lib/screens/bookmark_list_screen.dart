/// 收藏清单 —— 「阅读」tab 内的**子视图**，从信息流标题栏右侧「收藏 N」进入。
///
/// # 依据
/// 设计稿 `docs/design/visual-feed-bookmark-2026-09-25.html`
/// （`.bm-hd` / `.bm-sub` / `.empty` 三个类，以及第 355-407 行的两个 mockup）。
///
/// 设计稿原话（本页的**全部设计依据**）：
/// > 「同一套卡片组件，只是筛选过 —— **没有新界面要设计**。
/// >   空状态用粘土凹陷圆环 + 引导文案。」
/// >
/// > 「空状态要教会用户「**书签在哪**」，而不是只说「没有内容」。
/// >   **用真实图标做引导**，用户下次一眼就认出来。」
///
/// # 🔑 路线：为什么是「子路由」而不是「独立全屏页」
/// 挂成 `/home` 的**子路由**（`/home/bookmarks`）→ go_router 把它渲染在
/// **该分支的 Navigator** 里 → **底部 tabbar 保留**。
///
/// | | 路由形态 | tabbar | 依据 |
/// |---|---|---|---|
/// | **收藏清单** | `/home/bookmarks`（子路由） | ✅ **保留** | 设计稿 mockup 画了 tabbar；产品原则「**收藏是视图非 tab**」 |
/// | 阅读器 | `/article/:id`（顶层） | ❌ 全屏 | spec §5.1「底部：无」（沉浸阅读） |
///
/// 🔑 两者不同**不是疏漏**：「清单」属于「阅读」这个 tab 的**内容**；
///    「阅读器」是**覆盖全屏的沉浸态**。判断依据是「它是不是 tab 的内容」。
///
/// ## 🔴 返回路径（2026-09-28 白哥实测后修正）
/// 本页原先**没有任何返回入口** —— 当时按 mockup 判「子视图不需要返回按钮」，
/// 把设计稿 CSS 里的 `.bm-hd .back` 当成「全屏方案的残留」忽略了。
/// 白哥实测：「**收藏列表根本没有返回按钮**」→ 判断错误，已补。
///
/// 现在有**两条**返回路径：
/// 1. **边缘右滑** —— 由转场自带（`theme_builder` 的 `pageTransitionsTheme`
///    统一用 `CupertinoPageTransitionsBuilder`，它内含手势检测器）
/// 2. **标题栏右上「返回」** —— 启用设计稿原本定义的 `.bm-hd .back`
///
/// 🔑 教训：**「设计稿没画」≠「设计稿没定义」** —— `.back` 的样式就写在 CSS 里，
///    只是 mockup 那版没摆出来。看到「定义存在但未被使用」时，
///    要当**待补全的接口**看，而不是当残留删掉。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../providers/bookmark_provider.dart';
// `Bookmark` 是仓储层的记录类型（本页要按收藏顺序重排内容）
import '../services/bookmark_repository.dart' show Bookmark;
import '../providers/feed_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/clay.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_toggle.dart';
import '../widgets/feed_card.dart';

class BookmarkListScreen extends ConsumerWidget {
  const BookmarkListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);

    // 🔑 两件事分开看（同信息流页的约定）：
    //    · `isReady` → 「库能不能用」（决定按钮是否可点 / 是否给准确提示）
    //    · `bookmarkListProvider` → 「有哪些收藏、什么顺序」
    final bookmarkState = ref.watch(bookmarkProvider);
    final ready = bookmarkState.isReady;
    final list = ref.watch(bookmarkListProvider);

    // ── 🆕 收藏的内容**从服务端取**（2026-09-29 改）──
    //
    // 本页此前用 `mockFeedItems` 反查卡片 —— 它自己就写着
    // 「Phase 3 接真内容后，这里要改成『按 id 查内容』」。现在正是那一步。
    //
    // 🔴 **两个 `watch` 都在 build 顶层**（不放进 `when` 的回调里）。
    //    Riverpod 要求 `watch` 无条件执行 —— 放进条件分支会让
    //    「上一次 build 订阅了、这一次没订阅」这种状态漂移，
    //    表现为「有时候不刷新」且**不报错**。
    //    → 先取出 ids（可能为空），再算 key，再 watch。三者都是无条件的。
    final wantIds = <int>[];
    for (final b in list.valueOrNull ?? const <Bookmark>[]) {
      wantIds.add(b.contentId);
    }
    // 🔑 排序后 join → key 值稳定（同一批 id 任何顺序都命中同一缓存）
    wantIds.sort();
    final contentsAsync = ref.watch(feedByIdsProvider(wantIds.join(',')));

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理，这里只避让状态栏
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题栏（设计稿 `.bm-hd`：`display:flex; justify-content:space-between`
            //    左侧 `h2` 23/w600/字距-.015em · 右侧 `.back` 12/accent/w600）──
            //
            // 🔴 **2026-09-28 修正**：本页原先**没有任何返回入口**（按设计稿 mockup 走
            //    「子视图 + 无返回按钮」）→ 白哥实测「收藏列表根本没有返回按钮」。
            //
            // 🔑 **设计稿 CSS 里本来就定义了 `.bm-hd .back`**（返回链接样式），
            //    只是 mockup 那版没用它 —— 当时我把它判为「全屏方案的残留」而忽略，
            //    但它更可能是**留给实现补全的**。现在启用它。
            //
            // ⚠️ 位置在**右上角**（照设计稿的 `space-between`；iOS 惯例其实在左上）。
            //    改到左上只需把这个 `InkWell` 挪到 `children` 首位。
            //    🔑 返回现在有两条路：**边缘右滑**（转场自带，见 `theme_builder`
            //    的 `pageTransitionsTheme`）+ 本按钮；按钮是**可见的那一条**。
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '收藏',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 23 * -0.015,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  // 设计稿 `.bm-hd .back{font-size:12px;color:var(--accent);font-weight:600}`
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

            // ── 副标题（设计稿 `.bm-sub`：12 / ink3 / 行高 1.6；左右 16+6=22）──
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
              child: Text(
                '收藏的文章会一直留在这里，方便随时重读。',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  height: 1.6,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),

            // ── 内容 ──
            Expanded(
              child: list.when(
                // 首次加载（通常 < 100ms）→ **什么都不画**。
                // 🔴 不能在这里画空状态 —— 那会在有收藏时先闪一下
                //    「还没有收藏的文章」，是**对用户的谎报**。
                loading: () => const SizedBox.shrink(),
                // 库不可用 → 给一句**准确**的话，不冒充「没有收藏」。
                // ⚠️ 设计稿**未定义**此态 → 取最小诚实表达（同 `BookmarkButton`
                //    禁用态加透明度时的处理原则：不引入新语义，但也不撒谎）。
                error: (e, st) => const _Unavailable(),
                data: (bookmarks) {
                  // 没有收藏 → 空状态（与服务不可用**分开**表达）
                  if (bookmarks.isEmpty) return const _EmptyState();

                  // 🔑 收藏有，但要等**内容**从服务端回来。
                  //    这一层是**新加的**（数据源从 mock 改成 `/api/feed`）——
                  //    它可能失败，且失败**不是**「没有收藏」。
                  return contentsAsync.when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    // 🔴 内容取不到 → 明确说出来 + 可重试。
                    //    不要说成「没有收藏」—— 用户的收藏**还在**（端侧库里有），
                    //    只是**内容显示不出来**。这两件事对他完全不同。
                    error: (e, _) => _ContentUnavailable(
                      error: e,
                      onRetry: () => ref.invalidate(feedByIdsProvider(wantIds.join(','))),
                    ),
                    data: (byId) {
                      // 🔴 **按收藏顺序重排**，不依赖响应顺序 ——
                      //    后端按 `published_at DESC` 返回，而本页要的是
                      //    「收藏时间倒序」（那是端侧 `bookmark` 表的顺序）。
                      final items = <FeedItem>[];
                      final missing = <int>[];
                      for (final b in bookmarks) {
                        final it = byId[b.contentId];
                        if (it == null) {
                          missing.add(b.contentId);
                        } else {
                          items.add(it);
                        }
                      }
                      if (missing.isNotEmpty) {
                        // ⚠️ 「跳过」不等于「静默」：留日志便于排查
                        //    （内容池有保留期清理，旧收藏可能已无对应内容）
                        debugPrint('[bookmark_list] ${missing.length} 条收藏在服务端'
                            '无对应内容（可能已清理）→ 跳过：$missing');
                      }

                      // 全部取不到 → 说清楚是「内容没了」而不是「没有收藏」
                      if (items.isEmpty) return _AllMissing(count: bookmarks.length);
                      return _list(context, ref, items, ready);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 卡片列表（设计稿 `.feed` 16px 左右 + `.fcards` 13px 间距，与信息流**同一套**）。
  Widget _list(
    BuildContext context,
    WidgetRef ref,
    List<FeedItem> items,
    bool ready,
  ) {
    return ListView.separated(
      // 底部留出 tabbar 高度 —— `_ShellScaffold` 开了 `extendBody: true`。
      // 依据见 `CoSpacing.tabBarClearance`（与三个 tab 页同一处理）。
      padding: const EdgeInsets.fromLTRB(16, 0, 16, CoSpacing.tabBarClearance),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 13),
      itemBuilder: (_, i) {
        final item = items[i];
        return FeedCard(
          item: item,
          // 清单里的卡片**必然已收藏**（数据来自收藏表）→ 书签恒为实心态
          bookmarked: true,
          // 🔴 库未就绪 → 传 `null` → 按钮禁用（不传「点了没反应」的回调）
          onToggleBookmark: ready
              ? () => toggleBookmarkWithToast(context, ref, item.id)
              : null,
          // 点卡片 → 阅读器（与信息流一致）
          onTap: () => context.push('/article/${item.id}'),
        );
      },
    );
  }
}

/// 空状态 —— 设计稿 `.empty`。
///
/// 🔑 设计稿对空状态的要求不是「告诉用户没有内容」，而是
/// 「**教会用户书签在哪**」→ 所以末尾那行**引导**（含一个**真实样式的书签方块**）
/// 是这一屏的重点，不是装饰。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return SingleChildScrollView(
      // 设计稿 `.empty{padding:52px 22px;text-align:center}`
      padding: const EdgeInsets.fromLTRB(22, 52, 22, 52),
      child: Column(
        children: [
          // ── 粘土**凹陷**圆环（设计稿 `.empty .ring`：74×74 圆形 + 两个 inset）──
          //
          // 🔑 用 `Clay(pressed)` 而不是手写 `BoxShadow(blurStyle: inner)`：
          //    · 凹陷的 inset 方向、色值、几何缩放**都由 token 决定**（三档自动适配）
          //    · 手写会把「墨/格/夜」三套数值复制到页面层，改 token 时漏改
          //    ⚠️ 设计稿把 inset 写死为 `4px 4px 10px` / `-3px -3px 8px`；
          //       本实现按项目惯例**取 token 的缩放档**（同 `_ClayTabBar` 选中态的处理：
          //       spec §3.3.1 明文「选中态与默认态共用同一套内阴影」）。
          SizedBox(
            width: 74,
            height: 74,
            child: Clay(
              state: ClayState.pressed,
              fill: t.sunken,
              // 圆形：半径 = 74 / 2。几何仍成立（偏移 ≤ 半径，§3.4 约束）
              borderRadius: BorderRadius.circular(37),
              child: Center(
                child: Icon(
                  Icons.bookmark_border,
                  size: 26,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          Text(
            '还没有收藏的文章',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: 9),

          ConstrainedBox(
            // 设计稿 `.empty p{max-width:250px}`
            constraints: const BoxConstraints(maxWidth: 250),
            child: Text(
              '读到喜欢的文章，点右上角的书签就能存下来，以后随时回来重读。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                height: 1.7,
                color: Color(t.ink2.argb32),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── 引导行（设计稿 `.empty .hint`：gap 7 · 12 / ink3）──
          // 「在卡片上找这个 [书签方块] 图标」——设计稿要求**用真实图标**，
          // 让用户下次一眼认出来。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '在卡片上找这个',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  color: Color(t.ink3.argb32),
                ),
              ),
              const SizedBox(width: 7),
              _HintBookmarkChip(t: t),
              const SizedBox(width: 7),
              Text(
                '图标',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 引导行里的**小书签方块**（设计稿 `.empty .hint .bm`：24×24 · 图标 12）。
///
/// 🔑 **刻意不复用 `BookmarkButton`** —— 那个是**带状态与交互语义的控件**
/// （`onPressed: null` 会走「禁用」分支：透明度 0.45 + 去掉按下动效，
/// 而设计稿这里要的是**正常观感**的示意图形，不是「禁用的按钮」）。
/// 用一个装饰性小方块反而更诚实：**它本来就不可点**。
///
/// 但**沿用同一视觉语言**（比例取自 `.bm`，30px 基准）：
/// · 圆角 `10 × 24/30 = 8`
/// · 图标 `15 × 24/30 = 12`
/// · 底 `sunken` + `Clay(pressed)`（未收藏的书签就是凹陷的）
class _HintBookmarkChip extends StatelessWidget {
  const _HintBookmarkChip({required this.t});

  final CoEvoTokens t;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Clay(
        state: ClayState.pressed,
        fill: t.sunken,
        borderRadius: BorderRadius.circular(8),
        child: Center(
          child: Icon(
            Icons.bookmark_border,
            size: 12,
            color: Color(t.ink3.argb32),
          ),
        ),
      ),
    );
  }
}

/// 库不可用 —— **设计稿未定义此态**，取最小诚实表达。
///
/// 🔴 为什么不能沿用空状态的「还没有收藏的文章」：那是**谎报** ——
/// 用户可能明明收藏过，只是库暂时打不开。本项目的既定原则：
/// 「**静默失败 / 误导性提示 比报错更糟**」（见 `bookmark_provider` 的类注释）。
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '收藏暂时读不出来，重启应用可再试。',
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

/// **收藏还在，但内容取不到**（`/api/feed?ids=` 失败）。
///
/// # 🔴 与 [_Unavailable] 的区别（不能合并成一个）
/// | | 加载的是什么 | 用户的收藏还在吗 |
/// |---|---|---|
/// | [_Unavailable] | **端侧库**打不开 | 不确定（库都读不到） |
/// | **本组件** | **服务端内容**取不到 | ✅ **在**（就在本机 `bookmark` 表里） |
///
/// 对用户而言「我的收藏丢了」和「收藏在、但内容显示不出来」是两件事：
/// 前者恐慌，后者只是等一下。所以文案要说清**收藏没丢**。
class _ContentUnavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ContentUnavailable({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final isNetwork = error is ContentApiException &&
        (error as ContentApiException).statusCode == 0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNetwork ? Icons.wifi_off : Icons.cloud_off,
              size: 28,
              color: Color(t.ink3.argb32),
            ),
            const SizedBox(height: CoSpacing.md),
            Text(
              // 🔑 第一句就先安抚 —— 用户最怕的是「收藏没了」
              '你的收藏还在',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.sm),
            Text(
              isNetwork ? '内容需要联网读取，现在连不上。\n检查网络后再试。' : '内容服务暂时不可用。\n稍后再试。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                height: 1.6,
                color: Color(t.ink3.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.lg),
            // ⚠️ 本页（阅读区）用**纯文字按钮**，不用粘土 ——
            //    spec §八「阅读区容器内不得出现粘土类」。
            TextButton(
              onPressed: onRetry,
              child: Text(
                '重试',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(t.accent.argb32),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// **收藏的内容全都不在了**（服务通了，但这些 id 在内容池里都查不到）。
///
/// 典型成因：内容池有保留期清理 → 很久以前收藏的文章被清掉了。
/// 🔑 与 [_EmptyState]（「还没有收藏」）分开：这里**有收藏**，只是内容没了。
///    文案要给出「为什么」——否则用户会以为收藏功能坏了。
class _AllMissing extends StatelessWidget {
  final int count;

  const _AllMissing({required this.count});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          '你收藏的 $count 篇文章已不在内容库里。\n'
          '（旧文章会定期清理）',
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
