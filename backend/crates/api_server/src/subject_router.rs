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

/// 课标摘要
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CurriculumGuide {
    #[serde(rename = "_meta")]
    meta: serde_json::Value,
    subjects: std::collections::HashMap<String, serde_json::Value>,
}

static CURRICULUM: OnceLock<CurriculumGuide> = OnceLock::new();
static KNOWLEDGE_GRAPH: OnceLock<KnowledgeGraph> = OnceLock::new();

/// 知识图谱节点
#[derive(Debug, Clone, Serialize, Deserialize)]
struct KGNode {
    id: usize,
    subject: String,
    concept: String,
    grade_band: String,
    category: String,
    prerequisites: Vec<usize>,
}

/// 知识图谱边
#[derive(Debug, Clone, Serialize, Deserialize)]
struct KGEdge {
    from: usize,
    to: usize,
    r#type: String,
}

/// 知识图谱
#[derive(Debug, Clone, Serialize, Deserialize)]
struct KnowledgeGraph {
    meta: serde_json::Value,
    nodes: Vec<KGNode>,
    edges: Vec<KGEdge>,
}

const GRADE_ORDER: &[&str] = &["g1-2", "g3-4", "g5-6", "g7-9", "g10", "g11-12"];
const COMPULSORY_CATEGORY: &str = "义务教育";
const HIGH_SCHOOL_CATEGORY: &str = "高中";

/// 初始化课标（在应用启动时调用）
pub fn init_curriculum(path: &str) {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    if let Ok(guide) = serde_json::from_str::<CurriculumGuide>(&content) {
        let _ = CURRICULUM.set(guide);
    }
}

/// 初始化知识图谱（在应用启动时调用）
pub fn init_knowledge_graph(path: &str) {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    if let Ok(kg) = serde_json::from_str::<KnowledgeGraph>(&content) {
        let _ = KNOWLEDGE_GRAPH.set(kg);
    }
}

/// 获取知识图谱路径描述（用于 prompt 注入）
pub fn get_knowledge_paths(subject: &str, grade_band: &str) -> String {
    let kg = match KNOWLEDGE_GRAPH.get() {
        Some(g) => g,
        None => return String::new(),
    };

    // 找到当前年级+之前所有年级的该科节点
    let grade_idx = GRADE_ORDER.iter().position(|g| *g == grade_band);
    let relevant_bands: Vec<&str> = match grade_idx {
        Some(idx) => GRADE_ORDER[..=idx].to_vec(),
        None => vec![grade_band],
    };

    // 按 grade_band 顺序收集节点
    let mut lines: Vec<String> = Vec::new();
    for band in &relevant_bands {
        let band_nodes: Vec<_> = kg.nodes.iter()
            .filter(|n| n.subject == subject && n.grade_band == *band)
            .collect();
        if band_nodes.is_empty() { continue; }

        let concept_list: Vec<String> = band_nodes.iter()
            .map(|n| n.concept.clone())
            .collect();
        lines.push(format!("【{}】 {}", band, concept_list.join(" → ")));
    }

    if lines.is_empty() { return String::new(); }
    format!(
        "\n### 教学顺序\n以下概念按学习顺序列出（→ 表示先后依赖）：\n{}",
        lines.join("\n")
    )
}

/// 从 guide 的 subject 数据中提取指定 band 的 items
fn get_band_items(subject_data: &serde_json::Value, grade_band: &str) -> Vec<String> {
    let category = if grade_band.starts_with("g10") { "高中" } else { "义务教育" };
    subject_data.get(category)
        .and_then(|c| c.get(grade_band))
        .and_then(|g| g.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// 获取课标约束（覆盖内容 + 禁止超纲内容）
pub fn get_curriculum_bounds(subject: &str, grade_band: &str) -> (String, String) {
    let guide = match CURRICULUM.get() {
        Some(g) => g,
        None => return (String::new(), String::new()),
    };

    let subject_data = match guide.subjects.get(subject) {
        Some(d) => d,
        None => return (String::new(), String::new()),
    };

    // 当前年级必须覆盖的内容
    let current_items = get_band_items(subject_data, grade_band);
    let cover = current_items.iter().map(|i| format!("- {}", i)).collect::<Vec<_>>().join("\n");

    // 查找下一个学段（禁止深入的内容）
    let grade_idx = GRADE_ORDER.iter().position(|g| *g == grade_band);
    let bound = grade_idx
        .and_then(|idx| GRADE_ORDER.get(idx + 1))
        .and_then(|next_band| {
            let next_items = get_band_items(subject_data, next_band);
            if next_items.is_empty() { None }
            else {
                Some(next_items.iter().map(|i| format!("- {}", i)).collect::<Vec<_>>().join("\n"))
            }
        })
        .unwrap_or_default();

    (cover, bound)
}

/// 获取课标摘要片段（兼容旧接口）
pub fn get_curriculum_hint(subject: &str, grade_band: &str) -> String {
    let (cover, _) = get_curriculum_bounds(subject, grade_band);
    cover
}

/// LLM 路由 prompt
pub fn build_routing_prompt(user_message: &str) -> String {
    format!(
        r#"分析以下学生请求，提取"科目"和"年级"两个字段。

科目可选值：数学、语文、英语、物理、化学、生物、历史、地理、政治、科学
年级可选值：一年级、二年级、三年级、四年级、五年级、六年级、初一(七年级)、初二(八年级)、初三(九年级)、高一(十年级)、高二(十一年级)、高三(十二年级)
如果未明确提及，科目默认为"数学"（最常见的自学科目），年级留空。

学生请求：{message}

只返回 JSON，格式：
{{"subject": "科目", "grade": "年级", "description": "一句话描述"}}
"#,
        message = user_message
    )
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
        assert_eq!(subject_to_domain("物理"), "math");
        assert_eq!(subject_to_domain("英语"), "language");
        assert_eq!(subject_to_domain("化学"), "chemistry");
        assert_eq!(subject_to_domain("生物"), "biology");
        assert_eq!(subject_to_domain("语文"), "");
        assert_eq!(subject_to_domain("历史"), "");
    }
}
