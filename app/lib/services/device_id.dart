// 端侧**匿名设备标识** —— 一个「首次生成、之后永不变」的本地 id。
//
// # 它存在的唯一理由：让服务端的去重统计有意义
//
// `POST /api/generate-card` 接受可选的 `device_id`，服务端用它写
// `generated_card_hit(spelling, device_id)` —— `(spelling, device_id)` 是 PK，
// 于是 `COUNT(*)` 就是 **distinct_user_count**（去重后的用户数）。
//
// 🔴 **A3 的词库回流门槛就靠这个信号**：
//     `hit_count` 只累计总次数（**去重不了**）→ 「一个人刷 100 次」与
//     「100 个人各查 1 次」在它眼里一模一样 → 拿它当门槛会把噪声当需求。
//
// # 🔴 格式：`dev_` + 32 位小写 hex（16 字节）
// **一旦发布就不能改** —— 它是服务端的去重键，改格式 = 所有老用户
// 在服务端变成「陌生人」（同一台设备会被算成两个用户）。
// 若真需要改版，必须**保留旧值**而不是就地重生成（见 `_loadOrCreate` 的说明）。
//
// # 语义：它是**设备**标识，不是**用户**标识
// | 情形 | 结果 |
// |---|---|
// | 换设备 | 新 id → 服务端算作另一个「用户」（**这是想要的** —— 两台设备本来就该各算一个去重单位）|
// | 卸载重装 | 新 id（`SharedPreferences` 被系统清空）→ 同上，**可接受** |
// | 退出登录 | **不变** ✅（见下）|
//
// # 🔑 它与登录态**无关**，退出登录**不许清它**
// 它不是凭证，而是「这台设备」的匿名标签。`auth_provider.logout()` 用的是
// `prefs.remove('display_name')`（**精确删单键**，不是 `clear()`）→ 目前安全。
// ⚠️ 但这是**约定而非强制** —— 若将来有人把 logout 改成 `prefs.clear()`，
//    device_id 会被静默抹掉，表现为「每次退出登录都换一个新身份」。
//    → 已加断言守这条（`scripts/query_verify/bin/verify_device_id.dart`）。
//
// # 为什么不用「随机数」「每次请求现生成」蒙混
// 那样服务端收到的每次都是新 id → `distinct_user_count` 会被灌成请求次数，
// 比「不传」**更糟**（不传至少是「0，明确未启用」；瞎传是「有值但全错」）。
// 🔑 判据：**指标宁可为空，不可为假。**

import 'dart:math';

/// `SharedPreferences` 里存 device_id 的键。
///
/// 前缀 `coevo.` 与项目其它键（`display_name` / `coevo_show_login`）保持同类风格。
const String kDeviceIdPrefsKey = 'coevo.device_id';

/// id 前缀 —— 让它在日志/DB 里一眼可辨认（同 `ext:` 前缀的做法）。
const String kDeviceIdPrefix = 'dev_';

/// 随机字节数（16 字节 = 128 bit，碰撞概率可忽略）。
const int kDeviceIdBytes = 16;

/// 校验一个字符串是否是**本格式**的 device_id。
///
/// ⚠️ 用**大小写敏感**匹配（我们生成的就是小写；服务端只把它当字符串键，
///    没有归一化需求 —— 但校验要严，避免把用户手输的怪字符串当真）。
final RegExp _kDeviceIdPattern =
    RegExp('^${RegExp.escape(kDeviceIdPrefix)}[0-9a-f]{${kDeviceIdBytes * 2}}\$');

bool isDeviceId(String? s) => s != null && _kDeviceIdPattern.hasMatch(s);

