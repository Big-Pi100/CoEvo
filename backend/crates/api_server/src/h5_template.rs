//! H5 分享页模板管理：LLM 生成含 {变量} 的 HTML 模板，运行时替换为用户数据
//!
//! 数据层已抽取到 `share_data` 模块，本文件只保留 H5 特有的逻辑。

use serde::Serialize;

/// 用户 H5 数据（运行时替代模板中的 {变量}）
/// 由 `build_user_h5_data` 从 `UserShareData` 映射而来
#[derive(Debug, Serialize)]
pub struct UserH5Data {
    pub display_name: String,
    pub real_name: String,
    pub streak_days: i64,
    pub total_cards: i64,
    pub today_reviews: i64,
    pub referral_code: String,
    pub register_url: String,
    pub active_plans_summary: String,
    pub current_focus: String,
    pub plan_count: i64,
    pub completed_plans: i64,
    pub achievement_count: i64,
}

/// 替换 HTML 模板中的 {变量} 占位符为用户实际数据
pub fn replace_h5_variables(template: &str, data: &UserH5Data) -> String {
    let mut result = template.to_string();
    result = result.replace("{display_name}", &data.display_name);
    result = result.replace("{real_name}", &data.real_name);
    result = result.replace("{streak_days}", &data.streak_days.to_string());
    result = result.replace("{total_cards}", &data.total_cards.to_string());
    result = result.replace("{today_reviews}", &data.today_reviews.to_string());
    result = result.replace("{referral_code}", &data.referral_code);
    result = result.replace("{register_url}", &data.register_url);
    result = result.replace("{active_plans_summary}", &data.active_plans_summary);
    result = result.replace("{current_focus}", &data.current_focus);
    result = result.replace("{plan_count}", &data.plan_count.to_string());
    result = result.replace("{completed_plans}", &data.completed_plans.to_string());
    result = result.replace("{achievement_count}", &data.achievement_count.to_string());
    // 注入 OG meta 标签（在 </head> 前插入）
    let frontend = crate::share_data::public_base_url();
    let backend = crate::share_data::coevo_base_url();
    let share_url = format!("{}/share/{}", backend, &data.referral_code);
    let og_meta = format!(
        r#"<meta property="og:image" content="{}/app/icons/Icon-512.png">
<meta property="og:title" content="{} 邀请你一起学习">
<meta property="og:description" content="在 CoEvo 刻意进化学习，如果不想被AI取代，你需要刻意进化">
<meta property="og:url" content="{}">"#,
        frontend, data.display_name, share_url,
    );
    result = result.replace("</head>", &format!("{}</head>", og_meta));
    result
}

