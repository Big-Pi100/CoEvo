// CoEvo · 划词手势（`SelectionArea` + 防抖）—— **信息流页与书库页共用**
//
// # 🔴 为什么抽出来（2026-10-05）
//
// 白哥真机反馈：「书库中的书籍划词不成功」。查证结果：**书库页当初有意没做划词**
// （`book_reader_screen` 原文注释：「划词查词留到下一轮」）。
// 而信息流页的划词逻辑是 `reader_screen` 的私有实现 ⇒ 书库用不了。
//
// ⇒ 本组件把「划词手势」抽成公共件：
//   · **查词逻辑**在 `services/word_lookup.dart`（`lookupWord`，一处定义）
//   · **手势 + 防抖**在本文件（一处定义）
//   · 两页只需各自「包一层」即可
//
// 🔑 判据：**「行为一致」最可靠的实现方式 = 只有一处定义**。
//    若两页各写一份防抖，改一处忘一处 ⇒ 两页体验静默不一致。
//
// ⚠️ 本文件 import Flutter ⇒ 本机不可验证（渲染），以 CI + 真机为准。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/word_lookup.dart';

/// 划词防抖时长 —— **两页共用的唯一权威**。
///
/// 🔴 **防抖不是性能优化，是正确性** —— `onSelectionChanged` 在
/// 「拖动手柄调节范围」期间会**连续触发**。若直接查库：一次「长按 + 微调」
/// = 十几次 SQLite 查询 + 十几个叠起来的浮层。
///
/// 🔑 300ms 的取值理由：人手拖动是**连续移动**（间隔通常 < 100ms），
///    而「停下来看结果」的停顿远超 300ms ⇒ 这个阈值能把「一次连续操作」
///    合并成一次查词，又不会让用户等得可感。
const Duration kLookupDebounce = Duration(milliseconds: 300);

/// 把长按选中的文字包成「划词即查」。两页共用（信息流 / 书库）。
class WordLookupSelection extends ConsumerStatefulWidget {
  const WordLookupSelection({
    super.key,
    required this.child,
    this.articleId,
    this.onTap,
  });

  /// 被包裹的正文。
  final Widget child;

  /// **痕迹键**（「本文查过的词」底色）—— `lookup_event.article_id`。
  ///
  /// · **信息流页**：传 `widget.articleId`（非空 int）⇒ 痕迹照旧
  /// · **书库页**：传 `null` ⇒ **有意不记痕迹**
  ///   （书不是「文章」：它的 id 是 String uuid，硬塞 int 会**污染痕迹数据**）
  ///
  /// 📌 `null` 的语义是「有意不记」，不是「漏传」—— 见
  ///    `services/word_lookup.dart` 头部关于 `articleId` 可空的那一节。
  final int? articleId;

  /// 🆕 **单击正文**时回调（2026-10-06 —— 阅读设置面板的入口，spec §5.1）。
  ///
  /// 默认 `null` ⇒ **不注册点击识别器** ⇒ 行为与改动前**逐字相同**。
  ///
  /// # 🔴 为什么这个回调必须放在**本组件内部**（不能在外面包一层 `GestureDetector`）
  ///
  /// 读 Flutter SDK 源码（`widgets/selectable_region.dart`）实测：
  ///
  /// | 手势 | 注册者 | 位置 |
  /// |---|---|---|
  /// | **长按（划词）** | `LongPressGestureRecognizer` | `:717` |
  /// | **单击** | `TapAndHorizontalDragGestureRecognizer`（`onTapUp`）| `:683` |
  /// | 右键 | `TapGestureRecognizer`（**只绑 `onSecondaryTapDown`**）| `:458` |
  ///
  /// ⇒ **手势语义上「单击」与「长按」确实不冲突**（是两个不同的 recognizer）。
  ///
  /// ⚠️ **但竞技场层面，外面包一层拿不到**：手势竞技场按「**加入顺序**」裁决，
  ///    而加入顺序 = hit test 顺序 = **内层先**。外层 `GestureDetector` 比
  ///    `SelectableRegion` 浅 ⇒ **它总是后加入** ⇒ 单击被内层吃掉。
  /// ✅ 放在**本组件内部**（作为 `SelectionArea` 的 child）⇒ 它**比内层的
  ///    `SelectableRegion` 更深** ⇒ **先加入竞技场** ⇒ 单击归我们。
  ///    （长按仍是 `LongPressGestureRecognizer` 在 500ms 后先 accept ⇒ 划词不受影响。）
  ///
  /// # 🔑 与「单击取消选区」如何共存（**这是关键**）
  ///
  /// 原文/书库页的既有行为是「**单击正文 = 清空选区**」。若无条件接管单击，
  /// 用户长按选中、看完浮层后想取消选区，点一下却弹出**设置面板** —— 手感是错的。
  ///
  /// ⇒ 用 [selectionActive] 分流，且**靠「注册与否」分流**（不是靠 handler 里判断）：
  ///    · **有选区** ⇒ `onTap` 传 **`null`** ⇒ `GestureDetector` **不创建**该识别器
  ///      （读源码：`onTap == null` 时不注册 `TapGestureRecognizer`）
  ///      ⇒ 单击**落到 `SelectableRegion`** ⇒ **清空选区**（原行为，一字不差）
  ///    · **无选区** ⇒ 注册 ⇒ 单击 ⇒ **弹面板**
  ///
  /// 📌 为什么用「注册与否」而不是「handler 里 `if (有选区) return;`」：
  ///    后者仍会**吃掉**这次点击 ⇒ 选区永远取消不掉（且没有任何报错）。
  ///    🔑 判据：**要让出事件，只能不注册识别器**（handler 里 return 拦不住竞技场）。
  final VoidCallback? onTap;

