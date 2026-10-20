//! 订阅套餐管理 + 到期日计算核心函数
//!
//! 所有延期操作（支付成功、管理员设置、注册赠送）统一走 `extend_subscription()`
//! 不允许任何套餐 ID/时长/价格的硬编码

use chrono::{DateTime, NaiveDate, NaiveDateTime, TimeZone, Utc};
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

/// 获取用户当前到期日（**原始字符串**）。
///
/// ⚠️ 只用于「原样透传给客户端展示」与迁移脚本。
/// **任何需要比较/计算的场景请用 [`parsed_expires`]** —— 不要自己 parse，
/// 否则会重演「三种归一手法并存」（见 `docs/design/subscription-expires-format-unification-2026-10-21.md`）。
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

// ══════════════════════════════════════════════════════════════════════════
// 到期日：**唯一的解析入口**（2026-10-21 收口，方案 A）
//
// # 为什么必须收口（立项依据）
//
// 收口前，同一个字段有三种各自为政的归一手法：
// | 位置 | 手法 |
// |---|---|
// | `is_subscription_active` | 手写判 `len==10 && [4]=='-'` 补 `T00:00:00Z` |
// | `set_expires_if_later` | SQL `datetime()` |
// | `maintenance.rs` | `date(substr(v,1,10))` |
//
// 其中第一条有**静默失效**风险：带时区偏移（`+08:00`）的值落进 RFC3339 分支后
// parse 成功（RFC3339 允许偏移），但若形态再怪一点就 parse 失败 ⇒ **静默判「未订阅」**。
// 而订阅闸门后面挂着同步 / 翻译 / 云端书架 —— 一个静默 false 就是「付了钱什么都没」。
//
// 📌 判据：**同一件事的口径只能有一处权威**。
// ══════════════════════════════════════════════════════════════════════════

/// 把库里存的**任意历史形态**解析成 UTC 时间。全库唯一入口。
///
/// 接受的形态（按优先级）：
/// 1. **RFC3339**（`2026-10-21T14:04:22Z` · 也接受 `+08:00` 偏移）—— IAP 写的、**唯一应出现的**
/// 2. **纯日期**（`2026-10-21`）—— `extend_subscription` 的旧写法，视为当日 **00:00 UTC**
/// 3. **SQLite 风格**（`2026-10-21 14:04:22`，空格分隔）—— 手工改库时可能留下的
///
/// 返回 `None`：空串 / 无法解析（调用方按「未订阅」处理，但**这属于脏数据**，应告警）。
///
/// 🔑 这是纯函数（不碰 DB）⇒ **可单测**，且 `extend_subscription` 的计算也能共用它。
pub fn parse_expires(raw: &str) -> Option<DateTime<Utc>> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    // ① RFC3339（含 `Z` 或 `+08:00` 偏移）
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Some(dt.with_timezone(&Utc));
    }
    // ② 纯日期 → 当日 00:00 UTC（与旧 `is_subscription_active` 的补齐语义一致）
    if let Ok(d) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        return d.and_hms_opt(0, 0, 0).map(|t| Utc.from_utc_datetime(&t));
    }
    // ③ SQLite 风格（空格分隔、无时区标记）
    if let Ok(ndt) = NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        return Some(Utc.from_utc_datetime(&ndt));
    }
    None
}

/// 读库并解析 —— **所有比较 / 计算都应走这里**。
pub fn parsed_expires(conn: &Connection, user_id: &str) -> Result<Option<DateTime<Utc>>> {
    let Some(raw) = get_current_expires(conn, user_id)? else {
        return Ok(None);
    };
    Ok(parse_expires(&raw))
}

/// 规范化成**唯一对外形态**：`YYYY-MM-DDTHH:MM:SSZ`（UTC、秒级）。
///
/// 无法解析 ⇒ `None`（由调用方决定报错，**不静默写垃圾**）。
pub fn canonicalize_expires(raw: &str) -> Option<String> {
    parse_expires(raw).map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

/// 构造一个**带可读消息**的 rusqlite 错误（`rusqlite::Error` 没有专门的「值非法」变体）。
fn invalid_expires_err(raw: &str) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::new(
        std::io::ErrorKind::InvalidInput,
        format!("到期日格式非法（要求 RFC3339 或 YYYY-MM-DD）: {:?}", raw),
    )))
}

