//! E2E 复习流程全生命周期测试（纯 HTTP）
//!
//! 覆盖 4 个复习端点:
//!   GET  /api/review/due    — 查询到期卡片
//!   POST /api/review/verify — 获取验证题
//!   POST /api/review/judge  — 批改答案
//!   POST /api/review/submit — 提交评分
//!
//! 前置条件: 通过自由对话触发 CP1 创建卡片

use serde_json::{json, Value};
use student_llm::{student_speak, DEFAULT_PROMPT};
use std::sync::OnceLock;

const TEST_USER: &str = "reviewuser";
const TEST_PASS: &str = "reviewpass123";
const TEST_CONV: &str = "review-test-conv";
const MAX_DIALOGUE_ROUNDS: usize = 2;  // 仅需少量对话触发 CP1
const TIMEOUT_MINS: u64 = 10;

// 学生提示词由 student_llm crate 统一管理（DEFAULT_PROMPT），见 prompts/student/default.md

/// 每轮诊断数据
struct TurnDiag {
    label: String,
    user_msg: String,
    teacher_reply: String,
    student_reply: String,
    candidates: usize,
    plan_updated: bool,
    cp1_concepts: Vec<String>,
    plan_state_after: Option<String>,  // after this turn, what's the plan state
    system_prompt: String,             // 教学 LLM 系统提示词
    user_content: String,              // 教学 LLM 输入（含 plan context）
}

static INIT: OnceLock<()> = OnceLock::new();

/// 启动 API server 并返回 base URL
async fn start_server() -> String {
    // Load env first
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }

    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });

    // 独立测试 DB
    let db_path = format!("data/test_api_{}.db", chrono::Utc::now().timestamp());
    let _ = std::fs::remove_file(&db_path);
    api_server::db_pool::init(&db_path).expect("init db");

    // 初始化 schema（从 main.rs SCHEMA_SQL 同步）
    let conn = api_server::db_pool::get_conn();
    let sql = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/schema.sql"));
    conn.execute_batch(&sql).expect("schema init");
    // 确保所有 CREATE TABLE 有 IF NOT EXISTS（schema.sql 中部分表缺少）
    conn.execute_batch("
        CREATE TABLE IF NOT EXISTS user_preferences (
            user_id TEXT NOT NULL, key TEXT NOT NULL,
            value TEXT NOT NULL, updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, key),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );"
    ).expect("user_preferences table");

    // Build router + start server
    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);

    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    base
}

/// 解析响应 body 为 JSON
async fn body_json(resp: reqwest::Response) -> Value {
    resp.json().await.unwrap_or(json!({"raw": "parse failed"}))
}

