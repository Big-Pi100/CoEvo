// 兴趣筛选的 Riverpod 接线 —— 把「选择集合」接到 `SharedPreferences`。
//
// 🔑 分层同 `device_id_provider`：`services/interest_selection.dart` **零依赖**
//    ⇒ 归一化/排序/相等性可在纯 Dart 断言脚本里跑（本机可验证，已进 CI）；
//    本文件是唯一碰 Flutter 与存储的地方。
//
// # 为什么是 `AsyncNotifier` 而不是 `FutureProvider`
// 兴趣是**可变的**（用户会来回勾）。`FutureProvider` 只能读一次；
// 变更需要「改状态 + 持久化」，那是 notifier 的职责。
//
// # 🔴 降级原则（同 `device_id`）
// 读失败 ⇒ **降级为「全部」**，绝不因为「偏好读不出来」而挡住信息流。
// 本项目判据：**易失败的依赖不要放在渲染的前置链上**。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/interest_selection.dart';

/// 持久化键（**读写都用这一个常量** —— 两处各写一份字面量必然漂移）。
const String kInterestPrefsKey = 'interest_categories';

/// 用户勾选的兴趣分类（`AsyncValue` 包装）。
///
/// ⚠️ 读取方**不要**直接 `.when` 到 loading 就空白：
///    `valueOrNull ?? InterestSelection.none` 才是正确姿势（见 [interestKeyOf]）。
final interestProvider =
    AsyncNotifierProvider<InterestNotifier, InterestSelection>(
        InterestNotifier.new);

/// 🔑 给渲染层用的「一个表达式拿到 family key」——
///    把「未加载完 / 读失败 / 有值」三种情况收敛成**同一个默认值**（= 全部）。
///
/// 为什么不在这里等 `future`：等它会**把本地偏好的读取压到首屏关键路径上**。
/// 而 `SharedPreferences` 首次 `getInstance()` 之后是内存读 ⇒ 毫秒级，
/// 未加载完时用「全部」渲染，加载完若**确实有筛选**再切（同一次会话里只发生一次）。
///
/// ⚠️ 代价（如实记录）：已设兴趣的用户，首帧会以「全部」发起一次请求，
///    prefs 就绪后切换 key ⇒ 可能**多发一次请求**。
///    ⇒ 想彻底消除，需要在 `main()` 里预载 prefs 并用 `overrideWithValue` 注入
///      （动启动路径，本轮不做 —— 见报告「已知取舍」）。
String interestKeyOf(InterestSelection? sel) =>
    (sel ?? InterestSelection.none).normalizedKey;

class InterestNotifier extends AsyncNotifier<InterestSelection> {
  @override
  Future<InterestSelection> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return InterestSelection.parse(prefs.getString(kInterestPrefsKey));
    } catch (e) {
      // 读不出来 ⇒ 降级「全部」（**不阻塞信息流**），但**必须留日志** ——
      // 否则「偏好静默失效」永远不会被发现（同 `device_id` 的判据）。
      debugPrint('[interest] 读取失败 → 降级为「全部」: $e');
      return InterestSelection.none;
    }
  }

  /// 勾选 / 取消勾选某一类。
  Future<void> toggle(String key) async {
    final cur = state.valueOrNull ?? InterestSelection.none;
    await _apply(cur.toggled(key));
  }

  /// 清空 = 回到「全部」（界面的「清除」出口）。
  Future<void> clear() async => _apply(InterestSelection.none);

  /// 🔑 先更新 UI（本地计算，无需等待），再异步落盘。
  ///
  /// 顺序不能反：`setString` 是 IO，等它回来再更新会让 pill 有明显延迟感。
  /// ⚠️ 反过来（先改内存后落盘）的代价：落盘失败时**本次生效、重启丢失** ——
  ///    这个取舍是有意的（用户当次操作必须立刻有反馈），所以失败**必须留日志**。
  Future<void> _apply(InterestSelection next) async {
    state = AsyncData(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(kInterestPrefsKey, next.normalizedKey);
      if (!ok) {
        debugPrint('[interest] 写入返回 false —— 本次生效，重启后可能丢失');
      }
    } catch (e) {
      debugPrint('[interest] 写入失败（本次生效，重启后可能丢失）: $e');
    }
  }
}
