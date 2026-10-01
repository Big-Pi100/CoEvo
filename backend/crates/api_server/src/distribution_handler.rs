//! 佣金/提现/结算/通知 API — 真实业务逻辑
//!
//! 包括：通知、支付计算、结算批次、提现审核、团队管理、分销统计

use axum::response::IntoResponse;
use axum::{
    extract::{Multipart, Path, Query},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::admin_handlers::{err, mask_email, ok, verify_admin};
use encoding_rs::GBK;

// ── 公共余额计算函数 ──

/// 计算用户净可用佣金
/// 底层 SQL 来自 `v_user_available_balance` 视图，与 list_withdrawals 子查询同源
pub(crate) fn net_available_commission(conn: &rusqlite::Connection, user_id: &str) -> i64 {
    conn.query_row(
        "SELECT COALESCE(available_balance, 0) FROM v_user_available_balance WHERE earner_id = ?1",
        rusqlite::params![user_id],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

// ── 公共请求结构 ──

#[derive(Deserialize)]
pub struct UserQuery {
    pub user_id: String,
}

#[derive(Deserialize)]
pub struct ExportAllQuery {
    #[serde(default)]
    pub batch_no: Option<String>,
}

// ════════════════════════════════════════════════════════════════
// 用户端通知 API（4个）
// ════════════════════════════════════════════════════════════════

/// GET /api/notifications — 通知列表
pub async fn list_notifications(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("list_notifications: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();

    let mut stmt = match conn.prepare(
        "SELECT id, notification_type, title, body, read, action_url, created_at \
         FROM user_notifications WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 50",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let notifications: Vec<serde_json::Value> =
        match stmt.query_map(rusqlite::params![query.user_id], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "notification_type": row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                "title": row.get::<_, String>(2)?,
                "body": row.get::<_, Option<String>>(3)?,
                "read": row.get::<_, i32>(4)? != 0,
                "action_url": row.get::<_, Option<String>>(5)?,
                "created_at": row.get::<_, String>(6)?,
            }))
        }) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("query_error: {}", e),
                )
            }
        };

    let unread_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM user_notifications WHERE user_id = ?1 AND read = 0",
            rusqlite::params![query.user_id],
            |row| row.get(0),
        )
        .unwrap_or(0);

    ok(json!({"notifications": notifications, "unread_count": unread_count}))
}

/// POST /api/notifications/{id}/read — 标记已读
pub async fn mark_read(
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("mark_read: id={}, user_id={}", id, body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE user_notifications SET read = 1 WHERE id = ?1 AND user_id = ?2",
        rusqlite::params![id, body.user_id],
    ) {
        Ok(_) => ok(json!({"status": "ok"})),
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("db_error: {}", e),
        ),
    }
}

/// POST /api/notifications/read-all — 全部已读
pub async fn mark_read_all(headers: HeaderMap, Json(body): Json<UserQuery>) -> impl IntoResponse {
    tracing::info!("mark_read_all: user_id={}", body.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();
    match conn.execute(
        "UPDATE user_notifications SET read = 1 WHERE user_id = ?1 AND read = 0",
        rusqlite::params![body.user_id],
    ) {
        Ok(updated) => ok(json!({"status": "ok", "updated": updated})),
        Err(e) => err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("db_error: {}", e),
        ),
    }
}

// ════════════════════════════════════════════════════════════════
// 用户端支付计算（3个）
// ════════════════════════════════════════════════════════════════

/// GET /api/referral/user-campaign — 查询用户适用的有效活动（前端取 campaign_id）
pub async fn user_campaign(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("user_campaign: user_id={}", query.user_id);
    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return err(StatusCode::UNAUTHORIZED, &e.to_string());
    }

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT id, name, rewards FROM marketing_campaigns \
         WHERE status = 'active' \
         AND (valid_from IS NULL OR valid_from <= datetime('now')) \
         AND (valid_until IS NULL OR valid_until > datetime('now')) \
         ORDER BY valid_from DESC",
    ) {
        Ok(s) => s,
        Err(_) => return ok(json!({"campaign_id": null})),
    };

    let rows: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let name: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
        let rewards: String = row.get(2)?;
        Ok(json!({"id": id, "name": name, "rewards": rewards}))
    }) {
        Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
        Err(_) => vec![],
    };

    // 只返回包含 discount 类型的活动
    for campaign in &rows {
        if let Some(rewards_str) = campaign["rewards"].as_str() {
            if let Ok(rewards) = serde_json::from_str::<Vec<serde_json::Value>>(rewards_str) {
                if rewards.iter().any(|r| {
                    let rtype = r["type"].as_str().unwrap_or("");
                    rtype == "discount_pct" || rtype == "discount_fix"
                }) {
                    return ok(json!({
                        "campaign_id": campaign["id"],
                        "campaign_name": campaign["name"],
                    }));
                }
            }
        }
    }

    ok(json!({"campaign_id": null}))
}

#[derive(Deserialize)]
pub struct CalculateRequest {
    pub user_id: String,
    pub plan_id: String,
    #[serde(default)]
    pub campaign_id: Option<String>, // 可选：指定活动 ID，不传时自动查有效折扣活动
}

/// POST /api/pay/calculate — 计算折后价
pub async fn calculate(
    headers: HeaderMap,
    Json(body): Json<CalculateRequest>,
) -> impl IntoResponse {
    tracing::info!(
        "calculate: user_id={}, plan_id={}",
        body.user_id,
        body.plan_id
    );

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();

    // 1. 查用户的原价套餐
    let original_price: i64 = match conn.query_row(
        "SELECT price FROM subscription_plans WHERE id = ?1",
        rusqlite::params![body.plan_id],
        |row| row.get(0),
    ) {
        Ok(p) => p,
        Err(_) => return err(StatusCode::NOT_FOUND, "plan_not_found"),
    };

    // 2. 查指定活动是否有效
    let campaign: Result<(String, String), rusqlite::Error> = match body.campaign_id.as_ref() {
        Some(cid) if !cid.is_empty() => conn.query_row(
            "SELECT id, rewards FROM marketing_campaigns \
                 WHERE id = ?1 AND status = 'active' \
                 AND (valid_from IS NULL OR valid_from <= datetime('now')) \
                 AND (valid_until IS NULL OR valid_until > datetime('now'))",
            rusqlite::params![cid],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        ),
        _ => {
            // 未指定 campaign_id 时兜底：找第一个含 discount 的有效活动
            let stmt = conn.prepare(
                "SELECT id, rewards FROM marketing_campaigns \
                 WHERE status = 'active' \
                 AND (valid_from IS NULL OR valid_from <= datetime('now')) \
                 AND (valid_until IS NULL OR valid_until > datetime('now')) \
                 LIMIT 5",
            );
            match stmt {
                Ok(mut s) => {
                    let rows: Vec<(String, String)> = match s.query_map([], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                    }) {
                        Ok(mapped) => mapped
                            .filter_map(|r| r.ok())
                            .filter(|(_, r)| {
                                r.contains("discount_pct") || r.contains("discount_fix")
                            })
                            .collect(),
                        Err(_) => vec![],
                    };
                    match rows.into_iter().next() {
                        Some(c) => Ok(c),
                        None => Err(rusqlite::Error::QueryReturnedNoRows),
                    }
                }
                Err(_) => Err(rusqlite::Error::QueryReturnedNoRows),
            }
        }
    };

    let (campaign_id, rewards_str) = match campaign {
        Ok(c) => c,
        Err(_) => {
            return ok(json!({
                "original_price": original_price,
                "discounted_price": original_price,
                "campaign_id": null,
                "discount_note": "活动已过期或不存在",
            }))
        }
    };

    // 5. 检查折扣状态
    //    没有 fulfillment → 折扣从未发放（min_member_count 未达标等）→ 不显示
    //    status=granted → 已发放未使用 → 显示折扣
    //    status=fulfilled → 已使用 → 不显示
    let has_discount: bool = conn.query_row(
        "SELECT COUNT(*) FROM reward_fulfillments \
         WHERE campaign_id = ?1 AND user_id = ?2 AND reward_type IN ('discount_pct', 'discount_fix') AND status IN ('fulfilled', 'granted')",
        rusqlite::params![&campaign_id, &body.user_id],
        |row| row.get::<_, i64>(0),
    ).unwrap_or(0) > 0;
    let already_used: bool = conn.query_row(
        "SELECT COUNT(*) FROM reward_fulfillments \
         WHERE campaign_id = ?1 AND user_id = ?2 AND reward_type IN ('discount_pct', 'discount_fix') AND status = 'fulfilled'",
        rusqlite::params![&campaign_id, &body.user_id],
        |row| row.get::<_, i64>(0),
    ).unwrap_or(0) > 0;

    let mut discounted_price = original_price;
    let mut discount_note = String::new();

    if has_discount && !already_used {
        if let Ok(rewards) = serde_json::from_str::<Vec<serde_json::Value>>(&rewards_str) {
            for reward in &rewards {
                let rtype = reward["type"].as_str().unwrap_or("");
                let party = reward["party"].as_str().unwrap_or("");
                // self=触发者本人, inviter=邀请人, invitee=被邀请人, all=全体
                if party != "self" && party != "inviter" && party != "invitee" && party != "all" {
                    continue;
                }
                // 验证用户资格
                let eligible = match party {
                    "self" => {
                        // 触发者自己——只要在支付就符合资格
                        true
                    }
                    "inviter" => {
                        // 邀请人资格：有人通过此用户的推广码 AND 通过此活动注册
                        conn.query_row(
                        "SELECT COUNT(*) FROM users WHERE referred_by = ?1 AND referred_campaign_id = ?2",
                        rusqlite::params![&body.user_id, &campaign_id],
                        |row| row.get::<_, i64>(0),
                    ).unwrap_or(0) > 0
                    }
                    "invitee" => {
                        // 被邀请人资格：此用户是通过此活动被邀请的
                        conn.query_row(
                        "SELECT COUNT(*) FROM users WHERE id = ?1 AND referred_by IS NOT NULL AND referred_campaign_id = ?2",
                        rusqlite::params![&body.user_id, &campaign_id],
                        |row| row.get::<_, i64>(0),
                    ).unwrap_or(0) > 0
                    }
                    "all" => true,
                    _ => false,
                };
                if !eligible {
                    continue;
                }
                match rtype {
                    "discount_fix" => {
                        if let Some(val) = reward["value"].as_i64() {
                            discounted_price = (original_price - val).max(0);
                            discount_note = format!("推荐优惠: 减{}元", val);
                        }
                    }
                    "discount_pct" => {
                        if let Some(val) = reward["value"].as_f64() {
                            // value 如 0.85 = 85 折 (付85%)
                            let pct = val.clamp(0.0, 1.0);
                            discounted_price = (original_price as f64 * pct) as i64;
                            let zhe = (pct * 100.0) as i64;
                            discount_note = format!("推荐折扣: {}折", zhe);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    ok(json!({
        "original_price": original_price,
        "discounted_price": discounted_price,
        "campaign_id": campaign_id,
        "discount_note": discount_note,
    }))
}

// ════════════════════════════════════════════════════════════════
// 管理端结算 API（6个）
// ════════════════════════════════════════════════════════════════

/// GET /api/admin/settlement/pending-commissions — 待结算佣金列表
pub async fn pending_commissions(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("pending_commissions");

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT de.id, de.earner_id, COALESCE(u.display_name, u.username, u.id) AS earner_name,
                de.amount, de.expense_type, de.status, de.created_at,
                de.fee, de.actual_amount
         FROM distribution_expenses de
         JOIN users u ON u.id = de.earner_id
         WHERE de.expense_type = 'withdrawal'
           AND de.status = 'confirmed'
           AND (de.batch_no IS NULL OR de.batch_no = '')
         ORDER BY de.created_at ASC",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let items: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "earner_id": row.get::<_, String>(1)?,
            "earner_name": row.get::<_, String>(2)?,
            "amount": row.get::<_, i64>(3)?,
            "expense_type": row.get::<_, String>(4)?,
            "status": row.get::<_, String>(5)?,
            "created_at": row.get::<_, String>(6)?,
            "fee": row.get::<_, Option<i64>>(7)?,
            "actual_amount": row.get::<_, Option<i64>>(8)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("query_error: {}", e),
            )
        }
    };

    ok(json!({"commissions": items}))
}

/// GET /api/admin/settlement/batches — 批次列表
pub async fn list_batches(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("list_batches");

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT batch_no, COUNT(*) as item_count, SUM(amount) as total_amount, \
                status, MAX(batch_paid_at) as paid_at, MAX(created_at) as created_at \
         FROM distribution_expenses \
         WHERE batch_no IS NOT NULL AND batch_no != '' \
         GROUP BY batch_no ORDER BY created_at DESC",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let batches: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        Ok(json!({
            "batch_no": row.get::<_, String>(0)?,
            "item_count": row.get::<_, i64>(1)?,
            "total_amount": row.get::<_, i64>(2)?,
            "status": row.get::<_, String>(3)?,
            "paid_at": row.get::<_, Option<String>>(4)?,
            "created_at": row.get::<_, String>(5)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("query_error: {}", e),
            )
        }
    };

    ok(json!({"batches": batches}))
}

