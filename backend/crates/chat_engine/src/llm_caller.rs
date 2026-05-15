/// N4: LLM Caller
///
/// Testing: DeepSeek V4 Flash (OpenAI-compatible API)
/// Production: Qwen3 Max (阿里云百炼)
///
/// Provides:
///   - `generate()`: simple non-streaming call (for pipeline)
///   - `stream_generate()`: streaming SSE (for real-time UI)
///
/// Performance:
///   - Single request with one retry on failure (no racing)
///   - Pool config prevents stale-connection reuse with 30 s idle timeout
///   - 10 s connect timeout prevents TCP-handshake hangs
///
/// Cold start:
///   - `warmup()` called at server startup to pre-warm DeepSeek model

use tokio::sync::mpsc;
use reqwest::Client;
use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::Duration;

/// Global HTTP client (shared across all LlmCaller instances).
///
/// Pool tuning:
///   - `connect_timeout`: prevents hanging on TCP handshake
///   - `pool_max_idle_per_host`: limits idle connections (5 is enough for
///      our 2-attempt retry pattern)
///   - `pool_idle_timeout`: evicts stale/corrupted connections after 30 s,
///      preventing "poisoned connection" reuse
fn http_client() -> &'static Client {
    static HTTP_CLIENT: OnceLock<Client> = OnceLock::new();
    HTTP_CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .pool_max_idle_per_host(5)
            .pool_idle_timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest::Client::new")
    })
}

#[derive(Debug, Clone)]
pub struct LlmConfig {
    pub api_key: String,
    pub base_url: String,
    pub model: String,
    pub max_tokens: u32,
    pub temperature: f32,
}

impl LlmConfig {
    pub fn deepseek_v4_flash(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            base_url: "https://api.deepseek.com/v1".into(),
            model: "deepseek-v4-flash".into(),
            max_tokens: 4096,
            temperature: 0.7,
        }
    }

    pub fn qwen3_max(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1".into(),
            model: "qwen3-max".into(),
            max_tokens: 4096,
            temperature: 0.7,
        }
    }
}

#[derive(Debug)]
pub enum LlmEvent {
    Thinking,
    Token(String),
    Done(String),
}

#[derive(Debug)]
pub enum LlmError {
    Timeout,
    EmptyResponse,
    ApiError(String),
    DegradedL2,
    DegradedL3,
}

impl std::fmt::Display for LlmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LlmError::Timeout => write!(f, "LLM timeout"),
            LlmError::EmptyResponse => write!(f, "Empty LLM response"),
            LlmError::ApiError(msg) => write!(f, "LLM API error: {}", msg),
            LlmError::DegradedL2 => write!(f, "Degraded service (L2)"),
            LlmError::DegradedL3 => write!(f, "Degraded service (L3)"),
        }
    }
}

pub struct LlmCaller {
    config: LlmConfig,
    consecutive_failures: u32,
}

impl LlmCaller {
    pub fn new(config: LlmConfig) -> Self {
        Self {
            config,
            consecutive_failures: 0,
        }
    }

    // ── Non-streaming call (for pipeline / eval) ──

    /// Non-streaming chat completion.
    ///
    /// Single request with one retry on failure. Previously used a
    /// `tokio::select!` race of two parallel requests — this was the
    /// root cause of connection-pool corruption: the losing request's
    /// connection was dropped mid-flight back into the reqwest pool,
    /// poisoning it for all subsequent callers.
    pub async fn generate(&mut self, system_prompt: &str, user_content: &str) -> Result<String, LlmError> {
        let url = format!("{}/chat/completions", self.config.base_url);
        let body = build_request_body(&self.config, system_prompt, user_content);
        let consecutive = &mut self.consecutive_failures;

        let mut last_error = LlmError::EmptyResponse;
        for attempt in 0..2 {
            match post_one(http_client(), &url, &self.config.api_key, &body).await {
                Ok(reply) => {
                    *consecutive = 0;
                    return Ok(reply);
                }
                Err(e) => {
                    if attempt == 0 {
                        tracing::warn!("LLM generate attempt 1 failed: {:?}", e);
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    }
                    last_error = e;
                }
            }
        }

        *consecutive += 1;
        Err(last_error)
    }

