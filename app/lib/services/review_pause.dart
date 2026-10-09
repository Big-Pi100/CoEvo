// CoEvo · 复习卡的「暂停」—— **分派与文案的唯一权威**（纯 Dart · 本机可验）
//
// # 为什么单独成一个文件
//
// 复习列表里有**两种卡**，它们的「暂停」落在**两张不同的表**上：
//
// | 卡片 | id 形态 | 暂停落在哪 |
// |---|---|---|
// | 生词 | `w…`（词库 id）| `user_word.deleted = 1`（= 移出生词本 / 先不学了）|
// | 划线 | `hl:<uuid>` | `highlight.paused = 1`（见 `user_db_schema.sql` 该列）|
//
// 🔴 **2026-10-08 之前的实现只有生词那一支** ⇒ 划线卡点「暂停」会：
//    写端 `UPDATE user_word … WHERE word_id = 'hl:…'` 影响 **0 行**
//    ⇒ 仓储返回 `false` ⇒ 页面 `if (!changed) return;` ⇒ **静默、连提示都没有**。
//    （白哥真机报「暂停对划线的卡片无效」；而「静默失败」正是本项目最忌讳的一类。）
//
// 🔑 所以「按 id 形态分派」是一条**业务判据**，不是 UI 细节 ——
//    它必须待在纯 Dart 层：埋在页面里就只能靠真机验（本机渲染不了 Flutter）。
//    📌 同 `picked_text.dart` / `spelling_grader.dart` 的理由。
//
// ⚠️ 本文件不得 import 任何 Flutter 包 —— 这是它唯一的硬约束
//    （一旦引入，「本机可跑」这个前提立刻失效）。

import 'highlight_id.dart' show isHighlightWordId;

/// 这张卡是划线卡吗？
///
/// 🔴 判据**只能**来自 `highlight_id.dart`（那里写着「任何对 `word_id` 做形态判断的
///    地方都必须先问它」）—— 本函数只是给复习领域起一个读得懂的名字，**不另立判据**。
bool isHighlightCard(String wordId) => isHighlightWordId(wordId);

/// 暂停一张卡 —— 按卡片类型**分派到对应的写端**。
///
/// 两个回调形如「入参 `wordId`、返回『本次是否真的改了状态』」。
/// 🔑 依赖倒置：本函数不关心仓储怎么构造（那是调用方的事）⇒
///    它可以被脚本用**两个假实现**独立驱动，不需要真 DB。
///
/// 返回 `false` 的两种含义（都**不是**错误，调用方按「无改动」处理）：
/// ① 它本来就是该状态（幂等）；② 该 id 不归那个仓储管。
Future<bool> pauseReviewCard({
  required String wordId,
  required Future<bool> Function(String wordId) pauseWord,
  required Future<bool> Function(String wordId) pauseHighlight,
}) =>
    isHighlightCard(wordId) ? pauseHighlight(wordId) : pauseWord(wordId);

/// 暂停成功后的提示文案 —— **按卡片类型分两套**。
///
/// 🔴 为什么不能共用一句：生词那句是「**再次查词就会恢复**」，
///    而划线卡**没有「再次查词」这个动作** —— 照抄就是**说谎**
///    （用户会照做，然后发现没用；这比不说更糟）。
///    划线卡的恢复入口在「笔记」页（见 `highlights_screen`）。
///
/// ⚠️ 文案里**点名出口**（「可在『笔记』里恢复」）而不是只说「已暂停」——
///    判据：**「静默失败 + 无出口」比报错更糟**，而「暂停了但不知去哪恢复」
///    正是「有动作、无出口」。
String pausedMessage({
  required String wordId,
  required String spelling,
}) =>
    isHighlightCard(wordId)
        ? '已暂停这条笔记，可在「笔记」里恢复。'
        : '已暂停「$spelling」，再次查词就会恢复。';

/// 暂停**之前**的二次确认正文 —— 与 [pausedMessage] **同一处权威**。
///
/// # 为什么需要二次确认（白哥 2026-10-08 真机反馈「很容易误点」）
///
/// 这个动作**改变了排期** —— 那张卡从复习列表里消失，而「它去哪了」在
/// **当前界面上完全看不见**：用户只会发现「列表少了一条」，恢复入口在**另一个 tab**。
/// 并且它是**单击**触发的（右滑 / 长按那类手势天然不易误触）。
///
/// 📌 判据：**「后果不可见 + 恢复路径远」的动作才值得加确认** ——
///    给每个动作都加确认，会让每一步都多一次点击。
///    这同 `ui-control-placement` 的两维思路：**确认也是一种常驻成本**，
///    只花在真正会误伤的地方。
///
/// 🔴 文案必须与 [pausedMessage] **说同一件事**（后果 + 出口）——
///    「确认框说 A、结果提示说 B」是最容易漂的一处，所以两条放同一个文件。
String pauseConfirmBody({
  required String wordId,
  required String spelling,
}) =>
    isHighlightCard(wordId)
        ? '这条笔记会离开复习列表。\n可以随时在「笔记」里让它回来。'
        : '「$spelling」会离开复习列表。\n你再次查这个词，它就会回来。';
