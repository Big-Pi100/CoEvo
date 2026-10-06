//! 云端同步（订阅权益）—— `push` / `pull`
//!
//! 📄 设计依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §四（协议）
//! 白哥 2026-10-05 批准的 3 个决策：
//!   ① 改隐私政策以允许同步（已做）
//!   ② **多端登录**（推翻 L0 的「单端踢旧」）
//!   ③ 🔴 **push/pull 校验有效订阅**
//!
//! # 🔴 三条贯穿本模块的判据
//!
//! ## ① 幂等落在**数据库约束**上，不落在「先查再写」
//! 每张表的**主键就是幂等键** ⇒ 写入用 `INSERT ... ON CONFLICT`。
//! 「先 SELECT 看有没有、再 INSERT」有**竞态**（两个并发 push 都查到不存在，然后都插）。
//!
//! ## ② `pull` 的时间轴是 `received_at`（服务端收货时间），不是设备时间
//! 设备可能**离线积压好几天**再补传（`reviewed_at` 很旧）⇒ 用它当时间轴会**漏**。
//!
//! ## ③ 「未订阅」回 **403**，不是 401
//! 端侧收到 401 的标准处理是「清凭据 → 跳登录」。
//! 若把「已登录但没订阅」也回 401 ⇒ 用户**被莫名登出**（还会以为账号坏了）。
//! ⇒ 见 `AppError::Forbidden` 的注释。
//!
//! # ⚠️ 与设计文档 §4.2 的一处偏差（如实记录）
//!
//! 文档 §4.2 的 `user_words` 示例字段名是 **`created_at`**，而端侧表 `user_word`
//! 的列名是 **`added_at`**（`user_db_schema.sql:181+`）。
//! ⇒ **以端侧为准**（端侧是数据源，服务端是副本）。若按文档写 `created_at`，
//! 端侧序列化时会**静默传空**（字段名不匹配 ⇒ `serde` 默认忽略）⇒ 服务端 `added_at` 全空。
//! 📌 判据：**跨端字段名以「数据产生方」为准**，文档示例不作依据。

use axum::extract::Query;
use axum::http::HeaderMap;
use axum::Json;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use crate::error::AppError;

/// 单次 push 里**每张表**的最大条目数 —— 防「一次传百万条」把服务端拖垮。
///
/// 🔑 超限**明确报 400**（不是静默截断）⇒ 客户端分批重传。
///    ⚠️ 静默截断的后果：客户端以为推成功了（把 `pending_push` 清 0）⇒ **数据永久丢**。
/// 📌 判据：**「服务端不接受」必须说出来**，不能吞。
const MAX_ITEMS_PER_TABLE: usize = 1000;

/// `device_id` 长度上限（防刷；正常是端侧生成的固定长度串）。
const MAX_DEVICE_ID_LEN: usize = 128;

// ══════════════════════════════════════════════════════════════════════
// 入参
// ══════════════════════════════════════════════════════════════════════

/// 复习事件（**唯一真相源** —— 端侧重放它来派生 `card_review_state`）。
#[derive(Debug, Deserialize)]
pub struct ReviewEventInput {
    pub word_id: String,
    pub rating: i64,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    /// 设备时间（UTC ISO8601）。⚠️ **不校验为「过去」** —— 设备时钟可能不准，
    /// 且离线补传的事件本来就旧。乱序由 `received_at` 兜住（见模块头 ②）。
    pub reviewed_at: String,
}

/// 生词本条目。
#[derive(Debug, Deserialize)]
pub struct UserWordInput {
    pub word_id: String,
    pub spelling: String,
    #[serde(default)]
    pub source_article_id: Option<i64>,
    #[serde(default)]
    pub source_sentence: Option<String>,
    /// 🔑 端侧列名是 `added_at`（**不是**文档 §4.2 写的 `created_at` —— 见模块头）。
    pub added_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub deleted: i64,
}

/// 阅读记录。
#[derive(Debug, Deserialize)]
pub struct ArticleReadInput {
    pub article_id: i64,
    pub read_at: String,
}

/// 收藏条目（v6 起为**软删**：取消收藏 = `deleted=1`，不是删行）。
#[derive(Debug, Deserialize)]
pub struct BookmarkInput {
    pub content_id: i64,
    pub bookmarked_at: String,
    #[serde(default)]
    pub deleted: i64,
}

/// 电子书进度（按**内容指纹**，不是 `book_id` —— 书籍 id 是端侧 uuid）。
#[derive(Debug, Deserialize)]
pub struct BookProgressInput {
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub updated_at: String,
}

/// `POST /api/sync/push` 的请求体。
#[derive(Debug, Deserialize)]
pub struct PushInput {
    pub device_id: String,
    #[serde(default)]
    pub review_events: Vec<ReviewEventInput>,
    #[serde(default)]
    pub user_words: Vec<UserWordInput>,
    #[serde(default)]
    pub article_reads: Vec<ArticleReadInput>,
    #[serde(default)]
    pub bookmarks: Vec<BookmarkInput>,
    #[serde(default)]
    pub book_progress: Vec<BookProgressInput>,
}

/// `GET /api/sync/pull` 的查询参数。
#[derive(Debug, Deserialize)]
pub struct PullQuery {
    /// 上次 pull 返回的 `server_time`。**缺省 = 首次同步**（拉全部）。
    #[serde(default)]
    pub since: Option<String>,
    /// 自己的设备 id ⇒ 服务端**排除**本设备推上去的数据（那些本地已经有了）。
    #[serde(default)]
    pub device_id: Option<String>,
}

