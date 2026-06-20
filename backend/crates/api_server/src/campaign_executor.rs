//! 活动执行引擎
//!
//! 核心职责：根据触发事件查找有效活动，解析 rewards 并执行分发。
//! 所有错误只记录 warning，不阻塞主流程。

/// 保留常量引用（实际未使用）
pub const FREE_REWARD_PLAN_ID: &str = "reward_days";

/// 活动触发入口：查活动 → 解析 rewards → 幂等检查 → 分发
///
/// 返回所有生成的 fulfillment_id 列表。
/// 所有错误仅记录 warning 日志，不返回上层。
pub fn execute_campaign_trigger(
    conn: &rusqlite::Connection,
    trigger_event: &str,
    user_id: &str,
    referrer_id: Option<&str>,
    order_id: Option<&str>,
) -> Result<Vec<String>, String> {
    let campaigns = find_active_campaigns(conn, trigger_event)?;
    let mut fulfillment_ids = Vec::new();

    for (campaign_id, campaign_name, rewards_json, _attribution_window) in &campaigns {
        let rewards: Vec<serde_json::Value> = match serde_json::from_str(rewards_json) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("parse rewards failed for campaign {}: {}", campaign_id, e);
                continue;
            }
        };

        for reward in &rewards {
            let rtype = reward["type"].as_str().unwrap_or("");
            let party = reward["party"].as_str().unwrap_or("");
            let trigger = reward["trigger"].as_str().unwrap_or("");
            let value = &reward["value"];

            // trigger 必须匹配触发事件
            if trigger != trigger_event {
                continue;
            }

            // commission 类型在没有 order_id 时跳过（注册触发场景）
            if (rtype == "commission_pct" || rtype == "commission_fix") && order_id.is_none() {
                continue;
            }

            // 确定目标用户
            let target_user_id = match party {
                "self" => user_id.to_string(),
                "inviter" | "referrer" => match referrer_id {
                    Some(rid) => rid.to_string(),
                    None => continue, // 无推荐人，跳过
                },
                _ => continue, // 未知 party
            };

            // 幂等检查：同一用户同一活动同一奖励只发一次
            let already_fulfilled = check_idempotent(
                conn, campaign_id, &target_user_id, trigger_event, party, rtype,
            )
            .unwrap_or(false);
            if already_fulfilled {
                tracing::debug!(
                    "idempotent skip: campaign={}, user={}, type={}, party={}",
                    campaign_id,
                    target_user_id,
                    rtype,
                    party
                );
                continue;
            }

            // ── 分发逻辑 ──
            match rtype {
                "subscription_days" => {
                    handle_subscription_days(
                        conn, campaign_id, campaign_name, user_id, party,
                        value, trigger_event, order_id, &mut fulfillment_ids,
                    );
                }
                "commission_pct" => {
                    handle_commission_pct(
                        conn, campaign_id, campaign_name, user_id,
                        &target_user_id, party, value, trigger_event,
                        order_id, &mut fulfillment_ids,
                    );
                }
                "commission_fix" => {
                    handle_commission_fix(
                        conn, campaign_id, campaign_name, user_id,
                        &target_user_id, party, value, trigger_event,
                        order_id, &mut fulfillment_ids,
                    );
                }
                _ => {
                    tracing::debug!("unknown reward type: {}", rtype);
                }
            }
        }
    }

    Ok(fulfillment_ids)
}

/// 查找当前有效的活动（status=active + 时间窗口内）
fn find_active_campaigns(
    conn: &rusqlite::Connection,
    trigger_event: &str,
) -> Result<Vec<(String, String, String, i64)>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, rewards, attribution_window \
             FROM marketing_campaigns \
             WHERE status='active' AND trigger_event=?1 \
             AND (valid_from IS NULL OR valid_from <= datetime('now')) \
             AND (valid_until IS NULL OR valid_until > datetime('now'))",
        )
        .map_err(|e| format!("query campaigns failed: {}", e))?;

    let rows = stmt
        .query_map(rusqlite::params![trigger_event], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .map_err(|e| format!("query campaigns failed: {}", e))?;

    let campaigns: Vec<(String, String, String, i64)> =
        rows.filter_map(|r| r.ok()).collect();
    Ok(campaigns)
}

