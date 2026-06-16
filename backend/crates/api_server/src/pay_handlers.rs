//! 支付相关 Handler — 下单 / 回调 / 订单查询

use axum::{
    extract::Path,
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;

use crate::subscription;

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

    // 查套餐
    let conn = crate::db_pool::get_conn();
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

    // 生成订单号
    let now = chrono::Utc::now();
    let ts = now.timestamp();
    let order_id = format!("OE{}", ts);

    // 到期时间（下单后 10 分钟未支付自动关闭）
    let expire = (now + chrono::Duration::minutes(10)).format("%Y-%m-%dT%H:%M:%S+08:00").to_string();

    // 免费套餐（price=0）跳过微信支付，直接激活
    if plan.price <= 0 {
        let created_at = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        // 写订单（已支付）
        if let Err(e) = conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, paid_at, created_at)
             VALUES (?1, ?2, ?3, 0, 'SUCCESS', ?4, ?4)",
            rusqlite::params![order_id, user_id, plan_id, created_at],
        ) {
            return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入订单失败: {}", e)).into_response();
        }
        // 激活订阅
        match subscription::extend_subscription(
            &conn, &user_id, &plan_id, None, Some(&order_id), None,
        ) {
            Ok(new_expires) => {
                return (
                    StatusCode::OK,
                    json!({
                        "order_id": order_id,
                        "code_url": "",
                        "amount": 0,
                        "paid": true,
                        "new_expires": new_expires,
                    }).to_string(),
                ).into_response();
            }
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("激活订阅失败: {}", e)).into_response(),
        }
    }

    // 调微信下单（price > 0）
    let wechat_config = match crate::wechat_pay::WechatPayConfig::from_env() {
        Some(c) => c,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "微信支付未配置").into_response(),
    };

    match crate::wechat_pay::native_order(
        &wechat_config,
        &order_id,
        &format!("CoEvo {}", plan.name),
        plan.price,
        &expire,
    )
    .await
    {
        Ok(resp) => {
            // 写订单
            let created_at = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();
            if let Err(e) = conn.execute(
                "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, prepay_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, 'NOTPAY', ?5, ?6)",
                rusqlite::params![order_id, user_id, plan_id, plan.price, resp.prepay_id, created_at],
            ) {
                return (StatusCode::INTERNAL_SERVER_ERROR, format!("写入订单失败: {}", e)).into_response();
            }

            (
                StatusCode::OK,
                json!({
                    "order_id": order_id,
                    "code_url": resp.code_url,
                    "prepay_id": resp.prepay_id,
                    "amount": plan.price,
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
            (StatusCode::OK, json!({"code": "SUCCESS"}).to_string()).into_response()
        }
        Err(e) => {
            tracing::error!("pay_notify: 延期失败: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("延期失败: {}", e)).into_response()
        }
    }
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

/// GET /api/pay/orders — 查询用户订单
pub async fn user_orders_handler(
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let user_id = match payload.get("user_id").and_then(|v| v.as_str()) {
        Some(id) => id,
        None => return (StatusCode::BAD_REQUEST, "user_id 不能为空").into_response(),
    };

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT id, plan_id, amount, status, transaction_id, paid_at, created_at
         FROM payment_orders WHERE user_id = ?1 ORDER BY created_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("查询失败: {}", e)).into_response(),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![user_id], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "plan_id": row.get::<_, String>(1)?,
            "amount": row.get::<_, i64>(2)?,
            "status": row.get::<_, String>(3)?,
            "transaction_id": row.get::<_, Option<String>>(4)?,
            "paid_at": row.get::<_, Option<String>>(5)?,
            "created_at": row.get::<_, String>(6)?,
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
                        // 微信已支付，同步更新本地
                        let paid_at = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let _ = conn.execute(
                            "UPDATE payment_orders SET status='SUCCESS', paid_at=?1 WHERE id=?2 AND status='NOTPAY'",
                            rusqlite::params![paid_at, order_id],
                        );
                        order_json["status"] = json!("SUCCESS");
                        order_json["paid_at"] = json!(paid_at);

                        // 延期订阅
                        let user_id = order_json["user_id"].as_str().unwrap_or("");
                        let plan_id = order_json["plan_id"].as_str().unwrap_or("");
                        if !user_id.is_empty() && !plan_id.is_empty() {
                            let _ = subscription::extend_subscription(
                                &conn, user_id, plan_id,
                                None, Some(&order_id), Some("微信支付"),
                            );
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
