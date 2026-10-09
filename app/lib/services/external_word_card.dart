// CoEvo · 词库外词卡的**唯一取卡实现**：端侧缓存 → 服务端（缓存优先）→ 写回端侧缓存
//
// # 依据
// · L0 `v1-final-design-authoritative-2026-09-25.md` §九：未命中 → 查 `external_word_cache`
//   → 仍无 → 联网制卡 → **写缓存** → 显示
// · `docs/design/sync-implementation-assessment-2026-10-04.md:152`：
//   `external_word_cache` ⛔ **不同步**，理由 = 「它是**缓存**不是资产：
//   **词卡可按需向服务端再取**（`/api/generate-card` + 服务端全局缓存）」
//
// # 🔴 本文件存在的原因：上面那句「可按需再取」原先**只在划词路径成立**
//
// 2026-10-09 白哥真机报「重装后，之前 LLM 生成的生词卡显示『这张卡暂时打不开』」。
// 逐跳查下来：`external_word_cache` 只存在于端侧（不参与同步、不在云端），
// 而 `WordQueryService.cardById` 的 `ext:` 回落在端侧缓存未命中时**直接返回 null**
// —— 既没有服务端回落，复习页也没有再生入口。
// ⇒ 任何使端侧缓存消失的事件（重装 / 清数据 / 换账号 / 将来任何清理）
//    都会让那些词**永久打不开**，而服务端全局缓存里**本来就有那份卡**
//    （实测该账号 8 个词 **8/8 命中** ⇒ 回落是**零 LLM 成本、毫秒级**的）。
//
// ⇒ 于是把「读缓存 → 联网 → 转形状 → 写回缓存」整条链收成**一处实现**，
//   两个调用方（复习取卡 / 划词制卡）共用 —— 原先两边各写一半，
//   而「文案与重试判据」这类东西**两边必然漂移**（本项目已有教训）。
//
// # 🔑 为什么是**纯 Dart**（本文件不得 import 任何 Flutter 包）
// 这样 `scripts/query_verify` 能拿**真库 + 假生成器**直接跑它，
// 把两个最容易假绿的点变成**行为断言**：
// · 「缓存命中 ⇒ **一次网络都不发**」（只扫源码看不出来）
// · 「回落成功后**真的写回了端侧缓存** ⇒ 下次不再联网」（= 自愈的核心）
// ⇒ 服务端结果由本文件自己的 [`ExternalCardGenReply`] 承载；
//   与 HTTP 客户端的映射在 `providers/generate_card_provider.dart` 的
//   [`externalCardReplyOf`]（**唯一一处**，别在两处各写一遍）。

import 'generated_card_adapter.dart';

/// 读端侧缓存（`null` / 空串 = 没有）。
typedef ExternalCacheRead = Future<String?> Function(String spelling);

/// 写端侧缓存（**覆盖**语义，与 `ExternalWordCacheRepository.put` 一致）。
typedef ExternalCacheWrite = Future<void> Function(String spelling, String content);

/// 发一次制卡请求（**含服务端全局缓存命中**这一情形）。
typedef ExternalCardGenerate = Future<ExternalCardGenReply> Function(String spelling);

/// 可选告警出口（本层没有 logger —— 纯 Dart 不能 `debugPrint`）。
///
/// 🔑 **不是可选的洁癖**：缓存写回失败若完全无声，就会表现成
/// 「每次打开这张卡都要联网一次」而**没有任何痕迹**——正是本项目最忌的静默失效。
typedef ExternalCardWarn = void Function(String message);

// ────────────────────────────────────────────────────────────────────
// 服务端结果（端侧视角）
// ────────────────────────────────────────────────────────────────────

/// `POST /api/generate-card` 的三种结局 —— 对用户**完全不同**，用类型强制区分。
sealed class ExternalCardGenReply {
  const ExternalCardGenReply();
}

/// ✅ 拿到卡。`rawCard` 是服务端**原始** card JSON
/// （`{word, entry_type, definition, …}` 平铺字段），**不是** `word.db` 的形状。
final class ExternalCardGenReady extends ExternalCardGenReply {
  const ExternalCardGenReady({
    required this.rawCard,
    required this.fromCache,
    required this.contractVersion,
  });

  final Map<String, Object?> rawCard;

  /// `true` = 服务端已有这个词的卡（**本次没花钱**）。
  final bool fromCache;

  /// 契约版本（如 `v6`）—— 端侧不认识时要**显式失败**（见 [toCardContent]）。
  final String contractVersion;
}

/// ⏳ 服务端 503 —— 同一时刻别人正在生成同一个词。
/// **不是错误**，稍后重试就有（若提示成「生成失败」，用户会以为功能坏了）。
final class ExternalCardGenBusy extends ExternalCardGenReply {
  const ExternalCardGenBusy();
}

/// ❌ 失败。`message` 由服务端转成**面向用户的中文**（可直接显示）；
/// `statusCode == null` = 网络层失败（连不上 / 超时 / DNS）。
final class ExternalCardGenFailed extends ExternalCardGenReply {
  const ExternalCardGenFailed({required this.message, this.statusCode});

  final String message;
  final int? statusCode;
}

