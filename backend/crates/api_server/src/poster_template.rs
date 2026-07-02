//! 海报模板管理：LLM 生成含 {变量} 的 SVG 模板，运行时替换为用户数据
//!
//! 数据层已抽取到 `share_data` 模块，本文件只保留 SVG 特有的逻辑。

use serde::Serialize;

const ZONE_MIN_GAP: i32 = 20; // zone 之间最小间距

/// 根据 zone 类型返回合理的内容高度估算
fn zone_estimated_height(name: &str, zone_y: i32) -> i32 {
    match name {
        "qr" => 250,     // 180px QR + 装饰框 + padding
        "footer" => 50,
        "title" => 200,  // 标题 + 副标题 + 装饰线
        "code" => 130,   // 推广码 + 文本框
        _ => 260,        // stats 等数据卡片区
    }
}

/// 检测 SVG 中 `<g data-zone="xxx">` 的重叠并按顺序修正。
/// 保持 LLM 的原始创意（X 坐标、大小、装饰），只修正 Y 重叠：
/// 按 zone 在文档中出现的顺序，如果后一个 zone 的 Y 与前一个重叠，则将其下移。
/// 不在 data-zone 列表中的 zone 原样保留。
pub fn reflow_svg_zones(svg: &str) -> String {
    let mut result = svg.to_string();

    // Pass 1: 收集所有 zone 的信息（名称、原始 Y、在字符串中的位置）
    struct ZoneInfo {
        name: String,
        orig_y: i32,
        orig_x: String,
        abs_start: usize,   // "translate(" 的起始位置
        paren_end: usize,   // ")" 的结束位置
        tag_end: usize,     // 标签 > 的位置
    }
    let mut zones: Vec<ZoneInfo> = Vec::new();
    let mut search_from: usize = 0;

    loop {
        let remaining = &result[search_from..];
        let zone_start_rel = match remaining.find("data-zone=\"") {
            Some(pos) => pos,
            None => break,
        };
        let zone_start = search_from + zone_start_rel;
        let val_start = zone_start + "data-zone=\"".len();
        let val_end = match result[val_start..].find('"') {
            Some(pos) => val_start + pos,
            None => break,
        };
        let zone_name = result[val_start..val_end].to_string();

        let g_start = match result[..zone_start].rfind("<g") {
            Some(pos) => pos,
            None => { search_from = val_end; continue; }
        };
        let tag_end = match result[g_start..].find('>') {
            Some(pos) => g_start + pos,
            None => break,
        };

    let tag_slice = &result[g_start..=tag_end].to_string();
    if let Some(trans_start_rel) = tag_slice.find("translate(") {
        let abs_start = g_start + trans_start_rel;
        let after_trans = abs_start + "translate(".len();
        if let Some(paren_end_rel) = result[after_trans..].find(')') {
            let paren_end = after_trans + paren_end_rel;
            let coord = result[after_trans..paren_end].to_string();
            let parts: Vec<&str> = coord.split(',').collect();
            if parts.len() == 2 {
                let x_str = parts[0].trim().to_string();
                let y_str = parts[1].trim();
                if let Ok(y) = y_str.parse::<i32>() {
                    zones.push(ZoneInfo {
                        name: zone_name,
                        orig_y: y,
                        orig_x: x_str,
                        abs_start,
                        paren_end,
                        tag_end,
                    });
                    }
                }
            }
        }
        search_from = tag_end;
    }

    if zones.is_empty() {
        return result;
    }

    // Pass 2: 碰撞检测，按文档顺序处理所有 zone
    let mut corrected_y: Vec<i32> = zones.iter().map(|z| z.orig_y).collect();
    let mut prev_bottom = 0i32;

    for i in 0..zones.len() {
        let z = &zones[i];
        let zone_height = zone_estimated_height(&z.name, z.orig_y);

        let desired_y = z.orig_y;
        if desired_y < prev_bottom + ZONE_MIN_GAP {
            corrected_y[i] = prev_bottom + ZONE_MIN_GAP;
        }
        prev_bottom = corrected_y[i] + zone_height;
    }

    // 检查是否超出 SVG 底部（900px），超出则上提
    for i in (0..zones.len()).rev() {
        let z = &zones[i];
        let zone_height = zone_estimated_height(&z.name, z.orig_y);
        let zone_bottom = corrected_y[i] + zone_height;
        if zone_bottom > 890 {
            let max_y = 890 - zone_height;
            if max_y > 0 && corrected_y[i] > max_y {
                corrected_y[i] = max_y;
            }
        }
    }

    // Pass 3: 从后往前替换，避免位置偏移影响后续替换
    for i in (0..zones.len()).rev() {
        if corrected_y[i] == zones[i].orig_y {
            continue; // 不需要修正
        }
        let z = &zones[i];
        let old_trans = result[z.abs_start..=z.paren_end].to_string();
        let new_trans = format!("translate({}, {})", z.orig_x, corrected_y[i]);
        if old_trans == new_trans {
            continue;
        }
        let before = result[..z.abs_start].to_string();
        let after = result[z.paren_end + 1..].to_string();
        result = format!("{}{}{}", before, new_trans, after);
    }

    result
}

