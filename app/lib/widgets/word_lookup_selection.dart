// CoEvo · 划词手势（`SelectionArea` + 选区菜单）—— **信息流页与书架页共用**
//
// # 🔴 为什么抽出来（2026-10-05）
//
// 白哥真机反馈：「书库中的书籍划词不成功」。查证结果：**书架页当初有意没做划词**
// （`book_reader_screen` 原文注释：「划词查词留到下一轮」）。
// 而信息流页的划词逻辑是 `reader_screen` 的私有实现 ⇒ 书架用不了。
//
// ⇒ 本组件把「划词手势」抽成公共件：
//   · **查词逻辑**在 `services/word_lookup.dart`（`lookupWord`，一处定义）
//   · **选中形态判定**在 `services/picked_text.dart`（纯 Dart · 本机可验）
//   · **菜单外观**在 `widgets/selection_menu.dart`
//   · **手势 + 菜单接入**在本文件
//
// 🔑 判据：**「行为一致」最可靠的实现方式 = 只有一处定义**。
//    若两页各写一份，改一处忘一处 ⇒ 两页体验静默不一致。
//
// # 🆕 2026-10-07 v2：**不再防抖，也不再自动查词** —— 改成「有选区就弹菜单」
//
// ## v1（旧）怎么做的
// `onSelectionChanged` + **300ms 防抖** → 直接 `lookupWord`。
// 防抖不是性能优化，是**正确性**：`onSelectionChanged` 在拖手柄期间**每帧触发**，
// 不防抖会打十几次库、弹十几个浮层。
//
// ## 🔴 v1 那套的根问题：**它在猜**
// 「划词即查词」意味着**没有任何用户动作**可当作「选完了」的信号 ⇒
// 只能靠「停手 300ms」去**猜**。两个后果：
//   · 拖动中途停一下（用户在思考）⇒ **误弹词卡**
//   · 拖手柄把相邻标点带进来（`vertical,`）⇒ 送去在线制卡 ⇒ 服务端 **400**
//
// ## ✅ v2：把「选择完成」交给框架
// 读 Flutter SDK（`widgets/selectable_region.dart`）确认：
// **`contextMenuBuilder` 就是「选择完成」的信号** ——
// `_handleTouchLongPressEnd` 与 `_onAnyDragEnd` 都会走 `_showToolbar()`，
// 而 `_showToolbar()` 会调用 `contextMenuBuilder`。
// ⇒ 判定与动作都挪进菜单：**用户在菜单上点哪一项，才走哪条路**。
//   · 🔑 **整套防抖（`kLookupDebounce` + `Timer`）删除** —— 信号从「猜」变成「框架给」
//   · 🔴 **「位置 / 翻转 / 夹紧」不全是框架的事**（2026-10-08 修正，原句是错的）——
//     框架只负责「把返回值插进 Overlay」+「给出锚点」；
//     **约束放松与定位必须我们自己补**（`CustomSingleChildLayout` +
//     `TextSelectionToolbarLayoutDelegate`，见 `_buildMenu` 的长说明）。
//     按原句「全部由框架负责」实现，会得到**全屏白屏**（真机已验证）。
//   · 🔑 「点外部收起」**才是**框架行为（`_SelectionToolbarWrapper` 包了
//     `TapRegion(groupId: SelectableRegion)`）。
//
// ## 🔑 判定为什么放在**菜单构建时**（而不是点击时）
// 菜单**第一项的名字**要在渲染时就确定（`查词` vs `翻译`）⇒ 判定必须发生在这里。
// 它是**纯函数**（`classifyPicked`）、无副作用，且**只调用一次**
// （结果由闭包捕获给 onTap 用）。
// ⇒ 判据：「**同一件事的口径只能一处权威**」—— 不在 onTap 里再判一遍。
//
// ## ⚠️ 与白哥 2026-09-27 那句的关系（如实记录，别当成矛盾）
// 他曾定：「**中间那个点『查词』是多余的，直接弹出底部浮窗就可以了**」。
// 那次是**单功能菜单**（菜单里只有一个按钮 ⇒ 纯多余一步）；
// v2 是**多功能菜单**（查词/翻译 · 划线 · 复制），且它是**新功能唯一的曝光入口**
// —— 若单词不弹菜单，用户大多数划选都看不到菜单，那些功能永远没有曝光。
// 📌 取舍记录在 `docs/design/visual-selection-menu-2026-10-07.html` §4。
//
// ⚠️ 本文件 import Flutter ⇒ **本机不可验证**（渲染），以 CI + 真机为准。
//    但**判定逻辑不在这里** —— 它在 `services/picked_text.dart`（纯 Dart · 本机可跑）。

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart' show SelectionChangedCause;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../providers/user_db_provider.dart';
import '../services/highlight_enqueue.dart';
import '../services/highlight_repository.dart';
import '../services/highlight_span.dart';
import '../services/picked_text.dart';
import '../services/word_lookup.dart';
import 'note_dialog.dart';
import 'selection_menu.dart';
import 'translation_sheet.dart';

