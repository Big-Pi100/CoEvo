# category 扩到 12 类 + 「8 类之外」频道接入（2026-10-02 三轮）

> **给白哥** · 起因：「『8 类之外』但存在的高价值频道 —— 这些要接入，而且**如果不能归类
> 的话可以增加新的分类**」。
>
> 🔴 本文所有数字都在本机用**后端真实代码**实测
> （`examples/eval_candidate_sources.rs` → 真 `fetch_source_items` + `fetch_article_body_diagnostic`）。
>
> 📄 上游 → [`npr-feed-catalog-2026-10-02.md`](npr-feed-catalog-2026-10-02.md)（1400 个 ID 全扫）
> · [`sports-entertainment-source-2026-10-02.md`](sports-entertainment-source-2026-10-02.md)（二轮）

---

## 一、结论速览

| 项 | 结果 |
|---|---|
| 分类 | **8 类 → 12 类**（新增 `education` · `history` · `law` · `family`）|
| 接入源 | **13 → 23 个启用源**（新增 10 个 NPR 频道）|
| 12 类源覆盖 | ✅ **全部有源**（断言锁住：分类集合 ≡ `CONTENT_CATEGORIES`）|
| 测试 | `cargo test -p api_server` **159 passed** · 证伪 **2/2** |
| 部署 | ❌ **未部署** |

**一句话**：白哥点名的 6 个频道全部接入；另外 4 个同类频道一并接入（省得再来一轮）。
**4 个无法归类的**新建成类；**能归类的**归入现有类（不让兴趣标签膨胀）。

---

## 二、🔑 本轮最值钱的判据：区分**独立话题**与**跨类编辑栏目**

扫出的 71 个活跃频道里，有一批**不是话题，而是「同一批内容的另一种呈现」**。

**实测证据**（抓一轮标题看）：

| 跨类编辑栏目 | 同一轮里的内容分属哪些类 |
|---|---|
| `Obituaries`(1062) | 「纪念爵士 John Coltrane」→ `culture` ·「画家 Sliman Mansour」→ `culture` ·「NPR 编辑逝世」→ `news` |
| `Race`(1015) | 「为孩子选学校」→ `education` ·「Kaepernick 下跪十年」→ `sports` ·「黑人为何亲近 Dolly Parton」→ `culture` |
| `On Disabilities`(1133) | 「特殊教育主管辞职」→ `education` ·「寄养中的残障儿童」→ `health` |
| `Opinion`(1057) | 政治评论 / 讣告 / 雕塑艺术 —— 全跨 |
| `Analysis`(1059) | 犯罪 / 中东 / 经济 / 政治 —— 全跨 |
| `Perspective`(1166) | 9/11 家事 / Gen Z / AI / Michael Jackson —— 全跨 |

⇒ **给它们建类会让分类自相矛盾**（一条内容同时属于两个类）⇒ **不接**。

📌 判据：**「这个 feed 切的是话题，还是视角？」**

⚠️ **要如实说明**：这 6 个栏目的**质量并不差**（实测 4/4 达标 · 营销 0）——
不接是**归类口径**的决定，**不是质量问题**。若将来「视角」要作为独立维度（如
「深度 / 观点」标签），它们随时可以接，那时它们**不是 category**，而是另一个字段。

---

## 三、接入的 10 个频道（实测数据）

全部是 NPR topic feed ⇒ 与 `NPR News`(id=1) **同一媒体** ⇒
`license`/`redistributable` **逐字相同** ⇒ **零新增合规风险**。

| ID | 频道 | 归入类 | RSS | 营销 | ≥300 词 | 句末完整 | 摘要中位 |
|---|---|---|---|---|---|---|---|
| 1013 | **Education** | 🆕 `education` | 10 | 0 | **4/4** | — | 27 词 |
| 1136 | **History** | 🆕 `history` | 10 | 0 | 3/4 | — | 30 词 |
| 1070 | **Law** | 🆕 `law` | 10 | 0 | 2/4 | — | 30 词 |
| 1164 | **Family** | 🆕 `family` | 10 | 0 | **4/4** | — | 29 词 |
| 1016 | Religion | `culture` | 10 | 0 | **4/4** | — | 28 词 |
| 1142 | Architecture | `culture` | 10 | 0 | **4/4** | — | 29 词 |
| 1165 | Weather | `science` | 10 | 0 | **4/4** | — | 28 词 |
| 1146 | Strange News | `news` | 10 | 0 | **4/4** | — | 29 词 |
| 1028 | On Aging | `health` | 10 | 0 | **4/4** | — | 28 词 |
| 1020 | Media | `news` | 10 | 0 | **4/4** | — | 30 词 |
| *1001* | *NPR News（对照）* | *news* | *10* | *0* | *4/4* | — | *32 词* |

