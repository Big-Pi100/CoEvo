# CoEvo 分销营销模块 — 任务分解方案

> 基于设计文档 `distribution-marketing-design.md` v2.0
> 作者: 高见远（架构师）
> 日期: 2026-06-18

---

## 一、文件清单

### 1.1 后端 Rust（新增文件）

| # | 文件路径 | 说明 |
|---|---------|------|
| F01 | `backend/crates/api_server/src/referral_handler.rs` | 推广码/点击追踪/用户端数据 API |
| F02 | `backend/crates/api_server/src/campaign_handler.rs` | 管理端活动 CRUD API |
| F03 | `backend/crates/api_server/src/distribution_handler.rs` | 佣金/提现/结算/退款联动/通知 API |
| F04 | `backend/crates/api_server/src/campaign_scheduler.rs` | 活动调度器（推送触发/cron/自动解锁） |
| F05 | `backend/crates/api_server/src/llm_poster.rs` | LLM 海报/H5 生成 + QR 码替换 |
| F06 | `backend/scripts/migrate_subscription_expires.sql` | subscription_expires 迁移 SQL |

### 1.2 后端 Rust（修改文件）

| # | 文件路径 | 改动内容 |
|---|---------|---------|
| M01 | `backend/crates/api_server/src/schema.rs` | +6 张新表 + users 表 2 个新字段 |
| M02 | `backend/crates/api_server/src/routes.rs` | +30+ 条新路由 |
| M03 | `backend/crates/api_server/src/lib.rs` | +5 个新 mod |
| M04 | `backend/crates/api_server/src/auth.rs` | RegisterRequest 增加 referral 字段 |
| M05 | `backend/crates/api_server/src/subscription.rs` | read/write 改为 users.subscription_expires |
| M06 | `backend/crates/api_server/src/pay_handlers.rs` | 支付回调接入归因引擎 |
| M07 | `backend/crates/api_server/src/admin_handlers.rs` | 去掉 user_preferences JOIN，直接读 users.subscription_expires |

### 1.3 前端 Flutter（新增文件）

| # | 文件路径 | 说明 |
|---|---------|------|
| F07 | `app/lib/pages/admin/campaign/admin_campaign_list.dart` | 活动列表卡片视图 |
| F08 | `app/lib/pages/admin/campaign/admin_campaign_form.dart` | 创建/编辑活动表单 |
| F09 | `app/lib/pages/admin/campaign/admin_campaign_detail.dart` | 活动详情+启停/推送 |
| F10 | `app/lib/pages/admin/team/admin_team_tree.dart` | 分销团队搜索+树形展开 |
| F11 | `app/lib/pages/admin/team/admin_user_detail_sheet.dart` | 用户详情弹窗 |
| F12 | `app/lib/pages/admin/settlement/admin_commission_list.dart` | 锁定中佣金+勾选加批次 |
| F13 | `app/lib/pages/admin/settlement/admin_batch_list.dart` | 结算批次列表 |
| F14 | `app/lib/pages/admin/settlement/admin_batch_detail.dart` | 批次明细+CSV导出 |
| F15 | `app/lib/pages/admin/withdrawal/admin_withdrawal_list.dart` | 待审核提现列表 |
| F16 | `app/lib/pages/admin/stats/admin_stats_dashboard.dart` | 数据指标卡+趋势图 |
| F17 | `app/lib/pages/user/distribution/earnings_page.dart` | 用户端收益面板 |
| F18 | `app/lib/pages/user/distribution/team_page.dart` | 用户端团队页面 |
| F19 | `app/lib/pages/user/distribution/withdraw_page.dart` | 用户端提现页面 |
| F20 | `app/lib/pages/user/distribution/notification_panel.dart` | 通知中心列表 |
| F21 | `app/lib/widgets/share_widget.dart` | 分享弹窗组件（推广码+海报+链接） |
| F22 | `app/lib/providers/distribution_provider.dart` | 分销相关的 Riverpod provider |

### 1.4 前端 Flutter（修改文件）

| # | 文件路径 | 改动内容 |
|---|---------|---------|
| M08 | `app/lib/screens/admin_screen.dart` | 侧边栏新增「营销中心」菜单+子 Tab 路由 |
| M09 | `app/lib/screens/profile_screen.dart` | 用户端个人页新增推广码展示+分享入口 |
| M10 | `app/lib/screens/pay_screen.dart` | 支付页展示折扣信息+邀请好友横幅 |

---

## 二、依赖关系图

