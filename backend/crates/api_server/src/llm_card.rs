//! 词库在线制卡（LLM 兜底）—— `POST /api/generate-card`
//!
//! # 这条路径解决什么
//!
//! 用户划到的词**不在 `word.db`** 时（`hong kong` / 新闻里的新词 / 罕见词），
//! 端侧现在只弹「词库里没有「X」」然后结束 —— **没有出口**。
//! 本模块提供出口：**服务端调 LLM 生成一张卡 → 写全局缓存 → 返回**。
//!
//! # 为什么在服务端（不是端侧）
//!
//! | | 服务端（本模块） | 端侧直连 |
//! |---|---|---|
//! | 跨用户复用 | ✅ **全局缓存** → 成本 ∝ **唯一词数** | ❌ 成本 ∝ 用户数 |
//! | key 安全 | ✅ 只在服务端 | 🔴 打进 IPA 会被提取 |
//! | 聚类一致性 | ✅ 全局唯一 | ❌ 各设备不同 |
//!
//! # 🔴 「与预制同一套」= prompt + 参数 + 校验 **三者都要对齐**
//!
//! 白哥要求「在线生成与预制**同一套** prompt / 契约 / 校验」。只对齐 prompt **不够** ——
//! 实测两边参数原本不一致（下表的「预制」列来自 `scripts/coevo_wordlib_contract.py`）：
//!
//! | 参数 | 预制 | 本模块 |
//! |---|---|---|
//! | `model` | `deepseek-flash` | **同**（见 [`MODEL`]） |
//! | `max_tokens` | `900` | **同** |
//! | `temperature` | `0.1` | **同** |
//! | `response_format` | `{"type":"json_object"}` | **同**（[`extra_params`]） |
//! | `thinking` | `{"type":"disabled"}` | **同**（同上；**缺了成本可能差数倍**） |
//! | messages | 单条 `user`（prompt 全文） | **同**（传空 system → 只有 user） |
//!
//! # 三层缓存里的位置
//!
//! 本模块维护**第 ② 层：服务端全局缓存**（`generated_card_cache`）——
//! 跨用户复用的主力（① 端侧缓存只管本机；③ `word.db` 靠版本发布）。

use std::collections::HashSet;
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

use rusqlite::Connection;

// ══════════════════════════════════════════════════════════════════
// 🔴 与 `scripts/coevo_wordlib_contract.py` **逐项对齐**的常量
//    改这里必须同步改那边（反之亦然），否则「同一套」不成立
// ══════════════════════════════════════════════════════════════════

/// 契约版本 —— 与 Python 侧 `CONTRACT_VERSION` 对齐。
/// 🔑 写进缓存行 → 契约升级后可识别/失效陈旧缓存。
pub const CONTRACT_VERSION: &str = "v6";

/// 模型名 —— 与 Python 侧 `MODEL` 默认值一致。
/// ⚠️ 不要改用 `LlmConfig::deepseek_v4_flash()` 里的 `deepseek-v4-flash`：
///    两者**不是同一个名字**，而 `deepseek-flash` 是**实测有效**的那个（smoke 10/10）。
const MODEL: &str = "deepseek-flash";

/// 与 Python 侧 `max_tokens=900` 对齐（默认 config 是 65536 —— 差 73 倍）。
const MAX_TOKENS: u32 = 900;

/// 与 Python 侧 `temperature=0.1` 对齐（默认 config 是 0.7 —— 词卡要确定性）。
const TEMPERATURE: f32 = 0.1;

/// 预制脚本传的**额外请求体字段**（`generate_with_extra` 会 merge 进去）。
fn extra_params() -> serde_json::Value {
    serde_json::json!({
        "response_format": {"type": "json_object"},
        "thinking": {"type": "disabled"},
    })
}

/// prompt 文件名（在 `COEVO_PROMPTS_DIR` 下）—— **与 Python 读同一个文件**。
const PROMPT_FILE: &str = "wordlib_contract.md";

