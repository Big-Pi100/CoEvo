use chrono::{DateTime, Utc};

/// 成就记录
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Achievement {
    pub id: String,
    pub user_id: String,
    pub achievement_key: String,
    pub name: String,
    pub icon: String,
    pub unlocked_at: DateTime<Utc>,
}

/// 成就上下文 (用于 N7 成就检测)
#[derive(Debug, Clone)]
pub struct AchievementContext {
    pub user_id: String,
    pub total_cards: u32,
    pub total_reviews: u32,
    pub streak_days: u32,
    pub domains_covered: u32,
}

/// 成就定义
#[derive(Debug, Clone)]
pub struct AchievementDef {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub description: String,
    pub condition: String,    // 如 "total_cards >= 50"
}

impl AchievementDef {
    pub fn predefined() -> Vec<Self> {
        vec![
            AchievementDef { id: "first_card".into(), name: "初识".into(), icon: "🌟".into(), description: "第一张卡片".into(), condition: "total_cards >= 1".into() },
            AchievementDef { id: "collector_50".into(), name: "收集者".into(), icon: "📚".into(), description: "50 张卡片".into(), condition: "total_cards >= 50".into() },
            AchievementDef { id: "library_200".into(), name: "图书馆".into(), icon: "🏛️".into(), description: "200 张卡片".into(), condition: "total_cards >= 200".into() },
            AchievementDef { id: "scholar_500".into(), name: "学者".into(), icon: "🎓".into(), description: "500 张卡片".into(), condition: "total_cards >= 500".into() },
            AchievementDef { id: "streak_3".into(), name: "坚持3天".into(), icon: "🔥".into(), description: "连续 3 天复习".into(), condition: "streak_days >= 3".into() },
            AchievementDef { id: "streak_7".into(), name: "坚持7天".into(), icon: "🔥".into(), description: "连续 7 天复习".into(), condition: "streak_days >= 7".into() },
            AchievementDef { id: "streak_30".into(), name: "坚持30天".into(), icon: "💪".into(), description: "连续 30 天复习".into(), condition: "streak_days >= 30".into() },
            AchievementDef { id: "explorer_3".into(), name: "探索者".into(), icon: "🗺️".into(), description: "覆盖 3 个领域".into(), condition: "domains_covered >= 3".into() },
            AchievementDef { id: "polymath_5".into(), name: "博学家".into(), icon: "🧠".into(), description: "覆盖 5 个领域".into(), condition: "domains_covered >= 5".into() },
            AchievementDef { id: "hundred_100".into(), name: "百炼".into(), icon: "⚔️".into(), description: "累计复习 100 次".into(), condition: "total_reviews >= 100".into() },
            AchievementDef { id: "thousand_1000".into(), name: "千锤".into(), icon: "🗡️".into(), description: "累计复习 1000 次".into(), condition: "total_reviews >= 1000".into() },
        ]
    }
}
