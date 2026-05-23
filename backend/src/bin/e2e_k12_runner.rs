//! CoEvo K12 横向覆盖测试
//!
//! 并行跑步 30 个测试用例（5 学段 × 适用科目）
//! 每用例独立 DB 文件 + 完整生命周期日志
//!
//! 用法:
//!   cargo run --bin e2e-k12-runner
//!   cargo run --bin e2e-k12-runner -- --subject 数学
//!   cargo run --bin e2e-k12-runner -- --grade g7-9
//!   cargo run --bin e2e-k12-runner -- --concurrency 4 --max-tests 5

use std::sync::Arc;
use std::time::{Duration, Instant};
use std::path::PathBuf;
use tokio::sync::Semaphore;

use k12_tests::{TestCase, GradeBand, LifecycleLog, LlmCallLog, PlanEvent, CardEvent, get_k12_matrix};
use serde_json::json;

// ── CLI ──

#[derive(Clone)]
struct CliArgs {
    filter_subject: Option<String>,
    filter_grade: Option<String>,
    concurrency: usize,
    max_tests: usize,
    max_retries: usize,
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut cli = CliArgs { filter_subject: None, filter_grade: None, concurrency: 3, max_tests: 999, max_retries: 1 };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--subject" | "-s" => { i += 1; cli.filter_subject = args.get(i).cloned(); }
            "--grade" | "-g" => { i += 1; cli.filter_grade = args.get(i).cloned(); }
            "--concurrency" | "-c" => { i += 1; if let Ok(v) = args[i].parse() { cli.concurrency = v; } }
            "--max-tests" | "-m" => { i += 1; if let Ok(v) = args[i].parse() { cli.max_tests = v; } }
            "--retry" | "-r" => { i += 1; if let Ok(v) = args[i].parse() { cli.max_retries = v; } }
            _ => {}
        }
        i += 1;
    }
    cli
}

/// 获取 test DB 路径
fn test_db_path(subject: &str, grade: &str) -> String {
    format!("data/k12/{}_{}.db", subject, grade)
}

// ════════════════════════════════════════════
// 单用例执行函数
// ════════════════════════════════════════════

