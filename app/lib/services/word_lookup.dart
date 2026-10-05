// CoEvo · 划词查词（**从 `reader_screen` 搬出** · 2026-10-05）
//
// # 🔴 为什么搬出来
//
// 书库阅读页也要划词查词（白哥真机反馈「书库中的书籍划词不成功」——
// 实际是**当初有意没做**，见 `book_reader_screen` 的旧注释）。
// 而查词这一族逻辑原本是 `reader_screen.dart` 的**文件私有顶层函数** ——
// 跨文件用不了。
//
// 两条路：
//   · 书库页再写一份 ⇒ **两份实现必然漂移**（本项目已有教训）
//   · **搬到这里公开** ⇒ 信息流页与书库页共用同一份（判据：一处定义）
//
// 🔑 搬迁之所以可行，是因为这一族函数**早就是顶层函数、不依赖任何 State**
//    （`reader_screen` 的原文注释写着「它不依赖任何 State 字段（只用到
//    `context` 与 `ref`，两者都由调用处传入）」）—— 这正是那次重构的收益。
//
// # 🔊 分层
// | 层 | 文件 | 内容 |
// |---|---|---|
// | **查词逻辑**（本文件）| `services/word_lookup.dart` | 查库 → 弹浮层 → 落库 → 在线制卡 |
// | **划词手势** | `widgets/word_lookup_selection.dart` | `SelectionArea` + 防抖（两页共用）|
// | 摆放 | `reader_screen` / `book_reader_screen` | 谁包谁 |
//
// # 🔴 `articleId` 可空（2026-10-05 改，**语义变更**）
//
// 原签名是 `required int articleId` —— 因为它是**痕迹（「本文查过的词」底色）的唯一键**，
// 而「漏传 ⇒ 痕迹静默消失」踩过坑（`tokens_verify` 【24】有接线断言守着）。
//
// 但书库场景**没有 article 概念**（书的 id 是 String uuid，不是文章的 int id）——
// 硬塞一个值会**污染痕迹数据**（将来 id 撞上就会串）。
// 而 `lookup_event.article_id` 在 schema 里**本来就是可空的**
// （原文注释：「哪篇文章（**可空**）」）⇒ `required` 是**过度约束**。
//
// ⇒ 改为 `int? articleId`：
//   · 信息流页传 `widget.articleId`（**非空**，由类型系统保证）⇒ 痕迹照旧
//   · 书库页传 `null` ⇒ **有意不记痕迹**（不是漏传）
// 📌 断言的强度**提高了**：原来守「语法上有没有传」，现在守
//    「信息流页必须传**非空**值」+「书库页**有意**不传」。
//
// ⚠️ 本文件 import Flutter ⇒ **本机不可验证**，靠 `codestatic`（符号）
//    与 `analyze_inproc`（unused import 等）兜，最终以 CI 的 `frontend` 为准。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/generate_card_client.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../providers/device_id_provider.dart';
import '../providers/generate_card_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../providers/word_db_provider.dart';
import 'external_word_cache_repository.dart';
import 'external_word_id.dart';
import 'generated_card_adapter.dart';
import 'review_list_query.dart';
import 'user_word_repository.dart';
import 'word_query_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/lookup_sheet.dart';

