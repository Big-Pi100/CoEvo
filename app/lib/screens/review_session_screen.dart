/// 复习「翻卡」—— **全屏顶层路由**（`/review/session`，在 shell 之外）。
///
/// # 🔴 为什么是顶层路由而不是复习页内的一个状态（2026-09-28 修正）
///
/// 白哥真机报：「四键被底部栏遮住了，**拉动也出不来**」。
///
/// 根因：原先翻卡是 `review_screen` 里用 `bool _inCard` 切换的**页内状态** →
/// 它继承了「复习 tab 那一屏」的全部布局约束，其中包含
/// `_ShellScaffold` 的 `extendBody: true` + 底部 tabbar（约 100px）。
/// 而底部操作区**固定在页面最底部、不参与滚动** → 被盖住且拉不出来。
///
/// 🔴 更根本的是：**设计稿的翻卡根本没有 tabbar** ——
/// `visual-word-card-target` 的 `.phone` 容器里只有 `pbar` + `pbody` + `card`
/// （`tabbar` / `nav` / `bottom` **0 命中**）→ 翻卡是**全屏沉浸态**。
///
/// 🔑 所以修法是结构性的：**提升为顶层路由** → 天然全屏。
///    与项目既有模式一致（`app.dart` 的阅读器 `/article/:id` 同理）。
///
/// ## 🔑 教训：**「页内状态」会静默继承所在页面的布局约束**
/// 用它表示「另一个界面」时，那些约束（这里是 tabbar）会跟着来，而**编译器不报错**。
/// 判断依据就是项目已定的那条：**它是不是 tab 的内容**
/// （是 → 页内状态；否 → 顶层路由）。
///
/// # 🔴 考核取代了自评（白哥 2026-09-28）
/// 白哥原话：「这四个按钮没有用，还是要用**考试**（**单纯的拼写考核**即可）」
///
/// 于是评分不再由用户点四档给出，而是由**拼写判定器**给出：
/// 拼对 → `good`｜拼错 → `again`（见 `spelling_grader.dart`）。
/// 🔑 FSRS 本身不变（官方 `fsrs 2.0.1`，FSRS-6）——
///    变的是**喂给它的信号**：从「主观自评」变成「客观答题结果」。
///
/// # 三种阶段（**全部从状态推出，没有额外 setState 同步**）
/// | 阶段 | 条件 | 显示 |
/// |---|---|---|
/// | **考核** | 词**已到期** 且 未作答 | 只有释义 + 音标（**不给单词、不给记忆法、不给语境句**）+ 输入框 |
/// | **结果** | 已作答 | 对/错 + 你写的 vs 正确 + 下次复习时间 + **完整四段卡**（学一下） |
/// | **浏览** | 词**未到期** | 完整四段卡（不考核、**不写 FSRS** —— 白哥定「未到期的不考」） |
///
/// 🔑 阶段不存成字段，而是**由 `(isDue, answered)` 两个已有状态推出** ——
///    存字段就要在换卡时手动重置，而「忘了重置」会让下一张直接显示上一张的结果
///    （看起来「像是有内容」→ 不易察觉）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:async';

import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../providers/device_id_provider.dart';
import '../providers/review_list_provider.dart';
import '../providers/review_session_provider.dart';
import '../providers/user_db_provider.dart';
import '../services/fsrs_service.dart';
import '../services/review_list_query.dart';
import '../services/spelling_grader.dart';
import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/theme_builder.dart';
import '../theme/tokens_ext.dart';
import '../widgets/word_card.dart';

class ReviewSessionScreen extends ConsumerStatefulWidget {
  const ReviewSessionScreen({super.key});

  @override
  ConsumerState<ReviewSessionScreen> createState() =>
      _ReviewSessionScreenState();
}

