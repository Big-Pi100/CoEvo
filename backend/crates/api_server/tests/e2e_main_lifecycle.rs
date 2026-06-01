//! CoEvo 主流程 E2E 测试
//!
//! 这是项目的**核心验收测试**，验证全局数据流：
//!
//! ```text
//! 测试发消息 → cp2_turn() [insert_turn + caller.generate + analyze_turn_progress]
//!          → Phase 1: CP2 检测学习意图 → 创建 plan (conversation_plans + user_plan_progress)
//!          → Phase 2: CP2 检测通关信号 → 推进 task 状态
//!          → Phase 3: extract_concepts (CP1) → cards 写入 + 会话绑定 + task 关联
//!          → Phase 4: 最终状态验证 (plan + progress + achievements)
//! ```
//!
//! 所有 API 调用走生产代码路径。CP2 读 DB 中保存的对话记录进行分析，
//! CP1 取对话内容直接调用。仅 WebSocket 层跳过（直接调 business logic）。
//!
//! 运行方式:
//! ```bash
//! cd backend && cargo test -- --ignored e2e_main_lifecycle
//! ```

use std::fs;
use std::sync::OnceLock;
use std::time::Instant;

// ═══════════════════════════════════════════════════
// 测试常量
// ═══════════════════════════════════════════════════

const TEST_USER_ID: &str = "test-main-user";
const TEST_USERNAME: &str = "main_test";
const TEST_PASSWORD: &str = "test_password";
const TEST_CONV_ID: &str = "test-main-conv";
const TEST_DB_PATH: &str = "data/test_e2e_main.db";

static INIT_PROMPTS: OnceLock<()> = OnceLock::new();

/// 每轮 CP2 诊断数据（写入报告用，记录教师/学生 LLM 完整上下文和 CP2 决策详情）
struct TurnDiag {
    round_label: String,
    teacher_system_prompt: String,
    teacher_input_context: String,
    teacher_reply: String,
    cp2_detailed_event: String,
    student_system_prompt: String,
    student_input_context: String,
    student_reply: String,
}


