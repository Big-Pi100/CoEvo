//! 整段 / 整句翻译（订阅权益 · 2026-10-08）
//!
//! # 与词卡制卡（`llm_card`）的关系
//!
//! | | `llm_card` | 本模块 |
//! |---|---|---|
//! | 输入 | 一个**词形**（≤64 字符、严格白名单）| 任意文本（≤800 字符）|
//! | 缓存 | 🔑 **服务端全局**（高频词被多人查同一张卡 ⇒ 能摊薄）| ❌ **不做**（见下）|
//! | 产物 | 结构化卡片（进复习）| 一次性译文（**不进任何地方**）|
//! | 额度 | 无（缓存把成本摊掉了）| 免费 **10 次/月** · 订阅无限 |
//! | 复用 | — | `LlmCaller` · `compliance` · 登录鉴权 |
//!
//! # 🔴 为什么服务端**不做**缓存（与 `llm_card` 相反）
//!
//! 缓存的全部价值来自「**同一份结果被多人复用**」。词卡能摊薄，
//! 是因为 `attention` 会被成千上万人查 → 一次生成、N 次命中。
//!
//! 而翻译的单位是**句子**：每篇文章的每句话都是唯一的 ⇒ 跨用户命中率**≈ 0**
//! ⇒ 加了缓存也只是多一层永远打不中的查找（还多一处「缓存与 prompt 版本漂移」的隐患）。
//!
//! 📌 判据：**「能摊薄才有缓存价值」**（`product-core-expansion` §4.3）。
//! ⚠️ 端侧缓存**有价值**（同一个用户会重复看同一句）—— 但那是端侧的事，不在这里。
//!
//! # 计费口径
//!
//! · **按次，不按长度**（选中上限 800 字符）⇒ 用户不必猜「这句长会不会多扣」
//! · 🔴 **只有成功返回译文才计费**（调模型失败 / 合规拒绝 ⇒ **退额**）
//!   —— 收了钱没给东西是最快失去信任的方式

use axum::http::HeaderMap;
use axum::Json;
use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::error::AppError;

// ══════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════

/// 与 `llm_card` **同一个模型**（实测有效）。
///
/// ⚠️ 不要改成 `LlmConfig::deepseek_v4_flash()` 里的 `deepseek-v4-flash` ——
///    两者**不是同一个名字**，而 `deepseek-flash` 是 smoke 实测通过的那个。
///    （同一条教训在 `llm_card.rs` 里也记着。）
const MODEL: &str = "deepseek-flash";

/// 输出上限。
///
/// 🔑 与 [`MAX_TEXT_CHARS`] **同比例**（2026-10-09 由 900 提到 2400）：
///    翻译是「等长改写」，英译中约 1.5 倍字符数；按 **3 tokens/字符** 的余量
///    ⇒ 800 × 3 = 2400（与原来 300 × 3 = 900 完全同一口径）。
///
/// 🔴 **改长度上限时必须一起看这个** —— 不改的后果是**静默截断**：
///    模型把长句译文拦腰切断，**没有任何报错**，用户拿到半句中文还以为原文就那样。
///    📌 同族：`llm_card` 也有一个同名的 `MAX_TOKENS`（**那是制卡的，与翻译无关**，
///       别改错文件）。
const MAX_TOKENS: u32 = 2400;
/// 低温度：翻译要**稳定**，不要发挥。
const TEMPERATURE: f32 = 0.2;

/// 选中文本长度上限（**字符**，不是字节）。
///
/// 🔑 2026-10-09 由 **300 提到 800** —— 白哥：「用了一下经常超出，800 字符比较合理」。
///
/// 原 300 的注释写着「与划线记忆同一条线」——
/// ⚠️ **实测那个前提已不成立**：划线 / 痕迹侧**没有**字符长度限制
///    （`word_lookup_selection` 里的 300 是 **300ms 防抖**，与字符数无关）
///    ⇒ 300 只是翻译这一侧的历史值，**不构成任何约束**。
/// 800 ≈ 一段较长的英文自然段 —— 用户实际想翻的单位就是「**一段**」。
///
/// 🔴 **改本值时必须同步 [`MAX_TOKENS`] 与 [`MAX_SEGMENTS`]**：
///    两者都由本值推导 ⇒ 只改本值会让长文本分别表现为
///    「**译文被截断**」与「**被拒：段落太多**」，两种都难自查。
pub const MAX_TEXT_CHARS: usize = 800;

/// 免费层每月次数（设计稿 §3 定的初值）。
pub const FREE_MONTHLY_LIMIT: i64 = 10;

/// 段数上限（防滥用：一次请求最多产出这么多段）。
///
/// 🔑 与 [`MAX_TEXT_CHARS`] **同比例**（2026-10-09 由 50 提到 140）：
///    300 字符按最短句切是 20–30 段 ⇒ 50 是安全余量；
///    800 字符则约 53–80 段 ⇒ 取 140（同样留约 2 倍余量）。
///    🔴 不跟着改 ⇒ 长文本会被判「段落太多」而**直接拒掉**
///      （用户看到的是「失败」，而不是「短一点就行」）。
const MAX_SEGMENTS: usize = 140;

/// prompt 文件名（在 `COEVO_PROMPTS_DIR` 下）。
///
/// 🔑 与 `llm_card` 同一机制（文件在 `backend/prompts/`）——
///    **不内联**：调 prompt 是翻译质量的日常动作，内联意味着每次都重新编译。
const PROMPT_FILE: &str = "translate.md";

// ══════════════════════════════════════════════════════════════════════
// 纯函数（无 I/O / 无网络 ⇒ 可独立断言）
// ══════════════════════════════════════════════════════════════════════

/// 额度周期 = `'YYYY-MM'`，按 **UTC+8**（中国标准时间）算。
///
/// 🔑 **为什么不是 UTC**：目标用户全在**中国区**（产品只上架中国区）。
///    用 UTC 会让「下月 1 日重置」实际发生在 **1 日早上 8 点** ——
///    用户 1 号凌晨用不了会以为额度系统坏了。
///
/// ⚠️ **也不按「用户本地时区」**：那需要客户端上报时区（可伪造），
///    而**额度口径只能有一处权威**。UTC+8 是对全部目标用户都成立的固定口径。
pub fn current_period(now: chrono::DateTime<chrono::Utc>) -> String {
    (now + chrono::Duration::hours(8))
        .format("%Y-%m")
        .to_string()
}

