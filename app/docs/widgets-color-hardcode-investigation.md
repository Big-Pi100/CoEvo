# widgets/ 目录硬编码色彩调查报告

> 调查日期: 2026-06-06 | 迁移完成: 2026-06-06 22:45 | 终验: 2026-06-06 23:32 | 状态: ✅ 全部完成 + 终验零残余

## 执行总结

2026-06-06 22:45 完成所有迁移和修复，按计划顺序推进：

| 阶段 | 内容 | 处数 | 状态 |
|------|------|:---:|:---:|
| 🔴 P1 #3 残余 | card_list(3) + review(1) 调用方遗漏 | 4 | ✅ |
| 🔵 策略1 直接迁移 | empty_state(3) + markdown(4) + achievement(4) + graph(18) | 29 | ✅ |
| 🟡 策略2 注入+品牌色 | _GeometryPainter(16) + fl_chart(3) | 19 | ✅ |
| 🟢 策略2C 保留 | 饼图色板 | 1 | ✅ 保留 |
| ⬜ 策略3 保留 | 成就等级色 + 撒花粒子 + markdown sentinel | 28 | ✅ 保留 |
| 🔴 Bug 修复 | _spawnConfetti() 改用 tierColor(tier) | 1 | ✅ |
| **合计** | | **43 迁移 / 29 保留** | |

## 范围确认

`widgets/` 目录共 5 个文件，4 个有 `Colors.` 引用（`skeleton.dart` 零引用 ✅）

| 文件 | Colors. 引用 | const Color(0x...) | 合计 |
|------|:-----------:|:-----------------:|:----:|
| `graph_widget.dart` | 22 | 14 | **36** |
| `achievement_overlay.dart` | 4 | 12（含 _confettiColors） | **16** |
| `markdown_span_nodes.dart` | 12 | 0 | **12** |
| `empty_state.dart` | 3 | 0 | **3** |

**总计 67 处硬编码色彩。**

---

## 逐文件分析

### 1. `empty_state.dart` (3 处) — 🔵 低难度

```dart
// line 28 — 图标色
Icon(icon, size: 56, color: Colors.grey.shade300)
// line 31 — 标题色
Text(title, style: TextStyle(color: Colors.grey.shade600))
// line 35 — 副标题色
Text(subtitle!, style: TextStyle(color: Colors.grey.shade400, fontSize: 13))
```

StatelessWidget，`build` 中有 `context`，可直接替换为 `Theme.of(context).colorScheme.*`。

---

### 2. `markdown_span_nodes.dart` (12 处) — 🟡 中难度

**A 类 — 错误兜底 UI (4 处):**
```dart
// _renderFallback() — 与 graph_widget._buildError() 重复
Colors.orange.shade50   → colorScheme.errorContainer
Colors.orange.shade200  → colorScheme.error.withAlpha(51)
Colors.orange.shade700  → colorScheme.error
Colors.orange.shade800  → colorScheme.onErrorContainer
```

**B 类 — 默认参数 + 颜色逻辑判断 (8 处，不宜迁移):**
```dart
const DisplayMathBlock(this.formula, {this.textColor = Colors.black87, ...});
// line 74 — 功能性颜色等值比较
if (color == Colors.black87 || color == Colors.black || color == Colors.white) return formula;
// line 93
RichContentBuilder({..., this.textColor = Colors.black87});
```

`Colors.black87` 是默认参数值，无 context。`_addColorCmd()` 中 `== Colors.black87` 是功能逻辑判断（是否为默认色以跳过颜色注入），非视觉展示。

---

### 3. `achievement_overlay.dart` (16 处) — 🟡 中难度

**A 类 — 背景/阴影/排版色 (4 处):**
```dart
Colors.black.withValues(alpha: 0.35)  // overlay 遮罩
Colors.white                            // 卡片背景
Colors.black.withValues(alpha: 0.15)  // 卡片阴影
Colors.grey.shade600                   // 文本色
```
TickerProviderStateMixin 有 context，可迁移。

**B 类 — 成就等级色 + 撒花粒子色 (12 处，不宜迁移到 ColorScheme，但内部有 Bug):**

`_spawnConfetti()` 中的 `tierBase` switch（lines 189-202）：
```dart
switch (tier) {
  case 'gold':      tierBase = const Color(0xFFFFD700); break;
  case 'platinum':  tierBase = const Color(0xFFC0C0C0); break;  // 🔴 Bug!
  case 'diamond':   tierBase = const Color(0xFF00BCD4); break;  // 🟡 不一致
  default:          tierBase = const Color(0xFFCD7F32);         // bronze fallback
}
```

