//! 腾讯云 ASR（语音识别）— 句子识别 API
//!
//! 使用 TC3-HMAC-SHA256 签名调用 SentenceRecognition

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// TTS 与 ASR 共用的腾讯云配置
struct AsrConfig {
    secret_id: String,
    secret_key: String,
}

impl AsrConfig {
    fn from_env() -> Option<Self> {
        let secret_id = std::env::var("TENCENT_SECRET_ID").ok()?;
        let secret_key = std::env::var("TENCENT_SECRET_KEY").ok()?;
        if secret_id.is_empty() || secret_key.is_empty() {
            return None;
        }
        Some(Self {
            secret_id,
            secret_key,
        })
    }
}

/// 调用腾讯云 SentenceRecognition API
///
/// - `audio_base64`: base64 编码的 WAV 音频数据
/// - `engine`: 引擎类型，如 "16k_zh"（中文普通话）、"16k_en"（英文）
/// - `voice_format`: 音频格式，如 "wav"、"mp3"
pub async fn recognize(
    audio_base64: &str,
    data_len: usize,
    engine: &str,
    voice_format: &str,
) -> Result<String, String> {
    let config = match AsrConfig::from_env() {
        Some(c) => c,
        None => return Err("ASR 未配置".to_string()),
    };

    let service = "asr";
    let host = "asr.tencentcloudapi.com";
    let action = "SentenceRecognition";
    let version = "2019-06-14";
    let region = "ap-guangzhou";
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("time: {}", e))?
        .as_secs();

    // 1. 构建请求体
    let usr_audio_key = format!("coe_{}", timestamp);
    let body_obj = serde_json::json!({
        "ProjectId": 0,
        "SubServiceType": 2,
        "EngSerViceType": engine,
        "SourceType": 1,
        "VoiceFormat": voice_format,
        "UsrAudioKey": usr_audio_key,
        "Data": audio_base64,
        "DataLen": data_len,
    });
    let body = serde_json::to_string(&body_obj).map_err(|e| format!("json: {}", e))?;

    // 2. CanonicalRequest
    let canonical_uri = "/";
    let canonical_qs = "";
    let payload_hash = hex::encode(Sha256::digest(body.as_bytes()));
    let canonical_request = format!(
        "POST\n{}\n{}\ncontent-type:application/json\nhost:{}\n\ncontent-type;host\n{}",
        canonical_uri, canonical_qs, host, payload_hash
    );

    // 3. StringToSign
    let algorithm = "TC3-HMAC-SHA256";
    let date_str = format_timestamp_date(timestamp);
    let credential_scope = format!("{}/{}/tc3_request", date_str, service);
    let hashed_canonical = hex::encode(Sha256::digest(canonical_request.as_bytes()));
    let string_to_sign = format!(
        "{}\n{}\n{}\n{}",
        algorithm, timestamp, credential_scope, hashed_canonical
    );

    // 4. Signature
    let secret_date = hmac_sha256(
        format!("TC3{}", config.secret_key).as_bytes(),
        date_str.as_bytes(),
    );
    let secret_service = hmac_sha256(&secret_date, service.as_bytes());
    let secret_signing = hmac_sha256(&secret_service, "tc3_request".as_bytes());
    let signature = hex::encode(hmac_sha256(&secret_signing, string_to_sign.as_bytes()));

    // 5. Authorization
    let authorization = format!(
        "{} Credential={}/{}, SignedHeaders=content-type;host, Signature={}",
        algorithm, config.secret_id, credential_scope, signature
    );

    // 6. HTTP 请求（10s 超时）
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("client: {}", e))?;

    tracing::info!("ASR calling {} engine={} len={}", host, engine, data_len);
    let resp = client
        .post(format!("https://{}/", host))
        .header("Authorization", &authorization)
        .header("Content-Type", "application/json")
        .header("Host", host)
        .header("X-TC-Action", action)
        .header("X-TC-Timestamp", timestamp.to_string())
        .header("X-TC-Version", version)
        .header("X-TC-Region", region)
        .body(body)
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
            "ASR API error ({}): {}",
            status.as_u16(),
            resp_text
        ));
    }

    // 解析返回
    let resp_json: serde_json::Value =
        serde_json::from_str(&resp_text).map_err(|e| format!("json parse: {}", e))?;

    tracing::info!(
        "ASR full response: {}",
        serde_json::to_string(&resp_json).unwrap_or_default()
    );

    let result_text = resp_json["Response"]["Result"]
        .as_str()
        .ok_or_else(|| format!("ASR response missing Result field: {}", resp_text))?;

    Ok(result_text.to_string())
}

/// HMAC-SHA256 计算
fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// Unix timestamp → YYYY-MM-DD
fn format_timestamp_date(ts: u64) -> String {
    let secs = ts as i64;
    let days = secs / 86400;
    // 从 1970-01-01 开始
    let mut y = 1970i64;
    let mut d = days;
    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if d < days_in_year {
            break;
        }
        d -= days_in_year;
        y += 1;
    }
    let leap = is_leap(y);
    let month_days = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m = 0usize;
    for (i, &md) in month_days.iter().enumerate() {
        if d < md {
            m = i;
            break;
        }
        d -= md;
    }
    format!("{:04}-{:02}-{:02}", y, m + 1, d + 1)
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}
