# 前端-后端 API 对齐审查报告

审查日期: 2025-06-05
范围: Flutter 前端全部 API 调用 vs Rust 后端处理程序响应形状

---

## P0 — 阅读模式全文数据断裂

### 问题
`chat_screen.dart` 通过 `k12ReadingCurrentCard()` 检测是否处于阅读模式，读取 `card['full_text']`：

```dart
// chat_screen.dart:157-164
final cardResult = await _client!.k12ReadingCurrentCard(_convId);
final card = cardResult['current_card'];
if (card != null && card is Map<String, dynamic> && card['full_text'] != null && 
    (card['full_text'] as String).isNotEmpty) {
```

但后端 `k12_reading_current_card_handler` (routes.rs:1660-1763) 仅返回：

```rust
Ok(serde_json::json!({
    "id": id,
    "card_type": card_type,
    "front": front,
    "back": back_val,   // 可能是 JSON 对象（poem 卡片）
}))
```

**`full_text`、`author`、`appreciation`、`technique`、`theme` 均不返回。**

### 影响
- `_isReading` 永远为 `false` → 阅读模式横幅永不显示
- `_buildReadingCardBanner()` 消失
- 「查看全文 →」按钮不可达
- `ReadingFullTextScreen` 永远无法被触发
- 即使手动 route 到 `/reading-full-text`，所有字段均 `null`

### 根因
V3 重构中移除了 `k12_reading_current_card_handler` 的阅读卡片展开逻辑。前端仍依赖旧响应格式。

### 修复建议
两个方案：
**A)** 后端 `k12_reading_current_card_handler` 在读取 `cards` 表的 `back` 字段后，解析其中的 JSON 结构提取 `full_text` 返回
**B)** 前端改为直接读取 `back` 字段（poem 卡片格式 `{"full_text": "...", "author": "...", ...}`），移除 `full_text` 独立字段的依赖

---

## P1 — CardListScreen 的 subject/subjects 已从后端移除

### 问题
`chat_client.dart` 的 `getAllCards()` 仍然发送 `subject` 参数：

```dart
// chat_client.dart:341-346
final params = <String, String>{'user_id': userId};
if (query != null && query.isNotEmpty) params['q'] = query;
// ...
if (subject != null && subject.isNotEmpty) params['subject'] = subject;
```

后端 `AllCardsQuery` (routes.rs:492-498) 移除了 `subject`：

```rust
pub struct AllCardsQuery {
    pub user_id: String,
    pub q: Option<String>,         // 搜索关键词
    pub state: Option<i32>,        // FSRS state 过滤
    pub domain: Option<String>,    // 领域过滤
    pub sort: Option<String>,      // 排序
    // subject 已被删除
}
```

同时 `cards_all_handler` 响应中不再返回 `subjects` 列表，但前端读取：

```dart
// card_list_screen.dart:90-91
final subjects = (resp['subjects'] as List<dynamic>?)
    ?.map((e) => e as String).toList() ?? [];
```

以及使用 `card.subject` 进行过滤：

```dart
// card_list_screen.dart:123
if (_subjectFilter != null && c.subject != _subjectFilter) return false;
```

### 影响
- K12 科目标签栏 (`_subjects`) 永远为空 → 用户看不到按科目过滤的 UI
- `subject` 查询参数被 axum 静默忽略（非错误）
- 功能区为死代码，不崩溃但无用

### 修复建议
清理 `card_list_screen.dart` 中所有 `_subjectFilter`、`_subjects` 相关死代码

---

## P1 — DueCard 模型包含已删除字段 subject/grade_band

### 问题
前端 `coevo_models.dart` 的 `DueCard` 模型仍声明 `subject` 和 `grade_band` 字段：

```dart
// coevo_models.dart:78-79
final String? subject;
final String? gradeBand;
```

后端 `DueCard` 结构体 (fsrs_scheduler.rs) 已完全移除：

```rust
pub struct DueCard {
    pub id: String,
    pub front: String,
    pub back: String,
    pub domain: Option<String>,
    // ... 无 subject, 无 grade_band
    pub conversation_id: Option<String>,
}
```

`fromJson` 通过 `as String?` 安全降级为 `null`，不会崩溃。

### 影响
- `review_screen.dart` 的 `_planDueCount()` 按 `conversationId` 分组 — 不受影响
- `card_list_screen.dart` 的 `_applyFilters()` 中 `c.subject != _subjectFilter` 在 `_subjectFilter` 为 `null` 时永远为 `false`（不过滤）
- 无显式错误，但存在误导性死字段

### 修复建议
从 `DueCard` 中删除 `subject` 和 `gradeBand` 字段

---

## P1 — ChatClient.sendMessage() 调用了已删除的 HTTP 端点

### 问题
`chat_client.dart` 中仍保留 `sendMessage()` 方法，通过 `POST /api/chat` 发送：

```dart
// chat_client.dart:39-41
final resp = await http.post(
  Uri.parse('$baseUrl/api/chat'),   // ⚠️ 此路由已删除
```

该路由在 V3 重构中被移除（转到 WS），routes.rs 中无对应路由。

### 影响
- 主流程使用 WS (`streamChat()`)，所以**运行时不会触发**
- 但如果任何代码路径意外调用 `sendMessage()`，将收到 404
- 死方法，无运行时影响但易误导

### 修复建议
删除 `sendMessage()` 方法，或标记为 `@Deprecated` 并抛异常

---

## P2 — K12 进度页面缺少 subject/grade_band

### 问题
`achievements_screen.dart` 尝试按 `subject` 和 `grade_band` 分组 K12 进度：

