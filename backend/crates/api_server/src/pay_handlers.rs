//! 支付相关 Handler — 下单 / 回调 / 订单查询

use axum::{
    extract::{Path, Query},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::subscription;
use crate::distribution_handler::net_available_commission;

#[derive(Deserialize)]
pub struct UserOrdersQuery {
    pub user_id: Option<String>,
}

/// POST /api/pay/native — Native 支付下单
pub async fn native_pay_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let user_id = match payload.get("user_id").and_then(|v| v.as_str()) {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => return (StatusCode::BAD_REQUEST, "user_id 不能为空").into_response(),
    };
    let plan_id = match payload.get("plan_id").and_then(|v| v.as_str()) {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => return (StatusCode::BAD_REQUEST, "plan_id 不能为空").into_response(),
    };

    // 折后价（拼团/砍价场景覆盖 plan.price）
    let actual_price: Option<i64> = payload.get("actual_price").and_then(|v| v.as_i64());

    // 佣金抵扣金额（分），0 或 None 表示不使用佣金抵扣
    let commission_discount: Option<i64> = payload.get("commission_discount").and_then(|v| v.as_i64());

    // 查套餐
    let mut conn = crate::db_pool::get_conn();
    let plan = match subscription::get_plan_by_id(&conn, &plan_id) {
        Ok(Some(p)) => p,
        Ok(None) => return (StatusCode::NOT_FOUND, "套餐不存在").into_response(),
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询套餐失败: {}", e)).into_response(),
    };

    if !plan.is_active {
        return (StatusCode::BAD_REQUEST, "套餐已下架").into_response();
    }

    // 检查可用性
    if let Some(max) = plan.max_uses {
        if plan.used_count >= max {
            return (StatusCode::BAD_REQUEST, "套餐已售罄").into_response();
        }
    }

    // 实际支付金额（actual_price 覆盖 plan.price，砍价/拼团场景）
    let base_price = actual_price.unwrap_or(plan.price);
    if base_price > plan.price {
        return (StatusCode::BAD_REQUEST, "actual_price 不能高于 plan.price").into_response();
    }

    // ── 佣金抵扣校验（只读，不操作 DB）──
    let mut commission_used: i64 = 0;
    let mut commission_ids: Vec<String> = Vec::new();
    let mut full_deduct_ids: Vec<String> = Vec::new();
    let mut full_deduct_amounts: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    let mut partial_deduct_id: Option<(String, i64)> = None;
    if let Some(discount) = commission_discount.filter(|&d| d > 0) {
        if discount >= base_price {
            // 全额抵扣，final_price=0 走免费路径
            // 无需再校验
        }

        // 查可用佣金总额
        let available = net_available_commission(&conn, &user_id);

        if discount > available {
            return (StatusCode::BAD_REQUEST, "佣金不足").into_response();
        }

        // FIFO 取佣金记录（预计算需要扣的佣金 ID）
        let records: Vec<(String, i64)> = {
            let mut stmt = match conn.prepare(
                "SELECT id, amount FROM distribution_commissions WHERE earner_id=?1 AND status='available' ORDER BY created_at ASC",
            ) {
                Ok(s) => s,
                Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询佣金记录失败: {}", e)).into_response(),
            };
            let mapped = match stmt.query_map(rusqlite::params![user_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            }) {
                Ok(rows) => rows,
                Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("遍历佣金记录失败: {}", e)).into_response(),
            };
            mapped.filter_map(|r| r.ok()).collect()
        };

        let mut remaining = discount;

        for (id, amount) in &records {
            if remaining <= 0 {
                break;
            }
            if *amount <= remaining {
                // 整条扣，标记 used
                full_deduct_ids.push(id.clone());
                full_deduct_amounts.insert(id.clone(), *amount);
                commission_used += amount;
                remaining -= amount;
            } else {
                // 部分扣：只扣需要的金额，记录保留
                partial_deduct_id = Some((id.clone(), remaining));
                commission_used += remaining;
                break;
            }
        }
        // 合并佣金 ID 用于响应
        commission_ids = full_deduct_ids.clone();
        if let Some((pid, _)) = &partial_deduct_id {
            commission_ids.push(pid.clone());
        }
    }

    let final_price = base_price - commission_used;

    // 生成订单号
    let now = chrono::Utc::now();
    let order_id = format!("OE{}", &uuid::Uuid::new_v4().to_string()[..20]);

    // 到期时间（下单后 10 分钟未支付自动关闭）
    let expire = (now + chrono::Duration::minutes(10)).format("%Y-%m-%dT%H:%M:%S+08:00").to_string();

    // 免费（price=0 或折扣后为 0）跳过微信支付，直接激活
    if final_price <= 0 {
        let created_at = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let order_amount = final_price.max(0);

        // 事务内：扣佣金 + 写订单 + 激活订阅，任一失败整体回滚
        let tx = match conn.transaction() {
            Ok(t) => t,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("事务启动失败: {}", e)).into_response(),
        };

        // 扣佣金：INSERT expense 记录（佣金记录本身不可变，只靠 expense 表追溯可用余额）
        for cid in &full_deduct_ids {
            let orig_amount = full_deduct_amounts.get(cid).copied().unwrap_or(0);
            if let Err(e) = tx.execute(
                "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, ref_commission_id, created_at)
                 SELECT ?1, earner_id, ?2, 'subscription', 'confirmed', id, datetime('now')
                 FROM distribution_commissions WHERE id=?3 AND status='available'",
                rusqlite::params![uuid::Uuid::new_v4().to_string(), orig_amount, cid],
            ) {
                return (StatusCode::INTERNAL_SERVER_ERROR, format!("插入抵扣记录失败: {}", e)).into_response();
            }
        }
        if let Some((pid, deduct_amount)) = &partial_deduct_id {
            if let Err(e) = tx.execute(
                "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, ref_commission_id, created_at)
                 SELECT ?1, earner_id, ?2, 'subscription', 'confirmed', id, datetime('now')
                 FROM distribution_commissions WHERE id=?3 AND status='available' AND amount >= ?2",
                rusqlite::params![uuid::Uuid::new_v4().to_string(), deduct_amount, pid],
            ) {
                return (StatusCode::INTERNAL_SERVER_ERROR, format!("插入部分抵扣记录失败: {}", e)).into_response();
            }
        }

        // 写订单
        if let Err(e) = tx.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, paid_at, created_at)
             VALUES (?1, ?2, ?3, ?4, 'SUCCESS', ?5, ?5)",
            rusqlite::params![order_id, user_id, plan_id, order_amount, created_at],
        ) {
            return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入订单失败: {}", e)).into_response();
        }

        // 激活订阅
        match subscription::extend_subscription(
            &tx, &user_id, &plan_id, None, Some(&order_id), None,
        ) {
            Ok(new_expires) => {
                if let Err(e) = tx.commit() {
                    return (StatusCode::INTERNAL_SERVER_ERROR, format!("事务提交失败: {}", e)).into_response();
                }
                return (
                    StatusCode::OK,
                    json!({
                        "order_id": order_id,
                        "code_url": "",
                        "amount": 0,
                        "paid": true,
                        "new_expires": new_expires,
                        "commission_used": commission_used,
                        "commission_ids": commission_ids,
                    }).to_string(),
                ).into_response();
            }
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("激活订阅失败: {}", e)).into_response(),
        }
    }

    // 调微信下单（price > 0）
    // 先调微信 API（外部 HTTP 调用，不在 DB 事务内），成功后再事务扣佣金+写订单
    let wechat_config = match crate::wechat_pay::WechatPayConfig::from_env() {
        Some(c) => c,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "微信支付未配置").into_response(),
    };

    match crate::wechat_pay::native_order(
        &wechat_config,
        &order_id,
        &format!("CoEvo {}", plan.name),
        final_price,
        &expire,
    )
    .await
    {
        Ok(resp) => {
            let order_amount = final_price.max(0);
            let created_at = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

            // 事务内：扣佣金 + 写 NOTPAY 订单，微信已返回成功才扣佣金
            let tx = match conn.transaction() {
                Ok(t) => t,
                Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("事务启动失败: {}", e)).into_response(),
            };

            for cid in &full_deduct_ids {
                if let Err(e) = tx.execute(
                    "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, ref_commission_id, created_at)
                     SELECT ?1, earner_id, amount, 'subscription', 'confirmed', id, datetime('now')
                     FROM distribution_commissions WHERE id=?2 AND status='available'",
                    rusqlite::params![uuid::Uuid::new_v4().to_string(), cid],
                ) {
                    return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入抵扣记录失败: {}", e)).into_response();
                }
            }
            if let Some((pid, deduct_amount)) = &partial_deduct_id {
                if let Err(e) = tx.execute(
                    "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, ref_commission_id, created_at)
                     SELECT ?1, earner_id, ?2, 'subscription', 'confirmed', id, datetime('now')
                     FROM distribution_commissions WHERE id=?3 AND status='available' AND amount >= ?2",
                    rusqlite::params![uuid::Uuid::new_v4().to_string(), deduct_amount, pid],
                ) {
                    return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入抵扣记录失败: {}", e)).into_response();
                }
            }

            if let Err(e) = tx.execute(
                "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, prepay_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, 'NOTPAY', ?5, ?6)",
                rusqlite::params![order_id, user_id, plan_id, order_amount, resp.prepay_id, created_at],
            ) {
                return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入订单失败: {}", e)).into_response();
            }

            if let Err(e) = tx.commit() {
                return (StatusCode::INTERNAL_SERVER_ERROR, format!("事务提交失败: {}", e)).into_response();
            }

            (
                StatusCode::OK,
                json!({
                    "order_id": order_id,
                    "code_url": resp.code_url,
                    "prepay_id": resp.prepay_id,
                    "amount": final_price,
                    "commission_used": commission_used,
                    "commission_ids": commission_ids,
                })
                .to_string(),
            )
                .into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("微信下单失败: {}", e)).into_response(),
    }
}

