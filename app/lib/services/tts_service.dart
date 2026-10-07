import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'speech_chunks.dart';
import 'speech_text.dart';

/// N14: TTS Service — Device-native speech synthesis + Tencent Cloud TTS
///
/// Provides a unified interface for text-to-speech across engines.
enum TtsState { loading, playing, stopped, paused }

// ─────────────────────────────────────────────────────────────
// 语速范围 —— **唯一权威是库自己声明的值**
// ─────────────────────────────────────────────────────────────

/// 语速下限。不用 `0`：`0` = 完全不读，是无效配置而非「最慢」。
const double kSpeechRateMin = 0.1;

/// 语速上限 = `flutter_tts` **自己声明**的 flutter 侧 max。
///
/// 依据（读的是包源码，不是文档）：`flutter_tts-4.2.5` 的
/// `getSpeechRateValidRange()` 返回 `min 0 · normal 0.5 · max 1.5`。
const double kSpeechRateMax = 1.5;

/// 默认语速。
///
/// # 🔴 2026-10-07 真机修复：`1.0` → **`0.5`**
///
/// 白哥 iOS 真机首测反馈：「默认语速过快，只有调到 **0.5** 才是正常语速」。
/// 而 `0.5` 正是本文件下面那个常量 [kSpeechRateNormal] ——
/// 即 `flutter_tts` **自己声明的 `normal`**（`getSpeechRateValidRange()` 返回
/// `min 0 · normal 0.5 · max 1.5`）。
///
/// ⚠️ **本文件此前的注释已经预言了这次反馈**（原文保留在下方历史里）：
///   「⚠️ 它**不是最保守**的选择（最保守是 `0.5`）。
///     📌 若真机再反馈不稳 → 降到 `kSpeechRateNormal`。」
///   ⇒ 现在正是那个触发条件。
///
/// 📌 判据：**默认值应当取「库声明的中位值」，而不是「贴着上限的历史值」** ——
///    贴着上限意味着任何平台实现差异都会表现为「太快」，而慢了只是「不够快」，
///    后者用户能自己调、前者会让人以为功能坏了。
///
/// ## 历史（保留作决策史）
/// · 原值 `1.0` 的依据是「与用户长期在用的值一致（不改变体验）」——
///   它的代价是**贴着上限**（映射到 Android 是 `2.0` = Android 原生文档的合法上限）。
/// · `c49673c` 曾把它改成 `1.5` 引入过一次事故，后回到 `1.0`。
/// · 🆕 2026-10-07 白哥定案：**统一 `0.5`**（不做平台分叉）。
const double kSpeechRateDefault = 0.5;

/// 库声明的「正常语速」（flutter 侧）。保留常量是为了**让上一条注释可执行**。
const double kSpeechRateNormal = 0.5;

