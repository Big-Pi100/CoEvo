/// Sherpa-ONNX TTS 后端
///
/// 替代系统 TTS，使用离线神经网络合成语音。
/// 目前仅 Web 平台走 WASM，原生平台通过 FFI。
///
/// 模型文件（~125MB）首次使用从 ModelScope 下载后缓存。

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:audioplayers/audioplayers.dart';

/// Sherpa TTS 后端的状态
enum SherpaTtsState {
  uninitialized,
  downloading,
  ready,
  error,
}

/// Sherpa TTS 后端
class SherpaTtsBackend {
  SherpaTtsState _state = SherpaTtsState.uninitialized;
  String? _errorMessage;
  sherpa_onnx.OfflineTts? _tts;
  final AudioPlayer _player = AudioPlayer();

  SherpaTtsState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isReady => _state == SherpaTtsState.ready && _tts != null;

  /// 模型文件 URL（ModelScope 国内可访问）
  static const String _modelBaseUrl =
      'https://modelscope.cn/models/dengcunqin/matcha_tts_zh_en_20251010/resolve/master';

  static const String _vocoderUrl =
      'https://modelscope.cn/models/dengcunqin/matcha_tts_zh_en_20251010/resolve/master/vocos-16khz-univ.onnx';

  /// 返回模型文件的基础目录
  static Future<String> get _modelDir async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/sherpa-tts-models';
  }

  /// 检查模型是否已下载
  Future<bool> isModelDownloaded() async {
    final dir = await _modelDir;
    return File('$dir/model-steps-3.onnx').existsSync() &&
        File('$dir/vocos-16khz-univ.onnx').existsSync() &&
        File('$dir/tokens.txt').existsSync() &&
        File('$dir/lexicon.txt').existsSync();
  }

  /// 下载模型文件（首次使用）
  Future<void> downloadModel(void Function(double progress)? onProgress) async {
    _state = SherpaTtsState.downloading;
    _errorMessage = null;

    final dir = await _modelDir;
    await Directory(dir).create(recursive: true);

    // 暂时先用 http 下载，后续可考虑并发下载 + 断点续传
    final files = [
      ('model-steps-3.onnx', '$_modelBaseUrl/model-steps-3.onnx', 73 * 1024 * 1024),
      ('vocos-16khz-univ.onnx', _vocoderUrl, 52 * 1024 * 1024),
      ('tokens.txt', 'https://hf-mirror.com/csukuangfj/matcha-icefall-zh-en/resolve/main/tokens.txt', 21 * 1024),
      ('lexicon.txt', 'https://hf-mirror.com/csukuangfj/matcha-icefall-zh-en/resolve/main/lexicon.txt', 1400 * 1024),
    ];

    int completed = 0;
    final totalFiles = files.length;

    for (final (filename, url, _) in files) {
      final path = '$dir/$filename';
      if (File(path).existsSync() && File(path).lengthSync() > 1024) {
        completed++;
        onProgress?.call(completed / totalFiles);
        continue;
      }
      try {
        debugPrint('[SherpaTTS] 下载: $filename');
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await File(path).writeAsBytes(response.bodyBytes);
          debugPrint('[SherpaTTS] 下载完成: $filename (${response.bodyBytes.length} bytes)');
        } else {
          throw Exception('HTTP ${response.statusCode}: $url');
        }
      } catch (e) {
        _state = SherpaTtsState.error;
        _errorMessage = '下载失败 $filename: $e';
        return;
      }
      completed++;
      onProgress?.call(completed / totalFiles);
    }

    _state = SherpaTtsState.ready;
    debugPrint('[SherpaTTS] 所有模型下载完成');
    // 自动初始化 TTS 引擎
    await initTts();
  }

  /// 初始化 TTS 引擎（加载模型到内存）
  Future<bool> initTts() async {
    if (_tts != null) return true;
    try {
      final dir = await _modelDir;
      sherpa_onnx.initBindings();
      _tts = sherpa_onnx.OfflineTts(
        sherpa_onnx.OfflineTtsConfig(
          model: sherpa_onnx.OfflineTtsModelConfig(
            matcha: sherpa_onnx.OfflineTtsMatchaModelConfig(
              acousticModel: '$dir/model-steps-3.onnx',
              vocoder: '$dir/vocos-16khz-univ.onnx',
              tokens: '$dir/tokens.txt',
              lexicon: '$dir/lexicon.txt',
              dataDir: '', // espeak-ng data（可选，无则用 lexicon）
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        ),
      );
      debugPrint('[SherpaTTS] 引擎初始化完成');
      return true;
    } catch (e) {
      _state = SherpaTtsState.error;
      _errorMessage = 'TTS 初始化失败: $e';
      debugPrint('[SherpaTTS] $_errorMessage');
      return false;
    }
  }

  /// 合成语音并播放
  Future<bool> speak(String text) async {
    if (!isReady) return false;
    if (_tts == null && !await initTts()) return false;

    try {
      final audio = _tts!.generate(text: text, sid: 0, speed: 1.0);
      if (audio.samples.isEmpty) {
        debugPrint('[SherpaTTS] 合成结果为空');
        return false;
      }

      // 保存为临时 WAV 文件
      final dir = await _modelDir;
      final wavPath = '$dir/sherpa_output.wav';
      sherpa_onnx.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      // 播放
      await _player.play(DeviceFileSource(wavPath));
      return true;
    } catch (e) {
      debugPrint('[SherpaTTS] 播放失败: $e');
      return false;
    }
  }

  /// 释放资源
  void dispose() {
    _tts?.free();
    _tts = null;
    _player.dispose();
  }
}