```dart
// achievements_screen.dart:290-294
final bySubject = <String, List<Map<String, dynamic>>>{};
for (final p in _k12Progress) {
  final subj = p['subject'] as String? ?? '';       // → 永远 ''
  bySubject.putIfAbsent(subj, () => []).add(p);
}
// ...
final band = g['grade_band'] as String? ?? '';        // → 永远 ''
final label = gradeLabels[band] ?? band;               // → ''
```

后端 `k12_progress_handler` (routes.rs:1826-1836) 仅返回：

```rust
Ok(serde_json::json!({
    "goal": goal,
    "total_cards": total_cards,
    "mastered_cards": mastered_cards,
    "reviewed_cards": (total_cards - mastered_cards).max(0),
    "started_at": started_at_ts,
    "last_activity_at": last_activity_ts,
    // 无 subject, 无 grade_band
}))
```

### 影响
- 所有进度条目按 `''` 分组 → 混杂在无标签的条目中
- 年级标签永远显示为 `''`（`gradeLabels['']` → `null` → `band` → `''`）
- 进度条仍显示，科目名称缺失

### 修复建议
后端从 `conversation_plans` 表读取 `subject` 字段加入响应，或前端改用 `goal` 字段作为分组依据

---

## ✅ 已验证对齐的 API

| API 端点 | 状态 | 备注 |
|----------|------|------|
| `POST /api/auth/register` | ✅ 对齐 | `{user_id, token}` |
| `POST /api/auth/login` | ✅ 对齐 | `{user_id, token}` |
| `POST /api/auth/verify` | ✅ 对齐 | `{valid: bool}` |
| `GET /api/review/due` | ✅ 对齐 | `{cards, total_due, has_more}` |
| `POST /api/review/submit` | ✅ 对齐 | `{status, achievements}` |
| `POST /api/review/verify` | ✅ 对齐 | `{questions}` |
| `POST /api/review/judge` | ✅ 对齐 | `{results, total_correct, total}` |
| `PATCH /api/cards/status` | ✅ 对齐 | `{status: "ok"}` |
| `PATCH /api/cards/batch-status` | ✅ 对齐 | `{updated, status}` |
| `GET /api/cards/all` | ⚠️ 部分对齐 | 响应无误但前端含死代码 |
| `GET /api/cards/{id}/last-review` | ✅ 对齐 | `{id,rating,verification_result,details,...}` |
| `GET /api/history` | ✅ 对齐 | `{conversations, count}` 含 title, turn_count |
| `GET /api/history?conversation_id=` | ✅ 对齐 | `{turns, total}` |
| `DELETE /api/conversations/{id}` | ✅ 对齐 | `{status, deleted_at}` |
| `POST /api/conversations/{id}/restore` | ✅ 对齐 | `{status: "ok"}` |
| `DELETE /api/conversations/{id}/permanent` | ✅ 对齐 | `{status: "ok"}` |
| `GET /api/user/{id}/profile` | ✅ 对齐 | `{stats, display_name, achievements, cefr_stats, ...}` |
| `PUT /api/user/{id}/profile` | ✅ 对齐 | 手动调用，无预期格式 |
| `POST /api/user/{id}/display-name` | ✅ 对齐 | `{status: "ok"}` |
| `GET /api/user/{id}/preferences` | ✅ 对齐 | `Map<String, String>` |
| `PUT /api/user/{id}/preferences` | ✅ 对齐 | `{status: "ok"}` |
| `GET /api/plans` | ✅ 对齐 | `{plans: [{id, conversation_id, goal, plan, ...}]}` |
| `GET /api/user/{id}/learning-report` | ✅ 对齐 | `{plans, stats, assessment}` |
| `GET /api/user/{id}/activity` | ✅ 对齐 | `{days: [{date, score, reviews, ...}]}` |
| `GET /api/user/{id}/weekly-report` | ✅ 对齐 | 未在 UI 渲染中验证 |
| `POST /api/k12/init` | ✅ 对齐 | `{conversation_id, plan}` |
| `POST /api/k12/reading/init` | ✅ 对齐 | `{conversation_id, plan, current_card, ...}` |
| `GET /api/k12/reading/{id}/current-card` | ❌ **断裂** | 返回 `{id, card_type, front, back}` 缺 `full_text` |
| `GET /api/k12/progress` | ⚠️ 部分对齐 | 缺 `subject`/`grade_band` 导致前端展示异常 |
| `POST /api/verify-translation` | ✅ 对齐 | `{result: "pass"|"fail"}` |
| WebSocket /ws | ✅ 对齐 | 事件类型: token/done/candidates/thinking/planning/error |

---

## 总结

| 等级 | 数量 | 关键项 |
|------|------|--------|
| 🔴 P0 | 1 | 阅读模式全文断裂，`ReadingFullTextScreen` 不可达 |
| 🟡 P1 | 3 | CardList subject 死代码、DueCard 残留字段、HTTP chat 死端点 |
| 🔵 P2 | 1 | K12 进度页面缺科目/年级标签 |

### 优先级修复顺序
1. **P0**: 修复 `k12_reading_current_card_handler` 返回 `full_text` 或前端改读 `back` 字段
2. **P1**: 清理 `CardListScreen` 的 subject 相关死代码
3. **P1**: 清理 `DueCard` 模型的 `subject`/`gradeBand`
4. **P1**: 删除 `ChatClient.sendMessage()` 死方法
5. **P2**: 修复 K12 进度页面的 subject/grade_band 缺失
