//! 运维定时任务（**与营销活动无关**）
//!
//! | 任务 | 周期 | 作用 |
//! |---|---|---|
//! | 「未支付订单关单」 | 每 5 分钟 | `NOTPAY` 超 30 分钟 → `NOTPAY_CANCELLED` |
//! | 「过期 trial 硬删除」 | 每 5 分钟 | 创建超 30 天且未认领的 `trial_%` 账户及其关联数据 |
//! | 🆕「到期订阅的云端备份清理」 | 每 5 分钟 | 订阅到期满 **30 天** ⇒ 删该用户云端电子书文件、`blob_size` 归零（白哥 2026-10-09 定）|
//!
//! ## 🔴 2026-10-09 注：trial 清理**只清存量**了
//!
//! 试用账号机制已整体退役（`/api/trial/start` 与 `/api/trial/claim` 已删）
//! ⇒ **不再产生新的 `trial_%` 账号**。这个任务**保留**，因为它仍要清理
//! **存量**账号（不保留就永远占库）。
//! 📄 `docs/review/trial-account-removal-2026-10-09.md`
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
/// ⚠️ **故意不含 `distribution_commissions`**（白哥 2026-09-29 批「保持不删」，
///    理由见 [`tests::two_tables_have_no_user_id_column`]）：它是**财务记录**，
///    列是 `earner_id`/`buyer_id`，按用户删是产品决策。
///
/// ⚠️ **`trial_ip_log` 也不含**（2026-09-29 起就如此）：它**没有 `user_id` 列**
///    ⇒ 原来的 `DELETE ... WHERE user_id = ?1` 恒失败且被吞掉。
///    🔴 2026-10-09 追加说明：它现在**已无写入方**（`trial_handler` 已删），
///    是一张**历史表**。**留着不删**（清理它要动 schema 迁移，而它对用户无害）；
///    将来做 schema 清理时，它可以随 `purge` 的注释一起评估删除。
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

/// 订阅到期后，云端备份的**保留天数**（白哥 2026-10-09 定）。
///
/// 🔑 「订阅到期**一个月后**清除释放」—— 给用户一个**反悔窗口**：
///    续费 / 重订后仍能拿回云端副本，超期才释放磁盘。
///
/// ⚠️ 语义边界（写清楚免得后人误读成「到期就删」）：
///    · 起算点是 **`subscription_expires` 那天**，不是「我们发现他到期那天」；
///    · 到期**当天**不算满 30 天（用 `<= date('now','-30 days')`，即第 31 天起清）；
///    · 🔴 **删的只是云端文件** —— 端侧本地那份**不动**（用户不会丢书）。
pub const BLOB_RETENTION_DAYS_AFTER_EXPIRY: i64 = 30;

