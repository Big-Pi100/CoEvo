//! Reading-First 模式加载器 — 独立于 curriculum_loader
//!
//! 加载 reading_plans/ 中的课文计划 + cards/ 中的 reading 卡片。
//! 与现有 K12 体系完全并行，不修改任何现有代码。

use std::collections::HashMap;
use std::sync::OnceLock;
use serde::{Deserialize, Serialize};

static READING_DATA: OnceLock<ReadingPrebuilt> = OnceLock::new();

// ── 数据模型 ──

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingPlanFile {
    pub subject: String,
    pub goal: String,
    pub stages: Vec<ReadingStageData>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingStageData {
    pub name: String,
    pub sort: i64,
    #[serde(default)]
    pub grade_band: String,
    #[serde(default)]
    pub prerequisite_stages: Vec<String>,
    #[serde(default)]
    pub tasks: Vec<ReadingTaskData>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingTaskData {
    pub name: String,
    pub sort: i64,
    #[serde(default)]
    pub mode: String,                          // "reading_first" | "nursery_rhyme"
    #[serde(default)]
    pub reading_card_id: Option<String>,       // 关联的 reading 卡 ID
    #[serde(default)]
    pub focus: String,                         // 核心教学点
    #[serde(default)]
    pub extra_points: Vec<String>,             // 顺带教学点
    #[serde(default)]
    pub vocab_card_ids: Vec<String>,           // 本课词卡 ID
    #[serde(default)]
    pub concept_card_ids: Vec<String>,         // 关联概念卡 ID
    #[serde(default)]
    pub lesson_script: String,                 // 教学引导
    #[serde(default)]
    pub gold_cr_ids: Vec<String>,
    #[serde(default)]
    pub status: String,                        // pending | in_progress | completed
}

/// Reading 卡（从 cards/ 中加载）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingCardData {
    pub id: String,
    pub card_type: String,
    pub front: String,
    pub back: Option<String>,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub background: String,
    #[serde(default)]
    pub appreciation: Vec<String>,
    #[serde(default)]
    pub technique: Vec<String>,
    #[serde(default)]
    pub theme: String,
    #[serde(default)]
    pub common_mistakes: String,
    #[serde(default)]
    pub level: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub grade_band: String,
    #[serde(default)]
    pub full_text: String,
    #[serde(default)]
    pub translation: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub characters: Vec<Vec<String>>,
    #[serde(default)]
    pub key_plot: Vec<String>,
    #[serde(default)]
    pub dynasties: String,
    #[serde(default)]
    pub famous_lines: Vec<String>,
    #[serde(default)]
    pub imagery: Vec<String>,
    #[serde(default)]
    pub real_words: Vec<Vec<String>>,
    #[serde(default)]
    pub function_words: Vec<Vec<String>>,
    #[serde(default)]
    pub phonetic_loans: Vec<Vec<String>>,
    #[serde(default)]
    pub sentence_patterns: Vec<String>,
    #[serde(default)]
    pub main_characters: Vec<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct ReadingPrebuilt {
    /// subject → plan
    pub plan_index: HashMap<String, ReadingPlanFile>,
    /// card_id → ReadingCardData
    pub card_index: HashMap<String, ReadingCardData>,
}

// ── 初始化 ──

pub fn init() -> Result<(), String> {
    let base = reading_paths::prebuilt();
    let plans_dir = base.join("reading_plans");
    let cards_dir = base.join("cards").join("reading");

    eprintln!("[READING] init: plans={:?} cards={:?}", plans_dir, cards_dir);

    let mut plan_index: HashMap<String, ReadingPlanFile> = HashMap::new();
    let mut card_index: HashMap<String, ReadingCardData> = HashMap::new();

    // 1. 加载 reading_plans/
    if plans_dir.exists() {
        eprintln!("[READING] reading_plans dir FOUND");
        for entry in std::fs::read_dir(&plans_dir).map_err(|e| format!("read plans dir: {}", e))? {
            let path = entry.map_err(|e| format!("entry: {}", e))?.path();
            if path.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let plan: ReadingPlanFile = load_json(&path)?;
            let subject = plan.subject.clone();
            plan_index.insert(subject, plan);
        }
        tracing::info!("READING: loaded {} plans from {:?}", plan_index.len(), plans_dir);
    } else {
        tracing::warn!("READING: plans dir not found: {:?}", plans_dir);
    }

    // 2. 加载 cards/ 中的 reading 卡（chinese_reading.json + chinese_reading_extended.json）
    if cards_dir.exists() {
        for entry in std::fs::read_dir(&cards_dir).map_err(|e| format!("read cards dir: {}", e))? {
            let path = entry.map_err(|e| format!("entry: {}", e))?.path();
            let fname = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.starts_with("chinese_reading") && n.ends_with(".json") => n.to_string(),
                _ => continue,
            };
            let card_file: serde_json::Value = load_json(&path)?;
            if let Some(cards) = card_file.get("cards").and_then(|v| v.as_array()) {
                for c in cards {
                    let card: ReadingCardData = serde_json::from_value(c.clone())
                        .map_err(|e| format!("parse card in {}: {}", fname, e))?;
                    card_index.insert(card.id.clone(), card);
                }
            }
        }
        tracing::info!("READING: loaded {} cards from {:?}", card_index.len(), cards_dir);
    }

    let data = ReadingPrebuilt { plan_index, card_index };
    eprintln!("[READING] init done: {} plans, {} cards", data.plan_index.len(), data.card_index.len());
    READING_DATA.set(data).map_err(|_| "READING already initialized".to_string())
}

pub fn get() -> Option<&'static ReadingPrebuilt> {
    READING_DATA.get()
}