/// 幂等检查：同一活动 + 同一用户 + 同一触发事件 + 同一 party + 同一奖励类型是否已 fulfilled
fn check_idempotent(
    conn: &rusqlite::Connection,
    campaign_id: &str,
    user_id: &str,
    trigger_event: &str,
    party: &str,
    reward_type: &str,
) -> Result<bool, String> {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM reward_fulfillments \
             WHERE campaign_id=?1 AND user_id=?2 AND trigger_event=?3 \
             AND party=?4 AND reward_type=?5 AND status='fulfilled'",
            rusqlite::params![campaign_id, user_id, trigger_event, party, reward_type],
            |row| row.get(0),
        )
        .map_err(|e| format!("idempotent check failed: {}", e))?;
    Ok(count > 0)
}

/// 写 reward_fulfillments 记录
fn write_fulfillment(
    conn: &rusqlite::Connection,
    campaign_id: &str,
    user_id: &str,
    party: &str,
    reward_type: &str,
    reward_value: &str,
    trigger_event: &str,
    order_id: Option<&str>,
) -> Result<String, String> {
    let fid = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    conn.execute(
        "INSERT INTO reward_fulfillments \
         (id, campaign_id, user_id, party, reward_type, reward_value, \
          trigger_event, level, status, fulfilled_at, created_at, order_id) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, 'fulfilled', ?8, ?8, ?9)",
        rusqlite::params![
            fid,
            campaign_id,
            user_id,
            party,
            reward_type,
            reward_value,
            trigger_event,
            now,
            order_id,
        ],
    )
    .map_err(|e| format!("write fulfillment failed: {}", e))?;
    Ok(fid)
}

/// 写用户通知
pub fn write_notification(
    conn: &rusqlite::Connection,
    user_id: &str,
    notification_type: &str,
    title: &str,
    body: &str,
    action_url: Option<&str>,
) -> Result<String, String> {
    let nid = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    conn.execute(
        "INSERT INTO user_notifications \
         (id, user_id, notification_type, title, body, action_url, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![nid, user_id, notification_type, title, body, action_url, now],
    )
    .map_err(|e| format!("write notification failed: {}", e))?;
    Ok(nid)
}

// ── 各奖励类型的分发处理 ──

/// 处理 subscription_days 奖励：直接计算到期日，不调 extend_subscription
fn handle_subscription_days(
    conn: &rusqlite::Connection,
    campaign_id: &str,
    campaign_name: &str,
    user_id: &str,
    party: &str,
    value: &serde_json::Value,
    trigger_event: &str,
    order_id: Option<&str>,
    fulfillment_ids: &mut Vec<String>,
) {
    if party != "self" {
        tracing::warn!(
            "subscription_days party must be 'self', got '{}'",
            party
        );
        return;
    }

    let days = match value.as_i64() {
        Some(d) if d > 0 => d,
        _ => {
            tracing::warn!("invalid subscription_days value: {:?}", value);
            return;
        }
    };

    // 直接计算新到期日
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let old_expires = crate::subscription::get_current_expires(conn, user_id).unwrap_or(None);
    let base = match &old_expires {
        Some(d) if d.as_str() >= today.as_str() => d.clone(),
        _ => today.clone(),
    };
    let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
    let new_date = base_date + chrono::Duration::days(days);
    let new_expires = new_date.format("%Y-%m-%d").to_string();

    if let Err(e) = crate::subscription::set_expires(conn, user_id, &new_expires) {
        tracing::warn!("set_expires failed: {}", e);
        return;
    }
    if let Err(e) = crate::subscription::insert_audit_log(
        conn,
        "reward",
        None,
        user_id,
        old_expires.as_deref(),
        &new_expires,
        0,
        None,
        Some(&format!("活动奖励: {}天", days)),
    ) {
        tracing::warn!("insert_audit_log failed: {}", e);
        return;
    }

    // 写 fulfillment
    let fid = match write_fulfillment(
        conn,
        campaign_id,
        user_id,
        party,
        "subscription_days",
        &days.to_string(),
        trigger_event,
        order_id,
    ) {
        Ok(id) => id,
        Err(e) => {
            tracing::warn!("write_fulfillment failed: {}", e);
            return;
        }
    };

    // 写通知
    let title = "🎉 获得会员天数".to_string();
    let body = format!("你通过「{}」获得了 {} 天会员！", campaign_name, days);
    let action_url = format!("share?campaign_id={}", campaign_id);
    if let Err(e) = write_notification(conn, user_id, "reward", &title, &body, Some(&action_url))
    {
        tracing::warn!("write_notification failed: {}", e);
    }

    fulfillment_ids.push(fid);
}

