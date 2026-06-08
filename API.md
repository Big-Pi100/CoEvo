# CoEvo API 文档

Base URL: `http://localhost:8080`

认证方式：普通用户 Bearer Token（`Authorization: Bearer <token>`），管理员 x-admin-key 或 Admin Bearer Token。

---

## 一、健康检查

### `GET /health`

无需认证。

**Response 200:**
```
CoEvo API — OK
```

---

## 二、用户认证 (Auth)

### `POST /api/auth/register`

注册新用户。

**限流:** 5 次/分钟/IP（滑动窗口，重启重置）

**Request:**
```json
{
  "username": "string",
  "password": "string",
  "real_name": "string (可选)",
  "phone": "string (可选)"
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

---

### `POST /api/auth/login`

用户登录。登录后自动踢掉同一用户的其他 WebSocket 连接（单设备登录）。

**限流:** 10 次/分钟/IP（滑动窗口，重启重置）

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

### `POST /api/auth/verify`

验证存储的 Token 是否仍然有效（用于 App 重启时的会话恢复）。

**Request:**
```json
{
  "user_id": "string",
  "token": "string"
}
```

**Response 200 (有效):**
```json
{
  "valid": true
}
```

**Response 200 (无效):**
```json
{
  "valid": false
}
```

---

## 三、聊天 (WebSocket)

### `WS /ws`

WebSocket 流式聊天（前端主要聊天方式）。首条消息必须携带 `token` 用于鉴权，后续消息可省略 Token。WebSocket 心跳默认 60 秒 Ping 帧。

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

| 类型 | 说明 |
|------|------|
| `{"type":"thinking"}` | AI 开始思考 |
| `{"type":"token","content":"逐字输出"}` | Token 流式输出 |
| `{"type":"planning"}` | 计划生成中（替代 token） |
| `{"type":"done","reply":"完整回复"}` | 生成完毕，含完整回复 |
| `{"type":"plan_updated"}` | 学习计划已更新（ColdPath） |

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
{"type":"achievements","achievements":[{"key":"...","name":"...","icon":"..."}]}
{"type":"kicked","content":"您的账号已在其他设备登录，当前连接已断开"}
```

**ColdPath 1**: 后台概念提取 → 创建 pending 卡片（异步推送 `candidates`）
**ColdPath 2**: 后台分析对话进度 → 自动更新 plan（推送 `plan_updated` 和 `achievements`）

---

## 四、间隔重复 / 复习 (Review / Spaced Repetition)

### `GET /api/review/due`

获取到期卡片（需 Bearer Token 认证）。

**Query Params:**
- `user_id` (required) — 用户 ID
- `conversation_id` (optional) — 限定会话
- `limit` (optional, default 20) — 每页数量
- `offset` (optional, default 0) — 分页偏移

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

---

### `POST /api/review/submit`

提交复习评分（含 FSRS 调度更新 + 成就检测）。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
  "card_id": "uuid",
  "rating": 3,
  "verification_type": "spelling",
  "verification_result": "pass",
  "details": "[{\"question\":\"...\",\"correct\":true,\"feedback\":\"...\"}]"
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

---

### `POST /api/review/verify`

AI 生成验证问题（注入最近 10 轮考题历史避免重复出题）。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
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

**Response 500:**
```json
{
  "error": "Failed to parse questions",
  "raw": "LLM 原始回复"
}
```

---

### `POST /api/review/judge`

AI 批量评判用户答案（3 题）。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
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
  "total_correct": 2,
  "total": 3
}
```

**Response 500:**
```json
{
  "error": "LLM: ..."
}
```

---

### `GET /api/review/cards-by-progress`

按学习计划进度分组获取卡片。

**Query Params:**
- `user_id` (required)

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
      "plan_id": "uuid",
      "task_key": "math_g7_algebra",
      "task_status": "in_progress",
      "plan_goal": "代数基础",
      "plan_subject": "math",
      "plan_grade_band": "g7-9"
    }
  ],
  "plans": [
    {"plan_id": "uuid", "goal": "...", "subject": "...", "grade_band": "..."}
  ],
  "count": 42
}
```

---

## 五、卡片管理 (Cards)

### `PATCH /api/cards/status`

更新单张卡片状态。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
  "card_id": "string",
  "status": "active|pending|skipped|archived"
}
```

**Response 200:**
```json
{
  "status": "ok"
}
```

---

### `PATCH /api/cards/batch-status`

批量更新卡片状态。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
  "card_ids": ["id1", "id2"],
  "status": "active|pending|skipped|archived"
}
```

