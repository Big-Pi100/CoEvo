//! 海报模板管理：LLM 生成含 {变量} 的 SVG 模板，运行时替换为用户数据

use serde::Serialize;

/// 获取 CoEvo 公开域名（部署时通过 COEVO_BASE_URL 环境变量配置）
fn coevo_base_url() -> String {
    std::env::var("COEVO_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:8080".to_string())
}

/// 用户海报数据（运行时替代模板中的 {变量}）
#[derive(Debug, Serialize)]
pub struct UserPosterData {
    pub display_name: String,
    pub real_name: String,
    pub streak_days: i64,
    pub total_cards: i64,
    pub today_reviews: i64,
    pub referral_code: String,
    pub qr_code_url: String,
    pub active_plans_summary: String,
    pub current_focus: String,
    pub plan_count: i64,
    pub completed_plans: i64,
    pub achievement_count: i64,
}

/// 替换模板中的 {变量} 占位符为用户实际数据
pub fn replace_template_variables(template: &str, data: &UserPosterData) -> String {
    let mut result = template.to_string();
    result = result.replace("{display_name}", &data.display_name);
    result = result.replace("{real_name}", &data.real_name);
    result = result.replace("{streak_days}", &data.streak_days.to_string());
    result = result.replace("{total_cards}", &data.total_cards.to_string());
    result = result.replace("{today_reviews}", &data.today_reviews.to_string());
    result = result.replace("{referral_code}", &data.referral_code);
    result = result.replace("{active_plans_summary}", &data.active_plans_summary);
    result = result.replace("{current_focus}", &data.current_focus);
    result = result.replace("{plan_count}", &data.plan_count.to_string());
    result = result.replace("{completed_plans}", &data.completed_plans.to_string());
    result = result.replace("{achievement_count}", &data.achievement_count.to_string());
    // 生成二维码图片（先渲染为 PNG base64，再嵌入为 <image> 元素）
    // 目的：避免 SVG 嵌套/坐标转换带来的渲染不一致
    let qr_raw = crate::referral_handler::generate_qr_svg(&data.qr_code_url, "#1A237E", "#FFFFFF");
    let qr_png_b64 = crate::referral_handler::svg_to_png(&qr_raw)
        .ok()
        .and_then(|bytes| {
            use base64::Engine;
            Some(base64::engine::general_purpose::STANDARD.encode(&bytes))
        })
        .unwrap_or_default();
    let qr_block = if !qr_png_b64.is_empty() {
        // translate(-90,-90) 自居中：假设模板把 {QR_PLACEHOLDER} 放在 QR 框中心
        format!(
            "<g transform=\"translate(-90, -90)\"><image href=\"data:image/png;base64,{}\" width=\"180\" height=\"180\" preserveAspectRatio=\"xMidYMid meet\"/></g>\n",
            qr_png_b64
        )
    } else {
        // PNG 失败时的 fallback：用原始 QR SVG 替换
        let bare_svg = if let Some(pos) = qr_raw.find("<svg") { &qr_raw[pos..] } else { "<svg/>" };
        format!("<g transform=\"translate(-90, -90)\">{}</g>\n", bare_svg)
    };
    // 先尝试替换 QR_PLACEHOLDER（兼容含占位符的模板）
    if result.contains("QR_PLACEHOLDER") {
        result = result.replace("QR_PLACEHOLDER", &qr_block);
    } else {
        // 无占位符时，在 </svg> 前注入二维码
        if let Some(pos) = result.rfind("</svg>") {
            result.insert_str(pos, &qr_block);
        }
    }
    result
}

