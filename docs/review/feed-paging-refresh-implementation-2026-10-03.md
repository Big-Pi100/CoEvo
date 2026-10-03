# 🛠 信息流修复第一批：下拉刷新 + 上拉分页（2026-10-03）

> **白哥指令**：「同意」（批准做第一批：下拉刷新 + 分页）
> **结果**：✅ 已实施 · ✅ 核心逻辑本地验证 **54 项全过** · 🔴 **UI 接线无法本机验证**（见 §四）
> **未部署**（App 侧改动，需你出包；后端一行未改）

---

## 一、一句话

把「只能看 30 条、只能靠杀 App 更新」修成「**可下拉刷新 + 可上拉翻完全部**」，
并顺手补上一个**结构性的可验证性**改进：把分页逻辑抽成**零 Flutter 依赖的纯 Dart**，
使它在「本机 Flutter 全崩」的前提下**仍能被本地验证**。

---

## 二、改了什么（4 个文件）

| # | 文件 | 类型 | 说明 |
|---|---|---|---|
| 1 | `app/lib/services/feed_pager.dart` | 🆕 新增 | **分页状态机**（零 import 纯 Dart）—— 累积 / 去重 / 游标 / 终局 / 错误保留 |
| 2 | `app/lib/providers/feed_provider.dart` | 改 | `FutureProvider.family` → **`AsyncNotifierProvider.family`**，加 `loadMore()` / `refresh()` |
| 3 | `app/lib/screens/home_screen.dart` | 改 | `RefreshIndicator` + `ScrollController` + footer（含错误态） |
| 4 | `scripts/trace_verify/bin/verify_feed_pager.dart` | 🆕 新增 | **54 项**断言（纯 Dart，可本地跑、可挂 CI） |

`home_screen.dart` 新增 3 个辅助方法：`_refreshFeed` / `_fillViewport` / `_feedFooter`。

---

## 三、🔑 关键设计：为什么把分页抽成**纯 Dart**

**这是本轮最重要的工程决策**，理由是一条**硬约束**：

> 本机 Flutter 是鸿蒙定制版 ⇒ `flutter analyze / build / test` 全崩
> （`CreateFile 231`：Dart 建不了子进程）

⇒ 若分页逻辑写在 provider / widget 里，**本轮改动将 0 项本地验证**。

**实测确证**（不是我推理的 —— 我实际跑了这个实验）：

```
$ dart run .tmp_typecheck.dart      # 内容仅：import feed_provider.dart
Error: Dart library 'dart:ui' is not available on this platform.
Context: The unavailable library 'dart:ui' is imported through these packages:
    .tmp_typecheck.dart => lib/providers/feed_provider.dart
      => package:flutter_riverpod => package:flutter => dart:ui
exit=254
```

⇒ 🔴 **任何 import 了 Flutter 的文件都无法用本机任何手段验证**（`dart:ui` 只在 Flutter 引擎里）。
   这条边界对 `feed_provider.dart` 与 `home_screen.dart` **都成立**。

⇒ 所以唯一的办法是：**把能抽的逻辑抽到「不 import 任何东西」的文件里**
   （连 `models/feed_item.dart` 都不能依赖 —— 它为了 `debugPrint` import 了 Flutter）。
   做法：**泛型 + `idOf` 回调**解耦 ⇒ `FeedPager<T>` 不需要知道 `T` 是什么。

📌 这与项目既有做法一致：`scripts/trace_verify` 的
   `import '../../../app/lib/services/markdown_unescape.dart'` 就是同一路子
   —— **验证脚本 import 真源码，不是副本**。

---

## 四、🔴 验证到什么程度（如实分层）

