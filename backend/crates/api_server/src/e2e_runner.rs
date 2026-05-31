//! E2E Pipeline Test Runner — 共享测试工具
//!
//! 提供 E2E 测试框架的基础设施：
//! - 测试结果 JSON 序列化/反序列化
//! - LLM 对话辅助函数
//! - 测试环境初始化
//! - 结果目录管理

use std::path::PathBuf;
use std::time::Duration;
use serde::{Deserialize, Serialize};

// ── 测试结果结构 ──

/// 测试通过等级
///
/// A: 完全符合设计预期 — 正确 pipeline prompt 路由 + 字段 100% 对齐
/// B: 功能正确但有轻微偏差 — 部分字段不对齐，不影响使用
/// C: 兜底机制触发 — LLM 路径未走通但 word_bank/通用路径成功
/// D: 兜底部分生效 — 只有少量有效输出，功能勉强可用
/// F: 彻底失败 — 无有效输出
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum Grade {
    #[serde(rename = "A")]
    A,
    #[serde(rename = "B")]
    B,
    #[serde(rename = "C")]
    C,
    #[serde(rename = "D")]
    D,
    #[serde(rename = "F")]
    F,
}

/// 单个测试阶段的运行结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhaseResult {
    pub phase: String,
    pub pipeline_version: String,
    pub run_id: String,
    pub started_at: String,
    pub completed_at: String,
    pub duration_ms: u64,
    pub status: PhaseStatus,
    pub grade: Option<Grade>,
    pub metrics: serde_json::Value,
    pub llm_logs: Vec<LlmLog>,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum PhaseStatus {
    #[serde(rename = "passed")]
    Passed,
    #[serde(rename = "failed")]
    Failed,
    #[serde(rename = "skipped")]
    Skipped,
}

/// LLM 调用日志（用于 prompt 调优分析）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmLog {
    pub phase: String,
    pub step: String,
    pub domain: String,
    pub system_prompt_preview: String,
    pub user_message: String,
    pub raw_llm_response: String,
    pub duration_ms: u64,
    pub token_count: Option<u64>,
}

impl LlmLog {
    pub fn new(phase: &str, step: &str, domain: &str) -> Self {
        Self {
            phase: phase.to_string(),
            step: step.to_string(),
            domain: domain.to_string(),
            system_prompt_preview: String::new(),
            user_message: String::new(),
            raw_llm_response: String::new(),
            duration_ms: 0,
            token_count: None,
        }
    }
}

// ── 运行配置 ──

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunConfig {
    pub run_id: String,
    pub llm_model: String,
    pub base_url: String,
    pub started_at: String,
    pub completed_phases: Vec<String>,
}

// ── 结果管理 ──

const RESULTS_DIR: &str = "docs/test-results";

/// 获取本次运行的目录
fn get_run_dir(run_id: &str) -> PathBuf {
    PathBuf::from(RESULTS_DIR).join(run_id)
}

/// 获取最新的运行目录（latest symlink 的替代，实际读文件）
pub fn get_latest_run_dir() -> Option<PathBuf> {
    let latest_path = PathBuf::from(RESULTS_DIR).join("latest");
    if latest_path.join("config.json").exists() {
        Some(latest_path)
    } else {
        None
    }
}

/// 保存运行配置
pub fn save_config(run_id: &str, config: &RunConfig) -> std::io::Result<()> {
    let dir = get_run_dir(run_id);
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_string_pretty(config)?;
    std::fs::write(dir.join("config.json"), &json)?;
    Ok(())
}

/// 保存阶段结果
pub fn save_phase_result(run_id: &str, result: &PhaseResult) -> std::io::Result<()> {
    let dir = get_run_dir(run_id);
    std::fs::create_dir_all(&dir)?;
    let filename = format!("phase-{}.json", result.phase);
    let json = serde_json::to_string_pretty(result)?;
    std::fs::write(dir.join(&filename), &json)?;
    Ok(())
}