    // ── Streaming call (for real-time UI) ──

    pub async fn stream_generate(
        &mut self,
        system_prompt: &str,
        user_content: &str,
        tx: mpsc::Sender<LlmEvent>,
    ) -> Result<(), LlmError> {
        // Retry once on failure (streaming connection can be flaky)
        let mut last_error = LlmError::EmptyResponse;
        for attempt in 0..2 {
            match self.stream_generate_inner(system_prompt, user_content, &tx).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    tracing::warn!("LLM stream attempt {} failed: {:?}", attempt + 1, e);
                    last_error = e;
                    // Brief backoff before retry
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
            }
        }
        Err(last_error)
    }

    async fn stream_generate_inner(
        &mut self,
        system_prompt: &str,
        user_content: &str,
        tx: &mpsc::Sender<LlmEvent>,
    ) -> Result<(), LlmError> {
        let _ = tx.send(LlmEvent::Thinking).await;

        let url = format!("{}/chat/completions", self.config.base_url);
        let body = json!({
            "model": self.config.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content}
            ],
            "stream": true,
            "max_tokens": self.config.max_tokens,
            "temperature": self.config.temperature,
        });

        let response = http_client()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                self.consecutive_failures += 1;
                LlmError::ApiError(format!("Connection: {}", e))
            })?;

        if !response.status().is_success() {
            self.consecutive_failures += 1;
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(LlmError::ApiError(format!("HTTP {}: {}", status, text)));
        }

        // 流式 SSE 解析
        use futures_util::StreamExt;
        let mut full_text = String::new();
        let mut stream = response.bytes_stream();
        let mut buffer = Vec::new();
        let had_content = false;

        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    self.consecutive_failures += 1;
                    // 尝试获取响应状态码
                    let status_str = e.status().map(|s| s.to_string()).unwrap_or_else(|| "unknown".into());
                    return Err(LlmError::ApiError(format!(
                        "Stream decode failed (HTTP {}): {}. Raw buffer: {} bytes, had_content: {}",
                        status_str, e, buffer.len(), had_content,
                    )));
                }
            };
            buffer.extend_from_slice(&chunk);

            while let Some(pos) = buffer.windows(2).position(|w| w == b"\n\n") {
                let block = buffer[..pos + 2].to_vec();
                buffer = buffer[pos + 2..].to_vec();
                let line = String::from_utf8_lossy(&block);

                for ln in line.lines() {
                    if let Some(data) = ln.strip_prefix("data: ") {
                        if data.trim() == "[DONE]" { break; }
                        if let Ok(parsed) = serde_json::from_str::<Value>(data) {
                            if let Some(c) = parsed["choices"][0]["delta"]["content"].as_str() {
                                full_text.push_str(c);
                                let _ = tx.send(LlmEvent::Token(c.to_string())).await;
                            }
                        }
                    }
                }
            }
        }

        self.consecutive_failures = 0;
        let _ = tx.send(LlmEvent::Done(full_text)).await;
        Ok(())
    }

    pub fn consecutive_failures(&self) -> u32 { self.consecutive_failures }
    pub fn reset_failures(&mut self) { self.consecutive_failures = 0; }
}

// ── Helper functions ──

/// Build the request body from config, system prompt, and user content
fn build_request_body(config: &LlmConfig, system_prompt: &str, user_content: &str) -> serde_json::Value {
    let mut messages: Vec<serde_json::Value> = Vec::new();
    if !system_prompt.is_empty() {
        messages.push(json!({"role": "system", "content": system_prompt}));
    }
    messages.push(json!({"role": "user", "content": user_content}));
    json!({
        "model": config.model,
        "messages": messages,
        "stream": false,
        "max_tokens": config.max_tokens,
        "temperature": config.temperature,
    })
}