/// 别人正在生成时，本请求最多等多久。
const WAIT_TIMEOUT: Duration = Duration::from_millis(8000);
/// 等待时的轮询间隔。
const WAIT_POLL: Duration = Duration::from_millis(200);

/// 词形长度上限（防滥用）。
const MAX_SPELLING_LEN: usize = 64;

// ══════════════════════════════════════════════════════════════════

/// 错误分类 —— **分「参数错」与「上游错」**（照 `tencent_asr.rs` 的模式）。
#[derive(Debug)]
pub enum CardError {
    /// 400：请求参数不合法
    BadRequest(String),
    /// 503：同词正在生成中（前端提示 + 自动重试）
    InProgress,
    /// 502：LLM 上游失败
    Upstream(String),
    /// 422：生成结果没过闸门（**不写缓存** —— 避免把错固化）
    Gate(String),
    /// 500：本地错误（DB / 文件 / 解析）
    Internal(String),
}

impl CardError {
    pub fn status(&self) -> axum::http::StatusCode {
        use axum::http::StatusCode;
        match self {
            CardError::BadRequest(_) => StatusCode::BAD_REQUEST,
            CardError::InProgress => StatusCode::SERVICE_UNAVAILABLE,
            CardError::Upstream(_) => StatusCode::BAD_GATEWAY,
            CardError::Gate(_) => StatusCode::UNPROCESSABLE_ENTITY,
            CardError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn message(&self) -> String {
        match self {
            CardError::BadRequest(m) => format!("参数错误: {}", m),
            CardError::InProgress => "该词正在生成中，请稍后重试".to_string(),
            CardError::Upstream(m) => format!("内容生成失败，请稍后重试（{}）", m),
            CardError::Gate(m) => format!("生成内容未通过校验: {}", m),
            CardError::Internal(m) => format!("服务内部错误: {}", m),
        }
    }
}

/// 一次调用的结果。
pub struct GenResult {
    pub card: serde_json::Value,
    /// 是否来自缓存（`true` = 本次**没有**调 LLM）
    pub from_cache: bool,
    pub hit_count: i64,
}

// ── in-flight 去重（防止多用户同时查同一新词时重复调 LLM）────────────────
//
// L0 §4.3 明确要求：`brainstorm` 冷启动时 10 个用户同时查 → **不能生成 10 次**。
// 实现：进程内一个 `HashSet<String>` 记录「正在生成的词」；
//      后来的请求看到标记 → 轮询等缓存（最多 8s）→ 拿到就返回，拿不到就 503。

fn inflight() -> &'static StdMutex<HashSet<String>> {
    static S: OnceLock<StdMutex<HashSet<String>>> = OnceLock::new();
    S.get_or_init(|| StdMutex::new(HashSet::new()))
}

struct InflightGuard(String);
impl InflightGuard {
    fn acquire(word: &str) -> Option<Self> {
        let mut set = inflight().lock().unwrap_or_else(|e| e.into_inner());
        if set.contains(word) {
            None
        } else {
            set.insert(word.to_string());
            Some(InflightGuard(word.to_string()))
        }
    }
}
impl Drop for InflightGuard {
    fn drop(&mut self) {
        if let Ok(mut set) = inflight().lock() {
            set.remove(&self.0);
        }
    }
}

// ── prompt 加载（单一来源文件）────────────────────────────────────────

/// prompt 目录 —— 与 `main.rs` 里 `chat_engine::prompt_loader::init` 用的是同一个环境变量。
fn prompts_dir() -> String {
    std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string())
}

/// 读契约 prompt（**进程内缓存一次**）。
pub fn prompt() -> Result<&'static str, CardError> {
    static P: OnceLock<String> = OnceLock::new();
    if let Some(p) = P.get() {
        return Ok(p.as_str());
    }
    let path = format!("{}/{}", prompts_dir(), PROMPT_FILE);
    let s = std::fs::read_to_string(&path)
        .map_err(|e| CardError::Internal(format!("读契约 prompt 失败 {}: {}", path, e)))?;
    if s.trim().is_empty() {
        return Err(CardError::Internal(format!("契约 prompt 文件为空: {}", path)));
    }
    let _ = P.set(s);
    Ok(P.get().map(|s| s.as_str()).unwrap_or(""))
}

