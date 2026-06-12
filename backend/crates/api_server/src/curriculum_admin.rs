//! Admin API handlers for curriculum data management.
//!
//! POST /api/admin/curriculum/load — load curriculum data from JSON files into DB
//! GET  /api/admin/curriculum/status — check load status of each subject
//! PATCH/POST/DELETE/PUT — individual CRUD operations on plans/stages/tasks/cards

use axum::{extract::{Path, Query}, http::{HeaderMap, StatusCode}, Json, response::IntoResponse};
use serde::{Deserialize, Serialize};
use crate::admin_handlers;
use crate::curriculum_loader;
use crate::db_pool;
use std::path::PathBuf;
use std::fmt;
use std::str::FromStr;

/// 原子写入：写 temp 文件后 rename，防止崩溃产生半截文件
fn atomic_write(path: &std::path::Path, content: &str) -> Result<(), String> {
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, content).map_err(|e| format!("write {}: {}", temp.display(), e))?;
    std::fs::rename(&temp, path).map_err(|e| format!("rename {} -> {}: {}", temp.display(), path.display(), e))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Gap 3: Domain / Subject enums (§2.1)
// ---------------------------------------------------------------------------

/// Curriculum domain enum — 4 domains used for card classification.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub enum Domain {
    #[serde(rename = "language")] Language,
    #[serde(rename = "science")] Science,
    #[serde(rename = "literature")] Literature,
    #[serde(rename = "humanities")] Humanities,
}

impl Domain {
    pub const ALL: &'static [&'static str] = &["language", "science", "literature", "humanities"];
}

impl fmt::Display for Domain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Domain::Language => write!(f, "language"),
            Domain::Science => write!(f, "science"),
            Domain::Literature => write!(f, "literature"),
            Domain::Humanities => write!(f, "humanities"),
        }
    }
}

impl FromStr for Domain {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "language" => Ok(Domain::Language),
            "science" => Ok(Domain::Science),
            "literature" => Ok(Domain::Literature),
            "humanities" => Ok(Domain::Humanities),
            _ => Err(format!("invalid domain '{}', expected one of: {}", s, Domain::ALL.join(", "))),
        }
    }
}

/// Curriculum subject enum — all K12 subjects used in curriculum plans.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub enum Subject {
    #[serde(rename = "english")] English,
    #[serde(rename = "chinese")] Chinese,
    #[serde(rename = "math")] Math,
    #[serde(rename = "physics")] Physics,
    #[serde(rename = "chemistry")] Chemistry,
    #[serde(rename = "biology")] Biology,
    #[serde(rename = "history")] History,
    #[serde(rename = "geography")] Geography,
    #[serde(rename = "politics")] Politics,
    #[serde(rename = "science")] ScienceComprehensive,
    #[serde(rename = "it")] It,
    #[serde(rename = "pe")] Pe,
    #[serde(rename = "art")] Art,
    #[serde(rename = "labor")] Labor,
    #[serde(rename = "japanese")] Japanese,
    #[serde(rename = "russian")] Russian,
    #[serde(rename = "general")] General,
}

impl Subject {
    pub const ALL: &'static [&'static str] = &[
        "english", "chinese", "math", "physics", "chemistry", "biology",
        "history", "geography", "politics", "science", "it", "pe", "art",
        "labor", "japanese", "russian", "general",
    ];
}

impl fmt::Display for Subject {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Subject::English => write!(f, "english"),
            Subject::Chinese => write!(f, "chinese"),
            Subject::Math => write!(f, "math"),
            Subject::Physics => write!(f, "physics"),
            Subject::Chemistry => write!(f, "chemistry"),
            Subject::Biology => write!(f, "biology"),
            Subject::History => write!(f, "history"),
            Subject::Geography => write!(f, "geography"),
            Subject::Politics => write!(f, "politics"),
            Subject::ScienceComprehensive => write!(f, "science"),
            Subject::It => write!(f, "it"),
            Subject::Pe => write!(f, "pe"),
            Subject::Art => write!(f, "art"),
            Subject::Labor => write!(f, "labor"),
            Subject::Japanese => write!(f, "japanese"),
            Subject::Russian => write!(f, "russian"),
            Subject::General => write!(f, "general"),
        }
    }
}

impl FromStr for Subject {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "english" => Ok(Subject::English),
            "chinese" => Ok(Subject::Chinese),
            "math" => Ok(Subject::Math),
            "physics" => Ok(Subject::Physics),
            "chemistry" => Ok(Subject::Chemistry),
            "biology" => Ok(Subject::Biology),
            "history" => Ok(Subject::History),
            "geography" => Ok(Subject::Geography),
            "politics" => Ok(Subject::Politics),
            "science" => Ok(Subject::ScienceComprehensive),
            "it" => Ok(Subject::It),
            "pe" => Ok(Subject::Pe),
            "art" => Ok(Subject::Art),
            "labor" => Ok(Subject::Labor),
            "japanese" => Ok(Subject::Japanese),
            "russian" => Ok(Subject::Russian),
            "general" => Ok(Subject::General),
            _ => Err(format!("invalid subject '{}', expected one of: {}", s, Subject::ALL.join(", "))),
        }
    }
}

// ---------------------------------------------------------------------------
// Gap 6: card_type normalization helper (§2.3)
// ---------------------------------------------------------------------------

/// Old card_type values that should be normalized to "text" or "concept".
const OLD_CARD_TYPES: &[&str] = &[
    "dialogue", "informational", "opinion", "letter", "biography",
    "report", "speech", "instruction", "play", "review",
];

/// Normalize card_type based on domain.
/// - language → "text" for old sub-types
/// - science/humanities → "concept" for old sub-types
/// - Otherwise preserve original value
fn normalize_card_type(domain: &str, card_type: &str) -> String {
    if !OLD_CARD_TYPES.contains(&card_type) {
        return card_type.to_string();
    }
    match domain {
        "language" => "text".to_string(),
        "science" | "humanities" => "concept".to_string(),
        _ => card_type.to_string(),
    }
}

