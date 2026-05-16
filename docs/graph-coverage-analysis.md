# 图形渲染工具 · K-12 覆盖率分析

> 日期：2026-05-16
> 背景：LLM 用 line 折线图画向量加法，视觉误导。需查缺补漏。

---

## 一、当前支持类型（6 种）

| type | 渲染方式 | 适用场景 |
|------|---------|---------|
| line | fl_chart LineChart | 函数图像、趋势线 |
| bar | fl_chart BarChart | 柱状图、数据对比 |
| scatter | fl_chart ScatterChart | 散点图、实验数据 |
| polygon | CustomPainter | 三角形、矩形、多边形 |
| circle | CustomPainter | 圆、弧 |
| arrow | CustomPainter | 向量、力分析 ← **今日新增** |

---

## 二、K-12 覆盖率逐年级分析

### 小学（1-6 年级）

| 知识点 | 图形需求 | 支持 | 状态 |
|--------|---------|------|------|
| 条形统计图 | bar | bar | ✅ |
| 折线统计图 | line | line | ✅ |
| 扇形统计图 | pie / 圆 + sector | circle | ⚠️ 缺扇区 |
| 长方形/正方形 | polygon 4点 | polygon | ✅ |
| 三角形 | polygon 3点 | polygon | ✅ |
| 平行四边形/梯形 | polygon 4点 | polygon | ✅ |
| 圆的认识 | circle | circle | ✅ |
| 数轴 | line + tick | line | ⚠️ 缺刻度 |
| **小学覆盖率** | | | **7/9 (78%)** |

### 初中（7-9 年级）

| 知识点 | 图形需求 | 支持 | 状态 |
|--------|---------|------|------|
| 一次函数 y=kx+b | line | line | ✅ |
| 二次函数 y=ax²+bx+c | line | line | ✅ |
| 反比例函数 y=k/x | line | line | ✅ |
| 坐标系描点 | scatter | scatter | ✅ |
| 三角形全等/相似 | polygon + 标记 | polygon | ⚠️ 缺角弧/等号标记 |
| 勾股定理 | polygon | polygon | ✅ |
| 平行四边形性质 | polygon | polygon | ✅ |
| 圆的性质（弦、切线） | circle + line | circle | ⚠️ 缺切线 |
| 数据的集中趋势 | bar / line | bar/line | ✅ |
| 三角函数初步（sin/cos） | line | line | ✅ |
| **初中覆盖率** | | | **8/10 (80%)** |

### 高中（10-12 年级）

| 知识点 | 图形需求 | 支持 | 状态 |
|--------|---------|------|------|
| 向量加减、数乘 | arrow | arrow | ✅ ← 本次补 |
| 向量数量积/夹角 | arrow + angle | arrow | ⚠️ 缺夹角弧 |
| 三角函数 y=sin(x) | line | line | ✅ |
| 导数/切线 | line + tangent | line | ⚠️ 缺切线标注 |
| 立体几何（三视图） | 3D 投影 | ❌ | ❌ 不支持 |
| 椭圆/双曲线/抛物线 | line (需方程) | line | ✅ |
| 复数平面 | arrow + polygon | arrow/polygon | ✅ |
| 概率分布（正态等） | line + fill | line | ✅ |
| 参数方程/极坐标 | line (需采样) | line | ✅ |
| 数列/递推 | bar/scatter | bar/scatter | ✅ |
| 受力分析 | arrow + 标注 | arrow | ✅ |
| **高中覆盖率** | | | **9/11 (82%)** |

---

## 三、总体评分

| 学段 | 覆盖率 | 等级 |
|------|--------|------|
| 小学 | 78% | 🟡 B |
| 初中 | 80% | 🟡 B |
| 高中 | 82% | 🟡 B |
| **综合** | **80%** | **🟡 B** |

---

## 四、已知缺陷 & 补齐路线

| 优先级 | 缺失项 | 实现方式 | 工作量 |
|--------|--------|---------|--------|
| 🔴 P0 | **arrow 向量** | ✅ 已实现 | done |
| 🟡 P1 | **pie 扇形图** | fl_chart PieChart | 1h |
| 🟡 P1 | polygon 顶点标注 | TextPainter 画标签 | 1h |
| 🟡 P1 | polygon 直角标记 | CustomPainter 画小方框 | 30min |
| 🟢 P2 | 坐标轴刻度标签 | 箭头图的坐标轴已有；line/bar 依赖 fl_chart 内置 | — |
| 🟢 P2 | 角度弧线 mark | CustomPainter 画弧 + 小标签 | 1.5h |
| 🟢 P2 | 圆切线 | CustomPainter 直线 + 切点 | 1h |
| 🔵 P3 | 立体几何投影 | 复杂，暂缓 | — |

---

## 五、本次修复结论

LLM 之前用 line 画向量的原因：**缺少 arrow 类型**。现在 `arrow` 已实现，提示词增加约束：

```
向量必须用 arrow 类型，禁止用 line 折线图冒充。
每条箭头包含 from/to/label 字段，支持多条箭头同框。
```

下次 LLM 画向量将输出正确的箭头图而非误导性折线。
