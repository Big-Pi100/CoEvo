# 源接入实施报告（2026-10-02 · 8 个新源）

> **白哥批准**：「同意」→ 接入上一轮建议的顺序 1–3：
> **NPR 6 个分频道** + **arXiv cs.CL** + **HackerNoon**。
>
> 🔴 **本报告含两个合规发现**，其中一个**改变了 HackerNoon 的定性**（见 §三）。
> ⚠️ **未部署**（生产环境未动）—— 但请务必先读 §五「部署会立刻做什么」。
>
> 📄 上游 → [`source-expansion-2026-10-02.md`](source-expansion-2026-10-02.md)（实测数据）· [`candidate-source-evaluation-2026-10-02.md`](candidate-source-evaluation-2026-10-02.md)
> 🔧 工具 → `backend/crates/api_server/examples/eval_candidate_sources.rs`（接入前验证）

---

## 一、做了什么

| # | 改动 | 文件 |
|---|---|---|
| ① | 新增 **8 行 seed**（id 6–13）：NPR 6 分频道 + arXiv cs.CL + HackerNoon | `backend/crates/api_server/src/schema.rs` |
| ② | 改 seed 断言：启用源 **4 → 12**；表行数 **5 → 13**；**新增 4 组守门断言** | `backend/crates/api_server/src/content_fetch.rs` |
| ③ | 端侧分类表加 **`health`**（依据已定稿规格，见 §四）| `app/lib/models/feed_item.dart` |
| ④ | `eval_candidate_sources.rs` 改为可复用的「**接入前验证**」模式 | `backend/crates/api_server/examples/` |

### 8 个新源的配置

| id | 名称 | URL | cat | cefr | license | redist |
|---|---|---|---|---|---|---|
| 6 | NPR World 国际 | `feeds.npr.org/1004` | news | B2 | news | **1** |
| 7 | NPR Business 商业 | `feeds.npr.org/1006` | business | B2 | news | **1** |
| 8 | NPR Science 科学 | `feeds.npr.org/1007` | science | B2 | news | **1** |
| 9 | NPR Culture 文化 | `feeds.npr.org/1008` | culture | B2 | news | **1** |
| 10 | NPR Technology | `feeds.npr.org/1019` | tech | B2 | news | **1** |
| 11 | NPR Health 健康 | `feeds.npr.org/1128` | **health** | B2 | news | **1** |
| 12 | arXiv cs.CL | `export.arxiv.org/rss/cs.CL` | science | C1 | **mixed** | 🔴 **0** |
| 13 | HackerNoon | `hackernoon.com/feed` | tech | B2 | **author** | 🔴 **0** |

### 📈 效果：兴趣领域 2 类 → **7 类**

| 之前 | 之后 |
|---|---|
| `news`(127) · `tech`(288) | + `business` · `science` · `culture` · `health` · 以及 news 侧扩量 |

---

## 二、接入前的真实代码验证（判据：不用脚本复刻）

把 8 个源加进 `eval_candidate_sources.rs`，走**生产同款路径**（`fetch_source_items` + `fetch_article_body_diagnostic`）：

| 源 | RSS 解析 | 条目 | 摘要中位 | 营销 | 网页提取 |
|---|---|---|---|---|---|
| NPR World | ✅ | 10 | 29 词 | 0 | **4/4 达标** |
| NPR Business | ✅ | 10 | 30 词 | 0 | **4/4 达标** |
| NPR Science | ✅ | 10 | 28 词 | 0 | **4/4 达标** |
| NPR Culture | ✅ | 10 | 30 词 | 0 | **4/4 达标** |
| NPR Technology | ✅ | 10 | 28 词 | 0 | 3/4 达标 |
| NPR Health | ✅ | 10 | 29 词 | 0 | **4/4 达标** |
| **arXiv cs.CL** | ✅ | **269** | **202 词** | 0 | 句末完整 **4/4**（本身偏短，符合预期）|
| **HackerNoon** | ✅ | 20 | **全文 1612 词** | 0 | 无需抓网页 |

