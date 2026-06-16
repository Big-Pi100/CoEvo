# 运行参数配置 + 调试日志体系 + Prompt 架构重构 — 实施报告

> **版本**: v4.0（实施完成）  
> **日期**: 2026-06-13  
> **标签**: `cm dsg` `config` `debug-log` `prompt-split`

---

## 1. 概述

### 1.1 三件事

1. **细粒度调试日志** — 在现有运行流程的关键节点写入结构化日志，独立于运行日志存储，可按 conversation_id 查询回溯
2. **运行参数可配置** — 将硬编码参数改为 DB 配置，后台可查看和修改；prompt 模板可直接编辑
3. **Prompt 架构重构** — 将 prompt 中的"指令"（LLM 判断逻辑）和"输出格式"拆到独立子目录，格式部分可跨科目复用

### 1.2 不做什么

- ❌ 不做实时双栏调试面板
- ❌ 不做 WebSocket 调试事件推送
- ❌ 不做 HomeScreen 嵌入
- ❌ 不做 LLM 调用质量评估
- ❌ 不改变现有生产代码逻辑

---

## 2. 调试日志体系

### 2.1 日志存储

- **存储路径**: `data/debug_logs/{yyyy-mm-dd}/{conversation_id}.jsonl`
- **格式**: JSON Lines（每行一个 JSON 对象，行末 `\n`）
- **写入策略**: 追加写入，`tokio::sync::Mutex` 文件锁，每完成一个步骤写入一行

### 2.2 日志结构

```json
{
  "timestamp": "2026-06-13T10:30:00.123Z",
  "conversation_id": "conv_abc123",
  "phase": "base",
  "step": "system_prompt_selected",
  "details": {
    "template_path": "prompts/chat/english/structured.md",
    "mode": "structured",
    "domain": "english",
    "char_count": 425,
    "substitutions": [
      {"placeholder": "{grade}", "resolved_from": "user_plan_progress", "resolved_value": "grade_5"}
    ]
  }
}
```

**关键原则：日志自身不做任何截断。**
- `details` 中记录的内容必须是完整的上下文片段
- context 组装过程中的截断必须在 `details` 中明确记录：`truncated: true`, `original_size`, `truncated_size`, `truncation_reason`

### 2.3 埋点位置

| 代码位置 | step 名称 | 记录内容 |
|---------|----------|---------|
| `ws.rs` 会话创建 | `session_start` | conversation_id, user_id, subject, 是否被跟踪 |
| `ws.rs` 跟踪检查 | `tracker_check` | user_id 是否在跟踪列表 |
| `ws.rs:482` | `plan_context_built` | domain, mode, context 长度 |
| `ws.rs:488` | `system_prompt_selected` | 模板路径、模式、占位符替换 |
| `ws.rs:537` | `history_loaded` | 总轮数、截断前后字数 |
| `ws.rs:546` | `user_content_built` | 各片段长度 |
| `ws.rs:627` | `plan_created` | 触发方式（goal/plan命令）、domain |
| `ws.rs:827` | `cp1_skipped` | 跳过原因 |
| `ws.rs:866` | `cp1_concept_extraction` | candidates 数量 |
| `ws.rs:1001` | `cp1_cards_inserted` | 插入卡片数 |
| `ws.rs:865` | `cp2_analysis` | 分析结果 |
| `ws.rs 断开` | `session_end` | 总事件数、文件大小 |
| `plan_handler.rs:971` | `plan_context_exit` | pipeline_domain, mode, ctx 长度 |
| `plan_handler.rs:1103` | `context_text_inject` | card_id, full_text 长度, 翻译/句型 |

### 2.4 实现文件

| # | 文件 | 类型 | 用途 | 行数 |
|---|------|------|------|------|
| B1 | `backend/crates/api_server/src/debug_logger.rs` | 新增 | JSONL 文件日志模块 | ~150 |
| B2 | `backend/crates/api_server/src/debug_trackers_cache.rs` | 新增 | 跟踪用户内存缓存 | ~100 |
| B3 | `backend/crates/api_server/src/app_config_cache.rs` | 新增 | 运行时配置双缓存 | ~180 |
| B4 | `backend/crates/api_server/src/config_admin.rs` | 新增 | 配置管理 + 模板编辑 + 跟踪管理 API（8 个 handler） | ~388 |
| B5 | `backend/crates/api_server/src/routes.rs` | 修改 | 注册新路由 | +8 |
| B6 | `backend/crates/api_server/src/ws.rs` | 修改 | 13 处 debug_log 埋点 + app_config 动态读取 | +30 |
| B7 | `backend/crates/api_server/src/plan_handler.rs` | 修改 | 2 处 debug_log 埋点 | +10 |
| B8 | `backend/crates/api_server/src/concept_extractor.rs` | 修改 | 硬编码上限 → app_config 动态读取 | +5 |
| B9 | `backend/crates/api_server/src/admin_handlers.rs` | 修改 | ok/err 改为 pub(crate) | +2 |
| B10 | `backend/src/main.rs` | 修改 | 3 张表创建 + 缓存初始化 | +15 |
| B11 | `backend/src/bin/e2e_pipeline_test.rs` | 修改 | 补上新增的 max_count 参数 | +2 |
| F1 | `app/lib/screens/config_page.dart` | 新增 | 配置管理 + prompt 编辑页面 | ~300 |
| F2 | `app/lib/screens/debug_logs_page.dart` | 新增 | 调试日志查询浏览 + 跟踪管理页面 | ~250 |
| F3 | `app/lib/screens/admin_screen.dart` | 修改 | 用户管理加跟踪按钮 + 新增 2 个 Tab | +30 |
| F4 | `app/lib/screens/user_detail_screen.dart` | 修改 | 增加跟踪状态 + conversation_id 列表 | +15 |