/// 划线的**正文来源** —— 传了它，菜单里才会出现「划线」项。
///
/// 🔑 为什么要把「正文明文」也传进来：**框架不给偏移量**。
///    `onSelectionChanged` 给的 `SelectedContent` 只有 `plainText`
///    ⇒ 只能拿选中文本去正文明文里**反查**位置（见 `highlight_span.dart`）。
class HighlightSource {
  const HighlightSource({
    required this.type,
    required this.sourceId,
    this.chapterIdx,
    required this.plainText,
    this.title,
  });

  final HighlightSourceType type;

  /// 文章 id（整数的文本形式）或 `book.id`（端侧 uuid）。
  final String sourceId;

  /// 章内下标 —— **只有书有**（文章是单页）。
  final int? chapterIdx;

  /// 正文明文 —— **必须与渲染用的是同一份**，否则定位会偏。
  final String plainText;

  /// 这段正文的**出处标题**（文章标题 / 书名）。
  ///
  /// 🔑 与上面四个字段**性质不同**：那几个是**定位划线**必需的（少了就存不上），
  ///    这一个**只用于展示**（译文浮层顶栏那句「翻译 · 来自 XXX」）。
  ///    放这里而不是给 `WordLookupSelection` 再加一个平级参数，是因为
  ///    「标题」天然属于「这段正文的出处」—— 而调用方（两个阅读页）
  ///    构造 `HighlightSource` 时**手上正好有它**（`item.title` / `ch.bookTitle`）。
  ///
  /// ⚠️ 可空：拿不到就**不显示**来源（浮层退化为只写「翻译」）。
  ///    不要用 `sourceId` 顶替 —— `sourceId` 是 id（数字或 uuid），
  ///    把它当标题显示出来是**给用户看一串内部标识**（同族教训：界面上的值必须对用户有意义）。
  final String? title;
}

/// 把长按选中的文字包成「划词 → 弹选区菜单」。两页共用（信息流 / 书架）。
class WordLookupSelection extends ConsumerStatefulWidget {
  const WordLookupSelection({
    super.key,
    required this.child,
    this.articleId,
    this.onTap,
    this.highlightSource,
  });

  /// 被包裹的正文。
  final Widget child;

  /// 🆕 划线的正文来源（2026-10-07）。
  ///
  /// `null`（默认）⇒ 菜单**不含**「划线」项 —— 这样「划不了线」的页面
  /// 不会出现一个点了没反应的按钮。
  final HighlightSource? highlightSource;

  /// **痕迹键**（「本文查过的词」底色）—— `lookup_event.article_id`。
  ///
  /// · **信息流页**：传 `widget.articleId`（非空 int）⇒ 痕迹照旧
  /// · **书架页**：传 `null` ⇒ **有意不记痕迹**
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
  /// 原文/书架页的既有行为是「**单击正文 = 清空选区**」。若无条件接管单击，
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
  /// 当前选区文本 —— **给菜单用**。
  ///
  /// 🔴 为什么是字段，而不是在 `contextMenuBuilder` 里现取：
  /// 那个回调是**构建期**（不能 await），而且框架给它的签名只有
  /// `(BuildContext, SelectableRegionState)` —— **没有选中文本参数**。
  /// ⇒ 在 `onSelectionChanged`（框架把文本送上来的地方）缓存下来。
  ///
  /// 📌 时序是安全的：`_handleTouchLongPressEnd` 与拖手柄的每次 update
  ///    都先 `_updateSelectedContentIfNeeded()`（→ 本字段更新）再 `_showToolbar()`
  ///    （→ 菜单构建）。⇒ 菜单读到的**已经是最终文本**。
  String _picked = '';

  /// 当前是否有选区 —— 决定 [WordLookupSelection.onTap] **是否注册**。
  ///
  /// ⚠️ 只在**真正变化**时 `setState`：`onSelectionChanged` 在拖动手柄时会被**高频**调用
  ///    （每移动一次一次），无条件 setState 会让正文反复重建。
  bool _selectionActive = false;

