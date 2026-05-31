//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, put, delete}, Json, extract::{Path, Query}};
use axum::extract::ws::WebSocketUpgrade;
use axum::http::HeaderMap;
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

/// Reusable HTTP client for STT requests — avoids creating a new connection pool per call
static STT_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn stt_client() -> &'static reqwest::Client {
    STT_CLIENT.get_or_init(reqwest::Client::new)
}

pub fn build_router(llm_config: LlmConfig) -> Router {
    // 存储 LLM 配置供 routes 使用
    crate::llm::init(llm_config);

    Router::new()
        .route("/health", get(health_check))
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
        .route("/api/auth/verify", post(auth_verify))
        .route("/api/chat", post(chat_handler))
        .route("/api/review/due", get(review_due_handler))
        .route("/api/review/submit", post(review_submit_handler))
        .route("/api/review/verify", post(review_verify_handler))
        .route("/api/review/judge", post(review_judge_handler))
        // Skipped concepts
        .route("/api/cards/skip", post(cards_skip_handler))
        .route("/api/cards/skipped", get(cards_skipped_handler))
        .route("/api/cards/skipped/{skip_id}", delete(cards_skip_delete_handler))
        .route("/api/cards/batch-create", post(cards_batch_create_handler))
        .route("/api/cards/all", get(cards_all_handler))
        .route("/api/cards/{card_id}/last-review", get(cards_last_review_handler))
        // History
        .route("/api/history", get(history_handler))
        // Profile
        .route("/api/user/{user_id}/profile", get(profile_handler))
        .route("/api/user/{user_id}/display-name", post(update_display_name_handler))
        .route("/api/user/{user_id}/avatar", post(avatar_upload_handler).get(avatar_get_handler))
        // Preferences
        .route("/api/user/{user_id}/preferences", get(preferences_get_handler).put(preferences_put_handler))
        // WS
        .route("/api/k12/init", post(k12_init_handler))
        .route("/api/k12/progress", get(k12_progress_handler))
        .route("/api/k12/reading/init", post(k12_reading_init_handler))
        .route("/api/k12/reading/{conv_id}/current-card", get(k12_reading_current_card_handler))
        .route("/api/k12/quiz/submit", post(crate::k12_quiz_api::quiz_submit_handler))
        .route("/ws", get(ws_upgrade))
        // Learning Plans
        .route("/api/plans", get(plans_list_handler).post(plan_upsert_handler))
        .route("/api/plans/{plan_id}", delete(plan_delete_handler))
        // Learning Report (Phase 3)
        .route("/api/user/{user_id}/learning-report", get(learning_report_handler))
        .route("/api/user/{user_id}/activity", get(activity_handler))
        .route("/api/user/{user_id}/weekly-report", get(weekly_report_handler))
        // Admin
        .route("/api/admin/users", get(admin_users_handler))
        .route("/api/admin/users/expiring", get(admin_expiring_users))
        .route("/api/admin/users/export", get(admin_users_export))
        .route("/api/admin/login", post(admin_login))
        .route("/api/admin/dashboard", get(admin_dashboard))
        .route("/api/admin/register", post(admin_register))
        .route("/api/admin/users/batch-subscription", post(admin_batch_subscription))
        .route("/api/admin/users/{user_id}", get(admin_user_detail).delete(admin_delete_user))
        .route("/api/admin/users/{user_id}/restore", post(admin_restore_user))
        .route("/api/admin/users/{user_id}/reveal-phone", post(admin_reveal_phone))
        .route("/api/admin/users/{user_id}/subscription", put(admin_set_subscription))
        .route("/api/admin/users/{user_id}/quick-extend", post(admin_quick_extend))
        .route("/api/admin/subscription-requests", get(admin_list_subscription_requests).post(admin_create_subscription_request))
        .route("/api/admin/subscription-requests/{req_id}/approve", post(admin_approve_request))
        .route("/api/admin/subscription-requests/{req_id}/reject", post(admin_reject_request))
        .route("/api/admin/admins", get(admin_list_admins).post(admin_create_admin))
        .route("/api/admin/admins/{admin_id}/password", post(admin_reset_password))
        .route("/api/admin/admins/{admin_id}/permissions", put(admin_set_permissions))
        .route("/api/admin/admins/{admin_id}/disable", delete(admin_disable_admin))
        .route("/api/admin/admins/{admin_id}/enable", post(admin_enable_admin))
        .route("/api/admin/audit-log", get(admin_audit_log))
        .route("/api/admin/guardian/students", get(guardian_students))
        .route("/api/admin/guardian/students/{student_id}", get(guardian_student_cards))
        .route("/api/admin/guardian/students/{student_id}/cards", get(guardian_student_cards))
        .route("/api/admin/guardian/students/{student_id}/conversations", get(guardian_student_conversations))
        .route("/api/admin/guardian/students/{student_id}/conversations/{conv_id}", get(guardian_student_conversation_detail))
        .route("/api/admin/guardian/students/{student_id}/learning-summary", get(guardian_learning_summary))
        .route("/api/admin/guardian/bind", post(guardian_bind_request))
        .route("/api/admin/guardian/reveal-phone/{admin_id}", post(guardian_reveal_phone))
        // Guardian assignment management (super admin)
        .route("/api/admin/guardian/assignments", get(admin_list_assignments).post(admin_create_assignment))
        .route("/api/admin/guardian/assignments/{assignment_id}", delete(admin_remove_assignment))
        .route("/api/user/bind-lookup", post(bind_lookup_handler))
        .route("/api/user/{user_id}/profile", put(update_user_profile_handler))
        // Conversation management
        .route("/api/conversations/{conv_id}", delete(conversation_delete_handler))
        .route("/api/conversations/{conv_id}/restore", post(conversation_restore_handler))
        .route("/api/conversations/{conv_id}/permanent", delete(conversation_permanent_delete_handler))
        // STT
        .route("/api/stt", post(stt_handler))
        // Verify translation (V1 forward mode)
        .route("/api/verify-translation", post(verify_translation_handler))
}

// ════════════════════════════════════════════
// Handlers (stubs — will be filled in later)
// ════════════════════════════════════════════

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

async fn auth_register(Json(input): Json<AuthInput>) -> Json<serde_json::Value> {
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

async fn auth_login(Json(input): Json<AuthInput>) -> Json<serde_json::Value> {
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

/// Verify that a stored token is still valid (used for session restore on app restart)
#[derive(Deserialize)]
pub struct TokenVerifyInput {
    pub user_id: String,
    pub token: String,
}

async fn auth_verify(Json(input): Json<TokenVerifyInput>) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let valid = crate::auth::verify_token(&conn, &input.user_id, &input.token);
    Json(serde_json::json!({"valid": valid}))
}

#[derive(Deserialize)]
pub struct ChatInput {
    pub user_id: String,
    pub conversation_id: String,
    pub message: String,
}

// ── Chat handler (split into composable helpers per P1-6) ──

/// Check subscription — returns Ok(()) if valid, Err(msg) if expired/missing
fn check_subscription(user_id: &str) -> Result<(), String> {
    let conn = crate::db_pool::get_conn();
    let expires: Option<String> = conn.query_row(
        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).ok().flatten();
    let now_ts = chrono::Utc::now().timestamp();
    let expired = match &expires {
        Some(e) => {
            let normalized = if e.len() == 10 && e.as_bytes().get(4) == Some(&b'-') {
                format!("{}T00:00:00Z", e)
            } else {
                e.clone()
            };
            chrono::DateTime::parse_from_rfc3339(&normalized)
                .map(|dt| dt.timestamp() < now_ts)
                .unwrap_or(true)
        }
        None => true,
    };
    if expired {
        let msg = if expires.is_some() { "subscription_expired" } else { "subscription_required" };
        Err(msg.to_string())
    } else {
        Ok(())
    }
}

/// Pre-query DB for concept extraction dedup + chat history. Drops conn before async.
fn load_chat_context(
    user_id: &str, conversation_id: &str, message: &str,
) -> (Vec<String>, Vec<String>, String, Vec<(String, String)>) {
    let conn = crate::db_pool::get_conn();

    let existing_fronts: Vec<String> = query_vec(
        &conn, "SELECT LOWER(front) FROM cards WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or_default();
    let skipped_fronts: Vec<String> = query_vec(
        &conn, "SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or_default();

    let mut history: Vec<(String, String)> = query_vec(
        &conn,
        "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at DESC LIMIT 10",
        rusqlite::params![conversation_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
    ).unwrap_or_default();
    history.reverse();

    let now = chrono::Utc::now();
    let now_str = now.to_rfc3339().to_string();

    // Save conversation + user turn
    let _ = conn.execute(
        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conversation_id, user_id, now_str],
    );
    let _ = conn.execute(
        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'user', ?3, ?4)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), conversation_id, message, now_str],
    );

    (existing_fronts, skipped_fronts, now_str, history)
}

