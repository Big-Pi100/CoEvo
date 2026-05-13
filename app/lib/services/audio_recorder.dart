import 'dart:async';
import 'package:flutter/services.dart';

/// 原生音频录制 — 通过 MethodChannel 调用 Android MediaRecorder
class NativeAudioRecorder {
  static const _channel = MethodChannel('coevo/audio_recorder');
  bool _isRecording = false;
  String? _filePath;

  bool get isRecording => _isRecording;

  /// 检查是否有录音权限
  Future<bool> hasPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求录音权限
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 开始录音，返回录音文件路径
  Future<String> start(String filePath) async {
    // 防重入：如果前一轮录音未正确停止，先强制停止
    if (_isRecording) {
      try { await _channel.invokeMethod('stopRecording'); } catch (_) {}
      _isRecording = false;
    }
    _filePath = filePath;
    try {
      await _channel.invokeMethod('startRecording', {'path': filePath});
      _isRecording = true;
      return filePath;
    } catch (e) {
      _isRecording = false;
      rethrow;
    }
  }

  /// 停止录音，返回录音文件路径
  Future<String> stop() async {
    if (!_isRecording) return _filePath ?? '';
    try {
      await _channel.invokeMethod('stopRecording');
    } catch (_) {}
    _isRecording = false;
    return _filePath ?? '';
  }
}
