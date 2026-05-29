//! K12 题库加载器
//!
//! 启动时从 data/curriculum/prebuilt/k12_quiz_bank*.json 加载试题到 k12_quiz_bank 表

use rusqlite::Connection;

/// 从预生成 JSON 文件加载题库到数据库
pub fn load_quiz_bank(conn: &Connection, base_dir: &str) -> Result<usize, String> {
    let dir = std::path::Path::new(base_dir);
    if !dir.exists() {
        return Ok(0); // 目录不存在，静默跳过
    }

    let mut total = 0usize;
    let mut loaded = 0usize;

    for entry in std::fs::read_dir(dir).map_err(|e| format!("read_dir: {}", e))? {
        let path = entry.map_err(|e| format!("entry: {}", e))?.path();
        let fname = path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if !fname.starts_with("k12_quiz_bank") || !fname.ends_with(".json") {
            continue;
        }

        let content = std::fs::read_to_string(&path)
            .map_err(|e| format!("read {}: {}", path.display(), e))?;
        let data: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("parse {}: {}", path.display(), e))?;

        let quizzes = data.get("quizzes")
            .and_then(|v| v.as_array())
            .map(|arr| arr.len())
            .unwrap_or(0);

        if let Some(quiz_list) = data.get("quizzes").and_then(|v| v.as_array()) {
            for quiz in quiz_list {
                let id = quiz.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let subject = quiz.get("subject").and_then(|v| v.as_str()).unwrap_or("");
                let grade_band = quiz.get("grade_band").and_then(|v| v.as_str()).unwrap_or("");
                let task_name = quiz.get("task_name").and_then(|v| v.as_str());
                let question = quiz.get("question").and_then(|v| v.as_str()).unwrap_or("");
                let answer = quiz.get("answer").and_then(|v| v.as_str()).unwrap_or("");
                let question_type = quiz.get("question_type").and_then(|v| v.as_str()).unwrap_or("choice");
                let options = quiz.get("options").and_then(|v| v.as_str());
                let source_dataset = quiz.get("source_dataset").and_then(|v| v.as_str()).unwrap_or("");
                let difficulty: f64 = quiz.get("difficulty").and_then(|v| v.as_f64()).unwrap_or(0.5);

                let result = conn.execute(
                    "INSERT OR IGNORE INTO k12_quiz_bank (id, subject, grade_band, task_name, question, answer, question_type, options, source_dataset, difficulty)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    rusqlite::params![id, subject, grade_band, task_name, question, answer, question_type, options, source_dataset, difficulty],
                );
                match result {
                    Ok(affected) => if affected > 0 { loaded += 1; }
                    Err(e) => tracing::warn!("Quiz insert failed: {} — {}", e, id),
                }
            }
        }

        total += quizzes;
        tracing::info!("Loaded {} quizzes from {} (inserted: {})", quizzes, fname, loaded);
    }

    tracing::info!("K12 quiz bank: {} loaded, {} total files", loaded, total);
    Ok(loaded)
}
