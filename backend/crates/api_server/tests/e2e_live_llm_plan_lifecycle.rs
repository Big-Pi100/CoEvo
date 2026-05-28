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
    plan_content TEXT DEFAULT NULL, plan_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
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
            "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?1,?2,?3,?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME, pw_hash, now],
        ).unwrap();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at) VALUES (?1,?2,0,?3)",
            rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now],
        ).unwrap();
    }

    // 初始化 prompt loader (general + pipelines)
    let prompts_dir = "../../prompts";
    let pipelines_dir = "../../pipelines";
    chat_engine::prompt_loader::init(prompts_dir, pipelines_dir);

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
        "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at DESC LIMIT 10"
    ).unwrap();
    let turns: Vec<(String, String)> = stmt.query_map(
        rusqlite::params![TEST_CONV_ID],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?)),
    ).unwrap().filter_map(|r| r.ok()).collect();

    let mut hist = String::new();
    for (role, content) in turns.iter().rev() {
        hist.push_str(&format!("{}: {}\n", role, content));
    }
    hist
}

/// 构建 plan_context (thin wrapper → plan_handler 公共函数)
fn build_plan_context() -> (String, String, String) {
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

fn truncate_utf8(s: &str, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}

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
    let (domain, mode, plan_ctx) = build_plan_context();
    let prompts = chat_engine::prompt_loader::get_for_domain(&domain);
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
            let preview: String = r.chars().take(3000).collect();
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

    // 新计划：渲染但不检测成就（成就仅对进度更新触发）
    // 已有计划更新：渲染 + 成就检测
    if result.plan_updated {
        println!("📝 plan_update 已处理 | is_new_plan={}", result.is_new_plan);

        // 成就检测 — 仅对非新建计划的进度更新触发
        if !result.is_new_plan {
            if let Some(ref pj) = result.plan_json {
                record_stage_achievements(&conn, pj);
            }
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
    let (domain, mode, ctx) = build_plan_context();
    assert_eq!(mode, "structured", "Phase2: 应为 structured 模式");
    assert!(!domain.is_empty(), "Phase2: domain 不应为空");
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

// ════════════════════════════════════════════
// 回退机制专项测试: LLM 能否使用 reset_current_task
// ════════════════════════════════════════════

#[tokio::test]
#[ignore]
async fn e2e_live_revert_basic() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E LIVE: 回退机制基础测试");
    println!("{}", "=".repeat(70));

    setup();

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("DEEPSEEK_API_KEY not set in .env");

    use chat_engine::llm_caller::{LlmCaller, LlmConfig};
    let config = LlmConfig::deepseek_v4_flash(&api_key);
    let mut caller = LlmCaller::new(config);

    // ── Step 1: 创建学习计划 ──
    println!("\n─── Step 1: 创建计划 ───");
    let plan = serde_json::json!({
        "stages": [{
            "name": "基础概念",
            "status": "in_progress",
            "tasks": [
                {"name": "理解定义", "status": "in_progress"},
                {"name": "应用练习", "status": "pending"}
            ]
        }],
        "completed_concepts": []
    });
    let conn = api_server::db_pool::get_conn();
    conn.execute(
        "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at)
         VALUES ('p1', ?1, ?2, '数学基础', '', 'structured', ?3, '2024-01-01', '2024-01-01')",
        rusqlite::params![TEST_USER_ID, TEST_CONV_ID, plan.to_string()],
    ).unwrap();

    // ── Step 2: 模拟超前更新 ──
    println!("\n─── Step 2: 模拟 LLM 超前更新 (Task1→done, Task2→in_progress) ───");
    let premature = serde_json::json!({
        "stages": [{
            "name": "基础概念",
            "status": "in_progress",
            "tasks": [
                {"name": "理解定义", "status": "done"},
                {"name": "应用练习", "status": "in_progress"}
            ]
        }],
        "completed_concepts": ["定义概念"]
    });
    conn.execute(
        "UPDATE learning_plans SET plan_json=?1, updated_at='2024-01-02' WHERE id='p1'",
        rusqlite::params![premature.to_string()],
    ).unwrap();

    insert_turn("user", "好的，我们开始学习吧");
    insert_turn("assistant", "好的！今天我们学习数学基础。首先我们来理解定义...");

    // ── Step 3: 用户指出进度错误 ──
    println!("\n─── Step 3: 用户指出进度错误 ───");
    let user_msg = "STOP。我发现计划进度有问题：理解定义这个任务被错误标记为完成，但我根本没学会。\
这不是复习请求，而是计划状态错误。请在回复中用 <plan_update> 标签设置 reset_current_task 为 true 来回退。";

    let (domain, mode, plan_ctx) = build_plan_context();
    println!("当前 domain: {:?}, plan_context:\n{}", domain, plan_ctx);

    let prompts = chat_engine::prompt_loader::get_for_domain(&domain);
    let system_prompt = &prompts.chat_system_structured;
    let history = get_conversation_history();
    let user_content = format!("{}{}", history, plan_ctx);

    let sp_tail: String = system_prompt.chars().rev().take(500).collect::<Vec<_>>().into_iter().rev().collect();
    println!("系统提示词 (最后500字):\n{}", sp_tail);

    let raw_reply = caller.generate(system_prompt, &user_content).await
        .expect("LLM call failed");

    println!("\n🤖 LLM 完整回复 ({} chars):\n{}", raw_reply.len(), raw_reply);
    println!("\n--- 检测 plan_update ---");

    // ── Step 4: 检查是否用了 reset_current_task ──
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &raw_reply, TEST_CONV_ID, TEST_USER_ID,
    );

    if result.plan_updated {
        println!("plan_updated: true");
        if let Some(ref pj) = result.plan_json {
            let stages = pj["stages"].as_array().unwrap();
            for stage in stages {
                let sname = stage["name"].as_str().unwrap_or("");
                let sstatus = stage["status"].as_str().unwrap_or("");
                println!("  Stage [{}]: {}", sname, sstatus);
                if let Some(tasks) = stage["tasks"].as_array() {
                    for task in tasks {
                        println!("    Task [{}]: {}", task["name"].as_str().unwrap_or(""), task["status"].as_str().unwrap_or(""));
                    }
                }
            }
        }

        // 验证回退是否生效
        if let Some(ref pj) = result.plan_json {
            let tasks = pj["stages"][0]["tasks"].as_array().unwrap();
            let t1 = tasks[0]["status"].as_str().unwrap();
            let t2 = tasks[1]["status"].as_str().unwrap();
            println!("\n回退后状态: Task1={}, Task2={}", t1, t2);

            if t1 == "in_progress" && t2 == "pending" {
                println!("✅ 回退生效！LLM 正确使用了 reset_current_task");
            } else if t1 == "done" && t2 == "in_progress" {
                println!("❌ 回退未生效！状态未改变。LLM 回复中可能未包含 reset_current_task");
                // 检查 LLM 回复中是否有 reset_current_task
                if raw_reply.contains("reset_current_task") {
                    println!("   但 LLM 回复中包含了 reset_current_task 关键字");
                } else {
                    println!("   LLM 回复中未包含 reset_current_task 关键字");
                }
            } else {
                println!("⚠️  意外状态: Task1={}, Task2={}", t1, t2);
            }
        }
    } else {
        println!("plan_updated: false");
        println!("❌ LLM 回复中未包含 <plan_update> 标签");
        println!("检查 LLM 回复是否包含 reset_current_task: {}", raw_reply.contains("reset_current_task"));
    }
}

#[tokio::test]
#[ignore]
async fn e2e_live_revert_explicit() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E LIVE: 显式回退测试 (直接要求 LLM 回退)");
    println!("{}", "=".repeat(70));

    setup();

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("DEEPSEEK_API_KEY not set in .env");

    use chat_engine::llm_caller::{LlmCaller, LlmConfig};
    let config = LlmConfig::deepseek_v4_flash(&api_key);
    let mut caller = LlmCaller::new(config);

    // ── 创建计划 ──
    let plan = serde_json::json!({
        "stages": [{
            "name": "入门",
            "status": "in_progress",
            "tasks": [
                {"name": "安装环境", "status": "done"},
                {"name": "Hello World", "status": "in_progress"}
            ]
        }],
        "completed_concepts": []
    });
    let conn = api_server::db_pool::get_conn();
    conn.execute(
        "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_json, created_at, updated_at)
         VALUES ('p2', ?1, ?2, '编程入门', '', 'structured', ?3, '2024-01-01', '2024-01-01')",
        rusqlite::params![TEST_USER_ID, TEST_CONV_ID, plan.to_string()],
    ).unwrap();

    insert_turn("user", "开始学习编程");
    insert_turn("assistant", "好的！我们从安装环境开始...");

    // ── 直接要求 LLM 使用 reset_current_task ──
    // 用户消息明确要求回退
    let user_msg = "注意：我刚才被错误地标记为完成了「Hello World」任务，但我实际上还没开始学这个。\
        请你在回复中使用 <plan_update> 标签，并在 JSON 中设置 \"reset_current_task\": true 来回退这个错误。";

    let prompts = chat_engine::prompt_loader::get();
    let history = format!("user: 开始学习编程\nassistant: 好的！我们从安装环境开始...\nuser: {}", user_msg);
    let user_content = history;

    println!("用户消息: {}", user_msg);

    let raw_reply = caller.generate(&prompts.chat_system_structured, &user_content).await
        .expect("LLM call failed");

    println!("\n🤖 LLM 回复:\n{}", raw_reply);

    let result = api_server::plan_handler::handle_plan_update(
        &conn, &raw_reply, TEST_CONV_ID, TEST_USER_ID,
    );

    if result.plan_updated {
        println!("\nplan_updated: true");
        if let Some(ref pj) = result.plan_json {
            let tasks = pj["stages"][0]["tasks"].as_array().unwrap();
            for task in tasks {
                println!("  {}: {}", task["name"].as_str().unwrap_or(""), task["status"].as_str().unwrap_or(""));
            }

            let t2 = tasks[1]["status"].as_str().unwrap();
            if t2 == "pending" || t2 == "in_progress" {
                println!("✅ 回退处理成功");
            } else {
                println!("⚠️ 回退后状态: {} (期望 pending 或 in_progress)", t2);
            }
        }
    } else {
        println!("\n❌ plan_updated: false");
        if raw_reply.contains("reset_current_task") {
            println!("   LLM 提到了 reset_current_task 但未正确使用 <plan_update> 格式");
        } else {
            println!("   LLM 未使用 reset_current_task");
        }
        println!("   原始回复:\n{}", raw_reply);
    }
}

