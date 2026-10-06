# 内容质量：NPR 音频页「只有配件、没有正文」

> 2026-10-06 · 白哥反馈样本：*Temwa Chawinga is a soccer star at home and abroad*
> （`content_pool.id = 7091`）· 「里边除了裸链接几乎没有有价值的内容」
>
> 📌 本文**只调查不动手**（按铁律：先报告 → 请示 → 再修）。

---

## 一、结论先说

**三个独立缺陷叠加**，任何一个单独存在都不会出这个症状：

| # | 缺陷 | 位置 | 性质 |
|---|---|---|---|
| 1 | **抓取时机**：NPR 文字稿**延迟上线**，而补抓**按时间倒序优先抓最新的** ⇒ 正好抓在「还没上线」的窗口 | `pick_body_candidates` 的 `ORDER BY published_at DESC` | 设计缺陷 |
| 2 | **只试一次**：`body_attempted_at` 记上就**永久放弃** ⇒ 文字稿后来上线了也不会再抓 | `pick_body_candidates` 的 `body_attempted_at IS NULL` | 设计缺陷 |
| 3 | **质量门槛太松**：`MIN_EXTRACTED_CHARS = 300` ⇒ 626 字符的「配件版」**通过判定**，被当成正文存下 | `fetch_article_body` | 阈值问题 |

**并且端侧帮不上忙**：`body` 非空 ⇒ 走正文分支 ⇒ **不显示「正文还没取到，以下是摘要」那条提示**
⇒ 用户看到的就是「标题 + 下载链接 + 播放器 iframe + 一句摘要」，**没有任何提示说这是不完整的**。

---

## 二、证据链（全部实测，非推断）

### 2.1 生产库里存的是什么

```sql
select body from content_pool where id = 7091
```
```
#### Temwa Chawinga is a soccer star at home and abroad

- [Download](https://ondemand.npr.org/anon.npr-mp3/npr/wesun/2026/10/...mp3?...)
- **Embed** ** `<iframe src="https://www.npr.org/player/embed/nx-s1-5981387/nx-s1-9951305" ...>` **

The two-time MVP of the National Women's Soccer League is making waves with her team,
the Current, in Kansas City and at home in Malawi\.
```
**626 字符 / 52 词**。四行里：标题（重复）· 音频下载 · 播放器嵌入 · **一句摘要**。
⇒ 唯一有信息量的内容**就是那句摘要**（而它和 `summary` 字段**逐字相同**）。

### 2.2 原页其实有完整文字稿（决定性证据）

抓原页（137,912 字节 · 9 个 `<p>`）：

```html
<div class="transcript storytext" aria-label="Transcript">
  <b class="icn-story-transcript-wrap">…<span class="transcript-label">Transcript</span></span></b>
  <p><p>AYESHA RASCOE, HOST: <p><p> A two-time MVP in the National Women's Soccer League has…
  <p><p>GREG ECHLIN, BYLINE: Fans of Temwa Chawinga gathered in Kansas City…
  <p><p>(SOUNDBITE OF ARCHIVED RECORDING)<p><p>UNIDENTIFIED ANNOUNCER: There's the final whistle.
```

⇒ **有一段 3,606 字符的完整节目文字稿（transcript）**，我们只抓到了 `storytext` 的**另一个**元素
（`class="storytext storylocation linkLocation"`，位置在它前面 900 字符 —— 那个**只有播放器配件**）。

### 2.3 用当前代码重抓 ⇒ 10/10 全部成功

| 样本 | 生产库存的 | 现在重抓 |
|---|---|---|
| Temwa Chawinga | 626 | **4,462** |
| Cineplexity | 1,268 | **11,438** |
| Russia drones Kyiv | 1,255 | **4,872** |
| Brazil election | 1,250 | **6,658** |
| Premier League | 1,249 | **5,530** |
| France arrests | 1,244 | **4,433** |
| Marathon training | 1,230 | **8,312** |
| Supreme Court climate | 1,221 | **5,216** |
| Community colleges | 1,200 | **6,427** |
| Google satellite | 1,109 | **4,431** |

⇒ **提取器本身没问题**（`dom_smoothie` + `storytext` 选择器 09-30 就加了，v0.1.4 已含）。
⇒ 问题是**当时抓的那一次，页面上的 transcript 还不存在**。

### 2.4 时间分离：抓取时机决定成败

只看「NPR 音频节目页」（57 篇）：

| 组 | 篇数 | 发布 → 抓取 的间隔 |
|---|---|---|
| **抓到文字稿**（正文 ≥3000 字符） | 21 | 中位 **103.9 h**（≈4.3 天）|
| **只有配件**（正文 <3000 字符） | 36 | 中位 **3.2 h** · **最大仅 7.8 h** |

**「失败组」的时间上界（7.8h）与「成功组」的中位（103.9h）相差 13 倍** ——
这不是巧合，是「**文字稿需要几小时到几天才上线**」的直接体现。

### 2.5 影响面

| 口径 | 数量 |
|---|---|
| `content_pool` 总计 | 1,380 篇 |
| **NPR 音频节目页** | **57 篇**（其中 **36 篇 = 63% 是配件版**）|
| 全库「含播放器/嵌入特征 且 正文 <2000 字符」 | 35 篇（2%）|
| 内容源结构 | 24 源中 **18 个是 NPR 分类源** ⇒ NPR 是主力源 |

⚠️ **趋势判断**：这 38 篇里 35 篇是 **10-02 ~ 10-05** 的（近 4 天）——
说明它**每天都在产生新的**，不是一次性历史问题。