/// 查词 —— 长按选中后（经 300 ms 防抖）的落点。
///
/// # 🔴 五种「拿不到词卡」必须各有明确表达（不能静默无效，也不能笼统）
///
/// | 情况 | 表达 | 能不能等 |
/// |---|---|---|
/// | **当前平台没有本地 SQLite**（web） | 「查词需在手机上使用」 | ❌ **永久** |
/// | **真机上落盘/打开失败** | 「词库打开失败，请重启 App 后再试」 | ❌ 需重启 |
/// | **还在首次落盘**（`valueOrNull == null`） | 「词库正在准备，请稍候再试」 | ✅ 约 0.5–2 s |
/// | 🆕 **词库外**（未命中 + 词形还原也没命中） | **转圈 → 在线制卡**（见 `_lookupExternalWord`）| ✅ 约 5–10 s |
/// | 🆕 词库外**且制卡失败** | 服务端的**准确文案**（网络 / 正在生成中 / 合规拒绝各有措辞）| ⚠️ 看情形 |
///
/// 🔑 **前两者与第三者必须分开** —— 笼统说「请稍候再试」会让 web 用户
/// 一直重试一个**永远不会成功**的操作（见 `word_db_provider` 的 [WordDbLoad] 文档）。
///
/// 🆕 **2026-10-01（A2）**：第四行**原来是**「只说一句『词库里没有「X」』就结束」——
///    那是 A2 落地前的状态（`reader_screen` 的旧注释自己就写着「为 Phase 3 留了输入」）。
///    现在**词库外的词也能查**（在线制卡），所以那不再是一个终点，而是一个**分支**。
///
/// 🔑 提成顶层函数（而非 State 方法）：它不依赖任何 State 字段
/// （只用到 `context` 与 `ref`，两者都由调用处传入）→ 挂在 State 上没有理由。
Future<void> lookupWord(
  BuildContext context,
  WidgetRef ref,
  String rawText, {
  /// 🔴 **「这篇」的 id —— 痕迹的命根子**（2026-10-02 真机定位的缺口）。
  ///
  /// 它一路传到 `lookup_event.article_id`，而读取侧是
  /// `lookupsForArticle(articleId) → WHERE le.article_id = ?1`。
  /// 两边只要有一边缺，痕迹就**恒为空** —— 且**不报任何错**（只是少画底色）。
  ///
  /// 📌 判据：**「写了 A 端」≠「B 端会显示」** —— 这条链跨了 3 个文件
  ///    （本文件 → `_writeBackLookup` → `recordLookup` → SQL），
  ///    任一处漏传都会静默失效。故 `tokens_verify` 里有**接线断言**守着。
  int? articleId,
}) async {
  // ⚠️ 这里用 `read`（不订阅）是对的 —— 预热由 `build` 里的 `watch` 负责。
  //    `valueOrNull == null` 表示 future **还没跑完**（首次落盘中）。
  final load = ref.read(wordQueryProvider).valueOrNull;

  if (load is! WordDbReady) {
    _hint(
      context,
      switch (load) {
        WordDbUnsupported() => '查词需在手机上使用（Web 端无本地词库）',
        WordDbFailed() => '词库打开失败，请重启 App 后再试',
        // 到这里的只有 `null`（future 未完成）—— `WordDbReady` 已被上面排除
        _ => '词库正在准备，请稍候再试',
      },
    );
    return;
  }

  final text = rawText.trim();
  final result = await load.service.lookup(text);
  if (!context.mounted) return;

  // ── 🔑 Step 3.4c：查词写入（v1 §八 / §九：**查词即自动入生词本，零额外操作**）──
  //
  // 🔴🔴 **必须先弹浮层，写入放后面 —— 且不得阻塞**
  //    「读到词义」是产品核心动作。写库失败（磁盘满 / 库损坏）
  //    **绝不能**让用户看不到释义。所以：
  //      · 命中 → 先 `await` 浮层（用户看到释义）→ 再异步写入
  //      · 未命中 → 只记 `lookup_event`（白哥定 Q2：未命中**也记**）
  //    ⚠️ 写入的失败**只记日志**，不打扰用户（见 `_writeBackLookup`）。
  if (result == null) {
    // 🆕 A2：词库外的词 → **在线制卡**（2026-10-01）
    //
    // 产品原则：**仍不验证登录态**、**仍不打断阅读** ——
    // 失败时给准确提示，成功时弹与词库内词**同一个**浮层。
    await _lookupExternalWord(context, ref, text, articleId: articleId);
    return;
  }

  await LookupSheet.show(context, result);

  // 浮层已展示（或被用户关掉）→ 再做写入。
  // 🔑 传 `sentence: text` 不是语境 —— 本轮没有可靠的「所在句」来源，
  //    故**只记词本身**；`source_sentence` 留空比记一句错的好。
  //    （真实语境需从正文渲染层拿到句子边界，属后续增强。）
  unawaited(_writeBackLookup(
    ref,
    articleId: articleId,
    wordId: result.card.wordId,
    spelling: result.card.spelling,
  ));
}