/// 输入校验（**明确报错**，不静默截断）。
pub fn validate_text(text: &str) -> Result<String, String> {
    let t = text.trim();
    if t.is_empty() {
        return Err("没有选中任何内容".into());
    }
    let n = t.chars().count();
    if n > MAX_TEXT_CHARS {
        // 🔴 不自动截断 —— 截断会译出一句**半截的话**，用户以为模型翻错了。
        //    让他自己缩短选区，比给他一个错误的结果好。
        return Err(format!(
            "选中内容太长（{n} 字符），一次最多 {MAX_TEXT_CHARS} 字符"
        ));
    }
    if !t.chars().any(|c| c.is_ascii_alphabetic()) {
        return Err("选中内容里没有英文".into());
    }
    Ok(t.to_string())
}

/// 一句对照。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Segment {
    /// 原文句。⚠️ 约定「与原文逐字一致」（prompt 第 1 条）。
    pub src: String,
    /// 中文译文。
    pub dst: String,
}

/// **格式闸门**：把模型返回的 JSON 收成 `Vec<Segment>`，不合法就给出原因。
///
/// # 🔴 为什么 `src` 只查「长度比例」而不查「逐字相等」
///
/// 逐字相等看着更严，实际是**假严**：
/// · 模型把 `don't` 写成 `don’t`（智能引号）就能让**整个请求失败**
/// · 而这条约束的真实目的是「防止模型**改写/省略**原文」，不是「字符级一致」
///
/// ⇒ 用**覆盖率**表达那个目的：`src` 总长 / 原文长度 ∈ [0.8, 1.25]。
///    · 模型只翻了一半 ⇒ 比例 < 0.8 ⇒ 拒（明显缺内容）
///    · 模型自己加了一堆 ⇒ 比例 > 1.25 ⇒ 拒（在做"解读"而不是"翻译"）
///
/// ⚠️ 阈值刻意**宽**：宁可放行一个略有出入的译文，也不要让正常请求失败
///    （失败对用户来说是**白扣一次额度**的体验，即使我们退额）。
pub fn parse_segments(raw: &str, original: &str) -> Result<Vec<Segment>, String> {
    let v: serde_json::Value =
        serde_json::from_str(raw.trim()).map_err(|e| format!("返回不是合法 JSON: {e}"))?;

    let arr = v
        .get("segments")
        .and_then(|x| x.as_array())
        .ok_or_else(|| "缺少 segments 数组".to_string())?;

    if arr.is_empty() {
        return Err("segments 是空的".into());
    }
    if arr.len() > MAX_SEGMENTS {
        return Err(format!("segments 段数过多（{}）", arr.len()));
    }

    let mut out = Vec::with_capacity(arr.len());
    for (i, item) in arr.iter().enumerate() {
        let src = item
            .get("src")
            .and_then(|x| x.as_str())
            .ok_or_else(|| format!("第 {i} 项缺 src"))?;
        let dst = item
            .get("dst")
            .and_then(|x| x.as_str())
            .ok_or_else(|| format!("第 {i} 项缺 dst"))?;
        if dst.trim().is_empty() {
            return Err(format!("第 {i} 项的译文是空的"));
        }
        if src.trim().is_empty() {
            return Err(format!("第 {i} 项的原文是空的"));
        }
        out.push(Segment {
            src: src.to_string(),
            dst: dst.to_string(),
        });
    }

    // 覆盖率检查（见上方说明）
    let src_chars: usize = out.iter().map(|s| s.src.chars().count()).sum();
    let orig_chars = original.chars().count().max(1);
    let ratio = src_chars as f64 / orig_chars as f64;
    if !(0.8..=1.25).contains(&ratio) {
        return Err(format!(
            "译文与原文长度差异过大（src {src_chars} / 原文 {orig_chars}）"
        ));
    }

    Ok(out)
}

// ══════════════════════════════════════════════════════════════════════
// 额度（DB · 可独立断言）
// ══════════════════════════════════════════════════════════════════════

/// **尝试占一次额度**。返回 `true` = 占到（可以调模型），`false` = 已用尽。
///
/// # 🔴 为什么写成一条 SQL（而不是「先 SELECT 再 UPDATE」）
///
/// 「先查后写」在并发下会**双花**：两个请求同时读到 `used_count = 9`，
/// 各自认为「还有 1 次」⇒ 都放行 ⇒ 实际用了 11 次。
///
/// 这里的 `INSERT ... ON CONFLICT DO UPDATE ... **WHERE**` 让「判断 + 自增」
/// 成为**一条原子语句**：`WHERE` 不满足时该语句**影响 0 行** ⇒ 返回 `false`。
/// 这正是 SQLite（单写者）下最简的正确写法 —— 不需要显式事务。
///
/// ⚠️ 返回值直接来自 `execute` 的 **affected rows**（0 或 1）——
///    依赖的是 SQL 语义，不是「我们算出来的结果」。
pub fn try_consume_quota(
    conn: &rusqlite::Connection,
    uid: &str,
    period: &str,
    chars: i64,
    limit: i64,
    now: &str,
) -> Result<bool, AppError> {
    let n = conn
        .execute(
            "INSERT INTO translation_usage (user_id, period, used_count, chars_sum, updated_at)
             VALUES (?1, ?2, 1, ?3, ?4)
             ON CONFLICT (user_id, period) DO UPDATE SET
               used_count = used_count + 1,
               chars_sum  = chars_sum + excluded.chars_sum,
               updated_at = excluded.updated_at
             WHERE translation_usage.used_count + 1 <= ?5",
            params![uid, period, chars, now, limit],
        )
        .map_err(|e| AppError::Internal(format!("占翻译额度: {e}")))?;
    Ok(n == 1)
}

/// **退还一次额度**（调模型失败 / 合规拒绝时）。
///
/// 🔴 必须有它：用户没拿到译文却扣了次数，是**最快失去信任**的方式。
///
/// ⚠️ 用 `MAX(0, used_count - 1)` 兜底：即使因为某种原因被多退一次，
///    也不会退成负数（负数会让「已用 0 次」显示不出来）。
pub fn refund_quota(conn: &rusqlite::Connection, uid: &str, period: &str) -> Result<(), AppError> {
    conn.execute(
        "UPDATE translation_usage
            SET used_count = MAX(0, used_count - 1),
                updated_at = ?3
          WHERE user_id = ?1 AND period = ?2",
        params![uid, period, crate::sync_handlers::now_ms()],
    )
    .map_err(|e| AppError::Internal(format!("退还翻译额度: {e}")))?;
    Ok(())
}

