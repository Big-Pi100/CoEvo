// CoEvo · 6 格验证码输入（「忘记密码」第 2 步用）
//
// # 🔴 关键实现决策：「1 个隐藏输入框 + 6 个展示格」
//
// 白哥 2026-10-05 定的是「**6 个格子**」（相对我原建议的「单框 + 等宽字距」）。
// 但那是**视觉**要求 —— 实现上**没有**用 6 个 `TextField`，原因如下：
//
// ## 为什么不用 6 个真 `TextField`
//
// 6 个真输入框要自己实现「跳格 / 退格回退 / 粘贴分配」三件事，而其中一条是**硬坑**：
//
// > 🔴 **当前格为空时按退格，`onChanged` 根本不会触发** ——
// >    内容本来就是空，没有「变更」事件。
// >    ⇒ 用户连按退格想删掉已填的位，界面**毫无反应**（「静默失效」）。
// >    绕开它必须再挂一层 `KeyboardListener` / `Focus.onKeyEvent` 去嗅探
// >    `backspace` 键，并处理「同一个 `FocusNode` 被两个 widget 使用」之类的问题。
//
// ## 一个隐藏输入框为什么更好
//
// `TextField` **原生就会**正确处理退格与粘贴：
//   · 退格 ⇒ 内容由 `"482"` 变 `"48"` ⇒ **`onChanged` 正常触发**（坑不存在了）
//   · 粘贴 `"你的验证码是 482913，10 分钟内有效"` ⇒ `onChanged` 一次给出整段
//     ⇒ 交给 `cleanCodeInput` 清洗即可
//   · 超过 6 位 ⇒ `LengthLimitingTextInputFormatter` 原生截断
//
// 于是「6 格」只剩**渲染**问题：把 `controller.text` 的第 i 个字符画进第 i 个格子。
// ⇒ 纯逻辑缩到最小（`services/code_box_logic.dart`，本机可断言）。
//
// 📌 判据：**「N 个格子」是视觉要求，不是实现要求** —— 别把 UI 描述直译成
//    「N 个原生控件」。直译会换来一堆只有真机才测得出的边界 bug。
//
// # 视觉
//
// 每格复用 `ClayField` 同一档：`Clay(state: ClayState.pressed, fill: t.sunken)`
// ⇒ 与登录/注册弹窗的输入框**同一观感**（凹陷）。**不新造视觉**。
// 当前格加一圈朱砂描边（`accent`）—— 这是**唯一**的焦点提示
// （隐藏输入框不画光标：`showCursor: false`，否则会看到一条游标飘在格子上）。
//
// ⚠️ 本文件 import Flutter ⇒ **本机不可验证**（渲染），以 CI 的 `frontend` 为准。
//    其中可验的部分已抽到 `services/code_box_logic.dart`。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/code_box_logic.dart';
import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class CodeInput extends StatefulWidget {
  const CodeInput({
    super.key,
    required this.controller,
    this.enabled = true,
    this.hasError = false,
    this.autofocus = false,
    this.onCompleted,
  });

  /// 承载**完整验证码**（长度 0–6）。展示层按字符拆到 6 个格子里。
  final TextEditingController controller;

  final bool enabled;

  /// 错误态：6 格全部描红（由调用方在收到「验证码不正确」后置 `true`）。
  final bool hasError;

  final bool autofocus;

  /// 填满 6 位时回调。
  ///
  /// 🔑 调用方应在这里**自动提交**（设计稿 §三 屏②），
  ///    但**必须自己挡重复调用** —— 快速输入时 `onChanged` 可能连续触发。
  final VoidCallback? onCompleted;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  /// 单个格子的高度（宽 38 / 高 47）。
  ///
  /// 🔑 抽成常量是为了**让描边圆角与 `Clay` 内部算的圆角同值** ——
  ///    `Clay` 不传 `borderRadius` 时会走 `t.clay.radiusFor(size.height)` 的**尺寸阶梯**
  ///    （§3.5：阴影参数必须随尺寸缩放）。若我这里硬写一个 11，
  ///    描边就会与格子的真实圆角**差一点**（肉眼像「没对齐」）。
  /// 📌 判据：**别硬传 `borderRadius`**（同 `ClayField` 的注释）——
  ///    要用就用**同一个函数**算。
  static const double _boxHeight = 47;

  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 焦点变化要重绘 —— 当前格描边依赖「是否聚焦」。
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  /// 【补】上一次的完整码，用于判断「这次是否**刚刚**填满」。
  ///
  /// 🔑 `onChanged` 会在每一次输入都触发（包括删到 5 位再补回 6 位）。
  ///    只有「上一次 < 6 且这一次 == 6」才算**完成**，
  ///    否则用户在第 6 格反复改数字会被重复提交。
  String _lastText = '';

  void _onChanged(String value) {
    final wasComplete = isCodeComplete(_lastText);
    _lastText = value;
    setState(() {}); // 刷新 6 格显示 + 当前格描边
    if (!wasComplete && isCodeComplete(value)) {
      widget.onCompleted?.call();
    }
  }

  /// 当前应描边的那一格（= 已填位数；填满 6 位时无描边）。
  int? get _activeIndex {
    final n = widget.controller.text.length;
    if (n >= kCodeBoxCount) return null;
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final accent = Color(t.accent.argb32);
    final ink = Color(t.ink.argb32);
    final text = widget.controller.text;
    final active = _activeIndex;
    final focused = _focus.hasFocus;

    return Stack(
      alignment: Alignment.center,
      children: [
        // ── 视觉层：6 个格子 ──
        _Row(
          children: [
            for (var i = 0; i < kCodeBoxCount; i++)
              Padding(
                padding: EdgeInsets.only(right: i == kCodeBoxCount - 1 ? 0 : 7),
                child: _box(
                  char: i < text.length ? text[i] : '',
                  // 错误态全红优先于「当前格」——否则用户只看到一格红，以为只有那格错。
                  isActive: !widget.hasError && focused && active == i,
                  isError: widget.hasError,
                  accent: accent,
                  ink: ink,
                  t: t,
                ),
              ),
          ],
        ),
        // ── 输入层：一个**透明**的真实输入框，覆盖整个区域 ──
        //
        // 🔑 放在上层 ⇒ 点击任意位置都会聚焦它（不用给 6 个格子各挂 `onTap`）。
        //    `showCursor: false` + 透明文字 ⇒ 用户只看到 6 个格子，
        //    看不到游标与文字（否则会与格子里的数字**重叠成双影**）。
        Positioned.fill(
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            enabled: widget.enabled,
            autofocus: widget.autofocus,
            showCursor: false,
            // 数字键盘 + 只收数字 + 最多 6 位 —— **全部交给原生**，
            // 不比在 `onChanged` 里自己过滤（那会漏掉输入法批量上屏的情况）。
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(kCodeBoxCount),
            ],
            style: const TextStyle(color: Colors.transparent, fontSize: 1),
            // 关掉计数器（`maxLength` 会默认显示「3/6」，在弹层里很突兀）。
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              counterText: '',
              isDense: true,
            ),
            onChanged: _onChanged,
          ),
        ),
      ],
    );
  }

  /// 画单个格子（凹陷 + 当前格朱砂描边 / 错误态全描红）。
  Widget _box({
    required String char,
    required bool isActive,
    required bool isError,
    required Color accent,
    required Color ink,
    required CoEvoTokens t,
  }) {
    // 描边圆角与 `Clay` 内部**同一个函数**算出来（见 `_boxHeight` 注释）。
    final radius = BorderRadius.circular(t.clay.radiusFor(_boxHeight));

    return SizedBox(
      width: 38,
      height: _boxHeight,
      child: Clay(
        // ⚠️ **不传** `borderRadius` —— 让 `Clay` 按真实高度走尺寸阶梯。
        state: ClayState.pressed,
        fill: t.sunken,
        // 🔑 用 `foregroundDecoration` 画描边：它**不影响子布局**，
        //    也不改 `Clay` 自己的阴影参数（走 `Container.decoration` 会覆盖 inset 阴影）。
        child: Container(
          alignment: Alignment.center,
          foregroundDecoration: (isActive || isError)
              ? BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: accent, width: 2),
                )
              : null,
          child: Text(
            char,
            style: TextStyle(
              // 验证码是数字 ⇒ 用界面字体（Inter 的数字等宽、规整）。
              // ⚠️ `CoFonts` **没有 mono**（只有 latinSerif/ipaSerif/cjk/uiSans）——
              //    设计稿 CSS 里的 `--mono` 是**浏览器**概念，App 侧不对应字体。
              fontFamily: CoFonts.uiSans,
              fontSize: 20,
              color: ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// 只做横向布局、**不参与滚动**的 `Row` 别名 —— 让上面那段更易读。
class _Row extends StatelessWidget {
  const _Row({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      );
}