// ─────────────────────────────────────────────────────────────
// 🆕 词库外查词 → 在线制卡（A2 · 2026-10-01）
// ─────────────────────────────────────────────────────────────

/// **词库外查词** —— 查端侧缓存，没有才联网制卡。
///
/// # 流程（照 L0 §九「用户查词流程」的未命中分支）
/// ```
/// word.db 未命中
///   → ① 查端侧缓存 `external_word_cache` ──命中──► 直接展示（0 次网络）
///   → ② 未命中 → 转圈 → POST /api/generate-card → 写缓存 → 展示
/// ```
///
/// # 🔴 五条**已定裁决**（白哥 2026-09-29 · `llm-card-online-path` §21.3 · 本次照做，不再问）
/// | # | 事项 | 定案 |
/// |---|---|---|
/// | 1 | 写入目标 | **`external_word_cache`**（端侧独立缓存表，不动 `word.db`）|
/// | 2 | 失败路径 | **直接报错 + 稍后重试**（**不**做 L0 原文的「降级卡」）|
/// | 3 | 等待 UI | **转圈** |
/// | 4 | 一致性 | 与预制**同一套** prompt / 契约 / 校验（服务端已如此）|
/// | 5 | 登录态 | **不验证** —— 划词是内容渲染的一部分（产品原则）|
///
/// # ⚠️ 不做「会话内内存缓存」（如实标注，**不是漏了**）
/// 我曾在实施方案里列过这一项，复核 L0 后**删掉**：L0 §九 只要求
/// 「查 `external_word_cache`」，**没有**内存缓存这一层。
/// 而端侧 SQLite 命中是**本地查询**（~40 µs 量级，见 `word_query_service` 的实测注释）
/// → 加一层内存只多出「生命周期 / 失效 / 上限」三个要维护的东西，收益极小。
/// 📌 判据：**别为「看起来会更快」加一层，除非能指出它挡掉了什么**。
Future<void> _lookupExternalWord(
  BuildContext context,
  WidgetRef ref,
  String text, {
  /// 见 `lookupWord` 的同名参数：痕迹的唯一键，**必须一路传下去**。
  int? articleId,
}) async {
  // ── ① 端侧缓存（离线也能看 + 免一次网络往返）──
  String? raw;
  try {
    final db = await ref.read(userDbProvider.future);
    raw = await ExternalWordCacheRepository(db).contentOf(text);
  } catch (e) {
    // 读缓存失败 → **降级为「当作没有缓存」**（继续走联网），不是终止。
    // 🔑 缓存是**优化**：它坏了只该让这条路变慢，不该让它走不通。
    debugPrint('[lookup] 读词库外缓存失败（$text）：$e');
  }

  // ── ② 没有缓存 → 联网制卡（转圈）──
  if (raw == null) {
    raw = await _generateExternalCard(context, ref, text);
  }

  // ── ③ 展示 ──
  if (raw == null) return; // 失败路径已在 `_generateExternalCard` 里给过提示
  if (!context.mounted) return;

  final c = parseCardContent(raw);
  if (c.sections.isEmpty) {
    // 缓存里存了个空壳（理论上不该发生 —— 适配器写入前已校验 section 非空）；
    // 宁可说「不完整」也不要弹一张**没有任何内容**的卡。
    _hint(context, '「$text」的词卡不完整，请稍后重试');
    return;
  }

  // 🔑 与词库内词**共用同一个浮层**（`LookupSheet` 只读 spelling / ipa /
  //    definition / context 四样）→ 用户体验完全一致，没有「另一种卡」。
  await LookupSheet.show(
    context,
    WordLookupResult(
      card: WordCard(
        wordId: externalWordId(text),
        spelling: c.front.isEmpty ? text : c.front,
        ipa: c.ipa.isEmpty ? null : c.ipa,
        entryType: c.entryType.isEmpty ? null : c.entryType,
        sections: c.sections.map(WordSection.new).toList(growable: false),
      ),
      query: text,
    ),
  );

  // ── ④ 写入生词本（🔑 用**合成 id**，于是它立刻进复习队列）──
  //    与词库内词走**同一条**写回链（`_writeBackLookup`）——
  //    区别只有 `wordId` 的形态（`ext:brainstorm` vs `w005333`）。
  unawaited(_writeBackLookup(
    ref,
    articleId: articleId,
    wordId: externalWordId(text),
    spelling: text,
  ));
}

