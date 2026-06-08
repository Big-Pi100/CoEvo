# API 修复与测试改进计划

> 生成日期: 2026-06-04
>
> 基于 `frontend-api-alignment-report.md` 发现的问题拟定

---

## 总览

| 优先级 | 问题 | 类型 | 预估工作量 |
|:------|:-----|:----|:---------|
| P0 | 复习流程零测试覆盖 | 测试缺口 | 2-3 天 | ✅ **完成** |
| P0 | WebSocket 路径未测试 | 测试缺口 | 1 天 | ✅ **完成** |
| P1 | `GET /api/review/due` 字段缺失 | 前后端不一致 | 0.5 天 | ✅ **完成** |
| P1 | 用户资料/活动/周报未测试 | 测试缺口 | 1 天 | ✅ **完成** |
| P2 | 卡片状态管理未测试 | 测试缺口 | 0.5 天 | ✅ **完成** |
| P2 | 对话管理未测试 | 测试缺口 | 0.5 天 | ✅ **完成** |
| P2 | Token 验证未测试 | 测试缺口 | 0.3 天 | ✅ **完成**（合入 Phase 4）|
| P2 | 管理后台 ~25 端点未测试 | 测试缺口 | 0.5 天 | ✅ **完成**（Phase 7）|

---

## Phase 1: 修复后端数据缺失（P1 · 0.5 天）

### 问题：`GET /api/review/due` 返回字段不完整

**当前状态**: `DueCard` 结构体 (`fsrs_scheduler.rs:17-27`) 只返回 9 个字段，前端期望 15 个。

**修改文件**:

| 文件 | 改动 |
|:----|:-----|
| `crates/card_engine/src/fsrs_scheduler.rs` | `DueCard` 结构体 +6 字段，SQL 查询 +6 列 |
| `app/lib/models/coevo_models.dart` | 确认字段名对齐（无需修改，前端已用 `json['due'] as int?` 安全解析） |

**具体改动**:

```rust
// DueCard 结构体新增字段
pub struct DueCard {
    pub id: String,
    pub front: String,
    pub back: String,
    pub domain: Option<String>,
    pub card_type: String,
    pub source_sentence: Option<String>,
    pub state: i32,
    pub reps: i32,
    pub lapses: i32,              // ← 新增
    pub difficulty: f64,          // ← 新增
    pub due: i64,                 // ← 新增
    pub last_review: Option<i64>, // ← 新增
    pub last_review_quality: Option<i32>, // ← 新增
    pub subject: Option<String>,  // ← 新增
    pub grade_band: Option<String>, // ← 新增
    pub conversation_id: Option<String>,
}
```

```sql
-- SQL 查询补充字段
SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       cm.state, cm.reps, cm.lapses, cm.difficulty, cm.due, cm.last_review,
       c.subject, c.grade_band, c.conversation_id
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
LEFT JOIN review_log lr ON c.id = lr.card_id  -- for last review quality
...
```

**验证方法**: 运行 `cargo test -p card_engine --lib` 确认单元测试通过。

---

## Phase 2: 复习流程 e2e 测试（P0 · 2-3 天）

### 新增测试文件

`backend/crates/api_server/tests/e2e_review_lifecycle.rs`

### 测试流程

```
1. Register → Login → Subscription
2. 创建自由对话 → 发送教学消息 → 等待 CP1 创建卡片
3. 确认卡片已创建（active）
4. GET /api/review/due → 验证有到期卡片
5. POST /api/review/verify → 获取 3 道验证题
6. 模拟用户回答 → POST /api/review/judge → 批改
7. POST /api/review/submit → 提交评分，触发 FSRS
8. 验证成就返回
```

### 断言要点

| 步骤 | 断言 | 说明 |
|:----|:-----|:-----|
| review/due | `total_due > 0`, `cards` 非空 | FSRS 调度正常 |
| review/verify | `questions` 长度为 3 | LLM 出题正常 |
| review/judge | `results` 数组长度匹配 | LLM 批改正常 |
| review/submit | `status == "ok"` | FSRS 更新正常 |

### 复用组件