/// 按 subject 获取 reading plan
pub fn get_plan(subject: &str) -> Option<&'static ReadingPlanFile> {
    get()?.plan_index.get(subject)
}

/// 获取 reading plan 内容（按学段过滤），返回 serde_json::Value
/// 用于 build_plan_context 中合并状态
pub fn get_plan_content(subject: &str, grade_band: &str) -> Option<serde_json::Value> {
    // 直接使用 subject 作为 key（迁移后 conversations.subject 已是英文代码）
    let subject_key = subject;
    let plan = get_plan(subject_key)?;
    let grade_for_filter = match grade_band {
        "g10" | "g11-12" => "g10-12",
        _ => grade_band,
    };
    let filtered: Vec<_> = plan.stages.iter()
        .filter(|s| s.grade_band == grade_for_filter || s.grade_band.is_empty())
        .cloned()
        .collect();
    Some(serde_json::json!({
        "id": format!("{}_reading_plan", subject_key),
        "subject": subject_key,
        "grade_band": grade_band,
        "goal": plan.goal,
        "stages": filtered,
    }))
}

/// 按 card_id 获取 reading 卡
pub fn get_card(card_id: &str) -> Option<&'static ReadingCardData> {
    get()?.card_index.get(card_id)
}

/// 构建当前 task 的 LLM context（含 reading 卡内容）
pub fn build_reading_context(
    plan_json: &serde_json::Value,
    current_task_name: &str,
) -> String {
    let mut ctx = String::new();

    // 注入学段信息（供 prompt 做学段感知教学）
    if let Some(gb) = plan_json.get("grade_band").and_then(|v| v.as_str()) {
        ctx.push_str(&format!("学段: {}\n", gb));
    }

    let stages = match plan_json.get("stages").and_then(|v| v.as_array()) {
        Some(s) => s,
        None => return ctx,
    };

    for stage in stages {
        let tasks = match stage.get("tasks").and_then(|v| v.as_array()) {
            Some(t) => t,
            None => continue,
        };
        for task in tasks {
            let name = task.get("name").and_then(|v| v.as_str()).unwrap_or("");
            if name != current_task_name {
                continue;
            }

            let mode = task.get("mode").and_then(|v| v.as_str()).unwrap_or("reading_first");
            let focus = task.get("focus").and_then(|v| v.as_str()).unwrap_or("");
            let script = task.get("lesson_script").and_then(|v| v.as_str()).unwrap_or("");
            let card_id = task.get("reading_card_id").and_then(|v| v.as_str()).unwrap_or("");

            ctx.push_str(&format!("\n\n## 当前课文任务: {}\n", name));
            ctx.push_str(&format!("教学模式: {}\n", mode));
            ctx.push_str(&format!("核心教学点: {}\n", focus));
            if !script.is_empty() {
                ctx.push_str(&format!("教学引导: {}\n", script));
            }

            // 注入 reading 卡内容
            if !card_id.is_empty() {
                if let Some(card) = get_card(card_id) {
                    ctx.push_str(&"\n### 课文卡\n".to_string());
                    ctx.push_str(&format!("作者: {}\n", card.author));
                    if !card.background.is_empty() {
                        ctx.push_str(&format!("背景: {}\n", card.background));
                    }
                    if !card.full_text.is_empty() {
                        ctx.push_str(&format!("全文:\n{}\n", card.full_text));
                    }
                    if !card.translation.is_empty() {
                        ctx.push_str(&format!("译文:\n{}\n", card.translation));
                    }
                    if !card.summary.is_empty() {
                        ctx.push_str(&format!("概要: {}\n", card.summary));
                    }
                    if !card.appreciation.is_empty() {
                        ctx.push_str("\n### 语句赏析\n");
                        for a in &card.appreciation {
                            ctx.push_str(&format!("- {}\n", a));
                        }
                    }
                    if !card.technique.is_empty() {
                        ctx.push_str("\n### 手法\n");
                        for t in &card.technique {
                            ctx.push_str(&format!("- {}\n", t));
                        }
                    }
                    if !card.theme.is_empty() {
                        ctx.push_str(&format!("\n### 主旨\n{}\n", card.theme));
                    }
                    if !card.common_mistakes.is_empty() {
                        ctx.push_str(&format!("\n### 易错/常考\n{}\n", card.common_mistakes));
                    }
                }
            }

            // 注入词卡
            if let Some(vocab_ids) = task.get("vocab_card_ids").and_then(|v| v.as_array()) {
                if !vocab_ids.is_empty() {
                    ctx.push_str("\n### 本课词卡\n");
                    // 词卡需从 curriculum_loader 的 card_index 获取，此处仅标记
                    ctx.push_str(&format!("关联词卡数量: {}\n", vocab_ids.len()));
                }
            }

            return ctx;
        }
    }
    ctx
}

fn load_json<T: serde::de::DeserializeOwned>(path: &std::path::Path) -> Result<T, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {}", path.display(), e))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("parse {}: {}", path.display(), e))
}

mod reading_paths {
    use std::path::PathBuf;
    pub fn prebuilt() -> PathBuf {
        if let Ok(dir) = std::env::var("COEVO_K12_DATA_DIR") {
            return PathBuf::from(dir);
        }
        let dev_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../data/curriculum/prebuilt");
        if dev_path.join("reading_plans").exists() {
            return dev_path;
        }
        let cwd_path = PathBuf::from("data/curriculum/prebuilt");
        if cwd_path.join("reading_plans").exists() {
            return cwd_path;
        }
        dev_path
    }
}