/// POST /api/pay/notify — 微信支付回调
pub async fn pay_notify_handler(
    headers: axum::http::HeaderMap,
    body: String,
) -> impl IntoResponse {
    let wechat_config = match crate::wechat_pay::WechatPayConfig::from_env() {
        Some(c) => c,
        None => {
            tracing::error!("pay_notify: 微信支付未配置");
            return (StatusCode::INTERNAL_SERVER_ERROR, "未配置").into_response();
        }
    };

    // 获取微信签名相关 header
    let signature = match headers.get("Wechatpay-Signature").and_then(|v| v.to_str().ok()) {
        Some(s) => s,
        None => return (StatusCode::BAD_REQUEST, "缺少 Wechatpay-Signature").into_response(),
    };
    let timestamp = match headers.get("Wechatpay-Timestamp").and_then(|v| v.to_str().ok()) {
        Some(s) => s,
        None => return (StatusCode::BAD_REQUEST, "缺少 Wechatpay-Timestamp").into_response(),
    };
    let nonce = match headers.get("Wechatpay-Nonce").and_then(|v| v.to_str().ok()) {
        Some(s) => s,
        None => return (StatusCode::BAD_REQUEST, "缺少 Wechatpay-Nonce").into_response(),
    };

    // 验签
    match crate::wechat_pay::verify_notify(&wechat_config, signature, timestamp, nonce, &body) {
        Ok(event_type) => {
            if event_type != "TRANSACTION.SUCCESS" {
                // 非支付成功事件，直接返回成功
                return (StatusCode::OK, json!({"code": "SUCCESS"}).to_string()).into_response();
            }
        }
        Err(e) => {
            tracing::error!("pay_notify: 验签失败: {}", e);
            return (StatusCode::UNAUTHORIZED, "验签失败").into_response();
        }
    }

    // 解析回调 body
    let json_body: serde_json::Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("JSON 解析失败: {}", e)).into_response(),
    };

    let resource = match json_body["resource"].as_object() {
        Some(r) => r,
        None => return (StatusCode::BAD_REQUEST, "缺少 resource").into_response(),
    };

    // 解密 resource 中的 ciphertext（使用 APIv3 密钥的 AEAD_AES_256_GCM）
    let ciphertext = match resource.get("ciphertext").and_then(|v| v.as_str()) {
        Some(c) => c,
        None => return (StatusCode::BAD_REQUEST, "缺少 ciphertext").into_response(),
    };
    let associated_data = resource.get("associated_data").and_then(|v| v.as_str()).unwrap_or("");
    let nonce_resource = resource.get("nonce").and_then(|v| v.as_str()).unwrap_or("");

    let decrypted = match decrypt_aes_256_gcm(&wechat_config.api_v3_key, ciphertext, nonce_resource, associated_data) {
        Ok(d) => d,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("解密失败: {}", e)).into_response(),
    };

    let pay_data: serde_json::Value = match serde_json::from_str(&decrypted) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("解密数据解析失败: {}", e)).into_response(),
    };

    let out_trade_no = match pay_data["out_trade_no"].as_str() {
        Some(s) => s.to_string(),
        None => return (StatusCode::BAD_REQUEST, "缺少 out_trade_no").into_response(),
    };
    let transaction_id = match pay_data["transaction_id"].as_str() {
        Some(s) => s.to_string(),
        None => return (StatusCode::BAD_REQUEST, "缺少 transaction_id").into_response(),
    };

    let conn = crate::db_pool::get_conn();

    // 查询订单
    let order: Result<(String, String, String, String), _> = conn.query_row(
        "SELECT user_id, plan_id, amount, status FROM payment_orders WHERE id = ?1",
        rusqlite::params![out_trade_no],
        |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        )),
    );

    let (user_id, plan_id, _amount, status) = match order {
        Ok(o) => o,
        Err(_) => return (StatusCode::NOT_FOUND, "订单不存在").into_response(),
    };

    if status == "SUCCESS" {
        // 已处理过，避免重复
        return (StatusCode::OK, json!({"code": "SUCCESS"}).to_string()).into_response();
    }

    // 更新订单状态
    let paid_at = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    if let Err(e) = conn.execute(
        "UPDATE payment_orders SET status='SUCCESS', transaction_id=?1, paid_at=?2 WHERE id=?3",
        rusqlite::params![transaction_id, paid_at, out_trade_no],
    ) {
        tracing::error!("更新订单状态失败: {}", e);
        return (StatusCode::INTERNAL_SERVER_ERROR, "更新订单失败").into_response();
    }

    // 延期订阅
    match subscription::extend_subscription(
        &conn,
        &user_id,
        &plan_id,
        None,      // operator_id = NULL（系统）
        Some(&out_trade_no),
        Some("微信支付"),
    ) {
        Ok(new_expires) => {
            tracing::info!("pay_notify: 用户 {} 订阅延期至 {}", user_id, new_expires);

            // === 分销归因：订单支付成功 ===
            let _ = distribute_commission_on_payment(&conn, &out_trade_no);

            (StatusCode::OK, json!({"code": "SUCCESS"}).to_string()).into_response()
        }
        Err(e) => {
            tracing::error!("pay_notify: 延期失败: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("延期失败: {}", e)).into_response()
        }
    }
}

