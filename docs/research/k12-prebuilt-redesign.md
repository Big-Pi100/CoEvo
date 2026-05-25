# K12 预生成方案设计 V2.3

> 日期：2026-05-25 | V2.3 — 管线完成 + 考试设计转向
> 核心变更：预生成管线全部落地，考题改为运行时 LLM 动态生成

---

## 一、背景

### V1 的问题

2026-05-23 实施 V1 方案后，发现规则提取有以下不可修复的问题：

1. **每科一个解析器** — 11 个解析器应对 21 个不同 MD 结构，维护成本高
2. **规则必然遗漏** — OCR 格式变化导致解析器漏 CR，需要大量手动补丁
3. **卡背质量差** — 词汇卡 `{"back": "等级: **"}` 等于空卡，概念卡句子截断
4. **验证循环** — R2 分批验证采样伪影，反复修反复验

### V2.1 的核心理念

**课标里只有三部分有价值：课程内容、学业质量、附录。且三部分各有分工，互不混淆。**

```
课程内容 → LLM 提取概念 + 交叉验证 → 去重逻辑排序 → Plan
          → 卡片关联（1:N）

附录     → 规则/LLM 提取词表 → LLM 生成卡背（音标/释义/例句/词性）
          → 字卡（汉字/拼音/笔画）

学业质量 → 分割完整条目（不做概念化） → 运行时 LLM 出题+判卷
          → 出题框架配置（预生成）→ 后端 k12_assessment crate

Plan → 关联 cards（gold_cr_ids）
     → 学习进度锚点
     → 出题框架（考试时 LLM 据此出题）

---

## 二、架构

### 2.1 完整流程

```
OCR MD 文件（38 份）
  │
  ▼ 清洗（通用三段分割）
  ├── 课程内容 raw_text → LLM 批量提取概念
  │     └─ 按 module 分组 → plan_builder → plans.json
  │
  ├── 学业质量 raw_text → 分割完整条目
  │     └─ 出题框架配置 → 运行时 LLM 动态出题+判卷
  │
  └── 附录（词汇/字表/参考书）→ 结构化提取
        └─ LLM 批量生成卡背 → cards.json
```

### 2.2 与 V1 架构对比

```
V1:
  MD → 11 个规则解析器 → gold JSON(层级) 
     → 验证(LLM) → 手动补丁 → 重建

V2:
  MD → 1 个清洗脚本 → raw_text → LLM 提取
     → 直接出概念/卡片/题库
```

---

## 三、两个入口（不变）

```
用户打开 App
  │
  ├── 🎓 K12 结构化学习
  │     用户选择 科目 + 年级
  │       → POST /k12/init
  │       → 进入对话（ws 同一入口）
  │       → ColdPath 2 运行
  │
  └── 🧭 自由探索（现有对话入口）
         → 无学科/年级限制
         → subject_router + LLM 计划
         → ColdPath 2 运行
```

**K12 入口的后端/前端代码不变。** 唯一变化是预生成数据的文件格式（从 V1 gold JSON 到 V2 gold JSON 的转换层）。

---

## 三、学习计划生成 — 两类科目不同策略

### 3.1 分类依据

科目分为两大类，Plan 生成逻辑完全不同：

| 类别 | 科目 | Plan 策略 |
|:----|:-----|:---------|
| **非语言类**（14科） | 数学/物理/化学/生物/历史/地理/信息科技/科学/体育/道德与法治 + 高中数理化生史地政 | 概念提取 → 逻辑排序 → Plan |
| **语言类**（4科） | 语文/英语/俄语/日语（义务+高中） | **场景×技能** → 按学段/级别组织 → 关联词表/篇目 |

### 3.2 非语言类 — 概念提取 + 逻辑排序

1. 从 `cleaned/_content.md` 获取【内容要求】段
2. LLM 提取学科知识点（概念、定义、规律、公式、事实）
3. 去重 → 按知识体系递进关系排序 → 生成 stage/task
4. 每个 task 关联 2-8 个概念（gold_cr_ids）

### 3.3 关键原则：Plan 生成时的逻辑推演与知识补全

提取的概念列表可能不完整或有遗漏（LLM 提取错误、课标本身跳跃）。Plan 生成时**不允许直接排序**，必须做一次 LLM 驱动的逻辑推演：

**推演步骤（Plan 生成阶段必须执行）：**

```
概念列表 → LLM 审查 → 发现缺失 → 补充知识点
          → 发现顺序问题 → 调整阶段
          → 发现课标盲区 → 标注待补
