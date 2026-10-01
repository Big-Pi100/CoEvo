# Step 3.4c 实施报告：查词写入（`user_word` + `lookup_event`）

> ## ⛔ 局部作废（2026-10-01）：`AddWordResult` 的第 4 个值 `limitReached` 已删除
>
> ⛔ 免费层生词本 200 词上限**已取消**（白哥 2026-10-01 定，**已作废**）→
> 本文中「`add()` 返回 `added` / `alreadyExists` / `revived` / `limitReached`」的枚举清单
> **只剩前三项**（`limitReached` 与其分支已一并删除）。
> ⛔ 其余实施结论**仍然有效**。
>
> 📄 依据：`docs/review/free-tier-limit-removal-assessment-2026-10-01.md`

> 日期：2026-09-28｜方案依据：`step3-4c-word-writeback-plan-2026-09-28.md`
> 状态：✅ **已实施**（代码 + 验收全绿）· ⏳ **待白哥真机验证**
> 权威依据：`v1-final-design-authoritative-2026-09-25.md` §3.2 / §八 / §九（L0）

---

## 一、做了什么（7 步全部完成）

| # | 步 | 产出 |
|---|---|---|
| 1 | schema 加两表 + 4 索引 | `user_db_schema.sql`（+ `user_word` · `lookup_event`） |
| 2 | 迁移机制 | `kUserDbVersion` **1 → 2**；`onUpgrade` **重跑全量幂等 schema** |
| 3 | ★ **老库升级验收** | 🆕 `scripts/query_verify/bin/verify_userdb_migration.dart`（**20 项**） |
| 4 | 生词本仓储 | 🆕 `services/user_word_repository.dart` · 🆕 `verify_user_word.dart`（**53 项**） |
| 5 | **共享 DB 连接** | 🆕 `providers/user_db_provider.dart` · 🆕 `providers/user_word_provider.dart` |
| 6 | 接查词链路 | `reader_screen._lookupWord` → `_writeBackLookup`（**不阻塞浮层**） |
| 7 | 接线断言 | `tokens_verify` **§16**（+15 项） |

---

## 二、🔴 步骤 5 是一个**计划外的必要发现**

计划里没写「抽共享 DB 连接」，但实施时立刻撞上：

```dart
// 原先：bookmarkProvider 自己 open + 自己 dispose
final db = await openUserDb(...);
ref.onDispose(() => db.close());
```

「生词本」也要用库。若它**也自己 open 一次**：

| # | 事实 | 后果 |
|---|---|---|
| 1 | `sqflite` 默认 **`singleInstance: true`** | 同路径第二次 `openDatabase` 返回**同一个 `Database` 对象** |
| 2 | 两个 provider 各自 `ref.onDispose(close)` | 谁先销毁谁把**共用的那个**关掉 |
| 3 | 另一个 provider 继续用 | 🔴 `database_closed` 异常 |

🔑 **所以「多个功能共用一个库」时，连接的所有权必须唯一。**
→ 抽出 `userDbProvider` 作为**唯一**的 open + close 点；`bookmarkProvider` 改为
`await ref.watch(userDbProvider.future)`，**不再自己 open / close**。

⚠️ 这同时**改善**了日志：打开失败原打 `[bookmark] user.db 打开失败`，
但打开的是**整个 user.db**、不只服务收藏 → 现统一为 **`[user_db]`**（排查用 `grep user_db`）。

> 🔑 这条已写入断言（§16）：**「全库只有一处 `openUserDb` 调用」**。
> 扫描时须**排除 `services/user_db.dart`** —— 那是 `openUserDb` 的**定义处**。

---

## 三、实施中被验收抓到的**两个真 bug**（都是我自己写的）

### bug 1 · `updated_at` 被写成了 SQL 文本

```dart
// ❌ 错的：update() 的 map 会把它当**字面量**参数化绑定
await _db.update('user_word', {'updated_at': _nowUtcSql}, ...);
// → 列里真的存了 "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')" 这串文本
```

🔴 **且写入时不报错** —— 直到**读取**时 `parseUserDbUtc` 抛 `FormatException`。
典型的「**静默污染、延迟暴露**」。

✅ 修法：改用 `rawUpdate` 把表达式写进 SQL 文本（同 `review_list_query.upsertState` 用 `rawInsert`）。
✅ 并加断言锁住：`updated_at 不以 strftime( 开头`。

### bug 2 · 两条断言**自己写错了**（不是实现问题）