### 2.5 新增 DB 表

```sql
-- 运行时配置表
CREATE TABLE app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT DEFAULT '',
    updated_at INTEGER NOT NULL
);

-- 用户跟踪表
CREATE TABLE debug_trackers (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    subject TEXT,
    status TEXT DEFAULT 'active',  -- active / stopped
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_debug_trackers_user ON debug_trackers(user_id);

-- 调试日志元数据
CREATE TABLE debug_logs (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    user_id TEXT,
    subject TEXT,
    date TEXT NOT NULL,
    log_file_path TEXT NOT NULL,
    entry_count INTEGER DEFAULT 0,
    file_size_bytes INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_debug_logs_conv ON debug_logs(conversation_id);
CREATE INDEX idx_debug_logs_date ON debug_logs(date);
```

### 2.6 用户隔离与日志开关

- 默认不开启，零开销
- 管理后台指定 `user_id` 启用/关闭跟踪
- `ws.rs` 先查内存缓存判断是否需要记录
- 跟踪记录存储于 `debug_trackers` 表 + `Arc<RwLock<HashMap>>` 内存缓存

### 2.7 API 清单

| 方法 | 路由 | 用途 | 权限 |
|------|------|------|------|
| GET | `/api/admin/config` | 列出所有配置项 | admin |
| POST | `/api/admin/config` | 批量更新配置 | admin |
| GET | `/api/admin/prompt/template` | 读取模板文件内容 | admin |
| POST | `/api/admin/prompt/template` | 保存模板文件内容 | **super** |
| POST | `/api/admin/debug/track` | 开始跟踪某用户 | admin |
| DELETE | `/api/admin/debug/track/{id}` | 关闭跟踪 | admin |
| GET | `/api/admin/debug/tracks` | 列出活跃跟踪 | admin |
| GET | `/api/admin/debug/logs` | 搜索日志（user_id/conv_id/date） | admin |
| GET | `/api/admin/debug/logs/{id}` | 日志详情（含文件内容） | admin |

---

## 3. 运行参数可配置

### 3.1 配置项

| key | 默认值 | 说明 | 影响代码 |
|-----|--------|------|---------|
| `prompt.history_max_chars` | `5000` | 对话历史截断字数 | `ws.rs` |
| `prompt.history_max_turns` | `10` | 对话历史保留轮次 | `ws.rs` |
| `prompt.concept_extract_max` | `5` | 概念提取最多数量 | `concept_extractor.rs` |
| `debug_log.enabled` | `true` | 是否启用调试日志 | `debug_logger.rs` |
| `debug_log.retention_days` | `7` | 调试日志保留天数 | 清理 job |

### 3.2 双缓存策略

```
app_config 表 (持久化) ←→ Arc<RwLock<HashMap>> (内存缓存)
                        ↑
                起服时全量加载
```

### 3.3 模板编辑权限

- `role = 'super'` 可编辑
- 普通管理员只读查看
- 原子写入（tmp + rename），崩溃安全

---

## 4. Prompt 架构重构（阶段二：signal/format 拆分）

### 4.1 目标

将每个 prompt 拆为"指令"（LLM 判断逻辑）和"输出格式"两个部分，格式部分可跨科目复用。

### 4.2 新目录结构

```
prompts/
├── format/                             ← 共享格式模板池（21 个文件）
│   ├── shared/
│   │   ├── json-only.md                "只返回 JSON，不要其他文字"
│   │   ├── json-array.md               "只返回 JSON 数组"
│   │   └── pass-fail.md                "Respond with exactly one word"
│   ├── chat/
│   │   ├── graph.md                    <graph> JSON 渲染格式
│   │   ├── latex.md                    LaTeX 公式规则
│   │   └── plan-marker.md              **Goal学习计划创建✅ 已完成**
│   ├── plan/
│   │   ├── creation.md                 计划创建 JSON schema
│   │   ├── analysis.md                 计划分析 JSON schema
│   │   └── signal.md                   {has_task: bool} 格式
│   ├── quiz/
│   │   ├── generate.md                 [{question, expected_answer}]
│   │   ├── judge.md                    [{correct, feedback}]
│   │   └── grill.md                    {task, passed, correct, ...}
│   ├── concept/
│   │   ├── general.md                  {front, definition, domain}
│   │   ├── science.md                  + key_elements, formula, applications
│   │   ├── language.md                 + pronunciation, pos, definitions
│   │   ├── literature.md               + full_text, translation, author
│   │   └── humanities.md               + body, period, region, tags
│   ├── verify/
│   │   ├── translation.md              pass/fail 判定
│   │   └── usage.md                    {word, correct, reason, correction_hint}
│   └── routing/
│       └── subject.md                  {subject, grade, description}
│
├── {category}/{subject}/
│   ├── signal/{type}.md                ← 指令部分（判断逻辑）
│   ├── format/{type}.md                ← 格式部分（引用 format/ 共享池）
│   └── {type}.md                       ← 旧式 flat 文件（后向兼容）
```

