# iOS 真机首测问题清单与根因分析（2026-10-07）

> **背景**：CoEvo 首次在 iPhone 真机上运行（此前**一次都没验证过**）。
> 白哥报 7 条，本文逐条给**根因**与**修复建议**。
> 🔴 **本轮未改任何代码**（按铁律：先调查出报告 → 请示 → 再改）。
> 📄 出包过程见 `docs/operations/ios-archive-first-run-findings-2026-10-07.md`

---

## 一、总览

| # | 问题 | 严重度 | 状态 | 根因 |
|---|---|---|---|---|
| 1 | 划词词卡正常 | — | ✅ | — |
| 2 | 信息流正常 | — | ✅ | — |
| 3a | 发音**默认语速过快** | 🟠 中 | 🔴 **已定位** | `kSpeechRateDefault = 1.0`，而 iOS 上「正常」是 `0.5` |
| 3b | **后台/锁屏后不能继续朗读** | 🟠 中 | 🔴 **已确认** | `Info.plist` **缺 `UIBackgroundModes: [audio]`** |
| 4 | **书库无法导入**（本地 + 用 App 打开）| 🔴 **最严重** | 🔴 **已确认** | `file_selector` 在 iOS **只认 UTI**，而代码只给了 `extensions` ⇒ **必然抛 `ArgumentError`** |
| 5 | **登录注册连不上服务器** | 🔴 第二严重 | 🟠 **待验证** | 后端**实测完全正常**；怀疑 `dart-define` 未注入（需用 IPA 验证）|
| 6 | 复习页空状态**文字靠左上** | 🟡 低 | 🟠 **已定位代码** | 外层 `Column(crossAxisAlignment: .start)` 包裹空状态 |
| 7 | 音色菜单**无法关闭** | 🟠 中 | 🟠 **待复现** | `showModalBottomSheet` + `DropdownButtonFormField` 的手势/路由冲突 |

---

## 二、逐条分析

### 3a · 默认语速过快

`app/lib/services/tts_service.dart`：

```dart
const double kSpeechRateDefault = 1.0;   // ← 当前默认
const double kSpeechRateNormal  = 0.5;   // ← 库声明的 normal
```

**代码注释自己就预言了这次反馈**：

> ⚠️ 它**不是最保守**的选择（最保守是 `0.5` = 库声明的 `normal`）
> 📌 **若真机再反馈不稳 → 降到 `kSpeechRateNormal`**

白哥反馈「调到 **0.5** 才是正常语速」——与 `kSpeechRateNormal = 0.5` **完全对应** ✅

⚠️ **但要注意平台语义差异**：注释里写着「映射到 Android 是 `2.0` = Android 原生文档的合法上限」
⇒ **Android 与 iOS 对同一个 `1.0` 的听感不同**。
⇒ 所以这是一个**产品决策**（见 §四），不只是改个数字。

### 3b · 后台/锁屏不能继续朗读

`app/ios/Runner/Info.plist` **实测**（`plistlib` 解析）：

| Key | 状态 |
|---|---|
| `UIBackgroundModes` | 🔴 **缺失** |
| `NSMicrophoneUsageDescription` | 🔴 **缺失**（⚠️ 录音功能会**直接崩溃**，尚未暴露）|
| `UIFileSharingEnabled` | 🔴 缺失 |
| `LSSupportsOpeningDocumentsInPlace` | 🔴 缺失 |
| `CFBundleDocumentTypes` | ✅ 有（EPUB + Plain Text）|

**iOS 的后台音频是硬性声明制**：没有 `UIBackgroundModes: [audio]`，App 一进后台/锁屏，系统**必然**挂起音频会话。
⇒ 这是**唯一**原因，与 `flutter_tts` 代码无关。

⚠️ 顺带：`NSMicrophoneUsageDescription` 缺失是个**定时炸弹** ——
`pubspec` 里有 `record: ^6.2.1`（录音），一旦用户触发录音，iOS 会**直接 kill 进程**（不是报错）。
上架审核也会因此被拒。

