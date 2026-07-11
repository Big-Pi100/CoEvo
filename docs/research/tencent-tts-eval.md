# 腾讯云语音合成(TTS) CoEvo 集成评估报告

> 调研日期: 2026-06-14 | 基于腾讯云官方文档

---

## 一、产品概览

腾讯云语音合成（Text To Speech, TTS）提供从文本到自然语音的转换服务，支持 SSML 标记语言、多情感控制、多语言。

**官方文档**: https://cloud.tencent.com/document/product/1073/

---

## 二、三种 API 对比

| 特性 | 基础语音合成 | 实时语音合成 | 长文本语音合成 |
|:----|:-----------|:-----------|:------------|
| **接口** | `TextToVoice` | `TextToStreamAudioWS` | `CreateTtsTask` |
| **协议** | HTTP POST (同步) | **WebSocket (流式)** | HTTP POST (异步) |
| **文本上限** | 150 汉字 / 500 字母 | **600 汉字** / 1800 字母 | **10 万字符** |
| **延迟** | 中等 | **极低（边合成边返回）** | 较高（任务式） |
| **输出** | 完整音频 (base64) | 流式音频帧 + 逐字时间戳 | 下载链接 |
| **适用场景** | 短文本播报 | ✅ **AI 对话、语音助手** | 有声书、新闻播报 |
| **Flutter SDK** | ❌ 无 Flutter 封装 | ✅ 有 Flutter 插件 | ❌ 无 Flutter 封装 |

### 推荐：实时语音合成 (WebSocket)

对于 CoEvo 的 AI 对话场景，**实时语音合成**最合适：
- 流式返回，边合成边播放，延迟低
- 支持逐字时间戳（可用于字幕同步）
- 600 汉字上限足够一次回复的播报

---

## 三、实时语音合成 详细说明

### 3.1 连接方式

```
WebSocket URL:
wss://tts.cloud.tencent.com/stream_ws?Action=TextToStreamAudioWS&AppId=...&SecretId=...&Text=...&Signature=...
```

所有参数拼接到 URL 中，通过 HMAC-SHA1 签名认证。

### 3.2 核心参数

| 参数 | 必填 | 说明 |
|:----|:----|:-----|
| `Text` | ✅ | 合成文本，中文 ≤600字，英文 ≤1800字母 |
| `VoiceType` | ❌ | 音色 ID（默认 0，推荐精品音色） |
| `Volume` | ❌ | 音量 [-10, 10]，默认 0 |
| `Speed` | ❌ | 语速 [-2, 6]，默认 0 (1.0x) |
| `Codec` | ✅ | 音频格式：`pcm` 或 `mp3` |
| `SampleRate` | ❌ | 采样率：24000/16000/8000 |
| `EnableSubtitle` | ❌ | 是否启用逐字时间戳 |
| `EmotionCategory` | ❌ | 情感控制（多情感音色适用） |

### 3.3 长文本处理策略

实时 TTS 单次上限 600 汉字。对于 LLM 超长回复，采用**分片合成**策略：

```
LLM 回复（如 2000 字）
  → 按句子/标点切分 ≤600 字片段
  → 片段1 → WS 连接1 → 音频流1
  → 片段2 → WS 连接2 → 音频流2
  → ... 
  → 客户端拼接播放（连续无间隙）
```

**切分规则**：
- 以句号/问号/感叹号/换行为自然边界
- 每个片段 ≤600 汉字
- 最后一段不足 600 字直接合成
- 音频格式统一（pcm/mp3），客户端顺序播放

### 3.3 认证方式

腾讯云 API 密钥对:
- **SecretId**: 密钥 ID
- **SecretKey**: 密钥 Key
- 签名算法: HMAC-SHA1 → Base64 → URL Encode

### 3.4 响应格式

WebSocket 返回两种帧：
- **binary 帧**: PCM/MP3 音频数据
- **text 帧**: JSON 控制信息（含时间戳）

```json
// 合成中
{"code":0, "final":0, "result":{"subtitles":[
    {"Text":"欢","BeginTime":250,"EndTime":570,"Phoneme":"huan1"},
    {"Text":"迎","BeginTime":570,"EndTime":770,"Phoneme":"ying2"}
]}}

// 合成结束
{"code":0, "final":1, "result":{"subtitles":null}}
```

---

## 四、音色与价格

### 4.1 音色分类

| 类别 | 价格水平 | 推荐用途 |
|:----|:--------|:--------|
| **精品/基础音色** | 最便宜 | ✅ **CoEvo 主力** |
| 大模型音色 | 中等 | 需要更自然效果时 |
| 超自然大模型音色 | 最贵 | 高质量播客场景 |

### 4.2 计费方式