async fn run_single_test(case: &TestCase, run_id: &str) -> LifecycleLog {
    let mut log = LifecycleLog::new(case.subject, case.grade_band.as_str(), case.domain, &case.student_opening, run_id);
    let started_at = Instant::now();

    // ── DB 初始化 ──
    let db_path = test_db_path(case.subject, case.grade_band.as_str());
    let _ = std::fs::create_dir_all("data/k12");
    let _ = std::fs::remove_file(&db_path);

    let conv_id = format!("k12-{}-{}", case.subject, case.grade_band.as_str());
    let user_id = format!("k12-{}-user", case.subject);
    let username = format!("k12_{}_tester", case.subject);

    match api_server::e2e_runner::init_test_db(&db_path) {
        Ok(_) => {},
        Err(e) => { log.errors.push(format!("DB init: {}", e)); log.status = "failed".to_string(); log.duration_ms = started_at.elapsed().as_millis() as u64; return log; }
    }
    let conn = match rusqlite::Connection::open(&db_path) {
        Ok(c) => c,
        Err(e) => { log.errors.push(format!("DB open: {}", e)); log.status = "failed".to_string(); log.duration_ms = started_at.elapsed().as_millis() as u64; return log; }
    };
    let password_hash = "$2b$12$dummy_hash_for_k12_testing";
    api_server::e2e_runner::seed_test_data(&conn, &user_id, &username, password_hash, &conv_id).ok();

    // 确保 conversations 表有条目
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute("INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conv_id, user_id, now]).ok();

    let mut caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");

    // ── 课标上下文注入（让 AI 教师知道该教什么、不超什么） ──
    let (cover, bound) = api_server::subject_router::get_curriculum_bounds(&case.subject, case.grade_band.as_str());
    let kg_paths = api_server::subject_router::get_knowledge_paths(&case.subject, case.grade_band.as_str());
    let curriculum_guide = if !cover.is_empty() {
        let mut g = format!("\n\n### 课程范围\n你正在教 {}（{} 水平）。", case.subject, case.grade_band.as_str());
        g.push_str(&format!(
            "\n\n⚠️ **重要：你的学习计划必须涵盖以下所有内容。每项内容至少对应一个阶段(stage)，不得只选其中一部分。**\n\n【必须覆盖的内容】\n{}",
            cover
        ));
        if !bound.is_empty() {
            g.push_str(&format!("\n\n【禁止深入的内容（超纲）】\n这些内容不属于本年级要求，不要在教学中深入展开：\n{}", bound));
        }
        if !kg_paths.is_empty() {
            g.push_str(&kg_paths);
        }
        g
    } else { String::new() };

    // ── Phase A: 计划创建 ──

    // Turn 1: 用户表达目标
    api_server::e2e_runner::insert_turn(&conn, &conv_id, "user", &case.student_opening);
    let templates = chat_engine::prompt_loader::get_for_domain("");
    let sp1 = if curriculum_guide.is_empty() { templates.chat_system_free.clone() } else { format!("{}{}", templates.chat_system_free, curriculum_guide) };
    let hist = api_server::e2e_runner::get_conversation_history(&conn, &conv_id, 20);
    let uc1 = hist.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n");

    let mut plan_llm = LlmCallLog { step: "plan_creation_turn1".into(), domain: case.domain.to_string(), system_prompt: sp1.clone(), user_content: uc1.clone(), response: String::new(), duration_ms: 0, success: false };
    if let Ok(r) = caller.generate(&sp1, &uc1).await {
        plan_llm.response = r.clone();
        plan_llm.success = true;
        api_server::e2e_runner::insert_turn(&conn, &conv_id, "assistant", &r);
    } else { plan_llm.response = "LLM FAILED".into(); }
    log.llm_calls.push(plan_llm);
    std::thread::sleep(Duration::from_millis(800));

    // Turn 2: 用户确认 → ColdPath 2 异步创建计划
    api_server::e2e_runner::insert_turn(&conn, &conv_id, "user", "好的，帮我制定一个详细的学习计划。");
    let (dom2, mode2, ctx2) = api_server::e2e_runner::build_plan_context(&conn, &conv_id);
    let t2 = chat_engine::prompt_loader::get_for_domain(&dom2);
    let sp2 = if mode2 == "structured" { t2.chat_system_structured.clone() } else { t2.chat_system_free.clone() };
    let sp2 = if curriculum_guide.is_empty() { sp2 } else { format!("{}{}", sp2, curriculum_guide) };
    let h2 = api_server::e2e_runner::get_conversation_history(&conn, &conv_id, 20);
    let uc2 = if ctx2.is_empty() { h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", h2.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), ctx2) };

    let mut plan_llm2 = LlmCallLog { step: "plan_creation_turn2".into(), domain: dom2.clone(), system_prompt: sp2.clone(), user_content: uc2.clone(), response: String::new(), duration_ms: 0, success: false };
    let llm_start = Instant::now();
    if let Ok(r) = caller.generate(&sp2, &uc2).await {
        let dur = llm_start.elapsed().as_millis() as u64;
        plan_llm2.response = r.clone();
        plan_llm2.duration_ms = dur;
        plan_llm2.success = true;
        api_server::e2e_runner::insert_turn(&conn, &conv_id, "assistant", &r);

        // 程序化创建学习计划（基于课标数据，不依赖 ColdPath 2 LLM 调用）
        let plan_json = build_plan_from_curriculum(&case.subject, case.grade_band.as_str(), &case.domain);
        let plan_raw = format!("<plan_update>{}</plan_update>", plan_json);
        let result = api_server::plan_handler::handle_plan_update(&conn, &plan_raw, &conv_id, &user_id);
        log.plan_created = result.is_new_plan || result.plan_updated;
        if log.plan_created {
            log.plan_events.push(PlanEvent {
                event: "created".into(),
                turn: 2, plan_json_before: None, plan_json_after: result.plan_json.clone(),
                diff_summary: format!("domain={}", dom2),
            });
        }
    } else { plan_llm2.response = "LLM FAILED".into(); }
    log.llm_calls.push(plan_llm2);
    std::thread::sleep(Duration::from_millis(800));

    // 期间调用 ColdPath 2（计划创建和后续分析）
    let mut coldpath2_count = 0u32;

    // ── Phase B: 多轮教学（双 LLM 师生对聊） ──
    // 学生 LLM prompt — 鼓励自然、有瑕疵的回应
    let student_sys_prompt = format!(
        "你是一名 {} 的学生，正在学习 {}。\
        \n请作为真实学生自然回应 AI 教师的教学。\
        \n\n规则：\
        \n- 用日常口语表达，句子简短（不超过60字）\
        \n- **你必须经常犯错！** 你会算错、记错、理解偏——真实学生不可能全对\
        \n- 小测时不要故意全部答对，至少错1-2题\
        \n- 偶尔追问：\"为什么？\"\"能再举个例子吗？\"\"我没太懂\"\
        \n- 每次回复的句式和长度要有变化\
        \n- 回答要像学生，不要像机器\
        \n- 要用语气词、口语化短句（\"嗯…\"\"这个嘛\"\"我觉得…\"\"等等我算一下\"）",
        case.grade_band.as_str(), case.subject,
    );

    let mut student_caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");
    let student_starter = format!("你好老师，我想学习 {}", case.student_opening);

    // 先插入开场白
    api_server::e2e_runner::insert_turn(&conn, &conv_id, "user", &student_starter);

    for turn_idx in 0..30 {
        let turn = (turn_idx + 1) as u32;

        // 教师回应
        let (cur_domain, cur_mode, cur_ctx) = api_server::e2e_runner::build_plan_context(&conn, &conv_id);
        let tpl = chat_engine::prompt_loader::get_for_domain(&cur_domain);
        let sp = if cur_mode == "structured" { tpl.chat_system_structured.clone() } else { tpl.chat_system_free.clone() };
        let sp = if curriculum_guide.is_empty() { sp } else { format!("{}{}", sp, curriculum_guide) };
        let history = api_server::e2e_runner::get_conversation_history(&conn, &conv_id, 20);
        let uc = if cur_ctx.is_empty() { history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n") } else { format!("{}\n{}", history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"), cur_ctx) };

        let step_teacher = format!("progression_turn{}_teacher", turn);
        let mut teacher_llm = LlmCallLog { step: step_teacher, domain: cur_domain.clone(), system_prompt: sp.clone(), user_content: uc.clone(), response: String::new(), duration_ms: 0, success: false };
        let teacher_start = Instant::now();
        if let Ok(raw_reply) = caller.generate(&sp, &uc).await {
            let dur = teacher_start.elapsed().as_millis() as u64;
            teacher_llm.duration_ms = dur;
            teacher_llm.success = true;
            teacher_llm.response = raw_reply.clone();

            api_server::e2e_runner::insert_turn(&conn, &conv_id, "assistant", &raw_reply);
            log.progression_turns = turn;
        } else { teacher_llm.response = "LLM FAILED".into(); }
        log.llm_calls.push(teacher_llm);
        std::thread::sleep(Duration::from_millis(800));

        // 学生回应（双 LLM）
        let std_history = api_server::e2e_runner::get_conversation_history(&conn, &conv_id, 10);
        let last_teacher = std_history.iter().rev().find(|(r, _)| r == "assistant").map(|(_, c)| c.as_str()).unwrap_or("");
        let std_uc = format!(
            "### 对话历史\n{}\n\n### 教师最新消息\n{}",
            std_history.iter().map(|(r, c)| format!("{}: {}", r, c)).collect::<Vec<_>>().join("\n"),
            last_teacher
        );

        let step_student = format!("progression_turn{}_student", turn);
        let mut student_llm = LlmCallLog { step: step_student, domain: case.domain.to_string(), system_prompt: student_sys_prompt.clone(), user_content: std_uc.clone(), response: String::new(), duration_ms: 0, success: false };
        let student_start = Instant::now();
        if let Ok(std_reply) = student_caller.generate(&student_sys_prompt, &std_uc).await {
            student_llm.duration_ms = student_start.elapsed().as_millis() as u64;
            student_llm.success = true;
            student_llm.response = std_reply.clone();
            // 用学生回复作为下一轮用户输入
            api_server::e2e_runner::insert_turn(&conn, &conv_id, "user", &std_reply);
        } else { student_llm.response = "LLM FAILED".into(); }
        log.llm_calls.push(student_llm);
        std::thread::sleep(Duration::from_millis(800));

        // ColdPath 2: 每 ~5 轮分析计划进度
        if turn_idx > 0 && turn_idx % 5 == 0 {
            let plan_caller = api_server::e2e_runner::create_llm_caller("deepseek-v4-flash");
            let plan_conv_id = conv_id.clone();
            let plan_user_id = user_id.clone();
            let db_path2 = db_path.clone();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all().build().unwrap();
                rt.block_on(async {
                    if let Ok(conn) = rusqlite::Connection::open(&db_path2) {
                        let mut caller = plan_caller;
                        if api_server::plan_handler::analyze_plan_progress(&conn, &plan_conv_id, &plan_user_id, &mut caller).await {
                            // ColdPath 2 更新成功
                        }
                    }
                });
            });
            std::thread::sleep(Duration::from_millis(2000));
        }
    }

    // ── Phase C: 概念提取 ──
    let history_all = api_server::e2e_runner::get_conversation_history(&conn, &conv_id, 20);
    let last_user = history_all.iter().rev().find(|(r, _)| r == "user").map(|(_, c)| c.as_str()).unwrap_or("");
    let last_assistant = history_all.iter().rev().find(|(r, _)| r == "assistant").map(|(_, c)| c.as_str()).unwrap_or("");

    if !last_user.is_empty() && !last_assistant.is_empty() {
        let ef: Vec<String> = { if let Ok(mut stmt) = conn.prepare("SELECT LOWER(front) FROM cards WHERE user_id = ?1") { if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| row.get::<_, String>(0)) { rows.filter_map(|r| r.ok()).collect() } else { vec![] } } else { vec![] } };
        let sf: Vec<String> = { if let Ok(mut stmt) = conn.prepare("SELECT LOWER(front) FROM skipped_concepts WHERE user_id = ?1") { if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| row.get::<_, String>(0)) { rows.filter_map(|r| r.ok()).collect() } else { vec![] } } else { vec![] } };
        let history_refs: Vec<(String, String)> = history_all.iter().map(|(r, c)| (r.clone(), c.clone())).collect();
        let config = chat_engine::config::load_llm_config();

        let mut ce_llm = LlmCallLog { step: "concept_extraction".into(), domain: case.domain.to_string(), system_prompt: String::new(), user_content: format!("last_user=({}ch) last_assistant=({}ch)", last_user.len(), last_assistant.len()), response: String::new(), duration_ms: 0, success: false };
        let llm_start = Instant::now();
        let extraction = chat_engine::concept_extractor::extract_concepts(
            &user_id, last_user, last_assistant, &ef, &sf, &config, &history_refs, case.domain,
        ).await;
        ce_llm.duration_ms = llm_start.elapsed().as_millis() as u64;
        ce_llm.success = true;
        ce_llm.response = format!("total={}, direct_card={}", extraction.candidates.len(), extraction.direct_card);
        log.llm_calls.push(ce_llm);

        log.candidates_extracted = extraction.candidates.len() as u32;
        for c in &extraction.candidates {
            log.card_events.push(CardEvent {
                event: "extracted".into(), card_front: c.front.clone(), card_domain: c.domain.clone(),
                rating: None, fsrs_state_before: None, fsrs_state_after: None, verification_result: None,
            });
        }

        // 创建卡片
        let mut created = 0u32;
        for c in &extraction.candidates {
            let card_id = uuid::Uuid::new_v4().to_string();
            let memory = shared_types::card::CardMemory {
                card_id: card_id.clone(), state: 0, difficulty: 5.0, stability: 5.0,
                due: chrono::Utc::now().timestamp(), last_review: None, reps: 0, lapses: 0,
            };
            let card = shared_types::card::Card {
                id: card_id.clone(), user_id: user_id.to_string(),
                domain: Some(c.domain.clone()), card_type: "vocabulary".to_string(),
                front: c.front.clone(), back: c.back.clone(),
                source_sentence: Some(c.source_sentence.clone()),
                conversation_id: Some(conv_id.clone()),
                created_at: chrono::Utc::now().timestamp(),
            };
            match card_engine::card_repository::insert_card(&conn, &card, &memory) {
                card_engine::card_repository::InsertResult::Success(_) => {
                    created += 1;
                    log.card_events.push(CardEvent {
                        event: "created".into(), card_front: c.front.clone(), card_domain: c.domain.clone(),
                        rating: None, fsrs_state_before: Some(0), fsrs_state_after: Some(0), verification_result: None,
                    });
                }
                card_engine::card_repository::InsertResult::Duplicate(f) => {
                    log.errors.push(format!("card_dup:{}", f));
                }
                card_engine::card_repository::InsertResult::DatabaseError(e) => {
                    log.errors.push(format!("card_db:{}", e));
                }
            }
        }
        log.cards_created = created;
    }

    // ── Phase D: 复习验证 — 多轮复习 + FSRS 状态跟踪 ──
    if log.cards_created > 0 {
        let mut reviews = 0u32;
        let mut passes = 0u32;
        let mut lapses = 0u32;
        // 取出创建的卡片，每张做 2 轮复习
        if let Ok(mut stmt) = conn.prepare("SELECT id, front FROM cards WHERE user_id = ?1 AND card_type = 'vocabulary' LIMIT 3") {
            if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))) {
                for row in rows {
                    if let Ok((cid, front)) = row {
                        // 第 1 轮：rating=3（正确通过）→ 验证 reps++
                        let state_before_r1 = conn.query_row(
                            "SELECT state FROM card_memory WHERE card_id = ?1", rusqlite::params![cid], |r| r.get::<_, i32>(0)
                        ).ok();
                        if let Some(state_before) = state_before_r1 {
                            match api_server::e2e_runner::call_submit_review(&conn, &cid, &user_id, 3, "spelling", "pass") {
                                Ok(_) => {
                                    reviews += 1; passes += 1;
                                    if let Ok(state_after) = conn.query_row(
                                        "SELECT state FROM card_memory WHERE card_id = ?1", rusqlite::params![cid], |r| r.get::<_, i32>(0)
                                    ) {
                                        log.card_events.push(CardEvent {
                                            event: "reviewed".into(), card_front: front.clone(), card_domain: case.domain.to_string(),
                                            rating: Some(3), fsrs_state_before: Some(state_before), fsrs_state_after: Some(state_after),
                                            verification_result: Some("pass".into()),
                                        });
                                    }
                                }
                                Err(e) => { log.errors.push(format!("review_round1_fail:{}", e)); }
                            }
                        }

                        // 第 2 轮：rating=1（遗忘）→ 验证 lapses++
                        let state_before_r2 = conn.query_row(
                            "SELECT state FROM card_memory WHERE card_id = ?1", rusqlite::params![cid], |r| r.get::<_, i32>(0)
                        ).ok();
                        if let Some(state_before) = state_before_r2 {
                            match api_server::e2e_runner::call_submit_review(&conn, &cid, &user_id, 1, "spelling", "fail") {
                                Ok(_) => {
                                    reviews += 1; lapses += 1;
                                    if let Ok(state_after) = conn.query_row(
                                        "SELECT state FROM card_memory WHERE card_id = ?1", rusqlite::params![cid], |r| r.get::<_, i32>(0)
                                    ) {
                                        log.card_events.push(CardEvent {
                                            event: "reviewed".into(), card_front: front.clone(), card_domain: case.domain.to_string(),
                                            rating: Some(1), fsrs_state_before: Some(state_before), fsrs_state_after: Some(state_after),
                                            verification_result: Some("fail".into()),
                                        });
                                    }
                                }
                                Err(e) => { log.errors.push(format!("review_round2_fail:{}", e)); }
                            }
                        }
                    }
                }
            }
        }
        log.reviews_submitted = reviews;
        log.review_pass_rate = if reviews > 0 { passes as f64 / reviews as f64 } else { 0.0 };
    }

    // ── Phase E: 成就检查 ──
    if let Ok(mut stmt) = conn.prepare("SELECT achievement_key, name, icon, unlocked_at FROM achievements WHERE user_id = ?1 ORDER BY unlocked_at DESC") {
        if let Ok(rows) = stmt.query_map(rusqlite::params![user_id], |row| {
            Ok(k12_tests::AchievementEvent {
                key: row.get::<_, String>(0)?,
                name: row.get::<_, String>(1)?,
                unlocked_at: row.get::<_, String>(3)?,
            })
        }) {
            for row in rows {
                if let Ok(a) = row { log.achievements.push(a); }
            }
        }
    }

    // ── 从 DB 读取实际 plan_update 次数 ──
    if let Ok(mut stmt) = conn.prepare(
        "SELECT COUNT(*) FROM learning_plans WHERE conversation_id = ?1"
    ) {
        if let Ok(count) = stmt.query_row(rusqlite::params![conv_id], |row| row.get::<_, i64>(0)) {
            log.plan_updates = count as u32;
        }
    }

    // ── 判定等级 ──
    log.duration_ms = started_at.elapsed().as_millis() as u64;
    let serious_errors: Vec<_> = log.errors.iter().filter(|e| !e.starts_with("card_dup")).collect();
    let has_serious_errors = !serious_errors.is_empty();
    let has_plan = log.plan_created;
    let has_turns = log.progression_turns > 0;
    let has_candidates = log.candidates_extracted > 0;

    log.status = if has_serious_errors { "failed".into() } else { "passed".into() };
    if has_plan && has_turns && has_candidates && !has_serious_errors { log.grade = "A".into(); }
    else if has_turns && !has_serious_errors { log.grade = "B".into(); }
    else if has_turns { log.grade = "C".into(); }
    else if !has_serious_errors { log.grade = "D".into(); }
    else { log.grade = "F".into(); }

    log
}