/// Build the user_content string from history + plan context + current message
fn build_user_content(history: &[(String, String)], plan_context: &str, message: &str) -> String {
    let mut user_content = String::new();
    if history.len() > 1 {
        let context = &history[..history.len() - 1];
        let mut lines: Vec<String> = Vec::new();
        let mut total = 0usize;
        for (role, content) in context.iter().rev() {
            let label = if role == "user" { "用户" } else { "AI" };
            let line = format!("\n{}: {}", label, content);
            let next = total + line.len();
            if next > 5000 { break; }
            total = next;
            lines.push(line);
        }
        if !lines.is_empty() {
            lines.reverse();
            user_content.push_str("\n\n### 对话历史");
            for l in &lines { user_content.push_str(l); }
        }
    }
    if !plan_context.is_empty() {
        user_content.push_str(plan_context);
    }
    user_content.push_str(&format!("\n\n### 当前对话\n用户: {}", message));
    user_content
}

/// Process plan_update tags in LLM reply + detect achievements
fn process_plan_update(
    raw_reply: &str, conversation_id: &str, user_id: &str,
) -> (String, bool) {
    let conn = crate::db_pool::get_conn();
    let result = crate::plan_handler::handle_plan_update(&conn, raw_reply, conversation_id, user_id);

    let mut reply = result.cleaned_reply;
    if result.is_new_plan {
        if let Some(ref plan) = result.plan_json {
            reply = crate::plan_handler::render_plan(plan);
        }
    }

    // Achievement detection (stage done → silver/gold)
    if result.plan_updated && !result.is_new_plan {
        if let Some(ref plan) = result.plan_json {
            if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                for stage in stages {
                    if stage["status"] == "done" {
                        let stage_name = stage["name"].as_str().unwrap_or("阶段");
                        let key = format!("{}_silver", stage_name);
                        if !crate::plan_handler::achievement_exists(&conn, user_id, &key) {
                            crate::plan_handler::write_achievement(&conn, user_id,
                                &key, &format!("{}精英", stage_name), "🥈", "silver", "stage");
                        }
                        if stages.iter().all(|s| s["status"] == "done") {
                            let domain_name = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("领域");
                            let dkey = format!("{}_gold", domain_name);
                            if !crate::plan_handler::achievement_exists(&conn, user_id, &dkey) {
                                crate::plan_handler::write_achievement(&conn, user_id,
                                    &dkey, &format!("{}大师", domain_name), "🥇", "gold", "domain");
                            }
                        }
                    }
                }
            }
        }
    }

    (reply, result.plan_updated)
}

/// Save assistant reply turn
fn save_assistant_turn(conversation_id: &str, content: &str, now_str: &str) {
    let conn = crate::db_pool::get_conn();
    let _ = conn.execute(
        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'assistant', ?3, ?4)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), conversation_id, content, now_str],
    );
    let _ = conn.execute(
        "UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
        rusqlite::params![conversation_id],
    );
}

async fn chat_handler(
    headers: HeaderMap,
    Json(input): Json<ChatInput>,
) -> Json<serde_json::Value> {
    // 1. Auth
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }

    // 2. Subscription check
    if let Err(msg) = check_subscription(&input.user_id) {
        return Json(serde_json::json!({"error": msg}));
    }

    // 3. Load context (sync DB ops, drops conn before async LLM call)
    let (existing_fronts, skipped_fronts, now_str, history) =
        load_chat_context(&input.user_id, &input.conversation_id, &input.message);

    // 4. Build system prompt with plan context
    let llm_config = crate::llm::get_config();
    let (system_prompt, plan_context) = {
        let conn = crate::db_pool::get_conn();
        let (domain, mode, ctx) = crate::plan_handler::build_plan_context(&conn, &input.conversation_id);
        let templates = chat_engine::prompt_loader::get_for_domain(&domain);
        let sp = if mode == "structured" {
            templates.chat_system_structured.clone()
        } else {
            templates.chat_system_free.clone()
        };
        (sp, ctx)
    };

    // 5. Build user content and call LLM
    let user_content = build_user_content(&history, &plan_context, &input.message);
    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    let raw_reply = match caller.generate(&system_prompt, &user_content).await {
        Ok(r) => r,
        Err(e) => return Json(serde_json::json!({"error": format!("LLM: {}", e)})),
    };

    // 6. Process plan updates + achievements
    let (final_reply, mut plan_updated) =
        process_plan_update(&raw_reply, &input.conversation_id, &input.user_id);

    // 代码层兜底：若 LLM 未处理回退请求，自动回退
    if !plan_updated && crate::plan_handler::check_revert_signals(&input.message)
        && crate::plan_handler::auto_revert(&crate::db_pool::get_conn(), &input.conversation_id).is_some() {
            plan_updated = true;
        }

    // 7. Extract candidate concepts (async, uses pre-queried data)
    let conn7 = crate::db_pool::get_conn();
    let (extract_domain, _, extract_plan_ctx) = crate::plan_handler::build_plan_context(&conn7, &input.conversation_id);
    let extraction = chat_engine::concept_extractor::extract_concepts(
        &input.user_id, &input.message, &final_reply,
        &existing_fronts, &skipped_fronts, &llm_config, &history,
        &extract_domain, &extract_plan_ctx,
    ).await;
    let candidates: Vec<String> = extraction.candidates.iter().map(|c| c.front.clone()).collect();

    // 8. Save assistant turn
    save_assistant_turn(&input.conversation_id, &final_reply, &now_str);

    Json(serde_json::json!({
        "reply": final_reply,
        "candidates": candidates,
        "achievements": [],
        "plan_updated": plan_updated,
    }))
}

// ── Review Handlers ──

#[derive(Deserialize)]
pub struct DueQuery {
    pub user_id: String,
}

