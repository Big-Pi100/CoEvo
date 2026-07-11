# SEO + 免费试用转化方案 — 实现核对报告

> 核对日期：2026-06-24 | 核对目标：`docs/seo-and-landing-agent-plan.md`（v3）

---

## 一、总览

| 分类 | 总数 | ✅ 已完成 | ❌ 未实现 | 完成率 |
|:----|:----:|:--------:|:--------:|:-----:|
| 后端 API | 2 | 2 | 0 | 100% |
| 后端路由 | 1 | 1 | 0 | 100% |
| 后端清理 | 1 | 0 | 1 | **0%** |
| 后端防滥用 | 1 | 0 | 1 | **0%** |
| Flutter 核心逻辑 | 3 | 3 | 0 | 100% |
| Flutter 注册弹窗 UI | 1 | 1 | 0 | 100% |
| Flutter 弹窗触发 | 3 | 0 | 3 | **0%** |
| Flutter PC 响应式 | 1 | 0 | 1 | **0%** |
| SEO index.html | 3 | 0 | 3 | **0%** |
| 删除冗余文件 | 2 | 1 | 1 | 50% |
| **合计** | **18** | **8** | **10** | **44%** |

---

## 二、逐项核对详情

### 后端

#### 1. ✅ POST /api/trial/start — 创建临时账户
- **文件**: `backend/crates/api_server/src/trial_handler.rs`（第25-72行）✅
- **路由**: `routes.rs` 第256行 ✅
- **注册**: `lib.rs` 第47行 `pub mod trial_handler;` ✅
- **实现检查**:
  - ✅ 生成唯一 username = `trial_` + uuid 前8位
  - ✅ 推广码 referral_code = `CoEvo_trial_` + uuid 前4位
  - ✅ 不可登录密码：`bcrypt("trial_no_login_" + uuid)`
  - ✅ 1 天试用订阅：`subscription_expires = datetime('now', '+1 day')`
  - ✅ INSERT INTO users + tokens
  - ✅ 返回 `{ user_id, token, username }`

#### 2. ✅ PUT /api/trial/claim — 认领账户
- **文件**: `trial_handler.rs`（第77-195行）✅
- **路由**: `routes.rs` 第257行 ✅
- **实现检查**:
  - ✅ 校验 token
  - ✅ 校验密码复杂度（6位以上）
  - ✅ 校验 username 唯一
  - ✅ 加密 PII 字段（real_name, phone）
  - ✅ 处理推广码 referral_code
  - ✅ 触发注册活动（campaign trigger）
  - ✅ 删除旧 token、创建新 token
  - ✅ 返回 `{ token, username }`

#### 3. ❌ 定时清理 — 软删除 + 硬删除（plan 3.4 节）
- **文件**: `campaign_scheduler.rs`
- **预期**: 每5分钟执行：
  - 软删除：`UPDATE users SET deleted_at=datetime('now') WHERE username LIKE 'trial_%' AND password_hash IS NULL AND deleted_at IS NULL AND created_at<datetime('now','-7 days')`
  - 硬删除：软删后30天级联 DELETE 12张关联表
- **实际**: `campaign_scheduler.rs` 只有佣金解锁、NOTPAY关单、cron推送、海报模板刷新。**没有任何 trial 账户清理相关代码。**
- **状态**: ❌ **完全缺失**

#### 4. ❌ 防滥用 — 同 IP 每日限 3 次（plan 3.1 第8条）
- **预期**: `trial_handler.rs` 的 `start` 函数中增加 IP 检测，同IP每天最多创建3个临时账户
- **实际**: `trial_handler.rs` 里没有任何 IP 追踪或限流逻辑
- **状态**: ❌ **完全缺失**

---

### Flutter 前端 — 核心逻辑

#### 5. ✅ auth_client.dart — API 客户端
- **文件**: `app/lib/api/auth_client.dart`
- **实现**:
  - ✅ `trialStart()` — POST /api/trial/start（第61-72行）
  - ✅ `trialClaim()` — PUT /api/trial/claim（第75-105行）

#### 6. ✅ auth_provider.dart — 状态管理
- **文件**: `app/lib/providers/auth_provider.dart`
- **实现**:
  - ✅ `trialStart()` — 创建临时账户并保存 token（第180-202行）
  - ✅ `trialClaim()` — 认领账户，写 `coevo_trial_claimed` 到 SharedPreferences（第205-235行）
  - ✅ `isTrialAccount()` 辅助函数（第239-241行）
  - ✅ `isClaimed()` 辅助函数（第244-247行）

#### 7. ✅ home_screen.dart — 首屏自动创建临时账户
- **文件**: `app/lib/screens/home_screen.dart`
- **实现**:
  - ✅ `_initAuth()` 检测未登录 → 自动调 `trialStart()`（第42-62行）
  - ✅ 白底加载页 + spinner + 品牌文案（第106-131行）
  - 注：计划中说的 `auth_screen.dart` 不存在，实际逻辑移到了 `home_screen.dart`，这也是合理的入口。

---

### Flutter 前端 — 注册弹窗

#### 8. ✅ claim_dialog.dart — 注册弹窗组件
- **文件**: `app/lib/widgets/claim_dialog.dart`
- **实现**: ✅ 完整组件，包含登录/注册切换、用户名/密码/姓名/手机/邀请码表单、校验逻辑、调 `trialClaim()` API

