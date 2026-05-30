# 卡片复习三管线完整流程

## 管线 1：概念卡（ColdPath 1 生成）

### 数据来源
```
WS 对话 → 后台 tokio::spawn → extract_concepts() → LLM 提取 → candidates
→ ws.send 通知前端 → 概念确认弹窗 → POST /api/cards/batch-create
```

### 卡片特征
| 字段 | 示例 |
|:----|:-----|
| card_type | `concept` |
| front | "勾股定理" |
| back | "直角三角形两直角边平方和等于斜边平方" |
| domain | "math" |
| source_sentence | 对话中提取的来源句子 |

### 触发时机
每轮 WS 对话后，ColdPath 1 后台异步提取。用户在前端看到弹窗确认后写入 DB。

### 复习表现
```
列表: 蓝色标签"新卡片"
翻转: front → back (概念名 → 释义)
验证: "验证一下" → LLM 出题 (AI quiz) → 用户作答 → LLM 判题 → 评分
跳过: 左滑 → 确认 → 不再推荐
TTS: 朗读概念 / 朗读释义
```

---

## 管线 2：词卡（Vocabulary Cards）

### 数据来源
```
JSON 预置: data/curriculum/prebuilt/vocab_enriched/chinese_enriched.json
├─ 766 个汉字/词语条目
└─ 每个含: 拼音、释义、笔画、组词、例句

运行时加载: curriculum_loader.get_cards() 从 chinese_compulsory.json 加载
链接字段: plan 中 task 的 vocab_card_ids → 匹配 card_tmpl.id

导入时机: unlock_next_cards (任务推进完成时)
```

### 卡片特征
| 字段 | 示例 |
|:----|:-----|
| card_type | `vocabulary` |
| front | "翩然" |
| back | "piān rán / 动作轻快的样子 / 落叶翩然起舞" |
| k12_card_id | `chinese_g7-9_v0947` |

### 触发时机
CP2 完成任务推进时 → `unlock_next_cards()` → 管道 A 代码：

```rust
// plan_handler.rs:1280
let vocab_ids = next_task.get("vocab_card_ids")  // 从当前 task 取
// 遍历 compulsory 卡片集，匹配 id → INSERT INTO cards + card_memory
```

### 复习表现
```
列表: 蓝色标签"新卡片"
翻转: front → back (字词 → 拼音+释义+组词+例句)
验证: "验证一下" → spelling 模式
      输入框: 用户输入拼音或默写
      自动比对: resolveStrategy → language/verification_strategy
      非拼写: LLM 出题 (同概念卡)
跳过: 左滑
TTS: 朗读字词 / 朗读释义
```

---

## 管线 3：课文卡（Reading Cards）

### 数据来源
```
JSON 预置: data/curriculum/prebuilt/cards/reading/chinese_reading_primary.json
├─ 775 张阅读卡片
└─ 各卡: front/back/background/appreciation/technique/theme/common_mistakes

运行时: reading_loader.init() 从 prebuilt/reading_plans 加载
链接字段: plan 中 task 的 reading_card_id → reading_loader.get_card(id)
```

### 卡片特征
| 字段 | 示例 |
|:----|:-----|
| card_type | `nursery_rhyme` (g1-2) 或 `reading` (其他年级) |
| front | 《春》全文 |
| back | 赏析 + 手法 + 主题 + 易错点 |
| appreciation | `["比喻: 太阳像红气球", "拟人: 春姑娘来了"]` |
| technique | `["比喻", "拟人", "排比"]` |

### 触发时机
任务推进时 → `unlock_next_cards()` → 管道 B：

```rust
// plan_handler.rs:1314
let reading_card_id = next_task.get("reading_card_id")
  → reading_loader::get_card(&reading_card_id)
  → INSERT INTO cards + card_memory
```

### 复习表现
```
列表: 蓝色标签"新卡片"
翻转: front → back (课文标题 → 全文/赏析/手法)
验证: "验证一下" → LLM 出题 (关于课文内容的理解题)
TTS: 朗读课文 / 朗读赏析
阅读全文: 从复习页点击 → ReadingFullTextScreen 显示完整课文
```