**结论：8/8 全部可解析、可提取**。NPR 各频道的表现与现有 NPR 主频道**同构**
（摘要中位 28–32 词 · 提取 4/4 达标 · 营销 0）⇒ 是「同一个媒体的同一批内容」。

---

## 三、🔴 两个合规发现（本轮新查，之前没查过）

### 3.1 🔴 HackerNoon 的许可**不允许我们展示全文**

**实测条款原文**（`hackernoon.com/terms`，2026-10-02）：

> AS BETWEEN YOU AND COMPANY, **YOU ARE THE SOLE OWNER OF YOUR CONTENT**
> …
> **Record, process, or mine information about other Users**

并且**全文无 `CC BY` / `Creative Commons` / `attribution` 字样**。

⇒ ① 作者保留版权 ② terms **明确禁止挖掘其他用户的内容**。

**所以我把它设成 `redistributable = 0`**（`write_items` 会因此丢弃 `content:encoded` 的 1612 词，只留 14–28 词 `description`）。

#### ⚠️ 但这个设置让它的最大优势**失效**了

| 维度 | `redistributable = 1`（原计划）| `redistributable = 0`（已设）|
|---|---|---|
| 内容 | **1612 词全文**（RSS 自带，零抓取）| 14–28 词摘要 |
| 价值 | ⭐ 很高（长文 + 零成本）| 🟡 **接近 ECNS**（也是只存摘要）|
| 风险 | 🔴 许可不明（可能侵权）| ✅ 低 |

⇒ **它现在只是一个「零成本的短摘要源」**，而不是我上一轮推荐的那个「RSS 全文源」。
   **这是我上一轮的疏漏** —— 当时只看了内容质量，没查许可。

#### 请你选（三选一）

| 选项 | 说明 |
|---|---|
| **A.** 保持 `redistributable = 0`（现状）| 合规优先。留着无害（零抓取成本），但内容价值低 |
| **B.** 改成 `1` 展示全文 | 🔴 承担许可风险。**若选它，建议先咨询法律意见**（涉及上架合规）|
| **C.** 不接 HackerNoon | 最干净。**我略倾向这个** —— 因为 A 的价值接近 ECNS，而我们的 tech 类已充足（Dev.to 288 条 + HN 123 条）|

### 3.2 🟡 **存量源的 `license` 标注也需要复核**（顺带发现）

查 HackerNoon 时顺手查了同族的 Dev.to，发现**现有标注也不准确**：

| 源 | 现标注 | 实测条款 | 问题 |
|---|---|---|---|
| **Dev.to**（id=4，在用）| `cc` · redist=**1** | 「**personal, non-commercial transitory viewing only**」 | 🟡 不是 CC；且**非商业**限制与我们「订阅收费」冲突 |
| Hacker News（id=5）| `public_domain` · redist=1 | HN 的条目是**用户提交的标题+链接** | 🟡 需确认 |

⚠️ **这不是本轮引入的**，是**存量标注**。但既然发现了必须说清 ——
   因为它直接关系到**上架合规**（App Store 审核 + 中国区法律）。

📌 **建议**：把「**内容源的许可复核**」加进「**上架前强制检查项**」
   （与「支付/恢复购买」「文章朗读权益」同批）—— 现在做成本最低。

---

## 四、🔴 发现一个规格漂移：category 词表

**实施时发现**：定稿与代码不一致。**先读定稿**（判据：动手前先搜已定规格）：

`docs/design/english-app-implementation-plan-v2-2026-09-25.md` §10.3.1：

> **✅ 定稿：扩到 7 个 category，删掉 `life`**
> ```sql
> category TEXT NOT NULL
>   CHECK (category IN ('tech','business','science','sports',
>                       'culture','entertainment','health'))
> ```
> 理由：…**删掉 `life`** —— 「生活」太糊（睡眠算健康还是生活？），会让抓取时的分类判断不稳定