### 4 · 书库无法导入 🔴（最严重）

`app/lib/services/ebook/book_import_flow.dart:52`：

```dart
const _kEbookTypeGroup = XTypeGroup(
  label: '电子书',
  extensions: <String>['epub', 'txt'],   // ← iOS 不认这个
  // ❌ 没有 uniformTypeIdentifiers
);
```

**`file_selector` 的平台过滤参数支持矩阵**（官方 pub 页 + 插件源码 + 多个来源一致）：

| 参数 | Android | **iOS** |
|---|---|---|
| `extensions` | ✔️ | **❌ 不支持** |
| `mimeTypes` | ✔️ | ❌ |
| `uniformTypeIdentifiers` | ❌ | **✔️ 唯一可用** |

`file_selector_ios` 源码逻辑（`_allowedUtiListFromTypeGroups`）：

> **若某个类型组的 `uniformTypeIdentifiers` 为空且不允许任意文件 ⇒ 抛 `ArgumentError`**

⇒ 我们的代码在 iOS 上**必定**走到这个分支 ⇒ 抛错 ⇒ 被 `catch (e)` 兜住
⇒ `_showImportFailure(context, EbookParseErrorKind.unknown)` ⇒ 用户看到「导入失败」✅

**这解释了「本地导入失败」**，且是**确定性**的（不是偶发）。

⚠️ **「用 App 打开电子书」是另一条路径**（`AppDelegate.swift` → `open_with_handler.dart`），
它的 iOS 配置其实**写得完整**（`open url` 回调 + MethodChannel + `CFBundleDocumentTypes` 都有）。
⇒ 需要单独确认失败原因，可能是：
· `CFBundleTypeRole: Viewer` + `LSHandlerRank: Alternate`（优先级低，可能不出现在「打开方式」里）
· 或 Dart 侧 `getPendingFiles` 的拉取时机

### 5 · 登录注册连不上服务器 🟠（待验证）

**我实测了生产后端（匿名，不改数据）**：

```
200  /api/feed        → 有数据
200  /api/auth/login  → {"error":"邮箱或密码错误"}      ← 路由在、逻辑正常
200  /api/auth/register → {"error":"邮箱格式不正确"}
200  /api/auth/register → {"error":"密码至少6位含英文+数字"}
```

⇒ **后端完全正常**，问题在客户端侧。

**关键矛盾**：信息流是**纯网络请求**（`content_client.fetchFeed`，**无本地缓存、无 fallback**），
而白哥反馈「信息流正常」 ⇒ 说明 **API 是通的** ⇒ `API_HOST` 注入**应该是生效的**。

⚠️ 但「连不上服务器」这句文案来自 `auth_provider._friendlyError`，**只在**
`SocketException` / `Connection refused` / `Failed host lookup` 时出现：

```dart
if (msg.contains('SocketException') ||
    msg.contains('Connection refused') ||
    msg.contains('Failed host lookup')) {
  return '连不上服务器，请检查网络后重试';
}
```

⇒ 客户端**确实**收到了这三类异常之一。

**两个可能**（需二选一确认）：
1. **`dart-define` 在 `xcodebuild archive` 时丢了** ⇒ `API_HOST` 掉回 `localhost`
   → 但那样信息流也该失败（除非白哥看到的「正常」是指页面能打开）
   → ⚠️ 已确认机制：`xcode_backend.dart:686` 通过 **`DART_DEFINES` 环境变量**取 dart-define
2. **iOS 特有网络问题**（ATS / IPv6 / 首次网络权限）

**验证方式**：解包白哥下载的 IPA，用 `strings` 在 `App.framework/App` 里搜 `keyievolution`
（AOT 编译后 `String.fromEnvironment` 的值会被内联为常量，可搜到）。

### 6 · 复习页空状态靠左上 🟡

`app/lib/screens/review_screen.dart`：

