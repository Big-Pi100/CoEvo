# 阅读管线升级方案

> 日期: 2026-05-29
> 状态: 待实施

## 一、现状总结

### 1.1 三条管线的卡片集成

CoEvo 内部有三条管线，各有不同的卡片集成方式：

| 方面 | 通用管线 | K12管线 | 阅读管线 |
|:----|:---------|:--------|:---------|
| 卡结构 | `Card` + `CardMemory` | `Card`（同表） | `ReadingCardData`（异构） |
| 存储 | SQLite `cards` + `card_memory` | SQLite `cards` 表（同） | JSON 文件（内存加载） |
| 创建 | 对话→ConceptCandidate→format_card | 课标模板→INSERT | Python LLM→JSON文件 |
| 复习 | FSRS-5 调度 | 同通用管线 | **无 FSRS** |
| 学生可见 | `GET /api/cards/all` | 同通用管线 | **看不见** ⛔ |

### 1.2 已发现问题

**问题 A — 学生看不到课文全文**

`build_reading_context()` 将全文注入 LLM 的 system prompt，但全文从不展示给学生。

```
教师 LLM ← full_text ✅
学生     ← 仅看到 LLM 的分析 ❌
```

**问题 B — 词卡/概念卡未使用**

`ReadingTaskData` 预留了 `vocab_card_ids` 和 `concept_card_ids` 字段，但 **681 个 task 全部为空**。

| 字段 | 总数 | 有值的 task | 占比 |
|:----|:---:|:----------:|:----:|
| vocab_card_ids | 681 | **0** | 0% |
| concept_card_ids | 681 | **0** | 0% |

**问题 C — 词卡数据存在但未关联**

`chinese_compulsory.json` 已有 **2614 张汉字级词卡**（`card_type=vocabulary`），词卡 ID 格式为 `chinese_g7-9_v0000`。词卡富集数据存在于 `vocab_enriched/chinese_enriched.json`。

但 `reading_plans/chinese.json` 中的 `vocab_card_ids` 从未引用它们。

**问题 D — 教学知识点未进入 FSRS 复习**

- 通用/K12：`k12_init_handler` 写入 `cards` + `card_memory` → FSRS 复习 ✅
- 阅读：`k12_reading_init_handler` 写入 `cards`（残缺） + 无 `card_memory` → 无复习 ❌

### 1.3 概念卡说明

用户确认：概念卡不需要特殊处理，走 Cold Path 1（对话中直接提取概念）即可，与通用管线的 N2 流程共享。

## 二、升级方案

### 阶段 P0 — 全文展示功能

**目标**：学生在阅读模式下可打开独立界面阅读课文全文。

#### 后端

**P0-1: `k12_reading_init_handler` 增加 `current_card` 返回值**

文件：`backend/crates/api_server/src/routes.rs`

在 handler 尾部（"导入首任务"之后），从 `plan_content` 找到第一个 task 的 `reading_card_id`，调用 `reading_loader::get_card()` 获取卡片数据，序列化返回。

返回增加字段：
```json
{
  "conversation_id": "...",
  "plan": {...},
  "current_card": {
    "id": "reading_vernacular_...",
    "front": "祝福",
    "author": "鲁迅",
    "full_text": "旧历的年底毕竟最像年底...",
    "appreciation": [...],
    "technique": [...],
    "theme": "..."
  }
}
```

**P0-2: 新增 API `GET /api/k12/reading/{conv_id}/current-card`**

文件：`backend/crates/api_server/src/routes.rs`

逻辑：
1. 从 `learning_plans` 读取 `plan_content`
2. 找到第一个 `status != "done"` 的 task
3. 获取 `reading_card_id`
4. 调用 `reading_loader::get_card()` 返回完整 `ReadingCardData`

```
GET /api/k12/reading/{conv_id}/current-card
→ 200: { current_card: { id, front, author, full_text, appreciation, ... } }
```

#### 前端

**P0-3: 新建 `ReadingFullTextScreen`**

文件：`app/lib/screens/reading_full_text_screen.dart`

功能：
- 干净的阅读界面，接收 `ReadingCardData`
- AppBar 显示课文标题 + 作者
- 正文区域：字号可调（12-20px）、行距舒适、底部留白
- 滚动到底按钮（长文时有用）
- 夜间模式（跟随系统）

**P0-4: `chat_screen.dart` 增加全文入口**

在输入框上方显示课文卡片：

```
┌──────────────────────────────────┐
│ 📖 当前课文：祝福 · 鲁迅          │
│         [查看课文全文 →]          │
└──────────────────────────────────┘
```

点击 `→` 跳转到 `ReadingFullTextScreen`。

**P0-5: 课文推进时刷新**

每次 `reading_update` 推进到新 task 后，Flutter 调用 `GET /api/k12/reading/{conv_id}/current-card` 获取新课文数据，更新卡片上显示的课文名和全文内容。

---

### 阶段 P1 — 词卡与课文关联

**目标**：从已有 2614 张汉字词库中筛选与每篇课文相关的词，填充 `vocab_card_ids`。

#### P1-1: 数据现状

| 数据源 | 文件 | 条目 |
|:------|:----|:----:|
| 词库（富集） | `vocab_enriched/chinese_enriched.json` | 2614 |
| 词卡（编译后） | `cards/chinese_compulsory.json` | 2614 张词卡 |
| 课文 task | `reading_plans/chinese.json` | 681 个 |
| 已关联的 task | — | **0 个** |

