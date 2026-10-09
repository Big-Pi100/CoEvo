# 通知面板「外壳」统一 · 方案 + 实施记录（2026-10-09）

> 来源：`docs/review/product-backlog-audit-2026-10-06.md` §一.4（「通知『外壳』：功能不缺，是视觉不统一」）
> 状态：✅ **方案 A 已实施**（白哥 2026-10-09 批准：「按方案 A，注意设计统一」）· 见 §六 实施记录

---

## 一、实测现状（本次核对）

| 检查 | 结果 |
|---|---|
| `app/lib/screens/notification_panel.dart:143` | `appBar: AppBar(title: Tw('通知中心'), actions: [ if (unreadCount>0) TextButton('全部已读 ($unreadCount)') ])` |
| 🔴 **它是不是孤例** | **是** —— `grep -rl "appBar: AppBar(" app/lib` ⇒ **全库只有这一个文件** |
| 兄弟页怎么做顶栏 | `highlights_screen` / `bookmark_list_screen` / `reading_tab_screen` / `achievements_screen`：**0 处 `AppBar`**，一律 `Scaffold` + `SafeArea` + **自绘标题行** |
| 设计系统口径（`bookmark_list_screen:98-148`）| 标题：左，`23 / w600 / letterSpacing -0.015em / ink`；右侧动作：`12 / w600 / accent`，包 `InkWell(borderRadius 8)` + `padding(h10,v6)` 撑点击区 |
| 它怎么被打开 | `profile_screen.dart:477` 用 **`MaterialPageRoute` push**（+ `app.dart:267` 另有一处）|

⚠️ 文档里说的「与 `HeaderChip` 不一致」**不准确**：`HeaderChip` 是**药丸**（图标+文字+计数、可点，用于「收藏 N」「全部/已到期」筛选），
**不是页面顶栏**。⇒ 正确的参照物是**兄弟页的自绘标题行**，不是 `HeaderChip`。

---

## 二、🔴 必须一起处理的风险点（这个改动**不是纯视觉**）

当前顶栏**没有手写返回按钮** —— 它是 **`AppBar` 自动插入的**（`MaterialPageRoute` 可 pop 时的默认 leading）。

⇒ **只把 `AppBar` 换成自绘标题行，页面会失去唯一的返回入口。**
📌 这正是 `bookmark_list_screen:101-106` 记录过的事故原形：
「本页原先**没有任何返回入口** → 白哥实测『收藏列表根本没有返回按钮』」。

⇒ 所以本项的真实内容 = **换外壳 + 显式补返回入口**（两件事一起做，缺一不可）。

---

## 三、方案（推荐 A，备选 B）

### 方案 A ⭐ 照 `bookmark_list_screen` 的**完全同形**改（标题左 / 返回右）

```
Scaffold(
  backgroundColor: Color(t.page.argb32),
  body: SafeArea(bottom: false, child: Column([
    ① 标题行：Row(spaceBetween)
        左  Text('通知中心', 23/w600/字距-.015em/ink)
        右  InkWell(→ context.pop())  Text('返回', 12/w600/accent) + padding(h10,v6)
    ② 「全部已读 (N)」：**从顶栏移到副标题行**
        （同 `bookmark_list_screen` 的 `.bm-sub` 位：Padding(22,0,22,16)）
        仅 `unreadCount > 0` 时渲染；文案与动作**逐字不变**
    ③ Expanded( 原来的 body：loading / RefreshIndicator / 空态 / 列表 )
  ])))
```
- ✅ 与兄弟页**逐项同形**（间距 18/2/14/14、字号、字距、`InkWell` 圆角与热区）
- ✅ 返回入口**显式**（不再依赖 `AppBar` 的隐式 leading）
- ✅ 右侧只剩一个元素 ⇒ 不会两个动作撞在一行

### 方案 B 标题左 / 右侧两个（返回 + 全部已读）

- 保持「全部已读」在顶栏，右侧并排两个文字链接
- ⚠️ 代价：右上有两个 12px 链接，**热区相邻易误点**；且与兄弟页的「一个右侧动作」形态不一致
- 适用场景：若白哥觉得「全部已读」放副标题行太深（要多扫一行）

---

## 四、改动面与验证计划

| 项 | 内容 |
|---|---|
| 改动文件 | **1 个**（`screens/notification_panel.dart`）|
| 数据/接口 | **零改动**（纯 UI；`_markAllRead` / `_load` / 未读数逻辑一字不动）|
| 断言 | ① 全库 `appBar: AppBar(` 计数 = **0**（新判据：外壳唯一口径）<br>② `notification_panel` 含自绘标题行 + **显式返回**（防「又没返回入口」）<br>③ 「全部已读」文案与动作**仍在**（从顶栏搬走不等于删）<br>④ 证伪：把返回删掉 ⇒ ② 变红 |
| 本机可验 | `analyze_inproc`（error=0）+ 上面 4 条文本断言（Flutter 渲染本机验不了）|
| 需真机 | 通知中心页：能返回 · 「全部已读」能点 · 未读数为 0 时不显示该动作 |

