# CoEvo API 文档

Base URL: `http://localhost:8080`

---

## 健康检查

### `GET /health`

**Response 200:**
```json
"CoEvo API -- OK"
```

---

## 认证

### `POST /api/auth/register`

注册新用户。

**Request:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response 200:**
```json
{
  "user_id": "uuid",
  "token": "sha256_token"
}
```

**Response 400:**
```json
{
  "error": "Username already exists"
}
```

### `POST /api/auth/login`

用户登录。

**Request:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response 200:**
```json
{
  "user_id": "uuid",
  "token": "sha256_token"
}
```

**Response 401:**
```json
{
  "error": "Invalid credentials"
}
```

---

## 聊天

### `POST /api/chat`

非流式聊天（一次请求返回完整回复 + 概念提取）。

**Request:**
```json
{
  "user_id": "string",
  "conversation_id": "conv_1712345678000",
  "message": "用户消息"
}
```

**Response 200:**
```json
{
  "reply": "AI 回复内容",
  "concepts": ["概念1", "概念2"],
  "direct_card": false
}
```

### `WS /ws`

WebSocket 流式聊天（推荐）。连接后发送 JSON，接收多事件流。

**Client → Server:**
```json
{
  "user_id": "string",
  "conversation_id": "conv_1712345678000",
  "message": "用户消息"
}
```

**Server → Client (HotPath，按序):**
```
{"type":"thinking"}
{"type":"token","content":"逐字"}
{"type":"planning"}               // 计划生成中（替代 token）
{"type":"done","reply":"完整回复"}
{"type":"plan_updated"}            // 学习计划已更新
```

**Server → Client (ColdPath，异步):**
```
{"type":"candidates","candidates":[{"front":"...","back":"...","source_sentence":"...","domain":"..."}]}
```

---

## 复习

### `GET /api/review/due`

获取到期卡片。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{
  "cards": [
    {
      "id": "uuid",
      "front": "概念",
      "back": "解释",
      "domain": "general",
      "card_type": "concept",
      "source_sentence": "原文",
      "state": 0,
      "reps": 0,
      "lapses": 0
    }
  ],
  "total_due": 5,
  "has_more": false
}
```

### `POST /api/review/submit`

提交复习评分。

**Request:**
```json
{
  "user_id": "string",
  "card_id": "uuid",
  "rating": 3,
  "verification_type": "spelling",
  "verification_result": "pass"
}
```

**Response 200:**
```json
{
  "status": "ok",
  "achievements": [
    {"key": "first_card", "name": "初识", "icon": "🌟"}
  ]
}
```

### `POST /api/review/verify`

AI 生成验证问题。

**Request:**
```json
{
  "card_id": "uuid",
  "front": "概念",
  "back": "解释"
}
```

**Response 200:**
```json
{
  "questions": [
    {"question": "什么是...?", "expected_answer": "..."}
  ]
}
```

### `POST /api/review/judge`

AI 批量评判用户答案。

**Request:**
```json
{
  "card_id": "uuid",
  "questions": [
    {"question": "?", "expected_answer": "...", "user_answer": "..."}
  ]
}
```

**Response 200:**
```json
{
  "results": [
    {"correct": true, "feedback": "正确"}
  ],
  "total_correct": 1
}
```

---

## 卡片

### `POST /api/cards/batch-create`

批量制卡（来自对话中的候选概念）。

**Request:**
```json
{
  "user_id": "string",
  "candidates": [
    {
      "front": "概念",
      "back": "解释",
      "source_sentence": "原文",
      "domain": "general"
    }
  ]
}
```

**Response 200:**
```json
{
  "created": 2,
  "duplicates": 1,
  "achievements": []
}
```

### `GET /api/cards/all`

查询用户所有卡片（支持搜索/过滤/排序）。

**Query Params:**
- `user_id` (required)
- `q` 搜索关键词
- `state` 状态过滤 (0-3)
- `domain` 领域过滤
- `sort` 排序: `state` | `front` | `created` | `due`

**Response 200:**
```json
{
  "cards": [
    {
      "id": "uuid",
      "front": "...",
      "back": "...",
      "domain": "general",
      "card_type": "concept",
      "source_sentence": "...",
      "created_at": 1712345678,
      "state": 0,
      "difficulty": 5.0,
      "due": 1712345678,
      "reps": 0,
      "lapses": 0
    }
  ],
  "total": 12,
  "state_counts": [5, 3, 2, 0],
  "domains": ["general", "tech"]
}
```

---

## 跳过概念

### `POST /api/cards/skip`

跳过某个概念。

**Request:**
```json
{
  "user_id": "string",
  "front": "概念名",
  "source_text": "来源对话"
}
```

**Response 200:**
```json
{"skipped_id": "uuid"}
```

### `GET /api/cards/skipped`

获取已跳过的概念列表。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{
  "skipped": [
    {
      "id": "uuid",
      "front": "概念",
      "domain": "general",
      "source_text": "来源",
      "skipped_at": 1712345678
    }
  ]
}
```

