//! Prompt Loader — 按类别 × 科目加载 prompt 模板
//!
//! 目录结构:
//!   prompts/{category}/{subject}/{type}.md
//!
//! 类别:
//!   chat     - 教师对话（free/structured/reading...）
//!   concept  - CP1 概念提取（extract/direct）
//!   plan     - CP2 计划管理（creation/analysis/signal）
//!   quiz     - 考核（generate/judge/grill）
//!   verify   - 复习验证（spelling/dialogue/translation）
//!   routing  - 学科路由（subject）
//!
//! 每类别下 general/ 作为通用兜底，科目目录不存在时 fallback。

use std::collections::HashMap;
use std::sync::OnceLock;

// ── 各类别 prompt 结构体 ──

#[derive(Clone, Debug, Default)]
pub struct ChatTemplates {
    pub free: String,
    pub structured: String,
    pub reading: String,
    pub reading_nursery: String,
    pub reading_primary: String,
    pub reading_secondary: String,
}

#[derive(Clone, Debug, Default)]
pub struct ConceptTemplates {
    pub extract: String,
    pub direct: String,
}

#[derive(Clone, Debug, Default)]
pub struct PlanTemplates {
    pub creation: String,
    pub analysis: String,
    pub signal: String,
}

#[derive(Clone, Debug, Default)]
pub struct QuizTemplates {
    pub generate: String,
    pub judge: String,
    pub grill: String,
}

#[derive(Clone, Debug, Default)]
pub struct VerifyTemplates {
    pub spelling: String,
    pub dialogue: String,
    pub translation: String,
}

#[derive(Clone, Debug, Default)]
pub struct RoutingTemplates {
    pub subject: String,
}

// ── 注册表 ──

pub struct PromptRegistry {
    /// 各类别 × 科目 map
    pub chat: HashMap<String, ChatTemplates>,
    pub concept: HashMap<String, ConceptTemplates>,
    pub plan: HashMap<String, PlanTemplates>,
    pub quiz: HashMap<String, QuizTemplates>,
    pub verify: HashMap<String, VerifyTemplates>,
    pub routing: HashMap<String, RoutingTemplates>,
    /// 各类别通用兜底
    pub chat_general: ChatTemplates,
    pub concept_general: ConceptTemplates,
    pub plan_general: PlanTemplates,
    pub quiz_general: QuizTemplates,
    pub verify_general: VerifyTemplates,
    pub routing_general: RoutingTemplates,
}

static REGISTRY: OnceLock<PromptRegistry> = OnceLock::new();

// ── 加载函数 ──

fn read_file(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

fn read_file_with_alt(path: &str, alt: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|_| alt.to_string())
}

fn load_chat_dir(dir: &str) -> ChatTemplates {
    ChatTemplates {
        free: read_file(&format!("{}/free.md", dir)),
        structured: read_file(&format!("{}/structured.md", dir)),
        reading: read_file(&format!("{}/reading.md", dir)),
        reading_nursery: read_file(&format!("{}/reading-nursery.md", dir)),
        reading_primary: read_file(&format!("{}/reading-primary.md", dir)),
        reading_secondary: read_file(&format!("{}/reading-secondary.md", dir)),
    }
}

fn load_chat_dir_with_fallback(dir: &str, fallback: &ChatTemplates) -> ChatTemplates {
    ChatTemplates {
        free: read_file_with_alt(&format!("{}/free.md", dir), &fallback.free),
        structured: read_file_with_alt(&format!("{}/structured.md", dir), &fallback.structured),
        reading: read_file_with_alt(&format!("{}/reading.md", dir), &fallback.reading),
        reading_nursery: read_file_with_alt(&format!("{}/reading-nursery.md", dir), &fallback.reading_nursery),
        reading_primary: read_file_with_alt(&format!("{}/reading-primary.md", dir), &fallback.reading_primary),
        reading_secondary: read_file_with_alt(&format!("{}/reading-secondary.md", dir), &fallback.reading_secondary),
    }
}

fn load_concept_dir(dir: &str) -> ConceptTemplates {
    ConceptTemplates {
        extract: read_file(&format!("{}/extract.md", dir)),
        direct: read_file(&format!("{}/direct.md", dir)),
    }
}