```dart
// 208 行附近
child: Column(
  crossAxisAlignment: CrossAxisAlignment.start,   // ← 🔴 这里
  children: [
    _header(...), _sortBar(...),
    Expanded(
      child: list.when(
        data: (rows) => rows.isEmpty
            ? _EmptyState(filtered: _isFiltering)   // ← 空状态被包在 .start 的 Column 里
            : _list(rows),
      ),
    ),
  ],
),
```

而 `_EmptyState` 内部（`filtered == false` 分支）用的是：

```dart
return SingleChildScrollView(
  padding: const EdgeInsets.fromLTRB(22, 52, 22, 52),   // ← 垂直从顶部 52 起
  child: Column(children: [...]),                        // ← 水平默认 center
);
```

**分析**：
- **「上」能确定解释**：`SingleChildScrollView` 从顶部开始 + padding 52 ⇒ **垂直靠上，不是居中** ✅
- **「左」待确认**：内层 `Column` 默认是 `CrossAxisAlignment.center`，理论上水平居中；
  但外层 `.start` 会让 `Expanded` 的 child 拿到**宽松宽度约束** ⇒ 空状态可能 **shrink-wrap 到内容宽度** ⇒ 视觉上偏左
- ⚠️ 白哥说「与安卓测试时不同」——**需要真机/模拟器截图对比**才能定论（同一份 Flutter 代码两端布局不该有差异，除非是字体宽度差异导致 shrink-wrap 后的视觉差异）

⚠️ 另一个分支（`filtered == true`）用的是 `Center(...)` ⇒ **那个是真居中**。

### 7 · 音色菜单无法关闭 🟠

`reading_settings_panel.dart`：

```dart
Future<void> showReadingSettingsPanel(BuildContext context, {bool showTrace = true}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,            // ← 面板可超过半屏
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x1F000000),
    builder: (_) => ReadingSettingsPanel(showTrace: showTrace),
  );
}
```

音色选择器是 `DropdownButtonFormField<String>`（262 行）。

**参数上没有 `isDismissible: false`** ⇒ 理论上点遮罩可关、下拉可关。
⇒ 所以「无法关闭」更可能是**手势被吃掉**，两个候选：
1. **下拉手势被内部滚动视图拦截** —— `isScrollControlled: true` 的面板内容通常可滚动，
   而 `showModalBottomSheet` 的下拉关闭依赖 `enableDrag`（默认 true）；
   若内部有 `SingleChildScrollView`/`ListView` 且已滚到顶部，手势归属会打架。
2. **Dropdown 的路由与 sheet 的遮罩叠加** —— Material 的 dropdown 打开时会推一个带 barrier 的 route，
   点击外部时可能「先关 dropdown」而**不关 sheet** ⇒ 用户感觉「点一下没反应」。

⇒ 需要真机复现确认是哪个（**建议白哥录一下操作**，或说明「点哪里、期望什么」）。

---

## 三、修复建议（按优先级分批）

### 批次 A · 确定性 bug，风险低（建议立即做）

| # | 改动 | 文件 |
|---|---|---|
| A1 | **补 `uniformTypeIdentifiers`**（EPUB:`org.idpf.epub-container` / TXT:`public.plain-text`）—— 修「书库无法导入」 | `services/ebook/book_import_flow.dart` |
| A2 | **补 `UIBackgroundModes: [audio]`** —— 修「后台不能朗读」 | `ios/Runner/Info.plist` |
| A3 | **补 `NSMicrophoneUsageDescription`** —— 拆掉录音崩溃的定时炸弹（上架必查） | `ios/Runner/Info.plist` |
| A4 | 复习空状态改为**真正居中**（`Center` 或调整外层对齐） | `screens/review_screen.dart` |

### 批次 B · 需一个决策（见 §四）

| # | 改动 |
|---|---|
| B1 | 默认语速 `1.0` → `0.5`（或改为**分平台**） |
| B2 | 音色菜单的关闭方式（需先确认现象） |

### 批次 C · 需先验证

| # | 改动 |
|---|---|
| C1 | `dart-define` 是否真注入 → 由 **IPA 解包**确认；确认后在 workflow 里加**断言**防回归 |
| C2 | 「用 App 打开电子书」失败原因（`CFBundleDocumentTypes` 的角色/优先级 + Dart 侧拉取时机） |