  /// 选中文本变化 —— **只做两件事**：缓存文本 + 维护 [_selectionActive]。
  ///
  /// 🔴 **不再查词、不再防抖**（v2）。查词改由菜单触发（见类文档的「v2」）。
  void _onSelectionChanged(SelectedContent? content) {
    final text = _cleanPicked(content?.plainText);
    _picked = text;

    // 🔑 选区「有/无」的状态（供 onTap 注册与否）——**去重后再 setState**
    final active = text.isNotEmpty;
    if (active != _selectionActive) {
      setState(() => _selectionActive = active);
    }
  }

  /// **先收起菜单，再执行动作。**
  ///
  /// 🔑 顺序不能反 —— 「查词」会弹 `LookupSheet`（modal 浮层），
  /// 若菜单还挂着，两者会**叠在一起**（用户看到菜单压在词卡上）。
  void _runAfterClose(SelectableRegionState region, VoidCallback action) {
    region.hideToolbar();
    action();
  }

  /// 把选中内容**入队**（写 `highlight` + `card_review_state`），并给一句反馈。
  ///
  /// # 🔴 三条要点
  /// ① **定位失败也要存** —— `locateSelection` 找不到时给 `[-1,-1)`；
  ///    用户的意图是「记住这段」，位置只是附属。**不能因为定位不了就丢弃**。
  /// ② **必须给反馈** —— 存上了 / 没存上都要说（本项目判据：「静默失败」比报错更糟）。
  /// ③ 存成功要 `bump()` —— 复习页读的是 `card_review_state`，
  ///    不通知的话用户切到复习页**看不到刚划的那条**（「写了 A 端 ≠ B 端会显示」）。
  ///
  /// # 🆕 2026-10-07 成功时的 toast 带「写笔记」
  ///
  /// 🔑 为什么**必须**在这里给入口：**手感最新鲜** —— 刚读到、刚决定要记住。
  ///    等用户切到复习页时，他已经在想别的事了。
  /// ⚠️ 但**绝不能是强制步骤** —— 划线后弹一个「写笔记」表单会把「一步入队」
  ///    变成两步，而划线的核心体验就是**快**。⇒ 放在 toast 上，**不要就不点**。
  /// 打开译文浮层（菜单第 1 项的「翻译」）。
  ///
  /// 🔑 `onRemember` **只在有正文来源时才传** —— 拿不到来源就定位不了划线，
  ///    那样按钮点了会静默失败（本项目最忌讳的一类）。宁可不显示它。
  Future<void> _translate(String text) async {
    await showTranslationSheet(
      context,
      text: text,
      // 🔑 来源标题是**可选**的（`HighlightSource.title` 可空）——
      //    拿不到就传 null，浮层退化为只写「翻译」（不显示假的来源）。
      sourceLabel: widget.highlightSource?.title,
      // 🆕 2026-10-11：把**刚翻出来的译文**交给入队 —— 随划线一起入库。
      //
      // 🔴 不接住它就是**白花**：用户为这段文字付了额度（免费 10 次/月 · 订阅无限），
      //    而此前点「划线记住这段」之后译文**当场被丢掉** ⇒ 复习时只剩骨架、
      //    笔记页也没有（白哥真机反馈原话：「划线后笔记中没有记录译文，
      //    复习时也没有译文提示」）。
      // ✅ 零新增成本 —— 译文在点这个按钮**之前就已经在手上**。
      // ⚠️ 译文可空（浮层理论上可能只有空白段）⇒ 交给下游的归一化（`add()`）处理。
      onRemember: widget.highlightSource == null
          ? null
          : (String? translation) {
              _enqueueHighlight(text, translation: translation);
            },
    );
  }

