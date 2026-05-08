import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// N14: TTS Service — Device-native speech synthesis
///
/// Uses flutter_tts to speak AI replies aloud.
/// Can be toggled on/off by user preference.

enum TtsState { playing, stopped, paused }

class TtsService {
  final FlutterTts _tts = FlutterTts();
  TtsState state = TtsState.stopped;
  bool _enabled = true;
  double _speechRate = 0.5;

  TtsService() {
    _tts.setCompletionHandler(() => state = TtsState.stopped);
    _tts.setErrorHandler((msg) {
      state = TtsState.stopped;
    });
  }

  bool get enabled => _enabled;
  set enabled(bool v) {
    _enabled = v;
    if (!v) stop();
  }

  /// Get/set the user's preferred speech rate (0.0 - 1.0 range for flutter_tts).
  double get speechRate => _speechRate;
  set speechRate(double rate) {
    _speechRate = rate.clamp(0.0, 1.0);
  }

  /// Speak the given text using the device's TTS engine
  Future<void> speak(String text, {String? language}) async {
    if (!_enabled || text.isEmpty) return;

    // Stop any ongoing speech before starting new speech.
    // flutter_tts may silently drop overlapping speak() calls on some
    // platforms, so we must ensure a clean state first.
    await _tts.stop();
    // Allow TTS engine time to fully release after stop
    await Future.delayed(const Duration(milliseconds: 100));

    final lang = language ?? _detectLanguage(text);
    await _tts.setLanguage(lang);
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);

    state = TtsState.playing;
    final result = await _tts.speak(text);
    // flutter_tts returns "1" on success; if it fails, log and reset state
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
        (r >= 0x3040 && r <= 0x30FF)    // Hiragana/Katakana
    );
    return hasCjk ? 'zh-CN' : 'en-US';
  }
}

/// Riverpod provider for TTS service
final ttsServiceProvider = Provider<TtsService>((ref) {
  return TtsService();
});

/// Riverpod provider for TTS enabled state
final ttsEnabledProvider = StateProvider<bool>((ref) => true);
