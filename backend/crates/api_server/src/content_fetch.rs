//! 内容抓取器 —— HTTP 抓取 + 幂等入库
//!
//! # 分层（与 `content_rss` / `content_hn` 的分工）
//!
//! | 层 | 文件 | 职责 | 能否独立验证 |
//! |---|---|---|---|
//! | 解析 | `content_rss` / `content_hn` | 原始响应 → `ParsedItem` | ✅ 纯函数（真实 fixture 断言） |
//! | **抓取** | **本文件** | HTTP + 入库 + 失败处置 | 🟠 需要网络/DB |
//! → 🔑 **把「容易错的语义」都放在纯函数层**，本层只做「拿回来、写下去」。
//!
//! # 🔴 两条必须遵守的工程约束
//!
//! ## ① **`await` 期间不持有 DB 连接**
//! `crate::db_pool::get_conn()` 返回的是**池里的一个连接**（RAII guard）。
//! 若把它一路带着穿过 `await`，网络慢时会把池里的连接**占住不放** ——
//! 而抓取是「5 个源 × 每个几十秒」的长时间任务 → 池被抽干、**其它接口全部排队**。
//! → 结构上分成两段：**先异步抓（不碰 DB）→ 再同步写（不跨 await）**。
//!   （`llm_card.rs` 有一模一样的注释，那里是「LLM 调用要 3–5 秒」。）
//!
//! ## ② 幂等靠 **`UNIQUE(url)` + `INSERT OR IGNORE`**，不靠「先查再插」
//! 「先 SELECT 看存不存在，再 INSERT」在**并发/重复运行**下是经典竞态
//! （两个执行体同时查到「不存在」→ 都插入）。
//! → 交给数据库的唯一约束，`INSERT OR IGNORE` 是原子的。
//! 🔑 而「这次到底插进去几条」用 `execute` 的**返回值**取（受影响行数），
//!    **不用** `SELECT changes()` —— 后者是**连接级**的，池里连接会被复用，
//!    拿到的可能是**上一条无关语句**的改动数。

use rusqlite::Connection;

use crate::content_rss::{self, ParsedItem};

/// 抓取用的 UA。
///
/// # 🔴 本值**不能**包含 `://`（2026-09-29 实测定位）
///
/// 原先写的是业界惯例形式：`CoEvo/1.0 (+https://keyievolution.fun; English learning app)`
/// —— RFC 9110 建议 UA 里带联系人 URL。**但实测它会静默失败**：
///
/// | UA | NPR 文章页 3 次结果 |
/// |---|---|
/// | `CoEvo/1.0` | ✅ 200 200 200 |
/// | `CoEvo/1.0 (keyievolution.fun)` | ✅ 200 200 |
/// | `CoEvo/1.0 English learning app` | ✅ 200 200 |
/// | `CoEvo/1.0 (+https://example.com)` | 🔴 **000 000**（换域名也失败）|
/// | `CoEvo/1.0 (+https://keyievolution.fun)` | 🔴 **000 000** |
/// | `CoEvo/1.0 +https://keyievolution.fun` | 🔴 **000**（无括号也失败）|
///
/// → 变量隔离后**唯一触发条件就是 UA 里出现 `https://`**（不是域名、不是括号、不是长度）。
///   表现是**连接被静默断开**（curl 报 `000` 超时，**不是** 403）——
///   这正是最难排查的那种：看起来像「网络问题」。
///
/// ⚠️ 影响面：只有 NPR 出现（它的 CDN/WAF 这么处理）；ECNS / Dev.to / HN 同 UA 正常。
///    所以别把它当成「全站通用规律」，但也**别把 `://` 加回来**。
///
/// # 为什么用 `Mozilla/5.0 (compatible; …)` 而不是裸 `CoEvo/1.0`
/// `compatible` 是 RFC 里为**非浏览器客户端**准备的关键字 ——
/// 既让站点知道「这不是浏览器」，又不至于因为「UA 不以 Mozilla 开头」被一部分站点拦。
/// 实测两者都能过 NPR；取兼容性更好的这个。
/// 🔑 **没有伪装**：`CoEvo/1.0` 明确标识了身份，只是不带 URL。
const USER_AGENT: &str = "Mozilla/5.0 (compatible; CoEvo/1.0)";

/// 单次 HTTP 超时（秒）。
const HTTP_TIMEOUT_SECS: u64 = 20;

/// 一个内容源（`content_source` 的一行，只取抓取需要的列）。
#[derive(Debug, Clone)]
pub struct SourceRow {
    pub id: i64,
    pub name: String,
    pub url: String,
    /// `rss` | `hn`
    pub kind: String,
    pub category: Option<String>,
    /// 1 = 允许存全文；0 = 只存摘要（Flipboard 模式）
    pub redistributable: i64,
    /// 源的时间戳**不带时区**时按此偏移解释（分钟；东八区 = 480）
    /// ⚠️ 实测 ECNS 用的就是不带时区的格式 —— 见 `content_rss::parse_pub_date`
    pub tz_offset_min: i32,
}

/// 一个源的抓取结果。
#[derive(Debug)]
pub struct FetchOutcome {
    pub source_id: i64,
    pub source_name: String,
    /// 拿到几条
    pub items: usize,
    /// **真正新入库**几条（幂等：重复的会被忽略）
    pub inserted: usize,
    /// `None` = 本轮成功
    pub error: Option<String>,
}

/// 读**启用**的源。
pub fn load_enabled_sources(conn: &Connection) -> Result<Vec<SourceRow>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, url, kind, category, redistributable, tz_offset_min \
             FROM content_source WHERE enabled = 1 ORDER BY id",
        )
        .map_err(|e| format!("prepare content_source: {}", e))?;
    let rows = stmt
        .query_map([], |r| {
            Ok(SourceRow {
                id: r.get(0)?,
                name: r.get(1)?,
                url: r.get(2)?,
                kind: r.get(3)?,
                category: r.get(4)?,
                redistributable: r.get(5)?,
                tz_offset_min: r.get(6)?,
            })
        })
        .map_err(|e| format!("query content_source: {}", e))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("collect content_source: {}", e))
}

/// 抓一个源 → `ParsedItem` 列表（**不碰 DB**，见模块头 ①）。
pub async fn fetch_source_items(src: &SourceRow) -> Result<Vec<ParsedItem>, String> {
    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .map_err(|e| format!("建 HTTP 客户端失败: {}", e))?;

    match src.kind.as_str() {
        "rss" => {
            let body = http_get_text(&client, &src.url).await?;
            content_rss::parse_rss(&body, src.tz_offset_min)
        }
        // 🔴 2026-10-03 白哥决定**放弃 HN**（见 `schema.rs` seed 里 HN 行的说明）。
        //    这里**不保留 `"hn"` 分支** —— 若有人把 HN 重新 `enabled=1`，
        //    会走下面这条 `other` 分支**明确报错**（而不是静默返回空）。
        //    📌 判据：**去掉能力时，要让「重新启用」立刻可见地失败**，
        //       而不是留一段没人维护的分支假装还支持。
        other => Err(format!("未知的源类型 `{}`（目前只支持 rss）", other)),
    }
}

async fn http_get_text(client: &reqwest::Client, url: &str) -> Result<String, String> {
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("请求失败 {}: {}", url, e))?;
    let status = resp.status();
    if !status.is_success() {
        return Err(format!("HTTP {} @ {}", status.as_u16(), url));
    }
    resp.text()
        .await
        .map_err(|e| format!("读响应失败 {}: {}", url, e))
}

/// 词数（用于生词密度参考）。
///
/// 判据：按**空白切分**后数非空片段。英文源足够；
/// ⚠️ 对中文（ECNS 有中文标题）会偏大 —— 但本列是**参考值**，
/// 且不参与任何判定（只展示），故不引入分词依赖。
pub fn count_words(text: &str) -> i64 {
    text.split_whitespace().filter(|w| !w.is_empty()).count() as i64
}

