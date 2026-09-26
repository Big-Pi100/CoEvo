//! 词库：从 cefr_catalog.json 加载，提供 CEFR 等级查询
//!
//! 启动时一次性加载 ~4.2 万词的 JSON，存入 HashMap。
//! 运行时查询为 O(1)。
//!
//! ## 2026-09-26 清理
//!
//! 1. **删除 `match_text()` + `WordMatch`** —— 0 个调用点（死代码）。
//!    它做的是 O(N) 全表扫（N = 41,574），曾被文档误认为「划词性能瓶颈」，
//!    但**划词是端侧功能**（v1 §2.1「查词（词库内）离线可用」），不走后端。
//!    见 `docs/design/word-query-indexing-audit-2026-09-26.md`。
//! 2. **`get_cefr_catalog_stats()` 改为启动时预计算** —— 该结果**只依赖
//!    启动时加载的 JSON，运行期不变**，但原先每次请求都全遍历 41,574 条
//!    （「我的」页面加载即触发）。
//!
//! ## ⚠️ 与端侧词库的关系
//!
//! 本模块加载的 `cefr_catalog.json`（**41,574 条**）与端侧 `word.db`（**11,523 词**）
//! 是**两个不同抽象层级**的东西：
//!
//! | | `cefr_catalog.json` | `word.db` |
//! |---|---|---|
//! | 单位 | **表面词形**（surface form） | **词元**（lemma） |
//! | 来源 | CEFR-J + Brown 语料 | 清洗 + LLM 补内容后的学习条目 |
//! | 变形 | 各算一条（`is`/`was`/`been` 分开） | 归一到原形（存 `word_form`） |
//!
//! 新设计里端侧才是权威词库；本模块**目前仍服务于 `/api/user/{id}/profile`
//! 的 `cefr_stats`**（用户已掌握的词按等级统计）。该接口将来若改走端侧数据，
//! 本模块可整体删除。

use std::collections::HashMap;
use std::sync::OnceLock;
use serde::Deserialize;

static WORD_BANK: OnceLock<HashMap<String, CefrEntry>> = OnceLock::new();
/// CEFR 等级统计 —— 启动时算一次（结果完全静态）
static CEFR_STATS: OnceLock<Vec<CefrCatalogStat>> = OnceLock::new();

#[derive(Debug, Clone, Deserialize)]
pub struct CefrEntry {
    pub pos: Option<String>,
    pub domain: Option<String>,
    pub difficulty_level: Option<u32>,
    pub definition: Option<String>,
    pub cefr_level: Option<String>,
    pub ipa: Option<String>,
}

/// CEFR 等级统计（单行）
#[derive(Debug, Clone, serde::Serialize)]
pub struct CefrCatalogStat {
    pub level: String,
    pub total: u64,
}

/// CEFR 等级顺序：A1, A2, B1, B2, C1, C2，其余排最后
fn level_order(l: &str) -> usize {
    match l {
        "A1" => 0,
        "A2" => 1,
        "B1" => 2,
        "B2" => 3,
        "C1" => 4,
        "C2" => 5,
        _ => 6,
    }
}

/// 从词库统计各 CEFR 等级的词数（供 `init` 一次性调用）
fn compute_stats(catalog: &HashMap<String, CefrEntry>) -> Vec<CefrCatalogStat> {
    let mut counts: HashMap<&str, u64> = HashMap::new();
    for entry in catalog.values() {
        if let Some(ref level) = entry.cefr_level {
            *counts.entry(level.as_str()).or_insert(0) += 1;
        }
    }
    let mut stats: Vec<CefrCatalogStat> = counts
        .into_iter()
        .map(|(level, total)| CefrCatalogStat {
            level: level.to_string(),
            total,
        })
        .collect();
    stats.sort_by_key(|s| level_order(&s.level));
    stats
}

