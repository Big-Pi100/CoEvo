# Step 3.5 收藏清单 —— 实施报告

> 日期：2026-09-27｜触发：白哥「虽然可以点击收藏，但**收藏了的内容在哪看**？」
> 状态：✅ **已实施**（白哥选「阅读 tab 内的子视图」+「现在就做」）
> 依据：`docs/design/visual-feed-bookmark-2026-09-25.html`（第 355-407 行两个 mockup + `.bm-hd`/`.bm-sub`/`.empty` 三类）

---

## 〇、一句话

**设计稿明说「没有新界面要设计」** —— 本步只是把已有的 `FeedCard` **筛选一遍**，
加上一个「教用户书签在哪」的空状态，以及首页标题栏的入口。

> 设计稿原文：「同一套卡片组件，只是筛选过 —— **没有新界面要设计**。
> 空状态用粘土凹陷圆环 + 引导文案。」

---

## 一、施前核实（发现的是**功能缺口**，不是 bug）

| 检查 | 结果 |
|---|---|
| bookmark/收藏 页面 | ❌ 没有 |
| 路由入口 | ❌ 没有 |
| 首页标题栏「收藏 N」 | ❌ 没放 —— `home_screen.dart:263` 注释：「属 **3.5**……本批不放，避免出现点了没反应的死入口」 |

→ **收藏此前只写入 `user.db`，没有任何查看入口。**

### 基础设施已齐（这是本步工作量不大的原因）

| 依赖 | 状态 |
|---|---|
| `BookmarkRepository.list()` | ✅ 已实现（`bookmarkedAt` 倒序 · `limit`/`offset`） |
| `bookmarkProvider` | ✅ 就绪（`idsOrEmpty` / `isReady`） |
| `FeedItem.id` | ✅ **与 `bookmark.content_id` 同源** |
| `FeedItem.meta` | ✅ 注释即：「卡片与**收藏清单共用**的元信息行……格式必须只定义一次」 |

🔑 **模型层早就为清单设计好了** —— 本步只是把它接上。

---

## 二、关键设计决策

### 2.1 路由形态：**子路由**（保留 tabbar）

| | 路由 | tabbar | 依据 |
|---|---|---|---|
| **收藏清单** | `/home/bookmarks`（**子路由**） | ✅ 保留 | 设计稿 mockup **画了 tabbar 且无返回按钮**；产品原则「**收藏是视图非 tab**」 |
| 阅读器 | `/article/:id`（顶层） | ❌ 全屏 | spec §5.1「底部：无」（沉浸阅读） |

🔑 **判据：「它是不是 tab 的内容」** —— 清单是「阅读」这个 tab 的**内容**；阅读器是**覆盖全屏的沉浸态**。
两者形态不同**不是疏漏**。

**实现要点**：`path: 'bookmarks'`（**无前导斜杠** = 相对路径 = 子路由）
→ go_router 渲染在**该分支的 Navigator** 内 → tabbar 保留 + iOS 右滑返回可用。

⚠️ **设计稿 CSS 里另有一个未被 mockup 使用的 `.bm-hd .back`**（返回链接样式）——
说明设计阶段也考虑过「全屏 push + 返回按钮」。**本实现按 mockup 走**。
**返回方式**：点「阅读」tab（`goBranch(i, initialLocation: i == currentIndex)` 会回到分支初始页）或右滑。

> ⏳ **待真机确认**：这条路由的**返回可发现性**（用户是否知道点 tab 能回去）。
> 若实测不明显，`bm-hd .back` 的样式设计稿已备好，追加成本很低。

### 2.2 🔑 抽出共用的「切换收藏 + 轻提示」

信息流与收藏清单要做**同一件事**，而 toast 的**文案与时长由设计稿 §1.6 规定**
（「已收藏 · 可在「收藏」里重读」，1.5 秒消失）。

→ 抽成 `lib/widgets/bookmark_toggle.dart`，两处都调它。

🔑 **与 `BookmarkButton` 被抽出来是同一条理由**：设计稿里是同一个东西 →
实现里就该是**一处**。否则改文案要记得改两处，漏一处就出现「同一个 App 两种提示」。

### 2.3 空状态：**重点不是「没有内容」，而是「书签在哪」**

> 设计稿原文：「空状态要教会用户『**书签在哪**』，而不是只说『没有内容』。
> **用真实图标做引导**，用户下次一眼就认出来。」

三件套（严格照设计稿 `.empty`）：

