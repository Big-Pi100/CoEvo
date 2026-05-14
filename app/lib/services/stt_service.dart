/// 语音识别服务 — 条件导出
///
/// 原生平台（Android/iOS/HarmonyOS）：使用原生 MediaRecorder + VPS 讯飞识别
/// Web 平台：使用文本输入替代（Web Speech API 后续集成）
export 'stt_service_web.dart' if (dart.library.io) 'stt_service_native.dart';
