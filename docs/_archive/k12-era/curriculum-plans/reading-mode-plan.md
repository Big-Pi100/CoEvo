# K12 语文（语言类）课文模式改造计划

## 一、现状与问题

当前架构以**知识点/技能维度**组织 plan：

- Stage = 学段（"第一学段：识字与基础阅读"）
- Task = 技能点（"生活场景识字与拼音"）
- Reading 卡 = task 附属内容

问题：语文/外语学习天然以**文本/课文**为入口。学生先接触课文，在阅读中自然渗透知识。当前 plan 以知识点为入口，不符合语言教学认知规律。

## 二、目标模式

```
课本单元(Stage)
  ├── 第1课(Task) → Reading卡(课文全文)
  │     ├── 教学：语句赏析·人物·手法·主旨(Lesson)
  │     └── 复习：Concep卡(渗透知识点)
  ├── 第2课(Task) → Reading卡(课文全文)
  └── 单元整合(Task) → 拓展阅读/写作
```

**关键转变：**
- Task = 一篇课文，不再是一个技能点
- Reading 卡 = task 的核心（front 展示课文，back 考点分析）
- Concept 卡 = reading 中渗出的知识点（人物、手法、字词等）
- 进入 task 的体验：先看课文 → 完成交互 → 暴露知识点

## 三、改造范围

### 第一批：语文（先行）
- 初中7-9年级课文目录已有（6册，~120课）
- 高中必修+选择性必修课文目录已有（5册，~100课）
- 小学课文量大约400课（6年×上下册），可作为后续

### 第二批：英语、日语、俄语（母语水平，非国内K12教材）

**放弃使用国内K12英语教材。** 国内教材学完仍无法正常读写，达不到母语水平目标。

改为使用**母语国家的真实材料**，按语言能力水平分级：

| 语种 | 课文来源 | 水平分级 |
|:----|:---------|:---------|
| 英语 | 英美原版分级读物/新闻/文学/学术文章 | CEFR A1→C2 |
| 日语 | 日本国语教材/新闻/文学 | JLPT N5→N1 |
| 俄语 | 俄罗斯原版教材/文学 | TORFL A1→C2 |

**Plan 组织**：按CEFR/语言水平，不按年级。

```json
{
  "subject": "english",
  "goal": "母语级英语读写能力",
  "stages": [
    {
      "name": "CEFR A1 · 基础阅读",
      "sort": 0,
      "grade_band": "a1",  // ← 不再是g1-2等学段
      "tasks": [...]
    },
    {
      "name": "CEFR B2 · 文学赏析",
      "sort": 3,
      "grade_band": "b2",
      "tasks": [...]
    }
  ]
}
```

**词卡同样按CEFR分组**：A1词表、A2词表...C2词表。

### 第三批：日语/俄语
采用与英语相同的母语水平标准，使用原版材料按 CEFR/JLPT/TORFL 分级。

| 语种 | 内容来源 | 分级方式 |
|:----|:---------|:--------|
| 日语 | 日本国语教材/新闻/文学/学术文本 | JLPT N5→N1 |
| 俄语 | 俄罗斯原版教材/新闻/文学/学术文本 | TORFL A1→C2 |

无现成材料的，用 LLM 按对应级别生成课文 + 词表 + 练习。

## 四、数据模型设计

### 新版 Plan JSON（语文为例）

```json
{
  "subject": "chinese",
  "goal": "语文课文阅读与素养提升",
  "stages": [
    {
      "name": "七年级上册·第一单元",
      "sort": 0,
      "grade_band": "g7-9",
      "tasks": [
        {
          "name": "春",
          "sort": 0,
          "mode": "reading_first",     // ← 新字段：课文优先模式
          "reading_card_id": "reading_ext_初中白话文_春",
          "lesson_script": "本文是朱自清的写景抒情名篇...",
          "key_points": [
            {"type": "appreciation", "label": "语句赏析"},
            {"type": "technique", "label": "写作手法"},
            {"type": "theme", "label": "主旨概括"}
          ],
          "concept_ids": ["chinese_compulsory_xxxx"],
          "gold_cr_ids": []
        }
      ]
    }
  ]
}
```

