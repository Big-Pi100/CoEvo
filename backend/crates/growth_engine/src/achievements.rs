//! N7: 成就检测
//!
//! 适配自 LinguaFlow growth_engine/src/achievements.rs
//! 触发点: 制卡后 + 复习后

use shared_types::growth::{Achievement, AchievementDef, AchievementContext};
use rusqlite::Connection;

/// 成就检测器
pub struct AchievementDetector;

impl Default for AchievementDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl AchievementDetector {
    pub fn new() -> Self {
        Self
    }

    /// 检查所有成就定义，返回新解锁的成就
    pub fn check(
        &self,
        definitions: &[AchievementDef],
        ctx: &AchievementContext,
        already_unlocked: &[String],
    ) -> Vec<Achievement> {
        let unlocked_set: std::collections::HashSet<&str> =
            already_unlocked.iter().map(|s| s.as_str()).collect();
        let mut new_achievements = Vec::new();

        for def in definitions {
            if unlocked_set.contains(def.id.as_str()) {
                continue;
            }
            if is_condition_met(&def.condition, ctx) {
                new_achievements.push(Achievement {
                    id: format!("{}-{}", ctx.user_id, def.id),
                    user_id: ctx.user_id.clone(),
                    achievement_key: def.id.clone(),
                    name: def.name.clone(),
                    icon: def.icon.clone(),
                    unlocked_at: chrono::Utc::now(),
                });
            }
        }
        new_achievements
    }

    /// 检测并持久化新成就
    pub fn check_and_persist(
        &self,
        conn: &Connection,
        definitions: &[AchievementDef],
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

        let new_ones = self.check(definitions, ctx, &already_unlocked);
        for a in &new_ones {
            let _ = conn.execute(
                "INSERT INTO achievements (id, user_id, achievement_key, name, icon, unlocked_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![a.id, a.user_id, a.achievement_key, a.name, a.icon, a.unlocked_at.to_rfc3339()],
            );
        }
        new_ones
    }
}

fn is_condition_met(condition: &str, ctx: &AchievementContext) -> bool {
    // Named conditions
    if condition == "first_card" { return ctx.total_cards >= 1 }

    // Numeric: "key >= value"
    parse_numeric(condition, ctx)
}

fn parse_numeric(condition: &str, ctx: &AchievementContext) -> bool {
    let parts: Vec<&str> = condition.split_whitespace().collect();
    if parts.len() != 3 {
        return false;
    }

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
        }
    }

    #[test]
    fn test_collector_50_unlocks() {
        let defs = AchievementDef::predefined();
        let detector = AchievementDetector;
        let ctx = sample_ctx();
        let result = detector.check(&defs, &ctx, &[]);
        assert!(result.iter().any(|a| a.achievement_key == "collector_50"));
    }

    #[test]
    fn test_first_card_not_unlocked_when_below_1() {
        let ctx = AchievementContext {
            user_id: "u1".into(),
            total_cards: 0,
            total_reviews: 0,
            streak_days: 0,
            domains_covered: 0,
        };
        let detector = AchievementDetector;
        let result = detector.check(&[AchievementDef {
            id: "first_card".into(),
            name: "初识".into(),
            icon: "🌟".into(),
            description: "".into(),
            condition: "total_cards >= 1".into(),
        }], &ctx, &[]);
        assert!(result.is_empty());
    }

    #[test]
    fn test_already_unlocked_skipped() {
        let detector = AchievementDetector;
        let ctx = sample_ctx();
        let already = vec!["collector_50".into(), "streak_7".into()];
        let result = detector.check(&AchievementDef::predefined(), &ctx, &already);
        assert!(!result.iter().any(|a| a.achievement_key == "collector_50"));
        assert!(!result.iter().any(|a| a.achievement_key == "streak_7"));
    }
}
