import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../api/api_config.dart';
import 'audio_recorder.dart';

/// 语音识别服务 — Android原生MediaRecorder录音 + VPS转讯飞识别
///
/// 录音使用 Android 原生 MediaRecorder（微信同款），兼容所有国产手机。
/// 录音文件上传到 VPS，由后端转发到科大讯飞语音听写 API。
class SttService {
  final NativeAudioRecorder _recorder = NativeAudioRecorder();
  String? _audioPath;
  bool _isListening = false;
  String _transcript = '';
  String? _lastError;
  DateTime? _recordStartTime;

  bool get isListening => _isListening;
  bool get isAvailable => true;
  String? get lastError => _lastError;

  Future<void> startRecording() async {
    _lastError = null;
    _transcript = '';
    // 强制重置录音器状态（防上轮失败残留）
    try { await _recorder.stop(); } catch (_) {}

    try {
      // 先检查并请求权限
      if (!await _recorder.hasPermission()) {
        final granted = await _recorder.requestPermission();
        if (!granted) {
          _lastError = '需要麦克风权限';
          return;
        }
      }

      final dir = await getTemporaryDirectory();
      _audioPath = '${dir.path}/coevo_stt_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(_audioPath!);
      _recordStartTime = DateTime.now();
      _isListening = true;
    } catch (e) {
      _lastError = '启动录音失败: $e';
      _isListening = false;
    }
  }

  Future<String> stopRecording() async {
    if (_recordStartTime != null) {
      final elapsed = DateTime.now().difference(_recordStartTime!).abs();
      if (elapsed.inMilliseconds < 1000) {
        _lastError = '录音时间太短';
        _isListening = false;
        _cleanup();
        return '';
      }
    }

    if (!_isListening) {
      _cleanup();
      return '';
    }

    _isListening = false;

    try {
      await _recorder.stop();
    } catch (e) {
      _lastError = '停止录音失败: $e';
      _cleanup();
      return '';
    }

    if (_audioPath == null || !File(_audioPath!).existsSync()) {
      _lastError = '录音文件为空';
      _cleanup();
      return '';
    }

    // 发送到 VPS 进行语音识别
    try {
      final bytes = await File(_audioPath!).readAsBytes();

      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/stt'),
        headers: {'Content-Type': 'application/octet-stream'},
        body: bytes,
      ).timeout(const Duration(seconds: 30));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        // 优先显示后端返回的错误
        if (data.containsKey('error')) {
          _lastError = data['error'] as String? ?? '识别失败';
        } else {
          _transcript = data['text'] as String? ?? '';
          if (_transcript.isEmpty) {
            final debug = data['_debug'] as String?;
            if (debug != null && debug.isNotEmpty) {
              _lastError = '识别结果为空 (后端: ${debug.substring(0, debug.length.clamp(0, 200))})';
            } else {
              _lastError = '未能识别到语音';
            }
          }
        }
      } else {
        _lastError = '识别失败 (${resp.statusCode})';
      }
    } catch (e) {
      _lastError = '识别出错: $e';
    }

    _cleanup();
    return _transcript.trim();
  }

  void _cleanup() {
    if (_audioPath != null) {
      try { File(_audioPath!).delete(); } catch (_) {}
      _audioPath = null;
    }
  }

  void dispose() {
    _cleanup();
  }
}

final sttServiceProvider = Provider<SttService>((ref) {
  return SttService();
});