fn err_response(code: StatusCode, msg: &str) -> axum::response::Response {
    (code, Json(serde_json::json!({"error": msg}))).into_response()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn data_dir() -> PathBuf {
    PathBuf::from(std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v4".to_string()))
}
fn plans_dir() -> PathBuf { data_dir().join("plans") }
fn cards_dir() -> PathBuf { data_dir().join("cards") }
fn plan_path(subject: &str) -> PathBuf { plans_dir().join(format!("{}.json", subject)) }
fn sub_table_name(domain: &str) -> String { format!("prebuilt_{}_cards.json", domain) }

/// Auto git commit after writing JSON files, silently skip if git not available.
fn auto_git_commit(subject: &str, action: &str) {
    let data_dir_str = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v4".to_string());
    let data_dir = std::path::Path::new(&data_dir_str);
    // Walk up to find the parent that has .git
    let mut git_dir = data_dir.to_path_buf();
    loop {
        if git_dir.join(".git").exists() {
            let ts = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
            let msg = format!("curriculum: {} - {} ({})", subject, action, ts);
            let _ = std::process::Command::new("git")
                .args(["-C", &git_dir.to_string_lossy(), "add", "v4/"])
                .output();
            let _ = std::process::Command::new("git")
                .args(["-C", &git_dir.to_string_lossy(), "commit", "-m", &msg])
                .output();
            break;
        }
        if !git_dir.pop() { break; }
    }
}

fn load_plan_json(subject: &str) -> Result<serde_json::Value, String> {
    let p = plan_path(subject);
    serde_json::from_str(&std::fs::read_to_string(&p).map_err(|e| format!("read {}: {}", p.display(), e))?)
        .map_err(|e| format!("parse {}: {}", p.display(), e))
}
fn save_plan_json(subject: &str, v: &serde_json::Value) -> Result<(), String> {
    let p = plan_path(subject);
    let content = serde_json::to_string_pretty(v).map_err(|e| format!("serialize: {}", e))?;
    atomic_write(&p, &content)?;
    auto_git_commit(subject, "plan");
    Ok(())
}
fn load_parent_cards(domain: &str) -> Result<Vec<serde_json::Value>, String> {
    let p = cards_dir().join(domain).join("prebuilt_cards.json");
    if !p.exists() { return Ok(vec![]); }
    serde_json::from_str(&std::fs::read_to_string(&p).map_err(|e| format!("read {}: {}", p.display(), e))?)
        .map_err(|e| format!("parse {}: {}", p.display(), e))
}
fn save_parent_cards(domain: &str, cards: &[serde_json::Value]) -> Result<(), String> {
    let p = cards_dir().join(domain).join("prebuilt_cards.json");
    let content = serde_json::to_string_pretty(cards).map_err(|e| format!("serialize: {}", e))?;
    atomic_write(&p, &content)?;
    auto_git_commit(&format!("cards/{}", domain), "parent");
    Ok(())
}
fn load_sub_cards(domain: &str) -> Result<Vec<serde_json::Value>, String> {
    let p = cards_dir().join(domain).join(sub_table_name(domain));
    if !p.exists() { return Ok(vec![]); }
    serde_json::from_str(&std::fs::read_to_string(&p).map_err(|e| format!("read {}: {}", p.display(), e))?)
        .map_err(|e| format!("parse {}: {}", p.display(), e))
}
fn save_sub_cards(domain: &str, cards: &[serde_json::Value]) -> Result<(), String> {
    let p = cards_dir().join(domain).join(sub_table_name(domain));
    let content = serde_json::to_string_pretty(cards).map_err(|e| format!("serialize: {}", e))?;
    atomic_write(&p, &content)?;
    auto_git_commit(&format!("cards/{}", domain), "sub");
    Ok(())
}

/// Extract plan_id from plan JSON, defaulting to "{subject}_plan".
fn get_plan_id(plan: &serde_json::Value, subject: &str) -> String {
    plan["id"].as_str().map(|s| s.to_string()).unwrap_or_else(|| format!("{}_plan", subject))
}

/// Find which domain a card belongs to by scanning all domain JSON files.
fn find_card_domain(card_id: &str) -> Option<(String, usize)> {
    for domain in &["science", "language", "literature", "humanities"] {
        if let Ok(cards) = load_parent_cards(domain) {
            for (i, c) in cards.iter().enumerate() {
                if c["id"].as_str() == Some(card_id) {
                    return Some((domain.to_string(), i));
                }
            }
        }
    }
    None
}

/// Allowed sub-card fields for all domains.
const SUB_DOMAIN_FIELDS: &[&str] = &[
    "definition", "key_elements", "applications", "related_concepts",
    "formula", "graph", "source", "pronunciation", "pos", "definitions",
    "related_phrases", "structure_meta", "level", "full_text", "translation",
    "author", "genre", "node_type", "body", "period", "region", "tags",
];

// ---------------------------------------------------------------------------
// Existing P0 types & handlers
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct CurriculumLoadRequest {
    pub subjects: Vec<String>,
}

#[derive(Serialize, Clone)]
pub struct SubjectLoadResult {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stages: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tasks: Option<i64>,
}

#[derive(Serialize)]
pub struct CurriculumLoadResponse {
    pub loaded: std::collections::HashMap<String, SubjectLoadResult>,
}

/// POST /api/admin/curriculum/load
pub async fn curriculum_load_handler(
    headers: HeaderMap,
    Json(input): Json<CurriculumLoadRequest>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }
    let conn = db_pool::get_conn();
    let pd = plans_dir();

    let mut result = std::collections::HashMap::new();
    let mut to_load: Vec<String> = Vec::new();
    let mut not_found: Vec<String> = Vec::new();

    for subject in &input.subjects {
        if pd.join(format!("{}.json", subject)).exists() {
            to_load.push(subject.clone());
        } else {
            not_found.push(subject.clone());
        }
    }

    for subject in &to_load {
        conn.execute("DELETE FROM prebuilt_tasks WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject]).ok();
        conn.execute("DELETE FROM prebuilt_stages WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject]).ok();
        conn.execute("DELETE FROM prebuilt_plans WHERE subject=?1", rusqlite::params![subject]).ok();
    }
    if !to_load.is_empty() {
        let filter = to_load.clone();
        if let Err(e) = curriculum_loader::write_prebuilt_to_db(&conn, Some(&filter)) {
            return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("Failed to load curriculum: {}", e));
        }
    }

    for subject in &input.subjects {
        if not_found.contains(subject) {
            result.insert(subject.clone(), SubjectLoadResult { status: "not_found".to_string(), stages: None, tasks: None });
            continue;
        }
        let stages: i64 = conn.query_row("SELECT COUNT(*) FROM prebuilt_stages WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject], |row| row.get(0)).unwrap_or(0);
        let tasks: i64 = conn.query_row("SELECT COUNT(*) FROM prebuilt_tasks WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject], |row| row.get(0)).unwrap_or(0);
        result.insert(subject.clone(), SubjectLoadResult { status: "ok".to_string(), stages: Some(stages), tasks: Some(tasks) });
    }
    Json(CurriculumLoadResponse { loaded: result }).into_response()
}

#[derive(Serialize)]
pub struct SubjectStatus {
    pub subject: String,
    pub display_name: String,
    pub json_exists: bool,
    pub loaded: bool,
    pub stages_count: i64,
    pub tasks_count: i64,
}
#[derive(Serialize)]
pub struct CurriculumStatusResponse { pub subjects: Vec<SubjectStatus> }

/// GET /api/admin/curriculum/status
pub async fn curriculum_status_handler(headers: HeaderMap) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }
    let conn = db_pool::get_conn();
    let pd = plans_dir();
    let subject_names: std::collections::HashMap<&str, &str> = [
        ("english","英语"),("chinese","语文"),("math","数学"),
        ("physics","物理"),("chemistry","化学"),("biology","生物"),
        ("history","历史"),("geography","地理"),("politics","政治"),
        ("science","科学"),("it","信息技术"),("pe","体育"),
        ("art","艺术"),("labor","劳动"),("japanese","日语"),("russian","俄语"),
    ].iter().cloned().collect();

    let mut subjects: Vec<SubjectStatus> = Vec::new();
    if let Ok(dir) = std::fs::read_dir(&pd) {
        for entry in dir.flatten() {
            let path = entry.path();
            if !path.is_file() { continue; }
            let fname = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.ends_with(".json") => n.to_string(),
                _ => continue,
            };
            let subject = fname.strip_suffix(".json").unwrap_or("").to_string();
            let display_name = subject_names.get(subject.as_str()).unwrap_or(&"未知").to_string();
            let loaded = conn.query_row("SELECT COUNT(*) FROM prebuilt_plans WHERE subject=?1", rusqlite::params![subject], |row| row.get::<_, i64>(0)).unwrap_or(0) > 0;
            let stages_count: i64 = if loaded { conn.query_row("SELECT COUNT(*) FROM prebuilt_stages WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject], |row| row.get(0)).unwrap_or(0) } else { 0 };
            let tasks_count: i64 = if loaded { conn.query_row("SELECT COUNT(*) FROM prebuilt_tasks WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject], |row| row.get(0)).unwrap_or(0) } else { 0 };
            subjects.push(SubjectStatus { subject, display_name, json_exists: true, loaded, stages_count, tasks_count });
        }
    }
    Json(CurriculumStatusResponse { subjects }).into_response()
}

// ═══════════════════════════════════════════════════════════
// PATCH — 修改单个实体
// ═══════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct PatchFields {
    #[serde(flatten)]
    pub fields: std::collections::HashMap<String, serde_json::Value>,
}

/// PATCH /api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}
pub async fn patch_stage_handler(
    headers: HeaderMap,
    Path((subject, stage_id)): Path<(String, String)>,
    Json(input): Json<PatchFields>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    if input.fields.contains_key("id") {
        return err_response(StatusCode::BAD_REQUEST, "id field is not allowed");
    }
    let conn = db_pool::get_conn();

    // 1. Load & update JSON
    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let plan_id = get_plan_id(&plan, &subject); // extract BEFORE mutable borrow
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let idx = match stages.iter().position(|s| s["id"].as_str() == Some(&stage_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("stage {} not found", stage_id)),
    };
    for (key, val) in &input.fields {
        stages[idx][key] = val.clone();
    }
    if let Err(e) = save_plan_json(&subject, &plan) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e);
    }

    // 2. Update DB
    for key in &["name", "grade_band", "sort_order"] {
        if let Some(val) = input.fields.get(*key) {
            if let Some(s) = val.as_str() {
                let sql = format!("UPDATE prebuilt_stages SET {}=?1 WHERE id=?2 AND plan_id=?3", key);
                conn.execute(&sql, rusqlite::params![s, stage_id, plan_id]).ok();
            }
        }
    }
    if let Some(val) = input.fields.get("sort") {
        if let Some(s) = val.as_str() {
            conn.execute("UPDATE prebuilt_stages SET sort_order=?1 WHERE id=?2 AND plan_id=?3",
                rusqlite::params![s, stage_id, plan_id]).ok();
        }
    }

    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// PATCH /api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks/{task_id}
pub async fn patch_task_handler(
    headers: HeaderMap,
    Path((subject, stage_id, task_id)): Path<(String, String, String)>,
    Json(input): Json<PatchFields>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    if input.fields.contains_key("id") {
        return err_response(StatusCode::BAD_REQUEST, "id field is not allowed");
    }
    let conn = db_pool::get_conn();

    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let si = match stages.iter().position(|s| s["id"].as_str() == Some(&stage_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("stage {} not found", stage_id)),
    };
    let tasks = match stages[si]["tasks"].as_array_mut() {
        Some(t) => t, None => return err_response(StatusCode::NOT_FOUND, "no tasks in stage"),
    };
    let ti = match tasks.iter().position(|t| t["id"].as_str() == Some(&task_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("task {} not found", task_id)),
    };
    for (key, val) in &input.fields {
        tasks[ti][key] = val.clone();
    }
    if let Err(e) = save_plan_json(&subject, &plan) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e);
    }

    // Update DB
    let allowed = ["name", "task_key", "prompt_mode", "card_ids", "dependencies", "origin", "sort_order", "focus"];
    for key in &allowed {
        if let Some(val) = input.fields.get(*key) {
            if let Some(s) = val.as_str() {
                let sql = format!("UPDATE prebuilt_tasks SET {}=?1 WHERE id=?2", key);
                conn.execute(&sql, rusqlite::params![s, task_id]).ok();
            } else if let Some(arr) = val.as_array() {
                let s = serde_json::to_string(arr).unwrap_or_default();
                let sql = format!("UPDATE prebuilt_tasks SET {}=?1 WHERE id=?2", key);
                conn.execute(&sql, rusqlite::params![s, task_id]).ok();
            }
        }
    }
    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// PATCH /api/admin/curriculum/subject/{subject}/cards/{card_id}
pub async fn patch_card_handler(
    headers: HeaderMap,
    Path((_subject, card_id)): Path<(String, String)>,
    Json(input): Json<PatchFields>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    if input.fields.contains_key("id") {
        return err_response(StatusCode::BAD_REQUEST, "id field is not allowed");
    }
    let conn = db_pool::get_conn();

    let (domain, idx) = match find_card_domain(&card_id) {
        Some(d) => d, None => return err_response(StatusCode::NOT_FOUND, &format!("card {} not found", card_id)),
    };

    // Normalize card_type (Gap 6)
    let mut normalized_fields = input.fields.clone();
    if let Some(card_type_val) = normalized_fields.get("card_type") {
        if let Some(raw_type) = card_type_val.as_str() {
            let normalized = normalize_card_type(&domain, raw_type);
            normalized_fields.insert("card_type".to_string(), serde_json::Value::String(normalized));
        }
    }

    // Parent JSON
    let mut parents = match load_parent_cards(&domain) {
        Ok(c) => c, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    for (key, val) in &normalized_fields { parents[idx][key] = val.clone(); }
    if let Err(e) = save_parent_cards(&domain, &parents) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    // Sub JSON
    let has_sub = normalized_fields.keys().any(|k| SUB_DOMAIN_FIELDS.contains(&k.as_str()));
    if has_sub {
        if let Ok(mut subs) = load_sub_cards(&domain) {
            if let Some(si) = subs.iter().position(|c| c["id"].as_str() == Some(&card_id)) {
                for (key, val) in &normalized_fields {
                    if SUB_DOMAIN_FIELDS.contains(&key.as_str()) { subs[si][key] = val.clone(); }
                }
                save_sub_cards(&domain, &subs).ok();
            }
        }
    }

    // DB parent
    for key in &["front", "card_type", "domain", "subject", "grade_band"] {
        if let Some(val) = input.fields.get(*key) {
            if let Some(s) = val.as_str() {
                conn.execute(&format!("UPDATE prebuilt_cards SET {}=?1 WHERE id=?2", key), rusqlite::params![s, card_id]).ok();
            }
        }
    }
    // DB sub
    if has_sub {
        let sub_tbl = format!("prebuilt_{}_cards", domain);
        let cols: Vec<String> = (|| -> Option<Vec<String>> {
            let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", sub_tbl)).ok()?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(1)).ok()?;
            Some(rows.flatten().filter(|c| c != "id").collect())
        })().unwrap_or_default();
        for key in input.fields.keys() {
            if !cols.contains(key) { continue; }
            if let Some(val) = input.fields.get(key) {
                if let Some(s) = val.as_str() {
                    conn.execute(&format!("UPDATE {} SET {}=?1 WHERE id=?2", sub_tbl, key), rusqlite::params![s, card_id]).ok();
                }
            }
        }
    }
    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// PATCH /api/admin/curriculum/subject/{subject}/plan — 修改计划元数据
pub async fn patch_plan_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Json(input): Json<PatchFields>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    if input.fields.contains_key("id") || input.fields.contains_key("subject") {
        return err_response(StatusCode::BAD_REQUEST, "id/subject fields are not allowed");
    }
    let conn = db_pool::get_conn();

    // 1. Load & update plan JSON
    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let allowed_meta = ["title", "goal", "author", "display_name", "visible", "theme_color", "theme_icon", "domain", "grade_band"];
    for (key, val) in &input.fields {
        if allowed_meta.contains(&key.as_str()) {
            plan[key] = val.clone();
        }
    }
    if let Err(e) = save_plan_json(&subject, &plan) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e);
    }

    // 2. Update DB — prebuilt_plans columns
    let plan_id = get_plan_id(&plan, &subject);
    let db_cols = ["title", "goal", "author", "display_name", "visible", "theme_color", "theme_icon", "domain", "grade_band"];
    for key in &db_cols {
        if let Some(val) = input.fields.get(*key) {
            if let Some(s) = val.as_str() {
                let sql = format!("UPDATE prebuilt_plans SET {}=?1 WHERE id=?2", key);
                conn.execute(&sql, rusqlite::params![s, plan_id]).ok();
            } else if let Some(b) = val.as_bool() {
                // visible is stored as INTEGER
                let sql = format!("UPDATE prebuilt_plans SET {}=?1 WHERE id=?2", key);
                conn.execute(&sql, rusqlite::params![if b { 1 } else { 0 }, plan_id]).ok();
            }
        }
    }

    Json(serde_json::json!({"status": "ok"})).into_response()
}

// ═══════════════════════════════════════════════════════════
// POST — 新增实体
// ═══════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct NewStageBody {
    pub name: String,
    #[serde(default)]
    pub grade_band: String,
    #[serde(default)]
    pub sort: String,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

/// POST /api/admin/curriculum/subject/{subject}/plan/stages
pub async fn post_stage_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Json(input): Json<NewStageBody>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();
    let stage_id_str = uuid::Uuid::new_v4().to_string();

    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let plan_id = get_plan_id(&plan, &subject);
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let mut new_stage = serde_json::json!({"id": stage_id_str, "name": input.name, "grade_band": input.grade_band, "sort": input.sort, "tasks": []});
    for (k, v) in &input.extra { if k != "tasks" { new_stage[k] = v.clone(); } }
    let stages_len = stages.len();
    stages.push(new_stage);
    if let Err(e) = save_plan_json(&subject, &plan) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    let sort_val = if input.sort.is_empty() { (stages_len as i64).to_string() } else { input.sort.clone() };
    conn.execute("INSERT INTO prebuilt_stages (id, plan_id, name, sort_order, grade_band) VALUES (?1,?2,?3,?4,?5)",
        rusqlite::params![stage_id_str, plan_id, input.name, sort_val, input.grade_band]).ok();

    Json(serde_json::json!({"id": stage_id_str, "status": "ok"})).into_response()
}

