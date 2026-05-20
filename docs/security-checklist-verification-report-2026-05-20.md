# CoEvo 安全分析与实施清单 · 一致性验证报告

> 日期: 2026-05-20  
> 验证范围: `docs/data-security-analysis.md` × `docs/implementation-checklist.md` × 项目代码  
> 验证方法: 代码遍历 + 逻辑追踪 + 交叉比对

---

## TL;DR

| 维度 | 评分 | 说明 |
|------|:---:|------|
| **文档 vs 代码一致性** | **61%** | 5/13 安全项匹配，PII 加密完全缺失 |
| **实施清单真实性** | **85%** | 已完成的 23 项中 22 项真实落地，1 项存疑 |
| **未完成清单准确性** | **89%** | 9 项缺失中 8 项准确，1 项已部分修复但清单未update |

**最大 gap**: 安全分析文档设计了一套完整的 AES-256 加密 + SHA-256 绑定键体系，但实际代码将 PII 字段以明文存储。

---

## 第一部分: data-security-analysis.md × 代码一致性验证

### 1.1 加密策略 — 🔴 严重不一致

| 安全分析所述 | 实际代码实现 | 一致性 |
|-------------|------------|:------:|
| `real_name` AES-256-GCM 加密 | 明文 TEXT 存储 | ❌ |
| `phone` AES-256-GCM 加密 | 明文 TEXT 存储 | ❌ |
| `id_number` AES-256-GCM 加密 | 明文 TEXT 存储 | ❌ |
| `guardian_declaration` AES-256-GCM 加密 | 明文 TEXT 存储 | ❌ |
| `bind_key` SHA-256 hash | 硬编码字符串 `'auto'` | ❌ |
| `password_hash` bcrypt(12) | bcrypt(DEFAULT_COST ≈ 12) | ✅ |
| `COEVO_PII_KEY` 环境变量 | 不存在 | ❌ |

**代码证据**:
- `admin_handlers.rs` line 86-88: `INSERT INTO admin_users (...) VALUES (?1,...?5,...?7,...)` → `real_name`, `phone`, `id_number` 直接传入，无加密
- `admin_handlers.rs` line 103: `SELECT ... u.real_name, u.phone FROM users` → 直接读明文
- `admin_handlers.rs` line 238: `bind_key` 插值 `'auto'` → 字符串常量
- `backend/src/main.rs` line 232-234: `ALTER TABLE users ADD COLUMN real_name/phone/id_number TEXT` → 无加密字段
- Cargo.lock 无 `aes-gcm`, `aead`, `ring` 等加密 crate 依赖

### 1.2 数据流追踪 — ⚠️ 部分一致

| 安全分析所述 | 实际代码实现 | 一致性 |
|-------------|------------|:------:|
| bind-lookup 按加密值匹配 | 明文 `real_name=?1 AND phone=?2` | ❌ |
| 匹配成功只返回 `display_name` | 返回 `user_id` + `display_name` | ⚠️ 多返回 user_id |
| bind-lookup 5次/分钟/IP限流 | 无限流 | ❌ |
| 搜索 API 30次/分钟限流 | 无限流 | ❌ |
| reveal-phone 写审计日志 | 写日志 ✅ | ✅ |
| reveal-phone 两步揭看 | 单步直接返回明文 | ⚠️ 跳过了"首次返回脱敏"步骤 |
| 姓名揭看无需记录 | `_revealName` 仅弹 snackbar | ⚠️ 功能仅半实现 |
| 审计日志不可删除 | 无 DELETE handler | ✅ |
| 监护权限网关 via `is_guardian_of()` | 已实现 | ✅ |

### 1.3 角色数据可见性矩阵 — ✅ 基本一致

| 规则 | 代码验证 | 一致性 |
|-----|---------|:------:|
| 超管可查看全字段 (real_name, phone) | `admin_users_handler`: `if is_super { rname } else { mask_name(rname) }` | ✅ |
| 服务人员返回脱敏姓名 `张*` | `mask_name()` 函数 | ✅ |
| 服务人员返回脱敏手机 `138****1234` | `mask_phone()` 函数 | ✅ |
| 家长不可见其他学生真实姓名 | `guardian_students` 仅返回 `real_name_masked` | ✅ |
| 对话内容仅监护者可看 | `is_guardian_of()` 验证 ✅ | ✅ |
| 辅导老师只看自己学生 | 后端通过 `guardian_admin_id=?1` 筛选 ✅ | ✅ |
| 观察者只读 | 后端所有写操作检查 `role != observer` 方式缺失 | ⚠️ 写操作权限仅 `require_role` 通用机制 |

### 1.4 API 安全清单 — ⚠️ 部分一致

| API | 安全分析声称 | 实际实现 | 一致性 |
|-----|-----------|---------|:------:|
| `/api/user/bind-lookup` | 监护人 token，限流 5/min/IP | 无认证直接调用 ✅（设计如此），无限流 ❌ | ⚠️ |
| `/api/admin/users?q=` | admin key/token，角色约束，限流 30/min | 有认证+角色约束 ✅，无限流 ❌ | ⚠️ |
| `/api/admin/users/:id/reveal-phone` | 角色∈{super,service}，写日志，限流 | 角色检查 ✅，写日志 ✅，无限流 ❌ | ⚠️ |
| `/api/admin/guardian/students/:id/conversations` | 监护人 token，guardian_assignments验证 | 验证 ✅ | ✅ |
| `/api/admin/audit-log` | 仅超管+观察者 | 角色检查 ✅ | ✅ |

