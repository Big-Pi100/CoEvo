//! Prompt Loader — 从外部文件加载 prompt 模板
//!
//! 启动时一次性读取 prompts/ 目录下的所有 .md 文件
//! 运行时通过 format! 填充 {变量}

use std::sync::OnceLock;

pub struct PromptTemplates {
    pub chat_system: String,
    /// FREE 状态：无学习计划时的系统提示词（含创建计划引导）
    pub chat_system_free: String,
    /// STRUCTURED 状态：已有学习计划时的系统提示词（含计划遵循、考核、进度更新）
    pub chat_system_structured: String,
    pub concept_extract: String,
    pub card_direct: String,
    pub quiz_generate: String,
    pub quiz_judge: String,
}

static PROMPTS: OnceLock<PromptTemplates> = OnceLock::new();

/// 初始化: 从 prompts 目录加载所有模板
pub fn init(prompts_dir: &str) {
    let templates = PromptTemplates {
        chat_system: read_or_default(&format!("{}/chat_system.md", prompts_dir), ""),
        chat_system_free: read_or_default(&format!("{}/chat_system_free.md", prompts_dir), ""),
        chat_system_structured: read_or_default(&format!("{}/chat_system_structured.md", prompts_dir), ""),
        concept_extract: read_or_default(&format!("{}/concept_extract.md", prompts_dir), ""),
        card_direct: read_or_default(&format!("{}/card_direct.md", prompts_dir), ""),
        quiz_generate: read_or_default(&format!("{}/quiz_generate.md", prompts_dir), ""),
        quiz_judge: read_or_default(&format!("{}/quiz_judge.md", prompts_dir), ""),
    };
    let _ = PROMPTS.set(templates);
}

/// 获取加载的 prompt 模板
pub fn get() -> &'static PromptTemplates {
    PROMPTS.get().expect("Prompts not initialized — call init() first")
}

/// 构建概念提取 prompt（含上下文注入，避免重复提取）
///
/// - `text`: AI 回复文本
/// - `existing_concepts`: 已提取/跳过的概念 front 列表
/// - `context_turns`: 最近 N 轮对话 (role, content)
pub fn build_concept_extract(
    text: &str,
    existing_concepts: &[String],
    context_turns: &[(String, String)],
) -> String {
    let tpl = &get().concept_extract;

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

fn read_or_default(path: &str, default: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|_| {
        tracing::warn!("Prompt file not found: {} (using default)", path);
        default.to_string()
    })
}