/// 把条目写入内容池（**幂等**，见模块头 ②）。返回真正新入库的条数。
pub fn write_items(
    conn: &Connection,
    src: &SourceRow,
    items: &[ParsedItem],
    now_utc: &str,
) -> Result<usize, String> {
    let mut inserted = 0usize;
    for it in items {
        // ── 🆕 2026-10-03 内容质量闸门（见 `content_quality` 模块）──
        //
        // 🔑 为什么放在**这一层**（`write_items` 是所有源的**唯一入库点**）：
        //    守门人放在「参数化的点」上，新接一个源就自动受保护；
        //    若放在各源自己的解析函数里，将来必忘（同族教训：`unescape` 只接了一处，
        //    另一处渲染路径就漏了）。
        //
        // ⚠️ 判据用「**抓到了什么**」（`it.body` 优先，退回 summary），而不是
        //    「打算存什么」（`body` 变量受 `redistributable` 影响）——
        //    否则 `redistributable = 0` 的源会**绕过**闸门。
        //
        // 🆕 2026-10-03 新增第三类判据：**URL 形态**（非 HTML 文档 → 直接不入库）。
        //    🔑 它堵的是**乱码判据的盲区** —— 实测 4 条 PDF 里只有 2 条带乱码，
        //       另 2 条是 `body = 0`（没有乱码 ⇒ 乱码判据看不见）。
        //       按 URL 过滤覆盖 4/4。
        //    📄 详见 `content_quality::NON_HTML_EXTENSIONS` 的说明。
        let gate_text = it.body.as_deref().or(it.summary.as_deref()).unwrap_or("");
        if let Some(reason) = crate::content_quality::check_content(&it.title, gate_text, &it.url) {
            tracing::info!(
                "content_fetch: 跳过条目（{}）· {} — {}",
                reason,
                src.name,
                it.title
            );
            continue;
        }

        // 🔴 `redistributable = 0` 的源**不存全文** —— 列的含义就是「能不能存全文」，
        //    不能因为「刚好抓到了」就存（那会让这一列失去意义）。
        let body = if src.redistributable == 1 {
            it.body.as_deref()
        } else {
            None
        };

        // 🆕 2026-10-02：源站的**报错信息**不该被当摘要存（见 `is_source_error_summary`）
        let summary = sanitize_summary(it.summary.as_deref());

        let wc = count_words(&format!(
            "{} {} {}",
            it.title,
            summary.unwrap_or(""),
            body.unwrap_or("")
        ));

        let n = conn
            .execute(
                "INSERT OR IGNORE INTO content_pool \
                 (source_id, title, summary, body, url, author, category, \
                  published_at, fetched_at, word_count) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                rusqlite::params![
                    src.id,
                    it.title,
                    summary,
                    body,
                    it.url,
                    it.author,
                    // 🔑 分类取**源配置**（受控词表）而不是 RSS 的自由标签 —— 见 `ParsedItem` 的说明
                    src.category,
                    it.published_at,
                    now_utc,
                    wc,
                ],
            )
            .map_err(|e| format!("插入 content_pool 失败 ({}): {}", it.url, e))?;
        inserted += n;
    }
    Ok(inserted)
}

// ─────────────────────────────────────────────────────────────────────
// 🆕 2026-10-02 · 过滤「源站渲染失败」的摘要
// ─────────────────────────────────────────────────────────────────────

/// 明显是**源站自己渲染失败**的摘要 —— 命中则视为「没有摘要」。
///
/// # 🔴 为什么需要它（真实案例，不是防患于未然）
/// 白哥真机反馈里有一篇「只有半句话」，实测其 `content_pool.summary` 是：
/// ```text
/// Liquid syntax error: 'raw' tag was never closed
/// ```
/// 那**不是文章摘要，是源站自己的模板报错** —— Dev.to 渲染那篇失败，
/// RSS 的 `<description>` 里给的就是这句。而**端侧在 `body` 为空时会兜底显示摘要**
/// → 用户看到的「半句话」就是它。
///
/// # 🔴 判据为什么是「指纹 + 长度」**两条一起**
/// · 只用指纹 → 正常文章里也可能出现 `syntax error`（讲编译错误的教程）→ **误杀**
/// · 只用长度 → 短摘要本身合法（一句话新闻）→ **误杀**
/// · **同时成立**才算：**又短、又长得像框架报错**
/// 📌 判据形状同族：**单信号判据易整类误判，要加互补信号**（见 memory「判据库」）
///    —— 这里的互补信号是**长度**，它把「讨论报错的文章」排除在外（那类文章长）。
///
/// # 诚实边界
/// 这是**黑名单**（已知指纹），不是「能检测一切源站错误」。
/// 遇到新形态要**加指纹** —— [SOURCE_ERROR_FINGERPRINTS] 是唯一改动点。
pub fn is_source_error_summary(s: &str) -> bool {
    /// 「摘要」短过这个长度才可能是报错信息。
    ///
    /// 依据：真正文摘要通常 ≥ 60 字符（一句话摘要）；而报错信息是**一句短话**。
    /// 取 200 很松 —— 它只用来把「长文章里出现 error 字样」排除掉。
    const MAX_ERROR_SUMMARY_CHARS: usize = 200;

    let t = s.trim();
    if t.is_empty() {
        return false;
    }
    if t.chars().count() > MAX_ERROR_SUMMARY_CHARS {
        return false;
    }
    let lower = t.to_lowercase();
    SOURCE_ERROR_FINGERPRINTS.iter().any(|p| lower.contains(p))
}

/// 已知的「源站模板/框架报错」指纹（**全部小写**，用 `contains` 匹配）。
///
/// ⚠️ 只放**明确无歧义**的：宁可漏拦，也不误杀正常摘要。
/// （实测案例是第一条；其余几条是同族形态，一并挡掉。）
/// 🔴 新增指纹时**放宽要谨慎**：泛化的词（如 `"error"` / `"undefined"`）会误杀。
const SOURCE_ERROR_FINGERPRINTS: &[&str] = &[
    // Dev.to / Jekyll 的 Liquid 模板引擎（**实测命中**）
    "liquid syntax error",
    "was never closed",
    // 通用模板渲染失败
    "template render error",
    "an error occurred while rendering",
    // JS 渲染失败（SPA 类站点把报错吐在 description 里）
    "cannot read propert", // 覆盖 properties / property
];

/// 摘要入库前的清洗：命中的**当成没有摘要**。
///
/// 🔑 返回 `None`（而不是空串）—— 端侧据此**不会**把它当内容显示，
///    而是走「这一篇还没有正文」那条正常分支。
pub fn sanitize_summary(summary: Option<&str>) -> Option<&str> {
    match summary {
        Some(s) if s.trim().is_empty() => None,
        Some(s) if is_source_error_summary(s) => {
            tracing::debug!(
                "content_fetch: 丢弃源站报错摘要: {:?}",
                &s.chars().take(80).collect::<String>()
            );
            None
        }
        other => other,
    }
}

/// 更新源的抓取状态（成功/失败都要更新 —— 否则失败的源会被反复重试却不留痕）。
pub fn touch_source(
    conn: &Connection,
    source_id: i64,
    ok: bool,
    now_utc: &str,
) -> Result<(), String> {
    let sql = if ok {
        "UPDATE content_source SET last_fetch_at = ?1, fail_count = 0, updated_at = ?1 WHERE id = ?2"
    } else {
        "UPDATE content_source SET last_fetch_at = ?1, fail_count = fail_count + 1, updated_at = ?1 WHERE id = ?2"
    };
    conn.execute(sql, rusqlite::params![now_utc, source_id])
        .map_err(|e| format!("更新源状态失败 id={}: {}", source_id, e))?;
    Ok(())
}

/// 抓一轮（**所有启用的源**）—— 每个源独立成败，互不阻断。
///
/// 🔴 返回 `Vec<FetchOutcome>`（含失败项）而**不是** `Result<Vec<_>>`：
///    「A 源失败」不该让调用方以为「整轮失败」，
///    也不该让 B/C 源的结果被丢弃。失败信息**逐源**表达。
pub async fn fetch_all(now_utc: &str) -> Vec<FetchOutcome> {
    let sources = {
        let conn = crate::db_pool::get_conn();
        match load_enabled_sources(&conn) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("content_fetch: 读内容源失败: {}", e);
                return Vec::new();
            }
        }
    };

    let mut out = Vec::with_capacity(sources.len());
    for src in sources {
        let fetched = fetch_source_items(&src).await;
        // 🔑 到这里才碰 DB（见模块头 ①：await 期间不持有连接）
        let (items, inserted, error) = match fetched {
            Ok(items) => {
                let conn = crate::db_pool::get_conn();
                match write_items(&conn, &src, &items, now_utc) {
                    Ok(n) => (items.len(), n, None),
                    Err(e) => (items.len(), 0, Some(e)),
                }
            }
            Err(e) => (0, 0, Some(e)),
        };

        {
            let conn = crate::db_pool::get_conn();
            if let Err(e) = touch_source(&conn, src.id, error.is_none(), now_utc) {
                tracing::warn!("content_fetch: 更新源状态失败: {}", e);
            }
        }

        match &error {
            None => tracing::info!(
                "content_fetch: {} 拿到 {} 条 · 新增 {} 条",
                src.name,
                items,
                inserted
            ),
            Some(e) => tracing::warn!("content_fetch: {} 失败: {}", src.name, e),
        }
        out.push(FetchOutcome {
            source_id: src.id,
            source_name: src.name,
            items,
            inserted,
            error,
        });
    }
    out
}