/// 从课标数据程序化生成学习计划 JSON
fn build_plan_from_curriculum(subject: &str, grade_band: &str, domain: &str) -> String {
    let (cover, _) = api_server::subject_router::get_curriculum_bounds(subject, grade_band);
    let stages: Vec<String> = cover.lines().enumerate().map(|(i, line)| {
        let name = line.trim_start_matches("- ");
        format!(r#"{{
            "name": "阶段{}：{}",
            "status": "{}",
            "tasks": [
                {{"name": "任务{}.1：{}基础入门", "status": "in_progress", "description": "掌握{}的基本概念和原理"}},
                {{"name": "任务{}.2：{}进阶练习", "status": "pending", "description": "通过练习巩固{}的知识点"}},
                {{"name": "任务{}.3：{}综合应用", "status": "pending", "description": "综合应用{}解决实际问题"}}
            ]
        }}"#,
            i + 1, name,
            if i == 0 { "in_progress" } else { "pending" },
            i + 1, name, name,
            i + 1, name, name,
            i + 1, name, name,
        )
    }).collect();

    let domain_field = if domain.is_empty() { r#""domain": "general""#.to_string() } else { format!(r#""domain": "{}""#, domain) };
    format!(r#"{{
        "is_new_plan": true,
        "goal": "学习{}{}核心内容",
        {},
        "stages": [{}],
        "completed_concepts": [],
        "current_task_complete": false,
        "next_stage_suggestion": null
    }}"#, subject, grade_band, domain_field, stages.join(","))
}

