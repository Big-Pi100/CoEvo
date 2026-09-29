# Bug 报告：APK 构建失败 —— **用了错误的 Flutter SDK（鸿蒙分支）**

> 报告时间：2026-09-29 09:5x
> 触发：白哥执行 `flutter build apk --release --target-platform android-arm64` → `BUILD FAILED in 59s`
> 状态：**根因已确证 · 修复未执行（等批）** · `word.db` / 代码**未改**

---

## 一、结论（一句话）

**`flutter` 这个命令在 PATH 里解析到了 `D:\flutter_flutter`（鸿蒙分支 3.27.5-ohos），
而不是正确的 `D:\flutter`（3.41.1 stable）。所有报错和警告都是这一个原因造成的。**

修复 = **用全路径 `D:\flutter\bin\flutter.bat`**（上一次成功的构建就是这么跑的）。

---

## 二、A/B 对照（同一份代码，只差用了哪个 SDK）

| | 上次（**成功**） | 本次（**失败**） |
|---|---|---|
| 命令 | `D:\flutter\bin\flutter.bat build apk --release` | `flutter build apk --release --target-platform android-arm64` |
| 实际 SDK | `D:\flutter` | 🔴 `D:\flutter_flutter`（PATH 解析） |
| 结果 | ✅ `Built app-release.apk (82.6MB)` | ❌ `kernel_snapshot_program failed` |

**证据链**：
1. `command -v flutter` → `/d/flutter_flutter/bin/flutter`
2. `echo $PATH | grep flutter` → **只有** `/d/flutter_flutter/bin`
   （`D:\flutter\bin` **根本不在 PATH 里** → 「裸调 `flutter`」**永远**是鸿蒙版）
3. 报错里出现 `/D:/flutter_flutter/packages/flutter/lib/src/foundation/platform.dart`
   —— 那是**鸿蒙分支自己的** Flutter 源码路径

---

## 三、两个 SDK 的差异（实测）

| 项 | `D:\flutter` | `D:\flutter_flutter` |
|---|---|---|
| `frameworkVersion` | **3.41.1** | **3.27.5-ohos-1.0.5** |
| `channel` | `stable` | `[user-branch]` |
| `TargetPlatform` 枚举 | 标准 6 值 | 🔴 **多一个 `ohos`**（`platform.dart:86`） |
| `compileSdkVersion`（默认） | **36** | **35** |
| `ndkVersion`（默认） | **28.2.13676358** | **26.1.10909125** |

> 出处：`packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`
> （`flutter_flutter` 用的是旧的 `flutter.groovy`，第 45 行 `compileSdkVersion = 35`）

---

## 四、🔴 三类症状 —— **一个根因**

### 症状 1：`TargetPlatform.ohos` 未穷尽匹配（4 处）

```
Error: The type 'TargetPlatform' is not exhaustively matched by the switch cases
       since it doesn't match 'TargetPlatform.ohos'.
  flutter_math_fork-0.7.4/lib/src/widgets/selectable.dart:276 / 473
  .../render/layout/line_editable.dart:469
  .../widgets/selection/gesture_detector_builder_selectable.dart:42
```

**机理**：鸿蒙分支往 `TargetPlatform` 枚举里**加了 `ohos`**。第三方包写的
`switch (platform) { ... }` **穷尽枚举但没有 `default`** → 多一个值就编译失败。
**这是鸿蒙分支的固有问题**，不是我们代码的错。

### 症状 2：找不到 3.41 才有的 API（3 处）

```
gpt_markdown-1.0.9/.../selectable_adapter.dart:269  Type 'SelectedContentRange' not found
flutter_math_fork-0.7.4/.../layout_builder_baseline.dart:26  Type 'RenderObjectWithLayoutCallbackMixin' not found
                                       ...:63  The method 'runLayoutCallback' isn't defined
```

**机理**：3.27.5 比 3.41.1 **老 8 个次版本**，这些类型/方法还不存在。
（即「依赖的包是按新 SDK 写的，老 SDK 里没有」）

### 症状 3：Android SDK 36 / NDK 27 警告

```
Warning: The plugin flutter_tts requires Android SDK version 36 or higher.
Your project is configured to compile against Android SDK 35 ...
Your project is configured with Android NDK 26.1.10909125, but ... require 27.0.12077973
```

**机理**：`app/android/app/build.gradle.kts` 里是
```kotlin
compileSdk = flutter.compileSdkVersion     // ← 继承自 SDK
ndkVersion = flutter.ndkVersion            // ← 继承自 SDK
```
SDK 换成老的（35 / 26.1）→ 默认值就低了 → 触发警告。
**换回 3.41.1（36 / 28.2）警告自动消失。**

---

## 五、🔴🔴 附带的重要发现：那堆警告给的**修复建议是错的**

Flutter 的警告写着：
```
Fix this issue by compiling against the highest Android SDK version
Add the following to E:\CoEvo\app\android\app\build.gradle.kts:
    android { compileSdk = 36 ... ndkVersion = "27.0.12077973" }
```

**🔴 不要照做。** 本项目**故意**写成 `flutter.compileSdkVersion`（继承 SDK 的默认值）——
这是 Flutter 官方推荐做法，保证「SDK 升级 → 编译目标跟着升」。

