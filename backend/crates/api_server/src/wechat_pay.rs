//! 微信支付 API v3 — Native 支付 + 回调验签（微信支付公钥模式）
//!
//! 使用 WECHATPAY2-SHA256-RSA2048 签名方案
//! 验签使用微信支付公钥（pub_key.pem）而非平台证书

use rsa::pkcs8::DecodePrivateKey;
use rsa::pkcs8::DecodePublicKey;
use rsa::{Pkcs1v15Sign, RsaPrivateKey, RsaPublicKey};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

/// 微信支付配置
pub struct WechatPayConfig {
    pub mch_id: String,
    pub api_v3_key: String,
    pub app_id: String,
    pub api_client_cert: String,
    pub cert_serial_no: String,
    pub pub_key_path: String,
    pub pub_key_id: String,
    pub notify_url: String,
}

impl WechatPayConfig {
    pub fn from_env() -> Option<Self> {
        let mch_id = std::env::var("WECHAT_MCH_ID").ok()?;
        let api_v3_key = std::env::var("WECHAT_API_V3_KEY").ok()?;
        let app_id = std::env::var("WECHAT_APP_ID").ok()?;
        let api_client_cert = std::env::var("WECHAT_API_CLIENT_CERT_PATH").ok()?;
        let notify_url = std::env::var("WECHAT_NOTIFY_URL").ok()?;
        let pub_key_path = std::env::var("WECHAT_PUB_KEY_PATH").ok()?;
        let pub_key_id = std::env::var("WECHAT_PUB_KEY_ID").ok()?;
        let cert_serial_no = std::env::var("WECHAT_CERT_SERIAL").ok()?;
        if mch_id.is_empty() || api_v3_key.is_empty() || app_id.is_empty() {
            return None;
        }
        Some(Self {
            mch_id,
            api_v3_key,
            app_id,
            api_client_cert,
            cert_serial_no,
            pub_key_path,
            pub_key_id,
            notify_url,
        })
    }

    fn load_private_key(&self) -> Result<RsaPrivateKey, String> {
        let pem_str = std::fs::read_to_string(&self.api_client_cert)
            .map_err(|e| format!("读取商户私钥失败: {}", e))?;
        RsaPrivateKey::from_pkcs8_pem(&pem_str).map_err(|e| format!("解析私钥失败: {}", e))
    }

    fn load_public_key(&self) -> Result<RsaPublicKey, String> {
        let content = std::fs::read_to_string(&self.pub_key_path)
            .map_err(|e| format!("读取微信支付公钥失败: {}", e))?;
        RsaPublicKey::from_public_key_pem(&content).map_err(|e| format!("解析公钥失败: {}", e))
    }
}

/// Native 下单响应
#[derive(Debug)]
pub struct NativeOrderResponse {
    pub prepay_id: String,
    pub code_url: String,
}

/// Native 支付下单
pub async fn native_order(
    config: &WechatPayConfig,
    out_trade_no: &str,
    description: &str,
    total_fee: i64,
    time_expire: &str,
) -> Result<NativeOrderResponse, String> {
    let url = "https://api.mch.weixin.qq.com/v3/pay/transactions/native";
    let body = serde_json::json!({
        "appid": config.app_id,
        "mchid": config.mch_id,
        "description": description,
        "out_trade_no": out_trade_no,
        "time_expire": time_expire,
        "notify_url": config.notify_url,
        "amount": { "total": total_fee, "currency": "CNY" },
    })
    .to_string();

    let authorization = sign_request(config, "POST", url, &body)?;

    tracing::info!("native_order: body={}", body);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("创建 HTTP 客户端失败: {}", e))?;

    let resp = client
        .post(url)
        .header("Authorization", &authorization)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("User-Agent", "CoEvo/0.1")
        .header("Wechatpay-Serial", &config.pub_key_id)
        .body(body)
        .send()
        .await
        .map_err(|e| format!("HTTP 请求失败: {}", e))?;

    let status = resp.status();
    let resp_text = resp
        .text()
        .await
        .map_err(|e| format!("读取响应失败: {}", e))?;

    tracing::info!(
        "native_order: status={} resp={}",
        status.as_u16(),
        resp_text
    );

    if !status.is_success() {
        return Err(format!(
            "微信支付 API 错误 ({}): {}",
            status.as_u16(),
            resp_text
        ));
    }

    let resp_json: serde_json::Value =
        serde_json::from_str(&resp_text).map_err(|e| format!("JSON 解析失败: {}", e))?;

    let code_url = resp_json["code_url"]
        .as_str()
        .ok_or_else(|| format!("响应缺少 code_url: {}", resp_text))?
        .to_string();
    let prepay_id = resp_json["prepay_id"]
        .as_str()
        .map(|s| s.to_string())
        .unwrap_or_default();

    Ok(NativeOrderResponse {
        prepay_id,
        code_url,
    })
}

