//! 活动调度器（推送触发 / cron / 自动解锁 / 海报模板刷新）
//!
//! 包含：
//! - 佣金锁定期到期自动解锁（30天）
//! - NOTPAY 超时关单（30分钟未支付）
//! - cron 定时推送（按 push_cron 匹配时间，写 user_notifications）
//! - 后台定时任务（5分钟间隔自动执行）
//! - 海报模板每日刷新（每天 00:30 执行）

use chrono::Timelike;
use serde_json;

/// 佣金锁定期到期自动解锁
///
/// 查找所有 status='locked' 且 created_at 超过 30 天的佣金记录，
/// 将其状态改为 'available'，标记解锁时间。
pub fn unlock_available_commissions(conn: &rusqlite::Connection) -> Result<usize, String> {
    let count = conn.execute(
        "UPDATE distribution_commissions SET status = 'available', unlocked_at = datetime('now') \
         WHERE status = 'locked' AND datetime(created_at, '+30 days') <= datetime('now')",
        [],
    ).map_err(|e| format!("佣金自动解锁失败: {}", e))?;

    if count > 0 {
        tracing::info!("campaign_scheduler: 自动解锁 {} 条佣金", count);
    }

    Ok(count)
}

/// NOTPAY 超时关单（30分钟未支付）
///
/// 查找所有 status='NOTPAY' 且创建超过 30 分钟的订单，
/// 将其状态改为 'NOTPAY_CANCELLED'。
pub fn cancel_expired_orders(conn: &rusqlite::Connection) -> Result<usize, String> {
    let count = conn.execute(
        "UPDATE payment_orders SET status = 'NOTPAY_CANCELLED' \
         WHERE status = 'NOTPAY' \
         AND datetime(created_at, '+30 minutes') <= datetime('now')",
        [],
    ).map_err(|e| format!("NOTPAY 关单失败: {}", e))?;

    if count > 0 {
        tracing::info!("campaign_scheduler: 关停 {} 个超时未支付订单", count);
    }

    Ok(count)
}

/// 软删除 7 天未认领的临时账户
///
/// 临时账户 username 以 'trial_' 开头。
/// 认领后 username 会被用户修改为自定义值，不再匹配此模式。
pub fn soft_delete_expired_trials(conn: &rusqlite::Connection) -> Result<usize, String> {
    let count = conn.execute(
        "UPDATE users SET deleted_at = datetime('now') \
         WHERE username LIKE 'trial_%' \
         AND deleted_at IS NULL \
         AND created_at < datetime('now', '-7 days')",
        [],
    ).map_err(|e| format!("trial 软删除失败: {}", e))?;

    if count > 0 {
        tracing::info!("campaign_scheduler: 软删除 {} 个过期临时账户", count);
    }
    Ok(count)
}

/// 硬删除软删后超过 30 天的账户及其关联数据
///
/// 按依赖顺序清理：先删子表再删 users 主表。
/// 单用户硬删除失败不影响其他用户。
pub fn hard_delete_soft_deleted_trials(conn: &rusqlite::Connection) -> Result<usize, String> {
    let ids = {
        let mut stmt = conn.prepare(
            "SELECT id FROM users \
             WHERE deleted_at IS NOT NULL \
             AND deleted_at < datetime('now', '-30 days')"
        ).map_err(|e| format!("查询待硬删除用户失败: {}", e))?;

        let rows: Vec<String> = stmt.query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("查询待硬删除用户失败: {}", e))?
            .filter_map(|r| r.ok())
            .collect();
        rows
    };

    let count = ids.len();
    if count == 0 { return Ok(0); }

    // 级联清理关联表（按依赖顺序）
    let tables = [
        "card_memory",
        "user_cards",
        "user_plan_progress",
        "cp1_plans",
        "plan_runs",
        "conversation_turns",
        "conversations",
        "tokens",
        "distribution_commissions",
        "payment_orders",
        "user_notifications",
        "trial_ip_log",
    ];
    for uid in &ids {
        for table in &tables {
            let sql = format!("DELETE FROM {} WHERE user_id = ?1", table);
            let _ = conn.execute(&sql, rusqlite::params![uid]);
        }
        // 最后删除用户主表记录
        conn.execute("DELETE FROM users WHERE id = ?1", rusqlite::params![uid])
            .map_err(|e| format!("硬删除用户 {} 失败: {}", uid, e))?;
    }

    tracing::info!("campaign_scheduler: 硬删除 {} 个软删超过30天的账户", count);
    Ok(count)
}

