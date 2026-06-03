# e2e 测试范式审计 —— API 调用 vs 直接函数调用

> 2026-06-03 02:04

## 核心问题

测试 **完全不经过 HTTP API 层**，所有操作都是直接调用内部函数。
前端所有功能依赖 HTTP API，当 API 响应格式变化时测试零感知。

## 逐行对标

| 测试操作 | 实现方式 | 对应生产 API | 是否一致？ |
|---------|---------|-------------|-----------|
| 用户消息入库 | `helpers::insert_turn()` → 直接 `conn.execute(INSERT INTO conversation_turns)` | `POST /api/chat` (ws.rs) | ❌ 跳过了 ws.rs WebSocket 握手、ColdPath CP1 异步触发 |
| 教师 LLM 调用 | `caller.generate(system_prompt, user_content)` | ws.rs 内部同路径 | ✅ 提示词一致 |
| CP2 分析 | `plan_handler::analyze_turn_progress()` → 直接调内部函数 | 同函数 | ✅ 函数一致 |
| 学生 LLM 调用 | `student_caller.generate(STUDENT_SYSTEM_PROMPT, history)` | 无对应 API | ⚠️ 纯测试辅助 |
| 查询计划 | `helpers::get_plan()` → 直接 `conn.query_row(SELECT FROM conversation_plans)` | `GET /api/plans` | ❌ **关键断裂** |
| 查询卡片 | `helpers::get_plan_content_json()` → 直接 SQL | `GET /api/cards/all` | ❌ |
| CP1 概念提取 | `chat_engine::concept_extractor::extract_concepts()` | ws.rs 内部同路径 | ✅ 函数一致 |
| 卡片写入 | 直接 `conn.execute(INSERT INTO cards)` | `POST /api/chat` (WebSocket 内 ColdPath) | ❌ |
| 查询计划进度 | `conn.query_row(SELECT FROM user_plan_progress)` | `GET /api/user/{id}/learning-report` | ❌ |
| 成就查询 | `helpers::get_achievements()` → 直接 SQL | `GET /api/history` / 成就 API | ❌ |
| 创建用户/会话 | `conn.execute(INSERT INTO users/conversations)` | `POST /api/auth/register` + `POST /api/k12/init` | ❌ |
| 验证卡片关联 | 直接 SQL GROUP BY | `GET /api/cards/all` + `GET /api/plans` | ❌ |

## 后果

测试通过了，但以下 API 响应已经断裂：
- `GET /api/plans` — 缺 `conversation_id`（**已修**）
- `GET /api/plans` — `task_status` 列不存在（**已修**）
- `GET /api/user/{id}/learning-report` — 同上
- `GET /api/reading-milestone` — 同上
- `POST /api/k12/init` — 之前不写 conversation_plans（**已修**）

**但这些断裂在测试中零感知**，因为测试直接读 DB、不经过 HTTP 序列化。

## 修复方向

测试范式应改为：

```
操作 → HTTP 请求 → API handler → DB → HTTP 响应 → 断言
```

而非现在的：

```
操作 → 直接调内部函数 → DB → 直接 SQL 查询 → 断言
```

具体来说，`cp2_turn()` 不应直接调 `caller.generate()` 和 `insert_turn()`，而应发 `POST /api/chat` WebSocket 消息。`get_plan()` 不应直接 `conn.query_row()`，而应发 `GET /api/plans?conversation_id=xxx` 并断言响应 JSON。

这需要引入 HTTP 客户端到测试（axum::test 或 reqwest），把每个断言点改为对 API 响应的断言。