fn load_concept_dir_with_fallback(dir: &str, fallback: &ConceptTemplates) -> ConceptTemplates {
    ConceptTemplates {
        extract: read_file_with_alt(&format!("{}/extract.md", dir), &fallback.extract),
        direct: read_file_with_alt(&format!("{}/direct.md", dir), &fallback.direct),
    }
}

fn load_plan_dir(dir: &str) -> PlanTemplates {
    PlanTemplates {
        creation: read_file(&format!("{}/creation.md", dir)),
        analysis: read_file(&format!("{}/analysis.md", dir)),
        signal: read_file(&format!("{}/signal.md", dir)),
    }
}

fn load_plan_dir_with_fallback(dir: &str, fallback: &PlanTemplates) -> PlanTemplates {
    PlanTemplates {
        creation: read_file_with_alt(&format!("{}/creation.md", dir), &fallback.creation),
        analysis: read_file_with_alt(&format!("{}/analysis.md", dir), &fallback.analysis),
        signal: read_file_with_alt(&format!("{}/signal.md", dir), &fallback.signal),
    }
}

fn load_quiz_dir(dir: &str) -> QuizTemplates {
    QuizTemplates {
        generate: read_file(&format!("{}/generate.md", dir)),
        judge: read_file(&format!("{}/judge.md", dir)),
        grill: read_file(&format!("{}/grill.md", dir)),
    }
}

fn load_quiz_dir_with_fallback(dir: &str, fallback: &QuizTemplates) -> QuizTemplates {
    QuizTemplates {
        generate: read_file_with_alt(&format!("{}/generate.md", dir), &fallback.generate),
        judge: read_file_with_alt(&format!("{}/judge.md", dir), &fallback.judge),
        grill: read_file_with_alt(&format!("{}/grill.md", dir), &fallback.grill),
    }
}

fn load_verify_dir(dir: &str) -> VerifyTemplates {
    VerifyTemplates {
        spelling: read_file(&format!("{}/spelling.md", dir)),
        dialogue: read_file(&format!("{}/dialogue.md", dir)),
        translation: read_file(&format!("{}/translation.md", dir)),
    }
}

fn load_verify_dir_with_fallback(dir: &str, fallback: &VerifyTemplates) -> VerifyTemplates {
    VerifyTemplates {
        spelling: read_file_with_alt(&format!("{}/spelling.md", dir), &fallback.spelling),
        dialogue: read_file_with_alt(&format!("{}/dialogue.md", dir), &fallback.dialogue),
        translation: read_file_with_alt(&format!("{}/translation.md", dir), &fallback.translation),
    }
}

fn load_routing_dir(dir: &str) -> RoutingTemplates {
    RoutingTemplates {
        subject: read_file(&format!("{}/subject.md", dir)),
    }
}

fn load_routing_dir_with_fallback(dir: &str, fallback: &RoutingTemplates) -> RoutingTemplates {
    RoutingTemplates {
        subject: read_file_with_alt(&format!("{}/subject.md", dir), &fallback.subject),
    }
}

/// 扫描某类别下所有科目子目录并注册
fn scan_subject_dirs<T, F1, F2>(base_dir: &str, load_dir: F1, load_with_fb: F2) -> (HashMap<String, T>, T)
where
    T: Clone + Default,
    F1: Fn(&str) -> T,
    F2: Fn(&str, &T) -> T,
{
    let general_dir = format!("{}/general", base_dir);
    let general = if std::path::Path::new(&general_dir).exists() {
        load_dir(&general_dir)
    } else {
        T::default()
    };

    let mut map = HashMap::new();
    if let Ok(entries) = std::fs::read_dir(base_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() { continue; }
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if !n.is_empty() && n != "general" => n.to_string(),
                _ => continue,
            };
            let dir_str = path.to_string_lossy().to_string();
            let tpl = load_with_fb(&dir_str, &general);
            map.insert(name, tpl);
        }
    }
    (map, general)
}

// ── 初始化 ──