**而当前代码**（`schema.rs` + `feed_item.dart`）是 **6 个值**：

| | 定稿（7 个）| 实现（6 个）|
|---|---|---|
| 共有 | tech · business · science · culture | 同 ✅ |
| 定稿独有 | **sports · entertainment · health** | — |
| 实现独有 | — | 🔴 **news** · 🔴 **life** |
| CHECK 约束 | 有 | 🔴 **无** |

#### 本轮我的处理（**只做必要的一步**）

- ✅ **加了 `health`**（因为要接 NPR Health 频道，且**它是定稿里的值**，不是我发明的）
  - 后端 seed 用它 + 端侧 `_categoryLabels` 加一行
- ❌ **没做**「删 `news`/`life`」「加 `sports`/`entertainment`」「加 CHECK 约束」
  - 理由：这些要连带处理**存量 `content_pool.category`**
    （生产库现有 `news` 127 条、`tech` 288 条）+ 后端 CHECK + 断言 + 设计文档，
    **是一组动作**，不该混进「加源」这一批

⚠️ **已写进代码注释**（`feed_item.dart` 的 `_categoryLabels` 上方），避免下一个人以为这是完整的词表。

📌 **请你定**：是否要按定稿把词表收敛到 7 类？（`news` 怎么办 —— 定稿里没有它，但现有 127 条数据用它）

---

## 五、⚠️ 部署会立刻做什么（**重要，请先读**）

### 5.1 seed 的生效机制

`db_pool.rs:47` 在**每次服务启动**都调用 `init_database`，而 seed 用的是
`INSERT OR IGNORE`：

```sql
INSERT OR IGNORE INTO content_source (id, name, url, ...) VALUES (6, 'NPR World 国际', ...), ...
```

⇒ **id 6–13 不存在于生产库 ⇒ 重启后会被插入**。

### 5.2 所以部署的连锁反应

| 步 | 会发生什么 |
|---|---|
| 1 | 服务重启 → `init_database` 执行 seed → **生产库自动多出 8 行源**（enabled=1）|
| 2 | 下一轮抓取（≤6 小时后）→ **立刻开始抓这 8 个源** |
| 3 | arXiv **269 条/天** 会进入 `content_pool`（摘要 202 词）|
| 4 | NPR 6 频道各 ~10 条/轮，共 ~60 条/轮 ⇒ **~240 条/天** |
| 5 | HackerNoon 20 条/轮 ⇒ 仅摘要入库 |

🔑 **不需要单独的 INSERT 语句**（seed 会自动做）—— 但这也意味着
   **部署即改生产数据**，无法「先部署代码、稍后再加源」。

⚠️ 若想先不抓（例如想先审一遍配置），可以两步走：
  部署 + 立刻把某几个源 `UPDATE content_source SET enabled = 0`。

---

## 六、验证

| 检查 | 结果 |
|---|---|
| `cargo fmt --check` | ✅ 通过 |
| `cargo clippy --workspace --all-targets -D warnings` | ✅ 通过 |
| `cargo test --workspace` | ✅ **154 + 20 项全过** |
| 端侧语义静态分析（`scripts/static_check`）| ✅ **error = 0**（96 文件）|
| **证伪（新断言真会报红吗）** | ✅ **5/5 如期报红**，还原后复跑全绿 |

### 🔴 过程中被两道「防线」各拦下一次

**① `cargo test` 拦下**：`schema.rs:1106` 还有**第二处**锁死 seed 行数的断言

```
assertion `left == right` failed: 种子源应为 5 个（实测可达清单）
  left: 13   right: 5
```

⇒ 同一件事（seed 行数）被**两处**断言锁着：
- `content_fetch::test_seed_sources_are_loaded` → 数的是**启用数**（12）
- `schema::test_core_table_columns` → 数的是**表总行数**（13）