### 2.1 数据表 FK 依赖

```
marketing_campaigns
  └─ created_by → admin_users(id)
  └─ updated_by → admin_users(id)

referral_clicks
  └─ campaign_id → marketing_campaigns(id)
  └─ referrer_id → users(id)

reward_fulfillments
  └─ campaign_id → marketing_campaigns(id)
  └─ user_id → users(id)
  └─ order_id → payment_orders(id) (nullable)
  └─ referral_click_id → referral_clicks(id) (nullable)

distribution_commissions
  └─ campaign_id → marketing_campaigns(id)
  └─ earner_id → users(id)
  └─ buyer_id → users(id)
  └─ order_id → payment_orders(id)
  └─ batch_id → settlement_batches(id) (nullable)

distribution_withdrawals
  └─ earner_id → users(id)
  └─ batch_id → settlement_batches(id) (nullable)
  └─ handled_by → admin_users(id)

settlement_batches
  └─ handled_by → admin_users(id)

user_notifications
  └─ user_id → users(id)
```

**表创建顺序**: `marketing_campaigns` → `referral_clicks` → `settlement_batches` → `distribution_commissions` + `distribution_withdrawals` + `reward_fulfillments` + `user_notifications`

### 2.2 后端代码模块调用关系

```
auth.rs (改) ──→ referral_handler.rs (新)
  注册时写入 referral_code + referred_by

routes.rs (改) ──→ campaign_handler.rs (新) ──→ schema.rs (改, 表读写)
                 referral_handler.rs (新) ──→ schema.rs
                 distribution_handler.rs (新) ──→ schema.rs + pay_handlers.rs
                 campaign_scheduler.rs (新) ──→ distribution_handler.rs
                 llm_poster.rs (新) ──→ llm.rs (已有)

pay_handlers.rs (改) ──→ distribution_handler.rs (新)
  支付/退款回调触发佣金生成/取消

subscription.rs (改) ──→ 自身(SQL 迁移)
  user_preferences → users.subscription_expires
```

### 2.3 前端页面路由关系

```
admin_screen.dart (改)
  ├── /admin/campaigns        → admin_campaign_list.dart
  │   ├── /admin/campaigns/new  → admin_campaign_form.dart (弹窗)
  │   └── /admin/campaigns/{id} → admin_campaign_detail.dart
  ├── /admin/team             → admin_team_tree.dart
  ├── /admin/settlement       → admin_commission_list.dart
  │   └── /admin/batches      → admin_batch_list.dart
  │       └── /admin/batches/{id} → admin_batch_detail.dart
  ├── /admin/withdrawals      → admin_withdrawal_list.dart
  └── /admin/stats            → admin_stats_dashboard.dart

profile_screen.dart (改)
  └── 推广码展示 → share_widget.dart (复用)
      └── 收益面板 → earnings_page.dart
      └── 团队 → team_page.dart
      └── 提现 → withdraw_page.dart

pay_screen.dart (改)
  └── 折扣横幅展示（条件：有 referred_by 且活动有效）
```

---

## 三、实现阶段与顺序

### 阶段划分原则

| 阶段 | 名称 | 工期 | 并行度 |
|------|------|------|--------|
| S0 | 数据迁移（前置） | 1 天 | 单人 |
| S1 | 核心链路（P0） | 4 天 | 后端 2 人并行 |
| S2 | 结算提现（P1） | 4 天 | 团队并行 |
| S3 | 推送+数据+LLM（P2） | 3 天 | 后端+前端并行 |
| S4 | 测试+上线（P3） | 2 天 | 全组并行 |

### S0：subscription_expires 数据迁移（前置条件）

**工期**: 1 天 | **人员**: 1 人后端

**前置条件**: 无（独立改造）

**涉及文件**: M05 (subscription.rs) + M07 (admin_handlers.rs) + F06 (迁移脚本)

**产出**: subscription_expires 从 user_preferences 迁入 users 表，读/写全部走新字段。旧 KV 数据保留不动。

### S1：核心链路（全民推广码 + 活动管理 + 点击追踪）

**工期**: 4 天 | **人员**: 后端 2 人并行，前端 1 人

**前置条件**: S0 完成

**后端两条并行线**：

| 线 | 开发者 | 涉及文件 | 功能 |
|----|--------|---------|------|
| 线A（基础设施） | 后端A | M01+M02+M03+M04 | schema 新表/routes/auth 改造 |
| 线B（业务逻辑） | 后端B | F01+F02 | referral_handler + campaign_handler |

