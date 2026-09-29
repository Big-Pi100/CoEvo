//! 内容合规闸门（在线制卡）—— 涉主权 / 涉政 / 涉黄暴 / 涉歧视
//!
//! # 为什么必须有这一步
//!
//! 预制词库的卡是**逐轮人工核查过**的（曾查出 `taiwan` / `tibet` 释义的涉主权错误，
//! 2026-09-26 已修，全库 P0 归零）。但**在线制卡（LLM 兜底）没有人工环节** ——
//! 一次 LLM 调用就能把违规内容直接返回给用户。
//! → 本模块是「按需生长」路线的**前置闸门**，位于 `llm_card::gate()` **之前**。
//!
//! # 与离线扫描器的关系：**词表共用，逻辑各写**
//!
//! | 侧 | 文件 | 词表来源 |
//! |---|---|---|
//! | 离线全库 | `scripts/scan_compliance.py` | 🔑 `backend/prompts/compliance_terms.json` |
//! | 在线闸门 | **本模块** | 🔑 同上（**同一份文件**） |
//!
//! 词表只有一处权威（`compliance_terms.json`），两侧都读它 → 加词只改一处。
//!
//! 🔴 但「词表一样」≠「判据一样」：Python 用 `re`，这里用 `regex` + 手写词边界，
//!   去重 / 字段口径都可能漂。→ 因此有**共享用例** `prompts/compliance_cases.json`：
//!   Python 用 `scripts/verify_compliance_parity.py` 跑，本模块用
//!   [`tests::compliance_cases_parity`] 跑**同一份**。两边都过 = 跨语言一致（构造保证）。
//!
//! # 五条铁律（首版踩坑后固化 · 详见扫描器 docstring）
//!
//! 1. **必须按词边界匹配** —— 裸子串会把 `grape`/`schooner` 判违规
//! 2. **敏感词条 ≠ 违规内容** —— 要看内容**怎么描述它**（标注了冒犯性？另有正常义？）
//! 3. **核心是组合判定** —— 敏感主体 × 主权类措辞**同字段**同现才升级
//! 4. **「独立王国」本身不是错的**，只有针对中国领土才错（`India became an independent nation` 是史实）
//! 5. **官方行政区划名 ≠ 主权主张** —— `autonomous region` 不得进主权措辞表
//!
//! # 与离线扫描的一点**有意不同**：扫的字段范围
//!
//! 离线扫描器只把 `card.sections[]` 里 `en/zh/text/source` 当正文（那是对 word.db 的**卡结构**）。
//! 在线卡的字段是**整张都给用户看的**，且字段随契约演进（v6 就新增了 ipa/definition/context）。
//! → 本模块**递归收集卡里所有字符串**，未知字段一律当正文（加 `.text` 后缀进规则 ④ 的扫描面）。
//!   🔑 宁可多扫不可漏扫：漏扫 = 违规内容直出用户，多扫最多多一条 P1。

use std::collections::HashSet;
use std::sync::OnceLock;

use serde::Deserialize;

/// 与 `scripts/scan_compliance.py` 读的**同一个文件**。
const TERMS_FILE: &str = "compliance_terms.json";

// ══════════════════════════════════════════════════════════════════
// 词表（结构与 `compliance_terms.json` 严格对应）
// ══════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
struct RawPattern {
    pattern: String,
    why: String,
}

#[derive(Deserialize)]
struct RawTerms {
    sovereign_subjects: Vec<String>,
    sovereign_claim_words: Vec<String>,
    strong_claim_words: Vec<String>,
    hard_block_with_subject: Vec<RawPattern>,
    hard_block_always: Vec<RawPattern>,
    political_subjects: Vec<String>,
    political_claim_words: Vec<String>,
    violence_sex_terms: Vec<String>,
    discrimination_terms: Vec<String>,
    slur_ack_terms: Vec<String>,
    neutral_sense_terms: Vec<String>,
}

/// 一个词条 + 它预编译好的匹配器。
pub struct Term {
    raw: String,
    /// 多词词条（含空格）→ 用 `\b` + `\s+` 的 regex（词间空白可伸缩）。
    /// 单词词条 → `None`，走 [`find_bounded`]（手写词边界，见该函数注释）。
    multi: Option<regex::Regex>,
}

