/// 朗读**喇叭** —— **词卡场景**（单词 / 例句 / 搭配 / 浮层）的唯一一处定义。
///
/// # 🔴 与「阅读器顶栏朗读键」的分工（2026-10-06 补 · 别混用）
///
/// | | **本组件**（`SpeakButton`）| `_SpeakButton`（`screens/reader_screen.dart`）|
/// |---|---|---|
/// | 场景 | 词卡：**5 处**喇叭（词头/语境/搭配/浮层）| 阅读器顶栏：**整篇**文章 |
/// | 文本 | **短**（一个词 / 一句）| **长**（数千～数万字符）|
/// | 方法 | `togglePlay`（一次 `speak`）| `speakLong`（**分段 + 队列**）|
/// | 语义 | **再点即停**（切换）| **读完为止**（点第二次 = 停）|
/// | 形态 | 圆形**粘土** + 三态图标（转圈/`stop_rounded`/`volume_up_rounded`）| 顶栏**平面**图标（`play_circle_outline`/`stop_circle_outlined`）|
///
/// 🔴 **为什么不合并成一个**（这是有意的，不是漏了）：
/// · **文本量级不同** ⇒ 方法必须不同（长文用 `togglePlay` 会**超出平台单次上限而静默无声**）。
/// · **形态归属不同** ⇒ 词卡的喇叭是卡片内的圆形按钮（锚点 `.spk`）；
///   阅读器顶栏出现圆形粘土会**破坏 spec §八「阅读界面零粘土」**的边界
///   （那里唯一允许的粘土是书签）。
/// 📌 判据：**「复用同一组件」≠「同一套行为」** —— 为本页/本量级设计的参数
///    借给另一个场景，会同时错在「行为」和「视觉归属」两处。
///    ⇒ 两者**共享的是 `TtsService`**（真正的公共层），不是一个按钮组件。
///
/// # 依据（都是既有定案，不是新需求 · 2026-09-28 21:4x 接通）
/// | 来源 | 内容 |
/// |---|---|
/// | **v1 §6.2**（L0 原文） | `front`（单词）✅ · `context`（英文例句）✅ · `collocation`（英文搭配）✅ 朗读；`definition` / `root` / `etymology` / `cognate` ❌（**含中文**）<br>🔑 **原则：只朗读纯英文文本。** |
/// | **锚点 `.spk`** | `26×26` 圆形 + `background:var(--card)` + 凸起阴影 + `svg 12px` |
/// | **锚点 `.ctx .spk`** | `22×22` + `margin-left:6px` + `vertical-align:-8px`（跟在例句后） |
/// | **锚点 §07 浮层** | 单词行**右侧**一个喇叭（`margin-left:auto`） |
/// | **白哥 2026-09-28 21:4x** | ① 搭配**每条一个** ② 行为 = **播放/停止切换** |
///
/// > 📌 `ARCHIVE.md` §2.5 早就记着：「朗读入口**早有设计**（L1 每卡 **2 个**喇叭，
/// > 与 v1 §6.2 一致）→ 只需接通（Step 3）」—— 但实现只接了词头 **1 个**，
/// > 语境 / 搭配 / 浮层两处共 **4 处**都漏了。本组件是「接通」的那一步。
///
/// # 🔴 为什么抽成公共组件（而不是 5 处各写一个）
/// 一屏上现在最多**同时出现 5 个喇叭**：词头 · ④ 语境 · 搭配 3 条 · 浮层 2 个。
/// 🔑 **「外观 + 行为一致」最可靠的实现方式 = 只有一处定义** ——
///    尤其是「播放态」：5 处各写一份，改一处就会**静默走偏**
///    （用户看到「两个喇叭同时亮」，而这类不一致**编译器和断言都抓不到**）。
///
/// # 🔴 播放态必须按「**哪一段**」判断，不能只看全局 `isPlaying`
/// 若各按钮都用 `tts.isPlaying`（全局），点了 ④ 语境 → **词头与 3 条搭配的喇叭会一起亮**
/// —— 用户看不出到底在读哪段。故用 [TtsService.isSpeaking]（比对文本）。
///
/// # ⚠️ 三态图标
/// | 状态 | 图标 | 读作 |
/// |---|---|---|
/// | 本段 `loading` | 转圈（`CircularProgressIndicator`） | 「在准备」 |
/// | 本段 `playing` | `stop_rounded` | 「**再点即停**」（白哥定的切换行为） |
/// | 其它 | `volume_up_rounded` | 「点我朗读」 |
///
/// # ⚠️ 设置里关了朗读 → **不渲染**（而不是渲染一个点了没反应的）
/// 判据：「**静默失败 + 无出口」比「报错」更糟** —— 本项目已定。
/// 关了朗读还留个喇叭，用户点了没反应，会以为「坏了」。
///
/// # ⚠️ 圆角必须**显式**给 `size / 2`
/// 锚点是 `border-radius:50%`（正圆），而各档 `clay.radius` 不同
/// （墨 26 / 格 14 / 夜 24）→ 走 token 档位会在「格」档得到 14px ≠ 正圆。
/// 同 `BookmarkButton`（10）与 `_ClayTabBar`（17）的处理方式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/tts_service.dart';
import '../theme/clay.dart';
import '../theme/tokens_ext.dart';

