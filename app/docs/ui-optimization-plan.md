# CoEvo 前端 UI 优化清单

> 审计日期: 2026-06-06 | 状态: 待审阅

---

## 1. 成就页日历 — 自适应宽度 (P0)

**现状:** 日历格子用 `Row` 按周分组，每个单元格硬编码 `width: 40, height: 40`。
在窄屏设备上 7×40=280px 会溢出；在宽屏上右侧留大片空白。

**方案:** 用 `LayoutBuilder` 获取可用宽度 → `cellSize = (availableWidth - 6*gap) / 7`，格子宽高动态计算。
同时周表头文字也按 `cellSize` 居中。保留杜绿色热力图着色逻辑。

**影响范围:** `achievements_screen.dart` `_buildHeatmap()` 方法

---

## 2. 家长端/管理端脱离主题 (P0)

**现状:** `guardian_screen.dart` 和 `admin_screen.dart` 定义了自己的颜色变量
(`_surfaceBg`, `_primaryDark` 等)，完全不调用 `Theme.of(context).colorScheme`。
切换到 Duolingo 主题后，这两个页面仍是深蓝风格，与主页视觉割裂。

**方案:**
- 删除文件内自定义颜色变量
- 全部替换为 `Theme.of(context).colorScheme.*` (primary / surface / onSurface / outline 等)
- 字体改用 `theme.textTheme.*`，间距改用 `AppTheme.spacing*` 常量

**影响范围:** `guardian_screen.dart` (~400 行), `admin_screen.dart` (~700 行)

---

## 3. 全项目硬编码颜色 (~80 处) (P1)

**现状:** 分布在 10+ 个文件中，用 `Colors.red`, `Colors.orange.shade700`, `Color(0xFF1A1A2E)` 等裸色值。
主题切换时这些组件颜色不变，看起来像"只换了一半"。

**高密度问题文件:**
| 文件 | 硬编码颜色数 | 典型例子 |
|------|-------------|---------|
| `chat_screen.dart` | ~15 | `Colors.red.shade50`, `Color(0xFF1A1A2E)` |
| `review_screen.dart` | ~10 | `Colors.red.shade400`, `Colors.orange.shade400` 状态色 |
| `achievements_screen.dart` | ~8 | `Colors.green.shade100~700` 热力图梯度 |
| `card_list_screen.dart` | ~6 | `Colors.blue/orange/green/purple` 状态标签 |
| `conversation_list_screen.dart` | ~4 | `Colors.red` 删除背景 |
| `profile_screen.dart` | ~4 | `Colors.orange` 订阅状态 |

**方案（按文件逐个替换）:**

| 硬编码 | 替换为 |
|--------|--------|
| `Colors.red` / `Colors.red.shade*` | `theme.colorScheme.error` |
| `Colors.orange` / `Colors.orange.shade*` | `theme.colorScheme.tertiary` (或新增 `warning` 色) |
| `Colors.green.shade*` (热力图) | 基于 `colorScheme.primary` 的 `withOpacity()` 梯度 |
| `Colors.grey.shade*` | `colorScheme.onSurfaceVariant` / `surfaceVariant` |
| `Colors.indigo` / `Color(0xFF1A1A2E)` | `colorScheme.primary` / `primaryContainer` |
| `Colors.blue` 状态标签 | `colorScheme.secondary` |

**影响范围:** 所有屏幕文件（~14 个）

---

## 4. 排版硬编码 (P1)

**现状:** 大量 `fontSize: 14`, `fontSize: 16`, `fontSize: 13`, `fontWeight: FontWeight.w600` 裸值，
未使用 `theme.textTheme`。切换 Duolingo 字体 (Fredoka One / Nunito Sans) 后效果打折扣，
因为字号和粗细是根据原 CoEvo 主题手调的。

**方案:** 分类替换：
- `fontSize: 18~20 + bold` → `theme.textTheme.titleMedium` / `titleLarge`
- `fontSize: 14~16` (正文) → `theme.textTheme.bodyMedium` / `bodyLarge`
- `fontSize: 11~13` (辅助) → `theme.textTheme.labelSmall` / `bodySmall`
- `fontWeight: FontWeight.w600` → 由 TextTheme style 自带 weight，去掉显式覆盖

**影响范围:** 所有屏幕文件

---

## 5. 间距常量未使用 (P2)

**现状:** `AppTheme` 定义了 `spacingXs(4) / Sm(8) / Md(12) / Lg(16) / Xl(24) / Xxl(32)`，
但全项目用裸数字 `8`, `16`, `20` 等。统一间距有助于视觉一致性。

**方案:** 全局查找替换 `SizedBox(width/height: N)` / `EdgeInsets.all(N)` →
`AppTheme.spacing*`。**但量极大，建议按文件逐批处理**，不在一次改动中全量替换。

---

## 6. 缺失错误/空状态 (P2)

**现状:** 以下几个屏幕在网络/API 失败时没有错误提示：

| 屏幕 | 缺失项 | 方案 |
|------|--------|------|
| **HomeScreen** | API 加载科目失败 | 加 `ErrorWidget` + "重新加载" 按钮 |
| **ProfileScreen** | 网络请求失败 | SnackBar 或内联错误卡片 |
| **ReviewScreen** | 卡片加载失败 | 显示 "暂无待复习卡片" 空状态 |
| **AchievementsScreen** | 数据接口失败 | try/catch 包裹 + 错误占位图 |

---

## 7. 文档/注释类小问题 (P3)

| 问题 | 位置 |
|------|------|
| 超时注释写"1.5s"代码是 `Duration(milliseconds: 5000)` = 5s | `chat_screen.dart:981` |
| `/k12-subject` 路由未在 GoRouter 注册 | `app.dart` |
| `chat_input.dart` CircularProgressIndicator 颜色硬编码 `Colors.white` | `chat_input.dart:62` |

---

## 修复优先级建议

| 批次 | 内容 | 文件数 | 用户感知 |
|------|------|--------|----------|
| **第 1 批** | #1 日历自适应 + #2 家长/管理端主题迁移 | 3 | ⭐⭐⭐ 立即可见 |
| **第 2 批** | #3 硬编码颜色替换 | ~14 | ⭐⭐⭐ 主题切换完整 |
| **第 3 批** | #4 排版规范化 + #6 错误状态 | ~6 | ⭐⭐ 体验打磨 |
| **第 4 批** | #5 间距常量 + #7 杂项 | ~14 | ⭐ 代码质量 |

---

> **下一步:** 请确认从哪一批开始、或调整优先级后，我按文件逐个实施。
