//! 生命周期日志结构体
//!
//! 每个测试用例输出一个 JSON 日志文件，记录：
//! - prompt 调用（输入 + 输出）
//! - context 组装
//! - 学习计划生命周期
//! - 卡片生命周期
//! - 成就系统事件
//! - 最终等级

use serde::{Serialize, Deserialize};

/// 单个 LLM 调用记录
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmCallLog {
    pub step: String,           // "plan_creation_turn1", "progression_turn2", "concept_extraction"
    pub domain: String,
    pub system_prompt: String,
    pub user_content: String,
    pub response: String,
    pub duration_ms: u64,
    pub success: bool,
}

/// 计划生命周期事件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanEvent {
    pub event: String,          // "created", "updated", "task_complete", "stage_advance", "completed"
    pub turn: u32,
    pub plan_json_before: Option<serde_json::Value>,
    pub plan_json_after: Option<serde_json::Value>,
    pub diff_summary: String,   // 人可读的变化摘要
}

/// 卡片生命周期事件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardEvent {
    pub event: String,          // "extracted", "created", "reviewed", "fsrs_updated"
    pub card_front: String,
    pub card_domain: String,
    pub rating: Option<i32>,
    pub fsrs_state_before: Option<i32>,
    pub fsrs_state_after: Option<i32>,
    pub verification_result: Option<String>,
}

/// 成就事件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AchievementEvent {
    pub key: String,
    pub name: String,
    pub unlocked_at: String,
}

/// 完整生命周期日志（每个 subject-grade 一个）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LifecycleLog {
    pub run_id: String,
    pub subject: String,
    pub grade_band: String,     // "g1-2", "g3-4", "g5-6", "g7-9", "g10-12"
    pub domain: String,
    pub student_opening: String,

    // 阶段结果
    pub plan_created: bool,
    pub progression_turns: u32,
    pub plan_updates: u32,
    pub candidates_extracted: u32,
    pub cards_created: u32,
    pub reviews_submitted: u32,
    pub review_pass_rate: f64,

    // 详细日志
    pub llm_calls: Vec<LlmCallLog>,
    pub plan_events: Vec<PlanEvent>,
    pub card_events: Vec<CardEvent>,
    pub achievements: Vec<AchievementEvent>,

    // 结果
    pub status: String,         // "passed", "failed", "skipped"
    pub grade: String,          // "A", "B", "C", "D", "F"
    pub duration_ms: u64,
    pub errors: Vec<String>,
}

impl LifecycleLog {
    pub fn new(subject: &str, grade_band: &str, domain: &str, opening: &str, run_id: &str) -> Self {
        Self {
            run_id: run_id.to_string(),
            subject: subject.to_string(),
            grade_band: grade_band.to_string(),
            domain: domain.to_string(),
            student_opening: opening.to_string(),
            plan_created: false,
            progression_turns: 0,
            plan_updates: 0,
            candidates_extracted: 0,
            cards_created: 0,
            reviews_submitted: 0,
            review_pass_rate: 0.0,
            llm_calls: vec![],
            plan_events: vec![],
            card_events: vec![],
            achievements: vec![],
            status: "running".to_string(),
            grade: "F".to_string(),
            duration_ms: 0,
            errors: vec![],
        }
    }
}
