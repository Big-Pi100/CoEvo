//! Pipeline 2：质量评估管线
//!
//! 读取 Pipeline 1 产出的 LifecycleLog JSON，对 5 维质量进行评分
//!
//! 维度：
//! - teacher：教师回答质量（L2 — 第二条 LLM 评估）
//! - card：卡片质量（L2 — 第二条 LLM 评估）
//! - plan：计划执行度（L1 — 自动计算）
//! - student：学生模拟质量（L2 — 需双 LLM 数据）
//! - review：复习全链路（L1 — 自动计算）

pub mod reader;
pub mod evaluator;
pub mod score;
pub mod report;

use serde::{Serialize, Deserialize};

/// 每用例的综合评估结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualityEval {
    pub subject: String,
    pub grade_band: String,
    pub source_run_id: String,

    pub scores: QualityScores,
    pub llm_eval_logs: Vec<LlmEvalLog>,
    pub issues: Vec<QualityIssue>,
}

/// 各维度评分
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualityScores {
    pub teacher: Option<TeacherScore>,
    pub student: Option<StudentScore>,
    pub plan: Option<PlanScore>,
    pub card: Option<CardScore>,
    pub review: Option<ReviewScore>,
    pub composite: CompositeScore,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeacherScore {
    pub correctness: f64,
    pub grade_fit: f64,
    pub structure: f64,
    pub coverage: f64,
    pub plan_update_rate: f64,
    pub overall: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StudentScore {
    pub error_rate: f64,
    pub naturalness: f64,
    pub questioning_rate: f64,
    pub diversity: f64,
    pub understanding_depth: f64,
    pub overall: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanScore {
    pub parse_rate: f64,
    pub stage_advancement: f64,
    pub task_completion: f64,
    pub persistence: f64,
    pub routing_consistency: f64,
    pub overall: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CardScore {
    pub candidate_count: f64,
    pub domain_accuracy: f64,
    pub front_quality: f64,
    pub back_quality: f64,
    pub dedup_rate: f64,
    pub useful_rate: f64,
    pub overall: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewScore {
    pub card_creation_rate: f64,
    pub fsrs_correctness: f64,
    pub log_completeness: f64,
    pub verification_match: f64,
    pub multi_round_consistency: f64,
    pub overall: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompositeScore {
    pub teacher_weighted: f64,
    pub card_weighted: f64,
    pub plan_weighted: f64,
    pub student_weighted: f64,
    pub review_weighted: f64,
    pub total: f64,
    pub grade: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmEvalLog {
    pub dimension: String,
    pub prompt: String,
    pub response: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualityIssue {
    pub severity: String,
    pub category: String,
    pub message: String,
}

pub fn grade_from_score(score: f64) -> &'static str {
    if score >= 85.0 { "A" }
    else if score >= 70.0 { "B" }
    else if score >= 55.0 { "C" }
    else if score >= 40.0 { "D" }
    else { "F" }
}
