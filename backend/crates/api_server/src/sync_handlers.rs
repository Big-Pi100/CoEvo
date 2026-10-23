//! 云端同步（订阅权益）—— `push` / `pull`
//!
//! 📄 设计依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §四（协议）
//! 白哥 2026-10-05 批准的 3 个决策：
//!   ① 改隐私政策以允许同步（已做）
//!   ② **多端登录**（推翻 L0 的「单端踢旧」）
//!   ③ 🔴 **push/pull 校验有效订阅** —— ⚠️ **2026-10-13 已修正**：
//!      **push 校验订阅 · pull 只校验登录**（拉取是「出口」，
//!      依据 [`authorize_login_only`] 判据表「**限制入口可以，限制出口不行**」）。
//!      详见 `sync_pull` 的文档与那次实测（云端数据被锁、用户以为全丢了）。
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

/// 划线记忆。
///
/// 🔴 **本表是 2026-10-09 才加的，它补的是一个真实缺口**（见 `schema.rs::SYNC_SCHEMA_SQL`
///    里 `sync_highlight` 的说明）：
///    在此之前只有 `review_log`（复习事件）同步，而事件里 `hl:<uuid>` 指向的**划线本体不同步**
///    ⇒ 重装 / 换机的设备会拿到「无主划线卡」（标题是 `hl:<uuid>`、点暂停无反应）。
///    📌 判据：**同步的粒度必须覆盖「引用关系」**。
///
/// ⚠️ 没有 `pending_push`（端侧概念）；也没有 `received_at`（服务端生成）。
#[derive(Debug, Deserialize)]
pub struct HighlightInput {
    /// 端侧生成的 uuid v4。🔴 **不能自增** —— 两台设备各自从 1 开始必撞。
    pub id: String,
    /// `article` / `book`（与端侧 `HighlightSourceType.wire` 逐字一致）。
    pub source_type: String,
    /// article: 文章 id（**文本形式**）· book: 端侧 `book.id`（uuid）。
    pub source_id: String,
    /// ⚠️ 可空：**只有书有**（文章是单页）。
    #[serde(default)]
    pub chapter_idx: Option<i64>,
    pub start_offset: i64,
    pub end_offset: i64,
    /// 🔴 选中的原文 —— 复习时的**标准答案**（不是可推导的派生值）。
    pub text: String,
    #[serde(default)]
    pub note: Option<String>,
    /// 「暂停复习」（离开复习列表，但**不删**这条划线）。
    #[serde(default)]
    pub paused: i64,
    #[serde(default)]
    pub deleted: i64,
    pub created_at: String,
    /// 最后一次改变该条状态的时刻（改笔记 / 暂停 / 取消都要刷新）。
    pub updated_at: String,
    /// 🆕 2026-10-11 该划线片段的中文译文（复习提示之一）。
    ///
    /// 🔴 **必须 `#[serde(default)]`（可空）** —— 老版本端侧不会带这个字段，
    ///    缺了它 serde 会直接**反序列化失败**（整个批次 400），而不是当成「没有译文」。
    #[serde(default)]
    pub translation: Option<String>,
}

/// 电子书进度（按**内容指纹**，不是 `book_id` —— 书籍 id 是端侧 uuid）。
#[derive(Debug, Deserialize)]
pub struct BookProgressInput {
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub updated_at: String,
    /// 🆕 2026-10-23 字符偏移（本章纯文本第几个字符）。
    ///
    /// 🔴 为什么加：翻页阅读器的分页是**字符**关系，`scroll_ratio` 是**像素**关系，
    ///    两者不是线性 —— 同一比例在字号 15/24 下指向不同句子。
    ///
    /// 🔑 `Option` + `default`：**老客户端不推这个字段**（`None`）—— 服务端存 NULL，
    ///    读端回退到 `scroll_ratio`。这样新旧版本可以同时在线。
    #[serde(default)]
    pub char_offset: Option<i64>,
}

/// 书单条目（**元数据**；文件本体走独立端点，见 `book_blob_handler`）。
///
/// 🔴 **这里没有 `blob_size`** —— 它不是端侧事实（见 `schema.rs::SYNC_SCHEMA_SQL`
/// 的 `sync_book` 说明）。端侧若想「把云端标记抹掉」是**做不到的**，这正是设计。
#[derive(Debug, Deserialize)]
pub struct BookInput {
    /// 内容指纹（跨设备身份）。⚠️ 服务端**只做长度/字符校验**，不重算 ——
    /// 重算需要原始文件，而 push 通道里只有元数据。
    pub content_hash: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub lang: String,
    #[serde(default)]
    pub chapter_count: i64,
    #[serde(default)]
    pub size_bytes: i64,
    pub added_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub deleted: i64,
}

/// 查词记录（**日志型**：内容一旦写入不再改 ⇒ `INSERT OR IGNORE`）。
///
/// 🔴 跨设备身份是 `uid`（端侧 uuid），**不是**端侧自增 id ——
///    自增 id 在两台设备上各自从 1 开始 ⇒ 必撞（同 `HighlightInput.id` 的判据）。
#[derive(Debug, Deserialize)]
pub struct LookupEventInput {
    pub uid: String,
    /// ⚠️ **可空**：查了但词库里没有 ⇒ `None`（白哥定「未命中也要记」）。
    #[serde(default)]
    pub word_id: Option<String>,
    pub spelling: String,
    #[serde(default)]
    pub article_id: Option<i64>,
    #[serde(default)]
    pub sentence: Option<String>,
    #[serde(default)]
    pub position: Option<i64>,
    pub looked_up_at: String,
}

/// 书本内书签。
///
/// 🔑 `content_hash` 是**书**的跨设备身份（不是端侧 `book_id` —— 那是端侧 uuid）。
/// 🔴 `deleted` 合并是 **OR**（任一端删过即删）—— 本表没有 `updated_at`，
///    「谁更新谁赢」在这里没有判据；而书签的「取消」是终局意愿（见 `schema.rs` 说明）。
#[derive(Debug, Deserialize)]
pub struct BookMarkerInput {
    pub id: String,
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub excerpt: String,
    pub created_at: String,
    #[serde(default)]
    pub deleted: i64,
    /// 🆕 2026-10-23 字符偏移（与 `BookProgressInput::char_offset` 同口径）；老客户端为 `None`。
    #[serde(default)]
    pub char_offset: Option<i64>,
}

/// 成就解锁记录（`unlocked_at` 取**较早** = 首次解锁时刻）。
#[derive(Debug, Deserialize)]
pub struct AchievementUnlockInput {
    pub key: String,
    pub unlocked_at: String,
}

