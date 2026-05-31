//! K12 题库 API
//!
//! POST /api/k12/quiz/submit — 提交试题作答，计算通过率

use axum::{Json, http::HeaderMap};
use serde::Deserialize;
use uuid::Uuid;

/// 单题作答
#[derive(Deserialize)]
pub struct QuizAnswer {
    pub quiz_id: String,
    pub answer: String,
}

/// 提交请求
#[derive(Deserialize)]
pub struct QuizSubmitInput {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub task_name: String,
    pub answers: Vec<QuizAnswer>,
}

/// 提交查询参数
#[derive(Deserialize)]
pub struct QuizSubmitQuery {
    pub user_id: String,
}

/// POST /api/k12/quiz/submit — 提交作答并计算通过率
pub async fn quiz_submit_handler(
    headers: HeaderMap,
    Json(input): Json<QuizSubmitInput>,
) -> Json<serde_json::Value> {
    // 鉴权
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return crate::routes::auth_json(e);
    }

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    let mut correct_count = 0u32;
    let mut total_count = 0u32;
    let mut details: Vec<serde_json::Value> = Vec::new();

    for answer in &input.answers {
        total_count += 1;

        // 查正确答案
        let correct_answer: Option<String> = conn.query_row(
            "SELECT answer FROM k12_quiz_bank WHERE id = ?1",
            rusqlite::params![&answer.quiz_id],
            |row| row.get(0),
        ).ok();

        let is_correct = match correct_answer {
            Some(ref correct) => answer.answer.trim() == correct.trim(),
            None => false,
        };

        if is_correct {
            correct_count += 1;
        }

        // 写入 k12_quiz_attempts
        let attempt_id = Uuid::new_v4().to_string();
        let _ = conn.execute(
            "INSERT INTO k12_quiz_attempts (id, user_id, quiz_id, conversation_id, user_answer, is_correct, attempted_at, task_name)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                attempt_id, input.user_id, answer.quiz_id, input.conversation_id,
                answer.answer, if is_correct { 1 } else { 0 }, now, input.task_name,
            ],
        );

        details.push(serde_json::json!({
            "quiz_id": answer.quiz_id,
            "correct": is_correct,
            "expected": correct_answer.unwrap_or_default(),
        }));
    }

    let pass_rate = if total_count > 0 {
        correct_count as f64 / total_count as f64
    } else {
        0.0
    };

    // 更新 k12_progress（写入/更新）
    let _ = conn.execute(
        "INSERT INTO k12_progress (id, user_id, subject, grade_band, plan_json, mastered_cards, total_cards, started_at, last_activity_at)
         VALUES (?1, ?2, '', '', NULL, 0, 0, ?3, ?3)
         ON CONFLICT(user_id, subject, grade_band) DO UPDATE SET last_activity_at = ?3",
        rusqlite::params![Uuid::new_v4().to_string(), input.user_id, now],
    );

    Json(serde_json::json!({
        "correct": correct_count,
        "total": total_count,
        "pass_rate": (pass_rate * 100.0).round() / 100.0,
        "passed": pass_rate >= 0.8,
        "details": details,
    }))
}
