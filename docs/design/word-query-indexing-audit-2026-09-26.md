# Phase 1 #11「索引化查询」调查报告

- 日期：2026-09-26 ｜ 触发：白哥指派「Phase 1 #11 索引化查询」
- 结论：**该任务的文档前提不成立** —— 要「替代」的东西是**死代码**，而**索引早已齐备**。
  真实需求是**另一个东西**（端侧查词能力），需白哥重新界定范围。
- 依据：`backend/crates/chat_engine/src/word_bank.rs` 实码 + `data/word.db` 实测 + `data/coevo.db` +
  `scripts/sqflite_probe/`（可复跑探针）
- ⚠️ **本报告初版只做调查**；白哥 2026-09-26 逐项定案后，**已按方案 A 实施完毕** —— 见 §九「实施结果」。

> ## ✅ 已实施（2026-09-26，白哥定案后）
>
> | 白哥的决定 | 落地 |
> |---|---|
> | **① 方案 A**（拆出可验证的查询层） | ✅ `WordQueryService`（`app/lib/services/`）+ 🆕 `scripts/query_verify/`（**79 项断言全过**） |
> | **② 跨库方案 = 冗余 `spelling`** | ✅ `user.db` schema **v1.1**：`card_review_state.spelling` + `idx_crs_spelling`；配 `ReviewListQuery`（搜索/三档排序/分组） |
> | **③** 后端 `word_bank.rs` 清理 | 🟠 **待定**（白哥追问「为什么本次不做」→ 见 §九 更正说明：我原假设「本地无法验证后端」**被实测推翻**，`cargo check` 9 分钟通过） |
> | **④ 更正 #11 定性** | ✅ 主方案 + `word-database-design` 共 **6 处**已更正并标注原因 |
> | **⑤ `scripts/` 入库** | 🟠 **待定**（白哥问「有什么」→ 见 §九 清单与建议） |

---

## 一、TL;DR

| 文档说 | 实测 |
|---|---|
| 「查词后端 `word_bank.rs` 每次调用**遍历全部 41,574 词条**（O(N) 全表扫）」 | 🔴 **那个函数是死代码** —— `match_text()` **0 个调用点** |
| 「**必须重写**」 | 🔴 **要修的对象不存在**；唯一被调用的 `lookup_cefr()` 本来就是 **O(1) HashMap** |
| 「划词性能基础」 | 🔴 **划词是端侧功能**（v1 §2.1「查词（词库内）离线可用」），与后端 `word_bank.rs` **无关** |
| （隐含）word.db 需要索引化 | 🔴 **索引已齐**：9 显式 + 18 自动 = **27 个**，所有查询都走索引 |

**真实缺口**：**端侧完全没有 DB 能力**（`app/pubspec.yaml` 无任何 SQLite 依赖、`app/lib` 无 DB 访问层、`word.db` 不在 app 内）。

**决定性好消息**：已验证 **纯 Dart 可用 `sqflite_common_ffi` 打开真 `word.db` 并查询**
（`scripts/sqflite_probe/`）→ **查询层可做成纯 Dart → 本地可验证**。

**🔴 顺带查出两处我此前引入的缺陷**（§六）：① `assets/sql/` **未声明 assets → 不打包**
② **`/scripts` 被 gitignore 而 CI 引用了它 → 2 个 job 必然失败**。两者都是「写了但没接通」，且都不报错。

---

## 二、文档前提错在哪（逐条实测）

### 2.1 `match_text()` 是死代码

文档引用点在 `english-app-implementation-plan-v2` §2366：「`word_bank.rs` 全表扫 → `word_bank.rs:111`」。
该行确实是 `for (id, entry) in catalog.iter()`（遍历全表）。

**但全项目搜索调用点**：

```bash
$ grep -rn "match_text" backend/ --include=*.rs | grep -v word_bank.rs
（无输出）
```

| 函数 | 复杂度 | 调用点 | 状态 |
|---|---|---|---|
| `match_text()` | **O(词库大小)** 全表扫 | **0** | 🔴 **死代码** |
| `lookup_cefr()` | **O(1)** HashMap | 1（`routes.rs:1617`） | ✅ 活的 |
| `get_cefr_catalog_stats()` | O(词库大小) | 1（`routes.rs:1606`） | ✅ 活的（统计接口） |

