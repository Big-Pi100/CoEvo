/// 复习「翻卡」—— **全屏顶层路由**（`/review/session`，在 shell 之外）。
///
/// # 🔴 为什么是顶层路由而不是复习页内的一个状态（2026-09-28 修正）
///
/// 白哥真机报：「四键被底部栏遮住了，**拉动也出不来**」。
///
/// 根因：原先翻卡是 `review_screen` 里用 `bool _inCard` 切换的**页内状态** →
/// 它继承了「复习 tab 那一屏」的全部布局约束，其中包含
/// `_ShellScaffold` 的 `extendBody: true` + 底部 tabbar（约 100px）。
/// 而四键**固定在页面最底部、不参与滚动** → 被 tabbar 盖住且拉不出来。
///
/// 🔴 更根本的是：**设计稿的翻卡根本没有 tabbar** ——
/// `visual-word-card-target` 的 `.phone` 容器里只有 `pbar` + `pbody` + `card`
/// （`tabbar` / `nav` / `bottom` **0 命中**）→ 翻卡是**全屏沉浸态**。
///
/// 🔑 所以修法是结构性的：**提升为顶层路由** → 天然全屏。
///    这与项目既有模式一致（`app.dart` 的阅读器 `/article/:id` 同理：
///    「覆盖全屏的沉浸态 → 顶层路由」）。
///
/// ## 🔑 教训：**「页内状态」会静默继承所在页面的布局约束**
/// 用它表示「另一个界面」时，那些约束（这里是 tabbar）会跟着来，而**编译器不报错**。
/// 判断依据就是项目已定的那条：**它是不是 tab 的内容**
/// （是 → 页内状态；否 → 顶层路由）。
///
/// # 四键位置：**固定在页面底部**（不随内容滚动）
/// 这是设计意图，不是实现偶然：
/// · 设计稿：「四个按钮各标出『下次什么时候再见』」→ 它们是**决策动作**，
///   必须**始终可达**；
/// · 若跟着内容滚，用户滚到词源链中段时四键就跑出视野 → **没法评分**。
/// → 内容区（①~④）自己滚，四键固定。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/review_list_provider.dart';
import '../providers/review_session_provider.dart';
import '../providers/user_db_provider.dart';
import '../services/fsrs_service.dart';
import '../services/review_list_query.dart';
import '../services/tts_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/word_card.dart';

class ReviewSessionScreen extends ConsumerStatefulWidget {
  const ReviewSessionScreen({super.key});

  @override
  ConsumerState<ReviewSessionScreen> createState() =>
      _ReviewSessionScreenState();
}

