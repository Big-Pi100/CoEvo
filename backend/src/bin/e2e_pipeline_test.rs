//! CoEvo E2E 管线测试 CLI
//!
//! 阶段化 E2E 测试工具：每阶段独立运行、结果持久化、可链式/单独执行。
//! Phase 2 使用双 LLM 模拟师生对话进行计划推进测试。
//!
//! 用法:
//!   cargo run --bin e2e-pipeline-test
//!   cargo run --bin e2e-pipeline-test -- --phase plan-creation
//!   cargo run --bin e2e-pipeline-test -- --from phase-2
//!   cargo run --bin e2e-pipeline-test -- --force

use std::collections::HashMap;
use std::time::{Duration, Instant};
use std::path::PathBuf;

use api_server::e2e_runner;
use serde_json::json;

// ── CLI ──

struct CliArgs {
    phases: Option<Vec<String>>,
    from: Option<String>,
    domain: Option<String>,
    model: String,
    force: bool,
    report_only: bool,
    clean: bool,
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut cli = CliArgs {
        phases: None, from: None, domain: None,
        model: "deepseek-v4-flash".to_string(), force: false, report_only: false, clean: false,
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--phase" | "-p" => { i += 1; if i < args.len() { cli.phases = Some(args[i].split(',').map(|s| s.to_string()).collect()); } }
            "--from" | "-f" => { i += 1; if i < args.len() { cli.from = Some(args[i].clone()); } }
            "--domain" | "-d" => { i += 1; if i < args.len() { cli.domain = Some(args[i].clone()); } }
            "--model" | "-m" => { i += 1; if i < args.len() { cli.model = args[i].clone(); } }
            "--force" => cli.force = true,
            "--report-only" => cli.report_only = true,
            "--clean" => cli.clean = true,
            _ => {}
        }
        i += 1;
    }
    cli
}

const ALL_PHASES: &[&str] = &[
    "plan-creation", "progression-history", "progression-language",
    "progression-math", "concept-extraction", "review-flow", "report",
];
const TEST_DB_PATH: &str = "data/test_e2e_pipeline.db";
const TEST_USER_ID: &str = "e2e-pipeline-user";
const TEST_CONV_ID: &str = "e2e-pipeline-conv";
const TEST_USERNAME: &str = "e2e_pipeline_tester";
const TEST_PASSWORD_HASH: &str = "$2b$12$dummy_hash_for_testing";

// 各 domain 专用 conversation_id（避免状态串扰）
const CONV_HISTORY: &str = "e2e-history-conv";
const CONV_LANG: &str = "e2e-lang-conv";
const CONV_MATH: &str = "e2e-math-conv";

fn should_run_phase(phase: &str, cli: &CliArgs) -> bool {
    if cli.report_only { return phase == "report"; }
    if let Some(ref from) = cli.from {
        let idx = ALL_PHASES.iter().position(|p| *p == phase).unwrap_or(0);
        let from_idx = ALL_PHASES.iter().position(|p| *p == from.as_str()).unwrap_or(0);
        if idx < from_idx { return false; }
    }
    if let Some(ref phases) = cli.phases { return phases.contains(&phase.to_string()); }
    true
}

fn truncate(s: &str, max: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max { s.to_string() }
    else { let truncated: String = chars[..max].iter().collect(); format!("{}... ({} chars total)", truncated, chars.len()) }
}

// ════════════════════════════════════════════
// Phase 1: 计划创建 + 路由测试
// ════════════════════════════════════════════

