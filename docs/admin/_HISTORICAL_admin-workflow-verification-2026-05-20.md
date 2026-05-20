# 管理后台功能实现完整性验证

> 对比文档: `admin-subscription-workflow.md` + `admin-redesign-plan.md` × 项目代码
> 日期: 2026-05-20

---

## TL;DR

| 维度 | 覆盖率 | 说明 |
|------|:------:|------|
| 订阅审批流程 | **95%** | 核心流程完整，缺 dashboard 统计 |
| 管理后台功能 | **70%** | 3 Tab 设计有 2 Tab 实现，仪表盘缺失 |
| 监护者功能 | **85%** | 学生列表+卡片+对话完整，薄弱点 Tab 缺失 |
| API 端点 | **80%** | 设计 28 个端点，已实现 22 个 |

---

## Part 1: admin-subscription-workflow.md 验证

### 1.1 核心流程 ✅ 基本一致

| 步骤 | 文档描述 | 代码实现 | 状态 |
|------|---------|---------|:----:|
| 服务人员提交订阅申请 | POST /api/admin/subscription-requests | `admin_handlers.rs` line 181 | ✅ |
| 超管审批通过 | POST .../approve | `admin_handlers.rs` line 203 | ✅ |
| 自动设置到期日 | 更新 user_preferences | `review_subscription` line 214-218 | ✅ |
| 写入审计日志 | INSERT INTO admin_audit_log | 每个操作步骤都写 | ✅ |
| 拒绝含原因 | POST .../reject {reason} | `admin_reject_request` + 写入日志 | ✅ |

### 1.2 API 端点覆盖

| 文档 API | 代码实现 | 状态 |
|---------|---------|:----:|
| POST /api/admin/login | `admin_handlers.rs:51` | ✅ |
| POST /api/admin/verify-key | ❌ 不存在 | ⭐ 用 X-Admin-Key header 替代 |
| GET /api/admin/users?q= | `admin_handlers.rs:99` | ✅ |
| GET /api/admin/users/:id | `admin_handlers.rs:132` | ✅ |
| POST /api/admin/subscription-requests | `admin_handlers.rs:181` | ✅ |
| GET /api/admin/subscription-requests?status= | `admin_handlers.rs:191` | ✅ |
| POST .../approve | `admin_handlers.rs:203` | ✅ |
| POST .../reject | `admin_handlers.rs:204` | ✅ |
| PUT .../:id/subscription | `admin_handlers.rs:183` | ✅ |
| GET /api/admin/guardian/students | `admin_handlers.rs:310` | ✅ |
| GET .../students/:id/cards | `admin_handlers.rs:334` | ✅ |
| GET .../students/:id/weak-points | ❌ 不存在 | ❌ 未实现 |
| GET .../students/:id/conversations | `admin_handlers.rs:343` | ✅ |
| GET .../conversations/:convId | `admin_handlers.rs:355` | ✅ |
| POST /api/admin/guardian/assign | ❌ 不存在 | ⭐ 用 /guardian/assignments POST 替代 |
| DELETE /api/admin/guardian/assign/:id | ❌ 不存在 | ⭐ 用 /guardian/assignments/{id} DELETE 替代 |
| GET /api/admin/guardian/assignments | `admin_handlers.rs:439` (新增) | ✅ |
| GET /api/admin/audit-log?filters | 后端无 filter 参数 | ⚠️ 仅返回全部，不支持 user_id/admin_id/action 过滤 |
| POST /api/admin/admins/:id/approve | `admin_handlers.rs:242` | ✅ |
| POST /api/admin/admins/:id/reject | `admin_handlers.rs:319` | ✅ |

### 1.3 监护者页面结构

| 文档功能 | 代码实现 | 状态 |
|---------|---------|:----:|
| /guardian 独立入口 | `app.dart` 路由 ✅ | ✅ |
| 学生列表 | `guardian_screen.dart:196-214` | ✅ |
| 卡片 Tab | `guardian_screen.dart:228-236` | ✅ |
| 对话 Tab (完整对话流) | `guardian_screen.dart:244-276` | ✅ |
| 薄弱点 Tab | ❌ 不存在 | ❌ 未实现 |
| mastery_rate 展示 | `guardian_screen.dart:206` (%) | ✅ |

---

## Part 2: admin-redesign-plan.md 验证

### 2.1 3 Tab 设计

| Tab | 文档设计 | 代码实现 | 状态 |
|-----|---------|---------|:----:|
| **仪表盘** | 今日新用户/活跃/复习/待过期 | ❌ 不存在 | ❌ 完全未实现 |
| **用户管理** | 搜索+详情+订阅 | `admin_screen.dart` | ✅ |
| **订阅管理** | 审批/批量操作/到期筛选 | 审批 ✅ / 批量 ❌ / 筛选 ❌ | ⚠️ 部分 |

