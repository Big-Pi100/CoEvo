//! 分享数据共享层：SVG 海报和 H5 海报共用同一套用户数据构建逻辑。
//!
//! 职责：
//! - 定义 `UserShareData` 通用数据接口
//! - 从 DB 构建用户全量数据（含解密）
//! - 提供 `coevo_base_url()` 单一入口

use serde::Serialize;

/// 获取 CoEvo 后端公开域名（指向 API 服务，如 /share/ 路由）
/// 部署时通过 COEVO_BASE_URL 环境变量配置，默认 http://localhost:8080
pub fn coevo_base_url() -> String {
    std::env::var("COEVO_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:8080".to_string())
}

/// 获取 CoEvo 前端公开地址（指向 Flutter Web，如 /home 路由、静态资源）
/// 部署时通过 PUBLIC_BASE_URL 环境变量配置，默认 http://localhost:3000
pub fn public_base_url() -> String {
    std::env::var("PUBLIC_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:3000".to_string())
}

/// 用户基础分享数据（两个模板共用）
#[derive(Debug, Serialize)]
pub struct UserShareData {
    pub display_name: String,
    pub real_name: String,
    pub streak_days: i64,
    pub total_cards: i64,
    pub today_reviews: i64,
    pub referral_code: String,
    pub register_url: String,  // 统一命名，海报取此值生成 QR 码
    pub plan_count: i64,
    pub active_plans_summary: String,
    pub current_focus: String,
    pub completed_plans: i64,
    pub achievement_count: i64,
}

/// 用户计划统计结果（`build_user_plan_stats` 的返回值）
pub struct UserPlanStats {
    pub plan_count: i64,
    pub active_plans_summary: String,
    pub current_focus: String,
    pub completed_plans: i64,
    pub achievement_count: i64,
}

// ── 共享：用户计划统计 ──

/// 从 DB 构建用户计划统计数据（两处模板共用同一实现）
pub fn build_user_plan_stats(
    conn: &rusqlite::Connection,
    user_id: &str,
) -> UserPlanStats {
    let plan_count: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT id) FROM plan_runs WHERE user_id = ?1 AND status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let active_plans_summary = if plan_count > 0 {
        let mut latest_plan: Option<(String, Option<String>, String)> = None;
        if let Ok(mut stmt) = conn.prepare(
            "SELECT pr.goal,
                    (SELECT upp2.task_key FROM user_plan_progress upp2
                     WHERE upp2.plan_id = pr.id AND upp2.status = 'in_progress' LIMIT 1) as task_key,
                    pr.plan_content \
             FROM plan_runs pr \
             WHERE pr.user_id = ?1 AND pr.status = 'active' \
             ORDER BY task_key IS NULL,
               (SELECT MAX(up2.updated_at) FROM user_plan_progress up2 WHERE up2.plan_id = pr.id) DESC
             LIMIT 1"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            }) {
                for row in rows.flatten() {
                    latest_plan = Some(row);
                }
            }
        }
        let summary = match latest_plan {
            Some((goal, Some(task_key), plan_content)) => {
                let task_name = match serde_json::from_str::<serde_json::Value>(&plan_content) {
                    Ok(v) => v["stages"].as_array().and_then(|stages| {
                        stages.iter().find_map(|stage| {
                            stage["tasks"].as_array().and_then(|tasks| {
                                tasks.iter().find(|t| t["task_key"].as_str() == Some(task_key.as_str()))
                            })
                        })
                    }).and_then(|t| t["name"].as_str().map(String::from))
                    .unwrap_or_default(),
                    Err(_) => String::new(),
                };
                if task_name.is_empty() { goal } else { format!("{}·{}", goal, task_name) }
            }
            Some((goal, None, _)) => goal,
            None => format!("{} 个未开始科目", plan_count),
        };
        if plan_count > 1 {
            format!("{} 等 {} 个科目", summary, plan_count - 1)
        } else {
            summary
        }
    } else {
        String::new()
    };

    let current_focus = if plan_count > 0 {
        let mut focus = String::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT pr.goal,
                    (SELECT upp2.task_key FROM user_plan_progress upp2
                     WHERE upp2.plan_id = pr.id AND upp2.status = 'in_progress' LIMIT 1) as task_key,
                    pr.plan_content \
             FROM plan_runs pr \
             WHERE pr.user_id = ?1 AND pr.status = 'active' \
             ORDER BY (SELECT MAX(up4.updated_at) FROM user_plan_progress up4 WHERE up4.plan_id = pr.id) DESC LIMIT 1"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            }) {
                for row in rows.flatten() {
                    let task_name = match serde_json::from_str::<serde_json::Value>(&row.2) {
                        Ok(v) => v["stages"].as_array().and_then(|stages| {
                            stages.iter().find_map(|stage| {
                                stage["tasks"].as_array().and_then(|tasks| {
                                    tasks.iter().find(|t| t["task_key"].as_str() == Some(&row.1))
                                })
                            })
                        }).and_then(|t| t["name"].as_str().map(String::from))
                        .unwrap_or_default(),
                        Err(_) => String::new(),
                    };
                    if task_name.is_empty() { focus = row.0; }
                    else { focus = format!("{}·{}", row.0, task_name); }
                }
            }
        }
        focus
    } else {
        String::new()
    };

    let completed_plans: i64 = conn.query_row(
        "SELECT COUNT(*) FROM plan_runs WHERE user_id = ?1 AND status = 'completed'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let achievement_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM achievements WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    UserPlanStats { plan_count, active_plans_summary, current_focus, completed_plans, achievement_count }
}

// ── 共享：构建用户全量数据 ──

/// 从 DB 构建用户完整分享数据（含解密 real_name、注入 campaign_id）
pub fn build_user_share_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    campaign_id: &str,
) -> Result<UserShareData, String> {
    let display_name: String = conn.query_row(
        "SELECT COALESCE(display_name, username) FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).map_err(|e| format!("user query: {}", e))?;

    // ⚠️ real_name 在 DB 中为 AES-256-GCM 加密，必须解密
    let real_name_raw: Option<String> = conn.query_row(
        "SELECT real_name FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).ok();
    let real_name = real_name_raw.as_ref()
        .map(|v| {
            if crate::encryption::is_encrypted(v) {
                crate::encryption::decrypt(v)
            } else {
                v.clone()
            }
        })
        .unwrap_or_default();

    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_cards WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let today_start_ts = chrono::Utc::now()
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
        .timestamp();
    let today_reviews: i64 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r JOIN user_cards c ON r.card_id = c.id \
         WHERE c.user_id = ?1 AND r.reviewed_at >= ?2",
        rusqlite::params![user_id, today_start_ts], |row| row.get(0),
    ).unwrap_or(0);

    let referral_code: String = conn.query_row(
        "SELECT referral_code FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or_default();

    let base = public_base_url();
    let register_url = if campaign_id.is_empty() {
        format!("{}/home?ref={}", base, referral_code)
    } else {
        format!("{}/home?ref={}&campaign_id={}", base, referral_code, campaign_id)
    };

    let stats = build_user_plan_stats(conn, user_id);

    Ok(UserShareData {
        display_name,
        real_name,
        streak_days,
        total_cards,
        today_reviews,
        referral_code,
        register_url,
        plan_count: stats.plan_count,
        active_plans_summary: stats.active_plans_summary,
        current_focus: stats.current_focus,
        completed_plans: stats.completed_plans,
        achievement_count: stats.achievement_count,
    })
}