```

**具体规则：**
1. **前置知识检查** — 每个 stage/task 的前置概念是否已掌握？如果缺失，补充为前置 stage
2. **概念密度均衡** — 如果某 stage 概念过多（>12），拆分为多个 task；概念过少（<3），合并或补充
3. **课标缺陷标记** — 如果课标本身缺少关键知识点（例如"学习函数前无变量概念"），由 LLM 生成补充概念并标记为`课标补全`
4. **交叉引用** — 跨科目的概念引用（如物理的"能量守恒"与化学的"化学变化"），在关联中标注

**补充概念的来源优先顺序：**
  1. 同一科目内已有但被遗漏的概念
  2. 同一科目上一年级的概念（义务阶段跨学段复用）
  3. 数学作为所有理科的基础，跨科目补充（物理需要"向量"→数学提供）
  4. LLM 生成通用知识概念（最后选择）

**产出格式：** 每个概念增加 `origin` 字段标记来源：
- `extracted` — 课标原文提取
- `prequisite_gap` — 前置知识补全
- `curriculum_fix` — 课标缺陷补全
- `cross_subject` — 跨科目引用

---

## 四、全学科知识图谱

### 4.1 图的构建方式

Plan 是单学科的，但知识之间的联系天然跨学科。

**节点：** 所有科目 Plan 中标记为 `red` 或 `task` 的条目（统一用 stage/task ID 作节点 ID）

**边：** 分两层构建

#### 第一层：学科内边（Plan 生成阶段自动产出）

| 边类型 | 方向 | 产生方式 |
|:------|:----|:---------|
| `prerequisite` | 有向 | Plan 生成时 LLM 识别的 stage/task 依赖关系 |
| `refines` | 有向 | 同一学科内，后一 stage 对前一 stage 的深化 |

Plan 生成时 LLM 自动输出每个 task 的前置依赖列表，这些依赖构成学科内 DAG。

#### 第二层：跨学科边（后处理阶段单独运行）

跨学科边无法在 Plan 生成时一次性完成，因为需要知道**所有学科**的 Plan 结构。需要独立的后处理步骤：

```
所有 Plan 就绪 → 跨学科链接器 → 输出 cross_edges.json
```

**链接器工作方式：**

1. **名称对齐** — 扫描所有 Plan 的 stage/task，找到**同名或高度相似**的条目，建立 `cross_equivalent` 边
   - 示例：数学的"平面直角坐标系" ↔ 物理的"坐标系"
   
2. **LLM 交叉审查** — 对每个学科 Plan，LLM 标注"本学科哪些 task 需要其他学科知识"，列出依赖的学科+级别

3. **课程重叠分析** — 高中阶段理科共有的概念（能量/守恒/结构/变化等），自动连接

4. **学段衔接** — 义务阶段→高中阶段的同一学科 Plan 跨阶段连接

#### 边格式

```json
{
  "source": {"subject": "physics", "stage": "力学", "task": "牛顿第二定律"},
  "target": {"subject": "math", "stage": "函数与导数", "task": "向量运算"},
  "type": "cross_foundation",
  "strength": "strong",  // strong | medium | weak
  "note": "加速度合成分解依赖向量知识"
}
```

### 4.2 图谱的渐进式完善

知识图谱不需要一步到位。分三阶段推进：

| 阶段 | 范围 | 建立方式 |
|:----|:-----|:---------|
| **Phase 1** | 单学科内依赖 | Plan 生成时天然产出 |
| **Phase 2** | 跨学科连接 | 后处理 LLM 链接器 |
| **Phase 3** | 用户贡献 | 学习过程中用户发现的连接→反馈→图谱更新 |

### 3.4 语言类 — 场景×技能组织

语言学习的特殊性：知识点不是层级式的，而是**螺旋上升的场景能力**。

#### 义务教育语文

| 学段 | 组织维度 | 学习任务群 | 关联数据 |
|:----|:---------|:----------|:--------|
| 第一学段（1-2） | 家庭生活/学校生活/社会场景 | 语言文字积累/实用性阅读/文学阅读/思辨性阅读 | 字表一（300字） |
| 第二学段（3-4） | 校园内外/自然探索/人际交往 | 同上 | 字表一+二 |
| 第三学段（5-6） | 社会参与/科学探索/文学创作 | 同上 | 字表全部（3500字） |
| 第四学段（7-9） | 文化传承/社会议题/学术探究 | 同上 + 整本书阅读 | 字表 + 背诵篇目（135篇）+ 课外读物 |

Plan 结构：4 学段 × 4 任务群 = 16 stages，每 stage 按场景拆 tasks，task 关联字表/篇目

#### 义务教育英语

| 级别 | 对应年级 | 词汇范围 | 技能重点 |
|:----|:--------|:--------|:--------|
| 预备级 | 1-2 | CEFR A1 部分 | 视听说为主 |
| 一级 | 3-4 | CEFR A1 | 基础词汇+简单语篇 |
| 二级 | 5-6 | CEFR A1-A2 | 词汇扩展+语法入门 |
| 三级 | 7-9 | CEFR A1-A2（3694词） | 完整语篇+文化知识 |

Plan 结构：级别 → 6 要素（主题/语篇/语言知识/文化知识/语言技能/学习策略）→ 场景 task → 关联词汇

#### 高中语文

| 课程层级 | 任务群 | 重点 |
|:---------|:------|:-----|
| 必修 | 整本书阅读/当代文化参与/跨媒介阅读/语言积累（8任务群） | 基础阅读与表达能力 |
| 选择性必修 | 中华传统文化/革命传统/外国作家/科学文化（6任务群） | 深度阅读与专题探究 |
| 选修 | 汉字汉语/现当代作家/学术论文（4任务群） | 专业拓展与研究能力 |

Plan 结构：课程层级 → 任务群 → 学习目标与内容 → 关联背诵篇目+课外读物

#### 高中英语

| 课程层级 | 主题语境 | 语篇类型 | 词汇 |
|:---------|:---------|:--------|:----|
| 必修 | 人与自我/人与社会/人与自然（基础） | 对话/记叙文/说明文/应用文 | CEFR B1 部分 |
| 选择性必修 | 同上（扩展） | 议论文/讲座/报告/文学 | CEFR B1 |
| 选修（提高） | 同上（深度） | 演讲/辩论/学术论文 | CEFR B1（3956词）|

Plan 结构：课程层级 → 主题语境 → 6要素 → 场景 task → 关联 B1 词汇

### 3.4 英语词汇等级限制

| 学段 | CEFR 等级 | 词数 | 来源 |
|:----|:---------|:----|:-----|
| 义务教育 | A1 + A2 | 3,694 | CEFR 词库 |
| 高中 | B1 + B2 | 16,994 | CEFR 词库 |

### 3.5 词卡与 Plan 绑定

#### 绑定方式

词卡在重建时通过关键词匹配分配到 Plan task：

| 语言 | 匹配策略 | 覆盖率 |
|:----|:--------|:------|
| 汉语 | 字卡全归"识字"类 task | 100% |
| 日语/俄语 | 词卡全归"词汇"类 task | 100% |
| 英语 | 词卡按场景关键词匹配（translation/definition 中搜索场景词） | ~18% |

英语覆盖率低的核心原因：CEFR definition 字段质量差（内容为"n at level 2 (Brown freq: 74)"），缺少语义信息用于匹配。通用的冠词/介词/代词等基础词天然不归属特定场景。

#### 远期方案：LLM 按 task 生成阅读文章

这是语言学习的理想形态。每个 task 除了概念卡和词卡外，还有一篇 LLM 生成的短文：

```
Plan task "学校生活词汇"
  ├── 概念卡（场景描述 × 技能目标）
  ├── 词卡（school/teacher/classroom/homework 等，已绑 plan_task_id）
  └── LLM → 一篇短文自然覆盖这些词汇
       → 学生读文章 → 学词汇 → 做练习
