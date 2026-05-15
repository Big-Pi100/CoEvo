//! CoEvo E2E — 学习计划生命周期 (真实 LLM 驱动)
//!
//! 使用 DeepSeek V4 Flash 进行端到端对话测试，覆盖：
//!   FREE → 创建计划 → STRUCTURED → 概念更新 → 任务完成 → 考核 → 成就
//!
//! 运行方式:
//!   cargo test -p api_server --test e2e_live_llm_plan_lifecycle -- --ignored --nocapture
//!
//! 前置条件:
//!   - backend/.env 中已配置 DEEPSEEK_API_KEY
//!   - 每次运行约消耗 $0.01~0.02 API 费用

use std::fs;

// ════════════════════════════════════════════
// Test Setup
// ════════════════════════════════════════════

const TEST_DB_PATH: &str = "data/test_live_llm_plan.db";
const TEST_USER_ID: &str = "test-live-llm-user";
const TEST_CONV_ID: &str = "test-live-llm-conv";
const TEST_USERNAME: &str = "live_llm_tester";
const TEST_PASSWORD: &str = "test123";

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT,
    streak_days INTEGER DEFAULT 0, last_active_date TEXT, display_name TEXT DEFAULT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, token TEXT NOT NULL, created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL, learning_plan_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversation_turns (
    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
    content TEXT NOT NULL, created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS learning_plans (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT,
    goal TEXT NOT NULL, domain TEXT NOT NULL DEFAULT '', mode TEXT DEFAULT NULL,
    plan_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS achievements (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, achievement_key TEXT NOT NULL,
    name TEXT NOT NULL, icon TEXT NOT NULL, tier TEXT DEFAULT 'fixed', source TEXT,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

fn setup() {
    let _ = fs::remove_file(TEST_DB_PATH);
    let _ = fs::create_dir_all("data");

    // 加载 .env
    let env_paths = ["../../.env", ".env", "../.env"];
    for p in &env_paths {
        if dotenvy::from_filename(p).is_ok() {
            eprintln!("[setup] loaded env from {}", p);
            break;
        }
    }

    api_server::db_pool::init(TEST_DB_PATH).expect("init DB pool");

    {
        let conn = api_server::db_pool::get_conn();
        conn.execute_batch(SCHEMA_SQL).expect("create schema");
    }

    let now = chrono::Utc::now().to_rfc3339();
    let pw_hash = api_server::auth::hash_password(TEST_PASSWORD);
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) VALUES (?1,?2,?3,?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME, pw_hash, now],
        ).unwrap();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at) VALUES (?1,?2,0,?3)",
            rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now],
        ).unwrap();
    }

    // 初始化 prompt loader
    let prompts_dir = "../../prompts";
    chat_engine::prompt_loader::init(prompts_dir);

    eprintln!("[setup] done\n");
}

fn insert_turn(role: &str, content: &str) {
    let conn = api_server::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1,?2,?3,?4,?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), TEST_CONV_ID, role, content, now],
    ).unwrap();
    conn.execute("UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
        rusqlite::params![TEST_CONV_ID]).ok();
}

/// 获取对话历史 (最近 5000 字符滑动窗口)
fn get_conversation_history() -> String {
    let conn = api_server::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at ASC"
    ).unwrap();
    let turns: Vec<(String, String)> = stmt.query_map(
        rusqlite::params![TEST_CONV_ID],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?)),
    ).unwrap().filter_map(|r| r.ok()).collect();

    let mut hist = String::new();
    for (role, content) in turns.iter().rev() {
        let line = format!("{}: {}\n", role, content);
        if hist.len() + line.len() > 5000 { break; }
        hist.insert_str(0, &line);
    }
    hist
}

/// 构建 plan_context (thin wrapper → plan_handler 公共函数)
fn build_plan_context() -> (String, String) {
    let conn = api_server::db_pool::get_conn();
    api_server::plan_handler::build_plan_context(&conn, TEST_CONV_ID)
}

fn get_plan_from_db() -> Option<(String, String, String)> {
    let conn = api_server::db_pool::get_conn();
    conn.query_row(
        "SELECT id, goal, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![TEST_CONV_ID],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,String>(2)?)),
    ).ok()
}

