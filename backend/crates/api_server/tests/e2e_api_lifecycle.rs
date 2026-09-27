//! E2E API 全生命周期测试 — 全走 HTTP API（对话通过 WS）
//!
//! 新规范流程（3 场景统一）:
//!   进入任何对话:
//!     查 conversations (确认存在)
//!     查 conversation_plans (渲染 plan)
//!     查 user_plan_progress (显示进度)
//!     查 conversation_turns (恢复历史)
//!     → WS 连接继续
//!
//! 三种 init 方式共用一个生命周期 runner：
//!   - free: 无 init，CP2 自由创建计划
//!
//! 📌 2026-09-27：原覆盖 free / k12 / reading 三模式 —— K12 结构化管道已整体清退
//!    （路由 + quiz 题库 + 课程加载器全部移除），`/api/k12/reading/init` 路由更早已不存在，
//!    故只保留 **free** 模式（另两个场景已删）。
//!
//! 与 e2e_main_lifecycle 互为对照组：
//!   - e2e_main_lifecycle: 直接调内部函数 → 验证业务逻辑
//!   - e2e_api_lifecycle:  全走 HTTP API + WS  → 验证 API 契约

use api_server::test_helpers::{body_json, body_json_or};
use serde_json::{json, Value};
use student_llm::{student_speak, DEFAULT_PROMPT};
use std::sync::OnceLock;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

const FREE_USER: &str = "e2eapitest";
const TEST_PASS: &str = "pass123word456";

const FREE_CONV: &str = "e2e-api-test-free";

const MAX_DIALOGUE_ROUNDS: usize = 5;
const TIMEOUT_MINS: u64 = 15;

struct LifecycleConfig {
    name: &'static str,
    conv_id: &'static str,
    user: &'static str,
}

/// 每轮诊断数据
struct TurnDiag {
    label: String,
    user_msg: String,
    teacher_reply: String,
    student_reply: String,
    candidates: usize,
    plan_updated: bool,
    cp1_concepts: Vec<String>,
    plan_state_after: Option<String>,
    system_prompt: String,
    user_content: String,
    prompt_source: String,
}

static INIT: OnceLock<()> = OnceLock::new();

/// 启动 API server 并返回 base URL + WS URL
async fn start_server() -> (String, String) {
    for p in &["../../.env", ".env", "../.env"] {
        let _ = dotenvy::from_filename(p);
    }

    INIT.get_or_init(|| {
        chat_engine::prompt_loader::init("../../prompts");
        let _ = std::fs::create_dir_all("data");
    });

    api_server::test_helpers::init_tracing();

    let db_path = std::env::var("COEVO_DB_PATH").unwrap_or_else(|_| {
        api_server::test_helpers::resolve_db_path().to_string_lossy().to_string()
    });
    let is_new_db = !std::path::Path::new(&db_path).exists();
    api_server::db_pool::init(&db_path).expect("init db");

    let conn = api_server::db_pool::get_conn();
    if is_new_db {
        api_server::schema::init_database(&conn).expect("schema init");
    } else {
        // 已有 DB：只跑迁移（不重建表）
        api_server::schema::run_migrations(&conn).expect("migrations");
    }

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("DEEPSEEK_API_KEY 未设置");
    let llm_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let app = api_server::routes::build_router(llm_config);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{}", addr);
    let ws_base = base.replace("http", "ws");

    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    (base, ws_base)
}