/// 联网制卡（含「转圈 → 关闭 → 提示」的时序）。
///
/// 返回**已转换的 `card.content` JSON**（`null` = 失败，且已提示过用户）。
///
/// # 🔴 时序要点：**先关转圈，再提示**
/// 若在浮层还开着时 `_hint`，SnackBar 会被 modal 遮住 —— 用户看到的是
/// 「转圈转完了，什么都没发生」。**静默失败**正是本项目一直在消灭的东西。
Future<String?> _generateExternalCard(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  final closeLoading = _showGenerating(context, text);

  String? raw;
  String? error;

  try {
    // 🔑 device_id 是**可选**统计信号（服务端算 `distinct_user_count`，A3 回流门槛用）：
    //    取不到就传 `null` —— **不阻断制卡**（它是统计，不是功能前提）。
    final deviceId = await deviceIdOrNull(ref);
    final res = await ref.read(generateCardClientProvider).generate(
          text,
          deviceId: deviceId,
        );

    switch (res) {
      case GenerateCardReady():
        try {
          raw = toCardContent(
            res.card,
            spelling: text,
            contractVersion: res.contractVersion,
          );
          // 写缓存 —— ⚠️ 失败**不**影响本次展示（只在下次查同一个词时要重新联网）
          try {
            final db = await ref.read(userDbProvider.future);
            await ExternalWordCacheRepository(db).put(text, raw);
          } catch (e) {
            debugPrint('[lookup] 写词库外缓存失败（$text）：$e');
          }
        } on GeneratedCardException catch (e) {
          // 🔴 契约对不上 / 缺 definition → **显式失败**，不要静默弹一张空卡
          debugPrint('[lookup] 契约转换失败（$text）：$e');
          error = '「$text」的词卡格式异常，请稍后重试';
        }

      case GenerateCardInProgress():
        // 白哥裁决的「报错 + 稍后重试」—— 这不是故障，是「有人正在生成同一个词」
        error = '「$text」正在生成中，请稍后重试';

      case GenerateCardFailed(:final message):
        // 🔑 **不改写服务端的文案** —— 它已按情形给了**准确**的话
        //    （参数错 / 上游失败 / 合规拒绝各有措辞，见 `CardError::message()`）。
        //    端侧若自己拼一句笼统的「生成失败」，就把这些区别抹掉了。
        error = message;
    }
  } finally {
    await closeLoading();
  }

  if (error != null && context.mounted) {
    _hint(context, error);
  }
  return raw;
}

