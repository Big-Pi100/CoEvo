/// 翻译的**编排**：端侧优先 → 服务端兜底。
///
/// # 这里只有一个决定：**走谁**
/// ```
/// ① 端侧能用吗？(installed)
///    ├─ 不能 → 服务端 LLM（现状路径，**完全不碰预扣**）
///    └─ 能   → ② 预扣（服务端点头：权益不变）
///                ├─ 未登录 / 额度尽 → 如实返回，**不翻、不回落**
///                ├─ 预扣失败（网络/5xx/404）→ 🔑 **回落服务端 LLM**
///                │                            （它自己扣额并守上限 ⇒ 不绕过）
///                └─ OK → ③ 端侧翻
///                          ├─ 成功 → 逐句对照
///                          └─ 失败 → ④ 带凭据回落服务端（**不重复扣**）
/// ```
///
/// # 🔑 为什么写成「依赖注入」的样子
/// 本文件**零 Flutter 依赖**，四个外部能力都是函数参数 ⇒
/// 断言脚本可以注入假实现，**真跑**每一条分支（见 `verify_translation_service.dart`）。
/// 若写成直接 `ref.read(...)`，这些分支就只能靠真机点出来 —— 那等于没有回归防线。
///
/// # 🔴 两条不能动的顺序
/// ① **先判可用性，再预扣** —— 反过来会在「端侧根本不能用」时白扣用户一次额度。
/// ② **预扣「没成功」时不许端侧翻** —— 没拿到服务端的放行，就不该在本地产出译文
///    （否则免费用户绕过了额度）。⚠️ 但**允许回落服务端**：那条路自己会扣额。
library;

import 'ondevice_translate.dart';
import 'translate_parse.dart';

/// 查端侧可用性。
typedef OnDeviceStatusProbe = Future<OnDeviceTranslateStatus> Function();

/// 端侧批量翻译（`null` = 失败）。
typedef OnDeviceBatchTranslate = Future<List<String>?> Function(List<String> texts);

/// 预扣一次额度。
typedef QuotaPrepay = Future<PrepayResult> Function(String text);

/// 走服务端 LLM 翻译（`ticket` 非空 ⇒ 服务端**不再扣额**）。
typedef ServerTranslate = Future<TranslateResult> Function(
  String text, {
  String? ticket,
});

/// 一次翻译的结局 + 它**实际走的哪条路**。
typedef TranslatePathOutcome = ({TranslateResult result, bool onDevice});

/// 端侧优先 + 服务端兜底的完整编排（见文件头）。
Future<TranslatePathOutcome> translateWithFallback({
  required String text,
  required OnDeviceStatusProbe probeOnDevice,
  required OnDeviceBatchTranslate translateOnDevice,
  required QuotaPrepay prepay,
  required ServerTranslate translateViaServer,
}) async {
  // ── ① 端侧能用吗？（**先判、后扣**）──
  final status = await probeOnDevice();
  if (!status.canTranslate) {
    // 端侧不可用 / 语言包未下载 ⇒ 走现状路径：**完全不碰预扣**（不会多扣）
    return (result: await translateViaServer(text), onDevice: false);
  }

  // ── ② 预扣（闸门仍由服务端握着 ⇒ 权益语义不变）──
  final pre = await prepay(text);
  switch (pre) {
    case PrepayNeedLogin():
      return (result: const TranslateNeedLogin(), onDevice: false);

    case PrepayQuotaExceeded(:final message):
      return (result: TranslateQuotaExceeded(message: message), onDevice: false);

    case PrepayFailed():
      // 🔑 预扣失败 ⇒ **回落服务端 LLM**，而不是直接失败。
      //
      // # 🔴 为什么这不等于「绕过额度闸门」（我一开始想错了）
      // `/api/translate` **自己就会扣额、并守着同一个上限**（它本来就是
      // 「扣额 + 翻译」一体）。⇒ 回落路径的额度语义与预扣**完全一致**，
      // 没有任何绕过。
      //
      // # 🔴 为什么**不能**在这里直接失败
      // 预扣失败的情形里包含 **404（服务端还没部署这个端点）**。
      // 若写成「预扣失败就不翻」，那么「**新 App + 旧服务端**」这个组合会让
      // 「iOS 18+ 且语言包已下好」的用户**连翻译都用不了**（其余用户反而正常）
      // —— 这是典型的**上线顺序敏感性**：靠流程去保证顺序，不如让代码不吃顺序。
      return (result: await translateViaServer(text), onDevice: false);

    case PrepayOk(:final ticket):
      // ── ③ 端侧翻译（切句 ⇒ 保住「逐句对照」的 UI 形态）──
      final sentences = splitSentences(text);
      final dsts = await translateOnDevice(sentences);
      if (dsts != null && dsts.length == sentences.length) {
        return (
          result: TranslateReady(
            segments: [
              for (var i = 0; i < sentences.length; i++)
                TransSegment(src: sentences[i], dst: dsts[i]),
            ],
            used: pre.used,
            limit: pre.limit,
            subscribed: pre.subscribed,
          ),
          onDevice: true,
        );
      }

      // ── ④ 回落服务端（带凭据 ⇒ **不重复扣额**）──
      //
      // ⚠️ 这一步的额度语义：预扣已扣 1 次，凭据让服务端跳过第二次扣。
      //    若服务端 LLM 也失败，它会走自己的退额逻辑（既有行为，未改）。
      return (
        result: await translateViaServer(text, ticket: ticket),
        onDevice: false,
      );
  }
}
