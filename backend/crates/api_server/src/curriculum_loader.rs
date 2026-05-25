//! K12 预生成数据加载器
//!
//! 启动时从 docs/curriculum/prebuilt/ 加载 plans + cards
//! 供 /k12/init 路由直接使用

use std::collections::HashMap;
use std::sync::OnceLock;

static K12_DATA: OnceLock<K12Prebuilt> = OnceLock::new();

/// 预生成数据结构
pub struct K12Prebuilt {
    pub plans: Vec<PlanTemplate>,
    pub cards: Vec<CardTemplate>,
    /// plan + card 按 subject+grade 的索引
    pub plan_index: HashMap<String, PlanTemplate>,
    pub card_index: HashMap<String, Vec<CardTemplate>>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PlanTemplate {
    pub id: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub grade_band: String,
    pub goal: String,
    #[serde(default)]
    pub stages: Vec<StageTemplate>,
    pub total_crs: i64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct StageTemplate {
    pub name: String,
    #[serde(default)]
    pub tasks: Vec<TaskTemplate>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TaskTemplate {
    pub name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub gold_cr_ids: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CardTemplate {
    pub id: String,
    pub front: String,
    pub back: String,
    #[serde(rename = "card_type", default)]
    pub card_type: String,
    #[serde(default)]
    pub domain: String,
    #[serde(default)]
    pub subdomain: Option<String>,
    pub source_sentence: Option<String>,
    pub source_line: Option<i64>,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub grade_band: String,
    pub gold_cr_id: Option<String>,
}

/// 初始化 — 启动时调用
pub fn init() -> Result<(), String> {
    let base = Paths::prebuilt();
    let mut all_plans: Vec<PlanTemplate> = Vec::new();
    let mut all_cards: Vec<CardTemplate> = Vec::new();
    let mut plan_index: HashMap<String, PlanTemplate> = HashMap::new();
    let mut card_index: HashMap<String, Vec<CardTemplate>> = HashMap::new();

    // 扫描 prebuilt 目录
    let dir = std::fs::read_dir(&base).map_err(|e| format!("read_dir: {}", e))?;
    for entry in dir.flatten() {
        let path = entry.path();
        let fname = path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if fname.ends_with("_plans.json") {
            if let Ok(items) = load_json::<Vec<PlanTemplate>>(&path) {
                for plan in items {
                    let key = format!("{}_{}", plan.subject, plan.grade_band);
                    plan_index.insert(key.clone(), plan.clone());
                    all_plans.push(plan);
                }
            }
        }
        if fname.ends_with("_cards.json") {
            // 卡片文件格式: {"cards": [CardTemplate]}
            if let Ok(wrapper) = load_json::<serde_json::Value>(&path) {
                if let Some(card_list) = wrapper.get("cards").and_then(|v| v.as_array()) {
                    let templates: Vec<CardTemplate> = card_list.iter().filter_map(|c| {
                        serde_json::from_value(c.clone()).ok()
                    }).collect();
                    for card in &templates {
                        let key = format!("{}_{}", card.subject, card.grade_band);
                        card_index.entry(key).or_default().push(card.clone());
                    }
                    all_cards.extend(templates);
                }
            }
        }
    }

    let data = K12Prebuilt {
        plans: all_plans,
        cards: all_cards,
        plan_index,
        card_index,
    };
    K12_DATA.set(data)
        .map_err(|_| "K12 already initialized".to_string())
}

pub fn get() -> &'static K12Prebuilt {
    K12_DATA.get().expect("K12 not initialized")
}

/// 获取指定科目+年级的计划
pub fn get_plan(subject: &str, grade: &str) -> Option<&'static PlanTemplate> {
    let key = format!("{}_{}", subject, grade);
    get().plan_index.get(&key)
}

/// 获取指定科目+年级的卡片
pub fn get_cards(subject: &str, grade: &str) -> Option<&'static Vec<CardTemplate>> {
    let key = format!("{}_{}", subject, grade);
    get().card_index.get(&key)
}

fn load_json<T: serde::de::DeserializeOwned>(path: &std::path::Path) -> Result<T, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {}", path.display(), e))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("parse {}: {}", path.display(), e))
}

/// 预生成数据目录
struct Paths;
impl Paths {
    fn prebuilt() -> std::path::PathBuf {
        let base = std::env::var("COEVO_K12_DATA_DIR")
            .unwrap_or_else(|_| "docs/curriculum/prebuilt".to_string());
        std::path::PathBuf::from(base)
    }
}
