# CoEvo 前端 UI 优化清单

> 审计日期: 2026-06-06 | 状态: ✅ 全部完成 (2026-06-06)

---

## 1. 成就页日历 — 自适应宽度 (P0) ✅ 已完成

**完成日期:** 2026-06-06 | **方案:** 重写为 GitHub 贡献图风格 (LayoutBuilder + 7列对齐 + 53 周横向滚动)

**影响范围:** `achievements_screen.dart` `_buildHeatmap()` 方法

---

## 2. 家长端/管理端脱离主题 (P0) ✅ 已完成

**完成日期:** 2026-06-06 | **方案:** 删除自定义颜色变量，全部替换为 `Theme.of(context).colorScheme.*`

**影响范围:** `guardian_screen.dart` (~400 行), `admin_screen.dart` (~700 行)

---

## 3. 全项目硬编码颜色 (~80 处) (P1) ✅ 已完成

**完成日期:** 2026-06-06 | **方案:** 14/14 屏幕文件全部迁移，每个文件添加 `_cs` getter，`Colors.xxx` → `_cs.xxx`


---

## 4. 排版硬编码 (P1) ✅ 已完成

**完成日期:** 2026-06-06 | **方案:** 72 处 fontSize 精确匹配迁移至 textTheme (11→labelSmall, 12→bodySmall, 14→bodyMedium, 16→bodyLarge, 18→titleLarge)，31 处复杂 fontWeight+fontSize 组合保留

**影响范围:** 所有屏幕文件

---

## 5. 间距常量未使用 (P2) ✅ 已完成

**现状:** `AppTheme` 定义了 `spacingXs(4) / Sm(8) / Md(12) / Lg(16) / Xl(20) / Xxl(24) / Xxxl(32) / Xxxxl(48)`，
但全项目用裸数字 `8`, `16`, `20` 等。统一间距有助于视觉一致性。

**完成情况:** 304 处替换，16/16 屏幕文件全部迁移，含 import 自动添加。Python 脚本：`tools/migrate_spacing.py`
**完成日期:** 2026-06-06

---

## 6. 缺失错误/空状态 (P2) ✅ 已完成

**完成日期:** 2026-06-06

**修复详情:**

| 屏幕 | 修复内容 |
|------|---------|
| **ProfileScreen** | 添加 `_error` 状态 + `_buildErrorView()` (cloud_off 图标 + 重试按钮)；`_editName()` → `updateDisplayName()` 加 try/catch + SnackBar 重试；`_updateProfile()` 空 catch → SnackBar 提示 |
| **ReviewScreen** | 添加 `_loadError` 状态 + 加载失败 UI（"加载失败" + 重试按钮），区分"网络错误"与"今日复习完成"；`_replenishQueue()` catch 加 debugPrint |
| **AchievementsScreen** | 修复 `getAchievementsAll()` bug（独立 try/catch，不再拖垮主数据）；添加 `_error` 状态 + `_buildEmptyOrErrorState()`（错误→重试，空→"暂无成就数据"提示） |
| **HomeScreen** | 低优先级 — 无异步数据加载，仅 `_startSubject` 已有 SnackBar 处理 |

---

## 7. 文档/注释类小问题 (P3) ✅ 已完成

**完成日期:** 2026-06-06

| 问题 | 状态 | 说明 |
|------|------|------|
| 超时注释"1.5s"代码是 `Duration(milliseconds: 5000)` | ✅ 已不存在 | chat_screen 从 1453→839 行重构后相关代码已移除 |
| `/k12-subject` 路由未在 GoRouter 注册 | ✅ 已修复 | 添加 `import` + `GoRoute(path: '/k12-subject')` 到 `app.dart` |
| `chat_input.dart` 颜色硬编码 `Colors.white` | ✅ P1 #3 已修复 | 零 Colors. 引用残留 |

---

## 完成总览

| 批次 | 内容 | 状态 |
|------|------|------|
| P0 | #1 日历自适应 + #2 家长/管理端主题迁移 | ✅ |
| P1 | #3 硬编码颜色替换 + #4 排版规范化 | ✅ |
| P2 | #5 间距常量 + #6 错误/空状态 | ✅ |
| P3 | #7 文档/注释类小问题 | ✅ |

**7/7 项全部完成，全项目 `flutter analyze` 0 error。**