| 元素 | 设计稿 | 实现 |
|---|---|---|
| 圆环 | 74×74 · `--sunken` 底 + 两个 inset | `Clay(state: pressed, fill: sunken, borderRadius: circular(37))` |
| 标题 | `16 / w600` | 「还没有收藏的文章」 |
| 说明 | `13 / ink2 / lh1.7 / max-width 250` | 「读到喜欢的文章，点右上角的书签就能存下来，以后随时回来重读。」 |
| **引导行** | `12 / ink3` · gap 7 | 「在卡片上找这个 **[书签方块]** 图标」 |

**两个实现决策（附理由）**：

1. **圆环用 `Clay(pressed)` 而非手写 `BoxShadow(blurStyle: inner)`**
   → 凹陷的 inset **方向、色值、几何缩放全由 token 决定**（三档自动适配）。
   手写会把墨/格/夜三套数值复制到页面层，改 token 时漏改。
   ⚠️ 设计稿把 inset 写死为 `4px 4px 10px`/`-3px -3px 8px` —— 本实现按项目惯例**取 token 缩放档**
   （同 `_ClayTabBar` 选中态：spec §3.3.1 明文「选中态与默认态共用同一套内阴影」）。

2. **引导行里的小方块刻意*不*复用 `BookmarkButton`**
   → 那是**带状态与交互语义的控件**：`onPressed: null` 会走「禁用」分支
   （透明度 0.45 + 去掉按下动效），而设计稿这里要的是**正常观感的示意图形**。
   → 用装饰性小方块更诚实：**它本来就不可点**。
   但**沿用同一视觉语言**（比例取自 `.bm` 的 30px 基准）：
   圆角 `10×24/30 = 8` · 图标 `15×24/30 = 12` · 底 `sunken` + `Clay(pressed)`。

### 2.4 ⚠️ 一处**设计稿未定义**的态：库不可用

`bookmarkListProvider` 在 `user.db` 打开失败时会失败。**设计稿没有这个态**。

🔴 **不能沿用空状态的「还没有收藏的文章」** —— 那是**谎报**：用户明明收藏过，只是库暂时打不开。
本项目既定原则：「**静默失败 / 误导性提示 比报错更糟**」。

→ 取最小诚实表达：「收藏暂时读不出来，重启应用可再试。」

🔑 同理，**加载中不画空状态**（否则有收藏时会先闪一下「还没有收藏」= 也是对用户的谎报）。

### 2.5 数据流：为什么新加一个 `bookmarkListProvider`

`bookmarkProvider` 的 state 是 `Set<int>` —— **集合没有顺序**，
而清单排序是设计明确要求的（「时间戳 DESC —— 『我刚存了什么』的直觉」）。

```dart
final bookmarkListProvider = FutureProvider<List<Bookmark>>((ref) async {
  await ref.watch(bookmarkProvider.future);   // 🔑 watch 而非 read
  final repo = ref.read(bookmarkProvider.notifier).repository;
  return repo == null ? const <Bookmark>[] : repo.list();
});
```

🔑 **`watch` 而不是 `read`**（沿用 3.32 的教训）：
· 只 `read` → 不等仓储就绪 → **第一次打开清单必然是空**
· `watch` 还带来必要行为：**收藏变化后清单自动刷新** ——
  `BookmarkNotifier.toggle` 每次都会 `state = AsyncData(...)` → 本 provider 重算
  → **在清单里点掉一个收藏，它立刻从列表消失**（不用手写 `setState`）

---

## 三、改动清单

| 文件 | 改动 |
|---|---|
| 🆕 `screens/bookmark_list_screen.dart` | 收藏清单页（标题栏 + 副标题 + 列表 + 空状态 + 库不可用态） |
| 🆕 `widgets/bookmark_toggle.dart` | 共用的「切换收藏 + 轻提示」 |
| `providers/bookmark_provider.dart` | 新增 `bookmarkListProvider`（有序清单） |
| `screens/home_screen.dart` | 标题栏加 `_BookmarkEntry`（`.bm-entry`）；`_toggleBookmark` 改调共用函数 |
| `app.dart` | `/home` 下加子路由 `bookmarks` |
| `scripts/tokens_verify/` | 新增 §14（18 条断言） |

### 3.1 入口（`.bm-entry`）—— 它是**凹陷**的