#[derive(Deserialize)]
pub struct NewTaskBody {
    pub name: String,
    #[serde(default)]
    pub task_key: String,
    #[serde(default)]
    pub prompt_mode: String,
    #[serde(default)]
    pub card_ids: Vec<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub focus: String,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

/// POST /api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks
pub async fn post_task_handler(
    headers: HeaderMap,
    Path((subject, stage_id)): Path<(String, String)>,
    Json(input): Json<NewTaskBody>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();
    let task_id_str = uuid::Uuid::new_v4().to_string();

    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let plan_id = get_plan_id(&plan, &subject);
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let si = match stages.iter().position(|s| s["id"].as_str() == Some(&stage_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("stage {} not found", stage_id)),
    };
    let tasks = match stages[si]["tasks"].as_array_mut() {
        Some(t) => t, None => return err_response(StatusCode::NOT_FOUND, "no tasks array in stage"),
    };
    let origin = if input.origin.is_empty() { "admin".to_string() } else { input.origin.clone() };
    let mut new_task = serde_json::json!({
        "id": task_id_str, "name": input.name, "task_key": input.task_key,
        "prompt_mode": input.prompt_mode, "card_ids": input.card_ids, "dependencies": input.dependencies,
        "origin": origin,
    });
    if !input.focus.is_empty() { new_task["focus"] = serde_json::Value::String(input.focus.clone()); }
    for (k, v) in &input.extra { new_task[k] = v.clone(); }
    let sort_order = (tasks.len() as i64).to_string();
    new_task["sort_order"] = serde_json::Value::String(sort_order.clone());
    tasks.push(new_task);
    if let Err(e) = save_plan_json(&subject, &plan) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    conn.execute(
        "INSERT INTO prebuilt_tasks (id, plan_id, stage_id, name, task_key, prompt_mode, card_ids, dependencies, origin, sort_order) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
        rusqlite::params![task_id_str, plan_id, stage_id, input.name, input.task_key, input.prompt_mode,
            serde_json::to_string(&input.card_ids).unwrap_or_default(),
            serde_json::to_string(&input.dependencies).unwrap_or_default(),
            origin, sort_order,
        ],
    ).ok();

    Json(serde_json::json!({"id": task_id_str, "status": "ok"})).into_response()
}

#[derive(Deserialize)]
pub struct NewCardBody {
    pub front: String,
    pub domain: String,
    #[serde(default)]
    pub card_type: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub grade_band: String,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

/// POST /api/admin/curriculum/subject/{subject}/cards
pub async fn post_card_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Json(input): Json<NewCardBody>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();
    let card_id_str = uuid::Uuid::new_v4().to_string();
    let cid_clone = card_id_str.clone(); // for DB insertion later

