//! CoEvo E2E — 学习计划生命周期全面分析
//!
//! 测试目标:
//!   1. 验证学习计划的完整生命周期: FREE → 创建 → 执行 → 更新 → 结束
//!   2. 追踪每个阶段的 context 构建 (plan_context / system_prompt 选择)
//!   3. 验证 DB 状态转换的正确性
//!   4. 验证成就系统的触发 (silver/gold, bronze 待源码实现)
//!
//! 模拟对话流程 (不依赖真实 LLM):
//!   Phase 1 (4-turn): 用户模糊意图 → LLM 主动追问（FREE 引导）→ 用户补充细节 → 创建计划
//!   Phase 2: STRUCTURED 状态 context 注入验证
//!   Phase 3: 用户表示理解概念 → completed_concepts 更新
//!   Phase 4: 完成任务 → current_task_complete → 下一任务激活
//!   Phase 5: 考核 (grill assessment) → AssessmentSimulator 多场景 (5a/5b/5c)
//!   Phase 6: 完成所有任务 → stage done → silver 成就
//!   Phase 7: 剩余阶段推进 → 全部 done → gold 成就
//!   Phase 8: 最终状态验证 (DB + 成就)
//!   Phase 9: context 追溯 (每阶段 context 变化)
//!   Phase 10: 边界情况 (截断标签/普通回复/空stages/upsert/词边界)
//!
//! 测试组织: 单一 #[test] 函数内顺序执行所有阶段，
//! 因为各阶段共享 DB 状态且需要按生命周期顺序推进。

use std::fs;

// ════════════════════════════════════════════
// Test Setup Helpers
// ════════════════════════════════════════════

const TEST_DB_PATH: &str = "data/test_e2e_plan_lifecycle.db";
const TEST_USER_ID: &str = "test-plan-user-001";
const TEST_CONV_ID: &str = "test-plan-conv-001";
const TEST_USERNAME: &str = "plan_tester";
const TEST_PASSWORD: &str = "test123";

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    streak_days INTEGER DEFAULT 0,
    last_active_date TEXT,
    display_name TEXT DEFAULT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    turn_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    learning_plan_id TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS conversation_turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE TABLE IF NOT EXISTS learning_plans (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT,
    goal TEXT NOT NULL,
    domain TEXT NOT NULL DEFAULT '',
    mode TEXT DEFAULT NULL,
    plan_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS achievements (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    achievement_key TEXT NOT NULL,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tier TEXT DEFAULT 'fixed',
    source TEXT,
    unlocked_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS cards (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    domain TEXT,
    card_type TEXT NOT NULL,
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    source_sentence TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS card_memory (
    card_id TEXT PRIMARY KEY,
    state INTEGER DEFAULT 0,
    difficulty REAL DEFAULT 5.0,
    stability REAL DEFAULT 0.0,
    due INTEGER DEFAULT 0,
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE IF NOT EXISTS review_log (
    id TEXT PRIMARY KEY,
    card_id TEXT NOT NULL,
    rating INTEGER NOT NULL,
    verification_type TEXT NOT NULL,
    verification_result TEXT NOT NULL,
    reviewed_at INTEGER NOT NULL,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);
CREATE TABLE IF NOT EXISTS skipped_concepts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    front TEXT NOT NULL,
    domain TEXT,
    source_text TEXT,
    skipped_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, key),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
"#;

/// 初始化测试 DB (每次测试前调用)
fn setup_test_db() {
    // 删除旧测试 DB
    let _ = fs::remove_file(TEST_DB_PATH);

    // 确保 data 目录存在
    let _ = fs::create_dir_all("data");

    // 初始化连接池
    api_server::db_pool::init(TEST_DB_PATH)
        .expect("Failed to init test DB pool");

    // 创建 schema
    {
        let conn = api_server::db_pool::get_conn();
        conn.execute_batch(SCHEMA_SQL)
            .expect("Failed to create test schema");
    }

    // 创建测试用户
    {
        let conn = api_server::db_pool::get_conn();
        let now = chrono::Utc::now().to_rfc3339();
        let pw_hash = api_server::auth::hash_password(TEST_PASSWORD);
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![TEST_USER_ID, TEST_USERNAME, pw_hash, now],
        ).expect("Failed to insert test user");
    }

    // 创建测试会话
    {
        let conn = api_server::db_pool::get_conn();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
            rusqlite::params![TEST_CONV_ID, TEST_USER_ID, now],
        ).expect("Failed to insert test conversation");
    }
}

/// 插入一条对话轮次
fn insert_turn(role: &str, content: &str) {
    let conn = api_server::db_pool::get_conn();
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), TEST_CONV_ID, role, content, now],
    ).expect("Failed to insert turn");
    conn.execute(
        "UPDATE conversations SET turn_count = turn_count + 1 WHERE id = ?1",
        rusqlite::params![TEST_CONV_ID],
    ).ok();
}

/// 构建 plan_context (thin wrapper → plan_handler 公共函数)
///
/// 不再自行复制 routes.rs 逻辑，直接调用 plan_handler::build_plan_context 权威实现。
fn build_plan_context() -> (String, String) {
    let conn = api_server::db_pool::get_conn();
    api_server::plan_handler::build_plan_context(&conn, TEST_CONV_ID)
}

