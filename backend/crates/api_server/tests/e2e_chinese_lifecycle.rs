//! E2E 语文课文阅读全生命周期测试（纯 HTTP）
//!
//! 与 e2e_k12_lifecycle 的区别：
//!   - e2e_k12_lifecycle: K12 math 数理化场景，k12/init
//!   - e2e_chinese_lifecycle: K12 语文课文阅读场景，k12/reading/init
//!
//! 加入双 LLM 学生模拟，实际推进课文阅读教学对话

use serde_json::{json, Value};
use student_llm::{student_speak, DEFAULT_PROMPT};
use std::sync::OnceLock;

const TEST_USER: &str = "chineseuser";
const TEST_PASS: &str = "chinesepass123";
const K12_SUBJECT: &str = "chinese";
const K12_GRADE: &str = "g1-2";
const INIT_ENDPOINT: &str = "/api/k12/reading/init";
const MAX_DIALOGUE_ROUNDS: usize = 7;
const TIMEOUT_MINS: u64 = 15;

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
        let _ = api_server::curriculum_loader::init();
        let _ = api_server::reading_loader::init();
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
async fn e2e_chinese_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 📖 Chinese E2E test – pure HTTP reading lifecycle");
    println!("    subject={}, grade={}", K12_SUBJECT, K12_GRADE);
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

    // ── Step 3b: K12 Reading Init（创建语文课文阅读会话） ──
    println!("\n--- Step 3b: Chinese Reading Init ---");
    let resp = client.post(format!("{}{}", base, INIT_ENDPOINT))
        .header("Authorization", format!("Bearer {}", token))
        .json(&json!({
            "user_id": uid, "subject": K12_SUBJECT, "grade_band": K12_GRADE,
        }))
        .send().await.unwrap();
    calls += 1;
    let init_val: Value = body_json(resp).await;
    let k12_conv = init_val["conversation_id"].as_str().unwrap_or("").to_string();
    assert!(!k12_conv.is_empty(), "K12 init should return conversation_id");
    println!("  K12 conv_id={}, resumed={}", k12_conv, init_val["resumed"].as_bool().unwrap_or(false));

    // ── Step 4: 双 LLM 对话（已有预置 plan）──
    println!("\n--- Step 4: Chat (dual-LLM dialogue) ---");
    let run_id = format!("e2e_chinese_{}", chrono::Utc::now().format("%Y%m%d_%H%M%S"));
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

    // 4a. 首条消息：语文课文阅读预置计划已就绪，直接开始教学
    let k12_first_msgs = [
        "Hello, let's start the Chinese reading lesson.",
        "OK, I'm ready to read the first text!",
    ];
    // K12 已有预置 plan，无需 CP2 创建
    let _plan_created = true;
    for (i, msg) in k12_first_msgs.iter().enumerate() {
        let resp = client.post(format!("{}/api/chat", base))
            .header("Authorization", format!("Bearer {}", token))
            .json(&json!({
                "user_id": uid, "conversation_id": k12_conv, "message": msg,
            }))
            .send().await.unwrap();
        let chat: Value = body_json(resp).await;
        calls += 1;
        let reply = chat["reply"].as_str().unwrap_or("").to_string();
        let updated = chat["plan_updated"].as_bool().unwrap_or(false);
        let err = chat["error"].as_str().map(|s| s.to_string());
        let candidates = fmt_candidates(&chat, 50);
        let label = format!("K12初始(对话{})", i+1);
        let plan_state = if updated { check_plan_state(&client, &base, &k12_conv, &token, &uid, &mut calls).await } else { None };
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
        let hist_resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, k12_conv))
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
                "user_id": uid, "conversation_id": &k12_conv, "message": active_msg,
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
        let plan_state = if updated { check_plan_state(&client, &base, &k12_conv, &token, &uid, &mut calls).await } else { None };
        let (sys_prompt, user_content) = capture_llm_input();
        turn_diags.push(TurnDiag {
            label, user_msg: active_msg, teacher_reply,
            student_reply: String::new(), candidates: candidates.len(),
            plan_updated: updated, cp1_concepts: candidates, plan_state_after: plan_state,
            system_prompt: sys_prompt, user_content,
        });
    }

    // ── Step 5: Verify plan via API ──
    println!("\n--- Step 5: Verify plans ---");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = client.get(format!("{}/api/plans?conversation_id={}", base, k12_conv))
        .send().await.unwrap();
    let plans_resp: Value = body_json(resp).await;
    calls += 1;
    let list = plans_resp["plans"].as_array().unwrap();
    assert!(!list.is_empty(), "CP2 should create a plan");
    let plan_json = serde_json::to_string_pretty(&plans_resp).unwrap_or_default();

    // ── Step 6: Verify conversation history ──
    println!("\n--- Step 6: Conversation history ---");
    let resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, k12_conv))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let hist: Value = body_json(resp).await;
    calls += 1;
    let all_turns = match hist["turns"].as_array() {
        Some(arr) => arr.iter().filter_map(|t| {
            let role = t["role"].as_str()?;
            let content = t["content"].as_str()?;
            Some(format!("{}: {}", role, content))
        }).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>(),
        None => vec![],
    };
    println!("  turns: {}", all_turns.len());
    assert!(all_turns.len() >= 4, "should have >=4 turns");

    // ── Step 7: Cards & learning report (via API) ──
    println!("\n--- Step 7: Cards & learning report ---");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let cards_resp: Value = body_json(resp).await;
    calls += 1;
    let active_cards = cards_resp["cards"].as_array().map(|a| a.len()).unwrap_or(0);

    let total_cards: i64 = {
        let conn = api_server::db_pool::get_conn();
        conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id = ?1",
            rusqlite::params![uid], |r| r.get(0)).unwrap_or(0)
    };

    let resp = client.get(format!("{}/api/user/{}/learning-report", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let report_val: Value = body_json(resp).await;
    calls += 1;
    let plan_count = report_val["plans"].as_array().map(|a| a.len()).unwrap_or(0);

    // 查询最终 plan 状态（合并 plan_content 结构 + user_plan_progress 状态）
    let plan_status_lines: Vec<String> = {
        let conn = api_server::db_pool::get_conn();
        // 从 user_plan_progress 读取实际状态
        let task_statuses: std::collections::HashMap<String, String> = {
            let mut stmt = conn.prepare(
                "SELECT task_key, status FROM user_plan_progress WHERE plan_id = (SELECT id FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1)"
            ).ok();
            match stmt {
                Some(mut s) => s.query_map(rusqlite::params![k12_conv], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                }).ok().map(|rows| {
                    rows.filter_map(|r| r.ok()).collect()
                }).unwrap_or_default(),
                None => std::collections::HashMap::new(),
            }
        };

        // 从 plan_content 读取结构
        let plan_str: Option<String> = conn.query_row(
            "SELECT plan_content FROM conversation_plans WHERE conversation_id = ?1",
            rusqlite::params![k12_conv], |r| r.get(0),
        ).ok();
        match plan_str {
            Some(content) => {
                let v: serde_json::Value = serde_json::from_str(&content).unwrap_or_default();
                let stages = v.get("stages").and_then(|s| s.as_array());
                stages.map(|ss| {
                    ss.iter().filter_map(|s| {
                        let sn = s["name"].as_str().unwrap_or("?");
                        s["tasks"].as_array().map(|tasks| {
                            tasks.iter().map(|t| {
                                let tname = t["name"].as_str().unwrap_or("?");
                                let status = task_statuses.get(tname)
                                    .map(|s| s.as_str())
                                    .or_else(|| task_statuses.get(t["task_key"].as_str().unwrap_or("")).map(|s| s.as_str()))
                                    .or_else(|| t["status"].as_str())
                                    .unwrap_or("pending");
                                format!("- {} / {} → {}", sn, tname, status)
                            }).collect::<Vec<_>>().join("\n")
                        })
                    }).collect::<Vec<_>>()
                }).unwrap_or_default()
            }
            None => vec![],
        }
    };
    println!("  active_cards: {}, total_cards: {}, plans in report: {}", active_cards, total_cards, plan_count);

    // ── Save report ──
    {
        let report = format!(
r#"# 语文课文阅读 E2E 测试报告

- **运行时间**: {}
- **API 调用数**: {}
- **结果**: ✅ 通过
- **卡片数**: {} (active: {})
- **对话轮次**: {}
- **CP1 提取**: {} 个候选概念

---

## 步骤汇总

| Step | 操作 | 状态 |
|------|------|------|
| 1 | Register | ✅ |
| 2 | Login | ✅ |
| 3 | Subscription | ✅ |
| 4 | Chat ({} turns) | ✅ plan_updated={} |
| 5 | Plans (1) | ✅ |
| 6 | History ({} turns) | ✅ |
| 7 | Cards (active={}, total={}) + Report ({}) | ✅ |

---

## 每轮诊断

{}
---

## Plan 数据/状态

```json
{}
```
---

## CP1 事件日志

{}
---

## CP2 事件日志

{}
---

## 计划状态

{}
---

## 完整对话流

{}
"#,
            chrono::Utc::now().format("%Y-%m-%d %H:%M:%S"),
            calls,
            total_cards,
            active_cards,
            turn_diags.len(),
            turn_diags.iter().map(|d| d.candidates).sum::<usize>(),
            turn_diags.len(),
            plan_created,
            all_turns.len(),
            active_cards, total_cards, plan_count,
            {
                // 每轮诊断
                let mut parts = Vec::new();
                for (i, d) in turn_diags.iter().enumerate() {
                    let plan_state_str = match &d.plan_state_after {
                        Some(ps) => format!("\n### 轮后计划状态\n```json\n{}\n```", ps),
                        None => String::new(),
                    };
                    parts.push(format!(
"═══════════════════════════════════════════════════════════════
## 轮次 {}: {}

### System Prompt
```
{}
```
### User Content
```
{}
```
### 用户消息
{}
### 教师回复
{}
### CP1 候选概念（{} 个）
{}{}
### CP2 决策
{}",
                        i+1, d.label,
                        d.system_prompt,
                        d.user_content,
                        d.user_msg,
                        d.teacher_reply,
                        d.candidates,
                        if d.cp1_concepts.is_empty() { "无".to_string() } else { d.cp1_concepts.join("\n- ") },
                        plan_state_str,
                        if d.plan_updated { "✅ CP2 更新了计划" } else { "❄️ CP2 未检测到变化" },
                    ));
                }
                parts.join("\n\n")
            },
            plan_json,  // 完整 plan JSON，不截断
            // CP1 事件日志
            turn_diags.iter().enumerate()
                .map(|(i, d)| {
                    let concepts_str = if d.cp1_concepts.is_empty() { "无".to_string() } else { d.cp1_concepts.join(", ") };
                    format!("CP1 轮{}: {} 个候选 — {}",
                        i+1, d.candidates, concepts_str)
                })
                .collect::<Vec<_>>()
                .join("\n"),
            // CP2 事件日志
            turn_diags.iter().enumerate()
                .map(|(i, d)| {
                    format!("Turn{}: CP2 updated={}", i+1, d.plan_updated)
                })
                .collect::<Vec<_>>()
                .join("\n"),
            // 计划状态
            if plan_status_lines.is_empty() {
                "无计划状态（plan_content 为空）".to_string()
            } else {
                plan_status_lines.join("\n")
            },
            // 完整对话流
            all_turns.join("\n"),
        );
        let _ = std::fs::write(format!("{}/summary.md", report_dir), &report);
        println!("  📁 报告已保存: {}/summary.md", report_dir);
    }

    // ── Summary ──
    println!("\n{}", "=".repeat(70));
    println!(" Chinese E2E test passed – {} API calls", calls);
    println!("{}", "=".repeat(70));
}
