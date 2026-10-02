# 修「片段当全文」+ 打通存量重抓（2026-10-02）

> **一句话**：两个缺陷叠加，一个让 **Ars Technica 的 163 词片段被当成全文**（用户看到 `Read full article`），
> 另一个让**任何回填/换格式都做不了**（清标记也不会被重抓）。本次修两处 + 给出存量迁移。
>
> 📄 上游调查报告 → [`body-refetch-blocked-2026-10-02.md`](body-refetch-blocked-2026-10-02.md) · [`content-source-inventory-and-interests-2026-10-02.md`](content-source-inventory-and-interests-2026-10-02.md)
> **状态**：✅ 代码已改 · ✅ **本地断言全过（154 项）** · ✅ 证伪通过 · ⏳ **未部署**（等白哥构建 + 部署指令）

---

## 一、两个缺陷（各有独立根因）

### 缺陷 A：片段被当全文（`content_rss.rs`）

```rust
// 改动前
let longer = match summary {
    Some(s) => text.chars().count() > s.chars().count() + BODY_LONGER_THRESHOLD,
    None => true,     // 🔴 摘要缺失 ⇒ 恒真
};
```

Ars Technica 的 `content:encoded` 是 **161 词片段**（尾部 `Read full article` / `Comments`），
而它的 `description` 是 **14 词导读**、`<content:encoded>` 才是长文 —— 但**判据在摘要为空/过短时直接放行**。

实测（`tests/fixtures/arstechnica.xml`，20/20 条）：
```
…differences in behavior across experimental scenarios,” they found.Read full article
Comments
```

后果两条：
1. **用户可见**：正文尾部直接显示 `Read full article` / `Comments`
2. **更严重**：`body` 被填上片段 ⇒ 被缺陷 B 永久排除 ⇒ **永远不去抓网页全文**

### 缺陷 B：`body` 非空 ⇒ 永不重抓（`content_fetch.rs`）

```sql
WHERE … AND p.body_attempted_at IS NULL
        AND (p.body IS NULL OR p.body = '')      -- 🔴 就是它
```
而它的注释写着「**写了也不影响，只是多余**」——**这句是错的**（详见上游报告）。

⇒ 清掉 `body_attempted_at` 之后，「待重抓」看着 148 条，**真正会被挑中的只有 11–12 条**。

---

## 二、修复

### A：`extract_body` → `classify_encoded`（三重判据，返回三态）

| # | 判据 | 为什么 |
|---|---|---|
| ① | **强标记按子串**（`read full article` 等）| 源**自己声明**不是全文 —— 最可靠 |
| ② | **词数 < 300**（`MIN_FULL_BODY_WORDS`）| **绝对闸**；摘要缺失时唯一的防线 |
| ③ | 与摘要**量级相近**（原判据）| 同源时为摘要 + 样板差异 |

🔴 **③ 的关键修正**：`None => true` 改成 `None => false`（**缺基准时弃权**），
并显式排除空摘要 —— 否则「比 0 长」也恒真。

三态 `EncodedKind { Full, Excerpt, Absent }`，处理：

| 分类 | `body` | `summary` |
|---|---|---|
| `Full` | 全文 | 源的 description |
| **`Excerpt`** | **NULL** ✅ | **`better_summary(description, 片段)`** |
| `Absent` | NULL | 源的 description |

**`Excerpt` 为什么进 `summary` 而不是丢掉**：
- `body` 空 ⇒ **满足补抓条件** ⇒ 会去抓网页全文（缺陷 B 修好后）
- 内容不丢 ⇒ 用户仍在「摘要」位置读得到，且端侧会**如实**显示「只有摘要」

**`better_summary`**：在源摘要与片段之间**取更有用的**（要求片段 ≥2 倍且多 ≥50 词才替换）。
> 🔴 若不这么做：Ars 会从「161 词正文 + 怪异标记」掉到「**14 词导读**」——
> **修掉一个问题的同时制造一个更大的问题**。