/// 弹一个「正在生成」的等待浮层，返回**关闭它的函数**。
///
/// # 为什么是「转圈」而不是骨架屏 / 进度条
/// 白哥 2026-09-29 已裁决（`llm-card-online-path` §21.3）。理由（我们的推断）：
/// 生成耗时**不可预估**（依赖上游 LLM），进度条会给出**假承诺**；
/// 而「转圈 + 一句话说明」是诚实的 —— 用户知道在等，也知道大概等多久。
///
/// # 🔴🔴 关闭时必须**等「对话框真的挂载」这个条件**，不能等一个猜的时长
///
/// `showDialog` 是异步的：它内部走 `Navigator.push`，而对话框要**下一次渲染**
/// 才会执行 `builder`。所以「请求返回」与「对话框出现」是两个独立的时序。
///
/// ⚠️ **曾经的写法是错的**（2026-10-02 修）：
/// ```dart
/// await Future<void>.delayed(Duration.zero);   // ❌ 只让出**事件循环**（Timer(0)，≈0 ms）
/// final c = dialogCtx;
/// if (c != null && c.mounted) Navigator.of(c).pop();   // c 为 null 时**静默什么都不做**
/// ```
/// `Duration.zero` **不保证渲染帧已经跑过**（帧间隔 ~16 ms）。于是：
/// **请求比一帧还快返回时**（断网 / 连接被拒 / DNS 失败，HTTP 可能几毫秒就失败）
/// → 关闭函数执行时 `builder` 还没跑、`dialogCtx` 仍是 `null` → **不 pop** →
/// 对话框**随后**才出现 → **永久留在屏幕上**。
///
/// 🔴 后果被两个设置放大到「必须杀 App」：
/// · `barrierDismissible: false`（生成期间不许点掉等待）
/// · 本项目**仅 iOS** —— 没有 Android 的系统返回键可退
///
/// ✅ **修法**：等 `builder` **真正执行过**这个事实（`Completer`），
///    并加**有界超时**兜底（万一 builder 因故永不运行，也不能把调用方挂死）。
///    🔑 一般化：`等一个猜的时长` ＜ `等一个条件成立`。
///    （这与 flaky test 的经典修法同一条：**永远不要 sleep，要等状态**。）
///
/// 📌 **这一类缺陷文本断言验不到** —— 代码「看起来」是对的（有 null 检查、有延迟），
///    只有**构造极端路径真跑**才暴露。所以它的最终防线是
///    `docs/review/a2-device-verification-checklist-2026-10-02.md` §2b
///    （**断网**下划一个没查过的词库外词 → 转圈必须消失）。
///
/// ⚠️ 本函数**是同步的**（返回「关闭函数」而不是「Future<关闭函数>」）——
///    写成 `async` 会让调用处拿到 `Future` 却当函数调，类型不符（我初稿正是这么写的）。
Future<void> Function() _showGenerating(BuildContext context, String word) {
  BuildContext? dialogCtx;
  // 「builder 已执行」的信号 —— 关闭函数等的就是它
  final dialogReady = Completer<void>();
  void markReady() {
    if (!dialogReady.isCompleted) dialogReady.complete();
  }

  unawaited(showDialog<void>(
    context: context,
    // 🔴 不可点外部关闭：生成期间用户不该能「点掉等待」——
    //    那会留下「有个请求还在飞，但界面已回到阅读」的模糊状态。
    barrierDismissible: false,
    // 🔑 与 `LookupSheet` 同一轻遮罩（12% 黑）：等待**不该像跳到了另一个界面**
    barrierColor: const Color(0x1F000000),
    builder: (c) {
      dialogCtx = c;
      markReady(); // ← 到这一刻，「关闭它」才是安全的
      return _GeneratingDialog(word: word);
    },
  ).whenComplete(() {
    // 兜底：对话框因别的原因结束（页面已 pop / 被系统关掉）→ 也要解除等待，
    // 否则关闭函数会一直挂着，调用方那一步就卡住了。
    markReady();
  }));

  return () async {
    // 🔴 等**条件**（builder 跑过），不是等时长。
    // ⚠️ 超时是**兜底而非正常路径**：3 秒内 builder 都没跑，
    //    说明对话框根本没弹出来（如页面已 pop）→ 此时不该再等、也不该 pop 别的东西。
    await dialogReady.future
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    final c = dialogCtx;
    if (c != null && c.mounted) Navigator.of(c).pop();
  };
}

