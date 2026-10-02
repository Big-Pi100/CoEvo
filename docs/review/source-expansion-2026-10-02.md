# 源扩展实测：arXiv / Product Hunt / 创业故事 / 公版书（2026-10-02）

> **白哥定的口径**（本轮的前提，改变了整个判断框架）：
> 1. **质量优先** —— 「可达性差、内容质量差就**直接放弃**」（我们做的是学习工具，不是媒体）
> 2. **内容量不是问题** —— 会兼容电子书，**找到可用的公版图书源即可解决大部分内容问题**
>
> 🔴 **所有数据在 VPS（生产环境）实测**。本机结论**不可替代** —— 本轮再次验证：
> **Project Gutenberg 本机完全不可达（HTTP 000），但 VPS 上可达（200）**。
>
> 📄 上游 → [`content-source-inventory-and-interests-2026-10-02.md`](content-source-inventory-and-interests-2026-10-02.md) · [`candidate-source-evaluation-2026-10-02.md`](candidate-source-evaluation-2026-10-02.md)
> 🔧 工具 → `backend/crates/api_server/examples/eval_candidate_sources.rs`

---

## 一、结论速览

| 源 | 可达性 | 内容质量实测 | 结论 |
|---|---|---|---|
| **arXiv** | ✅ 全分类 200 | abstract 中位 **202 词** · **句末完整 100%** · `/html/` 全文 **9992 词**（覆盖 **93%**）| ⭐ **推荐接入** |
| **Product Hunt 官方** | 🔴 **403** | — | ❌ **放弃** |
| ├ Sidehunt（PH 替代）| ✅ 200 | 🔴 `description` **全空** · 仅 12 条产品名 | ❌ 放弃 |
| └ WhatLaunched（PH 替代）| ✅ 200 | 🟡 产品营销描述（≤2000 字符）| ❌ 放弃 |
| **Starter Story** | ✅ 200 | 🔴 dom_smoothie 提取仅 **289 字符**（JS 渲染的数据档案页）| ❌ **放弃** |
| 🆕 **Failory**（同族发现）| ✅ 200 | ✅ **1723 词 · 句末完整**（真叙事长文）| 🟡 **可用但要新增 kind** |
| **Project Gutenberg** | ✅ **VPS 可达** | ✅ 单本 **130,416 词**（傲慢与偏见）· epub/txt 可下 | ⭐ **公版书主路径** |
| Standard Ebooks | 🟡 主页 200 · feed **401** | 未细测 | 🟡 备选 |
| archive.org / Open Library / Gutendex | 🔴 **VPS 也 000** | — | ❌ 放弃 |

---

## 二、白哥提的三项 —— 逐项实测

### 2.1 Product Hunt ❌ **不可用，且 vibedollar 早就知道**

**实测（两种 UA、本机 + VPS 四次）**：

```
https://www.producthunt.com/    CoEvo-UA=403   Browser-UA=403
VPS 上同样 403（5495 B 错误页）
```

**vibedollar 的代码里已经标注了这一条**（`case_sources/sidehunt_provider.py:6-7`）：

> Product Hunt (冷门②) **403 (Cloudflare 拦 — 数据源受阻, 标注不可用)**

vibedollar 的应对是**用两个镜像站替代** —— 我实测了它们：

| 替代 | 可达 | 抓到什么 | 能用吗 |
|---|---|---|---|
| **Sidehunt** | 200 | 12 条，`description` **是空字符串** | ❌ 连描述都没有 |
| **WhatLaunched** | 200 | 45 条，JSON-LD `SoftwareApplication.description` | 🟡 是**产品营销文案**（≤2000 字符），不是文章 |

📌 **判断**：Product Hunt 这条线**整体放弃**。
   即使绕过 403（用镜像），拿到的也是**产品营销描述** —— 短、是广告、无文章结构。
   与「学英语」的目标不匹配，且**每周要维护镜像站的解析**。

