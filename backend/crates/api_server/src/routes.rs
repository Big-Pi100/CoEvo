//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, put, delete, patch}, Json, extract::{Path, Query}};
use axum::extract::ws::WebSocketUpgrade;
use axum::http::HeaderMap;
use tower_http::trace::TraceLayer;
use serde::Deserialize;
use std::sync::OnceLock;
use std::collections::HashMap;

use crate::error::AppError;
use crate::curriculum_loader;
use crate::admin_handlers::*;

/// Helper: convert an AppError into a Json error response (for handlers returning Json<Value>)
pub(crate) fn auth_json(e: AppError) -> Json<serde_json::Value> {
    Json(serde_json::json!({"error": e.to_string()}))
}

/// Helper: run a DB query that returns Vec<T>, or return a Json error
fn query_vec<T, F>(
    conn: &rusqlite::Connection, sql: &str, params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<Vec<T>, Json<serde_json::Value>>
where F: Fn(&rusqlite::Row) -> rusqlite::Result<T>
{
    let mut stmt = conn.prepare(sql).map_err(|e| Json(serde_json::json!({"error": format!("DB prepare: {}", e)})))?;
    let rows: Vec<T> = stmt.query_map(params, map)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB query: {}", e)})))?
        .filter_map(|r| r.ok()).collect();
    Ok(rows)
}

/// Helper: run a query_row that returns a single value, or return a Json error
#[allow(dead_code)]
fn query_one<T, F>(
    conn: &rusqlite::Connection, sql: &str, params: &[&dyn rusqlite::types::ToSql],
    map: F,
) -> Result<T, Json<serde_json::Value>>
where F: Fn(&rusqlite::Row) -> rusqlite::Result<T>
{
    conn.query_row(sql, params, map)
        .map_err(|e| Json(serde_json::json!({"error": format!("DB query: {}", e)})))
}

use chat_engine::llm_caller::LlmConfig;

pub fn build_router(llm_config: LlmConfig) -> Router {
    // 存储 LLM 配置供 routes 使用
    crate::llm::init(llm_config);

    Router::new()
        // ── Health ──
        .route("/health", get(health_check))
        // ── Auth ──
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
        .route("/api/auth/verify", post(auth_verify))
        // ── Review / Spaced Repetition ──
        .route("/api/review/due", get(review_due_handler))
        .route("/api/review/submit", post(review_submit_handler))
        .route("/api/review/verify", post(review_verify_handler))
        .route("/api/review/judge", post(review_judge_handler))
        .route("/api/review/cards-by-progress", get(review_cards_by_progress_handler))
        // ── Cards ──
        .route("/api/cards/status", patch(cards_status_handler))
        .route("/api/cards/batch-status", patch(cards_batch_status_handler))
        .route("/api/cards/all", get(cards_all_handler))
        .route("/api/cards/by-plan", get(cards_by_plan_handler))
        .route("/api/cards/search", get(cards_search_handler))
        .route("/api/cards/{card_id}/last-review", get(cards_last_review_handler))
        // ── History ──
        .route("/api/history", get(history_handler))
        // ── Conversation Management ──
        .route("/api/conversations/{conv_id}", delete(conversation_delete_handler))
        .route("/api/conversations/{conv_id}/restore", post(conversation_restore_handler))
        .route("/api/conversations/{conv_id}/permanent", delete(conversation_permanent_delete_handler))
        // ── User Profile ──
        .route("/api/user/{user_id}/profile", get(profile_handler))
        .route("/api/user/{user_id}/profile", put(update_user_profile_handler))
        .route("/api/user/{user_id}/display-name", post(update_display_name_handler))
        .route("/api/user/{user_id}/avatar", post(avatar_upload_handler).get(avatar_get_handler))
        .route("/api/user/{user_id}/achievements-all", get(achievements_all_handler))
        .route("/api/user/{user_id}/preferences", get(preferences_get_handler).put(preferences_put_handler))
        .route("/api/user/bind-lookup", post(bind_lookup_handler))
        // ── Learning Plans ──
        .route("/api/plans", get(plans_list_handler))
        // ── Learning Reports (Dashboard) ──
        .route("/api/user/{user_id}/learning-report", get(learning_report_handler))
        .route("/api/user/{user_id}/activity", get(activity_handler))
        .route("/api/user/{user_id}/weekly-report", get(weekly_report_handler))
        // ── K12 Structured Learning ──
        .route("/api/k12/init", post(k12_init_handler))
        .route("/api/k12/progress", get(k12_progress_handler))
        .route("/api/k12/reading/{conv_id}/current-card", get(k12_reading_current_card_handler))
        .route("/api/k12/quiz/submit", post(crate::k12_quiz_api::quiz_submit_handler))
        // ── WebSocket ──
        .route("/ws", get(ws_upgrade))
        // ── Verify Translation (V1 forward mode) ──
        .route("/api/verify-translation", post(verify_translation_handler))
        // ── Admin ──
        .route("/api/admin/login", post(admin_login))
        .route("/api/admin/dashboard", get(admin_dashboard))
        .route("/api/admin/register", post(admin_register))
        .route("/api/admin/users", get(admin_users_handler))
        .route("/api/admin/users/expiring", get(admin_expiring_users))
        .route("/api/admin/users/export", get(admin_users_export))
        .route("/api/admin/users/batch-subscription", post(admin_batch_subscription))
        .route("/api/admin/users/{user_id}", get(admin_user_detail).delete(admin_delete_user))
        .route("/api/admin/users/{user_id}/hard-delete", delete(admin_hard_delete_user))
        .route("/api/admin/users/{user_id}/restore", post(admin_restore_user))
        .route("/api/admin/users/{user_id}/reveal-phone", post(admin_reveal_phone))
        .route("/api/admin/users/{user_id}/subscription", put(admin_set_subscription))
        .route("/api/admin/users/{user_id}/quick-extend", post(admin_quick_extend))
        .route("/api/admin/subscription-requests", get(admin_list_subscription_requests).post(admin_create_subscription_request))
        .route("/api/admin/subscription-requests/{req_id}/approve", post(admin_approve_request))
        .route("/api/admin/subscription-requests/{req_id}/reject", post(admin_reject_request))
        .route("/api/admin/admins", get(admin_list_admins).post(admin_create_admin))
        .route("/api/admin/admins/{admin_id}/approve", post(admin_approve_admin))
        .route("/api/admin/admins/{admin_id}/reject", post(admin_reject_admin))
        .route("/api/admin/admins/{admin_id}/password", post(admin_reset_password))
        .route("/api/admin/admins/{admin_id}/permissions", put(admin_set_permissions))
        .route("/api/admin/admins/{admin_id}/disable", delete(admin_disable_admin))
        .route("/api/admin/admins/{admin_id}/enable", post(admin_enable_admin))
        .route("/api/admin/audit-log", get(admin_audit_log))
        // ── Admin: Guardian (Parent) ──
        .route("/api/admin/guardian/students", get(guardian_students))
        .route("/api/admin/guardian/students/{student_id}", get(guardian_student_cards))
        .route("/api/admin/guardian/students/{student_id}/cards", get(guardian_student_cards))
        .route("/api/admin/guardian/students/{student_id}/conversations", get(guardian_student_conversations))
        .route("/api/admin/guardian/students/{student_id}/conversations/{conv_id}", get(guardian_student_conversation_detail))
        .route("/api/admin/guardian/students/{student_id}/learning-summary", get(guardian_learning_summary))
        .route("/api/admin/guardian/bind", post(guardian_bind_request))
        .route("/api/admin/guardian/reveal-phone/{admin_id}", post(guardian_reveal_phone))
        .route("/api/admin/guardian/assignments", get(admin_list_assignments).post(admin_create_assignment))
        .route("/api/admin/guardian/assignments/{assignment_id}", delete(admin_remove_assignment))
        // ── 全局中间件：HTTP 请求/响应日志 ──
        .layer(TraceLayer::new_for_http())
}

// ════════════════════════════════════════════
// Handlers (stubs — will be filled in later)
// ════════════════════════════════════════════

/// GET /health — 服务器健康检查
/// 请求: 无
/// 响应: "CoEvo API — OK"
async fn health_check() -> &'static str {
    "CoEvo API — OK"
}

#[derive(Deserialize)]
pub struct AuthInput {
    pub username: String,
    pub password: String,
    pub real_name: Option<String>,
    pub phone: Option<String>,
}