- `student_llm` crate → 模拟学生回答验证题
- `e2e_api_lifecycle` 的 server 启动/DB 初始化 → 复制模式
- `DEFAULT_PROMPT` → 学生提示词

---

## Phase 3: WebSocket 路径验证（P0 · 1 天）

### 方案

在现有 `e2e_api_lifecycle.rs` 中新增一个 WS 子测试，或在 `e2e_review_lifecycle` 中包含：

```
1. 建立 WS 连接 → /ws
2. 发送 ChatRequest (含 token)
3. 接收 WsEvent → 验证 type=delta + type=done
4. 验证 done 事件的 reply 非空
5. 关闭连接
```

### 实现方式

```rust
use tokio_tungstenite::connect_async;
// 或使用 reqwest 的 WS 支持

let ws_url = base.replace("http", "ws");
let (ws_stream, _) = connect_async(ws_url).await.unwrap();
let (write, read) = ws_stream.split();

// 发送消息
write.send(Message::Text(chat_request_json)).await.unwrap();

// 接收事件
while let Some(msg) = read.next().await {
    let event: WsEvent = serde_json::from_str(&msg?).unwrap();
    match event.type.as_str() {
        "done" => { /* 验证 reply */ break; }
        "error" => { panic!("WS error"); }
        _ => {} // delta
    }
}
```

**依赖**: 需要在 `api_server/Cargo.toml` 的 dev-dependencies 中添加 `tokio-tungstenite`。

---

## Phase 4: 资料/活动/周报测试（P1 · 1 天）

### 新增测试文件或合入现有测试

在 `e2e_api_lifecycle.rs` 中追加步骤：

| 步骤 | API | 断言 |
|:----|:----|:-----|
| 获取 profile | `GET /api/user/{id}/profile` | `user_id` 匹配 |
| 更新显示名称 | `POST /api/user/{id}/display-name` | `status == "ok"` |
| 获取偏好 | `GET /api/user/{id}/preferences` | 返回 map |
| 保存偏好 | `PUT /api/user/{id}/preferences` | `status == "ok"` |
| 获取活动 | `GET /api/user/{id}/activity?days=30` | 返回活动数据 |
| 获取周报 | `GET /api/user/{id}/weekly-report` | 返回周报数据 |
| Token 验证 | `POST /api/auth/verify` | `valid == true` |

---

## Phase 5: 卡片状态管理测试（P2 · 0.5 天）

在 `e2e_api_lifecycle.rs` 追加：

```
1. 从 CP1 获取 candidates
2. PATCH /api/cards/status → 确认第一张卡为 active
3. GET /api/cards/all → 验证卡在返回中
4. PATCH /api/cards/status → 将卡标记为 skipped
5. GET /api/cards/all → 验证卡不在返回中（仅 active）
```

---

## Phase 6: 对话管理测试（P2 · 0.5 天）

在 `e2e_api_lifecycle.rs` 末尾追加：

```
1. DELETE /api/conversations/{conv_id} → 软删除
2. GET /api/history?include_deleted=only → 验证在回收站
3. POST /api/conversations/{conv_id}/restore → 恢复
4. 验证对话可正常使用
```

---

## 实施顺序建议

```
Phase 1 (后端修复) → Phase 2 (复习测试) → Phase 3 (WS验证)
       ↓                    ↓
  Phase 4 (资料测试) ← 可并行 ← Phase 5+6 (卡片+对话)
```

**Phase 1 应首先完成**，因为 Phase 2 中 `GET /api/review/due` 的断言依赖正确的字段返回。Phase 4/5/6 不依赖 Phase 1，可并行实施。

---

## 风险与备注

| 风险 | 说明 | 缓解措施 |
|:----|:-----|:--------|
| WS 测试依赖第三方库 | `tokio-tungstenite` 需添加依赖 | 轻量库，无兼容风险 |
| 复习测试耗时较长 | 需要先创建对话→等待 CP1→再验证复习 | 用 2-3 轮对话即可触发 CP1 |
| 成就检测可能为空 | 短对话可能不足以触发成就 | 断言`status=="ok"` 而非成就内容 |
