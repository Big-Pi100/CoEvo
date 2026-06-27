//! N5: FSRS 待复习队列
//!
//! 负责:
//!   1. 查询到期卡片 (due <= now, 按 due ASC, LIMIT 20)
//!   2. 提交复习结果后更新 FSRS-5 状态
//!   3. 管理 streak_days 签到逻辑
//!
//! 调度核心: crate::fsrs5 — 自实现 FSRS-5 算法 (避免 fsrs crate 与 rusqlite bundled 冲突)

use shared_types::growth::AchievementContext;
use chrono::Utc;
use rusqlite::Connection;
use crate::fsrs5::{self, FsrsMemory, Rating};
use serde_json;

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
    pub lapses: i32,
    pub difficulty: f64,
    pub created_at: i64,
    pub due: i64,
    #[serde(rename = "last_reviewed_at")]
    pub last_review: Option<i64>,
    pub last_review_quality: Option<i32>,
    pub conversation_id: Option<String>,
}

/// N5: 查询到期卡片（按 task 级过滤，仅返回 in_progress/done 任务的卡片）
pub fn get_due_cards(conn: &Connection, user_id: &str, limit: i64, offset: i64, conv_id: Option<&str>, language: Option<&str>) -> (Vec<DueCard>, i64) {
    let now = Utc::now().timestamp();
    tracing::info!("[CP1] get_due_cards: user_id={}, conv_id={:?}, language={:?}, limit={}, offset={}",
        user_id, conv_id, language, limit, offset);

    // 语言 tab 独立处理：查 prebuilt_cards 词库（含全部预置词汇），LEFT JOIN user_cards 获取 FSRS 状态
    if let Some(lang) = language {
        let subj = match lang {
            "chinese" => "chinese",
            _ => "english",
        };
        let sql = format!(
            "SELECT pc.id, pc.front, COALESCE(plc.pronunciation, '') as back,
                    pc.subject as domain, pc.card_type, NULL as source_sentence,
                    COALESCE(cm.state, 0), COALESCE(cm.reps, 0), COALESCE(cm.lapses, 0), 0,
                    COALESCE(cm.difficulty, 5.0), COALESCE(cm.due, 0), cm.last_review,
                    NULL, NULL,
                    plc.definitions, plc.pronunciation, plc.related_phrases, plc.pos,
                    NULL,NULL,NULL,NULL,NULL,  -- usc
                    NULL,NULL,NULL,NULL,       -- ulc
                    NULL,NULL,NULL,NULL,       -- ulf
                    NULL,NULL,NULL,NULL        -- uhc
             FROM prebuilt_cards pc
             JOIN prebuilt_language_cards plc ON pc.id = plc.id
             JOIN user_cards uc ON uc.prebuilt_card_id = pc.id AND uc.user_id = ?1
             JOIN card_memory cm ON cm.user_card_id = uc.id
             WHERE pc.subject = ?2 AND pc.card_type = 'vocabulary'
               AND cm.status = 'active'
               AND cm.due <= ?3
             ORDER BY CASE WHEN cm.state = 0 THEN 1 ELSE 0 END, cm.due ASC
             LIMIT ?4 OFFSET ?5",
        );
        tracing::info!("[CP1] get_due_cards language SQL: {}", sql);

        let mut stmt = conn.prepare(&sql).unwrap();
        let cards: Vec<DueCard> = stmt.query_map(
            rusqlite::params![user_id, subj, now, limit, offset],
            |row| {
                let mut card = DueCard {
                    id: row.get(0)?,
                    front: row.get(1)?,
                    back: row.get(2)?,
                    domain: row.get(3)?,
                    card_type: row.get(4)?,
                    source_sentence: row.get(5)?,
                    state: row.get(6)?,
                    reps: row.get(7)?,
                    lapses: row.get(8)?,
                    created_at: row.get(9)?,
                    difficulty: row.get(10)?,
                    due: row.get(11)?,
                    last_review: row.get(12)?,
                    last_review_quality: row.get(13)?,
                    conversation_id: row.get(14)?,
                };
                // 词汇卡：构造 JSON back
                if card.card_type == "vocabulary" {
                    let defs_str: Option<String> = row.get(15).ok().unwrap_or_default();
                    let pronunciation: Option<String> = row.get(16).ok().unwrap_or_default();
                    let related_phrases: Option<String> = row.get(17).ok().unwrap_or_default();
                    let pos: Option<String> = row.get(18).ok().unwrap_or_default();
                    let defs_val: serde_json::Value = defs_str.as_deref()
                        .and_then(|s| serde_json::from_str(s).ok())
                        .unwrap_or(serde_json::Value::Null);
                    let json_back = if subj == "chinese" {
                        serde_json::json!({
                            "character": card.front,
                            "pinyin": pronunciation.unwrap_or_default(),
                            "definitions": defs_val,
                            "common_words": related_phrases.unwrap_or_default(),
                        })
                    } else {
                        serde_json::json!({
                            "word": card.front,
                            "phonetic": pronunciation.unwrap_or_default(),
                            "pos": pos.unwrap_or_default(),
                            "definitions": defs_val,
                            "collocations": related_phrases.unwrap_or_default(),
                        })
                    };
                    card.back = serde_json::to_string(&json_back).unwrap_or(card.back);
                }
                Ok(card)
            }
        ).unwrap().filter_map(|r| r.ok()).collect();

        let total_sql = format!(
            "SELECT COUNT(*) FROM prebuilt_cards pc
             JOIN prebuilt_language_cards plc ON pc.id = plc.id
             JOIN user_cards uc ON uc.prebuilt_card_id = pc.id AND uc.user_id = ?1
             JOIN card_memory cm ON cm.user_card_id = uc.id
             WHERE pc.subject = ?2 AND pc.card_type = 'vocabulary'
               AND cm.status = 'active'
               AND cm.due <= ?3"
        );
        let total: i64 = conn.query_row(
            &total_sql,
            rusqlite::params![user_id, subj, now],
            |row| row.get(0),
        ).unwrap_or(0);

        tracing::info!("[CP1] get_due_cards result: returned {} cards, total_due={}", cards.len(), total);
        return (cards, total);
    }

    // plan-based 或默认查询（语言查询已在上方独立处理并返回）
    let (where_clause, total_where): (String, String) = if let Some(cid) = conv_id {
        (
            format!("c.user_id = ?1 AND pr.conversation_id = '{}' AND cm.status = 'active' AND cm.due <= ?2 AND upp.user_id = c.user_id AND upp.status IN ('in_progress', 'done') AND (pr.subject NOT IN ('english', 'chinese') OR c.prebuilt_card_id IS NULL)", cid.replace('\'', "''")),
            format!("c.user_id = ?1 AND pr.conversation_id = '{}' AND cm.status = 'active' AND cm.due <= ?2 AND upp.user_id = c.user_id AND upp.status IN ('in_progress', 'done') AND (pr.subject NOT IN ('english', 'chinese') OR c.prebuilt_card_id IS NULL)", cid.replace('\'', "''")),
        )
    } else {
        (
            "c.user_id = ?1 AND c.plan_run_id != '' AND cm.status = 'active' AND cm.due <= ?2".to_string(),
            "c.user_id = ?1 AND c.plan_run_id != '' AND cm.status = 'active' AND cm.due <= ?2".to_string(),
        )
    };

    let sql = format!(
        "SELECT c.id, COALESCE(c.front, pc.front) as front,
                COALESCE(psc.definition, plc.pronunciation, plt.full_text, phc.body, 
                         usc.definition, ulc.pronunciation, ulf.full_text, uhc.body, '') as back,
                c.domain, COALESCE(pc.card_type, '') as card_type, NULL as source_sentence,
                cm.state, cm.reps, cm.lapses, 0, cm.difficulty, cm.due, cm.last_review,
                (SELECT rating FROM review_log WHERE card_id = c.id ORDER BY reviewed_at DESC LIMIT 1),
                pr.conversation_id,
                plc.definitions,
                plc.pronunciation,
                plc.related_phrases,
                plc.pos,
                usc.definition, usc.key_elements, usc.applications, usc.related_concepts, usc.source,
                ulc.pronunciation, ulc.definitions, ulc.related_phrases, ulc.pos,
                ulf.full_text, ulf.translation, ulf.author, ulf.genre,
                uhc.body, uhc.period, uhc.region, uhc.tags
         FROM user_cards c
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         LEFT JOIN prebuilt_science_cards psc ON pc.id = psc.id
         LEFT JOIN prebuilt_language_cards plc ON pc.id = plc.id
         LEFT JOIN prebuilt_literature_cards plt ON pc.id = plt.id
         LEFT JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
         LEFT JOIN user_science_cards usc ON c.id = usc.id
         LEFT JOIN user_language_cards ulc ON c.id = ulc.id
         LEFT JOIN user_literature_cards ulf ON c.id = ulf.id
         LEFT JOIN user_humanities_cards uhc ON c.id = uhc.id
         LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id AND c.plan_run_id != ''
         JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN user_plan_progress upp ON c.plan_run_id = upp.plan_id AND c.task_key = upp.task_key
         WHERE {}
         ORDER BY CASE WHEN cm.state = 0 THEN 1 ELSE 0 END, cm.due ASC
         LIMIT ?3 OFFSET ?4",
        where_clause
    );


    let mut stmt = conn.prepare(&sql).unwrap();

    let cards: Vec<DueCard> = stmt.query_map(
        rusqlite::params![user_id, now, limit, offset],
        |row| {
            let mut card = DueCard {
                id: row.get(0)?,
                front: row.get(1)?,
                back: row.get(2)?,
                domain: row.get(3)?,
                card_type: row.get(4)?,
                source_sentence: row.get(5)?,
                state: row.get(6)?,
                reps: row.get(7)?,
                lapses: row.get(8)?,
                created_at: row.get(9)?,
                difficulty: row.get(10)?,
                due: row.get(11)?,
                last_review: row.get(12)?,
                last_review_quality: row.get(13)?,
                conversation_id: row.get(14)?,
            };
            // 词汇卡：构造 JSON back（复用 V3 前端的 _buildJsonBack 渲染）
            if card.card_type == "vocabulary" {
                let defs_str: Option<String> = row.get(15).ok().unwrap_or_default();
                let pronunciation: Option<String> = row.get(16).ok().unwrap_or_default();
                let related_phrases: Option<String> = row.get(17).ok().unwrap_or_default();
                let pos: Option<String> = row.get(18).ok().unwrap_or_default();

                let defs_val: serde_json::Value = defs_str.as_deref()
                    .and_then(|s| serde_json::from_str(s).ok())
                    .unwrap_or(serde_json::Value::Null);

                let subject = card.domain.as_deref().unwrap_or("language");

                // 中文词汇卡：{character, pinyin, definitions, related_phrases}
                // 英文词汇卡：{word, phonetic, pos, definitions, collocations}
                let json_back = if subject == "chinese" || subject == "japanese" {
                    serde_json::json!({
                        "character": card.front,
                        "pinyin": pronunciation.unwrap_or_default(),
                        "definitions": defs_val,
                        "common_words": related_phrases.unwrap_or_default(),
                    })
                } else {
                    serde_json::json!({
                        "word": card.front,
                        "phonetic": pronunciation.unwrap_or_default(),
                        "pos": pos.unwrap_or_default(),
                        "definitions": defs_val,
                        "collocations": related_phrases.unwrap_or_default(),
                    })
                };
                card.back = serde_json::to_string(&json_back).unwrap_or(card.back);
            }
            Ok(card)
        }
    ).unwrap().filter_map(|r| r.ok()).collect();

    let total_sql = format!(
        "SELECT COUNT(*) FROM user_cards c
         LEFT JOIN prebuilt_cards pc ON c.prebuilt_card_id = pc.id
         LEFT JOIN plan_runs pr ON c.plan_run_id = pr.id AND c.plan_run_id != ''
         JOIN card_memory cm ON c.id = cm.user_card_id
         LEFT JOIN user_plan_progress upp ON c.plan_run_id = upp.plan_id AND c.task_key = upp.task_key
         WHERE {}",
        total_where
    );

    let total: i64 = conn.query_row(
        &total_sql,
        rusqlite::params![user_id, now],
        |row| row.get(0),
    ).unwrap_or(0);

    tracing::info!("[CP1] get_due_cards result: returned {} cards, total_due={}", cards.len(), total);
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
            "INSERT INTO review_log (id, card_id, user_card_id, rating, verification_type, verification_result, details_json, reviewed_at)
             VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![log_id, card_id, rating, verification_type, verification_result, details, now],
        ).map_err(|e| format!("Review log insert: {}", e))?;
    } else {
        conn.execute(
            "INSERT INTO review_log (id, card_id, user_card_id, rating, verification_type, verification_result, reviewed_at)
             VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![log_id, card_id, rating, verification_type, verification_result, now],
        ).map_err(|e| format!("Review log insert: {}", e))?;
    }

    // 2. FSRS-5 scheduling
    let passed = verification_result == "pass";
    let rating = Rating::from_pass(passed, false);
    let new_state = compute_next_state(conn, card_id, rating);

    conn.execute(
        "UPDATE card_memory SET state = ?1, due = ?2, last_review = ?3,
         reps = reps + 1, lapses = lapses + ?4
         WHERE user_card_id = ?5",
        rusqlite::params![new_state.0, new_state.1, now, if passed { 0 } else { 1 }, card_id],
    ).map_err(|e| format!("Card memory update: {}", e))?;

    // 3. 更新 streak
    let streak_days = update_streak(conn, user_id)?;

    // 4. 批量聚合成就上下文 — 单次查询替代多次独立查询
    let agg: AchievementAggregate = conn.query_row(
        "SELECT
            (SELECT COUNT(*) FROM user_cards c JOIN card_memory cm ON c.id = cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active') AS total_cards,
            (SELECT COUNT(*) FROM review_log r
             JOIN user_cards c ON r.card_id = c.id
             WHERE c.user_id = ?1) AS total_reviews,
            (SELECT COUNT(DISTINCT c.domain) FROM user_cards c JOIN card_memory cm ON c.id = cm.user_card_id WHERE c.user_id = ?1 AND cm.status = 'active' AND c.domain IS NOT NULL) AS domains_covered,
            (SELECT COUNT(*) FROM plan_runs pr
             JOIN user_plan_progress upp ON pr.id = upp.plan_id
             WHERE upp.user_id = ?1 AND upp.status = 'completed') AS plans_completed,
            (SELECT COUNT(*) FROM conversations WHERE user_id = ?1) AS conversations_completed",
        rusqlite::params![user_id],
        |row| Ok(AchievementAggregate {
            total_cards: row.get(0)?,
            total_reviews: row.get(1)?,
            domains_covered: row.get(2)?,
            plans_completed: row.get(3)?,
            conversations_completed: row.get(4)?,
        }),
    ).unwrap_or(AchievementAggregate {
        total_cards: 0,
        total_reviews: 0,
        domains_covered: 0,
        plans_completed: 0,
        conversations_completed: 0,
    });

    Ok(AchievementContext {
        user_id: user_id.to_string(),
        total_cards: agg.total_cards,
        total_reviews: agg.total_reviews,
        streak_days,
        domains_covered: agg.domains_covered,
        plans_completed: agg.plans_completed,
        conversations_completed: agg.conversations_completed,
        ..Default::default()
    })
}

