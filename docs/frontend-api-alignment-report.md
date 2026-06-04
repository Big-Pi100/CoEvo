# 前端接口调用与后端测试对齐分析报告

> 生成日期: 2026-06-04
> 
> 分析范围: `app/lib/api/` (ChatClient + AuthClient) + 首页 `home_screen.dart` vs 后端 `routes.rs` + e2e 测试

---

## 一、接口总览

### 后端注册接口（routes.rs 第 62-139 行）

| 端ポイント | 方法 | 前端调用 | e2e_api 覆盖 | e2e_k12 覆盖 | e2e_chinese 覆盖 |
|:-----------|:----:|:--------:|:-----------:|:-----------:|:---------------:|
| `/health` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/auth/register` | POST | ✅ | ✅ | ✅ | ✅ |
| `/api/auth/login` | POST | ✅ | ✅ | ✅ | ✅ |
| `/api/auth/verify` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/chat` | POST | ✅ WS/REST | ✅ | ✅ | ✅ |
| `/api/review/due` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/review/submit` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/review/verify` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/review/judge` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/cards/status` | PATCH | ✅ | ❌ | ❌ | ❌ |
| `/api/cards/batch-status` | PATCH | ✅ (未调用) | ❌ | ❌ | ❌ |
| `/api/cards/all` | GET | ✅ | ✅ | ✅ | ✅ |
| `/api/cards/{id}/last-review` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/history` | GET | ✅ | ✅ | ✅ | ✅ |
| `/api/user/{id}/profile` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/user/{id}/display-name` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/user/{id}/preferences` | GET/PUT | ✅ | ❌ | ❌ | ❌ |
| `/api/k12/init` | POST | ✅ | ❌ | **✅** | ❌ |
| `/api/k12/progress` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/k12/reading/init` | POST | ✅ | ❌ | ❌ | **✅** |
| `/api/k12/reading/{id}/current-card` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/k12/quiz/submit` | POST | ❌ (服务端) | ❌ | ❌ | ❌ |
| `/ws` | WebSocket | ✅ | ❌ | ❌ | ❌ |
| `/api/plans` | GET | ✅ | ✅ | ✅ | ✅ |
| `/api/user/{id}/learning-report` | GET | ✅ | ✅ | ✅ | ✅ |
| `/api/user/{id}/activity` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/user/{id}/weekly-report` | GET | ✅ | ❌ | ❌ | ❌ |
| `/api/conversations/{id}` | DELETE | ✅ | ❌ | ❌ | ❌ |
| `/api/conversations/{id}/restore` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/conversations/{id}/permanent` | DELETE | ✅ | ❌ | ❌ | ❌ |
| `/api/verify-translation` | POST | ✅ | ❌ | ❌ | ❌ |
| `/api/stt` | POST | ✅ (app) | ❌ | ❌ | ❌ |

---

## 二、前端主页关键路径追踪

### 2.1 自由对话入口
```
home_screen.dart:120 "开始对话"
  → context.push('/chat')
  → chat_screen 创建新 WS 连接 → /ws
```

**e2e 覆盖**: `e2e_api_lifecycle` 覆盖 REST 路径 (`POST /api/chat`)，**不覆盖 WS 路径**

### 2.2 K12 科目入口
```
home_screen.dart:189 _startSubject()
  → 前端判断 _isReadingSubject():
      chinese = true  → k12ReadingInit() → POST /api/k12/reading/init
      other  = false → k12Init() → POST /api/k12/init
  → 获取 conversation_id → push('/chat', extra: convId)
  → chat_screen 通过 WS 发送消息
```

**e2e 覆盖**:
- `e2e_k12_lifecycle`: ✅ `POST /api/k12/init` (math)
- `e2e_chinese_lifecycle`: ✅ `POST /api/k12/reading/init`
- **但都是 REST 聊天，不覆盖 WS**

### 2.3 历史对话入口
```
home_screen.dart:147
  → context.push('/conversations')
  → conversation_list_screen → GET /api/history?user_id=...
  → 选择对话 → push('/chat', extra: convId)