// ════════════════════════════════════════════
// 双智能体自主对话 — 全程学生 LLM + 导师 LLM
// ════════════════════════════════════════════

/// 学生智能体的系统提示词
const STUDENT_SYSTEM_PROMPT: &str = "\
你是一个正在使用 AI 学习助手的中学生。你正在学习 K-12 课程体系中的某个知识点。\n\
\n\
**话题范围（K-12）**：你只能从以下话题中选择一个来学习：
- 小学数学：分数运算、小数乘除、简易方程
- 初中数学：一次函数、勾股定理、三角形全等、一元二次方程
- 初中物理：欧姆定律、压强与浮力、光的反射
- 高中数学：三角函数、数列、概率

话题必须具体，不能笼统（如不能说「数学」或「编程」）。\n\
\n\
行为指南：\n\
1. **首次对话**：从上述列表选一个话题，告诉导师你想学什么，请他制定学习计划。\n\
2. **教学过程**：认真听导师讲解，有疑问就提出，理解后要求进入下一个任务。\n\
3. **考核环节**：导师出题时，认真回答每一题。用自己的话解释概念，展示计算步骤。\n\
   - 不要只说「我懂了」「理解了」这种空话\n\
   - 用具体的知识内容展示你的理解\n\
4. **推进节奏**：完成一个任务后主动说「请继续下一个任务」或「可以出题考核我了」。\n\
5. **最终目标**：完成学习计划中的所有阶段和任务。\n\
\n\
回复格式：直接输出你要对导师说的话，不要加「学生：」「用户：」等前缀。\n\
不要模拟导师的回复，不要输出 <plan_update> 标签。";

/// 学生智能体：根据对话历史生成下一句回复
async fn student_speak(
    student_caller: &mut chat_engine::llm_caller::LlmCaller,
    history: &str,
    plan_summary: &str,
) -> String {
    let context = if plan_summary.is_empty() {
        history.to_string()
    } else {
        format!("{}{}", history, plan_summary)
    };

    match student_caller.generate(STUDENT_SYSTEM_PROMPT, &context).await {
        Ok(reply) => {
            let cleaned = reply.trim().to_string();
            let preview: String = cleaned.chars().take(200).collect();
            println!("  🧑 学生: {}", preview);
            cleaned
        }
        Err(e) => {
            println!("  ⚠️ 学生 LLM 调用失败: {:?}, 使用回退", e);
            "请继续下一个任务，如果我已经掌握了请出题考核我。".to_string()
        }
    }
}