/// 初始化: 扫描 prompts/{category}/{subject}/ 注册所有 prompt
pub fn init(base_dir: &str) {
    let (chat, chat_general) = scan_subject_dirs(
        &format!("{}/chat", base_dir),
        load_chat_dir,
        load_chat_dir_with_fallback,
    );
    let (concept, concept_general) = scan_subject_dirs(
        &format!("{}/concept", base_dir),
        load_concept_dir,
        load_concept_dir_with_fallback,
    );
    let (plan, plan_general) = scan_subject_dirs(
        &format!("{}/plan", base_dir),
        load_plan_dir,
        load_plan_dir_with_fallback,
    );
    let (quiz, quiz_general) = scan_subject_dirs(
        &format!("{}/quiz", base_dir),
        load_quiz_dir,
        load_quiz_dir_with_fallback,
    );
    let (verify, verify_general) = scan_subject_dirs(
        &format!("{}/verify", base_dir),
        load_verify_dir,
        load_verify_dir_with_fallback,
    );
    let (routing, routing_general) = scan_subject_dirs(
        &format!("{}/routing", base_dir),
        load_routing_dir,
        load_routing_dir_with_fallback,
    );

    let registry = PromptRegistry {
        chat: chat.clone(), chat_general: chat_general.clone(),
        concept: concept.clone(), concept_general: concept_general.clone(),
        plan: plan.clone(), plan_general: plan_general.clone(),
        quiz: quiz.clone(), quiz_general: quiz_general.clone(),
        verify: verify.clone(), verify_general: verify_general.clone(),
        routing: routing.clone(), routing_general: routing_general.clone(),
    };
    let _ = REGISTRY.set(registry);

    tracing::info!(
        "Prompts loaded: chat({} subjects), concept({}), plan({}), quiz({}), verify({}), routing({})",
        chat.len(), concept.len(), plan.len(), quiz.len(), verify.len(), routing.len(),
    );
}

// ── 查询 API ──

/// 获取教师对话 prompt，按科目 fallback
pub fn get_chat(subject: &str) -> &'static ChatTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.chat_general;
    }
    r.chat.get(subject).unwrap_or(&r.chat_general)
}

/// 获取概念提取 prompt，按科目 fallback
pub fn get_concept(subject: &str) -> &'static ConceptTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.concept_general;
    }
    r.concept.get(subject).unwrap_or(&r.concept_general)
}

/// 获取计划 prompt（暂仅 general/，后续可扩展）
pub fn get_plan(subject: &str) -> &'static PlanTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.plan_general;
    }
    r.plan.get(subject).unwrap_or(&r.plan_general)
}

/// 获取考核 prompt，按科目 fallback
pub fn get_quiz(subject: &str) -> &'static QuizTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.quiz_general;
    }
    r.quiz.get(subject).unwrap_or(&r.quiz_general)
}

/// 获取复习验证 prompt（暂仅 general/）
pub fn get_verify(subject: &str) -> &'static VerifyTemplates {
    let r = REGISTRY.get().expect("Prompts not initialized");
    if subject.is_empty() || subject == "general" {
        return &r.verify_general;
    }
    r.verify.get(subject).unwrap_or(&r.verify_general)
}

/// 获取路由 prompt
pub fn get_routing() -> &'static RoutingTemplates {
    &REGISTRY.get().expect("Prompts not initialized").routing_general
}

// ── 辅助函数（供 concept_extractor 等调用） ──

/// 构建概念提取 prompt（通用管线，后向兼容）
pub fn build_concept_extract(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
) -> String {
    build_concept_extract_for_domain(text, existing_concepts, context_turns, "general")
}

/// 构建概念提取 prompt（带 domain 路由）
pub fn build_concept_extract_for_domain(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
    domain: &str,
) -> String {
    build_concept_extract_for_domain_with_plan(text, existing_concepts, context_turns, domain, "")
}

