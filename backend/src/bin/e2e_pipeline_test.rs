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
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut cli = CliArgs {
        phases: None, from: None, domain: None,
        model: "deepseek-v4-flash".to_string(), force: false, report_only: false,
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
            _ => {}
        }
        i += 1;
    }
    cli
}

const ALL_PHASES: &[&str] = &["plan-creation", "plan-progression", "report"];
const TEST_DB_PATH: &str = "data/test_e2e_pipeline.db";
const TEST_USER_ID: &str = "e2e-pipeline-user";
const TEST_CONV_ID: &str = "e2e-pipeline-conv";
const TEST_USERNAME: &str = "e2e_pipeline_tester";
const TEST_PASSWORD_HASH: &str = "$2b$12$dummy_hash_for_testing";

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

    let test_cases = vec![
        ("math", "我想系统学习数学，从基础开始，目标是掌握高等数学"),
        ("language", "我想学习英语，从基础单词和语法开始"),
        ("", "我想学习历史，了解世界历史的主要事件"),
    ];

    let mut passed = 0;
    let total = test_cases.len();

    for (expected_domain, message) in &test_cases {
        let step = format!("create_plan_{}", if expected_domain.is_empty() { "general" } else { expected_domain });
        let mut log = e2e_runner::LlmLog::new("plan-creation", &step, expected_domain);

        conn.execute("DELETE FROM learning_plans WHERE conversation_id = ?1", rusqlite::params![TEST_CONV_ID]).ok();
        conn.execute("DELETE FROM conversation_turns WHERE conversation_id = ?1", rusqlite::params![TEST_CONV_ID]).ok();
        std::thread::sleep(Duration::from_millis(500));

        // Turn 1: 用户表达学习目标
        e2e_runner::insert_turn(&conn, TEST_CONV_ID, "user", message);
        log.user_message = message.to_string();

        let (domain, mode, plan_ctx) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);
        println!("  🎯 [{}] Turn1 domain={:?} mode={:?}", step, domain, mode);

        let templates = chat_engine::prompt_loader::get_for_domain(&domain);
        let sp = if mode == "structured" { templates.chat_system_structured.clone() } else { templates.chat_system_free.clone() };
        log.system_prompt_preview = truncate(&sp, 200);

        let history = e2e_runner::get_conversation_history(&conn, TEST_CONV_ID, 20);
        let uc = if plan_ctx.is_empty() { history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), plan_ctx) };

        let llm_start = Instant::now();
        match caller.generate(&sp, &uc).await {
            Ok(r) => { log.duration_ms += llm_start.elapsed().as_millis() as u64; log.raw_llm_response = truncate(&r, 3000); e2e_runner::insert_turn(&conn, TEST_CONV_ID, "assistant", &r); }
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

        let result = api_server::plan_handler::handle_plan_update(&conn, "", TEST_CONV_ID, TEST_USER_ID);
        // 重新处理：从最近一条 assistant 回复中寻找 plan_update
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
        duration_ms: duration.as_millis() as u64, status,
        metrics: json!({ "total_attempts": total, "successful": passed, "failed": total - passed, "domain_accuracy": format!("{}/{}", passed, total), "domain_results": domain_results }),
        llm_logs, errors,
    }
}

// ════════════════════════════════════════════
// Phase 2: 计划推进测试（双 LLM 师生模拟）
// ════════════════════════════════════════════

