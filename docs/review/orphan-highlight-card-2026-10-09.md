# 无主划线卡：`hl:<uuid>` 仍显示 ID + 暂停无效（2026-10-09）

- 触发：白哥真机第二次截图 ——「**单词修复了**（`with`/`fixtures`/`SACHA` 都正常），
  但是最顶上那个**还是** `hl:8613b24d-…`，而且**点击暂停无法删除**」
- 状态：🔴 **仅调查，未改任何代码**（涉及架构选择 + 可能删数据，按铁律先请示）

---

## 一、先说「单词那一半为什么修好了」

`sync_user_word` 里那 8 条 `ext:`（`ext:fixtures` · `ext:sacha` · `ext:html` …）
走的是解析器第 ④ 级（**id 自带拼写，拆前缀即得**）⇒ 全部恢复正常 ✅

⇒ 上一批修复**按设计生效**。

## 二、`hl:` 这一半为什么修不了（**不是修复失效，是信息不在本机**）

| 证据 | 内容 |
|---|---|
| 线上 `sync_review_log` | `hl:8613b24d-deff-4284-bc70-b5bfe2efb6b6` 有 **2 条复习事件**（10-08 05:08 / 06:19，账号 `b5b3a29d`）|
| 服务端 `sync_*` 表 | 只有 `sync_review_log` / `sync_user_word` / `sync_article_read` / `sync_bookmark` / `sync_book_progress` / `sync_book` —— 🔴 **没有 `sync_highlight`** |
| 端侧 push/pull 的表 | `review_events` · `user_words` · `article_reads` · `bookmarks` · `book_progress` · `books` —— 🔴 **不含 highlight** |

⇒ **划线的「本体」（原文 `text`）从来不参与同步**。复习卡会同步过来，
但它引用的那条划线**不跟着来**。

### 两个现象因此是**同一个根因**

1. **标题显示 ID**：解析器第 ③ 级（`hl:` ⇒ 查同库 `highlight.text`）**查不到**该行
   ⇒ 按设计**返回 `null`、保留原值** ⇒ 原值就是那条 ID ⇒ 显示 ID。
   （⚠️ 这恰恰说明「不写占位」的设计是对的：它没有再制造新的脏值。）
2. **暂停点了没用**：`HighlightRepository.pause` 执行
   `UPDATE highlight SET paused=1 … WHERE id = ? AND …`
   ⇒ **影响 0 行** ⇒ 返回 `false` ⇒ 页面 `if (!changed) return;` ⇒ **静默**。

### 为什么本机没有这条划线

你**早先重装过 App**（就是报「重装后自动登录试用账号」那一次）——
重装会清掉 `user.db`，**划线条目随之消失**；而**服务端的复习事件还在**
（它在 `sync_review_log` 里，与划线本体分开存）。

**⚠️ 这不是个别现象**：任何**重装 / 换机 / 清数据**的人都会遇到 ——
只要有 `hl:` 卡的复习历史留在了服务端，新设备就会拿到一张**自己无法解析、也无法操作**的卡。

---

## 三、这条卡现在是「死卡」

- 复习列表里：标题是 ID，**点暂停没有任何反应**（不报错、不提示）
- 点进翻卡：`review_session_provider` 有 `hl:` 分支会去查 highlight 表 ⇒ **同样查不到**
- 「笔记」页：**也没有这条**（它本来就不在 `highlight` 表里）
⇒ **界面上没有任何出口能清掉它** —— 正是本项目最忌讳的「**静默失败 + 无出口**」。

### 3.1 🔴 「暂停」为什么是**静默**的：`false` 承载了两种语义

交互链：点「暂停」⇒ 弹二次确认 ⇒ 确认后调
`pauseReviewCard` → `HighlightRepository.pause(id)` →

```sql
UPDATE highlight SET paused = 1, … WHERE id = ? AND paused = 0 AND deleted = 0
```

⇒ **影响 0 行** ⇒ 返回 `false` ⇒ 页面

```dart
// `false` = 本来就已经是暂停状态（本次无动作）→ 不刷界面、不提示
if (!changed) return;
```

**问题在于 `false` 有两种含义，而页面只按其中一种处理**：

| 情形 | 实际含义 | 界面表现 |
|---|---|---|
| 有主卡、已是暂停态 | 幂等（**正确**）| 静默 —— 对 |
| **无主卡**（本机没有这条划线）| 🔴 **操作失败 / 数据不存在** | 静默 —— **错**（用户以为点了没用）|

📌 判据：**一个返回值承载两种语义时，接收方迟早只处理其中一种** ——
而「静默」会让错误的那一种完全无法被发现。
（同族：本项目「**静默失败 + 无出口**比报错更糟」。）