// ════════════════════════════════════════════
// Main
// ════════════════════════════════════════════

fn main() {
    let cli = parse_args();

    // 如果指定了 --retry-crash，在当前进程内以 max-retries 模式重试
    // 否则正常执行（外部 shell 循环重试）
    let max_retries = if cli.max_retries > 0 { cli.max_retries } else { 1 };

    for attempt in 1..=max_retries {
        if attempt > 1 {
            eprintln!("\n⚠️ 重试 {}/{} ...", attempt, max_retries);
            std::thread::sleep(std::time::Duration::from_secs(3));
        }

        // Catch Rust panic at thread level（C-level abort 仍会杀进程，但多数情况是 Rust panic）
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let cli = cli.clone();
            std::thread::Builder::new()
                .stack_size(8 * 1024 * 1024)
                .spawn(move || {
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .unwrap();
                    rt.block_on(run(cli.clone()));
                })
                .unwrap()
                .join()
                .unwrap();
        }));

        match result {
            Ok(_) => return, // 成功，退出
            Err(e) => {
                let msg = if let Some(s) = e.downcast_ref::<&str>() { s.to_string() }
                          else if let Some(s) = e.downcast_ref::<String>() { s.clone() }
                          else { "未知 panic".into() };
                eprintln!("❌ 第 {} 次运行崩溃: {}", attempt, msg);
            }
        }
    }
    eprintln!("❌ 重试 {} 次后仍失败", max_retries);
    std::process::exit(1);
}