### 2.6 一个我不能确定的数字（如实标注）

另一个「更本质」的判据 —— **正文长度 ≤ 摘要 × 1.3**（意味着正文位置放的是摘要）——
在 688 篇可比对条目里命中 **337 篇（48%）**。

⚠️ **但这个数字我判为不可靠、不进结论**，因为分母混了不同性质的源：
实测有源的 `summary` **本身就是全文**（例：某条 `summary` 33,067 字符）。
⇒ 要得出可靠结论，得先按源分别确认「summary 的语义」。
（📌 判据：**比例类判据的分母必须干净** —— 否则虚高/虚低都无从判断。）

---

## 三、修复方案（三档，可分开批准）

### 方案 A —— 存量修复（**立即见效 · 已验证**）

把「配件型」条目的 `body_attempted_at` 清空 + 开 `COEVO_REFETCH_BODIES=1` 跑一轮：
下轮补抓就会重抓它们，**实测 10/10 能拿到完整文字稿**。

```sql
-- 精确范围（35 篇），不扫全库
UPDATE content_pool SET body_attempted_at = NULL
WHERE length(body) < 2000
  AND (body LIKE '%npr.org/player/embed%' OR body LIKE '%ondemand.npr.org%');
```
- ✅ 优点：一轮补抓内见效（每轮 ~N 条，几分钟）
- ⚠️ 代价：**只解决这 35 篇**，明天的新文章照样进坑

### 方案 B —— 质量判据（**治本 · 防劣质入库**）

在 `fetch_article_body` 的判定里加一条「**这是不是正文**」：

**推荐判据**：`正文长度 ≥ max(300, summary长度 × 1.5)`
- 理由：**「正文 ≈ 摘要」就是「没抓到正文」的可靠信号**（正文理应远长于摘要）
- 不达标的 ⇒ 返回 `BodyOutcome::TooShort` ⇒ **不存 body** ⇒ 端侧走摘要分支
  ⇒ 至少会**诚实地显示「正文还没取到，以下是摘要」**（比现在显示垃圾好）

⚠️ 需先核实 `summary` 在**各源**的语义（见 §2.6）—— 有的源 summary 是全文，
那种源不能被这条判据误杀。**这是动手前必须先做的事。**

**备选判据**（互补，不替代）：正文含 `player/embed` / `<iframe` / `ondemand.npr.org` 等
**明确的「配件特征」**且长度 < 2000 ⇒ 判为非正文。
- ✅ 精确（几乎不会误杀真文章）
- ❌ 只覆盖 NPR 这一类形态，换个源就失效

### 方案 C —— 延迟重抓（**治本 · 自愈**）

让「判为没抓到正文」的条目**有机会重试**，而不是永久放弃。三选一：

| 选项 | 做法 | 代价 |
|---|---|---|
| **C1** | 判为「没抓到」时**不写** `body_attempted_at` ⇒ 每轮都重试 | 简单，但会反复抓（NPR 每天 20+ 篇 × 数轮 = 持续浪费）|
| **C2** | 加 `body_retry_count` 列 + **指数退避**（1h → 6h → 1d → 3d，最多 4 次）| 改 schema，但最干净 |
| **C3** | 只对「发布 < 7 天」的失败条目重试，每轮限量 | 改动最小，用一个**时间窗**代替计数 |

- 我的倾向：**C3**（不改 schema，且「小于 7 天」正好覆盖文字稿上线的窗口）
- ⚠️ 三个都要配「**每轮限量的失败重试配额**」，否则重试会把新文章的抓取挤掉

### 建议顺序

**A（今天就能修好那 36 篇）→ B（先核实 summary 语义，再定阈值）→ C（自愈）**

---

## 四、顺带发现（不是本轮主题，但记下来）

1. **`iap_plan.dart:310` 的注释已过时** —— 它说「唯一的订阅权益『跨设备同步』**后端尚未实现**」，
   而云端同步**阶段 1 已实现**（`sync_handlers.rs` + 5 张表）。
   ⇒ 典型的「注释 ≠ 实现」，会让后来人误判（同族已记：注释里的声明须核验）。
2. **`MIN_EXTRACTED_CHARS = 300` 这条门槛的口径值得复盘** ——
   它的文档写「实测参考：NPR 正文 6800+ 字符 · ECNS 4700+ · Dev.to 3000+」，
   即**正常正文是 3000+**，而门槛设成 300（**差 10 倍**）。
   📌 阈值取「实测值的 1/10」时，它就不再是「正文门槛」，而是「非空门槛」——
   这与它注释里「只用来挡『明显不是正文』」的**意图不符**（626 字符的配件版明显不是正文，却过了）。

---

## 五、请白哥定

| # | 问题 | 我的建议 |
|---|---|---|
| ① | 存量 35 篇修不修？ | ✅ 修（方案 A，已验证 10/10）|
| ② | 质量判据怎么做？ | 先**核实各源 summary 语义**（半天），再定用「长度比」还是「配件特征」|
| ③ | 要不要延迟重抓？ | ✅ 要（方案 C3），否则明天继续产生新的 |
| ④ | **产品决策**：NPR 节目文字稿算好内容吗？ | ⚠️ **这条请你定** —— 文字稿含 `AYESHA RASCOE, HOST:` `(APPLAUSE)` `(SOUNDBITE OF ARCHIVED RECORDING)` 这类**舞台指示**。对英语学习是**真实口语素材**（好），但混着舞台指示（可能干扰）。要不要保留？要不要清洗？ |