---

## 统一复习流程

三管线共享同一个复习界面 `review_screen.dart`：

```
                   ┌──────────────┐
                   │  TabBar 导航   │
                   │  Tab1: 按学科  │
                   │  Tab2: 全部卡片 │
                   └──────┬───────┘
                          │
                   ┌──────▼───────┐
                   │  卡片列表      │  ← Dismissible 左滑跳过
                   │  state 彩色标签 │  ← 蓝(新)/橙(学习)/绿(复习)/紫(重学)
                   │  进度蒙版      │  ← state+reps 决定覆盖比例
                   └──────┬───────┘
                          │ 点击
                   ┌──────▼───────┐
                   │  卡片翻转      │
                   │  front → back │
                   └──────┬───────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │ 我已记住   │  │ 验证一下   │  │ 左滑跳过   │
     │ (跳过验证) │  │          │  │          │
     └────┬─────┘  └────┬─────┘  └────┬─────┘
          │             │             │
          ▼             ▼             │
     ┌──────────┐  ┌──────────┐      │
     │ 评分按钮   │  │ 管线策略路由 │      │
     │ 记住/模糊/ │  │          │      │
     │ 忘记      │  │ spelling │      │
     └────┬─────┘  │ 模式 →   │      │
          │        │ 自动比对  │      │
          │        │          │      │
          │        │ AI 模式  │      │
          │        │ → LLM出题│      │
          │        │ → 作答   │      │
          │        │ → LLM判题│      │
          │        └────┬─────┘      │
          │             │            │
          └─────────────┼────────────┘
                        │
                   ┌────▼────┐
                   │ submit  │
                   │ FSRS 更新│
                   │ 成就检查 │
                   └─────────┘
```

### 前端提交的数据

```json
POST /api/review/submit
{
  "card_id": "k12_math_compulsory_0000",
  "rating": 3,              // 1=忘记 2=模糊 3=记住
  "verification_type": "spelling" | "ai_dialogue",
  "verification_result": "pass" | "fail",
  "details_json": "[{\"question\":\"一次函数表达式？\",\"correct\":true,\"feedback\":\"正确\"}]"
}
```

### getDueCards 的 SQL 查询

```sql
SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       cm.state, cm.reps, cm.lapses, cm.difficulty, cm.due
FROM cards c
JOIN card_memory cm ON cm.card_id = c.id
WHERE c.user_id = ? AND cm.due <= ?
ORDER BY cm.state ASC, cm.due ASC
LIMIT ?
```

### 进度蒙版逻辑

| state | reps | 蒙版 | 含义 |
|:-----|:----|:----|:-----|
| 0 (新卡片) | 任意 | 0% | 全彩色 |
| 1 (学习中) | 0 | 100% | 完全蒙版 |
| 1 (学习中) | ≥1 | 50% | 半蒙版 |
| 2 (复习中) | 0-2 | 100% | 完全蒙版 |
| 2 (复习中) | 3-5 | 50% | 半蒙版 |
| 2 (复习中) | ≥6 | 0% | 全彩色（掌握） |
| 3 (重学中) | 0-2 | 100% | 完全蒙版 |
| 3 (重学中) | 3-5 | 50% | 半蒙版 |
| 3 (重学中) | ≥6 | 0% | 全彩色（掌握） |

---

## 三管线对比总结

| 维度 | 概念卡 | 词卡 | 课文卡 |
|:-----|:------|:-----|:-------|
| card_type | `concept` | `vocabulary` | `nursery_rhyme` / `reading` |
| 生成方式 | LLM 实时提取 | 预置数据导入 | 预置数据导入 |
| 依赖 | ColdPath 1 WS 后台 | `vocab_card_ids` + curriculum data | `reading_card_id` + reading data |
| 激活时机 | 对话后弹窗确认 | 任务推进后自动 | 任务推进后自动 |
| 验证策略 | AI quiz (LLM 出题+判题) | spelling + AI quiz | AI quiz |
| 数据量 | 动态 | 6,779 词条 | 775 张卡片 |
| 前端特色 | 概念弹窗确认 | 拼音/默写检查 | "查看全文"入口 |
