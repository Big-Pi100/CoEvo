# 修 CI 红：未使用的 import（warning 级）+ 增强本地检查工具（2026-10-03）

> **起因**：白哥贴出 CI 的 `flutter analyze --no-fatal-infos` 输出 —— **57 issues · exit 1**
>
> **结论**：✅ 已修（1 行）· ✅ 工具已增强并**证伪** · ⏳ 请重新出包

---

## 一、根因：**只有 1 条 warning 致命，其余 56 条 info 都不致命**

CI 的判据是 `flutter analyze --no-fatal-infos`：

| 档 | 是否致命 |
|---|---|
| `error` | ✅ 致命 |
| **`warning`** | ✅ **致命（`--no-fatal-infos` 不含 warning）** |
| `info` | ❌ 不致命 |

那 57 条里 **56 条是 info**（`avoid_print` 等），**只有 1 条 warning**，而它正是我引入的：

```
warning • Unused import: '../services/interest_selection.dart' • lib/screens/home_screen.dart:17:8
```

### 为什么会多这个 import

我加它是想用 `InterestSelection` 类型，但实际写的是：

```dart
_feedKey = interestKeyOf(ref.watch(interestProvider).valueOrNull);
```

`interestKeyOf` 来自 `interest_provider.dart`；它的**参数类型**由 inference 处理
⇒ **不需要显式 import** `interest_selection.dart`（该文件唯一的公开符号是 `InterestSelection`，
而我从未在 home_screen 里写出这个类型名）。
⇒ 这个 import **从头到尾没被用过**。

**修复**：删掉那一行。

---

## 二、🔴 我的本地工具为什么没抓到（这才是重点）

上一轮刚建的 `scripts/codestatic` **只过滤了 `Severity.error`**：

```dart
if (d.severity != Severity.error) continue;   // ← 🔴 跳过了 warning
```

而 CI 的判据是 `--no-fatal-infos` ⇒ **warning 也致命**。
⇒ **本地「全绿」而 CI 红**。

### 📌 判据（已固化）

> **「本地检查的判据」必须与「CI 的判据」逐条对齐** —— 包括「**哪一档算失败**」。

这不是「忘了改一个常量」，而是**两个门禁的判据集不一致** —— 这类不一致**不会报错**，
只会让本地绿灯**失去意义**。

### 修复后的档位（**刻意对齐 CI**）

| 档 | 是否判失败 | 对应 CI |
|---|---|---|
| `error` | ✅ | 默认致命 |
| `warning` | ✅ | `--no-fatal-infos` **不含** warning ⇒ 致命 |
| `info` | ❌（`--strict` 才判）| `--no-fatal-infos` 让 info 不致命 |

用法：`dart run bin/check.dart <目录>` · `--strict` · `--all`

### 证伪（**先证明新建的判据真的有效**）

| 注入 | 期望 | 结果 |
|---|---|---|
| 加一行 `import 'dart:math';`（必然未使用）| 红 | ✅ 退出码 **1**，精确报出 `Unused import: 'dart:math'.` |
| 还原 | 绿 | ✅ 退出码 0 |

两次均**字节级还原** ✅

---

## 三、⚠️ 另一个必须说清的边界：**lint 规则未覆盖**

实测同一份代码：**我的工具报 7 条，CI 报 57 条** —— 差的 **50 条全是 lint 规则**
（`avoid_print` / `depend_on_referenced_packages` / `use_build_context_synchronously` …）。

**为什么**：接 lint 需要 `import 'package:analyzer/src/lint/registry.dart'`
（**`src/` 内部 API**，不受语义化版本保护）+ 自行解析 `analysis_options.yaml`
+ 注册 `flutter_lints` 规则实例 ⇒ **脆弱、易随版本崩**，
而收益只是「把**不致命**的 info 也搬过来」。

⇒ **不做，如实写明边界。**

### 但「不覆盖 lint」仍然够用（对「防 CI 红」而言）

CI 的 57 条里**只有 1 条 warning**（`unused_import`，**内建**）—— 本工具**抓得到** ✅
而 flutter_lints 的规则**几乎全是 info**（不致命）。

**结论**：对「防 CI 红」够用；**但 lint 相关问题请以 CI 为准**。

---

## 四、🔴 比工具更重要的：流程建议

**改了 `app/lib` 之后、出包之前，先推 `main` 让 CI 跑 `frontend` job。**

理由：`flutter analyze` 是**权威判据**（含 lint 与全部 warning），本工具**不覆盖 lint**；
而推 main 的成本**几乎为零**（**推 main 不会部署** —— 部署 job 都要 tag）。

> 🔴 **这次事故的直接教训**：我改了 `app/lib`，**没等 CI 就出包** ⇒ 出包/CI 时才发现。
> 上下文：上一轮我刚因为「本机无法编译验证」建了工具，却**没同时建立「出包前先过 CI」的流程** ——
> 工具补了「能查到什么」，但没补「**什么时候必须跑**」。

---

## 五、验证

| # | 项 | 结果 |
|---|---|---|
| ① | 整包（= CI 分析范围）符号解析 + 内建诊断 | ✅ **error 0 · warning 0** · info 7 · 退出码 0 |
| ② | 五个 Dart 断言脚本 | ✅ 全绿（`verify_feed_wiring` **63 项**）|
| ③ | 语法检查（改动的 2 文件）| ✅ |
| ④ | 工具**双向证伪**（含未使用 import 新用例）| ✅ |

⚠️ **重要**：① 的 `warning 0` 是**本工具口径**；**lint 部分仍需 CI 确认**（§三）。
但本次 CI 红的唯一原因（`unused_import`）**属内建 warning，已被本工具覆盖** ✅
⇒ **CI 应当变绿**。

---

## 六、产出物

| 文件 | 说明 |
|---|---|
| `app/lib/screens/home_screen.dart` | 删掉未使用的 import（1 行，**CI 红的唯一原因**）|
| `scripts/codestatic/bin/check.dart` | 按 severity 分档 · **判据对齐 CI** · `--strict` / `--all` |
| `scripts/codestatic/README.md` | 新增「先看边界」节（含 7 vs 57 的差异与原因）· 流程建议 |

---

## 七、⏳ 请白哥

1. **看一次 CI**（`v0.1.4` tag 或这次 push）—— 确认 `frontend` job 变绿
2. **再出包**（命令不变）
   ```bat
   cd E:\CoEvo\app
   D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
   ```