### 2.2 创业故事（"start story"）❌ **已改版成 AI 档案页**

vibedollar 有 `case_sources/starterstory_provider.py`（296 行），抓 `starterstory.com/businesses/{slug}` 的六区块（Overview / Revenue / Monetization / Growth / Founders / Tools）。

**实测（dom_smoothie 真实提取）**：

```
https://www.starterstory.com/businesses/accelevents
  🟡 太短: 289 字符   ← 提取不到正文（阈值 300）
```

**页面自述**（实测 HTML 里）：

> **Researched profile. Starter Story's AI research system compiled this page from 49 public sources**

⇒ 它已经不是「创始人访谈文章」，而是**结构化数据档案页**（JS 渲染）。
   vibedollar 抓到的产物也证明了这点 —— `knowledge/cases/accelevents.yaml`：

```yaml
founder: { name: Jonathan Kazarian, background: '' }
business: { revenue_mrr: 850000 }
acquisition: { primary: Word of mouth / Direct sales / Outbound }
```

⇒ **营收数字、变现标签、创始人名字** —— 这些对「提取创业数据」有用（vibedollar 的目标），
   **对「读英语文章」零价值**。

📌 **判断**：**放弃**。理由：内容是**数据**不是**文本**。

#### 🆕 但同族里发现一个真能用的：**Failory**

vibedollar 也在用它（`failory_provider.py`，创始人访谈叙事）。我实测了**文章页**：

| 项 | 实测 |
|---|---|
| URL | `https://www.failory.com/interview/basetemplates` |
| dom_smoothie 提取 | ✅ **1723 词 · 句末完整 · 达标** |
| 内容形态 | ✅ 真叙事（`In 2019, Maximilian acquired BaseTemplates, a website selling pitch deck templates. Through content and free tools…`）|
| **RSS** | 🔴 **无** —— `/feed` `/rss` `/interviews/feed` 全 **404**，只有 `sitemap.xml` |

⚠️ **两个待确认点**：
1. **要接入必须新增一种 `kind`**（后端现在只有 `rss` | `hn`）—— 这是**改代码**，不是配置
2. **时效性存疑** —— 我抓的那篇发布于 **2022-05-05**（页面上的日期）。`failory_interviews.json` 里也只有 **3 条**。
   若它更新很慢，「每天有新内容」的订阅价值基础就不成立（同 Smashing 的问题）

📌 **判断**：**先记录，不接**。除非白哥明确想要「创业故事」这个题材。

### 2.3 arXiv ⭐ **推荐接入**

#### 可达性（VPS 实测）

| 分类 | 条目 | HTTP |
|---|---|---|
| **cs.AI** | **561** | 200 |
| **cs.LG** | **621** | 200 |
| **cs.CL**（NLP，最贴「语言」）| **269** | 200 |
| cs.SE（软件工程）| 46 | 200 |
| stat.ML | 90 | 200 |
| econ.EM（经济）| 10 | 200 |

RSS 是标准的 **RSS 2.0**（`<rss>` 根元素）⇒ **后端 `parse_rss` 能直接解析**（实测 269 条全过）。

⚠️ 一次实测里 cs.AI 出现过一次 `error sending request`（VPS 单测 200）⇒ **偶发抖动**，不只是 arXiv 的问题。

#### 内容质量

**① RSS 里的 abstract**（直接可用，零抓取）：

```
条目 269 · abstract 中位 202 词（范围 101–334）
🔑 句末完整 8/8 = 100%     ← 远好于其他源
```

对比（同一判据）：
| 源 | 句末完整率 |
|---|---|
| **arXiv** | ✅ **100%** |
| HackerNoon | 70% |
| Smashing | 75% |
| Wired | 62% |
| **Ars Technica**（已废弃）| 🔴 **0%** |

⇒ arXiv 的 abstract **本身就是完整的一段学术摘要**，不是被截断的片段。