/// 「正在生成」等待浮层（详见 `_showGenerating` 的说明）。
class _GeneratingDialog extends StatelessWidget {
  const _GeneratingDialog({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          decoration: BoxDecoration(
            color: Color(t.card.argb32),
            borderRadius: BorderRadius.circular(t.clay.radius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(t.accent.argb32),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '正在制作「$word」',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: Color(t.ink.argb32),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                // 🔑 **给一个时间预期**（不是精确承诺）—— 否则用户会在第 3 秒就放弃。
                '第一次遇到这个词需要现场生成，约 5–10 秒',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  height: 1.5,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 查词写入 —— **失败只记日志，绝不打扰用户**（见调用处的说明）。
///
/// 分工（照 v1 §九 的分支）：
///   ① `lookup_event` —— **每次都记**（命中/未命中都记 · 白哥定 Q2）
///   ② `user_word` —— **只在有 `wordId` 时**写
///   ③ `card_review_state` —— 让新词**立刻进复习队列**（v1 §八 的
///      「INSERT user_word + card_review_state」是同一动作的两半）
///
/// # 🆕 `wordId` 的三种来源（2026-10-01 · A2）
/// | 情形 | `wordId` | 说明 |
/// |---|---|---|
/// | 命中词库 | `w0xxxxx` | 真主键 |
/// | **词库外**（在线制卡成功） | **`ext:<拼写>`** | 合成 id，见 `external_word_id.dart` |
/// | 彻底取不到卡 | `null` | 只写 `lookup_event`（`word_id` 留 NULL），到此为止 |
///
/// ⚠️ **`lookup_event.word_id` 的含义随之变化**：原来是「命中才写、未命中留 NULL」，
///    现在多了一种「**词库外但有卡**」→ 写 `ext:` 合成 id。
///    三种都仍能回答它原本要回答的问题（「查过哪些词」「当时那句是什么」）。
///
/// ⚠️ 三者**不是事务**：任一步失败，前面的已经写入 ——
///    这是**有意**的（可接受的降级）。理由：
///    · 查词写入是「尽力而为」的旁路，不该因为复习调度写失败而丢掉落词记录
///    · 三张表各自独立可用（复习页只看 `card_review_state`、生词本只看 `user_word`）
///    → 若将来要做严格一致，才需要包事务；**当前没有这个必要**。
Future<void> _writeBackLookup(
  WidgetRef ref, {
  /// 🔴 **`required`，不是可选** —— 这是本次真机事故的修法（2026-10-02）。
  ///
  /// 它曾经**不在签名里**，于是两个调用点也都没传 ⇒ `lookup_event.article_id`
  /// 恒为 `NULL` ⇒ 阅读页 `WHERE le.article_id = ?1` 永不匹配 ⇒ **痕迹恒不显示** ——
  /// 而且**没有任何报错**（只是少画底色），所以躺了很久才被发现。
  ///
  /// 🔑 用 `required` 而**不是**「默认 null + 祈祷调用方记得传」：
  ///    ⇒ 漏传会在**编译期**就失败，而不是在真机上表现为「某个功能悄悄没了」。
  ///    📌 判据：**能用类型系统保证的，就不要靠自觉**（同 `CollocationItem.zh`
  ///       删死判空那次的理由 —— 「编译器强制处理」比「运行时守卫」更早）。
  int? articleId,
  String? wordId,
  required String spelling,
}) async {
  // 🔑 **在任何 `await` 之前**先取到 notifier 引用。
  //
  // 原因是本函数是 `unawaited(...)` 调用的（fire-and-forget，不阻塞释义浮层），
  // 期间用户可能已经退出阅读页 → `ref` 失效 → `await` 之后再 `ref.read` 会抛错。
  // 而 `Notifier` **实例**的存活与 widget 无关（`userDbRevisionProvider`
  // 是非 autoDispose，只要 app 在就一直在）→ 拿着引用调 `bump()` 永远安全。
  final revision = ref.read(userDbRevisionProvider.notifier);
  // 🔑 同理：成就解锁队列的 notifier **实例**（存活与 widget 无关）
  final unlockNotifier = ref.read(achievementUnlockProvider.notifier);

  try {
    final repo = await ref.read(userWordProvider.future);
    await repo.recordLookup(
      articleId: articleId,
      wordId: wordId,
      spelling: spelling,
    );

    if (wordId == null) return; // 未命中：没有词库 id，到此为止
    // ⚠️ 未命中时**不 bump**：只写了 `lookup_event`，而复习页读的是
    //    `user_word` + `card_review_state` → 刷了也是白刷一次库。

    final added = await repo.add(wordId, spelling);

    // `alreadyExists` → `add()` 直接 return，**一行都没写** → 库没变，不 bump。
    // 🔑 「只在**真的写库后**才刷新」的落实点：刷新不是「操作发生了」，
    //    而是「数据变了」。两者在这里正好分道（`alreadyExists` 也有操作，
    //    但库没动）。
    if (added == AddWordResult.alreadyExists) return;

    // 新词 → 立刻进复习队列（`next_review_at` = 现在 → 立即到期）
    // 🔑 只在**真的新增**时插：`alreadyExists` / `revived` 时状态已存在，
    //    重插会把用户已经积累的 FSRS 进度**清零**（`INSERT OR REPLACE`）。
    if (added == AddWordResult.added) {
      final review = ReviewListQuery(await ref.read(userDbProvider.future));
      await review.upsertState(
        wordId: wordId,
        spelling: spelling,
        state: 0, // 未学
        nextReviewAt: DateTime.now().toUtc(),
      );
    }

    // 🔴 **写库完成之后**才签「库变了」—— 顺序不可颠倒（先 bump 会让读端
    //    在写入完成前重查一次旧值，而修订号已经变过 → 不会再重算 → 表现为没刷新）。
    //
    // 到这里的两种情形都真的改了库：
    //   · `added`   → 新增 `user_word` + `card_review_state` → 复习页会多一个词
    //   · `revived` → `user_word.deleted = 0` + `updated_at` 刷新 → 复习页重新看到它
    revision.bump();

    // 🔑 成就检查（**写库成功之后** · 与 bump 同一时机原则：「数据变了」才检查）。
    //    `unawaited` —— 不阻塞查词浮层；失败在 `checkAndRefreshAchievements` 内 catch
    //    （成就永不影响查词主流程）。
    unawaited(_checkAchievementsAfterLookup(ref, unlockNotifier));
  } catch (e, st) {
    // 🔑 **只记日志**（见调用处说明）：查词写入失败不影响「看到词义」。
    debugPrint('[lookup] 写入失败 spelling=$spelling：$e\n$st');
  }
}

/// 查词写回后的成就检查（**不阻塞查词流程**）。
///
/// 🔑 与 `review_session_screen._checkAchievements` 同一模式：
///    · `unawaited` 调用 → 队列 notifier 由调用方传入（`ref` 可能已失效）
///    · 失败在 `checkAndRefreshAchievements` 内 catch → 不打断查词
///
/// 🔴 **必须定义在 `_writeBackLookup` 之外** —— 2026-09-29 两次踩坑记录：
///   ① 用「大括号计数」找函数结尾时，`_writeBackLookup` 的**命名参数 `{`**
///      （`WidgetRef ref, {`）会先被当成函数体 → 函数被插进签名中间。
///   ② 更隐蔽：**先插入、再定位**时，刚插入的 helper 里也有 `) async {`
///      → 第二次定位找到的是**自己**，越修越坏。
///   🔑 正确做法：**从 `) async {` 之后开始计数**，且**先定位再插入**（一次完成）。
Future<void> _checkAchievementsAfterLookup(
  WidgetRef ref,
  AchievementUnlockNotifier notifier,
) async {
  final newly = await checkAndRefreshAchievements(ref);
  if (newly.isEmpty) return;
  notifier.pushAll(newly);
}

/// 轻提示（沿用首页 toast 的样式 —— `snackBarTheme` 已是「ink 底 + page 字 + floating」）。
void _hint(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
}

