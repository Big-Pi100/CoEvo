# 前后端数据格式一致性审查报告

**审查日期**: 2026-06-04  
**审查范围**: 前端模型类 (`coevo_models.dart`) → API 客户端 (`chat_client.dart`) → 后端路由 (`routes.rs`/`fsrs_scheduler.rs`) → 渲染代码  
**方法**: 逐端追踪每个 API 路径的数据流（请求字段 → 响应字段 → 模型解析 → UI 消费）

---

## 审查结果总览

| 类别 | 数量 | 说明 |
|:----|:----:|:------|
| ✅ 完全一致 | 12 个端点 | 请求/响应格式与前端的解析/使用完全匹配 |
| ⚠️ 字段名不一致 | 1 个 | `DueCard` `last_review` ↔ `last_reviewed_at` |
| ⚠️ 可选字段缺失 | 1 个 | `DueCard` 缺少 `created_at`（前端有解析但值为 null） |
| ❌ 阻塞问题 | 0 个 | |

---

## 详细对齐检查

### 1. 认证 (`POST /api/auth/register`, `POST /api/auth/login`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{"username","password","real_name"?,"phone"?}` | `RegisterRequest` 同名字段 | ✅ 完全一致 |
| 请求 | `{"username","password"}` | `LoginRequest` 同名字段 | ✅ |
| 响应 | `data["user_id"]`, `data["token"]` | `AuthResponse{user_id,token,message}` | ✅ 仅使用 user_id/token，extra message 无害 |

### 2. Token 验证 (`POST /api/auth/verify`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{"user_id","token"}` | `TokenVerifyInput` 同名 | ✅ |
| 响应 | `data["valid"] == true` | `{"valid": bool}` | ✅ |

### 3. 聊天 (`POST /api/chat`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `ChatRequest{userId,conversationId,message,token?}` | `ChatInput{user_id,conversation_id,message}` | ✅ token 额外字段，后端未读取 |
| 响应 | `data["reply"]`, `data["candidates"]` | `{"reply","candidates","achievements","plan_updated"}` | ✅ |
| 响应 | `data["plan_updated"]` | ✅ 同上 | ✅ |

### 4. WebSocket (`WS /ws`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{user_id,conversation_id,message,token}` | ws.rs 解析同名字段 | ✅ |
| 事件 | `WsEvent.type="delta"` (content) | `{"type":"delta","data":"..."}` | ✅ |
| 事件 | `WsEvent.type="done"` (reply+candidates) | `{"type":"done","reply":"...","candidates":["..."]}` | ✅ `WsEvent.reply` vs `"data"` 差异见 WS 协议部分 |
| ⚠️ | `WsEvent.content: json['content']` | ws.rs 事件 `{"content": ...}` | ✅ type=delta 时用 content |

### 5. 到期卡片 (`GET /api/review/due`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `GET ?user_id=xxx` | `DueQuery{user_id,limit?}` | ✅ |
| 响应 | `resp["cards"]`, `resp["total_due"]` | `get_due_cards` 返回 `(Vec<DueCard>, i64)` | ✅ |
| 字段: `id` | `json['id'] as String` | `DueCard.id: String` | ✅ |
| `front` | `json['front'] as String` | `DueCard.front` | ✅ |
| `back` | `json['back'] as String` | `DueCard.back` | ✅ |
| `domain` | `json['domain'] as String?` | `DueCard.domain: Option<String>` | ✅ |
| `card_type` | `json['card_type'] as String` | `DueCard.card_type` | ✅ |
| `source_sentence` | `json['source_sentence'] as String?` | `DueCard.source_sentence` | ✅ |
| `state` | `json['state'] as int` | `DueCard.state: i32` | ✅ |
| `reps` | `json['reps'] as int` | `DueCard.reps: i32` | ✅ |
| `lapses` | `json['lapses'] as int` | `DueCard.lapses: i32` | ✅ 新加 |
| `difficulty` | `json['difficulty'] as num?.toDouble()` | `DueCard.difficulty: f64` | ✅ 新加 |
| `due` | `json['due'] as int?` | `DueCard.due: i64` | ✅ 新加 |
| ⚠️ **`last_reviewed_at`** | **`json['last_reviewed_at'] as int?`** | **`DueCard.last_review` → JSON 输出 `"last_review"`** | ❌ **字段名不匹配** |
| `last_review_quality` | `json['last_review_quality'] as int?` | `DueCard.last_review_quality: Option<i32>` | ✅ 新加 |
| `subject` | `json['subject'] as String?` | `DueCard.subject: Option<String>` | ✅ 新加 |
| `grade_band` | `json['grade_band'] as String?` | `DueCard.grade_band: Option<String>` | ✅ 新加 |
| `conversation_id` | `json['conversation_id'] as String?` | `DueCard.conversation_id: Option<String>` | ✅ |
| ⚠️ `created_at` | `json['created_at'] as int?` | DueCard 无此字段 → **永远 null** | ⚠️ 不影响功能 |

