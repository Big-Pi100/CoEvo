// 译文浮层 —— 划词菜单「翻译」的结果面板
//
// # 🔴 三条设计约束（设计稿 §2「正面处理『翻译会削弱阅读』」）
//
// | # | 约束 | 为什么 |
// |---|---|---|
// | ① | **按需触发**（没有"整篇一键翻译"）| 把「打开 → 全译 → 读完（其实读的是中文）」这条捷径**物理堵掉** |
// | ② | **译文不替换原文**（本文件是个底部浮层）| 关掉后正文**一个字都没变** ⇒ 翻译是**工具**，不是「另一份文本」 |
// | ③ | ⭐ **浮层里可直接「划线记住这段」** | 🔑 **把「看懂」转成「记住」** —— 让翻译从**终点**变回**中间站** |
//
// ③ 是本功能最重要的一处：它正是「制卡-FSRS」这个产品核心与翻译的**接缝** ——
//
//     看不懂 → 翻译 → 看懂 → 划线 → 记住
//
// 每一步都留在同一个产品里闭环。前两条只是"不让用户走捷径"（防守），
// ③ 才让功能产生一个**留在产品里**的结果（进攻）。
//
// # 🔑 为什么浮层**不认识**「划线」这个机制
//
// 它只暴露一个 `onRemember` 回调（可空）。调用方把它接到自己的入队逻辑上。
// 好处：① 浮层不需要 import 手势组件（也不依赖 `HighlightSource`）；
//       ② 将来「划线」以外的记忆方式（如书签）也能用同一个出口
//       —— 判据：**浮层负责展示与抛事件，不负责知道事件怎么实现**。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/translate_client.dart';
import '../providers/translate_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 弹出译文浮层。
///
/// [onRemember] 为 `null` ⇒ **不显示**「划线记住这段」
/// （⚠️ 拿不到正文来源时不要显示一个点了没反应的按钮）。
Future<void> showTranslationSheet(
  BuildContext context, {
  required String text,
  String? sourceLabel,
  ValueChanged<String?>? onRemember,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 与 `LookupSheet` **同一遮罩**（12% 黑）——
    // 默认 54% 会把正文压暗成「跳到了另一个界面」，而这一步的意图是**不打断阅读**。
    barrierColor: const Color(0x1F000000),
    builder: (_) => TranslationSheet(
      text: text,
      sourceLabel: sourceLabel,
      onRemember: onRemember,
    ),
  );
}

class TranslationSheet extends ConsumerStatefulWidget {
  const TranslationSheet({
    super.key,
    required this.text,
    this.sourceLabel,
    this.onRemember,
  });

  /// 选中的原文（≤800 字符，服务端会再校验一次）。
  ///
  /// 🔑 上限**只在服务端定义一处**（`translation::MAX_TEXT_CHARS`），端侧**不复制**这个数字做
  ///    前置校验 —— 否则改一处漏一处，而端侧那个会让「服务端已放宽、端侧还在拦」静默存在。
  ///    这里只写进注释供读者知道量级（2026-10-09 由 300 提到 800）。
  final String text;

  /// 顶栏那行来源（如 `Why We Read Slowly`）。`null` ⇒ 只显示「翻译」。
  final String? sourceLabel;

  /// ③ 的出口：把这段加进记忆队列（并**带上这段的译文**）。`null` ⇒ 不显示该按钮。
  ///
  /// ⚠️ 参数是 `String?` **不是**无参 —— 译文可空（浮层理论上只拿到空白段时），
  ///    由下游 `HighlightRepository.add` 统一归一化。
  final ValueChanged<String?>? onRemember;

  @override
  ConsumerState<TranslationSheet> createState() => _TranslationSheetState();
}

