# 候选内容源评估（2026-10-02）

> **给白哥** · 起因：废弃 Ars Technica 后要补一个 tech 源，白哥要求「**三个源都测可达性和抓取质量再选择**」。
>
> 🔴 **本文所有数字都在本机用后端真实代码实测**（`examples/eval_candidate_sources.rs`）——
> 走的是 `fetch_source_items`（真 RSS 解析）+ `fetch_article_body_diagnostic`（真 `dom_smoothie` 提取），
> **不是 Python 粗模拟**。原因见 §五（上一轮就是栽在「用 Python 模拟」上）。
>
> 📄 上游 → [`content-source-inventory-and-interests-2026-10-02.md`](content-source-inventory-and-interests-2026-10-02.md) §九（Ars 废弃）

---

## 一、结论速览

| 源 | 格式 | 条目 | 全文从哪来 | 营销/软文 | 预期日增 | 结论 |
|---|---|---|---|---|---|---|
| **Wired** | RSS 2.0 | 50 | 抓网页 | 🔴 **42%** | ~102 | ❌ **不推荐**（营销页污染）|
| **Lobsters** | RSS 2.0 | 25 | 抓网页（**外链**）| 0% | ~75 | ⚠️ **可用但有三个隐患** |
| **Simon Willison** | 🔴 **Atom** | 30 | `<summary>` 即全文 | 0% | — | ❌ **当前不可用**（后端不解析 Atom）|
| **HackerNoon** | RSS 2.0 | 20 | ✅ **RSS 自带全文** | 5% | ~48 | ⭐ **推荐**（零抓取成本）|
| **Smashing** | RSS 2.0 | 40 | ✅ RSS 自带全文 | 🔴 20% | 🔴 **~0.4** | ❌ 不推荐（内容不新）|
| **TechCrunch** | RSS 2.0 | 20 | 抓网页 | 0% | ~50 | ✅ 备选（纯新闻）|
| *NPR（对照）* | RSS 2.0 | 10 | 抓网页 | 0% | ~35 | 基准 |

**一句话**：白哥点的三个里，**Wired 有 42% 是优惠码页、Lobsters 的内容来自 21 个不同个人博客（版权不可控）、Simon Willison 是 Atom（后端解析不了）**。
反倒是**顺带测的 HackerNoon** 最合适 —— 它的 RSS **直接给 1613 词的全文**，我们**不用抓网页**。

---

## 二、逐源详测

### 2.1 Wired ❌ 不推荐：**42% 是营销页**

| 项 | 实测 |
|---|---|
| RSS | RSS 2.0 · **50 条** · 2341 ms |
| 内容构成 | 📰 真新闻 **20** · 🛍 导购评测 **9** · 🛒 **优惠码页 21** |
| RSS 给全文 | ❌ 0 条（仅 24 词摘要）|
| 网页提取 | 7/8 成功 · 7 篇 ≥300 词 · 5 篇句末完整 |

🔴 **优惠码页的样子**（21 条，全在 `/story/` 下，**与真新闻同路径**）：

```
https://www.wired.com/story/columbia-promo-code/
https://www.wired.com/story/uber-eats-promo-code/
https://www.wired.com/story/nike-promo-code/
https://www.wired.com/story/wayfair-promo-code/
https://www.wired.com/story/att-promo-code/
…（共 21 条）
```

⇒ **URL 无法区分**（都在 `/story/`），只能靠**标题关键词**过滤（`promo code` / `coupon` / `% off`）。

⚠️ **即使过滤掉优惠码页，仍有残留问题**：正文尾部会混入推广区块。实测一条导购文的尾部：

```
…Commerce_AFFILIATE_ZZ)\.*
Read More
## Wired Coupons          ← 🔴 站内推广区块被提取进正文
```

📌 **判断**：营销页对「学英语」**零价值**（内容是重复的优惠码模板）。
   要使用必须**新增一层标题过滤**，且以后 Wired 换形态还要再维护 —— **性价比低**。

### 2.2 Lobsters ⚠️ 可用，但三个隐患