📌 **教训**：这不是「两处冗余」，而是**两个不同口径**（启用 vs 总量）。
   我一开始只改了前者 —— 因为**不知道后者存在**。
   ⇒ 修法不只是「把 5 改成 13」，而是**在两边都写清「另一处数的是什么」**，
     否则下一个人还会只改一处、并把另一处当成「另一个 bug」。
   （同族判据：**同一件事的口径只能有一处权威 + 写明参照系**。）

**② `cargo clippy` 拦下**：删 `DIRECT_PAGES` 时留下**孤立的 doc 注释**

Rust 允许 doc 注释挂在「下一个 item」上 ⇒ 那段说明（讲「没有 RSS 的源」）
**静默跑到了 `PROMO_TITLE_WORDS` 头上**，成了误导性文档。
🔴 **它不是编译错误**（`cargo test` 全绿），只有 `clippy -D warnings` 能发现。
📌 这是「**改造后残留**」的又一实例 —— 与项目已记的
   「改造后『没人用』不是编译错误」「抽出的 widget 会漏 = 假绿」同族。

### 证伪明细（判据：新增的防漂移断言必须验证「破坏了会红」）

| # | 注入 | 结果 |
|---|---|---|
| 0 | arXiv 的 `redistributable` 0→1 | ✅ 报红 |
| 1 | HackerNoon 的 `redistributable` 0→1 | ✅ 报红 |
| 2 | NPR Health 的 `category` health→news | ✅ 报红 |
| 3 | NPR World 的 `tz_offset_min` 0→480 | ✅ 报红 |
| 4 | NPR Culture 的 `enabled` 1→0 | ✅ 报红 |

🔑 证伪工具用 `os.utime()` 强制刷 mtime —— 否则 cargo 可能**跳过重编**、
   复跑用的还是注入版二进制（本项目已记过这个坑）。

### 新增的 4 组守门断言（在 `test_seed_sources_are_loaded` 里）

| 断言 | 防的是什么 |
|---|---|
| **分类覆盖** `news/tech/business/science/culture/health` 都有源 | 「扩源补类型」这个**目的**本身 |
| **许可受限的源必须 `redistributable = 0`** | 把不该存的内容**静默存进来**（改了不会报错）|
| **NPR 7 个源 `redistributable` 必须一致（=1）** | 分频道与主频道**条款漂移** |
| **arXiv/HackerNoon/NPR 的 `tz_offset_min` 必须为 0** | 时间被**错误解释**（ECNS 是唯一的 480 例外）|

📌 判据：**「决定」要固化成断言**（只写在注释里会漂移）。

---

## 七、待白哥决策

| # | 事项 | 选项 |
|---|---|---|
| 1 | 🔴 **HackerNoon 怎么处理** | A 保持 `redist=0`（合规但价值低）/ B 改成 1（有许可风险）/ **C 不接（我略倾向）** |
| 2 | 🔴 **部署** | 未动。⚠️ 部署即自动插 8 个源并开始抓（见 §五）|
| 3 | 🟡 **存量许可复核** | Dev.to / HN 的 `license` 标注是否要复核？建议进「上架前强制检查项」|
| 4 | 🟡 **category 词表是否按定稿收敛** | 定稿 7 类（删 life、加 sports/entertainment）vs 实现 6 类（含 news/life）—— `news` 的 127 条存量怎么归？|

---

## 八、复现方式

