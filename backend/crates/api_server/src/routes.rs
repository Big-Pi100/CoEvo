//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, delete}, Json, extract::{Path, Query}, http::StatusCode, response::IntoResponse};
use axum::extract::ws::WebSocketUpgrade;
use axum::http::HeaderMap;
use serde::Deserialize;
use std::sync::OnceLock;
use std::collections::HashMap;

use chat_engine::llm_caller::LlmConfig;

/// Reusable HTTP client for STT requests — avoids creating a new connection pool per call
static STT_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn stt_client() -> &'static reqwest::Client {
    STT_CLIENT.get_or_init(|| reqwest::Client::new())
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
        // Conversation management
        .route("/api/conversations/{conv_id}", delete(conversation_delete_handler))
        .route("/api/conversations/{conv_id}/restore", post(conversation_restore_handler))
        .route("/api/conversations/{conv_id}/permanent", delete(conversation_permanent_delete_handler))
        // STT
        .route("/api/stt", post(stt_handler))
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
}

async fn auth_register(Json(input): Json<AuthInput>) -> Json<serde_json::Value> {
    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::register(&conn, &crate::auth::RegisterRequest {
            username: input.username,
            password: input.password,
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

async fn chat_handler(
    headers: HeaderMap,
    Json(input): Json<ChatInput>,
) -> Json<serde_json::Value> {
    // Verify auth
    if let Err(e) = crate::auth_middleware::verify_auth(&input.user_id, &headers) {
        return Json(serde_json::json!({"error": e}));
    }

    // 检查订阅状态（与 WS /ws 保持一致）
    {
        let conn = crate::db_pool::get_conn();
        let expires: Option<String> = conn.query_row(
            "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
            rusqlite::params![input.user_id],
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
            let msg = if expires.is_some() {
                "subscription_expired"
            } else {
                "subscription_required"
            };
            return Json(serde_json::json!({"error": msg}));
        }
    }

    let llm_config = crate::llm::get_config();

    // Do all DB operations in one block — drop conn before async
    let (existing_fronts, skipped_fronts, now_str, history) = {
        let conn = crate::db_pool::get_conn();

        // Pre-query for concept extraction
        let existing_fronts: Vec<String> = {
            let mut stmt = conn.prepare(
                "SELECT LOWER(front) FROM cards WHERE user_id = ?1"
            ).unwrap();
            let rows = stmt.query_map(rusqlite::params![input.user_id], |row| row.get::<_, String>(0))
                .unwrap();
            rows.filter_map(|r| r.ok()).collect()
        };
        let skipped_fronts: Vec<String> = {
            let mut stmt = conn.prepare(
                "SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1"
            ).unwrap();
            let rows = stmt.query_map(rusqlite::params![input.user_id], |row| row.get::<_, String>(0))
                .unwrap();
            rows.filter_map(|r| r.ok()).collect()
        };

        // 加载最近 10 轮历史
        let history: Vec<(String, String)> = {
            let mut stmt = conn.prepare(
                "SELECT role, content FROM conversation_turns
                 WHERE conversation_id = ?1
                 ORDER BY created_at DESC LIMIT 10"
            ).unwrap();
            let mut turns: Vec<(String, String)> = stmt.query_map(
                rusqlite::params![input.conversation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            ).unwrap().filter_map(|r| r.ok()).collect();
            turns.reverse();
            turns
        };

        let now = chrono::Utc::now();
        let now_str = now.to_rfc3339().to_string();

        // Save conversation turns
        let _ = conn.execute(
            "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
            rusqlite::params![input.conversation_id, input.user_id, now_str],
        );
        let _ = conn.execute(
            "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'user', ?3, ?4)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), input.conversation_id, input.message, now_str],
        );

        (existing_fronts, skipped_fronts, now_str, history)
    }; // conn dropped here

    // ── 查询学习计划，判定生命周期状态 ──
    let (system_prompt, plan_context) = {
        let conn = crate::db_pool::get_conn();
        let (mode, ctx) = crate::plan_handler::build_plan_context(&conn, &input.conversation_id);
        let templates = chat_engine::prompt_loader::get();
        let sp = if mode == "structured" {
            templates.chat_system_structured.clone()
        } else {
            templates.chat_system_free.clone()
        };
        (sp, ctx)
    };

    // 构建 user_content（对话历史 + 计划上下文 + 当前消息）
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
        user_content.push_str(&plan_context);
    }
    user_content.push_str(&format!("\n\n### 当前对话\n用户: {}", input.message));

    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    let raw_reply = match caller.generate(&system_prompt, &user_content).await {
        Ok(r) => r,
        Err(e) => return Json(serde_json::json!({"error": format!("LLM: {}", e)})),
    };

    // ── 解析 <plan_update> 标签（与 WebSocket 路径共用 plan_handler） ──
    let (final_reply, plan_updated) = {
        let conn = crate::db_pool::get_conn();
        let result = crate::plan_handler::handle_plan_update(
            &conn, &raw_reply, &input.conversation_id, &input.user_id,
        );

        let mut reply = result.cleaned_reply;

        // 新建计划 → 渲染计划文本替代 raw_reply
        if result.is_new_plan {
            if let Some(ref plan) = result.plan_json {
                reply = crate::plan_handler::render_plan(plan);
            }
        }

        // 成就检测（与 ws.rs 共用 plan_handler 函数）
        if result.plan_updated && !result.is_new_plan {
            if let Some(ref plan) = result.plan_json {
                // 检查 stage done → silver / gold
                if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                    for stage in stages {
                        if stage["status"] == "done" {
                            let stage_name = stage["name"].as_str().unwrap_or("阶段");
                            let key = format!("{}_silver", stage_name);
                            if !crate::plan_handler::achievement_exists(&conn, &input.user_id, &key) {
                                crate::plan_handler::write_achievement(&conn, &input.user_id,
                                    &key, &format!("{}精英", stage_name), "🥈", "silver", "stage");
                            }
                            if stages.iter().all(|s| s["status"] == "done") {
                                let domain_name = plan.get("goal").and_then(|v| v.as_str()).unwrap_or("领域");
                                let dkey = format!("{}_gold", domain_name);
                                if !crate::plan_handler::achievement_exists(&conn, &input.user_id, &dkey) {
                                    crate::plan_handler::write_achievement(&conn, &input.user_id,
                                        &dkey, &format!("{}大师", domain_name), "🥇", "gold", "domain");
                                }
                            }
                        }
                    }
                }
            }
        }

        (reply, result.plan_updated)
    };

    // 2. ColdPath: 提取候选概念 (no Connection — uses pre-queried data)
    let extraction = chat_engine::concept_extractor::extract_concepts(
        &input.user_id, &input.message, &final_reply,
        &existing_fronts, &skipped_fronts, &llm_config,
        &history,
    ).await;

    let candidates: Vec<String> = extraction.candidates.iter().map(|c| c.front.clone()).collect();

    // 3. 保存 assistant 回复 (新连接)
    {
        let conn = crate::db_pool::get_conn();
        let _ = conn.execute(
            "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'assistant', ?3, ?4)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), input.conversation_id, final_reply, now_str],
        );
        let _ = conn.execute(
            "UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
            rusqlite::params![input.conversation_id],
        );
    }

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
        return Json(serde_json::json!({"error": e}));
    }
    let conn = crate::db_pool::get_conn();
    let (cards, total) = card_engine::fsrs_scheduler::get_due_cards(&conn, &query.user_id, 20);
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
        return Json(serde_json::json!({"error": e}));
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
        return Json(serde_json::json!({"error": e}));
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
        return Json(serde_json::json!({"error": e}));
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
        return Json(serde_json::json!({"error": e}));
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
        return Json(serde_json::json!({"error": e}));
    }
    let conn = crate::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT id, front, domain, source_text, skipped_at FROM skipped_concepts WHERE user_id = ?1 ORDER BY skipped_at DESC"
    ).unwrap();
    let rows: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![query.user_id],
        |row| Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "front": row.get::<_, String>(1)?,
            "domain": row.get::<_, Option<String>>(2)?,
            "source_text": row.get::<_, String>(3)?,
            "skipped_at": row.get::<_, i64>(4)?,
        }))
    ).unwrap().filter_map(|r| r.ok()).collect();
    Json(serde_json::json!({"skipped": rows}))
}

