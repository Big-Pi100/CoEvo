# CoEvo 数据库架构规划 v2.1

> 基于 V2.0 执行经验 + 本地优先架构设计 + 22 表状态审计  
> 创建时间：2026-06-01 00:30  
> 状态：**架构规划文档** — 待确认后分阶段实施

---

## 一、V2.0 执行回顾（已完成）

V2.0 已于 2026-05-31 晚全量实施完毕，版本 0.1.0 → 0.2.0。

| 阶段 | 内容 | 状态 |
|------|------|------|
| Phase 0 | Domain enum, domain 语义修正, routes 三路径迁移, ws.rs 死代码清理 | ✅ |
| Phase 0.5 | plan_json→task_status 列改名（7 文件 ~107 引用） | ✅ |
| Phase 1 | bind_hash 唯一索引 + 清理遗留 idx_users_bind_key | ✅ |
| Phase 2 | conversations 重建（删 learning_plan_id, FK+CASCADE） | ✅ |
| Phase 3 | learning_plans 重建（domain enum CHECK, mode CHECK, task_status, UNIQUE+FZK） | ✅ |
| Phase 4 | cards 重建（FK+origin CHECK）, review_log CHECK, card_memory CASCADE, learning_plan_tasks 新建 | ✅ |
| Phase 4b | 预置卡 origin='prebuilt' 标记修复（27,342 张） | ✅ |
| 测试 | 66/66 lib/integration tests pass；3/19 live e2e pass（CP2 驱动版） | ✅ |

---

## 二、架构原则变更

### 2.1 从"全量云端"到"用户只读 + 本地优先"

**原有模式**：所有数据全量存在云端 SQLite，每次请求走网络查 DB。

**新原则**：

```
云端 = 内容分发层（轻量，不随用户量增长）
  ├── cards — 卡片内容（2.7 万张，全用户共享）
  ├── k12_quiz_bank — 题库（共享）
  ├── knowledge_graph — 知识图谱（共享）
  ├── plan_templates（未来）— K12 计划模板（共享）
  └── 用户基础信息（登录认证 + 轻量 profile）

设备端 = 用户状态层（容量随用户增长，单用户全部）
  └── state.json（users 表中的 JSON 字段）
        ├── plans[].task_status — 计划进度
        ├── card_memory{} — FSRS 算法状态
        ├── review_logs[] — 复习记录（只追加）
        ├── conversations[].turns[] — 对话历史
        └── skipped_concepts[] — 跳过记录
```

### 2.2 用户只读原则

用户状态 JSON 是单用户全部状态的唯一真实源。Rust 后端（当前）或 Flutter 前端（未来本地模式）的读路径：

```
1. 根据 user_id 查询 users.state_json
2. 反序列化为 Rust/Flutter struct
3. 就地操作，不再跨表查询
```

写路径：

```
1. 修改 Rust/Flutter struct
2. 序列化为 JSON
3. UPDATE users SET state_json=? WHERE id=?1
```

---

## 三、22 表状态审计结论

来自 2026-06-01 00:20 的全库审计：

### 🔴 应迁入 user JSON 的用户状态

| 当前表 | 行数 | 字段 | 说明 |
|--------|------|------|------|
| `learning_plans` | 7 | `task_status`, `updated_at` | 计划进度映射 |
| `card_memory` | 27,690 | state, difficulty, stability, due, last_review, reps, lapses | FSRS 复习状态（7 字段） |
| `review_log` | 21 | 全部字段 | 复习事件日志（只追加） |
| `skipped_concepts` | 120 | 全部字段 | 跳过记录（只追加） |
| `conversations` | 378 | `turn_count`, `deleted_at` | 会话元数据状态 |
| `conversation_turns` | 595 | 全部字段 | 对话历史（只追加） |

### 🟢 留在独立表的共享/内容数据

| 表 | 说明 | 理由 |
|----|------|------|
| `cards` | 卡片内容 front/back | 全用户共享的结构化内容，不是状态 |
| `learning_plans` (部分) | `plan_content`, `goal`, `domain` | 计划结构（未来可迁移到 plan_templates） |
| `k12_quiz_bank` | 题库 | 共享数据 |
| `k12_quiz_attempts` | 答题记录 | 0 行，当前未用 |
| `knowledge_graph` | 知识图谱 | 共享静态数据 |
| `users` (部分) | username, password_hash | 登录认证（非状态部分） |
| `tokens`, `admin_users`, `audit_log` | 系统管理 | 安全/管理数据 |

### 🟡 待定/遗留

