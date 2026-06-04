//! E2E WebSocket 路径验证测试（纯 WS，不依赖 REST chat）
//!
//! 覆盖:
//!   1. WS 握手 → 发送 ChatRequest → 接收事件流
//!   2. 验证收到 thinking / token / done 事件
//!   3. 验证 done 事件的 reply 非空
//!   4. 关闭连接
//!
//! 不依赖 student_llm 模拟 — 发一条固定消息即可触发流式回复

use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "wsuser";
const TEST_PASS: &str = "wspass123";
const TEST_CONV: &str = "ws-test-conv";

static INIT: OnceLock<()> = OnceLock::new();

/// 启动 API server 并返回 base URL
async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }

    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });

    let db_path = format!("data/test_ws_{}.db", chrono::Utc::now().timestamp());
    let _ = std::fs::remove_file(&db_path);
    api_server::db_pool::init(&db_path).expect("init db");

    let conn = api_server::db_pool::get_conn();
    let sql = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/schema.sql"));
    conn.execute_batch(&sql).expect("schema init");
    conn.execute_batch("
        CREATE TABLE IF NOT EXISTS user_preferences (
            user_id TEXT NOT NULL, key TEXT NOT NULL,
            value TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, key),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );"
    ).expect("user_preferences table");

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);

    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    base
}

/// 解析响应 body 为 JSON
async fn body_json(resp: reqwest::Response) -> Value {
    resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
}

#[tokio::test]
#[ignore]
async fn e2e_ws_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🌐 WS E2E test – WebSocket messaging lifecycle");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Register ──
    println!("\n--- Step 1: Register ---");
    let resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await.unwrap();
    let reg: Value = body_json(resp).await;
    calls += 1;
    let uid = reg["user_id"].as_str().expect("register should return user_id")
        .to_string();
    println!("  uid: {}", uid);

    // ── Step 2: Login (get token) ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let token = login["token"].as_str().expect("login should return token")
        .to_string();
    println!("  token: {}...", &token[..16]);

    // ── Step 3: Subscription (通过 preferences API) ──
    println!("\n--- Step 3: Subscription ---");
    let expires = format!("{}T00:00:00Z",
        (chrono::Utc::now() + chrono::Duration::days(30)).format("%Y-%m-%d"));
    let resp = client.put(format!("{}/api/user/{}/preferences", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"subscription_expires": expires}))
        .send().await.unwrap();
    println!("  subscription: {:?}", resp.status());

    // ── Step 4: WS 连接 + 消息收发 ──
    println!("\n--- Step 4: WebSocket ---");
    let ws_url = base.replace("http", "ws");
    println!("  connecting to: {}/ws", ws_url);

    let (ws_stream, _) = tokio_tungstenite::connect_async(format!("{}/ws", ws_url)).await
        .expect("WS connect should succeed");
    println!("  connected ✅");
    calls += 1;

    let (mut write, read) = ws_stream.split();

    // 发送 ChatRequest
    let chat_req = json!({
        "user_id": uid,
        "conversation_id": TEST_CONV,
        "message": "Hello, please tell me about the Pythagorean theorem.",
        "token": token,
    }).to_string();
    use futures_util::SinkExt;
    write.send(tokio_tungstenite::tungstenite::Message::Text(chat_req.into())).await
        .expect("WS send should succeed");
    println!("  sent message ✅");

    use futures_util::StreamExt;
    use tokio::time::Duration;

    // 收集事件，验证协议
    let mut got_thinking = false;
    let mut got_token = false;
    let mut got_done = false;
    let mut done_reply: String = String::new();
    let mut event_count = 0u32;

    let timeout = Duration::from_secs(90);
    let result = tokio::time::timeout(timeout, async {
        let mut read = read;
        while let Some(msg) = read.next().await {
            event_count += 1;
            let text = match msg {
                Ok(tokio_tungstenite::tungstenite::Message::Text(t)) => t,
                Ok(tokio_tungstenite::tungstenite::Message::Ping(_)) => continue,
                Ok(tokio_tungstenite::tungstenite::Message::Pong(_)) => continue,
                Ok(tokio_tungstenite::tungstenite::Message::Close(_)) => break,
                _ => { continue; }
            };

            let event: Value = serde_json::from_str(&text).unwrap_or_default();
            let event_type = event["type"].as_str().unwrap_or("?");

            match event_type {
                "thinking" => {
                    got_thinking = true;
                    println!("  event {}: thinking", event_count);
                }
                "token" => {
                    got_token = true;
                    let content = event["content"].as_str().unwrap_or("");
                    if event_count <= 3 {
                        println!("  event {}: token ({} chars)", event_count, content.len());
                    }
                }
                "done" => {
                    got_done = true;
                    done_reply = event["reply"].as_str().unwrap_or("").to_string();
                    println!("  event {}: done! reply={} chars", event_count, done_reply.len());
                    let candidates = event["candidates"].as_array();
                    if let Some(c) = candidates {
                        println!("    candidates: {}", c.len());
                    }
                    break; // done 是最后一个事件
                }
                "error" => {
                    let err = event["content"].as_str().unwrap_or("?");
                    panic!("WS error event: {}", err);
                }
                "plan_updated" => {
                    println!("  event {}: plan_updated", event_count);
                }
                _ => {
                    println!("  event {}: unknown type={}", event_count, event_type);
                }
            }
        }
    }).await;

    match result {
        Ok(()) => {
            println!("\n  WS events received: {}", event_count);
            assert!(got_thinking, "should receive 'thinking' event");
            assert!(got_done, "should receive 'done' event");
            assert!(!done_reply.is_empty(), "done reply should be non-empty");
            assert!(done_reply.len() > 20, "done reply should be substantial (>20 chars)");
            println!("  ✅ WS protocol verified: thinking + done(reply={} chars)", done_reply.len());
        }
        Err(_) => {
            panic!("WS test timed out after {}s — got events: thinking={}, token={}, done={}",
                90, got_thinking, got_token, got_done);
        }
    }

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 🌐 WS E2E test passed – {} API calls", calls);
    println!("{}", "=".repeat(70));
}