**🔴 发现：三处定义不一致 + silver 缺失**

`achievement_icons.dart::tierColor()` 是规范化定义（被 `_tierGlowColor()` 正确委托调用），`_spawnConfetti()` 却维护了独立 switch，导致：

| Tier | `tierColor()` (canonical) | `_spawnConfetti()` | 问题 |
|------|---|------|------|
| bronze | `0xFFCD7F32` | `0xFFCD7F32` (default) | ✅ |
| silver | `0xFFC0C0C0` | ❌ **switch 中缺失**，fallthrough→bronze | Bug |
| gold | `0xFFFFD700` | `0xFFFFD700` | ✅ |
| platinum | `0xFFE5E4E2` (铂金色) | `0xFFC0C0C0` | **用错了 silver 的颜色** |
| diamond | `0xFFB9F2FF` (冰蓝) | `0xFF00BCD4` (cyan) | **颜色不一致** |

**修复建议**：删掉 `_spawnConfetti()` 的独立 switch，统一调用 `tierColor(tier)`（与 `_tierGlowColor()` 一致）。修复后 silver 成就也能正常触发撒花。

// _confettiColors — 撒花粒子色（8 种固定颜色）
static const _confettiColors = [
  Color(0xFFFFD700), Color(0xFFC0C0C0), Color(0xFFCD7F32),
  Color(0xFFFF6B6B), Color(0xFF4ECDC4), Color(0xFF9B59B6),
  Color(0xFFFF8C00), Color(0xFF3498DB),
];
```
金色=传说级，不应因主题切换变绿色。这些颜色承载"成就等级"语义，非"主题强调色"。🚫 策略结论不变（不迁移到 ColorScheme），但内部一致性需修复。

---

### 4. `graph_widget.dart` (36 处) — 🔴 高难度

**A 类 — BoxDecoration 背景/边框 (14 处):**
```dart
// 7 个容器统一外观（图表面板、柱状图、饼图、雷达图、散点图等）
color: Colors.grey.shade50            → colorScheme.surfaceContainerLow
border: Border.all(color: Colors.grey.shade200) → colorScheme.outlineVariant
```
14 处在 `StatelessWidget.build()` 方法中，有 context。

**B 类 — 错误状态 (5 处):**
```dart
// _buildError() — 与 markdown_span_nodes._renderFallback() 重复
Colors.orange.shade50/200/700/800   → colorScheme.error* 家族
```

**C 类 — Canvas CustomPainter + 图表主色 (17 处):**
```dart
// 14 处 — const Color(0xFF6C63FF)，图表品牌紫色
// 用于：折线图描边、柱状图填充、几何图形、箭头颜色

// 3 处 — CustomPainter paint() 中的裸色
Colors.grey.shade400   // 坐标轴线
Colors.grey.shade500   // 虚线
Colors.grey.shade600   // 点/标签
```

CustomPainter `paint()` **无 BuildContext**，无法访问 `Theme.of(context)`。

---

## 三档策略总览

| 策略 | 说明 | 处数 | 文件 |
|------|------|:---:|------|
| **策略 1 — 直接迁移** | StatelessWidget 有 context | 22 | 4 文件 |
| **策略 2 — 需设计决策** | CustomPainter/图表品牌色 | 17 | graph_widget |
| **策略 3 — 不宜迁移** | 品牌语义色/功能逻辑色 | 28 | 3 文件 |

---

---

## 策略 2 深度分析：graph_widget Canvas/CustomPainter + 图表品牌色（17 处）

### 2A — _GeometryPainter 中的硬编码（10 处 const Color(0xFF6C63FF) + 3 处 Colors.grey）

```dart
class _GeometryPainter extends CustomPainter {
  // ... 20+ 几何数据字段，零 ColorScheme 相关字段
  void paint(Canvas canvas, Size size) {
    // line 761: 坐标轴 → Colors.grey.shade400
    // line 771-780: 圆填充/描边/圆心 → const Color(0xFF6C63FF) 占用 3 种 alpha + 纯色
    // line 794-806: 多边形填充/描边/顶点 → const Color(0xFF6C63FF) 占用 2 种 alpha + 纯色
    // line 812: 顶点标签 TP → const Color(0xFF6C63FF)
    // line 847: 直角标记 → const Color(0xFF6C63FF)
    // line 855: 箭头默认色 → const Color(0xFF6C63FF)
    // line 932: 角度弧线 → Colors.orange
    // line 940: 弧线标签 → Colors.orange
    // line 951: 切线虚线 → Colors.grey.shade500
    // line 970-973: 切线端点 + 标签 → Colors.grey.shade600
  }
}
```

**核心问题**：`CustomPainter.paint()` 无 `BuildContext`，无法调用 `Theme.of(context)`。

**但**：`_GeometryPainter` 在 3 处被构造（`_buildPolygon`、`_buildCircle`、`_buildArrowChart`），这 3 个方法**都有 BuildContext 参数**。

**方案 A — 注入 ColorScheme（推荐）：**

```dart
class _GeometryPainter extends CustomPainter {
  final ColorScheme colorScheme;  // 新增
  // ...
  _GeometryPainter({..., required this.colorScheme});
  
