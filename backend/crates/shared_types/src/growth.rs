use std::collections::HashMap;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// ── 双语字符串（TOML: 纯字符串 或 {zh = "...", en = "..."}） ──

/// 双语字符串：TOML 中可以是纯字符串（向后兼容）或 {zh, en} 内联表
#[derive(Debug, Clone, Serialize, Default)]
pub struct LocalizedString {
    pub zh: String,
    pub en: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum LocalizedStringHelper {
    String(String),
    Table(HashMap<String, String>),
}

impl<'de> Deserialize<'de> for LocalizedString {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where D: serde::Deserializer<'de>
    {
        let helper: LocalizedStringHelper = Deserialize::deserialize(deserializer)?;
        match helper {
            LocalizedStringHelper::String(s) => Ok(LocalizedString { zh: s, en: String::new() }),
            LocalizedStringHelper::Table(mut t) => Ok(LocalizedString {
                zh: t.remove("zh").unwrap_or_default(),
                en: t.remove("en").unwrap_or_default(),
            }),
        }
    }
}

impl LocalizedString {
    /// 取中文（前端当前语言）
    pub fn zh(&self) -> &str { &self.zh }
    /// 取英文
    pub fn en(&self) -> &str { &self.en }
}

// ── 成就记录（DB 存储 + API 返回） ──

/// 成就解锁记录（写入 achievements 表，返回给前端）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Achievement {
    pub id: String,
    pub user_id: String,
    pub achievement_key: String,
    pub name: String,
    pub icon: String,
    pub color: String,
    pub tier: String,
    pub category: String,
    pub description: String,
    pub unlocked_at: DateTime<Utc>,
}

/// 成就记录的精简版（旧 API 兼容，不含 tier/category/color）
/// 仅用于渐进迁移，Phase 3 后可移除
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AchievementLegacy {
    pub id: String,
    pub user_id: String,
    pub achievement_key: String,
    pub name: String,
    pub icon: String,
    pub unlocked_at: DateTime<Utc>,
}

impl Achievement {
    /// 转为旧版精简格式
    pub fn to_legacy(&self) -> AchievementLegacy {
        AchievementLegacy {
            id: self.id.clone(),
            user_id: self.user_id.clone(),
            achievement_key: self.achievement_key.clone(),
            name: self.name.clone(),
            icon: self.icon.clone(),
            unlocked_at: self.unlocked_at,
        }
    }
}

// ── 成就上下文（检测时使用） ──

/// 成就检测上下文（Phase 2: 事件总线，由 build_context 从 DB 动态采集）
/// 所有字段均可选 — 缺失时 metric 从 DB 按需查询
#[derive(Debug, Clone)]
pub struct AchievementContext {
    pub user_id: String,
    // ── 已有字段 ──
    pub total_cards: u32,
    pub total_reviews: u32,
    pub streak_days: u32,
    pub domains_covered: u32,
    pub plans_completed: u32,
    pub conversations_completed: u32,
    // ── Phase 5 新增字段 ──
    pub hard_cards_count: u32,
    pub recent_accuracy_20: f64,
    pub recent_accuracy_50: f64,
    pub recent_accuracy_100: f64,
    pub weekend_streak: u32,
    pub night_sessions: u32,
    pub early_sessions: u32,
    pub hard_perfect_streak: u32,
    pub perfect_session_10: u32,
    pub mature_cards: u32,
    pub learning_cards: u32,
    pub no_skip_streak: u32,
    pub languages_count: u32,
    pub cards_in_1h: u32,
    pub days_since_last_review: u32,
    pub reviews_today: u32,
    pub days_since_reg: u32,
    // ── Phase 6 新增 ──
    /// 覆盖 K12 学科数（从 domain 提取 :: 之间的学科名去重统计）
    pub subjects_count: u32,
}

