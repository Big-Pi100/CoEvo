# 管线式架构 · 设计文档

> 日期：2026-05-21 · V2（确定首批三条管线：math / language / general）
> 动机：消除 prompt 膨胀，为每个学习场景建立独立管线
> 状态：V2 · 实施前定稿

---

## 一、问题陈述：一个 prompt 打不了天下

### 1.1 prompt 膨胀

当前 `concept_extract.md` 一个文件处理所有场景：

```
concept_extract.md
  ├── 数学/物理 → 核心公式 + LaTeX + 符号解释
  ├── 其他领域 → 定义 + 关键要素 + 应用 + 关联
  ├── 英语词汇 → 词库匹配 + 释义生成（代码硬编码）
  └── 要加 grammar? → 时态结构 + 用法说明 + 例外（计划中）
```

一个 prompt 里塞不同场景的卡片结构，导致：
- LLM 容易混淆分支条件
- 改一处要理解所有分支
- 加新场景必须侵入已有文件

### 1.2 教学节奏不同

结构化学习的"讲解→举例→小测"三阶段制并不适合所有场景：

| 场景 | 理想的教学节奏 | 当前支持 |
|------|--------------|:--------:|
| 数学/物理 | 讲解→推导→练习 | ✅ 勉强可用 |
| 语言学习 | 展示→发音→拼写→造句 | ❌ |
| 编程 | 概念→演示→练手→debug | ❌ |
| 历史/地理 | 背景→事件→因果→影响 | ❌ |

### 1.3 验证方式不同

| 场景 | 卡片的验证方式 | 路由依据 |
|------|--------------|---------|
| 通用概念 | AI 快问快答 | fallback |
| 英语词汇 | 拼写打字 / 听写 | `domain = "vocabulary"` |
| 英语语法 | 填空 / 改错 / 时态判断 | `domain = "grammar"` |
| 数学/物理 | 公式默写 / 推导填空 | 待定（Phase 3） |

---

## 二、架构设计

### 2.1 核心概念：管线（Pipeline）

一条管线 = 一个场景的 **prompt 集合 + 卡片 schema + 验证策略** 的完整封装。

```
pipeline/
  ├── prompts/          ← 该场景的 prompt 文件
  │   ├── chat_system.md               （可选，不提供则回退通用）
  │   ├── chat_system_free.md           （可选）
  │   ├── chat_system_structured.md     （可选）
  │   ├── concept_extract.md            （可选）
  │   ├── card_direct.md                （可选）
  │   ├── quiz_generate.md              （可选）
  │   └── quiz_judge.md                 （可选）
  ├── config.json       ← 场景元数据
  └── (可选) src/       ← 自定义验证策略等
```

**关键设计**：管线目录里的文件不要求全。找不到的文件自动回退到通用管线。这意味着：
- 管线作者只需覆盖要差异化的 prompt
- 新增管线 = 建目录 + 写要改的文件
- 现有通用 prompt 不需要改

### 2.2 首批三条管线

```
backend/
  ├── prompts/              ← 通用管线（兜底）
  │   ├── chat_system.md
  │   ├── chat_system_free.md
  │   ├── chat_system_structured.md
  │   ├── concept_extract.md         ← 清理分支后的纯通用版
  │   ├── card_direct.md
  │   ├── quiz_generate.md
  │   └── quiz_judge.md
  │
  └── pipelines/
      ├── math/            ← 数学/物理管线
      │   └── prompts/
      │       └── concept_extract.md  ← 公式结构 + LaTeX 分支（从通用中提取）
      │
      └── language/        ← 语言学习管线
          └── prompts/
              ├── concept_extract.md  ← 英语词汇+语法提取（Phase 2 完善）
              └── chat_system_structured.md ← 四阶段教学（Phase 2 完善）
```

```
app/
  └── lib/
      ├── pipelines/
      │   ├── verification_strategy.dart  ← 策略接口
      │   ├── pipeline_registry.dart      ← 注册表
      │   ├── general/                    ← 通用策略实现
      │   │   └── verification_strategy.dart
      │   └── language/                   ← 语言管线策略
      │       └── verification_strategy.dart  ← 拼写/听写（Phase 2 实现）
      │
      └── screens/
          └── review_screen.dart          ← 按管线路由验证组件
```

### 2.3 管线注册表

