//! N5: FSRS 待复习队列
//!
//! 负责:
//!   1. 查询到期卡片 (due <= now, 按 due ASC, LIMIT 20)
//!   2. 提交复习结果后更新 FSRS 状态
//!   3. 管理 streak_days 签到逻辑
//!
//! ⚠️ 注意: 当前未使用 fsrs crate (如果不可用则手动计算)
//! TODO: 后续集成 fsrs crate 的 FSRS-5 算法

use shared_types::growth::AchievementContext;
use chrono::Utc;
use rusqlite::Connection;

/// 待复习的卡片 (用于 UI 展示)
#[derive(Debug, Clone, serde::Serialize)]
pub struct DueCard {
    pub id: String,
    pub front: String,
    pub back: String,
    pub domain: Option<String>,
    pub card_type: String,
    pub source_sentence: Option<String>,
    pub state: i32,
    pub reps: i32,
}

/// N5: 查询到期卡片
pub fn get_due_cards(conn: &Connection, user_id: &str, limit: i64) -> (Vec<DueCard>, i64) {
    let now = Utc::now().timestamp();

    let mut stmt = conn.prepare(
        "SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
                cm.state, cm.reps
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1
           AND cm.due <= ?2
         ORDER BY cm.due ASC
         LIMIT ?3"
    ).unwrap();

    let cards: Vec<DueCard> = stmt.query_map(
        rusqlite::params![user_id, now, limit],
        |row| Ok(DueCard {
            id: row.get(0)?,
            front: row.get(1)?,
            back: row.get(2)?,
            domain: row.get(3)?,
            card_type: row.get(4)?,
            source_sentence: row.get(5)?,
            state: row.get(6)?,
            reps: row.get(7)?,
        })
    ).unwrap().filter_map(|r| r.ok()).collect();

    let total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.due <= ?2",
        rusqlite::params![user_id, now],
        |row| row.get(0),
    ).unwrap_or(0);

    (cards, total)
}

