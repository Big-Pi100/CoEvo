# 内容源策略评估：RSS + Reddit 方案

- 日期：2026-09-25
- 评估对象：白哥提出的「用 RSS 订阅 + Reddit 帖子做内容源，通过 vibedollar 订阅拉取」
- 上游：`docs/design/english-app-implementation-plan-v2-2026-09-25.md`
- 结论：**方向正确（绕开了出版许可），但 Reddit 部分有必须知道的风险；RSS 部分有比预想更好的源**

---

## 〇、先说结论

| 判断 | 内容 |
|---|---|
| ✅ **合规突破** | RSS / 文章**不是「书籍」**，绕开了 App Store 的网络出版服务许可证门槛。这是这个方案最大的价值 |
| ✅ **产品洞察成立** | 「刷信息流 + 学英语」是真需求，信息流的爽感 + 每日新鲜是留存引擎 |
| 🔴 **Reddit 有重大风险** | 商业使用需 **$12,000/年** API 合同；且 Reddit 正在**起诉搜索 API 提供商**（SerpApi）——这正是 vibedollar 依赖的模式 |
| 🔴 **Reddit 内容不适合学英语** | 俚语、缩写、语法随意、NSFW 风险；VOA/BBC Learning English 这类**专为 ESL 设计**的源要好得多 |
| 🟠 **架构必须调整** | 若「每用户按兴趣单独抓取」会引入边际成本，需改为**服务端共享内容池** |
| 🟠 **有一个新边际成本** | 每日新内容 → 词库外生词 → LLM 制卡。必须用**全局缓存**化解 |

---

## 一、合规：方向正确，这是一次真正的突破

### 1.1 为什么这个转向很关键

首版方案评估时，我指出「内置书库分发」可能触发 Apple 的**网络出版服务许可证**要求。你的转向直接绕开了这一条：

| 内容形态 | 是否触发出版资质 |
|---|---|
| 「书籍与杂志内容」（整本书、在线书城） | 🔴 触发，需 NPPA 许可 |
| **RSS 文章 / 论坛帖子 / 新闻** | ✅ **不触发** —— 不是「书籍」 |

这是一次**零成本解除阻塞**（不需要申请任何资质），比首版方案里的四条路径都好。

### 1.2 但合规风险从「出版资质」转移到了「数据获取与再分发」

需要区分三个层次：

| 层次 | 风险 | 说明 |
|---|---|---|
| **① 获取方式** | 🔴 / 🟢 | Reddit API 商用限制 vs RSS 公开发布 |
| **② 内容再分发** | 🟠 | 全文展示给用户 ≠ 个人订阅阅读 |
| **③ 用户数据（UGC）** | 🟠 | 帖子作者是自然人，涉及个人信息 |

**① 获取方式**（详见 §二）—— Reddit 是风险区，RSS 是安全区。

**② 内容再分发** —— 即使 RSS 合规，把它聚合展示给其他用户仍要谨慎：

| 内容类型 | 再分发风险 | 建议 |
|---|---|---|
| **公版 / CC 许可**（Wikipedia、Project Gutenberg） | 🟢 低 —— 许可允许再分发 | 可全文展示 |
| **ESL 教学源**（VOA / BBC Learning English） | 🟡 中 —— 本身是教学材料，引用较安全 | 可展示，注明来源 |
| **新闻站**（BBC News / NPR / Reuters） | 🟠 中高 —— feed 供订阅，不等同授权再分发 | **只存标题+摘要+链接**，全文引导跳原文（Flipboard/Feedly 模式） |
| **用户生成内容**（Reddit 帖子正文） | 🔴 高 —— 正文是作者创作作品 | 不建议展示全文 |

**③ 个人信息** —— Reddit 帖子含用户名，属 GDPR/CCPA 意义上的个人数据。若面向海外区（含欧盟），需考虑数据最小化：**去掉作者信息，只保留内容**。