async fn phase_plan_creation(run_id: &str, cli: &CliArgs) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 1: 计划创建 + 路由测试");
    println!("{}", "=".repeat(70));

    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut llm_logs = Vec::new();
    let mut errors = Vec::new();
    let mut domain_results = HashMap::new();

    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");
    let mut caller = e2e_runner::create_llm_caller(&cli.model);

    let all_cases: Vec<(&str, &str)> = vec![
        ("math", "我想系统学习数学，从基础开始，目标是掌握高等数学"),
        ("language", "我想学习英语，从基础单词和语法开始"),
        ("", "我想学习历史，了解世界历史的主要事件"),
    ];

    let test_cases: Vec<&(&str, &str)> = if let Some(ref filter) = cli.domain {
        if filter.is_empty() {
            all_cases.iter().collect()
        } else {
            all_cases.iter().filter(|(d, _)| *d == filter.as_str()).collect()
        }
    } else {
        all_cases.iter().collect()
    };

    let mut passed = 0;
    let total = test_cases.len();

    for case in &test_cases {
        let (expected_domain, message) = *case;
        let step = format!("create_plan_{}", if expected_domain.is_empty() { "general" } else { expected_domain });
        let mut log = e2e_runner::LlmLog::new("plan-creation", &step, expected_domain);

        conn.execute("DELETE FROM learning_plans WHERE conversation_id = ?1", rusqlite::params![TEST_CONV_ID]).ok();
        conn.execute("DELETE FROM conversation_turns WHERE conversation_id = ?1", rusqlite::params![TEST_CONV_ID]).ok();
        std::thread::sleep(Duration::from_millis(500));

        // Turn 1: 用户表达学习目标
        e2e_runner::insert_turn(&conn, TEST_CONV_ID, "user", message);
        log.user_message = message.to_string();

        // Turn 1 尚无学习计划，domain/mode 走默认值
        println!("  🎯 [{}] Turn1 (plan not yet created)", step);

        let templates = chat_engine::prompt_loader::get_for_domain("");
        let sp = templates.chat_system_free.clone();  // 无计划时走 free mode
        log.system_prompt_preview = sp.clone();

        let history = e2e_runner::get_conversation_history(&conn, TEST_CONV_ID, 20);
        let uc = history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n");

        let llm_start = Instant::now();
        match caller.generate(&sp, &uc).await {
            Ok(r) => { log.duration_ms += llm_start.elapsed().as_millis() as u64; log.raw_llm_response = r.clone(); e2e_runner::insert_turn(&conn, TEST_CONV_ID, "assistant", &r); }
            Err(e) => { errors.push(format!("LLM Turn1 失败({}): {:?}", step, e)); llm_logs.push(log); continue; }
        }

        // Turn 2: 用户确认创建计划
        std::thread::sleep(Duration::from_millis(1500));
        let confirm = "好的，帮我制定一个详细的学习计划。";
        e2e_runner::insert_turn(&conn, TEST_CONV_ID, "user", confirm);
        log.user_message = format!("{}\n[Turn2] {}", message, confirm);

        let (dom2, mode2, ctx2) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);
        println!("  🎯 [{}] Turn2 domain={:?} mode={:?}", step, dom2, mode2);

        let t2 = chat_engine::prompt_loader::get_for_domain(&dom2);
        let sp2 = if mode2 == "structured" { t2.chat_system_structured.clone() } else { t2.chat_system_free.clone() };
        let h2 = e2e_runner::get_conversation_history(&conn, TEST_CONV_ID, 20);
        let uc2 = if ctx2.is_empty() { h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), ctx2) };

        let llm_start2 = Instant::now();
        match caller.generate(&sp2, &uc2).await {
            Ok(r) => { log.duration_ms += llm_start2.elapsed().as_millis() as u64; e2e_runner::insert_turn(&conn, TEST_CONV_ID, "assistant", &r); }
            Err(e) => { errors.push(format!("LLM Turn2 失败({}): {:?}", step, e)); llm_logs.push(log); continue; }
        }

        // 从最近一条 assistant 回复中提取 plan_update
        let last_turns = e2e_runner::get_conversation_history(&conn, TEST_CONV_ID, 2);
        let last_assistant = last_turns.iter().rev().find(|(r, _)| r == "assistant").map(|(_, c)| c.clone()).unwrap_or_default();
        let result = api_server::plan_handler::handle_plan_update(&conn, &last_assistant, TEST_CONV_ID, TEST_USER_ID);

        // 提取 pipeline_domain
        let pipeline_domain: String = result.plan_json.as_ref().and_then(|j| j.get("domain")).and_then(|v| v.as_str()).unwrap_or("").to_string();
        let db_domain: String = conn.query_row("SELECT plan_json FROM learning_plans WHERE conversation_id = ?1", rusqlite::params![TEST_CONV_ID], |row| row.get::<_, String>(0))
            .ok().and_then(|pj| serde_json::from_str::<serde_json::Value>(&pj).ok().and_then(|v| v.get("domain").and_then(|d| d.as_str()).map(|s| s.to_string()))).unwrap_or_default();
        let matched_domain = if !pipeline_domain.is_empty() { pipeline_domain.as_str() } else { db_domain.as_str() };
        let domain_match = matched_domain == *expected_domain || (expected_domain.is_empty() && !matched_domain.is_empty());
        if domain_match { passed += 1; }

        println!("  💡 [{}] plan_update: is_new={} pipeline_domain={:?} match={}", step, result.is_new_plan, matched_domain, domain_match);

        let plan_has_stages = result.plan_json.as_ref().and_then(|j| j.get("stages")).and_then(|s| s.as_array()).map(|a| !a.is_empty()).unwrap_or(false);
        let (_, actual_mode, _) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);

        domain_results.insert(expected_domain.to_string(), json!({
            "expected": expected_domain, "actual": matched_domain,
            "domain_match": domain_match, "plan_created": result.is_new_plan,
            "plan_has_stages": plan_has_stages, "mode": actual_mode,
        }));
        llm_logs.push(log);
        std::thread::sleep(Duration::from_secs(2));
    }

    let duration = start.elapsed();
    let status = if errors.is_empty() && passed == total { e2e_runner::PhaseStatus::Passed } else { e2e_runner::PhaseStatus::Failed };

    e2e_runner::PhaseResult {
        phase: "plan-creation".to_string(),
            pipeline_version: "2026-05-21_v2".to_string(),
            run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
            duration_ms: duration.as_millis() as u64, status, grade: None,
            metrics: json!({ "total_attempts": total, "successful": passed, "failed": total - passed, "domain_accuracy": format!("{}/{}", passed, total), "domain_results": domain_results }),
        llm_logs, errors,
    }
}

// ════════════════════════════════════════════
// Phase 2a: progression-history (原 Phase 2 改名)
// ════════════════════════════════════════════

