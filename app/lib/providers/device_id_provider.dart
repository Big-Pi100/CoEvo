// device_id 的 Riverpod 接线 —— 把真实的 `SharedPreferences` 接进纯逻辑层。
//
// 🔑 分层理由：`services/device_id.dart` **零 Flutter 依赖**（IO 用回调注入）→
//    生成/校验/单飞都能在纯 Dart 断言脚本里跑；本文件是唯一 import Flutter 的地方。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_id.dart';

/// 本机匿名设备标识。
///
/// - `ref.read(deviceIdProvider.future)` → `String`（抛 [DeviceIdUnavailable] = 读写成失败）
/// - **调用方必须容错**：它是**统计信号**，不是功能前提 →
///   取不到就降级（制卡不传 `device_id`、复习日志沿用 `''`），**不要**中断主流程。
///
/// ⚠️ **不要用 `ref.watch`** 订阅它 —— 它在本机生命周期内恒定不变，
///    订阅只会让 Consumer 多做一次无意义的重建。
final deviceIdProvider = FutureProvider<String>((ref) {
  return DeviceId.ensure(
    read: (key) async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    },
    write: (key, value) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    },
  );
});

/// 给 **`WidgetRef`**（widget 层）用的「取不到就 `null`」版本。
Future<String?> deviceIdOrNull(WidgetRef ref) =>
    _softRead(() => ref.read(deviceIdProvider.future));

/// 给 **`Ref`**（provider 层）用的同上。
///
/// ⚠️ `WidgetRef` 与 `Ref` **没有公共父类** → 只能有两个入口。
///    实现共用 `_softRead`，降级逻辑仍只有一处。
Future<String?> deviceIdOrNullFrom(Ref ref) =>
    _softRead(() => ref.read(deviceIdProvider.future));

/// 🔑 把「拿不到就降级」收成一处 —— 避免两个调用方各写一遍 `try/catch`，
///    将来改一处漏一处。
Future<String?> _softRead(Future<String> Function() load) async {
  try {
    return await load();
  } catch (e) {
    // 必须留日志：否则「去重统计静默失效」这种状态永远不会被发现
    debugPrint('[device_id] 不可用 → 本次降级（不传 device_id）: $e');
    return null;
  }
}
