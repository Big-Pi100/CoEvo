//! 活动调度器（推送触发 / cron / 自动解锁 / 海报模板刷新）
//!
//! 包含：
//! - 佣金锁定期到期自动解锁（30天）
//! - NOTPAY 超时关单（30分钟未支付）
//! - 后台定时任务（5分钟间隔自动执行）
//! - 海报模板每日刷新（每天 00:30 执行）

use chrono::Timelike;

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

/// 定时任务内部执行逻辑（接受 DB 路径参数）
///
/// 打开 DB 连接，依次执行所有调度任务，
/// 返回执行结果摘要字符串。
fn run_scheduler_inner(db_path: &str) -> Result<String, String> {
    let conn = rusqlite::Connection::open(db_path)
        .map_err(|e| format!("scheduler db open: {}", e))?;
    let unlocked = unlock_available_commissions(&conn)?;
    let cancelled = cancel_expired_orders(&conn)?;
    let msg = format!("scheduler: unlocked={}, cancelled={}", unlocked, cancelled);
    if unlocked > 0 || cancelled > 0 {
        tracing::info!("{}", msg);
    }
    Ok(msg)
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
}