**Response 200:**
```json
{
  "updated": 2,
  "status": "ok"
}
```

---

### `GET /api/cards/all`

查询用户所有卡片（支持搜索/过滤/排序）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)
- `q` (optional) — 搜索关键词（匹配 front）
- `state` (optional) — FSRS 状态过滤 (0-3)
- `subject` (optional) — 科目过滤
- `sort` (optional) — 排序：`front` | `created` | `state` | `due`

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
      "created_at": 1712345678,
      "state": 0,
      "difficulty": 5.0,
      "due": 1712345678,
      "reps": 0,
      "lapses": 0,
      "conversation_id": "conv_..."
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

---

### `GET /api/cards/by-plan`

按学习计划分组获取卡片（支持惰性加载）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)
- `conversation_id` (optional) — 指定则加载该计划的卡片列表
- `limit` (optional, default 20, max 500)
- `offset` (optional, default 0)
- `sort` (optional) — `front` (默认) | `due` | `created`

**Response 200:**
```json
{
  "plans": [
    {
      "id": "plan_uuid",
      "goal": "代数基础",
      "grade_band": "g7-9",
      "conversation_id": "conv_...",
      "cards": [ /* 仅在指定 conversation_id 时返回卡片数组 */ ],
      "card_count": 25
    }
  ],
  "total_plans": 3,
  "has_more": false
}
```

---

### `GET /api/cards/search`

搜索卡片（关键词匹配）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)
- `q` (required) — 搜索关键词
- `limit` (optional, default 20, max 200)
- `offset` (optional, default 0)

**Response 200:**
```json
{
  "cards": [ /* 同 cards/all 返回格式 */ ],
  "total": 12,
  "has_more": false
}
```

---

### `GET /api/cards/{card_id}/last-review`

获取某张卡片的最近一次评审详情。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

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

## 六、对话历史 (History)

### `GET /api/history`

获取对话列表或指定对话的轮次。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)
- `conversation_id` (optional) — 指定对话则返回轮次
- `limit` (default 50, max 200)
- `offset` (optional, default 0)
- `include_deleted` (optional) — `"only"`=仅已删除, `"true"`=全部, 默认仅活跃

**无 conversation_id（对话列表）:**
```json
{
  "user_id": "...",
  "conversations": [
    {
      "id": "conv_...",
      "turn_count": 12,
      "started_at": "2026-05-07T18:00:00+00:00",
      "deleted_at": null,
      "title": "第一条消息..."
    }
  ],
  "count": 5
}
```

**有 conversation_id（轮次列表，DESC 排序）:**
```json
{
  "conversation_id": "conv_...",
  "turns": [
    {"id": "turn_uuid", "role": "assistant", "content": "...", "created_at": "..."},
    {"id": "turn_uuid", "role": "user", "content": "...", "created_at": "..."}
  ],
  "count": 2,
  "total": 47
}
```

---

## 七、对话管理 (Conversations)

### `DELETE /api/conversations/{conv_id}`

软删除对话（移至回收站）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{"status": "ok", "deleted_at": 1712345678}
```

---

### `POST /api/conversations/{conv_id}/restore`

恢复已删除的对话。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{"status": "ok"}
```

---

### `DELETE /api/conversations/{conv_id}/permanent`

物理删除对话（不可恢复，同时删除关联的 conversation_turns）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{"status": "ok"}
```

---

## 八、用户配置 (User Profile)

### `GET /api/user/{user_id}/profile`

用户统计、成就和 CEFR 词汇进度。需 Bearer Token 认证。

**Response 200:**
```json
{
  "user_id": "...",
  "display_name": "昵称",
  "real_name": "张三 (PII 解密后)",
  "phone": "13800138000 (PII 解密后)",
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
      "tier": "bronze",
      "category": "seed",
      "color": "#CD7F32",
      "description": "创建第一张卡片",
      "unlocked_at": "2026-05-07T..."
    }
  ],
  "cefr_stats": [
    {"level": "A1", "max_count": 1401, "count": 45},
    {"level": "A2", "max_count": 1797, "count": 30}
  ]
}
```

---

### `PUT /api/user/{user_id}/profile`

更新用户资料（real_name / phone）。需 Bearer Token 认证。

**Request:**
```json
{
  "real_name": "张三",
  "phone": "13800138000"
}
```
两个字段均可选，仅更新提供的字段。

**Response 200:**
```json
{"status": "ok"}
```

**Response 409:**
```json
{"error": "该手机号已被其他用户占用"}
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

