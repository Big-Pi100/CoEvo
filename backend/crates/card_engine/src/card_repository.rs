//! N4: 卡片入库 (去重 + 写入)
//!
//! 负责:
//!   1. 去重检查 (front Jaro-Winkler > 0.85 拒绝)
//!   2. 事务写入 cards + card_memory
//!   3. 卡片状态管理 (pending → active / skipped)

use shared_types::card::{Card, CardMemory};
use rusqlite::Connection;

/// 入库结果
#[derive(Debug)]
pub enum InsertResult {
    Success(String),           // card_id
    Duplicate(String),         // front 已存在
    DatabaseError(String),     // 数据库错误
}

/// RAII transaction guard — auto-rollback on drop if not committed
struct TxGuard<'a> {
    conn: &'a Connection,
    committed: bool,
}

impl<'a> TxGuard<'a> {
    fn begin(conn: &'a Connection) -> Result<Self, rusqlite::Error> {
        conn.execute_batch("BEGIN IMMEDIATE")?;
        Ok(TxGuard { conn, committed: false })
    }
    fn commit(mut self) -> Result<(), rusqlite::Error> {
        self.conn.execute_batch("COMMIT")?;
        self.committed = true;
        Ok(())
    }
}

impl<'a> Drop for TxGuard<'a> {
    fn drop(&mut self) {
        if !self.committed {
            let _ = self.conn.execute_batch("ROLLBACK");
        }
    }
}

/// 插入卡片 (status='active') — 用于 K12 预生成和直接制卡
pub fn insert_card(conn: &Connection, card: &Card, memory: &CardMemory) -> InsertResult {
    insert_card_with_status(conn, card, memory, "active")
}

/// 插入卡片 (status='pending') — 用于概念弹窗候选
pub fn insert_pending_card(conn: &Connection, card: &Card, memory: &CardMemory) -> InsertResult {
    insert_card_with_status(conn, card, memory, "pending")
}

/// 内部实现：插入卡片 + 指定 status
fn insert_card_with_status(conn: &Connection, card: &Card, memory: &CardMemory, status: &str) -> InsertResult {
    let front_lower = card.front.to_lowercase();

    // 1. Transaction — auto-rollback on drop if not committed
    let tx = match TxGuard::begin(conn) {
        Ok(tx) => tx,
        Err(e) => return InsertResult::DatabaseError(format!("Begin tx: {}", e)),
    };

    // 2. Dedup check (inside transaction, prevents TOCTOU)
    // 扫描所有卡片（含 skipped），确保同一概念不会被重复提取
    let existing_fronts: Vec<String> = {
        let mut stmt = match conn.prepare(
            "SELECT LOWER(front) FROM cards WHERE user_id = ?1"
        ) {
            Ok(s) => s,
            Err(e) => return InsertResult::DatabaseError(format!("Prepare: {}", e)),
        };
        let rows = match stmt.query_map(rusqlite::params![card.user_id], |row| {
            row.get::<_, String>(0)
        }) {
            Ok(rows) => rows,
            Err(e) => return InsertResult::DatabaseError(format!("Query: {}", e)),
        };
        rows.filter_map(|r| r.ok()).collect()
    };

    // Exact + fuzzy matching
    for existing in &existing_fronts {
        if existing == &front_lower {
            return InsertResult::Duplicate(card.front.clone());
        }
        let sim = strsim::jaro_winkler(existing, &front_lower);
        if sim > 0.85 {
            return InsertResult::Duplicate(card.front.clone());
        }
    }

    // 3. Insert card with status
    if let Err(e) = conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band, status)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        rusqlite::params![
            card.id, card.user_id, card.domain, card.card_type,
            card.front, card.back, card.source_sentence, card.conversation_id, card.created_at,
            card.subject, card.grade_band, status,
        ],
    ) {
        return InsertResult::DatabaseError(format!("Card insert: {}", e));
    }

    // 4. Insert card memory
    if let Err(e) = conn.execute(
        "INSERT INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        rusqlite::params![
            memory.card_id, memory.state, memory.difficulty, memory.stability,
            memory.due, memory.last_review, memory.reps, memory.lapses,
        ],
    ) {
        return InsertResult::DatabaseError(format!("Memory insert: {}", e));
    }

    // 5. Commit
    match tx.commit() {
        Ok(_) => InsertResult::Success(card.id.clone()),
        Err(e) => InsertResult::DatabaseError(format!("Commit: {}", e)),
    }
}