/// 清理**订阅到期满 [`BLOB_RETENTION_DAYS_AFTER_EXPIRY`] 天**用户的云端备份。
///
/// 返回 `(清理的用户数, 释放的字节数)`。
///
/// # 🔴 三个必须守住的点（每一个写错都不会报错，只会错得很安静）
///
/// | # | 约束 | 写错的后果 |
/// |---|---|---|
/// | 1 | **不动 `sync_book.deleted`** | 端侧 `mergeCloudBooks` 把 `deleted` 理解成「别端删了书」⇒ **把用户本地的书删掉**（数据丢失）|
/// | 2 | **只把 `blob_size` 置 0，不删 `sync_book` 行** | 行是「云端记录」，端侧还要靠它认书；删行等于凭空消失 |
/// | 3 | **先删文件，再置 `blob_size = 0`** | 反过来的话：中途失败 ⇒ `blob_size = 0` 但文件还在 ⇒ 本函数**再也不会选中它**（筛选条件是 `blob_size > 0`）⇒ **文件永久残留**，而配额看着是空的 |
///
/// 🔑 顺序 3 的收益是**幂等可自愈**：先删文件、置 0 失败 ⇒ 下轮仍被选中 ⇒
///    重新 `purge_user`（返回 0 字节，因为文件已没了）⇒ 再置 0 ⇒ 收敛。
///
/// 🔑 筛选条件里带 `EXISTS (… blob_size > 0)` 是**性能**考虑，不是正确性 ——
///    否则每 5 分钟要对**所有**历史到期用户各扫一次目录。
///
/// ⚠️ `subscription_expires` 有**两种格式**（正常订阅 `YYYY-MM-DD` / 试用遗留带时刻）
///    ⇒ 一律 `substr(x,1,10)` 取日期部分；**解析不出来时 `date()` 返回 NULL**，
///    比较结果为 NULL（假）⇒ 那一行**不会被删** —— 这是安全的一侧（宁可不删）。
pub fn purge_expired_blobs(
    conn: &rusqlite::Connection,
    store: &dyn crate::book_storage::BlobStore,
) -> Result<(usize, u64), String> {
    let ids: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT id FROM users \
                  WHERE subscription_expires IS NOT NULL \
                    AND trim(subscription_expires) <> '' \
                    AND deleted_at IS NULL \
                    AND date(substr(subscription_expires, 1, 10)) \
                        <= date('now', ?1) \
                    AND EXISTS (SELECT 1 FROM sync_book sb \
                                 WHERE sb.user_id = users.id AND sb.blob_size > 0)",
            )
            .map_err(|e| format!("查询待清理云端备份的用户失败: {}", e))?;
        let offset = format!("-{} days", BLOB_RETENTION_DAYS_AFTER_EXPIRY);
        // ⚠️ 必须先把结果绑到局部变量再 `rows` 出块 —— 直接 `.collect()` 收尾会因
        //    `MappedRows` 借用 `stmt`、而 `stmt` 在块尾先析构 ⇒ 编译期报 E0597。
        //    （同文件 `hard_delete_expired_trials` 是同一个形状。）
        let rows: Vec<String> = stmt
            .query_map(rusqlite::params![offset], |row| row.get::<_, String>(0))
            .map_err(|e| format!("查询待清理云端备份的用户失败: {}", e))?
            .filter_map(|r| r.ok())
            .collect();
        rows
    };

    let mut freed_total: u64 = 0;
    let mut purged_users = 0usize;
    // 本轮统一的「服务端时刻」：同一次清理用**一个**时间戳（与上传/删除端点同一形态）。
    let received_at = crate::book_blob_handler::now_ms();
    for uid in &ids {
        // ① 先删文件（失败则**不**置 0 ⇒ 下轮重试 ⇒ 自愈）
        let freed = match store.purge_user(uid) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!(
                    "maintenance: 云端备份清理失败（下轮重试） uid={} err={}",
                    uid,
                    e
                );
                continue;
            }
        };
        // ② 再把服务端权威值归零（配额随之释放；`deleted` **不动**）
        //
        // 🔴🔴 **必须走 `book_blob_handler::zero_blob_sizes_for_user` —— 不能在本文件自写 UPDATE。**
        //
        //     本函数**第一版就是自写的裸 `UPDATE ... SET blob_size = 0`**，后果是**静默的**：
        //     `received_at` 是 **pull 的时间轴**（`sync_handlers::pull_changes` 的
        //     `WHERE received_at > ?since`）。只改 `blob_size` 不推进时间轴 ⇒
        //     用户的**其他设备永远不知道备份已被释放** ⇒ 书架仍显示「云端」⇒ 点下载 **404**。
        //
        //     ⚠️ 这**不是**「顺手写得更整齐」，而是把约束收回唯一权威处：
        //        「写 `blob_size` 必须同时推进 `received_at`」这条约束在
        //        `set_blob_size`（单条）与本函数（批量）各有一份，
        //        放在同一模块里 ⇒ 改一处时另一处就在眼前。
        //
        //     📌 判据：**「同一件事的口径只能一处权威」** —— 别处自写 SQL 不会红，
        //        只会让「另一台设备看不到变更」这类**换设备才暴露**的缺陷漏过去。
        if let Err(e) = crate::book_blob_handler::zero_blob_sizes_for_user(conn, uid, &received_at)
        {
            // 到这一步文件已经删了 ⇒ 如实记错，但**不**中止其他用户
            tracing::warn!(
                "maintenance: blob 已删但 blob_size 归零失败（下轮自愈） uid={} err={}",
                uid,
                e
            );
            continue;
        }
        freed_total += freed;
        purged_users += 1;
    }

    if purged_users > 0 {
        tracing::info!(
            "maintenance: 清理 {} 个到期用户的云端备份，释放 {} 字节（到期满 {} 天）",
            purged_users,
            freed_total,
            BLOB_RETENTION_DAYS_AFTER_EXPIRY
        );
    }
    Ok((purged_users, freed_total))
}