**前端（S1后半段开始）**:

| 任务 | 涉及文件 | 功能 |
|------|---------|------|
| admin 侧边栏改造 | M08 | 新增营销中心 Tab 菜单 |
| 活动管理页面 | F07+F08+F09 | 活动列表/创建/详情 |

**S1 → S2 前置条件**: schema.rs 新表已上线（确保 F01/F02/F03 可读写 DB）

### S2：结算提现 + 支付联动

**工期**: 4 天 | **人员**: 后端 1 人 + 前端 1-2 人并行

**前置条件**: S1 完成（新表就绪，活动管理页面可用）

**后端并行**：
| 文件 | 功能 |
|------|------|
| F03 (distribution_handler.rs) | 佣金/提现/结算/退款联动/通知 |
| M06 (pay_handlers.rs) | 支付回调接入归因 |
| F04 (campaign_scheduler.rs) | cron 解锁任务 |

**前端并行**：
| 文件 | 功能 |
|------|------|
| F10+F11 | 分销团队页面 |
| F12+F13+F14 | 佣金结算页面 |
| F15 | 提现审核页面 |
| F17+F18+F19 | 用户端收益/团队/提现 |

### S3：推送 + 数据统计 + LLM 生成

**工期**: 3 天 | **人员**: 后端 1 人 + 前端 1 人并行

**前置条件**: S2 完成（佣金/通知基础设施就绪）

**后端**：
| 文件 | 功能 |
|------|------|
| F05 (llm_poster.rs) | LLM 海报/H5 生成 |
| F04 (campaign_scheduler.rs 推送部分) | 活动推送触发 |
| M02 (routes.rs 添加频率限制) | click 60/min, poster 5/min |

**前端**：
| 文件 | 功能 |
|------|------|
| F20 (notification_panel.dart) | 通知中心 |
| F16 (admin_stats_dashboard.dart) | 数据统计面板 |
| F21 (share_widget.dart) | 分享弹窗 |
| M09+M10 | profile/pay 集成 |

### S4：测试 + 上线

**工期**: 2 天 | **人员**: 全体

**前置条件**: S3 完成

| 类型 | 内容 |
|------|------|
| 单元测试 | 点击追踪 / 绑定逻辑 / 佣金计算 / 折扣应用 / 推广码生成 |
| 集成测试 | 注册→绑定→支付→佣金 全链路 |
| 数据迁移 | VPS 回填 subscription_expires + referred_by 初始化 |
| 回归测试 | 确保 subscription_expires 迁移不破坏现有订阅查询 |

---

## 四、任务列表

### T01：subscription_expires 数据迁移（S0）

| 字段 | 内容 |
|------|------|
| **任务名称** | subscription_expires 从 user_preferences 迁入 users 表 |
| **涉及文件** | M05 (subscription.rs), M07 (admin_handlers.rs), F06 (迁移 SQL) |
| **前置依赖** | 无 |
| **验收标准** | ① `subscription.rs` 中读到期日 `get_current_expires()` 从 `SELECT users.subscription_expires` 获取 ② 写到期日 `set_expires()` 从 `INSERT user_preferences` 改为 `UPDATE users SET subscription_expires=` ③ `admin_handlers.rs` 中所有用户列表查询去掉 `LEFT JOIN user_preferences`，直接读 `users.subscription_expires` ④ 迁移 SQL 可回填已有数据 ⑤ 部署后先跑回填再发代码 |

---

### T02：Schema + 基础设施 + 路由注册（S1 线A）

| 字段 | 内容 |
|------|------|
| **任务名称** | 新表创建 + 用户表扩字段 + 路由注册 + 新模块声明 |
| **涉及文件** | M01 (schema.rs), M02 (routes.rs), M03 (lib.rs), M04 (auth.rs) |
| **前置依赖** | T01（建议串行，避免 schema 冲突）；但可与 T01 并行（不同模块） |
| **验收标准** | ① `schema.rs` 的 `SCHEMA_SQL` 中包含 7 张新表（marketing_campaigns, referral_clicks, settlement_batches, distribution_commissions, distribution_withdrawals, user_notifications, reward_fulfillments）② `users` 表增加 `referral_code TEXT UNIQUE` 和 `referred_by TEXT REFERENCES users(id)` 字段 ③ `lib.rs` 中增加 `pub mod referral_handler;` / `pub mod campaign_handler;` / `pub mod distribution_handler;` / `pub mod campaign_scheduler;` / `pub mod llm_poster;` ④ `routes.rs` 中注册全部 30+ 条新路由（§七 API 清单） ⑤ `auth.rs` 中 `RegisterRequest` 增加可选字段 `referral: Option<ReferralInfo>`，注册逻辑中实现：查推广码→找推广员→写 referred_by→生成自己的 referral_code |

