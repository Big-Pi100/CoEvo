//! N4: 卡片入库 (去重 + 写入)
//!
//! 负责:
//!   1. 去重检查 (front Jaro-Winkler > 0.85 拒绝)
//!   2. 跳过记录自动移除 (用户主动制卡时)
//!   3. 事务写入 cards + card_memory

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

/// 插入卡片 (事务封装，自动回滚)
pub fn insert_card(conn: &Connection, card: &Card, memory: &CardMemory) -> InsertResult {
    let front_lower = card.front.to_lowercase();

    // 1. Transaction — auto-rollback on drop if not committed
    let tx = match TxGuard::begin(conn) {
        Ok(tx) => tx,
        Err(e) => return InsertResult::DatabaseError(format!("Begin tx: {}", e)),
    };

    // 2. Dedup check (inside transaction, prevents TOCTOU)
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

    // 3. Remove skip record (user actively created this card)
    let _ = conn.execute(
        "DELETE FROM skipped_concepts WHERE user_id = ?1 AND LOWER(front) = ?2",
        rusqlite::params![card.user_id, front_lower],
    );

    // 4. Insert card
    if let Err(e) = conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence, conversation_id, created_at, subject, grade_band)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        rusqlite::params![
            card.id, card.user_id, card.domain, card.card_type,
            card.front, card.back, card.source_sentence, card.conversation_id, card.created_at,
            card.subject, card.grade_band,
        ],
    ) {
        return InsertResult::DatabaseError(format!("Card insert: {}", e));
    }

    // 5. Insert card memory
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

    // 6. Commit
    match tx.commit() {
        Ok(_) => InsertResult::Success(card.id.clone()),
        Err(e) => InsertResult::DatabaseError(format!("Commit: {}", e)),
    }
}

/// 跳过概念: 写入 skipped_concepts 表
pub fn skip_concept(conn: &Connection, user_id: &str, front: &str, domain: &Option<String>, source: &str) -> Result<String, String> {
    let id = format!("skip_{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap());
    let now = chrono::Utc::now().timestamp();

    conn.execute(
        "INSERT INTO skipped_concepts (id, user_id, front, domain, source_text, skipped_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![id, user_id, front, domain, source, now],
    ).map_err(|e| format!("Skip insert: {}", e))?;

    Ok(id)
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
            "CREATE TABLE cards (id TEXT PRIMARY KEY, user_id TEXT, domain TEXT, card_type TEXT, front TEXT, back TEXT, source_sentence TEXT, conversation_id TEXT, created_at INTEGER);
             CREATE TABLE card_memory (card_id TEXT PRIMARY KEY, state INTEGER, difficulty REAL, stability REAL, due INTEGER, last_review INTEGER, reps INTEGER, lapses INTEGER);
             CREATE TABLE skipped_concepts (id TEXT PRIMARY KEY, user_id TEXT, front TEXT, domain TEXT, source_text TEXT, skipped_at INTEGER);"
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
    fn test_skip_concept_writes() {
        let conn = setup_db();
        let id = skip_concept(&conn, "u1", "rust", &Some("programming".into()), "rust is fast").unwrap();
        assert!(id.starts_with("skip_"));
    }
}