> ⚠️ 我不是律师。以上是基于公开资料的合规调研，涉及正式上线前建议找专业人士确认。

---

## 二、【重点提醒】Reddit 的具体风险

### 2.1 官方 API 的商业使用门槛

| 项 | 事实 |
|---|---|
| 免费层 | 100 QPM，**明确禁止商业应用** |
| 商用单价 | $0.24 / 1,000 调用 |
| **合同门槛** | **约 $12,000/年（¥8.7 万/年）起**，不分用量 |
| 审批 | 2026-06-05 起 Responsible Builder Policy，**所有 API 访问需人工审批**（2–4 周，可能静默拒绝） |
| ML 训练 | **明确禁止用 API 数据训练模型** |

**CoEvo 是明确的商业产品**（订阅制），所以免费层不适用。

成本随规模的演算（若走商用档）：

| 用户规模 | 调用量（5 条/天） | API 成本 |
|---|---:|---:|
| 1,000 | 15 万/月 | ¥259/月 |
| 10,000 | 150 万/月 | ¥2,592/月 |
| 50,000 | 750 万/月 | ¥12,960/月 |

**外加 $12,000/年 的合同门槛（约 ¥8.7 万/年，无论用量）** —— 这与「零边际成本」模型直接冲突。

### 2.2 更值得注意的：Reddit 正在起诉搜索 API 提供商

这是我认为**最需要你知道**的一条：

| 时间 | 事件 |
|---|---|
| 2025-06-04 | Reddit 起诉 **Anthropic**（未经许可抓取） |
| 2025-10-22 | Reddit 起诉 **Perplexity + SerpApi + Oxylabs + AWMProxy**（SDNY） |

**注意被告名单里有谁**：
- **SerpApi** —— 搜索 API 提供商
- **Oxylabs** —— 代理/抓取基础设施提供商

这是**首次有平台直接起诉「搜索 API 供应商」和「代理供应商」作为共同被告**。

**为什么这条对你重要**：vibedollar 抓 Reddit 用的正是 **AnySearch**（第三方搜索 API），与 SerpApi 是同一类模式。而你现在打算把这条管线接到一个**面向终端用户展示内容**的商业 App 上 —— 暴露程度比 vibedollar 的「给你线索做内部判断」更高。

法律状态需要说清楚：
- CFAA（联邦反黑客法）层面：**抓公开数据是安全的**（hiQ v. LinkedIn, 9th Cir. 2022）
- **但合同违约（Reddit User Agreement）才是真正的风险面** —— hiQ 案里 LinkedIn 最终正是赢在合同违约上
- 小团队通常「飞在雷达下」，但暴露不为零

### 2.3 产品角度：Reddit 恰恰不适合学英语

这一点和合规无关，是内容质量问题：

| 问题 | 具体表现 |
|---|---|
| **大量俚语/缩写** | IMO、TBH、IIRC、AFAIK、TL;DR、OP、ELI5 |
| **语法随意** | 小写开头、省略标点、故意错拼（"u"、"ur"、"thx"） |
| **语言难度不可控** | native 的随意表达，对学习者反而更难理解 |
| **NSFW / 争议内容** | 需要大量审核成本，且审核漏网会直接影响 App Store 审核 |
| **人身攻击/极端言论** | 学习场景不适宜 |
| **信噪比低** | 高质量讨论占比不高 |

**对比：专为 ESL 学习者设计的源**

| 源 | 特点 |
|---|---|
| **VOA Learning English** | 慢速新闻、**词汇受限**、分级明确、美音 |
| **BBC Learning English** | 每日更新、含测验、英音、专业教学团队 |

这两个源是**英语教学领域的标准资源**，语言被刻意控制在学习者可理解的范围内。**用它们替代 Reddit，内容质量是数量级的提升。**

---

## 三、【推荐】RSS 为主的内容源方案

### 3.1 推荐源清单

**A 类 · ESL 专用（核心推荐）**

