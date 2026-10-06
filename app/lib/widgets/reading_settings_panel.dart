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
  const ReadingSettingsPanel({super.key, this.showTrace = true});

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
      // 底部避让 Home Indicator（同 `lookup_sheet`）
      padding: EdgeInsets.fromLTRB(
        22,
        18,
        22,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
        ],
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
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 与 `lookup_sheet` 同一遮罩（半透明浅黑，不抢内容）
    barrierColor: const Color(0x1F000000),
    builder: (_) => ReadingSettingsPanel(showTrace: showTrace),
  );
}
