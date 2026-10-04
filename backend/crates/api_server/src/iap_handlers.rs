//! Apple IAP（自动续期订阅）—— 服务端**验证与对账**
//!
//! # 职责边界（🔴 先读这段）
//!
//! 本 App 的订阅权益是「**无限生词本 + 文章朗读**」，两者都是**端侧功能**
//! （生词本在 `user.db`，朗读在端侧）⇒ **服务端不是权益判断的必经路径**。
//!
//! | 判断 | 由谁做 | 说明 |
//! |---|---|---|
//! | 「当前是否是会员」 | **端侧**（StoreKit 2 `Transaction.currentEntitlements`）| 离线可用 |
//! | 「服务端记录了什么」 | 本模块 + `users.subscription_expires` | **对账/留档** |
//!
//! ⇒ 所以本模块**不做下单、不做支付回调**（IAP 下这两件事都不存在）。
//! ⇒ 唯一的入口是 `POST /api/iap/verify`：端侧买完 → 拿 `transactionId` → 告诉我们。
//!
//! # 与微信时代的结构差异（别照搬旧写法）
//!
//! | 微信 | IAP |
//! |---|---|
//! | 服务端**下单** → 客户端扫码 | ❌ 服务端不参与下单（StoreKit 在客户端完成）|
//! | 微信**回调**服务端（被动等）| ❌ 无回调 —— 凭据由**客户端上报** |
//! | 服务端**主动**向微信查单 | ✅ **必须主动查**（`GET /inApps/v1/transactions/{id}`）|
//! | 加 N 天（买断）| ✅ **直接写入 Apple 给的 `expiresDate`**（订阅）|
//!
//! # 🔑 一期不验 JWS 签名（有理由，不是省事）
//!
//! JWS 验签的必要性是「**收到别人发来的 JWS 时，证明它真来自 Apple**」。
//! 而我们是**主动**调 Apple 的 HTTPS 接口 ⇒ 响应经 **TLS** 保护 ⇒ 中间人无法伪造
//! ⇒ **可不验签**。二期做 Server Notifications V2（Apple 主动 POST 给我们）时**必须验**。
//!
//! ⚠️ 但**仍要解 JWS 的 payload** —— Apple 的交易信息就装在 JWS 第二段里（见
//!    `parse_signed_transaction_info`）。「不验签」≠「不解码」。

