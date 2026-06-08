# E2E 测试与前端需求对齐文档

> 日期: 2026-06-05
> 范围: 6 个 e2e 集成测试 vs Flutter 前端所有 API 调用
> 原则: 每项测试必须使用与前端完全相同的 HTTP 请求/响应格式

---

## 1. e2e_api_lifecycle — 全链路主流程

### 覆盖场景
三种进对话入口对应三个独立测试函数：

| 场景 | 测试函数 | 模拟的前端入口 |
|------|---------|--------------|
| Free Chat | `e2e_api_free_chat` | 首页「开始对话」按钮 |
| K12 Structured | `e2e_api_k12` | 首页科目网格 → 选物理 → `g7-9` 年级 |
| Reading | `e2e_api_reading` | 首页科目网格 → 选语文 → `g3-4` 年级 |

### free chat 流程

| 步骤 | 前端触发 | 请求 API | 请求体 | 响应关键字段 |
|------|---------|---------|--------|------------|
| 注册 | — | `POST /api/auth/register` | `{username, password}` | `user_id`, `token` |
| 登录 | 登录页"登录"按钮 | `POST /api/auth/login` | `{username, password}` | `user_id`, `token` |
| 订阅检测 | 首页加载（隐式） | `PUT /api/user/{id}/preferences` | `{subscription_expires}` | — |
| 检查对话状态 | 进入对话页 | `GET /api/history` | `{user_id, conversation_id}` | `turns[]`, `total` |
| 检查计划 | 对话页渲染计划面板 | `GET /api/plans` | `{conversation_id}` | `plans[{goal, plan}]` |
| 发送消息 | 对话页输入框 → 发送 | WebSocket `/ws` | `{user_id, conversation_id, message, token}` | `done.reply`, `candidates[]`, `plan_updated` |
| 学生 LLM 回复 | 双 LLM 教学循环 | 调用 `student_llm`（内部工具） | 教师最后回复 | 自然语言回复 |
| 验证计划 | 对话中 CP2 检测 | `GET /api/plans` | `{conversation_id}` | `plans[].plan.stages[].tasks[]` |
| 验证历史 | 对话页历史记录 | `GET /api/history` | `{user_id, conversation_id}` | `turns[].role, content` |
| 验证卡片 | 卡片列表页 | `GET /api/cards/all` | `{user_id}` | `cards[].id, card_type` |
| 学习报告 | 成就/报告页 | `GET /api/user/{id}/learning-report` | — | `plans[], stats` |
| WS 排水 | 对话结束后残留事件 | WebSocket（被动接收） | — | `candidates[]`, `plan_updated` |

### K12 流程
在 free chat 基础上，步骤 3b 增加：

| 步骤 | 前端触发 | 请求 API | 请求体 | 响应关键字段 |
|------|---------|---------|--------|------------|
| K12 Init | 选科目 → 选年级 → 确认 | `POST /api/k12/init` | `{user_id, subject, grade_band}` | `conversation_id`, `resumed` |

### Reading 流程
在 free chat 基础上，步骤 3b 增加：

| 步骤 | 前端触发 | 请求 API | 请求体 | 响应关键字段 |
|------|---------|---------|--------|------------|
| Reading Init | 选语文 → 选年级 → 确认 | `POST /api/k12/reading/init` | `{user_id, subject, grade_band}` | `conversation_id`, `imported_cards`, `current_card` |

### WS 事件协议（全部场景通用）

| type | 前端处理位置 | 前端读取字段 | 测试验证 |
|------|------------|------------|---------|
| `thinking` | `_handleWsEvent` → 显示"思考中..." | — | 验证收到 ✅ |
| `token` | `_handleWsEvent` → 流式追加 | `content` | 可选验证 |
| `candidates` | 显示概念确认弹窗 | `candidates[]` | 验证收到并计数 |
| `plan_updated` | 刷新计划面板 | — | 记录 flag |
| `done` | 完成流式渲染 | `reply` | 验证 reply 非空 |
| `error` | 显示错误提示 | `content` | 测试 panic |

---

## 2. e2e_cards_lifecycle — 卡片状态管理

### 覆盖的前端页面
卡片列表页（`CardListScreen`）+ 复习页（`ReviewScreen`）

### 流程

| 步骤 | 前端触发 | 请求 API | 请求体 | 响应关键字段 |
|------|---------|---------|--------|------------|
| 注册 | — | `POST /api/auth/register` | `{username, password}` | `user_id`, `token` |
| 登录 | 登录页 | `POST /api/auth/login` | `{username, password}` | `token` |
| 订阅 | 首页（隐式） | `PUT /api/user/{id}/preferences` | `{subscription_expires}` | — |
| 数据准备 | 通过 SQL 直接创建 3 张测试卡片 | — | — | — |
| 验证卡片存在 | 卡片列表页加载 | `GET /api/cards/all` | `{user_id}` | `total >= 3` |
| 单张跳过 | 卡片列表 → 左滑 →「跳过」 | `PATCH /api/cards/status` | `{user_id, card_id, status: "skipped"}` | `status: "ok"` |
| 验证已跳过 | 卡片列表页刷新 | `GET /api/cards/all` | `{user_id}` | `total` 减 1 |
| 批量归档 | 长按多选（预留 UI） | `PATCH /api/cards/batch-status` | `{user_id, card_ids[], status: "archived"}` | `status: "ok"`, `updated >= 2` |
| 验证全移除 | 刷新列表 | `GET /api/cards/all` | `{user_id}` | `total == 0` |