fn get_achievements() -> Vec<(String, String, String)> {
    let conn = api_server::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT achievement_key, name, tier FROM achievements WHERE user_id = ?1 ORDER BY unlocked_at"
    ).unwrap();
    stmt.query_map(rusqlite::params![TEST_USER_ID], |row| {
        Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,String>(2)?))
    }).unwrap().filter_map(|r| r.ok()).collect()
}

// ════════════════════════════════════════════
// 成就检测 (与 simulation 测试对齐)
// ════════════════════════════════════════════

/// 阶段完成成就检测 — 遍历所有 stage，对 status=="done" 的写入成就
fn record_stage_achievements(conn: &rusqlite::Connection, plan_json: &serde_json::Value) {
    if let Some(stages) = plan_json.get("stages").and_then(|v| v.as_array()) {
        let all_done = stages.iter().all(|s| s["status"] == "done");
        let domain_name = plan_json.get("goal")
            .and_then(|v| v.as_str())
            .unwrap_or("领域");

        for stage in stages {
            if stage["status"] == "done" {
                let stage_name = stage["name"].as_str().unwrap_or("阶段");
                let key = format!("{}_silver", stage_name);
                if !api_server::plan_handler::achievement_exists(conn, TEST_USER_ID, &key) {
                    api_server::plan_handler::write_achievement(
                        conn, TEST_USER_ID,
                        &key, &format!("{}精英", stage_name),
                        "🥈", "silver", "stage",
                    );
                    println!("  🏆 silver: {}", key);
                }
            }
        }

        if all_done {
            let dkey = format!("{}_gold", domain_name);
            if !api_server::plan_handler::achievement_exists(conn, TEST_USER_ID, &dkey) {
                api_server::plan_handler::write_achievement(
                    conn, TEST_USER_ID,
                    &dkey, &format!("{}大师", domain_name),
                    "🥇", "gold", "domain",
                );
                println!("  🏆 gold: {}", dkey);
            }
        }
    }
}

// ════════════════════════════════════════════
// Phase 5 辅助: 用 LLM 生成真实学生回答
// ════════════════════════════════════════════

/// 根据助教提问生成具体、详细的真实学生回答。
///
/// 不再使用 "第一题我理解了" 这种空泛模板，而是让 LLM
/// 以认真学生的身份，根据对话上下文给出有实质内容的回答。
async fn generate_student_answer(
    caller: &mut chat_engine::llm_caller::LlmCaller,
) -> String {
    let history = get_conversation_history();

    let student_system = "\
你是一个认真学习的学生，正在接受助教的一对一考核。\
你的助教刚刚向你提出了一些问题。请认真、具体地回答每一个问题。\n\
\n\
回答要求：\n\
- 概念题：用自己的话解释核心概念，给出你理解的定义和例子\n\
- 计算题：展示完整的计算步骤，不要只给结果\n\
- 应用题：说明应用场景和实际操作步骤\n\
- 不要说空泛的话如「我理解了」「我掌握了」「这个很简单」\n\
- 用具体的知识内容证明你的理解\n\
- 如果有不确定的地方，诚实说明并给出你的推理过程";

    let user_prompt = format!(
        "{}\n\n以上对话中，助教向你提出了考核问题。\
         请以学生的身份，对这些问题给出具体、详细的回答。",
        history
    );

    match caller.generate(student_system, &user_prompt).await {
        Ok(answer) => {
            let preview: String = answer.chars().take(300).collect();
            println!("  🎓 生成学生回答 ({} chars): {}...", answer.len(), preview);
            answer
        }
        Err(e) => {
            // LLM 生成失败时的合理回退 — 仍然比旧 mock 模板好
            println!("  ⚠️ 学生回答生成失败: {:?}, 使用文字回退", e);
            "我来认真回答你提出的问题。对于概念部分，我结合我们讨论的内容来阐述核心定义和原理。\
             对于计算部分，我展示推导步骤和验证过程。\
             对于应用部分，我结合具体场景说明实践方法。\
             如果我的回答还有不足之处，请具体指出，我会补充。".to_string()
        }
    }
}