**→ 「必须重写 word_bank.rs」这个任务，修的是一个没人调用的函数。**

### 2.2 唯一被调用的路径是「个人统计」，不是查词

`routes.rs:1606-1625` 的用途（实码）：

```rust
// CEFR 词汇统计
let catalog_stats = chat_engine::word_bank::get_cefr_catalog_stats();
if let Ok(mut stmt) = conn.prepare(
    "SELECT c.front FROM user_cards c JOIN card_memory cm ON ... WHERE cm.state = 2 ...") {
    for front in rows.flatten() {
        if let Some(level) = chat_engine::word_bank::lookup_cefr(&front) { ... }
    }
}
```

- 遍历的是**用户已掌握的词**（不是全库）→ `lookup_cefr` 又是 O(1) → **该循环无性能问题**
- ⚠️ `get_cefr_catalog_stats()` **每次请求遍历 41,574 条**（可优化，但它是统计接口、频率低，**非划词路径**）

### 2.3 极重要的数字澄清：**41,574 与 11,523 是两个东西**

| 数据 | 规模 | 出处 | 用途 |
|---|---:|---|---|
| `backend/cefr_catalog.json` | **41,574**（12 MB） | CEFR-J 原始词表 | 后端 `word_bank`（**旧**，O(N) 扫） |
| **`data/word.db`**（新词库） | **11,523**（31 MB） | LLM 全库重跑产物，18 表 | **端侧**（v1 设计） |

→ 文档把「41,574 全表扫」当成划词瓶颈，**混用了两代数据**。

### 2.4 索引实测：早已齐备，且查询都走索引

```
$ python3（EXPLAIN QUERY PLAN）
word.spelling 精确    → SEARCH word USING INDEX sqlite_autoindex_word_3 (spelling=?)
word_form.form 精确   → SEARCH word_form USING COVERING INDEX sqlite_autoindex_word_form_1
card.word_id         → SEARCH card USING INDEX sqlite_autoindex_card_1 (word_id=?)
word_morpheme.word_id → SEARCH word_morpheme USING INDEX sqlite_autoindex_word_morpheme_1
```

`word.db` 索引清单（**27 个**）：

| 类型 | 数量 | 例 |
|---|---:|---|
| 显式 `CREATE INDEX` | **9** | `idx_word_spelling` · `idx_form` · `idx_anchor` · `idx_card_hash` · `idx_morpheme_root` … |
| `UNIQUE` 自动索引 | **18** | `word(spelling)` · `word_form(form,base)` · `card(word_id)` · `word_morpheme(word_id,position)` … |

**v1 要求的 `idx_word_spelling` 已在**（v1 §3.1.1 第 125 行）。
**v1 要求的 `idx_word_lemma` 不存在 —— 但这是已决策的修正**：v2 用 `word_form` 表替代了 `lemma` 列
（见 `word-db-migration-to-v1-design` 的「修正 2」），`word_form(form)` 已是 PK 前缀索引。

---

## 三、真实需求是什么（三层，逐层收窄）

| 层 | 内容 | 现状 |
|---|---|---|
| **① 词条查询（word.db）** | 划词 → 查 `word` → 取 `card.content`；变形 → 查 `word_form` 还原 | ✅ **索引已齐、查询已微秒级**（§四实测）**不缺索引** |
| **② 端侧 DB 能力** | SQLite 依赖 + DB 打开/加载 + word.db 打包 + 查询层代码 | 🔴 **完全缺失**（0 依赖 / 0 访问层 / 库不在 app 内） |
| **③ 复习列表与搜索（user.db）** | 按到期时间排序 + **按单词搜索** + 熟度三点 | 🟠 排序索引已有；🔴 **搜索受跨库阻塞**（见下） |

### 🔴 ③ 的一个真实架构问题（必须白哥定）

`app/assets/sql/user_db_schema.sql` 的 `card_review_state` **主键是 `word_id`，没有 `spelling`**：

```sql
CREATE TABLE card_review_state (
  word_id TEXT PRIMARY KEY,      -- 词库 word.id
  state INTEGER, stability REAL, difficulty REAL,
  next_review_at TEXT NOT NULL,
  ...
);
```

