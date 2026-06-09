/// 卡片结构 (N3 格式化输出 → N4 入库)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Card {
    pub id: String,
    pub user_id: String,
    pub domain: Option<String>,
    pub card_type: String,
    pub front: String,
    pub back: String,
    pub source_sentence: Option<String>,
    pub conversation_id: Option<String>,
    pub created_at: i64,
    pub subject: Option<String>,
    pub grade_band: Option<String>,
    pub plan_id: Option<String>,
    pub task_key: Option<String>,
}

/// FSRS 记忆状态 (1:1 cards)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CardMemory {
    pub card_id: String,
    pub state: i32,                  // 0:New, 1:Learning, 2:Review, 3:Relearning
    pub difficulty: f64,
    pub stability: f64,
    pub due: i64,                    // Unix timestamp
    pub last_review: Option<i64>,
    pub reps: i32,
    pub lapses: i32,
}

/// 候选概念 (N2 提取输出)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConceptCandidate {
    pub front: String,
    pub back: String,
    pub source_sentence: String,
    pub domain: String,
}

/// N2 提取结果
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ExtractionResult {
    pub candidates: Vec<ConceptCandidate>,
    pub direct_card: bool,           // true = Path B2 (直接制卡)
}
