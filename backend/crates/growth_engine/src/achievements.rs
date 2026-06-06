//! N7: 成就检测引擎（Phase 1 — 数据驱动）
//!
//! 从 achievements.toml 加载成就定义，插件化条件求值。
//! Phase 1 触发点仅 review_submit；Phase 2 事件总线后扩展。

use shared_types::growth::{Achievement, AchievementDef, AchievementContext, ConditionDef, AchievementsToml};
use rusqlite::Connection;

// ── 条件求值器 trait ──

/// 条件求值器接口 — 新增条件类型只需实现此 trait 并注册
pub trait ConditionEvaluator: Send + Sync {
    /// 求值单个条件
    fn evaluate(&self, condition: &ConditionDef, ctx: &AchievementContext) -> bool;
}

/// 比较求值器：处理 gte / lte / eq / gt / lt
struct ComparisonEvaluator;

impl ConditionEvaluator for ComparisonEvaluator {
    fn evaluate(&self, condition: &ConditionDef, ctx: &AchievementContext) -> bool {
        let actual = match condition.metric.as_str() {
            // ── 已有 6 个 ──
            "total_cards" => ctx.total_cards as f64,
            "total_reviews" => ctx.total_reviews as f64,
            "streak_days" => ctx.streak_days as f64,
            "domains_covered" => ctx.domains_covered as f64,
            "plans_completed" => ctx.plans_completed as f64,
            "conversations_completed" => ctx.conversations_completed as f64,
            // ── Phase 5 新增 17 个 ──
            "hard_cards_count" => ctx.hard_cards_count as f64,
            "recent_accuracy_20" => ctx.recent_accuracy_20,
            "recent_accuracy_50" => ctx.recent_accuracy_50,
            "recent_accuracy_100" => ctx.recent_accuracy_100,
            "weekend_streak" => ctx.weekend_streak as f64,
            "night_sessions" => ctx.night_sessions as f64,
            "early_sessions" => ctx.early_sessions as f64,
            "hard_perfect_streak" => ctx.hard_perfect_streak as f64,
            "perfect_session_10" => ctx.perfect_session_10 as f64,
            "mature_cards" => ctx.mature_cards as f64,
            "learning_cards" => ctx.learning_cards as f64,
            "no_skip_streak" => ctx.no_skip_streak as f64,
            "languages_count" => ctx.languages_count as f64,
            "cards_in_1h" => ctx.cards_in_1h as f64,
            "days_since_last_review" => ctx.days_since_last_review as f64,
            "reviews_today" => ctx.reviews_today as f64,
            "days_since_reg" => ctx.days_since_reg as f64,
            "subjects_count" => ctx.subjects_count as f64,
            _ => {
                tracing::warn!("Unknown metric: {}", condition.metric);
                return false;
            }
        };

        match condition.op.as_str() {
            "gte" => actual >= condition.value,
            "lte" => actual <= condition.value,
            "eq"  => actual == condition.value,
            "gt"  => actual > condition.value,
            "lt"  => actual < condition.value,
            _ => {
                tracing::warn!("Unknown operator: {}", condition.op);
                false
            }
        }
    }
}

// ── 成就引擎 ──

/// 数据驱动的成就引擎
pub struct AchievementEngine {
    definitions: Vec<AchievementDef>,
    comparison_eval: ComparisonEvaluator,
}

impl AchievementEngine {
    /// 从 TOML 文件加载成就定义（推荐路径）
    pub fn from_toml_file(path: &str) -> Result<Self, String> {
        let toml_str = std::fs::read_to_string(path)
            .map_err(|e| format!("读取成就文件失败 ({}): {}", path, e))?;
        Self::from_toml_str(&toml_str)
    }

    /// 从 TOML 字符串加载
    pub fn from_toml_str(toml_str: &str) -> Result<Self, String> {
        let defs = AchievementsToml::from_toml(toml_str)?;
        tracing::info!("从 TOML 加载了 {} 个成就定义", defs.len());
        Ok(Self {
            definitions: defs,
            comparison_eval: ComparisonEvaluator,
        })
    }

    /// 回退：使用硬编码预定义成就（TOML 文件不可用时）
    pub fn from_predefined() -> Self {
        let defs = AchievementDef::predefined();
        tracing::info!("使用硬编码回退：{} 个成就定义", defs.len());
        Self {
            definitions: defs,
            comparison_eval: ComparisonEvaluator,
        }
    }

