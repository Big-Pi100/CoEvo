# 课标与教学融合方案设计

> 日期：2026-05-22 | V1.0
> 参考：Nature "Classroom AI" (2026) / arXiv 2311.17696 KG-RAG

---

## 一、问题陈述

当前 CoEvo 的教学管线对**学科、年级、课标毫无感知**：

```
用户: "我想学小学数学三年级"
  → LLM 自由发挥（无 subject/grade/curriculum 意识）
  → 可能教了五年级的内容（超纲）
  → 可能漏了三年级的核心概念（覆盖不全）
  → 事后评估才知道问题，已无法补救
```

**目标**：从用户入口到教学输出，全程受课标约束。

---

## 二、整体架构

四层结构，每层解决一个维度的问题：

```
                   用户消息入口
                        │
              ┌─────────┴─────────┐
              │  Layer 1          │  入口路由
              │  Entry Router     │  subject + grade → domain + band
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              │  Layer 2          │  课标约束
              │  Curriculum       │  "覆盖什么 + 不超什么"
              │  Bounding         │
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              │  Layer 3          │  知识图谱
              │  Knowledge Graph  │  概念关系 + 教学顺序
              └─────────┬─────────┘
                        │
              ┌─────────┴─────────┐
              │  Layer 4          │  评估反馈
              │  Evaluation       │  覆盖度 + 年级适配 + 缺失检测
              └─────────┬─────────┘
                        │
                 AI 教师输出
```

---

## 三、各层详述

### Layer 1: Entry Router（入口路由）

**功能**：从用户第一句话提取 subject + grade。

```
输入: "我想学小学数学三年级"
输出: {subject: "数学", grade: "三年级",
      domain: "math", grade_band: "g3-4"}
```

**已有工作**：
- `subject_router.rs` 已实现（LLM 路由 prompt + 映射函数）
- 路由 prompt 约 100 token，一次轻量 LLM 调用

**待完成**：
- 挂接到 WS 聊天入口（routes.rs）
- 将路由结果持久化到 conversation 表（新增 subject/grade_band 字段）
- 后续对话复用已路由结果（无需重复调用）

---

### Layer 2: Curriculum Bounding（课标约束）

**功能**：将课标要求作为教学边界注入 prompt。

**两个约束方向**：

```
COVER（覆盖什么）                  BOUNDARY（不超什么）
────────────────────────────      ────────────────────────────
- 本年级必须教的内容                - 本年级不要求的内容
- 从 curriculum_guide.json 读取     - 更高年级才学的内容
- 正面指引：确保覆盖                 - 负面约束：避免超纲
```

**Prompt 注入写法**：

```
### 课程范围与约束

你正在教 {subject}（{grade_band}）。

【必须覆盖的内容 — 请确保教学中涉及以下所有内容】
{curriculum_items}

【禁止超出范围的内容 — 以下内容不属于本年级要求】
教学中不应包含以下内容：
{excluded_items}

如果一个概念确实需要跨年级引用才能讲清楚：
1. 简要说明即可
2. 不要深入展开
3. 标注"这个概念你们会学到"
```

**课标范围判定逻辑**：

```
function get_curriculum_bounds(subject, grade_band):
    current = curriculum[subject][grade_band]     # 当前年级内容
    lower   = curriculum[subject][lower_band]     # 低年级（前置知识）
    upper   = curriculum[subject][upper_band]     # 高年级（未来知识）

    cover   = current                              # 必须覆盖
    allowed = lower + current                      # 可引用的（含前置）
    exclude = upper                                # 禁止深入的

    return { cover, exclude }
```

**示例**：数学 g3-4

```
覆盖：万以内数四则运算、小数与分数初步、周长与面积、角、计量单位
可引用前置（g1-2）：加减法、乘除法、简单图形、长度单位
禁止深入（g5-6）：分数四则运算、百分数、立体图形体积、圆、方程
```

**已有工作**：
- `curriculum_guide.json`（7.5KB，37 条）
- `subject_router.get_curriculum_hint()` 函数

**待完成**：
- 集成到 `build_plan_context()` 返回 curriculum bounds
- 注入到 `chat_system_structured.md` 和 `chat_system_free.md`

---

### Layer 3: Knowledge Graph（知识图谱）

**功能**：不仅告诉 LLM "教什么"，还告诉"按什么顺序教"和"概念之间有什么关系"。

**为什么需要知识图谱**：
课标摘要只列出了"要教哪些概念"，但没有概念间的依赖关系。例如：
- "一元二次方程"依赖"一元一次方程"
- "导数"依赖"极限"
- "定语从句"依赖"宾语从句"

没有知识图谱，LLM 可能跳过前置直接教后置。

**知识图谱结构**：

```
SubjectNode {
    concept: String,          // 概念名 (e.g., "一元二次方程")
    prerequisites: [String],  // 前置概念 (e.g., ["一元一次方程", "代数式"])
    belongs_to: String,       // 所属主题 (e.g., "方程与不等式")
    grade_band: String,       // 所属年级 (e.g., "g7-9")
    depth: u8,                // 教学深度 (1=了解, 2=理解, 3=掌握, 4=综合)
}
```

