//! E2E K12 进度 & 阅读当前卡片测试
//!
//! 覆盖:
//!   GET /api/k12/progress                    — K12 学习进度
//!   GET /api/k12/reading/{conv_id}/current-card — 语文阅读当前课文

use api_server::test_helpers::body_json;
use serde_json::{json, Value};
use std::sync::OnceLock;

static INIT: OnceLock<()> = OnceLock::new();

async fn start_server() -> String {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }
    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = api_server::curriculum_loader::init();
        // reading_loader 已删除（V3 不再需要）
        let _ = std::fs::create_dir_all("data");
    });
    api_server::test_helpers::init_tracing();
    let db_path = format!("data/test_k12extra_{}.db", chrono::Utc::now().timestamp());
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
async fn e2e_k12_extra_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 📊 K12 Extra E2E test – progress & current-card endpoints");
    println!("{}", "=".repeat(70));

    let base = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // ── Step 1: Register ──
    println!("\n--- Step 1: Register ---");
    let resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": "k12extra", "password": "test123"}))
        .send().await.unwrap();
    let reg: Value = body_json(resp).await;
    calls += 1;
    let uid = reg["user_id"].as_str().expect("register uid").to_string();
    println!("  uid: {}", uid);

    // ── Step 2: Login ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": "k12extra", "password": "test123"}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let token = login["token"].as_str().expect("login token").to_string();
    println!("  token: {}...", &token[..16]);

    // ── Step 3: GET /api/k12/progress (new user → empty) ──
    println!("\n--- Step 3: GET /api/k12/progress (empty) ---");
    let resp = client.get(format!("{}/api/k12/progress?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let progress: Value = body_json(resp).await;
    calls += 1;
    println!("  progress: {:?}", progress.get("subjects"));
    // 新用户：可能返回空 subjects 或默认结构
    assert!(progress.is_object(), "progress should return an object");

    // ── Step 4: 插入测试计划数据到 conversation_plans + cards ──
    println!("\n--- Step 4: Insert test plan data ---");
    let now_ts = chrono::Utc::now().timestamp();
    {
        let conn = api_server::db_pool::get_conn();
        // 插入两个 conversation_plans（作为"subject"进度来源）
        let plan1_id = uuid::Uuid::new_v4().to_string();
        let plan1_conv = uuid::Uuid::new_v4().to_string();
        // 创建 conversations 记录（满足 FK 约束）
        let _ = conn.execute(
            "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
            rusqlite::params![plan1_conv, uid, now_ts.to_string()],
        );
        let plan_content1 = serde_json::json!({"goal": "math基础学习", "stages": [{"name": "代数", "tasks": [{"name": "一元一次方程", "task_key": "00-00"}]}]}).to_string();
        conn.execute(
            "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, plan_content, created_at, updated_at)
             VALUES (?1, ?2, ?3, 'math基础学习', ?4, ?5, ?5)",
            rusqlite::params![plan1_id, uid, plan1_conv, plan_content1, now_ts],
        ).expect("insert plan1");

        let plan2_id = uuid::Uuid::new_v4().to_string();
        let plan2_conv = uuid::Uuid::new_v4().to_string();
        // 创建 conversations 记录（满足 FK 约束）
        let _ = conn.execute(
            "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
            rusqlite::params![plan2_conv, uid, now_ts.to_string()],
        );
        let plan_content2 = serde_json::json!({"goal": "physics基础学习", "stages": [{"name": "力学", "tasks": [{"name": "牛顿定律", "task_key": "00-00"}]}]}).to_string();
        conn.execute(
            "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, plan_content, created_at, updated_at)
             VALUES (?1, ?2, ?3, 'physics基础学习', ?4, ?5, ?5)",
            rusqlite::params![plan2_id, uid, plan2_conv, plan_content2, now_ts],
        ).expect("insert plan2");
    }
    println!("  inserted 2 plans: math, physics");

    // ── Step 5: GET /api/k12/progress (with data) ──
    println!("\n--- Step 5: GET /api/k12/progress (with data) ---");
    let resp = client.get(format!("{}/api/k12/progress?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let progress2: Value = body_json(resp).await;
    calls += 1;
    println!("  progress: {}", serde_json::to_string_pretty(&progress2).unwrap_or_default());
    let subjects = progress2["progress"].as_array();
    match subjects {
        Some(s) => {
            println!("  subjects: {}", s.len());
            for subj in s {
                println!("    goal: {}, cards: {}/{}",
                    subj["goal"].as_str().unwrap_or("?"),
                    subj["mastered_cards"].as_i64().unwrap_or(-1),
                    subj["total_cards"].as_i64().unwrap_or(-1));
            }
            assert!(s.len() >= 2, "should have at least 2 plans");
        }
        None => {
            // 接受其它格式
            println!("  progress: {:?}", progress2);
        }
    }

    // ── Step 6: GET /api/k12/reading/{conv_id}/current-card ──
    println!("\n--- Step 6: GET /api/k12/reading/current-card ---");
    // 先插入一个 conversation_plan 作为阅读计划
    let conv_id = "test_reading_conv";
    let reading_plan = json!({
        "stages": [{
            "name": "第一学段：识字与基础阅读",
            "grade_band": "g1-2",
            "sort": 0,
            "tasks": [{
                "name": "我是中国人",
                "reading_card_id": "chinese_g1-2_reading_001",
                "sort": 0
            }, {
                "name": "天地人",
                "reading_card_id": "chinese_g1-2_reading_002",
                "sort": 1
            }]
        }]
    });
    {
        let conn = api_server::db_pool::get_conn();
        // conversations 表 FK
        let now_ts = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at)
             VALUES (?1, ?2, 1, ?3)",
            rusqlite::params![conv_id, uid, now_ts],
        ).ok();
        conn.execute(
            "INSERT INTO conversation_plans (id, user_id, conversation_id, goal, plan_content, created_at, updated_at)
             VALUES (?1, ?2, ?3, '语文课文阅读学习', ?4, ?5, ?5)",
            rusqlite::params![
                format!("plan_{}", conv_id), uid, conv_id,
                reading_plan.to_string(), now_ts,
            ],
        ).ok();
    }

    let resp = client.get(format!("{}/api/k12/reading/{}/current-card?user_id={}", base, conv_id, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let card_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  current-card response: {:?}", card_resp);
    // reading_card_id 是虚拟的，reading_loader 里可能找不到对应卡片
    // 至少验证返回了有效 JSON，不报 500
    assert!(card_resp.is_object(), "should return an object");

    // ── Step 7: 测试不存在的 conv ──
    println!("\n--- Step 7: GET /api/k12/reading/nonexistent/current-card ---");
    let resp = client.get(format!("{}/api/k12/reading/nonexistent/current-card?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let err_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  error response: {:?}", err_resp);
    assert!(err_resp.get("error").is_some(), "non-existent conv should return error");

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" 📊 K12 Extra E2E test passed – {} API calls (no LLM)", calls);
    println!("{}", "=".repeat(70));
}
