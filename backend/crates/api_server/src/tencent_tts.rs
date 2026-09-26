//! Tencent Cloud Text-to-Speech (TTS) client — 实时语音合成
//!
//! 使用 WebSocket 协议连接腾讯云 TTS 服务，流式合成音频。
//!
//! API 文档: https://cloud.tencent.com/document/product/1073/94308
//!
//! # 🔴 当前无调用方（2026-09-26）—— 保留供后续功能扩展，不要删
//!
//! 词卡朗读 / 文章朗读 / chat 回复朗读**全部改为端侧 `flutter_tts`**（零成本、零延迟、
//! 文本不出端），因此本模块的两个调用方已被移除：
//! - `ws.rs` 的流式合成（原 chat 回复自动朗读）
//! - `routes.rs` 的 `POST /api/tts/preview` + `POST /api/tts/speak`
//!
//! **白哥定案（2026-09-26）：后端 TTS 全链保留**，标注「后续 **chat、AI 考核**功能扩展」。
//! AI 考核（口语评测等）如需服务端高质量语音合成，可直接复用本模块。
//! 决策依据：`docs/design/tts-unified-client-side-2026-09-26.md` §7.3
//!
//! ⚠️ 因是 `pub mod`，Rust 不会报 `dead_code` —— **若无此注释，后人会误以为它是死代码而删除**。
//!
//! # Usage
//!
//! ```ignore
//! let audio = tencent_tts::synthesize("你好，欢迎使用CoEvo学习助手。").await?;
//! // audio: Vec<u8> — MP3 音频数据
//! ```

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha1::Sha1;
use std::collections::BTreeMap;
use tokio_tungstenite::connect_async;

type HmacSha1 = Hmac<Sha1>;

/// TTS 配置
pub struct TtsConfig {
    app_id: String,
    secret_id: String,
    secret_key: String,
}

impl TtsConfig {
    /// 从环境变量加载配置
    pub fn from_env() -> Option<Self> {
        let app_id = std::env::var("TENCENT_APP_ID").ok()?;
        let secret_id = std::env::var("TENCENT_SECRET_ID").ok()?;
        let secret_key = std::env::var("TENCENT_SECRET_KEY").ok()?;
        if app_id.is_empty() || secret_id.is_empty() || secret_key.is_empty() {
            return None;
        }
        Some(Self { app_id, secret_id, secret_key })
    }

    /// 是否已配置
    fn is_configured() -> bool {
        Self::from_env().is_some()
    }
}

/// 文本分片：按句子边界切分，每片 ≤ max_chars
pub fn split_text(text: &str, max_chars: usize) -> Vec<String> {
    if text.chars().count() <= max_chars {
        return vec![text.to_string()];
    }

    let mut chunks = Vec::new();
    // 句子边界标点
    let sentence_enders = ['.', '!', '?', '\n', '。', '！', '？', '\r'];

    let mut start = 0;
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();

    while start < len {
        // 确定当前片的结束位置（不超过 max_chars）
        let end = (start + max_chars).min(len);
        if end == len {
            // 最后一片直接取剩余全部
            chunks.push(chars[start..end].iter().collect());
            break;
        }

        // 在 [start, end] 范围内找最后一个句子边界
        let mut split_pos = end;
        for i in (start..end).rev() {
            if sentence_enders.contains(&chars[i]) {
                split_pos = i + 1;
                break;
            }
        }
        // 如果找不到边界（整个片段没有句子结束符），硬切
        if split_pos == end {
            split_pos = end;
        }

        chunks.push(chars[start..split_pos].iter().collect());
        start = split_pos;
    }

    chunks
}

/// 生成腾讯云 TTS WebSocket 签名 URL
fn build_ws_url(config: &TtsConfig, text: &str, voice_type: Option<i32>, speed: Option<f32>) -> Result<String, String> {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("time error: {}", e))?
        .as_secs();
    let expired = timestamp + 300; // 5 分钟有效期

    let expired_str = expired.to_string();
    let timestamp_str = timestamp.to_string();
    let session_id = uuid::Uuid::new_v4().to_string();
    let codec = "mp3".to_string();

    // 构建请求参数（按字典序排列）
    let mut params: BTreeMap<&str, &str> = BTreeMap::new();
    params.insert("Action", "TextToStreamAudioWS");
    params.insert("AppId", &config.app_id);
    params.insert("Codec", &codec);
    params.insert("Expired", &expired_str);
    params.insert("SecretId", &config.secret_id);
    params.insert("SessionId", &session_id);
    params.insert("Timestamp", &timestamp_str);
    params.insert("Text", text);

    // 可选参数
    let vt_str;
    if let Some(vt) = voice_type {
        vt_str = vt.to_string();
        params.insert("VoiceType", &vt_str);
    }
    let sp_str;
    if let Some(sp) = speed {
        sp_str = sp.to_string();
        params.insert("Speed", &sp_str);
    }

    // 拼接 key=value 字符串（排除 Signature）— 用于签名
    // Text 用原始值参与签名
    let param_str: String = params
        .iter()
        .map(|(k, v)| format!("{}={}", k, v))
        .collect::<Vec<_>>()
        .join("&");

    // 签名原文: GET{host}{path}?{params}（所有参数用原始值）
    let sign_str = format!("GETtts.cloud.tencent.com/stream_ws?{}", param_str);

    // HMAC-SHA1 签名
    let mut mac = HmacSha1::new_from_slice(config.secret_key.as_bytes())
        .map_err(|e| format!("HMAC key error: {}", e))?;
    mac.update(sign_str.as_bytes());
    let signature = BASE64.encode(mac.finalize().into_bytes());

    // 构建最终 URL：Text URL 编码，Signature 最后
    let encoded_sig = urlencode(&signature);
    let encoded_text = urlencode(text);

    // 用编码后的 Text 替换原始 Text
    let url_param_str = params
        .iter()
        .map(|(k, v)| {
            if *k == "Text" {
                format!("Text={}", encoded_text)
            } else {
                format!("{}={}", k, v)
            }
        })
        .collect::<Vec<_>>()
        .join("&");

    let url = format!(
        "wss://tts.cloud.tencent.com/stream_ws?{}&Signature={}",
        url_param_str, encoded_sig
    );

    tracing::debug!("TTS WS URL (param_str): {}", &param_str.chars().take(200).collect::<String>());
    tracing::debug!("TTS signature: {}", signature);

    Ok(url)
}

