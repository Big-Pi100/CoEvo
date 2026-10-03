# 🔍 信息流三问调查：只有 30 篇 / 没有刷新 / 兴趣选择（2026-10-03）

> **白哥问**：① 阅读页面只加载 30 篇文章 ② 没有任何刷新机制 ③ 兴趣选择是否应该做了
> **本文只调查 + 给建议，未改任何代码**（按铁律：先报告，审批后再动手）

---

## 一、结论速览

| 问题 | 实测结论 | 该不该做 |
|---|---|---|
| **① 只有 30 篇** | 🔴 **前端硬编码**（`feed_provider.dart:41` `limit: 30`）—— 而后端 `offset` 分页**早已支持**、前端 `FeedPage.hasMore` **也早已实现**（🔴 **全项目无人调用**）| ✅ 该修（**接线活**，非新功能）|
| **② 没有刷新** | 🔴 **三处全缺**：无下拉刷新、无滚动监听、**且 provider 明确设计成「切 tab 不重拉」** ⇒ 内容停在「进 App 后第一次拉到的」 | ✅ 该修（纯前端）|
| **③ 兴趣选择** | ⚠️ **有意向但未在 L1 定型**；且 🔴 **硬约束：12 类里 8 类近 7 天不足 13 条** → 勾了会像空列表 | 🟡 **先定语义，暂缓界面** |

**一句话**：前两件是**缺陷**（规格已列、基础设施已就位，只差接线），建议立刻做；
第三件是**未决策的功能**，且有内容供给的硬约束，建议先定语义。

---

## 二、① 30 篇从哪来（证据）

### 2.1 代码位置

```dart
// app/lib/providers/feed_provider.dart:36-43
final feedProvider = FutureProvider.family<FeedPage, String>((ref, categoryKey) async {
  final client = ref.watch(contentClientProvider);
  return client.fetchFeed(
    category: categoryKey.isEmpty ? null : categoryKey,
    limit: 30,          // 🔴 硬编码；不传 offset
  );
});
```

而客户端的完整签名是：

```dart
// app/lib/api/content_client.dart:115-120
Future<FeedPage> fetchFeed({
  String? category,
  int limit = 20,
  int offset = 0,       // ← 参数存在，但 provider 没传
  String? sort,
})
```

### 2.2 后端能力（**全都有**）

| 能力 | 位置 | 状态 |
|---|---|---|
| `?category=` 过滤 | `content_handler.rs:107-117`（`(?1 IS NULL OR p.category = ?1)`）| ✅ |
| `limit` / `offset` | `content_handler.rs:87-88` | ✅ |
| `total`（总数）| `content_handler.rs:156-158` | ✅ 已返回 |
| limit 上限 | `MAX_LIMIT = 50` · `DEFAULT_LIMIT = 20` | ✅ |

### 2.3 🔴 关键：客户端**已经写好分页判断，但没接线**

```dart
// app/lib/api/content_client.dart:43-44
/// 是否还有下一页（按 offset+本页条数 < total 判断）。
bool get hasMore => offset + items.length < total;
```

**`hasMore` 全项目搜索：只在 `content_client.dart` 内定义，无任何调用点。**

📌 判据：**「实现了但没人用」不是编译错误** —— 它与「漏接 `onTap` 导致功能静默消失」同族
（记忆里的既有判据：数 `grep -c`，只有 1 处 = 只有定义）。

### 2.4 量化：30 篇到底够不够（**用生产数据算**）

```
按时间倒序（生产库 990 条）：
  第  1 条: 2026-10-03T11:03:03Z
  第 30 条: 2026-10-03T06:24:53Z      ← 跨度 ≈ 4.6 小时
  第 50 条: 2026-10-03T04:22:07Z      ← 跨度 ≈ 6.7 小时

  30 篇 / 990 条 = 只看到 3.0%   ⇒ 剩下 960 条**拿不到**
```

🔑 **一页只覆盖约 4.6 小时**，而抓取间隔是 **6 小时/轮** ⇒
**用户翻到底时，看到的内容已经比「最新」旧了一轮**。

⚠️ 顺带一个必须说清的点：**光把 `30` 调大没用**。
即使调到后端上限 `50`，也只是 **3.0% → 5.1%**，仍是「翻到底就断」。
**真正的修法是分页（offset），不是调大 limit。**

---

## 三、② 没有刷新机制（证据）

### 3.1 三处全缺（逐项 grep，全部 0 命中）

| 机制 | 关键字 | `home_screen.dart` 命中 |
|---|---|---|
| 下拉刷新 | `RefreshIndicator` / `onRefresh` | **0** |
| 上拉加载 | `ScrollController` / `NotificationListener` | **0**（连滚动回调都没有）|
| 分页游标 | `offset` / `hasMore` / `loadMore` | **0** |

列表本身是**静态**的：

```dart
// app/lib/screens/home_screen.dart:358-367
data: (page) {
  if (page.items.isEmpty) return const _FeedEmpty();
  return ListView.separated(
    itemCount: page.items.length,   // ← 就是这 30 条，到此为止
    ...
```

### 3.2 🔴 为什么「放几小时也不变」—— 这是**设计使然**，不是漏了