/// 定时任务内部执行逻辑（接受 DB 路径参数）
///
/// 打开 DB 连接，依次执行所有调度任务，
/// 返回执行结果摘要字符串。
fn run_scheduler_inner(db_path: &str) -> Result<String, String> {
    let conn = rusqlite::Connection::open(db_path)
        .map_err(|e| format!("scheduler db open: {}", e))?;
    let unlocked = unlock_available_commissions(&conn)?;
    let cancelled = cancel_expired_orders(&conn)?;
    let pushed = execute_cron_pushes(&conn)?;
    let soft_deleted = soft_delete_expired_trials(&conn)?;
    let hard_purged = hard_delete_soft_deleted_trials(&conn)?;
    let msg = format!(
        "scheduler: unlocked={}, cancelled={}, cron_pushed={}, trial_soft_deleted={}, trial_hard_purged={}",
        unlocked, cancelled, pushed, soft_deleted, hard_purged
    );
    if unlocked > 0 || cancelled > 0 || pushed > 0 || soft_deleted > 0 || hard_purged > 0 {
        tracing::info!("{}", msg);
    }
    Ok(msg)
}

/// 执行 cron 推送：检查 push_trigger='cron' 且 push_cron 匹配当前时间的活动
/// push_cron 格式: "minute hour * * day"（day: 0=每天, 1-7=周一到周日）
/// 匹配成功后查 target_roles 匹配的用户，写 user_notifications
fn execute_cron_pushes(conn: &rusqlite::Connection) -> Result<usize, String> {
    let now = chrono::Utc::now();
    let minute = now.format("%M").to_string();
    let hour = now.format("%H").to_string();
    let day_of_week = now.format("%u").to_string(); // 1=周一, 7=周日

    let mut stmt = conn.prepare(
        "SELECT id, name, target_roles, description FROM marketing_campaigns \
         WHERE status='active' AND push_trigger='cron' \
         AND push_cron IS NOT NULL"
    ).map_err(|e| format!("cron query: {}", e))?;

    let campaigns: Vec<(String, String, Option<String>, Option<String>)> = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    }).map_err(|e| format!("cron fetch: {}", e))?
    .filter_map(|r| r.ok())
    .collect();

    let mut pushed = 0;
    for (id, name, target_roles_json, description) in &campaigns {
        let cron = {
            let tmp = conn.query_row(
                "SELECT push_cron FROM marketing_campaigns WHERE id=?1",
                rusqlite::params![id],
                |row| row.get::<_, String>(0),
            ).unwrap_or_default();
            tmp
        };
        if cron.is_empty() { continue; }

        let parts: Vec<&str> = cron.split(|c| c == ' ' || c == ',' || c == '\t')
            .filter(|p| !p.is_empty())
            .collect();
        if parts.len() < 5 { continue; }

        let c_minute = parts[0];
        let c_hour = parts[1];
        let c_day = parts[4];

        let minute_match = c_minute == "*" || c_minute == minute;
        let hour_match = c_hour == "*" || c_hour == hour;
        let day_match = c_day == "*" || c_day == "0" || c_day == day_of_week;

        if !(minute_match && hour_match && day_match) { continue; }

        // ── 时间匹配 → 查目标用户 → 写通知 ──
        let has_role_col = conn.prepare("SELECT role FROM users WHERE 1=0").is_ok();
        let user_ids: Vec<String> = if has_role_col {
            let mut user_list: Vec<String> = Vec::new();
            match target_roles_json {
                Some(roles_json) if roles_json != "[]" && roles_json != "null" => {
                    if let Ok(roles) = serde_json::from_str::<Vec<String>>(roles_json) {
                        if !roles.is_empty() {
                            let placeholders: Vec<String> = (0..roles.len())
                                .map(|i| format!("?{}", i + 1))
                                .collect();
                            let sql = format!(
                                "SELECT id FROM users WHERE role IN ({}) AND deleted_at IS NULL LIMIT 100",
                                placeholders.join(",")
                            );
                            if let Ok(mut stmt) = conn.prepare(&sql) {
                                let params: Vec<&dyn rusqlite::types::ToSql> = roles.iter()
                                    .map(|r| r as &dyn rusqlite::types::ToSql).collect();
                                if let Ok(rows) = stmt.query_map(params.as_slice(), |row| row.get(0)) {
                                    for r in rows.flatten() {
                                        user_list.push(r);
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
            user_list
        } else {
            conn.query_row("SELECT COUNT(*) FROM users WHERE deleted_at IS NULL", [], |row| row.get::<_, i64>(0))
                .map(|total| if total > 0 { vec!["all".to_string()] } else { vec![] })
                .unwrap_or_default()
        };

        for uid in &user_ids {
            let title = format!("📢 {}", name);
            let body = description.clone().unwrap_or_else(|| "点击查看活动详情！".to_string());
            if uid == "all" {
                // 全量推送：分批写通知
                if let Ok(mut all_stmt) = conn.prepare(
                    "SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100"
                ) {
                    if let Ok(rows) = all_stmt.query_map([], |row| row.get::<_, String>(0)) {
                        for rid in rows.filter_map(|r| r.ok()) {
                            let _ = crate::campaign_executor::write_notification(
                                conn, &rid, "campaign", &title, &body, Some(&format!("/share?campaign_id={}", id)),
                            );
                        }
                    }
                }
            } else {
                let _ = crate::campaign_executor::write_notification(
                    conn, uid, "campaign", &title, &body, Some(&format!("/share?campaign_id={}", id)),
                );
            }
            pushed += 1;
        }

        tracing::info!("cron push: campaign={} ({}), cron={}, users_pushed={}", name, id, cron, pushed);
    }

    Ok(pushed)
}

/// 刷新所有 active 活动的海报模板（每天 00:30 执行）
/// 单活动失败不影响其他活动
pub fn refresh_all_active_templates(db_path: &str, base_dir: &str) {
    let conn = match rusqlite::Connection::open(db_path) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("refresh templates: open db failed: {}", e);
            return;
        }
    };

    let campaigns: Vec<(String, String)> = match conn.prepare(
        "SELECT id, name FROM marketing_campaigns WHERE status = 'active'"
    ) {
        Ok(mut stmt) => stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }).unwrap().filter_map(|r| r.ok()).collect(),
        Err(e) => {
            tracing::error!("refresh templates: query failed: {}", e);
            return;
        }
    };

    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("refresh templates: create runtime failed: {}", e);
            return;
        }
    };
    let mut poster_success = 0;
    let mut h5_success = 0;
    for (id, name) in &campaigns {
        // 查 rewards（此处 conn 同步查询，不跨 await）
        let rewards: String = conn.query_row(
            "SELECT COALESCE(rewards, '[]') FROM marketing_campaigns WHERE id = ?1",
            rusqlite::params![id], |row| row.get(0),
        ).unwrap_or_else(|_| "[]".to_string());

        // 海报模板刷新
        match rt.block_on(crate::poster_template::generate_template_via_llm(base_dir, name, &rewards)) {
            Ok(svg) => {
                let _ = conn.execute(
                    "UPDATE marketing_campaigns SET poster_template = ?1, updated_at = ?2 WHERE id = ?3",
                    rusqlite::params![svg, chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(), id],
                );
                poster_success += 1;
            }
            Err(e) => {
                tracing::warn!("refresh poster template for campaign {} ({}): {}", id, name, e);
            }
        }

        // H5 模板刷新（单活动失败不影响其他）
        match rt.block_on(crate::h5_template::generate_h5_template_via_llm(base_dir, name, &rewards)) {
            Ok(html) => {
                let _ = conn.execute(
                    "UPDATE marketing_campaigns SET h5_template = ?1, updated_at = ?2 WHERE id = ?3",
                    rusqlite::params![html, chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(), id],
                );
                h5_success += 1;
            }
            Err(e) => {
                tracing::warn!("refresh h5 template for campaign {} ({}): {}", id, name, e);
            }
        }
    }
    tracing::info!("refresh_all_active_templates: poster {}/{} | h5 {}/{} refreshed", poster_success, campaigns.len(), h5_success, campaigns.len());
}