  void paint(Canvas canvas, Size size) {
    // 所有 const Color(0xFF6C63FF) → colorScheme.primary
    // Colors.orange → colorScheme.tertiary (或新增语义)
    // Colors.grey.shade400 → colorScheme.outline
    // Colors.grey.shade500 → colorScheme.outlineVariant
    // Colors.grey.shade600 → colorScheme.onSurfaceVariant
  }
}
```

调用方只需加一行：`colorScheme: Theme.of(context).colorScheme`

**一致性检查**：
- `arrow.color ?? const Color(0xFF6C63FF)` → `arrow.color ?? colorScheme.primary`
  - `arrow.color` 来自 LLM 生成的 hex，不应被覆盖 → 逻辑不变
- 坐标轴线 `Colors.grey.shade400` → `colorScheme.outline` — 语义匹配（次要线条）
- 角度弧线 `Colors.orange` → `colorScheme.tertiary` — 语义近似（强调但不喧宾夺主）
- 切线 `grey.shade500/600` → `outlineVariant/onSurfaceVariant` — 语义匹配

**风险**：`shouldRepaint` 目前始终返回 `true`（每次重绘）。如果改为 `old.colorScheme != colorScheme` 判断，主题切换时才会触发重绘，性能更好。

### 2B — fl_chart 中的品牌紫色（4 处 const Color(0xFF6C63FF)）

```dart
// _buildLineChart (line 172)
LineChartBarData(color: const Color(0xFF6C63FF), ...)
// _buildLineChart (line 177) — 渐变填充
belowBarData: BarAreaData(color: const Color(0xFF6C63FF).withAlpha(25))
// _buildBarChart (line 205)
BarChartRodData(color: const Color(0xFF6C63FF), ...)
// _parseColor 默认值 (lines 612, 616)
return const Color(0xFF6C63FF);
```

这 4 处都在 `build()` 方法中（有 context），直接替换为 `colorScheme.primary`。

### 2C — 饼图固定色板（1 处 `List<int>`）

```dart
// _buildPieChart (line 319)
final colors = [0xFF6C63FF, 0xFFFF6B6B, 0xFF4ECDC4, 0xFFFFD93D, 0xFFA78BFA, 0xFFFB923C, 0xFF34D399, 0xFF60A5FA];
```

**不宜迁移**。饼图扇区需要视觉区分度。如果 8 个扇区全用 `colorScheme.primary` 的不同 alpha 变体，扇区间几乎无法分辨。这是**数据可视化色彩设计原则**问题，非纯代码问题。

替代方案：基于 `colorScheme.primary` 生成 harmony palette（如用 HSL 轮转 45°/扇区），但实现复杂度远高于收益。

### 2D — fl_chart 图表排版色（4 处）

```dart
// 散点图标题样式 (line 327)
Colors.white → colorScheme.onPrimary (如果容器背景是 surface)
// 雷达图容器 (line 510 area)
Colors.grey.shade50 / Colors.grey.shade200
// 散点图容器 (line 284 area)
Colors.grey.shade50 / Colors.grey.shade200
```

已在策略 1（BoxDecoration A 类）中覆盖。

### 策略 2 总结

| 子类 | 处数 | 建议 | 难度 |
|------|:---:|------|:---:|
| 2A — CustomPainter 内部 | 13 | 注入 ColorScheme 构造函数 | 🔴 中等 |
| 2B — fl_chart 品牌色 | 4 | 直接换 colorScheme.primary | 🟢 简单 |
| 2C — 饼图色板 | 1 | 保持固定 | — |
| 2D — fl_chart 排版 | 4 | 已归入策略 1 | — |

**策略 2 可迁移 17 处（2A: 13 + 2B: 4）**

---

## 策略 3 深度分析：不应迁移的颜色（28 处）

### 3A — 成就等级语义色（12 处 in achievement_overlay.dart）+ 内部一致性 Bug

#### 语义分析（策略结论不变）

```dart
// 规范化定义 — achievement_icons.dart::tierColor()
const Color(0xFFCD7F32)  // bronze  — 入门级
const Color(0xFFC0C0C0)  // silver  — 稀有级
const Color(0xFFFFD700)  // gold    — 传说级
const Color(0xFFE5E4E2)  // platinum — 史诗级（铂金色调）
const Color(0xFFB9F2FF)  // diamond — 终极限定（冰蓝色调)

