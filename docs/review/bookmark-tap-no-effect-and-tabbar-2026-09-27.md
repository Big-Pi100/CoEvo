# 收藏按钮点击无效 · 底部栏背景 —— 调查报告

> 日期：2026-09-27｜来源：白哥真机反馈「收藏按钮点击没用，其他正常」+「底部栏背景能不能改成透明」
> 状态：**已实施**（白哥选「收藏修复 = 方案 A」·「底部栏 = 方案 A」）→ 实施记录见文末第八节

---

## 零、先说一个被顺带证实的结论

「**其他正常**」= **长按弹词卡正常** → `word.db` 那条链
（`rootBundle` → `path_provider` → 33 MB 落盘 → `sqflite` 打开 → 查询）**五环全通**。

这补上了 `verify_worddb_bootstrap.dart:142` 自述「不验」的那两条。
✅ 3.4b 的落盘改造**在真机上确认成立**。

---

## 一、收藏按钮：不是「没接线」，是**按钮被禁用**

### 已排除（每条都有代码证据）

| 怀疑 | 结论 | 证据 |
|---|---|---|
| 按钮没接 `onTap` | ❌ 排除 | `bookmark_button.dart:88` `onTap: onPressed` |
| 父层没传回调 | ❌ 排除 | `feed_card.dart:84-87` 传了 `onPressed: onToggleBookmark` |
| 父层传了 `null` | ⚠️ **只在这条上** | `home_screen.dart:292-294` `bookmarkReady ? () => ... : null` |
| provider 没预热（3.32 那个坑） | ❌ 排除 | `home_screen.dart:232` **`ref.watch(bookmarkProvider)`** ✅ |
| 阅读器里也没接 | ❌ 排除 | `reader_screen.dart:161` 同样 `watch` ✅ |

→ 所以「点击没用」的**唯一**可能是：**`bookmarkReady == false`，按钮处于禁用态**。

### 为什么用户会把它当成「坏了」而不是「禁用」

`bookmark_button.dart:78-79` 的禁用表达是 **`Opacity(0.45)`**：

> ⚠️ 实测观感：`0.45` 在浅色主题（`page #F1EDE4` + `sunken #EDE6DA`）下**不显眼**，
> 加上 `Clay` 在无 `onTap` 时**连按下动效都没有** → 用户感知是「**这个按钮是好的，但点了没反应**」，
> 而不是「它被禁用了」。

🔑 这正是 3.22 那条教训的**反向命中**：当时怕「静默无效的操作」所以改成禁用，
但**禁用态本身不够显眼** → 用户仍然读到「静默无效」。

### 禁用链路

`bookmark_provider.dart:106`：

```dart
bool get isReady => hasValue;   // 只有 AsyncData 才为 true
```

| provider 状态 | `isReady` | 按钮 |
|---|---|---|
| `AsyncLoading`（首次，约 100ms） | false | 禁用（**短暂**） |
| `AsyncData` | true | 可点 |
| **`AsyncError`（打开失败）** | **false** | **永久禁用** ← 🔴 |

→ 白哥看到的是**永久禁用** ⇒ `bookmarkProvider.build()` **抛了异常**。

候选抛出点（`bookmark_provider.dart:45-64`）：
1. `rootBundle.loadString(kUserDbSchemaAsset)` —— 读 assets
2. `getApplicationSupportDirectory()` —— path_provider
3. **`openUserDb(...)` —— 打开库 + 在 `onCreate` 里跑整段 schema 脚本** ← 嫌疑最大

---

## 二、🔴 确凿缺陷：失败**没有任何日志**（我们查不下去的直接原因）

`bookmark_provider.build()` 的注释（第 67-72 行）解释了「刻意不 catch」的语义理由 —— **这个决定是对的**。
但里面漏了一步：**打日志**。

对比同类 provider：

```dart
// word_db_provider.dart:126
debugPrint('[word_db] 词库不可用：$e\n$st');
```

而 `bookmark_provider.dart` 全文**没有一行 `debugPrint` 覆盖 `build()` 的失败路径**
（只有 `toggle()` 失败时的日志，第 92 行）。

**后果**：真机上 `user.db` 打开失败 → 用户看到按钮禁用 → **logcat 里一行都没有**。
→ 我们只能靠读代码推理根因，无法一句日志定位。

> 🔑 违反项目已确立的规则：「**日志必须能定位问题**」（见「日志与超时」一节：
> 认证模块 5 处静默失败就是因为缺日志才拖了很久）。

**这一条无论根因是什么都必须补。**

---

## 三、高嫌疑根因：`user_db_schema.sql` 里的 `PRAGMA journal_mode = WAL`

### 3.1 证据链（源码级，非猜测）