    // Normalize card_type (Gap 6)
    let normalized_card_type = normalize_card_type(&input.domain, &input.card_type);

    // 1. Parent JSON
    let mut parents = load_parent_cards(&input.domain).unwrap_or_default();
    let mut new_card = serde_json::json!({
        "id": card_id_str, "front": input.front, "card_type": normalized_card_type,
        "domain": input.domain, "subject": input.subject, "grade_band": input.grade_band,
    });
    for (k, v) in &input.extra { new_card[k] = v.clone(); }
    parents.push(new_card);
    if let Err(e) = save_parent_cards(&input.domain, &parents) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    // 2. Sub JSON
    let has_sub = input.extra.iter().any(|(k, _)| SUB_DOMAIN_FIELDS.contains(&k.as_str()));
    if has_sub {
        let mut subs = load_sub_cards(&input.domain).unwrap_or_default();
        let mut new_sub = serde_json::json!({"id": cid_clone.clone()});
        for (k, v) in &input.extra { if SUB_DOMAIN_FIELDS.contains(&k.as_str()) { new_sub[k] = v.clone(); } }
        subs.push(new_sub);
        save_sub_cards(&input.domain, &subs).ok();
    }

    // 3. DB parent
    conn.execute("INSERT INTO prebuilt_cards (id, card_type, domain, subject, grade_band, front) VALUES (?1,?2,?3,?4,?5,?6)",
        rusqlite::params![cid_clone.clone(), normalized_card_type, input.domain, subject, input.grade_band, input.front]).ok();

    // 4. DB sub
    if has_sub {
        let sub_tbl = format!("prebuilt_{}_cards", input.domain);
        let cols: Vec<String> = (|| -> Option<Vec<String>> {
            let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", sub_tbl)).ok()?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(1)).ok()?;
            Some(rows.flatten().filter(|c| c != "id").collect())
        })().unwrap_or_default();
        let mut col_names: Vec<&str> = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(cid_clone.clone())];
        for col in &cols {
            if input.extra.contains_key(col) {
                col_names.push(col);
                params.push(Box::new(input.extra[col].as_str().unwrap_or("").to_string()));
            }
        }
        if !col_names.is_empty() {
            let placeholders: Vec<String> = (2..=params.len()).map(|i| format!("?{}", i)).collect();
            let sql = format!("INSERT INTO {} (id, {}) VALUES (?1, {})", sub_tbl, col_names.join(","), placeholders.join(","));
            let refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
            conn.execute(&sql, refs.as_slice()).ok();
        }
    }
    Json(serde_json::json!({"id": cid_clone, "status": "ok"})).into_response()
}

