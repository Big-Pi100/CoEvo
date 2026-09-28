# Android 构建失败 · 根因报告：用错了 Flutter SDK

> 日期：2026-09-27 22:05｜触发：白哥 `flutter build apk --debug` → `BUILD FAILED in 1m 13s`
> 结论：🔴 **构建环境问题，与本次代码改动无关**（改动根本没被编译到）

---

## 〇、结论先行

| # | 结论 |
|---|---|
| **1** | 🔴 **用错了 Flutter SDK**：裸敲 `flutter` 命中的是 **鸿蒙定制版 3.27.5-ohos**，而项目自方案 A 起**只能在官方 3.41.1 上编译** |
| **2** | ✅ **与本次代码改动（收藏按钮 + 底部栏）无关** —— 编译在依赖层就崩了，我们的代码**一行都没被编译到** |
| **3** | ⚠️ **附带损伤**：这次 `pub get` 把 `pubspec.lock` **降级了 45 处**（需恢复） |
| **4** | 🔑 上次成功那次的命令是 **`D:\flutter\bin\flutter.bat ...`（显式全路径）** → 所以没踩到；这次裸敲 `flutter` → 踩到了 |

---

## 一、根因：两个 Flutter SDK，PATH 指向了错的那个

```
D:/flutter          →  "frameworkVersion": "3.41.1"            ← 官方版（项目需要的）
D:/flutter_flutter  →  "version": "3.27.5-ohos-1.0.5"          ← 鸿蒙定制版（PATH 里的）
```

| 检查 | 结果 |
|---|---|
| `which flutter` | **`/d/flutter_flutter/bin/flutter`** ← 🔴 鸿蒙版 |
| PATH 中 flutter 相关目录 | **只有 `/d/flutter_flutter/bin`** |
| `D:/flutter/bin` 在 PATH 中？ | ❌ **不在** |

→ 所以裸敲 `flutter` = 鸿蒙 3.27.5-ohos。**上次成功是因为敲了全路径**。

### 错误信息里的铁证

```
/D:/flutter_flutter/packages/flutter/lib/src/foundation/platform.dart
D:\flutter_flutter\bin\flutter.bat'  finished with non-zero exit value 1
```
→ Gradle 调用的确实是 `D:\flutter_flutter`。

---

## 二、为什么这两个 SDK **互斥**（API 存在性实测）

| 需要的 API | `D:/flutter` 3.41.1 | `D:/flutter_flutter` 3.27.5-ohos |
|---|---|---|
| `SelectedContentRange`（`gpt_markdown 1.0.9` 需要） | ✅ **有**（`rendering/selection.dart`） | ❌ **没有** |
| `RenderObjectWithLayoutCallbackMixin`（`flutter_math_fork 0.7.4` 需要） | ✅ **有**（`rendering/object.dart`） | ❌ **没有** |
| `TargetPlatform.ohos`（鸿蒙独有） | ❌ 没有 | ✅ **有**（1 处） |

**两个方向的冲突同时成立**：

| 报错 | 机制 |
|---|---|
| `Type 'SelectedContentRange' not found`<br>`Type 'RenderObjectWithLayoutCallbackMixin' not found` | pub **官方包**要 **新 API**（3.41.1 有）→ 鸿蒙 3.27.5 **太老，没有** |
| `'TargetPlatform' is not exhaustively matched … doesn't match 'TargetPlatform.ohos'` | 鸿蒙 SDK **多一个枚举值** → pub **官方包**的 `switch` 不穷尽 → **编译期错误** |

→ 🔑 **「官方 Flutter 3.41.1 + pub 官方包」是唯一自洽组合** —— 这正是方案 A 的结果
（方案 A 把项目从「只能在鸿蒙上编译」**翻转**成「只能在官方上编译」，见
`flutter-run-blocker-2026-09-27.md` §八：「**官方 Flutter 3.41.1 / Dart 3.11.0 真编译 ✅ 通过**」）。

---

## 三、附带损伤：`pubspec.lock` 被降级（**需恢复**）

鸿蒙 SDK 3.27.5 的 pinned 依赖版本更低 → `pub get` 把 lock **降级了 45 处**：