/// 一次抓取里最多补抓多少篇正文。
///
/// # 🔴 这个数必须 > 「每轮新增条数」，否则存量永远补不完
///
/// 实测（2026-09-29）：一轮 feed 抓取新增 **~200 条**（ECNS 100 + HN 60 + Ars 20 + …），
/// 而抓正文是**每轮限量**的。若限量 = 25、间隔 6h（一天 4 轮）→ 一天只补 **100 篇**
/// ⇒ **每天欠 100 篇** → 可读率会**持续下降**，且永远追不上。
///
/// → 取 **100**：一天 4 轮可补 400 篇 > 新增 200 篇 ✅ 存量会**逐步**被吃掉。
///
/// # 为什么是 100 而不是更大
/// · 对源站的礼貌：100 篇分散在 5 个源 ≈ 每源 20 个请求/轮
///   （正常用户翻几页也会产生这个量级）
/// · 耗时：实测约 **1–2 秒/篇**（串行）→ 100 篇 ≈ 2–3 分钟，
///   远小于 6 小时间隔 ✅
///
/// 🔑 判据：**任何「按缺失挑候选」的批处理，限量必须 ≥ 每轮新增** ——
///    否则它不是「分摊到多轮」，而是**永远落后**。
pub const MAX_BODY_FETCH_PER_ROUND: usize = 100;

/// 内容保留天数（白哥 2026-10-02 定：「存量不要，太多内容没有意义」）。
///
/// `COEVO_CONTENT_RETENTION_DAYS` 覆盖；`0` = **不清理**。
///
/// # 🔴 为什么是「保留期」而不是「全清」
/// 「太多内容没有意义」不等于「一条都不留」—— 读者仍需要一个**可翻的积压**
/// （今天没读完的，明天还在）。保留期同时满足两件事：
/// ① 信息流保持新鲜（旧的自然消失）② 库不会无限增长。
///
/// # 为什么用 `fetched_at` 而不是 `published_at`
/// 🔴 实测：**有些源的条目本身就是旧的**，用 `published_at` 会「刚抓到就被删」：
/// · Dev.to 的 RSS 里有 2020 年的热门老文
/// · Smashing 的 40 条跨度 **156 天**（最新 09-30，最旧 04-27）
/// ⇒ 用 **`fetched_at`（我们拿到它的时刻）** 语义更准：
///    「这条内容我们保留了多久」——与「源给的是什么日期」无关。
pub const DEFAULT_CONTENT_RETENTION_DAYS: i64 = 30;

/// 每轮清理的**上限条数**。
///
/// 🔑 为什么要限量：第一次生效时可能积压很多（或将来某轮抓得特别多），
///    一次性 `DELETE` 几万行会**长时间持有写锁**（SQLite 单写者模型）
///    ⇒ 同一时间其它写入（抓取入库）会被挡住。
///    分轮小批删除：每轮最多 500，4 轮/天 = 2000/天 的清理吞吐，
///    远大于稳态新增（约 600/天）⇒ 足够，且不会长时间锁库。
pub const PRUNE_BATCH_PER_ROUND: usize = 500;

/// 补抓正文：挑「有 url、允许全文、还没试过」的条目。
///
/// # 查询条件的含义
/// ```sql
/// WHERE redistributable = 1 AND body_attempted_at IS NULL AND url <> ''
///   AND (?2 = 1 OR body IS NULL OR body = '')      ← ?2 = 重抓模式
/// ORDER BY COALESCE(published_at, fetched_at) DESC LIMIT ?
/// ```
/// · `redistributable = 1` —— 按源控制（`redistributable = 0` 的源**有意只存摘要**）
/// · `body_attempted_at IS NULL` —— **只试一次**（见 `content_pool.body_attempted_at` 的说明）
/// · **按时间倒序** —— 先抓最新的（用户最可能读到的那批）
///
/// # 🔴🔴 `(body IS NULL OR body = '')` 与「重抓模式」
///
/// ## 这条注释曾经写错（2026-10-02 实测定案）
///
/// 原文写的是「**不筛 `body IS NULL`**……两个条件叠加就够，不必再写 `body IS NULL`
/// （**写了也不影响，只是多余**）」。**「写了也不影响」这句是错的**：
///
/// | 场景 | `body` 为空？ | 加了这条有影响吗 |
/// |---|---|---|
/// | **常规补抓**（第一次抓某条没有正文的）| 是 | ❌ 无影响（本来就该抓）|
/// | **存量重抓**（想让已有正文的换格式/重取）| **否** | 🔴 **致命 —— 永远抓不到** |
///
/// 写这段注释时只想了场景 1。实测代价：清掉 328 条的 `body_attempted_at` 之后，
/// 「待重抓」看着是 148 条，而**真正会被挑中的只有 11–12 条** ——
/// 其余 136 条因为「**已有正文**」被永久排除，**且全程零报错**。
///
/// ## 所以加 `refetch_existing` 开关（而不是删掉那个条件）
///
/// · **默认 `false`** ⇒ SQL 里 `(?2 = 1 OR …)` 的第一项为假 ⇒ **行为与改动前逐字相同**
///   （现有调用方零风险）
/// · `true` ⇒ 不再要求 `body` 为空 ⇒ 重置过标记的存量**真的会被挑中**
///   （`body_attempted_at IS NULL` 仍然生效 ⇒ 依然「每条只试一次」，不会反复抓）
///
/// 由 [`refetch_existing_enabled`]（环境变量 `COEVO_REFETCH_BODIES=1`）驱动，
/// 只在「存量迁移窗口」临时打开、跑完立刻关。
///
/// 📌 判据：**改「下游怎么筛输入」时，要让旧行为成为默认值** ——
///    同一个函数同时服务两种语义时，用**参数**把差异显式化，别靠调用方记着改。
pub fn pick_body_candidates(
    conn: &Connection,
    limit: usize,
    refetch_existing: bool,
) -> Result<Vec<(i64, String)>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT p.id, p.url FROM content_pool p \
             LEFT JOIN content_source s ON s.id = p.source_id \
             WHERE COALESCE(s.redistributable, 0) = 1 \
               AND p.body_attempted_at IS NULL \
               AND p.url <> '' \
               AND (?2 = 1 OR p.body IS NULL OR p.body = '') \
             ORDER BY COALESCE(p.published_at, p.fetched_at) DESC \
             LIMIT ?1",
        )
        .map_err(|e| format!("prepare body candidates: {}", e))?;
    let rows = stmt
        .query_map(
            rusqlite::params![limit as i64, refetch_existing as i64],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
        )
        .map_err(|e| format!("query body candidates: {}", e))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("collect body candidates: {}", e))
}

/// 「重抓模式」开关 —— `COEVO_REFETCH_BODIES=1` 时为真（**默认关**）。
///
/// 见 [`pick_body_candidates`] 的「重抓模式」一节。用途只有一个：
/// **把已重置抓取标记的存量重新抓一遍**（换提取器 / 换格式 / 补漏）。
///
/// ⚠️ 用完**必须关掉**（删掉环境变量并重启）—— 否则每轮都会去抓
///    「已经有正文但还没试过」的条目（正常运行时那批应该是空的，代价不大，
///    但语义上「重抓」不该是常态）。
pub fn refetch_existing_enabled() -> bool {
    std::env::var("COEVO_REFETCH_BODIES")
        .map(|v| v.trim() == "1")
        .unwrap_or(false)
}

/// 内容保留天数（`COEVO_CONTENT_RETENTION_DAYS`；`0` = 不清理）。
///
/// 解析失败或没设 → 用 [`DEFAULT_CONTENT_RETENTION_DAYS`]。
/// ⚠️ 负数当作 `0`（不清理）—— 避免「手滑写负数」导致把 `-(-1) days` 拼成
///    `--1 days` 这种非法 SQL 修饰符（那样会**每轮报错**，还不好查）。
pub fn content_retention_days() -> i64 {
    std::env::var("COEVO_CONTENT_RETENTION_DAYS")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .unwrap_or(DEFAULT_CONTENT_RETENTION_DAYS)
        .max(0)
}