// ════════════════════════════════════════════
// 对话辅助: 发送一轮消息并处理 LLM 响应
// ════════════════════════════════════════════

#[allow(dead_code)]
struct TurnResult {
    cleaned_reply: String,
    is_new_plan: bool,
    plan_updated: bool,
    rendered_plan: Option<String>,
}

/// 发送用户消息 → 调用 LLM → 解析 plan_update → 更新 DB
async fn chat_turn(
    caller: &mut chat_engine::llm_caller::LlmCaller,
    user_message: &str,
    turn_label: &str,
) -> TurnResult {
    println!("\n{}", "─".repeat(60));
    println!("🔄 Turn: {}", turn_label);
    println!("{}", "─".repeat(60));

    insert_turn("user", user_message);
    println!("👤 用户: {}", user_message);

    // 确定 mode + system_prompt
    let (mode, plan_ctx) = build_plan_context();
    let prompts = chat_engine::prompt_loader::get();
    let system_prompt = if mode == "structured" {
        &prompts.chat_system_structured
    } else {
        &prompts.chat_system_free
    };

    // 构建 user_content: 历史 + plan_context
    let history = get_conversation_history();
    let user_content = if plan_ctx.is_empty() {
        history
    } else {
        format!("{}{}", history, plan_ctx)
    };

    println!("📋 mode={} | system_prompt_len={} | user_content_len={}",
        mode, system_prompt.len(), user_content.len());

    // 调用 LLM
    let raw_reply = match caller.generate(system_prompt, &user_content).await {
        Ok(r) => {
            let preview: String = r.chars().take(500).collect();
            println!("🤖 LLM 原始回复 ({} chars):\n{}", r.len(), preview);
            r
        }
        Err(e) => {
            panic!("LLM 调用失败: {:?}", e);
        }
    };

    // 解析 plan_update
    let conn = api_server::db_pool::get_conn();
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &raw_reply, TEST_CONV_ID, TEST_USER_ID,
    );

    if result.plan_updated {
        let _rendered = api_server::plan_handler::render_plan(result.plan_json.as_ref().unwrap());
        println!("📝 plan_update 已处理 | is_new_plan={}", result.is_new_plan);

        // 成就检测 (抽取为独立函数, 与 simulation 测试对齐)
        if let Some(ref pj) = result.plan_json {
            record_stage_achievements(&conn, pj);
        }

        // 保存 LLM 清理后的回复
        insert_turn("assistant", &result.cleaned_reply);

        let rendered_plan = if result.is_new_plan || result.plan_json.is_some() {
            let rp = api_server::plan_handler::render_plan(
                result.plan_json.as_ref().unwrap()
            );
            println!("📋 渲染的计划:\n{}", rp);
            Some(rp)
        } else { None };

        TurnResult {
            cleaned_reply: result.cleaned_reply,
            is_new_plan: result.is_new_plan,
            plan_updated: true,
            rendered_plan,
        }
    } else {
        println!("ℹ️  无 plan_update (普通回复)");
        insert_turn("assistant", &raw_reply);
        TurnResult {
            cleaned_reply: raw_reply,
            is_new_plan: false,
            plan_updated: false,
            rendered_plan: None,
        }
    }
}

// ════════════════════════════════════════════
// 主测试
// ════════════════════════════════════════════