/// 定时任务内部执行逻辑（接受 DB 路径参数）
///
/// 打开 DB 连接，依次执行所有调度任务，返回执行结果摘要字符串。
fn run_scheduler_inner(db_path: &str) -> Result<String, String> {
    let conn =
        rusqlite::Connection::open(db_path).map_err(|e| format!("scheduler db open: {}", e))?;
    let cancelled = cancel_expired_orders(&conn)?;
    let purged = hard_delete_expired_trials(&conn)?;

    // 🆕 2026-10-09：订阅到期满 30 天 ⇒ 清理云端备份（释放磁盘）。
    // 🔑 这个任务的**失败不该拖垮另外两个** —— 它们与它无关。
    let (blob_users, blob_bytes) =
        match purge_expired_blobs(&conn, &crate::book_storage::LocalDiskStore::from_env()) {
            Ok(v) => v,
            Err(e) => {
                tracing::error!("maintenance: 云端备份清理出错（不影响其它任务）: {}", e);
                (0, 0)
            }
        };

    let msg = format!(
        "maintenance: cancelled={}, trial_hard_purged={}, blob_purged_users={}, blob_freed_bytes={}",
        cancelled, purged, blob_users, blob_bytes
    );
    if cancelled > 0 || purged > 0 || blob_users > 0 {
        tracing::info!("{}", msg);
    }
    Ok(msg)
}

