# 「本地无法 flutter run」根因报告

> 日期：2026-09-27 01:25（创建）· 01:40（**方案 A 已实施**）
> 触发：白哥实测 `D:\flutter\bin\flutter.bat run -d chrome` → `Failed to compile application`
> 状态：✅✅ **方案 A 已实施 + 真编译验证通过（2026-09-27 03:36）** —— 见 §九

---

## 〇、结论先行

| # | 结论 | 性质 |
|---|---|---|
| **1** | 我上轮写的「**本地无法 `flutter run`**」**是错的** —— 那是**我的工具沙箱**限制，白哥环境完全正常 | ✅ **已证伪**（见 §一） |
| **2** | 真正的阻塞：**项目当前只能在鸿蒙定制版 Flutter 上编译**，与官方 Flutter **不兼容** | 🔴 **真实缺陷** |
| **3** | 🔴 **CI 的两个 Flutter job 从 2026-05-26 起就不可能通过** —— 而文档一直记「验证链路已打通」 | 🔴 **需更正认知** |

---

## 一、结论 1 的证伪过程（我的错，先认）

**我上轮看到的崩溃**：

```
Command: D:\...\.workbuddy\binaries\PortableGit\...\mingw64\bin\git.EXE
         -c log.showSignature=false log -n 1 --pretty=format:%ar
CreateFile failed 231 (所有的管道范例都在使用中。)
```

崩在 **flutter 启动时调 git 算版本号**，而它调的是 **WorkBuddy 自带 PortableGit**（句柄继承把命名管道耗尽）。
白哥机器上没有这个 git → **这是「工具进程环境」层的限制，不可外推**。

**白哥实测结果**（全部正常）：

| 命令 | 结果 |
|---|---|
| `D:\flutter\bin\flutter.bat --version` | ✅ Flutter **3.41.1** stable · Dart 3.11.0 |
| `flutter doctor -v` | ✅ Windows / Android / Chrome / Visual Studio / 设备 / 网络 **全绿**（仅 PATH 警告） |
| `flutter pub get` | ✅ `Got dependencies!` |
| `flutter devices` | ✅ **3 个**（Windows desktop / Chrome / Edge） |
| `flutter run -d chrome` | 🔴 **Failed to compile application** ← 真问题在这 |

> 🔑 **教训已固化进 skill `verifiable-core-logic`**：「跑不起来」有三层（工具进程环境 / SDK / 项目），
> **结论不许跨层外推** —— 报失败必须写出崩溃命令的完整路径 + 标注适用范围。
> 判据：崩溃行的路径含代理目录 = ① 层；项目内 = ③ 层；SDK 目录 = ② 层。

---

## 二、结论 2：两个依赖与官方 Flutter 不兼容

编译错误共 **4 组**，全部集中在 **2 个包**，而这 2 个包**只被 1 个文件使用**：

```
app/lib/widgets/markdown_span_nodes.dart   (920 行)
  ├── import 'package:flutter_math_fork/flutter_math.dart';
  └── import 'package:gpt_markdown/gpt_markdown.dart';
        ↓ 被 4 个界面 import
     card_list_screen · review_screen · chat_message_bubble · review_card_widget
```

### 根因 A：`packages/flutter_math_fork` 是**鸿蒙定制降级版**

`app/pubspec.yaml` 用 `dependency_overrides` 把它指向了**仓库内的一份改写副本**：

```yaml
dependency_overrides:
  flutter_math_fork:
    path: packages/flutter_math_fork     # ← 仓库内 391 个文件，已入库
```

**实测差异**（对比 pub 官方 0.7.4）：

| 文件 | 改写内容 | 目的 |
|---|---|---|
| `render/layout/layout_builder_baseline.dart` | ❌ **删掉 `RenderObjectWithLayoutCallbackMixin`** · `runLayoutCallback()` → **`rebuildIfNecessary()`** | 适配**旧版 Flutter（3.27）**的 API 形态 |
| `widgets/selectable.dart` | ➕ `case TargetPlatform.ohos:` ×2 | 鸿蒙平台分支 |
| `render/layout/line_editable.dart` | ➕ `case TargetPlatform.ohos:` | 同上 |
| `widgets/selection/gesture_detector_builder_selectable.dart` | ➕ `case TargetPlatform.ohos:` | 同上 |