**② `/html/` 全文版**（arXiv 近年提供）：

```
覆盖率: 14/15 = 93%   （抽 15 篇实测）
dom_smoothie 提取: 9,992 词 · 句末完整
```

🔑 **全文的 URL 形态**：`https://arxiv.org/html/{id}v1`（从 abs 页的链接里拿）
   - `abs` 页 → 269 词（只有摘要 + 元数据）
   - `/html/` 页 → **9,992 词**（真全文）

⚠️ **但提取质量有瑕疵**：尾部出现 LaTeX 残留（`\hat\{\alpha\}`）——
   公式、符号、参考文献在 Markdown 里会以源码形式出现。

#### 📌 判断与使用建议

**推荐接入，但建议只用 RSS 的 abstract（不抓 `/html/`）**：

| 方案 | 内容 | 优点 | 缺点 |
|---|---|---|---|
| **A（倾向）** | 只用 RSS abstract（202 词）| 零抓取 · 零噪音 · 100% 完整 · 568 条/天 | 短（<300 词阈值）|
| B | 抓 `/html/` 全文 | 9992 词长文 | 93% 覆盖 · **LaTeX 残留** · 每篇 10–30 s |

⚠️ **语域问题（需白哥判断，不是技术问题）**：arXiv 是**学术英语**（C1+），
   术语密集、句法复杂。对「学英语」来说是**高难度但高质量的真实语料**。
   我们的分级系统可以标 `C1`，但它是否适合目标用户，是**产品决定**。

⚠️ **量的问题**：cs.AI+cs.LG+cs.CL 每天合计 **1400+ 条** —— 远超需求。
   建议**只选 1–2 个分类**（如 cs.CL，269 条/天，且与「语言」最贴）。

---

## 三、公版书（白哥说的「内容量主路径」）

### 3.1 Project Gutenberg ⭐ **VPS 可达**（本机不可达）

🔴 **又一次「本机 ≠ VPS」**：

| 环境 | `gutenberg.org` |
|---|---|
| 本机 | 🔴 **HTTP 000**（超时）|
| **VPS** | ✅ **HTTP 200** |

⇒ 若只在本机测，会**误判「Gutenberg 不可用」而放弃整条路**。

### 3.2 实测能力

| 项 | 实测 |
|---|---|
| 主页 | ✅ 200 · 30 KB |
| 书目 | ✅ 7.5 万+ 本（页面自述 "over 75,000 free eBooks"）|
| **txt 格式** | ✅ 200 · 傲慢与偏见 **772,386 B / 130,416 词** |
| **epub 格式** | ✅ 200 · 561,102 B |
| **许可** | ✅ **公有领域（Public Domain）** ⇒ 无版权风险，可自由分发 |
| 机器可读目录 | ✅ **OPDS**：`/ebooks/search.opds/?query=X` → Atom `<feed>` · 62 KB · 27 entry |

#### 🔴 但下载**不稳定** —— 必须处理

实测（VPS，同一 URL 连续 4 次）：

```
epub 第 1 次: 512,348 B   ← 不完整
epub 第 2 次: 561,102 B   ← ✅ 完整
epub 第 3 次: 260,204 B   ← 不完整
txt  第 1 次: 213,052 B   ← 不完整（声明 772,386）
⚠️ 一次完整下载用了 30+ 秒（≈18 KB/s）
```

**但**：`accept-ranges: bytes` ✅ → **Range 实测返回 HTTP 206 + 精确 1024 B** ✅

⇒ **有解**：**带 Range 的分段重试下载器**（每段小、失败重试、拼装校验大小）。
   `curl --continue-at -` 或自实现 range 循环都可以。

📌 **但先问一句：谁下载？**
- **如果电子书是「用户在 App 里导入」** → 下载在**用户设备**上，用用户网络 ⇒ **VPS 不稳定无所谓** ✅
- **如果我们要「预抓公版书推给用户」** → 必须实现分段重试下载器 ⚠️