impl Term {
    fn new(raw: &str) -> Result<Self, String> {
        let raw = raw.trim().to_string();
        if raw.is_empty() {
            return Err("合规词表含空词条".to_string());
        }
        let multi = if raw.contains(' ') {
            let joined = raw
                .split_whitespace()
                .map(regex::escape)
                .collect::<Vec<_>>()
                .join(r"\s+");
            let pat = format!(r"\b{}\b", joined);
            Some(
                regex::RegexBuilder::new(&pat)
                    .case_insensitive(true)
                    .build()
                    .map_err(|e| format!("合规词表正则编译失败 {:?}: {}", raw, e))?,
            )
        } else {
            None
        };
        Ok(Term { raw, multi })
    }

    pub fn raw(&self) -> &str {
        &self.raw
    }

    /// 在 `text` 中找到该词（**带词边界**）→ 返回**字节**起始位置。
    pub fn find(&self, text: &str) -> Option<usize> {
        match &self.multi {
            Some(re) => re.find(text).map(|m| m.start()),
            None => find_bounded(text, &self.raw),
        }
    }
}

/// 加载好的词表（全部词条已预编译）。
pub struct Terms {
    sovereign_subjects: Vec<Term>,
    sovereign_claim_words: Vec<Term>,
    strong_claim_words: HashSet<String>,
    hard_block_with_subject: Vec<(regex::Regex, String)>,
    hard_block_always: Vec<(regex::Regex, String)>,
    political_subjects: Vec<Term>,
    political_claim_words: Vec<Term>,
    violence_sex_terms: Vec<Term>,
    discrimination_terms: Vec<Term>,
    slur_ack_terms: Vec<Term>,
    neutral_sense_terms: Vec<Term>,
}

impl Terms {
    pub fn load_from_str(s: &str) -> Result<Self, String> {
        let raw: RawTerms = serde_json::from_str(s)
            .map_err(|e| format!("解析合规词表失败: {}", e))?;

        fn terms(v: &[String]) -> Result<Vec<Term>, String> {
            v.iter().map(|t| Term::new(t)).collect()
        }
        fn pats(v: &[RawPattern]) -> Result<Vec<(regex::Regex, String)>, String> {
            v.iter()
                .map(|p| {
                    let re = regex::RegexBuilder::new(&p.pattern)
                        .case_insensitive(true)
                        .build()
                        .map_err(|e| format!("合规词表正则编译失败 {:?}: {}", p.pattern, e))?;
                    Ok((re, p.why.clone()))
                })
                .collect()
        }

        Ok(Terms {
            sovereign_subjects: terms(&raw.sovereign_subjects)?,
            sovereign_claim_words: terms(&raw.sovereign_claim_words)?,
            strong_claim_words: raw
                .strong_claim_words
                .iter()
                .map(|s| s.to_lowercase())
                .collect(),
            hard_block_with_subject: pats(&raw.hard_block_with_subject)?,
            hard_block_always: pats(&raw.hard_block_always)?,
            political_subjects: terms(&raw.political_subjects)?,
            political_claim_words: terms(&raw.political_claim_words)?,
            violence_sex_terms: terms(&raw.violence_sex_terms)?,
            discrimination_terms: terms(&raw.discrimination_terms)?,
            slur_ack_terms: terms(&raw.slur_ack_terms)?,
            neutral_sense_terms: terms(&raw.neutral_sense_terms)?,
        })
    }

    pub fn load_from(path: &str) -> Result<Self, String> {
        let s = std::fs::read_to_string(path)
            .map_err(|e| format!("读合规词表失败 {}: {}", path, e))?;
        Self::load_from_str(&s)
    }
}

/// 词表文件路径 —— 与 [`crate::llm_card`] 读 prompt 用**同一个环境变量**。
fn terms_path() -> String {
    let dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    format!("{}/{}", dir, TERMS_FILE)
}

/// 进程内加载一次的词表。
///
/// 🔴 读不到 → **返回 Err，不降级**。合规闸门「读不到词表就放行」是
///    「静默失效 = 主要敌人」的教科书案例（闸门看起来在，实际不挡任何东西）。
pub fn terms() -> Result<&'static Terms, String> {
    static T: OnceLock<Terms> = OnceLock::new();
    if let Some(t) = T.get() {
        return Ok(t);
    }
    let t = Terms::load_from(&terms_path())?;
    let _ = T.set(t);
    Ok(T.get().expect("terms set"))
}

// ══════════════════════════════════════════════════════════════════
// 判据工具
// ══════════════════════════════════════════════════════════════════

