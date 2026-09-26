# curriculum — 课标数据集

> 最后更新：2026-05-24 | V2 目录结构

---

## 目录结构

```
docs/curriculum/
├── raw/                          # 原始课标文件（只读，测试数据唯一可信源）
│   ├── compulsory/               # 义务教育 17 科（16 学科 + 1 课程方案）
│   │   ├── 义务教育数学课程标准（2022年版）.md     ← OCR 文本
│   │   ├── 义务教育数学课程标准（2022年版）.pdf     ← 原始 PDF（OCR 来源）
│   │   └── ...（共 17 科 × 2 = 34 文件）
│   └── senior/                   # 高中 21 科（20 学科 + 1 课程方案）
│       ├── 1.普通高中课程方案（2017年版2020年修订）.md
│       ├── 1.普通高中课程方案（2017年版2020年修订）.pdf
│       └── ...（共 21 科 × 2 = 42 文件）
│
├── cleaned/                     # 三段式清洗文本（V2 管线输出，不覆盖 raw/）
│   ├── compulsory/
│   │   ├── math.md              # 全量清洗文本
│   │   ├── math_content.md      # 课程内容（概念来源）
│   │   ├── math_quality.md      # 学业质量（题库来源）
│   │   ├── math_appendix.md     # 附录（词表/参考书）
│   │   └── ...
│   └── senior/
│       ├── math.md
│       ├── math_content.md
│       ├── math_quality.md
│       ├── math_appendix.md
│       └── ...
│
├── gold/                         # 黄金数据（V2 管线输出）
│   ├── compulsory/               # 义务教育金数据
│   │   ├── math.json
│   │   ├── chinese.json
│   │   └── ...
│   └── senior/                   # 高中金数据
│       ├── math.json
│       ├── chinese.json
│       └── ...
│
├── prebuilt/                     # 预生成数据（V2 管线输出）
│   ├── plans/                    # 学习计划
│   │   ├── math_g1-2.json
│   │   ├── math_g3-4.json
│   │   ...
│   │   └── math_senior.json
│   └── cards/                    # 学习卡片
│       ├── math_g1-2.json
│       ├── math_g3-4.json
│       ...
│       └── math_senior.json
│
└── README.md                     # 本文件
```

---

## 命名规则

### 科目 key（gold JSON 文件名）

| key | 科目 | 级别 |
|:----|:----|:----|
| `math` | 数学 | 义务 + 高中 |
| `chinese` | 语文 | 义务 + 高中 |
| `english` | 英语 | 义务 + 高中 |
| `physics` | 物理 | 义务 + 高中 |
| `chemistry` | 化学 | 义务 + 高中 |
| `biology` | 生物 | 义务 + 高中 |
| `history` | 历史 | 义务 + 高中 |
| `geography` | 地理 | 义务 + 高中 |
| `politics` | 道德与法治 / 思想政治 | 义务 + 高中 |
| `science` | 科学 | 仅义务 |
| `it` | 信息科技 / 信息技术 | 义务 + 高中 |
| `art` | 艺术 | 义务 + 高中 |
| `music` | 音乐 | 仅高中 |
| `fine_arts` | 美术 | 仅高中 |
| `pe` | 体育与健康 | 义务 + 高中 |
| `general_technology` | 通用技术 | 仅高中 |
| `russian` | 俄语 | 义务 + 高中 |
| `japanese` | 日语 | 义务 + 高中 |
| `german` | 德语 | 仅高中 |
| `french` | 法语 | 仅高中 |
| `spanish` | 西班牙语 | 仅高中 |
| `labor` | 劳动 | 仅义务 |
| `curriculum_framework` | 课程方案 | 义务 + 高中 |

### gold JSON 文件名

```
gold/{level}/{subject}.json
gold/compulsory/math.json        ← 义务教育数学
gold/senior/math.json            ← 高中数学
```

### 预生成文件名

```
prebuilt/plans/{subject}_{grade_band}.json
prebuilt/cards/{subject}_{grade_band}.json

prebuilt/plans/math_g1-2.json    ← 数学 1-2 年级学习计划
prebuilt/cards/math_g1-2.json    ← 数学 1-2 年级学习卡片
prebuilt/plans/math_senior.json  ← 高中数学学习计划
```

### grade_band 规范

| 代码 | 含义 |
|:----|:------|
| `g1-2` | 小学 1-2 年级（义务第一学段） |
| `g3-4` | 小学 3-4 年级（义务第二学段） |
| `g5-6` | 小学 5-6 年级（义务第三学段） |
| `g7-9` | 初中 7-9 年级（义务第四学段） |
| `senior` | 高中 |

---

## gold JSON 格式（V2）

```json
{
  "subject": "数学",
  "level": "compulsory",
  "version": "义务教育课程标准（2022年版）",
  "source_file": "义务教育数学课程标准（2022年版）.md",
  "source_hash": "sha256:xxxx",
  "extracted_at": "2026-05-25T00:00:00",
  
  "sections": {
    "curriculum_content": {
      "raw_text": "（清洗后的原文整块）",
      "concepts": [
        {"id": "m_001", "text": "理解集合含义", "module": "集合", "grade": "g1-2"}
      ]
    },
    "academic_quality": {
      "raw_text": "（学业质量原文）"
    }
  },
  
  "appendix": {
    "vocabulary": [
      {"word": "apple", "meaning": "苹果", "level": "一级"}
    ],
    "recitation": [],
    "references": []
  }
}
```

## 预生成格式

### plans.json

```json
{
  "plans": [{
    "id": "math_compulsory",
    "subject": "数学",
    "grade_band": "g1-2",
    "goal": "小学 1-2 年级数学",
    "stages": [
      {"name": "数与运算", "tasks": [{"name": "概念1", "gold_cr_ids": ["m_001"]}]}
    ]
  }]
}
```

### cards.json

```json
{
  "cards": [{
    "id": "math_g1-2_000",
    "subject": "数学",
    "grade_band": "g1-2",
    "front": "集合",
    "back": "集合是由确定的、互不相同的元素构成的整体。用大写字母表示。",
    "card_type": "concept"
  }]
}
```

---

## 版本说明

| 文件类型 | 版本源 | 更新频率 |
|:--------|:-------|:--------|
| `raw/` | 课标 10 年修订一次 | 几乎不更新 |
| `gold/` | V2 管线生成 | 管线每次运行重生成 |
| `prebuilt/` | V2 管线生成 | 管线每次运行重生成 |

- raw/ 下的 MD/PDF 是**只读的**，管线脚本只能读不能写
- gold/ 和 prebuilt/ 是管线产物，每次重跑覆盖