/// 清理超过保留期的内容，**每轮限量**。返回本轮删除条数。
///
/// # 语义
/// 删的是「**我们拿到它已超过 `days` 天**」的条目（按 `fetched_at`，理由见常量注释）。
///
/// # 🔴 删之前查过「谁在读它」（判据：删之前三问）
/// · **端侧 `bookmark.content_id` / `article_read.article_id` 都指向 `content_pool.id`**
///   ⇒ 删行后那两条记录会**悬空**。
/// · ✅ **id 不会复用**：本表用 `AUTOINCREMENT`（`schema.rs` 有专门说明），
///   所以**不会出现「旧收藏静默指向新文章」**这类最难查的错。
///   📌 那句注释当时就是**为保留期清理预留的**（原文：「若内容池做保留期清理…」）。
/// · ⚠️ **但仍会「点开收藏打不开」**（端侧没有正文缓存，阅读页是联网取的）。
///   当前 **零真实用户**（生产库 `users` 仅 1 行 trial）⇒ 现在无影响；
///   若将来做「离线阅读 / 收藏缓存正文」，这条风险自然消失。
///   📄 已记入 `docs/review/source-onboarding-2026-10-02.md`
///
/// # 幂等
/// 重复调用是安全的：第二次没有更旧的行 → 返回 0。
pub fn prune_old_content(conn: &Connection, days: i64, batch: usize) -> Result<usize, String> {
    if days <= 0 {
        return Ok(0);
    }
    let modifier = format!("-{} days", days);
    let n = conn
        .execute(
            // ⚠️ 用 `id IN (SELECT ... LIMIT)` 而不是 `DELETE ... LIMIT`：
            //    后者需要 SQLite 编译时开 `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`，
            //    不能假定构建环境有（跨平台/不同发行版不一致）。
            "DELETE FROM content_pool WHERE id IN (                SELECT id FROM content_pool                 WHERE fetched_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?1)                 ORDER BY fetched_at ASC LIMIT ?2              )",
            rusqlite::params![modifier, batch as i64],
        )
        .map_err(|e| format!("prune content_pool: {}", e))?;
    Ok(n)
}

/// 写入抓到的正文 + **无论成败都记下尝试时间**。
///
/// [body] 为 `None` = 这次没拿到正文（页面拿不到 / 结构不匹配 / 正文太短）——
/// 仍然写 `body_attempted_at`，避免下轮重复尝试。
///
/// 🔑 写 `body_attempted_at` 与写 `body` **在同一个 `execute` 里**：
///    分成两条语句的话，中间失败会出现「记了尝试但没写正文」或反之 ——
///    两者都会让「只试一次」的语义**静默变形**。
pub fn save_body(
    conn: &Connection,
    id: i64,
    body: Option<&str>,
    now_utc: &str,
) -> Result<(), String> {
    conn.execute(
        "UPDATE content_pool SET body = COALESCE(?1, body), body_attempted_at = ?2, \
         word_count = CASE WHEN ?1 IS NOT NULL THEN ?3 ELSE word_count END \
         WHERE id = ?4",
        rusqlite::params![
            body,
            now_utc,
            // 拿到正文后重算词数（正文比摘要长得多 → 卡片上的「N min」才准）
            body.map(count_words),
            id
        ],
    )
    .map_err(|e| format!("save body id={}: {}", id, e))?;
    Ok(())
}

/// 抓一篇正文的**结果**（带失败原因）。
///
/// # 🔴 为什么不是 `Option<String>`
/// 失败有三种，**修法完全不同**：
/// | 原因 | 修法 |
/// |---|---|
/// | HTTP 没通 | 网络/UA/超时/对方防爬 |
/// | 提取到 0 段 | 选择器不匹配 / 负面标记误伤 |
/// | 提取到了但太短 | 阈值问题 或 页面确实没有正文 |
/// → 只返回 `None` 的话，日志里只有「失败」，**排查要靠猜**。
///   （实测踩到：NPR 10 次全失败，但看不出卡在哪一步 —— 于是写了
///    `examples/body_diag.rs`，它需要这个枚举才能给出结论。）
/// 🔑 判据：**失败信息要能直接指向下一步动作**，否则等于没报。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BodyOutcome {
    /// 拿到了可用正文。
    Got(String),
    /// HTTP 层失败（网络 / 非 2xx / 超时）。
    HttpFailed(String),
    /// HTTP 通了，但**一段正文都没提取到**。
    NoParagraphs,
    /// 提取到了，但总长不够（附实际长度）。
    TooShort(usize),
    /// 🆕 2026-10-03：**非 HTML 文档**（PDF / 文档 / 压缩包）—— **未发起网络请求**。
    ///
    /// 与 [`NoParagraphs`](Self::NoParagraphs) 的区别很重要：
    /// 后者是「抓了但提取不到」（可能重试），前者是「**这个 url 根本不是网页**」（不该重试）。
    /// ⚠️ 之所以要单独一个变体：把它混进 `NoParagraphs` 会让日志显示
    ///    「抓了但没有段落」—— 而真相是「**压根没抓**」⇒ 误导排查方向。
    NonHtmlDocument(String),
}

impl BodyOutcome {
    pub fn text(&self) -> Option<&str> {
        match self {
            BodyOutcome::Got(t) => Some(t),
            _ => None,
        }
    }

    /// 失败原因（供日志/诊断工具用）。
    ///
    /// 🔑 返回 `String` 而不是 `&str` —— 日志聚合要把 reason 当 map 的 key，
    ///    而 `&str` 借用 `self` 会让 map 的生命周期绑死在循环变量上
    ///    （实测报 E0597: `outcome` does not live long enough）。
    ///    这里返回值极短、调用频率低，多一次分配**无所谓**。
    pub fn reason(&self) -> String {
        match self {
            BodyOutcome::Got(_) => "ok",
            BodyOutcome::HttpFailed(_) => "http_failed",
            BodyOutcome::NoParagraphs => "no_paragraphs",
            BodyOutcome::TooShort(_) => "too_short",
            // 🔑 单独的 reason 名 —— 让日志能区分「抓了没提取到」与「压根没抓」
            BodyOutcome::NonHtmlDocument(_) => "non_html_document",
        }
        .to_string()
    }
}

/// 抓一篇的正文（**只做 HTTP + 提取**，不碰 DB）。
///
/// 判据有两条（都要满足才采纳）：
/// 1. 提到了正文
/// 2. **总长度够**（见下面的 `MIN_EXTRACTED_CHARS`）
///
/// # 🆕 2026-10-02：提取器换成 `dom_smoothie`，产出 **Markdown**（不是纯文本）
/// `content_pool.body` 的语义随之变化：**「纯文本（`\n\n` 分段）」→「Markdown」**。
/// 🔴 这引出一条顺序硬约束：**必须先重抓完存量、再切端侧渲染器**
/// （否则老数据的纯文本会被当 Markdown 解析 → 含 `*` `_` `#` 的正文显示成乱码）。
/// 📄 见 `docs/review/content-pipeline-rebuild-plan-2026-10-02.md` §五。
pub async fn fetch_article_body(client: &reqwest::Client, url: &str) -> BodyOutcome {
    /// 提取结果至少这么长才算「抓到了正文」。
    ///
    /// 实测参考：NPR 正文 6800+ 字符 · ECNS 4700+ · Dev.to 3000+。
    /// 取 300 是个**很松**的下限 —— 只用来挡「明显不是正文」的情况
    /// （cookie 横幅 / 一句导航）。宁松不严：严了会把短讯判死。
    const MIN_EXTRACTED_CHARS: usize = 300;

    // 🆕 2026-10-03：**非 HTML 文档直接跳过，不抓**。
    //
    // # 为什么在**这里**也要拦一次（入库闸门不是已经拦了吗）
    //
    // 入库闸门管的是「**新**条目」；本函数管的是「**已入库**条目的补抓」。
    // 两者覆盖的场景不同：
    //   · 存量里可能已有 PDF（实测 4 条）⇒ 每轮补抓都会去拉它们
    //   · 而 PDF 会**原样返回二进制**（实测 body 达 3.5M / 4.3M 字符）
    //     ⇒ 每次白拉几 MB 进内存，且**永远抓不到正文** ⇒ 每轮重复
    //
    // 🔑 判据：**「按缺失挑候选」的批处理，必须能「记住这个挑不出来」**——
    //    否则失败项变成永久噪音（同族：`body_attempted_at` 的设计初衷）。
    //
    // ⚠️ 调用方会把本结果记入 `body_attempted_at` ⇒ 之后不再重试。
    if let Some(ext) = crate::content_quality::non_html_extension(url) {
        return BodyOutcome::NonHtmlDocument(ext);
    }

    let html = match http_get_text(client, url).await {
        Ok(h) => h,
        Err(e) => return BodyOutcome::HttpFailed(e),
    };
    // `Some(url)` 让 Markdown 里的**相对链接绝对化**（App 里点得开）；
    // url 不合法时内部会**降级重试**，不会因此丢掉正文（见该函数文档）。
    let md = crate::content_extract::extract_to_markdown(&html, Some(url));
    if md.trim().is_empty() {
        return BodyOutcome::NoParagraphs;
    }
    let len = md.chars().count();
    if len < MIN_EXTRACTED_CHARS {
        return BodyOutcome::TooShort(len);
    }
    BodyOutcome::Got(md)
}