/// 处理 commission_pct 奖励：按比率计算佣金并写入 distribution_commissions
fn handle_commission_pct(
    conn: &rusqlite::Connection,
    campaign_id: &str,
    _campaign_name: &str,
    buyer_id: &str,
    earner_id: &str,
    party: &str,
    value: &serde_json::Value,
    trigger_event: &str,
    order_id: Option<&str>,
    fulfillment_ids: &mut Vec<String>,
) {
    let rate = match value.as_f64() {
        Some(r) if r > 0.0 => r,
        _ => {
            tracing::warn!("invalid commission_pct value: {:?}", value);
            return;
        }
    };

    let order_id_str = match order_id {
        Some(id) => id,
        None => return,
    };

    // 查订单金额
    let order_amount: i64 = match conn.query_row(
        "SELECT amount FROM payment_orders WHERE id = ?1",
        rusqlite::params![order_id_str],
        |row| row.get(0),
    ) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("query order amount failed: {}", e);
            return;
        }
    };

    let amount = (order_amount as f64 * rate) as i64;
    if amount <= 0 {
        return;
    }

    // 写 distribution_commissions
    let commission_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO distribution_commissions \
         (id, campaign_id, earner_id, buyer_id, order_id, order_amount, \
          rate_applied, amount, level, status, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, 'locked', ?9)",
        rusqlite::params![
            commission_id, campaign_id, earner_id, buyer_id,
            order_id_str, order_amount, rate, amount, now,
        ],
    ) {
        tracing::warn!("insert commission failed: {}", e);
        return;
    }

    // 写 fulfillment
    let fid = match write_fulfillment(
        conn,
        campaign_id,
        earner_id,
        party,
        "commission_pct",
        &amount.to_string(),
        trigger_event,
        order_id,
    ) {
        Ok(id) => id,
        Err(e) => {
            tracing::warn!("write_fulfillment failed: {}", e);
            return;
        }
    };

    // 写通知（给推广员）
    let amount_yuan = amount as f64 / 100.0;
    let title = "💰 获得推广佣金".to_string();
    let body = format!("你邀请的好友完成支付，获得 ¥{:.2} 佣金！", amount_yuan);
    if let Err(e) = write_notification(
        conn,
        earner_id,
        "reward",
        &title,
        &body,
        Some("/referral/my-commissions"),
    ) {
        tracing::warn!("write_notification failed: {}", e);
    }

    fulfillment_ids.push(fid);
}