/// 更新卡片状态: active / pending / skipped / archived
pub fn update_card_status(conn: &Connection, card_id: &str, status: &str) -> Result<(), String> {
    conn.execute(
        "UPDATE cards SET status = ?1 WHERE id = ?2",
        rusqlite::params![status, card_id],
    ).map_err(|e| format!("Status update: {}", e))?;
    Ok(())
}

/// 批量更新卡片状态
pub fn batch_update_status(conn: &Connection, card_ids: &[String], status: &str) -> Result<(), String> {
    for card_id in card_ids {
        conn.execute(
            "UPDATE cards SET status = ?1 WHERE id = ?2",
            rusqlite::params![status, card_id],
        ).map_err(|e| format!("Batch status update: {}", e))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use shared_types::card::ConceptCandidate;
    use crate::card_formatter::format_card;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE cards (id TEXT PRIMARY KEY, user_id TEXT, domain TEXT, card_type TEXT, front TEXT, back TEXT, source_sentence TEXT, conversation_id TEXT, created_at INTEGER, subject TEXT, grade_band TEXT, status TEXT NOT NULL DEFAULT 'active');
             CREATE TABLE card_memory (card_id TEXT PRIMARY KEY, state INTEGER, difficulty REAL, stability REAL, due INTEGER, last_review INTEGER, reps INTEGER, lapses INTEGER);"
        ).unwrap();
        conn
    }

    #[test]
    fn test_insert_new_card() {
        let conn = setup_db();
        let candidate = ConceptCandidate {
            front: "quantum computing".into(),
            back: "A computing paradigm using qubits".into(),
            source_sentence: "Quantum computing is the future.".into(),
            domain: "science".into(),
        };
        let (card, memory) = format_card("u1", &candidate);
        let result = insert_card(&conn, &card, &memory);
        match result {
            InsertResult::Success(id) => assert_eq!(id, card.id),
            _ => panic!("Expected success"),
        }
        // 验证默认 status='active'
        let status: String = conn.query_row(
            "SELECT status FROM cards WHERE id = ?1",
            rusqlite::params![card.id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(status, "active");
    }

    #[test]
    fn test_insert_pending_card() {
        let conn = setup_db();
        let candidate = ConceptCandidate {
            front: "pendulum".into(),
            back: "A weight suspended from a pivot".into(),
            source_sentence: "The pendulum swings.".into(),
            domain: "physics".into(),
        };
        let (card, memory) = format_card("u1", &candidate);
        let result = insert_pending_card(&conn, &card, &memory);
        match result {
            InsertResult::Success(id) => assert_eq!(id, card.id),
            _ => panic!("Expected success"),
        }
        // 验证 status='pending'
        let status: String = conn.query_row(
            "SELECT status FROM cards WHERE id = ?1",
            rusqlite::params![card.id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(status, "pending");
    }

    #[test]
    fn test_insert_duplicate_rejected() {
        let conn = setup_db();
        let candidate = ConceptCandidate {
            front: "machine learning".into(),
            back: "AI technique".into(),
            source_sentence: "ML is a subset of AI.".into(),
            domain: "tech".into(),
        };
        let (card1, mem1) = format_card("u1", &candidate);
        let _ = insert_card(&conn, &card1, &mem1);

        let (card2, mem2) = format_card("u1", &candidate);
        let result = insert_card(&conn, &card2, &mem2);
        match result {
            InsertResult::Duplicate(front) => assert_eq!(front, "machine learning"),
            _ => panic!("Expected duplicate"),
        }
    }

    #[test]
    fn test_update_card_status() {
        let conn = setup_db();
        let candidate = ConceptCandidate {
            front: "rust ownership".into(),
            back: "Each value has one owner".into(),
            source_sentence: "Ownership is key in Rust.".into(),
            domain: "programming".into(),
        };
        let (card, memory) = format_card("u1", &candidate);
        let _ = insert_card(&conn, &card, &memory);

        // active → skipped
        update_card_status(&conn, &card.id, "skipped").unwrap();
        let status: String = conn.query_row(
            "SELECT status FROM cards WHERE id = ?1",
            rusqlite::params![card.id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(status, "skipped");

        // skipped → active (revert)
        update_card_status(&conn, &card.id, "active").unwrap();
        let status: String = conn.query_row(
            "SELECT status FROM cards WHERE id = ?1",
            rusqlite::params![card.id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(status, "active");
    }
}