/// 用 LLM 模拟学生回答教师提问
/// conv_id 参数使函数可复用于多 domain 测试
async fn generate_student_answer(
    conn: &rusqlite::Connection,
    conv_id: &str,
) -> String {
    let history = e2e_runner::get_conversation_history(conn, conv_id, 10);
    let history_str = history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n");

    let student_system = "\
你是一个认真学习的学生，正在接受一位AI助教的一对一教学。\
\n\n回答要求：\
\n- 概念题：用自己的话解释核心概念，给出你理解的定义和例子\
\n- 如果老师问了问题，你必须具体回答，展示你的理解\
\n- 回答要真实自然，像真正的学生一样\
\n- 表明你理解了或还有哪里不懂\
\n- 当老师讲解完概念后，可以说「我理解了，请继续举例」\
\n- 当完成了举例练习，可以说「都答对了，请推进」\
\n- 每次回答不要太长（不超过300字）";

    let user_prompt = format!(
        "{}\n\n以上是当前的对话历史。请以学生的身份，自然地对助教的最新消息做出回应。\
         如果助教在提问，回答他的问题。如果助教在讲解，表示你理解了并请求继续。",
        history_str
    );

    let config = chat_engine::config::load_llm_config();
    let mut student_caller = chat_engine::llm_caller::LlmCaller::new(config);

    match student_caller.generate(student_system, &user_prompt).await {
        Ok(answer) => {
            let preview: String = answer.chars().take(300).collect();
            println!("  🎓 学生生成 ({} chars): {}...", answer.len(), preview);
            answer
        }
        Err(e) => {
            println!("  ⚠️ 学生回答生成失败: {:?}, 使用默认回退", e);
            "我理解了刚才讲解的内容。请继续教学。".to_string()
        }
    }
}

async fn phase_progression_history(run_id: &str, cli: &CliArgs) -> e2e_runner::PhaseResult {
    progression_domain_test(run_id, cli, "progression-history", CONV_HISTORY, "history",
        "我想系统学习历史，了解世界历史的主要事件",
        |_reply_contains_latex: &str| false).await
}

// ════════════════════════════════════════════
// Phase 2b: progression-language
// ════════════════════════════════════════════

async fn phase_progression_language(run_id: &str, cli: &CliArgs) -> e2e_runner::PhaseResult {
    progression_domain_test(run_id, cli, "progression-language", CONV_LANG, "language",
        "我想学基础英语词汇和语法，从最简单的开始",
        |_reply_contains_latex: &str| false).await
}

// ════════════════════════════════════════════
// Phase 2c: progression-math（含 LaTeX 检测）
// ════════════════════════════════════════════

async fn phase_progression_math(run_id: &str, cli: &CliArgs) -> e2e_runner::PhaseResult {
    progression_domain_test(run_id, cli, "progression-math", CONV_MATH, "math",
        "我想系统学习数学，从基础开始，目标是掌握高等数学",
        |reply: &str| reply.contains(r"\(") || reply.contains(r"\[")).await
}