```rust
// backend/src/pipeline_router.rs (新增)

pub struct PipelineConfig {
    pub domain: &'static str,         // "math" / "language" / "general"
    pub display_name: &'static str,   // "数学学习" / "语言学习"
    pub prompts_path: &'static str,   // 相对于项目根
    pub available_verifications: &'static [&'static str],
}

pub fn resolve_pipeline(domain: &str) -> PipelineConfig {
    match domain {
        "math" => PipelineConfig {
            domain: "math",
            display_name: "数学/物理学习",
            prompts_path: "pipelines/math/prompts/",
            available_verifications: &["ai_dialogue"],
        },
        "language" | "english" | "chinese" => PipelineConfig {
            domain: "language",
            display_name: "语言学习",
            prompts_path: "pipelines/language/prompts/",
            available_verifications: &["spelling", "ai_dialogue"],
        },
        _ => PipelineConfig {  // 通用兜底
            domain: "general",
            display_name: "通用学习",
            prompts_path: "prompts/",
            available_verifications: &["ai_dialogue"],
        },
    }
}
```

```dart
// app/lib/pipelines/pipeline_registry.dart (新增)

enum PipelineDomain { general, math, language }

PipelineDomain resolveDomain(String? domain) {
  switch (domain) {
    case 'math': return PipelineDomain.math;
    case 'language': return PipelineDomain.language;
    default: return PipelineDomain.general;
  }
}

VerificationStrategy resolveStrategy(DueCard card) {
  switch (resolveDomain(card.domain)) {
    case PipelineDomain.language:
      return LanguageVerificationStrategy();
    default:
      return GeneralVerificationStrategy();
  }
}
```

### 2.4 Prompt 加载器

```rust
// 当前 prompt_loader.rs → 增强为支持管线

/// 为指定管线加载 prompt 模板
/// domain = "general" | "math" | "language" | ... 
pub fn init_for_pipeline(domain: &str) -> PromptTemplates {
    let base = if domain.is_empty() || domain == "general" {
        "prompts".to_string()
    } else {
        format!("pipelines/{}/prompts", domain)
    };

    PromptTemplates {
        chat_system: read_with_fallback(&format!("{}/chat_system.md", base), "prompts/chat_system.md"),
        chat_system_free: read_with_fallback(&format!("{}/chat_system_free.md", base), "prompts/chat_system_free.md"),
        chat_system_structured: read_with_fallback(&format!("{}/chat_system_structured.md", base), "prompts/chat_system_structured.md"),
        concept_extract: read_with_fallback(&format!("{}/concept_extract.md", base), "prompts/concept_extract.md"),
        card_direct: read_with_fallback(&format!("{}/card_direct.md", base), "prompts/card_direct.md"),
        quiz_generate: read_with_fallback(&format!("{}/quiz_generate.md", base), "prompts/quiz_generate.md"),
        quiz_judge: read_with_fallback(&format!("{}/quiz_judge.md", base), "prompts/quiz_judge.md"),
    }
}

/// 先读管线目录，不存在则回退到通用目录
fn read_with_fallback(pipeline_path: &str, fallback_path: &str) -> String {
    std::fs::read_to_string(pipeline_path)
        .or_else(|_| std::fs::read_to_string(fallback_path))
        .unwrap_or_default()
}
```

### 2.5 路由时机

```
用户表达学习需求
    │
    ▼
N8 学习计划创建（或检测用户意图）
    │  LLM 输出 plan_update JSON 时包含 "domain" 字段
    │  domain = "math" | "language" | null
    │
    ▼
N1 对话开始 → prompt_loader.init_for_pipeline(domain)
    │  加载对应管线的 prompt 集合
    │
    ▼
N2 概念提取 → 使用管线的 concept_extract.md
    │
    ▼
卡片入库（全局统一）
    │
    ▼
N5 复习队列（全局统一）
    │
    ▼
N6 验证 → 前端按 card.domain 路由验证策略
```

### 2.6 domain 字段的演进

```
学习计划创建时:
  LLM 输出 "domain": "math"
      ↓
  存入 learning_plans 表
      ↓
  对话 prompt 注入时:
    当前 domain = "math" → 加载 math 管线

自由对话时:
  无学习计划 → domain = null → 通用管线

已有卡片:
  cards 表的 domain 字段不受影响，验证时直接读 card.domain
```

---

## 三、实施计划

### Phase 1: 管线架构就绪（3天）

| # | 任务 | 估计 | 文件 |
|:-:|------|:----:|------|
| 1 | `prompt_loader.rs` 增强：支持按管线加载 + 回退 | 4h | `backend/crates/chat_engine/src/prompt_loader.rs` |
| 2 | 新建 `pipeline_router.rs`：注册表 + 路由函数 | 2h | `backend/crates/chat_engine/src/pipeline_router.rs` |
| 3 | 清理通用 `concept_extract.md`：移出数学分支 | 1h | `backend/prompts/concept_extract.md` |
| 4 | 新建 `pipelines/math/prompts/concept_extract.md`：数学专用 | 1h | `pipelines/math/prompts/concept_extract.md` |
| 5 | 新建 `pipelines/language/prompts/`：先初始化空目录 | 0.5h | `pipelines/language/prompts/` |
| 6 | 学习计划 N8 加入 domain 字段 | 2h | `backend/src/main.rs` + `backend/prompts/chat_system_free.md` |
| 7 | 前端 `pipeline_registry.dart`：注册表 + 策略接口 | 3h | `app/lib/pipelines/` |
| 8 | 前端 `review_screen.dart`：从硬编码分支改为策略路由 | 4h | `app/lib/screens/review_screen.dart` |
| 9 | E2E 测试适配 | 2h | `docs/evaluation/` |
| | **合计** | **~3天** | |

