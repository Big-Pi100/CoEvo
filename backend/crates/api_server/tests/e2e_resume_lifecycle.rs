//! E2E 历史会话重建测试（轻量 LLM 调用）
//!
//! 验证已存在的管线对话（free/K12/Reading）被断线重连时：
//!   1. GET /api/history       — 历史消息正确加载
//!   2. GET /api/plans         — plan + progress 正确加载
//!   3. WS 重新连接            — system prompt 正确恢复，对话继续
//!   4. turn_count 递增        — 历史未丢失
//!
//! 要求: 先运行 e2e_api_lifecycle 产生数据

use api_server::test_helpers::body_json;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::sync::OnceLock;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

const TEST_USER: &str = "e2eapitest";
const TEST_PASS: &str = "pass123word456";

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> (String, String) {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    api_server::test_helpers::init_tracing();
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = std::env::var("COEVO_DB_PATH").unwrap_or_else(|_| {
        api_server::test_helpers::resolve_db_path().to_string_lossy().to_string()
    });
    let is_new_db = !std::path::Path::new(&db_path).exists();
    api_server::db_pool::init(&db_path).expect("init db");
    if is_new_db {
        let conn = api_server::db_pool::get_conn();
        api_server::schema::init_database(&conn).expect("schema init");
    }
    let api_key = std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);
    let ws_base = format!("ws://{}", addr);
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    (base, ws_base)
}

/// 获取全部活跃对话摘要列表
async fn list_conversations(client: &reqwest::Client, base: &str, uid: &str, token: &str) -> Value {
    let resp = client.get(format!("{}/api/history?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    body_json(resp).await
}

/// 获取指定对话的消息历史
async fn get_history(client: &reqwest::Client, base: &str, uid: &str, conv: &str, token: &str) -> Value {
    let resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, conv))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    body_json(resp).await
}

/// 获取指定对话的 plan
async fn get_plan(client: &reqwest::Client, base: &str, conv: &str, token: &str) -> Value {
    let resp = client.get(format!("{}/api/plans?conversation_id={}", base, conv))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    body_json(resp).await
}

/// 通过 WS 发送一消息并等 done
async fn ws_send_and_wait<S, St>(write: &mut S, read: &mut St, msg: &str) -> (String, bool)
where
    S: SinkExt<Message> + Unpin,
    S::Error: std::fmt::Debug,
    St: StreamExt<Item=Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    write.send(Message::Text(msg.to_string().into())).await.expect("WS send");
    let mut reply = String::new();
    let mut plan_updated = false;

    tokio::time::timeout(std::time::Duration::from_secs(60), async {
        while let Some(item) = read.next().await {
            if let Ok(Message::Text(t)) = item {
                let event: Value = serde_json::from_str(&t).unwrap_or_default();
                match event["type"].as_str().unwrap_or("") {
                    "done" => {
                        reply = event["reply"].as_str().unwrap_or("").to_string();
                        return;
                    }
                    "plan_updated" => { plan_updated = true; }
                    _ => {}
                }
            }
        }
    }).await.expect("WS timeout");

    (reply, plan_updated)
}