/// GET /api/admin/settlement/batches/{batch_no} — 批次详情
pub async fn get_batch(headers: HeaderMap, Path(batch_no): Path<String>) -> impl IntoResponse {
    tracing::info!("get_batch: batch_no={}", batch_no);

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    // 批次聚合信息
    let batch = match conn.query_row(
        "SELECT batch_no, COUNT(*) as item_count, SUM(amount) as total_amount, \
                status, MAX(batch_paid_at) as paid_at, MAX(created_at) as created_at \
         FROM distribution_expenses \
         WHERE batch_no = ?1 \
         GROUP BY batch_no",
        rusqlite::params![batch_no],
        |row| {
            Ok(json!({
                "batch_no": row.get::<_, String>(0)?,
                "item_count": row.get::<_, i64>(1)?,
                "total_amount": row.get::<_, i64>(2)?,
                "status": row.get::<_, String>(3)?,
                "paid_at": row.get::<_, Option<String>>(4)?,
                "created_at": row.get::<_, String>(5)?,
            }))
        },
    ) {
        Ok(b) => b,
        Err(_) => return err(StatusCode::NOT_FOUND, "batch_not_found"),
    };

    // 批次内明细（distribution_expenses 记录）
    let mut stmt = match conn.prepare(
        "SELECT de.id, de.earner_id, \
                COALESCE(u.display_name, u.username, u.id) AS earner_name, \
                u.username, u.email, \
                de.amount, de.expense_type, de.status, de.created_at, \
                de.fee, de.actual_amount \
         FROM distribution_expenses de \
         JOIN users u ON u.id = de.earner_id \
         WHERE de.batch_no = ?1 \
         ORDER BY de.created_at ASC",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let items: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![batch_no], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "earner_id": row.get::<_, String>(1)?,
            "earner_name": row.get::<_, String>(2)?,
            "username": row.get::<_, Option<String>>(3)?.unwrap_or_default(),
            // 🔴 2026-09-29：原为 `real_name`（脱敏）+ `real_name_full`（**明文**）+ `phone`。
            //    那两列已删 → 改展示 `email`（脱敏）。
            //    ⚠️ 顺带去掉 `*_full`：脱敏字段与明文字段同时下发，等于脱敏没做。
            "email": row.get::<_, Option<String>>(4)?.map(|e| mask_email(&e)),
            "amount": row.get::<_, i64>(5)?,
            "expense_type": row.get::<_, String>(6)?,
            "status": row.get::<_, String>(7)?,
            "created_at": row.get::<_, String>(8)?,
            "fee": row.get::<_, i64>(9)?,
            "actual_amount": row.get::<_, i64>(10)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("query_error: {}", e),
            )
        }
    };

    ok(json!({"batch": batch, "items": items}))
}

/// GET /api/admin/settlement/batches/{batch_no}/export — ZIP 导出（CSV + 付款凭证）
pub async fn export_batch(headers: HeaderMap, Path(batch_no): Path<String>) -> impl IntoResponse {
    tracing::info!("export_batch: batch_no={}", batch_no);

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT de.id, u.username, COALESCE(u.display_name, u.username) AS earner_name,                 u.email,                 de.amount, de.expense_type, de.status, de.fee, de.actual_amount, de.created_at, de.note          FROM distribution_expenses de          JOIN users u ON u.id = de.earner_id          WHERE de.batch_no = ?1          ORDER BY de.created_at ASC"
    ) {
        Ok(s) => s,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("db_error: {}", e)),
    };

    // 🔴 2026-09-29：「真实姓名 / 手机号」两列 → 合并为「邮箱」（实名与手机号已取消）。
    //    ⚠️ 导出的 CSV 是**明文**，所以这里也一并去掉了原 `real_name`/`phone` 的 AES 解密 ——
    //       邮箱直接导出即可（它是用户主动提供的登录标识，非身份信息）。
    let mut csv = String::from(
        "ID,用户名,推广名,邮箱,金额(分),类型,状态,手续费(分),到账金额(分),创建时间,备注,凭证路径\n",
    );
    let mut proof_files: Vec<(String, Vec<u8>)> = Vec::new();

    if let Ok(rows) = stmt.query_map(rusqlite::params![batch_no], |row| {
        let email: Option<String> = row.get(3)?;
        let note: Option<String> = row.get(10)?;
        let email = email.unwrap_or_default();
        let proof = note
            .as_ref()
            .and_then(|n| {
                let s = n.as_str();
                let pos = s.find("凭证: ");
                pos.and_then(|p| {
                    let after = &s[p + "凭证: ".len()..];
                    let start = after.chars().position(|c| c == '"')?;
                    let from = &after[start + 1..];
                    let end = from.chars().position(|c| c == '"')?;
                    Some(from[..end].to_string())
                })
            })
            .unwrap_or_default();
        let note_text = note.unwrap_or_default().replace('"', "\"\"");
        // Read proof image if exists
        if !proof.is_empty() {
            if let Ok(img_data) = std::fs::read(&proof) {
                let img_name = proof.rsplit('/').next().unwrap_or("proof.png").to_string();
                proof_files.push((img_name, img_data));
            }
        }
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            email,
            row.get::<_, i64>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, i64>(7)?,
            row.get::<_, i64>(8)?,
            row.get::<_, String>(9)?,
            note_text,
            proof,
        ))
    }) {
        for r in rows.flatten() {
            // 🔴 2026-09-29：列数 13 → 12（`real_name` + `phone` 合并为 `email`）。
            //    ⚠️ 占位符个数必须与元组字段数**同时**改 —— 只改一边会编译通过、运行时 panic。
            csv.push_str(&format!(
                "{},{},{},{},{},{},{},{},{},{},\"{}\",{},\n",
                r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7, r.8, r.9, r.10, r.11
            ));
        }
    }

    // Generate ZIP
    let mut zip_buf = std::io::Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(&mut zip_buf);

    // Add CSV
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    let (gbk_bytes, _, _) = GBK.encode(&csv);
    zip.start_file(format!("batch_{}.csv", batch_no), options)
        .unwrap();
    std::io::Write::write_all(&mut zip, &gbk_bytes).unwrap();

    // Add proof images
    for (name, data) in &proof_files {
        let img_path = format!("proofs/{}", name);
        zip.start_file(&img_path, options).unwrap();
        std::io::Write::write_all(&mut zip, data).unwrap();
    }

    zip.finish().unwrap();
    let zip_data = zip_buf.into_inner();

    (
        StatusCode::OK,
        [
            ("Content-Type", "application/zip"),
            (
                "Content-Disposition",
                &format!("attachment; filename*=UTF-8''batch_{}.zip", batch_no),
            ),
        ],
        zip_data,
    )
        .into_response()
}