| 包 | HEAD（正确基线） | 工作区（被污染） |
|---|---|---|
| `characters` | **1.4.1** | 1.3.0 |
| `meta` | **1.17.0** | 1.15.0 |
| `matcher` | **0.12.18** | 0.12.16+1 |
| `path` | **1.9.1** | 1.9.0 |
| （另 41 处） | … | … |

- `git diff --stat` = **45 insertions / 45 deletions**
- lock 修改时间 **21:58:20** = 构建那一刻（铁证）
- 🔑 **`git checkout app/pubspec.lock` 可恢复到已验证过的基线**（HEAD 里是高版本）

⚠️ **注意区分**：`pubspec.yaml` 的改动**不能**恢复 —— 那是方案 A 的**有意改动**
（删 `flutter_math_fork` override + `gpt_markdown` 1.0.8→1.0.9）。只有 `lock` 是被意外污染的。

---

## 四、修复方案

### 方案 A（推荐）· 用官方 Flutter 全路径构建

```powershell
cd E:\CoEvo\app
git checkout pubspec.lock                      # 先撤销被降级的 lock
D:\flutter\bin\flutter.bat build apk --debug   # 显式全路径 = 官方 3.41.1
```

**优点**：一行命令、零配置改动、可复现。
**代价**：每次都要敲全路径（容易忘 —— 这次就是这么踩的）。

### 方案 B · 调整 PATH 顺序（治本）

把 `D:\flutter\bin` 放到 `D:\flutter_flutter\bin` **之前**：

```powershell
# 查看当前顺序
$env:PATH -split ';' | Select-String flutter
```
然后在系统环境变量里调整顺序 → 之后裸敲 `flutter` 就是官方版。

**优点**：根治；不会因为忘敲全路径再踩。
**代价**：⚠️ **会影响鸿蒙项目的开发**（若这台机器还在做鸿蒙开发，`flutter` 会变成官方版）。
→ 🔴 **需白哥确认这台机器是否还在做鸿蒙项目**再决定。

### 方案 C · 在项目里放一个构建脚本

新建 `app/build-apk.ps1`，内部写死官方 SDK 全路径 + 构建参数。
**优点**：项目内自解释，换机器/换人不会踩；可顺带固定构建参数。
**代价**：多一个脚本文件要维护。

---

## 五、顺带发现的构建警告（**本次不是错误，但会变成错误**）

这次 `pub get` / 构建过程打出的警告，与本次失败**无关**，但值得记录：

| 警告 | 内容 | 影响 |
|---|---|---|
| **compileSdk 偏低** | 项目 `compileSdk = 35`，而 `flutter_tts` **要求 36** | ⚠️ 目前仍能构建（AGP 取插件最高值），但**升级后会变成错误** |
| **NDK 版本不一致** | 项目 `26.1.10909125`，11 个插件要求 `27.0.12077973` | ⚠️ 同上（提示「向后兼容」） |
| **Android x86 支持将移除** | `after 3.27` | ℹ️ 我们只发 arm64，影响很小 |

`android/app/build.gradle.kts` 里目前是：
```kotlin
compileSdk = flutter.compileSdkVersion   // 解析为 35
ndkVersion = flutter.ndkVersion          // 解析为 26.1.10909125
```
→ 若要消除，需显式写 `compileSdk = 36` / `ndkVersion = "27.0.12077973"`。
**但这是构建配置改动，按项目铁律需先请示。**

---

## 六、⚠️ 当前状态（重要）

**本次代码改动（收藏按钮修复 + 底部栏渐隐）尚未被验证过** ——
上次成功构建是 **20:09**，而改动是 **21:37~21:42** 做的，这次构建在依赖层就崩了。

→ 所以「收藏按钮能不能点」**目前仍是未知**。需要按第四节修复后重新构建。

---

## 七、验证清单（修复后）

构建前：
- [ ] `git checkout app/pubspec.lock`（撤销降级）
- [ ] 确认用的是官方 SDK（构建输出里**不应**出现 `flutter_flutter`）

构建后：
- [ ] `flutter build apk --debug` 输出 `√ Built build\app\outputs\flutter-apk\app-debug.apk`
- [ ] APK 时间戳为最新
- [ ] 装机后按 `bookmark-tap-no-effect-and-tabbar-2026-09-27.md` §8.5 的四项复验
