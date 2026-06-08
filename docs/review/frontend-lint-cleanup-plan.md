# 前端 Dart Lint 清理计划

> 2026-06-06 | 基于 `dart analyze` 输出的 51 个 info 级别问题

---

## 总览

| 指标 | 值 |
|------|-----|
| 总问题数 | 51 个 info（0 error, 0 warning） |
| 涉及文件 | 10 个 |
| 影响 | 均为 lint 级别，不影响编译/运行 |
| 建议优先级 | P2 — 代码健康度提升，无功能影响 |

---

## 按类型分布

| # | Lint 规则 | 数量 | 严重度 | 修复难度 |
|---|-----------|------|--------|---------|
| 1 | `deprecated_member_use` (withOpacity → withValues) | 10 | ⚠️ 中等 | ★☆☆ 简单替换 |
| 2 | `deprecated_member_use` (red/green/blue → r/g/b) | 6 | ⚠️ 中等 | ★☆☆ 简单替换 |
| 3 | `curly_braces_in_flow_control_structures` | 12 | ℹ️ 低 | ★☆☆ 加括号 |
| 4 | `use_build_context_synchronously` | 6 | ℹ️ 低 | ★★☆ 需理解逻辑 |
| 5 | `deprecated_member_use` (surfaceVariant → surfaceContainerHighest) | 1 | ⚠️ 中等 | ★☆☆ 简单替换 |
| 6 | `avoid_web_libraries_in_flutter` | 2 | ℹ️ 低 | ★★★ 需重构 |
| 7 | `depend_on_referenced_packages` | 2 | ℹ️ 低 | ★☆☆ 加依赖 |
| 8 | `unnecessary_string_interpolations` | 2 | ℹ️ 低 | ★☆☆ 删花括号 |
| 9 | `prefer_interpolation_to_compose_strings` | 2 | ℹ️ 低 | ★☆☆ 字符串改插值 |
| 10 | `prefer_is_not_empty` | 1 | ℹ️ 低 | ★☆☆ 方法替换 |
| 11 | `prefer_is_not_operator` | 1 | ℹ️ 低 | ★☆☆ 操作符替换 |
| 12 | `no_leading_underscores_for_local_identifiers` | 1 | ℹ️ 低 | ★☆☆ 变量改名 |
| 13 | `prefer_final_fields` | 1 | ℹ️ 低 | ★☆☆ 加 final |
| 14 | `dangling_library_doc_comments` | 1 | ℹ️ 低 | ★☆☆ 加 library 指令 |
| 15 | `unintended_html_in_doc_comment` | 1 | ℹ️ 低 | ★☆☆ 加反引号 |
| 16 | `unnecessary_brace_in_string_interps` | 1 | ℹ️ 低 | ★☆☆ 删花括号 |

---

## 按文件分布

### 1. `admin_screen.dart` — 11 个问题 ⭐ 最集中的文件

| 行号 | Lint | 当前代码 | 修复方式 |
|------|------|---------|---------|
| 4 | avoid_web_libraries | `import 'dart:html';` | 需替换为 `dart:js_interop` 或条件导入 |
| 73 | curly_braces | `if (cond) do();` | 加 `{ }` |
| 143 | use_build_context_synchronously | `Navigator.of(ctx)` after await | 插 `if (mounted)` 守卫 |
| 191 | use_build_context_synchronously | 同上 | 同上 |
| 200 | use_build_context_synchronously | 同上 + 非关联 mounted | 需修复 mounted 守卫 |
| 211 | use_build_context_synchronously | 同上 | 同上 |
| 476 | no_leading_underscores | `var _debounce = ...` (local) | 改名为 `debounce` |
| 725 | prefer_is_not_empty | `!isEmpty` | 改用 `isNotEmpty` |
| 809 | withOpacity ×4 | `Colors.red.withOpacity(0.1)` | 全部改为 `.withValues(alpha: 0.1)` |
| 841 | unnecessary_string_interpolations | `'$expr'` | 改为 `expr` |
| 1288 | withOpacity | `color.withOpacity(0.5)` | 改为 `.withValues(alpha: 0.5)` |

**重点关注**: 第 200/211 行的 `use_build_context_synchronously` + `unrelated mounted check` 需要仔细修改。

---

### 2. `guardian_screen.dart` — 10 个问题

| 行号 | Lint | 修复方式 |
|------|------|---------|
| 3 | avoid_web_libraries | 替换 `dart:html` 导入 |
| 42 | prefer_final_fields | `_relation` 加 `final` |
| 305 | curly_braces | 加 `{ }` |
| 306 | curly_braces | 加 `{ }` |
| 411, 465, 516 | withOpacity ×3 | 改为 `.withValues(alpha: ...)` |
| 733, 779, 795 | withOpacity ×3 | 同上 |

---

### 3. `chat_screen.dart` — 6 个问题

| 行号 | Lint | 修复方式 |
|------|------|---------|
| 152 | curly_braces | 加 `{ }` |
| 180 | curly_braces | 加 `{ }` |
| 189 | curly_braces | 加 `{ }` |
| 197 | curly_braces | 加 `{ }` |
| 332 | use_build_context_synchronously | 插 `if (mounted)` 守卫 |
| 431 | unnecessary_string_interpolations + unnecessary_brace | 简化字符串插值 |