/// GET /api/admin/settlement/batches/export-all — 导出所有批次为 ZIP
/// GET /api/admin/settlement/batches/export-all — 导出选中/全部批次为 ZIP（单 CSV + 凭证图片）
pub async fn export_all_batches(
    headers: HeaderMap,
    Query(query): Query<ExportAllQuery>,
) -> impl IntoResponse {
    tracing::info!("export_all_batches: batch_no={:?}", query.batch_no);

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    // 收集需要导出的 batch_no
    let batch_nos: Vec<String> = if let Some(ref selected) = query.batch_no {
        selected
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    } else {
        let list_stmt = conn.prepare(
            "SELECT batch_no FROM distribution_expenses WHERE batch_no IS NOT NULL AND batch_no != '' GROUP BY batch_no ORDER BY batch_no DESC"
        );
        match list_stmt {
            Ok(mut stmt) => match stmt.query_map([], |row| row.get::<_, String>(0)) {
                Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                Err(e) => {
                    return err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        &format!("query_error: {}", e),
                    )
                }
            },
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("db_error: {}", e),
                )
            }
        }
    };

    if batch_nos.is_empty() {
        return err(StatusCode::BAD_REQUEST, "没有可导出的批次");
    }

    // 单 CSV + 图片
    let mut csv = String::from("批次号,ID,用户名,推广名,邮箱,金额(分),类型,状态,手续费(分),到账金额(分),创建时间,备注,凭证路径
");
    let mut zip_buf = std::io::Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(&mut zip_buf);

    for batch_no in &batch_nos {
        let inner_stmt = conn.prepare(
            "SELECT de.id, u.username, COALESCE(u.display_name, u.username) AS earner_name,                     u.email,                     de.amount, de.expense_type, de.status, de.fee, de.actual_amount, de.created_at, de.note              FROM distribution_expenses de              JOIN users u ON u.id = de.earner_id              WHERE de.batch_no = ?1              ORDER BY de.created_at ASC"
        );
        let Ok(mut stmt) = inner_stmt else {
            continue;
        };

        if let Ok(rows) = stmt.query_map(rusqlite::params![batch_no], |row| {
            // 🔴 2026-09-29：`u.real_name, u.phone` → `u.email`（索引随列数变化整体前移）。
            let email: Option<String> = row.get(3)?;
            let note: Option<String> = row.get(10)?;
            let email = email.unwrap_or_default();
            let proof = note
                .as_ref()
                .and_then(|n| {
                    let s = n.as_str();
                    let pos = s.find("凭证: ");
                    pos.and_then(|p| {
                        let after = &s[p + "凭证: ".len()..];
                        let start = after.chars().position(|c| c == '"')?;
                        let from = &after[start + 1..];
                        let end = from.chars().position(|c| c == '"')?;
                        Some(from[..end].to_string())
                    })
                })
                .unwrap_or_default();
            let note_text = note.unwrap_or_default().replace('"', "\"\"");
            Ok((
                batch_no.clone(),
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                email,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, i64>(7)?,
                row.get::<_, i64>(8)?,
                row.get::<_, String>(9)?,
                note_text,
                proof,
            ))
        }) {
            let all: Vec<_> = rows.filter_map(|r| r.ok()).collect();
            for r in &all {
                if !r.12.is_empty() {
                    if let Ok(img_data) = std::fs::read(&r.12) {
                        let img_name =
                            format!("{}/{}", r.0, r.12.rsplit('/').next().unwrap_or("proof.png"));
                        let _ = zip.start_file(&img_name, options);
                        let _ = std::io::Write::write_all(&mut zip, &img_data);
                    }
                }
                // 🔴 2026-09-29：列数 14 → 13（`real_name` + `phone` → `email`）。
                csv.push_str(&format!(
                    "{},{},{},{},{},{},{},{},{},{},{},\"{}\",{}\n",
                    r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7, r.8, r.9, r.10, r.11, r.12
                ));
            }
        };
    }

    let csv_name = "settlement_records.csv";
    let (gbk_bytes, _, _) = GBK.encode(&csv);
    let _ = zip.start_file(csv_name, options);
    let _ = std::io::Write::write_all(&mut zip, &gbk_bytes);

    zip.finish().unwrap();
    let zip_data = zip_buf.into_inner();

    (
        StatusCode::OK,
        [
            ("Content-Type", "application/zip"),
            (
                "Content-Disposition",
                "attachment; filename*=UTF-8''settlement_export.zip",
            ),
        ],
        zip_data,
    )
        .into_response()
}

#[derive(Deserialize)]
pub struct MarkPaidRequest {
    pub note: Option<String>,
}

/// POST /api/admin/settlement/complete-payment — 上传凭证完成结算（生成批次号 + 标记已打款）
pub async fn mark_paid(headers: HeaderMap, mut multipart: Multipart) -> impl IntoResponse {
    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let mut note = format!("管理端标记已打款 (操作人: {})", admin_id);
    let mut proof_path: Option<String> = None;
    let mut expense_ids: Vec<String> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        match name.as_str() {
            "expense_ids" => {
                if let Ok(text) = field.text().await {
                    expense_ids = text
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                }
            }
            "image" => {
                let data = match field.bytes().await {
                    Ok(d) => d,
                    Err(_) => continue,
                };
                if data.is_empty() || data.len() > 10 * 1024 * 1024 {
                    return err(StatusCode::BAD_REQUEST, "图片大小不能超过 10MB");
                }
                if data.len() < 4 {
                    return err(StatusCode::BAD_REQUEST, "无效的图片文件");
                }
                let is_png =
                    data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47;
                let is_jpeg = data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF;
                if !is_png && !is_jpeg {
                    return err(StatusCode::BAD_REQUEST, "仅支持 PNG/JPEG 格式的图片");
                }
                let ext = if is_png { "png" } else { "jpg" };
                let dir = "data/payment_proofs";
                let _ = std::fs::create_dir_all(dir);
                let batch_tag = &format!("ST{}", chrono::Utc::now().format("%Y%m%d"));
                let filename = format!("{}/{}_{}.{}", dir, batch_tag, admin_id, ext);
                if let Err(e) = tokio::fs::write(&filename, &data).await {
                    return err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        &format!("保存图片失败: {}", e),
                    );
                }
                proof_path = Some(filename);
            }
            "note" => {
                if let Ok(text) = field.text().await {
                    if !text.trim().is_empty() {
                        note = format!("{} (备注: {})", note, text.trim());
                    }
                }
            }
            _ => {}
        }
    }

    if expense_ids.is_empty() {
        return err(StatusCode::BAD_REQUEST, "请指定要结算的提现记录");
    }
    if proof_path.is_none() {
        return err(StatusCode::BAD_REQUEST, "请上传打款凭证图片");
    }

    // 生成 batch_no
    let today = chrono::Utc::now().format("%Y%m%d").to_string();
    let batch_seq: i64 = conn
        .query_row(
            "SELECT COUNT(DISTINCT batch_no) FROM distribution_expenses WHERE batch_no LIKE ?1",
            rusqlite::params![format!("ST{}%", today)],
            |row| row.get(0),
        )
        .unwrap_or(0);
    let batch_no = format!("ST{}-{:04}", today, batch_seq + 1);

    let full_note = format!("{} | 凭证: {:?}", note, proof_path);

    // 构建 IN 占位符，从 ?5 开始（?1-?4 是 SET 字段）
    let set_count = 4;
    let placeholders: Vec<String> = expense_ids
        .iter()
        .enumerate()
        .map(|(i, _)| format!("?{}", i + 1 + set_count))
        .collect();
    let sql = format!(
        "UPDATE distribution_expenses SET status = 'paid', batch_no = ?1, batch_paid_at = ?2, handled_by = ?3, note = ?4 \
         WHERE id IN ({}) AND status = 'confirmed'",
        placeholders.join(",")
    );

    match conn.execute("BEGIN TRANSACTION", []) {
        Ok(_) => {}
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("tx_error: {}", e),
            )
        }
    }

    // 动态参数：batch_no + now + admin_id + full_note + 所有 expense_ids
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![
        Box::new(batch_no.clone()),
        Box::new(now.clone()),
        Box::new(admin_id.clone()),
        Box::new(full_note),
    ];
    for eid in &expense_ids {
        params.push(Box::new(eid.clone()));
    }
    let params_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    if let Err(e) = conn.execute(&sql, params_refs.as_slice()) {
        let _ = conn.execute("ROLLBACK", []);
        return err(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("update_expenses_error: {}", e),
        );
    }

    match conn.execute("COMMIT", []) {
        Ok(_) => ok(json!({"status": "paid", "batch_no": batch_no, "paid_at": now})),
        Err(e) => {
            let _ = conn.execute("ROLLBACK", []);
            err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("commit_error: {}", e),
            )
        }
    }
}
// ════════════════════════════════════════════════════════════════
// 待结算提现 CSV 导出
// ════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct PendingExportQuery {
    pub expense_ids: Option<String>,
}

/// GET /api/admin/settlement/pending-export — 导出待结算提现为 CSV（无图）
pub async fn export_pending_csv(
    headers: HeaderMap,
    Query(query): Query<PendingExportQuery>,
) -> impl IntoResponse {
    tracing::info!("export_pending_csv");

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let mut csv = String::from("ID,用户名,推广名,邮箱,金额(分),手续费(分),到账金额(分),创建时间\n");

    if let Some(ref ids_str) = query.expense_ids {
        // 导出选中的
        let ids: Vec<&str> = ids_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        if ids.is_empty() {
            return err(StatusCode::BAD_REQUEST, "expense_ids_empty");
        }
        let placeholders: Vec<String> = ids
            .iter()
            .enumerate()
            .map(|(i, _)| format!("?{}", i + 1))
            .collect();
        let sql = format!(
            "SELECT de.id, u.username, COALESCE(u.display_name, u.username) AS earner_name, \
                    u.email, \
                    de.amount, de.fee, de.actual_amount, de.created_at \
             FROM distribution_expenses de \
             JOIN users u ON u.id = de.earner_id \
             WHERE de.id IN ({}) AND de.expense_type = 'withdrawal' AND de.status = 'confirmed'",
            placeholders.join(",")
        );
        if let Ok(mut stmt) = conn.prepare(&sql) {
            let params: Vec<&dyn rusqlite::types::ToSql> = ids
                .iter()
                .map(|s| s as &dyn rusqlite::types::ToSql)
                .collect();
            if let Ok(rows) = stmt.query_map(params.as_slice(), |row| {
                // 🔴 2026-09-29：`real_name` + `phone` → `email`（索引整体前移 2→1 列）
                let email: Option<String> = row.get(3)?;
                let email = email.unwrap_or_default();
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    email,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                    row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                    row.get::<_, String>(7)?,
                ))
            }) {
                for r in rows.flatten() {
                    // 🔴 2026-09-29：列数 9 → 8（`real_name` + `phone` 两列合并为 `email` 一列）。
                    //    ⚠️ 这里**极易漏**：`format!` 占位符个数与元组字段数必须同时改 ——
                    //    只改元组不改 format（或反之）会编译通过、**运行时 panic**
                    //    （"N positional arguments but M were given"）。
                    csv.push_str(&format!(
                        "{},{},{},{},{},{},{},{}\n",
                        r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7
                    ));
                }
            }
        }
    } else {
        // 导出全部待结算
        if let Ok(mut stmt) = conn.prepare(
            "SELECT de.id, u.username, COALESCE(u.display_name, u.username) AS earner_name, \
                    u.email, \
                    de.amount, de.fee, de.actual_amount, de.created_at \
             FROM distribution_expenses de \
             JOIN users u ON u.id = de.earner_id \
             WHERE de.expense_type = 'withdrawal' AND de.status = 'confirmed' \
               AND (de.batch_no IS NULL OR de.batch_no = '') \
             ORDER BY de.created_at ASC",
        ) {
            if let Ok(rows) = stmt.query_map([], |row| {
                // 🔴 2026-09-29：同上（`real_name` + `phone` → `email`）
                let email: Option<String> = row.get(3)?;
                let email = email.unwrap_or_default();
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    email,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                    row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                    row.get::<_, String>(7)?,
                ))
            }) {
                for r in rows.flatten() {
                    // 🔴 2026-09-29：列数 9 → 8（`real_name` + `phone` 两列合并为 `email` 一列）。
                    //    ⚠️ 这里**极易漏**：`format!` 占位符个数与元组字段数必须同时改 ——
                    //    只改元组不改 format（或反之）会编译通过、**运行时 panic**
                    //    （"N positional arguments but M were given"）。
                    csv.push_str(&format!(
                        "{},{},{},{},{},{},{},{}\n",
                        r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7
                    ));
                }
            }
        }
    }

    let (gbk_bytes, _, _) = GBK.encode(&csv);
    let body: Vec<u8> = gbk_bytes.into();
    (
        StatusCode::OK,
        [
            ("Content-Type", "text/csv; charset=gbk"),
            (
                "Content-Disposition",
                "attachment; filename*=UTF-8''pending_withdrawals.csv",
            ),
        ],
        body,
    )
        .into_response()
}

// ════════════════════════════════════════════════════════════════
// 用户端提现 API（2个）
// ════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct WithdrawRequest {
    pub user_id: String,
    pub amount: i64, // 单位：分
}