| 层 | 手段 | 结果 |
|---|---|---|
| ✅ **分页逻辑** | `verify_feed_pager.dart`（54 项）| **54 passed / 0 failed** · 退出码 0 |
| ✅ **类型检查**（`feed_pager.dart`）| `dart run` 会做**完整类型检查**（不只是语法）| 通过 |
| ✅ **语法检查**（3 个文件）| `dart format --output=none`（解析 AST）| 3/3 通过 |
| ✅ **第三方 API 签名** | **读 pub-cache 里 riverpod 2.6.1 源码**逐条核实 | 见 §五 |
| 🔴 **UI 接线**（RefreshIndicator / ScrollController / footer 渲染）| ❌ **本机无法验证** | **未验证** |
| 🔴 **provider ↔ 页面数据流** | ❌ 同上 | **未验证** |
| 🔴 **CI `flutter analyze`** | 推 main 后会跑（官方 Flutter 3.41.1）| ⏳ 待 CI |

### 4.1 关于「类型检查」的强度

`dart run verify_feed_pager.dart` 成功 ⇒ 说明 `feed_pager.dart`
**通过了 Dart 的完整静态类型检查**（`dart run` 不是只做语法解析）——
对**纯 Dart 文件**而言，这个强度**≈ `flutter analyze`**。

### 4.2 我为什么坚持核实 API 而不是凭记忆写

`feed_provider.dart` / `home_screen.dart` 无法编译验证 ⇒ **API 用法写错了我也不会知道**。
所以逐条**读 riverpod 源码**核实（不是查文档、不是凭记忆）：

| 我用的 API | 核实结果（源码位置） |
|---|---|
| `AsyncNotifierProvider.family<N,T,Arg>(N.new)` | ✅ `builders.dart:52` — `call<NotifierT extends FamilyAsyncNotifier<T,Arg>, T, Arg>` |
| `FamilyAsyncNotifier<State, Arg>` | ✅ `async_notifier/family.dart:6` — `build(Arg arg)` |
| `arg` 字段 | ✅ `family.dart:15` — `late final Arg arg` |
| notifier 内的 `ref` | ✅ `async_notifier/base.dart:20` — `AsyncNotifierProviderRef<State> get ref` |
| `state = AsyncData(x)` | ✅ 项目先例 `bookmark_provider.dart:81` |
| `AsyncError(error, stackTrace)` | ✅ `common.dart:466` — **两参必填**（我传的是 `(e, st)` ✅）|
| `state.valueOrNull` | ✅ `common.dart`（多处）|
| `provider(arg).notifier` | ✅ `family.dart:80` — `late final ... notifier` |

---

## 五、🐛 本地验证抓到的**2 个真 bug**（这就是它的价值）

| # | bug | 怎么抓到的 | 性质 |
|---|---|---|---|
| 1 | `_dedupe(const [], ...)` 让泛型 T 推断成 **`dynamic`** ⇒ `List<dynamic>` 赋给 `List<T>` **类型错误** | 脚本**第一次跑就编译失败** | 🔴 若没有脚本，这个错会在**你出包时**才暴露 |
| 2 | `startingLoadMore()` 用 `loadMoreError: null` 想「清除错误」—— 但 `_copy` 的语义是 `?? this.xxx` ⇒ **传 null = 不修改** ⇒ 错误**根本没清除** | 断言「重试时清掉上次的 loadMoreError」**红了** | 🔴 用户会看到 footer **同时**显示转圈和错误文字 |

⚠️ bug 2 尤其值得记：我在 `startingRefresh()` 里**已经意识到**这个坑并写了注释，
却在 `startingLoadMore()` 里**犯了同一个错** ——
📌 **「知道某个坑」≠「不会踩」**，只有断言能保证。

另外还有一条**测试自己的错**（也算收获）：
断言「最后一页后 `!hasMore`」时我把 `total` 写成 200 而只拉了 120 条 ⇒ 断言必然红。
📌 判据：**断言失败先分清「实现错 / 断言错 / 文档矛盾」** —— 这次是**断言错**。

---

## 六、⏳ 需要你验什么（我验不了的部分）

### 6.1 你可以在终端跑（本机跑不了）

```bash
cd /e/CoEvo/app

# ① 静态检查 —— CI 用的是这个（--no-fatal-infos 表示 info 不算失败）
flutter analyze --no-fatal-infos

# ② 出包（含后端地址，别漏 --dart-define）
flutter build apk --release \
  --dart-define=API_HOST=api.keyievolution.fun \
  --target-platform android-arm64
```

