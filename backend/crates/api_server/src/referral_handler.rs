//! 推广码/点击追踪/用户端数据 API — 真实业务逻辑
//!
//! 包括：点击追踪、推广码查看、分享统计、团队树、佣金列表、海报/H5 生成、用户画像
//! 海报/H5 使用 LLM 管线 (chat_engine::llm_caller) 生成个性化推广内容。

use std::collections::HashMap;
use axum::{Json, http::HeaderMap, extract::{Query, Path}};
use axum::response::IntoResponse;
use serde::Deserialize;
use serde_json::json;
use base64::Engine;
use crate::h5_template::fallback_h5_html;
use crate::distribution_handler::net_available_commission;
// StatusCode 通过 axum::http::StatusCode 全路径使用

// ── 请求/响应结构 ──

#[derive(Deserialize)]
pub struct ClickRequest {
    pub campaign_id: String,
    pub referrer_code: String,
    pub clicker_anonymous_id: Option<String>,
    pub share_channel: Option<String>,
    pub landed_page: Option<String>,
}

#[derive(Deserialize)]
pub struct UserQuery {
    pub user_id: String,
}

#[derive(Deserialize)]
pub struct UserBody {
    pub user_id: String,
    pub campaign_id: Option<String>,
}

// ── 辅助函数 ──

/// 加载分享类 prompt 文件（signal + format 合并）
fn load_share_prompt(base_dir: &str, prompt_type: &str, sub_type: &str) -> Result<String, String> {
    let path = format!("{}/share/{}/{}.md", base_dir, sub_type, prompt_type);
    std::fs::read_to_string(&path).map_err(|e| format!("读取 {} 失败: {}", path, e))
}

/// 加载主 prompt（仅主模板，不含 signal/format）
/// 路径: {base_dir}/share/{prompt_type}.md
pub(crate) fn load_main_prompt(base_dir: &str, prompt_type: &str) -> Result<String, String> {
    let main_path = format!("{}/share/{}.md", base_dir, prompt_type);
    std::fs::read_to_string(&main_path).map_err(|e| format!("读取 {} 失败: {}", main_path, e))
}

/// 加载三部分 prompt：主模板 + signal + format，按序合并
/// 路径:
///   - 主: {base_dir}/share/{prompt_type}.md
///   - signal: {base_dir}/share/signal/{prompt_type}.md
///   - format: {base_dir}/share/format/{prompt_type}.md
pub(crate) fn load_combined_prompt(base_dir: &str, prompt_type: &str) -> Result<String, String> {
    let main_path = format!("{}/share/{}.md", base_dir, prompt_type);
    let signal_path = format!("{}/share/signal/{}.md", base_dir, prompt_type);
    let format_path = format!("{}/share/format/{}.md", base_dir, prompt_type);

    let main = std::fs::read_to_string(&main_path).unwrap_or_default();
    let signal = std::fs::read_to_string(&signal_path).unwrap_or_default();
    let format = std::fs::read_to_string(&format_path).unwrap_or_default();

    let mut parts: Vec<&str> = Vec::new();
    if !main.is_empty() { parts.push(&main); }
    if !signal.is_empty() { parts.push(&signal); }
    if !format.is_empty() { parts.push(&format); }

    if parts.is_empty() {
        return Err(format!("未找到 prompt: share/{}.md", prompt_type));
    }
    Ok(parts.join("\n\n"))
}

/// 加载海报系统提示（主prompt）
///
/// 如果提供了 campaign_id 且该活动有自定义 prompt，则使用自定义的
/// 否则使用默认的 share/poster.md 文件
/// 自定义 prompt 会自动合并 signal + format 部分
fn load_poster_prompt(base_dir: &str, campaign_id: Option<&str>, conn: Option<&rusqlite::Connection>) -> Result<String, String> {
    if let (Some(cid), Some(c)) = (campaign_id, conn) {
        let custom: String = c.query_row(
            "SELECT poster_prompt FROM marketing_campaigns WHERE id = ?1 AND poster_prompt IS NOT NULL AND poster_prompt != ''",
            rusqlite::params![cid],
            |row| row.get(0),
        ).unwrap_or_default();
        if !custom.is_empty() {
            let signal = match load_share_prompt(base_dir, "poster", "signal") {
                Ok(s) => s,
                Err(_) => String::new(),
            };
            let format = match load_share_prompt(base_dir, "poster", "format") {
                Ok(f) => f,
                Err(_) => String::new(),
            };
            let mut parts = vec![custom];
            if !signal.is_empty() { parts.push(signal); }
            if !format.is_empty() { parts.push(format); }
            return Ok(parts.join("\n\n"));
        }
    }
    // 无自定义 prompt，使用默认文件
    load_combined_prompt(base_dir, "poster")
}

