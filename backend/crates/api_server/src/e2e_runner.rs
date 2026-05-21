//! E2E Pipeline Test Runner — 共享测试工具
//!
//! 提供 E2E 测试框架的基础设施：
//! - 测试结果 JSON 序列化/反序列化
//! - LLM 对话辅助函数
//! - 测试环境初始化
//! - 结果目录管理

use std::path::PathBuf;
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};

// ── 测试结果结构 ──

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
            source_sentence TEXT, created_at INTEGER,
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