而 v1 的复习页要显示「**单词 + 释义 + 熟度 + 到期时间**」并支持**搜索** →
需要同时读 `user.db`（状态）与 `word.db`（spelling / 释义）→ **跨库**。

三个可选做法（各有代价）：

| 方案 | 做法 | 代价 |
|---|---|---|
| **A. 冗余 `spelling`** | `card_review_state` 加 `spelling` 列（写入时同步） | 查询最快、可建搜索索引；但**需保证与 word.db 一致**（词库升级时 spelling 不变，风险低） |
| **B. ATTACH JOIN** | 打开 user.db 后 `ATTACH word.db`，JOIN 查询 | 无冗余；但**两库都要常开**，且 ATTACH 路径管理复杂 |
| **C. 单库合并** | 把 word 相关表并入 user.db | 最简单；但**词库更新要整库替换**（31 MB），且破坏「词库只读 / 用户库可写」的分层 |

---

## 四、性能实测基线（可复跑）

### 4.1 Python `sqlite3`（稳态，2000 次取 p50）

| 查询 | p50 | p95 |
|---|---:|---:|
| `word WHERE spelling=?` → id | **19 µs** | 31 µs |
| **完整链路 `word` → `card.content`** | **43 µs** | 92 µs |
| `word_form WHERE form=?` | 17 µs | 29 µs |
| 词形还原 → 再查 word | 33 µs | 49 µs |

### 4.2 Dart + `sqflite_common_ffi`（纯 Dart，与 App 同语言栈）

| 指标 | 数值 | 说明 |
|---|---:|---|
| **首查（冷）** | **1.3–2.6 ms** | 含 FFI 初始化 + 页缓存冷启动（**仅启动后第一次**） |
| `word WHERE spelling=?` p50 | **156 µs** | 稳态（2000 次中位） |
| **完整查词链路 p50** | **228 µs** | `word` → `card.content` |
| 词形还原链路 p50 | 161 µs | `word_form` → `base` → `word` |
| 8 词句子级（一次事务）p50 | 445 µs | 模拟划一次词查一句 |
| 未命中词 p50 | 70 µs | **不退化** → 确认 O(log n) |

**结论：稳态 ~0.2 ms，远低于人类感知阈值（100 ms）。性能不是本任务的瓶颈。**

⚠️ **两个解读注意**：
1. **必须区分首查与稳态** —— 首查 2.6 ms 来自冷启动，不是查询慢
2. **这是 Windows 桌面 FFI，不代表 iOS 真机** —— 用于验证「索引有效」与「复杂度不退化」，**不是 iOS 性能承诺**
3. Dart/FFI 比 Python `sqlite3` 慢 3–8 倍（FFI 调用与数据编解码开销）—— **绝对值仍远低于阈值，无需优化**

---

## 五、可行性验证（决定性）

```bash
cd scripts/sqflite_probe
/d/flutter/bin/cache/dart-sdk/bin/dart.exe pub get --offline
/d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/query_probe.dart
```

实测输出（真 `word.db`，31.4 MB）：

```
表 18 个 · 索引 27 个
【精确查词】receive   → id=w001720 cefr=A2
【词形还原】received  → base=receive anchor=receive depth=1 in_vocab=0
【EXPLAIN】SEARCH word USING INDEX sqlite_autoindex_word_3 (spelling=?)
【参数化查询】注入尝试返回 0 行（应为 0）
✅ 纯 Dart 可用 sqflite_common_ffi 打开真 word.db 并查询
```

**意义**：查询层**不需要 Flutter** → 能用**真库**跑断言 → **本地即可验证**
（与 `scripts/fsrs_verify/`、`scripts/analyze_inproc/` 同一思路）。

**不能本地验证的部分**（须 CI/真机）：iOS 上 assets 里的 DB 打开路径、word.db 打包后的体积、首次拷贝 DB 的耗时。

---

## 六、🔴 顺带查出**两处**我此前引入的缺陷

`app/pubspec.yaml` 的 `flutter:` 段**只声明了 `fonts:`，没有 `assets:`**：