/// 获取用户学习画像数据（JSON 字符串）
///
/// 按设计文档 §9 返回完整的用户画像，包含：
/// - learning_today / learning_yesterday：今日/昨日复习对比
/// - current_plan：当前活跃学习计划
/// - recent_completed_tasks：最近完成的任务
/// - vocabulary：词汇学习数据
/// - achievements：已解锁成就
/// - referral_code：推广码
/// 生成用户画像数据（供 LLM 生成分享海报文案）
///
/// 🔴 2026-09-29 已退役：原实现从 `user_cards` / `card_memory` / `review_log` /
///     `plan_runs` / `user_plan_progress` / `achievements` 读取学习战绩。
///     学习状态已整体迁到端侧（`user.db`）→ 后端不再持有这些数据；成就方向定为「端侧计算」。
///     → 战绩类字段一律返回 0 / 空。⚠️ 战绩展示 UI 已同步移除（待「成就体系重新规划」重做）。
/// 仅保留 `users` 表内可得的字段（`streak_days` / `referral_code`）。
fn get_user_portrait_data(conn: &rusqlite::Connection, user_id: &str) -> Result<String, String> {
    let streak_days: i64 = conn.query_row(
        "SELECT COALESCE(streak_days, 0) FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let referral_code: String = conn.query_row(
        "SELECT referral_code FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or_default();

    let result = json!({
        "learning_today": {
            "streak_days": streak_days,
            "new_cards": 0,
            "total_cards": 0,
            "total_reviews": 0,
            "overall_mastery": 0,
            "review_accuracy": 0,
        },
        "learning_yesterday": {
            "streak_days": (streak_days - 1).max(0),
            "new_cards": 0,
            "total_cards": 0,
            "total_reviews": 0,
            "overall_mastery": 0,
            "review_accuracy": 0,
        },
        "vocabulary": {
            "total_words": 0,
            "new_today": 0,
            "mastered_today": 0,
            "mastered_yesterday": 0,
        },
        "achievements": [],
        "referral_code": referral_code,
    });

    Ok(result.to_string())
}

/// 降级海报 SVG（LLM 调用失败时使用）
fn fallback_poster_svg(referral_code: &str) -> String {
    let base = crate::share_data::public_base_url();
    let qr_content = format!("{}/home?ref={}&camp=poster", base, referral_code);
    let qr_svg = generate_qr_svg(&qr_content, "#1A237E", "#FFFFFF");
    format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="600" viewBox="0 0 400 600">
  <rect width="400" height="600" fill="#4F46E5" rx="20"/>
  <text x="200" y="80" text-anchor="middle" fill="white" font-size="28" font-weight="bold">CoEvo 学习推广</text>
  <text x="200" y="130" text-anchor="middle" fill="white" font-size="16">一起学习，共同成长</text>
  <rect x="100" y="220" width="200" height="200" rx="10" fill="white"/>
  <text x="200" y="320" text-anchor="middle" fill="#4F46E5" font-size="14">推广码</text>
  <text x="200" y="350" text-anchor="middle" fill="#4F46E5" font-size="24" font-weight="bold">{}</text>
  {}
  <text x="200" y="500" text-anchor="middle" fill="white" font-size="12">扫码或输入推广码注册</text>
  <text x="200" y="530" text-anchor="middle" fill="white" font-size="12">即可获得专属学习福利</text>
</svg>"##,
        referral_code, qr_svg
    )
}

// ── QR 码生成 ──

/// 生成二维码 SVG
pub(crate) fn generate_qr_svg(content: &str, fg_color: &str, bg_color: &str) -> String {
    use qrcode::{QrCode, EcLevel};
    use qrcode::render::svg;

    let code = QrCode::with_error_correction_level(content, EcLevel::M).unwrap();
    code.render()
        .min_dimensions(180, 180)
        .dark_color(svg::Color(fg_color))
        .light_color(svg::Color(bg_color))
        .build()
}

/// 将 SVG 字符串转换为 PNG 字节数组
pub(crate) fn svg_to_png(svg: &str) -> Result<Vec<u8>, String> {
    // 替换中文/系统字体名称为通用 sans-serif（resvg 可能不含中文字体）
    let cleaned = svg
        .replace("font-family=\"'PingFang SC', 'Microsoft YaHei', sans-serif\"", "font-family=\"sans-serif\"")
        .replace("font-family=\"system-ui, -apple-system, sans-serif\"", "font-family=\"sans-serif\"")
        .replace("font-family=\"'PingFang SC', 'Helvetica Neue', 'Microsoft YaHei', system-ui, sans-serif\"", "font-family=\"sans-serif\"");
    let mut opts = resvg::usvg::Options::default();
    opts.fontdb_mut().load_system_fonts();
    let tree = resvg::usvg::Tree::from_data(cleaned.as_bytes(), &opts)
        .map_err(|e| {
            let preview: String = cleaned.chars().take(500).collect();
            tracing::warn!("SVG→PNG failed, first 500 chars of SVG:\n---\n{}\n---", preview);
            format!("SVG parse error: {}", e)
        })?;

    let size = tree.size();
    let width = size.width() as u32;
    let height = size.height() as u32;

    let mut pixmap = resvg::tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| format!("Failed to create {}x{} pixmap", width, height))?;

    resvg::render(&tree, resvg::tiny_skia::Transform::default(), &mut pixmap.as_mut());

    pixmap
        .encode_png()
        .map_err(|e| format!("PNG encode error: {}", e))
}