/// 读取阶段结果
pub fn load_phase_result(run_id: &str, phase: &str) -> Option<PhaseResult> {
    let dir = get_run_dir(run_id);
    let filename = format!("phase-{}.json", phase);
    let path = dir.join(&filename);
    if !path.exists() { return None; }
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

/// 更新运行配置：标记某阶段已完成
pub fn mark_phase_completed(run_id: &str, phase: &str) -> std::io::Result<()> {
    let path = get_run_dir(run_id).join("config.json");
    if !path.exists() { return Ok(()); }
    let content = std::fs::read_to_string(&path)?;
    let mut config: RunConfig = serde_json::from_str(&content)?;
    if !config.completed_phases.contains(&phase.to_string()) {
        config.completed_phases.push(phase.to_string());
    }
    std::fs::write(&path, serde_json::to_string_pretty(&config)?)?;
    Ok(())
}

/// 检查某阶段是否已完成
pub fn is_phase_completed(run_id: &str, phase: &str) -> bool {
    let path = get_run_dir(run_id).join("config.json");
    if !path.exists() { return false; }
    let content = std::fs::read_to_string(&path).ok();
    let config: RunConfig = match content.and_then(|c| serde_json::from_str(&c).ok()) {
        Some(c) => c,
        None => return false,
    };
    config.completed_phases.contains(&phase.to_string())
}

/// 更新 latest 目录：复制结果到 latest/
pub fn update_latest(run_id: &str) -> std::io::Result<()> {
    let src = get_run_dir(run_id);
    let dst = PathBuf::from(RESULTS_DIR).join("latest");
    let _ = std::fs::remove_dir_all(&dst);
    copy_dir_all(&src, &dst)
}

fn copy_dir_all(src: &PathBuf, dst: &PathBuf) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_all(&entry.path(), &dst.join(entry.file_name()))?;
        } else {
            std::fs::copy(entry.path(), dst.join(entry.file_name()))?;
        }
    }
    Ok(())
}

// ── 测试环境初始化 ──