/// 拼出给 LLM 的 prompt（`{word}` 替换）。
///
/// 🔑 用 `replace` 而非格式化 —— 避免 prompt 里其它 `{}` 被误解析。
fn build_prompt(prompt_tpl: &str, word: &str) -> String {
    prompt_tpl.replace("{word}", word)
}

// ── 校验闸门（在线准入）──────────────────────────────────────────────

/// 是否含**完整**的 `/.../`（至少一对斜杠且中间非空）。
///
/// 🔴 防的是 `S1` 那类残缺：`/ˈ`、`/`、空 —— 实测 26 条卡栽在这。
fn has_full_ipa(s: &str) -> bool {
    let b: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < b.len() {
        if b[i] == '/' {
            if let Some(j) = b[i + 1..].iter().position(|&c| c == '/') {
                if j > 0 {
                    return true;
                }
                i += 2;
                continue;
            }
            break;
        }
        i += 1;
    }
    false
}

/// 分词（小写 + 只留字母与撇号）—— 与 Python 侧判据同精神。
fn tokens(text: &str) -> HashSet<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|t| !t.is_empty())
        .map(|t| t.to_string())
        .collect()
}

/// 规则变形（只做最常见的几类）。
///
/// ⚠️ **已知边界**：不规则变形（`buried`/`shrank`/`went`）**不在**这里。
/// 但 R2 的语义是「以**该词自身**的规则变体检查」，而在线路径生成的是**该词**的例句，
/// 出现不规则变形的概率低；且**离线扫描器**（`verify_card_field_consistency.py`，
/// 带不规则表）会在**回流时**再兜一道。→ 双保险。
fn regular_forms(w: &str) -> Vec<String> {
    let mut v = vec![format!("{}s", w), format!("{}ed", w), format!("{}ing", w)];
    if let Some(stem) = w.strip_suffix('e') {
        v.push(format!("{}ing", stem));
        v.push(format!("{}d", w));
    }
    if let Some(stem) = w.strip_suffix('y') {
        if !stem.is_empty() {
            v.push(format!("{}ies", stem));
            v.push(format!("{}ied", stem));
        }
    }
    if w.ends_with("s") || w.ends_with("x") || w.ends_with("ch") || w.ends_with("sh") {
        v.push(format!("{}es", w));
    }
    v
}

/// 例句是否含该词（精确或规则变形）。
fn context_contains_word(text: &str, word: &str) -> bool {
    let toks = tokens(text);
    let w = word.to_lowercase();
    if toks.contains(&w) {
        return true;
    }
    regular_forms(&w).iter().any(|f| toks.contains(f))
}

/// **客观闸门** —— 生成结果准入（不过则**不写缓存**）。
///
/// 🔑 只做**机械可判、无歧义**的四条（对应离线扫描器 S1/S4 的核心）：
///   1. `ipa` 非空且含完整 `/.../`
///   2. `definition.en` / `definition.zh` 非空
///   3. `context` 非空且**含该词**（或规则变形）
///   4. `entry_type` 非空
///
/// ⚠️ **不做**：语义正确性 / 合规扫描 / 词源真实性 —— 那些要么需 LLM 判断，
///    要么属于 `scan_compliance.py` 的职责（**合规扫描是上线的硬前提**，见模块注释）。
pub fn gate(card: &serde_json::Value, spelling: &str) -> Result<(), String> {
    let ipa = card.get("ipa").and_then(|v| v.as_str()).unwrap_or("");
    if ipa.trim().is_empty() {
        return Err("ipa 为空".to_string());
    }
    if !has_full_ipa(ipa) {
        return Err(format!("ipa 格式不完整（无完整 /.../）: {}", ipa));
    }

    let def = card.get("definition").ok_or_else(|| "缺 definition".to_string())?;
    let en = def.get("en").and_then(|v| v.as_str()).unwrap_or("");
    let zh = def.get("zh").and_then(|v| v.as_str()).unwrap_or("");
    if en.trim().is_empty() {
        return Err("definition.en 为空".to_string());
    }
    if zh.trim().is_empty() {
        return Err("definition.zh 为空".to_string());
    }

    let ctx = card.get("context").and_then(|v| v.as_str()).unwrap_or("");
    if ctx.trim().is_empty() {
        return Err("context 为空".to_string());
    }
    if !context_contains_word(ctx, spelling) {
        return Err(format!("例句不含该词: {}", ctx));
    }

    let et = card.get("entry_type").and_then(|v| v.as_str()).unwrap_or("");
    if et.trim().is_empty() {
        return Err("entry_type 为空".to_string());
    }

    Ok(())
}

