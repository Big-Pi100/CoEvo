# `sports` / `entertainment` 补源（2026-10-02 二轮）

> **给白哥** · 起因：受控词表的 8 个分类里，`sports` / `entertainment` **一直没有源**
> —— 即定稿 §10.3.1 担心的「用户勾了这三个标签却拉不到内容」里剩下的两个
> （`culture` 已在首轮由 `NPR Culture` 补齐）。
>
> 白哥指令：「sports / entertainment 要补源」。
>
> 🔴 **本文所有数字都在本机用后端真实代码实测**（`examples/eval_candidate_sources.rs`，
> 走真 `fetch_source_items` + `fetch_article_body_diagnostic`），**不是 Python 粗模拟**。
>
> 📄 上游 → [`source-onboarding-2026-10-02.md`](source-onboarding-2026-10-02.md)（首轮 8 源接入）
> · [`candidate-source-evaluation-2026-10-02.md`](candidate-source-evaluation-2026-10-02.md)（评估工具与判据）

---

## 一、结论速览

| 源 | 类 | RSS 条数 | 营销 | 网页提取 ≥300 词 | 句末完整 | 预期日增 | 结论 |
|---|---|---|---|---|---|---|---|
| **NPR Sports** | sports | 10 | 0 | **3/4** | **4/4** | ~30 | ✅ **接入** |
| **NPR Movies** | entertainment | 10 | 0 | **4/4** | 3/4 | ~40 | ✅ **接入** |
| *NPR News（对照）* | news | 10 | 0 | 4/4 | 2/4 | ~40 | 基准 |
| NPR Pop Culture | entertainment | 10 | 0 | 4/4 | 3/4 | ~40 | ⏳ 备选（未接）|
| ESPN NFL | sports | **31** | 0 | 4/4 | 3/4 | **~124** | ⏳ 备选（未接）|
| Variety | entertainment | 10 | 0 | 4/4 | 4/4 | ~40 | ❌ 不接（不同媒体 → 新许可判断）|
| Hollywood Reporter | entertainment | 10 | 0 | 4/4 | 4/4 | ~40 | ❌ 不接（同上）|
| CBS Sports | sports | — | — | — | — | — | 🔴 **reqwest 请求失败**（curl 200）|

**一句话**：两个类都用 **NPR 分频道**补齐 —— 与已接入的 `NPR News`(id=1) **同一媒体**，
`license` / `redistributable` **逐字相同** ⇒ **零新增合规风险**，且是**纯配置**（无代码、无新 `kind`）。
非 NPR 候选里 ESPN 量最大但摘要只有 **20 词**（NPR 32 词），暂不接。

接入后 **受控词表的 8 类全部有源覆盖**。

---

## 二、逐源详测

### 2.1 ✅ NPR Sports `feeds.npr.org/1055` —— 接入

```
① RSS: 10 条 · 606 ms · 营销 0 · 摘要中位 32 词（18–38）
② 网页提取 4 篇（真实 dom_smoothie）:
   ✅   139 词 · 句末完整 · What's next for the Premier League after Manch…
   ✅   567 词 · 句末完整 · The White Sox say their fan in the Vatican may…
   ✅   907 词 · 句末完整 · How WNBA star Gabby Williams carries her $1 bi…
   ✅   705 词 · 句末完整 · The Senate passes the Protect College Sports A…
   → 成功 4 · ≥300 词 3 篇 · 句末完整 4 篇 · 失败 0
```

**覆盖面好**：一轮同时出现英超 / MLB / WNBA / 大学体育 + 体育立法
（对照 ESPN NFL **只覆盖 NFL**）。139 词那篇是短讯，属正常波动。

### 2.2 ✅ NPR Movies `feeds.npr.org/1045` —— 接入

```
① RSS: 10 条 · 2566 ms · 营销 0 · 摘要中位 29 词（15–34）
② 网页提取 4 篇:
   ✅   906 词 · 句末完整 · John Wilson's revenge against Hollywood? A doc…
   ✅  1250 词 · 句末🔴截断 · Kyle MacLachlan says he was David Lynch's 'sub…
   ✅  2099 词 · 句末完整 · Cineplexity: Blade Runner is a classic. Does t…
   ✅  1114 词 · 句末完整 · 'To Catch a Predator' drama 'Primetime' brings…
   → 成功 4 · ≥300 词 4 篇 · 句末完整 3 篇 · 失败 0
```

