import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../api/api_config.dart';
import '../../theme/app_theme.dart';

/// 聊天输入栏 — 文本输入 + 语音输入（按住说话，腾讯云 ASR）
class ChatInput extends ConsumerStatefulWidget {
  final TextEditingController textController;
  final bool isWaiting;
  final bool isDeleted;
  final VoidCallback onSend;

  const ChatInput({
    super.key,
    required this.textController,
    required this.isWaiting,
    required this.isDeleted,
    required this.onSend,
  });

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends ConsumerState<ChatInput>
    with SingleTickerProviderStateMixin {
  ColorScheme get _cs => Theme.of(context).colorScheme;

  bool _voiceMode = false;
  bool _isRecording = false;
  bool _isTranscribing = false;

  // 纯 JS 方案：所有录制逻辑在 JS 中执行，Dart 只负责调用
  List<Float32List> _pcmChunks = [];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(_pulseController);
    _initJsRecorder();
  }

  /// 一次性注入 JS 录音模块
  void _initJsRecorder() {
    // ignore: deprecated_member_use
    if (js.context.hasProperty('__coeStart')) return;
    // ignore: deprecated_member_use
    js.context.callMethod('eval', ['''
      window.__coePcm = [];
      window.__coeCtx = null;

      window.__coeStart = function() {
        window.__coePcm = [];
        navigator.mediaDevices.getUserMedia({audio: true}).then(function(stream) {
          var ctx = new (window.AudioContext || window.webkitAudioContext)();
          window.__coeCtx = ctx;
          var source = ctx.createMediaStreamSource(stream);
          var proc = ctx.createScriptProcessor(4096, 1, 1);
          proc.onaudioprocess = function(e) {
            window.__coePcm.push(new Float32Array(e.inputBuffer.getChannelData(0)));
          };
          source.connect(proc);
          proc.connect(ctx.destination);
          window.__coeStream = stream;
          window.__coeProc = proc;
          window.__coeSource = source;
        });
      };

      window.__coeStop = function(callback) {
        if (window.__coeStream) {
          window.__coeStream.getTracks().forEach(function(t) { t.stop(); });
        }
        if (window.__coeCtx) { window.__coeCtx.close(); }
        window.__coeStream = null;
        window.__coeCtx = null;
        window.__coeProc = null;
        window.__coeSource = null;

        // 编码为 WAV base64
        var chunks = window.__coePcm;
        if (chunks.length === 0) { callback(''); return; }

        var totalLen = 0;
        for (var i = 0; i < chunks.length; i++) totalLen += chunks[i].length;
        var all = new Float32Array(totalLen);
        var off = 0;
        for (var i = 0; i < chunks.length; i++) { all.set(chunks[i], off); off += chunks[i].length; }

        // 下采样到 16000Hz（16k_zh）减少 payload
        var sr = 44100, targetSr = 16000;
        var step = sr / targetSr; // ~2.756
        var downLen = Math.floor(all.length / step);
        var down = new Float32Array(downLen);
        for (var i = 0; i < downLen; i++) {
          var src = Math.floor(i * step);
          down[i] = all[src];
        }

        var pcm16 = new Int16Array(down.length);
        for (var i = 0; i < down.length; i++) {
          pcm16[i] = Math.max(-32768, Math.min(32767, Math.round(down[i] * 32767)));
        }

        sr = targetSr;
        var ch = 1, bps = 16;
        var ds = pcm16.length * 2;
        var buf = new ArrayBuffer(44 + ds);
        var v = new DataView(buf);
        function wS(a, s) { for (var i = 0; i < s.length; i++) v.setUint8(a + i, s.charCodeAt(i)); }
        v.setUint32(4, 36 + ds, true);
        wS(0, 'RIFF'); wS(8, 'WAVE'); wS(12, 'fmt ');
        v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, ch, true);
        v.setUint32(24, sr, true); v.setUint32(28, sr * ch * 2, true);
        v.setUint16(32, ch * 2, true); v.setUint16(34, bps, true);
        wS(36, 'data'); v.setUint32(40, ds, true);
        for (var i = 0; i < pcm16.length; i++) v.setInt16(44 + i * 2, pcm16[i], true);

        var bytes = new Uint8Array(buf);
        var bin = '';
        for (var i = 0; i < bytes.byteLength; i++) bin += String.fromCharCode(bytes[i]);
        callback(btoa(bin));
      };
    ''']);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _cleanup();
    super.dispose();
  }