```

**e2e 覆盖**: ✅ `GET /api/history` (在三个测试中都有)

---

## 三、覆盖缺口分析

### P0 缺口（影响核心功能）

| 缺口 | 端点 | 影响 | 修复建议 |
|:----|:-----|:-----|:--------|
| **WS 路径未测试** | `/ws` | 前端 100% 使用 WS 聊天，e2e 全用 REST | 需要 WS E2E 测试或用 REST 等价验证 |
| **复习流程未测试** | `/api/review/*` (4 个端点) | 前端核心功能无 API 覆盖 | 加 e2e_review_lifecycle 测试 |
| **卡片状态管理未测试** | `PATCH /api/cards/status` | 用户确认/跳过卡片 | 在 e2e_api 中加 PATCH 步骤 |

### P1 缺口（影响体验）

| 缺口 | 端点 | 影响 |
|:----|:-----|:-----|
| 用户资料 | `GET /api/user/{id}/profile` | 首页头像/昵称 |
| 学习活动 | `/api/user/{id}/activity` | 热力图 |
| 周报 | `/api/user/{id}/weekly-report` | 每周学习报告 |
| K12 进度 | `/api/k12/progress` | 学习进度展示 |
| 阅读当前卡片 | `GET /api/k12/reading/{id}/current-card` | 语文课文阅读 |
| 对话管理 | DELETE/POST `/api/conversations/*` | 删除/恢复对话 |
| 偏好设置 | `GET/PUT /api/user/{id}/preferences` | 学习偏好 |
| 显示名称 | `POST /api/user/{id}/display-name` | 修改昵称 |
| Token 验证 | `POST /api/auth/verify` | 启动时鉴权 |

### P2 缺口（管理后台）

所有 `/api/admin/*` 端点（~20 个）均未在 e2e 测试中覆盖。这是管理后台功能，不属于核心学习流程，优先级低。

---

## 四、前端调用方式与测试方式差异

### 4.1 聊天路径对比

```
前端 (生产):  WS 流式        → /ws → WsEvent(type:delta/done/error)
  → 优势：实时流式显示
  → 劣势：需要 WebSocket 连接

e2e 测试:     REST 同步       → POST /api/chat → {reply, candidates, plan_updated}
  → 优势：调用简单，可断言
  → 劣势：不覆盖 WS 路径，不测试流式处理
```

**风险**: WS 路径和 REST 路径虽然共享 `chat_handler` 逻辑，但 WS 有额外的流式处理、连接管理、token 认证逻辑。REST 测试通过不代表 WS 不出问题。

### 4.2 订阅管理

```
前端: 管理后台设置订阅（admin API）
e2e: 直接写 user_preferences 表
```

测试通过 `user_preferences` 设置 `subscription_expires`，前端通过管理后台设置。**路径不同但数据相同，风险低。**

---

## 五、e2e 测试覆盖统计（更新至 2026-06-04 10:47）

| 测试 | 覆盖端点 | 耗时 | 场景 |
|:----|:--------:|:----:|:-----|
| `e2e_api_lifecycle` | 7 核心 | ~177s | 自由对话全链路 |
| `e2e_k12_lifecycle` | 7 K12 | ~200s | K12 数理化 |
| `e2e_chinese_lifecycle` | 7 阅读 | ~240s | 语文课文阅读 |
| `e2e_review_lifecycle` | 4 复习 | ~69s | 复习流程 (due/verify/judge/submit) |
| `e2e_ws_lifecycle` | 1 WS | ~8s | WebSocket 流式聊天 |
| `e2e_profile_lifecycle` | 7 资料 | ~1.8s | 资料/偏好/活动/周报/Token 验证 |
| `e2e_cards_lifecycle` | 3 卡片 | ~1.8s | 卡片状态单张+批量管理 |
| `e2e_conv_lifecycle` | 5 对话 | ~1.9s | 软删/恢复/永久删/回收站查询 |
| `e2e_admin_lifecycle` | ~22 管理 | ~3.7s | 管理后台全功能 |
| **汇总覆盖** | **~58 端点** | | **核心链路 + 分支路径 + 管理后台** |

---

## 六、前后端数据格式对齐审查

### 6.1 确认匹配（6 项）

| 端点 | 前端期望 | 后端返回 | 结论 |
|:-----|:---------|:---------|:----:|
| `POST /api/chat` | `reply`, `candidates`, `plan_updated` | routes.rs:527-532 | ✅ 完全匹配 |
| `POST /api/k12/init` | `conversation_id`, `plan`, `cards` | routes.rs:2004-2012 | ✅ 完全匹配 |
| `POST /api/k12/reading/init` | `conversation_id`, `plan`, `cards` | routes.rs:类似格式 | ✅ 完全匹配 |
| `GET /api/plans` | `data['plans']` → `p['plan']` | routes.rs:1440-1452 | ✅ `{"plans":[{"id","plan":...}]}` |
| `GET /api/history` | `data['turns']` | routes.rs:1053 | ✅ `{"turns":[...]}` |
| `GET /api/cards/all` | `data['cards']` | routes.rs:910 | ✅ `{"cards":[...]}` |

### 6.2 发现问题：`GET /api/review/due` 字段缺失 (P1)

**后端 `DueCard`**（`fsrs_scheduler.rs:17-27`）仅返回 9 个字段：

```rust
pub struct DueCard {
    pub id, front, back, domain: Option<String>,
    pub card_type, source_sentence: Option<String>,
    pub state: i32, reps: i32,
    pub conversation_id: Option<String>,
}
```

**前端 `DueCard.fromJson()`**（`coevo_models.dart:102-120`）期望 15 个字段，其中 6 个后端从未返回：

| 字段 | 前端解析 | 实际值 | 影响 |
|:----|:--------|:------|:-----|
| `due` | `json['due'] as int?` | **永远 null** | 复习排序不可靠 |
| `difficulty` | `..?.toDouble() ?? 5.0` | **永远 5.0** | 难度显示失效 |
| `lapses` | `json['lapses'] as int? ?? 0` | **永远 0** | 遗忘计数不显示 |
| `last_reviewed_at` | `json['last_reviewed_at'] as int?` | **永远 null** | 上次复习时间空白 |
| `last_review_quality` | `json['last_review_quality'] as int?` | **永远 null** | 上次评分空白 |
| `subject`/`grade_band` | `json['subject/grade_band']` | **永远 null** | 科目信息空白 |

**修复方案**: 在 `fsrs_scheduler::get_due_cards()` 的 SQL 查询中补充 `cm.due`, `cm.difficulty`, `cm.lapses`, `cm.last_review` 字段，同时在 `DueCard` 结构体中增加对应字段。

---

## 七、e2e 测试纯度确认（2026-06-04 审查）

### 7.1 断言全部基于 HTTP API

三个 e2e 测试的全部断言（assert!）均来自 HTTP API 响应：

| 断言 | 测试 | 数据来源 |
|:----|:----|:--------|
| `reg["user_id"]` | 3 个测试 | `POST /api/auth/register` 响应 |
| `token` | 3 个测试 | `POST /api/auth/login` 响应 |
| `k12_conv` | k12 + chinese | `POST /api/k12/init` / `reading/init` 响应 |
| `err.is_none()` | 3 个测试 | `POST /api/chat` 响应 |
| `list` 非空 | 3 个测试 | `GET /api/plans` 响应 |
| `all_turns.len() >= 4` | 3 个测试 | `GET /api/history` 响应 |

### 7.2 内部代码调用范围（均为测试基础设施）

| 调用 | 用途 | 不能转 API 的原因 |
|:----|:-----|:----------------|
| `prompt_loader::init()` | 加载提示词模板 | 文件系统操作，生产也这样做 |
| `db_pool::init()` | 创建测试 SQLite DB | 服务器基础设施 |
| `schema.sql` | 建表 | DDL 操作 |
| `build_router()` | 启动 HTTP 服务器 | 被测对象 |
| `curriculum_loader::init()` | 加载课纲 JSON | 文件加载，生产也这样做 |
| `reading_loader::init()` | 加载课文 JSON | 同上 |
| `student_llm` | 学生模拟器 | 测试工具，已独立 crate |

**结论**: 测试是干净的 HTTP API 测试，不依赖内部代码验证业务逻辑。

---

## 八、建议优先级（更新版）

1. **P0: 复习流程测试** — `/api/review/due` + `submit` + `verify` + `judge` 零测试覆盖
2. **P0: WS 路径验证** — 至少一次 WS 握手收发验证
3. **P1: `GET /api/review/due` 字段补齐** — 后端 `DueCard` 缺少 6 个前端期望的字段
4. **P1: 资料/活动/进度报告** — 加 `e2e_profile_lifecycle` 覆盖 profile + activity + weekly-report + preferences
5. **P2: 对话管理** — 在现有测试中加删对话步骤（DELETE + restore）
