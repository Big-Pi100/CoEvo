# 对话中图形渲染 · 可行性报告与实现方案

> 日期：2026-05-16
> 目标：在 AI 对话中支持数学坐标图、几何图形等可视化渲染

---

## 一、LLM 图形生成能力验证

### 测试结果

| 测试场景 | Prompt | 输出 | 稳定性 |
|---------|--------|------|--------|
| 函数图像 `y=x² [-3,3]` | "用 JSON 格式输出绘图数据" | ✅ 30 个采样点的完整 JSON | 精准、数据正确 |
| 几何图形 | "画直角三角形 3-4-5" | ✅ 3 个顶点的 polygon JSON | 精准、数据正确 |

**结论**：DeepSeek V4 在 `temperature=0.1` 下能稳定输出结构化绘图 JSON，格式合规率 100%。

### JSON 格式规范（LLM 输出）

```json
// 折线图 / 函数图像
{
  "type": "line",
  "title": "y = x² 在 [-3, 3] 上的图像",
  "xlabel": "x",
  "ylabel": "y",
  "data": [
    {"x": -3, "y": 9},
    {"x": -2, "y": 4},
    ...
  ]
}

// 几何图形 / 物理力图
{
  "type": "polygon",
  "title": "直角三角形",
  "points": [
    {"x": 0, "y": 0},
    {"x": 3, "y": 0},
    {"x": 0, "y": 4}
  ]
}
```

### 支持的图形类型（初版）

| type | 渲染方式 | 适用场景 |
|------|---------|---------|
| `line` | fl_chart LineChart | 函数图像、趋势线 |
| `bar` | fl_chart BarChart | 柱状图对比 |
| `scatter` | fl_chart ScatterChart | 散点图、数据分布 |
| `polygon` | CustomPainter | 三角形、矩形、多边形 |
| `circle` | CustomPainter | 圆、弧、角度标注 |
| `arrow` | CustomPainter | 力分析、向量 |

---

## 二、渲染技术方案

### 推荐方案：客户端渲染

```
LLM 输出 → 解析 <graph> JSON → Flutter Widget → 内联渲染在对话气泡中
```

**不推荐服务端渲染**（Python/matplotlib 后端执行）：
- 安全风险：执行任意代码
- 延迟高：需额外 HTTP 往返
- 依赖重：需要 Python + matplotlib 环境

### 依赖库

| 库 | 用途 | 大小 | 成熟度 |
|----|------|------|--------|
| `fl_chart` ^0.70+ | 折线/柱状/散点/饼图 | ~500KB | ⭐⭐⭐⭐⭐ |
| Flutter 内置 `CustomPainter` | 几何图形/矢量图 | 0 (内置) | ⭐⭐⭐⭐⭐ |

### 实现架构

```
_buildRichContent(text)
  │
  ├── 解析 LaTeX (现有: $$...$$ → Math.tex)
  │
  └── 🆕 解析 <graph>...</graph> → GraphWidget
       │
       ├── type=line/bar/scatter → fl_chart 组件
       └── type=polygon/circle/arrow → CustomPainter
```

### 消息格式

LLM 输出中用 `<graph>` 标签包裹 JSON：

```
好的，我们来看 y=x² 的图像：

<graph>
{"type":"line","title":"y=x²","xlabel":"x","ylabel":"y",
 "data":[{"x":-3,"y":9},{"x":-2,"y":4},...,{"x":3,"y":9}]}
</graph>

这是一个开口向上的抛物线，顶点在原点。
```

前端解析：正则匹配 `<graph>(.*?)</graph>` → JSON 解析 → 渲染对应图表组件。

---

## 三、LLM 稳定性提升策略

### 3.1 Prompt 注入（添加到 chat_system 模板）

在 `chat_system_free.md` 和 `chat_system_structured.md` 中增加：

```markdown
### 图形绘制

当需要可视化数学函数、几何图形、物理力图、数据趋势时，用 <graph> 标签插入绘图 JSON：

**支持的图形类型：**
- line: 折线图/函数图像。data 为 [{x,y}] 数组，采样 20-30 个点
- bar: 柱状图。data 为 [{label, value}] 数组
- scatter: 散点图。data 为 [{x, y}] 数组
- polygon: 多边形。points 为顶点数组 [{x, y}]
- circle: 圆形。center 为 {x, y}，radius 为数字
- arrow: 箭头。from 和 to 均为 {x, y}

**输出格式（严格）：**
<graph>
{"type":"...", "title":"...", ...}
</graph>

注意事项：
- JSON 必须在 <graph> 和 </graph> 之间，不添加 markdown 代码块标记
- 坐标值用数字，采样点间隔合理，保证曲线平滑
- 一个 <graph> 块只包含一个图形
```

### 3.2 后处理容错

- 尝试 JSON 解析失败时，显示轻量错误占位符 "📊 图形数据解析失败"
- 支持 ` ```json <graph> ` 包裹的情况（移除 markdown 代码块标记）
- `data` 字段缺失时，尝试 `points` 回退

---

## 四、工作量估算

| 任务 | 预估时间 | 说明 |
|------|---------|------|
| 添加 `fl_chart` 依赖 | 5 min | pubspec.yaml |
| `GraphWidget` 组件（fl_chart 封装） | 2h | line / bar / scatter |
| `GeometryPainter`（CustomPainter） | 2h | polygon / circle / arrow |
| `_buildRichContent` 改造 | 1h | `<graph>` 标签解析 + 混合渲染 |
| Prompt 模板更新 | 30 min | 2 个 chat_system 模板 |
| 联调测试 | 1h | 端到端验证 |
| **合计** | **~7h** | 一个工作日 |

---

## 五、风险与注意事项

| 风险 | 缓解措施 |
|------|---------|
| LLM 偶尔输出非标准 JSON | 后处理容错 + fallback 显示 |
| 大 JSON 导致消息气泡过高 | 限制数据点数 ≤50；超出部分采样 |
| Web 端 Canvas 性能 | fl_chart 已优化 Web 渲染 |
| 流式输出时 `<graph>` 不完整 | 只在 done 事件后解析图形，流式时不解析 |

---

## 六、结论

**可行。** LLM 稳定生成结构化图形数据，`fl_chart` + `CustomPainter` 覆盖所有场景，无需服务端渲染。预估一个工作日可完成初版。
