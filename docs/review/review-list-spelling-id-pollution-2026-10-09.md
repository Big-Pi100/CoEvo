# 复习列表标题显示成内部 ID（账号切换后）—— 根因调查

- 触发：白哥真机截图 —— 复习 / 笔记列出 4 张卡，标题显示
  `hl:8613b24d-deff-4284-bc70-b5bfe2efb6b6` · `w000129` · `ext:fixtures` · `ext:sacha`
- 白哥归因：「**账号退出、更换后**本地的数据出现异常」
- 状态：🔴 **仅调查，未改任何代码**（按项目铁律先出报告）

---

## 一、根因链（每一步都有代码位置）

| # | 环节 | 位置 |
|---|---|---|
| 1 | **列表标题读的是 `card_review_state.spelling`**（冗余列）| `review_list_query.dart:118` `SELECT crs.word_id, crs.spelling, …` → `review_screen.dart` 渲染 `Text(item.spelling)` |
| 2 | pull 复习事件时，为**每个 wordId** 重算并写回状态 | `sync_service.dart:555` `upsertState(spelling: await _spellingFor(wordId), …)` |
| 3 | `_spellingFor` 只查**两处**，都取不到就**返回 `word_id` 本身** | `sync_service.dart:580` |
| 4 | **`upsertState` 是 `INSERT OR REPLACE`** ⇒ 每次重放**整行覆盖**，兜底值被**持久写入** | `review_list_query.dart:236` |
| 5 | ⇒ 列表就把 `word_id` 当标题显示出来 | — |

### `_spellingFor` 的原文（它自己写着会发生什么）

```dart
/// 🔑 顺序：**本地已有状态 → 生词本 → `word_id` 本身**。
///    · 前两者能命中时拿到的是**真拼写**
///    · 都命中不了（首次同步且这个词不在生词本里）⇒ 用 `word_id` 兜底
///      ⚠️ 那是个**难看的占位**（列表会显示 `w008732` 而不是单词），
///         但**比崩掉好**，且下次该词进生词本 / 本地查词后会被覆盖。
```

⇒ 作者**知道**这个兜底会显示成 `w008732`（正是截图里的形态），
并认为「下次会被覆盖」—— 但**下面两条让它没被覆盖**。

---

## 二、为什么「退出登录 / 换账号」会触发

1. **退出登录本身不清 `user.db`**（只清 secure storage 的 token + 翻译缓存）——
   所以「退出」不是数据被删，而是**换账号后拉进来一批本机第一次见的词**。
2. 线上实测该账号的复习事件：**36 个不同 word_id**
   （`ext:` 词库外 **24** 个 · `hl:` 划线 **2** 个 · `w0xxx` **107** 条事件）。
3. 这些词在本机 `card_review_state` / `user_word` 里**都没有** ⇒ 走兜底 ⇒ 写 `word_id` ⇒ 列表显示 ID。

⇒ 所以现象**与账号切换强相关**，但根因不是「切换」本身，而是
**「首次见到的词」+「兜底值被持久化」** 两者叠加。

---

## 三、加重项：pull 内部的处理顺序（**最小改动、最大收益**）

`sync_service.dart:415-419`：

```dart
r.pulledReviewEvents = await _applyReviewEvents(events);   // ① 先
r.pulledUserWords    = await _applyUserWords(words);        // ② 后
```

① 在跑的时候，**同一次 pull 里那份带正确 spelling 的 `user_word` 还没落库**
⇒ `_spellingFor` 查不到 ⇒ **必然兜底**。

📌 **只要把 ①② 对调**，绝大多数情况当场就能拿到真拼写。

---

## 四、三处「本来拿得到真拼写」，但都没拿

| `word_id` 形态 | 真拼写在哪儿 | `_spellingFor` 查了吗 |
|---|---|---|
| `hl:<uuid>` | **同一个库**的 `highlight.text`（划线原文，`user_db_schema.sql:499`，`NOT NULL`）| ❌ |
| `ext:<拼写>` | **id 里自带**（去掉 `ext:` 前缀即词形）| ❌ |
| `w0xxxxx` | 跨库的 `word.db`，或本地 `user_word.spelling` | 只查后者 |