/// POST /api/referral/withdraw — 用户发起提现
pub async fn user_withdraw(
    headers: HeaderMap,
    Json(body): Json<WithdrawRequest>,
) -> impl IntoResponse {
    tracing::info!(
        "user_withdraw: user_id={}, amount={}",
        body.user_id,
        body.amount
    );

    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    if body.amount <= 0 {
        return err(StatusCode::BAD_REQUEST, "amount_must_be_positive");
    }

    let conn = crate::db_pool::get_conn();

    // 1. 查用户可提现金额
    let available = net_available_commission(&conn, &body.user_id);

    if body.amount > available {
        return err(StatusCode::BAD_REQUEST, "余额不足");
    }

    // 2. 手续费计算：固定 1%，最低 1 元（100 分）
    let fee = (body.amount as f64 * 0.01).max(100.0) as i64;
    let actual_amount = body.amount - fee;

    // 3. 创建提现记录（distribution_expenses）
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    match conn.execute(
        "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, fee, actual_amount, created_at) \
         VALUES (?1, ?2, ?3, 'withdrawal', 'pending', ?4, ?5, ?6)",
        rusqlite::params![id, body.user_id, body.amount, fee, actual_amount, now],
    ) {
        Ok(_) => ok(json!({
            "id": id,
            "amount": body.amount,
            "fee": fee,
            "actual_amount": actual_amount,
            "status": "pending",
            "created_at": now,
        })),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &format!("insert_error: {}", e)),
    }
}

/// GET /api/referral/my-withdrawals — 用户查看自己的提现记录
pub async fn user_withdrawals(
    headers: HeaderMap,
    Query(query): Query<UserQuery>,
) -> impl IntoResponse {
    tracing::info!("user_withdrawals: user_id={}", query.user_id);

    if let Err(e) = crate::auth_middleware::verify_auth(&query.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    let conn = crate::db_pool::get_conn();

    let mut stmt = match conn.prepare(
        "SELECT id, amount, fee, actual_amount, status, note, created_at, handled_at \
         FROM distribution_expenses WHERE earner_id = ?1 AND expense_type = 'withdrawal' \
         ORDER BY created_at DESC LIMIT 20",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let withdrawals: Vec<serde_json::Value> =
        match stmt.query_map(rusqlite::params![query.user_id], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "amount": row.get::<_, i64>(1)?,
                "fee": row.get::<_, i64>(2)?,
                "actual_amount": row.get::<_, i64>(3)?,
                "status": row.get::<_, String>(4)?,
                "note": row.get::<_, Option<String>>(5)?,
                "created_at": row.get::<_, String>(6)?,
                "handled_at": row.get::<_, Option<String>>(7)?,
            }))
        }) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("query_error: {}", e),
                )
            }
        };

    ok(json!({"withdrawals": withdrawals}))
}

// ════════════════════════════════════════════════════════════════
// 管理端提现 API（3个）
// ════════════════════════════════════════════════════════════════

/// GET /api/admin/withdrawals — 待审核提现列表
pub async fn list_withdrawals(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("list_withdrawals");

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let mut stmt = match conn.prepare(
        "SELECT de.id, de.earner_id, \
                COALESCE(u.display_name, u.username) AS earner_name, \
                u.username, u.email, \
                de.amount AS apply_amount, de.status, de.note, \
                de.handled_by, de.handled_at, de.created_at, de.fee, de.actual_amount, \
                COALESCE((SELECT SUM(amount) FROM distribution_commissions WHERE earner_id = u.id AND status = 'locked'), 0) AS locked_amount, \
                COALESCE((SELECT available_balance FROM v_user_available_balance WHERE earner_id = u.id), 0) AS available_amount \
         FROM distribution_expenses de \
         JOIN users u ON u.id = de.earner_id \
         WHERE de.expense_type = 'withdrawal' AND de.status = 'pending' \
         ORDER BY de.created_at ASC"
    ) {
        Ok(s) => s,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("db_error: {}", e)),
    };

    let items: Vec<serde_json::Value> = match stmt.query_map([], |row| {
        Ok(json!({
            "id": row.get::<_, String>(0)?,
            "earner_id": row.get::<_, String>(1)?,
            "earner_name": row.get::<_, String>(2)?,
            "username": row.get::<_, Option<String>>(3)?.unwrap_or_default(),
            // 🔴 2026-09-29：原 `real_name`（脱敏）+ `real_name_full`（明文）+ `phone` → `email`（脱敏）
            "email": row.get::<_, Option<String>>(4)?.map(|e| mask_email(&e)),
            "apply_amount": row.get::<_, i64>(5)?,
            "status": row.get::<_, String>(6)?,
            "note": row.get::<_, Option<String>>(7)?,
            "handled_by": row.get::<_, Option<String>>(8)?,
            "handled_at": row.get::<_, Option<String>>(9)?,
            "created_at": row.get::<_, String>(10)?,
            "fee": row.get::<_, i64>(11)?,
            "actual_amount": row.get::<_, i64>(12)?,
            "locked_amount": row.get::<_, i64>(13)?,
            "available_amount": row.get::<_, i64>(14)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("query_error: {}", e),
            )
        }
    };

    ok(json!({"withdrawals": items}))
}

#[derive(Deserialize)]
pub struct RejectWithdrawalRequest {
    pub note: Option<String>,
}

/// POST /api/admin/withdrawals/{id}/approve — 审核通过（同时分配结算批次号）
pub async fn approve_withdrawal(headers: HeaderMap, Path(id): Path<String>) -> impl IntoResponse {
    tracing::info!("approve_withdrawal: id={}", id);

    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();

    // 查提现信息
    let (earner_id, amount, current_status): (String, i64, String) = match conn.query_row(
        "SELECT earner_id, amount, status FROM distribution_expenses WHERE id = ?1 AND expense_type = 'withdrawal'",
        rusqlite::params![id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    ) {
        Ok(d) => d,
        Err(_) => return err(StatusCode::NOT_FOUND, "withdrawal_not_found"),
    };

    if current_status != "pending" {
        return err(StatusCode::BAD_REQUEST, "withdrawal_already_processed");
    }

    match conn.execute("BEGIN TRANSACTION", []) {
        Ok(_) => {}
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("tx_error: {}", e),
            )
        }
    }

    // 1. UPDATE expense status → confirmed（不分配 batch_no，等管理员统一结算时再分配）
    if let Err(e) = conn.execute(
        "UPDATE distribution_expenses SET status = 'confirmed', handled_by = ?1, handled_at = ?2 WHERE id = ?3 AND status = 'pending'",
        rusqlite::params![admin_id, now, id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("update_expense_error: {}", e));
    }

    // 2. 通知用户提现审核通过
    let notif_id = uuid::Uuid::new_v4().to_string();
    let _ = conn.execute(
        "INSERT INTO user_notifications (id, user_id, notification_type, title, body, read, created_at) \
         VALUES (?1, ?2, 'withdrawal', '提现审核通过', ?3, 0, ?4)",
        rusqlite::params![notif_id, earner_id,
            format!("您的 {:.2} 元提现申请已通过审批，将尽快安排打款。", amount as f64 / 100.0),
            now],
    );

    match conn.execute("COMMIT", []) {
        Ok(_) => ok(json!({
            "status": "confirmed",
            "withdrawal_id": id,
        })),
        Err(e) => {
            let _ = conn.execute("ROLLBACK", []);
            err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("commit_error: {}", e),
            )
        }
    }
}

/// POST /api/admin/withdrawals/{id}/reject — 审核驳回
pub async fn reject_withdrawal(
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<RejectWithdrawalRequest>,
) -> impl IntoResponse {
    tracing::info!("reject_withdrawal: id={}", id);

    let (admin_id, _role) = match verify_admin(&headers) {
        Ok(r) => r,
        Err(e) => return e,
    };

    let conn = crate::db_pool::get_conn();
    let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
    let reason = body.note.clone().unwrap_or_else(|| "审核驳回".to_string());
    let full_note = format!("{} (操作人: {})", reason, admin_id);

    // 查 earner_id 用于发通知
    let earner_id: String = match conn.query_row(
        "SELECT earner_id FROM distribution_expenses WHERE id = ?1 AND expense_type = 'withdrawal'",
        rusqlite::params![id],
        |row| row.get(0),
    ) {
        Ok(eid) => eid,
        Err(_) => return err(StatusCode::NOT_FOUND, "withdrawal_not_found"),
    };

    match conn.execute("BEGIN TRANSACTION", []) {
        Ok(_) => {}
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("tx_error: {}", e),
            )
        }
    }

    // UPDATE expense status → cancelled
    if let Err(e) = conn.execute(
        "UPDATE distribution_expenses SET status = 'cancelled', note = ?1, handled_by = ?2, handled_at = ?3 WHERE id = ?4 AND status = 'pending'",
        rusqlite::params![full_note, admin_id, now, id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("update_expense_error: {}", e));
    }

    // 通知用户
    let notif_id = uuid::Uuid::new_v4().to_string();
    let _ = conn.execute(
        "INSERT INTO user_notifications (id, user_id, notification_type, title, body, read, created_at) \
         VALUES (?1, ?2, 'withdrawal', '提现审核未通过', ?3, 0, ?4)",
        rusqlite::params![notif_id, earner_id,
            format!("您的提现申请未通过审核。原因: {}", reason), now],
    );

    match conn.execute("COMMIT", []) {
        Ok(_) => ok(json!({"status": "rejected", "id": id})),
        Err(e) => {
            let _ = conn.execute("ROLLBACK", []);
            err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("commit_error: {}", e),
            )
        }
    }
}

// ════════════════════════════════════════════════════════════════
// 管理端团队 API（2个）
// ════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct TeamQuery {
    pub search: Option<String>,
}

/// GET /api/admin/team — 团队搜索
pub async fn admin_team(headers: HeaderMap, Query(query): Query<TeamQuery>) -> impl IntoResponse {
    tracing::info!("admin_team: search={:?}", query.search);

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    let items: Vec<serde_json::Value> = if let Some(ref search) = query.search {
        let pattern = format!("%{}%", search);
        let sql = "SELECT id, display_name, referral_code, created_at \
                   FROM users \
                   WHERE (display_name LIKE ?1 OR referral_code LIKE ?1) AND deleted_at IS NULL \
                   ORDER BY created_at DESC LIMIT 50";
        let mut stmt = match conn.prepare(sql) {
            Ok(s) => s,
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("db_error: {}", e),
                )
            }
        };
        let result: Vec<serde_json::Value> =
            match stmt.query_map(rusqlite::params![pattern], |row| {
                Ok(json!({
                    "id": row.get::<_, String>(0)?,
                    "display_name": row.get::<_, Option<String>>(1)?,
                    "referral_code": row.get::<_, String>(2)?,
                    "created_at": row.get::<_, String>(3)?,
                }))
            }) {
                Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
                Err(e) => {
                    return err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        &format!("query_error: {}", e),
                    )
                }
            };
        result
    } else {
        let sql = "SELECT id, display_name, referral_code, created_at \
                   FROM users WHERE deleted_at IS NULL \
                   ORDER BY created_at DESC LIMIT 50";
        let mut stmt = match conn.prepare(sql) {
            Ok(s) => s,
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("db_error: {}", e),
                )
            }
        };
        let result: Vec<serde_json::Value> = match stmt.query_map([], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "display_name": row.get::<_, Option<String>>(1)?,
                "referral_code": row.get::<_, String>(2)?,
                "created_at": row.get::<_, String>(3)?,
            }))
        }) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("query_error: {}", e),
                )
            }
        };
        result
    };

    ok(json!({"team": items}))
}

