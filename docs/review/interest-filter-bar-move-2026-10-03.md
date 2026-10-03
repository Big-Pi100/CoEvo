# 兴趣筛选移到信息流页顶部（下拉栏）· 实施报告

> 2026-10-03 ｜ 白哥：「CI 已经绿了；真机测试筛选正常，但 **UI 设计不好**，把兴趣筛选做成**下拉栏**吧，如何？；**同意流程建议**」
> 📌 本轮属 **「撤回已定案」** ⇒ 按项目判据做**一组动作**（实现 / 锚点 / 规格 / 断言 / 设计稿）。

---

## 一、先回前两条

### ① CI 绿了 ⇒ 「判据对齐」修正有效

上一轮把 `scripts/codestatic` 的判定从「只过滤 `error`」改为「**error + warning 判失败**」（对齐 CI 的 `--no-fatal-infos`）后，CI 转绿。
⇒ 反向印证：**那条致命的确实是内建 `warning`（`unused_import`）**，且本地工具此前**漏掉了整档 warning**。

### ② 流程建议已入册（项目约定）

写入 `MEMORY.md` 的「工作风格」段：

```
🔴 改了 app/lib ⇒ 先推 main 让 CI 跑 frontend（权威·含 lint）再出包（推 main 不部署·成本≈0）〔白哥 10-03 同意〕
```

**为什么值得入约定**：`flutter analyze` 是**权威判据**（含 lint 与全部 warning），而本机工具
**不覆盖 lint**（接 lint 需 `package:analyzer/src/lint/registry.dart` —— `src/` 内部 API，脆弱）。
推 main **不触发部署**（部署 job 都要 tag）⇒ 成本≈0。

---

## 二、🔑 一个关键判断：真问题是**位置**，不是形态

白哥提「做成下拉栏」，但核实后发现**更根本的问题**：

```
原路径：信息流 → 切「我的」tab → 找到「内容偏好」→ 点胶囊 → 切回信息流
        （4 步，且筛选器与「被它筛的东西」不在同一屏）
```

兴趣筛选本质是「**看信息流的前置控制**」。放在设置页 ⇒ **语义错位**，
所以用起来别扭 —— 用户只会说「这功能不好用」，**不会说「它不该在这一页」**。

> 📌 **新判据（已写入规格 §10.3.2）**：**「控件属于哪一屏」比「它是什么形态」更根本。**
> 形态错了只是**难看**；位置错了让用户**走冤枉路**，且**不易被归因**。
> ⇒ 加一个「设置项」前先问：**它是不是某个具体页面的「前置控制」？** 是 ⇒ 放那一页。

### 为什么先请示再动手（没直接开干）

「下拉栏」有**两种理解**（信息流顶部 / 「我的」页内），且**涉及撤回我刚做的「我的」页分组**。
按判据「**撤回已定案 = 一组动作**」，先核实 + 请示，避免做错方向。
**白哥定**：位置 = **信息流页顶部** · 收起方式 = **再点标题收起**。

---

## 三、实施：一组动作（6 处同步）

| # | 动作 | 文件 | 说明 |
|---|---|---|---|
| 1 | **实现** | 🆕 `app/lib/widgets/interest_filter_bar.dart` | 自包含组件 |
| 2 | 接入 | `app/lib/screens/home_screen.dart` | 标题栏下插 `const InterestFilterBar()` |
| 3 | **移除** | `app/lib/screens/profile_screen.dart` | 删分组调用 + 2 个方法 + 3 个 import（1511 → **1362 行**）|
| 4 | **锚点** | `visual-feed-bookmark-2026-09-25.html` | 新增 `.feed-filt`/`.filt-chip` CSS + HTML 示意 |
| 4 | **锚点** | `profile-redesign-2026-09-29.html` | 移除 2 处「内容偏好」组 → 换说明注释 |
| 5 | **规格** | `implementation-plan-v2 §10.3.2` | 位置变更 + 新判据 |
| 5 | **规格** | `profile-redesign-plan-2026-09-29.md` | 顶部更正块 + 2 处 inline 标注 |
| 5 | **规格** | `ui-ux-refactor-assessment-2026-09-25.md` | 顶部「⚠️ 局部更正」块 + 决策表标注 |
| 6 | **断言** | `scripts/query_verify/bin/verify_feed_wiring.dart` | 【9b】改指向新文件 + 新增【10】组 | 59 → **68 项** |