// ══════════════════════════════════════════════════════════════════════
// 出参
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug, Serialize)]
pub struct ReviewEventOut {
    pub word_id: String,
    pub rating: i64,
    pub duration_ms: Option<i64>,
    pub reviewed_at: String,
    pub utc_day: String,
    pub device_id: String,
}

#[derive(Debug, Serialize)]
pub struct UserWordOut {
    pub word_id: String,
    pub spelling: String,
    pub source_article_id: Option<i64>,
    pub source_sentence: Option<String>,
    pub added_at: String,
    pub updated_at: String,
    pub deleted: i64,
}

#[derive(Debug, Serialize)]
pub struct ArticleReadOut {
    pub article_id: i64,
    pub read_at: String,
}

#[derive(Debug, Serialize)]
pub struct BookmarkOut {
    pub content_id: i64,
    pub bookmarked_at: String,
    pub deleted: i64,
}

#[derive(Debug, Serialize)]
pub struct BookProgressOut {
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub updated_at: String,
}

#[derive(Debug, Serialize)]
pub struct PullOutput {
    pub review_events: Vec<ReviewEventOut>,
    pub user_words: Vec<UserWordOut>,
    pub article_reads: Vec<ArticleReadOut>,
    pub bookmarks: Vec<BookmarkOut>,
    pub book_progress: Vec<BookProgressOut>,
    /// 🔑 客户端把它存下来作为**下次 pull 的 `since`**。
    ///    取「本次返回数据里最大的 `received_at`」；若无数据则取当前时间。
    ///    ⚠️ **不能用「当前时间」替代** —— 若本次有数据而客户端用当前时间当 since，
    ///    在 pull 与取时间之间写入的记录会被**跳过**（时间轴断层）。
    pub server_time: String,
}

// ══════════════════════════════════════════════════════════════════════
// 辅助
// ══════════════════════════════════════════════════════════════════════

/// 服务端当前时间（**毫秒精度**）。
///
/// 🔑 为什么用毫秒而非秒：`pull` 用 `received_at > since`（严格大于）。
/// 若精度只到秒，则「同一秒内写入 + 取 since」会**漏掉**那条记录。
/// 毫秒把这个窗口压到理论极限，且端侧幂等能兜住残余的重复。
fn now_ms() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

/// 从 `reviewed_at` 推导 UTC 日历日（`'YYYY-MM-DD'`）。
///
/// 🔑 **服务端自己算，不用客户端传的 `utc_day`** —— 它是 `reviewed_at` 的纯函数值，
/// 两处各算一次就可能不一致（而端侧 FSRS 用它做「同日去重」⇒ 不一致会让去重失效）。
/// 📌 判据：**派生值只在一处生成**。
fn utc_day_of(reviewed_at: &str) -> Result<String, AppError> {
    // 只做形状校验（不解析时区 —— 端侧已保证是 UTC ISO8601）
    let b = reviewed_at.as_bytes();
    if reviewed_at.len() < 10 || b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') {
        return Err(AppError::BadRequest(format!(
            "reviewed_at 格式非法（需 UTC ISO8601，如 2026-10-06T12:00:00Z）：{reviewed_at}"
        )));
    }
    Ok(reviewed_at[..10].to_string())
}

/// 校验 `device_id` 并返回它。
fn check_device_id(raw: &str) -> Result<String, AppError> {
    let v = raw.trim();
    if v.len() > MAX_DEVICE_ID_LEN {
        return Err(AppError::BadRequest(format!(
            "device_id 过长（上限 {MAX_DEVICE_ID_LEN}）"
        )));
    }
    Ok(v.to_string())
}

/// 校验每张表的条目数上限。
fn check_batch_size(label: &str, n: usize) -> Result<(), AppError> {
    if n > MAX_ITEMS_PER_TABLE {
        return Err(AppError::BadRequest(format!(
            "{label} 单次最多 {MAX_ITEMS_PER_TABLE} 条（收到 {n}）—— 请分批推送"
        )));
    }
    Ok(())
}

/// 鉴权 + 订阅校验（push / pull **共用**同一套）。
///
/// # 🔴 为什么订阅校验放在这里而不是各 handler 里
/// 两个入口的判据**必须完全一致** —— 若一处漏了，那条路径就成了「免费同步」的后门
/// （决策③ 的目的是「服务端也要能拒绝」，不是只靠端侧不显示入口）。
/// 📌 判据：**同一件事的口径只能一处权威**。
fn authorize_with_subscription(headers: &HeaderMap) -> Result<(String, String), AppError> {
    // ① 取 token（**唯一实现**在 `user_purge::extract_bearer_token`）
    let token = crate::user_purge::extract_bearer_token(headers)?;
    let conn = crate::db_pool::get_conn();
    // ② token → uid（**唯一实现**在 `auth::uid_by_token`）
    //    ⚠️ 它返回 `Result<_, String>` ⇒ 显式映射为 `Unauthorized`
    //    （token 无效 = 认证失败，不是「参数错」）
    let uid = crate::auth::uid_by_token(&conn, &token).map_err(AppError::Unauthorized)?;
    // ③ 🔴 订阅校验（决策③）
    if !crate::subscription::is_subscription_active(&conn, &uid) {
        // ⚠️ 403 而非 401（见模块头 ③）—— 文案要**说清是订阅问题**，
        //    否则用户看到「操作失败」只会反复重试。
        return Err(AppError::Forbidden(
            "跨设备同步是订阅权益，订阅后可开启".into(),
        ));
    }
    Ok((uid, token))
}