/// GET /api/admin/team/{user_id} — 用户详情 + 推广统计
pub async fn admin_team_user(headers: HeaderMap, Path(user_id): Path<String>) -> impl IntoResponse {
    tracing::info!("admin_team_user: user_id={}", user_id);

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    // 用户信息
    let user_info = match conn.query_row(
        "SELECT id, display_name, username, referral_code, created_at, streak_days \
         FROM users WHERE id = ?1 AND deleted_at IS NULL",
        rusqlite::params![user_id],
        |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "display_name": row.get::<_, Option<String>>(1)?,
                "username": row.get::<_, String>(2)?,
                "referral_code": row.get::<_, String>(3)?,
                "created_at": row.get::<_, String>(4)?,
                "streak_days": row.get::<_, i64>(5)?,
            }))
        },
    ) {
        Ok(u) => u,
        Err(_) => return err(StatusCode::NOT_FOUND, "user_not_found"),
    };

    // 推广统计
    let total_clicks: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM referral_clicks WHERE referrer_id = ?1",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let total_referrals: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE referred_by = ?1 AND deleted_at IS NULL",
            rusqlite::params![user_id],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let total_commission: i64 = conn.query_row(
        "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE earner_id = ?1 AND status NOT IN ('cancelled')",
        rusqlite::params![user_id], |row| row.get(0),
    ).unwrap_or(0);

    // 最新 10 次点击
    let mut stmt = match conn.prepare(
        "SELECT id, campaign_id, clicker_anonymous_id, share_channel, landed_page, created_at \
         FROM referral_clicks WHERE referrer_id = ?1 \
         ORDER BY created_at DESC LIMIT 10",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_error: {}", e),
            )
        }
    };

    let recent_clicks: Vec<serde_json::Value> =
        match stmt.query_map(rusqlite::params![user_id], |row| {
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "campaign_id": row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                "clicker_anonymous_id": row.get::<_, Option<String>>(2)?,
                "share_channel": row.get::<_, Option<String>>(3)?,
                "landed_page": row.get::<_, Option<String>>(4)?,
                "created_at": row.get::<_, String>(5)?,
            }))
        }) {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                return err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    &format!("query_error: {}", e),
                )
            }
        };

    ok(json!({
        "user": user_info,
        "stats": {
            "total_clicks": total_clicks,
            "total_referrals": total_referrals,
            "total_commission": total_commission,
        },
        "recent_clicks": recent_clicks,
    }))
}

// ════════════════════════════════════════════════════════════════
// 管理端统计 API（2个）
// ════════════════════════════════════════════════════════════════

/// GET /api/admin/distribution/stats — 总览指标
pub async fn admin_stats(headers: HeaderMap) -> impl IntoResponse {
    tracing::info!("admin_stats");

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    let total_campaigns: i64 = conn
        .query_row("SELECT COUNT(*) FROM marketing_campaigns", [], |row| {
            row.get(0)
        })
        .unwrap_or(0);

    let active_campaigns: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM marketing_campaigns WHERE status = 'active'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let total_clicks: i64 = conn
        .query_row("SELECT COUNT(*) FROM referral_clicks", [], |row| row.get(0))
        .unwrap_or(0);

    let total_registrations: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE referred_by IS NOT NULL AND deleted_at IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let pending_commissions_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM distribution_commissions WHERE status = 'available'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    let pending_commissions_amount: i64 = conn.query_row(
        "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE status = 'available'",
        [], |row| row.get(0),
    ).unwrap_or(0);

    let pending_withdrawals_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM distribution_expenses WHERE status = 'pending' AND expense_type = 'withdrawal'",
        [], |row| row.get(0),
    ).unwrap_or(0);

    let pending_withdrawals_amount: i64 = conn.query_row(
        "SELECT COALESCE(SUM(amount), 0) FROM distribution_expenses WHERE status = 'pending' AND expense_type = 'withdrawal'",
        [], |row| row.get(0),
    ).unwrap_or(0);

    let total_paid: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE status = 'paid'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    ok(json!({
        "total_campaigns": total_campaigns,
        "active_campaigns": active_campaigns,
        "total_clicks": total_clicks,
        "total_registrations": total_registrations,
        "pending_commissions_count": pending_commissions_count,
        "pending_commissions_amount": pending_commissions_amount,
        "pending_withdrawals_count": pending_withdrawals_count,
        "pending_withdrawals_amount": pending_withdrawals_amount,
        "total_paid": total_paid,
    }))
}

#[derive(Deserialize)]
pub struct FunnelQuery {
    pub campaign_id: Option<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
}

/// GET /api/admin/distribution/funnel — 漏斗数据
pub async fn admin_funnel(
    headers: HeaderMap,
    Query(query): Query<FunnelQuery>,
) -> impl IntoResponse {
    tracing::info!(
        "admin_funnel: campaign={:?}, from={:?}, to={:?}",
        query.campaign_id,
        query.date_from,
        query.date_to
    );

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    // 构建过滤条件
    let mut filters: Vec<String> = Vec::new();
    if let Some(ref cid) = query.campaign_id {
        filters.push(format!("campaign_id = '{}'", cid.replace('\'', "''")));
    }
    if let Some(ref dt_from) = query.date_from {
        filters.push(format!("created_at >= '{}'", dt_from.replace('\'', "''")));
    }
    if let Some(ref dt_to) = query.date_to {
        filters.push(format!("created_at <= '{}'", dt_to.replace('\'', "''")));
    }
    let where_clause = if filters.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", filters.join(" AND "))
    };

    // 点击数
    let clicks: i64 = conn
        .query_row(
            &format!("SELECT COUNT(*) FROM referral_clicks {}", where_clause),
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 注册数（通过 referred_by 关联到点击）
    let registrations: i64 = conn
        .query_row(
            &format!(
                "SELECT COUNT(DISTINCT u.id) FROM users u \
             JOIN referral_clicks rc ON u.referred_by = rc.referrer_id \
             {} AND u.deleted_at IS NULL",
                where_clause
            ),
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 支付数
    let payments: i64 = conn
        .query_row(
            "SELECT COUNT(DISTINCT po.id) FROM payment_orders po \
             JOIN users u ON po.user_id = u.id \
             WHERE po.status = 'SUCCESS' AND u.referred_by IS NOT NULL \
             AND u.referred_by != '' AND u.deleted_at IS NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 佣金总额
    let commission_amount: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(dc.amount), 0) FROM distribution_commissions dc \
             WHERE dc.status NOT IN ('cancelled')",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    ok(json!({
        "clicks": clicks,
        "registrations": registrations,
        "payments": payments,
        "commission_amount": commission_amount,
    }))
}

// ════════════════════════════════════════════════════════════════
// 退款 API（2个）
// ════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct AdminRefundRequest {
    pub reason: Option<String>,
}

/// 管理员退款的**结果**。
#[derive(Debug, PartialEq, Eq)]
pub enum AdminRefundOutcome {
    /// 订单**不存在**，**或状态不是 `SUCCESS`** → 404。
    ///
    /// 🔑 这两种情况在这里**合并为一**，因为原始查询就是
    ///    `WHERE id = ?1 AND status = 'SUCCESS'` —— 一次查询分不出是哪一种。
    ///    ⚠️ 与 [`RefundOutcome::OrderNotFound`] 不同：`webhook_refund` 查订单**不带状态**，
    ///    所以那边能分开（「非 SUCCESS」表现为「进事务后被守卫挡住」而非 404）。
    ///    这是两个入口**各自既有**的语义差异，抽取时**原样保留**、不做「顺手统一」。
    NotFoundOrNotPaid,
    /// 事务已提交。计数用于**响应体**与日志。
    Applied {
        cancelled_commissions: i64,
        cancelled_rewards: i64,
    },
}

/// 管理员退款的**核心副作用**（纯 DB 操作 · **不碰全局连接池** → 可独立测试）。
///
/// # 🔑 为什么把它从 handler 里抽出来
/// 与 [`apply_refund`] 同一个理由：`admin_refund` 用 `db_pool::get_conn()`（全局池），
/// 而测试用各自的 `setup_db()` 连接（刻意避开全局池）。
/// 🔴 此前它的测试 `test_admin_refund_cancels_commissions` 是**把这里的 SQL 抄进测试里跑**
///    （注释写着「因为 handler 需 admin 认证」）→ 它断言的是「**SQL 抄本**会怎样」，
///    而 `admin_refund` 本身改坏/删掉**都不会让那个测试变红**。
///    📌 这是比 `assert!(true)` **更隐蔽**的假绿：有真断言、真数据、真会失败 ——
///       但**失败原因永远与被测对象无关**。
///
/// # 行为（与抽取前的 handler 内联代码**逐字对应**）
/// 1. 查订单（**带 `AND status = 'SUCCESS'`**）→ 不满足即 `NotFoundOrNotPaid`（不改任何表）
/// 2. `BEGIN` → 三步 UPDATE → `COMMIT`；任一步失败 → `ROLLBACK` + `Err`
/// 3. 错误串**保留原前缀**（`tx_error:` / `update_order_error:` / …）→ handler 直接作为 500 响应体
pub fn apply_admin_refund(
    conn: &rusqlite::Connection,
    order_id: &str,
    reason: &str,
) -> Result<AdminRefundOutcome, String> {
    // 1. 查 payment_orders WHERE id = ?1 AND status = 'SUCCESS'
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM payment_orders WHERE id = ?1 AND status = 'SUCCESS'",
            rusqlite::params![order_id],
            |row| row.get(0),
        )
        .unwrap_or(false);

    if !exists {
        return Ok(AdminRefundOutcome::NotFoundOrNotPaid);
    }

    // 2. BEGIN TRANSACTION
    //    ⚠️ 这一句失败时**不做 ROLLBACK** —— BEGIN 没成功就没有事务在跑，回滚无意义。
    //       （与抽取前的写法一致。）
    if let Err(e) = conn.execute("BEGIN TRANSACTION", []) {
        return Err(format!("tx_error: {}", e));
    }

    // a. 订单 → REFUND + 写 refund_reason
    if let Err(e) = conn.execute(
        "UPDATE payment_orders SET status = 'REFUND', refund_reason = ?1 WHERE id = ?2 AND status = 'SUCCESS'",
        rusqlite::params![reason, order_id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("update_order_error: {}", e));
    }

    // b. 佣金 locked → cancelled（**统计影响行数**，供响应体用）
    let cancelled_commissions = match conn.execute(
        "UPDATE distribution_commissions SET status = 'cancelled' WHERE order_id = ?1 AND status = 'locked'",
        rusqlite::params![order_id],
    ) {
        Ok(n) => n as i64,
        Err(e) => {
            let _ = conn.execute("ROLLBACK", []);
            return Err(format!("update_commissions_error: {}", e));
        }
    };

    // c. 奖励 fulfilled → cancelled（同样统计）
    let cancelled_rewards = match conn.execute(
        "UPDATE reward_fulfillments SET status = 'cancelled' WHERE order_id = ?1 AND status = 'fulfilled'",
        rusqlite::params![order_id],
    ) {
        Ok(n) => n as i64,
        Err(e) => {
            let _ = conn.execute("ROLLBACK", []);
            return Err(format!("update_rewards_error: {}", e));
        }
    };

    // 3. COMMIT
    if let Err(e) = conn.execute("COMMIT", []) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("commit_error: {}", e));
    }

    Ok(AdminRefundOutcome::Applied {
        cancelled_commissions,
        cancelled_rewards,
    })
}