| 计费项 | 精品音色 | 大模型音色 | 超自然大模型 |
|:------|:--------|:----------|:-----------|
| **免费额度** | 800 万字符（一次性） | 10 万字符 | 2 万字符 |
| **后付费** | **0.3 元/万字符** | 1.2 元/万字符 | 6.5 元/万字符 |
| **预付费（最低）** | 0.15 元/万字符 | 0.4 元/万字符 | 4.8 元/万字符 |

> 💡 **成本估算**：按精品音色 0.3元/万字符计算，假设平均每条回复 100 字，10000 次对话 ≈ 10000×100 = 100万字符 ≈ **30 元**。

---

## 五、CoEvo 集成方案分析

### 方案 A：后端 Rust 直连 WebSocket（推荐）

```
CoEvo Backend (Rust/axum)
  └── LLM 回复文本
  └── connect wss://tts.cloud.tencent.com/stream_ws
  └── 接收流式音频 → 转发给前端
  └── 前端音频播放 + 字幕同步
```

**优点**：
- 现有架构无需额外服务
- 可控性强（可做缓存、限流）
- 使用 tokio-tungstenite 实现 WebSocket 客户端

**缺点**：
- 需实现 HMAC-SHA1 签名（Rust 现有 sha2/hmac crate）
- 需处理音频流中转

### 方案 B：前端 Flutter SDK 直连

```
Flutter Web App
  └── TTSController.synthesize(text)
  └── 返回 Uint8List 音频
  └── 直接播放
```

**优点**：
- 不需要后端中转
- Flutter 插件原生支持

**缺点**：
- Flutter Web 不支持原生音频解码
- SecretId/SecretKey 暴露在前端（不安全）
- 实时流式合成可能不支持 Web 端

### 方案 C：混合架构

```
LLM 回复 → Rust 后端 → 腾讯云 TTS WebSocket
                        → MP3 音频 → 前端播放
```

前端通过 HTTP/WS 从后端获取音频流，后端作为透明代理。

---

## 六、腾讯云 ASR（语音识别）调研

### 6.1 为什么换掉讯飞 STT

| 对比项 | 讯飞 STT | 腾讯云 ASR |
|:------|:--------|:----------|
| **协议** | 私有 SDK，依赖 Native 端 | **WebSocket 标准协议**，全平台通用 |
| **Web 支持** | ❌ 需要原生封装 | ✅ Flutter Web 可直接对接后端代理 |
| **签名** | `IFLYTEK_API_KEY` + `IFLYTEK_API_SECRET` | `SecretId` + `SecretKey`，HMAC-SHA1 |
| **免费额度** | 有限 | 实时 5 小时/月，一句话 5000 次/月 |
| **后付费** | 单价不详 | **3.2 元/小时**（标准版后付费） |
| **实时率** | 1:1 实时率 | 1:1 实时率（每 200ms 发 200ms 音频） |

**核心优势**: 用腾讯 ASR 替换讯飞后，TTS + ASR 统一使用腾讯云，两套服务共享同一组 API 密钥，环境变量简化。

### 6.2 实时语音识别 API

**连接地址**:
```
wss://asr.cloud.tencent.com/asr/v2/<AppId>?secretid=xxx&timestamp=xxx&signature=xxx
```

**认证**: 与 TTS 一致的 HMAC-SHA1 签名机制

**音频参数**:
| 参数 | 值 |
|:----|:---|
| 采样率 | 16000Hz |
| 采样精度 | 16 bit |
| 声道 | 单声道 |
| 编码 | PCM / WAV / MP3 / Opus |
| 发送间隔 | 每 200ms 发 200ms 数据 |

**响应格式**（流式 JSON）:
```json
{"code":0,"voice_id":"xxx","result":{
    "slice_type":1,           // 0=开始, 1=中间, 2=结束
    "voice_text_str":"今天天气",  // 识别文本
    "word_list":[{"word":"今天","start_time":0,"end_time":500,"stable_flag":0}, ...]
}}
```

**语言支持**: 中文、英文、粤语、日语、韩语、多语种大模型（自动识别 15+ 语言）

### 6.3 与讯飞 STT 的集成差异

| 方面 | 讯飞 (当前) | 腾讯云 (待迁移) |
|:----|:-----------|:--------------|
| **SDK 方式** | Native SDK（Android/iOS 各自集成） | Rust 后端 WS 代理 |
| **前端集成** | `stt_service_native.dart` + `stt_service_web.dart` | 统一走后端 WS 中转 |
| **Flutter Web** | ❌ 不支持（只有文本输入桩） | ✅ 通过后端桥接支持 |
| **延迟** | 低（直连） | 略高（多一跳），但可控 |
| **并发限制** | 未知 | 默认 200 路 |

### 6.4 迁移建议

建议在 Rust 后端新增统一的音频处理模块，同时承载：
- **TTS**: 接收 LLM 回复文本 → 调用腾讯云 TTS WS → 返回音频给前端
- **ASR**: 接收前端录音流 → 转发给腾讯云 ASR WS → 返回识别文本给 LLM

