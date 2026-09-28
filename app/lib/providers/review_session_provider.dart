// CoEvo · 复习「翻卡会话」的状态
//
// # 🔴 为什么需要它（2026-09-28 · 白哥真机报「四键被底部栏遮住」）
//
// 翻卡态原先的实现在 `review_screen` 里用 `bool _inCard` 切换 ——
// **看起来**没问题，但它让翻卡变成了「复习 tab 内的一屏」，于是：
// · 底部 tabbar 照旧占着约 100px（`_ShellScaffold` 的 `extendBody: true`）→
//   四键（固定在页面最底部、不参与滚动）**被 tabbar 盖住，拉也拉不出来**
// · 🔴 而**设计稿的翻卡 mockup 里根本没有 tabbar**
//   （`visual-word-card-target` 的 `.phone` 容器：`pbar` + `pbody` + `card`，
//    `tabbar`/`nav`/`bottom` **0 命中**）→ 翻卡是**全屏沉浸态**
//
// 🔑 于是修法是结构性的：把翻卡从「页内状态」提升为**顶层路由**
//   （`/review/session`，挂在 shell **之外**）→ 天然全屏。
//   这与项目既有模式一致 —— 阅读器 `/article/:id` 正是这么做的：
//   > 「「阅读器」是**覆盖全屏的沉浸态**（spec §5.1「底部：无」）→ 顶层路由」
//
// 🔑 教训（值得单独记）：**「页内状态」会继承所在页面的所有布局约束** ——
//   用它表示「另一个界面」时，那些约束（这里是 tabbar）会**静默**跟着来。
//   判断依据：**它是不是 tab 的内容**（是 → 页内；否 → 顶层路由）。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/fsrs_service.dart';
import '../services/word_query_service.dart';
import 'review_list_provider.dart';
import 'word_db_provider.dart';

/// 一次复习会话：**队列快照 + 当前位置 + 当前卡的作答结果**。
///
/// # 🔑 为什么「作答结果」也放在这里（而不是页面自己 `setState`）
/// 因为它与「第几张」**必须同步重置**。
/// 若页面各管一份（`_index` 在 provider、`_answered` 在页面），
/// 换卡时忘了重置 `_answered` → 下一张会**直接显示上一张的结果**
/// （而且看起来「像是有内容」→ 不易察觉）。
/// 放一起 → `next()` 一次把两者都重置，**结构上不可能不同步**。
class ReviewSessionState {
  const ReviewSessionState({
    this.queue = const [],
    this.index = 0,
    this.answered = false,
    this.correct,
    this.submitted = '',
    this.nextReviewAt,
  });

  /// 🔴 **进入时的冻结快照**，不是活的列表。
  ///
  /// 为什么必须冻结：提交评级后该词的 `next_review_at` 变成未来 →
  /// 它会**离开「今天该复习」分组**。若队列是活的，
  /// `index` 指向的项每评一次就整体前移一位 →
  /// 出现「评完一张，下一张跳过了一个」这类**很难察觉**的错位。
  final List<ReviewRow> queue;

  final int index;

  // ── 当前卡的作答状态（`next()` 时全部重置）──

  /// 是否已提交（`true` = 显示结果态）
  final bool answered;

  /// 判定结果（`null` = 未提交）
  final bool? correct;

  /// 用户实际输入的原文（结果态要展示「你写的 vs 正确的」）
  final String submitted;

  /// 本次评级后的**新到期时间**（结果态展示「下次复习：X」）
  ///
  /// 🔑 这是**真实结果**（`FsrsService.apply` 的产出），不是预览 ——
  ///    所以屏幕上写的「下次 10 分钟」就是数据库里存的那个值。
  final DateTime? nextReviewAt;

  bool get isEmpty => queue.isEmpty;

  /// 当前这张（越界 → `null`）
  ReviewRow? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  /// 进度文案的分母（**取自快照** → 不会因提交而变）
  int get total => queue.length;
}

class ReviewSessionNotifier extends Notifier<ReviewSessionState> {
  @override
  ReviewSessionState build() => const ReviewSessionState();

  /// 开始一次会话：[rows] 是当前列表，[index] 是点中的那一项。
  void start(List<ReviewRow> rows, int index) {
    state = ReviewSessionState(queue: List.of(rows), index: index);
  }

  /// 记录当前卡的作答结果（进结果态）。
  void markAnswered({
    required bool correct,
    required String submitted,
    required DateTime nextReviewAt,
  }) {
    state = ReviewSessionState(
      queue: state.queue,
      index: state.index,
      answered: true,
      correct: correct,
      submitted: submitted,
      nextReviewAt: nextReviewAt,
    );
  }