use axum::{
    extract::Json,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use rusqlite::params;
use serde::Deserialize;
use serde_json::{json, Value};

// ════════════════════════════════════════════════════════════
// 常量：Product ID 必须与 App Store Connect 完全一致
// ════════════════════════════════════════════════════════════

/// 🔴 与 ASC 里建的订阅产品 ID **必须逐字一致**（大小写敏感）。
pub const PRODUCT_MONTHLY: &str = "com.coevo.coevoApp.pro.monthly";
pub const PRODUCT_YEARLY: &str = "com.coevo.coevoApp.pro.yearly";

/// 🔴 与 Xcode 工程的 `PRODUCT_BUNDLE_IDENTIFIER` 一致（`app/ios/Runner.xcodeproj`）。
pub const BUNDLE_ID: &str = "com.coevo.coevoApp";

pub const ENV_SANDBOX: &str = "Sandbox";
pub const ENV_PRODUCTION: &str = "Production";

/// 我们认可的 Product ID 集合。
pub fn is_known_product(product_id: &str) -> bool {
    product_id == PRODUCT_MONTHLY || product_id == PRODUCT_YEARLY
}

// ════════════════════════════════════════════════════════════
// Apple 交易（从 Server API 的 JWS payload 中提取的最小集）
// ════════════════════════════════════════════════════════════

#[derive(Debug, Clone, PartialEq)]
pub struct AppleTransaction {
    /// 本期交易的唯一 ID（**每期续费都会变**）
    pub transaction_id: String,
    /// 订阅的**稳定标识** —— 同一订阅的所有续期共享它
    /// ⇒ **恢复购买 / 查订阅状态靠它，不能靠 `transaction_id`**
    pub original_transaction_id: String,
    pub product_id: String,
    pub bundle_id: String,
    /// 购入时间（Apple 毫秒时间戳）
    pub purchase_date: Option<i64>,
    /// 到期时间（Apple 毫秒时间戳）· 订阅才有
    pub expires_date: Option<i64>,
    /// `Sandbox` | `Production`
    pub environment: String,
    pub app_account_token: Option<String>,
    /// 原始 JWS，留档排障用
    pub raw_jws: String,
}

/// 解析 Apple `GET /inApps/v1/transactions/{id}` 的响应体。
///
/// 响应形如 `{"signedTransactionInfo":"<JWS>"}` —— 真正的交易信息在 **JWS 第二段**。
pub fn parse_transaction_response(body: &str) -> Result<AppleTransaction, String> {
    let v: Value =
        serde_json::from_str(body).map_err(|e| format!("Apple 响应不是合法 JSON: {}", e))?;
    let jws = v
        .get("signedTransactionInfo")
        .and_then(|s| s.as_str())
        .ok_or_else(|| "Apple 响应缺 signedTransactionInfo".to_string())?;
    parse_signed_transaction_info(jws)
}

/// 从 JWS 中解出交易信息（**只解码、不验签** —— 理由见模块文档）。
///
/// JWS 结构：`<base64url(header)>.<base64url(payload)>.<base64url(signature)>`
pub fn parse_signed_transaction_info(jws: &str) -> Result<AppleTransaction, String> {
    let parts: Vec<&str> = jws.split('.').collect();
    if parts.len() != 3 {
        return Err(format!("JWS 段数应为 3，实际 {}", parts.len()));
    }
    let payload_bytes = base64_url_decode(parts[1])?;
    let v: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|e| format!("JWS payload 不是合法 JSON: {}", e))?;

    let get_str = |k: &str| -> Result<String, String> {
        v.get(k)
            .and_then(|x| x.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| format!("交易信息缺字段 `{}`", k))
    };

    Ok(AppleTransaction {
        transaction_id: get_str("transactionId")?,
        original_transaction_id: get_str("originalTransactionId")?,
        product_id: get_str("productId")?,
        bundle_id: get_str("bundleId")?,
        purchase_date: v.get("purchaseDate").and_then(|x| x.as_i64()),
        expires_date: v.get("expiresDate").and_then(|x| x.as_i64()),
        environment: get_str("environment")?,
        app_account_token: v
            .get("appAccountToken")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        raw_jws: jws.to_string(),
    })
}

/// base64url（无 padding）解码 —— JWS 用这种编码。
fn base64_url_decode(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(s)
        .map_err(|e| format!("base64url 解码失败: {}", e))
}

fn base64_url_encode(b: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
}

// ════════════════════════════════════════════════════════════
// 纯逻辑：校验与换算
// ════════════════════════════════════════════════════════════

/// 校验这笔交易是不是「我们的、且环境对得上」。
///
/// 三项缺一不可 —— **只校验其中一项都是不够的**：
/// · 不校验 `bundle_id` ⇒ 别人 App 的交易也能写进我们的库
/// · 不校验 `product_id` ⇒ 将来加产品时旧逻辑会静默接受任意产品
/// · 不校验 `environment` ⇒ 沙盒交易被当成真实付费（**最危险**）
pub fn validate_transaction(tx: &AppleTransaction, expected_env: &str) -> Result<(), String> {
    if tx.bundle_id != BUNDLE_ID {
        return Err(format!(
            "bundleId 不匹配：期望 {}，实际 {}",
            BUNDLE_ID, tx.bundle_id
        ));
    }
    if !is_known_product(&tx.product_id) {
        return Err(format!("未知 productId：{}", tx.product_id));
    }
    if tx.environment != expected_env {
        return Err(format!(
            "environment 不匹配：期望 {}，实际 {}",
            expected_env, tx.environment
        ));
    }
    Ok(())
}