// ── 缓存读写 ────────────────────────────────────────────────────────

/// 读缓存。返回 `(card_json, hit_count)`。
fn read_cache(conn: &Connection, spelling: &str) -> Result<Option<(String, i64)>, CardError> {
    let mut st = conn
        .prepare("SELECT card_content, hit_count FROM generated_card_cache WHERE spelling = ?1")
        .map_err(|e| CardError::Internal(format!("prepare: {}", e)))?;
    let mut rows = st
        .query(rusqlite::params![spelling])
        .map_err(|e| CardError::Internal(format!("query: {}", e)))?;
    match rows.next() {
        Ok(Some(r)) => {
            let c: String = r.get(0).map_err(|e| CardError::Internal(e.to_string()))?;
            let h: i64 = r.get(1).map_err(|e| CardError::Internal(e.to_string()))?;
            if c.trim().is_empty() {
                return Ok(None);   // 🔴 空内容当作未命中（避免把空卡片发给用户）
            }
            Ok(Some((c, h)))
        }
        Ok(None) => Ok(None),
        Err(e) => Err(CardError::Internal(format!("row: {}", e))),
    }
}

/// 记一次命中：`hit_count += 1`，并在带 `device_id` 时登记（用于算 distinct）。
fn bump_hit(conn: &Connection, spelling: &str, device_id: Option<&str>) -> Result<i64, CardError> {
    if let Some(did) = device_id {
        if !did.trim().is_empty() {
            conn.execute(
                "INSERT INTO generated_card_hit (spelling, device_id, first_hit_at, hit_count) \
                 VALUES (?1, ?2, datetime('now'), 1) \
                 ON CONFLICT(spelling, device_id) DO UPDATE SET hit_count = hit_count + 1",
                rusqlite::params![spelling, did],
            )
            .map_err(|e| CardError::Internal(format!("hit insert: {}", e)))?;
        }
    }
    conn.execute(
        "UPDATE generated_card_cache \
         SET hit_count = hit_count + 1, updated_at = datetime('now') \
         WHERE spelling = ?1",
        rusqlite::params![spelling],
    )
    .map_err(|e| CardError::Internal(format!("bump: {}", e)))?;

    // distinct = 该词的 hit 行数（PK 已保证设备去重）
    let distinct: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM generated_card_hit WHERE spelling = ?1",
            rusqlite::params![spelling],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let _ = conn.execute(
        "UPDATE generated_card_cache SET distinct_user_count = ?2 WHERE spelling = ?1",
        rusqlite::params![spelling, distinct],
    );
    conn.query_row(
        "SELECT hit_count FROM generated_card_cache WHERE spelling = ?1",
        rusqlite::params![spelling],
        |r| r.get(0),
    )
    .map_err(|e| CardError::Internal(format!("re-read hit: {}", e)))
}

