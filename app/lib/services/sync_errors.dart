/// 同步的**错误类型** —— **纯 Dart · 零 import**。
///
/// # 🔴 为什么必须独立成文件（2026-10-10）
///
/// 这两个类型原先定义在 `api/sync_client.dart` 里，但那个文件**有 Flutter 依赖**
/// （`package:http` / `flutter/foundation`）⇒ 而**捕获**异常的地方是
/// `services/sync_service.dart`，它**必须是纯 Dart**（`scripts/query_verify`
/// 要 import 它做离线断言，一旦引入 Flutter 那套脚本直接编译不过）。
///
/// ⇒ 结果就是：**`SyncUnauthorized` 被定义、被抛出，却永远传不到能处理它的层**
///   （全仓 grep 只有它自己的定义处 + 抛出点，**零消费**）。
///   症状：401 落进通用分支 ⇒ 用户看到的是「同步失败」（暗示重试即可），
///   而实际上**重试永远不会成功**。
///
/// 🔑 判据：**异常类型的定义位置必须与「能捕获它的那一层」的依赖约束相容**。
///   否则它会被迫在层边界上丢失 —— 而且**不报错**（类型还在，只是没人能 import）。
///
/// 📄 真机案例：`docs/review/device-sync-and-profile-failure-2026-10-10.md`
library;

/// 「已登录，但**没有有效订阅**」—— 这是**预期内的状态**，不是故障。
///
/// 上层应据此显示「订阅后可用」而不是「同步失败，请重试」。
class SyncNotSubscribed implements Exception {
  SyncNotSubscribed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `token` 失效（**HTTP 401**）—— 与 [SyncNotSubscribed] 分开，因为**处理方式不同**。
///
/// # 🔴 401 是**终态**，不是「这次没赶上」
///
/// 本项目里 401 的**最常见来源不是密码错**，而是：
/// **同一账号在别的设备上登录** ⇒ 服务端把旧 token 清掉
/// （`enforce_token_limit` / 改密码 / 重置密码）。
///
/// ⇒ **「重试」对它永远无效**（retry 用的还是同一个失效 token）。
///   上层必须把它与「网络超时 / 5xx」**分开**：
///   · 网络类 → 「稍后会自动重试」
///   · 401    → 「**请重新登录**」（唯一有效出口）
///
/// 📄 真机案例：`docs/review/device-sync-and-profile-failure-2026-10-10.md`
class SyncUnauthorized implements Exception {
  SyncUnauthorized(this.message);
  final String message;
  @override
  String toString() => message;
}