/// 从 DB 构建用户海报数据
pub fn build_user_poster_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    _campaign_id: &str,
) -> Result<UserPosterData, String> {
    let display_name: String = conn.query_row(
        "SELECT COALESCE(display_name, username) FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).map_err(|e| format!("user query: {}", e))?;

    let real_name: String = conn.query_row(
        "SELECT COALESCE(real_name, '') FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or_default();

    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_cards WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    // reviewed_at 是 INTEGER unix timestamp
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

    let qr_code_url = format!("{}/app/auth?ref={}", coevo_base_url(), referral_code);

    // 活跃计划数据
    let plan_count: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT id) FROM plan_runs WHERE user_id = ?1 AND status = 'active'",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let active_plans_summary = if plan_count > 0 {
        let mut plans: Vec<(String, String, i64)> = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT pr.subject, upp.task_key, COALESCE(upp.updated_at, 0) \
             FROM plan_runs pr \
             JOIN user_plan_progress upp ON pr.id = upp.plan_id \
             WHERE pr.user_id = ?1 AND pr.status = 'active' \
             ORDER BY upp.updated_at DESC"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
            }) {
                for row in rows.flatten() {
                    plans.push(row);
                }
            }
        }
        if plan_count <= 3 {
            plans.iter().map(|(subject, task_key, _)| {
                let task_name: String = conn.query_row(
                    "SELECT name FROM prebuilt_tasks WHERE task_key = ?1 LIMIT 1",
                    rusqlite::params![task_key], |row| row.get(0),
                ).unwrap_or_default();
                if task_name.is_empty() {
                    subject.clone()
                } else {
                    format!("{}·{}", subject, task_name)
                }
            }).collect::<Vec<_>>().join("、")
        } else {
            format!("{} 个科目", plan_count)
        }
    } else {
        String::new()
    };

    let current_focus = if plan_count > 0 {
        let mut focus = String::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT pr.subject, upp.task_key \
             FROM plan_runs pr \
             JOIN user_plan_progress upp ON pr.id = upp.plan_id \
             WHERE pr.user_id = ?1 AND pr.status = 'active' \
             ORDER BY upp.updated_at DESC LIMIT 1"
        ) {
            if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            }) {
                for row in rows.flatten() {
                    let task_name: String = conn.query_row(
                        "SELECT name FROM prebuilt_tasks WHERE task_key = ?1 LIMIT 1",
                        rusqlite::params![&row.1], |row| row.get(0),
                    ).unwrap_or_default();
                    focus = format!("{}·{}", row.0, task_name);
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

    Ok(UserPosterData {
        display_name,
        real_name,
        streak_days,
        total_cards,
        today_reviews,
        referral_code,
        qr_code_url,
        active_plans_summary,
        current_focus,
        plan_count,
        completed_plans,
        achievement_count,
    })
}

/// 调 LLM 生成含 {变量} 占位符的 SVG 模板
pub async fn generate_template_via_llm(
    base_dir: &str,
    campaign_name: &str,
    rewards: &str,
) -> Result<String, String> {
    // 加载 prompt（使用 signal/format 分离架构）
    let mut prompt = crate::referral_handler::load_combined_prompt(base_dir, "poster")
        .map_err(|e| format!("load poster-template prompt failed: {}", e))?;

    // 注入活动信息
    prompt = prompt.replace("{campaign_name}", campaign_name);
    prompt = prompt.replace("{campaign_rewards}", rewards);

    // 调 LLM（使用 90 秒超时，避免 SVG 生成被截断）
    let api_key = std::env::var("DEEPSEEK_API_KEY").unwrap_or_default();
    if api_key.is_empty() {
        return Err("DEEPSEEK_API_KEY not set".to_string());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(180))
        .build()
        .map_err(|e| format!("http client: {}", e))?;
    let url = "https://api.deepseek.com/chat/completions";
    let body = serde_json::json!({
        "model": "deepseek-v4-flash",
        "messages": [
            {"role": "system", "content": &prompt},
            {"role": "user", "content": ""}
        ],
        "stream": false,
        "max_tokens": 65536,
        "temperature": 0.7,
        "reasoning_effort": "low",
    });
    let resp = client
        .post(url)
        .header("Authorization", format!("Bearer {}", api_key))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("LLM request failed: {}", e))?;
    let result: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("LLM response parse failed: {}", e))?;
    let reply = result["choices"][0]["message"]["content"]
        .as_str()
        .ok_or_else(|| "LLM returned empty response".to_string())?
        .to_string();

    // 调试：记录原始回复
    tracing::warn!("LLM raw reply (first 500c): {}", &reply.chars().take(500).collect::<String>());

    // 提取 SVG 代码（去除可能的 markdown 包裹）
    let mut svg = reply.trim().to_string();
    // 去除开头的 ```svg、```html、``` 等
    for prefix in &["```svg\n", "```html\n", "```svg\r\n", "```html\r\n", "```\n", "```\r\n"] {
        if svg.starts_with(prefix) {
            svg = svg[prefix.len()..].to_string();
            break;
        }
    }
    // 去除结尾的 ```
    if svg.ends_with("```") {
        svg = svg[..svg.len() - 3].to_string();
    }
    svg = svg.trim().to_string();

    if !svg.starts_with("<svg") {
        return Err("LLM did not return valid SVG".to_string());
    }

    Ok(svg)
}

/// 静态 fallback 海报（模板未生成时使用）
pub fn fallback_poster_svg(data: &UserPosterData) -> String {
    format!(
        r##"<svg viewBox="0 0 600 900" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1A237E"/><stop offset="1" stop-color="#0D1457"/></linearGradient></defs>
  <rect width="600" height="900" fill="url(#bg)" rx="20"/>
  <text x="300" y="120" text-anchor="middle" fill="#ffffff" font-size="32" font-weight="bold">{}</text>
  <text x="300" y="170" text-anchor="middle" fill="#9DA0F0" font-size="18">的学习报告</text>
  <rect x="40" y="220" width="520" height="120" rx="12" fill="rgba(255,255,255,0.08)"/>
  <text x="80" y="270" fill="#ffffff" font-size="22" font-weight="bold">🔥 连续学习 {} 天</text>
  <text x="80" y="310" fill="#9DA0F0" font-size="16">今日已复习 {} 张卡片</text>
  <rect x="40" y="360" width="250" height="80" rx="12" fill="rgba(255,255,255,0.08)"/>
  <text x="165" y="395" text-anchor="middle" fill="#ffffff" font-size="28" font-weight="bold">{}</text>
  <text x="165" y="420" text-anchor="middle" fill="#9DA0F0" font-size="12">总卡片数</text>
  <rect x="310" y="360" width="250" height="80" rx="12" fill="rgba(255,255,255,0.08)"/>
  <text x="435" y="395" text-anchor="middle" fill="#ffffff" font-size="28" font-weight="bold">{}%</text>
  <text x="435" y="420" text-anchor="middle" fill="#9DA0F0" font-size="12">掌握率</text>
  <rect x="200" y="650" width="200" height="180" rx="12" fill="#ffffff"/>
  <text x="300" y="760" text-anchor="middle" fill="#1A237E" font-size="14" font-weight="bold">扫码注册</text>
  <text x="300" y="780" text-anchor="middle" fill="#1A237E" font-size="12">推广码: {}</text>
  <g transform="translate(300, 740)">
  QR_PLACEHOLDER
  </g>
  <text x="300" y="870" text-anchor="middle" fill="#9DA0F0" font-size="12">⟐ CoEvo 刻意进化</text>
</svg>"##,
        data.display_name,
        data.streak_days,
        data.today_reviews,
        data.total_cards,
        85, // fallback mastery %
        data.referral_code,
    )
}

/// 静态 fallback 分享文案
pub fn fallback_copy() -> String {
    "一起扫码学习吧！".to_string()
}