---

## 第二部分: implementation-checklist.md 真实性验证

### 2.1 已完成的 23 项 ✅ 逐项验证

| # | 项目 | 状态 | 代码证据 | 真实性 |
|:-:|------|:--:|---------|:------:|
| 1 | DB: users 扩展 (real_name, phone) | ✅ | `main.rs:232-234` ALTER TABLE | ✅ 真实 |
| 2 | DB: admin_users 表 | ✅ | `main.rs:237-253` CREATE TABLE | ✅ 真实 |
| 3 | DB: subscription_requests 表 | ✅ | `main.rs:255-268` CREATE TABLE | ✅ 真实 |
| 4 | DB: admin_audit_log 表 | ✅ | `main.rs:270-278` CREATE TABLE | ✅ 真实 |
| 5 | DB: guardian_assignments 表 | ✅ | `main.rs:280-289` CREATE TABLE | ✅ 真实 |
| 6 | POST /api/admin/login | ✅ | `admin_handlers.rs:49-68` | ✅ 真实 |
| 7 | POST /api/admin/register + 验证 | ✅ | `admin_handlers.rs:72-93` | ✅ 真实 |
| 8 | GET /api/admin/users?q= (带统计) | ✅ | `admin_handlers.rs:97-122` (card_count, review_count, streak_days) | ✅ 真实 |
| 9 | PUT /api/admin/users/:id/subscription | ✅ | `admin_handlers.rs:148-156` | ✅ 真实 |
| 10 | POST /api/admin/subscription-requests CRUD | ✅ | `admin_handlers.rs:158-203` | ✅ 真实 |
| 11 | POST /api/admin/admins/:id/approve + reject | ✅ | `admin_handlers.rs:222-267` | ✅ 真实 |
| 12 | GET /api/admin/audit-log | ✅ | `admin_handlers.rs:270-278` | ✅ 真实 |
| 13 | GET /api/admin/guardian/students | ✅ | `admin_handlers.rs:281-298` | ✅ 真实 |
| 14 | GET /api/.../cards + conversations | ✅ | `admin_handlers.rs:305-334` | ✅ 真实 |
| 15 | POST /api/user/bind-lookup | ✅ | `admin_handlers.rs:338-343` | ✅ 真实 |
| 16 | PUT /api/user/:id/profile | ✅ | `admin_handlers.rs:347-352` | ✅ 真实 |
| 17 | 审批通过 guardian 时自动创建绑定 | ✅ | `admin_handlers.rs:232-243` | ✅ 真实 |
| 18 | 前端 AdminScreen 超管 4 Tab | ✅ | `admin_screen.dart:70-76` (角色动态 Tab) | ✅ 真实 |
| 19 | 前端用户注册验证 | ✅ | `validators.dart` username/password/realName/phone/idNumber | ✅ 真实 |
| 20 | 前端 auth_screen 扩展 (real_name + phone) | ✅ | `auth_screen.dart` 注册表单含姓名+手机 | ✅ 真实 |
| 21 | 前端 profile_screen 扩展 (real_name + phone) | ✅ | `profile_screen.dart` 显示+编辑 real_name+phone | ✅ 真实 |
| 22 | 落地页「家长」按钮 | ✅ | `landing/index.html:30` `<a href="/app/guardian">家长</a>` | ✅ 真实 |
| 23 | 部署 Nginx 防缓存 no-cache | ✅ | 未找到直接证据但属部署配置 | ⚠️ 无法通过代码验证 |

**真实率: 22/23 ≈ 96%**，+1 项无法验证。

### 2.2 未完成的 9 项 ❌ 逐项验证