若真按警告硬编码 `compileSdk = 36` / `ndkVersion = "27.0.12077973"`：
- 表面上「警告消失、构建通过」
- 实际是**用一个硬编码值掩盖了「用错 SDK」的真问题**
- 且以后 Flutter 升到 compileSdk 37 时，这个硬编码会**反噬**（钉住旧值）

> 🔑 这正是判据库里那条：**「约束报错先怀疑实现，再怀疑约束」** ——
> 警告给的「修复」是改约束；真正的故障在**环境**（用错了 SDK）。
> **判断依据**：警告只可能出现在「SDK 版本低」的情况下，而项目配置本身没动过
> （`git status` 证明 `build.gradle.kts` 上次提交后没改）。

---

## 六、🔴 副作用：`app/pubspec.lock` 已被改坏（**需回滚**）

失败那次跑了 pub 解析，日志里 `Changed 21 dependencies!`，实测 diff
**恰好 21 个包全部降级**（因为老 SDK 的依赖约束更松）：

| 包 | HEAD | 现值 | | 包 | HEAD | 现值 |
|---|---|---|---|---|---|---|
| `characters` | 1.4.1 | **1.3.0** | | `path` | 1.9.1 | **1.9.0** |
| `clock` | 1.1.2 | **1.1.1** | | `stack_trace` | 1.12.1 | **1.12.0** |
| `collection` | 1.19.1 | **1.19.0** | | `stream_channel` | 2.1.4 | **2.1.2** |
| `fake_async` | 1.3.3 | **1.3.1** | | `test_api` | 0.7.9 | **0.7.3** |
| `leak_tracker` | 11.0.2 | **10.0.7** | | `url_launcher_android` | 6.3.30 | **6.3.17** |
| `leak_tracker_flutter_testing` | 3.0.10 | **3.0.8** | | `url_launcher_ios` | 6.4.1 | **6.3.3** |
| `leak_tracker_testing` | 3.0.2 | **3.0.1** | | `url_launcher_linux` | 3.2.2 | **3.2.1** |
| `matcher` | 0.12.18 | **0.12.16+1** | | `url_launcher_macos` | 3.2.5 | **3.2.2** |
| `material_color_utilities` | 0.13.0 | **0.11.1** | | `url_launcher_web` | 2.4.3 | **2.4.1** |
| `meta` | 1.17.0 | **1.15.0** | | `url_launcher_windows` | 3.1.5 | **3.1.4** |
| | | | | `vector_math` | 2.2.0 | **2.1.4** |

其中 **19/21 是「Flutter SDK 钉住的包」**（`pubspec.yaml` 里没有它们）
→ 换回 3.41.1 跑 `pub get` 时**大概率会被强制升回**，但**不保证**（`meta`/`path` 在 pubspec 里）。

🔑 **不靠「大概率」** —— 直接 `git checkout` 回滚到已验证可用的版本（确定性、零风险）。

**其他文件**：`git status` 显示只有 `app/pubspec.lock` 一个改动，其余干净。

---

## 七、修复方案（**均未执行，等你批**）

### 🔴 必做（2 条）

| # | 动作 | 命令 | 风险 |
|---|---|---|---|
| 1 | 回滚被改坏的 lock | `cd E:/CoEvo && git checkout -- app/pubspec.lock` | 🟢 零（回到已验证状态） |
| 2 | 用**全路径**重新构建 | `cd E:/CoEvo/app && D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64` | 🟢 零 |

### 🟠 建议（防止再犯）—— 三选一

| 方案 | 做法 | 评价 |
|---|---|---|
| **A. 项目内构建脚本**（推荐） | 加 `E:/CoEvo/app/build_apk.bat`，里面**硬编码** `D:\flutter\bin\flutter.bat`。以后跑 `build_apk.bat` 就不会踩 | 🟢 **不碰你的环境** · 对鸿蒙开发零影响 |
| B. 改 PATH 顺序 | 把 `D:\flutter\bin` 放到 `D:\flutter_flutter\bin` 前面 | 🔴 **可能影响你的鸿蒙/DevEco 工作** |
| C. FVM 版本锁定 | 项目加 `.fvmrc`，用 `fvm flutter` | 🟠 引入新工具链，成本最高 |

| # | 动作 | 风险 |
|---|---|---|
| 3 | ❌ **不要**按警告改 `build.gradle.kts`（§五） | —— |
| 4 | 可选：把 `app/assets/` 里两个 32 MiB 的 `.bak` 清掉（占磁盘、与交付物无关） | 🟢 |

---

## 八、影响范围

| 项 | 影响 |
|---|---|
| 代码 / 数据 | ✅ **无**（报错全在第三方包的**编译期**，`word.db` 未碰） |
| 已产出的 APK | ✅ 上次那个 82.6 MiB 的**仍可用**（用它跑的 3.41.1） |
| 鸿蒙开发 | ✅ **无影响**（`D:\flutter_flutter` 一字未动） |
| `app/pubspec.lock` | 🔴 **已降级 21 包** → 待回滚 |