## 词卡与阅读的整合

**核心原则**：课文是语境，词卡是目标。

### 各学段的词卡-阅读关系

| 学段 | 关系 | 教学重点 |
|:----|:-----|:---------|
| g1-2 儿歌 | 儿歌全文 ≈ 词卡合集 | 通过唱儿歌学字词 |
| g3-4 入门 | 课文引出新字词 | 识字为主，赏析为辅 |
| g5-9 发展 | 课文深化词义理解 | 读写并重 |
| g10-12 深造 | 课文提升语感与表达 | 鉴赏为主，词卡退为辅助 |

### 数据结构：Task 关联词卡

```json
{
  "name": "两只老虎",
  "mode": "nursery_rhyme",
  "vocab_card_ids": ["chinese_compulsory_0003", ...],
  "focus": "重复句式·身体部位词汇",
  "core_characters": ["虎", "跑", "耳", "眼"]
}
```

```json
{
  "name": "春",
  "mode": "reading_first",
  "reading_card_id": "reading_ext_初中白话文_春",
  "vocab_card_ids": [...],  // 本课生词：盼、润、嫩、眨...
  "focus": "语言特色·比喻排比",
  "lesson_script": "..."
}
```

### 教学流程

```
进入 task "春"：

① 展示课文全文（Reading卡） → 学生阅读
② 重点字词（词卡列表） → 学生跟读/识记
③ 核心教学点（focus） → LLM引导学生赏析
④ 词卡复习 → 按 FSRS 调度
⑤ Concept卡解锁（可选） → 仅高年级需要
```

每篇文章只出场一次，讲它最突出的那一点。不贪多。

| 课文 | 核心教学点 | 出场学段 |
|:----|:----------|:--------|
| 《背影》 | 细节描写与情感表达 | 初二 |
| 《孔乙己》 | 人物刻画·社会批判 | 初三 |
| 《故都的秋》 | 情景交融 | 高一 |
| 《祝福》 | 叙事结构·反讽 | 高一 |
| 《春》 | 语言特色·比喻排比 | 初一 |

Task 数据结构：

```json
{
  "name": "背影",
  "mode": "reading_first",
  "reading_card_id": "reading_ext_初中白话文_背影",
  "focus": "细节描写与情感表达",
  "extra_points": ["线索安排"],
  "lesson_script": "围绕'背影'细节展开..."
}
```

| 字段 | 用途 | 适用范围 |
|:----|:-----|:---------|
| `mode` | 教学模式：`reading_first` / `knowledge_first` | 语言类 vs 数理化 |
| `reading_card_id` | 关联的 reading 卡片 ID | reading_first 模式 |
| `lesson_script` | 教师讲解脚本/核心提示 | reading_first 模式 |
| `key_points` | 本课重点考点列表 | 语言类 |

## 五、实施步骤

### Step 1：语文 prototype（1-2天）
选一篇课文（《春》），走通 `reading_first` 全链路：
- 数据：Plan task 含 `mode` / `reading_card_id` / `focus` / `vocab_card_ids`
- 后端：curriculum_loader 解析新模式 → 将 Reading卡+词卡+Concept卡一并注入 LLM context
- 会话流：LLM 按"课文→词汇→focus→复习"顺序教学
- 前端：`reading_first` 模式的 UI 展示

产出：一条可测试的完整链路，验证数据模型和会话流程。

### Step 2：语文全量重构（3-5天）
- 初中课文已确认约120课 → 按课本单元重构 plan JSON
- 每个 task 绑定一张 reading 卡 + N张关联词卡 + 1个 focus 教学点
- 概念卡保留但调整为 `reading_first` 展示顺序（课后解锁）

