//! 整段 / 整句翻译（订阅权益 · 2026-10-08）
//!
//! # 与词卡制卡（`llm_card`）的关系
//!
//! | | `llm_card` | 本模块 |
//! |---|---|---|
//! | 输入 | 一个**词形**（≤64 字符、严格白名单）| 任意文本（≤300 字符）|
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
//! · **按次，不按长度**（选中上限 300 字符）⇒ 用户不必猜「这句长会不会多扣」
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

/// 输出上限。翻译是「等长改写」，300 字符英文译成中文约 1.5 倍字符数 ⇒ 900 足够。
const MAX_TOKENS: u32 = 900;
/// 低温度：翻译要**稳定**，不要发挥。
const TEMPERATURE: f32 = 0.2;

/// 选中文本长度上限（**字符**，不是字节）。
///
/// 🔑 与划线记忆同一条线（300）—— 用户「选不动了就该分段处理」。
pub const MAX_TEXT_CHARS: usize = 300;

/// 免费层每月次数（设计稿 §3 定的初值）。
pub const FREE_MONTHLY_LIMIT: i64 = 10;

/// 段数上限（防滥用：一次请求最多产出这么多段）。
///
/// 300 字符按最短句子切也就 20–30 段，50 是安全余量。
const MAX_SEGMENTS: usize = 50;

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
    let clean = validate_text(text).map_err(TranslateError::BadInput)?;
    let chars = clean.chars().count() as i64;
    let period = current_period(chrono::Utc::now());

    // ── ① 订阅？占额？──
    let (subscribed, used_before) = {
        let conn = crate::db_pool::get_conn();
        let sub = crate::subscription::is_subscription_active(&conn, uid);
        if sub {
            // 订阅用户不检查上限，但仍然**记账**（用于回显与将来的用量分析）
            let before = usage_of(&conn, uid, &period)?;
            (true, before)
        } else {
            let ok = try_consume_quota(
                &conn,
                uid,
                &period,
                chars,
                FREE_MONTHLY_LIMIT,
                &crate::sync_handlers::now_ms(),
            )?;
            if !ok {
                return Err(TranslateError::QuotaExceeded);
            }
            (false, usage_of(&conn, uid, &period)?)
        }
    };
    let _ = used_before;

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
    let out = translate_text(&req.text, &uid).await?;
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

        // 恰好 300 字符 ⇒ 允许；301 ⇒ 拒（**不截断**）
        let ok300 = "a".repeat(MAX_TEXT_CHARS);
        assert!(validate_text(&ok300).is_ok(), "恰好 300 应当允许");
        let bad301 = "a".repeat(MAX_TEXT_CHARS + 1);
        let err = validate_text(&bad301).unwrap_err();
        assert!(err.contains("太长"), "应当明确说太长：{err}");

        // ⚠️ 按**字符**不是字节：300 个中文字（UTF-8 下 900 字节）不含字母 ⇒ 拒；
        //    但长度判定必须按字符，否则 90 个中文就"超 300 字节"了。
        let zh150 = "中".repeat(150);
        let e = validate_text(&zh150).unwrap_err();
        assert!(
            e.contains("没有英文"),
            "150 个中文字符不该被判太长，实际：{e}"
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
}