async fn review_due_handler(
    headers: HeaderMap,
    Query(query): Query<DueQuery>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let (cards, total) = card_engine::fsrs_scheduler::get_due_cards(&conn, &query.user_id, 500);
    Json(serde_json::json!({
        "cards": cards,
        "total_due": total,
        "has_more": total > 20,
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

async fn review_submit_handler(
    headers: HeaderMap,
    Json(input): Json<ReviewSubmitInput>,
) -> Json<serde_json::Value> {
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
            // 成就检测
            let detector = growth_engine::achievements::AchievementDetector;
            let defs = shared_types::growth::AchievementDef::predefined();
            let new_achievements = detector.check_and_persist(&conn, &defs, &ctx);

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
async fn review_verify_handler(
    headers: HeaderMap,
    Json(input): Json<VerifyInput>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let llm_config = crate::llm::get_config();
    let prompt = chat_engine::prompt_loader::get().quiz_generate.clone()
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
async fn review_judge_handler(
    headers: HeaderMap,
    Json(input): Json<JudgeInput>,
) -> Json<serde_json::Value> {
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

    let prompt = chat_engine::prompt_loader::get().quiz_judge.clone()
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
    let prompt = format!(
        "You are an English teacher judging whether a student's translation of a word is correct.\n\
         \nEnglish word: {}\nExpected meaning: {}\nStudent's answer: {}\n\
         \nJudge whether the student's answer correctly conveys the meaning of the English word.\n\
         Consider synonyms, paraphrases, and reasonable alternative translations as correct.\n\
         Only mark as 'fail' if the answer is completely wrong or unrelated.\n\
         \nRespond with exactly one word: pass or fail",
        input.front, input.back, input.user_input
    );

    let config = crate::llm::get_config();
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);
    match caller.generate("You are a strict but fair English teacher.", &prompt).await {
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

// ── Card Skip Handlers ──

#[derive(Deserialize)]
pub struct SkipInput {
    pub user_id: String,
    pub front: String,
    pub domain: Option<String>,
    pub source_text: String,
}

async fn cards_skip_handler(
    headers: HeaderMap,
    Json(input): Json<SkipInput>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    match card_engine::card_repository::skip_concept(&conn, &input.user_id, &input.front, &input.domain, &input.source_text) {
        Ok(id) => {
            // 同时删除已存在的卡片（及记忆状态）
            let _ = conn.execute(
                "DELETE FROM card_memory WHERE card_id IN (SELECT id FROM cards WHERE user_id = ?1 AND LOWER(front) = ?2)",
                rusqlite::params![input.user_id, input.front.to_lowercase()],
            );
            let _ = conn.execute(
                "DELETE FROM cards WHERE user_id = ?1 AND LOWER(front) = ?2",
                rusqlite::params![input.user_id, input.front.to_lowercase()],
            );
            Json(serde_json::json!({"skipped_id": id}))
        },
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

async fn cards_skipped_handler(
    headers: HeaderMap,
    Query(query): Query<DueQuery>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let rows = match query_vec(
        &conn,
        "SELECT id, front, domain, source_text, skipped_at FROM skipped_concepts WHERE user_id = ?1 ORDER BY skipped_at DESC",
        rusqlite::params![query.user_id],
        |row| Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "front": row.get::<_, String>(1)?,
            "domain": row.get::<_, Option<String>>(2)?,
            "source_text": row.get::<_, String>(3)?,
            "skipped_at": row.get::<_, i64>(4)?,
        })),
    ) {
        Ok(v) => v,
        Err(e) => return e,
    };
    Json(serde_json::json!({"skipped": rows}))
}

#[derive(Deserialize)]
pub struct SkipDeleteQuery {
    pub user_id: String,
}

async fn cards_skip_delete_handler(
    headers: HeaderMap,
    Query(query): Query<SkipDeleteQuery>,
    Path(skip_id): Path<String>,
) -> Json<serde_json::Value> {
    // Verify auth first — don't query DB before authentication
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // Read skipped record — scoped to the authenticated user
    let skipped = match conn.query_row(
        "SELECT front, domain, source_text, skipped_at FROM skipped_concepts WHERE id = ?1 AND user_id = ?2",
        rusqlite::params![skip_id, query.user_id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        }
    ) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("Skip not found: {}", e)})),
    };

    let (front, domain, source_text, _skipped_at) = skipped;

    // Restore as card
    let now = chrono::Utc::now().timestamp();
    // UUID format is guaranteed (8-4-4-4-12), split('-').next() never returns None
    let card_id = format!("card_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
    let back = source_text.clone().unwrap_or_default();
    let domain_str = domain.clone().unwrap_or_default();

    if let Err(e) = conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at)
         VALUES (?1, ?2, ?3, 'concept', ?4, ?5, ?6, NULL, ?7)",
        rusqlite::params![card_id, query.user_id, domain_str, front, back, source_text, now],
    ) {
        return Json(serde_json::json!({"error": format!("Card insert: {}", e)}));
    }

    // Create card memory (new card, due today)
    if let Err(e) = conn.execute(
        "INSERT INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
         VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
        rusqlite::params![card_id, now],
    ) {
        // Rollback card
        let _ = conn.execute("DELETE FROM cards WHERE id = ?1", rusqlite::params![card_id]);
        return Json(serde_json::json!({"error": format!("Card memory insert: {}", e)}));
    }

    // Delete skip record
    match conn.execute("DELETE FROM skipped_concepts WHERE id = ?1 AND user_id = ?2", rusqlite::params![skip_id, query.user_id]) {
        Ok(_) => Json(serde_json::json!({"status": "restored", "card_id": card_id})),
        Err(e) => Json(serde_json::json!({"error": format!("Delete: {}", e)})),
    }
}

async fn ws_upgrade(ws: WebSocketUpgrade) -> impl axum::response::IntoResponse {
    ws.on_upgrade(crate::ws::handle_ws)
}

// ════════════════════════════════════════════
// 批量制卡
// ════════════════════════════════════════════

#[derive(Deserialize)]
pub struct BatchCreateInput {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub candidates: Vec<CardCandidateInput>,
}

#[derive(Deserialize)]
pub struct CardCandidateInput {
    pub front: String,
    pub back: String,
    pub source_sentence: String,
    pub domain: Option<String>,
}

/// POST /api/cards/batch-create — 用户确认制卡后批量入库
async fn cards_batch_create_handler(
    headers: HeaderMap,
    Json(input): Json<BatchCreateInput>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let mut created = Vec::new();
    let mut duplicates = Vec::new();
    let mut errors = Vec::new();

    // 查对话的 subject/grade_band（如有），用于绑定 plan
    let (conv_subject, conv_grade): (Option<String>, Option<String>) = input.conversation_id.as_ref()
        .and_then(|cid| conn.query_row(
            "SELECT subject, grade_band FROM conversations WHERE id = ?1",
            rusqlite::params![cid],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).ok())
        .unwrap_or((None, None));

    for cand in &input.candidates {
        let candidate = shared_types::card::ConceptCandidate {
            front: cand.front.clone(),
            back: cand.back.clone(),
            source_sentence: cand.source_sentence.clone(),
            domain: cand.domain.clone().unwrap_or_else(|| "general".into()),
        };
        let (mut card, memory) = card_engine::card_formatter::format_card(&input.user_id, &candidate);
        card.conversation_id = input.conversation_id.clone();
        card.subject = conv_subject.clone();
        card.grade_band = conv_grade.clone();
        match card_engine::card_repository::insert_card(&conn, &card, &memory) {
            card_engine::card_repository::InsertResult::Success(id) => {
                created.push(id);
            }
            card_engine::card_repository::InsertResult::Duplicate(front) => {
                duplicates.push(front);
            }
            card_engine::card_repository::InsertResult::DatabaseError(e) => {
                errors.push(e);
            }
        }
    }

    // 成就检测
    let achievements = if !created.is_empty() {
        let total_cards: u32 = conn.query_row(
            "SELECT COUNT(*) FROM cards WHERE user_id = ?1",
            rusqlite::params![input.user_id], |row| row.get(0),
        ).unwrap_or(0);
        let total_reviews: u32 = conn.query_row(
            "SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id = c.id WHERE c.user_id = ?1",
            rusqlite::params![input.user_id], |row| row.get(0),
        ).unwrap_or(0);
        let streak_days: u32 = conn.query_row(
            "SELECT streak_days FROM users WHERE id = ?1",
            rusqlite::params![input.user_id], |row| row.get(0),
        ).unwrap_or(0);
        let domains_covered: u32 = conn.query_row(
            "SELECT COUNT(DISTINCT domain) FROM cards WHERE user_id = ?1 AND domain IS NOT NULL",
            rusqlite::params![input.user_id], |row| row.get(0),
        ).unwrap_or(0);

        let ctx = shared_types::growth::AchievementContext {
            user_id: input.user_id.clone(),
            total_cards, total_reviews, streak_days, domains_covered,
        };
        let detector = growth_engine::achievements::AchievementDetector;
        detector.check_and_persist(&conn, &shared_types::growth::AchievementDef::predefined(), &ctx)
    } else {
        vec![]
    };

    Json(serde_json::json!({
        "created": created,
        "duplicates": duplicates,
        "errors": errors,
        "achievements": achievements,
    }))
}

/// GET /api/cards/all — 获取用户所有卡片 (含搜索过滤)
#[derive(Deserialize)]
pub struct AllCardsQuery {
    pub user_id: String,
    pub q: Option<String>,         // 搜索关键词 (匹配 front/back)
    pub state: Option<i32>,        // 按状态过滤
    pub domain: Option<String>,    // 按领域过滤
    pub subject: Option<String>,   // 按科目过滤 (K12)
    pub sort: Option<String>,      // "front" | "created" | "state" | "due"
}

async fn cards_all_handler(
    headers: HeaderMap,
    Query(query): Query<AllCardsQuery>,
) -> Json<serde_json::Value> {
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    let mut sql = String::from(
        "SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
                c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                lrev.reviewed_at, lrev.rating, c.subject, c.grade_band
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         LEFT JOIN (
            SELECT card_id, MAX(reviewed_at) as last_reviewed_at
            FROM review_log GROUP BY card_id
         ) lr ON c.id = lr.card_id
         LEFT JOIN review_log lrev
            ON lrev.card_id = lr.card_id AND lrev.reviewed_at = lr.last_reviewed_at
         WHERE c.user_id = ?1"
    );
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(query.user_id.clone())];

    // 按领域过滤
    if let Some(ref domain) = query.domain {
        params.push(Box::new(domain.clone()));
        sql.push_str(&format!(" AND c.domain = ?{}", params.len()));
    }

    // 按 K12 科目过滤
    if let Some(ref subject) = query.subject {
        if !subject.is_empty() {
            params.push(Box::new(subject.clone()));
            sql.push_str(&format!(" AND c.subject = ?{}", params.len()));
        }
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
        "front": row.get::<_, String>(1)?,
        "back": row.get::<_, String>(2)?,
        "domain": row.get::<_, Option<String>>(3)?,
        "card_type": row.get::<_, String>(4)?,
        "source_sentence": row.get::<_, Option<String>>(5)?,
        "created_at": row.get::<_, i64>(6)?,
        "state": row.get::<_, i32>(7)?,
        "difficulty": row.get::<_, f64>(8)?,
        "due": row.get::<_, i64>(9)?,
        "reps": row.get::<_, i32>(10)?,
        "lapses": row.get::<_, i32>(11)?,
        "last_reviewed_at": row.get::<_, Option<i64>>(12)?,
        "last_review_quality": row.get::<_, Option<i32>>(13)?,
        "subject": row.get::<_, Option<String>>(14)?,
        "grade_band": row.get::<_, Option<String>>(15)?,
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
        "SELECT DISTINCT domain FROM cards WHERE user_id = ?1 AND domain IS NOT NULL ORDER BY domain",
        rusqlite::params![query.user_id], |row| row.get(0),
    ).unwrap_or_default();

    // K12 科目列表
    let subjects: Vec<String> = query_vec(
        &conn,
        "SELECT DISTINCT subject FROM cards WHERE user_id = ?1 AND subject IS NOT NULL ORDER BY subject",
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
        "subjects": subjects,
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
                (SELECT lp.goal FROM learning_plans lp
                 WHERE lp.conversation_id = c.id AND lp.mode = 'structured'
                 ORDER BY lp.updated_at DESC LIMIT 1) as plan_goal
         FROM conversations c
         WHERE c.user_id = ?1
           AND c.turn_count > 0
           AND (c.subject IS NULL OR c.subject = '')
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
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    match conn.execute(
        "UPDATE conversations SET deleted_at = ?1 WHERE id = ?2 AND user_id = ?3 AND deleted_at IS NULL",
        rusqlite::params![now, conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found or already deleted"})),
        Ok(_) => {
            // 同步标记关联的学习计划为 deleted
            let _ = conn.execute(
                "UPDATE learning_plans SET mode='deleted', updated_at=?1 WHERE conversation_id=?2 AND mode!='deleted'",
                rusqlite::params![now, conv_id],
            );
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
            // 同步恢复关联的学习计划
            let _ = conn.execute(
                "UPDATE learning_plans SET mode='structured', updated_at=?1 WHERE conversation_id=?2 AND mode='deleted'",
                rusqlite::params![chrono::Utc::now().to_rfc3339(), conv_id],
            );
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
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    // 级联删除 conversation_turns
    let _ = conn.execute(
        "DELETE FROM conversation_turns WHERE conversation_id = ?1",
        rusqlite::params![conv_id],
    );
    // 级联删除关联的学习计划
    let _ = conn.execute(
        "DELETE FROM learning_plans WHERE conversation_id = ?1",
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
    let conn = crate::db_pool::get_conn();

    // Verify auth: caller must be the user themselves
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return (axum::http::StatusCode::UNAUTHORIZED, axum::Json(serde_json::json!({"error": "unauthorized"})));
    }

    let total_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards WHERE user_id = ?1",
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
        "SELECT COUNT(DISTINCT domain) FROM cards WHERE user_id = ?1 AND domain IS NOT NULL",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let today_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN cards c ON r.card_id = c.id WHERE c.user_id = ?1 AND r.reviewed_at > ?2",
        rusqlite::params![user_id, chrono::Utc::now().timestamp() - 86400],
        |row| row.get(0),
    ).unwrap_or(0);

    let mut stmt = conn.prepare(
        "SELECT achievement_key, name, icon, unlocked_at FROM achievements WHERE user_id = ?1 ORDER BY unlocked_at DESC"
    ).unwrap();
    let achievements: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![user_id],
        |row| Ok(serde_json::json!({
            "key": row.get::<_, String>(0)?,
            "name": row.get::<_, String>(1)?,
            "icon": row.get::<_, String>(2)?,
            "unlocked_at": row.get::<_, String>(3)?,
        }))
    ).unwrap().filter_map(|r| r.ok()).collect();

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
         WHERE c.user_id = ?1 AND c.card_type = 'vocabulary' AND cm.state = 2"
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
            "total": s.total,
            "mastered": mastered,
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

// ── Display Name ──

async fn update_display_name_handler(
    Path(user_id): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
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
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
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
    let path = format!("{}/{}.png", avatar_dir(), user_id);
    match tokio::fs::read(&path).await {
        Ok(data) => Ok((axum::http::StatusCode::OK, [("Content-Type", "image/png")], data)),
        Err(_) => Err((axum::http::StatusCode::NOT_FOUND, "No avatar")),
    }
}

// ════════════════════════════════════════════
// Learning Plan Handlers
// ════════════════════════════════════════════

#[derive(Deserialize)]
pub struct PlanInput {
    pub user_id: String,
    pub goal: String,
    pub domain: String,
    pub plan_json: serde_json::Value,
    pub conversation_id: Option<String>,
}

async fn plans_list_handler(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

    let (sql, param_val): (&str, String) = if let Some(conv_id) = params.get("conversation_id") {
        ("SELECT id, goal, domain, mode, plan_content, plan_json, created_at, updated_at FROM learning_plans WHERE conversation_id = ?1 ORDER BY created_at DESC", conv_id.clone())
    } else if let Some(uid) = params.get("user_id") {
        ("SELECT id, goal, domain, mode, plan_content, plan_json, created_at, updated_at FROM learning_plans WHERE user_id = ?1 ORDER BY created_at DESC", uid.clone())
    } else {
        return Json(serde_json::json!({"error": "user_id or conversation_id required"}));
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB: {}", e)})),
    };
    let plans: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![param_val], |row| {
        // plan_content: 完整计划结构（可为 NULL）
        let plan_content_raw: Option<String> = row.get(4).ok();
        // plan_json: 状态信息
        let plan_json_raw: String = row.get(5)?;
        let plan_json_val: Option<serde_json::Value> = serde_json::from_str(&plan_json_raw).ok();

        // 合并：plan_content（内容）+ plan_json（状态）→ 前端格式
        let merged_plan = if let (Some(content_str), Some(status_val)) = (&plan_content_raw, &plan_json_val) {
            if let Ok(mut content) = serde_json::from_str::<serde_json::Value>(content_str) {
                // 从 plan_json 读取 task_status 映射
                let task_status = status_val.get("task_status")
                    .and_then(|s| s.as_object())
                    .or_else(|| status_val.as_object()); // 兼容旧格式直接存 map
                if let Some(status_map) = task_status {
                    if let Some(stages) = content.get_mut("stages").and_then(|s| s.as_array_mut()) {
                        for stage in stages {
                            if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                                for task in tasks {
                                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                                        let status = status_map.get(name)
                                            .and_then(|s| s.as_str())
                                            .unwrap_or("pending");
                                        task["status"] = serde_json::json!(status);
                                    }
                                }
                            }
                        }
                    }
                }
                content
            } else {
                serde_json::Value::Null
            }
        } else {
            serde_json::Value::Null
        };

        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "goal": row.get::<_, String>(1)?,
            "domain": row.get::<_, String>(2)?,
            "mode": row.get::<_, Option<String>>(3)?,
            "plan": merged_plan,
            "created_at": row.get::<_, String>(6)?,
            "updated_at": row.get::<_, String>(7)?,
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();

    Json(serde_json::json!({"plans": plans}))
}

async fn plan_upsert_handler(
    Json(input): Json<PlanInput>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    let plan_str = input.plan_json.to_string();

    // 通过 conversation_id 或 user_id+domain 查找已有计划
    let existing_id: Option<String> = if let Some(ref conv_id) = input.conversation_id {
        conn.query_row(
            "SELECT id FROM learning_plans WHERE conversation_id = ?1 AND mode != 'deleted' LIMIT 1",
            rusqlite::params![conv_id],
            |row| row.get(0),
        ).ok()
    } else {
        conn.query_row(
            "SELECT id FROM learning_plans WHERE user_id = ?1 AND domain = ?2 AND mode != 'deleted' LIMIT 1",
            rusqlite::params![input.user_id, input.domain],
            |row| row.get(0),
        ).ok()
    };

    if let Some(id) = existing_id {
        // Update existing
        let _ = conn.execute(
            "UPDATE learning_plans SET goal=?1, plan_json=?2, updated_at=?3 WHERE id=?4",
            rusqlite::params![input.goal, plan_str, now, id],
        );
        Json(serde_json::json!({"id": id, "status": "updated"}))
    } else {
        // Insert new
        let id = uuid::Uuid::new_v4().to_string();
        let _ = conn.execute(
            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?7)",
            rusqlite::params![id, input.user_id, input.conversation_id, input.goal, input.domain, plan_str, now],
        );
        Json(serde_json::json!({"id": id, "status": "created"}))
    }
}

async fn plan_delete_handler(
    Path(plan_id): Path<String>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    let user_id = match params.get("user_id") {
        Some(id) => id,
        None => return Json(serde_json::json!({"error": "user_id required"})),
    };
    let conn = crate::db_pool::get_conn();
    // 软删除：标记 mode=deleted，不物理删除
    match conn.execute(
        "UPDATE learning_plans SET mode='deleted', updated_at=?1 WHERE id=?2 AND user_id=?3",
        rusqlite::params![chrono::Utc::now().to_rfc3339(), plan_id, user_id],
    ) {
        Ok(_) => Json(serde_json::json!({"status": "ok"})),
        Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
    }
}

// ════════════════════════════════════════════
// Phase 3 — Learning Report
// ════════════════════════════════════════════

async fn learning_report_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

    // 1. 所有学习计划进度
    let mut stmt_plans = conn.prepare(
        "SELECT plan_json, plan_content, goal, mode, updated_at FROM learning_plans WHERE user_id = ?1 AND mode != 'deleted' ORDER BY updated_at DESC"
    ).unwrap();
    let mut plans: Vec<serde_json::Value> = Vec::new();
    for row in stmt_plans.query_map(rusqlite::params![user_id], |row| {
        let pj: String = row.get(0)?;
        let pc: Option<String> = row.get(1)?;
        let goal: String = row.get(2)?;
        let mode: String = row.get(3)?;
        let updated: String = row.get(4)?;
        Ok((pj, pc, goal, mode, updated))
    }).unwrap().filter_map(|r| r.ok()) {
        let (pj, pc, goal, mode, updated) = row;
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pj) {
                    let mut total_tasks = 0u32;
                    let mut done_tasks = 0u32;
                    let mut current_stage = "";
                    // plan_json 可能只有 task_status（被 apply_plan_mutations 改写后），
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
                        // plan_json 有 stages（旧格式）
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
        "SELECT COUNT(*) FROM cards WHERE user_id = ?1", rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    let reviews_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log WHERE card_id IN (SELECT id FROM cards WHERE user_id = ?1)",
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
/// status_map (plan_json 的 task_status) 用于 reading 模式的状态覆盖
fn compute_plan_totals(plan_content_str: &str, plan_json: &serde_json::Value) -> (u32, u32) {
    let mut total: u32 = 0;
    let mut done: u32 = 0;
    let status_map = plan_json.get("task_status").and_then(|v| v.as_object());
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
    let conn = crate::db_pool::get_conn();
    let week_ago = (chrono::Utc::now() - chrono::Duration::days(7)).to_rfc3339();
    let week_ago_ts = (chrono::Utc::now() - chrono::Duration::days(7)).timestamp();

    // 本周新增卡片
    let new_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards WHERE user_id = ?1 AND created_at >= ?2",
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
        "SELECT goal FROM learning_plans WHERE user_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
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
// Admin
// ════════════════════════════════════════════
async fn stt_handler(
    body: axum::body::Bytes,
) -> Json<serde_json::Value> {
    let appid = std::env::var("IFLYTEK_APPID").unwrap_or_default();
    let api_key = std::env::var("IFLYTEK_API_KEY").unwrap_or_default();
    let api_secret = std::env::var("IFLYTEK_API_SECRET").unwrap_or_default();
    if appid.is_empty() || api_key.is_empty() || api_secret.is_empty() {
        return Json(serde_json::json!({"error": "iFlytek credentials not configured"}));
    }

    // 用 ffmpeg 把 M4A/AAC 转成 16kHz 单声道 PCM
    let pid = std::process::id();
    let in_path = std::path::Path::new("/tmp").join(format!("stt_in_{}", pid));
    let out_path = std::path::Path::new("/tmp").join(format!("stt_out_{}.pcm", pid));
    let _ = tokio::fs::write(&in_path, &body).await;
    tracing::info!("STT: received {} bytes, wrote to {}", body.len(), in_path.display());
    let ffmpeg_out = std::process::Command::new("ffmpeg")
        .args([
            "-y",
            "-i", &in_path.to_string_lossy(),
            "-ar", "16000",
            "-ac", "1",
            "-sample_fmt", "s16",
            "-f", "s16le",
            &out_path.to_string_lossy(),
        ])
        .output();
    let _ = tokio::fs::remove_file(&in_path).await;

    let raw_pcm = match ffmpeg_out {
        Ok(o) if o.status.success() => {
            let data = tokio::fs::read(&out_path).await.unwrap_or_default();
            let _ = tokio::fs::remove_file(&out_path).await;
            data
        }
        Ok(o) => {
            let msg = String::from_utf8_lossy(&o.stderr).to_string();
            return Json(serde_json::json!({"error": format!("ffmpeg: {}", msg)}));
        }
        Err(e) => return Json(serde_json::json!({"error": format!("ffmpeg exec: {}", e)})),
    };
    if raw_pcm.is_empty() {
        return Json(serde_json::json!({"error": "empty pcm after ffmpeg"}));
    }
    tracing::info!("STT: ffmpeg ok, pcm={} bytes, sending to iFlytek", raw_pcm.len());

    let cur_time = chrono::Utc::now().timestamp().to_string();
    let param_json = serde_json::json!({
        "engine_type": "sms16k",
        "aue": "raw",
    });
    let param_b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        param_json.to_string(),
    );
    let checksum_input = format!("{}{}{}", api_key, cur_time, param_b64);
    let checksum = format!("{:x}", md5::compute(checksum_input.as_bytes()));

    let client = stt_client();
    // 讯飞 REST API 要求: audio 先 Base64 编码，再 URL 编码，作为 form 参数发送
    let audio_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &raw_pcm);
    let audio_form = audio_b64
        .replace('+', "%2B")
        .replace('/', "%2F")
        .replace('=', "%3D");
    let form_body = format!("audio={}", audio_form);
    match client
        .post("https://api.xfyun.cn/v1/service/v1/iat")
        .header("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
        .header("X-Appid", &appid)
        .header("X-CurTime", &cur_time)
        .header("X-Param", &param_b64)
        .header("X-CheckSum", &checksum)
        .body(form_body)
        .send()
        .await
    {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            tracing::info!("iFlytek response ({}): {}", status, &text[..text.len().min(500)]);
            if status == 200 {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
                    let code = json["code"].as_str().unwrap_or("??");
                    if code == "0" {
                        if let Some(t) = json["data"].as_str() {
                            if !t.is_empty() {
                                tracing::info!("STT: success, text='{}'", t);
                                return Json(serde_json::json!({"text": t}));
                            }
                        }
                        tracing::warn!("STT: code=0 but data empty: {}", text);
                        return Json(serde_json::json!({"text": "", "_debug": text}));
                    }
                    let desc = json["desc"].as_str().unwrap_or(&text);
                    tracing::error!("STT: code={} desc={}", code, desc);
                    return Json(serde_json::json!({"error": format!("iFlytek code={}: {}", code, desc)}));
                }
                tracing::error!("STT: parse error: {}", text);
                Json(serde_json::json!({"error": format!("iFlytek parse: {}", text)}))
            } else {
                Json(serde_json::json!({"error": format!("iFlytek {}: {}", status, text)}))
            }
        }
        Err(e) => Json(serde_json::json!({"error": format!("STT proxy: {}", e)})),
    }
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

/// POST /api/k12/init — 初始化 K12 会话
async fn k12_init_handler(
    headers: HeaderMap,
    Json(input): Json<K12InitInput>,
) -> Json<serde_json::Value> {
    eprintln!("[K12-INIT] start: user={}, subject={}, grade={}", input.user_id, input.subject, input.grade_band);

    // 1. Auth
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        eprintln!("[K12-INIT] auth failed: {:?}", e);
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now();
    let now_str = now.to_rfc3339();
    let now_ts = now.timestamp();

    // 2. 检查是否已有该学段的 K12 会话（同用户+同科目+同学段）
    let existing_conv: Option<String> = conn.query_row(
        "SELECT c.id FROM conversations c
         INNER JOIN learning_plans lp ON lp.conversation_id = c.id
         WHERE c.user_id = ?1 AND c.subject = ?2 AND c.grade_band = ?3
           AND lp.mode = 'structured' AND c.deleted_at IS NULL
         ORDER BY c.started_at DESC LIMIT 1",
        rusqlite::params![input.user_id, input.subject, input.grade_band],
        |row| row.get(0),
    ).ok();

    if let Some(conv_id) = existing_conv {
        eprintln!("[K12-INIT] resumed existing conv={}", conv_id);
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "resumed": true,
        }));
    }

    // 3. 创建新 conversation 带 subject/grade_band 标记
    let conv_id = uuid::Uuid::new_v4().to_string();
    eprintln!("[K12-INIT] new conv={} for {} {} {}", conv_id, input.user_id, input.subject, input.grade_band);
    if let Err(e) = conn.execute(
        "INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, ?3, ?4, ?5)",
        rusqlite::params![conv_id, input.user_id, now_str, input.subject, input.grade_band],
    ) {
        return Json(serde_json::json!({"error": format!("Conv create: {}", e)}));
    }

    // 3. 加载预生成计划
    let plan = match curriculum_loader::get_plan(&input.subject, &input.grade_band) {
        Some(p) => p,
        None => return Json(serde_json::json!({"error": format!("无此科目/学段的学习计划", )})),
    };

    // 3a. 检查是否有匹配当前学段的 stages
    if plan.stages.is_empty() {
        return Json(serde_json::json!({"error": format!("【{}】在{}学段没有预生成的学习内容", input.subject, input.grade_band)}));
    }

    // 4. 将计划写入 learning_plans 表
    let plan_id = uuid::Uuid::new_v4().to_string();
    let plan_json = serde_json::json!({
        "id": plan.id,
        "subject": input.subject,
        "grade_band": input.grade_band,
        "goal": plan.goal,
        "stages": plan.stages,
        "total_crs": plan.total_crs,
    });
    // 激活第一个任务（防止所有任务都是 pending，CP2 无法推进）
    let plan_str = {
        let mut pj = plan_json.clone();
        if let Some(stages) = pj.get_mut("stages").and_then(|s| s.as_array_mut()) {
            if let Some(first_stage) = stages.first_mut() {
                if let Some(tasks) = first_stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                    if let Some(first_task) = tasks.first_mut() {
                        first_task["status"] = serde_json::json!("in_progress");
                    }
                }
            }
        }
        serde_json::to_string(&pj).unwrap_or_default()
    };
    // 先清理同一用户+科目+学段的旧学习计划（防止 UNIQUE 冲突）
    // domain = subject + grade_band，确保不同学段不互相覆盖
    let _ = conn.execute(
        "DELETE FROM learning_plans WHERE user_id = ?1 AND domain = ?2",
        rusqlite::params![input.user_id, format!("{}_{}", input.subject, input.grade_band)],
    );
    if let Err(e) = conn.execute(
        "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, plan_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'structured', ?6, ?7, ?8, ?8)",
        rusqlite::params![plan_id, input.user_id, conv_id, format!("K12: {} {}", input.subject, input.grade_band), format!("{}_{}", input.subject, input.grade_band), plan_str, plan_str, now_str],
    ) {
        return Json(serde_json::json!({"error": format!("Plan insert: {}", e)}));
    }

    // 5. 卡片渐进解锁：只导入第一个任务的卡片
    let cards = curriculum_loader::get_cards(&input.subject, &input.grade_band);
    let mut card_ids: Vec<String> = Vec::new();

    // 从计划中提取第一个任务的 gold_cr_ids 和名称
    let first_task_ids: Vec<String> = plan_json.get("stages")
        .and_then(|s| s.as_array())
        .and_then(|stages| stages.first())
        .and_then(|stage| stage.get("tasks"))
        .and_then(|t| t.as_array())
        .and_then(|tasks| tasks.first())
        .and_then(|task| task.get("gold_cr_ids"))
        .and_then(|ids| ids.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default();

    let first_task_name: String = plan_json.get("stages")
        .and_then(|s| s.as_array())
        .and_then(|stages| stages.first())
        .and_then(|stage| stage.get("tasks"))
        .and_then(|t| t.as_array())
        .and_then(|tasks| tasks.first())
        .and_then(|task| task.get("name"))
        .and_then(|n| n.as_str())
        .unwrap_or("")
        .to_string();

    // 修复旧数据：将该科目所有卡片的 domain 对齐到计划名称（如 "math"→"数学"）
    let _ = conn.execute(
        "UPDATE cards SET domain = ?1 WHERE subject = ?1 AND domain != ?1",
        rusqlite::params![input.subject],
    );

    if let Some(card_list) = cards {
        for card_tmpl in card_list {
            // 概念卡：gold_cr_ids 与首任务的 gold_cr_ids 有交集则导入
            // 词卡/其他卡：plan_task_id 等于首任务 name 则导入
            let matches_task = card_tmpl.gold_cr_ids.iter().any(|g| first_task_ids.contains(g))
                || (!first_task_name.is_empty() && card_tmpl.plan_task_id == first_task_name);
            if !first_task_ids.is_empty() && !matches_task && first_task_name.is_empty() {
                continue;
            }
            let card_id = format!("k12_{}", &card_tmpl.id);
            let _ = conn.execute(
                "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, k12_card_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                rusqlite::params![card_id, input.user_id, input.subject, card_tmpl.card_type,
                    card_tmpl.front, card_tmpl.back, card_tmpl.source_sentence, conv_id, now_ts,
                    input.subject, input.grade_band, card_tmpl.id],
            );
            // 创建 card_memory (新卡片)
            let _ = conn.execute(
                "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                 VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
                rusqlite::params![card_id, now_ts],
            );
            card_ids.push(card_id);
        }
    }

    // 6. 返回结果
    Json(serde_json::json!({
        "conversation_id": conv_id,
        "plan": plan_json,
        "cards": serde_json::json!({
            "total": card_ids.len(),
            "ids": card_ids,
            "sample": card_ids.get(0..5).unwrap_or(&[]),
        }),
    }))
}

