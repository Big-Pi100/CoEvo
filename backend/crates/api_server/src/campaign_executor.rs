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
    campaign_filter: Option<&str>,
) -> Result<Vec<String>, String> {
    let all_campaigns = find_active_campaigns(conn)?;
    let mut fulfillment_ids = Vec::new();
    tracing::info!("execute_campaign_trigger: event={}, user={}, referrer={:?}, order={:?}, total_campaigns={}",
        trigger_event, user_id, referrer_id, order_id, all_campaigns.len());

    // 推送通知遍历所有活动（推送不分活动范围）
    for (
        campaign_id,
        campaign_name,
        _rewards_json,
        _attribution_window,
        _min_member_count,
        _campaign_type,
    ) in &all_campaigns
    {
        let push_trigger: Option<String> = conn
            .query_row(
                "SELECT push_trigger FROM marketing_campaigns WHERE id = ?1",
                rusqlite::params![campaign_id],
                |row| row.get(0),
            )
            .ok();
        if let Some(ref pt) = push_trigger {
            if pt == trigger_event {
                let push_title = format!("新活动: {}", campaign_name);
                let push_body = format!("{} 活动已开启！", campaign_name);
                let action_url = format!("share?campaign_id={}", campaign_id);
                let nid = uuid::Uuid::new_v4().to_string();
                if let Err(e) = conn.execute(
                    "INSERT INTO user_notifications (id, user_id, notification_type, title, body, action_url, created_at)                      SELECT ?1, ?2, 'campaign_push', ?3, ?4, ?5, datetime('now')                      WHERE NOT EXISTS (SELECT 1 FROM user_notifications WHERE user_id=?2 AND action_url=?5 AND notification_type='campaign_push')",
                    rusqlite::params![nid, user_id, push_title, push_body, action_url],
                ) {
                    tracing::warn!("push notification insert failed: {}", e);
                }
            }
        }
    }

    // 奖励处理遍历所有活动（除非指定了 campaign_filter）
    let mut campaigns = all_campaigns;
    if let Some(cid) = campaign_filter {
        campaigns.retain(|(id, _, _, _, _, _)| id == cid);
    }
    let user_referred_campaign: Option<String> = if campaign_filter.is_none() {
        conn.query_row(
            "SELECT referred_campaign_id FROM users WHERE id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .ok()
        .flatten()
    } else {
        None
    };

    for (
        campaign_id,
        campaign_name,
        rewards_json,
        _attribution_window,
        min_member_count,
        campaign_type,
    ) in &campaigns
    {
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

            // 活动范围检查（无 campaign_filter 时生效）：
            // party=self 的奖励（如注册有礼）：所有注册用户都能获得，不限活动
            // party=inviter/invitee/all 的奖励：只有用户的关联活动与此活动一致才发放
            if campaign_filter.is_none() && party != "self" {
                if let Some(ref ref_cid) = user_referred_campaign {
                    if ref_cid.as_str() != campaign_id.as_str() {
                        tracing::info!(
                            "  reward skip referred campaign: campaign={}, user_ref={}",
                            campaign_id,
                            ref_cid
                        );
                        continue;
                    }
                } else {
                    tracing::info!(
                        "  reward skip no referred campaign: campaign={}",
                        campaign_id
                    );
                    continue;
                }
            }

            // 确定目标用户
            // party: "self"    = 触发事件的用户本人（任何人，不验证推荐关系）
            //         "inviter"  = 邀请人/推荐人（需有 referrer_id，否则跳过）
            //         "invitee"  = 被邀请人（触发者必须有推荐人，否则跳过）
            //         "all"      = 活动所有参与者（拼团/砍价等共同活动）
            let target_users: Vec<String> = match party {
                "self" => vec![user_id.to_string()],
                "inviter" => match referrer_id {
                    Some(rid) => vec![rid.to_string()],
                    None => continue, // 无推荐人时跳过
                },
                "invitee" => {
                    // 被邀请人：触发者必须有上级推荐人
                    let has_referrer: bool = conn
                        .query_row(
                            "SELECT COUNT(*) FROM users WHERE id = ?1 AND referred_by IS NOT NULL",
                            rusqlite::params![user_id],
                            |row| row.get::<_, i64>(0),
                        )
                        .unwrap_or(0)
                        > 0;
                    if !has_referrer {
                        continue;
                    }
                    vec![user_id.to_string()]
                }
                "all" => {
                    // 查活动所有参与者（过滤掉临时试用账户）
                    let mut stmt = match conn.prepare(
                        "SELECT cm.user_id FROM campaign_members cm \
                         JOIN users u ON cm.user_id = u.id \
                         WHERE cm.campaign_id = ?1 AND u.username NOT LIKE 'trial_%'",
                    ) {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let users: Vec<String> = stmt
                        .query_map(rusqlite::params![campaign_id], |row| row.get(0))
                        .ok()
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                        .unwrap_or_default();
                    if users.is_empty() {
                        continue;
                    }
                    // 仅拼团模式（team_discount）检查最小成团人数
                    if *campaign_type == "team_discount" {
                        let unfulfilled: Vec<&String> = users
                            .iter()
                            .filter(|uid| {
                                !check_idempotent(
                                    conn,
                                    campaign_id,
                                    uid,
                                    trigger_event,
                                    party,
                                    rtype,
                                    order_id,
                                )
                                .unwrap_or(true)
                            })
                            .collect();
                        if unfulfilled.len() < *min_member_count as usize {
                            tracing::info!(
                                "  party=all 拼团 skip: campaign={}, unfulfilled={} < min={}",
                                campaign_id,
                                unfulfilled.len(),
                                min_member_count
                            );
                            continue;
                        }
                        tracing::info!(
                            "  party=all 拼团 成团: campaign={}, total={}, unfulfilled={}, min={}",
                            campaign_id,
                            users.len(),
                            unfulfilled.len(),
                            min_member_count
                        );
                    }
                    users
                }
                _ => continue, // 未知 party
            };

            for target_user_id in &target_users {
                // ── 奖励只发给**已注册**的账号（排除 trial 匿名账号）──
                //
                // 🔴 判据换了（2026-09-29）：原为
                //    `real_name IS NOT NULL AND phone_hash IS NOT NULL`
                //    （注释原文：「未提供真实身份信息（姓名+手机号）的用户不能获得奖励」）
                //    —— 那两列已随「实名 + 手机号」删除。
                //
                // 🔑 换成 `email IS NOT NULL` 是**更直接**的表达，而非放宽：
                //    原判据是在用「填了实名 + 手机号」**代理**「这人是不是真实用户」，
                //    而唯一可靠的标志就是**注册完成**（`trial/claim` 会给账号写入 email）。
                //    trial 匿名账号的 email 为 NULL → **依然被挡在奖励之外**，原意图不变。
                let registered: bool = conn
                    .query_row(
                        "SELECT COUNT(*) FROM users WHERE id = ?1 AND email IS NOT NULL",
                        rusqlite::params![target_user_id],
                        |row| row.get::<_, i64>(0),
                    )
                    .unwrap_or(0)
                    > 0;
                if !registered {
                    tracing::info!(
                        "  reward skip: user {} 尚未注册（email 为空）",
                        target_user_id
                    );
                    continue;
                }

                // ── 多级推广追溯 ──
                // 对 commission 类型且 level>1 的奖励，从 target_user 往上追溯找到上级
                let reward_level = reward["level"].as_i64().unwrap_or(1);
                let actual_earner = if (rtype == "commission_pct" || rtype == "commission_fix")
                    && party == "inviter"
                    && reward_level > 1
                {
                    let mut upstream: Option<String> = Some(target_user_id.clone());
                    for _ in 1..reward_level {
                        let current = match upstream {
                            Some(ref uid) => uid.clone(),
                            None => break,
                        };
                        upstream = conn.query_row(
                            "SELECT referred_by FROM users WHERE id = ?1 AND deleted_at IS NULL",
                            rusqlite::params![current],
                            |row| row.get(0),
                        ).ok().flatten();
                    }
                    upstream
                } else {
                    None
                };
                let earner_id: &str = actual_earner.as_deref().unwrap_or(target_user_id);

                // 幂等检查：同一活动同一接收人同一奖励只在同一订单发一次（用 earner_id + order_id 区分）
                let already_fulfilled = check_idempotent(
                    conn,
                    campaign_id,
                    earner_id,
                    trigger_event,
                    party,
                    rtype,
                    order_id,
                )
                .unwrap_or(false);
                if already_fulfilled {
                    tracing::debug!(
                        "idempotent skip: campaign={}, earner={}, type={}, party={}, order={:?}",
                        campaign_id,
                        earner_id,
                        rtype,
                        party,
                        order_id,
                    );
                    continue;
                }

                // 频率检查（once=只一次，靠幂等+唯一索引保障；always=每次触发，无限制）
                let freq = reward["freq"].as_str().unwrap_or("once");
                if freq == "always" {
                    // always: 无额外频率限制，靠幂等检查兜底
                } else {
                    // once: 幂等检查已在上方完成，此处不再重复
                }

                // ── 分发逻辑 ──
                match rtype {
                    "subscription_days" => {
                        handle_subscription_days(
                            conn,
                            campaign_id,
                            campaign_name,
                            target_user_id,
                            party,
                            value,
                            trigger_event,
                            order_id,
                            &mut fulfillment_ids,
                        );
                    }
                    "commission_pct" => {
                        handle_commission_pct(
                            conn,
                            campaign_id,
                            campaign_name,
                            user_id,
                            earner_id,
                            party,
                            value,
                            trigger_event,
                            order_id,
                            &mut fulfillment_ids,
                            reward_level,
                        );
                    }
                    "commission_fix" => {
                        handle_commission_fix(
                            conn,
                            campaign_id,
                            campaign_name,
                            user_id,
                            earner_id,
                            party,
                            value,
                            trigger_event,
                            order_id,
                            &mut fulfillment_ids,
                            reward_level,
                        );
                    }
                    "discount_pct" | "discount_fix" => {
                        // 写 fulfillment（status=granted，用于幂等检查；核销时覆盖为 fulfilled）
                        let fid = uuid::Uuid::new_v4().to_string();
                        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
                        let val_str = reward["value"].to_string();
                        let _ = conn.execute(
                            "INSERT INTO reward_fulfillments \
                             (id, campaign_id, user_id, party, reward_type, reward_value, \
                              trigger_event, level, status, fulfilled_at, created_at, order_id) \
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, 'granted', ?8, ?8, NULL)",
                            rusqlite::params![
                                fid,
                                campaign_id,
                                target_user_id,
                                party,
                                rtype,
                                val_str,
                                trigger_event,
                                now
                            ],
                        );
                        fulfillment_ids.push(fid);
                        // 发放通知 — value 如 0.85 = 85 折
                        let zhe = (reward["value"].as_f64().unwrap_or(1.0) * 100.0) as i64;
                        let discount_title = format!("{}奖励已发放", campaign_name);
                        let discount_body = format!("你获得了 {} 折优惠", zhe);
                        let action_url = format!("share?campaign_id={}", campaign_id);
                        if let Err(e) = write_notification(
                            conn,
                            target_user_id,
                            "reward_grant",
                            &discount_title,
                            &discount_body,
                            Some(&action_url),
                        ) {
                            tracing::warn!("write discount notification failed: {}", e);
                        }
                    }
                    _ => {
                        tracing::debug!("unknown reward type: {}", rtype);
                    }
                }
            } // end for target_user_id
        }
    }

    Ok(fulfillment_ids)
}

/// 查找当前有效的活动（status=active + 时间窗口内）
/// 不按 trigger_event 过滤，由 per-reward trigger 决定
fn find_active_campaigns(
    conn: &rusqlite::Connection,
) -> Result<Vec<(String, String, String, i64, i64, String)>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, rewards, attribution_window, COALESCE(min_member_count, 1), campaign_type \
             FROM marketing_campaigns \
             WHERE status='active' \
             AND (valid_from IS NULL OR valid_from <= datetime('now')) \
             AND (valid_until IS NULL OR valid_until > datetime('now'))",
        )
        .map_err(|e| format!("query campaigns failed: {}", e))?;

    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
            ))
        })
        .map_err(|e| format!("query campaigns failed: {}", e))?;

    let campaigns: Vec<(String, String, String, i64, i64, String)> =
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
    order_id: Option<&str>,
) -> Result<bool, String> {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM reward_fulfillments \
             WHERE campaign_id=?1 AND user_id=?2 AND trigger_event=?3 \
             AND party=?4 AND reward_type=?5 AND status IN ('fulfilled', 'granted') \
             AND (?6 IS NULL AND order_id IS NULL OR order_id = ?6)",
            rusqlite::params![
                campaign_id,
                user_id,
                trigger_event,
                party,
                reward_type,
                order_id
            ],
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
        rusqlite::params![
            nid,
            user_id,
            notification_type,
            title,
            body,
            action_url,
            now
        ],
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
    recipient_id: &str,
    raw_party: &str,
    value: &serde_json::Value,
    trigger_event: &str,
    order_id: Option<&str>,
    fulfillment_ids: &mut Vec<String>,
) {
    let days = match value.as_i64() {
        Some(d) if d > 0 => d,
        _ => {
            tracing::warn!("invalid subscription_days value: {:?}", value);
            return;
        }
    };

    // 直接计算新到期日
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let old_expires = crate::subscription::get_current_expires(conn, recipient_id).unwrap_or(None);
    let base = match &old_expires {
        Some(d) if d.len() >= 10 && &d[..10] >= today.as_str() => {
            // 兼容 ISO 8601 ("2026-07-08T14:44:42Z") 和纯日期格式
            d[..10].to_string()
        }
        _ => today.clone(),
    };
    let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
        .unwrap_or_else(|_| chrono::Utc::now().date_naive());
    let new_date = base_date + chrono::Duration::days(days);
    let new_expires = new_date.format("%Y-%m-%d").to_string();

    if let Err(e) = crate::subscription::set_expires(conn, recipient_id, &new_expires) {
        tracing::warn!("set_expires failed: {}", e);
        return;
    }
    if let Err(e) = crate::subscription::insert_audit_log(
        conn,
        "reward",
        None,
        recipient_id,
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
        recipient_id,
        raw_party,
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
    if let Err(e) = write_notification(
        conn,
        recipient_id,
        "reward_grant",
        &title,
        &body,
        Some(&action_url),
    ) {
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
    level: i64,
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
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'locked', ?10)",
        rusqlite::params![
            commission_id,
            campaign_id,
            earner_id,
            buyer_id,
            order_id_str,
            order_amount,
            rate,
            amount,
            level,
            now,
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
    level: i64,
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
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0.0, ?7, ?8, 'locked', ?9)",
        rusqlite::params![
            commission_id,
            campaign_id,
            earner_id,
            buyer_id,
            order_id_str,
            order_amount,
            amount,
            level,
            now,
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
        let cid = insert_test_campaign(
            &conn,
            "registration",
            r#"[{"type":"subscription_days","party":"inviter","trigger":"registration","value":3}]"#,
            "active",
        );

        let results = find_active_campaigns(&conn).unwrap();

        assert_eq!(results.len(), 1, "应找到 1 个活动");
        assert_eq!(results[0].0, cid, "活动 ID 应匹配");
        assert_eq!(results[0].1, "测试活动", "活动名称应匹配");
    }

    #[test]
    fn test_find_active_campaigns_any_trigger() {
        let conn = setup_db();
        insert_test_campaign(
            &conn,
            "payment",
            r#"[{"type":"commission_pct","party":"inviter","trigger":"payment","value":0.1}]"#,
            "active",
        );

        let results = find_active_campaigns(&conn).unwrap();
        assert_eq!(results.len(), 1, "不再按 trigger_event 过滤，应找到");
    }

    #[test]
    fn test_find_active_campaigns_draft_skipped() {
        let conn = setup_db();
        insert_test_campaign(
            &conn,
            "registration",
            r#"[{"type":"subscription_days","party":"inviter","trigger":"registration","value":3}]"#,
            "draft",
        );

        let results = find_active_campaigns(&conn).unwrap();
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
        )
        .unwrap();

        let results = find_active_campaigns(&conn).unwrap();
        assert_eq!(results.len(), 0, "过期活动不应被找到");
    }

    // ── check_idempotent ──

    #[test]
    fn test_check_idempotent_not_fulfilled_yet() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let already = check_idempotent(
            &conn,
            &campaign_id,
            &user_id,
            "registration",
            "self",
            "subscription_days",
            None,
        )
        .unwrap();

        assert!(!already, "未发放的奖励应返回 false");
    }

    #[test]
    fn test_check_idempotent_already_fulfilled() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        write_fulfillment(
            &conn,
            &campaign_id,
            &user_id,
            "self",
            "subscription_days",
            "3",
            "registration",
            None,
        )
        .unwrap();

        let already = check_idempotent(
            &conn,
            &campaign_id,
            &user_id,
            "registration",
            "self",
            "subscription_days",
            None,
        )
        .unwrap();

        assert!(already, "已发放的奖励应返回 true");
    }

    #[test]
    fn test_check_idempotent_different_user() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_a = insert_test_user(&conn);
        let user_b = insert_test_user(&conn);

        write_fulfillment(
            &conn,
            &campaign_id,
            &user_a,
            "self",
            "subscription_days",
            "3",
            "registration",
            None,
        )
        .unwrap();

        let already = check_idempotent(
            &conn,
            &campaign_id,
            &user_b,
            "registration",
            "self",
            "subscription_days",
            None,
        )
        .unwrap();

        assert!(!already, "其他用户的未发放奖励应返回 false");
    }

    #[test]
    fn test_check_idempotent_different_reward_type() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "payment", "[]", "active");
        let user_id = insert_test_user(&conn);

        write_fulfillment(
            &conn,
            &campaign_id,
            &user_id,
            "self",
            "subscription_days",
            "3",
            "registration",
            None,
        )
        .unwrap();

        let already = check_idempotent(
            &conn,
            &campaign_id,
            &user_id,
            "payment",
            "self",
            "commission_pct",
            None,
        )
        .unwrap();

        assert!(!already, "不同奖励类型应返回 false");
    }

    // ── write_fulfillment ──

    #[test]
    fn test_write_fulfillment_creates_record() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let fid = write_fulfillment(
            &conn,
            &campaign_id,
            &user_id,
            "self",
            "subscription_days",
            "3",
            "registration",
            None,
        )
        .unwrap();

        assert!(!fid.is_empty(), "fulfillment ID 不应为空");

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM reward_fulfillments WHERE id = ?1",
                rusqlite::params![fid],
                |row| row.get(0),
            )
            .unwrap();
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
        )
        .unwrap();

        let fid = write_fulfillment(
            &conn,
            &campaign_id,
            &user_id,
            "self",
            "commission_pct",
            "1200",
            "payment",
            Some(&order_id),
        )
        .unwrap();

        let stored_order_id: Option<String> = conn
            .query_row(
                "SELECT order_id FROM reward_fulfillments WHERE id = ?1",
                rusqlite::params![fid],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored_order_id, Some(order_id), "order_id 应正确存储");
    }

    // ── write_notification ──

    #[test]
    fn test_write_notification_creates_record() {
        let conn = setup_db();
        let user_id = insert_test_user(&conn);

        let nid = write_notification(
            &conn,
            &user_id,
            "reward",
            "🎉 获得会员天数",
            "你通过测试活动获得了 3 天会员！",
            Some("/profile"),
        )
        .unwrap();

        assert!(!nid.is_empty(), "notification ID 不应为空");

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM user_notifications WHERE id = ?1",
                rusqlite::params![nid],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "user_notifications 表中应有 1 条记录");
    }

    #[test]
    fn test_write_notification_with_null_url() {
        let conn = setup_db();
        let user_id = insert_test_user(&conn);

        let nid = write_notification(&conn, &user_id, "reward", "Test", "Test body", None).unwrap();

        let action_url: Option<String> = conn
            .query_row(
                "SELECT action_url FROM user_notifications WHERE id = ?1",
                rusqlite::params![nid],
                |row| row.get(0),
            )
            .unwrap();
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

        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动",
            &user_id,
            "inviter",
            &value,
            "registration",
            None,
            &mut fulfillment_ids,
        );

        assert_eq!(fulfillment_ids.len(), 1, "应有 1 个 fulfillment");

        let expires: Option<String> = conn
            .query_row(
                "SELECT subscription_expires FROM users WHERE id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(expires.is_some(), "subscription_expires 应被设置");
        if let Some(ref e) = expires {
            assert!(
                e.as_str() >= chrono::Utc::now().format("%Y-%m-%d").to_string().as_str(),
                "到期日应在今天或之后"
            );
        }

        let notif_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM user_notifications WHERE user_id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(notif_count, 1, "应有 1 条通知");

        let audit_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM subscription_audit_log WHERE target_user_id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(audit_count, 1, "应有 1 条审计日志");
    }

    #[test]
    fn test_handle_subscription_days_for_any_user() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let value = serde_json::json!(3);
        let mut fulfillment_ids = Vec::new();

        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动",
            &user_id,
            "inviter",
            &value,
            "registration",
            None,
            &mut fulfillment_ids,
        );

        assert_eq!(fulfillment_ids.len(), 1, "派对过滤已移除，应正常发放");
    }

    #[test]
    fn test_handle_subscription_days_invalid_value() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user(&conn);

        let value = serde_json::json!(0);
        let mut fulfillment_ids = Vec::new();
        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动",
            &user_id,
            "inviter",
            &value,
            "registration",
            None,
            &mut fulfillment_ids,
        );
        assert_eq!(fulfillment_ids.len(), 0, "value 为 0 时应跳过");

        let value2 = serde_json::json!("invalid");
        let mut fulfillment_ids2 = Vec::new();
        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动",
            &user_id,
            "inviter",
            &value2,
            "registration",
            None,
            &mut fulfillment_ids2,
        );
        assert_eq!(fulfillment_ids2.len(), 0, "无效 value 时应跳过");
    }

    /// 插入一个带 ISO 8601 subscription_expires 的测试用户
    fn insert_test_user_with_iso_expires(conn: &Connection) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let iso_expires = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        conn.execute(
            "INSERT INTO users (id, username, subscription_expires, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id, format!("test_user_{}", &id[..8]), iso_expires, now],
        )
        .unwrap();
        id
    }

    /// 插入一个**已注册**（有 email）的测试用户
    ///
    /// 🔴 原名 `insert_test_user_with_real_info`（插 `real_name` + `phone_hash`）——
    ///    那两列已于 2026-09-29 删除，「已注册」的标志改为 **`email` 非空**。
    fn insert_test_user_with_email(conn: &Connection) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        conn.execute(
            "INSERT INTO users (id, username, email, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![
                id,
                format!("test_user_{}", &id[..8]),
                format!("{}@example.com", &id[..8]),
                now
            ],
        )
        .unwrap();
        id
    }

    #[test]
    fn test_handle_subscription_days_iso8601_expires() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(&conn, "registration", "[]", "active");
        let user_id = insert_test_user_with_iso_expires(&conn);

        // 第一次添加 3 天
        let mut fids1 = Vec::new();
        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动",
            &user_id,
            "inviter",
            &serde_json::json!(3),
            "registration",
            None,
            &mut fids1,
        );
        assert_eq!(fids1.len(), 1, "第一次应创建 fulfillment");

        let expires1: String = conn
            .query_row(
                "SELECT subscription_expires FROM users WHERE id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            )
            .unwrap();

        // 第二次再添加 7 天（模拟两条奖励叠加）
        let mut fids2 = Vec::new();
        handle_subscription_days(
            &conn,
            &campaign_id,
            "测试活动2",
            &user_id,
            "inviter",
            &serde_json::json!(7),
            "registration",
            None,
            &mut fids2,
        );
        assert_eq!(fids2.len(), 1, "第二次应创建 fulfillment");

        let expires2: String = conn
            .query_row(
                "SELECT subscription_expires FROM users WHERE id = ?1",
                rusqlite::params![user_id],
                |row| row.get(0),
            )
            .unwrap();

        // expires2 应在 expires1 之后 7 天（累加，非覆盖）
        let d1 = chrono::NaiveDate::parse_from_str(&expires1[..10], "%Y-%m-%d").unwrap();
        let d2 = chrono::NaiveDate::parse_from_str(&expires2[..10], "%Y-%m-%d").unwrap();
        let diff = (d2 - d1).num_days();
        assert!(diff >= 7, "第二次应累加 7 天，实际只差 {} 天", diff);
    }

    #[test]
    fn test_reward_requires_registered_account() {
        let conn = setup_db();
        let campaign_id = insert_test_campaign(
            &conn,
            "registration",
            r#"[{"type":"subscription_days","party":"self","value":3,"trigger":"registration","freq":"once"}]"#,
            "active",
        );
        // 未注册 —— trial 匿名账号（email 为 NULL）
        let user_anonymous = insert_test_user(&conn);

        // 已注册 —— 有 email
        let user_registered = insert_test_user_with_email(&conn);

        let result_anon =
            execute_campaign_trigger(&conn, "registration", &user_anonymous, None, None, None)
                .unwrap();
        assert_eq!(
            result_anon.len(),
            0,
            "未注册（email 为空）的账号不应获得奖励"
        );

        let result_reg =
            execute_campaign_trigger(&conn, "registration", &user_registered, None, None, None)
                .unwrap();
        assert_eq!(result_reg.len(), 1, "已注册（有 email）的账号应获得奖励");

        // ⚠️ `campaign_id` 用完即弃：本测试只关心「奖励是否发放」，
        //    活动 id 由 `insert_test_campaign` 建好并被 trigger 按 trigger 类型匹配到。
        let _ = campaign_id;
    }

    #[test]
    fn test_executor_campaign_filter_scope() {
        let conn = setup_db();
        // 创建两个活动：一个 self 奖励，一个 inviter 奖励
        let _cid_self = insert_test_campaign(
            &conn,
            "registration",
            r#"[{"type":"subscription_days","party":"self","value":3,"trigger":"registration","freq":"once"}]"#,
            "active",
        );
        let cid_inviter = insert_test_campaign(
            &conn,
            "registration",
            r#"[{"type":"subscription_days","party":"inviter","value":7,"trigger":"registration","freq":"once"}]"#,
            "active",
        );

        // ⚠️ 必须是**已注册**（有 email）的用户 —— 奖励发放要求 `email IS NOT NULL`（2026-09-29 起的判据）
        let inviter_id = insert_test_user_with_email(&conn);
        let invitee_id = insert_test_user_with_email(&conn);

        // 设置 invitee 的 referred_by 和 referred_campaign_id
        conn.execute(
            "UPDATE users SET referred_by = ?1, referred_campaign_id = ?2 WHERE id = ?3",
            rusqlite::params![inviter_id, cid_inviter, invitee_id],
        )
        .unwrap();

        // 不加 campaign_filter（处理所有活动）
        let results = execute_campaign_trigger(
            &conn,
            "registration",
            &invitee_id,
            Some(&inviter_id),
            None,
            None,
        )
        .unwrap();
        // self 奖励 + inviter 奖励 = 2 条 fulfillment
        assert_eq!(results.len(), 2, "应有 2 条 fulfillment（self + inviter）");
    }
}