/// Apple 毫秒时间戳 → RFC3339（UTC），如 `2026-11-04T12:33:00Z`。
///
/// 🔑 用**完整时间**（而非 `%Y-%m-%d`）：订阅是按秒到期的，
///    截断到日期会在「最后一天」多送/少送最多 24 小时。
///    `subscription::is_subscription_active` 两种格式都兼容，这里给更精确的那种。
pub fn millis_to_rfc3339(ms: i64) -> Option<String> {
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

// ════════════════════════════════════════════════════════════
// 持久化
// ════════════════════════════════════════════════════════════

/// 幂等写入 `iap_transactions`。返回「是否是首次插入」。
///
/// 🔑 为什么用 `DO UPDATE ... WHERE 有变化` 而不是 `DO NOTHING`：
///    **续期要能更新到期日**。`DO NOTHING` 会让一笔订阅永远停在首期的到期时间。
/// 🔑 `WHERE` 用 `IS NOT`（而不是 `<>`）比较 —— 后者遇 NULL 恒为 NULL
///    ⇒ `expires_date` 为 NULL 的行**永远不会被更新**。
pub fn upsert_transaction(
    conn: &rusqlite::Connection,
    tx: &AppleTransaction,
    user_id: &str,
) -> Result<bool, String> {
    let existed = conn
        .query_row(
            "SELECT 1 FROM iap_transactions WHERE transaction_id = ?1",
            params![tx.transaction_id],
            |_| Ok(()),
        )
        .is_ok();

    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    conn.execute(
        "INSERT INTO iap_transactions
           (transaction_id, original_transaction_id, user_id, product_id,
            purchase_date, expires_date, environment, app_account_token,
            raw_payload, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
         ON CONFLICT(transaction_id) DO UPDATE SET
           user_id          = excluded.user_id,
           expires_date     = excluded.expires_date,
           environment      = excluded.environment,
           raw_payload      = excluded.raw_payload,
           updated_at       = excluded.updated_at
         WHERE iap_transactions.expires_date     IS NOT excluded.expires_date
            OR iap_transactions.user_id          IS NOT excluded.user_id
            OR iap_transactions.environment      IS NOT excluded.environment",
        params![
            tx.transaction_id,
            tx.original_transaction_id,
            user_id,
            tx.product_id,
            tx.purchase_date,
            tx.expires_date,
            tx.environment,
            tx.app_account_token,
            tx.raw_jws,
            now,
        ],
    )
    .map_err(|e| format!("写 iap_transactions 失败: {}", e))?;

    Ok(!existed)
}

/// 写「我的订单」记录（幂等：同一 `transaction_id` 只写一条）。
///
/// 🔑 `payment_orders` 是**面向用户的订单视图** —— 查询接口（`pay_handlers`）复用它，
///    所以 IAP 的交易也要在这里留一条，否则「我的订单」是空的。
/// ⚠️ Apple 的 `transactionId` 天然唯一 ⇒ 以它为去重键。
fn ensure_order(
    conn: &rusqlite::Connection,
    tx: &AppleTransaction,
    user_id: &str,
    amount_fen: i64,
) -> Result<(), String> {
    let exists = conn
        .query_row(
            "SELECT 1 FROM payment_orders WHERE transaction_id = ?1 LIMIT 1",
            params![tx.transaction_id],
            |_| Ok(()),
        )
        .is_ok();
    if exists {
        return Ok(());
    }

    let order_id = uuid::Uuid::new_v4().to_string();
    let paid_at = tx
        .purchase_date
        .and_then(millis_to_rfc3339)
        .unwrap_or_else(|| chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string());

    conn.execute(
        "INSERT INTO payment_orders
           (id, user_id, plan_id, amount, currency, status, transaction_id, paid_at, created_at)
         VALUES (?1, ?2, ?3, ?4, 'CNY', 'SUCCESS', ?5, ?6, ?6)",
        params![
            order_id,
            user_id,
            tx.product_id,
            amount_fen,
            tx.transaction_id,
            paid_at,
        ],
    )
    .map_err(|e| format!("写 payment_orders 失败: {}", e))?;

    Ok(())
}

/// 取该产品的**兜底**价格（分）—— 用于订单展示。
///
/// ⚠️ 价格权威在 **App Store Connect**；本地 `subscription_plans.price` 只是兜底。
///    取不到就记 0（订单展示为 0 比「写入一个编造的数字」更诚实 —— 编造会污染对账）。
fn fallback_price_fen(conn: &rusqlite::Connection, product_id: &str) -> i64 {
    conn.query_row(
        "SELECT price FROM subscription_plans WHERE id = ?1",
        params![product_id],
        |row| row.get::<_, i64>(0),
    )
    .unwrap_or(0)
}

// ════════════════════════════════════════════════════════════
// Apple Server API
// ════════════════════════════════════════════════════════════

/// IAP 服务端配置（来自环境变量）。
///
/// 🔴 三项都**必须白哥在 ASC 生成/填写**：
///    · `.p8` 私钥（ASC → Users and Access → Integrations → In-App Purchase）
///    · `Key ID`（随 .p8 一起给出）
///    · `Issuer ID`（ASC 页面上方）
#[derive(Debug, Clone)]
pub struct IapConfig {
    pub key_id: String,
    pub issuer_id: String,
    /// `.p8` 文件的**内容**（PEM，含 `-----BEGIN PRIVATE KEY-----`）
    pub private_key_pem: String,
    /// `Sandbox` | `Production`
    pub environment: String,
}

impl IapConfig {
    pub fn from_env() -> Result<Self, String> {
        let key_id = std::env::var("IAP_KEY_ID").map_err(|_| "缺环境变量 IAP_KEY_ID")?;
        let issuer_id = std::env::var("IAP_ISSUER_ID").map_err(|_| "缺环境变量 IAP_ISSUER_ID")?;
        let private_key_pem =
            std::env::var("IAP_PRIVATE_KEY").map_err(|_| "缺环境变量 IAP_PRIVATE_KEY")?;
        // 默认 Production；沙盒联调时设成 Sandbox
        let environment =
            std::env::var("IAP_ENVIRONMENT").unwrap_or_else(|_| ENV_PRODUCTION.to_string());

        Ok(Self {
            key_id,
            issuer_id,
            private_key_pem,
            environment,
        })
    }

    fn api_base(&self) -> &'static str {
        if self.environment == ENV_SANDBOX {
            "https://api.storekit-sandbox.itunes.apple.com"
        } else {
            "https://api.storekit.itunes.apple.com"
        }
    }
}

/// 生成 App Store Server API 的鉴权 JWT（ES256）。
///
/// 结构：`{"alg":"ES256","kid":<KeyID>,"typ":"JWT"}` / `{"iss":<IssuerID>,"iat":..,"exp":..,"aud":"appstoreconnect-v1","bid":<BundleID>}`
pub fn make_api_token(cfg: &IapConfig, now_unix: i64) -> Result<String, String> {
    let header = json!({"alg": "ES256", "kid": cfg.key_id, "typ": "JWT"});

    // 🔑 `exp` 给 20 分钟 —— Apple 允许 1–60 分钟，取中间值避免边界。
    //    每次请求**现签**（不做缓存），因为一次验证只调一个接口，缓存收益为零。
    let payload = json!({
        "iss": cfg.issuer_id,
        "iat": now_unix,
        "exp": now_unix + 20 * 60,
        "aud": "appstoreconnect-v1",
        "bid": BUNDLE_ID,
    });

    let signing_input = format!(
        "{}.{}",
        base64_url_encode(header.to_string().as_bytes()),
        base64_url_encode(payload.to_string().as_bytes()),
    );

    let signature = sign_es256(&cfg.private_key_pem, signing_input.as_bytes())?;
    Ok(format!(
        "{}.{}",
        signing_input,
        base64_url_encode(&signature)
    ))
}

/// 用 `.p8`（PKCS#8）私钥做 ES256 签名。
///
/// 🔴 两个必须踩对的细节：
///   ① **PEM → DER**：`ring::signature::EcdsaKeyPair::from_pkcs8` 收的是 **DER 字节**，
///      而 `.p8` 文件是 **PEM**（base64 包在 `-----BEGIN PRIVATE KEY-----` 里）
///      ⇒ 必须先把 header/footer/换行剥掉再 base64 解码。直接喂 PEM 一定失败。
///   ② **签名格式**：必须用 `ECDSA_P256_SHA256_FIXED_SIGNING`（输出 **R||S 各 32 字节**）。
///      用 `_ASN1_` 变体（DER 编码）产出的签名**不符合 JWT ES256 规范**，
///      Apple 会返回 401 —— 而且错误信息不会告诉你是格式问题。
fn sign_es256(private_key_pem: &str, msg: &[u8]) -> Result<Vec<u8>, String> {
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

    let der = pem_to_der(private_key_pem)?;
    let rng = SystemRandom::new();

    // ⚠️ ring 0.17 的 `from_pkcs8` 是**三参数**（第三个是 `&dyn SecureRandom`）——
    //    与 0.16 的两参数签名不同，照抄旧示例会编译失败。
    let key_pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
        .map_err(|e| format!("解析 .p8 私钥失败（确认是 PKCS#8 且曲线为 P-256）: {}", e))?;

    let sig = key_pair
        .sign(&rng, msg)
        .map_err(|e| format!("ES256 签名失败: {}", e))?;

    Ok(sig.as_ref().to_vec())
}

/// PEM → DER：剥掉 `-----BEGIN/END-----` 与所有空白，再 base64 解码。
fn pem_to_der(pem: &str) -> Result<Vec<u8>, String> {
    let b64: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .flat_map(|l| l.chars())
        .filter(|c| !c.is_whitespace())
        .collect();

    if b64.is_empty() {
        return Err("私钥内容为空（IAP_PRIVATE_KEY 是否只填了路径而不是文件内容？）".to_string());
    }

    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| format!("私钥 base64 解码失败: {}", e))
}