### 6.2 装上后请重点看这几件事

| # | 操作 | 预期 |
|---|---|---|
| 1 | 进信息流，**下拉** | 顶部出现转圈；**松手后内容刷新**（转圈收起时内容**已经**是新的，不是随后才变）|
| 2 | **快速上滑到底** | 底部出现转圈 → 列表**继续增长**（不再停在 30 条）|
| 3 | 一直上滑到最后一页 | 列表停止增长；**不再转圈**（不空转）|
| 4 | 断网点开 App（或飞行模式）| 显示「网络好像不通」+ **重试按钮** + **能下拉** |
| 5 | 网络恢复后**下拉** | 正常加载（错误态下拉也应生效）|
| 6 | 翻到第 3 页后切到「复习」再切回 | ⚠️ **已加载的页数应保留**（provider 不 autoDispose）|
| 7 | 下拉刷新后再上滑 | 从第 1 页重新开始，**不出现重复卡片** |

⚠️ 第 6 项若**回到 30 条**，说明 provider 的存活范围与预期不符 —— 告诉我。

### 6.3 我没验但**风险很低**的部分

- `_fillViewport`（`LayoutBuilder` + `SingleChildScrollView` + `ConstrainedBox`）是 Flutter 里
  「让不满屏内容可下拉」的**标准写法**，但我无法本地渲染确认

---

## 七、🔍 附带修掉的一处「空头支票」

`_FeedError` 的说明文案**本来就写着**：

> 「服务可能正在忙。稍后再试，**或者下拉重试**。」

🔴 但在本次改动之前，**根本没有下拉刷新** —— 这句文案是**空头支票**。
（📌 同族判据：「注释/文案里的能力声明」要 grep 得到实现才算数。）

✅ 现在：**错误态也包进了 `RefreshIndicator`**（配合 `_fillViewport`），文案终于成立。

---

## 八、⏳ 三个待你定的项

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **「到底了」要不要显示文案** | 我**刻意没做**（新增用户可见文案属设计决策，`visual-feed-bookmark` 里没有）。列表自然结束不致误解。**要的话给我文案** |
| 2 | **兴趣选择的语义**（筛选 vs 排序）| 上一轮问了没答 —— 它决定界面形态，且**内容供给不足**是硬约束（8/12 类 <13 条）|
| 3 | 🆕 **`trace_verify` 的脚本要不要进 CI** | 现在**完全没进**（只有 `fsrs_verify` 进了）⇒ **脚本存在但没人跑 = 迟早失效**（同「`hasMore` 写了没人用」）。<br>⚠️ 但 CI 配置**我也无法本地验证** ⇒ 不擅自改，把改法放在 §九 |

---

## 九、建议的 CI 改动（供你决定，我未改）

`fsrs-verify` job 已证明这条路可行（它用官方 Dart + import 真源码）。
可照抄一个：

```yaml
  trace-verify:
    name: Trace Verify (pure Dart)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: scripts/trace_verify
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: stable
      - name: Verify feed pager (分页状态机)
        run: dart run bin/verify_feed_pager.dart
      - name: Verify unescape (Markdown 转义)
        run: dart run bin/verify_unescape.dart
      - name: Verify trace markdown (痕迹注入)
        run: dart run bin/verify_trace_markdown.dart
```

⚠️ **顺带**：这也把项目**既有的**两个脚本（`verify_unescape` / `verify_trace_markdown`）纳入 CI ——
它们现在同样「存在但没人跑」。

---

## 十、产出

| 文件 | 说明 |
|---|---|
| `app/lib/services/feed_pager.dart` | 🆕 分页状态机（纯 Dart）|
| `app/lib/providers/feed_provider.dart` | 改：分页 + 刷新 |
| `app/lib/screens/home_screen.dart` | 改：UI 接线 |
| `scripts/trace_verify/bin/verify_feed_pager.dart` | 🆕 **54 项**验证 |
| `docs/review/feed-paging-refresh-and-interests-2026-10-03.md` | 上一轮调查报告 |
| 本报告 | 实施 + 验证边界 |
