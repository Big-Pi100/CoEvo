//! API Routes
//!
//! 复用 LinguaFlow routes.rs 的模式

use axum::{Router, routing::{get, post, put, delete, patch}, Json, extract::{Path, Query}, response::IntoResponse};
use axum::extract::ws::WebSocketUpgrade;
use axum::http::{HeaderMap, StatusCode, header};
use tower_http::trace::TraceLayer;
use std::collections::HashMap;
use std::sync::OnceLock;
use serde::Deserialize;
use serde_json::json;

use crate::error::AppError;
use crate::admin_handlers::*;

/// 提供 Flutter Web 构建的静态文件（SPA 模式：未匹配路径返回 index.html）
const FLUTTER_WEB_DIR: &str = "../app/build/web";

async fn serve_flutter_web(Path(path): Path<String>) -> impl IntoResponse {
    let base = std::path::Path::new(FLUTTER_WEB_DIR);
    let file_path = if path.is_empty() || path == "index.html" || !path.contains('.') {
        // 无扩展名路径 → SPA fallback
        base.join("index.html")
    } else {
        let p = base.join(&path);
        if p.starts_with(base) && p.is_file() { p } else { base.join("index.html") }
    };

    // 尝试读取文件
    match tokio::fs::read(&file_path).await {
        Ok(data) => {
            let ext = file_path.extension().and_then(|e| e.to_str()).unwrap_or("");
            let mime = match ext {
                "html" => "text/html; charset=utf-8",
                "js" | "mjs" => "application/javascript",
                "css" => "text/css",
                "png" => "image/png",
                "jpg" | "jpeg" => "image/jpeg",
                "svg" => "image/svg+xml",
                "json" => "application/json",
                "wasm" => "application/wasm",
                "ico" => "image/x-icon",
                "map" => "application/json",
                _ => "application/octet-stream",
            };
            (StatusCode::OK, [(header::CONTENT_TYPE, mime)], data).into_response()
        }
        Err(_) if file_path.ends_with("index.html") => {
            (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")], b"<h1>App not built</h1><p>Run: cd app && flutter build web</p>" as &[u8]).into_response()
        }
        Err(_) => {
            // 文件不存在 → SPA fallback
            match tokio::fs::read(base.join("index.html")).await {
                Ok(data) => (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")], data).into_response(),
                Err(_) => (StatusCode::NOT_FOUND, "App not built").into_response(),
            }
        }
    }
}

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
        // ── Public ──
        .route("/api/public/qrcode", get(crate::config_admin::qrcode_handler))
        // ── Payment & Subscription ──
        .route("/api/pay/plans", get(crate::plans_handlers::plans_list_handler))
        .route("/api/pay/native", post(crate::pay_handlers::native_pay_handler))
        .route("/api/pay/notify", post(crate::pay_handlers::pay_notify_handler))
        .route("/api/pay/orders", get(crate::pay_handlers::user_orders_handler))
        .route("/api/pay/orders/{id}", get(crate::pay_handlers::order_status_handler))
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
        .route("/api/user/{user_id}/plan-achievements", get(plan_achievements_handler))
        .route("/api/user/{user_id}/preferences", get(preferences_get_handler).put(preferences_put_handler))
        .route("/api/user/{user_id}/subscription", get(user_subscription_handler))
        .route("/api/tts/preview", post(tts_preview_handler))
        .route("/api/tts/speak", post(tts_speak_handler))
        .route("/api/stt/transcribe", post(stt_transcribe_handler))
        .route("/api/user/bind-lookup", post(bind_lookup_handler))
        // ── Learning Plans ──
        .route("/api/plans", get(plans_list_handler))
        // ── Learning Reports (Dashboard) ──
        .route("/api/user/{user_id}/learning-report", get(learning_report_handler))
        .route("/api/user/{user_id}/activity", get(activity_handler))
        .route("/api/user/{user_id}/weekly-report", get(weekly_report_handler))
        // ── K12 Structured Learning ──
        .route("/api/k12/init", post(k12_init_handler))
        .route("/api/k12/subjects", get(k12_subjects_handler))
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
        // ── Admin: 支付 & 套餐管理 ──
        .route("/api/admin/plans", get(crate::plans_handlers::admin_plans_list_handler).post(crate::plans_handlers::admin_plan_create_handler))
        .route("/api/admin/plans/{id}", put(crate::plans_handlers::admin_plan_update_handler))
        .route("/api/admin/pay/orders", get(crate::pay_handlers::admin_orders_handler))
        // ── Admin: Audit Log ──
        .route("/api/admin/users/{user_id}/audit-log", get(admin_audit_log_handler))
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
        // ── Admin: Curriculum Management ──
        .route("/api/admin/curriculum/load", post(crate::curriculum_admin::curriculum_load_handler))
        .route("/api/admin/curriculum/status", get(crate::curriculum_admin::curriculum_status_handler))
        .route("/api/admin/curriculum/git-log", get(crate::curriculum_admin::git_log_handler))
        .route("/api/admin/curriculum/rollback", post(crate::curriculum_admin::rollback_handler))
        // GET — 读取端点
        .route("/api/admin/curriculum/subject/{subject}/plan", get(crate::curriculum_admin::get_plan_handler).patch(crate::curriculum_admin::patch_plan_handler).put(crate::curriculum_admin::put_plan_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards", get(crate::curriculum_admin::list_cards_handler))
        .route("/api/admin/curriculum/subject/{subject}/relations", get(crate::curriculum_admin::list_relations_handler).post(crate::curriculum_admin::create_relation_handler))
        .route("/api/admin/curriculum/subject/{subject}/relations/{relation_id}", delete(crate::curriculum_admin::delete_relation_handler))
        // PATCH — 修改单个实体（即改即用）
        .route("/api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}", patch(crate::curriculum_admin::patch_stage_handler))
        .route("/api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks/{task_id}", patch(crate::curriculum_admin::patch_task_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards/{card_id}", patch(crate::curriculum_admin::patch_card_handler))
        // POST — 新增实体
        .route("/api/admin/curriculum/subject/{subject}/plan/stages", post(crate::curriculum_admin::post_stage_handler))
        .route("/api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks", post(crate::curriculum_admin::post_task_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards", post(crate::curriculum_admin::post_card_handler))
        .route("/api/admin/curriculum/plan", post(crate::curriculum_admin::post_plan_handler))
        // DELETE — 删除实体
        .route("/api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}", delete(crate::curriculum_admin::delete_stage_handler))
        .route("/api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks/{task_id}", delete(crate::curriculum_admin::delete_task_handler))
        .route("/api/admin/curriculum/subject/{subject}/plan", delete(crate::curriculum_admin::delete_plan_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards/{card_id}", delete(crate::curriculum_admin::delete_card_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards", put(crate::curriculum_admin::put_cards_handler))
        // Gap 1: 模版下载
        .route("/api/admin/curriculum/templates/plan", get(crate::curriculum_admin::get_plan_template_handler))
        .route("/api/admin/curriculum/templates/cards", get(crate::curriculum_admin::get_cards_template_handler))
        // Gap 2: JSON 数据导入（不触发加载）
        .route("/api/admin/curriculum/subject/{subject}/plan/import", post(crate::curriculum_admin::import_plan_handler))
        .route("/api/admin/curriculum/subject/{subject}/cards/import", post(crate::curriculum_admin::import_cards_handler))
        // ── Admin: Config & Debug ──
        .route("/api/admin/config", get(crate::config_admin::get_config_handler).post(crate::config_admin::post_config_handler))
        .route("/api/admin/prompt/template", get(crate::config_admin::get_template_handler).post(crate::config_admin::post_template_handler))
        .route("/api/admin/prompt/templates", get(crate::config_admin::list_templates_handler))
        .route("/api/admin/debug/track", post(crate::config_admin::debug_track_handler))
        .route("/api/admin/debug/track/{id}", delete(crate::config_admin::debug_untrack_handler))
        .route("/api/admin/debug/tracks", get(crate::config_admin::debug_tracks_handler))
        .route("/api/admin/debug/logs", get(crate::config_admin::debug_logs_handler))
        .route("/api/admin/debug/logs/{id}", get(crate::config_admin::debug_log_detail_handler))
        // ── Distribution & Marketing ──
        // 用户端 API
        .route("/api/campaigns/check-push-trigger", get(crate::campaign_handler::check_push_trigger))
        .route("/api/referral/click", post(crate::referral_handler::click))
        .route("/api/referral/my-code", get(crate::referral_handler::my_code))
        .route("/api/referral/my-stats", get(crate::referral_handler::my_stats))
        .route("/api/referral/my-team", get(crate::referral_handler::my_team))
        .route("/api/referral/my-commissions", get(crate::referral_handler::my_commissions))
        .route("/api/referral/generate-poster", post(crate::referral_handler::generate_poster))
        .route("/api/referral/generate-h5", post(crate::referral_handler::generate_h5))
        .route("/api/referral/user-portrait", get(crate::referral_handler::user_portrait))
        .route("/api/referral/qrcode", get(crate::referral_handler::get_qrcode))
        .route("/api/campaign/join", post(crate::campaign_member_handler::join))
        .route("/api/trial/start", post(crate::trial_handler::start))
        .route("/api/trial/claim", put(crate::trial_handler::claim))
        // 用户端提现
        .route("/api/referral/withdraw", post(crate::distribution_handler::user_withdraw))
        .route("/api/referral/my-withdrawals", get(crate::distribution_handler::user_withdrawals))
        // 推广落地页
        .route("/share/{code}", get(crate::referral_handler::share_landing))
        .route("/go/{code}", get(crate::referral_handler::share_landing))
        .route("/api/pay/calculate", post(crate::distribution_handler::calculate))
        .route("/api/referral/user-campaign", get(crate::distribution_handler::user_campaign))
        .route("/api/notifications", get(crate::distribution_handler::list_notifications))
        .route("/api/notifications/{id}/read", post(crate::distribution_handler::mark_read))
        .route("/api/notifications/read-all", post(crate::distribution_handler::mark_read_all))
        // 管理端活动 API
        .route("/api/admin/campaigns", get(crate::campaign_handler::list).post(crate::campaign_handler::create))
        .route("/api/admin/campaigns/default-poster-prompt", get(crate::campaign_handler::default_poster_prompt))
        .route("/api/admin/campaigns/{id}", get(crate::campaign_handler::get).put(crate::campaign_handler::update).delete(crate::campaign_handler::delete))
        .route("/api/admin/campaigns/{id}/status", patch(crate::campaign_handler::toggle_status))
        .route("/api/admin/campaigns/{id}/push", post(crate::campaign_handler::push))
        .route("/api/admin/campaigns/{id}/stats", get(crate::campaign_handler::stats))
        .route("/api/admin/campaigns/{id}/generate-poster-template", post(crate::campaign_handler::generate_poster_template))
        .route("/api/admin/campaigns/{id}/generate-h5-template", post(crate::campaign_handler::generate_h5_template))
        .route("/api/admin/campaigns/{id}/preview-poster", post(crate::campaign_handler::preview_poster))
        .route("/api/admin/campaigns/{id}/preview-h5", post(crate::campaign_handler::preview_h5))
        // 管理端结算 API
        .route("/api/admin/settlement/pending-commissions", get(crate::distribution_handler::pending_commissions))
        .route("/api/admin/settlement/batches/export-all", get(crate::distribution_handler::export_all_batches))
        .route("/api/admin/settlement/batches", get(crate::distribution_handler::list_batches))
        .route("/api/admin/settlement/batches/{batch_no}", get(crate::distribution_handler::get_batch))
        .route("/api/admin/settlement/batches/{batch_no}/export", get(crate::distribution_handler::export_batch))
        .route("/api/admin/settlement/complete-payment", post(crate::distribution_handler::mark_paid))
        .route("/api/admin/settlement/pending-export", get(crate::distribution_handler::export_pending_csv))
        // 管理端提现 API
        .route("/api/admin/withdrawals", get(crate::distribution_handler::list_withdrawals))
        .route("/api/admin/withdrawals/{id}/approve", post(crate::distribution_handler::approve_withdrawal))
        .route("/api/admin/withdrawals/{id}/reject", post(crate::distribution_handler::reject_withdrawal))
        // 管理端团队 API
        .route("/api/admin/team", get(crate::distribution_handler::admin_team))
        .route("/api/admin/team/{user_id}", get(crate::distribution_handler::admin_team_user))
        // 管理端统计 API
        .route("/api/admin/distribution/stats", get(crate::distribution_handler::admin_stats))
        .route("/api/admin/distribution/funnel", get(crate::distribution_handler::admin_funnel))
        .route("/api/admin/distribution/summary", get(crate::distribution_handler::admin_summary))
        .route("/api/admin/distribution/monthly-stats", get(crate::distribution_handler::admin_monthly_stats))
        .route("/api/admin/distribution/ranking", get(crate::distribution_handler::admin_ranking))
        .route("/api/admin/distribution/export", get(crate::distribution_handler::admin_export))
        // 退款 API
        .route("/api/admin/refund/{order_id}", post(crate::distribution_handler::admin_refund))
        .route("/api/webhook/refund", post(crate::distribution_handler::webhook_refund))
        // ── Flutter Web App 静态文件（SPA 路由） ──
        .route("/app/{*path}", get(serve_flutter_web))
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
    pub referral: Option<crate::auth::ReferralInfo>,
}

/// POST /api/auth/register — 注册新用户
/// 请求: {"username": "str", "password": "str", "real_name?": "str", "phone?": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
/// 限流: 5 次/分钟/IP
async fn auth_register(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!("auth_register: user_id={}, referral={:?}", input.username, input.referral);

    // Rate limit: 20 reg/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 20, 60) { return resp; }

    let result = {
        let conn = crate::db_pool::get_conn();
        crate::auth::register(&conn, &crate::auth::RegisterRequest {
            username: input.username,
            password: input.password,
            real_name: input.real_name,
            phone: input.phone,
            referral: input.referral,
        })
    };
    match result {
        Ok(resp) => Json(serde_json::json!(resp)).into_response(),
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
    }
}

/// POST /api/auth/login — 用户登录
/// 请求: {"username": "str", "password": "str"}
/// 响应: {"user_id": "uuid", "token": "str"} 或 {"error": "str"}
/// 注意: 登录后会踢掉同一用户的其他 WebSocket 连接（单设备登录）
/// 限流: 10 次/分钟/IP
async fn auth_login(
    headers: HeaderMap,
    Json(input): Json<AuthInput>,
) -> impl axum::response::IntoResponse {
    tracing::info!("auth_login: user_id={}", input.username);

    // Rate limit: 10 login/min per IP
    if let Err(resp) = crate::rate_limiter::check_rate_limit(&headers, 10, 60) { return resp; }

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
            Json(serde_json::json!(resp)).into_response()
        },
        Err(e) => Json(serde_json::json!({"error": e})).into_response(),
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
    let real_name: Option<String> = if valid {
        conn.query_row(
            "SELECT real_name FROM users WHERE id = ?1",
            rusqlite::params![input.user_id],
            |row| row.get(0),
        ).ok().flatten()
    } else {
        None
    };
    Json(serde_json::json!({"valid": valid, "real_name": real_name}))
}

// ── Review Handlers ──

#[derive(Deserialize)]
pub struct DueQuery {
    pub user_id: String,
    pub conversation_id: Option<String>,
    pub language: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

/// GET /api/review/due — 获取到期待复习的卡片
/// 请求参数: ?user_id=str[&conversation_id=str][&language=english][&limit=20][&offset=0]
/// 响应: {"cards": [...], "total_due": int, "has_more": bool}
async fn review_due_handler(
    headers: HeaderMap,
    Query(query): Query<DueQuery>,
) -> Json<serde_json::Value> {
    tracing::info!("review_due_handler: user_id={}, conv_id={:?}, language={:?}", 
        query.user_id, query.conversation_id, query.language);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let page_size = query.limit.unwrap_or(20);
    let offset = query.offset.unwrap_or(0);
    let (cards, total) = card_engine::fsrs_scheduler::get_due_cards(
        &conn, &query.user_id, page_size, offset, query.conversation_id.as_deref(), query.language.as_deref(),
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

    // ── 注入最近 10 轮考题历史 ──
    let history_context = {
        let conn = crate::db_pool::get_conn();
        let mut context = String::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT details_json, verification_result FROM review_log
             WHERE card_id = ?1 AND details_json IS NOT NULL AND details_json != ''
             ORDER BY reviewed_at DESC LIMIT 10"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![input.card_id], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, String>(1)?,
                ))
            }) {
                let logs: Vec<_> = rows.filter_map(|r| r.ok()).collect();
                if !logs.is_empty() {
                    context.push_str("\n\n### 近期考题记录（供参考，避免重复出题）\n");
                    for (log_idx, (details, result)) in logs.iter().enumerate() {
                        context.push_str(&format!("\n第{}轮（{}）：\n", logs.len() - log_idx, result));
                        if let Some(d) = details {
                            if let Ok(parsed) = serde_json::from_str::<Vec<serde_json::Value>>(d) {
                                for (i, q) in parsed.iter().enumerate() {
                                    let question = q.get("question").and_then(|v| v.as_str()).unwrap_or("");
                                    let expected = q.get("expected").and_then(|v| v.as_str()).unwrap_or("");
                                    let actual = q.get("actual").and_then(|v| v.as_str()).unwrap_or("");
                                    let correct = q.get("correct").and_then(|v| v.as_bool()).unwrap_or(false);
                            let mark = if correct { "correct" } else { "wrong" };
                            context.push_str(&format!(
                                "  Q{}: {} | 预期: {} | 用户答: {} | {}\n",
                                i + 1, question, expected, actual, mark
                            ));
                                }
                            }
                        }
                    }
                }
            }
        }
        context
    };

    let llm_config = crate::llm::get_config();
    let prompt = chat_engine::prompt_loader::get_quiz("general").generate.clone()
        .replace("{front}", &input.front)
        .replace("{back}", &input.back);
    // 如果有历史记录，注入到 prompt 末尾
    let full_prompt = if history_context.is_empty() {
        prompt
    } else {
        format!("{}{}", prompt, history_context)
    };

    let mut caller = chat_engine::llm_caller::LlmCaller::new(llm_config.clone());
    match caller.generate("", &full_prompt).await {
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
    tracing::info!("review_cards_by_progress_handler: user_id={}", query.user_id);
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }
    let conn = crate::db_pool::get_conn();
    let mut plan_info: std::collections::HashMap<String, serde_json::Value> = std::collections::HashMap::new();
    let cards: Vec<serde_json::Value> = match conn.prepare(
        "SELECT c.id, c.user_id, c.front,
                COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') as back,
                c.domain, pc.subject, pc.card_type,
                '' as source_sentence, c.created_at, pr.conversation_id, c.plan_run_id, c.task_key,
                upp.status as task_status,
                pr.goal as plan_goal, pr.subject as plan_subject, pr.grade_band as plan_grade_band
         FROM user_cards c
         JOIN card_memory cm ON c.id = cm.user_card_id
         JOIN user_plan_progress upp ON c.plan_run_id = upp.plan_id AND c.task_key = upp.task_key
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id
                 LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
                 LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
                 LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
                 LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
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
                    "created_at": row.get::<_, String>(8)?,
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
        "SELECT c.id, c.user_id, c.front,
                COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') as back,
                c.domain, pc.subject, pc.card_type,
                '' as source_sentence,
                c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                lrev.reviewed_at, lrev.rating,
                pr.conversation_id, c.plan_run_id, c.task_key
         FROM user_cards c
         JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id
                 LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
                 LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
                 LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
                 LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
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
        sql.push_str(&format!(" AND pc.subject = ?{}", params.len()));
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
            sql.push_str(&format!(" AND (c.front LIKE ?{} OR COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') LIKE ?{})", params.len(), params.len()));
        }
    }

    // 隐藏非 vocabulary 的预制卡（对话生成卡不受影响）
    sql.push_str(" AND NOT (c.plan_run_id IS NULL AND pc.card_type != 'vocabulary')");

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
        "created_at": row.get::<_, String>(8)?,
        "state": row.get::<_, i32>(9)?,
        "difficulty": row.get::<_, f64>(10)?,
        "due": row.get::<_, i64>(11)?,
        "reps": row.get::<_, i32>(12)?,
        "lapses": row.get::<_, i32>(13)?,
        "last_reviewed_at": row.get::<_, Option<i64>>(14)?,
        "last_review_quality": row.get::<_, Option<i32>>(15)?,
        "conversation_id": row.get::<_, Option<String>>(16)?,
        "plan_id": row.get::<_, Option<String>>(17)?,
        "task_key": row.get::<_, Option<String>>(18)?,
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
        "SELECT DISTINCT domain FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND c.domain IS NOT NULL AND cm.status = 'active' ORDER BY domain",
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
    tracing::info!("cards_by_plan_handler: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return auth_json(e);
    }

    let conn = crate::db_pool::get_conn();

    // 1. 获取用户所有 plan
    let mut stmt = match conn.prepare(
        "SELECT id, conversation_id, goal, grade_band FROM plan_runs WHERE user_id = ?1 ORDER BY created_at DESC"
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
                "SELECT c.id, c.user_id, c.front,
                        COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, 
                                 usc.definition, ulc.pronunciation, ulf.full_text, uhc.body, '') as back,
                        c.domain, pc.subject, pc.card_type,
                        '' as source_sentence,
                        c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
                        lrev.reviewed_at, lrev.rating,
                        pr.conversation_id, c.plan_run_id, c.task_key,
                        usc.definition, usc.key_elements, usc.applications, usc.related_concepts,
                        ulc.pronunciation, ulc.definitions, ulc.related_phrases, ulc.pos,
                        ulf.full_text, ulf.translation, ulf.author, ulf.genre,
                        uhc.body, uhc.period, uhc.region, uhc.tags
                 FROM user_cards c
                 JOIN card_memory cm ON c.id = cm.user_card_id
                 LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
                 LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id
                 LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
                 LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
                 LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
                 LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
                 LEFT JOIN user_science_cards usc ON c.id = usc.id
                 LEFT JOIN user_language_cards ulc ON c.id = ulc.id
                 LEFT JOIN user_literature_cards ulf ON c.id = ulf.id
                 LEFT JOIN user_humanities_cards uhc ON c.id = uhc.id
                 LEFT JOIN (
                    SELECT card_id, MAX(reviewed_at) as last_reviewed_at
                    FROM review_log GROUP BY card_id
                 ) lr ON c.id = lr.card_id
                 LEFT JOIN review_log lrev
                    ON lrev.card_id = lr.card_id AND lrev.reviewed_at = lr.last_reviewed_at
                 WHERE pr.conversation_id = '{}' AND c.user_id = '{}' AND cm.status = 'active'
                 ORDER BY {}
                 LIMIT {} OFFSET {}",
                conv_id.replace('\'', "''"),
                query.user_id.replace('\'', "''"),
                order_col, page_size, page_offset,
            );
            tracing::info!("cards_by_plan SQL: {}", sql);
            let loaded: Vec<serde_json::Value> = match conn.prepare(&sql) {
                Ok(mut stmt) => stmt.query_map([], |row| {
                    let domain = row.get::<_, Option<String>>(4)?;
                    Ok(serde_json::json!({
                        "id": row.get::<_, String>(0)?,
                        "user_id": row.get::<_, String>(1)?,
                        "front": row.get::<_, String>(2)?,
                        "back": row.get::<_, String>(3)?,
                        "domain": domain,
                        "card_type": row.get::<_, Option<String>>(6)?,
                        "source_sentence": row.get::<_, Option<String>>(7)?,
                        "created_at": row.get::<_, String>(8)?,
                        "state": row.get::<_, i32>(9)?,
                        "difficulty": row.get::<_, f64>(10)?,
                        "due": row.get::<_, i64>(11)?,
                        "reps": row.get::<_, i32>(12)?,
                        "lapses": row.get::<_, i32>(13)?,
                        "last_reviewed_at": row.get::<_, Option<i64>>(14)?,
                        "last_review_quality": row.get::<_, Option<i32>>(15)?,
                        "conversation_id": row.get::<_, Option<String>>(16)?,
                        "plan_id": row.get::<_, Option<String>>(17)?,
                        "task_key": row.get::<_, Option<String>>(18)?,
                    }))
                }).unwrap().filter_map(|r| r.ok()).collect(),
                Err(e) => {
                    tracing::warn!("cards_by_plan prepare failed: {}", e);
                    vec![]
                },
            };
            let count = loaded.len();
            (loaded, count)
        } else {
            let count: usize = conn.query_row(
                "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id WHERE pr.conversation_id = ?1 AND c.user_id = ?2 AND cm.status = 'active'",
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

    tracing::info!("cards_by_plan_handler EXIT");

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
        "SELECT c.id, c.user_id, c.front,
                COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') as back,
                c.domain, pc.subject, pc.card_type,
                '' as source_sentence, c.created_at, pr.conversation_id, c.plan_run_id, c.task_key,
                cm.state, cm.reps, cm.lapses, cm.difficulty, cm.due
         FROM user_cards c
         JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id
                 LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
                 LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
                 LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
                 LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
         WHERE c.user_id = '{}'
           AND cm.status IN ('active', 'pending')
           AND (c.front LIKE '{}' OR COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') LIKE '{}')
         ORDER BY c.front ASC
         LIMIT {} OFFSET {}",
        query.user_id.replace('\'', "''"),
        like.replace('\'', "''"),
        like.replace('\'', "''"),
        page_size, page_offset,
    );

    let total_sql = format!(
        "SELECT COUNT(*) FROM user_cards c
         JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
                 LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
                 LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
                 LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
                 LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
         WHERE c.user_id = '{}'
           AND cm.status IN ('active', 'pending')
           AND (c.front LIKE '{}' OR COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, '') LIKE '{}')",
        query.user_id.replace('\'', "''"),
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
                "created_at": row.get::<_, String>(8)?,
                "conversation_id": row.get::<_, Option<String>>(9)?,
                "plan_id": row.get::<_, Option<String>>(10)?,
                "task_key": row.get::<_, Option<String>>(11)?,
                "state": row.get::<_, i32>(12)?,
                "reps": row.get::<_, i32>(13)?,
                "lapses": row.get::<_, i32>(14)?,
                "difficulty": row.get::<_, f64>(15)?,
                "due": row.get::<_, i64>(16)?,
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
                (SELECT pr.goal FROM plan_runs pr WHERE pr.conversation_id = c.id LIMIT 1) as plan_goal
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
                .map(|g| g)
                .or_else(|| first_msg.as_deref()
                    .map(|s| if s.chars().count() > 50 { format!("{}...", s.chars().take(50).collect::<String>()) } else { s.to_string() }))
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
        "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let total_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN user_cards c ON r.card_id = c.id WHERE c.user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let domains_covered: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT c.domain) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND c.domain IS NOT NULL AND cm.status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);
    let today_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN user_cards c ON r.card_id = c.id WHERE c.user_id = ?1 AND r.reviewed_at > ?2",
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
    let subscription_expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
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
        "SELECT c.front FROM user_cards c JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         WHERE c.user_id = ?1 AND pc.card_type = 'vocabulary' AND cm.state = 2 AND cm.status = 'active'"
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
        "subscription_expires": subscription_expires,
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
    let category_order = ["seed", "consistency", "knowledge", "exploration", "mastery", "social", "special"];
    let category_labels: std::collections::HashMap<&str, &str> = [
        ("seed", "启程"), ("consistency", "坚持"), ("knowledge", "博学"),
        ("exploration", "探索"), ("mastery", "精进"), ("social", "社交"), ("special", "特殊"),
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
            "share_count" => ctx.share_count as f64,
            "share_days" => ctx.share_days as f64,
            "referral_count" => ctx.referral_count as f64,
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
            "share_count" => "次分享",
            "share_days" => "天",
            "referral_count" => "个注册",
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

// ── Plan Achievements ──

/// 查询 plan 成就（source='plan_achievement'），按 plan_id 分组返回
async fn plan_achievements_handler(
    headers: axum::http::HeaderMap,
    Path(user_id): Path<String>,
) -> impl axum::response::IntoResponse {
    let conn = crate::db_pool::get_conn();
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return (axum::http::StatusCode::UNAUTHORIZED,
            axum::Json(serde_json::json!({"error": "unauthorized"})));
    }

    let mut stmt = match conn.prepare(
        "SELECT id, achievement_key, name, icon, tier, unlocked_at \
         FROM achievements WHERE user_id = ?1 AND source = 'plan_achievement' \
         ORDER BY unlocked_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            axum::Json(serde_json::json!({"error": format!("DB error: {}", e)}))),
    };

    let rows: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![&user_id], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "achievement_key": row.get::<_, String>(1)?,
            "name": row.get::<_, String>(2)?,
            "icon": row.get::<_, String>(3)?,
            "tier": row.get::<_, String>(4)?,
            "unlocked_at": row.get::<_, String>(5)?,
        }))
    }).unwrap()
    .filter_map(|r| r.ok())
    .collect();

    // 按 plan_id 分组 (achievement_key: plan_stage_{plan_id}_{idx} 或 plan_complete_{plan_id})
    let mut plan_map: std::collections::HashMap<String, Vec<serde_json::Value>> = std::collections::HashMap::new();
    let mut plan_name_map: std::collections::HashMap<String, String> = std::collections::HashMap::new();

    for row in &rows {
        let key = row["achievement_key"].as_str().unwrap_or("");
        let name = row["name"].as_str().unwrap_or("");
        let plan_id = if let Some(rest) = key.strip_prefix("plan_stage_") {
            rest.rfind('_').map(|p| &rest[..p])
        } else if let Some(rest) = key.strip_prefix("plan_complete_") {
            Some(rest)
        } else {
            None
        };
        if let Some(pid) = plan_id {
            plan_map.entry(pid.to_string()).or_default().push(row.clone());
            if let Some(dot) = name.find('·') {
                plan_name_map.entry(pid.to_string()).or_insert_with(|| name[..dot].to_string());
            }
        }
    }

    let mut plans: Vec<serde_json::Value> = plan_map.into_iter().map(|(pid, achs)| {
        serde_json::json!({
            "plan_id": pid,
            "plan_name": plan_name_map.get(&pid).unwrap_or(&pid),
            "achievements": achs,
        })
    }).collect();
    plans.sort_by(|a, b| {
        a["plan_name"].as_str().unwrap_or("").cmp(&b["plan_name"].as_str().unwrap_or(""))
    });

    (axum::http::StatusCode::OK, axum::Json(serde_json::json!({"plans": plans})))
}