// ────────────────────────────────────────────────────────────────────
// 取不到卡（抛给界面，带**准确原因**）
// ────────────────────────────────────────────────────────────────────

/// 词库外的词**这次取不到卡**。
///
/// 🔴 为什么用**异常**而不是「返回 null」：
/// 它的载体是 `ExternalCardLoader`（`Future<String?>` 的契约由纯 Dart 的
/// `WordQueryService` 定义）。改成返回值会牵动那一层与它的全部行为断言，
/// 而**「取不到」在这条路径上确实是失败**（网络/服务端错误），
/// 且**唯一调用方** `cardBundleProvider` 本就有 `catch` 分支在等它。
/// —— 同 `DeviceIdUnavailable` / `GeneratedCardException` 的既有惯例。
///
/// 🔑 关键是它带 **`message`（准确的话）+ `retryable`（有没有出口）**：
/// 旧实现在这里只留下一个 `null`，界面只好猜原因 —— 于是把「词库外取不到」
/// 猜成了「词库还在准备」，用户按提示「稍后再试」**永远不会好**。
class ExternalCardUnavailable implements Exception {
  const ExternalCardUnavailable(this.message, {this.retryable = true});

  /// **面向用户**的一句话（服务端文案优先 —— 它已按情形区分）。
  final String message;

  /// 重试是否有意义（判据见 [_retryable]）。
  final bool retryable;

  @override
  String toString() => 'ExternalCardUnavailable: $message';
}

// ────────────────────────────────────────────────────────────────────
// 主流程
// ────────────────────────────────────────────────────────────────────

/// 取词库外词卡：① 端侧缓存 → ② 服务端（**其全局缓存优先，未命中才现生成**）→ ③ 写回端侧缓存。
///
/// 成功返回**已转换的** `card.content` JSON（可直接喂渲染层 / 存库）；
/// 取不到则抛 [ExternalCardUnavailable]。
///
/// [readCache] 传 `null` 表示**调用方已经查过并确定未命中**
/// （划词路径必须把「转圈」插在「读缓存」与「联网」之间，所以那次读留在调用方）。
Future<String> resolveExternalWordCard({
  required String spelling,
  required ExternalCardGenerate generate,
  ExternalCacheRead? readCache,
  ExternalCacheWrite? writeCache,
  ExternalCardWarn? onWarn,
}) async {
  // ── ① 端侧缓存：命中即返回（**一次网络都不发**）──
  if (readCache != null) {
    try {
      final hit = await readCache(spelling);
      if (hit != null && hit.isNotEmpty) return hit;
    } catch (e) {
      // 读缓存失败 ⇒ 降级为「当作没有缓存」（继续走联网），**不终止**。
      // 🔑 缓存是**优化**：它坏了只该让这条路变慢，不该让它走不通。
      onWarn?.call('读词库外缓存失败（$spelling）：$e');
    }
  }

  // ── ② 服务端（缓存优先 —— 命中时 0 次 LLM、毫秒级）──
  final reply = await generate(spelling);

  final ready = switch (reply) {
    ExternalCardGenReady r => r,
    // 503 = 有人正在生成同一个词 → **可重试**
    ExternalCardGenBusy() =>
      throw ExternalCardUnavailable('「$spelling」正在生成中，请稍后重试'),
    ExternalCardGenFailed(:final message, :final statusCode) =>
      throw ExternalCardUnavailable(message, retryable: _retryable(statusCode)),
  };

  // ── ③ 转形状（服务端原始 card → `word.db.card.content`）──
  final content = _toCardContent(ready, spelling);

  // ── ④ 写回端侧缓存 ──
  //    ⚠️ 失败**不影响本次展示**（内容已经拿到了，只在**下次**需要再联网一次）。
  //    但必须留痕（`onWarn`）—— 否则「每次打开都要联网」会完全无声。
  if (writeCache != null) {
    try {
      await writeCache(spelling, content);
    } catch (e) {
      onWarn?.call('写词库外缓存失败（$spelling）：$e');
    }
  }

  return content;
}

/// 契约转换失败的文案 —— **唯一一处**（原先散在 `word_lookup`，会与复习路径漂移）。
String _toCardContent(ExternalCardGenReady ready, String spelling) {
  try {
    return toCardContent(
      ready.rawCard,
      spelling: spelling,
      contractVersion: ready.contractVersion,
    );
  } on GeneratedCardException {
    // 🔴 契约对不上 / 缺 definition → **显式失败**，不要静默弹一张空卡
    throw ExternalCardUnavailable('「$spelling」的词卡格式异常，请稍后重试');
  }
}

/// 重试判据：**服务端故障可重试，参数/内容问题不可**。
///
/// 🔑 这条判据原先**不存在**（界面上也没有出口）——
/// 现在它决定「重试」按钮出不出现，所以必须写下来而不是让界面猜：
/// 「一个永远不会成功的重试按钮」比没有按钮更糟（训练用户点无效的东西）。
bool _retryable(int? statusCode) {
  if (statusCode == null) return true; // 网络层失败（连不上 / 超时 / DNS）
  if (statusCode == 503) return true; // 正在生成中
  if (statusCode >= 500) return true; // 502 上游 / 500 内部
  return false; // 400 参数 · 422 合规 —— 再点一次也是同样结果
}