impl AchievementContext {
    /// 最小上下文（仅 user_id，其余字段由引擎按需查 DB）
    pub fn minimal(user_id: impl Into<String>) -> Self {
        Self {
            user_id: user_id.into(),
            total_cards: 0,
            total_reviews: 0,
            streak_days: 0,
            domains_covered: 0,
            plans_completed: 0,
            conversations_completed: 0,
            hard_cards_count: 0,
            recent_accuracy_20: 0.0,
            recent_accuracy_50: 0.0,
            recent_accuracy_100: 0.0,
            weekend_streak: 0,
            night_sessions: 0,
            early_sessions: 0,
            hard_perfect_streak: 0,
            perfect_session_10: 0,
            mature_cards: 0,
            learning_cards: 0,
            no_skip_streak: 0,
            languages_count: 0,
            cards_in_1h: 0,
            days_since_last_review: 9999,
            reviews_today: 0,
            days_since_reg: 9999,
            subjects_count: 0,
        }
    }
}

impl Default for AchievementContext {
    fn default() -> Self {
        Self {
            user_id: String::new(),
            total_cards: 0,
            total_reviews: 0,
            streak_days: 0,
            domains_covered: 0,
            plans_completed: 0,
            conversations_completed: 0,
            hard_cards_count: 0,
            recent_accuracy_20: 0.0,
            recent_accuracy_50: 0.0,
            recent_accuracy_100: 0.0,
            weekend_streak: 0,
            night_sessions: 0,
            early_sessions: 0,
            hard_perfect_streak: 0,
            perfect_session_10: 0,
            mature_cards: 0,
            learning_cards: 0,
            no_skip_streak: 0,
            languages_count: 0,
            cards_in_1h: 0,
            days_since_last_review: 9999,
            reviews_today: 0,
            days_since_reg: 9999,
            subjects_count: 0,
        }
    }
}

// ── 成就定义（TOML 反序列化 → 运行时使用） ──

/// 完整成就定义（从 TOML 加载后的运行时表示）
#[derive(Debug, Clone, serde::Serialize)]
pub struct AchievementDef {
    pub id: String,
    pub category: String,
    pub tier: String,
    pub name: LocalizedString,
    pub description: LocalizedString,
    pub icon: String,
    pub color: String,
    pub conditions: Vec<ConditionDef>,
    pub condition_logic: String,  // "AND" | "OR", default "AND"
    pub triggers: Vec<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
}

/// 单个条件定义
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConditionDef {
    pub metric: String,
    pub op: String,      // gte | lte | eq | gt | lt
    pub value: f64,
}

// ── TOML 反序列化结构（仅用于解析 achievements.toml） ──

/// 顶层 TOML 文件结构: [achievements.<key>]
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AchievementsToml {
    pub achievements: HashMap<String, AchievementTomlDef>,
}

/// 单个成就的 TOML 定义（反序列化专用，不含 id）
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AchievementTomlDef {
    pub category: String,
    pub tier: String,
    pub name: LocalizedString,
    pub description: LocalizedString,
    pub icon: String,
    pub color: String,
    #[serde(default)]
    pub conditions: Vec<ConditionDef>,
    #[serde(default = "default_logic")]
    pub condition_logic: String,
    #[serde(default)]
    pub triggers: Vec<String>,
    #[serde(default)]
    pub hidden: bool,
}

fn default_logic() -> String {
    "AND".into()
}

impl AchievementsToml {
    /// 从 TOML 字符串加载成就定义
    pub fn from_toml(toml_str: &str) -> Result<Vec<AchievementDef>, String> {
        let parsed: Self = toml::from_str(toml_str).map_err(|e| format!("TOML 解析失败: {}", e))?;
        Ok(parsed.into_defs())
    }

    /// 转为 Vec<AchievementDef>（填充 id 字段）
    pub fn into_defs(self) -> Vec<AchievementDef> {
        self.achievements.into_iter().map(|(id, raw)| AchievementDef {
            id,
            category: raw.category,
            tier: raw.tier,
            name: raw.name,
            description: raw.description,
            icon: raw.icon,
            color: raw.color,
            conditions: raw.conditions,
            condition_logic: raw.condition_logic,
            triggers: raw.triggers,
            hidden: raw.hidden,
        }).collect()
    }
}

// ── 向后兼容: 旧版预定义成就列表（Phase 1 过渡期） ──

/// 向后兼容：当 TOML 文件不可用时，使用硬编码回退
/// Phase 2 完成后可移除
#[derive(Debug, Clone)]
pub struct AchievementDefLegacy {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub description: String,
    pub condition: String,
}