/// 处理 commission_fix 奖励：固定金额佣金
fn handle_commission_fix(
    conn: &rusqlite::Connection,
    campaign_id: &str,
    _campaign_name: &str,
    buyer_id: &str,
    earner_id: &str,
    party: &str,
    value: &serde_json::Value,
    trigger_event: &str,
    order_id: Option<&str>,
    fulfillment_ids: &mut Vec<String>,
) {
    let amount = match value.as_i64() {
        Some(v) if v > 0 => v,
        _ => {
            tracing::warn!("invalid commission_fix value: {:?}", value);
            return;
        }
    };

    let order_id_str = match order_id {
        Some(id) => id,
        None => return,
    };

    // 查订单金额（用于记录）
    let order_amount: i64 = match conn.query_row(
        "SELECT amount FROM payment_orders WHERE id = ?1",
        rusqlite::params![order_id_str],
        |row| row.get(0),
    ) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("query order amount failed: {}", e);
            return;
        }
    };

    // 写 distribution_commissions
    let commission_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO distribution_commissions \
         (id, campaign_id, earner_id, buyer_id, order_id, order_amount, \
          rate_applied, amount, level, status, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0.0, ?7, 1, 'locked', ?8)",
        rusqlite::params![
            commission_id, campaign_id, earner_id, buyer_id,
            order_id_str, order_amount, amount, now,
        ],
    ) {
        tracing::warn!("insert commission failed: {}", e);
        return;
    }

    // 写 fulfillment
    let fid = match write_fulfillment(
        conn,
        campaign_id,
        earner_id,
        party,
        "commission_fix",
        &amount.to_string(),
        trigger_event,
        order_id,
    ) {
        Ok(id) => id,
        Err(e) => {
            tracing::warn!("write_fulfillment failed: {}", e);
            return;
        }
    };

    // 写通知（给推广员）
    let amount_yuan = amount as f64 / 100.0;
    let title = "💰 获得推广佣金".to_string();
    let body = format!("你邀请的好友完成支付，获得 ¥{:.2} 佣金！", amount_yuan);
    if let Err(e) = write_notification(
        conn,
        earner_id,
        "reward",
        &title,
        &body,
        Some("/referral/my-commissions"),
    ) {
        tracing::warn!("write_notification failed: {}", e);
    }

    fulfillment_ids.push(fid);
}