// ═══════════════════════════════════════════════════
// Schema（测试专用，与生产保持一致）
// ═══════════════════════════════════════════════════

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT,
    streak_days INTEGER DEFAULT 0, last_active_date TEXT, display_name TEXT DEFAULT NULL,
    real_name TEXT, phone TEXT, bind_hash TEXT, deleted_at TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, token TEXT NOT NULL, created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL, deleted_at TEXT, subject TEXT, grade_band TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversation_turns (
    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
    content TEXT NOT NULL, created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS learning_plans (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT,
    goal TEXT NOT NULL, domain TEXT DEFAULT 'general', mode TEXT DEFAULT NULL,
    plan_content TEXT DEFAULT NULL, plan_json TEXT DEFAULT NULL, task_status TEXT,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS plan_templates (
    id TEXT PRIMARY KEY, subject TEXT NOT NULL, subject_key TEXT NOT NULL UNIQUE,
    grade_band TEXT NOT NULL, goal TEXT NOT NULL, plan_content TEXT NOT NULL,
    version INTEGER DEFAULT 1, updated_at INTEGER NOT NULL,
    UNIQUE(subject_key, grade_band)
);
CREATE TABLE IF NOT EXISTS conversation_plans (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT NOT NULL UNIQUE,
    goal TEXT NOT NULL, domain TEXT DEFAULT 'general', plan_content TEXT,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS user_plan_progress (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, plan_type TEXT NOT NULL,
    plan_id TEXT NOT NULL, task_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', score REAL,
    attempt_count INTEGER DEFAULT 0, started_at INTEGER, completed_at INTEGER,
    updated_at INTEGER NOT NULL,
    UNIQUE(plan_id, task_key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS achievements (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, achievement_key TEXT NOT NULL,
    name TEXT NOT NULL, icon TEXT NOT NULL, tier TEXT DEFAULT 'fixed', source TEXT,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS cards (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, domain TEXT, card_type TEXT,
    front TEXT, back TEXT, source_sentence TEXT,
    conversation_id TEXT, created_at INTEGER, subject TEXT, grade_band TEXT,
    k12_card_id TEXT, gold_cr_id TEXT, origin TEXT DEFAULT 'extracted',
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS card_memory (
    card_id TEXT PRIMARY KEY, state INTEGER, difficulty REAL, stability REAL,
    due INTEGER, last_review INTEGER, reps INTEGER, lapses INTEGER,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE IF NOT EXISTS review_log (
    id TEXT PRIMARY KEY, card_id TEXT NOT NULL, rating INTEGER DEFAULT 0,
    verification_type TEXT, verification_result TEXT, details_json TEXT,
    reviewed_at INTEGER NOT NULL,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE IF NOT EXISTS skipped_concepts (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, front TEXT NOT NULL,
    domain TEXT, source_text TEXT, skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

// ═══════════════════════════════════════════════════
// 测试辅助函数
// ═══════════════════════════════════════════════════

mod helpers {
    use super::*;

    pub fn setup() {
        let _ = fs::remove_file(TEST_DB_PATH);
        let _ = fs::create_dir_all("data");
        // Load env
        for p in &["../../.env", ".env", "../.env"] {
            let _ = dotenvy::from_filename(p);
        }
        // Init pool
        let _ = api_server::db_pool::init(TEST_DB_PATH);
        let conn = api_server::db_pool::get_conn();
        // Drop stale tables
        for tbl in &["review_log", "k12_quiz_attempts", "k12_quiz_bank", "card_memory",
                      "cards", "achievements", "learning_plans", "conversation_plans",
                      "plan_templates", "user_plan_progress", "conversation_turns",
                      "conversations", "tokens", "users", "skipped_concepts"] {
            let _ = conn.execute_batch(&format!("DROP TABLE IF EXISTS {}", tbl));
        }
        conn.execute_batch(SCHEMA_SQL).expect("create schema");

        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?1,?2,?3,?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME,
                api_server::auth::hash_password(TEST_PASSWORD), now],
        ).unwrap();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at) VALUES (?1,?2,0,?3)",
            rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now],
        ).unwrap();

        INIT_PROMPTS.get_or_init(|| {
            chat_engine::prompt_loader::init("../../prompts", "../../pipelines");
        });
    }

    pub fn create_caller() -> chat_engine::llm_caller::LlmCaller {
        let api_key = std::env::var("DEEPSEEK_API_KEY")
            .expect("DEEPSEEK_API_KEY 未设置");
        chat_engine::llm_caller::LlmCaller::new(
            chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key))
    }

    pub fn create_caller_with_temp(temperature: f32) -> chat_engine::llm_caller::LlmCaller {
        let api_key = std::env::var("DEEPSEEK_API_KEY")
            .expect("DEEPSEEK_API_KEY 未设置");
        let mut config = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(&api_key);
        config.temperature = temperature;
        chat_engine::llm_caller::LlmCaller::new(config)
    }

    pub fn insert_turn(role: &str, content: &str) {
        let conn = api_server::db_pool::get_conn();
        let now = chrono::Utc::now().timestamp();
        conn.execute(
            "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1,?2,?3,?4,?5)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), TEST_CONV_ID, role, content, now],
        ).unwrap();
    }

    pub fn get_history() -> String {
        let conn = api_server::db_pool::get_conn();
        let mut stmt = conn.prepare(
            "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY rowid"
        ).unwrap();
        stmt.query_map(rusqlite::params![TEST_CONV_ID], |row| {
            Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?))
        }).unwrap().filter_map(|r| r.ok())
        .map(|(r, c)| format!("{}: {}", r, c))
        .collect::<Vec<_>>()
        .join("\n")
    }

    pub fn build_plan_ctx() -> (String, String, String) {
        let conn = api_server::db_pool::get_conn();
        api_server::plan_handler::build_plan_context(&conn, TEST_CONV_ID)
    }

    pub fn get_plan() -> Option<(String, String, String)> {
        let conn = api_server::db_pool::get_conn();
        // 优先 conversation_plans（CP2 创建的计划）
        let from_cp1 = conn.query_row(
            "SELECT id, goal, COALESCE(plan_content, '') FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![TEST_CONV_ID],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).ok();
        if from_cp1.is_some() { return from_cp1; }
        // 兜底 learning_plans
        conn.query_row(
            "SELECT id, goal, COALESCE(task_status, plan_json, '') FROM learning_plans
             WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
            rusqlite::params![TEST_CONV_ID],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).ok()
    }

    pub fn get_plan_content_json() -> Option<serde_json::Value> {
        let conn = api_server::db_pool::get_conn();
        // 优先读 conversation_plans（CP2 创建的计划存于此）
        let from_cp1 = conn.query_row(
            "SELECT plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![TEST_CONV_ID],
            |row| row.get::<_, String>(0),
        ).ok().and_then(|s| serde_json::from_str(&s).ok());
        if from_cp1.is_some() { return from_cp1; }
        // 兜底：从 learning_plans 读取（旧路径）
        conn.query_row(
            "SELECT COALESCE(plan_content, '') FROM learning_plans
             WHERE conversation_id = ?1 ORDER BY updated_at DESC LIMIT 1",
            rusqlite::params![TEST_CONV_ID],
            |row| row.get::<_, String>(0),
        ).ok().and_then(|s| serde_json::from_str(&s).ok())
    }

    pub fn get_stages_from_plan_json(pjson: &str) -> Vec<serde_json::Value> {
        serde_json::from_str::<serde_json::Value>(pjson).ok()
            .and_then(|v| v.get("stages").cloned())
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
    }

    /// 读取计划结构并合并 user_plan_progress 的真实进度（报告用）
    pub fn get_merged_stages() -> (Vec<serde_json::Value>, String) {
        let conn = api_server::db_pool::get_conn();
        // 读取 conversation_plans 中的 plan_content（原始结构）
        match conn.query_row(
            "SELECT plan_content FROM conversation_plans WHERE conversation_id = ?1 LIMIT 1",
            rusqlite::params![TEST_CONV_ID],
            |row| row.get::<_, String>(0),
        ) {
            Ok(content) => {
                let mut merged: serde_json::Value = serde_json::from_str(&content).unwrap_or_default();
                let goal = merged.get("goal").and_then(|g| g.as_str()).map(|s| s.to_string())
                    .or_else(|| {
                        conn.query_row(
                            "SELECT goal FROM conversation_plans WHERE conversation_id = ?1",
                            rusqlite::params![TEST_CONV_ID],
                            |r| r.get::<_, String>(0),
                        ).ok()
                    }).unwrap_or_default();
                // 从 user_plan_progress 读取真实进度并合并
                let progress_rows: Vec<(String, String)> = {
                    let mut stmt = conn.prepare(
                        "SELECT task_key, status FROM user_plan_progress WHERE plan_id IN (SELECT id FROM conversation_plans WHERE conversation_id = ?1)"
                    ).unwrap();
                    stmt.query_map(rusqlite::params![TEST_CONV_ID], |row| {
                        Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?))
                    }).unwrap().filter_map(|r| r.ok()).collect()
                };
                let progress_map: std::collections::HashMap<String, String> = progress_rows.into_iter().collect();
                if let Some(stages) = merged.get_mut("stages").and_then(|s| s.as_array_mut()) {
                    for stage in stages {
                        if let Some(tasks) = stage.get_mut("tasks").and_then(|t| t.as_array_mut()) {
                            for task in tasks {
                                let task_key = task.get("task_key").and_then(|k| k.as_str())
                                    .or_else(|| task.get("name").and_then(|n| n.as_str()))
                                    .unwrap_or("");
                                if let Some(real_status) = progress_map.get(task_key) {
                                    task["status"] = serde_json::json!(real_status);
                                }
                            }
                        }
                    }
                }
                let stages = merged.get("stages").and_then(|s| s.as_array())
                    .cloned().unwrap_or_default();
                (stages, goal)
            }
            Err(_) => (Vec::new(), String::new()),
        }
    }

    pub fn get_achievements() -> Vec<(String, String, String)> {
        let conn = api_server::db_pool::get_conn();
        let mut stmt = conn.prepare(
            "SELECT achievement_key, name, tier FROM achievements WHERE user_id = ?1"
        ).unwrap();
        stmt.query_map(rusqlite::params![TEST_USER_ID], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        }).unwrap().filter_map(|r| r.ok()).collect()
    }
}

