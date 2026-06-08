# CoEvo 本地开发指南

## 环境要求

- **Rust**: 1.81+ (rustup)
- **Flutter**: 3.27+ (含 Dart SDK)
- **Node.js**: 22+（可选，仅用于某些工具）
- **Python**: 3.13 (数据脚本)
- **操作系统**: Windows / macOS / Linux

## 快速开始

### 1. 克隆项目

```bash
git clone <repo-url> coevo
cd coevo
```

### 2. 配置 API Key

```bash
cd backend
cp .env.example .env   # 或手动创建 .env
```

编辑 `.env`:

```
DEEPSEEK_API_KEY=sk-你的key
```

> 获取 key: https://platform.deepseek.com/api_keys

### 3. 启动后端

```bash
cd backend
cargo run
```

启动日志示例:
```
CoEvo API on http://0.0.0.0:8080
LLM: deepseek-v4-flash @ https://api.deepseek.com/v1
Prompts loaded from prompts/
[K12] data dir: data/curriculum/v3
[K12] loaded 14 plans from ...v3/plans
[K12] loaded 14 card sets from ...v3/cards
Word bank loaded: ~10万 words
Schema initialized (18 tables)
```

### 4. 启动前端 (Flutter Web)

```bash
cd app
flutter run -d chrome --release \
  --dart-define=API_HOST=localhost
```

> Flutter Web 连接 `http://localhost:8080`。生产部署时改 `--dart-define=API_HOST=<OLD_VPS_IP>`

---

## 项目结构 (2026-06-08)

```
backend/                    # Rust 后端 (axum)
├── src/main.rs             # 入口 + 启动配置 + 内联 SCHEMA_SQL (18 表)
├── prompts/                # LLM Prompt 模板 (50+ 文件)
│   ├── chat/               # 对话 prompt
│   │   ├── chinese/        # 语文 (三级: nursery/primary/secondary)
│   │   ├── english/        # 英语 (free + 三级 reading + structured)
│   │   ├── japanese/       # 日语 (free + reading 三级 + structured)
│   │   ├── russian/        # 俄语 (同上)
│   │   ├── math/ physics/ chemistry/ biology/  # 理科 structured
│   │   ├── history/ geography/ politics/ it/   # 文科 structured
│   │   ├── art/ labor/ science/ pe/           # 其他
│   │   └── general/        # 通用 (free + structured)
│   ├── quiz/               # 复习考题 prompt (general/chinese/english/math)
│   ├── concept/            # 概念提取 (direct + extract)
│   ├── plan/               # 学习计划 (analysis/creation/signal)
│   ├── routing/            # 学科路由 (subject)
│   ├── student/            # 学生智能体 (仅测试用)
│   └── verify/             # 验证
├── data/
│   ├── coevo.db            # SQLite 数据库
│   ├── logs/               # 运行日志
│   ├── avatars/            # 用户头像
│   └── deleted_users.ndjson
├── data/curriculum/        # K12 课标数据 (V3)
│   ├── v3/                 # 当前版本
│   │   ├── plans/          # 14 科计划 JSON
│   │   └── cards/          # 14 科卡片 JSON (合并后)
│   ├── prebuilt/           # 预构建数据
│   │   └── cefr_j/         # CEFR-J 英语分级词库
│   ├── raw/ cleaned/ gold/ # 数据处理管线 (管线内)
│   └── english_rebuild/    # 英语重建产物
├── scripts/                # Python 数据脚本
│   ├── english_rebuild/    # 英语重建管线 (Phase 1-5)
│   ├── rebuild_subject_cards/  # 卡片重分配
│   ├── v3_scripts/         # V3 数据迁移脚本
│   └── eval/               # 评估管线
└── crates/
    ├── api_server/         # HTTP + WS + 鉴权 + 计划 + K12
    │   ├── auth.rs              # 注册/登录/Token (限流 5/10 per min)
    │   ├── auth_middleware.rs   # Bearer Token 鉴权
    │   ├── rate_limiter.rs      # 滑动窗口限流 (2026-06-08 新增)
    │   ├── error.rs             # 统一错误类型
    │   ├── db_pool.rs           # 连接池
    │   ├── plan_handler.rs      # 学习计划 (K12 + CP2)
    │   ├── curriculum_loader.rs # K12 课标 JSON 加载器
    │   ├── achievement_engine.rs # 成就系统 (23+ 成就)
    │   ├── routes.rs            # REST API
    │   └── ws.rs                # WebSocket 流式 (CP1/CP2 分离)
    ├── chat_engine/        # LLM 调用 + 概念提取 + 词库
    │   ├── llm_caller.rs        # OpenAI 兼容 API 调用
    │   ├── concept_extractor.rs # N2 概念提取
    │   ├── word_bank.rs         # CEFR 词库
    │   └── prompt_loader.rs     # 外部 prompt 文件加载
    ├── card_engine/        # 制卡 + FSRS-5
    │   ├── fsrs_scheduler.rs    # N5 队列 + task 级过滤
    │   ├── fsrs5.rs             # FSRS-5 自实现 (16/16 测试)
    │   └── card_repository.rs   # TxGuard 事务封装
    ├── growth_engine/      # 成就
    └── shared_types/       # 公共类型

app/                        # Flutter 前端
├── lib/
│   ├── api/                # HTTP/WS 客户端
│   │   └── chat_client.dart     # REST 调用 (含 cardRefreshProvider)
│   ├── providers/          # Riverpod 状态管理
│   │   ├── auth_provider.dart   # AuthState + cardRefreshProvider
│   │   └── ...
│   ├── screens/            # 页面
│   │   ├── chat_screen.dart        # AI 对话 (含课文面板入口)
│   │   ├── review_screen.dart      # 复习 (内联验证 + 后台评判)
│   │   ├── achievements_screen.dart # 成就 (事件驱动刷新)
│   │   ├── profile_screen.dart     # 个人页 (头像预检)
│   │   └── chat/
│   │       ├── chat_reading_passage.dart  # 课文阅读面板 (2026-06-08)
│   │       ├── chat_concept_dialog.dart   # 制卡确认弹窗
│   │       ├── chat_input.dart            # 输入栏
│   │       ├── chat_plan_panel.dart       # 学习计划面板
│   │       └── chat_message_bubble.dart   # 消息气泡
│   ├── services/           # TTS / STT 服务
│   │   └── tts_service.dart     # TTS (音色持久化修复)
│   ├── widgets/            # 通用组件
│   │   └── markdown_span_nodes.dart  # 结构化 JSON 卡片渲染 (牛津/新华字典)
│   └── theme/              # Material 3 主题
├── test/                   # 测试
└── analysis_options.yaml
```