/// POST /api/admin/curriculum/plan
pub async fn post_plan_handler(
    headers: HeaderMap,
    Json(input): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let subject = match input["subject"].as_str() {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return err_response(StatusCode::BAD_REQUEST, "subject is required"),
    };
    let path = plan_path(&subject);
    if path.exists() { return err_response(StatusCode::CONFLICT, &format!("plan {} already exists", subject)); }

    if let Some(p) = path.parent() { std::fs::create_dir_all(p).ok(); }

    // Build plan from request fields, with defaults
    let goal = input.get("goal").and_then(|v| v.as_str()).unwrap_or(&format!("{}学习计划", subject)).to_string();
    let domain = input.get("domain").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let title = input.get("title").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let display_name = input.get("display_name").and_then(|v| v.as_str()).unwrap_or(&subject).to_string();
    let author = input.get("author").and_then(|v| v.as_str()).unwrap_or("admin").to_string();
    let visible = input.get("visible").and_then(|v| v.as_bool()).unwrap_or(true);
    let theme_color = input.get("theme_color").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let theme_icon = input.get("theme_icon").and_then(|v| v.as_str()).unwrap_or("").to_string();

    let plan_id_str = uuid::Uuid::new_v4().to_string();
    let plan = serde_json::json!({
        "subject": subject, "goal": goal, "domain": domain,
        "title": title, "display_name": display_name, "author": author,
        "visible": visible, "theme_color": theme_color, "theme_icon": theme_icon,
        "id": plan_id_str,
        "stages": [],
    });

    let content = match serde_json::to_string_pretty(&plan) {
        Ok(c) => c, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("serialize: {}", e)),
    };
    if let Err(e) = std::fs::write(&path, &content) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("write: {}", e));
    }
    auto_git_commit(&subject, "plan-created");
    Json(serde_json::json!({"subject": subject, "status": "created"})).into_response()
}

// ═══════════════════════════════════════════════════════════
// DELETE — 删除实体
// ═══════════════════════════════════════════════════════════

/// DELETE /api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}
pub async fn delete_stage_handler(
    headers: HeaderMap,
    Path((subject, stage_id)): Path<(String, String)>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();

    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let idx = match stages.iter().position(|s| s["id"].as_str() == Some(&stage_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("stage {} not found", stage_id)),
    };
    stages.remove(idx);
    if let Err(e) = save_plan_json(&subject, &plan) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    conn.execute("DELETE FROM prebuilt_tasks WHERE stage_id=?1", rusqlite::params![stage_id]).ok();
    conn.execute("DELETE FROM prebuilt_stages WHERE id=?1", rusqlite::params![stage_id]).ok();
    Json(serde_json::json!({"status": "deleted"})).into_response()
}

/// DELETE /api/admin/curriculum/subject/{subject}/plan/stages/{stage_id}/tasks/{task_id}
pub async fn delete_task_handler(
    headers: HeaderMap,
    Path((subject, stage_id, task_id)): Path<(String, String, String)>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();

    let mut plan = match load_plan_json(&subject) {
        Ok(p) => p, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    let stages = match plan["stages"].as_array_mut() {
        Some(s) => s, None => return err_response(StatusCode::NOT_FOUND, "no stages in plan"),
    };
    let si = match stages.iter().position(|s| s["id"].as_str() == Some(&stage_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("stage {} not found", stage_id)),
    };
    let tasks = match stages[si]["tasks"].as_array_mut() {
        Some(t) => t, None => return err_response(StatusCode::NOT_FOUND, "no tasks in stage"),
    };
    let ti = match tasks.iter().position(|t| t["id"].as_str() == Some(&task_id)) {
        Some(i) => i, None => return err_response(StatusCode::NOT_FOUND, &format!("task {} not found", task_id)),
    };
    tasks.remove(ti);
    if let Err(e) = save_plan_json(&subject, &plan) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    conn.execute("DELETE FROM prebuilt_tasks WHERE id=?1", rusqlite::params![task_id]).ok();
    Json(serde_json::json!({"status": "deleted"})).into_response()
}

/// DELETE /api/admin/curriculum/subject/{subject}/cards/{card_id}
pub async fn delete_card_handler(
    headers: HeaderMap,
    Path((_subject, card_id)): Path<(String, String)>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let conn = db_pool::get_conn();

    let (domain, idx) = match find_card_domain(&card_id) {
        Some(d) => d, None => return err_response(StatusCode::NOT_FOUND, &format!("card {} not found", card_id)),
    };

    let mut parents = match load_parent_cards(&domain) {
        Ok(c) => c, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    parents.remove(idx);
    if let Err(e) = save_parent_cards(&domain, &parents) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    let mut subs = load_sub_cards(&domain).unwrap_or_default();
    if let Some(si) = subs.iter().position(|c| c["id"].as_str() == Some(&card_id)) {
        subs.remove(si);
        save_sub_cards(&domain, &subs).ok();
    }

    conn.execute("DELETE FROM prebuilt_cards WHERE id=?1", rusqlite::params![card_id]).ok();
    for tbl in &["prebuilt_science_cards", "prebuilt_language_cards", "prebuilt_literature_cards", "prebuilt_humanities_cards"] {
        conn.execute(&format!("DELETE FROM {} WHERE id=?1", tbl), rusqlite::params![card_id]).ok();
    }
    Json(serde_json::json!({"status": "deleted"})).into_response()
}

// ═══════════════════════════════════════════════════════════
// Card Relations CRUD
// ═══════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct RelationsQuery {
    pub card_id: Option<String>,
}

#[derive(Serialize)]
pub struct RelationRow {
    pub id: String,
    pub from_id: String,
    pub from_type: String,
    pub to_id: String,
    pub to_type: String,
    pub relation_type: String,
    pub description: String,
}

#[derive(Serialize)]
pub struct RelationsListResponse {
    pub relations: Vec<RelationRow>,
}

#[derive(Deserialize)]
pub struct CreateRelationBody {
    pub from_id: String,
    pub from_type: String,
    pub to_id: String,
    pub to_type: String,
    pub relation_type: String,
    #[serde(default)]
    pub description: String,
}

/// GET /api/admin/curriculum/subject/{subject}/relations?card_id=xxx
pub async fn list_relations_handler(
    headers: HeaderMap,
    Path(_subject): Path<String>,
    Query(q): Query<RelationsQuery>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }
    let conn = db_pool::get_conn();

    let relations: Vec<RelationRow> = if let Some(card_id) = &q.card_id {
        let sql = "SELECT id, from_id, from_type, to_id, to_type, relation_type, description \
                   FROM card_relations WHERE (from_id=?1 OR to_id=?1) AND user_id IS NULL \
                   ORDER BY sort_order";
        let mut stmt = match conn.prepare(sql) {
            Ok(s) => s,
            Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("db query: {}", e)),
        };
        let result: Vec<RelationRow> = match stmt.query_map(rusqlite::params![card_id], |row| {
            Ok(RelationRow {
                id: row.get(0)?,
                from_id: row.get(1)?,
                from_type: row.get(2)?,
                to_id: row.get(3)?,
                to_type: row.get(4)?,
                relation_type: row.get(5)?,
                description: row.get(6)?,
            })
        }) {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => vec![],
        };
        result
    } else {
        // Return all prebuilt relations for this subject (no card_id filter)
        let sql = "SELECT r.id, r.from_id, r.from_type, r.to_id, r.to_type, r.relation_type, r.description \
                   FROM card_relations r \
                   INNER JOIN prebuilt_cards pc ON (r.from_id = pc.id OR r.to_id = pc.id) \
                   WHERE pc.subject=?1 AND r.user_id IS NULL \
                   ORDER BY r.sort_order";
        let mut stmt = match conn.prepare(sql) {
            Ok(s) => s,
            Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("db query: {}", e)),
        };
        let result: Vec<RelationRow> = match stmt.query_map(rusqlite::params![_subject], |row| {
            Ok(RelationRow {
                id: row.get(0)?,
                from_id: row.get(1)?,
                from_type: row.get(2)?,
                to_id: row.get(3)?,
                to_type: row.get(4)?,
                relation_type: row.get(5)?,
                description: row.get(6)?,
            })
        }) {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => vec![],
        };
        result
    };

    // Deduplicate by id (a relation may match both from and to sides)
    let mut seen = std::collections::HashSet::new();
    let unique: Vec<RelationRow> = relations.into_iter()
        .filter(|r| seen.insert(r.id.clone()))
        .collect();

    Json(RelationsListResponse { relations: unique }).into_response()
}