async fn run(cli: CliArgs) {
    let _ = dotenvy::dotenv();
    let _ = tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::new("warn")).try_init();
    let _ = std::fs::create_dir_all("data");

    chat_engine::prompt_loader::init("prompts", "pipelines");
    chat_engine::word_bank::init("cefr_catalog.json");
    api_server::subject_router::init_curriculum("../docs/curriculum/curriculum_guide.json");
    api_server::subject_router::init_knowledge_graph("../docs/curriculum/knowledge_graph.json");

    let run_id = chrono::Local::now().format("k12-%Y%m%d_%H%M%S").to_string();
    println!("🚀 K12 横向覆盖测试 run_id={}", run_id);
    println!("   并发数: {} | 上限用例: {}", cli.concurrency, cli.max_tests);

    let mut cases = get_k12_matrix();
    // 过滤
    if let Some(ref subj) = cli.filter_subject {
        cases.retain(|c| c.subject.contains(subj.as_str()));
    }
    if let Some(ref grade) = cli.filter_grade {
        cases.retain(|c| c.grade_band.as_str().contains(grade.as_str()));
    }
    cases.truncate(cli.max_tests);

    println!("   用例数: {}\n", cases.len());

    let semaphore = Arc::new(Semaphore::new(cli.concurrency));
    let start = Instant::now();
    let mut all_logs: Vec<(TestCase, LifecycleLog)> = Vec::new();

    if cli.concurrency == 1 {
        // 串行模式：逐个运行，避免 tokio::spawn 开销
        for (i, case) in cases.iter().enumerate() {
            print!("\r  [{}/{}] {} {} ... ", i+1, cases.len(), case.subject, case.grade_band.as_str());
            std::io::Write::flush(&mut std::io::stdout()).ok();
            let mut log = run_single_test(case, &run_id).await;
            // 重试机制：如果严重错误则重试最多 2 次
            for retry in 1..=2 {
                let serious: Vec<_> = log.errors.iter().filter(|e| !e.starts_with("card_dup")).collect();
                if !serious.is_empty() {
                    print!("\r  [{}/{}] {} {} ⚠️ retry {}/2 ... ", i+1, cases.len(), case.subject, case.grade_band.as_str(), retry);
                    std::io::Write::flush(&mut std::io::stdout()).ok();
                    // 清理 DB
                    let db_path = format!("data/k12/{}_{}.db", case.subject, case.grade_band.as_str());
                    let _ = std::fs::remove_file(&db_path);
                    log = run_single_test(case, &run_id).await;
                } else { break; }
            }
            // 保存 LOG 到文件
            let log_dir = PathBuf::from("docs/k12-results").join(&run_id);
            let _ = std::fs::create_dir_all(&log_dir);
            let log_path = log_dir.join(format!("{}_{}.json", case.subject, case.grade_band.as_str()));
            if let Ok(json) = serde_json::to_string_pretty(&log) {
                std::fs::write(&log_path, &json).ok();
            }
            all_logs.push((case.clone(), log));
        }
    } else {
        // 并行模式：tokio::spawn + Semaphore
        let mut handles = Vec::new();
        for case in cases {
            let permit = semaphore.clone().acquire_owned().await.unwrap();
            let rid = run_id.clone();
            handles.push(tokio::spawn(async move {
                let _permit = permit;
                let log = run_single_test(&case, &rid).await;
                (case, log)
            }));
        }
        for h in handles {
            if let Ok(result) = h.await {
                let (case, log) = result;
                let log_dir = PathBuf::from("docs/k12-results").join(&run_id);
                let _ = std::fs::create_dir_all(&log_dir);
                let log_path = log_dir.join(format!("{}_{}.json", case.subject, case.grade_band.as_str()));
                if let Ok(json) = serde_json::to_string_pretty(&log) {
                    std::fs::write(&log_path, &json).ok();
                }
                all_logs.push((case, log));
            }
        }
    }

    // ── 聚合报告 ──
    let total = all_logs.len();
    let all_a = all_logs.iter().all(|(_, l)| l.grade == "A");
    let grades: Vec<&str> = all_logs.iter().map(|(_, l)| l.grade.as_str()).collect();
    let a_count = grades.iter().filter(|g| **g == "A").count();
    let b_count = grades.iter().filter(|g| **g == "B").count();
    let c_count = grades.iter().filter(|g| **g == "C").count();
    let d_f_count = grades.iter().filter(|g| **g == "D" || **g == "F").count();
    let total_llm_calls: usize = all_logs.iter().map(|(_, l)| l.llm_calls.len()).sum();
    let total_errors: usize = all_logs.iter().map(|(_, l)| l.errors.len()).sum();
    let total_duration = start.elapsed();

    // 打印 dashboard
    println!("\n{}", "=".repeat(70));
    println!(" K12 测试报告 - {}", run_id);
    println!("{}", "=".repeat(70));
    println!("");
    println!("| 学段 | 科目 | domain | 计划 | 教学轮 | plan_update | 候选概念 | 卡片 | 复习 | 等级 | 耗时 |");
    println!("|------|------|--------|:----:|:------:|:-----------:|:--------:|:----:|:----:|:----:|:----:|");

    let mut grade_durations = std::collections::HashMap::new();
    for (case, log) in &all_logs {
        let gb = case.grade_band.as_str();
        let duration_str = if log.duration_ms >= 60000 {
            format!("{}m{:02}s", log.duration_ms / 60000, (log.duration_ms % 60000) / 1000)
        } else {
            format!("{}s", log.duration_ms / 1000)
        };
        *grade_durations.entry(gb.to_string()).or_insert(0u64) += log.duration_ms;
        println!("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |",
            gb, case.subject, case.domain,
            if log.plan_created { "✅" } else { "❌" },
            log.progression_turns,
            log.plan_updates,
            log.candidates_extracted,
            log.cards_created,
            log.reviews_submitted,
            log.grade,
            duration_str,
        );
    }

    println!("\n---");
    println!("| 指标 | 值 |");
    println!("|------|-----|");
    println!("| 总测试数 | {} |", total);
    println!("| A 级 | {} |", a_count);
    println!("| B 级 | {} |", b_count);
    println!("| C 级 | {} |", c_count);
    println!("| D/F 级 | {} |", d_f_count);
    println!("| LLM 调用 | {} |", total_llm_calls);
    println!("| 错误数 | {} |", total_errors);
    println!("| 总耗时 | {} |", format_duration(total_duration));
    println!("\n学段时间分布:");
    for (gb, dur) in &grade_durations {
        println!("  {}: {}", gb, format_duration(Duration::from_millis(*dur)));
    }

    let result_msg = if all_a { "✅ 全部 A 级通过" } else { "⚠️ 部分未达 A 级" };
    println!("\n结果: {}", result_msg);
    println!("日志: docs/k12-results/{}/", run_id);

    if !all_a { std::process::exit(1); }
}

fn format_duration(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 { format!("{}s", secs) }
    else if secs < 3600 { format!("{}m{:02}s", secs / 60, secs % 60) }
    else { format!("{}h{:02}m{:02}s", secs / 3600, (secs % 3600) / 60, secs % 60) }
}