### 6. 卡片列表 (`GET /api/cards/all`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求参数 | `user_id, q, state, domain, subject, sort` | `AllCardsQuery` 同名字段 | ✅ |
| 响应 | `resp["cards"]` (→ DueCard.fromJson) | `{"cards": [...]}` | ✅ |
| 响应 | `resp["state_counts"]` (→ Map) | `{"state_counts":{"new":N,"learning":N,...}}` | ✅ |
| 响应 | `resp["domains"]` (→ List) | `{"domains": ["..."]}` | ✅ |
| 响应 | `resp["subjects"]` (→ List) | `{"subjects": ["..."]}` | ✅ |
| 卡片字段 `last_reviewed_at` | `json['last_reviewed_at']` | `cards_all` 用显式 `"last_reviewed_at"` | ✅ **此处正确** |

**注意**: CardListScreen 重用 `DueCard.fromJson` 解析 /api/cards/all 的响应。该端点使用显式 JSON key `"last_reviewed_at"`，与从 Json 解析相符 ✅。但 `/api/review/due` 使用 serde `Serialize` 输出 `"last_review"`，出现不一致。

### 7. 验证问题 (`POST /api/review/verify`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{user_id, card_id, front, back}` | 同名字段 | ✅ |
| 响应 | `resp["questions"] → VerifyQuestion.fromJson` | `{"questions": [{"question","expected_answer"}]}` | ✅ |

### 8. 判断答案 (`POST /api/review/judge`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{user_id, card_id, questions: [{question,expected_answer,user_answer}]}` | 同名字段 | ✅ |
| 响应 | `resp["results"] → JudgeResult.fromJson` | `{"results": [{"correct": bool, "feedback": "str"}]` | ✅ |
| 响应 | `resp["total_correct"] as int` | `{"total_correct": int}` (e2e 测试确认) | ✅ |

### 9. 提交复习 (`POST /api/review/submit`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{user_id, card_id, rating, verification_type, verification_result, details?}` | `ReviewSubmitInput{...details: Option<String>}` | ✅ |
| 响应 | `resp["status"]`, `resp["achievements"]` | `{"status":"ok", "achievements":[...]}` | ✅ |

### 10. 对话历史 (`GET /api/history`)

| 场景 | 前端请求 | 后端 | 状态 |
|:----|:--------|:-----|:----:|
| 列表 | `GET ?user_id=X&limit=50&include_deleted?` | `HistoryQuery{user_id,limit?,include_deleted?}` | ✅ |
| 轮次 | `GET ?user_id=X&conversation_id=Y&limit=50&offset=0` | 同上，加 `conversation_id` | ✅ |
| 列表响应 | `data["conversations"]`, `data["count"]` | `{"conversations":[{id,turn_count,started_at,deleted_at,title}], "count":N}` | ✅ |
| 轮次响应 | `data["turns"], data["total"]` | `{"turns":[{id,role,content,created_at}], "count":N, "total":N}` | ✅ |

### 11. 学习计划 (`GET /api/plans`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `?user_id=X` 或 `?conversation_id=X` | PlansQuery 支持 user_id / conversation_id | ✅ |
| 响应 | `data["plans"]` → `p["goal"]`, `p["conversation_id"]`, `p["mode"]` | `{"plans":[{"id","conversation_id","goal","mode","plan": {...}}]}` | ✅ |

### 12. 学习报告 (`GET /api/user/{id}/learning-report`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 响应 | `data["plans"]` | `{"plans":[...], "stats":{...}, "assessment":{...}}` | ✅ |

