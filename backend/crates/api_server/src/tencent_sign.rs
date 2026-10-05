//! 腾讯云 API 3.0 公共调用层 —— TC3-HMAC-SHA256 签名 + HTTP POST
//!
//! # 为什么要有这个模块（而不是各写一份）
//!
//! ASR（[`crate::tencent_asr`]）与邮件推送（[`crate::tencent_ses`]）都要调腾讯云 API，
//! 签名算法**完全相同**（TC3-HMAC-SHA256），只有 `service` / `host` / `action` /
//! `version` / `region` 这几个**标识字段**不同。
//!
//! 🔴 **签名只能有一份实现**：本项目在「文本断言」上已经踩过
//!    「同一口径两份实现 ⇒ 修一处漏一处」的坑；签名算法更隐蔽 ——
//!    两份都「看起来能跑」，但只有一份对（差异藏在 canonical 串的某个换行里）。
//!    ⇒ 收敛到此处，`tencent_asr` 与 `tencent_ses` 都调这里。
//!
//! # 签名格式（与原 `tencent_asr` 内联实现**逐字一致**）
//!
//! `SignedHeaders=content-type;host` —— 刻意**不含** `x-tc-action`。
//! 腾讯云官方示例把 `x-tc-action` 也签进去，但 TC3 规范只要求
//! 「`host` + `content-type` 必签，其余自定」⇒ 两种都能通过校验。
//! 🔑 保持与既有实现（ASR，已在生产跑通）逐字一致，避免「换个接口就莫名失败」。
//!
//! # 🔴 与旧实现的一处**有意改进**：检查 `Response.Error`
//!
//! 旧 `tencent_asr` 只查 HTTP 状态码 ⇒ **业务错误会被当成成功**
//! （腾讯云很多错误是 HTTP 200 + `{"Response":{"Error":{...}}}`）。
//! ASR 侧因为要取 `Response.Result`，缺字段会顺带报错；但**邮件推送不能靠这个兜底** ——
//! 若发信失败被当成成功，用户会一直等一封永远不来的验证码（「静默失效」）。
//! ⇒ 本模块统一检查 `Response.Error` 并返回 `Err`。

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// 一次腾讯云 API 调用所需的全部信息。
pub struct Tc3Call<'a> {
    /// 签名用服务名，如 `"asr"` / `"ses"`。
    pub service: &'a str,
    /// 接口域名，如 `"ses.tencentcloudapi.com"`。
    pub host: &'a str,
    /// 接口名，如 `"SendEmail"`。
    pub action: &'a str,
    /// 接口版本，如 `"2020-10-02"`。
    pub version: &'a str,
    /// 地域，如 `"ap-guangzhou"`。
    pub region: &'a str,
    pub secret_id: &'a str,
    pub secret_key: &'a str,
    /// 请求体 JSON 的**紧凑字符串**。
    ///
    /// 🔴 它同时是「实际发送的 body」与「参与签名的 payload」——
    ///    两者必须是**同一个字符串**（分别序列化两次会因字段顺序/空格不同而签名失败）。
    pub body: &'a str,
}