/// 写缓存（**`INSERT OR IGNORE`** → 并发时以先写入者为准，不覆盖）。
fn write_cache(conn: &Connection, spelling: &str, card_json: &str) -> Result<(), CardError> {
    conn.execute(
        "INSERT OR IGNORE INTO generated_card_cache \
         (spelling, card_content, contract_version, source, hit_count, distinct_user_count, created_at, updated_at) \
         VALUES (?1, ?2, ?3, 'llm-online', 0, 0, datetime('now'), datetime('now'))",
        rusqlite::params![spelling, card_json, CONTRACT_VERSION],
    )
    .map_err(|e| CardError::Internal(format!("cache insert: {}", e)))?;
    Ok(())
}

// ── 主流程 ──────────────────────────────────────────────────────────

/// 取缓存（**连接用完即释放**）。
///
/// 🔑 为什么不把 `&Connection` 一路传下去：LLM 调用要 **3–5 秒**，
///    期间若持有池中连接，高并发时会**耗尽连接池**（池上限 30）。
///    → 每个 DB 动作各自取/放连接，**await 期间不持有连接**。
fn try_cache(word: &str, device_id: Option<&str>) -> Result<Option<GenResult>, CardError> {
    let conn = crate::db_pool::get_conn();
    if let Some((content, _)) = read_cache(&conn, word)? {
        let card: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| CardError::Internal(format!("缓存内容不是合法 JSON: {}", e)))?;
        let hits = bump_hit(&conn, word, device_id)?;
        return Ok(Some(GenResult { card, from_cache: true, hit_count: hits }));
    }
    Ok(None)
}

/// 取缓存或生成。
///
/// 顺序（L0 §4.1 的数据流）：
/// ```text
/// ① 查全局缓存 → 命中 → hit_count++ → 返回（0 次 LLM）
/// ② 未命中 → 抢 in-flight 标记
///      · 抢到 → 读 prompt → LLM → 解析 → 闸门 → 写缓存 → 返回
///      · 没抢到 → 轮询等缓存（≤8s）→ 拿到返回；超时 → 503
/// ```
pub async fn get_or_generate(
    spelling: &str,
    device_id: Option<&str>,
) -> Result<GenResult, CardError> {
    let word = normalize(spelling);
    validate_spelling(&word)?;

    // ① 缓存
    if let Some(r) = try_cache(&word, device_id)? {
        tracing::info!("generate_card: cache HIT spelling={} hits={}", word, r.hit_count);
        return Ok(r);
    }

    // ② 抢生成权
    let _guard = match InflightGuard::acquire(&word) {
        Some(g) => g,
        None => {
            // 别人在生成 → 等缓存（每次循环重新取连接，避免跨 await 持有）
            tracing::info!("generate_card: wait in-flight spelling={}", word);
            let t0 = Instant::now();
            while t0.elapsed() < WAIT_TIMEOUT {
                tokio::time::sleep(WAIT_POLL).await;
                if let Some(r) = try_cache(&word, device_id)? {
                    return Ok(r);
                }
            }
            return Err(CardError::InProgress);
        }
    };

    // ③ 生成（**此处不持有任何 DB 连接**）
    let tpl = prompt()?;
    let content = build_prompt(tpl, &word);
    tracing::info!("generate_card: MISS → LLM spelling={} prompt_chars={}", word, content.len());

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .map_err(|_| CardError::Internal("DEEPSEEK_API_KEY 未配置".to_string()))?;

    let cfg = chat_engine::llm_caller::LlmConfig {
        api_key,
        base_url: "https://api.deepseek.com".to_string(),
        model: MODEL.to_string(),
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
    };
    let mut caller = chat_engine::llm_caller::LlmCaller::new(cfg);

    // 🔑 空 system + prompt 全文作为 user → 与 Python (`messages:[{role:user,...}]`) 一致
    let reply = caller
        .generate_with_extra("", &content, &extra_params())
        .await
        .map_err(|e| CardError::Upstream(format!("{:?}", e)))?;

    let card: serde_json::Value = serde_json::from_str(reply.trim())
        .map_err(|e| CardError::Upstream(format!("返回不是合法 JSON: {} ({})", e, preview(&reply))))?;

    // ④ 闸门（不过 → 不写缓存）
    if let Err(why) = gate(&card, &word) {
        tracing::warn!("generate_card: GATE REJECT spelling={} reason={}", word, why);
        return Err(CardError::Gate(why));
    }

    // ⑤ 写缓存
    let card_json = serde_json::to_string(&card)
        .map_err(|e| CardError::Internal(format!("serialize: {}", e)))?;
    {
        let conn = crate::db_pool::get_conn();
        write_cache(&conn, &word, &card_json)?;
    }
    tracing::info!("generate_card: stored spelling={} bytes={}", word, card_json.len());

    Ok(GenResult { card, from_cache: false, hit_count: 0 })
}

