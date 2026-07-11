import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import '../api/chat_client.dart';
import '../api/api_config.dart';

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
  ChatClient? _client;

  // 当前正在播放的 AudioPlayer（Tencent TTS，用户点击触发）
  AudioPlayer? _currentPlayer;
  // auto-play 独立播放器（WS tts_audio 触发，流式分块播放）
  AudioPlayer? _autoPlayer;
  final List<Uint8List> _autoQueue = [];
  bool _autoPlaying = false;
  String? _currentPlayingText;

  // 单调递增的"代"计数器。每次发起新请求时 +1，
  // 异步回调完成时检查回调请求的代是否仍是最新一代，否则丢弃。
  int _playGen = 0;

  // TTS 缓存: 已合成的文本 → 音频字节
  final Map<String, Uint8List> _ttsCache = {};

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

  void bindClient(ChatClient client) {
    _client = client;
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
      await _currentPlayer?.stop();
      _currentPlayer?.dispose();
      _currentPlayer = null;
      await _tts.stop();
      return;
    }

    // 递增代，使之前进行中的异步回调失效
    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS]  new gen=$myGen');

    // 停止当前播放
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();

    // 检查缓存（由 auto-play 预先缓存）
    final prefs = await SharedPreferences.getInstance();
    if (myGen != _playGen) {
      debugPrint('[TTS]  gen changed during cache check, abort');
      return;
    }

    _currentPlayingText = text;
    final cached = _ttsCache[text];
    if (cached != null) {
      debugPrint('[TTS]  playing from cache');
      _playCached(myGen, text, cached);
      return;
    }

    // 无缓存 → 加载 + 播放
    state = TtsState.loading;
    notifyListeners();

    final engine = prefs.getString('tts_engine') ?? 'tencent';
    if (engine == 'tencent') {
      await _fetchAndPlayTencent(myGen, text);
    } else {
      await _speakWithNative(myGen, text);
    }
  }

  /// 兼容旧接口：直接播放（不切换停止）
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS] speak gen=$myGen: "${_trunc(text)}"');

    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();

    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();

    final engine = await _getTtsEngine();
    if (myGen != _playGen) {
      debugPrint('[TTS]  gen changed, abort speak');
      return;
    }

    if (engine == 'tencent') {
      await _fetchAndPlayTencent(myGen, text);
    } else {
      await _speakWithNative(myGen, text, language: language);
    }
  }

  /// 缓存音频（不播放）
  /// 缓存音频（不播放）— 自动清理文本格式以匹配按钮 key
  void cacheAudio(String text, Uint8List audio) {
    _ttsCache[_cleanText(text)] = audio;
  }

  /// 播放 auto-play 音频（流式：多个 chunk 逐个播放）
  void playAutoStream(Uint8List audio) {
    if (audio.isEmpty) {
      debugPrint('[TTS] auto-play: empty audio, skipping');
      return;
    }
    _autoQueue.add(Uint8List.fromList(audio));
    if (!_autoPlaying) {
      _autoPlaying = true;
      _playNextAuto();
    }
  }

  void _playNextAuto() {
    if (_autoQueue.isEmpty) {
      _autoPlaying = false;
      _autoPlayer = null;
      return;
    }
    final audio = _autoQueue.removeAt(0);
    _autoPlayer?.stop();
    _autoPlayer?.dispose();
    final player = AudioPlayer();
    _autoPlayer = player;
    try {
      player.setSource(BytesSource(audio));
      player.resume();
      player.onPlayerComplete.listen((_) {
        if (_autoPlayer == player) {
          _playNextAuto();
        }
      });
    } catch (e) {
      debugPrint('[TTS] auto-play exception: $e');
      _playNextAuto();
    }
  }

  /// 缓存并播放（由 auto-play 调用）
  Future<void> cacheAndPlay(String text, Uint8List audio) async {
    _ttsCache[text] = audio;

    _playGen++;
    final myGen = _playGen;
    debugPrint('[TTS] cacheAndPlay gen=$myGen');

    // 停止当前
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();

    _currentPlayingText = text;
    _playCached(myGen, text, audio);
  }

  /// 播放已缓存的音频（带代检查）
  void _playCached(int myGen, String text, Uint8List audio) {
    if (myGen != _playGen) {
      debugPrint('[TTS]  gen stale in _playCached, abort');
      return;
    }
    final player = AudioPlayer();
    _currentPlayer = player;
    player.setSource(BytesSource(Uint8List.fromList(audio)));
    player.resume();
    state = TtsState.playing;
    notifyListeners();
    _listenPlayerComplete(player, myGen);
  }

  /// 监听播放完成，携带代检查
  void _listenPlayerComplete(AudioPlayer player, int myGen) {
    player.onPlayerComplete.listen((_) {
      if (_currentPlayer == player) {
        debugPrint('[TTS]  player complete, gen=$myGen current=$_playGen');
        _currentPlayer = null;
        if (myGen == _playGen) {
          state = TtsState.stopped;
          notifyListeners();
        }
        // if myGen != _playGen: 已有新的播放请求，不重置 state
      }
    });
  }

  /// 从后端获取 TTS 引擎偏好
  Future<String> _getTtsEngine() async {
    if (_client == null) return 'native';
    try {
      final prefs = await _client!.getPreferences();
      return prefs['tts_engine'] ?? 'tencent';
    } catch (_) {
      return 'tencent';
    }
  }

  /// 用腾讯云 TTS 合成并播放（带缓存 + 代检查）
  Future<void> _fetchAndPlayTencent(int myGen, String text) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/tts/speak'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': _cleanText(text),
          'user_id': _client?.userId ?? '',
        }),
      );

      if (myGen != _playGen) {
        debugPrint('[TTS]  gen stale after tencent fetch, discard');
        return;
      }

      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        _ttsCache[text] = Uint8List.fromList(resp.bodyBytes);
        debugPrint('[TTS]  tencent got ${resp.bodyBytes.length} bytes, gen=$myGen');

        if (myGen != _playGen) {
          debugPrint('[TTS]  gen stale before create player, discard');
          return;
        }

        final player = AudioPlayer();
        _currentPlayer = player;
        player.setSource(BytesSource(Uint8List.fromList(resp.bodyBytes)));
        player.resume();
        state = TtsState.playing;
        notifyListeners();
        _listenPlayerComplete(player, myGen);
      } else {
        debugPrint('[TTS]  tencent http ${resp.statusCode}, gen=$myGen');
        if (myGen == _playGen) {
          state = TtsState.stopped;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[TTS] tencent error: $e, gen=$myGen');
      if (myGen == _playGen) {
        state = TtsState.stopped;
        notifyListeners();
      }
    }
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
      } else if (_availableVoices.isNotEmpty) {
        final best = _pickBestVoice(lang);
        if (best != null) {
          await _tts.setVoice(Map<String, String>.from(best as Map));
        } else {
          await _tts.setLanguage(lang);
        }
      } else {
        await _tts.setLanguage(lang);
      }
      await _tts.setSpeechRate(_speechRate);
      await _tts.setVolume(1.0);

      state = TtsState.playing;
      notifyListeners();
      final result = await _tts.speak(text);
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
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _autoPlayer?.stop();
    _autoPlayer?.dispose();
    _autoPlayer = null;
    _autoQueue.clear();
    _autoPlaying = false;
    await _tts.stop();
    state = TtsState.stopped;
    _currentPlayingText = null;
    notifyListeners();
  }

  // ── Getters / Setters ──
  bool get isPlaying => (state == TtsState.playing && _currentPlayingText != null) || _autoPlayer != null;
  bool get enabled => _enabled;
  set enabled(bool v) {
    _enabled = v;
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('tts_enabled', v));
    _syncToBackend();
    notifyListeners();
  }

  double get speechRate => _speechRate;
  set speechRate(double v) {
    _speechRate = v;
    _tts.setSpeechRate(v);
    SharedPreferences.getInstance().then((prefs) => prefs.setDouble('tts_speech_rate', v));
    _syncToBackend();
    notifyListeners();
  }

  Map<String, dynamic>? get selectedVoice => _selectedVoice;
  List<Map<String, dynamic>> get availableVoices => _availableVoices;

  Future<void> selectVoice(Map<String, dynamic>? voice) async {
    _selectedVoice = voice;
    if (voice != null) {
      await _tts.setVoice(Map<String, String>.from(voice as Map));
    }
    _syncToBackend();
    notifyListeners();
  }

  Future<void> _syncToBackend() async {
    if (_client == null) return;
    final prefs = <String, String>{
      'tts_speed': _speechRate.toString(),
      'tts_enabled': _enabled.toString(),
    };
    if (_selectedVoice != null) {
      prefs['tts_voice_name'] = _selectedVoice!['name']?.toString() ?? '';
      prefs['tts_voice_locale'] = _selectedVoice!['locale']?.toString() ?? '';
    }
    await _client!.savePreferences(prefs);
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

  Map<String, dynamic>? _pickBestVoice(String language) {
    if (_availableVoices.isEmpty) return null;
    final exact = _availableVoices.cast<Map<String, dynamic>?>().firstWhere(
      (v) => v?['locale'] == language,
      orElse: () => null,
    );
    if (exact != null) return exact;
    final langPrefix = language.split('-').first;
    final prefixMatch = _availableVoices.cast<Map<String, dynamic>?>().firstWhere(
      (v) {
        final loc = v?['locale'] as String? ?? '';
        return loc.startsWith(langPrefix);
      },
      orElse: () => null,
    );
    if (prefixMatch != null) return prefixMatch;
    return _availableVoices.first;
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