/// 订单支付成功时执行分销归因
///
/// 通过 campaign_executor 统一处理佣金分发和 subscription_days 等奖励。
pub fn distribute_commission_on_payment(
    conn: &rusqlite::Connection,
    order_id: &str,
) -> Result<(), String> {
    // 查订单和推荐人
    let (buyer_id, referrer_id): (String, Option<String>) = conn.query_row(
        "SELECT po.user_id, u.referred_by FROM payment_orders po JOIN users u ON po.user_id = u.id WHERE po.id = ?1",
        rusqlite::params![order_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).map_err(|e| format!("订单查询失败: {}", e))?;

    // 触发支付活动（commission 分发 + subscription_days 等）
    let _ = crate::campaign_executor::execute_campaign_trigger(
        conn, "payment", &buyer_id, referrer_id.as_deref(), Some(order_id), None,
    );

    // 核销折扣：用户支付后，将 status=granted 的折扣标记为 fulfilled（已使用）
    let discount_campaign: Option<(String, String)> = {
        let cid: Option<String> = conn.query_row(
            "SELECT referred_campaign_id FROM users WHERE id = ?1",
            rusqlite::params![buyer_id],
            |row| row.get(0),
        ).ok().flatten();
        match cid {
            Some(ref c) if !c.is_empty() => {
                conn.query_row(
                    "SELECT id, name FROM marketing_campaigns \
                     WHERE id = ?1 AND status='active' AND rewards LIKE '%discount_pct%'",
                    rusqlite::params![c],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                ).ok()
            }
            _ => None,
        }
    };

    if let Some((_campaign_id, campaign_name)) = discount_campaign {
        // 核销 invitee 折扣（被邀请人自己支付时）
        let redeemed = conn.execute(
            "UPDATE reward_fulfillments SET status = 'fulfilled', order_id = ?1 \
             WHERE user_id = ?2 AND party = 'invitee' AND reward_type IN ('discount_pct', 'discount_fix') \
             AND status = 'granted' AND order_id IS NULL",
            rusqlite::params![order_id, buyer_id],
        ).unwrap_or(0);
        if redeemed > 0 {
            let _ = crate::campaign_executor::write_notification(
                conn, &buyer_id, "reward_redeem",
                &format!("📉 折扣已使用"),
                &format!("你在本次支付中使用了「{}」推荐折扣优惠！", campaign_name),
                None,
            );
            tracing::info!("distribute_commission_on_payment: redeemed invitee discount for {}, order={}", buyer_id, order_id);
        }
    }

    // 核销 inviter 折扣（邀请人自己支付时）
    let inviter_redeemed = conn.execute(
        "UPDATE reward_fulfillments SET status = 'fulfilled', order_id = ?1 \
         WHERE user_id = ?2 AND party = 'inviter' AND reward_type IN ('discount_pct', 'discount_fix') \
         AND status = 'granted' AND order_id IS NULL",
        rusqlite::params![order_id, buyer_id],
    ).unwrap_or(0);
    if inviter_redeemed > 0 {
        // 查活动名
        let camp_name: String = conn.query_row(
            "SELECT COALESCE(mc.name, '') FROM reward_fulfillments rf \
             LEFT JOIN marketing_campaigns mc ON rf.campaign_id = mc.id \
             WHERE rf.user_id = ?1 AND rf.party = 'inviter' AND rf.status = 'fulfilled' AND rf.order_id = ?2 \
             LIMIT 1",
            rusqlite::params![buyer_id, order_id],
            |row| row.get(0),
        ).unwrap_or_default();
        let display_name = if camp_name.is_empty() { "推荐活动" } else { &camp_name };
        let _ = crate::campaign_executor::write_notification(
            conn, &buyer_id, "reward_redeem",
            &format!("📉 折扣已使用"),
            &format!("你在本次支付中使用了邀请「{}」获得的折扣优惠！", display_name),
            None,
        );
        tracing::info!("distribute_commission_on_payment: redeemed inviter discount for {}, order={}", buyer_id, order_id);
    }

    Ok(())
}

/// AEAD_AES_256_GCM 解密
fn decrypt_aes_256_gcm(
    api_v3_key: &str,
    ciphertext: &str,
    nonce: &str,
    associated_data: &str,
) -> Result<String, String> {
    use aes_gcm::{Aes256Gcm, Key, Nonce};
    use aes_gcm::aead::{Aead, KeyInit, Payload};

    let key = Key::<Aes256Gcm>::from_slice(api_v3_key.as_bytes());
    let cipher = Aes256Gcm::new(key);

    let nonce_bytes = nonce.as_bytes();
    let nonce_arr: &[u8; 12] = &nonce_bytes[..12].try_into().map_err(|_| "nonce 长度错误")?;
    let nonce = Nonce::from_slice(nonce_arr);

    let cipher_bytes = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        ciphertext,
    )
    .map_err(|e| format!("base64 解码失败: {}", e))?;

    let payload = Payload {
        msg: &cipher_bytes,
        aad: associated_data.as_bytes(),
    };

    let plaintext = cipher
        .decrypt(nonce, payload)
        .map_err(|e| format!("AES 解密失败: {:?}", e))?;

    String::from_utf8(plaintext).map_err(|e| format!("UTF-8 转换失败: {}", e))
}