/// 简单的 URL 编码（仅编码必要的特殊字符）
fn urlencode(s: &str) -> String {
    let mut result = String::with_capacity(s.len() * 2);
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(byte as char);
            }
            b' ' => result.push_str("%20"),
            _ => {
                result.push_str(&format!("%{:02X}", byte));
            }
        }
    }
    result
}

/// 合成一段文本为音频（MP3 格式）
///
/// 自动处理文本分片（每片 ≤600 字），多段合成后拼接返回。
/// - `voice_type`: 腾讯云音色 ID（None = 使用默认音色）
/// - `speed`: 语速 [-2, 6]（None = 正常语速）
/// 如果 TTS 未配置，返回 Ok(None)。
pub async fn synthesize(text: &str, voice_type: Option<i32>, speed: Option<f32>) -> Result<Option<Vec<u8>>, String> {
    let config = match TtsConfig::from_env() {
        Some(c) => c,
        None => {
            tracing::warn!("TTS not configured: TENCENT_SECRET_ID/KEY/APP_ID missing");
            return Ok(None);
        }
    };

    let chunks = split_text(text, 300);
    tracing::info!("TTS: splitting {} chars into {} chunks", text.chars().count(), chunks.len());

    let mut all_audio = Vec::new();

    for (i, chunk) in chunks.iter().enumerate() {
        if chunk.trim().is_empty() {
            continue;
        }
        tracing::debug!("TTS chunk {}/{}: {} chars", i + 1, chunks.len(), chunk.chars().count());
        match synthesize_chunk(&config, chunk, voice_type, speed).await {
            Ok(audio) => all_audio.extend(audio),
            Err(e) => {
                tracing::error!("TTS chunk {}/{} failed: {}", i + 1, chunks.len(), e);
            }
        }
    }

    if all_audio.is_empty() {
        return Err("TTS: all chunks failed — check server logs for details".to_string());
    }

    Ok(Some(all_audio))
}

/// 合成单个文本片段（≤600 汉字）
pub async fn synthesize_chunk(config: &TtsConfig, text: &str, voice_type: Option<i32>, speed: Option<f32>) -> Result<Vec<u8>, String> {
    use futures_util::StreamExt;

    let url = build_ws_url(config, text, voice_type, speed)?;

    // 连接 WebSocket
    let (mut ws_stream, _) = connect_async(&url)
        .await
        .map_err(|e| format!("WS connect failed: {}", e))?;

    let mut audio_data = Vec::new();
    let mut has_final = false;

    // 接收音频帧和控制消息
    loop {
        match tokio::time::timeout(std::time::Duration::from_secs(15), ws_stream.next()).await {
            Ok(Some(Ok(msg))) => match msg {
                tokio_tungstenite::tungstenite::Message::Binary(data) => {
                    // 二进制帧 = 音频数据（PCM 或 MP3）
                    audio_data.extend_from_slice(&data);
                }
                tokio_tungstenite::tungstenite::Message::Text(text) => {
                    // 文本帧 = JSON 控制消息
                    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
                        let code = json.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
                        if code != 0 {
                            let msg = json.get("message").and_then(|m| m.as_str()).unwrap_or("unknown");
                            // 非致命错误：最后一次可能已经收了部分音频，返回已有的
                            if audio_data.is_empty() {
                                return Err(format!("TTS error (code={}): {}", code, msg));
                            }
                            tracing::warn!("TTS non-zero code {}: {} (returning partial audio)", code, msg);
                            has_final = true;
                            break;
                        }
                        if json.get("final").and_then(|f| f.as_i64()) == Some(1) {
                            has_final = true;
                            break;
                        }
                    }
                }
                tokio_tungstenite::tungstenite::Message::Ping(data) => {
                    use futures_util::SinkExt;
                    let _ = ws_stream.send(tokio_tungstenite::tungstenite::Message::Pong(data)).await;
                }
                tokio_tungstenite::tungstenite::Message::Pong(_) => {}
                tokio_tungstenite::tungstenite::Message::Close(_) => break,
                _ => {}
            },
            Ok(Some(Err(e))) => {
                if audio_data.is_empty() {
                    return Err(format!("WS recv error: {}", e));
                }
                has_final = true;
                break;
            }
            Ok(None) => break,
            Err(_) => {
                // 超时
                if audio_data.is_empty() {
                    return Err("TTS timeout: no data received".to_string());
                }
                has_final = true;
                break;
            }
        }
    }

    if !has_final && audio_data.is_empty() {
        return Err("TTS: connection closed without final frame".to_string());
    }

    // 主动关闭 WS
    let _ = ws_stream.close(None).await;

    Ok(audio_data)
}
