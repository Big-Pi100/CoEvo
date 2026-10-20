//! 订阅套餐管理 + 到期日计算核心函数
//!
//! 所有延期操作（支付成功、管理员设置、注册赠送）统一走 `extend_subscription()`
//! 不允许任何套餐 ID/时长/价格的硬编码

use rusqlite::{params, Connection, Result};
use serde::Serialize;
/// 套餐定义
#[derive(Debug, Serialize)]
pub struct PlanRow {
    pub id: String,
    pub name: String,
    pub duration_days: Option<i64>,
    pub price: i64,
    pub max_uses: Option<i64>,
    pub used_count: i64,
    pub once_per_user: bool,
    pub available_from: Option<String>,
    pub available_until: Option<String>,
    pub sort_order: i64,
    pub is_active: bool,
}

/// 查询可购买套餐列表（可选按用户过滤）
///
/// 如果 `user_id` 不为空，会排除该用户已支付成功的 once_per_user 套餐
pub fn get_available_plans(conn: &Connection, user_id: Option<&str>) -> Result<Vec<PlanRow>> {
    let mut sql = String::from(
        "SELECT sp.id, sp.name, sp.duration_days, sp.price,
                sp.max_uses, sp.used_count, sp.once_per_user,
                sp.available_from, sp.available_until, sp.sort_order, sp.is_active
         FROM subscription_plans sp
         WHERE sp.is_active = 1
           AND (sp.max_uses IS NULL OR sp.used_count < sp.max_uses)
           AND (sp.available_from IS NULL OR sp.available_from <= datetime('now'))
           AND (sp.available_until IS NULL OR sp.available_until > datetime('now'))",
    );
    if user_id.is_some() {
        sql.push_str(
            " AND (sp.once_per_user = 0 OR sp.once_per_user IS NULL
                   OR NOT EXISTS (
                     SELECT 1 FROM payment_orders
                     WHERE user_id = ?1 AND plan_id = sp.id AND status = 'SUCCESS'
                   ))",
        );
    }
    sql.push_str(" ORDER BY sp.sort_order ASC");

    let mut stmt = conn.prepare(&sql)?;
    let mapper = |row: &rusqlite::Row| -> rusqlite::Result<PlanRow> {
        Ok(PlanRow {
            id: row.get(0)?,
            name: row.get(1)?,
            duration_days: row.get(2)?,
            price: row.get(3)?,
            max_uses: row.get(4)?,
            used_count: row.get(5)?,
            once_per_user: row.get::<_, i32>(6)? != 0,
            available_from: row.get(7)?,
            available_until: row.get(8)?,
            sort_order: row.get(9)?,
            is_active: row.get::<_, i32>(10)? != 0,
        })
    };
    let rows;
    if let Some(uid) = user_id {
        rows = stmt
            .query_map(params![uid], mapper)?
            .filter_map(|r| r.ok())
            .collect();
    } else {
        rows = stmt.query_map([], mapper)?.filter_map(|r| r.ok()).collect();
    }
    Ok(rows)
}

/// 查询单个套餐（管理端用，含已下架）
pub fn get_plan_by_id(conn: &Connection, plan_id: &str) -> Result<Option<PlanRow>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, duration_days, price, max_uses, used_count,
                once_per_user, available_from, available_until, sort_order, is_active
         FROM subscription_plans WHERE id = ?1",
    )?;
    let mut rows = stmt.query_map(params![plan_id], |row| {
        Ok(PlanRow {
            id: row.get(0)?,
            name: row.get(1)?,
            duration_days: row.get(2)?,
            price: row.get(3)?,
            max_uses: row.get(4)?,
            used_count: row.get(5)?,
            once_per_user: row.get::<_, i32>(6)? != 0,
            available_from: row.get(7)?,
            available_until: row.get(8)?,
            sort_order: row.get(9)?,
            is_active: row.get::<_, i32>(10)? != 0,
        })
    })?;
    match rows.next() {
        Some(Ok(plan)) => Ok(Some(plan)),
        _ => Ok(None),
    }
}

/// 获取用户当前到期日
pub fn get_current_expires(conn: &Connection, user_id: &str) -> Result<Option<String>> {
    let result = conn.query_row(
        "SELECT subscription_expires FROM users WHERE id = ?1",
        params![user_id],
        |row| row.get::<_, Option<String>>(0),
    );
    match result {
        Ok(Some(v)) if !v.is_empty() => Ok(Some(v)),
        _ => Ok(None),
    }
}

/// 统一订阅有效性检查（ws.rs、routes.rs 等共用）
pub fn is_subscription_active(conn: &Connection, user_id: &str) -> bool {
    match get_current_expires(conn, user_id) {
        Ok(Some(expires)) => {
            let normalized = if expires.len() == 10 && expires.as_bytes().get(4) == Some(&b'-') {
                format!("{}T00:00:00Z", expires)
            } else {
                expires
            };
            chrono::DateTime::parse_from_rfc3339(&normalized)
                .map(|dt| dt.timestamp() > chrono::Utc::now().timestamp())
                .unwrap_or(false)
        }
        _ => false,
    }
}