| # | 事实 | 出处 |
|---|---|---|
| 1 | schema 第 **16-17** 行有两条 PRAGMA，会被 `splitSqlStatements` 切出，经 `executeSqlScript` → **`db.execute()`** 逐条执行 | `user_db_schema.sql:16-17` · `user_db.dart:104-108` |
| 2 | `db.execute()` 在 Android 上落到 **`SQLiteDatabase.execSQL()`** | `sqflite_android-2.4.0/.../Database.java:425` |
| 3 | `execSQL()` → `executeSql()` → **`SQLiteStatement.executeUpdateDelete()`** | `SQLiteDatabase.java:2234-2235` |
| 4 | `executeUpdateDelete()` 是**专为「不返回数据的语句」**（INSERT/UPDATE/DELETE）设计的 API | 方法名与 javadoc |
| 5 | Android 官方 javadoc 明文：per-connection 的 PRAGMA **不该**用该方法，应用 `execPerConnectionSQL` | `SQLiteDatabase.java:2195-2198` |
| 6 | `journal_mode` 与 `foreign_keys` **都是 per-connection** PRAGMA | Android 官方文档 |
| 7 | 而 `PRAGMA journal_mode = WAL` 按 SQLite 语义**返回新的日志模式**（有结果行） | SQLite 官方文档 |
| 8 | 且 `onCreate` 在**事务内** → WAL 切换在事务内也不被允许 | `openUserDb` 的 `onCreate` 语义 |

### 3.2 对照组 —— 为什么 `onConfigure` 那条**没事**

`user_db.dart:68`：

```dart
onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
```

`PRAGMA foreign_keys = ON` **不返回结果行**（设置语法；查询语法是 `PRAGMA foreign_keys`）
→ 不触碰第 3-5 条的约束 ✅

### 3.3 🔑 这是「改了一半」

`user_db.dart:66-67` 的注释：

```dart
// 🔴 `PRAGMA foreign_keys` 是**连接级**设置，必须在每次连接时开 ——
//    写在 schema 脚本里只在建表那次生效（且 sqflite 在事务里可能忽略）。
```

作者**已经意识到**「schema 里的 PRAGMA 不可靠」→ 把 `foreign_keys` 搬到了 `onConfigure`，
**但 `journal_mode` 留在了 schema 里**。

→ 典型的「**改了一半**」：迁移的理由对，执行只做了一半。

---

## 四、为什么 49 项验收全过 —— 一个关键盲区

`scripts/query_verify/bin/verify_bookmark.dart` 走的是：

```dart
factory: databaseFactoryFfi,      // ← sqlite3 **FFI**（直调 C API）
```

而 Android 上走的是：

```dart
factory: sqflite.databaseFactory, // ← 平台通道 → Android 系统 SQLiteDatabase
```

### 两条路的差异

| | `databaseFactoryFfi` | Android `databaseFactory` |
|---|---|---|
| 底层 | sqlite3 C API（FFI） | `SQLiteDatabase` |
| `execute()` 落到 | `sqlite3_exec` / `prepare`+`step` | **`execSQL` → `executeUpdateDelete()`** |
| 有无「不许返回数据」限制 | **无** | **有**（第 3-5 条） |

→ 所以 **FFI 上跑得通 ≠ Android 上跑得通**。

🔑 这是「**在错平台验证 → 错平台不报错，掩盖真平台的问题**」的又一实例 ——
与之前那条「**web 无 SQLite 掩盖了 provider 预热 bug**」**同一类**（见 `MEMORY.md` 跨轮教训）。

### ⚠️ 诚实标注置信度

**本根因是源码级推理，置信度高，但未经真机实测确证。**
要 100% 确证必须有 Android 上的异常信息 —— 而当前**恰好缺日志**（第二节）。
→ 所以修复方案把「补日志」与「PRAGMA 归位」**一起做**：即使 PRAGMA 不是真因，补上日志也能一次抓出真因。

---

## 五、修复方案（三选一）

### 方案 A（推荐）· 补日志 + PRAGMA 归位

| 步骤 | 改动 | 文件 |
|---|---|---|
| 1 | `build()` 加 `try/catch`：`debugPrint('[bookmark] user.db 打开失败：$e\n$st')` 后 **`rethrow`**（语义不变，仍是 `AsyncError`） | `bookmark_provider.dart` |
| 2 | 删掉 schema 第 16-17 行两条 PRAGMA（`foreign_keys` 已由 `onConfigure` 覆盖） | `user_db_schema.sql` |
| 3 | `onConfigure` 补 `await db.rawQuery('PRAGMA journal_mode = WAL')` —— 🔴 **必须 `rawQuery` 而非 `execute`**（它会返回结果行） | `user_db.dart` |
| 4 | 断言锁住：① 「schema 里不得再出现 `PRAGMA`」② 「打开后 `journal_mode == 'wal'`」③ 「`foreign_keys == 1`」 | `verify_bookmark.dart` |

**优点**：即使 PRAGMA 不是真因，第 1 步也能让我们**一次**拿到真因；改动小、可回退。
**风险**：低（`rawQuery` 是正确的 PRAGMA 执行方式；就算 WAL 未生效也只是退回默认 DELETE，功能不受影响）。