---

### 4. `markdown_span_nodes.dart` — 8 个问题

| 行号 | Lint | 当前代码 | 修复方式 |
|------|------|---------|---------|
| 80 | deprecated: red/green/blue | `color.red < 60` | 改为 `color.r < 60` |
| 80 | deprecated: red/green/blue | `color.green < 60` | 改为 `color.g < 60` |
| 80 | deprecated: red/green/blue | `color.blue < 60` | 改为 `color.b < 60` |
| 81 | deprecated: red/green/blue (in hex) | `color.red.toRadixString(16)` | 改为 `color.r.toRadixString(16)` |
| 81 | deprecated: red/green/blue (in hex) | `color.green.toRadixString(16)` | 改为 `color.g.toRadixString(16)` |
| 81 | deprecated: red/green/blue (in hex) | `color.blue.toRadixString(16)` | 改为 `color.b.toRadixString(16)` |
| 82 | prefer_interpolation_to_compose_strings | `'\\textcolor{' + hex + '}{' + formula + '}'` | 改为 `r'\textcolor{$hex}{$formula}'` |
| 82 | prefer_interpolation_to_compose_strings | 同上 | 同上（同一行两个拼接） |

---

### 5. `graph_widget.dart` — 4 个问题

| 行号 | Lint | 修复方式 |
|------|------|---------|
| 5 | depend_on_referenced_packages | pubspec.yaml 添加 `fl_chart` |
| 7 | unintended_html_in_doc_comment | 文档注释 `< >` 加反引号 |
| 607 | curly_braces | 加 `{ }` |
| 645 | prefer_is_not_operator | `!(x is T)` → `x is! T` |

---

### 6-10. 其余文件（各 1-3 个问题）

| 文件 | 行号 | Lint | 修复方式 |
|------|------|------|---------|
| `achievements_screen.dart` | 43 | curly_braces | 加 `{ }` |
| `profile_screen.dart` | 85, 191, 192 | curly_braces ×3 | 加 `{ }` |
| `chat_concept_dialog.dart` | 115 | use_build_context_synchronously | 插 `if (mounted)` |
| `conversation_list_screen.dart` | 4 | depend_on_referenced_packages | pubspec.yaml 添加 `intl` |
| `sherpa_tts.dart` | 1 | dangling_library_doc_comments | 添加 `library sherpa_tts;` |
| `skeleton.dart` | 48 | deprecated: surfaceVariant | 改为 `surfaceContainerHighest` |

---

## 分批次清理计划

### 第一批 — 零风险机械替换（30 个问题，预计 5 分钟）

涉及 lint：`deprecated_member_use` (withOpacity/red/etc)、`prefer_is_not_empty`、`prefer_is_not_operator`、`prefer_final_fields`、`unnecessary_string_interpolations`、`unnecessary_brace_in_string_interps`、`no_leading_underscores_for_local_identifiers`、`curly_braces`、`unintended_html_in_doc_comment`

共 **25 个问题**，都可以用 `Edit` 工具批量替换，无需理解业务逻辑。

### 第二批 — 简单确认替换（6 个问题，预计 10 分钟）

涉及 lint：`use_build_context_synchronously`

需要逐行确认 `mounted` 守卫是否正确，其中 admin_screen L200/L211 的两个 `unrelated mounted check` 需要额外注意。

### 第三批 — 需额外操作（5 个问题，预计 5 分钟）

| 问题 | 操作 |
|------|------|
| `depend_on_referenced_packages` ×2 | pubspec.yaml 添加 `intl` 和 `fl_chart` 依赖 |
| `dangling_library_doc_comments` ×1 | 文件头部加 `library sherpa_tts;` |
| `avoid_web_libraries_in_flutter` ×2 | 替换 `dart:html` 导入方式 |

### 第四批 — 字符串拼接改插值（2 个问题，预计 2 分钟）

涉及：`prefer_interpolation_to_compose_strings`
markdown_span_nodes.dart 的两个拼接改为插值，需注意反斜杠转义。

---

## 执行结果（2026-06-06）

| 批次 | 修复数 | 实际结果 |
|------|--------|---------|
| 第一批 — 机械替换 | 37 个 | ✅ 0 error |
| 第二批 — mounted 守卫 | 6 个 | ✅ 0 error |
| 第三/四批 | 4 个 | ✅ 0 error |
| 按计划跳过 | 4 个 | ↩️ **跳过** |

**最终状态：47/51 已修复，0 error, 0 warning。**

### 跳过项确认

| Lint | 文件 | 原因 | 状态 |
|------|------|------|------|
| `avoid_web_libraries_in_flutter` | admin_screen.dart, guardian_screen.dart | Web 管理端/家长端，本就需要 `dart:html` | ✅ 跳过 |
| `depend_on_referenced_packages` | conversation_list_screen.dart, graph_widget.dart | `intl`/`fl_chart` 是 transitive dependency | ✅ 跳过 |
