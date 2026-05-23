# 对话页 Markdown 全渲染 · 可行性方案

> 日期: 2026-05-17
> 目标: 将 LLM 输出的 Markdown 完全渲染，同时兼容现有图形和公式系统

---

## 一、现状

`chat_message_bubble.dart` 当前只渲染三种格式：

| 格式 | 解析方式 | 渲染 |
|------|---------|------|
| 纯文本 | 默认 | `Text` widget |
| LaTeX 公式 | `\\(...\\)` / `\\[...\\]` 正则 | `flutter_math_fork` |
| 图形 | `<graph>...</graph>` 正则 | `GraphWidget` (fl_chart + CustomPainter) |
| **Markdown** | ❌ 未解析 | `** 粗体 **`、`### 标题` 等显示为原始文本 |

---

## 二、候选方案

### 方案 A: `markdown_widget` (v2.3.2+8)

```yaml
markdown_widget: ^2.3.2
```

| 维度 | 评估 |
|------|------|
| 维护状态 | 最后更新 12 个月前，不活跃但稳定 |
| Markdown 支持 | 标题、粗斜体、列表、表格、代码高亮 |
| LaTeX 数学 | 需额外扩展（`latex.dart` 示例），用 `flutter_math_fork` |
| 自定义元素 | `SpanNodeGeneratorWithTag` → 可为 `<graph>` 注册自定义 SpanNode |
| 集成复杂度 | 中 — 需了解 SpanNode 体系 |

### 方案 B: `flutter_markdown` 生态

```yaml
flutter_markdown_plus: ^0.7.7  # 社区 fork，原版已停止维护
flutter_markdown_latex: ^0.1.0 # LaTeX 扩展
```

| 维度 | 评估 |
|------|------|
| 维护状态 | 原版停止维护，fork 活跃度待验证 |
| Markdown 支持 | 完整 GFM（标题、粗斜体、列表、表格、代码高亮）|
| LaTeX 数学 | `flutter_markdown_latex` 扩展内置支持 |
| 自定义元素 | `builders` 参数 + `MarkdownElementBuilder` |
| 集成复杂度 | 中 — 两个额外依赖 |

### 方案 C: 自己写轻量渲染器（不推荐）

| 维度 | 评估 |
|------|------|
| 工作量 | 高（120+ 行解析 → Widget 映射 + 调试）|
| 兼容性 | 完全可控 |
| 维护成本 | 持续修 Bug |
| 结论 | ❌ 除非两个现有库都无法满足需求 |

---

## 三、推荐方案: 方案 A — `markdown_widget`

### 3.1 选型理由

1. **功能完整** — GFM 支持、代码高亮、表格
2. **扩展性强** — `SpanNodeGeneratorWithTag` 直接对标 `<graph>` 需求
3. **LaTeX 示例现成** — 社区已提供 `latex.dart` 扩展模板
4. **Flutter Web 兼容** — 纯 Dart 实现，无原生依赖
5. **体积可控** — 约 200KB

### 3.2 技术架构

