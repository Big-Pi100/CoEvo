// CoEvo · 兴趣选择集合验收（纯 Dart · 零 Flutter 依赖）
//
// 跑法：cd scripts/trace_verify && dart run bin/verify_interest_selection.dart
//
// # 为什么它存在
//
// `InterestSelection` 是「兴趣筛选」里**唯一能在本机验证**的部分
// （本机 Flutter 崩 ⇒ 界面/persist 接线只能靠 CI + 出包实测）。
// 而它守的恰好是最容易**静默出错**的一条：**同一个集合必须产生同一个 key**。
// 错了不会报错 —— 只是用户每换一次勾选顺序就多一次网络请求，且旧 provider 不复用。
//
// 依据：`app/lib/services/interest_selection.dart` 文件头。

import 'dart:io';

import '../../../app/lib/services/interest_selection.dart';

var _pass = 0;
var _fail = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String label, Object? got, Object? want) =>
    check(label, got == want, got == want ? '' : '实得=$got 期望=$want');

void section(String s) {
  print('');
  print('─' * 70);
  print(s);
}

void main() {
  print('CoEvo 兴趣选择集合验收 · 依据 app/lib/services/interest_selection.dart');

  // ══════════════════════════════════════════════════════════════
  section('【1】🔴 核心约定：同一集合 ⇒ 同一 key（与勾选顺序无关）');

  // 这是本文件的**唯一理由**。若这条挂了，`feedProvider(categoryKey)` 会因为
  // 「先勾 A 再勾 B」与「先勾 B 再勾 A」产生两个 key ⇒ 两个 provider 实例
  // ⇒ 白发一次请求，且**不报错**。
  final ab = InterestSelection.from(['tech', 'science']);
  final ba = InterestSelection.from(['science', 'tech']);
  eq('构造顺序不同 ⇒ 同一个 key', ab.normalizedKey, ba.normalizedKey);
  eq('key 是排序后的', ab.normalizedKey, 'science,tech');
  check('🔴 两个实例也**相等**（Riverpod 不会误判「变了」）', ab == ba);
  eq('hashCode 一致（Set 相等 ⇒ 哈希相等）', ab.hashCode, ba.hashCode);

  // 逐步 toggle（模拟用户真实操作顺序）
  var step1 = InterestSelection.none.toggled('tech').toggled('science');
  var step2 = InterestSelection.none.toggled('science').toggled('tech');
  eq('toggle 顺序不同 ⇒ 同一个 key', step1.normalizedKey, step2.normalizedKey);
  check('toggle 顺序不同 ⇒ 实例相等', step1 == step2);

  // ══════════════════════════════════════════════════════════════
  section('【2】空集 = 「全部」（与 feedProvider(\'\') 衔接）');

  check('空集 isAll', InterestSelection.none.isAll);
  eq('空集 key = 空串（= 后端「不筛」）', InterestSelection.none.normalizedKey, '');
  eq('count = 0', InterestSelection.none.count, 0);
  // 全选 12 类 ⇒ 与「不筛」**不是**同一件事（后者让后端返回全部，前者要显式列 12 个）
  final all12 = InterestSelection.from([
    'news', 'tech', 'business', 'science', 'sports', 'culture',
    'entertainment', 'health', 'education', 'history', 'law', 'family',
  ]);
  check('全选 12 类 != 空集（两者语义不同，别混）', all12 != InterestSelection.none);
  eq('全选 12 类的 key 按字典序', all12.normalizedKey,
      'business,culture,education,entertainment,family,health,history,law,news,science,sports,tech');

  // ══════════════════════════════════════════════════════════════
  section('【3】归一：大小写 / 空白 / 重复 / 空串');

  eq('大写归一为小写', InterestSelection.from(['TECH']).normalizedKey, 'tech');
  eq('空白被 trim', InterestSelection.from([' tech ']).normalizedKey, 'tech');
  eq('重复去重', InterestSelection.from(['tech', 'tech', 'TECH']).normalizedKey, 'tech');
  eq('空串被丢弃', InterestSelection.from(['', '  ', 'tech']).normalizedKey, 'tech');
  eq('全空串 ⇒ 空集', InterestSelection.from(['', '  ']).normalizedKey, '');
  eq('split 空串（parse("")）⇒ 空集', InterestSelection.parse('').normalizedKey, '');
  eq('parse(null) ⇒ 空集', InterestSelection.parse(null).normalizedKey, '');
  eq('parse 带空白的串', InterestSelection.parse(' tech , science ').normalizedKey,
      'science,tech');

  // ══════════════════════════════════════════════════════════════
  section('【4】parse ↔ normalizedKey 往返（持久化靠它）');

  // 🔑 往返只对**已规范化**的串成立（这一点是断言的前提，别写成任意串）：
  //    `parse('law,family,news').normalizedKey == 'family,law,news'` ——
  //    输入是合法的但**未规范化**，输出被排序 ⇒ 与原串不同。
  //    ⚠️ 我第一版就把这个当成「往返失败」写进了期望值 ——
  //       那是**断言错，不是实现错**（`family,law,news` 才是字典序）。
  //    📌 判据：断言失败先分清「实现错 / 断言错 / 文档矛盾」三类。
  for (final raw in ['', 'tech', 'science,tech', 'family,law,news']) {
    eq('往返: "$raw"', InterestSelection.parse(raw).normalizedKey, raw);
  }
  // 乱序输入 ⇒ 输出**规范化**（不是原样回吐）
  eq('乱序输入被规范化', InterestSelection.parse('tech,science').normalizedKey,
      'science,tech');
  eq('未规范化的合法输入 ⇒ 被排序', InterestSelection.parse('law,family,news').normalizedKey,
      'family,law,news');
  // 🔑 幂等：规范化两次 = 规范化一次
  final once = InterestSelection.parse('tech,science');
  eq('幂等', InterestSelection.parse(once.normalizedKey).normalizedKey,
      once.normalizedKey);

  // ══════════════════════════════════════════════════════════════
  section('【5】toggle / contains / cleared');

  final s = InterestSelection.none;
  final t1 = s.toggled('tech');
  check('toggle 后包含 tech', t1.contains('tech'));
  check('🔴 toggled 不修改原实例（不可变）', !s.contains('tech') && s.isAll);
  final t2 = t1.toggled('tech');
  check('再次 toggle 同一 key ⇒ 移除（回到空集）', t2.isAll);
  check('contains 大小写不敏感', t1.contains('TECH') && t1.contains(' tech '));
  check('toggled 空串 ⇒ 不变', t1.toggled('').normalizedKey == t1.normalizedKey);
  check('cleared ⇒ 空集', t1.cleared.isAll);
  eq('keys 是字典序列表', t1.keys.join('|'), 'tech');

  // ══════════════════════════════════════════════════════════════
  section('【6】🔴 key 的字符形态必须是「逗号分隔、无空格」（与后端契约）');

  // 后端 `parse_categories` 按 `,` 切分 + trim。若前端多带了空格，
  // 后端也能容忍 —— 但**存储与日志里会出现两种写法**，比对时会误判成「变了」。
  // ⇒ 这里锁住「输出无空格」。
  final multi = InterestSelection.from(['tech', 'science', 'law']);
  check('无前导/尾随空格', multi.normalizedKey == multi.normalizedKey.trim());
  check('无连续逗号', !multi.normalizedKey.contains(',,'));
  check('不以逗号开头/结尾',
      !multi.normalizedKey.startsWith(',') && !multi.normalizedKey.endsWith(','));
  check('无空格', !multi.normalizedKey.contains(' '));
  eq('形态确认', multi.normalizedKey, 'law,science,tech');

  // ══════════════════════════════════════════════════════════════
  print('');
  print('=' * 70);
  print('  通过 $_pass 项 · 失败 $_fail 项');
  print('=' * 70);
  if (_fail > 0) {
    print('🔴 失败清单：');
    for (final f in _failures) {
      print('    · $f');
    }
    exit(1);
  }
  print('✅ 全部通过 —— 退出码 0');
}