| 表 | 建议 |
|----|------|
| `achievements` | 可在 cloud 或本地，体积小，影响面小 |
| `k12_progress` | 0 行（遗留表，可后续清理） |
| `user_preferences` | 可合并到 state_json 的 `preferences` 字段 |
| `guardian_assignments` | 监护人绑定关系，云端正合适 |
| `subscription_requests` | 订阅审批流，云端管理 |

---

## 四、待决问题框架

### Q1: 用户状态用 JSON 还是 DB 列？

| 结论 | 理由 |
|------|------|
| **JSON** | 本地优先架构下，JSON 序列化/反序列化是必须能力。DB 列的优势（可查询、索引）在读了 JSON 后就地计算时不成立。28KB/用户的体量下不值得归一化。 |
| 未来更改条件 | 如果需要跨用户查询（如"多少学生完成了任务 X"），再在云端建物化视图或分析表 |

### Q2: CP2 自由对话是否建新表？

| 结论 | 理由 |
|------|------|
| **不建** | CP1 和 K12 共享 `learning_plans` 表，以 `plan_template_id IS NULL` 区分。迁入 user JSON 后更无区别——反正都在 state_json.plans[] 里。 |

### Q3: 改 API 路径从单表到多表/JSON 的影响？

| 结论 | 理由 |
|------|------|
| **当前不拆模版，先迁 JSON** | 避免中间过渡方案。等 user JSON 落地后，plan_content 的去重（模板化）问题直接自然解决——云端只存模板，用户 JSON 只存状态。一步到位。 |

---

## 五、v2.1 分阶段实施计划

### 第零步：设计定型（当前）

- [x] 架构原则确立（用户只读 + 本地优先）
- [x] 边界划分完成（什么进 JSON，什么留独立表）
- [x] 待决问题框架建立
- [ ] 确认：card_memory 进 JSON（2.7MB 反序列化 vs 本地 CPU 算，接受）
- [ ] 确认：conversation_turns 进 JSON（含全部对话历史）
- [ ] 确认：review_log 进 JSON
- [ ] 确认：skipped_concepts 进 JSON

### 第 1 步：users 表加 state_json 列

```sql
ALTER TABLE users ADD COLUMN state_json TEXT DEFAULT '{}';
```

纯新增列，不影响现有数据。旧的表（card_memory, review_log, conversations, etc.）**不删除**。

### 第 1b 步：时间字段统一（配合建表/改表一并执行）

全部 TEXT 时间列改为 INTEGER（Unix 秒级时间戳）。不单独建表，在表重建/新建时顺带完成。

| 新建表直接 INTEGER | 旧表迁移时转换 |
|-------------------|---------------|
| `plan_templates.updated_at` | `users.created_at` TEXT→INTEGER |
| `conversation_plans.created_at/updated_at` | `conversations.started_at` TEXT→INTEGER |
| `user_plan_progress.started_at/completed_at/updated_at` | `conversation_turns.created_at` TEXT→INTEGER |
| | `review_log.reviewed_at` ✅ 已是 INTEGER 不动 |

### 第 2 步：双写过渡

在 Rust 后端添加 `UserState` struct，封装所有状态操作：

```rust
#[derive(Serialize, Deserialize)]
struct UserState {
    plans: Vec<PlanState>,
    card_memory: HashMap<String, CardMemoryState>,
    review_logs: Vec<ReviewEntry>,
    skipped_concepts: Vec<SkippedEntry>,
    conversations: Vec<ConversationState>,
    preferences: HashMap<String, String>,
    updated_at: String,
}

fn read_user_state(conn, user_id) -> UserState
fn write_user_state(conn, user_id, state: &UserState)
```

所有读写路径**双写**：同时写旧表 + state_json。运行一段时间验证一致性后进入第 3 步。

### 第 3 步：读路径切换

所有读路径从旧表切换到 `state_json`。旧表保留作为回退。

- `build_plan_context()` → 从 state_json.plans 读取
- `GET /api/cards/due` → 从 state_json.card_memory 筛选到期卡片
- `GET /api/plans` → 从 state_json.plans 返回
- `GET /api/conversations` → 从 state_json.conversations 返回
- `WS handle_ws()` → 每轮对话结束时更新 state_json

### 第 4 步：写路径切换

写操作只改 state_json，不再写旧表。旧表冻结。

### 第 5 步：旧表清理（可选）

待本地优先上线（Flutter 端直接读写本地 JSON）后，云端只读不写这些表，可以保留作为同步信道或清理。

---

## 六、建议的 State JSON Schema

