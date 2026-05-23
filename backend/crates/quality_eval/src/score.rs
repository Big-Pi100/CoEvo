//! L1 指标自动计算（plan / review 维度）
//! 无需 LLM 调用，从 LifecycleLog 直接计算

use k12_tests::LifecycleLog;
use crate::{PlanScore, ReviewScore, CompositeScore, grade_from_score};

/// 计算计划执行度评分（L1）
pub fn compute_plan_score(log: &LifecycleLog) -> PlanScore {
    let parse_rate = if log.plan_events.is_empty() { 0.0 } else { 1.0 };

    let turns = log.progression_turns.max(1) as f64;
    let stage_advancement = (log.plan_updates as f64 / turns).min(1.0);

    let task_completion = (log.plan_updates as f64 / turns.min(4.0) * 2.0).min(1.0); // 4回合至少2次plan_update算满分

    let persistence = if log.plan_created { 1.0 } else { 0.0 };

    let routing_consistency = 1.0; // 待完善：对比 plan_json.domain 与测试 domain

    let overall = parse_rate * 0.30 + stage_advancement * 0.25
        + task_completion * 0.20 + persistence * 0.15
        + routing_consistency * 0.10;

    PlanScore {
        parse_rate, stage_advancement, task_completion,
        persistence, routing_consistency,
        overall: overall * 100.0, // 统一到 0-100 分制
    }
}

/// 计算复习全链路评分（L1）
pub fn compute_review_score(log: &LifecycleLog) -> ReviewScore {
    let card_creation_rate = if log.candidates_extracted > 0 {
        log.cards_created as f64 / log.candidates_extracted as f64
    } else {
        0.0
    };

    let has_fsrs = log.card_events.iter().any(|e| {
        e.event == "reviewed" && e.fsrs_state_before.is_some() && e.fsrs_state_after.is_some()
    });
    let fsrs_correctness = if has_fsrs { 1.0 } else { 0.0 };

    let log_completeness = if log.reviews_submitted > 0 { 1.0 } else { 0.0 };

    let verification_match = log.review_pass_rate;

    let multi_round_consistency = if log.reviews_submitted >= 4 { 1.0 } else {
        log.reviews_submitted as f64 / 4.0
    };

    let overall = card_creation_rate * 0.20 + fsrs_correctness * 0.25
        + log_completeness * 0.20 + verification_match * 0.15
        + multi_round_consistency * 0.20;

    ReviewScore {
        card_creation_rate, fsrs_correctness, log_completeness,
        verification_match, multi_round_consistency,
        overall: overall * 100.0, // 统一到 0-100 分制
    }
}

/// 计算综合评分
pub fn compute_composite(
    teacher: Option<f64>, student: Option<f64>,
    plan: Option<f64>, card: Option<f64>, review: Option<f64>,
) -> CompositeScore {
    let weights = if student.is_none() && review.is_none() {
        // 学生+复习都不可用：权重分摊
        (0.40, 0.35, 0.25, 0.0, 0.0)
    } else if student.is_none() {
        // 仅学生不可用：均摊给学生→教师(+10%)和卡片(+10%)
        (0.40, 0.25, 0.15, 0.0, 0.20)
    } else if review.is_none() {
        // 仅复习不可用：均摊给计划和卡片
        (0.30, 0.25, 0.20, 0.20, 0.05)
    } else {
        (0.30, 0.25, 0.15, 0.20, 0.10)
    };

    let total = teacher.unwrap_or(0.0) * weights.0
        + card.unwrap_or(0.0) * weights.1
        + plan.unwrap_or(0.0) * weights.2
        + student.unwrap_or(0.0) * weights.3
        + review.unwrap_or(0.0) * weights.4;

    let grade = grade_from_score(total).to_string();

    CompositeScore {
        teacher_weighted: teacher.unwrap_or(0.0) * weights.0,
        card_weighted: card.unwrap_or(0.0) * weights.1,
        plan_weighted: plan.unwrap_or(0.0) * weights.2,
        student_weighted: student.unwrap_or(0.0) * weights.3,
        review_weighted: review.unwrap_or(0.0) * weights.4,
        total,
        grade,
    }
}