---

## 四、三个修法（**要你选**）

| 选项 | 内容 | 代价 / 风险 |
|---|---|---|
| **A. 把 `highlight` 纳入同步** | 后端加 `sync_highlight` 表 + push/pull 契约 + 端侧合并（照 `bookmark` 那套：`updated_at` 谁新谁赢）| 工作量最大（后端 + 端侧 + 部署）。✅ 但**顺带补上一个真缺口**：用户会期望「笔记能跨设备」——现在不能 |
| **B. pull 时丢弃「本机无对应划线」的 `hl:` 卡** | 从源头不再产生死卡 | 小。⚠️ 那条卡的复习历史就留不住了（本来也读不出来）|
| **C. 止血：暂停无主划线卡时，清掉它的复习状态** | 让用户**能把它从列表里弄走** | 小。⚠️ 涉及删一行 `card_review_state`（**复习派生态**，不是原始历史）|

### 我的建议：**C 先做 + 报告里定 A 还是 B**

理由：
- **C 是必须的** —— 否则**现在这张卡永久卡在列表里**，没有任何出口（你已经被卡住了）
- C 的删除范围可以**收到最小**：只删 `card_review_state`（复习状态 = 服务端不推的派生态），
  **保留** `user_word` / `review_log` ⇒ 可逆、不丢原始历史
- **A 是正解**（用户期望笔记跨设备），但它是新功能量级（后端 + 部署），值得单独排一批
- B 可作为 A 的过渡（或与 A 一起做）

⚠️ 若选 A，还需要定一条**合并规则**：划线被别端删除时，本机未同步的划线怎么办
（`bookmark` 已有的那套「`updated_at` 谁新谁赢 + `deleted` 标记」可直接复用）。

---

# 六、✅ 实施结果（白哥 2026-10-09 批「同意 C — A」）

## 6.1 C：我把「删那一行」换成了「**判据层不显示**」——请你确认这个替换

你批的是 C（「暂停无主卡时，清掉它的复习状态」）。**方向我照做了，但落点换了**，
理由如下 —— 如果你要「真的删那一行」，加一行就行，说一声。

**做法**：在 `review_list_query.dart` 的 `_visibilityWheres` 增加第 ④ 条：

```dart
// 划线卡必须真的有那条划线（无主卡 = 引用了不存在的划线 ⇒ 不该出现）
"(crs.word_id NOT LIKE '$kHighlightIdPrefix%' OR h.id IS NOT NULL)",
```

`list` / `count` / `dueCount` **三处共用**这份判据 ⇒ 列表与顶部计数同时生效。

### 🔴 为什么不是「删 `card_review_state` 那一行」

| # | 理由 |
|---|---|
| 1 | **删了也留不住** —— `card_review_state` 是 `review_log` 的**派生态**，`_applyReviewEvents` 的重放随时能把它重建（同 `user_db_schema.sql` 里 `paused` 那条注释的判据：「会被重建的表」不能存用户意图 —— 反过来也一样，从它上面删东西，一重放就回来了）|
| 2 | **留着是可恢复的前提** —— A 上线后只要那条划线从别端同步回来，卡片**自动恢复可用**（排期还在）。删掉这一行就把这条恢复路径**永久切断** |
| 3 | **它不可见之后没有任何副作用** —— 不占屏、不进计数、不影响任何查询 |
| 4 | **成因是系统性的** —— 任何**重装 / 换机 / 清数据**的设备都会出同一张卡。修在「暂停」按钮上只堵住一个出口，而且**要先让用户找到并点它**；修在判据上则**一次性、无需用户动作** |

📌 现固化为判据：**「不显示」是可逆的，「删除」不是 —— 能用前者解决就不要用后者。**
（同族：「保留可下载的那一段」写在订阅页的「到期后」文案里 —— 那次也是「不没收用户资产」优先。）

**效果**：那张 `hl:8613b24d-…` 的卡**自动从列表消失**，你不需要做任何操作；
且**找不到出口**这个问题一并消失（因为已经没有东西需要清理）。

## 6.2 A：划线纳入同步（`sync_highlight`）

### 后端（`schema.rs` + `sync_handlers.rs`）

| 项 | 内容 |
|---|---|
| 新表 | `sync_highlight`（12 列 + `received_at`，PK `(user_id, id)`）+ `idx_sync_highlight_pull` |
| push | `HighlightInput` · 入 `PushInput` · `check_batch_size` · upsert（**字段级**）· `PushStats.highlights` · 日志 `hl=` |
| pull | `HighlightOut` · 入 `PullOutput` · 查询 · `max_received` 表清单 · 日志 |
| 校验 | 🔴 `source_type` 显式校验回 **400** —— 只靠表上的 CHECK 会抛 rusqlite 错 ⇒ 映射成 **500** ⇒ 客户端无限重试 |
| 注销 | 🔴 加进 `user_purge.rs` 的删除清单 —— `text`（用户选中的原文）与 `note`（用户写的笔记）私人程度最高，**漏了就是隐私政策失实** |
| 表清单 | 加进 `schema.rs` 的 `EXPECTED_TABLES`（集合相等断言会立刻发现漏登） |

