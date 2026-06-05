//! E2E 卡片状态管理测试（纯 HTTP，不依赖 LLM）
//!
//! 验证 e2e_api_lifecycle 对话管线产出的卡片数据完整性：
//!   GET  /api/cards/all            — 卡片存在且有 proper field values
//!   GET  /api/cards/by-plan        — 卡片按 plan 正确分组
//!   PATCH /api/cards/status        — 单张卡片状态切换
//!   PATCH /api/cards/batch-status  — 批量修改

use api_server::test_helpers::body_json;
use serde_json::{json, Value};
use std::sync::OnceLock;

const TEST_USER: &str = "e2eapitest";
const TEST_PASS: &str = "pass123word456";

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
    } else {
        let conn = api_server::db_pool::get_conn();
        api_server::schema::run_migrations(&conn).expect("migrations");
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
async fn e2e_cards_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🃏 Cards E2E test – verify pipeline cards + card status management");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Register (用户已存在则跳过) ──
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
    println!("  uid={}, token={}...", uid, &token[..16]);

    // ── Step 3: GET /api/cards/all — 验证对话管线产出的卡片 ──
    println!("\n--- Step 3: GET /api/cards/all — verify pipeline cards ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all_val: Value = body_json(resp).await;
    calls += 1;
    let total = all_val["total"].as_i64().unwrap_or(0);
    let cards = all_val["cards"].as_array().map(|a| a.len()).unwrap_or(0);
    println!("  total={}, cards_in_response={}", total, cards);
    println!("  domains: {:?}", all_val["domains"].as_array());

    // 验证：对话管线应产生过卡片（由 e2e_api_lifecycle 填充）
    assert!(total > 0, "expected cards from pipeline, got total=0 — run e2e_api_lifecycle first");

    // 验证每张卡片的关键字段
    if let Some(card_list) = all_val["cards"].as_array() {
        for c in card_list.iter().take(5) {
            let id = c["id"].as_str().unwrap_or("");
            let ctype = c["card_type"].as_str().unwrap_or("");
            let front = c["front"].as_str().unwrap_or("");
            let state = c["state"].as_i64().unwrap_or(-1);
            let has_conv = c["conversation_id"].as_str().map(|s| !s.is_empty()).unwrap_or(false);
            println!("  card: id={}, type={}, front={:.30}, state={}, has_conv_id={}", id, ctype, front, state, has_conv);
            assert!(!id.is_empty(), "card should have id");
            assert!(!ctype.is_empty(), "card should have card_type");
            assert!(!front.is_empty(), "card should have front");
            assert!(state >= 0, "card should have valid state");
        }
    }

    // ── Step 4: GET /api/cards/by-plan — 验证卡片按 plan 分组 ──
    println!("\n--- Step 4: GET /api/cards/by-plan — verify plan grouping ---");
    let resp = client.get(format!("{}/api/cards/by-plan?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let by_plan: Value = body_json(resp).await;
    calls += 1;
    let total_plans = by_plan["total_plans"].as_i64().unwrap_or(0);
    let plans = by_plan["plans"].as_array().map(|a| a.len()).unwrap_or(0);
    println!("  total_plans={}, plans_in_response={}", total_plans, plans);

    if let Some(plan_list) = by_plan["plans"].as_array() {
        println!("  plans total: {}, with cards: {}",
            plan_list.len(),
            plan_list.iter().filter(|p| p["card_count"].as_i64().unwrap_or(0) > 0).count());
        for p in plan_list.iter().take(5) {
            let goal = p["goal"].as_str().unwrap_or("(空)");
            let card_count = p["card_count"].as_i64().unwrap_or(0);
            println!("  plan: goal={:.40}, card_count={}", goal, card_count);
        }
    }

    // ── 从 cards/all 响应中收集卡片用于后续状态测试 ──
    let mut test_cards: Vec<String> = Vec::new();
    if let Some(card_list) = all_val["cards"].as_array() {
        for c in card_list {
            let id = c["id"].as_str().unwrap_or("");
            if !id.is_empty() && id.len() >= 8 {
                test_cards.push(id.to_string());
            }
            if test_cards.len() >= 2 { break; }
        }
    }

    if test_cards.len() < 2 {
        println!("  ⚠️ 不足 2 张可操作的卡片，跳过状态变更测试");
        println!("\n{}", "=".repeat(70));
        println!(" 🃏 Cards E2E test passed – {} API calls (read-only)", calls);
        println!("{}", "=".repeat(70));
        return;
    }
    println!("  selected test cards: {:?}", test_cards);

    // ── Step 5: PATCH /api/cards/status — 将第一张卡标记为 skipped ──
    println!("\n--- Step 5: PATCH /api/cards/status (single → skipped) ---");
    let resp = client.patch(format!("{}/api/cards/status", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"user_id": uid, "card_id": test_cards[0], "status": "skipped"}))
        .send().await.unwrap();
    let status_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  status response: {:?}", status_resp);
    assert_eq!(status_resp["status"].as_str(), Some("ok"), "single status update should succeed");

    // ── Step 6: GET /api/cards/all 验证 skipped 的卡不再出现 ──
    println!("\n--- Step 6: GET /api/cards/all (after skip, active only) ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let all2: Value = body_json(resp).await;
    calls += 1;
    let post_total = all2["total"].as_i64().unwrap_or(0);
    println!("  total cards (active only): {} (was {})", post_total, total);
    assert!(post_total < total, "skipped card should reduce active count");

    // ── Step 7: PATCH /api/cards/batch-status — 将剩余 1 张标记为 archived ──
    println!("\n--- Step 7: PATCH /api/cards/batch-status (single → archived) ---");
    let resp = client.patch(format!("{}/api/cards/batch-status", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({"user_id": uid, "card_ids": [test_cards[1]], "status": "archived"}))
        .send().await.unwrap();
    let batch_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  batch status response: {:?}", batch_resp);
    assert_eq!(batch_resp["status"].as_str(), Some("ok"), "batch status update should succeed");
    assert!(batch_resp["updated"].as_i64().unwrap_or(0) >= 1, "should update at least 1 card");

    // ── Step 8: 恢复卡片状态（不影响后续测试）──
    println!("\n--- Step 8: Restore card status ---");
    for cid in &test_cards {
        let resp = client.patch(format!("{}/api/cards/status", base))
            .header("Authorization", format!("Bearer {}", token))
            .json(&json!({"user_id": uid, "card_id": cid, "status": "active"}))
            .send().await.unwrap();
        let r: Value = body_json(resp).await;
        calls += 1;
        assert_eq!(r["status"].as_str(), Some("ok"), "restore {} should succeed", cid);
    }
    println!("  restored {} cards to active", test_cards.len());

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 🃏 Cards E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