⚠️ 前两类**零跨库成本**（一个查同库表、一个拆字符串），本该拿到。
`_spellingFor` 文档里「为什么不查 `word.db`」的理由（怕把跨库风险引进来）**对第三类成立**，
但**不适用于前两类**。

### 旁证：会话页与列表页口径不一致

`review_session_provider.dart:216` 有 `isHighlightWordId(wordId)` 分支
（专门处理划线卡、从 highlight 表取原文）—— **会话页处理了，列表页没有**。
⇒ 表现是「点进翻卡能看到原文，退回列表标题又是 uuid」这类不一致。

---

## 五、已污染的数据怎么办

- `upsertState` 是 `INSERT OR REPLACE` ⇒ **每次有复习事件时都会重写** ⇒ 有**自愈机会**。
- 但**只有「有复习事件」的词**才会被重写；**沉默的词会一直显示 ID**。
- ⇒ 修代码只解决「以后不再写坏」，**已脏的行需要一次性修复**
  （例如启动后扫一遍 `card_review_state`，对 `spelling` 形如 `w0…/hl:…/ext:…` 的行按 §四的三种方式补真拼写）。

## 六、服务端是干净的（已直查线上）

`sync_user_word` **45 行，spelling 全部正确，0 条脏数据** ✅

⇒ 污染**只在端侧** `card_review_state`，**不会**经 push 扩散到别的设备
（push 的是 `user_word.spelling`，那条路径是对的）。

⚠️ 但同时意味着：`card_review_state` **不参与同步** ⇒ **每台设备各自脏、也要各自修**。

---

## 八、实施方案（方案 B —— 已实施）

### 8.1 新增：`app/lib/services/review_spelling.dart`（**解析 + 自愈的单一权威**）

| 等级 | 来源 | 成本 |
|---|---|---|
| ① | 本地 `card_review_state.spelling` —— **但排除「已是 ID 形态」的值** | 一次主键查询 |
| ② | `user_word.spelling` | 一次查询 |
| ③ | `hl:<uuid>` ⇒ **同库** `highlight.text`（划线原文）| 一次主键查询 |
| ④ | `ext:<拼写>` ⇒ **去前缀即得** | 零查询 |
| ⑤ | `w0xxxxx` ⇒ 词库（**由调用方注入**，本文件不依赖 `word.db`）| 调用方决定 |
| ⑥ | 都没有 ⇒ **返回 `null`** | — |

**三条判据（都进了断言）：**

1. 🔴 **解析不出来返回 `null`，绝不返回 `word_id`** ——
   这是根因：旧实现的 `return wordId` 把一次显示问题**升级成了持久化数据污染**。
2. 🔴 **① 必须排除「ID 形态」的值** —— 否则一条脏值会**自我固化**
   （查到自己 ⇒ 返回自己 ⇒ 永远修不掉）。判据 `isWordIdShaped`：
   `ext:` / `hl:` 前缀，或 `^w\d{6}$`（**定长 6 位** —— 宁可漏判，不可误判真拼写）。
3. **零 Flutter 依赖**（连 `debugPrint` 都不用，改注入 `onLog`）——
   否则 `scripts/*_verify` 的纯 `dart run` 加载不了它。

`repairAll()` = 自愈：扫 `card_review_state`，对**脏值行**逐条解析后只更新 `spelling` 一列。
**幂等**（已正确的行不动）· **候选为 0 直接返回**（连事务都不开）。

### 8.2 `sync_service.dart`

- **对调 pull 两步**：`_applyUserWords` **先**、`_applyReviewEvents` 后
  （后者要拿前者的 `spelling` 当来源）
- `_spellingFor` 改为**委托解析器**，返回类型 `Future<String>` → **`Future<String?>`**
- 调用点：`resolved ?? currentRow?.spelling ?? wordId`
  —— 解析不出时**沿用表里现有的值**（不动那一列），而不是写占位

### 8.3 `word_db_provider.dart`

- 词库就绪后跑 `_repairStaleSpellings`（新）
- 🔴 **刻意不放进 `if (result.didWrite)` 块里**：那条支线是「词库变了才做」，
  而「拼写被写成 ID」是**同步 pull 造成的、与词库是否更新无关** ——
  挂上去 ⇒ 词库不更新时**永远不修**。
