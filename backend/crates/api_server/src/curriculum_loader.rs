//! K12 V3 预生成数据加载器
//!
//! 启动时从 data/curriculum/prebuilt/{plans,cards}/ 加载 V3 格式数据
//! 从文件名推断 subject + level，无需数据文件内嵌。
//! 供 /k12/init 路由直接使用。

use std::collections::HashMap;
use std::sync::OnceLock;

static K12_DATA: OnceLock<K12Prebuilt> = OnceLock::new();

// ── 数据模型（V3 格式） ──

/// 顶层索引结构
pub struct K12Prebuilt {
    pub plan_index: HashMap<String, PlanData>,
    pub card_index: HashMap<String, Vec<CardData>>,
}

/// Plan 文件包装（合并格式）：{stages: [...], subject: "...", ...}
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct PlanFile {
    pub subject: Option<String>,
    pub goal: Option<String>,
    pub stages: Vec<StageData>,
    pub total_stages: Option<i64>,
    pub total_tasks: Option<i64>,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct PlanData {
    pub id: String,
    pub goal: String,
    #[serde(default)]
    pub stages: Vec<StageData>,
    pub total_crs: i64,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct StageData {
    pub name: String,
    #[serde(default)]
    pub prerequisite_stages: Vec<String>,
    #[serde(default)]
    pub tasks: Vec<TaskData>,
    #[serde(default)]
    pub grade_band: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct TaskData {
    pub name: String,
    #[serde(default)]
    pub gold_cr_ids: Vec<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    #[serde(default)]
    pub cross_subject_refs: Vec<serde_json::Value>,
    #[serde(default)]
    pub origin: String,
}

/// 卡片文件包装：{"cards": [...]}
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct CardFile {
    pub cards: Vec<CardData>,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct CardData {
    pub id: String,
    pub front: String,
    pub back: String,
    #[serde(default)]
    pub domain: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub grade_band: String,
    #[serde(rename = "card_type", default)]
    pub card_type: String,
    #[serde(default)]
    pub gold_cr_ids: Vec<String>,
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub source_sentence: String,
    #[serde(default)]
    pub plan_task_id: String,
}

// ── 科目 key 映射 ──

/// 前端中文 → 文件系统 key
pub const CHINESE_TO_ENGLISH: &[(&str, &str)] = &[
    ("数学", "math"), ("语文", "chinese"), ("英语", "english"),
    ("物理", "physics"), ("化学", "chemistry"), ("生物", "biology"),
    ("历史", "history"), ("地理", "geography"), ("政治", "politics"),
    ("科学", "science"), ("信息技术", "it"), ("体育", "pe"),
    ("艺术", "art"), ("日语", "japanese"), ("俄语", "russian"),
];

/// 前端 grade_band → 文件系统 level
fn grade_to_level(grade: &str) -> &str {
    match grade {
        "g1-2" | "g3-4" | "g5-6" | "g7-9" | "compulsory" => "compulsory",
        "g10" | "g10-12" | "g11-12" | "senior" => "senior",
        _ => grade,
    }
}

/// 从文件名推断 subject + level："{subject}_{level}.json" 或 "{subject}.json"
fn parse_filename(fname: &str) -> Option<(String, String)> {
    let stem = fname.strip_suffix(".json")?;
    match stem.rfind('_') {
        Some(pos) => {
            let subject = stem[..pos].to_string();
            let level = stem[pos + 1..].to_string();
            Some((subject, level))
        }
        None => {
            // 合并后的单文件: "{subject}.json" → key="{subject}_all"
            Some((stem.to_string(), "all".to_string()))
        }
    }
}

// ── 初始化 ──

pub fn init() -> Result<(), String> {
    let base = Paths::prebuilt();
    eprintln!("[K12] init: base={}", base.display());
    eprintln!("[K12] cards_dir={}", base.join("cards").display());
    tracing::info!("K12 loader: scanning {}", base.display());
    let cards_dir = base.join("cards");

    let mut plan_index: HashMap<String, PlanData> = HashMap::new();
    let mut card_index: HashMap<String, Vec<CardData>> = HashMap::new();

    // 1. 扫描计划文件：先扫 v3/ 根目录（兼容旧结构），再扫 plans/ 子目录
    let plan_dirs: Vec<std::path::PathBuf> = {
        let mut dirs = vec![base.clone()];
        let plans_dir = base.join("plans");
        if plans_dir.exists() {
            dirs.push(plans_dir);
        }
        dirs
    };
    let mut plan_source_dirs = Vec::new();
    for scan_dir in &plan_dirs {
        let mut count_before = plan_index.len();
        if let Ok(dir) = std::fs::read_dir(scan_dir) {
            for entry in dir.flatten() {
            let path = entry.path();
            if !path.is_file() { continue; }
            let fname = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) if n.ends_with(".json") && !n.ends_with("stage_grade_filter.json") => n.to_string(),
                _ => continue,
            };
            // 跳过 cards/ 子目录
            if path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()) == Some("cards") {
                continue;
            }
            let subject = fname.strip_suffix(".json").unwrap_or("").to_string();
            let plan_file: PlanFile = match load_json(&path) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("[K12] SKIP plan {}: {}", fname, e);
                    tracing::warn!("K12: skip plan {}: {}", fname, e);
                    continue;
                }
            };
            let plan = PlanData {
                id: format!("{}_plan", subject),
                goal: plan_file.goal.unwrap_or_else(|| format!("{}学习计划", subject)),
                stages: plan_file.stages,
                total_crs: plan_file.total_tasks.unwrap_or(0),
            };
            plan_index.insert(subject.clone(), plan);
        }
    }
            if plan_index.len() > count_before {
                plan_source_dirs.push(scan_dir.display().to_string());
            }
    }
    if plan_index.is_empty() {
        eprintln!("[K12] WARN: no plan files found in {:?}", plan_dirs.iter().map(|d| d.display()).collect::<Vec<_>>());
        tracing::warn!("K12: no plan files found");
    } else {
        eprintln!("[K12] loaded {} plans from {}", plan_index.len(), plan_source_dirs.join(", "));
        tracing::info!("K12: loaded {} plans", plan_index.len());
    }

    // 2. 扫描卡片文件
    if cards_dir.exists() {
        if let Ok(dir) = std::fs::read_dir(&cards_dir) {
            for entry in dir.flatten() {
                let path = entry.path();
                let fname = match path.file_name().and_then(|n| n.to_str()) {
                    Some(n) if n.ends_with(".json") => n.to_string(),
                    _ => continue,
                };
                let (subject, level) = match parse_filename(&fname) {
                    Some(p) => p,
                    None => continue,
                };
                let card_file: CardFile = match load_json(&path) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!("[K12] SKIP cards {}: {}", fname, e);
                        tracing::warn!("K12: skip cards {}: {}", fname, e);
                        continue;
                    }
                };
                let key = format!("{}_{}", subject, level);
                eprintln!("[K12] loaded {} → key={} ({} cards)", fname, key, card_file.cards.len());
                card_index.insert(key, card_file.cards);
            }
        }
        eprintln!("[K12] loaded {} card sets from {}", card_index.len(), cards_dir.display());
    } else {
        tracing::warn!("K12: cards dir not found: {}", cards_dir.display());
    }

    let data = K12Prebuilt { plan_index, card_index };
    K12_DATA.set(data).map_err(|_| "K12 already initialized".to_string())
}