// + 8 种撒花粒子色
static const _confettiColors = [
  Color(0xFFFFD700), Color(0xFFC0C0C0), Color(0xFFCD7F32),
  Color(0xFFFF6B6B), Color(0xFF4ECDC4), Color(0xFF9B59B6),
  Color(0xFFFF8C00), Color(0xFF3498DB),
];
```

**不可迁移到 ColorScheme 的核心理由**：

1. **语义绑定**：金色 ≠ "品牌强调色"，金色 = "传说级"。青铜 ≠ "暖色容器"，青铜 = "入门级"。如果用户切换到 Duolingo 主题（绿色系），传说级成就变绿 — 这是**语义失真**，不是视觉一致性。

2. **跨文化共识**：金/银/铜的等级体系在奥运会、游戏、军事勋章中通用。破坏这个映射就是破坏用户直觉。

3. **撒花粒子**：8 种颜色是为了视觉丰富度。全换成 ColorScheme 会变成单色渐变，撒花效果大打折扣。

4. **对比：成就背景/阴影色（策略 1 A 类）应该迁移** — `Colors.black.withAlpha(N)` 和 `Colors.white` 是纯视觉层，不携带语义。

#### 🔴 内部一致性 Bug（与迁移策略无关，但需修复）

`_spawnConfetti()` 自己维护了一套独立 switch，与规范化 `tierColor()` 不一致：

| Tier | `tierColor()` (canonical) | `_spawnConfetti()` switch | 问题 |
|------|---|------|------|
| silver | `0xFFC0C0C0` | ❌ 缺失！fallthrough→bronze | 银成就撒花显示铜色 |
| platinum | `0xFFE5E4E2` | `0xFFC0C0C0` | 铂金撒花显示银色 |
| diamond | `0xFFB9F2FF` | `0xFF00BCD4` | 钻石色调不一致 |

**根因**：`achievement_overlay.dart` 和 `achievement_icons.dart` 各自维护了 tier 颜色定义，后者是规范源但 `_spawnConfetti()` 未引用。而同一文件内的 `_tierGlowColor()` 正确地委托给了 `tierColor()`。

**修复**：`_spawnConfetti()` 改用 `tierColor(tier)`，删掉整个 switch（与 `_tierGlowColor()` 对齐）。

### 3B — markdown 默认参数 + 逻辑判断（8 处）

```dart
// DisplayMathBlock — 默认 textColor
const DisplayMathBlock(this.formula, {this.textColor = Colors.black87, ...});

// RichContentBuilder — 默认 textColor
RichContentBuilder({..., this.textColor = Colors.black87});

// _addColorCmd — 功能性等值判断
if (color == Colors.black87 || color == Colors.black || color == Colors.white)
  return formula; // 默认色/极端色跳过注入

// _addColorCmd — RGB 阈值判断
if (color.r < 60 && color.g < 60 && color.b < 60)
  return formula; // 深色跳过注入
