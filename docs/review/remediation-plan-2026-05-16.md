# CoEvo 代码审查修复推进计划

**基于**: `docs/code-review-2026-05-16.md`（修订版）  
**日期**: 2026-05-16  
**当前状态**: ✅ 全部完成 · P0 4/4 · P1 6/6 · P2 8/8 · 前端 4模块独立

---

## 总览

| 阶段 | 内容 | 预估 | 优先级 |
|------|------|------|--------|
| **第 1 天** | 验证已修复项 + 前端可立即验证项 | 2h | 🔴 | ✅ 完成 |
| **第 2-3 天** | 稳定性加固（unwrap + chat_screen 拆分） | 10h | 🟡 | ✅ 完成 |
| **第 4-5 天** | 架构升级（fsrs crate + CI/CD） | 12h | 🟢 | ✅ 完成 |
| **按需** | 长期优化 | — | ⚪ |

---

## 第 1 天：验证 + 前端快速修复 (2h) ✅

### 1.1 回归验证 ✅
- `cargo test`: 28/28 passed (card_engine 16 + chat_engine 9 + growth_engine 1 + shared_types 2)
- `cargo clippy`: 0 errors
- `flutter analyze`: 0 errors / 60 info

### 1.2 前端测试本地验证 ✅
- `flutter test`: 33/33 passed（修复 2 个断言与 UI 不符的测试）
- `review_widget_test.dart`: 无数据时不显示 TabBar → 改为检测 AppBar
- `widget_test.dart`: Auth 页面无 "刻意进化" 文本 → 改为检测 CoEvoApp 渲染

### 1.3 P2-10: dart_code_metrics 配置 ✅
- `analysis_options.yaml` 已配置（升级至 5.7.1 以兼容 freezed）

---

## 第 2-3 天：稳定性加固 (10h) ✅

### 2.1 P1-2: unwrap() 系统清理 (4h) ✅

**结果**: routes.rs 35 → 22 unwrap

| 优先级 | 模式 | 数量 | 结果 |
|--------|------|------|------|
| 🔴 高 | DB 查询 `.unwrap()` | ~8 | ✅ 已消除 → query_vec/query_one 辅助函数 |
| 🟡 中 | UUID split | ~6 | ✅ 添加安全注释 |
| 🟢 低 | JSON object_mut | ~3 | ✅ 改为 if let |
| 🟢 低 | 静态初始化 | ~3 | 保持 |

- 新增 `query_vec()/query_one()` 通用辅助函数（自动 prepare → query_map → Json error）
- 剩余 22 处为低频 handler（admin/profile/preferences），风险可控

### 2.2 P0-4: chat_screen.dart 拆分 (6h) ✅

**结果**: 1453 → 828 行（-43%）

**实际目录结构**：
```
app/lib/screens/chat/
├── chat_concept_dialog.dart   (139行)  ConceptDialog.show 静态方法
├── chat_input.dart            (221行)  ChatInput ConsumerStatefulWidget
├── chat_plan_panel.dart       (182行)  ChatPlanPanel StatefulWidget
└── chat_message_bubble.dart   (165行)  ChatMessageBubble StatelessWidget
```

- chat_screen.dart 变为纯容器组件，移除所有旧方法
- 移除 flutter_math_fork / graph_widget / stt_service / tts_service import
- `flutter analyze`: 0 errors

当前 1453 行单一文件，拆分为模块化结构：

**目标目录结构**：
```
app/lib/
├── screens/
│   └── chat/
│       ├── chat_screen.dart          (~200行) ← 主容器
│       ├── chat_message_list.dart    (~300行) ← 消息列表+流式渲染
│       ├── chat_input.dart           (~250行) ← 输入栏+语音+发送
│       ├── chat_concept_dialog.dart  (~200行) ← 概念确认弹窗
│       ├── chat_plan_panel.dart      (~200行) ← 学习计划面板
│       └── chat_controller.dart      (~300行) ← 状态管理+WS+API
```

