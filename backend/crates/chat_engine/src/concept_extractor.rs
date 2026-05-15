//! N2: 概念提取器
//!
//! 适配自 LinguaFlow conversation_engine/src/concept_extractor.rs
//!
//! 两层:
//!   1. 意图检测 (本地关键词)
//!   2. LLM 概念提取 / 直接制卡
//!
//! 输出: Vec<ConceptCandidate>

use crate::llm_caller::{LlmCaller, LlmConfig};
pub use shared_types::card::ConceptCandidate;
use shared_types::card::ExtractionResult;

/// 检测用户消息是否包含制卡意图
fn has_card_intent(message: &str) -> bool {
    let keywords = ["制卡", "记住", "做成卡片", "make card", "add to", "记住这个", "背下来"];
    let msg_lower = message.to_lowercase();
    keywords.iter().any(|k| msg_lower.contains(k))
}

/// N2: 从对话中提取候选概念
///
/// existing_fronts: 用户已有卡片的 front 列表 (全小写)
/// skipped_fronts: 用户跳过记录中的 front 列表 (全小写)
/// history: 最近 N 轮对话 (role, content)，注入 LLM prompt 以避免重复提取
///
/// 1. 检测制卡意图 → Path B2 (直接生成卡片)
/// 2. 否则 → LLM 提取候选概念 → 去重
pub async fn extract_concepts(
    _user_id: &str,
    user_message: &str,
    ai_reply: &str,
    existing_fronts: &[String],
    skipped_fronts: &[String],
    llm_config: &LlmConfig,
    history: &[(String, String)],
) -> ExtractionResult {
    if has_card_intent(user_message) {
        // Path B2: 直接制卡
        match generate_direct_card(llm_config, user_message, ai_reply).await {
            Some(card) => ExtractionResult {
                candidates: vec![card],
                direct_card: true,
            },
            None => ExtractionResult { candidates: vec![], direct_card: true },
        }
    } else {
        // 从 LLM 提取候选概念（传入已有概念 + 对话历史，避免重复）
        let all_existing: Vec<String> = existing_fronts.iter()
            .chain(skipped_fronts.iter())
            .cloned()
            .collect();
        let mut candidates = extract_candidates_from_llm(llm_config, ai_reply, &all_existing, history).await;

    let existing_fronts_lower: Vec<String> = existing_fronts.iter().map(|f| f.to_lowercase()).collect();
    let skipped_lower: Vec<String> = skipped_fronts.iter().map(|f| f.to_lowercase()).collect();

    candidates.retain(|c| {
        let f = c.front.to_lowercase();
        !existing_fronts_lower.contains(&f) && !skipped_lower.contains(&f)
    });

        // 词库匹配：从 AI 回复中扫描出生词（不额外消耗 LLM）
        if crate::word_bank::is_loaded() {
            let matched = crate::word_bank::match_text(ai_reply);
            // 收集需要 LLM 生成释义的词汇（去重后）
            let mut vocab_needs_llm: Vec<String> = Vec::new();
            let mut vocab_candidates: Vec<ConceptCandidate> = Vec::new();

            for m in &matched {
                let word_lower = m.word.to_lowercase();
                if existing_fronts_lower.contains(&word_lower) || skipped_lower.contains(&word_lower) {
                    continue;
                }
                if candidates.iter().any(|c| c.front.to_lowercase() == word_lower) {
                    continue;
                }
                // 所有词库匹配的都交给 LLM 生成释义
                vocab_needs_llm.push(m.word.clone());
            }

            // 批量调用 LLM 为生词生成释义
            if !vocab_needs_llm.is_empty() {
                let prompt = format!(
                    "为以下英语单词生成简洁的单词卡。每个单词包含: front(单词)、back(中文释义和英文例句)。\
                     \n返回 JSON 数组，只返回 JSON，不要其他文字。\
                     \n单词: {}",
                    vocab_needs_llm.join(", ")
                );
                let mut caller = LlmCaller::new(llm_config.clone());
                if let Ok(text) = caller.generate("", &prompt).await {
                    let generated = parse_candidates(&text);
                    for g in generated {
                        let word_lower = g.front.to_lowercase();
                        if vocab_needs_llm.iter().any(|w| w.to_lowercase() == word_lower) {
                            let source = find_source_sentence(ai_reply, &g.front).unwrap_or_default();
                            vocab_candidates.push(ConceptCandidate {
                                source_sentence: source,
                                domain: "vocabulary".to_string(),
                                ..g
                            });
                        }
                    }
                }
            }

            candidates.extend(vocab_candidates);
        }

        ExtractionResult { candidates, direct_card: false }
    }
}