**判据（可信度最高的一条）**：

```
官方 0.7.4  lib/ 内 "ohos" 出现次数 = 0     ← 官方 Flutter 从无 ohos 这个平台
本地副本    lib/ 内 "ohos" 出现次数 = 4
```

且 **pub cache 里残留 `patch` 工具的 `.orig` 备份**（`selectable.dart.orig` 等 3 个）
→ 反证这份改写是**在官方版基础上手工打补丁**得到的。

> 🔑 **这不是「包坏了」，是「包被改成了只能在另一个 Flutter 分支上跑」。**

**时间线**：`git log -S "TargetPlatform.ohos"` → 补丁引入于 **`ac7a4a1` (2026-05-26)**，
即该副本**入库时就已是改写版**，四个月来一直是这个状态。

### 根因 B：`gpt_markdown: 1.0.8` 版本过旧

```
gpt_markdown-1.0.8/lib/custom_widgets/selectable_adapter.dart:45:7
  Error: The non-abstract class '_RenderSelectableAdapter' is missing implementations for:
   - SelectionHandler.contentLength
   - SelectionHandler.getSelection
```

**实测 API 差异**：

| SDK | `rendering/selection.dart` 里 `contentLength` / `getSelection` |
|---|---|
| 鸿蒙 3.27.5 | **0 次** → 1.0.8 能编译 ✅ |
| 官方 3.41.1 | **存在**（为 `SelectionHandler` 的抽象成员）→ 1.0.8 编不过 🔴 |

pubspec 里 `gpt_markdown: 1.0.8` 是**精确锁定**（无 `^`）→ 也从未升级过。
可升版本：**1.0.9**（本地 cache 已有）· **1.3.0**（latest）。

---

## 三、结论 3：CI 的两个 Flutter job 必然失败

`.github/workflows/ci.yml` 有两个 job 用官方 Flutter：

| job | 行 | 步骤 |
|---|---|---|
| `frontend` | 60 | `subosito/flutter-action@v2` + `channel: stable` → `flutter pub get` / `analyze` / `test` |
| （iOS） | 143 | 同上 → `flutter build ios --release --no-codesign` |

`flutter-action` 装的**必然是官方 Flutter**，而官方 Flutter **没有 `TargetPlatform.ohos`** →
**这两个 job 从 2026-05-26 起必然编译失败**：

| 时间 | 事件 |
|---|---|
| 2026-05-16 (`bb80da8`) | ci.yml 引入 |
| **2026-05-26 (`ac7a4a1`)** | **ohos 改写版 `flutter_math_fork` 入库 → 此后两个 Flutter job 不可能通过** |

> 🔴 **需更正认知**：项目记忆与文档里「CI 5 job 已打通」的说法**对这两个 job 不成立** ——
> 除非 workflow 从未启用 / 仓库未成功推送。**建议白哥在 GitHub Actions 页面确认一下历史运行记录。**

---

## 四、影响范围

| 项 | 范围 |
|---|---|
| 直接受阻 | **1 个文件**（`markdown_span_nodes.dart`，920 行）· **2 个包** |
| 间接受阻 | **4 个界面**（`card_list_screen` · `review_screen` · `chat_message_bubble` · `review_card_widget`） |
| **不受阻** | ✅ `flutter pub get` · `flutter analyze`（非编译）· 纯 Dart 验收脚本（`fsrs_verify` / `tokens_verify`，零 Flutter 依赖） |
| **本轮主题改动** | ✅ **与本次失败无关** —— 错误全部来自第三方包，无一条指向 `theme_builder` / `co_spacing` / `theme_provider` |

### 🔑 一个降低工作量的事实：`flutter_math_fork` 对本项目**零需求**

| 证据 | 结果 |
|---|---|
| 词库 `card.content` 含 LaTeX（`\frac` / `\text{` / `begin{` / `^{`） | **0 / 11,523** |
| `DisplayMathBlock`（该文件里唯一对外暴露的公式组件）外部调用点 | **0 处**（仅文件内自用） |
| 数学内容来源 | K12 课程（**已废止**，见记忆「不做 K12 相关内容」） |