**构建来源**：
1. 课标 PDF 中的"内容要求"明确列出了知识点的学习深度
2. 教材大纲隐含了教学顺序（先学 X 再学 Y）
3. 语义关系（is-a、has-part、prerequisite）

**第一版方案**：人工构建核心概念图谱（每科 20-30 个关键节点，含前置关系）

```
数学 g7-9 片段：
  有理数 ─前置→ 实数 ─前置→ 一元一次方程 ─前置→ 一元二次方程
  一元一次方程 ─前置→ 不等式
  实数 ─前置→ 平面直角坐标系 ─前置→ 一次函数
```

**注入方式**：

```
### 概念依赖关系

本课涉及的概念依赖关系如下（→ 表示"依赖"或"之后学"）：
{knowledge_graph_paths}

请按此顺序教学：先教前置概念，再教后续概念。
不要跳过前置概念直接讲后面的内容。
```

**待完成**：
- 知识图谱数据结构定义
- 核心概念图谱（每科首批 20-30 节点）
- 图谱 → prompt 渲染函数

---

### Layer 4: Evaluation & Feedback（评估反馈）

**功能**：教学完成后，用量化指标评估课标覆盖度和年级适配度。

**现有评估线**：`e2e-quality-eval` 已实现 teacher/card/plan/review/student 五维评估。

**需要新增的评估指标**：

| 指标 | 方法 | 数据来源 |
|------|------|---------|
| **课标覆盖度** | 教学内容 vs curriculum_guide 对比 | teacher response + card_events |
| **年级适配度(客观)** | Flesch-Kincaid 等可读性指标 | teacher response 文本分析 |
| **知识图谱覆盖度** | 教学涉及概念 vs KG 节点比例 | card_events |
| **教学顺序合规** | 教学顺序是否遵循 KG 依赖关系 | plan_events |
| **超纲检测** | 是否出现上一学段的内容 | teacher response 文本分析 |

**年级适配度客观化**（参考 Nature "Classroom AI" 论文）：
- 使用 Flesch Reading Ease, Coleman-Liau Index 等可读性指标
- 对中文教材使用字词频率和句长统计
- 不同年级应有不同的可读性分数范围

---

## 四、依赖关系与实施顺序

```
Phase 1: 入口路由（已开始）
  Layer 1 完成
  ↓
Phase 2: 课标约束
  Layer 2 完成
    依赖 Layer 1 的输出（subject + grade_band 已知）
  ↓
Phase 3: 知识图谱
  Layer 3 完成
    依赖 Layer 2 的课标约束（知识范围已定）
  ↓
Phase 4: 评估反馈
  Layer 4 完成
    依赖 Layer 2+3 的课标/KG 数据（有基准才能评估）
```

### 排期

| 阶段 | 内容 | 文件 | 估计 |
|:----:|------|:----:|:----:|
| P1 | 入口路由 → WS 入口挂接 | routes.rs | 1h |
| P2a | curriculum_bounds 函数 + prompt 注入 | plan_handler.rs | 1h |
| P2b | 评估线集成课标覆盖度 | evaluator.rs | 1h |
| P3a | KG 数据结构 + 首批图谱（数学/英语） | knowledge_graph.rs | 2h |
| P3b | KG → prompt 渲染 | plan_handler.rs | 1h |
| P4 | 客观年级适配度（可读性指标） | evaluator.rs | 2h |

---

## 五、与现有体系的衔接

```
现有                            新增
══════════════════════          ══════════════════════
prompt_loader                    → Layer 2: curriculum_bounds 注入
  ├── chat_system_structured.md    ← 增加"课程范围与约束"段落
  └── chat_system_free.md          ← 同上

plan_handler                      → Layer 1: 路由结果持久化
  ├── build_plan_context()          ← 返回 curriculum_bounds
  └── handle_plan_update()          ← 不变

subject_router                    → Layer 1: 新建
     ← 已实现

knowledge_graph                   → Layer 3: 新建
     ← 数据结构 + 首批图谱

quality_eval                      → Layer 4: 扩充
  ├── evaluator.rs                  ← 增加课标覆盖度评估
  └── score.rs                      ← 增加年级适配度 L1 指标
```

---

## 六、关键决策记录

| 决策 | 选择 | 理由 |
|:----|:----|:------|
| 课标格式 | 手工精炼摘要 JSON | 7.5KB 全科，比 OCR 扫描版更实用 |
| 路由方式 | LLM 路由（方案 A） | 用户确认 |
| 约束注入方式 | system prompt 段落 | 零延迟，无额外 LLM 调用 |
| 知识图谱范围 | 每科首批 20-30 核心节点 | 够用，后续按需扩展 |
| 年级适配评估 | 可读性指标 + LLM 交叉审查 | 客观+主观结合 |
| 教学顺序控制 | prompt 中的 KG 路径指引 | 软约束（LLM 自遵守），不硬编码 |
