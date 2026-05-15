# 历史会话删除/恢复功能 — 完整设计与影响范围

> 日期: 2026-05-15
> 版本: V1.1

---

## 一、设计方案：软删除 + 回收站恢复 + 定时清理

### 1.1 生命周期状态机

```
  新建对话 ──→ 活跃 (deleted_at = NULL)
                  │
                  │ 用户左滑删除 → 确认弹窗
                  ▼
             已删除 (deleted_at = 当前时间)
                  │
        ┌─────────┴─────────┐
        │                   │
    回收站中点"恢复"      30天后定时清理
        │                   │
        ▼                   ▼
     活跃               物理删除
                     (DELETE conversations
                      + 级联删 turns)
```

### 1.2 用户交互（简化版，无撤销）

```
删除:
  活跃Tab → 左滑 → 确认弹窗 → 软删除 → 对话移至回收站

恢复:
  切换到"已删除"Tab → 点"恢复"按钮 → 回到活跃Tab

彻底删除:
  已删除Tab → 点"彻底删除" → 二次确认 → 物理删除
```

---

## 二、数据库变更

### migrations（main.rs 新增）

```sql
ALTER TABLE conversations ADD COLUMN deleted_at TEXT DEFAULT NULL;
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
```

### 现有查询影响

| 查询位置 | 当前 | 修改 |
|---------|------|------|
| `history_handler` 对话列表 | `SELECT ... FROM conversations WHERE user_id = ?1` | 加 `AND deleted_at IS NULL`（默认）或 `AND deleted_at IS NOT NULL`（回收站） |
| `history_handler` 轮次查询 | 通过 conversation_id 精确查询 | 无需修改 |
| `learning_report` 统计 | 子查询 `SELECT id FROM conversations WHERE user_id = ?1` | 加 `AND deleted_at IS NULL` |
| `activity_handler` 热力图 | 同上模式 | 同上 |
| `weekly_report` | 同上模式 | 同上 |
| `chat_handler` / `ws.rs` 写入 | `INSERT OR IGNORE INTO conversations` | 无需修改 |

---

## 三、后端 API 变更

### 新增端点

| Method | Path | 说明 | 鉴权 |
|--------|------|------|------|
| `DELETE` | `/api/conversations/{conv_id}` | 软删除（设 deleted_at） | Bearer |
| `POST` | `/api/conversations/{conv_id}/restore` | 恢复（清 deleted_at） | Bearer |
| `DELETE` | `/api/conversations/{conv_id}/permanent` | 物理删除 + 级联删除 conversation_turns | Bearer |

### 修改端点

| Method | Path | 修改 |
|--------|------|------|
| `GET` | `/api/history` | 新增 `include_deleted` 参数：`false`(默认)=活跃, `true`=全部, `only`=仅已删除 |

### 新增路由（routes.rs）

```rust
.route("/api/conversations/{conv_id}", delete(conversation_delete_handler))
.route("/api/conversations/{conv_id}/restore", post(conversation_restore_handler))
.route("/api/conversations/{conv_id}/permanent", delete(conversation_permanent_delete_handler))
```

### 定时清理（30天）

```rust
// main.rs 启动时 spawn 后台任务
tokio::spawn(async move {
    loop {
        tokio::time::sleep(Duration::from_secs(86400)).await; // 每天一次
        let conn = db_pool::get_conn();
        let cutoff = (Utc::now() - Duration::days(30)).to_rfc3339();
        // 物理删除: 先删 turns，再删 conversations
        conn.execute_batch(&format!(
            "DELETE FROM conversation_turns WHERE conversation_id IN (SELECT id FROM conversations WHERE deleted_at IS NOT NULL AND deleted_at < '{}');
             DELETE FROM conversations WHERE deleted_at IS NOT NULL AND deleted_at < '{}';",
            cutoff, cutoff
        )).ok();
    }
});
```

---

## 四、前端完整设计方案

### 4.1 页面布局

对话列表页面顶部使用 TabBar 分为两栏，同一页面内切换：

