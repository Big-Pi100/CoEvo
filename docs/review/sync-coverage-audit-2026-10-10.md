# 同步覆盖面排查：还有哪些内容该同步（2026-10-10）

> 触发：白哥「同意 A。另外你**再排查一下还有哪些需要同步的内容**」
> 状态：✅ **已实施（2026-10-10）** —— 白哥「三项都做」⇒ P0（已批 A）+ P1 + P2 + P3 **全部落地**。
> 实施记录见 §七（含**真库断言抓到的一个真实缺陷**）。
>
> ~~状态：🔴 只排查，未改任何代码~~（初版状态，已被 §七 取代）

---

## 〇、方法：三方对比

| 来源 | 含义 |
|---|---|
| ① **全部本地表**（`user_db_schema.sql` 13 张 + `book_db_schema.sql` 6 张）| 事实全集 |
| ② **`local_data_owner.kUserOwnedTables` / `kBookOwnedTables`** | 项目自己定义的「**属于用户的数据**」（换账号要清）——**这是权威的"用户数据"口径** |
| ③ **同步清单**（`sync_handlers.rs` 的 7 类）| 实际在同步的 |

外加 ④ **`SharedPreferences` 的键**（偏好类，不在 DB 里，容易漏）。

---

## 一、完整对照表（19 张表）

| 表 | 是用户数据？ | 同步清单里有？ | 判定 |
|---|---|---|---|
| `review_log` | ✅ | ✅ `review_events` | ✅ 已同步 |
| `user_word` | ✅ | ✅ `user_words` | ✅ 已同步 |
| `article_read` | ✅ | ✅ `article_reads` | ✅ 已同步 |
| `bookmark` | ✅ | ✅ `bookmarks` | ✅ 已同步 |
| `highlight` | ✅ | ✅ `highlights` | ✅ 已同步 |
| `book` | ✅ | ✅ `books`（元数据）| ✅ 已同步 |
| `book_progress` | ✅ | ✅ `book_progress` | ✅ 已同步 |
| **`lookup_event`** | ✅ | ❌ | 🔴 **要补（P0 · A 已批）** |
| **`book_marker`** | ✅ | ❌ | 🔴 **要补（P1 · 见下）** |
| **`achievement_unlock`** | ✅ | ❌ | 🟡 **建议补（P2）** |
| `external_word_cache` | ✅ | ❌ | ✅ **不需**（缓存，可重生 —— 且「按需向服务端取」已实现）|
| `translation_cache` | ✅ | ❌ | ✅ **不需**（缓存，可重翻；端侧翻译已免费）|
| `card_review_state` | ✅ | ❌ | ✅ **不需**（`review_log` 的**派生态**，重放口径已保证）|
| `book_chapter` | ✅ | ❌ | ✅ **不需**（**原始文件的派生态**，导入/下载时重解析）|
| `book_progress_pending` | ✅ | ❌ | ✅ **不需**（**中转态**：pull 写入 → 导入后认领；来源在服务端）|
| `cloud_book` | ✅ | ❌（但**由 pull 填充**）| ✅ 不需单独同步 |
| `local_meta` | ❌（**归属记录本身**）| ❌ | ✅ 不需（设备本地）|
| （book 原始文件）| — | ✅ blob 通道 | ✅ 已同步 |

---

## 二、🔴 排查出的第二项：`book_marker`（书本内书签/摘录）

**这不是我推断的 —— schema 注释原文就写着**：

```
# ⚠️ 同步：表结构已为它准备好，但**管线未接**（如实标注）

`deleted`（软删）与 uuid 都是为了同步准备的（并集同步下硬删会复活 ——
文章收藏已踩过一次）。但**同步管线（sync_handlers.rs / sync_service.dart）
尚未接入本表** —— 那是订阅权益上线时的事。
```

**实测确认**（2026-10-10）：

```
grep book_marker  sync_service.dart          → 0 命中
grep book_marker  sync_handlers.rs           → 0 命中
```
⇒ **管线确实未接**，与注释一致。

**它是什么**：书本阅读器里的**书签/摘录**（`book_reader_screen` 写入，
`UNIQUE(chapter_idx, scroll_ratio)` 去重，`deleted` 软删）。
⇒ 🔴 **是用户资产**（用户手动加的书签），**换机后会丢**。

⇒ **建议与 A 一起做**（同一套模式：端侧 merge/push/pull + 服务端新表）。

---

## 三、🟡 P2：`achievement_unlock`（成就解锁时间）

- **能重建**：`evaluateAchievements(metrics)` 会按指标**重新判定**并 `INSERT OR IGNORE` ⇒
  只要指标够，徽章会**自动解锁**。
- 🔴 **但「解锁时间」会漂**：新设备上会记成「现在」而不是「当初」——
  成就墙的日期变成假的。