/// 从已替换变量的 SVG 文本中提取显示名称（用于 PNG fallback）
/// 尝试从 SVG 中提取推广码，失败时使用空串
fn extract_user_for_png_fallback(svg: &str) -> crate::poster_template::UserPosterData {
    let base = crate::share_data::coevo_base_url();
    // 尝试从 SVG 中提取推广码（<text ...>推广码: XXXX</text> 或 {referral_code} 被替换后的值）
    let referral_code = svg.lines()
        .find_map(|line| {
            let trimmed = line.trim();
            if let Some(start) = trimmed.find("推广码: ") {
                let after = &trimmed[start + 5..];  // skip "推广码: "
                let code = after.trim_end_matches(|c: char| c == '<' || c == '/' || c == ' ' || c == '>');
                Some(code.to_string())
            } else {
                None
            }
        })
        .filter(|c| !c.is_empty())
        .unwrap_or_default();
    crate::poster_template::UserPosterData {
        display_name: "用户".to_string(),
        real_name: String::new(),
        streak_days: 7,
        total_cards: 20,
        today_reviews: 3,
        referral_code: referral_code.clone(),
        qr_code_url: format!("{}/home?ref={}", base, referral_code),
        avatar_url: String::new(),
        active_plans_summary: String::new(),
        current_focus: String::new(),
        plan_count: 0,
        completed_plans: 0,
        achievement_count: 0,
    }
}

/// 生成包含 SVG 和 PNG 的 JSON 响应（PNG 转换失败时降级为纯 SVG）
/// 内部：SVG → JSON(PNG) 响应（公开供 admin preview 等场景用）
pub fn poster_json_response_inline(svg: &str, copy: &str) -> axum::http::Response<axum::body::Body> {
    poster_json_response(svg, copy, None)
}

fn poster_json_response(svg: &str, copy: &str, poster_data: Option<&crate::poster_template::UserPosterData>) -> axum::http::Response<axum::body::Body> {
    let png_data_url = match svg_to_png(svg) {
        Ok(png_bytes) => {
            let png_base64 =
                base64::engine::general_purpose::STANDARD.encode(&png_bytes);
            Some(format!("data:image/png;base64,{}", png_base64))
        }
        Err(_e) => {
            // PNG 失败时用 fallback SVG 重新尝试（确保 PNG 总有产出）
            let fallback_svg = if let Some(data) = poster_data {
                // 使用真实用户数据生成 fallback，并确保 QR 占位符被替换
                let fallback = crate::poster_template::fallback_poster_svg(data);
                crate::poster_template::replace_template_variables(&fallback, data)
            } else {
                // 无用户数据时最简降级
                let data = extract_user_for_png_fallback(svg);
                let fallback = crate::poster_template::fallback_poster_svg(&data);
                crate::poster_template::replace_template_variables(&fallback, &data)
            };
            match svg_to_png(&fallback_svg) {
                Ok(png_bytes) => {
                    let png_base64 =
                        base64::engine::general_purpose::STANDARD.encode(&png_bytes);
                    Some(format!("data:image/png;base64,{}", png_base64))
                }
                Err(e2) => {
                    tracing::warn!("SVG→PNG fallback also failed: {}, returning SVG only", e2);
                    None
                }
            }
        }
    };

    Json(json!({
        "svg": svg,
        "poster_png": png_data_url,
        "copy": copy,
    }))
    .into_response()
}