pub fn get() -> &'static K12Prebuilt {
    K12_DATA.get().expect("K12 not initialized")
}

// ── 公开查询接口 ──

/// 通过 subject key（英文代码）+ grade_band 获取 Plan（已按年级过滤）
/// 与 get_plan 的区别：直接使用英文 key，不经过 CHINESE_TO_ENGLISH 查找
pub fn get_plan_by_key(subject_key: &str, grade: &str) -> Option<PlanData> {
    let plan = match get().plan_index.get(subject_key) {
        Some(p) => p,
        None => {
            eprintln!("[K12] get_plan_by_key: MISS key={}", subject_key);
            return None;
        }
    };
    let grade_for_filter = match grade {
        "g10" | "g11-12" => "g10-12",
        _ => grade,
    };
    let filtered_stages: Vec<StageData> = plan.stages.iter()
        .filter(|s| s.grade_band.is_empty() || s.grade_band == grade_for_filter)
        .cloned()
        .collect();
    let result = PlanData {
        stages: filtered_stages,
        ..plan.clone()
    };
    if result.stages.is_empty() {
        eprintln!("[K12] WARN: {} no stages match grade_band '{}' (plan has {} stages)", subject_key, grade_for_filter, plan.stages.len());
        tracing::warn!("K12: no stages match grade_band {} for {}", grade, subject_key);
    }
    eprintln!("[K12] get_plan_by_key: {} -> {} stages (filtered for grade={})", subject_key, result.stages.len(), grade);
    Some(result)
}