/// POST /api/admin/curriculum/subject/{subject}/relations
pub async fn create_relation_handler(
    headers: HeaderMap,
    Path(_subject): Path<String>,
    Json(input): Json<CreateRelationBody>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }
    let conn = db_pool::get_conn();
    let relation_id = uuid::Uuid::new_v4().to_string();

    // Get max sort_order for ordering
    let max_sort: i64 = conn.query_row(
        "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM card_relations WHERE user_id IS NULL",
        [],
        |row| row.get(0),
    ).unwrap_or(0);

    if let Err(e) = conn.execute(
        "INSERT INTO card_relations (id, from_type, from_id, to_type, to_id, relation_type, description, sort_order) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        rusqlite::params![relation_id, input.from_type, input.from_id, input.to_type, input.to_id, input.relation_type, input.description, max_sort],
    ) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("insert relation: {}", e));
    }

    Json(serde_json::json!({"id": relation_id, "status": "ok"})).into_response()
}

/// DELETE /api/admin/curriculum/subject/{subject}/relations/{relation_id}
pub async fn delete_relation_handler(
    headers: HeaderMap,
    Path((_subject, relation_id)): Path<(String, String)>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }
    let conn = db_pool::get_conn();

    conn.execute("DELETE FROM card_relations WHERE id=?1 AND user_id IS NULL",
        rusqlite::params![relation_id]).ok();

    Json(serde_json::json!({"status": "deleted"})).into_response()
}

// ═══════════════════════════════════════════════════════════
// Rollback — 回滚指定 commit 的 v4/ 数据
// ═══════════════════════════════════════════════════════════

/// Helper: walk up from data_dir to find `.git` directory.
fn find_git_root() -> Option<PathBuf> {
    let data_dir_str = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v4".to_string());
    let p = std::path::Path::new(&data_dir_str);
    let mut git_dir = Some(p.to_path_buf());
    loop {
        match git_dir.as_ref() {
            Some(d) if d.join(".git").exists() => break,
            Some(d) => {
                let mut parent = d.clone();
                if parent.pop() { git_dir = Some(parent); } else { git_dir = None; break; }
            }
            None => break,
        }
    }
    git_dir
}

#[derive(Deserialize)]
pub struct RollbackRequest {
    pub commit: String,
}

#[derive(Serialize)]
pub struct RollbackResponse {
    pub status: String,
    pub subjects: Vec<String>,
    pub commit: String,
}

/// POST /api/admin/curriculum/rollback
pub async fn rollback_handler(
    headers: HeaderMap,
    Json(input): Json<RollbackRequest>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) {
        return e;
    }

    let git_root = match find_git_root() {
        Some(d) => d,
        None => return err_response(StatusCode::INTERNAL_SERVER_ERROR, "git repository not found"),
    };

    // 1. git checkout {commit} -- v4/
    let output = std::process::Command::new("git")
        .args(["-C", &git_root.to_string_lossy(), "checkout", &input.commit, "--", "v4/"])
        .output();
    match output {
        Ok(o) if o.status.success() => {},
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("git checkout failed: {}", stderr));
        },
        Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("git command failed: {}", e)),
    }

    // 2. Scan plans/ directory for all JSON files
    let pd = plans_dir();
    let mut subjects: Vec<String> = Vec::new();
    if let Ok(dir) = std::fs::read_dir(&pd) {
        for entry in dir.flatten() {
            let path = entry.path();
            if !path.is_file() { continue; }
            let fname = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.ends_with(".json") => n.to_string(),
                _ => continue,
            };
            let subject = fname.strip_suffix(".json").unwrap_or("").to_string();
            if !subject.is_empty() {
                subjects.push(subject);
            }
        }
    }

    if subjects.is_empty() {
        return err_response(StatusCode::NOT_FOUND, "no plan files found after checkout");
    }

    // 3. Re-write to DB
    let conn = db_pool::get_conn();
    // Clear existing data for these subjects
    for subject in &subjects {
        conn.execute("DELETE FROM prebuilt_tasks WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject]).ok();
        conn.execute("DELETE FROM prebuilt_stages WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject]).ok();
        conn.execute("DELETE FROM prebuilt_plans WHERE subject=?1", rusqlite::params![subject]).ok();
    }
    if let Err(e) = curriculum_loader::write_prebuilt_to_db(&conn, Some(&subjects)) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("Failed to reload curriculum: {}", e));
    }

    // 4. Auto-commit rollback action
    let msg = format!("rollback: reverted to {}", &input.commit[..input.commit.len().min(7)]);
    std::process::Command::new("git")
        .args(["-C", &git_root.to_string_lossy(), "add", "v4/"])
        .output().ok();
    std::process::Command::new("git")
        .args(["-C", &git_root.to_string_lossy(), "commit", "-m", &msg])
        .output().ok();

    Json(RollbackResponse {
        status: "ok".to_string(),
        subjects,
        commit: input.commit,
    }).into_response()
}

// ═══════════════════════════════════════════════════════════
// PUT — 批量替换（写 JSON → 按科目重新加载）
// ═══════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct CardsQuery {
    pub domain: String,
}

/// PUT /api/admin/curriculum/subject/{subject}/plan
pub async fn put_plan_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    let path = plan_path(&subject);
    if let Some(p) = path.parent() { std::fs::create_dir_all(p).ok(); }
    let content = match serde_json::to_string_pretty(&input) {
        Ok(c) => c, Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("serialize: {}", e)),
    };
    if let Err(e) = std::fs::write(&path, &content) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("write: {}", e));
    }
    auto_git_commit(&subject, "plan-replaced");

    let conn = db_pool::get_conn();
    let filter = vec![subject.clone()];
    if let Err(e) = curriculum_loader::write_prebuilt_to_db(&conn, Some(&filter)) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("reload: {}", e));
    }
    Json(serde_json::json!({"status": "reloaded", "subject": subject})).into_response()
}