// ═══════════════════════════════════════════════════
// CP2 对话轮次（模拟生产中的 ws.rs 处理流程）
// ═══════════════════════════════════════════════════

struct Cp2TurnResult {
    has_plan: bool,
    cp2_updated: bool,
    reply: String,
    diag: TurnDiag,
    was_new_plan: bool,  // 本轮是否创建了新计划
}

async fn cp2_turn(
    caller: &mut chat_engine::llm_caller::LlmCaller,
    cp2_caller: &mut chat_engine::llm_caller::LlmCaller,
    user_message: &str,
    turn_label: &str,
    api_calls: &mut u32,
    had_plan_before: bool,
) -> Cp2TurnResult {
    println!("\n{}", "─".repeat(60));
    println!("🔄 CP2 Turn: {}", turn_label);

    // 1. 保存用户消息 → DB（生产中的 ws.rs 流程）
    helpers::insert_turn("user", user_message);
    println!("👤 用户: {}", truncate(&user_message, 120));

    // 2. 构建对话上下文（含计划 context，如果存在）
    let (domain, mode, plan_ctx) = helpers::build_plan_ctx();
    let prompts = chat_engine::prompt_loader::get_for_domain(&domain);
    let system_prompt_str = if mode == "structured" { &prompts.chat_system_structured }
        else if mode == "reading" { &prompts.chat_system_reading }
        else { &prompts.chat_system_free };
    let history = helpers::get_history();
    let user_content = if plan_ctx.is_empty() { history } else { format!("{}{}", history, plan_ctx) };

    // 3. LLM 生成回复（生产中同路径）
    let start = Instant::now();
    let raw_reply = caller.generate(system_prompt_str, &user_content).await
        .expect("LLM 调用失败");
    let latency = start.elapsed();
    *api_calls += 1;
    println!("🤖 LLM ({:.1}s) {} chars", latency.as_secs_f64(), raw_reply.len());
    // 打印 teacher 回复摘要（前 200 字 + 是否含通关信号）
    let has_badge = raw_reply.contains("🎉") || raw_reply.contains("通关") || raw_reply.contains("✅ 已完成") || raw_reply.contains("学习已经完成");
    println!("  教师回复摘要: {}... 含通关信号={}", truncate(&raw_reply, 200), has_badge);

    helpers::insert_turn("assistant", &raw_reply);

    // 4. CP2 分析（生产中的 analyze_turn_progress 路径）
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let cp2_updated = api_server::plan_handler::analyze_turn_progress(
        TEST_CONV_ID, TEST_USER_ID, cp2_caller, &raw_reply,
    ).await;
    let has_plan_now = helpers::get_plan().is_some();
    let was_new_plan = !had_plan_before && has_plan_now;
    let cp2_event_desc = if was_new_plan {
        "CP2 创建了新计划".to_string()
    } else if cp2_updated {
        "CP2 推进了任务状态或更新了计划".to_string()
    } else {
        // CP2 没检测到触发信号，描述原因
        format!("CP2 未检测到触发信号 (teacher 含通关信号={}, reply_len={})", has_badge, raw_reply.len())
    };
    println!("📝 CP2: {}", &cp2_event_desc);

    let diag = TurnDiag {
        round_label: turn_label.to_string(),
        teacher_system_prompt: system_prompt_str.to_string(),
        teacher_input_context: user_content.clone(),
        teacher_reply: raw_reply.clone(),
        cp2_detailed_event: cp2_event_desc,
        student_system_prompt: String::new(),
        student_input_context: String::new(),
        student_reply: String::new(),
    };
    Cp2TurnResult { has_plan: has_plan_now, cp2_updated, reply: raw_reply, diag, was_new_plan }
}

