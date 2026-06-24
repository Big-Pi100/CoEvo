# 变更记录 2026-06-24

## 概述

今天的改动涉及前端 Flutter 和后端 Rust。变更已通过 `git stash push -m "0624-recovery"` 暂存，可随时恢复：

```bash
git stash pop stash@{0}
```

## 已修改文件（18 个）

### 前端 Flutter（15 个）

| 文件 | 改动内容 |
|------|---------|
| `app/pubspec.yaml` | `markdown_widget: ^2.3.2` → `flutter_markdown_plus: ^1.0.3` |
| `app/lib/app.dart` | 删 `/auth` 路由；redirect 简化为直接通过；`initialLocation` 改为 `/`；新增 `path: '/'` redirect 到 `/home` |
| `app/lib/screens/auth_screen.dart` | **已删除**（不再需要独立认证页面）|
| `app/lib/screens/home_screen.dart` | 新增 `_initAuth()`：等待 auth restore → 检查退出登录标记 → 自动 trial/start 或显示 ClaimDialog；新增 loading 状态 |
| `app/lib/screens/chat_screen.dart` | 3 处 `context.go('/auth')` → `context.go('/')`；`tts_audio` 事件加引擎偏好检查；移除流式 `debugPrint` |
| `app/lib/screens/profile_screen.dart` | `context.go('/auth')` → `context.go('/')`；分享链接 `/app/auth?ref=` → `/?ref=` |
| `app/lib/screens/achievements_screen.dart` | `ref.listen` → `ref.listenManual`（Riverpod 2.6.1 兼容）|
| `app/lib/screens/review_screen.dart` | `SingleTickerProviderStateMixin` → `TickerProviderStateMixin`；TabController 初始长度 3，_loadPlans 完成后动态重建 |
| `app/lib/screens/chat/chat_input.dart` | JS `__coeStart` 加 `.catch()`；`__coeStop` 加空检查；`_startRecording` 加 try-catch；`_exitVoiceMode` 清 `_isTranscribing` |
| `app/lib/services/tts_service.dart` | `togglePlay` 缓存路径前检查 `tts_engine` 偏好，非 tencent 走原生 |
| `app/lib/widgets/markdown_span_nodes.dart` | 替换 import 为 `flutter_markdown_plus`；MarkdownWidget → MarkdownBody；新增表格提取逻辑（`_TableSegment`、`_splitBlockLevel`、`_renderMarkdownTable`、`_splitTableRow`）；单元格支持 `**bold**` 和 `\(...\)` 公式 |
| `app/lib/widgets/graph_widget.dart` | 新增 8 色调色板；坐标轴箭头/刻度线/网格虚线；`pendingLabels` 延迟绘制 + 半透明背景 |
| `app/lib/widgets/achievement_overlay.dart` | `SingleTickerProviderStateMixin` → `TickerProviderStateMixin` |
| `app/lib/api/auth_client.dart` | 新增 `trialStart()` + `trialClaim()` API 方法 |
| `app/lib/providers/auth_provider.dart` | 新增 `trialStart()`、`trialClaim()`、`isTrialAccount()`、`isClaimed()`；`logout()` 设置 `coevo_show_login` 标记 |

### 后端 Rust（5 个）

| 文件 | 改动内容 |
|------|---------|
| `backend/crates/api_server/src/plan_handler.rs` | domain 回退（`pipeline_domain` fallback 到 `domain`）；badge 模糊匹配（`**...✅ 已完成` 快速路径）|
| `backend/crates/api_server/src/routes.rs` | 去掉对话列表的 `"K12: "` 前缀 |
| `backend/crates/api_server/src/ws.rs` | TTS 本地原生时跳过云端合成（`voice_type.is_none()` return）|
| `backend/crates/chat_engine/src/concept_extractor.rs` | UTF-8 panic 修复（`[..60]` → `char_indices().nth(60)`）|
| `backend/prompts/plan/general/creation.md` | 金字塔原则替换硬编码数量约束 |

## 新增文件（3 个，未跟踪）

| 文件 | 说明 |
|------|------|
| `backend/crates/api_server/src/trial_handler.rs` | `POST /api/trial/start` + `PUT /api/trial/claim` |
| `backend/crates/api_server/src/campaign_member_handler.rs` | `POST /api/campaign/join` 入会 API |
| `app/lib/widgets/claim_dialog.dart` | 临时账户认领弹窗（登录/注册），与 auth_screen 逻辑一致 |

## 删除文件（1 个）

| 文件 | 说明 |
|------|------|
| `app/lib/screens/auth_screen.dart` | 不再需要独立认证页面，认证移到 HomeScreen |

## 回滚方法

```bash
# 恢复所有改动
git stash pop stash@{0}

# 放弃所有改动（不可逆）
git stash drop stash@{0}
```