/// 更新 streak_days
fn update_streak(conn: &Connection, user_id: &str) -> Result<u32, String> {
    let today = Utc::now().date_naive();
    let today_str = today.format("%Y-%m-%d").to_string();

    let last_active: Option<String> = conn.query_row(
        "SELECT last_active_date FROM users WHERE id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).ok();

    let new_streak = match last_active {
        Some(date_str) if date_str == today_str => {
            // 今天已经复习过了, 不变
            conn.query_row(
                "SELECT streak_days FROM users WHERE id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            ).unwrap_or(0)
        }
        Some(date_str) => {
            // 检查是否是昨天
            let yesterday = (today - chrono::Duration::days(1)).format("%Y-%m-%d").to_string();
            if date_str == yesterday {
                // 连续签到
                let streak: u32 = conn.query_row(
                    "SELECT streak_days + 1 FROM users WHERE id = ?1",
                    rusqlite::params![user_id],
                    |row| row.get(0),
                ).unwrap_or(1);
                streak
            } else {
                // 断签，重置为 1
                1
            }
        }
        None => 1, // 首次签到
    };

    conn.execute(
        "UPDATE users SET streak_days = ?1, last_active_date = ?2 WHERE id = ?3",
        rusqlite::params![new_streak, today_str, user_id],
    ).map_err(|e| format!("Update streak: {}", e))?;

    Ok(new_streak)
}

/// N6c: 提交复习结果
pub fn submit_review(
    conn: &Connection,
    card_id: &str,
    rating: i32,
    verification_type: &str,
    verification_result: &str,
    user_id: &str,
    details_json: Option<&str>,
) -> Result<AchievementContext, String> {
    let now = Utc::now().timestamp();
    let log_id = format!("rev_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());

    // 1. 写入 review_log
    if let Some(details) = details_json {
        conn.execute(
            "INSERT INTO review_log (id, card_id, rating, verification_type, verification_result, details_json, reviewed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![log_id, card_id, rating, verification_type, verification_result, details, now],
        ).map_err(|e| format!("Review log insert: {}", e))?;
    } else {
        conn.execute(
            "INSERT INTO review_log (id, card_id, rating, verification_type, verification_result, reviewed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![log_id, card_id, rating, verification_type, verification_result, now],
        ).map_err(|e| format!("Review log insert: {}", e))?;
    }

    // 2. FSRS 状态更新 (当前为简化版)
    let passed = verification_result == "pass";
    let new_rating = if passed { 3i32 } else { 1i32 };
    let new_state = compute_next_state(conn, card_id, new_rating, passed);

    conn.execute(
        "UPDATE card_memory SET state = ?1, due = ?2, last_review = ?3,
         reps = reps + 1, lapses = lapses + ?4
         WHERE card_id = ?5",
        rusqlite::params![new_state.0, new_state.1, now, if passed { 0 } else { 1 }, card_id],
    ).map_err(|e| format!("Card memory update: {}", e))?;

    // 3. 更新 streak
    let streak_days = update_streak(conn, user_id)?;

    // 4. 聚合成就上下文
    let total_cards: u32 = conn.query_row(
        "SELECT COUNT(*) FROM cards WHERE user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let total_reviews: u32 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    let domains_covered: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT domain) FROM cards WHERE user_id = ?1 AND domain IS NOT NULL",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    Ok(AchievementContext {
        user_id: user_id.to_string(),
        total_cards,
        total_reviews,
        streak_days,
        domains_covered,
    })
}

/// 简化版 FSRS 状态机:
/// New →(first review)→ Learning →(rating>=3)→ Review
/// Review →(rating<=1)→ Relearning →(rating>=3)→ Review
/// 返回 (new_state, next_due_timestamp)
fn compute_next_state(conn: &Connection, card_id: &str, _rating: i32, passed: bool) -> (i32, i64) {
    let current_state: i32 = conn.query_row(
        "SELECT state FROM card_memory WHERE card_id = ?1",
        rusqlite::params![card_id], |row| row.get(0),
    ).unwrap_or(0);

    let now = Utc::now().timestamp();
    let intervals = [60, 300, 900, 3600, 14400, 43200, 86400, 172800, 345600, 604800];
    let reps: i32 = conn.query_row(
        "SELECT reps FROM card_memory WHERE card_id = ?1",
        rusqlite::params![card_id], |row| row.get(0),
    ).unwrap_or(0);

    match (current_state, passed) {
        // New → 首次复习
        (0, true) => (1, now + 1800),               // → Learning, 30min
        (0, false) => (1, now + 120),                // → Learning, 2min
        // Learning
        (1, true) => (2, now + interval(reps, &intervals)), // → Review
        (1, false) => (1, now + 120),                // stay Learning, 2min
        // Review
        (2, true) => (2, now + interval(reps + 1, &intervals)), // stay Review
        (2, false) => (3, now + 600),                // → Relearning, 10min
        // Relearning
        (3, true) => (2, now + interval(reps, &intervals)),     // → Review
        (3, false) => (3, now + 300),                // stay Relearning, 5min
        _ => (current_state, now + 3600),
    }
}

fn interval(reps: i32, intervals: &[i64]) -> i64 {
    let idx = reps as usize;
    if idx < intervals.len() { intervals[idx] } else { intervals[intervals.len() - 1] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_full_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT, streak_days INTEGER DEFAULT 0, last_active_date TEXT, created_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, turn_count INTEGER DEFAULT 0, started_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS conversation_turns (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, domain TEXT, card_type TEXT NOT NULL, front TEXT NOT NULL, back TEXT NOT NULL, source_sentence TEXT, created_at INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS card_memory (card_id TEXT PRIMARY KEY, state INTEGER DEFAULT 0, difficulty REAL DEFAULT 5.0, stability REAL DEFAULT 0.0, due INTEGER DEFAULT 0, last_review INTEGER, reps INTEGER DEFAULT 0, lapses INTEGER DEFAULT 0);
             CREATE TABLE IF NOT EXISTS review_log (id TEXT PRIMARY KEY, card_id TEXT NOT NULL, rating INTEGER NOT NULL, verification_type TEXT NOT NULL, verification_result TEXT NOT NULL, reviewed_at INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS achievements (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, achievement_key TEXT NOT NULL, name TEXT NOT NULL, icon TEXT NOT NULL, unlocked_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS skipped_concepts (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, front TEXT NOT NULL, domain TEXT, source_text TEXT, skipped_at INTEGER NOT NULL);"
        ).unwrap();
        // 插入测试用户
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES ('e2e_user', 'e2e_test', '2026-01-01')",
            [],
        ).unwrap();
        conn
    }

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE cards (id TEXT PRIMARY KEY, user_id TEXT, domain TEXT, card_type TEXT, front TEXT, back TEXT, source_sentence TEXT, created_at INTEGER);
             CREATE TABLE card_memory (card_id TEXT PRIMARY KEY, state INTEGER DEFAULT 0, difficulty REAL DEFAULT 5.0, stability REAL DEFAULT 0.0, due INTEGER DEFAULT 0, last_review INTEGER, reps INTEGER DEFAULT 0, lapses INTEGER DEFAULT 0);
             CREATE TABLE review_log (id TEXT PRIMARY KEY, card_id TEXT, rating INTEGER, verification_type TEXT, verification_result TEXT, reviewed_at INTEGER);
             CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT, streak_days INTEGER DEFAULT 0, last_active_date TEXT, created_at TEXT);"
        ).unwrap();
        conn
    }

    #[test]
    fn test_get_due_cards_empty() {
        let conn = setup_db();
        let (cards, total) = get_due_cards(&conn, "u1", 20);
        assert!(cards.is_empty());
        assert_eq!(total, 0);
    }

    #[test]
    fn test_submit_review_updates_streak() {
        let conn = setup_db();
        conn.execute("INSERT INTO users (id, username, created_at) VALUES ('u1', 'test', '2026-01-01')", []).unwrap();
        conn.execute("INSERT INTO cards (id, user_id, front, back, card_type, created_at) VALUES ('c1', 'u1', 'test', 'test', 'concept', 0)", []).unwrap();
        conn.execute("INSERT INTO card_memory (card_id, due) VALUES ('c1', 0)", []).unwrap();

        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "u1").unwrap();
        assert_eq!(ctx.streak_days, 1);
        assert_eq!(ctx.total_reviews, 1);
    }

    // ── E2E 全流程: 制卡 → FSRS → 复习 → 状态转移 ──

    fn insert_card(conn: &Connection, id: &str, user_id: &str, front: &str, back: &str) {
        conn.execute(
            "INSERT INTO cards (id, user_id, front, back, card_type, created_at) VALUES (?1, ?2, ?3, ?4, 'concept', 0)",
            rusqlite::params![id, user_id, front, back],
        ).unwrap();
        conn.execute(
            "INSERT INTO card_memory (card_id, state, due) VALUES (?1, 0, 0)",
            rusqlite::params![id],
        ).unwrap();
    }

    fn insert_card_old(conn: &Connection, id: &str, user_id: &str, front: &str, back: &str) {
        conn.execute(
            "INSERT INTO cards (id, user_id, front, back, card_type, created_at) VALUES (?1, ?2, ?3, ?4, 'concept', 86400)",
            rusqlite::params![id, user_id, front, back],
        ).unwrap();
        conn.execute(
            "INSERT INTO card_memory (card_id, state, due) VALUES (?1, 2, 0)",  // old Review state
            rusqlite::params![id],
        ).unwrap();
    }

    #[test]
    fn e2e_new_card_to_learning() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // 1. 到期查询
        let (due, total) = get_due_cards(&conn, "e2e_user", 20);
        assert_eq!(due.len(), 1, "新卡片应到期");
        assert_eq!(total, 1);
        assert_eq!(due[0].state, 0, "New 状态");

        // 2. 提交复习 (pass) → New → Learning
        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        assert_eq!(ctx.total_reviews, 1, "第1次复习");

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 1, "New + pass → Learning");
    }

    #[test]
    fn e2e_learning_to_review() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();

        // 模拟 due 已到
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();

        // Learning + pass → Review
        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        assert_eq!(ctx.total_reviews, 2);

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 2, "Learning + pass → Review");
    }

    #[test]
    fn e2e_review_to_relearning() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning → Review
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();

        // Review + fail → Relearning
        submit_review(&conn, "c1", 1, "spelling", "fail", "e2e_user").unwrap();

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 3, "Review + fail → Relearning");
    }

    #[test]
    fn e2e_relearning_to_review() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning → Review → Relearning
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 1, "spelling", "fail", "e2e_user").unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c1'", []).unwrap();

        // Relearning + pass → Review
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user").unwrap();

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 2, "Relearning + pass → Review");
    }

    #[test]
    fn e2e_streak_continuation() {
        let conn = setup_full_db();

        // 第1天: 复习 → streak=1
        insert_card(&conn, "c2", "e2e_user", "卡B", "说明B");
        submit_review(&conn, "c2", 3, "spelling", "pass", "e2e_user").unwrap();
        let s1: i32 = conn.query_row(
            "SELECT streak_days FROM users WHERE id='e2e_user'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(s1, 1, "第1天 streak=1");

        // 第2天 (模拟): 复习 → streak=2
        conn.execute("UPDATE users SET last_active_date=?1", rusqlite::params![{
            let yesterday = chrono::Utc::now().date_naive() - chrono::Duration::days(1);
            yesterday.format("%Y-%m-%d").to_string()
        }]).unwrap();
        insert_card(&conn, "c3", "e2e_user", "卡C", "说明C");
        submit_review(&conn, "c3", 3, "spelling", "pass", "e2e_user").unwrap();
        let s2: i32 = conn.query_row(
            "SELECT streak_days FROM users WHERE id='e2e_user'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(s2, 2, "第2天 streak=2");
    }

    #[test]
    fn e2e_streak_break() {
        let conn = setup_full_db();

        // 设上次活跃为 3 天前
        conn.execute("UPDATE users SET last_active_date=?1", rusqlite::params![{
            let three_days_ago = chrono::Utc::now().date_naive() - chrono::Duration::days(3);
            three_days_ago.format("%Y-%m-%d").to_string()
        }]).unwrap();

        insert_card(&conn, "c4", "e2e_user", "卡D", "说明D");
        submit_review(&conn, "c4", 3, "spelling", "pass", "e2e_user").unwrap();

        let streak: i32 = conn.query_row(
            "SELECT streak_days FROM users WHERE id='e2e_user'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(streak, 1, "断签后重置为 1");
    }

    #[test]
    fn e2e_due_queue_ordering() {
        let conn = setup_full_db();
        insert_card(&conn, "ca", "e2e_user", "较早到期", "");
        insert_card(&conn, "cb", "e2e_user", "较晚到期", "");
        insert_card_old(&conn, "cc", "e2e_user", "旧卡片", "");
        conn.execute("UPDATE card_memory SET due=100 WHERE card_id='ca'", []).unwrap();
        conn.execute("UPDATE card_memory SET due=200 WHERE card_id='cb'", []).unwrap();
        conn.execute("UPDATE card_memory SET due=86400*2 WHERE card_id='cc'", []).unwrap();

        let (due, _) = get_due_cards(&conn, "e2e_user", 20);
        assert!(due.len() >= 2, "至少 2 张到期 (ca=100, cb=200)");
        // 按 due ASC
        for w in due.windows(2) {
            let d1: i64 = conn.query_row(
                "SELECT due FROM card_memory WHERE card_id=?1", rusqlite::params![w[0].id], |r| r.get(0)
            ).unwrap();
            let d2: i64 = conn.query_row(
                "SELECT due FROM card_memory WHERE card_id=?1", rusqlite::params![w[1].id], |r| r.get(0)
            ).unwrap();
            assert!(d1 <= d2, "到期队列应按 due 升序");
        }
    }

    #[test]
    fn e2e_limit_20_cards() {
        let conn = setup_full_db();
        for i in 0..30 {
            let id = format!("c_{}", i);
            insert_card(&conn, &id, "e2e_user", &format!("卡{}", i), "");
        }
        let (due, total) = get_due_cards(&conn, "e2e_user", 20);
        assert_eq!(due.len(), 20, "LIMIT 20");
        assert_eq!(total, 30, "total 报告全部数量");
    }

    #[test]
    fn e2e_lapses_increment_on_fail() {
        let conn = setup_full_db();
        insert_card(&conn, "c_lapse", "e2e_user", "遗忘测试", "");

        // fail
        submit_review(&conn, "c_lapse", 1, "spelling", "fail", "e2e_user").unwrap();
        let lapses: i32 = conn.query_row(
            "SELECT lapses FROM card_memory WHERE card_id='c_lapse'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(lapses, 1, "fail → lapses+1");

        // pass
        conn.execute("UPDATE card_memory SET due=0 WHERE card_id='c_lapse'", []).unwrap();
        submit_review(&conn, "c_lapse", 3, "spelling", "pass", "e2e_user").unwrap();
        let lapses2: i32 = conn.query_row(
            "SELECT lapses FROM card_memory WHERE card_id='c_lapse'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(lapses2, 1, "pass → lapses 不变");
    }
}
