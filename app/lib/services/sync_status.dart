/// 云端同步的**状态模型** —— **纯 Dart · 零 import**。
///
/// # 🔑 为什么单独一个文件（而不是塞进 provider）
///
/// 「上次同步是几点 / 成没成」这类**换算**最容易错，而它错了不会报错 ——
/// 只会让用户看到一句**假的时间**。放在纯文件里 ⇒ `scripts/query_verify`
/// 可以直接 import 它做**穷举**（跨天 / 跨年 / 时钟回拨 / null）。
/// 📌 同族先例：`auth_session_policy.dart` / `achievement_rules.dart`。
///
/// ⚠️ **本文件不得 import 任何东西**（含 `package:flutter/*`）——
/// 一旦引入，那套离线断言会直接编译不过。
library;

/// 同步所处的阶段。
///
/// 🔑 [skipped] 必须与 [failed] **分开**：
///    「未登录 / 没满足前提 ⇒ 这轮没跑」不是故障，**不该**把图标置成失败态，
///    也不该盖掉上一次的成功时间 —— 否则用户会看到「同步失败」而其实只是没登录。
enum SyncPhase {
  /// 还没同步过（全新设备 / 刚换账号）。
  idle,

  /// 正在同步。
  syncing,

  /// 上次同步成功。
  ok,

  /// 上次同步**失败**（[SyncStatus.lastError] 一定有值）。
  failed,

  /// 本轮**没跑**（未登录 / `user.db` 不可用等前提不满足）——
  /// **不算失败**，保持上一次的状态与时间。
  skipped,
}

/// 同步状态（供 UI 显示）。
class SyncStatus {
  final SyncPhase phase;

  /// **上次成功**同步的时刻（当地时区）。失败不会清掉它 ——
  /// 「上次成功是昨天 18:05，之后一次失败」比「什么都没同步过」信息量大得多。
  final DateTime? lastOkAt;

  /// 最近一次失败的原因（**可直接展示给用户**的一句话）。
  final String? lastError;

  /// 最近一次成功同步推上去 / 拉下来的条数（摘要用）。
  final int lastPushed;
  final int lastPulled;

  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastOkAt,
    this.lastError,
    this.lastPushed = 0,
    this.lastPulled = 0,
  });

  /// 是否「订阅有效但同步出过问题」—— 供图标选失败态。
  bool get hasError => phase == SyncPhase.failed;

  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastOkAt,
    String? lastError,
    int? lastPushed,
    int? lastPulled,
  }) {
    return SyncStatus(
      phase: phase ?? this.phase,
      lastOkAt: lastOkAt ?? this.lastOkAt,
      lastError: lastError,
      lastPushed: lastPushed ?? this.lastPushed,
      lastPulled: lastPulled ?? this.lastPulled,
    );
  }
}

/// 「上次同步」的**相对时间文案** —— 🔑 **全库唯一的换算点**。
///
/// 输入 [now] 而不是内部调 `DateTime.now()`：**让它可以被断言穷举**
/// （跨天 / 跨年 / 时钟回拨都测得了）。调用方传 `DateTime.now()`。
///
/// ⚠️ 边界（都有断言）：
/// · `days <= 0` → 「今天」——**含负天数**。时钟回拨 / 时区变化会让差值为负，
///   那时说「-1 天前」或「1970-01-01」都比「今天」更糟。
/// · 只有**昨天**单独成词；2~6 天用「N 天前」；≥7 天直接给日期（相对天数已无意义）。
String relativeSyncLabel(DateTime at, DateTime now) {
  final a = at.toLocal();
  final n = now.toLocal();
  // 🔑 比「日期」而不是比「时刻」—— 23:59 同步、00:01 查看应显示「昨天」，
  //    而不是「0 小时前」。按自然日算才是用户嘴里的「今天/昨天」。
  final aDay = DateTime(a.year, a.month, a.day);
  final nDay = DateTime(n.year, n.month, n.day);
  final days = nDay.difference(aDay).inDays;
  final hm = '${a.hour.toString().padLeft(2, '0')}:'
      '${a.minute.toString().padLeft(2, '0')}';
  if (days <= 0) return '今天 $hm';
  if (days == 1) return '昨天 $hm';
  if (days < 7) return '$days 天前';
  return '${a.year}-${a.month.toString().padLeft(2, '0')}-'
      '${a.day.toString().padLeft(2, '0')}';
}