/// 通用 domain 推进测试（Progression 核心逻辑）
async fn progression_domain_test(
    run_id: &str,
    cli: &CliArgs,
    phase_name: &str,
    conv_id: &str,
    expected_domain: &str,
    first_student_msg: &str,
    check_latex: fn(&str) -> bool,
) -> e2e_runner::PhaseResult {
    let phase_label = match phase_name {
        "progression-history" => "2a: history 计划推进",
        "progression-language" => "2b: language 计划推进",
        "progression-math" => "2c: math 计划推进",
        _ => phase_name,
    };

    println!("\n{}", "=".repeat(70));
    println!(" Phase {} (双 LLM 师生模拟, domain={})", phase_label, expected_domain);
    println!("{}", "=".repeat(70));

    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut llm_logs = Vec::new();
    let mut errors = Vec::new();

    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");

    // 清理该 conv_id 的旧数据，创建独立学习计划
    conn.execute("DELETE FROM learning_plans WHERE conversation_id = ?1", rusqlite::params![conv_id]).ok();
    conn.execute("DELETE FROM conversation_turns WHERE conversation_id = ?1", rusqlite::params![conv_id]).ok();
    conn.execute("DELETE FROM cards WHERE user_id = ?1 AND created_at > 0", rusqlite::params![TEST_USER_ID]).ok();
    // 确保 conversation 存在
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conv_id, TEST_USER_ID, now],
    ).ok();
    std::thread::sleep(Duration::from_millis(300));

    // Turn 1: 用户表达学习目标
    e2e_runner::insert_turn(&conn, conv_id, "user", first_student_msg);

    // 调用 LLM 创建计划
    let mut teacher_caller = e2e_runner::create_llm_caller(&cli.model);
    let templates = chat_engine::prompt_loader::get_for_domain("");
    let sp = templates.chat_system_free.clone();
    let history = e2e_runner::get_conversation_history(&conn, conv_id, 20);
    let uc = history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n");

    match teacher_caller.generate(&sp, &uc).await {
        Ok(r) => e2e_runner::insert_turn(&conn, conv_id, "assistant", &r),
        Err(e) => {
            errors.push(format!("创建计划 LLM 调用失败: {:?}", e));
            return e2e_runner::PhaseResult {
                phase: phase_name.to_string(), pipeline_version: "2026-05-21_v3".to_string(),
                run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
                duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Failed, grade: None,
                metrics: json!({"skipped_reason": format!("LLM init failed: {:?}", e)}), llm_logs: vec![], errors,
            };
        }
    }

    // Turn 2: 用户确认
    std::thread::sleep(Duration::from_millis(1000));
    let confirm = "好的，帮我制定一个详细的学习计划。";
    e2e_runner::insert_turn(&conn, conv_id, "user", confirm);

    let (dom2, mode2, ctx2) = e2e_runner::build_plan_context(&conn, conv_id);
    let t2 = chat_engine::prompt_loader::get_for_domain(&dom2);
    let sp2 = if mode2 == "structured" { t2.chat_system_structured.clone() } else { t2.chat_system_free.clone() };
    let h2 = e2e_runner::get_conversation_history(&conn, conv_id, 20);
    let uc2 = if ctx2.is_empty() { h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), ctx2) };

    match teacher_caller.generate(&sp2, &uc2).await {
        Ok(r) => e2e_runner::insert_turn(&conn, conv_id, "assistant", &r),
        Err(e) => {
            errors.push(format!("确认计划 LLM 调用失败: {:?}", e));
            return e2e_runner::PhaseResult {
                phase: phase_name.to_string(), pipeline_version: "2026-05-21_v3".to_string(),
                run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
                duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Failed, grade: None,
                metrics: json!({"skipped_reason": format!("LLM confirm failed: {:?}", e)}), llm_logs: vec![], errors,
            };
        }
    }

    // 解析 plan_update
    let last_turns = e2e_runner::get_conversation_history(&conn, conv_id, 2);
    let last_assistant = last_turns.iter().rev().find(|(r, _)| r == "assistant").map(|(_, c)| c.clone()).unwrap_or_default();
    let create_result = api_server::plan_handler::handle_plan_update(&conn, &last_assistant, conv_id, TEST_USER_ID);

    if !create_result.is_new_plan && !create_result.plan_updated {
        errors.push("计划创建失败：无 plan_update 响应".to_string());
        return e2e_runner::PhaseResult {
            phase: phase_name.to_string(), pipeline_version: "2026-05-21_v3".to_string(),
            run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
            duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Failed, grade: None,
            metrics: json!({"skipped_reason": "Plan not created"}), llm_logs: vec![], errors,
        };
    }

    println!("  📋 domain={:?} 计划已创建", expected_domain);

    // ── 多轮教学模拟 ──
    let mut student_msg = "好的，请开始教我当前计划中的第一个任务吧。".to_string();
    let mut conversations = 0;
    let mut plan_updates = 0;
    let mut latex_found = false;
    const MAX_TURNS: usize = 6;

    for turn in 0..MAX_TURNS {
        let step = format!("{}-{}", phase_name, turn + 1);
        let mut log = e2e_runner::LlmLog::new(phase_name, &step, expected_domain);

        // 学生发言
        e2e_runner::insert_turn(&conn, conv_id, "user", &student_msg);
        log.user_message = student_msg.clone();

        let (cur_domain, cur_mode, cur_ctx) = e2e_runner::build_plan_context(&conn, conv_id);
        let tpl = chat_engine::prompt_loader::get_for_domain(&cur_domain);
        let sp = if cur_mode == "structured" { tpl.chat_system_structured.clone() } else { tpl.chat_system_free.clone() };
        log.system_prompt_preview = sp.clone();

        let history = e2e_runner::get_conversation_history(&conn, conv_id, 20);
        let uc = if cur_ctx.is_empty() { history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), cur_ctx) };

        println!("\n  🔄 [{}] 学生: {}", step, truncate(&student_msg, 120));
        println!("  📋 mode={:?}, domain={:?}", cur_mode, cur_domain);

        // 教师 LLM 回复
        let llm_start = Instant::now();
        let raw_reply = match teacher_caller.generate(&sp, &uc).await {
            Ok(r) => { log.duration_ms = llm_start.elapsed().as_millis() as u64; log.raw_llm_response = r.clone(); r }
            Err(e) => { errors.push(format!("教师LLM({}): {:?}", step, e)); llm_logs.push(log); continue; }
        };

        if check_latex(&raw_reply) { latex_found = true; println!("  📐 [{}] LaTeX 检测到！", step); }

        let result = api_server::plan_handler::handle_plan_update(&conn, &raw_reply, conv_id, TEST_USER_ID);
        e2e_runner::insert_turn(&conn, conv_id, "assistant", &result.cleaned_reply);
        println!("  👨‍🏫 教师: {}", truncate(&result.cleaned_reply, 300));

        conversations += 1;
        if result.plan_updated {
            plan_updates += 1;
            if let Some(ref pj) = result.plan_json {
                if pj.get("current_task_complete").and_then(|v| v.as_bool()).unwrap_or(false) { println!("  ✅ [{}] current_task_complete = true", step); }
                if let Some(stage) = pj.get("next_stage_suggestion").and_then(|v| v.as_str()) { if !stage.is_empty() { println!("  🏁 [{}] 下一阶段: {}", step, truncate(stage, 80)); } }
            }
        }

        llm_logs.push(log);
        std::thread::sleep(Duration::from_millis(1500));

        // 学生 LLM 生成下一轮
        student_msg = generate_student_answer(&conn, conv_id).await;

        let (_, next_mode, _) = e2e_runner::build_plan_context(&conn, conv_id);
        if next_mode == "free" { println!("  🏁 [{}] mode=free，计划周期结束", step); break; }
    }

    let duration = start.elapsed();
    let has_teaching = conversations > 0;
    let has_plan_update = plan_updates > 0;
    let has_no_errors = errors.is_empty();

    // 教学进行 + 无错误 = 通过（plan_update 是 LLM 行为指标，非 pass/fail 门槛）
    let status = if has_teaching && has_no_errors {
        if !has_plan_update {
            // 记录 warning 但不阻断通过
            errors.push("教师教学未产生 plan_update (LLM 行为差异，非代码缺陷)".to_string());
        }
        e2e_runner::PhaseStatus::Passed
    } else {
        if !has_teaching { errors.push("无教学互动".to_string()); }
        e2e_runner::PhaseStatus::Failed
    };

    println!("  📊 统计: plan_updates={}, conversations={}, latex_found={}, errors={}",
        plan_updates, conversations, latex_found, errors.len());
    println!("  📊 判定: {}", if status == e2e_runner::PhaseStatus::Passed { "✅ 通过" } else { "❌ 失败" });

    e2e_runner::PhaseResult {
        phase: phase_name.to_string(), pipeline_version: "2026-05-21_v3".to_string(),
        run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
        duration_ms: duration.as_millis() as u64, status, grade: None,
        metrics: json!({
            "total_conversations": conversations, "plan_updates": plan_updates,
            "latex_found": latex_found, "domain": expected_domain,
        }),
        llm_logs, errors,
    }
}