/// 通过 WS 发送消息返回 (reply, candidates, plan_updated)
/// done 前收到的 candidates 被正确收集；done 后发出的 candidates 由 read_drain 补充
async fn ws_send_and_recv<S, St>(
    write: &mut S,
    read: &mut St,
    msg: &str,
    timeout_secs: u64,
) -> (String, Vec<String>, bool)
where
    S: SinkExt<Message> + Unpin,
    S::Error: std::fmt::Debug,
    St: StreamExt<Item=Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    write.send(Message::Text(msg.to_string().into())).await.expect("WS send");
    let mut reply = String::new();
    let mut candidates = Vec::new();
    let mut plan_updated = false;

    tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), async {
        while let Some(item) = read.next().await {
            match item {
                Ok(Message::Text(t)) => {
                    let event: Value = serde_json::from_str(&t).unwrap_or_default();
                    match event["type"].as_str().unwrap_or("") {
                        "done" => {
                            reply = event["reply"].as_str().unwrap_or("").to_string();
                            return; // done 后退出
                        }
                        "candidates" => {
                            if let Some(c) = event["candidates"].as_array() {
                                candidates = c.iter()
                                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                                    .collect();
                            }
                        }
                        "plan_updated" => { plan_updated = true; }
                        _ => {}
                    }
                }
                Ok(Message::Close(_)) | Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {}
                _ => {}
            }
        }
    }).await.expect("WS timeout");

    (reply, candidates, plan_updated)
}

/// 检查对话状态：查 conversations + plans + progress + turns
async fn check_dialogue_state(
    client: &reqwest::Client, base: &str, conv: &str, uid: &str, token: &str,
    label: &str,
) -> serde_json::Value {
    // 查 conversations（通过 history API — 有 turns 即确认存在）
    let hist_resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, conv))
        .header("Authorization", format!("Bearer {}", token))
        .send().await;
    let turns_info: Value = match hist_resp {
        Ok(r) => body_json(r).await,
        Err(_) => json!({"turns": []}),
    };
    let turn_count = turns_info["turns"].as_array().map(|a| a.len()).unwrap_or(0);

    // 查 conversation_plans + user_plan_progress（通过 plans API）
    let plans_resp = client.get(format!("{}/api/plans?conversation_id={}", base, conv))
        .header("Authorization", format!("Bearer {}", token))
        .send().await;
    let plan_info: Value = match plans_resp {
        Ok(r) => body_json(r).await,
        Err(_) => json!({}),
    };
    let has_plan = plan_info.get("plans").and_then(|p| p.as_array()).map(|a| !a.is_empty()).unwrap_or(false);

    let state = json!({
        "label": label,
        "conv_exists": turn_count > 0,
        "has_plan": has_plan,
        "plan_detail": plan_info,
        "turn_count": turn_count,
    });
    println!("  📊 state: conv_exists={}, has_plan={}, turns={}",
        turn_count > 0, has_plan, turn_count);
    state
}