```json
{
  "version": 1,
  "updated_at": "2026-06-01T00:30:00Z",
  "plans": {
    "plan_id_1": {
      "task_status": { "task_key_1": "done", "task_key_2": "in_progress" },
      "updated_at": "2026-06-01T00:28:00Z"
    }
  },
  "card_memory": {
    "card_id_1": { "state": 0, "difficulty": 5.0, "stability": 0.0, "due": 1717113600, "last_review": null, "reps": 0, "lapses": 0 }
  },
  "review_logs": [
    { "id": "r1", "card_id": "card_1", "rating": 4, "verification_type": "typing", "verification_result": "pass", "reviewed_at": 1717113600 }
  ],
  "conversations": {
    "conv_id_1": {
      "turn_count": 12,
      "deleted_at": null,
      "turns": [
        { "role": "user", "content": "...", "created_at": "..." },
        { "role": "assistant", "content": "...", "created_at": "..." }
      ]
    }
  },
  "skipped_concepts": [
    { "front": "...", "domain": "math", "skipped_at": 1717113600 }
  ],
  "preferences": {
    "review_per_day": "20",
    "theme": "light"
  }
}
```

> 注意：conversation_turns 的 content 字段是 LLM 对话文本，可能较长。如果整块序列化超出 SQLite 单行限制（默认 ~2GB），考虑只在 state_json 存元数据（turn_count, last_message_preview），完整历史留在独立表。

---

## 七、本地优先路线图

```
当前阶段（VPS 做全部工作）
  ├── Rust 后端 + SQLite 全量 DB
  └── Flutter Web 通过 HTTP/WS 调用后端

v2.1 实施后（后端保留 state_json 同步信道）
  ├── Rust 后端：读 state_json + 写 state_json
  ├── 旧表保留但仅做灾备
  └── API 接口不变（屏蔽内部变化）

本地优先上线（Flutter 直连本地 DB）
  ├── Flutter 端：嵌入 SQLite，state_json 在本地
  ├── Rust 后端：仅做内容分发 + 状态同步
  ├── 同步协议：用户登录时拉取 state_json，离线修改后推送
  └── 冲突处理：最后写入者胜（单设备用户不需要 CRDT）
```

> **状态更新（2026-06-01 01:38）**：本文档部分内容已根据后续决策调整。最终定稿以 `Complete_Database_Structure_Analysis_Report.md` 为准。关键变更：用户状态用 DB 列（非 JSON）、CP1 独立 `conversation_plans` 表（非共用）、时间字段全部统一为 INTEGER Unix timestamp。

---

## 附录 A：V2.0 与 V2.1 的关系

```
V2.0（已完成）                    V2.1（规划中）
─────────────────────             ─────────────────────
表结构规范化                      数据归属重新划分
FK/CASCADE/CHECK                状态→用户 JSON
domain 枚举化                   内容→共享独立表
plan_json→task_status           后端读路径切换
                                本地优先架构铺垫
```

V2.1 不是 V2.0 的替代，而是 V2.0 基础上的**上层架构演进**。

---

## 附录 B：外部方案评估与融合

> 基于 `他人建议.md`（2026-06-01）的评估

### B.1 外部方案的核心价值

| 可取之处 | 已纳入 v2.1 |
|---------|------------|
| 本地优先，端侧持有可变状态 | ✅ 核心原则 |
| state.json 做用户状态容器 | ✅ |
| 共享内容与用户状态分离 | ✅ |
| 全量上传/下载 + 最后写入者胜 | ✅ |
| 用户状态 AES-256-GCM 加密 | ✅（需叠加平台密钥） |

### B.2 外部方案与项目现实的偏差

| 偏差 | 外部方案假设 | 实际情况 | 修正 |
|------|------------|---------|------|
| 后端架构 | 认证服务 + MinIO 两个独立组件 | 已在单 Rust 进程中（axum + SQLite + JWT） | **不拆**。在现有后端加同步 API |
| 对象存储 | MinIO 自托管 | VPS 文件系统 + Nginx | **不引入 MinIO**。state.json 存文件系统或 DB，通过 Nginx 分发 |
| 教师/家长角色 | 未考虑 | 有 admin_users, guardian_assignments, subscription_requests | **加密方案要分两层**：用户密钥（端侧加密）+ 平台密钥（教师可读） |
| 课堂同步链 | 仅学生→云端 | 学生→监护人（家长需求看进展）→教师（教师需求看全班） | 同步协议需支持家长/教师的跨用户读权限 |
| LLM 计算 | 未提及 | 云端跑 chat_engine, CP2, 概念提取（不可卸载到端侧） | 云端计算层保留，LLM 相关逻辑不动 |
| 共享内容版本管理 | 独立 SQLite 文件 + version.json | 当前 JSON 文件 + DB 表即可 | **不过度设计**，保持现有 JSON 文件 + 启动加载 |
| 同步粒度 | 全量覆盖 | 学生→家长→教师三方需要不同的数据视图 | 同步 API 需支持按权限过滤字段 |