---

### T03：推广码 + 点击追踪 + 活动管理（S1 线B）

| 字段 | 内容 |
|------|------|
| **任务名称** | 推广码/点击追踪 API + 活动 CRUD API |
| **涉及文件** | F01 (referral_handler.rs), F02 (campaign_handler.rs) |
| **前置依赖** | T02（需要 schema 和路由就绪） |
| **验收标准** | ① `referral_handler.rs` 实现：`GET /api/referral/my-code`（查看推广码）、`GET /api/referral/my-stats`（分享数据）、`POST /api/referral/click`（点击追踪→写入 referral_clicks 表→返回 click_id）、`GET /api/referral/my-team`（团队树，含递归查询）、`GET /api/referral/my-commissions`（佣金列表）② `campaign_handler.rs` 实现：活动 CRUD（GET/POST/PUT/DELETE）、启停（PATCH status）、手动推送（POST push）、统计数据（GET stats）③ 推广码生成规则：`CoEvo_` + 4位大写字母数字，UNIQUE 冲突自动重试最多3次 ④ `GET /api/referral/my-team` 使用 SQLite 递归 CTE，限制最多 2 级 |

---

### T04：管理端活动页面 + 侧边栏改造（S1 前端）

| 字段 | 内容 |
|------|------|
| **任务名称** | 管理端「营销中心」侧边栏 + 活动管理页面 |
| **涉及文件** | M08 (admin_screen.dart), F07 (admin_campaign_list.dart), F08 (admin_campaign_form.dart), F09 (admin_campaign_detail.dart) |
| **前置依赖** | T03（需要后端 API 就绪） |
| **验收标准** | ① `admin_screen.dart` 侧边栏新增「营销中心」可展开子菜单：活动管理 / 分销团队 / 佣金结算 / 待审核提现 / 数据统计 ② 活动列表页卡片视图，支持状态 badge、筛选 ③ 创建弹窗包含全部字段（名称/类型/时间/推送/奖励/限制）④ 活动详情页支持查看、编辑、启停、手动推送 ⑤ 子菜单路由正确跳转 |

---

### T05：佣金 + 结算 + 提现 + 支付联动（S2）

| 字段 | 内容 |
|------|------|
| **任务名称** | 佣金生成/解锁/结算 + 提现 + 支付回调归因 + 退款联动 + cron 任务 |
| **涉及文件** | F03 (distribution_handler.rs), M06 (pay_handlers.rs), F04 (campaign_scheduler.rs 解锁部分), F06 (F06 中的 order_timeout_minutes app_config) |
| **前置依赖** | T02（schema 就绪） |
| **验收标准** | ① 支付回调 `pay_notify_handler` 中查 `users.referred_by` → 查活动 rewards → 按 trigger=payment 生成 `distribution_commissions(locked)` 和 `reward_fulfillments`（幂等保护）② 退款回调把关联的 locked 佣金设为 cancelled ③ `POST /api/pay/calculate` 计算折后价（有无 referred_by / 活动是否有效 / 归因窗口是否超期），`GET /api/pay/plans` 返回套餐含折后价 ④ 结算批次创建：available 佣金勾选生成批次号 `ST{日期}-{序号}` ⑤ 提现审核：POST approve → 自动加入结算批次；POST reject → 需填写驳回原因 ⑥ NOTPAY 超时 cron 关单 + 折扣回收 ⑦ 30天自动解锁 cron 任务 ⑧ 站内通知：佣金到账、提现状态变更时写入 `user_notifications` |

---

### T06：管理端结算/提现/团队页面 + 用户端收益/团队/提现（S2 前端）