```
┌─ 前端 ───────────────────────────────────┐
│  录音 → WebSocket → 后端                   │
│  播放 ← 音频流 ← 后端                      │
└───────────────────────────────────────────┘
         ↕  WebSocket 中转
┌─ 后端 ───────────────────────────────────┐
│  ASR 代理: 前端音频 → 腾讯云 ASR → 文字     │
│  TTS 代理: LLM 文字 → 腾讯云 TTS → 音频     │
└───────────────────────────────────────────┘
         ↕
┌─ 腾讯云 ─────────────────────────────────┐
│  ASR / TTS 服务                            │
└───────────────────────────────────────────┘
```

## 七、代码影响范围

### 7.1 后端改动清单

| 文件 | 改动 | 行数估算 |
|:----|:----|:--------|
| **新建** `backend/crates/api_server/src/tencent_tts.rs` | 腾讯云 TTS 客户端：HMAC-SHA1 签名、WS 连接、音频接收、文本分片 | ~200 行 |
| `backend/crates/api_server/src/lib.rs` | 添加 `pub mod tencent_tts;` | 1 行 |
| `backend/crates/api_server/src/ws.rs` | LLM 回复完成后调 TTS 合成，`done` 消息附加 `audio` 字段 | ~30 行 |
| `backend/crates/api_server/Cargo.toml` | 新增 `hmac` + `sha1`（已有 `base64` 0.22、`sha2` 0.10 可复用） | 2 行 |

**不需要动的**：
- `llm.rs` — LLM 流程独立
- `main.rs` — `dotenvy::dotenv()` 已自动加载所有 env
- `.env` — 已含 `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY` / `TENCENT_APP_ID`
- 后端不存在 STT 代码（讯飞集成是纯前端 SDK）

### 7.2 前端改动清单

| 文件 | 改动 | 行数估算 |
|:----|:----|:--------|
| `app/lib/models/coevo_models.dart` | `WsEvent` 类增加 `String? audio` 字段 | 2 行 |
| `app/lib/screens/chat_screen.dart` | `done` 消息中解码 audio 并用 `audioplayers` 播放 | ~20 行 |

**不需要动的**：`flutter_tts`（保留作降级）、`sherpa_tts`（备选）、`pubspec.yaml`（`audioplayers` 已有）

### 7.3 依赖分析

| 依赖 | 状态 | 用途 |
|:----|:----|:----|
| `base64` 0.22 | ✅ 已有 | Base64 编解码 |
| `sha2` 0.10 | ✅ 已有 | SHA-256（腾讯云不用） |
| `hmac` | ❌ 需新增 | HMAC-SHA1 签名 |
| `sha1` | ❌ 需新增 | SHA-1 哈希 |
| `tokio-tungstenite` 0.21 | ⚠️ 仅在 dev-deps | 需提为正式依赖 |
| `audioplayers` 6.1.0 | ✅ 已有（前端） | 音频播放 |

### 7.4 架构图

```
WS 连接 (用户 → 后端)
  │
  ├── 用户消息 → LLM 流式生成
  │   ├── "type":"token", "content":"..." → 前端文本
  │   └── LlmEvent::Done(reply)
  │       └── tencent_tts::synthesize(reply)
  │           ├── ≤600字 → 1 次 WS 连接
  │           ├── >600字 → 按句子分片 → 多次 WS 连接 → 拼接
  │           └── base64(audio) → "done": {reply, audio}
  │
  └── 前端 done → 显示文本 + audioplayers 播放音频
```

### 7.5 与讯飞 STT 的关系

| 服务 | 厂商 | 用途 | 当前状态 |
|:----|:----|:----|:--------|
| **STT** (语音识别) | 讯飞 → **腾讯云 ASR** | 用户语音→文字 | 🔄 待迁移 |
| **TTS** (语音合成) | **腾讯云 TTS** | AI 回复→语音 | 🔜 待集成 |

> 迁移到腾讯云后统一使用 `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY`，
> 不再需要 `IFLYTEK_APPID`、`IFLYTEK_API_KEY`、`IFLYTEK_API_SECRET`。

## 八、建议优先级

1. **P1**: 集成腾讯云实时语音合成 TTS（Rust 后端 WS 代理）
   - LLM 回复按句子分片（≤600 汉字），逐段合成
   - 音频流转发前端播放

2. **P2**: 集成腾讯云实时语音识别 ASR（Rust 后端 WS 代理）
   - 前端录音 → 后端中转 → 腾讯云 ASR → 文字 → LLM
   - Flutter Web 语音输入正式可用（当前只有文本输入）

3. **P3**: 前端音频播放 + 录音组件
   - Web Audio API 播放 / MediaRecorder 录音
   - 字幕同步、播放控制

4. **P4**: 缓存策略
   - TTS 结果缓存减少 API 调用
   - 常用短语/课文的 ASR 热词表优化
