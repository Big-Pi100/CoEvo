//! H5 分享页模板管理：LLM 生成含 {变量} 的 HTML 模板，运行时替换为用户数据
//!
//! 严格复制 poster_template.rs 的模式，但：
//! - 模板格式为 HTML（非 SVG）
//! - 新增 {share_url} 变量（替代海报的 QR_PLACEHOLDER）
//! - 含 HTML 安全检查（禁止 script/事件处理器/javascript: 协议）

use serde::Serialize;

/// 用户 H5 数据（运行时替代模板中的 {变量}）
#[derive(Debug, Serialize)]
pub struct UserH5Data {
    pub display_name: String,
    pub streak_days: i64,
    pub total_cards: i64,
    pub today_reviews: i64,
    pub referral_code: String,
    pub share_url: String,
}

/// 替换 HTML 模板中的 {变量} 占位符为用户实际数据
///
/// 替换规则：
///   1. 遍历 UserH5Data 所有字段，做 String::replace()
///   2. {share_url} 替换为完整分享链接
///   3. 不解析嵌套变量、不支持条件逻辑
pub fn replace_h5_variables(template: &str, data: &UserH5Data) -> String {
    let mut result = template.to_string();
    result = result.replace("{display_name}", &data.display_name);
    result = result.replace("{streak_days}", &data.streak_days.to_string());
    result = result.replace("{total_cards}", &data.total_cards.to_string());
    result = result.replace("{today_reviews}", &data.today_reviews.to_string());
    result = result.replace("{referral_code}", &data.referral_code);
    result = result.replace("{share_url}", &data.share_url);
    result
}

