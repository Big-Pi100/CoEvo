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
use tracing;

/// 归一化 card front：去除括号注释（如 "你（人称代词）" → "你"），用于去重比较
fn normalize_front(front: &str) -> String {
    let f = front.trim().to_lowercase();
    // 去除中文括号（ ）和英文括号 ( ) 内的注释内容
    let mut result = String::with_capacity(f.len());
    let mut depth = 0i32;
    for ch in f.chars() {
        match ch {
            '(' | '（' => depth += 1,
            ')' | '）' => {
                if depth > 0 { depth -= 1; }
            }
            _ => {
                if depth == 0 { result.push(ch); }
            }
        }
    }
    result.trim().to_string()
}

/// N2: 从对话中提取候选概念
///
/// existing_fronts: 用户已有卡片的 front 列表 (全小写，含所有 status)
/// history: 最近 N 轮对话 (role, content)，注入 LLM prompt 以避免重复提取
///
/// 1. 检测制卡意图 → Path B2 (直接生成卡片)
/// 2. 否则 → LLM 提取候选概念 → 去重
#[allow(clippy::too_many_arguments)]
pub async fn extract_concepts(
    _user_id: &str,
    user_message: &str,
    ai_reply: &str,
    existing_fronts: &[String],
    llm_config: &LlmConfig,
    history: &[(String, String)],
    domain: &str,  // "language" / "math" / "general"
    plan_context: &str,  // 当前学习计划上下文，用于限定提取范围
) -> ExtractionResult {
    tracing::info!("[CP1] extract_concepts ENTERED: domain={}, msg_preview={}",
        domain, &user_message[..user_message.len().min(60)]);

    // 从 LLM 提取候选概念（传入已有概念 + 对话历史 + plan 上下文，避免重复）
    tracing::info!("[CP1] extract_candidates_from_llm: domain={}, plan_context=[{}], existing={}, history={}", 
        domain, plan_context, existing_fronts.len(), history.len());

    let all_existing: Vec<String> = existing_fronts.to_vec();
    let mut candidates = extract_candidates_from_llm(llm_config, ai_reply, &all_existing, history, domain, plan_context).await;

    tracing::info!("[CP1] after LLM: {} raw candidates before dedup", candidates.len());

    let existing_fronts_normalized: Vec<String> = existing_fronts.iter().map(|f| normalize_front(f)).collect();

    candidates.retain(|c| {
        let f = normalize_front(&c.front);
        !existing_fronts_normalized.contains(&f)
    });

        tracing::info!("[CP1] after dedup: {} candidates ({} filtered out as duplicates)",
            candidates.len(), existing_fronts.len());

        // 词库匹配：从 AI 回复中扫描出生词（不额外消耗 LLM）
        if crate::word_bank::is_loaded() {
            let matched = crate::word_bank::match_text(ai_reply);
            // 收集需要 LLM 生成释义的词汇（去重后）
            let mut vocab_needs_llm: Vec<String> = Vec::new();
            let mut vocab_candidates: Vec<ConceptCandidate> = Vec::new();

            for m in &matched {
                let word_lower = m.word.to_lowercase();
                if existing_fronts_normalized.contains(&word_lower) {
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
                    "为以下英语单词生成简洁的单词卡。每个单词包含: front(单词), pronunciation(音标), definitions(中文释义和英文例句), related_phrases(常用搭配)。\
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
                } else {
                    // LLM 不可用时的降级：利用词库自带释义
                    for m in &matched {
                        let word_lower = m.word.to_lowercase();
                        if vocab_needs_llm.iter().any(|w| w.to_lowercase() == word_lower) {
                            let source = find_source_sentence(ai_reply, &m.word).unwrap_or_default();
                            let back = m.definition.clone();
                            let ipa = m.ipa.clone().unwrap_or_default();
                            let back_with_ipa = if ipa.is_empty() { back } else { format!("/{}/ {}", ipa, back) };
                            vocab_candidates.push(ConceptCandidate {
                                front: m.word.clone(),
                                back: back_with_ipa,
                                source_sentence: source,
                                domain: "vocabulary".to_string(),
                            });
                        }
                    }
                }
            }

            candidates.extend(vocab_candidates);
            tracing::info!("[CP1] after vocab matching: total candidates={}", candidates.len());
        } else {
            tracing::info!("[CP1] word_bank not loaded, skipping vocab matching");
        }

        tracing::info!("[CP1] extract_concepts returning: {} candidates, direct_card=false", candidates.len());        ExtractionResult { candidates, direct_card: false }
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

/// LLM 提取候选概念（带上下文注入 + domain 路由）
async fn extract_candidates_from_llm(
    config: &LlmConfig,
    ai_reply: &str,
    existing_concepts: &[String],
    history: &[(String, String)],
    domain: &str,
    plan_context: &str,
) -> Vec<ConceptCandidate> {
    let prompt = crate::prompt_loader::build_concept_extract_for_domain_with_plan(ai_reply, existing_concepts, history, domain, plan_context);
    tracing::info!("[CP1] Full prompt built: domain={}, total_len={}, existing_count={}, history_count={}",
        domain, prompt.len(), existing_concepts.len(), history.len());
    tracing::info!("[CP1] Full prompt content: {}", prompt);
    tracing::info!("[CP1] plan_context section: {}", plan_context);

    let mut caller = LlmCaller::new(config.clone());
    match caller.generate("", &prompt).await {
        Ok(text) => {
            tracing::info!("[CP1] LLM response received: len={}, content=\n{}",
                text.len(), text);
            let candidates = parse_candidates(&text);
            tracing::info!("[CP1] parse_candidates yielded: {}", candidates.len());
            candidates
        },
        Err(e) => {
            tracing::warn!("[CP1] LLM call failed: {:?}", e);
            vec![]
        },
    }
}

/// 从 JSON 数组中解析候选人列表，过滤无效条目
/// 兼容两种格式：
///   V3 格式: {"front":..., "back":..., "source_sentence":..., "domain":...}
///   V4 格式: {"front":..., "definition":..., "key_elements":..., ...} (将非 front 字段序列化为 back)
pub fn parse_candidates(text: &str) -> Vec<ConceptCandidate> {
    let mut candidates = Vec::new();

    // 辅助: 修复反斜杠后解析 JSON 数组
    let try_parse_v4 = |json_str: &str| -> Option<Vec<serde_json::Value>> {
        match serde_json::from_str::<Vec<serde_json::Value>>(json_str) {
            Ok(list) => Some(list),
            Err(err) => {
                let repaired = repair_json_backslashes(json_str);
                serde_json::from_str::<Vec<serde_json::Value>>(&repaired).ok().or_else(|| {
                    tracing::info!("[CP1] JSON parse failed: {}", err);
                    None
                })
            }
        }
    };

    // 尝试获取 JSON 数组文本
    let json_text = if let Some(start) = text.trim().find('[') {
        if let Some(end) = text.rfind(']') {
            tracing::info!("[CP1] parse_candidates: extracted JSON from brackets, len={}", end - start + 1);
            Some(&text[start..=end])
        } else {
            tracing::info!("[CP1] parse_candidates: found '[' but no matching ']'");
            None
        }
    } else {
        tracing::info!("[CP1] parse_candidates: no JSON array found, preview={}",
            &text[..text.len().min(100)]);
        None
    };

    if let Some(jt) = json_text {
        if let Some(list) = try_parse_v4(jt) {
            for item in &list {
                if let Some(front) = item.get("front").and_then(|v| v.as_str()) {
                    if front.trim().is_empty() { continue; }
                    let mut obj = item.clone();
                    obj.as_object_mut().map(|m| m.remove("front"));
                    obj.as_object_mut().map(|m| m.remove("source_sentence"));
                    let back = serde_json::to_string(&obj).unwrap_or_default();
                    let source_sentence = item.get("source_sentence")
                        .and_then(|v| v.as_str()).unwrap_or("").to_string();
                    let domain = item.get("domain")
                        .and_then(|v| v.as_str()).unwrap_or("general").to_string();
                    candidates.push(ConceptCandidate {
                        front: front.to_string(),
                        back,
                        source_sentence,
                        domain,
                    });
                }
            }
            tracing::info!("[CP1] parse_candidates: parsed {} candidates", candidates.len());
        } else {
            tracing::info!("[CP1] parse_candidates: all parse attempts failed");
        }
    }

    // 过滤: 移除无效条目
    let placeholders = ["无知识点", "无", "none", "null", "n/a", "没有", "无内容", ""];
    let before_filter = candidates.len();
    candidates.retain(|c| {
        let front = c.front.trim().to_lowercase();
        !front.is_empty() && !placeholders.contains(&front.as_str())
    });
    let filtered_out = before_filter - candidates.len();
    if filtered_out > 0 {
        tracing::info!("[CP1] filtered out {} placeholder candidates", filtered_out);
    }

    candidates
}

/// 修复 LLM 输出 JSON 字符串值中的未转义反斜杠
///
/// LLM（特别是 DeepSeek V4 Flash）在生成 JSON 时可能在字符串字段中输出
/// 字面反斜杠（如 `\d`、`\w`），这不符合 JSON 规范。
/// 此函数将 JSON 字符串值内所有非法转义的 `\` 替换为 `\\`。
fn repair_json_backslashes(json_str: &str) -> String {
    let mut result = String::with_capacity(json_str.len());
    let chars: Vec<char> = json_str.chars().collect();
    let mut i = 0;
    let mut in_string = false;

    while i < chars.len() {
        let ch = chars[i];
        match ch {
            '"' if i == 0 || chars[i - 1] != '\\' => {
                in_string = !in_string;
                result.push(ch);
            }
            '\\' if in_string => {
                let valid_escape = i + 1 < chars.len() && matches!(
                    chars[i + 1],
                    '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' | 'u'
                );
                if valid_escape {
                    result.push(ch);
                } else {
                    result.push_str("\\\\");
                    continue;
                }
            }
            _ => result.push(ch),
        }
        i += 1;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
