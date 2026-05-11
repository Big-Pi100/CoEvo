import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/chat_client.dart';

/// N14: TTS Service — Device-native speech synthesis
///
/// Uses flutter_tts to speak AI replies aloud.
/// Can be toggled on/off by user preference.
/// Preferences are synced to backend via ChatClient.

enum TtsState { playing, stopped, paused }

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  TtsState state = TtsState.stopped;
  bool _enabled = true;
  double _speechRate = 1.0;
  Map<String, dynamic>? _selectedVoice;
  List<Map<String, dynamic>> _availableVoices = [];
  ChatClient? _client;

  TtsService() {
    _tts.setCompletionHandler(() => state = TtsState.stopped);
    _tts.setErrorHandler((msg) {
      state = TtsState.stopped;
    });
  }

  /// 绑定后端客户端（登录后调用）
  void bindClient(ChatClient client) {
    _client = client;
  }

  /// 初始化：加载本地偏好（零延迟），然后异步从后端同步
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _speechRate = prefs.getDouble('tts_speech_rate') ?? 1.0;
    _enabled = prefs.getBool('tts_enabled') ?? true;
    _loadVoices();
    // 异步同步后端偏好（不阻塞 UI）
    _syncFromBackend();
  }

  /// 从后端同步偏好数据
  Future<void> _syncFromBackend() async {
    if (_client == null) return;
    final remote = await _client!.getPreferences();
    if (remote.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    bool changed = false;

    // 语速
    if (remote.containsKey('tts_speech_rate')) {
      final rate = double.tryParse(remote['tts_speech_rate']!);
      if (rate != null && rate != _speechRate) {
        _speechRate = rate.clamp(0.1, 2.0);
        await prefs.setDouble('tts_speech_rate', _speechRate);
        changed = true;
      }
    }

    // 朗读开关
    if (remote.containsKey('tts_enabled')) {
      final enabled = remote['tts_enabled'] == 'true';
      if (enabled != _enabled) {
        _enabled = enabled;
        await prefs.setBool('tts_enabled', _enabled);
        changed = true;
      }
    }

    // 音色（best-effort 匹配）
    if (remote.containsKey('tts_voice_name') && remote.containsKey('tts_voice_locale')) {
      final savedName = remote['tts_voice_name'];
      final savedLocale = remote['tts_voice_locale'];
      await prefs.setString('tts_voice_name', savedName ?? '');
      await prefs.setString('tts_voice_locale', savedLocale ?? '');
      if (_availableVoices.isNotEmpty && savedName != null && savedLocale != null) {
        final match = _availableVoices.cast<Map<String, dynamic>?>().firstWhere(
          (v) => v?['name'] == savedName && v?['locale'] == savedLocale,
          orElse: () => null,
        );
        if (match != null) {
          _selectedVoice = match;
          changed = true;
        }
      }
    }

    if (changed) notifyListeners();
  }

  /// 同步当前偏好到后端
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

  /// 后台加载可用音色（Web 平台可能延迟，需重试）
  Future<void> _loadVoices() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final voices = await _tts.getVoices;
      if (voices is List && voices.isNotEmpty) {
        _availableVoices = voices.cast<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        // 加载完成后恢复首选音色
        final prefs = await SharedPreferences.getInstance();
        final savedName = prefs.getString('tts_voice_name');
        final savedLocale = prefs.getString('tts_voice_locale');
        if (savedName != null && savedLocale != null) {
          _selectedVoice = _availableVoices.cast<Map<String, dynamic>?>().firstWhere(
            (v) => v?['name'] == savedName && v?['locale'] == savedLocale,
            orElse: () => null,
          );
        }
        notifyListeners();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// 可用音色列表
  List<Map<String, dynamic>> get availableVoices => List.unmodifiable(_availableVoices);

  /// 当前选中的音色
  Map<String, dynamic>? get selectedVoice => _selectedVoice;

  /// 设置音色
  Future<void> selectVoice(Map<String, dynamic>? voice) async {
    _selectedVoice = voice;
    if (voice != null) {
      await _tts.setVoice(Map<String, String>.from(voice as Map));
    }
    final prefs = await SharedPreferences.getInstance();
    if (voice != null) {
      await prefs.setString('tts_voice_name', voice['name'] ?? '');
      await prefs.setString('tts_voice_locale', voice['locale'] ?? '');
    } else {
      await prefs.remove('tts_voice_name');
      await prefs.remove('tts_voice_locale');
    }
    _syncToBackend();
    notifyListeners();
  }

  bool get enabled => _enabled;
  set enabled(bool v) {
    _enabled = v;
    if (!v) stop();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('tts_enabled', _enabled);
    });
    _syncToBackend();
    notifyListeners();
  }

  /// Get/set the user's preferred speech rate (0.1 - 2.0 range).
  double get speechRate => _speechRate;
  set speechRate(double rate) {
    _speechRate = rate.clamp(0.1, 2.0);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('tts_speech_rate', _speechRate);
    });
    _syncToBackend();
    notifyListeners();
  }

  /// Speak the given text using the device's TTS engine
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100));

    if (_selectedVoice != null) {
      await _tts.setVoice(Map<String, String>.from(_selectedVoice! as Map));
    } else {
      final lang = language ?? _detectLanguage(text);
      await _tts.setLanguage(lang);
    }
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);

    state = TtsState.playing;
    final result = await _tts.speak(text);
    if (result != 1) {
      state = TtsState.stopped;
    }
  }

  /// Stop playback
  Future<void> stop() async {
    await _tts.stop();
    state = TtsState.stopped;
  }

  /// Simple language detection: check for CJK characters
  String _detectLanguage(String text) {
    final hasCjk = text.runes.any((r) =>
        (r >= 0x4E00 && r <= 0x9FFF) || // CJK Unified
        (r >= 0x4E00 && r <= 0x9FFF)    // (kept for compatibility)
    );
    return hasCjk ? 'zh-CN' : 'en-US';
  }
}

/// Riverpod provider for TTS service (ChangeNotifier 以便滑块/下拉框响应)
final ttsServiceProvider = ChangeNotifierProvider<TtsService>((ref) {
  final tts = TtsService();
  tts.init();
  return tts;
});

/// Riverpod provider for TTS enabled state
final ttsEnabledProvider = StateProvider<bool>((ref) => true);
