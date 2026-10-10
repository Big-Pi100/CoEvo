# 划线与生词的「复习卡」不跨设备同步

> 白哥真机反馈（2026-10-11 00:29）：**安卓复习页有一张划线卡，iOS 没有**；
> 「**划线在笔记里同步了，但没有在复习里同步**」。
>
> **状态：🔴 已定位根因 · ⏳ 未改任何代码（等白哥审批）**
> 本报告**不含明文 IP**（延续既定的脱敏约定）。

---

## 一、现象（白哥截图）

| 端 | 复习页 |
|---|---|
| **安卓**（图 1）| 「今天有 **1** 个该看」→ 卡片「**Beyond the ReAct Loop: Why Your AI Agent…**」，标「现在复习」|
| **iOS**（图 2）| 「**今天没有要复习的**」→ 列表里没有那张卡 |

两侧**都**能看到 `beginning` / `in` / `host` / `fixtures` / `every` 等卡（它们都**有排期**：
「17 小时后」「1 天后」「2 天后」）⇒ **只有那张「从未复习过」的划线卡缺**。

---

## 二、🔴 根因（证据链完整）

### 2.1 机制：「进复习队列」在本地是**两张表一起写**

`services/highlight_enqueue.dart`（文件头注释原文）：

> 划线要能被复习，需要**两件事同时成立**：
> ① `highlight` 表里有这条划线
> ② `card_review_state` 里有一行 `word_id = 'hl:<uuid>'`（FSRS 排期）

查词入生词本**同理**（`user_word` + `card_review_state`）。

### 2.2 而**同步只覆盖数据表**，`card_review_state` 是派生态、**不在 11 类同步表里**

同步的 11 类：`review_log` / `user_word` / `article_read` / `bookmark` / `highlight` /
`book_progress` / `book` / `lookup_event` / `book_marker` / `achievement_unlock` / `setting`
—— **没有 `card_review_state`**。

### 2.3 pull 的应用层**只写数据表、不碰 `card_review_state`**

`services/sync_service.dart`：

| 方法 | 行 | 写了什么 |
|---|---|---|
| `_applyHighlights` | 1092–1120 | **只** `_upsertHighlight(merged)` ❌ 不碰 `card_review_state` |
| `_applyUserWords` | 931–961 | **只** `_upsertUserWord(merged)` ❌ 不碰 `card_review_state` |

⇒ 别端拉回「一条划线」或「一个生词」后，**没有对应的排期行**。

### 2.4 复习页以 `card_review_state` 为**主表** ⇒ 没有那行 = **不显示**

`services/review_list_query.dart` 的 list / count / dueCount 三处查询都以
`card_review_state crs` 为主表（`LEFT JOIN highlight`）
⇒ **没有 `crs` 行 ⇒ 该卡根本不出现在列表里，也不进「今天该复习」计数**（**静默**）。

### 2.5 🔑 为什么「`review_log` 重放」救不了它

重放**只能还原「复习过的卡」** —— 有 event 才有行。
「**新加入、从未复习**」的卡**没有 event** ⇒ **永远不出现**。

> ⚠️ `review_list_query.dart:134-136` 有一条**已过时的承诺**：
> 「**待「划线纳入同步」上线后，只要那条划线从别端同步回来，卡片就会自动恢复（排期还在）**」
> —— 该承诺的前提是「**排期那行还在本地**」（即曾被重放出来过）。
> 对「**从未复习过的卡**」这个前提**不成立**：本地从来没有过那一行。

### 2.6 ✅ 服务端硬证据（决定性的）

直查线上 `coevo.db`：

```
sync_highlight 共 2 条：
  8ae98a41-…  「Beyond the ReAct Loop: Why Your AI A…」  created_at 10-09T10:39:59  deleted=0   ← 就是截图那张
  8cc48a9e-…  「Saturday Sports: MLB playoffs; remem…」  10-10T16:31（≈ 反馈前 2 分钟刚划）

sync_review_log 里 hl: 事件共 2 条，**全部**是 hl:8613b24d-…（另一条 uuid，其划线不在 sync_highlight 里）
对照：非 hl: 事件 139 条
```

⇒ **`8ae98a41` 在 `sync_highlight` 里有、在 `sync_review_log` 里没有** ⇒ **从未复习过** ⇒
**两端都拿不到它的排期** ⇒ 只有「划它的那台设备」（本地入队时写过 `crs`）能显示 ✅ **与截图完全一致**。