/// **手写词边界匹配** —— 等价于 Python 的 `(?<![a-z])term(?![a-z])`（`re.I`）。
///
/// 🔑 为什么不用 `regex`：Rust 的 `regex` crate **不支持 lookaround**
///    （`(?<!...)` / `(?=...)` 都没有）。→ 单词词条自己扫。
///
/// 🔴 铁律 1：必须带边界 —— 裸子串会把 g**rape** / s**coon**er 判成违规。
fn find_bounded(text: &str, term: &str) -> Option<usize> {
    let tb = text.as_bytes();
    let nb = term.as_bytes();
    if nb.is_empty() || nb.len() > tb.len() {
        return None;
    }
    for i in 0..=(tb.len() - nb.len()) {
        if tb[i..i + nb.len()].eq_ignore_ascii_case(nb) {
            let before_ok = i == 0 || !tb[i - 1].is_ascii_alphabetic();
            let end = i + nb.len();
            let after_ok = end >= tb.len() || !tb[end].is_ascii_alphabetic();
            if before_ok && after_ok {
                return Some(i);
            }
        }
    }
    None
}

/// 列表里**第一个**命中的词（按**词表顺序**，不是位置顺序 —— 与 Python `_first_hit` 一致）。
fn first_hit<'a>(list: &'a [Term], text: &str) -> Option<(&'a str, usize)> {
    list.iter().find_map(|t| t.find(text).map(|p| (t.raw(), p)))
}

/// 列表里**所有**命中的词（每个词只取首次出现位置 —— 与 Python `_all_hits` 一致）。
fn all_hits<'a>(list: &'a [Term], text: &str) -> Vec<(&'a str, usize)> {
    list.iter()
        .filter_map(|t| t.find(text).map(|p| (t.raw(), p)))
        .collect()
}

/// 截取命中处的上下文（与 Python `_snip` 同口径：命中位置前 32 字符起、取 95 字符）。
fn snip(text: &str, pos_byte: usize) -> String {
    let pos_chars = text[..pos_byte.min(text.len())].chars().count();
    let a = pos_chars.saturating_sub(32);
    text.chars()
        .skip(a)
        .take(95)
        .collect::<String>()
        .replace('\n', " ")
        .trim()
        .to_string()
}

// ══════════════════════════════════════════════════════════════════
// 规则引擎
// ══════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    /// 明确违规 —— **不可上线**
    P0,
    /// 高风险，需人工复核
    P1,
    /// 提示（可能误报）
    P2,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::P0 => "P0",
            Level::P1 => "P1",
            Level::P2 => "P2",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub level: Level,
    pub category: &'static str,
    pub field: String,
    pub reason: String,
}