| 字段 | 内容 |
|------|------|
| **任务名称** | 管理端全部子页面 + 用户端分销页面 |
| **涉及文件** | F10 (admin_team_tree.dart), F11 (admin_user_detail_sheet.dart), F12 (admin_commission_list.dart), F13 (admin_batch_list.dart), F14 (admin_batch_detail.dart), F15 (admin_withdrawal_list.dart), F17 (earnings_page.dart), F18 (team_page.dart), F19 (withdraw_page.dart) |
| **前置依赖** | T05（需要后端 API） |
| **验收标准** | ① 分销团队页面支持搜索用户+树形展开 ② 用户详情弹窗展示分享记录/佣金明细/团队结构 ③ 佣金结算页面锁定中列表+勾选创建批次 ④ 批次列表+明细+CSV导出+标记已打款 ⑤ 提现审核列表+通过+驳回 ⑥ 用户端收益面板：累计收益/佣金明细/状态显示（locked/available/settled/paid）⑦ 用户端团队树 ⑧ 用户端提现页面：金额/手续费/确认弹窗 |

---

### T07：活动调度器 + 通知中心 + 数据统计 + LLM 生成（S3）

| 字段 | 内容 |
|------|------|
| **任务名称** | 推送调度/通知/统计/LLM 海报生成 |
| **涉及文件** | F04 (campaign_scheduler.rs 推送部分), F05 (llm_poster.rs), F16 (admin_stats_dashboard.dart), F20 (notification_panel.dart), F21 (share_widget.dart), M09 (profile_screen.dart), M10 (pay_screen.dart) |
| **前置依赖** | T05 + T06（佣金和通知基础设施就绪） |
| **验收标准** | ① 活动调度器按 push_trigger 推送：registration（注册时触发）、login（登录时检查）、cron（定时批量推送）、manual（管理端手动推送）→ 写入 `user_notifications` ② 前端通知中心：轮询 60s GET /api/notifications、未读小红点、标记已读、全部已读、通知分类展示（营销/收益/提现）③ 数据统计面板：指标卡（活动数/参与数/佣金/待审核提现）、趋势图（7天/30天）、漏斗（曝光→点击→注册→支付）、分销员排行、按月统计/导出CSV ④ LLM 海报生成：POST /api/referral/generate-poster（返回 SVG + 配文）、POST /api/referral/generate-h5（保存到 /share/{code}/index.html 返回 URL）、GET /api/referral/user-portrait（用户学习画像数据）⑤ SVG 中 QR_PLACEHOLDER 替换为真实二维码（qrcode crate）⑥ 频率限制：click 60/min, poster 5/min, team 10/min ⑦ 用户个人页新增推广码展示+复制按钮 ⑧ 支付页折扣横幅展示+优惠到期倒计时 ⑨ share_widget 包含朋友圈（保存海报）和会话（复制 H5 链接）两个按钮 |

---

### T08：测试 + 数据迁移 + 部署上线（S4）

| 字段 | 内容 |
|------|------|
| **任务名称** | 单元测试 + 集成测试 + VPS 数据迁移 + 回归测试 |
| **涉及文件** | 全量 |
| **前置依赖** | T01~T07 全部完成 |
| **验收标准** | ① 单元测试覆盖：点击追踪（匿名去重/归因窗口/自链接排除）、绑定逻辑（不可逆/非法 code 静默跳过/已删除推广员）、佣金计算（各级比例/30天解锁/退款取消）、折扣应用（折后价/NOTPAY 回收）、推广码生成（UNIQUE 冲突重试/最多3次跳过）② 集成测试：mock 支付回调，验证注册→绑定→支付→佣金全链路 ③ VPS 数据迁移：回填 subscription_expires + 初始化 referred_by ④ 回归测试：确保 subscription_expires 迁移不破坏现有订阅查询 ⑤ 部署后线上验证：创建活动→查看活动列表→模拟点击→验证追踪 |

---

## 五、任务依赖关系图

```
T01 (数据迁移) ──→ 无依赖（独立前置）
                      
T02 (Schema+路由) ──→ 依赖 T01（建议串行）
    │
    ├──→ T03 (推广码+活动API) ──→ 依赖 T02
    │       │
    │       └──→ T04 (管理端活动页面) ──→ 依赖 T03
    │
    └──→ T05 (佣金+结算+支付联动) ──→ 依赖 T02
            │
            ├──→ T06 (前端结算/提现/团队页面) ──→ 依赖 T05
            │
            └──→ T07 (推送+通知+统计+LLM) ──→ 依赖 T05+T06

T08 (测试+上线) ──→ 依赖 T01~T07

并行建议：
  T01 与 T02 可并行（不同文件，注意 schema 冲突）
  T03 与 T05 可并行（不同 handler，共用 schema）
  T04 与 T06/T07 前端的部分可并行（不同页面）
  T06 前端与 T07 后端可并行
```

---

## 六、风险提示