## 常用命令

### 后端

| 命令 | 说明 |
|:--|:--|
| `cargo run` | 启动后端 (8080) |
| `cargo test --workspace` | 运行全部测试 (41 个) |
| `cargo test -p card_engine` | 仅运行制卡引擎测试 |
| `cargo check` | 编译检查 |
| `RUST_LOG=debug cargo run` | 带调试日志启动 |

**重要架构改进 (2026-05-16)**:

* **统一错误类型**: `api_server::error::AppError` (thiserror)，实现 `IntoResponse`
  - `verify_auth()` 返回 `Result<(), AppError>`，鉴权失败自动 401
  - handler 使用 `auth_json(e)` 辅助函数转换
* **事务封装**: `card_engine::card_repository::TxGuard` — RAII 自动回滚
  - 替代手动 BEGIN/ROLLBACK/COMMIT
  - Drop 时自动 ROLLBACK 未提交事务
* **LLM 指数退避**: 250ms * 2^attempt，上限 2000ms
* **PRAGMA foreign_keys = ON**: db_pool 连接池级别启用外键约束
* **日志默认级别**: `warn`（生产安全），开发时设 `RUST_LOG=info`
* **DB 查询安全**: `query_vec()` / `query_one()` 辅助函数

## 近期重要改动 (2026-05-17)

### Markdown 全渲染

- 依赖: `markdown_widget ^2.3.2`
- 块分割模型: `<graph>` 和 `\[formula\]` 作为独立 Block，纯文本走 MarkdownWidget
- 行内公式 `\(...\)` 正则分割 + `flutter_math_fork`
- 颜色统一: `RichContentBuilder.textColor` 贯穿整个链路（公式/文本/引用/代码块）
- 自定义 MarkdownConfig: blockquote/textColor, PreConfig/textStyle, CodeConfig/style

### 图形渲染工具

- 依赖: `fl_chart ^0.70.0` + CustomPainter
- 支持 7 种类型: line / bar / scatter / pie / polygon / circle / arrow
- polygon 扩展: 顶点标注 labels、直角标记 rightAngles、角度弧线 angles
- circle 扩展: 切线 tangents、圆心角弧线 angles
- 容错: `_safeDouble` / `_safeInt` 替换所有 `as num` 强转
- K-12 覆盖率 90%（小学 89% / 初中 90% / 高中 91%）

### 单设备登录

- 机制: `KICK_NOTIFIERS` (Arc\<Notify\>) 全局映射
- 新设备登录 → `kick_user_connections` → 旧 WS 收到 kicked 事件 → 前端跳转 /auth
- 修复: `lock.remove()` 替代 `lock.get()` 防跨会话 permit 残留

### 复习 + 卡片页合并

- 删 `/cards` 路由 + 导航项，底部导航 4→3 项
- review_screen: `DefaultTabController` [待复习(N) / 全部卡片]
- `CardListScreen(embedded: true)` 嵌入全部卡片 Tab