```yaml
flutter:
  uses-material-design: true
  fonts: [...]
  # ← 没有 assets: 段
```

**后果**：我上轮建的 **`app/assets/sql/user_db_schema.sql` 根本不会被打包进 App** →
端侧「建 user.db」时会找不到建表脚本。**这是一个静默失败**（编译不报错、运行时才炸）。

**同类风险**：将来把 `word.db` 放进 `assets/` 时，**必须同步加 `assets:` 声明**，否则同样静默失效。

### 6.2 🔴 `/scripts` 被 gitignore，而 CI 引用了它 → **2 个 job 必然失败**

`.gitignore` 第 18 行忽略了**整个目录**：

```
/scripts
```

**后果**：`git ls-files scripts/` → **0 个文件**（`scripts/` 下**全部未入库**）。

**而 CI 引用了它**：

| 位置 | 引用 | 影响 |
|---|---|---|
| `.github/workflows/ci.yml:85` | `working-directory: scripts/fsrs_verify` | 🔴 **`fsrs-verify` job 必失败**（checkout 后目录不存在） |
| `.github/workflows/ci.yml:121` | `python3 scripts/check_native_readiness.py` | 🔴 **`native-readiness` job 必失败** |

**影响面**（5 个 job 中 2 个）：

| job | 是否受影响 |
|---|---|
| `backend`（Rust） | ✅ 不受影响 |
| `frontend`（Flutter） | ✅ 不受影响 |
| **`fsrs-verify`** | 🔴 **必失败** |
| **`native-readiness`** | 🔴 **必失败** |
| `ios-build` | ✅ 不受影响 |

**连带发现**：`scripts/` 下还有**大量有长期价值的脚本**同样未入库 ——
`load_llm_results.py`（词库落库）· `build_chains.py`（形态链）· `classify_vocab_noise.py` ·
`verify_card_structure.py`（卡片结构验收）· `audit_coverage_denominator.py` …
→ **换机器 / 协作 / CI 上都拿不到**。

**三个修法**（请白哥选）：

| 方案 | 做法 | 代价 |
|---|---|---|
| **A. 白名单部分入库**（推荐） | 把 `/scripts` 改成 `/scripts/*` + `!/scripts/<要入库的>`，放行验证工具与可复用脚本 | 需逐个列出；一次性工作量 |
| **B. 验证工具移到 `tools/`** | 新建 `tools/` 放验证工具（未被忽略） | 需移动文件 + 改 CI 路径 |
| **C. 从 CI 移除这 2 个 job** | 不在 CI 跑验证 | 🟠 **放弃 CI 价值**（这两个 job 正是「本地跑不了」时的补偿） |

> 🔑 **教训：「文件写出来了」≠「它在目标环境可用」。**
> 与 §6.1 同源 —— `assets/sql/` 没声明 → 不打包；`scripts/` 被忽略 → CI 拿不到。
> **两者都是「写了但没接通」，且都不报错。**
> → **检查方式**：`git ls-files <path>`（是否入库）+ `git check-ignore -v <path>`（为何被忽略）

---

## 七、方案（请白哥选）

### 方案 A（推荐）：拆出「可验证的查询层」，DB 接入留 Step 3

| 项 | 内容 |
|---|---|
| **做什么** | ① 修 `assets:` 声明（含 `assets/sql/`，为 word.db 预留）② 加 SQLite 依赖（`sqflite` + `sqflite_common_ffi` 作 dev）③ 写**纯 Dart 查询层**（`WordQueryService`：查词 / 词形还原 / 取卡片 / 聚合成词卡）④ 写**断言集**（用真 `word.db`，扩 `scripts/sqflite_probe/` 为验收脚本）⑤ 产出索引补充 SQL（若 §三③ 选定方案） |
| **为什么现在做** | 🔑 **查询层与界面解耦** —— 它是**纯逻辑**，可立即验证；且 v1 §九 查词流程、复习页「搜索」都要它 |
| **不做什么** | DB 在 iOS 上的打开/拷贝、划词界面、复习页 UI（**属 Step 3/4**） |
| **可本地验证** | ✅ 全部（真库 + 真断言） |
| **预计** | **0.5–1 天**（查询层 ~200–300 行 + 断言 ~150 行） |
| **风险** | 低 —— 纯 Dart，不碰 UI，不改生产库 |