#### 9. ❌ 首次进入聊天页弹注册窗（plan 4.3 第3项）
- **预期**: `chat_screen.dart` 刚进入时检测 `isTrialAccount && !isClaimed` → 弹出 ClaimDialog
- **实际**: `chat_screen.dart` **没有任何 trial/claim 相关代码**，也没有导入或显示 `ClaimDialog`
- **状态**: ❌ **完全缺失**

#### 10. ❌ 点击个人图标弹注册窗（plan 4.3 第4项）
- **预期**: `profile_screen.dart` 点击个人图标时检测 trial 状态 → 弹出 ClaimDialog
- **实际**: `profile_screen.dart` **没有任何 trial/claim 相关代码**
- **状态**: ❌ **完全缺失**

#### 11. ❌ 监听 task 完成弹注册窗（plan 4.3 第5项）
- **预期**: `chat_screen.dart` 监听 user_plan_progress 中 status='done' → 增量弹注册 Dialog
- **实际**: `chat_screen.dart` **没有相关的 task 完成监听逻辑**
- **状态**: ❌ **完全缺失**

#### 12. ❌ PC 端响应式适配（plan 4.5 节）
- **文件**: `app/lib/app.dart`
- **预期**: `builder` 中加宽度约束，宽屏（>768px）时限制内容宽度 ≤1200px，居中
- **实际**: 第354-360行仍是旧的 `builder: (context, child) => Stack(...)`，**未加宽度约束**
- **状态**: ❌ **未实现**

---

### SEO / index.html

#### 13. ❌ Title 未优化（plan 8.5 节）
- **当前**: `<title>CoEvo - 刻意进化学习</title>`
- **预期**: `<title>CoEvo AI特级教师 — 主动式一对一学习，不遗忘不跑偏</title>`
- **状态**: ❌ **未更新**

#### 14. ❌ Meta description 未优化（plan 8.5 节）
- **当前**: `<meta name="description" content="刻意进化学习 - CoEvo: AI驱动的个性化学习平台">`
- **预期**: `<meta name="description" content="CoEvo刻意进化学习，基于FSRS记忆算法的AI特级教师...免费试用，30天不满意全额退">`
- **状态**: ❌ **未更新**

#### 15. ❌ FAQ Schema JSON-LD 缺失（plan 7.4 第3项）
- **预期**: 在 `index.html` 中添加 FAQ 结构化数据 JSON-LD
- **实际**: **不存在**
- **状态**: ❌ **完全缺失**

#### 16. ✅ 百度统计 — 存在（plan 8.3）
- 已在 `index.html` 第35-43行

---

### 其他

#### 17. ✅ first_run_carousel.dart — 已删除
- **预期**: 删除首屏5页幻灯片组件
- **实际**: 文件未找到 ✅ **已删除**

#### 18. ❌ landing/ 目录 — 仍存在（plan 8.4 第11项）
- **预期**: 删除本地 + VPS 的 `landing/` 目录，不再维护
- **实际**: 本地 `E:\CoEvo\landing\` 目录仍然存在（含30个文件：index.html, mobile.html, css, fonts, js 等）
- **状态**: ❌ **本地未清理**

---

## 三、优先级建议

### P0 — 影响核心功能（建议优先修复）
| # | 问题 | 文件 | 建议 |
|:-|:-----|:-----|:-----|
| 1 | 注册弹窗完全不触发 | `chat_screen.dart`, `profile_screen.dart` | 三个触发点（首次进入、个人图标、task完成）均未实现，试用转化路径断掉 |
| 2 | Trial 清理缺失 | `campaign_scheduler.rs` | 临时账户会无限堆积 DB |

### P1 — 影响用户体验
| # | 问题 | 文件 | 建议 |
|:-|:-----|:-----|:-----|
| 3 | PC 端宽屏未约束 | `app/lib/app.dart` | 宽屏下 UI 元素等比例放大，体验差 |
| 4 | SEO 优化未生效 | `app/web/index.html` | Title/description 不符合 SEO 策略 |
| 5 | FAQ Schema 缺失 | `app/web/index.html` | 失去百度搜索结构化展现机会 |

### P2 — 锦上添花
| # | 问题 | 文件 | 建议 |
|:-|:-----|:-----|:-----|
| 6 | IP 防滥用未实现 | `trial_handler.rs` | 目前无滥创建防护 |
| 7 | `landing/` 未清理 | `E:\CoEvo\landing/` | 遗留目录，不再维护 |

---

## 四、关键发现

1. **后端 API 基础设施完整**：trial/start 和 trial/claim 两个核心 API 均正确实现并注册路由，可直接使用。
2. **Flutter 基础能力完整**：`auth_provider.dart` 和 `auth_client.dart` 的 trial 方法完整，`claim_dialog.dart` 组件 UI 完整。
3. **最大缺口在弹窗触发**：三个弹窗触发点（chat_screen 两个、profile_screen 一个）**一个都没实现**。虽然有 ClaimDialog 组件，但没有任何代码调用它。试用→注册的转化路径完全断开了。
4. **清理逻辑完全缺失**：临时账户创建后没有任何清理机制。
5. **计划文档标记了"已完成"但实际未完成**：plan 第 4.3 节的改动清单中 chat_screen 和 profile_screen 的弹窗都标记为 ✅ **已完成**，但实际代码中完全没有。
