# Phase 3: 分级阅读课文 — 文本类型设计

## 核心思路

对标语文体系，英语阅读也分 text_type（体裁），每篇 task**只对应一个体裁**，按 CEFR 级别逐步扩展。

## 英语文本类型体系

| text_type | 中文类比 | 说明 |
|-----------|---------|------|
| `nursery_rhyme` | 语文 nursery_rhyme | 儿歌 / 童谣 / 韵律诗 |
| `dialogue` | — | 对话（日常场景、故事对话） |
| `poem` | 语文 poem | 诗歌（含打油诗、俳句、十四行诗） |
| `narrative` | 语文 vernacular | 叙事文（故事性阅读——主流类型） |
| `informational` | — | 说明文 / 知识性文章 |
| `opinion` | — | 议论文 / 观点表达 |
| `letter` | — | 书信（私人 + 正式） |
| `speech` | — | 演讲词 |
| `play` | — | 戏剧剧本节选 |
| `biography` | 语文 foreign? | 人物传记 |
| `report` | — | 报道 / 新闻 |
| `instruction` | — | 操作说明 / 食谱 / 规则 |
| `review` | — | 评论（书评、影评、餐厅评价） |

## CEFR × 文本类型 分布矩阵

| CEFR | Grade | 类型 | 篇数 | 每篇词数 | key_sentence_patterns 建议 | key_grammar 建议 |
|------|-------|------|------|---------|--------------------------|-----------------|
| **A1** | g1-2 | nursery_rhyme ×5, dialogue ×5, narrative ×5 | **15** | 20-60 | "I am...", "This is...", "I like...", "It is...", "I can..." | be动词, 一般现在时, 不定冠词, 形容词位置 |
| **A2** | g3-6 | narrative ×6, dialogue ×3, letter ×3, poem ×3, informational ×3, instruction ×2 | **20** | 60-180 | "There is/are...", "I went to...", "He said...", "First,...Then,..." | 一般过去时, 现在进行时, 可数/不可数, 介词 |
| **B1** | g7-9 | narrative ×6, informational ×5, opinion ×4, letter ×3, biography ×3, report ×2, poem ×2 | **25** | 180-350 | "In my opinion...", "It is believed that...", "Despite..., ...", "If I were..." | 现在完成时, 被动语态, 条件句, 关系从句 |
| **B2** | g10-12 | narrative ×4, opinion ×4, speech ×3, play ×2, biography ×2, review ×2, report ×2, poem ×1 | **20** | 350-700 | "The author argues that...", "Consequently,...", "Were it not for..." | 虚拟语气, 强调句, 倒装, 非谓语动词 |

**总计: ~80 篇课文**

## 各 text_type 的 card_back 数据结构

对照语文的 JSON 结构，英语阅读卡统一采用结构化 back：

### narrative（叙事文）
```json
{
  "full_text": "...",
  "translation": "...",
  "author": "..." | null,
  "source": "原创" | "改编自: ...",
  "key_sentence_patterns": [
    {"pattern": "Once upon a time...", "explanation": "故事开头：很久以前..."}
  ],
  "key_grammar": [
    {"point": "一般过去时", "example": "walked, said, went"}
  ],
  "vocabulary_focus": ["word1", "word2"],
  "common_mistakes": "...",
  "cefr_level": "A2",
  "tags": ["童话", "寓言", "冒险"]
}
```

### poem（诗歌）
```json
{
  "full_text": "...",
  "translation": "...",
  "author": "Robert Frost",
  "era": "20世纪",
  "technique": ["比喻", "意象", "押韵"],
  "theme": "自然与选择",
  "famous_lines": ["Two roads diverged in a wood, and I—"],
  "vocabulary_focus": ["diverged", "undergrowth", "hence"],
  "cefr_level": "B2",
  "tags": ["美国诗歌", "自然"]
}
```