  /// 前进一张。返回 `true` = 还有下一张；`false` = 已到队尾（调用方该退出页面）。
  ///
  /// 🔑 **一次把 `index` 与作答状态一起重置** —— 见 [ReviewSessionState] 的说明。
  ///
  /// ⚠️ 越界一律返回 `false` **并把 index 收敛到队尾** ——
  ///    让「越界」与「正常结束」走同一条退出路径，不留下一个越界的 index
  ///    被下一次 `build` 读到。
  bool next() {
    if (state.isEmpty) return false;
    final n = state.index + 1;
    if (n >= state.queue.length) {
      state = ReviewSessionState(
          queue: state.queue, index: state.queue.length - 1);
      return false;
    }
    // 作答状态**不带过去**（默认值即「未作答」）
    state = ReviewSessionState(queue: state.queue, index: n);
    return true;
  }

  void clear() => state = const ReviewSessionState();
}

final reviewSessionProvider =
    NotifierProvider<ReviewSessionNotifier, ReviewSessionState>(
  ReviewSessionNotifier.new,
);

// ─────────────────────────────────────────────────────────────
// 单张卡的数据（词条 + 槽位分配 + 四档预览）
// ─────────────────────────────────────────────────────────────

/// 一张卡渲染所需的全部数据 —— **一次取齐**。
///
/// ⚠️ **不再含四档预览**（2026-09-28 改）：评分方式从「自评四档」改为
/// **拼写判定**（对/错）→ 不需要预先算四个分支的间隔。
/// 结果态显示的是 `FsrsService.apply` 产出的**真实**新到期时间（不是预测）。
class CardBundle {
  const CardBundle({
    required this.card,
    required this.profile,
    required this.names,
  });

  final WordCard card;

  /// `null` = 该词无槽位分配记录（罕见）→ ①② 都不渲染，只剩 ③④
  final WordMnemonicProfile? profile;

  /// `mnemonic_type.code → 显示名`（从库读，不在 UI 硬编码）
  final Map<String, String> names;
}

/// 取**当前这张卡**的数据（含四档预览）。
///
/// # 依赖关系（为什么不是 `family(wordId)`）
/// 当前是哪张卡由 [reviewSessionProvider] 决定 → 直接 `watch` 它的 `current`。
/// 于是 `next()` 一调用，本 provider **自动重算** —— 不需要调用方
/// 记得「换卡后要重新取数据」（那正是最容易漏的一步）。
///
/// # ⚠️ 词库未就绪时**返回 `null`**（不是抛）
/// 调用方据此渲染「这张卡暂时打不开」。
/// 🔑 与列表项释义的处理**取向一致**：跨库依赖不该让页面崩，
///    但**必须给准确的话**（不是空白、不是假装正常）。
///
/// # 🔑 为什么把「算四档预览」也放这里
/// 它是纯粹的「状态 → 间隔」计算，与渲染无关。
/// 放在页面里会让**预览**与**提交**分散在两处 —— 而这两者**必须用同一套
/// scheduler 与同一套确定性抖动**（否则用户看到的「下次 14 天」是假的）。
/// 放在一起，才容易保证它们共用同一个 [fsrsServiceProvider]。
final cardBundleProvider = FutureProvider.autoDispose<CardBundle?>((ref) async {
  final row = ref.watch(reviewSessionProvider.select((s) => s.current));
  if (row == null) return null;

  // 词库要 31.4 MB 首次落盘（0.5–2 s）→ `watch` 它，就绪后自动重算
  final load = ref.watch(wordQueryProvider).valueOrNull;
  if (load is! WordDbReady) return null;

  try {
    final data = await load.service.reviewCardOf(row.item.wordId);
    if (data == null) return null; // 词库里没有这个词（数据不一致）
    final names = await load.service.mnemonicTypeNames();

    return CardBundle(
      card: data.card,
      profile: data.profile,
      names: names,
    );
  } catch (e, st) {
    debugPrint('[review_session] 加载卡片失败 wordId=${row.item.wordId}：$e\n$st');
    return null;
  }
});

/// 全应用共用的 **FSRS 服务实例**。
///
/// # 🔑 为什么用 provider 而不是各自 `FsrsService()`
/// `FsrsService` 的构造会建一个 `Scheduler`（含解析参数）。
/// 共用一个实例让「提交用的参数」**只有一个来源** ——
/// 而不是「碰巧两处都写了默认值」。
///
/// ⚠️ 注意：即使两个实例，结果也一样 —— 因为 `_deterministicFuzz`
///    按 `cardId` 哈希算，是**纯函数**（不依赖实例状态）。
///    共用是为了**表达「只有一个来源」**，不是正确性必需。
///    （这一点如实写明，免得后人以为「换两个实例会出错」。）
final fsrsServiceProvider = Provider<FsrsService>((ref) => FsrsService());
