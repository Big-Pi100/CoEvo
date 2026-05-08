//! LLM Config holder for api_server routes

use chat_engine::llm_caller::LlmConfig;
use std::sync::OnceLock;

static LLM_CONFIG: OnceLock<LlmConfig> = OnceLock::new();

pub fn init(config: LlmConfig) {
    let _ = LLM_CONFIG.set(config);
}

pub fn get_config() -> LlmConfig {
    LLM_CONFIG.get().cloned().unwrap_or_else(|| {
        // Fallback: load from env
        chat_engine::config::load_llm_config()
    })
}