### B：`pick_body_candidates` 加 `refetch_existing` 开关（**方案 A**）

```sql
AND (?2 = 1 OR p.body IS NULL OR p.body = '')     -- ?2 = 重抓模式
```
- 默认 `false` ⇒ 第一项为假 ⇒ **行为与改动前逐字相同**（现有调用零风险）
- `true` ⇒ 不再要求 `body` 为空 ⇒ 重置过标记的存量**真的会被挑中**
  （`body_attempted_at IS NULL` 仍生效 ⇒ 依然「每条只试一次」）

由 `COEVO_REFETCH_BODIES=1` 驱动（与上次临时加速同一手法：systemd drop-in、用完即删），
启动时打 **WARN** 日志提醒「用完要关」。

---

## 三、🔴 设计过程中被**真实数据**推翻了三次（都值得记）

| # | 我最初的判断 | 真实数据 | 影响 |
|---|---|---|---|
| 1 | 「片段标记**独立成行**」⇒ 整行匹配 | 标记**紧跟在正文最后一句后面**（20/20）| 整行匹配**一条都认不出来** ⇒ 改成子串 |
| 2 | 「Ars 的 `description` 是**空的**」| 它是 **14 词导读**（CDATA 包裹）| 我的测量脚本把 CDATA 内容一起剥掉了（**工具错，不是数据错**）|
| 3 | 「片段归档为摘要 ≈ 什么都不用改」| 若优先 description，Ars 掉到 **14 词** | 加 `better_summary` |

📌 判据：**判据的「理想化样本」与「真实数据」可能完全不同** ——
本次三个错都只有拿**真 fixture/真库**跑才会暴露（`import` 时我在合成样本上全绿）。

---

## 四、验证

| 检查 | 结果 |
|---|---|
| `cargo test -p api_server` | ✅ **154 项全过**（含 5 项新增） |
| 新增断言 | 5 条（见下） |
| 生产库 dry-run | ✅ 识别 **34 篇** body 实为片段（Ars 为主） |
| Python 侧判据（迁移脚本） | ✅ 20/20 识别、剥后 100–362 词、无残留标记 |

### 4.1 新增/改写的断言

| 断言 | 守什么 |
|---|---|
| `test_ars_encoded_is_excerpt_not_body` | 🔑 **替换了原来那条「把 bug 锁死」的断言**（原断言 `assert!(body.is_some())` + 注释「Ars feed 自带全文」）|
| `test_npr_encoded_is_excerpt_keeps_source_summary` | NPR 仍保留源摘要（不被片段覆盖）|
| `test_relative_criterion_must_not_be_vacuous_without_summary` | 🔴 原缺陷形态（无摘要 + 短 encoded）|
| `test_short_encoded_without_summary_is_excerpt_by_length_gate` | 绝对闸**独立**生效（不靠标记）|
| `test_long_encoded_without_summary_is_full` | **反向**：够长无标记 ⇒ 必须是全文（防误伤）|
| `test_excerpt_marker_must_be_whole_line_not_substring` | 正文提到 `read more` 不算标记 |
| `test_pick_candidates_default_skips_existing_body` | 🔴 默认行为**与改动前逐字相同** |
| `test_pick_candidates_refetch_mode_includes_existing_body` | 🔴 重抓模式真的挑中「有正文」的 |
| `test_refetch_mode_differs_only_by_body_condition` | 两模式**只差**那一个条件 |

### 4.2 证伪（证明断言不是恒真的）

对 5 处注入缺陷 → **5/5 目标断言如期报红**，还原后复跑全绿（154 项）：

| # | 注入 | 目标断言 |
|---|---|---|
| 0 | 相对判据 `None` 分支改回**恒真**（原缺陷写法）| `test_long_encoded_without_summary_is_full` |
| 1 | 关掉绝对长度闸 | `..._by_length_gate` |
| 2 | 关掉强标记检测 | `test_ars_encoded_is_excerpt_not_body` |
| 3 | 重抓模式开关失效 | `..._refetch_mode_includes_existing_body` |
| 4 | 不剥噪音行 | `test_ars_encoded_is_excerpt_not_body` |