/// 简单的计划摘要（供学生智能体了解进度）
fn plan_summary() -> String {
    if let Some((_, goal, pjson)) = get_plan_from_db() {
        if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
            let stages = plan["stages"].as_array().unwrap();
            let mut s = format!("\n\n[当前计划进度: 目标={}]", goal);
            let mut all_done = true;
            for stage in stages {
                let sn = stage["name"].as_str().unwrap_or("?");
                let ss = stage["status"].as_str().unwrap_or("?");
                s.push_str(&format!("\n  阶段[{}]: {}", sn, ss));
                if ss != "done" { all_done = false; }
                if let Some(tasks) = stage["tasks"].as_array() {
                    for task in tasks {
                        let tn = task["name"].as_str().unwrap_or("?");
                        let ts = task["status"].as_str().unwrap_or("?");
                        s.push_str(&format!("\n    任务[{}]: {}", tn, ts));
                        if ts != "done" { all_done = false; }
                    }
                }
            }
            if all_done { s.push_str("\n  全部完成！"); }
            return s;
        }
    }
    String::new()
}

#[tokio::test]
#[ignore]
async fn e2e_dual_agent_autonomous() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E: 双智能体自主对话 (学生 LLM ↔ 导师 LLM)");
    println!("{}", "=".repeat(70));

    setup();

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("请在 backend/.env 中设置 DEEPSEEK_API_KEY");

    let tutor_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let mut tutor_caller = chat_engine::llm_caller::LlmCaller::new(tutor_config);

    // 学生用稍低的 temperature 保证行为可控
    let mut student_config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    student_config.temperature = 0.5;
    let mut student_caller = chat_engine::llm_caller::LlmCaller::new(student_config);

    // ── Phase 0: 学生发起学习请求 ──
    println!("\n─── 阶段 0: 学生发起学习请求 ───");
    let initial_msg = student_speak(
        &mut student_caller,
        "（这是对话的开始，请向导师打招呼并说出你想学习的 K-12 知识点）",
        "",
    ).await;
    // 兜底：如果 LLM 返回空消息
    let initial_msg = if initial_msg.trim().is_empty() {
        "导师好！我想学习勾股定理，这是我的数学课内容，请帮我制定一个学习计划。".to_string()
    } else {
        initial_msg
    };
    let t0 = chat_turn(&mut tutor_caller, &initial_msg, "学生首次发言").await;

    // 容忍：LLM 可能不立即创建计划
    if t0.plan_updated && t0.is_new_plan {
        println!("✅ 学习计划已在首轮创建");
    } else {
        // 追问创建计划
        println!("  ⚠️ 首轮未创建计划，追问...");
        let follow = "请你帮我创建一个学习计划，我需要有条理地学习。在回复中用 <plan_update> 标签输出计划。";
        let tf = chat_turn(&mut tutor_caller, follow, "追问创建计划").await;
        if !tf.is_new_plan {
            // 再追问一次
            let follow2 = "我需要一个学习计划。请用 <plan_update> 标签创建一个包含 \"is_new_plan\": true 的计划。";
            let _tf2 = chat_turn(&mut tutor_caller, follow2, "再次追问").await;
        }
    }

    let plan = get_plan_from_db();
    assert!(plan.is_some(), "应该已创建学习计划");
    println!("✅ 学习计划已创建");

    // ── 主循环：学生 ↔ 导师自主对话 ──
    println!("\n─── 主循环: 自主对话推进 ───");
    let max_rounds = 80;
    let mut round = 0;
    let mut total_tasks = 0;

    // 记录初始状态
    if let Some((_, _, pjson)) = get_plan_from_db() {
        if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
            let stages = plan["stages"].as_array().unwrap();
            total_tasks = stages.iter()
                .filter_map(|s| s["tasks"].as_array())
                .map(|t| t.len()).sum();
            println!("  初始: {} 阶段, {} 任务", stages.len(), total_tasks);
        }
    }

    for round in 1..=max_rounds {
        // 检查是否全部完成
        let (done_stages, done_tasks, all_done, stage_count) = {
            let plan = get_plan_from_db();
            if plan.is_none() { break; }
            let (_, _, pjson) = plan.unwrap();
            let plan_val: serde_json::Value = serde_json::from_str(&pjson).unwrap();
            let stages = plan_val["stages"].as_array().unwrap();
            let sc = stages.len();
            let ds = stages.iter().filter(|s| s["status"] == "done").count();
            let dt: usize = stages.iter()
                .filter_map(|s| s["tasks"].as_array())
                .map(|t| t.iter().filter(|x| x["status"] == "done").count())
                .sum();
            let ad = ds == sc && stages.iter().all(|s|
                s["tasks"].as_array().map_or(false, |t|
                    t.iter().all(|x| x["status"] == "done")
                )
            );
            (ds, dt, ad, sc)
        };

        if total_tasks == 0 {
            if let Some((_, _, pjson)) = get_plan_from_db() {
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
                    total_tasks = plan["stages"].as_array().unwrap().iter()
                        .filter_map(|s| s["tasks"].as_array())
                        .map(|t| t.len()).sum();
                }
            }
        }

        println!("\n  🔄 轮次 {round}: {}/{} 阶段完成, {}/{} 任务完成",
            done_stages, stage_count, done_tasks, total_tasks);

        if all_done {
            println!("  🎉 全部任务完成!");
            break;
        }

        // 学生发言
        let summary = plan_summary();
        let history = get_conversation_history();
        let student_msg = student_speak(&mut student_caller, &history, &summary).await;
        let _result = chat_turn(&mut tutor_caller, &student_msg, &format!("轮次{}", round)).await;

        // 每 5 轮显示详细状态
        if round % 5 == 0 {
            if let Some((_, _, pjson)) = get_plan_from_db() {
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
                    for stage in plan["stages"].as_array().unwrap() {
                        let sn = stage["name"].as_str().unwrap_or("?");
                        let ss = stage["status"].as_str().unwrap_or("?");
                        print!("    {} [{}]", sn, ss);
                        if let Some(tasks) = stage["tasks"].as_array() {
                            for task in tasks {
                                print!(" | {}:{}", task["name"].as_str().unwrap_or("?"), task["status"].as_str().unwrap_or("?"));
                            }
                        }
                        println!();
                    }
                }
            }
        }
    }

    if round >= max_rounds {
        println!("  ⚠️ 达到最大轮次限制 {}", max_rounds);
    }

    // ── 最终验证 ──
    println!("\n{}", "=".repeat(70));
    println!(" 最终验证");
    println!("{}", "=".repeat(70));

    let plan = get_plan_from_db();
    assert!(plan.is_some(), "学习计划应存在");
    let (_pid, goal, pjson) = plan.unwrap();
    println!("目标: {}", goal);

    let plan_val: serde_json::Value = serde_json::from_str(&pjson).unwrap();
    let stages = plan_val["stages"].as_array().unwrap();
    let done_stages_final = stages.iter().filter(|s| s["status"] == "done").count();
    let done_tasks_final: usize = stages.iter()
        .filter_map(|s| s["tasks"].as_array())
        .map(|t| t.iter().filter(|x| x["status"] == "done").count())
        .sum();

    println!("阶段完成: {}/{}", done_stages_final, stages.len());
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

    assert!(done_tasks_final >= 1, "至少完成 1 个任务");
    assert!(done_stages_final >= 1, "至少完成 1 个阶段");

    let achievements = get_achievements();
    println!("\n成就: {} 个", achievements.len());
    for (key, name, tier) in &achievements {
        println!("  🏆 {} | {} | {}", key, name, tier);
    }
    assert!(!achievements.is_empty(), "应该解锁至少 1 个成就");

    println!("\n{}", "=".repeat(70));
    println!(" ✅ 双智能体自主对话测试完成! ({} 轮)", round);
    println!("    阶段 {}/{} | 任务 {}/{} | 成就 {} 个",
        done_stages_final, stages.len(), done_tasks_final, total_tasks, achievements.len());
    println!("{}", "=".repeat(70));
}