```

**生成方式：** 后端在对话中按 task 动态生成，而非预生成。因为：
- 预生成文章需要大量存储且灵活性差
- 对话中 LLM 可以根据学生水平调整难度
- 同一词汇可在不同 task 的重复出现（强化记忆）

**生成时机：** 当 ColdPath 2 检测到学生进入某 task 且该 task 关联了词卡时，触发文章生成。

**覆盖验证：** task 完成时，LLM 检查该 task 下所有关联词卡是否已在对话/文章中覆盖 → 未覆盖的词在后续对话中主动插入。

义务教育到 A2 为止（对应课标 2,000+ 词要求），高中到 B1。B2+ 词汇由学生自由探索时主动制卡。

---

## 四、目录结构与命名规范

### 4.1 三级目录结构

```
docs/curriculum/
├── raw/                          # 原始课标文件（只读，唯一可信源）
│   ├── compulsory/               # 义务教育 17 科（16 学科 + 1 课程方案）
│   │   ├── 义务教育数学课程标准（2022年版）.md     ← OCR 文本
│   │   ├── 义务教育数学课程标准（2022年版）.pdf     ← 原始 PDF
│   │   └── ...
│   └── senior/                   # 高中 21 科
│       ├── 1.普通高中课程方案（2017年版2020年修订）.md
│       ├── 1.普通高中课程方案（2017年版2020年修订）.pdf
│       └── ...
│
├── gold/                         # 黄金数据（V2 管线输出）
│   ├── compulsory/
│   │   ├── math.json
│   │   ├── chinese.json
│   │   └── ...
│   └── senior/
│       ├── math.json
│       ├── chinese.json
│       └── ...
│
└── prebuilt/                     # 预生成数据（V2 管线输出）
    ├── plans/                    # 学习计划
    │   ├── math_g1-2.json
    │   ├── math_g3-4.json
    │   ├── ... 
    │   └── math_senior.json
    └── cards/                    # 学习卡片
        ├── math_g1-2.json
        ├── math_g3-4.json
        ├── ...
        └── math_senior.json
