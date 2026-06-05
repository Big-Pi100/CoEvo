//! E2E 用户资料/活动/周报测试（纯 HTTP，不依赖 LLM）
//!
//! 覆盖:
//!   GET  /api/user/{id}/profile
//!   POST /api/user/{id}/display-name
//!   GET  /api/user/{id}/preferences
//!   PUT  /api/user/{id}/preferences
//!   GET  /api/user/{id}/activity?days=30
//!   GET  /api/user/{id}/weekly-report
//!   POST /api/auth/verify

use api_server::test_helpers::body_json;
use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "profileuser";
const TEST_PASS: &str = "profilepass123";

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    api_server::test_helpers::init_tracing();
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_profile_{}.db", chrono::Utc::now().timestamp());
    let _ = std::fs::remove_file(&db_path);
    api_server::db_pool::init(&db_path).expect("init db");
    let conn = api_server::db_pool::get_conn();
    api_server::schema::init_database(&conn).expect("schema init");
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

#[tokio::test]
#[ignore]
async fn e2e_profile_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 👤 Profile E2E test – user profile, prefs, activity, report");
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
    let uid = reg["user_id"].as_str().expect("register uid").to_string();
    println!("  uid: {}", uid);

    // ── Step 2: Login ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let token = login["token"].as_str().expect("login token").to_string();
    println!("  token: {}...", &token[..16]);

    // ── Step 3: Token verify ──
    println!("\n--- Step 3: Token verify ---");
    let resp = client.post(format!("{}/api/auth/verify", base))
        .json(&json!({"user_id": uid, "token": token}))
        .send().await.unwrap();
    let verify: Value = body_json(resp).await;
    calls += 1;
    assert_eq!(verify["valid"].as_bool(), Some(true), "token should be valid");
    println!("  valid: {} ✅", verify["valid"]);

    // ── Step 4: Get profile ──
    println!("\n--- Step 4: GET /api/user/{}/profile ---", uid);
    let resp = client.get(format!("{}/api/user/{}/profile", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let profile: Value = body_json(resp).await;
    calls += 1;
    let uid_back = profile["user_id"].as_str().unwrap_or("?");
    println!("  user_id: {} (expected={})", uid_back, uid);
    assert_eq!(uid_back, uid, "profile user_id should match");
    let stats = profile["stats"].as_object().expect("profile should have stats object");
    assert!(stats.contains_key("total_cards"), "profile stats should have total_cards");
    println!("  stats: {:?}", stats);

    // ── Step 5: Update display name ──
    println!("\n--- Step 5: POST display-name ---");
    let resp = client.post(format!("{}/api/user/{}/display-name", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"display_name": "测试用户张三"}))
        .send().await.unwrap();
    let dn: Value = body_json(resp).await;
    calls += 1;
    println!("  display-name response: {:?}", dn);
    assert_eq!(dn["status"].as_str(), Some("ok"), "display-name update should succeed");
    assert_eq!(dn["display_name"].as_str(), Some("测试用户张三"), "display name should match");

    // ── Step 6: Get preferences (empty initially) ──
    println!("\n--- Step 6: GET preferences ---");
    let resp = client.get(format!("{}/api/user/{}/preferences", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let prefs: Value = body_json(resp).await;
    calls += 1;
    println!("  preferences keys: {}", prefs.as_object().map(|o| o.len()).unwrap_or(0));
    // 初始无数据，可能返回空对象或包含 subscription_expires（如果之前设过）

    // ── Step 7: Save preferences ──
    println!("\n--- Step 7: PUT preferences ---");
    let expires = format!("{}T00:00:00Z",
        (chrono::Utc::now() + chrono::Duration::days(30)).format("%Y-%m-%d"));
    let resp = client.put(format!("{}/api/user/{}/preferences", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"subscription_expires": expires, "theme": "dark", "language": "zh-CN"}))
        .send().await.unwrap();
    calls += 1;
    assert_eq!(resp.status().as_u16(), 200, "preferences PUT should return 200");

    // 读回来验证
    let resp = client.get(format!("{}/api/user/{}/preferences", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let prefs2: Value = body_json(resp).await;
    calls += 1;
    println!("  preferences: {:?}", prefs2);
    assert!(prefs2.get("subscription_expires").is_some(), "subscription_expires should be set");
    assert!(prefs2.get("theme").is_some(), "theme should be set");

    // ── Step 8: Get activity ──
    println!("\n--- Step 8: GET activity ---");
    let resp = client.get(format!("{}/api/user/{}/activity?days=30", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let activity: Value = body_json(resp).await;
    calls += 1;
    println!("  activity keys: {:?}", activity.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()));
    // 新用户可能没有活动数据，但至少应返回有效 JSON
    assert!(activity.is_object(), "activity should return an object");

    // ── Step 9: Get weekly report ──
    println!("\n--- Step 9: GET weekly-report ---");
    let resp = client.get(format!("{}/api/user/{}/weekly-report", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let wr: Value = body_json(resp).await;
    calls += 1;
    println!("  weekly-report keys: {:?}", wr.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()));
    // 新用户周报可能全为 0，但应返回有效结构
    assert!(wr.is_object(), "weekly-report should return an object");

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 👤 Profile E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
