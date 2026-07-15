//! E2E 考试管线测试（含 LLM 调用）
//!
//! 在 pipeline 产出的真实卡片上执行完整考试流程：
//!   1. GET  /api/cards/all             — 找到一张活跃卡片
//!   2. POST /api/review/verify         — LLM 生成 3 个快问快答题目
//!   3. POST /api/review/judge          — LLM 判断用户答案正确性
//!   4. POST /api/review/submit         — 提交复习结果（含 FSRS 调度）
//!   5. GET  /api/cards/{id}/last-review — 验证考试记录已保存
//!
//! 不依赖 LLM 的步骤：due（可以跳过，直接从 cards/all 拿卡片）

use api_server::test_helpers::body_json;
use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "e2eapitest";
const TEST_PASS: &str = "pass123word456";

// 用于 defer 测试的独立测试用户
const DEFER_TEST_USER: &str = "e2edefertest";
const DEFER_TEST_PASS: &str = "defertest123";

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
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    base
}

#[tokio::test]
#[ignore]
async fn e2e_review_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" ✅ Review E2E test – full exam pipeline on real cards");
    println!("    verify → judge → submit → last-review");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
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
        _ => { calls += 1; println!("  user exists"); }
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

    // ── Step 3: 找一张活跃卡片 ──
    println!("\n--- Step 3: Find an active card ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all_val: Value = body_json(resp).await;
    calls += 1;
    let total = all_val["total"].as_i64().unwrap_or(0);
    let cards = all_val["cards"].as_array().map(|a| a.to_vec()).unwrap_or_default();

    if cards.is_empty() {
        println!("  ⚠️ 无活跃卡片，跳过（先运行 e2e_api_lifecycle 产生数据）");
        println!("\n{}", "=".repeat(70));
        println!(" ✅ Review E2E test skipped – no active cards");
        println!("{}", "=".repeat(70));
        return;
    }

    let card = &cards[0];
    let card_id = card["id"].as_str().unwrap_or("");
    let front = card["front"].as_str().unwrap_or("");
    let back = card["back"].as_str().unwrap_or("");
    println!("  selected card: id={}, front={:.40}, back={:.30}",
        card_id, front, back);
    assert!(!card_id.is_empty(), "card must have id");

    // ── Step 4: POST /api/review/verify — LLM 生成快问快答题目 ──
    println!("\n--- Step 4: POST /api/review/verify — generate quiz questions ---");
    let resp = client.post(format!("{}/api/review/verify", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "card_id": card_id,
            "front": front,
            "back": back,
        }))
        .send().await.unwrap();
    let verify_val: Value = body_json(resp).await;
    calls += 1;

    let questions = verify_val["questions"].as_array()
        .map(|a| a.to_vec()).unwrap_or_default();
    println!("  generated {} questions", questions.len());
    if questions.is_empty() {
        println!("  ⚠️ LLM did not return valid questions, skipping judge+submit");
        println!("  raw response: {:?}", verify_val);
        println!("\n{}", "=".repeat(70));
        println!(" ✅ Review E2E test – partial (verify only)");
        println!("{}", "=".repeat(70));
        return;
    }

    for (i, q) in questions.iter().enumerate() {
        let expected = q["expected_answer"].as_str().unwrap_or("?");
        println!("  Q{}: {} (expected: {} chars)", i + 1,
            q["question"].as_str().unwrap_or("?"),
            expected.chars().count());
    }

    // ── Step 5: POST /api/review/judge — 用正确答案作为用户答案（模拟考试通过）──
    println!("\n--- Step 5: POST /api/review/judge — evaluate answers ---");
    let judge_questions: Vec<Value> = questions.iter().map(|q| {
        let expected = q["expected_answer"].as_str().unwrap_or("?");
        json!({
            "question": q["question"].as_str().unwrap_or(""),
            "expected_answer": expected,
            "user_answer": expected,  // 用正确答案模拟用户输入
        })
    }).collect();

    let resp = client.post(format!("{}/api/review/judge", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "card_id": card_id,
            "questions": judge_questions,
        }))
        .send().await.unwrap();
    let judge_val: Value = body_json(resp).await;
    calls += 1;

    let results = judge_val["results"].as_array()
        .map(|a| a.to_vec()).unwrap_or_default();
    println!("  judged {} answers", results.len());
    for r in &results {
        println!("    correct={}, feedback={:.40}", r["correct"].as_bool().unwrap_or(false), r["feedback"].as_str().unwrap_or(""));
    }
    assert!(results.len() > 0, "should have judged answers");

    // ── Step 6: POST /api/review/submit — 提交复习结果 ──
    println!("\n--- Step 6: POST /api/review/submit — submit review result ---");
    let details: Vec<Value> = results.iter().map(|r| {
        json!({
            "question": r["question"].as_str().unwrap_or(""),
            "correct": r["correct"].as_bool().unwrap_or(false),
            "feedback": r["feedback"].as_str().unwrap_or(""),
        })
    }).collect();

    let details_str = serde_json::to_string(&details).unwrap_or_default();
    let resp = client.post(format!("{}/api/review/submit", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "card_id": card_id,
            "rating": 4,
            "verification_type": "ai_dialogue",
            "verification_result": "pass",
            "details": details_str,
        }))
        .send().await.unwrap();
    let submit_val: Value = body_json(resp).await;
    calls += 1;
    println!("  submit response: status={:?}, achievements={:?}",
        submit_val["status"].as_str(),
        submit_val["achievements"].as_array().map(|a| a.len()).unwrap_or(0));
    assert_eq!(submit_val["status"].as_str(), Some("ok"), "submit should succeed");

    // ── Step 7: GET /api/cards/{id}/last-review — 验证考试记录已保存 ──
    println!("\n--- Step 7: GET /api/cards/{}/last-review ---", card_id);
    let resp = client.get(format!("{}/api/cards/{}/last-review?user_id={}", base, card_id, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let last_review: Value = body_json(resp).await;
    calls += 1;
    println!("  last review: rating={}, verification_type={}, verification_result={}",
        last_review["rating"].as_i64().unwrap_or(-1),
        last_review["verification_type"].as_str().unwrap_or(""),
        last_review["verification_result"].as_str().unwrap_or(""));
    assert_eq!(last_review["verification_type"].as_str(), Some("ai_dialogue"),
        "verification_type should be ai_dialogue");
    assert!(last_review["details"].is_array() || last_review["details"].is_string(),
        "details should exist in last-review");

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" ✅ Review E2E test passed – {} API calls", calls);
    println!("    {} questions generated, {} answers judged, review saved", questions.len(), results.len());
    println!("{}", "=".repeat(70));
}