/// 诊断用：抓一篇并返回结果（供 `examples/body_diag.rs`）。
///
/// 🔑 与 [`fetch_bodies_round`] **走同一条代码路径** —— 诊断的必须是真的那条，
///    否则结论不适用（自己建一份 client / 复刻一遍逻辑都会引入偏差）。
pub async fn fetch_article_body_diagnostic(url: &str) -> BodyOutcome {
    match reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
    {
        Ok(c) => fetch_article_body(&c, url).await,
        Err(e) => BodyOutcome::HttpFailed(format!("建客户端失败: {}", e)),
    }
}

/// 补抓一轮正文（**限量**）。返回 (尝试数, 成功数)。
///
/// 🔴 结构与 [`fetch_all`] 一致：**先异步抓（不碰 DB）→ 再同步写**。
///    不能把 `get_conn()` 的 guard 带进 `await`（见模块头 ①）。
pub async fn fetch_bodies_round() -> (usize, usize) {
    let candidates = {
        let conn = crate::db_pool::get_conn();
        match pick_body_candidates(&conn, MAX_BODY_FETCH_PER_ROUND, refetch_existing_enabled()) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("content_fetch: 挑正文候选失败: {}", e);
                return (0, 0);
            }
        }
    };
    if candidates.is_empty() {
        return (0, 0);
    }

    let client = match reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("content_fetch: 建 HTTP 客户端失败: {}", e);
            return (0, 0);
        }
    };

    let mut ok = 0usize;
    let total = candidates.len();
    // 🔑 按失败原因分类计数 —— 让日志直接指向「下一步查什么」
    let mut reasons: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for (id, url) in candidates {
        let outcome = fetch_article_body(&client, &url).await;
        if let Some(text) = outcome.text() {
            ok += 1;
            // 🔑 到这里才碰 DB
            let conn = crate::db_pool::get_conn();
            if let Err(e) = save_body(&conn, id, Some(text), &now_utc_iso()) {
                tracing::warn!("content_fetch: 写正文失败 id={}: {}", id, e);
            }
        } else {
            *reasons.entry(outcome.reason()).or_insert(0) += 1;
            if let BodyOutcome::HttpFailed(e) = &outcome {
                tracing::debug!("content_fetch: 正文 HTTP 失败 {}: {}", url, e);
            }
            // 🔑 失败也要记尝试 —— 否则下轮又挑到它（`body_attempted_at` 的意义）
            let conn = crate::db_pool::get_conn();
            if let Err(e) = save_body(&conn, id, None, &now_utc_iso()) {
                tracing::warn!("content_fetch: 记尝试失败 id={}: {}", id, e);
            }
        }
    }
    let detail: Vec<String> = reasons
        .iter()
        .map(|(k, v)| format!("{}={}", k, v))
        .collect();
    tracing::info!(
        "content_fetch: 补抓正文 {}/{} 篇成功{}",
        ok,
        total,
        if detail.is_empty() {
            String::new()
        } else {
            format!(" · 失败分类: {}", detail.join(" "))
        }
    );
    (total, ok)
}

/// 当前时刻（**UTC ISO8601 带 `Z`**）—— 与表的时间列口径一致。
pub fn now_utc_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// 默认抓取间隔：**6 小时**。
///
/// 依据：方案的成本核算就是按「每 6 小时」算的（100 源 → ¥0.18/月）。
/// 🔑 抓取频率与「内容新鲜度」的关系是**平台期**的（新闻源本身也不是每分钟更新），
///    所以调快不会带来成比例的新内容，只增加请求量与失败面。
pub const DEFAULT_FETCH_INTERVAL_SECS: u64 = 6 * 3600;

/// 启动后**首次抓取**的延迟（秒）。
///
/// 🔑 为什么不立刻抓：启动瞬间要尽快对外可服务，而抓取是「几十秒的网络任务」。
///    但也不能等满 6 小时 —— 否则**新部署的实例会对用户显示空信息流**。
///    → 起服后 30 秒开始首轮。
const FIRST_FETCH_DELAY_SECS: u64 = 30;

