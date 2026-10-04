// ════════════════════════════════════════════════════════════════════════
// 法律链接行 —— 订阅页 / 「关于」页**共用**
// ════════════════════════════════════════════════════════════════════════
//
// # 为什么抽成组件（而不是两处各写一份）
//
// 需求出现在**两个页面**：
//   · 订阅页（`subscribe_screen`）—— Apple 对订阅类 App 的**强制要求**
//   · 「关于」页（`about_screen`）—— ASC 要求 App 内要有入口
//
// 两处不只是「长得像」，而是**同一条规则**：
//   **URL 为空时显示「即将上线」，不为空时可点** ——
//   而「不放死链」是本项目已定的判据（点不动比不放进糟糕）。
//   ⇒ 这条规则写在两处就会**漂**（改了一处忘了另一处）。
//   📌 判据：**同一件事的口径只能一处权威**。
//
// # 🔴 「不放死链」为什么重要
//
// 用户点了一个没反应的入口，会以为 **App 坏了** —— 这比「明确说还没上线」更糟
// （同族教训：**「静默失败 + 无出口」比「报错」更糟**）。
// 所以 URL 未就绪时，右列显示「即将上线」文字，且**整行不可点**。

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 正文与右列说明的字号 —— 与「关于」页 / 订阅页保持一致（跨页同字号）。
const double _kLabelFontSize = 14;
const double _kHintFontSize = 12.5;

class LegalLinkRow extends StatelessWidget {
  const LegalLinkRow({super.key, required this.label, required this.url});

  final String label;

  /// 目标 URL。**为 null 表示尚未部署** ⇒ 显示「即将上线」且不可点。
  final String? url;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final target = url;

    final labelText = Text(
      label,
      style: TextStyle(
        fontFamily: CoFonts.uiSans,
        fontSize: _kLabelFontSize,
        color: Color(t.ink.argb32),
      ),
    );

    // ── 未就绪：不可点 + 明确说明（**不放死链**）──
    if (target == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            labelText,
            const Spacer(),
            Text(
              '即将上线',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: _kHintFontSize,
                color: Color(t.ink3.argb32),
              ),
            ),
          ],
        ),
      );
    }

    // ── 就绪：可点（强调色 + 箭头表达「能进去」）──
    return InkWell(
      onTap: () => _open(context, target),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            labelText,
            const Spacer(),
            Icon(Icons.chevron_right, size: 20, color: Color(t.accent.argb32)),
          ],
        ),
      ),
    );
  }

  /// 打开外部链接。
  ///
  /// 🔴 **失败必须让用户看见** —— 点了没反应正是本组件要避免的那种体验。
  /// ⚠️ 用 `context.mounted` 而不是 `State.mounted`：本组件是 `StatelessWidget`。
  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (ok || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接，请稍后重试')),
    );
  }
}