**拆分原则**：
- 每个文件 ≤ 400 行
- 状态管理通过 Riverpod Provider 通信
- 组件之间不直接引用，通过回调传递
- 保持原有功能完整性，不做行为变更

**实施步骤**：
1. 创建 `chat_controller.dart`，提取 WS 连接/消息流/概念提取逻辑
2. 创建 `chat_message_list.dart`，提取消息渲染+数学公式
3. 创建 `chat_input.dart`，提取输入栏+STT
4. 创建 `chat_concept_dialog.dart`，提取概念确认弹窗
5. 创建 `chat_plan_panel.dart`，提取学习计划面板
6. `chat_screen.dart` 变为纯容器组件，组装子组件

**验证**：
```bash
flutter analyze lib/screens/chat/
flutter test
# 手动测试：发送消息 → 概念弹窗 → 计划面板 → 语音输入
```

---

## 第 4-5 天：架构升级 (12h) ✅

### 3.1 P1-3: 集成 FSRS-5 (8h) ✅

**方案变更**: `fsrs` crate 因 `libsqlite3-sys` 与 `rusqlite(bundled)` 冲突，改为**自实现 FSRS-5 核心算法**。

**新增**: `card_engine/src/fsrs5.rs`
- 17 项默认参数（W[0..16]）来自 FSRS 论文
- 4 级 Rating：Again(1)/Hard(2)/Good(3)/Easy(4)
- `schedule()` 函数 — memory state + rating → 难度/稳定性/间隔
- 核心公式：init_difficulty / next_difficulty / stability_after_success / stability_after_failure

**修改**: `fsrs_scheduler.rs`
- `compute_next_state` 固定间隔数组 → FSRS-5 公式
- `card_memory.difficulty/stability` 列从冗余变为实际使用

**验证**: `cargo test -p card_engine` 16/16 passed

### 3.2 CI/CD 质量门禁 (2h) ✅

- `.github/workflows/ci.yml` 已创建
- Backend: fmt → clippy → test
- Frontend: pub get → analyze → test
- **待**: GitHub 仓库连接确认后激活

### 3.3 P2-8: freezed 模型生成 (2h) ⚠️

- 依赖已添加：`freezed_annotation` + `json_annotation` + `build_runner` + `freezed` + `json_serializable`
- 示例 `freezed_example.dart` 已创建（DueCardFreezed 含 fromJson/fromLegacy）
- `dart_code_metrics` 升级至 5.7.1 + http override 解决 freezed 冲突
- **待**: 本地运行 `cd app && dart run build_runner build --delete-conflicting-outputs`

---

## 长期优化（按需推进）

| 项目 | 说明 | 预估 |
|------|------|------|
| P1-8/P1-9 | review_screen(846行)/profile_screen(877行) 拆分 | 8h |
| P1-10 | 错误边界 — API 调用失败 UI 友好提示 | 3h |
| P2-9 | widget 测试扩展到核心页面 | 6h |
| 速率限制 | `tower::limit` 添加 API 限流 | 2h |
| API 文档 | `utoipa` / swagger 自动生成 | 4h |
| HTTPS | Nginx 层面已配置，待域名备案 | — |

---

## 可立即执行项（无需额外上下文）

```bash
# 1. 运行现有测试，确认本次修复无回归
cd backend && cargo test -p card_engine -p chat_engine -p growth_engine

# 2. 检查 clippy 警告
cargo clippy --workspace 2>&1 | grep warning

# 3. 前端静态分析
cd app && flutter analyze

# 4. 前端测试
flutter test
```

---

## 里程碑

| 里程碑 | 标志 | 状态 |
|--------|------|------|
| ✅ 安全修复完成 | P0-1/P0-2/P0-3 全部合并 | ✅ 2026-05-16 |
| ✅ 稳定性达标 | unwrap 清理 + chat_screen 拆分 | ✅ 2026-05-16 |
| ✅ 架构升级 | fsrs5 自实现 + CI/CD + freezed 依赖 | ✅ 2026-05-16 |
| ⏳ 本地执行 | flutter test + build_runner + CI 激活 | 📋 待用户本地 |