// ════════════════════════════════════════════
// 语文课文阅读模式 E2E 评估
// ════════════════════════════════════════════

/// 阅读模式专用的 plan_context builder
fn build_reading_context() -> (String, String, String) {
    let conn = api_server::db_pool::get_conn();
    api_server::plan_handler::build_plan_context(&conn, TEST_CONV_ID)
}

/// 获取阅读模式 plan（不限制 mode='structured'）
fn get_reading_plan_from_db() -> Option<(String, String, String)> {
    let conn = api_server::db_pool::get_conn();
    conn.query_row(
        "SELECT id, goal, plan_json FROM learning_plans WHERE conversation_id = ?1 ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![TEST_CONV_ID],
        |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,String>(2)?)),
    ).ok()
}

#[tokio::test]
#[ignore]
async fn e2e_live_chinese_reading() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E LIVE: 语文课文阅读模式 (DeepSeek V4 Flash)");
    println!("{}", "=".repeat(70));

    // ── Setup ──
    let _ = fs::remove_file(TEST_DB_PATH);
    if PathBuf::from(TEST_DB_PATH).exists() {
        // DB 文件未被删除，用绝对路径重试
        let abs_path = std::env::current_dir().unwrap_or_default().join(TEST_DB_PATH);
        let _ = fs::remove_file(&abs_path);
        eprintln!("[SETUP] retry remove: {:?}", abs_path);
    }
    let _ = fs::create_dir_all("data");
    let env_paths = ["../../.env", ".env", "../.env"];
    for p in &env_paths {
        if dotenvy::from_filename(p).is_ok() { break; }
    }
    api_server::db_pool::init(TEST_DB_PATH).expect("init DB pool");
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute_batch(SCHEMA_SQL).expect("create schema");
    }
    // 添加 subject/grade_band 列
    {
        let conn = api_server::db_pool::get_conn();
        let _ = conn.execute_batch(
            "ALTER TABLE conversations ADD COLUMN subject TEXT DEFAULT NULL;
             ALTER TABLE conversations ADD COLUMN grade_band TEXT DEFAULT NULL;"
        );
    }
    let now = chrono::Utc::now().to_rfc3339();
    let pw_hash = api_server::auth::hash_password(TEST_PASSWORD);
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?1,?2,?3,?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME, pw_hash, now],
        ).unwrap();
    }
    let prompts_dir = "../../prompts";
    let pipelines_dir = "../../pipelines";
    chat_engine::prompt_loader::init(prompts_dir, pipelines_dir);

    // 初始化 reading_loader（加载 prebuilt data）
    api_server::reading_loader::init().unwrap_or_else(|e| {
        eprintln!("[TEST] reading_loader::init warned: {}", e);
    });

    let api_key = std::env::var("DEEPSEEK_API_KEY")
        .expect("请在 backend/.env 中设置 DEEPSEEK_API_KEY");
    let config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
    let mut caller = chat_engine::llm_caller::LlmCaller::new(config);

    // ── Phase 1: 初始化阅读会话 ──
    println!("\n─── Phase 1: 初始化阅读会话 (语文·g7-9) ───");
    let subject_key = "chinese".to_string();
    let grade_band = "g7-9".to_string();

    // 模拟 /api/k12/reading/init 的行为
    // 使用 TEST_CONV_ID 以便 insert_turn() 正常工作
    let plan = api_server::reading_loader::get_plan(&subject_key)
        .expect("reading plan 应存在");

    // 按学段过滤 stages
    let filtered_stages: Vec<_> = plan.stages.iter()
        .filter(|s| s.grade_band == grade_band || grade_band.starts_with(&s.grade_band[..2]))
        .cloned()
        .collect();
    println!("  计划段: {} 阶段 (原始 {} 段)", filtered_stages.len(), plan.stages.len());

    // plan_content: 完整计划结构
    let plan_content = serde_json::json!({
        "id": format!("{}_reading_plan", subject_key),
        "subject": subject_key,
        "grade_band": &grade_band,
        "goal": plan.goal,
        "stages": filtered_stages.clone(),
    });
    let plan_content_str = serde_json::to_string(&plan_content).unwrap();
    // plan_json: 仅状态
    let mut status_map = serde_json::Map::new();
    if let Some(stages) = plan_content.get("stages").and_then(|s| s.as_array()) {
        for stage in stages {
            if let Some(tasks) = stage.get("tasks").and_then(|t| t.as_array()) {
                for task in tasks {
                    if let Some(name) = task.get("name").and_then(|n| n.as_str()) {
                        status_map.insert(name.to_string(), serde_json::json!("pending"));
                    }
                }
            }
        }
    }
    let plan_json_str = serde_json::to_string(&serde_json::Value::Object(status_map)).unwrap();

    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1,?2,0,?3,?4,?5)",
            rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now, "语文", &grade_band],
        ).unwrap();
        conn.execute(
            "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, plan_json, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,'reading',?6,?7,?8,?8)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), TEST_USER_ID, TEST_CONV_ID,
                format!("Reading: 语文 {}", &grade_band), "语文", plan_content_str, plan_json_str, now],
        ).unwrap();
    }
    insert_turn("assistant", &format!(
        "欢迎进入课文阅读学习！当前计划：语文 ({} 阶段, {} 学段)。第一课即将开始。",
        filtered_stages.len(), grade_band
    ));

    // ── Phase 2: 验证 reading context 组装 ──
    println!("\n─── Phase 2: 验证 reading context ───");
    let (domain, mode, ctx) = build_reading_context();
    assert_eq!(mode, "reading", "应为 reading 模式");
    assert!(!ctx.is_empty(), "context 不应为空");
    // 验证 context 中包含 reading_loader 卡片内容
    println!("  mode={}, ctx_len={}, domain={}", mode, ctx.len(), domain);
    let first_stage = &filtered_stages[0];
    let first_task = &first_stage.tasks[0];
    println!("  首任务: {} | focus: {}", first_task.name, first_task.focus);
    // 验证 context 包含核心教学点
    assert!(ctx.contains("核心教学点"), "context 应包含核心教学点");
    assert!(ctx.contains(&first_task.name), "context 应包含课文名");
    assert!(ctx.contains(&first_task.focus), "context 应包含 focus");

    // 如果有 reading_card_id，验证卡片内容已注入
    if let Some(ref card_id) = first_task.reading_card_id {
        if !card_id.is_empty() {
            let card = api_server::reading_loader::get_card(card_id);
            assert!(card.is_some(), "reading card {} 应在 index 中", card_id);
            println!("  reading card: {} by {}", card.unwrap().front, card.unwrap().author);
            assert!(ctx.contains(&card.unwrap().theme), "context 应包含主旨");
        }
    }
    println!("✅ Phase2: reading context 组装验证通过");

    // ── 双智能体对话：学生 ↔ 教师 ──
    println!("\n{}", "=".repeat(70));
    println!("  双智能体对话：学生 ↔ 教师 (语文课文阅读模式)");
    println!("{}", "=".repeat(70));

    // 学生智能体 prompt — 扮演初中生学习语文课文
    let student_system = "\
你是一个正在学习语文课的初中生。你的语文老师正在按照课文阅读计划教你课文。\
你认真听讲，积极回答老师的提问。\n\
行为规则：\
\n- **首次发言**：告诉老师你想学语文课文《春》\
\n- **教学过程中**：老师讲解后，你要针对教学点（比喻、拟人、多感官描写等）提出自己的理解和问题\
\n- **回答提问**：用具体内容回答，不要只说空话\
\n- **表示掌握**：当你觉得已经理解了一篇课文，礼貌地说学会了，请老师推进到下一篇\
\n- **最终目标**：至少完成2篇课文的学习（《春》和《济南的冬天》或下一课）\
\n- 不要说「我理解了」「我掌握了」等空话，要用具体的赏析语句展示你的理解\
\n- 不要输出<reading_update>标签，那是老师用的\
\n- 直接输出你要说的话，不要加「学生：」前缀";

    let student_config = chat_engine::llm_caller::LlmConfig {
        temperature: 0.6,
        ..chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key)
    };
    let mut student_caller = chat_engine::llm_caller::LlmCaller::new(student_config);

    let prompts = chat_engine::prompt_loader::get_for_domain("");

    // 学生首次发言
    println!("\n─── 学生首次发言 ───");
    let initial_msg = {
        let history = get_conversation_history();
        // 给学生提供上下文
        let ctx_summary = format!("\n[课文阅读已准备就绪，当前计划包含36个阶段，145篇课文。你的第一课是《春》，教学重点是「语言特色·比喻排比与多感官描写」]");
        let student_input = format!("{}{}", history, ctx_summary);
        let reply = student_caller.generate(student_system, &student_input).await
            .unwrap_or_else(|_| "老师好！我想学习语文课文《春》，听说这篇课文用了很多比喻和拟人，请给我讲解一下。".to_string());
        if reply.trim().is_empty() {
            "老师好！我想学习《春》这篇课文，特别是里面的比喻和拟人手法。".to_string()
        } else {
            reply
        }
    };
    println!("  🧑 学生: {}", truncate_utf8(&initial_msg, 200));

    // ── 主对话循环 ──
    let system_prompt = prompts.chat_system_reading.clone();
    let max_rounds = 10;
    let start_time = std::time::Instant::now();
    let max_duration = std::time::Duration::from_secs(90);
    let mut rounds_completed = 0u32;
    let mut plan_updated_count = 0;
    let mut llm_reply_total_chars = 0usize;
    let mut last_context = String::new();

    for round in 1..=max_rounds {
        // 超时保护
        if start_time.elapsed() > max_duration {
            println!("  ⏰ 达到最大持续时间 ({:?}), 停止", max_duration);
            rounds_completed = round - 1;
            break;
        }
        rounds_completed = round;

        // 获取当前 reading context
        let (domain, mode, ctx) = build_reading_context();

        // 构建 teacher prompt (history + reading context)
        let history = get_conversation_history();
        let user_content = format!("{}{}", history, ctx);
        last_context = ctx.clone();

        // 调用教师 LLM
        let raw_reply = match caller.generate(&system_prompt, &user_content).await {
            Ok(r) => r,
            Err(e) => {
                println!("  ⚠️ 教师 LLM 调用失败: {:?}", e);
                break;
            }
        };
        llm_reply_total_chars += raw_reply.len();

        // 处理 plan_update / reading_update
        let conn = api_server::db_pool::get_conn();
        let result = api_server::plan_handler::handle_plan_update(
            &conn, &raw_reply, TEST_CONV_ID, TEST_USER_ID,
        );

        let cleaned_reply = if result.plan_updated {
            plan_updated_count += 1;
            if result.is_new_plan {
                // reading mode 不应该创建新 plan
                println!("  ⚠️ 教师创建了新计划 (reading mode 不应有此行为)");
            } else {
                // 更新了进度
                let done: usize = if let Some(ref pj) = result.plan_json {
                    pj["stages"].as_array().unwrap().iter()
                        .filter_map(|s| s["tasks"].as_array())
                        .map(|t| t.iter().filter(|x| x["status"] == "done").count())
                        .sum()
                } else { 0 };
                println!("  📝 plan 更新: done_tasks={}", done);
            }
            result.cleaned_reply
        } else {
            raw_reply
        };

        insert_turn("assistant", &cleaned_reply);

        // 检查是否所有任务已完成
        let (done_tasks, total_tasks, all_done) = {
            if let Some((_, _, pjson)) = get_reading_plan_from_db() {
                if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
                    let stages = plan["stages"].as_array().unwrap();
                    let dt: usize = stages.iter()
                        .filter_map(|s| s["tasks"].as_array())
                        .map(|t| t.iter().filter(|x| x["status"] == "done").count())
                        .sum();
                    let tt: usize = stages.iter()
                        .filter_map(|s| s["tasks"].as_array())
                        .map(|t| t.len()).sum();
                    let ad = stages.iter().all(|s| s["status"] == "done")
                        || stages.iter().all(|s|
                            s["tasks"].as_array().map_or(true, |t|
                                t.iter().all(|x| x["status"] == "done")
                            )
                        );
                    (dt, tt, ad)
                } else { (0, 1, false) }
            } else { (0, 1, false) }
        };

        println!("  🔄 轮次{round}: done_tasks={done_tasks}/{total_tasks}  plan_updates={plan_updated_count}");
        if done_tasks >= 2 || all_done {
            println!("  🎉 完成至少2篇课文!");
            break;
        }

        // 学生智能体发言
        let student_history = format!("{}{}", get_conversation_history(), &last_context);
        let student_msg = student_caller.generate(student_system, &student_history).await
            .unwrap_or_else(|_| "老师，我理解了。请继续下一课的教学吧。".to_string());
        let student_clean = student_msg.trim().to_string();
        let preview: String = student_clean.chars().take(200).collect();
        println!("  🧑 学生: {}", preview);

        if student_clean.is_empty() {
            // 兜底
            insert_turn("user", "请继续教学或出题考核我。");
        } else {
            insert_turn("user", &student_clean);
        }
    }

    // ── 最终评估 ──
    println!("\n{}", "=".repeat(70));
    println!("  教学评估报告");
    println!("{}", "=".repeat(70));

    // 1. 任务推进评估
    let (done_tasks_final, total_tasks_final) = {
        if let Some((_, _, pjson)) = get_reading_plan_from_db() {
            if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
                let stages = plan["stages"].as_array().unwrap();
                let dt: usize = stages.iter()
                    .filter_map(|s| s["tasks"].as_array())
                    .map(|t| t.iter().filter(|x| x["status"] == "done").count())
                    .sum();
                let tt: usize = stages.iter()
                    .filter_map(|s| s["tasks"].as_array())
                    .map(|t| t.len()).sum();
                (dt, tt)
            } else { (0, 1) }
        } else { (0, 1) }
    };

    println!("  任务推进: {}/{} done", done_tasks_final, total_tasks_final);
    println!("  plan_update 总次数: {}", plan_updated_count);
    println!("  对话轮次: {}", rounds_completed);
    println!("  教师回复总字符: {}", llm_reply_total_chars);

    // 2. Context 质量评估
    println!("\n── Context 质量评估 ──");
    let (_, mode_final, ctx_final) = build_reading_context();
    println!("  最终 mode: {}", mode_final);
    if !ctx_final.is_empty() {
        let has_focus = ctx_final.contains("核心教学点");
        let has_reading_card = ctx_final.contains("语句赏析") || ctx_final.contains("手法");
        let has_theme = ctx_final.contains("主旨");
        let has_full_text = ctx_final.contains("全文");
        println!("  ✅ 含核心教学点: {}", has_focus);
        println!("  ✅ 含 reading 卡: {}", has_reading_card);
        println!("  ✅ 含主旨: {}", has_theme);
        println!("  ✅ 含全文: {}", has_full_text);
    }

    // 3. reading_update 标签清理验证
    println!("\n── reading_update 标签清理 ──");
    if let Some((_, _, pjson)) = get_reading_plan_from_db() {
        if !pjson.contains("<reading_update") {
            println!("  ✅ plan_json 中无残留 reading_update 标签");
        } else {
            println!("  ⚠️ plan_json 中有残留 reading_update 标签");
        }
    }

    // 4. 断言
    assert_eq!(mode_final, "reading", "全程应为 reading 模式");
    assert!(rounds_completed >= 3, "至少 3 轮对话 (应有实质性教学互动)");

    // 如果至少完成了一个任务，打印进度详情
    if done_tasks_final > 0 {
        println!("\n── 已完成任务详情 ──");
        if let Some((_, _, pjson)) = get_reading_plan_from_db() {
            if let Ok(plan) = serde_json::from_str::<serde_json::Value>(&pjson) {
                for stage in plan["stages"].as_array().unwrap() {
                    let sname = stage["name"].as_str().unwrap_or("?");
                    if let Some(tasks) = stage["tasks"].as_array() {
                        let remaining: Vec<_> = tasks.iter().filter(|t| t["status"] == "pending").collect();
                        let done: Vec<_> = tasks.iter().filter(|t| t["status"] == "done").collect();
                        if !done.is_empty() {
                            for t in &done {
                                println!("  ✅ {} → {}", sname, t["name"].as_str().unwrap_or("?"));
                            }
                        }
                        if !remaining.is_empty() && done.is_empty() {
                            break; // 只显示当前活跃 stage
                        }
                    }
                }
            }
        }
    }

    println!("\n{}", "=".repeat(70));
    println!(" ✅ 语文课文阅读模式 E2E 双智能体评估完成!");
    println!("    任务 {}/{} 完成 | plan_update {} 次 | 对话 {} 轮",
        done_tasks_final, total_tasks_final, plan_updated_count, rounds_completed);
    println!("{}", "=".repeat(70));
}

