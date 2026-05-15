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
Schema initialized (9 tables, 迁移后 10 表)
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
├── src/main.rs             # 入口 + 启动配置 + 内联 SCHEMA_SQL（9 表 + 迁移）
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
    │   ├── auth_middleware.rs   # Bearer Token 鉴权
    │   ├── plan_handler.rs     # 学习计划解析/存储/JSON修复
    │   ├── routes.rs           # REST API 路由（含对话软删除/恢复/彻底删除）
    │   └── ws.rs               # WebSocket 流式聊天
    ├── chat_engine/        # LLM 调用 + 概念提取 + 词库 + JSON修复
    ├── card_engine/        # 制卡 + FSRS 调度
    ├── growth_engine/      # 成就检测
    └── shared_types/       # 公共类型

app/                        # Flutter 前端
├── lib/
│   ├── api/                # HTTP/WS 客户端
│   ├── models/             # 数据模型
│   ├── providers/          # Riverpod 状态管理
│   ├── screens/            # 9 个页面
│   ├── services/           # TTS / STT 服务
│   └── theme/              # Material 3 主题
```

## 常用命令

### 后端

| 命令 | 说明 |
|:--|:--|
| `cargo run` | 启动后端 (8080) |
| `cargo test --workspace` | 运行全部测试 (35 个) |
| `cargo test -p card_engine` | 仅运行制卡引擎测试 |
| `cargo check` | 编译检查 |
| `RUST_LOG=debug cargo run` | 带调试日志启动 |

### 前端

| 命令 | 说明 |
|:--|:--|
| `flutter run` | 启动 App |
| `flutter analyze` | 静态分析 |
| `flutter test` | 运行全部测试 |
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