/// 发起调用，成功时返回 `Response` 对象（已从 `{"Response": {...}}` 外层取出）。
///
/// 失败一律 `Err(String)`，其中必含腾讯云的 `Error.Code`（便于归因：
/// `InvalidTemplateID` / `NotAuthenticatedSender` / `InsufficientBalance` …）。
///
/// ⚠️ **超时 10 秒** —— 与旧 ASR 实现一致。调用方（路由层）应把失败**如实**处理，
/// 不要把 `Err` 吞掉当成成功（那正是「静默失效」）。
pub async fn call(req: Tc3Call<'_>) -> Result<serde_json::Value, String> {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("time: {}", e))?
        .as_secs();

    // ── 1. CanonicalRequest ──
    // 格式（逐字对齐旧实现）：
    //   POST \n / \n <空 query> \n content-type:application/json \n host:<host> \n \n content-type;host \n <sha256(body)>
    let canonical_request = format!(
        "POST\n/\n\ncontent-type:application/json\nhost:{}\n\ncontent-type;host\n{}",
        req.host,
        hex::encode(Sha256::digest(req.body.as_bytes()))
    );

    // ── 2. StringToSign ──
    const ALGORITHM: &str = "TC3-HMAC-SHA256";
    let date_str = format_timestamp_date(timestamp);
    let credential_scope = format!("{}/{}/tc3_request", date_str, req.service);
    let string_to_sign = format!(
        "{}\n{}\n{}\n{}",
        ALGORITHM,
        timestamp,
        credential_scope,
        hex::encode(Sha256::digest(canonical_request.as_bytes()))
    );

    // ── 3. Signature（四级派生密钥）──
    let secret_date = hmac_sha256(
        format!("TC3{}", req.secret_key).as_bytes(),
        date_str.as_bytes(),
    );
    let secret_service = hmac_sha256(&secret_date, req.service.as_bytes());
    let secret_signing = hmac_sha256(&secret_service, b"tc3_request");
    let signature = hex::encode(hmac_sha256(&secret_signing, string_to_sign.as_bytes()));

    // ── 4. Authorization ──
    let authorization = format!(
        "{} Credential={}/{}, SignedHeaders=content-type;host, Signature={}",
        ALGORITHM, req.secret_id, credential_scope, signature
    );

    // ── 5. HTTP ──
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("client: {}", e))?;

    tracing::info!("Tencent API calling {} action={}", req.host, req.action);
    let resp = client
        .post(format!("https://{}/", req.host))
        .header("Authorization", &authorization)
        .header("Content-Type", "application/json")
        .header("Host", req.host)
        .header("X-TC-Action", req.action)
        .header("X-TC-Timestamp", timestamp.to_string())
        .header("X-TC-Version", req.version)
        .header("X-TC-Region", req.region)
        .body(req.body.to_string())
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {}", e))?;

    let status = resp.status();
    let resp_text = resp
        .text()
        .await
        .map_err(|e| format!("read response: {}", e))?;

    if !status.is_success() {
        return Err(format!(
            "{} API HTTP {}: {}",
            req.service,
            status.as_u16(),
            resp_text
        ));
    }

    let resp_json: serde_json::Value =
        serde_json::from_str(&resp_text).map_err(|e| format!("json parse: {}", e))?;

    let resp_obj = resp_json
        .get("Response")
        .cloned()
        .unwrap_or(serde_json::Value::Null);

    // 🔴 业务错误（HTTP 200 但 Response.Error 非空）—— 必须显式失败，见文件头说明。
    if let Some(err) = resp_obj.get("Error") {
        let code = err
            .get("Code")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown");
        let msg = err.get("Message").and_then(|v| v.as_str()).unwrap_or("");
        return Err(format!("{} API error {}: {}", req.service, code, msg));
    }

    Ok(resp_obj)
}

/// HMAC-SHA256 计算。
fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// Unix timestamp → `YYYY-MM-DD`（**UTC**）。
///
/// 🔑 用 `chrono` 而不是手写年月日换算：手写版本要自己处理闰年与月长，
///    错一天就表现为「签名偶尔失败」—— 极难排查。`chrono` 已在依赖内（0.4.44）。
fn format_timestamp_date(ts: u64) -> String {
    let secs = ts.min(i64::MAX as u64) as i64;
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|dt| dt.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 日期换算的**边界**必须逐个钉住（闰年 / 跨年 / 纪元起点）。
    /// 🔑 期望值独立来源：这些是常识日期，不是「跑一遍看看得到什么」。
    #[test]
    fn test_timestamp_date_boundaries() {
        assert_eq!(format_timestamp_date(0), "1970-01-01", "纪元起点");
        // 2024 是闰年 → 2 月有 29 天
        assert_eq!(format_timestamp_date(1_709_164_800), "2024-02-29", "闰日");
        assert_eq!(
            format_timestamp_date(1_735_689_599),
            "2024-12-31",
            "跨年前一秒"
        );
        assert_eq!(
            format_timestamp_date(1_735_689_600),
            "2025-01-01",
            "跨年后一秒"
        );
        // 期望值由 Python `datetime` 独立算出，**不是**跑本函数得到的
        // （判据：期望值必须独立 —— 否则只是「和我上次跑的一样」）
        assert_eq!(
            format_timestamp_date(1_791_158_400),
            "2026-10-05",
            "本年某日"
        );
    }

    /// HMAC-SHA256 的**标准测试向量**（RFC 4231 · Test Case 2）。
    ///
    /// 🔑 期望值是 RFC 原文，不是我跑出来的 —— 这样它才能真正证明
    ///    「实现没被改动」，而不是「实现和我上次跑的一样」。
    #[test]
    fn test_hmac_sha256_rfc4231_case2() {
        let out = hex::encode(hmac_sha256(b"Jefe", b"what do ya want for nothing?"));
        assert_eq!(
            out, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            "HMAC-SHA256 与 RFC 4231 测试向量不符 ⇒ 签名会全线失败"
        );
    }
}