  void _cleanup() {
    try {
      // ignore: deprecated_member_use
      js.context.callMethod('__coeStop', [_nullFunc]);
    } catch (_) {}
  }

  void _nullFunc() {}

  void _enterVoiceMode() => setState(() => _voiceMode = true);

  void _exitVoiceMode() {
    _cleanup();
    setState(() {
      _voiceMode = false;
      _isRecording = false;
    });
  }

  Future<void> _startRecording() async {
    try {
      // ignore: deprecated_member_use
      js.context.callMethod('__coeStart');
      setState(() => _isRecording = true);
    } catch (e) {
      _showError('无法启动录音: $e');
      _exitVoiceMode();
    }
  }

  void _stopRecording() {
    setState(() => _isRecording = false);
    setState(() => _isTranscribing = true);

    // 通过回调获取 WAV base64
    // ignore: deprecated_member_use
    final callback = js.JsFunction.withThis((self, b64) {
      if (mounted) {
        _sendBase64(b64 as String);
      }
    });
    try {
      // ignore: deprecated_member_use
      js.context.callMethod('__coeStop', [callback]);
    } catch (e) {
      _showError('录音停止失败: $e');
      _exitVoiceMode();
    }
  }

  Future<void> _sendBase64(String b64) async {
    if (b64.isEmpty) { _exitVoiceMode(); return; }

    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/stt/transcribe'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'audio': b64, 'format': 'wav', 'engine': '16k_zh'}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 && mounted) {
        final d = jsonDecode(resp.body) as Map<String, dynamic>;
        final text = d['text'] as String? ?? '';
        if (text.isNotEmpty) {
          widget.textController.text = text;
          widget.textController.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
        }
        _exitVoiceMode();
      } else if (mounted) { _showError('语音识别失败: ${resp.body}'); _exitVoiceMode(); }
    } catch (e) { _showError('语音识别错误: $e'); _exitVoiceMode(); }
    finally { if (mounted) setState(() => _isTranscribing = false); }
  }

  void _showError(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ... build methods ...
  @override
  Widget build(BuildContext context) {
    if (widget.isDeleted) return const SizedBox.shrink();
    final deco = BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)));

    if (_voiceMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: deco,
        child: Row(children: [
          IconButton(
            icon: _isTranscribing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.keyboard, size: 22),
            onPressed: (_isRecording || _isTranscribing) ? null : _exitVoiceMode,
            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onLongPressStart: _isTranscribing ? null : (_) => _startRecording(),
              onLongPressEnd: _isTranscribing ? null : (_) => _stopRecording(),
              onLongPressCancel: _stopRecording,
              child: AnimatedBuilder(
                animation: _pulseAnimation, builder: (_, child) => child!,
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isRecording ? Colors.red.withAlpha(20) : _cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _isRecording ? Colors.red.withAlpha(100) : _cs.outline.withAlpha(60)),
                  ),
                  child: Center(
                    child: _isTranscribing
                        ? const Row(mainAxisSize: MainAxisSize.min, children: [
                            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.grey)),
                            SizedBox(width: 8), Text('识别中...', style: TextStyle(fontSize: 15)),
                          ])
                        : _isRecording
                            ? const Row(mainAxisSize: MainAxisSize.min, children: [
                                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.red)),
                                SizedBox(width: 8), Text('松手 结束', style: TextStyle(color: Colors.red, fontSize: 15)),
                              ])
                            : const Text('按住 说话', style: TextStyle(fontSize: 15)),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: deco,
      child: Row(children: [
        if (!widget.isWaiting)
          IconButton(
            icon: const Icon(Icons.mic, size: 22),
            onPressed: _enterVoiceMode, padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: widget.textController,
            decoration: const InputDecoration(
              hintText: '输入消息...', isDense: true, border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            textInputAction: TextInputAction.send, onSubmitted: (_) => widget.onSend(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: widget.isWaiting ? null : widget.onSend,
          icon: widget.isWaiting
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send),
        ),
      ]),
    );
  }
}
