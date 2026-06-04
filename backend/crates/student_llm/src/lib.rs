//! 学生 LLM 模拟器
//!
//! 供 E2E 测试使用，模拟真实学生与 AI 老师对话。
//! prompt 文件位于 `prompts/student/default.md`，使用 include_str! 编译嵌入。

/// 学生默认系统提示词（编译嵌入）
pub const DEFAULT_PROMPT: &str = include_str!("../../../prompts/student/default.md");

/// 学生 LLM 生成自然回复（含最多 3 次自动重试）
///
/// # Arguments
/// * `caller` - LLM 调用器
/// * `prompt` - 学生系统提示词（通常用 `DEFAULT_PROMPT`）
/// * `history` - 对话历史（用户消息 + 教师回复的完整文本）
pub async fn student_speak(
    caller: &mut chat_engine::llm_caller::LlmCaller,
    prompt: &str,
    history: &str,
) -> String {
    let max_retries = 3;
    for attempt in 0..max_retries {
        match caller.generate(prompt, history).await {
            Ok(reply) => {
                let trimmed = reply.trim().to_string();
                if !trimmed.is_empty() {
                    return trimmed;
                }
                eprintln!("student_speak: empty response on attempt {}", attempt + 1);
            }
            Err(e) => {
                eprintln!("student_speak: LLM error on attempt {}: {:?}", attempt + 1, e);
            }
        }
        if attempt < max_retries - 1 {
            // 指数退避：1s, 2s
            std::thread::sleep(std::time::Duration::from_secs(1 << attempt));
        }
    }
    eprintln!("student_speak: all {} attempts failed, returning empty", max_retries);
    String::new()
}