/// GET /api/pay/orders?user_id=xxx — 查询用户订单
pub async fn user_orders_handler(
    Query(query): Query<UserOrdersQuery>,
) -> impl IntoResponse {
    let user_id = match &query.user_id {
        Some(id) if !id.is_empty() => id.as_str(),
        _ => return (StatusCode::BAD_REQUEST, "user_id 不能为空").into_response(),
    };

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT po.id, po.plan_id, sp.name, po.amount, po.status, po.transaction_id, po.paid_at, po.created_at
         FROM payment_orders po
         LEFT JOIN subscription_plans sp ON po.plan_id = sp.id
         WHERE po.user_id = ?1
         ORDER BY po.created_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![user_id], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "plan_id": row.get::<_, String>(1)?,
            "plan_name": row.get::<_, Option<String>>(2)?,
            "amount": row.get::<_, i64>(3)?,
            "status": row.get::<_, String>(4)?,
            "transaction_id": row.get::<_, Option<String>>(5)?,
            "paid_at": row.get::<_, Option<String>>(6)?,
            "created_at": row.get::<_, String>(7)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    (StatusCode::OK, json!({"orders": rows}).to_string()).into_response()
}

/// GET /api/admin/pay/orders — 管理端查询全部订单（含用户信息）
pub async fn admin_orders_handler() -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT po.id, po.user_id, po.plan_id, sp.name, po.amount, po.status, po.transaction_id, po.paid_at, po.created_at
         FROM payment_orders po
         LEFT JOIN subscription_plans sp ON po.plan_id = sp.id
         ORDER BY po.created_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "user_id": row.get::<_, String>(1)?,
            "plan_id": row.get::<_, String>(2)?,
            "plan_name": row.get::<_, Option<String>>(3)?,
            "amount": row.get::<_, i64>(4)?,
            "status": row.get::<_, String>(5)?,
            "transaction_id": row.get::<_, Option<String>>(6)?,
            "paid_at": row.get::<_, Option<String>>(7)?,
            "created_at": row.get::<_, String>(8)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    (StatusCode::OK, json!({"orders": rows}).to_string()).into_response()
}