  Future<void> _enqueueHighlight(String text, {String? translation}) async {
    final src = widget.highlightSource!;
    final span = locateSelection(plainText: src.plainText, picked: text);

    // 🔑 uuid 在**调用方**生成（`highlight_id.dart` 说明了为什么不放在那边）。
    //    这里提前取出来，是为了让成功后的 toast 能带上「写笔记」——
    //    它需要这条划线的 id（`setNote(id, ...)`）。
    final id = const Uuid().v4();

    var ok = false;
    try {
      final db = await ref.read(userDbProvider.future);
      final r = await enqueueHighlight(
        db: db,
        uuid: id,
        sourceType: src.type,
        sourceId: src.sourceId,
        chapterIdx: src.chapterIdx,
        startOffset: span.start,
        endOffset: span.end,
        text: text,
        // 🆕 从「翻译浮层」那条路径来的时候带着译文；从菜单直接划线时是 null
        translation: translation,
      );
      ok = r == HighlightEnqueueResult.ok;
    } catch (e, st) {
      debugPrint('[highlight] 入队失败：$e\n$st');
    }

    if (!mounted) return;
    if (ok) {
      // 🔑 写库之后才 bump（顺序不可颠倒 —— 先 bump 会让读端在写入完成前重查旧值）
      ref.read(userDbRevisionProvider.notifier).bump();
      _hint(
        '已加入记忆 · 复习里会再见',
        actionLabel: '写笔记',
        onAction: () => _writeNote(id, text),
      );
    } else {
      _hint('划线没存上，请再试一次');
    }
  }

  /// 给刚划的那条写 / 改笔记（走 [NoteDialog]）。
  ///
  /// ⚠️ 结果三态要分清（这正是 `NoteDialogResult` 存在的理由）：
  ///    · `null`（弹窗被取消）⇒ **什么都不做**
  ///    · `isClearing` ⇒ 清空笔记
  ///    · 有内容 ⇒ 保存
  Future<void> _writeNote(String id, String excerpt) async {
    final r = await NoteDialog.show(context, excerpt: excerpt);
    if (r == null || !mounted) return;

    try {
      final db = await ref.read(userDbProvider.future);
      await HighlightRepository(db).setNote(id, r.note);
      // 🔑 同入队：写库成功之后才 bump（正文下划线 / 划线清单跟着刷新）
      ref.read(userDbRevisionProvider.notifier).bump();
      if (!mounted) return;
      _hint(r.isClearing ? '笔记已删除' : '笔记已保存');
    } catch (e, st) {
      debugPrint('[highlight] 笔记保存失败：$e\n$st');
      if (!mounted) return;
      _hint('笔记没存上，请再试一次');
    }
  }

