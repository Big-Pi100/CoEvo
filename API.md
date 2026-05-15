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

非流式聊天（一次请求返回完整回复 + 概念提取）。需要鉴权和有效订阅。

**Request Headers:**
- `Authorization: Bearer <token>` (required)

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
  "candidates": [
    {"front": "概念1", "back": "解释1", "source_sentence": "原文", "domain": "general"}
  ],
  "achievements": []
}
```

**Response 200 (订阅错误):**
```json
{"error": "subscription_required"}
```
或
```json
{"error": "subscription_expired"}
```

**Response 401:**
```json
{"error": "Missing or invalid Authorization header"}
```

> `candidates` 为概念提取结果（ColdPath 异步），REST 端点中通常为空数组；概念候选通过 WebSocket `candidates` 事件异步推送。

### `WS /ws`

WebSocket 流式聊天（推荐）。连接后发送 JSON，接收多事件流。
首条消息必须携带 `token` 用于鉴权，后续消息可省略。

**Client → Server (首条消息，含 token):**
```json
{
  "user_id": "string",
  "conversation_id": "conv_1712345678000",
  "message": "用户消息",
  "token": "sha256_token"
}
```

**Client → Server (后续消息，token 可选):**
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

**Server → Client (鉴权/订阅错误):**
```
{"type":"error","content":"missing_token"}
{"type":"error","content":"invalid_token"}
{"type":"error","content":"subscription_required"}
{"type":"error","content":"subscription_expired"}
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
  "verification_result": "pass",
  "details": "{\"questions\":[...]}"
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
  "total_correct": 1,
  "total": 3
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
  "created": ["card_id_1", "card_id_2"],
  "duplicates": ["已存在的概念名"],
  "errors": ["创建失败的原因"],
  "achievements": []
}
```

> `created` 为成功创建的卡片 ID 数组；`duplicates` 为与已有卡片重复的前端名数组；`errors` 为创建失败的错误信息数组。

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
  "state_counts": {
    "new": 5,
    "learning": 3,
    "review": 2,
    "relearning": 0
  },
  "domains": ["general", "tech"]
}
```

### `GET /api/cards/{card_id}/last-review`

获取某张卡片的最近一次考试详情。

**Response 200:**
```json
{
  "id": "review_log_id",
  "rating": 3,
  "verification_type": "ai_dialogue",
  "verification_result": "pass",
  "details": [{"question": "...", "expected_answer": "...", "user_answer": "..."}],
  "reviewed_at": 1712345678
}
```

**Response 404:**
```json
{"error": "No review found"}
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
  "domain": "general",
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

取消跳过并恢复为卡片（读取跳过记录 → 重建卡片+记忆状态 → 删除跳过记录）。

**Response 200:**
```json
{"status": "restored", "card_id": "uuid"}
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
  "display_name": "昵称",
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

### `GET /api/user/{user_id}/learning-report`

学习报告（Phase 3 家长看板）。汇总计划进度、成就分 tier 统计、学习统计、考核数据。

**Response 200:**
```json
{
  "plans": [
    {
      "goal": "AI入门",
      "mode": "structured",
      "current_stage": "阶段一",
      "total_tasks": 5,
      "done_tasks": 2,
      "progress_pct": "40%",
      "updated_at": "2026-05-13T..."
    }
  ],
  "achievements_by_tier": [
    {"tier": "bronze", "count": 3},
    {"tier": "silver", "count": 1}
  ],
  "stats": {
    "total_cards": 12,
    "total_reviews": 47,
    "total_conversation_turns": 120,
    "streak_days": 5
  },
  "assessment": {
    "tasks_passed": 3
  }
}
```

---

### `GET /api/user/{user_id}/activity`

活跃度热力图数据。

**Query Params:**
- `days` (可选，默认 90) — 回溯天数

**Response 200:**
```json
{
  "days": [
    {
      "date": "2026-05-13",
      "score": 8,
      "reviews": 5,
      "conversations": 8,
      "cards": 3
    }
  ]
}
```

> `score = reviews + conversations + cards`，前端可按 score 映射颜色深浅。

---

### `GET /api/user/{user_id}/weekly-report`

本周学习周报。

**Response 200:**
```json
{
  "week_start": "2026-05-07",
  "week_end": "2026-05-13",
  "new_cards": 5,
  "reviews": 23,
  "conversation_turns": 45,
  "new_achievements": 2,
  "active_plan": "AI入门"
}
```

---

### `POST /api/user/{user_id}/display-name`

更新用户显示名称。

**Request:**
```json
{"display_name": "新昵称"}
```

**Response 200:**
```json
{"status": "ok", "display_name": "新昵称"}
```

**Response 400:**
```json
{"error": "display_name cannot be empty"}
```

---

### `POST /api/user/{user_id}/avatar`

上传头像（multipart，max 5MB）。上传后文件保存为 `<user_id>.png`。

**Request**: `multipart/form-data`，单文件字段。

**Response 200:**
```json
{"status": "ok", "url": "/api/user/{user_id}/avatar"}
```

**Response 400:**
```json
{"error": "File too large (max 5MB)"}
```

### `GET /api/user/{user_id}/avatar`

获取头像图片。

**Response 200**: `image/png` 二进制数据

**Response 404**: `"No avatar"`

---

### `GET /api/user/{user_id}/preferences`

获取用户偏好键值对。

**Response 200:**
```json
{
  "tts_speed": "1.0",
  "tts_enabled": "true"
}
```

### `PUT /api/user/{user_id}/preferences`

批量更新用户偏好。

**Request:**
```json
{
  "tts_speed": "1.2",
  "tts_enabled": "false"
}
```

**Response 200:**
```json
{"status": "ok"}
```

---

## 语音识别

### `POST /api/stt`

语音转文字（STT）。接收音频字节流，经 ffmpeg 转码后调用科大讯飞 API。

**Request**: 原始音频 bytes（M4A/AAC），通过 HTTP Body 发送。

**Response 200:**
```json
{"text": "识别出的文字"}
```

**Response 500:**
```json
{"error": "iFlytek credentials not configured"}
```

> 需要配置环境变量 `IFLYTEK_APPID`、`IFLYTEK_API_KEY`、`IFLYTEK_API_SECRET`。

---

## 管理

### `GET /api/admin/users`

管理员查询用户列表。

**Query Params:**
- `q` (required) — 搜索关键词（匹配 user_id 或 username）

**Request Headers:**
- `x-admin-key` (required) — 管理员密钥，对应环境变量 `COEVO_ADMIN_KEY`

**Response 200:**
```json
{
  "users": [
    {
      "user_id": "uuid",
      "username": "test",
      "created_at": "2026-05-07T...",
      "subscription_expires": "2026-12-31"
    }
  ]
}
```

**Response 401:**
```json
{"error": "unauthorized"}
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
