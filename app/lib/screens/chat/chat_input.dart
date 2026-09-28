import 'package:flutter/material.dart';

/// 聊天输入栏 —— **纯文本输入**。
///
/// # 🔴 2026-09-27：语音输入已移除（不是优化，是解阻）
///
/// 这里原来有一套「按住说话」的语音输入，靠 `dart:js` 注入一段浏览器 JS
/// （`MediaRecorder` + `ScriptProcessor` → 下采样 16k → WAV base64 → `/api/stt/transcribe`）。
///
/// 它有两个问题：
/// 1. 🔴 **阻断原生构建** —— `import 'dart:js'` 在 iOS/Android 上**编译期**不可用，
///    导致 `:app:compileFlutterBuildDebug` 失败。
///    （实测：`flutter build apk --debug` → `BUILD FAILED in 1h 26m 4s`）
/// 2. 🔑 **在 iOS 上原理上不可能工作** —— 它依赖浏览器的 `MediaRecorder`，
///    而 iOS 上没有这个东西。
///
/// 而项目**只做 iOS、不做 web** → 这段代码在目标平台上**从未生效过**。
/// ∴ 删除它**不损失任何现有能力**，只是卸掉一个「永远跑不通、却阻断构建」的包袱。
///
/// ⚠️ 若将来「AI 考核」（v1 预留）需要语音输入，应在 iOS 上用**原生录音插件**实现
/// （如 `record` 包），而不是浏览器 API —— 那是新功能开发，不是恢复旧代码。
/// 📄 详见 `docs/review/android-build-blocker-web-only-2026-09-27.md`
///
/// 🔑 顺带：本类从 `ConsumerStatefulWidget` 降为 `StatelessWidget` ——
///    删掉语音后它**没有任何状态**了（原来唯一的 state 是 `_voiceMode` 等），
///    也没有用 `ref`。留着 Stateful 是空壳。
class ChatInput extends StatelessWidget {
  final TextEditingController textController;
  final bool isWaiting;
  final bool isDeleted;
  final bool isBlocked;
  final VoidCallback onSend;

  const ChatInput({
    super.key,
    required this.textController,
    required this.isWaiting,
    required this.isDeleted,
    this.isBlocked = false,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    if (isDeleted) return const SizedBox.shrink();
    final deco = BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: deco,
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: '输入消息...',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: isBlocked ? null : (_) => onSend(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: (isWaiting || isBlocked) ? null : onSend,
          icon: isWaiting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.send),
        ),
      ]),
    );
  }
}
