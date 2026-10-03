// 信息流分页状态机验收 —— `app/lib/services/feed_pager.dart`
//
// 跑法（🔑 必须用**官方版** Dart：PATH 里那个是鸿蒙定制版）：
//   cd scripts/trace_verify
//   DART=/d/flutter/bin/cache/dart-sdk/bin/dart.exe
//   $DART run bin/verify_feed_pager.dart
//
// 退出码 0 = 全过；1 = 有失败 → 可挂 CI / pre-commit。
//
// # 为什么这个脚本能验「Flutter 项目里的代码」
//
// `feed_pager.dart` 是**零 import** 的纯 Dart（见该文件头部的说明）
// ⇒ 本脚本 `import` 它之后，`dart run` 会做**完整的类型检查**（不只是语法）
// ⇒ 验证强度 ≈ `flutter analyze` 对该文件的效果。
//
// ⚠️ **它验不到的**（如实列出，见报告）：
//   · UI 接线（`RefreshIndicator` / `ScrollController` / footer 渲染）
//   · provider 与页面之间的数据流
//   这两部分是 Flutter 依赖代码，本机无法跑 → 需白哥在终端验证。

import 'dart:io';

import '../../../app/lib/services/feed_pager.dart';

int _pass = 0;
int _fail = 0;

void check(bool cond, String label, {String? detail}) {
  if (cond) {
    _pass++;
    print('  ✅ $label');
  } else {
    _fail++;
    print('  🔴 $label${detail == null ? '' : '\n       $detail'}');
  }
}

void section(String title) {
  print('');
  print('── $title ──');
}

/// 生成 `[from, from-1, ..., from-count+1]`（模拟「按时间倒序」的一页）。
List<int> page(int from, int count) =>
    List<int>.generate(count, (i) => from - i);

int _id(int x) => x;