/// 运行一次全生命周期测试（注册 + 可选 init + WS 对话 + 最终验证）
async fn run_lifecycle(cfg: LifecycleConfig) {
    println!("\n{}", "=".repeat(70));
    println!(" 🚀 {} E2E test – full lifecycle via HTTP + WS", cfg.name);
    println!("    规范: 查conv → 查plan → 查progress → 查turns → WS继续");
    println!("{}", "=".repeat(70));

    let (base, ws_base) = start_server().await;
    let client = reqwest::Client::new();
    let mut calls = 0u32;

    // Step 1: Register（用户已存在则跳过）
    println!("\n--- Step 1: Register ---");
    let register_resp = client.post(format!("{}/api/auth/register", base))
        .json(&json!({"username": cfg.user, "password": TEST_PASS}))
        .send().await;
    let uid = match register_resp {
        Ok(r) if r.status().is_success() => {
            calls += 1;
            let reg: Value = body_json(r).await;
            let uid = reg["user_id"].as_str().map(|s| s.to_string()).unwrap_or_default();
            println!("  registered uid={}", uid);
            uid
        }
        _ => {
            calls += 1;
            println!("  user already exists, skipping");
            String::new()
        }
    };

    // Step 2: Login（从 login 获取 user_id + token）
    println!("\n--- Step 2: Login ---");
    let resp = client.post(format!("{}/api/auth/login", base))
        .json(&json!({"username": cfg.user, "password": TEST_PASS}))
        .send().await.unwrap();
    let login: Value = body_json(resp).await;
    calls += 1;
    let uid = login["user_id"].as_str().expect("login should return user_id").to_string();
    let token = login["token"].as_str().unwrap_or("").to_string();
    assert!(!token.is_empty(), "login should return token");

    // Step 3: Subscription
    println!("\n--- Step 3: Subscription ---");
    let expires = (chrono::Utc::now() + chrono::Duration::days(365)).to_rfc3339();
    let resp = client.put(format!("{}/api/user/{}/preferences", base, uid))
        .json(&json!({"subscription_expires": expires}))
        .send().await.unwrap();
    calls += 1;

    // 📌 原 Step 3b（K12 / Reading 预建 init）已随两条管道一并移除。
    //    free 模式没有预建流程 —— 对话由 WS 首条消息懒创建。
    let active_conv_id = cfg.conv_id.to_string();

    // Step 4: 检查初始状态（free 模式首次运行应为空）
    // 注意：使用生产 DB 时前次测试数据可能残留，断言容忍 residual
    // 📌 原另有 K12 / Reading 两支（init 预建 plan、对话由 WS 懒创建）—— 两条管道已清退。
    println!("\n--- Step 4: Check initial state ---");
    let init_state = check_dialogue_state(&client, &base, &active_conv_id, &uid, &token, "init").await;
    if init_state["conv_exists"].as_bool() == Some(true) {
        println!("  ⚠️ free: conv exists (residual), turns={}", init_state["turn_count"].as_u64().unwrap_or(0));
    } else {
        assert_eq!(init_state["conv_exists"].as_bool(), Some(false));
        assert_eq!(init_state["has_plan"].as_bool(), Some(false));
        assert_eq!(init_state["turn_count"].as_u64(), Some(0));
    }

    // Step 5: WS 对话
    println!("\n--- Step 5: WebSocket dialogue ---");
    let run_id = format!("e2e_api_free_{}", chrono::Utc::now().format("%Y%m%d_%H%M%S"));
    let report_dir = format!("data/eval_runs/{}", run_id);
    let _ = std::fs::create_dir_all(&report_dir);

    let start_time = std::time::Instant::now();
    let api_key = std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY");
    let mut student_cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    student_cfg.temperature = 0.3;

    let mut plan_created = false;
    let mut turn_diags: Vec<TurnDiag> = Vec::new();
    let mut state_snapshots: Vec<serde_json::Value> = Vec::new();

    api_server::plan_handler::enable_context_log();

    fn capture_llm_input() -> (String, String) {
        api_server::plan_handler::drain_llm_input_log().pop().unwrap_or_default()
    }

    fn capture_prompt_source() -> String {
        api_server::plan_handler::drain_prompt_source_log().pop().unwrap_or_default()
    }

    // 连接 WS
    let (ws_stream, _) = tokio_tungstenite::connect_async(format!("{}/ws", ws_base)).await
        .expect("WS connect should succeed");
    println!("  WS connected ✅");
    let (mut write, read) = ws_stream.split();
    let mut read = read;

    // 5a. 初始消息——自由对话需 CP2 建计划，K12/Reading 已有计划
    let init_msg = "Hello, I want to learn the Pythagorean theorem.";

    let ws_msg = json!({
        "user_id": uid, "conversation_id": active_conv_id.as_str(),
        "message": init_msg, "token": token,
    }).to_string();
    let (reply, candidates, updated) = ws_send_and_recv(&mut write, &mut read, &ws_msg, 120).await;
    calls += 1;
    plan_created = updated;
    println!("  first reply: {} chars, candidates={}, plan_updated={}", reply.len(), candidates.len(), updated);

    let state = check_dialogue_state(&client, &base, active_conv_id.as_str(), &uid, &token, "first_msg").await;
    state_snapshots.push(state);

    // free chat 需要第二条消息触发 CP2 创建计划
    let ws_msg2 = json!({
        "user_id": uid, "conversation_id": active_conv_id.as_str(),
        "message": "OK, please make a study plan for me.", "token": token,
    }).to_string();
    let (reply2, candidates2, updated2) = ws_send_and_recv(&mut write, &mut read, &ws_msg2, 120).await;
    calls += 1;
    plan_created = updated2;
    println!("  plan request: {} chars", reply2.len());

    let (sys_prompt, user_content) = capture_llm_input();
    turn_diags.push(TurnDiag {
        label: "创建计划(对话2)".into(), user_msg: "OK, please make a study plan for me.".into(),
        teacher_reply: reply2, student_reply: String::new(), candidates: candidates2.len(),
        plan_updated: updated2, cp1_concepts: candidates2, plan_state_after: None,
        system_prompt: sys_prompt, user_content,
        prompt_source: capture_prompt_source(),
    });

    let (sys_prompt, user_content) = capture_llm_input();
    turn_diags.push(TurnDiag {
        label: "首条消息".into(), user_msg: init_msg.to_string(), teacher_reply: reply,
        student_reply: String::new(), candidates: candidates.len(),
        plan_updated: plan_created, cp1_concepts: candidates, plan_state_after: None,
        system_prompt: sys_prompt, user_content,
        prompt_source: capture_prompt_source(),
    });

    // 5b. 双 LLM 循环
    let mut round = 0usize;
    let max_duration = std::time::Duration::from_secs(TIMEOUT_MINS * 60);
    while round < MAX_DIALOGUE_ROUNDS && start_time.elapsed() < max_duration {
        round += 1;

        // 查 conversation_turns（恢复历史）
        let hist_resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, active_conv_id.as_str()))
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
        let student_input = raw_turns.iter()
            .find(|(role, _)| role == "assistant")
            .map(|(_, content)| format!("assistant: {}", content))
            .unwrap_or_default();

        let mut student_caller = chat_engine::llm_caller::LlmCaller::new(student_cfg.clone());
        let student_msg = student_speak(&mut student_caller, DEFAULT_PROMPT, &student_input).await;
        assert!(!student_msg.is_empty(), "student LLM empty at round {}", round);

        let ws_msg = json!({
            "user_id": uid, "conversation_id": active_conv_id.as_str(),
            "message": student_msg, "token": token,
        }).to_string();
        let (reply, candidates, updated) = ws_send_and_recv(&mut write, &mut read, &ws_msg, 120).await;
        calls += 1;
        if updated { plan_created = true; }

        // 每轮检查完整状态
        let label = format!("双LLM轮{}", round);
        let state = check_dialogue_state(&client, &base, active_conv_id.as_str(), &uid, &token, &label).await;
        let has_plan_now = state["has_plan"].as_bool().unwrap_or(false);
        state_snapshots.push(state);
        if has_plan_now { plan_created = true; }

        let (sys_prompt, user_content) = capture_llm_input();
        turn_diags.push(TurnDiag {
            label, user_msg: student_msg, teacher_reply: reply,
            student_reply: String::new(), candidates: candidates.len(),
            plan_updated: updated, cp1_concepts: candidates,
            plan_state_after: None, system_prompt: sys_prompt, user_content,
            prompt_source: capture_prompt_source(),
        });
    }

    // 排水：读掉 WS 残留的 candidates/plan_updated 事件
    println!("\n--- Drain leftover WS events ---");
    {
        use tokio::time::Duration;
        let drain = tokio::time::sleep(Duration::from_secs(3));
        tokio::pin!(drain);
        tokio::select! {
            item = read.next() => {
                if let Some(Ok(Message::Text(t))) = item {
                    let event: Value = serde_json::from_str(&t).unwrap_or_default();
                    if event["type"].as_str() == Some("candidates") {
                        if let Some(c) = event["candidates"].as_array() {
                            let cv: Vec<String> = c.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect();
                            println!("  drained {} candidates", cv.len());
                            turn_diags.last_mut().map(|d| d.cp1_concepts = cv);
                        }
                    }
                    if event["type"].as_str() == Some("plan_updated") {
                        println!("  drained plan_updated");
                    }
                }
            }
            _ = &mut drain => { println!("  drain timeout"); }
        }
    }

    // Step 6: Verify plan
    println!("\n--- Step 6: Verify plan ---");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = client.get(format!("{}/api/plans?conversation_id={}", base, active_conv_id.as_str()))
        .send().await.unwrap();
    let plans_resp: Value = body_json(resp).await;
    calls += 1;
    let list = plans_resp["plans"].as_array().unwrap();
    // free 模式下 CP2 应已创建计划
    assert!(!list.is_empty(), "CP2 should create a plan for free chat");
    let plan_json = serde_json::to_string_pretty(&plans_resp).unwrap_or_default();

    // Step 7: Verify conversation history
    println!("\n--- Step 7: Conversation history ---");
    let resp = client.get(format!("{}/api/history?user_id={}&conversation_id={}", base, uid, active_conv_id.as_str()))
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
    assert!(all_turns.len() >= 2, "should have >=2 turns");

    // Step 8: Cards & report
    println!("\n--- Step 8: Cards & learning report ---");
    let resp = client.get(format!("{}/api/cards/all?user_id={}", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let cards_resp: Value = body_json(resp).await;
    calls += 1;
    let active_cards = cards_resp["cards"].as_array().map(|a| a.len()).unwrap_or(0);
    // 从 API 响应统计 CP1 概念卡片数（card_type = "concept"）
    let cp1_total = cards_resp["cards"].as_array()
        .map(|cards| {
            cards.iter().filter(|c| c["card_type"].as_str() == Some("concept")).count()
        })
        .unwrap_or(0);
    let total_cards: i64 = {
        let conn = api_server::db_pool::get_conn();
        conn.query_row("SELECT COUNT(*) FROM user_cards WHERE user_id = ?1",
            rusqlite::params![uid], |r| r.get(0)).unwrap_or(0)
    };

    let resp = client.get(format!("{}/api/user/{}/learning-report", base, uid))
        .header("Authorization", format!("Bearer {}", token))
        .send().await.unwrap();
    let report_val: Value = body_json(resp).await;
    calls += 1;
    let plan_count = report_val["plans"].as_array().map(|a| a.len()).unwrap_or(0);

    // ── 计算关键指标 ──
    let plan_update_count = turn_diags.iter().filter(|d| d.plan_updated).count();
    let (plan_stages, plan_tasks): (usize, usize) = {
        let resp = client.get(format!("{}/api/plans?conversation_id={}", base, active_conv_id.as_str()))
            .send().await;
        match resp {
            Ok(r) => {
                let v: Value = body_json(r).await;
                if let Some(plan) = v["plans"].as_array().and_then(|plans| plans.first()) {
                    let pc = plan.get("plan").or_else(|| plan.get("plan_content"))
                        .and_then(|c| c.as_object());
                    let stages = pc.and_then(|p| p.get("stages").and_then(|s| s.as_array()))
                        .map(|a| a.len()).unwrap_or(0);
                    let tasks = pc.and_then(|p| p.get("stages").and_then(|s| s.as_array()))
                        .map(|stages| stages.iter()
                            .filter_map(|s| s.get("tasks").and_then(|t| t.as_array()).map(|a| a.len()))
                            .sum())
                        .unwrap_or(0);
                    (stages, tasks)
                } else { (0, 0) }
            }
            Err(_) => (0, 0),
        }
    };
    let plan_created_label = if plan_created { "✅" } else { "❌" };
    // 📌 原用于区分「init 预建」vs「free 懒建」；预建的两条管道已清退 → free 下两者恒 false
    let init_conv = false;
    let init_has_plan = false;
    let init_turns = init_state["turn_count"].as_u64().unwrap_or(0);

    // ── Save report ──
    {
        let snapshots_str = state_snapshots.iter()
            .map(|s| serde_json::to_string_pretty(s).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\n---\n");

        let report = format!(
r#"# {} E2E 测试报告

- **运行时间**: {}
- **API 调用数**: {}
- **结果**: ✅ 通过
- **卡片数**: {} (active: {})
- **对话轮次**: {}
- **CP2 推进**: {} 次
- **CP1 提取**: {} 个候选概念
- **Plan 创建**: {}
- **Plan 结构**: {} 阶段 / {} 任务

---

## 步骤汇总

| Step | 操作 | 状态 |
|------|------|------|
| 1 | Register | ✅ |
| 2 | Login | ✅ |
| 3 | Subscription | ✅ |
| 4 | Check initial state | ✅ conv={}, plan={}, turns={} |
| 5 | WS dialogue ({} turns) | ✅ plan_created={}, updated={}次 |
| 6 | Plans | ✅ {} 阶段 / {} 任务 |
| 7 | History ({} turns) | ✅ |
| 8 | Cards (active={}, total={}) + Report ({}) | ✅ |

---

## 对话状态快照

{}

---

## 每轮诊断

{}

---

## Plan 数据/状态

```json
{}
```

---

## 完整对话流

{}
"#,
            cfg.name,
            chrono::Utc::now().format("%Y-%m-%d %H:%M:%S"),
            calls,
            total_cards,
            active_cards,
            turn_diags.len(),
            plan_update_count,
            cp1_total,
            if plan_created { "✅" } else { "❌" },
            plan_stages, plan_tasks,
            init_conv, init_has_plan, init_turns,
            turn_diags.len(),
            if plan_created { "✅" } else { "❌" },
            plan_update_count,
            plan_stages, plan_tasks,
            all_turns.len(),
            active_cards, total_cards, plan_count,
            snapshots_str,
            {
                let mut parts = Vec::new();
                for (i, d) in turn_diags.iter().enumerate() {
                    parts.push(format!(
"═══════════════════════════════════════════════════════════════
## 轮次 {}: {}

### System Prompt
```
{}
```
### Prompt 来源
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
{}
### CP2 决策
{}",
                        i+1, d.label,
                        d.system_prompt,
                        d.prompt_source,
                        d.user_content,
                        d.user_msg,
                        d.teacher_reply,
                        d.cp1_concepts.len(),
                        if d.cp1_concepts.is_empty() { "无".to_string() } else { d.cp1_concepts.join("\n- ") },
                        if d.plan_updated { "✅ CP2 更新了计划" } else { "❄️ CP2 未检测到变化" },
                    ));
                }
                parts.join("\n\n")
            },
            plan_json,
            all_turns.join("\n"),
        );
        let report_path = format!("{}/summary.md", report_dir);
        let _ = std::fs::write(&report_path, &report);
        println!("  📁 报告已保存: {}", report_path);
    }

    println!("\n{}", "=".repeat(70));
    println!(" ✅ {} E2E test passed – {} API calls, {} dialogue rounds, {} cards",
        cfg.name, calls, turn_diags.len(), total_cards);
    println!("{}", "=".repeat(70));
}

// ── 测试场景 ──
// 📌 原另有 `e2e_api_k12` / `e2e_api_reading` 两个场景 —— K12 结构化管道已整体清退，
//    Reading 所依赖的 `/api/k12/reading/init` 路由更早已不存在，故一并移除。

#[tokio::test]
#[ignore]
async fn e2e_api_free_chat() {
    run_lifecycle(LifecycleConfig {
        name: "Free Chat",
        conv_id: FREE_CONV,
        user: FREE_USER,
    }).await;
}
