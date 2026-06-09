//! N3: 卡片格式化 (纯函数)
//!
//! 将概念数据格式化为 Card + 初始 CardMemory

use shared_types::card::{Card, CardMemory, ConceptCandidate};
use chrono::Utc;

/// 格式化卡片: 从候选概念生成 Card + CardMemory
/// 这是纯函数，所有参数直接传入，无副作用
pub fn format_card(user_id: &str, candidate: &ConceptCandidate) -> (Card, CardMemory) {
    let now = Utc::now().timestamp();
    let card_id = format!("card_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());

    let card = Card {
        id: card_id.clone(),
        user_id: user_id.to_string(),
        domain: Some(candidate.domain.clone()),
        // domain 为 "vocabulary" 的候选自动归为词汇卡，其余为概念卡
        card_type: if candidate.domain == "vocabulary" { "vocabulary".to_string() } else { "concept".to_string() },
        front: candidate.front.clone(),
        back: candidate.back.clone(),
        source_sentence: Some(candidate.source_sentence.clone()),
        conversation_id: None,
        created_at: now,
        subject: None,
        grade_band: None,
        plan_id: None,
        task_key: None,
    };

    // FSRS 初始状态: New, difficulty=5.0, stability=0.0, due=now
    let memory = CardMemory {
        card_id,
        state: 0,          // New
        difficulty: 5.0,
        stability: 0.0,
        due: now,          // 立即可复习
        last_review: None,
        reps: 0,
        lapses: 0,
    };

    (card, memory)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_card_creates_valid_ids() {
        let candidate = ConceptCandidate {
            front: "rust ownership".into(),
            back: "Rust's ownership system ensures memory safety without a garbage collector".into(),
            source_sentence: "Rust uses ownership to manage memory.".into(),
            domain: "programming".into(),
        };
        let (card, memory) = format_card("user_test", &candidate);
        assert_eq!(card.user_id, "user_test");
        assert_eq!(card.front, "rust ownership");
        assert_eq!(card.card_type, "concept");
        assert_eq!(memory.state, 0); // New
        assert!((memory.difficulty - 5.0).abs() < 0.01);
        assert!(card.id.starts_with("card_"));
        assert_eq!(memory.card_id, card.id);
    }

    #[test]
    fn test_memory_due_is_now() {
        let candidate = ConceptCandidate {
            front: "test".into(),
            back: "test".into(),
            source_sentence: "test".into(),
            domain: "general".into(),
        };
        let (_, memory) = format_card("u1", &candidate);
        let now = Utc::now().timestamp();
        // due should be within 2 seconds of now
        assert!((memory.due - now).abs() < 2);
    }
}
