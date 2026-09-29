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

use crate::content_hn::{self, DEFAULT_STORY_LIMIT};
use crate::content_rss::{self, ParsedItem};

/// 抓取用的 UA。
///
/// 🔴 **必须带** —— 实测 `apnews.com` 对无 UA 的请求直接 `403`。
/// 同时带上项目标识（不伪装成浏览器，便于对方在日志里识别与联系我们）。
const USER_AGENT: &str = "CoEvo/1.0 (+https://keyievolution.fun; English learning app)";

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
        "hn" => fetch_hn(&client, src).await,
        other => Err(format!("未知的源类型 `{}`（支持 rss | hn）", other)),
    }
}

/// Hacker News：无批量接口 → 逐个拉（见 `content_hn::DEFAULT_STORY_LIMIT`）。
///
/// 🔑 单条拉失败**不断整轮** —— 用 `filter_map` 跳过拿不到的，而不是 `?` 提前返回。
///    理由：HN 的 id 列表里可能夹着已删除的帖子（返回 `null`），
///    为此丢掉整批热帖是**用局部问题惩罚整体**。
async fn fetch_hn(client: &reqwest::Client, src: &SourceRow) -> Result<Vec<ParsedItem>, String> {
    let base = src.url.trim_end_matches('/');
    let list_url = format!("{}/topstories.json", base);
    let list = http_get_text(client, &list_url).await?;
    let ids = content_hn::parse_topstory_ids(&list, DEFAULT_STORY_LIMIT)?;

    let mut out = Vec::new();
    for id in ids {
        let item_url = format!("{}/item/{}.json", base, id);
        // 单条失败 → 跳过（记 debug 日志，不中断）
        match http_get_text(client, &item_url).await {
            Ok(txt) => match content_hn::parse_story_item(&txt) {
                Ok(Some(it)) => out.push(it),
                Ok(None) => {}
                Err(e) => tracing::debug!("hn item {} 解析跳过: {}", id, e),
            },
            Err(e) => tracing::debug!("hn item {} 拉取跳过: {}", id, e),
        }
    }
    if out.is_empty() {
        // 🔴 「一条都没拿到」要报错 —— 否则会被当成「这轮无新内容」而静默通过
        return Err("HN 一条都没取到（API 变了或网络受限？）".into());
    }
    Ok(out)
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
    resp.text().await.map_err(|e| format!("读响应失败 {}: {}", url, e))
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
        // 🔴 `redistributable = 0` 的源**不存全文** —— 列的含义就是「能不能存全文」，
        //    不能因为「刚好抓到了」就存（那会让这一列失去意义）。
        let body = if src.redistributable == 1 { it.body.as_deref() } else { None };

        let wc = count_words(&format!(
            "{} {} {}",
            it.title,
            it.summary.as_deref().unwrap_or(""),
            body.unwrap_or("")
        ));

        let n = conn
            .execute(
                "INSERT OR IGNORE INTO content_pool \
                 (source_id, title, summary, body, url, author, category, \
                  published_at, fetched_at, word_count, score, comments) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                rusqlite::params![
                    src.id,
                    it.title,
                    it.summary,
                    body,
                    it.url,
                    it.author,
                    // 🔑 分类取**源配置**（受控词表）而不是 RSS 的自由标签 —— 见 `ParsedItem` 的说明
                    src.category,
                    it.published_at,
                    now_utc,
                    wc,
                    it.score,
                    it.comments,
                ],
            )
            .map_err(|e| format!("插入 content_pool 失败 ({}): {}", it.url, e))?;
        inserted += n;
    }
    Ok(inserted)
}

/// 更新源的抓取状态（成功/失败都要更新 —— 否则失败的源会被反复重试却不留痕）。
pub fn touch_source(conn: &Connection, source_id: i64, ok: bool, now_utc: &str) -> Result<(), String> {
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
                src.name, items, inserted
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
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
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
            score: None,
            comments: None,
        }
    }

    #[test]
    fn test_seed_sources_are_loaded() {
        let conn = mem();
        let s = load_enabled_sources(&conn).unwrap();
        assert_eq!(s.len(), 5, "种子应有 5 个源");
        assert!(s.iter().any(|x| x.kind == "hn"), "应有 HN 源");
        assert!(
            s.iter().all(|x| x.url.starts_with("http")),
            "每个源的 url 都应可用: {:?}",
            s.iter().map(|x| &x.url).collect::<Vec<_>>()
        );
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
        write_items(&conn, &s, &[item("https://a.test/1")], "2026-09-29T00:00:00Z").unwrap();

        let body: Option<String> = conn
            .query_row("SELECT body FROM content_pool WHERE url = ?1", ["https://a.test/1"], |r| r.get(0))
            .unwrap();
        assert_eq!(body, None, "redistributable=0 → 不存全文");
        // 摘要仍要存（否则这条就没内容了）
        let summary: Option<String> = conn
            .query_row("SELECT summary FROM content_pool WHERE url = ?1", ["https://a.test/1"], |r| r.get(0))
            .unwrap();
        assert_eq!(summary.as_deref(), Some("S"));
    }

    #[test]
    fn test_category_comes_from_source_not_rss_tag() {
        let conn = mem();
        let mut s = src(1, "rss");
        s.category = Some("news".into());
        write_items(&conn, &s, &[item("https://a.test/1")], "2026-09-29T00:00:00Z").unwrap();
        let cat: Option<String> = conn
            .query_row("SELECT category FROM content_pool WHERE url = ?1", ["https://a.test/1"], |r| r.get(0))
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
            .query_row("SELECT fail_count, last_fetch_at FROM content_source WHERE id=1", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(fail, 0);
        assert_eq!(last.as_deref(), Some("2026-09-29T00:00:00Z"));

        // 连续失败 → fail_count 累加（但 last_fetch_at 仍更新，避免被反复重试）
        touch_source(&conn, 1, false, "2026-09-29T01:00:00Z").unwrap();
        touch_source(&conn, 1, false, "2026-09-29T02:00:00Z").unwrap();
        let (fail2, last2): (i64, Option<String>) = conn
            .query_row("SELECT fail_count, last_fetch_at FROM content_source WHERE id=1", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(fail2, 2, "失败要累加");
        assert_eq!(last2.as_deref(), Some("2026-09-29T02:00:00Z"));

        // 成功一次 → 归零
        touch_source(&conn, 1, true, "2026-09-29T03:00:00Z").unwrap();
        let fail3: i64 = conn
            .query_row("SELECT fail_count FROM content_source WHERE id=1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(fail3, 0, "成功要归零");
    }

    #[test]
    fn test_now_utc_iso_has_z() {
        let s = now_utc_iso();
        assert!(s.ends_with('Z'), "{}", s);
        assert_eq!(s.len(), 20, "ISO8601 秒级长度应为 20: {}", s);
    }
}