/// 云端同步**胶囊**上的常驻短文案 —— 与 [syncStatusSummary] **同源**（一份状态，两种长度）。
///
/// # 为什么需要第二套文案
///
/// | 用途 | 要求 |
/// |---|---|
/// | [syncStatusSummary]（点击后弹 `SnackBar`）| 可以长：带原因、带「（上次成功：…）」 |
/// | 本函数（**常驻的胶囊**）| 必须**短且稳定**（4~12 字），否则会撑破那一行 |
///
/// ⚠️ 两者**都从 [SyncStatus] 派生** —— 不要在 widget 里各写一套 `switch`：
///    那是「同一件事两个来源」的形状（改一处漏一处，且失败态容易只在一边处理）。
///
/// 🔑 与 [syncStatusSummary] 的**唯一语义差别**：胶囊**总有字**
///    （未同步过 ⇒ 「尚未同步」），因为一枚空胶囊没有意义；
///    而 `SnackBar` 在「没什么可说」时**不弹**（弹一句「未知状态」是噪音）。
String syncChipLabel(SyncStatus s, DateTime now) {
  switch (s.phase) {
    case SyncPhase.syncing:
      return '正在同步…';
    case SyncPhase.failed:
      return '同步失败';
    case SyncPhase.ok:
      final at = s.lastOkAt;
      return at == null ? '已同步' : '已同步 · ${relativeSyncLabel(at, now)}';
    case SyncPhase.idle:
    case SyncPhase.skipped:
      // skipped = 本轮没跑（未登录等），**保留上次成功时间** —— 否则用户会看到
      // 「尚未同步」而其实前几天刚同步过（同 [syncStatusSummary] 的取向）。
      final at = s.lastOkAt;
      return at == null ? '尚未同步' : '已同步 · ${relativeSyncLabel(at, now)}';
  }
}

/// **未订阅**时胶囊的文案（🆕 2026-10-09）。
///
/// 🔑 它与 [syncChipLabel] 是**两条不同的东西**，不是「同一件事的两种写法」：
///    后者描述**同步进行到哪**（只在「有能力同步」的前提下才有意义），
///    这条描述**能力本身没开**。合成一个函数会让它内部长出一个
///    `if (!subscribed) return …` 的旁路，读起来像特例、改起来容易漏。
///
/// 🔴 白哥 2026-10-09：「未同步显示灰色，**这样没有订阅的用户才知道要订阅**」
///    ⇒ 文案必须**同时说清状态与出口**（未订阅 · 订阅后可同步），
///      只说「未同步」会让用户以为是网络问题而反复点。
String syncUnsubscribedLabel() => '未订阅 · 订阅后可同步';

/// 云朵图标 / 胶囊**点击后**展示的一句话（徽标本身放不下这些字）。
///
/// 返回 `null` = **没什么可说**（还没同步过、或本轮没跑）——
/// 调用方据此**不弹提示**（而不是弹一句「未知状态」）。
String? syncStatusSummary(SyncStatus s, DateTime now) {
  switch (s.phase) {
    case SyncPhase.syncing:
      return '正在同步…';
    case SyncPhase.ok:
      final at = s.lastOkAt;
      if (at == null) return null;
      return '已同步 · ${relativeSyncLabel(at, now)}';
    case SyncPhase.failed:
      final at = s.lastOkAt;
      final when = at == null ? '' : '（上次成功：${relativeSyncLabel(at, now)}）';
      return '同步失败${s.lastError == null ? '' : '：${s.lastError}'}$when';
    case SyncPhase.idle:
    case SyncPhase.skipped:
      return null;
  }
}
