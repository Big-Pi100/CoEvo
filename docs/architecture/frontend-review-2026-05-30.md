# CoEvo 前端代码 Review + 用户场景分析

> 日期：2026-05-30
> 范围：`app/lib/` (43 文件, 12,646 行 Dart)

---

## 一、架构概览

```
app/lib/
├── main.dart               # 入口
├── app.dart                # GoRouter 路由 + ShellScaffold
├── api/                    # API 通信层 (WS + HTTP)
│   ├── api_config.dart     # 服务器地址 (--dart-define 注入)
│   ├── auth_client.dart    # 认证 API
│   └── chat_client.dart    # 聊天/卡片/复习 API (672 行)
├── models/
│   └── coevo_models.dart   # 数据模型 (ChatRequest, WsEvent, DueCard 等)
├── providers/
│   └── auth_provider.dart  # 全局认证状态
├── screens/
│   ├── auth_screen.dart     # 登录注册 (212 行)
│   ├── home_screen.dart     # 首页 - 科目选择 + 快速入口 (270 行)
│   ├── chat_screen.dart     # 对话主界面 (896 行, 拆分为 4 组件)
│   ├── chat/chat_input.dart         # 输入组件 (222 行)
│   ├── chat/chat_message_bubble.dart # 气泡组件 (80 行)
│   ├── chat/chat_plan_panel.dart     # 计划面板 (204 行)
│   ├── chat/chat_concept_dialog.dart # 概念确认弹窗 (141 行)
│   ├── review_screen.dart  # 复习 (936 行)
│   ├── card_list_screen.dart        # 卡片列表管理 (875 行)
│   ├── conversation_list_screen.dart # 历史对话 (355 行)
│   ├── reading_full_text_screen.dart # 全文阅读 (202 行)
│   ├── profile_screen.dart  # 个人中心 (1184 行)
│   ├── admin_screen.dart    # 管理后台 (1337 行)
│   ├── guardian_screen.dart # 家长端 (865 行)
│   ├── user_detail_screen.dart  # 用户详情
│   ├── skipped_list_screen.dart  # 跳过列表
│   └── k12_subject_screen.dart  # K12 科目
├── pipelines/              # 验证策略
│   ├── verification_strategy.dart
│   ├── pipeline_registry.dart
│   ├── general/verification_strategy.dart
│   ├── language/verification_strategy.dart
│   ├── language/grammar_strategy.dart
│   └── math/verification_strategy.dart
├── services/               # 语音/TTS
│   ├── tts_service.dart     (288 行)
│   ├── stt_service.dart
│   ├── stt_service_native.dart
│   ├── stt_service_web.dart
│   ├── audio_recorder.dart
│   └── sherpa_tts.dart
├── theme/
│   └── app_theme.dart
├── utils/
│   └── validators.dart
└── widgets/
    ├── graph_widget.dart    (982 行 - 读书数据图表)
    ├── skeleton.dart        (骨架屏)
    ├── empty_state.dart
    └── markdown_span_nodes.dart
```

---

## 二、用户场景与流程分析

### 2.1 核心用户旅程

```
登录 → 首页 → 选科目/选年级 → 进入对话 → 教学 → 复习
                           ↘ 自由对话 ↗       ↘ 卡片管理

首页入口:
  ├─ 开始对话（自由模式）
  ├─ 历史对话（继续之前）
  └─ 13 个科目网格（每个有年级选择）
       ├─ 语文 → K12 Reading 模式 → 阅读计划/课文/词卡
       └─ 其他 12 科 → K12 Structured 模式 → 结构化教学
```

### 2.2 对话流 (ChatScreen)

```
用户发消息 → WS → 后端 LLM 处理 → WS 返回 → 渲染
                                              ├─ 文本气泡 (chat_message_bubble)
                                              ├─ 计划更新 (chat_plan_panel)
                                              └─ 概念提取弹窗 (chat_concept_dialog)
```

**状态**: 31 个状态变量 + 3 个 stream subscription。当前为单页面大 StatefulWidget，已拆分 4 个组件。

### 2.3 复习流 (ReviewScreen)

```
Tab 1: 待复习队列 → 查看卡片 (正面→反面翻转) → 答题 → LLM 验证 → 评分
Tab 2: 按科目计划筛选 → 同上

流程:
  get_due_cards → 显示正面 → 翻转看背面 → 
    输入答案 → verify (LLM 出题) → judge (LLM 判题) → submit_review → FSRS
```