/// 从回复文本中找包含该词的句子
fn find_source_sentence(reply: &str, word: &str) -> Option<String> {
    for line in reply.lines() {
        if line.to_lowercase().contains(&word.to_lowercase()) {
            let trimmed = line.trim();
            if trimmed.len() > 120 {
                return Some(format!("{}...", &trimmed[..120]));
            }
            return Some(trimmed.to_string());
        }
    }
    None
}

/// LLM 提取候选概念（带上下文注入）
async fn extract_candidates_from_llm(
    config: &LlmConfig,
    ai_reply: &str,
    existing_concepts: &[String],
    history: &[(String, String)],
) -> Vec<ConceptCandidate> {
    let prompt = crate::prompt_loader::build_concept_extract(ai_reply, existing_concepts, history);

    let mut caller = LlmCaller::new(config.clone());
    match caller.generate("", &prompt).await {
        Ok(text) => parse_candidates(&text),
        Err(_) => vec![],
    }
}

/// Path B2: 直接制卡
async fn generate_direct_card(config: &LlmConfig, user_message: &str, ai_reply: &str) -> Option<ConceptCandidate> {
    let prompt = crate::prompt_loader::build_card_direct(user_message, ai_reply);

    let mut caller = LlmCaller::new(config.clone());
    match caller.generate("", &prompt).await {
        Ok(text) => parse_single_candidate(&text),
        Err(_) => None,
    }
}

/// 从 JSON 数组中解析候选人列表，过滤无效条目
pub fn parse_candidates(text: &str) -> Vec<ConceptCandidate> {
    let mut candidates = Vec::new();

    // 尝试直接 JSON 解析
    if let Ok(list) = serde_json::from_str::<Vec<ConceptCandidate>>(text.trim()) {
        candidates = list;
    } else if let Some(start) = text.find('[') {
        if let Some(end) = text.rfind(']') {
            let json_str = &text[start..=end];
            if let Ok(list) = serde_json::from_str::<Vec<ConceptCandidate>>(json_str) {
                candidates = list;
            }
        }
    }

    // 过滤: 移除无效条目
    let placeholders = ["无知识点", "无", "none", "null", "n/a", "没有", "无内容", ""];
    candidates.retain(|c| {
        let front = c.front.trim().to_lowercase();
        !front.is_empty() && !placeholders.contains(&front.as_str())
    });

    candidates
}

fn parse_single_candidate(text: &str) -> Option<ConceptCandidate> {
    if let Ok(c) = serde_json::from_str::<ConceptCandidate>(text.trim()) {
        return Some(c);
    }
    if let Some(start) = text.find('{') {
        if let Some(end) = text.rfind('}') {
            let json_str = &text[start..=end];
            if let Ok(c) = serde_json::from_str::<ConceptCandidate>(json_str) {
                return Some(c);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_card_intent_detection() {
        assert!(has_card_intent("把这个制卡"));
        assert!(has_card_intent("帮我记住这个概念"));
        assert!(!has_card_intent("今天天气真好"));
        assert!(has_card_intent("make card for this"));
    }

    #[test]
    fn test_parse_candidates_valid() {
        let json = r#"[{"front":"重力","back":"物体间相互吸引的力","source_sentence":"重力是物体下落的原因","domain":"physics"}]"#;
        let result = parse_candidates(json);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].front, "重力");
    }

    #[test]
    fn test_parse_candidates_empty() {
        let result = parse_candidates("没什么值得提取的");
        assert!(result.is_empty());
    }

    #[test]
    fn test_parse_single_candidate() {
        let json = r#"{"front":"machine learning","back":"AI technique","source_sentence":"ML is amazing","domain":"tech"}"#;
        let c = parse_single_candidate(json);
        assert!(c.is_some());
        assert_eq!(c.unwrap().front, "machine learning");
    }
}
