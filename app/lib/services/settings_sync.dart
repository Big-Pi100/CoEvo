// CoEvo · 应用设置的**跨设备同步**（纯 Dart：只依赖 sqflite API + **注入的** prefs 读写）
//
// 🔴 设计约束：本文件**不得 import 任何 Flutter 包** ——
//    `SharedPreferences` 是 Flutter 插件 ⇒ 读写**由调用方注入**（见两个 typedef）。
//    理由同 `sync_service.dart`：**把 IO 推到边界，逻辑留在中间** ⇒ 本机可断言。
//
// # 三个动作
//
// ```
//   采集   prefs 现值 → 与 `setting_sync` 表比对 → 变了就 upsert（pending_push = 1）  ← [collectSettings]
//   推送   `setting_sync` 的 pending 行 → 服务端                                        ← sync_service
//   应用   拉回的远端行 → 写表（LWW 合并）+ **写回 prefs**                                ← [applySettings]
// ```
//
// 🔑 **为什么是「采集式」而不是「给每个 setter 加标脏」**
//    现值就是唯一真相 —— 用户改的、[applySettings] 写回的，一视同仁。
//    若给每个设置项加「写时标脏」，就要改 5+ 个 setter
//    （漏一处 ⇒ 那一项**永不同步**，而且**静默**）。
//
// # 谁需要它
// 阅读字号 / 痕迹开关 / 兴趣筛选 / TTS 开关与语速 / 显示名此前只存在 `SharedPreferences`
// ⇒ 换设备后**全部丢失**（用户要重设一遍）。它是审计报告 §四 里「最容易被漏的一类」。
//
// # 🔴 键清单为什么是**字面量**（而不是引用各来源文件的常量）
//
// 那些来源文件里有的是 provider（`interest_provider.dart`）、有的 import 了 Flutter
// （`tts_service.dart` 用 `SharedPreferences`）⇒ 本文件（纯 Dart）**不能** import 它们。
// ⇒ 用字面量清单，并由**断言**钉住「与来源一致」：
//    `scripts/query_verify/bin/verify_sync.dart` 逐键核对它出现在对应来源文件里。
//    📌 判据：**不能 import 时就靠断言补上编译期约束**（本项目已多次这样做）。
//
// # ⚠️ 已知边界：换账号后 prefs 里的残留
//
// `setting_sync` 在 `kUserOwnedTables` 里（换账号会被清空），但**写回 prefs 的那些值不会**。
// ⇒ 换账号后，下一个账号的「首次采集」可能把**上一个账号的设置值**当成自己的推上去。
//    🔴 处理：`sync_provider.dart` 的换账号路径会**一并复位**这些 prefs 键
//       （见 `resetSyncedSettingPrefs`）—— 与清理旧版游标键
//       （`clearLegacySyncCursorPrefs`，2026-10-10 由 `clearSyncCursorFor` 改名）同一时机。

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'sync_merge.dart' as m;

/// 要同步的设置（prefs 键）。
///
/// 🔴 **只列「配置一次就不动」的项** —— 与设备强相关的偏好（如「主题跟随系统」）
///    刻意**不纳入**（那是「这台设备怎么显示」，不是「这个用户怎么学」）。
///
/// | 键 | 含义 | 来源文件（断言核对其存在）|
/// |---|---|---|
/// | `reading_font_size` | 阅读字号 | `services/reading_settings.dart` |
/// | `reading_trace_enabled` | 痕迹开关 | `services/reading_settings.dart` |
/// | `interest_categories` | 兴趣筛选 | `providers/interest_provider.dart` |
/// | `tts_enabled` | 朗读开关 | `services/tts_service.dart` |
/// | `tts_speech_rate` | 朗读语速 | `services/tts_service.dart` |
/// | `display_name` | 显示名 | `screens/profile_screen.dart` |
const List<String> kSyncedSettingKeys = [
  'reading_font_size',
  'reading_trace_enabled',
  'interest_categories',
  'tts_enabled',
  'tts_speech_rate',
  'display_name',
];

/// 读一个 prefs 键（注入）—— 返回 `null` 表示**没有设过**。
///
/// 🔑 `null` 与「值是 null」是两件事：本函数的 `null` 只会由「这个键不存在」产生，
///    而采集端据它**跳过**（没设过 ⇒ 不上传 ⇒ 不会把默认值当成用户设置推给别端）。
typedef PrefsRead = Future<Object?> Function(String key);

/// 写一个 prefs 键（注入）。`value` 是 JSON 文本；
/// 调用方应 `jsonDecode` 后**按类型**写回（`setInt` / `setBool` / `setDouble` / `setString` /
/// `setStringList`）—— 否则读回的类型会漂（`int` 变 `double` 会让下次采集误判为「已变更」）。
typedef PrefsWrite = Future<void> Function(String key, String value);

