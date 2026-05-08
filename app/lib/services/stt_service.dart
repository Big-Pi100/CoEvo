import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Speech-to-text using the device's native recognizer.
///
/// Works on iOS (SFSpeechRecognizer), Android (SpeechRecognizer),
/// and Web (Web Speech API). No model files needed.
class SttService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _initialized = false;
  String _transcript = '';

  bool get isListening => _isListening;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = await _speech.initialize(
      onStatus: (status) {},
      onError: (error) {},
    );
  }

  Future<void> startRecording() async {
    await initialize();
    if (!_speech.isAvailable) return;

    _transcript = '';
    _isListening = true;
    await _speech.listen(
      onResult: (result) {
        _transcript = result.recognizedWords;
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
      ),
      localeId: 'en_US',
    );
  }

  Future<String> stopRecording() async {
    if (!_isListening) return _transcript;
    _isListening = false;
    await _speech.stop();
    return _transcript.trim();
  }

  void dispose() {
    if (_isListening) {
      _speech.stop();
      _isListening = false;
    }
  }
}

/// Riverpod provider for STT service
final sttServiceProvider = Provider<SttService>((ref) {
  return SttService();
});