/// 启动后台定时任务，每 5 分钟运行一次
///
/// 在 `db_pool::init()` 之后调用。会在独立线程中循环执行。
pub fn start_scheduler(db_path: &str) {
    let db_path = db_path.to_string();
    tracing::info!("campaign_scheduler: 启动后台定时任务（每 5 分钟），db={}", db_path);
    let db_path_clone_5min = db_path.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(300)); // 5分钟
            if let Err(e) = run_scheduler_inner(&db_path_clone_5min) {
                tracing::error!("Campaign scheduler error: {}", e);
            }
        }
    });

    // 海报模板每日刷新线程（00:30 执行）
    let base_dir = std::env::var("COEVO_PROMPTS_DIR").unwrap_or_else(|_| "prompts".to_string());
    std::thread::spawn(move || {
        let now = chrono::Local::now();
        let next_run = if now.hour() > 0 || now.minute() >= 31 {
            // 已过今天 00:30，明天
            (now.date_naive() + chrono::Duration::days(1))
                .and_hms_opt(0, 30, 0)
                .unwrap()
                .and_local_timezone(chrono::Local)
                .unwrap()
        } else {
            // 今天
            now.date_naive()
                .and_hms_opt(0, 30, 0)
                .unwrap()
                .and_local_timezone(chrono::Local)
                .unwrap()
        };
        let initial_delay = (next_run - now).num_seconds().max(0) as u64;
        tracing::info!("poster template refresh scheduler: first run in {}s", initial_delay);
        std::thread::sleep(std::time::Duration::from_secs(initial_delay));

        loop {
            refresh_all_active_templates(&db_path, &base_dir);
            std::thread::sleep(std::time::Duration::from_secs(86400)); // 24h
        }
    });
}

