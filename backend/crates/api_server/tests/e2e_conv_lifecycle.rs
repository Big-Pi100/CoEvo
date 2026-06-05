//! E2E 对话管理测试（纯 HTTP，不依赖 LLM）
//!
//! 连 production DB，对 e2e_api_lifecycle 产出的真实对话做软删除/恢复/彻底删除验证。
//! 同时作为管线前置清理：彻底删除旧测试对话，让 e2e_api_lifecycle 从干净状态开始。
//!
//! 覆盖:
//!   DELETE /api/conversations/{conv_id}         — 软删除
//!   POST  /api/conversations/{conv_id}/restore   — 恢复
//!   DELETE /api/conversations/{conv_id}/permanent — 彻底删除
//!   GET  /api/history                            — 验证三种状态

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

/// 获取用户对话列表。mode: "active" | "only" (deleted only) | "all"
async fn get_convs(client: &reqwest::Client, base: &str, uid: &str, token: &str, mode: &str) -> Vec<String> {
    let url = match mode {
        "only" => format!("{}/api/history?user_id={}&include_deleted=only", base, uid),
        "all" => format!("{}/api/history?user_id={}&include_deleted=true", base, uid),
        _ => format!("{}/api/history?user_id={}", base, uid),
    };
    let resp = client.get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist: Value = body_json(resp).await;
    hist["conversations"].as_array()
        .map(|a| a.iter().filter_map(|c| c["id"].as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}

#[tokio::test]
#[ignore]
async fn e2e_conv_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 💬 Conversation E2E test – cleanup pipeline convs: soft delete → restore → permanent delete");
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

    // ── Step 3: 获取用户的活跃对话（由 e2e_api_lifecycle 产生）──
    println!("\n--- Step 3: Get active conversations ---");
    let active_convs = get_convs(&client, &base, &uid, &token, "active").await;
    calls += 1;
    println!("  active conversations: {:?}", active_convs);

    if active_convs.is_empty() {
        // 无活跃对话，但可能有软删除的旧测试数据，仍需清理
        println!("  ⚠️ no active conversations, checking soft-deleted...");
        let deleted_convs = get_convs(&client, &base, &uid, &token, "only").await;
        calls += 1;
        if deleted_convs.is_empty() {
            println!("  no soft-deleted conversations either, skip");
            println!("\n{}", "=".repeat(70));
            println!(" 💬 Conversation E2E test skipped – no pipeline conversations");
            println!("{}", "=".repeat(70));
            return;
        }
        println!("  found {} soft-deleted conversations, permanent deleting...", deleted_convs.len());
        for cid in &deleted_convs {
            let resp = client.delete(format!("{}/api/conversations/{}/permanent", base, cid))
                .header("Authorization", format!("Bearer {}", token))
                .query(&[("user_id", uid.as_str())])
                .send().await;
            calls += 1;
            println!("  permanent delete {}: {:?}", cid, resp.map(|r| r.status()));
        }
        println!("\n{}", "=".repeat(70));
        println!(" 💬 Conversation E2E test – cleaned {} soft-deleted conversations", deleted_convs.len());
        println!("{}", "=".repeat(70));
        return;
    }

    let test_conv = &active_convs[0];
    let before_count = active_convs.len();
    println!("  selected test conv: {}, total active: {}", test_conv, before_count);

    // ── Step 4: DELETE 软删除对话 ──
    println!("\n--- Step 4: DELETE /api/conversations/{} (soft delete) ---", test_conv);
    let resp = client.delete(format!("{}/api/conversations/{}", base, test_conv))
        .header("Authorization", format!("Bearer {}", token))
        .query(&[("user_id", uid.as_str())])
        .send().await.unwrap();
    let del: Value = body_json(resp).await;
    calls += 1;
    println!("  delete response: {:?}", del);
    assert_eq!(del["status"].as_str(), Some("ok"), "soft delete should succeed");
    assert!(del["deleted_at"].is_number(), "deleted_at should be set");

    // ── Step 5: 验证对话不在活跃列表中 ──
    println!("\n--- Step 5: Verify conv not in active list ---");
    let active_after_del = get_convs(&client, &base, &uid, &token, "active").await;
    calls += 1;
    println!("  active conversations: {} (was {})", active_after_del.len(), before_count);
    assert!(!active_after_del.contains(test_conv), "conv should not appear after soft delete");

    // ── Step 6: 验证在回收站中 ──
    println!("\n--- Step 6: Verify in deleted list ---");
    let deleted_convs = get_convs(&client, &base, &uid, &token, "only").await;
    calls += 1;
    println!("  deleted conversations: {}", deleted_convs.len());
    assert!(deleted_convs.contains(test_conv), "conv should appear in deleted list");

    // ── Step 7: POST restore 恢复对话 ──
    println!("\n--- Step 7: POST restore ---");
    let resp = client.post(format!("{}/api/conversations/{}/restore", base, test_conv))
        .header("Authorization", format!("Bearer {}", token))
        .query(&[("user_id", uid.as_str())])
        .send().await.unwrap();
    calls += 1;
    println!("  restore status: {}", resp.status());
    assert_eq!(resp.status().as_u16(), 200, "restore should return 200");

    // ── Step 8: 验证对话回来了 ──
    println!("\n--- Step 8: Verify conv restored ---");
    let after_restore = get_convs(&client, &base, &uid, &token, "active").await;
    calls += 1;
    println!("  active conversations: {} (should = {})", after_restore.len(), before_count);
    assert!(after_restore.contains(test_conv), "conv should be back after restore");
    assert_eq!(after_restore.len(), before_count, "restore should return to original count");

    // ── Step 9: 永久删除全部活跃对话（清理管线数据）──
    // e2e_api_lifecycle 不在测试中自行删除对话，
    // 由本测试在每次运行前负责清理，保证从干净状态开始。
    // 用户也可以选择不运行本测试，手动登录查看管线数据。
    println!("\n--- Step 9: Permanent delete ALL active conversations (cleanup) ---");
    for cid in &after_restore {
        let resp = client.delete(format!("{}/api/conversations/{}/permanent", base, cid))
            .header("Authorization", format!("Bearer {}", token))
            .query(&[("user_id", uid.as_str())])
            .send().await;
        calls += 1;
        if let Ok(r) = resp {
            println!("  permanent delete {}: status={}", cid, r.status());
        }
    }

    // ── Step 10: 验证所有对话被清理 ──
    println!("\n--- Step 10: Verify all cleaned up ---");
    let all_after = get_convs(&client, &base, &uid, &token, "all").await;
    calls += 1;
    println!("  all remaining conversations ({:?}): {}", all_after, all_after.len());
    // 允许剩余 0-1 个对话（并发测试可能产生额外的）
    assert!(all_after.len() <= 1, "all but at most 1 test conversation should be gone, got {}", all_after.len());

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 💬 Conversation E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
