/// 「正在同步」的**转圈弹窗** —— 白哥 2026-10-10 要求：
/// 「同步在 UI 上没有显示，可以用**弹窗转圈**的方式显示同步进行中的状态」。
///
/// # 🔑 只用于**用户主动触发**的同步
///
/// | 触发方式 | 反馈形式 |
/// |---|---|
/// | 点云朵 / 失败重试（**手动**）| ✅ 本弹窗（转圈）|
/// | 登录后 / 进后台 / 回前台 / 本地改动后（**自动**）| ❌ **不弹窗** —— 自动同步不该打断用户 |
///
/// ⇒ 自动同步的可见性由**云朵图标 / 胶囊**承担（`syncCloudVisual` 的 `syncing` 态
///    + `syncChipLabel` 的「正在同步…」）。两条路都从**同一个** [SyncStatus] 派生，
///    不存在「弹窗说在同步、图标说已完成」这种两套来源的分歧。
///
/// # ⚠️ 三条防卡屏（本项目踩过「弹窗把界面卡住」）
///
/// 1. **超时兜底**：无论状态回调是否回来，最多显示 [_kTimeout]。
///    弹窗的关闭**依赖状态变化**，而状态是异步的 ⇒ 没有兜底就是一个
///    「回调没来就永久卡屏」的结构（比「没显示同步」严重得多）。
/// 2. **不在 `build` 里直接 `pop`** —— 构建期改导航栈会抛异常，排到下一帧。
/// 3. **先启动同步、后弹窗** —— 保证「转圈出现」时请求**已经在路上**，
///    不会出现「转圈转了半天、其实还没发请求」的空窗。
///    📌 判据：**时序上「让被观察者先动」优于「先摆好观察者」**（同族：等条件成立 > 等猜的时长）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sync_provider.dart';
import '../providers/sync_status_provider.dart';
import '../services/sync_status.dart';
import '../theme/tokens_ext.dart';

/// 弹窗的**最长显示时长**（超时即关 —— 见文件头「防卡屏 1」）。
const Duration _kTimeout = Duration(seconds: 8);

/// **手动**触发一次同步，并显示「正在同步」转圈弹窗（结束自动关闭）。
///
/// 调用点：云朵图标 / 胶囊的点击、失败后的「重试」。
/// ⚠️ **不要**在自动时机（进后台 / 回前台 / 登录后 / 本地改动后）调用它 ——
///    那些时机不该弹窗打断用户。
Future<void> syncWithProgressDialog(BuildContext context, WidgetRef ref) async {
  // 🔑 提前取 messenger（判据：一旦下面出现 `await`，后取的 `context` 可能已失效）
  final messenger = ScaffoldMessenger.of(context);

  // 🔑 先启动、后弹窗（见文件头「防卡屏 3」）
  final future = syncNowFromUi(ref);

  if (context.mounted) {
    // ⚠️ 不 await：它的生命周期由弹窗自己（监听状态 + 超时）管理。
    //    这里 await 会一直阻塞到弹窗关闭 —— 而那正是我们要等的 `future` 之后。
    unawaited(showDialog<void>(
      context: context,
      // 🔴 不可点击遮罩关闭：同步是**正在进行**的操作，误触关闭会让用户
      //    以为「取消了」，而其实请求还在跑（本项目判据：**别给用户假的控制感**）。
      barrierDismissible: false,
      builder: (_) => const SyncProgressDialog(),
    ));
  }

  await future;

  // 结果提示（弹窗此时已按状态自行关闭）。
  // ⚠️ 用**提前取好**的 messenger，而不是 `ScaffoldMessenger.of(context)` ——
  //    用户可能已离开触发它的页面。
  final s = ref.read(syncStatusProvider);
  final msg = syncStatusSummary(s, DateTime.now());
  if (msg != null) {
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 「正在同步」的转圈弹窗体（**自身监听状态**，同步结束即关）。
class SyncProgressDialog extends ConsumerStatefulWidget {
  const SyncProgressDialog({super.key});

  @override
  ConsumerState<SyncProgressDialog> createState() => _SyncProgressDialogState();
}

class _SyncProgressDialogState extends ConsumerState<SyncProgressDialog> {
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // 🔴 超时兜底（文件头「防卡屏 1」）
    _timeout = Timer(_kTimeout, _closeIfPossible);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  /// 关闭弹窗 —— 幂等（多次调用只关一次；`canPop` 兜住「已被关掉」的情形）。
  void _closeIfPossible() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(syncStatusProvider);
    // 🔑 同步已结束 ⇒ **下一帧**关闭（不在 build 里直接 pop，见文件头「防卡屏 2」）。
    //    ⚠️ 每次 build 都注册一次没关系：`_closeIfPossible` 幂等。
    if (s.phase != SyncPhase.syncing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeIfPossible());
    }

    final t = CoEvoTokensExt.of(context);
    return Dialog(
      backgroundColor: Color(t.page.argb32),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 16),
            // 文案与胶囊**同源**（`syncChipLabel` 的 `syncing` 分支）——
            // 避免「弹窗」与「胶囊」各写一句、将来改一处漏一处。
            Text(
              syncChipLabel(s, DateTime.now()),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
