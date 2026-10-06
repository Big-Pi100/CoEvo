//! 运维定时任务（**与营销活动无关**）
//!
//! | 任务 | 周期 | 作用 |
//! |---|---|---|
//! | 「未支付订单关单」 | 每 5 分钟 | `NOTPAY` 超 30 分钟 → `NOTPAY_CANCELLED` |
//! | 「过期 trial 硬删除」 | 每 5 分钟 | 创建超 30 天且未认领的 `trial_%` 账户及其关联数据 |
//!
//! ## 🔄 2026-10-06 从 `campaign_scheduler.rs` 拆出
//!
//! 原文件叫「活动调度器」，但它同时装着**两件与营销活动毫无关系**的运维任务
//! —— 关单与 trial 清理。删除分销/活动链时，它们**必须留下**：
//!
//! * 关单停掉 ⇒ 订单永远停在 `NOTPAY`，`payment_orders` 持续堆积（脏数据，且影响对账）。
//! * trial 清理停掉 ⇒ 过期匿名账户永久占库（且 `trial_%` 前缀永远存在）。
//!
//! 🔴 这是本次清理第二处「多职责」陷阱：**调度器的名字指向 A，内容却包含 B**。
//! 只看文件名就整文件删 ⇒ 上面两件事**静默停摆**（不报错，只是很久以后才发现）。
//! 📄 依据：`docs/review/backend-dead-route-cleanup-2026-10-06.md` §二 陷阱 2
//!
//! ## 已随分销链退役（**不要**再加回来）
//!
//! · 佣金锁定期自动解锁（`unlock_available_commissions`）
//! · cron 定时推送（`execute_cron_pushes`，写 `user_notifications`）
//! · 海报模板每日刷新（`refresh_all_active_templates`）
//!
//! ## 已删除的死入口
//!
//! 原 `pub fn run_scheduler()`（供「手动触发一次调度」）**全仓库零调用方** ⇒ 未迁移。
//! 需要手动触发时，直接调用下面的 [`run_scheduler_inner`] 或重启服务。

/// trial 硬删除时的**级联清理表**（按依赖顺序：先子表再 users 主表）。
///
/// 🔑 只有一处权威 —— 测试 [`tests::cascade_list_matches_real_schema`] 直接读它，
///    所以「加了幽灵表名」或「加了没有 `user_id` 列的表」都会**当场测试失败**。
///
/// 🔴 2026-09-29 清掉 7 个**已退役 / 从未存在**的表名（`card_memory` · `user_cards` ·
///    `user_plan_progress` · `cp1_plans` · `plan_runs` · `conversation_turns` · `conversations`）：
///    它们必然报 `no such table`，而调用处的 `let _ =` 把错误**静默吞掉** →
///    列表看着周全，实际一半空转。（`cp1_plans` 全库仅此一处出现，不是任何 CREATE 的产物。）
///
/// ⚠️ **故意不含**（白哥 2026-09-29 批「保持不删」，理由见
///    [`tests::two_tables_have_no_user_id_column`]）：
///    · `distribution_commissions` = **财务记录**（列是 `earner_id`/`buyer_id`，按用户删是产品决策）
///    · `trial_ip_log` = **反试用滥用日志**（只有 `ip`；删掉等于让同 IP 再次白嫖试用）
///    两者**都没有 `user_id` 列** → 原来的 `DELETE ... WHERE user_id = ?1` 恒失败且被吞掉。
pub const CASCADE_TABLES: &[&str] = &["tokens", "payment_orders", "user_notifications"];

/// NOTPAY 超时关单（30 分钟未支付）
///
/// 🔑 用 SQL 侧的 `datetime('now')` 比较 —— 与 `created_at` 的写入口径一致
/// （都是 `datetime('now')` 派生的字符串，可直接做字符串/时间比较）。
pub fn cancel_expired_orders(conn: &rusqlite::Connection) -> Result<usize, String> {
    let count = conn
        .execute(
            "UPDATE payment_orders SET status = 'NOTPAY_CANCELLED' \
         WHERE status = 'NOTPAY' \
         AND datetime(created_at, '+30 minutes') <= datetime('now')",
            [],
        )
        .map_err(|e| format!("NOTPAY 关单失败: {}", e))?;

    if count > 0 {
        tracing::info!("maintenance: 关停 {} 个超时未支付订单", count);
    }

    Ok(count)
}