```

**不可迁移的核心理由**：

1. **Sentinel 值模式**：`Colors.black87` 不是"显示用的黑色"，而是"调用方没传自定义颜色的信号"。调用方（屏幕文件）会传入**主题感知的 textColor**：
   ```dart
   // chat_screen.dart 调用:
   DisplayMathBlock(formula, textColor: _cs.onSurface)
   RichContentBuilder(textColor: _cs.onSurface)
   ```
   改默认值不影响实际渲染，但会破坏 sentinel 语义。

2. **功能性逻辑**：`== Colors.black87` 和 `if (color.r < 60 ...)` 是**颜色处理逻辑**，不是 UI 展示。换成 `colorScheme.onSurface == color` 不成立（因为调用方已传入主题色，不会再等于 sentinel）。

3. **flutter_math_fork 已知 Bug**：`textStyle.color` 不传递到所有 TeX 原子，需要 `\textcolor` hack。`_addColorCmd()` 是这个 hack 的守卫逻辑。改动它需要重新验证所有 LaTeX 公式渲染。

**结论**：这 8 处不仅不应迁移，**改了反而可能引入 LaTeX 渲染回归**。

### 3C — 图表函数式颜色引用（标记为策略 2 部分）

`graph_widget.dart::_parseColor()` 的 `const Color(0xFF6C63FF)` 属于策略 2（可迁移），因为它是 fl_chart 品牌色的一部分。已在 2B 中覆盖。

### 策略 3 总结

| 子类 | 处数 | 结论 | 迁移风险 |
|------|:---:|------|:---:|
| 成就等级色 (金/银/铜/铂/钻) | 5 | **不可迁移** | 语义失真 |
| 撒花粒子色 (8 种) | 8 | **不可迁移** | 视觉效果退化 |
| markdown 默认参数 | 8 | **不可迁移** | LaTeX 渲染回归 |
| markdown 等值判断 | — | **不可迁移** | 功能性逻辑破坏 |

**策略 3 全部保留，0 处迁移。**

---

## 修正后总览（终验确认）

| 阶段 | 内容 | 可迁移 | 保留 | 状态 |
|------|------|:---:|:---:|:---:|
| 🔴 P1 #3 残余 | card_list(3) + review(1) | 4 | 0 | ✅ |
| 🔵 策略 1 | empty_state(3) + markdown(4) + achievement(4) + graph(18) | 29 | 0 | ✅ |
| 🟡 策略 2A | _GeometryPainter(13) + parseColor 默认(3) | 16 | 0 | ✅ |
| 🟡 策略 2B | fl_chart 品牌色(3) | 3 | 0 | ✅ |
| 🟢 策略 2C | 饼图色板 | 0 | 1 | ✅ 保留 |
| 🔴 Bug 修复 | _spawnConfetti() → tierColor(tier) | 1 (修复) | 0 | ✅ |
| ⬜ 策略 3 | 撒花粒子 8 色 | 0 | 8 | ✅ 保留 |
| ⬜ 策略 3 | markdown sentinel (Colors.black87 ×3) | 0 | 3 | ✅ 保留 |
| **合计** | | **43 迁移 + 1 修复** | **12 保留** | |

> 注：`achievement_icons.dart` 在 `shared/` 目录，不在本次 widgets/ 范围内，其 35 处 `0xFF` 全部为成就语义色（策略 3），无需改动。

---

## 补充发现：调用方遗漏（P1 #3 残余 — 4 处，立即修复）

进一步分析 `markdown_span_nodes.dart` 中 `Colors.black87` 默认参数的调用方，发现 **4 处 P1 #3 颜色迁移的漏网之鱼**：

| # | 文件 | 行号 | 调用代码 | 问题 |
|---|------|:---:|------|------|
| 1 | `card_list_screen.dart` | 586 | `RichContentBuilder().build(card.front)` | 未传 `textColor`，依赖默认 `Colors.black87` |
| 2 | `card_list_screen.dart` | 590 | `RichContentBuilder().build(card.back)` | 同上 |
| 3 | `card_list_screen.dart` | 595 | `RichContentBuilder().build(card.sourceSentence!)` | 同上 |
| 4 | `review_screen.dart` | 900 | `RichContentBuilder(textColor: const Color(0xFF1A1A2E)).build(card.back)` | 传了硬编码旧 CoEvo 背景色 |

### 调用方全景（6 处，含已验证合规的）

```
card_list_screen.dart ─┬─ 586  RichContentBuilder().build(front)           ❌ 漏传
                       ├─ 590  RichContentBuilder().build(back)            ❌ 漏传
                       └─ 595  RichContentBuilder().build(sourceSentence)  ❌ 漏传

guardian_screen.dart   ─ 729  RichContentBuilder(textColor: _cs.onSurface) ✅

chat_message_bubble.dart─ 28  RichContentBuilder(textColor: baseColor)     ✅
                              (baseColor = _cs.onPrimary / _cs.onSecondaryContainer)