### 方案 B · 只补日志，先不动 PRAGMA

- 先重装 → 抓 `logcat` → 拿到真实异常 → 再针对性修
- **优点**：零猜测，最严谨
- **缺点**：多一轮真机往返

### 方案 C · 不用 WAL

- 直接删掉 `journal_mode`，保持默认 DELETE
- 依据：**单用户端侧库并发极低**，WAL 的「读写并发」收益有限；且本库写入极少（一次复习一行）
- **代价**：失去 WAL 的崩溃恢复优势
- 备注：这仍是「正确的修复」（删掉了错误用法），但**主动放弃了 WAL**

> **我的建议**：**方案 A**。理由：第 1 步（补日志）无论如何都该做，第 2-3 步修正的是一个
> **已被 Android 官方明文否定**的用法 —— 即使它不是本次真因，留着也是隐患。
> 且这三个改动都可在一次重装里一起验证。

---

## 六、底部栏背景（另一件事）

### 6.1 先纠正一个前提：**改背景为「透明」不会有任何视觉变化**

三处颜色**完全相同**：

| 位置 | 值 |
|---|---|
| `theme_builder.dart:33` `scaffoldBackgroundColor` | `_c(t.page)` |
| `app.dart:221` tabbar 的 `ColoredBox` | `Color(t.page.argb32)` |
| 设计稿 `.phone{background:var(--page)}` | `--page` |

设计稿的 `.tabbar` **本身就无背景色**（只有 `margin-top:auto; z-index:9`）→ 透出的就是 `page`。
→ 代码用 `ColoredBox(page)` 是**显式做同一件事**，不是偏离。

**所以白哥看到的「破坏视觉」不是色差，而是结构。**

### 6.2 「破坏视觉」的真正来源

`Scaffold(bottomNavigationBar:)` 让 tabbar 占据一条**独立地带**，`body` **不含**这块高度：

```
┌─────────────┐
│  内容（可滚动）│
├─────────────┤ ← 内容到此为止
│  空白 36px   │ ← ListView 底部 padding(24) + tabbar 顶部 padding(12)
│  ①   ②   ③  │ ← 三个按钮
│  空白 24px   │ ← SafeArea minimum
└─────────────┘
```

滚动到底时，卡片与按钮之间有一道**静止的空白带**（约 36px + 按钮高度）
→ 观感是「**内容被切掉一块，下面飘着三个按钮**」，而不是「内容一直延伸到按钮之下」。

**这就是「一条栏」的实体感来源 —— 不是颜色，是那道静止空白。**

### 6.3 方案（「透明」的实质 = 让内容延伸进去）

| 步骤 | 改动 |
|---|---|
| 1 | `_ShellScaffold`：`Scaffold` 加 **`extendBody: true`** → body 延伸到 tabbar 之后 |
| 2 | `_ClayTabBar`：背景由「纯色 `page`」→ **自上而下「透明 → `page`」的渐隐遮罩** |
| 3 | 各页滚动容器底部 padding 加大（约 `24` → `96`），让内容能滚到按钮上方停住 |

**为什么第 2 步要渐隐，不能纯透明**：
`extendBody` 后内容会从按钮**背后**穿过，而按钮多数是**无底的**（未选中项无背景）
→ 不遮的话会**与按钮文字硬叠**，比现在还难看。
渐隐让内容在接近按钮时**柔和淡出** → 视觉上「没有硬边界」= 观感上的「透明」。
三档主题各自用**自己的 `page` 色**做渐隐终点 → 自动适配。

### ⚠️ 6.4 需要白哥确认的一点

**第 2 步的「渐隐遮罩」是设计稿里没有的元素**（设计稿 `.tabbar` 无背景）。

按项目规则「设计稿与 spec 冲突时按 spec / 不擅自加设计稿没有的东西」——
所以这里**必须请示**，不能默默加。

三个可选：
- **A｜渐隐遮罩 + 内容穿透**（推荐）：最接近「透明」的观感，且不叠字
- **B｜纯透明 + 内容穿透**：贴设计稿（无背景），但滚动中内容会与按钮文字叠
- **C｜保持现状，只把空白带缩小**：不动结构，把 36px 空白压到 12px，弱化「栏」的实体感

---

## 七、影响范围与验证

| 项 | 说明 |
|---|---|
| 改动文件（方案 A） | `bookmark_provider.dart` · `user_db_schema.sql` · `user_db.dart` · `verify_bookmark.dart` |
| 改动文件（底部栏） | `app.dart`（`_ShellScaffold` + `_ClayTabBar`）+ 各页滚动容器 padding |
| 需重新验收 | `query_verify`（6 个脚本）· `tokens_verify` · `trace_verify` |
| 需重新构建 | `flutter build apk --debug`（约 11 分钟，Gradle 缓存已热） |
| 真机验证 | ① 收藏按钮可点 + toast 出现 ② 杀掉重开 → 收藏保持 ③ 底部栏滚动观感 |

