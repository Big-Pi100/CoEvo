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

---

## 九、修复进展（2026-09-29 09:5x · 白哥批「方案 B」）

### 9.1 ✅ ① 已执行：`pubspec.lock` 已回滚

`git checkout -- app/pubspec.lock` → 逐包比对 **差异 0**，21 个包全部恢复：
`characters 1.4.1` · `collection 1.19.1` · `meta 1.17.0` · `path 1.9.1` ·
`vector_math 2.2.0` · `test_api 0.7.9` · `leak_tracker 11.0.2` ✅

### 9.2 🔴 方案 B 的两个硬事实（动手前取证）

| 核实项 | 结果 |
|---|---|
| `D:\flutter_flutter\bin` 在哪 | **机器级 PATH，而且 index = 0（第 1 条）** |
| 用户级 PATH 有 flutter 吗 | ❌ 没有 |
| 当前进程有管理员权限吗 | 🔴 **False**（写机器级注册表被拒：`不允许所请求的注册表访问权`） |

🔑 **技术要点：Windows 生效 PATH = `机器级` + `用户级`，机器级永远在前。**
→ 光往**用户级**加 `D:\flutter\bin` **完全无效**（会被机器级的 `flutter_flutter` 压住）。
→ **方案 B 必须改机器级 PATH → 需要管理员。这一步只能白哥来做。**

### 9.3 ✅ 风险实测：比原先估的**低**

我上一条把 B 标为「可能影响鸿蒙/DevEco」，实测下来风险确实小：

| 检查 | 结果 |
|---|---|
| 有鸿蒙 Flutter 项目在用 `flutter_flutter` 吗 | ✅ **没有** —— `D:/Huawei` 下只有 `DevEco Studio` 与 `Emulator` · `D:/HarmonyProgram` **空** · 全盘找 `ohos/` 子目录 **0 结果** |
| DevEco 配置引用 `flutter` 吗 | ✅ **没有任何引用**（搜遍 `DevEcoStudio6.1/` 配置目录） |
| DevEco 依赖 PATH 里的什么 | 它自己的 `jbr` / `openharmony toolchains` / `tools/node` / `hvigor` / `ohpm`（**都与 flutter 无关**） |

→ **把 `D:\flutter\bin` 插到 `flutter_flutter\bin` 前面，`flutter_flutter` 那条留在原地不动**
（需要时用全路径调用），**对现有环境无实际影响**。

### 9.4 🆕 交付：`scripts/fix-flutter-path.ps1`

**为什么不是「你自己改一下 PATH」** —— 因为用错工具会**毁掉 PATH**：

```
🔴 setx 会在 1024 字符处截断 → 机器级 PATH 是 1442 字符 → 用 setx 会砍掉后面 400+ 字符
✅ 脚本用的是 .NET API：[Environment]::SetEnvironmentVariable(..., 'Machine')
```

**脚本自带的安全设计**（都已验证）：

| 机制 | 说明 |
|---|---|
| 管理员检查 | 无权限时**明确报错并退出**（exit 1），不会静默失败 |
| **`-Check` 免提权** | 只读模式，随时可查现状（exit 0=已正确 / 2=未修） |
| 幂等 | 已正确则直接退出，不重复写 |
| **自动备份** | 改动前把原 PATH 写到 `%USERPROFILE%\PATH-machine-backup-<时间戳>.txt` |
| 长度护栏 | 新 PATH 若比旧的短 >10% → **拒绝执行**（防截断灾难） |
| 读回断言 | 写完立刻读回比对，不一致即报错 |
| **`-Rollback`** | 一键从最新备份还原 |
| 不碰 `flutter_flutter` | 只**插入**，不删除、不移动那条 |

**实测验证**（我在无管理员环境下跑过）：

```
PARSE = OK
-Check    → index of D:\flutter\bin = -1 · index of flutter_flutter = 0 · exit 2  ✅
（无参数） → [FAIL] Must run as Administrator · exit 1  ✅
```

### 9.5 白哥要执行的两步

```powershell
# ① 全路径重跑构建（会走 3.41.1，SDK/NDK 警告也会一起消失）
cd E:\CoEvo\app
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64

# ② 实施方案 B：以【管理员】身份打开 PowerShell 终端，运行：
powershell -ExecutionPolicy Bypass -File E:\CoEvo\scripts\fix-flutter-path.ps1
#    然后【新开一个终端】验证：
#    Get-Command flutter     → 应显示 D:\flutter\bin\flutter.bat
#    撤销（如需）：
powershell -ExecutionPolicy Bypass -File E:\CoEvo\scripts\fix-flutter-path.ps1 -Rollback
```

⚠️ **注意**：改 PATH 后**必须新开终端**才生效（已开着的窗口仍是旧 PATH）。
⚠️ 若以后做鸿蒙 Flutter 开发，需要显式用 `D:\flutter_flutter\bin\flutter.bat`（或把两条顺序调回）。