review_screen.dart     ─ 900  RichContentBuilder(textColor: 0xFF1A1A2E)    ❌ 硬编码
```

### 根因分析

**`card_list_screen.dart` (lines 581–595)**：
```dart
DefaultTextStyle(
  style: TextStyle(color: _cs.onPrimary),  // 外层有 DefaultTextStyle
  child: Column(children: [
    RichContentBuilder().build(card.front),  // ← 没传 textColor
    ...
  ]),
)
```
虽然外层有 `DefaultTextStyle(color: _cs.onPrimary)`，但 `RichContentBuilder.build()` 内部**显式创建**了 `TextStyle(color: textColor, ...)`（line 97），会**覆盖**继承的 `DefaultTextStyle`。实际渲染色 = `Colors.black87`，而非 `_cs.onPrimary`。

**`review_screen.dart` (line 900)**：`const Color(0xFF1A1A2E)` 是旧 CoEvo 深蓝主题背景色，P1 #3 迁移 review_screen 时遗漏。

### 修复方案

| 调用点 | 改为 |
|--------|------|
| `card_list_screen.dart` ×3 | `.build(...)` → `(textColor: _cs.onPrimary).build(...)` |
| `review_screen.dart` ×1 | `const Color(0xFF1A1A2E)` → `_cs.onSurface` |

**不改 `markdown_span_nodes.dart` 内部**的默认参数和等值判断（策略 3 分析仍有效）。

---

## 跨文件重复代码

`graph_widget.dart::_buildError()` 和 `markdown_span_nodes.dart::_renderFallback()` 几乎逐字相同的橙色错误卡片。建议抽出公共 `ErrorFallback` widget，放在迁移时一起处理。

---

## 终验（2026-06-06 23:32）

### grep 验证（widgets/ 目录）

| 模式 | 含义 | 匹配数 | 判定 |
|------|------|:---:|:---:|
| `Colors.(grey\|orange\|black\|white).(shade\|withValue)` | 排版/背景/阴影硬编码 | **0** | ✅ |
| `const Color(0xFF6C63FF)` | CoEvo 品牌紫硬编码 | **0** | ✅ |
| `0xFF[0-9A-Fa-f]{6}` | 所有 hex 色彩残留 | **9** | ✅ 全策略3保留 |

### 策略 3 保留清单（9 处，全部合规）

| 文件 | 行 | 内容 | 保留理由 |
|------|:---:|------|------|
| `achievement_overlay.dart` | 107-114 | `_confettiColors` 8 色 | 撒花视觉丰富度，迁移会导致单色退化 |
| `graph_widget.dart` | 320 | 饼图 8 色板 | 数据可视化区分度，`cs.primary` alpha 变体无法分辨扇区 |
| `markdown_span_nodes.dart` | 51,75,94 | `Colors.black87` sentinel ×3 | 功能性 sentinel + `_addColorCmd()` 守卫逻辑，涉及 LaTeX 渲染 |

### 内部一致性验证

| 检查项 | 状态 |
|------|:---:|
| `_spawnConfetti()` 使用 `tierColor(tier)` | ✅ 与 `_tierGlowColor()` 一致 |
| silver tier 不再 fallthrough 到 bronze | ✅ |
| platinum 颜色 = `0xFFE5E4E2`（非 silver 的 `0xFFC0C0C0`） | ✅ |
| diamond 颜色 = `0xFFB9F2FF`（非旧 cyan `0xFF00BCD4`） | ✅ |
| `card_list_screen.dart` ×3 `RichContentBuilder` 传入 `_cs.onPrimary` | ✅ |
| `review_screen.dart` ×1 `RichContentBuilder` 传入 `_cs.onSurface` | ✅ |
| `empty_state.dart` 3 处颜色全部迁移到 ColorScheme | ✅ |
| `markdown_span_nodes._renderFallback()` 4 处全部迁移 | ✅ |
| `achievement_overlay.dart` 4 处 A 类全部迁移 | ✅ |
| `graph_widget.dart` 所有排版/背景色迁移完毕 | ✅ |
| `graph_widget._GeometryPainter` 注入 `ColorScheme cs` | ✅ |
| `graph_widget._parseColor()` 接入 `ColorScheme cs` | ✅ |
| `graph_widget` fl_chart 品牌色迁移到 `cs.primary` | ✅ |

### 结论

**widgets/ 目录硬编码色彩全部清理完毕，零残余。** 保留的 9 处均为语义色/功能色，按策略 3 不迁移。内部 Bug（`_spawnConfetti` tier 颜色不一致）已修复。调用方遗漏（P1 #3 残余 4 处）已修复。
