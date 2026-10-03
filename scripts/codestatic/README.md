# codestatic —— 本地「符号解析 + 内建诊断」检查

用 `package:analyzer` 做**编译级**诊断。**本机 `flutter analyze` / `dart analyze` 崩时的替代**。

## 🔴 先看边界（**它能做什么、不能做什么**）

| 档 | 本工具 | CI（`flutter analyze --no-fatal-infos`）|
|---|---|---|
| `error`（符号解析/类型/语法）| ✅ **覆盖** | ✅ |
| `warning`（含 `unused_import` 等**内建** warning）| ✅ **覆盖** | ✅ **致命** |
| `info`（内建：deprecated 等）| ✅ 覆盖 | ✅ 不致命 |
| **`info`（lint 规则，如 `flutter_lints` 的 `avoid_print` / `depend_on_referenced_packages` / `use_build_context_synchronously` …）** | ❌ **未覆盖** | ✅ **不致命** |

⚠️ **实测差距（2026-10-03）**：同一份代码，本工具报 **7** 条、CI 报 **57** 条 ——
差的 **50 条全是 lint 规则**（且**全为 info 级**）。

### 为什么「不覆盖 lint」仍然够用（对「防 CI 红」而言）

CI 的判据是 `--no-fatal-infos` ⇒ **只有 `error` 与 `warning` 致命**。
而**内建 warning 已被覆盖** + flutter_lints 的规则**几乎全是 info**
⇒ 实测那 57 条里**只有 1 条 warning**（`unused_import`，内建），**本工具抓得到**。

### 为什么不去接 lint

需要 `import 'package:analyzer/src/lint/registry.dart'`（**`src/` 内部 API**，不受语义化版本
保护）+ 自行解析 `analysis_options.yaml` + 注册规则实例 ⇒ **脆弱、易随版本崩**，
而收益只是「把不致命的 info 也搬过来」。**判据：成本高、收益低 ⇒ 不做，如实写明边界。**

🔴 **所以：`lint` 相关的问题，请以 CI 的 `flutter analyze` 为准。**

---

## 为什么需要它（2026-10-03 的两次真实事故）

本机 Flutter 是**鸿蒙定制版**：`flutter analyze` / `dart analyze` 一律崩
（`CreateFile failed 231`，analysis_server 起不来）。
于是长期只能靠 `dart format --output=none` 做**语法**检查 ——
**而「语法通过」≠「能编译」也≠「能过 CI」**。

| # | 事故 | 本工具能否抓 |
|---|---|---|
| ① | `kCategoryLabels` 改名后仍在 `FeedItem` 类内，调用方按「`k` = 顶层常量」惯例裸写 ⇒ **符号解析不到** ⇒ `flutter build` 失败 | ✅ **error 级** |
| ② | 多写了一个**未使用的 import** ⇒ CI 的 `warning` ⇒ **CI 红** | ✅ **warning 级** |

两次 `dart format --output=none` **都完全通过**（语法没错）。

⇒ 本脚本直接调用 analyzer **库**（**不经 analysis_server**）⇒ 不受那个崩溃影响。

---

## 用法

```bash
cd scripts/codestatic
dart pub get                                    # 首次

# ✅ 推荐：分析整个 app 包（**与 CI 的分析范围一致**，含 tool/）
dart run bin/check.dart "E:/CoEvo/app"

dart run bin/check.dart "E:/CoEvo/app/lib"      # 只 lib（更快）
dart run bin/check.dart "E:/CoEvo/app" --all    # 列出 info 明细
dart run bin/check.dart "E:/CoEvo/app" --strict # 连 info 也判失败（更严）
```

- 退出码：**0** = 口径内通过 · **1** = 不通过 · **2** = 用法/路径错
- 默认判定口径 = **error + warning 判失败**（**刻意与 CI 的 `--no-fatal-infos` 对齐**）
- 🔴 路径必须**绝对且规范化**（Windows 用 `\`）—— 脚本内部已做

## 前提

`app/.dart_tool/package_config.json` 必须存在且含 **`sky_engine`**
（`dart:ui` 的来源）—— 实测本项目有 ✅。
若缺它会输出大量「`Target of URI doesn't exist: 'dart:ui'`」——
脚本把这类归为**噪音**（单独列出、**不计入判定**），避免淹没真问题。

## 与其它检查的分工

| 手段 | 能力 | 局限 |
|---|---|---|
| `dart format --output=none` | **语法**（AST 能否解析）| ❌ 查不出符号解析（事故①）|
| **本脚本** | **符号解析 + 内建诊断**（error/warning/info）· 判定口径对齐 CI | ❌ **不覆盖 lint 规则**；不跑代码 |
| CI `flutter analyze --no-fatal-infos` | 官方、**全量规则**（含 lint）| 需推 CI |
| 真机运行 | 行为/视觉 | 慢，只覆盖走过的路径 |

## 为什么不接进 CI

CI 已有**更强**的官方 `flutter analyze`（规则集完整，含 lint）。
本工具定位是**本机补救** ⇒ 再接一个依赖十几个包的 job 只会拖慢 CI，**收益为零**。
📌 判据：**能进 CI 的只有「自带全部输入且不重复既有门禁」的** —— 本条两条都不满足。

---

## 🔴 流程建议（比工具本身更重要）

**改了 `app/lib` 之后、出包之前，先推 `main` 让 CI 跑 `frontend` job。**

理由（事故②的直接教训）：`flutter analyze` **能列出 lint 与全部 warning**，
是**权威判据**；而本工具**不覆盖 lint**。
推 main 的成本几乎为零（**推 main 不会部署** —— 部署 job 都要 tag）。

> 事故②就是「**改了 app/lib 却没等 CI，直接出包**」⇒ 出包时才发现 unused import。

---

## 实测记录（2026-10-03）

```
事故①修复前（kCategoryLabels 在类内）→ 检出该 error
事故①修复后 → 99 个 .dart · 0 error
证伪① 注入「符号不在顶层」      → 退出码 1（精确报出）· 还原 → 0 · 字节级还原 ✅
证伪② 注入「未使用的 import」    → 退出码 1（精确报出 unused_import）· 还原 → 0 · 字节级还原 ✅
整包 app：error 0 · warning 0 · info 7 → 退出码 0（口径内通过）
```

⚠️ 开发这个工具时发现并修掉了它**自身**一个致命 bug：
`main` 里 `return 1` **不会**变成进程退出码（Dart 的 `main` 返回值不用作退出码）
⇒ 脚本**检测到了 error 却仍返回 0** ⇒ 门禁完全失效。✅ 修法：显式 `exitCode = 1`。
📌 **这正是「门禁必须证伪过」的价值** —— 只跑一次「全绿」的用例，这个 bug 永远不会暴露。
