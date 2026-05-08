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
Schema initialized (8 tables)
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
├── src/main.rs             # 入口 + 启动配置
├── schema.sql              # 数据库 8 张表定义
├── cefr_catalog.json       # 英文词库 (10 万词)
├── prompts/                # LLM Prompt 模板
│   ├── chat_system.md
│   ├── concept_extract.md
│   ├── card_direct.md
│   ├── quiz_generate.md
│   └── quiz_judge.md
├── data/coevo.db           # SQLite 数据库 (运行后自动创建)
└── crates/
    ├── api_server/         # HTTP + WS 路由
    ├── chat_engine/        # LLM 调用 + 概念提取 + 词库
    ├── card_engine/        # 制卡 + FSRS 调度
    ├── growth_engine/      # 成就检测
    └── shared_types/       # 公共类型

app/                        # Flutter 前端
├── lib/
│   ├── api/                # HTTP/WS 客户端
│   ├── models/             # 数据模型
│   ├── providers/          # Riverpod 状态管理
│   ├── screens/            # 8 个页面
│   ├── services/           # TTS / STT 服务
│   └── theme/              # Material 3 主题
```

## 常用命令

### 后端

| 命令 | 说明 |
|:--|:--|
| `cargo run` | 启动后端 (8080) |
| `cargo test --workspace` | 运行全部测试 (26 个) |
| `cargo test -p card_engine` | 仅运行制卡引擎测试 |
| `cargo check` | 编译检查 |
| `RUST_LOG=debug cargo run` | 带调试日志启动 |

### 前端

| 命令 | 说明 |
|:--|:--|
| `flutter run` | 启动 App |
| `flutter analyze` | 静态分析 |
| `flutter test` | 运行 Flutter 测试 |

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

## 修改 Prompt

Prompt 文件在 `backend/prompts/`，修改后重启后端即可生效，**无需重新编译**。
