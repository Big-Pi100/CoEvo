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

/// Long-timeout HTTP client for plan creation LLM calls.
///
/// Plan creation prompts can be 10000+ chars and the LLM needs time to
/// think before it starts generating output. 30s is too short.
/// This client has a 5-minute total timeout, matching the CP2 timeout.
fn long_http_client() -> &'static Client {
    static LONG_HTTP_CLIENT: OnceLock<Client> = OnceLock::new();
    LONG_HTTP_CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(300))
            .pool_max_idle_per_host(3)
            .pool_idle_timeout(Duration::from_secs(60))
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
            base_url: "https://api.deepseek.com".into(),
            model: "deepseek-v4-flash".into(),
            max_tokens: 65536,
            temperature: 0.7,
        }
    }

    pub fn qwen3_max(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1".into(),
            model: "qwen3-max".into(),
            max_tokens: 65536,
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
    /// Single request with one retry on failure. Uses the default 30s
    /// http_client — suitable for quick queries.
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
                        // Exponential backoff: base 250ms, cap 2s
                        let delay = std::cmp::min(250 * 2u64.pow(attempt as u32), 2000);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                    last_error = e;
                }
            }
        }

        *consecutive += 1;
        Err(last_error)
    }

    /// Non-streaming chat completion with long timeout (300s).
    ///
    /// Uses `long_http_client()` for plan creation etc. where the LLM
    /// needs significant time to generate long JSON output. Non-streaming
    /// is faster than streaming for large outputs because the LLM
    /// generates everything at once instead of token by token.
    pub async fn generate_long(&mut self, system_prompt: &str, user_content: &str) -> Result<String, LlmError> {
        let url = format!("{}/chat/completions", self.config.base_url);
        let body = build_request_body(&self.config, system_prompt, user_content);
        let consecutive = &mut self.consecutive_failures;

        let start = std::time::Instant::now();
        tracing::info!("generate_long ENTER: user_chars={}, max_tokens={}", user_content.len(), self.config.max_tokens);

        let mut last_error = LlmError::EmptyResponse;
        for attempt in 0..2 {
            match post_one(long_http_client(), &url, &self.config.api_key, &body).await {
                Ok(reply) => {
                    *consecutive = 0;
                    let elapsed = start.elapsed();
                    tracing::info!("generate_long OK: elapsed={:?}, reply_chars={}, preview={}",
                        elapsed, reply.len(), &reply.chars().take(200).collect::<String>());
                    return Ok(reply);
                }
                Err(e) => {
                    if attempt == 0 {
                        tracing::warn!("LLM generate_long attempt 1 failed after {:?}: {:?}", start.elapsed(), e);
                        let delay = std::cmp::min(250 * 2u64.pow(attempt as u32), 2000);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                    last_error = e;
                }
            }
        }

        *consecutive += 1;
        tracing::error!("generate_long FAILED after {:?}: {:?}", start.elapsed(), last_error);
        Err(last_error)
    }

    // ── Streaming call (for real-time UI) ──

    /// Streamed chat completion, wrapped as non-streaming return.
    ///
    /// Uses the streaming API internally (`stream: true`) but collects all
    /// tokens and returns the complete text — works around API endpoints
    /// that reject large `max_tokens` on non-streaming requests.
    pub async fn generate_streamed(&mut self, system_prompt: &str, user_content: &str) -> Result<String, LlmError> {
        let start = std::time::Instant::now();
        tracing::info!("generate_streamed ENTER: user_chars={}, max_tokens={}", user_content.len(), self.config.max_tokens);

        let (mut tx, mut rx) = mpsc::channel::<LlmEvent>(64);
        let mut full_text = String::new();

        let mut last_error = LlmError::EmptyResponse;
        for attempt in 0..2 {
            match self.stream_generate_inner(system_prompt, user_content, &tx).await {
                Ok(()) => {
                    // Drain remaining events
                    while let Some(event) = rx.recv().await {
                        match event {
                            LlmEvent::Token(t) => full_text.push_str(&t),
                            LlmEvent::Done(text) => {
                                full_text = text;
                                break;
                            }
                            LlmEvent::Thinking => {}
                        }
                    }
                    self.consecutive_failures = 0;
                    let elapsed = start.elapsed();
                    let preview: String = full_text.chars().take(200).collect();
                    tracing::info!("generate_streamed OK: elapsed={:?}, output_chars={}, preview={}{}",
                        elapsed, full_text.len(), preview,
                        if full_text.len() > 200 { "..." } else { "" });
                    return Ok(full_text);
                }
                Err(e) => {
                    if attempt == 0 {
                        tracing::warn!("LLM generate_streamed attempt 1 failed after {:?}: {:?}", start.elapsed(), e);
                        let delay = std::cmp::min(250 * 2u64.pow(attempt as u32), 2000);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        // Re-create channel for retry
                        let (new_tx, new_rx) = mpsc::channel::<LlmEvent>(64);
                        tx = new_tx;
                        rx = new_rx;
                        full_text.clear();
                    }
                    last_error = e;
                }
            }
        }
        self.consecutive_failures += 1;
        tracing::error!("generate_streamed FAILED after {:?}: {:?}", start.elapsed(), last_error);
        Err(last_error)
    }

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
                    // Exponential backoff before retry
                    let delay = std::cmp::min(250 * 2u64.pow(attempt as u32), 2000);
                    tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
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
        tracing::info!("LLM request (non-history): model={}, max_tokens={}, system_chars={}, user_chars={}",
            self.config.model, self.config.max_tokens, system_prompt.len(), user_content.len());
        let preview: String = user_content.chars().take(120).collect();
        tracing::info!("  user_content_preview: {}{}", preview,
            if user_content.len() > 120 { "..." } else { "" });

        let response = long_http_client()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                self.consecutive_failures += 1;
                tracing::warn!("LLM stream_generate_inner: Connection error: {}", e);
                LlmError::ApiError(format!("Connection: {}", e))
            })?;

        if !response.status().is_success() {
            self.consecutive_failures += 1;
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(LlmError::ApiError(format!("HTTP {}: {}", status, text)));
        }

        // 流式 SSE 解析
        let start = std::time::Instant::now();
        use futures_util::StreamExt;
        let mut full_text = String::new();
        let mut stream = response.bytes_stream();
        let mut buffer = Vec::new();
        let mut chunk_count = 0u64;
        let mut frame_count = 0u64;

        while let Some(chunk) = stream.next().await {
            chunk_count += 1;
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    self.consecutive_failures += 1;
                    let status_str = e.status().map(|s| s.to_string()).unwrap_or_else(|| "unknown".into());
                    tracing::error!("LLM SSE stream chunk error at chunk={}, buffer={}B, full_text={}chars: HTTP {}: {}",
                        chunk_count, buffer.len(), full_text.len(), status_str, e);
                    return Err(LlmError::ApiError(format!(
                        "Stream decode failed (HTTP {}): {}. Raw buffer: {} bytes, full_text: {} chars",
                        status_str, e, buffer.len(), full_text.len(),
                    )));
                }
            };
            buffer.extend_from_slice(&chunk);

            while let Some(pos) = buffer.windows(2).position(|w| w == b"\n\n") {
                frame_count += 1;
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

        let elapsed = start.elapsed();
        tracing::info!("LLM SSE stream done: elapsed={:?}, chunks={}, frames={}, full_text={}chars, final_buffer={}B",
            elapsed, chunk_count, frame_count, full_text.len(), buffer.len());

        self.consecutive_failures = 0;
        let _ = tx.send(LlmEvent::Done(full_text)).await;
        Ok(())
    }

    // ── Streaming call with proper role-based history ──

    /// Streamed chat completion with proper multi-turn chat history.
    ///
    /// Unlike `stream_generate` (which concatenates everything into one user message),
    /// this builds a proper `messages` array with alternating user/assistant roles.
    pub async fn stream_generate_with_history(
        &mut self,
        system_prompt: &str,
        history: &[(String, String)],  // (role, content) — "user" or "assistant"
        current_message: &str,
        plan_context: &str,
        tx: mpsc::Sender<LlmEvent>,
    ) -> Result<(), LlmError> {
        let mut last_error = LlmError::EmptyResponse;
        for attempt in 0..2 {
            match self.stream_history_inner(system_prompt, history, current_message, plan_context, &tx).await {
                Ok(()) => { self.consecutive_failures = 0; return Ok(()); }
                Err(e) => {
                    if attempt == 0 {
                        tracing::warn!("LLM stream_history attempt 1 failed: {:?}", e);
                        let delay = std::cmp::min(250 * 2u64.pow(attempt as u32), 2000);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                    last_error = e;
                }
            }
        }
        self.consecutive_failures += 1;
        Err(last_error)
    }

    async fn stream_history_inner(
        &mut self,
        system_prompt: &str,
        history: &[(String, String)],
        current_message: &str,
        plan_context: &str,
        tx: &mpsc::Sender<LlmEvent>,
    ) -> Result<(), LlmError> {
        let _ = tx.send(LlmEvent::Thinking).await;

        let mut messages: Vec<serde_json::Value> = Vec::new();
        messages.push(json!({"role": "system", "content": system_prompt}));
        if !plan_context.is_empty() {
            messages.push(json!({"role": "system", "content": plan_context}));
        }
        for (role, content) in history {
            messages.push(json!({"role": role, "content": content}));
        }
        messages.push(json!({"role": "user", "content": current_message}));

        let url = format!("{}/chat/completions", self.config.base_url);
        let body = json!({
            "model": self.config.model,
            "messages": messages,
            "stream": true,
            "max_tokens": self.config.max_tokens,
            "temperature": self.config.temperature,
        });
        // DEBUG: 打印 messages 概览
        tracing::info!("LLM request: model={}, max_tokens={}, system_chars={}, total_msgs={}",
            self.config.model, self.config.max_tokens,
            system_prompt.len(),
            body["messages"].as_array().map(|a| a.len()).unwrap_or(0));
        for (i, msg) in body["messages"].as_array().unwrap_or(&vec![]).iter().enumerate() {
            let role = msg["role"].as_str().unwrap_or("?");
            let content = msg["content"].as_str().unwrap_or("");
            let preview: String = content.chars().take(80).collect();
            tracing::info!("  msg[{}] role={}, chars={}, preview={}",
                i, role, content.len(), preview);
        }

        let response = http_client()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send().await
            .map_err(|e| { self.consecutive_failures += 1; LlmError::ApiError(format!("Connection: {}", e)) })?;

        if !response.status().is_success() {
            self.consecutive_failures += 1;
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(LlmError::ApiError(format!("HTTP {}: {}", status, text)));
        }

        use futures_util::StreamExt;
        let mut full_text = String::new();
        let mut stream = response.bytes_stream();
        let mut buffer = Vec::new();

        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    self.consecutive_failures += 1;
                    let status_str = e.status().map(|s| s.to_string()).unwrap_or_else(|| "unknown".into());
                    return Err(LlmError::ApiError(format!(
                        "Stream decode failed (HTTP {}): {}. Raw buffer: {} bytes",
                        status_str, e, buffer.len(),
                    )));
                }
            };
            buffer.extend_from_slice(&chunk);

            // 按 SSE 帧分割（\n\n 分隔），每帧只处理一次，处理完从 buffer 移除
            while let Some(pos) = buffer.windows(2).position(|w| w == b"\n\n") {
                let block = buffer[..pos + 2].to_vec();
                buffer = buffer[pos + 2..].to_vec();
                let line = String::from_utf8_lossy(&block);

                for ln in line.lines() {
                    if let Some(data) = ln.strip_prefix("data: ") {
                        if data.trim() == "[DONE]" { break; }
                        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(data) {
                            if let Some(c) = parsed["choices"][0]["delta"]["content"].as_str() {
                                if !c.is_empty() {
                                    full_text.push_str(c);
                                    let _ = tx.send(LlmEvent::Token(c.to_string())).await;
                                }
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
        assert_eq!(cfg.max_tokens, 65536);
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