/// 把任意输入钳到合法范围 —— **本文件唯一的语速入口**。
///
/// # 🔴 为什么必须由我们钳（2026-10-02 真机事故）
///
/// `flutter_tts` 的 Android 实现（`FlutterTtsPlugin.kt`）：
/// ```kotlin
/// "setSpeechRate" -> {
///     setSpeechRate(rate.toFloat() * 2.0f)   // 🔴 会乘 2
///     result.success(1)                       // 🔴 硬编码成功 —— 永不报错
/// }
/// private fun setSpeechRate(rate: Float) {
///     tts!!.setSpeechRate(rate)               // 🔴 Android 的返回值(ERROR/SUCCESS)被丢弃
/// }
/// ```
/// ⇒ **无论值是否合法，Dart 侧都收不到任何错误。**
///
/// 而曾默认 `1.5`（→ Android **3.0**）、Slider 允许到 `2.0`（→ Android **4.0**），
/// 症状是：**引擎接受朗读请求（`speak` 返回 1）但不产生声音**，全程零报错。
/// 真机上表现为「喇叭图标变停止、就是没声」，且**新装用户必现**（prefs 空 → 落到坏默认值）。
///
/// 📌 判据：**「第三方库报成功」不能当作「值合法」** —— 范围要由**我们自己的代码**兑现。
///    同族：`mature-package-replacement` skill 的「决定要靠自己的代码兑现，不在依赖身上寄生」。
///
/// ⚠️ **加载持久化值时也要过这里** —— 只改默认值**修不好**已经存在设备上的坏值。
double clampSpeechRate(double v) {
  if (v.isNaN) return kSpeechRateDefault;
  return v.clamp(kSpeechRateMin, kSpeechRateMax);
}

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  TtsState state = TtsState.stopped;
  bool _enabled = true;
  double _speechRate = kSpeechRateDefault;
  Map<String, dynamic>? _selectedVoice;
  List<Map<String, dynamic>> _availableVoices = [];
  String? _currentPlayingText;

  // 单调递增的"代"计数器。每次发起新请求时 +1，
  // 异步回调完成时检查回调请求的代是否仍是最新一代，否则丢弃。
  int _playGen = 0;

  // ── 长文本朗读的**分段队列**（2026-10-05 加）──
  //
  // # 🔴 为什么需要队列（真机反馈：书库「整章朗读」没声音且不报错）
  //
  // 根因：整章正文（数千～数万字符）**远超平台单次输入上限**
  // （Android `getMaxSpeechInputLength()` ≈ 4000；iOS `AVSpeechUtterance` 同样有上限），
  // 而 `_cleanText` 不截断 ⇒ 平台拒收，且 `awaitSpeakCompletion` 未开启
  // ⇒ `speak()` 立即返回、**Dart 侧收不到失败** ⇒ 表现为「点了没反应」。
  //
  // 修法：**分段 + 用 completion 回调依次推进**（切分逻辑在
  // `speech_chunks.dart`，那是零 import 的纯 Dart，本机可断言）。
  //
  // 🔑 `_currentPlayingText` 仍存**整段原文**（不是当前小块）——
  //    因为 UI 判断按钮状态用的是 `isSpeaking(整章文本)`，改了就永远判不到。
  List<String> _queue = const <String>[];
  int _queueIndex = 0;

  /// 单次插件调用的**有界超时**。
  ///
  /// # 🔴 为什么必须有出口（2026-10-02）
  /// `flutter_tts` 在**引擎未就绪**时会把调用挂起、**永不回调**：
  /// ```kotlin
  /// if (ttsStatus == null) { pendingMethodCalls.add(...); return }   // 🔴 result 永不返回
  /// ```
  /// ⇒ Dart 侧 `await _tts.stop()` **永久挂着** → 后面一行都到不了
  ///   → UI **永久停在 loading 转圈**，无报错、无出口。
  /// 📌 判据：**「静默失败 + 无出口」比「报错」更糟**（本项目既定）。
  ///
  /// 超时后 [`_guard`] 返回 `null` → `state` 复位 → **按钮变回可点**（用户能重试，而不是干等）。
  static const Duration _kPluginTimeout = Duration(seconds: 3);

  /// 包一层超时 —— 插件不回调时**不让调用方永久挂起**。
  ///
  /// 返回 `null` = 超时（**而不是抛异常**）：调用点写 `if (result != 1)` 这类
  /// 判定时天然把 `null` 归入「没成功」，不必每处都写 try/catch。
  Future<T?> _guard<T>(Future<T> op, String label) async {
    try {
      return await op.timeout(_kPluginTimeout);
    } on TimeoutException {
      debugPrint('[TTS] $label 超时（插件未回调）→ 放弃本次调用');
      return null;
    }
  }

  TtsService() {
    _tts.setCompletionHandler(() {
      debugPrint('[TTS] native completion');
      // 🆕 2026-10-05：**队列推进** —— 长文本分段朗读靠这条回调串起来。
      //
      // 🔑 与词卡朗读（`togglePlay`）**共用**这一条回调，靠 `_queue` 是否为空区分：
      //    · 队列非空且还有下一段 → 推进（长文本路径）
      //    · 否则 → 复位（词卡的既有行为，一字未改）
      if (_queue.isNotEmpty && _queueIndex < _queue.length - 1) {
        _queueIndex++;
        debugPrint('[TTS]  queue ${_queueIndex + 1}/${_queue.length}');
        unawaited(_speakChunkAt(_queueIndex, _playGen));
      } else {
        _resetQueue(notify: true);
      }
    });
    _tts.setErrorHandler((msg) {
      debugPrint('[TTS] native error: $msg');
      // 🔴 出错也要清队列 —— 否则「队列还在、但不会推进」会一直挂着
      _resetQueue(notify: false);
      state = TtsState.stopped;
    });
  }

  /// 初始化可用音色列表
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('tts_enabled') ?? true;
    // 🔑 **必须钳制** —— 见 [clampSpeechRate]：设备上可能存着旧版本写入的越界值，
    //    而「只改默认值」对它们无效（读得到 prefs 就永远不会走默认值）。
    _speechRate = clampSpeechRate(
      prefs.getDouble('tts_speech_rate') ?? kSpeechRateDefault,
    );
    // ⚠️ `getVoices` 也走同一条 method channel ⇒ 引擎未就绪时**同样会永久挂起**，
    //    故一并过 `_guard`（取不到就是空列表，音色下拉框显示「系统默认」，不影响朗读）。
    //
    // 🔑 插件这个 getter 的**静态类型是 `Future<dynamic>`**（未声明泛型）⇒
    //    原写法 `_availableVoices = await _tts.getVoices` 其实是**隐式运行时强转**：
    //    插件一旦返回别的形状（null / 非 Map 元素）就抛 `TypeError` —— 而它发生在
    //    `init()` 里，会被上游吞成「音色列表为空」，**看不出是类型问题**。
    //    ⇒ 这里显式做一次**逐元素规范化**：类型不对的元素直接丢弃，不猜、不抛。
    final raw = await _guard<dynamic>(_tts.getVoices, 'getVoices');
    _availableVoices = (raw is List ? raw : const <dynamic>[])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
    notifyListeners();
  }

  /// 播放/停止切换（手动按钮用）
  ///
  /// 2026-09-26：TTS 全量端侧 `flutter_tts`（腾讯云路径与音频字节缓存已移除）。
  Future<void> togglePlay(String text) async {
    if (!_enabled || text.isEmpty) return;

    // 🔴 短文本播放必须**清掉长文本队列** —— 否则「整章朗读中点了词卡」会出现
    //    词卡读完后 completion 又去推进整章队列（两条播放流互相抢）。
    _resetQueue(notify: false);

    debugPrint('[TTS] togglePlay: "${_trunc(text)}" gen=$_playGen');

    // 如果正在播放同一段文本 → 停止
    if (_currentPlayingText == text && state == TtsState.playing) {
      debugPrint('[TTS]  same text playing, stopping');
      _currentPlayingText = null;
      _playGen++;  // 废弃当前代，阻止任何进行中的回调继续播放
      state = TtsState.stopped;
      notifyListeners();
      await _guard(_tts.stop(), 'stop');
      return;
    }

    // 递增代，使之前进行中的异步回调失效
    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS]  new gen=$myGen');

    await _guard(_tts.stop(), 'stop');

    if (myGen != _playGen) {
      debugPrint('[TTS]  gen changed, abort');
      return;
    }

    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();
    await _speakWithNative(myGen, text);
  }

  /// **长文本朗读**：分段 + 依次播放（修「整章朗读没声音」· 2026-10-05）。
  ///
  /// 与 [togglePlay] 的分工：
  /// · [togglePlay] —— **短文本**（词卡 / 试听），一次 `speak` 就够
  /// · 本方法 —— **长文本**（整章正文），必须先分段（见 [splitForSpeech]）
  ///
  /// 🔑 停止用 [stop]（由调用方判断 `isSpeaking(原文)` 决定「播 / 停」）——
  ///    本方法**不复用** `togglePlay` 的「同一文本再点即停」逻辑，
  ///    因为那个逻辑对长文本没有意义（用户要的是「整章读完」而不是「再点一次切歌」）。
  Future<void> speakLong(String text) async {
    if (!_enabled || text.isEmpty) return;

    // 🔑 分段在 `_cleanText` **之后** —— 先清 markdown 再算长度，
    //    否则可能按「含标记的长度」切、实际内容更短（白切）。
    final chunks = splitForSpeech(_cleanText(text));

    debugPrint('[TTS] speakLong: ${text.length} 字符 → ${chunks.length} 段');
    if (chunks.isEmpty) return;

    _playGen++;
    final myGen = _playGen;

    // 先停掉一切在播的东西（含其它队列）
    _resetQueue(notify: false);
    await _guard(_tts.stop(), 'stop');
    // ⚠️ 同 `_speakWithNative`：`stop()` 后立刻 `speak()` 会被插件丢弃
    //    （插件没暴露「已停止」状态可等 —— 本项目的不得已，见那里的注释）
    await Future.delayed(const Duration(milliseconds: 100));
    if (myGen != _playGen) return;

    _queue = chunks;
    _queueIndex = 0;
    // 🔴 存**原文**（不是当前小块）—— UI 的 `isSpeaking(整章文本)` 靠它
    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();

    await _speakChunkAt(0, myGen);
  }

  /// 播放队列中第 [index] 段。段间**不再 `stop()`**（上一段已读完才推进）。
  Future<void> _speakChunkAt(int index, int myGen) async {
    if (myGen != _playGen) {
      debugPrint('[TTS]  gen stale, abort chunk $index');
      return;
    }
    if (index >= _queue.length) {
      _resetQueue(notify: true);
      return;
    }
    _queueIndex = index;
    final chunk = _queue[index];

    try {
      // 🔑 语言**按段**判定 —— 中英混排的书里，每段的 `_detectLanguage` 可能不同，
      //    用第一段的语言读完整本会出现「用中文腔读英文」。
      final lang = _detectLanguage(chunk);
      if (_selectedVoice != null) {
        await _guard(
            _tts.setVoice(Map<String, String>.from(_selectedVoice! as Map)), 'setVoice');
      } else {
        final best = _pickBestVoice(lang);
        if (best != null) {
          await _guard(_tts.setVoice(Map<String, String>.from(best as Map)), 'setVoice');
        } else {
          await _guard(_tts.setLanguage(lang), 'setLanguage');
        }
      }
      await _guard(_tts.setSpeechRate(_speechRate), 'setSpeechRate');
      await _guard(_tts.setVolume(1.0), 'setVolume');

      if (myGen != _playGen) return;

      state = TtsState.playing;
      notifyListeners();

      final result = await _guard(_tts.speak(chunk), 'speak');
      if (result != 1) {
        // 🔴 **单段失败就停整条队列** —— 继续读会变成
        //    「前半本没声、后半本有声」，比「整本没声」更难判断。
        debugPrint('[TTS]  chunk $index 未接受，停止队列');
        if (myGen == _playGen) _resetQueue(notify: true);
      }
      // ✅ 成功时**不在这里推进** —— 由 `setCompletionHandler` 在真正读完后推进
      //    （`speak()` 立即返回，它返回 1 只代表「请求被接受」）。
    } catch (e) {
      debugPrint('[TTS] chunk $index error: $e');
      if (myGen == _playGen) _resetQueue(notify: true);
    }
  }

  /// 清空队列。`notify: true` 时把状态复位为 `stopped` 并通知 UI。
  void _resetQueue({required bool notify}) {
    _queue = const <String>[];
    _queueIndex = 0;
    if (notify) {
      state = TtsState.stopped;
      notifyListeners();
    }
  }

  /// 兼容旧接口：直接播放（不切换停止）
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS] speak gen=$myGen: "${_trunc(text)}"');

    await _guard(_tts.stop(), 'stop');

    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();

    if (myGen != _playGen) {
      debugPrint('[TTS]  gen changed, abort speak');
      return;
    }

    await _speakWithNative(myGen, text, language: language);
  }

  /// 使用本地原生 TTS 朗读（带代检查）
  Future<void> _speakWithNative(int myGen, String text, {String? language}) async {
    try {
      // ⚠️ 这 100ms 是**绕第三方插件的竞态**（`stop()` 后立刻 `speak()` 会被丢弃）。
      //    它是本机判据「等条件成立 ＜ 等猜的时长」的**同类实例**，但此处属不得已：
      //    插件没有暴露「已停止」的状态可等。缓解手段是下面的 `myGen` 代检查
      //    （即使这里等错了，代检查也能挡住过期播放）。
      await _guard(_tts.stop(), 'stop');
      await Future.delayed(const Duration(milliseconds: 100));

      if (myGen != _playGen) {
        debugPrint('[TTS]  gen stale before native speak, abort');
        return;
      }

      final lang = language ?? _detectLanguage(text);

      if (_selectedVoice != null) {
        await _guard(
            _tts.setVoice(Map<String, String>.from(_selectedVoice! as Map)), 'setVoice');
      } else {
        // 无用户指定音色 → 按语言自动挑该语言内质量最高的音色；
        // 挑不到（无匹配语言、或音色列表为空）返回 null → 交给系统按 lang 选默认音色
        final best = _pickBestVoice(lang);
        if (best != null) {
          await _guard(_tts.setVoice(Map<String, String>.from(best as Map)), 'setVoice');
        } else {
          await _guard(_tts.setLanguage(lang), 'setLanguage');
        }
      }
      // 🔑 `_speechRate` 在 setter 与 `init()` 两处都已钳过（见 [clampSpeechRate]），
      //    这里不再重复判断 —— 保证「值合法」只有一处权威。
      await _guard(_tts.setSpeechRate(_speechRate), 'setSpeechRate');
      await _guard(_tts.setVolume(1.0), 'setVolume');

      state = TtsState.playing;
      notifyListeners();
      // 清理 markdown 标记后再朗读（`**bold**`、标题符号等会被逐字念出来）
      final result = await _guard(_tts.speak(_cleanText(text)), 'speak');
      if (result != 1) {
        if (myGen == _playGen) {
          state = TtsState.stopped;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('TTS speak error: $e');
      if (myGen == _playGen) {
        state = TtsState.stopped;
        notifyListeners();
      }
    }
  }

  /// Stop playback
  Future<void> stop() async {
    debugPrint('[TTS] stop  gen=$_playGen');
    _playGen++; // 废弃当前代
    // 🔴 必须清队列：否则已排队的后续分段还会被 completion 推进 ⇒「按了停止还在念」
    _resetQueue(notify: false);
    await _guard(_tts.stop(), 'stop');
    state = TtsState.stopped;
    _currentPlayingText = null;
    notifyListeners();
  }

  // ── Getters / Setters ──
  bool get isPlaying => state == TtsState.playing && _currentPlayingText != null;
  bool get enabled => _enabled;

  /// 当前正在朗读的文本（`null` = 没有）。
  String? get currentText => _currentPlayingText;

  /// **这一段**是否正在朗读（含 `loading` 态）。
  ///
  /// 🔴 为什么需要它（2026-09-28 21:4x）：
  /// 一张词卡上现在有**多个喇叭**（词头 + ④ 语境 + 每条搭配），
  /// 若各按钮都用全局 [isPlaying] 判断，**所有喇叭会一起变成「播放中」** ——
  /// 用户点了语境，词头那个也跟着亮，看不出到底在读哪段。
  ///
  /// ⚠️ `loading` 也算「这一段在忙」：首次朗读有准备时间，
  ///    这段时间按钮要显示转圈，而不是退回「未播放」再跳「播放中」（会闪）。
  ///
  /// 🔑 只读判定，**不改 [togglePlay] 的既有语义**（它的停止判定用
  ///    `state == playing`，与这里刻意保留差异 —— 动它会改变点击行为）。
  bool isSpeaking(String text) =>
      text.isNotEmpty &&
      _currentPlayingText == text &&
      (state == TtsState.playing || state == TtsState.loading);

  set enabled(bool v) {
    _enabled = v;
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('tts_enabled', v));
    notifyListeners();
  }

  double get speechRate => _speechRate;

  /// 设置语速。
  ///
  /// 🔴 **必须钳制**（见 [clampSpeechRate]）—— 插件对越界值**静默成功**，
  ///    症状是「图标变停止、就是没声音」，且**不报任何错**。
  ///    写入口只有这一处 + `init()` 读持久化值那一处，两处都过同一个函数。
  set speechRate(double v) {
    _speechRate = clampSpeechRate(v);
    // ⚠️ setter 是**同步**方法，不能 `await` ⇒ 用 `unawaited` +
    //    仍走 `_guard`（插件挂起时 Future 永远 pending，但**不会阻塞 UI**
    //    因为没有 await；同时也不会再出现「裸调用」这种无保护写法）。
    unawaited(_guard(_tts.setSpeechRate(_speechRate), 'setSpeechRate'));
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setDouble('tts_speech_rate', _speechRate));
    notifyListeners();
  }

  Map<String, dynamic>? get selectedVoice => _selectedVoice;
  List<Map<String, dynamic>> get availableVoices => _availableVoices;

  Future<void> selectVoice(Map<String, dynamic>? voice) async {
    _selectedVoice = voice;
    if (voice != null) {
      await _guard(_tts.setVoice(Map<String, String>.from(voice as Map)), 'setVoice');
    }
    notifyListeners();
  }

  String _detectLanguage(String text) {
    if (text.isEmpty) return 'en-US';
    final hasCjk = text.runes.any((r) =>
        (r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0x2E80 && r <= 0x2EFF) ||
        (r >= 0x3000 && r <= 0x303F) ||
        (r >= 0xFF00 && r <= 0xFFEF));
    return hasCjk ? 'zh-CN' : 'en-US';
  }

  /// iOS `AVSpeechSynthesisVoice.quality` 档位权重（数值越大越好）
  ///
  /// 依据（实测 flutter_tts 源码，非猜测）：
  ///   `flutter_tts-4.2.5/ios/Classes/SwiftFlutterTtsPlugin.swift:344`
  ///   `voiceDict["quality"] = voice.quality.stringValue` → "default" | "enhanced" | "premium"
  /// 其中 `default` 即 iOS 内置 Compact 音色（体积几十 KB，听感为「机器人音」）；
  /// Enhanced / Premium 需用户在「设置 → 辅助功能 → 朗读内容 → 声音」手动下载。
  static const Map<String, int> _qualityRank = {
    'premium': 3,
    'enhanced': 2,
    'default': 1,
  };

  /// 在候选集中取质量最高的音色（同分保持原顺序，保证行为确定性）
  ///
  /// 为什么必要：`getVoices` 返回时**不按质量排序**（同 locale 可同时存在
  /// default / enhanced / premium 多条），若只取首个命中就可能落到 Compact，
  /// 使端侧朗读音质低于原腾讯云精品音色。
  ///
  /// ⚠️ 本机无 iOS 真机，无法验证真实音色列表与实际听感 → 需真机确认（见决策文档 §6.2）。
  Map<String, dynamic> _pickHighestQuality(List<Map<String, dynamic>> candidates) {
    var best = candidates.first;
    var bestRank = _qualityRankOf(best);
    for (final v in candidates.skip(1)) {
      final rank = _qualityRankOf(v);
      if (rank > bestRank) {
        best = v;
        bestRank = rank;
      }
    }
    return best;
  }

  /// 读取音色质量档位权重；无 `quality` 字段（Android / Web）按 default 处理，不降级
  int _qualityRankOf(Map<String, dynamic> voice) {
    final q = (voice['quality'] as String?)?.toLowerCase();
    return _qualityRank[q] ?? 1;
  }

  Map<String, dynamic>? _pickBestVoice(String language) {
    if (_availableVoices.isEmpty) return null;
    final voices = _availableVoices
        .cast<Map<String, dynamic>?>()
        .whereType<Map<String, dynamic>>()
        .toList();
    if (voices.isEmpty) return null;

    // ① 精确 locale 匹配 → 同 locale 内优先高质量档
    final exact = voices.where((v) => v['locale'] == language).toList();
    if (exact.isNotEmpty) return _pickHighestQuality(exact);

    // ② 同语言前缀匹配 → 同样优先高质量档
    final langPrefix = language.split('-').first;
    final prefix = voices
        .where((v) => ((v['locale'] as String?) ?? '').startsWith(langPrefix))
        .toList();
    if (prefix.isNotEmpty) return _pickHighestQuality(prefix);

    // ③ 无匹配语言 → 返回 null，由调用方回落到 setLanguage(lang)
    //
    // 🔴 2026-09-26 修复：原为 `return voices.first`（取列表首个）
    //    隐患：`getVoices` 返回的是**系统全部音色**（含 zh/ja/fr…），首个命中
    //    很可能不是目标语言 → 会出现「用中文音色念英文」甚至「用日语腔读」。
    //    改为 null 后由 `_tts.setLanguage(lang)` 交给 iOS 选该语言的默认音色，语义正确。
    return null;
  }

  /// 把待朗读文本清成**能听的纯文本**。
  ///
  /// # 🔴 2026-10-06：由「手写一串 `replaceAll`」改为**委托** `speechTextFromMarkdown`
  ///
  /// ## 原实现的两个缺口（`docs/design/article-tts-entry-2026-10-06.html` §四）
  ///
  /// 原实现逐条列在这里（**已全部删除**，留作对照）：
  /// ```dart
  /// .replaceAll('**', '')      // 只去双星，单星 `/` `*` 强调不管
  /// .replaceAll('### ', '')    // 只去「井号 + 空格」这一种写法
  /// .replaceAll('\\(', '')     // ← 只去**转义的**圆括号
  /// .replaceAll('\\[', '')     // ← 只去**转义的**方括号
  /// ```
  /// 最后一个就是**真事故**：`[Law](https://www.npr.org/sections/law/)` 里是
  /// **普通**方括号，`\[` 那条规则**完全不受影响** ⇒ **整条 URL 被逐字念出来**
  /// （「h-t-t-p-s colon slash slash …」）。生产库实测这种行很常见。
  ///
  /// 链接 / 图片 / 裸 URL / 行内代码 / 表格分隔线 —— 一个都没处理。
  ///
  /// ## 现在：一处权威
  ///
  /// `speechTextFromMarkdown` 已把这套规则做完整（92 项断言 · 含真实 NPR 样本），
  /// 所以这里**只保留 TTS 特有的** `<graph>` 清理，其余全部交给它。
  /// 📌 判据：**同一件事的口径只能一处权威** —— 两份实现并存时，
  /// 只有一份会随新用例修好，另一份会**静默地**留在旧口径上。
  ///
  /// ⚠️ 顺序：`<graph>` 必须**先删**再委托 ——
  ///    `speechTextFromMarkdown` 的 HTML 标签规则会剥掉 `<graph>` **标签本身**，
  ///    却**留下里面的图形 JSON**（那些内容会被逐字念出来）。
  ///
  /// 🔴 影响面（三处共用）：**词卡朗读**（[togglePlay]）·
  ///    **书库整章朗读**（[speakLong]）· **文章朗读**（信息流阅读器）。
  ///    前两处是既有的 ⇒ 白哥 2026-10-06 批准「一并做」，
  ///    并要求真机复验书库朗读（章节是端侧数据，本机无样本）。
  String _cleanText(String text) {
    return speechTextFromMarkdown(
      text.replaceAll(RegExp(r'<graph>.*?</graph>', dotAll: true), ''),
    );
  }

  /// 日志截断辅助
  String _trunc(String s, [int max = 30]) =>
      s.length > max ? '${s.substring(0, max)}...' : s;
}

/// Riverpod provider for TTS service
final ttsServiceProvider = ChangeNotifierProvider<TtsService>((ref) {
  final tts = TtsService();
  tts.init();
  return tts;
});

/// Riverpod provider for TTS enabled state
final ttsEnabledProvider = StateProvider<bool>((ref) => true);

/// Riverpod provider for TTS auto-play toggle
final ttsAutoPlayProvider = StateProvider<bool>((ref) => true);