> ⚠️ 底部栏第 3 步（各页底部 padding）**需要逐个页面确认**，影响范围已核实：
>
> | 页面 | 路由 | 在 Shell 内？ | 受影响 |
> |---|---|---|---|
> | 信息流 | `/home` | ✅ | **需改** |
> | 复习 | `/review` | ✅ | 待确认（`review_screen` 列表容器） |
> | 我的 | `/mine` | ✅ | 待确认（`profile_screen`） |
> | 阅读器 | `/article/:id` | ❌ **顶层路由**（`pageBuilder` + 右滑转场） | **不受影响** ✅ |
> | chat / pay / notifications | 同名 | ❌ 顶层 | **不受影响** ✅ |
>
> 🔑 `app.dart:78-82` 的注释已定案：「阅读器**全屏**（spec §5.1「底部：无」）」
> → 所以 tabbar 改动**只影响三个 tab 页**，面可控。

---

## 八、实施记录（2026-09-27）

### 8.1 收藏按钮 · 方案 A

| # | 文件 | 改动 |
|---|---|---|
| 1 | `providers/bookmark_provider.dart` | `build()` 包 `try/catch` → `debugPrint('[bookmark] user.db 打开失败：$e\n$st')` + **`rethrow`**（语义不变，仍是 `AsyncError`；只是多了可查的痕迹） |
| 2 | `assets/sql/user_db_schema.sql` | 删掉两条 `PRAGMA`，改为**说明为什么不能放这里**（含源码级理由） |
| 3 | `services/user_db.dart` | `onConfigure` 改为 async：`execute('PRAGMA foreign_keys = ON')` + **`rawQuery('PRAGMA journal_mode = WAL')`**（🔴 必须 rawQuery） |
| 4 | `scripts/query_verify/bin/verify_bookmark.dart` | 新增 3 条断言（见 8.3） |

### 8.2 底部栏 · 方案 A（三处配套）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `app.dart` `_ShellScaffold` | 加 **`extendBody: true`** |
| 2 | `app.dart` `_ClayTabBar` | `ColoredBox(page)` → **`DecoratedBox` + `LinearGradient`（透明 → `page`，`stops: [0, 0.55]`）**；类文档补「偏离 3」 |
| 3 | `theme/co_spacing.dart` | 新增 **`tabBarClearance = 100`**（附高度估算依据与耦合说明） |
| 4 | `screens/home_screen.dart` · `review_screen.dart` · `profile_screen.dart` | 滚动容器底部 padding 改用 `CoSpacing.tabBarClearance` |
| 5 | `scripts/tokens_verify/bin/verify_tokens.dart` | 新增 **`_s13TabBarShell()`**，锁住「三处必须同时存在」（见 8.3） |

> 🔑 第 3-4 步特意**抽成常量**而不是各写 `100`：本项目已踩过
> 「token 层有定义、调用处又写裸值」的坑 —— 断言同时验「用了常量」+「没有裸值」。

### 8.3 验证结果

| 验收 | 改前 | 改后 |
|---|---|---|
| `analyze_inproc`（app/lib 76 文件） | error=0 / warning=13 / info=4 | ✅ **error=0** / warning=13 / info=4 |
| `verify_bookmark` | 49 项 | ✅ **52 项**（+3） |
| `verify_tokens` | 308 项 | ✅ **319 项**（+11） |
| `verify_trace` | ✅ | ✅ |
| `verify_word_query` / `pos_display` / `review_list` / `worddb_sync` / `worddb_bootstrap` | 42 / 31 / 37 / 6 / 22 | ✅ 全部不变 |

**新增断言（14 条）**

`verify_bookmark`【2.0】：
1. schema 里不得出现 `PRAGMA`（**先滤注释行** —— 否则文件顶部那段「为什么不能放」的说明会假红）
2. `journal_mode == 'wal'`（证明 `rawQuery` 真的生效）
3. `foreign_keys == 1`

`verify_tokens`【13】`_s13TabBarShell()`（11 条）：
4. `extendBody: true` 存在
5-6. tabbar 用 `LinearGradient` 且终点取 token 的 `page`
7. tabbar 背景不再是纯色 `ColoredBox`
8-13. 三个 tab 页各自：用了 `CoSpacing.tabBarClearance` + **没有裸值 `100`**
14. `tabBarClearance = 100`（与 `_ClayTabBar` 内边距耦合）

### 8.4 两次**证伪测试**（证明断言不是摆设）

| 断言 | 故意造错 | 结果 |
|---|---|---|
| `schema 里不得出现 PRAGMA` | 用临时 schema（含那两条 PRAGMA）跑 | ✅ **51 过 / 1 红** |
| 三处 padding 断言 | `home_screen` 改回裸值 `100` | ✅ **317 过 / 2 红** |