```

### 4.2 科目 key 映射

gold JSON 的文件名 = 科目 key。所有科目 key 统一为小写英文：

| key | 科目 | 级别 |
|:----|:----|:----:|
| `math` | 数学 | 义务+高中 |
| `chinese` | 语文 | 义务+高中 |
| `english` | 英语 | 义务+高中 |
| `physics` | 物理 | 义务+高中 |
| `chemistry` | 化学 | 义务+高中 |
| `biology` | 生物 | 义务+高中 |
| `history` | 历史 | 义务+高中 |
| `geography` | 地理 | 义务+高中 |
| `politics` | 思想政治 | 仅高中 |
| `science` | 科学 | 仅义务 |
| `it` | 信息科技 | 义务+高中 |
| `art` | 艺术 | 义务+高中 |
| `music` | 音乐 | 仅高中 |
| `fine_arts` | 美术 | 仅高中 |
| `pe` | 体育与健康 | 义务+高中 |
| `general_technology` | 通用技术 | 仅高中 |
| `russian` | 俄语 | 义务+高中 |
| `japanese` | 日语 | 义务+高中 |
| `german` | 德语 | 仅高中 |
| `french` | 法语 | 仅高中 |
| `spanish` | 西班牙语 | 仅高中 |
| `labor` | 劳动 | 仅义务 |
| `curriculum_framework` | 课程方案 | 义务+高中 |

### 4.3 文件名格式

```
raw/      {level}/{original_filename}.{md|pdf}
gold/     {level}/{subject_key}.json
prebuilt/ {type}/{subject_key}_{grade_band}.json
```

| 层级 | 例子 | 说明 |
|:----|:------|:------|
| raw | `raw/compulsory/义务教育数学课程标准（2022年版）.md` | 原始文件名不变 |
| gold | `gold/compulsory/math.json` | 科目 key |
| prebuilt/plans | `prebuilt/plans/math_g1-2.json` | 科目_key_grade |
| prebuilt/cards | `prebuilt/cards/math_g1-2.json` | 同上 |

### 4.4 grade_band 规范

| 代码 | 含义 |
|:----|:------|
| `g1-2` | 小学 1-2 年级（义务第一学段） |
| `g3-4` | 小学 3-4 年级（义务第二学段） |
| `g5-6` | 小学 5-6 年级（义务第三学段） |
| `g7-9` | 初中 7-9 年级（义务第四学段） |
| `senior` | 高中 |

### 4.5 预生成数据细节（更新）

### 4.5.1 卡片格式（复用 ColdPath 1 ConceptCandidate 格式）

预生成卡片必须与运行时  结构完全一致。



| 字段 | 规则 |
|:----|:------|
|  | 概念名称（名词短语，中文+英文术语优先）。不要问句 |
|  | 分段式结构，用  分隔。有则填写，无则留空 |
|  | 课标原文中提取该概念的句子 |
|  | 科目 key（如 math, chinese, biology） |

back 结构分段规范（按科目类型）：

| 类型 | 分段 | 例子 |
|:----|:------|:-----|
| 概念卡（理/文/工） | 定义 / 关键要素 / 应用 / 关联 | 生物: 定义: ...

结构: ...

功能: ...

关联: ... |
| 词汇卡（语言类） | 音标 / 释义 / 例句 / 词性 | 英语: 音标: /əˈbændən/

释义: 放弃

例句: He abandoned his plan.

词性: v. |
| 生字卡（语文） | 拼音 / 部首 / 笔画 / 组词 | 语文: 拼音: mā

部首: 女

笔画: 6

组词: 妈妈、姨妈 |
| 公式卡（数学/理科） | 公式 / 含义 / 条件 / 使用场景 | 数学: 公式: a²+b²=c²

含义: 直角三角形两直角边平方和等于斜边平方

条件: 直角三角形 |

**prompt 来源**: 复用  的单卡生成 prompt +  的结构化 back 规范。批量生成时，对每条概念独立发 LLM 请求，prompt 按 domain 选择对应的分段模板。

---

## 六、管线并行策略

### 6.1 为何需要并行

23科×每科5-10分钟LLM调用=串行2-4小时。除跨学科建图外，所有步骤均按科目独立，没有跨科依赖。

### 6.2 并行方案

| 阶段 | 方案 | 预计耗时 |
|:----|:----|:--------|
| 概念提取 | 23科分4批并行(每批6科×8路) | ~15分钟 |
| 词汇提取+卡背 | 按科目并行 | ~10分钟 |
| Plan生成+逻辑推演 | 按科目并行 | ~15分钟 |
| 考题生成 | 按科目并行 | ~10分钟 |
| 跨学科建图 | 单次，等待所有Plan就绪 | ~5分钟 |

### 6.3 实现方式

不修改脚本内部逻辑。每阶段提供两个入口：

```
scripts/gold/extract_{阶段}.py          # 单科目模式: --subject math
scripts/gold/run_parallel.py            # 并行Runner: 接收科目列表, multiprocessing.Pool分发
```

`run_parallel.py`逻辑：
```python
from multiprocessing import Pool