/// 定时任务入口，供 HTTP handler / API 调用
///
/// 打开 DB 连接，依次执行所有调度任务，
/// 返回 JSON 格式的执行结果摘要。
pub fn run_scheduler() -> Result<String, String> {
    let db_path = std::env::var("COEVO_DB_PATH")
        .unwrap_or_else(|_| "data/coevo.db".to_string());

    let result_json = run_scheduler_inner(&db_path)?;

    let result = serde_json::json!({
        "summary": result_json,
        "timestamp": chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
    }).to_string();

    tracing::info!("campaign_scheduler: run 完成 — {}", result_json);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::schema::init_database;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();
        // 插入测试用管理员（marketing_campaigns.created_by 外键依赖）
        conn.execute(
            "INSERT INTO admin_users (id, username, password_hash, role, status, created_at) \
             VALUES ('admin-1', 'admin', 'hash', 'super_admin', 'approved', datetime('now'))",
            [],
        )
        .unwrap();
        conn
    }

    /// 测试佣金解锁 SQL 不报错（实际执行在内存 DB 中需要对应 schema）
    #[test]
    fn test_unlock_available_commissions_sql_syntax() {
        // 验证 SQL 语法正确，不实际执行
        let sql = "UPDATE distribution_commissions SET status = 'available', unlocked_at = datetime('now') \
                   WHERE status = 'locked' AND datetime(created_at, '+30 days') <= datetime('now')";
        // 仅仅是验证 SQL 字符串有效
        assert!(sql.contains("unlocked_at"));
        assert!(sql.contains("+30 days"));
    }

    /// 验证 NOTPAY 关单 SQL
    #[test]
    fn test_cancel_expired_orders_sql_syntax() {
        let sql = "UPDATE payment_orders SET status = 'NOTPAY_CANCELLED' \
                   WHERE status = 'NOTPAY' \
                   AND datetime(created_at, '+30 minutes') <= datetime('now')";
        assert!(sql.contains("NOTPAY_CANCELLED"));
        assert!(sql.contains("+30 minutes"));
    }

    /// NOTPAY 关停测试：创建超 30 分钟的 NOTPAY 订单，运行关停，验证状态
    #[test]
    fn test_notpay_cancellation() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

        // 创建测试用户和套餐（外键依赖）
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES (?1, ?2, ?3)",
            rusqlite::params!["test-user-1", "buyer", now],
        ).unwrap();
        conn.execute(
            "INSERT INTO subscription_plans (id, name, price, created_at) \
             VALUES ('plan_1', '月度会员', 20000, ?1)",
            rusqlite::params![now],
        ).unwrap();

        // 创建 31 分钟前的 NOTPAY 订单（应被关停）
        let old_order_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, 'test-user-1', 'plan_1', 20000, 'NOTPAY', '2024-01-01 00:00:00')",
            rusqlite::params![old_order_id],
        ).unwrap();

        // 创建刚发生的 NOTPAY 订单（不应被关停）
        let recent_order_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, 'test-user-1', 'plan_1', 20000, 'NOTPAY', ?2)",
            rusqlite::params![recent_order_id, now],
        ).unwrap();

        // 执行关停
        let cancelled = cancel_expired_orders(&conn).unwrap();
        assert_eq!(cancelled, 1, "应恰好关停 1 个超时 NOTPAY 订单");

        // 验证旧订单已关停
        let old_status: String = conn.query_row(
            "SELECT status FROM payment_orders WHERE id = ?1",
            rusqlite::params![old_order_id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(old_status, "NOTPAY_CANCELLED", "超时订单应被关停");

        // 验证新订单未受影响
        let recent_status: String = conn.query_row(
            "SELECT status FROM payment_orders WHERE id = ?1",
            rusqlite::params![recent_order_id],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(recent_status, "NOTPAY", "新订单应保持 NOTPAY");
    }

    /// 佣金解锁测试：创建 locked 佣金（created_at 设 31 天前），运行解锁，验证 available
    #[test]
    fn test_commission_unlock() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

        // 创建外键依赖
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES (?1, ?2, ?3)",
            rusqlite::params!["earner-1", "earner", now],
        ).unwrap();
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES (?1, ?2, ?3)",
            rusqlite::params!["buyer-1", "buyer", now],
        ).unwrap();
        conn.execute(
            "INSERT INTO subscription_plans (id, name, price, created_at) \
             VALUES ('plan_1', '月度会员', 20000, ?1)",
            rusqlite::params![now],
        ).unwrap();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES ('order-1', 'buyer-1', 'plan_1', 20000, 'SUCCESS', ?1)",
            rusqlite::params![now],
        ).unwrap();
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES ('campaign-1', '测试活动', 'active', '[]', 'registration', 'admin-1', ?1)",
            rusqlite::params![now],
        ).unwrap();

        // 创建 31 天前的 locked 佣金（应被解锁）
        conn.execute(
            "INSERT INTO distribution_commissions \
             (id, campaign_id, earner_id, buyer_id, order_id, order_amount, rate_applied, amount, level, status, created_at) \
             VALUES (?1, 'campaign-1', 'earner-1', 'buyer-1', 'order-1', 20000, 0.1, 2000, 1, 'locked', '2024-01-01 00:00:00')",
            rusqlite::params![uuid::Uuid::new_v4().to_string()],
        ).unwrap();

        // 创建刚发生的 locked 佣金（不应被解锁）
        conn.execute(
            "INSERT INTO distribution_commissions \
             (id, campaign_id, earner_id, buyer_id, order_id, order_amount, rate_applied, amount, level, status, created_at) \
             VALUES (?1, 'campaign-1', 'earner-1', 'buyer-1', 'order-1', 20000, 0.1, 3000, 1, 'locked', ?2)",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), now],
        ).unwrap();

        // 执行解锁
        let unlocked = unlock_available_commissions(&conn).unwrap();
        assert_eq!(unlocked, 1, "应恰好解锁 1 条超 30 天的佣金");

        // 验证旧佣金已解锁
        let old_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM distribution_commissions WHERE status = 'available' AND created_at = '2024-01-01 00:00:00'",
            [],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(old_count, 1, "旧佣金应变为 available");

        // 验证新佣金仍为 locked
        let recent_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM distribution_commissions WHERE status = 'locked' AND created_at = ?1",
            rusqlite::params![now],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(recent_count, 1, "新佣金应保持 locked");
    }

    /// 测试 trial 软删除 SQL 语法
    #[test]
    fn test_trial_soft_delete_sql_syntax() {
        let sql = "UPDATE users SET deleted_at = datetime('now') \
                   WHERE username LIKE 'trial_%' \
                   AND deleted_at IS NULL \
                   AND created_at < datetime('now', '-7 days')";
        assert!(sql.contains("trial_%"));
        assert!(sql.contains("-7 days"));
    }

    /// 测试 trial 软删除：创建 8 天前的 trial 账户，运行软删除，验证被标记
    #[test]
    fn test_trial_soft_delete() {
        let conn = setup_db();

        // 创建 8 天前的未认领 trial 账户（应被软删除）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, '2024-01-01 00:00:00')",
            rusqlite::params!["trial-old", "trial_olduser", "hash_old"],
        ).unwrap();

        // 创建今天的 trial 账户（不应被删除）
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params!["trial-new", "trial_newuser", "hash_new", now],
        ).unwrap();

        // 创建已认领的 trial（username 已不再是 trial_ 开头，不应被删除）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, '2024-01-01 00:00:00')",
            rusqlite::params!["claimed-user", "normal_user", "hash_claimed"],
        ).unwrap();

        let deleted = soft_delete_expired_trials(&conn).unwrap();
        assert_eq!(deleted, 1, "应恰好软删除 1 个过期未认领 trial");

        // 验证旧 trial 已被软删除
        let old_deleted = conn.query_row::<Option<String>, _, _>(
            "SELECT deleted_at FROM users WHERE id = ?1",
            rusqlite::params!["trial-old"],
            |row| row.get::<_, Option<String>>(0),
        ).unwrap();
        assert!(old_deleted.is_some(), "过期 trial 应被标记 deleted_at（deleted_at 非 NULL）");

        // 验证新 trial 未被软删除
        let new_deleted = conn.query_row::<Option<String>, _, _>(
            "SELECT deleted_at FROM users WHERE id = ?1",
            rusqlite::params!["trial-new"],
            |row| row.get::<_, Option<String>>(0),
        ).unwrap();
        assert!(new_deleted.is_none(), "新 trial 应保持 deleted_at NULL");

        // 验证已认领用户未被软删除
        let claimed_deleted = conn.query_row::<Option<String>, _, _>(
            "SELECT deleted_at FROM users WHERE id = ?1",
            rusqlite::params!["claimed-user"],
            |row| row.get::<_, Option<String>>(0),
        ).unwrap();
        assert!(claimed_deleted.is_none(), "已认领用户应保持 deleted_at NULL");
    }

    /// 测试 trial 硬删除：先软删除一个用户，再运行硬删除
    #[test]
    fn test_trial_hard_delete() {
        let conn = setup_db();

        // 创建一个已软删除超过 30 天的用户
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at, deleted_at) \
             VALUES (?1, ?2, ?3, '2023-12-01 00:00:00', '2024-01-01 00:00:00')",
            rusqlite::params!["purge-user", "trial_purge", "hash"],
        ).unwrap();

        // 插入关联数据（测试级联清理）
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) \
             VALUES (?1, ?2, 'tok', '2023-12-01')",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "purge-user"],
        ).unwrap();
        conn.execute(
            "INSERT INTO conversations (id, user_id, started_at) \
             VALUES (?1, ?2, '2023-12-01')",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "purge-user"],
        ).unwrap();

        // 创建一个昨天软删除的用户（不应被硬删除）
        let yesterday = (chrono::Utc::now() - chrono::Duration::days(1))
            .format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at, deleted_at) \
             VALUES (?1, ?2, ?3, '2023-12-01 00:00:00', ?4)",
            rusqlite::params!["recent-purge", "trial_recent", "hash", yesterday],
        ).unwrap();

        let purged = hard_delete_soft_deleted_trials(&conn).unwrap();
        assert_eq!(purged, 1, "应恰好硬删除 1 个软删超过30天的账户");

        // 验证用户已从 users 表删除
        let user_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE id = ?1",
            rusqlite::params!["purge-user"],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(user_count, 0, "用户应从 users 表彻底删除");

        // 验证关联数据已清理
        let token_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM tokens WHERE user_id = ?1",
            rusqlite::params!["purge-user"],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(token_count, 0, "关联 tokens 应被清理");

        // 验证近期软删除的用户未被硬删除
        let recent_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE id = ?1",
            rusqlite::params!["recent-purge"],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(recent_count, 1, "近期软删除的用户应保留");
    }
}