```css
.bm-entry{...color:var(--accent);background:var(--sunken);border-radius:13px;
  box-shadow:inset 2px 2px 6px var(--cl-shade), inset -2px -2px 5px var(--cl-light)}
```

🔑 **`sunken` 底 + 两个 inset、无外阴影 = 粘土语汇里的 `pressed`（凹陷）** ——
与 `BookmarkButton` 的**未收藏态同一种物理形态**：**凹陷 = 「可以按下去」**。
这不是巧合，设计稿把「未激活的入口」统一做成凹陷。

⚠️ 圆角显式传 `13`（不走 token 档位）—— 与 `_ClayTabBar` 的 17、`BookmarkButton` 的 10 同一处理
（设计稿写死、不在主题变量里 → 三档共用）。

---

## 四、验证

| 验收 | 改前 | 改后 |
|---|---|---|
| `analyze_inproc` | 76 文件 · error=0 | ✅ **78 文件 · error=0** / warning=13 / info=4 |
| `verify_tokens` | 337 | ✅ **355**（+18） |
| `verify_bookmark` | 52 | ✅ 52 |
| `verify_word_query` / `pos_display` / `review_list` / `worddb_sync` / `worddb_bootstrap` | 42/31/37/6/22 | ✅ 全不变 |

### 4.1 新增断言（18 条 · 每类对应一个已定义的失效方式）

| 类 | 断言 |
|---|---|
| **文件** | 两个新文件存在 |
| **路由形态** | 编在 shell 分支内（相对路径）· **未做成顶层路由** |
| **复用而非重写** | 用 `FeedCard` · **未自行拼卡片元信息**（不许绕过 `FeedItem.meta`） |
| **空状态教学性** | 存在 · 用 `Clay(pressed)` 凹陷圆环 · 有「在卡片上找这个」引导行 · 用真实书签图标 |
| **共用交互** | 两处都调 `toggleBookmarkWithToast` · **toast 文案只在共用函数里定义一次** |
| **入口** | 首页有 `_BookmarkEntry` · 指向 `/home/bookmarks` · 显示计数 |
| **extendBody 配套** | 清单页底部用 `CoSpacing.tabBarClearance` |
| **不撒谎** | 库不可用态有独立处理 |

### 4.2 证伪测试（临时副本，生产文件未碰）

三处篡改 → **全部准确报红**：

| 篡改 | 结果 |
|---|---|
| `path: 'bookmarks'` → `path: '/bookmarks'`（改顶层路由） | 🔴 **两条路由断言同时报红** ✅ |
| 清单页自拼元信息（真实代码，非注释） | 🔴 准确报红 ✅ |
| —— | 其余 15 条**仍绿** → 断言独立、各司其职 ✅ |

> 🔑 中途一次失误也算收获：第一版把篡改写进了**注释**，断言**没有报红** ——
> 这反而**验证了 `_codeOnly()` 的注释过滤正确工作**（注释不算代码）。
> 改成真实代码后立刻报红。

---

## 五、⏳ 待真机确认

- [ ] 首页标题栏「收藏 N」入口可见、计数正确、点击进入清单
- [ ] 清单页**保留底部 tabbar**，点「阅读」tab 能回到信息流
- [ ] 卡片按**收藏时间倒序**（最近收藏在最上）
- [ ] 点清单里的书签 → 该项**立刻从列表消失** + toast「已取消收藏」
- [ ] 点卡片 → 进阅读器；返回后仍在清单页
- [ ] 全部取消后 → 空状态（凹陷圆环 + 引导行），书签小方块观感与卡片上的一致
- [ ] 三档主题（墨/格/夜）下空状态圆环与入口的凹陷可辨

> ⚠️ 需重新 `flutter build`（**用官方 SDK 全路径**，见
> `android-build-failed-wrong-flutter-sdk-2026-09-27.md`）

---

## 六、遗留与后续

| 项 | 说明 |
|---|---|
| **内容源仍是 mock** | 收藏里可能出现**本端没有内容的 id** → 当前**跳过 + 日志**。<br>⚠️ **Phase 3 接真 feed 后要改成「按 id 查内容」**（代码内已标 TODO） |
| **返回可发现性** | 见 §2.1 的 ⏳ —— 设计稿备有 `.bm-hd .back`，若需要追加成本很低 |
| **3.4c** | `user_word` / `lookup_event` 查词写入（收藏清单做完后的下一步） |
| **`user_word` 表尚未建** | `user_db_schema.sql` 末尾注明「待后续迁移一并落库」 |
