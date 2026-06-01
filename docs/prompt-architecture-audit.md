# Prompt 架构审计报告

审计时间：2026-06-01 | 总计：40 个 prompt 文件

## 一、当前分布

```
backend/prompts/                    ← 根目录（通用 fallback，12 个）
  ├─ chat_system.md                 ← ❌ 死代码，未引用
  ├─ chat_system_free.md            ✅
  ├─ chat_system_structured.md      ✅
  ├─ chat_system_reading.md         ✅
  ├─ chat_system_reading_nursery.md ✅
  ├─ chat_system_reading_primary.md ✅
  ├─ chat_system_reading_secondary.md ✅
  ├─ concept_extract.md             ✅
  ├─ card_direct.md                 ✅
  ├─ quiz_generate.md               ✅
  ├─ quiz_judge.md                  ✅
  └─ grill_assessment.md            ← ❌ 死代码，未引用

backend/pipelines/{domain}/prompts/  ← 领域覆盖（4 领域 × 7 文件 = 28 个）
  ├─ biology/  ← ⚠️ 与 chemistry 完全一致
  ├─ chemistry/ ← ⚠️ 与 biology 完全一致
  ├─ language/ ← 独立定制版
  └─ math/     ← 独立定制版
```

## 二、Struct 中的死字段

`PromptTemplates` 中有 2 个字段从没有被任何代码引用（`get_for_domain()` 加载后从未读取）：

| 字段 | 状态 | 对应文件 |
|------|------|---------|
| `chat_system` | ❌ 加载但不使用 | `prompts/chat_system.md` |
| `chat_system_nursery` | ❌ 加载但不使用 | 不存在对应 .md 文件 |

## 三、Pipeline 重复

| prompt 文件 | root | bio | chem | lang | math |
|------------|------|-----|------|------|------|
| card_direct.md | 251B | 251B | 251B | 254B | 264B |
| chat_system.md | 1693B | **1865B** | **1865B** | 950B | 968B |
| chat_system_free.md | 4365B | **4917B** | **4917B** | 1177B | 1148B |
| chat_system_structured.md | 4372B | **2502B** | **2502B** | 972B | 810B |
| concept_extract.md | 2059B | 1300B | 1288B | 802B | 1209B |
| quiz_generate.md | 219B | 219B | 219B | 247B | 285B |
| quiz_judge.md | 275B | 275B | 275B | 212B | 228B |

biology 和 chemistry 的文件大小完全一致（内容也相同），可以合并。

## 四、清理建议

### 立即可删（4 个文件）

| 文件 | 理由 |
|------|------|
| `prompts/chat_system.md` | 结构体字段加载但不使用，也没有任何代码引用 |
| `prompts/grill_assessment.md` | 未在 PromptTemplates 中注册，代码零引用 |
| `pipelines/biology/prompts/*`(7个) | 与 chemistry 完全一致，可复用 chemistry 的或删除让 fallback 到 root |
| `pipelines/chemistry/prompts/*`(7个) | 同上 |

### 需决策后清理（2 个 struct 字段）

| 字段 | 建议 |
|------|------|
| `chat_system` | 直接删除 struct 字段 + 加载代码 |
| `chat_system_nursery` | 直接删除 struct 字段 + 加载代码 |

### 保留（27 个）

| 文件 | 原因 |
|------|------|
| root 中除 chat_system.md 和 grill_assessment.md 外的 10 个 | 通用 fallback |
| language/ 下 7 个 | 独立定制 |
| math/ 下 7 个 | 独立定制 |
| root 下 3 个 reading 变体 | 学段隔离 |

## 五、清理后架构

```
backend/prompts/                    ← 通用 fallback（10 个）
  ├─ chat_system_free.md           自由对话
  ├─ chat_system_structured.md     结构化学习
  ├─ chat_system_reading.md        阅读（通用 fallback）
  ├─ chat_system_reading_nursery.md 幼儿阅读
  ├─ chat_system_reading_primary.md 小学阅读
  ├─ chat_system_reading_secondary.md 初中阅读
  ├─ concept_extract.md            概念提取
  ├─ card_direct.md                直接制卡
  ├─ quiz_generate.md              出题
  └─ quiz_judge.md                 判题

backend/pipelines/                  ← 领域定制（仅定制领域保留）
  ├─ language/prompts/  (7 个)      语言领域
  └─ math/prompts/      (7 个)      数学领域
```

文件数从 **40 → 24**（-16）。其余领域（biology, chemistry）不保留 pipeline 目录，自然 fallback 到 root。