---

## 四、需要白哥定三件事

1. **默认语速怎么改？**
   · **选项 1（简单）**：统一 `1.0 → 0.5`。⚠️ 会改变 Android 老用户的默认听感
   · **选项 2（保守）**：**iOS 用 0.5、Android 保持 1.0**（平台分叉，尊重平台差异）
   · 我倾向 **选项 1** —— iOS 是**首次上线**（无存量用户），且 `0.5` 是库声明的 `normal`，语义更干净；Android 侧只有白哥自己在测

2. **批次 A 是否现在就动手？**（4 处改动，都是确定性缺陷，我有把握）

3. **IPA 能否放到本机一份？**（比如 `E:\CoEvo_backups\`）
   —— 我需要解包确认 `dart-define` 是否注入，这决定问题 5 是「一行配置」还是「要排查 iOS 网络栈」

---

## 五、本轮未做（首轮调查时）

- ❌ **未改任何代码**（按铁律：先报告 → 请示 → 再改）
- ❌ 未部署、未改生产
- ✅ 生产后端**只做了只读探测**（`/api/feed`、`/api/auth/login`、`/api/auth/register` 的**无效输入**用例，未创建任何账号）

---

## 六、修复实施（白哥批准后 · 2026-10-07）

白哥批准三件：① 语速统一 `0.5` ② 修 ③ 提供 IPA 路径。

### 6.1 五处改动

| # | 文件 | 改动 | 修的问题 |
|---|---|---|---|
| A1 | `app/lib/services/ebook/book_import_flow.dart` | `_kEbookTypeGroup` 补 `uniformTypeIdentifiers`（`org.idpf.epub-container` / `public.plain-text`）| **书库无法导入** |
| A2 | `app/ios/Runner/Info.plist` | 补 `UIBackgroundModes: [audio]` | **后台/锁屏不能朗读** |
| A3 | `app/ios/Runner/Info.plist` | 补 `NSMicrophoneUsageDescription` | 防录音崩溃 |
| A4 | `app/lib/screens/review_screen.dart` | 空状态改 `LayoutBuilder + ConstrainedBox(minHeight) + Column(center)` | **空状态靠左上** |
| B1 | `app/lib/services/tts_service.dart` | `kSpeechRateDefault` `1.0` → **`0.5`** | **默认语速过快** |

**A4 的写法要说明**：不能直接写 `Center(child: SingleChildScrollView(...))` ——
scroll view 的 viewport 高度会取 `maxHeight` ⇒ 撑满 ⇒ `Center` 失效。
用 `LayoutBuilder` + `ConstrainedBox(minHeight: constraints.maxHeight - padding)`
才能**既垂直居中、又保留超屏滚动能力**。

### 6.2 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc app/lib` | ✅ **error=0 · warning=0**（5 个 info 均为既有项）|
| `Info.plist` | ✅ `plistlib` 解析通过 · `UIBackgroundModes = ['audio']` |
| 语速常量 | ✅ `kSpeechRateDefault = 0.5` |

### 6.3 ⚠️ 对 §二.3b 的一处修正

`record`（录音）在 `pubspec.yaml` 里有，但 `app/lib` **零引用** ⇒ 录音**未接线**。
⇒ 所以「缺麦克风声明会崩溃」目前**不会触发**（我此前称"定时炸弹"略重了）。
补声明是为了**防将来接线**；另建议单独评估是否移除 `record` 依赖
（链接麦克风 API 却不用，审核可能追问）。

---

## 七、问题 5 的重大进展：**App 从未发出过 auth 请求**

### 7.1 IPA 验证 → dart-define **注入成功** ✅

解包 `E:\CoEvo_backups\coevo_app.ipa`，在 AOT 快照（`App.framework/App`，10.8 MB）里搜：

```
✅ api.keyievolution.fun × 5      ← 注入成功
✅ keyievolution.fun     × 5
   localhost × 1 / 8080 × 1       ← 只是 `String.fromEnvironment` 的 defaultValue 常量
```

