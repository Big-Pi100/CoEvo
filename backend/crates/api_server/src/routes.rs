//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, delete}, Json, extract::{Path, Query}};
use axum::extract::ws::WebSocketUpgrade;
use axum::http::HeaderMap;
use serde::Deserialize;

use chat_engine::llm_caller::LlmConfig;

pub fn build_router(llm_config: LlmConfig) -> Router {
    // 存储 LLM 配置供 routes 使用
    crate::llm::init(llm_config);

    Router::new()
        .route("/health", get(health_check))
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
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
        // History
        .route("/api/history", get(history_handler))
        // Profile
        .route("/api/user/{user_id}/profile", get(profile_handler))
        // WS
        .route("/ws", get(ws_upgrade))
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
        Ok(resp) => Json(serde_json::json!(resp)),
        Err(e) => Json(serde_json::json!({"error": e})),
    }
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

    let llm_config = crate::llm::get_config();

    // Do all DB operations in one block — drop conn before async
    let (existing_fronts, skipped_fronts, _now_str, history) = {
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

    // 构建带上下文的 prompt
    let mut prompt = chat_engine::prompt_loader::get().chat_system.clone();
    if history.len() > 1 {
        let context = &history[..history.len() - 1];
        prompt.push_str("\n\n### 对话历史\n");
        for (role, content) in context {
            let label = if role == "user" { "用户" } else { "AI" };
            prompt.push_str(&format!("\n{}: {}", label, content));
        }
    }
    prompt.push_str(&format!("\n\n### 当前对话\n用户: {}", input.message));
    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    let reply = match caller.generate(&prompt).await {
        Ok(r) => r,
        Err(e) => return Json(serde_json::json!({"error": format!("LLM: {}", e)})),
    };

    // 2. ColdPath: 提取候选概念 (no Connection — uses pre-queried data)
    let extraction = chat_engine::concept_extractor::extract_concepts(
        &input.user_id, &input.message, &reply,
        &existing_fronts, &skipped_fronts, &llm_config,
    ).await;

    let candidates: Vec<String> = extraction.candidates.iter().map(|c| c.front.clone()).collect();

    // 3. 保存 assistant 回复 (新连接)
    let now_ts = chrono::Utc::now().timestamp();
    {
        let conn = crate::db_pool::get_conn();
        let _ = conn.execute(
            "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, 'assistant', ?3, ?4)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), input.conversation_id, reply, now_ts.to_string()],
        );
        let _ = conn.execute(
            "UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
            rusqlite::params![input.conversation_id],
        );
    }

    Json(serde_json::json!({
        "reply": reply,
        "candidates": candidates,
        "achievements": [],
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
    pub card_id: String,
    pub front: String,
    pub back: String,
}

/// AI 快问快答: 生成 3 个问题
async fn review_verify_handler(
    Json(input): Json<VerifyInput>,
) -> Json<serde_json::Value> {
    let llm_config = crate::llm::get_config();
    let prompt = chat_engine::prompt_loader::get().quiz_generate.clone()
        .replace("{front}", &input.front)
        .replace("{back}", &input.back);

    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    match caller.generate(&prompt).await {
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
    Json(input): Json<JudgeInput>,
) -> Json<serde_json::Value> {
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
    match caller.generate(&prompt).await {
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
        Ok(id) => Json(serde_json::json!({"skipped_id": id})),
        Err(e) => Json(serde_json::json!({"error": e})),
    }
}

async fn cards_skipped_handler(
    Query(query): Query<DueQuery>,
) -> Json<serde_json::Value> {
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
    Path(skip_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    match conn.execute("DELETE FROM skipped_concepts WHERE id = ?1", rusqlite::params![skip_id]) {
        Ok(_) => Json(serde_json::json!({"status": "removed"})),
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
                c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
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
}

/// GET /api/history — 获取对话历史
async fn history_handler(
    Query(query): Query<HistoryQuery>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let limit = query.limit.unwrap_or(50).min(200);

    if let Some(conv_id) = &query.conversation_id {
        // 查询指定对话的轮次
        let mut stmt = conn.prepare(
            "SELECT id, role, content, created_at
             FROM conversation_turns WHERE conversation_id = ?1
             ORDER BY created_at ASC LIMIT ?2"
        ).unwrap();
        let turns: Vec<serde_json::Value> = stmt.query_map(
            rusqlite::params![conv_id, limit],
            |row| Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "role": row.get::<_, String>(1)?,
                "content": row.get::<_, String>(2)?,
                "created_at": row.get::<_, String>(3)?,
            }))
        ).unwrap().filter_map(|r| r.ok()).collect();
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "turns": turns,
            "count": turns.len(),
        }));
    }

    // 查询用户的所有对话列表（含标题：第一条用户消息）
    let mut stmt = conn.prepare(
        "SELECT c.id, c.turn_count, c.started_at,
                (SELECT content FROM conversation_turns t
                 WHERE t.conversation_id = c.id AND t.role = 'user'
                 ORDER BY t.created_at ASC LIMIT 1) as first_msg
         FROM conversations c
         WHERE c.user_id = ?1 ORDER BY c.started_at DESC LIMIT ?2"
    ).unwrap();
    let conversations: Vec<serde_json::Value> = stmt.query_map(
        rusqlite::params![query.user_id, limit],
        |row| {
            let first_msg: Option<String> = row.get(3).ok().flatten();
            let title = first_msg.as_deref()
                .map(|s| if s.len() > 50 { format!("{}...", &s[..50]) } else { s.to_string() })
                .unwrap_or_else(|| "新对话".to_string());
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "turn_count": row.get::<_, i32>(1)?,
                "started_at": row.get::<_, String>(2)?,
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

    Json(serde_json::json!({
        "user_id": user_id,
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
