# 图表渲染对比：WorkBuddy vs CoEvo — 2026-06-26（v2 补充）

## 一、架构差异

| 维度 | WorkBuddy（聊天 UI） | CoEvo（Flutter Web） |
|:-----|:-------------------|:--------------------|
| **渲染引擎** | 浏览器原生 DOM + Canvas | Flutter CanvasKit（Web）/ Skia（原生） |
| **Markdown** | 浏览器原生渲染 | `flutter_markdown_plus` Widget |
| **图表** | Chart.js → `<canvas>`（HTML 沙箱） | `fl_chart` → Flutter Canvas |
| **几何图形** | SVG（DOM 元素） | CustomPainter → Canvas |
| **文字** | 浏览器文字渲染引擎 | Canvas 文字渲染 |
| **布局** | CSS Flow Layout | Flutter Flex Layout |

## 二、根本差距：Canvas vs DOM 文字渲染

### 2.1 WorkBuddy 的优势

WorkBuddy 的图表走的是**浏览器原生 Canvas（Chart.js）或 DOM（HTML/SVG）**。文字由浏览器的排版引擎处理：

```
浏览器渲染管道:   DOM/CSS → 布局 → 光栅化 → 屏幕
                      ↑
                  硬件加速, 亚像素抗锯齿, 字体回退
```

- 小字号文字清晰（亚像素渲染）
- 刻度数字自动适配容器宽度
- 文字和图形边界由浏览器精确计算
- 支持 `@media`、`prefers-color-scheme` 等响应式

### 2.2 CoEvo 的瓶颈

CoEvo 的 Flutter Web 在 CanvasKit 模式下，所有文字都是**通过 Skia 画到 Canvas 上**的：

```
Flutter Web 渲染:  Widget → CanvasKit → WebGL Canvas → 屏幕
                       ↑
                 无亚像素, 字体回退受限, DPI 缩放问题
```

Flutter Web 的 Canvas 文字渲染已知问题：
- **小字号模糊**：12px 以下文字锯齿明显（如轴刻度）
- **文字度量不精确**：`TextPainter.layout()` 和实际渲染位置有偏差 → 数字盖图
- **无自动换行折行**：长数字超出预定区域直接溢出或被裁切
- **字体加载延迟**：中文字体在 CanvasKit 下可能 fallback 失败

## 三、具体问题对比

### 3.1 数字位置不准（"数字盖住图"）

| | WorkBuddy (Chart.js) | CoEvo (fl_chart) |
|:--|:--------------------|:-----------------|
| 刻度标签 | 浏览器自动计算占位，`reservedSize` 由 CSS 保证 | Flutter 需硬编码 `reservedSize`，算错就重叠 |
| 长数字 | `autoSkip` + `maxRotation` 自动倾斜/跳过 | 手动 `_niceInterval`，算不好就溢出 |
| 定位 | CSS Box Model 精确控制 | Canvas `drawText` 手动算偏移 |

### 3.2 数字底色难看（"加了底色更难看了"）

CoEvo 的 `_GeometryPainter` 在标签后画半透明白色矩形（line 1077-1086），原因是 Canvas 文字在复杂图形背景上不可读。

WorkBuddy 的 SVG text 不需要这层 hack——浏览器 SVG 渲染器会自动处理文字和背景的对比度。

### 3.3 配色单调

| | WorkBuddy (Chart.js) | CoEvo (fl_chart) |
|:--|:--------------------|:-----------------|
| 柱状图 | 每柱可独立配色 | 全用 `cs.primary` 一个色 |
| 折线图 | 多 dataset 自动调色 | 单线 |
| 饼图 | 自由色板 | 8 色固定 palette |
| 主题 | 传入硬编码 hex | 绑死 Material `cs.primary` |

## 四、CoEvo 可以借鉴的点

### 4.1 tick 格式改进（低投入，高收益）

借鉴 Chart.js 的刻度格式化，不再用 `toStringAsFixed(1)`：

```dart
// 当前
Text(v.toStringAsFixed(1))  // 42.0, 100.0, 3.0

// 借鉴
Text(_formatHuman(v))       // 42, 100, 3
String _formatHuman(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}
```

### 4.2 reservedSize 动态计算

fl_chart 的 `reservedSize` 不够智能，但可以通过预计算最长 label 来动态设置：

```dart
final maxWidth = labels.map((l) => l.length * 8 + 12).reduce(max);
// maxWidth 传给 reservedSize
```

### 4.3 多彩配色方案

fl_chart 本身支持多彩，只是代码没利用。可以内置一个调色板（类似 WorkBuddy 的 9 ramp palette）：