上传头像（multipart，max 5MB）。上传后保存为 `<user_id>.png`。

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

### `GET /api/user/{user_id}/achievements-all`

获取所有成就定义（含进度、中英文名称、分 category 分组）。需 Bearer Token 认证。

**Response 200:**
```json
{
  "user_id": "...",
  "categories": [
    {
      "category": "seed",
      "label": "启程",
      "achievements": [
        {
          "id": "first_card",
          "name": "初识",
          "name_en": "First Card",
          "description": "创建第一张卡片",
          "description_en": "Create your first card",
          "icon": "🌟",
          "color": "#CD7F32",
          "tier": "bronze",
          "hidden": false,
          "unlocked": true,
          "unlocked_at": "2026-05-07T...",
          "progress_pct": 1.0,
          "progress_label": "1/1 张卡片"
        }
      ]
    }
  ]
}
```

**Category 列表:** `seed`(启程), `consistency`(坚持), `knowledge`(博学), `exploration`(探索), `mastery`(精进), `special`(特殊)

---

### `GET /api/user/{user_id}/preferences`

获取用户偏好键值对。

**Response 200:**
```json
{
  "tts_speed": "1.0",
  "tts_enabled": "true",
  "tts_voice": "zh-CN-XiaoxiaoNeural"
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

### `POST /api/user/bind-lookup`

监护人绑定查询（SHA-256 匹配，不暴露明文）。限流 5 次/分钟/IP。

**Request:**
```json
{
  "real_name": "张三",
  "phone": "13800138000"
}
```

**Response 200 (找到):**
```json
{"found": true, "user_id": "uuid", "display_name": "昵称"}
```

**Response 200 (未找到):**
```json
{"found": false}
```

---

## 九、学习计划 (Plans)

### `GET /api/plans`

获取学习计划列表（合并 `user_plan_progress` 状态，附加每个 plan 的 due 卡片数）。

**Query Params:**
- `user_id` (可选，建议提供) — 筛选用户计划
- `conversation_id` (可选) — 按会话筛选

**Response 200:**
```json
{
  "plans": [
    {
      "id": "uuid",
      "conversation_id": "conv_...",
      "goal": "AI入门",
      "subject": null,
      "grade_band": null,
      "domain": "linear_algebra",
      "mode": "structured",
      "plan": {
        "stages": [
          {"name": "阶段一", "tasks": [{"name": "...", "task_key": "...", "status": "in_progress", ...}]}
        ],
        "completed_concepts": []
      },
      "created_at": "2026-05-09T...",
      "updated_at": "2026-05-09T...",
      "due_card_count": 5
    }
  ]
}
```

---

## 十、学习报告 (Dashboard)

### `GET /api/user/{user_id}/learning-report`

学习报告（家长看板）。汇总计划进度、成就分 tier 统计、学习统计、考核数据。

**Response 200:**
```json
{
  "plans": [
    {
      "goal": "AI入门",
      "grade_band": null,
      "subject": null,
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

## 十一、K12 结构化学习

### `POST /api/k12/init`

初始化 K12 学科的结构化学习。创建新对话 + 加载预置课程计划 + 写入预置概念卡片。支持重复请求自动恢复（resume）。

需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
  "subject": "math",
  "grade_band": "g7-9"
}
```

**Response 200 (新建):**
```json
{
  "conversation_id": "uuid",
  "plan": {"goal": "代数基础", "stages": [...]}
}
```

**Response 200 (恢复已有):**
```json
{
  "conversation_id": "uuid",
  "plan": {"goal": "...", "stages": [...]},
  "resumed": true
}
```

---

### `GET /api/k12/progress`

获取 K12 学习进度（各学科完成情况）。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{
  "progress": [
    {
      "goal": "代数基础",
      "grade_band": "g7-9",
      "total_tasks": 20,
      "done_tasks": 7,
      "total_cards": 136,
      "mastered_cards": 45,
      "reviewed_cards": 60,
      "progress_pct": 35.0,
      "started_at": "2026-05-09T..."
    }
  ],
  "total": 1
}
```

---

### `GET /api/k12/reading/{conv_id}/current-card`

获取当前阅读模式课文的完整卡片数据。需 Bearer Token 认证。

**Query Params:**
- `user_id` (required)

**Response 200:**
```json
{
  "current_card": {
    "id": "reading_primary_我是中国人",
    "card_type": "reading",
    "front": "课文标题",
    "back": "课文全文...",
    "full_text": "课文全文",
    "translation": "课文翻译",
    "key_sentence_patterns": "...",
    "key_grammar": "...",
    "author": "作者",
    "famous_lines": "名句",
    "level": "primary",
    "tags": ["chinese", "g1-2"]
  }
}
```

**Response 200（无课文卡片）:**
```json
{
  "current_card": null
}
```

---

### `POST /api/k12/quiz/submit`

提交 K12 题库答案。需 Bearer Token 认证。

**Request:**
```json
{
  "user_id": "string",
  "conversation_id": "string (可选)",
  "task_name": "string",
  "answers": [
    {"quiz_id": "string", "answer": "string"}
  ]
}
```

**Response 200:**
```json
{
  "correct": 3,
  "total": 5,
  "pass_rate": 0.60,
  "passed": false,
  "details": [
    {"quiz_id": "q1", "correct": true, "expected": "正确答案"},
    {"quiz_id": "q2", "correct": false, "expected": "正确答案"}
  ]
}
```

---

## 十二、翻译验证

### `POST /api/verify-translation`

正向语义验证 — LLM 判断用户翻译是否等价于正确答案（用于语言类复习）。LLM 失败时 fallback 到简单关键词匹配。

**Request:**
```json
{
  "front": "hello",
  "back": "你好",
  "user_input": "你好吗"
}
```

**Response 200:**
```json
{"result": "pass|fail"}
```

---

## 十三、管理后台 (Admin)

管理后台认证方式：
- `x-admin-key` Header（对应环境变量 `COEVO_ADMIN_KEY`）
- 或 `Authorization: Bearer <admin_password_hash>`（从 `admin_users` 表验证）

### 13.1 登录 / 注册 / 仪表盘

---

#### `POST /api/admin/login`

管理员登录。

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
  "token": "password_hash",
  "role": "super|service|guardian|tutor",
  "admin_id": "uuid"
}
```

**Response 401:** `{"error": "invalid_credentials"}`
**Response 403:** `{"error": "pending_approval"}` 或 `{"error": "rejected"}`

---

#### `POST /api/admin/register`

管理员注册（一直返回 400，自助注册已禁用）。

**Response 400:**
```json
{"error": "self_register_disabled_contact_admin"}
```

---

#### `GET /api/admin/dashboard`

管理员仪表盘统计。

**Response 200:**
```json
{
  "total_users": 128,
  "total_cards": 5000,
  "today_new_users": 3,
  "today_active_users": 15,
  "today_reviews": 120,
  "expiring_soon": [
    {"user_id": "uuid", "username": "test", "display_name": "昵称", "expires": "2026-06-15"}
  ]
}
```

---

### 13.2 用户管理

---

#### `GET /api/admin/users`

查询用户列表。限流 30 次/分钟。

**Query Params:**
- `q` (required) — 搜索关键词（匹配 user_id / username / display_name）
- `page` (optional, default 1)
- `sort` (optional) — `"expiring"` 按过期时间排序
- `include_deleted` (optional) — 是否包含已删除用户

**Response 200:**
```json
{
  "users": [
    {
      "user_id": "uuid",
      "username": "test",
      "display_name": "昵称",
      "real_name": "张三 (super 可见明文)",
      "real_name_masked": "张*",
      "phone": "13800138000 (super 可见明文)",
      "phone_masked": "138****0000",
      "created_at": "2026-05-07T...",
      "streak_days": 5,
      "deleted_at": null,
      "card_count": 12,
      "review_count": 47,
      "subscription_expires": "2026-12-31",
      "guardian_id": null,
      "guardian_name": null,
      "guardian_phone_masked": null,
      "tutor_id": null,
      "tutor_name": null,
      "tutor_phone_masked": null
    }
  ],
  "total": 50,
  "page": 1,
  "total_pages": 3
}
```

---

#### `GET /api/admin/users/expiring`

获取即将过期的用户。

**Query Params:**
- `range` (optional) — `"today"` | `"week"` (默认) | `"month"`

**Response 200:**
```json
{
  "users": [
    {"user_id": "uuid", "username": "test", "display_name": "昵称", "expires": "2026-06-10"}
  ]
}
```

---

#### `GET /api/admin/users/export`

导出用户列表 CSV。

**Query Params:**
- `q` (required) — 搜索关键词

**Response 200:** Content-Type: `text/csv`

---

#### `POST /api/admin/users/batch-subscription`

批量设置订阅（仅 super 角色）。

**Request:**
```json
{
  "user_ids": ["uuid1", "uuid2"],
  "days": 365
}
```

**Response 200:**
```json
{"status": "ok", "count": 2}
```

---

#### `GET /api/admin/users/{user_id}`

获取用户详情。

**Response 200:**
```json
{
  "user_id": "uuid",
  "username": "test",
  "display_name": "昵称",
  "real_name": "张三",
  "phone": "13800138000",
  "created_at": "2026-05-07T...",
  "streak_days": 5,
  "last_active_date": "2026-06-07",
  "card_count": 12,
  "review_count": 47,
  "subscription_expires": "2026-12-31"
}
```

**Response 404:** `{"error": "not_found"}`

---

#### `DELETE /api/admin/users/{user_id}`

软删除用户（仅 super 角色）。

**Response 200:**
```json
{"status": "deleted", "deleted_at": 1712345678}
```

---

#### `DELETE /api/admin/users/{user_id}/hard-delete`

永久删除用户（归档到 ndjson）。仅 super 角色。

**Response 200:**
```json
{"status": "hard_deleted", "archive_id": "uuid"}
```

---

#### `POST /api/admin/users/{user_id}/restore`

恢复已删除用户。仅 super 角色。

**Response 200:**
```json
{"status": "restored"}
```

---

#### `POST /api/admin/users/{user_id}/reveal-phone`

两步揭看手机号。首次返回脱敏，二次确认返回明文。限流 20 次/分钟。

**Query Params:**
- `full` (optional) — `true` 返回明文，`false` 返回脱敏（默认 `false`）

**Response 200 (脱敏):**
```json
{"phone": "138****0000", "full": false}
```

**Response 200 (明文):**
```json
{"phone": "13800138000", "full": true}
```

**Response 404:** `{"error": "no_phone"}`

---

#### `PUT /api/admin/users/{user_id}/subscription`

设置用户订阅过期时间。super 或 service（需 `set_expiry` 权限）。

**Request:**
```json
{
  "subscription_expires": "2026-12-31",
  "days": 365
}
```

**Response 200 (直接生效):**
```json
{"status": "ok"}
```

**Response 200 (创建审批请求):**
```json
{"request_id": "uuid", "status": "pending"}
```

---

#### `POST /api/admin/users/{user_id}/quick-extend`

快速延期（同 subscription 逻辑，接口一致）。

**Request:**
```json
{
  "subscription_expires": "2026-12-31",
  "days": 365
}
```

**Response 200:**
```json
{"status": "ok"}
```
或
```json
{"request_id": "uuid", "status": "pending"}
```

---

### 13.3 订阅审批 (Subscription Requests)

---

#### `GET /api/admin/subscription-requests`

获取订阅审批请求列表。

**Query Params:**
- `status` (optional) — `"pending"` | `"approved"` | `"rejected"`

**Response 200:**
```json
{
  "requests": [
    {
      "id": "uuid",
      "target_user_id": "uuid",
      "requested_by": "admin_id",
      "package": "365d",
      "channel": "admin",
      "note": null,
      "status": "pending",
      "reject_reason": null,
      "requested_at": "2026-06-01T...",
      "reviewed_at": null,
      "target_username": "test",
      "requester_name": "管理员"
    }
  ]
}
```

---

#### `POST /api/admin/subscription-requests`

创建订阅审批请求。

**Request:**
```json
{
  "target_user_id": "uuid",
  "package": "365d",
  "channel": "admin",
  "note": "延期原因"
}
```

**Response 200:**
```json
{"request_id": "uuid", "status": "pending"}
```

---

#### `POST /api/admin/subscription-requests/{req_id}/approve`

审批通过。

**Response 200:**
```json
{"status": "approved"}
```

---

#### `POST /api/admin/subscription-requests/{req_id}/reject`

审批拒绝。

**Request:**
```json
{"reject_reason": "原因"}
```

**Response 200:**
```json
{"status": "rejected"}
```

---

### 13.4 管理员账号管理

---

#### `GET /api/admin/admins`

获取所有管理员列表。

**Response 200:**
```json
{
  "admins": [
    {
      "id": "uuid",
      "username": "admin",
      "role": "super|service",
      "status": "active|disabled|pending",
      "real_name": "张三",
      "phone": "13800138000",
      "registered_from": null,
      "created_at": "...",
      "approved_at": "...",
      "permissions": {}
    }
  ]
}
```

---

#### `POST /api/admin/admins`

创建管理员（仅 super 角色）。

**Request:**
```json
{
  "username": "string (≥5字符)",
  "password": "string (≥6字符)",
  "real_name": "string",
  "phone": "string",
  "role": "service|super"
}
```

**Response 200:**
```json
{"admin_id": "uuid", "status": "created"}
```

---

#### `POST /api/admin/admins/{admin_id}/approve`

审批通过管理员注册。

**Response 200:**
```json
{"status": "approved"}
```

---

#### `POST /api/admin/admins/{admin_id}/reject`

拒绝管理员注册。

**Request:**
```json
{"reject_reason": "原因"}
```

**Response 200:**
```json
{"status": "rejected"}
```

---

#### `POST /api/admin/admins/{admin_id}/password`

重置管理员密码（仅 super 角色）。

**Request:**
```json
{"password": "新密码"}
```

**Response 200:**
```json
{"status": "updated"}
```

---

#### `PUT /api/admin/admins/{admin_id}/permissions`

更新管理员权限（仅 super 角色）。

**Request:**
```json
{"permissions": {"can_reveal_phone": true, "set_expiry": false, ...}}
```

**Response 200:**
```json
{"status": "updated"}
```

---

#### `DELETE /api/admin/admins/{admin_id}/disable`

禁用管理员（仅 super 角色）。

**Response 200:**
```json
{"status": "disabled"}
```

---

#### `POST /api/admin/admins/{admin_id}/enable`

启用管理员。

**Response 200:**
```json
{"status": "active"}
```

---

#### `GET /api/admin/audit-log`

审计日志查询。

**Query Params:**
- `user_id` (optional)
- `admin_id` (optional)
- `action` (optional)
- `date_from` / `date_to` (optional)
- `q` (optional)

**Response 200:**
```json
{
  "logs": [
    {
      "id": "uuid",
      "admin_id": "uuid",
      "action": "reveal_phone",
      "target_user_id": "uuid",
      "detail": "步骤2：全量揭看",
      "created_at": "2026-06-01T...",
      "admin_name": "管理员名"
    }
  ]
}
```

---

### 13.5 家长/监护管理 (Guardian)

---

#### `GET /api/admin/guardian/students`

获取监护人绑定的学生列表。

**Response 200:**
```json
{
  "students": [
    {
      "student_user_id": "uuid",
      "display_name": "昵称",
      "real_name": "学生名",
      "phone_masked": "138****0000",
      "streak_days": 5,
      "last_active": "2026-06-07",
      "plan_total": 3,
      "plan_active_7d": 2,
      "plan_today": 1,
      "guardian_admin_id": "uuid (仅 tutor 角色返回)",
      "guardian_name": "监护人姓名 (仅 tutor 角色返回)",
      "guardian_phone_masked": "138****0000 (仅 tutor 角色返回)"
    }
  ]
}
```

---

#### `GET /api/admin/guardian/students/{student_id}` 或 `GET /api/admin/guardian/students/{student_id}/cards`

获取学生卡片列表。

**Response 200:**
```json
{
  "cards": [
    {"id": "uuid", "front": "...", "back": "...", "domain": "general", "state": 2, "reps": 3, "last_review": 1712345678, "conversation_id": "conv_..."}
  ]
}
```

---

#### `GET /api/admin/guardian/students/{student_id}/conversations`

获取学生对话列表。

**Response 200:**
```json
{
  "conversations": [
    {"id": "conv_...", "title": "第一条消息...", "started_at": "2026-06-01T...", "turn_count": 12}
  ]
}
```

---

#### `GET /api/admin/guardian/students/{student_id}/conversations/{conv_id}`

获取学生对话详情。

**Response 200:**
```json
{
  "turns": [
    {"role": "user|assistant", "content": "消息内容...", "created_at": "2026-06-01T..."}
  ]
}
```

---

#### `GET /api/admin/guardian/students/{student_id}/learning-summary`

获取学生学习摘要。

**Response 200:**
```json
{
  "overview": {
    "total_plans": 3,
    "active_7d": 2,
    "today_active": 1,
    "completed_plans": 1,
    "overall_progress": "45%",
    "overall_cards": "30%",
    "overall_score": 65,
    "attention": {
      "type": "scatter",
      "plans": 2,
      "detail": "同时开启了 2 个计划，均无明显推进"
    }
  },
  "plans": [
    {
      "plan_id": "uuid",
      "goal": "代数基础",
      "progress": {
        "total_tasks": 6,
        "done_tasks": 3,
        "current_stage": "一元一次方程",
        "current_task": "解方程练习"
      },
      "cards": {
        "total": 50,
        "mastered": 20,
        "learning": 10,
        "new": 15,
        "relearning": 5
      },
      "score": 65,
      "health": "attention",
      "reason": "该计划已完成 50% 但最近 7 天无活跃",
      "days_since_active": 8
    }
  ]
}
```

`health` 取值: `good` | `attention` | `stale` | `abandoned` | `not_started`

---

#### `POST /api/admin/guardian/bind`

监护人绑定学生。

**Request:**
```json
{
  "student_user_id": "uuid"
}
```

**Response 200:**
```json
{"success": true, "assignment_id": "uuid"}
```

---

#### `POST /api/admin/guardian/reveal-phone/{admin_id}`

获取监护人的完整手机号。

**Response 200:**
```json
{"phone": "13800138000"}
```

---

#### `GET /api/admin/guardian/assignments`

获取监护绑定关系列表。

**Response 200:**
```json
{
  "assignments": [
    {
      "id": "uuid",
      "guardian_admin_id": "uuid",
      "student_user_id": "uuid",
      "bind_key": "sha256_hash",
      "assigned_by": "uuid",
      "assigned_at": 1712345678,
      "is_active": true,
      "guardian_name": "监护人姓名",
      "student_display_name": "学生昵称",
      "student_real_name": "学生姓名"
    }
  ]
}
```

---

#### `POST /api/admin/guardian/assignments`

创建监护绑定关系。

**Request:**
```json
{
  "guardian_admin_id": "uuid",
  "student_user_id": "uuid"
}
```

**Response 200:**
```json
{"id": "uuid", "status": "created"}
```

---

#### `DELETE /api/admin/guardian/assignments/{assignment_id}`

解除监护绑定关系。

**Response 200:**
```json
{"status": "disabled"}
```

---

## 十四、状态码速查

| 状态码 | 含义 |
|:--|:--|
| 200 | 成功 |
| 400 | 请求错误（注册重名、参数不合法等） |
| 401 | 认证失败 / Token 无效 |
| 403 | 权限不足（如 pending_approval） |
| 404 | 资源不存在 |
| 409 | 冲突（如 phone_already_taken） |
| 429 | 限流（Rate limit exceeded） |
| 500 | 服务器错误（LLM 不可用、DB 错误等） |

---

## 十五、认证与限流汇总

| 端点 | 认证方式 | 限流 |
|------|----------|------|
| `/health` | 无 | 无 |
| `/api/auth/register` | 无 | 5 req/min/IP |
| `/api/auth/login` | 无 | 10 req/min/IP |
| `/api/auth/verify` | 无 | 无 |
| `/ws` | 首条消息 token | 无 |
| `/api/review/*` | Bearer Token | 无 |
| `/api/cards/*` | Bearer Token | 无 |
| `/api/history` | Bearer Token | 无 |
| `/api/conversations/*` | Bearer Token | 无 |
| `/api/user/*` | Bearer Token (部分端点无) | 无 (bind-lookup: 5 req/min/IP) |
| `/api/plans` | 无 | 无 |
| `/api/k12/*` | Bearer Token | 无 |
| `/api/verify-translation` | 无 | 无 |
| `/api/admin/*` | x-admin-key / Admin Bearer | admin/users: 30 req/min, reveal-phone: 20 req/min |

---

## 十六、端点索引

| 序号 | 方法 | 路径 | 分类 |
|:--:|:--|:--|:--|
| 1 | GET | `/health` | 健康检查 |
| 2 | POST | `/api/auth/register` | 认证 |
| 3 | POST | `/api/auth/login` | 认证 |
| 4 | POST | `/api/auth/verify` | 认证 |
| 5 | GET | `/ws` (WebSocket) | 聊天 |
| 6 | GET | `/api/review/due` | 复习 |
| 7 | POST | `/api/review/submit` | 复习 |
| 8 | POST | `/api/review/verify` | 复习 |
| 9 | POST | `/api/review/judge` | 复习 |
| 10 | GET | `/api/review/cards-by-progress` | 复习 |
| 11 | PATCH | `/api/cards/status` | 卡片 |
| 12 | PATCH | `/api/cards/batch-status` | 卡片 |
| 13 | GET | `/api/cards/all` | 卡片 |
| 14 | GET | `/api/cards/by-plan` | 卡片 |
| 15 | GET | `/api/cards/search` | 卡片 |
| 16 | GET | `/api/cards/{card_id}/last-review` | 卡片 |
| 17 | GET | `/api/history` | 历史 |
| 18 | DELETE | `/api/conversations/{conv_id}` | 对话 |
| 19 | POST | `/api/conversations/{conv_id}/restore` | 对话 |
| 20 | DELETE | `/api/conversations/{conv_id}/permanent` | 对话 |
| 21 | GET | `/api/user/{user_id}/profile` | 用户 |
| 22 | PUT | `/api/user/{user_id}/profile` | 用户 |
| 23 | POST | `/api/user/{user_id}/display-name` | 用户 |
| 24 | POST/GET | `/api/user/{user_id}/avatar` | 用户 |
| 25 | GET | `/api/user/{user_id}/achievements-all` | 用户 |
| 26 | GET/PUT | `/api/user/{user_id}/preferences` | 用户 |
| 27 | POST | `/api/user/bind-lookup` | 用户 |
| 28 | GET | `/api/plans` | 计划 |
| 29 | GET | `/api/user/{user_id}/learning-report` | 报告 |
| 30 | GET | `/api/user/{user_id}/activity` | 报告 |
| 31 | GET | `/api/user/{user_id}/weekly-report` | 报告 |
| 32 | POST | `/api/k12/init` | K12 |
| 33 | GET | `/api/k12/progress` | K12 |
| 34 | GET | `/api/k12/reading/{conv_id}/current-card` | K12 |
| 35 | POST | `/api/k12/quiz/submit` | K12 |
| 36 | POST | `/api/verify-translation` | 翻译 |
| 37 | POST | `/api/admin/login` | Admin |
| 38 | POST | `/api/admin/register` | Admin |
| 39 | GET | `/api/admin/dashboard` | Admin |
| 40 | GET | `/api/admin/users` | Admin |
| 41 | GET | `/api/admin/users/expiring` | Admin |
| 42 | GET | `/api/admin/users/export` | Admin |
| 43 | POST | `/api/admin/users/batch-subscription` | Admin |
| 44 | GET | `/api/admin/users/{user_id}` | Admin |
| 45 | DELETE | `/api/admin/users/{user_id}` | Admin |
| 46 | DELETE | `/api/admin/users/{user_id}/hard-delete` | Admin |
| 47 | POST | `/api/admin/users/{user_id}/restore` | Admin |
| 48 | POST | `/api/admin/users/{user_id}/reveal-phone` | Admin |
| 49 | PUT | `/api/admin/users/{user_id}/subscription` | Admin |
| 50 | POST | `/api/admin/users/{user_id}/quick-extend` | Admin |
| 51 | GET/POST | `/api/admin/subscription-requests` | Admin |
| 52 | POST | `/api/admin/subscription-requests/{req_id}/approve` | Admin |
| 53 | POST | `/api/admin/subscription-requests/{req_id}/reject` | Admin |
| 54 | GET/POST | `/api/admin/admins` | Admin |
| 55 | POST | `/api/admin/admins/{admin_id}/approve` | Admin |
| 56 | POST | `/api/admin/admins/{admin_id}/reject` | Admin |
| 57 | POST | `/api/admin/admins/{admin_id}/password` | Admin |
| 58 | PUT | `/api/admin/admins/{admin_id}/permissions` | Admin |
| 59 | DELETE | `/api/admin/admins/{admin_id}/disable` | Admin |
| 60 | POST | `/api/admin/admins/{admin_id}/enable` | Admin |
| 61 | GET | `/api/admin/audit-log` | Admin |
| 62 | GET | `/api/admin/guardian/students` | Admin-监护 |
| 63 | GET | `/api/admin/guardian/students/{student_id}` | Admin-监护 |
| 64 | GET | `/api/admin/guardian/students/{student_id}/cards` | Admin-监护 |
| 65 | GET | `/api/admin/guardian/students/{student_id}/conversations` | Admin-监护 |
| 66 | GET | `/api/admin/guardian/students/{student_id}/conversations/{conv_id}` | Admin-监护 |
| 67 | GET | `/api/admin/guardian/students/{student_id}/learning-summary` | Admin-监护 |
| 68 | POST | `/api/admin/guardian/bind` | Admin-监护 |
| 69 | POST | `/api/admin/guardian/reveal-phone/{admin_id}` | Admin-监护 |
| 70 | GET/POST | `/api/admin/guardian/assignments` | Admin-监护 |
| 71 | DELETE | `/api/admin/guardian/assignments/{assignment_id}` | Admin-监护 |

**共计 71 个路由路径（71 条 `.route()` 注册，对应 76 个 HTTP 方法处理 + 1 个 WebSocket 升级端点 `/ws`）。**
