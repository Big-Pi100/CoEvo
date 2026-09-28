import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// N14: TTS Service — Device-native speech synthesis + Tencent Cloud TTS
///
/// Provides a unified interface for text-to-speech across engines.
enum TtsState { loading, playing, stopped, paused }

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  TtsState state = TtsState.stopped;
  bool _enabled = true;
  double _speechRate = 1.5;
  Map<String, dynamic>? _selectedVoice;
  List<Map<String, dynamic>> _availableVoices = [];
  String? _currentPlayingText;

  // 单调递增的"代"计数器。每次发起新请求时 +1，
  // 异步回调完成时检查回调请求的代是否仍是最新一代，否则丢弃。
  int _playGen = 0;

  TtsService() {
    _tts.setCompletionHandler(() {
      debugPrint('[TTS] native completion');
      state = TtsState.stopped;
    });
    _tts.setErrorHandler((msg) {
      debugPrint('[TTS] native error: $msg');
      state = TtsState.stopped;
    });
  }

  /// 初始化可用音色列表
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('tts_enabled') ?? true;
    _speechRate = prefs.getDouble('tts_speech_rate') ?? 1.5;
    try {
      _availableVoices = await _tts.getVoices;
    } catch (_) {
      _availableVoices = [];
    }
    notifyListeners();
  }

  /// 播放/停止切换（手动按钮用）
  ///
  /// 2026-09-26：TTS 全量端侧 `flutter_tts`（腾讯云路径与音频字节缓存已移除）。
  Future<void> togglePlay(String text) async {
    if (!_enabled || text.isEmpty) return;

    debugPrint('[TTS] togglePlay: "${_trunc(text)}" gen=$_playGen');

    // 如果正在播放同一段文本 → 停止
    if (_currentPlayingText == text && state == TtsState.playing) {
      debugPrint('[TTS]  same text playing, stopping');
      _currentPlayingText = null;
      _playGen++;  // 废弃当前代，阻止任何进行中的回调继续播放
      state = TtsState.stopped;
      notifyListeners();
      await _tts.stop();
      return;
    }

    // 递增代，使之前进行中的异步回调失效
    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS]  new gen=$myGen');

    await _tts.stop();

    if (myGen != _playGen) {
      debugPrint('[TTS]  gen changed, abort');
      return;
    }

    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();
    await _speakWithNative(myGen, text);
  }

  /// 兼容旧接口：直接播放（不切换停止）
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS] speak gen=$myGen: "${_trunc(text)}"');

    await _tts.stop();

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
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 100));

      if (myGen != _playGen) {
        debugPrint('[TTS]  gen stale before native speak, abort');
        return;
      }

      final lang = language ?? _detectLanguage(text);

      if (_selectedVoice != null) {
        await _tts.setVoice(Map<String, String>.from(_selectedVoice! as Map));
      } else {
        // 无用户指定音色 → 按语言自动挑该语言内质量最高的音色；
        // 挑不到（无匹配语言、或音色列表为空）返回 null → 交给系统按 lang 选默认音色
        final best = _pickBestVoice(lang);
        if (best != null) {
          await _tts.setVoice(Map<String, String>.from(best as Map));
        } else {
          await _tts.setLanguage(lang);
        }
      }
      await _tts.setSpeechRate(_speechRate);
      await _tts.setVolume(1.0);

      state = TtsState.playing;
      notifyListeners();
      // 清理 markdown 标记后再朗读（`**bold**`、标题符号等会被逐字念出来）
      final result = await _tts.speak(_cleanText(text));
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
    _playGen++;  // 废弃当前代
    await _tts.stop();
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
  set speechRate(double v) {
    _speechRate = v;
    _tts.setSpeechRate(v);
    SharedPreferences.getInstance().then((prefs) => prefs.setDouble('tts_speech_rate', v));
    notifyListeners();
  }

  Map<String, dynamic>? get selectedVoice => _selectedVoice;
  List<Map<String, dynamic>> get availableVoices => _availableVoices;

  Future<void> selectVoice(Map<String, dynamic>? voice) async {
    _selectedVoice = voice;
    if (voice != null) {
      await _tts.setVoice(Map<String, String>.from(voice as Map));
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

  String _cleanText(String text) {
    return text
        .replaceAll('**', '')
        .replaceAll('### ', '')
        .replaceAll('## ', '')
        .replaceAll('# ', '')
        .replaceAll('\\(', '')
        .replaceAll('\\)', '')
        .replaceAll('\\[', '')
        .replaceAll('\\]', '')
        .replaceAll(RegExp(r'<graph>.*?</graph>', dotAll: true), '');
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