🔑 **第一次证伪里有个关键细节**：加回 PRAGMA 后，
「`journal_mode == 'wal'`」这条**仍然通过** ——
因为 **FFI 下那两个 PRAGMA 照样执行成功**。
→ **完美印证了第三节的盲区分析**：运行期在错平台**抓不到**，只有静态断言能挡。

### 8.5 ⏳ 待真机复验

1. 收藏按钮**可点**，点后出现 toast「已收藏 · 可在「收藏」里重读」
2. 杀掉 App 重开 → 收藏仍在（验真落盘）
3. 若仍不可点 → `logcat | grep bookmark` **现在能看到真实异常**了（这是本次的主要价值）
4. 底部栏：滚动到底时正文**淡出**在按钮之下，最后一张卡不被压住
5. 三档主题（墨 / 格 / 夜）下渐隐终点均为各自的 `page` 色

> ⚠️ 需重新 `flutter build apk --debug`（Gradle 缓存已热，约 11 分钟）

---

## 九、二次修正（2026-09-27 22:30）

### 9.1 ✅ 收藏按钮：**真机验证通过**

白哥反馈「**收藏好了**」→ 第三节的根因（`PRAGMA journal_mode = WAL` 在 Android 走 `execSQL` 被拒）
**得到真机实证**。这是本条记录最重要的结果。

### 9.2 🔴 底部栏：渐隐 → **改为完全透明**

> 白哥：「底部还是改成透明吧，**渐变不好看**」

**渐变为什么不好看**（如实记录，避免反复）：

渐变区覆盖 tabbar 上半段（`stops: [0, 0.55]`）→
当**白色卡片**滚进这块区域时，卡片下边缘会被**逐层雾化淡出**，形成一条**看得见的雾带**。
端点色与底色相同**消不掉它** —— 因为被雾化的是**穿过的卡片**，不是背景。
（这正是 6.2 节「静止空白」分析里没预见到的：我以为只需要处理「静止时的空白」，
实际滚动中「内容被雾化」同样显眼。）

**改为透明** = 回归设计稿原意（`.tabbar` **本就没有背景色**），不再算「偏离」。

| 文件 | 改动 |
|---|---|
| `app.dart` `_ClayTabBar.build` | 删掉 `DecoratedBox` + `LinearGradient` → 直接返回 `SafeArea` |
| `app.dart` 类文档 | 「偏离 3」→ 改为「✅ 背景：透明，与设计稿一致」+ 演进史表 |
| `app.dart` `_ShellScaffold` | 配套说明由「三处」→「两处」（背景项不再需要） |
| `tokens_verify` §13 | 断言由「必须有渐变」→「**不得有任何背景层**」 |

### 9.3 ⚠️ 透明的代价（如实记录）

滚动过程中，正文会与**未选中的** tab 文字重叠：

| tab | 有无底色 | 是否受影响 |
|---|---|---|
| 选中 | ✅ `Clay(selected)` 实心 `accent` 底 | **不受影响** |
| **未选中** | ❌ 仅 `ink3` 色图标与文字、**无底** | **会叠** |
| 静止（滚到底） | —— | **不叠**（各页已留 `CoSpacing.tabBarClearance`） |

**若实测影响阅读**，三个备选（按「不引入新设计元素」排序）：
1. **均匀半透明底** `page.withAlpha(0xCC)` —— 非渐变、内容隐约透出、文字清晰；**一行改动**
2. `BackdropFilter` **毛玻璃** —— iOS 原生观感，但引入 `dart:ui` 滤镜
3. **极窄渐变** `stops: [0.0, 0.18]` —— 视觉上接近透明

> 🔑 **不默默选** —— 等白哥看实际效果后再定。

### 9.4 断言范围的教训（🔴 本轮踩到并修正）

首版断言写的是**全文件**范围：

```dart
check('tabbar 也没有用 Container(color:) 隐式铺底',
    !RegExp(r'Container\(\s*color:').hasMatch(app));   // ← 拿整个 app.dart 当范围
```

→ **立刻被撞红**：`app.dart:424` 有**订阅弹窗的遮罩** `Container(color: Colors.black54)`，
那处**完全合法**（modal barrier），与 tabbar 毫无关系。

🔑 **教训：断言的范围必须等于被测对象的范围。**
范围过宽 → 「真红」与「假红」混在一起 → 久了就没人信断言了。

**修法**：先切出 `_ClayTabBar` 类体，再在类体内断言：

```dart
final clsStart = app.indexOf('class _ClayTabBar');
final clsEnd   = clsStart < 0 ? -1 : app.indexOf('\nclass ', clsStart + 1);
final tabBar   = clsStart < 0 ? '' : app.substring(clsStart, clsEnd < 0 ? app.length : clsEnd);
```

