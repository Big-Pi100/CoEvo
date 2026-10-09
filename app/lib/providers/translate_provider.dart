// 翻译的 Riverpod 接线 —— 把「真实的 token / user.db / http」接进纯逻辑层。
//
// # 🔑 编排只有一条：**先查缓存 → 未命中才调接口 → 成功才写缓存**
//
// 这条顺序不能乱：
// · 缓存命中时**根本不调接口** ⇒ 不花钱（这正是端侧缓存存在的意义）
// · 失败 / 额度用尽时**不写缓存** ⇒ 否则会把一次失败固化下来，
//   之后每次都在同一个句子上"命中"一个坏结果（同 `llm_card` 的「合规不过不写缓存」）。
//
// # ⚠️ 缓存命中时没有额度信息（如实标注）
//
// 不调接口 ⇒ 服务端不会回 `quota`。此时 `TranslateReady.used` 传 **-1**（哨兵值），
// 渲染层据此**不显示额度行**。
// 🔑 用一个不可能的负数表达"未知"，比「传 0」好：0 是**合法的**（本月还没用过），
//    两者混同会让用户看到"本月已用 0 次"这种假信息。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../api/ondevice_translate_client.dart';
import '../api/translate_client.dart';
import '../services/translation_cache.dart';
import '../services/translation_service.dart';
import 'auth_provider.dart';
import 'user_db_provider.dart';

/// 🔑 客户端由 provider 持有**一个**实例（内部有 `http.Client` 连接池）——
///    每次 new 一个会各开一套连接且没人 close（同 `generate_card_provider` 的理由）。
final translateClientProvider = Provider<TranslateClient>((ref) {
  final client = TranslateClient();
  ref.onDispose(client.dispose);
  return client;
});

/// 🆕 端侧翻译客户端（iOS 18+ 的 `Translation.framework`）。
///
/// 🔑 **无状态、无需 dispose**（不像 `TranslateClient` 持有 http 连接池）——
///    它只是平台通道的一层封装。
final onDeviceTranslateClientProvider = Provider<OnDeviceTranslateClient>((ref) {
  return OnDeviceTranslateClient();
});

/// 缓存命中时的 `used` 哨兵值（见文件头说明）。
const int kTranslateUsedUnknown = -1;

/// 一次翻译的结果 + 它从哪来。
typedef TranslateOutcome = ({TranslateResult result, bool fromCache});

/// **翻译编排**（含端侧缓存）。
///
/// 返回 `fromCache: true` ⇒ 本次**没有花钱**（没调接口）。
Future<TranslateOutcome> translateWithCache(WidgetRef ref, String text) async {
  // ── ① 缓存 ──
  //
  // ⚠️ `user.db` 打不开时**不阻断翻译**（缓存是可选的加速层）——
  //    但要在日志里留痕，别让"缓存一直没生效"变成看不见的静默失效。
  TranslationCacheRepository? repo;
  try {
    final Database db = await ref.read(userDbProvider.future);
    repo = TranslationCacheRepository(db);
  } catch (e) {
    // ignore: avoid_print
    print('[translate] user.db 不可用，本次跳过缓存：$e');
  }

  if (repo != null) {
    final hit = await repo.get(text);
    if (hit != null) {
      final segs = _decodeSegments(hit.segmentsJson);
      if (segs.isNotEmpty) {
        return (
          result: TranslateReady(
            segments: segs,
            used: kTranslateUsedUnknown,
            limit: null,
            subscribed: false,
          ),
          fromCache: true,
        );
      }
    }
  }

  // ── ② 端侧优先 → 服务端兜底 ──
  //
  // 🔑 为什么经过编排而不是直接调接口：
  //    端侧翻译「零成本」，但翻译是**订阅权益**（免费 10 次/月）⇒
  //    端侧翻之前必须先由服务端**预扣额度**，否则免费用户变成事实上无限。
  //    编排的完整顺序与理由见 `services/translation_service.dart` 文件头。
  final token = ref.read(authProvider).token ?? '';
  final server = ref.read(translateClientProvider);
  final onDevice = ref.read(onDeviceTranslateClientProvider);

  final outcome = await translateWithFallback(
    text: text,
    probeOnDevice: onDevice.status,
    translateOnDevice: onDevice.translate,
    prepay: (t) => server.prepayQuota(t, token: token),
    translateViaServer: (t, {String? ticket}) =>
        server.translate(t, token: token, ticket: ticket),
  );
  final result = outcome.result;

  // ── ③ 成功才写缓存 ──
  if (result is TranslateReady && repo != null) {
    final json = jsonEncode(
      result.segments.map((s) => {'src': s.src, 'dst': s.dst}).toList(),
    );
    await repo.put(text, json);
    // 顺手做一次 LRU 淘汰（超限才真删；未超限是空操作）
    await repo.prune();
  }

  return (result: result, fromCache: false);
}

/// 把缓存里的 JSON 还原成 segments。
///
/// ⚠️ 缓存**可能损坏**（写一半断电、旧版本格式）⇒ 解析失败返回**空列表**，
///    调用方据此**当作未命中**去调接口 —— 而不是把坏数据渲染出来。
List<TransSegment> _decodeSegments(String json) {
  try {
    final d = jsonDecode(json);
    if (d is! List) return const [];
    final out = <TransSegment>[];
    for (final item in d) {
      if (item is! Map) continue;
      final src = item['src'];
      final dst = item['dst'];
      if (src is String && dst is String && dst.trim().isNotEmpty) {
        out.add(TransSegment(src: src, dst: dst));
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}
