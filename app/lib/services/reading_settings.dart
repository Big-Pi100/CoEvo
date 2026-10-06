// CoEvo · 阅读器设置 —— **规则层**（零 import 纯逻辑 ⇒ 本机可完整断言）
//
// # 🔑 为什么单独一层（而不是写在 provider / 面板里）
//
// 字号区间与痕迹开关的**默认值**是**产品规则**，而读写 SharedPreferences 是 **IO**。
// 本项目既定做法：**把规则抽成零 import 的纯 Dart** ⇒
//   · `dart run` 能做完整类型检查（不必等 flutter）
//   · 断言脚本能在**本机**跑（`scripts/query_verify/bin/verify_reading_settings.dart`）
// 📌 先例：`reading_completion` / `speech_chunks` / `sync_merge` / `iap_plan`。
//
// # ⚠️ 本文件**不含** UI，也不含 provider
// UI 在 `widgets/reading_settings_panel.dart`，状态在 `providers/reading_settings_provider.dart`。

/// 正文字号**下限** —— spec §5.1「默认 18px，可调 **15–24px**」。
const int kReadingFontSizeMin = 15;

/// 正文字号**上限**。
const int kReadingFontSizeMax = 24;

/// 正文字号**默认值**。
///
/// # 🔴 为什么是 17，而不是 spec 写的 18
///
/// spec §5.1 写「默认 18px」，但**白哥 2026-09-27 显式定为 17**
/// （对齐 L1 界面锚点 `visual-word-card-target` §07），且代码里长期是 17。
///
/// 📌 口径：**「设计稿与 spec 冲突按 spec」** —— 但这条讲的是**设计稿**；
///    而**白哥的显式决定**优先级高于 spec 的默认值（就是 L0 > L2 那条）。
///    把 18 当真会**改掉用户已在用的观感**（属「撤回已定案」）。
const int kReadingFontSizeDefault = 17;

/// 把任意数值**钳到合法区间**（越界取最近边界；NaN → 默认值）。
///
/// # 🔑 为什么需要它（而不是直接信存储值）
///
/// 字号来自 SharedPreferences ⇒ **可能是任意历史值**：
///   · 旧版本写过 `18`（spec 默认）或别的数
///   · 手工改过偏好文件 / 数据损坏 ⇒ 可能 0 / -3 / 1e9
///   · `double` 参与运算后出现小数（`18.0` → `18` 要取整）
/// ⇒ 不钳的话：字号 0 ⇒ 正文**不可见**（且**不报错**，用户以为文章是空的）。
/// 📌 判据：**来自持久化的值必须当作「不可信输入」**（同「配置类 seed 要校验」一族）。
int clampReadingFontSize(num v) {
  if (v.isNaN) return kReadingFontSizeDefault;
  final i = v.round();
  if (i < kReadingFontSizeMin) return kReadingFontSizeMin;
  if (i > kReadingFontSizeMax) return kReadingFontSizeMax;
  return i;
}

/// 判断一个字号是否**已在边界**（供 UI 决定是否禁用 −/+ 键）。
bool isReadingFontSizeAtMin(num v) =>
    clampReadingFontSize(v) <= kReadingFontSizeMin;
bool isReadingFontSizeAtMax(num v) =>
    clampReadingFontSize(v) >= kReadingFontSizeMax;

/// SharedPreferences 的**键名** —— 收敛在一处。
///
/// # 🔴 为什么不就地写字符串
///
/// 本项目已踩过「同一字符串散在多处 ⇒ **改一处漏一处**」（10-06 那次是 SQL 片段）。
/// 键名写错的后果**特别隐蔽**：读回的是默认值 ⇒ 表现为「**设置不生效**」，
/// 而不是报错（写进去的是 A 键、读的是 B 键，两边都「成功」）。
/// 📌 判据：**凡是「写端与读端必须一致」的字符串，只能有一处定义**。
abstract final class ReadingPrefKeys {
  /// 正文字号（`int`）。
  static const String fontSize = 'reading_font_size';

  /// 痕迹开关（`bool`）—— spec §5.1：**默认开启**。
  static const String traceEnabled = 'reading_trace_enabled';
}

/// 痕迹开关的**默认值** —— spec §5.1 原文「开关在阅读设置面板内，**默认开启**」。
///
/// 🔑 为什么默认开：痕迹是**这个产品的核心识别**（「查过的词在文章里留底色」）——
///    默认关掉等于把特色功能藏起来，新用户永远不知道有它。
const bool kTraceEnabledDefault = true;
