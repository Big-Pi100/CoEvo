// CoEvo · 匿名设备标识（`services/device_id.dart`）验收 —— **纯 Dart，无需 DB**
//
// 跑法：cd scripts/query_verify && dart run bin/verify_device_id.dart
//
// # 验什么
// · 格式（`dev_` + 32 hex）、生成确定性、参数校验（**不补零、不越界**）
// · 🔴 **「读到就用」** —— 包括**不符合当前格式**的已存值（老版本遗留）
//   （覆盖它 = 这台设备在服务端变成新用户 → 去重被稀释）
// · 🔴 **单飞**（并发首调只生成一次 —— 否则同机留下两个 id）
// · 🔴 **读/写失败必须抛**，不许静默生成新的（那会在一次偶发故障后换掉用户身份）
// · 空白值视为没有（生成新的）
//
// ⚠️ 本脚本**不 import Flutter**（靠注入的 fake read/write）—— 这正是
//    `device_id.dart` 把 IO 做成回调的目的。

import 'dart:io';
import 'dart:math';

import '../../../app/lib/services/device_id.dart';

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String label, Object? actual, Object? expected) => check(label,
    actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

/// 内存版持久化（记录每次写，便于断言「写了几次」）。
class _FakePrefs {
  _FakePrefs([Map<String, String>? init]) : store = {...?init};

  final Map<String, String> store;
  final List<MapEntry<String, String>> writes = [];
  int reads = 0;
  bool failRead = false;
  bool failWrite = false;

  Future<String?> read(String key) async {
    reads++;
    if (failRead) throw StateError('模拟读失败');
    return store[key];
  }

  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('模拟写失败');
    writes.add(MapEntry(key, value));
    store[key] = value;
  }
}

/// 固定字节 → 便于断言确定性。
List<int> _bytes(int seed) => List<int>.generate(kDeviceIdBytes, (i) => (seed + i) % 256);