- 放在既有收敛（③）**之后**：收敛会把 `ext:xxx` 改成 `w0xxxxx`，改完拼写正好由它一起修掉。
- 修好就 `bump()`（否则复习页仍显示旧值）。

### 8.4 `word_query_service.dart`

- 新增 `spellingOfId(id)`（`idOfSpelling` 的**反向**，只读一列）——
  不复用 `cardById`（那个会 `LEFT JOIN card` 读 ~1.2 KB/词的 `content`）。

## 九、验证

### 9.1 行为断言（新建 `scripts/query_verify/bin/verify_review_spelling.dart`，**真 sqlite 内存库**）

**27 项全绿**，覆盖：判据边界（`w2`/`w1234567` 不算 ID）· `ext:` 拆前缀 · `hl:` 取原文 ·
🔴 **解析不出必须返回 `null`**（含「注入的词库查询抛异常也不写坏」）·
🔴 **state 是脏值时跳过它、不自固化** · 各等级的调用次序 · `repairAll` 修好 2 行 + 幂等 + 不动正确行。

### 9.2 接线断言（`verify_sync.dart`：**71 → 73**）

pull 两步顺序 · `_spellingFor` 体内**不得**再出现 `wordId` 兜底（**切片 + 哨兵**，
因为调用点那句 `?? currentRow?.spelling ?? wordId` 是有意的，全文件扫会假红）·
自愈已接线 · 自愈**不在** `didWrite` 块内。

### 9.3 逐条证伪

| 注入 | 目标断言 | 结果 |
|---|---|---|
| A. pull 两行对调回旧顺序 | 「`user_words` 必须先落库」 | ✅ **变红** |
| B. `_spellingFor` 体内加 `?? wordId`（**签名不变**）| 「体内不得兜底」（切片判据）| ✅ **变红** |
| C. 删掉自愈调用 | 「自愈已接线」 | ✅ **变红 2 项** |
| D. 自愈挪进 `didWrite` 块内 | 「不在块内」 | ✅ **变红** |
| E. 解析器第⑥级改回 `return wordId` | 行为断言【4】【5】 | ✅ **变红 5 项** |

⇒ 5/5 全部变红，逐条恢复后**逐字节一致**、复跑全绿（73 / 27）。

**B 与 E 是本批最值得记的两条**：
- **B** 先写成「签名是不是 `Future<String?>`」，那**抓不到「签名不变、体内偷偷兜底」** ⇒
  改成**切片 + 哨兵**判据。
- **E** 证明「不许兜底」这条**行为**（而不只是文本）真的被守住 ——
  注入后**5 条**断言同时红（含「划线行不存在也不给 uuid」「两处脏值不给脏值」「词库抛异常不写坏」）。

⚠️ 做 D 时踩到一次「**子串匹配不认行首**」：替换后新增的 6 空格行
`      await _repair...` **内含** 4 空格锚点 ⇒ 计数变 2。
⇒ 锚点加 `\n` 限定行首（同族：`subtitle:` 里含 `title:` 那次假红）。

### 9.4 全量回归

`analyze_inproc`（171 文件）**error=0 / warning=0** ·
11 个断言脚本全绿：96 / 71 / 87 / **73** / 23 / 60 / 60 / 69 / **27** / 165 / 96 ·
`tokens_verify` 仍 **690 通过 / 8 失败**（存量，与基线逐条一致）。

### 9.5 待部署

🔴 **必须重新出安卓包才生效**（本次全是端侧改动）：
```bat
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
```

⚠️ 服务端**无需**部署（这一轮没动后端）。
⚠️ 已在真机上被写脏的 `card_review_state.spelling`：出包后**首次启动**（词库就绪时）会自动修。
⚠️ 界面重算的最后一环（`_runSync` 的 bump）在上一批端侧改动里 —— 也等着这次出包一起生效。

---

## 十、还留了一条「未做」的

`_spellingFor` 之外，**没有任何地方**会主动修 `card_review_state.spelling` ——
自愈只在「词库就绪」那一次跑。若用户长期不重启 App，
**当次会话新写坏的**（比如同步中途词库尚未就绪）要等下次启动才修。

📌 这属于**可接受的折中**（代价是「最多显示一次旧值」，而不是数据丢失），
本批**没做**「同步后立即补修」—— 那会让每次同步都多一次全表扫描。
如果你觉得需要，可以单独提。
