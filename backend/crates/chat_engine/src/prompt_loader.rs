//! Prompt Loader — 从外部文件加载 prompt 模板
//!
//! 支持管线式加载：
//! - init() 加载通用管线 prompts/ + 所有已注册管线的 prompts
//! - get(domain) 按 domain 获取对应 PromptTemplates，找不到回退通用
//!
//! 设计原则：
//! - 管线目录里的文件不要求全，不存在的文件自动回退到通用管线
//! - 新增管线只需建目录 + 写要改的文件 + 注册

use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Clone, Debug)]
pub struct PromptTemplates {
    pub chat_system: String,
    pub chat_system_free: String,
    pub chat_system_structured: String,
    pub concept_extract: String,
    pub card_direct: String,
    pub quiz_generate: String,
    pub quiz_judge: String,
}

impl Default for PromptTemplates {
    fn default() -> Self {
        Self {
            chat_system: String::new(),
            chat_system_free: String::new(),
            chat_system_structured: String::new(),
            concept_extract: String::new(),
            card_direct: String::new(),
            quiz_generate: String::new(),
            quiz_judge: String::new(),
        }
    }
}

/// 管线注册表
struct PromptRegistry {
    /// 通用管线（兜底）
    general: PromptTemplates,
    /// 场景管线 key=domain
    pipelines: HashMap<String, PromptTemplates>,
}

static REGISTRY: OnceLock<PromptRegistry> = OnceLock::new();

/// 初始化: 加载通用管线 + 所有已注册管线
///
/// `prompts_dir`: 通用 prompt 目录 (如 "prompts/")
/// `pipelines_base`: 管线基目录 (如 "pipelines/")
pub fn init(prompts_dir: &str, pipelines_base: &str) {
    let general = load_pipeline_dir(prompts_dir);
    tracing::info!("General prompts loaded from: {}", prompts_dir);

    let mut pipelines: HashMap<String, PromptTemplates> = HashMap::new();

    // 加载已注册管线
    for domain in &["math", "language"] {
        let dir = format!("{}/{}/prompts", pipelines_base, domain);
        let tpl = load_pipeline_dir_with_fallback(&dir, &general);
        let fallback_info = if std::path::Path::new(&dir).exists() { " (custom)" } else { " (fallback to general)" };
        tracing::info!("Pipeline [{}] loaded from: {}{}", domain, dir, fallback_info);
        pipelines.insert(domain.to_string(), tpl);
    }

    let registry = PromptRegistry { general, pipelines };
    let _ = REGISTRY.set(registry);
}

/// 加载单个目录，文件不存在时使用空字符串
fn load_pipeline_dir(dir: &str) -> PromptTemplates {
    PromptTemplates {
        chat_system: read_file(&format!("{}/chat_system.md", dir)),
        chat_system_free: read_file(&format!("{}/chat_system_free.md", dir)),
        chat_system_structured: read_file(&format!("{}/chat_system_structured.md", dir)),
        concept_extract: read_file(&format!("{}/concept_extract.md", dir)),
        card_direct: read_file(&format!("{}/card_direct.md", dir)),
        quiz_generate: read_file(&format!("{}/quiz_generate.md", dir)),
        quiz_judge: read_file(&format!("{}/quiz_judge.md", dir)),
    }
}

/// 加载单个目录，文件不存在时回退到 fallback 管线的对应字段
fn load_pipeline_dir_with_fallback(dir: &str, fallback: &PromptTemplates) -> PromptTemplates {
    PromptTemplates {
        chat_system: read_file_with_alt(&format!("{}/chat_system.md", dir), &fallback.chat_system),
        chat_system_free: read_file_with_alt(&format!("{}/chat_system_free.md", dir), &fallback.chat_system_free),
        chat_system_structured: read_file_with_alt(&format!("{}/chat_system_structured.md", dir), &fallback.chat_system_structured),
        concept_extract: read_file_with_alt(&format!("{}/concept_extract.md", dir), &fallback.concept_extract),
        card_direct: read_file_with_alt(&format!("{}/card_direct.md", dir), &fallback.card_direct),
        quiz_generate: read_file_with_alt(&format!("{}/quiz_generate.md", dir), &fallback.quiz_generate),
        quiz_judge: read_file_with_alt(&format!("{}/quiz_judge.md", dir), &fallback.quiz_judge),
    }
}