/// GET /api/referral/qrcode — 获取用户推广二维码（SVG 格式）
pub async fn get_qrcode(
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let user_id = match params.get("user_id") {
        Some(uid) if !uid.is_empty() => uid,
        _ => return (axum::http::StatusCode::BAD_REQUEST, "Missing user_id".to_string()).into_response(),
    };

    if let Err(e) = crate::auth_middleware::verify_auth(user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let referral_code: String = match conn.query_row(
        "SELECT referral_code FROM users WHERE id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ) {
        Ok(code) => code,
        Err(_) => return (axum::http::StatusCode::NOT_FOUND, "User not found".to_string()).into_response(),
    };

    // 构建二维码内容
    let campaign_id = params.get("camp").map(|s| s.as_str()).unwrap_or("share");
    let base = crate::share_data::public_base_url();
    let qr_content = format!(
        "{}/home?ref={}&camp={}",
        base, referral_code, campaign_id
    );

    let qr_svg = generate_qr_svg(&qr_content, "#1A237E", "#FFFFFF");

    ([(axum::http::header::CONTENT_TYPE, "image/svg+xml")], qr_svg).into_response()
}

// ── Handler 实现 ──

/// POST /api/referral/click — 点击追踪（公开接口，无需认证）
pub async fn click(
    Json(payload): Json<ClickRequest>,
) -> impl IntoResponse {
    tracing::info!("referral_click: campaign={}, code={}", payload.campaign_id, payload.referrer_code);

    // 用 referrer_code 查对应的用户
    let conn = crate::db_pool::get_conn();
    let referrer_id: Option<String> = conn.query_row(
        "SELECT id FROM users WHERE referral_code = ?1 AND deleted_at IS NULL",
        rusqlite::params![payload.referrer_code],
        |row| row.get(0),
    ).ok();

    let referrer_id = match referrer_id {
        Some(id) => id,
        None => return (axum::http::StatusCode::NOT_FOUND, Json(json!({"error": "referrer_not_found"}))).into_response(),
    };

    // 自链接防护：如果有 clicker_anonymous_id 且该匿名用户就是推广员自己，记录但不阻止
    let click_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    match conn.execute(
        "INSERT INTO referral_clicks (id, campaign_id, referrer_id, clicker_anonymous_id, share_channel, landed_page, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![click_id, payload.campaign_id, referrer_id, payload.clicker_anonymous_id, payload.share_channel, payload.landed_page, now],
    ) {
        Ok(_) => Json(json!({"id": click_id})).into_response(),
        Err(e) => (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("db_error: {}", e)}))).into_response(),
    }
}

/// GET /api/referral/my-code — 查看推广码
pub async fn my_code(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("my_code: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    match conn.query_row(
        "SELECT referral_code, created_at FROM users WHERE id = ?1",
        rusqlite::params![query.user_id],
        |row| {
            let code: String = row.get(0)?;
            let created: String = row.get(1)?;
            Ok((code, created))
        },
    ) {
        Ok((code, created_at)) => Json(json!({"referral_code": code, "created_at": created_at})).into_response(),
        Err(_) => (axum::http::StatusCode::NOT_FOUND, Json(json!({"error": "user_not_found"}))).into_response(),
    }
}

/// GET /api/referral/my-stats — 分享统计
pub async fn my_stats(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("my_stats: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let total_clicks: i64 = conn.query_row(
        "SELECT COUNT(*) FROM referral_clicks WHERE referrer_id = ?1",
        rusqlite::params![query.user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_registrations: i64 = conn.query_row(
        "SELECT COUNT(*) FROM users WHERE referred_by = ?1 AND deleted_at IS NULL",
        rusqlite::params![query.user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_earned: i64 = {
        // 净收益 = 所有佣金 - 所有支出
        let comm_total: i64 = conn.query_row(
            "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE earner_id = ?1 AND status NOT IN ('cancelled')",
            rusqlite::params![query.user_id], |row| row.get(0),
        ).unwrap_or(0);
        let expenses: i64 = conn.query_row(
            "SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses WHERE earner_id = ?1 AND status = 'confirmed'",
            rusqlite::params![query.user_id], |row| row.get(0),
        ).unwrap_or(0);
        comm_total - expenses
    };

    let available_commission: i64 = net_available_commission(&conn, &query.user_id);

    Json(json!({
        "total_clicks": total_clicks,
        "total_registrations": total_registrations,
        "total_earned": total_earned,
        "available_commission": available_commission,
    })).into_response()
}

/// GET /api/referral/my-team — 团队树（递归 CTE，最多 2 级）
pub async fn my_team(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("my_team: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();

    // 递归 CTE 查 2 级下线
    let sql = r#"
        WITH RECURSIVE team AS (
            SELECT id, display_name, referred_by, 1 AS level
            FROM users WHERE referred_by = ?1 AND deleted_at IS NULL
            UNION ALL
            SELECT u.id, u.display_name, u.referred_by, t.level + 1
            FROM users u
            JOIN team t ON u.referred_by = t.id
            WHERE t.level < 2 AND u.deleted_at IS NULL
        )
        SELECT u.id, COALESCE(u.display_name, u.username), u.referred_by, t.level FROM team t
        JOIN users u ON u.id = t.id
        ORDER BY t.level, u.id
    "#;

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("db_error: {}", e)}))).into_response(),
    };

    let members: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![query.user_id], |row| {
        let member_id: String = row.get(0)?;
        let display_name: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
        let referred_by: String = row.get::<_, Option<String>>(2)?.unwrap_or_default();
        let level: i32 = row.get(3)?;
        Ok((member_id, display_name, referred_by, level))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).map(|(member_id, display_name, referred_by, level)| {
            let referral_count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM users WHERE referred_by = ?1 AND deleted_at IS NULL",
                rusqlite::params![&member_id], |row| row.get(0),
            ).unwrap_or(0);
            json!({
                "id": member_id,
                "display_name": display_name,
                "referred_by": referred_by,
                "level": level,
                "referral_count": referral_count,
            })
        }).collect(),
        Err(_) => vec![],
    };

    Json(json!({"team": members})).into_response()
}