并**额外加一条前置断言**「能切出 `_ClayTabBar` 类体」—— 否则切片失败会静默变成空串，
让后面几条断言**因为「空串不含任何东西」而假绿**（🔑 「凡有兜底，须另设断言独立判是否命中」）。

### 9.5 验证结果

| 验收 | 结果 |
|---|---|
| `verify_tokens` | ✅ **320 项**（318 + 切片断言 + Container 断言） |
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4 |

**证伪测试（临时副本方式，零风险）**：
复制整个 `app/lib` 到临时目录 → 在副本里给 `_ClayTabBar` **加回 `ColoredBox` 背景** → 跑断言：

```
🔴 _ClayTabBar 不加背景层（透明 · 与设计稿 `.tabbar` 无背景一致）   ← 准确报红 ✅
✅ _ClayTabBar 没有用 Container(color:) 隐式铺底                  ← 仍绿（篡改的是 ColoredBox）
✅ _ClayTabBar 未用渐变                                            ← 仍绿
```
→ 三条断言**互相独立、各司其职** ✅
（另有 6 项红是临时目录里的假 `pubspec.yaml` 缺字体声明所致，属环境噪音）

> 🔑 **证伪测试用「临时副本」而非改生产文件**：`_repoRoot()` 是从 `Directory.current`
> 往上找 `app/pubspec.yaml` → 所以只要在临时目录造出 `app/pubspec.yaml` + `app/lib/`，
> 再 `cd` 过去跑同一个脚本，**读的就是副本** → 生产文件一行都不用碰。

### 9.6 ⏳ 待复验

- [ ] 重新构建（**注意用官方 SDK 全路径**，见 `android-build-failed-wrong-flutter-sdk-2026-09-27.md`）
- [ ] 底部栏：滚动时正文从按钮下方穿过（**无雾带**）
- [ ] 未选中 tab 文字在滚动中的可读性 —— 若不可读，从 9.3 的三个备选里挑
- [ ] 滚到底：最后一张卡不被压住（回归确认）

---

## 十一、四次修正（2026-09-27 23:10）：未选中 tab 改「凸起」

> 白哥：「**tab 未选中状态的效果是凹陷的，不好看，还是用凸起的视觉效果吧，选中仅改变颜色即可**」

### 11.1 三轮演进（最终形态）

| 轮 | 未选中 | 白哥反馈 |
|---|---|---|
| ① | **无底平坦**（照设计稿 `.tb`） | 「看不清」—— 根因：`extendBody` 后正文从下方穿过 |
| ② | `pressed` + `sunken`（**凹陷**） | 🔴 「**凹陷的，不好看**」 |
| ③ | **`raised`（凸起）** | ✅ 定案 |

### 11.2 🔑 「凸起 + 选中仅改颜色」在 Clay 里**天然配对**

`clay.dart` 的 painter 里 `raised` 与 `selected` **共用同一个 case**：

```dart
case ClayState.raised:
case ClayState.selected:          // ← 同一个 case
  _outer(canvas, rrect, isSelected ? clay.accentOut : clay.out, ...);
```

二者**形状、内阴影、尺寸完全一致**，只差：

| | 填充 | 外阴影色 |
|---|---|---|
| 未选中 `raised` | `clayFill`（= `card`） | `clay.out`（中性） |
| 选中 `selected` | `accent`（朱砂） | `clay.accentOut`（染朱砂） |

→ **不需要任何新参数或新状态**，组件本来就支持。

### 11.3 ⚠️ 不传 `fill`（移除上一轮的 `fill: t.sunken`）

上一轮凹陷态显式传了 `fill: t.sunken` —— 而 `sunken` 的语义**正是「凹陷底」**，
用在凸起上**语义错位**。`raised` 的自然填充就是 `clayFill`（= `card`），不传即正确。

🔑 **凸起的立体感来自外阴影，不是颜色**：实测 `card ↔ page` 对比度仅
**1.17 / 1.16 / 1.18**（三档）→ **单看颜色分不出药丸边界**，边界全由 `clay.out` 给出。
→ **不要为了「显得醒目」给未选中项塞显式 fill**。

### 11.4 字色仍须 `ink2`（换底色救不了 `ink3`）

换底色后重算 —— `ink3` 在**三种**候选底色上**全部不达标**：

| 档 | `ink3` on `page` | `ink3` on `sunken` | `ink3` on `card` | **`ink2` on `card`** |
|---|---|---|---|---|
| 墨 | 2.74 | 2.58 | 3.20 | ✅ **5.66** |
| 格 | 2.97 | 3.03 | 3.45 | ✅ **6.90** |
| 夜 | 4.16 | 4.16 | 3.53 | ✅ **6.29** |

🔑 **死结是 `ink3` 本身**（任何底色都 < 4.5）→ **必须换字色**，不是换底。
⚠️ 代价（如实记录）：`ink2` 让未选中项**比设计稿重一点**（设计稿用 `ink3` 表「次要」）。
→ **可读性优先于层级微差**。

### 11.5 📌 一处遗留**自然消失**