def run_subject(subject):
    subprocess.run(["python", "extract_stage.py", "--subject", subject])

with Pool(8) as p:
    p.map(run_subject, all_subjects)
```

---

## 七、大考系统设计（V2.3 新增）

### 7.1 设计原则

学业质量条目是综合性的能力描述，不是对具体知识点的考核。一份质量条目（如"能认识物质的形态、属性及结构，认识运动和力、声和光、电和磁"）覆盖 Plan 中**多个甚至全部 stage/task**。因此：

1. **不在预生成管线里出题** — 一套试卷无法覆盖所有学生的薄弱点，预出题浪费且不安全
2. **运行时 LLM 动态出题** — 后端 crate 按出题框架生成试卷，学生答完 LLM 判卷
3. **LLM 判卷比出题更适合 AI** — 判卷只需给一条质量条目 + 学生回答，判断"是否达到质量要求"；而出题需要严格约束（课标对齐/难度控制），LLM 自由发挥反而更自然

### 7.2 触发流程

```
ColdPath 2 检测到 stage 所有 task 完成
  → 后端推送到用户消息中心
     "物理·机械运动与简单机械 阶段测试已就绪"
  → 用户点开消息 → 进入独立考试页面（不在 ws 对话内）
  → 模拟真实考场环境（倒计时/题号导航/交卷/成绩单）