### 13. 活动数据 (`GET /api/user/{id}/activity`)

| 前端请求 | 后端 | 状态 |
|:--------|:-----|:----:|
| `GET ?days=N` | `Query<HashMap>` 提取 `days` | ✅ |

### 14. 卡片状态 (`PATCH /api/cards/status`, `PATCH /api/cards/batch-status`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 单张 | `{user_id, card_id, status}` | `StatusInput{user_id, card_id, status}` | ✅ |
| 批量 | `{user_id, card_ids, status}` | `BatchStatusInput{user_id, card_ids, status}` | ✅ |

### 15. 翻译验证 (`POST /api/verify-translation`)

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{front, back, user_input}` | `VerifyTranslationInput{front,back,user_input}` | ✅ |
| 响应 | `data["result"] as String` | `{"result": "pass|fail|partial"}` | ✅ |

### 16. K12/Reading Init

| 方向 | 前端 | 后端 | 状态 |
|:----|:-----|:-----|:----:|
| 请求 | `{user_id, subject, grade_band}` | `K12InitInput{user_id,subject,grade_band}` | ✅ |
| 响应 | `data["conversation_id"]`, `data["plan"]` | `{"conversation_id","plan","cards":{...}}` | ✅ |

---

## 发现问题详细分析

### ⚠️ 问题 1: DueCard `last_review` ↔ `last_reviewed_at` 字段名不一致 (P1)

**后端 `/api/review/due`**:
```rust
// fsrs_scheduler.rs
#[derive(serde::Serialize)]
pub struct DueCard {
    pub last_review: Option<i64>,  // → serde 输出 JSON key: "last_review"
}
```

**前端 `DueCard.fromJson`**:
```dart
factory DueCard.fromJson(Map<String, dynamic> json) => DueCard(
    lastReviewedAt: json['last_reviewed_at'] as int?,  // ← 读 "last_reviewed_at"
);
```

**影响**: `/api/review/due` 返回 `"last_review": 1234567890`，但前端读 `"last_reviewed_at"` 得到 null。复习 UI 不会展示"上次复习时间"。

**范围**: 仅影响 `/api/review/due` 端点。`/api/cards/all` 使用显式 JSON 构造 `"last_reviewed_at": ...`，不受影响。

**修复**: 在 DueCard 的 `last_review` 字段加 `#[serde(rename = "last_reviewed_at")]`

### ⚠️ 问题 2: DueCard 缺少 `created_at` 字段（低优先级）

前端 `DueCard.fromJson` 解析 `json['created_at'] as int?`，但后端 `DueCard` 结构体没有 `created_at` 字段。`/api/review/due` 的卡片永远不会有 `created_at` 值。

**影响**: 前端用 `due` 字段替代排序，`created_at` 仅用于显示，非核心功能。

---

## 关键数据流验证

### 自由对话流
```
用户输入 → ChatRequest.toJson() → POST /api/chat → {"reply","candidates"} → Message渲染
                                    ↓                      ↗
                           概念提取 → CP1写入cards → cards/all读取 → DueCard渲染
```

### 复习流
```
review_screen._loadCards() → GET /api/review/due
  → DueCard.fromJson() → List<DueCard> → UI渲染卡片
  → _preloadAiQuestions() → POST /api/review/verify
    → VerifyQuestion.fromJson() → 列表展示
  → _judgeInlineAnswers() → POST /api/review/judge
    → JudgeResult.fromJson() → 结果渲染
  → _submitInlineReview() → POST /api/review/submit
    → response["achievements"] → 成就弹窗
```

全部正确 ✅（除 `last_review` 字段名问题）

---

## 建议修复行动

| 优先级 | 问题 | 位置 | 修复 |
|:------|:----|:----|:----|
| **P1** | `last_review` vs `last_reviewed_at` | `fsrs_scheduler.rs:29` | 加 `#[serde(rename = "last_reviewed_at")]` |
| P3 | DueCard 缺 `created_at` | `coevo_models.dart:74` | 移除 `createdAt` 解析或添加后端字段（后端需加列） |

审查完成：12 个端点完全一致，1 个字段名问题，1 个可选字段缺失，无阻塞性问题。