// ── Reading-First 模式初始化 ──

/// POST /api/k12/reading/init — 初始化课文阅读会话（独立于 knowledge_first）
async fn k12_reading_init_handler(
    headers: HeaderMap,
    Json(input): Json<K12InitInput>,
) -> Json<serde_json::Value> {
    eprintln!("[READING-HANDLER] start: user={}, subject={}, grade={}", input.user_id, input.subject, input.grade_band);

    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        eprintln!("[READING-HANDLER] auth failed: {:?}", e);
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now();
    let now_str = now.to_rfc3339();
    let now_ts = now.timestamp();

    // 1. 检查是否已有 reading 会话
    let existing_conv: Option<String> = conn.query_row(
        "SELECT c.id FROM conversations c
         INNER JOIN learning_plans lp ON lp.conversation_id = c.id
         WHERE c.user_id = ?1 AND c.subject = ?2 AND c.grade_band = ?3
           AND lp.mode = 'reading' AND c.deleted_at IS NULL
         ORDER BY c.started_at DESC LIMIT 1",
        rusqlite::params![input.user_id, input.subject, input.grade_band],
        |row| row.get(0),
    ).ok();

    if let Some(conv_id) = existing_conv {
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "resumed": true,
        }));
    }

    // 2. 加载 reading plan（中文科目名→英文 key）
    let subject_key = crate::curriculum_loader::CHINESE_TO_ENGLISH.iter()
        .find(|(cn, _)| *cn == input.subject)
        .map(|(_, en)| *en)
        .unwrap_or(&input.subject)
        .to_string();
    eprintln!("[READING-HANDLER] subject_key={}, getting plan...", subject_key);
    let plan = match crate::reading_loader::get_plan(&subject_key) {
        Some(p) => {
            eprintln!("[READING-HANDLER] plan found: goal={}", p.goal);
            p
        }
        None => {
            eprintln!("[READING-HANDLER] plan NOT FOUND for key={}", subject_key);
            return Json(serde_json::json!({"error": format!("reading plan not found for subject: {}", input.subject)}));
        }
    };

    // 3. 创建 conversation
    let conv_id = uuid::Uuid::new_v4().to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, ?3, ?4, ?5)",
        rusqlite::params![conv_id, input.user_id, now_str, input.subject, input.grade_band],
    ) {
        eprintln!("[READING-HANDLER] Conv INSERT failed: {}", e);
        return Json(serde_json::json!({"error": format!("Conv create: {}", e)}));
    }

    // 4. 写入 plan（按学段过滤 stage）
    let subj_key = input.subject.clone();
    let grade_for_filter = match input.grade_band.as_str() {
        "g10" | "g11-12" => "g10-12",
        other => other,
    };
    let filtered_stages: Vec<_> = plan.stages.iter()
        .filter(|s| {
            let gb = s.grade_band.as_str();
            gb == grade_for_filter || gb.is_empty()
        })
        .cloned()
        .collect();
    eprintln!("[READING-HANDLER] filtered stages: {} of {} (grade={})", filtered_stages.len(), plan.stages.len(), input.grade_band);

    // plan_content: 完整计划结构（写入一次，只读不改）
    let plan_content = serde_json::json!({
        "id": format!("{}_reading_plan", subj_key),
        "subject": subj_key,
        "grade_band": input.grade_band,
        "goal": plan.goal,
        "stages": filtered_stages,
    });
    let plan_content_str = serde_json::to_string(&plan_content).unwrap_or_default();

    // plan_json: 仅状态（task_name → status）
    let status_map: serde_json::Value = if let Some(stages) = plan_content.get("stages").and_then(|s| s.as_array()) {
        let mut map = serde_json::Map::new();
        for stage in stages {
            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                        map.insert(name.to_string(), serde_json::json!("pending"));
                    }
                }
            }
        }
        serde_json::Value::Object(map)
    } else {
        serde_json::Value::Object(serde_json::Map::new())
    };
    // 激活第一个任务（reading 模式 CP2 查找 in_progress 的前提）
    let status_map = activate_first_task(status_map, &plan_content);
    let plan_json_str = serde_json::to_string(&status_map).unwrap_or_default();
    eprintln!("[READING-HANDLER] plan_content={}B, plan_json={}B", plan_content_str.len(), plan_json_str.len());

    if plan_content_str.is_empty() {
        eprintln!("[READING-HANDLER] plan_content is EMPTY");
        return Json(serde_json::json!({"error": "Plan serialization failed"}));
    }

    // 先删该用户该科目同学段的所有 plan（UNIQUE (user_id, domain)）
    let _ = conn.execute(
        "DELETE FROM learning_plans WHERE user_id = ?1 AND domain = ?2",
        rusqlite::params![input.user_id, format!("{}_{}", input.subject, input.grade_band)],
    );
    if let Err(e) = conn.execute(
        "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, plan_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'reading', ?6, ?7, ?8, ?8)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), input.user_id, conv_id,
            format!("Reading: {} {}", input.subject, input.grade_band), format!("{}_{}", input.subject, input.grade_band),
            plan_content_str, plan_json_str, now_str],
    ) {
        eprintln!("[READING-HANDLER] Plan INSERT failed: {}", e);
        return Json(serde_json::json!({"error": format!("Plan insert: {}", e)}));
    }

    // 5. 导入该学段所有卡片（诗词卡 + 词卡），立即可复习
    let mut imported_cards = 0i64;
    if let Some(stages) = plan_content.get("stages").and_then(|s| s.as_array()) {
        for stage in stages {
            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    // 5a. 导入诗词卡
                    if let Some(card_id) = task.get("reading_card_id").and_then(|c| c.as_str()) {
                        if !card_id.is_empty() {
                            let card = format!("k12_{}", card_id);
                            let (card_front, card_back) = crate::reading_loader::get_card(card_id)
                                .map(|rc| {
                                    let front = rc.front.clone();
                                    let back = format!("{}\n\n{}",
                                        rc.full_text,
                                        ["author", "translation", "summary", "appreciation"]
                                            .iter().filter_map(|f| {
                                                let v = match *f {
                                                    "author" => rc.author.clone(),
                                                    "translation" => rc.translation.clone(),
                                                    "summary" => rc.summary.clone(),
                                                    "appreciation" => rc.appreciation.join("\n"),
                                                    _ => String::new(),
                                                };
                                                if v.is_empty() { None }
                                                else { Some(format!("【{}】\n{}",
                                                    match *f {
                                                        "author" => "作者",
                                                        "translation" => "翻译",
                                                        "summary" => "摘要",
                                                        "appreciation" => "赏析",
                                                        _ => f,
                                                    }, v)) }
                                            }).collect::<Vec<_>>().join("\n\n")
                                    );
                                    (front, back)
                                })
                                .unwrap_or_else(|| ("课文阅读".to_string(), "Reading-First Mode".to_string()));
                            let _ = conn.execute(
                                "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, subject, grade_band, k12_card_id)
                                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                                rusqlite::params![card, input.user_id, input.subject, "reading",
                                    card_front, card_back, conv_id, now_ts, input.subject, input.grade_band, card_id],
                            ).ok();
                            let _ = conn.execute(
                                "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                                 VALUES (?1, 0, 5.0, 0.0, ?2, NULL, 0, 0)",
                                rusqlite::params![card, now_ts],
                            ).ok();
                            imported_cards += 1;
                        }
                    }
                    // 5b. 导入该 task 的词卡
                    if let Some(vocab_ids) = task.get("vocab_card_ids").and_then(|v| v.as_array()) {
                        for vid_val in vocab_ids {
                            if let Some(vid) = vid_val.as_str() {
                                if vid.is_empty() { continue; }
                                if let Some(vc) = crate::curriculum_loader::get_card_by_id(vid) {
                                    let k12_id = format!("k12_{}", vid);
                                    let _ = conn.execute(
                                        "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, subject, grade_band, k12_card_id)
                                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                                        rusqlite::params![k12_id, input.user_id, input.subject, "vocabulary",
                                            vc.front, vc.back, conv_id, now_ts, input.subject, input.grade_band, vid],
                                    ).ok();
                                    let _ = conn.execute(
                                        "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                                         VALUES (?1, 0, 5.0, 0.0, ?2, NULL, 0, 0)",
                                        rusqlite::params![k12_id, now_ts],
                                    ).ok();
                                    imported_cards += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 6. 查找当前课文卡用于返回
    let current_card: Option<serde_json::Value> = (|| {
        let stages = plan_content.get("stages")?.as_array()?;
        let first_stage = stages.first()?;
        let tasks = first_stage.get("tasks")?.as_array()?;
        let first_task = tasks.first()?;
        let card_id = first_task.get("reading_card_id")?.as_str()?;
        if card_id.is_empty() { return None; }
        let card = crate::reading_loader::get_card(card_id)?;
        serde_json::to_value(card).ok()
    })();

    eprintln!("[READING-HANDLER] SUCCESS: conv_id={}, imported_cards={}, has_current_card={}",
        conv_id, imported_cards, current_card.is_some());
    Json(serde_json::json!({
        "conversation_id": conv_id,
        "plan": plan_content,
        "imported_cards": imported_cards,
        "current_card": current_card,
    }))
}

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
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 1. 读取 plan_content（结构）和 plan_json（状态）
    let (plan_content_str, plan_json_str): (String, String) = match conn.query_row(
        "SELECT plan_content, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'reading'",
        rusqlite::params![conv_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
    ) {
        Ok(v) => v,
        Err(_) => return Json(serde_json::json!({"error": "reading plan not found"})),
    };

    let plan_content: serde_json::Value = match serde_json::from_str(&plan_content_str) {
        Ok(v) => v,
        Err(_) => return Json(serde_json::json!({"error": "invalid plan content"})),
    };
    let plan_json: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap_or_default();

    // 2. 找到第一个未完成的 task 的 reading_card_id
    let card_id: Option<String> = (|| {
        let stages = plan_content.get("stages")?.as_array()?;
        for stage in stages {
            let tasks = stage.get("tasks")?.as_array()?;
            for task in tasks {
                let task_name = task.get("name")?.as_str()?;
                let status = plan_json.get(task_name).and_then(|s| s.as_str()).unwrap_or("pending");
                if status == "done" {
                    continue; // 已完成，跳过
                }
                // 找到第一个未完成/进行中的 task
                let cid = task.get("reading_card_id")?.as_str()?.to_string();
                if cid.is_empty() { return None; }
                return Some(cid);
            }
        }
        None
    })();

    let current_card = card_id
        .as_deref()
        .and_then(crate::reading_loader::get_card)
        .and_then(|card| serde_json::to_value(card).ok());

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
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 从 k12_progress 表读取所有进度记录
    let mut stmt = match conn.prepare(
        "SELECT subject, grade_band, mastered_cards, total_cards, started_at, last_activity_at, completed_at
         FROM k12_progress
         WHERE user_id = ?1
         ORDER BY subject, grade_band"
    ) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB prepare: {}", e)})),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map(
        rusqlite::params![query.user_id],
        |row| Ok(serde_json::json!({
            "subject": row.get::<_, String>(0)?,
            "grade_band": row.get::<_, String>(1)?,
            "mastered_cards": row.get::<_, i64>(2)?,
            "total_cards": row.get::<_, i64>(3)?,
            "started_at": row.get::<_, String>(4)?,
            "last_activity_at": row.get::<_, Option<String>>(5)?,
            "completed_at": row.get::<_, Option<String>>(6)?,
        }))
    ) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return Json(serde_json::json!({"error": format!("DB query: {}", e)})),
    };

    Json(serde_json::json!({
        "progress": rows,
        "total": rows.len(),
    }))
}