```
LLM 回复文本
  │
  ▼
┌─ ChatMessageBubble ────────────────────────────────┐
│                                                     │
│  _buildRichContent(text)                            │
│    │                                                 │
│    ├─ 流式输出中？ → 纯 Text（不变）                    │
│    │                                                 │
│    └─ 完整回复：                                      │
│         │                                            │
│         ├─ Pass 1: 提取 <graph> 块 → 占位符标记        │
│         │    <graph>{"type":"line",...}</graph>       │
│         │    → ⟦GRAPH_0⟧                              │
│         │                                            │
│         ├─ Pass 2: MarkdownWidget(text)               │
│         │    ├─ markdown_widget 内置:                 │
│         │    │   ### 标题, **粗体**, `代码`           │
│         │    │   - 列表, | 表格 |, ``` 代码块 ```     │
│         │    │                                        │
│         │    └─ 自定义 SpanNode (LaTeX):              │
│         │         \\(x^2\\) → flutter_math_fork       │
│         │         \\[E=mc^2\\] → flutter_math_fork    │
│         │                                            │
│         └─ Pass 3: 替换占位符 → GraphWidget           │
│              ⟦GRAPH_0⟧ → GraphWidget(jsonStr)        │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### 3.3 实现要点

**Step 1: 注册 LaTeX SpanNode**

复用社区 `latex.dart` 模板，用 `flutter_math_fork` 渲染，支持 `\(inline\)` 和 `\[display\]`：

```dart
MarkdownGeneratorConfig(
  configs: [
    SpanNodeConfig(
      tag: 'latex',
      generator: (e, config, visitor) => LatexNode(e.attributes['content'] ?? ''),
    ),
  ],
)
```

但 markdown_widget 的 SpanNode 是按 HTML 标签匹配的。LaTeX 是纯文本标记（`\(`），不是 HTML 标签。需要先做一次文本预处理，将 `\(...\)` 转换为 `<latex inline>...</latex>`，`\[...\]` 转换为 `<latex block>...</latex>`。

**Step 2: 注册 Graph SpanNode**

```dart
SpanNodeConfig(
  tag: 'graph',
  generator: (e, config, visitor) => GraphNode(e.textContent),
)
```

与 Step 1 类似，先预处理 `<graph>JSON</graph>` → `<graph>JSON</graph>`（markdown_widget 可识别 HTML 标签），然后在自定义 Builder 中渲染 `GraphWidget`。

**Step 3: 构建渲染管道**

```dart
Widget _buildRichContent(String text, ...) {
  // 流式时跳过
  if (isStreaming) return Text(text, ...);

  // Pass 1: 保护 <graph> 块
  final graphBlocks = <String>[];
  final processed = text.replaceAllMapped(
    RegExp(r'<graph>(.*?)</graph>', dotAll: true),
    (m) {
      graphBlocks.add(m.group(1)!);
      return '<graph index="${graphBlocks.length - 1}"></graph>';
    },
  );

  // Pass 2: LaTeX 预处理 → markdown_widget 兼容格式
  final withLatex = processed
    .replaceAllMapped(RegExp(r'\\\[(.+?)\\\]', dotAll: true),
      (m) => '<latex block>${m.group(1)}</latex>')
    .replaceAllMapped(RegExp(r'\\\((.+?)\\\)'),
      (m) => '<latex inline>${m.group(1)}</latex>');

  // Pass 3: markdown_widget 渲染
  return MarkdownWidget(
    data: withLatex,
    config: MarkdownGeneratorConfig(
      configs: [
        SpanNodeConfig(tag: 'latex', ...),
        SpanNodeConfig(tag: 'graph', ...),
      ],
    ),
  );
}
```

### 3.4 图形渲染集成

`GraphSpanNode` 实现：

```dart
class GraphSpanNode extends SpanNode {
  final int index;
  final List<String> graphBlocks;
  
  @override
  InlineSpan build() {
    return WidgetSpan(
      child: GraphWidget(jsonStr: graphBlocks[index]),
    );
  }
}
```

---

## 四、风险与对策

| 风险 | 等级 | 对策 |
|------|------|------|
| markdown_widget 停止维护 | 🟡 | 代码量小（~2K 行），fork 维护可行 |
| LaTeX 与 Markdown 标记冲突 | 🟡 | 预处理阶段 LaTeX 优先，再喂给 markdown |
| `<graph>` 被 markdown 误解析 | 🟡 | Pass 1 先提取占位，渲染后再替换 |
| 长消息滚动性能 | 🟢 | Widget build 缓存 + ListView 虚拟化（现有） |
| 流式输出时 Markdown 半截 | 🟢 | 流式时不走 Markdown 渲染（现有逻辑不变） |

---

## 五、依赖变更

```diff
  # pubspec.yaml
  dependencies:
+   markdown_widget: ^2.3.2
    flutter_math_fork: ^0.7.0  # 保留
    fl_chart: ^0.70.0           # 保留
```

- 新增依赖：`markdown_widget` ~200KB
- 不删除现有依赖

---

## 六、预估工作量

| 任务 | 时间 |
|------|------|
| 添加依赖 + 基础集成 | 30 min |
| LaTeX SpanNode 实现 | 1 h |
| Graph SpanNode 实现 | 1 h |
| Markdown → LaTeX 预处理管线 | 1 h |
| 样式调优（标题/代码/表格配色） | 1 h |
| 回归测试（图形 + 公式 + 纯文本） | 1 h |
| **合计** | **~5.5 h** |

---

## 七、结论

**推荐方案 A（markdown_widget）**。可行性高，侵入性小，不影响现有图形和公式渲染。关键风险可控。