### SQL 数据准备字段
```sql
INSERT INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at)
-- 不包含 plan_id / task_key（CP1 未创建 plan 时这些为 NULL）
```

---

## 3. e2e_conv_lifecycle — 对话管理

### 覆盖的前端页面
历史对话列表（`ConversationListScreen` → 左滑删除/恢复/彻底删除）

### 流程

| 步骤 | 前端触发 | 请求 API | 请求体/参数 | 响应关键字段 |
|------|---------|---------|-----------|------------|
| 注册 | — | `POST /api/auth/register` | `{username, password}` | `user_id`, `token` |
| 登录 | 登录页 | `POST /api/auth/login` | `{username, password}` | `token` |
| 数据准备 | 通过 SQL 创建 1 个对话 + 3 条轮次 | — | — | — |
| 验证存在 | 历史列表页 | `GET /api/history` | `{user_id}` | `conversations[].id` |
| 软删除 | 左滑 → 删除 | `DELETE /api/conversations/{id}` | `{user_id}` | `status: "ok"`, `deleted_at` |
| 验证不在活跃列表 | 刷新历史列表 | `GET /api/history` | `{user_id}` | `conversations` 不含该 id |
| 验证在回收站 | 回收站页（预留 UI） | `GET /api/history` | `{user_id, include_deleted: "only"}` | `conversations` 含该 id |
| 恢复 | 回收站 → 恢复 | `POST /api/conversations/{id}/restore` | `{user_id}` | status 200 |
| 验证已恢复 | 刷新活跃列表 | `GET /api/history` | `{user_id}` | `conversations` 含该 id |
| 彻底删除 | 左滑 → 永久删除 | `DELETE /api/conversations/{id}/permanent` | `{user_id}` | status 200 |
| 验证消失 | 全量列表 | `GET /api/history` | `{user_id, include_deleted: "true"}` | `conversations` 不含该 id |

### SQL 数据准备字段
```sql
INSERT INTO conversations (id, user_id, turn_count, started_at)
INSERT INTO conversation_turns (id, conversation_id, role, content, created_at)
-- conversation_id 使用固定值 test_conv_mgmt
```

---

## 4. e2e_k12_extra_lifecycle — K12 进度与阅读卡片

### 覆盖的前端页面
成就页（`AchievementsScreen` 的 K12 进度区）+ 课文阅读页（`ReadingFullTextScreen`）

### 流程

| 步骤 | 前端触发 | 请求 API | 请求体/参数 | 响应关键字段 |
|------|---------|---------|-----------|------------|
| 注册 | — | `POST /api/auth/register` | `{username, password}` | `user_id`, `token` |
| 登录 | 登录页 | `POST /api/auth/login` | `{username, password}` | `token` |
| 空进度检查 | 成就页加载 | `GET /api/k12/progress` | `{user_id}` | `progress[]`（空数组） |
| 数据准备 | 通过 SQL 插入 2 个 `conversation_plans` + 相关数据 | — | — | — |
| 有数据进度检查 | 成就页加载 | `GET /api/k12/progress` | `{user_id}` | `progress[].goal, total_cards, mastered_cards` |
| 阅读当前卡片 | 阅读模式 → 全文页 | `GET /api/k12/reading/{conv_id}/current-card` | `{user_id}` | `{current_card: {id, card_type, front, back}}` |
| 无效 conv 测试 | — | `GET /api/k12/reading/{wrong_id}/current-card` | `{user_id}` | `{error: "..."}` |

### SQL 数据准备字段
```sql
INSERT INTO conversation_plans (id, user_id, conversation_id, goal, plan_content, created_at, updated_at)
-- plan_content 包含 JSON: {"goal": "...", "stages": [{"name": "...", "tasks": [...]}]}
```

---

## 5. e2e_profile_lifecycle — 用户资料与活动

### 覆盖的前端页面
个人资料页（`ProfileScreen`）+ 设置页（偏好设置）

### 流程

| 步骤 | 前端触发 | 请求 API | 请求体/参数 | 响应关键字段 |
|------|---------|---------|-----------|------------|
| 注册 | — | `POST /api/auth/register` | `{username, password}` | `user_id`, `token` |
| 登录 | 登录页 | `POST /api/auth/login` | `{username, password}` | `token` |
| Token 验证 | 首页恢复登录（隐式） | `POST /api/auth/verify` | `{user_id, token}` | `valid: true` |
| 获取资料 | 个人页 → 加载 | `GET /api/user/{id}/profile` | — | `{display_name, stats: {streak_days, ...}}` |
| 设置昵称 | 个人页 → 修改昵称 | `POST /api/user/{id}/display-name` | `{display_name}` | status 200 |
| 获取偏好 | 设置页 → 加载 | `GET /api/user/{id}/preferences` | — | `{key: value}` 映射 |
| 保存偏好 | 设置页 → 保存 | `PUT /api/user/{id}/preferences` | `{key: value}` | status 200 |
| 获取活动 | 成就页 → 热力图 | `GET /api/user/{id}/activity` | `{days: 30}` | `days[{date, score, reviews}]` |
| 获取周报 | 成就页 → 周报区 | `GET /api/user/{id}/weekly-report` | — | `{new_cards, reviews, active_plan}` |