/// 用户海报数据（运行时替代模板中的 {变量}）
/// 由 `build_user_poster_data` 从 `UserShareData` 映射而来
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
    let qr_raw = crate::referral_handler::generate_qr_svg(&data.qr_code_url, "#1A237E", "#FFFFFF");
    let qr_png_b64 = crate::referral_handler::svg_to_png(&qr_raw)
        .ok()
        .and_then(|bytes| {
            use base64::Engine;
            Some(base64::engine::general_purpose::STANDARD.encode(&bytes))
        })
        .unwrap_or_default();
    // 二维码块
    // translate(-90,-90) 自居中：模板把 QR_PLACEHOLDER 放在 QR 框中心，偏移一半尺寸使其居中
    // clipPath 防止图像溢出 180×180 区域
    let qr_block = if !qr_png_b64.is_empty() {
        format!(
            r#"<g transform="translate(-90, -90)"><clipPath id="qr-clip-{uid}"><rect width="180" height="180"/></clipPath><g clip-path="url(#qr-clip-{uid})"><image href="data:image/png;base64,{b64}" width="180" height="180" preserveAspectRatio="xMidYMid meet"/></g></g>"#,
            uid = data.referral_code.replace(|c: char| !c.is_alphanumeric(), "_"),
            b64 = qr_png_b64,
        )
    } else {
        let bare_svg = if let Some(pos) = qr_raw.find("<svg") { &qr_raw[pos..] } else { "<svg/>" };
        format!(
            r#"<g transform="translate(-90, -90)"><clipPath id="qr-clip-{uid}"><rect width="180" height="180"/></clipPath><g clip-path="url(#qr-clip-{uid})">{svg}</g></g>"#,
            uid = data.referral_code.replace(|c: char| !c.is_alphanumeric(), "_"),
            svg = bare_svg,
        )
    };
    // 替换 QR_PLACEHOLDER（模板应包含此占位符；若不包含则不注入）
    if result.contains("QR_PLACEHOLDER") {
        result = result.replace("QR_PLACEHOLDER", &qr_block);
    }
    // data-zone 重排：将各区块按预设 Y 坐标重新定位
    result = reflow_svg_zones(&result);
    result
}

/// 从 DB 构建用户海报数据（数据层委托给 share_data）
pub fn build_user_poster_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    campaign_id: &str,
) -> Result<UserPosterData, String> {
    let shared = crate::share_data::build_user_share_data(conn, user_id, campaign_id)?;
    Ok(UserPosterData {
        qr_code_url: shared.register_url.clone(), // register_url 直接用作 QR 码链接
        display_name: shared.display_name,
        real_name: shared.real_name,
        streak_days: shared.streak_days,
        total_cards: shared.total_cards,
        today_reviews: shared.today_reviews,
        referral_code: shared.referral_code,
        active_plans_summary: shared.active_plans_summary,
        current_focus: shared.current_focus,
        plan_count: shared.plan_count,
        completed_plans: shared.completed_plans,
        achievement_count: shared.achievement_count,
    })
}