// ── 单元测试 ──

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::init_database;
    use rusqlite::Connection;

    /// 创建测试数据库（in-memory + 初始化 schema）
    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();
        conn
    }

    /// 插入一个测试活动
    fn insert_test_campaign(
        conn: &Connection,
        trigger_event: &str,
        rewards_json: &str,
        status: &str,
    ) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO marketing_campaigns \
             (id, name, campaign_type, status, rewards, trigger_event, \
              attribution_window, valid_from, valid_until, created_at) \
             VALUES (?1, ?2, 'standard', ?3, ?4, ?5, 30, datetime('now','-1 day'), \
                     datetime('now','+30 days'), ?6)",
            rusqlite::params![id, "测试活动", status, rewards_json, trigger_event, now],
        )
        .unwrap();
        id
    }

    /// 插入一个测试用户，返回 user_id
    fn insert_test_user(conn: &Connection) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, format!("test_user_{}", &id[..8]), now],
        )
        .unwrap();
        id
    }

    // ── find_active_campaigns ──

    #[test]
    fn test_find_active_campaigns_found() {
        let conn = setup_db();
        let cid = insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":3}]"#, "active");

        let results = find_active_campaigns(&conn, "registration").unwrap();

        assert_eq!(results.len(), 1, "应找到 1 个活动");
        assert_eq!(results[0].0, cid, "活动 ID 应匹配");
        assert_eq!(results[0].1, "测试活动", "活动名称应匹配");
    }

    #[test]
    fn test_find_active_campaigns_no_match_trigger() {
        let conn = setup_db();
        insert_test_campaign(&conn, "payment",
            r#"[{"type":"commission_pct","party":"inviter","trigger":"payment","value":0.1}]"#, "active");

        let results = find_active_campaigns(&conn, "registration").unwrap();
        assert_eq!(results.len(), 0, "不应找到活动");
    }

    #[test]
    fn test_find_active_campaigns_draft_skipped() {
        let conn = setup_db();
        insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":3}]"#, "draft");

        let results = find_active_campaigns(&conn, "registration").unwrap();
        assert_eq!(results.len(), 0, "草稿状态的活动不应被找到");
    }

    #[test]
    fn test_find_active_campaigns_expired_skipped() {
        let conn = setup_db();
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO marketing_campaigns \
             (id, name, campaign_type, status, rewards, trigger_event, \
              attribution_window, valid_from, valid_until, created_at) \
             VALUES (?1, '过期活动', 'standard', 'active', '[]', 'registration', \
                     30, datetime('now','-30 days'), datetime('now','-1 day'), ?2)",
            rusqlite::params![id, now],
        ).unwrap();

        let results = find_active_campaigns(&conn, "registration").unwrap();
        assert_eq!(results.len(), 0, "过期活动不应被找到");
    }

    // ── check_idempotent ──

    #[test]
    fn test_check_idempotent_not_fulfilled_yet() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let already = check_idempotent(
            &conn, &campaign_id, &user_id, "registration", "self", "subscription_days",
        ).unwrap();

        assert!(!already, "未发放的奖励应返回 false");
    }

    #[test]
    fn test_check_idempotent_already_fulfilled() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        write_fulfillment(&conn, &campaign_id, &user_id, "self", "subscription_days",
            "3", "registration", None).unwrap();

        let already = check_idempotent(
            &conn, &campaign_id, &user_id, "registration", "self", "subscription_days",
        ).unwrap();

        assert!(already, "已发放的奖励应返回 true");
    }

    #[test]
    fn test_check_idempotent_different_user() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_a = insert_test_user(&conn);
        let user_b = insert_test_user(&conn);

        write_fulfillment(&conn, &campaign_id, &user_a, "self", "subscription_days",
            "3", "registration", None).unwrap();

        let already = check_idempotent(
            &conn, &campaign_id, &user_b, "registration", "self", "subscription_days",
        ).unwrap();

        assert!(!already, "其他用户的未发放奖励应返回 false");
    }

    #[test]
    fn test_check_idempotent_different_reward_type() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "payment", "[]", "active");
        let user_id = insert_test_user(&conn);

        write_fulfillment(&conn, &campaign_id, &user_id, "self", "subscription_days",
            "3", "registration", None).unwrap();

        let already = check_idempotent(
            &conn, &campaign_id, &user_id, "payment", "inviter", "commission_pct",
        ).unwrap();

        assert!(!already, "不同奖励类型应返回 false");
    }

    // ── write_fulfillment ──

    #[test]
    fn test_write_fulfillment_creates_record() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let fid = write_fulfillment(&conn, &campaign_id, &user_id, "self",
            "subscription_days", "3", "registration", None).unwrap();

        assert!(!fid.is_empty(), "fulfillment ID 不应为空");

        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM reward_fulfillments WHERE id = ?1",
            rusqlite::params![fid], |row| row.get(0),
        ).unwrap();
        assert_eq!(count, 1, "reward_fulfillments 表中应有 1 条记录");
    }

    #[test]
    fn test_write_fulfillment_with_order_id() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "payment", "[]", "active");
        let user_id = insert_test_user(&conn);

        let order_id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, ?2, '30d', 12000, 'SUCCESS', ?3)",
            rusqlite::params![order_id, user_id, now],
        ).unwrap();

        let fid = write_fulfillment(&conn, &campaign_id, &user_id, "inviter",
            "commission_pct", "1200", "payment", Some(&order_id)).unwrap();

        let stored_order_id: Option<String> = conn.query_row(
            "SELECT order_id FROM reward_fulfillments WHERE id = ?1",
            rusqlite::params![fid], |row| row.get(0),
        ).unwrap();
        assert_eq!(stored_order_id, Some(order_id), "order_id 应正确存储");
    }

    // ── write_notification ──

    #[test]
    fn test_write_notification_creates_record() {
        let conn = setup_db();
        let user_id = insert_test_user(&conn);

        let nid = write_notification(&conn, &user_id, "reward",
            "🎉 获得会员天数", "你通过测试活动获得了 3 天会员！", Some("/profile"),
        ).unwrap();

        assert!(!nid.is_empty(), "notification ID 不应为空");

        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM user_notifications WHERE id = ?1",
            rusqlite::params![nid], |row| row.get(0),
        ).unwrap();
        assert_eq!(count, 1, "user_notifications 表中应有 1 条记录");
    }

    #[test]
    fn test_write_notification_with_null_url() {
        let conn = setup_db();
        let user_id = insert_test_user(&conn);

        let nid = write_notification(&conn, &user_id, "reward", "Test", "Test body", None).unwrap();

        let action_url: Option<String> = conn.query_row(
            "SELECT action_url FROM user_notifications WHERE id = ?1",
            rusqlite::params![nid], |row| row.get(0),
        ).unwrap();
        assert_eq!(action_url, None, "action_url 应为 None");
    }

    // ── handle_subscription_days ──

    #[test]
    fn test_handle_subscription_days_new_user() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let value = serde_json::json!(3);
        let mut fulfillment_ids = Vec::new();

        handle_subscription_days(&conn, &campaign_id, "测试活动", &user_id, "self",
            &value, "registration", None, &mut fulfillment_ids);

        assert_eq!(fulfillment_ids.len(), 1, "应有 1 个 fulfillment");

        let expires: Option<String> = conn.query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert!(expires.is_some(), "subscription_expires 应被设置");
        if let Some(ref e) = expires {
            assert!(e.as_str() >= chrono::Utc::now().format("%Y-%m-%d").to_string().as_str(),
                "到期日应在今天或之后");
        }

        let notif_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM user_notifications WHERE user_id = ?1",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert_eq!(notif_count, 1, "应有 1 条通知");

        let audit_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM subscription_audit_log WHERE target_user_id = ?1",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert_eq!(audit_count, 1, "应有 1 条审计日志");
    }

    #[test]
    fn test_handle_subscription_days_wrong_party_skipped() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let value = serde_json::json!(3);
        let mut fulfillment_ids = Vec::new();

        handle_subscription_days(&conn, &campaign_id, "测试活动", &user_id, "inviter",
            &value, "registration", None, &mut fulfillment_ids);

        assert_eq!(fulfillment_ids.len(), 0, "party 不是 self 时应跳过");
    }

    #[test]
    fn test_handle_subscription_days_invalid_value() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let value = serde_json::json!(0);
        let mut fulfillment_ids = Vec::new();
        handle_subscription_days(&conn, &campaign_id, "测试活动", &user_id, "self",
            &value, "registration", None, &mut fulfillment_ids);
        assert_eq!(fulfillment_ids.len(), 0, "value 为 0 时应跳过");

        let value2 = serde_json::json!("invalid");
        let mut fulfillment_ids2 = Vec::new();
        handle_subscription_days(&conn, &campaign_id, "测试活动", &user_id, "self",
            &value2, "registration", None, &mut fulfillment_ids2);
        assert_eq!(fulfillment_ids2.len(), 0, "无效 value 时应跳过");
    }

    // ── execute_campaign_trigger 端到端测试 ──

    #[test]
    fn test_execute_campaign_trigger_registration_subscription_days() {
        let conn = setup_db();
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":5}]"#,
            "active");
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok(), "execute_campaign_trigger 应成功");
        let fids = result.unwrap();
        assert_eq!(fids.len(), 1, "应有 1 个 fulfillment");

        let expires: Option<String> = conn.query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert!(expires.is_some(), "subscription_expires 应被设置");

        let notif_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM user_notifications WHERE user_id = ?1 AND notification_type='reward'",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert_eq!(notif_count, 1, "应有 1 条奖励通知");
    }

    #[test]
    fn test_execute_campaign_trigger_idempotent_skip() {
        let conn = setup_db();
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":5}]"#,
            "active");
        let user_id = insert_test_user(&conn);

        let r1 = execute_campaign_trigger(&conn, "registration", &user_id, None, None);
        assert!(r1.is_ok());
        assert_eq!(r1.unwrap().len(), 1, "第一次触发应有 1 个 fulfillment");

        let r2 = execute_campaign_trigger(&conn, "registration", &user_id, None, None);
        assert!(r2.is_ok());
        assert_eq!(r2.unwrap().len(), 0, "第二次触发因幂等保护应返回 0 个新 fulfillment");
    }

    #[test]
    fn test_execute_campaign_trigger_no_active_campaigns() {
        let conn = setup_db();
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok(), "没有活动时也应返回 Ok");
        assert_eq!(result.unwrap().len(), 0, "没有活动时应返回空列表");
    }

    #[test]
    fn test_execute_campaign_trigger_referrer_not_provided() {
        let conn = setup_db();
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[
                {"type":"subscription_days","party":"self","trigger":"registration","value":3},
                {"type":"subscription_days","party":"inviter","trigger":"registration","value":1}
            ]"#, "active");
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 1, "只有 self 奖励应执行");
    }

    #[test]
    fn test_execute_campaign_trigger_with_referrer() {
        let conn = setup_db();
        // subscription_days 仅支持 party="self"（handle_subscription_days 会跳过非 self 的 party）
        // 本测试验证：提供 referrer_id 时，self 奖励正常执行，inviter 奖励被正确跳过
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[
                {"type":"subscription_days","party":"self","trigger":"registration","value":3},
                {"type":"subscription_days","party":"inviter","trigger":"registration","value":1}
            ]"#, "active");
        let user_id = insert_test_user(&conn);
        let referrer_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(
            &conn, "registration", &user_id, Some(&referrer_id), None);

        assert!(result.is_ok());
        let fids = result.unwrap();
        // subscription_days 仅支持 party=self，所以只有 self 得到 fulfillment
        assert_eq!(fids.len(), 1, "subscription_days 仅支持 self，inviter 奖励应被跳过");

        // 用户的 subscription_expires 应被设置
        let user_expires: Option<String> = conn.query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![user_id], |row| row.get(0),
        ).unwrap();
        assert!(user_expires.is_some(), "用户的 subscription_expires 应被设置");

        // 推荐人不应收到 subscription_days（因为 party=inviter 被跳过）
        let referrer_expires: Option<String> = conn.query_row(
            "SELECT subscription_expires FROM users WHERE id = ?1",
            rusqlite::params![referrer_id], |row| row.get(0),
        ).unwrap();
        assert!(referrer_expires.is_none(), "推荐人不应收到 subscription_days");
    }

    #[test]
    fn test_execute_campaign_trigger_multiple_campaigns() {
        let conn = setup_db();
        let _c1 = insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":3}]"#,
            "active");
        let _c2 = insert_test_campaign(&conn, "registration",
            r#"[{"type":"subscription_days","party":"self","trigger":"registration","value":7}]"#,
            "active");
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 2, "两个活动各应有一个 fulfillment (共 2 个)");
    }

    #[test]
    fn test_execute_campaign_trigger_unknown_reward_type() {
        let conn = setup_db();
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[
                {"type":"subscription_days","party":"self","trigger":"registration","value":3},
                {"type":"unknown_type","party":"self","trigger":"registration","value":99}
            ]"#, "active");
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 1, "未知奖励类型应被跳过");
    }

    #[test]
    fn test_execute_campaign_trigger_commission_skipped_on_registration() {
        let conn = setup_db();
        let _cid = insert_test_campaign(&conn, "registration",
            r#"[
                {"type":"subscription_days","party":"self","trigger":"registration","value":3},
                {"type":"commission_fix","party":"inviter","trigger":"payment","value":500}
            ]"#, "active");
        let user_id = insert_test_user(&conn);

        let result = execute_campaign_trigger(&conn, "registration", &user_id, None, None);

        assert!(result.is_ok());
        // commission_fix 的 trigger="payment", 不匹配 "registration", 所以被跳过
        assert_eq!(result.unwrap().len(), 1, "只有 subscription_days 应执行");
    }
}