### speech（演讲）
```json
{
  "full_text": "...",
  "translation": "...",
  "speaker": "Abraham Lincoln",
  "occasion": "葛底斯堡演说, 1863",
  "historical_context": "美国内战期间...",
  "key_rhetorical_devices": ["排比", "对仗"],
  "key_grammar": [],
  "vocabulary_focus": ["dedicate", "consecrate", "hallow"],
  "cefr_level": "B2",
  "tags": ["美国历史", "政治演说"]
}
```

## 名篇/公版资源推荐

| 作品 | 作者 | 公版状态 | 适合 CEFR | 适配 text_type |
|------|------|---------|----------|---------------|
| Aesop's Fables | 伊索 | ✅ 公版 | A2 | narrative |
| Grimm's Fairy Tales | 格林兄弟 | ✅ 公版 (1812) | A2-B1 | narrative |
| Andersen's Fairy Tales | 安徒生 | ✅ 公版 (1835+) | A2-B1 | narrative |
| Alice in Wonderland (excerpts) | Lewis Carroll | ✅ 公版 (1865) | B1 | narrative |
| The Adventures of Tom Sawyer | Mark Twain | ✅ 公版 (1876) | B1 | narrative |
| The Call of the Wild | Jack London | ✅ 公版 (1903) | B1-B2 | narrative |
| A Christmas Carol | Charles Dickens | ✅ 公版 (1843) | B1-B2 | narrative |
| The Importance of Being Earnest | Oscar Wilde | ✅ 公版 (1895) | B2 | play |
| The Gift of the Magi | O. Henry | ✅ 公版 (1905) | B1-B2 | narrative |
| The Tell-Tale Heart | Edgar Allan Poe | ✅ 公版 (1843) | B2 | narrative |
| Gettysburg Address | Lincoln | ✅ 公版 (1863) | B2 | speech |
| "The Road Not Taken" | R. Frost | ✅ 公版 (1916) | B1-B2 | poem |
| "Stopping by Woods" | R. Frost | ✅ 公版 (1923) | B1-B2 | poem |
| "I Wandered Lonely as a Cloud" | Wordsworth | ✅ 公版 (1807) | B1-B2 | poem |
| "Hope is the thing with feathers" | E. Dickinson | ✅ 公版 (1891) | B2 | poem |
| The Jungle Book (excerpts) | R. Kipling | ✅ 公版 (1894) | B1 | narrative |
| The Wind in the Willows | K. Grahame | ✅ 公版 (1908) | B1 | narrative |
| Little Women (excerpts) | L. M. Alcott | ✅ 公版 (1868) | B1 | narrative |
| "Shooting an Elephant" | George Orwell | ⚠️ 部分地区公版 | B2 | narrative/opinion |
| The War of the Worlds | H.G. Wells | ✅ 公版 (1898) | B1-B2 | narrative |
| Pride and Prejudice (opening) | Jane Austen | ✅ 公版 (1813) | B2 | narrative |
| The Happy Prince | Oscar Wilde | ✅ 公版 (1888) | B1 | narrative |
| Mother Goose Rhymes | 匿名 | ✅ 公版 | A1 | nursery_rhyme |

## 排版方案建议

**方案 A：AI 生成全部（80 篇）**
- 优点：完全可控，CEFR 级别精确匹配，词汇量可控
- 缺点：缺乏文化沉淀，文本质量不稳定

**方案 B：公版名篇为主（~50 篇）+ AI 补充（~30 篇）**
- A1: 全部 AI 生成（名篇达不到 A1 水平 → 儿歌除外）
- A2: 改编 Aesop + AI 补充
- B1: 名篇节选/改编为主（Mark Twain, Dickens, Andersen）
- B2: 名篇原版节选（Poe, Wilde, Frost, Lincoln）

**推荐：方案 B** — A1 走 AI，A2 及以上尽量用公版名篇（可能需要简写/节选适配 CEFR 级别），最后加上少量 AI 补缺。

## 下一步

确认方案后，开始生成每篇课文的详细内容（先 A1，逐步推进到 B2）。