```bash
# 接入前验证（改 CANDIDATES 数组即可扩展）
cd backend && cargo run -q -p api_server --example eval_candidate_sources

# CI 三项
cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

---

## 九、✅ 白哥三条决定已实施（2026-10-02 21:33 · `456a72b`）

| # | 决定 | 落地 |
|---|---|---|
| 1 | **HackerNoon 不接** | 从 seed 摘除 → 启用源 **12 → 11** · 表行数 **13 → 12** |
| 3 | **存量：加保留期机制**（不动现有数据）| `COEVO_CONTENT_RETENTION_DAYS`（默认 **30 天** · `0`=关）|
| 4 | **category 按定稿收敛** | → **8 类** = 定稿 7（删 `life`）**+ `news`** |

### 9.1 HackerNoon 为何「不接」而不是「接了只存摘要」

许可既然**只允许存摘要**（terms: `YOU ARE THE SOLE OWNER OF YOUR CONTENT`），
而 HackerNoon 的价值**恰恰在「RSS 全文」**（1612 词）⇒
接了也只等于**再加一个 ECNS**（也是只存摘要）⇒ 没有增量价值。

📌 判据：**当一个源的核心优势被合规挡掉时，「不接」通常优于「接个残废版」**。

### 9.2 保留期机制：`fetched_at` 而非 `published_at`

🔴 **实测必需**：有些源的条目**本身就是旧的** ——
· Dev.to 的 RSS 里有 **2020 年**的热门老文
· Smashing 的 40 条跨度 **156 天**（最新 09-30、最旧 04-27）

⇒ 用 `published_at` 会「**刚抓到就被删**」。`fetched_at` 的语义是
   「这条内容**我们**保留了多久」，与源给的日期无关。

| 参数 | 值 | 理由 |
|---|---|---|
| 默认保留 | **30 天** | 读者仍需要可翻的积压；同时库不会无限增长 |
| 每轮限量 | **500 条** | SQLite 单写者，一次删几万行会**长时间持写锁**，挡住抓取入库 |
| 新增索引 | `idx_cpool_fetched` | 否则每轮清理全表扫 |
| `0` / 负数 | **不清理** | 留一个**一键关闭**的止血开关 |

#### 🔴 删之前「三问」的实测答案

| 问 | 答 |
|---|---|
| 谁在读它 | 端侧 **`bookmark.content_id`**（收藏）+ **`article_read.article_id`**（已读）|
| 服务端知道收藏吗 | ❌ 不知道（**没有服务端 bookmark 表**，收藏只在端侧）|
| 端侧有正文缓存吗 | ❌ 没有 —— 阅读页**联网取** |
| **id 会复用吗** | ✅ **不会** —— `content_pool.id` 是 **`AUTOINCREMENT`** |

🔑 **`AUTOINCREMENT` 那句注释当时就是为保留期预留的** —— 原文：

> 普通 `INTEGER PRIMARY KEY` 在**删除后会复用** id（取 max+1）——
> **若内容池做保留期清理**，被清理文章的 id 会被新文章占用
> → 端侧那条「已读」记录会**静默指向另一篇文章**。
> `AUTOINCREMENT` 保证 id 单调不复用 → 断掉这条静默错配。

⇒ **九月底做 schema 时就预见到了这个需求，今天直接落地、无需额外改造。**

⚠️ **残余风险（如实记录）**：**「点开收藏打不开」**（收藏的那篇被清理后）。
   当前**零真实用户**（生产库 `users` 仅 1 行 trial）⇒ **现在无影响**。
   若将来做「离线阅读 / 收藏时缓存正文」，这条风险自然消失。

### 9.3 category 收敛 → 8 类

| 值 | 来源 |
|---|---|
| `tech` `business` `science` `sports` `culture` `entertainment` `health` | **定稿**（§10.3.1 的 7 类）|
| **`news`** | 🆕 **白哥追加的第 8 类** |

**为什么保留 `news`**：定稿两版都**没有**它 ——
它是**实现期**为 NPR / ECNS 临时加的，一直没进设计文档。
而「综合 / 国际新闻」确实**不属于任何兴趣类** ⇒ 硬塞会不准。

**动作**：
| 动作 | 结果 |
|---|---|
| 删 `life` | ✅ 生产库**无源用它** ⇒ 零影响 |
| 加 `sports` / `entertainment` | ✅ 进词表（**暂无源**，见 §待定）|
| 新增 `CONTENT_CATEGORIES` 常量 | ✅ **唯一权威定义处** |
| `content_source.category` 加 CHECK | ✅ |
| `content_pool.category` **不加** CHECK | 🔴 **故意的** —— 见下 |

#### 🔴 为什么 `content_pool` 故意不加 CHECK（尽管定稿写了）

入库用的是 **`INSERT OR IGNORE`**，而 SQLite 的 OR IGNORE
**会把 CHECK 违规一并忽略** ⇒ 结果是**静默丢内容**（用户看不到、日志也没有）。
📌 这比「没有约束」**更糟** —— 正是本项目最忌讳的「静默失败」。
⇒ 约束改到**上游**做：`content_source` 有 CHECK（配置表、改错立刻报错），
   且源配置被断言锁住 ⇒ `content_pool` 拿到的值天然合法。

#### 🆕 跨语言词表一致性断言（`verify_feed_wiring.dart` 【9】组 · +13 项）

词表**同时存在于两种语言**：后端 `CONTENT_CATEGORIES` + 端侧 `_categoryLabels`。
后端加类而端侧没跟上时：**不报错**，只是卡片显示兜底词 `Reading`
（`_unknownCategory`）—— **用户看到异常，而没有任何一处会红**。

断言内容：两边**集合相等**（不是「包含」——多一个也是漂移）·
定稿 7 类都在 · `news` 在第 8 位 · **`life` 已从两边消失** · CHECK 与常量同步。

📌 跨语言时做不到「物理上的一处定义」⇒ 改成
   **「一处权威 + 一处镜像 + 断言钉住」**。

### 9.4 🔴 过程中的自身失误（测试立刻抓到，值得记）

删 HackerNoon 时，我把 arXiv 那行结尾从 `,` 改成 `;` ——
**但原文已经是 `),`** ⇒ 变成 **`),;`**（多一个逗号）⇒ **SQL 语法错误**。

**`cargo test` 立刻抓到**：`auth::tests::*` **全红**（它们都依赖 `init_database`）：

```
content schema: near ";": syntax error
```

📌 **这一批测试的价值在这里体现**：schema 改坏 = **整库起不来**，
   而它不是「跑 seed 断言时才暴露」，是**所有**建库的测试一起红。

### 9.5 验证

| 检查 | 结果 |
|---|---|
| `cargo test --workspace` | ✅ **178 项**（158 + 20 · 新增 4 条保留期断言）|
| `cargo fmt --check` / `clippy --all-targets -D warnings` | ✅ / ✅ |
| 端侧语义静态分析 | ✅ **error = 0** |
| `verify_feed_wiring` | ✅ **57 项**（+13）|
| `tokens_verify` / `trace_markdown` / `verify_unescape` / `user_word` / `article_text` | ✅ 687 / 43 / 56 / 54 / 19 |

**证伪（4/4 全红）**：端侧删 `sports` ✅ · 保留期比较方向写反 ✅ ·
去掉「0 = 不清理」守卫 ✅ · 去掉每轮限量 ✅

---

## 十、⏳ 现在的待定项（更新）

| # | 事项 | 状态 |
|---|---|---|
| 1 | 🔴 **部署** | 未动。⚠️ 部署即**自动插入 7 个源**（NPR 6 + arXiv）并开始抓；30 天保留期同时生效 |
| 2 | 🟡 **`sports` / `entertainment` 要不要补源** | 词表已有这两个值但**没有源**。NPR 对应频道**实测可达**：Sports=`feeds.npr.org/1055` · Movies=`feeds.npr.org/1045`（各 10 条/轮）。不补 ⇒ 将来做兴趣筛选时这两个标签**拉不到内容**（定稿 §10.3 的原话）|
| 3 | 🟡 **存量许可复核**（Dev.to / HN） | 建议进「上架前强制检查项」（与支付/恢复购买、文章朗读权益同批）|
| 4 | ✅ ~~HackerNoon~~ | **已定：不接** |
| 5 | ✅ ~~category 收敛~~ | **已定：8 类** |
| 6 | ✅ ~~存量处置~~ | **已定：加保留期机制（30 天），不动现有数据** |