- ⇒ 小表（行数 = 成就数），**建议同步**以保留真实时间。
- ⚠️ 有**依赖关系**：若 `lookup_event` 不同步，基于它的那 4 个成就仍然解锁不了 ⇒
  **P2 应在 P0 之后**。

---

## 四、🟡 P3：设置类（**存 prefs，不在 DB** —— 最容易被漏的一类）

| 内容 | 存在哪 |
|---|---|
| 阅读字号 | `prefs['reading_font_size']` |
| 痕迹开关 | `prefs['reading_trace_enabled']` |
| 兴趣筛选 | `prefs['interest_categories']` |
| TTS 开关 / 语速 | `prefs['tts_enabled']` / `prefs['tts_speech_rate']` |
| 显示名 | `prefs['display_name']` |

⇒ **换设备后全部丢失**（用户要重设一遍）。

⚠️ 但**要不要同步偏好**是个**产品决策**（不是纯技术问题）：

| 支持同步 | 反对同步 |
|---|---|
| 用户体验一致（尤其字号/兴趣筛选是「配置一次就不动」的）| 偏好可能**与设备相关**（大屏用大字号）；且「主题跟随系统」这类**刻意是本机的** |
| 实现上是「小而稳定的键值对」| 要新增一条**与现有 7 类形态不同**的同步通道（键值 vs 行记录）|

⇒ **我不主动建议做**，列在这里供你判断。

---

## 五、建议顺序

| 优先级 | 项 | 理由 |
|---|---|---|
| **P0** | `lookup_event` | ✅ **已批**（A）—— 修「查词次数」+ 4 个成就 |
| **P1** | **`book_marker`** | 🔴 **schema 已备好、注释写明「管线未接」** —— 用户书签换机会丢 |
| P2 | `achievement_unlock` | 保留真实解锁时间（依赖 P0）|
| P3 | 设置类（prefs）| 需你决定要不要同步偏好 |

📌 **P0 与 P1 用同一套模式**（新增一类同步数据：服务端新表 + push/pull + 端侧 merge/push/pull + bump）
⇒ **一起做比分两次省**（约省一半改动与验证成本）。

---

## 六、请示

1. **`book_marker` 一起做吗？**（我建议**做** —— 它是用户资产，且设计早已备好）
2. **`achievement_unlock` 做吗？**（P2，小改动）
3. **设置类要同步吗？**（P3，**产品决策** —— 我暂不主动建议）

批准后我按流程走：**先写断言并逐条证伪 → 改码（端侧 + 服务端）→ 本地全验 → 部署/出包分别请示**。

---

*2026-10-10 · 方法：`grep CREATE TABLE` 取全部 19 张表 → 与
`local_data_owner` 的「用户数据」清单、`sync_handlers.rs` 的 7 类清单**三方对比** →
逐表判「能否派生 / 是否中转态 / 是否缓存」→ 另查 `SharedPreferences` 键（DB 外的漏网）→
用 schema 注释交叉验证（`book_marker` 的「管线未接」由实测 grep 确认）*

---

## 七、✅ 实施记录（2026-10-10 · 白哥「三项都做」）

### 7.1 落地内容（四类数据 = P0 + P1 + P2 + P3）

| # | 数据 | 跨设备身份 | 合并口径 | 服务端表 | 端侧表 |
|---|---|---|---|---|---|
| P0 | 查词记录 | `uid`（uuid，**惰性回填**）| 日志 ⇒ `INSERT OR IGNORE` | `sync_lookup_event` | `lookup_event`（+`uid`+`pending_push`）|
| P1 | 书本内书签 | `id` = uuid；**书**用 `content_hash` | 🔴 `deleted` 取 **OR**；其余取较早端 | `sync_book_marker` | `book_marker`（全量推）+ 🆕`book_marker_pending` |
| P2 | 成就解锁 | `key` | `unlocked_at` 取**较早** | `sync_achievement_unlock` | `achievement_unlock`（+`pending_push`）|
| P3 | 应用设置 | prefs 键名 | `value` 取**较新**（LWW）| `sync_setting` | 🆕`setting_sync`（键值载体）|

### 7.2 🔴 真库断言抓到的一个**真实缺陷**（实施中发现，非推断）

`lookup_event` 的同步幂等**靠 `INSERT OR IGNORE`**，而它的 PK 是**自增 `id`**
⇒ 若 `uid` 没有唯一约束，从云端**重复拉取**同一批会**每次插入新行**
（新 id 不冲突 ⇒ `OR IGNORE` 不触发）⇒ **查词次数虚增**，且**不报错**。

