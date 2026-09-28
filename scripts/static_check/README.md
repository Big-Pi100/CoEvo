# static_check —— 语义级静态分析（补 `dart format` 抓不到的那一半）

## 为什么有这个目录

**背景（2026-09-28 白哥构建失败）**：

```dart
// aggregate_page_screen.dart —— 实例方法里用了 context
Widget _topBar(CoEvoTokens t) {
  ... onTap: () => context.pop() ...   // 🔴 Error: The getter 'context' isn't defined
}
```

我在本地跑 `dart format --output=none` **通过**（语法完全正确）→ 错误留到白哥
跑 `flutter build apk --release` 才暴露。

🔑 **根因：「语法通过」≠「能编译」** —— 两者检查强度差一个数量级：

| 工具 | 检查什么 | 抓得到「未定义符号」吗 |
|---|---|---|
| `dart format` | **只语法解析**（括号配对、语句结构） | ❌ **完全看不见** |
| **本目录** | **语义分析**（名字解析、类型、作用域） | ✅ |

而我这边的环境**跑不了 `flutter analyze` / `dart analyze`**
（`CreateFile failed 231`：Dart 进程 spawn 子进程时 `CreateNamedPipe` 失败）。

## 怎么做成的

`package:analyzer` 是**纯 Dart 包** → 用 `dart run` 直接跑，
**不 spawn 额外的分析进程**（那正是崩溃的环节）。
它借 `app/.dart_tool/package_config.json`（182 个包）解析 `package:flutter/...`
→ 因此能真正分析 Flutter 代码。

```powershell
cd E:\CoEvo\scripts\static_check
D:\flutter\bin\dart.bat run bin/check.dart
```

⚠️ 必须用**完整路径**的 `dart.bat` —— PATH 里的 `dart` 是鸿蒙版（语言上限 3.6）。

## 判据

| 级别 | 是否门槛 | 说明 |
|---|---|---|
| `error` | 🔴 **必须为 0** | 真编译错误（未定义符号、类型不匹配…） |
| `unused_import` / `unused_element` / `unused_field` | 🟡 **该修** | **删代码留下的语义残留**（项目判据：删功能要清语义残留） |
| `invalid_*` | 🟡 看一眼 | 常暗示「某处类型变了」（原可空、现不可空） |
| 其它 `warning` / `info`（lint） | ⚪ 不阻塞 | 噪音，可作基线（与项目既定判据一致） |

## ⚠️ 已知边界（如实标注，别把本检查当「构建通过」）

- **只覆盖 `app/lib`**（87 文件）。`flutter build` 还包含
  **资源与平台配置**（`assets`、Gradle、`Info.plist`、字体声明…）——
  **那部分本检查看不到，仍须由构建确认**。
- 版本号 / 签名 / 依赖解析等 Gradle 侧问题，同样不在覆盖范围。
- 本检查**不是** `flutter analyze` 的替代品（后者还跑 lint 规则）；
  它是「**我这边唯一能达到的语义检查强度**」。

## 首次运行结果（2026-09-28）

- 分析 87 个文件 · **error = 0**
- warning 13 条：`unused_import` 8 · `unused_element` 3 · `unused_field` 1 · `invalid_null_aware_operator` 1
  - 🔑 其中 **3 条是本轮改动引入的**（`word_card` ×2 · `home_screen` ×1，抽组件后的孤立 import）→ **已清理**
  - 其余 12 条为**历史遗留**（`chat_*` / `review_card_widget` / `review_dialog` /
    `achievement_*` / `graph_widget` / `plan_provider` —— 多为 K12 遗留待整体清退）
- 单次耗时约 **36 秒**