// ── Display Name ──

async fn update_display_name_handler(
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    tracing::info!("update_display_name_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

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

// ── Subscription check ──

/// GET /api/user/{user_id}/subscription — 轻量订阅状态检查
async fn user_subscription_handler(
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    let conn = crate::db_pool::get_conn();
    let expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
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

    Json(json!({
        "expired": expired,
        "expires_at": expires,
    }))
}

// ── TTS Preview ──

/// POST /api/tts/preview — 试听指定音色
///
/// Body: {"text": "...", "voice_type": 101001, "speed": 0.0}
/// Returns: audio/mpeg 二进制流
async fn tts_preview_handler(
    _headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    use axum::http::StatusCode;

    // 无需鉴权（只是预览）
    let text = payload.get("text").and_then(|v| v.as_str()).unwrap_or("你好，欢迎使用腾讯云语音合成。");
    let voice_type = payload.get("voice_type").and_then(|v| v.as_i64()).map(|v| v as i32);
    let speed = payload.get("speed").and_then(|v| v.as_f64()).map(|v| v as f32);

    match crate::tencent_tts::synthesize(text, voice_type, speed).await {
        Ok(Some(audio)) => {
            axum::response::Response::builder()
                .header(axum::http::header::CONTENT_TYPE, "audio/mpeg")
                .body(axum::body::Body::from(audio))
                .unwrap()
        }
        Ok(None) => {
            axum::response::Response::builder()
                .status(StatusCode::SERVICE_UNAVAILABLE)
                .header(axum::http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(axum::body::Body::from("TTS 未配置，请在 .env 中设置腾讯云密钥"))
                .unwrap()
        }
        Err(e) => {
            axum::response::Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .header(axum::http::header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(axum::body::Body::from(format!("TTS 合成失败: {}", e)))
                .unwrap()
        }
    }
}

/// POST /api/tts/speak — 用用户 TTS 偏好朗读文本
///
/// Body: {"text": "...", "user_id": "..."}
/// 从 user_preferences 读取 tts_voice_type / tts_speed
/// Returns audio/mpeg
async fn tts_speak_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    use axum::http::StatusCode;

    let text = match payload.get("text").and_then(|v| v.as_str()) {
        Some(t) if !t.is_empty() => t,
        _ => {
            return axum::response::Response::builder()
                .status(StatusCode::BAD_REQUEST)
                .body(axum::body::Body::from("text 不能为空"))
                .unwrap();
        }
    };

    let user_id = match payload.get("user_id").and_then(|v| v.as_str()) {
        Some(id) => id,
        _ => {
            return axum::response::Response::builder()
                .status(StatusCode::BAD_REQUEST)
                .body(axum::body::Body::from("user_id 不能为空"))
                .unwrap();
        }
    };

    // 从 user_preferences 读取 TTS 偏好
    let conn = crate::db_pool::get_conn();
    let voice_type: Option<i32> = conn.query_row(
        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'tts_voice_type'",
        rusqlite::params![user_id],
        |row| row.get::<_, String>(0),
    ).ok().and_then(|v| v.parse::<i32>().ok())
    .or(Some(101016)); // 默认智甜-女童声

    let speed: Option<f32> = conn.query_row(
        "SELECT value FROM user_preferences WHERE user_id = ?1 AND key = 'tts_speed'",
        rusqlite::params![user_id],
        |row| row.get::<_, String>(0),
    ).ok().and_then(|v| v.parse::<f32>().ok());

    match crate::tencent_tts::synthesize(text, voice_type, speed).await {
        Ok(Some(audio)) => {
            axum::response::Response::builder()
                .header(axum::http::header::CONTENT_TYPE, "audio/mpeg")
                .body(axum::body::Body::from(audio))
                .unwrap()
        }
        Ok(None) => {
            axum::response::Response::builder()
                .status(StatusCode::SERVICE_UNAVAILABLE)
                .body(axum::body::Body::from("TTS 未配置"))
                .unwrap()
        }
        Err(e) => {
            axum::response::Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(axum::body::Body::from(format!("TTS 合成失败: {}", e)))
                .unwrap()
        }
    }
}

/// POST /api/stt/transcribe — 语音识别（腾讯云 ASR）
///
/// Body: {"audio": "<base64>", "format": "wav", "engine": "16k_zh"}
/// Returns: {"text": "识别结果"}
async fn stt_transcribe_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    use axum::http::StatusCode;

    let audio = match payload.get("audio").and_then(|v| v.as_str()) {
        Some(a) if !a.is_empty() => a,
        _ => {
            tracing::warn!("stt_transcribe: audio field missing or empty");
            return (StatusCode::BAD_REQUEST, "audio 不能为空").into_response();
        }
    };
    let data_len = payload.get("data_len").and_then(|v| v.as_i64()).unwrap_or(0) as usize;
    let engine = payload.get("engine").and_then(|v| v.as_str()).unwrap_or("16k_zh");
    let format = payload.get("format").and_then(|v| v.as_str()).unwrap_or("wav");

    tracing::info!("stt_transcribe: len={} engine={} format={}", data_len, engine, format);

    match crate::tencent_asr::recognize(audio, data_len, engine, format).await {
        Ok(text) => {
            tracing::info!("stt_transcribe OK: result_len={}", text.len());
            (StatusCode::OK, serde_json::json!({"text": text}).to_string()).into_response()
        }
        Err(e) => {
            tracing::error!("stt_transcribe failed: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("ASR 识别失败: {}", e)).into_response()
        }
    }
}

// ── Preferences ──

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
    // 合并 users 表的 subscription_expires（user_preferences 已去除订阅功能）
    let sub_expires: Option<String> = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok().flatten();
    if let Some(exp) = sub_expires {
        prefs.insert("subscription_expires".to_string(), serde_json::Value::String(exp));
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
        if key == "subscription_expires" {
            // 拒绝普通用户自设订阅到期时间，应通过管理员后台或支付流程处理
            continue;
        }
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
    headers: HeaderMap,
    Path(user_id): Path<String>,
    mut multipart: axum::extract::Multipart,
) -> Json<serde_json::Value> {
    tracing::info!("avatar_upload_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

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
    headers: HeaderMap,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    tracing::info!("plans_list_handler ENTER");

    let conn = crate::db_pool::get_conn();

    let (sql, param_val): (&str, String) = if let Some(conv_id) = params.get("conversation_id") {
        ("SELECT id, conversation_id, goal, subject, grade_band, domain, plan_content, created_at, updated_at FROM plan_runs WHERE conversation_id = ?1 ORDER BY created_at DESC", conv_id.clone())
    } else if let Some(uid) = params.get("user_id") {
        if crate::auth_middleware::verify_auth(uid, &headers).is_err() {
            return Json(serde_json::json!({"error": "unauthorized"}));
        }
        ("SELECT id, conversation_id, goal, subject, grade_band, domain, plan_content, created_at, updated_at FROM plan_runs WHERE user_id = ?1 ORDER BY created_at DESC", uid.clone())
    } else {
        return Json(serde_json::json!({"error": "user_id or conversation_id required"}));
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return Json(serde_json::json!({"error": format!("DB: {}", e)})),
    };
    let mut plans: Vec<serde_json::Value> = stmt.query_map(rusqlite::params![param_val], |row| {
        // plan_content: 完整计划结构（不含状态，状态在 user_plan_progress）
        let plan_content_raw: Option<String> = row.get(6).ok();
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
                let stmt = conn.prepare(
                    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
                );
                match stmt {
                    Ok(mut s) => s.query_map(rusqlite::params![plan_id], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                    }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect()).unwrap_or_default(),
                    Err(_) => vec![],
                }
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
            "plan": merged_plan,
            "created_at": row.get::<_, String>(7)?,
            "updated_at": row.get::<_, String>(8)?,
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();

    // 为每个 plan 统计待复习卡片数（due <= now）
    let now_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    if let Ok(mut count_stmt) = conn.prepare(
        "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id = cm.user_card_id LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id WHERE pr.conversation_id = ?1 AND cm.status = 'active' AND cm.due <= ?2"
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

    tracing::info!("plans_list_handler EXIT");
    Json(serde_json::json!({"plans": plans}))
}

// ════════════════════════════════════════════
// Phase 3 — Learning Report
// ════════════════════════════════════════════

async fn learning_report_handler(
    headers: HeaderMap,
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("learning_report_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

    let conn = crate::db_pool::get_conn();

    // 1. 所有学习计划进度
    let mut stmt_plans = conn.prepare(
        "SELECT plan_content, plan_content, goal, grade_band, subject, 'structured' as mode, updated_at FROM plan_runs WHERE user_id = ?1 ORDER BY updated_at DESC"
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
        "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active'", rusqlite::params![user_id], |row| row.get(0)
    ).unwrap_or(0);

    let reviews_total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log WHERE card_id IN (SELECT c.id FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active')",
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
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Query(params): Query<std::collections::HashMap<String, String>>,
) -> Json<serde_json::Value> {
    tracing::info!("activity_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

    let conn = crate::db_pool::get_conn();
    let days: i64 = params.get("days").and_then(|v| v.parse().ok()).unwrap_or(90);

    // 每日复习数
    let mut stmt = conn.prepare(
        "SELECT DATE(r.reviewed_at, 'unixepoch') as d, COUNT(*) as cnt
         FROM review_log r JOIN user_cards c ON r.card_id = c.id
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
         FROM user_cards WHERE user_id = ?1 AND created_at >= ?2
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
    headers: HeaderMap,
    Path(user_id): Path<String>,
) -> Json<serde_json::Value> {
    tracing::info!("weekly_report_handler: user_id={}", user_id);
    if crate::auth_middleware::verify_auth(&user_id, &headers).is_err() {
        return Json(serde_json::json!({"error": "unauthorized"}));
    }

    let conn = crate::db_pool::get_conn();
    let week_ago = (chrono::Utc::now() - chrono::Duration::days(7)).to_rfc3339();
    let week_ago_ts = (chrono::Utc::now() - chrono::Duration::days(7)).timestamp();

    // 本周新增卡片
    let new_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id=cm.user_card_id WHERE c.user_id = ?1 AND c.created_at >= ?2 AND cm.status = 'active'",
        rusqlite::params![user_id, week_ago_ts], |row| row.get(0)
    ).unwrap_or(0);

    // 本周复习次数
    let weekly_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN user_cards c ON r.card_id = c.id WHERE c.user_id = ?1 AND r.reviewed_at >= ?2",
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
        "SELECT goal FROM plan_runs WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 1",
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
        "SELECT pr.id, pr.plan_content FROM plan_runs pr
         JOIN conversations c ON pr.conversation_id = c.id
         WHERE c.user_id = ?1 AND c.deleted_at IS NULL AND pr.subject = ?2 AND pr.grade_band = ?3
         ORDER BY c.started_at DESC LIMIT 1",
        rusqlite::params![input.user_id, input.subject, input.grade_band],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?)),
    ).ok();

    if let Some((plan_id, plan_content_str)) = existing_plan {
        tracing::info!("[K12-INIT] resumed existing plan={}", plan_id);
        let plan_val: serde_json::Value = serde_json::from_str(&plan_content_str).unwrap_or_default();
        let conv_id: String = conn.query_row(
            "SELECT conversation_id FROM plan_runs WHERE id = ?1",
            rusqlite::params![plan_id], |row| row.get(0),
        ).unwrap_or_default();
        return Json(serde_json::json!({
            "conversation_id": conv_id,
            "plan": plan_val,
            "resumed": true,
        }));
    }

    // 从 prebuilt_stages/tasks 规范化表重建 plan JSON
    let prebuilt_plan_id: String = match conn.query_row(
        "SELECT id FROM prebuilt_plans WHERE subject = ?1 LIMIT 1",
        rusqlite::params![input.subject],
        |row| row.get(0),
    ) {
        Ok(id) => id,
        Err(_) => return Json(serde_json::json!({"error": format!("未找到 {} 的学习计划", input.subject)})),
    };
    let plan_goal: String = conn.query_row(
        "SELECT goal FROM prebuilt_plans WHERE id = ?1", rusqlite::params![prebuilt_plan_id],
        |row| row.get(0),
    ).unwrap_or_default();
    let plan_domain: String = conn.query_row(
        "SELECT domain FROM prebuilt_plans WHERE id = ?1", rusqlite::params![prebuilt_plan_id],
        |row| row.get(0),
    ).unwrap_or_default();
    tracing::info!("[K12-INIT] plan loaded: id={}, goal={}, domain={}, subject={}", prebuilt_plan_id, plan_goal, plan_domain, input.subject);
    let grade_band_filter = input.grade_band.as_str();

    // 读 stages（按 grade_band 过滤）
    let mut stages_json: Vec<serde_json::Value> = Vec::new();
    let grade_filter = grade_band_filter.to_string();
    if let Ok(mut stage_stmt) = conn.prepare(
        "SELECT id, name, sort_order FROM prebuilt_stages WHERE plan_id = ?1 AND (grade_band = '' OR grade_band = ?2) ORDER BY sort_order"
    ) {
        if let Ok(stage_rows) = stage_stmt.query_map(rusqlite::params![prebuilt_plan_id, grade_filter], |row| {
            Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,String>(2)?))
        }) {
            for stage_row in stage_rows.flatten() {
                let stage_id = stage_row.0;
                let stage_name = stage_row.1;
                let stage_sort = stage_row.2;

                // 读该 stage 的 tasks
                let mut tasks_json: Vec<serde_json::Value> = Vec::new();
                if let Ok(mut task_stmt) = conn.prepare(
                    "SELECT task_key, name, prompt_mode, card_ids, dependencies, origin, sort_order FROM prebuilt_tasks WHERE stage_id = ?1 ORDER BY sort_order"
                ) {
                    if let Ok(task_rows) = task_stmt.query_map(rusqlite::params![stage_id], |row| {
                        Ok((
                            row.get::<_,String>(0)?,   // task_key
                            row.get::<_,String>(1)?,   // name
                            row.get::<_,String>(2)?,   // prompt_mode
                            row.get::<_,String>(3)?,   // card_ids
                            row.get::<_,String>(4)?,   // dependencies
                            row.get::<_,String>(5)?,   // origin
                            row.get::<_,String>(6)?,   // sort_order
                        ))
                    }) {
                        for t in task_rows.flatten() {
                            let card_ids: serde_json::Value = serde_json::from_str(&t.3).unwrap_or_default();
                            let deps: serde_json::Value = serde_json::from_str(&t.4).unwrap_or_default();
                            tasks_json.push(serde_json::json!({
                                "task_key": t.0,
                                "name": t.1,
                                "prompt_mode": t.2,
                                "card_ids": card_ids,
                                "dependencies": deps,
                                "origin": t.5,
                            }));
                        }
                    }
                }
                stages_json.push(serde_json::json!({
                    "name": stage_name,
                    "sort": stage_sort,
                    "grade_band": grade_band_filter,
                    "tasks": tasks_json,
                }));
            }
        }
    }

    let plan_val = serde_json::json!({
        "goal": plan_goal,
        "domain": plan_domain,
        "stages": stages_json,
    });
    let filtered_content_str = serde_json::to_string(&plan_val).unwrap_or_default();
    tracing::info!("[K12-INIT] plan reconstructed: {} stages, {} total tasks",
        stages_json.len(),
        stages_json.iter().map(|s| s["tasks"].as_array().map(|a| a.len()).unwrap_or(0)).sum::<usize>()
    );

    let conv_id = uuid::Uuid::new_v4().to_string();
    let plan_id = uuid::Uuid::new_v4().to_string();

    // 先创建 conversations 记录（满足 FK 约束：conversation_plans.conversation_id → conversations.id）
    let _ = conn.execute(
        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conv_id, input.user_id, now_ts.to_string()],
    );

    // 写入 K12 plan（含 domain）
    match conn.execute(
        "INSERT INTO plan_runs (id, user_id, conversation_id, goal, subject, grade_band, domain, plan_content, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        rusqlite::params![plan_id, input.user_id, conv_id, plan_goal, input.subject, input.grade_band, plan_domain, filtered_content_str, now_ts, now_ts],
    ) {
        Ok(_) => tracing::info!("[K12-INIT] plan inserted: id={}, subject={}, grade_band={}", plan_id, input.subject, input.grade_band),
        Err(e) => {
            tracing::error!("[K12-INIT] plan INSERT FAILED: {} — subject={}, grade={}", e, input.subject, input.grade_band);
            return Json(serde_json::json!({"error": format!("创建计划失败: {}", e)}));
        }
    }

    // 预置词库科目（english/chinese）：只激活第一个 task 的卡片，逐课渐进激活
    let is_vocab_subject = input.subject == "english" || input.subject == "chinese";
    let mut activated = 0u32;
    if is_vocab_subject {
        // 只激活第一个 task 的卡片
        if let Some(stages) = plan_val.get("stages").and_then(|s| s.as_array()) {
            if let Some(first_stage) = stages.first() {
                if let Some(tasks) = first_stage.get("tasks").and_then(|t| t.as_array()) {
                    if let Some(first_task) = tasks.first() {
                        let task_key = first_task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
                        for cid in first_task.get("card_ids").and_then(|c| c.as_array()).into_iter().flatten() {
                            if let Some(card_uuid) = cid.as_str() {
                                crate::plan_handler::copy_prebuilt_card(&conn, &input.user_id, &plan_id, task_key, card_uuid);
                                activated += 1;
                            }
                        }
                    }
                }
            }
        }
        tracing::info!("[K12-INIT] activated {} cards in first task for vocab subject={}", activated, input.subject);
    } else {
        // 非词库科目：批量激活第一个 stage 所有 task 的卡片
        let _ = conn.execute("BEGIN", []);
        if let Some(stages) = plan_val.get("stages").and_then(|s| s.as_array()) {
            if let Some(first_stage) = stages.first() {
                if let Some(tasks) = first_stage.get("tasks").and_then(|t| t.as_array()) {
                    for task in tasks {
                        let task_key = task.get("task_key").and_then(|v| v.as_str()).unwrap_or("");
                        for cid in task.get("card_ids").and_then(|c| c.as_array()).into_iter().flatten() {
                            if let Some(card_uuid) = cid.as_str() {
                                crate::plan_handler::copy_prebuilt_card(&conn, &input.user_id, &plan_id, task_key, card_uuid);
                                activated += 1;
                            }
                        }
                    }
                }
            }
        }
        let _ = conn.execute("COMMIT", []);
        tracing::info!("[K12-INIT] activated {} cards in first stage", activated);
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

    Json(serde_json::json!({
        "conversation_id": conv_id,
        "plan": plan_val,
    }))
}

/// GET /api/k12/subjects — 返回所有可见的预置计划列表
async fn k12_subjects_handler() -> Result<Json<serde_json::Value>, AppError> {
    let conn = crate::db_pool::get_conn();

    let mut stmt = conn.prepare(
        "SELECT subject, COALESCE(display_name, ''), COALESCE(title, ''), COALESCE(goal, ''), COALESCE(author, ''), COALESCE(theme_color, ''), COALESCE(theme_icon, '') \
         FROM prebuilt_plans WHERE visible = 1 ORDER BY subject"
    ).map_err(|e| AppError::Internal(format!("prepare: {}", e)))?;

    let subjects: Vec<serde_json::Value> = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
        ))
    }).map_err(|e| AppError::Internal(format!("query: {}", e)))?
    .filter_map(|r| r.ok())
    .map(|(subject, display_name, title, goal, author, theme_color, theme_icon)| {
        serde_json::json!({
            "subject": subject,
            "display_name": if display_name.is_empty() { &subject } else { &display_name },
            "title": title,
            "goal": goal,
            "author": author,
            "theme_color": theme_color,
            "theme_icon": theme_icon,
        })
    }).collect();

    tracing::info!("k12_subjects_handler: returned {} subjects", subjects.len());
    Ok(Json(serde_json::json!({ "subjects": subjects })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::init_database;

    #[tokio::test]
    async fn test_k12_subjects_endpoint() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        // Insert a test plan with new fields
        let plan_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO prebuilt_plans (id, subject, domain, grade_band, goal, title, author, display_name, visible, theme_color, theme_icon) \
             VALUES (?1, 'english', 'language', 'g1-12', 'English Goal', 'English Title', 'Author Name', 'English', 1, '#81C784', 'language')",
            rusqlite::params![plan_id],
        ).unwrap();

        // Insert an invisible plan (should not appear)
        let hidden_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO prebuilt_plans (id, subject, domain, goal, visible) \
             VALUES (?1, 'japanese', 'language', 'Japanese Goal', 0)",
            rusqlite::params![hidden_id],
        ).unwrap();

        // Insert a plan with empty display_name (should fallback to subject)
        let fallback_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO prebuilt_plans (id, subject, domain, goal, visible) \
             VALUES (?1, 'physics', 'science', 'Physics Goal', 1)",
            rusqlite::params![fallback_id],
        ).unwrap();

        // Simulate the handler logic
        let mut stmt = conn.prepare(
            "SELECT subject, COALESCE(display_name, ''), COALESCE(title, ''), COALESCE(goal, ''), COALESCE(author, ''), COALESCE(theme_color, ''), COALESCE(theme_icon, '') \
             FROM prebuilt_plans WHERE visible = 1 ORDER BY subject"
        ).unwrap();

        let subjects: Vec<serde_json::Value> = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
            ))
        }).unwrap()
        .filter_map(|r| r.ok())
        .map(|(subject, display_name, title, goal, author, theme_color, theme_icon)| {
            serde_json::json!({
                "subject": subject,
                "display_name": if display_name.is_empty() { &subject } else { &display_name },
                "title": title,
                "goal": goal,
                "author": author,
                "theme_color": theme_color,
                "theme_icon": theme_icon,
            })
        }).collect();

        // Verify results
        assert_eq!(subjects.len(), 2, "should return 2 visible subjects, got {}", subjects.len());

        // English should have all fields
        let eng = &subjects[0];
        assert_eq!(eng["subject"], "english");
        assert_eq!(eng["display_name"], "English");
        assert_eq!(eng["title"], "English Title");
        assert_eq!(eng["author"], "Author Name");
        assert_eq!(eng["theme_color"], "#81C784");
        assert_eq!(eng["theme_icon"], "language");

        // Physics should fallback display_name to subject
        let phys = &subjects[1];
        assert_eq!(phys["subject"], "physics");
        assert_eq!(phys["display_name"], "physics", "empty display_name should fallback to subject");
        assert!(phys["title"].as_str().unwrap_or("").is_empty());
        assert!(phys["author"].as_str().unwrap_or("").is_empty());

        // Japanese should NOT appear (visible=0)
        assert!(!subjects.iter().any(|s| s["subject"] == "japanese"), "invisible subject should not appear");
    }
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
        "SELECT plan_content FROM plan_runs WHERE conversation_id = ?1",
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
        "SELECT id FROM plan_runs WHERE conversation_id = ?1",
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
            "SELECT c.id, pc.card_type, c.front,
                    COALESCE(psc.definition, plt.full_text, phc.body, c.front, plc.pronunciation, '') as back,
                    plt.translation,
                    plc.definitions
             FROM user_cards c
             LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
             LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
             LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
             LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
             LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
             WHERE c.prebuilt_card_id = ?1 AND c.user_id = ?2",
            rusqlite::params![uuid, query.user_id],
            |row| {
                let id: String = row.get(0)?;
                let card_type: String = row.get(1)?;
                let front: String = row.get(2)?;
                let back: String = row.get(3)?;
                let translation: Option<String> = row.get(4)?;
                let definitions: Option<String> = row.get(5)?;
                // 尝试解析 back 为 JSON（poem/song 卡片）
                let back_val: serde_json::Value = if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&back) {
                    parsed
                } else {
                    serde_json::Value::String(back.clone())
                };
                let mut resp = serde_json::json!({
                    "id": id,
                    "card_type": card_type,
                    "front": front,
                    "back": back_val,
                });
                // 平铺 back 中的字段到顶层（poem/song 卡片）
                if let Some(obj) = back_val.as_object() {
                    for key in &["full_text", "author", "famous_lines", "imagery", "technique", "theme", "common_mistakes", "dynasty", "level", "tags"] {
                        if let Some(val) = obj.get(*key) {
                            resp[*key] = val.clone();
                        }
                    }
                }
                // 纯文本 back：设为 full_text（文学=全文，语言=英文原文，科学=定义）
                if back_val.is_string() {
                    resp["full_text"] = serde_json::Value::String(back);
                }
                // 译文
                let trans_val = translation.filter(|t| !t.is_empty()).or_else(|| {
                    // 语言卡片：从 definitions JSON 数组中提取第一条
                    definitions.as_ref().and_then(|d| {
                        serde_json::from_str::<Vec<serde_json::Value>>(d).ok()
                            .and_then(|arr| arr.first().and_then(|v| v.as_str().map(|s| s.to_string())))
                    })
                });
                if let Some(t) = trans_val {
                    resp["translation"] = serde_json::Value::String(t);
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
        "SELECT pr.id, pr.plan_content, pr.goal, pr.grade_band, pr.created_at
         FROM plan_runs pr
         WHERE pr.user_id = ?1
         ORDER BY pr.created_at DESC"
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
            "SELECT COUNT(*) FROM user_cards WHERE plan_run_id = ?1",
            rusqlite::params![plan_id],
            |row| row.get(0),
        ).unwrap_or(0);

        let mastered_cards: i64 = conn.query_row(
            "SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id = cm.user_card_id WHERE c.plan_run_id = ?1 AND cm.state = 2 AND cm.reps >= 3",
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