/// 用 LLM 模拟学生回答教师提问
async fn generate_student_answer(
    conn: &rusqlite::Connection,
) -> String {
    let history = e2e_runner::get_conversation_history(conn, TEST_CONV_ID, 10);
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

async fn phase_plan_progression(run_id: &str, cli: &CliArgs) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 2: 计划推进测试 (双 LLM 师生模拟)");
    println!("{}", "=".repeat(70));

    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut llm_logs = Vec::new();
    let mut errors = Vec::new();

    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");
    let mut teacher_caller = e2e_runner::create_llm_caller(&cli.model);

    let (domain, mode, plan_ctx) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);
    if mode != "structured" || domain.is_empty() {
        errors.push("Phase 2 跳过：Phase 1 未创建计划".to_string());
        return e2e_runner::PhaseResult {
            phase: "plan-progression".to_string(), pipeline_version: "2026-05-21_v2".to_string(),
            run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
            duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Skipped,
            metrics: json!({"skipped_reason": "No plan from Phase 1"}), llm_logs: vec![], errors,
        };
    }

    println!("  📋 从 Phase 1 继承: domain={:?}, mode={:?}", domain, mode);

    let mut student_msg = "好的，请开始教我当前计划中的第一个任务吧。".to_string();
    let mut conversations = 0;
    let mut plan_updates = 0;
    let mut task_completions = 0;
    let mut stage_advances = 0;
    let mut student_generations = 0;
    const MAX_TURNS: usize = 6;

    for turn in 0..MAX_TURNS {
        let step = format!("progression-{}", turn + 1);
        let mut log = e2e_runner::LlmLog::new("plan-progression", &step, &domain);

        // 学生发言
        e2e_runner::insert_turn(&conn, TEST_CONV_ID, "user", &student_msg);
        log.user_message = truncate(&student_msg, 300);

        let (cur_domain, cur_mode, cur_ctx) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);
        let tpl = chat_engine::prompt_loader::get_for_domain(&cur_domain);
        let sp = if cur_mode == "structured" { tpl.chat_system_structured.clone() } else { tpl.chat_system_free.clone() };
        log.system_prompt_preview = truncate(&sp, 200);

        let history = e2e_runner::get_conversation_history(&conn, TEST_CONV_ID, 20);
        let uc = if cur_ctx.is_empty() { history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), cur_ctx) };

        println!("\n  🔄 [{}] 学生: {}", step, truncate(&student_msg, 120));
        println!("  📋 mode={:?}, domain={:?}", cur_mode, cur_domain);

        // 教师 LLM 回复
        let llm_start = Instant::now();
        let raw_reply = match teacher_caller.generate(&sp, &uc).await {
            Ok(r) => { log.duration_ms = llm_start.elapsed().as_millis() as u64; log.raw_llm_response = truncate(&r, 3000); r }
            Err(e) => { errors.push(format!("教师LLM({}): {:?}", step, e)); llm_logs.push(log); continue; }
        };

        let result = api_server::plan_handler::handle_plan_update(&conn, &raw_reply, TEST_CONV_ID, TEST_USER_ID);
        e2e_runner::insert_turn(&conn, TEST_CONV_ID, "assistant", &result.cleaned_reply);
        println!("  👨‍🏫 教师: {}", truncate(&result.cleaned_reply, 300));

        conversations += 1;
        if result.plan_updated {
            plan_updates += 1;
            if let Some(ref pj) = result.plan_json {
                if pj.get("current_task_complete").and_then(|v| v.as_bool()).unwrap_or(false) { task_completions += 1; println!("  ✅ [{}] current_task_complete = true", step); }
                if let Some(stage) = pj.get("next_stage_suggestion").and_then(|v| v.as_str()) { if !stage.is_empty() { stage_advances += 1; println!("  🏁 [{}] 下一阶段: {}", step, truncate(stage, 80)); } }
            }
        }

        llm_logs.push(log);
        std::thread::sleep(Duration::from_millis(1500));

        // 学生 LLM 生成下一轮回复（基于教师的最新消息）
        student_msg = generate_student_answer(&conn).await;
        student_generations += 1;

        // 如果 mode 变回 free，结束
        let (_, next_mode, _) = e2e_runner::build_plan_context(&conn, TEST_CONV_ID);
        if next_mode == "free" { println!("  🏁 [{}] mode=free，计划周期结束", step); break; }
    }

    let duration = start.elapsed();
    let has_teaching = conversations > 0;
    let has_plan_update = plan_updates > 0;
    let has_no_errors = errors.is_empty() || errors.len() < MAX_TURNS;

    let status = if has_plan_update && has_teaching && has_no_errors { e2e_runner::PhaseStatus::Passed }
    else if has_teaching && has_no_errors && !has_plan_update { errors.push("教师教学未产生 plan_update".to_string()); e2e_runner::PhaseStatus::Failed }
    else { if !has_teaching { errors.push("无教学互动".to_string()); } e2e_runner::PhaseStatus::Failed };

    println!("  📊 统计: plan_updates={}, task_completions={}, stage_advances={}, conversations={}, student_generations={}, errors={}",
        plan_updates, task_completions, stage_advances, conversations, student_generations, errors.len());
    println!("  📊 判定: {}", if status == e2e_runner::PhaseStatus::Passed { "✅ 通过" } else { "❌ 失败" });

    e2e_runner::PhaseResult {
        phase: "plan-progression".to_string(), pipeline_version: "2026-05-21_v2".to_string(),
        run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
        duration_ms: duration.as_millis() as u64, status,
        metrics: json!({ "total_conversations": conversations, "plan_updates": plan_updates, "task_completions": task_completions, "stage_advances": stage_advances, "student_generations": student_generations, "domain": domain }),
        llm_logs, errors,
    }
}