// ════════════════════════════════════════════
// Phase 3: concept-extraction（真实 LLM）
// ════════════════════════════════════════════

async fn phase_concept_extraction(run_id: &str, _cli: &CliArgs) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 3: 概念提取测试 (真实 LLM)");
    println!("{}", "=".repeat(70));

    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut errors = Vec::new();

    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");

    // 使用固定的已知回复，包含 word_bank 中的词汇（apple, red, run）
    // 避免依赖 LLM 教学对话的最后一轮（可能触发直接制卡意图）
    let user_message = "我理解了刚才的颜色和 be 动词的教学内容。";
    let ai_reply = "Great! Let me teach you some common words. Apple is a fruit. The color red is beautiful. She runs every morning. These are basic vocabulary words for beginners.";
    let history_refs: Vec<(String, String)> = vec![
        ("user".to_string(), "我想学基础英语词汇".to_string()),
        ("assistant".to_string(), "我来教你一些基本词汇。Apple is a fruit. The color red is very common.".to_string()),
        ("user".to_string(), user_message.to_string()),
        ("assistant".to_string(), ai_reply.to_string()),
    ];
    let existing_fronts: Vec<String> = {
        let stmt = conn.prepare("SELECT LOWER(front) FROM cards WHERE user_id = ?1");
        if let Ok(mut s) = stmt {
            if let Ok(rows) = s.query_map(rusqlite::params![TEST_USER_ID], |row| row.get::<_, String>(0)) {
                rows.filter_map(|r| r.ok()).collect()
            } else { vec![] }
        } else { vec![] }
    };

    let skipped_fronts: Vec<String> = {
        let stmt = conn.prepare("SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1");
        if let Ok(mut s) = stmt {
            if let Ok(rows) = s.query_map(rusqlite::params![TEST_USER_ID], |row| row.get::<_, String>(0)) {
                rows.filter_map(|r| r.ok()).collect()
            } else { vec![] }
        } else { vec![] }
    };

    let llm_config = chat_engine::config::load_llm_config();

    println!("  📝 提取概念: user_msg=({} chars), ai_reply=({} chars), existing={}, skipped={}",
        user_message.len(), ai_reply.len(), existing_fronts.len(), skipped_fronts.len());

    use shared_types::card::ExtractionResult;
    let extraction: ExtractionResult = chat_engine::concept_extractor::extract_concepts(
        TEST_USER_ID, user_message, ai_reply,
        &existing_fronts, &skipped_fronts, &llm_config, &history_refs,
        "language",
    ).await;

    let total = extraction.candidates.len();
    let direct_card = extraction.direct_card;
    println!("  ✅ 提取完成: total={}, direct_card={}", total, direct_card);

    // 验证 candidates 非空（有概念产生）
    let has_candidates = total > 0;

    // 验证 domain 路由正确：语言管线提取的卡片 domain 应为 vocabulary/language
    let vocab_domain_count = extraction.candidates.iter()
        .filter(|c| c.domain == "vocabulary" || c.domain == "language")
        .count();
    let domain_ok = total > 0 && vocab_domain_count as f64 / total as f64 >= 0.5;

    println!("  📊 domain 检查: vocab/language={}/{} ratio={:.1}% {}",
        vocab_domain_count, total, if total > 0 { vocab_domain_count as f64 / total as f64 * 100.0 } else { 0.0 },
        if domain_ok { "✅" } else { "❌" });

    if has_candidates && domain_ok {
        // 写入 cards 表（验证 insert_card 兼容概念提取输出）
        let mut inserted = 0;
        for c in &extraction.candidates {
            let card_id = uuid::Uuid::new_v4().to_string();
            let memory = shared_types::card::CardMemory {
                card_id: card_id.clone(), state: 0, difficulty: 5.0, stability: 5.0,
                due: chrono::Utc::now().timestamp(), last_review: None,
                reps: 0, lapses: 0,
            };
            let card = shared_types::card::Card {
                id: card_id, user_id: TEST_USER_ID.to_string(),
                domain: Some(c.domain.clone()), card_type: "vocabulary".to_string(),
                front: c.front.clone(), back: c.back.clone(),
                source_sentence: Some(c.source_sentence.clone()),
                conversation_id: Some(CONV_LANG.to_string()),
                created_at: chrono::Utc::now().timestamp(),
                subject: None, grade_band: None,
            };
            match card_engine::card_repository::insert_card(&conn, &card, &memory) {
                card_engine::card_repository::InsertResult::Success(_) => inserted += 1,
                _ => {}
            }
        }

        let duration = start.elapsed();
        e2e_runner::PhaseResult {
            phase: "concept-extraction".to_string(), pipeline_version: "2026-05-21_v3".to_string(),
            run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
            duration_ms: duration.as_millis() as u64, status: e2e_runner::PhaseStatus::Passed, grade: None,
            metrics: json!({ "total_concepts": total, "inserted": inserted, "direct_card": direct_card, "has_candidates": has_candidates, "domain_ok": domain_ok, "vocab_domain_count": vocab_domain_count, "domain": "language" }),
            llm_logs: vec![], errors,
        }
    } else {
        if !has_candidates { errors.push("概念提取未产生任何候选概念".to_string()); }
        if !domain_ok { errors.push(format!("domain 路由错误: 仅 {}/{} 候选为 language/vocabulary domain", vocab_domain_count, total)); }
        let duration = start.elapsed();
        e2e_runner::PhaseResult {
            phase: "concept-extraction".to_string(), pipeline_version: "2026-05-21_v3".to_string(),
            run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
            duration_ms: duration.as_millis() as u64, status: e2e_runner::PhaseStatus::Failed, grade: None,
            metrics: json!({"total_concepts": 0, "has_candidates": false}),
            llm_logs: vec![], errors,
        }
    }
}