/// 从 DB 构建用户 H5 数据（数据层委托给 share_data）
pub fn build_user_h5_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    campaign_id: &str,
) -> Result<UserH5Data, String> {
    let shared = crate::share_data::build_user_share_data(conn, user_id, campaign_id)?;
    Ok(UserH5Data {
        register_url: shared.register_url.clone(),
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

/// 调 LLM 生成 H5 模板
pub async fn generate_h5_template_via_llm(
    base_dir: &str,
    campaign_name: &str,
    rewards: &str,
) -> Result<String, String> {
    let mut prompt = crate::referral_handler::load_combined_prompt(base_dir, "h5")
        .map_err(|e| format!("load h5 prompt failed: {}", e))?;
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
    extract_html_from_llm_reply(&reply)
}

/// 从 LLM 原始回复中提取 HTML 代码
fn extract_html_from_llm_reply(reply: &str) -> Result<String, String> {
    let mut html = reply.trim().to_string();
    for prefix in &["```html\n", "```html\r\n", "```\n", "```\r\n"] {
        if html.starts_with(prefix) {
            html = html[prefix.len()..].to_string();
            break;
        }
    }
    if html.ends_with("```") {
        html = html[..html.len() - 3].to_string();
    }
    html = html.trim().to_string();
    if !html.starts_with("<!DOCTYPE html")
        && !html.starts_with("<!doctype html")
        && !html.starts_with("<html")
    {
        return Err("LLM did not return valid HTML".to_string());
    }
    if html.contains("<script") || html.contains("javascript:") {
        return Err("LLM returned HTML with unsafe content".to_string());
    }
    Ok(html)
}

/// 静态 fallback H5（活动无模板时使用）
pub fn fallback_h5_html(referral_code: &str, campaign_id: Option<&str>) -> String {
    let app_base = crate::share_data::public_base_url();
    let api_base = crate::share_data::coevo_base_url();
    let ref_param = match campaign_id {
        Some(cid) if !cid.is_empty() => format!("?ref={}&campaign_id={}", referral_code, cid),
        _ => format!("?ref={}", referral_code),
    };
    let mut html = format!(
        r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta property="og:image" content="{app_base}/app/icons/Icon-512.png">
    <meta property="og:title" content="CoEvo 邀请你一起学习">
    <meta property="og:description" content="在 CoEvo 刻意进化学习，如果不想被AI取代，你需要刻意进化">
    <meta property="og:url" content="{api_base}/share/{{code}}">
    <title>CoEvo 学习推广</title>
    <style>
        body {{ font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea 0%, #4F46E5 100%); }}
        .card {{ background: white; border-radius: 20px; padding: 40px 24px; text-align: center; box-shadow: 0 20px 60px rgba(0,0,0,0.15); max-width: 360px; width: 90%; }}
        .brand {{ color: #4F46E5; font-size: 22px; font-weight: bold; margin-bottom: 8px; }}
        .subtitle {{ color: #666; font-size: 14px; margin-bottom: 24px; }}
        .code-label {{ color: #999; font-size: 12px; margin-bottom: 4px; }}
        .code {{ background: linear-gradient(135deg, #667eea 0%, #4F46E5 100%); border-radius: 12px; padding: 16px; font-size: 28px; font-weight: bold; color: white; letter-spacing: 4px; margin: 8px 0 24px; }}
        .btn {{ display: inline-block; background: linear-gradient(135deg, #667eea 0%, #4F46E5 100%); color: white; padding: 14px 48px; border-radius: 28px; text-decoration: none; font-size: 16px; font-weight: 600; margin-top: 8px; box-shadow: 0 4px 15px rgba(79,70,229,0.4); }}
        .footer {{ color: #999; font-size: 12px; margin-top: 20px; }}
    </style>
</head>
<body>
    <div class="card">
        <div class="brand">CoEvo 刻意进化学习</div>
        <div class="subtitle">邀请你一起加入学习之旅</div>
        <div class="code-label">我的推广码</div>
        <div class="code">{}</div>
        <a class="btn" href="{app_base}/home{ref_param}">立即注册</a>
        <div class="footer">扫码或输入推广码加入学习</div>
    </div>
</body>
</html>"#,
        referral_code
    );
    html = html.replace("{app_base}", &app_base);
    html = html.replace("{api_base}", &api_base);
    html = html.replace("{code}", referral_code);
    html
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fallback_h5_html() {
        let html = fallback_h5_html("CoEvo_TEST", None);
        assert!(html.contains("CoEvo_TEST"));
        assert!(html.contains("/home?ref=CoEvo_TEST"));
        assert!(!html.contains("campaign_id"));
    }

    #[test]
    fn test_fallback_h5_html_with_campaign() {
        let html = fallback_h5_html("CoEvo_TEST", Some("camp-123"));
        assert!(html.contains("campaign_id=camp-123"));
        assert!(html.contains("/home?ref=CoEvo_TEST&campaign_id=camp-123"));
    }

    #[test]
    fn test_replace_h5_variables() {
        let data = UserH5Data {
            display_name: "测试用户".into(),
            real_name: "张三".into(),
            streak_days: 5,
            total_cards: 42,
            today_reviews: 12,
            referral_code: "TEST".into(),
            register_url: "http://localhost:8080/home?ref=TEST".into(),
            active_plans_summary: "数学".into(),
            current_focus: "高数".into(),
            plan_count: 2,
            completed_plans: 3,
            achievement_count: 1,
        };
        let template = "{display_name}|{streak_days}|{total_cards}|{today_reviews}|{referral_code}|{register_url}".to_string();
        let result = replace_h5_variables(&template, &data);
        assert!(!result.contains("{display_name}"));
        assert!(result.contains("测试用户"));
        assert!(result.contains("http://localhost:8080/home?ref=TEST"));
    }

    #[test]
    fn test_build_user_h5_data() {
        // 集成测试依赖于 DB 连接，这里只验证结构
        let data = UserH5Data {
            display_name: "Alice".into(),
            real_name: "Test".into(),
            streak_days: 3,
            total_cards: 10,
            today_reviews: 2,
            referral_code: "ABC".into(),
            register_url: "http://localhost:8080/home?ref=ABC".into(),
            active_plans_summary: String::new(),
            current_focus: String::new(),
            plan_count: 0,
            completed_plans: 0,
            achievement_count: 0,
        };
        assert_eq!(data.register_url, "http://localhost:8080/home?ref=ABC");
    }
}