/// 初始化测试 DB（创建表 + 测试用户 + 会话）
pub fn init_test_db(db_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let conn = rusqlite::Connection::open(db_path)?;

    conn.execute_batch(r#"
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
            plan_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS cards (
            id TEXT PRIMARY KEY, user_id TEXT NOT NULL, domain TEXT,
            card_type TEXT, front TEXT NOT NULL, back TEXT NOT NULL,
            source_sentence TEXT, conversation_id TEXT, created_at INTEGER,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS card_memory (
            card_id TEXT PRIMARY KEY, state INTEGER, difficulty REAL,
            stability REAL, due INTEGER, last_review INTEGER, reps INTEGER, lapses INTEGER,
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
        CREATE TABLE IF NOT EXISTS review_log (
            id TEXT PRIMARY KEY, card_id TEXT NOT NULL, rating INTEGER,
            verification_type TEXT, verification_result TEXT, reviewed_at INTEGER,
            FOREIGN KEY (card_id) REFERENCES cards(id)
        );
    "#)?;

    Ok(())
}

/// 创建测试用户 + 会话
pub fn seed_test_data(
    conn: &rusqlite::Connection,
    user_id: &str,
    username: &str,
    password_hash: &str,
    conv_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let now = chrono::Utc::now().to_rfc3339();

    conn.execute(
        "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![user_id, username, password_hash, now],
    )?;

    conn.execute(
        "INSERT OR IGNORE INTO conversations (id, user_id, turn_count, started_at) VALUES (?1, ?2, 0, ?3)",
        rusqlite::params![conv_id, user_id, now],
    )?;

    Ok(())
}

/// 插入对话轮次
pub fn insert_turn(conn: &rusqlite::Connection, conv_id: &str, role: &str, content: &str) {
    let now = chrono::Utc::now().to_rfc3339();
    let turn_id = format!("{}-{}", conv_id, rand::random::<u64>());
    let _ = conn.execute(
        "INSERT INTO conversation_turns (id, conversation_id, role, content, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![turn_id, conv_id, role, content, now],
    );
}

/// 获取对话历史
pub fn get_conversation_history(conn: &rusqlite::Connection, conv_id: &str, limit: usize) -> Vec<(String, String)> {
    let mut stmt = conn.prepare(
        "SELECT role, content FROM conversation_turns WHERE conversation_id = ?1 ORDER BY created_at"
    ).unwrap();
    let turns: Vec<(String, String)> = stmt.query_map(
        rusqlite::params![conv_id],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    ).unwrap().filter_map(|r| r.ok()).collect();

    // 返回最近 limit 轮
    if turns.len() > limit {
        turns[turns.len() - limit..].to_vec()
    } else {
        turns
    }
}

/// 创建 LLM Caller
pub fn create_llm_caller(model: &str) -> chat_engine::llm_caller::LlmCaller {
    let config = chat_engine::config::load_llm_config();
    let config = chat_engine::llm_caller::LlmConfig {
        model: model.to_string(),
        ..config
    };
    chat_engine::llm_caller::LlmCaller::new(config)
}

/// 查询学习计划上下文（带 domain）
pub fn build_plan_context(
    conn: &rusqlite::Connection,
    conv_id: &str,
) -> (String, String, String) {
    crate::plan_handler::build_plan_context(conn, conv_id)
}

/// 格式化持续时间
pub fn format_duration(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{}s", secs)
    } else {
        format!("{}m{:02}s", secs / 60, secs % 60)
    }
}

/// 根据阶段类型和指标判定通过等级
///
/// - concept-extraction: A=LLM路径+正确domain, C=仅word_bank路径, F=空
/// - progression: A=有plan_update, B=有教学但无plan_update, F=无教学
/// - plan-creation: A=domain全匹配, C=部分匹配, F=全不匹配
/// - review-flow: A=全通过, D=半通过, F=未通过
pub fn resolve_grade(phase: &str, status: &PhaseStatus, metrics: &serde_json::Value, _errors: &[String]) -> Grade {
    match status {
        PhaseStatus::Skipped => Grade::D,
        PhaseStatus::Failed => Grade::F,
        PhaseStatus::Passed => {
            match phase {
                "concept-extraction" => {
                    let total = metrics.get("total_concepts").and_then(|v| v.as_u64()).unwrap_or(0);
                    let domain_ok = metrics.get("domain_ok").and_then(|v| v.as_bool()).unwrap_or(false);
                    let direct_card = metrics.get("direct_card").and_then(|v| v.as_bool()).unwrap_or(false);
                    if direct_card { Grade::A }  // Path B2 直接制卡
                    else if total > 0 && domain_ok { Grade::A }  // LLM 路径 + 正确 domain
                    else if total > 0 { Grade::C }  // 仅 word_bank 匹配
                    else { Grade::D }
                }
                "progression-history" | "progression-language" | "progression-math" => {
                    let updates = metrics.get("plan_updates").and_then(|v| v.as_u64()).unwrap_or(0);
                    if updates > 0 { Grade::A }
                    else { Grade::B }  // 有教学但无 plan_update
                }
                "plan-creation" => {
                    let accuracy = metrics.get("domain_accuracy").and_then(|v| v.as_str()).unwrap_or("0/0");
                    if accuracy == "3/3" { Grade::A }
                    else if accuracy.starts_with("1/3") || accuracy.starts_with("2/3") { Grade::C }
                    else { Grade::D }
                }
                "review-flow" => {
                    let reps_ok = metrics.get("reps_ok").and_then(|v| v.as_bool()).unwrap_or(false);
                    let lapses_ok = metrics.get("lapses_ok").and_then(|v| v.as_bool()).unwrap_or(false);
                    let logs_ok = metrics.get("logs_ok").and_then(|v| v.as_bool()).unwrap_or(false);
                    if reps_ok && lapses_ok && logs_ok { Grade::A }
                    else if reps_ok || lapses_ok { Grade::D }
                    else { Grade::F }
                }
                _ => Grade::A,  // 其他阶段（report 等聚合阶段）默认 A
            }
        }
    }
}

// ── 卡片 & 复习辅助函数 ──

/// review_log 行条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewLogEntry {
    pub id: String,
    pub card_id: String,
    pub rating: i32,
    pub verification_type: String,
    pub verification_result: String,
    pub reviewed_at: i64,
}

/// 插入测试卡片（同时写入 cards + card_memory 1:1）
pub fn insert_test_card(
    conn: &rusqlite::Connection,
    user_id: &str,
    domain: &str,
    card_type: &str,
    front: &str,
    back: &str,
) -> Result<String, String> {
    let card_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();

    conn.execute(
        "INSERT INTO cards (id, user_id, domain, card_type, front, back, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![card_id, user_id, domain, card_type, front, back, now],
    ).map_err(|e| format!("Insert test card: {}", e))?;

    conn.execute(
        "INSERT INTO card_memory (card_id, state, difficulty, stability, due, last_review, reps, lapses)
         VALUES (?1, 0, 5.0, 5.0, ?2, NULL, 0, 0)",
        rusqlite::params![card_id, now],
    ).map_err(|e| format!("Insert test card memory: {}", e))?;

    Ok(card_id)
}

/// 调用 submit_review（封装 fsrs_scheduler）
pub fn call_submit_review(
    conn: &rusqlite::Connection,
    card_id: &str,
    user_id: &str,
    rating: i32,
    verification_type: &str,
    verification_result: &str,
) -> Result<(), String> {
    card_engine::fsrs_scheduler::submit_review(
        conn, card_id, rating, verification_type, verification_result, user_id, None,
    )?;
    Ok(())
}

/// 查 card_id 的所有 review_log
pub fn get_review_log(
    conn: &rusqlite::Connection,
    card_id: &str,
) -> Vec<ReviewLogEntry> {
    let stmt = conn.prepare(
        "SELECT id, card_id, rating, verification_type, verification_result, reviewed_at
         FROM review_log WHERE card_id = ?1 ORDER BY reviewed_at"
    ).map_err(|e| format!("Prepare review_log query: {}", e)).ok();

    let mut stmt = match stmt {
        Some(s) => s,
        None => return vec![],
    };

    stmt.query_map(rusqlite::params![card_id], |row| {
        Ok(ReviewLogEntry {
            id: row.get(0)?,
            card_id: row.get(1)?,
            rating: row.get(2)?,
            verification_type: row.get(3)?,
            verification_result: row.get(4)?,
            reviewed_at: row.get(5)?,
        })
    }).ok().map(|rows| rows.filter_map(|r| r.ok()).collect()).unwrap_or_default()
}