impl AchievementDefLegacy {
    /// 旧版预定义成就（与新 TOML 内容一致）
    pub fn predefined() -> Vec<Self> {
        vec![
            Self { id: "first_card".into(), name: "初识".into(), icon: "auto_stories".into(),
                description: "第一张卡片".into(), condition: "total_cards >= 1".into() },
            Self { id: "cards_50".into(), name: "收藏家".into(), icon: "library_books".into(),
                description: "50 张卡片".into(), condition: "total_cards >= 50".into() },
            Self { id: "cards_200".into(), name: "图书馆".into(), icon: "account_balance".into(),
                description: "200 张卡片".into(), condition: "total_cards >= 200".into() },
            Self { id: "cards_500".into(), name: "学者".into(), icon: "school".into(),
                description: "500 张卡片".into(), condition: "total_cards >= 500".into() },
            Self { id: "streak_3".into(), name: "坚持3天".into(), icon: "whatshot".into(),
                description: "连续 3 天复习".into(), condition: "streak_days >= 3".into() },
            Self { id: "streak_7".into(), name: "一周达人".into(), icon: "local_fire_department".into(),
                description: "连续 7 天复习".into(), condition: "streak_days >= 7".into() },
            Self { id: "streak_30".into(), name: "月学霸".into(), icon: "self_improvement".into(),
                description: "连续 30 天复习".into(), condition: "streak_days >= 30".into() },
            Self { id: "explorer_3".into(), name: "探索者".into(), icon: "explore".into(),
                description: "覆盖 3 个领域".into(), condition: "domains_covered >= 3".into() },
            Self { id: "reviews_100".into(), name: "百炼".into(), icon: "refresh".into(),
                description: "累计复习 100 次".into(), condition: "total_reviews >= 100".into() },
            Self { id: "reviews_1000".into(), name: "千锤".into(), icon: "history".into(),
                description: "累计复习 1000 次".into(), condition: "total_reviews >= 1000".into() },
        ]
    }
}

// ── 旧的 AchievementDef::predefined() — 保留用于测试兼容 ──

impl AchievementDef {
    /// 向后兼容预定义列表（用于测试）
    /// Phase 2 后可以移除
    pub fn predefined() -> Vec<Self> {
        AchievementDefLegacy::predefined().into_iter().map(|legacy| {
            let cat = match_category(&legacy.id);
            let tier = match_tier(&legacy.id);
            let color = match_color(&legacy.id);
            let conds = parse_legacy_condition(&legacy.condition);
            AchievementDef {
                id: legacy.id,
                category: cat,
                tier,
                name: LocalizedString { zh: legacy.name, en: String::new() },
                description: LocalizedString { zh: legacy.description, en: String::new() },
                icon: legacy.icon,
                color,
                conditions: conds,
                condition_logic: "AND".into(),
                triggers: vec!["review_completed".into()],
                hidden: false,
            }
        }).collect()
    }
}

pub fn match_category(key: &str) -> String {
    if key.starts_with("streak_") { "consistency".to_string() }
    else if key == "first_card" { "seed".to_string() }
    else if key.starts_with("explorer_") || key.starts_with("polymath_") { "exploration".to_string() }
    else { "knowledge".to_string() }
}

pub fn match_tier(key: &str) -> String {
    match key {
        "first_card" | "streak_3" | "explorer_3" | "reviews_100" => "bronze",
        "cards_50" | "streak_7" | "domains_5" => "silver",
        "cards_200" | "streak_30" | "reviews_1000" => "gold",
        "cards_500" => "platinum",
        _ => "bronze",
    }.to_string()
}

pub fn match_color(_key: &str) -> String {
    // 旧代码无颜色信息，返回默认值
    "#CD7F32".to_string()  // bronze default
}

fn parse_legacy_condition(condition: &str) -> Vec<ConditionDef> {
    let parts: Vec<&str> = condition.split_whitespace().collect();
    if parts.len() != 3 { return vec![]; }
    let value: f64 = parts[2].parse().unwrap_or(0.0);
    let op = match parts[1] {
        ">=" => "gte", ">" => "gt", "==" => "eq", "<=" => "lte", "<" => "lt",
        _ => "gte",
    };
    vec![ConditionDef { metric: parts[0].into(), op: op.into(), value }]
}