### 方案 B：整体推迟到 Step 3

| 项 | 内容 |
|---|---|
| **理由** | 划词界面（Step 3「★ 最大工作量」）会自然带出查询需求，一起做可避免接口返工 |
| **代价** | 🟠 **Step 2（设计系统）期间没有任何词库查询能力**；且「复习列表搜索」的跨库设计要等到那时才决策 |
| **预计** | 合并进 Step 3（不额外增加总工时） |

### 方案 C：只做依赖引入 + assets 修正（最小）

| 项 | 内容 |
|---|---|
| **做什么** | ① 修 `assets:` 声明 ② 加依赖 ③ **不写查询层** |
| **理由** | 若白哥认为「查询层属于实现细节，等 Step 3 一起写」 |
| **代价** | 🟠 修了静默缺陷，但**查询能力仍为零** |
| **预计** | **0.5 小时** |

### ⛔ 不推荐：按文档字面做

「重写 `word_bank.rs` 替代全表扫」→ **要修的函数 0 调用**，且 **划词不走后端** → **做出来的东西没人用**。
若白哥想清掉后端那两处（死代码 + 每次遍历 41,574 的统计接口），那是**独立的清理任务**，与本任务无关。

---

## 八、请示（4 项）

| # | 事项 | 我的建议 |
|---|---|---|
| **1** | **#11 的范围**（A / B / C） | ✅ **建议 A** —— 查询层是可立即验证的纯逻辑，且被 v1 查词流程与复习页搜索共同依赖 |
| **2** | 🔴 **复习列表的跨库方案**（§三③：冗余 spelling / ATTACH / 单库合并） | ✅ **建议 A「冗余 `spelling`」** —— 查询最快、可建搜索索引；词库升级不改 spelling，一致性风险低 |
| **3** | **后端 `word_bank.rs` 的处置** | 🟠 **建议独立清理**：删 `match_text` 死代码；`get_cefr_catalog_stats()` 的每次全遍历可改启动时预计算。**本次不做** |
| **4** | **`#11` 的定性是否更正** | ✅ **建议更正** —— 从「替代 `word_bank.rs` 全表扫」改为「**建立端侧索引化查询能力**」，并在文档标注原定性错误（避免后来者再按错误前提动手） |
| **5** | 🔴 **`scripts/` 是否入库**（§6.2：CI 有 2 个 job 必然失败） | ✅ **建议 A「白名单部分入库」** —— 放行**验证工具**与**可复用脚本**，一次性脚本仍忽略。⚠️ 不修则 CI 红着 |

**⚠️ 遵照铁律：本报告只做调查，未改任何业务代码（仅新增可复跑探针 `scripts/sqflite_probe/`）。等白哥批准后再实施。**

---

## 附：本次调查用到的事实来源

| 事项 | 来源 |
|---|---|
| `match_text` 0 调用 | `grep -rn "match_text" backend/ --include=*.rs`（排除自身） |
| `word_bank.rs` 三个函数的复杂度与调用点 | `backend/crates/chat_engine/src/word_bank.rs`（全文 243 行） |
| 调用上下文用途 | `backend/crates/api_server/src/routes.rs:1598-1625` |
| `cefr_catalog.json` = 41,574 | 文件实测（12,110,109 bytes） |
| `word.db` 索引 27 个 + EXPLAIN | `pragma` / `sqlite_master` / `EXPLAIN QUERY PLAN` 实测 |
| 性能数值 | Python `sqlite3` 2000 次 + Dart `sqflite_common_ffi` 2000 次 |
| 端侧能力缺口 | `app/pubspec.yaml` · `grep -rln "sqflite\|Database" app/lib/`（0 命中） |
| v1 查词流程与索引要求 | `v1-final-design-authoritative` §2.1 / §3.1.1 / §九 |

---

## 九、实施结果与两项更正（2026-09-26）

### 9.1 ✅ 方案 A 已实施

