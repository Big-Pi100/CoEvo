//! K12 题库评估系统
//!
//! 为每个任务提供客观完成判断：通过率 >= 80% 视为完成
//! 无题库时回退 LLM 主观判断

use rusqlite::Connection;

/// 判断指定任务是否应标记为完成
///
/// 逻辑：
/// - 查询 k12_quiz_bank 中该任务的题目数
/// - 无题库 → 返回 true（回退 LLM 判断）
/// - 有题库 → 计算最近 7 天通过率 ≥ 80%
pub fn should_mark_task_complete(
    conn: &Connection,
    user_id: &str,
    task_name: &str,
) -> bool {
    // 查该任务在题库中的题目数
    let quiz_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM k12_quiz_bank WHERE task_name = ?1",
            rusqlite::params![task_name],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 无题库时回退 LLM 判断
    if quiz_count == 0 {
        return true;
    }

    // 有题库：计算最近 7 天通过率
    let seven_days_ago = chrono::Utc::now() - chrono::Duration::days(7);
    let cutoff = seven_days_ago.to_rfc3339();

    let total: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM k12_quiz_attempts
             WHERE user_id = ?1 AND task_name = ?2 AND attempted_at >= ?3",
            rusqlite::params![user_id, task_name, cutoff],
            |row| row.get(0),
        )
        .unwrap_or(0);

    if total == 0 {
        return false; // 有题库但没做过题 → 未完成
    }

    let correct: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM k12_quiz_attempts
             WHERE user_id = ?1 AND task_name = ?2 AND attempted_at >= ?3 AND is_correct = 1",
            rusqlite::params![user_id, task_name, cutoff],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let pass_rate = correct as f64 / total as f64;
    pass_rate >= 0.8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_no_quiz_bank_returns_true() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE k12_quiz_bank (id TEXT, task_name TEXT);
             CREATE TABLE k12_quiz_attempts (id TEXT, user_id TEXT, task_name TEXT, is_correct INTEGER, attempted_at TEXT);"
        ).unwrap();

        // 无题库 → true
        assert!(should_mark_task_complete(&conn, "user1", "任务1"));
    }

    #[test]
    fn test_below_threshold_returns_false() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE k12_quiz_bank (id TEXT, task_name TEXT);
             CREATE TABLE k12_quiz_attempts (id TEXT, user_id TEXT, task_name TEXT, is_correct INTEGER, attempted_at TEXT);"
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_bank (id, task_name) VALUES ('q1', '任务1')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_attempts (id, user_id, task_name, is_correct, attempted_at)
             VALUES ('a1', 'user1', '任务1', 1, '2026-05-23T10:00:00Z')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_attempts (id, user_id, task_name, is_correct, attempted_at)
             VALUES ('a2', 'user1', '任务1', 0, '2026-05-23T10:01:00Z')",
            [],
        ).unwrap();

        // 1/2 = 50% < 80% → false
        assert!(!should_mark_task_complete(&conn, "user1", "任务1"));
    }

    #[test]
    fn test_above_threshold_returns_true() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE k12_quiz_bank (id TEXT, task_name TEXT);
             CREATE TABLE k12_quiz_attempts (id TEXT, user_id TEXT, task_name TEXT, is_correct INTEGER, attempted_at TEXT);"
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_bank (id, task_name) VALUES ('q1', '任务1')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_attempts (id, user_id, task_name, is_correct, attempted_at)
             VALUES ('a1', 'user1', '任务1', 1, '2026-05-23T10:00:00Z')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO k12_quiz_attempts (id, user_id, task_name, is_correct, attempted_at)
             VALUES ('a2', 'user1', '任务1', 1, '2026-05-23T10:01:00Z')",
            [],
        ).unwrap();

        // 2/2 = 100% >= 80% → true
        assert!(should_mark_task_complete(&conn, "user1", "任务1"));
    }
}
