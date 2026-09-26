# 进程内静态分析（`scripts/analyze_inproc/`）

## 为什么存在

2026-09-26 实测发现：本机**无法创建任何子进程**。

```
$ dart analyze
CreateFile failed 231 (所有的管道范例都在使用中)   ← ERROR_PIPE_BUSY
ProcessException: ... Command: dartaotruntime.exe analysis_server_aot.dart.snapshot ...
#2 AnalysisServer._startProcess (package:dartdev/src/analysis_server.dart:218)
```

`dart analyze` / `flutter analyze` 在**架构上必须 `Process.start()` 一个
`analysis_server` 子进程**，所以在本机环境下必然失败。

**关键：这与 Flutter 是官方版还是鸿蒙定制版无关** —— 实测两个 SDK 崩在同一行：

| SDK | 版本 | `dart analyze` |
|---|---|---|
| `D:\flutter`（官方 stable） | Flutter **3.41.1** / Dart **3.11.0** | 🔴 崩（`AnalysisServer._startProcess`） |
| `D:\flutter_flutter`（鸿蒙定制） | Flutter 3.27.5-ohos / Dart 3.6.2 | 🔴 崩（同一行） |

**但 `dart run <脚本>` 是同进程执行**，可以正常工作 → 于是把分析器跑在本进程内。

## 用法

```bash
cd scripts/analyze_inproc
DART=/d/flutter/bin/cache/dart-sdk/bin/dart.exe     # 官方版 Dart 3.11.0

$DART run bin/analyze.dart /e/CoEvo/app/lib
$DART run bin/analyze.dart /e/CoEvo/app/lib/services/fsrs_service.dart
$DART run bin/analyze.dart /e/CoEvo/app/lib --errors-only --quiet
```

- **退出码 0 = 无 error；1 = 有 error；2 = 用法错误** → 可挂 CI / pre-commit
- `--errors-only` 只看 error · `--quiet` 不打统计（便于管道）

## 能力边界（重要）

| 能查 | 不能查 |
|---|---|
| ✅ 语法错误、类型错误、未定义引用、未解析 import | ❌ **真正的平台编译**（`flutter build ios` 只能在 CI 上跑） |
| ✅ 未使用成员 / 未使用 import / 弃用 API | ❌ Flutter 特有的 widget 约束检查 |
| ✅ **平台可用性** —— 🆕 **本脚本自建**（见下） | ❌ 完整 lint 规则集（`flutter analyze` 在 CI 上更全） |

### 🆕 自建「平台可用性」判据（补上 analyzer 的缺口）

**为什么 analyzer 查不出 `dart:html`**：它用完整 Dart SDK，`dart:html` 作为 web 库**是存在的**，
所以 import 本身合法 —— 只有面向 mobile 真正编译时才报错。

**→ 于是本脚本自己扫 AST 的 import 指令**，命中 web-only 库即判 **ERROR**：

```dart
const _kWebOnlyLibraries = {
  'dart:html', 'dart:js', 'dart:js_util', 'dart:js_interop',
  'dart:indexed_db', 'dart:svg', 'dart:web_audio', 'dart:web_gl',
  'dart:web_sql', 'dart:ui_web',
};
```

**实测收益**（`app/lib`）：命中的库是 `dart:html`(11) + `dart:js`(3) + **`dart:ui_web`(1)** ——
🔴 **`dart:ui_web` 是原来 grep 口径 `dart:(html|js)` 会漏掉的**（`admin_campaign_detail.dart`）。
`check_native_readiness.py` 的 grep 口径已同步扩展。

```bash
# 只看 error（含 web-only 判据）—— Step 1 清障的验收命令
$DART run bin/analyze.dart /e/CoEvo/app/lib --errors-only
# → error=15（13 个文件 · web-only import 15 处）  ← 清障完成后应变为 0
```

用 `--no-web-check` 可关掉这一层，只跑纯 analyzer。

### 实测（2026-09-26，`app/lib` 76 文件）

```
分析文件 76 个 · 耗时 ~22-36 s
error=15（全部为 web-only 库）  warning=16  info=35
```

→ **除去 web-only 那 15 处，`app/lib` 在语义层是干净的**（0 个语法/类型/引用错误）。
这是「Step 1 清障改完能不能过」的第一道闸。

## 与 CI 的分工

| 层 | 工具 | 查什么 |
|---|---|---|
| 本地 · 静态 grep | `scripts/check_native_readiness.py` | `web-only` 库残留、admin 残留、代码量（**快，但受注释/字符串干扰**） |
| **本地 · 语义分析** | **本脚本** | **类型 / 引用 / 未使用 + `web-only` 库判据（按 AST，不受注释干扰）** |
| 本地 · 纯 Dart 逻辑 | `scripts/fsrs_verify/`（19 + 39 项断言） | FSRS 调度行为 |
| CI · 编译验证 | GHA ubuntu `flutter analyze`（完整 lint） | 与本地分析叠加，规则更全 |
| CI · 平台构建 | GHA **macOS** `flutter build ios --no-codesign` | 🔴 **最终裁决 —— 真正编译一次，任何残留都会暴露** |

## 两个前置条件（踩坑记录）

**① `dart pub get` 必须加 `--offline`**

```bash
FLUTTER_ROOT='D:\flutter' dart pub get --offline
```

- 不加 `--offline` 会**卡在 `Resolving dependencies...` 直到超时**（联网环节慢，实测 300 秒未返回）
- 加 `--offline` 用 pub 缓存，**秒级完成**
- 在 Flutter 项目里要用 `dart pub get`（不是 `flutter pub get`，后者崩在 fork），并显式给 `FLUTTER_ROOT`

**② 路径必须是平台规范化格式**

analyzer 会抛 `Only absolute normalized paths are supported` —— Windows 下必须传
`E:\CoEvo\app\lib`，**不能是 `E:/CoEvo/app/lib`**。脚本已自动转换。

## analyzer 版本

拉的是 **analyzer 14.4.0**（与 Dart 3.11 配套）。注意 analyzer 8+ 的 API 变化：

- `Severity` 从 `package:analyzer/error/error.dart` 移到了 **`package:analyzer/diagnostic/diagnostic.dart`**
- `errors` 是 `List<Diagnostic>`（不再是 `AnalysisError`）
