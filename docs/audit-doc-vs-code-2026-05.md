# 代码与文档一致性审查报告

> **审查日期**: 2026-05-13  
> **审查范围**: `API.md`, `CoEvo_DataFlow.md`, `CoEvo_Devplan.md`, `DEVELOPMENT.md`  
> **对比基准**: `backend/src/main.rs`, `backend/crates/api_server/src/routes.rs`, `backend/crates/api_server/src/ws.rs`  
> **审查人**: Senior Developer (高级开发工程师)  
> **修复日期**: 2026-05-14 ✅ 全部修复完成

---

## 总览

| 文档 | 严重问题 | 重要问题 | 轻微问题 | 状态 |
|:--|:--:|:--:|:--:|:--|
| API.md | 5 | 4 | 1 | 🔴 需更新 |
| CoEvo_DataFlow.md | 0 | 1 | 0 | 🟡 基本准确 |
| CoEvo_Devplan.md | 0 | 3 | 3 | 🟡 需补充 |
| DEVELOPMENT.md | 0 | 2 | 1 | 🟡 需修正 |

---

## 一、API.md — 5 严重 + 4 重要 + 1 轻微

### 🔴 严重问题 (CRITICAL)

#### CR-1: `POST /api/chat` 响应字段名完全不符

| | 文档声明 | 代码实际 |
|:--|:--|:--|
| 字段 1 | `"concepts"` | `"candidates"` |
| 字段 2 | `"direct_card": false` | ❌ 不存在 |
| 字段 3 | ❌ 未文档化 | `"achievements": []` |

**文档** (API.md L93-97):
```json
{
  "reply": "AI 回复内容",
  "concepts": ["概念1", "概念2"],
  "direct_card": false
}
```

**代码** (`routes.rs` L219-223):
```rust
Json(serde_json::json!({
    "reply": reply,
    "candidates": candidates,
    "achievements": [],
}))
```

**影响**: Flutter 客户端如果按文档解析 `concepts` 字段，将永远收到 `null`。`direct_card` 在 REST 端点中已被废弃（此逻辑仅在 WebSocket ColdPath 中保留）。

---

#### CR-2: `GET /api/cards/all` — `state_counts` 类型错误

| | 文档声明 | 代码实际 |
|:--|:--|:--|
| 类型 | `Array` `[5,3,2,0]` | `Object` `{new, learning, review, relearning}` |

**文档** (API.md L293):
```json
"state_counts": [5, 3, 2, 0]
```

**代码** (`routes.rs` L690-695):
```rust
"state_counts": {
    "new": state_counts[0],
    "learning": state_counts[1],
    "review": state_counts[2],
    "relearning": state_counts[3],
}
```

**影响**: 前端按数组索引 `state_counts[0]` 取值将得到 `undefined`。必须用 `state_counts.new` 等键名访问。

---

#### CR-3: `DELETE /api/cards/skipped/{skip_id}` — 状态值/结构错误

**文档** (API.md L348):
```json
{"status": "removed"}
```

**代码** (`routes.rs` L495):
```rust
Json(serde_json::json!({"status": "restored", "card_id": card_id}))
```

**影响**: 文档只说"移除跳过记录"，但代码实际是 **恢复为卡片并加入复习队列**（3 步操作：读 skip → 重建 card + card_memory → 删 skip）。响应包含新创建的 `card_id`，文档完全未体现。

---

#### CR-4: `POST /api/cards/batch-create` — `created` 类型错误 + 缺字段

**文档** (API.md L255-259):
```json
{
  "created": 2,
  "duplicates": 1,
  "achievements": []
}
```

**代码** (`routes.rs` L581-586):
```rust
Json(serde_json::json!({
    "created": created,        // Vec<String> — 卡片 ID 数组
    "duplicates": duplicates,  // Vec<String> — 重复的 front
    "errors": errors,          // Vec<String> — 文档未提及
    "achievements": achievements,
}))
```

**影响**: 
- `created` 是字符串数组而非数字，前端按 `int` 解析会崩溃
- `duplicates` 也是数组而非数字
- `errors` 字段完全未文档化

---

#### CR-5: 9 个端点完全未文档化

以下端点已在 `routes.rs` 注册但 **API.md 中无任何记录**:

| 端点 | 方法 | 代码位置 | 用途 |
|:--|:--|:--|:--|
| `/api/cards/{card_id}/last-review` | GET | L709-739 | 最近一次考试详情 |
| `/api/user/{user_id}/display-name` | POST | L864-880 | 更新显示名称 |
| `/api/user/{user_id}/avatar` | POST/GET | L930-965 | 头像上传/获取 |
| `/api/user/{user_id}/preferences` | GET/PUT | L886-916 | 用户偏好存取 |
| `/api/user/{user_id}/learning-report` | GET | L1054-1154 | 学习报告 (Phase 3) |
| `/api/user/{user_id}/activity` | GET | L1161-1224 | 活跃度热力图 |
| `/api/user/{user_id}/weekly-report` | GET | L1230-1276 | 周报数据 |
| `/api/admin/users` | GET | L1287-1326 | 管理员用户查询 |
| `/api/stt` | POST | L1333-1439 | 语音转文字 (讯飞) |

---

### 🟡 重要问题 (MAJOR)

#### MA-1: `POST /api/cards/skip` — 请求缺少 `domain` 字段

**文档** (API.md L307-313): 只有 `user_id, front, source_text`

**代码** (`routes.rs` L390-396):
```rust
pub struct SkipInput {
    pub user_id: String,
    pub front: String,
    pub domain: Option<String>,   // ← 文档未提及
    pub source_text: String,
}
```

---

#### MA-2: `GET /api/user/{user_id}/profile` — 响应缺少 `display_name`

**文档** (API.md L401-418): 只有 `user_id, stats, achievements`

**代码** (`routes.rs` L848-860): 在 `user_id` 和 `stats` 之间返回 `display_name` 字段。

---

#### MA-3: `POST /api/review/submit` — 请求缺少 `details` 字段

**文档** (API.md L164-172): 只有 `user_id, card_id, rating, verification_type, verification_result`

**代码** (`routes.rs` L250-257):
```rust
pub struct ReviewSubmitInput {
    pub user_id: String,
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,
    pub details: Option<String>,  // ← 文档未提及 (快问快答详情 JSON)
}
```

---

#### MA-4: `POST /api/review/judge` — 响应缺少 `total` 字段

**文档** (API.md L221-228): 只有 `results, total_correct`

**代码** (`routes.rs` L362-366): 还返回 `"total": results.len()` 表示题目总数。

---

### 🟢 轻微问题 (MINOR)

#### MI-1: `GET /api/history` 响应字段名略有差异

文档 (L366-368) 响应根层有 `user_id`:
```json
{"user_id": "...", "conversations": [...]}
```
代码 (`routes.rs` L795-799) 同样包含 `user_id`，但带 `conversation_id` 参数时返回 `conversation_id` + `turns` + `count`（文档亦同）。**一致，无问题。**

实际上重新检查，文档和代码是一致的。这个不算问题。

---

## 二、CoEvo_DataFlow.md — 1 重要

### 🟡 重要问题

#### DF-1: `POST /api/review/submit` 响应描述错误

**文档** (DataFlow.md L704):
```
| POST | `/api/review/submit` | N6c | `{card_id, rating, vtype, vresult}` | `{new_state, next_due, achievements}` |
```

**代码** (`routes.rs` L279-282):
```rust
Json(serde_json::json!({
    "status": "ok",
    "achievements": new_achievements,
}))
```

响应中 **不包含 `new_state` 和 `next_due`**。FSRS 状态更新发生在服务端内部，不暴露给客户端。

---

### ✅ 已验证准确的部分

- 10 张表结构正确列出（含 `user_preferences`）
- 所有 P0/P1/P2 问题标记正确
- WebSocket 协议描述准确
- 节点 N1-N8 逻辑与代码一致
- Seat-map 表字段完整

---

## 三、CoEvo_Devplan.md — 3 重要 + 3 轻微

### 🟡 重要问题

#### DP-1: 表数量声明错误 (2处)

| 位置 | 声明 | 实际 |
|:--|:--|:--|
| L307 | "8 个节点 · **9 张表**" | 10 张表 |
| L311 | "六、数据库设计 **(9 张表)**" | 10 张表 |

`user_preferences` 表于 2026-05-13 通过 migration 添加（`main.rs` L168-175），但 Devplan 中两处计数仍为 9。

---

#### DP-2: 数据库 Schema 缺少 `user_preferences` 表

L312-418 列出了 9 张表的完整 DDL，但缺少:

```sql
CREATE TABLE user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

---

#### DP-3: 技术栈描述不准确 — Flutter 未使用 Drift

**文档** (L428):
```
| 数据库 | SQLite (rusqlite + Drift) |
```

**实际**: Flutter 客户端通过 REST/WebSocket 与后端通信，**不使用 Drift**（Drift 是 Dart 端 SQLite ORM）。所有数据库操作在后端 Rust 端完成。

应改为:
```
| 数据库 | SQLite (rusqlite, 后端) |
| 通信 | REST + WebSocket, Dart 手动类型 |
```

---

### 🟢 轻微问题

#### DP-4: STT 状态过时

**文档** (L520-522):
> 状态: 技术调研完成，暂缓

**代码** (`routes.rs` L1333-1439): **完整的 STT 实现已存在**，包括 ffmpeg 音频转码 + 科大讯飞 API 调用。端点 `POST /api/stt` 已注册。

---

#### DP-5: 重复的章节编号

两个 "**四**" 章节:
- L135: `## 四、学习计划流程`
- L157: `## 四、节点定义`

第二个应为 `## 四` → `## 五`，之后所有章节编号依次递增。

---

#### DP-6: 实施计划中 Schema 表数不一致

**文档** (L442):
> 数据库 Schema + Migration (8 表)

实际初始 Schema 为 9 表，迁移后为 10 表。

---

## 四、DEVELOPMENT.md — 2 重要 + 1 轻微

### 🟡 重要问题

#### DV-1: 日志示例中的表数量错误

**文档** (L47):
```
Schema initialized (8 tables)
```

**代码** (`main.rs` L144):
```rust
tracing::info!("Schema initialized (9 tables)");
```

初始 Schema 含 9 张表（不含 user_preferences），迁移后共计 10 张。

---

#### DV-2: 引用不存在的 `schema.sql` 文件

**文档** (L66):
```
├── schema.sql              # 数据库 8 张表定义
```

**实际**: 项目 **没有独立的 `schema.sql` 文件**。Schema 定义在 `main.rs` 中的 `SCHEMA_SQL` 内联常量中：

```rust
// main.rs L8
const SCHEMA_SQL: &str = r#"..."#;
```

设计决策注释 (`main.rs` L7):
> 内联数据库 Schema（替代 schema.sql 文件，确保 APK 部署不依赖文件系统）

---

### 🟢 轻微问题

#### DV-3: Prompt 文件数量不对

**文档** (L69-73): 列出 5 个 prompt 文件
```
├── chat_system.md
├── concept_extract.md
├── card_direct.md
├── quiz_generate.md
└── quiz_judge.md
```

**实际**: 存在第 6 个 prompt 文件 `grill_assessment.md`（Part-time 考核功能使用）。

---

## 五、修复优先级建议

### 🔴 立即修复 (P0 — 影响前端集成)

| # | 文件 | 问题 | 修复方向 |
|:--|:--|:--|:--|
| CR-1 | API.md | chat 响应字段名 | `concepts` → `candidates`, 移除 `direct_card`, 添加 `achievements` |
| CR-2 | API.md | state_counts 类型 | Array → Object `{new, learning, review, relearning}` |
| CR-3 | API.md | skip delete 响应 | `removed` → `restored`, 添加 `card_id` |
| CR-4 | API.md | batch-create 响应 | `created` 改为 ID 数组, 添加 `errors`, `duplicates` 改为数组 |

### 🟡 尽快修复 (P1 — 影响新功能对接)

| # | 文件 | 问题 |
|:--|:--|:--|
| CR-5 | API.md | 补充 9 个未文档化端点 |
| MA-1~4 | API.md | 补充缺失的请求/响应字段 |
| DF-1 | DataFlow.md | 修正 review/submit 响应描述 |
| DP-1~3 | Devplan.md | 更新表数、Schema、技术栈 |
| DV-1~2 | DEVELOPMENT.md | 修正表数和 schema.sql 引用 |

### 🟢 择时修复 (P2 — 不影响功能)

| # | 文件 | 问题 |
|:--|:--|:--|
| DP-4 | Devplan.md | 更新 STT 状态为"已实现" |
| DP-5 | Devplan.md | 修复重复章节编号 |
| DP-6 | Devplan.md | 修正 Schema 表数引用 |
| DV-3 | DEVELOPMENT.md | 补充 grill_assessment.md |

---

## 六、统计数据

| 指标 | 数值 |
|:--|--:|
| 审查文档数 | 4 |
| 审查代码文件 | 3 (main.rs, routes.rs, ws.rs) |
| 发现问题总数 | 19 |
| 🔴 严重 | 5 |
| 🟡 重要 | 10 |
| 🟢 轻微 | 4 |
| 未文档化端点 | 9 |

---

*报告版本: V1.0*  
*审查工具: 人工逐行对比 (文档 vs 源码)*