class _ReviewSessionScreenState extends ConsumerState<ReviewSessionScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 提交/写库进行中 → 禁用输入与按钮（防连点造成重复写库 + 重复计数）
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    // ⚠️ 这里**不再**刷新复习列表 —— 刷新已改为「提交成功即 bump 修订号」
    //    （见 `_submit`）。原先放在 `dispose` 是怕退出路径有三条会漏一处，
    //    但那个理由换来的是**更脆的时机**：`dispose` 时 `ref` 临近失效，
    //    通知能否送达依赖 widget 生命周期细节 —— 表现为「评完返回列表还是旧的」。
    //    🔑 现在退出路径一条也不需要管：数据一变，读端自己就跟上了。
    //    （两套机制并存的坏处见 `user_db_provider.dart` 的 `UserDbRevision`。）
    super.dispose();
  }

  /// 提交一次作答：判定 → 算新状态 → **写两张表** → 进结果态。
  ///
  /// 🔴 只在**考核态**调用（未到期的词走浏览态，不写 FSRS —— 白哥定）。
  Future<void> _submit(ReviewRow row) async {
    if (_busy) return;

    final typed = _input.text;
    final correct = gradeSpelling(typed, row.item.spelling);
    final rating = ratingForSpelling(correct: correct);

    // 🔑 **在任何 `await` 之前**取到 notifier 引用（同 `reader_screen._writeBackLookup`）：
    //    下面有两次 `await` 写库，期间用户可能按返回退出 → `ref` 失效。
    //    拿着 notifier **实例**引用则不受影响（`userDbRevisionProvider`
    //    是非 autoDispose，生命周期与 app 一致）。
    final revision = ref.read(userDbRevisionProvider.notifier);
    // 🔑 同理提前取（成就解锁队列的 notifier 实例与 app 同生命周期）
    final unlockNotifier = ref.read(achievementUnlockProvider.notifier);

    setState(() => _busy = true);
    try {
      final svc = ref.read(fsrsServiceProvider);
      final now = svc.nowUtc();
      // 🔑 匿名设备标识 —— 写进 `review_log.device_id`（多端同步的**冲突判定**键，
      //    也是服务端去重统计的来源）。取不到就传 `null` →
      //    `ReviewEvent.toRow` 落成 `''`，**与升级前完全一致**（不是新故障）。
      final deviceId = await deviceIdOrNull(ref);
      final r = svc.review(rating, row.item.toReviewState(), now,
          deviceId: deviceId);

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

      // 🔴 **写库成功之后**再 bump（顺序不可颠倒：先 bump 会让列表在写入
      //    完成前重查一次，查到的还是旧值，而修订号已经变过 → 不会再重算一次
      //    → 表现为「这一次没刷新」）。
      //
      // 🔑 在这里 bump，而不是等页面 `dispose`（此前是那样）：数据在**提交成功
      //    那一刻**就变了，把「让界面知道」押在「页面被销毁」上是错配的时机 ——
      //    `dispose` 时 `ref` 临近失效，能否可靠送达依赖 widget 生命周期细节。
      //    这也是白哥报的「考试后状态要切一下才变」的根因之一。
      // ⚠️ 用**提前取好的** notifier 引用（见方法开头）—— 不用 `ref`，
      //    因为这两次 `await` 期间页面可能已被销毁。
      revision.bump();

      // 🔑 成就检查放在**写库成功之后**（与 bump 同理：「数据变了」才是检查时机）。
      //    `unawaited` —— 不让成就查询拖慢「提交 → 下一张」的节奏；
      //    失败在 `checkAndRefreshAchievements` 内被 catch（成就永不影响复习主流程）。
      unawaited(_checkAchievements(unlockNotifier));

      if (!mounted) return;
      ref.read(reviewSessionProvider.notifier).markAnswered(
            correct: correct,
            submitted: typed,
            nextReviewAt: r.state.nextReviewAt,
          );
      // 回顶部 —— 结果态的内容从「对/错」开始看
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e, st) {
      // 🔴 失败**不静默、不前进** —— 用户再点一次就是重试
      debugPrint('[review_session] 提交失败：$e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('这次没记上，再点一次试试。'),
            duration: Duration(seconds: 2),
          ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 检查成就解锁并入队（**不阻塞复习流程**）。
  ///
  /// 🔑 队列 notifier 由调用方传入（**不用 `ref`**）：
  ///    本方法是 `unawaited` 的，期间页面可能已销毁 → `ref` 失效。
  ///    notifier **实例**的存活与 widget 无关（与 `revision` 同一处理）。
  Future<void> _checkAchievements(AchievementUnlockNotifier notifier) async {
    final newly = await checkAndRefreshAchievements(ref);
    if (newly.isEmpty) return;
    notifier.pushAll(newly);
  }

  /// 下一张；已到队尾 → 退出（`dispose` 会刷新列表）。
  void _next() {
    _input.clear();
    final hasNext = ref.read(reviewSessionProvider.notifier).next();
    if (hasNext) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else {
      context.pop();
    }
  }

  // 🔄 2026-09-28 21:4x：**删除 `_speak` 与两处 `onSpeak` 传参**。
  //
  // 🔑 朗读（词卡朗读属**免费层**能力，见 MEMORY 变现段）现在由
  //    `SpeakButton` 自包含实现 —— 词头 / ④ 语境 / 搭配每条各自一个。
  //
  // ⚠️ 关于「考核态不显示喇叭（会念出答案）」：`WordPromptView` 本身
  //    不含词头与语境，天然没有喇叭，**不需要再靠传参控制**。
  //
  // 🔑 朗读从「页面注入回调」改为**自包含组件** `SpeakButton`
  //    （`widgets/speak_button.dart`，全库唯一一处定义）。
  //    原因：喇叭从 1 处扩到 5 处，且白哥定为**播放/停止切换** ——
  //    那要求每个喇叭知道「**当前在播的是不是自己**」（否则 5 个会一起亮），
  //    而 `VoidCallback` 不带状态、做不到。
  // ⚠️ `SpeakButton` 内部已做 `ttsEnabledProvider` 检查（关朗读就不渲染喇叭），
  //    所以这里原来的 `if (!ref.read(ttsEnabledProvider)) return;` 不再需要。

  /// 打开**聚合页**（词根族 / 词源族）—— 点卡片的 ① / ②。
  ///
  /// 🔑 用 **query 参数**传来处（而不是 `extra`）：纯字符串上下文可序列化，
  ///    走系统返回手势后也还在（`extra` 容易丢）。
  /// ⚠️ 两个值都要 `encodeComponent` —— 词里可能有空格/连字符
  ///    （实测 218 个词含空格或连字符，如 `according to`）。
  void _openAggregate(int pageId, String slotLabel, String word) {
    context.push(
      '/aggregate/$pageId'
      '?from=${Uri.encodeComponent(word)}'
      '&slot=${Uri.encodeComponent(slotLabel)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final s = ref.watch(reviewSessionProvider);
    final bundle = ref.watch(cardBundleProvider);
    final row = s.current;

    // 队列空（正常流程不会出现 —— `_openSession` 已挡掉越界）
    if (row == null) {
      return Scaffold(
        backgroundColor: Color(t.page.argb32),
        body: const SafeArea(child: _CardUnavailable()),
      );
    }

    final isDue = row.item.isDue(DateTime.now());

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      // 🔑 键盘弹出时自动避让 —— 否则输入框会被键盘盖住（考核态直接失效）
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        // 🔑 全屏路由 → **要**避让底部系统安全区（home indicator）。
        //    ⚠️ 页内状态那版写的是 `bottom: false`（因为 tabbar 会挡），
        //    现在没有 tabbar 了 → 必须避让。
        child: Column(
          children: [
            _topBar(t, s),
            Expanded(
              child: bundle.when(
                loading: () => const _CardLoading(),
                error: (e, st) => const _CardUnavailable(),
                data: (b) => b == null
                    ? const _CardUnavailable()
                    : _body(t, s, b, row, isDue: isDue),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    CoEvoTokens t,
    ReviewSessionState s,
    CardBundle b,
    ReviewRow row, {
    required bool isDue,
  }) {
    // ── 结果态（已作答）──
    if (s.answered) {
      return Column(
        children: [
          _ResultBanner(
            t: t,
            correct: s.correct ?? false,
            submitted: s.submitted,
            expected: row.item.spelling,
            nextReviewAt: s.nextReviewAt,
          ),
          Expanded(
            child: WordCardView(
              card: b.card,
              profile: b.profile,
              mnemonicNames: b.names,
              scrollController: _scroll,
              // 判定后**可以**点 ① / ② 展开聚合页 —— 同上，答案已经揭晓
              onOpenAggregate: (pageId, slotLabel) =>
                  _openAggregate(pageId, slotLabel, b.card.spelling),
              footer: _NextBar(label: '下一个', onTap: _next),
            ),
          ),
        ],
      );
    }

    // ── 浏览态（词未到期 → 只看不考，不写 FSRS）──
    if (!isDue) {
      return WordCardView(
        card: b.card,
        profile: b.profile,
        mnemonicNames: b.names,
        scrollController: _scroll,
        onOpenAggregate: (pageId, slotLabel) =>
            _openAggregate(pageId, slotLabel, b.card.spelling),
        footer: _NextBar(
          label: '下一个',
          hint: '还没到期 · ${_dueLabel(row.item.nextReviewAt, DateTime.now())}',
          onTap: _next,
        ),
      );
    }

    // ── 考核态（已到期 且 未作答）──
    return Column(
      children: [
        Expanded(
          child: WordPromptView(card: b.card, scrollController: _scroll),
        ),
        _answerBar(t, row),
      ],
    );
  }

  /// 作答区（固定在底部；键盘弹出时随 `resizeToAvoidBottomInset` 上移）。
  Widget _answerBar(CoEvoTokens t, ReviewRow row) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 14),
      child: Row(
        children: [
          Expanded(
            child: Clay(
              state: ClayState.pressed,
              fill: t.sunken,
              borderRadius: BorderRadius.circular(13),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: TextField(
                controller: _input,
                autofocus: true,
                enabled: !_busy,
                // 🔴 三个「防作弊」开关 —— 都必须在**关闭**状态：
                //    · `autocorrect`       自动纠错 → 会把拼错的**改成对的**（考核失效）
                //    · `enableSuggestions` 联想条 → 会**提示正确拼写**（等于给答案）
                //    · `textCapitalization` 首字母自动大写 → 干扰输入
                //      （本判定大小写不敏感，所以不构成误判，但仍不该替用户改输入）
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(row),
                style: TextStyle(
                  fontFamily: CoFonts.latinSerif,
                  fontSize: 18,
                  color: Color(t.ink.argb32),
                ),
                // 🔴 同上（`review_screen.dart` 搜索框）：本输入框 `autofocus: true`
                //    → 进页面即处于聚焦态，只写 `border: InputBorder.none`
                //    会让 theme 的 `focusedBorder`（朱砂 1.6px）直接显形。
                //    根因与判据 → `theme_builder.dart` 的 `borderlessInputDecoration`
                decoration: borderlessInputDecoration(
                  hintText: '拼出这个单词',
                  hintStyle: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 14,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Clay(
            state: ClayState.selected,
            borderRadius: BorderRadius.circular(13),
            onTap: _busy ? null : () => _submit(row),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            child: _busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      // 🔑 走 token（`accentInk` = 强调色上的前景色）——
                      //    不写 `Colors.white`：本项目页面层**零硬编码色**
                      color: Color(t.accentInk.argb32),
                    ),
                  )
                : Text(
                    '确认',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(t.accentInk.argb32),
                    ),
                  ),
          ),
        ],
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

  /// 到期文案（与复习列表同一套说法）。
  static String _dueLabel(DateTime nextAt, DateTime now) {
    final d = nextAt.difference(now.toUtc());
    if (d.inMinutes <= 0) return '现在';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟后';
    if (d.inHours < 24) return '${d.inHours} 小时后';
    if (d.inDays < 30) return '${d.inDays} 天后';
    final months = (d.inDays / 30).round();
    if (months < 12) return '$months 个月后';
    return '${(d.inDays / 365).round()} 年后';
  }
}

// ════════════════════════════════════════════════════════════════
// 子组件
// ════════════════════════════════════════════════════════════════

/// 结果横幅：对/错 + 你写的 vs 正确 + **本次评级后的真实下次时间**。
///
/// 🔑 三样都是「用户此刻最需要知道的事」：
/// · **对/错** —— 唯一的结果
/// · **正确拼写** —— 错了却不显示正确答案，这个错误就**毫无价值**
/// · **下次复习时间** —— 让用户看到「这一答的后果」
///    （原先四键上那层「看到后果」的意思没丢：只是从「选项的预览」变成「已发生的事实」）
class _ResultBanner extends StatelessWidget {
  const _ResultBanner({
    required this.t,
    required this.correct,
    required this.submitted,
    required this.expected,
    required this.nextReviewAt,
  });

  final CoEvoTokens t;
  final bool correct;

  /// 用户输入（**原文** —— 不做归一化展示，让用户看到自己到底打了什么）
  final String submitted;

  final String expected;
  final DateTime? nextReviewAt;

  @override
  Widget build(BuildContext context) {
    final next = nextReviewAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                correct ? Icons.check_circle_outline : Icons.cancel_outlined,
                size: 20,
                color: Color((correct ? t.accent : t.ink2).argb32),
              ),
              const SizedBox(width: 8),
              Text(
                correct ? '拼对了' : '拼错了',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Color(t.ink.argb32),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 对了的话「你写的」与正确答案一样，展示是重复 → 只在错时显示
          if (!correct) ...[
            Text(
              '你写的：$submitted',
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 15,
                color: Color(t.ink2.argb32),
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (!correct)
                Text(
                  '正确：',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 13,
                    color: Color(t.ink2.argb32),
                  ),
                ),
              Text(
                expected,
                style: TextStyle(
                  fontFamily: CoFonts.latinSerif,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(t.accent.argb32),
                ),
              ),
            ],
          ),
          if (next != null) ...[
            const SizedBox(height: 8),
            Text(
              // 🔑 这是 `FsrsService.apply` 的**真实产出**（不是预览）——
              //    屏幕上写的就是数据库里存的那个值
              '下次复习：${formatInterval(next.difference(DateTime.now().toUtc()))}',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                color: Color(t.ink3.argb32),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 底部固定条：「下一个」+ 可选提示（如「还没到期 · 4 天后」）。
class _NextBar extends StatelessWidget {
  const _NextBar({required this.label, required this.onTap, this.hint});

  final String label;
  final VoidCallback onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 14),
      child: Row(
        children: [
          if (hint != null)
            Expanded(
              child: Text(
                hint!,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  color: Color(t.ink3.argb32),
                ),
              ),
            )
          else
            const Spacer(),
          Clay(
            state: ClayState.selected,
            borderRadius: BorderRadius.circular(13),
            onTap: onTap,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(t.accentInk.argb32),
              ),
            ),
          ),
        ],
      ),
    );
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