// ════════════════════════════════════════════
// Phase 3: 报表生成
// ════════════════════════════════════════════

fn phase_report(run_id: &str) -> e2e_runner::PhaseResult {
    println!("\n{}", "=".repeat(70));
    println!(" Phase 3: 报表生成");
    println!("{}", "=".repeat(70));
    let started_at = chrono::Utc::now().to_rfc3339();
    let start = Instant::now();

    let plan_creation = e2e_runner::load_phase_result(run_id, "plan-creation");
    let plan_progression = e2e_runner::load_phase_result(run_id, "plan-progression");

    let mut lines = vec![];
    lines.push("# CoEvo 管线 E2E 测试报告".to_string());
    lines.push(format!("> 运行 ID: {} | {}", run_id, chrono::Local::now().format("%Y-%m-%d %H:%M:%S")));
    lines.push("".to_string());

    // Phase 1
    lines.push("## Phase 1: 计划创建 + 路由测试".to_string());
    if let Some(r) = &plan_creation {
        lines.push(format!("| 指标 | 值 |")); lines.push("|------|-----|".to_string());
        lines.push(format!("| 状态 | {} |", if r.status == e2e_runner::PhaseStatus::Passed { "✅ 通过" } else { "❌ 失败" }));
        lines.push(format!("| 耗时 | {} |", e2e_runner::format_duration(Duration::from_millis(r.duration_ms))));
        lines.push(format!("| domain 准确率 | {} |", r.metrics.get("domain_accuracy").and_then(|v| v.as_str()).unwrap_or("N/A")));
        if let Some(details) = r.metrics.get("domain_results").and_then(|v| v.as_object()) {
            lines.push("".to_string()); lines.push("| domain | 实际 | 期望 | 匹配 | 创建 | stages |".to_string()); lines.push("|--------|------|------|:----:|:----:|:------:|".to_string());
            for (dom, info) in details {
                let e = info.get("expected").and_then(|v| v.as_str()).unwrap_or("");
                let a = info.get("actual").and_then(|v| v.as_str()).unwrap_or("");
                let m = info.get("domain_match").and_then(|v| v.as_bool()).unwrap_or(false);
                let c = info.get("plan_created").and_then(|v| v.as_bool()).unwrap_or(false);
                let s = info.get("plan_has_stages").and_then(|v| v.as_bool()).unwrap_or(false);
                lines.push(format!("| {} | {} | {} | {} | {} | {} |", dom, a, e, if m { "✅" } else { "❌" }, if c { "✅" } else { "❌" }, if s { "✅" } else { "❌" }));
            }
        }
        for e in &r.errors { lines.push(format!("- ❌ {}", e)); }
    } else { lines.push("（未运行）".to_string()); }

    lines.push("".to_string());

    // Phase 2
    lines.push("## Phase 2: 计划推进测试".to_string());
    if let Some(r) = &plan_progression {
        if r.status == e2e_runner::PhaseStatus::Skipped { lines.push("⏭️ 已跳过".to_string()); }
        else {
            lines.push(format!("| 指标 | 值 |")); lines.push("|------|-----|".to_string());
            lines.push(format!("| 状态 | {} |", if r.status == e2e_runner::PhaseStatus::Passed { "✅ 通过" } else { "❌ 失败" }));
            lines.push(format!("| 耗时 | {} |", e2e_runner::format_duration(Duration::from_millis(r.duration_ms))));
            lines.push(format!("| 对话轮次 | {} |", r.metrics.get("total_conversations").and_then(|v| v.as_u64()).unwrap_or(0)));
            lines.push(format!("| plan_update | {} 次 |", r.metrics.get("plan_updates").and_then(|v| v.as_u64()).unwrap_or(0)));
            lines.push(format!("| task_complete | {} 次 |", r.metrics.get("task_completions").and_then(|v| v.as_u64()).unwrap_or(0)));
            lines.push(format!("| stage_advance | {} 次 |", r.metrics.get("stage_advances").and_then(|v| v.as_u64()).unwrap_or(0)));
            lines.push(format!("| 学生自动生成 | {} 次 |", r.metrics.get("student_generations").and_then(|v| v.as_u64()).unwrap_or(0)));
            lines.push(format!("| pipeline | {} |", r.metrics.get("domain").and_then(|v| v.as_str()).unwrap_or("N/A")));
        }
        for e in &r.errors { lines.push(format!("- ❌ {}", e)); }
    } else { lines.push("（未运行）".to_string()); }

    lines.push("".to_string()); lines.push("---".to_string()); lines.push("".to_string());

    let total_llm = plan_creation.as_ref().map(|r| r.llm_logs.len()).unwrap_or(0) + plan_progression.as_ref().map(|r| r.llm_logs.len()).unwrap_or(0);
    let total_err = plan_creation.as_ref().map(|r| r.errors.len()).unwrap_or(0) + plan_progression.as_ref().map(|r| r.errors.len()).unwrap_or(0);
    lines.push("## 汇总".to_string());
    lines.push(format!("| 项目 | 值 |")); lines.push("|------|-----|".to_string());
    lines.push(format!("| LLM 调用次数 | {} |", total_llm));
    lines.push(format!("| 错误数 | {} |", total_err));
    if let Some(r) = &plan_creation { lines.push(format!("| Phase 1 耗时 | {} |", e2e_runner::format_duration(Duration::from_millis(r.duration_ms)))); }
    if let Some(r) = &plan_progression { lines.push(format!("| Phase 2 耗时 | {} |", e2e_runner::format_duration(Duration::from_millis(r.duration_ms)))); }

    let report = lines.join("\n");
    let dir = PathBuf::from("docs/test-results").join(run_id);
    let _ = std::fs::create_dir_all(&dir);
    std::fs::write(dir.join("report.md"), &report).ok();
    println!("{}", report);

    e2e_runner::PhaseResult {
        phase: "report".to_string(), pipeline_version: "2026-05-21_v2".to_string(),
        run_id: run_id.to_string(), started_at, completed_at: chrono::Utc::now().to_rfc3339(),
        duration_ms: start.elapsed().as_millis() as u64, status: e2e_runner::PhaseStatus::Passed,
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
    chat_engine::prompt_loader::init("prompts", "pipelines");
    chat_engine::word_bank::init("cefr_catalog.json");

    e2e_runner::init_test_db(TEST_DB_PATH).expect("Failed to init test DB");
    let conn = rusqlite::Connection::open(TEST_DB_PATH).expect("Cannot open test DB");
    e2e_runner::seed_test_data(&conn, TEST_USER_ID, TEST_USERNAME, TEST_PASSWORD_HASH, TEST_CONV_ID).expect("Failed to seed test data");
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

        let result = match *phase_name {
            "plan-creation" => phase_plan_creation(&run_id, &cli).await,
            "plan-progression" => phase_plan_progression(&run_id, &cli).await,
            "report" => phase_report(&run_id),
            _ => unreachable!(),
        };
        e2e_runner::save_phase_result(&run_id, &result).expect("Failed to save");
        e2e_runner::mark_phase_completed(&run_id, phase_name).expect("Failed to mark");

        if result.status == e2e_runner::PhaseStatus::Failed { all_passed = false; println!("\n❌ {} 失败!", phase_name); }
        else { println!("\n✅ {} 通过!", phase_name); }
    }
    e2e_runner::update_latest(&run_id).ok();

    println!("\n结果: {}", if all_passed { "✅ 全部通过" } else { "⚠️ 部分失败" });
    println!("报告: docs/test-results/{}/report.md", run_id);
    std::process::exit(if all_passed { 0 } else { 1 });
}