/// 从 DB 构建用户 H5 变量替换数据
///
/// 与 build_user_poster_data() 模式相同，但：
/// - 去掉 qr_code_url 字段
/// - 新增 share_url: https://keyievolution.fun/share/{referral_code}
pub fn build_user_h5_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    _campaign_id: &str, // 保留扩展性
) -> Result<UserH5Data, String> {
    let display_name: String = conn.query_row(
        "SELECT COALESCE(display_name, username) FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).map_err(|e| format!("user query: {}", e))?;

    let streak_days: i64 = conn.query_row(
        "SELECT streak_days FROM users WHERE id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_cards: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_cards WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    // reviewed_at 是 INTEGER unix timestamp，与 poster_template.rs 一致
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

    let share_url = format!("https://keyievolution.fun/share/{}", referral_code);

    Ok(UserH5Data {
        display_name,
        streak_days,
        total_cards,
        today_reviews,
        referral_code,
        share_url,
    })
}

/// 调 LLM 生成含 {变量} 占位符的 HTML 模板
///
/// 逻辑与 poster_template::generate_template_via_llm() 相同，但：
/// - 使用 "h5-template" prompt
/// - 使用 h5_template::extract_html_from_llm_reply() 提取 HTML（含安全检查）
pub async fn generate_h5_template_via_llm(
    base_dir: &str,
    campaign_name: &str,
    rewards: &str,
) -> Result<String, String> {
    // 加载 prompt（使用 signal/format 分离架构）
    let mut prompt = crate::referral_handler::load_combined_prompt(base_dir, "h5")
        .map_err(|e| format!("load h5 prompt failed: {}", e))?;

    // 注入活动信息
    prompt = prompt.replace("{campaign_name}", campaign_name);
    prompt = prompt.replace("{campaign_rewards}", rewards);

    // 调 LLM（使用 90 秒超时）
    let api_key = std::env::var("DEEPSEEK_API_KEY").unwrap_or_default();
    if api_key.is_empty() {
        return Err("DEEPSEEK_API_KEY not set".to_string());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
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
    tracing::warn!("LLM raw reply (first 500c): {}", &reply[..reply.len().min(500)]);

    extract_html_from_llm_reply(&reply)
}

/// 从 LLM 原始回复中提取 HTML 代码
///
/// 包含安全检查：
///   1. 去除 markdown 包裹（```html / ```）
///   2. 必须以 <!DOCTYPE html 或 <html 开头
///   3. 不得包含 <script> 标签
///   4. 不得包含事件处理器属性（onload= / onclick= 等）
///   5. 不得包含 javascript: 协议
fn extract_html_from_llm_reply(reply: &str) -> Result<String, String> {
    let mut html = reply.trim().to_string();
    // 去除 markdown 包裹
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

    // 检查是否以合法 HTML 开头
    if !html.starts_with("<!DOCTYPE html")
        && !html.starts_with("<!doctype html")
        && !html.starts_with("<html")
    {
        return Err("LLM did not return valid HTML".to_string());
    }

    // 安全检查：禁止 script 标签
    if html.contains("<script") || html.contains("</script") {
        return Err("LLM returned HTML with script tags".to_string());
    }
    // 安全检查：禁止事件处理器
    for attr in &[
        "onload=", "onclick=", "onerror=", "onsubmit=", "onchange=",
        "onmouseover=", "onfocus=", "onblur=", "onkeydown=", "onkeyup=",
    ] {
        if html.contains(attr) {
            return Err(format!(
                "LLM returned HTML with prohibited event handler: {}",
                attr
            ));
        }
    }
    // 安全检查：禁止 javascript: 协议
    if html.contains("javascript:") {
        return Err("LLM returned HTML with javascript: protocol".to_string());
    }

    Ok(html)
}

/// 静态 fallback H5 HTML（模板未生成时使用）
///
/// 原实现在 referral_handler.rs，迁移至此。
pub fn fallback_h5_html(referral_code: &str) -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
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
        <a class="btn" href="/app/auth?ref={}">立即注册</a>
        <div class="footer">扫码或输入推广码加入学习</div>
    </div>
</body>
</html>"#,
        referral_code, referral_code
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replace_h5_variables() {
        let template = r#"Hello {display_name}, streak: {streak_days}, share: {share_url}"#;
        let data = UserH5Data {
            display_name: "小明".to_string(),
            streak_days: 15,
            total_cards: 42,
            today_reviews: 8,
            referral_code: "ABC123".to_string(),
            share_url: "https://keyievolution.fun/share/ABC123".to_string(),
        };
        let result = replace_h5_variables(template, &data);
        assert!(result.contains("小明"));
        assert!(result.contains("15"));
        assert!(result.contains("https://keyievolution.fun/share/ABC123"));
        assert!(!result.contains("{display_name}"));
        assert!(!result.contains("{streak_days}"));
        assert!(!result.contains("{share_url}"));
    }

    #[test]
    fn test_extract_html_valid() {
        let reply = "<!DOCTYPE html>\n<html><body>Hello</body></html>";
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_ok());
    }

    #[test]
    fn test_extract_html_no_doctype() {
        let reply = "<html><body>Hello</body></html>";
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_ok());
    }

    #[test]
    fn test_extract_html_with_script() {
        let reply = "<!DOCTYPE html><script>alert(1)</script>";
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_err());
    }

    #[test]
    fn test_extract_html_markdown_wrapped() {
        let reply = "```html\n<!DOCTYPE html>\n<html><body>Hi</body></html>\n```";
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_ok());
    }

    #[test]
    fn test_extract_html_event_handler() {
        let reply = r#"<!DOCTYPE html><body onload="alert(1)">"#;
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_err());
    }

    #[test]
    fn test_extract_html_javascript_protocol() {
        let reply = r#"<!DOCTYPE html><a href="javascript:void(0)">link</a>"#;
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_err());
    }

    #[test]
    fn test_build_user_h5_data_structure() {
        let data = UserH5Data {
            display_name: "test".into(),
            streak_days: 0,
            total_cards: 0,
            today_reviews: 0,
            referral_code: "TEST".into(),
            share_url: "https://keyievolution.fun/share/TEST".into(),
        };
        assert_eq!(data.share_url, "https://keyievolution.fun/share/TEST");
        assert!(data.share_url.contains(&data.referral_code));
    }

    #[test]
    fn test_fallback_h5_html() {
        let html = fallback_h5_html("CoEvo_TEST");
        assert!(html.contains("CoEvo_TEST"), "应包含推广码");
        assert!(html.contains("<!DOCTYPE html>"), "应包含 DOCTYPE");
        assert!(html.contains("CoEvo 刻意进化学习"), "应包含品牌名");
    }

    #[test]
    fn test_replace_all_variables() {
        let template = "{display_name}|{streak_days}|{total_cards}|{today_reviews}|{referral_code}|{share_url}";
        let data = UserH5Data {
            display_name: "Alice".into(),
            streak_days: 7,
            total_cards: 100,
            today_reviews: 5,
            referral_code: "XYZ789".into(),
            share_url: "https://keyievolution.fun/share/XYZ789".into(),
        };
        let result = replace_h5_variables(template, &data);
        assert_eq!(result, "Alice|7|100|5|XYZ789|https://keyievolution.fun/share/XYZ789");
    }

    #[test]
    fn test_extract_html_invalid_not_html() {
        let reply = "just some text without HTML tags";
        let result = extract_html_from_llm_reply(reply);
        assert!(result.is_err());
    }
}
