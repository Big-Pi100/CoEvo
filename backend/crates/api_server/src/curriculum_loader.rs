//! K12 V4 预生成数据加载器
//!
//! 启动时从 data/curriculum/v4/{cards/{domain}/,plans/} 加载 V4 格式数据
//! 从目录名推断 domain，从卡片体内嵌的 subject/grade_band 构建索引。
//! 供 /k12/init 路由直接使用。

use std::collections::HashMap;
use std::sync::OnceLock;

static K12_DATA: OnceLock<K12Prebuilt> = OnceLock::new();

// ── 数据模型（V4 格式 + 兼容 V3 CardData） ──

/// 顶层索引结构
pub struct K12Prebuilt {
    pub plan_index: HashMap<String, PlanData>,
    pub card_index: HashMap<String, Vec<CardData>>,
}

/// Plan 文件包装（合并格式）：{stages: [...], subject: "...", domain: "...", ...}
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct PlanFile {
    pub subject: Option<String>,
    pub goal: Option<String>,
    pub domain: Option<String>,
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

// ── V4 父卡记录（prebuilt_cards.json 中的条目） ──

#[derive(Debug, Clone, serde::Deserialize)]
pub struct V4ParentCard {
    pub id: String,
    #[serde(default)]
    pub card_type: String,
    #[serde(default)]
    pub domain: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub grade_band: String,
    #[serde(default)]
    pub front: String,
}

// ── V4 子表记录（prebuilt_{domain}_cards.json 中的条目） ──

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(untagged)]
pub enum V4SubCard {
    Science(V4ScienceSub),
    Language(V4LanguageSub),
    Literature(V4LiteratureSub),
    Humanities(V4HumanitiesSub),
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct V4ScienceSub {
    pub id: String,
    #[serde(default)]
    pub definition: String,
    #[serde(default)]
    pub key_elements: String,
    #[serde(default)]
    pub applications: String,
    #[serde(default)]
    pub related_concepts: String,
    #[serde(default)]
    pub formula: String,
    #[serde(default)]
    pub graph: String,
    #[serde(default)]
    pub source: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct V4LanguageSub {
    pub id: String,
    #[serde(default)]
    pub pronunciation: String,
    #[serde(default)]
    pub pos: String,
    #[serde(default)]
    pub definitions: String,
    #[serde(default)]
    pub related_phrases: String,
    #[serde(default)]
    pub structure_meta: String,
    #[serde(default)]
    pub level: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct V4LiteratureSub {
    pub id: String,
    #[serde(default)]
    pub full_text: String,
    #[serde(default)]
    pub translation: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub genre: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct V4HumanitiesSub {
    pub id: String,
    #[serde(default)]
    pub node_type: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub period: String,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub tags: String,
}

/// 兼容 V3 CardData（public，查询接口仍返回此类型）
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

// ── 子表文件名映射 ──

fn sub_table_name(domain: &str) -> &str {
    match domain {
        "science" => "prebuilt_science_cards.json",
        "language" => "prebuilt_language_cards.json",
        "literature" => "prebuilt_literature_cards.json",
        "humanities" => "prebuilt_humanities_cards.json",
        _ => "prebuilt_science_cards.json",
    }
}

// ── 子表 back 重建 ──

fn reconstruct_back(domain: &str, sub_value: &serde_json::Value) -> String {
    match domain {
        "science" => {
            let d = sub_value["definition"].as_str().unwrap_or("");
            let k = sub_value["key_elements"].as_str().unwrap_or("");
            let a = sub_value["applications"].as_str().unwrap_or("");
            let r = sub_value["related_concepts"].as_str().unwrap_or("");
            let mut parts = Vec::new();
            if !d.is_empty() { parts.push(format!("定义:{}", d)); }
            if !k.is_empty() { parts.push(format!("关键要素:{}", k)); }
            if !a.is_empty() { parts.push(format!("应用:{}", a)); }
            if !r.is_empty() { parts.push(format!("关联:{}", r)); }
            parts.join("\n\n")
        }
        "language" => {
            // 将 language 子表序列化为 JSON（兼容旧消费方）
            serde_json::to_string(sub_value).unwrap_or_default()
        }
        "literature" | "humanities" => {
            sub_value["body"].as_str()
                .or_else(|| sub_value["full_text"].as_str())
                .unwrap_or("")
                .to_string()
        }
        _ => String::new(),
    }
}

// ── 初始化 ──

pub fn init() -> Result<(), String> {
    let base = Paths::prebuilt();
    tracing::info!("[K12] init v4: base={}", base.display());

    let mut plan_index: HashMap<String, PlanData> = HashMap::new();
    let mut card_index: HashMap<String, Vec<CardData>> = HashMap::new();
    let mut global_cards: Vec<CardData> = Vec::new();

    // 1. 扫描卡片：遍历 v4/cards/{domain}/ 四个子目录
    let cards_base = base.join("cards");
    let domains = ["science", "language", "literature", "humanities"];

    if cards_base.exists() {
        for domain in &domains {
            let domain_dir = cards_base.join(domain);
            if !domain_dir.exists() {
                tracing::warn!("K12: domain dir not found: {}", domain_dir.display());
                continue;
            }

            // 读取父卡
            let parent_path = domain_dir.join("prebuilt_cards.json");
            if !parent_path.exists() {
                tracing::warn!("K12: parent cards not found: {}", parent_path.display());
                continue;
            }
            let parents: Vec<V4ParentCard> = match load_json(&parent_path) {
                Ok(p) => p,
                Err(e) => {
                    tracing::warn!("K12: skip parents {}: {}", parent_path.display(), e);
                    continue;
                }
            };

            // 读取子表
            let sub_path = domain_dir.join(sub_table_name(domain));
            let subs: HashMap<String, serde_json::Value> = if sub_path.exists() {
                    match load_json::<Vec<serde_json::Value>>(&sub_path) {
                        Ok(records) => records.into_iter()
                            .filter_map(|r| {
                                let id = r.get("id")
                                    .and_then(|id| id.as_str())
                                    .map(|id| id.to_string());
                                id.map(|id_str| (id_str, r))
                            })
                            .collect(),
                    Err(e) => {
                        tracing::warn!("K12: skip sub table {}: {}", sub_path.display(), e);
                        HashMap::new()
                    }
                }
            } else {
                HashMap::new()
            };

            // 合并父卡 + 子表 → CardData
            for parent in &parents {
                let back = subs.get(&parent.id)
                    .map(|sub| reconstruct_back(domain, sub))
                    .unwrap_or_default();

                let card = CardData {
                    id: parent.id.clone(),
                    front: parent.front.clone(),
                    back,
                    domain: parent.domain.clone(),
                    subject: parent.subject.clone(),
                    grade_band: parent.grade_band.clone(),
                    card_type: parent.card_type.clone(),
                    gold_cr_ids: Vec::new(),
                    origin: String::new(),
                    source_sentence: String::new(),
                    plan_task_id: String::new(),
                };
                global_cards.push(card);
            }

            tracing::info!("K12: loaded {} cards from domain={}", parents.len(), domain);
        }

        // 按 subject + grade_band 构建索引（兼容 get_cards_by_key 查询）
        for card in &global_cards {
            let level = grade_to_level(&card.grade_band);
            let key = format!("{}_{}", card.subject, level);
            card_index.entry(key).or_default().push(card.clone());
            // 也插入 subject_all 方便统一查询
            let all_key = format!("{}_all", card.subject);
            card_index.entry(all_key).or_default().push(card.clone());
        }
    } else {
        tracing::warn!("K12: cards dir not found: {}", cards_base.display());
    }

    tracing::info!("K12: loaded {} card sets ({} total cards)", card_index.len(), global_cards.len());

    // 2. 扫描计划文件
    let plans_dir = base.join("plans");
    if plans_dir.exists() {
        if let Ok(dir) = std::fs::read_dir(&plans_dir) {
            for entry in dir.flatten() {
                let path = entry.path();
                if !path.is_file() { continue; }
                let fname = match path.file_name().and_then(|n| n.to_str()) {
                    Some(n) if n.ends_with(".json") => n.to_string(),
                    _ => continue,
                };
                let subject = fname.strip_suffix(".json").unwrap_or("").to_string();
                let plan_file: PlanFile = match load_json(&path) {
                    Ok(f) => f,
                    Err(e) => {
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
    }
    if plan_index.is_empty() {
        tracing::warn!("K12: no plan files found in {}", plans_dir.display());
    } else {
        tracing::info!("K12: loaded {} plans from {}", plan_index.len(), plans_dir.display());
    }

    let data = K12Prebuilt { plan_index, card_index };
    K12_DATA.set(data).map_err(|_| "K12 already initialized".to_string())
}

pub fn get() -> &'static K12Prebuilt {
    K12_DATA.get().expect("K12 not initialized")
}

// ── 公开查询接口 ──

/// 通过 subject key（英文代码）+ grade_band 获取 Plan（已按年级过滤）
pub fn get_plan_by_key(subject_key: &str, grade: &str) -> Option<PlanData> {
    let plan = match get().plan_index.get(subject_key) {
        Some(p) => p,
        None => {
            tracing::warn!("K12: plan not found: key={}", subject_key);
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
        tracing::warn!("K12: no stages match grade_band {} for {} (plan has {} stages)", grade_for_filter, subject_key, plan.stages.len());
    }
    tracing::info!("K12: {} -> {} stages for grade={}", subject_key, result.stages.len(), grade);
    Some(result)
}

/// 通过 subject key（英文代码）+ grade_band 获取 Cards
pub fn get_cards_by_key(subject_key: &str, grade: &str) -> Option<&'static Vec<CardData>> {
    let level = match grade {
        "g10" | "g10-12" | "g11-12" | "senior" => "senior",
        _ => "compulsory",
    };
    // 先试 "{subject}_{level}"
    let key = format!("{}_{}", subject_key, level);
    if let Some(cards) = get().card_index.get(&key) {
        tracing::info!("K12: {} -> {} cards (key={})", subject_key, cards.len(), key);
        return Some(cards);
    }
    // 回退到 "{subject}_all"
    let fallback_key = format!("{}_{}", subject_key, "all");
    if let Some(cards) = get().card_index.get(&fallback_key) {
        tracing::info!("K12: {} -> {} cards (key={}, fallback from {})",
            subject_key, cards.len(), fallback_key, key);
        return Some(cards);
    }
    tracing::warn!("K12: cards not found: key={} (subject={})", key, subject_key);
    None
}

/// 通过前端 subject 中文名 + grade_band 获取 Plan（已按年级过滤）
pub fn get_plan(subject_cn: &str, grade: &str) -> Option<PlanData> {
    let subject_key = CHINESE_TO_ENGLISH.iter()
        .find(|(cn, _)| *cn == subject_cn)
        .map(|(_, en)| *en)
        .unwrap_or(subject_cn);
    get_plan_by_key(subject_key, grade)
}

/// 通过前端 subject 中文名 + grade_band 获取 Cards
pub fn get_cards(subject_cn: &str, grade: &str) -> Option<&'static Vec<CardData>> {
    let subject_key = CHINESE_TO_ENGLISH.iter()
        .find(|(cn, _)| *cn == subject_cn)
        .map(|(_, en)| *en)
        .unwrap_or(subject_cn);
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
            .join("../../../data/curriculum/v4");
        if dev_path.join("cards").exists() {
            return dev_path;
        }
        // 回退：相对 CWD（兼容在项目根目录运行）
        let cwd_path = std::path::PathBuf::from("data/curriculum/v4");
        if cwd_path.join("cards").exists() {
            return cwd_path;
        }
        // 最终回退
        dev_path
    }
}

/// 返回 v4 数据目录（data/curriculum/v4）
pub fn k12_data_dir() -> std::path::PathBuf {
    if let Ok(dir) = std::env::var("COEVO_K12_DATA_DIR") {
        return std::path::PathBuf::from(dir);
    }
    let dev_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../data/curriculum/v4");
    if dev_path.join("plans").join("chinese.json").exists() {
        return dev_path.join("plans");
    }
    if dev_path.join("chinese.json").exists() {
        return dev_path;
    }
    let cwd_path = std::path::PathBuf::from("data/curriculum/v4");
    if cwd_path.join("plans").join("chinese.json").exists() {
        return cwd_path.join("plans");
    }
    if cwd_path.join("chinese.json").exists() {
        return cwd_path;
    }
    Paths::prebuilt() // fallback
}
