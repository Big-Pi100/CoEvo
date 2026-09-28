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
    pub avatar_url: String,    // 用户头像 URL
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
    _conn: &rusqlite::Connection,
    _user_id: &str,
) -> UserPlanStats {
    // 🔴 2026-09-29 已退役：原实现从 `plan_runs` / `user_plan_progress` / `achievements`
    //     读取学习计划统计（K12 计划体系已整体清退；成就改为「端侧计算」）→ 统计恒 0 / 空。
    //     结构保留以兼容海报模板与前端。
    UserPlanStats {
        plan_count: 0,
        active_plans_summary: String::new(),
        current_focus: String::new(),
        completed_plans: 0,
        achievement_count: 0,
    }
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

    // 🔴 2026-09-29：学习状态已迁端侧 `user.db` → 后端不再持有卡片/复习数据，统计恒为 0。
    //     分享落地页保留字段（值为 0），文案由 LLM 依 `streak_days` 发挥。
    let total_cards: i64 = 0;
    let today_reviews: i64 = 0;

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

    // 头像 URL（永远指向 API base）
    let avatar_url = format!("{}/api/user/{}/avatar", coevo_base_url(), user_id);

    let stats = build_user_plan_stats(conn, user_id);

    Ok(UserShareData {
        display_name,
        real_name,
        streak_days,
        total_cards,
        today_reviews,
        referral_code,
        register_url,
        avatar_url,
        plan_count: stats.plan_count,
        active_plans_summary: stats.active_plans_summary,
        current_focus: stats.current_focus,
        completed_plans: stats.completed_plans,
        achievement_count: stats.achievement_count,
    })
}