/// 通过 subject key（英文代码）+ grade_band 获取 Cards
pub fn get_cards_by_key(subject_key: &str, grade: &str) -> Option<&'static Vec<CardData>> {
    let level = match grade {
        "g10" | "g10-12" | "g11-12" | "senior" => "senior",
        _ => "compulsory",
    };
    // 先试 "{subject}_{level}"（旧拆分格式）
    let key = format!("{}_{}", subject_key, level);
    if let Some(cards) = get().card_index.get(&key) {
        eprintln!("[K12] get_cards_by_key: {} -> {} cards (key={})", subject_key, cards.len(), key);
        return Some(cards);
    }
    // 回退到 "{subject}_all"（合并后的单文件格式）
    let fallback_key = format!("{}_{}", subject_key, "all");
    if let Some(cards) = get().card_index.get(&fallback_key) {
        eprintln!("[K12] get_cards_by_key: {} -> {} cards (key={}, fallback from {})",
            subject_key, cards.len(), fallback_key, key);
        return Some(cards);
    }
    eprintln!("[K12] get_cards_by_key: MISS key={} (subject={})", key, subject_key);
    tracing::warn!("K12: cards not found: {} (key={})", subject_key, key);
    None
}

/// 通过前端 subject 中文名 + grade_band 获取 Plan（已按年级过滤）
/// 兼容过渡期：中文名走 CHINESE_TO_ENGLISH，英文名直接使用
pub fn get_plan(subject_cn: &str, grade: &str) -> Option<PlanData> {
    let subject_key = CHINESE_TO_ENGLISH.iter()
        .find(|(cn, _)| *cn == subject_cn)
        .map(|(_, en)| *en)
        .unwrap_or(subject_cn);  // 如果找不到中文映射，直接用输入作为 key（英文代码兼容）
    get_plan_by_key(subject_key, grade)
}

/// 通过前端 subject 中文名 + grade_band 获取 Cards
/// 兼容过渡期：中文名走 CHINESE_TO_ENGLISH，英文名直接使用
pub fn get_cards(subject_cn: &str, grade: &str) -> Option<&'static Vec<CardData>> {
    let subject_key = CHINESE_TO_ENGLISH.iter()
        .find(|(cn, _)| *cn == subject_cn)
        .map(|(_, en)| *en)
        .unwrap_or(subject_cn);  // 如果找不到中文映射，直接用输入作为 key（英文代码兼容）
    get_cards_by_key(subject_key, grade)
}

/// 按 ID 查找卡片（遍历所有 card_index 条目）
pub fn get_card_by_id(card_id: &str) -> Option<&'static CardData> {
    for cards in get().card_index.values() {
        for card in cards {
            if card.id == card_id {
                return Some(card);
            }
        }
    }
    None
}

fn load_json<T: serde::de::DeserializeOwned>(path: &std::path::Path) -> Result<T, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {}", path.display(), e))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("parse {}: {}", path.display(), e))
}

struct Paths;
impl Paths {
    fn prebuilt() -> std::path::PathBuf {
        // 优先环境变量
        if let Ok(dir) = std::env::var("COEVO_K12_DATA_DIR") {
            return std::path::PathBuf::from(dir);
        }
        // 开发模式：从 CARGO_MANIFEST_DIR 定位
        let dev_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../data/curriculum/v3");
        if dev_path.join("plans").exists() {
            return dev_path;
        }
        // 回退：相对 CWD（兼容在项目根目录运行）
        let cwd_path = std::path::PathBuf::from("data/curriculum/v3");
        if cwd_path.join("plans").exists() {
            return cwd_path;
        }
        // 最终回退
        dev_path
    }
}

/// 返回 v3 迁移后的数据目录（data/curriculum/v3）
pub fn k12_data_dir() -> std::path::PathBuf {
    if let Ok(dir) = std::env::var("COEVO_K12_DATA_DIR") {
        return std::path::PathBuf::from(dir);
    }
    let dev_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../data/curriculum/v3");
    // 优先检查 plans/ 子目录（v2.1 架构调整后计划文件移入 plans/）
    if dev_path.join("plans").join("chinese.json").exists() {
        return dev_path.join("plans");
    }
    if dev_path.join("chinese.json").exists() {
        return dev_path;
    }
    let cwd_path = std::path::PathBuf::from("data/curriculum/v3");
    if cwd_path.join("plans").join("chinese.json").exists() {
        return cwd_path.join("plans");
    }
    if cwd_path.join("chinese.json").exists() {
        return cwd_path;
    }
    Paths::prebuilt() // fallback
}
