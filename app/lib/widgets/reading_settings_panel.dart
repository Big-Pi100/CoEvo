import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/reading_settings_provider.dart';
import '../providers/theme_provider.dart';
import '../services/reading_settings.dart';
import '../services/tts_service.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 朗读试听用的英文句子。
///
/// 🔑 从 `profile_screen` 搬来（2026-10-06 搬卡）—— 原为那边的 `_nativePreviewText`。
///    搬过来而不是两边各留一份：**同一句话两处定义**会漂（本项目既有判据）。
const String _kPreviewText = 'Hello. This is a sample sentence.';

/// 阅读设置面板（spec §5.1「**单击屏幕中央唤出底部面板**」· Kindle 模式）。
///
/// # 🔑 它解决的不是「少一个面板」，而是**三处阻塞**（2026-10-06 清查）
///
/// | 被阻塞的 | 为什么 |
/// |---|---|
/// | **痕迹开关** | spec §5.1 第 86 行：「界面上**不放**痕迹开关（遵守「阅读界面保持单纯」）——**开关在阅读设置面板内**，默认开启」⇒ 面板不存在 ⇒ **该开关没有任何入口**（连状态都没有）|
/// | **「单击屏幕中央」这个手势** | spec §5.1 把它留给「唤出阅读设置面板」⇒ 面板不存在 ⇒ **手势无目的**。🔑 这也正是当初划词选**长按**而非单击的原因（一个手势不能有两种含义）|
/// | **「我的」页有项设置搬不走** | `profile_screen.dart:963` 注释：「『搬去阅读面板』的前提是**面板先存在** —— 而它尚未实现」|
///
/// # ⚠️ 面板内的项 —— **4 项，不是 spec 列的 5 项**（取舍要写清）
///
/// spec §5.1 第 847 行列的是「字号 / 行高 / 主题 / 痕迹开关 / 发音语速音色」。
/// 本实现给 **字号 · 主题 · 痕迹开关 · 语速 · 音色**，**行高不放**，理由：
///
/// 🔴 spec **自己内部冲突**：第 839 行写「行高**随主题**：1.82 / 1.74 / 1.84」，
///    第 847 行又把「行高」列进面板。两者不能同时成立 ——
///    若面板可调行高，那它就不再「随主题」（切主题时该不该覆盖用户设定？无规格）。
/// ⇒ 按既定判据「**不替设计做决定**」实现无争议项，行高维持「随主题」。
/// ✅ **白哥 2026-10-06 已确认**：「行高不放阅读面板」（与上述取舍一致）。
///
/// # 🆕 「朗读设置」卡已从「我的」页**搬进本面板**（白哥 2026-10-06 定）
///
/// 搬的是 **语速 + 音色 + 试听**（原 `profile_screen._buildSpeechCard`）。
/// ⚠️ **如实标注一处代价**：那张卡原本也在服务**词卡朗读**场景
///    （词卡上的 5 个喇叭共用同一个 `tts.speechRate` / `selectedVoice`）。
///    搬进阅读面板后，**词卡场景下用户要调音色需先进入文章** ——
///    这是白哥权衡后的决定（阅读场景是调朗读参数的主场景）。
///    📌 若日后真机反馈「词卡里想调音色」，正解是在词卡页也放一个入口，
///      而**不是**把卡搬回去（状态仍只有一份，只是多一个入口）。
///
/// # ⚠️ 「主题」这一项是**复用**而非新状态
/// 它读写的是全局 `themeProvider`（与「我的」页的三档切换**同一个状态**）——
/// 不新增第二份主题状态（否则两处会各说各话）。
/// 同理「语速 / 音色」读写的也是全局 `ttsServiceProvider`（**同一个值**）。
class ReadingSettingsPanel extends ConsumerWidget {
  const ReadingSettingsPanel({
    super.key,
    this.showTrace = true,
    this.onOpenChapters,
    this.onClose,
  });