→ **数学公式渲染是 K12 遗留**，本项目（英语阅读 App）**用不到**。

---

## 五、修复方案（3 个选项，**待批准**）

### 选项 A：移除本地改写副本，对齐官方 Flutter　✅ **白哥已选 · 已实施**

| 步骤 | 动作 |
|---|---|
| 1 | `pubspec.yaml` 删除 `dependency_overrides.flutter_math_fork` |
| 2 | 删除 `app/packages/flutter_math_fork/`（**402 个文件 · 3.1 MB · 已入库**） |
| 3 | `markdown_span_nodes.dart` 摘掉公式相关代码（`DisplayMathBlock` · `BlockType.displayMath` · `Math.tex` ×2 · `_addColorCmd` · `formulaRegex`） |
| 4 | 🆕 **`gpt_markdown: 1.0.8` → `1.0.9`**（修 `SelectionHandler` 缺失；**必须一起做**，否则仍编不过） |

- **理由**：与本项目「**仅 iOS + 官方 Flutter 是正确方向**」一致；公式能力**零需求**（K12 遗留）
- **收益**：错误全清 · 消掉一个只对鸿蒙生效的定制依赖 · 🔑 **很可能顺带修好 CI 那两个 job**（见下）
- **副作用**：⚠️ **此后在鸿蒙 Flutter 上编不过** —— 按「仅 iOS」定位这本就应放弃
- **实施细节与验证**：见 **§八**

> 🔴 **对原报告的一处修正**：这里原写「移除 `flutter_math_fork`」，**不准确** ——
> `flutter_math_fork` 是 **`gpt_markdown` 自己的依赖**（`^0.7.3`），**不能从依赖树移除**。
> 实际做的是：**移除我们的本地改写副本 + 去掉 override** → 回落到 pub **官方 0.7.4**。
> 对我们的代码而言，它**已不再被直接 import**（公式渲染已摘除）。

> 🔑 **顺带修复 CI 的推断**：CI 里 `flutter-action` 装的是官方 Flutter，它会**读仓库里的 `pubspec.yaml`** ——
> 原来有 `path: packages/flutter_math_fork` → 编译那份含 `ohos` 的改写版 → **必然失败**。
> 现在 override 已删 → **CI 会改用 pub 官方版** → 加上 `gpt_markdown` 1.0.9，
> **那两个 job 很可能就此转绿**（仍需白哥在 Actions 页面确认历史与本次运行）。

### 选项 B：只升级 `gpt_markdown`，`flutter_math_fork` 用官方版　🟡

| 步骤 | 动作 |
|---|---|
| 1 | `pubspec.yaml` 删掉 `flutter_math_fork` 的 override（回落 pub 官方 0.7.4） |
| 2 | `gpt_markdown: 1.0.8` → 试 `1.0.9` / `1.3.0` |
| 3 | 若 API 有变（`GptMarkdownThemeData` 等），修 `markdown_span_nodes.dart` 的调用处 |

- **理由**：保留公式能力（若未来内容扩展需要）
- **风险**：⚠️ **官方 0.7.4 用的是新版 mixin** → 在鸿蒙 Flutter 上**编不过**，等于**被迫二选一**
- **另一风险**：1.3.0 与 1.0.8 的 API 差异未知，**需实测**才知改动量

### 选项 C：把 `markdown_span_nodes` 改成不依赖这 2 个包　🟠

| 内容 | 自研极简渲染（粗体 / 标题 / 表格 / 分割线），去掉 2 个第三方依赖 |
|---|---|

- **理由**：该文件本来就**自带了表格渲染**（`_renderMarkdownTable` 等），`gpt_markdown` 只用于**行内文本**；
  卡片渲染体系正在重写（Step 3），**依赖自研更可控**
- **收益**：一次解决 **3.41 兼容 + 鸿蒙耦合 + 未来升级风险**三个问题
- **工作量**：中（920 行文件要大改）

### 我的建议

**A 先行（拿到能跑的版本 → 让白哥亲眼看主题），C 留到 Step 3 卡片重写时一并做。**