| 项 | 实测 |
|---|---|
| RSS | RSS 2.0 · **25 条** · 1985 ms |
| 内容构成 | 📰 25 · 营销 0 ✅ |
| RSS 给全文 | ❌ 0 条 · **摘要中位 1 词**（就是「Comments」链接）|
| 网页提取 | **8/8 成功** · 6 篇 ≥300 词 · 6 篇句末完整 |

**表面很好**（零营销、抓取 8/8），但有三个必须先知道的问题：

#### 隐患 ①：它是**链接聚合站**，内容来自 21 个不同域名

```
🔗 blog.gitbutler.com      🔗 blog.rust-lang.org (×2)   🔗 www.waterfox.com
🔗 www.oliverdunk.com      🔗 amoffat.github.io          🔗 discourse.imfreedom.org
🔗 molily.de               🔗 write.as                   🔗 storyteller-platform.dev
🔗 github.com              🔗 blog.cryptographyengineering.com
🔗 rahuljuliato.com        🔗 blogs.windows.com          🔗 sm2n.ca
🔗 con.racket-lang.org     🔗 nikolan.net                🔗 loige.co
🔗 ploum.net               🔗 www.gimp.org               🔗 verdagon.dev
🔗 grim.cargocut.org       + 🏠 lobste.rs 站内 3 条
⇒ 25 条来自 21 个不同域名
```

🔴 **版权不可控**：我们抓的是**个人博客**的全文，每个站点的许可各自不同（有的没声明）。
   而 `content_source` 表的 `license` / `redistributable` 是**按源配置**的 ——
   **一个源里混 21 种许可，配置列无法表达**。
   （对照：NPR / Wired 是大媒体，授权政策明确。）

⚠️ **抓取稳定性**：21 个域名 = 21 个抓取目标，各自有不同的反爬/结构。
   本轮 8/8 成功可能是**单轮幸运**（对照 TechCrunch 同样抓网页，本轮 2/8 失败）。

#### 隐患 ②：RSS **没有摘要**（中位 1 词）

⇒ 抓网页失败的条目会退化成「**只有标题**」（比 Ars 更糟 —— Ars 至少有 161 词片段兜底）。

#### 隐患 ③：站内有**非文章内容**

`What are you doing this weekend?` / `Who's hiring? Q4 2026` —— 论坛帖，不是文章。
（实测抓出来只有 194 词）

📌 **判断**：技术社区质量其实不错（Rust 官方博客 / GIMP 访谈 / 密码学博客），
   但**版权不可控**这一条对「要上架 App Store 且要再分发内容」的产品是**硬伤**。

### 2.3 Simon Willison ❌ 当前不可用（Atom）

```
🔴 RSS 失败: 不是 RSS 2.0 文档（根元素是 `feed`）—— Atom 需另写适配器
```

**这是结构性阻断**：后端 `parse_rss` 只认 RSS 2.0（`Cargo.toml` 里已写明这个约束）。

⚠️ **但内容质量很高** —— 实测 30 条，全文在 `<summary>` 里：

| # | 标题 | 长度 |
|---|---|---|
| 9 | 2026 in LLMs (so far) | **73,103 字符** |
| 12 | Kākāpō Party | 7,692 字符 |
| 6 | Claude Sonnet 5.5 | 2,676 字符 |

📌 **它有 RSS 出口吗？** 实测 `/feed/` 与 `/rss/` 都 **404**，只有 Atom。
   ⇒ 要用必须**引 `feed-rs`（或写 Atom 适配器）**，这是一次性成本，之后这个源免费。
   ⚠️ 但也要注意：它是**个人博客**（同 Lobsters 隐患①的版权问题），只是单一来源、可控些。

### 2.4 🆕 HackerNoon ⭐ 推荐：RSS 自带全文

| 项 | 实测 |
|---|---|
| RSS | RSS 2.0 · **20 条** · 3423 ms |
| 内容构成 | 📰 19 · 导购 1 · 营销 **0** |
| **RSS 给全文** | ✅ **20/20 条，词数中位 1613**（范围 474–4729）|
| 网页提取 | ⏭️ **不需要** —— RSS 已给全文 |
| 句末完整 | 70%（剥 CDATA 后实测）|
| 🔴 软文 | **1/20（5%）** —— 尾部标注 `published as a press release by BlockmanPR` |
| **更新频率** | **20 条分布在 0.4 天内 ⇒ 每 6h 约 11.9 条新增（≈48 条/天）** |

