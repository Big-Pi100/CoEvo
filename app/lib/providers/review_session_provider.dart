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

import '../services/external_word_card.dart';
import '../services/fsrs_service.dart';
import '../services/highlight_id.dart';
import '../services/highlight_repository.dart';
import '../services/word_query_service.dart';
import 'review_list_provider.dart';
import 'user_db_provider.dart';
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
///
/// # 🆕 2026-10-07：改成 **sealed**（词卡 / 划线卡两种）
///
/// 划线的复习形态与词卡**完全不同**（提示是**首字母骨架**、判定是**默写**），
/// 而它们**共用同一个复习页与同一条 FSRS 链**。
///
/// 🔴 **为什么用 sealed 而不是「给一个可空的 `highlight` 字段」**：
/// 后者要么让 `card` 变可空（每个用到处都得 `!`），要么给划线卡硬造一张
/// **空壳 `WordCard`**（`sections: []`、`spelling: 摘录`）——
/// 那正是本项目已经否掉的「**硬套形状 ⇒ 造一堆空字段**」。
/// ⇒ sealed 让**编译器**替我们找出「每一处该分流的渲染点」，而不是靠人记。
sealed class CardBundle {
  const CardBundle();
}

/// 词卡（`w0xxxxx` / `ext:<拼写>`）。
class WordCardBundle extends CardBundle {
  const WordCardBundle({
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

/// 划线卡（`hl:<uuid>`）。
///
/// 🔑 它**不经过词库** ⇒ 词库还在首次落盘（31.4 MB，0.5–2 s）时，
///    划线卡**照样能复习**（词卡要等词库就绪）。
class HighlightCardBundle extends CardBundle {
  const HighlightCardBundle(this.highlight);

  final Highlight highlight;
}

/// 复习页取卡的**三态**。
///
/// # 🔴 为什么要把 `CardBundle?` 换成三个类型（2026-10-09）
/// 旧实现用**一个 `null` 同时表示两件完全不同的事**：
/// · 词库还没落盘（首次 31.4 MB / 0.5–2 s）→ 该**转圈**
/// · 真的取不到卡 → 该给**准确的话 + 出口**
///
/// 界面分不出来，只好把两者都渲染成「这张卡暂时打不开」——
/// 于是 `ext:`（**词库外**）的卡提示「可能是**词库**还在准备」，
/// 用户照提示「返回列表稍后再试」**永远不会好**（白哥 2026-10-09 真机报的就是这个）。
/// 📌 判据：**一个 `null` 承担两种语义 ⇒ 界面必然猜错原因**。
sealed class CardLoad {
  const CardLoad();
}

/// 词库尚未就绪 —— 该**转圈**（不是「打不开」）。
final class CardPreparing extends CardLoad {
  const CardPreparing();
}

/// 取不到卡 —— `message` 是**面向用户的准确原因**；`retryable` 决定给不给「重试」。
final class CardMissing extends CardLoad {
  const CardMissing(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
}

/// 拿到卡（词卡或划线卡）。
final class CardReady extends CardLoad {
  const CardReady(this.bundle);
  final CardBundle bundle;
}

/// 取**当前这张卡**的数据（含四档预览）。
///
/// # 依赖关系（为什么不是 `family(wordId)`）
/// 当前是哪张卡由 [reviewSessionProvider] 决定 → 直接 `watch` 它的 `current`。
/// 于是 `next()` 一调用，本 provider **自动重算** —— 不需要调用方
/// 记得「换卡后要重新取数据」（那正是最容易漏的一步）。
///
/// # ⚠️ 取不到时**不抛**，而是返回 [CardMissing]（**带准确原因**）
/// 🔑 与列表项释义的处理**取向一致**：跨库依赖不该让页面崩，
///    但**必须给准确的话**（不是空白、不是假装正常）。
///
/// # ⚠️ 唯一的例外：[ExternalCardUnavailable] 必须在这里接住
/// `cardById` 对 `ext:`（**词库外**）的词会在**联网取卡失败**时抛它 ——
/// 那里带着服务端的**准确文案**与「能否重试」。
/// 不接住的话它会被下面那个 `catch (e, st)` 吞成一个没有原因的失败
/// （= 又回到「界面猜原因」的老路）。
///
/// # 🔑 为什么把「算四档预览」也放这里
/// 它是纯粹的「状态 → 间隔」计算，与渲染无关。
/// 放在页面里会让**预览**与**提交**分散在两处 —— 而这两者**必须用同一套
/// scheduler 与同一套确定性抖动**（否则用户看到的「下次 14 天」是假的）。
/// 放在一起，才容易保证它们共用同一个 [fsrsServiceProvider]。
final cardBundleProvider = FutureProvider.autoDispose<CardLoad>((ref) async {
  final row = ref.watch(reviewSessionProvider.select((s) => s.current));
  if (row == null) return const CardMissing('复习队列里没有这一张卡。');

  final wordId = row.item.wordId;

  // ── 🆕 划线卡：走 `highlight` 表，**不碰词库**（也就不用等词库落盘）──
  if (isHighlightWordId(wordId)) {
    final uuid = highlightUuidOf(wordId);
    if (uuid == null) return const CardMissing('这张划线卡的数据不完整。');
    try {
      final db = await ref.read(userDbProvider.future);
      final h = await HighlightRepository(db).byId(uuid);
      // ⚠️ 已取消（`deleted`）的划线**也照常复习**：队列里那一行还在，
      //    此时说「打不开」比让用户复习一条他取消过的内容更没有帮助。
      //    （真正的清理是「取消时一并把队列行也处理掉」—— 当前**刻意不做**，
      //      因为「取消划线」不等于「不再复习」，见 schema 的软删说明。）
      if (h == null) return const CardMissing('这张划线卡已经不在了。');
      return CardReady(HighlightCardBundle(h));
    } catch (e, st) {
      debugPrint('[review_session] 加载划线失败 wordId=$wordId：$e\n$st');
      return const CardMissing('本机数据暂时读不出来，稍后再试。', retryable: true);
    }
  }

  // ── 词卡：要等词库就绪（31.4 MB 首次落盘 0.5–2 s）→ `watch` 它，就绪后自动重算 ──
  final loadAsync = ref.watch(wordQueryProvider);
  final load = loadAsync.valueOrNull;
  if (load is! WordDbReady) {
    // 🔴 「词库**打不开**」与「词库**还在准备**」必须分开：
    //    前者永远转不完（用户对着转圈白等），后者等一会儿就好。
    //    📌 旧实现两条都渲染成「打不开」，是同一个 `null` 的另一种表现。
    if (loadAsync.hasError) {
      return const CardMissing('词库打不开，这张卡暂时显示不了。', retryable: true);
    }
    return const CardPreparing();
  }

  try {
    final data = await load.service.reviewCardOf(wordId);
    // 词库里没有这个词（数据不一致：复习队列按 `word_id` 存的，却查不到）
    if (data == null) return const CardMissing('词库里没有这张卡的数据。');
    final names = await load.service.mnemonicTypeNames();

    return CardReady(
      WordCardBundle(
        card: data.card,
        profile: data.profile,
        names: names,
      ),
    );
  } on ExternalCardUnavailable catch (e) {
    // 🔴 **词库外**的词取不到卡 —— 原因与「词库」无关（它本来就在词库外），
    //    而是**联网取卡失败**。带服务端给的准确话 + 能不能重试。
    return CardMissing(e.message, retryable: e.retryable);
  } catch (e, st) {
    debugPrint('[review_session] 加载卡片失败 wordId=$wordId：$e\n$st');
    return const CardMissing('这张卡暂时读不出来，稍后再试。', retryable: true);
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
