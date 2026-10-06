# 「正文夹杂链接」为什么没解决 —— 三个原因 + 一个新发现

> 2026-10-06 ｜ 白哥：「之前说的内容中夹杂链接的问题没有解决，这是什么原因」
>
> 样本：`content_pool.id = 7091` · *Temwa Chawinga is a soccer star at home and abroad*
> 生产库实测（SSH 直取，逐字节）：

```text
#### Temwa Chawinga is a soccer star at home and abroad

- [Download](https://ondemand.npr.org/anon.npr-mp3/npr/wesun/2026/10/…mp3?t=progseg&…)
- **Embed** ** `<**iframe src="https://www.npr.org/player/embed/nx-s1-5981387/nx-s1-9951305" width="100%" height="290" frameborder="0" scrolling="no" title="NPR embedded audio player">` **

The two-time MVP of the National Women's Soccer League is making waves with her team, the Current, in Kansas City and at home in Malawi.
```

⚠️ 先澄清一处：您贴的文本里有 `isasoccer` / `andabroad`（空格丢失）、`Src=`（大写 S）、
`frameborder="o"` —— **实测三个函数都不产生这些变形**（原文 title 与 body 的空格**都是完好的**）。
⇒ 那不是端侧 bug（应是把屏幕内容转成文字时的识别误差）。
📌 但您指出的**核心问题成立**：正文里确实还夹着 **Download 链接** 与 **iframe 播放器**。

---

## 原因 ①（主因）**我上一轮只出报告、没有实施修复**

上一轮我给的报告里列了三个方案（A 存量修复 / B 质量判据 / C 延迟重抓），
结论是「**按铁律先报告，等批准**」。您当时回的是：

> 「1、**保留**；2、过时，现在的考试模式是正确的。全面清查计划，更新文档，**将计划了但没有做的按计划执行**」

我把「**保留**」理解成「NPR 舞台指示不清洗」（那个问题问的是这个），
**没有把「方案 A 存量重抓」作为待批项明确复述一遍** ——
而「按计划执行」我执行的是**清查出的那 4 件待办**（阅读设置面板等），**不含内容质量修复**。

⇒ **结果：这件事从头到尾一行都没修。** 这是执行层面的失误：
**「给了方案」≠「确认了要不要做」** —— 我没有在收到「保留」时追问「那方案 A/B/C 要不要执行」。

## 原因 ② 端侧还有一层 bug（**我上一轮写的代码的缺陷**）—— ✅ 已修

朗读侧 `speechTextFromMarkdown` 对这段的处理**漏掉了 iframe**：

| 步骤 | 看到的文本 | 结果 |
|---|---|---|
| ① `_htmlTagRe` | `<**iframe …` —— `<` 后跟的是 `*`，**不是字母** | ❌ **不匹配**（HTML 清理空转）|
| ② `_inlineCodeRe` | 剥掉反引号 | ⇒ 内容 `**<**iframe …>` **暴露** |
| ③ `_boldRe` | 把 `**<**` 剥成 `<` | ⇒ **`<iframe …>` 成形，但 HTML 清理早已跑完** |

⇒ 朗读时会**逐字念出** `src` / `width` / `frameborder` / `scrolling`。
**92 项断言全绿** —— 因为没有一条用例是「**标记内部藏着 HTML 标签**」这个形态。

✅ **已修**（`_stripInline` 末尾加「迭代到稳定」的第二轮结构性清理），
新增 **11 项断言** + 证伪（删掉第二轮 ⇒ 红 7 项）。断言总数 92 → **103**。

## 原因 ③（根因）**后端抓取层没有「配件清理」这一步**

`content_extract.rs` / `content_fetch.rs` 实测：

```bash
$ grep -n "Download\|Embed\|iframe\|ondemand" content_extract.rs content_fetch.rs
(空 = 没有清理)
```

NPR 在**正文区（`storytext`）内部**放了一个「Download / Embed」播放器工具条，
Readability 把它当正文一起抽出来了 ⇒ 原样入库 ⇒ **所有消费者都拿到这份脏数据**
（App 渲染 / 朗读 / 将来的任何用途）。

📌 这是**根因层**：端侧修的是"朗读别念出来"，但**渲染出来的正文里仍有那两行**。

---

## 🆕 顺带发现：**标题显示了两次**

`body` 首行是 `#### Temwa Chawinga is a soccer star at home and abroad`，
而 `_ReaderHead` **已经**显示了 `item.title`（内容**逐字相同**）⇒ 阅读页标题**重复**。
（这正好解释了您贴的前两行 —— 它们是同一个标题的两个来源。）

---

## 修复方案（**② 已做，①③④ 已实施**）

| # | 内容 | 状态 |
|---|---|---|
| **②** | 端侧朗读：剥标记后新暴露的 HTML/URL 再清一轮 | ✅ **已修**（103 项断言 · 证伪通过）|
| **B** | **后端配件清理**（根因） | ✅ **已实施**（见 §实施记录）|
| **D** | **去重标题** | ✅ **已实施**（同一层做 —— 抓取层是所有消费者的共同上游）|
| **C** | **延迟重抓**（防新文章继续进坑） | ✅ **已实施**（重试窗口 + 独立配额）|
| **A** | **存量重抓** | 📄 步骤已备好 → `docs/operations/content-body-refetch-2026-10-06.md`（⏳ **需部署后才能执行**）|

---

## 六、实施记录（2026-10-06）

### B · 后端配件清理（`content_extract.rs`）

新增 `strip_media_furniture(md)`，在 `extract_to_markdown` 末尾调用（**接线有测试守**）。

**四条规则**（保守 —— 宁可留一行，不误删正文）：

