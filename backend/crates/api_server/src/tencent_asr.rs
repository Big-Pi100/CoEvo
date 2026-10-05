//! 腾讯云 ASR（语音识别）— 句子识别 API
//!
//! 使用 TC3-HMAC-SHA256 签名调用 SentenceRecognition。
//!
//! 🔑 **签名与 HTTP 由 [`crate::tencent_sign`] 统一实现** —— 与邮件推送（`tencent_ses`）
//!    共用同一份 TC3 代码。本文件只负责「ASR 特有的部分」：请求体字段与 `Result` 解析。

const SERVICE: &str = "asr";
const HOST: &str = "asr.tencentcloudapi.com";
const ACTION: &str = "SentenceRecognition";
const VERSION: &str = "2019-06-14";
const REGION: &str = "ap-guangzhou";

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

    // 2–6. 签名 + HTTP —— **唯一实现**在 `crate::tencent_sign`
    //
    // 🔑 2026-10-05 重构：原本签名逻辑内联在本文件；新增「邮件推送」时
    //    发现它需要**完全相同**的 TC3 签名 ⇒ 抽到 `tencent_sign`，两处共用。
    //    判据：**同一口径只能有一份实现**（两份「都能跑」但只有一份对，
    //    差异藏在 canonical 串的换行里 —— 极难排查）。
    // ⚠️ 行为差异（有意）：`tencent_sign` 会检查 `Response.Error`，
    //    因此鉴权/参数类业务错误的报错**更准确**（原先会走到「缺 Result 字段」）。
    tracing::info!("ASR calling {} engine={} len={}", HOST, engine, data_len);
    let resp_json = crate::tencent_sign::call(crate::tencent_sign::Tc3Call {
        service: SERVICE,
        host: HOST,
        action: ACTION,
        version: VERSION,
        region: REGION,
        secret_id: &config.secret_id,
        secret_key: &config.secret_key,
        body: &body,
    })
    .await?;

    tracing::info!("ASR full response: {}", resp_json);

    let result_text = resp_json["Result"]
        .as_str()
        .ok_or_else(|| format!("ASR response missing Result field: {}", resp_json))?;

    Ok(result_text.to_string())
}
