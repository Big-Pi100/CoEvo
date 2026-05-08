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
use shared_types::card::{ConceptCandidate, ExtractionResult};

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
        // 从 LLM 提取候选概念
        let mut candidates = extract_candidates_from_llm(llm_config, ai_reply).await;

    let existing_fronts_lower: Vec<String> = existing_fronts.iter().map(|f| f.to_lowercase()).collect();
    let skipped_lower: Vec<String> = skipped_fronts.iter().map(|f| f.to_lowercase()).collect();

    candidates.retain(|c| {
        let f = c.front.to_lowercase();
        !existing_fronts_lower.contains(&f) && !skipped_lower.contains(&f)
    });

        // 最多 5 个
        candidates.truncate(5);

        ExtractionResult { candidates, direct_card: false }
    }
}

/// LLM 提取候选概念 (≤5)
async fn extract_candidates_from_llm(config: &LlmConfig, ai_reply: &str) -> Vec<ConceptCandidate> {
    let prompt = crate::prompt_loader::build_concept_extract(ai_reply);

    let mut caller = LlmCaller::new(config.clone());
    match caller.generate(&prompt).await {
        Ok(text) => parse_candidates(&text),
        Err(_) => vec![],
    }
}

/// Path B2: 直接制卡
async fn generate_direct_card(config: &LlmConfig, user_message: &str, ai_reply: &str) -> Option<ConceptCandidate> {
    let prompt = crate::prompt_loader::build_card_direct(user_message, ai_reply);

    let mut caller = LlmCaller::new(config.clone());
    match caller.generate(&prompt).await {
        Ok(text) => parse_single_candidate(&text),
        Err(_) => None,
    }
}

/// 从 JSON 数组中解析候选人列表，过滤无效条目
fn parse_candidates(text: &str) -> Vec<ConceptCandidate> {
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