### Step 3：英语/日语/俄语 — CEFR 内容规划（分批进行）
**不采用国内 K12 教材，改为原版母语材料 + CEFR 水平分级。**

| 语种 | 内容来源 | 分级方式 | 首批范围 |
|:----|:---------|:--------|:---------|
| 英语 | 英美分级读物/新闻/文学 | CEFR A1→C2 | 先做 A1-B1 基础段 |
| 日语 | 日本国语教材/新闻/文学 | JLPT N5→N1 | 先做 N5-N4 基础段 |
| 俄语 | 俄罗斯原版教材/文学 | TORFL A1→C2 | 先做 A1-A2 基础段 |

英语优先做，日语/俄语后续。
- Plan 按 CEFR 级别组织（不再使用 `g1-2` 等学段字段）
- 每个 level 建一批课文 reading 卡 + 对应词表
- 词卡用 CEFR 通用词表（A1/A2/B1...），不用国内教材词表

### Step 4：启蒙阶段（语文 g1-2）——儿歌化
**原则**：不上课文，不上知识点。g1-2 以儿歌/童谣为载体。

**模式**：`nursery_rhyme`
- Task = 一首儿歌（《小星星》《找朋友》《两只老虎》）
- 卡片 = 儿歌原文 + 画面描述 + 重复句式
- 教学 = 跟读 → 理解 → 输出
- 无 Concept 卡解锁，完成儿歌就通关

```json
{
  "name": "两只老虎",
  "mode": "nursery_rhyme",
  "reading_card_id": "...",
  "vocab_card_ids": ["chinese_compulsory_0003"],
  "focus": "重复句式·身体部位词汇",
  "core_characters": ["虎", "跑", "耳", "眼"]
}
```

**素材清单**：小学一年级儿歌约60首（已有课标篇目中的低幼部分可选取）

### Step 5：三门外语的启蒙阶段
按 CEFR Pre-A1 处理，**同样可以使用儿歌模式**（`nursery_rhyme`）：

| 语种 | 儿歌素材 | 教学点 |
|:----|:---------|:-------|
| 英语 | Twinkle Twinkle, Old MacDonald, Wheels on the Bus... | 韵律+基础词汇+简单句式 |
| 日语 | むすんでひらいて、かえるのうた、ぞうさん... | 假名+基本动词+重复结构 |
| 俄语 | Во поле берёза стояла, Калинка... | 字母+基础词汇+韵律 |

儿歌是跨语言通用的启蒙利器，不限于中文。

## 六、前端调整要点

### `reading_first` 模式下的 task 展示

```
进入 task：
  ┌─────────────────────────────┐
  │  春                          │  ← Reading卡 front（标题）
  │  [朱自清]                     │
  ├─────────────────────────────┤
  │  课文全文展示                  │  ← Reading卡 back（全文）
  │  盼望着，盼望着，东风来了...    │
  │                             │
  │  [开始学习]                    │  ← 跳转到知识点交互
  └─────────────────────────────┘

  ↓ 点击"开始学习"

  ┌─────────────────────────────┐
  │ 📝 语句赏析                    │  ← key_points 逐个展开
  │ "小草偷偷地从土里钻出来"       │
  │ → 拟人手法，"偷偷地""钻"      │
  │                             │
  │ 📝 主旨概括                     │
  │ → 赞美春天，热爱生活           │
  └─────────────────────────────┘
```

### 数理化保持原样
`knowledge_first` → 直接显示概念 cards

## 七、风险与注意

1. **数据量**：语文初中+高中约220课，每课需确认 reading 卡ID正确绑定
2. **启蒙阶段**：g1-2 保持旧模式，不做课文化
3. **课文不全**：当前 reading 卡覆盖了古诗文+白话文+外文，但可能有遗漏
4. **概念卡**：现有的 concept 卡需要按课文重新分配（大部分已通过 `gold_cr_ids` 和 `plan_task_id` 对齐）

---

## 八、代码影响分析 — 独立路线方案