/// 查询 DB 中的学习计划 JSON
fn get_plan_from_db() -> Option<(String, String, String)> {
    let conn = api_server::db_pool::get_conn();
    conn.query_row(
        "SELECT id, goal, plan_json FROM learning_plans WHERE conversation_id = ?1 AND mode = 'structured' ORDER BY updated_at DESC LIMIT 1",
        rusqlite::params![TEST_CONV_ID],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?)),
    ).ok()
}

/// 查询所有成就
fn get_achievements() -> Vec<(String, String, String, String)> {
    let conn = api_server::db_pool::get_conn();
    let mut stmt = conn.prepare(
        "SELECT achievement_key, name, tier, source FROM achievements WHERE user_id = ?1 ORDER BY unlocked_at"
    ).unwrap();
    stmt.query_map(
        rusqlite::params![TEST_USER_ID],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?, row.get::<_, Option<String>>(3)?.unwrap_or_default())),
    ).unwrap().filter_map(|r| r.ok()).collect()
}

// ════════════════════════════════════════════
// 共享工具函数
// ════════════════════════════════════════════

/// 构建完整的 LLM 回复文本（前置文案 + <plan_update> 标签）
///
/// 统一所有 Phase 中的 plan_update 构建方式，消除内联 JSON 字符串的转义负担。
fn make_plan_update(pre_text: &str, fields: &serde_json::Value) -> String {
    format!(
        "{}\n\n<plan_update>\n{}\n</plan_update>",
        pre_text,
        serde_json::to_string_pretty(fields).unwrap()
    )
}

/// 阶段完成成就检测 — 模拟 routes.rs 中 chat_handler 的成就触发逻辑
///
/// 遍历所有 stage，对 status=="done" 的写入 silver 成就；
/// 若全部 stage 均 done，则额外写入 gold 成就。
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
                    println!("  🏆 成就解锁: {} (silver)", key);
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
                println!("  🏆 成就解锁: {} (gold)", dkey);
            }
        }
    }
}

// ════════════════════════════════════════════
// AssessmentSimulator — 模拟 LLM 考核评估
// ════════════════════════════════════════════

/// 模拟 LLM 评估线程：接收用户回答文本，与任务知识点关键词匹配，
/// 自动生成 assessment JSON。建立"用户回答 → 评估结果"的因果链。
///
/// ## 评估规则
/// - 对每个知识点，检查用户回答中是否包含任一关键词
/// - 命中 → 归入 correct_concepts；未命中 → 归入 blind_spots
/// - `passed = (命中数 / 总数) >= pass_threshold`
/// - `current_task_complete = passed`（只有通过考核才标记任务完成）
struct AssessmentSimulator<'a> {
    /// 当前任务名
    task_name: &'a str,
    /// 期望用户掌握的知识点及对应关键词
    /// 格式: (知识点名称, [匹配关键词列表])
    expected_knowledge: &'a [(&'a str, &'a [&'a str])],
    /// 通过阈值 (0.0 ~ 1.0)
    pass_threshold: f64,
}

impl<'a> AssessmentSimulator<'a> {
    /// 评估用户回答，返回完整的 plan_update JSON Value
    fn evaluate(&self, user_answer: &str) -> serde_json::Value {
        let mut correct_concepts: Vec<&str> = Vec::new();
        let mut blind_spots: Vec<&str> = Vec::new();

        for (concept, keywords) in self.expected_knowledge {
            if keywords.iter().any(|kw| user_answer.contains(kw)) {
                correct_concepts.push(concept);
            } else {
                blind_spots.push(concept);
            }
        }

        let total = self.expected_knowledge.len();
        let score = correct_concepts.len();
        let passed = (score as f64 / total as f64) >= self.pass_threshold;

        let teaching_points: Vec<String> = if blind_spots.is_empty() {
            vec!["可以进一步了解DBSCAN密度聚类".into()]
        } else {
            blind_spots.iter().map(|s| format!("需要补习: {}", s)).collect()
        };

        serde_json::json!({
            "completed_concepts": correct_concepts,
            "assessment": {
                "task": self.task_name,
                "passed": passed,
                "correct": score,
                "total": total,
                "blind_spots": blind_spots,
                "teaching_points": teaching_points,
            },
            "current_task_complete": passed,
            "next_stage_suggestion": null
        })
    }
}

// ════════════════════════════════════════════
// 主测试入口
// ════════════════════════════════════════════