  /// 是否显示「痕迹」开关。
  ///
  /// 🔑 **书库页要传 `false`** —— 书库**有意不记痕迹**
  ///    （`WordLookupSelection(articleId: null)`：书的 id 是 String uuid，
  ///     而痕迹键是 int，硬塞会污染数据）。
  /// ⇒ 在书库显示这个开关，用户拨了**什么都不会发生**
  ///   ⇒ 正是本项目大忌「**静默失败 + 无出口**」。
  ///
  /// 📌 判据：**共享面板要给「该场景不适用的项」留关闭口** ——
  ///    否则两个页面会被迫要么共用一套不适用的项、要么各写一份面板。
  /// ⚠️ 默认 `true`：既有调用方（阅读器）行为不变。
  final bool showTrace;

  /// 🆕 2026-10-24：点「目录」行要做什么。`null` ⇒ **那一行不渲染**。
  final VoidCallback? onOpenChapters;

  /// 🆕 2026-10-24：**关闭面板的方式**。
  ///
  /// `null` ⇒ 默认 `Navigator.pop()`（面板是以 `showModalBottomSheet` 弹的，
  /// 弹掉一条路由正好）。
  /// 传了 ⇒ 用调用方给的方式 —— **翻页阅读器把本面板直接嵌在 `Stack` 里**
  /// （不是路由），`pop` 会把整个阅读页弹掉，必须换成「改一个状态位」。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);
    final rs = ref.watch(readingSettingsProvider);
    final themeSettings = ref.watch(themeProvider);
    final tts = ref.watch(ttsServiceProvider);
    final voices = tts.availableVoices;