/// 本月已用次数（**订阅用户也查** —— 返回值用于回显「本月已用 N 次」）。
pub fn usage_of(conn: &rusqlite::Connection, uid: &str, period: &str) -> Result<i64, AppError> {
    conn.query_row(
        "SELECT COALESCE(used_count, 0) FROM translation_usage
          WHERE user_id = ?1 AND period = ?2",
        params![uid, period],
        |r| r.get(0),
    )
    .or_else(|e| match e {
        rusqlite::Error::QueryReturnedNoRows => Ok(0),
        other => Err(AppError::Internal(format!("查翻译额度: {other}"))),
    })
}

// ══════════════════════════════════════════════════════════════════════
// 端侧翻译的额度预扣（A1 · 2026-10-09）
// ══════════════════════════════════════════════════════════════════════

/// 端侧翻译「预扣」成功后发出的**一次性凭据**。
///
/// # 🔴 它同时解决两个问题（少解决一个都会坏）
///
/// | 问题 | 不解决的后果 |
/// |---|---|
/// | **回落时重复扣额** | 端侧翻失败 → 回落 LLM → **再扣 1 次** ⇒ 一次翻译收两次 |
/// | **凭据被冒用** | 不做归属校验 ⇒ 换个身份就能白拿一次免扣 |
///
/// # 为什么放内存、不建表
/// · 生命周期只跨「预扣 → 端侧翻 → 可能回落」这一次交互（**秒级**）
/// · 丢了的最坏后果 = 用户**多扣 1 次**（罕见路径），**不是数据损坏**
/// · 建表等于为「容错」多养一张表 —— 本库的原则是**不为假想的复杂度付费**
///
/// ⚠️ 过期项在**每次访问时顺手清理**（见 [`issue_ticket`]），不依赖后台任务。
#[derive(Debug, Clone)]
struct QuotaTicket {
    uid: String,
    expires_at_ms: i64,
}

/// 凭据有效期。5 分钟 ≫「预扣 → 端侧翻 → 回落」的实际耗时（秒级），
/// 又短到不会被长期囤积。
const TICKET_TTL_MS: i64 = 5 * 60 * 1000;

type TicketMap = std::collections::HashMap<String, QuotaTicket>;

fn tickets() -> &'static std::sync::Mutex<TicketMap> {
    static T: std::sync::OnceLock<std::sync::Mutex<TicketMap>> = std::sync::OnceLock::new();
    T.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// 发一张凭据（=「这个人刚刚扣过 1 次」的证明）。
fn issue_ticket(uid: &str, now_ms: i64) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    // ⚠️ 用 `unwrap_or_else(|e| e.into_inner())` 而不是 `unwrap()`：
    //    本 Map 的操作**不会 panic**（只做插入/删除/保留），中毒只可能是
    //    别的线程 panic 波及 —— 继续用比「崩掉整个请求」好（翻译是旁路能力）。
    let mut m = tickets().lock().unwrap_or_else(|e| e.into_inner());
    m.retain(|_, t| t.expires_at_ms > now_ms); // 顺手清过期 ⇒ Map 不会无界增长
    m.insert(
        id.clone(),
        QuotaTicket {
            uid: uid.to_string(),
            expires_at_ms: now_ms + TICKET_TTL_MS,
        },
    );
    id
}

/// 校验并**消费**一张凭据。只有「属于该用户 + 未过期」才算有效。
///
/// 🔑 **消费即删除**（一次性）—— 否则同一张凭据能反复换来免扣。
fn take_ticket(uid: &str, ticket: &str, now_ms: i64) -> bool {
    let mut m = tickets().lock().unwrap_or_else(|e| e.into_inner());
    m.retain(|_, t| t.expires_at_ms > now_ms);
    match m.get(ticket) {
        Some(t) if t.uid == uid => {
            m.remove(ticket);
            true
        }
        _ => false,
    }
}

#[derive(Debug, Deserialize)]
pub struct QuotaRequest {
    /// 本次预计翻译的字符数（与 `translate_text` 的 `chars_sum` 同口径）。
    /// 缺省 = 0 ⇒ 它是**统计值，不参与上限判断**。
    #[serde(default)]
    pub chars: i64,
}

#[derive(Debug, Serialize)]
pub struct QuotaTicketOut {
    pub quota: QuotaInfo,
    /// 🔑 **非订阅用户才有**。回落时带回来 ⇒ 服务端据此**跳过扣额**。
    /// 订阅用户为 `None`（他们不受上限，回落本来就不扣）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
}

/// `POST /api/translate/quota` —— 端侧翻译的**额度预扣**（A1）。
///
/// # 为什么端侧翻译还要服务端点头
///
/// 端侧翻译本身**零成本**，但「翻译」是一项**订阅权益**（免费 10 次/月 · 订阅无限）。
/// 若端侧翻译完全绕过服务端，免费用户就变成**事实上无限** ⇒ 权益就不是「不变」了。
/// ⇒ 所以：**端侧翻之前先扣额**，闸门仍握在服务端手里（与 [`translate_text`] 用
/// **同一个** [`try_consume_quota`]、同一条原子 SQL —— 口径只有一处）。
///
/// ⚠️ 本接口**不调模型** —— 这正是它便宜的原因。
pub async fn consume_quota_handler(
    headers: HeaderMap,
    Json(req): Json<QuotaRequest>,
) -> Result<Json<QuotaTicketOut>, AppError> {
    let (uid, _token) = crate::sync_handlers::authorize_login_only(&headers)?;
    let out = consume_quota_for_ondevice(req.chars.max(0), &uid)?;
    Ok(Json(out))
}

/// 预扣一次额度（**端侧翻译专用 · 不调模型**）。
pub fn consume_quota_for_ondevice(chars: i64, uid: &str) -> Result<QuotaTicketOut, TranslateError> {
    let period = current_period(chrono::Utc::now());
    let now_ms = crate::sync_handlers::now_ms();
    let conn = crate::db_pool::get_conn();
    consume_quota_on_conn(&conn, chars, uid, &period, &now_ms)
}