⚠️ **那 1 篇「截断」不是真截断** —— 尾部是播客制作人署名
（`…Bridget Bentz, Molly Seavy-Nesper and Beth Novey adapted it for the web.*`），
即**内容已完，只是末尾不是句末标点**。同类现象在对照的 `NPR News` 上也有
（`…fact-checked by Sierra Juarez edited by Kate Concannon.`）。

📌 这印证了判据库里那条：**「句末完整」是探针，不是结论** ——
   报出异常值时要**看尾部原始内容**再定性（这里是「署名尾巴」，不是「半句话」）。

### 2.3 ⏳ ESPN NFL `espn.com/espn/rss/nfl/news` —— 未接（备选）

```
① RSS: 31 条 · 1233 ms · 营销 0 · 摘要中位 20 词（13–34）
② 网页提取 4 篇: 2245(截断) / 868 / 875 / 599 词 → 4/4 达标 · 句末完整 3/4
```

**优点**：量最大（31 条/轮 ≈ **124 条/天**，是 NPR Sports 的 4 倍）。
**不接的理由**（如实列出，供白哥后续决定）：

1. **摘要太短**（中位 20 词）—— 抓网页失败时退化成「几乎只有标题」，
   比 NPR（32 词）更糟
2. **尾部粘作者列表**（`…Eric Woodyard*`）—— 2245 词那篇是多人署名稿
3. **不同媒体 = 新的许可判断**（NPR 那条「同条款」红利消失）
4. 白哥要的是「**补源**」不是「最大量」；NPR Sports 30 条/天对「每日有更新」够用

📌 **若将来觉得 sports 内容偏少，ESPN 是第一个该加的**（数据已实测，加它只是一行 seed）。

### 2.4 ⏳ NPR Pop Culture `feeds.npr.org/1048` —— 未接（备选）

```
① RSS: 10 条 · 1578 ms · 营销 0 · 摘要中位 26 词
② 网页提取 4 篇: 676 / 345(截断) / 321 / 1734 词 → 4/4 达标 · 句末完整 3/4
```

质量与 Movies 同档。**不接**是因为 `entertainment` 已被 Movies 覆盖，
再挂一个会让「同一类两个源」——白哥此前表态过「**内容不要太多**」。
📌 若觉得 entertainment 只有电影太窄，它是现成的第二源。

### 2.5 ❌ Variety / Hollywood Reporter —— 不接

| | Variety | Hollywood Reporter |
|---|---|---|
| RSS | 10 条 · 摘要中位 **56 词** | 10 条 · 摘要中位 24 词 |
| 网页提取 | 4/4 达标 · **句末完整 4/4** | 4/4 达标 · **句末完整 4/4** |

技术上是**本批质量最好的两个**（句末完整 100%）。不接的**唯一**理由：
**它们是 NPR 之外的独立主体** ⇒ 需要**单独**的许可判断与 `license` 取值，
而 `entertainment` 已由 NPR Movies 覆盖 ⇒ **无增量收益时不该引入新的合规面**。

### 2.6 🔴 CBS Sports —— **curl 200 但 reqwest 请求失败**

| 工具 | 结果 |
|---|---|
| `curl`（本机，UA=CoEvoBot） | **200** · text/xml · 25659 字节 |
| `reqwest`（后端真实实现） | 🔴 `请求失败 … error sending request for url` |

**这与 Ars Technica 那次的病同源**（文章页对两种 UA 都返回 405）——
**同一 URL 在两个 HTTP 客户端下结果不同**。
⇒ 📌 判据：**候选源可达性必须用「生产同款客户端」验**，
   `curl` 只能用来**初筛**（本轮正是靠它把 18 个 URL 缩到 7 个），**不能当结论**。

### 2.7 ❌ 已实测不可达（本轮排除，记档以免重复调研）

| 源 | 结果 |
|---|---|
| The Guardian Sport · BBC Sport · Sky Sports · Deadline · NBC News | 🔴 502（CONNECT tunnel failed）|
| Bleacher Report · EW · AP News · Yahoo Sports | 🔴 403 |
| Sports Illustrated · Vulture · IGN | 🔴 404 |
| **`espn.com/espn/rss/news`（主频道）** | ⚠️ **HTTP 200 但内容已改版为 HTML**（非 RSS）⇒ 只有 `/espn/rss/<league>/news` 子频道还是 XML |

