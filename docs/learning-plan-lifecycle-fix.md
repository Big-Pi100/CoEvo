# 学习计划生命周期 × Context 组装 — 修复方案

> 日期：2026-05-14
> 问题：系统提示词缺少生命周期管理，导致学习计划状态管理异常

---

## 一、问题根因

| # | 位置 | 问题 |
|:--|:--|:--|
| 1 | `prompt_loader.rs:9` | `PromptTemplates` 只有单一 `chat_system` 字段 |
| 2 | `ws.rs:157` | 每次对话加载同一份 prompt，永不变化 |
| 3 | `chat_system.md` | 创建计划+更新计划+考核+自由对话全部混在一份 prompt |
| 4 | `llm_caller.rs:184` | LLM 调用只用单条 `user` 消息，无 `system` role 分离 |

---

## 二、约束

- **一个对话 = 一个学习计划**，不支持覆盖
- STRUCTURED 状态下用户想学新东西 → 建议开启新对话
- COMPLETED 是 terminal 状态 → 建议开启新对话

---

## 三、状态机

```
FREE ──(创建计划)──→ STRUCTURED ──(全部完成)──→ COMPLETED (terminal)
  ↑                                                    │
  └──── 开启新对话 ←────────────────────────────────────┘
```

---

## 四、需要修改的文件

### 4.1 新建：`prompts/chat_system_free.md`

FREE 状态专用提示词。内容：
- 角色定义（AI 学习助手）
- 对话风格
- 数学公式规范
- 计划创建引导 + 首次创建 JSON Schema（仅 `is_new_plan=true` 格式）
- 不含：考核机制、进度更新 Schema

### 4.2 新建：`prompts/chat_system_structured.md`

STRUCTURED/COMPLETED 状态专用提示词。内容：
- 角色定义（AI 学习导师，结构化模式）
- 对话风格 + 数学公式规范
- 计划遵循指令（按阶段任务教学）
- 一个对话一个计划的约束规则
- 考核机制（grill）
- 进度更新 JSON Schema（无 `is_new_plan`）
- 计划完成处理

### 4.3 修改：`prompt_loader.rs`

```rust
pub struct PromptTemplates {
    pub chat_system_free: String,        // 新增
    pub chat_system_structured: String,  // 新增
    // 保留 chat_system 作为回退（可选）
    pub chat_system: String,
    pub concept_extract: String,
    pub card_direct: String,
    pub quiz_generate: String,
    pub quiz_judge: String,
}
```

### 4.4 修改：`ws.rs`

核心变更点：

```rust
// 当前（line 157）：
let mut prompt = chat_engine::prompt_loader::get().chat_system.clone();

// 改为：先查 DB 判定状态，再选 prompt
let templates = chat_engine::prompt_loader::get();
let (system_prompt, plan_context) = determine_prompt_and_context(
    &chat_req.conversation_id, templates
);
let user_content = build_user_content(history, &chat_req.message, plan_context);
```

需要新增辅助函数：
- `determine_prompt_and_context()` — 查 DB → 返回 (system_prompt_str, plan_context_str)
- `build_user_content()` — 组装对话历史 + 计划上下文 + 当前消息

### 4.5 修改：`llm_caller.rs`

```rust
// 当前（line 184）：
"messages": [{"role": "user", "content": prompt}],

// 改为：
"messages": [
    {"role": "system", "content": system_prompt},
    {"role": "user", "content": user_content}
]
```

`stream_generate()` 签名变为接受两个参数：
```rust
pub async fn stream_generate(
    &mut self,
    system_prompt: &str,
    user_content: &str,
    tx: mpsc::Sender<LlmEvent>,
) -> Result<(), LlmError>
```

同时更新非流式 `generate()` 方法保持一致。

### 4.6 修改：`routes.rs`（line 178）

REST `/api/chat` 端点也使用相同的 prompt 选择逻辑，需要同步修改。

---

## 五、Context 组装公式（修复后）

```
每轮对话开始：
  1. SELECT mode, goal, plan_json FROM learning_plans
     WHERE conversation_id = ? AND mode = 'structured'
     ORDER BY updated_at DESC LIMIT 1

  2. 有结果？→ STRUCTURED 状态
     ├── system_prompt = chat_system_structured.md
     └── plan_context = 格式化 plan_json（当前阶段+任务）

  3. 无结果？→ FREE 状态
     ├── system_prompt = chat_system_free.md
     └── plan_context = None

  4. user_content = 对话历史 + plan_context + 当前用户消息

  5. LLM API 调用：
     messages: [
       {"role": "system", "content": system_prompt},
       {"role": "user", "content": user_content}
     ]
```

---

## 六、验证清单

| # | 场景 | 预期 |
|:--|:--|:--|
| 1 | 新对话自由聊天 | FREE prompt，无计划注入 |
| 2 | 用户表达学习目标 | FREE prompt，LLM 询问制定计划 |
| 3 | 用户确认后 LLM 输出计划 | FREE prompt，`is_new_plan=true`，DB INSERT |
| 4 | 下一轮对话 | STRUCTURED prompt，计划上下文已注入 |
| 5 | 计划进行中多轮教学 | STRUCTURED prompt，不重复提议创建计划 |
| 6 | 计划中用户想学新东西 | STRUCTURED prompt，LLM 建议新对话 |
| 7 | 考核 + 进度更新 | STRUCTURED prompt，LLM 输出进度 `<plan_update>` |
| 8 | 全部完成 | STRUCTURED prompt，LLM 祝贺 + 建议新对话 |
