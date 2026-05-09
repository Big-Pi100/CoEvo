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

    for (id, entry) in catalog.iter() {
        let id_lower = id.to_lowercase();

        // 单次词: 精确匹配
        if !id_lower.contains(' ') && !id_lower.contains('_') {
            if word_set.contains(id_lower.as_str()) {
                found.push(WordMatch {
                    word: id.clone(),
                    difficulty: entry.difficulty_level.unwrap_or(1),
                    domain: entry.domain.clone().unwrap_or_else(|| "general".into()),
                    definition: entry.definition.clone().unwrap_or_default(),
                });
                continue;
            }
        }

        // 多词/复合词
        let normalized = id_lower.replace('_', " ").replace('-', " ");
        let parts: Vec<&str> = normalized.split(' ').collect();
        if parts.len() >= 2 {
            if words.windows(parts.len()).any(|window| {
                window.iter().zip(parts.iter()).all(|(w, p)| w.as_str() == *p)
            }) {
                found.push(WordMatch {
                    word: id.clone(),
                    difficulty: entry.difficulty_level.unwrap_or(1),
                    domain: entry.domain.clone().unwrap_or_else(|| "general".into()),
                    definition: entry.definition.clone().unwrap_or_default(),
                });
            }
        }
    }

    // 去重 + 按难度降序
    found.sort_by(|a, b| b.difficulty.cmp(&a.difficulty));
    found.dedup_by(|a, b| a.word == b.word);
    found.truncate(10);
    found
}