### 6.1 高风险项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| R01 | **SQLite 递归 CTE 性能**: 团队树查询（`referral_handler.rs` 的 `/my-team`）使用递归 CTE，当团队规模 > 1000 人时可能慢 | 用户体验差，接口超时 | 限制递归深度 2 级；给 `users.referred_by` 加索引；可考虑缓存团队快照 |
| R02 | **推广码 UNIQUE 冲突**: 高并发注册场景下（如活动引爆），推广码生成可能频繁冲突 | 注册延迟 | 冲突后重试逻辑要健壮；预生成一批推广码备用（可选优化） |
| R03 | **LLM 生成海报失败兜底**: SVG 海报依赖 LLM 输出质量，LLM 可能生成不合法 SVG 或非 JSON 格式 | 用户看到空白海报 | 必须实现三级降级：缓存 → 昨日缓存 → 默认模板（品牌图+推广码） |
| R04 | **佣金状态一致性**: 支付回调 + 退款回调 + 30 天解锁 cron 同时操作同一条佣金记录 | 数据不一致 | 所有佣金操作在事务内执行；cron 任务加分布式锁（SQLite 用 `BEGIN IMMEDIATE`）|

### 6.2 中风险项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| R05 | **subscription_expires 迁移遗漏**: 代码中还有未走 `users.subscription_expires` 的读/写路径 | 订阅数据不一致 | 代码发布前 grep 所有 `user_preferences` 引用，逐个确认 |
| R06 | **前端暂无路由框架**: 当前管理端页面都在 admin_screen.dart 中通过 Tab 切换，但设计文档要求 GoRouter 路由 | 架构切换成本 | 建议统一使用 GoRouter（现有 main.dart 已引入 go_router），为新页面定义独立路由 `/admin/campaigns` 等 |
| R07 | **管理端侧边栏插入位置**: 现有侧边栏是硬编码的 Tab 索引（如 `_configTabIdx` 通过角色计算），插入新菜单后索引偏移 | 现有 Tab 错乱 | 建议重构为基于 Map 的菜单定义，而非硬编码索引；或在原有索引计算中插入营销中心的位置调整 |

### 6.3 低风险项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| R08 | **微信 OAuth 集成**: 设计文档提到从微信扫码进入需要读取 URL 参数，但 Flutter Web 处理 OAuth 回调需要特殊处理 | 扫码注册流程不通 | Flutter Web 中使用 `html.window.location.search` 读取 ref/camp 参数；测试需在真实微信浏览器中验证 |
| R09 | **多活动折扣互斥**: 同一笔订单可能匹配多个活动的 discount 规则 | 折扣重复 | 设计文档已明确：只取最新一条含 discount 的活动（按 created_at DESC），前端和后端应一致执行此规则 |
| R10 | **OG 图片存储**: LLM 生成的 H5 页面需要 OG 图片，存储在服务器磁盘上 | 磁盘占用增长 | OG 图片是固定模板（300×300 PNG），每个用户仅一张，磁盘占用可忽略；H5 页面每天更新覆盖旧文件 |

### 6.4 实施建议

1. **先跑通核心链路，再加高级功能**: S1 只做"注册→绑定→点击→活动CRUD"，S2 再叠加"支付→佣金→结算→提现"，S3 再叠加"推送→LLM→统计"
2. **所有新 API 增加频率限制**: 复用已有的 `rate_limiter.rs`，click 60/min, poster 5/min, team 10/min
3. **SQLite 外键约束**: 确保 `init_database()` 后执行 `PRAGMA foreign_keys = ON`
4. **幂等保护**: `reward_fulfillments` 核销前必须按 `(campaign_id, referral_click_id/order_id, reward_type, party)` 查重
5. **建议使用 GoRouter 管理新前端页面**: 不要把所有页面塞进 admin_screen.dart 的 Tab 里，用独立路由隔离页面逻辑

---

## 七、总结

| 维度 | 数据 |
|------|------|
| 总任务数 | 8（T01-T08）|
| 新增后端文件 | 5 个 Rust 文件 + 1 个迁移 SQL |
| 修改后端文件 | 6 个 Rust 文件 |
| 新增前端文件 | 12+4 个 Dart 文件 |
| 修改前端文件 | 3 个 Dart 文件 |
| 总工期估算 | 12-14 天（S0 1d + S1 4d + S2 4d + S3 3d + S4 2d，考虑并行约 10-11 天）|
| 并行峰值 | 后端 2 人 + 前端 1-2 人 |
