// CoEvo · 记忆（默写判定）设置 —— **规则层**（零 import 纯逻辑 ⇒ 本机可完整断言）
//
// # 🔑 为什么单独一层（同 `reading_settings.dart` 的取向）
//
// 「阈值区间 / 默认值 / 由阈值推出最多能错几个词」是**产品规则**，
// 而读写 SharedPreferences 是 **IO**。本项目既定做法：**规则抽成零 import 纯 Dart**
// ⇒ `dart run` 能做完整类型检查 + 断言脚本能在本机跑。
//
// # 🔴 这个设置**只管划线卡的默写**，绝不碰单词卡
//
// 单词卡的答案是**唯一**的（`scale` 就是 `scale`）——「多准算对」在它上面
// **没有意义**：拼错一个字母就是拼错了。
// 只有划线卡的默写才有「**精确 vs 大意**」的灰度 ⇒ **只有这种地方才需要用户定标准**。
//
// ⚠️ 这条不只是注释：**它是 UI 文案与验收的一部分** ——
//    设置项必须写明作用范围（「只影响划线记忆的默写 · 单词卡的拼写判定不受影响」），
//    否则用户会以为它把所有判定都放宽了。
//
// 依据：白哥 2026-10-07「**让记忆准确率可调吧，在我的页面弄个设置的滑动条**」。

/// 阈值**下限**（0% = 逐字全对，最严）。
const int kMemoryMaxWrongPercentMin = 0;

/// 阈值**上限**（30% = 很宽）。
///
/// 🔑 有上限是**刻意的**：再宽就失去「记忆」的意义了
/// （错一半也算记住 ⇒ 队列会失真，等于把 FSRS 的信号弄脏）。
const int kMemoryMaxWrongPercentMax = 30;

/// 默认阈值 **5%**（白哥 2026-10-07 定）。
///
/// ⚠️ 它**很严**：等价于「**≤ 19 个词的句子一个都不能错**」
/// （见 [maxWrongWordsFor]）。容错只对「长段」生效 ——
/// 这正是「和单词一样」那条要求的兑现（短语/短句与单词卡同一严格度）。
const int kMemoryMaxWrongPercentDefault = 5;

/// 滑动条的**刻度**（供 UI 画 tick）—— 只是显示方便，不是合法值白名单。
const List<int> kMemoryMaxWrongPercentTicks = [0, 5, 15, 30];

/// 🔑 推荐值（在轨道上做个小标记）—— 拖远了知道该回哪。
const int kMemoryMaxWrongPercentRecommended = kMemoryMaxWrongPercentDefault;

/// 把任意数值**钳到合法区间**（越界取最近边界；NaN → 默认值）。
///
/// # 🔑 为什么必须钳（同 `clampReadingFontSize` 的理由）
/// 阈值来自 SharedPreferences ⇒ **可能是任意历史值**：旧版本写过别的数、
/// 手工改过偏好文件、数据损坏。
/// ▶ 不钳的后果是**静默的**：阈值 0 ⇒ 一切判「忘记」⇒ **复习队列卡死**
///   （用户看到的现象是「怎么复习都不通过」，而不会看到任何报错）。
/// 📌 判据：**来自持久化的值必须当作「不可信输入」**。
int clampMemoryMaxWrongPercent(num v) {
  if (v.isNaN) return kMemoryMaxWrongPercentDefault;
  final i = v.round();
  if (i < kMemoryMaxWrongPercentMin) return kMemoryMaxWrongPercentMin;
  if (i > kMemoryMaxWrongPercentMax) return kMemoryMaxWrongPercentMax;
  return i;
}

/// 给定「标准答案有多少词」与阈值 ⇒ **最多允许错几个词**。
///
/// # 🔴 必须与判定层**同一口径**
///
/// 判定层（`highlight_grader.dart` 的 `gradeCloze`）用的是**整数比较**：
/// ```dart
/// correct = wrongWords * 100 <= expectedWords * maxWrongPercent
/// ```
/// ⇒ 「最多能错几个」就是满足该不等式的最大的 `wrongWords`，即
/// `expectedWords * percent ~/ 100`（整除）。
///
/// ⚠️ **用整除而不是浮点**：对非负整数，`n * p ~/ 100` 与
///    `floor(n * p / 100)` **在数学上等价** —— 选整除不是因为它「更准」，
///    而是因为 ① 它**逐字对应判定层的写法**（读者一眼能看出是解同一个不等式），
///    ② 它**不引入浮点**（`n` 或 `p` 变大时不必操心精度）。
///    📌 判据：**同一件事的口径只能一处权威** —— 这里只是把那条不等式**解出来**
///    给用户看，不是重新定义它。断言脚本会**逐点核对**两者一致。
int maxWrongWordsFor({required int expectedWords, required int percent}) {
  if (expectedWords <= 0) return 0;
  final pct = clampMemoryMaxWrongPercent(percent);
  return (expectedWords * pct) ~/ 100;
}

/// SharedPreferences 的**键名** —— 收敛在一处（同 [ReadingPrefKeys] 的理由：
/// 键名写错 ⇒ 读回默认值 ⇒ 表现为「**设置不生效**」而不是报错）。
abstract final class MemoryPrefKeys {
  /// 默写判定的容错阈值（`int`，百分数 0–30）。
  static const String maxWrongPercent = 'memory_max_wrong_percent';
}
