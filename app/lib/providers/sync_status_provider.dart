// 云端同步状态的 Riverpod 接线。
//
// 🔑 分层同 `sync_provider.dart`：状态模型在纯 Dart（`services/sync_status.dart`）
//    ⇒ 换算逻辑（今天/昨天/N 天前）能被离线断言穷举；本文件只管「持有 + 通知」。
//
// 🔴 **谁来写这个状态**：只有 `sync_provider.dart` 里那个**统一的同步执行入口**
//    —— 三处调用点（登录后 / 登出前 / 进后台）都走它。
//    ⚠️ 判据：**状态只有一个写入方**。若每个调用点各自 `ref.read(...).markXxx()`，
//       迟早在某一条路径上漏写（而「漏写」的表现是图标**永远停在旧状态**，不报错）。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sync_service.dart';
import '../services/sync_status.dart';

class SyncStatusNotifier extends StateNotifier<SyncStatus> {
  SyncStatusNotifier() : super(const SyncStatus());

  /// 同步开始。
  ///
  /// ⚠️ **不清 `lastOkAt`** —— 同步中仍要能告诉用户「上次成功是几点」。
  void begin() {
    state = state.copyWith(phase: SyncPhase.syncing);
  }

  /// 同步成功。
  void finishOk(SyncReport report, {DateTime? now}) {
    state = SyncStatus(
      phase: SyncPhase.ok,
      // 🔑 时间取「**完成时刻**」而不是「开始时刻」：用户问的是「我的数据现在是新的吗」。
      lastOkAt: now ?? DateTime.now(),
      lastError: null,
      lastPushed: report.pushedTotal,
      // ⚠️ 不再写 `report.pulledTotal + report.claimedBooks` ——
      //    `pulledTotal` 已把 `pulledBooks` 与 `claimedBooks` 算进去（2026-10-09 补全）。
      //    留着那个 `+` 会**双计**认领的书。
      //    📌 判据：**补丁要随修法一起撤** —— 否则「洞补好了、补丁还在」⇒ 数值偏大，
      //       而且没人会再想起来它当初是为什么加的。
      lastPulled: report.pulledTotal,
    );
  }

  /// 同步失败（原因**可直接展示**）。
  void finishFailed(String error) {
    state = state.copyWith(phase: SyncPhase.failed, lastError: error);
  }

  /// 本轮**没跑**（前提不满足：未登录 / `user.db` 不可用）。
  ///
  /// 🔴 与 [finishFailed] 分开：这不是故障，**不能**把图标置成失败态，
  ///    也**不能**清掉上次成功时间。回到上一次的状态（若从未同步过 ⇒ `idle`）。
  void finishSkipped() {
    state = state.copyWith(
      phase: state.lastOkAt == null ? SyncPhase.idle : SyncPhase.ok,
    );
  }
}

final syncStatusProvider =
    StateNotifierProvider<SyncStatusNotifier, SyncStatus>((ref) {
  return SyncStatusNotifier();
});