async fn cards_skip_delete_handler(
    headers: HeaderMap,
    Path(skip_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

    // 1. 读取跳过的概念记录
    let skipped = match conn.query_row(
        "SELECT user_id, front, domain, source_text, skipped_at FROM skipped_concepts WHERE id = ?1",
        rusqlite::params![skip_id],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, i64>(4)?,
            ))
        }
    ) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("Skip not found: {}", e)})),
    };

    let (user_id, front, domain, source_text, _skipped_at) = skipped;

    // Verify auth with the user_id from the skipped record
    if let Err(e) = crate::auth_middleware::verify_auth(&user_id, &headers) {
        return Json(serde_json::json!({"error": e}));
    }

    // 2. 重新创建卡片
    let now = chrono::Utc::now().timestamp();
    let card_id = format!("card_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
    let back = source_text.clone().unwrap_or_default();
    let domain_str = domain.clone().unwrap_or_default();

    if let Err(e) = conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence, created_at)
         VALUES (?1, ?2, ?3, 'concept', ?4, ?5, ?6, ?7)",
        rusqlite::params![card_id, user_id, domain_str, front, back, source_text, now],
    ) {
        return Json(serde_json::json!({"error": format!("Card insert: {}", e)}));
    }

    // 3. 创建卡片记忆状态（新卡片，今天到期）
    if let Err(e) = conn.execute(
        "INSERT INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
         VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
        rusqlite::params![card_id, now],
    ) {
        // 回滚卡片
        let _ = conn.execute("DELETE FROM cards WHERE id = ?1", rusqlite::params![card_id]);
        return Json(serde_json::json!({"error": format!("Card memory insert: {}", e)}));
    }

    // 4. 删除跳过记录
    match conn.execute("DELETE FROM skipped_concepts WHERE id = ?1", rusqlite::params![skip_id]) {
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
    Json(input): Json<BatchCreateInput>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let mut created = Vec::new();
    let mut duplicates = Vec::new();
    let mut errors = Vec::new();

    for cand in &input.candidates {
        let candidate = shared_types::card::ConceptCandidate {
            front: cand.front.clone(),
            back: cand.back.clone(),
            source_sentence: cand.source_sentence.clone(),
            domain: cand.domain.clone().unwrap_or_else(|| "general".into()),
        };
        let (card, memory) = card_engine::card_formatter::format_card(&input.user_id, &candidate);
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
    pub sort: Option<String>,      // "front" | "created" | "state" | "due"
}

async fn cards_all_handler(
    Query(query): Query<AllCardsQuery>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

    let mut sql = String::from(
        "SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
                c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                lrev.reviewed_at, lrev.rating
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

    let mut stmt = conn.prepare(&sql).unwrap();
    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let rows: Vec<serde_json::Value> = stmt.query_map(
        param_refs.as_slice(),
        |row| Ok(serde_json::json!({
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
        }))
    ).unwrap().filter_map(|r| r.ok()).collect();

    // 聚合统计数据
    let total = rows.len();
    let states = [0, 1, 2, 3];
    let state_counts: Vec<i32> = states.iter().map(|&s| {
        rows.iter().filter(|r| r["state"].as_i64() == Some(s as i64)).count() as i32
    }).collect();

    // 领域列表
    let domains: Vec<String> = {
        let mut stmt = conn.prepare(
            "SELECT DISTINCT domain FROM cards WHERE user_id = ?1 AND domain IS NOT NULL ORDER BY domain"
        ).unwrap();
        stmt.query_map(rusqlite::params![query.user_id], |row| row.get::<_, String>(0))
            .unwrap().filter_map(|r| r.ok()).collect()
    };

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
        return Json(serde_json::json!({"error": e}));
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
                    result.as_object_mut().unwrap().insert("details".to_string(), details);
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
        return Json(serde_json::json!({"error": e}));
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

    // 查询用户的所有对话列表（含标题：第一条用户消息）
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
                 ORDER BY t.created_at ASC LIMIT 1) as first_msg
         FROM conversations c
         WHERE c.user_id = ?1{} ORDER BY c.started_at DESC LIMIT ?2",
        deleted_filter
    );
    let mut stmt = conn.prepare(&sql).unwrap();
    let conversations: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![query.user_id, limit],
        |row| {
            let first_msg: Option<String> = row.get(4).ok().flatten(); // col 4 (after added deleted_at)
            let title = first_msg.as_deref()
                .map(|s| if s.len() > 50 { format!("{}...", &s[..50]) } else { s.to_string() })
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
        return Json(serde_json::json!({"error": e}));
    }
    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    match conn.execute(
        "UPDATE conversations SET deleted_at = ?1 WHERE id = ?2 AND user_id = ?3 AND deleted_at IS NULL",
        rusqlite::params![now, conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found or already deleted"})),
        Ok(_) => Json(serde_json::json!({"status": "ok", "deleted_at": now})),
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
        return Json(serde_json::json!({"error": e}));
    }
    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE conversations SET deleted_at = NULL WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NOT NULL",
        rusqlite::params![conv_id, query.user_id],
    ) {
        Ok(0) => Json(serde_json::json!({"error": "Conversation not found or not deleted"})),
        Ok(_) => Json(serde_json::json!({"status": "ok"})),
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
        return Json(serde_json::json!({"error": e}));
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
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

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

    Json(serde_json::json!({
        "user_id": user_id,
        "display_name": display_name,
        "stats": {
            "total_cards": total_cards,
            "total_reviews": total_reviews,
            "streak_days": streak_days,
            "domains_covered": domains_covered,
            "today_reviews": today_reviews,
        },
        "achievements": achievements,
    }))
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
    while let Ok(Some(field)) = multipart.next_field().await {
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
}

async fn plans_list_handler(
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();

    let (sql, param_val): (&str, String) = if let Some(conv_id) = params.get("conversation_id") {
        ("SELECT id, goal, domain, mode, plan_json, created_at, updated_at FROM learning_plans WHERE conversation_id = ?1 ORDER BY created_at DESC", conv_id.clone())
    } else if let Some(uid) = params.get("user_id") {
        ("SELECT id, goal, domain, mode, plan_json, created_at, updated_at FROM learning_plans WHERE user_id = ?1 ORDER BY created_at DESC", uid.clone())
    } else {
        return Json(serde_json::json!({"error": "user_id or conversation_id required"}));
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB: {}", e)})),
    };
    let plans: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![param_val], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "goal": row.get::<_, String>(1)?,
            "domain": row.get::<_, String>(2)?,
            "mode": row.get::<_, Option<String>>(3)?,
            "plan": serde_json::from_str::<serde_json::Value>(&row.get::<_, String>(4)?).ok(),
            "created_at": row.get::<_, String>(5)?,
            "updated_at": row.get::<_, String>(6)?,
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

    // Check if plan exists for this user+domain
    let existing_id: Option<String> = conn.query_row(
        "SELECT id FROM learning_plans WHERE user_id = ?1 AND domain = ?2 AND mode != 'deleted' LIMIT 1",
        rusqlite::params![input.user_id, input.domain],
        |row| row.get(0),
    ).ok();

    if let Some(id) = existing_id {
        // Update existing
        match conn.execute(
            "UPDATE learning_plans SET goal=?1, plan_json=?2, updated_at=?3 WHERE id=?4",
            rusqlite::params![input.goal, plan_str, now, id],
        ) {
            Ok(_) => Json(serde_json::json!({"id": id, "status": "updated"})),
            Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
        }
    } else {
        // Insert new
        let id = uuid::Uuid::new_v4().to_string();
        match conn.execute(
            "INSERT INTO learning_plans (id, user_id, goal, domain, mode, plan_json, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, 'structured', ?5, ?6, ?6)",
            rusqlite::params![id, input.user_id, input.goal, input.domain, plan_str, now],
        ) {
            Ok(_) => Json(serde_json::json!({"id": id, "status": "created"})),
            Err(e) => Json(serde_json::json!({"error": format!("DB: {}", e)})),
        }
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
        "SELECT plan_json, goal, mode, updated_at FROM learning_plans WHERE user_id = ?1 AND mode != 'deleted' ORDER BY updated_at DESC"
    ).unwrap();
    let mut plans: Vec<serde_json::Value> = Vec::new();
    for row in stmt_plans.query_map(rusqlite::params![user_id], |row| {
        let pj: String = row.get(0)?;
        let goal: String = row.get(1)?;
        let mode: String = row.get(2)?;
        let updated: String = row.get(3)?;
        Ok((pj, goal, mode, updated))
    }).unwrap().filter_map(|r| r.ok()) {
        let (pj, goal, mode, updated) = row;
        if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pj) {
            let mut total_tasks = 0u32;
            let mut done_tasks = 0u32;
            let mut current_stage = "";
            if let Some(stages) = plan.get("stages").and_then(|v| v.as_array()) {
                for stage in stages {
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

#[derive(Deserialize)]
struct AdminUsersQuery {
    q: String,
}

async fn admin_users_handler(
    headers: HeaderMap,
    Query(query): Query<AdminUsersQuery>,
) -> impl IntoResponse {
    // 验证管理员密钥
    let admin_key = std::env::var("COEVO_ADMIN_KEY").unwrap_or_default();
    let got = headers.get("x-admin-key").and_then(|v| v.to_str().ok()).unwrap_or("");
    if admin_key.is_empty() || got != admin_key {
        return (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "unauthorized"}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let pattern = format!("%{}%", query.q);

    let mut stmt = conn.prepare(
        "SELECT id, username, created_at FROM users WHERE id LIKE ?1 OR username LIKE ?1 LIMIT 20"
    ).unwrap();

    let users: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![pattern],
        |row| {
            let user_id: String = row.get(0)?;
            Ok((user_id, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        },
    ).unwrap().filter_map(|r| r.ok()).map(|(uid, uname, created)| {
        let expires: Option<String> = conn.query_row(
            "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'subscription_expires'",
            rusqlite::params![uid],
            |row| row.get(0),
        ).ok();
        serde_json::json!({
            "user_id": uid,
            "username": uname,
            "created_at": created,
            "subscription_expires": expires,
        })
    }).collect();

    Json(serde_json::json!({"users": users})).into_response()
}

// ════════════════════════════════════════════
// ════════════════════════════════════════════
// STT Proxy — 录音 → ffmpeg转WAV → 科大讯飞 → 返回文字
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