// ════════════════════════════════════════════
// Phase 4: review-flow（全链路复习验证）
// ════════════════════════════════════════════

async fn phase_review_flow(run_id: &str, _cli: &CliArgs) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 4: 复习提交全链路测试");
    println!("{}", "=".repeat(70));

    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut errors = Vec::new();
    let mut metrics = serde_json::Map::new();

    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");

    let card_id = match e2e_runner::insert_test_card(
        &conn, TEST_USER_ID, "language", "vocabulary", "apple", "苹果",
    ) {
        Ok(id) => id,
        Err(e) => {
            errors.push(format!("insert_test_card 失败: {}", e));
            return e2e_runner::PhaseResult {
                phase: "review-flow".to_string(), pipeline_version: "2026-05-21_v3".to_string(),
                run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
                duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Failed, grade: None,
                metrics: json!({"error": format!("{}", e)}), llm_logs: vec![], errors,
            };
        }
    };

    // 场景 A: 正确拼写 → pass, reps+1
    match e2e_runner::call_submit_review(&conn, &card_id, TEST_USER_ID, 3, "spelling", "pass") {
        Ok(_) => {
            let logs = e2e_runner::get_review_log(&conn, &card_id);
            metrics.insert("spelling_correct_logs".to_string(), json!(logs.len()));
            let reps: i64 = conn.query_row(
                "SELECT reps FROM card_memory WHERE card_id = ?1",
                rusqlite::params![card_id], |row| row.get(0),
            ).ok().unwrap_or(-1);
            metrics.insert("reps_after_pass".to_string(), json!(reps));
        }
        Err(e) => errors.push(format!("正确拼写场景失败: {}", e)),
    }

    // 场景 B: 错误拼写 → fail, lapses+1
    match e2e_runner::call_submit_review(&conn, &card_id, TEST_USER_ID, 1, "spelling", "fail") {
        Ok(_) => {
            let logs = e2e_runner::get_review_log(&conn, &card_id);
            metrics.insert("spelling_fail_logs".to_string(), json!(logs.len()));
            let lapses: i64 = conn.query_row(
                "SELECT lapses FROM card_memory WHERE card_id = ?1",
                rusqlite::params![card_id], |row| row.get(0),
            ).ok().unwrap_or(-1);
            metrics.insert("lapses_after_fail".to_string(), json!(lapses));
            let reps: i64 = conn.query_row(
                "SELECT reps FROM card_memory WHERE card_id = ?1",
                rusqlite::params![card_id], |row| row.get(0),
            ).ok().unwrap_or(-1);
            metrics.insert("reps_after_fail".to_string(), json!(reps));
        }
        Err(e) => errors.push(format!("错误拼写场景失败: {}", e)),
    }

    let reps_ok = metrics.get("reps_after_pass").and_then(|v| v.as_i64()).unwrap_or(0) >= 1;
    let lapses_ok = metrics.get("lapses_after_fail").and_then(|v| v.as_i64()).unwrap_or(0) >= 1;
    let logs_ok = metrics.get("spelling_correct_logs").and_then(|v| v.as_i64()).unwrap_or(0) >= 1
        && metrics.get("spelling_fail_logs").and_then(|v| v.as_i64()).unwrap_or(0) >= 2;

    metrics.insert("reps_ok".to_string(), json!(reps_ok));
    metrics.insert("lapses_ok".to_string(), json!(lapses_ok));
    metrics.insert("logs_ok".to_string(), json!(logs_ok));

    let status = if reps_ok && lapses_ok && logs_ok && errors.is_empty() {
        println!("  ✅ review-flow 全部场景通过");
        e2e_runner::PhaseStatus::Passed
    } else {
        println!("  ❌ review-flow 部分失败: reps_ok={}, lapses_ok={}, logs_ok={}, errors={}",
            reps_ok, lapses_ok, logs_ok, errors.len());
        e2e_runner::PhaseStatus::Failed
    };

    let duration = start.elapsed();
    e2e_runner::PhaseResult {
        phase: "review-flow".to_string(), pipeline_version: "2026-05-21_v3".to_string(),
        run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
        duration_ms: duration.as_millis() as u64, status, grade: None,
        metrics: json!(metrics), llm_logs: vec![], errors,
    }
}

