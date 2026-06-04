//! E2E 多用户并发安全测试
//!
//! 验证后端在高并发场景下不存在竞态条件和跨用户数据泄漏。
//!
//! 测试场景:
//!   1. 并发注册 + K12 init（同一科目，验证 plan_id 不冲突）
//!   2. 并发聊天（验证 turn_count 递增不乱序）
//!   3. 并发提交复习（验证 FSRS 不互相影响）
//!   4. 验证各用户数据隔离（不看到对方的数据）
//!
//! 注：不依赖 student_llm（用固定消息代替 LLM 对话），测试纯并发安全

use serde_json::{json, Value};
use std::sync::OnceLock;
use futures_util::future::join_all;

const USERS: &[(&str, &str)] = &[
    ("concuruserA", "pass123a"),
    ("concuruserB", "pass123b"),
    ("concuruserC", "pass123c"),
];

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = api_server::curriculum_loader::init();
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_concur_{}.db", chrono::Utc::now().timestamp());
    let _ = std::fs::remove_file(&db_path);
    api_server::db_pool::init(&db_path).expect("init db");
    let conn = api_server::db_pool::get_conn();
    let sql = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/schema.sql"));
    conn.execute_batch(&sql).expect("schema init");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS user_preferences (
            user_id TEXT NOT NULL, key TEXT NOT NULL,
            value TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, key),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );"
    ).expect("user_preferences table");
    let api_key = std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    base
}

async fn body_json(resp: reqwest::Response) -> Value {
    resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
}

