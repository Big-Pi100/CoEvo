//! 成就引擎单例模块
//!
//! 通过 std::sync::OnceLock 持有 AchievementEngine 单例，
//! 在 main.rs 启动时初始化，在 routes 中直接使用。
//!
//! Phase 2: 事件总线 — 各触发点调用 `publish(&conn, AppEvent::Xxx{...})` 即可。

use std::sync::OnceLock;
use growth_engine::achievements::AchievementEngine;
use shared_types::growth::AchievementContext;
use rusqlite::Connection;

static ENGINE: OnceLock<AchievementEngine> = OnceLock::new();

/// 初始化全局成就引擎（必须在 main.rs 中调用一次）
pub fn init(path: &str) {
    let engine = match AchievementEngine::from_toml_file(path) {
        Ok(e) => e,
        Err(err) => {
            tracing::warn!("成就引擎 TOML 加载失败，使用硬编码回退: {}", err);
            AchievementEngine::from_predefined()
        }
    };
    if ENGINE.set(engine).is_err() {
        tracing::warn!("成就引擎已被初始化（跳过）");
    }
}

/// 获取全局成就引擎引用（必须先 init）
pub fn get() -> &'static AchievementEngine {
    ENGINE.get().expect("成就引擎未初始化，请在 main.rs 中调用 init()")
}

/// 尝试获取引擎（不 panic，返回 None 时调用方降级到旧逻辑）
pub fn try_get() -> Option<&'static AchievementEngine> {
    ENGINE.get()
}

// ── Phase 2: 事件总线 ──

/// 成就触发事件类型（见设计文档 3.4 节）
///
/// 各触发点构造对应 variant 调用 `publish()` 即可。
/// 新增触发点：定义新 variant + TOML 配置 triggers 字段。
#[derive(Debug, Clone)]
pub enum AppEvent {
    /// 卡片创建后触发
    CardCreated { user_id: String },
    /// 复习提交后触发
    ReviewCompleted { user_id: String },
    /// 对话结束后触发
    ConversationEnded { user_id: String },
    /// 计划完成后触发
    PlanCompleted { user_id: String },
    /// 每日定时触发（带 24h 冷却，调用 check_daily 而非 publish）
    DailyTick { user_id: String },
}

impl AppEvent {
    /// 返回事件类型字符串（对应 TOML triggers 字段）
    fn event_type(&self) -> &'static str {
        match self {
            AppEvent::CardCreated { .. } => "card_created",
            AppEvent::ReviewCompleted { .. } => "review_completed",
            AppEvent::ConversationEnded { .. } => "conversation_ended",
            AppEvent::PlanCompleted { .. } => "plan_completed",
            AppEvent::DailyTick { .. } => "daily_tick",
        }
    }

    fn user_id(&self) -> &str {
        match self {
            AppEvent::CardCreated { user_id }
            | AppEvent::ReviewCompleted { user_id }
            | AppEvent::ConversationEnded { user_id }
            | AppEvent::PlanCompleted { user_id }
            | AppEvent::DailyTick { user_id } => user_id,
        }
    }
}

/// 发布成就事件到引擎（事件总线入口）
///
/// 各触发点只需构造 `AppEvent` variant 调用此函数，
/// 引擎自动按 TOML triggers 过滤匹配的成就并持久化。
pub fn publish(conn: &Connection, event: AppEvent) {
    check(conn, event.event_type(), event.user_id());
}

// ── Phase 2: 事件总线上下文构建 ──