🔑 **为什么它最优**：**RSS 直接给全文 ⇒ 零抓取**。这消除了三条风险链：
1. 抓取失败（对照 TechCrunch 本轮 2/8 失败）
2. 提取噪音（对照 Wired/TechCrunch 正文尾部混入 `## Related` / `## Wired Coupons`）
3. 反爬（对照 Ars 文章页 405）

⚠️ **一个需要标注的点**：HackerNoon 是 **UGC 技术博客平台**（与现有 Dev.to 同质）。
   ⇒ 它会让「tech 类占比」**上升**，而白哥反映过「大部分都是技术文章」。

### 2.5 Smashing ❌ 不推荐：**内容不新**

| 项 | 实测 |
|---|---|
| RSS | RSS 2.0 · 40 条 · 1988 ms |
| RSS 给全文 | ✅ 39/40 · 词数中位 **2550**（最长的源）|
| 句末完整 | 75% ✅ |
| 🔴 软文 | **8/40（20%）** |
| 🔴 **更新频率** | **40 条分布跨度 156 天**（最新 09-30，最旧 04-27）⇒ **每 6h 约 0.1 条** |

⇒ **内容是「长期精选存档」而非最新批次** —— 抓一轮就到底了，之后**无新增**。
   作为「每天有新内容」的订阅价值来源（这是订阅正当性的支柱），它**不满足**。

### 2.6 TechCrunch ✅ 备选

| 项 | 实测 |
|---|---|
| RSS | RSS 2.0 · 20 条 · 1383 ms · 营销 **0** |
| 网页提取 | **6/8 成功**（2 次「请求失败」）· 5 篇 ≥300 词 · 4 篇句末完整 |
| 尾部噪音 | ⚠️ 有 `Subscribe for the industry's biggest tech news` + `## Related` + `## Latest in Startups` |

⇒ 纯科技新闻、无营销污染，但**要抓网页**（有失败率）且**正文尾部有站内导航噪音**。

---

## 三、🆕 新增判据：评估内容源必须查「**营销内容占比**」

这一条是本轮**新发现**的（前几轮都没查过）：

| 源 | 营销/软文占比 | 形态 |
|---|---|---|
| Wired | 🔴 **42%** | 优惠码页（标题含 `promo code` / `coupon` / `% off`）|
| Smashing | 🔴 **20%** | 正文尾部含 `sponsored` / 广告标记 |
| HackerNoon | 5% | 尾部 `published as a press release by …` |
| ECNS / NPR / TechCrunch / Lobsters | 0% | — |

**为什么必须查**：它们**不是片段**（词数够长）、**不是错误**（HTTP 200），
所以前面的判据（可达性 / 词数 / 句末完整）**全都查不出来**。
只有**看标题**或**看正文里的标注**才能发现。

**检测方法**（两条独立信号）：
1. **标题关键词**：`promo code` / `coupon` / `% off` / `deal` / `sponsored`
2. **正文尾部标注**：`press release` / `sponsored` / `advertisement` / `business blogging program`

⚠️ 但⚠️：**标题过滤会漏**（HackerNoon 那条软文标题看着完全正常）。
   ⇒ 两条都要查，且必须**抽查正文尾部**（判据：机械判据只能到候选）。

---

## 四、推荐方案

### 4.1 首选：**HackerNoon**

| 理由 | 数据 |
|---|---|
| **零抓取成本** | RSS 自带 1613 词全文 ⇒ 不抓网页 ⇒ 无失败/无噪音/无反爬 |
| **内容新鲜** | 每 6h 约 11.9 条（≈48 条/天），远超 Ars 的 6–27 条/天 |
| **营销污染低** | 5%（vs Wired 42%）|
| **接入成本** | 一行 seed 插入（RSS 2.0，后端已支持）|

⚠️ **一个要白哥拍板的点**：它会**加剧偏技术**（与 Dev.to 同质）。
   Ars 本来就是 tech 源 ⇒ 这是**同类别替换**，比例不至于恶化；但**不会改善**。