⇒ **不是 dart-define 的问题**。
（同时确认 IPA 里的 `Info.plist` 确实缺 `UIBackgroundModes` / `NSMicrophoneUsageDescription`。）

### 7.2 TLS 验证 → **完全满足 iOS ATS** ✅

```
协议: TLSv1.3 · 套件: TLS_AES_256_GCM_SHA384
证书: Let's Encrypt · 有效期 2026-10-01 → 2026-12-30
✅ ECDHE + AES-GCM 系列套件握手成功（ATS 的核心要求）
```

⇒ **不是 ATS 的问题**。

### 7.3 🔴 决定性证据：nginx access log

**iOS App（UA = `Dart/3.11 (dart:io)`）当天发出的全部请求**：

```
12:33:08  GET  /api/public/qrcode                    200
12:33:15  GET  /api/feed?limit=30&offset=0           200
12:33:17  GET  /api/feed/10779                       200
12:39:11  GET  /api/feed/10780                       200
12:39:14  POST /api/generate-card                    200
12:42:39  POST /api/generate-card                    200
12:43:04  GET  /api/feed?...category=sports          200
12:43:07  GET  /api/feed/9945                        200
12:46:40  GET  /api/public/qrcode                    200
12:48:26  GET  /api/feed/7091                        200
12:48:31  GET  /api/feed?ids=7091                    200
12:52:22  GET  /api/feed?...category=sports          200
```

**`/api/auth/*` 与 `/api/trial/*`：零条**
（日志里所有 `/api/auth/*` 都是**我的 curl 探测**，UA = `curl/8.21.0`。）

### 7.4 结论与两条候选根因

App **能正常连服务器**（内容类接口全部 200）
⇒ 「连不上服务器」**不是网络层问题**，而是 **App 端**。

两条候选，**需要用新包重试来区分**：

**候选 1 · 显示的是「陈旧错误」**（我倾向这条）
`ClaimDialog` 显示的是 `authState.error`，而该字段可能由**启动阶段**的失败写入。
`home_screen._initAuth` 只在「**从未用过 trial**」时才发 `trialStart`；
若冷启动瞬间 DNS/网络尚未就绪 ⇒ `SocketException` ⇒ 写进 `state.error`，
之后用户打开注册弹窗，看到的就是这句**与当前操作无关的旧错误**。
✅ 这能同时解释「日志里没有 auth 请求」+「用户却看到连不上」。

**候选 2 · 请求在客户端提前失败**（未到 TCP 层 ⇒ nginx 无日志）
例如按钮逻辑提前 `return`。

⚠️ **区分方法**：在新包上**再点一次注册**，同时盯 nginx 日志 ——
- 日志**出现** `/api/auth/register` ⇒ 候选 1（陈旧错误）
- 日志**仍无** ⇒ 候选 2（按钮/流程问题）

### 7.5 📌 无论哪条，都有一个共通的产品缺陷值得修

**「错误提示的生命周期」** —— 旧错误应在新操作开始 / 弹窗打开时**清除**，
否则用户会把「上一次的故障」当成「这次操作的结果」。
（这与已入库的判据**「静默失败 + 无出口 比报错更糟」**是一对：
这里是**「有出口但出口指向错的因」**。）

---

## 八、待白哥确认 / 后续

1. **重新出包**（method=ad-hoc）→ 装机验证 A1/A2/A4/B1 是否解决
2. **重试注册**（我同时盯 nginx 日志）→ 区分问题 5 的候选 1 / 2
3. **问题 7（音色菜单）** 需要补充现象：点哪里没反应？
   （另注：`analyze` 提示 `reading_settings_panel.dart:263` 的
    `DropdownButtonFormField.value` 已 deprecated，建议改 `initialValue` —— 与本问题无关，顺带记录）
4. `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` **未加**（不在本次批准范围）——
   它们让 App 的 Documents 出现在「文件」App 里，属**产品决策**，需你定是否要
5. `record` 依赖是否移除（见 §6.3）