| 源 | RSS | 难度 | 特点 |
|---|---|---|---|
| **VOA Learning English** | `learningenglish.voanews.com/rss/` | A2–B1 | 慢速·词汇受限 |
| **BBC Learning English** | `bbc.co.uk/worldservice/learningenglish/rss/leweekly.xml` | A2–B2 | 每日更新·含测验 |
| **BBC Learning English from the News** | `podcasts.files.bbci.co.uk/p05hw4bq.rss` | B1–B2 | 新闻+音频 |

> **BBC 官网专门有 RSS 帮助页**，明确写「Copy this URL into your newsreader」—— 这是发布者对订阅行为的主动指引，合规清晰。

**B 类 · 规范新闻（进阶）**

| 源 | RSS | 难度 |
|---|---|---|
| BBC News | `feeds.bbci.co.uk/news/system/latest_published_content/rss.xml` | B2–C1 |
| NPR | `npr.org/rss/` | B2–C1 |
| Reuters | `reuters.com/rssFeed/` | B2–C1 |

**C 类 · 免费开放 API（技术/科普）**

| 源 | 接口 | 难度 | 许可 |
|---|---|---|---|
| **Hacker News** | 官方免费 API（`github.com/HackerNews/API`） | B2–C1 | 🟢 官方开放 |
| Dev.to | `dev.to/feed` | B2–C1 | 🟢 免费 API |
| NASA | `nasa.gov/rss/` | B1–B2 | 🟢 公版 |
| Smithsonian | `smithsonianmag.com/rss/` | B2–C1 | 🟡 |
| **Wikipedia** | `wikipedia.org/api` | 全级别 | 🟢 **CC 许可** |

> **Wikipedia 值得特别关注**：CC BY-SA 许可**明确允许再分发**，内容量极大（可按兴趣取任意主题），且语言规范。是「无版权顾虑」的最优选择。

### 3.2 「刷信息流 + 学习」的产品形态

你的核心洞察是「把刷社交平台和学习结合」。这个体验用 RSS 完全能实现，而且质量可控：

```
打开 App → 今日信息流（卡片式，像刷 Twitter）
   ├── [科技] How AI Is Changing Weather Forecasting   ← VOA Learning English
   ├── [文化] The History of Coffee                     ← BBC Learning English
   ├── [科学] NASA Finds Water on the Moon              ← NASA
   └── [生活] Why We Sleep Better in Winter             ← 自选源

点开一篇 → 阅读器（全屏、沉浸）
   · 划线选中单词 → 查词卡片（IPA + 例句 + 搭配）→ 自动发音
   · 查过的词静默进入生词本 → 排入 FSRS 复习队列
   · 读完 → 本文生词回顾（这几个词你今天遇到了）

下滑换下一篇（无限流）
```

**兴趣机制**（对应你说的「根据用户偏好拉取不同内容」）：

```
兴趣标签（首次启动选择，可随时改）
  ☑ 科技  ☑ 商业  ☑ 科学  ☐ 体育  ☑ 文化  ☐ 娱乐  ☑ 健康

→ 服务端按标签从共享池筛选 → 推送到用户本地
→ 阅读行为反馈（停留时长/查词密度/完成率）→ 调整权重
```

### 3.3 与「离线优先」的关系（需要明确）

原方案是「离线优先」，每日更新需要联网 —— 两者不冲突，但要设计好：

| 场景 | 行为 |
|---|---|
| 有网 | 后台拉取今日内容 → 存本地 SQLite |
| 无网 | 读已缓存的内容（**仍可查词、复习、发音**） |
| 复习 | 完全本地（FSRS）✅ |
| 内容更新 | 需要联网（每日一次，数据量很小 —— 几十篇文章约 1 MB） |

**关键**：内容更新是「每日一次的小批量拉取」，不是实时流，所以离线体验几乎不受影响。

---

## 四、【必须调整】架构：共享内容池，而非按用户抓取

