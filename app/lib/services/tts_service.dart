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
  double _speechRate = 1.0;
  Map<String, dynamic>? _selectedVoice;
  List<Map<String, dynamic>> _availableVoices = [];
  ChatClient? _client;
  AudioPlayer? _currentPlayer;
  String? _currentPlayingText;

  // TTS 缓存: 已合成的文本 → 音频字节
  final Map<String, Uint8List> _ttsCache = {};

  TtsService() {
    _tts.setCompletionHandler(() => state = TtsState.stopped);
    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
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
    _speechRate = prefs.getDouble('tts_speech_rate') ?? 1.0;
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

    // 如果正在播放同一段文本 → 停止
    if (_currentPlayingText == text && state == TtsState.playing) {
      _currentPlayingText = null;
      state = TtsState.stopped;
      notifyListeners();
      // 停止两种引擎
      await _currentPlayer?.stop();
      _currentPlayer?.dispose();
      _currentPlayer = null;
      await _tts.stop();
      return;
    }

    // 停止当前播放，准备播新的
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();
    _currentPlayingText = text;

    // 检查缓存（由 auto-play 预先缓存）
    final cached = _ttsCache[text];
    if (cached != null) {
      // 有缓存 → 直接播放
      final player = AudioPlayer();
      _currentPlayer = player;
      player.setSource(BytesSource(Uint8List.fromList(cached)));
      player.resume();
      state = TtsState.playing;
      notifyListeners();
      player.onPlayerComplete.listen((_) {
        if (_currentPlayer == player) {
          state = TtsState.stopped;
          _currentPlayer = null;
          notifyListeners();
        }
      });
      return;
    }

    // 无缓存 → 加载 + 播放
    state = TtsState.loading;
    notifyListeners();

    final engine = await _getTtsEngine();
    if (engine == 'tencent') {
      await _fetchAndPlayTencent(text);
    } else {
      await _speakWithNative(text);
    }
  }

  /// 兼容旧接口：直接播放（不切换停止）
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();

    _currentPlayingText = text;
    state = TtsState.loading;
    notifyListeners();

    final engine = await _getTtsEngine();
    if (engine == 'tencent') {
      await _fetchAndPlayTencent(text);
    } else {
      await _speakWithNative(text, language: language);
    }
  }

  /// 缓存音频（不播放）
  void cacheAudio(String text, Uint8List audio) {
    _ttsCache[text] = audio;
  }

  /// 缓存并播放（由 auto-play 调用）
  Future<void> cacheAndPlay(String text, Uint8List audio) async {
    _ttsCache[text] = audio;
    // 停止当前
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();
    // 播放
    _currentPlayingText = text;
    final player = AudioPlayer();
    _currentPlayer = player;
    player.setSource(BytesSource(audio));
    player.resume();
    state = TtsState.playing;
    notifyListeners();
    player.onPlayerComplete.listen((_) {
      if (_currentPlayer == player) {
        state = TtsState.stopped;
        _currentPlayer = null;
        notifyListeners();
      }
    });
  }

  /// 从后端获取 TTS 引擎偏好
  Future<String> _getTtsEngine() async {
    if (_client == null) return 'native';
    try {
      final prefs = await _client!.getPreferences();
      return prefs['tts_engine'] ?? 'native';
    } catch (_) {
      return 'native';
    }
  }

  /// 用腾讯云 TTS 合成并播放（带缓存）
  Future<void> _fetchAndPlayTencent(String text) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/tts/speak'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': _cleanText(text),
          'user_id': _client?.userId ?? '',
        }),
      );
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        // 缓存
        _ttsCache[text] = Uint8List.fromList(resp.bodyBytes);
        // 播放
        final player = AudioPlayer();
        _currentPlayer = player;
        player.setSource(BytesSource(Uint8List.fromList(resp.bodyBytes)));
        player.resume();
        state = TtsState.playing;
        notifyListeners();
        player.onPlayerComplete.listen((_) {
          if (_currentPlayer == player) {
            state = TtsState.stopped;
            _currentPlayer = null;
            notifyListeners();
          }
        });
      } else {
        state = TtsState.stopped;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Tencent TTS error: $e');
      state = TtsState.stopped;
      notifyListeners();
    }
  }

  /// 使用本地原生 TTS 朗读
  Future<void> _speakWithNative(String text, {String? language}) async {
    try {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 100));

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
        state = TtsState.stopped;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('TTS speak error: $e');
      state = TtsState.stopped;
      notifyListeners();
    }
  }

  /// Stop playback
  Future<void> stop() async {
    await _currentPlayer?.stop();
    _currentPlayer?.dispose();
    _currentPlayer = null;
    await _tts.stop();
    state = TtsState.stopped;
    notifyListeners();
  }

  // ── Getters / Setters ──
  bool get isPlaying => state == TtsState.playing && _currentPlayingText != null;
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
      'tts_speech_rate': _speechRate.toString(),
      'tts_enabled': _enabled.toString(),
    };
    if (_selectedVoice != null) {
      prefs['tts_voice_name'] = _selectedVoice!['name']?.toString() ?? '';
      prefs['tts_voice_locale'] = _selectedVoice!['locale']?.toString() ?? '';
    }
    await _client!.savePreferences(prefs);
  }

  Future<void> _loadVoices() async {
    for (int i = 0; i < 20; i++) {
      try {
        final voices = await _tts.getVoices;
        if (voices.isNotEmpty) {
          _availableVoices = voices;
          notifyListeners();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
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
final ttsAutoPlayProvider = StateProvider<bool>((ref) => false);
