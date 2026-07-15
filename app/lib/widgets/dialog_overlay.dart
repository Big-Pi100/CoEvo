import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/dialog_queue_provider.dart';

/// 全局弹窗覆盖层
///
/// 在 MaterialApp.builder 中注入，监听 dialogQueueProvider。
/// 当 active 不为 null 时，调用 showDialog() 显示对应的 builder。
/// dialog 关闭时自动调用 dequeue()。
class DialogOverlay extends ConsumerStatefulWidget {
  final Widget child;

  const DialogOverlay({super.key, required this.child});

  @override
  ConsumerState<DialogOverlay> createState() => _DialogOverlayState();
}

class _DialogOverlayState extends ConsumerState<DialogOverlay>
    with WidgetsBindingObserver {
  bool _dialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 屏幕尺寸变化时不作特殊处理
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DialogQueueState>(dialogQueueProvider, (prev, next) {
      final activeItem = next.active;
      if (activeItem != null && !_dialogVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_dialogVisible) {
            _showDialog(activeItem);
          }
        });
      }
    });

    return widget.child;
  }

  void _showDialog(DialogItem item) {
    if (_dialogVisible || !mounted) return;
    _dialogVisible = true;

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: item.builder,
      ).then((_) {
        _dialogVisible = false;
        if (mounted) {
          ref.read(dialogQueueProvider.notifier).dequeue();
        }
      }).catchError((_) {
        _dialogVisible = false;
        if (mounted) {
          ref.read(dialogQueueProvider.notifier).dequeue();
        }
      });
    } catch (e) {
      _dialogVisible = false;
    }
  }
}