⚠️ **第一次跑证伪时，我给 #0 挂的「目标断言」是错的**（挂到了
`test_relative_criterion_must_not_be_vacuous_without_summary`，而它**没红**）。
查出原因：**那条测试的样本同时带片段标记** ⇒ 标记闸会先兜住 ⇒
**任何一条闸失效它都还绿**（它对「相对判据恒真」不敏感）。

⇒ 真正能单独暴露它的，是「**无标记 + 够长 + 无摘要**」的样本
（`test_long_encoded_without_summary_is_full`）—— 此时唯一决定归属的就是那条相对判据。

📌 判据：**「有测试红了」≠「我指的那条测试红了」** ——
   证伪的目标必须是**具体断言名**，否则很容易把「别的测试顺手兜住了」当成「这条有覆盖」。
   反过来也说明：**多条闸指向同一结论时，要单独为每条闸准备样本**，
   否则一条坏了会被另一条掩盖。

### 4.3 ⚠️ 证伪工具自己也曾有个 bug（值得记）

用 `shutil.copy2` 还原会**保留较旧的 mtime** ⇒ cargo 认为「源码没变、无需重编」⇒
复跑用的还是**注入版**二进制 ⇒ 表现为「还原后仍然报红」（假红）。
⇒ 修法：还原后 `os.utime(path, None)` 强制刷新 mtime。

📌 判据：**「以为重跑了」≠「真的重跑了」** ——
   构建系统的时间戳语义会让它静默用旧产物（同族：本项目已记过
   `cargo test` 不重编 bin 那条）。

---

## 五、存量迁移（34 篇 Ars 片段）

新增脚本动作 `--demote-excerpt-bodies`（幂等、默认 dry-run）：

| 列 | 迁移前 | 迁移后 |
|---|---|---|
| `body` | 片段（含 `Read full article`）| **NULL** |
| `summary` | 14 词导读 | **片段**（剥掉标记）|
| `body_attempted_at` | 已设 | **NULL**（重新进候选队列）|

⚠️ **`body_attempted_at` 必须一起清** —— 否则 `body` 空了但「已试过」还在 ⇒ 仍不会被抓。
📌 判据：**改「内容列」时要连带检查「控制流列」**。

### 执行顺序（**顺序反了会白跑**）

```
① --demote-excerpt-bodies --apply          把已有的片段迁出来
② 开重抓模式（COEVO_REFETCH_BODIES=1）+ 重启
③ --reset-attempted --batch N --apply      分批清标记（现在能被挑中了）
④ 跑完立刻关掉重抓模式（删 drop-in + 重启）
```

---

## 六、⏳ 待办（等白哥）

| # | 事项 | 谁做 |
|---|---|---|
| 1 | **构建**（WSL 被安全策略禁，我跑不了）| 白哥 |
| 2 | 部署（❌ 未批准，不许动生产）| 待指令 |
| 3 | 执行存量迁移（按 §五 顺序）| 我可代跑，待指令 |
| 4 | 🔴 **Ars 抓不到全文**（文章页对两种 UA 都 **405**）⇒ 它只能停在「摘要」态 | 需产品决定：接受 / 换源 / 找镜像 |

### 附：一个已知的取舍

**Ars 的正文会从 161 词（含标记）变成 161 词（无标记、标为摘要）** ——
用户可读内容不变，但会看到「只有摘要」提示。这是**如实**的（我们确实只有片段），
且修好了「正文里出现 `Read full article`」。

⚠️ 若白哥认为「不该标成摘要」，替代方案是把片段留在 `body`（只剥标记）——
代价是**重新引入「body 非空 ⇒ 永不补抓」**（对 Ars 无实害，因为抓也抓不到，
但对**将来能抓全文的源**有害）。🔑 我选前者，因为**语义正确比少一个提示重要**。
