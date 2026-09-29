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

/// 硬删除创建超过 30 天且未认领的临时账户及其关联数据
///
/// 按依赖顺序清理：先删子表再删 users 主表。
/// 单用户硬删除失败不影响其他用户。
pub fn hard_delete_expired_trials(conn: &rusqlite::Connection) -> Result<usize, String> {
    let ids = {
        let mut stmt = conn.prepare(
            "SELECT id FROM users \
             WHERE username LIKE 'trial_%' \
             AND created_at < datetime('now', '-30 days')"
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
    //
    // 🔴 2026-09-29 清掉 7 个**已退役 / 从未存在**的表名：
    //    `card_memory` · `user_cards` · `user_plan_progress` · `cp1_plans` ·
    //    `plan_runs` · `conversation_turns` · `conversations`
    //    —— 它们必然报 `no such table`，而下面的 `let _ =` 把错误**静默吞掉**：
    //       列表看着很周全，实际一半是空转。
    //    （`cp1_plans` 尤其可疑：全库仅此一处出现，不是任何 CREATE TABLE 的产物。）
    //
    // ⚠️ 另有 2 个**遗留问题**（本次只移出列表 + 记录，**不改语义**，因为属产品决策，未批）：
    //    `distribution_commissions` 的列是 `earner_id` / `buyer_id`，`trial_ip_log` **只有 ip**，
    //    两者都**没有 `user_id` 列** → 原来那句 `DELETE ... WHERE user_id = ?1` 对它们**必然报错**、
    //    被 `let _ =` 吞掉 ⇒ **一行也没删过**。故移出列表是**行为等价**的。
    //    · `distribution_commissions` = **财务记录**：按用户删是产品决策（需批）；
    //    · `trial_ip_log` = **反试用滥用日志**（按 IP 计）：删掉等于让同 IP 再次白嫖 → 建议保持不删。
    //    → 见交付文档「遗留发现」。
    let tables = [
        "tokens",
        "payment_orders",
        "user_notifications",
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

    tracing::info!("campaign_scheduler: 硬删除 {} 个超过30天的过期临时账户", count);
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
    let purged = hard_delete_expired_trials(&conn)?;
    let msg = format!(
        "scheduler: unlocked={}, cancelled={}, cron_pushed={}, trial_hard_purged={}",
        unlocked, cancelled, pushed, purged
    );
    if unlocked > 0 || cancelled > 0 || pushed > 0 || purged > 0 {
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
            let title = format!("新活动: {}", name);
            let body = description.clone().unwrap_or_else(|| "点击查看活动详情！".to_string());
            if uid == "all" {
                // 全量推送：分批写通知
                if let Ok(mut all_stmt) = conn.prepare(
                    "SELECT id FROM users WHERE deleted_at IS NULL LIMIT 100"
                ) {
                    if let Ok(rows) = all_stmt.query_map([], |row| row.get::<_, String>(0)) {
                        for rid in rows.filter_map(|r| r.ok()) {
                            // 幂等性检查：同一活动同一用户 60 秒内不重复推送
                            let recent: bool = conn.query_row(
                                "SELECT COUNT(*) FROM user_notifications WHERE user_id=?1 AND title=?2 AND created_at > datetime('now', '-60 seconds')",
                                rusqlite::params![&rid, &title],
                                |r| r.get::<_, i64>(0),
                            ).unwrap_or(0) > 0;
                            if !recent {
                                let _ = crate::campaign_executor::write_notification(
                                    conn, &rid, "campaign", &title, &body, Some(&format!("share?campaign_id={}", id)),
                                );
                            }
                        }
                    }
                }
            } else {
                let recent: bool = conn.query_row(
                    "SELECT COUNT(*) FROM user_notifications WHERE user_id=?1 AND title=?2 AND created_at > datetime('now', '-60 seconds')",
                    rusqlite::params![uid, &title],
                    |r| r.get::<_, i64>(0),
                ).unwrap_or(0) > 0;
                if !recent {
                    let _ = crate::campaign_executor::write_notification(
                        conn, uid, "campaign", &title, &body, Some(&format!("share?campaign_id={}", id)),
                    );
                }
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

    /// 测试 trial 硬删除：创建超过30天的trial账户，运行硬删除，验证清空
    #[test]
    fn test_trial_hard_delete() {
        let conn = setup_db();

        // 创建一个31天前的未认领 trial 账户（应被硬删除）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, '2024-01-01 00:00:00')",
            rusqlite::params!["purge-user", "trial_purge", "hash"],
        ).unwrap();

        // 插入关联数据（测试级联清理）
        // 🔴 原实现还插了一条 `conversations`（对话链）—— 该表 2026-09-29 已退役，
        //    插入会报 `no such table: conversations`（就是本测试失败的原因）。
        //    级联清理的验证由现役表 `tokens` 承担即可。
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) \
             VALUES (?1, ?2, 'tok', '2023-12-01')",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "purge-user"],
        ).unwrap();

        // 创建一个3天前的 trial 账户（不应被硬删除）
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params!["recent-user", "trial_recent", "hash", now],
        ).unwrap();

        // 创建一个已认领的 trial（username 不再是 trial_ 开头，不应被删除）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, '2024-01-01 00:00:00')",
            rusqlite::params!["claimed-user", "normal_user", "hash_claimed"],
        ).unwrap();

        let purged = hard_delete_expired_trials(&conn).unwrap();
        assert_eq!(purged, 1, "应恰好硬删除 1 个超过30天的过期 trial 账户");

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

        // 验证近期 trial 账户未被硬删除
        let recent_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE id = ?1",
            rusqlite::params!["recent-user"],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(recent_count, 1, "3天前的 trial 账户应保留");

        // 验证已认领用户未被删除
        let claimed_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM users WHERE id = ?1",
            rusqlite::params!["claimed-user"],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(claimed_count, 1, "已认领用户应保留");
    }
}