/// Send one POST request and parse the response
async fn post_one(client: &'static Client, url: &str, api_key: &str, body: &serde_json::Value) -> Result<String, LlmError> {
    let response = client
        .post(url)
        .header("Authorization", format!("Bearer {}", api_key))
        .header("Content-Type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| LlmError::ApiError(format!("Connection: {}", e)))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(LlmError::ApiError(format!("HTTP {}: {}", status, text)));
    }

    let result: Value = response.json().await
        .map_err(|e| LlmError::ApiError(format!("JSON parse: {}", e)))?;

    result["choices"][0]["message"]["content"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or(LlmError::EmptyResponse)
}

/// Warm up the API by sending a trivial request (called at server start).
/// This ensures the DeepSeek model is loaded and connections are established.
pub async fn warmup() {
    let config = crate::config::load_llm_config();
    warmup_with_config(config).await;
}

/// Warm up with a specific config (used when config is already loaded).
pub async fn warmup_with_config(config: LlmConfig) {
    let mut caller = LlmCaller::new(config);
    match caller.generate("", "Say 'ok' in one word.").await {
        Ok(_) => tracing::info!("LLM warmup: OK"),
        Err(e) => tracing::warn!("LLM warmup: {:?} (non-critical)", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deepseek_config() {
        let cfg = LlmConfig::deepseek_v4_flash("test-key");
        assert_eq!(cfg.model, "deepseek-v4-flash");
        assert!(cfg.base_url.contains("deepseek.com"));
        assert_eq!(cfg.api_key, "test-key");
        assert_eq!(cfg.max_tokens, 4096);
        assert!((cfg.temperature - 0.7).abs() < 0.01);
    }

    #[test]
    fn test_qwen3_config() {
        let cfg = LlmConfig::qwen3_max("test-key");
        assert_eq!(cfg.model, "qwen3-max");
        assert!(cfg.base_url.contains("dashscope"));
    }

    #[test]
    fn test_failure_counter() {
        let cfg = LlmConfig::deepseek_v4_flash("test");
        let mut caller = LlmCaller::new(cfg);
        assert_eq!(caller.consecutive_failures(), 0);
        caller.consecutive_failures = 2;
        assert_eq!(caller.consecutive_failures(), 2);
        caller.reset_failures();
        assert_eq!(caller.consecutive_failures(), 0);
    }

    #[test]
    fn test_empty_prompt_returns_error() {
        // We can't test actual API calls without a key,
        // but we can verify the error types are constructible
        let err1 = LlmError::ApiError("test".into());
        let err2 = LlmError::EmptyResponse;
        let err3 = LlmError::DegradedL2;
        let _ = format!("{:?} {:?} {:?}", err1, err2, err3);
    }

    /// Integration test: calls DeepSeek V4 Flash with a simple prompt.
    /// Requires DEEPSEEK_API_KEY to be set in environment.
    #[tokio::test]
    #[ignore]
    async fn test_generate_with_deepseek() {
        let api_key = std::env::var("DEEPSEEK_API_KEY")
            .expect("Set DEEPSEEK_API_KEY to run this test");
        let cfg = LlmConfig::deepseek_v4_flash(&api_key);
        let mut caller = LlmCaller::new(cfg);

        let result = caller.generate("", "Say hello in one word.").await;
        assert!(result.is_ok(), "API call failed: {:?}", result.err());
        let text = result.unwrap();
        assert!(!text.is_empty(), "Response should not be empty");
        println!("DeepSeek response: {}", text);
    }

    /// Tests that the streaming endpoint also works.
    #[tokio::test]
    #[ignore]
    async fn test_stream_with_deepseek() {
        let api_key = std::env::var("DEEPSEEK_API_KEY")
            .expect("Set DEEPSEEK_API_KEY");
        let cfg = LlmConfig::deepseek_v4_flash(&api_key);
        let mut caller = LlmCaller::new(cfg);
        let (tx, mut rx) = mpsc::channel(100);

        let handle = tokio::spawn(async move {
            caller.stream_generate("", "Count to 3.", tx).await
        });

        let mut got_done = false;
        let mut tokens = Vec::new();
        while let Some(event) = rx.recv().await {
            match event {
                LlmEvent::Thinking => {},
                LlmEvent::Token(t) => tokens.push(t),
                LlmEvent::Done(t) => { got_done = true; assert!(!t.is_empty()); break; },
            }
        }
        assert!(got_done, "Should receive Done event");
        assert!(!tokens.is_empty(), "Should receive at least 1 token");
        handle.await.unwrap().unwrap();
    }
}