    return Container(
      decoration: BoxDecoration(
        color: Color(t.card.argb32),
        // 只圆上面两角（bottom sheet 惯例，与 `lookup_sheet` 一致）
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(t.clay.radius)),
      ),
      // 🔴 2026-10-07 白哥定：**面板最多占屏幕 2/3**。
      //
      // 为什么这个高度是关键（不是随手定的）：
      //   `showModalBottomSheet` 的下拉关闭判定是
      //   「**拖拽距离 > 面板高度的 50%**」（`_closeProgressThreshold = 0.5`）。
      //   面板越高 ⇒ 需要拖的距离越长 ⇒ 近全屏时**物理上够不着** ⇒
      //   体感就是「下拉关不掉」（白哥两轮反馈都提到了这点）。
      //   限到 2/3 屏后，**只需往下拖 1/3 屏**，是自然手势就能完成的量。
      //   📌 判据：**手势的阈值若依赖元素自身尺寸，就要让那个尺寸落进
      //      手势可达的范围** —— 光加视觉提示（把手）解决不了「够不着」。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 2 / 3,
      ),
      // 底部避让 Home Indicator（同 `lookup_sheet`）
      padding: EdgeInsets.fromLTRB(
        22,
        18,
        22,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      // ⚠️ 小屏（如 iPhone SE）上内容仍可能超出 2/3 屏 ⇒ 用可滚动兜住，避免溢出黄条。
      //    关键：内容**没超出时它不滚动**，因此不会与 sheet 抢下拉手势 ——
      //    滚动视图只在「真的能滚」时才参与手势竞争。
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 🔴 2026-10-07 真机修复（白哥反馈 #7）：可见的**下拉把手**。
          //
          // 白哥的原话是「应该要能**下拉**关闭」—— 面板靠下拉手势关闭，
          // 但此前**没有任何视觉提示**说明「这里能拖」。
          // 本把手做两件事：
          //   ① 告诉用户「可以拖」
          //   ② 给手势一个**明确的落点** —— 手势若落在 `Slider` / 下拉框上
          //      会先被它们接管，而把手区域没有竞争。
          //
          // ⚠️ 必须用 `Center` 单独包：外层 `Column` 是 `crossAxisAlignment: start`
          //    （那是给下面各分区左对齐用的，**别动**），
          //    直接把它放进 children 会**靠左**而不是居中。
          // 把手居左？不 —— **把手居中 + 关闭按钮靠右**（同一行）。
          //
          // 🔴 2026-10-07 真机修复（白哥反馈 #7，**第二次**）：
          //    白哥反馈「下拉依旧不能关」。复盘后找到更可能的原因：
          //    `showModalBottomSheet` 的下拉关闭判定是
          //    「**拖拽距离超过面板高度的一半**」（`_closeProgressThreshold = 0.5`）——
          //    而本面板有 5 个区块（字号/主题/痕迹/语速/音色），高度**接近全屏**
          //    ⇒ 要拖过半屏才关 ⇒ 用户拖不到 ⇒ 体感「拖不动/关不掉」。
          //
          // ⇒ 与其继续赌手势，不如**给一个必然可用的出口**：
          //    右上角显式关闭按钮。下拉同时保留（拖得够远仍能关）。
          // 📌 判据：**当「手势类交互」的判定条件对当前布局不友好时，
          //    补一个确定性的等价入口** —— 不要让用户猜怎么退出。
          SizedBox(
            width: double.infinity,
            height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Color(t.ink3.argb32).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Positioned(
                  right: -6,
                  child: InkWell(
                    onTap: onClose ?? () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: Color(t.ink3.argb32),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '阅读设置',
            style: TextStyle(
              fontFamily: CoFonts.cjk,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.xl),

          // ── ① 字号 ──
          _Row(
            tokens: t,
            label: '字号',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StepButton(
                  tokens: t,
                  icon: Icons.text_decrease,
                  // 到下限**禁用**（不是「点了不变」—— 那会让人以为卡了）
                  enabled: !isReadingFontSizeAtMin(rs.fontSize),
                  onTap: () => ref
                      .read(readingSettingsProvider.notifier)
                      .stepFontSize(-1),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    '${rs.fontSize}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                ),
                _StepButton(
                  tokens: t,
                  icon: Icons.text_increase,
                  enabled: !isReadingFontSizeAtMax(rs.fontSize),
                  onTap: () => ref
                      .read(readingSettingsProvider.notifier)
                      .stepFontSize(1),
                ),
              ],
            ),
          ),
          const SizedBox(height: CoSpacing.lg),

          // ── ② 底色（三档 · 复用全局 theme）──
          _Row(
            tokens: t,
            label: '底色',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final rt in ReadingTheme.values) ...[
                  _ThemeChip(
                    tokens: t,
                    label: _labelOf(rt),
                    selected: themeSettings.theme == rt,
                    onTap: () => ref.read(themeProvider.notifier).setTheme(rt),
                  ),
                  if (rt != ReadingTheme.values.last)
                    const SizedBox(width: CoSpacing.sm),
                ],
              ],
            ),
          ),
          const SizedBox(height: CoSpacing.lg),

          // ── ③ 痕迹开关（spec §5.1：面板内、默认开）──
          //
          // ⚠️ 书库页**不显示**它（见 [showTrace]）—— 书库不记痕迹，
          //    拨了没反应 = 静默失败。
          if (showTrace) ...[
            _Row(
              tokens: t,
              label: '痕迹',
              // ⚠️ **不传任何颜色参数** —— 主题层已有 `SwitchThemeData`
              //    （`theme_builder.dart:271`）。在控件里再写一份颜色 =
              //    「同一件事两处口径」，将来改主题色会**只改一处**。
              //    先例：`profile_screen.dart:1190` 的「跟随系统」开关也是裸 `Switch`。
              child: Switch(
                value: rs.traceEnabled,
                onChanged: (v) => ref
                    .read(readingSettingsProvider.notifier)
                    .setTraceEnabled(v),
              ),
            ),
            const SizedBox(height: CoSpacing.lg),
          ],

          // ── ④ 语速（复用全局 TTS 设置，不新增第二份）──
          //
          // 🔑 为什么语速放在这里而不是「我的」页：spec §5.1 明写它在阅读面板内。
          //    且它读写的仍是 `ttsServiceProvider` 的**同一个值** ⇒
          //    设置页（若将来有）与这里永远一致。
          Text(
            '朗读语速',
            style: TextStyle(
              fontFamily: CoFonts.cjk,
              fontSize: 13,
              color: Color(t.ink2.argb32),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: tts.speechRate,
                  min: kSpeechRateMin,
                  max: kSpeechRateMax,
                  // 🔴 与 `profile_screen` 的语速 Slider **同一表达式**（步长 0.1）
                  //    —— 两处入口必须同口径，否则「同一个值、两种粒度」。
                  //    ⚠️ 也不传 `activeColor`（理由同上面的 Switch：主题层管）。
                  divisions: ((kSpeechRateMax - kSpeechRateMin) / 0.1).round(),
                  label: tts.speechRate.toStringAsFixed(1),
                  onChanged: (v) {
                    // ⚠️ setter 自己会 `clampSpeechRate` ⇒ 这里不必再钳（一处权威）
                    ref.read(ttsServiceProvider).speechRate = v;
                  },
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${tts.speechRate.toStringAsFixed(1)}×',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12,
                    color: Color(t.ink2.argb32),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CoSpacing.lg),

          // ── ⑤ 音色（🆕 2026-10-06 从「我的」页「朗读设置」卡搬来）──
          //
          // 🔑 搬的是**整卡**（语速 + 音色 + 试听），按白哥 2026-10-06 的决定。
          //    ⚠️ 代价如实写在类文档里：那张卡原本也服务**词卡朗读**场景，
          //      搬走后词卡里要调音色需先进入文章。
          _Row(
            tokens: t,
            label: '音色',
            child: TextButton.icon(
              icon: const Icon(Icons.play_arrow, size: 16),
              label: Text(
                '试听',
                style: TextStyle(fontFamily: CoFonts.cjk, fontSize: 12),
              ),
              // 🔑 试听用**固定英文句**（本产品朗读英文）——
              //    不能拿正文试听：正文可能几千字，一点就念几分钟。
              onPressed: () => ref.read(ttsServiceProvider).speak(
                    _kPreviewText,
                    language: 'en-US',
                  ),
            ),
          ),
          const SizedBox(height: CoSpacing.sm),
          DropdownButtonFormField<String>(
            value: tts.selectedVoice?['name'] as String?,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: CoSpacing.md,
                vertical: 10,
              ),
              border: OutlineInputBorder(),
            ),
            // 🔴 提示语不能写「系统默认 (zh-CN)」—— 语义错误：
            //    本产品朗读英文，未指定音色时 `_pickBestVoice` 会按
            //    **文本语言**自动匹配（英文 → en-US）。搬迁时**原样保留**该修正。
            hint: Text(
              '系统默认（自动匹配语言）',
              style: TextStyle(fontFamily: CoFonts.cjk),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  '系统默认（自动匹配语言）',
                  style: TextStyle(fontFamily: CoFonts.cjk),
                ),
              ),
              if (voices.isNotEmpty)
                ...voices.map<DropdownMenuItem<String>>((v) {
                  final name = '${v['name'] ?? ''}';
                  final locale = '${v['locale'] ?? ''}';
                  return DropdownMenuItem(
                    value: name,
                    child: Text(
                      '$name ($locale)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: CoFonts.uiSans),
                    ),
                  );
                }),
            ],
            onChanged: (voiceName) {
              final ttsr = ref.read(ttsServiceProvider);
              if (voiceName == null || voiceName.isEmpty) {
                ttsr.selectVoice(null);
                return;
              }
              final match = voices
                  .cast<Map<String, dynamic>?>()
                  .firstWhere((v) => v?['name'] == voiceName,
                      orElse: () => null);
              if (match != null) {
                ttsr.selectVoice(match);
                // 切换音色后自动试听（英文），方便立即对比
                ttsr.speak(_kPreviewText, language: 'en-US');
              }
            },
          ),
          // 🆕 2026-10-24 白哥定：**目录入口放在这个面板里**（顶栏不加键、页码条不兼作按钮）。
          //
          // 🔑 `onOpenChapters == null` ⇒ **整行不渲染** ——
          //    滚动阅读器（热点页）没有「章」，不该出现一个点了没反应的入口。
          if (onOpenChapters != null) ...[
            const SizedBox(height: CoSpacing.sm),
            const Divider(height: 1),
            InkWell(
              onTap: () {
                // 🔑 先关面板，再执行动作 —— 否则两个 bottom sheet 叠在一起，
                //    用户关掉目录后看到的还是设置面板（「怎么又回来了」）。
                // 关面板：嵌在 Stack 里时用 onClose，弹在路由里时用 pop
                if (onClose != null) {
                  onClose!();
                } else {
                  Navigator.of(context).pop();
                }
                onOpenChapters!();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: CoSpacing.md, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '目录',
                        style: TextStyle(
                          fontFamily: CoFonts.cjk,
                          fontSize: 14,
                          color: Color(t.ink.argb32),
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: Color(t.ink3.argb32)),
                  ],
                ),
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }
}