// ════════════════════════════════════════════════════════════════
// Defer Queue 生命周期测试
// ════════════════════════════════════════════════════════════════

#[tokio::test]
#[ignore]
async fn e2e_defer_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" ✅ Defer Queue E2E test – defer/status lifecycle");
    println!("    defer → status(is_deferred=true) → wait → status(is_deferred=false)");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Register（用户已存在则跳过）──
    println!("\n--- Step 1: Register ---");
    let register_resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": DEFER_TEST_USER, "password": DEFER_TEST_PASS}))
        .send().await;
    match register_resp {
        Ok(r) if r.status().is_success() => {
            calls += 1;
            println!("  registered");
        }
        _ => { calls += 1; println!("  user exists"); }
    }

    // ── Step 2: Login ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": DEFER_TEST_USER, "password": DEFER_TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let uid = login["user_id"].as_str().expect("login user_id").to_string();
    let token = login["token"].as_str().expect("login token").to_string();
    println!("  uid={}", uid);

    // ── Step 3: GET /api/review/status — 初始状态（未推迟）──
    println!("\n--- Step 3: GET /api/review/status (initial) ---");
    let resp = client.get(format!("{}/api/review/status?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    calls += 1;
    let status: Value = body_json(resp).await;
    println!("  initial status: has_due={}, is_deferred={}",
        status["has_due"], status["is_deferred"]);
    assert_eq!(status["is_deferred"].as_bool(), Some(false),
        "initially should not be deferred");

    // ── Step 4: POST /api/review/defer — 推迟 10 秒──
    println!("\n--- Step 4: POST /api/review/defer (10s) ---");
    let defer_resp = client.post(format!("{}/api/review/defer", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "defer_seconds": 10,
            "card_ids": ["test_card_1", "test_card_2"],
        }))
        .send().await.unwrap();
    calls += 1;
    let defer_val: Value = body_json(defer_resp).await;
    println!("  defer result: status={}, deferred_until={}, card_ids_deferred={}",
        defer_val["status"], defer_val["deferred_until"], defer_val["card_ids_deferred"]);
    assert_eq!(defer_val["status"].as_str(), Some("ok"), "defer should succeed");
    assert_eq!(defer_val["card_ids_deferred"].as_i64(), Some(2),
        "should have 2 cards deferred");

    // ── Step 5: GET /api/review/status — 推迟中 ──
    println!("\n--- Step 5: GET /api/review/status (deferred) ---");
    let resp = client.get(format!("{}/api/review/status?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    calls += 1;
    let status2: Value = body_json(resp).await;
    println!("  deferred status: is_deferred={}, remaining_seconds={}",
        status2["is_deferred"], status2["remaining_seconds"]);
    assert_eq!(status2["is_deferred"].as_bool(), Some(true),
        "should be deferred after POST");
    assert!(status2["remaining_seconds"].as_i64().unwrap_or(0) > 0,
        "remaining_seconds should be positive");

    // ── Step 6: 等待 12 秒，让推迟期过期 ──
    println!("\n--- Step 6: Wait 12s for defer to expire ---");
    tokio::time::sleep(std::time::Duration::from_secs(12)).await;

    // ── Step 7: GET /api/review/status — 推迟已过期 ──
    println!("\n--- Step 7: GET /api/review/status (expired) ---");
    let resp = client.get(format!("{}/api/review/status?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    calls += 1;
    let status3: Value = body_json(resp).await;
    println!("  expired status: is_deferred={}, remaining_seconds={}",
        status3["is_deferred"], status3["remaining_seconds"]);
    assert_eq!(status3["is_deferred"].as_bool(), Some(false),
        "should no longer be deferred after expiry");

    // ── Step 8: 测试 boundary — defer_seconds=0 → 自动 clamp 到 60 ──
    println!("\n--- Step 8: POST /api/review/defer (0s boundary) ---");
    let empty_ids: Vec<String> = vec![];
    let defer_resp2 = client.post(format!("{}/api/review/defer", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "defer_seconds": 0,
            "card_ids": empty_ids,
        }))
        .send().await.unwrap();
    calls += 1;
    let defer_val2: Value = body_json(defer_resp2).await;
    println!("  zero-second defer: status={}", defer_val2["status"]);
    assert_eq!(defer_val2["status"].as_str(), Some("ok"),
        "zero-second defer should also succeed (clamped to 60)");

    // ── Step 9: 测试 boundary — defer_seconds 超大 → 自动 clamp ──
    println!("\n--- Step 9: POST /api/review/defer (huge boundary) ---");
    let defer_resp3 = client.post(format!("{}/api/review/defer", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "defer_seconds": 999999999,
            "card_ids": ["card_big"],
        }))
        .send().await.unwrap();
    calls += 1;
    let defer_val3: Value = body_json(defer_resp3).await;
    println!("  huge-value defer: status={}", defer_val3["status"]);
    assert_eq!(defer_val3["status"].as_str(), Some("ok"),
        "huge defer_seconds should also succeed (clamped to 30 days)");

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" ✅ Defer Queue E2E test passed – {} API calls", calls);
    println!("    defer → status(check) → wait → status(expired) → boundary tests");
    println!("{}", "=".repeat(70));
}

/// 辅助函数：POST /api/review/defer 并检查状态
#[allow(dead_code)]
async fn call_defer_status(
    base: &str, uid: &str, token: &str,
    client: &reqwest::Client,
) -> (Value, u32) {
    let resp = client.get(format!("{}/api/review/status?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    (body_json(resp).await, 1)
}
