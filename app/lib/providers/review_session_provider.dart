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

/// 一次复习会话：**队列快照 + 当前位置**。
class ReviewSessionState {
  const ReviewSessionState({this.queue = const [], this.index = 0});

  /// 🔴 **进入时的冻结快照**，不是活的列表。
  ///
  /// 为什么必须冻结：提交评级后该词的 `next_review_at` 变成未来 →
  /// 它会**离开「今天该复习」分组**。若队列是活的，
  /// `index` 指向的项每评一次就整体前移一位 →
  /// 出现「评完一张，下一张跳过了一个」这类**很难察觉**的错位。
  final List<ReviewRow> queue;

  final int index;

  bool get isEmpty => queue.isEmpty;

  /// 是否已到队尾（评完这张就该退出）
  bool get isLast => index >= queue.length - 1;

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

  /// 前进一张。返回 `true` = 还有下一张；`false` = 已到队尾（调用方该退出页面）。
  ///
  /// ⚠️ 越界一律返回 `false` **并把 index 收敛到队尾** ——
  ///    让「越界」与「正常结束」走同一条退出路径，不留下一个越界的 index
  ///    被下一次 `build` 读到。
  bool next() {
    if (state.isEmpty) return false;
    final n = state.index + 1;
    if (n >= state.queue.length) {
      state = ReviewSessionState(queue: state.queue, index: state.queue.length - 1);
      return false;
    }
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
/// 🔑 合成一个 bundle 而不是让页面查三次：三者**总是一起需要**
///   （没有 profile 就不知道该把哪两段放 ①②；没有 previews 四键就没数字）。
///   分开取只会让「忘了取某一个」变成一个静默的半成品界面。
class CardBundle {
  const CardBundle({
    required this.card,
    required this.profile,
    required this.previews,
    required this.names,
  });

  final WordCard card;

  /// `null` = 该词无槽位分配记录（罕见）→ ①② 都不渲染，只剩 ③④
  final WordMnemonicProfile? profile;

  /// 四档的「下次间隔」—— 直接喂给四键按钮
  final Map<ReviewRating, Duration> previews;

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

    final svc = ref.read(fsrsServiceProvider);
    return CardBundle(
      card: data.card,
      profile: data.profile,
      previews: svc.previewAll(row.item.toReviewState(), svc.nowUtc()),
      names: names,
    );
  } catch (e, st) {
    debugPrint('[review_session] 加载卡片失败 wordId=${row.item.wordId}：$e\n$st');
    return null;
  }
});

/// 全应用共用的 **FSRS 服务实例**。
///
/// # 🔑 共用是为了「明确表达」，而不是「正确性必需」
/// `FsrsService` 的「预览与提交一致」靠的是 `_deterministicFuzz`
/// —— 它**按 `cardId` 哈希**算抖动，是**纯函数**（不依赖实例状态）。
/// 所以即使两个实例，只要参数相同，结果也一样。
///
/// ⚠️ 但**共用仍然更好**：它把「预览和提交用的是同一套参数」
///    变成**结构上的事实**，而不是「碰巧两边都写了默认值」。
///    🔑 用一个 provider 表达这一点，比在两处各写 `FsrsService()` 更难出错。
final fsrsServiceProvider = Provider<FsrsService>((ref) => FsrsService());