### 4.3 引用机制

`{include:format/xxx/yyy.md}` 语法，在 `init()` 时递归解析展开。

```rust
// signal/structured.md → 引用共享的 graph 格式
{include:format/chat/graph.md}
```

### 4.4 加载优先级

```
signal/{type}.md + format/{type}.md → {type}.md (旧式) → general fallback
```

### 4.5 已迁移的科目（28 组 signal/format）

| 分类 | 已迁移的科目 |
|------|------------|
| chat | `general`(free, structured), `math`, `chemistry` |
| concept | `general`, `science`, `language`, `literature`, `humanities` |
| plan | `general`(creation, analysis, signal) |
| quiz | `general`(generate, judge, grill) |
| verify | `general`(translation, usage) |
| routing | `general`(subject) |

未迁移的科目（如 art/biology/geography 等 10 个 duplicate structured）仍通过旧式 flat 文件正常加载，后向兼容。

### 4.6 Rust 代码变更

- **`prompt_loader.rs`** — 新增 `resolve_includes()`（递归解析 `{include:...}`），新增 `read_signal_or_flat()`（三级加载），改用 `Path::join` 确保跨平台路径
- **`ws.rs`** — `verify_usage` 加载从 `std::fs::read_to_string` 改为 `get_verify("general").usage`
- **`Cargo.toml`** (chat_engine) — 新增 `regex = "1"` 依赖

---

## 5. 任务完成状态

### 阶段一 — ✅ 全部完成（~17 人时）

| # | 任务 | 状态 | 备注 |
|---|------|------|------|
| 1 | 创建 `debug_logger.rs` | ✅ | |
| 2 | 创建 `app_config` 表 + 缓存 | ✅ | 含 `app_config_cache.rs` |
| 3 | `ws.rs` 追加 debug_log 调用（13处） | ✅ | 包含设计时标注的 5 处 + 补全的 8 处 |
| 4 | `plan_handler.rs` 追加 debug_log（2处） | ✅ | |
| 4a | 创建 `debug_trackers` 表 + 缓存 | ✅ | 含 `debug_trackers_cache.rs` |
| 5 | 创建 `config_admin.rs` | ✅ | 9 个 handler |
| 5a | `concept_extractor.rs` 读取 app_config | ✅ | |
| 6 | 注册路由 | ✅ | |
| 7 | 创建 `config_page.dart` | ✅ | |
| 8 | 创建 `debug_logs_page.dart` | ✅ | |
| 9 | 集成 `admin_screen.dart` + `user_detail_screen.dart` | ✅ | 跟踪按钮 + 2 个新 Tab |
| 10 | 修复 `fsrs_scheduler.rs` 测试代码参数遗漏 | ✅ | 3 处补 `None` |

### 阶段二 — ✅ 全部完成（~2 人时）

| # | 任务 | 状态 | 备注 |
|---|------|------|------|
| 11 | `prompt_loader.rs` 新增 signal/format 加载 | ✅ | `resolve_includes` + `read_signal_or_flat` |
| 12 | 创建 `prompts/format/` 共享池 | ✅ | 21 个共享格式模板 |
| 13 | 拆分 28 组 prompt 到 signal/format | ✅ | 覆盖 chat/concept/plan/quiz/verify/routing |
| 14 | 删除 18 个旧 flat 文件 | ✅ | general/ 全部分类 + 4 concept + math/chemistry |
| 15 | 更新 ws.rs 调用 | ✅ | verify_usage 改用 prompt_loader |

---

## 6. 测试验证

| 测试 | 结果 |
|------|------|
| `cargo check`（全 workspace） | ✅ 零 error 零 warning |
| `cargo test --workspace` | ✅ 74 passed（含 28 api_server + 17 card_engine + 20 chat_engine + 9 growth_engine）|
| `prompt_loader` 单元测试 | ✅ 9/9 通过（新架构 signal+format+include+fallback） |
| e2e 集成测试 | ⏭️ 被忽略（需要 LLM API key，与变更无关） |

---

## 7. 已确认事项

| # | 事项 | 决策 |
|---|------|------|
| Q1 | 调试日志保留策略 | **✅ 7 天**，可配置。超期文件由定时任务清理 |
| Q2 | ws.rs 中 logger 的生命周期 | **✅ 同意**。WsSession 创建时初始化，关闭 WS 时 close() |
| Q3 | 配置生效范围 | **✅ 全局生效**，现阶段不需要按科目/用户覆盖 |
| Q4 | 模板编辑时是否校验格式 | **✅ 已确认**。占位符高亮 + 受保护模式警告 + 大括号闭合检查。阶段二已完成 prompt 拆分 |