/// 初始化: 从 cefr_catalog.json 加载词库，并预计算 CEFR 统计
pub fn init(path: &str) {
    let content = std::fs::read_to_string(path).unwrap_or_else(|e| {
        tracing::warn!("Cannot read word bank {}: {} (vocab matching disabled)", path, e);
        String::new()
    });

    if content.is_empty() {
        let _ = WORD_BANK.set(HashMap::new());
        let _ = CEFR_STATS.set(Vec::new());
        return;
    }

    let raw: HashMap<String, serde_json::Value> = match serde_json::from_str(&content) {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("Word bank JSON parse error: {} (vocab matching disabled)", e);
            let _ = WORD_BANK.set(HashMap::new());
            let _ = CEFR_STATS.set(Vec::new());
            return;
        }
    };

    let mut catalog = HashMap::with_capacity(raw.len());
    for (word, val) in raw {
        let entry = CefrEntry {
            pos: val.get("pos").and_then(|v| v.as_str()).map(String::from),
            domain: val.get("domain").and_then(|v| v.as_str()).map(String::from),
            difficulty_level: val.get("difficulty_level").and_then(|v| v.as_u64()).map(|v| v as u32),
            definition: val.get("definition").and_then(|v| v.as_str()).map(String::from),
            cefr_level: val.get("cefr_level").and_then(|v| v.as_str()).map(String::from),
            ipa: val.get("ipa").and_then(|v| v.as_str()).map(String::from),
        };
        catalog.insert(word, entry);
    }

    // ✅ 预计算统计 —— 原先每次请求都全遍历 41,574 条
    let stats = compute_stats(&catalog);
    tracing::info!(
        "Word bank loaded: {} words | CEFR levels: {}",
        catalog.len(),
        stats.len()
    );
    let _ = WORD_BANK.set(catalog);
    let _ = CEFR_STATS.set(stats);
}

/// 查询单个词的 CEFR 等级
pub fn lookup_cefr(word: &str) -> Option<String> {
    WORD_BANK.get()?.get(word).and_then(|e| e.cefr_level.clone())
}

/// 词库中各 CEFR 等级的词数（启动时已算好，O(1) 取用）
pub fn get_cefr_catalog_stats() -> Vec<CefrCatalogStat> {
    CEFR_STATS.get().cloned().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup_word_bank(words: &[(&str, u32, &str)]) {
        let mut catalog: HashMap<String, serde_json::Value> = HashMap::new();
        for (word, level, cefr) in words {
            catalog.insert(
                word.to_string(),
                serde_json::json!({
                    "difficulty_level": level,
                    "domain": "test",
                    "definition": "A test word",
                    "cefr_level": cefr,
                }),
            );
        }
        let json = serde_json::to_string(&catalog).unwrap();
        let dir = std::env::temp_dir();
        let path = dir.join(format!("word_bank_test_{}.json", std::process::id()));
        std::fs::write(&path, json).unwrap();
        init(path.to_str().unwrap());
    }

    /// Combined test — OnceLock global can only be initialized once per process.
    #[test]
    fn test_word_bank_lookup_and_stats() {
        setup_word_bank(&[
            ("data", 1, "A1"),
            ("algorithm", 3, "B1"),
            ("abandon", 3, "B1"),
            ("ubiquitous", 6, "C1"),
        ]);

        // ── lookup_cefr：O(1) 精确查询 ──
        assert_eq!(lookup_cefr("data").as_deref(), Some("A1"));
        assert_eq!(lookup_cefr("ubiquitous").as_deref(), Some("C1"));
        assert_eq!(lookup_cefr("not-in-bank"), None);

        // ── get_cefr_catalog_stats：预计算，按 CEFR 顺序排序 ──
        let stats = get_cefr_catalog_stats();
        let pairs: Vec<(&str, u64)> = stats.iter().map(|s| (s.level.as_str(), s.total)).collect();
        assert_eq!(pairs, vec![("A1", 1), ("B1", 2), ("C1", 1)]);

        // ── 统计是预计算的：重复调用结果一致且不重新遍历 ──
        assert_eq!(get_cefr_catalog_stats().len(), stats.len());
    }
}