    /// 返回所有成就定义（供 API 使用）
    pub fn definitions(&self) -> &[AchievementDef] {
        &self.definitions
    }

    /// 根据 achievement_key 查找定义
    pub fn find_def(&self, key: &str) -> Option<&AchievementDef> {
        self.definitions.iter().find(|d| d.id == key)
    }

    /// 检查所有成就定义，返回新解锁的成就
    pub fn check(
        &self,
        ctx: &AchievementContext,
        already_unlocked: &[String],
    ) -> Vec<Achievement> {
        let unlocked_set: std::collections::HashSet<&str> =
            already_unlocked.iter().map(|s| s.as_str()).collect();
        let mut new_achievements = Vec::new();
        let now = chrono::Utc::now();

        for def in &self.definitions {
            if unlocked_set.contains(def.id.as_str()) {
                continue;
            }
            if self.evaluate_achievement(def, ctx) {
                new_achievements.push(Achievement {
                    id: format!("{}-{}", ctx.user_id, def.id),
                    user_id: ctx.user_id.clone(),
                    achievement_key: def.id.clone(),
                    name: def.name.zh().to_string(),
                    icon: def.icon.clone(),
                    color: def.color.clone(),
                    tier: def.tier.clone(),
                    category: def.category.clone(),
                    description: def.description.zh().to_string(),
                    unlocked_at: now,
                });
            }
        }
        new_achievements
    }

    /// 检测并持久化新成就
    pub fn check_and_persist(
        &self,
        conn: &Connection,
        ctx: &AchievementContext,
    ) -> Vec<Achievement> {
        let already_unlocked: Vec<String> = {
            let mut stmt = conn.prepare(
                "SELECT achievement_key FROM achievements WHERE user_id = ?1"
            ).unwrap();
            stmt.query_map(rusqlite::params![ctx.user_id], |row| row.get::<_, String>(0))
                .unwrap()
                .filter_map(|r| r.ok())
                .collect()
        };

        let new_ones = self.check(ctx, &already_unlocked);
        for a in &new_ones {
            let _ = conn.execute(
                "INSERT OR IGNORE INTO achievements (id, user_id, achievement_key, name, icon, tier, source, unlocked_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    a.id, a.user_id, a.achievement_key, a.name, a.icon,
                    a.tier, a.category, a.unlocked_at.to_rfc3339()
                ],
            );
        }
        new_ones
    }

    /// 求值单个成就的所有条件（按 condition_logic 组合）
    fn evaluate_achievement(&self, def: &AchievementDef, ctx: &AchievementContext) -> bool {
        if def.conditions.is_empty() {
            return false; // 无条件 = 不触发（安全默认）
        }

        let results: Vec<bool> = def.conditions.iter()
            .map(|cond| self.comparison_eval.evaluate(cond, ctx))
            .collect();

        match def.condition_logic.to_uppercase().as_str() {
            "OR" => results.iter().any(|&r| r),
            _ => results.iter().all(|&r| r),  // "AND" 或默认
        }
    }

    /// 成就定义是否匹配当前事件类型
    /// - triggers 为空 → 匹配所有事件（向后兼容）
    /// - 否则 → 必须包含 event_type
    fn matches_event(def: &AchievementDef, event_type: &str) -> bool {
        if def.triggers.is_empty() {
            return true;  // 无 triggers = 通用成就
        }
        def.triggers.iter().any(|t| t == event_type)
    }

    /// 按事件类型检查成就（仅检查 triggers 匹配的成就定义）
    pub fn check_on_event(
        &self,
        event_type: &str,
        ctx: &AchievementContext,
        already_unlocked: &[String],
    ) -> Vec<Achievement> {
        let unlocked_set: std::collections::HashSet<&str> =
            already_unlocked.iter().map(|s| s.as_str()).collect();
        let mut new_achievements = Vec::new();
        let now = chrono::Utc::now();

        for def in &self.definitions {
            if unlocked_set.contains(def.id.as_str()) {
                continue;
            }
            if !Self::matches_event(def, event_type) {
                continue;
            }
            if self.evaluate_achievement(def, ctx) {
                new_achievements.push(Achievement {
                    id: format!("{}-{}", ctx.user_id, def.id),
                    user_id: ctx.user_id.clone(),
                    achievement_key: def.id.clone(),
                    name: def.name.zh().to_string(),
                    icon: def.icon.clone(),
                    color: def.color.clone(),
                    tier: def.tier.clone(),
                    category: def.category.clone(),
                    description: def.description.zh().to_string(),
                    unlocked_at: now,
                });
            }
        }
        new_achievements
    }

    /// 按事件类型检测并持久化新成就
    pub fn check_and_persist_on_event(
        &self,
        event_type: &str,
        conn: &Connection,
        ctx: &AchievementContext,
    ) -> Vec<Achievement> {
        let already_unlocked: Vec<String> = {
            let mut stmt = conn.prepare(
                "SELECT achievement_key FROM achievements WHERE user_id = ?1"
            ).unwrap();
            stmt.query_map(rusqlite::params![ctx.user_id], |row| row.get::<_, String>(0))
                .unwrap()
                .filter_map(|r| r.ok())
                .collect()
        };

        let new_ones = self.check_on_event(event_type, ctx, &already_unlocked);
        for a in &new_ones {
            let _ = conn.execute(
                "INSERT OR IGNORE INTO achievements (id, user_id, achievement_key, name, icon, tier, source, unlocked_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    a.id, a.user_id, a.achievement_key, a.name, a.icon,
                    a.tier, a.category, a.unlocked_at.to_rfc3339()
                ],
            );
        }
        new_ones
    }
}

