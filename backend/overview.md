# CoEvo 项目 — M1 全部完成

## M1 完成情况 (Day 1)

| 任务 | 状态 | 产出 |
|:--|:--|:--|
| Task 1.1: Cargo Workspace | ✅ | 5 crates, `cargo build` 通过 |
| Task 1.2: Schema (8 表) | ✅ | `schema.sql` + idempotent migration |
| Task 1.3: Flutter 骨架 | ✅ | `flutter analyze` — No issues found |
| Task 1.4: 代码移植 | ✅ | 从 LinguaFlow 复制+适配 5 个模块 |

## 后端 (Rust)

```
E:\CoEvo\backend/
├── Cargo.toml                 # Workspace
├── src/main.rs                # 入口 (启动+迁移+预热)
├── schema.sql                 # 8 张表 + 索引
├── crates/
│   ├── shared_types/          # 公共类型 (card/review/growth/conversation)
│   ├── api_server/            # Axum 路由 + WS + Auth + DB Pool
│   ├── chat_engine/           # LLM Caller + 概念提取
│   ├── card_engine/           # 卡片格式化 + 入库 + FSRS 调度
│   └── growth_engine/         # 成就检测
```

### 后端测试: 18 passed, 0 failed ✅
- card_engine: 7 tests
- chat_engine: 8 tests (2 integration ignored)
- growth_engine: 3 tests

## 前端 (Flutter)

```
E:\CoEvo\app/
├── pubspec.yaml               # 依赖: riverpod, go_router, ws, http
├── lib/
│   ├── main.dart              # 入口 (ProviderScope)
│   ├── app.dart               # GoRouter 路由配置
│   ├── api/
│   │   ├── api_config.dart    # [复用] API 配置
│   │   ├── auth_client.dart   # [复用] 登录/注册客户端
│   │   └── chat_client.dart   # [适配] 聊天+复习+WS API
│   ├── theme/
│   │   └── app_theme.dart     # [复用] 改色系 (深蓝+翠绿)
│   ├── models/
│   │   └── coevo_models.dart  # [新] ChatRequest, DueCard, WsEvent 等
│   ├── providers/
│   │   └── auth_provider.dart # [复用] Riverpod 认证状态
│   └── screens/
│       ├── auth_screen.dart   # [新] 登录/注册
│       ├── home_screen.dart   # [新] 首页 (对话+复习入口)
│       ├── chat_screen.dart   # [新] AI 对话 + 候选概念弹窗
│       ├── review_screen.dart # [新] 翻牌复习 + AI问答
│       └── profile_screen.dart# [新] 个人中心+成就
```

## API 路由 (已就绪)

| Method | Path | N节点 | 状态 |
|:--|:--|:--|:--|
| GET | `/health` | - | ✅ |
| POST | `/api/auth/register` | 用户 | ✅ |
| POST | `/api/auth/login` | 用户 | ✅ |
| POST | `/api/chat` | N1+N2 | ✅ |
| WS | `/ws` | N1+N2 | ✅ |
| GET | `/api/review/due` | N5 | ✅ |
| POST | `/api/review/submit` | N6c+N7 | ✅ |
| POST | `/api/review/verify` | N6b | ✅ |
| POST | `/api/review/judge` | N6b | ✅ |
| POST | `/api/cards/skip` | Flow E | ✅ |
| GET | `/api/cards/skipped/:user_id` | Flow E | ✅ |
| DELETE | `/api/cards/skipped/:id` | Flow E | ✅ |