/// POST /api/admin/refund/{order_id} — 管理员退款操作
///
/// 认证后把脏活交给 [`apply_admin_refund`]（抽出去才测得了，见那里的说明）。
pub async fn admin_refund(
    headers: HeaderMap,
    Path(order_id): Path<String>,
    Json(body): Json<AdminRefundRequest>,
) -> impl IntoResponse {
    tracing::info!(
        "admin_refund: order_id={}, reason={:?}",
        order_id,
        body.reason
    );

    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();
    let reason = body.reason.unwrap_or_else(|| "管理员退款".to_string());

    match apply_admin_refund(&conn, &order_id, &reason) {
        Ok(AdminRefundOutcome::NotFoundOrNotPaid) => {
            err(StatusCode::NOT_FOUND, "order_not_found_or_not_paid")
        }
        Ok(AdminRefundOutcome::Applied {
            cancelled_commissions,
            cancelled_rewards,
        }) => {
            // ⚠️ 与原实现的一处**等价差异**：原先在「取消佣金后」「取消奖励后」各打一条日志，
            //    这里改成成功后打**一条**（信息量相同：两个计数都在）。
            //    原因：纯函数是原子的（要么全成、要么回滚）→ 中间态的日志已无对应的事件。
            tracing::info!(
                "admin_refund: cancelled {} commissions, {} rewards for order_id={}",
                cancelled_commissions,
                cancelled_rewards,
                order_id
            );
            ok(json!({
                "order_id": order_id,
                "cancelled_commissions": cancelled_commissions,
                "cancelled_rewards": cancelled_rewards,
            }))
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

#[derive(Deserialize)]
pub struct WebhookRefundRequest {
    pub order_id: String,
    pub refund_id: Option<String>,
    pub status: Option<String>,
}

/// 退款处理的**结果**（供测试断言用）。
///
/// 🔑 HTTP 层**不用**它 —— 微信要求回调**恒返 200**（见 [`webhook_refund`]）。
///    返回 `Result` 的唯一目的是让**测试**能区分「做成了」「无事可做」「出错了」。
#[derive(Debug, PartialEq, Eq)]
pub enum RefundOutcome {
    /// 订单不存在 → 无事可做。
    /// ⚠️ 这**不是错误**：微信会重复投递，也可能投递已被清理的订单。
    OrderNotFound,
    /// 事务已提交，三张表都已更新。
    Applied,
}

/// 退款回调的**核心副作用**（纯 DB 操作 · **不碰全局连接池** → 可独立测试）。
///
/// # 🔑 为什么把它从 handler 里抽出来
/// `webhook_refund` 用的是 `db_pool::get_conn()`（**全局池**），
/// 而本文件其余测试都用各自的 `setup_db()` 连接（**刻意避开全局池**，防测试间互相干扰）
/// → 那条路径**此前测不了**，只能放一个 `assert!(true, ...)` 充数（假绿）。
/// 抽成接受 `&Connection` 的纯函数后，测试就能用 `setup_db()` 对它下真断言。
/// 📌 同族：「**核心业务逻辑要可独立验证**」。
///
/// # 行为（与抽取前 `webhook_refund` 内的代码**逐字对应**）
/// 1. 订单不存在 → `Ok(OrderNotFound)`，**不改任何表**
/// 2. 存在 → `BEGIN` → 三步 UPDATE → `COMMIT`；任一步失败 → `ROLLBACK` + `Err`
/// 3. 🔴 三步 UPDATE 都带 `AND status = '<期望值>'` —— 非 SUCCESS 的订单**不会**被改成 REFUND
pub fn apply_refund(
    conn: &rusqlite::Connection,
    order_id: &str,
    refund_id: Option<&str>,
) -> Result<RefundOutcome, String> {
    // 1. 查 payment_orders WHERE id = ?1
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) > 0 FROM payment_orders WHERE id = ?1",
            rusqlite::params![order_id],
            |row| row.get(0),
        )
        .unwrap_or(false);

    if !exists {
        return Ok(RefundOutcome::OrderNotFound);
    }

    // 2. BEGIN TRANSACTION
    conn.execute("BEGIN TRANSACTION", [])
        .map_err(|e| format!("tx_error: {}", e))?;

    // a. 订单 → REFUND（**仅当当前是 SUCCESS**）
    if let Err(e) = conn.execute(
        "UPDATE payment_orders SET status = 'REFUND', refund_id = ?1 WHERE id = ?2 AND status = 'SUCCESS'",
        rusqlite::params![refund_id, order_id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("update_order_error: {}", e));
    }

    // b. 佣金 locked → cancelled
    if let Err(e) = conn.execute(
        "UPDATE distribution_commissions SET status = 'cancelled' WHERE order_id = ?1 AND status = 'locked'",
        rusqlite::params![order_id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("update_commissions_error: {}", e));
    }

    // c. 奖励 fulfilled → cancelled
    if let Err(e) = conn.execute(
        "UPDATE reward_fulfillments SET status = 'cancelled' WHERE order_id = ?1 AND status = 'fulfilled'",
        rusqlite::params![order_id],
    ) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("update_rewards_error: {}", e));
    }

    // 3. COMMIT
    if let Err(e) = conn.execute("COMMIT", []) {
        let _ = conn.execute("ROLLBACK", []);
        return Err(format!("commit_error: {}", e));
    }

    Ok(RefundOutcome::Applied)
}

/// POST /api/webhook/refund — 微信退款回调
///
/// 🔴 **无论处理结果如何都必须返回 HTTP 200** —— 否则微信会持续重试。
///    所以本 handler **刻意不把错误映射成 HTTP 错误码**，只记日志。
///    真正的逻辑在 [`apply_refund`]（抽出去才测得了，见那里的说明）。
pub async fn webhook_refund(Json(body): Json<WebhookRefundRequest>) -> impl IntoResponse {
    tracing::info!(
        "webhook_refund: order_id={}, refund_id={:?}, status={:?}",
        body.order_id,
        body.refund_id,
        body.status
    );

    let conn = crate::db_pool::get_conn();
    match apply_refund(&conn, &body.order_id, body.refund_id.as_deref()) {
        Ok(RefundOutcome::OrderNotFound) => {
            tracing::info!("webhook_refund: 订单不存在，无事可做: {}", body.order_id);
        }
        Ok(RefundOutcome::Applied) => {
            tracing::info!("webhook_refund: 退款处理完成: {}", body.order_id);
        }
        Err(e) => {
            tracing::error!("webhook_refund: {}", e);
        }
    }

    // 🔴 恒返 200（微信要求，见函数文档）
    (
        StatusCode::OK,
        Json(json!({"code": "SUCCESS", "message": "ok"})),
    )
        .into_response()
}

// ════════════════════════════════════════════════════════════════
// 管理端数据汇总/排行/导出 API（4个）
// ════════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct MonthlyStatsQuery {
    pub year: Option<String>,
}

#[derive(Deserialize)]
pub struct RankingQuery {
    pub limit: Option<i64>,
}

#[derive(Deserialize)]
pub struct ExportQuery {
    pub status: Option<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
    pub user_id: Option<String>,
}

/// GET /api/admin/distribution/summary — 数据总览
pub async fn admin_summary(headers: HeaderMap) -> impl IntoResponse {
    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    // locked
    let (locked_count, locked_amount): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE status='locked'",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((0, 0));

    // available
    let (avail_count, avail_amount): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM distribution_commissions WHERE status='available'",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((0, 0));

    // paid（查 distribution_expenses 的已打款记录）
    let (paid_count, paid_amount): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM distribution_expenses WHERE status='paid'",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((0, 0));

    // 用于订阅抵扣的佣金（从 expense 表追溯，不修改 commission 记录）
    let (subscription_count, subscription_amount): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM distribution_expenses WHERE expense_type='subscription' AND status='confirmed'",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap_or((0, 0));

    // active campaigns
    let active_campaigns: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM marketing_campaigns WHERE status='active'",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // total clicks
    let total_clicks: i64 = conn
        .query_row("SELECT COUNT(*) FROM referral_clicks", [], |row| row.get(0))
        .unwrap_or(0);

    // total referrals
    let total_referrals: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM users WHERE referred_by IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    ok(json!({
        "locked_commissions": {
            "count": locked_count,
            "total_amount": locked_amount,
        },
        "available_commissions": {
            "count": avail_count,
            "total_amount": avail_amount,
        },
        "paid_commissions": {
            "count": paid_count,
            "total_amount": paid_amount,
        },
        "subscription_usage": {
            "count": subscription_count,
            "total_amount": subscription_amount,
        },
        "active_campaigns": active_campaigns,
        "total_clicks": total_clicks,
        "total_referrals": total_referrals,
    }))
}

/// GET /api/admin/distribution/monthly-stats — 按月统计
pub async fn admin_monthly_stats(
    headers: HeaderMap,
    Query(query): Query<MonthlyStatsQuery>,
) -> impl IntoResponse {
    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let year = query
        .year
        .unwrap_or_else(|| chrono::Utc::now().format("%Y").to_string());

    let conn = crate::db_pool::get_conn();

    let mut stmt = match conn.prepare(
        "SELECT strftime('%Y-%m', created_at) as month, \
                COUNT(*) as commission_count, \
                COALESCE(SUM(amount), 0) as commission_amount \
         FROM distribution_commissions \
         WHERE strftime('%Y', created_at) = ?1 \
         GROUP BY month ORDER BY month",
    ) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_prepare: {}", e),
            )
        }
    };

    let mut months: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![year], |row| {
        Ok(json!({
            "month": row.get::<_, String>(0)?,
            "commission_count": row.get::<_, i64>(1)?,
            "commission_amount": row.get::<_, i64>(2)?,
            "paid_count": 0,
            "paid_amount": 0,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_query: {}", e),
            )
        }
    };

    // 补充已打款数据（从 distribution_expenses）
    if let Ok(mut stmt2) = conn.prepare(
        "SELECT strftime('%Y-%m', batch_paid_at) as month, \
                COUNT(*) as paid_count, \
                COALESCE(SUM(amount), 0) as paid_amount \
         FROM distribution_expenses \
         WHERE status='paid' AND batch_paid_at IS NOT NULL AND strftime('%Y', batch_paid_at) = ?1 \
         GROUP BY month ORDER BY month",
    ) {
        if let Ok(rows) = stmt2.query_map(rusqlite::params![year], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
            ))
        }) {
            for r in rows.flatten() {
                if let Some(m) = months.iter_mut().find(|m| m["month"] == r.0) {
                    m["paid_count"] = json!(r.1);
                    m["paid_amount"] = json!(r.2);
                } else {
                    // 有打款但本月无佣金记录（极少数情况）
                    months.push(json!({
                        "month": r.0,
                        "commission_count": 0,
                        "commission_amount": 0,
                        "paid_count": r.1,
                        "paid_amount": r.2,
                    }));
                }
            }
        }
    }

    ok(json!({ "months": months }))
}