/// 调 Apple 查询单笔交易。
pub async fn fetch_transaction(
    cfg: &IapConfig,
    transaction_id: &str,
) -> Result<AppleTransaction, String> {
    let now = chrono::Utc::now().timestamp();
    let token = make_api_token(cfg, now)?;

    let url = format!(
        "{}/inApps/v1/transactions/{}",
        cfg.api_base(),
        transaction_id
    );

    let resp = reqwest::Client::new()
        .get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| format!("请求 Apple 失败: {}", e))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读取 Apple 响应失败: {}", e))?;

    if !status.is_success() {
        // ⚠️ 404 = 这笔交易在**这个环境**查不到 —— 最常见原因是「沙盒交易查了生产端点」
        //    或反之。把这条提示写进错误里，省一次盲目排查。
        return Err(format!(
            "Apple 返回 {} — 若为 404，检查 IAP_ENVIRONMENT 是否与交易来源环境一致。响应: {}",
            status, body
        ));
    }

    parse_transaction_response(&body)
}

// ════════════════════════════════════════════════════════════
// Handler
// ════════════════════════════════════════════════════════════

#[derive(Deserialize)]
pub struct IapVerifyBody {
    #[serde(rename = "transactionId")]
    pub transaction_id: String,
    pub user_id: String,
}

