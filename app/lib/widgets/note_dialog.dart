/// **划线笔记弹窗** —— 给一条划线写 / 改 / 删笔记。
///
/// # 🔑 两个入口共用同一份实现（判据：一处定义）
///
/// | 入口 | 位置 | 为什么在那里 |
/// |---|---|---|
/// | **划线之后** | 信息流 / 书架正文的 toast 上的「写笔记」 | 手感最新鲜 —— 刚读到、刚决定要记住 |
/// | **复习结果页** | 划线卡判定完之后 | 复习时**反而最想补笔记**（默不出来时正好记下「我为什么没记住」）|
///
/// ⚠️ **不能是强制步骤**：划线后写笔记是可选的 ——
///    强制的话会把「一步入队」变成两步（划线的核心体验就是「快」）。
///
/// # 🔴 硬约束：**判定之前不得显示笔记**
///
/// 笔记是用户自己写的，**很可能就写着答案**（「这句的意思是…」）——
/// 判定前露出来就是**泄题**。与「原文」同一条规则：**判定后才给**。
/// ⇒ 本弹窗会在**复习结果页**被调用，但那一定是「已作答」那一支；
///   `_HighlightResultCard` 的 `showNote` 参数守的就是这条（见其文档）。
///
/// # 🔑 笔记挂在**划线上**，不是另开一套内容体系
///
/// 2026-10-06 白哥否过「私密笔记」—— 那次否的是**挂在文章任意位置的独立笔记**；
/// 本功能是**挂在一条已有划线上**的备注（只多一个 `note` 字段）。
/// 📌 判据：**同一个词挂在不同对象上，是不同的功能** —— 不能拿旧结论一票否决。
///    （依据：白哥 2026-10-07「划线后用户可以自己写一个笔记，可以在划线的时候写，
///      也可以在卡片里写」）
///
/// # 版式
/// 与 `ChangeEmailDialog` 同一套外壳（`CoDialog` + `ClayField` + `ClayButton`），
/// **刻意不新画一套** ——「弹窗长什么样」全库只该有一处定义。
library;

import 'package:flutter/material.dart';

import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'clay_button.dart';
import 'clay_field.dart';
import 'co_dialog.dart';

/// 笔记弹窗的结果。
///
/// 🔴 **为什么不是「返回 `String?`」**：那样「取消」与「清空笔记」都是 `null`，
///    调用方分不出「用户什么都没做」和「用户要删掉笔记」——
///    前者不该写库，后者必须写。**一个可空类型表达不了三态。**
class NoteDialogResult {
  const NoteDialogResult(this.note);

  /// `null` = **清除笔记**；非空 = 新内容。
  final String? note;

  /// 是否是「清除」。
  bool get isClearing => note == null;
}

class NoteDialog extends StatefulWidget {
  const NoteDialog({
    super.key,
    required this.excerpt,
    this.initial,
  });

  /// 划线的原文（摘录）—— 让用户知道在给**哪一句**写笔记。
  final String excerpt;

  /// 已有笔记（`null` = 还没写过）。
  final String? initial;

  /// 弹出本弹窗。
  ///
  /// 返回：`null` = 取消 / 关闭（**什么都不做**）；否则见 [NoteDialogResult]。
  static Future<NoteDialogResult?> show(
    BuildContext context, {
    required String excerpt,
    String? initial,
  }) {
    return CoDialog.show<NoteDialogResult>(
      context,
      builder: (_) => NoteDialog(excerpt: excerpt, initial: initial),
    );
  }

  @override
  State<NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<NoteDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasExisting => (widget.initial ?? '').trim().isNotEmpty;

  void _save() {
    // 🔑 只有空白 ⇒ 与「清除」等价（不是存一个空串进库）。
    //    判据：**别让同一个语义有两种表示** —— 空串与 null 在库里并存，
    //    将来「有没有笔记」的判断就会在两处各写一个版本。
    final v = _controller.text.trim();
    Navigator.of(context).pop(NoteDialogResult(v.isEmpty ? null : v));
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return CoDialog(
      title: '笔记',
      actions: [
        ClayButton(
          label: '保存',
          expanded: true,
          onTap: _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 给哪一句写（摘录，最多 3 行）──
          Text(
            widget.excerpt,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 13,
              height: 1.65,
              fontStyle: FontStyle.italic,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.md),

          // ── 输入（多行）──
          ClayField(
            controller: _controller,
            hintText: '写点什么…（只有你自己看得到）',
            // 🔑 `minLines: 3` 让空框也有三行高 ——
            //    单行高的框，用户不会想到可以换行。
            minLines: 3,
            maxLines: 6,
            autofocus: true,
            textInputAction: TextInputAction.newline,
          ),

          // ── 已有笔记时给「删除」出口 ──
          //    ⚠️ 不给出口的话，用户只能「清空 → 保存」自己猜出来 ——
          //    「有提示、无出口」比没有提示更糟（本项目既有判据）。
          if (_hasExisting) ...[
            const SizedBox(height: CoSpacing.sm),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(const NoteDialogResult(null)),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Text(
                  '删除这条笔记',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
