# Flutter 静态分析报告

**日期**: 2026-06-08  
**工具**: `flutter analyze`  
**当前状态**: 0 errors, 7 warnings (全在第三方包), 0 app warnings  

> ⚠️ **构建移动端 APP 前置检查**：以下记录的两类问题在未来构建 Android/iOS 版本时**必须解决**，当前在 Web 部署下可暂缓。

---

## ✅ 已修复（2026-06-08）

### 9 个 Warnings 全部清除

| 问题类型 | 文件 | 修复方式 |
|:--|:--|:--|
| `unused_element` (`_tt`) | auth_screen, chat_input, chat_screen, k12_subject_screen, achievement_overlay | 删除 5 处未使用的 getter |
| `unused_local_variable` (`textTheme`) | chat_plan_panel.dart:47 | 删除未使用的局部变量 |
| `unnecessary_cast` (`as List<dynamic>`) | markdown_span_nodes.dart:179/185/191 | 去掉多余的 `as` 转换 |

---

## 🔴 构建移动端 APP 前必须解决

### 1. `avoid_web_libraries_in_flutter` — dart:html 依赖

**位置**: `lib/screens/admin_screen.dart:4`, `lib/screens/guardian_screen.dart:3`

两个文件导入了 `dart:html`，这是 **Web 专属库**，编译到 Android/iOS 会直接**报错无法构建**。

#### 当前用途

| 文件 | 函数 | 用途 | dart:html 代码 |
|:--|:--|:--|:--|
| `admin_screen.dart` | 文件导出 | 下载 CSV/JSON 到用户本地 | `html.AnchorElement(href: url)..click()` |
| `guardian_screen.dart` | 路由检测 | 判断当前路径是否为 `/teacher` | `html.window.location.pathname` |
| `guardian_screen.dart` | 持久化 | token 存取 | `html.window.localStorage[...]` |

#### 迁移方案（移动端替换）

| 当前代码 | 移动端替代方案 |
|:--|:--|
| `html.AnchorElement(href: url)..click()` | `dart:io` + `path_provider` 写文件 + 系统分享（或 `package:share_plus`） |
| `html.window.location.pathname` | `GoRouter` 的 `GoRouterState.of(context).uri.path` 或路由参数传递 |
| `html.window.localStorage` | `package:flutter_secure_storage`（推荐）或 `package:shared_preferences` |

#### 推荐做法：条件导入 + 平台适配层

创建统一的平台适配层，避免 `dart:html` 散落在各文件中：

```
lib/
  services/
    platform/
      platform_service.dart          # 抽象接口
      platform_service_web.dart      # dart:html 实现（仅 Web）
      platform_service_mobile.dart   # 移动端实现
```

`pubspec.yaml` 中通过 `flutter:` 的平台配置做条件导出。

---

### 2. `depend_on_referenced_packages` — fl_chart 依赖位置错误

**位置**: `lib/widgets/graph_widget.dart:5`, `pubspec.yaml:37`

#### 问题

`fl_chart` 被错误地放在了 `pubspec.yaml` 的 `dev_dependencies:` 下，但 `graph_widget.dart` 是生产代码（`lib/` 目录）。虽然 `flutter analyze` 只报 info，但构建 release 版本时 `fl_chart` 不会被包含在产物中。

#### 修复

将 `fl_chart` 从 `dev_dependencies` 移至 `dependencies`：

```yaml
# 当前（错误）
dev_dependencies:
  fl_chart: ^0.70.0

# 改为
dependencies:
  fl_chart: ^0.70.0
```

---

## INFO 级别（不影响构建，可顺便修复）

### 3. `curly_braces_in_flow_control_structures`（3处）

`lib/screens/review_screen.dart:192/201/209` — if 语句缺大括号，风格问题。

### 4. `no_leading_underscores_for_local_identifiers`（3处）

`empty_state.dart`, `graph_widget.dart`, `markdown_span_nodes.dart` — 局部变量以 `_cs`/`_tt` 命名，建议改为普通命名或用 `_` 显式忽略。

---

## 其余问题（无需处理）

| 来源 | 数量 | 原因 |
|:--|:--:|:--|
| flutter_math_fork 第三方包 | 7 warnings + ~440 infos | 第三方包，不应修改 |
| Test 文件 | 1 warning + ~29 infos | 测试代码有 `print`、转义字符属正常 |

---

## 移动端构建检查清单

移到 `pubspec.yaml` 的 `dependencies:` 下  
- [ ] `fl_chart` — 从 `dev_dependencies` 移出

用平台适配层替换  
- [ ] `admin_screen.dart` 的 `dart:html` 文件下载  
- [ ] `guardian_screen.dart` 的 `dart:html` token 存储  
- [ ] `guardian_screen.dart` 的 `dart:html` 路径检测  

可顺便修复  
- [ ] `review_screen.dart` 3 处 if 语句加大括号  
- [ ] 4 处局部变量 `_cs`/`_tt` 去掉下划线前缀