/// 统一订阅有效性检查（ws.rs、routes.rs 等共用）
///
/// 🆕 2026-10-21：改为走 [`parsed_expires`] —— 不再自己判字符串形态。
/// 行为与旧实现等价（旧实现只处理「10 字符纯日期」一种特例），
/// 但对 `+08:00` 偏移 / 空格分隔等形态**不再静默判错**。
pub fn is_subscription_active(conn: &Connection, user_id: &str) -> bool {
    match parsed_expires(conn, user_id) {
        Ok(Some(dt)) => dt.timestamp() > Utc::now().timestamp(),
        _ => false,
    }
}

/// 设置用户到期日 —— **管理端 / 退款 / 人工调整**语义（可往回改）。
///
/// 🔴 **IAP 上报不要用它** —— 用 [`set_expires_if_later`]（Apple 会乱序重放交易）。
///
/// # 🆕 2026-10-21：写入时**自动规范化**（方案 A 的一环）
///
/// 接受 RFC3339 / 纯日期 / SQLite 风格，统一落成 `YYYY-MM-DDTHH:MM:SSZ`。
///
/// 🔑 **为什么是"规范化"而不是"拒绝"**：
///    能理解的值应当收敛，不该让调用方为历史形态买单；
///    拒绝只保留给**无法理解**的垃圾值（那种必须报错，不能静默写进去）。
///
/// ⇒ 库里的 `subscription_expires` 从此**只有一种形态**，
///   读端也就不用再各自归一（见 [`parse_expires`] 的说明）。
pub fn set_expires(conn: &Connection, user_id: &str, expires: &str) -> Result<()> {
    let canonical = canonicalize_expires(expires).ok_or_else(|| invalid_expires_err(expires))?;
    conn.execute(
        "UPDATE users SET subscription_expires = ?1 WHERE id = ?2",
        params![canonical, user_id],
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
/// `subscription_expires` 目前**两种写法并存**：IAP 写 RFC3339（`…T13:57:39Z`），
/// 而 `extend_subscription` 写纯日期（`2026-10-18`）。
/// 字符串比较 `'2026-10-18' < '2026-10-18T13:57:39Z'` 恰好返回 true（短的在前）——
/// **看起来对纯属巧合**，跨格式时错向不定。`datetime()` 能同时解析两者。
///
/// ⚠️ 实测现状（2026-10-21）：生产库**全是 RFC3339**，纯日期 0 个 ——
///    因为 `extend_subscription` 目前**零调用点（死代码）**。
///    ⇒ 本函数用 `datetime()` 是**预防性**的，不是已经发生的数据混用。
///    📄 收口方案：`docs/design/subscription-expires-format-unification-2026-10-21.md`
///
/// # 返回
///
/// `Ok(true)` = 确实推进了；`Ok(false)` = 新值不比现值晚（**已忽略，不是错误**）。
/// 调用方应据此打日志 ——「报了几笔、几笔被忽略」是排查乱序的第一手判据。
///
/// # 格式契约（🆕 2026-10-21 起由本函数自己兜住）
///
/// 内部先 `canonicalize_expires`：
/// - 可解析（RFC3339 / 纯日期 / SQLite 风格）⇒ 规范成 RFC3339 再比较、再写
/// - **无法解析 ⇒ 返回 Err**（带可读消息），不再「静默不写」
///
/// 📌 旧版是「格式坏 ⇒ SQL `datetime()` 为 NULL ⇒ 静默不写」——
///    那是**静默失效**的入口（格式漂移会表现为"永远不更新"）。
///    现在改成显式报错；`iap_handlers` 里的 RFC3339 预校验保留作双重保险。
pub fn set_expires_if_later(conn: &Connection, user_id: &str, expires: &str) -> Result<bool> {
    let canonical = canonicalize_expires(expires).ok_or_else(|| invalid_expires_err(expires))?;
    let n = conn.execute(
        "UPDATE users SET subscription_expires = ?1
         WHERE id = ?2
           AND (subscription_expires IS NULL
                OR datetime(subscription_expires) < datetime(?1))",
        params![canonical, user_id],
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

    let old_expires = get_current_expires(conn, user_id)?;

    // 计算新到期日：**未过期则从原到期日累加**，否则从**此刻**开始。
    //
    // 🔴🔴 2026-10-21 修一处**隐藏的数据丢失**（收口时发现，非线上事故）：
    //
    // 旧写法用**字符串比较**挑基准、再用 `parse_from_str("%Y-%m-%d")` 解析，
    // 失败时 `unwrap_or_else(|| Utc::now().date_naive())` **静默退回今天**：
    // ```ignore
    // let base = match &old_expires {
    //     Some(d) if d.as_str() >= today.as_str() => d.clone(),   // ← 字符串比较
    //     _ => today.clone(),
    // };
    // let base_date = NaiveDate::parse_from_str(&base, "%Y-%m-%d")
    //     .unwrap_or_else(|_| Utc::now().date_naive());           // ← 静默退回今天
    // ```
    // 对 IAP 用户（值是 RFC3339 `2026-10-21T14:04:22Z`）：
    //   ① `"2026-10-21T…Z" >= "2026-10-21"` = **true**（前缀相同、更长）
    //   ② 用它去 `parse_from_str("%Y-%m-%d")` ⇒ **失败**（尾部有多余字符）
    //   ③ ⇒ 静默用「今天」 ⇒ `new = 今天 + days`，**用户已付费的剩余时长被清零**
    // ⇒ 一旦有人启用「后台赠送 / 补偿 / 手动延期」，对 IAP 用户操作就是**扣掉他的剩余权益**。
    //
    // ✅ 现在：统一走 [`parse_expires`]（比较的是 `DateTime`，不是字符串），
    //    并输出 **RFC3339** —— 库里的值从此只有一种形态。
    let now = Utc::now();
    let base = match old_expires.as_deref().and_then(parse_expires) {
        Some(dt) if dt > now => dt, // 未过期 ⇒ 从原到期日累加
        _ => now,                   // 已过期 / 未设置 ⇒ 从此刻开始
    };
    let new_expires = (base + chrono::Duration::days(days))
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string();

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

    /// `subscription_expires` **两种写法并存**（`extend_subscription` 写纯日期）。
    /// 若用字符串比较，`"2026-10-18" < "2026-10-18T23:00:00Z"` 恰好为 true ——
    /// **看起来对纯属巧合**。`datetime()` 归一后语义才确定。
    /// ⚠️ 生产库目前全是 RFC3339（`extend_subscription` 零调用点）⇒ 本测试是**预防性**的。
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

    // ══════════════════════════════════════════════════════════════════
    // 🆕 2026-10-21 格式收口（方案 A）—— 单一解析入口 + 写入规范化
    // 📄 docs/design/subscription-expires-format-unification-2026-10-21.md
    // ══════════════════════════════════════════════════════════════════

    /// 历史三种形态都要能解析；**带时区偏移的必须换算成 UTC**（旧实现会静默判错）。
    #[test]
    fn test_parse_expires_accepts_all_legacy_shapes() {
        let f = |s: &str| {
            parse_expires(s)
                .unwrap_or_else(|| panic!("{:?} 应可解析", s))
                .format("%Y-%m-%dT%H:%M:%SZ")
                .to_string()
        };
        assert_eq!(
            f("2026-10-21T14:04:22Z"),
            "2026-10-21T14:04:22Z",
            "① RFC3339"
        );
        assert_eq!(
            f("2026-10-21"),
            "2026-10-21T00:00:00Z",
            "② 纯日期 → 当日 00:00 UTC"
        );
        assert_eq!(
            f("2026-10-21T22:04:22+08:00"),
            "2026-10-21T14:04:22Z",
            "③ 偏移必须换算（R3：旧实现 len==10 判据漏掉它）"
        );
        assert_eq!(
            f("2026-10-21 14:04:22"),
            "2026-10-21T14:04:22Z",
            "④ SQLite 风格"
        );
    }

    #[test]
    fn test_parse_expires_rejects_garbage() {
        for bad in [
            "",
            "   ",
            "abc",
            "2026-13-45",
            "not-a-date",
            "2026-10-21T99:99:99Z",
        ] {
            assert!(parse_expires(bad).is_none(), "{:?} 不应解析成功", bad);
        }
    }

    /// 写入即规范化 ⇒ 库里**不会再有第二种形态**。
    #[test]
    fn test_set_expires_normalizes_to_rfc3339() {
        let conn = db();
        set_expires(&conn, "u1", "2026-10-21").unwrap();
        assert_eq!(
            expires_of(&conn).as_deref(),
            Some("2026-10-21T00:00:00Z"),
            "落库必须是 RFC3339（不能把纯日期原样写进去）"
        );
    }

    /// 无法理解的值必须**报错**，不能静默写垃圾、也不能静默不写。
    #[test]
    fn test_set_expires_rejects_garbage() {
        let conn = db();
        assert!(
            set_expires(&conn, "u1", "not-a-date").is_err(),
            "垃圾值必须报错（静默写入 = 灾难）"
        );
        assert_eq!(expires_of(&conn), None, "失败时不该留下任何值");
    }

    #[test]
    fn test_if_later_normalizes_too() {
        let conn = db();
        set_expires_if_later(&conn, "u1", "2026-10-21").unwrap();
        assert_eq!(expires_of(&conn).as_deref(), Some("2026-10-21T00:00:00Z"));
        assert!(
            set_expires_if_later(&conn, "u1", "garbage").is_err(),
            "非法值必须报错（旧版是 SQL datetime() 为 NULL ⇒ 静默不写）"
        );
    }

    /// `is_subscription_active` 对历史脏数据也要判得对（含绕过规范化直接写库的值）。
    #[test]
    fn test_is_active_handles_legacy_shapes() {
        let conn = db();
        let set_raw = |v: &str| {
            conn.execute(
                "UPDATE users SET subscription_expires=?1 WHERE id='u1'",
                params![v],
            )
            .unwrap();
        };
        set_raw("2099-01-01");
        assert!(
            is_subscription_active(&conn, "u1"),
            "纯日期（未来）应判有效"
        );
        set_raw("2000-01-01");
        assert!(
            !is_subscription_active(&conn, "u1"),
            "纯日期（过去）应判无效"
        );
        set_raw("2099-01-01T00:00:00+08:00");
        assert!(is_subscription_active(&conn, "u1"), "带偏移应判有效");
        set_raw("garbage");
        assert!(
            !is_subscription_active(&conn, "u1"),
            "非法值按未订阅（不 panic）"
        );
    }

    /// 🔴🔴 回归：`extend_subscription` **不得清掉用户剩余权益**。
    ///
    /// 旧实现的链条：对 RFC3339 值做**字符串比较**挑基准
    /// → `parse_from_str("%Y-%m-%d")` **失败** → `unwrap_or_else(今天)`
    /// → `new = 今天 + days` ⇒ **已付费的剩余天数被清零**。
    #[test]
    fn test_extend_subscription_preserves_remaining_days() {
        let conn = db();
        let original = parse_expires("2026-10-21T14:04:22Z").unwrap();
        set_expires(&conn, "u1", "2026-10-21T14:04:22Z").unwrap();

        let returned = extend_subscription(
            &conn,
            "u1",
            "com.coevo.coevoApp.pro.monthly",
            Some("tester"),
            None,
            None,
        )
        .unwrap();

        let got = parse_expires(&returned).expect("返回值必须可解析");
        let expected = original + chrono::Duration::days(30);

        assert!(
            got >= expected - chrono::Duration::days(1),
            "🔴 剩余权益被清零了 —— got={} · 期望≈{}",
            got,
            expected
        );
        // 落库值必须已是 RFC3339（契约）
        assert!(
            expires_of(&conn).unwrap().contains('T'),
            "落库值必须含 T（RFC3339）"
        );
    }
}
