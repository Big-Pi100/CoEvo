# 英语 Plan & Card 重构计划

## 一、现状评估

### 数据概览

| 文件 | 总量 | 词卡 | 非词卡 | 当前 grade_band |
|------|------|------|--------|----------------|
| `english_compulsory.json` | 3,700 | 3,694 | 6 | 全部 `g7-9` |
| `english_senior.json` | 17,007 | 16,994 | 13 | 全部 `g10-12` |

### 问题清单

| # | 问题 | 严重度 |
|---|------|--------|
| 1 | **无真实分级**: 全部 g7-9 / g10-12 批量赋值，A1 词"a/the/I/am"与 B2 词同等对待 | P0 |
| 2 | **无低年级覆盖**: g1-2/g3-4/g5-6 无任何英语词卡 | P0 |
| 3 | **变形词独立成卡**: abandon/abandoned/abandoning 各是一张卡，应合并到源词 | P0 |
| 4 | **无课文驱动**: 当前 task 是话题型（"家庭与学校基础词汇"），非文本驱动 | P1 |
| 5 | **缺分级阅读卡**: 无 `reading` 类型的课文卡（仅有 12 张 skill 卡） | P1 |
| 6 | **无语法/句型元数据**: 词卡只有释义，缺句型、语法点 | P2 |

## 二、目标

对标语文的课文驱动模式，基于 **CEFR** 重建英语学习体系。

### 核心原则

1. **CEFR 分级**: A1 → A2 → B1 → B2，精确到每张词卡的级别
2. **课文驱动**: 每个 task 对应一篇分级阅读短文（reading card），包含 full_text
3. **变形词合并**: abandon/abandoned/abandoning → 统一为 "abandon" 一张卡，back 中列出变形
4. **词汇按首次出现分配**: 词卡绑定到首次出现该词的课文 task（与语文一致）
5. **课文卡含翻译/句型/语法**: 对标语文文学卡的 full_text + 元数据结构

### 级别映射

| CEFR | 对应 CoEvo 年级 | 词汇量 | 阅读能力描述 |
|------|----------------|--------|------------|
| A1 | g1-2 (入门) | ~500 | 简单单词、短句、日常问候、自我介绍 |
| A2 | g3-4 → g5-6 (基础) | ~1,500 | 简单段落、日常话题、基本时态 |
| B1 | g7-9 (中级) | ~2,500 | 中等长度文章、观点表达、复合句 |
| B2 | g10-12 (中高级) | ~3,500+ | 复杂论述、抽象话题、学术预备 |

## 三、数据结构设计

### 课文卡（reading card）结构

对标语文文学卡，增加英语特有字段：

```json
{
  "id": "uuid",
  "card_type": "reading",
  "front": "My First Day at School",
  "subject": "english",
  "domain": "language",
  "grade_band": "g1-2",
  "cefr_level": "A1",
  "back": {
    "full_text": "Hello! My name is Tom. This is my first day at school. I see a big desk. I see a red book. My teacher is nice. I am happy.",
    "translation": "你好！我叫汤姆。这是我第一天上学。我看到一张大桌子。我看到一本红色的书。我的老师很好。我很开心。",
    "key_sentence_patterns": [
      {"pattern": "My name is...", "explanation": "自我介绍：我的名字是..."},
      {"pattern": "This is my...", "explanation": "这是 my + 名词"},
      {"pattern": "I see a...", "explanation": "我看到一个..."},
      {"pattern": "...is/am + adjective", "explanation": "be动词 + 形容词"}
    ],
    "key_grammar": [
      {"point": "be动词 (am/is) 基本用法", "example": "I am... / This is..."},
      {"point": "不定冠词 a/an", "example": "a desk, a book"},
      {"point": "形容词基本位置", "example": "a red book, a big desk"}
    ],
    "vocabulary_focus": ["name", "first", "day", "school", "desk", "book", "teacher", "nice", "happy", "see"],
    "common_mistakes": "\"see\" 与 \"look\" 混淆；形容词位置放在名词前"
  }
}
```

### 词卡（vocabulary card）结构改进

变形词合并到源词的 back 中：

```json
{
  "id": "uuid",
  "card_type": "vocabulary",
  "front": "abandon",
  "subject": "english",
  "domain": "language",
  "grade_band": "g10-12",
  "cefr_level": "B2",
  "back": {
    "meaning": "放弃，遗弃",
    "phonetic": "/əˈbændən/",
    "part_of_speech": "动词",
    "inflections": {
      "past": "abandoned",
      "past_participle": "abandoned",
      "present_participle": "abandoning",
      "third_person": "abandons",
      "noun_form": "abandonment"
    },
    "examples": [
      "They decided to abandon the project.",
      "The car was abandoned on the street."
    ],
    "collocations": ["abandon hope", "abandon ship", "abandon a plan"],
    "related_words": ["abandoned (adj.)", "abandonment (n.)"],
    "common_mistakes": "abandon 后直接跟宾语，不需要介词"
  }
}
```

## 四、实施步骤

### Phase 1: 词库瘦身与合并

- 合并变形词: abandon/abandoned/abandoning → abandon
- 去重 (派生词合并到源词的 inflections 字段)
- 预估: 20,688 → ~8,000 词根

### Phase 2: CEFR 重分级

- 用 Oxford 3000/5000 或 English Profile 作为基准
- 按 A1→B2 重新分配 grade_band
- 生成新的 grade_band 分布:
  - A1 → g1-2: ~500词
  - A1/A2 → g3-4: ~800词
  - A2 → g5-6: ~700词
  - A2/B1 → g7-9: ~1,500词
  - B1/B2 → g10-12: ~3,500词

### Phase 3: 分级阅读课文卡

按 CEFR 级别创建阅读短文：

| CEFR | 课文数 | 每篇词数 | 主题 |
|------|--------|---------|------|
| A1 | ~15 篇 | 30-80 词 | 日常生活、自我介绍、家庭、学校 |
| A2 | ~20 篇 | 80-200 词 | 爱好、天气、食物、旅行 |
| B1 | ~25 篇 | 200-400 词 | 文化、科技、环境、健康 |
| B2 | ~20 篇 | 400-800 词 | 社会议题、抽象讨论、学术 |

每篇课文包含：
- full_text（英语原文）
- translation（中文翻译）
- key_sentence_patterns（重点句型）
- key_grammar（重点语法）
- vocabulary_focus（本课核心词汇）

### Phase 4: 重建 english.json plan

- task 按课文标题命名（与语文一致）
- 每个 stage 对应一个 CEFR 级别
- card_ids 按课文 → 词汇的首现关联重建
- grade_band 改为 CEFR 对应的 g1-2/g3-4/g5-6/g7-9/g10-12

### Phase 5: 读卡验证

- 验证 task ↔ 课文卡匹配率（目标 100%）
- 验证词汇分配顺序正确性
- 验证变形词合并无遗漏
- 运行后端测试套件

## 五、待确认事项

1. **变形词合并策略**: 哪些算"变形词"？
   - ✅ 规则变形: abandon/abandoned/abandoning/abandons → 合并
   - ✅ 派生词: abandon/abandonment → 合并
   - ❓ 完全不同的词义: like (喜欢) / like (像) → 同一词还是分开？
   - ❓ 词性转换: clean (v.) / clean (adj.) → 同一卡不同释义，还是分开？

2. **课文来源**: 目前计划由 LLM 按 CEFR 级别生成，是否需要人工审核？

3. **进度**: 是先做 Phase 1-2（词库瘦身+分级），再 Phase 3-4（课文+重建），还是整体一起做？