理由：A 工作量最小且方向正确；白哥当前目标是**验证三档主题**，不该被 K12 遗留挡住。

---

## 六、本次失败**没有**暴露的问题（避免误判）

| 项 | 状态 |
|---|---|
| 本轮主题改动（`theme_builder` / `co_spacing` / `theme_provider` / `app.dart` / 设置页） | ✅ **零牵连** —— 编译错误全在第三方包 |
| `tokens_verify` 267 项 | ✅ 全过（纯 Dart，不经 Flutter 编译） |
| `analyze_inproc` 自建分析器 | ✅ error=3/warning=13 与基线一致（**但它跑的是 AST 分析，不做编译** → 抓不到这类「下游包与 SDK 版本不匹配」的问题）|

> 🔑 **一条方法论**：自建分析器**验证不了「依赖能否编译」** ——
> 这类问题只有**真编译**（`flutter run` / `flutter build`）才暴露。
> 白哥这次跑 `flutter run` 的价值正在于此：**补上了静态分析的能力盲区**。

---

## 七、待白哥定

| # | 事项 | 状态 |
|---|---|---|
| **1** | 选 **A** / **B** / **C**？ | ✅ **已选 A，已实施**（见 §八） |
| **2** | CI 那两个 Flutter job 历史运行情况 —— 是否需要在 GitHub Actions 页面核实？ | ⏳ **待白哥确认**（方案 A 很可能已顺带修好，见 §五 末） |
| **3** | 「**本地无法 `flutter run`**」结论已在文档中更正 | ✅ 已完成 |

---

## 八、方案 A 实施记录（2026-09-27 01:40）

### ① 改动清单

| # | 对象 | 动作 | 规模 |
|---|---|---|---|
| 1 | `app/packages/flutter_math_fork/` | 🔴 **删除**（git rm） | **402 文件 / 3.1 MB** |
| 2 | `app/pubspec.yaml` | 删 `dependency_overrides.flutter_math_fork`（含 9 行说明注释） | +9 / −3 行 |
| 3 | `app/pubspec.yaml` | `gpt_markdown: 1.0.8` → **`1.0.9`**（含说明注释） | +2 / −1 行 |
| 4 | `app/lib/widgets/markdown_span_nodes.dart` | 摘除公式渲染 | **−44 行**（920 → 876） |

**包可恢复**（git 历史内）：`git checkout ac7a4a1 -- app/packages/flutter_math_fork/`

### ② 公式代码的处置 —— **优雅降级，不报错**

摘除的不只是「渲染调用」，而是整条链路：

| 摘除项 | 位置 |
|---|---|
| `import 'package:flutter_math_fork/flutter_math.dart'` | 文件头 |
| `DisplayMathBlock` 类（含 `Math.tex`） | 原 45–72 行 |
| `_addColorCmd`（`\textcolor` 注入 hack） | 原 74–89 行 |
| `BlockType.displayMath` 枚举值 + switch 分支 | 2 处 |
| `_splitBySpecialBlocks` 的 `\[...\]` 分割分支 | 正则 + else 分支 |
| `_buildRichCell` 的 `formulaRegex` 行内公式分支 | 3 处 |

🆕 **新增降级**（`_fixMarkdown` 第 3 步）：**剥离 LaTeX 定界符**
- `\[ x^2 \]` → 独立段落；`\( x \)` → 行内文本
- 🔑 **为什么剥而不是删**：内容**不能丢**。留着定界符会让用户看到裸反斜杠
  （`\[x^2\]` 在 markdown 里还会被当转义符吃掉一部分），剥掉后 `x^2` 至少可读
- ⚠️ 这是**降级**而非支持 —— 不假装能渲染数学，只是不让它变乱码

### ③ ✅ 验证（静态层面全部通过）