/// POST /api/auth/register — 注册新用户
/// 请求: {"username": "str", "password": "str", "real_name?": "str", "phone?": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
async fn auth_register(Json(input): Json<AuthInput>) -> Json<serde_json::Value> {
    tracing::info!("auth_register: user_id={}", input.username);

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::register(&conn, &crate::auth::RegisterRequest {
            username: input.username,
            password: input.password,
            real_name: input.real_name,
            phone: input.phone,
        })
    };
    match result {
        Ok(resp) => Json(serde_json::json!(resp)),
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

/// POST /api/auth/login — 用户登录
/// 请求: {"username": "str", "password": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
/// 注意: 登录后会踢掉同一用户的其他 WebSocket 连接（单设备登录）
async fn auth_login(Json(input): Json<AuthInput>) -> Json<serde_json::Value> {
    tracing::info!("auth_login: user_id={}", input.username);

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::login(&conn, &crate::auth::LoginRequest {
            username: input.username,
            password: input.password,
        })
    };
    match result {
        Ok(resp) => {
            // 踢掉同一用户的其他 WS 连接（单设备登录强制）
            crate::ws::kick_user_connections(&resp.user_id).await;
            Json(serde_json::json!(resp))
        },
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

/// POST /api/auth/verify — 验证 token 是否仍有效（用于应用重启后的会话恢复）
/// 请求: {"user_id": "str", "token": "str"}
/// 响应: {"valid": true|false}
#[derive(Deserialize)]
pub struct TokenVerifyInput {
    pub user_id: String,
    pub token: String,
}

async fn auth_verify(Json(input): Json<TokenVerifyInput>) -> Json<serde_json::Value> {
    tracing::info!("auth_verify: user_id={}", input.user_id);

    let conn = crate::db_pool::get_conn();
    let valid = crate::auth::verify_token(&conn, &input.user_id, &input.token);
    Json(serde_json::json!({"valid": valid}))
}

// ── Review Handlers ──

#[derive(Deserialize)]
pub struct DueQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

/// GET /api/review/due — 获取到期待复习的卡片
/// 请求参数: ?user_id=str[&conversation_id=str][&limit=20][&offset=0]
/// 响应: {"cards": [...], "total_due": int, "has_more": bool}
async fn review_due_handler(
    headers: HeaderMap,
    Query(query): Query<DueQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("review_due_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let page_size = query.limit.unwrap_or(20);
    let offset = query.offset.unwrap_or(0);
    let (cards, total) = card_engine::fsrs_scheduler::get_due_cards(
        &conn, &query.user_id, page_size, offset, query.conversation_id.as_deref(),
    );
    Json(serde_json::json!({
        "cards": cards,
        "total_due": total,
        "has_more": (offset as usize + cards.len()) < total as usize,
    }))
}

#[derive(Deserialize)]
pub struct ReviewSubmitInput {
    pub user_id: String,
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,
    pub details: Option<String>,  // JSON 数组: [{question, correct, feedback}]
}

/// POST /api/review/submit — 提交复习结果（含 FSRS 调度更新 + 成就检测）
/// 请求: {"user_id": "str", "card_id": "str", "rating": int(0-4),
///        "verification_type": "str", "verification_result": "str",
///        "details?": "[{question,correct,feedback}]"}
/// 响应: {"status": "ok", "achievements": [...]} 或 {"error": "str"}
async fn review_submit_handler(
    headers: HeaderMap,
    Json(input): Json<ReviewSubmitInput>,
) -> Json<serde_json::Value> {
    tracing::info!("review_submit_handler: user_id={}", input.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();

    match card_engine::fsrs_scheduler::submit_review(
        &conn, &input.card_id, input.rating,
        &input.verification_type, &input.verification_result, &input.user_id,
        input.details.as_deref(),
    ) {
        Ok(ctx) => {
            // 每日定时成就检测（24h 冷却）
            crate::achievement_engine::check_daily(&conn, &ctx.user_id);

            // 事件总线：走 TOML triggers 过滤，仅检测 review_completed 成就
            crate::achievement_engine::publish(
                &conn,
                crate::achievement_engine::AppEvent::ReviewCompleted {
                    user_id: ctx.user_id.clone(),
                },
            );

            // 成就全量检测（兜底 + 返回新成就给前端）
            // 必须用 build_context 重新查 DB，因为 ctx 只有 6 个字段（submit_review 返回值）
            let fresh_ctx = crate::achievement_engine::build_context(&conn, &input.user_id);
            let engine = crate::achievement_engine::get();
            let new_achievements = engine.check_and_persist(&conn, &fresh_ctx);

            Json(serde_json::json!({
                "status": "ok",
                "achievements": new_achievements,
            }))
        }
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

#[derive(Deserialize)]
pub struct VerifyInput {
    pub user_id: String,
    pub card_id: String,
    pub front: String,
    pub back: String,
}

/// AI 快问快答: 生成 3 个问题
/// POST /api/review/verify — LLM 生成快问快答题目（3 题）
/// 请求: {"user_id": "str", "card_id": "str", "front": "str", "back": "str"}
/// 响应: {"questions": [{question, expected_answer}, ...]} 或 {"error": "str", "raw": "str"}
async fn review_verify_handler(
    headers: HeaderMap,
    Json(input): Json<VerifyInput>,
) -> Json<serde_json::Value> {
    tracing::info!("review_verify_handler: user_id={}", input.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let llm_config = crate::llm::get_config();
    let prompt = chat_engine::prompt_loader::get_quiz("general").generate.clone()
        .replace("{front}", &input.front)
        .replace("{back}", &input.back);

    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    match caller.generate("", &prompt).await {
        Ok(text) => {
            // 尝试 JSON 解析
            if let Ok(questions) = serde_json::from_str::<Vec<serde_json::Value>>(&text) {
                return Json(serde_json::json!({"questions": questions}));
            }
            // fallback: 从文本提取
            if let Some(start) = text.find('[') {
                if let Some(end) = text.rfind(']') {
                    if let Ok(questions) = serde_json::from_str::<Vec<serde_json::Value>>(&text[start..=end]) {
                        return Json(serde_json::json!({"questions": questions}));
                    }
                }
            }
            Json(serde_json::json!({"error": "Failed to parse questions", "raw": text}))
        }
        Err(e) => Json(serde_json::json!({"error": format!("LLM: {}", e)})),
    }
}

#[derive(Deserialize)]
pub struct JudgeInput {
    pub user_id: String,
    pub card_id: String,
    pub questions: Vec<JudgeQuestionInput>,
}

#[derive(Deserialize)]
pub struct JudgeQuestionInput {
    pub question: String,
    pub expected_answer: String,
    pub user_answer: String,
}

/// AI 快问快答: 批量判断 3 个答案
/// POST /api/review/judge — LLM 批量判断用户答案是否正确
/// 请求: {"user_id": "str", "card_id": "str",
///        "questions": [{"question":"str","expected_answer":"str","user_answer":"str"}, ...]}
/// 响应: {"results": [{"correct": bool, "feedback": "str"}, ...]} 或 {"error": "str"}
async fn review_judge_handler(
    headers: HeaderMap,
    Json(input): Json<JudgeInput>,
) -> Json<serde_json::Value> {
    tracing::info!("review_judge_handler: user_id={}", input.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let llm_config = crate::llm::get_config();

    let mut q_parts = Vec::new();
    for (i, q) in input.questions.iter().enumerate() {
        q_parts.push(format!(
            "Q{}: {}\nExpected: {}\nUser answered: {}",
            i + 1, q.question, q.expected_answer, q.user_answer
        ));
    }

    let prompt = chat_engine::prompt_loader::get_quiz("general").judge.clone()
        .replace("{questions}", &q_parts.join("\n---\n"));

    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    match caller.generate("", &prompt).await {
        Ok(text) => {
            if let Ok(results) = serde_json::from_str::<Vec<serde_json::Value>>(&text) {
                let total_correct = results.iter()
                    .filter(|r| r.get("correct").and_then(|c| c.as_bool()).unwrap_or(false))
                    .count();
                return Json(serde_json::json!({
                    "results": results,
                    "total_correct": total_correct,
                    "total": results.len(),
                }));
            }
            if let Some(start) = text.find('[') {
                if let Some(end) = text.rfind(']') {
                    if let Ok(results) = serde_json::from_str::<Vec<serde_json::Value>>(&text[start..=end]) {
                        let total_correct = results.iter()
                            .filter(|r| r.get("correct").and_then(|c| c.as_bool()).unwrap_or(false))
                            .count();
                        return Json(serde_json::json!({
                            "results": results,
                            "total_correct": total_correct,
                            "total": results.len(),
                        }));
                    }
                }
            }
            Json(serde_json::json!({"error": "Parse failed", "raw": text}))
        }
        Err(e) => Json(serde_json::json!({"error": format!("LLM: {}", e)})),
    }
}

// ── Review: cards by progress ──

/// GET /api/review/cards-by-progress — 按 task 进度查询卡片
#[derive(Deserialize)]
struct CardsByProgressQuery {
    user_id: String,
}

async fn review_cards_by_progress_handler(
    headers: HeaderMap,
    Query(query): Query<CardsByProgressQuery>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let mut plan_info: std::collections::HashMap<String, serde_json::Value> = std::collections::HashMap::new();
    let cards: Vec<serde_json::Value> = match conn.prepare(
        "SELECT c.id, c.user_id, c.front, c.back, c.domain, c.subject, c.card_type,
                c.source_sentence, c.created_at, c.conversation_id, c.plan_id, c.task_key,
                upp.status as task_status,
                cp.goal as plan_goal, cp.subject as plan_subject, cp.grade_band as plan_grade_band
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         JOIN user_plan_progress upp ON c.plan_id = upp.plan_id AND c.task_key = upp.task_key
         JOIN conversation_plans cp ON c.plan_id = cp.id
         WHERE upp.user_id = ?1
           AND upp.status IN ('done', 'in_progress')
           AND cm.status = 'active'
         ORDER BY upp.status DESC, c.created_at ASC"
    ) {
        Ok(mut stmt) => {
            match stmt.query_map(rusqlite::params![query.user_id], |row| {
                let plan_id: Option<String> = row.get(10)?;
                let plan_goal: Option<String> = row.get(13)?;
                let plan_subject: Option<String> = row.get(14)?;
                let plan_grade_band: Option<String> = row.get(15)?;
                // Collect unique plan info
                if let Some(ref pid) = plan_id {
                    if !plan_info.contains_key(pid) {
                        plan_info.insert(pid.clone(), serde_json::json!({
                            "plan_id": pid,
                            "goal": plan_goal,
                            "subject": plan_subject,
                            "grade_band": plan_grade_band,
                        }));
                    }
                }
                Ok(serde_json::json!({
                    "id": row.get::<_, String>(0)?,
                    "user_id": row.get::<_, String>(1)?,
                    "front": row.get::<_, String>(2)?,
                    "back": row.get::<_, String>(3)?,
                    "domain": row.get::<_, Option<String>>(4)?,
                    "subject": row.get::<_, Option<String>>(5)?,
                    "card_type": row.get::<_, String>(6)?,
                    "source_sentence": row.get::<_, Option<String>>(7)?,
                    "created_at": row.get::<_, i64>(8)?,
                    "conversation_id": row.get::<_, Option<String>>(9)?,
                    "plan_id": plan_id,
                    "task_key": row.get::<_, Option<String>>(11)?,
                    "task_status": row.get::<_, String>(12)?,
                    "plan_goal": plan_goal,
                    "plan_subject": plan_subject,
                    "plan_grade_band": plan_grade_band,
                }))
            }) {
                Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                Err(e) => return Json(serde_json::json!({"error": format!("DB query: {}", e)})),
            }
        }
        Err(e) => return Json(serde_json::json!({"error": format!("DB prepare: {}", e)})),
    };
    let plans: Vec<serde_json::Value> = plan_info.into_values().collect();
    Json(serde_json::json!({"cards": cards, "plans": plans, "count": cards.len()}))
}

// ── Verify Translation (V1 forward mode) ──

#[derive(Deserialize)]
struct VerifyTranslationInput {
    front: String,
    back: String,
    user_input: String,
}

async fn verify_translation_handler(
    Json(input): Json<VerifyTranslationInput>,
) -> Json<serde_json::Value> {
    tracing::info!("verify_translation_handler");

    let tpl = chat_engine::prompt_loader::get_verify("general");
    let prompt = tpl.translation
        .replace("{front}", &input.front)
        .replace("{back}", &input.back)
        .replace("{user_input}", &input.user_input);

    let config = crate::llm::get_config();
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);
    match caller.generate("", &prompt).await {
        Ok(reply) => {
            let result = if reply.to_lowercase().contains("pass") { "pass" } else { "fail" };
            Json(serde_json::json!({"result": result}))
        }
        Err(_) => {
            // LLM fallback: simple keyword matching
            let input_lower = input.user_input.to_lowercase();
            let back_lower = input.back.to_lowercase();
            let result = if back_lower.contains(&input_lower) || input_lower.contains(&back_lower) {
                "pass"
            } else {
                "fail"
            };
            Json(serde_json::json!({"result": result}))
        }
    }
}

// ── Card Status Handlers ──

#[derive(Deserialize)]
pub struct UpdateStatusInput {
    pub user_id: String,
    pub card_id: String,
    pub status: String,
}

#[derive(Deserialize)]
pub struct BatchStatusInput {
    pub user_id: String,
    pub card_ids: Vec<String>,
    pub status: String,
}

/// PATCH /api/cards/status — 更新卡片状态 (active/pending/skipped/archived)
async fn cards_status_handler(
    headers: HeaderMap,
    Json(input): Json<UpdateStatusInput>,
) -> Json<serde_json::Value> {
    tracing::info!("cards_status_handler: user_id={}", input.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    match card_engine::card_repository::update_card_status(&conn, &input.card_id, &input.status) {
        Ok(_) => Json(serde_json::json!({"status": "ok"})),
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

/// PATCH /api/cards/batch-status — 批量更新卡片状态
async fn cards_batch_status_handler(
    headers: HeaderMap,
    Json(input): Json<BatchStatusInput>,
) -> Json<serde_json::Value> {
    tracing::info!("cards_batch_status_handler: user_id={}", input.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    match card_engine::card_repository::batch_update_status(&conn, &input.card_ids, &input.status) {
        Ok(_) => Json(serde_json::json!({
            "updated": input.card_ids.len(),
            "status": "ok",
        })),
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

async fn ws_upgrade(ws: WebSocketUpgrade) -> impl axum::response::IntoResponse {
    ws.on_upgrade(crate::ws::handle_ws)
}

/// GET /api/cards/all — 获取用户所有卡片 (含搜索过滤)
#[derive(Deserialize)]
pub struct AllCardsQuery {
    pub user_id: String,
    pub q: Option<String>,         // 搜索关键词 (匹配 front/back)
    pub state: Option<i32>,        // 按 FSRS state 过滤
    pub subject: Option<String>,   // 按科目过滤 (替代 domain)
    pub sort: Option<String>,      // "front" | "created" | "state" | "due"
}

/// GET /api/cards/all — 获取用户所有 active 卡片（支持过滤、搜索、排序）
/// 请求参数: ?user_id=str&subject=str&state=int&q=str&sort=str
///    subject: 按科目过滤 (chinese/english/math/...)
///    state:   FSRS 状态过滤 (0=new, 1=learning, 2=review)
///    q:       搜索关键词（匹配 front/back）
///    sort:    排序方式 (front/created/state/due)
/// 响应: {"cards": [{id,front,back,domain,card_type,state,difficulty,due,reps,...}], ...}
async fn cards_all_handler(
    headers: HeaderMap,
    Query(query): Query<AllCardsQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("cards_all_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    let mut sql = String::from(
        "SELECT c.id, c.user_id, c.front, c.back, c.domain, c.subject, c.card_type, c.source_sentence,
                c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                lrev.reviewed_at, lrev.rating,
                c.conversation_id
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         LEFT JOIN (
            SELECT card_id, MAX(reviewed_at) as last_reviewed_at
            FROM review_log GROUP BY card_id
         ) lr ON c.id = lr.card_id
         LEFT JOIN review_log lrev
            ON lrev.card_id = lr.card_id AND lrev.reviewed_at = lr.last_reviewed_at
         WHERE c.user_id = ?1 AND cm.status = 'active'"
    );
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(query.user_id.clone())];

    // 按科目过滤
    if let Some(ref subject) = query.subject {
        params.push(Box::new(subject.clone()));
        sql.push_str(&format!(" AND c.subject = ?{}", params.len()));
    }

    // 按状态过滤
    if let Some(state) = query.state {
        params.push(Box::new(state));
        sql.push_str(&format!(" AND cm.state = ?{}", params.len()));
    }

    // 搜索
    if let Some(ref q) = query.q {
        if !q.is_empty() {
            let pattern = format!("%{}%", q);
            params.push(Box::new(pattern.clone()));
            sql.push_str(&format!(" AND (c.front LIKE ?{} OR c.back LIKE ?{})", params.len(), params.len()));
        }
    }

    // 隐藏非 vocabulary 的预制卡（对话生成卡不受影响）
    sql.push_str(" AND NOT (c.conversation_id IS NULL AND c.card_type != 'vocabulary')");

    // 排序
    match query.sort.as_deref() {
        Some("front") => sql.push_str(" ORDER BY c.front ASC"),
        Some("created") => sql.push_str(" ORDER BY c.created_at DESC"),
        Some("due") => sql.push_str(" ORDER BY cm.due ASC"),
        _ => sql.push_str(" ORDER BY cm.state ASC, cm.due ASC"), // 默认: 按状态+到期排序
    }

    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB prepare: {}", e)})),
    };
    let rows: Vec<serde_json::Value> = match stmt.query_map(param_refs.as_slice(), |row| Ok(serde_json::json!({
        "id": row.get::<_, String>(0)?,
        "user_id": row.get::<_, String>(1)?,
        "front": row.get::<_, String>(2)?,
        "back": row.get::<_, String>(3)?,
        "domain": row.get::<_, Option<String>>(4)?,
        "subject": row.get::<_, Option<String>>(5)?,
        "card_type": row.get::<_, String>(6)?,
        "source_sentence": row.get::<_, Option<String>>(7)?,
        "created_at": row.get::<_, i64>(8)?,
        "state": row.get::<_, i32>(9)?,
        "difficulty": row.get::<_, f64>(10)?,
        "due": row.get::<_, i64>(11)?,
        "reps": row.get::<_, i32>(12)?,
        "lapses": row.get::<_, i32>(13)?,
        "last_reviewed_at": row.get::<_, Option<i64>>(14)?,
        "last_review_quality": row.get::<_, Option<i32>>(15)?,
        "conversation_id": row.get::<_, Option<String>>(16)?,
    }))) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return Json(serde_json::json!({"error": format!("DB query: {}", e)})),
    };

    // 聚合统计数据
    let total = rows.len();
    let states = [0, 1, 2, 3];
    let state_counts: Vec<i32> = states.iter().map(|&s| {
        rows.iter().filter(|r| r["state"].as_i64() == Some(s as i64)).count() as i32
    }).collect();

    // 领域列表
    let domains: Vec<String> = query_vec(
        &conn,
        "SELECT DISTINCT domain FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND c.domain IS NOT NULL AND cm.status = 'active' ORDER BY domain",
        rusqlite::params![query.user_id], |row| row.get(0),
    ).unwrap_or_default();

    Json(serde_json::json!({
        "cards": rows,
        "total": total,
        "state_counts": {
            "new": state_counts[0],
            "learning": state_counts[1],
            "review": state_counts[2],
            "relearning": state_counts[3],
        },
        "domains": domains,
    }))
}

// ── Cards by Plan (grouped by conversation_plans) ──

#[derive(Deserialize)]
pub struct CardsByPlanQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    pub sort: Option<String>,
}

/// GET /api/cards/by-plan — 按 conversation_plan 分组返回卡片
/// 遍历用户的全部 conversation_plans，对每个 plan 用 conversation_id 取对应卡片
async fn cards_by_plan_handler(
    headers: HeaderMap,
    Query(query): Query<CardsByPlanQuery>,
) -> Json<serde_json::Value> {
    eprintln!("[MARK] cards_by_plan_handler ENTER");
    tracing::info!("cards_by_plan_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 1. 获取用户所有 plan
    let mut stmt = match conn.prepare(
        "SELECT id, conversation_id, goal, grade_band FROM conversation_plans WHERE user_id = ?1 ORDER BY created_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB prepare: {}", e)})),
    };

    let mut plans: Vec<serde_json::Value> = Vec::new();
    let rows = match stmt.query_map(rusqlite::params![query.user_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    }) {
        Ok(r) => r,
        Err(e) => return Json(serde_json::json!({"error": format!("DB query plan: {}", e)})),
    };

    for row in rows.flatten() {
        let (plan_id, conv_id, goal, grade_band) = row;

        // 惰性加载：仅当指定了 conversation_id 时才加载该 plan 的卡片
        let load_cards = query.conversation_id.as_deref() == Some(&conv_id);

        let (cards, effective_count): (Vec<serde_json::Value>, usize) = if load_cards {
            let page_size = query.limit.unwrap_or(20).max(1).min(500);
            let page_offset = query.offset.unwrap_or(0).max(0);
            let order_col = match query.sort.as_deref() {
                Some("front") | None => "c.front ASC",
                Some("due") => "cm.due ASC",
                Some("created") => "c.created_at DESC",
                Some(s) => s, // raw passthrough for flexibility
            };
            let sql = format!(
                "SELECT c.id, c.user_id, c.front, c.back, c.domain, c.subject, c.card_type, c.source_sentence,
                        c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                        lrev.reviewed_at, lrev.rating,
                        c.conversation_id
                 FROM cards c
                 JOIN card_memory cm ON c.id = cm.card_id
                 LEFT JOIN (
                    SELECT card_id, MAX(reviewed_at) as last_reviewed_at
                    FROM review_log GROUP BY card_id
                 ) lr ON c.id = lr.card_id
                 LEFT JOIN review_log lrev
                    ON lrev.card_id = lr.card_id AND lrev.reviewed_at = lr.last_reviewed_at
                 WHERE c.conversation_id = '{}' AND c.user_id = '{}' AND cm.status = 'active'
                 ORDER BY {}
                 LIMIT {} OFFSET {}",
                conv_id.replace('\'', "''"),
                query.user_id.replace('\'', "''"),
                order_col, page_size, page_offset,
            );
            let loaded: Vec<serde_json::Value> = match conn.prepare(&sql) {
                Ok(mut stmt) => stmt.query_map([], |row| {
                    Ok(serde_json::json!({
                        "id": row.get::<_, String>(0)?,
                        "user_id": row.get::<_, String>(1)?,
                        "front": row.get::<_, String>(2)?,
                        "back": row.get::<_, String>(3)?,
                        "domain": row.get::<_, Option<String>>(4)?,
                        "card_type": row.get::<_, String>(6)?,
                        "source_sentence": row.get::<_, Option<String>>(7)?,
                        "created_at": row.get::<_, i64>(8)?,
                        "state": row.get::<_, i32>(9)?,
                        "difficulty": row.get::<_, f64>(10)?,
                        "due": row.get::<_, i64>(11)?,
                        "reps": row.get::<_, i32>(12)?,
                        "lapses": row.get::<_, i32>(13)?,
                        "last_reviewed_at": row.get::<_, Option<i64>>(14)?,
                        "last_review_quality": row.get::<_, Option<i32>>(15)?,
                        "conversation_id": row.get::<_, Option<String>>(16)?,
                    }))
                }).unwrap().filter_map(|r| r.ok()).collect(),
                Err(_) => vec![],
            };
            let count = loaded.len();
            (loaded, count)
        } else {
            let count: usize = conn.query_row(
                "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.conversation_id = ?1 AND c.user_id = ?2 AND cm.status = 'active'",
                rusqlite::params![conv_id, query.user_id],
                |row| row.get(0),
            ).unwrap_or(0);
            (vec![], count)
        };

        plans.push(serde_json::json!({
            "id": plan_id,
            "goal": goal,
            "grade_band": grade_band,
            "conversation_id": conv_id,
            "cards": cards,
            "card_count": effective_count,
        }));
    }

    let total_cards: usize = plans.iter()
        .map(|p| p["card_count"].as_u64().unwrap_or(0) as usize)
        .sum();
    let cards_loaded = query.conversation_id.is_some();
    tracing::info!("cards_by_plan_handler: user_id={}, plans={}, total_cards={}, loaded_cards={}, conv_filter={:?}",
        query.user_id, plans.len(), total_cards, cards_loaded, query.conversation_id);

    eprintln!("[MARK] cards_by_plan_handler EXIT");

    Json(serde_json::json!({
        "plans": plans,
        "total_plans": plans.len(),
        "has_more": cards_loaded && query.limit.is_some(),
    }))
}

/// GET /api/cards/search — 搜索卡片的 front/back，支持分页
#[derive(Deserialize)]
pub struct CardsSearchQuery {
    pub user_id: String,
    pub q: String,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

async fn cards_search_handler(
    headers: HeaderMap,
    Query(query): Query<CardsSearchQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("cards_search_handler: user_id={}, q={}", query.user_id, query.q);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    if query.q.trim().is_empty() {
        return Json(serde_json::json!({"cards": [], "total": 0, "has_more": false}));
    }

    let conn = crate::db_pool::get_conn();
    let page_size = query.limit.unwrap_or(20).max(1).min(200);
    let page_offset = query.offset.unwrap_or(0).max(0);
    let like = format!("%{}%", query.q.replace('%', "\\%").replace('_', "\\_"));

    let sql = format!(
        "SELECT c.id, c.user_id, c.front, c.back, c.domain, c.subject, c.card_type,
                c.source_sentence, c.created_at, c.conversation_id,
                cm.state, cm.reps, cm.lapses, cm.difficulty, cm.due
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = '{}'
           AND cm.status IN ('active', 'pending')
           AND (c.front LIKE '{}' OR c.back LIKE '{}' OR c.source_sentence LIKE '{}')
         ORDER BY c.front ASC
         LIMIT {} OFFSET {}",
        query.user_id.replace('\'', "''"),
        like.replace('\'', "''"),
        like.replace('\'', "''"),
        like.replace('\'', "''"),
        page_size, page_offset,
    );

    let total_sql = format!(
        "SELECT COUNT(*) FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = '{}'
           AND cm.status IN ('active', 'pending')
           AND (c.front LIKE '{}' OR c.back LIKE '{}' OR c.source_sentence LIKE '{}')",
        query.user_id.replace('\'', "''"),
        like.replace('\'', "''"),
        like.replace('\'', "''"),
        like.replace('\'', "''"),
    );

    let total: i64 = conn.query_row(&total_sql, [], |row| row.get(0)).unwrap_or(0);

    let cards: Vec<serde_json::Value> = match conn.prepare(&sql) {
        Ok(mut stmt) => stmt.query_map([], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "user_id": row.get::<_, String>(1)?,
                "front": row.get::<_, String>(2)?,
                "back": row.get::<_, String>(3)?,
                "domain": row.get::<_, Option<String>>(4)?,
                "card_type": row.get::<_, String>(6)?,
                "source_sentence": row.get::<_, Option<String>>(7)?,
                "created_at": row.get::<_, i64>(8)?,
                "conversation_id": row.get::<_, Option<String>>(9)?,
                "state": row.get::<_, i32>(10)?,
                "reps": row.get::<_, i32>(11)?,
                "lapses": row.get::<_, i32>(12)?,
                "difficulty": row.get::<_, f64>(13)?,
                "due": row.get::<_, i64>(14)?,
            }))
        }).unwrap().filter_map(|r| r.ok()).collect(),
        Err(_) => vec![],
    };

    Json(serde_json::json!({
        "cards": cards,
        "total": total,
        "has_more": (page_offset as usize + cards.len()) < total as usize,
    }))
}

/// 历史查询
#[derive(Deserialize)]
pub struct HistoryQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub limit: Option<i64>,
    /// "only"=仅已删除, "true"=全部, 默认=仅活跃
    pub include_deleted: Option<String>,
    /// 分页偏移（仅 conversation_id 模式有效），默认 0
    pub offset: Option<i64>,
}

/// GET /api/cards/{card_id}/last-review — 最近一次考试详情
async fn cards_last_review_handler(
    headers: HeaderMap,
    Query(query): Query<DueQuery>,
    Path(card_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("cards_last_review_handler: card_id={}, user_id={}", card_id, query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    match conn.query_row(
        "SELECT id, rating, verification_type, verification_result, details_json, reviewed_at
         FROM review_log WHERE card_id = ?1
         ORDER BY reviewed_at DESC LIMIT 1",
        rusqlite::params![card_id],
        |row| Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "rating": row.get::<_, i32>(1)?,
            "verification_type": row.get::<_, String>(2)?,
            "verification_result": row.get::<_, String>(3)?,
            "details": row.get::<_, Option<String>>(4)?,
            "reviewed_at": row.get::<_, i64>(5)?,
        })),
    ) {
        Ok(data) => {
            // 如果 details_json 存在，解析为数组
            let mut result = data;
            if let Some(details_str) = result.get("details").and_then(|v| v.as_str()) {
                if let Ok(details) = serde_json::from_str::<serde_json::Value>(details_str) {
                    // result is always a JSON object (built from json!({...}))
                    if let Some(obj) = result.as_object_mut() {
                        obj.insert("details".to_string(), details);
                    }
                }
            }
            Json(result)
        }
        Err(_) => Json(serde_json::json!({"error": "No review found"})),
    }
}

/// GET /api/history — 获取对话历史
async fn history_handler(
    headers: HeaderMap,
    Query(query): Query<HistoryQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("history_handler: user_id={}", query.user_id);

    // 鉴权：验证 Bearer token
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();
    let limit = query.limit.unwrap_or(50).min(200);

    if let Some(conv_id) = &query.conversation_id {
        // 查询指定对话的轮次（支持分页：offset=0 为最新）
        let offset = query.offset.unwrap_or(0).max(0);
        let mut stmt = conn.prepare(
            "SELECT id, role, content, created_at
             FROM conversation_turns WHERE conversation_id = ?1
             ORDER BY created_at DESC LIMIT ?2 OFFSET ?3"
        ).unwrap();
        let turns: Vec<serde_json::Value> = stmt.query_map(
            rusqlite::params![conv_id, limit, offset],
            |row| Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "role": row.get::<_, String>(1)?,
                "content": row.get::<_, String>(2)?,
                "created_at": row.get::<_, String>(3)?,
            }))
        ).unwrap().filter_map(|r| r.ok()).collect();
        // 获取总轮次数（用于前端判断"还有更多"）
        let total: i64 = conn.query_row(
            "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id = ?1",
            rusqlite::params![conv_id],
            |row| row.get(0),
        ).unwrap_or(0);
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "turns": turns,
            "count": turns.len(),
            "total": total,
        }));
    }

    // 查询用户的所有对话列表（标题：有 plan 的显示 goal，否则显示第一条消息）
    // include_deleted: "only"=仅已删除, "true"=全部, 默认=仅活跃
    let deleted_filter = match query.include_deleted.as_deref() {
        Some("only") => " AND c.deleted_at IS NOT NULL",
        Some("true") => "",
        _ => " AND c.deleted_at IS NULL",
    };
    let sql = format!(
        "SELECT c.id, c.turn_count, c.started_at, c.deleted_at,
                (SELECT content FROM conversation_turns t
                 WHERE t.conversation_id = c.id AND t.role = 'user'
                 ORDER BY t.created_at ASC LIMIT 1) as first_msg,
                (SELECT cp.goal FROM conversation_plans cp WHERE cp.conversation_id = c.id LIMIT 1) as plan_goal
         FROM conversations c
         WHERE c.user_id = ?1
           AND c.turn_count > 0
           {} ORDER BY c.started_at DESC LIMIT ?2",
        deleted_filter
    );
    let mut stmt = conn.prepare(&sql).unwrap();
    let conversations: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![query.user_id, limit],
        |row| {
            let first_msg: Option<String> = row.get(4).ok().flatten();
            let plan_goal: Option<String> = row.get(5).ok().flatten();
            let title = plan_goal
                .filter(|g| !g.is_empty())
                .map(|g| format!("K12: {}", g))
                .or_else(|| first_msg.as_deref()
                    .map(|s| if s.len() > 50 { format!("{}...", &s[..50]) } else { s.to_string() }))
                .unwrap_or_else(|| "新对话".to_string());
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "turn_count": row.get::<_, i32>(1)?,
                "started_at": row.get::<_, String>(2)?,
                "deleted_at": row.get::<_, Option<String>>(3)?,
                "title": title,
            }))
        }
    ).unwrap().filter_map(|r| r.ok()).collect();
    Json(serde_json::json!({
        "user_id": query.user_id,
        "conversations": conversations,
        "count": conversations.len(),
    }))
}

