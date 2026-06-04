//! E2E 对话管理测试（纯 HTTP，不依赖 LLM）
//!
//! 覆盖:
//!   DELETE /api/conversations/{conv_id}         — 软删除
//!   POST  /api/conversations/{conv_id}/restore   — 恢复
//!   DELETE /api/conversations/{conv_id}/permanent — 彻底删除

use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "convuser";
const TEST_PASS: &str = "convpass123";

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_conv_{}.db", chrono::Utc::now().timestamp());
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
async fn e2e_conv_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 💬 Conversation E2E test – soft delete, restore, permanent delete");
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

    // ── Step 3: 创建测试对话 ──
    println!("\n--- Step 3: Create test conversations ---");
    let conv_id = "test_conv_mgmt";
    let now = chrono::Utc::now().to_rfc3339();
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at)
             VALUES (?1, ?2, 3, ?3)",
            rusqlite::params![conv_id, uid, now],
        ).expect("insert conversation");
        for i in 0..3 {
            conn.execute(
                "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![
                    format!("turn_{}", i), conv_id,
                    if i == 0 { "user" } else { "assistant" },
                    format!("测试消息 {}", i),
                    (chrono::Utc::now().timestamp() + i as i64).to_string(),
                ],
            ).expect("insert turn");
        }
    }
    calls += 1;
    println!("  created conv: {}", conv_id);

    // ── Step 4: GET /api/history 验证对话存在 ──
    println!("\n--- Step 4: GET /api/history (active only) ---");
    let resp = client.get(format!("{}/api/history?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist: Value = body_json(resp).await;
    calls += 1;
    let convs = hist["conversations"].as_array().unwrap();
    println!("  active conversations: {}", convs.len());
    assert!(convs.iter().any(|c| c["id"] == conv_id), "should find our conversation");

    // ── Step 5: DELETE 软删除对话 ──
    println!("\n--- Step 5: DELETE /api/conversations/{} (soft delete) ---", conv_id);
    let resp = client.delete(format!("{}/api/conversations/{}", base, conv_id))
        .header("Authorization", format!("Bearer {}", token))
        .query(&[("user_id", uid.as_str())])
        .send().await.unwrap();
    let del: Value = body_json(resp).await;
    calls += 1;
    println!("  delete response: {:?}", del);
    assert_eq!(del["status"].as_str(), Some("ok"), "soft delete should succeed");
    assert!(del["deleted_at"].is_number(), "deleted_at should be set");

    // ── Step 6: GET /api/history 验证对话不在活跃列表中 ──
    println!("\n--- Step 6: GET /api/history (active only, after delete) ---");
    let resp = client.get(format!("{}/api/history?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist2: Value = body_json(resp).await;
    calls += 1;
    let active_convs = hist2["conversations"].as_array().unwrap();
    println!("  active conversations: {}", active_convs.len());
    assert!(!active_convs.iter().any(|c| c["id"] == conv_id), "conv should not appear after delete");

    // ── Step 7: GET /api/history?include_deleted=only 验证在回收站 ──
    println!("\n--- Step 7: GET /api/history (deleted only) ---");
    let resp = client.get(format!("{}/api/history?user_id={}&include_deleted=only", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist3: Value = body_json(resp).await;
    calls += 1;
    let deleted_convs = hist3["conversations"].as_array().unwrap();
    println!("  deleted conversations: {}", deleted_convs.len());
    assert!(deleted_convs.iter().any(|c| c["id"] == conv_id), "conv should appear in deleted list");

    // ── Step 8: POST restore 恢复对话 ──
    println!("\n--- Step 8: POST restore ---");
    let resp = client.post(format!("{}/api/conversations/{}/restore", base, conv_id))
        .header("Authorization", format!("Bearer {}", token))
        .query(&[("user_id", uid.as_str())])
        .send().await.unwrap();
    calls += 1;
    println!("  restore status: {}", resp.status());
    assert_eq!(resp.status().as_u16(), 200, "restore should return 200");

    // ── Step 9: GET /api/history 验证对话回来了 ──
    println!("\n--- Step 9: GET /api/history (active, after restore) ---");
    let resp = client.get(format!("{}/api/history?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist4: Value = body_json(resp).await;
    calls += 1;
    let restored = hist4["conversations"].as_array().unwrap();
    println!("  active conversations: {}", restored.len());
    assert!(restored.iter().any(|c| c["id"] == conv_id), "conv should be back after restore");

    // ── Step 10: DELETE permanent 彻底删除 ──
    println!("\n--- Step 10: DELETE permanent ---");
    let resp = client.delete(format!("{}/api/conversations/{}/permanent", base, conv_id))
        .header("Authorization", format!("Bearer {}", token))
        .query(&[("user_id", uid.as_str())])
        .send().await.unwrap();
    calls += 1;
    println!("  permanent delete status: {}", resp.status());
    assert_eq!(resp.status().as_u16(), 200, "permanent delete should return 200");

    // ── Step 11: GET /api/history?include_deleted=true 验证彻底消失 ──
    println!("\n--- Step 11: GET /api/history (all, after permanent delete) ---");
    let resp = client.get(format!("{}/api/history?user_id={}&include_deleted=true", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist5: Value = body_json(resp).await;
    calls += 1;
    let all_convs = hist5["conversations"].as_array().unwrap();
    println!("  all conversations: {}", all_convs.len());
    assert!(!all_convs.iter().any(|c| c["id"] == conv_id), "conv should be gone after permanent delete");

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 💬 Conversation E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