/// 归一化：去空白 + 小写（与表上的 `COLLATE NOCASE` 呼应）。
fn normalize(s: &str) -> String {
    s.trim().to_lowercase()
}

/// 参数校验。
fn validate_spelling(w: &str) -> Result<(), CardError> {
    if w.is_empty() {
        return Err(CardError::BadRequest("spelling 不能为空".to_string()));
    }
    if w.chars().count() > MAX_SPELLING_LEN {
        return Err(CardError::BadRequest(format!(
            "spelling 过长（>{})",
            MAX_SPELLING_LEN
        )));
    }
    // 只接受「字母 / 空格 / 连字符 / 撇号 / 句点」—— 挡掉明显异常的输入
    if !w
        .chars()
        .all(|c| c.is_ascii_alphabetic() || c == ' ' || c == '-' || c == '\'' || c == '.')
    {
        return Err(CardError::BadRequest(
            "spelling 含不支持字符（只允许英文字母/空格/-/'/.）".to_string(),
        ));
    }
    Ok(())
}

fn preview(s: &str) -> String {
    s.chars().take(120).collect()
}

// ── 单元测试 ────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipa_full_detection() {
        assert!(has_full_ipa("/ˈhæpi/"));
        assert!(has_full_ipa("/ˈbʌs ˌstɒp/"));
        assert!(!has_full_ipa("/ˈ"));          // S1 残缺
        assert!(!has_full_ipa("/"));
        assert!(!has_full_ipa(""));
        assert!(!has_full_ipa("hæpi"));
    }

    #[test]
    fn context_word_check() {
        assert!(context_contains_word("I am happy to see you.", "happy"));
        assert!(context_contains_word("She runs fast.", "run"));        // 规则变形
        assert!(context_contains_word("They are making it.", "make"));  // e→ing
        assert!(!context_contains_word("I am happy to see you.", "sad"));
        assert!(!context_contains_word("", "any"));
    }

    #[test]
    fn gate_rejects_bad_cards() {
        let good = serde_json::json!({
            "ipa": "/ˈhæpi/",
            "definition": {"en": "feeling pleasure", "zh": "高兴的"},
            "context": "I am happy to see you.",
            "entry_type": "word"
        });
        assert!(gate(&good, "happy").is_ok());

        let no_ipa = serde_json::json!({
            "ipa": "/ˈ", "definition": {"en": "x", "zh": "x"},
            "context": "I am happy.", "entry_type": "word"
        });
        assert!(gate(&no_ipa, "happy").is_err());

        let ctx_miss = serde_json::json!({
            "ipa": "/ˈhæpi/", "definition": {"en": "x", "zh": "x"},
            "context": "I am glad.", "entry_type": "word"
        });
        assert!(gate(&ctx_miss, "happy").is_err());
    }

    #[test]
    fn spelling_validation() {
        assert!(validate_spelling("hong kong").is_ok());
        assert!(validate_spelling("t-shirt").is_ok());
        assert!(validate_spelling("").is_err());
        assert!(validate_spelling("a".repeat(100).as_str()).is_err());
        assert!(validate_spelling("bad!word").is_err());
    }

    #[test]
    fn prompt_placeholder_replace() {
        assert_eq!(build_prompt("word is {word}!", "cat"), "word is cat!");
    }
}
