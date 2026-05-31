//! 词库：从 cefr_catalog.json 加载，提供文本匹配
//!
//! 启动时一次性加载 ~10 万词的 JSON，存入 HashMap
//! 运行时 O(n) 扫描文本找出词库中存在的单词

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;
use serde::Deserialize;

static WORD_BANK: OnceLock<HashMap<String, CefrEntry>> = OnceLock::new();

#[derive(Debug, Clone, Deserialize)]
pub struct CefrEntry {
    pub pos: Option<String>,
    pub domain: Option<String>,
    pub difficulty_level: Option<u32>,
    pub definition: Option<String>,
    pub cefr_level: Option<String>,
    pub ipa: Option<String>,
}

/// 初始化: 从 cefr_catalog.json 加载词库
pub fn init(path: &str) {
    let content = std::fs::read_to_string(path)
        .unwrap_or_else(|e| {
            tracing::warn!("Cannot read word bank {}: {} (vocab matching disabled)", path, e);
            String::new()
        });

    if content.is_empty() {
        let _ = WORD_BANK.set(HashMap::new());
        return;
    }

    let raw: HashMap<String, serde_json::Value> = match serde_json::from_str(&content) {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("Word bank JSON parse error: {} (vocab matching disabled)", e);
            let _ = WORD_BANK.set(HashMap::new());
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

    tracing::info!("Word bank loaded: {} words", catalog.len());
    let _ = WORD_BANK.set(catalog);
}

/// 词库是否可用
pub fn is_loaded() -> bool {
    WORD_BANK.get().map(|m| !m.is_empty()).unwrap_or(false)
}

/// 词库匹配结果
#[derive(Debug, Clone)]
pub struct WordMatch {
    pub word: String,
    pub difficulty: u32,
    pub domain: String,
    pub definition: String,
    pub cefr_level: Option<String>,
    pub ipa: Option<String>,
}

/// 从文本中扫描出词库中存在的单词
///
/// 返回按难度降序排列，最多 10 个
pub fn match_text(text: &str) -> Vec<WordMatch> {
    let catalog = match WORD_BANK.get() {
        Some(c) => c,
        None => return vec![],
    };
    if text.is_empty() || catalog.is_empty() {
        return vec![];
    }

    let text_lower = text.to_lowercase();
    // 只提取英文字母单词（排除 CJK 等非拉丁字符干扰）
    let words: Vec<String> = text_lower
        .split(|c: char| c != '\'' && !c.is_ascii_lowercase())
        .filter(|w| !w.is_empty() && w.len() >= 2)
        .map(String::from)
        .collect();
    let word_set: HashSet<String> = words.iter().cloned().collect();

    let mut found: Vec<WordMatch> = Vec::new();

    // Pre-compute n-gram set for multi-word lookup — O(n) instead of O(n×m)
    let mut phrase_set: HashSet<String> = HashSet::new();
    for i in 0..words.len() {
        for len in 2..=5 {
            // phrases of 2-5 words
            if i + len <= words.len() {
                phrase_set.insert(words[i..i + len].join(" "));
            }
        }
    }

    for (id, entry) in catalog.iter() {
        let id_lower = id.to_lowercase();

        // 单次词: 精确匹配
        if !id_lower.contains(' ') && !id_lower.contains('_')
            && word_set.contains(id_lower.as_str()) {
                found.push(WordMatch {
                    word: id.clone(),
                    difficulty: entry.difficulty_level.unwrap_or(1),
                    domain: entry.domain.clone().unwrap_or_else(|| "general".into()),
                    definition: entry.definition.clone().unwrap_or_default(),
                    cefr_level: entry.cefr_level.clone(),
                    ipa: entry.ipa.clone(),
                });
                continue;
            }

        // 多词/复合词 — 使用预计算的 phrase_set 进行 O(1) 查找
        let normalized = id_lower.replace(['_', '-'], " ");
        let parts: Vec<&str> = normalized.split(' ').collect();
        if parts.len() >= 2
            && phrase_set.contains(&normalized) {
                found.push(WordMatch {
                    word: id.clone(),
                    difficulty: entry.difficulty_level.unwrap_or(1),
                    domain: entry.domain.clone().unwrap_or_else(|| "general".into()),
                    definition: entry.definition.clone().unwrap_or_default(),
                    cefr_level: entry.cefr_level.clone(),
                    ipa: entry.ipa.clone(),
                });
            }
    }

    // 去重 + 按难度降序
    found.sort_by_key(|a| std::cmp::Reverse(a.difficulty));
    found.dedup_by(|a, b| a.word == b.word);
    found.truncate(10);
    found
}

/// 查询单个词的 CEFR 等级
pub fn lookup_cefr(word: &str) -> Option<String> {
    WORD_BANK.get()?.get(word).and_then(|e| e.cefr_level.clone())
}

/// CEFR 等级统计
#[derive(Debug, Clone, serde::Serialize)]
pub struct CefrCatalogStat {
    pub level: String,
    pub total: u64,
}

/// 获取词库中各 CEFR 等级的词汇总数
pub fn get_cefr_catalog_stats() -> Vec<CefrCatalogStat> {
    let catalog = match WORD_BANK.get() {
        Some(c) => c,
        None => return vec![],
    };
    let mut counts: HashMap<&str, u64> = HashMap::new();
    for entry in catalog.values() {
        if let Some(ref level) = entry.cefr_level {
            *counts.entry(level).or_insert(0) += 1;
        }
    }
    let mut stats: Vec<CefrCatalogStat> = counts.into_iter()
        .map(|(level, total)| CefrCatalogStat { level: level.to_string(), total })
        .collect();
    // Sort by CEFR order: A1, A2, B1, B2, C1, C2
    let order = |l: &str| -> usize { match l { "A1" => 0, "A2" => 1, "B1" => 2, "B2" => 3, "C1" => 4, "C2" => 5, _ => 6 } };
    stats.sort_by_key(|s| order(&s.level));
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup_word_bank(words: &[(&str, u32)]) {
        let mut catalog: HashMap<String, serde_json::Value> = HashMap::new();
        for (word, level) in words {
            catalog.insert(word.to_string(), serde_json::json!({
                "difficulty_level": level,
                "domain": "test",
                "definition": "A test word"
            }));
        }
        let json = serde_json::to_string(&catalog).unwrap();
        let dir = std::env::temp_dir();
        let path = dir.join(format!("word_bank_test_{}.json", std::process::id()));
        std::fs::write(&path, json).unwrap();
        init(path.to_str().unwrap());
    }

    /// Combined test — OnceLock global can only be initialized once per process.
    #[test]
    fn test_word_bank_matching() {
        setup_word_bank(&[
            ("algorithm", 3),
            ("data", 1),
            ("machine learning", 4),
            ("deep learning", 5),
            ("look_up", 2),
            ("neural network", 4),
        ]);

        // Single word matching
        let matches1 = match_text("The algorithm and data structures are important");
        let words1: Vec<&str> = matches1.iter().map(|m| m.word.as_str()).collect();
        assert!(words1.contains(&"algorithm"));
        assert!(words1.contains(&"data"));

        // Multi-word matching using optimized phrase_set
        let matches2 = match_text("I am studying machine learning and deep learning with neural network");
        let words2: Vec<&str> = matches2.iter().map(|m| m.word.as_str()).collect();
        assert!(words2.contains(&"machine learning"));
        assert!(words2.contains(&"deep learning"));
        assert!(words2.contains(&"neural network"));
        // Sorted by difficulty descending
        assert_eq!(matches2[0].word, "deep learning");

        // Compound word with underscore
        let matches3 = match_text("Please look up this word");
        let words3: Vec<&str> = matches3.iter().map(|m| m.word.as_str()).collect();
        assert!(words3.contains(&"look_up"));

        // Truncation to 10 results
        assert!(matches2.len() <= 10);

        // Empty text should return empty
        let matches4 = match_text("");
        assert!(matches4.is_empty());
    }
}