// ── 旧 AchievementDetector 兼容层 ──

/// 旧版成就检测器（兼容过渡期调用）
/// Phase 2 事件总线完成后可移除
pub struct AchievementDetector;

impl AchievementDetector {
    pub fn new() -> Self { Self }

    /// 旧版 check（使用 Legacy 格式，返回旧版 Achievement）
    pub fn check_legacy(
        &self,
        definitions: &[shared_types::growth::AchievementDefLegacy],
        ctx: &AchievementContext,
        already_unlocked: &[String],
    ) -> Vec<shared_types::growth::Achievement> {
        let unlocked_set: std::collections::HashSet<&str> =
            already_unlocked.iter().map(|s| s.as_str()).collect();
        let mut new_achievements = Vec::new();
        let now = chrono::Utc::now();

        for def in definitions {
            if unlocked_set.contains(def.id.as_str()) {
                continue;
            }
            if legacy_condition_met(&def.condition, ctx) {
                new_achievements.push(shared_types::growth::Achievement {
                    id: format!("{}-{}", ctx.user_id, def.id),
                    user_id: ctx.user_id.clone(),
                    achievement_key: def.id.clone(),
                    name: def.name.clone(),
                    icon: def.icon.clone(),
                    color: shared_types::growth::match_color(&def.id),
                    tier: shared_types::growth::match_tier(&def.id),
                    category: shared_types::growth::match_category(&def.id),
                    description: def.description.clone(),
                    unlocked_at: now,
                });
            }
        }
        new_achievements
    }
}

/// 旧版条件判断（字符串解析）
fn legacy_condition_met(condition: &str, ctx: &AchievementContext) -> bool {
    if condition == "first_card" { return ctx.total_cards >= 1 }

    let parts: Vec<&str> = condition.split_whitespace().collect();
    if parts.len() != 3 { return false; }

    let field = parts[0];
    let op = parts[1];
    let threshold: u32 = match parts[2].parse() {
        Ok(v) => v,
        Err(_) => return false,
    };

    let value = match field {
        "total_cards" => ctx.total_cards,
        "total_reviews" => ctx.total_reviews,
        "streak_days" => ctx.streak_days,
        "domains_covered" => ctx.domains_covered,
        _ => return false,
    };

    match op {
        ">=" => value >= threshold,
        ">" => value > threshold,
        "==" => value == threshold,
        _ => false,
    }
}