### `DELETE /api/cards/skipped/{skip_id}`

取消跳过。

**Response 200:**
```json
{"status": "removed"}
```

---

## 对话历史

### `GET /api/history`

获取对话列表或指定对话的轮次。

**Query Params:**
- `user_id` (required)
- `conversation_id` (可选) — 指定对话则返回轮次
- `limit` (默认 50, 最大 200)

**无 conversation_id（对话列表）:**
```json
{
  "user_id": "...",
  "conversations": [
    {
      "id": "conv_...",
      "turn_count": 12,
      "started_at": "2026-05-07T18:00:00+00:00",
      "title": "第一条消息..."
    }
  ],
  "count": 5
}
```

**有 conversation_id（轮次列表）:**
```json
{
  "user_id": "...",
  "turns": [
    {"id": "turn_uuid", "role": "user", "content": "...", "created_at": "..."},
    {"id": "turn_uuid", "role": "assistant", "content": "...", "created_at": "..."}
  ]
}
```

---

## 用户

### `GET /api/user/{user_id}/profile`

用户统计与成就。

**Response 200:**
```json
{
  "user_id": "...",
  "stats": {
    "total_cards": 12,
    "total_reviews": 47,
    "streak_days": 5,
    "domains_covered": 3,
    "today_reviews": 3
  },
  "achievements": [
    {
      "key": "first_card",
      "name": "初识",
      "icon": "🌟",
      "unlocked_at": "2026-05-07T..."
    }
  ]
}
```

---

## 状态码速查

| 状态码 | 含义 |
|:--|:--|
| 200 | 成功 |
| 400 | 请求错误（注册重名等） |
| 401 | 认证失败 |
| 404 | 资源不存在 |
| 500 | 服务器错误（LLM 不可用、DB 错误等） |

---

## 学习计划

### `GET /api/plans`

获取学习计划列表。

**Query Params:**
- `conversation_id` (优先) 或 `user_id` (回退)

**Response 200:**
```json
{
  "plans": [
    {
      "id": "uuid",
      "goal": "AI入门",
      "domain": "linear_algebra",
      "mode": "structured",
      "plan": {
        "stages": [
          {"name": "阶段一", "status": "in_progress", "tasks": [...]}
        ],
        "completed_concepts": [...]
      },
      "created_at": "2026-05-09T...",
      "updated_at": "2026-05-09T..."
    }
  ]
}
```

### `POST /api/plans`

创建或更新学习计划。

**Request:**
```json
{
  "user_id": "string",
  "goal": "AI入门",
  "domain": "linear_algebra",
  "plan_json": {
    "stages": [
      {"name": "...", "status": "in_progress", "tasks": [...]}
    ]
  }
}
```

**Response 200:**
```json
{"id": "uuid", "status": "ok"}
```

### `DELETE /api/plans/{plan_id}`

软删除学习计划。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{"status": "ok"}
```
