//! E2E STT 端点测试 — 验证 POST /api/stt 不崩溃
//!
//! 当前状态: 无 iFlytek 凭据时返回 {"error": "credentials not configured"}
//! 完整测试需要: 真实 .m4a 录音 + 环境变量 IFLYTEK_APPID/API_KEY/API_SECRET

use serde_json::Value;
use std::sync::OnceLock;

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });
    let db_path = format!("data/test_stt_{}.db", chrono::Utc::now().timestamp());
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

#[tokio::test]
#[ignore]
async fn e2e_stt_endpoint() {
    println!("\n{}", "=".repeat(70));
    println!(" 🎤 STT E2E test – endpoint availability check");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();

    // 发送空 POST 到 /api/stt
    println!("\n--- POST /api/stt (empty body) ---");
    let resp = client.post(format!("{}/api/stt", base))
        .header("Content-Type", "application/octet-stream")
        .body(vec![])
        .send().await.unwrap();
    let status = resp.status().as_u16();
    let body: Value = resp.json().await.unwrap_or_default();
    println!("  status: {}", status);
    println!("  body: {:?}", body);

    // 无 iFlytek 凭据时返回 200 + error 字段
    assert_eq!(status, 200, "STT endpoint should return 200 even without credentials");
    assert!(body.get("error").is_some(), "should return error without iFlytek credentials");

    // 再试一个有内容的 body
    println!("\n--- POST /api/stt (with dummy audio bytes) ---");
    let dummy_audio = vec![0u8; 1024]; // 1KB 假音频
    let resp2 = client.post(format!("{}/api/stt", base))
        .header("Content-Type", "application/octet-stream")
        .body(dummy_audio)
        .send().await.unwrap();
    let status2 = resp2.status().as_u16();
    let body2: Value = resp2.json().await.unwrap_or_default();
    println!("  status: {}", status2);
    println!("  body: {:?}", body2);

    assert_eq!(status2, 200, "STT should return 200 with dummy audio");

    println!("\n{}", "=".repeat(70));
    println!(" 🎤 STT E2E test passed – endpoint alive (no iFlytek creds)");
    println!("{}", "=".repeat(70));
}
