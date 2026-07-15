import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 弹窗优先级（数值越大越优先）
enum DialogPriority {
  /// 支付/订阅弹窗（最高优先级）
  P0_PAYMENT(4),

  /// 分享营销弹窗
  P1_SHARE(3),

  /// 制卡确认、成就通知、H5 通知
  P2_CP1_CONCEPT(2),
  P2_ACHIEVEMENT(2),
  P2_NOTIFICATION_H5(2),

  /// 复习弹窗（最低优先级）
  P3_REVIEW(1);

  const DialogPriority(this.level);
  final int level;
}

/// 弹窗队列中的单个条目
class DialogItem {
  final String id;
  final DialogPriority priority;
  final WidgetBuilder builder;
  final VoidCallback? onClose;

  const DialogItem({
    required this.id,
    required this.priority,
    required this.builder,
    this.onClose,
  });
}

/// 弹窗队列状态
class DialogQueueState {
  final List<DialogItem> queue;
  final DialogItem? active;

  const DialogQueueState({
    this.queue = const [],
    this.active,
  });

  DialogQueueState copyWith({
    List<DialogItem>? queue,
    DialogItem? active,
    bool clearActive = false,
  }) {
    return DialogQueueState(
      queue: queue ?? this.queue,
      active: clearActive ? null : (active ?? this.active),
    );
  }
}

/// 全局弹窗调度器 Notifier
class DialogQueueNotifier extends Notifier<DialogQueueState> {
  @override
  DialogQueueState build() => const DialogQueueState();

  /// 入队一个弹窗
  ///
  /// 规则：
  /// - 如果 active 为 null → 直接展示
  /// - 如果新项目的 priority 高于当前 active → 抢占（当前 active 入队尾）
  /// - 否则排队
  /// - 对于 P3_REVIEW: 如果已有其他弹窗在队列中 → 不排队直接标记为 defer
  void enqueue(DialogItem item) {
    final state = this.state;
    final active = state.active;

    // P3_REVIEW 特殊处理：如果队列中已有其他弹窗，标记为 defer 不入队
    if (item.priority == DialogPriority.P3_REVIEW && active != null) {
      // 如果已有其他弹窗（非 P3_REVIEW）在展示或排队 → 不排队
      if (state.queue.isNotEmpty || active.priority != DialogPriority.P3_REVIEW) {
        item.onClose?.call();
        return;
      }
    }

    if (active == null) {
      // 无活跃弹窗 → 直接展示
      this.state = state.copyWith(active: item);
      return;
    }

    // 有活跃弹窗
    if (item.priority.level > active.priority.level) {
      // 新项目优先级更高 → 抢占
      this.state = state.copyWith(
        active: item,
        queue: [...state.queue, active],
      );
    } else {
      // 优先级不高于当前 → 排队
      this.state = state.copyWith(
        queue: [...state.queue, item],
      );
    }
  }

  /// 关闭当前弹窗 → 取队列头部下一个显示
  void dequeue() {
    final state = this.state;
    if (state.queue.isEmpty) {
      this.state = state.copyWith(clearActive: true);
      return;
    }
    final next = state.queue.first;
    final remaining = state.queue.length > 1 ? state.queue.sublist(1) : <DialogItem>[];
    this.state = DialogQueueState(
      queue: remaining,
      active: next,
    );
  }

  /// 清空全部（关闭所有弹窗）
  void clear() {
    this.state = const DialogQueueState();
  }

  /// 移除指定 ID 的条目（从队列中移除，不影响 active）
  void removeById(String id) {
    final state = this.state;
    this.state = state.copyWith(
      queue: state.queue.where((item) => item.id != id).toList(),
    );
  }
}

/// 全局弹窗队列 Provider
final dialogQueueProvider =
    NotifierProvider<DialogQueueNotifier, DialogQueueState>(
  DialogQueueNotifier.new,
);