### 4.1 问题

如果按「每个用户按兴趣单独抓取」设计：

```
User A 兴趣「科技」→ 触发抓取
User B 兴趣「商业」→ 触发抓取
...
成本 ∝ 用户数 × 抓取频率     ❌ 边际成本随用户线性增长
```

这会打破你要的**零边际成本模型**。

### 4.2 推荐架构

```
服务端：每日全局抓取（固定次数，与用户数无关）
    ↓
  内容池（按主题分类：科技/商业/文化/科学/生活）
    ↓
  用户按兴趣标签筛选（轻量接口 / 本地筛选）
    ↓
成本 = 固定（每天 N 个源 × 1 次）  ✅ 边际成本 ≈ 0
```

**成本核算**（共享池，与用户数无关）：

| 源数量 | 抓取频率 | 月流量 | CDN 成本 |
|---:|---|---:|---:|
| 20 | 每 6 小时 | 46 MB/月 | **¥0.04/月** |
| 50 | 每 6 小时 | 117 MB/月 | **¥0.09/月** |
| 100 | 每 6 小时 | 234 MB/月 | **¥0.18/月** |

**结论：即使 100 个源，月成本不到 ¥0.2。与用户数完全无关。**

### 4.3 需要新增的数据表

```sql
-- 内容源（运营维护）
CREATE TABLE content_source (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL,
  url          TEXT NOT NULL,           -- RSS / API 地址
  category     TEXT,                    -- tech | business | culture | science | life
  cefr_hint    TEXT,                    -- A2 | B1 | B2 | C1（难度提示）
  fetch_interval_min INTEGER DEFAULT 360,
  enabled      INTEGER DEFAULT 1,
  last_fetch_at TEXT,
  fail_count   INTEGER DEFAULT 0,
  license      TEXT,                    -- public_domain | cc | news | esl
  redistributable INTEGER DEFAULT 0     -- 是否可全文展示（决定存全文还是摘要）
);

-- 内容池（服务端共享）
CREATE TABLE content_pool (
  id           INTEGER PRIMARY KEY,
  source_id    INTEGER REFERENCES content_source(id),
  title        TEXT NOT NULL,
  summary      TEXT,                    -- 摘要（新闻类只存摘要）
  body         TEXT,                    -- 全文（仅 redistributable=1 时存）
  url          TEXT NOT NULL,
  author       TEXT,                    -- 注意：UGC 建议清空（个人信息）
  category     TEXT,
  cefr_est     TEXT,                    -- 自动估算难度
  word_count   INTEGER,
  unique_words INTEGER,                 -- 生词密度参考
  published_at TEXT,
  fetched_at   TEXT DEFAULT (datetime('now')),
  UNIQUE (url)
);
CREATE INDEX idx_pool_cat ON content_pool (category, published_at DESC);

-- 用户兴趣 + 已读
CREATE TABLE user_interest (
  user_id  TEXT NOT NULL,
  category TEXT NOT NULL,
  weight   REAL DEFAULT 1.0,
  PRIMARY KEY (user_id, category)
);

CREATE TABLE user_read (
  user_id      TEXT NOT NULL,
  content_id   INTEGER NOT NULL,
  read_at      TEXT DEFAULT (datetime('now')),
  progress     REAL DEFAULT 0,
  words_looked INTEGER DEFAULT 0,
  PRIMARY KEY (user_id, content_id)
);
```

---

## 五、【必须处理】新的边际成本：词库外生词

### 5.1 问题

每日新内容会带来词库外生词 → LLM 兜底制卡 → 这是 **per-lookup 成本**，会打破零边际成本模型。

### 5.2 解法：全局缓存（原方案已有设计）

原方案 §3.3 的 `generated_card_cache` 表正是为此设计的：**同一个词全局只生成一次，所有用户共享。**