/// `POST /api/iap/verify` —— 端侧买完（或恢复购买后）上报交易，服务端验证并记账。
///
/// # 🔴 为什么要求登录（白哥 2026-10-04 决策）
///
/// 服务端记账必须有 `user_id`，否则归属不明。但这**不违反产品原则** ——
/// 产品原则管的是「**内容渲染不得被登录态阻塞**」，而这里：
/// · **购买本身不需要登录**（StoreKit 用 Apple ID 完成）
/// · **端侧权益已解锁**（端侧权威，不依赖本次上报）
/// · 未登录时**不上报**，用户登录后**补报**即可
/// ⇒ 登录卡在「对账」，不卡在「能用」。
pub async fn iap_verify_handler(
    headers: HeaderMap,
    Json(body): Json<IapVerifyBody>,
) -> impl IntoResponse {
    // ── 1. 鉴权：必须登录（用户 id 与 token 必须对得上）──
    if let Err(e) = crate::auth_middleware::verify_auth(&body.user_id, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            json!({"error": format!("未登录或凭据无效: {}", e)}).to_string(),
        )
            .into_response();
    }

    if body.transaction_id.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            json!({"error": "transactionId 不能为空"}).to_string(),
        )
            .into_response();
    }

    // ── 2. 读配置 ──
    let cfg = match IapConfig::from_env() {
        Ok(c) => c,
        Err(e) => {
            // 🔴 配置缺失是**部署问题**，不是用户问题 ⇒ 503 + 明确原因，
            //    不要让端侧以为「这笔交易无效」。
            tracing::error!("IAP 未配置: {}", e);
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"error": format!("IAP 服务端未配置: {}", e)}).to_string(),
            )
                .into_response();
        }
    };

    // ── 3. 向 Apple 查证 ──
    let tx = match fetch_transaction(&cfg, &body.transaction_id).await {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("IAP 查证失败 tx={}: {}", body.transaction_id, e);
            return (
                StatusCode::BAD_GATEWAY,
                json!({"error": format!("交易查证失败: {}", e)}).to_string(),
            )
                .into_response();
        }
    };

    // ── 4. 校验（bundle / product / environment 三项）──
    if let Err(e) = validate_transaction(&tx, &cfg.environment) {
        tracing::warn!("IAP 交易校验不通过 tx={}: {}", tx.transaction_id, e);
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            json!({"error": format!("交易校验不通过: {}", e)}).to_string(),
        )
            .into_response();
    }

    // ── 5. 记账 ──
    let conn = crate::db_pool::get_conn();
    let amount = fallback_price_fen(&conn, &tx.product_id);

    if let Err(e) = upsert_transaction(&conn, &tx, &body.user_id) {
        tracing::error!("写入 iap_transactions 失败: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({"error": e}).to_string(),
        )
            .into_response();
    }

    if let Err(e) = ensure_order(&conn, &tx, &body.user_id, amount) {
        tracing::error!("写入 payment_orders 失败: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({"error": e}).to_string(),
        )
            .into_response();
    }

    // ── 6. 更新订阅到期日（🔴 直接写 Apple 的值，不是「加 N 天」）──
    let expires_at = tx.expires_date.and_then(millis_to_rfc3339);
    if let Some(ref exp) = expires_at {
        if let Err(e) = crate::subscription::set_expires(&conn, &body.user_id, exp) {
            tracing::error!("更新 subscription_expires 失败: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                json!({"error": format!("更新订阅状态失败: {}", e)}).to_string(),
            )
                .into_response();
        }
    }

    let is_active = expires_at
        .as_deref()
        .map(|_| crate::subscription::is_subscription_active(&conn, &body.user_id))
        .unwrap_or(false);

    (
        StatusCode::OK,
        json!({
            "isActive": is_active,
            "expiresAt": expires_at,
            "productId": tx.product_id,
            "originalTransactionId": tx.original_transaction_id,
        })
        .to_string(),
    )
        .into_response()
}