// ════════════════════════════════════════════
// 对话管理 — 软删除 / 恢复 / 彻底删除
// ════════════════════════════════════════════

#[derive(Deserialize)]
struct ConversationActionQuery {
    user_id: String,
}

/// DELETE /api/conversations/{conv_id} — 软删除对话
async fn conversation_delete_handler(
    headers: HeaderMap,
    Path(conv_id): Path<String>,
    Query(query): Query<ConversationActionQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("conversation_delete_handler: conv_id={}", conv_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().timestamp();
    match conn.execute(
        "UPDATE conversations SET deleted_at = ?1 WHERE id = ?2 AND user_id = ?3 AND deleted_at IS NULL",
        rusqlite::params![now, conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found or already deleted"})),
        Ok(_) => {
            Json(serde_json::json!({"status": "ok", "deleted_at": now}))
        },
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

/// POST /api/conversations/{conv_id}/restore — 恢复已删除对话
async fn conversation_restore_handler(
    headers: HeaderMap,
    Path(conv_id): Path<String>,
    Query(query): Query<ConversationActionQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("conversation_restore_handler: conv_id={}", conv_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE conversations SET deleted_at = NULL WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NOT NULL",
        rusqlite::params![conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found or not deleted"})),
        Ok(_) => {
            Json(serde_json::json!({"status": "ok"}))
        },
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

/// DELETE /api/conversations/{conv_id}/permanent — 物理删除（不可恢复）
async fn conversation_permanent_delete_handler(
    headers: HeaderMap,
    Path(conv_id): Path<String>,
    Query(query): Query<ConversationActionQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("conversation_permanent_delete_handler: conv_id={}", conv_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    // 级联删除 conversation_turns
    let _ = conn.execute(
        "DELETE FROM conversation_turns WHERE conversation_id = ?1",
        rusqlite::params![conv_id],
    );
    match conn.execute(
        "DELETE FROM conversations WHERE id = ?1 AND user_id = ?2",
        rusqlite::params![conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found"})),
        Ok(_) => Json(serde_json::json!({"status": "ok"})),
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

/// GET /api/user/:user_id/profile — 用户统计 + 成就
async fn profile_handler(
    headers: axum::http::HeaderMap,
    Path(user_id): Path<String>,
) -> impl axum::response::IntoResponse {
    tracing::info!("profile_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();

    // Verify auth: caller must be the user themselves
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return (axum::http::StatusCode::UNAUTHORIZED, axum::Json(serde_json::json!({"error": "unauthorized"})));
    }

    let total_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND cm.status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let total_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id = c.id WHERE c.user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let domains_covered: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT c.domain) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND c.domain IS NOT NULL AND cm.status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let today_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id = c.id WHERE c.user_id = ?1 AND r.reviewed_at > ?2",
        rusqlite::params![user_id, chrono::Utc::now().timestamp() - 86400],
        |row| row.get(0),
    ).unwrap_or(0);

    // 每日定时成就检测（24h 冷却）
    crate::achievement_engine::check_daily(&conn, &user_id);

    let mut stmt = conn.prepare(
        "SELECT achievement_key, name, icon, tier, source, unlocked_at \
         FROM achievements WHERE user_id = ?1 ORDER BY unlocked_at DESC"
    ).unwrap();
    let engine = crate::achievement_engine::get();
    let achievements: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![user_id],
        |row| {
            let key: String = row.get(0)?;
            let tier: String = row.get::<_, Option<String>>(3)?.unwrap_or_else(|| "bronze".to_string());
            let source: String = row.get::<_, Option<String>>(4)?.unwrap_or_default();
            let def = engine.find_def(&key);
            Ok(serde_json::json!({
                "key": key,
                "name": row.get::<_, String>(1)?,
                "icon": row.get::<_, String>(2)?,
                "tier": tier,
                "category": if source.is_empty() { def.map(|d| d.category.clone()).unwrap_or_default() } else { source },
                "color": def.map(|d| d.color.clone()).unwrap_or_else(|| "#CD7F32".to_string()),
                "description": def.map(|d| d.description.clone()).unwrap_or_default(),
                "unlocked_at": row.get::<_, String>(5)?,
            }))
        })
    .unwrap().filter_map(|r| r.ok()).collect();

    let display_name: Option<String> = conn.query_row(
        "SELECT display_name FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    let real_name_raw: Option<String> = conn.query_row(
        "SELECT real_name FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    let phone_raw: Option<String> = conn.query_row(
        "SELECT phone FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    // Decrypt PII fields — now stored as AES-256-GCM
    let real_name = real_name_raw.as_ref().map(|v| {
        if crate::encryption::is_encrypted(v) { crate::encryption::decrypt(v) } else { v.clone() }
    });
    let phone = phone_raw.as_ref().map(|v| {
        if crate::encryption::is_encrypted(v) { crate::encryption::decrypt(v) } else { v.clone() }
    });

    // CEFR 词汇统计
    let catalog_stats = chat_engine::word_bank::get_cefr_catalog_stats();
    let mut mastered_by_level: HashMap<String, u64> = HashMap::new();

    // 查询用户的 vocabulary 卡片中已掌握的 (state=2)，按 CEFR 等级分组
    if let Ok(mut stmt) = conn.prepare(
        "SELECT c.front FROM cards c JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND c.card_type = 'vocabulary' AND cm.state = 2 AND cm.status = 'active'"
    ) {
        if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| row.get::<_, String>(0)) {
            for front in rows.flatten() {
                if let Some(level) = chat_engine::word_bank::lookup_cefr(&front) {
                    *mastered_by_level.entry(level).or_insert(0) += 1;
                }
            }
        }
    }

    let cefr_stats: Vec<serde_json::Value> = catalog_stats.into_iter().map(|s| {
        let mastered = mastered_by_level.get(&s.level).copied().unwrap_or(0);
        serde_json::json!({
            "level": s.level,
            "max_count": s.total,
            "count": mastered,
        })
    }).collect();

    (axum::http::StatusCode::OK, axum::Json(serde_json::json!({
        "user_id": user_id,
        "display_name": display_name,
        "real_name": real_name,
        "phone": phone,
        "stats": {
            "total_cards": total_cards,
            "total_reviews": total_reviews,
            "streak_days": streak_days,
            "domains_covered": domains_covered,
            "today_reviews": today_reviews,
        },
        "achievements": achievements,
        "cefr_stats": cefr_stats,
    })))
}

// ── Achievements All (Phase 3: 按 category 分组 + 进度) ──

async fn achievements_all_handler(
    headers: axum::http::HeaderMap,
    Path(user_id): Path<String>,
) -> impl axum::response::IntoResponse {
    tracing::info!("achievements_all_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();

    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return (axum::http::StatusCode::UNAUTHORIZED,
            axum::Json(serde_json::json!({"error": "unauthorized"})));
    }

    let engine = crate::achievement_engine::get();
    let ctx = crate::achievement_engine::build_context(&conn, &user_id);

    // 持久化新解锁的成就（使用完整 ctx，补录之前因不完整 ctx 而漏掉的成就）
    let _new_achievements = engine.check_and_persist(&conn, &ctx);

    // 获取已解锁的成就
    let unlocked: Vec<String> = {
        let mut stmt = conn.prepare(
            "SELECT achievement_key, unlocked_at FROM achievements WHERE user_id = ?1"
        ).unwrap();
        stmt.query_map(rusqlite::params![&user_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).unwrap()
        .filter_map(|r| r.ok())
        .collect::<Vec<_>>()
        .into_iter()
        .map(|(k, _)| k)
        .collect()
    };

    // 已解锁成就的时间戳映射
    let unlocked_at_map: std::collections::HashMap<String, String> = {
        let mut stmt = conn.prepare(
            "SELECT achievement_key, unlocked_at FROM achievements WHERE user_id = ?1"
        ).unwrap();
        stmt.query_map(rusqlite::params![&user_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).unwrap()
        .filter_map(|r| r.ok())
        .collect()
    };

    let unlocked_set: std::collections::HashSet<&str> =
        unlocked.iter().map(|s| s.as_str()).collect();

    // 按 category 分组
    let category_order = ["seed", "consistency", "knowledge", "exploration", "mastery", "special"];
    let category_labels: std::collections::HashMap<&str, &str> = [
        ("seed", "启程"), ("consistency", "坚持"), ("knowledge", "博学"),
        ("exploration", "探索"), ("mastery", "精进"), ("special", "特殊"),
    ].into_iter().collect();

    let mut categories: Vec<serde_json::Value> = Vec::new();

    // tier 排序优先级：铜→银→金→铂→钻
    let tier_priority = |t: &str| -> u8 {
        match t {
            "bronze" => 0,
            "silver" => 1,
            "gold" => 2,
            "platinum" => 3,
            "diamond" => 4,
            _ => 5,
        }
    };

    for cat_key in &category_order {
        let mut defs_in_cat: Vec<&shared_types::growth::AchievementDef> = engine.definitions()
            .iter().filter(|d| d.category == *cat_key).collect();
        if defs_in_cat.is_empty() { continue; }
        defs_in_cat.sort_by_key(|d| tier_priority(&d.tier));

        let items: Vec<serde_json::Value> = defs_in_cat.iter().map(|def| {
            let is_unlocked = unlocked_set.contains(def.id.as_str());
            let unlocked_at = unlocked_at_map.get(&def.id).cloned();

            // 计算进度
            let (progress_pct, progress_label) = compute_progress(def, &ctx);

            serde_json::json!({
                "id": def.id,
                "name": def.name.zh(),
                "name_en": if def.name.en().is_empty() { serde_json::Value::Null } else { serde_json::Value::String(def.name.en().to_string()) },
                "description": def.description.zh(),
                "description_en": if def.description.en().is_empty() { serde_json::Value::Null } else { serde_json::Value::String(def.description.en().to_string()) },
                "icon": def.icon,
                "color": def.color,
                "tier": def.tier,
                "hidden": def.hidden,
                "unlocked": is_unlocked,
                "unlocked_at": unlocked_at,
                "progress_pct": progress_pct,
                "progress_label": progress_label,
            })
        }).collect();

        categories.push(serde_json::json!({
            "category": cat_key,
            "label": category_labels.get(cat_key).unwrap_or(&cat_key),
            "achievements": items,
        }));
    }

    (axum::http::StatusCode::OK, axum::Json(serde_json::json!({
        "user_id": user_id,
        "categories": categories,
    })))
}

/// 计算单个成就的进度百分比和标签
fn compute_progress(def: &shared_types::growth::AchievementDef, ctx: &shared_types::growth::AchievementContext) -> (f64, String) {
    if def.conditions.is_empty() {
        return (0.0, "—".into());
    }

    let mut ratios: Vec<f64> = Vec::new();
    let mut labels: Vec<String> = Vec::new();

    for cond in &def.conditions {
        let actual = match cond.metric.as_str() {
            // 已有
            "total_cards" => ctx.total_cards as f64,
            "total_reviews" => ctx.total_reviews as f64,
            "streak_days" => ctx.streak_days as f64,
            "domains_covered" => ctx.domains_covered as f64,
            "plans_completed" => ctx.plans_completed as f64,
            "conversations_completed" => ctx.conversations_completed as f64,
            // Phase 5 新增
            "hard_cards_count" => ctx.hard_cards_count as f64,
            "recent_accuracy_20" => ctx.recent_accuracy_20,
            "recent_accuracy_50" => ctx.recent_accuracy_50,
            "recent_accuracy_100" => ctx.recent_accuracy_100,
            "weekend_streak" => ctx.weekend_streak as f64,
            "night_sessions" => ctx.night_sessions as f64,
            "early_sessions" => ctx.early_sessions as f64,
            "hard_perfect_streak" => ctx.hard_perfect_streak as f64,
            "perfect_session_10" => ctx.perfect_session_10 as f64,
            "mature_cards" => ctx.mature_cards as f64,
            "learning_cards" => ctx.learning_cards as f64,
            "no_skip_streak" => ctx.no_skip_streak as f64,
            "languages_count" => ctx.languages_count as f64,
            "cards_in_1h" => ctx.cards_in_1h as f64,
            "days_since_last_review" => ctx.days_since_last_review as f64,
            "reviews_today" => ctx.reviews_today as f64,
            "days_since_reg" => ctx.days_since_reg as f64,
            "subjects_count" => ctx.subjects_count as f64,
            _ => 0.0,
        };
        let ratio = if cond.value > 0.0 {
            (actual / cond.value).min(1.0)
        } else {
            if actual >= 0.0 { 1.0 } else { 0.0 }
        };
        ratios.push(ratio);

        let metric_label = match cond.metric.as_str() {
            "total_cards" => "张卡片",
            "total_reviews" => "次复习",
            "streak_days" => "天",
            "domains_covered" => "个领域",
            "plans_completed" => "个计划",
            "conversations_completed" => "次对话",
            "hard_cards_count" => "张困难卡",
            "recent_accuracy_20" => "%准确率(20)",
            "recent_accuracy_50" => "%准确率(50)",
            "recent_accuracy_100" => "%准确率(100)",
            "weekend_streak" => "周",
            "night_sessions" => "次深夜",
            "early_sessions" => "次早起",
            "hard_perfect_streak" => "次全对",
            "perfect_session_10" => "次",
            "mature_cards" => "张成熟卡",
            "learning_cards" => "张学习卡",
            "no_skip_streak" => "天",
            "languages_count" => "种语言",
            "cards_in_1h" => "张",
            "days_since_last_review" => "天",
            "reviews_today" => "次",
            "days_since_reg" => "天",
            "subjects_count" => "个学科",
            _ => "",
        };
        labels.push(format!("{}/{} {}", actual as u64, cond.value as u64, metric_label));
    }

    let overall = match def.condition_logic.to_uppercase().as_str() {
        "OR" => ratios.iter().cloned().fold(0.0_f64, f64::max),
        _ => ratios.iter().cloned().fold(1.0_f64, f64::min), // AND
    };

    let label = labels.join(" | ");
    (overall, label)
}

// ── Display Name ──

async fn update_display_name_handler(
    Path(user_id): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    tracing::info!("update_display_name_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let name = input.get("display_name").and_then(|v| v.as_str()).unwrap_or("");
    if name.trim().is_empty() {
        return Json(serde_json::json!({"error": "display_name cannot be empty"}));
    }
    match conn.execute(
        "UPDATE users SET display_name = ?1 WHERE id = ?2",
        rusqlite::params![name.trim(), user_id],
    ) {
        Ok(_) => Json(serde_json::json!({"status": "ok", "display_name": name.trim()})),
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

// ════════════════════════════════════════════
// User Preferences
// ════════════════════════════════════════════

async fn preferences_get_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("preferences_get_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT key, value FROM user_preferences WHERE user_id = ?1"
    ).unwrap();
    let mut prefs = serde_json::Map::new();
    for row in stmt.query_map(rusqlite::params![user_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }).unwrap().filter_map(|r| r.ok()) {
        prefs.insert(row.0, serde_json::Value::String(row.1));
    }
    Json(serde_json::Value::Object(prefs))
}

async fn preferences_put_handler(
    Path(user_id): Path<String>,
    Json(input): Json<HashMap<String, String>>,
) -> Json<serde_json::Value> {
    tracing::info!("preferences_put_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().timestamp();
    for (key, value) in &input {
        // 正规化日期：纯日期 "YYYY-MM-DD" → RFC3339
        let value = if key == "subscription_expires" && value.len() == 10 && value.as_bytes().get(4) == Some(&b'-') {
            format!("{}T00:00:00Z", value)
        } else {
            value.clone()
        };
        let _ = conn.execute(
            "INSERT INTO user_preferences (user_id, key, value, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(user_id, key) DO UPDATE SET value = ?3, updated_at = ?4",
            rusqlite::params![user_id, key, value, now],
        );
    }
    Json(serde_json::json!({"status": "ok"}))
}

// ── Avatar ──

static AVATAR_DIR: OnceLock<String> = OnceLock::new();

pub fn set_avatar_dir(dir: &str) {
    let _ = AVATAR_DIR.set(dir.to_string());
}

fn avatar_dir() -> &'static str {
    AVATAR_DIR.get().map(|s| s.as_str()).unwrap_or("data/avatars")
}

async fn avatar_upload_handler(
    Path(user_id): Path<String>,
    mut multipart: axum::extract::Multipart,
) -> Json<serde_json::Value> {
    tracing::info!("avatar_upload_handler: user_id={}", user_id);

    use tokio::io::AsyncWriteExt;
    let _ = tokio::fs::create_dir_all(avatar_dir()).await;
    if let Ok(Some(field)) = multipart.next_field().await {
        let data = match field.bytes().await {
            Ok(d) => d,
            Err(e) => return Json(serde_json::json!({"error": format!("Read: {}", e)})),
        };
        if data.is_empty() || data.len() > 5 * 1024 * 1024 {
            return Json(serde_json::json!({"error": "File too large (max 5MB)"}));
        }
        let path = format!("{}/{}.png", avatar_dir(), user_id);
        let mut file = match tokio::fs::File::create(&path).await {
            Ok(f) => f,
            Err(e) => return Json(serde_json::json!({"error": format!("Write: {}", e)})),
        };
        if let Err(e) = file.write_all(&data).await {
            return Json(serde_json::json!({"error": format!("Write: {}", e)}));
        }
        return Json(serde_json::json!({"status": "ok", "url": format!("/api/user/{}/avatar", user_id)}));
    }
    Json(serde_json::json!({"error": "No file uploaded"}))
}

async fn avatar_get_handler(
    Path(user_id): Path<String>,
) -> Result<(axum::http::StatusCode, [(&'static str, &'static str); 1], Vec<u8>), (axum::http::StatusCode, &'static str)> {
    tracing::info!("avatar_get_handler: user_id={}", user_id);

    let path = format!("{}/{}.png", avatar_dir(), user_id);
    match tokio::fs::read(&path).await {
        Ok(data) => Ok((axum::http::StatusCode::OK, [("Content-Type", "image/png")], data)),
        Err(_) => Err((axum::http::StatusCode::NOT_FOUND, "No avatar")),
    }
}

// ════════════════════════════════════════════
// Learning Plan Handlers
// ════════════════════════════════════════════

async fn plans_list_handler(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    eprintln!("[MARK] plans_list_handler ENTER");

    let conn = crate::db_pool::get_conn();

    let (sql, param_val): (&str, String) = if let Some(conv_id) = params.get("conversation_id") {
        ("SELECT id, conversation_id, goal, subject, grade_band, '' as domain, 'structured' as mode, plan_content, created_at, updated_at FROM conversation_plans WHERE conversation_id = ?1 ORDER BY created_at DESC", conv_id.clone())
    } else if let Some(uid) = params.get("user_id") {
        ("SELECT id, conversation_id, goal, subject, grade_band, '' as domain, 'structured' as mode, plan_content, created_at, updated_at FROM conversation_plans WHERE user_id = ?1 ORDER BY created_at DESC", uid.clone())
    } else {
        return Json(serde_json::json!({"error": "user_id or conversation_id required"}));
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB: {}", e)})),
    };
    let mut plans: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![param_val], |row| {
        // plan_content: 完整计划结构（不含状态，状态在 user_plan_progress）
        let plan_content_raw: Option<String> = row.get(7).ok();
        let plan_id: String = row.get::<_, String>(0)?;
        let mut merged_plan = if let Some(content_str) = &plan_content_raw {
            if let Ok(content) = serde_json::from_str::<serde_json::Value>(content_str) {
                content
            } else {
                serde_json::Value::Null
            }
        } else {
            serde_json::Value::Null
        };

        // 从 user_plan_progress 合并状态到 stages[].tasks[].status
        if let Some(stages) = merged_plan.get_mut("stages").and_then(|s| s.as_array_mut()) {
            let progress_rows: Vec<(String, String)> = {
                let mut stmt = conn.prepare(
                    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
                ).unwrap_or_else(|_| panic!("prepare progress for plan {}", plan_id));
                stmt.query_map(rusqlite::params![plan_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect()).unwrap_or_default()
            };
            let progress_map: std::collections::HashMap<String, String> = progress_rows.into_iter().collect();

            for stage in stages.iter_mut() {
                if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                    for task in tasks {
                        let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                        let status = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                        task["status"] = serde_json::json!(status);
                    }
                }
            }
        }

        Ok(serde_json::json!({
            "id": plan_id,
            "conversation_id": row.get::<_, String>(1)?,
            "goal": row.get::<_, String>(2)?,
            "subject": row.get::<_, Option<String>>(3)?,
            "grade_band": row.get::<_, Option<String>>(4)?,
            "domain": row.get::<_, String>(5)?,
            "mode": row.get::<_, Option<String>>(6)?,
            "plan": merged_plan,
            "created_at": row.get::<_, i64>(8)?.to_string(),
            "updated_at": row.get::<_, i64>(9)?.to_string(),
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();

    // 为每个 plan 统计待复习卡片数（due <= now）
    let now_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    if let Ok(mut count_stmt) = conn.prepare(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id = cm.card_id WHERE c.conversation_id = ?1 AND cm.status = 'active' AND cm.due <= ?2"
    ) {
        for plan in &mut plans {
            if let Some(conv_id) = plan.get("conversation_id").and_then(|v| v.as_str()) {
                let count: i64 = count_stmt.query_row(rusqlite::params![conv_id, now_ts], |row| row.get(0)).unwrap_or(0);
                if let Some(obj) = plan.as_object_mut() {
                    obj.insert("due_card_count".to_string(), serde_json::json!(count));
                }
            }
        }
    }

    eprintln!("[MARK] plans_list_handler EXIT");
    Json(serde_json::json!({"plans": plans}))
}

// ════════════════════════════════════════════
// Phase 3 — Learning Report
// ════════════════════════════════════════════

async fn learning_report_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("learning_report_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();

    // 1. 所有学习计划进度
    let mut stmt_plans = conn.prepare(
        "SELECT plan_content, plan_content, goal, grade_band, subject, 'structured' as mode, updated_at FROM conversation_plans WHERE user_id = ?1 ORDER BY updated_at DESC"
    ).unwrap();
    let mut plans: Vec<serde_json::Value> = Vec::new();
    for row in stmt_plans.query_map(rusqlite::params![user_id], |row| {
        let pj: String = row.get(0)?;
        let pc: Option<String> = row.get(1)?;
        let goal: String = row.get(2)?;
        let grade_band: Option<String> = row.get(3)?;
        let subject: Option<String> = row.get(4)?;
        let mode: String = row.get(5)?;
        let updated: String = row.get(6)?;
        Ok((pj, pc, goal, grade_band, subject, mode, updated))
    }).unwrap().filter_map(|r| r.ok()) {
        let (pj, pc, goal, grade_band, subject, mode, updated) = row;
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pj) {
                    let mut total_tasks = 0u32;
                    let mut done_tasks = 0u32;
                    let mut current_stage = "";
                    // task_status 可能只有 task_status（被 apply_plan_mutations 改写后），
                    // 需要从 plan_content 中读取 stages 结构
                    let stages = plan.get("stages").and_then(|v| v.as_array());
                    if stages.map_or(true, |s| s.is_empty()) {
                        // 从 plan_content 取 stages
                        if let Some(ref pc_str) = pc {
                            let (ct, dd) = compute_plan_totals(pc_str, &plan);
                            total_tasks = ct;
                            done_tasks = dd;
                        }
                    } else {
                        // task_status 有 stages（旧格式）
                        for stage in stages.unwrap() {
                            let sname = stage["name"].as_str().unwrap_or("");
                            let sstatus = stage["status"].as_str().unwrap_or("pending");
                            if sstatus == "in_progress" && current_stage.is_empty() {
                                current_stage = sname;
                            }
                            if let Some(tasks) = stage["tasks"].as_array() {
                                for task in tasks {
                                    total_tasks += 1;
                                    if task["status"].as_str().unwrap_or("") == "done" {
                                        done_tasks += 1;
                                    }
                                }
                            }
                        }
                    }
            plans.push(serde_json::json!({
                "goal": goal,
                "grade_band": grade_band,
                "subject": subject,
                "mode": mode,
                "current_stage": current_stage,
                "total_tasks": total_tasks,
                "done_tasks": done_tasks,
                "progress_pct": if total_tasks > 0 { format!("{:.0}%", done_tasks as f64 / total_tasks as f64 * 100.0) } else { "0%".to_string() },
                "updated_at": updated,
            }));
        }
    }

    // 2. 成就统计
    let mut stmt = conn.prepare(
        "SELECT tier, COUNT(*) as cnt FROM achievements WHERE user_id = ?1 GROUP BY tier ORDER BY tier"
    ).unwrap();
    let tier_counts: serde_json::Value = stmt.query_map(rusqlite::params![user_id], |row| {
        Ok(serde_json::json!({
            "tier": row.get::<_, String>(0)?,
            "count": row.get::<_, i64>(1)?,
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();

    // 3. 学习统计
    let cards_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND cm.status = 'active'", rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    let reviews_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log WHERE card_id IN (SELECT c.id FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND cm.status = 'active')",
        rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    let conv_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id IN (SELECT id FROM conversations WHERE user_id = ?1 AND deleted_at IS NULL)",
        rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1", rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    // 4. 考核统计 —— bronze 成就数作为已通过任务的近似
    let bronze_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM achievements WHERE user_id = ?1 AND tier = 'bronze'",
        rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    Json(serde_json::json!({
        "plans": plans,
        "achievements_by_tier": tier_counts,
        "stats": {
            "total_cards": cards_total,
            "total_reviews": reviews_total,
            "total_conversation_turns": conv_total,
            "streak_days": streak_days,
        },
        "assessment": {
            "tasks_passed": bronze_count,
        }
    }))
}

/// 从 plan_content JSON 字符串中计算任务总数和完成数
/// status_map (task_status 的 task_status) 用于 reading 模式的状态覆盖
fn compute_plan_totals(plan_content_str: &str, task_status: &serde_json::Value) -> (u32, u32) {
    let mut total: u32 = 0;
    let mut done: u32 = 0;
    let status_map = task_status.get("task_status").and_then(|v| v.as_object());
    if let Ok(pc_v) = serde_json::from_str::<serde_json::Value>(plan_content_str) {
        if let Some(stages) = pc_v.get("stages").and_then(|v| v.as_array()) {
            for stage in stages {
                if let Some(tasks) = stage["tasks"].as_array() {
                    for task in tasks {
                        total += 1;
                        if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                            if status_map.and_then(|m| m.get(name)).and_then(|v| v.as_str()) == Some("done") {
                                done += 1;
                            }
                        } else if task["status"].as_str().unwrap_or("") == "done" {
                            done += 1;
                        }
                    }
                }
            }
        }
    }
    (total, done)
}

// ════════════════════════════════════════════
// Activity Heatmap API
// ════════════════════════════════════════════


async fn activity_handler(
    Path(user_id): Path<String>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    tracing::info!("activity_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let days: i64 = params.get("days").and_then(|v| v.parse().ok()).unwrap_or(90);

    // 每日复习数
    let mut stmt = conn.prepare(
        "SELECT DATE(r.reviewed_at, 'unixepoch') as d, COUNT(*) as cnt
         FROM review_log r JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1 AND r.reviewed_at >= ?2
         GROUP BY d ORDER BY d"
    ).unwrap();
    let since = chrono::Utc::now() - chrono::Duration::days(days);
    let since_ts = since.timestamp();
    let reviews_by_day: HashMap<String, i64> = stmt.query_map(
        rusqlite::params![user_id, since_ts],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    ).unwrap().filter_map(|r| r.ok()).collect();

    // 每日对话轮次数
    let mut stmt2 = conn.prepare(
        "SELECT DATE(created_at) as d, COUNT(*) as cnt
         FROM conversation_turns ct
         WHERE ct.conversation_id IN (SELECT id FROM conversations WHERE user_id = ?1)
           AND ct.created_at >= ?2
         GROUP BY d ORDER BY d"
    ).unwrap();
    let convs_by_day: HashMap<String, i64> = stmt2.query_map(
        rusqlite::params![user_id, since.to_rfc3339()],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    ).unwrap().filter_map(|r| r.ok()).collect();

    // 每日制卡数
    let mut stmt3 = conn.prepare(
        "SELECT DATE(created_at, 'unixepoch') as d, COUNT(*) as cnt
         FROM cards WHERE user_id = ?1 AND created_at >= ?2
         GROUP BY d ORDER BY d"
    ).unwrap();
    let cards_by_day: HashMap<String, i64> = stmt3.query_map(
        rusqlite::params![user_id, since_ts],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    ).unwrap().filter_map(|r| r.ok()).collect();

    // 生成日期序列 + 活动数据
    let mut days_data: Vec<serde_json::Value> = Vec::new();
    for i in (0..days).rev() {
        let date = (chrono::Utc::now() - chrono::Duration::days(i)).format("%Y-%m-%d").to_string();
        let reviews = reviews_by_day.get(&date).copied().unwrap_or(0);
        let convs = convs_by_day.get(&date).copied().unwrap_or(0);
        let cards = cards_by_day.get(&date).copied().unwrap_or(0);
        let score = reviews + convs + cards; // 活跃度
        days_data.push(serde_json::json!({
            "date": date,
            "score": score,
            "reviews": reviews,
            "conversations": convs,
            "cards": cards,
        }));
    }

    Json(serde_json::json!({"days": days_data}))
}

// ════════════════════════════════════════════
// Weekly Report API
// ════════════════════════════════════════════

async fn weekly_report_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("weekly_report_handler: user_id={}", user_id);

    let conn = crate::db_pool::get_conn();
    let week_ago = (chrono::Utc::now() - chrono::Duration::days(7)).to_rfc3339();
    let week_ago_ts = (chrono::Utc::now() - chrono::Duration::days(7)).timestamp();

    // 本周新增卡片
    let new_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id=cm.card_id WHERE c.user_id = ?1 AND c.created_at >= ?2 AND cm.status = 'active'",
        rusqlite::params![user_id, week_ago_ts], |row| row.get(0)
    ).unwrap_or(0);

    // 本周复习次数
    let weekly_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id = c.id WHERE c.user_id = ?1 AND r.reviewed_at >= ?2",
        rusqlite::params![user_id, week_ago_ts], |row| row.get(0)
    ).unwrap_or(0);

    // 本周对话轮次
    let weekly_convs: i64 = conn.query_row(
        "SELECT COUNT(*) FROM conversation_turns WHERE conversation_id IN (SELECT id FROM conversations WHERE user_id = ?1) AND created_at >= ?2",
        rusqlite::params![user_id, week_ago], |row| row.get(0)
    ).unwrap_or(0);

    // 本周新成就
    let weekly_achievements: i64 = conn.query_row(
        "SELECT COUNT(*) FROM achievements WHERE user_id = ?1 AND unlocked_at >= ?2",
        rusqlite::params![user_id, week_ago], |row| row.get(0)
    ).unwrap_or(0);

    // 当前计划进度
    let plan_goal: Option<String> = conn.query_row(
        "SELECT goal FROM conversation_plans WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 1",
        rusqlite::params![user_id], |row| row.get(0)
    ).ok();

    Json(serde_json::json!({
        "week_start": (chrono::Utc::now() - chrono::Duration::days(7)).format("%Y-%m-%d").to_string(),
        "week_end": chrono::Utc::now().format("%Y-%m-%d").to_string(),
        "new_cards": new_cards,
        "reviews": weekly_reviews,
        "conversation_turns": weekly_convs,
        "new_achievements": weekly_achievements,
        "active_plan": plan_goal,
    }))
}

// ════════════════════════════════════════════
// K12 结构化学习初始化
// ════════════════════════════════════════════

#[derive(Deserialize)]
pub struct K12InitInput {
    pub user_id: String,
    pub subject: String,
    pub grade_band: String,
}

#[derive(Deserialize)]
pub struct K12InitQuery {
    pub user_id: String,
}

/// POST /api/k12/init — 初始化 K12 计划（从 v3 JSON 加载）
async fn k12_init_handler(
    headers: HeaderMap,
    Json(input): Json<K12InitInput>,
) -> Json<serde_json::Value> {
    tracing::info!("[K12-INIT] start: user={}, subject={}, grade_band={}", input.user_id, input.subject, input.grade_band);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        tracing::warn!("[K12-INIT] auth failed: {:?}", e);
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();
    let now_ts = chrono::Utc::now().timestamp();

    // 查找已有 plan（同科目、同年级）
    let existing_plan: Option<(String, String)> = conn.query_row(
        "SELECT cp.id, cp.plan_content FROM conversation_plans cp
         JOIN conversations c ON cp.conversation_id = c.id
         WHERE c.user_id = ?1 AND c.deleted_at IS NULL AND cp.subject = ?2 AND cp.grade_band = ?3
         ORDER BY c.started_at DESC LIMIT 1",
        rusqlite::params![input.user_id, input.subject, input.grade_band],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?)),
    ).ok();

    if let Some((plan_id, plan_content_str)) = existing_plan {
        tracing::info!("[K12-INIT] resumed existing plan={}", plan_id);
        let plan_val: serde_json::Value = serde_json::from_str(&plan_content_str).unwrap_or_default();
        let conv_id: String = conn.query_row(
            "SELECT conversation_id FROM conversation_plans WHERE id = ?1",
            rusqlite::params![plan_id], |row| row.get(0),
        ).unwrap_or_default();
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "plan": plan_val,
            "resumed": true,
        }));
    }

    // 读取 v3 JSON 计划文件（从 root 读取新格式，含 grade_band 字段）
    let k12_data_dir = crate::curriculum_loader::k12_data_dir();
    let plan_path = std::path::Path::new(&k12_data_dir).join(format!("{}.json", input.subject));
    let plan_content_str = match std::fs::read_to_string(&plan_path) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("加载计划失败: {}", e)})),
    };

    // 按 grade_band 过滤 stage（从 v3 JSON 自身的 stage.grade_band 字段）
    let mut plan_val: serde_json::Value = serde_json::from_str(&plan_content_str).unwrap_or_default();
    let plan_goal = plan_val.get("goal").and_then(|g| g.as_str()).unwrap_or("").to_string();
    let grade_band_filter = input.grade_band.as_str();
    if !grade_band_filter.is_empty() {
        if let Some(stages) = plan_val.get_mut("stages").and_then(|s| s.as_array_mut()) {
            stages.retain(|stage| {
                let gb = stage.get("grade_band").and_then(|v| v.as_str()).unwrap_or("");
                gb == grade_band_filter || gb.is_empty()
            });
        }
    }
    let filtered_content_str = serde_json::to_string(&plan_val).unwrap_or_else(|_| plan_content_str.clone());

    let conv_id = uuid::Uuid::new_v4().to_string();
    let plan_id = uuid::Uuid::new_v4().to_string();

    // 先创建 conversations 记录（满足 FK 约束：conversation_plans.conversation_id → conversations.id）
    let _ = conn.execute(
        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conv_id, input.user_id, now_ts.to_string()],
    );

    // 写入 K12 plan
    match conn.execute(
        "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, subject, grade_band, plan_content, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![plan_id, input.user_id, conv_id, plan_goal, input.subject, input.grade_band, filtered_content_str, now_ts, now_ts],
    ) {
        Ok(_) => tracing::info!("[K12-INIT] plan inserted: id={}, subject={}, grade_band={}", plan_id, input.subject, input.grade_band),
        Err(e) => {
            tracing::error!("[K12-INIT] plan INSERT FAILED: {} — subject={}, grade={}", e, input.subject, input.grade_band);
            return Json(serde_json::json!({"error": format!("创建计划失败: {}", e)}));
        }
    }

    // 激活第一个 stage（过滤后）的卡片
    let mut activated = 0u32;
    if let Some(stages) = plan_val.get("stages").and_then(|s| s.as_array()) {
        if let Some(first_stage) = stages.first() {
            if let Some(tasks) = first_stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    let task_key = task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
                    for cid in task.get("card_ids").and_then(|c| c.as_array()).into_iter().flatten() {
                        if let Some(card_uuid) = cid.as_str() {
                            crate::plan_handler::copy_prebuilt_card(&conn, &input.user_id, &plan_id, &conv_id, task_key, card_uuid);
                            activated += 1;
                        }
                    }
                }
            }
        }
    }

    // 初始化 user_plan_progress（统一状态管理入口）
    let now_ts_progress = chrono::Utc::now().timestamp();
    let mut first_task_seen = false;
    if let Some(stages) = plan_val.get("stages").and_then(|s| s.as_array()) {
        for stage in stages {
            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    let task_key = task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
                    if !task_key.is_empty() {
                        let progress_id = uuid::Uuid::new_v4().to_string();
                        let init_status = if !first_task_seen { first_task_seen = true; "in_progress" } else { "pending" };
                        let _ = conn.execute(
                            "INSERT OR IGNORE INTO user_plan_progress (id, user_id, plan_id, task_key, status, updated_at)
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                            rusqlite::params![progress_id, input.user_id, plan_id, task_key, init_status, now_ts_progress],
                        );
                    }
                }
            }
        }
    }

    tracing::info!("[K12-INIT] SUCCESS: conv_id={}, plan_id={}, stages={}, cards_activated={}, grade_band={}",
        conv_id, plan_id,
        plan_val.get("stages").and_then(|s| s.as_array()).map(|a| a.len()).unwrap_or(0),
        activated, input.grade_band);

    let plan_val: serde_json::Value = serde_json::from_str(&plan_content_str).unwrap_or_default();
    Json(serde_json::json!({
        "conversation_id": conv_id,
        "plan": plan_val,
    }))
}

// ── Reading-First 模式初始化 ──

/// GET /api/k12/reading/{conv_id}/current-card — 获取当前 task 的课文卡片
#[derive(Deserialize)]
pub struct K12ReadingCurrentCardQuery {
    pub user_id: String,
}

async fn k12_reading_current_card_handler(
    headers: HeaderMap,
    Path(conv_id): Path<String>,
    Query(query): Query<K12ReadingCurrentCardQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("k12_reading_current_card_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 1. 读取 plan_content 和 user_plan_progress 状态
    let plan_content_str: String = match conn.query_row(
        "SELECT plan_content FROM conversation_plans WHERE conversation_id = ?1",
        rusqlite::params![conv_id],
        |row| row.get(0),
    ) {
        Ok(v) => v,
        Err(_) => return Json(serde_json::json!({"error": "reading plan not found"})),
    };

    let plan_content: serde_json::Value = match serde_json::from_str(&plan_content_str) {
        Ok(v) => v,
        Err(_) => return Json(serde_json::json!({"error": "invalid plan content"})),
    };

    // 2. 从 DB 读取 user_plan_progress 确定各 task 状态
    // 读取所有 task_key 的进度
    let plan_id: String = conn.query_row(
        "SELECT id FROM conversation_plans WHERE conversation_id = ?1",
        rusqlite::params![conv_id], |row| row.get(0),
    ).unwrap_or_default();

    let mut progress_map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    if !plan_id.is_empty() {
        if let Ok(mut stmt) = conn.prepare(
            "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![plan_id], |row| {
                Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?))
            }) {
                for row in rows.flatten() {
                    progress_map.insert(row.0, row.1);
                }
            }
        }
    }

    // 3. 找到第一个未完成 task 的 card_ids[0]
    let first_card_uuid: Option<String> = (|| {
        let stages = plan_content.get("stages")?.as_array()?;
        for stage in stages {
            let tasks = stage.get("tasks")?.as_array()?;
            for task in tasks {
                let task_key = task.get("task_key").and_then(|k| k.as_str()).unwrap_or("");
                let state = progress_map.get(task_key).map(|s| s.as_str()).unwrap_or("pending");
                if state == "done" || state == "skipped" {
                    continue;
                }
                let cids = task.get("card_ids")?.as_array()?;
                // 取第一张 card（课文卡/阅读卡）
                let first = cids.first()?.as_str()?;
                return Some(first.to_string());
            }
        }
        None
    })();

    // 4. 从 DB 读取卡片（用户已拥有该卡片）
    let current_card: Option<serde_json::Value> = first_card_uuid.and_then(|uuid| {
        conn.query_row(
            "SELECT id, card_type, front, back FROM cards WHERE id = ?1 AND user_id = ?2",
            rusqlite::params![uuid, query.user_id],
            |row| {
                let id: String = row.get(0)?;
                let card_type: String = row.get(1)?;
                let front: String = row.get(2)?;
                let back: String = row.get(3)?;
                // 尝试解析 back 为 JSON（poem 卡片）
                let back_val: serde_json::Value = if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&back) {
                    parsed
                } else {
                    serde_json::Value::String(back)
                };
                // Plan A: 将 back JSON 中的阅读卡片字段平铺到顶层
                let mut resp = serde_json::json!({
                    "id": id,
                    "card_type": card_type,
                    "front": front,
                    "back": back_val,
                });
                if let Some(obj) = back_val.as_object() {
                    // 按 ReadingFullTextScreen 需要的字段逐个平铺
                    for key in &["full_text", "author", "famous_lines", "imagery", "technique", "theme", "common_mistakes", "dynasty", "level", "tags"] {
                        if let Some(val) = obj.get(*key) {
                            resp[*key] = val.clone();
                        }
                    }
                }
                Ok(resp)
            }
        ).ok()
    });

    Json(serde_json::json!({
        "current_card": current_card,
    }))
}