// ── 测试 ──

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_ctx() -> AchievementContext {
        AchievementContext {
            user_id: "u1".into(),
            total_cards: 50,
            total_reviews: 100,
            streak_days: 7,
            domains_covered: 3,
            plans_completed: 0,
            conversations_completed: 0,
            ..Default::default()
        }
    }

    // ── 旧版测试（保持兼容） ──

    #[test]
    fn test_collector_50_unlocks_legacy() {
        let defs = shared_types::growth::AchievementDefLegacy::predefined();
        let detector = AchievementDetector;
        let ctx = sample_ctx();
        let result = detector.check_legacy(&defs, &ctx, &[]);
        assert!(result.iter().any(|a| a.achievement_key == "cards_50"));
    }

    #[test]
    fn test_first_card_not_unlocked_when_below_1_legacy() {
        let ctx = AchievementContext {
            user_id: "u1".into(),
            total_cards: 0,
            total_reviews: 0,
            streak_days: 0,
            domains_covered: 0,
            plans_completed: 0,
            conversations_completed: 0,
            ..Default::default()
        };
        let detector = AchievementDetector;
        let result = detector.check_legacy(
            &[shared_types::growth::AchievementDefLegacy {
                id: "first_card".into(), name: "初识".into(), icon: "auto_stories".into(),
                description: "".into(), condition: "total_cards >= 1".into(),
            }],
            &ctx, &[],
        );
        assert!(result.is_empty());
    }

    #[test]
    fn test_already_unlocked_skipped_legacy() {
        let detector = AchievementDetector;
        let ctx = sample_ctx();
        let already = vec!["cards_50".into(), "streak_7".into()];
        let result = detector.check_legacy(
            &shared_types::growth::AchievementDefLegacy::predefined(),
            &ctx, &already,
        );
        assert!(!result.iter().any(|a| a.achievement_key == "cards_50"));
        assert!(!result.iter().any(|a| a.achievement_key == "streak_7"));
    }

    // ── 新引擎测试 ──

    #[test]
    fn test_engine_from_toml_parses() {
        let toml_str = r##"
[achievements.first_card]
category = "seed"
tier = "bronze"
name = "初识"
description = "创建第一张卡片"
icon = "auto_stories"
color = "#CD7F32"
conditions = [{ metric = "total_cards", op = "gte", value = 1 }]
triggers = ["card_created"]
"##;
        let engine = AchievementEngine::from_toml_str(toml_str).unwrap();
        assert_eq!(engine.definitions.len(), 1);
        assert_eq!(engine.definitions[0].id, "first_card");
        assert_eq!(engine.definitions[0].tier, "bronze");
    }

    #[test]
    fn test_engine_detects_achievement() {
        let toml_str = r##"
[achievements.cards_50]
category = "knowledge"
tier = "silver"
name = "收藏家"
description = "50 张卡片"
icon = "library_books"
color = "#C0C0C0"
conditions = [{ metric = "total_cards", op = "gte", value = 50 }]
triggers = ["card_created"]
"##;
        let engine = AchievementEngine::from_toml_str(toml_str).unwrap();
        let result = engine.check(&sample_ctx(), &[]);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].achievement_key, "cards_50");
    }

    #[test]
    fn test_engine_skips_unlocked() {
        let toml_str = r##"
[achievements.first_card]
category = "seed"
tier = "bronze"
name = "初识"
description = "创建第一张卡片"
icon = "auto_stories"
color = "#CD7F32"
conditions = [{ metric = "total_cards", op = "gte", value = 1 }]
triggers = ["card_created"]
"##;
        let engine = AchievementEngine::from_toml_str(toml_str).unwrap();
        let already = vec!["first_card".to_string()];
        let result = engine.check(&sample_ctx(), &already);
        assert!(result.is_empty());
    }

    #[test]
    fn test_and_conditions_both_required() {
        let toml_str = r##"
[achievements.test_and]
category = "knowledge"
tier = "gold"
name = "Test"
description = "Both required"
icon = "star"
color = "#FFD700"
conditions = [
  { metric = "total_cards", op = "gte", value = 50 },
  { metric = "total_reviews", op = "gte", value = 200 }
]
condition_logic = "AND"
triggers = ["review_completed"]
"##;
        let engine = AchievementEngine::from_toml_str(toml_str).unwrap();
        let result = engine.check(&sample_ctx(), &[]); // 100 reviews, not 200
        assert!(result.is_empty());
    }

    #[test]
    fn test_or_conditions_either() {
        let toml_str = r##"
[achievements.test_or]
category = "knowledge"
tier = "gold"
name = "Test"
description = "Either one"
icon = "star"
color = "#FFD700"
conditions = [
  { metric = "total_cards", op = "gte", value = 500 },
  { metric = "total_reviews", op = "gte", value = 100 }
]
condition_logic = "OR"
triggers = ["review_completed"]
"##;
        let engine = AchievementEngine::from_toml_str(toml_str).unwrap();
        let result = engine.check(&sample_ctx(), &[]); // 100 reviews ✓
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_predefined_fallback() {
        let engine = AchievementEngine::from_predefined();
        assert_eq!(engine.definitions.len(), 10);
    }
}