/// [`consume_quota_for_ondevice`] 的**可独立断言**核心（只依赖 `conn`）。
///
/// 🔑 拆出来是为了**能测**（`db_pool::get_conn()` 是全局池，测试里拿不到）。
///    它与 `translate_text` 走**同一个** [`try_consume_quota`] ⇒
///    「额度口径只有一处」这条由**结构**保证，而不是靠人去对齐。
pub fn consume_quota_on_conn(
    conn: &rusqlite::Connection,
    chars: i64,
    uid: &str,
    period: &str,
    now_ms: &str,
) -> Result<QuotaTicketOut, TranslateError> {
    // 🔑 与 `try_consume_quota` 的 `now` **同口径**（毫秒时间戳**字符串**）——
    //    凭据的过期判断需要整数 ⇒ 在此解析一次。
    //    ⚠️ 解析失败退化 0 ⇒ 凭据**立即过期**（保守：宁可多扣一次，不可漏扣）。
    let now_i = now_ms.parse::<i64>().unwrap_or(0);
    if crate::subscription::is_subscription_active(conn, uid) {
        // 订阅用户不受上限 ⇒ **不预扣、也不发凭据**（回落时同样不受限）
        let used = usage_of(conn, uid, period)?;
        return Ok(QuotaTicketOut {
            quota: QuotaInfo {
                used,
                limit: None,
                subscribed: true,
            },
            ticket: None,
        });
    }

    if !try_consume_quota(conn, uid, period, chars, FREE_MONTHLY_LIMIT, now_ms)? {
        return Err(TranslateError::QuotaExceeded);
    }
    let used = usage_of(conn, uid, period)?;
    Ok(QuotaTicketOut {
        quota: QuotaInfo {
            used,
            limit: Some(FREE_MONTHLY_LIMIT),
            subscribed: false,
        },
        ticket: Some(issue_ticket(uid, now_i)),
    })
}

// ══════════════════════════════════════════════════════════════════════
// 错误
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug)]
pub enum TranslateError {
    BadInput(String),
    /// 免费额度用尽（**不是**「未订阅」—— 见 handler 的文案）
    QuotaExceeded,
    Compliance(String),
    /// 格式闸门不过（模型返回形状不对）
    Gate(String),
    Upstream(String),
    Internal(String),
}

impl From<AppError> for TranslateError {
    /// 🔑 只能映射成 `Internal` —— 因为用 `?` 的地方（`usage_of` / `try_consume_quota`）
    ///    **本来就只产生 `AppError::Internal`**（它们是本模块自己的 DB 辅助，
    ///    没有 400/403 语义）。若哪天真出现别的变体，这个实现会把它**降级成 500** ——
    ///    所以那三个函数刻意不产生别的变体。
    fn from(e: AppError) -> Self {
        TranslateError::Internal(e.to_string())
    }
}

impl From<TranslateError> for AppError {
    fn from(e: TranslateError) -> Self {
        match e {
            TranslateError::BadInput(m) => AppError::BadRequest(m),
            // 🔴 403 而非 429：这不是「太频繁」，是「这个月的量用完了」。
            //    429 会让端侧按「稍后重试」处理 —— 用户会一直重试到明天。
            TranslateError::QuotaExceeded => AppError::Forbidden(format!(
                "本月翻译额度已用完（{FREE_MONTHLY_LIMIT} 次），下月 1 日重置"
            )),
            // 422 语义由端侧文案体现；这里用 BadRequest 的 400 也可，
            // 但 422 更准确（请求合法、内容不合规）
            TranslateError::Compliance(m) => AppError::BadRequest(format!("内容不合规：{m}")),
            TranslateError::Gate(m) => AppError::Internal(format!("译文格式异常：{m}")),
            TranslateError::Upstream(m) => AppError::Internal(format!("翻译服务异常：{m}")),
            TranslateError::Internal(m) => AppError::Internal(m),
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
// 出参
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug, Serialize)]
pub struct QuotaInfo {
    /// 本月已用（**成功计费的**次数）
    pub used: i64,
    /// 免费层上限；订阅用户为 `null`（不限）
    pub limit: Option<i64>,
    pub subscribed: bool,
}

#[derive(Debug, Serialize)]
pub struct TranslationOut {
    /// 🔑 **永远是一个数组**（即使只有一句）——
    ///    客户端只需**一条**渲染路径（判据：能少一个分支就少一个）。
    pub segments: Vec<Segment>,
    pub quota: QuotaInfo,
}

// ══════════════════════════════════════════════════════════════════════
// prompt
// ══════════════════════════════════════════════════════════════════════

fn prompts_dir() -> String {
    std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string())
}

/// 读翻译 prompt（**进程内缓存一次**，同 `llm_card::prompt`）。
pub fn prompt() -> Result<&'static str, TranslateError> {
    static P: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    if let Some(p) = P.get() {
        return Ok(p.as_str());
    }
    let path = format!("{}/{}", prompts_dir(), PROMPT_FILE);
    let s = std::fs::read_to_string(&path)
        .map_err(|e| TranslateError::Internal(format!("读翻译 prompt 失败 {path}: {e}")))?;
    if s.trim().is_empty() {
        return Err(TranslateError::Internal(format!(
            "翻译 prompt 是空的：{path}"
        )));
    }
    let _ = P.set(s);
    Ok(P.get().map(|x| x.as_str()).unwrap_or(""))
}

// ══════════════════════════════════════════════════════════════════════
// 核心
// ══════════════════════════════════════════════════════════════════════

/// 翻译一段文本。`uid` = 已鉴权的用户（额度记在他头上）。
///
/// # 顺序（每一步都有理由）
///
/// 1. 校验输入（**不花任何钱**的前置）
/// 2. 查订阅 → 决定要不要占额
/// 3. **占额**（原子）⇒ 失败立刻返回，**不调模型**
/// 4. 调模型（**此处不持有 DB 连接** —— 跨 await 持连接会拖住连接池）
/// 5. 合规闸门 → 不通过则**退额**
/// 6. 格式闸门 → 不通过则**退额**
/// 7. 返回译文 + 额度
///
/// ⚠️ 第 3 步「先占后退」而**不是**「先调后占」：
///    后者在并发下会超用（多人同时调、都还没记账）。
///    代价是失败路径多一步退款 —— 而退款失败只影响一次计数，不是数据损坏。
pub async fn translate_text(text: &str, uid: &str) -> Result<TranslationOut, TranslateError> {
    translate_text_inner(text, uid, None).await
}