Future<void> main() async {
  // ═══════════════════════════════════════════════════════════
  section('【1】格式与生成（纯函数）');

  final a = deviceIdFromBytes(_bytes(0)); // _bytes(0) = [0,1,2,…,15]
  eq('长度 = 前缀 4 + 32', a.length, kDeviceIdPrefix.length + kDeviceIdBytes * 2);
  eq('字节 0..15 → dev_000102…0f', a, 'dev_000102030405060708090a0b0c0d0e0f');
  eq('全 0 字节 → 32 个 0',
      deviceIdFromBytes(List<int>.filled(kDeviceIdBytes, 0)),
      'dev_${'0' * 32}');
  check('✅ isDeviceId 认它', isDeviceId(a));
  check('🔑 确定性：同字节 → 同结果', deviceIdFromBytes(_bytes(0)) == a);
  check('不同字节 → 不同结果', deviceIdFromBytes(_bytes(1)) != a);

  final hex = deviceIdFromBytes(_bytes(0x12));
  check('十六进制小写、每字节两位', hex.startsWith('dev_1213'), hex);

  section('【1b】参数校验（**不静默补零**）');
  check('字节数不足 → 抛 ArgumentError（补零会让两个输入同 id）', () {
    try {
      deviceIdFromBytes([1, 2, 3]);
      return false;
    } on ArgumentError {
      return true;
    }
  }());
  check('字节数过多 → 抛 ArgumentError', () {
    try {
      deviceIdFromBytes(List<int>.filled(kDeviceIdBytes + 1, 0));
      return false;
    } on ArgumentError {
      return true;
    }
  }());
  check('字节越界（>255）→ 抛 ArgumentError', () {
    try {
      final b = List<int>.filled(kDeviceIdBytes, 0)..[0] = 256;
      deviceIdFromBytes(b);
      return false;
    } on ArgumentError {
      return true;
    }
  }());

  section('【1c】格式校验的**严**度');
  check('❌ 缺前缀', !isDeviceId('00000000000000000000000000000000'));
  check('❌ 长度不对', !isDeviceId('dev_abc'));
  check('❌ 含大写（我们只生成小写）', !isDeviceId('dev_${'A' * 32}'));
  check('❌ 含非 hex 字符', !isDeviceId('dev_${'z' * 32}'));
  check('❌ null', !isDeviceId(null));
  check('❌ 空串', !isDeviceId(''));

  section('【1d】随机生成');
  final r1 = newDeviceId();
  final r2 = newDeviceId();
  check('两次随机结果不同', r1 != r2);
  check('随机结果合法', isDeviceId(r1) && isDeviceId(r2));
  check('注入种子 rng → 可复现', newDeviceId(Random(42)) == newDeviceId(Random(42)));

  // ═══════════════════════════════════════════════════════════
  section('【2】首次：无存储 → 生成并持久化');
  DeviceId.resetForTest();
  {
    final p = _FakePrefs();
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    check('返回值合法', isDeviceId(got), got);
    eq('写了一次', p.writes.length, 1);
    eq('写入的键正确', p.writes.first.key, kDeviceIdPrefsKey);
    eq('写入的值 == 返回值（落盘与内存一致）', p.writes.first.value, got);
    eq('valueOrNull 立即可用（同步取）', DeviceId.valueOrNull, got);
  }

  section('【2b】已有值 → **直接用，不覆盖**');
  DeviceId.resetForTest();
  {
    final existing = deviceIdFromBytes(_bytes(7));
    final p = _FakePrefs({kDeviceIdPrefsKey: existing});
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    eq('返回已存值（不是新生成的）', got, existing);
    eq('🔴 **没有写**（不覆盖）', p.writes.length, 0);
  }

  section('【2c】🔴 已存值**不符合当前格式**也照用（老版本遗留）');
  DeviceId.resetForTest();
  {
    // 假设上一版格式是 uuid 形态（无前缀）—— 覆盖它会让这台设备「变成新用户」
    const legacy = '3f2a1b0c-9d8e-4f7a-8b6c-5d4e3f2a1b0c';
    final p = _FakePrefs({kDeviceIdPrefsKey: legacy});
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    eq('返回老格式值（**保留而非重生成**）', got, legacy);
    eq('没有写', p.writes.length, 0);
    check('（注：它本身不合法 —— 但校验只用于我们自己生成的值）', !isDeviceId(legacy));
  }

  section('【2d】空白值 → 视为没有 → 生成新的');
  DeviceId.resetForTest();
  {
    final p = _FakePrefs({kDeviceIdPrefsKey: '   '});
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    check('生成了合法新值（不是空串）', isDeviceId(got), got);
    eq('写了一次（把空白覆盖掉）', p.writes.length, 1);
  }

  section('【2e】已存值带首尾空白 → 去空白后用（不重复写）');
  DeviceId.resetForTest();
  {
    final v = deviceIdFromBytes(_bytes(3));
    final p = _FakePrefs({kDeviceIdPrefsKey: '  $v\n'});
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    eq('返回去空白后的值', got, v);
    eq('没有写', p.writes.length, 0);
  }

  // ═══════════════════════════════════════════════════════════
  section('【3】🔴 单飞：并发首调只生成一次');
  DeviceId.resetForTest();
  {
    final p = _FakePrefs();
    // 三处同时首次调用（如「启动预热」与「划词」撞在一起）
    final results = await Future.wait([
      DeviceId.ensure(read: p.read, write: p.write),
      DeviceId.ensure(read: p.read, write: p.write),
      DeviceId.ensure(read: p.read, write: p.write),
    ]);
    eq('三次拿到的值**完全相同**', results.toSet().length, 1);
    eq('🔴 只写了一次（不是三次各生成一个）', p.writes.length, 1);
    check('读也只发生一次（后续走内存缓存）', p.reads <= 1, 'reads=${p.reads}');
  }

  section('【3b】已缓存 → 后续 ensure 不再碰 IO');
  // ⚠️ 必须**先 reset** —— 否则本段拿到的是【3】留下的缓存，
  //    新的 fake prefs **一次都不会被碰**（writes 会是 0，不是 1）。
  //    这正是我第一次写这条断言时踩的坑：断言的前提没随段间状态变化。
  DeviceId.resetForTest();
  {
    final p = _FakePrefs();
    final got = await DeviceId.ensure(read: p.read, write: p.write);
    eq('首次写入一次', p.writes.length, 1);
    final readsBefore = p.reads;
    final again = await DeviceId.ensure(read: p.read, write: p.write);
    eq('两次结果一致', again, got);
    eq('没有新增读', p.reads, readsBefore);
    eq('没有新增写', p.writes.length, 1);
    DeviceId.resetForTest();
  }

  // ═══════════════════════════════════════════════════════════
  section('【4】🔴 失败路径：**抛错而不是静默换身份**');
  DeviceId.resetForTest();
  {
    final p = _FakePrefs()..failRead = true;
    var threw = false;
    try {
      await DeviceId.ensure(read: p.read, write: p.write);
    } on DeviceIdUnavailable {
      threw = true;
    }
    check('读失败 → 抛 DeviceIdUnavailable（**不是**生成一个新的）', threw);
    eq('没有写（没生成兜底值）', p.writes.length, 0);

    // 失败后允许重试（inflight 已清）
    DeviceId.resetForTest();
    p.failRead = false;
    final ok = await DeviceId.ensure(read: p.read, write: p.write);
    check('复位后可正常取得', isDeviceId(ok), ok);
  }

  DeviceId.resetForTest();
  {
    final p = _FakePrefs()..failWrite = true;
    var threw = false;
    try {
      await DeviceId.ensure(read: p.read, write: p.write);
    } on DeviceIdUnavailable {
      threw = true;
    }
    check('写失败 → 抛（不留「内存里有个从未落盘的值」）', threw);
  }

  section('【4b】resetForTest 真的清干净');
  DeviceId.resetForTest();
  {
    final p = _FakePrefs();
    await DeviceId.ensure(read: p.read, write: p.write);
    check('有值', DeviceId.valueOrNull != null);
    DeviceId.resetForTest();
    check('reset 后 valueOrNull == null', DeviceId.valueOrNull == null);

    final p2 = _FakePrefs({kDeviceIdPrefsKey: deviceIdFromBytes(_bytes(9))});
    final got2 = await DeviceId.ensure(read: p2.read, write: p2.write);
    eq('reset 后重新读盘（拿到盘上的值）', got2, deviceIdFromBytes(_bytes(9)));
  }

  DeviceId.resetForTest();

  // ═══════════════════════════════════════════════════════════
  print('');
  print('═' * 72);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「单飞」失败 → 查 `DeviceId._inflight` 是否在 await 前就赋值；');
    print('   若「老格式仍用」失败 → 查 `_loadOrCreate` 是否误把 `isDeviceId` 当门槛。');
    exitCode = 1;
  }
}