/// GET /api/k12/progress — 获取用户 K12 进度摘要
#[derive(Deserialize)]
pub struct K12ProgressQuery {
    pub user_id: String,
}

/// 激活计划中的第一个任务：将第一 stage 的第一个 task 设为 in_progress
/// 防止 reading/structured 模式创建计划后所有任务全 pending，CP2 无法推进
fn activate_first_task(mut status_map: serde_json::Value, plan_content: &serde_json::Value) -> serde_json::Value {
    if let Some(first_task_name) = plan_content.get("stages")
        .and_then(|s| s.as_array())
        .and_then(|a| a.first())
        .and_then(|stage| stage.get("tasks"))
        .and_then(|t| t.as_array())
        .and_then(|a| a.first())
        .and_then(|task| task.get("name"))
        .and_then(|n| n.as_str())
    {
        if let Some(map) = status_map.as_object_mut() {
            map.insert(first_task_name.to_string(), serde_json::json!("in_progress"));
        }
    }
    status_map
}

async fn k12_progress_handler(
    headers: HeaderMap,
    Query(query): Query<K12ProgressQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("k12_progress_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 从 conversation_plans + user_plan_progress + cards 聚合进度
    let mut rows: Vec<serde_json::Value> = Vec::new();

    // 1. 查询所有 conversation_plans
    let mut stmt = match conn.prepare(
        "SELECT cp.id, cp.plan_content, cp.goal, cp.grade_band, cp.created_at
         FROM conversation_plans cp
         WHERE cp.user_id = ?1
         ORDER BY cp.created_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB prepare: {}", e)})),
    };

    let plans = match stmt.query_map(rusqlite::params![query.user_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, i64>(4)?,
        ))
    }) {
        Ok(r) => r,
        Err(e) => return Json(serde_json::json!({"error": format!("DB query: {}", e)})),
    };

    for plan_row in plans.flatten() {
        let (plan_id, plan_content_str, goal, grade_band, started_at_ts) = plan_row;

        // 2. 解析 plan_content JSON 统计总任务数
        let total_tasks = serde_json::from_str::<serde_json::Value>(&plan_content_str)
            .ok()
            .map(|v| {
                v.get("stages")
                    .and_then(|s| s.as_array())
                    .map(|stages| {
                        stages.iter().fold(0, |acc, stage| {
                            acc + stage.get("tasks")
                                .and_then(|t| t.as_array())
                                .map(|tasks| tasks.len())
                                .unwrap_or(0)
                        })
                    })
                    .unwrap_or(0)
            })
            .unwrap_or(0);

        // 3. 查询 user_plan_progress 获取完成数
        let done_tasks: i64 = conn.query_row(
            "SELECT COUNT(*) FROM user_plan_progress WHERE plan_id = ?1 AND status = 'done'",
            rusqlite::params![plan_id],
            |row| row.get(0),
        ).unwrap_or(0);

        // 4. 卡片统计
        let total_cards: i64 = conn.query_row(
            "SELECT COUNT(*) FROM cards WHERE plan_id = ?1",
            rusqlite::params![plan_id],
            |row| row.get(0),
        ).unwrap_or(0);

        let mastered_cards: i64 = conn.query_row(
            "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id = cm.card_id WHERE c.plan_id = ?1 AND cm.state = 2 AND cm.reps >= 3",
            rusqlite::params![plan_id],
            |row| row.get(0),
        ).unwrap_or(0);

        rows.push(serde_json::json!({
            "goal": goal,
            "grade_band": grade_band,
            "total_tasks": total_tasks,
            "done_tasks": done_tasks,
            "total_cards": total_cards,
            "mastered_cards": mastered_cards,
            "reviewed_cards": (total_cards - mastered_cards).max(0),
            "progress_pct": if total_tasks > 0 { format!("{:.0}%", done_tasks as f64 / total_tasks as f64 * 100.0) } else { "0%".to_string() },
            "started_at": started_at_ts,
        }));
    }

    Json(serde_json::json!({
        "progress": rows,
        "total": rows.len(),
    }))
}