### 3.3 Gutenberg 的机器可读入口（两个坑）

| 入口 | 实测 | 说明 |
|---|---|---|
| `/ebooks/search.opds/?query=X` | ✅ 200 · `<feed>` Atom · 27 entry | **真 OPDS**，但**是 Atom 格式**（后端 `parse_rss` 不认）|
| `/feeds/top.rss` | 🔴 **返回的是 HTML 页**（不是 RSS！）| 「Feeds of new eBooks」说明页 —— **名字骗人** |
| `/ebooks/{id}.epub.noimages` | ✅ 200 · `application/epub+zip` | 下载入口（302 跳转）|

⚠️ **`/feeds/top.rss` 是个「文档名与实际不符」的坑** —— 与今天其他的「文档写了但没生效」同族。

### 3.4 其他公版书源

| 源 | VPS | 说明 |
|---|---|---|
| **Standard Ebooks** | 🟡 主页 200 · `/feeds/atom/all` **401** | 排版精良（比 Gutenberg 好），但 feed 要认证 |
| archive.org | 🔴 000 | 不可达 |
| openlibrary.org | 🔴 000 | 不可达 |
| gutendex.com（第三方 API）| 🔴 000（VPS 与本地都不可达）| 用它做书目 API 的路走不通 |

---

## 四、「直接放弃」的执行清单（按白哥口径）

本轮**实测后放弃 5 个**，各有明确理由：

| 放弃的 | 理由（实测） |
|---|---|
| Product Hunt 官方 | **403**（Cloudflare）—— 不是「暂时」，是长期拦 |
| Sidehunt | 可达但 `description` **全空** |
| WhatLaunched | 可达但是**产品营销描述** |
| Starter Story | 改版成 **AI 数据档案页**（dom_smoothie 提取仅 289 字符）|
| Smashing（上轮）| **40 条跨 156 天** ⇒ 无持续新增 |
| Wired（上轮）| **42% 优惠码页** |
| Lobsters（上轮）| **21 个域名** ⇒ 版权不可控 |
| Simon Willison（上轮）| **Atom** ⇒ 当前后端不解析 |

📌 **这个口径很有价值** —— 它把「权衡」变成「判据」：
   **可达性 < 可用 或 内容质量不达标 → 直接弃，不投入维护成本。**
   本轮 8 个候选里只留 2 个（arXiv + 上轮的 HackerNoon），**筛掉 75%**。

---

## 五、「其他类型不够」的补法：NPR 分频道（零成本）

白哥说「其他类型的信息不太够」。现有结构：

| 类型 | 源 | 状态 |
|---|---|---|
| news | NPR | ✅ 唯一 100% 全文的源 |
| news | ECNS | 🟡 仅 28 词摘要 + **曾停更 46 小时** |
| tech | Dev.to + HN | ✅ |
| tech | （HackerNoon 待接）| ⭐ RSS 全文 |
| —— | **其他类型（商业/科学/文化/健康）** | 🔴 **空缺** |

**补法**：NPR 有 6 个分频道 RSS，**实测全部可达**（上轮报告 §七）：

```
feeds.npr.org/1006  商业   ·  1007  科学   ·  1008  文化
             1019  科技   ·  1128  健康   ·  1004  国际
```

🔑 **纯配置改动**（往 `content_source` 加 6 行 seed）—— **零代码、零风险**，
   把兴趣领域从 **2 类扩到 7 类**，且 NPR 是本轮实测**质量最好**的源
   （句末完整 6/8，全文字数中位 1000+）。

---

## 六、🆕 本轮新增判据

### 6.1 **「镜像站」不是「原站」的等价替代**

Product Hunt 403 → vibedollar 用 sidehunt / whatlaunched 替代。
但**镜像站给的内容形态与原站不同**：PH 至少还有产品描述，Sidehunt **连描述都是空的**。