---

## 三、影响范围（比一条划线大得多）

| 类型 | 是否受影响 | 说明 |
|---|---|---|
| **划线卡**（`hl:<uuid>`）| 🔴 **全部新划的** | 只要没复习过，别端就看不到 |
| **生词卡**（`w…` / `ext:…`）| 🔴 **全部新加的** | 同上（`user_word` 同步了、`crs` 没有）|
| 电子书划线卡 | 🔴 **同样**（也是 `hl:`）| — |
| **已复习过的卡** | ✅ 不受影响 | 有 `review_log` event ⇒ 重放能建出 `crs` 行 |
| 「今天该复习」计数 | 🔴 **两端必然不一致** | 缺的卡不进计数 |

> 🔑 这解释了白哥**上一轮**报的「**两端复习状态不一致**」的**第二个成因** ——
> 与刚修的「只推不拉」是**两个独立缺陷**，指向同一症状。
> 📌 判据：**同一症状可能有多个成因** —— 修掉一个不等于问题消失（本轮正是这样发现的）。

---

## 四、修复方案（请白哥选）

### 🔴 方案 A（推荐）· **pull 之后「补建缺失的排期行」**

在 `pullOnce` 的应用阶段末尾加一步：**只补「本地没有排期」的那些卡**。

```
对本次拉回的 highlight（deleted=0）：
    INSERT OR IGNORE INTO card_review_state (word_id='hl:'||id, spelling, state=0, next_review_at)
      排期取 highlight.created_at（= 划线当时的入队时刻）
对本次拉回的 user_word（deleted=0）：
    同理，word_id = user_word.word_id，spelling = 真拼写
```

**要点**
- ✅ **`INSERT OR IGNORE` 语义** —— 已有排期**绝不被覆盖**（不会冲掉别端的 FSRS 进度）
- ✅ **排期用源记录的 `created_at` / `added_at`**，而不是 `now`
  （否则每次重装/新机都会「从今天重新开始」，历史到期日全丢）
- ✅ **跳过 `deleted=1`** 的（不把已删的补回来）
- ✅ **displayName 口径复用 `highlight_enqueue` 那一处**（项目判据：同一件事的口径只能一处权威）
- ✅ **幂等**：重复 pull 不会重复插（`OR IGNORE` + 条件）
- ⚠️ 只在「本次确实拉回了 highlight/user_word」时跑（零成本优化）

**代价**：`pull` 多一条 `INSERT … SELECT … NOT EXISTS`（单用户 10²–10³ 行，可忽略）。

### 🟠 方案 B · **把 `card_review_state` 纳入同步（第 12 类）**

❌ **不推荐**：它是 `review_log` 的**派生态**，与重放构成**双重来源**
⇒ 「谁覆盖谁」难有干净判据（重放会重建、同步会覆盖 ⇒ 冲突）。
且它含 FSRS 数值 + `paused` 语义，同步它等于把「派生态」当权威，与既有设计冲突。

### 🟡 方案 C · **把「卡加入」做成可同步的事件**（新增 `card_added` 表）

最正规，但要**新增表 + 端侧迁移 + 服务端 DDL**，且要处理「卡加入后又删除」的语义 ⇒ 重。
可作为**将来**的收敛方向，本轮不必。

---

## 五、顺带发现的两处**过时注释**（不改代码，仅标注）

| 位置 | 过时的内容 | 事实 |
|---|---|---|
| `review_list_query.dart:108-110` | 「`highlight`（划线本体）**从不参与同步** —— 服务端连 `sync_highlight` 表都没有（6 张 `sync_*` 表…）」| 10-09 起 **已有** `sync_highlight`；现共 **11** 张 sync 表 |
| `review_list_query.dart:134-136` | 「只要那条划线从别端同步回来，卡片就会**自动恢复**（排期还在）」| 对「**从未复习过**」的卡**不成立**（本轮踩到的正是它）|

---

## 六、待白哥定

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | 是否按 **方案 A** 修 | ✅ 建议 A（改动小、幂等、与「派生态由端侧重算」的既有设计一致）|
| 2 | 补建的**范围** | 划线 + 生词**都补**（同族，一次性改全 —— 判据「补丁 ≠ 修法」）|
| 3 | 那两处**过时注释**是否顺手改 | ✅ 建议改（否则下一个人会照它做判断，这正是本轮的坑）|
| 4 | 是否**顺带**把「无主卡」的可见性判据也复核 | 建议复核一次（`8613b24d` 那条就是无主卡）|