**结论**：质量与对照**同档**（NPR 频道是同构的），**营销 0**。

📌 **Law 的 2/4 是全批最低**（另 2 篇 <300 词）—— 但仍与对照的基准同一量级，
且 **RSS 摘要照样进 `summary`**（卡片有摘要可展示），故不影响接入。

### 3.1 重叠实测：**0–17%**（接它们不会造成内容重复）

| 新频道 | vs 最可能重复的已接频道 | 重叠 |
|---|---|---|
| Education(1013) | Culture(1008) 17% · News(1001) **0%** | 低 |
| Law(1070) | News 17% · Politics 17% · Business **0%** | 低 |
| On Disabilities(1133) | Health 17% · News **0%** | 低 |
| History / Family / Religion / Architecture / Weather / Strange News / On Aging / Media | — | **全部 0%** |

⇒ 与二轮结论一致：**NPR topic feed 基本是独立内容池**。

---

## 四、分类设计：8 → 12 类

### 4.1 为什么是这 4 个新类

| 新类 | 承载 | 为什么**不能**归入现有类 |
|---|---|---|
| `education` | 1013 | `culture` 是艺术/音乐，`news` 太泛 —— 教育是独立领域 |
| `history` | 1136 | `culture` 装不下「人口普查史 / 考古 / DNA 家谱」 |
| `law` | 1070 | `business` 是经济，装不下「死刑 / 最高法院 / 诉讼」 |
| `family` | 1164 | 定稿删掉的是 `life`（理由「太糊」），而 `family` 很具体（育儿假 / 托儿成本 / 照护父母）—— **不是同一个东西** |

### 4.2 为什么不新增更多（能归则归）

| 频道 | 归入 | 理由 |
|---|---|---|
| Religion | `culture` | 信仰与宗教文化是文化的一部分 |
| Architecture | `culture` | 建筑是艺术门类 |
| Weather | `science` | 气象是地球科学 |
| Strange News | `news` | 趣闻即新闻 |
| Media | `news` | 「关于新闻业的新闻」，受众与 news 重合 |
| On Aging | `health` | 内容实测全是健康（免疫细胞 / 痴呆护理 / 认知衰退）|

### 4.3 🔴 12 个是上限

**兴趣标签是用户可见的**（定稿 §10.3.1：「粒度决定『按我兴趣推』的感知强度」）。
12 个已是移动端一屏承受的上限 —— **再加就该先合并**（`law`→`news` · `family`→`health`）。

✅ 好消息：**兴趣选择界面尚未实现**（端侧只有 `feed_item.dart` 的显示映射），
所以本轮新增类的成本只是「词表 + 前端 map」两处，**没有已上线的界面要改**。

---

## 五、实施清单

| 文件 | 改动 |
|---|---|
| `backend/crates/api_server/src/schema.rs` | `CONTENT_CATEGORIES` 加 4 类 · `CHECK` 同步 · seed 加 **id 15–24** · 注释写明判据 |
| `backend/crates/api_server/src/content_fetch.rs` | 断言：启用源 **13→23** · 表总行 **14→24** · NPR 源 **9→19** |
| `backend/crates/api_server/src/schema.rs`（测试） | 种子数 **14→24**；🆕 **新增独立断言** `test_content_source_check_matches_categories` |
| `app/lib/models/feed_item.dart` | `_categoryLabels` 加 4 个（**词表 key 是唯一权威的镜像**）|

⚠️ **前端无需改逻辑** —— `_categoryLabels` 是唯一改动点，跨语言一致性断言（集合相等）**自动适配**。

### 5.1 🔴 实施中发现的一个坑：`CHECK` 与 `INSERT OR IGNORE` 的组合

**背景**：`content_source.category` 上有 `CHECK`（8 类），而 seed 用 `INSERT OR IGNORE`。

**三条事实构成一条无报错的失效链**：

1. `INSERT OR IGNORE` 会**静默吞掉** CHECK 违规（不只是重复冲突）
2. `CREATE TABLE IF NOT EXISTS` **不重建已存在的表** ⇒ SQLite **不支持 ALTER 改 CHECK**
   ⇒ **CHECK 只对新库生效**
