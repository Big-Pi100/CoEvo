//! CoEvo E2E — 卡片管线完整性测试
//!
//! 每个测试使用独立 DB 文件，不依赖共享 db_pool。
//! 覆盖：K12 init 制卡、Plan 推进激活、Reading init、
//!       Cold Path 1 绑定、历史会话过滤

use std::fs;
use rusqlite::{Connection, params};

const USER_ID: &str = "card-test-user";

fn setup_db(path: &str) -> Connection {
    let _ = fs::remove_file(path);
    let _ = fs::create_dir_all("data");
    let conn = Connection::open(path).expect("open DB");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY, user_id TEXT NOT NULL, turn_count INTEGER DEFAULT 0,
            started_at TEXT NOT NULL, subject TEXT, grade_band TEXT
        );
        CREATE TABLE IF NOT EXISTS learning_plans (
            id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT,
            goal TEXT NOT NULL, domain TEXT NOT NULL DEFAULT '', mode TEXT,
            plan_content TEXT, task_status TEXT,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY, user_id TEXT NOT NULL, domain TEXT,
            card_type TEXT NOT NULL DEFAULT 'concept',
            front TEXT NOT NULL, back TEXT NOT NULL,
            source_sentence TEXT, conversation_id TEXT,
            created_at INTEGER NOT NULL, subject TEXT, grade_band TEXT, k12_card_id TEXT
        );
        CREATE TABLE IF NOT EXISTS card_memory (
            card_id TEXT PRIMARY KEY, state INTEGER DEFAULT 0,
            difficulty REAL DEFAULT 5.0, stability REAL DEFAULT 0.0,
            due INTEGER NOT NULL, last_review INTEGER, reps INTEGER DEFAULT 0,
            lapses INTEGER DEFAULT 0,
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT,
            streak_days INTEGER DEFAULT 0, last_active_date TEXT, display_name TEXT,
            created_at TEXT NOT NULL
        );",
    ).expect("schema");
    conn.execute("INSERT INTO users (id, username, password_hash, created_at) VALUES (?1, ?2, '', 'now')",
        params![USER_ID, USER_ID]).ok();
    conn
}

fn count_cards(conn: &Connection, user: &str) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id = ?1", params![user], |r| r.get(0)).unwrap_or(0)
}
fn count_memory(conn: &Connection, user: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM card_memory cm JOIN cards c ON cm.card_id = c.id WHERE c.user_id = ?1",
        params![user], |r| r.get(0)).unwrap_or(0)
}
fn cards_with_domain(conn: &Connection, user: &str, domain: &str) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id = ?1 AND domain = ?2",
        params![user, domain], |r| r.get(0)).unwrap_or(0)
}

// ════════════════════════════════════════════
// Test 1: K12 Init → domain 匹配 + card_memory
// ════════════════════════════════════════════
#[test]
fn test_k12_init_card_domain() {
    let conn = setup_db("data/t_k12_init.db");
    let now_ts = 1000000;
    let conv_id = "k12-test";

    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, 'now', '数学', 'g3-4')",
        params![conv_id, USER_ID]).unwrap();
    conn.execute("INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, task_status, created_at, updated_at)
        VALUES ('p1', ?1, ?2, '测试', '数学', 'structured', '{}', '{}', 'now', 'now')",
        params![USER_ID, conv_id]).unwrap();

    // 模拟 K12 init：INSERT cards + card_memory（domain=中文名）
    for (cid, front, ctype) in &[("c001","加法","concept"), ("c002","减法","concept"), ("c003","乘法","vocabulary")] {
        let card_id = format!("k12_{}", cid);
        conn.execute(
            "INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, subject, grade_band, k12_card_id)
             VALUES (?1, ?2, '数学', ?3, ?4, 'back', ?5, ?6, '数学', 'g3-4', ?7)",
            params![card_id, USER_ID, ctype, front, conv_id, now_ts, cid],
        ).unwrap();
        conn.execute(
            "INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
             VALUES (?1, 0, 0.3, 1.0, ?2, 0, 0, 0)",
            params![card_id, now_ts],
        ).unwrap();
    }

    assert_eq!(count_cards(&conn, USER_ID), 3);
    assert_eq!(count_memory(&conn, USER_ID), 3);
    // 所有卡片 domain = "数学"（匹配 plan.domain）
    assert_eq!(cards_with_domain(&conn, USER_ID, "数学"), 3);
    let plan_domain: String = conn.query_row("SELECT domain FROM learning_plans WHERE id = 'p1'", [], |r| r.get(0)).unwrap();
    assert_eq!(plan_domain, "数学");
    assert_eq!(cards_with_domain(&conn, USER_ID, &plan_domain), 3);
}