```dart
// app/lib/providers/feed_provider.dart:69-73
/// ⚠️ `autoDispose`：读完退出后释放 —— 全文可能几 KB，…
///    而信息流列表（上面那个）**不** autoDispose（切 tab 回来不该重新拉）。
```

⇒ `feedProvider` **刻意不 autoDispose** ⇒ 一旦拉到就**常驻缓存**。

而唯一的刷新入口是**错误态的重试**：

```dart
// app/lib/screens/home_screen.dart:352-355
error: (e, _) => _FeedError(
  error: e,
  onRetry: () => ref.invalidate(feedProvider('')),   // ← 只有失败时才出现
),
```

🔴 **组合起来的后果**：
**一切正常时，唯一能让内容更新的办法是「杀掉 App 重开」**（或不切 tab 地重启）。
用户看到的永远是「进 App 后第一次拉到的 30 条」。

📌 这里的取舍本身没错（避免切 tab 重拉是合理的），**但没有配「主动刷新」的出口** ——
缺的是**用户能自己触发**的那条路（下拉刷新）。

### 3.3 附带发现：收藏页也没有下拉刷新

`bookmark_list_screen.dart`：`RefreshIndicator` **0** 命中。
🟡 但**严重度低得多** —— 收藏数据在**端侧 `user.db`**，收藏后立即可见，不存在「网络内容过期」问题。

---

## 四、③ 兴趣选择：规格状态（**逐层核实**）

### 4.1 四份文档，说法不同（必须分层看）

| 层 | 文档 | 说了什么 |
|---|---|---|
| **L0** 权威 | `v1-final-design-authoritative` | ❌ **「兴趣」0 命中** —— **不在最高层定稿** |
| **L1** 界面锚点 | `visual-feed-bookmark-2026-09-25.html` | ❌ **「兴趣」「刷新」「分页」全是 0 命中** —— 只定了**卡片样式 + 收藏作为视图** |
| 评估 | `ui-ux-refactor-assessment:289` | ✅ 信息流首页目标形态 = **卡片式无限流 + 兴趣筛选 + 下拉刷新 + 分页 + 收藏筛选** |
| L3 | `implementation-plan-v2 §10.3` | ✅ 兴趣标签 = **7 类**（⚠️ **已过时**）|
| L3 | `content-source-strategy:506` | 🔴 `user_interest` 表**不建** |

### 4.2 ⚠️ 那条 L3 规格**已过时 5 个月**

```
docs/design/english-app-implementation-plan-v2:2282
| 兴趣选择界面（内容源文档 L190） | 科技 · 商业 · 科学 · 体育 · 文化 · 娱乐 · 健康（7 个） |
```

而**实际** `CONTENT_CATEGORIES`（`schema.rs:516-530`）已是 **12 类**：

```
news · tech · business · science · sports · culture · entertainment · health
+ education · history · law · family（2026-10-02 三轮新增）
```

⇒ **两者不一致**（7 vs 12，且规格里没有 `news`）。
🔑 若照规格做，会**漏掉 5 个类**；而 12 类又超过了规格自己说的「移动端一屏上限」。

### 4.3 🔴🔴 硬约束：**内容供给不足**（这条最关键）

按类统计生产库（990 条）：

| category | 全量 | 近 7 天 | 判定（一页 30 条为参考）|
|---|---|---|---|
| tech | 438 | **438** | ✅ 够 |
| science | 284 | **281** | ✅ 够 |
| news | 168 | **144** | ✅ 够 |
| culture | 30 | 13 | 🟡 近 7 天不足 |
| health | 16 | 6 | ⚠️ 拖动就见底 |
| sports | 10 | 8 | ⚠️ |
| history | 10 | 3 | ⚠️ |
| family | 10 | 1 | ⚠️ |
| entertainment | 9 | 3 | 🔴 像空列表 |
| education | 7 | 5 | 🔴 |
| law | 5 | 5 | 🔴 |
| business | 3 | 3 | 🔴 |

**⇒ 12 类里 8 类近 7 天不足 13 条，4 类不足 8 条。**

🔴 **若现在放开「按兴趣筛选」**：
勾 `business` 的用户会看到 **3 条**；勾 `law` 看到 **5 条**；`family` 近 7 天只有 **1 条**。
**这比「没有筛选功能」更糟** ——
它会让用户以为「App 里没有这类内容」，而不是「筛掉了」。
📌 正是本项目反复的教训：**「静默失败 + 无出口」比「报错」更糟**。

### 4.4 另一个未定项：「兴趣**如何生效**」（规格自己说尚未设计）

```
docs/design/content-source-strategy-evaluation:506
| `user_interest` | 🔴 不建 | ① 兴趣偏好属**端侧 prefs** ② 「兴趣怎么影响排序」**尚未设计**
                        → 现在建表是**没有依据的结构** |
```

两种语义差别**很大**，且决定界面怎么写：

| 语义 | 行为 | 界面含义 |
|---|---|---|
| **筛选（filter）** | 勾 N 类 ⇒ **只**显示这 N 类 | 「只看这些」+ 需要「全部」出口 |
| **排序（rank）** | 勾 N 类 ⇒ 这 N 类**排前**，其余仍在 | 「优先看这些」+ 不需要出口 |