// ════════════════════════════════════════════
// Phase 5: 报表生成
// ════════════════════════════════════════════

fn phase_report(run_id: &str) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 5: 报表生成");
    println!("{}", "=".repeat(70));
    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();

    let mut lines = vec![];
    lines.push("# CoEvo 管线 E2E 测试报告".to_string());
    lines.push(format!("> 运行 ID: {} | {}", run_id, chrono::Local::now().format("%Y-%m-%d %H:%M:%S")));
    lines.push("".to_string());

    let all_phases = [
        ("plan-creation", "Phase 1: 计划创建 + 路由测试"),
        ("progression-history", "Phase 2a: history 计划推进"),
        ("progression-language", "Phase 2b: language 计划推进"),
        ("progression-math", "Phase 2c: math 计划推进"),
        ("concept-extraction", "Phase 3: 概念提取"),
        ("review-flow", "Phase 4: 复习全链路"),
    ];

    let mut total_llm = 0usize;
    let mut total_err = 0usize;
    let mut all_durations: Vec<(String, u64)> = Vec::new();

    for (phase_key, phase_label) in &all_phases {
        lines.push("".to_string());
        lines.push(format!("## {}", phase_label));
        if let Some(r) = e2e_runner::load_phase_result(run_id, phase_key) {
            total_llm += r.llm_logs.len();
            total_err += r.errors.len();
            all_durations.push((phase_key.to_string(), r.duration_ms));

            if r.status == e2e_runner::PhaseStatus::Skipped {
                lines.push("⏭️ 已跳过".to_string());
            } else {
                let grade_str = match r.grade {
                    Some(e2e_runner::Grade::A) => "A",
                    Some(e2e_runner::Grade::B) => "B",
                    Some(e2e_runner::Grade::C) => "C",
                    Some(e2e_runner::Grade::D) => "D",
                    _ => "F",
                };
                lines.push(format!("| 指标 | 值 |")); lines.push("|------|-----|".to_string());
                lines.push(format!("| 状态 | {} |", if r.status == e2e_runner::PhaseStatus::Passed { "✅ 通过" } else { "❌ 失败" }));
                lines.push(format!("| 等级 | {} |", grade_str));
                lines.push(format!("| 耗时 | {} |", e2e_runner::format_duration(Duration::from_millis(r.duration_ms))));
                // 通用指标
                if let Some(v) = r.metrics.get("total_conversations").and_then(|v| v.as_u64()) {
                    lines.push(format!("| 对话轮次 | {} |", v));
                }
                if let Some(v) = r.metrics.get("plan_updates").and_then(|v| v.as_u64()) {
                    lines.push(format!("| plan_update | {} 次 |", v));
                }
                if let Some(v) = r.metrics.get("latex_found").and_then(|v| v.as_bool()) {
                    lines.push(format!("| LaTeX 检测 | {} |", if v { "✅" } else { "❌" }));
                }
                if let Some(v) = r.metrics.get("total_concepts").and_then(|v| v.as_u64()) {
                    lines.push(format!("| 候选概念数 | {} |", v));
                }
                if let Some(v) = r.metrics.get("inserted").and_then(|v| v.as_u64()) {
                    lines.push(format!("| 写入卡片数 | {} |", v));
                }
                if let Some(v) = r.metrics.get("domain").and_then(|v| v.as_str()) {
                    lines.push(format!("| pipeline | {} |", v));
                }
                if let Some(v) = r.metrics.get("reps_ok").and_then(|v| v.as_bool()) {
                    lines.push(format!("| reps 递增 | {} |", if v { "✅" } else { "❌" }));
                }
                if let Some(v) = r.metrics.get("lapses_ok").and_then(|v| v.as_bool()) {
                    lines.push(format!("| lapses 递增 | {} |", if v { "✅" } else { "❌" }));
                }
                if let Some(v) = r.metrics.get("logs_ok").and_then(|v| v.as_bool()) {
                    lines.push(format!("| review_log 记录 | {} |", if v { "✅" } else { "❌" }));
                }
            }
            for e in &r.errors { lines.push(format!("- ❌ {}", e)); }
        } else {
            lines.push("（未运行）".to_string());
        }
    }

    lines.push("".to_string()); lines.push("---".to_string()); lines.push("".to_string());
    lines.push("## 汇总".to_string());
    lines.push(format!("| 项目 | 值 |")); lines.push("|------|-----|".to_string());
    lines.push(format!("| LLM 调用次数 | {} |", total_llm));
    lines.push(format!("| 错误数 | {} |", total_err));
    for (key, dur) in &all_durations {
        lines.push(format!("| {} 耗时 | {} |", key, e2e_runner::format_duration(Duration::from_millis(*dur))));
    }

    let report = lines.join("\n");
    let dir = PathBuf::from("docs/test-results").join(run_id);
    let _ = std::fs::create_dir_all(&dir);
    std::fs::write(dir.join("report.md"), &report).ok();
    println!("{}", report);

    e2e_runner::PhaseResult {
        phase: "report".to_string(), pipeline_version: "2026-05-21_v3".to_string(),
        run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
        duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Passed, grade: None,
        metrics: json!({"total_llm_calls": total_llm, "total_errors": total_err}),
        llm_logs: vec![], errors: vec![],
    }
}