| 断言 | 错在哪 |
|---|---|
| 「上限时不弹订阅提示」 | 逻辑写反 —— 实现里 `debugPrint` 的**文案**含「已达上限」，把它当成了用户可见提示 |
| 「全库只有一处 openUserDb」 | 没排除 `user_db.dart`（**定义处**）；且 `path.endsWith('services/…')` 在 **Windows 上恒 false**（分隔符是 `\`） |

🔑 **判据再次生效**：「见红先分清**实现错还是断言错**」—— 这两条一看数据就自相矛盾
（实现明明没问题，是断言的范围/判断错了）。

---

## 四、关键设计（与 `bookmark` 的两处**反向**差异）

| | `bookmark` | `user_word` |
|---|---|---|
| 删除 | **硬删**（`DELETE`）—— 收藏是可再生的意图 | 🔴 **软删**（`deleted = 1`）—— 生词带学习数据 |
| 状态载体 | 内存 `Set<int>`（读多写极少 + 单条判定） | 🔴 **不用** —— 要 `COUNT` + 列表 + 排序 |

**复用的部分**：`parseUserDbUtc` · 幂等写入 · `pending_push` 模式 · 值类型 `==`/`hashCode`。

### 三种写入分支（用枚举而非 `bool`）

`add()` 返回 `AddWordResult`：`added` / `alreadyExists` / `revived` / `limitReached`。

🔑 **为什么不用 `bool`**：`false` 无法区分「已存在」与「已达上限」——
而这两者要给**完全不同**的反馈（一个「已在生词本」、一个「要订阅」）。
用 `bool` 会迫使调用方再查一次库。

### 三条不可动摇的语义

1. **`added_at` 永不刷新**（幂等 + 复活都不改）—— 它表达「我第一次收它是什么时候」
2. **`source_sentence` 取首次**，不被后续查词覆盖（v1 明确决策）
3. **上限口径 = `COUNT(*) WHERE deleted = 0`** —— 已移出的不占额度

---

## 五、验收

| 验收 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4（81 文件） |
| `verify_tokens` | ✅ **397 项**（+15，新增 §16 接线） |
| 🆕 `verify_userdb_migration` | ✅ **20 项** |
| 🆕 `verify_user_word` | ✅ **53 项** |
| `verify_bookmark` | ✅ 52 项（**未回归** —— 证明共享连接重构没破坏收藏） |
| 其余 5 个脚本 | ✅ 42/31/37/6/22 全不变 |
| `trace_verify` | ✅ 97 项 |

### 证伪测试（3 组，全部有效）

| 篡改 | 结果 |
|---|---|
| `kUserDbVersion` 2 → 1 | ✅ **3 条准确报红**（含「user_word 已创建」），并打印根因提示 |
| 写入改回 `await`（阻塞）+ bookmark 又自己 open | ✅ **4 条准确报红** |
| （另）§16 首跑抓到 2 条**我自己写错的断言** | ✅ 已修 |

🔑 第 1 组的证伪还顺带改好了一处体验：**脚本原本崩溃退出**（在 §5 直接 `INSERT` 不存在的表），
现改为**前置守卫 + 跳过后续节**，做到「干净报红 + 给出根因」——
因为**崩溃容易被误读成「环境问题」**，而这里要表达的恰恰是「实现错了」。

---

## 六、⏳ 待白哥真机验证（**脚本验不到的部分**）

**前提**：本次改了 schema + `kUserDbVersion` → **必须重新构建**。

```powershell
cd E:\CoEvo\app
D:\flutter\bin\flutter.bat build apk --release
```

### 重点验 1：🔴 **老库能否升级出两张新表**（本次最关键的验证）

你手机上已有 `user.db`（收藏功能验过）→ 装了新包后它会**原地升级**。
- **预期**：一切正常，收藏**还在**（升级不能丢数据）
- 🔴 **若失败**：进阅读器查词会报「词库打开失败」之类的错
  → `adb logcat | grep user_db` 能拿到真实异常（这是本次专门补的日志）

### 重点验 2：查词是否真的写入了

1. 进阅读器 → **长按一个词** → 弹浮层（**应立刻弹出，不等落库**）
2. 杀进程 → 重开 → 进「复习」tab → **该词应已在复习列表里**（说明进了 `card_review_state`）
3. 生词本页**尚未做**（属 3.5 之后的界面）→ 目前只能通过复习列表间接确认

### 重点验 3：未命中的词

- 长按一个**词库里没有的词** → 应提示「词库里没有「X」」
- 但它**仍被记进 `lookup_event`**（无 UI 可看，属数据层 —— 靠验收脚本保证）

### ⚠️ 一个**已知未做**（如实说明）

**`source_sentence` 目前是空的** —— 本轮**没有可靠的「所在句」来源**
（要从正文渲染层拿到句子边界）。所以：
- 「取首次语境」的**逻辑**已实现并有断言
- 但**首条数据本身为空** → 这个功能**还没真正产生价值**
- 真实语境需在后续增强里从 `trace_locator` / 正文段落拿句子边界

🔑 我**没有**用「整段正文」或「查词时的随机文本」去充数 —— 那会写进一条**看起来像例句、
其实是错的东西**，比留空更糟（本项目已记录过「宁可留空也不记错的」原则）。

---

## 七、留待 Phase 3（本次**未做**）

- **词库外生词 → LLM 制卡**（白哥原话「进入词库」）——
  ⚠️ **开工前必须澄清「进入词库」的确切含义**：v1 原设计是写 `external_word_cache`（端侧缓存），
  若按字面理解成写 `word.db` 会撞两堵墙：
  ① 破坏只读预制库前提 ② `user_word.word_id NOT NULL` 与「词库外词无 id」的结构断链
  📄 详见 `step3-4c-word-writeback-plan-2026-09-28.md` §六
- **`lookup_event.sentence` / `position` 的真实采集**（见上）
- **生词本界面**（列表 / 200 词计数 / 上限提示的落地时机）
- **同步**（三表都是 `pending_push` 就绪、无调用方）
