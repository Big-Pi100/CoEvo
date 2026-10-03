//! 订单查询 Handler
//!
//! # 🔴 2026-10-03：微信支付**已移除**，支付改为 Apple IAP
//!
//! 本模块原名「支付相关 Handler — 下单 / 回调 / 订单查询」。本次改动删除了：
//!
//! | 删除项 | 原行数 | 为什么 |
//! |---|---|---|
//! | `native_pay_handler` | 315 | 微信 Native 扫码下单 |
//! | `pay_notify_handler` | 158 | 微信支付回调（异步通知）|
//! | `distribute_commission_on_payment` | 184 | 「支付成功后返佣」—— 调用者**全部是上面两条微信路径** |
//! | 同模块 `wechat_pay.rs` | 283 | 微信 API v3 封装 |
//!
//! **合计约 940 行**（含 `routes.rs` 的两条端点注册）。
//!
//! # 为什么改
//!
//! 产品改用 **Apple 应用内购买（IAP · 自动续期订阅）**：
//! · 下单与支付流程由 **StoreKit 在客户端**完成 —— 服务端**不参与下单**；
//! · 服务端只做**交易验证与对账**（`GET /api/iap/verify`，见 `iap_handlers.rs`）；
//! · 因此「下单 Handler」「支付回调 Handler」这两类**在 IAP 下不需要存在**。
//!
//! ⚠️ 注意一个**结构差异**（别照搬微信的写法）：微信是**服务端下单 → 客户端扫码 →
//!    微信回调服务端**；IAP 是**客户端购买 → 客户端拿凭据 → 客户端告诉服务端**。
//!    ⇒ 后者没有「服务端被动等回调」这一环，**验证必须由服务端主动发起**。
//!
//! # 保留了什么（以及为什么）
//!
//! · `user_orders_handler` — 用户端「我的订单」。
//! · `admin_orders_handler` — 管理端订单查询。
//! · `order_status_handler` — 查单笔订单状态（**已去掉「向微信查询」那段**）。
//!
//! 🔑 这三个查的都是 `payment_orders` 表，而 **IAP 的交易记录也会写进同一张表**
//!    （见 `iap_handlers.rs` 的设计说明）⇒ 查询接口**无需为 IAP 重写**。

use axum::{
    extract::{Path, Query},
    http::StatusCode,
    response::IntoResponse,
};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
pub struct UserOrdersQuery {
    pub user_id: Option<String>,
}

/// GET /api/pay/orders?user_id=xxx — 查询用户订单
pub async fn user_orders_handler(Query(query): Query<UserOrdersQuery>) -> impl IntoResponse {
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
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("查询失败: {}", e),
            )
                .into_response()
        }
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
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("查询失败: {}", e),
            )
                .into_response()
        }
    };

    (StatusCode::OK, json!({"orders": rows}).to_string()).into_response()
}

/// GET /api/pay/orders/{id} — 查询单笔订单状态（**只读本地**）
///
/// # 🔴 2026-10-03 简化：去掉了「向微信查询实际状态并同步」那一段
///
/// 原实现有一段「本地是 `NOTPAY` 时，主动向微信查单，若已支付则同步本地状态 +
/// 延期订阅 + 分发佣金」。**IAP 下这一整段都没有对应物**：
///
/// | 微信的做法 | IAP 下的对应 |
/// |---|---|
/// | 服务端**主动**向微信查单 | ❌ 不需要 —— 交易凭据由客户端上报（`/api/iap/verify`）|
/// | 「条件 UPDATE 防竞态翻倍」| ❌ 不需要 —— 验证是**幂等**的（按 `transaction_id` 唯一）|
/// | 同步时顺带 `extend_subscription` | ❌ 移入 `iap_handlers`（由**验证**触发，不是由查单触发）|
/// | 顺带分发佣金 | ❌ 已随微信一并删除（见模块文档）|
///
/// ⇒ 本接口现在**纯粹是只读查询**：查不到就 404，不做任何副作用。
///    📌 判据：**「查状态」不该有副作用** —— 原实现把它做成了「查着查着就改了状态」，
///       在 IAP 下这是**多余且危险**的（会与验证链路争抢同一份状态）。
pub async fn order_status_handler(Path(order_id): Path<String>) -> impl IntoResponse {
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

    match order {
        Ok(o) => (StatusCode::OK, o.to_string()).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "订单不存在").into_response(),
    }
}