```
┌──────────────────────────────────────────────────┐
│  ← 对话列表                                       │
├──────────────────────────────────────────────────┤
│  [活跃 (3)]                [已删除 (1)]            │  ← TabBar
├──────────────────────────────────────────────────┤
│                                                  │
│  ← 活跃 Tab 内容 →          ← 已删除 Tab 内容 →    │
│                                                  │
│  ┌────────────────────────┐ ┌──────────────────┐ │
│  │ 🏷️ 初中物理       ←──  │ │ 🏷️ 旧对话         │ │
│  │    5轮 · 2小时前   🗑️  │ │   3轮 · 删除于3天前│ │
│  └────────────────────────┘ │ [恢复] [彻底删除]  │ │
│  ┌────────────────────────┐ └──────────────────┘ │
│  │ 🏷️ Rust入门        ←── │                      │
│  │    12轮 · 昨天      🗑️ │ 💡 30天后自动清理    │
│  └────────────────────────┘                      │
│  ┌────────────────────────┐                      │
│  │ 🏷️ Python基础           │                      │
│  │    3轮 · 3天前          │                      │
│  └────────────────────────┘                      │
└──────────────────────────────────────────────────┘
```

### 4.2 活跃 Tab — 左滑删除

左滑露出红色删除按钮，点击触发确认弹窗，确认后软删除。

```dart
Dismissible(
  key: Key(conv['id']),
  direction: DismissDirection.endToStart,
  background: Container(
    alignment: Alignment.centerRight,
    padding: EdgeInsets.only(right: 20),
    color: Colors.red,
    child: Icon(Icons.delete, color: Colors.white),
  ),
  confirmDismiss: (_) => _showDeleteDialog(conv),
  child: _buildConversationTile(conv),
);
```

### 4.3 删除确认弹窗

```dart
Future<void> _showDeleteDialog(Map<String, dynamic> conv) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('删除「${conv['title']}」'),
      content: Text('对话将移至回收站，30天内可恢复。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed == true && mounted) {
    await _doDelete(conv);
    _load(); // 刷新两个列表
  }
}
```

### 4.4 已删除 Tab — 回收站

```
┌──────────────────────────────────────────────────┐
│  ← 对话列表                                       │
├──────────────────────────────────────────────────┤
│  [活跃 (2)]          [已删除 (1)]                  │
├──────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────────────────────────────┐        │
│  │ 🏷️ 初中物理学习                      │        │
│  │    5轮对话 · 删除于 2小时前            │        │
│  │    [恢复]              [彻底删除]      │        │
│  └──────────────────────────────────────┘        │
│                                                  │
│  💡 已删除的对话将在30天后自动清理                  │
│                                                  │
└──────────────────────────────────────────────────┘
```

```dart
// 已删除对话的 ListTile
Widget _buildDeletedTile(Map<String, dynamic> conv) {
  final deletedAt = conv['deleted_at'] as String? ?? '';
  return Card(
    child: ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.grey.shade200,
        child: Icon(Icons.delete_outline, color: Colors.grey),
      ),
      title: Text(conv['title'] ?? '新对话', 
        style: TextStyle(color: Colors.grey.shade600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${conv['turn_count']}轮对话 · 删除于 $_formatDate(deletedAt)',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            icon: Icon(Icons.restore, size: 18),
            label: Text('恢复'),
            onPressed: () => _restoreConversation(conv),
          ),
          SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.delete_forever, size: 20, color: Colors.red.shade300),
            tooltip: '彻底删除',
            onPressed: () => _permanentDelete(conv),
          ),
        ],
      ),
    ),
  );
}
```

### 4.6 彻底删除确认

```dart
Future<void> _permanentDelete(Map<String, dynamic> conv) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('彻底删除'),
      content: Text('「${conv['title']}」将被永久删除，无法恢复。确定继续？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: Text('彻底删除'),
        ),
      ],
    ),
  );
  if (confirmed == true && mounted) {
    final client = _makeClient();
    await client.permanentDeleteConversation(conv['id']);
    _loadDeleted(); // 刷新已删除列表
  }
}
```

