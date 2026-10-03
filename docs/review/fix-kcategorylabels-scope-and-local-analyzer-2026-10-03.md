# 修复 `kCategoryLabels` 作用域错误 + 新增本地符号解析能力（2026-10-03）

> **起因**：白哥贴出 `flutter build apk` 失败：
>
> ```
> lib/screens/profile_screen.dart:653:31: Error:
>   The getter 'kCategoryLabels' isn't defined for the type '_ProfileScreenState'.
> ```
>
> **结论**：✅ 已修 · ✅ **本地编译级验证通过**（全量 99 文件 0 error）· ⏳ 请重新出包

---

## 一、根因（我上一轮引入的）

我把 `FeedItem` 的私有静态成员 `_categoryLabels` 改名成 `kCategoryLabels`，
**但位置没动** —— 它仍是 `FeedItem` 的**静态成员**。

而 `k` 前缀在本项目是**顶层常量**惯例：

| 现役顶层常量 | 位置 |
|---|---|
| `kFeedPageSize` | `providers/feed_provider.dart` |
| `kInterestPrefsKey` | `providers/interest_provider.dart` |
| `kUnescapablePunct` | `services/markdown_unescape.dart` |
| `kTraceFreshOpen` | `services/trace_markdown_source.dart` |
| `kCoEvoVersion` | `constants/app_info.dart` |

⇒ 我在 `profile_screen.dart` 里**按惯例裸写** `kCategoryLabels` ⇒ **解析不到**
（它是 `FeedItem.kCategoryLabels`）。

🔑 **这是「命名与位置不一致」**：改名时只把 `_` 换成 `k`（暗示顶层），没把定义移出去。
📌 判据：**改名如果同时改变了「命名约定的含义」（私有→顶层），就必须检查「位置是否也要跟着变」。**

---

## 二、修复

**移到顶层**（而不是在调用处加 `FeedItem.` 前缀），理由：
1. 它现在是**跨模块共享定义**（卡片元信息行 + 兴趣筛选 pill）⇒ 顶层更合适
2. 符合 `k` 前缀的项目惯例
3. **类内 3 处引用不用改**（顶层常量在类内可裸名引用）

```
app/lib/models/feed_item.dart
  · `static const Map<String, String> kCategoryLabels` （在 class FeedItem 内）
  → `const Map<String, String> kCategoryLabels`        （**顶层**）
  · 位置：移到 `import` 之后、`FeedItem` 的**类文档之前**
  · 补写「为什么在顶层」的说明（含这次的坑）
```

⚠️ **中途我自己又引入并修掉两个问题**（都在提交前发现）：
1. **`static const` 不能放顶层**（Dart 语法）⇒ 去掉 `static`
2. **插入点最初选在「类文档与 `class` 之间」** ⇒ 把 `FeedItem` 的**类文档截断**了
   （那串 `///` 会归给常量，类反而丢了文档）⇒ 改插到**类文档之前**

---

## 三、🔴 为什么现有防线全都没拦住（这是本轮最重要的部分）

| 防线 | 结果 | 为什么 |
|---|---|---|
| `dart format --output=none`（我本机唯一的检查）| ✅ **通过** | 它只验**语法**（AST 能否解析）；**符号解析不到不是语法错** |
| `verify_feed_wiring` 的源级断言 | ✅ **报了通过** | 它只查 **`feedItem.contains('kCategoryLabels')`**（字符串存在）—— 而字符串**确实在**（定义处）。**「字符串存在」≠「引用可解析」** |
| CI 的 `flutter analyze` | 🔴 **应该红了** | 它**能**抓到这个错 —— ⏳ 见 §五（我无法查私有仓库结果）|
| 出包 | 🔴 **红了** | 最终由白哥的 `flutter build` 抓到 |

⇒ 三层「看起来在守」的防线里，**只有 CI 和真编译抓到了**。

### 一个关键澄清：CI 可能早就报了，只是我们没看见

**上一轮白哥说「CI 全绿」** —— 那是提交 `a6b8ebf`（改的是 `feed_provider` 等），**不含**这次的
`profile_screen` 改动。**本轮 tag `v0.1.4` 的 CI 才包含它** ⇒ `frontend` job 的
`flutter analyze` **应当已红**。
（而且 `backend-release` / `backend-deploy` 与 `frontend` **无依赖关系** ⇒ 所以**部署照常成功** ✅
—— 这解释了「CI 红但部署成功」这个看似矛盾的现象。）

📌 判据：**「CI 绿」必须绑定到具体的 commit/tag** —— 一个旧 commit 的绿不能代表新代码。

---

## 四、补上的能力：`scripts/codestatic` —— 本地**符号解析**检查

### 为什么能绕开本机的崩溃

本机 `flutter analyze` / `dart analyze` 崩是因为 **analysis_server 起不来**
（`CreateFile failed 231`）。而这次**直接调用 analyzer 库**（`package:analyzer`），
**不经过 analysis_server** ⇒ 不受影响。

**前提已验证**：`app/.dart_tool/package_config.json` 含 **`sky_engine`**
（`dart:ui` 的来源，实测 `file:///D:/flutter/bin/cache/pkg/sky_engine`）✅
⇒ analyzer 能解析 `dart:ui` ⇒ **能完整分析 Flutter 代码**（无 embedder 噪音）。

### 用法

```bash
cd scripts/codestatic
dart pub get
dart run bin/check.dart "E:/CoEvo/app/lib"      # 全量（本次 41 秒 / 99 文件）
```

退出码：**0** = 无 error · **1** = 有 error · **2** = 用法错

### 为什么不接进 CI