/// GET /api/admin/distribution/ranking — 分销员排行
pub async fn admin_ranking(
    headers: HeaderMap,
    Query(query): Query<RankingQuery>,
) -> impl IntoResponse {
    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let limit = query.limit.unwrap_or(20);

    let conn = crate::db_pool::get_conn();

    let mut stmt = match conn.prepare(
        "SELECT u.id, u.display_name, u.referral_code, \
                COUNT(DISTINCT rc.id) as click_count, \
                COUNT(DISTINCT u2.id) as referral_count, \
                COALESCE(SUM(dc.amount), 0) as total_commission \
         FROM users u \
         LEFT JOIN referral_clicks rc ON rc.referrer_id = u.id \
         LEFT JOIN users u2 ON u2.referred_by = u.id \
         LEFT JOIN distribution_commissions dc ON dc.earner_id = u.id AND dc.status NOT IN ('cancelled') \
         WHERE u.referral_code IS NOT NULL \
         GROUP BY u.id ORDER BY total_commission DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => return err(StatusCode::INTERNAL_SERVER_ERROR, &format!("db_prepare: {}", e)),
    };

    let ranking: Vec<serde_json::Value> = match stmt.query_map(rusqlite::params![limit], |row| {
        Ok(json!({
            "user_id": row.get::<_, String>(0)?,
            "display_name": row.get::<_, Option<String>>(1)?,
            "referral_code": row.get::<_, Option<String>>(2)?,
            "click_count": row.get::<_, i64>(3)?,
            "referral_count": row.get::<_, i64>(4)?,
            "total_commission": row.get::<_, i64>(5)?,
        }))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_query: {}", e),
            )
        }
    };

    ok(json!({ "ranking": ranking }))
}