**发现方式**：`verify_sync_service.dart`【14】① 真跑一遍 —— pull 一次后行数从 3 变 4。
**修复**：给 `lookup_event.uid` 加 `CREATE UNIQUE INDEX`（SQLite 允许多个 NULL ⇒ 老行不受影响）。
**判据固化**：**「幂等键」必须真的有约束** —— 代码写 `OR IGNORE` 而表上没有唯一性，
是「看起来幂等、实际不幂等」。

### 7.3 顺带修正的既有缺陷

1. **`syncNow()` 漏复制计数**：`pushedHighlights` / `pulledHighlights` / `pulledBooks`
   从来**没被复制**进返回的 `SyncReport` ⇒ 这些字段在 `syncNow()` 后**归零**
   ⇒ `pulledTotal` 变小 ⇒ 不 bump ⇒ **「数据同步了、界面不刷新」**。
   已补全，并加断言「逐字段复制数 == 声明数」（能抓将来再加字段时又漏）。
2. **`sync_book` 未登记进 `verify_sync` 的表清单** ⇒ 它的「PK 含 user_id」「注销清单」
   两组断言**从未覆盖它**（清单漏一项 = 那一项无守护）。已补。

### 7.4 分批循环（必要的基础设施）

老库升级后 `lookup_event.pending_push` 默认 1 ⇒ 可能有**数千条**待推，
而服务端单表上限 1000 ⇒ 一次全推会 **400**，且**拖垮整批**（一张表超限，其余表也推不上去）。
⇒ `pushOnce` 改为**分批循环**：
- 有 `pending_push` 标记的表：逐轮每表取 ≤1000 条，推完再取；
- 全量推的表（`book_progress`/`books`/`book_markers`）：🔴 **只在第一轮带**（否则永不终止）；
- 终止条件用「有标记的表都没取满」（**不能**只靠「批量为 0」——设置采集异常会死循环）。

### 7.5 P3 的两处特别注意（设置类）

1. **写回 prefs 后必须通知读端**：新增 `settingsRevisionProvider`
   （字号 / 兴趣 provider `watch` 它；TTS 是 `ChangeNotifier` ⇒ 显式调 `reloadSyncedSettings`）。
   ⚠️ 不通知 = 「同步了、界面没变」。
2. **换账号必须复位 prefs**：`setting_sync` 表被 `clearUserOwnedData` 清掉，
   但**写回 prefs 的值不会** ⇒ 不复位会把上个账号的设置（含**显示名**）推给新账号
   ⇒ **跨账号泄漏且不报错**。已加 `resetSyncedSettingPrefs`（移除键，**不是**写默认值）。

### 7.6 版本与迁移

| 库 | 版本 | 变更 | 迁移 |
|---|---|---|---|
| `user.db` | 9 → **10** | 2 处**加列**（`lookup_event.uid`/`pending_push`、`achievement_unlock.pending_push`）+ 1 处**加表**（`setting_sync`）| `onUpgrade` 的 `oldVersion < 10` 分支（加列必须 ALTER）|
| `book.db` | 4 → **5** | 加表（`book_marker_pending`）| 重跑全量脚本即可 |

⚠️ **两处都补了「真机现状」起点断言**（`fromVersion: 9` / `fromVersion: 4`）——
「最新那个版本」最容易被漏（它看起来「已经是新的了」）。

### 7.7 断言与验证

| 脚本 | 结果 |
|---|---|
| `cargo test -p api_server --lib` | ✅ 293 项（含 5 组新表单测）|
| `verify_sync.dart` | ✅ 158 项（服务端四表 + 端侧接线 + 设置键一致性）|
| `verify_sync_merge.dart` | ✅ 225 项（四类合并口径 + 契约 + 跨语言方向核对）|
| `verify_sync_service.dart` | ✅ 108 项（含【14】四类**真库行为**）|
| `verify_userdb_migration.dart` | ✅ 583 项（v1…**v9** → v10 九条路径）|
| `verify_bookdb_migration.dart` | ✅ 68 项（v1/v3/**v4** → v5）|
| `verify_local_owner.dart` | ✅ 57 项（新表已纳管）|
| `verify_user_word.dart` | ✅ 56 项（**口径已变**的那条已改：`lookup_event` 现在**有** `pending_push`）|
| 其余相关（book_marker / book_cloud / progress_sync / highlight_repo / achievement_service）| ✅ 全绿 |

**证伪抽验**：去掉 `uid` 唯一索引 ⇒ `verify_sync` 红 ✅；删 `syncNow` 一个字段复制 ⇒ 红 ✅。

### 7.8 ⏳ 未做（需白哥指令）

1. **部署服务端**（新表 + push/pull）—— 按铁律需单独批准。
2. **重新出包**（端侧 schema v10 + 同步逻辑）—— iOS 走 CI，仓库须公开。
3. `docs/design/sync-implementation-assessment-2026-10-04.md` 的「7 类表」清单
   现已过时（**11 类**）—— 待更新（本次已在 §7.1 给出新的对照表）。