> 📌 **规格一律「标注而非删除」**（保留决策演变可追溯）：
> · `implementation-plan-v2 §10.3.1` 的旧值（7 类）上轮就没改写；
> · `profile-redesign-plan` / `ui-ux-refactor-assessment` 用**顶部更正块** + inline 标注；
> · 后者已**有先例**（该文顶部本就有「⛔ 局部作废（2026-10-01）」块）—— 照它的形式写。

---

## 四、设计要点（每条都写进了代码注释）

### 4.1 为什么是**自包含**组件

· **自己 `ref.watch(interestProvider)`** ⇒ 与 `home_screen` 的 `_feedKey`
  （`interestKeyOf(ref.watch(interestProvider).valueOrNull)`）**天然同步** ——
  两者读**同一个 provider**，不存在「界面显示 A、实际请求 B」的漂移。
· **展开态是纯 UI 状态**（不持久化、不进 provider）⇒ 放组件自己的 `State`。
  `home_screen` 只需一行 `const InterestFilterBar()`。

### 4.2 🔑 形态变了，但**胶囊不变**

展开面板里的 12 个类别胶囊与「我的」页原来的实现**逐字相同**
（`Clay(state: selected)` ⇒ 自动 accent 填充 + `accentInk` 压字 + `accentOut` 外阴影）。
⇒ **已真机验证过的那部分不重做**（本轮改动只动「收纳方式」，不动「胶囊本身」）。

**变的是**：平时**收起**成一行 `[全部 ▾]`，点击**就地向下展开**，**再点标题收起**。

### 4.3 ⚠️ 为什么没用公共组件 `HeaderChip`（如实记录取舍）

`HeaderChip` 是本项目「标题栏药丸」的**唯一权威定义**，项目判据是「**同一外观只有一处定义**」。
这里却自绘了 `_TriggerChip`，理由是**结构性的**：

· 它需要尾部有一个**展开指示**（`▾`，展开时旋转 180°）；
  而 `HeaderChip` 的尾部位置是 `count`（`int`）—— **放不下任意 widget**；
  它的 `icon` 在**左侧**（语义是「这是什么」，不是「可以展开」）。
· 它**不需要** `labelReserve` 定宽（定宽是为解决「在标题栏里与别的元素并排时抖动」；
  本 chip **独占一行左侧**，无对齐依赖）。

🔑 但**逐个复制了 `HeaderChip` 的样式常量**：圆角 13 · 字号 11.5 w600 · `accent` 色 ·
   padding 7×12 · `pressed + sunken` 的**凹陷**形态 ——
   **形态语汇必须一致，只是允许结构不同**（与 `HeaderChip` 类文档里
   「两处结构不同是有意的，但形态完全共用」是同一条理由）。

📌 **并写明**：若将来**第三处**也需要这种「带展开指示的药丸」，就该抽公共组件了 ——
**两处可以各画一个，三处不行**（那时漂移概率高到不值得）。

### 4.4 「再点标题收起」⇒ 面板里**不放「完成」**

收起动作**只有一处出口**（点标题），不制造第二个。
但**保留「清除」** —— 语义不同：**收起** = 藏起面板（勾选仍在），**清除** = 取消全部勾选。
（仅在有勾选时出现。）

### 4.5 展开动画

`AnimatedSize`（180ms · `easeOutCubic` · `alignment: topCenter`）+ 指示图标的
`AnimatedRotation`（同一时长/曲线）—— **两个动画同一节奏**。
⚠️ 收起态用 `SizedBox(width: double.infinity)`（**不是** `SizedBox.shrink()`）：
后者的宽度为 0，展开时会**同时从 0 宽拉伸到全宽**（横向拉伸感，很怪）。

---

## 五、验证（4 层 · 全过）

| # | 项 | 结果 |
|---|---|---|
| ① | **符号解析**（整包 **103 个 .dart** · **编译级**）| **error 0 · warning 0** ✅ |
| ② | `trace_verify` 4 个脚本 | 退出码全 0 ✅ |
| ③ | `verify_feed_wiring`（接线断言）| **68 项**全过 ✅ |
| ④ | 语法（5 个改动文件）| 全 ✅ |

### 证伪 4 项（含**反证伪**）

```
① 把 InterestFilterBar 塞回 profile      ⇒ 【10】红 ✅「我的页不再有筛选」精准命中
② 删掉 home 的 const InterestFilterBar() ⇒ 【10】红 ✅「信息流页引用了筛选栏」精准命中
③ 筛选栏不 watch provider                ⇒ 「自包含」断言红 ✅
④ 反证伪：只改 trigger 文案（纯重构）      ⇒ **仍全绿** ✅（证明「不锁拼写」成立）
```