| 验证 | 结果 |
|---|---|
| `markdown_span_nodes.dart` 单文件分析 | ✅ **0 / 0 / 0** |
| 全库静态分析 | ✅ **error=3 / warning=13 / info=7** 与基线**完全一致** |
| `tokens_verify` 回归 | ✅ **267 项全过 / 0 实现失败 / 0 规格冲突** |
| 全库 `flutter_math_fork` 直接引用 | ✅ **0 处**（仅剩注释里的历史说明） |
| `packages/flutter_math_fork` 路径引用 | ✅ **0 处**（`.gitnexus/meta.json` 是索引工具缓存，会自更新，**按既有教训不动**） |
| `pubspec.yaml` YAML 合法性 | ✅ 通过（`gpt_markdown: 1.0.9` · overrides 仅剩 `http`） |
| 🆕 `pubspec.lock` | ✅ **已在沙箱内修正** —— 跑通了 `dart pub get --offline` → `flutter_math_fork` **0.7.4（hosted，不再指 path）** · `gpt_markdown` **1.0.9** |
| CI / analysis_options 引用残留 | ✅ 均无 |
| reference 2 个包版本 | ✅ `gpt_markdown` 1.0.9 已实现 `contentLength`/`getSelection` |

### ④ 🔴 剩余风险（**必须真编译才能确认**）

我对**官方 `flutter_math_fork` 0.7.4** 做了静态 API 核对，全部通过：

| 检查项 | 官方 0.7.4 | Flutter 3.41 | 结论 |
|---|---|---|---|
| `TargetPlatform.ohos` | **0 处** | 无该平台 | ✅ 不报 ohos 错 |
| `RenderObjectWithLayoutCallbackMixin` | **有**（L26）+ `runLayoutCallback()` | 有 | ✅ 不报 mixin 缺失 |
| Flutter `Selectable` mixin | **未使用**（54 处 `Selectable` 全是它自己的 `SelectableMath`） | 存在 | ✅ 不涉及 |
| selection API | 用 `TextSelectionPoint`（**公开稳定 API**） | 存在 | ✅ |

> ⚠️ **但这不等于「一定能编过」** —— 上面只覆盖了**已知的 3 类错误**。
> Flutter 3.41 相对 0.7.4 的其它 API 漂移**无法静态穷尽** → **必须真编译**（§九）。
>
> 🔑 与「自建分析器验证不了依赖能否编译」是同一个道理（见 §六）：**静态核对有上限，真编译才是终判。**

#### 🆕 一次失败的尝试：想用自建分析器**预判**依赖包兼容性（**此路不通，勿重试**）

我的 `analyze_inproc` 是同进程分析器（不受沙箱子进程限制），于是试着直接分析
`pub cache` 里的官方 `flutter_math_fork-0.7.4` —— 期望提前知道它是否兼容。

**结果是 2,043 个 error**，但**这是假错误**：

| error 类型 | 数量 | 说明 |
|---|---:|---|
| `undefined_class` | 538 | 🔴 连基础符号都解析不出来 |
| `undefined_identifier` | 452 | 同上 |
| `undefined_method` / `undefined_function` | 441 | 同上 |
| `uri_does_not_exist` | 119 | **import 都找不到** |
| 其余（`non_constant_map_value` 等） | 493 | 连带噪声 |

→ 这是**典型「解析上下文缺失」**：分析器依赖**项目的** `.dart_tool/package_config.json`，
无法为任意 `pub cache` 包建立正确的 SDK / 依赖上下文（那个包有自己的一套依赖）。

> 🔑 **结论：依赖包能否编译，只有真编译能验。** 我把这条路试过了，走不通。
> 同类的「已知可行」与「已知不可行」，都值得写下来 —— 省下后人一次徒劳尝试。

> ✅ **顺带的新事实**：`dart pub get` **可以在沙箱内跑通**（它不需要 `analysis_server` 子进程）
> —— 这与 `dart analyze` 必崩（`AnalysisServer._startProcess`）形成对比。
> **「某个 dart 命令跑不了」不能推广到所有 dart 命令**，要逐个试。

### ⑤ 🔑 一处方法论收获（已固化进 skill `safe-bulk-deletion`）

**「删除」有三种深度，风险递增**：

| 深度 | 例 | 风险 |
|---|---|---|
| 删**文件** | 删一个页面 | 编译报错 → 能发现 ✅ |
| 删**引用** | 删 import / 配置 | 编译报错 → 能发现 ✅ |
| 🔴 删**唯一提供者** | 上轮删 `app_theme.dart` | **不报错、静默降级** ⚠️ |

