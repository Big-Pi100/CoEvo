# 管理后台 · 实现进度清单

> 日期: 2026-05-20 · V2 — 验证报告后更新
> 上次评估: `docs/security-checklist-verification-report-2026-05-20.md`

---

## 一、已完成 ✅

| 层级 | 项目 | 状态 | 验证 |
|------|------|:--:|:----:|
| DB | users 扩展 (real_name, phone) | ✅ | `main.rs:232-234` |
| DB | admin_users 表 | ✅ | `main.rs:237-253` |
| DB | subscription_requests 表 | ✅ | `main.rs:255-268` |
| DB | admin_audit_log 表 | ✅ | `main.rs:270-278` |
| DB | guardian_assignments 表 | ✅ | `main.rs:280-289` |
| 后端 | POST /api/admin/login | ✅ | `admin_handlers.rs:49-68` |
| 后端 | POST /api/admin/register + 验证 | ✅ | `admin_handlers.rs:72-93` |
| 后端 | GET /api/admin/users?q= (带统计数据) | ✅ | `admin_handlers.rs:97-122` |
| 后端 | PUT /api/admin/users/:id/subscription | ✅ | `admin_handlers.rs:148-156` |
| 后端 | POST /api/admin/subscription-requests CRUD | ✅ | `admin_handlers.rs:158-203` |
| 后端 | POST /api/admin/admins/:id/approve + reject | ✅ | `admin_handlers.rs:222-267` |
| 后端 | GET /api/admin/audit-log | ✅ | `admin_handlers.rs:270-278` |
| 后端 | GET /api/admin/guardian/students | ✅ | `admin_handlers.rs:281-298` |
| 后端 | GET /api/.../cards + conversations | ✅ | `admin_handlers.rs:305-334` |
| 后端 | POST /api/user/bind-lookup | ✅ | `admin_handlers.rs:338-343` |
| 后端 | PUT /api/user/:id/profile | ✅ | `admin_handlers.rs:347-352` |
| 后端 | 审批通过 guardian 时自动创建绑定 | ✅ | `admin_handlers.rs:232-243` |
| 后端 | 辅导老师路由跳转 /guardian | ✅ | `admin_screen.dart:123-126` |
| 后端 | 绑定 key SHA-256 哈希 | ✅ | `admin_handlers.rs:239-244` (2026-05-20 修复) |
| 后端 | bind-lookup IP 限流 (5/min) | ✅ | `rate_limiter.rs` + `admin_handlers.rs:339` (2026-05-20 修复) |
| 后端 | admin/users API 限流 (30/min) | ✅ | `admin_handlers.rs:97-98` (2026-05-20 修复) |
| 后端 | reveal-phone 限流 (20/min) | ✅ | `admin_handlers.rs:141` (2026-05-20 修复) |
| 前端 | AdminScreen 超管 4 Tab | ✅ | `admin_screen.dart:70-76` |
| 前端 | 用户注册验证 | ✅ | `validators.dart` |
| 前端 | auth_screen 扩展 (real_name + phone) | ✅ | `auth_screen.dart` |
| 前端 | profile_screen 扩展 (real_name + phone) | ✅ | `profile_screen.dart` |
| 前端 | 落地页「家长」按钮 | ✅ | `landing/index.html:30` |
| 前端 | 家长单页滚动设计（无 Tab） | ✅ | `guardian_screen.dart` |
| 前端 | 学习报告对话流展示 | ✅ | `guardian_screen.dart:217-280` |
| 前端 | 手机号两步揭看（脱敏 → 二次确认 → 完整） | ✅ | `admin_screen.dart:162-192` (2026-05-20 修复) |
| 前端 | 服务人员搜索正常 + 脱敏电话/姓名 | ✅ | `admin_users_handler` 返回 `phone_masked` + `real_name_masked` |
| 前端 | 订阅管理切 Tab 自动加载 | ✅ | `_onTabChanged` line 58 |
| 部署 | Nginx 防缓存 no-cache | ✅ | — |

---

## 二、未完成/设计不符 ❌

| # | 问题 | 设计要求 | 当前状态 |
|:--:|------|---------|:--------:|
| **1** | **AES-256 PII 加密** | real_name/phone/id_number 加密存储 | 仍明文存储。需添加 aes-gsm crate + 数据迁移 |
| **2** | **监护分配管理(超管)** | 超管后台分配学生↔辅导老师/家长 | 完全未实现 |

### P2 — 待定

| 修复 | 内容 | 优先级 |
|:----:|------|:------:|
| P2-1 | AES-256 加密 PII 字段 | 中 — 当前 VPS 未遭遇入侵痕迹，但安全文档应修正 |
| P2-2 | 超管监护分配管理 UI | 低 — 绑定逻辑可通过审批流程走通 |

---

## 三、已修复项（历史记录）

以下为 V1 清单标记"未完成"，经 2026-05-20 验证确认已实现：

| # | 原问题 | 实际现状 | 修复时间 |
|:--:|-------|---------|:--------:|
| 1 | 辅导老师路由 | ✅ 已跳转 /guardian | 清单过时 |
| 2 | 辅导老师数据绑定 | ✅ 通过 guardian_assignments 正常使用 | 清单过时 |
| 3 | 家长页面 Tab 问题 | ✅ 单页滚动，无 Tab | 清单过时 |
| 4 | 服务人员搜索 | ✅ 正常，含脱敏字段 | 清单过时 |
| 5 | 订阅管理自动加载 | ✅ _onTabChanged 已实现 | 清单过时 |
| 6 | 手机号脱敏/揭看 | ✅ 两步揭看 + 审计日志 | 2026-05-20 |
| 7 | 学习报告无数据 | ✅ 对话流正常展示 | 清单过时 |

---

## 四、正确的角色-页面映射

```
角色        入口URL        登录后看到什么
─────────────────────────────────────────
超管        /app/admin     4 Tab: 用户管理/订阅管理/注册审批/操作日志
服务人员    /app/admin     2 Tab: 用户管理 + 注册审批
辅导老师    /app/guardian  监护者界面: 学生列表 → 学习报告(卡片+对话)
家长        /app/guardian  监护者界面: 同上
观察者      /app/admin     2 Tab: 用户管理(只读) + 操作日志
```

## 五、安全加固状态

| 措施 | 状态 | 说明 |
|------|:----:|------|
| bcrypt(12) 密码哈希 | ✅ | 用户 + 管理员密码已 bcrypt |
| 手机号两步揭看 + 审计日志 | ✅ | 2026-05-20 修复 |
| bind-lookup IP 限流 (5/min) | ✅ | 2026-05-20 修复 |
| admin/users 限流 (30/min) | ✅ | 2026-05-20 修复 |
| reveal-phone 限流 (20/min) | ✅ | 2026-05-20 修复 |
| bind_key SHA-256 哈希 | ✅ | 2026-05-20 修复 |
| AES-256 PII 字段加密 | ❌ | 待定 — 需评估投入产出比 |
| 监护分配管理 UI | ❌ | 低优先，审批流程已可覆盖 |