3. 由 1+2：「词表加了类、CHECK 没加」⇒ **新库静默丢源**，
   数量断言虽然会红，但它只说「少了一行」，**不告诉你是哪个类**

**查证结果（对本项目的实际影响）**：

| 库 | `content_source` 建于 | CHECK 状态 |
|---|---|---|
| 生产库（VPS）| 2026-09-29 `6c7d60d` —— **那时没有 CHECK** | 🔴 **根本没有 CHECK**（CHECK 是二轮 `456a72b` 才加的）|
| 新库（测试/将来重建）| 现在 | ✅ 有（12 类）|

⇒ **好消息**：生产库没有 CHECK ⇒ 新类**能正常插入**，接入不会被挡。
⇒ **隐患**：二轮加的 CHECK 在**生产库永远不生效**（`IF NOT EXISTS` 跳过），
   「写了 CHECK」≠「生产在校验」—— 这条已写进 `schema.rs` 注释。

**本轮的处理**（不引入表重建的复杂度）：

- ✅ 同步 CHECK 到 12 类（保证**新库**正确）
- ✅ **新增独立断言** `test_content_source_check_matches_categories`：
  **读 `sqlite_master` 的 DDL**，逐值比对 `CONTENT_CATEGORIES`
  ⇒ 缺哪个类**直接指出来**，而不是只报「少了一行」
- ✅ 断言**独立成 test** —— 因为塞在数量断言后面**根本没机会跑**（实测确认）
- ⏳ **未做**：让旧库也获得 CHECK（需**重建表**）。**是否需要，请白哥定** ——
  收益是「生产也校验分类」，代价是一次带风险的 DDL 迁移。

📌 判据（已入 skill）：**断言要读「生效的东西」（DDL），而不是读「源文件里的声明」**。

---

## 六、验证

### 6.1 测试

```
cargo test -p api_server   →   159 passed; 0 failed
```

### 6.2 三方一致性（词表 ≡ 端侧 map ≡ CHECK DDL）

```
后端词表  : [news, tech, business, science, sports, culture, entertainment,
             health, education, history, law, family]        (12)
端侧 map  : 同上                                              (12)  ✅ 集合相等
CHECK DDL : 同上                                              (12)  ✅ 集合相等
```

### 6.3 源覆盖（12 类全部有源）

```
news 5 · tech 4 · business 1 · science 3 · sports 1 · culture 3
entertainment 1 · health 2 · education 1 · history 1 · law 1 · family 1
无源覆盖的类: 无 ✅      词表外的类: 无 ✅
```

### 6.4 证伪（确认断言真会红，而非恒真）

| # | 注入 | 结果 |
|---|---|---|
| ① | 从 `CHECK` 里删掉 `'education'` | ✅ 独立断言报红，**并直接指出「缺 classification `education`」** |
| ② | 把 `NPR Education` 的 category 改成 `'edu'` | ✅ **`INSERT OR IGNORE` 静默吞掉** ⇒ 源少一行 ⇒ 数量断言报红（22≠23 · 23≠24）|

**证伪 ② 的价值**：它**证明了「静默丢源」确实会发生**，也证明了断言能抓到
—— 这条链正是 §5.1 里那三条事实的实证。

---

## 七、部署时会发生什么

`INSERT OR IGNORE`（幂等）⇒ 部署后下一轮抓取：

1. **自动插入 10 个新源**（id 15–24）并开始抓取
2. 存量新增约 **10 源 × ~40 条/天**（NPR 频道节奏）⇒ 内容池日增翻倍
3. **30 天保留期**同时生效（`prune_old_content`）
4. 生产库**无 CHECK** ⇒ 插入不受限（见 §5.1）

⚠️ 与二轮合计：**部署一次会同时插入 19 个 NPR 源 + arXiv**（二轮 9 + 三轮 10）。

---

## 八、遗留 / 待白哥定

1. 🔴 **部署**（未动）—— 会一次性插入全部新源并开始抓
2. 🟡 **是否重建 `content_source` 表**以让生产库也获得 CHECK（见 §5.1，需 DDL 迁移）
3. ⏳ **「跨类编辑栏目」若要接**（`Opinion`/`Analysis`/`Perspective`/`Obituaries`/
   `Race`/`On Disabilities`）—— 它们**不应是 `category`**，而应是另一个维度
   （如「视角 / 观点」标签）。**要不要引入这个维度，是产品决定**。
4. ⏳ 上轮遗留：ESPN NFL / NPR Pop Culture 备选 · 存量许可复核（Dev.to / HN）