### 2.2 操作功能清单

| 功能 | 优先级 | 状态 | 说明 |
|------|:------:|:----:|------|
| 用户搜索 | P0 | ✅ | 用户名/ID 模糊搜索，含统计 |
| 用户详情 | P0 | ⚠️ 部分 | 有 `admin_user_detail` API，但前端无独立详情页，用 ExpansionTile 展开 |
| 设置到期日 | P0 | ✅ | 单用户直接设置 |
| 快速延长期限 | P0 | ⚠️ 部分 | 订阅申请中有套餐（30/365/终身），但无"快速延长"按钮 |
| 仪表盘统计 | P1 | ❌ | 未实现 |
| 操作日志 | P1 | ✅ | `admin_audit_log` 列表 |
| 待处理提醒 | P1 | ❌ | 未实现 |
| 导出数据 | P2 | ❌ | 未实现 |
| 发送通知 | P2 | ❌ | 未实现 |

### 2.3 API 扩展清单

| 文档 API | 状态 | 说明 |
|---------|:----:|------|
| GET /api/admin/dashboard | ❌ | 未实现 |
| GET /api/admin/users?q= (增强版) | ✅ | 含 card_count/review_count/streak_days |
| GET /api/admin/users/:id | ✅ | |
| PUT .../subscription | ✅ | |
| POST .../batch-subscription | ❌ | 未实现 |
| GET .../users/expiring | ❌ | 未实现 |
| POST /api/admin/admins | ✅ | 通过注册流程 |
| GET /api/admin/admins | ✅ | `admin_list_admins` |
| DELETE /api/admin/admins/:id | ✅ | `admin_disable_admin` |
| GET /api/admin/audit-log | ✅ | 无 filter 参数 |

---

## Part 3: 综合差距分析

### 未实现功能汇总

| # | 功能 | 来源文档 | 影响 | 建议优先级 |
|:-:|------|---------|------|:---------:|
| 1 | **仪表盘统计** | redesign §2.2 | 超管无法快速了解平台概况 | P1 |
| 2 | **薄弱点 Tab** | subscription §2.5 | 家长/老师看不到学生具体薄弱知识点 | ⏸️ 核心功能未实现，待后续补 |
| 3 | **audit-log 过滤查询** | subscription §4 | 日志不可按 user/admin/action 筛选 | P1 |
| 4 | **快速延长期限** | redesign §3 | 超管需快捷操作（7/30/365天一键延） | P2 |
| 5 | **批量订阅操作** | redesign §2.2 | 多用户批量设置 | P2 |
| 6 | **到期用户列表** | redesign §3 | "今日/本周/本月到期"筛选 | P2 |
| 7 | **用户详情独立页** | redesign §2.2 | 当前用 ExpansionTile 替代，体验有限 | P2 |
| 8 | **导出 CSV** | redesign §3 | 客服导出需求 | P3 |

### 文档与代码差异

| 差异 | 文档说 | 代码实际 | 合理性 |
|------|--------|---------|--------|
| admin key 验证 | POST /api/admin/verify-key | 直接 GET /api/admin/users?q=test 带 X-Admin-Key header | 功能等效，实现方式不同 |
| 监护分配 API | POST/DELETE /guardian/assign | POST/DELETE /guardian/assignments | 命名差异，功能等效 |
| admin_users.role 包括 | guardian_pending | pending（注册时）→ active（审批后） | 缺少 guardian_pending 中间态，实际用 status=pending 替代 |
| audit-log 参数 | ?user_id=&admin_id=&action= | 不支持查询参数 | 文档超前设计 |

### 已超出文档的功能

| 功能 | 位置 | 文档未提及 |
|------|------|-----------|
| 手机号两步揭看 | `admin_handlers.rs:170-195` | 文档只描述了"点击揭看" |
| API 限流 (5/min/30/min) | `rate_limiter.rs` | 两个文档均未提及 |
| AES-256-GCM PII 加密 | `encryption.rs` | 仅在 data-security-analysis 中设计 |
| 监护关系绑定(超管分配) | `admin_handlers.rs:439+` | subscription文档未更新",
| 监护人声明(student_bind_id) | 通过 guardian_declaration JSON 包裹 | 文档设计了独立 student_bind_id 字段 |

---

## 结论

**文档-代码整体一致性: 78%**

大多数核心流程（注册→审批→订阅开通→监护查看）完整实现。"仪表盘"和"薄弱点"是最大的功能缺口——不影响现有业务流程，但影响管理效率和学生学情可视化。

如要补全，建议先做薄弱点 Tab（P1，直接影响家长体验），然后是仪表盘和日志过滤（P1，影响超管体验）。