/// 应用设置（**键值对** —— 与其余表形态不同的同步通道）。
///
/// 🔑 `value` 是端侧 `jsonEncode` 后的文本（bool / int / double / String / List 统一承载）
///    ⇒ 服务端只做搬运、不理解语义（语义是端侧知识）。
#[derive(Debug, Deserialize)]
pub struct SettingInput {
    pub key: String,
    pub value: String,
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
    /// 🆕 2026-10-09：划线记忆（**必须在 `bookmarks` 之后** —— 端侧按同一顺序组装，
    /// 顺序本身就是「有没有漏掉一张表」的可读信号）。
    #[serde(default)]
    pub highlights: Vec<HighlightInput>,
    #[serde(default)]
    pub book_progress: Vec<BookProgressInput>,
    #[serde(default)]
    pub books: Vec<BookInput>,
    /// 🆕 2026-10-10：查词记录（成就 `lookupCount` 的数据源）。
    #[serde(default)]
    pub lookup_events: Vec<LookupEventInput>,
    /// 🆕 2026-10-10：书本内书签（用户资产）。
    #[serde(default)]
    pub book_markers: Vec<BookMarkerInput>,
    /// 🆕 2026-10-10：成就解锁记录（保留真实解锁时间）。
    #[serde(default)]
    pub achievement_unlocks: Vec<AchievementUnlockInput>,
    /// 🆕 2026-10-10：应用设置（prefs 键值）。
    #[serde(default)]
    pub settings: Vec<SettingInput>,
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

/// 划线记忆（回应给端侧）。
///
/// 🔑 字段与 `HighlightInput` **逐字对应**（含 `paused`）——
///    `paused` 是**用户意图**（「这条先不复习了」），必须跨设备，
///    否则在 A 设备暂停的笔记到 B 设备又回来了。
#[derive(Debug, Serialize)]
pub struct HighlightOut {
    pub id: String,
    pub source_type: String,
    pub source_id: String,
    pub chapter_idx: Option<i64>,
    pub start_offset: i64,
    pub end_offset: i64,
    pub text: String,
    pub note: Option<String>,
    pub paused: i64,
    pub deleted: i64,
    pub created_at: String,
    pub updated_at: String,
    /// 🆕 2026-10-11 该划线片段的中文译文（复习提示之一）。`None` = 还没翻译/补译过。
    pub translation: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct BookProgressOut {
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub updated_at: String,
    /// 🆕 2026-10-23 字符偏移；老数据为 `None`（端侧回退到 `scroll_ratio` 换算）。
    pub char_offset: Option<i64>,
}

/// 书单条目（回应给端侧）。
///
/// 🔑 `blob_size` 是端侧判断「**云端有没有这本书**」的**唯一依据**：
///    `> 0` ⇒ 云端有 ⇒ 本地没有时可显示「云端」并允许下载。
#[derive(Debug, Serialize)]
pub struct BookOut {
    pub content_hash: String,
    pub title: String,
    pub author: String,
    pub lang: String,
    pub chapter_count: i64,
    pub size_bytes: i64,
    pub blob_size: i64,
    pub added_at: String,
    pub updated_at: String,
    pub deleted: i64,
}

#[derive(Debug, Serialize)]
pub struct LookupEventOut {
    pub uid: String,
    pub word_id: Option<String>,
    pub spelling: String,
    pub article_id: Option<i64>,
    pub sentence: Option<String>,
    pub position: Option<i64>,
    pub looked_up_at: String,
}

/// 书本内书签（回应给端侧）。
///
/// 🔑 `content_hash` 让端侧认出「这是**哪本书**的书签」（本地可能还没导入那本书
///    ⇒ 端侧先存进 `book_marker_pending`，等导入后认领）。
#[derive(Debug, Serialize)]
pub struct BookMarkerOut {
    pub id: String,
    pub content_hash: String,
    pub chapter_idx: i64,
    pub scroll_ratio: f64,
    pub excerpt: String,
    pub created_at: String,
    pub deleted: i64,
    /// 🆕 2026-10-23 字符偏移（与进度同口径）；老数据为 `None`。
    pub char_offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct AchievementUnlockOut {
    pub key: String,
    pub unlocked_at: String,
}

#[derive(Debug, Serialize)]
pub struct SettingOut {
    pub key: String,
    pub value: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize)]
pub struct PullOutput {
    pub review_events: Vec<ReviewEventOut>,
    pub user_words: Vec<UserWordOut>,
    pub article_reads: Vec<ArticleReadOut>,
    pub bookmarks: Vec<BookmarkOut>,
    /// 🆕 2026-10-09：划线记忆（同 `PushInput.highlights`）。
    pub highlights: Vec<HighlightOut>,
    pub book_progress: Vec<BookProgressOut>,
    pub books: Vec<BookOut>,
    /// 🆕 2026-10-10：查词记录。
    pub lookup_events: Vec<LookupEventOut>,
    /// 🆕 2026-10-10：书本内书签。
    pub book_markers: Vec<BookMarkerOut>,
    /// 🆕 2026-10-10：成就解锁记录。
    pub achievement_unlocks: Vec<AchievementUnlockOut>,
    /// 🆕 2026-10-10：应用设置。
    pub settings: Vec<SettingOut>,
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
/// 服务端当前时间（毫秒精度）。`pub(crate)`：翻译额度也要用**同一个**时间口径
/// （判据：同一件事的口径只能一处权威）。
pub(crate) fn now_ms() -> String {
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
/// **只校验登录**（不校验订阅）—— 返回 `(uid, token)`。
///
/// # 🔑 为什么需要它（而不是到处用 `authorize_with_subscription`）
///
/// 书架的**下载 / 删除**端点**刻意不要求订阅**：
/// 订阅过期后，用户**必须仍能取回和删除**自己已上传的书。
/// 否则「数据不丢」这句承诺是假的 —— 那正是订阅的全部卖点。
///
/// | 动作 | 要求 | 为什么 |
/// |---|---|---|
/// | **推送**同步（push）| 登录 + **订阅** | 它是订阅权益；且**消耗**服务端写入 |
/// | **拉取**同步（pull）| **只需登录** | 🔑 与「下载文件」同族：**取回权不随订阅到期而消失** |
/// | **上传**文件（占配额）| 登录 + **订阅** | 消耗服务端资源 |
/// | **下载**文件 | **只需登录** | 🔑 已付费期间存进去的数据，取回权不随订阅到期而消失 |
/// | **删除**文件 | **只需登录** | 否则过期用户的配额被**永久占用**（他也删不掉）|
///
/// 📌 判据：**「付费买的是存储，不是访问权」** —— 限制入口可以，限制出口不行。
///
/// 🔴 2026-10-13 修正：本表原先把「**拉取同步**」也写成「登录 + 订阅」，
///    **与上面这条判据自相矛盾**（拉取是**出口**）。后果被实测抓到 ——
///    `690861018@qq.com` 的订阅被清空后，云端 **258 行**数据**完好无损**，
///    但 `pull` 一律 **403** ⇒ 用户在界面上看到的是「**数据全都没了**」。
///    ✅ 已把 pull 归入「只需登录」。
///    📌 教训：**判据写对了但没逐行落实 = 等于没写** ——
///       这张表里**每一行都要拿判据校验一遍**，而不是只看「有没有写判据」。
pub(crate) fn authorize_login_only(headers: &HeaderMap) -> Result<(String, String), AppError> {
    // ① 取 token（**唯一实现**在 `user_purge::extract_bearer_token`）
    let token = crate::user_purge::extract_bearer_token(headers)?;
    let conn = crate::db_pool::get_conn();
    // ② token → uid（**唯一实现**在 `auth::uid_by_token`）
    let uid = crate::auth::uid_by_token(&conn, &token).map_err(AppError::Unauthorized)?;
    Ok((uid, token))
}

/// **登录 + 订阅** —— **仅 `push` 用**（写入侧准入）。
///
/// 🔴 2026-10-13：`pull` **不再**走这里（改为 [`authorize_login_only`]）——
///    拉取是「**出口**」，按判据表只需登录。详见 `sync_pull` 的文档。
///    ⇒ 本函数现在**只有 `sync_push` 一个调用点**；
///      若将来又多出调用方，先问一句：**它是入口还是出口？**
///
/// 🔑 token 解析只走 [`authorize_login_only`] 一处 —— 两份实现迟早漂移
///    （本项目在「文本断言」上已踩过「同一口径两处实现」的坑）。
fn authorize_with_subscription(headers: &HeaderMap) -> Result<(String, String), AppError> {
    let (uid, token) = authorize_login_only(headers)?;
    // 🔴 订阅校验（决策③）
    let conn = crate::db_pool::get_conn();
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
    /// 🆕 2026-10-09：划线记忆。
    pub highlights: usize,
    pub book_progress: usize,
    pub books: usize,
    /// 🆕 2026-10-10：查词记录。
    pub lookup_events: usize,
    /// 🆕 2026-10-10：书本内书签。
    pub book_markers: usize,
    /// 🆕 2026-10-10：成就解锁记录。
    pub achievement_unlocks: usize,
    /// 🆕 2026-10-10：应用设置。
    pub settings: usize,
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
    check_batch_size("highlights", input.highlights.len())?;
    check_batch_size("book_progress", input.book_progress.len())?;
    check_batch_size("books", input.books.len())?;
    check_batch_size("lookup_events", input.lookup_events.len())?;
    check_batch_size("book_markers", input.book_markers.len())?;
    check_batch_size("achievement_unlocks", input.achievement_unlocks.len())?;
    check_batch_size("settings", input.settings.len())?;

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

    // ── ④b 🆕 划线：**字段级**合并（不能整行取较新）──
    //
    // 「最新意愿」（`deleted` / `paused` / `note`）取**较新**；
    // 「首次事实」（`text` / offsets / `source_*` / `created_at`）取**较早** ——
    // 理由见 `HighlightInput` 与 `schema.rs` 里 `sync_highlight` 的那张表。
    //
    // 🔴 `note` 取较新时**连 NULL 一起取**：`note` 可空，而「清空笔记」是一个**真实意图**
    //    ⇒ 不能写成 `COALESCE(excluded.note, sync_highlight.note)`（那样笔记**永远清不掉**，
    //    清空会被当成「这次没带这个字段」）。📌 判据：**可空的「意愿型」字段，
    //    NULL 是值不是缺失** —— 只有「事实型」字段才该用「取非空」的宽松口径。
    //
    // ⚠️ `source_id` 是**文本**（article 存文章 id 的文本形式、book 存端侧 uuid）——
    //    不转 INTEGER：书的来源 id 本来就不是数字。
    for h in &input.highlights {
        // 显式校验枚举：表上有 CHECK，但让 CHECK 抛错会变成 **500**（Internal），
        // 而这是**客户端数据问题** ⇒ 必须回 400（与 `rating` 的处理同一条判据）。
        if h.source_type != "article" && h.source_type != "book" {
            return Err(AppError::BadRequest(format!(
                "highlight.source_type 只能是 article / book（收到 {}）",
                h.source_type
            )));
        }
        stats.highlights += tx
            .execute(
                "INSERT INTO sync_highlight
                   (user_id, id, source_type, source_id, chapter_idx, start_offset, end_offset,
                    text, note, paused, deleted, created_at, updated_at, received_at, translation)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                 ON CONFLICT (user_id, id) DO UPDATE SET
                   deleted      = CASE WHEN excluded.updated_at > sync_highlight.updated_at
                                       THEN excluded.deleted ELSE sync_highlight.deleted END,
                   paused       = CASE WHEN excluded.updated_at > sync_highlight.updated_at
                                       THEN excluded.paused ELSE sync_highlight.paused END,
                   note         = CASE WHEN excluded.updated_at > sync_highlight.updated_at
                                       THEN excluded.note ELSE sync_highlight.note END,
                   updated_at   = MAX(excluded.updated_at, sync_highlight.updated_at),
                   text         = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.text ELSE sync_highlight.text END,
                   start_offset = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.start_offset ELSE sync_highlight.start_offset END,
                   end_offset   = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.end_offset ELSE sync_highlight.end_offset END,
                   source_type  = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.source_type ELSE sync_highlight.source_type END,
                   source_id    = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.source_id ELSE sync_highlight.source_id END,
                   chapter_idx  = CASE WHEN excluded.created_at < sync_highlight.created_at
                                       THEN excluded.chapter_idx ELSE sync_highlight.chapter_idx END,
                   created_at   = MIN(excluded.created_at, sync_highlight.created_at),
                   -- 🆕 2026-10-11 译文：**有值者胜**（`COALESCE(NULLIF(TRIM(...)))`）。
                   -- 🔴 **绝不能用 `excluded.translation` 直取** —— 端侧送来 `NULL`
                   --    （本端与它上次拉的远端都没有译文）时，会把**别端刚补上的译文抹掉**。
                   -- 🔴🔴 `TRIM` **不是装饰**：只用 `NULLIF(x,'')` 的话，**空白串 `'   '`
                   --    会被当成有效译文写进去**（本批的测试实测抓到了这一点）。
                   --    端侧判空用的是 `trim().isEmpty` ⇒ SQL 必须 `TRIM` 后再比，否则
                   --    **三处口径不一致**（端侧当「没有」、服务端当「有」）——
                   --    表现是「复习页看不到译文，而云端存着三个空格」。
                   translation  = COALESCE(NULLIF(TRIM(excluded.translation), ''), sync_highlight.translation),
                   received_at  = excluded.received_at
                 WHERE excluded.updated_at > sync_highlight.updated_at
                    OR excluded.created_at < sync_highlight.created_at",
                params![
                    &uid,
                    &h.id,
                    &h.source_type,
                    &h.source_id,
                    h.chapter_idx,
                    h.start_offset,
                    h.end_offset,
                    &h.text,
                    h.note,
                    h.paused,
                    h.deleted,
                    &h.created_at,
                    &h.updated_at,
                    &received_at,
                    h.translation
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert highlight: {e}")))?;
    }

    // ── ⑤ 电子书进度：按 `updated_at` 取**较新**（进度是「读到哪」的最新意愿）──
    for p in &input.book_progress {
        stats.book_progress += tx
            .execute(
                "INSERT INTO sync_book_progress
                   (user_id, content_hash, chapter_idx, scroll_ratio, updated_at, received_at,
                    char_offset)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT (user_id, content_hash) DO UPDATE SET
                   chapter_idx  = excluded.chapter_idx,
                   scroll_ratio = excluded.scroll_ratio,
                   updated_at   = excluded.updated_at,
                   received_at  = excluded.received_at,
                   -- 🆕 2026-10-23：`COALESCE` 而不是直接赋值 ——
                   --   老客户端推上来时 `char_offset` 是 NULL，直接赋值会把
                   --   **新客户端刚写好的精确值清空**（一端用旧版就能毁掉另一端的精度）。
                   --   📌 判据：**新字段的写入要「有值才覆盖」**，不能跟着整行覆盖。
                   char_offset  = COALESCE(excluded.char_offset,
                                           sync_book_progress.char_offset)
                 WHERE excluded.updated_at > sync_book_progress.updated_at",
                params![
                    &uid,
                    &p.content_hash,
                    p.chapter_idx,
                    p.scroll_ratio,
                    &p.updated_at,
                    &received_at,
                    p.char_offset
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert book_progress: {e}")))?;
    }

    // ── ⑥ 书单：按 `updated_at` 取**较新** ──
    //
    // 🔴🔴 **`blob_size` 故意不在 `DO UPDATE SET` 里** —— 这是本表最重要的一行约束。
    //
    //    它**不是遗漏**：`blob_size` 是**服务端事实**（云端存了几个字节），
    //    只有文件端点能写。若端侧能写，一台离线很久的设备推一次书单，
    //    就能把「云端已有」标回「没有」⇒ 用户以为备份丢了，而文件**明明还在**。
    //
    //    ⚠️ 但 `VALUES` 里**必须**给一个初值（NOT NULL 无默认值时会失败）：
    //       给 `0` 是安全的 —— 新插入的行本来就没上传过文件。
    //       若「上传先于 push」（不该发生，上传端点要求行已存在），
    //       后续 push 走 `DO UPDATE` 分支，也不会动 `blob_size`。
    //
    // 📌 判据：**「谁产生的事实，只能由谁写」** —— 跨设备可推的字段必须是「端侧产生的」。
    for b in &input.books {
        stats.books += tx
            .execute(
                "INSERT INTO sync_book
                   (user_id, content_hash, title, author, lang, chapter_count,
                    size_bytes, blob_size, added_at, updated_at, deleted, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8, ?9, ?10, ?11)
                 ON CONFLICT (user_id, content_hash) DO UPDATE SET
                   title         = excluded.title,
                   author        = excluded.author,
                   lang          = excluded.lang,
                   chapter_count = excluded.chapter_count,
                   size_bytes    = excluded.size_bytes,
                   updated_at    = excluded.updated_at,
                   deleted       = excluded.deleted,
                   received_at   = excluded.received_at
                 WHERE excluded.updated_at > sync_book.updated_at",
                params![
                    &uid,
                    &b.content_hash,
                    &b.title,
                    &b.author,
                    &b.lang,
                    b.chapter_count,
                    b.size_bytes,
                    &b.added_at,
                    &b.updated_at,
                    b.deleted,
                    &received_at
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert book: {e}")))?;
    }

    // ── ⑦ 查词记录：**纯 `INSERT OR IGNORE`**（日志不可变，PK 相同即重复）──
    //
    // 🔑 与 `review_log` 同一形态：「事件日志」不需要合并口径 ——
    //    内容一旦写入不再改，同一 `uid` 推多次结果一致。
    for e in &input.lookup_events {
        stats.lookup_events += tx
            .execute(
                "INSERT OR IGNORE INTO sync_lookup_event
                   (user_id, uid, word_id, spelling, article_id, sentence, position,
                    looked_up_at, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    &uid,
                    &e.uid,
                    &e.word_id,
                    &e.spelling,
                    e.article_id,
                    &e.sentence,
                    e.position,
                    &e.looked_up_at,
                    &received_at
                ],
            )
            .map_err(|e| AppError::Internal(format!("insert lookup_event: {e}")))?;
    }

    // ── ⑧ 书本内书签：**`deleted` 取 OR + 其余字段取较早端** ──
    //
    // 🔴 `deleted = MAX(excluded.deleted, sync_book_marker.deleted)` 表达的正是 **OR**：
    //    任一端删过 ⇒ 结果删。理由见 `BookMarkerInput` / `schema.rs`（本表无 `updated_at`，
    //    LWW 无判据；而「取消书签」是终局意愿）。
    //
    // 🔑 `created_at = MIN(...)` + 位置/摘录 CASE 取「较早那端」——
    //    同一 uuid 的两端副本内容本该一致，取较早保证结果稳定、可交换。
    for m in &input.book_markers {
        stats.book_markers += tx
            .execute(
                "INSERT INTO sync_book_marker
                   (user_id, id, content_hash, chapter_idx, scroll_ratio, excerpt,
                    created_at, deleted, received_at, char_offset)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT (user_id, id) DO UPDATE SET
                   deleted      = MAX(excluded.deleted, sync_book_marker.deleted),
                   content_hash = CASE WHEN excluded.created_at < sync_book_marker.created_at
                                       THEN excluded.content_hash
                                       ELSE sync_book_marker.content_hash END,
                   chapter_idx  = CASE WHEN excluded.created_at < sync_book_marker.created_at
                                       THEN excluded.chapter_idx
                                       ELSE sync_book_marker.chapter_idx END,
                   scroll_ratio = CASE WHEN excluded.created_at < sync_book_marker.created_at
                                       THEN excluded.scroll_ratio
                                       ELSE sync_book_marker.scroll_ratio END,
                   excerpt      = CASE WHEN excluded.created_at < sync_book_marker.created_at
                                       THEN excluded.excerpt
                                       ELSE sync_book_marker.excerpt END,
                   -- 🆕 2026-10-23 字符偏移：与 `scroll_ratio` **完全同构**（取较早那端）。
                   --    📌 判据：同族字段（同一坐标）必须同一处理，否则位置和偏移会指向不同页。
                   char_offset  = CASE WHEN excluded.created_at < sync_book_marker.created_at
                                       THEN excluded.char_offset
                                       ELSE sync_book_marker.char_offset END,
                   created_at   = MIN(excluded.created_at, sync_book_marker.created_at),
                   received_at  = excluded.received_at
                 WHERE excluded.created_at < sync_book_marker.created_at
                    OR excluded.deleted     > sync_book_marker.deleted",
                params![
                    &uid,
                    &m.id,
                    &m.content_hash,
                    m.chapter_idx,
                    m.scroll_ratio,
                    &m.excerpt,
                    &m.created_at,
                    m.deleted,
                    &received_at,
                    m.char_offset
                ],
            )
            .map_err(|e| AppError::Internal(format!("upsert book_marker: {e}")))?;
    }

    // ── ⑨ 成就解锁：`unlocked_at` 取**较早**（首次解锁时刻，同 `article_read.read_at`）──
    for a in &input.achievement_unlocks {
        stats.achievement_unlocks += tx
            .execute(
                "INSERT INTO sync_achievement_unlock (user_id, key, unlocked_at, received_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (user_id, key) DO UPDATE SET
                   unlocked_at = MIN(excluded.unlocked_at, sync_achievement_unlock.unlocked_at),
                   received_at = excluded.received_at
                 WHERE excluded.unlocked_at < sync_achievement_unlock.unlocked_at",
                params![&uid, &a.key, &a.unlocked_at, &received_at],
            )
            .map_err(|e| AppError::Internal(format!("upsert achievement_unlock: {e}")))?;
    }

    // ── ⑩ 应用设置：`value` 取**较新端**（LWW，同 `book_progress`）──
    //
    // 🔴 `value` 是**整体替换**（不是字段级合并）—— 一个设置项就是一个原子值，
    //    「较新的那端说了算」（端侧在**写入设置时**刷新 `updated_at`）。
    for s in &input.settings {
        stats.settings += tx
            .execute(
                "INSERT INTO sync_setting (user_id, key, value, updated_at, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (user_id, key) DO UPDATE SET
                   value       = excluded.value,
                   updated_at  = excluded.updated_at,
                   received_at = excluded.received_at
                 WHERE excluded.updated_at > sync_setting.updated_at",
                params![&uid, &s.key, &s.value, &s.updated_at, &received_at],
            )
            .map_err(|e| AppError::Internal(format!("upsert setting: {e}")))?;
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
        "sync_push: uid={} device={} review={} word={} read={} bm={} hl={} bp={} book={} \
         lookup={} marker={} ach={} set={}",
        uid,
        device_id,
        stats.review_events,
        stats.user_words,
        stats.article_reads,
        stats.bookmarks,
        stats.highlights,
        stats.book_progress,
        stats.books,
        stats.lookup_events,
        stats.book_markers,
        stats.achievement_unlocks,
        stats.settings
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
/// `my_device` 传空串表示**不排除任何设备** ——
/// 🔴 `sync_pull` handler 在**首次全量**时显式传空串（理由见 `sync_pull` 里的长注释）。
pub fn pull_changes(
    conn: &Connection,
    uid: &str,
    since: &str,
    my_device: &str,
) -> Result<PullOutput, AppError> {
    // 🔴🔴 2026-10-10：**所有查询必须落在同一个读事务里**。
    //
    // # 为什么（这是一个**会静默丢数据**的竞态）
    //
    // `server_time` 与返回的数据来自**两次独立查询**。连接池（`db_pool.rs`，30 连接）
    // + WAL ⇒ 每次 autocommit 查询是**各自独立的读快照** ⇒ 两次查询之间若有并发写入：
    //
    // | 时刻 | 谁 | 发生什么 |
    // |---|---|---|
    // | T1 | pull | 查数据（快照 S1）—— **没有** X |
    // | T2 | push | 写入 X（`received_at = R`）并提交 |
    // | T3 | pull | 查 `MAX(received_at)`（快照 S2）—— **看到了 R** |
    //
    // ⇒ `server_time = R` ⇒ 客户端把游标推进到 R
    // ⇒ 下次 `received_at > R` ⇒ **X 永远不再返回** ⇒ 那条改动**永久丢失，且不报错**。
    //
    // 🔑 修法：同一事务的同一快照 ⇒「返回的数据」与「`server_time`」必然一致
    //    （`server_time` 只会等于「已返回数据的最大值」，绝不会超前于它）。
    // 📌 同族判据：**「判据口径差一层」不报错只给错数** —— 这里是「快照差一层」。
    // ⚠️ 只读事务在 WAL 下不阻塞写，成本可忽略；且本函数无 `LIMIT`（一次全拉）
    //    ⇒ 「截断 + 时间戳超前」那类漏在结构上也不可能发生。
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| AppError::Internal(format!("begin pull tx: {e}")))?;
    // 遮蔽：下面所有 `conn.xxx` 都走本事务的**同一快照**。
    let conn: &Connection = &tx;

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

    let mut highlights: Vec<HighlightOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT id, source_type, source_id, chapter_idx, start_offset, end_offset,
                        text, note, paused, deleted, created_at, updated_at, translation
                   FROM sync_highlight
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull highlight: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(HighlightOut {
                    id: r.get(0)?,
                    source_type: r.get(1)?,
                    source_id: r.get(2)?,
                    chapter_idx: r.get(3)?,
                    start_offset: r.get(4)?,
                    end_offset: r.get(5)?,
                    text: r.get(6)?,
                    note: r.get(7)?,
                    paused: r.get(8)?,
                    deleted: r.get(9)?,
                    created_at: r.get(10)?,
                    updated_at: r.get(11)?,
                    translation: r.get(12)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull highlight: {e}")))?;
        for row in rows {
            highlights.push(row.map_err(|e| AppError::Internal(format!("row highlight: {e}")))?);
        }
    }

    let mut book_progress: Vec<BookProgressOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT content_hash, chapter_idx, scroll_ratio, updated_at, char_offset
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
                    char_offset: r.get(4)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull bp: {e}")))?;
        for row in rows {
            book_progress.push(row.map_err(|e| AppError::Internal(format!("row bp: {e}")))?);
        }
    }

    let mut books: Vec<BookOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT content_hash, title, author, lang, chapter_count,
                        size_bytes, blob_size, added_at, updated_at, deleted
                   FROM sync_book
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull book: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(BookOut {
                    content_hash: r.get(0)?,
                    title: r.get(1)?,
                    author: r.get(2)?,
                    lang: r.get(3)?,
                    chapter_count: r.get(4)?,
                    size_bytes: r.get(5)?,
                    blob_size: r.get(6)?,
                    added_at: r.get(7)?,
                    updated_at: r.get(8)?,
                    deleted: r.get(9)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull book: {e}")))?;
        for row in rows {
            books.push(row.map_err(|e| AppError::Internal(format!("row book: {e}")))?);
        }
    }

    // 🆕 2026-10-10：查词记录。⚠️ 本表**不排除本设备**（所有表里只有 `review_log` 需要排除）——
    //    重复拉回由端侧「按 uid 幂等写入」兜住，且能纠正偏差。
    let mut lookup_events: Vec<LookupEventOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT uid, word_id, spelling, article_id, sentence, position, looked_up_at
                   FROM sync_lookup_event
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull lookup: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(LookupEventOut {
                    uid: r.get(0)?,
                    word_id: r.get(1)?,
                    spelling: r.get(2)?,
                    article_id: r.get(3)?,
                    sentence: r.get(4)?,
                    position: r.get(5)?,
                    looked_up_at: r.get(6)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull lookup: {e}")))?;
        for row in rows {
            lookup_events.push(row.map_err(|e| AppError::Internal(format!("row lookup: {e}")))?);
        }
    }

    // 🆕 2026-10-10：书本内书签。
    let mut book_markers: Vec<BookMarkerOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT id, content_hash, chapter_idx, scroll_ratio, excerpt, created_at, deleted,
                        char_offset
                   FROM sync_book_marker
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull marker: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(BookMarkerOut {
                    id: r.get(0)?,
                    content_hash: r.get(1)?,
                    chapter_idx: r.get(2)?,
                    scroll_ratio: r.get(3)?,
                    excerpt: r.get(4)?,
                    created_at: r.get(5)?,
                    deleted: r.get(6)?,
                    char_offset: r.get(7)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull marker: {e}")))?;
        for row in rows {
            book_markers.push(row.map_err(|e| AppError::Internal(format!("row marker: {e}")))?);
        }
    }

    // 🆕 2026-10-10：成就解锁记录。
    let mut achievement_unlocks: Vec<AchievementUnlockOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT key, unlocked_at FROM sync_achievement_unlock
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull achievement: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(AchievementUnlockOut {
                    key: r.get(0)?,
                    unlocked_at: r.get(1)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull achievement: {e}")))?;
        for row in rows {
            achievement_unlocks
                .push(row.map_err(|e| AppError::Internal(format!("row achievement: {e}")))?);
        }
    }

    // 🆕 2026-10-10：应用设置。
    let mut settings: Vec<SettingOut> = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT key, value, updated_at FROM sync_setting
                  WHERE user_id = ?1 AND received_at > ?2
                  ORDER BY received_at ASC",
            )
            .map_err(|e| AppError::Internal(format!("prepare pull setting: {e}")))?;
        let rows = stmt
            .query_map(params![&uid, &since], |r| {
                Ok(SettingOut {
                    key: r.get(0)?,
                    value: r.get(1)?,
                    updated_at: r.get(2)?,
                })
            })
            .map_err(|e| AppError::Internal(format!("query pull setting: {e}")))?;
        for row in rows {
            settings.push(row.map_err(|e| AppError::Internal(format!("row setting: {e}")))?);
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
            "SELECT MAX(received_at) FROM sync_highlight     WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_book_progress WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_book          WHERE user_id = ?1",
            // 🆕 2026-10-10：漏一张 ⇒ 只写那张表时 `server_time` 不前进 ⇒ 同一批被**反复重拉**
            "SELECT MAX(received_at) FROM sync_lookup_event      WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_book_marker       WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_achievement_unlock WHERE user_id = ?1",
            "SELECT MAX(received_at) FROM sync_setting           WHERE user_id = ?1",
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

    let out = PullOutput {
        review_events,
        user_words,
        article_reads,
        bookmarks,
        highlights,
        book_progress,
        books,
        lookup_events,
        book_markers,
        achievement_unlocks,
        settings,
        server_time: max_received,
    };
    // 🔴 显式结束读事务（`unchecked_transaction` 在 drop 时会 rollback ——
    //    读事务下二者等价，但显式 commit 让「这里正常结束」的意图可读）。
    tx.commit()
        .map_err(|e| AppError::Internal(format!("commit pull tx: {e}")))?;
    Ok(out)
}

/// `GET /api/sync/pull` — 拉取服务端的变更（**只需登录**）。
///
/// # 🔴 2026-10-13：由「登录 + 订阅」改为「**只需登录**」（白哥选方案 B）
///
/// 理由**不是**新定的规矩 —— 本文件 [`authorize_login_only`] 的判据表早就写着：
///
/// > **「付费买的是存储，不是访问权」—— 限制入口可以，限制出口不行。**
///
/// 但那张表当时把「**拉取同步**」也算进「登录 + 订阅」⇒ **判据与实现自相矛盾**。
/// 后果是实测出来的（白哥 `690861018@qq.com`）：
/// 该账号 `subscription_expires` 被清空后，服务端 **258 行**学习数据**完好无损**，
/// 但 `pull` 一律 **403** ⇒ 界面上显示「**数据全都没了**」（其实是被锁在云端取不回）。
/// 这与产品对用户的承诺「**不会丢失或锁定任何已积累的内容**」**直接冲突**。
///
/// 🔑 现在：**push 仍需订阅（入口）· pull 只需登录（出口）** ——
///    与「下载文件只需登录、上传文件需订阅」**完全同构**。
///    有意为之的副作用：订阅到期后，用户仍能把云端数据**取回本地**，
///    只是不能再往云端推。
///
/// ⚠️ 不会造成越权读：`pull_changes` 仍按 `uid` 过滤，只能拉到自己的数据。
pub async fn sync_pull(
    headers: HeaderMap,
    Query(q): Query<PullQuery>,
) -> Result<Json<PullOutput>, AppError> {
    let (uid, _token) = authorize_login_only(&headers)?;

    // 首次同步（无 since）⇒ 用一个早于一切的时间戳（ISO8601 最小可表示值）
    let since_raw = q.since.as_deref().map(str::trim).filter(|s| !s.is_empty());
    // 🔴 是否「首次全量」（客户端没有游标）
    let is_first_sync = since_raw.is_none();
    let since = since_raw.unwrap_or("1970-01-01T00:00:00.000Z");

    // 🔴🔴 2026-10-10：**首次全量拉取时不排除本设备**。
    //
    // # 为什么（不这么做 ⇒ 自己推的历史**永远拉不回来**）
    //
    // `pull` 默认排除本设备，其前提是「**本端推的，本端一定有**」。
    // 该前提在下面这些情形**不成立**：
    //   · 卸载重装 / 清数据 / 换账号后重登
    //   · `user.db` 被重建（含 v11 把游标表清空 ⇒ 客户端必然做一次「首次全量拉取」）
    // ⇒ 那些记录在服务端有、本地没有，而 `device_id <> me` 又把它们排除掉
    // ⇒ **永久拿不回，且不报错**（用户看到「同步成功，但东西少了一份」）。
    //
    // 🔑 「首次全量拉取」的语义就是「**把服务端这份数据完整克隆到本地**」
    //    —— 排除本设备与这个语义**直接矛盾**（除非本地一定完整，而那正是不能假设的）。
    // ⚠️ 增量拉取（有 since）仍排除本设备：那时「本地完整」的前提由「本地曾拉过」
    //    保证；且不排除会导致**每次同步都白拉一遍自己的事件**。
    // 📄 依据：`docs/review/sync-ui-not-refreshing-and-device-state-mismatch-2026-10-10.md` §二
    let my_device = if is_first_sync {
        ""
    } else {
        q.device_id.as_deref().map(str::trim).unwrap_or("")
    };

    let out = {
        let conn = crate::db_pool::get_conn();
        pull_changes(&conn, &uid, since, my_device)?
    };

    tracing::info!(
        "sync_pull: uid={} since={} device={} review={} word={} read={} bm={} hl={} bp={} \
         lookup={} marker={} ach={} set={}",
        uid,
        since,
        my_device,
        out.review_events.len(),
        out.user_words.len(),
        out.article_reads.len(),
        out.bookmarks.len(),
        out.highlights.len(),
        out.book_progress.len(),
        out.lookup_events.len(),
        out.book_markers.len(),
        out.achievement_unlocks.len(),
        out.settings.len()
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
//    ⇒ 两个 auth 函数（`token → uid` **或** `token → uid → 订阅校验 → 403`）
//      **都没有单测**。那一层由**源码断言**兜
//      （`scripts/query_verify/bin/verify_sync.dart`）：
//      锁「**push 走订阅版 / pull 走登录版**」+「未订阅回 403 而非 401」。
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

    /// 🔴🔴 2026-10-10：**读事务必须提供「单一快照」**（`pull` 的正确性前提）。
    ///
    /// # 这条测试同时**证明缺陷存在**与**修复手段有效**（对照组 + 实验组）
    ///
    /// `pull_changes` 先查数据、再查 `MAX(received_at)` 当 `server_time`。
    /// 连接池（`db_pool.rs`，30 连接）+ WAL ⇒ **每次 autocommit 查询各自独立快照**
    /// ⇒ 两次查询之间若有并发 push 提交：
    ///   · `server_time` **包含**那条并发记录（第三次查询的快照看到了它）
    ///   · 但**返回的数据里没有它**（第一次查询的快照没看到）
    /// ⇒ 客户端把游标推进到 `server_time` ⇒ 下次 `received_at > server_time`
    ///   ⇒ **那条记录永远不再返回**（永久丢失，且全程不报错）。
    /// 📌 同族判据：**「判据口径差一层」不报错只给错数** —— 这里是「快照差一层」。
    ///
    /// ⚠️ 本测试**不**直接调 `pull_changes`（无法在它内部两次查询之间插入写入），
    ///    而是验证它依赖的**机制前提**：
    /// · 对照组（**无**事务）⇒ 第二次查询能看到并发提交 ⇒ **非原子确实存在**
    /// · 实验组（**有**事务）⇒ 同一事务内看不到 ⇒ **事务提供同一快照**
    /// 「`pull_changes` 真的用了事务」由**源码断言**兜（`verify_sync.dart` §17.1）
    /// —— 两层互补，且各自**可证伪**（把 `unchecked_transaction` 删掉，§17.1 立刻红）。
    #[test]
    fn test_read_transaction_gives_single_snapshot() {
        let dir = std::env::temp_dir().join(format!(
            "coevo_pull_snapshot_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.db");

        let writer = Connection::open(&path).unwrap();
        writer
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL);",
            )
            .unwrap();
        let reader = Connection::open(&path).unwrap();

        // ── 对照组：**没有**事务 ⇒ 两次查询看到不同快照 ──
        let before = reader
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get::<_, i64>(0))
            .unwrap();
        writer
            .execute("INSERT INTO t (v) VALUES ('x')", [])
            .unwrap();
        let after = reader
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get::<_, i64>(0))
            .unwrap();
        assert_eq!(before, 0);
        assert_eq!(
            after, 1,
            "🔴 对照组前提不成立：无事务时第二次查询**应当**能看到并发提交。\
             若这里相等，说明本环境不满足「各自快照」⇒ 本测试证明不了任何事（假绿）。"
        );

        // ── 实验组：**有**事务 ⇒ 同一快照（第一次读时确定）──
        let tx = reader.unchecked_transaction().unwrap();
        let snap1 = tx
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get::<_, i64>(0))
            .unwrap();
        writer
            .execute("INSERT INTO t (v) VALUES ('y')", [])
            .unwrap(); // 并发写入并提交
        let snap2 = tx
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get::<_, i64>(0))
            .unwrap();
        assert_eq!(snap1, 1);
        assert_eq!(
            snap2, 1,
            "🔴 事务内第二次查询看到了并发提交 ⇒ 快照隔离失效 \
             ⇒ `pull` 的 `server_time` 会超前于返回数据 ⇒ 永久漏一条"
        );
        tx.commit().unwrap();

        // 事务结束后重新查 ⇒ 能看到（证明那次写入**真的发生了**，不是没写进去）
        let final_count = reader
            .query_row("SELECT COUNT(*) FROM t", [], |r| r.get::<_, i64>(0))
            .unwrap();
        assert_eq!(final_count, 2);

        drop(reader);
        drop(writer);
        let _ = std::fs::remove_dir_all(&dir);
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
            highlights: vec![],
            book_progress: vec![],
            books: vec![],
            lookup_events: vec![],
            book_markers: vec![],
            achievement_unlocks: vec![],
            settings: vec![],
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
            "sync_highlight",
            "sync_book_progress",
            "sync_book",
            // 🆕 2026-10-10：同步覆盖面补齐的 4 张表
            "sync_lookup_event",
            "sync_book_marker",
            "sync_achievement_unlock",
            "sync_setting",
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

    /// 🆕 2026-10-09 划线同步：**字段级**合并 + 暂停 / 笔记跨设备。
    ///
    /// 🔴 本测试守的是一个**真实缺口**：此前 `review_log`（复习事件）参与同步，
    ///    而 `highlight`（划线本体）**不参与** ⇒ 重装 / 换机 / 清数据的设备会拿到
    ///    「**无主划线卡**」：标题显示成 `hl:<uuid>`、点「暂停」静默无反应、
    ///    界面上没有任何出口能去掉它。
    ///    ⇒ 所以**第 ① 组的断言就是「别端必须能拿到这条划线本身」**。
    ///
    /// ⚠️ 时间戳用**真实 ISO8601**（毫秒精度）—— 合并判据依赖
    ///    「字典序 == 时间序」这个前提（见测试模块顶部那条说明）。
    #[test]
    fn test_highlight_sync_field_level_merge() {
        const C1: &str = "2026-10-01T00:00:00.000Z"; // created_at（首次事实）
        const U1: &str = "2026-10-01T00:00:00.000Z";
        const U2: &str = "2026-10-02T00:00:00.000Z";
        const U3: &str = "2026-10-03T00:00:00.000Z";
        const U4: &str = "2026-10-04T00:00:00.000Z";
        const U5: &str = "2026-10-05T00:00:00.000Z";
        const U6: &str = "2026-10-06T00:00:00.000Z";

        #[allow(clippy::too_many_arguments)]
        fn hl(
            id: &str,
            text: &str,
            note: Option<&str>,
            paused: i64,
            deleted: i64,
            created: &str,
            updated: &str,
        ) -> HighlightInput {
            HighlightInput {
                id: id.into(),
                source_type: "article".into(),
                source_id: "42".into(),
                chapter_idx: None,
                start_offset: 10,
                end_offset: 20,
                text: text.into(),
                note: note.map(|s| s.into()),
                paused,
                deleted,
                created_at: created.into(),
                updated_at: updated.into(),
                // 🆕 v1.12：本 helper 默认「无译文」；译文相关的用例自带字面量。
                translation: None,
            }
        }

        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        // ① A 创建
        let mut a = base_push("devA");
        a.highlights = vec![hl("h1", "the quick fox", None, 0, 0, C1, U1)];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out.highlights.len(),
            1,
            "🔴 别端必须能拿到**划线本体** —— 拿不到就是「无主划线卡」"
        );
        assert_eq!(out.highlights[0].text, "the quick fox");
        assert_eq!(out.highlights[0].paused, 0);
        assert_eq!(out.highlights[0].chapter_idx, None, "文章没有章节号");
        assert_eq!(out.highlights[0].source_id, "42");

        // ② B **暂停**（较新）⇒ 必须跨设备（否则「A 暂停、换台设备又回来了」）
        let mut b = base_push("devB");
        b.highlights = vec![hl("h1", "the quick fox", None, 1, 0, C1, U2)];
        push_changes(&conn, "u1", "devB", RECV1, &b).unwrap();
        assert_eq!(
            pull_changes(&conn, "u1", ALL, "").unwrap().highlights[0].paused,
            1,
            "暂停是**用户意图**，必须跨设备（同 `paused` 那条注释的判据）"
        );

        // ③ B 写笔记（较新）
        let mut b2 = base_push("devB");
        b2.highlights = vec![hl("h1", "the quick fox", Some("记一下"), 1, 0, C1, U3)];
        push_changes(&conn, "u1", "devB", RECV1, &b2).unwrap();
        assert_eq!(
            pull_changes(&conn, "u1", ALL, "").unwrap().highlights[0]
                .note
                .as_deref(),
            Some("记一下")
        );

        // ④ 🔴 B **清空**笔记（较新）—— `NULL` 是**值**，不是「这次没带这个字段」
        //
        //    若把 `note` 写成 `COALESCE(excluded.note, sync_highlight.note)`，
        //    笔记就**永远清不掉**（清空被当成缺失）。同族的坑见 `sync_book` 的 `blob_size`。
        let mut b3 = base_push("devB");
        b3.highlights = vec![hl("h1", "the quick fox", None, 1, 0, C1, U4)];
        push_changes(&conn, "u1", "devB", RECV1, &b3).unwrap();
        assert_eq!(
            pull_changes(&conn, "u1", ALL, "").unwrap().highlights[0].note,
            None,
            "清空笔记必须能同步"
        );

        // ⑤ A 推「正文不同 + `created_at` 更晚 + `updated_at` 更旧」的同一 id
        //    ⇒ **整行都不该被改**（两边的判据都不成立）
        let mut a2 = base_push("devA");
        a2.highlights = vec![hl("h1", "被改写的正文", Some("旧笔记"), 0, 0, U5, U1)];
        push_changes(&conn, "u1", "devA", RECV2, &a2).unwrap();
        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.highlights[0].text, "the quick fox");
        assert_eq!(out.highlights[0].paused, 1, "更旧的意愿不得让暂停复活");
        assert_eq!(out.highlights[0].note, None, "更旧的意愿不得让笔记回来");

        // ⑥ A 推「`created_at` 更晚 + `updated_at` 最新」⇒
        //    **意愿字段更新、首次事实不动**（这正是「字段级分离」的判据）
        let mut a3 = base_push("devA");
        a3.highlights = vec![hl("h1", "又一次被改写", Some("新笔记"), 0, 0, U5, U5)];
        push_changes(&conn, "u1", "devA", RECV2, &a3).unwrap();
        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out.highlights[0].text, "the quick fox",
            "🔴 「首次事实」（正文 / offsets）不得被**更晚**的副本改写"
        );
        assert_eq!(out.highlights[0].start_offset, 10);
        assert_eq!(out.highlights[0].paused, 0, "更新的意愿生效（取消暂停）");
        assert_eq!(
            out.highlights[0].note.as_deref(),
            Some("新笔记"),
            "更新的意愿生效（改笔记）"
        );

        // ⑦ 取消（软删，较新）⇒ 必须传播
        let mut b4 = base_push("devB");
        b4.highlights = vec![hl("h1", "the quick fox", Some("新笔记"), 0, 1, C1, U6)];
        push_changes(&conn, "u1", "devB", RECV2, &b4).unwrap();
        assert_eq!(
            pull_changes(&conn, "u1", ALL, "").unwrap().highlights[0].deleted,
            1,
            "取消划线必须能同步（否则「取消了的又自己回来」）"
        );
    }

    /// 🔴 非法 `source_type` 必须回 **400**（客户端数据问题），不是 500。
    ///
    /// 表上有 `CHECK (source_type IN ('article','book'))` —— 若只靠它拦，
    /// 触发的是 rusqlite 错误 ⇒ 被映射成 `AppError::Internal`（**500**）⇒
    /// 客户端会以为是服务端故障而无限重试（同 `rating` 那条判据）。
    #[test]
    fn test_highlight_rejects_unknown_source_type() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.highlights = vec![HighlightInput {
            id: "h1".into(),
            source_type: "podcast".into(), // 不认识
            source_id: "42".into(),
            chapter_idx: None,
            start_offset: 0,
            end_offset: 5,
            text: "hello".into(),
            note: None,
            paused: 0,
            deleted: 0,
            created_at: "2026-10-01T00:00:00.000Z".into(),
            updated_at: "2026-10-01T00:00:00.000Z".into(),
            translation: None,
        }];
        let err = push_changes(&conn, "u1", "devA", RECV1, &a).unwrap_err();
        assert!(
            matches!(err, AppError::BadRequest(_)),
            "应为 400（客户端数据问题），实际 {err:?}"
        );
    }

    /// 🆕 v1.12（2026-10-11）划线卡**译文**的合并口径 —— **有值者胜**，绝不丢。
    ///
    /// # 🔴 这条测试为什么必须存在
    /// 若把 upsert 写成 `translation = excluded.translation` **直取**，那么
    /// 「本端没有译文（送 `None`）」就会把**别端刚补上的译文抹掉** —— 而且是**静默**的：
    /// 本地看不出、云端也看不出，用户只会发现「译文自己没了」。
    ///
    /// ✅ 正确写法是 `COALESCE(NULLIF(excluded.translation, ''), sync_highlight.translation)`：
    ///    · 送来的有值 ⇒ 用它
    ///    · 送来 `NULL` **或空串** ⇒ **保留原有的**
    ///
    /// ⚠️ 这个口径必须与端侧**三处**一致（`sync_merge._pickTranslation` ·
    ///    `HighlightRepository.withoutTranslation` 的 WHERE · 本处）。
    #[test]
    fn test_highlight_translation_survives_a_null_push() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mk = |translation: Option<&str>, updated: &str| HighlightInput {
            id: "h1".into(),
            source_type: "article".into(),
            source_id: "42".into(),
            chapter_idx: None,
            start_offset: 0,
            end_offset: 5,
            text: "hello".into(),
            note: None,
            paused: 0,
            deleted: 0,
            created_at: "2026-10-01T00:00:00.000Z".into(),
            updated_at: updated.into(),
            translation: translation.map(|s| s.into()),
        };

        // ① 设备 A 推上译文
        let mut a = base_push("devA");
        a.highlights = vec![mk(Some("你好"), "2026-10-01T00:00:00.000Z")];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // ② 设备 B **没有译文**，但时间戳更新（模拟「B 改了别的字段」）
        let mut b = base_push("devB");
        b.highlights = vec![mk(None, "2026-10-02T00:00:00.000Z")];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        // ③ 译文必须**还在**
        let got: Option<String> = conn
            .query_row(
                "SELECT translation FROM sync_highlight WHERE user_id='u1' AND id='h1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            got.as_deref(),
            Some("你好"),
            "🔴 译文被空值抹掉了 —— upsert 用了直取而不是 COALESCE(NULLIF(...))"
        );

        // ④ 空串同样按「没有」处理（三处口径必须一致）
        let mut c = base_push("devC");
        c.highlights = vec![mk(Some("   "), "2026-10-03T00:00:00.000Z")];
        push_changes(&conn, "u1", "devC", "2026-10-06T10:10:00.000Z", &c).unwrap();
        let got2: Option<String> = conn
            .query_row(
                "SELECT translation FROM sync_highlight WHERE user_id='u1' AND id='h1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            got2.as_deref(),
            Some("你好"),
            "🔴 空白串必须按「没有」处理（与端侧 _pickTranslation / withoutTranslation 同口径）"
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
            char_offset: None,
        }];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let mut b = base_push("devB");
        b.book_progress = vec![BookProgressInput {
            content_hash: "hash-abc".into(),
            chapter_idx: 9,
            scroll_ratio: 0.8,
            updated_at: "2026-10-05T00:00:00Z".into(),
            char_offset: None,
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
            char_offset: None,
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

    // ══════════════════════════════════════════════════════════════════
    // 🆕 2026-10-10：同步覆盖面补齐（审计报告 §五 P0/P1/P2/P3）
    //    四张新表：`sync_lookup_event` · `sync_book_marker` ·
    //              `sync_achievement_unlock` · `sync_setting`
    // ══════════════════════════════════════════════════════════════════

    /// 🔑 `lookup_event` 是**日志型** ⇒ `INSERT OR IGNORE` 幂等；未命中词的 `word_id` 是 NULL。
    ///
    /// ⚠️ 这条同时守一个**结构陷阱**：`word_id` 可空，但**绝不能**把它放进 PK ——
    ///    NULL 在 SQLite 的 PK 里互不相等 ⇒ 破坏幂等。跨设备身份只用 `uid`。
    #[test]
    fn test_lookup_event_union_and_idempotent() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.lookup_events = vec![LookupEventInput {
            uid: "lk-1".into(),
            word_id: Some("w1".into()),
            spelling: "receive".into(),
            article_id: Some(7),
            sentence: Some("I receive it".into()),
            position: Some(3),
            looked_up_at: "2026-10-01T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // 未命中的词（word_id = None）也要能存
        let mut b = base_push("devB");
        b.lookup_events = vec![LookupEventInput {
            uid: "lk-2".into(),
            word_id: None,
            spelling: "zzz".into(),
            article_id: None,
            sentence: None,
            position: None,
            looked_up_at: "2026-10-02T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devB", RECV1, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.lookup_events.len(), 2, "两条不同 uid 都应存在");
        let miss = out.lookup_events.iter().find(|e| e.uid == "lk-2").unwrap();
        assert_eq!(
            miss.word_id, None,
            "未命中词的 word_id 应是 NULL（不是空串）"
        );

        // 幂等：同一批重推，行数与 received_at 都不变
        let recv_before: String = conn
            .query_row(
                "SELECT received_at FROM sync_lookup_event WHERE uid='lk-1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        push_changes(&conn, "u1", "devA", RECV2, &a).unwrap();
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM sync_lookup_event", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 2, "重复 push 不得增行");
        let recv_after: String = conn
            .query_row(
                "SELECT received_at FROM sync_lookup_event WHERE uid='lk-1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(recv_before, recv_after, "重复 push 不得推进 received_at");
    }

    /// 🔴 `book_marker` 的 `deleted` 合并是 **OR**（任一端删过即删），不是「取较新」。
    ///
    /// # 为什么这条断言最重要
    /// 本表**没有 `updated_at`** ⇒ 若照抄其余表的「谁更新谁赢」，取消**永远传不出去**
    /// （取消不刷时间戳 ⇒ `t > t` 为假 ⇒ 服务端保留旧的 `deleted = 0`）——
    /// 那正是「取消了的书签又自己回来」。OR 语义**恰好**匹配「取消是终局意愿」。
    #[test]
    fn test_book_marker_deleted_is_or() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        fn mk(id: &str, created: &str, deleted: i64) -> BookMarkerInput {
            BookMarkerInput {
                id: id.into(),
                content_hash: "hash-book-1".into(),
                chapter_idx: 2,
                scroll_ratio: 0.5,
                excerpt: "一段摘录".into(),
                created_at: created.into(),
                deleted,
                char_offset: None,
            }
        }

        // A 端打书签
        let mut a = base_push("devA");
        a.book_markers = vec![mk("m1", "2026-10-01T00:00:00.000Z", 0)];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        // B 端取消（deleted=1）—— ⚠️ 它**没有更晚的 created_at**（正是本表没有 LWW 判据的证明）
        let mut b = base_push("devB");
        b.book_markers = vec![mk("m1", "2026-10-01T00:00:00.000Z", 1)];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.book_markers.len(), 1);
        assert_eq!(out.book_markers[0].deleted, 1, "任一端的取消都要生效（OR）");

        // 反向：A 再推「未删」的旧副本 ⇒ **不得复活**
        let mut a2 = base_push("devA");
        a2.book_markers = vec![mk("m1", "2026-10-01T00:00:00.000Z", 0)];
        push_changes(&conn, "u1", "devA", RECV2, &a2).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out2.book_markers[0].deleted, 1,
            "OR 语义下不得被未删副本复活"
        );

        // 位置 / 摘录是「首次事实」⇒ 取 `created_at` 较早端（更晚的副本不得改写位置）
        let mut b2 = base_push("devB");
        b2.book_markers = vec![BookMarkerInput {
            id: "m1".into(),
            content_hash: "hash-book-1".into(),
            chapter_idx: 99,
            scroll_ratio: 0.99,
            excerpt: "被改写".into(),
            created_at: "2026-10-09T00:00:00.000Z".into(),
            deleted: 1,
            char_offset: None,
        }];
        push_changes(&conn, "u1", "devB", RECV2, &b2).unwrap();
        let out3 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out3.book_markers[0].chapter_idx, 2,
            "位置是首次事实 ⇒ 取较早端"
        );
        assert_eq!(out3.book_markers[0].excerpt, "一段摘录");
    }

    /// `achievement_unlock` 的 `unlocked_at` 取**较早**（= 首次解锁这一事实）。
    #[test]
    fn test_achievement_unlock_keeps_earliest() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut later = base_push("devA");
        later.achievement_unlocks = vec![AchievementUnlockInput {
            key: "first_word".into(),
            unlocked_at: "2026-10-05T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV1, &later).unwrap();

        // B 端记的是**更早**时刻（真正的首次解锁）⇒ 应胜出
        let mut earlier = base_push("devB");
        earlier.achievement_unlocks = vec![AchievementUnlockInput {
            key: "first_word".into(),
            unlocked_at: "2026-10-01T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devB", RECV2, &earlier).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.achievement_unlocks.len(), 1);
        assert_eq!(
            out.achievement_unlocks[0].unlocked_at, "2026-10-01T00:00:00Z",
            "应取**较早**（首次解锁时刻）"
        );

        // 再推更晚的 ⇒ 不得把「首次解锁时间」推后
        push_changes(&conn, "u1", "devA", RECV2, &later).unwrap();
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(
            out2.achievement_unlocks[0].unlocked_at, "2026-10-01T00:00:00Z",
            "更晚的不得覆盖较早的"
        );
    }

    /// `setting` 的 `value` 取**较新端**（LWW），且更旧的重推不推进 `received_at`（幂等）。
    #[test]
    fn test_setting_last_write_wins() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));

        let mut a = base_push("devA");
        a.settings = vec![SettingInput {
            key: "reading_font_size".into(),
            value: "17".into(),
            updated_at: "2026-10-01T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devA", RECV1, &a).unwrap();

        let mut b = base_push("devB");
        b.settings = vec![SettingInput {
            key: "reading_font_size".into(),
            value: "22".into(),
            updated_at: "2026-10-05T00:00:00Z".into(),
        }];
        push_changes(&conn, "u1", "devB", RECV2, &b).unwrap();

        let out = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out.settings.len(), 1);
        assert_eq!(out.settings[0].value, "22", "较新端胜");

        // 幂等：重推更旧的那批 ⇒ 不覆盖、不推进 received_at
        let before: String = conn
            .query_row(
                "SELECT received_at FROM sync_setting WHERE key='reading_font_size'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        push_changes(&conn, "u1", "devA", RECV2, &a).unwrap();
        let after: String = conn
            .query_row(
                "SELECT received_at FROM sync_setting WHERE key='reading_font_size'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(before, after, "更旧的设置不得刷新 received_at");
        let out2 = pull_changes(&conn, "u1", ALL, "").unwrap();
        assert_eq!(out2.settings[0].value, "22", "更旧的不得回退");
    }

    /// 🔴 4 张新表的多用户隔离 —— **这条能抓出「PK 忘了带 user_id」**。
    ///
    /// 手法：两个用户用**完全相同**的 `uid` / `id` / `key`。若某张表 PK 漏了 `user_id`，
    /// 第二个用户会**覆盖**第一个 —— 而单人测试**永远发现不了**。
    #[test]
    fn test_new_sync_tables_multi_user_isolation() {
        let conn = setup();
        seed_user(&conn, "u1", Some("2099-01-01"));
        seed_user(&conn, "u2", Some("2099-01-01"));

        for u in ["u1", "u2"] {
            let mut p = base_push("devA");
            p.lookup_events = vec![LookupEventInput {
                uid: "same-uid".into(),
                word_id: None,
                spelling: "same".into(),
                article_id: None,
                sentence: None,
                position: None,
                looked_up_at: "2026-10-01T00:00:00Z".into(),
            }];
            p.book_markers = vec![BookMarkerInput {
                id: "same-id".into(),
                content_hash: "h".into(),
                chapter_idx: 1,
                scroll_ratio: 0.1,
                excerpt: "e".into(),
                created_at: "2026-10-01T00:00:00Z".into(),
                deleted: 0,
                char_offset: None,
            }];
            p.achievement_unlocks = vec![AchievementUnlockInput {
                key: "same-key".into(),
                unlocked_at: "2026-10-01T00:00:00Z".into(),
            }];
            p.settings = vec![SettingInput {
                key: "same-key".into(),
                value: "v".into(),
                updated_at: "2026-10-01T00:00:00Z".into(),
            }];
            push_changes(&conn, u, "devA", RECV1, &p).unwrap();
        }

        let o1 = pull_changes(&conn, "u1", ALL, "").unwrap();
        let o2 = pull_changes(&conn, "u2", ALL, "").unwrap();
        assert_eq!(o1.lookup_events.len(), 1, "u1 应恰好看到自己那条");
        assert_eq!(o2.lookup_events.len(), 1);
        assert_eq!(o1.book_markers.len(), 1);
        assert_eq!(o2.book_markers.len(), 1);
        assert_eq!(
            o1.achievement_unlocks.len(),
            1,
            "PK 漏 user_id ⇒ 一人看不到自己的"
        );
        assert_eq!(o2.achievement_unlocks.len(), 1);
        assert_eq!(o1.settings.len(), 1);
        assert_eq!(o2.settings.len(), 1);
    }
}
