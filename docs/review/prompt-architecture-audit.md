# Prompt 架构重整方案

## 一、全系统 Prompt 分类

全系统所有 LLM 调用中的 prompt 按**功能类别**划分，而非按科目划分。每类下再按科目细分。

| 类别 | 用途 | 使用方 | 当前状态 |
|------|------|--------|---------|
| **chat** | 教师对话（自由/结构化/阅读模式） | ws.rs | ✅ 已文件化 |
| **concept** | CP1 概念提取 | concept_extractor.rs | ✅ 已文件化 |
| **plan** | CP2 计划管理（创建/分析/信号检测） | plan_handler.rs | ✅ 已文件化 |
| **quiz** | 出题/判题/考核评估 | ws.rs, routes.rs | ✅ 已文件化 |
| **verify** | 复习验证（翻译校验） | routes.rs | ✅ 已文件化 |
| **routing** | 学科路由 | subject_router.rs | ✅ 已文件化 |
| **test** | e2e 测试学生模拟 | e2e 测试文件 | ✅ 已文件化 |

## 二、目录结构（类别 × 科目）

```
backend/prompts/                    ← 唯一 prompt 存放位置
│
├── chat/                           ← 教师对话类
│   ├── general/                    ← 通用兜底
│   │   ├── free.md                 (原 chat-free)
│   │   ├── structured.md           (原 chat-structured)
│   │   ├── reading.md              (原 chat-reading)
│   │   ├── reading-nursery.md
│   │   ├── reading-primary.md
│   │   └── reading-secondary.md
│   │
│   ├── math/                       ← 数学（含 LaTeX + <graph>）
│   │   ├── free.md
│   │   └── structured.md
│   │
│   ├── chinese/                    ← 语文（含阅读变体）
│   │   ├── free.md
│   │   ├── structured.md
│   │   ├── reading.md
│   │   ├── reading-primary.md
│   │   └── reading-secondary.md
│   │
│   ├── english/                    ← 英语
│   │   ├── free.md
│   │   ├── structured.md
│   │   ├── reading.md
│   │   ├── reading-primary.md
│   │   └── reading-secondary.md
│   │
│   └── ...                         ← 其他科目按需（不存在则 fallback general/）
│
├── concept/                        ← CP1 概念提取类
│   ├── general/
│   │   ├── extract.md              (原 concept-extract)
│   │   └── direct.md               (原 card-direct)
│   └── math/                       ← 数学专用提取 prompt（可选）
│       └── extract.md
│
├── quiz/                           ← 考核类
│   ├── general/
│   │   ├── generate.md
│   │   ├── judge.md
│   │   └── grill.md
│   └── ...                         ← 科目目录按需
│
├── plan/                           ← CP2 计划管理类
│   └── general/
│       ├── creation.md             (从 build_plan_creation_prompt 提取)
│       ├── analysis.md             (从 build_plan_analysis_prompt 提取)
│       └── signal.md               (任务完成信号检测)
│
├── verify/                         ← 复习验证类
│   └── general/
│       ├── spelling.md             (拼写验证)
│       ├── dialogue.md             (对话验证)
│       └── translation.md          (翻译校验)
│
├── routing/                        ← 学科路由类
│   └── general/
│       └── subject.md              (从 build_routing_prompt 提取)
│
└── test/                           ← 测试模拟类
    └── general/
        └── student.md              (e2e 学生扮演)
```

**核心规则**：
1. 按类别建目录，每个类别下有 `general/` 兜底
2. 各类别下按科目建子目录（`math/`、`chinese/` 等），科目级 prompt 不存在时 fallback 到该类别下的 `general/`
3. 所有 prompt 文件采用 `kebab-case` 命名，不加 `chat_system_` 前缀
4. 支持逐层 fallback：`prompts/chat/math/free.md` → `prompts/chat/general/free.md`

## 三、Rust 加载架构

### 3.1 数据结构

```rust
// 每个类别独立的结构体
pub struct ChatTemplates {
    pub free: String,
    pub structured: String,
    pub reading: String,
    pub reading_nursery: String,
    pub reading_primary: String,
    pub reading_secondary: String,
}

pub struct ConceptTemplates {
    pub extract: String,
    pub direct: String,
}

pub struct PlanTemplates {
    pub creation: String,
    pub analysis: String,
    pub signal: String,
}

pub struct QuizTemplates {
    pub generate: String,
    pub judge: String,
    pub grill: String,
}

pub struct VerifyTemplates {
    pub spelling: String,
    pub dialogue: String,
    pub translation: String,
}

pub struct RoutingTemplates {
    pub subject: String,
}
```

### 3.2 注册表

```rust
pub struct PromptRegistry {
    // 每个类别一个 map: subject_key → Templates
    chat: HashMap<String, ChatTemplates>,
    concept: HashMap<String, ConceptTemplates>,
    plan: HashMap<String, PlanTemplates>,
    quiz: HashMap<String, QuizTemplates>,
    verify: HashMap<String, VerifyTemplates>,
    routing: HashMap<String, RoutingTemplates>,
    // 各类别通用兜底
    chat_general: ChatTemplates,
    concept_general: ConceptTemplates,
    plan_general: PlanTemplates,
    quiz_general: QuizTemplates,
    verify_general: VerifyTemplates,
    routing_general: RoutingTemplates,
}
```

### 3.3 查询 API