/// 批量聚合结果，用于单次查询替代多次独立查询
struct AchievementAggregate {
    total_cards: u32,
    total_reviews: u32,
    domains_covered: u32,
    plans_completed: u32,
    conversations_completed: u32,
}

/// FSRS-5 scheduling: compute next state and due timestamp.
/// Returns (new_state_code, next_due_timestamp)
///
/// State mapping: 0=New, 1=Learning, 2=Review, 3=Relearning
fn compute_next_state(conn: &Connection, card_id: &str, rating: Rating) -> (i32, i64) {
    // Read current memory state from DB
    let (current_state, difficulty, stability, reps, last_review): (i32, f64, f64, i32, Option<i64>) = conn.query_row(
        "SELECT state, difficulty, stability, reps, last_review FROM card_memory WHERE user_card_id = ?1",
        rusqlite::params![card_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
    ).unwrap_or((0, 0.0, 0.0, 0, None));

    let now = Utc::now().timestamp();
    let elapsed_days = match last_review {
        Some(lr) => ((now - lr) as f64 / 86400.0).max(0.0),
        None => 0.0,
    };

    let mem = FsrsMemory {
        difficulty,
        stability,
        reps,
        lapses: 0, // will be updated separately
        last_review,
    };

    let result = fsrs5::schedule(&mem, rating, elapsed_days);

    // Map FSRS result to state codes
    let next_state = match rating {
        Rating::Again => 3,  // Relearning
        Rating::Hard | Rating::Good => {
            if current_state == 0 { 1 } else { 2 } // New→Learning, else Review
        }
        Rating::Easy => 2,  // Review
    };

    let next_due = now + result.interval_seconds;

    // Update difficulty/stability in card_memory
    let _ = conn.execute(
        "UPDATE card_memory SET difficulty = ?1, stability = ?2 WHERE user_card_id = ?3",
        rusqlite::params![result.difficulty, result.stability, card_id],
    );

    (next_state, next_due)
}

/// B2 隐式复习：用户输入命中词库词汇时，记录为一次通过（pass）的隐式复习。
/// 与 submit_review 不同的是，不触发成就检测和 streak 更新。
/// 由 ws.rs hot path 中的 B2 逻辑调用。
pub fn record_implicit_review(conn: &Connection, user_card_id: &str) {
    let now = Utc::now().timestamp();
    let rating = Rating::from_pass(true, false);
    let new_state = compute_next_state(conn, user_card_id, rating);

    let _ = conn.execute(
        "UPDATE card_memory SET state = ?1, due = ?2, last_review = ?3, reps = reps + 1
         WHERE user_card_id = ?4",
        rusqlite::params![new_state.0, new_state.1, now, user_card_id],
    );

    // 写入 review_log（简化：verification_type='ai_dialogue', rating=4 pass）
    let log_id = format!("b2_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
    let _ = conn.execute(
        "INSERT INTO review_log (id, card_id, user_card_id, rating, verification_type, verification_result, reviewed_at)
         VALUES (?1, ?2, ?2, 4, 'ai_dialogue', 'pass', ?3)",
        rusqlite::params![log_id, user_card_id, now],
    );
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
             CREATE TABLE IF NOT EXISTS prebuilt_cards (id TEXT PRIMARY KEY, card_type TEXT NOT NULL, domain TEXT NOT NULL, subject TEXT NOT NULL DEFAULT '', grade_band TEXT NOT NULL DEFAULT '', front TEXT NOT NULL DEFAULT '', difficulty REAL DEFAULT 0.5, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS plan_runs (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT NOT NULL, prebuilt_plan_id TEXT, subject TEXT NOT NULL DEFAULT '', domain TEXT NOT NULL, grade_band TEXT NOT NULL DEFAULT '', goal TEXT NOT NULL DEFAULT '', plan_content TEXT, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS user_cards (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, plan_run_id TEXT DEFAULT '', prebuilt_card_id TEXT, domain TEXT NOT NULL, front TEXT, status TEXT NOT NULL DEFAULT 'active', task_key TEXT, language TEXT, level TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE IF NOT EXISTS card_memory (user_card_id TEXT PRIMARY KEY, state INTEGER DEFAULT 0, status TEXT DEFAULT 'active', difficulty REAL DEFAULT 5.0, stability REAL DEFAULT 0.0, due INTEGER DEFAULT 0, last_review INTEGER, reps INTEGER DEFAULT 0, lapses INTEGER DEFAULT 0);
             CREATE TABLE IF NOT EXISTS review_log (id TEXT PRIMARY KEY, card_id TEXT NOT NULL, user_card_id TEXT REFERENCES user_cards(id) ON DELETE CASCADE, rating INTEGER NOT NULL, verification_type TEXT NOT NULL, verification_result TEXT NOT NULL, details_json TEXT DEFAULT NULL, reviewed_at INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS achievements (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, achievement_key TEXT NOT NULL, name TEXT NOT NULL, icon TEXT NOT NULL, tier TEXT DEFAULT 'fixed', source TEXT, unlocked_at TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS user_plan_progress (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, plan_id TEXT NOT NULL, task_key TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', score REAL, attempt_count INTEGER DEFAULT 0);
             CREATE TABLE IF NOT EXISTS prebuilt_science_cards (id TEXT PRIMARY KEY, definition TEXT NOT NULL DEFAULT '', key_elements TEXT NOT NULL DEFAULT '', applications TEXT NOT NULL DEFAULT '', related_concepts TEXT NOT NULL DEFAULT '', formula TEXT NOT NULL DEFAULT '', graph TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS prebuilt_language_cards (id TEXT PRIMARY KEY, pronunciation TEXT NOT NULL DEFAULT '', pos TEXT NOT NULL DEFAULT '', definitions TEXT NOT NULL DEFAULT '[]', related_phrases TEXT NOT NULL DEFAULT '', structure_meta TEXT NOT NULL DEFAULT '', level TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS prebuilt_literature_cards (id TEXT PRIMARY KEY, full_text TEXT NOT NULL DEFAULT '', translation TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '', genre TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS prebuilt_humanities_cards (id TEXT PRIMARY KEY, node_type TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', period TEXT NOT NULL DEFAULT '', region TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS user_science_cards (id TEXT PRIMARY KEY, definition TEXT NOT NULL DEFAULT '', key_elements TEXT NOT NULL DEFAULT '', applications TEXT NOT NULL DEFAULT '', related_concepts TEXT NOT NULL DEFAULT '', formula TEXT NOT NULL DEFAULT '', graph TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS user_language_cards (id TEXT PRIMARY KEY, pronunciation TEXT NOT NULL DEFAULT '', pos TEXT NOT NULL DEFAULT '', definitions TEXT NOT NULL DEFAULT '[]', related_phrases TEXT NOT NULL DEFAULT '', structure_meta TEXT NOT NULL DEFAULT '', level TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS user_literature_cards (id TEXT PRIMARY KEY, full_text TEXT NOT NULL DEFAULT '', translation TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '', genre TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE IF NOT EXISTS user_humanities_cards (id TEXT PRIMARY KEY, node_type TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', period TEXT NOT NULL DEFAULT '', region TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);"
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
            "CREATE TABLE prebuilt_cards (id TEXT PRIMARY KEY, card_type TEXT NOT NULL, domain TEXT NOT NULL, subject TEXT NOT NULL DEFAULT '', grade_band TEXT NOT NULL DEFAULT '', front TEXT NOT NULL DEFAULT '', difficulty REAL DEFAULT 0.5, created_at TEXT NOT NULL DEFAULT (datetime('now')));
             CREATE TABLE plan_runs (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, conversation_id TEXT NOT NULL, domain TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
             CREATE TABLE user_cards (id TEXT PRIMARY KEY, user_id TEXT, plan_run_id TEXT DEFAULT '', prebuilt_card_id TEXT, domain TEXT, front TEXT, status TEXT DEFAULT 'active', task_key TEXT, language TEXT, level TEXT, created_at TEXT DEFAULT (datetime('now')));
             CREATE TABLE card_memory (user_card_id TEXT PRIMARY KEY, state INTEGER DEFAULT 0, status TEXT DEFAULT 'active', difficulty REAL DEFAULT 5.0, stability REAL DEFAULT 0.0, due INTEGER DEFAULT 0, last_review INTEGER, reps INTEGER DEFAULT 0, lapses INTEGER DEFAULT 0);
             CREATE TABLE review_log (id TEXT PRIMARY KEY, card_id TEXT, user_card_id TEXT, rating INTEGER, verification_type TEXT, verification_result TEXT, reviewed_at INTEGER);
             CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT, streak_days INTEGER DEFAULT 0, last_active_date TEXT, created_at TEXT);
             CREATE TABLE conversations (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, turn_count INTEGER DEFAULT 0, started_at TEXT NOT NULL);
             CREATE TABLE user_plan_progress (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, plan_id TEXT NOT NULL, task_key TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', score REAL, attempt_count INTEGER DEFAULT 0);
             CREATE TABLE prebuilt_science_cards (id TEXT PRIMARY KEY, definition TEXT NOT NULL DEFAULT '', key_elements TEXT NOT NULL DEFAULT '', applications TEXT NOT NULL DEFAULT '', related_concepts TEXT NOT NULL DEFAULT '', formula TEXT NOT NULL DEFAULT '', graph TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE prebuilt_language_cards (id TEXT PRIMARY KEY, pronunciation TEXT NOT NULL DEFAULT '', pos TEXT NOT NULL DEFAULT '', definitions TEXT NOT NULL DEFAULT '[]', related_phrases TEXT NOT NULL DEFAULT '', structure_meta TEXT NOT NULL DEFAULT '', level TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE prebuilt_literature_cards (id TEXT PRIMARY KEY, full_text TEXT NOT NULL DEFAULT '', translation TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '', genre TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE prebuilt_humanities_cards (id TEXT PRIMARY KEY, node_type TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', period TEXT NOT NULL DEFAULT '', region TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', FOREIGN KEY (id) REFERENCES prebuilt_cards(id) ON DELETE CASCADE);
             CREATE TABLE user_science_cards (id TEXT PRIMARY KEY, definition TEXT NOT NULL DEFAULT '', key_elements TEXT NOT NULL DEFAULT '', applications TEXT NOT NULL DEFAULT '', related_concepts TEXT NOT NULL DEFAULT '', formula TEXT NOT NULL DEFAULT '', graph TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE user_language_cards (id TEXT PRIMARY KEY, pronunciation TEXT NOT NULL DEFAULT '', pos TEXT NOT NULL DEFAULT '', definitions TEXT NOT NULL DEFAULT '[]', related_phrases TEXT NOT NULL DEFAULT '', structure_meta TEXT NOT NULL DEFAULT '', level TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE user_literature_cards (id TEXT PRIMARY KEY, full_text TEXT NOT NULL DEFAULT '', translation TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '', genre TEXT NOT NULL DEFAULT '', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);
             CREATE TABLE user_humanities_cards (id TEXT PRIMARY KEY, node_type TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', period TEXT NOT NULL DEFAULT '', region TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', FOREIGN KEY (id) REFERENCES user_cards(id) ON DELETE CASCADE);"
        ).unwrap();
        conn
    }

    #[test]
    fn test_get_due_cards_empty() {
        let conn = setup_db();
        let (cards, total) = get_due_cards(&conn, "u1", 20, 0, None, None);
        assert!(cards.is_empty());
        assert_eq!(total, 0);
    }

    #[test]
    fn test_submit_review_updates_streak() {
        let conn = setup_db();
        conn.execute("INSERT INTO users (id, username, created_at) VALUES ('u1', 'test', '2026-01-01')", []).unwrap();
        conn.execute("INSERT INTO plan_runs (id, user_id, conversation_id, domain, created_at, updated_at) VALUES ('pr_c1', 'u1', 'conv_c1', 'test', datetime('now'), datetime('now'))", []).unwrap();
        conn.execute("INSERT INTO user_cards (id, user_id, plan_run_id, domain, front, created_at) VALUES ('c1', 'u1', 'pr_c1', 'test', 'test', '2026-01-01')", []).unwrap();
        conn.execute("INSERT INTO card_memory (user_card_id, due) VALUES ('c1', 0)", []).unwrap();

        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "u1", None).unwrap();
        assert_eq!(ctx.streak_days, 1);
        assert_eq!(ctx.total_reviews, 1);
    }

    // ── E2E 全流程: 制卡 → FSRS → 复习 → 状态转移 ──

    fn insert_card(conn: &Connection, id: &str, user_id: &str, front: &str, _back: &str) {
        // 插入一条 plan_run 记录供 FK 引用
        let plan_run_id = format!("pr_{}", id);
        let conv_id = format!("conv_{}", id);
        conn.execute(
            "INSERT INTO plan_runs (id, user_id, conversation_id, domain, created_at, updated_at) VALUES (?1, ?2, ?3, 'test', datetime('now'), datetime('now'))",
            rusqlite::params![plan_run_id, user_id, conv_id],
        ).unwrap();
        conn.execute(
            "INSERT INTO user_cards (id, user_id, plan_run_id, domain, front, created_at) VALUES (?1, ?2, ?3, 'test', ?4, '2026-01-01')",
            rusqlite::params![id, user_id, plan_run_id, front],
        ).unwrap();
        conn.execute(
            "INSERT INTO card_memory (user_card_id, state, due) VALUES (?1, 0, 0)",
            rusqlite::params![id],
        ).unwrap();
    }

    fn insert_card_old(conn: &Connection, id: &str, user_id: &str, front: &str, _back: &str) {
        let plan_run_id = format!("pr_{}", id);
        let conv_id = format!("conv_{}", id);
        conn.execute(
            "INSERT INTO plan_runs (id, user_id, conversation_id, domain, created_at, updated_at) VALUES (?1, ?2, ?3, 'test', datetime('now'), datetime('now'))",
            rusqlite::params![plan_run_id, user_id, conv_id],
        ).unwrap();
        conn.execute(
            "INSERT INTO user_cards (id, user_id, plan_run_id, domain, front, created_at) VALUES (?1, ?2, ?3, 'test', ?4, '2026-01-02')",
            rusqlite::params![id, user_id, plan_run_id, front],
        ).unwrap();
        conn.execute(
            "INSERT INTO card_memory (user_card_id, state, due) VALUES (?1, 2, 0)",  // old Review state
            rusqlite::params![id],
        ).unwrap();
    }

    #[test]
    fn e2e_new_card_to_learning() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // 1. 到期查询
        let (due, total) = get_due_cards(&conn, "e2e_user", 20, 0, None, None);
        assert_eq!(due.len(), 1, "新卡片应到期");
        assert_eq!(total, 1);
        assert_eq!(due[0].state, 0, "New 状态");

        // 2. 提交复习 (pass) → New → Learning
        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        assert_eq!(ctx.total_reviews, 1, "第1次复习");

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE user_card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 1, "New + pass → Learning");
    }

    #[test]
    fn e2e_learning_to_review() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();

        // 模拟 due 已到
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();

        // Learning + pass → Review
        let ctx = submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        assert_eq!(ctx.total_reviews, 2);

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE user_card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 2, "Learning + pass → Review");
    }

    #[test]
    fn e2e_review_to_relearning() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning → Review
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();

        // Review + fail → Relearning
        submit_review(&conn, "c1", 1, "spelling", "fail", "e2e_user", None).unwrap();

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE user_card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 3, "Review + fail → Relearning");
    }

    #[test]
    fn e2e_relearning_to_review() {
        let conn = setup_full_db();
        insert_card(&conn, "c1", "e2e_user", "概念A", "概念A的解释");

        // New → Learning → Review → Relearning
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();
        submit_review(&conn, "c1", 1, "spelling", "fail", "e2e_user", None).unwrap();
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c1'", []).unwrap();

        // Relearning + pass → Review
        submit_review(&conn, "c1", 3, "spelling", "pass", "e2e_user", None).unwrap();

        let state: i32 = conn.query_row(
            "SELECT state FROM card_memory WHERE user_card_id='c1'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(state, 2, "Relearning + pass → Review");
    }

    #[test]
    fn e2e_streak_continuation() {
        let conn = setup_full_db();

        // 第1天: 复习 → streak=1
        insert_card(&conn, "c2", "e2e_user", "卡B", "说明B");
        submit_review(&conn, "c2", 3, "spelling", "pass", "e2e_user", None).unwrap();
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
        submit_review(&conn, "c3", 3, "spelling", "pass", "e2e_user", None).unwrap();
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
        submit_review(&conn, "c4", 3, "spelling", "pass", "e2e_user", None).unwrap();

        let streak: i32 = conn.query_row(
            "SELECT streak_days FROM users WHERE id='e2e_user'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(streak, 1, "断签后重置为 1");
    }

    #[test]
    fn e2e_due_queue_ordering() {
        let conn = setup_full_db();
        insert_card(&conn, "ca", "e2e_user", "较早到期新卡", "");
        insert_card(&conn, "cb", "e2e_user", "较晚到期新卡", "");
        insert_card_old(&conn, "cc", "e2e_user", "复习中卡片", "");
        conn.execute("UPDATE card_memory SET due=100, state=0 WHERE user_card_id='ca'", []).unwrap();
        conn.execute("UPDATE card_memory SET due=200, state=0 WHERE user_card_id='cb'", []).unwrap();
        conn.execute("UPDATE card_memory SET due=500, state=2 WHERE user_card_id='cc'", []).unwrap();

        let (due, _) = get_due_cards(&conn, "e2e_user", 20, 0, None, None);
        assert!(due.len() >= 3, "3 张到期");
        // 新排序: 非新卡片(state≠0)优先，同组内按 due ASC
        assert_eq!(due[0].id, "cc", "复习中(cc)应排第一");
        assert_eq!(due[1].id, "ca", "新卡ca due=100");
        assert_eq!(due[2].id, "cb", "新卡cb due=200");
    }

    #[test]
    fn e2e_limit_20_cards() {
        let conn = setup_full_db();
        for i in 0..30 {
            let id = format!("c_{}", i);
            insert_card(&conn, &id, "e2e_user", &format!("卡{}", i), "");
        }
        let (due, total) = get_due_cards(&conn, "e2e_user", 20, 0, None, None);
        assert_eq!(due.len(), 20, "LIMIT 20");
        assert_eq!(total, 30, "total 报告全部数量");
    }

    #[test]
    fn e2e_lapses_increment_on_fail() {
        let conn = setup_full_db();
        insert_card(&conn, "c_lapse", "e2e_user", "遗忘测试", "");

        // fail
        submit_review(&conn, "c_lapse", 1, "spelling", "fail", "e2e_user", None).unwrap();
        let lapses: i32 = conn.query_row(
            "SELECT lapses FROM card_memory WHERE user_card_id='c_lapse'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(lapses, 1, "fail → lapses+1");

        // pass
        conn.execute("UPDATE card_memory SET due=0 WHERE user_card_id='c_lapse'", []).unwrap();
        submit_review(&conn, "c_lapse", 3, "spelling", "pass", "e2e_user", None).unwrap();
        let lapses2: i32 = conn.query_row(
            "SELECT lapses FROM card_memory WHERE user_card_id='c_lapse'", [], |r| r.get(0)
        ).unwrap();
        assert_eq!(lapses2, 1, "pass → lapses 不变");
    }
}