---

## 6. e2e_ws_lifecycle — WebSocket 协议验证

### 覆盖的前端页面
对话页（`ChatScreen`）发送首条消息

### 流程

| 步骤 | 前端触发 | 请求 | 响应 | 验证 |
|------|---------|------|------|------|
| 注册 | — | `POST /api/auth/register` | `user_id, token` | 有 user_id |
| 登录 | 登录页 | `POST /api/auth/login` | `token` | 有 token |
| 订阅 | 首页（隐式） | `PUT /api/user/{id}/preferences` | — | status 200 |
| WS 连接 | 对话页 → 发消息 | WebSocket `/ws` → 发送 ChatRequest | — | 连接成功 |
| 事件接收 | 同上 | — | `thinking` 事件 | 验证收到 |
| 事件接收 | 同上 | — | `token` 事件（可选） | 可选 |
| 事件接收 | 同上 | — | `done` 事件含 reply | reply 非空且 > 20 字 |
| 事件接收 | 同上 | — | `candidates` 事件（可选） | 可选 |
| 连接关闭 | WS 回复结束 | — | Close frame | 正常关闭 |

### WS ChatRequest 格式
```json
{
  "user_id": "用户 UUID",
  "conversation_id": "会话 UUID",
  "message": "用户输入文本",
  "token": "Bearer token 字符串"
}
```

### WS 事件格式
```json
{"type": "thinking"}
{"type": "token", "content": "..."}
{"type": "candidates", "candidates": ["概念1", "概念2"]}
{"type": "plan_updated"}
{"type": "done", "reply": "完整回复文本", "candidates": [...]}
{"type": "error", "content": "错误描述"}
```

---

## 测试覆盖矩阵

| Frontend API | 前端页面 | e2e_api | e2e_cards | e2e_conv | e2e_k12 | e2e_profile | e2e_ws |
|------------|---------|---------|-----------|---------|---------|------------|--------|
| Register | 登录/注册页 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Login | 登录页 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Token Verify | 首页恢复 | — | — | — | — | ✅ | — |
| Preferences | 设置页 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| K12 Init | 科目网格 | ✅ | — | — | — | — | — |
| Reading Init | 语文科目 | ✅ | — | — | — | — | — |
| WS Chat | 对话页 | ✅ | — | — | — | — | ✅ |
| History (list) | 历史对话列表 | — | — | ✅ | — | — | — |
| History (turns) | 对话页历史 | ✅ | — | ✅ | — | — | — |
| Plans | 计划面板 | ✅ | — | — | — | — | — |
| Cards all | 卡片列表页 | ✅ | ✅ | — | — | — | — |
| Cards status | 卡片列表左滑 | — | ✅ | — | — | — | — |
| Cards batch-status | 预留批量操作 | — | ✅ | — | — | — | — |
| Conv DELETE | 历史列表左滑 | — | — | ✅ | — | — | — |
| Conv RESTORE | 回收站恢复 | — | — | ✅ | — | — | — |
| Conv PERMANENT | 彻底删除 | — | — | ✅ | — | — | — |
| K12 progress | 成就页进度 | — | — | — | ✅ | — | — |
| Reading current-card | 阅读全文页 | — | — | — | ✅ | — | — |
| Profile | 个人页 | ✅ | — | — | — | ✅ | — |
| Display name | 个人页 | — | — | — | — | ✅ | — |
| Activity | 成就页热力图 | — | — | — | — | ✅ | — |
| Weekly report | 成就页周报 | — | — | — | — | ✅ | — |
| Learning report | 学习报告页 | ✅ | — | — | — | — | — |

---

## 未覆盖的前端 API

| API | 前端页面 | 原因 |
|-----|---------|------|
| `POST /api/user/{id}/avatar` | 个人页头像上传 | 涉及文件上传，需额外测试策略 |
| `POST /api/verify-translation` | 复习页翻译验证 | 当前无对应 e2e |
| `POST /api/review/due` | 复习页获取待复习卡片 | 仅 `e2e_api_lifecycle` 间接覆盖 |
| `POST /api/review/submit` | 复习页提交评分 | 同上 |
| `POST /api/review/verify` | 复习页 LLM 出题 | 同上 |
| `POST /api/review/judge` | 复习页批改 | 同上 |
| `PATCH /api/cards/status` (single) | 卡片列表跳过 | `e2e_cards` |
| `DELETE /api/conversations/{id}/permanent` | 回收站删除 | `e2e_conv` |
| Admin APIs | 管理后台 | 前端 guardian_screen 是独立 Web 页面 |