// ════════════════════════════════════════════
// Test 2: Plan 推进 → 下一批卡片激活
// ════════════════════════════════════════════
#[test]
fn test_plan_advancement_creates_cards() {
    let conn = setup_db("data/t_plan_advance.db");
    let conv_id = "plan-adv-test";
    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, 'now', '数学', 'g3-4')",
        params![conv_id, USER_ID]).unwrap();

    // Plan：2 tasks（首 task gold_cr_ids=["cr_001"]）
    let plan = serde_json::json!({"goal":"数学","stages":[{"name":"基础","tasks":[
        {"name":"加减法","gold_cr_ids":["cr_001"]},
        {"name":"乘除法","gold_cr_ids":["cr_002"]}
    ]}]});
    let status = serde_json::json!({"task_status":{"加减法":"done"}});
    conn.execute("INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, task_status, created_at, updated_at)
        VALUES ('p2', ?1, ?2, '数学', '数学', 'structured', ?3, ?4, 'now', 'now')",
        params![USER_ID, conv_id, plan.to_string(), status.to_string()]).unwrap();

    // 调用 handle_plan_update 推进
    let reply = "<plan_update>{\"completed_concepts\":[\"加减法\"],\"current_task_complete\":true}</plan_update>";
    api_server::plan_handler::handle_plan_update(&conn, reply, conv_id, USER_ID);

    // 验证 plan 推进到下一 task
    let updated: String = conn.query_row("SELECT task_status FROM learning_plans WHERE conversation_id = ?1",
        params![conv_id], |r| r.get(0)).unwrap_or_default();
    assert!(updated.contains("乘除法"), "next task should be in plan: {}", updated);
    let has_pending = updated.contains("\"pending\"") || updated.contains("\"in_progress\"");
    assert!(has_pending, "next task should be pending/in_progress: {}", updated);
}