/// 构建概念提取 prompt（带 domain 路由 + plan 上下文）
pub fn build_concept_extract_for_domain_with_plan(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
    domain: &str,
    plan_context: &str,
) -> String {
    let tpl = get_concept(domain);

    let concepts_str = if existing_concepts.is_empty() {
        "（暂无）".to_string()
    } else {
        existing_concepts
            .iter()
            .map(|c| format!("- {}", c))
            .collect::<Vec<_>>()
            .join("\n")
    };

    let history_str = if context_turns.is_empty() {
        "（首轮对话）".to_string()
    } else {
        context_turns
            .iter()
            .map(|(role, content)| format!("{}: {}", role, content))
            .collect::<Vec<_>>()
            .join("\n")
    };

    if tpl.extract.is_empty() {
        // 降级为硬编码
        format!(
            "从以下文本中提取值得记住的知识点，最多5个。返回JSON数组。\n\n已有概念:\n{}\n\n{}",
            concepts_str, text
        )
    } else {
        tpl.extract.replace("{text}", text)
            .replace("{existing_concepts_list}", &concepts_str)
            .replace("{conversation_history}", &history_str)
            .replace("{plan_context}", plan_context)
    }
}

/// 构建直接制卡 prompt
pub fn build_card_direct(user_message: &str, ai_reply: &str) -> String {
    let tpl = get_concept("general");
    if tpl.direct.is_empty() {
        format!("Generate a flashcard from this conversation.\nUser: {}\nAI: {}", user_message, ai_reply)
    } else {
        tpl.direct.replace("{user_message}", user_message)
           .replace("{ai_reply}", ai_reply)
    }
}

// ── 后向兼容（过渡期用，后续删除） ──
use crate::pipeline_router::Domain;

/// 后向兼容: 从 Domain 解析 subject，获取 chat prompt
pub fn get_chat_for_domain(domain: &Domain) -> &'static ChatTemplates {
    get_chat(&domain.to_string())
}

/// 后向兼容: 从 domain 字符串获取 concept prompt
pub fn get_concept_for_domain(domain: &str) -> &'static ConceptTemplates {
    get_concept(domain)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_init() {
        let tmp = std::env::temp_dir().join("coevo_prompt_cat_test");
        // chat/
        std::fs::create_dir_all(tmp.join("chat/general")).ok();
        std::fs::create_dir_all(tmp.join("chat/math")).ok();
        std::fs::write(tmp.join("chat/general/free.md"), "通用聊天模板").ok();
        std::fs::write(tmp.join("chat/math/free.md"), "数学聊天模板").ok();
        // concept/
        std::fs::create_dir_all(tmp.join("concept/general")).ok();
        std::fs::write(tmp.join("concept/general/extract.md"), "通用提取模板").ok();
        // quiz/
        std::fs::create_dir_all(tmp.join("quiz/general")).ok();
        std::fs::write(tmp.join("quiz/general/generate.md"), "通用出题模板").ok();
        // plan/
        std::fs::create_dir_all(tmp.join("plan/general")).ok();
        std::fs::write(tmp.join("plan/general/creation.md"), "通用创建模板").ok();
        // verify/
        std::fs::create_dir_all(tmp.join("verify/general")).ok();
        // routing/
        std::fs::create_dir_all(tmp.join("routing/general")).ok();

        init(tmp.to_str().unwrap());
    }

    #[test]
    fn test_get_chat_general() {
        test_init();
        let tpl = get_chat("general");
        assert_eq!(tpl.free, "通用聊天模板");
        assert!(tpl.structured.is_empty()); // 未设置
    }

    #[test]
    fn test_get_chat_math() {
        test_init();
        let tpl = get_chat("math");
        assert_eq!(tpl.free, "数学聊天模板");
    }

    #[test]
    fn test_get_chat_unknown_fallback() {
        test_init();
        let tpl = get_chat("history");
        assert_eq!(tpl.free, "通用聊天模板"); // fallback
    }

    #[test]
    fn test_get_concept_general() {
        test_init();
        let tpl = get_concept("general");
        assert_eq!(tpl.extract, "通用提取模板");
    }

    #[test]
    fn test_get_quiz() {
        test_init();
        let tpl = get_quiz("general");
        assert_eq!(tpl.generate, "通用出题模板");
    }

    #[test]
    fn test_get_plan() {
        test_init();
        let tpl = get_plan("general");
        assert_eq!(tpl.creation, "通用创建模板");
    }

    #[test]
    fn test_get_routing() {
        test_init();
        let tpl = get_routing();
        assert!(tpl.subject.is_empty());
    }
}
