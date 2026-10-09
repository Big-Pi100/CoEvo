/// 端侧翻译的**纯契约**（零 Flutter / 零平台依赖）。
///
/// # 为什么单独一个文件
/// 同 `translate_parse.dart` 的理由：**能脱离外部依赖验证的逻辑，就别让它依赖**。
/// 分句规则（[splitSentences]）是这个功能里最容易出错、又最难在真机上复现的一块
/// —— 抽成纯函数后，它能用**一行字符串**覆盖全部边界（见 `verify_translation_service.dart`）。
///
/// 平台通道在 `api/ondevice_translate_client.dart`（它 import Flutter）。
library;

/// 目标语言（BCP-47）。
///
/// 🔴 中文必须写 **`zh-Hans`**，不能写 `zh` ——
///    Apple 的 `LanguageAvailability` 只认 `zh-Hans` / `zh-Hant`，
///    写 `zh` 会被判成 `unsupported`（这类错**不报错、只是永远走不到端侧**）。
const String kOnDeviceTargetLang = 'zh-Hans';

/// 源语言。
const String kOnDeviceSourceLang = 'en';

/// 端侧翻译的可用性（对应 Swift 侧 `LanguageAvailability.status`）。
enum OnDeviceTranslateStatus {
  /// ✅ 语言包已就位 ⇒ **离线也能翻**。
  installed,

  /// 🟡 系统支持这一对语言，但**语言包还没下载**。
  ///
  /// ⚠️ 它**不是**「可以翻」：首次翻会弹系统下载确认 ⇒ 会打断阅读。
  ///    所以本状态**不自动走端侧**（见 `translation_service.dart` ① 的判据）。
  supported,

  /// ⛔ 系统不支持这一对语言。
  unsupported,

  /// ⛔ 设备/系统不支持（iOS < 18）· 桥接不可用 · 查询异常。
  unavailable,
}

extension OnDeviceTranslateStatusX on OnDeviceTranslateStatus {
  /// 🔑 **只有 `installed` 才算可用** —— `supported` 需要现场下载（几十 MB），
  ///    在「划词翻译」这个场景里等下载是**不可接受**的体验（用户只是想知道这个词什么意思）。
  bool get canTranslate => this == OnDeviceTranslateStatus.installed;
}

// ══════════════════════════════════════════════════════════════════════
// 分句
// ══════════════════════════════════════════════════════════════════════

/// 句末标点（半角 + 全角）。
const String _enders = '.!?…。！？';

/// **全角**句末标点。
///
/// 🔑 中文**不用空格分隔**（`你好。你好吗？`）⇒ 对全角标点**不能**要求
///    「后面是空白」才断句 —— 否则整段中文会被当成一句。
///    半角标点才需要那个检查（为的是不把 `a.m.` / `U.S.` 从中间切断）。
const String _fullWidthEnders = '。！？';

/// 断句时**并入前一句**的收尾符号（引号类）。
const String _trailers = '"\'”’」』';

/// 段数上限（纯防御）。
///
/// 800 字符正常切不出上百句；但若出现**无空白的长串**（例如被人为塞成一行的文本），
/// 切分会退化成「一句 = 一整段」。这里给个硬上限，超出部分**合并成最后一段** ——
/// 因为「段数爆炸」会让批翻译与浮层渲染都变慢，而合并只是少几行对照。
const int kMaxOnDeviceSegments = 200;

/// 把一段文本切成**句子**。
///
/// # 🔴 为什么必须切
/// 服务端返回的 `segments[]` 是 `{src, dst}` 的**逐句对照**（译文浮层就按它对排）。
/// 而端侧 `TranslationSession` 只给「整段译文」⇒ 不切句的话，浮层会退化成
/// 「一大段原文 + 一大段译文」。切句后**仍是逐句对照**（UI 形态一个字不变）。
///
/// # 规则（刻意保守）
/// | 规则 | 守的是什么 |
/// |---|---|
/// | 断句点 = `.` `!` `?` `…` `。` `！` `？` | 常规句末 |
/// | 半角标点后**必须**是空白或结尾才断 | 🔴 否则 `a.m.` / `U.S.` 的**内部**点会被切断 |
/// | **全角**标点（`。！？`）**直接断** | 🔑 中文不用空格分隔 ⇒ 要求空白会让整段中文变成一句 |
/// | 收尾引号并入前一句 | `He said "go."` 不该把引号剩给下一句 |
///
/// ## ⚠️ 已知局限（如实标注，不要以为它完备）
/// · **缩写仍会被误判为句末**：`The U.S. is large.` 会切成 2 段（译成更碎的对照行）。
///   完美分句需要 NLP（缩写词典 + 上下文），而端侧只是**加速层** ——
///   服务端 LLM 分段没有这个问题。**若将来引入缩写白名单，请连带更新断言。**
/// · 与服务端 LLM 的分段**不可能完全一致**（那是模型判断）。两边本就是不同引擎，
///   不追求逐字对齐，只要求「切得合理」。
List<String> splitSentences(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];

  final out = <String>[];
  final buf = StringBuffer();

  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    buf.write(c);
    if (!_enders.contains(c)) continue;
    // 🔑 先记下**进入时**的标点是不是全角 —— 后面吞标点会改变 `c` 的含义
    final fullWidth = _fullWidthEnders.contains(c);

    // ① 吞掉连续的句末标点（`?!` / `...`）与紧邻的收尾引号
    while (i + 1 < t.length) {
      final next = t[i + 1];
      final isEnder = _enders.contains(next);
      final isTrailer = _trailers.contains(next);
      if (!isEnder && !isTrailer) break;
      // 收尾引号后面若还有非空白，说明它属于别处（如 `"a" and "b"`）⇒ 不并入
      if (isTrailer && i + 2 < t.length && !_isSpace(t[i + 2])) break;
      i++;
      buf.write(next);
    }

    // ② 断句条件（两条，缺一不可）：
    //    · **全角**标点 ⇒ 直接断（中文不用空格分隔）
    //    · 半角标点 ⇒ 后面必须是空白/结尾（否则 `a.m.` / `U.S.` 会被从中间切断）
    if (fullWidth || i + 1 >= t.length || _isSpace(t[i + 1])) {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }
  }

  final rest = buf.toString().trim();
  if (rest.isNotEmpty) out.add(rest);

  // ③ 空输入之外恒有内容（兜底：整段作为一句）
  if (out.isEmpty) return [t];

  if (out.length > kMaxOnDeviceSegments) {
    final head = out.take(kMaxOnDeviceSegments - 1).toList();
    head.add(out.skip(kMaxOnDeviceSegments - 1).join(' '));
    return head;
  }
  return out;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