### 4.7 chat_screen 防护

```dart
// chat_screen.dart _init() 中，加载历史前检查对话是否已删除
final history = await _client!.getConversationTurns(_convId);
// 如果对话已被软删除，getConversationTurns 仍能返回数据（轮次未删）
// 但前端应在 UI 上提示用户此对话已删除
// 当前简化处理：允许查看已删除对话的历史，但显示"此对话已被删除"横幅
```

---

## 五、永久删除策略

| 方式 | 触发 | 说明 |
|------|------|------|
| 用户手动 | 回收站 → 点"彻底删除" → 二次确认 | 物理删除 conversations + 级联删 conversation_turns |
| 定时清理 | 服务端每天凌晨检查 | `deleted_at < 30天前` → 物理删除 |
| 首次实现 | 仅支持手动 | 定时清理作为后续迭代 |

**30 天宽限期理由**：给用户足够时间反悔，同时避免数据库无限膨胀。

---

## 六、前端新增代码清单

```
conversation_list_screen.dart:
  + _selectedTab: int                        // TabBar 索引 (0=活跃, 1=已删除)
  + _deletedConversations: List<Map>         // 已删除列表
  + _loadActive()                            // 加载活跃列表
  + _loadDeleted()                           // 加载已删除列表
  + _showDeleteDialog(conv)                  // 删除确认弹窗
  + _doDelete(conv)                          // 执行软删除 → 刷新两列表
  + _restoreConversation(conv)               // 恢复 → 刷新两列表
  + _permanentDelete(conv)                   // 彻底删除 + 二次确认
  + _buildActiveList()                       // 活跃列表（含 Dismissible）
  + _buildDeletedList()                      // 已删除列表
  + _buildDeletedTile(conv)                  // 已删除项（恢复/彻底删除按钮）

chat_client.dart:
  + deleteConversation(convId)               // DELETE /api/conversations/{id}
  + restoreConversation(convId)              // POST /api/conversations/{id}/restore
  + permanentDeleteConversation(convId)      // DELETE /api/conversations/{id}/permanent
  ~ getConversationList({includeDeleted})    // 加参数

chat_screen.dart:
  + _isDeleted bool                          // 对话是否已删除
  + _buildDeletedBanner()                    // "此对话已被删除"提示横幅
```

---

## 七、影响范围汇总

| 层级 | 文件 | 改动量 | 内容 |
|------|------|--------|------|
| DB | `main.rs` | +3 行 | migration |
| 后端 | `routes.rs` | ≈80 行 | 3 新 handler + 3 query 修改 |
| 后端 | `ws.rs` | 0 | 无需修改 |
| 前端 | `conversation_list_screen.dart` | ≈150 行 | TabBar + Dismissible + 弹窗 + 回收站 + 彻底删除 |
| 前端 | `chat_client.dart` | ≈40 行 | 3 新方法 + 参数 |
| 前端 | `chat_screen.dart` | ≈20 行 | 已删除横幅 |
| API | `API.md` | ≈20 行 | 3 新端点 + 修改 |

**总计：≈6 文件，≈310 行**

---

## 八、风险点

| 风险 | 缓解 |
|------|------|
| 已删除对话的学习计划仍在 DB | 无需处理——计划绑定 conversation_id，恢复对话时计划也恢复 |
| 已删除对话仍可通过 URL 直接访问 | chat_screen 显示"此对话已被删除"横幅 + 禁用输入 |
| 物理删除后 conversation_turns 孤儿记录 | 使用子查询级联删除 |
| 回收站数据膨胀 | 30天定时清理 |
| 用户误以为删除即永久消失 | 确认弹窗明确告知"移至回收站，30天内可恢复" |

---

*文档版本: V1.1*
*更新: 补充回收站 UI、恢复按钮、彻底删除流程、永久删除策略*