/// **规则引擎** —— 对 `(字段名, 文本)` 列表跑 5 条铁律。
///
/// 🔑 与 `scripts/scan_compliance.py::scan_parts` 是**同一套规则**（逐条对齐，含去重口径）。
///    跨语言一致性由共享用例保证 —— 见模块注释。
pub fn scan_parts(t: &Terms, parts: &[(String, String)], spelling: &str) -> Vec<Finding> {
    let spelling = spelling.trim().to_lowercase();
    let joined = parts
        .iter()
        .map(|(_, x)| x.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let acknowledged = t.slur_ack_terms.iter().any(|x| x.find(&joined).is_some());
    let neutral = t.neutral_sense_terms.iter().any(|x| x.find(&joined).is_some());

    // (level, category, field, snippet, reason)
    let mut found: Vec<(Level, &'static str, String, String, String)> = Vec::new();

    // ── ①a 无条件硬阻断（任何字段）──
    for (label, text) in parts {
        for (re, why) in &t.hard_block_always {
            if let Some(m) = re.find(text) {
                found.push((
                    Level::P0,
                    "涉主权",
                    label.clone(),
                    snip(text, m.start()),
                    why.clone(),
                ));
            }
        }
    }

    // ── ①b 需主体触发的硬阻断（🔴 铁律 4：**同字段内**必须出现中国领土主体）──
    for (label, text) in parts {
        if first_hit(&t.sovereign_subjects, text).is_none() {
            continue;
        }
        for (re, why) in &t.hard_block_with_subject {
            if let Some(m) = re.find(text) {
                found.push((
                    Level::P0,
                    "涉主权",
                    label.clone(),
                    snip(text, m.start()),
                    why.clone(),
                ));
            }
        }
    }

    // ── ② 敏感主体 × 主权类措辞（同字段内组合）──
    for (label, text) in parts {
        let Some((subj, _)) = first_hit(&t.sovereign_subjects, text) else {
            continue;
        };
        let Some((claim, cpos)) = first_hit(&t.sovereign_claim_words, text) else {
            continue;
        };
        let lvl = if t.strong_claim_words.contains(&claim.to_lowercase()) {
            Level::P0
        } else {
            Level::P1
        };
        found.push((
            lvl,
            "涉主权",
            label.clone(),
            snip(text, cpos),
            format!("领土主体「{}」与「{}」同现", subj, claim),
        ));
    }

    // ── ③ 涉政 ──
    for (label, text) in parts {
        let Some((subj, spos)) = first_hit(&t.political_subjects, text) else {
            continue;
        };
        let cls = first_hit(&t.political_claim_words, text);
        let lvl = if cls.is_some() { Level::P0 } else { Level::P1 };
        let reason = match cls {
            Some((c, _)) => format!("政治主体「{}」 + 定性词「{}」", subj, c),
            None => format!("政治主体「{}」（需人工复核）", subj),
        };
        found.push((lvl, "涉政", label.clone(), snip(text, spos), reason));
    }

    // ── ④ 涉黄暴 / 涉恐（🔴 铁律 2c：**词条本身就是该敏感词 → 跳过**）──
    //   `massacre`/`rape`/`terrorist` 的例句正是在**解释这个词本身**，是正确的词典行为。
    for (label, text) in parts {
        if !(label.ends_with(".en") || label.ends_with(".zh") || label.ends_with(".text")) {
            continue;
        }
        for (w, pos) in all_hits(&t.violence_sex_terms, text) {
            if w.to_lowercase() == spelling {
                continue;
            }
            found.push((
                Level::P1,
                "涉黄暴/涉恐",
                label.clone(),
                snip(text, pos),
                format!("敏感词「{}」（词条非该词）", w),
            ));
        }
    }

    // ── ⑤ 涉歧视 ──
    for (label, text) in parts {
        for (w, pos) in all_hits(&t.discrimination_terms, text) {
            let same_word = spelling == w.to_lowercase();
            // 🔑 铁律 2a：词条即该敏感词 + 明确标注冒犯性 → 正确的词典行为，不报
            if same_word && acknowledged {
                continue;
            }
            // 🔑 铁律 2b：该词另有正常义（retard=延缓）→ P2 待确认
            if neutral {
                found.push((
                    Level::P2,
                    "涉歧视",
                    label.clone(),
                    snip(text, pos),
                    format!("「{}」—— 但该词另有正常义，需人工确认语境", w),
                ));
                continue;
            }
            // 🔑 铁律 2d：词条即该词、但未标注冒犯性 → P1（收录正当，缺标注是缺陷）
            if same_word {
                found.push((
                    Level::P1,
                    "涉歧视",
                    label.clone(),
                    snip(text, pos),
                    format!("「{}」为敏感词但**未标注冒犯性** → 建议补标注", w),
                ));
                continue;
            }
            // 其余：敏感词出现在**别的词**的内容里且无标注 → P0
            found.push((
                Level::P0,
                "涉歧视",
                label.clone(),
                snip(text, pos),
                format!("歧视性词汇「{}」出现在非该词的内容中且未标注", w),
            ));
        }
    }

    // ── 去重：**同一字段的同一类别**只留一条（取最严重级别，原因合并）──
    //   实例：`tibet` 的定义同时命中 3 条涉主权规则 —— 同一个问题被描述 3 次，应合并为 1 条。
    //   ⚠️ 不能按 snippet 做键：snippet 从命中位置往前 32 字符起算，
    //      不同命中位置 → snippet 不同 → 同一句话会被当成多条。
    let mut best: Vec<(Level, &'static str, String, String, Vec<String>)> = Vec::new();
    for (lvl, cat, field, snip_s, reason) in found {
        if let Some(cur) = best.iter_mut().find(|c| c.1 == cat && c.2 == field) {
            if lvl < cur.0 {
                cur.0 = lvl;
            }
            if !cur.4.contains(&reason) {
                cur.4.push(reason);
            }
        } else {
            best.push((lvl, cat, field, snip_s, vec![reason]));
        }
    }
    best.into_iter()
        .map(|(level, category, field, snip_s, reasons)| Finding {
            level,
            category,
            field,
            reason: format!("{}｜{}", snip_s, reasons.join(" + ")),
        })
        .collect()
}

// ══════════════════════════════════════════════════════════════════
// 在线卡的形状适配
// ══════════════════════════════════════════════════════════════════

/// 递归收集卡里所有字符串，给出 `(字段名, 文本)`。
///
/// 🔑 字段名规则（为了让规则 ④ 的 `.en/.zh/.text` 扫描面覆盖到）：
///    · 路径本身已以 `.en`/`.zh`/`.text` 结尾 → 原样（如 `definition.en`）
///    · 顶层 `word` → `spelling`（与传入的 spelling 合流，去重后只留一个字段）
///    · **其余一律补 `.text`** —— 在线卡整张都给用户看，未知字段也不许漏扫
fn collect_parts(v: &serde_json::Value, path: &str, out: &mut Vec<(String, String)>) {
    match v {
        serde_json::Value::String(s) => {
            if s.trim().is_empty() {
                return;
            }
            let label = if path == "word" {
                "spelling".to_string()
            } else if path.ends_with(".en") || path.ends_with(".zh") || path.ends_with(".text") {
                path.to_string()
            } else {
                format!("{}.text", path)
            };
            out.push((label, s.clone()));
        }
        serde_json::Value::Array(a) => {
            for (i, x) in a.iter().enumerate() {
                let p = if path.is_empty() {
                    i.to_string()
                } else {
                    format!("{}.{}", path, i)
                };
                collect_parts(x, &p, out);
            }
        }
        serde_json::Value::Object(m) => {
            for (k, x) in m {
                let p = if path.is_empty() {
                    k.clone()
                } else {
                    format!("{}.{}", path, k)
                };
                collect_parts(x, &p, out);
            }
        }
        _ => {}
    }
}

/// 扫描一张**在线卡**（LLM 输出形状，见 `prompts/wordlib_contract.md`）。
pub fn scan_card(t: &Terms, card: &serde_json::Value, spelling: &str) -> Vec<Finding> {
    let mut parts: Vec<(String, String)> = vec![("spelling".to_string(), spelling.to_string())];
    collect_parts(card, "", &mut parts);
    scan_parts(t, &parts, spelling)
}

/// 合规判定结果。
#[derive(Debug)]
pub enum Verdict {
    /// 无 P0 → 放行
    Pass,
    /// 有 P0 → **不可上线**，附详细原因（调用方**不写缓存**）
    Violation(String),
}

/// 用**已加载**的词表判定（纯函数 · 便于测试）。
///
/// ⚠️ P1 / P2 **不阻断** —— 它们要人工复核，不该把用户挡在门外。
pub fn check_with(t: &Terms, card: &serde_json::Value, spelling: &str) -> Verdict {
    let p0: Vec<String> = scan_card(t, card, spelling)
        .into_iter()
        .filter(|f| f.level == Level::P0)
        .map(|f| format!("[{}] {} ({})", f.category, f.reason, f.field))
        .collect();
    if p0.is_empty() {
        Verdict::Pass
    } else {
        Verdict::Violation(p0.join("; "))
    }
}

/// **在线准入**。
///
/// 🔴 返回值分两层，**不能混**：
///    · `Ok(Verdict::Violation)` = 内容违规 → 调用方按「拒绝」处理（422，不重试）
///    · `Err(_)`               = **词表加载失败 / 内部错误** → 调用方必须按「服务故障」处理（500）
///
/// 为什么必须分开：若把 `Err` 也当成「违规」，那么一次**部署时漏了词表文件**
/// 会让**每个词**都返回「该词暂不支持生成」—— 把配置故障伪装成内容问题，
/// 排查时完全看不出真相。这正是「静默失效 = 主要敌人」。
pub fn check_card(card: &serde_json::Value, spelling: &str) -> Result<Verdict, String> {
    let t = terms()?;
    Ok(check_with(t, card, spelling))
}

// ══════════════════════════════════════════════════════════════════
// 测试
// ══════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 🔴 与 Python 跑**同一份**用例（`scripts/verify_compliance_parity.py`）。
    ///    两边都过 → 跨语言规则一致（由构造保证，不是人工比对）。
    const CASES: &str = include_str!("../../../prompts/compliance_cases.json");
    const TERMS_JSON: &str = include_str!("../../../prompts/compliance_terms.json");

    #[derive(Deserialize)]
    struct CasesDoc {
        cases: Vec<Case>,
        /// 「卡片 JSON → (字段名, 文本)」适配层的用例（第一条是 `_why` 说明，无 `id`）
        card_cases: Vec<serde_json::Value>,
    }
    #[derive(Deserialize)]
    struct Case {
        id: String,
        spelling: String,
        parts: Vec<(String, String)>,
        expect: Vec<(String, String, String)>,
    }
    #[derive(Deserialize)]
    struct CardCase {
        id: String,
        spelling: String,
        card: serde_json::Value,
        expect: Vec<(String, String, String)>,
    }

    fn triples(findings: &[Finding]) -> Vec<String> {
        let mut v: Vec<String> = findings
            .iter()
            .map(|f| format!("{}|{}|{}", f.level.as_str(), f.category, f.field))
            .collect();
        v.sort();
        v
    }

    fn expected_triples(c: &Case) -> Vec<String> {
        let mut v: Vec<String> = c
            .expect
            .iter()
            .map(|(l, cat, f)| format!("{}|{}|{}", l, cat, f))
            .collect();
        v.sort();
        v
    }

    #[test]
    fn compliance_cases_parity() {
        let t = Terms::load_from_str(TERMS_JSON).expect("词表应可加载");
        let doc: CasesDoc = serde_json::from_str(CASES).expect("用例文件应可解析");
        assert!(doc.cases.len() >= 20, "用例太少: {}", doc.cases.len());

        let mut fails = Vec::new();
        for c in &doc.cases {
            let got = triples(&scan_parts(&t, &c.parts, &c.spelling));
            let exp = expected_triples(c);
            if got != exp {
                fails.push(format!(
                    "  ✗ {}\n      输入 {:?} / spelling={:?}\n      期望 {:?}\n      实际 {:?}",
                    c.id, c.parts, c.spelling, exp, got
                ));
            }
        }
        assert!(
            fails.is_empty(),
            "{} 个合规用例不符：\n{}",
            fails.len(),
            fails.join("\n")
        );
    }

    /// 🔴 与 Python 跑**同一份** `card_cases`（`scripts/audit_generated_card_cache.py` 的
    ///    `selfcheck_card_cases`）。验的是「**卡片 JSON → (字段名, 文本)**」这一层适配 ——
    ///    适配错了 → 后续规则再准也白搭（扫错字段）。
    #[test]
    fn compliance_card_cases_parity() {
        let t = Terms::load_from_str(TERMS_JSON).expect("词表应可加载");
        let doc: CasesDoc = serde_json::from_str(CASES).expect("用例文件应可解析");

        let cases: Vec<CardCase> = doc
            .card_cases
            .iter()
            .filter(|v| v.get("id").is_some()) // 跳过 `_why` 说明项
            .map(|v| serde_json::from_value(v.clone()).expect("card_case 结构不对"))
            .collect();
        assert!(cases.len() >= 8, "card_cases 太少: {}", cases.len());

        let mut fails = Vec::new();
        for c in &cases {
            let got = triples(&scan_card(&t, &c.card, &c.spelling));
            let mut exp: Vec<String> = c
                .expect
                .iter()
                .map(|(l, cat, f)| format!("{}|{}|{}", l, cat, f))
                .collect();
            exp.sort();
            if got != exp {
                fails.push(format!(
                    "  ✗ {}\n      card {:?} / spelling={:?}\n      期望 {:?}\n      实际 {:?}",
                    c.id, c.card, c.spelling, exp, got
                ));
            }
        }
        assert!(
            fails.is_empty(),
            "{} 个 card_case 不符（卡适配层与 Python 不一致）：\n{}",
            fails.len(),
            fails.join("\n")
        );
    }

    #[test]
    fn boundary_matching_avoids_substring_false_positives() {
        // 🔴 铁律 1：这些词含 `rape` / `coon` 子串，但**不是**违规
        assert!(find_bounded("a bunch of grapes", "rape").is_none());
        assert!(find_bounded("he scraped the wall", "rape").is_none());
        assert!(find_bounded("a schooner sailed", "coon").is_none());
        assert!(find_bounded("the drapery hung", "rape").is_none());
        // 真的命中
        assert!(find_bounded("rape is a crime", "rape").is_some());
        assert!(find_bounded("a coon", "coon").is_some());
    }

    #[test]
    fn multiword_term_allows_flexible_whitespace() {
        let t = Term::new("hong kong").unwrap();
        assert!(t.find("Hong Kong is a city").is_some());
        assert!(t.find("Hong   Kong is a city").is_some()); // 词间空白可伸缩（对应 Python 的 \s+）
        assert!(t.find("Hongkong is a city").is_none()); // 无空格 → 不匹配（有独立词条另算）
    }

    #[test]
    fn terms_file_is_self_consistent() {
        let t = Terms::load_from_str(TERMS_JSON).unwrap();
        assert!(!t.sovereign_subjects.is_empty());
        assert!(!t.discrimination_terms.is_empty());
        // 强主权词必须是主权措辞的子集（否则 `_STRONG_CLAIM` 判定会落空）
        let claim: HashSet<String> =
            t.sovereign_claim_words.iter().map(|x| x.raw().to_string()).collect();
        for s in &t.strong_claim_words {
            assert!(claim.contains(s), "strong_claim_words 含非主权措辞: {}", s);
        }
        // 铁律 5：官方行政区划名**不得**进主权措辞表
        assert!(
            !claim.contains("autonomous region"),
            "`autonomous region` 是官方行政区划名，不得进主权措辞表"
        );
    }

    #[test]
    fn card_adapter_scans_unknown_fields() {
        let t = Terms::load_from_str(TERMS_JSON).unwrap();
        // 契约里没有的字段（模拟 LLM 多吐/契约升级）也必须被扫到
        let card = serde_json::json!({
            "word": "tibet",
            "definition": {"en": "Tibet was historically an independent kingdom.", "zh": "西藏"},
            "some_future_field": "It is a self-governing democracy."
        });
        let f = scan_card(&t, &card, "tibet");
        let got = triples(&f);
        assert!(
            got.iter().any(|x| x.contains("some_future_field")),
            "未知字段应被扫到: {:?}",
            got
        );
        assert!(got.iter().any(|x| x.contains("definition.en")));
    }

    #[test]
    fn check_with_rejects_violating_card_and_passes_clean_one() {
        let t = Terms::load_from_str(TERMS_JSON).unwrap();

        let bad = serde_json::json!({
            "word": "tibet",
            "definition": {"en": "Tibet was historically an independent kingdom.", "zh": "西藏"}
        });
        match check_with(&t, &bad, "tibet") {
            Verdict::Violation(m) => assert!(m.contains("涉主权"), "原因应指出涉主权: {}", m),
            Verdict::Pass => panic!("违规卡必须被拒"),
        }

        // 🔴 反向：正确表述（自治区）**不得**被拒 —— 否则闸门会误杀正常内容
        let ok = serde_json::json!({
            "word": "tibet",
            "definition": {"en": "An autonomous region in southwestern China", "zh": "西藏自治区"}
        });
        assert!(matches!(check_with(&t, &ok, "tibet"), Verdict::Pass));

        // 🔴 P1 / P2 不阻断
        let p1 = serde_json::json!({
            "word": "appall",
            "context": "The news of the massacre appalled the world."
        });
        assert!(
            matches!(check_with(&t, &p1, "appall"), Verdict::Pass),
            "P1 不该阻断（需人工复核，不是「不能给用户」）"
        );
    }

    #[test]
    fn missing_terms_file_is_err_not_violation() {
        // 🔴 词表加载失败必须是 Err（服务故障 = 500），
        //    **不能**被当成「合规违规」（422）—— 否则「部署漏了词表」会伪装成
        //    「每个词都不支持生成」，把配置故障变成内容问题。
        assert!(Terms::load_from("definitely/not/here/compliance_terms.json").is_err());
    }

    #[test]
    fn clean_card_passes() {
        let card = serde_json::json!({
            "word": "brainstorm",
            "entry_type": "word",
            "ipa": "/ˈbreɪnstɔːm/",
            "definition": {"pos": "[v]", "en": "to generate ideas", "zh": "头脑风暴"},
            "context": "Let's brainstorm some ideas for the new project.",
            "etymology": {"text": "brain + storm", "etyma": []},
            "collocations": [{"phrase": "brainstorm ideas", "zh": "头脑风暴"}]
        });
        let t = Terms::load_from_str(TERMS_JSON).unwrap();
        let f = scan_card(&t, &card, "brainstorm");
        assert!(f.iter().all(|x| x.level != Level::P0), "{:?}", triples(&f));
    }
}
