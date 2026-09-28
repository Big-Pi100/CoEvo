// 聚合页（词根族 / 词源族）的数据层。
//
// 🔑 为什么单独一个 provider 而不是页面里 `initState` 查：
//    同 `cardBundleProvider` —— 页面里手写异步要自己管「已取消 / 重建重跑」，
//    而 provider 有缓存与生命周期（`autoDispose` 在离开页面时清掉）。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/word_query_service.dart';
import 'word_db_provider.dart';

/// 一个聚合页的全部内容（标题 + 成员 + 分拆法）。
///
/// # ⚠️ 词库未就绪时**返回 `null`**（不是抛）
/// 调用方据此渲染「这一页暂时打不开」。
/// 🔑 与复习列表的释义处理**取向一致**：跨库依赖不该让页面崩，
///    但**必须给准确的话**（不是空白、不是假装「没有这个族」）。
///
/// # 🔑 为什么 `pageId` 作为 family 参数
/// 每个族的成员不同 → 分开缓存。且同一页反复进出（卡片 → 族页 → 返回 → 再进）
/// 命中缓存，不必重查。
final aggregatePageProvider =
    FutureProvider.autoDispose.family<AggregatePage?, int>((ref, pageId) async {
  // 词库首次落盘 31.4 MB（0.5–2 s）→ `watch` 它，就绪后自动重算
  final load = ref.watch(wordQueryProvider).valueOrNull;
  if (load is! WordDbReady) return null;

  try {
    return await load.service.aggregatePageOf(pageId);
  } catch (e, st) {
    // 🔑 这里可以记日志：本层在 Flutter 侧（service 层才是纯 Dart 不能记）
    debugPrint('[aggregate] 读取失败 pageId=$pageId：$e\n$st');
    return null;
  }
});