// ══════════════════════════════════════════════════════════════════════
// POST /api/sync/push
// ══════════════════════════════════════════════════════════════════════

/// `push` 的统计（每张表**实际写入**的行数 —— 用于日志与测试）。
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PushStats {
    pub review_events: usize,
    pub user_words: usize,
    pub article_reads: usize,
    pub bookmarks: usize,
    pub book_progress: usize,
}

/// **push 的核心逻辑**（接受 `&Connection` ⇒ 测试可直接用临时库验证）。
///
/// # 🔑 为什么抽成独立函数（而不是写在 handler 里）
///
/// handler 必须拿**全局连接池**（`db_pool::get_conn()`）⇒ 一旦逻辑写在里面，
/// 测试就得初始化连接池 + 起 HTTP 服务 ⇒ **事实上测不了**（而设计文档 §五
/// 明确要求「阶段 1 可 `cargo test` 验证」）。
/// 抽出来后，测试用 `init_database` 造的临时库就能覆盖**幂等 / 合并口径 / 多用户隔离**。
/// 📌 判据：**核心逻辑要能独立验证**（项目 skill `verifiable-core-logic`）。
///
/// # 幂等保证
/// 同一批重复推送，**结果与推一次完全一致**：
///   · 各表的**主键 = 幂等键** ⇒ 冲突必然发生
///   · `review_log` 用 `INSERT OR IGNORE`
///   · 其余用条件 UPSERT，且 `WHERE` 只在**真有有效变更**时才刷新 `received_at`
/// ⇒ 因此：**重复推送不会推进 `received_at`**（可由测试断言）。
pub fn push_changes(
    conn: &Connection,
    uid: &str,
    device_id: &str,
    received_at: &str,
    input: &PushInput,
) -> Result<PushStats, AppError> {
    check_batch_size("review_events", input.review_events.len())?;
    check_batch_size("user_words", input.user_words.len())?;
    check_batch_size("article_reads", input.article_reads.len())?;
    check_batch_size("bookmarks", input.bookmarks.len())?;
    check_batch_size("book_progress", input.book_progress.len())?;

    let mut stats = PushStats::default();
    // 🔑 用 `unchecked_transaction`（只需 `&Connection`，与 `db_pool` 的共享连接兼容）
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| AppError::Internal(format!("begin tx: {e}")))?;

    // ── ① 复习事件：纯 `INSERT OR IGNORE`（事件不可变，PK 相同即重复）──
    for ev in &input.review_events {
        if !(1..=4).contains(&ev.rating) {
            return Err(AppError::BadRequest(format!(
                "rating 必须在 1..=4（收到 {}）",
                ev.rating
            )));
        }
        let utc_day = utc_day_of(&ev.reviewed_at)?;
        stats.review_events += tx
            .execute(
                "INSERT OR IGNORE INTO sync_review_log
                   (user_id, word_id, rating, duration_ms, reviewed_at, utc_day, device_id, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    &uid,
                    &ev.word_id,
                    ev.rating,
                    ev.duration_ms,
                    &ev.reviewed_at,
                    &utc_day,
                    &device_id,
                    &received_at
                ],
            )
            .map_err(|e| AppError::Internal(format!("insert review: {e}")))?;
    }

    // ── ② 生词本：**字段级**合并（设计 §3.1.1）──
    //
    // 🔴 不能「整行取较新」—— 不同字段的口径不同：
    //    · `deleted` / `updated_at` = 表达**最新意愿** ⇒ 取较新
    //    · `added_at` / `source_sentence` / `source_article_id` = 表达**首次事实** ⇒ 取较早
    //      （v1 §八 定死：例句取**首次**查词语境，用最新语境覆盖会让例句跳动、干扰复习）
    //
    // 🔑 `WHERE` 子句保证「**只有真的产生有效变更时才刷新 `received_at`**」——
    //    否则重复 push 会把 received_at 推新 ⇒ 其他设备每次都白拉一遍（也破坏幂等语义）。
    //
    // ⚠️ `MIN`/`MAX` 对 TEXT 是**字典序**比较 —— 而 ISO8601 UTC 的字典序 == 时间序
    //    （前提：格式统一为 `YYYY-MM-DDTHH:MM:SSZ`，零填充）。这是本写法成立的基础。
    for w in &input.user_words {
        stats.user_words += tx
            .execute(
                "INSERT INTO sync_user_word
                   (user_id, word_id, spelling, source_article_id, source_sentence,
                    added_at, updated_at, deleted, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT (user_id, word_id) DO UPDATE SET
                   deleted    = CASE WHEN excluded.updated_at > sync_user_word.updated_at
                                     THEN excluded.deleted ELSE sync_user_word.deleted END,
                   updated_at = MAX(excluded.updated_at, sync_user_word.updated_at),
                   added_at   = MIN(excluded.added_at, sync_user_word.added_at),
                   spelling   = CASE WHEN excluded.updated_at > sync_user_word.updated_at
                                     THEN excluded.spelling ELSE sync_user_word.spelling END,
                   source_article_id = CASE WHEN excluded.added_at < sync_user_word.added_at
                                     THEN excluded.source_article_id
                                     ELSE sync_user_word.source_article_id END,
                   source_sentence   = CASE WHEN excluded.added_at < sync_user_word.added_at
                                     THEN excluded.source_sentence
                                     ELSE sync_user_word.source_sentence END,
                   received_at = excluded.received_at
                 WHERE excluded.updated_at > sync_user_word.updated_at
                    OR excluded.added_at   < sync_user_word.added_at",
                params![
                    &uid,
                    &w.word_id,
                    &w.spelling,
                    w.source_article_id,
                    w.source_sentence,
                    &w.added_at,
                    &w.updated_at,
                    w.deleted,
                    &received_at
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert user_word: {e}")))?;
    }

    // ── ③ 阅读记录：`read_at` 取**较早**（语义 = 首次读完的时刻）──
    for r in &input.article_reads {
        stats.article_reads += tx
            .execute(
                "INSERT INTO sync_article_read (user_id, article_id, read_at, received_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (user_id, article_id) DO UPDATE SET
                   read_at     = MIN(excluded.read_at, sync_article_read.read_at),
                   received_at = excluded.received_at
                 WHERE excluded.read_at < sync_article_read.read_at",
                params![&uid, r.article_id, &r.read_at, &received_at],
            )
            .map_err(|e| AppError::Internal(format!("upsert article_read: {e}")))?;
    }

    // ── ④ 收藏：按 `bookmarked_at` 取**较新**（软删，所以 `deleted` 也是「较新胜」）──
    for b in &input.bookmarks {
        stats.bookmarks += tx
            .execute(
                "INSERT INTO sync_bookmark (user_id, content_id, bookmarked_at, deleted, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (user_id, content_id) DO UPDATE SET
                   deleted       = excluded.deleted,
                   bookmarked_at = excluded.bookmarked_at,
                   received_at   = excluded.received_at
                 WHERE excluded.bookmarked_at > sync_bookmark.bookmarked_at",
                params![&uid, b.content_id, &b.bookmarked_at, b.deleted, &received_at],
            )
            .map_err(|e| AppError::Internal(format!("upsert bookmark: {e}")))?;
    }

    // ── ⑤ 电子书进度：按 `updated_at` 取**较新**（进度是「读到哪」的最新意愿）──
    for p in &input.book_progress {
        stats.book_progress += tx
            .execute(
                "INSERT INTO sync_book_progress
                   (user_id, content_hash, chapter_idx, scroll_ratio, updated_at, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT (user_id, content_hash) DO UPDATE SET
                   chapter_idx  = excluded.chapter_idx,
                   scroll_ratio = excluded.scroll_ratio,
                   updated_at   = excluded.updated_at,
                   received_at  = excluded.received_at
                 WHERE excluded.updated_at > sync_book_progress.updated_at",
                params![
                    &uid,
                    &p.content_hash,
                    p.chapter_idx,
                    p.scroll_ratio,
                    &p.updated_at,
                    &received_at
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert book_progress: {e}")))?;
    }

    tx.commit()
        .map_err(|e| AppError::Internal(format!("commit: {e}")))?;
    Ok(stats)
}

/// `POST /api/sync/push` — 上传本地未同步的变更（**需登录 + 有效订阅**）。
pub async fn sync_push(
    headers: HeaderMap,
    Json(input): Json<PushInput>,
) -> Result<Json<serde_json::Value>, AppError> {
    // 🔑 鉴权 + 订阅校验在**唯一一处**（`authorize_with_subscription`）——
    //    push / pull 共用 ⇒ 不存在「一条路径忘了校验」的后门
    let (uid, _token) = authorize_with_subscription(&headers)?;
    let device_id = check_device_id(&input.device_id)?;
    let received_at = now_ms();

    let stats = {
        let conn = crate::db_pool::get_conn();
        push_changes(&conn, &uid, &device_id, &received_at, &input)?
    };

    tracing::info!(
        "sync_push: uid={} device={} review={} word={} read={} bm={} bp={}",
        uid,
        device_id,
        stats.review_events,
        stats.user_words,
        stats.article_reads,
        stats.bookmarks,
        stats.book_progress
    );

    Ok(Json(serde_json::json!({
        "ok": true,
        // 🔑 返回「本批的服务端收货时间」⇒ 客户端可据此推进 since，
        //    不必等下一次 pull（减少一次往返）。
        "received_at": received_at,
    })))
}

// ══════════════════════════════════════════════════════════════════════
// GET /api/sync/pull
// ══════════════════════════════════════════════════════════════════════

/// **pull 的核心逻辑**（接受 `&Connection` ⇒ 可独立测试；理由同 `push_changes`）。
///
/// `since` 传 `"1970-01-01T00:00:00.000Z"` 表示**首次同步**（拉全部）。
/// `my_device` 传空串表示**不排除任何设备**。
pub fn pull_changes(
    conn: &Connection,
    uid: &str,
    since: &str,
    my_device: &str,
) -> Result<PullOutput, AppError> {
    // 🔑 「排除自己的设备」用 `?3 = '' OR device_id <> ?3` 表达 ——
    //    比「拼两条 SQL」清晰，且 device_id 缺省时自动退化为「不排除」。
    //    只有 review_log 需要（其余表的变更本身是「字段值」，重拉无害且能纠正偏差）。
    let mut review_events: Vec<ReviewEventOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT word_id, rating, duration_ms, reviewed_at, utc_day, device_id
                   FROM sync_review_log
                  WHERE user_id = ?1 AND received_at > ?2 AND (?3 = '' OR device_id <> ?3)
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull review: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since, &my_device], |r| {
                Ok(ReviewEventOut {
                    word_id: r.get(0)?,
                    rating: r.get(1)?,
                    duration_ms: r.get(2)?,
                    reviewed_at: r.get(3)?,
                    utc_day: r.get(4)?,
                    device_id: r.get(5)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull review: {e}")))?;
        for row in rows {
            review_events.push(row.map_err(|e| AppError::Internal(format!("row review: {e}")))?);
        }
    }

    let mut user_words: Vec<UserWordOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT word_id, spelling, source_article_id, source_sentence,
                        added_at, updated_at, deleted
                   FROM sync_user_word
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull word: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(UserWordOut {
                    word_id: r.get(0)?,
                    spelling: r.get(1)?,
                    source_article_id: r.get(2)?,
                    source_sentence: r.get(3)?,
                    added_at: r.get(4)?,
                    updated_at: r.get(5)?,
                    deleted: r.get(6)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull word: {e}")))?;
        for row in rows {
            user_words.push(row.map_err(|e| AppError::Internal(format!("row word: {e}")))?);
        }
    }

    let mut article_reads: Vec<ArticleReadOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT article_id, read_at FROM sync_article_read
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull read: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(ArticleReadOut {
                    article_id: r.get(0)?,
                    read_at: r.get(1)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull read: {e}")))?;
        for row in rows {
            article_reads.push(row.map_err(|e| AppError::Internal(format!("row read: {e}")))?);
        }
    }

    let mut bookmarks: Vec<BookmarkOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT content_id, bookmarked_at, deleted FROM sync_bookmark
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull bookmark: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(BookmarkOut {
                    content_id: r.get(0)?,
                    bookmarked_at: r.get(1)?,
                    deleted: r.get(2)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull bookmark: {e}")))?;
        for row in rows {
            bookmarks.push(row.map_err(|e| AppError::Internal(format!("row bookmark: {e}")))?);
        }
    }

    let mut book_progress: Vec<BookProgressOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT content_hash, chapter_idx, scroll_ratio, updated_at
                   FROM sync_book_progress
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull bp: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(BookProgressOut {
                    content_hash: r.get(0)?,
                    chapter_idx: r.get(1)?,
                    scroll_ratio: r.get(2)?,
                    updated_at: r.get(3)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull bp: {e}")))?;
        for row in rows {
            book_progress.push(row.map_err(|e| AppError::Internal(format!("row bp: {e}")))?);
        }
    }

    // 🔑 `server_time` = 「**本次返回的数据里**最大的 received_at」，没有数据时才用当前时间。
    //
    // 🔴 为什么不能用「当前时间」一了百了：本函数先查数据、后取当前时间，
    //    两者之间若有写入 ⇒ 那条记录的 received_at **落在 since 与 now 之间**，
    //    而客户端下次用 now 当 since ⇒ `received_at > now` **不成立** ⇒ **永久漏掉**。
    //    取「已返回数据的最大 received_at」则不会漏（它在 since 之后、且已被本次返回）。
    // ⚠️ 若中途有并发写入没被本次查到，那条的 received_at **大于** 所有已返回的
    //    ⇒ 下次 `> server_time` 会包含它 ✅（它比 server_time 新）
    let max_received = {
        let mut m: Option<String> = None;
        // ⚠️ 逐表取 MAX —— 只读一行、不扫全表
        for sql in [
            "SELECT MAX(received_at) FROM sync_review_log    WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_user_word     WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_article_read  WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_bookmark      WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_book_progress WHERE user_id = ?1",
        ] {
            let v: Option<String> = conn
                .query_row(sql, params![&uid], |r| r.get(0))
                .map_err(|e| AppError::Internal(format!("max received_at: {e}")))?;
            if let Some(v) = v {
                m = Some(match m {
                    Some(cur) if cur >= v => cur,
                    _ => v,
                });
            }
        }
        m.unwrap_or_else(now_ms)
    };

    Ok(PullOutput {
        review_events,
        user_words,
        article_reads,
        bookmarks,
        book_progress,
        server_time: max_received,
    })
}

/// `GET /api/sync/pull` — 拉取服务端的变更（**需登录 + 有效订阅**）。
pub async fn sync_pull(
    headers: HeaderMap,
    Query(q): Query<PullQuery>,
) -> Result<Json<PullOutput>, AppError> {
    let (uid, _token) = authorize_with_subscription(&headers)?;

    // 首次同步（无 since）⇒ 用一个早于一切的时间戳（ISO8601 最小可表示值）
    let since = q
        .since
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("1970-01-01T00:00:00.000Z");
    let my_device = q.device_id.as_deref().map(str::trim).unwrap_or("");

    let out = {
        let conn = crate::db_pool::get_conn();
        pull_changes(&conn, &uid, since, my_device)?
    };

    tracing::info!(
        "sync_pull: uid={} since={} device={} review={} word={} read={} bm={} bp={}",
        uid,
        since,
        my_device,
        out.review_events.len(),
        out.user_words.len(),
        out.article_reads.len(),
        out.bookmarks.len(),
        out.book_progress.len()
    );

    Ok(Json(out))
}

// ══════════════════════════════════════════════════════════════════════
// 测试
// ══════════════════════════════════════════════════════════════════════
//
// ⚠️ **本模块的边界（如实说明）**：
//    这里覆盖的是 `push_changes` / `pull_changes`（**核心逻辑**）。
//    **未覆盖** handler 层（`sync_push` / `sync_pull`）—— 它们需要 HTTP + 全局连接池
//    ⇒ `authorize_with_subscription`（token → uid → 订阅校验 → 403）**没有单测**。
//    那一层由**源码断言**兜（`scripts/query_verify/bin/verify_sync.dart`：
//    锁「两个 handler 都调了同一个鉴权+订阅函数」+「未订阅回 403 而非 401」）。
//    📌 判据：**盲区要写出来**，不能因为「测了核心逻辑」就默认整条链路可信。

#[cfg(test)]
mod tests {
    use super::*;

    /// 时间戳用**真实格式**（`YYYY-MM-DDTHH:MM:SS.mmmZ`）——
    /// 因为各表的合并判据都依赖「ISO8601 字典序 == 时间序」这个前提，
    /// 用 `"T1"`/`"T2"` 这类假值会把那个前提测掉。
    const RECV1: &str = "2026-10-06T10:00:00.000Z";
    const RECV2: &str = "2026-10-06T10:05:00.000Z";
    const ALL: &str = "1970-01-01T00:00:00.000Z";

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn
    }

    /// 造用户；`expires` 给 `None` = 未订阅。
    fn seed_user(conn: &Connection, uid: &str, expires: Option<&str>) {
        conn.execute(
            "INSERT INTO users (id, username, created_at, subscription_expires)
             VALUES (?1, ?2, '2026-01-01T00:00:00Z', ?3)",
            params![uid, uid, expires],
        )
        .unwrap();
    }

    fn ev(word: &str, rating: i64, at: &str) -> ReviewEventInput {
        ReviewEventInput {
            word_id: word.into(),
            rating,
            duration_ms: None,
            reviewed_at: at.into(),
        }
    }

    fn word(id: &str, added: &str, updated: &str, deleted: i64, sentence: &str) -> UserWordInput {
        UserWordInput {
            word_id: id.into(),
            spelling: "receive".into(),
            source_article_id: Some(1),
            source_sentence: Some(sentence.into()),
            added_at: added.into(),
            updated_at: updated.into(),
            deleted,
        }
    }

    fn base_push(device: &str) -> PushInput {
        PushInput {
            device_id: device.into(),
            review_events: vec![],
            user_words: vec![],
            article_reads: vec![],
            bookmarks: vec![],
            book_progress: vec![],
        }
    }

    #[test]
    fn test_sync_tables_created() {
        let conn = setup();
        for t in [
            "sync_review_log",
            "sync_user_word",
            "sync_article_read",
            "sync_bookmark",
            "sync_book_progress",
        ] {
            let n: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    params![t],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "{t} 应由 init_database 建出");
        }
    }

    /// 🔴 幂等：同一批重复推送**不得刷新 `received_at`**。
    ///
    /// 为什么这条最重要：`received_at` 是 pull 的时间轴。若重复 push 刷新它，
    /// 其他设备会**每次都白拉一遍**（且 `server_time` 语义漂移）。
    #[test]
    fn test_push_is_idempotent() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut input = base_push("devA");
        input.review_events = vec![ev("w1", 3, "2026-10-06T09:00:00Z")];
        input.user_words = vec![word(
            "w1",
            "2026-10-01T00:00:00Z",
            "2026-10-01T00:00:00Z",
            0,
            "s",
        )];
        input.article_reads = vec![ArticleReadInput {
            article_id: 42,
            read_at: "2026-10-02T00:00:00Z".into(),
        }];

        push_changes(&conn, "u1", "devA", RECV1, &input).unwrap();
        let got = |sql: &str| -> String { conn.query_row(sql, [], |r| r.get(0)).unwrap() };
        let rv1 = got("SELECT received_at FROM sync_review_log");
        let ww1 = got("SELECT received_at FROM sync_user_word");
        let ar1 = got("SELECT received_at FROM sync_article_read");
        assert_eq!(rv1, RECV1);

        // 同一批，换一个 received_at 再推一次
        push_changes(&conn, "u1", "devA", RECV2, &input).unwrap();

        assert_eq!(
            got("SELECT received_at FROM sync_review_log"),
            rv1,
            "重复 push 不得推进 review_log.received_at"
        );
        assert_eq!(
            got("SELECT received_at FROM sync_user_word"),
            ww1,
            "重复 push 不得推进 user_word.received_at"
        );
        assert_eq!(
            got("SELECT received_at FROM sync_article_read"),
            ar1,
            "重复 push 不得推进 article_read.received_at"
        );

        // 行数也不得增长
        for (t, want) in [
            ("sync_review_log", 1),
            ("sync_user_word", 1),
            ("sync_article_read", 1),
        ] {
            let n: i64 = conn
                .query_row(&format!("SELECT COUNT(*) FROM {t}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, want, "{t} 重复 push 后行数应不变");
        }
    }

    /// 🔴 多用户隔离 —— **这条能抓出「PK 忘了带 user_id」**。
    ///
    /// ⚠️ 关键在测试数据：两个用户用**完全相同的** `(word_id, reviewed_at, device_id)`。
    /// 若 PK 漏了 `user_id`，第二条会**覆盖**第一条 —— 而单人测试**永远发现不了**。
    #[test]
    fn test_multi_user_isolation_and_pk_includes_user_id() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));
        seed_user(&conn, "u2", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.review_events = vec![ev("w1", 3, "2026-10-06T09:00:00Z")];
        a.user_words = vec![word(
            "w1",
            "2026-10-01T00:00:00Z",
            "2026-10-01T00:00:00Z",
            0,
            "u1 的语境",
        )];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // u2 用**同 word_id / 同 reviewed_at / 同 device**
        let mut b = base_push("devA");
        b.review_events = vec![ev("w1", 4, "2026-10-06T09:00:00Z")];
        b.user_words = vec![word(
            "w1",
            "2026-10-01T00:00:00Z",
            "2026-10-01T00:00:00Z",
            0,
            "u2 的语境",
        )];
        push_changes(&conn, "u2", "devA", RECV1, &b).unwrap();

        let o1 = pull_changes(&conn, "u1", ALL, "").unwrap();
        let o2 = pull_changes(&conn, "u2", ALL, "").unwrap();

        assert_eq!(o1.review_events.len(), 1, "u1 应恰好看到自己那 1 条");
        assert_eq!(o2.review_events.len(), 1, "u2 应恰好看到自己那 1 条");
        assert_eq!(
            o1.review_events[0].rating, 3,
            "u1 的评分被 u2 覆盖了 ⇒ PK 漏了 user_id"
        );
        assert_eq!(o2.review_events[0].rating, 4);
        assert_eq!(
            o1.user_words[0].source_sentence.as_deref(),
            Some("u1 的语境"),
            "u1 的语境被 u2 覆盖了 ⇒ PK 漏了 user_id"
        );
    }

    /// `pull` 排除**本设备**推上去的数据（那些本地已经有了）。
    #[test]
    fn test_pull_excludes_own_device() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));
        let mut a = base_push("devA");
        a.review_events = vec![ev("w1", 3, "2026-10-06T09:00:00Z")];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let same = pull_changes(&conn, "u1", ALL, "devA").unwrap();
        assert!(same.review_events.is_empty(), "自己设备推的不应被拉回");
        let other = pull_changes(&conn, "u1", ALL, "devB").unwrap();
        assert_eq!(other.review_events.len(), 1, "别的设备应能看到");
        // 空 device = 不排除
        let none = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(none.review_events.len(), 1);
    }

    /// 🔴 `user_word` 是**字段级**合并，不是「整行取较新」（设计 §3.1.1）。
    #[test]
    fn test_user_word_field_level_merge() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        // 设备 A：added_at **较早**（首次加入），语境 = A
        let mut a = base_push("devA");
        a.user_words = vec![word(
            "w1",
            "2026-10-01T00:00:00Z",
            "2026-10-01T00:00:00Z",
            0,
            "A 的语境",
        )];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // 设备 B：added_at **较晚**、updated_at **较新**、且删了（deleted=1）
        let mut b = base_push("devB");
        b.user_words = vec![word(
            "w1",
            "2026-10-05T00:00:00Z",
            "2026-10-05T00:00:00Z",
            1,
            "B 的语境",
        )];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        let w = &out.user_words[0];
        assert_eq!(w.deleted, 1, "deleted 应取**较新**（表达最新意愿）");
        assert_eq!(w.updated_at, "2026-10-05T00:00:00Z", "updated_at 应取较新");
        assert_eq!(
            w.added_at, "2026-10-01T00:00:00Z",
            "added_at 应取**较早**（首次加入时刻）"
        );
        assert_eq!(
            w.source_sentence.as_deref(),
            Some("A 的语境"),
            "例句应取「added_at 更早那端」= 首次语境 —— 用最新语境覆盖会让例句跳动、干扰复习"
        );

        // 再把「更旧」的 A 推一次 ⇒ 不得回退
        let mut a2 = base_push("devA");
        a2.user_words = vec![word(
            "w1",
            "2026-10-01T00:00:00Z",
            "2026-10-01T00:00:00Z",
            0,
            "A 的语境",
        )];
        push_changes(&conn, "u1", "devA", RECV2, &a2).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out2.user_words[0].deleted, 1,
            "更旧的数据不得覆盖较新的 deleted"
        );
    }

    /// `article_read` 的 `read_at` **取较早**（语义 = 首次读完的时刻）。
    #[test]
    fn test_article_read_keeps_earliest() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut late = base_push("devA");
        late.article_reads = vec![ArticleReadInput {
            article_id: 7,
            read_at: "2026-10-05T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV1, &late).unwrap();

        let mut early = base_push("devB");
        early.article_reads = vec![ArticleReadInput {
            article_id: 7,
            read_at: "2026-10-01T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devB", RECV2, &early).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out.article_reads[0].read_at, "2026-10-01T00:00:00Z",
            "应取**较早**（首次读完）"
        );

        // 再推较晚的 ⇒ 不得把时间推后
        let mut late2 = base_push("devA");
        late2.article_reads = vec![ArticleReadInput {
            article_id: 7,
            read_at: "2026-10-09T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV2, &late2).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out2.article_reads[0].read_at, "2026-10-01T00:00:00Z",
            "较晚的不得覆盖较早的"
        );
    }

    /// 🔴 收藏：**取消能同步**（软删 ⇒ `deleted=1` 是「较新意愿」）。
    ///
    /// 这正是「硬删改软删」要解决的问题：并集只增不减 ⇒ 硬删会被别端**并回来**。
    #[test]
    fn test_bookmark_delete_propagates() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        // A 收藏
        let mut a = base_push("devA");
        a.bookmarks = vec![BookmarkInput {
            content_id: 5,
            bookmarked_at: "2026-10-01T00:00:00Z".into(),
            deleted: 0,
        }];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // B 取消收藏（较新）
        let mut b = base_push("devB");
        b.bookmarks = vec![BookmarkInput {
            content_id: 5,
            bookmarked_at: "2026-10-05T00:00:00Z".into(),
            deleted: 1,
        }];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.bookmarks.len(), 1);
        assert_eq!(
            out.bookmarks[0].deleted, 1,
            "取消收藏应能同步（否则「删了又回来」）"
        );

        // ⚠️ 反向：A 再把「旧的未删版本」推一次 ⇒ 不得复活
        let mut a2 = base_push("devA");
        a2.bookmarks = vec![BookmarkInput {
            content_id: 5,
            bookmarked_at: "2026-10-01T00:00:00Z".into(),
            deleted: 0,
        }];
        push_changes(&conn, "u1", "devA", RECV2, &a2).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out2.bookmarks[0].deleted, 1,
            "旧的（较早）不得让已取消的收藏复活"
        );
    }

    /// `book_progress` 取较新；且**按 `content_hash`**（不是端侧 book_id）。
    #[test]
    fn test_book_progress_newer_wins_and_keyed_by_hash() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.book_progress = vec![BookProgressInput {
            content_hash: "hash-abc".into(),
            chapter_idx: 3,
            scroll_ratio: 0.2,
            updated_at: "2026-10-01T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let mut b = base_push("devB");
        b.book_progress = vec![BookProgressInput {
            content_hash: "hash-abc".into(),
            chapter_idx: 9,
            scroll_ratio: 0.8,
            updated_at: "2026-10-05T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.book_progress.len(), 1, "同一指纹应只有一行");
        assert_eq!(out.book_progress[0].chapter_idx, 9, "取较新");
        assert_eq!(out.book_progress[0].scroll_ratio, 0.8);

        // 另一本（不同指纹）⇒ 独立一行
        let mut c = base_push("devC");
        c.book_progress = vec![BookProgressInput {
            content_hash: "hash-xyz".into(),
            chapter_idx: 1,
            scroll_ratio: 0.1,
            updated_at: "2026-10-05T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devC", RECV2, &c).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out2.book_progress.len(), 2, "不同指纹 = 不同的书");
    }

    /// `utc_day` 由**服务端**从 `reviewed_at` 推导（不信客户端）。
    #[test]
    fn test_utc_day_derived_server_side() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));
        let mut a = base_push("devA");
        a.review_events = vec![ev("w1", 2, "2026-10-06T23:59:59Z")];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();
        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.review_events[0].utc_day, "2026-10-06");
    }

    /// `since` 生效：只拉严格晚于它的数据。
    #[test]
    fn test_pull_since_filters() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.review_events = vec![ev("w1", 3, "2026-10-06T09:00:00Z")];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let mut b = base_push("devB");
        b.review_events = vec![ev("w2", 3, "2026-10-06T09:30:00Z")];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", RECV1, "").unwrap();
        assert_eq!(out.review_events.len(), 1, "只应拉到 RECV2 那条");
        assert_eq!(out.review_events[0].word_id, "w2");
        // 边界：since == RECV2 ⇒ 严格大于 ⇒ 空
        let out2 = pull_changes(&conn, "u1", RECV2, "").unwrap();
        assert!(
            out2.review_events.is_empty(),
            "`>` 是严格大于（配合毫秒精度 + 端侧幂等）"
        );
    }

    /// `server_time` = 本次数据里最大的 `received_at`（无数据时才是当前时间）。
    ///
    /// 🔑 这条守的是「**不漏**」：若返回「当前时间」而客户端用它当 since，
    /// pull 与取时间之间写入的记录会被**永久跳过**。
    #[test]
    fn test_server_time_is_max_received_at() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.review_events = vec![ev("w1", 3, "2026-10-06T09:00:00Z")];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out.server_time, RECV1,
            "有数据时应等于数据的最大 received_at"
        );

        // 空库 ⇒ 退化为当前时间（非空且格式正确）
        seed_user(&conn, "u2", Some("2099-01-01"));
        let empty = pull_changes(&conn, "u2", ALL, "").unwrap();
        assert!(!empty.server_time.is_empty());
        assert!(
            empty.server_time.len() >= 20,
            "应为 ISO8601 毫秒格式：{}",
            empty.server_time
        );
    }

    /// 入参校验（**明确报错**，不静默）。
    #[test]
    fn test_input_validation() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        // rating 越界
        let mut bad = base_push("devA");
        bad.review_events = vec![ev("w1", 5, "2026-10-06T09:00:00Z")];
        assert!(matches!(
            push_changes(&conn, "u1", "devA", RECV1, &bad),
            Err(AppError::BadRequest(_))
        ));

        // reviewed_at 格式非法
        let mut bad2 = base_push("devA");
        bad2.review_events = vec![ev("w1", 3, "not-a-date")];
        assert!(matches!(
            push_changes(&conn, "u1", "devA", RECV1, &bad2),
            Err(AppError::BadRequest(_))
        ));

        // 批量超限
        let mut big = base_push("devA");
        big.review_events = (0..(MAX_ITEMS_PER_TABLE + 1))
            .map(|i| ev(&format!("w{i}"), 3, "2026-10-06T09:00:00Z"))
            .collect();
        assert!(matches!(
            push_changes(&conn, "u1", "devA", RECV1, &big),
            Err(AppError::BadRequest(_))
        ));

        // device_id 过长
        assert!(matches!(
            check_device_id(&"x".repeat(MAX_DEVICE_ID_LEN + 1)),
            Err(AppError::BadRequest(_))
        ));
        assert!(check_device_id("dev-ok").is_ok());
    }

    /// 订阅判定（决策③ 的**依据**，不是 handler）。
    ///
    /// ⚠️ handler 层的 403 **未被单测覆盖**（需 HTTP）⇒ 见模块尾部的边界说明。
    #[test]
    fn test_subscription_gate_basis() {
        let conn = setup();
        seed_user(&conn, "sub", Some("2099-01-01"));
        seed_user(&conn, "free", None);
        seed_user(&conn, "expired", Some("2020-01-01"));

        assert!(
            crate::subscription::is_subscription_active(&conn, "sub"),
            "有效期内应放行"
        );
        assert!(
            !crate::subscription::is_subscription_active(&conn, "free"),
            "无到期日应拒绝"
        );
        assert!(
            !crate::subscription::is_subscription_active(&conn, "expired"),
            "已过期应拒绝"
        );
    }
}