class _TranslationSheetState extends ConsumerState<TranslationSheet> {
  /// `null` = 还在加载。
  TranslateResult? _result;
  bool _fromCache = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _result = null;
      _fromCache = false;
    });
    final out = await translateWithCache(ref, widget.text);
    if (!mounted) return;
    setState(() {
      _result = out.result;
      _fromCache = out.fromCache;
    });
  }

  Future<void> _copyAll(List<TransSegment> segments) async {
    // 🔑 译文不是「选区」⇒ 用 `Clipboard`（不能用 `region.copySelection`）。
    //    多句时按行拼，让粘到别处仍可读。
    // 🔑 拼接口径**复用 `translationTextOf`** —— 与「划线记住这段」「批量补译」
    //    **同一处定义**。三处各写一份 ⇒ 同一段文字会存出/复制出**三种文本**
    //    （而**不报错**）。
    // ⚠️ 复制场景**不可为空** ⇒ `?? ''`：真全空时粘出去是空串，与「没东西可复制」等价。
    final text = translationTextOf(segments) ?? '';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('译文已复制'),
        duration: Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Container(
      decoration: BoxDecoration(
        color: Color(t.card.argb32),
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.clay.radius)),
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        18,
        22,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      // ⚠️ 多句 + 长句可能很高 ⇒ 限高并允许滚动（不限高会把浮层顶出屏幕）
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(t),
          const SizedBox(height: CoSpacing.md),
          Flexible(child: _body(t)),
        ],
      ),
    );
  }

  Widget _header(CoEvoTokens t) {
    final label = widget.sourceLabel;
    final suffix = _fromCache ? ' · 本机缓存' : '';
    return Text(
      label == null || label.trim().isEmpty ? '翻译$suffix' : '翻译 · 来自 $label$suffix',
      style: TextStyle(
        fontFamily: CoFonts.uiSans,
        fontSize: 11,
        letterSpacing: .5,
        color: Color(t.ink3.argb32),
      ),
    );
  }

  Widget _body(CoEvoTokens t) {
    final r = _result;
    if (r == null) return _loading(t);

    return switch (r) {
      // 🔑 用 `final T x` 绑定而不是 `T()`：后者不会把 `r` 收窄，
      //    传给 `_ready` 时静态类型仍是 `TranslateResult`（编译不过）。
      //    写成绑定后类型是确定的，**不靠流分析**（同族教训：Dart 对闭包捕获的变量不提升）。
      final TranslateReady ready => _ready(t, ready),
      TranslateNeedLogin() => _message(
          t,
          title: '登录后可翻译',
          detail: '翻译需要账号来记录额度（免费每月 10 次）。\n'
              '登录后即可使用；也可以先关掉，继续读。',
          // 🔑 未登录**不是失败** —— 按钮用「继续阅读」而不是「重试」
          //    （重试一个永远不会成功的动作只会让人更困惑）。
          //
          // 🔴 「去登录」放在**主要**位置：用户点「翻译」是**明确想用这个功能**，
          //    去登录才是他意图的延续；「继续阅读」是放弃这次翻译。
          //    但这**不是**强迫跳转（那会违反本功能 §2 的首要约束「不打断阅读」）——
          //    两个按钮**平级呈现**，且次要按钮是「关闭」而不是隐藏。
          actions: [
            // 数组顺序 = 视觉左右：**主操作靠右**（iOS 习惯：取消在左、确认在右；
            // 本 App 仅 iOS ⇒ 跟 iOS，不要跟 Android 的「主操作靠左」）。
            _Action(
              label: '继续阅读',
              primary: false,
              onTap: () => Navigator.of(context).pop(),
            ),
            _Action(
              label: '去登录',
              primary: true,
              onTap: () {
                // 🔴 **先取 router 再 pop** —— `pop()` 之后这个 `context`
                //    （浮层的 route）就开始失效，届时再 `GoRouter.of` 可能拿不到。
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.go('/mine');
              },
            ),
          ],
        ),
      TranslateQuotaExceeded(:final message) => _message(
          t,
          title: '本月额度已用完',
          detail: message,
          // ⚠️ 额度用尽是**订阅**的转化点，但**不在这里推销** ——
          //    用户此刻拿到的是「用不了」这一个信息，塞第三件事会稀释它。
          //    订阅入口在「我的」页（与其余权益同一处）。
          actions: [
            _Action(
              label: '知道了',
              primary: false,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      TranslateFailed(:final message) => _message(
          t,
          title: '翻译失败',
          detail: message,
          actions: [
            _Action(
              label: '重试',
              primary: true,
              onTap: _load,
            ),
          ],
        ),
    };
  }

  Widget _loading(CoEvoTokens t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(t.accentBright.argb32),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '正在翻译',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                color: Color(t.ink2.argb32),
              ),
            ),
          ],
        ),
      );

  /// ✅ 结果：逐句对照（英文在上、中文在下）。
  ///
  /// 🔑 单句与多句**走同一条渲染路径**（服务端保证 `segments` 永远非空）
  ///    ⇒ 没有「if 单句 else 多句」这个分支（能少一个分支就少一个）。
  Widget _ready(CoEvoTokens t, TranslateReady r) {
    final segments = r.segments;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in segments) ...[
                  Text(
                    s.src,
                    style: TextStyle(
                      fontFamily: CoFonts.latinSerif,
                      fontSize: 13.5,
                      height: 1.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    s.dst,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 17,
                      height: 1.6,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  const SizedBox(height: CoSpacing.md),
                ],
                if (_showQuotaLine(r)) _quotaLine(t, r),
              ],
            ),
          ),
        ),
        const SizedBox(height: CoSpacing.md),
        Row(
          children: [
            // ③ 把「看懂」转成「记住」—— 有来源时才有这个出口
            if (widget.onRemember != null)
              Expanded(
                child: _button(
                  t,
                  label: '划线记住这段',
                  primary: false,
                  onTap: () {
                    // 🔑 先把**这段的译文**取出来（浮层一关，`segments` 就够不着了），
                    //    再关浮层、再入队 —— 顺序不能反。
                    // 🔴 必须复用 `translationTextOf`（**口径只有那一处**）：
                    //    这里若自己 `.map((s) => s.dst).join()`，与「批量补译」会存出
                    //    **两种串**（比如多段之间用不用换行），而**不报错**。
                    final translation = translationTextOf(segments);
                    // 先关浮层再入队 —— 让用户立刻看到正文里出现下划线
                    Navigator.of(context).pop();
                    widget.onRemember!(translation);
                  },
                ),
              ),
            if (widget.onRemember != null) const SizedBox(width: CoSpacing.md),
            Expanded(
              child: _button(
                t,
                label: '复制译文',
                primary: true,
                onTap: () => _copyAll(segments),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 额度行只在**知道**的时候显示。
  ///
  /// 🔴 缓存命中时 `used == kTranslateUsedUnknown`（没调接口 ⇒ 服务端没回 quota）
  ///    ⇒ **不显示**。若显示成「本月已用 0 次」，那是**假信息**
  ///    （用户会以为额度被重置了）。
  bool _showQuotaLine(TranslateReady r) {
    if (r.used == kTranslateUsedUnknown) return false;
    if (r.subscribed) return false; // 订阅不限 ⇒ 不必提示
    return true;
  }

  Widget _quotaLine(CoEvoTokens t, TranslateReady r) {
    final limit = r.limit ?? 0;
    return Text(
      '本月已用 ${r.used} / $limit 次',
      style: TextStyle(
        fontFamily: CoFonts.uiSans,
        fontSize: 11.5,
        color: Color(t.ink3.argb32),
      ),
    );
  }

  /// 非结果态（未登录 / 额度用尽 / 失败）的通用版式。
  ///
  /// 🔑 用 `actions` 列表而不是一个 `retry: bool`：
  ///    未登录那一态需要**两个**出口（去登录 / 继续读），
  ///    而 `bool` 只能表达「一个按钮，文案二选一」——
  ///    硬塞会变成 `if (xxx) ... else ...` 的一堆特判。
  Widget _message(
    CoEvoTokens t, {
    required String title,
    required String detail,
    required List<_Action> actions,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Color(t.ink.argb32),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13.5,
            height: 1.7,
            color: Color(t.ink2.argb32),
          ),
        ),
        const SizedBox(height: CoSpacing.lg),
        Row(
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: CoSpacing.md),
              Expanded(
                child: _button(
                  t,
                  label: actions[i].label,
                  primary: actions[i].primary,
                  onTap: actions[i].onTap,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _button(
    CoEvoTokens t, {
    required String label,
    required bool primary,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(t.clay.radius * 0.5),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(t.clay.radius * 0.5),
          color: primary ? Color(t.accent.argb32) : Colors.transparent,
          border: primary
              ? null
              : Border.all(color: Color(t.line.argb32), width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            // 🔑 压字色用 `accentInk`（spec：实心填充用 `accent`，上面压 `accentInk`）——
            //    不是 `page`：浅色主题下两者接近，深色主题下 `page` 会**看不见**。
            color: primary ? Color(t.accentInk.argb32) : Color(t.ink.argb32),
          ),
        ),
      ),
    );
  }
}

/// 浮层底部的一个动作。
///
/// 🔑 提出来是为了让「非结果态」能表达**两个**出口（见 `_message` 的说明）。
class _Action {
  const _Action({
    required this.label,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;
}
