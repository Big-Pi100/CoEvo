// 兴趣筛选的**选择集合**（纯逻辑 · 零 import）
//
// # 为什么单独成文件、且零 import
//
// 本项目**本机 Flutter 跑不了**（鸿蒙定制版 SDK，`dart analyze` 会 `CreateFile 231`）
// ⇒ 任何 `import 'package:flutter/...'` 的文件在本地**一律无法验证**
//   （依赖链最终到 `dart:ui`，它只在引擎里 —— 实测确证）。
// ⇒ 要让「选择集合」这件事可验证，它必须**零 import**，只依赖 `dart:core`。
//   于是 `scripts/trace_verify/bin/verify_interest_selection.dart` 能在本机跑真断言，
//   并已接进 CI（同 `feed_pager` / `markdown_unescape` 的做法）。
//
// 📌 判据：**把「可验证的核心」从「无法验证的外壳」里切出来** ——
//    切不出来的部分（UI 接线）如实标注为「本机不可验」，交给 CI + 出包实测。
//
// # 🔑 本类要解决的唯一问题：**同一个集合必须产生同一个字符串**
//
// `feedProvider` 是 `family`，**参数参与相等性比较**：
//   · 用 `Set<String>` 当参数 → `Set` 的 `==` 是**引用比较** ⇒ 每次都是新 provider
//     ⇒ 每次重建都重新发请求（同 `feedByIdsProvider` 注释里踩过的坑）
//   · 用 `'tech,science'` 当参数 → 字符串值相等 ✅ 但**顺序必须确定**：
//     `'tech,science'` 与 `'science,tech'` 是**两个不同的 key** ⇒ 两个 provider 实例
//     ⇒ 用户「先勾 tech 再勾 science」与「先勾 science 再勾 tech」会**各发一次请求**
//     ⇒ 而且旧实例不会被复用，白耗流量（这个 bug **不报错**，只是多请求）
// ⇒ 所以：**排序**是这里唯一的正确做法，不是一个「顺手优化」。
//
// ⚠️ 排序用 `List.sort()`（字典序，UTF-16 码元比较）。
//    category key 全是 ASCII 小写 ⇒ 与后端 Rust 的 `str` 排序**结果一致** ✅
//    （后端 `parse_categories` 也会排序，但**前端不能依赖它** —— 后端排序只影响
//      它自己的 INSTR 串，前端 key 的稳定性必须前端自己保证）。

/// 用户勾选的兴趣分类集合（**不可变** · 纯 Dart）。
///
/// # 与后端的关系
///
/// [normalizedKey] 会被直接当 `?category=` 的值传给 `/api/feed`：
/// · `''`（空集）⇒ **不传该参数** ⇒ 后端不筛 ⇒ 「全部」（见 [isAll]）
/// · `'tech,science'` ⇒ 后端 `parse_categories` 规范化成 `,science,tech,`
///   后用 `INSTR` 做**集合成员判定**（见 `content_handler.rs`）
///
/// ⚠️ 本类**不做白名单校验** —— 合法性由「可选值从哪来」保证
///    （界面上只有 12 个真实分类的 pill）＋ 后端仍会再过滤一次（防御性）。
///    在这里再加一层，只会多出一个会漂移的定义。
class InterestSelection {
  /// 已选中的分类 key（**始终小写** · 去重）。
  ///
  /// 🔑 用 `Set` 存但**对外只暴露排序后的 [keys]** ——
  ///    `Set` 的迭代顺序在 Dart 里是**插入顺序**（`LinkedHashSet`），
  ///    直接用它拼 key 就会带上「用户勾选顺序」⇒ 违反本类的核心约定。
  final Set<String> _selected;

  const InterestSelection._(this._selected);

  /// 空选择 = **不筛** = 信息流的「全部」。
  static const InterestSelection none = InterestSelection._(<String>{});

  /// 从一组 key 构造（会归一：小写 + 去空白 + 去重）。
  factory InterestSelection.from(Iterable<String> keys) {
    final s = <String>{};
    for (final k in keys) {
      final n = k.trim().toLowerCase();
      if (n.isNotEmpty) s.add(n);
    }
    return InterestSelection._(s);
  }

  /// 从**存储形态**解析（`'tech,science'` 或 `''`）。
  ///
  /// 🔑 与 [normalizedKey] 是**往返**关系：`parse(x).normalizedKey == x` 当且仅当
  ///    `x` 本身已规范化。测试锁住了这条（含乱序、空白、重复、大写）。
  factory InterestSelection.parse(String? raw) =>
      InterestSelection.from((raw ?? '').split(','));

  /// 已选 key（**字典序** —— 顺序恒定，见文件头）。
  List<String> get keys {
    final l = _selected.toList()..sort();
    return l;
  }

  /// 传给 `feedProvider` 的 **family key**（也是持久化用的串）。
  ///
  /// 空集 ⇒ `''` ⇒ 与「全部」是**同一个 key** ——
  /// 这在语义上正好正确：**没选兴趣 = 不筛 = 全部**。
  String get normalizedKey => keys.join(',');

  /// 是否「不筛」（= 全部）。
  bool get isAll => _selected.isEmpty;

  int get count => _selected.length;

  bool contains(String key) => _selected.contains(key.trim().toLowerCase());

  /// 返回**切换某个 key 后**的新实例（不可变风格 —— 便于 Riverpod 比较）。
  InterestSelection toggled(String key) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return this;
    final next = <String>{..._selected};
    if (!next.remove(k)) next.add(k);
    return InterestSelection._(next);
  }

  /// 清空 = 回到「全部」。
  InterestSelection get cleared => none;

  /// 相等性按**集合**判定（与顺序无关）——
  /// 于是 `from(['a','b']) == from(['b','a'])` ✅
  /// ⚠️ 这也让 Riverpod 的 state 比较不会因为顺序差异而误判「变了」。
  @override
  bool operator ==(Object other) =>
      other is InterestSelection &&
      other._selected.length == _selected.length &&
      other._selected.containsAll(_selected);

  @override
  int get hashCode => Object.hashAllUnordered(_selected);

  @override
  String toString() =>
      isAll ? 'InterestSelection(全部)' : 'InterestSelection($normalizedKey)';
}