规格原文用的是「**按我兴趣推**」（「推」偏排序），但没定死。
⇒ **不定这个，界面文案、勾选框的提示、空状态都没法写。**

### 4.5 好消息：**基础设施已 100% 就位**

| 层 | 能力 | 状态 |
|---|---|---|
| 后端 | `?category=` 过滤 | ✅ |
| 后端 | `limit` / `offset` / `total` | ✅ |
| 客户端 | `fetchFeed(category:, limit:, offset:)` | ✅ |
| 客户端 | `FeedPage.hasMore` | ✅（🔴 未接线）|
| **Provider** | `FutureProvider.family<FeedPage, String>` | ✅ **已预留** |

甚至 provider 的注释就写着：

```
// app/lib/providers/feed_provider.dart:30-32
/// 用 `FutureProvider.family` 而不是普通 `FutureProvider`：
/// 「分类筛选」是本路由的**既定下一步**（后端 `/api/feed?category=` 已支持），
/// 提前用 family 就不必在那时把整棵树改一遍。
```

⇒ **当年就是为了兴趣筛选才用的 `family`。**
但 UI 层写死了空 key —— `ref.watch(feedProvider(''))`（`home_screen.dart:336`），
**参数从没被传过非空值**。

---

## 五、建议（分两批，理由分开）

### 🔴 第一批：**立刻做**（无依赖 · 纯缺陷 · 已验证基础设施齐备）

| # | 改动 | 为什么 |
|---|---|---|
| 1 | **下拉刷新**（`RefreshIndicator` + `ref.invalidate(feedProvider(...))`）| 修复「内容永远停在首次加载」—— 当前唯一出路是杀 App |
| 2 | **上拉加载更多**（`ScrollController` + `hasMore` + `offset`）| 把「只能看 3.0%」变成「能看到全部」；`hasMore` 和 `offset` 都已就位，**只差接线** |

**这两件属于「缺陷修复」而不是「新功能」**：
- 规格（`ui-ux-refactor-assessment:289`）已把「分页 + 下拉刷新」列为信息流首页的**应有形态**
- 实现成本低（后端与客户端 API 都无需改）
- ⚠️ 注意：**不要只把 `limit: 30` 改成 50** —— 那只是 3% → 5%，翻到底照样断

**建议顺带**：`hasMore` 至今零调用，说明它是个**没接线就静默失效**的坑；
接线时**配一条断言**（防将来又断）。

### 🟡 第二批：**兴趣选择 —— 先定语义，暂缓界面**

**不建议现在做界面**，三条理由：

| # | 理由 | 依据 |
|---|---|---|
| 1 | **内容供给不足** | 8/12 类近 7 天 < 13 条；4 类 < 8 条 ⇒ 勾了像空列表 |
| 2 | **语义未定** | 规格自己写「兴趣怎么影响排序**尚未设计**」（`content-source-strategy:506`）|
| 3 | **L1 未定型** | 界面锚点 `visual-feed-bookmark` 里「兴趣」0 命中 ⇒ 现在做等于**自己定规格** |

**建议的顺序**：

```
① 定语义（决策）──→ ② 补内容供给（或加门槛）──→ ③ 做界面（成本很低，基础设施已就位）
```

**其中 ① 是纯决策、需要白哥定**；② 是运营/接源问题；③ 才是编码。

### 4.5 若想「先上最小可用版」的一个选项

**只把「内容够的类」展示给用户勾选**（近 7 天 ≥ N 条，比如 20）：
- ✅ 绝不会出现空列表
- ⚠️ 但现在只有 **tech / science / news** 三类够 ⇒ **只有 3 个可选项**
  ⇒ 「兴趣选择」的意义就很弱了（用户勾 3 个 ≈ 没筛）

📌 所以这个最小版本的收益存疑 —— **我更倾向先把第一批做完**，
等接源把内容量做上来（尤其 `culture` 30 条已在门口），兴趣选择才有意义。

---

## 六、⏳ 待白哥定

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **第一批（下拉刷新 + 分页）现在做吗？** | ✅ 建议做 —— 是缺陷，不是新功能 |
| 2 | **兴趣选择的语义：筛选 还是 排序？** | 需你定（规格未定，且它决定界面形态）|
| 3 | **是否接受「内容不足的类先不给用户选」** | 若接受，`culture`/`health` 等要等接源 |
| 4 | 是否要一并处理**收藏页**（无下拉刷新）| 🟡 严重度低（本地数据）—— 可顺手加 |

---

## 七、产出

| 文件 | 说明 |
|---|---|
| 本报告 | 完整证据链（文件:行号 + 生产数据）|
| `scripts/trace_verify/bin/category_stats.py` | 🆕 分类分布统计（只读）|
| `scripts/trace_verify/bin/paging_span.py` | 🆕 量化「一页覆盖多长时间」（只读）|

> **本轮未改任何代码**（`app/lib` 与 `backend/` 一字未动）——
> 新增的只有两个**只读**诊断脚本。