/// 从 DB 动态构建成就检测上下文（Phase 2 事件总线）
/// 用于非 review 触发点（card_created / conversation_ended / plan_completed / daily_tick）
pub fn build_context(conn: &Connection, user_id: &str) -> AchievementContext {
    // ── 已有 6 个指标 ──
    let total_cards: u32 = conn.query_row(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.status = 'active'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    let total_reviews: u32 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    let domains_covered: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT c.domain) FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.status = 'active' AND c.domain IS NOT NULL",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    let streak_days: u32 = conn.query_row(
        "WITH RECURSIVE dates(d) AS (
            SELECT date('now', 'localtime')
            UNION ALL
            SELECT date(d, '-1 day') FROM dates
            WHERE d > date('now', 'localtime', '-365 days')
        )
        SELECT COUNT(*) FROM dates d
        WHERE EXISTS (
            SELECT 1 FROM review_log r
            JOIN cards c ON r.card_id = c.id
            WHERE c.user_id = ?1 AND date(r.reviewed_at, 'unixepoch') = d.d
        )
        AND d >= IFNULL(
            (SELECT date(
                (SELECT date(r.reviewed_at, 'unixepoch') FROM review_log r
                 JOIN cards c ON r.card_id = c.id
                 WHERE c.user_id = ?1
                 ORDER BY r.reviewed_at DESC LIMIT 1),
                '-1 day'
            )),
            date('now', 'localtime', '-1 day')
        )",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    let plans_completed: u32 = conn.query_row(
        "SELECT COUNT(*) FROM conversation_plans cp
         JOIN user_plan_progress upp ON cp.id = upp.plan_id
         WHERE upp.user_id = ?1 AND upp.status = 'completed'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    let conversations_completed: u32 = conn.query_row(
        "SELECT COUNT(*) FROM conversations WHERE user_id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // ── Phase 5: 新增 17 个指标 ──

    // 1. hard_cards_count: difficulty > 7.0 的活跃卡片数（硬卡片）
    let hard_cards_count: u32 = conn.query_row(
        "SELECT COUNT(*) FROM cards c JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.status = 'active' AND cm.difficulty > 7.0",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 2. recent_accuracy_20: 最近 20 次复习准确率 %（必须≥20次复习才统计）
    let recent_accuracy_20: f64 = conn.query_row(
        "WITH recent AS (
            SELECT rating FROM review_log r
            JOIN cards c ON r.card_id = c.id
            WHERE c.user_id = ?1
            ORDER BY r.reviewed_at DESC LIMIT 20
        )
        SELECT CASE WHEN COUNT(*) < 20 THEN 0.0
               ELSE 100.0 * SUM(CASE WHEN rating >= 3 THEN 1 ELSE 0 END) / COUNT(*)
               END
        FROM recent",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0.0);

    // 3. recent_accuracy_50: 最近 50 次复习准确率 %（必须≥50次复习才统计）
    let recent_accuracy_50: f64 = conn.query_row(
        "WITH recent AS (
            SELECT rating FROM review_log r
            JOIN cards c ON r.card_id = c.id
            WHERE c.user_id = ?1
            ORDER BY r.reviewed_at DESC LIMIT 50
        )
        SELECT CASE WHEN COUNT(*) < 50 THEN 0.0
               ELSE 100.0 * SUM(CASE WHEN rating >= 3 THEN 1 ELSE 0 END) / COUNT(*)
               END
        FROM recent",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0.0);

    // 4. recent_accuracy_100: 最近 100 次复习准确率 %（必须≥100次复习才统计）
    let recent_accuracy_100: f64 = conn.query_row(
        "WITH recent AS (
            SELECT rating FROM review_log r
            JOIN cards c ON r.card_id = c.id
            WHERE c.user_id = ?1
            ORDER BY r.reviewed_at DESC LIMIT 100
        )
        SELECT CASE WHEN COUNT(*) < 100 THEN 0.0
               ELSE 100.0 * SUM(CASE WHEN rating >= 3 THEN 1 ELSE 0 END) / COUNT(*)
               END
        FROM recent",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0.0);

    // 5. weekend_streak: 连续有学习的周末数（使用 islands 算法）
    let weekend_streak: u32 = conn.query_row(
        "WITH weekend_activity AS (
             SELECT DISTINCT date(r.reviewed_at, 'weekday 6') as wk_start
             FROM review_log r
             JOIN cards c ON r.card_id = c.id
             WHERE c.user_id = ?1
               AND (strftime('%w', r.reviewed_at) = '0' OR strftime('%w', r.reviewed_at) = '6')
               AND r.reviewed_at >= CAST(strftime('%s', 'now', 'localtime', '-365 days') AS INTEGER)
         ),
         with_gaps AS (
             SELECT wk_start,
                    julianday(wk_start) - julianday(LAG(wk_start, 1) OVER (ORDER BY wk_start)) as gap
             FROM weekend_activity
         ),
         with_islands AS (
             SELECT wk_start,
                    SUM(CASE WHEN COALESCE(gap, 99) > 7 THEN 1 ELSE 0 END) OVER (ORDER BY wk_start) as island_id
             FROM with_gaps
         ),
         user_island AS (
             SELECT island_id FROM with_islands
             WHERE wk_start = (SELECT MAX(wk_start) FROM weekend_activity)
         )
         SELECT COUNT(*) FROM with_islands, user_island
         WHERE with_islands.island_id = user_island.island_id",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 6. night_sessions: 22:00-02:00 学习次数（去重日期，最近 30 天）
    let night_sessions: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT date(r.reviewed_at, 'unixepoch')) FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1
           AND (cast(strftime('%H', r.reviewed_at, 'unixepoch') as integer) >= 22
                OR cast(strftime('%H', r.reviewed_at, 'unixepoch') as integer) < 2)
           AND r.reviewed_at >= CAST(strftime('%s', 'now', 'localtime', '-30 days') AS INTEGER)",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 7. early_sessions: 06:00-08:00 学习次数（去重日期，最近 30 天）
    let early_sessions: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT date(r.reviewed_at, 'unixepoch')) FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1
           AND cast(strftime('%H', r.reviewed_at, 'unixepoch') as integer) >= 6
           AND cast(strftime('%H', r.reviewed_at, 'unixepoch') as integer) < 8
           AND r.reviewed_at >= CAST(strftime('%s', 'now', 'localtime', '-30 days') AS INTEGER)",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 8. hard_perfect_streak: 困难卡片连续正确次数
    //    查找最近一次"未全对"的位置，之后正确的 hard 卡片数即为当前 streak
    let hard_perfect_streak: u32 = conn.query_row(
        "WITH hard_reviews AS (
            SELECT r.rating,
                   ROW_NUMBER() OVER (ORDER BY r.reviewed_at DESC) as rn
            FROM review_log r
            JOIN cards c ON r.card_id = c.id
            JOIN card_memory cm ON c.id = cm.card_id
            WHERE c.user_id = ?1 AND cm.difficulty > 7.0
            ORDER BY r.reviewed_at DESC
            LIMIT 100
        ),
        first_fail AS (
            SELECT MIN(rn) as fail_rn FROM hard_reviews WHERE rating < 3
        )
        SELECT COUNT(*) FROM hard_reviews
        WHERE rn < COALESCE((SELECT fail_rn FROM first_fail), 9999)",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 9. perfect_session_10: 是否存在单次会话（同一天+同一小时）≥10 张全对
    let perfect_session_10: u32 = conn.query_row(
        "WITH sessions AS (
             SELECT date(r.reviewed_at, 'unixepoch') as session_date,
                    strftime('%H', r.reviewed_at, 'unixepoch') as session_hour,
                    r.rating
             FROM review_log r
             JOIN cards c ON r.card_id = c.id
             WHERE c.user_id = ?1
               AND r.reviewed_at >= CAST(strftime('%s', 'now', 'localtime', '-30 days') AS INTEGER)
         )
         SELECT 1 FROM sessions
         GROUP BY session_date, session_hour
         HAVING COUNT(*) >= 10
            AND MIN(rating) >= 3
         LIMIT 1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 10. mature_cards: FSRS Review 状态卡片数（state=2）
    let mature_cards: u32 = conn.query_row(
        "SELECT COUNT(*) FROM card_memory cm
         JOIN cards c ON cm.card_id = c.id
         WHERE c.user_id = ?1 AND cm.state = 2 AND cm.status = 'active'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 11. learning_cards: Learning/Relearning 状态卡片数（state=1 或 3）
    let learning_cards: u32 = conn.query_row(
        "SELECT COUNT(*) FROM card_memory cm
         JOIN cards c ON cm.card_id = c.id
         WHERE c.user_id = ?1 AND cm.state IN (1, 3) AND cm.status = 'active'",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 12. no_skip_streak: 连续不跳过天数
    //     从今天往回数，连续几天满足："有复习 AND 无跳过(rating≠1)"
    //     遇到"未复习"或"有跳过"即断连
    let no_skip_streak: u32 = conn.query_row(
        "WITH RECURSIVE dates(d) AS (
            SELECT date('now', 'localtime')
            UNION ALL
            SELECT date(d, '-1 day') FROM dates
            WHERE d > date('now', 'localtime', '-30 days')
        ),
        daily_status AS (
            SELECT d,
                   EXISTS(SELECT 1 FROM review_log r JOIN cards c ON r.card_id = c.id
                          WHERE c.user_id = ?1 AND date(r.reviewed_at, 'unixepoch') = d.d) as has_review,
                   EXISTS(SELECT 1 FROM review_log r JOIN cards c ON r.card_id = c.id
                          WHERE c.user_id = ?1 AND date(r.reviewed_at, 'unixepoch') = d.d AND r.rating = 1) as has_skip
            FROM dates d
        ),
        break_point AS (
            SELECT MAX(julianday(d) - julianday(date('now', 'localtime'))) as break_offset
            FROM daily_status
            WHERE has_review = 0 OR has_skip = 1
        )
        SELECT CAST(COALESCE(ABS((SELECT break_offset FROM break_point)), 0) AS INTEGER)",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 13. languages_count: 覆盖语言数（从 cards.domain 提取语言前缀，如 "EN::..." 或 "ZH::..."）
    let languages_count: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT 
                CASE 
                    WHEN c.domain LIKE 'EN::%' THEN 'EN'
                    WHEN c.domain LIKE 'ZH::%' THEN 'ZH'
                    WHEN c.domain LIKE 'FR::%' THEN 'FR'
                    WHEN c.domain LIKE 'ES::%' THEN 'ES'
                    WHEN c.domain LIKE 'DE::%' THEN 'DE'
                    WHEN c.domain LIKE 'JA::%' THEN 'JA'
                    WHEN c.domain LIKE 'KO::%' THEN 'KO'
                    ELSE 'OTHER'
                END)
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.status = 'active' AND c.domain IS NOT NULL",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 14. cards_in_1h: 是否存在 1 小时内创建 ≥20 张卡片（滑动窗口）
    let cards_in_1h: u32 = conn.query_row(
        "WITH card_times AS (
             SELECT created_at,
                    LEAD(created_at, 19) OVER (ORDER BY created_at) as window_end
             FROM cards
             WHERE user_id = ?1
               AND created_at >= CAST(strftime('%s', 'now', 'localtime', '-90 days') AS INTEGER)
         )
         SELECT 1 FROM card_times
         WHERE window_end IS NOT NULL
           AND (window_end - created_at) <= 3600
         LIMIT 1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 15. days_since_last_review: 距上次复习天数（无复习记录 = 0，不触发"回归"类成就）
    let days_since_last_review: u32 = conn.query_row(
        "SELECT COALESCE(CAST((CAST(strftime('%s', 'now') AS INTEGER) - MAX(r.reviewed_at)) / 86400 AS INTEGER), 0)
         FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 16. reviews_today: 今日复习次数
    let reviews_today: u32 = conn.query_row(
        "SELECT COUNT(*) FROM review_log r
         JOIN cards c ON r.card_id = c.id
         WHERE c.user_id = ?1 AND date(r.reviewed_at, 'unixepoch') = date('now', 'localtime')",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    // 17. days_since_reg: 注册至今天数
    let days_since_reg: u32 = conn.query_row(
        "SELECT COALESCE(CAST(julianday('now', 'localtime') - julianday(created_at) AS INTEGER), 9999)
         FROM users WHERE id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(9999);

    // 18. subjects_count: 覆盖 K12 学科数（从 domain 提取 :: 之间的学科名去重）
    let subjects_count: u32 = conn.query_row(
        "SELECT COUNT(DISTINCT 
            CASE 
                WHEN c.domain LIKE '%::%::%' THEN
                    SUBSTR(c.domain, 
                           INSTR(c.domain, '::') + 2,
                           INSTR(SUBSTR(c.domain, INSTR(c.domain, '::') + 2), '::') - 1)
                WHEN c.domain LIKE '%::%' THEN
                    SUBSTR(c.domain, INSTR(c.domain, '::') + 2)
                ELSE c.domain
            END)
         FROM cards c
         JOIN card_memory cm ON c.id = cm.card_id
         WHERE c.user_id = ?1 AND cm.status = 'active' AND c.domain IS NOT NULL",
        rusqlite::params![user_id],
        |row| row.get(0),
    ).unwrap_or(0);

    AchievementContext {
        user_id: user_id.to_string(),
        total_cards,
        total_reviews,
        streak_days,
        domains_covered,
        plans_completed,
        conversations_completed,
        hard_cards_count,
        recent_accuracy_20,
        recent_accuracy_50,
        recent_accuracy_100,
        weekend_streak,
        night_sessions,
        early_sessions,
        hard_perfect_streak,
        perfect_session_10,
        mature_cards,
        learning_cards,
        no_skip_streak,
        languages_count,
        cards_in_1h,
        days_since_last_review,
        reviews_today,
        days_since_reg,
        subjects_count,
    }
}

/// 事件总线入口：根据事件类型检查并持久化新成就
/// 各触发点只需调用此函数即可
pub fn check(conn: &Connection, event_type: &str, user_id: &str) {
    let engine = match try_get() {
        Some(e) => e,
        None => return,
    };
    let ctx = build_context(conn, user_id);
    let new_ones = engine.check_and_persist_on_event(event_type, conn, &ctx);
    if !new_ones.is_empty() {
        tracing::info!(
            "成就事件 {}: 用户 {} 解锁 {} 个新成就: {:?}",
            event_type, user_id, new_ones.len(),
            new_ones.iter().map(|a| a.achievement_key.as_str()).collect::<Vec<_>>()
        );
    }
}

/// 每日定时触发（带冷却：同一用户 24h 内只触发一次）
/// 可在任何高频路径调用，不会重复执行
pub fn check_daily(conn: &Connection, user_id: &str) {
    // 检查距上次触发是否超过 24 小时
    let should_run: bool = conn.query_row(
        "SELECT
            CASE
                WHEN MAX(unlocked_at) IS NULL THEN 1
                WHEN strftime('%s', 'now') - strftime('%s', MAX(unlocked_at)) > 86400 THEN 1
                ELSE 0
            END
         FROM achievements
         WHERE user_id = ?1 AND achievement_key = '__daily_tick'",
        rusqlite::params![user_id],
        |row| row.get::<_, i32>(0).map(|v| v == 1),
    ).unwrap_or(true);

    if should_run {
        // 写入标记行阻止重复触发
        let _ = conn.execute(
            "INSERT OR REPLACE INTO achievements (id, user_id, achievement_key, name, icon, tier, source, unlocked_at)
             VALUES (?1, ?2, '__daily_tick', '_internal', '_internal', 'bronze', '_internal', ?3)",
            rusqlite::params![
                format!("{}-__daily_tick", user_id),
                user_id,
                chrono::Utc::now().to_rfc3339()
            ],
        );
        check(conn, "daily_tick", user_id);
    }
}