  @override
  ConsumerState<WordLookupSelection> createState() =>
      _WordLookupSelectionState();
}

class _WordLookupSelectionState extends ConsumerState<WordLookupSelection> {
  Timer? _lookupDebounce;

  /// 当前是否有选区 —— 决定 [WordLookupSelection.onTap] **是否注册**。
  ///
  /// ⚠️ 只在**真正变化**时 `setState`：`onSelectionChanged` 在拖动手柄时会被**高频**调用
  ///    （每移动一次一次），无条件 setState 会让正文反复重建。
  bool _selectionActive = false;

  @override
  void dispose() {
    // 🔴 必须取消：定时器回调里会 `lookupWord`（用 context）——
    //    页面已销毁还触发会报「Looking up a deactivated widget's ancestor」。
    _lookupDebounce?.cancel();
    super.dispose();
  }

  /// 选中文本变化 → **防抖后直接查词**（没有中间的「查词」按钮）。
  void _onSelectionChanged(SelectedContent? content) {
    _lookupDebounce?.cancel();

    final text = _cleanPicked(content?.plainText);

    // 🔑 选区「有/无」的状态（供 onTap 注册与否）——**去重后再 setState**
    final active = text.isNotEmpty;
    if (active != _selectionActive) {
      setState(() => _selectionActive = active);
    }

    if (text.isEmpty) {
      // 拖动把手的瞬间会出现「空选中」→ 撤掉已排队的那次，但不查
      return;
    }

    _lookupDebounce = Timer(kLookupDebounce, () {
      if (!mounted) return;
      lookupWord(context, ref, text, articleId: widget.articleId);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 🔑 内层包一层（比 `SelectableRegion` 深 ⇒ 竞技场里先赢，见 [onTap] 的说明）。
    //
    // ⚠️ `behavior: HitTestBehavior.opaque` —— 让**正文空白处**也能触发
    //    （Kindle 式「点哪都能唤出」）。若用 `deferToChild`，只有恰好点在
    //    文字上才生效，留白处点了没反应（且不报错，最难查的那种）。
    final body = widget.child;
    final withTap = widget.onTap == null || _selectionActive
        ? body // 无回调 / 有选区 ⇒ **不注册** ⇒ 单击归 SelectableRegion（清空选区）
        : GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: body,
          );

    return SelectionArea(
      onSelectionChanged: _onSelectionChanged,
      // 🔑 **必须显式返回空** —— 不提供时 `SelectionArea` 会用默认菜单
      //    （复制/全选/…）。本项目「划词即查词」，不要系统菜单。
      contextMenuBuilder: (_, __) => const SizedBox.shrink(),
      child: withTap,
    );
  }
}

/// 归一化长按选中的文本（**只做输入卫生，不做任何猜测**）。
///
/// # 🔴 为什么不在这里剥首尾标点（我一度这么写，被实测否掉）
/// 直觉是「`word,` 在词库里查不到 → 剥掉逗号就好了」。但实测词库后发现**两个反例**：
///
/// | 词库真实词条 | 剥首尾标点后 | 后果 |
/// |---|---|---|
/// | **`a.m.`** · **`dr.`** | `a.m` · `dr` | 🔴 **反而查不到**（原词条就带句点） |
/// | **`café`** · `cybercafé` · `français` | ~~`caf`~~（若用 `[^A-Za-z0-9]`） | 🔴 **把词毁掉** |
///
/// 而词库里含内部标点的词共 **64 个**（`e-mail` · `brother-in-law` · `driver's license` …）
/// → 「把标点剥掉」这个动作**需要知道词库里有什么**，那是查询层的信息，UI 层没有。
///
/// 🔑 **结论：UI 层只做「去空白」这一件无争议的事**；标点/大小写等**宽松匹配属查询层**
///    （它才知道精确命中是否失败、该不该再试一次）。
///
/// ⚠️ **已知边界（待办 · 现状已随 A2 变化）**：长按后**拖动手柄**会把相邻标点带进来
///    （`vertical,`）——
///    · 🆕 2026-10-01 前：会提示「词库里没有『vertical,』」
///    · 🆕 2026-10-01 后（A2）：会**送去在线制卡** —— 服务端的 `validate_spelling`
///      会以 400 拒掉带标点的输入（`bad!word` 之类），用户看到的是**参数错误**。
///    ⇒ 体验上仍是「不理想但不出错」，正解没变：查询层加**「精确 → 剥标点」两段查**。
///      那要同步 `verify_word_query`，**不在本轮**。
///    📌 主路径不受影响：长按**默认选中的就是一个词**（不含标点）。
String _cleanPicked(String? raw) => raw?.trim() ?? '';