/// 读取文件，不存在时返回 alt 默认值
fn read_file_with_alt(path: &str, alt: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|_| alt.to_string())
}

fn read_file(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// 获取通用管线的 prompt（无参，后向兼容）
pub fn get() -> &'static PromptTemplates {
    let registry = REGISTRY.get().expect("Prompts not initialized — call init() first");
    &registry.general
}

/// 获取指定管线的 prompt 模板
///
/// - domain = "" 或 "general" → 通用兜底
/// - domain = "math" → 数学管线
/// - domain = "language" → 语言管线
/// - 未知 domain → 通用兜底
pub fn get_for_domain(domain: &str) -> &'static PromptTemplates {
    let registry = REGISTRY.get().expect("Prompts not initialized — call init() first");

    if domain.is_empty() || domain == "general" {
        return &registry.general;
    }

    registry.pipelines.get(domain).unwrap_or(&registry.general)
}

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
    let tpl = &get_for_domain(domain).concept_extract;

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

    if tpl.is_empty() {
        // 降级为硬编码
        format!(
            "从以下文本中提取值得记住的知识点，最多5个。返回JSON数组。\n\n已有概念:\n{}\n\n{}",
            concepts_str, text
        )
    } else {
        tpl.replace("{text}", text)
            .replace("{existing_concepts_list}", &concepts_str)
            .replace("{conversation_history}", &history_str)
    }
}

/// 构建直接制卡 prompt
pub fn build_card_direct(user_message: &str, ai_reply: &str) -> String {
    let tpl = &get().card_direct;
    if tpl.is_empty() {
        format!("Generate a flashcard from this conversation.\nUser: {}\nAI: {}", user_message, ai_reply)
    } else {
        tpl.replace("{user_message}", user_message)
           .replace("{ai_reply}", ai_reply)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 仅用于测试的初始化
    fn test_init() {
        // 用临时目录模拟管线目录结构
        let tmp = std::env::temp_dir().join("coevo_prompt_test");
        let _ = std::fs::create_dir_all(tmp.join("pipelines/math/prompts"));
        let _ = std::fs::create_dir_all(tmp.join("pipelines/language/prompts"));

        // 写通用 prompt
        std::fs::write(tmp.join("concept_extract.md"), "通用提取模板").ok();
        // 写 math 专用 prompt
        std::fs::write(tmp.join("pipelines/math/prompts/concept_extract.md"), "数学提取模板").ok();
        // language 无专用 prompt（测试回退）

        let prompts_dir = tmp.to_str().unwrap().to_string();
        let pipelines_base = format!("{}/pipelines", prompts_dir);
        init(&prompts_dir, &pipelines_base);
    }

    #[test]
    fn test_get_general() {
        test_init();
        let tpl = get_for_domain("general");
        assert_eq!(tpl.concept_extract, "通用提取模板");
    }

    #[test]
    fn test_get_math() {
        test_init();
        let tpl = get_for_domain("math");
        assert_eq!(tpl.concept_extract, "数学提取模板");
    }

    #[test]
    fn test_get_language_fallback() {
        test_init();
        let tpl = get_for_domain("language");
        // language 没有专用 prompt，应回退到通用
        assert_eq!(tpl.concept_extract, "通用提取模板");
    }

    #[test]
    fn test_get_unknown_domain() {
        test_init();
        let tpl = get_for_domain("history");
        assert_eq!(tpl.concept_extract, "通用提取模板");
    }
}
