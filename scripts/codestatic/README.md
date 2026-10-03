# codestatic —— 本地「符号解析」检查

用 `package:analyzer` 做**编译级**诊断。**本机 `flutter analyze` / `dart analyze` 会崩时的替代**。

## 为什么需要它（2026-10-03 的真实事故）

本机 Flutter 是**鸿蒙定制版**：`flutter analyze` / `dart analyze` 一律崩
（`CreateFile failed 231`，analysis_server 起不来）。
于是长期只能靠 `dart format --output=none` 做**语法**检查 ——
🔴 **而「语法通过」≠「能编译」**。

那次事故（`flutter build apk` 失败）：

```
lib/screens/profile_screen.dart:653:31: Error:
  The getter 'kCategoryLabels' isn't defined for the type '_ProfileScreenState'.
```

- `kCategoryLabels` 原叫 `_categoryLabels`，是 **`FeedItem` 的私有静态成员**
- 兴趣界面要复用它 ⇒ 改名去私有，**但位置没动**（仍在类内）
- 而 `k` 前缀在本项目是**顶层常量**惯例（`kFeedPageSize` / `kInterestPrefsKey` …）
  ⇒ 调用方按惯例**裸写** ⇒ **解析不到**
- ⚠️ `dart format --output=none` **完全通过**（语法没错）；CI 的源级字符串断言
  （`feedItem.contains('kCategoryLabels')`）也**报了 ✅** —— 因为「字符串存在」≠「引用可解析」

⇒ 本脚本直接调用 analyzer **库**（**不经 analysis_server**）⇒ 不受那个崩溃影响。

## 用法

```bash
cd scripts/codestatic
dart pub get          # 首次
dart run bin/check.dart "E:/CoEvo/app/lib"        # 全量
dart run bin/check.dart "E:/CoEvo/app/lib/screens"  # 单目录（快）
```

- 退出码 **0** = 0 个 error；**1** = 有 error；**2** = 用法/路径错
- 🔴 路径必须是**绝对且规范化**（Windows 上用 `\`）—— 脚本内部已做

## 前提

`app/.dart_tool/package_config.json` 必须存在且含 **`sky_engine`**
（它是 `dart:ui` 的来源）—— 实测本项目有 ✅。
若缺它会输出大量「`Target of URI doesn't exist: 'dart:ui'`」——
脚本把这类归为**噪音**（单独列出、**不计入判定**），避免淹没真错误。

## 与其它检查的分工（**互补，不是替代**）

| 手段 | 能力 | 局限 |
|---|---|---|
| `dart format --output=none` | **语法**（AST 能否解析）| ❌ 查不出「符号解析不到」（本次事故）|
| **本脚本** | **符号解析**（编译级 error）| ❌ 查不出 lint 规则（`flutter analyze` 的 info/warning）；不跑代码 |
| CI 的 `flutter analyze --no-fatal-infos` | 官方、**全量规则** | 需要推 CI（我**无法**查私有仓库结果）；本机跑不了 |
| 真机运行 | 行为/视觉 | 慢，且只覆盖走过的路径 |

## 为什么不接进 CI

**CI 已经有更强的**：`frontend` job 跑官方 `flutter analyze --no-fatal-infos`
（官方 Flutter 3.41.1，规则集完整）。本脚本的定位是**本机补救** ——
补上「本地唯一能做的只有语法检查」这个缺口。
⇒ 再接一个依赖很重（analyzer 十几个包）的 job 只会拖慢 CI，**收益为零**。

📌 判据：**能进 CI 的只有「自带全部输入且不重复既有门禁」的** —— 本条两条都不满足。

## 实测记录（2026-10-03）

```
修复前（kCategoryLabels 在类内 + 调用方裸写）→ 检出该 error
修复后 → 扫描 99 个 .dart，0 error
证伪   → 注入「符号不在顶层」⇒ 退出码 1；还原 ⇒ 0（字节级还原一致）
```

⚠️ 证伪过程中发现并修掉了脚本自身的一个**致命 bug**：
`main` 里 `return 1` **不会**变成进程退出码（Dart 的 `main` 返回值不用作退出码）
⇒ 脚本**检测到了 error 却仍返回 0** ⇒ 门禁完全失效。
✅ 修法：显式 `exitCode = 1`。📌 **这正是「门禁必须证伪过」的价值** ——
只跑一次「全绿」的用例，这个 bug 永远不会暴露。