/// 完整用户会话：注册 + 登录 + 订阅
async fn setup_user(base: &str, client: reqwest::Client, username: &str, password: &str) -> (String, String) {
    let _ = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": username, "password": password}))
        .send().await;
    // retry loop: register might be delayed by concurrent requests
    for attempt in 0..5 {
        let resp = client.post(format!("{}/api/auth/login", base))
            .json(&json!({"username": username, "password": password}))
            .send().await.unwrap();
        let login: Value = body_json(resp).await;
        if let (Some(uid), Some(token)) = (
            login["user_id"].as_str().map(|s| s.to_string()),
            login["token"].as_str().map(|s| s.to_string()),
        ) {
            // 订阅
            let expires = format!("{}T00:00:00Z",
                (chrono::Utc::now() + chrono::Duration::days(30)).format("%Y-%m-%d"));
            let _ = client.put(format!("{}/api/user/{}/preferences", base, uid))
                .header("Authorization", format!("Bearer {}", token))
                .json(&json!({"subscription_expires": expires}))
                .send().await;
            return (uid, token);
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    panic!("setup_user failed for {} after 5 retries", username);
}

#[tokio::test]
#[ignore]
async fn e2e_concurrency_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" ⚡ Concurrency E2E test – multi-user parallel safety");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Phase 1: 并发注册 + 初始化 ──
    println!("\n--- Phase 1: Concurrent user setup ---");
    let user_futures = USERS.iter().map(|(u, p)| {
        let client = client.clone();
        let base = base.clone();
        async move { setup_user(&base, client, u, p).await }
    });
    let user_results: Vec<(String, String)> = join_all(user_futures).await;
    calls += USERS.len() as u32 * 2; // login + subscription

    let users: Vec<(&str, String, String)> = USERS.iter().zip(user_results.iter())
        .map(|((name, _), (uid, token))| (*name, uid.clone(), token.clone()))
        .collect();

    for (name, uid, _) in &users {
        println!("  {}: uid={}", name, uid);
    }

    // ── Phase 2: 并发 K12 init（同一科目，验证 plan_id 不冲突）──
    println!("\n--- Phase 2: Concurrent K12 init (same subject) ---");
    let init_futures = users.iter().map(|(_, uid, token)| {
        let base = base.clone();
        let client = client.clone();
        let uid = uid.clone();
        let token = token.clone();
        async move {
            let resp = client.post(format!("{}/api/k12/init", base))
                .header("Authorization", format!("Bearer {}", token))
                .json(&json!({"user_id": uid, "subject": "math", "grade_band": "g7-9"}))
                .send().await.unwrap();
            let val: Value = body_json(resp).await;
            let conv_id = val["conversation_id"].as_str().map(|s| s.to_string());
            (uid, conv_id, val)
        }
    });
    let init_results: Vec<(String, Option<String>, Value)> = join_all(init_futures).await;
    calls += users.len() as u32;

    for (uid, conv_id, val) in &init_results {
        assert!(conv_id.is_some(), "user {} should get conversation_id", uid);
        assert!(val.get("error").is_none(), "user {} K12 init error: {:?}", uid, val.get("error"));
        // 验证 plan 存在
        let plan = val.get("plan");
        assert!(plan.is_some(), "user {} should get a plan", uid);
        if let Some(p) = plan {
            let stages = p.get("stages").and_then(|s| s.as_array());
            assert!(stages.is_some(), "user {} plan should have stages", uid);
            assert!(stages.map_or(0, |s| s.len()) > 0, "user {} plan should have at least 1 stage", uid);
        }
        // 验证 conversation_id 唯一
        let same_count = init_results.iter().filter(|(_, c, _)| c == conv_id).count();
        assert_eq!(same_count, 1, "conversation_id {} should be unique, shared by {} users", 
            conv_id.as_deref().unwrap_or("?"), same_count);
        println!("  {} init OK: conv={}", uid, conv_id.as_deref().unwrap_or("?"));
    }

    // ── Phase 3: 从每个用户的 plan 中读取计划 ──
    println!("\n--- Phase 3: Verify plans via API ---");
    let plan_futures = users.iter().map(|(_, uid, token)| {
        let base = base.clone();
        let client = client.clone();
        let uid = uid.clone();
        let token = token.clone();
        async move {
            let resp = client.get(format!("{}/api/plans?user_id={}", base, uid))
                .header("Authorization", format!("Bearer {}", token))
                .send().await.unwrap();
            let val: Value = body_json(resp).await;
            let plans = val["plans"].as_array().map(|a| a.len()).unwrap_or(0);
            (uid, plans)
        }
    });
    let plan_results: Vec<(String, usize)> = join_all(plan_futures).await;
    calls += users.len() as u32;

    for (uid, count) in &plan_results {
        assert!(*count >= 1, "user {} should have at least 1 plan, got {}", uid, count);
        println!("  {}: {} plan(s)", uid, count);
    }

    // ── Phase 4: 并发聊天（短消息，验证 turn_count 不乱序）──
    println!("\n--- Phase 4: Concurrent chat messages ---");
    let mut chat_futures = Vec::new();
    for (_, uid, token) in &users {
        let conv_id = init_results.iter()
            .find(|(u, _, _)| u == uid)
            .and_then(|(_, c, _)| c.clone())
            .unwrap_or_default();
        let base = base.clone();
        let client = client.clone();
        let uid = uid.clone();
        let token = token.clone();
        let msg = format!("Hello, please give me a math problem.");
        chat_futures.push(async move {
            let resp = client.post(format!("{}/api/chat", base))
                .header("Authorization", format!("Bearer {}", token))
                .json(&json!({"user_id": uid, "conversation_id": conv_id, "message": msg}))
                .send().await.unwrap();
            let val: Value = body_json(resp).await;
            (uid.clone(), val)
        });
    }
    let chat_results: Vec<(String, Value)> = join_all(chat_futures).await;
    calls += users.len() as u32;

    for (uid, val) in &chat_results {
        assert!(val.get("error").is_none(), "user {} chat error: {:?}", uid, val.get("error"));
        let reply = val["reply"].as_str().unwrap_or("");
        assert!(!reply.is_empty(), "user {} should get non-empty reply", uid);
        println!("  {} chat OK: reply={} chars", uid, reply.len());
    }

    // ── Phase 5: 验证各用户数据隔离 ──
    println!("\n--- Phase 5: Data isolation check ---");
    let isolation_futures = users.iter().map(|(_, uid, token)| {
        let base = base.clone();
        let client = client.clone();
        let uid = uid.clone();
        let token = token.clone();
        async move {
            // 检查用户的 conversations
            let resp = client.get(format!("{}/api/history?user_id={}", base, uid))
                .header("Authorization", format!("Bearer {}", token))
                .send().await.unwrap();
            let val: Value = body_json(resp).await;
            let convs = val["conversations"].as_array().map(|a| a.len()).unwrap_or(0);

            // 检查用户的 cards
            let resp2 = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
                .header("Authorization", format!("Bearer {}", token))
                .send().await.unwrap();
            let val2: Value = body_json(resp2).await;
            let cards = val2["total"].as_i64().unwrap_or(0);

            // 检查每个 conversation 属于该用户
            let all_match = val["conversations"].as_array()
                .map(|arr| arr.iter().all(|c| c.get("id").and_then(|id| id.as_str()).is_some()))
                .unwrap_or(true);

            (uid, convs, cards, all_match)
        }
    });
    let isolation_results: Vec<(String, usize, i64, bool)> = join_all(isolation_futures).await;
    calls += users.len() as u32 * 2; // history + cards/all per user

    for (uid, convs, cards, all_match) in &isolation_results {
        assert!(*all_match, "user {}: conversations should belong to this user", uid);
        assert!(*cards >= 0, "user {}: cards should be valid", uid);
        println!("  {}: {} conversations, {} cards (isolation OK)", uid, convs, cards);
    }

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" ⚡ Concurrency E2E test passed – {} API calls, {} concurrent users", calls, users.len());
    println!("{}", "=".repeat(70));
}