### 学习计划双智能体测试

- 学生 LLM + 导师 LLM 全自主对话
- K-12 话题约束，覆盖计划创建→子步骤→任务完成→阶段完成→成就
- 2 话题验证: 一次函数(23.5min)/一元二次方程(25.8min)
- 详见 `DEVELOPMENT.md` 测试章节
  - 统一 prepare + query_map + 错误转 Json 响应
  - routes.rs unwrap 35→22（高风险 DB 类已清零）
* **chat_screen 拆分**: 1453→830 行（-43%）
  - `chat_concept_dialog.dart` — 制卡确认弹窗 (ConceptDialog.show)
  - `chat_input.dart` — 文本+语音输入栏 (ChatInput widget)
  - `chat_plan_panel.dart` — 学习计划面板 (ChatPlanPanel)
  - `chat_message_bubble.dart` — 消息气泡渲染 (ChatMessageBubble)
* **Freezed 模型**: 已添加依赖 + 示例 (`models/freezed_example.dart`)
  - 运行 `cd app && dart run build_runner build` 生成代码
  - DueCard → 后续逐模型迁移 (ConceptCandidate/VerifyQuestion/JudgeResult/ChatRequest/WsEvent)

### 前端

| 命令 | 说明 |
|:--|:--|
| `flutter run` | 启动 App |
| `flutter analyze` | 静态分析 |
| `flutter test` | 运行全部测试 |
| `flutter test test/model_test.dart test/review_widget_test.dart` | 数据模型 + 复习页面测试 |
| `flutter test test/math_streaming_test.dart test/math_e2e_pipeline_test.dart` | 运行数学公式渲染测试 (19 用例) |

## 调试

### 后端日志级别

```bash
RUST_LOG=debug cargo run          # 详细
RUST_LOG=info cargo run           # 正常
RUST_LOG=warn cargo run           # 仅警告
```

### 验证 API 连通性

```bash
curl http://localhost:8080/health
# → "CoEvo API -- OK"

# 注册用户
curl -X POST http://localhost:8080/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test"}'
```

### 数据库

```bash
# 查看 SQLite 数据库
cd backend
sqlite3 data/coevo.db ".tables"
sqlite3 data/coevo.db "SELECT * FROM users;"
```

### 对话管理

CoEvo 支持软删除机制，避免误删导致数据永久丢失。

```bash
# 软删除对话（移至回收站）
curl -X DELETE "http://localhost:8080/api/conversations/conv_xxx?user_id=user_xxx" \
  -H "Authorization: Bearer <token>"

# 恢复已删除对话
curl -X POST "http://localhost:8080/api/conversations/conv_xxx/restore?user_id=user_xxx" \
  -H "Authorization: Bearer <token>"

# 彻底删除（不可恢复，同时删除 conversation_turns）
curl -X DELETE "http://localhost:8080/api/conversations/conv_xxx/permanent?user_id=user_xxx" \
  -H "Authorization: Bearer <token>"

# 查看已删除对话
curl "http://localhost:8080/api/history?user_id=user_xxx&include_deleted=only" \
  -H "Authorization: Bearer <token>"

# 手动清理30天前的已删除对话
sqlite3 data/coevo.db "DELETE FROM conversation_turns WHERE conversation_id IN (SELECT id FROM conversations WHERE deleted_at IS NOT NULL AND deleted_at < datetime('now','-30 days')); DELETE FROM conversations WHERE deleted_at IS NOT NULL AND deleted_at < datetime('now','-30 days');"
```

## 修改 Prompt

Prompt 文件在 `backend/prompts/`，修改后重启后端即可生效，**无需重新编译**。

---

## 数学公式渲染

### 渲染管道

CoEvo 支持 LLM 输出的 LaTeX 数学公式，通过 `flutter_math_fork` 渲染：

```
DeepSeek/Qwen SSE
  → ws.rs (JSON 帧: {"type":"token","content":"..."})
  → WebSocket
  → chat_screen.dart: _handleWsEvent (≈445行)
  → _buildRichContent(text, isStreaming: bool)
  → Math.tex(formula)
```

### 支持的定界符

| 类型 | 定界符 | 示例 | flutter_math_fork |
|------|--------|------|-------------------|
| 行内公式 | `\( ... \)` | `\(\sin\theta\)` | 行内渲染 |
| 独立公式 | `\[ ... \]` | `\[\sum x^n\]` | 块级居中渲染 |

### 流式渲染策略

为防止流式输出期间公式闪烁（不完整定界符导致正则反复匹配/不匹配）：

- **流式期间** (`isStreaming = true`): `_buildRichContent` 直接返回纯文本，**跳过正则解析**
- **done 事件** (`isStreaming = false`): 一次性用正则提取所有公式，渲染为 `Math.tex`

