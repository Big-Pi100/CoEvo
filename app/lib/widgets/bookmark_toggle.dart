/// 收藏切换 + 轻提示 —— **信息流与收藏清单共用的同一个交互**。
///
/// # 为什么抽成一个函数
/// 设计稿 §03 ② 明写「**同一套卡片组件，只是筛选过**」，§1.6 又规定了 toast 的
/// **文案与时长**（「已收藏 · 可在「收藏」里重读」，1.5 秒消失）。
/// 两处都要做同一件事 → **文案与时长只该定义一次**。
///
/// 🔑 这与 `BookmarkButton` 被抽出来是**同一条理由**：
/// 设计稿里是同一个类 → 实现里就该是一个东西，而不是两处各画一遍。
/// （否则改一次文案要记得改两处，漏一处就出现「同一个 App 两种提示」。）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/bookmark_provider.dart';

/// 切换收藏并弹轻提示。
///
/// 🔑 **返回 `null`（仓储未就绪 / 写入失败）时不弹提示** ——
/// 那表示「这次操作**什么都没发生**」。为一次没执行的操作弹 toast 会误导用户
/// （「提示说成功了，但刷新后又没了」）。
///
/// ⚠️ 用 `context.mounted` 而不是 `State.mounted`：本函数是**顶层函数**，
/// 没有 `State`；动画/异步后 context 可能已失效。
Future<void> toggleBookmarkWithToast(
  BuildContext context,
  WidgetRef ref,
  int contentId,
) async {
  final on = await ref.read(bookmarkProvider.notifier).toggle(contentId);
  if (on == null || !context.mounted) return;

  ScaffoldMessenger.of(context)
    // 连点两张卡时不排队，直接换成最新的那条
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(on ? '已收藏 · 可在「收藏」里重读' : '已取消收藏'),
        // 设计稿 §1.6：「1.5 秒消失（原文：「不做常驻标签」）」
        duration: const Duration(milliseconds: 1500),
      ),
    );
}