CI 已有**更强**的（`frontend` job 的官方 `flutter analyze`，规则集完整）。
本工具定位是**本机补救**，补上「本地只能做语法检查」的缺口。
再接一个依赖十几个包的 job 只会拖慢 CI、**收益为零**。

📌 判据：**能进 CI 的只有「自带全部输入且不重复既有门禁」的** —— 本条两条都不满足。

---

## 五、验证

### 5.1 修复的验证（**编译级**，非语法级）

```
$ dart run bin/check.dart "E:/CoEvo/app/lib"
扫描 99 个 .dart（E:\CoEvo\app\lib）
✅ **0 个 error** —— 符号解析全部通过
退出码=0
```

⚠️ **这不是「语法通过」** —— 是**符号解析**（analyzer 的 error 级别诊断）通过。
⇒ 白哥重新 `flutter build apk` **应当能过**。

### 5.2 双向证伪（证明这个工具真的有效）

| 注入 | 期望 | 结果 |
|---|---|---|
| `kCategoryLabels.entries` → `FeedItem.kCategoryLabels.entries`（模拟「符号不在顶层」）| 红 | ✅ 退出码 **1**，且精确报出 `The getter 'kCategoryLabels' isn't defined` |
| 还原为裸名 | 绿 | ✅ 退出码 0 |

两次均**字节级还原**（md5 一致）。

### 5.3 全部 Dart 断言脚本

| 脚本 | 结果 |
|---|---|
| `verify_unescape` | ✅ |
| `verify_trace_markdown` | ✅ |
| `verify_feed_pager` | ✅ |
| `verify_interest_selection` | ✅ |
| `verify_feed_wiring` | ✅ **63 项**（59 → 63，新增【9b】4 项）|

---

## 六、🐛 证伪时发现工具自身一个**致命 bug**（如实记录）

第一轮证伪时：工具**检测到了 error 并打印了**，但**退出码是 0**。

```
🔴 证伪① 改成 FeedItem.kCategoryLabels ⇒ 应报错
     退出码=0（期望非0）· 失败项=1
       · The getter 'kCategoryLabels' isn't defined ...
```

**根因**：Dart 的 `main` **返回值不用作进程退出码** —— 必须显式 `exitCode = 1`。
⇒ 脚本**永远返回 0** ⇒ **门禁完全失效**。

✅ 已修（显式 `exitCode`），重做证伪后：注入 ⇒ 1 · 还原 ⇒ 0。

📌 **这正是「门禁必须证伪过」的价值**：如果只跑一次「全绿」的用例，
   这个 bug（以及它掩盖的一切）**永远不会暴露**。
   ⚠️ 而它和本次事故是**同一族**：**「看起来通过了」≠「真的通过」**。

---

## 七、防回归断言（`verify_feed_wiring` 新增【9b】组）

```dart
section('【9b】🔴 跨模块常量的定义位置');
check('kCategoryLabels 有定义（前提）', defMatch != null, '截不到 ⇒ 下面会假绿');
check('它定义在【顶层】（缩进为空 ⇒ 外部可裸名引用）', ...);
check('兴趣界面用【裸名】引用它（与上面「顶层」配套）', profile.contains('kCategoryLabels.entries'));
check('不出现 FeedItem.kCategoryLabels（那是「定义在类内」的写法）', ...);
```

🔑 **锁的是「定义位置」而不是「字符串存在」** —— 这正是原来漏掉的那个维度：
位置决定调用方能不能裸名引用。
（同时给脚本加了读入 `profile_screen.dart`。）

---

## 八、⏳ 请白哥做两件事

### 1. 重新出包（命令不变）

```bat
cd E:\CoEvo\app
D:\flutter\bin\flutter.bat build apk --release ^
  --target-platform android-arm64 ^
  --dart-define=API_HOST=api.keyievolution.fun
```

### 2. 看一眼 CI（验证我的推断）

我推断 **tag `v0.1.4` 的 `frontend` job 应该已经红了**（`flutter analyze` 能抓到该 error），
而 `backend-release` / `backend-deploy` 因为**与 frontend 无依赖** ⇒ 照常成功。
**请确认**——若确实如此，说明门禁有效（只是我没法查）。

---

## 九、己方失误清单（如实）

| # | 失误 | 应当的做法 |
|---|---|---|
| 1 | 改名 `_categoryLabels`→`kCategoryLabels` 却**没检查位置** | 命名约定改变时，**位置也要一起审** |
| 2 | 顶层常量写了 `static const` | 顶层不得有 `static`（Dart 语法）|
| 3 | 插入点选在「类文档与 class 之间」⇒ **截断类文档** | 插入前先看清**文档注释的归属边界** |
| 4 | 新加的断言里单引号串嵌套单引号（`'… isn't …'`）⇒ 语法错 | 已由 `dart format` 抓到；⚠️ **而我的检查命令当时没写 `\|\| echo 🔴` 分支，失败时静默无输出** ⇒ 差点忽略 |
| 5 | 证伪时才发现工具自身「退出码恒 0」 | —— |

🔑 **第 4 条有个附带教训**：检查命令写成 `cmd && echo "✅"`（**没有 `||` 分支**），
失败时**什么都不打印** ⇒ 看起来像「没消息」。⇒ **检查命令必须让两种结果都可见**。

---

## 十、产出物

| 文件 | 说明 |
|---|---|
| `app/lib/models/feed_item.dart` | `kCategoryLabels` 移到顶层（+ 为什么在顶层的说明）|
| 🆕 `scripts/codestatic/` | 本地符号解析检查（`bin/check.dart` + README + pubspec，analyzer 钉 `^14.4.0`）|
| `scripts/query_verify/bin/verify_feed_wiring.dart` | 新增【9b】组（59 → 63 项）+ 读入 profile_screen |