/// 从字节生成 id（**纯函数** —— 断言可喂固定字节拿确定结果）。
///
/// [bytes] 少于 [kDeviceIdBytes] 时**抛错而不是补零** —— 补零会让两个不同的
/// 短输入产出同一个 id，属于静默错误。
String deviceIdFromBytes(List<int> bytes) {
  if (bytes.length != kDeviceIdBytes) {
    throw ArgumentError(
        'device_id 需要 $kDeviceIdBytes 字节，收到 ${bytes.length}');
  }
  final buf = StringBuffer(kDeviceIdPrefix);
  for (final b in bytes) {
    if (b < 0 || b > 255) throw ArgumentError('字节越界: $b');
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// 生成一个新的 id（[rng] 可注入以便断言）。
String newDeviceId([Random? rng]) {
  final r = rng ?? Random.secure();
  return deviceIdFromBytes(
      List<int>.generate(kDeviceIdBytes, (_) => r.nextInt(256)));
}

// ───────────────────────── IO（回调注入）─────────────────────────

/// 读一个持久化键（读不到返回 `null`）。
///
/// 🔑 **用回调而非直接依赖 `SharedPreferences`** —— 让本文件保持**零 Flutter 依赖**，
///    于是生成/校验/单飞逻辑能在纯 Dart 断言脚本里跑（同 `word_db_bootstrap` 的做法）。
typedef PrefsRead = Future<String?> Function(String key);

/// 写一个持久化键。
typedef PrefsWrite = Future<void> Function(String key, String value);

/// 匿名设备标识的**唯一入口**（单飞 + 内存缓存）。
///
/// # 为什么要有单飞
/// 若两处并发首次调用（如「启动时预热」与「划词同时发生」），天真的实现会
/// **各生成一个 id**，然后后写的覆盖先写的 —— 而先返回的那个已经被用掉了，
/// 于是同一台设备在服务端留下两个 id（去重被稀释）。
/// → 本类把「进行中的 Future」缓存起来，后续调用直接复用**同一个** Future。
class DeviceId {
  DeviceId._();

  static Future<String>? _inflight;
  static String? _cached;

  /// 已加载的值（未加载时 `null`）。给**同步上下文**用。
  static String? get valueOrNull => _cached;

  /// 取 device_id：**读到就用**（哪怕是老格式/手工值 —— 见下），否则生成并持久化。
  ///
  /// 🔴 **`isDeviceId(s)` 为 false 的已存值也照用**（不覆盖）：
  ///    它可能是**上一版格式**留下的（改过前缀/长度）。覆盖它会让这台设备
  ///    在服务端变成新用户 —— 而「保留旧值」只是格式不统一，**代价小得多**。
  ///    → 校验只用于「我们自己新生成的值」（`newDeviceId` 保证合法）。
  static Future<String> ensure({
    required PrefsRead read,
    required PrefsWrite write,
    Random? rng,
  }) {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _inflight ??= _loadOrCreate(read: read, write: write, rng: rng);
  }

  static Future<String> _loadOrCreate({
    required PrefsRead read,
    required PrefsWrite write,
    Random? rng,
  }) async {
    String? existing;
    try {
      existing = await read(kDeviceIdPrefsKey);
    } catch (e) {
      // 🔴 读失败**不能**让它变成「生成新的」—— 那会在一次偶发故障后
      //    把用户身份换掉。宁可抛出（调用方降级为「本次不传 device_id」）。
      _inflight = null; // 允许下次重试
      throw DeviceIdUnavailable('读取 device_id 失败: $e');
    }

    final trimmed = existing?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      _cached = trimmed;
      return trimmed;
    }

    final fresh = newDeviceId(rng);
    try {
      await write(kDeviceIdPrefsKey, fresh);
    } catch (e) {
      // 写失败 → 本次仍可用（内存里有），但**不缓存**，下次会重新尝试生成。
      // ⚠️ 后果：若持续写失败，每次启动都会是新 id —— 可接受（比阻断制卡好），
      //    但要留日志让这种状态可见。
      _inflight = null;
      throw DeviceIdUnavailable('持久化 device_id 失败: $e');
    }
    _cached = fresh;
    return fresh;
  }

  /// ⚠️ **仅供断言** —— 清掉内存缓存，让下一次 `ensure` 重新读。
  static void resetForTest() {
    _inflight = null;
    _cached = null;
  }
}

/// device_id 不可用（读/写持久化失败）。
///
/// 🔑 调用方应当**降级**处理（本次不传 device_id），**而不是**中断主流程 ——
///    它是统计信号，不是功能前提（同「增强不该阻断主体」）。
class DeviceIdUnavailable implements Exception {
  const DeviceIdUnavailable(this.message);
  final String message;
  @override
  String toString() => 'DeviceIdUnavailable: $message';
}