/// 设置用户到期日
///
/// ⚠️ **无条件覆盖**（last-write-wins）。这是**管理端 / 退款 / 人工调整**语义
/// （那些场景**需要**能往回改）。
/// 🔴 **IAP 上报不要用它** —— 用 [`set_expires_if_later`]（Apple 会乱序重放交易）。
pub fn set_expires(conn: &Connection, user_id: &str, expires: &str) -> Result<()> {
    conn.execute(
        "UPDATE users SET subscription_expires = ?1 WHERE id = ?2",
        params![expires, user_id],
    )?;
    Ok(())
}

/// 设置到期日 —— **只允许向后推进**（IAP 上报专用）。
///
/// # 🔴 为什么必须有它（2026-10-20 真机事故）
///
/// StoreKit **重放历史交易时不保证顺序**：一次「恢复购买」/冷启动可能投递 9 笔
/// （本项目沙盒月度订阅 5 天累积了 9 笔），而端侧按**投递顺序**逐笔上报。
///
/// 原来的 [`set_expires`] 是**无条件覆盖** ⇒ 最后投递的那笔说了算
/// ⇒ 若最后一笔是旧的（事故里是 10-18），到期日就被**回退**成"已过期"
/// ⇒ 服务端判「未订阅」⇒ **同步 403 + 误弹「订阅已到期」**，
///   而端侧 StoreKit 明明还有效到 10-21 ⇒ 用户看到「订阅中 · 同步失败」。
///
/// 📌 判据：**幂等写入 ≠ 可以乱序到达**。
///    有先后语义的字段（到期日 / 余额 / 计数器）必须是 **max / 累加 / 带版本号**。
///    顺序**不该由客户端保证** —— 它会重试、会并发、换实现就变。
///
/// # 为什么用 `datetime()` 而不是字符串比较
///
/// `subscription_expires` 目前**格式混用**：IAP 写 RFC3339（`…T13:57:39Z`），
/// 而 `activate_subscription` 写纯日期（`2026-10-18`）。
/// 字符串比较 `'2026-10-18' < '2026-10-18T13:57:39Z'` 恰好返回 true（短的在前）——
/// **看起来对纯属巧合**，跨格式时错向不定。`datetime()` 能同时解析两者。
///
/// # 返回
///
/// `Ok(true)` = 确实推进了；`Ok(false)` = 新值不比现值晚（**已忽略，不是错误**）。
/// 调用方应据此打日志 ——「报了几笔、几笔被忽略」是排查乱序的第一手判据。
///
/// # 格式契约
///
/// 本函数假定 `expires` 是**可被 SQLite `datetime()` 解析**的时间串。
/// 格式非法时 `datetime(?1)` 为 NULL ⇒ 条件不成立 ⇒ **静默不写**。
/// ⇒ 调用方**必须先校验**（见 `iap_handlers` 里的 `parse_from_rfc3339`），
///    否则会变成「格式漂移 ⇒ 永远不写 ⇒ 静默失效」。
pub fn set_expires_if_later(conn: &Connection, user_id: &str, expires: &str) -> Result<bool> {
    let n = conn.execute(
        "UPDATE users SET subscription_expires = ?1
         WHERE id = ?2
           AND (subscription_expires IS NULL
                OR datetime(subscription_expires) < datetime(?1))",
        params![expires, user_id],
    )?;
    Ok(n > 0)
}

/// 更新套餐已售数
pub fn increment_used_count(conn: &Connection, plan_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE subscription_plans SET used_count = used_count + 1 WHERE id = ?1",
        params![plan_id],
    )?;
    Ok(())
}

/// 写审计日志
pub fn insert_audit_log(
    conn: &Connection,
    action: &str,
    operator_id: Option<&str>,
    target_user_id: &str,
    old_expires: Option<&str>,
    new_expires: &str,
    amount: i64,
    order_id: Option<&str>,
    note: Option<&str>,
) -> Result<()> {
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    conn.execute(
        "INSERT INTO subscription_audit_log
         (action, operator_id, target_user_id, old_expires, new_expires,
          amount, order_id, note, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            action,
            operator_id,
            target_user_id,
            old_expires,
            new_expires,
            amount,
            order_id,
            note,
            now,
        ],
    )?;
    Ok(())
}

