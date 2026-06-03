# CoEvo 全链路审计待办清单

> 2026-06-02 | 基于全天调研发现的待修复/待决策事项

---

## P0 — 影响核心功能

### 1. CP1 在自由对话中被跳过
- **问题**: `ws.rs:453` 用 `!extract_domain.is_empty()` 判断是否运行 CP1
- **根因**: CP2 创建的 `conversation_plans.plan_content` JSON 中没有 `domain`/`pipeline_domain` 字段，`build_plan_context` 返回 `""`，CP1 被跳过
- **修法**: 改为直接查 `conversation_plans` 是否存在，CP1 的 domain 从 `conversations.subject` 或 plan_content 的 domain 字段取
- **文件**: `ws.rs ~L453`, `plan_handler.rs ~L1070`
- **优先级**: 高——自由对话用户永远收不到 CP1 卡片

### 2. 科目路由未接入
- **问题**: `get_plan("general")`, `get_quiz("general")`, `get_verify("general")`, `get_routing()` 都硬编码了 `"general"`
- **影响**: 即使 `chat/math/free.md` 被定制了，但 plan/concept/quiz/verify 仍用 general
- **修法**: 从 `build_plan_context` 或 `conversations.subject` 获取 domain 传入
- **文件**: 多处

---

## P1 — 数据不一致

### 3. `cards.plan_task_id` 虚悬列（已解决）
- **DDL 有此列，`expired_plan_tasks` 表已删除。reading 模式代码仍在写入空字符串 `''`。
- ✅ 已修：从生产 DDL 移除 `plan_task_id`，reading 代码改写 `plan_type + plan_id`
- **文件**: `main.rs` cards DDL, `routes.rs` reading INSERT

### 4. 测试 SCHEMA_SQL 与生产 DDL 不同步（已解决）
- 缺 `status CHECK`、`ON DELETE CASCADE`、部分列 NOT NULL
- ✅ 全面对齐：NOT NULL、CHECK、FK ON DELETE、INDEXES、列默认值、conversations 列
- ✅ 同时修复了生产 `conversation_plans.domain CHECK` 导致的潜在 INSERT 静默失败 bug
- **文件**: `main.rs` SCHEMA_SQL, `e2e_main_lifecycle.rs` SCHEMA_SQL

### 5. `user_plan_progress.plan_type` 值不一致
- CP2 创建时写 `"conversation"`，K12 写 `"k12"`
- 暂不处理（无用户数据风险）

---

## P2 — Prompt 体系优化（接 `route_subject` 后）

### 6. `route_subject()` 函数存在但无人调用
- 完整实现：LLM 路由 + 关键词降级 + JSON 解析
- 计划：自由对话第一轮消息后调用，结果存入 `conversations.subject`
- 文件: `subject_router.rs`

### 7. `build_plan_creation_prompt` 路径修复（已完成）
- ✅ `prompts/general/plan-creation.md` → `prompts/plan/general/creation.md`
- ✅ 硬编码 fallback 已备份为 `creation.md.bak`

### 8. 各 prompt 文件实际使用状态（2026-06-03 清理后）

#### chat/ 目录最终结构

| 科目 | 文件 | 模式 | 说明 |
|------|------|------|------|
| **general** | `free.md`, `structured.md` | 双重 | 通用兜底，自由对话无计划→free，有计划→structured |
| **12 非语言 K12** (art, bio, chem, geo, hist, it, labor, math, pe, phys, pol, sci) | `structured.md` | 纯 structured | K12 入口直建计划，永不触发 free 模式 |
| **chinese** | `reading-nursery.md`, `reading-primary.md`, `reading-secondary.md` | 纯 reading | 语文专用，无 free/structured |
| **english** | `free.md`, `structured.md`, 3× reading | 混合（待改造） | 当前走 structured mode，待切 reading |
| **japanese** | 同上 | 混合（待改造） | 同 english |
| **russian** | 同上 | 混合（待改造） | 同 english |

#### 其他 prompt

| prompt | 状态 | 说明 |
|--------|------|------|
| concept/general/extract.md | ✅ 使用中 | CP1 概念提取（不分科，原理上不需要分科） |
| concept/general/direct.md | ✅ 使用中 | CP1 直接制卡 |
| plan/general/signal.md | ✅ 使用中 | CP2 信号检测 |
| plan/general/analysis.md | ✅ 使用中 | CP2 任务分析 |
| plan/general/creation.md | ✅ 已修复路径 | 之前无人用（路径错误），现在正确加载 |
| quiz/general/* | ⏸ 未上线 | quiz 功能未上线 |
| routing/general/subject.md | ⏸ 无人调用 | route_subject() 存在但未接入 |
| test/general/student.md | ✅ 使用中 | e2e 测试学生模拟 |
| verify/general/translation.md | ✅ 使用中 | 复习验证 |

#### 已删除的冗余文件
- `concept/` 下 16 个非 general 科目目录（CP1 原理上不需要分科）
- `chat/general/reading*.md`（移出到语言学科目录）
- `chat/chinese/free.md`, `chat/chinese/structured.md`（chinese 只有 reading 模式）
- `chat/` 下 12 个非语言 K12 科目的 `free.md`（K12 入口永不触发）
- 4 个语言学科的 `reading.md`（分化前旧文件，fallback 永不命中）

### 9. prompt 分层优化策略

```
每个 prompt = 角色定义（通用） + 行为规范（通用） + 科目知识（专属） + 变量注入

chat/math structured.md 示例:
  - 角色: "你是一个AI学习助手" → 通用
  - 行为: "用中文回复"、"不要输出XML" → 通用
  - 领域: "涉及数学公式时，使用 LaTeX: \( \) 和 \[ \]" → math 特有
  - 变量: {history}, {plan_context} → 代码注入
```

当前各科目 `structured.md` 内容都与 `general/` 相同，后续按需差异化即可。

---

## 已完成的今日工作

| 事项 | 状态 |
|------|------|
| `cards` 加 `plan_type TEXT, plan_id TEXT` | ✅ |
| K12/reading/CP1 卡片 INSERT 统一补全 | ✅ |
| CP1 卡片补 `conversation_id` | ✅ |
| learning_plans 从生产代码完全清除 | ✅ |
| `creation.md` 路径修复 + 硬编码备份 | ✅ |
| e2e 全流程测试通过 | ✅ |
| DB 结构分析报告更新 | ✅ |
| 内存清理（移除 LinguaFlow 引用） | ✅ |
| concept/ 下 16 个科目目录删除 | ✅ 06-03 |
| chat/ 目录 prompt 文件归位清理 | ✅ 06-03 |
| 12 非语言 K12 科目删 free.md、补 structured.md | ✅ 06-03 |
| chinese 纯 reading 化 | ✅ 06-03 |
| english/japanese/russian 补全 reading 文件 | ✅ 06-03 |
| learning_plans 全库清除（DDL + 迁移 + 代码 + 测试） | ✅ 06-03 |
| plan_handler.rs 去 legacy 双写 + fallback | ✅ 06-03 |
| cards.plan_task_id 虚悬列移除 | ✅ 06-03 |
| 测试 SCHEMA_SQL 全面对齐生产 DDL | ✅ 06-03 |
| conversation_plans.domain CHECK bug 修复 | ✅ 06-03 |
| 测试 helper 去 learning_plans 兜底 | ✅ 06-03 |
| e2e 测试 Phase 1 精简 + 复跑通过 | ✅ 06-03 |
| audit 待办文档同步 | ✅ 06-03 |