```
无缓存：1000 用户 × 3 次/天 = 90,000 次 LLM/月  ❌
有缓存：900,000 次查词 → 词库外 90,000 → 缓存未命中 13,500 次 LLM/月  ✅
```

**关键洞察**：成本随「唯一词数」增长，不随「查询次数」增长。而英文常用词就 2–5 万个 —— **边际成本天然收敛**。

### 5.3 双层缓存策略

```
用户查词
  ├── 命中 word.db（11,900 卡）      → 本地秒回 ✅ 主要路径
  ├── 命中本地 external_word_cache   → 本地秒回 ✅
  └── 都未命中 → 请求服务端
        ├── 命中 generated_card_cache（全局共享）→ 返回 ✅
        └── 都未命中 → LLM 生成 → 写入全局缓存 + 本地缓存 ✅
```

**建议**：预先用 LLM 把 VOA/BBC Learning English 的**高频词表**跑一遍（这些源词汇受限，词表规模有限），进一步降低运行时调用。

---

## 六、修正后的方案对比

| 维度 | Reddit 方案 | RSS 方案（推荐） |
|---|---|---|
| **合规（内容形态）** | 🟢 不是书籍，绕开出版许可 | 🟢 同样绕开 |
| **合规（获取方式）** | 🔴 商用需 $12K/年；平台在起诉搜索 API 商 | 🟢 RSS 公开供订阅，零成本零风险 |
| **内容质量（学英语）** | 🔴 俚语/缩写/语法随意/NSFW | 🟢 ESL 专用源，语言受控 |
| **边际成本** | 🔴 API 调用 + 门槛费 | 🟢 共享池，¥0.2/月固定 |
| **更新频率** | 高（实时） | 中（每日，对学习足够） |
| **审核负担** | 🔴 高（UGC 需大量过滤） | 🟢 低（编辑把关过的内容） |
| **个人信息** | 🟠 含用户名，GDPR 义务 | 🟢 新闻源无个人信息 |
| **内容量** | 大 | 取决于源数量（可扩到 100+） |

**我的建议：RSS 为主（A/B/C 类源），Reddit 不做。**

若你仍希望保留「社交讨论」的形态，有三个替代思路：
1. **Hacker News** —— 官方免费 API，技术讨论质量高，语言规范
2. **Reddit 官方 API 免费层** —— **但明确禁止商用，不可用**
3. 自建讨论区（用户评论）—— 内容由 App 自己产生，无外部依赖

---

## 七、对 vibedollar 的复用建议

你说「用 vibedollar 订阅拉取」。实测 vibedollar 的技术栈：

| 能力 | vibedollar 现状 | 对 CoEvo 可复用性 |
|---|---|---|
| 抓取管线 | `pipeline/collector.py` — 用 **AnySearch** 搜 Reddit/X | 🟠 模式可复用，但 Reddit 部分不建议用于 CoEvo |
| 内容解析 | `_parse_results` / `_parse_comment_results` | 🟡 解析逻辑绑定 Reddit 格式 |
| 存储去重 | `pipeline/posts.py` — `PostStore`，md5 source_id 幂等 | ✅ **去重机制可直接复用** |
| 订阅机制 | `vibedollar_v2/sub_backend.py` | 🟠 绑定「产品描述→找客户」，改造工作量中等 |
| **RSS 支持** | **无**（全仓库搜索无 RSS 解析） | ❌ **需新建** |
| 定时调度 | `vibedollar_v2/v3_scheduler.py` | ✅ 调度框架可参考 |

**结论**：
- **可复用**：去重机制（`PostStore` 的 source_id 幂等设计）、调度框架、订阅→抓取的流程骨架
- **需新建**：RSS/Atom 解析（`feedparser` 或自研）、内容池、兴趣分发
- **不建议复用**：Reddit 抓取部分（因 §二 的风险）

另外提示一个**职责边界问题**：vibedollar 是独立商业产品（卖线索给 agent），CoEvo 是英语学习 App。让 CoEvo 依赖 vibedollar 运行时会引入跨项目耦合 —— 建议**只复用代码模式，不建立运行时依赖**。