/// 核心函数：为指定用户延长订阅
///
/// 从 DB 查套餐时长，不允许硬编码。
/// 所有延期操作（支付、管理端设置、注册赠送）统一走此函数。
pub fn extend_subscription(
    conn: &Connection,
    user_id: &str,
    plan_id: &str,
    operator_id: Option<&str>,
    order_id: Option<&str>,
    note: Option<&str>,
) -> Result<String> {
    // 幂等性检查：同一 order_id 只处理一次
    if let Some(oid) = order_id {
        let already_done: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM subscription_audit_log WHERE action='pay' AND order_id=?1",
                params![oid],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0)
            > 0;
        if already_done {
            // 查询已写入的到期日
            let expires = conn
                .query_row(
                    "SELECT subscription_expires FROM users WHERE id=?1",
                    params![user_id],
                    |row| row.get::<_, String>(0),
                )
                .unwrap_or_default();
            return Ok(expires);
        }
    }

    // 从 DB 查套餐时长和价格
    let (duration_days, price) = conn.query_row(
        "SELECT duration_days, price FROM subscription_plans WHERE id = ?1",
        params![plan_id],
        |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, i64>(1)?)),
    )?;

    let days = duration_days.unwrap_or(30); // fallback（理论上不会走到这里）
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();

    let old_expires = get_current_expires(conn, user_id)?;

    // 计算新到期日：未过期则从原到期日累加，否则从今天开始
    let base = match &old_expires {
        Some(d) if d.as_str() >= today.as_str() => d.clone(),
        _ => today.clone(),
    };
    let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
    let new_date = base_date + chrono::Duration::days(days);
    let new_expires = new_date.format("%Y-%m-%d").to_string();

    // 写 users.subscription_expires
    set_expires(conn, user_id, &new_expires)?;

    // 更新套餐已售数
    increment_used_count(conn, plan_id)?;

    // 写审计日志
    insert_audit_log(
        conn,
        order_id.map(|_| "pay").unwrap_or("set"),
        operator_id,
        user_id,
        old_expires.as_deref(),
        &new_expires,
        price,
        order_id,
        note,
    )?;

    Ok(new_expires)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES ('u1', 'tester', datetime('now'))",
            [],
        )
        .unwrap();
        conn
    }

    fn expires_of(conn: &Connection) -> Option<String> {
        get_current_expires(conn, "u1").unwrap()
    }

    // ── 🔴 本组测试守的是 2026-10-20 事故：
    //    StoreKit 乱序重放 ⇒ 一笔旧交易把到期日「回退」⇒ 服务端判未订阅。──

    #[test]
    fn test_if_later_writes_when_empty() {
        let conn = db();
        assert_eq!(expires_of(&conn), None);
        let advanced = set_expires_if_later(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        assert!(advanced, "空值必须写入");
        assert_eq!(expires_of(&conn).as_deref(), Some("2026-10-21T14:04:22Z"));
    }

    #[test]
    fn test_if_later_advances() {
        let conn = db();
        set_expires_if_later(&conn, "u1", "2026-10-18T13:57:39Z").unwrap();
        let advanced = set_expires_if_later(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        assert!(advanced, "更晚的值必须推进");
        assert_eq!(expires_of(&conn).as_deref(), Some("2026-10-21T14:04:22Z"));
    }

    /// 🔴🔴 事故本体：库里有 10-21，来了一笔 10-18（乱序的旧交易）⇒ **必须拒绝回退**。
    /// 这条挂了 = bug 复现（旧实现 `set_expires` 在这里会写成 10-18）。
    #[test]
    fn test_if_later_ignores_older() {
        let conn = db();
        set_expires_if_later(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        let advanced = set_expires_if_later(&conn, "u1", "2026-10-18T13:57:39Z").unwrap();
        assert!(!advanced, "旧值不得推进");
        assert_eq!(
            expires_of(&conn).as_deref(),
            Some("2026-10-21T14:04:22Z"),
            "🔴 到期日被回退了 —— 事故复发"
        );
    }

    #[test]
    fn test_if_later_equal_is_noop() {
        let conn = db();
        set_expires_if_later(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        let advanced = set_expires_if_later(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        assert!(!advanced, "相等不算推进");
        assert_eq!(expires_of(&conn).as_deref(), Some("2026-10-21T14:04:22Z"));
    }

    /// `subscription_expires` **格式混用**（`activate_subscription` 写纯日期）。
    /// 若用字符串比较，`"2026-10-18" < "2026-10-18T23:00:00Z"` 恰好为 true ——
    /// **看起来对纯属巧合**。`datetime()` 归一后语义才确定。
    #[test]
    fn test_if_later_handles_mixed_formats() {
        let conn = db();
        // 后台写的纯日期
        set_expires(&conn, "u1", "2026-10-18").unwrap();
        // IAP 写 RFC3339（同一天但更晚的时刻）
        let advanced = set_expires_if_later(&conn, "u1", "2026-10-18T23:00:00Z").unwrap();
        assert!(advanced, "同一天的更晚时刻应推进（datetime() 归一生效）");
        assert_eq!(expires_of(&conn).as_deref(), Some("2026-10-18T23:00:00Z"));
    }

    /// 🔑 **反向对照**：原 `set_expires` **保留**回退能力 ——
    /// 退款 / 人工撤销需要它。若哪天有人"顺手把老函数也改成单调"，
    /// 这条会红，提醒他：两个函数的语义是**刻意的不同**。
    #[test]
    fn test_unconditional_set_expires_can_roll_back() {
        let conn = db();
        set_expires(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();
        set_expires(&conn, "u1", "2026-10-18T13:57:39Z").unwrap();
        assert_eq!(
            expires_of(&conn).as_deref(),
            Some("2026-10-18T13:57:39Z"),
            "无条件版必须能回退（退款/管理端依赖它）"
        );
    }
}