---

## 七、✅ 实施（白哥 2026-10-11 00:43「同意」→ 方案 A）

| # | 文件 | 改动 |
|---|---|---|
| 1 | 🆕 `services/card_backfill.dart` | **纯 Dart**：`backfillCardsAfterPull({db, highlightIds, wordIds})` |
| 2 | `services/review_list_query.dart` | 🆕 `insertStateIfAbsent`（`INSERT OR IGNORE` ⇒ **只补不覆盖**）|
| 3 | `services/highlight_enqueue.dart` | `_displayName` → **公开** `highlightCardDisplayName`（口径一处）|
| 4 | `services/sync_service.dart` | `pullOnce` 在**全部 apply 之后**调用补建；🆕 `_idsOf` 辅助 |
| 5 | `services/review_list_query.dart` | 订正 §五 那两处**过时注释** |

### 几个关键决定（都已写进代码注释）

| 决定 | 理由 |
|---|---|
| 用 `insertStateIfAbsent`（**OR IGNORE**）而**不是** `upsertState`（OR REPLACE）| 后者会把本地**已有的 FSRS 进度整行清零**（静默、不可逆）|
| ⚠️ 用 **`rawUpdate`** 判「是否真的插入」| `rawInsert` 返回 `last_insert_rowid`，而 `OR IGNORE` 冲突时 SQLite **不更新它** ⇒ 会拿到上次的 rowid ⇒ **误判「插入了」** |
| 排期取源的 `created_at` / `added_at`，**不用 `now`** | 用 `now` ⇒ 每次新机 / 重装都「从今天重新开始」，历史到期日全丢 |
| 时间解析失败就**跳过**（**不**用 `now` 兜底）| 同上；宁可这一张不补，也不要一个**错的时间** |
| `deleted=1` **跳过**；`paused=1` **要补** | 前者 = 别端已删（补回来是「复活」）；后者在列表里显示「暂停」而**不是隐藏**（不补 ⇒ 两端差一行）|
| 补建行 `pending_push = 0` | 拉来的不该再推回去（防回声）|
| 排在**全部 apply 之后** | 要读刚落库的 `highlight.text` / `user_word.spelling`；排前面 ⇒ 查不到源 ⇒ **空转且不报错** |
| 失败**不影响**本轮 pull | 数据已落库；补建**幂等**，下次 pull 会再补 |

### 🔴 证伪：首版断言**全是假绿**（本轮最有价值的发现）

**改坏 5 处**（`INSERT OR IGNORE`→`OR REPLACE` · `created_at`→`now` · 两处 `deleted` 跳过 ·
`if (false && …)`）⇒ 首版断言**只红了 1 项**。

| 被兜住的断言 | 兜住来源 |
|---|---|
| `contains('INSERT OR IGNORE')` | 文件里**别的表**也有同类语句 |
| `contains('deleted')` / `contains('continue')` | `columns: […'deleted'…]` 与别处的 `continue` |
| `contains(函数名)` | **函数体内的调用**（`r.pulledBooks = await _applyCloudBooks(books);`）|

⇒ 改成三件套：**函数体切片** + **正则锁列/实参** + **计数**。
改后同样 5 处 ⇒ **红 6 项** ✅

> 🔑 判据：**证伪的强度 = 「改坏处数」与「变红项数」是否相称**。
>    改 5 处只红 1 项 ⇒ **断言覆盖不足**，而不是「实现没问题」。

**另一条教训**：改坏时的 `old_string` **多含了一行注释** ⇒ 复原失败
（`String to replace not found`），文件停在**半改坏**状态 —— 而它**能跑、不报错**。
⇒ 改坏只改那一行；复原后**必须再跑一次断言** + `grep 证伪用临时改动` 扫残留。

### 验证

`analyze_inproc`（`app/lib`）**error = 0** · **50 个 query_verify 脚本全 EXIT=0**
（`verify_sync` **220** 项，本轮 **+17**）

### ⏳ 未做

- **出包**（端侧改动，需白哥指令）—— ⚠️ 本批**服务端无改动**，**不用部署**
- 真机验证：两端的复习列表应**逐条一致**（含那张「Beyond the ReAct Loop」）
- §五 的「无主卡可见性判据」复核（建议项，未做）