/// PUT /api/admin/curriculum/subject/{subject}/cards?domain=language
pub async fn put_cards_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Query(q): Query<CardsQuery>,
    Json(input): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    let domain = &q.domain;
    let submitted: Vec<serde_json::Value> = if let Some(arr) = input.as_array() {
        arr.clone()
    } else if let Some(arr) = input["cards"].as_array() {
        arr.clone()
    } else {
        return err_response(StatusCode::BAD_REQUEST, "body must be an array or {cards: [...]}");
    };

    let domain_dir = cards_dir().join(domain);
    std::fs::create_dir_all(&domain_dir).ok();

    // Parent cards: keep only those NOT from this subject, then append submitted
    let mut existing = load_parent_cards(domain).unwrap_or_default();
    existing.retain(|c| c["subject"].as_str() != Some(&subject));
    existing.extend(submitted);
    if let Err(e) = save_parent_cards(domain, &existing) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }

    // Sub cards
    if let Some(sub_arr) = input.get("sub_cards").and_then(|v| v.as_array()) {
        let mut subs = load_sub_cards(domain).unwrap_or_default();
        let new_ids: std::collections::HashSet<&str> = sub_arr.iter().filter_map(|c| c["id"].as_str()).collect();
        subs.retain(|c| !new_ids.contains(c["id"].as_str().unwrap_or("")));
        subs.extend(sub_arr.iter().cloned());
        if let Err(e) = save_sub_cards(domain, &subs) { return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e); }
    }

    let conn = db_pool::get_conn();
    let filter = vec![subject.clone()];
    if let Err(e) = curriculum_loader::write_prebuilt_to_db(&conn, Some(&filter)) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("reload: {}", e));
    }
    Json(serde_json::json!({"status": "reloaded", "subject": subject, "domain": domain})).into_response()
}

// ═══════════════════════════════════════════════════════════
// GET — 读取端点
// ═══════════════════════════════════════════════════════════

/// GET /api/admin/curriculum/git-log — 返回最近 10 条 git log
pub async fn git_log_handler(headers: HeaderMap) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    let data_dir = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v4".to_string());
    let p = std::path::Path::new(&data_dir);
    // Walk up to find .git
    let mut git_dir = Some(p.to_path_buf());
    loop {
        match git_dir.as_ref() {
            Some(d) if d.join(".git").exists() => break,
            Some(d) => {
                let mut parent = d.clone();
                if parent.pop() { git_dir = Some(parent); } else { git_dir = None; break; }
            }
            None => break,
        }
    }

    let git_dir = match git_dir {
        Some(d) => d,
        None => return Json(serde_json::json!({"log": []})).into_response(),
    };

    let output = std::process::Command::new("git")
        .args(["-C", &git_dir.to_string_lossy(), "log", "--oneline", "-10", "--", "v4/"])
        .output();
    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return Json(serde_json::json!({"log": []})).into_response(),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut entries: Vec<serde_json::Value> = Vec::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() { continue; }
        // Format: "abc1234 message here"
        if let Some((hash, rest)) = line.split_once(' ') {
            entries.push(serde_json::json!({"hash": hash, "message": rest}));
        } else {
            entries.push(serde_json::json!({"hash": line, "message": ""}));
        }
    }
    Json(serde_json::json!({"log": entries})).into_response()
}

/// GET /api/admin/curriculum/subject/{subject}/plan — 返回完整 plan JSON
pub async fn get_plan_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    match load_plan_json(&subject) {
        Ok(plan) => Json(plan).into_response(),
        Err(e) => err_response(StatusCode::NOT_FOUND, &e),
    }
}

#[derive(Deserialize)]
pub struct ListCardsQuery {
    pub domain: String,
    #[serde(default)]
    pub q: String,
    #[serde(default)]
    pub level: String,
    #[serde(default = "default_limit")]
    pub limit: i64,
    #[serde(default)]
    pub offset: i64,
}
fn default_limit() -> i64 { 20 }

/// GET /api/admin/curriculum/subject/{subject}/cards — 按 domain 列出卡片（支持搜索、过滤、分页）
pub async fn list_cards_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Query(q): Query<ListCardsQuery>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    let parents = match load_parent_cards(&q.domain) {
        Ok(c) => c,
        Err(_) => return Json(serde_json::json!({"cards": [], "total": 0})).into_response(),
    };

    // Load sub-cards and merge domain-specific fields
    let merged = if let Ok(subs) = load_sub_cards(&q.domain) {
        let subs_map: std::collections::HashMap<&str, &serde_json::Value> = subs.iter()
            .filter_map(|s| s["id"].as_str().map(|id| (id, s)))
            .collect();
        parents.into_iter().map(|p| {
            if let Some(sub) = p["id"].as_str().and_then(|id| subs_map.get(id)) {
                let mut m = p;
                if let Some(obj) = sub.as_object() {
                    let existing_keys: std::collections::HashSet<String> = m.as_object()
                        .map(|o| o.keys().cloned().collect())
                        .unwrap_or_default();
                    for (k, v) in obj {
                        if k != "id" && !existing_keys.contains(k.as_str()) {
                            m[k] = v.clone();
                        }
                    }
                }
                m
            } else {
                p
            }
        }).collect()
    } else {
        parents
    };

    // Filter by subject
    let mut filtered: Vec<serde_json::Value> = merged.into_iter()
        .filter(|c| c["subject"].as_str() == Some(&subject))
        .collect();

    // Filter by search query (front or definition/释义)
    let query = q.q.trim().to_lowercase();
    if !query.is_empty() {
        filtered = filtered.into_iter().filter(|c| {
            let front = c["front"].as_str().unwrap_or("").to_lowercase();
            // Also check domain-specific fields
            let extra = match q.domain.as_str() {
                "language" => c["pronunciation"].as_str().or(c["pos"].as_str()).or_else(|| {
                    c["definitions"].as_array().and_then(|a| a.first())
                        .and_then(|v| v.as_str())
                }),
                "science" => c["definition"].as_str(),
                "literature" => c["author"].as_str().or(c["genre"].as_str()),
                "humanities" => c["node_type"].as_str(),
                _ => None,
            };
            let extra_str = extra.unwrap_or("").to_lowercase();
            front.contains(&query) || extra_str.contains(&query)
        }).collect();
    }

    // Filter by level (only for language domain)
    let level_filter = q.level.trim().to_lowercase();
    if !level_filter.is_empty() && q.domain == "language" {
        filtered = filtered.into_iter().filter(|c| {
            c["level"].as_str().map(|l| l.to_lowercase() == level_filter).unwrap_or(false)
        }).collect();
    }

    let total = filtered.len() as i64;
    let offset = q.offset.max(0) as usize;
    let limit = q.limit.max(1) as usize;
    let cards: Vec<serde_json::Value> = filtered.into_iter().skip(offset).take(limit).collect();

    Json(serde_json::json!({"cards": cards, "total": total})).into_response()
}

// ═══════════════════════════════════════════════════════════
// Gap 1: JSON 模版下载 (§5.4)
// ═══════════════════════════════════════════════════════════

fn templates_dir() -> PathBuf {
    let data_dir = std::env::var("COEVO_K12_DATA_DIR").unwrap_or_else(|_| "data/curriculum/v4".to_string());
    let mut p = PathBuf::from(&data_dir);
    // Walk up to find data/curriculum
    loop {
        if p.join("templates").exists() {
            return p.join("templates");
        }
        if !p.pop() { break; }
    }
    // Fallback to absolute path relative to project root
    PathBuf::from("data/curriculum/templates")
}

/// GET /api/admin/curriculum/templates/plan
pub async fn get_plan_template_handler(headers: HeaderMap) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }
    let p = templates_dir().join("plan_template.json");
    match std::fs::read_to_string(&p) {
        Ok(content) => {
            match serde_json::from_str::<serde_json::Value>(&content) {
                Ok(val) => Json(val).into_response(),
                Err(e) => err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("parse template: {}", e)),
            }
        }
        Err(e) => err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("read template: {}", e)),
    }
}

#[derive(Deserialize)]
pub struct CardsTemplateQuery {
    pub domain: String,
}

