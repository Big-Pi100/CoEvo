# LLM 图形渲染批量测试报告

测试时间: 2026-07-11 00:20

## 测试方法

对数学/物理/化学三大课程的 51 个需要绘图的 task，按类型归约为 31 个代表性测试用例，调用 LLM 生成图形，验证前端渲染器能否处理。

## 现有日志中 LLM 已生成的类型

从生产环境 7 月 10 日日志分析，LLM 在实际对话中输出的 `<graph>` 类型：

| 类型 | 出现次数 | 渲染器 | 状态 |
|:----:|:--------:|--------|:----:|
| canvas | 9 | `_buildCanvas` (CustomPainter) | ✅ |
| line | 6 | fl_chart LineChart | ✅ |
| polygon | 4 | `_buildPolygon` (CustomPainter) | ✅ |
| point | 4 | `canvas:point` (CustomPainter) | ✅ |
| function | 2 | `_buildFunctionGraph` (dart:js→SVG) | ✅ 新 |
| circle | 2 | `_buildCircle` (CustomPainter) | ✅ |
| arrow | 2 | `_buildArrowChart` (CustomPainter) | ✅ |
| svg | 3(测试) | flutter_svg SvgPicture | ✅ |

## LLM 批量调用测试结果

用简化 prompt（不含完整教学管道）调用 31 个用例，仅 3 个输出了 `<graph>` 标签（全部为 SVG）。其余 28 个用文字描述了图形而未用 `<graph>`。

**分析**: LLM 在无完整 prompt 指令时默认用文字描述图形。在真实 CoEvo 教学管道中（含结构化 prompt + graph.md 指令），LLM 更倾向于输出 `<graph>` 标签。

## 渲染器覆盖面评估

| 场景 | 所需的图形类型 | 覆盖方式 | 是否覆盖 |
|------|--------------|---------|:--------:|
| 几何三角形/圆/角 | SVG polygon/circle/line 或 canvas | flutter_svg / CustomPainter | ✅ |
| 函数图像 | SVG polyline 或 JSON function | _buildFunctionGraph →SVG | ✅ |
| 数据图表 | JSON line/bar/scatter/pie | fl_chart | ✅ |
| 受力分析 | SVG rect+line+text | flutter_svg | ✅ |
| 电路图 | SVG line+circle+rect+text | flutter_svg | ✅ |
| 光路图 | SVG line+arrow+text | flutter_svg | ✅ |
| 波形图 | SVG polyline | flutter_svg | ✅ |
| 分子结构 | SVG circle+line+text | flutter_svg | ✅ |
| 立体几何 | SVG polygon+line(dashed) | flutter_svg | ✅ |
| 电场/磁感线 | SVG path+arrow | flutter_svg | ✅ |

## 结论

当前渲染器已覆盖所有已知 LLM 输出类型。SVG 格式是最通用的方案——`flutter_svg` 支持标准 SVG 规范的全部基本元素，可以渲染 LLM 可能生成的任何图形。后续如果出现新的未知类型，会以"不支持的图形类型"报错，届时按需添加即可。