### Phase 2: 英语管线深化（持续迭代，见 `english-learning-review.md`）

| 阶段 | 内容 | 估计 |
|:----:|------|:----:|
| P0 | 拼写验证精确化 | 2h |
| F1-F5 | 基础能力（TTS/STT/音标/CEFR） | 1周 |
| V1-V6 | 管线功能（验证/听写/语法/仪表盘） | 2-4周 |

### Phase 3: 各管线分别深化（按需）

每条管线独立演进，模式同 Phase 2：
- 先修 bug
- 再补基础能力
- 最后深度优化

---

## 四、向后兼容

| 资产 | 兼容策略 |
|------|---------|
| 已有 prompt 文件 | 原地保留，成为通用管线 |
| 迁移 `concept_extract.md` 数学分支 | 原文件去掉数学分支，不影响其他领域 |
| 已有卡片数据 | 字段不变，`card.domain` 即路由键 |
| 已有对话历史 | 不涉及改动 |
| 已有学习计划 | 缺 `domain` 字段走通用管线 |
| 复习队列逻辑 | 不变 |
| FSRS 调度 | 不变 |
| 注册用户 | 不受影响 |

---

## 五、数学管线 Prompt 规划（Phase 1 即用）

### `pipelines/math/prompts/concept_extract.md`

从当前 `concept_extract.md` 提取出数学分支，保持原结构：

```markdown
从以下对话中提取值得记住的新知识点作为卡片。

……

### 卡片释义结构

**数学/物理概念**:
- 核心公式: \(公式\) 格式（LaTeX 行内公式）
- 公式解释: 各符号含义的一句话解释
- 含义: 这个概念是什么，解决什么问题
- 背景: 在什么情境下出现，与哪些概念相关

**原则**: 有则填写，无则留空。

每个元素必须是包含 front/back/source_sentence/domain 的 JSON 对象。
只返回 JSON 数组，不要任何其他文字。
```

### 通用 `concept_extract.md` 清理后

去除数学/物理分支，仅保留通用结构：

```markdown
从以下对话中提取值得记住的新知识点作为卡片。

……

### 卡片释义结构

- 定义: 一句话说清楚是什么
- 关键要素: 核心组成部分/特征（列表形式）
- 应用: 实际用在什么场景
- 关联: 与哪些已知概念有关

**原则**: 有则填写，无则留空。

每个元素必须是包含 front/back/source_sentence/domain 的 JSON 对象。
只返回 JSON 数组，不要任何其他文字。
```

---

## 六、语言管线规划（Phase 2 启动）

语言管线 Phase 1 只建空目录。Phase 2 正式启动时：

- `pipelines/language/prompts/concept_extract.md` — 英语词汇 + 语法双通道提取
- `pipelines/language/prompts/chat_system_structured.md` — 四阶段教学（展示→讲解→练习→验证）
- 前端 `LanguageVerificationStrategy` — 拼写 / 听写 / 语法填空

详细方案见 `docs/english-learning-review.md`

---

## 七、与现有架构的关系

```
当前:
  prompt_loader.init("prompts/")    → 所有对话共享 7 个 prompt 文件
  review_screen card_type 分支      → 硬编码 if/else 的验证逻辑

增强后:
  prompt_loader.init_for_pipeline(domain) → 按 domain 选 prompt 目录
  pipeline_router.resolve(domain)         → 返回管线配置
  VerificationStrategy.resolve(card)      → 按 card.domain 选验证策略

共享不变:
  FSRS 调度 / 复习队列 / 卡片数据库表 / 对话流 / 用户认证 / 成就系统

管线独占:
  System prompt / 概念提取 prompt / 验证策略 / 卡片 Schema 扩展
```

---

## 八、未来扩展

新增一条管线的完整步骤：

1. **后端**：`pipelines/<name>/prompts/` 下写要覆盖的 prompt
2. **后端**：`pipeline_router.rs` 注册新 domain
3. **前端**：`app/lib/pipelines/<name>/verification_strategy.dart`（可选）
4. **前端**：`pipeline_registry.dart` 注册新策略

> 新增一条管线 = 建目录 + 写 prompt + 改两处注册。

---

*文档状态：V2 · 实施前定稿*
*首批三条管线：math / language / general*