// ════════════════════════════════════════════
// 教学质量评估 E2E — 带全面日志输出
// ════════════════════════════════════════════

use std::path::PathBuf;
use std::time::Instant;

/// 运行一次教学质量评估测试并保存完整日志
async fn run_eval_session(
    run_id: &str,
    subject_cn: &str,
    subject_key: &str,
    grade_band: &str,
    tasks_limit: usize,  // 只测试前 N 个 task，0=全量
) -> PathBuf {
    let run_dir = format!("data/eval_runs/{}", run_id);
    let _ = fs::create_dir_all(&run_dir);

    // 初始化 data + session
    let now = chrono::Utc::now().to_rfc3339();
    let plan = api_server::reading_loader::get_plan(subject_key)
        .expect("reading plan should exist");
    let filtered_stages: Vec<_> = plan.stages.iter()
        .filter(|s| s.grade_band == grade_band || grade_band.starts_with(&s.grade_band[..2]))
        .cloned()
        .collect();

    // 只保留 first_stage + tasks_limit 个 task（评估用，不跑全学段）
    let mut trimmed_stages: Vec<serde_json::Value> = vec![];
    if let Some(first) = filtered_stages.first() {
        let mut stage_json = serde_json::to_value(first).unwrap_or_default();
        if tasks_limit > 0 {
            if let Some(tasks) = stage_json.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                tasks.truncate(tasks_limit);
            }
        }
        trimmed_stages.push(stage_json);
    }

    let plan_content = serde_json::json!({
        "subject": subject_key, "grade_band": grade_band,
        "goal": plan.goal, "stages": trimmed_stages,
    });
    let plan_content_str = serde_json::to_string(&plan_content).unwrap();
    let mut status_map = serde_json::Map::new();
    for stage in plan_content["stages"].as_array().unwrap() {
        for task in stage["tasks"].as_array().unwrap() {
            if let Some(name) = task["name"].as_str() {
                status_map.insert(name.to_string(), serde_json::json!("pending"));
            }
        }
    }
    let plan_json_str = serde_json::to_string(&serde_json::Value::Object(status_map)).unwrap();

    // 写 meta.json
    let expected_tasks = {
        let mut et = serde_json::json!({"stages": []});
        if let Some(stages) = et.get_mut("stages").and_then(|s| s.as_array_mut()) {
            for s in plan_content["stages"].as_array().unwrap().iter().take(2) {
                let mut ss = serde_json::json!({"name": s["name"], "tasks": []});
                for t in s["tasks"].as_array().unwrap() {
                    ss["tasks"].as_array_mut().unwrap().push(serde_json::json!({
                        "name": t["name"], "focus": t["focus"], "mode": t["mode"]
                    }));
                }
                stages.push(ss);
            }
        }
        et
    };
    let meta = serde_json::json!({
        "run_id": run_id, "subject": subject_cn, "subject_key": subject_key,
        "grade_band": grade_band, "total_stages": filtered_stages.len(),
        "total_tasks": plan_content["stages"].as_array().unwrap().iter()
            .map(|s| s["tasks"].as_array().map(|t| t.len()).unwrap_or(0)).sum::<usize>(),
        "started_at": now,
        "expected_tasks": expected_tasks,
    });
    fs::write(format!("{}/meta.json", run_dir), serde_json::to_string_pretty(&meta).unwrap()).ok();

    // 初始化 DB 插入
    let conn = api_server::db_pool::get_conn();
    conn.execute(
        "INSERT OR REPLACE INTO conversations (id, user_id, turn_count, started_at, subject, grade_band)
         VALUES (?1, ?2, 0, ?3, ?4, ?5)",
        rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now, subject_cn, grade_band],
    ).ok();
    conn.execute(
        "DELETE FROM learning_plans WHERE user_id = ?1 AND domain = ?2",
        rusqlite::params![TEST_USER_ID, subject_cn],
    ).ok();
    conn.execute(
        "INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, plan_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'reading', ?6, ?7, ?8, ?8)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), TEST_USER_ID, TEST_CONV_ID,
            format!("Reading: {} {}", subject_cn, grade_band), subject_cn,
            plan_content_str, plan_json_str, now],
    ).ok();

    let prompts = chat_engine::prompt_loader::get_for_domain("");
    // 按学段 + task mode 选择对应的物理隔离 prompt
    let is_nursery = plan_content.get("stages")
        .and_then(|s| s.as_array())
        .and_then(|a| a.first())
        .and_then(|s| s.get("tasks"))
        .and_then(|t| t.as_array())
        .and_then(|a| a.first())
        .and_then(|t| t.get("mode"))
        .and_then(|m| m.as_str())
        == Some("nursery_rhyme");
    let is_primary = grade_band == "g1-2" || grade_band == "g3-4";
    let system_prompt = if is_nursery {
        let p = prompts.chat_system_reading_nursery.clone();
        if !p.is_empty() { p } else { prompts.chat_system_reading.clone() }
    } else if is_primary {
        let p = prompts.chat_system_reading_primary.clone();
        if !p.is_empty() { p } else { prompts.chat_system_reading.clone() }
    } else {
        let p = prompts.chat_system_reading_secondary.clone();
        if !p.is_empty() { p } else { prompts.chat_system_reading.clone() }
    };
    eprintln!("[EVAL] Prompt selected: {} chars (grade={}, nursery={})", system_prompt.len(), grade_band, is_nursery);

    // 学生智能体 prompt（纯被动应答，不接触计划信息）
    let student_system = format!(
"你是一个{}学生。你的语文老师正在教你课文。\
\n\
行为规则：\
\n- 老师提问时，尽可能用具体内容回答\
\n- 对老师讲的内容可以提出自己的理解，但不要主动指挥教学进度\
\n- 如果老师问你是否理解，用你自己的话复述所学内容来展示理解\
\n- 直接输出你要说的话，不要加前缀",
        if grade_band == "g1-2" { "小学低年级" } else { "初中" }
    );
    let mut student_cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
        &std::env::var("DEEPSEEK_API_KEY").expect("DEEPSEEK_API_KEY")
    );
    student_cfg.temperature = 0.6;
    let mut student_caller = chat_engine::llm_caller::LlmCaller::new(student_cfg);

    // 双智能体对话主循环
    let start_time = Instant::now();
    let max_rounds = 20u32;
    let max_duration_secs = 1800u64;
    let mut turn = 0u32;

    for round in 1..=max_rounds {
        if start_time.elapsed().as_secs() > max_duration_secs { break; }

        // 获取 plan_context
        let (_, _, ctx) = {
            let c = api_server::db_pool::get_conn();
            api_server::plan_handler::build_plan_context(&c, TEST_CONV_ID)
        };

        // 读取当前 plan_state
        let plan_state: String = conn.query_row(
            "SELECT plan_json FROM learning_plans WHERE conversation_id = ?1",
            rusqlite::params![TEST_CONV_ID],
            |row| row.get(0),
        ).unwrap_or_default();

        // 学生发言（仅看对话历史，不看计划上下文）
        let student_history = get_conversation_history();
        let student_msg = student_caller.generate(&student_system, &student_history).await
            .unwrap_or_else(|_| "老师，我理解了。".to_string());
        insert_turn("user", &student_msg);

        // 教师回复
        let user_content = format!("{}{}", get_conversation_history(), ctx);
        let teacher_start = Instant::now();
        let raw_reply = match {
            let mut t_cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
                &std::env::var("DEEPSEEK_API_KEY").unwrap()
            );
            let mut t_caller = chat_engine::llm_caller::LlmCaller::new(t_cfg);
            t_caller.generate(&system_prompt, &user_content).await
        } {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[EVAL] Teacher LLM error at round {}: {:?} (retrying)", round, e);
                // 重试一次
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                let mut t_cfg2 = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
                    &std::env::var("DEEPSEEK_API_KEY").unwrap()
                );
                let mut t_caller2 = chat_engine::llm_caller::LlmCaller::new(t_cfg2);
                match t_caller2.generate(&system_prompt, &user_content).await {
                    Ok(r) => r,
                    Err(e2) => {
                        eprintln!("[EVAL] Teacher LLM failed after retry at round {}: {:?}", round, e2);
                        String::new()
                    }
                }
            }
        };
        if raw_reply.is_empty() {
            eprintln!("[EVAL] Empty teacher reply at round {}, skipping log save", round);
            // 跳过本轮日志，但继续循环
            turn += 1;
            continue;
        }
        let latency_ms = teacher_start.elapsed().as_millis() as u64;

        // 处理 plan_update
        let conn_handle = api_server::db_pool::get_conn();
        let result = api_server::plan_handler::handle_plan_update(
            &conn_handle, &raw_reply, TEST_CONV_ID, TEST_USER_ID,
        );
        let cleaned = result.cleaned_reply;
        insert_turn("assistant", &cleaned);

        // 读取更新后的 plan_state
        let new_plan_state: String = conn_handle.query_row(
            "SELECT plan_json FROM learning_plans WHERE conversation_id = ?1",
            rusqlite::params![TEST_CONV_ID],
            |row| row.get(0),
        ).unwrap_or_default();

        turn += 1;
        let turn_dir = format!("{}/turn_{:03}", run_dir, turn);
        let _ = fs::create_dir_all(&turn_dir);

        fs::write(format!("{}/user.txt", turn_dir), &student_msg).ok();
        fs::write(format!("{}/system_prompt.txt", turn_dir), &system_prompt).ok();
        fs::write(format!("{}/plan_context.txt", turn_dir), &ctx).ok();
        fs::write(format!("{}/llm_reply_raw.txt", turn_dir), &raw_reply).ok();
        fs::write(format!("{}/cleaned_reply.txt", turn_dir), &cleaned).ok();
        fs::write(format!("{}/plan_state_before.json", turn_dir), &plan_state).ok();
        fs::write(format!("{}/plan_state_after.json", turn_dir), &new_plan_state).ok();

        let meta_turn = serde_json::json!({
            "turn": turn, "plan_updated": result.plan_updated,
            "latency_ms": latency_ms,
            "reply_chars": raw_reply.len(), "reply_tokens_est": raw_reply.len() / 2,
        });
        fs::write(format!("{}/llm_metadata.json", turn_dir),
            serde_json::to_string_pretty(&meta_turn).unwrap()).ok();

        // Coldpath 2 模拟：每 5 轮调用 analyze_plan_progress
        if turn > 0 && turn % 3 == 0 {
            eprintln!("    [CP2] Running auto-progress analysis at turn {}...", turn);
            let mut cp2_cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
                &std::env::var("DEEPSEEK_API_KEY").unwrap()
            );
            cp2_cfg.temperature = 0.0;
            let mut cp2_caller = chat_engine::llm_caller::LlmCaller::new(cp2_cfg);
            let advanced = api_server::plan_handler::analyze_plan_progress(
                TEST_CONV_ID, TEST_USER_ID, &mut cp2_caller,
            ).await;
            eprintln!("    [CP2] Turn {}: advanced={}", turn, advanced);
            if advanced {
                // 重新读取 context（任务状态已更新）
                let (_, _, new_ctx) = {
                    let c = api_server::db_pool::get_conn();
                    api_server::plan_handler::build_plan_context(&c, TEST_CONV_ID)
                };
                // 更新 ctx 供下轮使用
                // (ctx 会在下轮开始时从 build_plan_context 重新读取)
            }
        }

        println!("  📝 Turn {:03}: plan_updated={}, reply={}chars, {}ms",
            turn, result.plan_updated, raw_reply.len(), latency_ms);
        // Debug: confirm loop is advancing
        eprintln!("[LOOP] end of round {} (turn={})", round, turn);

        // 检查是否所有 task 都已完成（提前结束）
        let all_done = {
            let c = api_server::db_pool::get_conn();
            let pj: String = c.query_row(
                "SELECT plan_json FROM learning_plans WHERE conversation_id = ?1",
                rusqlite::params![TEST_CONV_ID],
                |row| row.get(0),
            ).unwrap_or_default();
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&pj) {
                let status_map = v.get("task_status")
                    .and_then(|s| s.as_object())
                    .or_else(|| v.as_object());
                status_map.map(|m| m.values().all(|s| s.as_str() == Some("done"))).unwrap_or(false)
            } else { false }
        };
        if all_done {
            eprintln!("[EVAL] All tasks completed at turn {}! Breaking early.", turn);
            break;
        }
    }

    // 写入 aggregate.json
    let agg = serde_json::json!({
        "run_id": run_id, "total_turns": turn,
        "duration_secs": start_time.elapsed().as_secs(),
    });
    fs::write(format!("{}/aggregate.json", run_dir),
        serde_json::to_string_pretty(&agg).unwrap()).ok();

    eprintln!("[EVAL] Session {} done: {} turns in {}s, logs at {}",
        run_id, turn, start_time.elapsed().as_secs(), run_dir);

    PathBuf::from(&run_dir)
}

