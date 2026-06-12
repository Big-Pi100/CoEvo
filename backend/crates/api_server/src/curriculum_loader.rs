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
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default = "default_true")]
    pub visible: bool,
    #[serde(default)]
    pub theme_color: String,
    #[serde(default)]
    pub theme_icon: String,
    pub total_stages: Option<i64>,
    pub total_tasks: Option<i64>,
}

fn default_true() -> bool { true }

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct PlanData {
    pub id: String,
    pub goal: String,
    #[serde(default)]
    pub stages: Vec<StageData>,
    pub total_crs: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub author: String,
    #[serde(default = "default_true")]
    pub visible: bool,
    #[serde(default)]
    pub theme_color: String,
    #[serde(default)]
    pub theme_icon: String,
    #[serde(default)]
    pub domain: String,
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
    #[serde(default)]
    pub task_key: String,
    #[serde(default)]
    pub prompt_mode: String,
    #[serde(default)]
    pub card_ids: Vec<String>,
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
                    title: plan_file.title.clone(),
                    display_name: plan_file.display_name.clone(),
                    author: plan_file.author.clone(),
                    visible: plan_file.visible,
                    theme_color: plan_file.theme_color.clone(),
                    theme_icon: plan_file.theme_icon.clone(),
                    domain: plan_file.domain.clone().unwrap_or_default(),
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

/// 将 prebuilt 数据写入 DB 表（启动时在 schema init 后调用）
/// 从此 JSON 不再是运行时数据源，仅用作镜像。
/// subject_filter: Some(&[...]) 时只处理指定的 subject；None 时处理全部。
pub fn write_prebuilt_to_db(conn: &rusqlite::Connection, subject_filter: Option<&[String]>) -> Result<(), String> {
    let base = Paths::prebuilt();
    let cards_base = base.join("cards");
    for domain in &["science", "language", "literature", "humanities"] {
        let dir = cards_base.join(domain);
        if !dir.exists() { continue; }

        // 父表
        let parents: Vec<serde_json::Value> = load_json(&dir.join("prebuilt_cards.json"))
            .map_err(|e| format!("load {} parent: {}", domain, e))?;
        for p in &parents {
            let id = p["id"].as_str().unwrap_or("");
            let card_type = p["card_type"].as_str().unwrap_or("");
            let dom = p["domain"].as_str().unwrap_or(domain);
            let subject = p["subject"].as_str().unwrap_or("");
            let grade = p["grade_band"].as_str().unwrap_or("");
            let front = p["front"].as_str().unwrap_or("");
            conn.execute(
                "INSERT OR IGNORE INTO prebuilt_cards (id, card_type, domain, subject, grade_band, front) VALUES (?1,?2,?3,?4,?5,?6)",
                rusqlite::params![id, card_type, dom, subject, grade, front],
            ).map_err(|e| format!("insert prebuilt_cards {}: {}", id, e))?;
        }

        // 子表：查 DB 实际列，过滤 JSON 中不存在的列
        let sub_name = format!("prebuilt_{}_cards.json", domain);
        let subs: Vec<serde_json::Value> = load_json(&dir.join(&sub_name))
            .unwrap_or_default();
        let sub_table = format!("prebuilt_{}_cards", domain);
        // 获取 DB 表实际列名（不含 id）
        let db_cols: Vec<String> = {
            let sql = format!("PRAGMA table_info({})", sub_table);
            let mut stmt = conn.prepare(&sql)
                .map_err(|e| format!("pragma {}: {}", sub_table, e))?;
            let mut cols = Vec::new();
            if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(1)) {
                for r in rows.flatten() {
                    if r != "id" {
                        cols.push(r);
                    }
                }
            }
            cols
        };
        for s in &subs {
            let id = s["id"].as_str().unwrap_or("");
            // 只取 DB 表中存在的列
            let cols: Vec<&String> = db_cols.iter()
                .filter(|c| s.get(c.as_str()).is_some())
                .collect();
            if cols.is_empty() { continue; }
            let col_names: Vec<&str> = cols.iter().map(|c| c.as_str()).collect();
            let placeholders: Vec<String> = cols.iter().enumerate()
                .map(|(i, _)| format!("?{}", i + 2)).collect();
            let sql = format!(
                "INSERT OR IGNORE INTO {} (id, {}) VALUES (?1, {})",
                sub_table, col_names.join(","), placeholders.join(",")
            );
            let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(id.to_string())];
            for col in &cols {
                let val = s[col.as_str()].as_str().unwrap_or("");
                params.push(Box::new(val.to_string()));
            }
            let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
            conn.execute(&sql, param_refs.as_slice())
                .map_err(|e| format!("insert {} {}: {}", sub_table, id, e))?;
        }
        tracing::info!("K12 DB: wrote {} {} parent cards", parents.len(), domain);
    }

    // 2. 写计划（写入 plan_content 完整 JSON + stages/tasks 子表）
    // 收集需要写回 ID 的 JSON 文件（plan_val 在循环内已被修改，延迟统一写回）
    let mut pending_backfills: HashMap<String, serde_json::Value> = HashMap::new();
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
                // 如果指定了 subject_filter，跳过不匹配的 subject
                if let Some(ref filter) = subject_filter {
                    if !filter.contains(&subject) {
                        continue;
                    }
                }
                let mut plan_val: serde_json::Value = load_json(&path)
                    .map_err(|e| format!("load plan {}: {}", fname, e))?;
                let goal = plan_val["goal"].as_str().unwrap_or("").to_string();
                let domain = plan_val["domain"].as_str().unwrap_or("").to_string();
                let plan_id = if let Some(id) = plan_val["id"].as_str() {
                    id.to_string()
                } else {
                    let new_id = uuid::Uuid::new_v4().to_string();
                    plan_val["id"] = serde_json::Value::String(new_id.clone());
                    pending_backfills.insert(path.to_string_lossy().to_string(), plan_val.clone());
                    new_id
                };

                // upsert: 同 subject 先删再插（保证幂等）
                conn.execute("DELETE FROM prebuilt_tasks WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject])
                    .map_err(|e| format!("delete prebuilt_tasks for {}: {}", subject, e))?;
                conn.execute("DELETE FROM prebuilt_stages WHERE plan_id IN (SELECT id FROM prebuilt_plans WHERE subject=?1)", rusqlite::params![subject])
                    .map_err(|e| format!("delete prebuilt_stages for {}: {}", subject, e))?;
                conn.execute("DELETE FROM prebuilt_plans WHERE subject=?1", rusqlite::params![subject])
                    .map_err(|e| format!("delete prebuilt_plans {}: {}", subject, e))?;

                conn.execute(
                    "INSERT INTO prebuilt_plans (id, subject, grade_band, goal, domain, title, author, display_name, visible, theme_color, theme_icon) VALUES (?1,?2,'',?3,?4,?5,?6,?7,?8,?9,?10)",
                    rusqlite::params![plan_id, subject, goal, domain,
                        plan_val["title"].as_str().unwrap_or(""),
                        plan_val["author"].as_str().unwrap_or(""),
                        plan_val["display_name"].as_str().unwrap_or(""),
                        plan_val["visible"].as_bool().unwrap_or(true),
                        plan_val["theme_color"].as_str().unwrap_or(""),
                        plan_val["theme_icon"].as_str().unwrap_or(""),
                    ],
                ).map_err(|e| format!("insert prebuilt_plans {}: {}", subject, e))?;

                // 写 stages + tasks（规范化表，替代 plan_content JSON）
                // 延迟收集自动生成的 ID，避免在不可变借用期间修改 plan_val
                let mut new_stage_ids: Vec<(usize, String)> = Vec::new();
                let mut new_task_ids: Vec<(usize, usize, String)> = Vec::new();
                if let Some(stages) = plan_val["stages"].as_array() {
                    for (si, stage) in stages.iter().enumerate() {
                        let stage_name = stage["name"].as_str().unwrap_or("");
                        let stage_grade = stage["grade_band"].as_str().unwrap_or("");
                        let stage_id = if let Some(id) = stage["id"].as_str() {
                            id.to_string()
                        } else {
                            let new_id = uuid::Uuid::new_v4().to_string();
                            new_stage_ids.push((si, new_id.clone()));
                            new_id
                        };
                        conn.execute(
                            "INSERT OR IGNORE INTO prebuilt_stages (id, plan_id, sort_order, name, grade_band) VALUES (?1,?2,?3,?4,?5)",
                            rusqlite::params![stage_id, plan_id, si as i64, stage_name, stage_grade],
                        ).map_err(|e| format!("insert stage {}: {}", stage_id, e))?;

                        if let Some(tasks) = stage["tasks"].as_array() {
                            for (ti, task) in tasks.iter().enumerate() {
                                let task_key = task["task_key"].as_str().unwrap_or("");
                                let task_name = task["name"].as_str().unwrap_or("");
                                let prompt_mode = task["prompt_mode"].as_str().unwrap_or("");
                                let card_ids = task["card_ids"].as_array()
                                    .map(|a| serde_json::to_string(a).unwrap_or_default())
                                    .unwrap_or_default();
                                let task_id = if let Some(id) = task["id"].as_str() {
                                    id.to_string()
                                } else {
                                    let new_id = uuid::Uuid::new_v4().to_string();
                                    new_task_ids.push((si, ti, new_id.clone()));
                                    new_id
                                };
                                let dependencies = task["dependencies"].as_array()
                                    .map(|a| serde_json::to_string(a).unwrap_or_default())
                                    .unwrap_or_default();
                                let origin = task["origin"].as_str().unwrap_or("");
                                conn.execute(
                                    "INSERT OR IGNORE INTO prebuilt_tasks (id, plan_id, stage_id, task_key, name, prompt_mode, card_ids, dependencies, origin, sort_order) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                                    rusqlite::params![task_id, plan_id, stage_id, task_key, task_name, prompt_mode, card_ids, dependencies, origin, ti as i64],
                                ).map_err(|e| format!("insert task {}: {}", task_id, e))?;
                            }
                        }
                    }
                }
                // 将延迟收集的 ID 写回 plan_val（此时 stages 借用已释放）
                if !new_stage_ids.is_empty() || !new_task_ids.is_empty() {
                    if let Some(stages_arr) = plan_val["stages"].as_array_mut() {
                        for (si, new_id) in &new_stage_ids {
                            stages_arr[*si]["id"] = serde_json::Value::String(new_id.clone());
                        }
                        for (si, ti, new_id) in &new_task_ids {
                            if *si < stages_arr.len() {
                                if let Some(tasks_arr) = stages_arr[*si]["tasks"].as_array_mut() {
                                    if *ti < tasks_arr.len() {
                                        tasks_arr[*ti]["id"] = serde_json::Value::String(new_id.clone());
                                    }
                                }
                            }
                        }
                    }
                    pending_backfills.insert(path.to_string_lossy().to_string(), plan_val.clone());
                }
                tracing::info!("K12 DB: wrote plan {}", subject);
            }
        }
    }

    // 3. 将自动生成的 ID 写回 JSON 文件
    for (plan_path, plan_val) in &pending_backfills {
        let json_str = serde_json::to_string_pretty(plan_val)
            .map_err(|e| format!("serialize plan JSON for write-back: {}", e))?;
        let tmp = format!("{}.tmp", plan_path);
        std::fs::write(&tmp, &json_str)
            .map_err(|e| format!("write {}: {}", tmp, e))?;
        std::fs::rename(&tmp, plan_path)
            .map_err(|e| format!("rename {} -> {}: {}", tmp, plan_path, e))?;
        tracing::info!("K12 DB: wrote back auto-generated IDs to {}", plan_path);
    }

    tracing::info!("K12 DB: prebuilt data written successfully");
    Ok(())
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