/// GET /api/admin/curriculum/templates/cards?domain=language
pub async fn get_cards_template_handler(
    headers: HeaderMap,
    Query(q): Query<CardsTemplateQuery>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    // Validate domain using enum
    if Domain::from_str(&q.domain).is_err() {
        return err_response(StatusCode::BAD_REQUEST, &format!("invalid domain '{}', expected: {}", q.domain, Domain::ALL.join(", ")));
    }

    let p = templates_dir().join(format!("cards_{}_template.json", q.domain));
    match std::fs::read_to_string(&p) {
        Ok(content) => {
            match serde_json::from_str::<serde_json::Value>(&content) {
                Ok(val) => Json(val).into_response(),
                Err(e) => err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("parse template: {}", e)),
            }
        }
        Err(e) => err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("read template: {}", e)),
    }
}

// ═══════════════════════════════════════════════════════════
// Gap 2: JSON 数据导入 (§5.5)
// ═══════════════════════════════════════════════════════════

/// Validate imported JSON data using strict field matching rules.
/// Returns Ok(()) if valid, or Err with specific error message.
fn validate_import_json(
    data: &serde_json::Value,
    allowed_fields: &[&str],
    required_fields: &[&str],
    allow_array: bool,
) -> Result<(), String> {
    // Determine if we're dealing with an array or single object
    let items: Vec<&serde_json::Value> = if let Some(arr) = data.as_array() {
        if !allow_array {
            return Err("expected a single JSON object, got an array".to_string());
        }
        arr.iter().collect()
    } else if data.is_object() {
        vec![data]
    } else {
        return Err("expected a JSON object or array".to_string());
    };

    for (item_idx, item) in items.iter().enumerate() {
        let prefix = if items.len() > 1 { format!("[item {}] ", item_idx) } else { String::new() };

        // Get all keys in this item
        let keys: Vec<String> = match item.as_object() {
            Some(map) => map.keys().cloned().collect(),
            None => return Err(format!("{}expected a JSON object", prefix)),
        };

        // Reject keys starting with underscore (internal/comments)
        for key in &keys {
            if key.starts_with('_') { continue; } // skip _comment, _fields etc.
            // Check for id field
            if key == "id" {
                return Err(format!("{}field 'id' is not allowed in import data (id is auto-generated)", prefix));
            }
            // Check field is in allowed list
            if !allowed_fields.contains(&key.as_str()) {
                return Err(format!("{}unexpected field '{}' — allowed fields: {}", prefix, key, allowed_fields.join(", ")));
            }
        }

        // Check required fields
        for req in required_fields {
            if *req == "id" { continue; } // id is never required in import
            if !item.get(req).and_then(|v| if v.is_null() { None } else { Some(v) }).is_some() {
                return Err(format!("{}missing required field '{}'", prefix, req));
            }
        }
    }

    Ok(())
}

const PLAN_ALLOWED_FIELDS: &[&str] = &[
    "title", "goal", "author", "display_name", "domain", "grade_band",
    "visible", "theme_color", "theme_icon", "stages",
];
const PLAN_REQUIRED_FIELDS: &[&str] = &[
    "title", "goal", "display_name", "domain", "grade_band", "stages",
];

const CARD_ALLOWED_FIELDS: &[&str] = &[
    "front", "card_type", "domain", "subject", "grade_band",
    "pronunciation", "pos", "definitions", "related_phrases", "structure_meta", "level",
    "definition", "key_elements", "applications", "related_concepts", "formula", "graph", "source",
    "full_text", "translation", "author", "genre",
    "node_type", "body", "period", "region", "tags",
];
const CARD_REQUIRED_FIELDS: &[&str] = &[
    "front", "card_type", "domain", "subject", "grade_band",
];

#[derive(Deserialize)]
pub struct CardsImportQuery {
    pub domain: String,
}

/// POST /api/admin/curriculum/subject/{subject}/plan/import
pub async fn import_plan_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Json(input): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    // Validate subject
    if Subject::from_str(&subject).is_err() {
        return err_response(StatusCode::BAD_REQUEST, &format!("invalid subject '{}'", subject));
    }

    // Validate JSON structure
    if let Err(e) = validate_import_json(&input, PLAN_ALLOWED_FIELDS, PLAN_REQUIRED_FIELDS, false) {
        return err_response(StatusCode::BAD_REQUEST, &e);
    }

    // Validate domain consistency
    let domain = input["domain"].as_str().unwrap_or("");
    if Domain::from_str(domain).is_err() {
        return err_response(StatusCode::BAD_REQUEST, &format!("invalid domain '{}' in plan data", domain));
    }

    // Ensure the plan doesn't already exist
    let path = plan_path(&subject);
    if path.exists() {
        return err_response(StatusCode::CONFLICT, &format!("plan '{}' already exists, use PUT to replace", subject));
    }

    // Write to file (no id field — it will be auto-generated on load)
    let content = match serde_json::to_string_pretty(&input) {
        Ok(c) => c,
        Err(e) => return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("serialize: {}", e)),
    };
    if let Some(p) = path.parent() { std::fs::create_dir_all(p).ok(); }
    if let Err(e) = std::fs::write(&path, &content) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("write: {}", e));
    }

    // Do NOT trigger loading — show as "未加载"
    Json(serde_json::json!({"status": "imported", "subject": subject, "loaded": false})).into_response()
}

/// POST /api/admin/curriculum/subject/{subject}/cards/import?domain=language
pub async fn import_cards_handler(
    headers: HeaderMap,
    Path(subject): Path<String>,
    Query(q): Query<CardsImportQuery>,
    Json(input): Json<serde_json::Value>,
) -> impl axum::response::IntoResponse {
    if let Err(e) = admin_handlers::verify_admin(&headers) { return e; }

    // Validate subject
    if Subject::from_str(&subject).is_err() {
        return err_response(StatusCode::BAD_REQUEST, &format!("invalid subject '{}'", subject));
    }

    // Validate domain
    let domain = &q.domain;
    if Domain::from_str(domain).is_err() {
        return err_response(StatusCode::BAD_REQUEST, &format!("invalid domain '{}'", domain));
    }

    // Validate JSON structure — must be an array of card objects
    if let Err(e) = validate_import_json(&input, CARD_ALLOWED_FIELDS, CARD_REQUIRED_FIELDS, true) {
        return err_response(StatusCode::BAD_REQUEST, &e);
    }

    let cards: Vec<serde_json::Value> = match input.as_array() {
        Some(arr) => arr.clone(),
        None => return err_response(StatusCode::BAD_REQUEST, "expected a JSON array of cards"),
    };

    // Validate each card's domain matches the query domain
    for (i, card) in cards.iter().enumerate() {
        let card_domain = card["domain"].as_str().unwrap_or("");
        if card_domain != domain {
            return err_response(StatusCode::BAD_REQUEST,
                &format!("[card {}] domain '{}' does not match query domain '{}'", i, card_domain, domain));
        }
        let card_subject = card["subject"].as_str().unwrap_or("");
        if card_subject != subject {
            return err_response(StatusCode::BAD_REQUEST,
                &format!("[card {}] subject '{}' does not match URL subject '{}'", i, card_subject, subject));
        }
    }

    // Write to parent cards file (append to existing, or create new)
    let mut existing = load_parent_cards(domain).unwrap_or_default();
    existing.extend(cards);
    if let Err(e) = save_parent_cards(domain, &existing) {
        return err_response(StatusCode::INTERNAL_SERVER_ERROR, &e);
    }

    // Do NOT trigger loading — show as "未加载"
    Json(serde_json::json!({"status": "imported", "subject": subject, "domain": domain, "loaded": false})).into_response()
}