```rust
// 按类别 + 科目获取 prompt
pub fn get_chat(subject: &str) -> &ChatTemplates;
pub fn get_concept(subject: &str) -> &ConceptTemplates;
pub fn get_plan(subject: &str) -> &PlanTemplates;
pub fn get_quiz(subject: &str) -> &QuizTemplates;
pub fn get_verify(subject: &str) -> &VerifyTemplates;
pub fn get_routing() -> &RoutingTemplates;
```

### 3.4 初始化

启动时扫描 `prompts/{category}/` 下所有子目录，按类别 + 科目注册：

```rust
pub fn init(base_dir: &str) {
    for category in &["chat", "concept", "quiz", "plan", "verify", "routing", "test"] {
        let general_dir = format!("{}/{}/general", base_dir, category);
        let general_tpl = load_{category}_dir(&general_dir);
        
        let mut pipelines = HashMap::new();
        if let Ok(entries) = std::fs::read_dir(format!("{}/{}", base_dir, category)) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_dir() { continue; }
                let name = path.file_name()...;
                if name == "general" { continue; }
                let tpl = load_{category}_dir_with_fallback(&path, &general_tpl);
                pipelines.insert(name, tpl);
            }
        }
        
        registry.{category} = pipelines;
        registry.{category}_general = general_tpl;
    }
}
```

## 四、调用方变更

| 类别 | 调用方 | 改前 | 改后 |
|------|--------|------|------|
| chat | ws.rs | `get_for_domain(domain).chat_system_free` | `get_chat(&domain).free` |
| concept | concept_extractor.rs | `get_for_domain(domain).concept_extract` | `get_concept(&domain).extract` |
| concept | concept_extractor.rs | `get().card_direct` | `get_concept("general").direct` |
| plan | plan_handler.rs | `build_plan_analysis_prompt()` | `get_plan("general").analysis` |
| plan | plan_handler.rs | `build_plan_creation_prompt()` | `get_plan("general").creation` |
| quiz | ws.rs / routes.rs | `get_for_domain(domain).quiz_generate` | `get_quiz(&domain).generate` |
| verify | routes.rs | 硬编码字符串 | `get_verify("general").spelling` |
| routing | subject_router.rs | 硬编码字符串 | `get_routing().subject` |

## 五、实施步骤

### Step 1：重构目录结构

```bash
# 删除旧结构
rm -rf backend/prompts/{math,physics,chemistry,biology,chinese,english,...}

# 创建新结构
mkdir -p backend/prompts/{chat,concept,quiz,plan,verify,routing,test}/general
mkdir -p backend/prompts/chat/{math,chinese,english}
mkdir -p backend/prompts/concept/math
```

### Step 2：复制迁移文件

```bash
# chat/general/ ← 从旧 prompts/general/ 来
cp old_general/chat-free.md           prompts/chat/general/free.md
cp old_general/chat-structured.md     prompts/chat/general/structured.md
cp old_general/chat-reading.md        prompts/chat/general/reading.md
cp old_general/chat-reading-*.md      prompts/chat/general/
cp old_general/concept-extract.md     prompts/concept/general/extract.md
cp old_general/card-direct.md         prompts/concept/general/direct.md
cp old_general/quiz-generate.md       prompts/quiz/general/generate.md
cp old_general/quiz-judge.md          prompts/quiz/general/judge.md
cp old_general/grill-assessment.md    prompts/quiz/general/grill.md
cp old_general/plan-creation.md       prompts/plan/general/creation.md
```

### Step 3：重构 `prompt_loader.rs`

拆分 `PromptTemplates` 为多个类别结构体，不再共用。

### Step 4：提取硬编码 prompt

- `plan_handler.rs:1392` → `prompts/plan/general/analysis.md`
- `plan_handler.rs:1752` → `prompts/plan/general/signal.md`
- `subject_router.rs:220` → `prompts/routing/general/subject.md`
- `routes.rs:519,575,631` → `prompts/verify/general/{spelling,dialogue,translation}.md`
- 测试文件 → `prompts/test/general/student.md`

### Step 5：更新调用方

所有 `get_for_domain(domain).xxx` 改为 `get_xxx(&domain).yyy`。

### Step 6：全量测试

## 六、文件变化总结

| | 改前 | 改后 |
|---|------|------|
| 组织结构 | 科目平铺（`prompts/{subject}/`） | 类别 × 科目（`prompts/{category}/{subject}/`） |
| Rust 数据结构 | 单一 `PromptTemplates` 大集合 | 每类独立 `*Templates` 结构体 |
| 查询 API | `get_for_domain(domain).field` | `get_chat(domain).free` / `get_concept(domain).extract` |
| 硬编码 | 5+ 处 Rust 字符串 | 全部提取为文件 |

---

## 七、实施完成状态（2026-06-01）

**全部实施完成。** 最终目录结构：

```
prompts/
├── chat/       ← 31 文件（16 科目 × chat prompt，含阅读变体）
├── concept/    ← 21 文件（16 科目 × 概念提取）
├── quiz/       ← 9 文件（考核出题/判题，含 math/chinese/english 科目版）
├── plan/       ← 3 文件（creation.md + analysis.md + signal.md，step3-4 提取）
├── verify/     ← 1 文件（translation.md，step4 提取）
├── routing/    ← 1 文件（subject.md，step4 提取）
└── test/       ← 1 文件（student.md，step4 提取）
```

所有硬编码 LLM prompt 已提取为独立文件。`prompt_loader.rs` 完全重写为按类别 × 科目双层路由。
旧 `pipelines/` 目录和 `prompts/` 根目录下的零散文件已删除。