| 产物 | 说明 |
|---|---|
| `app/lib/services/word_query_service.dart` | 查词（含词形还原）/ 卡片段解析 / 聚合页入口 / 成员带**分拆法**；**只 import `package:sqflite_common/sqlite_api.dart`（纯 Dart）** |
| `app/lib/services/review_list_query.dart` | 复习列表 / 前缀搜索 / **三档排序**（白名单防注入）/ 到期计数 / 分组 |
| `app/lib/services/fsrs_service.dart` | `toRow({required String spelling})` —— 冗余列由**编译器**强制，不靠注释提醒 |
| `app/assets/sql/user_db_schema.sql` | **v1.1**：`spelling TEXT NOT NULL COLLATE NOCASE` + `idx_crs_spelling`；文件末附**变更记录** |
| 🆕 `scripts/query_verify/` | **验收套件**：`verify_word_query.dart`（**42 项**）+ `verify_review_list.dart`（**37 项**），退出码可挂 CI |
| `app/pubspec.yaml` | 加 `sqflite`（dep）+ `sqflite_common_ffi`（dev）；**修 `assets:` 声明缺失**（§6.1） |

**验收结果**：**79 项断言全过，退出码 0**。`app/lib` 的 analyzer error 仍只有 3 处（全是那 2 个待重写文件的 web-only）。

### 9.2 ⚠️ 更正一：我原以为「后端无法本地验证」——**错了**

白哥追问第 3 项「为什么本次不做」时，我复盘发现自己的**隐含假设不成立**：

| 我的假设 | 实测 |
|---|---|
| 本地无法编译/验证 Rust 后端 | 🔴 **`cargo check -p chat_engine` 9 分 02 秒通过，退出码 0**；`cargo 1.95.0` 可用，`target/` 已有 721 MB 构建产物 |

→ **「不能验证」不是理由**。真实的（较弱的）理由是「范围」：它属后端，而 #11 是端侧任务。
但既然能验证，且实测它**是真问题**：

| 项 | 实测 |
|---|---|
| `get_cefr_catalog_stats()` | 🔴 **每次「我的」页面加载（`GET /api/user/{id}/profile`）都全遍历 41,574 条** |
| 该结果是否静态 | 🔴 **完全静态** —— 只依赖启动时加载的 `cefr_catalog.json`，运行期不变 → 每次重算是纯浪费 |
| 开销量级 | Python 模拟 p50 **7.03 ms**（Rust 会更快）；41,574 条遍历 + 分组 |
| 修法 | 移到 `init()` 时算一次（或 `OnceLock` 缓存）→ 每请求变 O(1) |

→ **建议改为「本次一起做」**（约 20 行 + `cargo test` 验证）。

### 9.3 ⚠️ 更正二：`capture` 的文档表述可以更锋利

原表述「`capture` → ① 有内容但无入口」（正确），但实测还发现：

| `capture` 的段 | 入口 |
|---|---|
| `root`（`capt + -ure`） | 🔴 **无**（`capt` 族只 2 词，未达门槛） |
| `etymology`（`capere` 拉丁·拿取） | ✅ **有**（词源族 **56 词**） |

→ **两个入口各自独立判断**：渲染层要能处理「① 无箭头、② 有箭头」这种组合。
已把这句写进界面稿（`visual-word-card-target`）的对应位置与验收清单。

### 9.4 🔑 验收抓到的两个真问题（都靠断言发现，非人工排查）

| # | 问题 | 修法 |
|---|---|---|
| 1 | 「最近」排序用 `COALESCE(last_review_at, updated_at)` → **刚加入但上次复习较早**的词会被排到最后，与语义相反 | 改为 `updated_at DESC`（插入与更新都刷新）；**留一条断言专锁此情形** |
| 2 | `sqflite` 默认 `singleInstance: true` → 同路径二次 `open` 返回**同一实例**，`close()` **连带关掉别处连接**（实测 `database_closed`） | 需要独立连接时显式 `singleInstance: false`；生产上每库**只开一次** |

> 🔑 **这两条都不是靠读代码发现的，而是靠「能跑真库的断言」。**
> 印证了方案 A 的价值：查询层能在本地用真数据验证 → 错误在设计期暴露而不是上线后。

---

*本报告初版为调查产出（未改业务代码）；§九 为白哥定案后的实施记录。`data/coevo.db` 时间戳未变。*