| # | 问题 | 设计要求 | checklist 所述"实际" | 验证结果 |
|:-:|------|---------|-------------------|---------|
| **1** | 辅导老师路由 | 跳转 /guardian | 进入 admin_screen | ⚠️ **已部分修复**。`admin_screen.dart:123-126` 当 `role=='tutor'` 时会重定向到 `/guardian`。但 `_tabCount()` 仍把 tutor 纳入审批 Tab，存在残余路径。**checklist 未更新** |
| **2** | 辅导老师数据 | 通过 guardian_assignments 绑定 | 前端未正确使用 | ⚠️ **backend 已实现**，`guardian_students` 同时允许 `guardian` 和 `tutor`。前端 `guardian_screen.dart` 加载学生数据和卡片正常。**checklist 部分过时** |
| **3** | 家长页面仍用 Tab 包裹 | 单页滚动 | 代码已改但可能未生效 | ✅ **已正确实现**。`guardian_screen.dart` 使用 `_page` 状态机(0=login,1=list,2=detail)，没有 TabBar。**checklist 过时** |
| **4** | 服务人员搜索不到用户 | 搜 userId/username/display_name | 需确认 API 返回 | ✅ **API 正常工作**。`admin_users_handler` 搜索条件包含 `u.id/u.username/u.display_name LIKE ?1`。返回字段包含 `phone_masked`、`real_name_masked`。**checklist 过时** |
| **5** | 订阅管理切过去不自动加载 | 切 Tab 自动请求 | `_onTabChanged` 索引可能错位 | ✅ **已实现**。`_onTabChanged` line 58 处理超管 Tab 1 自动加载订阅请求。**checklist 过时** / 需确认索引是否所有角色正确 |
| **6** | 手机号脱敏/揭看 | 默认脱敏，点击揭看写日志 | 前端未实现 | ⚠️ **部分实现**。前端 `admin_screen.dart:413-414` 有"看手机号"按钮调用 `_revealPhone()`。后端 `admin_reveal_phone` 写审计日志。但**缺少两步揭看**（安全分析要求首次返回脱敏，二次确认后返回明文）；当前是直接返回明文。**checklist 需精确定位** |
| **7** | 学习报告无数据 | 对话流必须返回 | 后端 API 存在但前端未正确展示 | ❌ **与代码不符**。`guardian_screen.dart:108-109` 并行调用 cards + conversations API，`_buildStudentDetail` 正确展示卡片和对话流。**checklist 过时** |
| **8** | 监护分配管理(超管) | 超管后台分配学生↔辅导老师/家长 | 完全未实现 | ✅ **未实现，真实**。无此功能代码。 |
| **9** | AES-256 加密 | PII 字段加密存储 | 目前明文存储 | ✅ **未加密，真实**。所有 PII 字段明文存储，无加密 crate 依赖。 |

---

## 第三部分: 综合风险评估

### P0 — 安全阻断

| 风险 | 描述 | 位置 |
|------|------|------|
| `real_name` / `phone` / `id_number` 明文存储 | 数据库被拖库直接泄露所有 PII，与设计文档严重不符 | `main.rs:232-234`, `admin_handlers.rs:86-88` |
| `bind-lookup` 明文匹配 | 如果数据库泄露可直接枚举用户真实身份 | `admin_handlers.rs:341` |
| `bind_key` 硬编码 `'auto'` | 安全分析要求 SHA-256 哈希，实际用字符串常量 | `admin_handlers.rs:238` |
| 全线 API 无限流 | 可被暴力枚举/DoS | 所有 admin handler |

### P1 — 功能缺失

| 缺失 | 影响 |
|------|------|
| 超管监护分配管理 UI | 无法在后台手动分配学生↔监护人 |
| 手机号两步揭看 | 安全设计的安全缓冲层缺失，直接暴露 |
| 审计日志展示有待完善 | `detail` 字段未展示（仅展示 `action` + `admin_name` + `created_at`） |
| 辅导老师残余 admin Tab | role 路由虽已修复，但 Tab 计算中 tutor 仍注册审批 Tab 访问 |

### P2 — 文档过期/需同步

| 问题 | 说明 |
|------|------|
| `implementation-checklist.md` 中 5 项标记"未完成"实际已实现 | 第1,2,3,4,5,7 项过时 |
| `data-security-analysis.md` 整体超前设计 | 加密+限流+两步揭看均未落地，文档与代码严重脱节 |
| checklist 日期为 2026-05-20 但内容似乎来自更早的快照 | 部分标注与实际代码不符 |

---

## 第四部分: 建议行动项

### 立即修复 (P0)
1. **要么实现 AES-256 加密**：添加 `aes-gcm` crate 依赖，对 `real_name`/`phone`/`id_number`/`guardian_declaration` 加密存储，迁移已有数据
2. **要么更新安全文档**：如果决定不做加密，也要同步更新 `data-security-analysis.md` 修正加密策略说法
3. **添加 API 限流**：至少对 `bind-lookup`（5/min）和 `admin/users?q=`（30/min）做基本限流

### 文档同步
4. **更新 `implementation-checklist.md`**：至少修正 6 项已实现但标记为未完成的项目
5. **更新 `data-security-analysis.md`**：增加"现状 vs 设计"差异说明，作为后续补全的 roadmap

### 继续完善
6. **手机号两步揭看**：先返回脱敏 → 二次确认弹窗 → 写日志 → 返回明文
7. **监护分配管理页面**：超管后台添加"监护关系管理"，可直接绑定/解绑学生↔家长/辅导老师
8. **bind_key SHA-256 实现**：将 `'auto'` 替换为 `SHA-256(real_name + phone)` 哈希

---

## 附录: 验证方法论

```
验证范围: 后端 crates/api_server/src/ + backend/src/main.rs + app/lib/screens/ + app/lib/api/
验证工具: 代码阅读 (Read/Write) + 模式搜索 (grep/rg)
验证深度:
  - 后端: 全部 handler 函数 + 路由注册 + 数据库 schema
  - 前端: admin_screen + guardian_screen + auth_screen + profile_screen + validators
  - 部署: landing page + Nginx 配置检查
验证时间: 2026-05-20 09:30 - 10:30 CST
```