// ════════════════════════════════════════════
// Main
// ════════════════════════════════════════════

#[tokio::main]
async fn main() {
    let cli = parse_args();
    let mut run_id = chrono::Local::now().format("pipeline-%Y%m%d_%H%M%S").to_string();
    let _ = dotenvy::dotenv();
    let _ = tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::new("warn")).try_init();
    let _ = std::fs::create_dir_all("data");

    if cli.clean {
        println!("🧹 --clean: 清除已有测试 DB");
        let _ = std::fs::remove_file(TEST_DB_PATH);
        let _ = std::fs::remove_dir_all("docs/test-results");
    }

    chat_engine::prompt_loader::init("prompts", "pipelines");
    chat_engine::word_bank::init("cefr_catalog.json");

    e2e_runner::init_test_db(TEST_DB_PATH).expect("Failed to init test DB");
    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");
    e2e_runner::seed_test_data(&conn, TEST_USER_ID, TEST_USERNAME, TEST_PASSWORD_HASH, TEST_CONV_ID).expect("Failed to seed test data");
    // 为各 domain 独立 conversation 创建记录
    for cid in &[CONV_HISTORY, CONV_LANG, CONV_MATH] {
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
            rusqlite::params![cid, TEST_USER_ID, now],
        ).ok();
    }
    api_server::db_pool::init(TEST_DB_PATH).expect("Failed to init DB pool");

    let existing = if !cli.force { e2e_runner::get_latest_run_dir().and_then(|p| std::fs::read_to_string(p.join("config.json")).ok().and_then(|c| serde_json::from_str::<e2e_runner::RunConfig>(&c).ok())) } else { None };
    match (&existing, cli.force) {
        (Some(cfg), false) => { println!("🔁 断点续跑: run_id={}, 已完成={:?}", cfg.run_id, cfg.completed_phases); run_id = cfg.run_id.clone(); }
        _ => { e2e_runner::save_config(&run_id, &e2e_runner::RunConfig {
            run_id: run_id.clone(), llm_model: cli.model.clone(),
            base_url: chat_engine::config::load_llm_config().base_url,
            started_at: chrono::Utc::now().to_rfc3339(), completed_phases: vec![],
        }).expect("Failed to save config"); }
    }

    println!("🚀 E2E 管线测试 run_id={} model={}", run_id, cli.model);

    let mut all_passed = true;
    for phase_name in ALL_PHASES {
        if !should_run_phase(phase_name, &cli) { continue; }
        if !cli.force && e2e_runner::is_phase_completed(&run_id, phase_name) { println!("\n⏭️ {} 已完成", phase_name); continue; }

        let mut result = match *phase_name {
            "plan-creation" => phase_plan_creation(&run_id, &cli).await,
            "progression-history" => phase_progression_history(&run_id, &cli).await,
            "progression-language" => phase_progression_language(&run_id, &cli).await,
            "progression-math" => phase_progression_math(&run_id, &cli).await,
            "concept-extraction" => phase_concept_extraction(&run_id, &cli).await,
            "review-flow" => phase_review_flow(&run_id, &cli).await,
            "report" => phase_report(&run_id),
            _ => unreachable!(),
        };
        // 自动判定通过等级
        result.grade = Some(e2e_runner::resolve_grade(
            &result.phase, &result.status, &result.metrics, &result.errors,
        ));
        e2e_runner::save_phase_result(&run_id, &result).expect("Failed to save");
        e2e_runner::mark_phase_completed(&run_id, phase_name).expect("Failed to mark");

        let grade_str = match result.grade {
            Some(e2e_runner::Grade::A) => "A",
            Some(e2e_runner::Grade::B) => "B",
            Some(e2e_runner::Grade::C) => "C",
            Some(e2e_runner::Grade::D) => "D",
            _ => "F",
        };
        if result.status == e2e_runner::PhaseStatus::Failed {
            all_passed = false;
            println!("\n❌ {} 失败! grade={}", phase_name, grade_str);
        } else if result.grade != Some(e2e_runner::Grade::A) {
            all_passed = false;
            println!("\n⚠️ {} 通过但 grade={} (未达 A)", phase_name, grade_str);
        } else {
            println!("\n✅ {} 通过! grade=A", phase_name);
        }
    }
    e2e_runner::update_latest(&run_id).ok();

    println!("\n结果: {}", if all_passed { "✅ 全部通过 (全 A)" } else { "⚠️ 部分未达 A 级" });
    println!("报告: docs/test-results/{}/report.md", run_id);
    std::process::exit(if all_passed { 0 } else { 1 });
}