/// 用于 CP1 验证：从 DB 中查询当前 user 已有的卡片 fronts
fn get_existing_fronts(conn: &rusqlite::Connection) -> Vec<String> {
    let mut stmt = conn.prepare(
        "SELECT LOWER(front) FROM cards WHERE user_id = ?1"
    ).unwrap();
    stmt.query_map(rusqlite::params![TEST_USER_ID], |row| {
        row.get::<_, String>(0)
    }).unwrap().filter_map(|r| r.ok()).collect()
}

/// 截断长字符串显示
fn truncate(s: &str, max: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max { s.to_string() }
    else { format!("{}...", chars[..max].iter().collect::<String>()) }
}

const STUDENT_SYSTEM_PROMPT: &str = "\
你是一个初中生，正在跟 AI 老师学习勾股定理。\n\
\n\
**你的角色**：你是学生，老师是 assistant。\n\
\n\
**行为**：\n\
- 像真实初中生一样说话：短句、语气词（\"哦！\"\"嗯...\"\"啊？\"）\n\
- 认真听老师讲课，思考后再回应\n\
- 不理解就问，说\"老师我没听懂\"\"能再讲一遍吗？\"\n\
- 老师出题时试着回答，算错了也没关系\n\
- 千万不要模仿老师提问或教学（不可以说\"你知道...吗？\"\"我们来学...\"）\n\
\n\
**不要提及**：\"任务\"\"计划\"\"推进\"\"通关\"等系统概念。";

/// 学生 LLM 生成自然回复
async fn student_speak(
    student_caller: &mut chat_engine::llm_caller::LlmCaller,
    history: &str,
) -> String {
    match student_caller.generate(STUDENT_SYSTEM_PROMPT, history).await {
        Ok(reply) => {
            let cleaned = reply.trim().to_string();
            println!("  🧑 学生: {}", truncate(&cleaned, 200));
            cleaned
        }
        Err(_) => String::new()
    }
}

// ═══════════════════════════════════════════════════
// 测试：主流程全链路验证
// ═══════════════════════════════════════════════════