```dart
static const _chartColors = [
  Color(0xFF378ADD), // 蓝
  Color(0xFFD85A30), // 橙红
  Color(0xFF639922), // 绿
  Color(0xFF534AB7), // 紫
  ...  // 8-10 色循环
];
```

### 4.4 去掉 geometry 的标签底色 hack

`_GeometryPainter` 的 `pendingLabels` 半透明背景（line 1077-1086）是 Canvas 文字可读性的妥协方案。优化方向：
- 改用 `ParagraphBuilder` + 背景色着色，而不是画矩形
- 或者在标签位置留空白（使用白色 Path 遮挡背景图形）

### 4.5 字体大小适配

WorkBuddy 规范了最小字号 11px，CoEvo 的几何图文字号固定 11px（line 1072），但 fl_chart 的 tick 字号固定 10px（line 154/163）。统一提到 11px 以上会改善可读性。

## 六、Markdown 渲染管线对比

### 6.1 渲染链路

| 环节 | WorkBuddy | CoEvo |
|:-----|:----------|:------|
| **Markdown 引擎** | 浏览器原生 HTML 渲染 | `flutter_markdown_plus` |
| **数学公式** | 无内置支持（需外部库） | ✅ `flutter_math_fork`（`\(\)` 行内 + `\[\]` 独立） |
| **代码高亮** | 浏览器原生 `<pre><code>` | 仅灰底圆角，**无语法高亮** |
| **表格** | 浏览器 `<table>` | 自制 `_renderMarkdownTable`（Flutter Table） |
| **行内样式** | CSS 完整 | MarkdownStyleSheet 有限子集 |
| **图片** | `<img>` 原生支持 | ❌ **完全不支持** |
| **流式渲染** | 逐 token 增量 DOM | 流式时降级为纯 `Text`（fontSize:15），无 Markdown 无 graph |

### 6.2 补充差距

**1. 代码块无高亮**
`MarkdownStyleSheet` 只设了背景色和圆角，没接入语法高亮库。比起 WorkBuddy 浏览器各级别高亮差一截。

**2. 流式渲染体验割裂**
```dart
// line 98-100
if (isStreaming) {
  return Text(text, style: TextStyle(fontSize: 15, height: 1.5)); // 纯文本
}
```
流式输出时所有 `<graph>`、数学公式、Markdown 格式全部丢失。等消息收完才重新渲染。WorkBuddy 因为是 DOM 流式更新，打字中就能看到格式和图表。

**3. 不支持图片**
`flutter_markdown_plus` 本身支持图片，但 CoEvo 未配置图片加载器。LLM 输出 `![alt](url)` 时会断裂。

## 七、提升方案汇总

### 7.1 graph_widget 优化（P0）

| 问题 | 方案 | 位置 |
|:-----|:-----|:-----|
| 刻度数字带 `.0` | `_formatHuman` 去末位零 | `line 154` |
| 刻度字号 10→12 | 统一提到 12px | `line 154,163` |
| $reservedSize$ 太小 | 按最长标签动态计算 | `line 153,162` |
| 柱状图单色 | 内置 8 色调色板循环 | `line 206` |
| 折线图单线 | 解析 `data.datasets[]` 数组 | `line 95-195` |
| geometry 标签白底 | 改用 stroke outline | `line 1077-1086` |

### 7.2 markdown 体验优化（P1）

| 问题 | 方案 |
|:-----|:-----|
| 代码无高亮 | 引入 `flutter_highlight` 包 |
| 流式降级纯文本 | 流式模式走简化 block 分割，保留 `<graph>` 和数学公式 |
| 无图片支持 | 配置 `flutter_markdown_plus` 的 `imageBuilder` 或屏蔽处理 |

### 7.3 架构边界（不改）

- 不切 `HtmlElementView`（iframe 嵌入 Chart.js）
- 不换 markdown 引擎
- CanvasKit 小字模糊是 Flutter Web 架构限制，只能通过提高字号+动态 reservedSize 缓解

## 八、行优先级

| 优先级 | 项目 | 预计改善 |
|:------:|:-----|:---------|
| **P0** | 刻度格式 + 动态 reservedSize | 消除数字重叠、刻度清晰 |
| **P0** | 多彩配色 + 多 dataset 折线 | 告别单色平庸 |
| **P1** | geometry 标签底色美化 | 去除丑陋白底 |
| **P1** | 流式渲染保留 graph 和数学 | 打字中能看图 |
| **P2** | 代码语法高亮 | 代码块更专业 |
| **P2** | 流式 markdown 渲染 | 流式体验更平滑 |