### B.3 融合后的 CoEvo 云端架构

```
┌─────────────────────────────────────────────────────────┐
│                  云端（单 Rust 进程）                     │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐         │
│  │ 认证层    │  │ 计算层    │  │ 内容分发层     │         │
│  │ users     │  │ LLM 对话  │  │ cards         │         │
│  │ tokens    │  │ CP2 分析  │  │ quiz_bank     │         │
│  │ JWT       │  │ 概念提取  │  │ knowledge_    │         │
│  │           │  │ 制卡      │  │ graph         │         │
│  │           │  │ FSRS调度  │  │ plan_         │         │
│  │           │  │          │  │ templates(未)  │         │
│  └────┬──────┘  └────┬─────┘  └───────┬───────┘         │
│       │              │                │                 │
│       └──────────────┴────────────────┘                 │
│                         │                               │
│  ┌──────────────────────▼────────────────────────────┐  │
│  │  同步层（新增）                                    │  │
│  │  GET /api/sync/state  → 下载加密/明文 state.json  │  │
│  │  PUT /api/sync/state  → 上传加密 state.json       │  │
│  │  GET /api/sync/student/:id → 教师/家长查看        │  │
│  │  存储: /data/states/{user_id}/state.json          │  │
│  │  双密钥: 用户密码派生密钥（端侧加密）               │  │
│  │          + 平台主密钥（教师/家长解密用）            │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### B.4 同步 API 设计（新增 REST 端点）

```rust
// 在现有 routes.rs /api/ 下新增

/// 上传用户状态（端侧→云端）
// POST /api/sync/state
// Body: { state_json: "<AES-256-GCM 密文>" }
// 用平台密钥解密后存盘（校验签名、版本号）

/// 下载用户状态（云端→端侧）
// GET /api/sync/state
// Response: { state_json: "<AES-256-GCM 密文>", version: 2, updated_at: "..." }
// 端侧用自己的密码派生密钥解密

/// 教师/家长查看学生状态
// GET /api/sync/student/{student_id}
// Auth: admin 或 guardian（从 JWT 角色 + guardian_assignments 校验）
// Response: { state_json: "<平台密钥解密后的明文>", ... }
// 教师看到的是明文（去除了 conversation_turns 保护隐私的可选）
```

### B.5 加密方案

```
AES-256-GCM 双层加密（参考当前 PII 加密的 encryption.rs 模式）：

用户密码层（端侧加密上行的密文）：
  key = SHA-256(password + salt)
  加密 state.json → 上行密文

平台密钥层（云端转存时叠加：
  key = COEVO_SYNC_KEY（环境变量，类似 COEVO_PII_KEY）
  再次加密 → 存盘

教师读取时：
  1. 鉴权（admin / guardian 角色）
  2. 平台私钥解密
  3. 返回明文（可选移除敏感字段如 conversation_turns 详情）
```

### B.6 未采纳的过度设计

| 外部方案设计 | 不采用理由 |
|------------|----------|
| MinIO 对象存储 | 增加部署复杂度。当前 VPS 文件系统 + Nginx 足够。state.json 可存 `/opt/coevo/user-states/{user_id}.json` |
| 独立 auth.db | 当前 `users` + `tokens` 表已处理认证，再拆一个 SQLite 文件没有收益，反而增加事务复杂度 |
| 内容版本 SQLite 文件 | 当前 `curriculum_loader` 从 JSON 启动加载到内存的机制运行良好。只有 15 个 plan + 22 个 card 文件，编译时加载零延迟 |
| 增量同步（increments/） | 初期不需要。全量 state.json 30KB，每 5 分钟上传一次完全可接受 |
| CRDT / 操作日志 | 用户主要在一台设备学习。教师跨设备查看不需要实时 CRDT |

---

## 附录 C：增长场景对比

| 场景 | 当前架构 | 本地优先 | 差异 |
|------|---------|---------|------|
| 100 用户 | 云端 ~300MB DB | 云端 ~30MB + 用户各~3MB 本地 | 1:10 |
| 1000 用户 | 云端 ~3GB DB | 云端 ~30MB + 用户各~3MB 本地 | 1:100 |
| 10000 用户 | 云端 ~30GB DB | 云端 ~30MB | 1:1000 |
| 服务器成本 | 随用户线性增长 | 基本固定 | 显著 |
| 用户性能 | 依赖网络延迟 | 本地处理，零延迟 | 质变 |

云端数据增长仅限共享内容（卡片、题库、知识图谱），不随用户量增长。用户私有状态存在本地，云端只做加密备份/同步信道。
