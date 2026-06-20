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
           AND (sp.available_until IS NULL OR sp.available_until > datetime('now'))"
    );
    if let Some(_) = user_id {
        sql.push_str(
            " AND (sp.once_per_user = 0 OR sp.once_per_user IS NULL
                   OR NOT EXISTS (
                     SELECT 1 FROM payment_orders
                     WHERE user_id = ?1 AND plan_id = sp.id AND status = 'SUCCESS'
                   ))"
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
        rows = stmt.query_map(params![uid], mapper)?.filter_map(|r| r.ok()).collect();
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
         FROM subscription_plans WHERE id = ?1"
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
pub fn set_expires(conn: &Connection, user_id: &str, expires: &str) -> Result<()> {
    conn.execute(
        "UPDATE users SET subscription_expires = ?1 WHERE id = ?2",
        params![expires, user_id],
    )?;
    Ok(())
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