**合并口径**（与 `sync_user_word` 同一形状）：

| 字段 | 类别 | 口径 |
|---|---|---|
| `deleted` / `paused` / `note` | 最新意愿 | 取**较新**（按 `updated_at`）|
| `text` / offsets / `source_*` / `chapter_idx` | 首次事实 | 取**较早**（按 `created_at`）|

🔴 `note` 取较新时**连 `NULL` 一起取**：「清空笔记」是真实意图
（写成 `COALESCE` 则笔记**永远清不掉**）。
🔴 「首次事实」那组**整组来自同一端** —— 逐字段取会拼出
`text = "the quick fox"` 配 `start_offset = 999` 这种**不存在的组合**。

### 端侧

| 文件 | 改动 |
|---|---|
| `sync_merge.dart` | `highlightKey` / `highlightToPushJson` / `highlightFromPullJson` / `mergeHighlight` + 两张契约表；把 `_earlierAddedSide` 泛化成 `_earlierSideBy(key)` |
| `highlight_repository.dart` | `Highlight.toPushRow()`；修正两处「`pending()` 无消费者」的过时注释 |
| `sync_service.dart` | push 收集 `pending()` + 组装 body + `markSynced`；pull 加 `_applyHighlights`（**直写**，不走 `add()`）；`SyncReport` 加两项并计入 `pushedTotal`/`pulledTotal` |

🔴 **pull 里 `_applyHighlights` 排在 `_applyReviewEvents` 之前** ——
`ReviewSpellingResolver` 的第 ③ 级正是**同库**的 `highlight.text`：
排在后面的话，新设备第一次 pull 时标题会先显示成 `hl:<uuid>`，要等下次启动自愈才修好
（与 `user_words` 那条顺序修正是**同一条判据**）。
🔴 **同步走「直写」而不是 `HighlightRepository.add()`** —— `add()` 带业务语义
（「用户刚划了这条」），它会把 `deleted`/`paused` **归零** ⇒ 别端取消的划线在本地**复活**、
别端暂停的笔记在本地**恢复排期**。

## 6.3 验证

| 项 | 结果 |
|---|---|
| 后端 | `cargo test -p api_server` **280 passed / 0 failed**（+2：字段级合并 · `source_type` 400）· `fmt --check` ✅ |
| 端侧 | `analyze_inproc` **error=0 / warning=0** |
| 断言 | `verify_review_list` **60→71** · `verify_review_pause` **47→49** · `verify_sync` **73→95** · `verify_sync_merge` **120→157** · `verify_sync_service` **69→84** |
| 证伪 | **C 4 条 + A 9 条注入逐条变红、恢复后逐字节还原、复跑全绿** |

⚠️ 过程中踩到两次「检测器本身退化」（都是**假绿**的近亲）：
① C 的注入锚点被 **CRLF** 绊住（脚本读到的 `\n` 与实际不符）⇒ 改成行级/正则；
② A-5 的锚点只匹配到行首、**漏了行尾内容** ⇒ 改成 `[^\n]*\r?\n`。
📌 判据：**「注入没生效」必须与「断言没红」区分开** —— 前者是**闸门自己坏了**，
若不显式报 SKIP，就会把「什么都没测」读成「通过」。

## 6.4 剩余的

- 🔴 **后端需构建部署**（新表 + 新路由字段）—— 与你 WSL 那条构建命令同一条路
- 🔴 **端侧需出包**（C + A 都是端侧改动）
- 🟠 **可选**：订阅页权益第 1 行现在是「学习记录跨设备同步」，
  划线笔记也在里面了 —— 是否要写成「…（含划线笔记）」让它更具体？**我没动**（那是界面锚点里的文案）。
- ⏳ 老设备上**已经**存在的无主卡：判据层改完就看不见了，不需要任何清理动作

---

## 五、附：本轮验证（上一批修复本身是有效的）

- 单词侧已由你确认「修复了」（`ext:` 全部正常）
- 本地 `verify_review_spelling` 27 项 · `verify_sync` 73 项 · 端侧 `analyze` error=0
- 该卡的失败路径**恰好落在**「解析不出 ⇒ 保持原值」这条**有意设计**上 ——
  它没有再写一个假的拼写进去（这点是对的）