/// 查询微信支付订单状态
///
/// 调用 WeChat `/v3/pay/transactions/out-trade-no/{out_trade_no}` API
/// 返回支付状态（SUCCESS / NOTPAY / CLOSED 等）
pub async fn query_order_status(
    config: &WechatPayConfig,
    out_trade_no: &str,
) -> Result<String, String> {
    let url = format!(
        "https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/{}?mchid={}",
        out_trade_no, config.mch_id
    );
    let authorization = sign_request(config, "GET", &url, "")?;

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("client: {}", e))?;

    let resp = client
        .get(&url)
        .header("Authorization", &authorization)
        .header("Accept", "application/json")
        .header("User-Agent", "CoEvo/0.1")
        .header("Wechatpay-Serial", &config.pub_key_id)
        .send()
        .await
        .map_err(|e| format!("HTTP: {}", e))?;

    let status = resp.status();
    let text = resp.text().await.map_err(|e| format!("读取响应: {}", e))?;

    if !status.is_success() {
        // 404 表示订单不存在（未支付），返回 NOTPAY
        if status.as_u16() == 404 {
            return Ok("NOTPAY".to_string());
        }
        return Err(format!("微信查询失败 ({}): {}", status.as_u16(), text));
    }

    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("JSON: {}", e))?;
    let trade_state = json["trade_state"].as_str().unwrap_or("NOTPAY").to_string();
    Ok(trade_state)
}

/// 生成 WECHATPAY2-SHA256-RSA2048 签名头
fn sign_request(
    config: &WechatPayConfig,
    method: &str,
    url: &str,
    body: &str,
) -> Result<String, String> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("时间错误: {}", e))?
        .as_secs();

    let nonce = uuid::Uuid::new_v4().to_string().replace('-', "");
    let nonce = &nonce[..32];

    let uri = url
        .trim_start_matches("https://api.mch.weixin.qq.com")
        .trim_start_matches("https://api2.mch.weixin.qq.com");

    let sign_str = format!("{}\n{}\n{}\n{}\n{}\n", method, uri, timestamp, nonce, body);

    tracing::info!(
        "sign_request: method={} uri={} timestamp={} nonce={} body_len={}",
        method,
        uri,
        timestamp,
        nonce,
        body.len()
    );

    let private_key = config.load_private_key()?;
    let hash = Sha256::digest(sign_str.as_bytes());
    let signature = private_key
        .sign_with_rng(
            &mut rand::thread_rng(),
            Pkcs1v15Sign::new::<Sha256>(),
            &hash, // Pkcs1v15Sign 要求传入预哈希后的摘要（32 字节）
        )
        .map_err(|e| format!("签名失败: {}", e))?;

    let signature_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &signature);

    tracing::info!("sign_request: signature_b64_len={} ok", signature_b64.len());

    Ok(format!(
        "WECHATPAY2-SHA256-RSA2048 mchid=\"{}\",nonce_str=\"{}\",timestamp=\"{}\",signature=\"{}\",serial_no=\"{}\"",
        config.mch_id, nonce, timestamp, signature_b64, config.cert_serial_no
    ))
}

/// 验证微信支付回调通知的签名（微信支付公钥模式）
///
/// 使用从商户平台下载的 pub_key.pem 验证签名
/// 返回回调请求体中的 event_type（如 "TRANSACTION.SUCCESS"）
pub fn verify_notify(
    config: &WechatPayConfig,
    wechatpay_signature: &str,
    wechatpay_timestamp: &str,
    wechatpay_nonce: &str,
    body: &str,
) -> Result<String, String> {
    let sign_str = format!("{}\n{}\n{}\n", wechatpay_timestamp, wechatpay_nonce, body);

    let public_key = config.load_public_key()?;

    let hash = Sha256::digest(sign_str.as_bytes());
    let sig_bytes = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        wechatpay_signature,
    )
    .map_err(|e| format!("解码签名失败: {}", e))?;

    public_key
        .verify(
            Pkcs1v15Sign::new::<Sha256>(),
            &hash, // 传入预哈希后的摘要
            &sig_bytes,
        )
        .map_err(|_| "签名验证失败".to_string())?;

    let json: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let event_type = json["event_type"]
        .as_str()
        .ok_or_else(|| "缺少 event_type".to_string())?
        .to_string();

    Ok(event_type)
}