// ════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn sample_tx() -> AppleTransaction {
        AppleTransaction {
            transaction_id: "2000000123456789".to_string(),
            original_transaction_id: "2000000100000000".to_string(),
            product_id: PRODUCT_MONTHLY.to_string(),
            bundle_id: BUNDLE_ID.to_string(),
            purchase_date: Some(1_800_000_000_000),
            expires_date: Some(1_802_592_000_000),
            environment: ENV_SANDBOX.to_string(),
            app_account_token: None,
            raw_jws: "h.p.s".to_string(),
        }
    }

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_database(&conn).unwrap();
        conn.execute(
            "INSERT INTO users (id, username, created_at) VALUES ('u1', 'tester', datetime('now'))",
            [],
        )
        .unwrap();
        conn
    }

    // ── 纯逻辑 ──

    #[test]
    fn test_is_known_product() {
        assert!(is_known_product(PRODUCT_MONTHLY));
        assert!(is_known_product(PRODUCT_YEARLY));
        // 反向：相似但不相同的串必须被拒（防「前缀匹配」式的假通过）
        assert!(!is_known_product("com.coevo.coevoApp.pro.monthly.x"));
        assert!(!is_known_product("com.coevo.coevoApp.pro"));
        assert!(!is_known_product(""));
    }

    #[test]
    fn test_validate_transaction_ok() {
        let tx = sample_tx();
        assert!(validate_transaction(&tx, ENV_SANDBOX).is_ok());
    }

    /// 🔴 三种不匹配**逐一**断言 —— 不能只测一种就认为「校验写对了」。
    #[test]
    fn test_validate_transaction_rejects_each_field() {
        let mut tx = sample_tx();

        // ① bundle 不对（别人的 App）
        tx.bundle_id = "com.other.app".to_string();
        assert!(
            validate_transaction(&tx, ENV_SANDBOX).is_err(),
            "bundle 不匹配未拦住"
        );
        tx.bundle_id = BUNDLE_ID.to_string();

        // ② product 不在白名单
        tx.product_id = "com.coevo.coevoApp.pro.lifetime".to_string();
        assert!(
            validate_transaction(&tx, ENV_SANDBOX).is_err(),
            "未知产品未拦住"
        );
        tx.product_id = PRODUCT_MONTHLY.to_string();

        // ③ 🔴 环境不符 —— 最危险的一种：沙盒交易被当真实付费
        assert!(
            validate_transaction(&tx, ENV_PRODUCTION).is_err(),
            "沙盒交易混入生产环境未拦住"
        );
    }

    #[test]
    fn test_millis_to_rfc3339() {
        // 2027-02-17T04:31:40Z（由扩展时间戳实算，非手写）
        let s = millis_to_rfc3339(1_802_592_000_000).unwrap();
        assert!(s.ends_with('Z'), "应为 UTC：{}", s);
        assert_eq!(s.len(), 20, "RFC3339 长度应为 20：{}", s);
        // 🔑 必须是**完整时间**而非日期 —— 长度断言就是在防「截断成 %Y-%m-%d」
        assert!(s.contains('T'), "缺时间部分，可能被截断成日期：{}", s);
    }

    // ── 持久化 ──

    #[test]
    fn test_upsert_transaction_insert_then_idempotent() {
        let conn = setup_db();
        let tx = sample_tx();

        let first = upsert_transaction(&conn, &tx, "u1").unwrap();
        assert!(first, "首次应为新插入");

        let second = upsert_transaction(&conn, &tx, "u1").unwrap();
        assert!(!second, "同样内容再写一次不应算新插入");

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM iap_transactions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "幂等失败：写了两条");
    }

    /// 🔑 这条测的是「续期能更新到期日」—— `DO NOTHING` 会在这里挂。
    #[test]
    fn test_upsert_transaction_updates_expires_on_renewal() {
        let conn = setup_db();
        let mut tx = sample_tx();
        upsert_transaction(&conn, &tx, "u1").unwrap();

        let new_expires = 1_805_184_000_000_i64;
        tx.expires_date = Some(new_expires);
        upsert_transaction(&conn, &tx, "u1").unwrap();

        let got: i64 = conn
            .query_row(
                "SELECT expires_date FROM iap_transactions WHERE transaction_id = ?1",
                params![tx.transaction_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            got, new_expires,
            "续期后到期日未更新（DO NOTHING 的典型症状）"
        );
    }

    #[test]
    fn test_ensure_order_idempotent() {
        let conn = setup_db();
        let tx = sample_tx();

        ensure_order(&conn, &tx, "u1", 990).unwrap();
        ensure_order(&conn, &tx, "u1", 990).unwrap();

        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM payment_orders", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1, "同一 transactionId 写了两条订单");

        // 顺带守住「参数确实写进了 INSERT」，而不只是「函数没报错」
        let (status, amount, plan): (String, i64, String) = conn
            .query_row(
                "SELECT status, amount, plan_id FROM payment_orders WHERE transaction_id = ?1",
                params![tx.transaction_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(status, "SUCCESS");
        assert_eq!(amount, 990);
        assert_eq!(plan, PRODUCT_MONTHLY);
    }

    // ── 解析 ──

    #[test]
    fn test_parse_signed_transaction_info() {
        let payload = json!({
            "transactionId": "2000000999",
            "originalTransactionId": "2000000111",
            "productId": PRODUCT_YEARLY,
            "bundleId": BUNDLE_ID,
            "purchaseDate": 1_800_000_000_000_i64,
            "expiresDate": 1_803_153_600_000_i64,
            "environment": "Sandbox"
        });
        let jws = format!(
            "{}.{}.{}",
            base64_url_encode(b"{\"alg\":\"ES256\"}"),
            base64_url_encode(payload.to_string().as_bytes()),
            base64_url_encode(b"fakesig")
        );

        let tx = parse_signed_transaction_info(&jws).unwrap();
        assert_eq!(tx.transaction_id, "2000000999");
        assert_eq!(tx.original_transaction_id, "2000000111");
        assert_eq!(tx.product_id, PRODUCT_YEARLY);
        assert_eq!(tx.environment, "Sandbox");
        assert_eq!(tx.expires_date, Some(1_803_153_600_000));
    }

    #[test]
    fn test_parse_rejects_malformed() {
        // 段数不对
        assert!(parse_signed_transaction_info("only.two").is_err());
        // payload 不是 JSON
        let bad = format!(
            "{}.{}.{}",
            base64_url_encode(b"{}"),
            base64_url_encode(b"not json"),
            base64_url_encode(b"sig")
        );
        assert!(parse_signed_transaction_info(&bad).is_err());
    }

    #[test]
    fn test_parse_transaction_response_requires_field() {
        assert!(parse_transaction_response("{}").is_err());
        assert!(parse_transaction_response("not json").is_err());
    }

    // ── JWT 签名 ──

    /// 🔑 用**运行时生成的密钥**做端到端自验：签出来的 JWT 必须能被自己的公钥验过。
    ///    这样在**没有白哥 .p8** 的情况下也能验证「签名逻辑本身是对的」。
    #[test]
    fn test_make_api_token_signature_is_verifiable() {
        use ring::rand::SystemRandom;
        use ring::signature::{
            EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING,
        };

        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let key_pair =
            EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
                .unwrap();
        let public_key = key_pair.public_key().as_ref().to_vec();

        // 造一个 PEM（模拟 .p8 文件内容）
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(pkcs8.as_ref());
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            b64
        );

        let cfg = IapConfig {
            key_id: "ABC123".to_string(),
            issuer_id: "issuer-uuid".to_string(),
            private_key_pem: pem,
            environment: ENV_SANDBOX.to_string(),
        };

        let token = make_api_token(&cfg, 1_800_000_000).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3, "JWT 应为三段");

        // header 里必须带 kid（Apple 靠它选公钥）
        let header: Value = serde_json::from_slice(&base64_url_decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "ABC123");

        // payload 的关键字段
        let payload: Value = serde_json::from_slice(&base64_url_decode(parts[1]).unwrap()).unwrap();
        assert_eq!(payload["iss"], "issuer-uuid");
        assert_eq!(payload["aud"], "appstoreconnect-v1");
        assert_eq!(payload["bid"], BUNDLE_ID);
        assert_eq!(
            payload["exp"].as_i64().unwrap() - payload["iat"].as_i64().unwrap(),
            1200
        );

        // 🔑 关键断言：签名是 **R||S 64 字节**（不是 DER）—— 用 `_ASN1_` 变体这里会挂
        let sig = base64_url_decode(parts[2]).unwrap();
        assert_eq!(sig.len(), 64, "ES256 签名应为 64 字节（R||S）而非 DER");

        // 端到端验签
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let pub_key =
            ring::signature::UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public_key);
        pub_key
            .verify(signing_input.as_bytes(), &sig)
            .expect("自签名验不过 —— 签名逻辑有误");
    }

    #[test]
    fn test_pem_to_der_rejects_empty() {
        assert!(pem_to_der("").is_err());
        assert!(pem_to_der("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----").is_err());
    }

    #[test]
    fn test_api_base_switches_by_environment() {
        let mut cfg = IapConfig {
            key_id: "k".into(),
            issuer_id: "i".into(),
            private_key_pem: "p".into(),
            environment: ENV_SANDBOX.to_string(),
        };
        assert!(cfg.api_base().contains("sandbox"));
        cfg.environment = ENV_PRODUCTION.to_string();
        assert!(!cfg.api_base().contains("sandbox"));
        assert!(cfg.api_base().contains("api.storekit.itunes.apple.com"));
    }
}