本轮是第四种：**删「被改写的依赖」** —— 它既不是孤儿也不是唯一提供者，
**而是别人的依赖树里的一员**（`gpt_markdown` → `flutter_math_fork`）。
→ 教训：**判断「能不能删」要先看依赖图，不只是引用图。**

---

## 九、✅ 真编译验证通过（2026-09-27 03:36 · 白哥执行）

```powershell
cd E:\CoEvo\app
D:\flutter\bin\flutter.bat run -d chrome
```

**结果：编译通过，Chrome 正常启动应用。**

```
Launching lib\main.dart on Chrome in debug mode...
Waiting for connection from debug service on Chrome...  89.1s
Flutter run key commands.  (r/R/h/d/c/q)
A Dart VM Service on Chrome is available at: http://127.0.0.1:54095/...
Starting application from main method in: org-dartlang-app:/web_entrypoint.dart.
tryRestore: 开始时恢复认证... → 完成 (isRestored=true)
```

| 验证项 | 结果 |
|---|---|
| **官方 Flutter 3.41.1 / Dart 3.11.0 真编译** | ✅ **通过** ← 方案 A 唯一的未知项 |
| `flutter_math_fork` **0.7.4（pub 官方版）** 能否编译 | ✅ **能**（此前是鸿蒙改写版才编不过） |
| `gpt_markdown` **1.0.9** | ✅ 通过 |
| 应用启动（认证恢复 `tryRestore` 流程） | ✅ 正常执行 |

> 🔑 **推论：方案 A 成立** —— 「删掉鸿蒙改写副本 + 删 override + 回落 pub 官方 0.7.4」这条路**走通了**。
> 同时反证 §六 的结论：**自建 AST 分析器验证不了的「依赖能否编译」，一次真编译就给出答案**。

### 📌 顺带诊断：启动后界面仍是 K12 时代页面（**与本次改动无关**）

白哥反馈「看上去是旧版的界面」。**已核实 —— 不是主题没生效，而是页面层本身还是 K12 遗留**：

| 页面 | 行数 | 实际内容 |
|---|---:|---|
| `screens/home_screen.dart` | 475 | 🔴 **K12 科目直选页**（`getK12Subjects()` → `/api/k12/subjects`；「选择科目开始结构化学习」+ 年级选择 → `k12Init`） |
| `screens/review_screen.dart` | 1,533 | 🔴 「**英语 tab + 汉语 tab** + 全部卡片」（多学科遗留） |
| `screens/achievements_screen.dart` | 999 | 🔴 `_k12Progress`（K12 进度） |

**主题层已生效**（代码核实：`inkTokens.page = 0xF1EDE4` · `accent = 0xB4432C`，
与设计稿 `visual-feed-bookmark-2026-09-25.html` 的 `[data-theme="ink"]` **色值完全一致**），
`app.dart` 接线正确（浅色槽 `allTokens[ink]` / 深色槽 `nightTokens`）。

→ **页面层重写 = Step 3**（`plan-and-progress` §480 早已明确：「`home_screen` 本质就是 K12 学科选择页，要整体重写成信息流首页」）。

---

## 十、一句话总结

**项目原本只在鸿蒙定制版 Flutter 上能编译** —— 根因是仓库里存着一份为鸿蒙降级改写的 `flutter_math_fork` 副本
（由 `dependency_overrides` 指向）+ 一个版本过旧的 `gpt_markdown`。两者均已处置，**回到官方 Flutter 路线**；
公式渲染随之移除（对本项目**零需求**，属 K12 遗留）。
静态层面全部通过（全库 error=3/warning=13 与基线一致 · tokens 验收 267 项全过），
**✅ 且真编译已通过（2026-09-27 03:36，`flutter run -d chrome` 成功启动应用）** —— 本问题**闭环**。

> ⚠️ 唯一未变的是**页面本身还是 K12 遗留**（首页=科目直选 / 复习页含汉语 tab / 成就页=K12 进度）——
> 那属于 **Step 3 核心界面重写**的范围，不是本问题的遗留。