/// 两个尺寸档（**都是锚点给定的值**，不是自定）。
abstract final class SpeakSize {
  /// 词头 / 浮层单词行 —— 锚点 `.spk{width:26px;height:26px}`。
  static const double main = 26;

  /// 语境原句 / 浮层例句 / 搭配 —— 锚点 `.ctx .spk{width:22px;height:22px}`。
  static const double inline = 22;

  /// inline 场景的**前间距** —— 锚点 `.ctx .spk{margin-left:6px}`。
  ///
  /// ⚠️ 不取 `CoSpacing.sm`（8）：锚点写死 6，且这个值只影响「喇叭离文字多远」，
  ///    走档位会在三档之间变（而它不该随主题变）。同 `.bm-entry` 的 `radius:13`。
  static const double inlineGap = 6;
}

class SpeakButton extends ConsumerWidget {
  const SpeakButton({
    super.key,
    required this.text,
    this.size = SpeakSize.main,
    this.gapBefore = 0,
  });

  /// 要朗读的文本。**调用方保证是纯英文**（v1 §6.2：中文段不给喇叭）。
  final String text;

  /// [SpeakSize.main]（26）或 [SpeakSize.inline]（22）。
  final double size;

  /// 左侧留白 —— inline 场景传 [SpeakSize.inlineGap]（6）。
  ///
  /// 🔑 用「组件自带间距」而不是靠调用方在外面垫 `SizedBox`：
  ///    居中/换行时外层 `SizedBox` 会变成一个可断行点，喇叭可能与文字**分局两行**。
  final double gapBefore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 🔴 关朗读 → 不渲染（见类文档：静默失败比报错更糟）
    if (!ref.watch(ttsEnabledProvider)) return const SizedBox.shrink();
    // 空文本不渲染（「朗读空串」是无意义交互）
    final t9 = text.trim();
    if (t9.isEmpty) return const SizedBox.shrink();

    final t = CoEvoTokensExt.of(context);
    final tts = ref.watch(ttsServiceProvider);
    final mine = tts.isSpeaking(text);
    final loading = mine && tts.state == TtsState.loading;
    final playing = mine && tts.state == TtsState.playing;

    final button = Clay(
      state: ClayState.raised,
      // ⚠️ 显式给 `card`：锚点 `background:var(--card)`。
      //    （`Clay` 默认填充正好是 `clayFill` → `card`，但显式写出来
      //      才不会在将来改 `clayFill` 时被静默改掉。）
      fill: t.card,
      // 🔴 显式正圆（见类文档：各档 `clay.radius` 不同）
      borderRadius: BorderRadius.circular(size / 2),
      // ⚠️ `loading` 时**不给 onTap** → `Clay` 内部 `_interactive=false`，
      //    不会重复触发（转圈本身就是「已在处理」的反馈）。
      //    ⚠️ 不要用 `ClayState.disabled` —— 那会加 `Opacity(0.5)`，
      //       而「正在准备」不是「不可用」，变淡反而像坏了。
      onTap: loading ? null : () => tts.togglePlay(text),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: loading
              ? SizedBox(
                  // 转圈占圆的 ~42%，视觉上与图标等重
                  width: size * 0.42,
                  height: size * 0.42,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(t.accent.argb32),
                  ),
                )
              : Icon(
                  // 🔴 播放中显示「停止」—— 因为**再点就是停**（白哥定的切换行为）。
                  //    若显示成「正在播」的静态喇叭，用户不知道还能点它。
                  playing ? Icons.stop_rounded : Icons.volume_up_rounded,
                  // 图标 = 半径（26→13 与既有实现一致；22→11）。
                  // 🔑 锚点 `.spk svg{width:12px}` 是 26 圆的值 → 13 与之基本一致
                  //    （也正好是 Material 图标按钮的标准比例）。
                  size: size / 2,
                  color: Color(t.accent.argb32),
                ),
        ),
      ),
    );

    if (gapBefore <= 0) return button;
    return Padding(
      padding: EdgeInsets.only(left: gapBefore),
      child: button,
    );
  }
}