#[tokio::test]
#[ignore]
async fn e2e_live_teaching_quality() {
    println!("\n{}", "=".repeat(70));
    println!(" CoEvo E2E: 教学质量评估 (语文阅读 g1-2 完整学段)");
    println!("{}", "=".repeat(70));

    // ── Setup ──
    let _ = fs::remove_file(TEST_DB_PATH);
    if PathBuf::from(TEST_DB_PATH).exists() {
        // DB 文件未被删除，用绝对路径重试
        let abs_path = std::env::current_dir().unwrap_or_default().join(TEST_DB_PATH);
        let _ = fs::remove_file(&abs_path);
        eprintln!("[SETUP] retry remove: {:?}", abs_path);
    }
    let _ = fs::create_dir_all("data");
    let _ = fs::create_dir_all("data/eval_runs");
    for p in &["../../.env", ".env", "../.env"] {
        if dotenvy::from_filename(p).is_ok() { break; }
    }
    api_server::db_pool::init(TEST_DB_PATH).expect("init DB pool");
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute_batch(SCHEMA_SQL).expect("create schema");
        let _ = conn.execute_batch(
            "ALTER TABLE conversations ADD COLUMN subject TEXT DEFAULT NULL;
             ALTER TABLE conversations ADD COLUMN grade_band TEXT DEFAULT NULL;"
        );
    }
    let now = chrono::Utc::now().to_rfc3339();
    let pw_hash = api_server::auth::hash_password(TEST_PASSWORD);
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute(
            "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?1,?2,?3,?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME, pw_hash, now],
        ).unwrap();
    }
    let prompts_dir = "../../prompts";
    let pipelines_dir = "../../pipelines";
    chat_engine::prompt_loader::init(prompts_dir, pipelines_dir);
    api_server::reading_loader::init().unwrap_or_else(|e| {
        eprintln!("[EVAL] reading_loader init: {}", e);
    });

    let run_id = format!("eval_{}", chrono::Utc::now().format("%Y%m%d_%H%M%S"));

    // ── Session: 语文阅读 g1-2（首 stage 的 3 个 task） ──
    println!("\n─── Session: 语文阅读 g1-2 (3 tasks) ───");
    let dir1 = run_eval_session(&format!("{}_chinese_g12", run_id),
        "语文", "chinese", "g1-2", 3).await;
    println!("  ✅ Logs: {:?}", dir1);

    println!("\n{}", "=".repeat(70));
    println!(" ✅ 教学质量评估 E2E 完成! 日志目录: data/eval_runs/{}", run_id);
    println!("    运行评审: python scripts/eval/quality_review.py --run {}", run_id);
    println!("{}", "=".repeat(70));
}
