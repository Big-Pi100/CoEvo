# CoEvo 本地开发指南

## 环境要求

- **Rust**: 1.81+ (rustup)
- **Flutter**: 3.27+ (含 Dart SDK)
- **Node.js**: 22+（可选，仅用于某些工具）
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
Word bank loaded: ~10万 words
Schema initialized (10 tables, 迁移后 11 表)
```

### 4. 启动前端

```bash
cd app
flutter run
```

> 需要连接模拟器或真机。Flutter 默认连接 `http://localhost:8080`。

---

## 项目结构

```
backend/                    # Rust 后端 (axum)
├── src/main.rs             # 入口 + 启动配置 + 内联 SCHEMA_SQL（10 表 + 迁移）
├── cefr_catalog.json       # 英文词库 (10 万词)
├── prompts/                # LLM Prompt 模板
│   ├── chat_system.md
│   ├── chat_system_free.md       # 自由对话模式
│   ├── chat_system_structured.md # 结构化学习模式
│   ├── concept_extract.md
│   ├── card_direct.md
│   ├── quiz_generate.md
│   ├── quiz_judge.md
│   └── grill_assessment.md
├── data/coevo.db           # SQLite 数据库 (运行后自动创建)
└── crates/
    ├── api_server/         # HTTP + WS 路由 + 鉴权中间件 + 计划管理
    │   ├── auth.rs              # 注册/登录/Token验证
    │   ├── auth_middleware.rs   # Bearer Token 鉴权（返回 AppError）
    │   ├── error.rs             # 统一错误类型 (thiserror AppError + IntoResponse)
    │   ├── db_pool.rs           # 连接池 (PRAGMA foreign_keys = ON)
    │   ├── plan_handler.rs     # 学习计划解析/存储/JSON修复
    │   ├── routes.rs           # REST API 路由（chat_handler 已拆分为5个helper函数）
    │   └── ws.rs               # WebSocket 流式聊天
    ├── chat_engine/        # LLM 调用 + 概念提取 + 词库 + JSON修复
    ├── card_engine/        # 制卡 + FSRS-5 调度（fsrs5.rs 自实现 + TxGuard）
    ├── growth_engine/      # 成就检测
    └── shared_types/       # 公共类型

app/                        # Flutter 前端
├── lib/
│   ├── api/                # HTTP/WS 客户端
│   ├── models/             # 数据模型
│   ├── providers/          # Riverpod 状态管理
│   ├── screens/            # 9 个页面
│   │   └── chat/
│   │       ├── chat_concept_dialog.dart  # 制卡确认弹窗
│   │       ├── chat_input.dart           # 文本+语音输入栏
│   │       └── chat_plan_panel.dart      # 学习计划面板(可折叠)
│   ├── services/           # TTS / STT 服务
│   ├── widgets/            # 通用组件 (graph_widget, skeleton)
│   └── theme/              # Material 3 主题
├── test/
│   ├── model_test.dart         # 数据模型序列化测试
│   ├── review_widget_test.dart # 复习页面 Widget 测试
│   └── ...                     # 数学公式测试等
└── analysis_options.yaml  # dart_code_metrics 配置
```

## 常用命令

### 后端

| 命令 | 说明 |
|:--|:--|
| `cargo run` | 启动后端 (8080) |
| `cargo test --workspace` | 运行全部测试 (37 个) |
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