void main() {
  // ══════════════════════════════════════════════════════════════════
  section('① 基本分页：累积与游标');
  // ══════════════════════════════════════════════════════════════════
  {
    // 🔑 `total` 要设成「实际能拉到的总条数」，否则最后那条 `!hasMore` 断言必失败。
    //    ⚠️ 第 1 版这里写 total=200 却只拉了 120 条 ⇒ `hasMore` 当然仍为真。
    //       **那是测试的期望值错，不是实现错** ——
    //       📌 判据：断言失败先分清「实现错 / 断言错 / 文档矛盾」三类。
    var p = FeedPager<int>.first(page(100, 30), 120, idOf: _id);
    check(p.items.length == 30, '首页 30 条');
    check(p.fetched == 30, '游标 = 30（= 已请求的原始条数）');
    check(p.nextOffset == 30, '下一页 offset = 30');
    check(p.hasMore, 'total 120 > fetched 30 ⇒ 还有更多');
    check(!p.ended, '未到终局');

    p = p.append(page(70, 30), 120, idOf: _id);
    check(p.items.length == 60, '第二页后累积 60 条（无重复）');
    check(p.fetched == 60, '游标 = 60');
    check(p.nextOffset == 60, '下一页 offset = 60');

    p = p.append(page(40, 30), 120, idOf: _id);
    check(p.items.length == 90, '第三页后 90 条');
    check(p.hasMore, 'fetched 90 < total 120 ⇒ 还有更多');

    // 最后一页（正好取满）
    p = p.append(page(10, 30), 120, idOf: _id);
    check(p.items.length == 120, '第四页后 120 条');
    check(p.fetched == 120, '游标 120 = total');
    check(!p.hasMore, 'fetched 到 total ⇒ 没有更多了（不必依赖空页）');
  }

  // ══════════════════════════════════════════════════════════════════
  section('② 🔴 去重：新内容插入导致重复时不重复显示');
  // ══════════════════════════════════════════════════════════════════
  {
    // 第 1 页 [100..71]
    var p = FeedPager<int>.first(page(100, 30), 200, idOf: _id);

    // 模拟：插入 5 条新内容后，第 2 页 OFFSET 30 返回 [75..46]
    //   （与原页重叠 [75..71] 共 5 条）
    p = p.append(page(75, 30), 205, idOf: _id);

    check(p.items.length == 55, '去重后 55 条（30 + 新增 25）',
        detail: '实得 ${p.items.length}；重叠的 5 条被丢弃');
    check(p.items.first == 100, '首条仍是 100（顺序不被重复项打乱）');
    check(p.items.last == 46, '末条 = 46');

    // 🔑 顺序稳定：重复项**不改变已有位置**
    check(
      p.items.sublist(0, 5).join(',') == '100,99,98,97,96',
      '前 5 条顺序不变',
    );

    // 没有重复 id
    final ids = p.items.toSet();
    check(ids.length == p.items.length, '无重复 id（集合大小 = 列表长度）');
  }

  // ══════════════════════════════════════════════════════════════════
  section('③ 🔴🔴 游标必须独立于 items.length（本文件最易写错处）');
  // ══════════════════════════════════════════════════════════════════
  {
    // 极端场景：插入的新内容 **≥ 一整页**
    // ⇒ 第 2 页 OFFSET 30 拿到的**全是已看过的**
    var p = FeedPager<int>.first(page(100, 30), 300, idOf: _id);
    final lenBefore = p.items.length;

    p = p.append(page(100, 30), 330, idOf: _id); // 整页重复

    check(p.items.length == lenBefore, '整页重复 ⇒ 条目数不变（去重生效）',
        detail: '实得 ${p.items.length}，期望 $lenBefore');
    check(p.fetched == 60, '🔴 游标照常前进到 60（不是 30）',
        detail: '实得 ${p.fetched}');
    check(p.nextOffset == 60,
        '🔴 下一页 offset = 60 —— 若拿 items.length(=$lenBefore) 当 offset，'
        '会**永远停在 $lenBefore**，列表再也不增长（用户上拉却什么也不来）',
        detail: '实得 ${p.nextOffset}');
    check(p.hasMore, '仍应继续翻（不能因为本页无新增就停下）');

    // 再翻一页「有新内容」⇒ 证明能从极端状态恢复
    p = p.append(page(69, 30), 330, idOf: _id);
    check(p.items.length == 60, '下一页恢复正常累积 → 60 条',
        detail: '实得 ${p.items.length}');
  }

  // ══════════════════════════════════════════════════════════════════
  section('④ 🔴 空页 = 终局信号（防空转）');
  // ══════════════════════════════════════════════════════════════════
  {
    // 场景：total 说还有，但服务端实际取不到（并发删除 / count 口径差）
    var p = FeedPager<int>.first(page(100, 30), 999, idOf: _id);
    check(p.hasMore, '前置：total 999 ⇒ hasMore 为真');

    p = p.append(const [], 999, idOf: _id); // 服务端返回空页

    check(p.ended, '空页 ⇒ ended 置位');
    check(!p.hasMore, '🔴 空页后不再有更多（否则用户上拉 → 空页 → 再上拉 → 死循环）',
        detail: 'fetched=${p.fetched} total=${p.total} ended=${p.ended}');
    check(p.items.length == 30, '已有条目保留（空页不该清列表）');
    check(p.loadingMore == false, '空页后不在加载态');

    // 首页就是空（服务端通但没内容）
    final empty = FeedPager<int>.first(const [], 0, idOf: _id);
    check(empty.isEmpty, '空首页 ⇒ isEmpty');
    check(!empty.hasMore, '空首页 ⇒ 不该显示「加载更多」');
    check(empty.ended, '空首页 ⇒ ended');
  }

  // ══════════════════════════════════════════════════════════════════
  section('⑤ 错误处理：失败**不清列表**');
  // ══════════════════════════════════════════════════════════════════
  {
    var p = FeedPager<int>.first(page(100, 30), 200, idOf: _id);

    // 加载更多失败
    var q = p.startingLoadMore();
    check(q.loadingMore, 'startingLoadMore ⇒ loadingMore 为真');
    check(q.items.length == 30, '进入加载态不清列表');

    q = q.loadMoreFailed('network down');
    check(!q.loadingMore, '失败后退出加载态');
    check(q.loadMoreError == 'network down', '记录 loadMoreError');
    check(q.items.length == 30, '🔴 失败后列表完好（30 条）');
    check(q.hasMore, '失败不影响 hasMore（可以再试）');
    check(q.nextOffset == 30, '失败不推进游标（重试仍请求同一页）');

    // 重试
    var r = q.startingLoadMore();
    check(r.loadingMore && r.loadMoreError == null,
        '重试时清掉上次的 loadMoreError（否则 footer 同时显示转圈与错误）');

    // 下拉刷新失败
    var s = p.startingRefresh();
    check(s.refreshError == null, '刷新开始时清掉旧 refreshError');
    s = s.refreshFailed('timeout');
    check(s.refreshError == 'timeout', '记录 refreshError');
    check(s.items.length == 30, '🔴 刷新失败也**保留列表**（用户不会突然看到空白页）');

    s = s.clearRefreshError();
    check(s.refreshError == null, 'clearRefreshError 生效');

    // ⚠️ 清除语义的单测：`_copy` 用 `?? this.x` ⇒ 传 null **不等于**清除
    //    这正是 `clearXxxError` 开关存在的原因（防「以为清了其实没清」）
    final t1 = p.loadMoreFailed('e1');
    final t2 = t1.startingRefresh();
    check(t2.loadMoreError == null,
        'startingRefresh 应**显式清除** loadMoreError（不能依赖传 null）');
  }

  // ══════════════════════════════════════════════════════════════════
  section('⑥ 下拉刷新 = 用第一页重置');
  // ══════════════════════════════════════════════════════════════════
  {
    var p = FeedPager<int>.first(page(100, 30), 200, idOf: _id);
    p = p.append(page(70, 30), 200, idOf: _id);
    check(p.items.length == 60, '前置：已累积 60 条');

    // 刷新成功 ⇒ 用新首页替换（丢弃累积）
    final refreshed = FeedPager<int>.first(page(105, 30), 210, idOf: _id);
    check(refreshed.items.length == 30, '刷新后回到 30 条');
    check(refreshed.items.first == 105, '刷新后首条是最新的 105');
    check(refreshed.fetched == 30, '游标重置为 30');

    // 刷新期间的中间态：保留旧列表
    final during = p.startingRefresh();
    check(during.items.length == 60, '刷新进行中仍显示旧的 60 条（不闪白）');
  }

  // ══════════════════════════════════════════════════════════════════
  section('⑦ 边界与不变量');
  // ══════════════════════════════════════════════════════════════════
  {
    // 空构造
    const p0 = FeedPager<int>();
    check(p0.isEmpty && p0.fetched == 0 && p0.total == 0 && !p0.hasMore,
        '缺省构造 = 空且无更多');
    check(p0.items is List<int>, '缺省 items 类型正确（const [] 可赋给 List<T>）');

    // 不变量：fetched 单调不减（除刷新重置）—— 用一系列 append 抽查
    var p = FeedPager<int>.first(page(100, 20), 500, idOf: _id);
    var last = p.fetched;
    var mono = true;
    for (var i = 0; i < 5; i++) {
      p = p.append(page(80 - i * 20, 20), 500, idOf: _id);
      if (p.fetched < last) mono = false;
      last = p.fetched;
    }
    check(mono, '连续 append 时 fetched 单调不减');
    check(p.fetched == 120, '5 页 × 20 条 = 120',
        detail: '实得 ${p.fetched}');

    // 超大 id（不依赖 int 的位宽假设）
    final big = FeedPager<int>.first(const [1 << 62, (1 << 62) - 1], 2, idOf: _id);
    check(big.items.length == 2 && big.fetched == 2, '大 id 正常工作');
  }

  // ══════════════════════════════════════════════════════════════════
  print('');
  print('=' * 62);
  print('  通过 $_pass 项 · 失败 $_fail 项');
  print('=' * 62);
  if (_fail > 0) {
    print('🔴 有失败项 —— 退出码 1');
    exit(1);
  }
  print('✅ 全部通过 —— 退出码 0');
}
