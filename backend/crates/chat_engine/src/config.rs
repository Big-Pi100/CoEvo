//! CoEvo — Configuration
//!
//! Loads LLM configuration from environment variables.
//! Pattern: copied from LinguaFlow conversation_engine/src/config.rs

use crate::llm_caller::LlmConfig;
use std::sync::OnceLock;

static DB_PATH: OnceLock<String> = OnceLock::new();

/// Ensure DB path is registered for chat_engine's internal use.
/// Called once at startup with the server's resolved db_path.
pub fn ensure_db_connection(db_path: &str) {
    let _ = DB_PATH.set(db_path.to_string());
}

pub fn db_path() -> &'static str {
    DB_PATH.get().map(|s| s.as_str()).unwrap_or("data/coevo.db")
}

/// Load LLM config from environment variables.
/// Pattern: same as LinguaFlow
pub fn load_llm_config() -> LlmConfig {
    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .or_else(|_| std::env::var("LLM_API_KEY"))
        .unwrap_or_else(|_| {
            tracing::warn!("No DEEPSEEK_API_KEY/LLM_API_KEY set — using empty key");
            String::new()
        });

    let base_url = std::env::var("LLM_BASE_URL")
        .unwrap_or_else(|_| "https://api.deepseek.com".to_string());

    let model = std::env::var("LLM_MODEL")
        .unwrap_or_else(|_| "deepseek-v4-flash".to_string());

    LlmConfig {
        api_key,
        base_url,
        model,
        max_tokens: 65536,
        temperature: 0.7,
    }
}
