// CoEvo · 划线卡的「批量补译」—— 把还**没有译文**的划线一次补齐。
//
// # 它解决什么
// 划线卡的复习提示 = **中文译文 + 首字母骨架**（白哥 2026-10-11 定，**同时显示**）。
// 而译文是**可空的**（历史划线一条都没有）⇒ 需要一个入口把它们补齐，
// 否则「译文提示」这个能力对老用户永远不会生效。
//
// # 🔴 这不是免费操作 —— 成本模型决定了整个设计
// 翻译是**订阅权益**（免费 **10 次/月** · 订阅无限），`translation.rs` 的额度是
// **服务端按 UTC+8 月**计数的。「补译 N 条」= **消耗 N 次额度**。所以：
//   · **逐条串行**（不并发）—— 并发会同时占额度，且失败时定位不到是哪一条；
//   · **额度用尽即停**（不是「跳过继续」）—— 继续只会得到一串 403，
//     白白拖长等待，还让用户以为「卡住了」；
//   · 结果**如实回报**（成功 n / 额度用完 / 失败 m），**不含糊成「完成了」**。
//
// # 🔑 为什么不做「划线时自动翻译」
// 那会让「划线」这个**离线也能完成**的动作依赖网络与额度；
// 而且成本随划线量**线性增长** —— 用户随手划 100 条就烧掉 100 次额度。
// 「批量补译」把它变成用户**显式选择**的一次性动作，成本可见、可控。
//
// # ⚠️ 缓存会命中，这是好事
// `translateWithCache` 先查 `translation_cache` ⇒ **翻过、补过的句子不再花钱**。
// 所以「重复点补译」不会重复扣额度（只会把上次中断的补完）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/highlight_repository.dart';
import '../services/translate_parse.dart';
import 'translate_provider.dart';
import 'user_db_provider.dart';

/// 一次「批量补译」的结果 —— **如实回报**，不把部分成功说成成功。
class HighlightBackfillResult {
  const HighlightBackfillResult({
    required this.total,
    required this.ok,
    required this.failed,
    required this.stopMessage,
  });

  /// 本次**待补**的条数（= 调用时查出来的缺译文条数）。
  final int total;

  /// 成功补上译文的条数。
  final int ok;

  /// 单条失败（网络抖动 / 该句特别长）的条数 —— **不中断**整批。
  final int failed;

  /// 非空 = **提前停止**的原因（额度用尽 / 登录失效）。
  /// 文案尽量来自服务端（额度那条含「下月 1 日重置」）。
  final String? stopMessage;

  bool get stopped => stopMessage != null;

  /// 是否**全部**补完（没有任何中断、也没有失败）。
  bool get allDone => !stopped && failed == 0 && ok == total;

  /// 是否**无事可做**（调用时就一条都不缺）。
  bool get nothingToDo => total == 0;
}

/// **把缺译文的划线逐条补齐**。
///
/// [limit] 只用于测试/试跑（限制本次最多补几条）。
/// [onProgress] 每处理完一条回调一次（`done`, `total`）—— UI 用它显示进度。
Future<HighlightBackfillResult> backfillHighlightTranslations(
  WidgetRef ref, {
  int? limit,
  void Function(int done, int total)? onProgress,
}) async {
  final db = await ref.read(userDbProvider.future);
  final repo = HighlightRepository(db);
  final pending = await repo.withoutTranslation(limit: limit);

  var ok = 0;
  var failed = 0;
  String? stopMessage;

  for (var i = 0; i < pending.length; i++) {
    final h = pending[i];
    try {
      final outcome = await translateWithCache(ref, h.text);
      switch (outcome.result) {
        case TranslateReady(:final segments):
          // 🔑 `segments` **永远非空**（服务端保证至少一段）⇒ 不需要空判断分支。
          //    多段时用换行拼接 —— 译文是给人读的提示，保留分段更易读。
          final text = segments
              .map((s) => s.dst.trim())
              .where((s) => s.isNotEmpty)
              .join('\n');
          if (text.isEmpty) {
            // 服务端给了「成功」但内容是空白 —— 不写空串（那会与「没有译文」的
            // 消费口径打架：`withoutTranslation` 把空串也算缺）⇒ 记一次失败。
            failed++;
          } else {
            await repo.setTranslation(h.id, text);
            ok++;
          }
        case TranslateQuotaExceeded(:final message):
          // 🔴 额度用尽 ⇒ **立即停止**（继续只会连续 403）
          stopMessage = message;
        case TranslateNeedLogin():
          stopMessage = '登录已失效，请重新登录后再补译';
        case TranslateFailed():
          // 单条失败**不中断**：可能是这一句特别长，或一次网络抖动。
          failed++;
      }
    } catch (e) {
      // 任何未预期的异常也按「这一条失败」处理 —— 不能让一条坏数据打断整批
      failed++;
    }

    onProgress?.call(i + 1, pending.length);
    if (stopMessage != null) break;
  }

  return HighlightBackfillResult(
    total: pending.length,
    ok: ok,
    failed: failed,
    stopMessage: stopMessage,
  );
}

/// 还**没有译文**的划线**条数** —— 供 UI 决定「要不要显示补译入口」。
///
/// 🔑 订阅 `userDbRevisionProvider`：补译/同步写库后**自动重算**
///    （否则补完了条数还停在旧值 —— 本项目已踩过「写端不通知读端」）。
final highlightTranslationPendingCountProvider = FutureProvider<int>((ref) async {
  ref.watch(userDbRevisionProvider);
  final db = await ref.watch(userDbProvider.future);
  final rows = await HighlightRepository(db).withoutTranslation();
  return rows.length;
}, name: 'highlightTranslationPendingCount');