/// GET /api/referral/my-commissions — 佣金列表
pub async fn my_commissions(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("my_commissions: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let sql = r#"
        SELECT dc.id, dc.campaign_id, dc.buyer_id, dc.order_id, dc.order_amount,
               dc.rate_applied, dc.amount, dc.level, dc.status, dc.created_at,
               po.plan_id, po.paid_at
        FROM distribution_commissions dc
        JOIN payment_orders po ON po.id = dc.order_id
        WHERE dc.earner_id = ?1
        ORDER BY dc.created_at DESC
        LIMIT 50
    "#;

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("db_error: {}", e)}))).into_response(),
    };

    let items: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![query.user_id], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "campaign_id": row.get::<_, String>(1)?,
            "buyer_id": row.get::<_, String>(2)?,
            "order_id": row.get::<_, String>(3)?,
            "order_amount": row.get::<_, i64>(4)?,
            "rate_applied": row.get::<_, f64>(5)?,
            "amount": row.get::<_, i64>(6)?,
            "level": row.get::<_, i32>(7)?,
            "status": row.get::<_, String>(8)?,
            "created_at": row.get::<_, String>(9)?,
            "plan_id": row.get::<_, String>(10)?,
            "paid_at": row.get::<_, Option<String>>(11)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(_) => vec![],
    };

    Json(json!({"commissions": items})).into_response()
}

/// 内部海报生成（供 admin preview_poster 等场景调用，跳过 auth）
pub async fn generate_poster_internal(
    conn: &rusqlite::Connection,
    user_id: &str,
    campaign_id: &str,
) -> axum::http::Response<axum::body::Body> {
    let template: Option<String> = if !campaign_id.is_empty() {
        conn.query_row(
            "SELECT poster_template FROM marketing_campaigns WHERE id = ?1",
            rusqlite::params![campaign_id],
            |row| row.get(0),
        ).ok().flatten()
    } else {
        None
    };

    let (svg, copy, poster_data) = if let Some(ref tpl) = template {
        let data = match crate::poster_template::build_user_poster_data(conn, user_id, campaign_id) {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("build_user_poster_data failed: {}", e);
                return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response();
            }
        };
        let svg = crate::poster_template::replace_template_variables(tpl, &data);
        (svg, crate::poster_template::fallback_copy(), Some(data))
    } else {
        let data = match crate::poster_template::build_user_poster_data(conn, user_id, "") {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("build_user_poster_data failed: {}", e);
                return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response();
            }
        };
        let svg = crate::poster_template::replace_template_variables(
            &crate::poster_template::fallback_poster_svg(&data),
            &data,
        );
        (svg, crate::poster_template::fallback_copy(), Some(data))
    };
    poster_json_response(&svg, &copy, poster_data.as_ref())
}

/// POST /api/referral/generate-poster — 海报生成（模板替换流程）
///
/// 流程：
///   1. 查 marketing_campaigns.poster_template
///   2. 如有模板 → build_user_poster_data() + replace_template_variables()
///   3. 如无模板 → fallback 静态海报
///   零 LLM 调用，快速响应。
pub async fn generate_poster(
    headers: HeaderMap,
    Json(body): Json<UserBody>,
) -> impl IntoResponse {
    tracing::info!("generate_poster: user_id={}", body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();

    // 如果传了 campaign_id 但活动不存在（已删除），返回已结束标记
    if let Some(ref cid) = body.campaign_id {
        let exists: bool = conn.query_row(
            "SELECT 1 FROM marketing_campaigns WHERE id = ?1",
            rusqlite::params![cid],
            |_| Ok(true),
        ).unwrap_or(false);
        if !exists {
            return (axum::http::StatusCode::OK, Json(json!({"status": "campaign_ended"}))).into_response();
        }
    }

    // 查活动是否有海报模板
    let template: Option<String> = if let Some(ref cid) = body.campaign_id {
        conn.query_row(
            "SELECT poster_template FROM marketing_campaigns WHERE id = ?1",
            rusqlite::params![cid],
            |row| row.get(0),
        ).ok().flatten()
    } else {
        None
    };

    let (svg, copy, poster_data) = if let Some(tpl) = template {
        // 使用模板替换流程（零 LLM）
        let campaign_id = body.campaign_id.as_deref().unwrap_or("");
        let data = match crate::poster_template::build_user_poster_data(&conn, &body.user_id, campaign_id) {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("build_user_poster_data failed: {}", e);
                return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response();
            }
        };
        let svg = crate::poster_template::replace_template_variables(&tpl, &data);
        let copy = crate::poster_template::fallback_copy();
        (svg, copy, Some(data))
    } else {
        // Fallback: 模板未生成，用静态海报（同样走变量替换确保二维码注入）
        let data = match crate::poster_template::build_user_poster_data(&conn, &body.user_id, "") {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("build_user_poster_data failed: {}", e);
                return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": format!("build_user_data_failed: {}", e)}))).into_response();
            }
        };
        let svg = crate::poster_template::replace_template_variables(
            &crate::poster_template::fallback_poster_svg(&data),
            &data,
        );
        let copy = crate::poster_template::fallback_copy();
        (svg, copy, Some(data))
    };

    // 保持后续 SVG→PNG 转换逻辑不变
    poster_json_response(&svg, &copy, poster_data.as_ref())
}