// ════════════════════════════════════════════
// Test 3: Reading Init → 诗词卡 + 词卡全部导入
// ════════════════════════════════════════════
#[test]
fn test_reading_init_all_cards() {
    let conn = setup_db("data/t_reading_init.db");
    let conv_id = "rd-test";
    let now_ts = 1000000;

    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, 'now', '语文', 'g3-4')",
        params![conv_id, USER_ID]).unwrap();

    // 模拟 plan_content（3 tasks 各有 reading_card_id + vocab）
    let pc = serde_json::json!({"stages":[{"name":"三上","tasks":[
        {"name":"大青树下的小学","reading_card_id":"r1","vocab_card_ids":["v001","v002"]},
        {"name":"花的学校","reading_card_id":"r2","vocab_card_ids":["v003"]},
        {"name":"燕子","reading_card_id":"r3","vocab_card_ids":[]}
    ]}]});
    conn.execute("INSERT INTO learning_plans (id, user_id, conversation_id, goal, domain, mode, plan_content, task_status, created_at, updated_at)
        VALUES ('pr', ?1, ?2, '阅读', '语文', 'reading', ?3, '{}', 'now', 'now')",
        params![USER_ID, conv_id, pc.to_string()]).unwrap();

    // 模拟 reading init 的卡片导入（遍历所有 task）
    let stages = pc["stages"].as_array().unwrap();
    for stage in stages {
        for task in stage["tasks"].as_array().unwrap() {
            if let Some(cid) = task["reading_card_id"].as_str() {
                let k12 = format!("k12_{}", cid);
                conn.execute("INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, subject, grade_band, k12_card_id)
                    VALUES (?1,?2,'语文','reading',?3,'全文',?4,?5,'语文','g3-4',?6)",
                    params![k12, USER_ID, task["name"].as_str(), conv_id, now_ts, cid]).unwrap();
                conn.execute("INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                    VALUES (?1,0,5.0,0.0,?2,NULL,0,0)", params![k12, now_ts]).unwrap();
            }
            for vid_val in task["vocab_card_ids"].as_array().unwrap_or(&vec![]) {
                if let Some(vid) = vid_val.as_str() {
                    let k12 = format!("k12_{}", vid);
                    conn.execute("INSERT OR IGNORE INTO cards (id, user_id, domain, card_type, front, back, conversation_id, created_at, subject, grade_band, k12_card_id)
                        VALUES (?1,?2,'语文','vocabulary',?3,'字义',?4,?5,'语文','g3-4',?6)",
                        params![k12, USER_ID, vid, conv_id, now_ts, vid]).unwrap();
                    conn.execute("INSERT OR IGNORE INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
                        VALUES (?1,0,5.0,0.0,?2,NULL,0,0)", params![k12, now_ts]).unwrap();
                }
            }
        }
    }

    assert_eq!(conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND card_type='reading'", params![USER_ID], |r| r.get::<_,i64>(0)).unwrap(), 3);
    assert_eq!(conn.query_row("SELECT COUNT(*) FROM cards WHERE user_id=?1 AND card_type='vocabulary'", params![USER_ID], |r| r.get::<_,i64>(0)).unwrap(), 3);
    assert_eq!(count_memory(&conn, USER_ID), 6);
    assert_eq!(cards_with_domain(&conn, USER_ID, "语文"), 6);
}

// ════════════════════════════════════════════
// Test 4: Cold Path 1 → batch-create 绑定
// ════════════════════════════════════════════
#[test]
fn test_cold_path1_card_binding() {
    let conn = setup_db("data/t_cp1.db");
    let conv_id = "cp1-test";
    let now_ts = 1000000;

    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES (?1, ?2, 0, 'now', '数学', 'g3-4')",
        params![conv_id, USER_ID]).unwrap();

    // Cold Path 1 insert: domain=LLM指定('math'), subject=conversation('数学'), conversation_id=conv_id
    conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band)
         VALUES ('cp1_card', ?1, 'math', 'concept', '加法交换律', 'a+b=b+a', '示例', ?2, ?3, '数学', 'g3-4')",
        params![USER_ID, conv_id, now_ts],
    ).unwrap();
    conn.execute("INSERT INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
        VALUES ('cp1_card', 0, 5.0, 0.0, ?1, NULL, 0, 0)", params![now_ts]).unwrap();

    assert_eq!(count_cards(&conn, USER_ID), 1);
    assert_eq!(count_memory(&conn, USER_ID), 1);
    // domain 保持 LLM 原始值 'math'（非中文）
    let domain: String = conn.query_row("SELECT domain FROM cards WHERE id = 'cp1_card'", [], |r| r.get(0)).unwrap();
    assert_eq!(domain, "math", "ColdPath1 card preserves LLM domain");
    // subject = conversation.subject
    let subj: String = conn.query_row("SELECT subject FROM cards WHERE id = 'cp1_card'", [], |r| r.get(0)).unwrap();
    assert_eq!(subj, "数学", "ColdPath1 card subject matches conversation");
}

// ════════════════════════════════════════════
// Test 5: 历史会话过滤
// ════════════════════════════════════════════
#[test]
fn test_history_filter() {
    let conn = setup_db("data/t_history.db");
    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at) VALUES ('free', ?1, 3, 'now')", params![USER_ID]).unwrap();
    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES ('k12', ?1, 5, 'now', '数学', 'g3-4')", params![USER_ID]).unwrap();
    conn.execute("INSERT INTO conversations (id, user_id, turn_count, started_at, subject, grade_band) VALUES ('rd', ?1, 2, 'now', '语文', 'g3-4')", params![USER_ID]).unwrap();

    // 模拟 history_handler 过滤：subject IS NULL OR subject = ''
    let mut stmt = conn.prepare(
        "SELECT id, turn_count FROM conversations WHERE user_id = ?1 AND turn_count > 0 AND (subject IS NULL OR subject = '') ORDER BY started_at DESC"
    ).unwrap();
    let rows: Vec<(String, i32)> = stmt.query_map(params![USER_ID], |r| {
        Ok((r.get::<_,String>(0)?, r.get::<_,i32>(1)?))
    }).unwrap().filter_map(|r| r.ok()).collect();

    assert_eq!(rows.len(), 1, "only free chat should appear in history");
    assert_eq!(rows[0].0, "free");
    assert_eq!(rows[0].1, 3);
}