/// 启动后台定时任务，每 5 分钟运行一次
///
/// 在 `db_pool::init()` 之后调用。会在独立线程中循环执行。
///
/// 🔑 线程内只做三件事：关单 · trial 存量清理 · **到期订阅的云端备份清理**。
///    （原「海报模板每日刷新」线程已随分销链删除。）
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

    // ══════════════════════════════════════════════════════════════════
    // 🆕 2026-10-09 · 订阅到期满 30 天 ⇒ 清理云端备份
    //
    // # 🔴 这些测试在守什么（每一条写错都**不会报错**，只会错得很安静）
    // · 保留窗口：到期 29 天**不能**删（那会提前没收人家还没过期的反悔期）
    // · 未来到期 / NULL：**不能**删（NULL = 从未订阅；拿它当到期是拿「取反」当判据）
    // · **`deleted` 一个字节都不能动**：端侧把它读成「别端删了书」⇒ 会删用户本地的书
    // · **行必须留着**：删行等于这本书凭空消失（端侧靠它认书）
    // · **文件必须真的没了**：只更新数据库 = 磁盘没释放，白干
    // · 幂等：第二轮必须 (0, 0)
    // ══════════════════════════════════════════════════════════════════

    /// 造一个临时 blob 仓库 + 一本书。
    ///
    /// 返回 `(store, dir)` —— `dir` 要在断言后交给 `remove_dir_all` 清掉。
    fn tmp_store(tag: &str) -> (crate::book_storage::LocalDiskStore, std::path::PathBuf) {
        let dir =
            std::env::temp_dir().join(format!("coevo_maint_blob_{}_{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = crate::book_storage::LocalDiskStore::with_root(&dir);
        (store, dir)
    }

    const TEST_HASH: &str = "0123456789abcdef0123456789abcdef";

    /// 插一个用户（可指定订阅到期日；`None` = 从未订阅）。
    fn insert_user(conn: &Connection, id: &str, expires: Option<&str>) {
        conn.execute(
            "INSERT INTO users (id, username, created_at, subscription_expires) \
             VALUES (?1, ?2, '2026-01-01 00:00:00', ?3)",
            rusqlite::params![id, format!("u_{}", id), expires],
        )
        .unwrap();
    }

    /// 插一行 `sync_book`（模拟「云端有一本书」）。
    fn insert_cloud_book(conn: &Connection, uid: &str, hash: &str, blob_size: i64) {
        conn.execute(
            "INSERT INTO sync_book \
             (user_id, content_hash, title, blob_size, added_at, updated_at, deleted, received_at) \
             VALUES (?1, ?2, 't', ?3, '2026-01-01 00:00:00', '2026-01-01 00:00:00', 0, '2026-01-01 00:00:00')",
            rusqlite::params![uid, hash, blob_size],
        )
        .unwrap();
    }

    fn days_ago(n: i64) -> String {
        (chrono::Utc::now() - chrono::Duration::days(n))
            .format("%Y-%m-%d")
            .to_string()
    }

    #[test]
    fn test_blob_purge_respects_retention_window() {
        let conn = setup_db();
        let (store, dir) = tmp_store("window");
        use crate::book_storage::BlobStore;

        // 到期 29 天：**不该删**（还在 30 天反悔窗口内）
        insert_user(&conn, "u-recent", Some(&days_ago(29)));
        insert_cloud_book(&conn, "u-recent", TEST_HASH, 100);
        store.put("u-recent", TEST_HASH, "epub", b"hello").unwrap();

        // 到期 31 天：**该删**
        insert_user(&conn, "u-old", Some(&days_ago(31)));
        insert_cloud_book(&conn, "u-old", TEST_HASH, 100);
        store.put("u-old", TEST_HASH, "epub", b"hello").unwrap();

        let (users, bytes) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!(users, 1, "只有到期满 30 天以上的那个用户被清");
        assert_eq!(bytes, 5, "释放字节数 = 那份文件的大小");

        // 29 天的：文件与 blob_size 都还在
        assert_eq!(
            store.disk_usage_of("u-recent").unwrap(),
            5,
            "未过保留期不得删文件"
        );
        let bs: i64 = conn
            .query_row(
                "SELECT blob_size FROM sync_book WHERE user_id='u-recent'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bs, 100, "未过保留期 blob_size 不得归零");

        // 31 天的：文件没了、blob_size 归零
        assert_eq!(
            store.disk_usage_of("u-old").unwrap(),
            0,
            "过保留期必须真的删掉文件"
        );
        let bs2: i64 = conn
            .query_row(
                "SELECT blob_size FROM sync_book WHERE user_id='u-old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bs2, 0, "过保留期 blob_size 必须归零（配额随之释放）");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_blob_purge_keeps_row_and_deleted_flag() {
        let conn = setup_db();
        let (store, dir) = tmp_store("keeprow");

        insert_user(&conn, "u-old", Some(&days_ago(40)));
        insert_cloud_book(&conn, "u-old", TEST_HASH, 100);

        purge_expired_blobs(&conn, &store).unwrap();

        // 🔴 行必须在（端侧靠它认书；删行 = 书凭空消失）
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sync_book WHERE user_id='u-old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1, "sync_book 行不得删除（只有 blob_size 归零）");

        // 🔴 `deleted` 必须还是 0 —— 端侧把它读成「别端删了书」⇒ 会删用户本地的书
        let deleted: i64 = conn
            .query_row(
                "SELECT deleted FROM sync_book WHERE user_id='u-old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            deleted, 0,
            "🔴 deleted 一个字节都不能动 —— 动了会让端侧把用户本地的书删掉"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_blob_purge_skips_null_and_future() {
        let conn = setup_db();
        let (store, dir) = tmp_store("nullfut");

        // 从未订阅（NULL）——「取反」当判据是错的：NULL ≠ 到期
        insert_user(&conn, "u-never", None);
        insert_cloud_book(&conn, "u-never", TEST_HASH, 100);

        // 订阅还有效（未来日期）
        insert_user(&conn, "u-active", Some("2099-12-31"));
        insert_cloud_book(&conn, "u-active", TEST_HASH, 100);

        // 日期格式无法解析 ⇒ 安全侧：不删
        insert_user(&conn, "u-bad", Some("not-a-date"));
        insert_cloud_book(&conn, "u-bad", TEST_HASH, 100);

        let (users, bytes) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!((users, bytes), (0, 0), "NULL / 未来 / 坏格式 一律不删");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_blob_purge_is_idempotent() {
        let conn = setup_db();
        let (store, dir) = tmp_store("idem");
        use crate::book_storage::BlobStore;

        insert_user(&conn, "u-old", Some(&days_ago(45)));
        insert_cloud_book(&conn, "u-old", TEST_HASH, 7);
        store.put("u-old", TEST_HASH, "epub", b"1234567").unwrap();

        let (u1, b1) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!((u1, b1), (1, 7));

        // 第二轮：`blob_size` 已归零 ⇒ 筛选条件不再命中 ⇒ 什么都不做
        let (u2, b2) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!((u2, b2), (0, 0), "幂等：第二轮必须无事发生");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 🔴 **自愈路径**：模拟「删文件成功、`blob_size` 归零失败」的中间态
    /// （文件已无、`blob_size` 仍 > 0）⇒ 下一轮**必须仍然选中它**并收敛到 0。
    ///
    /// 这条守的是**实现顺序**（先删文件、后归零）带来的那个性质。
    /// ⚠️ 反过来（先归零、后删文件）一旦中途失败，就是
    /// 「`blob_size = 0` + 文件残留」⇒ 筛选条件 `blob_size > 0` **永远不再命中**
    /// ⇒ **文件永久残留**，而配额看着是空的 —— 没有人会发现。
    #[test]
    fn test_blob_purge_self_heals_when_zeroing_failed() {
        let conn = setup_db();
        let (store, dir) = tmp_store("heal");
        // ⚠️ 这里**不要** `use crate::book_storage::BlobStore;` ——
        //    本测试模拟的是「文件已被删」，全程不调 `store.put/disk_usage_of`
        //    ⇒ trait 不在作用域也不影响（写这句是为了防后来人照抄隔壁测试的 `use`）。

        insert_user(&conn, "u-old", Some(&days_ago(60)));
        insert_cloud_book(&conn, "u-old", TEST_HASH, 100);

        // 模拟那个中间态：文件已经没了（第一次 purge 删的），但 blob_size 没归零
        let (u1, _) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!(u1, 1);
        conn.execute(
            "UPDATE sync_book SET blob_size = 100 WHERE user_id = 'u-old'",
            [],
        )
        .unwrap();

        // 第二轮：必须**再次被选中**（blob_size 仍 > 0）⇒ 收敛
        let (u2, b2) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!(u2, 1, "blob_size 未归零时必须继续被选中（否则永久卡住）");
        assert_eq!(b2, 0, "文件早已不在 ⇒ 本次释放 0 字节，但仍然要归零");
        let bs: i64 = conn
            .query_row(
                "SELECT blob_size FROM sync_book WHERE user_id='u-old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bs, 0, "第二轮必须把 blob_size 收敛到 0");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 🔴🔴 **清理必须推进 `received_at`** —— 它是 **pull 的时间轴**。
    ///
    /// 这是本功能**第一版真实踩过的缺陷**：`purge_expired_blobs` 当时自写了一条
    /// 裸 `UPDATE ... SET blob_size = 0`（没动 `received_at`）⇒
    /// 用户的**其他设备**永远拉不到这次变更 ⇒ 书架仍显示「云端有」⇒ 点下载 **404**。
    /// 它**不报错、不掉任何断言**，只有真机换设备才看得见。
    ///
    /// ⚠️ 断言**直接模拟 pull**（拿清理前的时刻当 `since` 查一次），
    ///    而不是只查「`received_at` 不等于旧值」——
    ///    后者只证明字段被写了，前者才证明**用户真的能看到**。
    ///    两者不等价：格式写错（例如换成 `date()` 那种 `YYYY-MM-DD`）时字段明明变了，
    ///    但字符串比较下 pull 仍会漏 ⇒ 只查「变了」会**假绿**。
    #[test]
    fn test_blob_purge_advances_received_at_for_pull() {
        let conn = setup_db();
        let (store, dir) = tmp_store("pull");
        use crate::book_storage::BlobStore;

        insert_user(&conn, "u-old", Some(&days_ago(60)));
        insert_cloud_book(&conn, "u-old", TEST_HASH, 5);
        store.put("u-old", TEST_HASH, "epub", b"12345").unwrap();

        // 该设备「清理前已同步过」⇒ 它的游标停在旧 received_at（= insert 时的 '2026-01-01 00:00:00'）
        const SINCE: &str = "2026-01-01 00:00:01";
        let before: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sync_book WHERE user_id = ?1 AND received_at > ?2",
                rusqlite::params!["u-old", SINCE],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(before, 0, "前提：清理前，该设备拉不到任何书单变更");

        let (purged, _) = purge_expired_blobs(&conn, &store).unwrap();
        assert_eq!(purged, 1);

        // 🔴 用**同一个** since 再拉 ⇒ 必须能看到这一行
        //    （= 其他设备会得知「云端已经没有这本书」）
        let after: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sync_book WHERE user_id = ?1 AND received_at > ?2",
                rusqlite::params!["u-old", SINCE],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            after, 1,
            "清理必须推进 received_at —— 否则其他设备永远不知道备份已被释放\
             （书架仍显示「云端」、点下载 404）"
        );

        // 归零本身也要生效（否则配额不释放）
        let bs: i64 = conn
            .query_row(
                "SELECT blob_size FROM sync_book WHERE user_id = 'u-old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bs, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 🔴 「写 `blob_size` 的 SQL 只在本模块」—— 本文件**不得**再出现裸 UPDATE。
    ///
    /// ⚠️ 判据要**落在函数体内**、且要**剥掉整行注释**：
    ///    · 本文件的测试代码里有一条 `UPDATE sync_book SET blob_size = 100 ...`
    ///      （用于模拟中间态）⇒ 整文件扫会**假红**；
    ///    · `purge_expired_blobs` 的**注释**里为了说明这段历史，写了
    ///      「自写的裸 `UPDATE ... SET blob_size = 0`」⇒ 同样假红
    ///      （第一次写这条测试就是这么红的）。
    ///    📌 判据：**文本断言必须先剥注释**，且只能**按整行**剥 ——
    ///       否则会把「解释这件事的文字」当成「这件事本身」。
    #[test]
    fn test_purge_does_not_write_blob_size_directly() {
        let src = include_str!("maintenance.rs");
        let start = src.find("pub fn purge_expired_blobs(").expect("函数应存在");
        let end = src[start..]
            .find("/// 定时任务内部执行逻辑")
            .map(|i| start + i)
            .unwrap_or(src.len());
        // 剥掉整行注释（只按整行 —— 见上文判据）
        let body: String = src[start..end]
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");

        assert!(
            body.contains("zero_blob_sizes_for_user("),
            "切片必须覆盖清理主体（否则下面的反向断言是**假绿**）"
        );
        assert!(
            !body.contains("SET blob_size"),
            "清理函数体内不得直接写 blob_size —— 必须走 \
             `book_blob_handler::zero_blob_sizes_for_user`（它会一并推进 received_at）"
        );
    }
}