---

## 八、待你决策

| # | 决策点 | 选项 | 我的建议 |
|---|---|---|---|
| **1** | **Reddit 是否保留** | A 放弃 / B 保留但只存链接不展示内容 / C 保留并接受风险 | **A** —— 风险 + 成本 + 内容质量三重不利；Hacker News 可替代「社交讨论」形态 |
| **2** | 内容源范围 | A 只做 ESL 专用源（VOA/BBC LE） / B + 新闻源 / C + 开放 API（HN/NASA/Wikipedia） | **C** —— 覆盖全难度，且 Wikipedia/HN 无版权顾虑 |
| **3** | 新闻类的存储策略 | A 只存标题+摘要+链接 / B 全文展示 | **A** —— 规避再分发风险（Flipboard 模式） |
| **4** | 是否用共享内容池 | A 是（推荐） / B 按用户抓取 | **A** —— 决定边际成本是 0 还是线性增长 |
| **5** | vibedollar 复用边界 | A 只复用代码模式 / B 建立运行时依赖 | **A** —— 避免跨项目耦合 |

---

## 附：调研证据索引

| 结论 | 来源 |
|---|---|
| RSS/文章不是「书籍」→ 不触发出版许可 | Apple App Store Connect 文档（触发条件是「提供書籍與雜誌內容的 App」） |
| Reddit 商用 API $12,000/年门槛 | Reddit 2023-06 定价公告（$0.24/1k，商用合同 $12k/月起） |
| 2026-06-05 起需人工审批 | Reddit Responsible Builder Policy |
| Reddit 起诉 Anthropic | 2025-06-04 |
| Reddit 起诉 Perplexity + **SerpApi + Oxylabs** | 2025-10-22, SDNY —— 首次直接起诉搜索 API 与代理供应商 |
| 抓公开数据 CFAA 下安全 | hiQ Labs v. LinkedIn, 31 F.4th 1180 (9th Cir. 2022) |
| 合同违约才是真实风险面 | hiQ 案 LinkedIn 最终赢在合同违约索赔 |
| 明确禁止 ML 训练 | Reddit Data API Terms |
| BBC RSS 主动指引订阅 | BBC 官网 RSS help 页（"Copy this URL into your newsreader"） |
| VOA / BBC Learning English 为 ESL 专用 | 官网说明 + 多所大学 ESL 资源推荐 |
| Hacker News 官方免费 API | github.com/HackerNews/API |
| Wikipedia CC 许可允许再分发 | CC BY-SA 4.0 |
| vibedollar 用 AnySearch 抓 Reddit | `pipeline/collector.py`（`_call_anysearch`） |
| vibedollar 无 RSS 支持 | 全仓库 grep `rss\|feedparser\|atom` 无解析实现 |
| vibedollar 去重机制 | `pipeline/posts.py` `PostStore.upsert_post`（md5 source_id 幂等） |

---

## 九、🆕 2026-09-29 实测修订与实施记录（**本文档的结论有一处被实测推翻**）

> 触发：白哥选「内容源 = 下一批」，我按规矩先核实现状 → 发现**本文档 §三 的核心推荐源在国内不可达**。
> 全部数据来自**本机 + VPS 双实测**（`curl -o /dev/null -w '%{http_code}'`，带 UA）。

### 9.1 🔴 实测：§三 推荐的 A 类源**全部不可达**