---

## 五、设计口径的取证（**「设计统一」定的是哪一套**）

白哥强调「注意设计统一」⇒ 先把**设计稿**里的标题栏口径查清（不按代码里哪个多来定）：

| 来源 | 依据 |
|---|---|
| 🔑 **设计稿** `visual-feed-bookmark-2026-09-25.html:174-176` | `.bm-hd{padding:2px 6px 4px; display:flex; align-items:baseline; justify-content:space-between}`<br>`.bm-hd h2{font-size:23px; font-weight:600; letter-spacing:-.015em}`<br>`.bm-hd .back{font-size:12px; color:var(--accent); font-weight:600}` |
| 同族的其他标题栏（同一份锚点/主题稿）| `.feed-hd`（`h2` 24/w600/字距-.015em + `.dt`）· `.rev-hd`（`h2` 24 + **`.cnt` 12/w600/accent**）· `.ach-hd`（`h2` 24 + `p` 12.5/ink3）|
| ⇒ **统一口径** | **大标题左（23–24 / w600 / 字距 -.015em）+ 右侧一个元素（12 / w600 / accent）**，`space-between` |
| 设计稿里**没有**「通知中心」这一屏 | ⇒ 它是**实现期新增**页面，只能照**同族**（子视图标题栏）：用 `.bm-hd` |
| ⚠️ 全库另有第二套顶栏（`achievements_screen._TopBar`：「‹ 返回」+ 小标题居中）| **无设计稿依据**（设计稿里返回在**右**）⇒ 属存量第二口径，**本次不扩散、不跟随** |

🔑 **取舍（如实标注）**：设计稿里**一页只有一个右侧元素**（`.back` 或 `.cnt`），
而通知中心有**两个**次要元素（返回 + 全部已读）。
⇒ 处置：**返回留在设计稿的位置**（右上，`.bm-hd .back` 口径）；
**「全部已读」下移一行**（右对齐，样式沿用同族的 `12/w600/accent`）。
📌 依据：`.rev-hd .cnt` 证明「accent 12/w600 的次要元素」就是这个系统的语言，
所以下移不引入新形态 —— 只是换了行。

---

## 五-b、实施记录（2026-10-09）

| 项 | 内容 |
|---|---|
| 改动文件 | **1 个**：`app/lib/screens/notification_panel.dart`（+ import `coevo_tokens` / `tokens_ext`）|
| 数据/接口 | **零改动**（`_load` / `_markAllRead` / 未读口径 / 列表项一字未动）|
| 关键动作 | ① `appBar: AppBar(...)` → `Scaffold(backgroundColor: page)` + `SafeArea` + 自绘标题行<br>② **显式补返回**（`InkWell` + `context.pop()`，原先是 `AppBar` 隐式给的）<br>③ 「全部已读 (N)」下移一行（文案/动作/条件渲染**逐字保留**）|
| 🆕 新断言 | `scripts/query_verify/bin/verify_notification_shell.dart` —— **33 项**（含跨页共用口径 4 项 + 第二套形态排除 2 项）|
| 改前基线 | **9 通过 / 24 失败**（证明断言确实在检测，不是空转）|
| 改后 | **33 / 0** ✅ |
| 证伪 | **5 条全部变红 + 逐字节还原**：① 返回动作被架空（`onTap: (){}`）② 加回 `AppBar` ③ 抹掉「全部已读」文案 ④ 标题字号改 14（落进第二套）⑤ 抄 shell 内页的 `bottom: false` |
| 静态分析 | `analyze_inproc` **error=0 · warning=0** |
| 回归 | `verify_script_portability` 19 ✅ · `verify_app_version` 6 ✅ · `tokens_verify` **699/8 = 存量基线（无新增）** |
| ⏳ 需真机 | 通知中心页：能返回 · 「全部已读」能点 · 未读为 0 时不显示该动作 |
| ⚠️ **本次踩到的坑（已记）** | 断言第一版**读到了我自己的注释**（我在注释里写了「原来这里是 `appBar: AppBar(`」）⇒ 「应为 0」假红。**判据：文本断言必须先按整行剥注释**（`_codeOnly`）；另修了一处**切片锚点写错**（`Text('通知中心'` 因换行不存在 ⇒ 空切片假红，靠「能切出片段」这条前提断言抓到）|

---

## 五-c、请白哥定（原）

1. **方案 A 还是 B？** ✅ **已定：A**（2026-10-09）
2. 批准后按「先写断言并证伪 → 改码 → 本地验证 → 报出包」执行 ✅ **已执行**（端侧改动，**需出包才生效**）

*2026-10-09 · 只出方案，未动代码*