三次注入均**字节级还原**（md5 前后一致），收尾比对三份源码**逐字节一致** ✅

### 新增的【10】组断言（**撤回防回归**）

```dart
check('🔴 信息流页**引用了**筛选栏', home.contains('InterestFilterBar'));
check('🔴「我的」页**不再**有筛选（撤回防回归：别把它放回去）', !profile.contains('InterestFilterBar'));
check('🔴「我的」页不再引用 `kCategoryLabels`（分组确已移除）', !profile.contains('kCategoryLabels'));
check('筛选栏是**自包含**的（自己 watch provider ⇒ 与 `_feedKey` 天然同步）', filterBar.contains('ref.watch(interestProvider)'));
check('`interestKeyOf` 仍由信息流页用来定 family key', home.contains('interestKeyOf('));
```

> 🔑 同时把【9b】的「兴趣界面用裸名引用 `kCategoryLabels`」**改指向新文件** ——
> **断言必须跟着「当前用它的地方」走**，否则撤回后会**假红**。

---

## 六、🐛 本轮自己踩的一个坑（如实记录）

**证伪③ 首跑没红 ⇒ 差点误判「断言判别力不足」。**

```
注入：replace('ref.watch(interestProvider)', 'const _x', 1)   ← 只换 1 处
结果：断言仍绿（rc=0）
```

**真因**：该字符串在文件里出现 **2 次** —— 第一次在**类文档注释**里
（`/// （interestKeyOf(ref.watch(interestProvider).valueOrNull)）天然同步`），
而 `readNoComment` **会剥掉注释** ⇒ 断言根本看不到它。
⇒ 我换掉的是注释里那处，**代码里那处没动**。

> 📌 判据：**注入回归时必须确认「改的是代码路径」，不是注释/文档。**
> 做法：① 先 `grep` 数出现次数 ② 用**无 count 的全局替换** ③ 或选**含上下文的长锚点**。

✅ 改成全局替换后，该断言精确命中 ⇒ 门禁有效。

---

## 七、⏳ 待白哥

1. **先推 main 看 CI**（本轮新约定的**第一次实践**）—— 我看不到私有仓库状态。
2. **再出包**（命令不变）：
   ```bat
   cd E:\CoEvo\app
   D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
   ```
3. **真机重点看 6 件事**：
   ① 信息流顶部出现 `[全部 ▾]` · ② 点它向下展开 12 个胶囊（**动画是否顺**）
   ③ 勾一类 ⇒ 列表只剩该类 · ④ **再点标题收起**（勾选保留）
   ⑤ 勾空类（如 `family`）⇒ 空状态说清 + 给「查看全部」· ⑥ 杀 App 重开**选择仍在**
4. **「我的」页**：确认「内容偏好」组已消失，且**其余分组编号连续**（③ 订阅 / ④ 其他 / ⑤ 退出）。

> ⚠️ **未做**（沿用上轮的已知取舍）：已设兴趣的用户，首帧仍会以「全部」发一次请求，
> prefs 就绪后切 key ⇒ **可能多发一次请求**。彻底消除需在 `main()` 预载 prefs（动启动路径）。

---

## 八、产出清单

| 类型 | 文件 |
|---|---|
| 🆕 实现 | `app/lib/widgets/interest_filter_bar.dart`（含完整设计依据：为什么自包含 / 为什么不用 HeaderChip / 动画取舍）|
| 改动 | `app/lib/screens/home_screen.dart`（+import · +1 行接入）|
| 改动 | `app/lib/screens/profile_screen.dart`（−149 行：分组 + 2 方法 + 3 import · 分组编号顺延）|
| 锚点 | `docs/design/visual-feed-bookmark-2026-09-25.html` · `docs/design/profile-redesign-2026-09-29.html` |
| 规格 | `docs/design/english-app-implementation-plan-v2-2026-09-25.md` · `profile-redesign-plan-2026-09-29.md` · `ui-ux-refactor-assessment-2026-09-25.md` |
| 断言 | `scripts/query_verify/bin/verify_feed_wiring.dart`（新增【10】组 · 59 → 68 项）|
| 记忆 | `MEMORY.md`（兴趣筛选位置 + **流程约定入册**）· `ARCHIVE.md §二十`（第七次分层）· 日志【第十三轮】|