class _ReviewSessionScreenState extends ConsumerState<ReviewSessionScreen> {
  /// 正在提交 → 四键禁用（防连点造成重复写库 / 重复计数）
  bool _submitting = false;

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    // 🔴 退出翻卡时**刷新列表** —— 本次会话可能已改了若干词的到期时间，
    //    不刷新的话返回列表看到的还是旧顺序（用户会以为「评了没用」）。
    //    ⚠️ 放在 `dispose` 而不是各退出路径：退出路径有**三条**
    //      （返回按钮 / 系统返回手势 / 评完最后一张自动退出），
    //      分散在三处写 = 迟早漏一处。
    try {
      ref.invalidate(reviewListProvider);
      ref.invalidate(reviewDueCountProvider);
    } catch (_) {
      // provider 容器已销毁（如整棵树被替换）→ 无需刷新
    }
    super.dispose();
  }

  /// 提交一次评级：算新状态 → **写两张表** → 自动下一张。
  Future<void> _submit(ReviewRating rating) async {
    if (_submitting) return;
    final row = ref.read(reviewSessionProvider).current;
    if (row == null) return;

    setState(() => _submitting = true);
    try {
      final svc = ref.read(fsrsServiceProvider);
      final now = svc.nowUtc();
      // `review()` = apply + 产出同步事件（与四键预览**同一套确定性抖动**）
      final r = svc.review(rating, row.item.toReviewState(), now);

      final db = await ref.read(userDbProvider.future);
      final q = ReviewListQuery(db);

      // 🔴 两张表都要写，缺一不可：
      //    · `card_review_state` = 当前状态（复习页排序的唯一依据）
      //    · `review_log`       = 评级流水（多端同步的最小单位 + 「今天复习了几个」）
      //    只写前者 → **历史永久丢失**（重放需要每一次评级的时间与档位）。
      await q.upsertState(
        wordId: row.item.wordId,
        spelling: row.item.spelling,
        state: r.state.state,
        step: r.state.step,
        stability: r.state.stability,
        difficulty: r.state.difficulty,
        reps: r.state.reps,
        lapses: r.state.lapses,
        lastReviewAt: r.state.lastReviewAt,
        nextReviewAt: r.state.nextReviewAt,
      );
      await q.logReview(r.event);
    } catch (e, st) {
      // 🔴 失败**不静默、不前进** —— 用户再点一次就是重试
      debugPrint('[review_session] 提交评级失败：$e\n$st');
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('这一张没记上，再点一次试试。'),
            duration: Duration(seconds: 2),
          ));
      }
      return;
    }

    if (!mounted) return;

    // 自动下一张；已到队尾 → 退出（`dispose` 会刷新列表）
    final hasNext = ref.read(reviewSessionProvider.notifier).next();
    if (hasNext) {
      setState(() => _submitting = false);
      // 新卡从顶部开始看（否则会停在上一张滚到的位置）
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else {
      setState(() => _submitting = false);
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final session = ref.watch(reviewSessionProvider);
    final bundle = ref.watch(cardBundleProvider);

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 🔑 全屏路由 → **要**避让底部系统安全区（home indicator）。
        //    ⚠️ 页内状态那版写的是 `bottom: false`（因为 tabbar 会挡），
        //    现在没有 tabbar 了 → 必须避让，否则四键压在 home indicator 上。
        child: Column(
          children: [
            _topBar(t, session),
            Expanded(
              child: bundle.when(
                loading: () => const _CardLoading(),
                // provider 内部已 catch 并返回 null → 这里不会收到 error
                error: (e, st) => const _CardUnavailable(),
                data: (b) => b == null
                    ? const _CardUnavailable()
                    : WordCardView(
                        card: b.card,
                        profile: b.profile,
                        previews: b.previews,
                        mnemonicNames: b.names,
                        ratingEnabled: !_submitting,
                        onRate: _submit,
                        onSpeak: () => _speak(b.card.spelling),
                        scrollController: _scroll,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部：退出 + 进度「复习 · 7 / 23」。
  Widget _topBar(CoEvoTokens t, ReviewSessionState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Row(
        children: [
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
          Expanded(
            child: Text(
              // 分母取自**快照** → 不会因提交而变（见 `ReviewSessionState.queue`）
              '复习 · ${s.index + 1} / ${s.total}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(t.ink2.argb32),
              ),
            ),
          ),
          // 与左侧「返回」大致等宽，让进度视觉居中
          const SizedBox(width: 46),
        ],
      ),
    );
  }

  /// 朗读单词 —— **词卡朗读属免费层能力**（见 MEMORY 变现段：
  /// 「免费层：生词本 200 词 + **词卡朗读** + 电子书导入」）→ 这里不做订阅判断。
  ///
  /// ⚠️ 失败只记日志：朗读失败不该打断复习。
  void _speak(String word) {
    if (!ref.read(ttsEnabledProvider)) return;
    ref.read(ttsServiceProvider).speak(word).catchError((Object e) {
      debugPrint('[review_session] 朗读失败 "$word"：$e');
    });
  }
}

/// 卡片加载中 —— 词库首次落盘要 0.5–2 s（31.4 MB），这段时间必须**有反馈**。
class _CardLoading extends StatelessWidget {
  const _CardLoading();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(t.accent.argb32),
        ),
      ),
    );
  }
}

/// 卡片取不出来 —— **给准确的话**，不空白、不假装正常。
///
/// 两种真实成因：
/// · 词库还没就绪 / 落盘失败
/// · 词库里没有这个词（数据不一致：词库升级时删过词）
class _CardUnavailable extends StatelessWidget {
  const _CardUnavailable();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '这张卡暂时打不开。\n若一直这样，可能是词库还在准备 —— 返回列表稍后再试。',
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