| # | 规则 | 实测覆盖 |
|---|---|---|
| 1 | 删**媒体类** HTML 标签（`iframe/audio/video/embed/object/source/track/param`）| `- **Embed** … <iframe …>` |
| 2 | **媒体链接**（`.mp3/.m4a/.ogg/.wav/.mp4/ondemand.`）**整个删**（连按钮文案）| `- [Download](…ondemand…mp3)` |
| 3 | 该行只剩标记字符与空白 ⇒ 删整行 | 同上（删完剩 `-`）|
| 4 | 该行剩下 ∈ `{embed,download,play,listen,watch}` ⇒ 删整行 | `**Embed**` |

🔴 **规则 3 与 4 缺一不可**：只做 1+2 会留下 `Embed`（端侧第一版就漏了它）。

**明文不删**：正文里提到 URL 的句子 · 围栏代码块内的标签 · 非媒体标签（`<div>`/`<code>`）。

**踩到的两个坑（都记进注释了）**：
1. `<**iframe` —— `<` 与标签名之间**夹着标记** ⇒ 正则要允许 `[*`_~\s]{0,4}`
   （比「先剥标记再删标签」安全：后者会改动整行）
2. 🔴 初版把**所有链接**都剥成文字 ⇒ **撞红了既有测试** `test_md_relative_links_absolutized`
   ⇒ 改为「**只处理媒体链接**，普通链接原样保留」
   📌 判据：**别顺手做「看起来也是清理」的事** —— 越界就会撞既有契约

### D · 标题去重（`content_extract.rs` + `content_fetch.rs`）

新增 `strip_duplicate_title(md, title)`：**首个非空行**是 Markdown 标题且与 `title` 逐字相同 ⇒ 删该行。

- 在 `fetch_bodies_round` 里应用（需要 `title` ⇒ `pick_body_candidates` 多返回一列）
- 🔑 **为什么在抓取层**（而非端侧渲染时跳过首行）：端侧做的话**每个消费者各写一遍**
  （阅读器 / 朗读 / 将来用途），漏一个就重现 —— 而这里是**共同上游**
- 刻意保守：首行是**普通段落**（非 `#` 标题）时**不删**

### C · 延迟重抓（`content_fetch.rs`）

新增 `pick_body_retry_candidates` + 常量（`BODY_RETRY_MIN_GAP_HOURS=12` ·
`BODY_RETRY_WINDOW_DAYS=7` · `MAX_BODY_RETRY_PER_ROUND=20` · `BODY_RETRY_SUSPECT_MAX_CHARS=3000`）。

**四个条件缺一不可**：已尝试过 · 距上次 ≥ 12h · 发布 ≤ 7 天 · 正文为空或 < 3000 字符。

- 🔴 **独立配额**：与新条目通道**分开**（否则重试会挤掉新内容 —— 新鲜度更值钱）
- 🔴 **必须有时间窗上界**：否则「源站本来只有摘要」的短新闻会被**永久**重试
- 🔑 `utc_iso_ago()` 而**不是** SQL `datetime('now','-12 hours')` ——
  后者返回 `2026-10-06 05:26:15`（空格、无 `Z`），与库里的 `…T…Z` **字符串序相反**
  ⇒ 比较会判反（同族：「时间戳按语义不按字符串」）

### 存量影响（实测）

- **配件型 41 篇**（含 `Embed`/`ondemand`/`iframe` 且 < 3000 字符）
- C 上线后**会自动重试 214 篇**（含这 41 篇中 10-01 之后的）⇒ **C 不只治未来，还自动修大部分存量**
- ⚠️ 但**渐进**：每轮配额 20、每轮 6h ⇒ 214 篇 ≈ **3 天**跑完
- ⇒ A 的价值 = 「立刻生效」+「覆盖已超窗的 1 篇（09-29）」

### 验证

- `cargo test -p api_server`：**260 passed / 0 failed**（+9）
- `cargo fmt --all --check`：干净
- 新增测试 **11 项**（10 项单测 + 1 项**接线测试**）
- 证伪：**8/8**（见 `content_extract.rs` / `content_fetch.rs` 的注释）
- ⚠️ **本地 clippy 不可作 CI 判据**：本地 rustc **1.95.0**，CI 钉 **1.98.0**
  （且本地 `student_llm` 上撞了 clippy ICE —— 工具链 bug，与本次改动无关）
  → 已确认「本次改动的文件无 clippy warning」，但**最终以 CI 为准**

🔴 **过程中一次真实事故（值得记）**：一次前台证伪**超时被 SIGTERM** ⇒
   `finally` **不执行** ⇒ **注入状态残留在源码里**（`is_furniture` 少了词表规则）。
   是后来跑测试才发现（`Embed 未清` 断言红）。
   ⇒ 📌 **判据：证伪/注入类脚本必须「自愈式」** ——
     把原始内容**落盘备份**，每轮**先从备份恢复**，并在**收尾再跑一次基线校验**；
     不能只靠 `finally`（进程被杀时它不跑）。


---

## 您可能想问：为什么不能一次修好

因为**三层各有各的职责**，且第三层（后端）要**部署 + 存量重抓**才生效：

```
① 抓取层（后端 · 根因）→ 决定「正文里有什么」   ⇒ 需部署 + 重抓存量
② 端侧朗读（已修）      → 决定「念出来什么」     ⇒ 已在包里
③ 渲染层（端侧）        → 决定「显示成什么」     ⇒ 依赖 ① 的数据
```

⇒ 只在端侧修，**渲染出来的正文里那两行依然在**（您看到的就是这个）。
要让它消失，**必须在 ①**（或端侧再加一道"渲染前过滤"，但那是把内容治理放到显示层，不推荐）。