#### P1-2: 关联脚本

新建 `scripts/gold/link_vocab_to_tasks.py`

流程：
1. 加载 `reading_plans/chinese.json` 获取所有 tasks
2. 加载 `chinese_compulsory.json` 获取词库（`{id, front}` 映射）
3. 对每个 task：
   a. 用 `reading_card_id` 从 `reading_loader::get_card()` 获取 `full_text`
   b. 在 `full_text` 中搜索词库中的每个汉字是否出现
   c. 匹配到的字按出现频率排序
   d. 取前 5-10 个最相关的字，写入 `task.vocab_card_ids`
4. 保存更新后的 `reading_plans/chinese.json`

注意：
- 只匹配词库中实际存在的汉字（2614个），不凭空生成
- 每个 task 关联 5-10 个生字
- 同一篇课文中高频出现的字优先

---

### 阶段 P2 — 词卡进入 FSRS 复习

**目标**：词卡写入 SQLite `cards` + `card_memory` 表，通过 `/api/review/due` 可复习。

#### P2-1: 修改 `k12_reading_init_handler`

在创建会话后，对首任务的 `vocab_card_ids`：
```rust
for vocab_id in task.vocab_card_ids {
    if let Some(card) = curriculum_loader::get_card(&vocab_id) {
        let k12_id = format!("k12_{}", vocab_id);
        conn.execute(
            "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, ...)
             VALUES (?1, ?2, 'chinese', 'vocabulary', ?3, ?4, ...)",
            rusqlite::params![k12_id, user_id, card.front, card.back],
        ).ok();
        conn.execute(
            "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, ...)
             VALUES (?1, 0, 5.0, 0.0, ?2, NULL, 0, 0)",
            rusqlite::params![k12_id, now_ts],
        ).ok();
    }
}
```

#### P2-2: `reading_update` 推进时导入下一批

在 `plan_handler.rs` 的 `reading_update` 处理中，当标记当前 task 为 "done" 后，找到下一个未开始的 task，导入其 `vocab_card_ids` 对应的词卡。

---

### 阶段四 — 其他

#### 4.1 概念卡

用户确认：走 Cold Path 1 即可，不单独处理。

Cold Path 1（`concept_extractor`）在通用教学对话中自动提取概念，产生 `ConceptCandidate` → `format_card` → `Card` + `CardMemory` → SQLite + FSRS。

阅读管线中的概念教学（手法、主旨等）也会在师生对话中发生，Cold Path 1 自动覆盖，无需额外代码。

#### 4.2 清理临时脚本

保留（已融入工作流，含升级版重试机制）：
- `scripts/gold/rebuild_appreciation.py` — 批量重建赏析
- `scripts/gold/rebuild_technique.py` — 批量重建手法
- `scripts/eval/batch_fix_eval.py` — 6维评估引擎（含指数退避重试+超短文跳过）

清理（一次性修复脚本）：
```
scripts/gold/fix_failed_24.py
scripts/gold/fix_zhiyunque.py
scripts/gold/fix_last_3.py
scripts/gold/fix_remaining_metadata.py
scripts/gold/fix_ft_70_84.py
scripts/gold/fix_leiyu.py
scripts/gold/fix_ft_60_69.py

# 根目录遗留脚本（2026-05 卡片质量优化期间创建）
_batch_update_final.py
_batch_update.py
_batch_update2.py
_check_remaining.py
fix_batch6.py
fix_batch7.py
fix_batch8.py
fix_cards.py
```

### 4.3 历史对话独立入口

**目标**：将 chat_screen 右上角的 history 按钮（小图标）提升到首页作为独立入口。

**现状**：历史对话管理藏在 chat_screen 的 `AppBar.actions` 中（`Icons.history`），用户必须进入聊天页才能找到，新用户无法感知。

**改动**：

首页 `home_screen.dart` 在「开始对话」卡片下方新增「历史对话」卡片：

```
┌──────────────────────────────────┐
│ 💬 开始对话                       │
│ 和 AI 自由对话学习新知识           │
└──────────────────────────────────┘
┌──────────────────────────────────┐
│ 🕐 历史对话                       │
│  继续之前的对话，或恢复已学习内容    │
└──────────────────────────────────┘
┌──────────────────────────────────┐
│ 📚 科目（网格）                    │
│ 数学 语文 英语 物理 ...           │
└──────────────────────────────────┘
```

点击「历史对话框」跳转到 `/conversations`（已有 `ConversationListScreen` 页面）。

### 排期

| 阶段 | 模块 | 工作量 | 前置 |
|:----|:----|:-----:|:----|
| P0-1 | 后端 init 返回 current_card | 0.5天 | — |
| P0-2 | 后端 current-card API | 0.5天 | — |
| P0-3 | 前端 ReadingFullTextScreen | 1天 | P0-1 |
| P0-4 | chat 入口卡片 | 0.5天 | P0-1 |
| P0-5 | 课文推进时刷新 | 0.5天 | P0-2 |
| P1 | 词卡-课文关联脚本 | 2天 | 词库已就绪 |
| P2 | 词卡 FSRS | 1天 | P1 |