---

## 三、🆕 本轮新增判据

| 判据 | 触发它的事实 |
|---|---|
| 🔴 **`curl` 可达 ≠ `reqwest` 可达** —— 候选源必须用**生产同款客户端**终验 | CBS Sports：curl 200 / reqwest 失败 |
| 🔴 **feed ID → 频道名必须由 `<title>` 确认**，不能凭「这家有那个频道」推断 | 据记忆直接请求 `1045` 得到**空 body**，差点误判「频道不存在」；并发重扫 ID 段才确认 |
| 🔑 **「HTTP 200」不等于「内容是 RSS」** —— 要看去向的 `content_type` / 根元素 | `espn.com/espn/rss/news` 返回 HTML 页 |
| 🔑 **「句末完整」报异常时先看尾部** —— 署名/制作人名单不是截断 | NPR Movies 1250 词那篇 |
| 🔑 **断言口径：集合相等 > 逐类 contains** | 本轮把分类覆盖断言从枚举 6 项改成与 `CONTENT_CATEGORIES` 逐值比对 |

---

## 四、改动清单

| 文件 | 改动 |
|---|---|
| `backend/crates/api_server/src/schema.rs` | seed 新增 **id 13 `NPR Sports 体育`**（`sports`）· **id 14 `NPR Movies 影视`**（`entertainment`）；`CONTENT_CATEGORIES` 上方注释由「尚未补源」改为「已补源 + ID 是抓 title 确认的」 |
| `backend/crates/api_server/src/content_fetch.rs` | `test_seed_sources_are_loaded`：启用源 **11→13** · 表总行 **12→14** · NPR 源 **7→9** · 分类覆盖断言改**集合相等** |
| `backend/crates/api_server/src/schema.rs`（测试） | seed 总行断言 **12→14**；**顺带更正**注释里「启用 12 / 总行 13」的**基数错误**（原与 `content_fetch` 的 11/12 差 1）|
| `app/lib/models/feed_item.dart` | `_categoryLabels` 注释由「sports/entertainment 没有源」改为「8 类全部有源」（**词表 key 未变**，无需改映射）|

⚠️ **前端无需改代码** —— `_categoryLabels` 本就含 `sports` / `entertainment`（首轮收敛时已同步），
本次只是注释与事实对齐。跨语言一致性断言（`verify_feed_wiring.dart`【9】）**不受影响**。

### 🔴 部署时会发生什么（不是「只加两行」）

新 seed 用的是 `INSERT OR IGNORE`（幂等）⇒ 部署后**下一次抓取**会：
1. **自动插入 id 13/14 两个源**并开始抓取（`content_source` 是配置表，无需迁移）
2. 同时首轮的 6 个 NPR 分频道 + arXiv 也会开始抓（若尚未部署）
3. **30 天保留期**同时生效（`prune_old_content`）

---

## 五、验证

- `cargo test -p api_server`：全部通过（含上述 4 处断言）
- **证伪**（确认断言真的会红，而不是恒真）：
  - 把 `NPR Movies` 的 `category` 改成 `sports` → 分类覆盖断言（集合相等）**必须报红**
    （`cats` 缺 `entertainment`，且 `expected_cats` 多一个）
  - 删掉 id 14 一行 → **启用源数（13）与表总行（14）两条同时报红**
- 前端：`_categoryLabels` 未改动 ⇒ `verify_feed_wiring.dart`【9】不受影响

## 六、复现方式

```bash
cd backend
cargo run -q -p api_server --example eval_candidate_sources
```

改 `examples/eval_candidate_sources.rs` 的 `CANDIDATES` 数组即可换候选源。

---

## 七、遗留（供白哥决定）

1. **ESPN NFL**（~124 条/天）—— 若嫌 sports 内容少，加它是一行 seed（数据已实测）
2. **NPR Pop Culture** —— 若嫌 entertainment 只有电影太窄，同上
3. Variety / Hollywood Reporter —— 要接需**单独做许可判断**
4. 存量许可复核（Dev.to / HN）—— 原建议进上架前检查项（**不受本轮影响**）