### 2.4 卡片管理 (CardListScreen)

```
全部卡片 → 按类型/科目/学段筛选 → 
  ├─ 点击进入复习
  ├─ 长按跳过
  └─ 查看详情（正面/背面/来源/复习历史）
```

---

## 三、用户需求与缺口分析

### P0 — 功能完整性问题

| 缺口 | 影响 | 原因 |
|:-----|:-----|:------|
| **无计划列表/进度展示** | 用户不知道学习计划状态 | 后端有 `GET /api/plans`，前端 profile_screen 未实现计划进度 |
| **订阅到期无优雅降级** | 到期后直接显示错误 | `_subscriptionDialogShown` 只弹一次对话框 |
| **WS 重连机制** | 断连后需刷新页面恢复 | 无自动重连逻辑 |
| **考试模式文字透明度** | 之前待办 (80%→20%) 未实现 | 需求已记录但未在前端实现 |

### P1 — 用户体验问题

| 问题 | 位置 | 建议 |
|:-----|:-----|:------|
| 画面加载异常 280 状态变量 | chat_screen.dart 和 review_screen.dart | 拆分为独立 Provider 管理状态 |
| 滚动加载翻倍偏移 | chat_screen.dart 加载历史对话 | offset 仅用 length 代替后端返回的 total |
| 无离线提示 | chat_screen.dart | WS 断开时用户无感知 |
| 复习页无空状态引导 | review_screen.dart | 无待复习卡片时显示空白页面 |
| 概念提取弹窗经常为空 | chat_concept_dialog.dart | 有时弹出后随即关闭，用户困惑 |
| "开始对话"入口和科目网格视觉分离 | home_screen.dart | 自由对话和结构化学习的关系不清晰 |
| 管理员页面 UI 不够优雅 | admin_screen.dart | 当前为纯功能性列表，缺视觉润色 |

### P2 — 技术债务

| 位置 | 问题 | 影响 |
|:-----|:-----|:------|
| review_screen.dart | 936 行单体文件，单组件 34 个状态变量 | 难以维护和测试 |
| review_screen.dart | _loadCards 和 _loadPlans 在每次 initState 都调用 | 重复加载 |
| chat_client.dart (672 行) | 所有 HTTP 和 WS 逻辑混在一起 | 单元测试困难 |
| graph_widget.dart (982 行) | 读书数据图表全部手写 canvas | 可维护性低 |
| guest_login 兼容 | login 时传 "guest" 密码 | 安全风险 |
| 无统一错误处理 | 各处 try-catch 分散 | 错误上报不统一 |

---

## 四、代码质量评估

| 维度 | 评分 | 说明 |
|:----|:----:|:------|
| 架构清晰度 | 7/10 | GoRouter + Riverpod 组合合理，但部分屏幕状态管理混乱 |
| 代码组织 | 6/10 | chat_screen 和 review_screen 过高，组件拆分不彻底 |
| 错误处理 | 5/10 | 分散式 try-catch，无统一错误处理中间件 |
| 注释完整性 | 8/10 | 关键逻辑有注释，API 文档较全 |
| 测试覆盖 | 4/10 | 前端 E2E 测试不足 |
| 性能 | 7/10 | WS 长连接合理，但 setState 频次较高 |
| 安全性 | 6/10 | token 存在内存中无持久化，guest_login 是遗留问题 |

---

## 五、建议路线图

### Phase A — 用户体验（短期可做）

1. **考试模式透明度** → 实现 80%→20% 的文字透明度修改（已有待办）
2. **空状态引导** → 复习页/卡片列表增加引导文案
3. **WS 状态提示** → 连接/断开/重连时给用户提示
4. **计划进度展示** → 在 profile 或主界面显示

### Phase B — 代码重构（中期）

1. **review_screen 拆分** → 拆为卡片翻转、答题、评分 3 个子组件
2. **chat_client 拆分** → WS 和 HTTP 分离
3. **统一错误处理** → 添加 Riverpod 错误 Provider

### Phase C — 功能扩展（远期）

1. **多端同步** → token 持久化到 SharedPreferences
2. **离线支持** → 缓存最近对话和卡片
3. **PWA 安装提示** → Web 平台渐进式 Web App
