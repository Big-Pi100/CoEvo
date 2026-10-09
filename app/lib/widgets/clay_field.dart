/// 粘土**输入框** —— 语汇里的「凹陷」档（spec §3.6 / §6.2）。
///
/// # 为什么是凹陷，不是凸起
///
/// 规格 §〇 的三条基础规则第 1 条把全应用的元素分成三类：
///
/// > **内容平面 / 交互粘土 / 输入凹陷** —— 文字永不动；有体积的只可能是可点的东西
///
/// 输入框正落在第三类。§6.2 明列它的成员：「搜索框 · **可输入字段** · 笔记输入区」。
///
/// # 🔴 与原型的一处冲突 —— **按 spec，不按原型**
///
/// `profile-redesign-2026-09-29.html` 第 ⑤ 屏（登录页）里的 `.inp` 画的是
/// **平面 + 细边框**：
/// ```css
/// .inp{background:var(--card);border:1px solid var(--line);border-radius:12px;…}
/// ```
/// 而 §3.6 定义输入类必须是**凹陷**（两个 inset 方向互换、无外阴影）。
/// 项目已定的裁决顺序是「**设计稿与 spec 冲突按 spec**」
/// （见 `MEMORY.md` 的文档分层），所以这里走凹陷。
/// 📄 该冲突已记入 `profile-redesign-plan-2026-09-29.md` 的实施记录。
///
/// # 实现：直接复用 `ClayState.pressed`
///
/// `ClayPainter` 的 `pressed` 分支**逐字就是** §3.6 的凹陷公式
/// （外阴影消失 + 两个 inset 方向互换），所以不需要新造一种态 ——
/// 这也与 `HeaderChip`（未激活态）、`BookmarkButton`（未收藏态）**同一语汇**：
/// > 凹陷 = 「可以按下去」。
///
/// ⚠️ 本组件**不传** `Clay.onTap` —— 点击应当由内层 `TextField` 处理（聚焦 + 唤起键盘）。
///    若给 `Clay` 挂了 `onTap`，它会包一层 `GestureDetector`（`HitTestBehavior.opaque`）
///    抢先吃掉点击，输入框就再也聚焦不了。**「不可点」在这里是刻意的，不是漏接。**
///
/// # 尺寸
/// `padding 13 + 字号 13.5 × 行高 ≈ 45px` → 由 `Clay` 按**真实高度**自动选到 **md 档**
/// （§3.5：阴影参数必须随元素尺寸缩放）。**不要**硬传 `borderRadius`，
/// 那会跳过尺寸阶梯（同 `ClayButton` 的注释）。
library;

import 'package:flutter/material.dart';

import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class ClayField extends StatelessWidget {
  const ClayField({
    super.key,
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.trailing,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;

  /// 占位文案（原型 `.inp.ph` 用 `ink3`）。
  final String? hintText;

  /// 密码框。仅影响 `TextField.obscureText`，不改变外观。
  final bool obscureText;

  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  /// 自动聚焦（弹窗打开时把光标放进第一个框）。
  final bool autofocus;

  /// 提交中置 `false` —— 与 `ClayButton(enabled:)` 同步关闭，避免重复提交。
  ///
  /// ⚠️ 它只关 `TextField` 自己的输入，**视觉上不改变凹陷**
  ///    （凹陷是「输入区」的固有形态，不是状态）。
  final bool enabled;

  /// 凹陷框**右侧**的可点元素（2026-10-05 新增）。
  ///
  /// 🔑 **这是通用形态，不是「密码专用」** —— 它只是「在框内右侧放一个可点件」，
  ///    首个使用者是「修改密码」弹层的**显隐切换**（👁）。
  ///    📌 判据：**别把某个业务概念塞进通用组件**（原打算叫 `obscureToggle`，
  ///    那会让 `ClayField` 知道「密码」这件事，而它本不该知道）。
  ///    若将来搜索框要「清空按钮」，同一个参数即可复用。
  ///
  /// ⚠️ 传 `null` 时**布局与从前完全一致**（`Row` 里只有那个 `Expanded`）——
  ///    既有调用点（登录/注册弹窗）不受影响。
  final Widget? trailing;

  /// 多行输入（2026-10-07 新增，首个使用者：**划线笔记**）。
  ///
  /// 🔑 与 `trailing` 同一条取向：**这是通用形态，不是「笔记专用」** ——
  ///    它只是「输入框能长高」，任何长文本输入都该能用。
  ///
  /// ⚠️ 默认 `1` ⇒ **既有调用点布局逐字不变**
  ///（同 `TraceMarkdown.traceEnabled` 那一族原则：加参数时让旧行为成为默认值）。
  ///
  /// 📌 `minLines` 决定「空的时候也有多高」—— 笔记框给 `3`
  ///    是为了**看得出这里能写多行**（单看一行高的框，用户不会想到可以换行）。
  final int minLines;
  final int maxLines;

  /// 原型 `.inp{border-radius:12px}` —— 写死，不走 token（同 `HeaderChip` 的 13）。
  static final BorderRadius _radius = BorderRadius.circular(12);

  /// 原型 `.inp{padding:13px 14px}`。
  static const EdgeInsets _pad = EdgeInsets.symmetric(horizontal: 14, vertical: 13);

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final ink = Color(t.ink.argb32);

    return Clay(
      state: ClayState.pressed,
      // ⚠️ 必须显式给 `sunken`：`Clay` 默认填充是 `clayFill`（= `card`），
      //    而凹陷区应当比卡面更暗（同 `HeaderChip` 的未激活态、`BookmarkButton`）。
      fill: t.sunken,
      borderRadius: _radius,
      child: Row(
        children: [
          Expanded(
            child: TextField(
          controller: controller,
          enabled: enabled,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          // 🔴 四种 border 全部显式置 `none` —— 只关 `border` 不够：
          //    `TextField` 在**聚焦**时会切到 `focusedBorder`，
          //    只写 `border` 的话，一点进输入框就会冒出一条 Material 下划线
          //    （粘土容器里出现一条 Material 线 = 两个体系混在一起）。
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            isDense: true,
            contentPadding: _pad,
            hintText: hintText,
            hintStyle: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13.5,
              color: Color(t.ink3.argb32),
            ),
          ),
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13.5,
            color: ink,
          ),
              // 光标用强调色 —— 这是输入焦点**唯一**的视觉提示（见类文档「待目视」）。
              cursorColor: Color(t.accent.argb32),
            ),
          ),
          // 🔑 `trailing == null` 时这一段不产生任何布局 ⇒ 既有调用点零变化。
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(right: 13),
              child: trailing,
            ),
        ],
      ),
    );
  }
}