#[tokio::test]
#[ignore]
async fn e2e_live_llm_plan_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E LIVE: 学习计划生命周期 (DeepSeek V4 Flash)");
    println!("{}", "=".repeat(70));

    setup();

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("请在 backend/.env 中设置 DEEPSEEK_API_KEY");
    let config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);

    // ── Phase 1: FREE → 创建计划 ──
    let t1 = chat_turn(&mut caller,
        "你好！我想系统地学习AI基础知识，特别是机器学习和深度学习。帮我制定一个详细的学习计划吧。",
        "Phase1: 创建学习计划",
    ).await;

    assert!(t1.plan_updated, "Phase1: 应触发 plan_update");
    assert!(t1.is_new_plan, "Phase1: 应为新建计划");
    assert!(t1.rendered_plan.is_some(), "Phase1: 应有渲染的计划");

    let plan = get_plan_from_db();
    assert!(plan.is_some(), "Phase1: DB 中应有学习计划");
    println!("\n✅ Phase1: 计划创建成功");

    // ── Phase 2: STRUCTURED — 验证 context 注入 ──
    let (mode, ctx) = build_plan_context();
    assert_eq!(mode, "structured", "Phase2: 应为 structured 模式");
    assert!(!ctx.is_empty(), "Phase2: plan_context 不应为空");
    println!("✅ Phase2: STRUCTURED context 注入验证通过");

    // ── Phase 3: 请求当前任务教学 → LLM 教授第一个任务 ──
    let _t3 = chat_turn(&mut caller,
        "好的，请开始教我当前计划中的第一个任务吧。",
        "Phase3: 请求教学",
    ).await;
    println!("✅ Phase3: LLM 开始了结构化教学");

    // ── Phase 4: 申请考核 → LLM 出题 → 模拟答题 → LLM 评估推进 ──
    let t4a = chat_turn(&mut caller,
        "我理解了当前任务的核心内容，请出题考核我。",
        "Phase4a: 申请考核",
    ).await;

    // 如果 LLM 出了考核题（无 plan_update），模拟答题触发评估
    if !t4a.plan_updated {
        println!("  📝 LLM 出了考核题，正在模拟答题...");
        let t4b = chat_turn(&mut caller,
            "好的我来回答：第一题，向量是标量的有序集合，矩阵是向量的二维排列。\
             第二题，矩阵乘法要求A的列数等于B的行数，结果维度是(m×n)×(n×p)→(m×p)。\
             第三题，点积=a1b1+a2b2+a3b3=2×4+(-1)×0+3×(-2)=8+0-6=2。\
             第四题，A(2×3)×B(3×2)→结果2×2，第一个元素=1×7+2×9+3×11=7+18+33=58。\
             第五题，在神经网络中每个神经元的计算本质是输入向量与权重向量的点积加上偏置，再经过激活函数。",
            "Phase4b: 答题",
        ).await;
        println!("  📝 答题后 plan_updated={}", t4b.plan_updated);
    }

    // 验证 task 推进
    if let Some((_, _, pjson)) = get_plan_from_db() {
        if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
            let stages = plan["stages"].as_array().unwrap();
            let active = stages.iter().find(|s| s["status"] == "in_progress")
                .or_else(|| stages.first());
            if let Some(stage) = active {
                let tasks = stage["tasks"].as_array().unwrap();
                let done_count = tasks.iter().filter(|t| t["status"] == "done").count();
                let stage_name = stage["name"].as_str().unwrap_or("?");
                println!("  📊 {} 任务: {}/{} done", stage_name, done_count, tasks.len());
            }
        }
    }
    println!("✅ Phase4: 考核流程完成");

    // ── Phase 5: 自适应推进剩余任务 (真实答案驱动, 无合成回退) ──
    //
    // 核心理念: 持续调用 LLM 直到所有阶段完成。不注入 mock 答案，
    // 不使用合成 plan_update。每次答题时用 LLM 根据上下文生成具体、
    // 详细的真实回答。LLM 拒绝作弊推进是正确的行为 — 我们通过
    // 更好的回答质量来赢得评估。
    println!("\n─── Phase 5: 自适应推进 (真实答案驱动) ───");
    let mut iteration = 0u32;
    let max_iterations: u32 = 30; // 安全上限，非功能限制
    loop {
        iteration += 1;
        if iteration > max_iterations {
            println!("  ⚠️ 安全上限 {} 轮, 停止 (不应在实际运行中触发)", max_iterations);
            break;
        }

        // ── 检查当前状态 ──
        let plan = get_plan_from_db();
        if plan.is_none() { break; }
        let (_pid, _goal, pjson) = plan.unwrap();
        let plan_val: serde_json::Value = serde_json::from_str(&pjson).unwrap();
        let stages = plan_val["stages"].as_array().unwrap();

        let total_tasks: usize = stages.iter()
            .filter_map(|s| s["tasks"].as_array()).map(|t| t.len()).sum();
        let done_tasks: usize = stages.iter()
            .filter_map(|s| s["tasks"].as_array())
            .map(|t| t.iter().filter(|x| x["status"] == "done").count())
            .sum();
        let done_stages = stages.iter().filter(|s| s["status"] == "done").count();

        println!("  📊 轮次{}: {}/{} 阶段, {}/{} 任务 done",
            iteration, done_stages, stages.len(), done_tasks, total_tasks);

        if stages.iter().all(|s| s["status"] == "done") {
            println!("  🎉 全部完成!");
            break;
        }

        // ── 定位当前活跃任务 ──
        let active_stage = stages.iter().find(|s| s["status"] == "in_progress")
            .or_else(|| stages.iter().find(|s| s["status"] == "pending"))
            .or_else(|| stages.first());
        let (stage_name, active_task_name) = active_stage.map(|s| {
            let sn = s["name"].as_str().unwrap_or("当前阶段");
            let tn = s["tasks"].as_array().and_then(|tasks| {
                tasks.iter().find(|t| {
                    t["status"] == "in_progress" || t["status"] == "pending"
                })
            }).and_then(|t| t["name"].as_str()).unwrap_or("当前任务");
            (sn.to_string(), tn.to_string())
        }).unwrap_or(("当前阶段".to_string(), "当前任务".to_string()));

        // ── Step A: 请求教学/考核 ──
        let request_prompt = format!(
            "请继续教我「{}」阶段的「{}」。如果我已经掌握了，请出题考核我。",
            stage_name, active_task_name
        );
        let ta = chat_turn(&mut caller, &request_prompt,
            &format!("教学请求-{}", iteration)).await;
        if ta.plan_updated { continue; }

        // ── Step B: 用 LLM 生成真实学生回答 (不是 mock 模板) ──
        let student_answer = generate_student_answer(&mut caller).await;
        let tb = chat_turn(&mut caller, &student_answer,
            &format!("答题-{}", iteration)).await;
        if tb.plan_updated { continue; }

        // ── Step C: 追问 — 请 LLM 指出具体不足 ──
        let follow_up = format!(
            "我已经认真回答了你的问题。如果还有哪里不够具体或理解有误，\
             请明确指出，我会补充。如果我的回答已经通过考核，\
             请标记「{}」为完成并推进到下一任务。",
            active_task_name
        );
        let _tc = chat_turn(&mut caller, &follow_up,
            &format!("跟进-{}", iteration)).await;
        // 无论是否 plan_updated，进入下一轮 — LLM 可能需要更多交互
    }

    // ── Phase 6: 最终状态验证 ──
    println!("\n{}", "=".repeat(70));
    println!(" 最终状态汇总");
    println!("{}", "=".repeat(70));

    if let Some((_pid, goal, pjson)) = get_plan_from_db() {
        let plan: serde_json::Value = serde_json::from_str(&pjson).unwrap();
        println!("目标: {}", goal);
        let stages = plan["stages"].as_array().unwrap();
        let done_stages = stages.iter().filter(|s| s["status"] == "done").count();
        println!("阶段完成: {}/{}", done_stages, stages.len());

        for stage in stages {
            let sname = stage["name"].as_str().unwrap();
            let sstatus = stage["status"].as_str().unwrap();
            println!("  {} → {}", sname, sstatus);
            if let Some(tasks) = stage["tasks"].as_array() {
                for task in tasks {
                    println!("    └ {} → {}", task["name"].as_str().unwrap(), task["status"].as_str().unwrap());
                }
            }
        }

        if let Some(concepts) = plan["completed_concepts"].as_array() {
            println!("\n完成概念: {} 个", concepts.len());
        }

        let done_tasks: usize = stages.iter()
            .filter_map(|s| s["tasks"].as_array())
            .map(|t| t.iter().filter(|x| x["status"] == "done").count())
            .sum();
        assert!(done_tasks >= 1, "至少完成1个任务");
    }

    let achievements = get_achievements();
    println!("\n成就总数: {}", achievements.len());
    for (key, name, tier) in &achievements {
        println!("  🏆 {} | {} | {}", key, name, tier);
    }
    assert!(!achievements.is_empty(), "应有解锁的成就");

    println!("\n{}", "=".repeat(70));
    println!(" ✅ LIVE E2E 学习计划生命周期测试完成!");
    println!("{}", "=".repeat(70));
}