/// GET /api/pay/orders/{id} — 查询单笔订单状态
///
/// 如本地状态为 NOTPAY，会向微信查询实际支付状态并同步
pub async fn order_status_handler(
    Path(order_id): Path<String>,
) -> impl IntoResponse {
    let conn = crate::db_pool::get_conn();
    let order = conn.query_row(
        "SELECT id, user_id, plan_id, amount, status, transaction_id, paid_at, created_at
         FROM payment_orders WHERE id = ?1",
        rusqlite::params![order_id],
        |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "user_id": row.get::<_, String>(1)?,
                "plan_id": row.get::<_, String>(2)?,
                "amount": row.get::<_, i64>(3)?,
                "status": row.get::<_, String>(4)?,
                "transaction_id": row.get::<_, Option<String>>(5)?,
                "paid_at": row.get::<_, Option<String>>(6)?,
                "created_at": row.get::<_, String>(7)?,
            }))
        },
    );

    let mut order_json = match order {
        Ok(o) => o,
        Err(_) => return (StatusCode::NOT_FOUND, "订单不存在").into_response(),
    };

    // 如果订单是 NOTPAY，向微信查询实际状态
    let status = order_json["status"].as_str().unwrap_or("NOTPAY");
    if status == "NOTPAY" {
        if let Some(ref config) = crate::wechat_pay::WechatPayConfig::from_env() {
            match crate::wechat_pay::query_order_status(config, &order_id).await {
                Ok(wechat_status) => {
                    if wechat_status == "SUCCESS" {
                        // 微信已支付，同步更新本地（条件更新，防止竞态翻倍）
                        let paid_at = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let updated = conn.execute(
                            "UPDATE payment_orders SET status='SUCCESS', paid_at=?1 WHERE id=?2 AND status='NOTPAY'",
                            rusqlite::params![paid_at, order_id],
                        ).unwrap_or(0);
                        if updated == 0 {
                            // 另一个请求已处理，跳过
                            // 重新查最新状态
                            if let Ok(new_order) = conn.query_row(
                                "SELECT id, user_id, plan_id, amount, status, transaction_id, paid_at, created_at
                                 FROM payment_orders WHERE id = ?1",
                                rusqlite::params![order_id],
                                |row| {
                                    Ok(json!({
                                        "id": row.get::<_, String>(0)?,
                                        "user_id": row.get::<_, String>(1)?,
                                        "plan_id": row.get::<_, String>(2)?,
                                        "amount": row.get::<_, i64>(3)?,
                                        "status": row.get::<_, String>(4)?,
                                        "transaction_id": row.get::<_, Option<String>>(5)?,
                                        "paid_at": row.get::<_, Option<String>>(6)?,
                                        "created_at": row.get::<_, String>(7)?,
                                    }))
                                },
                            ) {
                                order_json = new_order;
                            }
                        } else {
                            order_json["status"] = json!("SUCCESS");
                            order_json["paid_at"] = json!(paid_at);

                            // 延期订阅（仅在本次成功更新时执行）
                            let user_id = order_json["user_id"].as_str().unwrap_or("");
                            let plan_id = order_json["plan_id"].as_str().unwrap_or("");
                            if !user_id.is_empty() && !plan_id.is_empty() {
                                let _ = subscription::extend_subscription(
                                    &conn, user_id, plan_id,
                                    None, Some(&order_id), Some("微信支付"),
                                );
                                // 分销归因：此分支为 order_status_handler 同步微信状态，
                                // 不会触发 pay_notify_handler，需手动分发佣金
                                let _ = distribute_commission_on_payment(&conn, &order_id);
                            }
                        }
                    } else if wechat_status == "CLOSED" || wechat_status == "REVOKED" {
                        let _ = conn.execute(
                            "UPDATE payment_orders SET status='CLOSED' WHERE id=?1 AND status='NOTPAY'",
                            rusqlite::params![order_id],
                        );
                        order_json["status"] = json!("CLOSED");
                    }
                }
                Err(e) => {
                    tracing::warn!("查询微信订单状态失败: {}", e);
                }
            }
        }
    }

    (StatusCode::OK, order_json.to_string()).into_response()
}