#[tokio::test]
#[ignore]
async fn e2e_review_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🔄 Review E2E test – pure HTTP review lifecycle");
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
    assert!(reg["user_id"].is_string(), "register should return user_id");
    let uid = reg["user_id"].as_str().unwrap().to_string();
    println!("  user_id={}", uid);

    // ── Step 2: Login (get auth token) ──
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": TEST_USER, "password": TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let token = login["token"].as_str().unwrap_or("").to_string();
    assert!(!token.is_empty(), "login should return token");
    println!("  token={}..", &token[..token.len().min(16)]);

    // ── Step 3: Set subscription (user_preferences API) ──
    println!("\n--- Step 3: Set subscription ---");
    let expires = (chrono::Utc::now() + chrono::Duration::days(365)).to_rfc3339();
    let resp = client.put(format!("{}/api/user/{}/preferences", base, uid))
        .json(&json!({"subscription_expires": expires}))
        .send().await.unwrap();
    let sub: Value = body_json(resp).await;
    calls += 1;
    println!("  subscription: {:?}", sub);

    // ── Step 4: 初始对话 + 双 LLM 推进 ──
    println!("\n--- Step 4: Chat (dual-LLM dialogue) ---");
    let run_id = format!("e2e_api_{}", chrono::Utc::now().format("%Y%m%d_%H%M%S"));
    let report_dir = format!("data/eval_runs/{}", run_id);
    let _ = std::fs::create_dir_all(&report_dir);

    let start_time = std::time::Instant::now();
    let api_key = std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY");
    let mut student_cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    student_cfg.temperature = 0.3;

    let mut plan_created = false;
    let mut turn_diags: Vec<TurnDiag> = Vec::new();

    // 启用 LLM 输入日志（服务器端记录，测试通过 drain 读取）
    api_server::plan_handler::enable_context_log();

    /// 检查 plan 状态（通过 API）
    async fn check_plan_state(client: &reqwest::Client, base: &str, conv: &str, token: &str, _uid: &str, calls: &mut u32) -> Option<String> {
        let resp = client.get(format!("{}/api/plans?conversation_id={}", base, conv))
            .header("Authorization", format!("Bearer {}", token))
            .send().await.ok()?;
        *calls += 1;
        let val: Value = body_json(resp).await;
        let list = val["plans"].as_array()?;
        list.first().map(|p| serde_json::to_string_pretty(p).unwrap_or_default())
    }

    /// 检查候选人名（截断版）
    fn fmt_candidates(chat: &Value, max: usize) -> Vec<String> {
        chat["candidates"].as_array().map(|a| {
            a.iter().map(|c| {
                let s = c.as_str().unwrap_or("?");
                let chars: Vec<char> = s.chars().collect();
                if chars.len() > max { format!("{}...", chars[..max].iter().collect::<String>()) } else { s.to_string() }
            }).collect()
        }).unwrap_or_default()
    }

    /// 从日志缓冲区提取最新 LLM 输入（无 DB 访问）
    fn capture_llm_input() -> (String, String) {
        api_server::plan_handler::drain_llm_input_log()
            .pop()
            .unwrap_or_default()
    }

    // 4a. 首条消息：触发 CP2 创建计划
    let initial_msgs = [
        ("Hello, I want to learn the Pythagorean theorem.", false),
        ("OK, please make a study plan for me.", false),
    ];
    for (i, (msg, _)) in initial_msgs.iter().enumerate() {
        let resp = client.post(format!("{}/api/chat", base))
            .header("Authorization", format!("Bearer {}", token))
            .json(&json!({
                "user_id": uid, "conversation_id": TEST_CONV, "message": msg,
            }))
            .send().await.unwrap();
        let chat: Value = body_json(resp).await;
        calls += 1;
        let reply = chat["reply"].as_str().unwrap_or("").to_string();
        let updated = chat["plan_updated"].as_bool().unwrap_or(false);
        let err = chat["error"].as_str().map(|s| s.to_string());
        let candidates = fmt_candidates(&chat, 50);
        let label = format!("创建计划(对话{})", i+1);
        let plan_state = if updated { check_plan_state(&client, &base, TEST_CONV, &token, &uid, &mut calls).await } else { None };
        assert!(err.is_none(), "chat API error: {:?}", err);
        if updated { plan_created = true; }
        let (sys_prompt, user_content) = capture_llm_input();
        turn_diags.push(TurnDiag {
            label, user_msg: msg.to_string(), teacher_reply: reply,
            student_reply: String::new(), candidates: candidates.len(),
            plan_updated: updated, cp1_concepts: candidates, plan_state_after: plan_state,
            system_prompt: sys_prompt, user_content,
        });
    }

    // 4b. 双 LLM 学生模拟循环
    let mut round = 0usize;
    let max_duration = std::time::Duration::from_secs(TIMEOUT_MINS * 60);
    while round < MAX_DIALOGUE_ROUNDS && start_time.elapsed() < max_duration {
        round += 1;

        // 获取完整对话历史
        let hist_resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, TEST_CONV))
            .header("Authorization", format!("Bearer {}", token))
            .send().await.unwrap();
        let hist_val: Value = body_json(hist_resp).await;
        calls += 1;
        let raw_turns: Vec<(String, String)> = match hist_val["turns"].as_array() {
            Some(arr) => arr.iter().filter_map(|t| {
                let role = t["role"].as_str()?;
                let content = t["content"].as_str()?;
                Some((role.to_string(), content.to_string()))
            }).collect(),
            None => vec![],
        };

        // 构建学生输入上下文：只取最后一轮教师回复，标注角色来源
        // raw_turns 来自 /api/history，默认 ORDER BY created_at DESC（最新在前）
        let student_input = raw_turns.iter()
            .find(|(role, _)| role == "assistant")
            .map(|(_, content)| format!("assistant: {}", content))
            .unwrap_or_default();

        // 学生 LLM 生成回应
        let mut student_caller = chat_engine::llm_caller::LlmCaller::new(student_cfg.clone());
        let student_msg = student_speak(&mut student_caller, DEFAULT_PROMPT, &student_input).await;
        assert!(!student_msg.is_empty(), "student LLM returned empty response at round {}", round);

        // 发送学生消息
        let active_msg = student_msg;
        let chat_resp = client.post(format!("{}/api/chat", base))
            .header("Authorization", format!("Bearer {}", token))
            .json(&json!({
                "user_id": uid, "conversation_id": TEST_CONV, "message": active_msg,
            }))
            .send().await.unwrap();
        let chat_val: Value = body_json(chat_resp).await;
        calls += 1;
        if let Some(err) = chat_val["error"].as_str() {
            eprintln!("  ⚠️ chat error after student msg: {}", err);
            break;
        }
        let teacher_reply = chat_val["reply"].as_str().unwrap_or("").to_string();
        let updated = chat_val["plan_updated"].as_bool().unwrap_or(false);
        if updated { plan_created = true; }
        let candidates = fmt_candidates(&chat_val, 50);
        let label = format!("双LLM轮{}", round);
        let plan_state = if updated { check_plan_state(&client, &base, TEST_CONV, &token, &uid, &mut calls).await } else { None };
        let (sys_prompt, user_content) = capture_llm_input();
        turn_diags.push(TurnDiag {
            label, user_msg: active_msg, teacher_reply,
            student_reply: String::new(), candidates: candidates.len(),
            plan_updated: updated, cp1_concepts: candidates, plan_state_after: plan_state,
            system_prompt: sys_prompt, user_content,
        });
    }

    // ── Step 5: Verify cards exist ──
    println!("\n--- Step 5: Verify cards ---");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let cards_resp: Value = body_json(resp).await;
    calls += 1;
    let active_cards = cards_resp["cards"].as_array().map(|a| a.len()).unwrap_or(0);
    println!("  active_cards: {} (CP1 OK)", active_cards);
    assert!(active_cards > 0, "CP1 should create at least 1 card, got {}", active_cards);

    // ── Step 6: Review due cards ──
    println!("\n--- Step 6: GET /api/review/due ---");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = client.get(format!("{}/api/review/due?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let due_resp: Value = body_json(resp).await;
    calls += 1;
    let due_cards = due_resp["cards"].as_array().unwrap();
    let total_due = due_resp["total_due"].as_i64().unwrap_or(0);
    println!("  due_cards: {}, total_due: {}", due_cards.len(), total_due);
    assert!(total_due > 0, "should have due cards for review");
    // 验证新字段存在
    if let Some(first) = due_cards.first() {
        println!("  sample: id={}, difficulty={}, due={}, lapses={}",
            first["id"].as_str().unwrap_or(""),
            first["difficulty"].as_f64().unwrap_or(-1.0),
            first["due"].as_i64().unwrap_or(-1),
            first["lapses"].as_i64().unwrap_or(-1));
        assert!(first["difficulty"].as_f64().is_some(), "difficulty should be present");
        assert!(first["due"].as_i64().is_some(), "due should be present");
    }

    // ── Step 7: Review verify (generate questions) ──
    println!("
--- Step 7: POST /api/review/verify ---");
    let first_card = due_cards.first().unwrap();
    let card_id = first_card["id"].as_str().unwrap();
    let front = first_card["front"].as_str().unwrap_or("");
    let back = first_card["back"].as_str().unwrap_or("");
    let resp = client.post(format!("{}/api/review/verify", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid, "card_id": card_id, "front": front, "back": back,
        }))
        .send().await.unwrap();
    let verify_resp: Value = body_json(resp).await;
    calls += 1;
    let questions = verify_resp["questions"].as_array()
        .expect("verify should return questions array");
    println!("  questions: {} (card={})", questions.len(), card_id);
    assert_eq!(questions.len(), 3, "should generate 3 questions");

    // ── Step 8: Review judge (grade answers) ──
    println!("
--- Step 8: POST /api/review/judge ---");
    let judge_questions: Vec<serde_json::Value> = questions.iter().enumerate().map(|(i, q)| {
        let expected = q["expected_answer"].as_str().unwrap_or("");
        json!({
            "question": q["question"].as_str().unwrap_or(""),
            "expected_answer": expected,
            "user_answer": if i == 0 { expected.to_string() } else { format!("wrong answer {}", i) },
        })
    }).collect();
    let resp = client.post(format!("{}/api/review/judge", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid, "card_id": card_id, "questions": judge_questions,
        }))
        .send().await.unwrap();
    let judge_resp: Value = body_json(resp).await;
    calls += 1;
    let results = judge_resp["results"].as_array()
        .expect("judge should return results array");
    println!("  judged: {} results", results.len());
    assert_eq!(results.len(), 3, "should judge all 3 questions");
    assert_eq!(results[0]["correct"].as_bool().unwrap_or(false), true, "first answer should be correct");
    assert!(results[0]["feedback"].as_str().is_some(), "each result should have feedback");

    // ── Step 9: Review submit (FSRS + achievements) ──
    println!("
--- Step 9: POST /api/review/submit ---");
    let resp = client.post(format!("{}/api/review/submit", base))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid,
            "card_id": card_id,
            "rating": 3,
            "verification_type": "ai_dialogue",
            "verification_result": "pass",
        }))
        .send().await.unwrap();
    let submit_resp: Value = body_json(resp).await;
    calls += 1;
    println!("  submit: {:?}", submit_resp);
    assert_eq!(submit_resp["status"].as_str(), Some("ok"), "submit should succeed");

    // ── Summary ──
    println!("
{}", "=".repeat(70));
    println!(" 🔄 Review E2E test passed – {} API calls", calls);
    println!("{}", "=".repeat(70));
}