/// 三档 `ReadingTheme` → 中文名。
///
/// 🔑 **不在这里重写「墨/格/夜」** —— 它们已经是 `CoEvoTokens.label`
///    （`inkTokens` / `gridTokens` / `nightTokens`）。
///    重写一份 = 两处口径（将来改档位名会漂移）。
String _labelOf(ReadingTheme rt) => switch (rt) {
      ReadingTheme.ink => inkTokens.label,
      ReadingTheme.grid => gridTokens.label,
      ReadingTheme.night => nightTokens.label,
    };

/// 一行设置：左标签 + 右控件。
class _Row extends StatelessWidget {
  const _Row({required this.tokens, required this.label, required this.child});

  final CoEvoTokens tokens;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 13.5,
            color: Color(tokens.ink.argb32),
          ),
        ),
        child,
      ],
    );
  }
}

/// 字号 −/+ 键。
///
/// ⚠️ 到边界时**整键降透明度且不可点**（与 `BookmarkButton` 的禁用表达同一手法）——
///    比「点了没反应」诚实。
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tokens,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final CoEvoTokens tokens;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 20,
            color: Color(tokens.ink2.argb32),
          ),
        ),
      ),
    );
  }
}

/// 主题档位 chip。
class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.tokens,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final CoEvoTokens tokens;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          // 选中 = 强调色实心（与主题切换的既有表达一致）
          color: selected ? Color(tokens.accent.argb32) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Color(tokens.accent.argb32)
                : Color(tokens.line.argb32),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: CoFonts.cjk,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? Color(tokens.accentInk.argb32)
                : Color(tokens.ink2.argb32),
          ),
        ),
      ),
    );
  }
}

