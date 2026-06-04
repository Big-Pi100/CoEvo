//! E2E 卡片状态管理测试（纯 HTTP，不依赖 LLM）
//!
//! 覆盖:
//!   PATCH /api/cards/status       — 单张卡片状态切换
//!   PATCH /api/cards/batch-status  — 批量修改
//!   GET  /api/cards/all            — 验证状态变更生效

use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "cardsuser";
const TEST_PASS: &str = "cardspass123";

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_cards_{}.db", chrono::Utc::now().timestamp());
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

#[tokio::test]
#[ignore]
async fn e2e_cards_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🃏 Cards E2E test – card status management");
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

    // ── Step 3: Subscription ──
    println!("\n--- Step 3: Subscription ---");
    let expires = format!("{}T00:00:00Z",
        (chrono::Utc::now() + chrono::Duration::days(30)).format("%Y-%m-%d"));
    let resp = client.put(format!("{}/api/user/{}/preferences", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"subscription_expires": expires}))
        .send().await.unwrap();
    println!("  subscription: {}", resp.status());

    // ── Step 4: 直接通过 SQL 创建测试卡片（避免 LLM 依赖） ──
    println!("\n--- Step 4: Create test cards via SQL ---");
    let now = chrono::Utc::now().timestamp();
    let card_ids: Vec<String> = (1..=3).map(|i| format!("test_card_{}", i)).collect();
    {
        let conn = api_server::db_pool::get_conn();
        // 先创建 conversation（避免 FK 约束）
        let _ = conn.execute(
            "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at)
             VALUES ('test_conv', ?1, 1, ?2)",
            rusqlite::params![uid, chrono::Utc::now().to_rfc3339()],
        );
        for i in 0..3 {
            let cid = &card_ids[i];
            match conn.execute(
                "INSERT INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, status)
                 VALUES (?1, ?2, 'math', 'concept', ?3, ?4, 'test_conv', ?5, 'active')",
                rusqlite::params![cid, uid, format!("测试概念 {}", i+1), format!("概念 {} 的解释", i+1), now],
            ) {
                Ok(n) => println!("  inserted card {}: {} rows", cid, n),
                Err(e) => println!("  INSERT card {} FAILED: {}", cid, e),
            }
            match conn.execute(
                "INSERT OR IGNORE INTO card_memory (card_id, state, status, difficulty, stability, due, last_review, reps, lapses)
                 VALUES (?1, 0, 'active', 0.3, 1.0, ?2, 0, 0, 0)",
                rusqlite::params![cid, now],
            ) {
                Ok(n) => println!("  inserted card_memory {}: {} rows", cid, n),
                Err(e) => println!("  INSERT card_memory {} FAILED: {}", cid, e),
            }
        }
    }
    println!("  created 3 test cards: {:?}", card_ids);
    // Debug: 直接查 DB 确认写入
    {
        let conn = api_server::db_pool::get_conn();
        let db_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM cards WHERE user_id = ?1",
            rusqlite::params![uid], |r| r.get(0),
        ).unwrap_or(-1);
        let active_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM cards WHERE user_id = ?1 AND status = 'active'",
            rusqlite::params![uid], |r| r.get(0),
        ).unwrap_or(-1);
        println!("  DB: total={}, active={}", db_count, active_count);
    }
    calls += 1;

    // ── Step 5: GET /api/cards/all 验证卡片存在 ──
    println!("\n--- Step 5: GET /api/cards/all (all active) ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all_val: Value = body_json(resp).await;
    calls += 1;
    let pre_total = all_val["total"].as_i64().unwrap_or(0);
    println!("  total cards: {}", pre_total);
    assert!(pre_total >= 3, "should have at least 3 cards, got {}", pre_total);

    // ── Step 6: PATCH /api/cards/status — 将第一张卡标记为 skipped ──
    println!("\n--- Step 6: PATCH /api/cards/status (single → skipped) ---");
    let resp = client.patch(format!("{}/api/cards/status", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"user_id": uid, "card_id": card_ids[0], "status": "skipped"}))
        .send().await.unwrap();
    let status_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  status response: {:?}", status_resp);
    assert_eq!(status_resp["status"].as_str(), Some("ok"), "single status update should succeed");

    // ── Step 7: GET /api/cards/all 验证 skipped 的卡不再出现 ──
    println!("\n--- Step 7: GET /api/cards/all (after skip, active only) ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all2: Value = body_json(resp).await;
    calls += 1;
    let post_total = all2["total"].as_i64().unwrap_or(0);
    println!("  total cards (active only): {} (was {})", post_total, pre_total);
    assert_eq!(post_total, pre_total - 1, "skipped card should disappear from active count");

    // ── Step 8: PATCH /api/cards/batch-status — 将剩余 2 张标记为 archived ──
    println!("\n--- Step 8: PATCH /api/cards/batch-status (batch → archived) ---");
    let resp = client.patch(format!("{}/api/cards/batch-status", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"user_id": uid, "card_ids": [card_ids[1], card_ids[2]], "status": "archived"}))
        .send().await.unwrap();
    let batch_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  batch status response: {:?}", batch_resp);
    assert_eq!(batch_resp["status"].as_str(), Some("ok"), "batch status update should succeed");
    assert!(batch_resp["updated"].as_i64().unwrap_or(0) >= 2, "should update 2 cards");

    // ── Step 9: GET /api/cards/all 验证全部移除 ──
    println!("\n--- Step 9: GET /api/cards/all (after batch archive) ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all3: Value = body_json(resp).await;
    calls += 1;
    let final_total = all3["total"].as_i64().unwrap_or(0);
    println!("  total cards (active only): {} (was {})", final_total, post_total);
    assert_eq!(final_total, 0, "all cards should be non-active, got {}", final_total);

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 🃏 Cards E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