/// 调 LLM 生成含 {变量} 占位符的 SVG 模板
pub async fn generate_template_via_llm(
    base_dir: &str,
    campaign_name: &str,
    rewards: &str,
) -> Result<String, String> {
    let mut prompt = crate::referral_handler::load_combined_prompt(base_dir, "poster")
        .map_err(|e| format!("load poster-template prompt failed: {}", e))?;
    prompt = prompt.replace("{campaign_name}", campaign_name);
    prompt = prompt.replace("{campaign_rewards}", rewards);
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
    tracing::warn!("LLM raw reply (first 500c): {}", &reply.chars().take(500).collect::<String>());
    let mut svg = reply.trim().to_string();
    for prefix in &["```svg\n", "```html\n", "```svg\r\n", "```html\r\n", "```\n", "```\r\n"] {
        if svg.starts_with(prefix) {
            svg = svg[prefix.len()..].to_string();
            break;
        }
    }
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
  <g data-zone="title" transform="translate(0, 100)">
    <text x="300" y="60" text-anchor="middle" fill="#ffffff" font-size="32" font-weight="bold">{}</text>
    <text x="300" y="110" text-anchor="middle" fill="#9DA0F0" font-size="18">的学习报告</text>
  </g>
  <g data-zone="stats" transform="translate(40, 200)">
    <rect x="0" y="0" width="520" height="120" rx="12" fill="rgba(255,255,255,0.08)"/>
    <text x="40" y="50" fill="#ffffff" font-size="22" font-weight="bold">🔥 连续学习 {} 天</text>
    <text x="40" y="90" fill="#9DA0F0" font-size="16">今日已复习 {} 张卡片</text>
    <rect x="0" y="140" width="250" height="80" rx="12" fill="rgba(255,255,255,0.08)"/>
    <text x="125" y="175" text-anchor="middle" fill="#ffffff" font-size="28" font-weight="bold">{}</text>
    <text x="125" y="200" text-anchor="middle" fill="#9DA0F0" font-size="12">总卡片数</text>
    <rect x="270" y="140" width="250" height="80" rx="12" fill="rgba(255,255,255,0.08)"/>
    <text x="395" y="175" text-anchor="middle" fill="#ffffff" font-size="28" font-weight="bold">{}%</text>
    <text x="395" y="200" text-anchor="middle" fill="#9DA0F0" font-size="12">掌握率</text>
  </g>
  <g data-zone="code" transform="translate(40, 400)">
    <rect x="160" y="0" width="200" height="40" rx="12" fill="rgba(255,255,255,0.08)"/>
    <text x="260" y="26" text-anchor="middle" fill="#ffffff" font-size="14" font-weight="bold">推广码: {}</text>
  </g>
  <g data-zone="qr" transform="translate(300, 670)">
    <rect x="-90" y="-90" width="180" height="180" rx="12" fill="#ffffff"/>
    <text x="0" y="110" text-anchor="middle" fill="#1A237E" font-size="14" font-weight="bold">扫码注册</text>
    {{QR_PLACEHOLDER}}
  </g>
  <g data-zone="footer" transform="translate(0, 840)">
    <text x="300" y="20" text-anchor="middle" fill="#9DA0F0" font-size="12">⟐ CoEvo 刻意进化</text>
  </g>
</svg>"##,
        data.display_name,
        data.streak_days,
        data.today_reviews,
        data.total_cards,
        85,
        data.referral_code,
    )
}

/// 静态 fallback 分享文案
pub fn fallback_copy() -> String {
    "一起扫码学习吧！".to_string()
}