**核心原则**：不修改现有`knowledge_first`代码。新建独立模块，与当前 K12 体系并行。

| 维度 | 现有 K12 | Reading-First |
|:----|:---------|:--------------|
| API | `/api/k12/init` | **新建** `/api/k12/reading/init` |
| 数据加载 | `curriculum_loader.rs` | **新建** `reading_loader.rs` |
| 计划管理 | `plan_handler.rs` | **新建** `reading_plan.rs` |
| 会话流 | `ws.rs` K12 分支 | **新建** reading 分支 |
| 前端入口 | `k12_subject_screen.dart` | **新建** `reading_subject_screen.dart` |
| 卡片类型 | concept / vocabulary | poem / classical / vernacular / foreign / whole_book / nursery_rhyme |
| LLM Prompt | `chat_system_structured.md` | **新建** `chat_system_reading.md` 系列 |

### 数据流（独立路线）

```
前端选语文→初中
  ↓ POST /api/k12/reading/init
reading_loader.rs → 加载 reading_plan.json + reading_cards
  ├── plan 结构（stage=单元, task=课文）
  ├── task 包含: reading_card_id, focus, vocab_card_ids
  ├── reading 卡片（全文+考点）
  └── 词卡分组（按课文）

进入聊天
  ↓ WebSocket → mode="reading"
reading_plan.rs → build_reading_context()
  ├── 当前 task 的 reading 卡全文
  ├── 本课词卡列表
  ├── focus 教学点
  └── 注入 LLM context

LLM 回复
  ↓
chat_system_reading.md → 课文驱动教学流程
  ↓
reading_plan.rs → handle_reading_plan_update()
  ├── 推进课文 task
  └── 三层解锁：reading卡 → 词卡 → concept卡
```

### 需新建文件

**后端：**
- `src/reading_loader.rs` — 加载 reading plan + reading 卡片 + 词卡分组
- `src/reading_plan.rs` — reading plan 的上下文构建 + 进度管理
- `routes.rs` — 新增 2 个 endpoint（init + progress）
- `ws.rs` — 新增 `mode="reading"` 的 WebSocket 分支
- `prompts/chat_system_reading.md` — 课文教学模式 prompt
- `prompts/chat_system_nursery.md` — 儿歌教学模式 prompt

**前端：**
- `screens/reading_subject_screen.dart` — 语文入口
- `screens/reading_chat_screen.dart` — 课文优先的聊天界面
- `widgets/article_card_widget.dart` — 课文全文展示控件

### 数据文件

```
data/curriculum/prebuilt/
  reading_plans/
    chinese.json         ← 按课文组织的语文 plan（stage=单元, task=课文）
  cards/
    chinese_reading.json       ← reading 卡片（已有208张）
    chinese_reading_extended.json ← 白话文/外文/整本书（已有142张）
```

## 九、实施计划

### Phase 1：数据原型（1天）
1. 写 `reading_plans/chinese.json` 示例（1个stage=《春》，绑定 reading 卡+词卡+focus）
2. 确认三条数据线的关联：reading卡 ↔ 词卡 ↔ concept卡

### Phase 2：后端链路（1天）
3. 新建 `reading_loader.rs` — 加载 reading plan
4. `routes.rs` 新增 `/api/k12/reading/init`
5. `ws.rs` 新增 `mode="reading"` 分支
6. `reading_plan.rs` — 上下文构建

### Phase 3：Prompt（半天）
7. 写 `chat_system_reading.md`（课文教学模式）
8. 写 `chat_system_nursery.md`（儿歌教学模式）

### Phase 4：前端原型（1天）
9. 新建 `reading_subject_screen.dart`
10. 新建课文展示控件

### Phase 5：全量数据（3-5天）
11. 语文350篇课文 → 全量绑定到 plan
12. 英语/日语/俄语 → CEFR 独立路线（数据内容独立规划）

**拟稿人**：WorkBuddy
**日期**：2026-05-26
