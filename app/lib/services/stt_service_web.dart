import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 语音识别服务 — Web 平台桩实现
///
/// Web 平台使用浏览器 Web Speech API（通过 JS 互操作），
/// 或者直接使用文本输入替代语音。当前版本为占位实现。
class SttService {
  bool _isListening = false;
  String _transcript = '';
  String? _lastError;

  bool get isListening => _isListening;
  bool get isAvailable => false; // Web 暂不可用
  String? get lastError => _lastError;

  Future<void> startRecording() async {
    _lastError = 'Web 平台暂不支持语音输入，请使用文本输入';
    _isListening = false;
  }

  Future<String> stopRecording() async {
    _isListening = false;
    return '';
  }

  void dispose() {}
}

final sttServiceProvider = Provider<SttService>((ref) {
  return SttService();
});
