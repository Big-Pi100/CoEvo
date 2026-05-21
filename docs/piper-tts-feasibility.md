# Piper TTS 集成可行性调研

> 日期：2026-05-21
> 目标：评估 Piper TTS 作为 CoEvo 离线高质量语音引擎的可行性
> 重点：中文能力、跨平台（Android/iOS/Web）、Flutter 集成路径

---

## 一、Piper 是什么

Piper 是一个轻量级神经网络 TTS 引擎，由 Rhasspy 团队开发（现由 Open Home Foundation 维护）。

```
GitHub: github.com/rhasspy/piper → 已归档，迁移至 OHF-Voice/piper1-gpl
License: MIT → GPL-3.0（fork 后）
核心: VITS 架构 + espeak-ng 音素化
模型格式: ONNX（跨平台部署）
```

核心优势：**模型小（2-80MB）、速度极快（手机 CPU 实时合成）、离线运行**。

---

## 二、中文模型质量

### 可用模型

| 模型 | 大小 | 质量 | 来源 |
|------|:----:|:----:|------|
| `zh_CN-huihui-base` | ~10MB | 可懂，机械感 | Piper 官方 |
| `zh_CN-huihui-medium` | ~20MB | 较清晰，仍偏机械 | Piper 官方 |
| `zh_CN-huihui-high` | ~50MB | 自然度较好 | Piper 官方 |
| 社区模型（如 VITS 训练） | 10-100MB+ | 参差不齐，部分优秀 | Hugging Face |

**结论：Piper 的中文模型可用，但音质介于"可懂"和"较自然"之间，不如云端 API（如火山引擎/Edge TTS）但远超系统 TTS。**

**关键优势**：纯中文文本不会有发音错误或崩溃问题（Piper 的 espeak-ng 音素化对中文支持成熟）。

---

## 三、跨平台集成方案

### 方案 A：原生 FFI（Android/iOS）

```mermaid
flowchart LR
    Flutter -->|dart:ffi| libpiper.so
    libpiper.so -->|ONNX Runtime| CPU
    CPU --> PCM音频 -->|audioplayers| 扬声器
```

**Android**：编译 `libpiper.so`（arm64-v8a），打包到 APK
**iOS**：编译 `libpiper.dylib`（arm64），注意 GPL-3.0 合规
**模型**：打包在 assets 中，或首次启动下载后缓存

**难度**：中。需要：
1. 编译 Piper C/C++ 库为各平台 so/dylib
2. 用 `dart:ffi` 封装 C API
3. 音频流处理（PCM → 播放）

### 方案 B：WASM（Web 端）

```mermaid
flowchart LR
    Flutter Web -->|package:js| piper-tts-web.js
    piper-tts-web.js -->|ONNX Runtime Web| WASM
    WASM --> PCM音频 -->|Web Audio API| 扬声器
```

**现有 NPM 包**：`@mintplex-labs/piper-tts-web`

```js
import * as tts from '@mintplex-labs/piper-tts-web';
const wav = await tts.predict({ text: "你好", voiceId: 'zh_CN-huihui-medium' });
const audio = new Audio(URL.createObjectURL(wav));
audio.play();
```

**Flutter Web 集成**：通过 `dart:js` / `package:js` 做 JS interop

**难度**：低。已有现成 JS 包，只需封装 Dart 接口。

### 方案 C：HTTP Server 桥接（所有平台）

在 Flutter app 内嵌一个微型 HTTP server，或边车进程暴露 HTTP API。

**不推荐**——增加延迟和复杂度，移动端不适合。

---

## 四、推荐路线

### 第一阶段：Web 端先行（1-2 天）

用 `piper-tts-web` NPM 包 + Flutter Web JS interop，先覆盖 Web 平台：

```
优势：
- 已有现成 NPM 包，零编译
- 验证模型质量后再投入原生集成
- Web 端也是主要使用场景之一

步骤：
1. 将 piper-tts-web 及其 WASM 资源嵌入 Flutter Web build
2. 写 Dart JS interop 封装层
3. 中文+英文模型缓存策略
4. 替换 TtsService 的 speak() 实现
```

### 第二阶段：原生 FFI（2-3 天）

Web 端验证通过后：

```
Android:
  交叉编译 libpiper.so → Flutter FFI
iOS:
  编译 libpiper.dylib → 注意 GPL-3.0 合规
模型加载:
  assets 打包 or 首次下载
```

### 第三阶段：中文模型优先，英文直接复用

```
TTS 策略：
  检测到中文 → Piper zh_CN 模型（安全、稳定）
  检测到纯英文 → 可继续用 Web Speech API（纯英文不崩）
  中英混合 → 全部走 Piper 中文模型（能读英文但带口音，不崩）
```

---

## 五、关键决策点

| 决策 | 选项 A | 选项 B | 推荐 |
|------|--------|--------|:----:|
| 中文模型 | Piper 官方 high | 社区训练模型 | 先官方，后探索社区 |
| Web 集成 | piper-tts-web NPM | 自编译 WASM | NPM 包（省时） |
| 原生集成 | FFI libpiper | 通道到 WebView | FFI（性能好） |
| 模型分发 | 打包 assets | 首次下载缓存 | 混合（小包 assets，大包下载） |
| GPL 合规 | GPL app 无所谓 | 需注意分发 | 确认后再推进 |

---

## 六、风险

| 风险 | 概率 | 影响 | 缓解 |
|------|:----:|:----:|------|
| 中文模型音质不达标 | 中 | 高 | 先评估样音，不行找社区模型或弃用 |
| ONNX Runtime Web 包体积 | 高 | 中 | onnxruntime-web ~10MB，可 code split |
| FFI 编译复杂度 | 中 | 中 | 依赖 Piper 的 C API 稳定性 |
| GPL-3.0 合规 | 低 | 中 | OHF-Voice fork 是 GPL，需法律确认 |
| Flutter Web JS interop 性能 | 低 | 低 | 仅做函数调用，开销可忽略 |

---

## 七、下一步

1. **试听样音**：访问 `rhasspy.github.io/piper-samples/`，评估 `zh_CN` 模型听起来能否接受
2. **Web prototype**：搭一个最小 Flutter Web 页面，用 `piper-tts-web` 合成"你好，这是一个测试"
3. **评估通过后**：开始 FFI 原生集成