📌 判据：**替代源必须按「内容形态」重新评估**，不能因为「它是 X 的镜像」就认为等价。
   （同族：**「复用同一组件」≠「同一套行为」**。）

### 6.2 **「页面类型变了」是聚合/档案站的长期风险**

Starter Story 曾经是「创始人访谈文章」，现在自述是 **「AI research system compiled this page」**
⇒ 页面从**文章**变成**数据表**。而 `starterstory_provider.py`（8 月底写的）仍在按旧的六区块解析。

📌 判据：**接入「会改版的站点」时，断言要能发现「它变成另一种东西了」**，
   不能只断言「字段还在」。
   🔑 最小成本做法：**断言「提取出的正文字数下限」**（本次 Starter Story 只有 289 字符就被抓出来了）。

### 6.3 **判据：先问「谁下载」再评估下载稳定性**

Gutenberg 从 VPS 下载 3 次只成功 1 次 —— 看起来是「不可用」。
但如果下载发生在**用户设备**上，VPS 的稳定性**完全不相关**。

📌 判据：**评估「下载能力」前先确定「在哪下载」**。
   端侧下载 → 只关心**可达性**（200 就够）；服务端下载 → 才关心**稳定性与断点续传**。
   （本轮 Gutenberg 支持 `accept-ranges`，有解。）

### 6.4 **「文档名/文件名」可能与实际格式不符**（本族已第 4 次）

- `/feeds/top.rss` → 实际返回 **HTML 页**
- `build.gradle.kts` 没写 `minifyEnabled` → R8 **照样跑**（今天早些时候）
- `.env` 没有 `RUST_LOG` → 日志**静默不打**

📌 判据：**格式要实测（看根元素 / 看响应头），不能从名字推断**。
   （已有判据「RSS 还是 Atom 必须实测根元素」的扩展。）

---

## 七、建议的接入顺序

| 序 | 动作 | 成本 | 依据 |
|---|---|---|---|
| **1** | **接 NPR 6 个分频道** | 🟢 **纯配置**（6 行 seed）| 补「其他类型不够」，零风险，§五 |
| **2** | **接 arXiv cs.CL**（只用 RSS abstract）| 🟢 **一行 seed** | 269 条/天 · 100% 完整 · 零抓取，§2.3 |
| **3** | **接 HackerNoon**（上轮推荐）| 🟢 一行 seed | RSS 全文 1613 词 · 零抓取 |
| **4** | 公版书：**先做「用户导入」**（端侧下载）| 🟡 中（要 epub 解析）| §3，端侧下载 ⇒ VPS 不稳定无所谓 |
| **5** | 若要「预推公版书」→ 写**分段重试下载器** | 🟡 中 | §3.2（`accept-ranges` 已确认支持）|
| ❌ | Product Hunt / Sidehunt / WhatLaunched / Starter Story | — | **放弃**，§四 |
| 🟡 | Failory（创业故事）| 🔴 高（要新增 kind）| 先记录，除非白哥要这个题材 |
| 🟡 | Simon Willison / Standard Ebooks | 🔴 高（要 Atom 支持）| 两件都是 Atom ⇒ 若要做，**一次把 Atom 支持做全**（一个 feed-rs 解决两个源）|

🔑 **第 1–3 步合计只需 3 处 seed 改动，可以先做**（等白哥批准）。
   ⚠️ 但按项目铁律：**改代码前先出报告 + 请示** —— 本报告即为请示。

---

## 八、复现方式

```bash
cd backend
cargo run -q -p api_server --example eval_candidate_sources
```

改 `CANDIDATES`（RSS 源）或 `DIRECT_PAGES`（文章页）即可扩展。
RSS 侧走 `fetch_source_items`、文章页走 `fetch_article_body_diagnostic` —— **都是生产同款代码路径**。