第 ② 轮曾记「夜档 `sunken == page` → 凹陷填充不可见」。
改用 `raised` 后填充是 `clayFill`（= `card` = `#1C1F27`），与 `page`（`#0B0D12`）**不同**
→ **该问题不再存在**。

### 11.6 ✅ 保留的两项收益（来自第 ② 轮）

· **可读**：药丸**不透明** → 正文从下方穿过时不再与文字重叠
· **有按下反馈**：`Clay` 自动提供（按下瞬间 `pressed` 凹陷 → 松手回 `raised`）
  —— 物理隐喻正确：「按下去」就该是凹的（原先裸 `GestureDetector` 时没有反馈）

### 11.7 验证

| 验收 | 结果 |
|---|---|
| `verify_tokens` | ✅ **337 项**（330 + 7） |
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4 |

**断言更新**（锁四个点，缺一就会退回某个被否掉的版本）：
1. 未选中项走 `ClayState.raised`
2. **不再是 `pressed`**（防改回凹陷）
3. **不显式给 `sunken` 填充**（防与 `raised` 语义冲突）
4. 字色用 `ink2`、不用 `ink3`

**对比度硬校验**：`ink2 ↔ clayFill` ≥ 4.5（5.66 / 6.90 / 6.29）
**反向对照扩到 9 条**：`ink3` 在 `page`/`sunken`/`clayFill` **三种**底色上逐档验证 < 4.5
—— 🔑 这样把「为什么不能用 `ink3`」**完整记录下来**，将来 token 一改就会提示复核。

---

## 十二、🔴 新发现：**收藏了的内容没有地方看**

> 白哥：「虽然可以点击收藏，但**收藏了的内容在哪看**？」

### 12.1 现状（已核实）

| 检查 | 结果 |
|---|---|
| `app/lib/screens/` 下有 bookmark/收藏 页面 | ❌ **没有** |
| 路由里有收藏入口 | ❌ **没有**（只有 `/home` `/review` `/mine` `/article/:id` `/chat` `/pay` `/notifications`） |
| 首页标题栏右侧「收藏 N」入口 | ❌ **没放** —— `home_screen.dart:263` 有注释：<br>「右侧「收藏 N」入口属 **3.5**……本批不放，避免出现点了没反应的死入口」 |

→ **收藏目前只写入 `user.db`，没有任何查看入口。这是 3.5（收藏清单）尚未实施导致的，不是 bug。**

### 12.2 好消息：**基础设施已齐，且设计稿写得很完整**

| 依赖 | 状态 |
|---|---|
| `BookmarkRepository.list()` | ✅ 已实现（含 `bookmarkedAt` 倒序、`limit`/`offset`） |
| `bookmarkProvider` | ✅ 已就绪（`idsOrEmpty` / `isReady`） |
| `FeedItem.id` | ✅ **与 `bookmark.content_id` 同源**（`feed_item.dart` 注释明写） |
| `FeedItem.meta` | ✅ 注释：「卡片与**收藏清单共用**的元信息行」→ **模型早就为清单设计好了** |
| 设计稿 | ✅ **有完整定义**（`visual-feed-bookmark` 第 355-407 行） |

**设计稿原话（关键）**：

> 「同一套卡片组件，只是筛选过 —— **没有新界面要设计**。空状态用粘土凹陷圆环 + 引导文案。」
>
> 「空状态要教会用户『书签在哪』，而不是只说『没有内容』。**用真实图标做引导**，用户下次一眼就认出来。」

**设计稿布局**：

| 元素 | 设计稿 |
|---|---|
| 标题栏 | `<h2>收藏</h2>`（与信息流同 `.feed-hd` 样式）· **无返回按钮**（mockup 里 tabbar 仍在） |
| 副标题 | `.bm-sub` = 「收藏的文章会一直留在这里，方便随时重读。」 |
| 列表 | **复用 `FeedCard`**（书签为 `on` 态） |
| 空状态 | 粘土**凹陷圆环** + 书签图标 · 「还没有收藏的文章」· 「读到喜欢的文章，点右上角的书签就能存下来，以后随时回来重读。」· 引导行「在卡片上找这个 [书签图标] 图标」 |
| 入口 | `.bm-entry` = 「**收藏 12**」（信息流标题栏右侧，带书签小图标） |

### 12.3 ⚠️ 一处需白哥定：收藏清单**要不要保留底部 tabbar**

设计稿的 mockup **画了 tabbar**（且标题栏无返回按钮）→ 说明它是
**「阅读」tab 内的一个子视图**（对应产品原则「**收藏是视图非 tab**」）。
但 CSS 里另有一个**未被 mockup 使用**的 `.bm-hd .back`（返回链接样式）——
说明设计阶段也考虑过「全屏 push + 返回」。

两条路都能实现，观感与栈行为不同 → **见下面的提问**。


---

## 十、三次修正（2026-09-27 22:50）：未选中 tab 加底色