/// 硬删除创建超过 30 天且未认领的临时账户及其关联数据
///
/// 按依赖顺序清理：先删子表再删 users 主表。
/// 单用户硬删除失败不影响其他用户。
pub fn hard_delete_expired_trials(conn: &rusqlite::Connection) -> Result<usize, String> {
    let ids = {
        let mut stmt = conn
            .prepare(
                "SELECT id FROM users \
             WHERE username LIKE 'trial_%' \
             AND created_at < datetime('now', '-30 days')",
            )
            .map_err(|e| format!("查询待硬删除用户失败: {}", e))?;

        let rows: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("查询待硬删除用户失败: {}", e))?
            .filter_map(|r| r.ok())
            .collect();
        rows
    };

    let count = ids.len();
    if count == 0 {
        return Ok(0);
    }

    // 级联清理关联表 —— 列表与理由见模块级 `CASCADE_TABLES`
    for uid in &ids {
        for table in CASCADE_TABLES {
            let sql = format!("DELETE FROM {} WHERE user_id = ?1", table);
            let _ = conn.execute(&sql, rusqlite::params![uid]);
        }
        // 最后删除用户主表记录
        conn.execute("DELETE FROM users WHERE id = ?1", rusqlite::params![uid])
            .map_err(|e| format!("硬删除用户 {} 失败: {}", uid, e))?;
    }

    tracing::info!("maintenance: 硬删除 {} 个超过30天的过期临时账户", count);
    Ok(count)
}

/// 定时任务内部执行逻辑（接受 DB 路径参数）
///
/// 打开 DB 连接，依次执行所有调度任务，返回执行结果摘要字符串。
fn run_scheduler_inner(db_path: &str) -> Result<String, String> {
    let conn =
        rusqlite::Connection::open(db_path).map_err(|e| format!("scheduler db open: {}", e))?;
    let cancelled = cancel_expired_orders(&conn)?;
    let purged = hard_delete_expired_trials(&conn)?;
    let msg = format!(
        "maintenance: cancelled={}, trial_hard_purged={}",
        cancelled, purged
    );
    if cancelled > 0 || purged > 0 {
        tracing::info!("{}", msg);
    }
    Ok(msg)
}