```

### 7.3 出题框架（配置文件，预生成）

出题框架是预生成的配置文件，告诉运行时 LLM 怎么出题。存在 `gold/{level}/{subject}_exam_framework.json`：

```json
{
  "subject": "physics",
  "level": "compulsory",
  "stages": [
    {
      "name": "机械运动与简单机械",
      "total_questions": 10,
      "types": {"choice": 4, "fill": 3, "calculation": 2, "short_answer": 1},
      "difficulty": "mixed",
      "quality_item_ids": [3, 4, 5],
      "task_names": ["运动的描述与速度", "重力", "机械功", "杠杆平衡条件", "省力杠杆与费力杠杆", "滑轮", "反冲运动"]
    }
  ]
}
```

### 7.4 后端新 crate: k12_assessment

```
backend/crates/k12_assessment/
├── Cargo.toml
├── src/
│   ├── lib.rs              # 主入口: assess_stage()
│   ├── framework.rs         # 出题框架配置加载
│   ├── generator.rs         # LLM 调用: 出题 + 判卷
│   └── grader.rs            # 评分逻辑: 汇总评估结果
```

API:
- `POST /k12/exam/start` — 开始考试（LLM 按框架出题，返回试卷）
- `POST /k12/exam/submit` — 交卷（LLM 判卷，返回成绩+薄弱点分析）

### 7.5 前端新页面

- 考试页面（独立路由，不在 ws 内）
- 模拟真实考场：倒计时、题号导航（上一题/下一题/跳转）、交卷
- 成绩结果页：总分、每题得分、薄弱知识点列表
- 消息中心面板：显示待完成的阶段测试通知

### 7.6 与小考的关系

| | 小考（日常考核） | 大考（阶段测试） |
|:----|:---------------|:---------------|
| 触发 | 对话中 LLM 自然问问题 | Stage 完成后的系统通知 |
| 位置 | ws 会话流内 | 独立考试页面 |
| 覆盖范围 | 当节课的 1-2 个 task | 整个 stage 所有 task |
| 预生成 | 不需要 | 出题框架配置 |
| 判卷方式 | LLM 在对话中判断 | LLM 批量判卷 + 分数报告 |

---

## 八、数据库与数据格式升级（图谱支持）

### 8.1 Plan JSON 格式升级

```json
{
  "id": "math_g3-4",
  "subject": "math",
  "grade_band": "g3-4",
  "goal": "学习数学三四年级核心内容",
  "stages": [
    {
      "name": "数与运算",
      "prerequisite_stages": [],
      "tasks": [
        {
          "name": "万以内的加减法",
          "gold_cr_ids": ["cr_001", "cr_002"],
          "dependencies": [],                    // 新增：本 task 的前置 task ID
          "cross_subject_refs": [],               // 新增：跨科依赖 [{subject,stage,task}]
          "origin": "extracted"                   // 新增：来源标记
        }
      ]
    }
  ]
}
```

origin 取值：
- `extracted` — 课标原文提取
- `prerequisite_gap` — 前置知识补全
- `curriculum_fix` — 课标缺陷补全
- `cross_subject` — 跨科目引用

### 8.2 Card JSON 格式升级

```json
{
  "id": "math_g3-4_0010",
  "subject": "math",
  "grade_band": "g3-4",
  "domain": "数学",
  "front": "...",
  "back": "...",
  "source_sentence": "...",
  "card_type": "concept",
  "gold_cr_id": "cr_001",              // 新增：关联到 Plan 中的概念
  "plan_task_id": "t_003",             // 新增：关联到 Plan task
  "origin": "extracted"                // 新增：来源标记
}
```

### 8.3 新增数据库表

```sql
-- 知识图谱边表
CREATE TABLE IF NOT EXISTS knowledge_graph (
    id TEXT PRIMARY KEY,
    source_subject TEXT NOT NULL,
    source_stage TEXT,
    source_task TEXT,
    target_subject TEXT NOT NULL,
    target_stage TEXT,
    target_task TEXT,
    edge_type TEXT NOT NULL,      -- prerequisite|refines|parallel|cross_foundation|cross_applies|assessment
    strength TEXT DEFAULT 'medium', -- strong|medium|weak
    note TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_kg_source ON knowledge_graph(source_subject, source_stage);
CREATE INDEX IF NOT EXISTS idx_kg_target ON knowledge_graph(target_subject, target_stage);
```

### 8.4 现有表改造（幂等迁移）

```sql
-- cards 表（V2 已迁移）
ALTER TABLE cards ADD COLUMN gold_cr_id TEXT DEFAULT NULL;
ALTER TABLE cards ADD COLUMN plan_task_id TEXT DEFAULT NULL;
ALTER TABLE cards ADD COLUMN origin TEXT DEFAULT 'extracted';

-- 大考表（V3 新增）
CREATE TABLE IF NOT EXISTS exam_frameworks (
    id TEXT PRIMARY KEY, subject TEXT, level TEXT,
    stage TEXT, config_json TEXT, created_at TEXT
);
CREATE TABLE IF NOT EXISTS exam_attempts (
    id TEXT PRIMARY KEY, user_id TEXT, subject TEXT,
    stage TEXT, score REAL, weak_tasks TEXT,
    score_detail TEXT, attempted_at TEXT
);
```

### 4.5.2 plans.json（旧格式将被升级）

```json
{
  "subject": "数学",
  "grade_band": "g3-4",
  "goal": "学习数学三四年级核心内容（按概念模块）",
  "stages": [
    { "name": "数与运算", "tasks": [{"name": "概念1"}, ...] },
    { "name": "图形与几何", "tasks": [...] }
  ]
}
```

### 4.3 cards.json（卡背质量提升）

```json
// V2 词汇卡 - 完整背面
{
  "id": "eng_vocab_0001",
  "front": "abandon",
  "back": "音标: /əˈbændən/ 释义: 放弃、遗弃 词性: v. 例句: He abandoned his plan to travel abroad.",
  "card_type": "vocabulary"
}

// V2 概念卡 - 完整背面
{
  "id": "math_concept_0001",
  "front": "集合",
  "back": "集合是由一些确定的、互不相同的元素构成的整体。用大写字母表示。元素用小写字母表示。属于关系用 ∈ 表示。",
  "card_type": "concept"
}
```

---

## 五、K12 模式初始化流程（不变）

```
用户选择 "数学" + "g3-4"
  → Flutter 调用 POST /k12/init
  → 后端:
      1. 创建新 conversation（带 subject/grade_band 标记）
      2. curriculum_loader 读取预生成 plans.json
      3. handle_plan_update() 将计划写入 learning_plans 表
      4. 预置卡片批量插入 cards 表
      5. 返回 { conversation_id, plan, cards }
  → 进入 ws 对话
```

---

## 六、ColdPath 2 完全复用（不变）

```
ColdPath 2:
  analyze_plan_progress()
    1. 读取对话历史
    2. 读取 learning_plans
    3. LLM 分析进度
    4. handle_plan_update()
```

---

## 七、卡片与对话绑定（不变）

```sql
ALTER TABLE cards ADD COLUMN conversation_id TEXT;
ALTER TABLE cards ADD COLUMN k12_card_id TEXT;
ALTER TABLE cards ADD COLUMN subject TEXT;
ALTER TABLE cards ADD COLUMN grade_band TEXT;
```

---

## 八、题库评估关口（不变）

```
触发点 A：对话中任务教学完成时 → 前端自动弹出测评
触发点 B：个人进度页手动触发 → 全面评级模式
```

---

## 九、进度追踪与成就（不变）

```
k12_progress 表：按用户×科目×年级记录进度
k12_achievements 表：成就解锁
```

---

## 十、数据库迁移（不变）

```sql
ALTER TABLE cards ADD COLUMN conversation_id TEXT;
ALTER TABLE cards ADD COLUMN k12_card_id TEXT;
ALTER TABLE cards ADD COLUMN subject TEXT;
ALTER TABLE cards ADD COLUMN grade_band TEXT;
CREATE TABLE IF NOT EXISTS k12_progress (...);
CREATE TABLE IF NOT EXISTS k12_achievements (...);
```

---

## 十一、实施分期（V2.3 更新）

### P0：数据管线重构（全部完成 ✅）
- [x] 清洗脚本 clean_curriculum.py
- [x] LLM 概念提取（extract_v3 / extract_language）
- [x] Plan 生成脚本 build_plans_v3.py（含逻辑推演补全）
- [x] 概念卡生成器 generate_cards_v2.py（8 学科路由）
- [x] 词卡富集 enrich_vocab.py（LLM 并发批量生成）
- [x] 词卡重建 + Plan 绑定 rebuild_vocab_cards.py（关键词匹配）
- [x] 学业质量条目分割 extract_quality_items.py
- [x] 设计文档同步 V2.3

### P1：后端大考系统（待实施）
- [ ] 新 crate: k12_assessment（出题框架 + LLM 出题 + 判卷）
- [ ] API: POST /k12/exam/start
- [ ] API: POST /k12/exam/submit
- [ ] 消息推送：stage 完成 → 通知用户 → 用户点开考试

### P2：前端大考页面（待实施）
- [ ] 考试页面（独立路由，模拟真实考场）
- [ ] 倒计时 / 题号导航 / 交卷
- [ ] 成绩结果页（总分 + 薄弱点分析）
- [ ] 消息中心面板

### P3：清理
- [ ] 删除废弃的规则解析器 (11 个文件)
- [ ] 删除 orchestrator.py
- [ ] 删除 llm_validate_3round.py
- [ ] 删除旧的 generate_k12_quizzes.py

---

## 十二、预期效果

| 指标 | V1（规则提取） | V2（LLM 提取） |
|:----|:-------------:|:--------------:|
| 卡背质量 | 空背面/截断 | 完整释义+例句 |
| 概念遗漏 | 高（规则匹配不到就漏） | 低（LLM 理解语义） |
| 解析器数量 | 11 个 | 1 个清洗脚本 |
| 验证耗时 | 40+ API 调用/轮 | 0（不需验证） |
| 数据生成耗时 | 多轮手动修 | 一次性批量跑 |
| 预生成总成本 | — | ~$5（一次性） |
| 运行时 LLM 成本 | 0 | 0 |

---

## 十三、保留的测试脚本

V2 保留了通用测试基础设施。K12 专用测试已于 2026-05-24 删除。

| 文件 | 用途 | 用法 |
|:----|:------|:-----|
| `backend/src/bin/e2e_pipeline_test.rs` | 端到端管线测试（对话+制卡+复习） | `cargo run --bin e2e-pipeline-test` |
| `scripts/live_llm_stream_test.py` | LLM 流式响应连通性测试 | `python scripts/live_llm_stream_test.py` |

**已删除的 K12 测试（V2 数据格式不同，需重写）：**
- `e2e_k12_runner.rs` → 待 V2 数据就绪后重写
- `e2e_k12_prebuilt_runner.rs` → 待 V2 数据就绪后重写
- `k12_tests/` crate → 待 V2 数据就绪后重写
- `evaluate.rs` → 概念提取评估，V2 方式不同
- `quality_eval/` crate → 依赖 k12_tests，一并删除