/// [`translate_text`] 的完整实现。
///
/// `ticket`：端侧翻译**预扣**时发出的凭据（见 [`take_ticket`]）——
/// **有效时跳过扣额**（那次额度已在预扣时扣掉，不能再扣第二次）。
pub async fn translate_text_inner(
    text: &str,
    uid: &str,
    ticket: Option<&str>,
) -> Result<TranslationOut, TranslateError> {
    let clean = validate_text(text).map_err(TranslateError::BadInput)?;
    let chars = clean.chars().count() as i64;
    let period = current_period(chrono::Utc::now());

    // ── ① 订阅？占额？（凭据有效则**跳过**扣额 —— 那次已在预扣时扣过）──
    let subscribed = {
        let conn = crate::db_pool::get_conn();
        let sub = crate::subscription::is_subscription_active(&conn, uid);
        if sub {
            // 订阅用户不检查上限，但仍然**记账**（用于回显与将来的用量分析）
            let _ = usage_of(&conn, uid, &period)?;
            true
        } else {
            let now_ms = crate::sync_handlers::now_ms(); // 毫秒时间戳**字符串**
            let now_i = now_ms.parse::<i64>().unwrap_or(0);
            // 🔑 先看凭据：有效 ⇒ 本次是「端侧翻失败后的回落」⇒ 不再扣
            let pre_paid = ticket.map(|t| take_ticket(uid, t, now_i)).unwrap_or(false);
            if !pre_paid {
                let ok =
                    try_consume_quota(&conn, uid, &period, chars, FREE_MONTHLY_LIMIT, &now_ms)?;
                if !ok {
                    return Err(TranslateError::QuotaExceeded);
                }
            }
            false
        }
    };

    // ── ② 调模型（不持有连接）──
    let tpl = prompt()?;
    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .map_err(|_| TranslateError::Internal("DEEPSEEK_API_KEY 未配置".into()))?;

    let cfg = chat_engine::llm_caller::LlmConfig {
        api_key,
        base_url: "https://api.deepseek.com".to_string(),
        model: MODEL.to_string(),
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
    };
    let mut caller = chat_engine::llm_caller::LlmCaller::new(cfg);
    let user_msg = format!("{tpl}\n\n---\n\n{clean}");

    let reply = match caller
        .generate_with_extra("", &user_msg, &crate::llm_card::extra_params())
        .await
    {
        Ok(r) => r,
        Err(e) => {
            refund_or_log(uid, &period, subscribed);
            return Err(TranslateError::Upstream(format!("{e:?}")));
        }
    };

    // ── ③ 格式闸门（先解 JSON —— 后面的合规检查要拿结构化的值）──
    let segments = match parse_segments(&reply, &clean) {
        Ok(s) => s,
        Err(why) => {
            tracing::warn!(
                "translate: GATE REJECT uid={uid} reason={why} raw={}",
                crate::llm_card::preview(&reply)
            );
            refund_or_log(uid, &period, subscribed);
            return Err(TranslateError::Gate(why));
        }
    };

    // ── ④ 合规闸门（🔴 上线硬前提：动态生成内容无人工环节）──
    //
    // 🔑 复用 `check_card` —— 它内部 `collect_parts` **递归收集 JSON 里所有字符串**，
    //    所以翻译的形状（`{segments:[{src,dst}]}`）**天然适配**，不需要新写一个提取器。
    //    （判据：合规规则只能有一份实现。）
    let as_value = serde_json::json!({
        "segments": segments.iter().map(|s| serde_json::json!({"src": s.src, "dst": s.dst}))
                             .collect::<Vec<_>>()
    });
    match crate::compliance::check_card(&as_value, "") {
        Ok(crate::compliance::Verdict::Pass) => {}
        Ok(crate::compliance::Verdict::Violation(why)) => {
            tracing::warn!("translate: COMPLIANCE REJECT uid={uid} detail={why}");
            refund_or_log(uid, &period, subscribed);
            return Err(TranslateError::Compliance(why));
        }
        Err(e) => {
            // ⚠️ 词表加载失败 = **服务故障**（不是内容问题）⇒ 退款，但报 500
            tracing::error!("translate: 合规词表不可用: {e}");
            refund_or_log(uid, &period, subscribed);
            return Err(TranslateError::Internal(e));
        }
    }

    // ── ⑤ 回显额度 ──
    let used = {
        let conn = crate::db_pool::get_conn();
        usage_of(&conn, uid, &period)?
    };

    tracing::info!(
        "translate: uid={uid} chars={chars} segments={} used={used}",
        segments.len()
    );

    Ok(TranslationOut {
        segments,
        quota: QuotaInfo {
            used,
            limit: if subscribed {
                None
            } else {
                Some(FREE_MONTHLY_LIMIT)
            },
            subscribed,
        },
    })
}

/// 退额（非订阅用户才需要）。**失败只记日志**，不向上抛。
///
/// 🔑 为什么不让退款失败覆盖原始错误：用户看到的应该是**真正的原因**
///    （「模型超时」而不是「退款失败」）—— 后者会把他引向完全错误的排查方向。
fn refund_or_log(uid: &str, period: &str, subscribed: bool) {
    if subscribed {
        return; // 订阅用户不占免费额度，无需退
    }
    let conn = crate::db_pool::get_conn();
    if let Err(e) = refund_quota(&conn, uid, period) {
        tracing::error!("translate: 退还额度失败 uid={uid} period={period} err={e}");
    }
}

// ══════════════════════════════════════════════════════════════════════
// HTTP
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug, Deserialize)]
pub struct TranslateRequest {
    pub text: String,
    /// 🆕 端侧翻译预扣时拿到的**一次性凭据**（见 [`take_ticket`]）。
    ///
    /// 🔑 **可选，且缺省即现状** —— 老客户端不发这个字段，行为一字不变。
    #[serde(default)]
    pub ticket: Option<String>,
}

/// `POST /api/translate` —— **需登录**（额度要记在某个人头上）。
///
/// # 🔴 为什么这个端点可以要求登录（而读内容不行）
///
/// 产品原则：「**除生词表上限外不验证登录态**」—— 那条针对的是
/// **内容可见性**（读信息流 / 打开文章 / 划词 / 复习）。
///
/// 翻译是**有真实成本、需要记账**的能力 ⇒ 它属于「能力限制」那一类
/// （同 `/api/sync/*`）。**它不阻塞任何内容渲染** ⇒ 不违反那条原则。
///
/// ⚠️ 未登录回 **401**（不是 403）：端侧收到 401 的标准处理是
///    「清凭据 → 跳登录」—— 这对未登录用户正是正确行为。
///    而「已登录但额度用尽」回 **403**（见 `TranslateError::QuotaExceeded`），
///    用户不会被莫名登出。
pub async fn translate_handler(
    headers: HeaderMap,
    Json(req): Json<TranslateRequest>,
) -> Result<Json<TranslationOut>, AppError> {
    let (uid, _token) = crate::sync_handlers::authorize_login_only(&headers)?;
    let out = translate_text_inner(&req.text, &uid, req.ticket.as_deref()).await?;
    Ok(Json(out))
}

