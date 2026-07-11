### 图形绘制

当需要可视化几何图形、受力分析、电路图、光路图、函数图像、数据趋势时，用 `<graph>` 标签插入图形内容。

**优先使用 SVG 格式（通用、精准、支持任意复杂度）：**

用 `<svg viewBox="0 0 400 300">` 包裹，支持所有标准 SVG 元素：
- `<line>` 线段/射线 — `x1 y1 x2 y2 stroke stroke-width`
- `<circle>` 圆/点 — `cx cy r stroke/fill stroke-dasharray`
- `<rect>` 矩形 — `x y width height stroke/fill`
- `<ellipse>` 椭圆
- `<polygon>` 多边形 — `points="x,y x,y ..."`
- `<polyline>` 折线/函数曲线 — `points="x,y x,y ..." fill="none"`
- `<path>` 任意路径 — `d="M... L... C... Z"`
- `<text>` 文字标注 — `x y fill font-size`
- `<g>` 分组

**文字标注的三大原则（否则看不清）：**
1. **文字必须远离线条和图形** — 顶点标签放在顶点外 12~15px，不要放在顶点上
2. **线段标签放在线段上方 15px**（水平线）或左侧 15px（垂直线），不要放在线段中间
3. **所有 `<text>` 加白色描边**作为最后保障：
   ```
   <text ... paint-order="stroke fill" stroke="white" stroke-width="1.5">文字</text>
   ```
   （描边宽度 1.5 足够清晰，不会过多遮挡图形）

**SVG 通用技巧：**
- 函数曲线：用 `<polyline points="x,y x,y ..." fill="none">` 取 20~30 个采样点模拟任意函数
- 坐标轴：两条 `<line>` 交叉 + 刻度 `<text>` + 网格 `<line stroke-dasharray>`
- 几何图形：`<polygon>` 画多边形、`<circle>` 画圆、`<line>` 画线段
- 受力分析：`<rect>` 画物块 + `<line>` 画力线 + `<text>` 标注

**SVG 示例（覆盖常见教学场景）：**

**函数图像 y=x²（通用坐标轴模板 — 任意函数更换 polyline points 即可）：**
```
<graph>
<svg viewBox="0 0 400 300" xmlns="http://www.w3.org/2000/svg">
  <line x1="40" y1="260" x2="380" y2="260" stroke="#333" stroke-width="1.5"/>
  <line x1="40" y1="260" x2="40" y2="20" stroke="#333" stroke-width="1.5"/>
  <text x="375" y="275" font-size="12" fill="#333">x</text>
  <text x="25" y="30" font-size="12" fill="#333">y</text>
  <line x1="40" y1="220" x2="380" y2="220" stroke="#ddd" stroke-width="0.5" stroke-dasharray="2,2"/>
  <line x1="40" y1="180" x2="380" y2="180" stroke="#ddd" stroke-width="0.5" stroke-dasharray="2,2"/>
  <polyline points="40,260 60,200 80,148 100,104 120,68 140,40 160,20 180,8 200,4 220,8 240,20 260,40 280,68 300,104 320,148 340,200 360,260" fill="none" stroke="#4285F4" stroke-width="2"/>
  <text x="200" y="4" text-anchor="middle" fill="#4285F4" font-size="13" paint-order="stroke fill" stroke="white" stroke-width="1.5">y=x²</text>
</svg>
</graph>
```

**三角函数的单位圆：**
```
<graph>
<svg viewBox="0 0 400 300" xmlns="http://www.w3.org/2000/svg">
  <circle cx="150" cy="180" r="80" fill="none" stroke="#333" stroke-width="1"/>
  <line x1="70" y1="180" x2="230" y2="180" stroke="#333" stroke-width="0.5"/>
  <line x1="150" y1="100" x2="150" y2="260" stroke="#333" stroke-width="0.5"/>
  <line x1="150" y1="180" x2="200" y2="140" stroke="#4285F4" stroke-width="2"/>
  <text x="205" y="145" fill="#4285F4" font-size="12" paint-order="stroke fill" stroke="white" stroke-width="1.5">θ</text>
  <line x1="200" y1="180" x2="200" y2="140" stroke="#EA4335" stroke-width="1.5" stroke-dasharray="3,2"/>
  <text x="205" y="175" fill="#EA4335" font-size="11" paint-order="stroke fill" stroke="white" stroke-width="1.5">sinθ</text>
  <line x1="150" y1="180" x2="200" y2="180" stroke="#34A853" stroke-width="1.5" stroke-dasharray="3,2"/>
  <text x="170" y="195" fill="#34A853" font-size="11" paint-order="stroke fill" stroke="white" stroke-width="1.5">cosθ</text>
</svg>
</graph>
```

**平行线与截线（几何）：**
```
<graph>
<svg viewBox="0 0 400 300" xmlns="http://www.w3.org/2000/svg">
  <line x1="30" y1="100" x2="370" y2="100" stroke="#333" stroke-width="2"/>
  <line x1="30" y1="200" x2="370" y2="200" stroke="#333" stroke-width="2"/>
  <line x1="100" y1="50" x2="300" y2="250" stroke="#4285F4" stroke-width="2"/>
  <text x="310" y="155" fill="#4285F4" font-size="13" paint-order="stroke fill" stroke="white" stroke-width="1.5">截线</text>
  <text x="320" y="95" fill="#333" font-size="12" paint-order="stroke fill" stroke="white" stroke-width="1.5">l₁</text>
  <text x="320" y="215" fill="#333" font-size="12" paint-order="stroke fill" stroke="white" stroke-width="1.5">l₂</text>
  <text x="185" y="135" fill="#EA4335" font-size="11" paint-order="stroke fill" stroke="white" stroke-width="1.5">∠1=60°</text>
</svg>
</graph>
```

**也可用 JSON 格式（适用于数据图表）：**

| type | 用途 | 数据格式 |
|------|------|---------|
| line | 折线图 | `[{"x":-3,"y":9}, ...]` |
| bar | 柱状图 | `[{"label":"A","value":10}, ...]` |
| scatter | 散点图 | `[{"x":1.2,"y":3.4}, ...]` |
| pie | 扇形图 | `[{"label":"A","value":15}, ...]` |

数据图表示例：
```
<graph>
{"type":"line","title":"y=x²","data":[{"x":-3,"y":9},{"x":-2,"y":4},{"x":-1,"y":1},{"x":0,"y":0},{"x":1,"y":1},{"x":2,"y":4},{"x":3,"y":9}]}
</graph>
```

**输出规则：**
- **禁止任何 ASCII 字符画图**（如用 ^、|、-、/ 画坐标轴或图形），必须用 `<graph>` 标签
- 几何图形、物理图示、电路图、光路图：**一律用 SVG**
- 函数图像、趋势数据：可用 `line`/`bar`/`pie` JSON 格式（渲染效果更好）
- SVG 的 `viewBox` 建议 `0 0 400 300`，坐标在 0~500 范围内
- 禁止引用外部图片，只能内联绘制
- **文字必须偏移放置**，不要放在线条上或顶点正中央
- 描边宽度用 1.5，够了