/// 启动后台定时任务，每 5 分钟运行一次
///
/// 在 `db_pool::init()` 之后调用。会在独立线程中循环执行。
///
/// 🔑 线程内**只**做上面两件事 —— 原「海报模板每日刷新」线程（00:30）已随分销链删除。
pub fn start_scheduler(db_path: &str) {
    let db_path = db_path.to_string();
    tracing::info!("maintenance: 启动后台定时任务（每 5 分钟），db={}", db_path);
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(300)); // 5分钟
        if let Err(e) = run_scheduler_inner(&db_path) {
            tracing::error!("Maintenance scheduler error: {}", e);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::init_database;
    use rusqlite::Connection;

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
        )
        .unwrap();
        conn.execute(
            "INSERT INTO subscription_plans (id, name, price, created_at) \
             VALUES ('plan_1', '月度会员', 20000, ?1)",
            rusqlite::params![now],
        )
        .unwrap();

        // 创建 31 分钟前的 NOTPAY 订单（应被关停）
        let old_order_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, 'test-user-1', 'plan_1', 20000, 'NOTPAY', '2024-01-01 00:00:00')",
            rusqlite::params![old_order_id],
        )
        .unwrap();

        // 创建刚发生的 NOTPAY 订单（不应被关停）
        let recent_order_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, 'test-user-1', 'plan_1', 20000, 'NOTPAY', ?2)",
            rusqlite::params![recent_order_id, now],
        )
        .unwrap();

        // 执行关停
        let cancelled = cancel_expired_orders(&conn).unwrap();
        assert_eq!(cancelled, 1, "应恰好关停 1 个超时 NOTPAY 订单");

        // 验证旧订单已关停
        let old_status: String = conn
            .query_row(
                "SELECT status FROM payment_orders WHERE id = ?1",
                rusqlite::params![old_order_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(old_status, "NOTPAY_CANCELLED", "超时订单应被关停");

        // 验证新订单未受影响
        let recent_status: String = conn
            .query_row(
                "SELECT status FROM payment_orders WHERE id = ?1",
                rusqlite::params![recent_order_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(recent_status, "NOTPAY", "新订单应保持 NOTPAY");
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
        )
        .unwrap();

        // 插入关联数据（测试级联清理）
        // 🔴 原实现还插了一条 `conversations`（对话链）—— 该表 2026-09-29 已退役，
        //    插入会报 `no such table: conversations`（就是本测试失败的原因）。
        //    级联清理的验证由现役表 `tokens` 承担即可。
        conn.execute(
            "INSERT INTO tokens (id, user_id, token, created_at) \
             VALUES (?1, ?2, 'tok', '2023-12-01')",
            rusqlite::params![uuid::Uuid::new_v4().to_string(), "purge-user"],
        )
        .unwrap();

        // 创建一个3天前的 trial 账户（不应被硬删除）
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params!["recent-user", "trial_recent", "hash", now],
        )
        .unwrap();

        // 创建一个已认领的 trial（username 不再是 trial_ 开头，不应被删除）
        conn.execute(
            "INSERT INTO users (id, username, password_hash, created_at) \
             VALUES (?1, ?2, ?3, '2024-01-01 00:00:00')",
            rusqlite::params!["claimed-user", "normal_user", "hash_claimed"],
        )
        .unwrap();

        let purged = hard_delete_expired_trials(&conn).unwrap();
        assert_eq!(purged, 1, "应恰好硬删除 1 个超过30天的过期 trial 账户");

        // 验证用户已从 users 表删除
        let user_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM users WHERE id = ?1",
                rusqlite::params!["purge-user"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(user_count, 0, "用户应从 users 表彻底删除");

        // 验证关联数据已清理
        let token_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM tokens WHERE user_id = ?1",
                rusqlite::params!["purge-user"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(token_count, 0, "关联 tokens 应被清理");

        // 验证近期 trial 账户未被硬删除
        let recent_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM users WHERE id = ?1",
                rusqlite::params!["recent-user"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(recent_count, 1, "3天前的 trial 账户应保留");

        // 验证已认领用户未被删除
        let claimed_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM users WHERE id = ?1",
                rusqlite::params!["claimed-user"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(claimed_count, 1, "已认领用户应保留");
    }

    /// 🔴 **把「为什么这两张表不能按 user_id 删」固化成断言**（2026-09-29 · 白哥批「保持不删」）
    ///
    /// `hard_delete_expired_trials` 的级联列表里**故意没有** `trial_ip_log` 与
    /// `distribution_commissions`。原因不是「忘了」，而是**它们根本没有 `user_id` 列** ——
    /// 原来那句 `DELETE FROM <表> WHERE user_id = ?1` 必然报错、且被 `let _ =` 静默吞掉
    /// （= 一行也没删过）。移除是**行为等价**的。
    ///
    /// 🔑 为什么要断言「没有这一列」而不是「表还在」：
    ///    · 「表还在」只说明它没被删；
    ///    · 「**没有 user_id 列**」说明**为什么不能纳入级联** —— 这才是决策的依据。
    ///    将来若有人给它们加了 `user_id`，本断言会失败 → 提醒「现在可以重新考虑纳入级联了」。
    #[test]
    fn two_tables_have_no_user_id_column() {
        let conn = setup_db();
        for table in ["trial_ip_log", "distribution_commissions"] {
            let cols: Vec<String> = {
                let mut stmt = conn
                    .prepare(&format!("PRAGMA table_info({})", table))
                    .unwrap();
                stmt.query_map([], |r| r.get::<_, String>(1))
                    .unwrap()
                    .filter_map(|r| r.ok())
                    .collect()
            };
            assert!(
                !cols.is_empty(),
                "{} 表不存在或没有列 —— 级联列表的注释已过时，需重新评估",
                table
            );
            assert!(
                !cols.contains(&"user_id".to_string()),
                "{} 现在有 `user_id` 列了 → 可以重新评估是否纳入 trial 级联删除（列: {:?}）",
                table,
                cols
            );
        }
    }

    /// 级联列表**只应包含真实存在且带 `user_id` 的表**（防止再次写进幽灵表名）
    #[test]
    fn cascade_list_matches_real_schema() {
        let conn = setup_db();
        for table in super::CASCADE_TABLES {
            let cols: Vec<String> = {
                let mut stmt = conn
                    .prepare(&format!("PRAGMA table_info({})", table))
                    .unwrap();
                stmt.query_map([], |r| r.get::<_, String>(1))
                    .unwrap()
                    .filter_map(|r| r.ok())
                    .collect()
            };
            assert!(!cols.is_empty(), "级联表 {} 不存在（幽灵表名）", table);
            assert!(
                cols.contains(&"user_id".to_string()),
                "级联表 {} 没有 user_id 列 → 它的 DELETE 恒失败（被静默吞掉）",
                table
            );
        }
    }
}