### 正则表达式

```dart
// chat_screen.dart _buildRichContent (≈1237行)
final mathRegex = RegExp(
  r'\\[\(\[](.+?)\\[[)\]]',
  dotAll: true,  // LLM 输出的 \[...\] 可能含换行
);
```

> **注意**: `dotAll: true` 是必需的。DeepSeek/Qwen 输出 display 公式时常在 `\[` 和 `\]` 之间换行，
> 默认 `.` 不匹配 `\n` 会导致 display 公式静默丢弃。

### 测试

```bash
# 单元测试 + 管道测试 (19 用例)
cd app
flutter test test/math_streaming_test.dart test/math_e2e_pipeline_test.dart

# 真实 LLM 流式验证 (需要 DEEPSEEK_API_KEY 环境变量)
cd ..
python scripts/live_llm_stream_test.py              # 单领域
python scripts/live_llm_stream_test.py --domain all # 全部 5 领域
```

### 已知覆盖范围

通过 5 领域 × 248 公式真实 LLM 验证，支持以下 LaTeX 特性：

`\frac \int \sum \lim \sqrt \partial \pm \cdot \times`
`\begin{pmatrix} \begin{bmatrix} \begin{cases}`
`\left \right \mathbb \mathbf \nabla \varepsilon \infty`

---

## 学习计划生命周期测试 (双智能体)

> 测试文件: `backend/crates/api_server/tests/e2e_live_llm_plan_lifecycle.rs`

### 架构

```
┌─────────────────┐         ┌─────────────────┐
│  学生智能体 LLM  │ ──自然对话──→ │  导师智能体 LLM  │
│  (DeepSeek V4)  │ ←──教学+考核── │  (chat_system)   │
│  temp=0.5        │              │  temp=0.7        │
└─────────────────┘              └────────┬────────┘
                                          │
                                   handle_plan_update
                                          │
                              ┌───────────▼───────────┐
                              │ learning_plans        │
                              │ achievements          │
                              │ conversation_turns    │
                              └───────────────────────┘
```

### 设计

| 要素 | 实现 |
|------|------|
| 学生智能体 | 独立 LLM，读取对话历史 + 计划进度，自主决定每轮发言 |
| 导师智能体 | 使用 `chat_system_free.md` / `chat_system_structured.md` prompt |
| 话题约束 | K-12 课程（小学/初中/高中数学物理），固定候选列表 |
| plan_update | 导师通过 `<plan_update>` JSON 标签更新计划状态 |
| 成就检测 | `record_stage_achievements` 仅在 `!is_new_plan` 时触发 |

### 覆盖范围

| 生命周期节点 | 验证方式 |
|-------------|---------|
| 计划创建 | `get_plan_from_db().is_some()` + `is_new_plan=true` |
| 子步骤推进 | `task_sub_steps: teach→examples→quiz` |
| 任务完成 | `current_task_complete: true` → 推进到下一任务 |
| 阶段完成 | 阶段内全部任务 done → 阶段标记 done |
| 成就解锁 | silver（阶段完成）、gold（全部阶段完成） |
| 对话持久化 | `conversation_turns` 写入 user + assistant 消息 |

### 测试用例

| 测试函数 | 说明 | 标记 |
|---------|------|------|
| `e2e_live_llm_plan_lifecycle` | 硬编码用户消息的生命周期测试 | `#[ignore]` |
| `e2e_live_revert_basic` | 回退机制测试（LLM 使用 reset_current_task） | `#[ignore]` |
| `e2e_live_revert_explicit` | 显式回退测试（用户要求 LLM 回退） | `#[ignore]` |
| `e2e_dual_agent_autonomous` | **双智能体自主对话**（主测试） | `#[ignore]` |

### 运行

```bash
# 双智能体自主对话（完整生命周期，约 25 分钟）
cargo test -p api_server --test e2e_live_llm_plan_lifecycle \
  e2e_dual_agent_autonomous -- --ignored --nocapture

# 所有 LLM 测试
cargo test -p api_server --test e2e_live_llm_plan_lifecycle \
  -- --ignored --nocapture
```

前置条件: `backend/.env` 中已配置 `DEEPSEEK_API_KEY`

### 已验证结果

| 测试话题 | 计划 | 完成 | 成就 | 耗时 |
|---------|------|------|------|------|
| 一次函数（初中数学） | 3 阶段 6 任务 | 2/3 阶段, 4/6 任务 | 2 silver | 23.5 min |
| 一元二次方程（初中数学） | 3 阶段 6 任务 | 2/3 阶段, 4/6 任务 | 2 silver | 25.8 min |

### 已知限制

阶段三（深层应用/推导）所需轮次等于前两阶段之和，80 轮上限无法完整覆盖但断言已满足。详见 `docs/dual-agent-k12-v3-report-2026-05-17.md`