| 源 | 本机 | VPS（<VPS_IP>） | 文档原评价 |
|---|---|---|---|
| **VOA Learning English** | ❌ `000` | ❌ `000` | A 类核心推荐 |
| **BBC（含 Learning English）** | ❌ `000` | ❌ `000` | A 类核心推荐 |
| **Wikipedia** | ❌ `000` | ❌ `000` | 「无版权顾虑的最优选择」 |
| Google / Reuters / Guardian / Reddit | ❌ `000` | — | — |
| **NPR** | ✅ `200` | ✅ `200` | B 类 |
| **ECNS 中国新闻网英文** | ✅ `200` | ✅ `200` | 未列入 |
| **Ars Technica** | ✅ `200` | ✅ `200` | 未列入 |
| **Dev.to** | ✅ `200` | ✅ `200` | C 类（列为免费 API） |
| **Hacker News API** | ✅ `200` | ✅ `200` | C 类 |

🔑 **关键结论**：这不是沙箱限制 —— **VPS（腾讯云国内机）结果与本机完全一致**。
   而 VPS 才是抓取的**真实运行环境**。
   → §三 的「A 类 ESL 专用源」**在当前基础设施下不可用**：
     它们是唯一「语言受控（A2–B1）」的一类，也正是本产品的核心价值所在。

⚠️ **代价（需产品层面知晓）**：改用的可达源（NPR / Ars Technica）是**母语者向**的（B2–C1），
   对中文母语学习者**明显偏难**。若将来要保住 ESL 分级，只有两条路：
   ① 服务端走**海外出口**（代理或海外机器）；② 换海外 VPS。**均属基础设施决策，本批未做。**

### 9.2 🔴 Reddit 决策**变更**：用 Hacker News 承载「热帖」形态

白哥的原话：「**爱刷社交网络的比爱看新闻的多**」→ 产品上要「热帖」形态（洞察成立，本文档 §2.3 的否定只针对「用 Reddit 做英语学习材料」）。

但白哥提出的「**不说信息源、只说热帖**」**不成立** —— 🔑 **风险取决于数据怎么拿到，不取决于界面叫什么**：

| 事实 | 影响 |
|---|---|
| Reddit 免费 API **明确禁止商业应用** | CoEvo 是订阅制商业产品 → 免费层不适用 |
| 商用合同 **~$12,000/年**起（不分用量）+ 2026-06-05 起**人工审批** | 个人主体拿不到商用合同 |
| 2025-10-22 Reddit **起诉 SerpApi / Oxylabs**（搜索 API 与代理供应商） | 与 vibedollar 用的 AnySearch **同类模式** |
| 真实风险面是**合同违约**（hiQ 案 LinkedIn 最终赢在这条），非 CFAA | 属**归零型**（封禁/诉讼堵死后续路径） |

**→ 最终决策（白哥 2026-09-29）**：**Reddit 不再接**；「热帖」形态改由 **Hacker News** 承载。
HN 保留了**热帖榜 / 标题 / 分数 / 评论数**这套形态（需求被满足），且：
· 官方**免费** API（`github.com/HackerNews/API`）× 无商用门槛
· 无起诉先例 × 英语规范 × 无 NSFW

### 9.3 新闻类存储策略：白哥选**全文展示**（本文档原建议「只存摘要」）

| | 本文档 §八 决策 3 的建议 | 白哥 2026-09-29 的选择 |
|---|---|---|
| 新闻类 | **A：只存标题+摘要+链接**（规避再分发风险） | **B：全文展示** |

**已按白哥的选择实施**，并同步记录风险与两个技术前提：
1. **技术前提**：RSS 通常**只给摘要** → 要全文就得**抓原网页** —— 这是从「订阅 feed」
   跨到「爬正文」，边界不同。（实测：Ars Technica 的 feed **自带全文**，NPR 只有摘要。）
2. **风险等级**：新闻类从「中」升到「中高」（本文档 §1.2 的再分发分析）。
   → 数据层留了 `content_source.redistributable` 列，**按源**控制存不存全文
   （默认新闻类 = 1 是按白哥的选择；若将来要收紧，改配置即可，不需改代码）。

### 9.4 🆕 实测发现的第三个问题：**源的时间格式不统一，且有的不带时区**