### 10.1 白哥指令

> 「**OK，底部栏已经透明了，很好。按钮在未选中的 tab 需要加底色，看不清，让他们符合粘土风格**」

这正是 9.3 节预警的代价（透明 → 未选中项无底 → 正文穿过 → 看不清）。
白哥给的解法是**加底色**，而不是 9.3 列的三个备选（半透明/毛玻璃/窄渐变）。

### 10.2 🔴 关键发现：**只加底色解决不了「看不清」，墨档反而更糟**

先量化，再动手：

| 档 | `ink3` on `page`（原） | **只加 `sunken` 底** | 若字色改 `ink2` |
|---|---|---|---|
| 墨 | 2.74 | 🔴 **2.58（↓ 更低）** | ✅ **4.57** |
| 格 | 2.97 | 3.03（几乎没变） | ✅ **6.05** |
| 夜 | 4.16 | 4.16（**`sunken == page`，填了等于没填**） | ✅ **7.42** |

**三个结论**：

1. 🔑 **只加底色会让墨档更差** —— `sunken` 比 `page` 更暗，而字色没变 → 对比度**下降**。
2. 🔑 **病根是 `ink3` 本身**（三档全在 3.0 以下/边缘，低于 WCAG 小字要求的 4.5），
   「透明」只是让正文串进来、**加重了观感**，不是根因。
   → 所以**字色与底色必须一起改**，才真正解决白哥说的问题。
3. 🔴 **夜档 `sunken == page`**（都是 `#0B0D12`）→ **填充不可见**，凹陷感全部由 Clay 的
   **inset 内阴影**承担。这是「夜档没有比 `page` 更暗的色可用」的固有约束
   （设计系统设 `sunken = page` 就是这个原因），非缺陷。

### 10.3 实施：复用 `BookmarkButton` 的粘土语义

**关键是「凹/凸」的语义必须全 App 一致**：

| 元素 | 未激活 | 已激活 |
|---|---|---|
| 书签按钮（3.3 已实现） | `ClayState.pressed` + `fill: sunken` | `ClayState.selected` |
| **底部 tab（本次）** | **`ClayState.pressed` + `fill: sunken`** | `ClayState.selected` |

→ 这不是新设计，是**语义复用**。🔑 同一 App 里「凹 = 未激活 / 凸 = 已激活」只能有一种含义。

**顺带修好了一个遗留问题**：原先未选中项是裸 `GestureDetector`，
类文档曾记「设计稿没定义未选中项的按下反馈 → 本实现不自行添加」。
改用 `Clay` 后**自动获得**按下反馈（`scale(.97)` 回弹）——
不是特意加的，而是「有了物理形态就该有物理反馈」的自然结果。

### 10.4 ⚠️ 这**推翻了此前的判断**（如实记录）

本类文档**曾**明确写：

> 🔴 未选中项**不能**用 `Clay` —— 硬套会凭空多出三个灰底药丸，与设计稿不符。

**那个判断在当时是对的**（设计稿 `.tb` 确实只有 `color`）。
**但现在前提变了**：`extendBody` 让正文穿过 tabbar → 未选中项无底就会与正文重叠。
→ **用户指令覆盖设计稿**，于是按粘土语义重新设计。

🔑 **教训：设计稿的判断有前提，前提变了要重判 —— 而不是把旧结论当永久约束。**

### 10.5 验证

| 验收 | 结果 |
|---|---|
| `verify_tokens` | ✅ **330 项**（320 + 10） |
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4 |

**新增断言（10 条）**：
- 未选中项走 `ClayState.pressed`
- 未选中项显式 `fill: t.sunken`
- 未选中项字色用 `t.ink2`
- 未选中项不再用 `t.ink3`
- **三档对比度硬校验**：`ink2 ↔ sunken ≥ 4.5`（4.57 / 6.05 / 7.42）
- **三档反向对照**：`ink3 ↔ sunken < 4.5`（2.58 / 3.03 / 4.16）—— 记录「为什么不能用 ink3」

> 🔑 **两层断言各管一层**（这点值得记住）：
> · 「源码里写的是 `ink2`」→ 验**用了哪个 token**
> · 「`ink2 ↔ sunken ≥ 4.5`」→ 验**那个 token 够不够**
> 只写前者：有人改了 `ink2` 的值照样绿；只写后者：有人改回 `ink3` 照样绿。**必须都有。**

**证伪测试（临时副本）**：把字色改回 `ink3` → **2 条断言准确报红** ✅
且对比度断言**仍绿** —— 因为它算的是 token 值、与源码无关，**这正是正确的分层**。

### 10.6 高度未变（回归确认）

`_tabPadding` 保持 `EdgeInsets.fromLTRB(0, 8, 0, 7)` 未动 → **底部栏总高度不变**
→ `CoSpacing.tabBarClearance = 100` 仍然有效，各页 padding 无需调整。




