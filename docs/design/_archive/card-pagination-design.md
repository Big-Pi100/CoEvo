# 卡片分页加载设计方案

> 2026-06-06 | 解决 `getDueCards` LIMIT 500 截断问题 + 全部卡片体验优化

---

## 问题背景

- `GET /api/review/due` 限制 500 条返回，多个 plan 的卡片因 due 时间分布不均被截断
- 物理 plan 187 张卡片因排在 568 张旧卡片之后，全部被 LIMIT 500 排除
- 全部卡片列表无分页，展开即全量加载，大量卡片时前端卡顿

---

## 一、复习页 Tab 队列

### 1.1 加载机制

| 参数 | 值 |
|------|-----|
| 队列上限 | 20 张 |
| 可见渲染 | 前 10 张 |
| 补货阈值 | 队列剩余 ≤ 10 张 |
| 补货量 | 10 张 |

### 1.2 流程

```
初始加载：按 conversation_id 拉 20 张 → 显示前 10 张
用户翻卡：
  - 提交复习结果 → 从队列移除已处理卡片
  - 队列 ≤ 10 张 → 自动再拉 10 张（补到 20）
  - 新卡片追加到队列末尾
页面展示始终只渲染前 10 张
```

### 1.3 后端 API

**请求** `GET /api/review/due?user_id={uid}&conversation_id={convId}&limit=20&offset=0`

**响应**
```json
{
  "cards": [{DueCard}, ...],
  "total_due": 187,
  "has_more": true
}
```

**SQL**
```sql
SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       cm.state, cm.reps, cm.lapses, c.created_at, cm.difficulty, cm.due, cm.last_review,
       (SELECT rating FROM review_log WHERE card_id = c.id ORDER BY reviewed_at DESC LIMIT 1),
       c.conversation_id
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
WHERE c.user_id = ?1
  AND c.conversation_id = ?2
  AND cm.status = 'active'
  AND cm.due <= ?3
ORDER BY cm.state ASC, cm.due ASC
LIMIT ?4 OFFSET ?5
```

**参数**: `user_id, conversation_id, now, limit, offset`

### 1.4 前端改动（review_screen.dart）

| 改动 | 说明 |
|------|------|
| `_loadCards()` | 改为按选中的 `_selectedConvId` 拉 20 张，取消全局 `getDueCards` |
| `_loadMoreCards()` | 补货函数：队列 ≤ 10 时触发，拉 10 张追加到 `_cards` |
| `_submitInlineReview()` | 提交复习结果后移除该卡片，检查补货阈值 |
| 移除 `_planDueCount()` 对 `_cards` 的依赖 | tab badge 改用 `_planTabs` 缓存的 `card_count`（已有） |

---

## 二、全部卡片分页

### 2.1 展示机制

| 层级 | 内容 |
|------|------|
| 第一层 | Plan 标题行（折叠/展开） |
| 第二层 | 展开后显示该 plan 的卡片列表 |
| 第三层 | 列表底部「加载更多」按钮 |
| 每页 | 20 张卡片 |
| 排序 | 按 `front` 字段字母顺序 |

### 2.2 流程

```
展开 plan：
  → GET /api/cards/by-plan?user_id=x&conversation_id=y&limit=20&offset=0&sort=front
  → 显示 20 张卡片
  → 底部「加载更多」按钮
  → 点击 → GET /api/cards/by-plan?...&offset=20
  → 追加 20 张
  → 重复直至 has_more=false
```

### 2.3 后端 API 修改

**请求** `GET /api/cards/by-plan?user_id={uid}&conversation_id={convId}&limit=20&offset=0&sort=front`

**现有 `cards_by_plan_handler` 修改**：
- 新增 `offset` 参数（`Option<i64>`，默认 0）
- 新增 `sort` 参数（`Option<String>`，默认 `front`）
- 当指定 `conversation_id` 时，使用分页查询 + 字母排序

**SQL（分页 + 按 front 排序）**
```sql
SELECT c.id, c.user_id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
       lrev.reviewed_at, lrev.rating, c.conversation_id
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
LEFT JOIN (SELECT card_id, MAX(reviewed_at) as last_reviewed_at FROM review_log GROUP BY card_id) lr ON c.id = lr.card_id
LEFT JOIN review_log lrev ON lrev.card_id = lr.card_id AND lrev.reviewed_at = lr.last_reviewed_at
WHERE c.conversation_id = ?1 AND c.user_id = ?2 AND cm.status = 'active'
ORDER BY c.front ASC
LIMIT ?3 OFFSET ?4
```

**新增字段**: 响应增加 `has_more: bool`

---

## 三、全文搜索 API

### 3.1 用途
替代前端本地过滤（受限于已加载范围），直接查库返回匹配结果。

### 3.2 API 定义

**请求** `GET /api/cards/search?user_id={uid}&q={keyword}&limit=20&offset=0`

**响应**
```json
{
  "cards": [{
    "id": "...", "front": "...", "back": "...",
    "domain": "...", "card_type": "...",
    "conversation_id": "...",
    "state": 0, "reps": 0
  }, ...],
  "total": 42,
  "has_more": true
}
```

**SQL**
```sql
SELECT c.id, c.user_id, c.front, c.back, c.domain, c.card_type,
       c.source_sentence, c.created_at, c.conversation_id,
       cm.state, cm.reps, cm.lapses, cm.difficulty, cm.due
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
WHERE c.user_id = ?1
  AND cm.status = 'active'
  AND (c.front LIKE ?2 OR c.back LIKE ?2)
ORDER BY c.front ASC
LIMIT ?3 OFFSET ?4
```

`?2` = `'%' || keyword || '%'`

### 3.3 前端调整

| 改动 | 说明 |
|------|------|
| 搜索框输入 | debounce 300ms 后调 `/api/cards/search` |
| 展示搜索结果 | 覆盖当前卡片列表，显示「搜索结果：共 X 条」|
| 清空搜索 | 恢复 plan 分组视图 |
| 搜索时 | 隐藏 state 过滤 badge（已取消此功能） |

---

## 四、移除功能

| 功能 | 文件 | 说明 |
|------|------|------|
| 状态过滤 badge | `card_list_screen.dart` | 去掉「全部/新/学习中/复习中/重学」按钮行 |
| `_applyFilters()` | `card_list_screen.dart` | 移除，搜索改走 API |
| `_allCards` 累积 | `card_list_screen.dart` | 不再需要，移除 |
| `_stateCounts` 累积 | `card_list_screen.dart` | 不再需要，移除 |

---

## 五、工作量估算

| 模块 | 文件 | 预估 |
|------|------|------|
| 后端：review_due 加 conversation_id 过滤 + offset | `routes.rs`, `fsrs_scheduler.rs` | 小 |
| 后端：cards_by_plan 加 offset + sort | `routes.rs` | 小 |
| 后端：cards/search 新路由 | `routes.rs` | 中 |
| 前端：复习 tab 队列 | `review_screen.dart` | 中 |
| 前端：全部卡片分页 | `card_list_screen.dart` | 中 |
| 前端：搜索 API 调用 | `chat_client.dart`, `card_list_screen.dart` | 小 |
| 前端：移除过滤/accumulate | `card_list_screen.dart` | 小 |

---

## 六、未定事项

- 卡片字母排序：中文按什么序？SQLite `ORDER BY front ASC` 对中文是 Unicode 码点序，对英文/拼音是否满足需求？
- 搜索 `LIKE` 对中文是否够用？是否需要拼音/模糊匹配？