#[tokio::test]
#[ignore]
async fn e2e_resume_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🔄 Resume E2E test – history reopening + WS reconnect");
    println!("    检查所有管线对话的断线重连");
    println!("{}", "=".repeat(70));

    let (base, ws_base) = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Register（用户已存在则跳过）──
    println!("\n--- Step 1: Register ---");
    let register_resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await;
    match register_resp {
        Ok(r) if r.status().is_success() => {
            calls += 1;
            let reg: Value = body_json(r).await;
            println!("  registered uid={:?}", reg["user_id"].as_str());
        }
        _ => {
            calls += 1;
            println!("  user already exists, skipping");
        }
    }

    // ── Step 2: Login ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let uid = login["user_id"].as_str().expect("login user_id").to_string();
    let token = login["token"].as_str().expect("login token").to_string();
    println!("  uid={}", uid);

    // ── Step 3: 列出所有活跃对话 ──
    println!("\n--- Step 3: List all active conversations ---");
    let conv_list = list_conversations(&client, &base, &uid, &token).await;
    calls += 1;
    let conversations: Vec<Value> = conv_list["conversations"].as_array()
        .map(|a| a.to_vec()).unwrap_or_default();

    if conversations.is_empty() {
        println!("  ⚠️ 无活跃对话，跳过（先运行 e2e_api_lifecycle 产生数据）");
        println!("\n{}", "=".repeat(70));
        println!(" 🔄 Resume E2E test skipped – no pipeline conversations");
        println!("{}", "=".repeat(70));
        return;
    }

    println!("  {} active conversations found:", conversations.len());
    for c in &conversations {
        let cid = c["id"].as_str().unwrap_or("");
        let turns = c["turn_count"].as_u64().unwrap_or(0);
        println!("    conv={}, turn_count={}", &cid[..cid.len().min(36)], turns);
    }

    // ── Step 4: 对每个对话重建连接验证 ──
    let mut resumed = 0u32;
    for (idx, conv_entry) in conversations.iter().enumerate() {
        let conv_id = conv_entry["id"].as_str().unwrap_or("").to_string();
        let historical_turns = conv_entry["turn_count"].as_u64().unwrap_or(0);

        println!("\n--- Step 4.{}: Resume conv={} (current_turns={}) ---",
            idx + 1, &conv_id[..12], historical_turns);

        // 4a. 查消息历史
        let hist = get_history(&client, &base, &uid, &conv_id, &token).await;
        calls += 1;
        let turns = hist["turns"].as_array().map(|a| a.len()).unwrap_or(0);
        println!("  ① history: {} turns loaded", turns);
        assert!(turns > 0, "history should load turns, got 0");

        // 4b. 查 plan + progress
        let plan_val = get_plan(&client, &base, &conv_id, &token).await;
        calls += 1;
        let has_plan = plan_val.get("plans")
            .and_then(|p| p.as_array())
            .map(|a| !a.is_empty())
            .unwrap_or(false);
        println!("  ② plan: has_plan={}", has_plan);

        // 4c. 打开新的 WS 连接 → 发送 ChatRequest → 验证回复
        let ws_url = format!("{}/ws", ws_base);
        match connect_async(&ws_url).await {
            Ok((ws_stream, _)) => {
                let (mut write, mut read) = ws_stream.split();
                // 首条消息必须是 ChatRequest JSON（含 user_id, conversation_id, token, message）
                let chat_req = json!({
                    "type": "chat",
                    "user_id": uid,
                    "conversation_id": conv_id,
                    "token": token,
                    "message": "简单的对话重建测试",
                }).to_string();
                let (reply, plan_updated) = ws_send_and_wait(&mut write, &mut read, &chat_req).await;
                if !reply.is_empty() {
                    resumed += 1;
                    println!("  ③ WS reply: {} chars, plan_updated={}",
                        reply.len(), plan_updated);
                    // 验证回复不是空字符串或错误
                    assert!(reply.len() > 10, "WS reply should be meaningful, got {} chars", reply.len());
                } else {
                    println!("  ③ WS reply: empty (timeout)");
                }
                let _ = write.close().await;
            }
            Err(e) => {
                println!("  ③ WS connect failed: {}", e);
            }
        }

        // 4d. 查 history 验证 turn_count 递增
        let hist2 = get_history(&client, &base, &uid, &conv_id, &token).await;
        calls += 1;
        let turns2 = hist2["turns"].as_array().map(|a| a.len()).unwrap_or(0);
        println!("  ④ turns after resume: {} (was {})", turns2, turns);
        let expected_min = turns + 2; // 至少 + 2（user msg + assistant reply）
        assert!(turns2 >= expected_min,
            "resume should add at least 2 turns, got {} (expected >= {})", turns2, expected_min);

        // 打印对话模式信息（从 WS 日志核对）
        println!("  ⑤ resume success for {}", &conv_id[..16]);
    }

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 🔄 Resume E2E test – {}/{} conversations resumed ({}/{} API calls)",
        resumed, conversations.len(), calls, calls);
    assert!(resumed > 0, "at least one conversation should resume successfully");
    println!("{}", "=".repeat(70));
}