/// GET /api/admin/distribution/export — 导出佣金数据（CSV）
pub async fn admin_export(
    headers: HeaderMap,
    Query(query): Query<ExportQuery>,
) -> impl IntoResponse {
    if let Err(e) = verify_admin(&headers) {
        return e;
    }

    let conn = crate::db_pool::get_conn();

    let mut sql = String::from(
        "SELECT dc.id, dc.earner_id, COALESCE(u.display_name, ''), COALESCE(u.referral_code, ''), \
                dc.amount, dc.status, dc.created_at, COALESCE(dc.paid_at, ''), \
                COALESCE(po.plan_id, ''), COALESCE(po.amount, 0) \
         FROM distribution_commissions dc \
         JOIN users u ON u.id = dc.earner_id \
         JOIN payment_orders po ON po.id = dc.order_id \
         WHERE 1=1",
    );

    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(ref status) = query.status {
        sql.push_str(" AND dc.status = ?");
        params.push(Box::new(status.clone()));
    }
    if let Some(ref date_from) = query.date_from {
        sql.push_str(" AND dc.created_at >= ?");
        params.push(Box::new(date_from.clone()));
    }
    if let Some(ref date_to) = query.date_to {
        sql.push_str(" AND dc.created_at <= ?");
        params.push(Box::new(date_to.clone()));
    }
    if let Some(ref user_id) = query.user_id {
        sql.push_str(" AND dc.earner_id = ?");
        params.push(Box::new(user_id.clone()));
    }

    sql.push_str(" ORDER BY dc.created_at DESC");

    let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_prepare: {}", e),
            )
        }
    };

    let rows = match stmt.query_map(param_refs.as_slice(), |row| {
        Ok((
            row.get::<_, String>(0)?,                             // id
            row.get::<_, Option<String>>(1)?.unwrap_or_default(), // earner_id
            row.get::<_, String>(2)?,                             // display_name
            row.get::<_, String>(3)?,                             // referral_code
            row.get::<_, i64>(4)?,                                // amount
            row.get::<_, String>(5)?,                             // status
            row.get::<_, String>(6)?,                             // created_at
            row.get::<_, String>(7)?,                             // paid_at
            row.get::<_, String>(8)?,                             // plan_id
            row.get::<_, i64>(9)?,                                // order_amount
        ))
    }) {
        Ok(rows) => rows.filter_map(|r| r.ok()).collect::<Vec<_>>(),
        Err(e) => {
            return err(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("db_query: {}", e),
            )
        }
    };

    // 构建 CSV 字符串
    let mut csv = String::from(
        "ID,收益人ID,收益人姓名,推广码,佣金金额(分),状态,创建时间,支付时间,套餐ID,订单金额(分)\n",
    );
    for (
        id,
        earner_id,
        display_name,
        referral_code,
        amount,
        status,
        created_at,
        paid_at,
        plan_id,
        order_amount,
    ) in rows
    {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{}\n",
            id,
            earner_id,
            display_name,
            referral_code,
            amount,
            status,
            created_at,
            paid_at,
            plan_id,
            order_amount
        ));
    }

    (
        StatusCode::OK,
        [
            ("Content-Type", "text/csv; charset=utf-8"),
            (
                "Content-Disposition",
                "attachment; filename=\"commission_export.csv\"",
            ),
        ],
        csv,
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    // 🔑 **显式列出**需要的符号（而不是 `use super::*`）——
    //    通配导入会把「本模块到底依赖父模块的什么」藏起来，
    //    也让 `unused_imports` 这类检查失去作用（它只能整包判断）。
    use super::{apply_admin_refund, apply_refund, AdminRefundOutcome, RefundOutcome};
    use crate::schema::init_database;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        init_database(&conn).unwrap();
        conn
    }

    /// 创建批次测试：在 distribution_expenses 插入多条记录并聚合查询验证
    /// 标记已打款测试：distribution_expenses 批量标记 paid 后验证
    #[test]
    fn test_mark_paid() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let batch_no = format!("ST{}-0001", chrono::Utc::now().format("%Y%m%d"));

        // 先创建测试用户（FOREIGN KEY 约束需要）
        conn.execute(
            "INSERT INTO users (id, username, referral_code, created_at) VALUES ('earner-test', 'earner-test-user', 'earner-test-code', ?1)",
            rusqlite::params![now],
        ).unwrap();

        // 插入多条 expense
        for i in 0..3 {
            let expense_id = uuid::Uuid::new_v4().to_string();
            conn.execute(
                "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, batch_no, created_at) \
                 VALUES (?1, 'earner-test', ?2, 'subscription', 'confirmed', ?3, ?4)",
                rusqlite::params![expense_id, (i + 2) * 1000i64, batch_no, now],
            )
            .unwrap();
        }

        // 标记已打款
        conn.execute(
            "UPDATE distribution_expenses SET status = 'paid', batch_paid_at = ?1 \
             WHERE batch_no = ?2 AND status IN ('confirmed', 'paid')",
            rusqlite::params![now, batch_no],
        )
        .unwrap();

        // 验证状态变为 paid
        let (ret_status, ret_paid_at): (String, Option<String>) = conn
            .query_row(
                "SELECT status, batch_paid_at FROM distribution_expenses WHERE batch_no = ?1 LIMIT 1",
                rusqlite::params![batch_no],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(ret_status, "paid", "标记已打款后状态应为 paid");
        assert!(ret_paid_at.is_some(), "batch_paid_at 不应为空");
    }

    /// 标记已打款测试：非 confirmed 状态不可重复标记
    #[test]
    fn test_mark_paid_idempotent() {
        let conn = setup_db();
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let batch_no = format!("ST{}-0002", chrono::Utc::now().format("%Y%m%d"));
        let expense_id = uuid::Uuid::new_v4().to_string();

        // 先创建测试用户（FOREIGN KEY 约束需要）
        conn.execute(
            "INSERT INTO users (id, username, referral_code, created_at) VALUES ('earner-test', 'earner-test-user', 'earner-test-code', ?1)",
            rusqlite::params![now],
        ).unwrap();

        // 插入一条 expense
        conn.execute(
            "INSERT INTO distribution_expenses (id, earner_id, amount, expense_type, status, batch_no, created_at) \
             VALUES (?1, 'earner-test', 3000, 'subscription', 'confirmed', ?2, ?3)",
            rusqlite::params![expense_id, batch_no, now],
        )
        .unwrap();

        // 第一次标记 → paid
        let updated1 = conn
            .execute(
                "UPDATE distribution_expenses SET status = 'paid', batch_paid_at = ?1 \
                 WHERE batch_no = ?2 AND status IN ('confirmed', 'paid')",
                rusqlite::params![now, batch_no],
            )
            .unwrap();
        assert_eq!(updated1, 1, "第一次标记应成功");

        // 第二次标记 → 不应再影响（已被 AND status IN ('confirmed','paid') 限制，但已是 paid）
        let updated2 = conn
            .execute(
                "UPDATE distribution_expenses SET status = 'paid', batch_paid_at = ?1 \
                 WHERE batch_no = ?2 AND status IN ('confirmed', 'paid')",
                rusqlite::params![now, batch_no],
            )
            .unwrap();
        assert_eq!(
            updated2, 1,
            "幂等：已 paid 的记录也符合 IN ('confirmed','paid')，只更新行数不变但不会出错"
        );
    }

    // ════════════════════════════════════════════════════════════
    // 管理员退款（`apply_admin_refund`）—— **真断言**
    //
    // 🔴 这里替换掉了两个**假绿**测试：
    //    · `test_admin_refund_cancels_commissions` —— 把 handler 里的 SQL **抄进测试**再跑一遍
    //      （当时的注释：「执行退款操作（模拟 SQL，因为 handler 需 admin 认证）」）
    //    · `test_refund_only_success_orders` —— 同样只是跑了一条抄来的 UPDATE
    //    ⇒ 它们断言的是「**SQL 抄本**会得到什么结果」，
    //      而 `admin_refund` 改坏 / 删掉 / 顺序写错，**这两个测试都不会红**。
    //    📌 比 `assert!(true)` **更隐蔽**：有真断言、真数据、真会失败 ——
    //       只是**失败原因永远与被测对象无关**。
    //    修法不是「删测试」，而是**把逻辑抽成纯函数**，让断言有对象。
    // ════════════════════════════════════════════════════════════

    /// 🔴 正常退款：三张表都要变 + **计数要准**（计数进响应体，管理端会看到）。
    #[test]
    fn test_apply_admin_refund_cancels_commissions_and_rewards() {
        let conn = setup_db();
        let order_id = "order-admin-refund-ok";
        seed_refundable_order(&conn, order_id, "SUCCESS");

        let r = apply_admin_refund(&conn, order_id, "用户申请退款");
        assert_eq!(
            r,
            Ok(AdminRefundOutcome::Applied {
                cancelled_commissions: 1,
                cancelled_rewards: 1,
            }),
            "应报告各取消 1 条"
        );

        assert_eq!(status_of(&conn, "payment_orders", "id", order_id), "REFUND");
        assert_eq!(
            status_of(&conn, "distribution_commissions", "order_id", order_id),
            "cancelled"
        );
        assert_eq!(
            status_of(&conn, "reward_fulfillments", "order_id", order_id),
            "cancelled"
        );

        // `refund_reason` 要落库（管理员填的理由会展示给用户）——
        // 顺带守住「**参数确实传进了 UPDATE**」，而不只是「函数没报错」。
        let reason: Option<String> = conn
            .query_row(
                "SELECT refund_reason FROM payment_orders WHERE id = ?1",
                rusqlite::params![order_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(reason.as_deref(), Some("用户申请退款"));
    }

    /// 🔴 非 `SUCCESS` 订单 → `NotFoundOrNotPaid`（→ **404**），且**一张表都不许动**。
    ///    `admin_refund` 的查询自带 `AND status = 'SUCCESS'` —— 这点与 `webhook_refund` 不同
    ///    （那边查订单不带状态 → 「非 SUCCESS」表现为「进事务后被守卫挡住」）。
    ///    这是两个入口**各自既有**的语义差异，抽取时**原样保留、没做顺手统一**。
    #[test]
    fn test_apply_admin_refund_rejects_non_success_order() {
        let conn = setup_db();
        let order_id = "order-admin-refund-notpay";
        seed_refundable_order(&conn, order_id, "NOTPAY");

        let r = apply_admin_refund(&conn, order_id, "不该生效");
        assert_eq!(r, Ok(AdminRefundOutcome::NotFoundOrNotPaid));

        assert_eq!(
            status_of(&conn, "payment_orders", "id", order_id),
            "NOTPAY",
            "非 SUCCESS 订单不该被改成 REFUND"
        );
        // 🔑 佣金与奖励也必须**原样** —— 不能让「订单没退、佣金先被取消」这种情况存在
        //    （原测试只看订单状态，这里**加强**了覆盖。）
        assert_eq!(
            status_of(&conn, "distribution_commissions", "order_id", order_id),
            "locked",
            "订单未退，佣金不该被动"
        );
        assert_eq!(
            status_of(&conn, "reward_fulfillments", "order_id", order_id),
            "fulfilled",
            "订单未退，奖励不该被动"
        );
    }

    /// 订单**不存在** → 同样是 `NotFoundOrNotPaid`（与「非 SUCCESS」合并，见枚举文档）。
    #[test]
    fn test_apply_admin_refund_order_not_found() {
        let conn = setup_db();
        assert_eq!(
            apply_admin_refund(&conn, "no-such-order", "理由"),
            Ok(AdminRefundOutcome::NotFoundOrNotPaid)
        );
    }

    // 🗑 2026-10-01 删除 `test_refund_only_success_orders`。
    //    它插一个 NOTPAY 订单，然后跑一条**从 handler 抄来的** UPDATE，
    //    断言 `updated == 0` —— 测的是**那条 SQL**，不是 `admin_refund`。
    //    它的覆盖（「非 SUCCESS 不被退」）已由
    //    `test_apply_admin_refund_rejects_non_success_order` **加强版**接手
    //    （新测试连「佣金/奖励也不许被动」一起守）。
    //    📌 「删掉零消费者的测试」= 同「零消费者=死代码」，但**前提是覆盖已被接手**。

    // ════════════════════════════════════════════════════════════
    // 退款回调（`apply_refund`）—— **真断言**
    //
    // 🔑 这三个测试之所以能存在，是因为把逻辑从 handler 里抽成了纯函数：
    //    `webhook_refund` 走全局池 `db_pool::get_conn()`，而测试用的是 `setup_db()`
    //    的独立连接（刻意避开全局池）。
    //    ⚠️ 此前这里只有一个 `assert!(true, "...")` —— 恒真断言 = **假绿**
    //       （它不消耗任何信息，却让覆盖率看起来 +1）。
    //    📌 判据：**写不出真断言时如实标注未覆盖，而不是放个恒真断言充数**；
    //       而「抽成纯函数」才是让真断言写得出来的办法。
    // ════════════════════════════════════════════════════════════

    /// 造一套「订单 + locked 佣金 + fulfilled 奖励」的最小数据。
    ///
    /// 🔑 **两个退款入口（`apply_refund` / `apply_admin_refund`）共用它** ——
    ///    它们要的数据形状相同，只有「订单初始状态」不同 → 由参数给。
    /// ⚠️ FK 依赖必须**逐个建齐**，否则报 `FOREIGN KEY constraint failed`
    ///    而且**炸在 setup 上**（不是被测代码）—— 那种失败很容易被误读成「被测逻辑坏了」。
    ///    实测踩过：`marketing_campaigns.created_by` → `admin_users(id)`，
    ///    第一版填了字面量 `'admin'` 却没建该行。
    fn seed_refundable_order(conn: &Connection, order_id: &str, order_status: &str) {
        let now = chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let uid = format!("u-{}", order_id);
        let plan = format!("p-{}", order_id);
        let camp = format!("c-{}", order_id);

        conn.execute(
            "INSERT INTO users (id, username, display_name, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![uid, uid, "退款测试用户", now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO subscription_plans (id, name, price, duration_days, is_active, created_at) \
             VALUES (?1, '测试套餐', 10000, 30, 1, ?2)",
            rusqlite::params![plan, now],
        )
        .unwrap();
        // 🔴 `marketing_campaigns.created_by` → `admin_users(id)` 有外键。
        //    ⚠️ 第一版我在这里填了字面量 `'admin'` 却没建对应的管理员行 →
        //       `FOREIGN KEY constraint failed`，而且**炸在 setup 而不是被测代码上**
        //       —— 这种失败很容易被误读成「被测逻辑坏了」。先把依赖建齐再插。
        conn.execute(
            "INSERT INTO admin_users (id, username, password_hash, role, status, created_at) \
             VALUES ('admin-seed', 'admin_seed', 'hash', 'super_admin', 'approved', ?1)",
            rusqlite::params![now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO marketing_campaigns (id, name, status, rewards, trigger_event, created_by, created_at) \
             VALUES (?1, '退款测试活动', 'active', '[]', 'payment', 'admin-seed', ?2)",
            rusqlite::params![camp, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO payment_orders (id, user_id, plan_id, amount, status, created_at) \
             VALUES (?1, ?2, ?3, 10000, ?4, ?5)",
            rusqlite::params![order_id, uid, plan, order_status, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO distribution_commissions (id, campaign_id, earner_id, buyer_id, order_id, \
             order_amount, rate_applied, amount, level, status, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, 10000, 0.1, 1000, 1, 'locked', ?6)",
            rusqlite::params![format!("cm-{}", order_id), camp, uid, uid, order_id, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO reward_fulfillments (id, campaign_id, order_id, user_id, party, reward_type, \
             reward_value, trigger_event, status, fulfilled_at, created_at) \
             VALUES (?1, ?2, ?3, ?4, 'inviter', 'commission_pct', '0.1', 'payment', 'fulfilled', ?5, ?5)",
            rusqlite::params![format!("rw-{}", order_id), camp, order_id, uid, now],
        )
        .unwrap();
    }

    /// 🔑 读某个状态列。**仅测试用** —— `table` / `id_col` 都是调用处写死的字面量，
    /// 没有外部输入，所以这里的 `format!` 拼 SQL 不构成注入面。
    fn status_of(conn: &Connection, table: &str, id_col: &str, id: &str) -> String {
        conn.query_row(
            &format!("SELECT status FROM {} WHERE {} = ?1", table, id_col),
            rusqlite::params![id],
            |r| r.get(0),
        )
        .unwrap()
    }

    /// 🔴 订单**不存在** → `OrderNotFound`（**不是 `Err`**）。
    ///    微信会重复投递，也可能投递已被清理的订单 ——
    ///    把这种情况当错误、让回调永远重试，才是 bug。
    ///    （替代了此前那个「只验 setup、不验被测对象」的 `..._precondition`。）
    #[test]
    fn test_apply_refund_order_not_found() {
        let conn = setup_db();
        let r = apply_refund(&conn, "non-existent-order", Some("wx-refund-001"));
        assert_eq!(
            r,
            Ok(RefundOutcome::OrderNotFound),
            "订单不存在应返回 OrderNotFound，而不是 Err"
        );
    }

    /// 🔴 **真实路径**：订单存在且为 SUCCESS → **三张表都要被更新**。
    ///    只验一处不够 —— 三步 UPDATE 任意一步漏了/写错都该被抓出来。
    #[test]
    fn test_apply_refund_updates_three_tables() {
        let conn = setup_db();
        let order_id = "order-refund-ok";
        seed_refundable_order(&conn, order_id, "SUCCESS");

        let r = apply_refund(&conn, order_id, Some("wx-refund-002"));
        assert_eq!(r, Ok(RefundOutcome::Applied));

        assert_eq!(status_of(&conn, "payment_orders", "id", order_id), "REFUND");
        assert_eq!(
            status_of(&conn, "distribution_commissions", "order_id", order_id),
            "cancelled",
            "locked 佣金应被取消"
        );
        assert_eq!(
            status_of(&conn, "reward_fulfillments", "order_id", order_id),
            "cancelled",
            "fulfilled 奖励应被取消"
        );

        // `refund_id` 要落库（对账用）—— 顺带守住「参数确实传到了 UPDATE 里」
        let rid: Option<String> = conn
            .query_row(
                "SELECT refund_id FROM payment_orders WHERE id = ?1",
                rusqlite::params![order_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(rid.as_deref(), Some("wx-refund-002"));
    }

    /// 🔴 **非 SUCCESS 订单不被改动** —— 三步 UPDATE 都带 `AND status = '<期望值>'` 守卫。
    ///    事务本身算成功（`Applied`），但订单状态必须**原样**。
    ///    这条守住的是「幂等 / 防误改」这个真正重要的性质，不是形式。
    #[test]
    fn test_apply_refund_ignores_non_success_order() {
        let conn = setup_db();
        let order_id = "order-refund-notpay";
        seed_refundable_order(&conn, order_id, "NOTPAY");

        let r = apply_refund(&conn, order_id, Some("wx-refund-003"));
        assert_eq!(r, Ok(RefundOutcome::Applied));

        assert_eq!(
            status_of(&conn, "payment_orders", "id", order_id),
            "NOTPAY",
            "非 SUCCESS 订单不该被改成 REFUND"
        );
    }
}
// FORCE_REBUILD_1782825921