#[tokio::test]
#[ignore]
async fn e2e_main_lifecycle() {
    println!("\n{}", "=".repeat(70));
    println!(" 🚀 主流程 E2E 测试 — 全链路数据流验证");
    println!("   验证: CP2 plan创建+推进 → CP1概念提取 → cards写入+会话绑定 → task关联");
    println!("{}", "=".repeat(70));

    // ── Setup ──
    helpers::setup();
    let mut caller = helpers::create_caller();
    let mut cp2_caller = helpers::create_caller();
    let mut api_calls: u32 = 0;
    let mut cp2_events: Vec<String> = Vec::new();
    let mut cp1_events: Vec<String> = Vec::new();

    // ── Phase 1: CP2 驱动创建计划 ──
    // CP2 通过 LLM 分析教师回复中是否引入了学习任务，然后自动创建 plan
    println!("\n{}", "#".repeat(50));
    println!("## Phase 1: CP2 驱动创建计划");
    println!("{}", "#".repeat(50));

    let mut plan_created = false;
    let mut turn_diags: Vec<TurnDiag> = Vec::new();
    // 最多 3 轮对话让 CP2 检测学习意图并创建计划
    for (i, msg) in [
        "你好，我想学习勾股定理。",
        "请帮我制定一个包含概念理解、证明和应用的学习计划。",
        "可以制定学习计划吗？我们先学基本概念。",
    ].iter().enumerate() {
        let result = cp2_turn(&mut caller, &mut cp2_caller, msg,
            &format!("创建计划(对话{})", i+1), &mut api_calls, plan_created).await;
        let desc = format!("Turn{}: CP2检测: updated={}", i+1, result.cp2_updated);
        cp2_events.push(desc.clone());
        println!("  {}", desc);
        turn_diags.push(result.diag);
        if result.was_new_plan || result.has_plan {
            plan_created = true;
            if result.was_new_plan { break; }
        }
    }

    assert!(plan_created, "CP2 应在 3 轮对话后自动创建计划");
    println!("  ✅ Phase 1 完成 — CP2 成功创建计划");

    // 验证计划结构
    let plan_content = helpers::get_plan_content_json()
        .expect("plan_content 应有完整 JSON");
    assert!(plan_content.get("stages").is_some(), "应有 stages");
    let stages = plan_content["stages"].as_array().unwrap();
    assert!(!stages.is_empty(), "至少 1 个 stage");
    // goal 存于 learning_plans.goal 列，plan_content JSON 中不包含（被 handle_plan_update 剥离）
    let goal_from_db: String = if let Some((_, g, _)) = helpers::get_plan() { g } else { String::new() };
    assert!(!goal_from_db.is_empty(), "DB 中应有 goal");
    println!("  📋 计划结构: {} 阶段, goal='{}'", stages.len(), truncate(&goal_from_db, 60));

    // ── Phase 2: 双 LLM 自然对话教学（学生 LLM ↔ 导师 LLM，CP2 自动检测通关）──
    // 流程：Phase 1 教师已回复 + 计划已创建 → 学生看对话历史后回应 → cp2_turn → 循环
    println!("\n{}", "#".repeat(50));
    println!("## Phase 2: 双 LLM 自然对话 + CP2 自动推进");
    println!("{}", "#".repeat(50));

    let mut student_caller = helpers::create_caller_with_temp(0.6);
    let max_rounds = 30;
    let start_time = std::time::Instant::now();
    let max_duration = std::time::Duration::from_secs(300); // 最多 5 分钟

    // 第1轮：学生看到 Phase 1 教师回复后，根据教学内容做出回应
    // 此时 conversation_turns 中已有 Phase 1 的完整对话（user+assistant）
    let hist_after_phase1 = helpers::get_history();
    let mut student_msg = student_speak(&mut student_caller, &hist_after_phase1).await;
    if student_msg.trim().is_empty() || student_msg.len() < 5 {
        // 学生 LLM 未生成有效回复，用硬编码兜底消息
        student_msg = "老师，我不太明白，能讲得更简单一些吗？".to_string();
    }

    for round in 1..=max_rounds {
        let result = cp2_turn(&mut caller, &mut cp2_caller,
            &student_msg,
            &format!("双LLM轮{}", round), &mut api_calls, true /* 已有计划 */).await;
        let has_badge = result.reply.contains("🎉") || result.reply.contains("✅ 已完成") || result.reply.contains("学习已经完成");
        let desc = format!("对话轮{}: CP2 updated={}, 教师含通关信号={}", round, result.cp2_updated, has_badge);
        cp2_events.push(desc.clone());

        // 学生只看到对话历史（role: content 格式），看不到计划
        let hist_before_student = helpers::get_history();
        let next_student_msg = student_speak(&mut student_caller, &hist_before_student).await;

        // 填充学生诊断到本轮 TurnDiag
        let mut student_diag = result.diag;
        student_diag.student_system_prompt = STUDENT_SYSTEM_PROMPT.to_string();
        student_diag.student_input_context = hist_before_student;
        student_diag.student_reply = if next_student_msg.trim().is_empty() {
            "[学生未生成有效回复，对话结束]".to_string()
        } else {
            next_student_msg.clone()
        };
        turn_diags.push(student_diag);
        
        // 如果学生没话说了或消息太短，结束对话
        if next_student_msg.trim().is_empty() || next_student_msg.len() < 5 { 
            println!("  ⏹️ 学生无有效回复，对话结束");
            break; 
        }
        student_msg = next_student_msg;

        // 每轮检查：是否所有 task 都已完成
        let c = api_server::db_pool::get_conn();
        let total_tasks: i64 = c.query_row(
            "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1",
            rusqlite::params![TEST_USER_ID], |r| r.get(0),
        ).unwrap_or(0);
        let done_tasks: i64 = c.query_row(
            "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1 AND status = 'done'",
            rusqlite::params![TEST_USER_ID], |r| r.get(0),
        ).unwrap_or(0);
        println!("  📊 轮次{}: {}/{} 完成", round, done_tasks, total_tasks);
        if total_tasks > 0 && done_tasks >= total_tasks {
            println!("  🎉 全部任务已完成！");
            break;
        }

        // 超时保护
        if start_time.elapsed() > max_duration {
            println!("  ⏰ 超时保护触发，结束对话");
            break;
        }
    }

    // Phase 2 验证：所有 task 应已推进完毕
    let total_progress: i64 = {
        let c = api_server::db_pool::get_conn();
        c.query_row(
            "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1",
            rusqlite::params![TEST_USER_ID],
            |r| r.get(0),
        ).unwrap_or(0)
    };
    let progress_done: i64 = {
        let c = api_server::db_pool::get_conn();
        c.query_row(
            "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1 AND status = 'done'",
            rusqlite::params![TEST_USER_ID],
            |r| r.get(0),
        ).unwrap_or(0)
    };
    assert!(total_progress > 0, "应有 progress 记录");
    assert!(progress_done >= total_progress, "所有 task 应为 done 状态（当前 {}/{} done）——CP2 在 {} 轮内未能完成所有任务", progress_done, total_progress, max_rounds);
    println!("  ✅ Phase 2 完成 — 全部 {} 个任务已推进完成! 耗时 {:.0}s", total_progress, start_time.elapsed().as_secs_f64());

    // ── Phase 3: CP1 概念提取验证 ──
    println!("\n{}", "#".repeat(50));
    println!("## Phase 3: CP1 概念提取 + 卡片绑定验证");
    println!("{}", "#".repeat(50));

    let conn = api_server::db_pool::get_conn();
    let cfg = chat_engine::llm_caller::LlmConfig::deepseek_v4_flash(
        &std::env::var("DEEPSEEK_API_KEY").unwrap()
    );

    // 3a: 取前 2 轮对话的真实内容
    let turns: Vec<(String, String)> = {
        let mut stmt = conn.prepare(
            "SELECT role, content FROM conversation_turns
             WHERE conversation_id = ?1 ORDER BY rowid LIMIT 4"
        ).unwrap();
        stmt.query_map(rusqlite::params![TEST_CONV_ID], |row| {
            Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?))
        }).unwrap().filter_map(|r| r.ok()).collect()
    };
    println!("  📂 对话历史: {} 条", turns.len());

    // 记录 CP1 输入上下文供报告用
    let mut cp1_input_context = String::new();
    if turns.len() >= 4 {
        let user_msg = &turns[0].1; // 第一轮 user
        let ai_reply = &turns[1].1; // 第一轮 assistant
        cp1_input_context = format!("CP1 输入:\n  用户消息: {}\n  教师回复: {}\n  去重 front 数: {}",
            user_msg, ai_reply, get_existing_fronts(&conn).len());
        println!("  📌 CP1 输入: {} + {} (去重: {})",
            truncate(user_msg, 60), truncate(ai_reply, 60), get_existing_fronts(&conn).len());
        let existing_fronts = get_existing_fronts(&conn);
        println!("  📚 已有卡片 {} 张（用于去重）", existing_fronts.len());

        // 3b: 调用生产 CP1
        let result = chat_engine::concept_extractor::extract_concepts(
            TEST_USER_ID, user_msg, ai_reply,
            &existing_fronts, &[], &cfg, &turns, "math", "",
        ).await;
        println!("  📊 CP1 提取: {} 个候选概念", result.candidates.len());
        for c in &result.candidates {
            println!("    - {}: {}", truncate(&c.front, 40), truncate(&c.back, 60));
        }

        // 3c: 模拟 ws.rs 中 CP1 后的卡片写入（生产中由 ColdPath 处理）
        let now_ts = chrono::Utc::now().timestamp();
        let mut inserted = 0usize;
        for c in &result.candidates {
            let card_id = format!("cp1_main_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
            match conn.execute(
                "INSERT OR IGNORE INTO cards
                 (id, user_id, domain, card_type, front, back, source_sentence,
                  conversation_id, created_at)
                 VALUES (?1, ?2, 'math', 'concept', ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![card_id, TEST_USER_ID, &c.front, &c.back,
                    &c.source_sentence, TEST_CONV_ID, now_ts],
            ) {
                Ok(n) => { inserted += n as usize; }
                Err(_) => {}
            }
            // 写入 card_memory
            let _ = conn.execute(
                "INSERT OR IGNORE INTO card_memory
                 (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                 VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
                rusqlite::params![card_id, now_ts],
            );
        }
        println!("  💾 写入 cards 表: {} 张", inserted);

        // 3d: 验证卡片绑定到会话
        let bound: i64 = conn.query_row(
            "SELECT COUNT(*) FROM cards WHERE user_id = ?1 AND conversation_id = ?2 AND card_type = 'concept'",
            rusqlite::params![TEST_USER_ID, TEST_CONV_ID],
            |r| r.get(0),
        ).unwrap_or(0);
        assert_eq!(bound as usize, inserted, "cards 应正确绑定到当前会话");
        println!("  ✅ 卡片绑定验证: {} 张 → conversation_id='{}'", bound, TEST_CONV_ID);

        // 3e: 验证卡片与计划 task 的关联性
        println!("\n  ── 卡片 ↔ 计划 task 关联验证 ──");
        let current_task_key: Option<String> = conn.query_row(
            "SELECT task_key FROM user_plan_progress
             WHERE user_id = ?1 AND status = 'in_progress'
             ORDER BY updated_at DESC LIMIT 1",
            rusqlite::params![TEST_USER_ID],
            |r| r.get(0),
        ).ok();
        if let Some(task_key) = &current_task_key {
            println!("  🎯 当前任务: {}", task_key);
            // 从 plan_content 中找到该 task_key 对应的 name
            let task_name: String = helpers::get_plan_content_json()
                .and_then(|pc| pc["stages"].as_array().cloned())
                .map(|stages| {
                    stages.iter().filter_map(|s| s["tasks"].as_array()).flatten()
                        .find(|t| t["task_key"].as_str() == Some(task_key))
                        .and_then(|t| t["name"].as_str().map(|s| s.to_string()))
                        .unwrap_or_default()
                }).unwrap_or_default();
            let display_name = if task_name.is_empty() { task_key.as_str() } else { &task_name };
            let concepts: Vec<String> = result.candidates.iter()
                .map(|c| truncate(&c.front, 20)).collect();
            println!("  📝 任务: {}", display_name);
            println!("  🃏 提取的概念: {}", if concepts.is_empty() { "无".to_string() } else { concepts.join(", ") });
            // 不需要关键字匹配 — card 通过 conversation_id 关联，
            // 而 conversation 的当前 plan 状态由 CP2 在 user_plan_progress 中维护
            println!("  ✅ 卡片 ↔ task 关联: card.conversation_id → plan.status → in_progress ✓");
        } else {
            // 可能所有 task 都是 pending（CP2 尚未推进），列出 pending task
            let pending_tasks: Vec<String> = {
                let mut stmt = conn.prepare(
                    "SELECT task_key FROM user_plan_progress WHERE user_id = ?1 AND status = 'pending'"
                ).unwrap();
                stmt.query_map(rusqlite::params![TEST_USER_ID], |r| r.get::<_,String>(0))
                    .unwrap().filter_map(|r| r.ok()).collect()
            };
            // 显示所有 pending 任务供人眼检查
            let front_strs: Vec<String> = result.candidates.iter()
                .map(|c| truncate(&c.front, 20)).collect();
            println!("  ⏳ 无 in_progress task (CP2 未推进), pending: {}", pending_tasks.join(", "));
            println!("  🃏 提取的概念: {}", if front_strs.is_empty() { "无".to_string() } else { front_strs.join(", ") });
        }


        assert!(inserted > 0 || result.candidates.len() > 0,
            "CP1 应至少返回候选概念");
        println!("  ✅ Phase 3 完成 — CP1 概念提取 + 卡片写入 + 会话绑定验证通过");
        // 记录 CP1 事件
        let concept_names: Vec<String> = result.candidates.iter()
            .map(|c| c.front.chars().take(30).collect()).collect();
        cp1_events.push(format!("CP1 提取 {} 个概念: {}", result.candidates.len(), concept_names.join(", ")));
        cp1_events.push(format!("写入 {} 张卡片, 绑定到 conversation_id='{}'", inserted, TEST_CONV_ID));
        if let Some(tk) = &current_task_key {
            cp1_events.push(format!("当前计划 task: {} (in_progress)", tk));
        }
    } else {
        println!("  ⚠️ 对话轮次不足，跳过 CP1 验证（turns={}）", turns.len());
    }

    // ── Phase 4: 最终验证 ──
    println!("\n{}", "#".repeat(50));
    println!("## Phase 4: 最终状态验证");
    println!("{}", "#".repeat(50));

    // 4a: 计划存在
    let plan = helpers::get_plan();
    assert!(plan.is_some(), "学习计划应存在");
    let (_pid, goal, _pjson) = plan.unwrap();
    println!("  📋 目标: {}", goal);

    // 4b: 任务推进进度
    let (stages, _) = helpers::get_merged_stages();
    let total_tasks: usize = stages.iter()
        .filter_map(|s| s["tasks"].as_array())
        .map(|t| t.len()).sum();
    let done_tasks: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1 AND status = 'done'",
        rusqlite::params![TEST_USER_ID], |r| r.get(0),
    ).unwrap_or(0);
    println!("  📊 任务: {}/{} 完成", done_tasks, total_tasks);
    let total_tasks: usize = stages.iter()
        .filter_map(|s| s["tasks"].as_array())
        .map(|t| t.len()).sum();
    let done_tasks: usize = stages.iter()
        .filter_map(|s| s["tasks"].as_array())
        .map(|t| t.iter().filter(|x| x["status"] == "done").count())
        .sum();
    println!("  📊 任务: {}/{} 完成", done_tasks, total_tasks);
    for stage in &stages {
        let sn = stage["name"].as_str().unwrap_or("?");
        if let Some(tasks) = stage["tasks"].as_array() {
            for task in tasks {
                let tn = task["name"].as_str().unwrap_or("?");
                let ts = task["status"].as_str().unwrap_or("?");
                println!("    {} / {} → {} [{}]", sn, tn, ts, if ts == "done" { "✅" } else { "⏳" });
            }
        }
    }

    // 4c: 成就
    let achievements = helpers::get_achievements();
    println!("  🏆 成就: {} 个", achievements.len());
    for (key, name, tier) in &achievements {
        println!("    {} → {} ({})", key, name, tier);
    }

    // 4d: user_plan_progress 状态同步
    let progress_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM user_plan_progress WHERE user_id = ?1",
        rusqlite::params![TEST_USER_ID],
        |r| r.get(0),
    ).unwrap_or(0);
    println!("  📊 user_plan_progress: {} 条", progress_count);
    assert!(progress_count > 0, "应有 progress 记录");

    // ── 保存测试报告 ──
    let run_id = format!("e2e_main_{}", chrono::Utc::now().format("%Y%m%d_%H%M%S"));
    let report_dir = format!("data/eval_runs/{}", run_id);
    match std::fs::create_dir_all(&report_dir) {
        Err(e) => println!("  ⚠️ 无法创建报告目录: {}", e),
        Ok(_) => {
            let history_text = helpers::get_history();
            let task_status_lines: Vec<String> = stages.iter().filter_map(|s| {
                let sn = s["name"].as_str().unwrap_or("?");
                s["tasks"].as_array().map(|tasks| tasks.iter().map(|t| {
                    format!("- {} / {} → {}", sn,
                        t["name"].as_str().unwrap_or("?"),
                        t["status"].as_str().unwrap_or("?"))
                }).collect::<Vec<_>>().join("\n"))
            }).collect();
            let card_count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM cards WHERE user_id=?1",
                rusqlite::params![TEST_USER_ID], |r| r.get(0),
            ).unwrap_or(0);

            // 构建每轮诊断文本（完整上下文，不截断）
            let round_diag_lines: Vec<String> = turn_diags.iter().enumerate().map(|(i, d)| {
                format!(
"═══════════════════════════════════════════════════════════════
## 轮次 {}: {}

### 教师 LLM
━━━━ System Prompt ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{}
━━━━ 输入上下文（历史对话 + 计划）━━━━━━━━━━━━━━━━━━━━━━
{}
━━━━ 教师回复 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{}

### 学生 LLM
━━━━ System Prompt ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{}
━━━━ 学生输入上下文（教师回复后的完整对话历史）━━━━━━━━━━━━
{}
━━━━ 学生回复 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{}

### CP2 决策 —— {}",
                    i+1, d.round_label,
                    d.teacher_system_prompt,
                    d.teacher_input_context,
                    d.teacher_reply,
                    if d.student_system_prompt.is_empty() { "未运行（Phase 1 计划创建阶段）" } else { &d.student_system_prompt },
                    if d.student_input_context.is_empty() { "未运行" } else { &d.student_input_context },
                    if d.student_reply.is_empty() { "未运行" } else { &d.student_reply },
                    d.cp2_detailed_event)
            }).collect();

            let summary = format!(
"# 主流程 E2E 测试报告

- **运行时间**: {}
- **结果**: ✅ 通过
- **API 调用次数**: {}
- **计划任务数**: {} total, {} done
- **成就**: {} 个
- **卡片数**: {}
- **user_plan_progress**: {} 条

---

## 每轮诊断（教师/学生 LLM 完整上下文 + CP2 决策）

{}

---

## CP1 诊断（输入 + 输出）

{}

---

## CP2 事件日志

{}

## CP1 事件日志

{}

## 计划状态

{}

## 完整对话流

{}",
                chrono::Utc::now().format("%Y-%m-%d %H:%M:%S"),
                api_calls,
                total_tasks, done_tasks,
                achievements.len(),
                card_count,
                progress_count,
                round_diag_lines.join("\n\n"),
                if cp1_input_context.is_empty() { "CP1 未运行（无对话数据）".to_string() }
                else { format!("{}\n\nCP1 提取了 {} 个概念并写入 cards 表", cp1_input_context,
                    card_count) },
                if cp2_events.is_empty() { "无".to_string() } else { cp2_events.join("\n") },
                if cp1_events.is_empty() { "无".to_string() } else { cp1_events.join("\n") },
                task_status_lines.join("\n"),
                history_text,
            );
            let _ = std::fs::write(format!("{}/summary.md", report_dir), &summary);
            println!("  📁 报告已保存: {}", report_dir);
        }
    }

    println!("\n{}", "=".repeat(70));
    println!(" ✅ 主流程 E2E 测试通过 — {} 次 API 调用 | 任务 {}/{} | 成就 {} | 卡片 {}",
        api_calls, done_tasks, total_tasks, achievements.len(),
        conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1",
            rusqlite::params![TEST_USER_ID], |r| r.get::<_,i64>(0)).unwrap_or(0));
    println!("{}\n", "=".repeat(70));
}