### 4.2 备选：**TechCrunch**（若要「新闻感」更强的 tech）

优点：纯新闻、零营销；缺点：要抓网页（本轮 2/8 失败）、尾部有导航噪音。

### 4.3 若要「不加剧偏技术」→ 建议**加 NPR 分频道**（纯配置，零代码）

实测可达的 6 个频道（见上游报告 §七）：

```
feeds.npr.org/1006 商业 · 1007 科学 · 1008 文化
             1019 科技 · 1128 健康 · 1004 国际
```

⇒ **一条 seed 就能把兴趣领域从 2 类扩到 7 类**，且 NPR 是**唯一 100% 全文**的源（本对照 7/8 成功）。

### 4.4 Simon Willison：**建议记录为「待评估」**

内容质量高（73k 字符的 LLM 年度综述），但：
1. 需先支持 Atom（一次性成本）
2. 是个人博客（版权）

⇒ **除非白哥明确想要它的内容**，否则不急着做。

### 4.5 ❌ 不推荐

- **Wired**：42% 营销页 + 需新增过滤层 + 以后要维护
- **Smashing**：内容跨度 156 天（无持续新增）
- **Lobsters**：21 个域名的版权不可控（`redistributable` 列无法表达）

---

## 五、方法学（本轮踩到的坑）

### 5.1 🔴 用真实代码评估，不用 Python 模拟

上一轮我用 Python 分析 Ars 的 `<description>`，把 **CDATA 内容一起剥掉了**，
得出「description 是空的」——**而真相是 14 词导读**。工具错导致反向结论。

⇒ 本轮改用 `examples/eval_candidate_sources.rs`，走**后端真实函数**。
   📌 判据：**评估「能不能用」必须走真实那条路径** —— 自己复刻一遍就是引入一个新的偏差源。

### 5.2 🔴 「句末完整」判据漏了 CDATA ⇒ 假 0%

第一版判据报 HackerNoon / Smashing **句末完整 0%**（与 Ars 的 0/33 一模一样，很容易误判成「同一类问题」）。
查实际尾部才发现是 **`]]>` 后缀**没剥 ⇒ 修正后是 **70% / 75%**。

📌 判据：**判据报出「异常值」时，先看原始数据长什么样**（判据「机械判据只能到候选」）。
   `0%` 这种极端值尤其可疑 —— 它更可能是**判据坏了**，而不是数据全坏。

### 5.3 🔴 单轮样本的局限（如实标注）

本轮每源抽 **8 篇**测网页提取。样本小，**「8/8 成功」不能推断「长期 100% 成功」**。
⇒ 建议：定选后**先跑一周观察抓取成功率**，再决定是否加大投入。
   （对照数据：NPR 本轮 8/8，但历史库里 HN 有 **33% 抓不到** —— 同一个源不同时段差异很大。）

### 5.4 判据汇总（本轮新增/强化）

| 判据 | 来源 |
|---|---|
| 🆕 **查「营销内容占比」**（标题 + 正文尾部双信号）| Wired 42% |
| 🆕 **查「内容更新频率」**（pubDate 跨度）| Smashing 156 天跨度 |
| ⭐ **「RSS 给全文」是最有价值的属性**（消除三条风险链）| HackerNoon |
| 🔴 **聚合站要查「域名分散度」**（版权可控性）| Lobsters 21 域名 |
| 🔴 **格式要实测**（RSS vs Atom 决定能否直接接入）| Simon Willison |
| 🔴 评估必须走**真实代码路径** | §5.1 |
| 🔴 判据报极端值先查原始数据 | §5.2 |

---

## 六、复现方式

```bash
cd backend
cargo run -q -p api_server --example eval_candidate_sources
```

工具在 `backend/crates/api_server/examples/eval_candidate_sources.rs`：
改 `CANDIDATES` 数组即可加源，改 `SAMPLE_PER_SOURCE` 调样本量。
输出含：RSS 可达性 / 内容构成（含营销占比）/ 网页提取成功率 / 词数 / 句末完整率。