  /// 轻提示（沿用全项目同一款式：`snackBarTheme` 已是「ink 底 + page 字 + floating」）。
  ///
  /// # 🔑 带动作时为什么**自己拼 Row** 而不用 `SnackBarAction`
  ///
  /// `SnackBarAction` 只能设 `textColor`，而**没有哪一档 token 颜色是安全的**：
  /// 墨档是**深底浅字**、夜档是**浅底深字**（snackBar 底色取 `ink`）⇒
  /// 任何「朱砂系」颜色在其中一档都会低对比。
  /// ⇒ 用 `contentTextStyle` 的同一颜色（`page`）—— 与正文同色，
  ///    **任何档位都可读**；「它能点」由**下划线**表达（不靠颜色）。
  /// 📌 判据：**形态区分优于参数** —— 这里用「下划线」而不是「换个颜色」。
  void _hint(String message, {String? actionLabel, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        // 🔑 有动作时停久一点 —— 2 秒不够「看清 + 决定 + 点中」。
        //    （设计稿 §7 写的是 3–4 秒，取 4。）
        duration: Duration(seconds: actionLabel == null ? 2 : 4),
        content: actionLabel == null
            ? Text(message)
            : Row(
                children: [
                  Expanded(child: Text(message)),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: onAction,
                    // `opaque`：整块 padding 都可点（不然只有文字本身可点，
                    // 那对已经举起的手指来说太小）
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                      child: Text(
                        actionLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          // 下划线 = 「可点」的形态表达（颜色不指定 ⇒ 继承正文色）
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ));
  }

  /// 构建选区菜单 —— `contextMenuBuilder` 的落点。
  ///
  /// 🔑 **判定在这里发生一次**，结果由闭包捕获给 onTap。
  Widget _buildMenu(SelectableRegionState region) {
    final text = _picked;
    // 空选区不弹菜单（框架在「拖手柄的瞬间」会出现空选中）。
    if (text.isEmpty) return const SizedBox.shrink();

    final kind = classifyPicked(text);

    // 🔴🔴 **这层 `CustomSingleChildLayout` 不是「定位优化」，是在修一个白屏**
    //     （2026-10-08 白哥真机报：「正文长按菜单弹出时变成白屏」）。
    //
    // # 为什么会白屏（读 SDK 源码实测，非推测）
    //
    // `contextMenuBuilder` 的返回值被 `ContextMenuController` **直接 `Overlay.insert`**
    // （不是 `Positioned`）—— 而 Overlay 给**非定位 entry** 的约束是
    // **`BoxConstraints.tight(size)`（全屏紧约束）**，SDK 原注释：
    // 「Equivalent to BoxConstraints used by RenderStack for `StackFit.expand`」。
    // 该约束经 `_SelectionToolbarWrapper`（`TapRegion → Directionality → FadeTransition
    // → CompositedTransformFollower`；最后者 `extends RenderProxyBox` 且**不覆写
    // `performLayout`**）**原样透传**到我们返回的菜单上。
    //
    // 🔴 于是菜单被撑成**全屏**，而它的实心底 `Container(color: card)` 就盖住了整屏
    //    —— 墨/格档的 `card` 是白色 ⇒ **用户看到的就是"白屏"**
    //    （旁证：空选区返回的 `SizedBox.shrink()` 同样被撑满，但**没有底色**，不白）。
    //
    // # 为什么不能「自己限制尺寸」绕过
    //
    // `ConstrainedBox` / `SizedBox` 之类只会 `enforce`，遇**更紧**的父约束时
    // 只会**更紧**，**放松不掉**（这正是原实现的坑）。
    // ⇒ 唯一正确做法是**解除约束**，而这正是框架自带菜单走的路：
    //    `TextSelectionToolbarLayoutDelegate.getConstraintsForChild` 返回
    //    `constraints.loosen()`，并**顺带**按锚点做「上方放不下就翻转 + 水平夹紧」。
    //
    // ⚠️ 两条禁令：
    //   ① **别去掉这层包装** —— 去掉就是白屏（`_menuBody` 单独用必白）。
    //   ② **别改成别的"限制尺寸"写法** —— 放松约束只能靠 `loosen`。
    // 📌 判据：**「框架负责位置」≠「框架负责约束」** —— 约束放松是**调用方**的事
    //    （`selection_menu.dart` 的类文档过去写「位置/翻转/夹紧都是框架行为」，
    //    那句是错的，已回标）。
    final anchors = region.contextMenuAnchors;
    return CustomSingleChildLayout(
      delegate: TextSelectionToolbarLayoutDelegate(
        anchorAbove: anchors.primaryAnchor,
        // `secondaryAnchor` 可空（只有右键路径才给）⇒ 退回 primaryAnchor
        anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      ),
      child: _menuBody(region, text, kind),
    );
  }

  /// 菜单本体 —— **只负责「长什么样」**。
  ///
  /// 🔴 约束与定位**都不在这里**：`contextMenuBuilder` 必须把它包在
  ///    `CustomSingleChildLayout` + `TextSelectionToolbarLayoutDelegate` 里
  ///    （见 [`_buildMenu`] 的长说明；不包 ⇒ 被 Overlay 撑成全屏 ⇒ 白屏）。
  /// 📌 判据：**「长什么样」与「被给多大、摆在哪」是两件事** —— 拆开才改得动。
  Widget _menuBody(SelectableRegionState region, String text, PickedKind kind) {
    return SelectionMenu(items: [
      if (kind == PickedKind.word)
        SelectionMenuItem(
          label: '查词',
          icon: Icons.menu_book_outlined,
          onTap: () => _runAfterClose(
            region,
            // 🔑 送进去的是 **`text`（原始选中文本）**，不是剥标点后的结果 ——
            //    见 `picked_text.dart` 头部的「它不参与查词」。
            () => lookupWord(context, ref, text, articleId: widget.articleId),
          ),
        )
      else
        SelectionMenuItem(
          label: '翻译',
          icon: Icons.translate,
          onTap: () => _runAfterClose(region, () => _translate(text)),
        ),
      // 🆕 第 2 项：划线 —— **只有拿到「正文来源」时才出现**
      //    （文章页 / 书架页各自传；拿不到的页面不该出现一个点了没反应的按钮）
      if (widget.highlightSource != null)
        SelectionMenuItem(
          label: '划线',
          icon: Icons.edit_outlined,
          onTap: () => _runAfterClose(region, () => _enqueueHighlight(text)),
        ),
      SelectionMenuItem(
        label: '复制',
        icon: Icons.content_copy_outlined,
        // 🔑 用框架的 `copySelection` —— 它走 `SelectableRegion` 自己的剪贴板通道。
        //    不要自己写 `Clipboard.setData`：那会绕过选区语义，且是多出的第二份实现。
        //    依据：读 SDK 确认 `SelectableRegionState.copySelection` 是**公开** API（:1852）。
        onTap: () => _runAfterClose(
          region,
          () => region.copySelection(SelectionChangedCause.toolbar),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // 🔑 内层包一层（比 `SelectableRegion` 深 ⇒ 竞技场里先赢，见 [onTap] 的说明）。
    //
    // ⚠️ `behavior: HitTestBehavior.opaque` —— 让**正文空白处**也能触发
    //    （Kindle 式「点哪都能唤出」）。若用 `deferToChild`，只有恰好点在
    //    文字上才生效，留白处点了没反应（且不报错，最难查的那种）。
    //
    // 🔴🔴 **widget 结构必须恒定，只切换 `onTap`**（2026-10-11 修正）
    //
    // 白哥真机报的「**iOS 上长按选中、松手后两头没有手柄、无法调整**
    // （安卓两头有光标可调）」就是**违反这一条**造成的：
    //
    // 旧写法是 `_selectionActive ? body : GestureDetector(...)` ——
    // 选区一出现就让 child 的 **widget 类型**从 `GestureDetector` 变成裸 `body`
    // ⇒ Flutter **卸载旧 Element 树、重建**（确定性行为，不是推测）
    // ⇒ `_selectionDelegate` 里的 `SelectionPoint` 指向**已 unmount 的旧 RenderObject**
    // ⇒ 算不出选区几何 ⇒ `selectable_region.dart` 的 `_updateSelectionStatus` 走 else
    //    分支 **`_selectionOverlay.dispose()`** ⇒ **手柄被销毁**。
    //
    // ⚠️ 为什么只在 iOS 暴露：**iOS 在「长按一开始」显示手柄、Android 在「长按结束」
    //    再显示一次**（`selectable_region.dart:1000` / `:1020`）
    //    ⇒ **Android 有兜底、iOS 没有**。
    // ⚠️ 菜单却不受影响：`_showToolbar` 发现 overlay 为 `null` 会**重建**它
    //    ⇒ 症状正好是「能点划线，但两头没光标」—— 与白哥的描述**逐字吻合**。
    //
    // 🔑 **等价性说明**：`onTap: null` 时 Flutter **不创建** `TapGestureRecognizer`
    //    （`GestureDetector` 的 `gestures` 里没有它）⇒ 事件照旧落到 `SelectableRegion`
    //    ⇒「单击清空选区」的原行为**一字不差**。
    //    📌 原判据仍然成立（且这正是它的正确形态）：
    //       「**要让出事件，只能不注册识别器**」—— 这里是**不注册**，
    //       而不是 handler 里 `if (有选区) return;`（那会吃掉这次点击）。
    final body = widget.child;
    final withTap = widget.onTap == null
        // 这个页面本来就没有「单击」需求 ⇒ 结构恒定（永远不包 `GestureDetector`）
        ? body
        : GestureDetector(
            onTap: _selectionActive ? null : widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: body,
          );

    return SelectionArea(
      onSelectionChanged: _onSelectionChanged,
      // 🔑 v2：**返回真实菜单**（不再是 `SizedBox.shrink()`）。
      //    框架在「选择完成」时调用它（长按结束 / 拖手柄松手）——
      //    这正是我们之前缺的那个信号（v1 只能靠 300ms 防抖猜）。
      // ⚠️ 返回空 = 不弹菜单（`_picked` 为空时）。
      contextMenuBuilder: (_, region) => _buildMenu(region),
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
/// 🆕 **2026-10-07 v2 补充**：`services/picked_text.dart` 里的「剥首尾」**只用于判定**
///    （决定菜单第一项叫什么）—— 它**不回流到查词**，所以上面这条边界仍然成立。
///
/// ⚠️ **已知边界**：长按后**拖动手柄**会把相邻标点带进来（`vertical,`）——
///    · 2026-10-01 前：会提示「词库里没有『vertical,』」
///    · 2026-10-01 后（A2）：会**送去在线制卡** —— 服务端的 `validate_spelling`
///      会以 400 拒掉带标点的输入（`bad!word` 之类），用户看到的是**参数错误**。
///    · 🆕 2026-10-07 v2：**这条路径仍然存在**（判定剥标点只影响菜单文案，不改变
///      送进 `lookupWord` 的原文本）⇒ 正解没变：查询层加**「精确 → 剥标点」两段查**。
///      那要同步 `verify_word_query`，**不在本轮**。
///    📌 主路径不受影响：长按**默认选中的就是一个词**（不含标点）。
String _cleanPicked(String? raw) => raw?.trim() ?? '';