/// 启动内容抓取的**后台线程**（自带 tokio runtime）。
///
/// # 🔴 为什么自带 runtime，而不是 `tokio::spawn`
/// `tokio::spawn` **只在 tokio runtime 上下文里可用**（否则 panic）。
/// 本函数是普通同步函数，**它的调用方是否处于 runtime 里是隐含前提** ——
/// 靠「调用方恰好是 async」来成立的关系最容易在重构时静默断掉
/// （换个调用点就 panic，而且只在运行时暴露）。
/// → 自己建一个 current-thread runtime，**自包含**，不依赖外部上下文。
///
/// # 关掉它的方式
/// `COEVO_FETCH_INTERVAL_SECS=0` → 不启动（本地开发 / 单测时不必真的去抓网）。
pub fn start_fetch_scheduler() {
    let interval = std::env::var("COEVO_FETCH_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_FETCH_INTERVAL_SECS);
    if interval == 0 {
        tracing::info!("content_fetch: 已禁用（COEVO_FETCH_INTERVAL_SECS=0）");
        return;
    }

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                tracing::error!("content_fetch: 建 runtime 失败，抓取不会启动: {}", e);
                return;
            }
        };
        tracing::info!(
            "content_fetch: 启动（首轮 {}s 后，之后每 {}s）",
            FIRST_FETCH_DELAY_SECS,
            interval
        );
        tracing::info!(
            "content_fetch: 内容保留期 {} 天（`COEVO_CONTENT_RETENTION_DAYS=0` 可关闭清理）",
            content_retention_days()
        );
        // 🔴 重抓模式**必须显式可见** —— 它是给「存量迁移」用的临时开关。
        //    忘了关的后果：每轮都去抓「已有正文但未试过」的条目（正常运行时那批应为空），
        //    虽不致命，但语义上「重抓」不该是常态 ⇒ 用 WARN 级别，让人一眼看到。
        if refetch_existing_enabled() {
            tracing::warn!(
                "content_fetch: 🔴 **重抓模式已开启**（COEVO_REFETCH_BODIES=1）—— \
                 本轮起会重抓「已有正文」的条目（存量迁移用）。**迁移完成后请立刻关掉并重启**"
            );
        }
        std::thread::sleep(std::time::Duration::from_secs(FIRST_FETCH_DELAY_SECS));
        loop {
            let outcomes = rt.block_on(fetch_all(&now_utc_iso()));
            let ok = outcomes.iter().filter(|o| o.error.is_none()).count();
            let added: usize = outcomes.iter().map(|o| o.inserted).sum();
            tracing::info!(
                "content_fetch: 本轮 {}/{} 个源成功 · 新增 {} 条",
                ok,
                outcomes.len(),
                added
            );
            // 🆕 抓完 feed 后补抓正文（RSS 通常只给摘要 —— 全文要抓原网页）
            // 🔑 每轮限量，未抓到的 `body_attempted_at` 仍为空 → 下轮继续
            let (tried, got) = rt.block_on(fetch_bodies_round());
            if tried > 0 {
                tracing::info!("content_fetch: 正文补抓 {}/{}", got, tried);
            }
            // 🆕 保留期清理：删掉「拿到超过 N 天」的旧内容（`COEVO_CONTENT_RETENTION_DAYS`）
            // 🔑 放在抓取之后：先入库新的，再清旧的 —— 中间不会出现「空窗」
            let keep_days = content_retention_days();
            if keep_days > 0 {
                // ⚠️ 连接 guard 必须在**同步块**里取用后立刻释放 ——
                //    本函数（`prune_old_content`）是同步的，不跨 `await`，所以安全
                let pruned = {
                    let conn = crate::db_pool::get_conn();
                    prune_old_content(&conn, keep_days, PRUNE_BATCH_PER_ROUND)
                };
                match pruned {
                    Ok(0) => {}
                    Ok(n) => tracing::info!(
                        "content_fetch: 保留期清理删除 {} 条（保留 {} 天内的）",
                        n,
                        keep_days
                    ),
                    Err(e) => tracing::error!("content_fetch: 保留期清理失败: {}", e),
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(interval));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&c).unwrap();
        c
    }

    fn src(id: i64, kind: &str) -> SourceRow {
        SourceRow {
            id,
            name: "测试源".into(),
            url: "https://example.test/feed".into(),
            kind: kind.into(),
            category: Some("tech".into()),
            redistributable: 1,
            tz_offset_min: 0,
        }
    }

    fn item(url: &str) -> ParsedItem {
        ParsedItem {
            title: "T".into(),
            summary: Some("S".into()),
            body: Some("B".into()),
            url: url.into(),
            author: Some("A".into()),
            published_at: Some("2026-09-29T00:00:00Z".into()),
        }
    }

    #[test]
    fn test_seed_sources_are_loaded() {
        let conn = mem();
        let s = load_enabled_sources(&conn).unwrap();
        // 🔴 2026-10-02 四处变更，都在这一条里体现：
        //    ① `Ars Technica` 被禁用（`enabled = 0`）→ 不再计入
        //    ② **新增 7 个源**（NPR 6 分频道 + arXiv）→ 4 + 7 = **11**
        //    ③ 🆕 **二轮再加 2 个**（`NPR Sports` / `NPR Movies`，补 `sports` /
        //       `entertainment` 两个一直无源的类）→ 11 + 2 = **13**
        //    ④ 🆕 **三轮再加 10 个**（「8 类之外」的独立话题频道，含 4 个新类
        //       `education`/`history`/`law`/`family`）→ 13 + 10 = **23**
        //    理由与实测数据见 `schema.rs` 里那几行的注释。
        //    📌 这条断言同时是「`enabled` 真的被过滤」的守门人 ——
        //       它数的是 `load_enabled_sources` 的结果，不是表里的行数。
        assert_eq!(
            s.len(),
            22,
            "种子应有 22 个**启用**源（Ars + Hacker News 均已禁用 · HackerNoon 未接）"
        );
        // 🔴 反向断言：**不得**再有启用的 `hn` 源。
        //    2026-10-03 白哥决定放弃 HN ⇒ 适配器（content_hn.rs）已删。
        //    保留这条用意是**防回退**：若有人把 HN 重新 `enabled=1`，
        //    抓取时会走到「未知的源类型」而报错 —— 这条断言让它在**测试阶段**就暴露。
        assert!(
            s.iter().all(|x| x.kind != "hn"),
            "HN 已废弃（适配器已删）⇒ 不该有启用的 hn 源: {:?}",
            s.iter()
                .filter(|x| x.kind == "hn")
                .map(|x| &x.name)
                .collect::<Vec<_>>()
        );
        assert!(
            s.iter().all(|x| x.url.starts_with("http")),
            "每个源的 url 都应可用: {:?}",
            s.iter().map(|x| &x.url).collect::<Vec<_>>()
        );
        // 🔑 反向：被禁用的源**不得**出现在结果里（否则「禁用」是装饰）
        assert!(
            !s.iter().any(|x| x.name.contains("Ars")),
            "Ars 已禁用（enabled=0）→ 不该被加载"
        );
        // 🔑 但它在**表里**仍存在（禁用 ≠ 删除）
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM content_source", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            total, 24,
            "表里仍应有 24 行（5 原有 + 7 首轮 + 2 二轮 + 10 三轮；Ars 是禁用，不是删除）"
        );

        // ═══ 2026-10-02 新增源的守门断言 ═══════════════════════════════════
        //
        // 🔑 这些断言的共同理由：**新源的「配置值」直接决定合规与内容形态**，
        //    改错了不会报错，只会静默地把不该存的内容存进来（或该存的存不进来）。
        //    判据：**「决定」要固化成断言**，不能只写在注释里。

        // ①a 🔑 **所有源分类都必须落在受控词表内** ——
        //     词表是 `schema::CONTENT_CATEGORIES`（唯一权威定义处），
        //     `content_source.category` 上也有 CHECK。
        //     这里再断言一次的原因：**CHECK 只对新库生效**（旧库的 DDL 不会重建），
        //     而这条断言在**任何**库上都会跑。
        for src in &s {
            let cat = src.category.as_deref().unwrap_or("");
            assert!(
                crate::schema::CONTENT_CATEGORIES.contains(&cat),
                "源 `{}` 的 category `{}` 不在受控词表 {:?} 内",
                src.name,
                cat,
                crate::schema::CONTENT_CATEGORIES
            );
        }

        // ①b 分类**覆盖**：扩源的目的是「补其他类型」→ 断言确实扩到了
        //
        //     ✅ 2026-10-02 二轮后，**受控词表 8 类全部有源覆盖**：
        //        首轮补了 business / science / culture / health，
        //        二轮补了 `sports`（NPR Sports）/ `entertainment`（NPR Movies）。
        //
        //     🔑 口径从「逐类 `contains`」改成「**集合相等**」（2026-10-02 二轮）：
        //        原写法枚举 6 个类 → 若词表**新增第 9 类**而这里忘了加，
        //        断言**不会红**（正是「包含+枚举 < 集合相等」那个坑）。
        //        改成与 `CONTENT_CATEGORIES` **逐值比对**后，
        //        「词表加了类但没源」会**立刻**在这一条暴露。
        //        📌 这也是「补源」这件事本身的守门人：
        //           它红了 = 某类又变成「用户勾了却拉不到内容」。
        //
        //     ⚠️ 代价（如实标注）：将来若**有意**让某类暂时无源，
        //        这条会红 —— 那是**要的**（「无源」应当是被显式知道的事，
        //        而不是靠没人发现）。
        let cats: std::collections::BTreeSet<&str> =
            s.iter().filter_map(|x| x.category.as_deref()).collect();
        let expected_cats: std::collections::BTreeSet<&str> =
            crate::schema::CONTENT_CATEGORIES.iter().copied().collect();
        assert_eq!(
            cats, expected_cats,
            "受控词表的**每一类**都应有源覆盖（否则用户勾了标签却拉不到内容）"
        );

        // ② 🔴 许可受限的源**必须** `redistributable = 0`
        //    （实测依据：arXiv 默认许可「limits re-use of any type from other
        //      entities or individuals」⇒ 不抓 /html/ 全文，只存 abstract）
        //
        //    ⚠️ 这里曾有 HackerNoon（terms「YOU ARE THE SOLE OWNER OF YOUR
        //       CONTENT」）—— 白哥 2026-10-02 决定**不接**：许可既然只允许存摘要，
        //       而它的价值恰恰在「RSS 全文」⇒ 接了也只等于再加一个 ECNS。
        //
        //    📌 新增「许可受限」的源时，把名字加进下面这个切片即可（**别写成
        //       `for` 单元素数组** —— clippy 的 `single_element_loop` 会报，
        //       而且那种写法掩盖了「本来就只有一条」这个事实）。
        const LICENSE_RESTRICTED: &[&str] = &["arXiv"];
        for name in LICENSE_RESTRICTED {
            let src = s
                .iter()
                .find(|x| x.name.contains(name))
                .unwrap_or_else(|| panic!("应有 {} 源", name));
            assert_eq!(
                src.redistributable, 0,
                "{} 的许可不允许再分发全文 ⇒ redistributable 必须为 0（否则全文会入库）",
                name
            );
        }

        // ③ NPR 分频道与现有 NPR **同条款**（同一个媒体）⇒ 必须一致
        let npr: Vec<_> = s.iter().filter(|x| x.name.starts_with("NPR")).collect();
        // ⚠️ 这条数的是 `name.starts_with("NPR")` ⇒ **只统计 NPR 源**。
        //    三轮后 NPR 共 19 个（主 1 + 首轮 6 + 二轮 2 + 三轮 10）。
        //    🔑 它与「启用源总数 23」的差 = 4（ECNS · Dev.to · HN · arXiv）。
        assert_eq!(
            npr.len(),
            19,
            "应有 19 个 NPR 源（主 1 + 首轮 6 + 二轮 体育/影视 2 + 三轮 10）"
        );
        assert!(
            npr.iter().all(|x| x.redistributable == 1),
            "NPR 各频道应与现有 NPR 同条款（redistributable = 1）"
        );

        // ④ 时间格式：这 3 家都用 RFC 2822（自带时区）⇒ tz_offset 不生效，须为 0
        //    （⚠️ ECNS 是唯一的例外，它用不带时区的格式 ⇒ 480）
        for name in ["arXiv", "NPR"] {
            for src in s.iter().filter(|x| x.name.contains(name)) {
                assert_eq!(
                    src.tz_offset_min, 0,
                    "{} 用 RFC 2822 时间戳（自带时区）⇒ tz_offset_min 应为 0",
                    src.name
                );
            }
        }
    }

    #[test]
    fn test_write_is_idempotent() {
        let conn = mem();
        let s = src(1, "rss");
        let items = vec![item("https://a.test/1"), item("https://a.test/2")];

        let n1 = write_items(&conn, &s, &items, "2026-09-29T00:00:00Z").unwrap();
        assert_eq!(n1, 2, "首次应插 2 条");

        // 🔴 再写一遍：UNIQUE(url) + INSERT OR IGNORE → 一条都不该新增
        let n2 = write_items(&conn, &s, &items, "2026-09-29T01:00:00Z").unwrap();
        assert_eq!(n2, 0, "重复写应为 0（幂等）");

        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM content_pool", [], |r| r.get(0))
            .unwrap();
        assert_eq!(total, 2, "总行数不变");
    }

    #[test]
    fn test_non_redistributable_source_drops_body() {
        let conn = mem();
        let mut s = src(1, "rss");
        s.redistributable = 0;
        write_items(
            &conn,
            &s,
            &[item("https://a.test/1")],
            "2026-09-29T00:00:00Z",
        )
        .unwrap();

        let body: Option<String> = conn
            .query_row(
                "SELECT body FROM content_pool WHERE url = ?1",
                ["https://a.test/1"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(body, None, "redistributable=0 → 不存全文");
        // 摘要仍要存（否则这条就没内容了）
        let summary: Option<String> = conn
            .query_row(
                "SELECT summary FROM content_pool WHERE url = ?1",
                ["https://a.test/1"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(summary.as_deref(), Some("S"));
    }

    /// 🔴 **行为断言**（不只是「那个纯函数判得对」）：[write_items] 真的调用了
    /// [sanitize_summary]。
    ///
    /// 📌 为什么必须有它：纯函数测试只能证明「这个函数判得对」，
    /// 证明不了「入库路径真的用了它」——
    /// 文本/单元断言的上限是「写了」，「**会执行到**」只能真跑一遍
    /// （同族教训见 memory 判据库）。
    #[test]
    fn test_write_items_drops_source_error_summary() {
        let conn = mem();
        let s = src(1, "rss");

        // 白哥真机反馈那篇的真实 summary
        let mut bad = item("https://a.test/bad");
        bad.summary = Some("Liquid syntax error: 'raw' tag was never closed".into());
        // 对照组：正常摘要必须原样保留（防「顺手全清」）
        let good = item("https://a.test/good");

        let n = write_items(&conn, &s, &[bad, good], "2026-09-29T00:00:00Z").unwrap();
        // 🔑 过滤的是 **summary 这一列**，不是整条 → 两条都该入库
        //    （标题/URL 仍有价值：列表页还要显示它）
        assert_eq!(n, 2, "两条都该入库（只是其中一条的摘要被清掉）");

        let bad_summary: Option<String> = conn
            .query_row(
                "SELECT summary FROM content_pool WHERE url = ?1",
                ["https://a.test/bad"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bad_summary, None, "🔴 源站报错不该作为摘要入库");

        let good_summary: Option<String> = conn
            .query_row(
                "SELECT summary FROM content_pool WHERE url = ?1",
                ["https://a.test/good"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            good_summary.as_deref(),
            Some("S"),
            "🔴 正常摘要必须原样保留（别顺手全清）"
        );
    }

    #[test]
    fn test_category_comes_from_source_not_rss_tag() {
        let conn = mem();
        let mut s = src(1, "rss");
        s.category = Some("news".into());
        write_items(
            &conn,
            &s,
            &[item("https://a.test/1")],
            "2026-09-29T00:00:00Z",
        )
        .unwrap();
        let cat: Option<String> = conn
            .query_row(
                "SELECT category FROM content_pool WHERE url = ?1",
                ["https://a.test/1"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cat.as_deref(), Some("news"), "分类取源配置（受控词表）");
    }

    #[test]
    fn test_count_words() {
        assert_eq!(count_words(""), 0);
        assert_eq!(count_words("  a  b "), 2);
        assert_eq!(count_words("a\nb\tc"), 3);
    }

    #[test]
    fn test_touch_source_tracks_failures() {
        let conn = mem();
        touch_source(&conn, 1, true, "2026-09-29T00:00:00Z").unwrap();
        let (fail, last): (i64, Option<String>) = conn
            .query_row(
                "SELECT fail_count, last_fetch_at FROM content_source WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(fail, 0);
        assert_eq!(last.as_deref(), Some("2026-09-29T00:00:00Z"));

        // 连续失败 → fail_count 累加（但 last_fetch_at 仍更新，避免被反复重试）
        touch_source(&conn, 1, false, "2026-09-29T01:00:00Z").unwrap();
        touch_source(&conn, 1, false, "2026-09-29T02:00:00Z").unwrap();
        let (fail2, last2): (i64, Option<String>) = conn
            .query_row(
                "SELECT fail_count, last_fetch_at FROM content_source WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(fail2, 2, "失败要累加");
        assert_eq!(last2.as_deref(), Some("2026-09-29T02:00:00Z"));

        // 成功一次 → 归零
        touch_source(&conn, 1, true, "2026-09-29T03:00:00Z").unwrap();
        let fail3: i64 = conn
            .query_row(
                "SELECT fail_count FROM content_source WHERE id=1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(fail3, 0, "成功要归零");
    }

    #[test]
    fn test_now_utc_iso_has_z() {
        let s = now_utc_iso();
        assert!(s.ends_with('Z'), "{}", s);
        assert_eq!(s.len(), 20, "ISO8601 秒级长度应为 20: {}", s);
    }

    // ── 🆕 2026-10-02 · 源站报错摘要过滤 ─────────────────────────

    /// 🔴 **实测案例**（白哥真机反馈「只有半句话」那篇的真实 summary）。
    #[test]
    fn test_source_error_summary_real_case_is_detected() {
        // 这是 Dev.to 渲染失败时吐在 RSS description 里的原文
        assert!(is_source_error_summary(
            "Liquid syntax error: 'raw' tag was never closed"
        ));
    }

    /// 🆕 其他已知指纹（同族形态）。
    #[test]
    fn test_source_error_summary_other_fingerprints() {
        for s in [
            "Template render error: undefined method",
            "An error occurred while rendering this page",
            "Cannot read properties of undefined (reading 'map')",
            "Cannot read property 'x' of null",
        ] {
            assert!(is_source_error_summary(s), "应识别: {s}");
        }
    }

    /// 🔴 **互补信号（长度）的意义**：正常短文不该被误杀。
    #[test]
    fn test_normal_short_summary_not_killed() {
        for s in [
            "A short news brief about the economy and jobs.",
            "这里是中文摘要，讲的是同一天发生的两件事。",
            "Weekly roundup of everything that shipped this week.",
        ] {
            assert!(!is_source_error_summary(s), "🔴 误杀了正常摘要: {s}");
        }
    }

    /// 🔴🔴 **本组最关键的一条**：长文章里出现报错字样**不该**被误杀。
    /// 这正是「指纹 + 长度」两条一起用的理由 —— 只按指纹判会整类误伤技术文章。
    #[test]
    fn test_long_text_mentioning_error_not_killed() {
        // 一篇讲调试的长摘要（> 200 字符），里面出现 syntax error 字样
        let long = format!(
            "{} In this post we walk through how we hit a {} while building our parser, \
             why it took three days to find, and what we changed afterwards to make the \
             failure loud instead of silent.",
            "A long-form engineering write-up.", "syntax error"
        );
        assert!(
            long.chars().count() > 200,
            "构造的样本要够长才有意义: {}",
            long.chars().count()
        );
        assert!(
            !is_source_error_summary(&long),
            "🔴 长文里出现报错字样不该被误杀（互补信号失效）"
        );
    }

    /// `sanitize_summary` 的三种出口 + 空串归一。
    #[test]
    fn test_sanitize_summary_exits() {
        // ① 命中报错 → None（端侧据此走「还没有正文」的正常分支）
        assert_eq!(
            sanitize_summary(Some("Liquid syntax error: 'raw' tag was never closed")),
            None
        );
        // ② 本来就没有 → None
        assert_eq!(sanitize_summary(None), None);
        // ③ 空白串 → None（不该存一个「看起来有摘要」的空值）
        assert_eq!(sanitize_summary(Some("   ")), None);
        // ④ 正常摘要 → **原样保留**（不能顺手改内容）
        assert_eq!(
            sanitize_summary(Some("A normal summary sentence.")),
            Some("A normal summary sentence.")
        );
    }

    // ════════════════════════════════════════════════════════════════
    // 重抓模式（2026-10-02 · 「存量重抓被阻塞」的根因）
    // ════════════════════════════════════════════════════════════════

    /// 造一条 `content_pool`（只填挑候选用到的列）。
    fn pool_row(
        conn: &Connection,
        id: i64,
        source_id: i64,
        url: &str,
        body: Option<&str>,
        attempted: Option<&str>,
    ) {
        conn.execute(
            "INSERT INTO content_pool \
             (id, source_id, title, url, body, body_attempted_at, fetched_at) \
             VALUES (?1, ?2, 'T', ?3, ?4, ?5, '2026-10-01T00:00:00Z')",
            rusqlite::params![id, source_id, url, body, attempted],
        )
        .unwrap();
    }

    /// `N` 天前的 UTC ISO8601（带 `Z`）—— 保留期测试用。
    fn days_ago_iso(days: i64) -> String {
        // ⚠️ 用 SQLite 算时间而不是 Rust —— 与 `prune_old_content` 里的
        //    `strftime(...,'now',?1)` **同一套机制**（判据：基准值必须同源，
        //    否则「测试用 Rust 算、生产用 SQLite 算」会出现不可比的边界）
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.query_row(
            "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now',?1)",
            rusqlite::params![format!("-{} days", days)],
            |r| r.get(0),
        )
        .unwrap()
    }

    /// 插一行**指定 `fetched_at`** 的内容（保留期测试要控制时间）。
    fn pool_row_at(conn: &Connection, id: i64, fetched_at: &str) {
        conn.execute(
            "INSERT INTO content_pool (id, source_id, title, url, fetched_at) \
             VALUES (?1, 1, 'T', ?2, ?3)",
            rusqlite::params![id, format!("https://x.test/{}", id), fetched_at],
        )
        .unwrap();
    }

    fn count_pool(conn: &Connection) -> i64 {
        conn.query_row("SELECT COUNT(*) FROM content_pool", [], |r| r.get(0))
            .unwrap()
    }

    // ═══ 保留期清理（2026-10-02 · 白哥「存量不要，太多内容没有意义」）═══════

    #[test]
    fn test_prune_only_deletes_rows_older_than_window() {
        let c = mem();
        // 三档：今天 / 40 天前 / 100 天前 —— 保留期 30 天
        pool_row_at(&c, 1, &now_utc_iso()); // 今天
        pool_row_at(&c, 2, &days_ago_iso(40));
        pool_row_at(&c, 3, &days_ago_iso(100));

        let deleted = prune_old_content(&c, 30, 1000).unwrap();
        assert_eq!(deleted, 2, "30 天保留期 ⇒ 只该删 40 与 100 天前那两条");
        assert_eq!(count_pool(&c), 1, "今天那条必须留着");
        let left: i64 = c
            .query_row("SELECT id FROM content_pool", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 1, "留下的应该是「今天」那条（不是别条）");
    }

    #[test]
    fn test_prune_respects_batch_limit() {
        let c = mem();
        for i in 1..=10 {
            pool_row_at(&c, i, &days_ago_iso(100));
        }
        // 🔑 限量是为了不长时间持有写锁（SQLite 单写者）——
        //    这条断言守的是「限量真的生效」（否则一次删几万行会阻塞抓取入库）
        assert_eq!(prune_old_content(&c, 30, 4).unwrap(), 4);
        assert_eq!(count_pool(&c), 6);
        // 幂等：再删一次又是 4（还剩 6）
        assert_eq!(prune_old_content(&c, 30, 4).unwrap(), 4);
        // 删到没有为止
        assert_eq!(prune_old_content(&c, 30, 100).unwrap(), 2);
        assert_eq!(
            prune_old_content(&c, 30, 100).unwrap(),
            0,
            "没有更旧的了 ⇒ 0"
        );
        assert_eq!(count_pool(&c), 0);
    }

    #[test]
    fn test_prune_disabled_when_days_is_zero_or_negative() {
        let c = mem();
        for i in 1..=3 {
            pool_row_at(&c, i, &days_ago_iso(9999));
        }
        // `0` 与负数都表示「不清理」—— 白哥口径是「默认清理」，
        // 但要留一个**一键关闭**的开关（出问题时能立刻止血）。
        assert_eq!(prune_old_content(&c, 0, 1000).unwrap(), 0);
        assert_eq!(prune_old_content(&c, -1, 1000).unwrap(), 0);
        assert_eq!(count_pool(&c), 3, "关闭时一行都不该删");
    }

    #[test]
    fn test_prune_keeps_row_exactly_at_boundary() {
        let c = mem();
        // 边界：刚好 29 天（在 30 天窗口内）→ 留；刚好 31 天 → 删
        // 🔑 用「边界两侧各一条」而不是「只测一侧」，否则窗口写反了也发现不了
        pool_row_at(&c, 1, &days_ago_iso(29));
        pool_row_at(&c, 2, &days_ago_iso(31));
        assert_eq!(prune_old_content(&c, 30, 1000).unwrap(), 1);
        let left: i64 = c
            .query_row("SELECT id FROM content_pool", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 1, "29 天那条在窗口内，必须留下");
    }

    fn picked_ids(conn: &Connection, refetch: bool) -> Vec<i64> {
        pick_body_candidates(conn, 1000, refetch)
            .unwrap()
            .into_iter()
            .map(|(i, _)| i)
            .collect()
    }

    /// 🔴 默认模式：**有正文 ⇒ 不挑** —— 这是改动前就有的行为，必须逐字保持。
    #[test]
    fn test_pick_candidates_default_skips_existing_body() {
        let c = mem();
        pool_row(&c, 900, 1, "https://x.test/a", Some("已有正文"), None);
        pool_row(&c, 901, 1, "https://x.test/b", None, None);
        pool_row(
            &c,
            902,
            1,
            "https://x.test/c",
            Some("x"),
            Some("2026-10-01T00:00:00Z"),
        );

        let ids = picked_ids(&c, false);
        assert!(ids.contains(&901), "无正文 + 未试过 ⇒ 应被挑中");
        assert!(
            !ids.contains(&900),
            "🔴 默认模式：有正文 ⇒ **不挑**（与改动前一致）"
        );
        assert!(!ids.contains(&902), "已试过 ⇒ 不挑（「只试一次」）");
    }

    /// 🔴 重抓模式：**清过标记的存量（含已有正文的）必须被挑中** ——
    ///    这正是「清 `body_attempted_at` 却不重抓」那个缺陷的守门人。
    #[test]
    fn test_pick_candidates_refetch_mode_includes_existing_body() {
        let c = mem();
        pool_row(&c, 910, 1, "https://x.test/d", Some("已有正文"), None);
        pool_row(&c, 911, 1, "https://x.test/e", None, None);
        pool_row(
            &c,
            912,
            1,
            "https://x.test/f",
            Some("x"),
            Some("2026-10-01T00:00:00Z"),
        );

        let ids = picked_ids(&c, true);
        assert!(
            ids.contains(&910),
            "🔴 重抓模式：有正文 + 未试过（= 刚被重置过标记）⇒ **必须挑中**。\
             不挑 = 清标记白做 = 线上那个「136 篇永远不被重抓」的缺陷"
        );
        assert!(ids.contains(&911), "无正文的当然也要");
        assert!(
            !ids.contains(&912),
            "⚠️ 重抓模式**不取消**「只试一次」—— 已试过的仍不挑（否则会反复抓）"
        );
    }

    /// ⚠️ 两种模式的**唯一**差异就是「body 是否可为空」，其余条件必须一致。
    #[test]
    fn test_refetch_mode_differs_only_by_body_condition() {
        let c = mem();
        pool_row(&c, 920, 1, "https://x.test/g", Some("正文"), None);
        let d = picked_ids(&c, false);
        let r = picked_ids(&c, true);
        // 差集应当**恰好**是那条「有正文」的
        assert_eq!(d.len() + 1, r.len(), "只应多挑 1 条：{:?} vs {:?}", d, r);
        assert!(r.contains(&920) && !d.contains(&920));
    }
}
