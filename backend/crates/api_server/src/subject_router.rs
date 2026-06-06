//! 学科+年级路由 — 在用户第一句话时检测 subject 和 grade
//!
//! 流程：
//!   1. 用户: "我想学小学数学三年级"
//!   2. LLM 路由: subject="数学", grade="三年级"
//!   3. 映射: domain="math", grade_band="g3-4"
//!   4. 加载 curriculum_guide[数学][义务教育][g3-4]
//!   5. 注入到系统 prompt

use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// 路由结果
#[derive(Debug, Clone)]
pub struct RoutingResult {
    pub subject: String,
    pub grade_text: String,
    pub domain: String,
    pub grade_band: String,
    pub curriculum_hint: String,
}

/// 学科 → domain 映射（与 pipeline_router::Domain enum 对齐）
fn subject_to_domain(subject: &str) -> &'static str {
    match subject {
        "数学" => "math",
        "语文" | "英语" | "日语" | "俄语" => "language",
        "化学" => "chemistry",
        "生物" | "生物学" => "biology",
        "物理" => "physics",
        "历史" => "history",
        "地理" => "geography",
        "政治" | "道德与法治" | "道法" => "politics",
        "科学" => "science",
        "信息技术" | "信息科技" => "it",
        "体育" | "体育与健康" => "pe",
        "美术" | "音乐" | "艺术" => "art",
        "劳动" => "labor",
        _ => "general", // 未知科目兜底
    }
}

/// 年级文本 → grade_band
fn grade_to_band(text: &str) -> &'static str {
    if text.contains("一") || text.contains("二") {
        // 注意：需要区分"一/二年级" vs "高一/高二"
        if text.contains("高") || text.contains("十") {
            if text.contains("一") || text.contains("十") { "g10-12" }
            else if text.contains("二") || text.contains("十一") { "g10-12" }
            else if text.contains("三") || text.contains("十二") { "g10-12" }
            else { "g10-12" }
        } else {
            if text.contains("初") { "g7-9" }
            else if text.contains("一") || text.contains("二") { "g1-2" }
            else if text.contains("三") || text.contains("四") { "g3-4" }
            else if text.contains("五") || text.contains("六") { "g5-6" }
            else { "g1-2" }
        }
    } else if text.contains("三") || text.contains("四") {
        if text.contains("高") || text.contains("十") { "g10-12" }
        else { "g3-4" }
    } else if text.contains("五") || text.contains("六") {
        if text.contains("高") || text.contains("十") { "g10-12" }
        else { "g5-6" }
    } else if text.contains("七") || text.contains("八") || text.contains("九") || text.contains("初") {
        "g7-9"
    } else if text.contains("高") || text.contains("十") {
        "g10-12"
    } else {
        // 默认：基于学段关键词
        if text.contains("小") || text.contains("小学") || text.contains("低年级") { "g1-2" }
        else if text.contains("中") || text.contains("初中") { "g7-9" }
        else if text.contains("高") || text.contains("高中") { "g10-12" }
        else { "" }
    }
}


/// LLM 路由 prompt
pub fn build_routing_prompt(user_message: &str) -> String {
    chat_engine::prompt_loader::get_routing().subject
        .replace("{message}", user_message)
}

/// 解析 LLM 路由响应
pub fn parse_routing_response(response: &str) -> (String, String) {
    // 尝试提取 JSON
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(response) {
        let subject = json.get("subject").and_then(|v| v.as_str()).unwrap_or("数学").to_string();
        let grade = json.get("grade").and_then(|v| v.as_str()).unwrap_or("").to_string();
        return (subject, grade);
    }
    // 降级：关键词匹配
    ("数学".to_string(), String::new())
}

/// 执行路由（在聊天开始时调用）
pub async fn route(
    user_message: &str,
    caller: &mut chat_engine::llm_caller::LlmCaller,
) -> RoutingResult {
    let subject: String;
    let grade_text: String;

    // LLM 路由
    let prompt = build_routing_prompt(user_message);
    match caller.generate("", &prompt).await {
        Ok(response) => {
            let (s, g) = parse_routing_response(&response);
            subject = s;
            grade_text = g;
        }
        Err(_) => {
            // 降级：关键词匹配
            subject = "数学".to_string();
            grade_text = String::new();
        }
    }

    let domain = subject_to_domain(&subject).to_string();
    let grade_band = grade_to_band(&grade_text).to_string();
    let curriculum_hint = get_curriculum_hint(&subject, &grade_band);

    RoutingResult {
        subject, grade_text, domain, grade_band, curriculum_hint,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_grade_mapping() {
        assert_eq!(grade_to_band("小学三年级"), "g3-4");
        assert_eq!(grade_to_band("初一"), "g7-9");
        assert_eq!(grade_to_band("高一"), "g10-12");
        assert_eq!(grade_to_band("五年级"), "g5-6");
        assert_eq!(grade_to_band("初二"), "g7-9");
        assert_eq!(grade_to_band(""), "");
    }

    #[test]
    fn test_subject_mapping() {
        assert_eq!(subject_to_domain("数学"), "math");
        assert_eq!(subject_to_domain("物理"), "physics");
        assert_eq!(subject_to_domain("英语"), "language");
        assert_eq!(subject_to_domain("化学"), "chemistry");
        assert_eq!(subject_to_domain("生物"), "biology");
        assert_eq!(subject_to_domain("语文"), "language");
        assert_eq!(subject_to_domain("历史"), "history");
    }
}