| 源 | `pubDate` 格式 | 自带时区 |
|---|---|---|
| NPR / Ars Technica / Dev.to | `Tue, 29 Sep 2026 07:36:24 -0400` | ✅ RFC 2822 |
| **ECNS** | **`2026-09-29 21:34:24`** | ❌ **不带** |

🔴 **不能猜 UTC**：ECNS 那条按 UTC 解释会得到 `21:34Z`，而抓取时刻是 `15:58Z`
→ **时间比现在还晚**（未来时间）。它实际是**北京时间**。

🔑 判据：**「缺失的元信息」不能靠默认值兜底** —— 默认 0（UTC）会产出一个
「看起来正常、实际错 8 小时」的时间，而且**不报错**。
→ 做成 `content_source.tz_offset_min` 列（ECNS = 480），**时区是源的属性，不是解析器的常量**。

### 9.5 实施记录（2026-09-29 · 白哥定「先做后端」）

**新增 5 个文件**（`backend/crates/api_server/src/`）：

| 文件 | 职责 | 可独立验证 |
|---|---|---|
| `content_rss.rs` | RSS 2.0 → `ParsedItem`（纯函数 · 零 IO） | ✅ 真实 fixture 断言 |
| `content_hn.rs` | HN API → `ParsedItem` | ✅ 同上 |
| `content_fetch.rs` | HTTP + 幂等入库 + 调度线程 | 🟠 需网络/DB |
| `content_handler.rs` | `GET /api/feed` · `GET /api/feed/{id}` | ✅ 归一化逻辑可断言 |
| `examples/content_probe.rs` | 真实抓取冒烟（临时库） | 工具 |

**数据层**：`content_source` + `content_pool` 两张新表 + 5 个种子源。
🔴 **方案 §4.3 的 `user_read` / `user_interest` 有意不建**：

| 方案里的表 | 处置 | 理由 |
|---|---|---|
| `user_read` | 🔴 不建 | 与端侧 `user.db.article_read` **重复** —— 「学习状态已整体迁端侧」（09-29 定）→ 再建服务端阅读表就是**同一口径两个出处**，必然漂移 |
| `user_interest` | 🔴 不建 | ① 兴趣偏好属**端侧 prefs** ② 「兴趣怎么影响排序」**尚未设计** → 现在建表是**没有依据的结构** |

🔑 判据：**「方案里写了」≠「现在就该建」** —— 方案是 09-25 的，
   而「学习状态迁端侧」是 09-29 的**后手决策**，新决策覆盖旧方案。
   两侧都有**反向断言**守着（`schema.rs` 断言这两张表不存在）。

**验证**（全部实测）：

| 项 | 结果 |
|---|---|
| `cargo test -p api_server --lib content_*` | ✅ **27 项**（解析 11 · HN 6 · 抓取 8 · 其余） |
| 真实冒烟（`content_probe`） | ✅ **5/5 源成功** · 落库 **201 条** |
| 🔴 **幂等复跑** | ✅ **新增 0 条**（`UNIQUE(url)` + `INSERT OR IGNORE` 生效） |
| 🔴 时间完整性 | ✅ 5 个源 **0 条为空** · **0 条未来时间** · 范围 `09-24 → 09-29` |
| 各源全文情况 | Ars Technica **20/20 有全文** · HN 3 条（Ask HN）· NPR/ECNS/Dev.to 0（feed 只给摘要） |

**未做（明确边界）**：
· 端侧信息流改造（删 mock 3 篇）—— 属**下一批**
· VPS 部署（本批只到「本地可跑通」）—— 零改动，VPS 未碰
· 全文抓网页（`scraper`）：本机 `cargo check` 卡在 crates.io 索引更新，
  改用已有的 `roxmltree`；全文目前来自 **feed 自带**（`content:encoded`），
  「RSS 只给摘要的源要抓网页」这一步**未实现**

---

*本文档为方案评估与调研；§九 为实施记录。合规内容基于公开资料调研，不构成法律意见。*