/// POST /api/referral/generate-h5 — H5 分享页生成（模板替换流程，零 LLM）
///
/// 使用活动 h5_template（如果存在）做模板替换，否则返回 fallback。
/// 返回 JSON 包含 HTML 文本，前端在 WebView 中渲染。
/// 不再调用 LLM，不再写入磁盘。
pub async fn generate_h5(
    headers: HeaderMap,
    Json(body): Json<UserBody>,
) -> impl IntoResponse {
    tracing::info!("generate_h5: user_id={}", body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let referral_code: String = conn.query_row(
        "SELECT referral_code FROM users WHERE id = ?1",
        rusqlite::params![body.user_id], |row| row.get(0),
    ).unwrap_or_else(|_| "UNKNOWN".to_string());

    let avatar_url = format!("{}/api/user/{}/avatar", crate::share_data::coevo_base_url(), body.user_id);

    // 查活动 H5 模板（如果有 campaign_id）
    let html = if let Some(ref cid) = body.campaign_id {
        match conn.query_row(
            "SELECT h5_template FROM marketing_campaigns WHERE id = ?1",
            rusqlite::params![cid], |row| row.get::<_, Option<String>>(0),
        ).ok().flatten() {
            Some(template) => {
                tracing::info!("generate_h5: using custom template for campaign={}, template_len={}", cid, template.len());
                // 使用模板替换流程（零 LLM）
                match crate::h5_template::build_user_h5_data(&conn, &body.user_id, cid) {
                    Ok(data) => crate::h5_template::replace_h5_variables(&template, &data),
                    Err(e) => {
                        tracing::warn!("generate_h5: build_user_h5_data failed: {}", e);
                        fallback_h5_html(&referral_code, Some(cid), Some(&avatar_url))
                    }
                }
            }
            None => {
                tracing::info!("generate_h5: no h5_template for campaign={}, using fallback", cid);
                fallback_h5_html(&referral_code, Some(cid), Some(&avatar_url))
            }
        }
    } else {
        tracing::info!("generate_h5: no campaign_id, using fallback");
        fallback_h5_html(&referral_code, body.campaign_id.as_deref(), Some(&avatar_url))
    };

    // 🔴 2026-09-29 已退役：分享生成成就事件（成就改为「端侧计算」）

    // 返回 JSON，包含 HTML 文本 + 分享 URL（转发给好友的链接）
    let share_url = match &body.campaign_id {
        Some(cid) => format!("{}/share/{}?campaign_id={}", crate::share_data::coevo_base_url(), referral_code, cid),
        None => format!("{}/share/{}", crate::share_data::coevo_base_url(), referral_code),
    };
    Json(json!({"html": html, "url": share_url})).into_response()
}

/// GET /share/{code} — 推广落地页
///
/// 支持可选 ?campaign_id=xxx 参数，启用活动 H5 模板渲染。
pub async fn share_landing(
    Path(code): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();

    // 如果有 campaign_id，尝试用活动 H5 模板渲染
    if let Some(cid) = params.get("campaign_id") {
        let user_id: Option<String> = conn.query_row(
            "SELECT id FROM users WHERE referral_code = ?1 LIMIT 1",
            rusqlite::params![&code], |row| row.get(0),
        ).ok();

        if let Some(uid) = user_id {
            if let Some(template) = conn.query_row(
                "SELECT h5_template FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![cid], |row| row.get::<_, Option<String>>(0),
            ).ok().flatten() {
                if let Ok(data) = crate::h5_template::build_user_h5_data(&conn, &uid, cid) {
                    let mut html = crate::h5_template::replace_h5_variables(&template, &data);
                    // 注入 OG meta 标签
                    let campaign_name: String = conn.query_row(
                        "SELECT name FROM marketing_campaigns WHERE id = ?1",
                        rusqlite::params![cid], |row| row.get(0),
                    ).unwrap_or_default();
                    let frontend = crate::share_data::public_base_url();
                    let backend = crate::share_data::coevo_base_url();
                    let og = format!(
                        r#"<meta property="og:image" content="{}/app/icons/Icon-512.png">
<meta property="og:title" content="{} 邀请你一起学习">
<meta property="og:description" content="在 CoEvo 一起学习，{}活动等你参加！">
<meta property="og:url" content="{}/go/{}?campaign_id={}">"#,
                        frontend, data.display_name, campaign_name, backend, &data.referral_code, cid
                    );
                    html = html.replace("</head>", &format!("{}</head>", og));
                    return ([(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")], html);
                }
            }
        }
    }

    // 优先读取已保存的 LLM 生成 HTML
    let file_path = format!("data/share/{}/index.html", code);
    if let Ok(html) = std::fs::read_to_string(&file_path) {
        // 注入 OG meta 标签
        let frontend = crate::share_data::public_base_url();
        let backend = crate::share_data::coevo_base_url();
        let og = format!(
            r#"<meta property="og:image" content="{}/app/icons/Icon-512.png">
<meta property="og:title" content="在 CoEvo 一起学习">
<meta property="og:description" content="如果不想被AI取代，你需要刻意进化">
<meta property="og:url" content="{}/go/{}">"#,
            frontend, backend, code
        );
        let html_with_og = html.replace("</head>", &format!("{}</head>", og));
        return ([(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")], html_with_og);
    }

    // fallback: 内联模板
    let html = fallback_h5_html(&code, None, None);
    ([(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")], html)
}

/// GET /api/referral/user-portrait — 用户学习画像
///
/// 🔴 2026-09-29 已退役：原实现从 `review_log` / `user_cards` / `achievements` 读取战绩。
///     学习状态已迁端侧 → 仅返回 `users` 表内的 `streak_days`，战绩类字段一律 0 / 空。
pub async fn user_portrait(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("user_portrait: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({"error": e.to_string()}))).into_response();
    }

    let conn = crate::db_pool::get_conn();
    let uid = &query.user_id;

    // 连续学习天数（`users` 表）
    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![uid], |row| row.get(0),
    ).unwrap_or(0);

    Json(json!({
        "portrait": {
            "total_study_days": 0,
            "streak_days": streak_days,
            "today_reviews": 0,
            "total_cards": 0,
            "achievements": [],
        }
    })).into_response()
}

/// GET /share/ 或 /go/ — 无 referral code 时的通用落地页
pub async fn share_landing_home() -> impl IntoResponse {
    let html = r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CoEvo AI特级教师 — 主动式一对一学习，不遗忘不跑偏</title>
<meta name="description" content="CoEvo刻意进化学习，基于FSRS记忆算法的AI特级教师。AI一对一辅导，FSRS科学复习。不遗忘·不跑偏·不瞎编·效果看得见。免费试用，30天不满意全额退。">
<meta property="og:title" content="CoEvo AI特级教师">
<meta property="og:description" content="基于FSRS记忆算法的AI特级教师，不遗忘·不跑偏·不瞎编。">
<meta property="og:url" content="https://www.keyievolution.fun/">
<meta property="og:image" content="https://www.keyievolution.fun/icons/Icon-512.png">
<link rel="canonical" href="https://www.keyievolution.fun/">
<style>
body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;margin:0;padding:0;background:linear-gradient(135deg,#1565C0,#1A237E);color:#fff;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:20px}
h1{font-size:2em;margin-bottom:0.5em}
p{font-size:1.1em;line-height:1.6;max-width:500px;margin:0.5em auto}
.features{margin:2em 0}
.feature{margin:0.8em 0;padding:8px 16px;background:rgba(255,255,255,0.1);border-radius:8px;display:inline-block}
.cta{display:inline-block;margin-top:2em;padding:14px 40px;background:#fff;color:#1565C0;border-radius:30px;text-decoration:none;font-weight:bold;font-size:1.1em}
.url{margin-top:3em;font-size:0.85em;opacity:0.6}
</style>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[{"@type":"Question","name":"CoEvo是什么？","acceptedAnswer":{"@type":"Answer","text":"CoEvo是一个基于FSRS记忆算法的AI特级教师平台，提供一对一辅导、科学复习和个性化学习方案。"}},{"@type":"Question","name":"CoEvo和豆包/ChatGPT有什么区别？","acceptedAnswer":{"@type":"Answer","text":"CoEvo不仅提供AI对话，还通过FSRS算法自动规划复习、提取概念制卡，确保学过的内容真正内化。"}},{"@type":"Question","name":"CoEvo免费吗？","acceptedAnswer":{"@type":"Answer","text":"CoEvo提供免费试用，新用户无需注册即可立即体验全部功能。"}}]}
</script>
</head>
<body>
<h1>CoEvo AI特级教师</h1>
<p>基于FSRS记忆算法的主动式一对一学习平台。<br>不遗忘 · 不跑偏 · 不瞎编 · 效果看得见</p>
<div class="features">
<div class="feature">AI 一对一辅导</div>
<div class="feature">FSRS 科学复习</div>
<div class="feature">客观验证内化</div>
</div>
<a class="cta" href="https://www.keyievolution.fun/">免费试用</a>
<div class="url">www.keyievolution.fun</div>
</body>
</html>"#;
    ([(axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8")], html)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::init_database;

    /// 推广码格式测试：验证格式 CoEvo_ + 4位大写字母数字
    #[test]
    fn test_referral_code_format() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();

        // 模拟生成推广码的逻辑（与 auth.rs 一致）
        let mut codes: Vec<String> = Vec::new();

        // 插入测试用户，利用 referral_code UNIQUE 约束确保不重复
        for i in 0..5 {
            use rand::Rng;
            let suffix: String = rand::thread_rng()
                .sample_iter(&rand::distributions::Alphanumeric)
                .take(4)
                .map(|c| c as char)
                .collect::<String>()
                .to_uppercase();
            let candidate = format!("CoEvo_{}", suffix);

            let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
            let uid = uuid::Uuid::new_v4().to_string();
            let username = format!("test_user_{}", i);

            match conn.execute(
                "INSERT INTO users (id, username, referral_code, created_at) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![uid, username, candidate, now],
            ) {
                Ok(_) => codes.push(candidate),
                Err(_) => continue, // UNIQUE 冲突，跳过
            }
        }

        assert!(!codes.is_empty(), "至少应成功生成一个推广码");

        for code in &codes {
            // 格式: CoEvo_ + 4 位大写字母数字
            assert!(code.starts_with("CoEvo_"), "推广码应以 CoEvo_ 开头: {}", code);
            let suffix = code.trim_start_matches("CoEvo_");
            assert_eq!(suffix.len(), 4, "推广码后缀应为 4 位: {}", code);
            assert!(
                suffix.chars().all(|c| c.is_ascii_alphanumeric()),
                "推广码后缀应为大写字母数字: {}",
                code
            );
            assert_eq!(suffix.to_uppercase(), suffix, "推广码后缀应全大写: {}", code);
        }
    }

    /// 验证至少两个生成的推广码不重复
    #[test]
    fn test_referral_code_uniqueness() {
        // 使用哈希集验证 UNIQUE
        let mut seen = std::collections::HashSet::new();

        use rand::Rng;
        for _ in 0..10 {
            let suffix: String = rand::thread_rng()
                .sample_iter(&rand::distributions::Alphanumeric)
                .take(4)
                .map(|c| c as char)
                .collect::<String>()
                .to_uppercase();
            let code = format!("CoEvo_{}", suffix);
            assert!(
                seen.insert(code.clone()),
                "推广码重复: {}",
                code
            );
        }
    }

    #[test]
    fn test_fallback_poster_svg() {
        let svg = fallback_poster_svg("CoEvo_TEST");
        assert!(svg.contains("CoEvo_TEST"), "应包含推广码");
        assert!(svg.contains("<svg"), "应以 SVG 开头");
        assert!(svg.contains("</svg>"), "应以 SVG 结束");
        assert!(svg.contains("CoEvo 学习推广"), "应包含品牌名");
    }

    #[test]
    fn test_fallback_h5_html() {
        let html = crate::h5_template::fallback_h5_html("CoEvo_TEST", None, None);
        assert!(html.contains("CoEvo_TEST"), "应包含推广码");
        assert!(html.contains("<!DOCTYPE html>"), "应包含 DOCTYPE");
        assert!(html.contains("CoEvo 刻意进化学习"), "应包含品牌名");
    }

    #[test]
    fn test_load_share_prompt_file_not_found() {
        let result = load_share_prompt("/tmp/nonexistent", "poster", "signal");
        assert!(result.is_err(), "对于不存在的文件应返回错误");
    }

    #[test]
    fn test_qr_svg_format() {
        let qr = super::generate_qr_svg("http://test.com/ref=ABC", "#1A237E", "#FFFFFF");
        eprintln!("QR SVG: {}", qr);
        let has_close = qr.contains("\"/>");
        let has_space = qr.contains("\" />");
        assert!(has_close || has_space, "QR SVG should have self-closing path: close={}, space={}", has_close, has_space);
    }

    #[test]
    fn test_poster_placeholder_replaced() {
        let data = crate::poster_template::UserPosterData {
            display_name: "测试".to_string(),
            real_name: "User".to_string(),
            streak_days: 10,
            total_cards: 50,
            today_reviews: 5,
            referral_code: "TEST123".to_string(),
            qr_code_url: "http://test.com/ref=TEST123".to_string(),
            avatar_url: String::new(),
            active_plans_summary: "数学".to_string(),
            current_focus: "高数".to_string(),
            plan_count: 2,
            completed_plans: 3,
            achievement_count: 1,
        };
        let fallback = crate::poster_template::fallback_poster_svg(&data);
        assert!(fallback.contains("QR_PLACEHOLDER"), "fallback should have QR_PLACEHOLDER");
        let result = crate::poster_template::replace_template_variables(&fallback, &data);
        assert!(!result.contains("QR_PLACEHOLDER"), "QR_PLACEHOLDER should be replaced");
        assert!(result.contains("<svg"), "QR SVG should be in the result");
    }
}
