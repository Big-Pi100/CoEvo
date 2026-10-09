/// 端侧翻译的**平台通道客户端**（iOS `Translation.framework`）。
///
/// 分层同 `OpenWithHandler`：本文件只做**通道**，判断与分句在纯 Dart 层
/// （`services/ondevice_translate.dart`）。
///
/// # 🔴 只能真机验证
/// Apple 的翻译框架**在模拟器上不工作**（官方明确）⇒ 本文件的所有路径都必须在
/// 真机上过一遍（见 `docs/review/ondevice-translation-plan-2026-10-09.md` 的真机清单）。
///
/// # 🔑 一切失败都「吞成不可用/返回 null」
/// 端侧翻译是**加速层**：它坏掉不该让翻译整个不可用 —— 回落到服务端即可。
/// ⚠️ 但**不能吞掉「成功」**：译文为空、条数不匹配都算失败（否则会渲染出
/// 「半截对照」或空行，那比回落更糟）。
library;

import 'package:flutter/services.dart';

import '../services/ondevice_translate.dart';

class OnDeviceTranslateClient {
  /// [channel] 可注入 —— 让测试不用真的连平台通道（同 `OpenWithHandler` 的做法）。
  OnDeviceTranslateClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 `ios/Runner/OnDeviceTranslator.swift` 里注册的名字**必须一致**。
  static const String channelName = 'coevo/ondevice_translate';

  final MethodChannel _channel;

  /// 查可用性。
  Future<OnDeviceTranslateStatus> status({
    String source = kOnDeviceSourceLang,
    String target = kOnDeviceTargetLang,
  }) async {
    try {
      final r = await _channel.invokeMethod<String>('status', {
        'source': source,
        'target': target,
      });
      return switch (r) {
        'installed' => OnDeviceTranslateStatus.installed,
        'supported' => OnDeviceTranslateStatus.supported,
        'unsupported' => OnDeviceTranslateStatus.unsupported,
        // 认不出来的值一律当「不可用」—— 宁可回落服务端，也不要猜
        _ => OnDeviceTranslateStatus.unavailable,
      };
    } catch (_) {
      // 通道不存在（iOS < 18 / 安卓 / 桥接没注册）⇒ 不可用，**不抛出**
      return OnDeviceTranslateStatus.unavailable;
    }
  }

  /// 批量翻译。
  ///
  /// 返回 `null` = **失败**（由调用方回落服务端）。以下情况都算失败：
  /// · 平台抛异常（session 建不起来 / 系统校验不过 / 用户取消下载）
  /// · 返回条数与请求不一致（🔑 错位会把译文贴到别的句子上 —— 比失败更糟）
  /// · 任何一条译文为空
  Future<List<String>?> translate(
    List<String> texts, {
    String source = kOnDeviceSourceLang,
    String target = kOnDeviceTargetLang,
  }) async {
    if (texts.isEmpty) return const [];
    try {
      final r = await _channel.invokeMethod<List<Object?>>('translate', {
        'texts': texts,
        'source': source,
        'target': target,
      });
      if (r == null || r.length != texts.length) return null;
      final out = <String>[];
      for (final s in r) {
        if (s is! String || s.trim().isEmpty) return null;
        out.add(s);
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}