/// 弹出面板（唯一调用入口 —— 调用方只写一行）。
///
/// [showTrace] 见 [ReadingSettingsPanel.showTrace]（书库页传 `false`）。
Future<void> showReadingSettingsPanel(
  BuildContext context, {
  bool showTrace = true,
  /// 🆕 2026-10-24：面板底部多一行「目录 ›」。
  ///
  /// **只有翻页阅读器会传它**（滚动阅读器没有「章」的概念，不需要目录）。
  /// 不传 ⇒ 那一行**根本不渲染**（而不是渲染成不可点）——
  /// 拿不到动作就别给入口，这是本项目既有判据。
  VoidCallback? onOpenChapters,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 与 `lookup_sheet` 同一遮罩（半透明浅黑，不抢内容）
    barrierColor: const Color(0x1F000000),
    // 🔴 2026-10-07 真机修复（白哥反馈 #7）：**显式**声明可下拉关闭 + 点遮罩关闭。
    //
    // 白哥的原话：「不是点哪里没反应，而是**应该要能下拉关闭**」。
    // ⚠️ 这两个参数本就是 Flutter 的默认值 —— **显式写出来**是为了让下面那个
    //    自绘把手有明确对应的行为（后人删把手时能立刻看到它靠什么生效）。
    // 📌 用自绘把手而不是 `showDragHandle: true`：本面板背景是
    //    `Colors.transparent`（外层 `Container` 自己画圆角与底色），
    //    而官方把手依赖 sheet 自身背景色 ⇒ 透明时观感不可控。
    enableDrag: true,
    isDismissible: true,
    builder: (_) => ReadingSettingsPanel(
      showTrace: showTrace,
      onOpenChapters: onOpenChapters,
    ),
  );
}