/// **采集**：把 prefs 现值与 `setting_sync` 表比对，有变化就 upsert（标脏）。
///
/// 返回**当前待推的行**（形状：`key` / `value` / `updated_at`；与后端 `SettingInput` 一致）。
///
/// # 🔑 三条规则
/// | 情形 | 处理 |
/// |---|---|
/// | prefs 里**没有**这个键 | **跳过**（没设过 ⇒ 不上传 —— 否则会把「默认值」当成用户设置推给别端）|
/// | 表里没有这一行（老库升级后第一次）| 新增 + `pending_push = 1` |
/// | 表里值与现值**相同** | 不动（避免每次同步都产生「假变更」）|
/// | 表里值与现值**不同** | 更新 `value` / `updated_at`（= now）+ `pending_push = 1` |
///
/// ⚠️ 返回的是**整张表的 pending 行**（不只是本轮新标脏的）——
///    之前标脏但没推成功的行也要带上（否则它们永远补不上）。
Future<List<Map<String, Object?>>> collectSettings(
  Database db, {
  required PrefsRead readPref,
}) async {
  final now = DateTime.now().toUtc().toIso8601String();

  for (final key in kSyncedSettingKeys) {
    final raw = await readPref(key);
    if (raw == null) continue; // 没设过 ⇒ 不上传（见上表）
    final value = jsonEncode(raw);

    final rows = await db.query('setting_sync',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1);
    if (rows.isEmpty) {
      await db.insert('setting_sync', {
        'key': key,
        'value': value,
        'updated_at': now,
        'pending_push': 1,
      });
    } else if (rows.first['value'] != value) {
      await db.update(
        'setting_sync',
        {'value': value, 'updated_at': now, 'pending_push': 1},
        where: 'key = ?',
        whereArgs: [key],
      );
    }
  }

  final pending = await db.query('setting_sync',
      where: 'pending_push = 1', orderBy: 'key ASC');
  return pending
      .map((r) => <String, Object?>{
            'key': r['key'],
            'value': r['value'],
            'updated_at': r['updated_at'],
          })
      .toList(growable: false);
}

/// **应用**：把远端设置行**合并**（LWW）写进表，并**写回 prefs**。
///
/// 返回**真正改变了值的键**（调用方据此刷新读端 —— 字号 / 兴趣 / TTS 的 provider）。
///
/// # 🔴 为什么写回 prefs 是必须的
/// 设置的实际消费方（阅读器 / 信息流 / TTS）读的是 **prefs**，不是本表。
/// 只写表不写回 ⇒ 「数据同步了、界面没变」（本项目最忌的静默失效）。
///
/// # 🔑 只写回**真正变化的**键
/// 无谓地覆盖 prefs 会触发多余的状态重建，而且**下次采集会误判为「变更」**
/// （若类型漂了，如 int→double）⇒ 产生回声。
Future<List<String>> applySettings(
  Database db,
  List<Map<String, dynamic>> rows, {
  required PrefsWrite writePref,
}) async {
  final changed = <String>[];
  for (final j in rows) {
    final remote = m.settingFromPullJson(j);
    final key = remote['key'] as String? ?? '';
    if (key.isEmpty) continue;

    final existing = await db
        .query('setting_sync', where: 'key = ?', whereArgs: [key], limit: 1);
    final Map<String, Object?>? localRow =
        existing.isEmpty ? null : {...existing.first};
    final merged =
        localRow != null ? m.mergeSetting(localRow, remote) : {...remote};

    // 🔑 与其余表同一条防回声判据（见 `sync_merge.pendingPushAfterPull`）
    final pending = m.pendingPushAfterPull(
      localExisted: localRow != null,
      localWasPending:
          localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
    );

    final valueChanged =
        localRow == null || localRow['value'] != merged['value'];

    await db.rawInsert(
      'INSERT INTO setting_sync (key, value, updated_at, pending_push) '
      'VALUES (?,?,?,?) '
      'ON CONFLICT (key) DO UPDATE SET '
      '  value = excluded.value, '
      '  updated_at = excluded.updated_at, '
      '  pending_push = excluded.pending_push',
      [
        key,
        merged['value'],
        merged['updated_at'],
        pending ? 1 : 0,
      ],
    );

    if (valueChanged && merged['value'] is String && (merged['value'] as String).isNotEmpty) {
      await writePref(key, merged['value'] as String);
      changed.add(key);
    }
  }
  return changed;
}

/// 移除一个 prefs 键（注入 —— 换账号复位用）。
typedef PrefsRemove = Future<void> Function(String key);

/// 🆕 2026-10-10：**换账号时复位**同步过的设置 prefs（与「清空 `setting_sync`」配套）。
///
/// # 🔴 为什么必须有它（一个跨账号泄漏）
/// `setting_sync` 表在 `kUserOwnedTables` 里（换账号会被清空），
/// 但**写回 prefs 的那些值不会**。若不复位：
///   下一个账号的「首次采集」会把**上一个账号的设置值**当成「本地用户设置」推上去
///   ⇒ 跨账号泄漏（字号 / 兴趣 / **显示名**跑到别人账号）—— **且不报错**。
///
/// 🔑 做法：把每个同步键**移除**（**不是**写默认值 ——
///    写了默认值会被采集端当成「用户设过」而推上去，等于把问题倒过来）。
///    移除后 `readPref` 返回 `null` ⇒ 采集端跳过 ⇒ 由别端或代码默认值决定。
/// 📌 与 `clearLegacySyncCursorPrefs` 同一时机（换账号清数据的收尾），理由同族：
///    **用结构隔离/复位优于「靠人记得」**。
Future<void> resetSyncedSettingPrefs(PrefsRemove removePref) async {
  for (final key in kSyncedSettingKeys) {
    await removePref(key);
  }
}

/// 标记这些设置已同步（push 成功后调用）。
Future<void> markSettingsSynced(Database db, Iterable<String> keys) async {
  final list = keys.where((k) => k.isNotEmpty).toList();
  if (list.isEmpty) return;
  final ph = List.filled(list.length, '?').join(',');
  await db.update('setting_sync', {'pending_push': 0},
      where: 'key IN ($ph)', whereArgs: list);
}