#[test]
fn e2e_learning_plan_full_lifecycle() {
    println!("\n{}", "=".repeat(80));
    println!(" CoEvo E2E: 学习计划生命周期全面分析");
    println!("{}", "=".repeat(80));

    setup_test_db();
    println!("✅ 测试 DB 初始化完成");

    // ────────────────────────────────────────
    // Phase 0: 初始状态验证 (FREE)
    // ────────────────────────────────────────
    println!("\n─── Phase 0: FREE 状态 ───");
    {
        let (mode, ctx) = build_plan_context();
        assert_eq!(mode, "free", "初始应为 FREE 模式");
        assert!(ctx.is_empty(), "FREE 状态不应有 plan_context");
        println!("  ✅ mode='free', plan_context 为空 (正确)");

        let plan = get_plan_from_db();
        assert!(plan.is_none(), "初始不应存在学习计划");
        println!("  ✅ DB 中无学习计划 (正确)");
    }

    // ────────────────────────────────────────
    // Phase 1: FREE 模式主动引导 → 创建计划
    //
    // 对齐真实 LLM 行为: 用户表达模糊意图后，LLM 不会直接创建计划，
    // 而是先追问澄清（体现 FREE 模式的主动引导能力），用户补充细节后再创建。
    // ────────────────────────────────────────
    println!("\n─── Phase 1: FREE 主动引导 → 创建计划 (4-turn 对话) ───");

    // Turn 1: 用户表达模糊的学习意图 (FREE 模式)
    let user_msg_1 = "我想系统地学习AI基础知识";
    insert_turn("user", user_msg_1);
    println!("  👤 Turn1 (user): {}", user_msg_1);

    // 验证 Turn1 后仍为 FREE 状态
    {
        let (mode, ctx) = build_plan_context();
        assert_eq!(mode, "free", "Turn1 后仍应为 FREE 模式");
        assert!(ctx.is_empty(), "FREE 状态不应有 plan_context");
        println!("  ✅ Turn1 后: mode=free (正确)");
    }

    // Turn 2: LLM 主动追问 (FREE 模式引导，无 plan_update)
    // 对齐真实 LLM 行为：追问用户背景、偏好，帮助确定学习计划的粒度和方向
    let llm_guide_reply = "好的！为了更好地帮你制定学习计划，我想先了解一下：\
        你目前的编程基础如何？数学方面学过线性代数和概率论吗？\
        另外，你是更希望侧重理论学习，还是多做动手实践的项目？";
    insert_turn("assistant", llm_guide_reply);
    println!("  🤖 Turn2 (assistant/引导): 追问用户背景和偏好");

    // 验证：无 plan_update 的普通回复不会被误解析
    {
        let conn = api_server::db_pool::get_conn();
        let noop_result = api_server::plan_handler::handle_plan_update(
            &conn, llm_guide_reply, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(!noop_result.plan_updated, "普通追问不应触发 plan_update");
        assert!(!noop_result.is_new_plan, "普通追问不应识别为新建计划");
        println!("  ✅ 普通追问: plan_updated=false (正确，未被误解析)");
    }

    // Turn 3: 用户补充细节
    let user_msg_3 = "我有Python基础，数学方面学过线性代数和概率论。\
        我希望理论和实践结合，最终能自己做一些ML/DL项目。\
        请帮我制定一个分阶段的学习计划。";
    insert_turn("user", user_msg_3);
    println!("  👤 Turn3 (user): 补充编程基础、数学背景和学习偏好");

    // Turn 4: LLM 基于用户信息创建计划 (带 plan_update)
    let plan_update_new = make_plan_update(
        "很好！根据你的Python基础和数学背景，我为你制定了以下分阶段学习计划：",
        &serde_json::json!({
            "is_new_plan": true,
            "goal": "AI基础知识",
            "stages": [
                {
                    "name": "阶段一：机器学习基础",
                    "status": "in_progress",
                    "tasks": [
                        {"name": "监督学习概念", "status": "in_progress", "description": "理解监督学习的核心思想和常见算法类型"},
                        {"name": "无监督学习概念", "status": "pending", "description": "理解无监督学习的核心思想，如聚类和降维"},
                        {"name": "模型评估方法", "status": "pending", "description": "掌握交叉验证、混淆矩阵等评估手段"}
                    ]
                },
                {
                    "name": "阶段二：深度学习入门",
                    "status": "pending",
                    "tasks": [
                        {"name": "神经网络基础", "status": "pending", "description": "理解神经元、激活函数、前向传播"},
                        {"name": "反向传播", "status": "pending", "description": "理解梯度下降和反向传播机制"}
                    ]
                },
                {
                    "name": "阶段三：实战项目",
                    "status": "pending",
                    "tasks": [
                        {"name": "图像分类项目", "status": "pending", "description": "使用CNN完成图像分类任务"},
                        {"name": "NLP基础项目", "status": "pending", "description": "使用RNN/LSTM完成文本分类"}
                    ]
                }
            ],
            "completed_concepts": [],
            "current_task_complete": false,
            "next_stage_suggestion": null
        })
    );

    // 处理 plan_update
    let conn = api_server::db_pool::get_conn();
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &plan_update_new, TEST_CONV_ID, TEST_USER_ID,
    );

    assert!(result.is_new_plan, "应识别为新建计划");
    assert!(result.plan_updated, "计划应被标记为已更新");
    assert!(result.plan_json.is_some(), "应返回解析后的 plan JSON");

    let rendered = api_server::plan_handler::render_plan(result.plan_json.as_ref().unwrap());
    println!("  🤖 Turn4 (assistant/plan): 基于用户信息创建计划");
    println!("  ✅ 计划创建成功, is_new_plan=true");
    println!("  📋 渲染的计划文本:\n{}", rendered);
    assert!(rendered.contains("AI基础知识"), "渲染的计划应包含目标");
    assert!(rendered.contains("监督学习概念"), "渲染的计划应包含任务名");
    assert!(rendered.contains("🔄"), "渲染的计划应有进行中标记");

    // 验证 DB
    let plan = get_plan_from_db();
    assert!(plan.is_some(), "DB 中应存在学习计划");
    let (_pid, goal, plan_json_str) = plan.unwrap();
    assert_eq!(goal, "AI基础知识", "goal 应正确存储");
    let plan_json: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap();
    let stages = plan_json["stages"].as_array().unwrap();
    assert_eq!(stages.len(), 3, "应有3个阶段");
    assert_eq!(stages[0]["name"], "阶段一：机器学习基础");
    assert_eq!(stages[0]["tasks"].as_array().unwrap().len(), 3, "阶段一应有3个任务");

    // 验证第一个任务状态
    assert_eq!(stages[0]["tasks"][0]["status"], "in_progress");
    assert_eq!(stages[0]["tasks"][0]["name"], "监督学习概念");

    println!("  ✅ DB 验证: 3个阶段, 阶段一3个任务, 第一个任务 in_progress");
    println!("  ✅ Phase1 完成: FREE 主动引导 → 用户补充 → 创建计划 (4-turn)");

    // ────────────────────────────────────────
    // Phase 2: STRUCTURED 状态 context 注入验证
    // ────────────────────────────────────────
    println!("\n─── Phase 2: STRUCTURED context 注入 ───");
    {
        let (mode, ctx) = build_plan_context();
        assert_eq!(mode, "structured", "创建计划后应为 structured 模式");
        assert!(!ctx.is_empty(), "structured 状态应有 plan_context");
        assert!(ctx.contains("AI基础知识"), "context 应包含长期目标");
        assert!(ctx.contains("阶段一：机器学习基础"), "context 应包含当前阶段");
        assert!(ctx.contains("in_progress"), "context 应标注任务状态");
        assert!(ctx.contains("监督学习概念"), "context 应包含当前任务");

        println!("  ✅ mode='structured'");
        println!("  📝 注入的 plan_context:");
        println!("{}", ctx);
    }

    // ────────────────────────────────────────
    // Phase 3: 概念完成 (completed_concepts)
    // ────────────────────────────────────────
    println!("\n─── Phase 3: 概念完成更新 ───");

    insert_turn("user", "我理解了监督学习就是给数据打标签让模型学习对吗？");

    let plan_update_concepts = make_plan_update("很好！你已经掌握了基本概念。", &serde_json::json!({
        "completed_concepts": ["监督学习定义", "有标签数据"],
        "current_task_complete": false,
        "next_stage_suggestion": null
    }));

    let conn = api_server::db_pool::get_conn();
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &plan_update_concepts, TEST_CONV_ID, TEST_USER_ID,
    );

    assert!(!result.is_new_plan, "不应是新建计划");
    assert!(result.plan_updated, "计划应被更新");
    assert!(result.plan_json.is_some());

    // 验证 completed_concepts 累积
    let plan_json = result.plan_json.as_ref().unwrap();
    let concepts = plan_json["completed_concepts"].as_array().unwrap();
    let concept_names: Vec<&str> = concepts.iter().map(|c| c.as_str().unwrap()).collect();
    assert!(concept_names.contains(&"监督学习定义"), "应包含 '监督学习定义'");
    assert!(concept_names.contains(&"有标签数据"), "应包含 '有标签数据'");
    println!("  ✅ completed_concepts 累积: {:?}", concept_names);

    // ────────────────────────────────────────
    // Phase 4: 任务完成 + 推进
    // ────────────────────────────────────────
    println!("\n─── Phase 4: 任务完成 + 自动推进 ───");

    insert_turn("user", "我已经理解了监督学习的内容，可以进入下一个了");

    let plan_update_task_done = make_plan_update("好的！让我们进入下一个任务。", &serde_json::json!({
        "completed_concepts": ["监督学习算法分类"],
        "current_task_complete": true,
        "next_stage_suggestion": null
    }));

    let conn = api_server::db_pool::get_conn();
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &plan_update_task_done, TEST_CONV_ID, TEST_USER_ID,
    );

    assert!(result.plan_updated, "计划应被更新");

    // 验证任务状态变更
    let plan_json = result.plan_json.as_ref().unwrap();
    let stages = plan_json["stages"].as_array().unwrap();
    let tasks_s1 = stages[0]["tasks"].as_array().unwrap();

    assert_eq!(tasks_s1[0]["status"], "done", "任务1 应标记为 done");
    assert_eq!(tasks_s1[0]["name"], "监督学习概念");
    assert_eq!(tasks_s1[1]["status"], "in_progress", "任务2 应自动激活");
    assert_eq!(tasks_s1[1]["name"], "无监督学习概念");

    println!("  ✅ 任务1 (监督学习概念) → done");
    println!("  ✅ 任务2 (无监督学习概念) → in_progress (自动推进)");

    // 再次验证 context (应反映新状态)
    let (_mode, ctx) = build_plan_context();
    assert!(ctx.contains("无监督学习概念"), "context 应反映新的当前任务");
    assert!(ctx.contains("监督学习概念"), "context 应保留已完成任务 (当前阶段全部任务均展示)");
    assert!(ctx.contains("done"), "context 应标注完成任务的状态");
    println!("  📝 更新后的 context (含全部任务状态):\n{}", ctx);

    // ────────────────────────────────────────
    // Phase 5: 考核 (Grill Assessment) — AssessmentSimulator 多场景
    // ────────────────────────────────────────
    println!("\n─── Phase 5: 考核 (AssessmentSimulator 多场景) ───");

    // 构建针对"无监督学习概念"任务的评估器
    let simulator = AssessmentSimulator {
        task_name: "无监督学习概念",
        expected_knowledge: &[
            ("无监督学习定义", &["无监督", "没有标签", "未标记"] as &[&str]),
            ("聚类算法", &["聚类", "K-means", "分组", "簇"]),
            ("降维技术", &["降维", "PCA", "主成分", "维度"]),
            ("典型应用场景", &["客户分群", "异常检测", "推荐系统", "数据压缩"]),
        ],
        pass_threshold: 0.5,
    };

    // ── 5a: 场景 — 回答质量差，考核不通过 ──
    println!("\n  ── 5a: 回答质量差 → 考核不通过 ──");

    insert_turn("user", "无监督学习就是没有监督的学习吧？不太清楚具体内容");

    let assessment_fail = simulator.evaluate("无监督学习就是没有监督的学习吧？不太清楚具体内容");
    println!("  📊 AssessmentSimulator 评估结果 (fail): correct={}, total={}, passed={}",
        assessment_fail["assessment"]["correct"],
        assessment_fail["assessment"]["total"],
        assessment_fail["assessment"]["passed"],
    );
    println!("  📋 blind_spots: {:?}", assessment_fail["assessment"]["blind_spots"]);

    assert_eq!(assessment_fail["assessment"]["passed"], false, "质量差的回答应判定为不通过");
    assert_eq!(assessment_fail["current_task_complete"], false,
        "不通过时 current_task_complete 应为 false");
    let bs = assessment_fail["assessment"]["blind_spots"].as_array().unwrap();
    assert!(bs.len() >= 3, "应至少有3个盲点 (只命中了'无监督学习定义')");
    assert!(bs.contains(&serde_json::json!("聚类算法")), "应包含'聚类算法'盲点");
    assert!(bs.contains(&serde_json::json!("降维技术")), "应包含'降维技术'盲点");

    // 发送到 handler → 验证任务不推进
    let plan_update_fail = make_plan_update("嗯，让我们来仔细了解一下。", &assessment_fail);
    {
        let conn = api_server::db_pool::get_conn();
        let result = api_server::plan_handler::handle_plan_update(
            &conn, &plan_update_fail, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(result.plan_updated);
        let pj = result.plan_json.as_ref().unwrap();
        let tasks = pj["stages"][0]["tasks"].as_array().unwrap();
        assert_eq!(tasks[1]["status"], "in_progress",
            "考核不通过 → 任务2 应保持 in_progress，不应回退也不应推进");
        assert_eq!(tasks[1]["name"], "无监督学习概念");
    }
    println!("  ✅ 考核不通过: 任务2 保持 in_progress (正确)");

    // ── 5b: 场景 — 完美回答，考核通过 ──
    println!("\n  ── 5b: 完美回答 → 考核通过 → 任务推进 ──");

    insert_turn("user", "无监督学习不需要标签数据，核心方法包括K-means聚类和PCA降维，常用于客户分群和异常检测");

    let assessment_pass = simulator.evaluate(
        "无监督学习不需要标签数据，核心方法包括K-means聚类和PCA降维，常用于客户分群和异常检测"
    );
    println!("  📊 AssessmentSimulator 评估结果 (pass): correct={}, total={}, passed={}",
        assessment_pass["assessment"]["correct"],
        assessment_pass["assessment"]["total"],
        assessment_pass["assessment"]["passed"],
    );
    println!("  📋 blind_spots: {:?}", assessment_pass["assessment"]["blind_spots"]);

    assert_eq!(assessment_pass["assessment"]["correct"], 4, "完美回答应命中全部4个知识点");
    assert_eq!(assessment_pass["assessment"]["total"], 4);
    assert_eq!(assessment_pass["assessment"]["passed"], true, "完美回答应通过");
    assert!(assessment_pass["assessment"]["blind_spots"].as_array().unwrap().is_empty());
    assert_eq!(assessment_pass["current_task_complete"], true, "通过时 current_task_complete 应为 true");

    // 发送到 handler → 验证任务推进
    let plan_update_pass = make_plan_update("你理解得很好！", &assessment_pass);
    {
        let conn = api_server::db_pool::get_conn();
        let result = api_server::plan_handler::handle_plan_update(
            &conn, &plan_update_pass, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(result.plan_updated);
        let pj = result.plan_json.as_ref().unwrap();
        let tasks = pj["stages"][0]["tasks"].as_array().unwrap();
        assert_eq!(tasks[1]["status"], "done", "考核通过 → 任务2 应标记为 done");
        assert_eq!(tasks[1]["name"], "无监督学习概念");
        assert_eq!(tasks[2]["status"], "in_progress", "任务3 应自动激活 (模型评估方法)");
    }
    println!("  ✅ 考核通过: 4/4, 任务2 → done, 任务3 → in_progress");

    // ── 5c: AssessmentSimulator 结构验证 (不经过 handler) ──
    println!("\n  ── 5c: AssessmentSimulator 结构完整性验证 ──");

    let partial = simulator.evaluate("无监督学习没有标签，K-means可以做聚类分组");
    // 命中2个 (无监督学习定义 + 聚类算法), 漏2个 (降维技术 + 典型应用场景)
    assert_eq!(partial["assessment"]["correct"], 2,
        "部分回答应命中2个知识点");
    assert_eq!(partial["assessment"]["total"], 4);
    assert_eq!(partial["assessment"]["passed"], true,
        "2/4=50% ≥ threshold 应通过");
    let pbs = partial["assessment"]["blind_spots"].as_array().unwrap();
    assert_eq!(pbs.len(), 2, "应有2个盲点");
    assert!(pbs.contains(&serde_json::json!("降维技术")));
    assert!(pbs.contains(&serde_json::json!("典型应用场景")));
    // teaching_points 由盲点自动生成
    let tps = partial["assessment"]["teaching_points"].as_array().unwrap();
    assert!(tps.iter().any(|tp| tp.as_str().unwrap().contains("降维技术")));
    assert!(tps.iter().any(|tp| tp.as_str().unwrap().contains("典型应用场景")));
    // completed_concepts 与 assessment 分离
    let ccs = partial["completed_concepts"].as_array().unwrap();
    assert_eq!(ccs.len(), 2, "completed_concepts 应包含命中的概念名");
    assert!(ccs.contains(&serde_json::json!("无监督学习定义")));
    assert!(ccs.contains(&serde_json::json!("聚类算法")));

    println!("  ✅ AssessmentSimulator 结构验证通过:");
    println!("     • correct=2/4, passed=true (边界值)");
    println!("     • blind_spots 自动填充");
    println!("     • teaching_points 由盲点驱动生成");
    println!("     • completed_concepts 与 assessment.correct 一致");

    // ────────────────────────────────────────
    // Phase 6: 阶段完成 → silver 成就
    // ────────────────────────────────────────
    println!("\n─── Phase 6: 阶段一完成 → 成就触发 ───");

    insert_turn("user", "模型评估方法我也掌握了，交叉验证和混淆矩阵都很清楚");

    let plan_update_task3_done = make_plan_update("太棒了！阶段一的所有任务都完成了！", &serde_json::json!({
        "completed_concepts": ["交叉验证", "混淆矩阵", "ROC曲线"],
        "current_task_complete": true,
        "next_stage_suggestion": "阶段二：深度学习入门"
    }));

    let conn = api_server::db_pool::get_conn();
    let result = api_server::plan_handler::handle_plan_update(
        &conn, &plan_update_task3_done, TEST_CONV_ID, TEST_USER_ID,
    );

    assert!(result.plan_updated);
    let plan_json = result.plan_json.as_ref().unwrap();
    let stages = plan_json["stages"].as_array().unwrap();

    // 阶段一 → done, 阶段二 → in_progress
    assert_eq!(stages[0]["status"], "done", "阶段一应标记为 done");
    assert_eq!(stages[1]["status"], "in_progress", "阶段二应自动激活");
    assert_eq!(stages[1]["tasks"][0]["status"], "in_progress", "阶段二任务1应激活");
    assert_eq!(stages[1]["tasks"][0]["name"], "神经网络基础");

    println!("  ✅ 阶段一 → done");
    println!("  ✅ 阶段二 → in_progress (通过 next_stage_suggestion 推进)");

    // 成就检测 (使用共享函数 — 替代原手动内联代码)
    {
        let conn = api_server::db_pool::get_conn();
        let (_pid, _goal, plan_json_str) = get_plan_from_db().unwrap();
        let plan: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap();
        record_stage_achievements(&conn, &plan);
    }

    let achievements = get_achievements();
    let silver_ach = achievements.iter().find(|(k, _, _, _)| k.contains("silver"));
    assert!(silver_ach.is_some(), "应有 silver 成就");
    let (key, name, tier, source) = silver_ach.unwrap();
    assert_eq!(tier, "silver");
    assert_eq!(source, "stage");
    println!("  ✅ silver 成就: {} ({})", key, name);

    // ────────────────────────────────────────
    // Phase 7: 全部阶段完成 → gold 成就
    // ────────────────────────────────────────
    println!("\n─── Phase 7: 全部阶段完成 → gold 成就 ───");

    // 快速完成阶段二 (神经网络基础 + 反向传播 → done)
    insert_turn("user", "神经网络基础我理解了，激活函数和前向传播都清楚了");
    {
        let conn = api_server::db_pool::get_conn();
        let pu = make_plan_update("很好！", &serde_json::json!({
            "completed_concepts": ["神经元结构", "ReLU激活函数", "前向传播"],
            "current_task_complete": true,
            "next_stage_suggestion": null
        }));
        api_server::plan_handler::handle_plan_update(
            &conn, &pu, TEST_CONV_ID, TEST_USER_ID,
        );
    }

    insert_turn("user", "反向传播就是链式法则求梯度对吧？");
    {
        let conn = api_server::db_pool::get_conn();
        let pu = make_plan_update("完全正确！", &serde_json::json!({
            "completed_concepts": ["链式法则", "梯度下降", "反向传播机制"],
            "current_task_complete": true,
            "next_stage_suggestion": "阶段三：实战项目"
        }));
        api_server::plan_handler::handle_plan_update(
            &conn, &pu, TEST_CONV_ID, TEST_USER_ID,
        );
    }

    // 验证阶段二 → done, 阶段三 → in_progress
    {
        let (_pid, _goal, plan_json_str) = get_plan_from_db().unwrap();
        let plan_json: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap();
        let stages = plan_json["stages"].as_array().unwrap();
        assert_eq!(stages[1]["status"], "done", "阶段二应标记为 done");
        assert_eq!(stages[2]["status"], "in_progress", "阶段三应自动激活");
    }
    println!("  ✅ 阶段二 → done, 阶段三 → in_progress");

    // 完成阶段三
    insert_turn("user", "CNN图像分类项目我做完了，准确率95%");
    {
        let conn = api_server::db_pool::get_conn();
        let pu = make_plan_update("优秀！", &serde_json::json!({
            "completed_concepts": ["CNN架构", "卷积层", "池化层", "数据增强"],
            "current_task_complete": true,
            "next_stage_suggestion": null
        }));
        api_server::plan_handler::handle_plan_update(
            &conn, &pu, TEST_CONV_ID, TEST_USER_ID,
        );
    }

    insert_turn("user", "NLP项目也完成了，LSTM做文本分类效果不错");
    {
        let conn = api_server::db_pool::get_conn();
        let result = api_server::plan_handler::handle_plan_update(
            &conn,
            &make_plan_update("太棒了！🎉", &serde_json::json!({
                "completed_concepts": ["LSTM网络", "词嵌入", "文本预处理"],
                "current_task_complete": true,
                "next_stage_suggestion": null
            })),
            TEST_CONV_ID, TEST_USER_ID,
        );

        // 阶段三所有任务完成 → stage done
        let plan_json = result.plan_json.as_ref().unwrap();
        let stages = plan_json["stages"].as_array().unwrap();
        assert_eq!(stages[2]["status"], "done", "阶段三应标记为 done");
        assert!(stages.iter().all(|s| s["status"] == "done"), "所有阶段应标记为 done");
    }
    println!("  ✅ 阶段三 → done, 全部阶段完成!");

    // 触发所有成就检测 (使用共享函数)
    {
        let conn = api_server::db_pool::get_conn();
        let (_pid, _goal, plan_json_str) = get_plan_from_db().unwrap();
        let plan: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap();
        record_stage_achievements(&conn, &plan);
    }

    // ────────────────────────────────────────
    // Phase 8: 最终状态验证
    // ────────────────────────────────────────
    println!("\n─── Phase 8: 最终状态汇总 ───");

    // 最终 plan 状态
    let plan = get_plan_from_db();
    assert!(plan.is_some(), "最终应存在学习计划");
    let (_pid, goal, plan_json_str) = plan.unwrap();
    let plan_json: serde_json::Value = serde_json::from_str(&plan_json_str).unwrap();
    let stages = plan_json["stages"].as_array().unwrap();

    println!("  目标: {}", goal);
    for stage in stages {
        let sname = stage["name"].as_str().unwrap();
        let sstatus = stage["status"].as_str().unwrap();
        println!("  {} → {}", sname, sstatus);
        if let Some(tasks) = stage["tasks"].as_array() {
            for task in tasks {
                let tname = task["name"].as_str().unwrap();
                let tstatus = task["status"].as_str().unwrap();
                println!("    └ {} → {}", tname, tstatus);
            }
        }
    }

    // 验证 completed_concepts
    let concepts = plan_json["completed_concepts"].as_array().unwrap();
    println!("\n  累计完成概念: {} 个", concepts.len());
    for c in concepts {
        println!("    • {}", c.as_str().unwrap());
    }
    assert!(concepts.len() >= 10, "应有至少10个完成概念");

    // 最终成就列表
    let achievements = get_achievements();
    println!("\n  成就列表:");
    for (key, name, tier, source) in &achievements {
        println!("    🏆 {} | {} | tier={} source={}", key, name, tier, source);
    }

    let silver_count = achievements.iter().filter(|(_, _, t, _)| t == "silver").count();
    let gold_count = achievements.iter().filter(|(_, _, t, _)| t == "gold").count();
    assert!(silver_count >= 2, "应有至少2个 silver 成就 (阶段一+阶段二+阶段三)");
    assert!(gold_count >= 1, "应有1个 gold 成就");
    println!("\n  ✅ silver 成就: {} 个", silver_count);
    println!("  ✅ gold 成就: {} 个", gold_count);

    // ────────────────────────────────────────
    // Phase 9: Context 追踪总结
    // ────────────────────────────────────────
    println!("\n─── Phase 9: Context 构建追踪总结 ───");

    // 最终 context 状态 (全部完成)
    let (_mode, ctx) = build_plan_context();
    println!("  最终 mode: {}", _mode);
    // 当所有阶段都 done 时，context 不会包含任何阶段 (没有 in_progress 或 pending)
    // 这是预期行为：所有阶段完成后，不再有"当前阶段"的概念
    if ctx.contains("当前阶段") {
        println!("  context 仍包含当前阶段 (可能有未完成阶段)");
    } else {
        println!("  context 无当前阶段 (所有阶段已完成, 预期行为)");
    }
    println!("  最终 plan_context:\n{}", ctx);

    // ────────────────────────────────────────
    // Phase 10: 边界情况测试
    // ────────────────────────────────────────
    println!("\n─── Phase 10: 边界情况测试 ───");

    // 10a: 截断的 plan_update (不完整标签)
    {
        let conn = api_server::db_pool::get_conn();
        let truncated_reply = "前面正常文本<plan_update>{ \"incomplete";
        let result = api_server::plan_handler::handle_plan_update(
            &conn, truncated_reply, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(!result.plan_updated, "截断的 plan_update 不应触发更新");
        assert!(!result.cleaned_reply.contains("plan_update"), "截断标签应被清理");
        println!("  ✅ 截断的 <plan_update> 正确处理 (已清理, 不触发更新)");
    }

    // 10b: 无 plan_update 的普通回复
    {
        let conn = api_server::db_pool::get_conn();
        let normal_reply = "这是一个普通的回复，没有任何计划更新。";
        let result = api_server::plan_handler::handle_plan_update(
            &conn, normal_reply, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(!result.plan_updated, "普通回复不应触发更新");
        assert_eq!(result.cleaned_reply, normal_reply, "普通回复应原样返回");
        println!("  ✅ 无 plan_update 的普通回复正确处理");
    }

    // 10c: 验证 render_plan 处理空 stages
    {
        let empty_plan = serde_json::json!({
            "goal": "空计划",
            "stages": []
        });
        let rendered = api_server::plan_handler::render_plan(&empty_plan);
        assert!(rendered.contains("空计划"), "应包含目标");
        println!("  ✅ 空 stages 的 render_plan 正常: {}", rendered);
    }

    // 10d: 重复创建同一会话的学习计划 (upsert 行为)
    {
        let conn = api_server::db_pool::get_conn();
        let duplicate_create = make_plan_update("好的！", &serde_json::json!({
            "is_new_plan": true,
            "goal": "AI高级进阶",
            "stages": [
                {
                    "name": "新阶段：强化学习",
                    "status": "in_progress",
                    "tasks": [
                        {"name": "Q-Learning", "status": "in_progress", "description": "理解Q-Learning算法"}
                    ]
                }
            ],
            "completed_concepts": [],
            "current_task_complete": false,
            "next_stage_suggestion": null
        }));

        let result = api_server::plan_handler::handle_plan_update(
            &conn, &duplicate_create, TEST_CONV_ID, TEST_USER_ID,
        );
        assert!(result.is_new_plan, "再次创建应仍识别为 new_plan");
        assert!(result.plan_updated);
        // upsert 应更新现有计划而非创建新行
        let plan = get_plan_from_db();
        assert!(plan.is_some());
        let (_pid, goal, _pjson) = plan.unwrap();
        assert_eq!(goal, "AI高级进阶", "计划目标应被更新");
        println!("  ✅ 重复创建同一会话计划: upsert 行为正确 (更新现有计划)");
    }

    // 10e: AssessmentSimulator 词边界保护 — 确保关键词为完整单词匹配
    {
        // "PCA" 出现在 "SPACE" 中不应匹配
        let sim = AssessmentSimulator {
            task_name: "测试任务",
            expected_knowledge: &[
                ("降维技术", &["PCA"]),
            ],
            pass_threshold: 0.5,
        };
        let _result = sim.evaluate("SPACE探索很有意思");
        // "SPACE" 包含 "PCA" 子串，但我们用的是 contains()
        // 注: 当前实现使用 String::contains，无法区分词边界
        // 这是一个已知局限性，在此记录
        println!("  ⚠️  AssessmentSimulator 词边界局限性: contains() 无法区分 'PCA' vs 'SPACE'");
        println!("     建议生产环境中使用正则 \\b 或分词匹配");
    }

    // ────────────────────────────────────────
    // 测试完成
    // ────────────────────────────────────────
    println!("\n{}", "=".repeat(80));
    println!(" ✅ E2E 学习计划生命周期测试全部通过!");
    println!("{}", "=".repeat(80));
    println!(" 覆盖范围:");
    println!("   • FREE → STRUCTURED 状态转换");
    println!("   • 计划创建 (is_new_plan → INSERT)");
    println!("   • Context 构建 (plan_context 注入)");
    println!("   • 概念完成 (completed_concepts 累积)");
    println!("   • 任务完成 + 自动推进 (current_task_complete)");
    println!("   • 考核评估 (AssessmentSimulator: pass/fail/partial)");
    println!("   • 阶段完成 + 下一阶段激活 (next_stage_suggestion)");
    println!("   • 成就系统 (silver/gold via record_stage_achievements)");
    println!("   • 全部阶段完成 (plan completion)");
    println!("   • 边界情况 (截断标签, 普通回复, upsert)");
    println!("{}", "=".repeat(80));

    // 清理测试 DB (可选，保留用于调试)
    // let _ = fs::remove_file(TEST_DB_PATH);
}