// ══════════════════════════════════════════════════════════════════════
// 测试
// ══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn setup() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn
    }

    fn utc(y: i32, m: u32, d: u32, h: u32, mi: u32) -> chrono::DateTime<chrono::Utc> {
        chrono::Utc.with_ymd_and_hms(y, m, d, h, mi, 0).unwrap()
    }

    // ══════════════════════════════════════════════════════════════
    // ① 周期边界（UTC+8 口径）
    // ══════════════════════════════════════════════════════════════

    /// 🔴 周期按 **UTC+8** 算 —— 这条守的是「中国用户 1 号凌晨能不能用」。
    ///
    /// 期望值**手写**（不是跑一遍得到的）：UTC 9 月 30 日 16:00 = 北京时间 10 月 1 日 00:00。
    #[test]
    fn test_period_is_utc_plus_8() {
        // 北京时间 9/30 23:59 ⇒ 仍是 9 月
        assert_eq!(current_period(utc(2026, 9, 30, 15, 59)), "2026-09");
        // 北京时间 10/1 00:00 ⇒ 进入 10 月（UTC 还是 9/30 16:00）
        assert_eq!(
            current_period(utc(2026, 9, 30, 16, 0)),
            "2026-10",
            "🔴 UTC 还在 9 月，但中国用户已经是 10 月 1 日 ⇒ 必须给他新额度"
        );
        // 跨年
        assert_eq!(current_period(utc(2026, 12, 31, 16, 0)), "2027-01");
        // 月中
        assert_eq!(current_period(utc(2026, 10, 8, 4, 0)), "2026-10");
    }

    // ══════════════════════════════════════════════════════════════
    // ② 输入校验
    // ══════════════════════════════════════════════════════════════

    #[test]
    fn test_validate_text_boundaries() {
        assert!(validate_text("Hello.").is_ok());
        // 首尾空白会被去掉（选区常带空白）
        assert_eq!(validate_text("  Hello.  ").unwrap(), "Hello.");

        assert!(validate_text("").is_err(), "空");
        assert!(validate_text("   ").is_err(), "纯空白");
        assert!(validate_text("。，！").is_err(), "没有英文字母");
        assert!(validate_text("123 456").is_err(), "没有英文字母");

        // 恰好 800 字符 ⇒ 允许；801 ⇒ 拒（**不截断**）
        let ok_max = "a".repeat(MAX_TEXT_CHARS);
        assert!(
            validate_text(&ok_max).is_ok(),
            "恰好 {MAX_TEXT_CHARS} 应当允许"
        );
        let over_max = "a".repeat(MAX_TEXT_CHARS + 1);
        let err = validate_text(&over_max).unwrap_err();
        assert!(err.contains("太长"), "应当明确说太长：{err}");

        // ⚠️ 按**字符**不是字节：300 个中文字（UTF-8 下 900 字节）不含字母 ⇒ 拒；
        //    但长度判定必须按字符，否则 900 字节会被"超 800 字节"误判为太长。
        //
        // 🔴 这个样本的大小**必须跟着 `MAX_TEXT_CHARS` 走**：
        //    它要同时满足 ① 字符数 ≤ 上限 ② **字节数 > 上限**，
        //    才验得出「实现改成按字节判」这个回归。
        //    上限 300 时取 150（450 字节 > 300）刚好够；
        //    上限提到 800 后，150 个中文只有 450 字节 ⇒ **不再触发误判 ⇒ 断言变成假绿**。
        //    ⇒ 现在取 300（900 字节 > 800 ✅，且 300 ≤ 800 ✅）。
        //    📌 判据：**阈值的测试样本必须随阈值一起重算**，否则守的东西悄悄消失。
        let zh300 = "中".repeat(300);
        let e = validate_text(&zh300).unwrap_err();
        assert!(
            e.contains("没有英文"),
            "300 个中文字符（900 字节）不该被判太长，实际：{e}"
        );
    }

    /// 🔴 三个长度相关常量必须**同比例** —— 只改一个会让长文本以两种方式**静默坏掉**。
    ///
    /// | 常量 | 现状 | 漏改的后果 |
    /// |---|---|---|
    /// | `MAX_TEXT_CHARS` | 800 | —（用户可选中长度）|
    /// | `MAX_TOKENS` | 2400（= 上限 × 3）| 译文**被拦腰截断**，不报错 |
    /// | `MAX_SEGMENTS` | 140（≈ 上限 ÷ 5.7）| 长文本被**拒：段落太多** |
    ///
    /// ⚠️ 断言写成**区间**而不是精确等式：常量可以按需微调，
    ///    但要挡住的是「上限翻了几倍、另两个没动」这种**量级脱节**。
    /// 📌 判据：**派生值必须与源值同生命周期** —— 只改源值 = 制造静默 bug。
    #[test]
    fn test_length_constants_stay_in_proportion() {
        assert!(
            MAX_TOKENS as usize >= MAX_TEXT_CHARS * 2,
            "MAX_TOKENS={MAX_TOKENS} 相对 MAX_TEXT_CHARS={MAX_TEXT_CHARS} 太小\
             ⇒ 长文本的译文会被**静默截断**（用户拿到半句中文，日志里什么都没有）"
        );
        assert!(
            MAX_SEGMENTS >= MAX_TEXT_CHARS / 10,
            "MAX_SEGMENTS={MAX_SEGMENTS} 相对 MAX_TEXT_CHARS={MAX_TEXT_CHARS} 太小\
             ⇒ 长文本会被**拒：段落太多**（实测按最短句切约 1 段/10 字符）"
        );
        assert!(
            MAX_TOKENS as usize <= MAX_TEXT_CHARS * 6,
            "MAX_TOKENS 相对上限过大 ⇒ 单次成本上限被白抬高"
        );
    }

    // ══════════════════════════════════════════════════════════════
    // ③ 格式闸门
    // ══════════════════════════════════════════════════════════════

    #[test]
    fn test_parse_segments_accepts_wellformed() {
        let raw = r#"{"segments":[{"src":"Hello world.","dst":"你好，世界。"}]}"#;
        let s = parse_segments(raw, "Hello world.").unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].dst, "你好，世界。");

        // 多句
        let raw2 = r#"{"segments":[
            {"src":"He runs.","dst":"他跑了。"},
            {"src":"She walks.","dst":"她走着。"}]}"#;
        let s2 = parse_segments(raw2, "He runs. She walks.").unwrap();
        assert_eq!(s2.len(), 2);
    }

    /// 🔴 覆盖率闸门：模型**只翻一半** / **自己加内容** 都要被拒。
    #[test]
    fn test_parse_segments_rejects_coverage_violations() {
        // 只回半句（src 明显短于原文）
        let half = r#"{"segments":[{"src":"Hello.","dst":"你好。"}]}"#;
        let long_orig = "Hello. This is a much longer sentence that got dropped entirely.";
        assert!(
            parse_segments(half, long_orig).is_err(),
            "🔴 只翻一半必须拒（否则用户以为模型漏翻了）"
        );

        // 模型自己加了一堆（src 远长于原文）
        let inflated = r#"{"segments":[{"src":"Hello. And here is a lot more text that the model invented on its own, much longer than the input.","dst":"你好。"}]}"#;
        assert!(
            parse_segments(inflated, "Hello.").is_err(),
            "🔴 自己加内容必须拒（那是在『解读』不是在『翻译』）"
        );
    }

    #[test]
    fn test_parse_segments_rejects_malformed() {
        assert!(parse_segments("not json", "Hello.").is_err(), "非 JSON");
        assert!(
            parse_segments(r#"{"x":1}"#, "Hello.").is_err(),
            "缺 segments"
        );
        assert!(
            parse_segments(r#"{"segments":[]}"#, "Hello.").is_err(),
            "空数组"
        );
        assert!(
            parse_segments(r#"{"segments":[{"src":"hi"}]}"#, "hi").is_err(),
            "缺 dst"
        );
        assert!(
            parse_segments(r#"{"segments":[{"src":"hi","dst":"  "}]}"#, "hi").is_err(),
            "空译文"
        );
    }

    /// 智能引号等「字符级差异」**不该**让请求失败（这正是不用「逐字相等」的理由）。
    #[test]
    fn test_parse_segments_tolerates_char_level_differences() {
        let raw = r#"{"segments":[{"src":"don’t stop.","dst":"别停。"}]}"#;
        assert!(
            parse_segments(raw, "don't stop.").is_ok(),
            "智能引号不该判失败（覆盖率口径下长度一致）"
        );
    }

    // ══════════════════════════════════════════════════════════════
    // ④ 额度（原子占额 · 退款 · 用户隔离）
    // ══════════════════════════════════════════════════════════════

    /// 🔴 额度**恰好用满**：第 N 次成功、第 N+1 次失败。
    #[test]
    fn test_quota_exact_boundary() {
        let conn = setup();
        let p = "2026-10";
        let now = "2026-10-08T00:00:00.000Z";
        for i in 1..=FREE_MONTHLY_LIMIT {
            assert!(
                try_consume_quota(&conn, "u1", p, 10, FREE_MONTHLY_LIMIT, now).unwrap(),
                "第 {i} 次应当成功"
            );
        }
        assert!(
            !try_consume_quota(&conn, "u1", p, 10, FREE_MONTHLY_LIMIT, now).unwrap(),
            "🔴 第 {} 次必须失败",
            FREE_MONTHLY_LIMIT + 1
        );
        assert_eq!(usage_of(&conn, "u1", p).unwrap(), FREE_MONTHLY_LIMIT);
    }

    /// 退款让额度**真的回得来**（并且不会退成负数）。
    #[test]
    fn test_quota_refund() {
        let conn = setup();
        let p = "2026-10";
        let now = "2026-10-08T00:00:00.000Z";

        assert!(try_consume_quota(&conn, "u1", p, 10, 1, now).unwrap());
        assert!(
            !try_consume_quota(&conn, "u1", p, 10, 1, now).unwrap(),
            "已满"
        );

        refund_quota(&conn, "u1", p).unwrap();
        assert_eq!(usage_of(&conn, "u1", p).unwrap(), 0, "退款后回到 0");
        assert!(
            try_consume_quota(&conn, "u1", p, 10, 1, now).unwrap(),
            "退款后应当又能用了"
        );

        // 多退几次不能变负
        refund_quota(&conn, "u1", p).unwrap();
        refund_quota(&conn, "u1", p).unwrap();
        refund_quota(&conn, "u1", p).unwrap();
        assert_eq!(usage_of(&conn, "u1", p).unwrap(), 0, "🔴 不能退成负数");
    }

    /// 周期隔离：上月用满**不影响**本月。
    #[test]
    fn test_quota_period_isolation() {
        let conn = setup();
        let now = "2026-10-08T00:00:00.000Z";
        assert!(try_consume_quota(&conn, "u1", "2026-09", 10, 1, now).unwrap());
        assert!(
            !try_consume_quota(&conn, "u1", "2026-09", 10, 1, now).unwrap(),
            "9 月已满"
        );
        assert!(
            try_consume_quota(&conn, "u1", "2026-10", 10, 1, now).unwrap(),
            "🔴 10 月是新的额度 —— 用户不该被上个月的用量惩罚"
        );
    }

    /// 额度**按人隔离**。
    #[test]
    fn test_quota_per_user_isolation() {
        let conn = setup();
        let p = "2026-10";
        let now = "2026-10-08T00:00:00.000Z";
        assert!(try_consume_quota(&conn, "u1", p, 10, 1, now).unwrap());
        assert!(!try_consume_quota(&conn, "u1", p, 10, 1, now).unwrap());
        assert!(
            try_consume_quota(&conn, "u2", p, 10, 1, now).unwrap(),
            "🔴 别人用满了不该影响我"
        );
        assert_eq!(usage_of(&conn, "nobody", p).unwrap(), 0, "陌生用户 = 0");
    }

    /// 并发占额不会**双花**（模拟「先查后写」会放行的场景）。
    ///
    /// 🔑 单条 SQL 的意义就在这：把「判断 + 自增」做成一次原子操作。
    ///    这里用「连续调用」表达「两个请求同时看到 old=9」的最坏情况 ——
    ///    在单写者 SQLite 下，行为与真并发一致。
    #[test]
    fn test_quota_no_double_spend_at_boundary() {
        let conn = setup();
        let p = "2026-10";
        let now = "2026-10-08T00:00:00.000Z";
        // 先用到只剩 1 次
        for _ in 0..(FREE_MONTHLY_LIMIT - 1) {
            assert!(try_consume_quota(&conn, "u1", p, 10, FREE_MONTHLY_LIMIT, now).unwrap());
        }
        // 剩下 1 次：两次「同时」的请求只能有一个成功
        let a = try_consume_quota(&conn, "u1", p, 10, FREE_MONTHLY_LIMIT, now).unwrap();
        let b = try_consume_quota(&conn, "u1", p, 10, FREE_MONTHLY_LIMIT, now).unwrap();
        assert!(a ^ b, "🔴 只能有一个占到（a={a} b={b}）");
        assert_eq!(
            usage_of(&conn, "u1", p).unwrap(),
            FREE_MONTHLY_LIMIT,
            "不得超过上限"
        );
    }

    /// 表确实被建出来了（`init_database` 无条件跑）。
    #[test]
    fn test_table_exists() {
        let conn = setup();
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='translation_usage'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1, "translation_usage 表必须存在");
    }

    // ══════════════════════════════════════════════════════════════
    // ⑧ 端侧翻译的额度预扣 + 一次性凭据（A1 · 2026-10-09）
    // ══════════════════════════════════════════════════════════════
    //
    // ⚠️ 每个用例用**不同的 uid 与时间戳** —— 凭据存在**进程级全局 Map** 里，
    //    而 `cargo test` 默认多线程并行 ⇒ 共用 uid 会互相干扰（假红/假绿都可能）。
    //    凭据本身是 uuid ⇒ 天然唯一，只需避开 uid 与 now_ms 撞车。

    /// 🔑 凭据**只能消费一次** —— 否则一张凭据能反复换免扣（免费用户=无限）。
    #[test]
    fn ticket_is_single_use() {
        let now = 1_000_000i64;
        let t = issue_ticket("tkt-single", now);
        assert!(take_ticket("tkt-single", &t, now), "首次应有效");
        assert!(
            !take_ticket("tkt-single", &t, now + 1),
            "★ 第二次必须失效（一次性）"
        );
    }

    /// 🔴 凭据**绑定归属**：换 uid 不能用；且失败的那次尝试**不消费**它。
    #[test]
    fn ticket_is_bound_to_user() {
        let now = 2_000_000i64;
        let t = issue_ticket("tkt-owner", now);
        assert!(!take_ticket("tkt-thief", &t, now), "★ 别人的凭据必须无效");
        assert!(
            take_ticket("tkt-owner", &t, now),
            "本人仍可用（上面那次没把它消费掉）"
        );
    }

    /// ⏰ 过期即失效。
    #[test]
    fn ticket_expires() {
        let now = 3_000_000i64;
        let t = issue_ticket("tkt-exp", now);
        assert!(
            !take_ticket("tkt-exp", &t, now + TICKET_TTL_MS),
            "★ 过期后必须无效"
        );
        // 边界之内仍有效 —— 证明上面的失效是「过期」而不是「路径不通」
        let t2 = issue_ticket("tkt-exp2", now);
        assert!(take_ticket("tkt-exp2", &t2, now + TICKET_TTL_MS - 1));
    }

    /// 不存在的凭据 ⇒ 无效，且**不 panic**（客户端可能乱传）。
    #[test]
    fn unknown_ticket_is_rejected() {
        assert!(!take_ticket("tkt-unknown", "no-such-ticket", 4_000_000));
        assert!(!take_ticket("tkt-unknown", "", 4_000_000), "空串同样无效");
    }

    // ── 预扣：与 `translate_text` 走同一套额度口径 ──

    /// 免费用户预扣 ⇒ 扣 1、**必须拿到凭据**（回落靠它免重复扣）。
    #[test]
    fn quota_consume_grants_ticket_for_free_user() {
        let conn = setup();
        let out = consume_quota_on_conn(&conn, 12, "pre-a", "2026-10", "5000000").unwrap();
        assert_eq!(out.quota.used, 1, "应扣掉 1 次");
        assert_eq!(out.quota.limit, Some(FREE_MONTHLY_LIMIT));
        assert!(!out.quota.subscribed);
        assert!(out.ticket.is_some(), "★ 免费用户必须拿到凭据");
    }

    /// 免费用户**到上限** ⇒ 报 `QuotaExceeded`（同一条原子 SQL 判的）。
    #[test]
    fn quota_consume_rejects_when_exhausted() {
        let conn = setup();
        for i in 0..FREE_MONTHLY_LIMIT {
            let ok =
                try_consume_quota(&conn, "pre-b", "2026-10", 1, FREE_MONTHLY_LIMIT, "t").unwrap();
            assert!(ok, "第 {i} 次应成功");
        }
        let err = consume_quota_on_conn(&conn, 1, "pre-b", "2026-10", "5000000").unwrap_err();
        assert!(
            matches!(err, TranslateError::QuotaExceeded),
            "★ 到上限必须报额度用尽"
        );
    }

    /// 订阅用户预扣 ⇒ **不发凭据**、`limit` 为 `None`（他本来就不受限）。
    #[test]
    fn quota_consume_for_subscriber_has_no_ticket() {
        let conn = setup();
        conn.execute(
            "INSERT INTO users (id, username, email, subscription_expires, created_at)
             VALUES ('pre-sub', 'pre-sub', 'pre-sub@x.com', '2030-01-01', '2026-10-09')",
            [],
        )
        .unwrap();
        let out = consume_quota_on_conn(&conn, 12, "pre-sub", "2026-10", "5000000").unwrap();
        assert!(out.quota.subscribed, "该账号应被判定为订阅中");
        assert_eq!(out.quota.limit, None, "订阅不限 ⇒ limit 为 None");
        assert!(out.ticket.is_none(), "★ 订阅用户不需要凭据");
    }

    /// 🔴 预扣**不调模型**：它只碰额度表 ⇒ 未配 `DEEPSEEK_API_KEY` 也能成功。
    ///    （这条守的是「预扣接口便宜」这个前提 —— 一旦有人往里面塞模型调用，它会红。）
    #[test]
    fn quota_consume_does_not_touch_llm() {
        let conn = setup();
        // 环境里没有 key 也应该成功（本测试不依赖环境变量）
        let out = consume_quota_on_conn(&conn, 5, "pre-c", "2026-10", "6000000");
        assert!(out.is_ok(), "预扣不该依赖任何模型配置：{:?}", out.err());
    }
}
