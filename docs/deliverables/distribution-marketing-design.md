# CoEvo 微信营销与分销体系设计方案

> 版本: v2.0 · 2026-06-17  
> 状态: 设计稿（定稿）

---

## 一、设计原则

### 1.1 核心目标

1. **全链路闭环**: 管理端创建活动 → 后端规则引擎 → 前端触达用户 → 用户分享 → 追踪转化 → 奖励结算，每个环节可追溯
2. **全民分销**: 每个注册用户自动成为分销员，零门槛参与，目标是自然裂变而非招募专业推手
3. **归属清晰**: 每一笔订单必须能追溯到具体的推广链路（谁分享、谁点击、谁购买），杜绝"不知道是谁推销出去的"
4. **活动可扩展**: 活动类型、奖励规则、推送条件由配置驱动，新增活动类型不改代码

---

## 二、数据链路总览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          管理端 (营销中心)                                 │
│  活动配置 → 规则设定 → 效果统计 → 提现审核 → 分销团队管理                   │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ 写入 marketing_campaigns
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          后端 (规则引擎)                                   │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ 活动调度器    │→│ 推送触发器   │→│ 归因引擎      │→│ 结算引擎      │ │
│  │ 定时/条件触发 │  │ 站内通知/弹窗 │  │ 链接匹配/时间窗│  │ 佣金/时长计算  │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘ │
│                         │                    ↑              │            │
│                         ▼                    │              ▼            │
│                  ┌──────────────┐            │      ┌──────────────┐     │
│                  │ 用户收到推送   │────────────┘      │ 写入佣金记录   │     │
│                  └──────────────┘                     └──────────────┘     │
└─────────────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          前端 (Flutter Web)                               │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ 分享入口      │  │ 分享弹窗     │  │ 分销面板      │  │ 下单页追踪   │  │
│  │ 个人页/弹窗   │  │ 复制链接/保存│  │ 收益/团队/记录│  │ 携带 ref 参数 │  │
│  │              │  │ 海报         │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 三、数据表设计（完整版）

### 3.1 marketing_campaigns（营销活动定义）

```sql
CREATE TABLE marketing_campaigns (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    campaign_type TEXT NOT NULL,          -- invite_award / commission / discount_pct / discount_fix
    status TEXT DEFAULT 'draft',          -- draft / active / paused / ended

    -- 时间控制
    valid_from TEXT,
    valid_until TEXT,

    -- 推送规则
    push_trigger TEXT,                    -- registration / first_payment / login / manual / cron
    push_content TEXT,                    -- 推送文案 ({name} 会被替换, {role} 也可用)

    -- 目标角色（JSON 数组, 空 = 全部角色）
    target_roles TEXT DEFAULT '[]',       -- '["student"]' / '["teacher","guardian"]' / "[]"

    -- 分享文案模板
    share_text TEXT,                      -- "推荐 CoEvo AI 学英语, 一起进步!"

    -- 邀请者奖励
    reward_inviter_type TEXT,             -- days / discount_coupon / commission_pct / none
    reward_inviter_value TEXT,            -- 如 "7"（天）或 "2000"（2000分优惠券）

    -- 被邀请者奖励
    reward_invitee_type TEXT,
    reward_invitee_value TEXT,

    -- 佣金比例（仅 commission 类型生效）
    commission_rate_l1 REAL DEFAULT 0.00, -- 一级佣金比例
    commission_rate_l2 REAL DEFAULT 0.00, -- 二级佣金比例

    -- 归因窗口（天）
    attribution_window INTEGER DEFAULT 30,

    -- 参与限制
    max_participants INTEGER,            -- NULL = 不限
    per_user_limit INTEGER,              -- 每人最多参与次数, NULL = 不限

    -- 统计缓存
    participant_count INTEGER DEFAULT 0,
    conversion_count INTEGER DEFAULT 0,
    total_reward INTEGER DEFAULT 0,

    created_at TEXT NOT NULL,
    updated_at TEXT
);

CREATE INDEX idx_campaigns_status ON marketing_campaigns(status, valid_from, valid_until);
```

**campaign_type 说明**:

| 类型 | 说明 | 示例场景 |
|:----|:-----|:---------|
| `invite_award` | 邀请有奖（送时长/优惠券） | 新上线路, 邀请好友各得 3 天 |
| `commission` | 分销返佣（现金比例） | 长期活动, 一级 10%, 二级 5% |
| `discount_pct` | 被邀请者首单折扣 | 邀请者获赠时长, 被邀请者首单 8 折 |
| `discount_fix` | 被邀请者首单立减 | 邀请者获赠 7 天, 被邀请者立减 ¥5 |

**push_trigger 说明**:

| 触发条件 | 说明 |
|:---------|:-----|
| `registration` | 新注册用户自动推送 |
| `first_payment` | 首次支付成功后推送 |
| `login` | 用户登录时检查是否有未推送的活动 |
| `manual` | 仅管理员手动推送 |
| `cron` | 按 cron 表达式定时推送 |

### 3.2 user_referral_codes（用户推广码 - 全量覆盖）

每个注册用户自动获得一个唯一推广码，无需手动开通。

```sql
CREATE TABLE user_referral_codes (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL UNIQUE,          -- 每个用户唯一一条
    referral_code TEXT NOT NULL UNIQUE,    -- 6-8 位串, 如 "CoEvo_A1B2"
    qr_code_url TEXT,                      -- 二维码图片URL（延时生成）
    total_clicks INTEGER DEFAULT 0,        -- 累计点击
    total_registrations INTEGER DEFAULT 0, -- 累计注册
    total_conversions INTEGER DEFAULT 0,   -- 累计转化
    total_earned INTEGER DEFAULT 0,        -- 累计收入（分）
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_referral_code ON user_referral_codes(referral_code);
```

**referral_code 生成规则**: `CoEvo_` + 随机 4 位字母数字大写, 如 `CoEvo_A1B2`

### 3.3 referral_clicks（分享点击追踪）

每次用户点击分享链接都记录，用于归因分析。

```sql
CREATE TABLE referral_clicks (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,             -- 关联活动
    referrer_id TEXT NOT NULL,             -- 分享者 user_id
    clicker_anonymous_id TEXT,             -- 点击者匿名标识 (device_id / IP + UA hash)
    clicker_ip TEXT,
    clicker_user_agent TEXT,
    landed_page TEXT,                      -- 落地页
    converted INTEGER DEFAULT 0,           -- 是否最终转化
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (referrer_id) REFERENCES users(id)
);

CREATE INDEX idx_clicks_campaign ON referral_clicks(campaign_id);
CREATE INDEX idx_clicks_referrer ON referral_clicks(referrer_id);
CREATE INDEX idx_clicks_anonymous ON referral_clicks(clicker_anonymous_id);
```

### 3.4 referral_conversions（转化归因表）

记录"哪个分享最终转化成了哪个订单"，实现清晰的归属链路。

```sql
CREATE TABLE referral_conversions (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    click_id TEXT NOT NULL,                -- 关联 referral_clicks
    referrer_id TEXT NOT NULL,             -- 分享者（最终获佣人）
    buyer_id TEXT NOT NULL,                -- 购买者 user_id
    order_id TEXT NOT NULL,                -- 关联 payment_orders
    level INTEGER DEFAULT 1,              -- 1=一级, 2=二级
    amount INTEGER NOT NULL,              -- 订单金额（分）
    reward_type TEXT,                      -- 奖励类型
    reward_value TEXT,                     -- 奖励值
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id),
    FOREIGN KEY (buyer_id) REFERENCES users(id)
);

CREATE INDEX idx_conversion_buyer ON referral_conversions(buyer_id);
CREATE INDEX idx_conversion_referrer ON referral_conversions(referrer_id);
CREATE INDEX idx_conversion_order ON referral_conversions(order_id);
```

### 3.5 settlement_batches（结算批次）

每批对应一次财务人员的手动转账操作，包含唯一的转账凭证。

```sql
CREATE TABLE settlement_batches (
    id TEXT PRIMARY KEY,
    batch_no TEXT NOT NULL UNIQUE,           -- 批次号, 如 "ST20260617-001"
    total_amount INTEGER NOT NULL DEFAULT 0, -- 本批总金额（分）
    item_count INTEGER NOT NULL DEFAULT 0,   -- 本批佣金条数
    status TEXT DEFAULT 'pending',           -- pending / paid
    proof_image_url TEXT,                    -- 转账截图凭证
    note TEXT,                               -- 备注说明
    created_at TEXT NOT NULL,
    paid_at TEXT,
    handled_by TEXT                          -- 操作管理员 ID
);
```

**批次号规则**: `ST{日期}-{当日序号}`, 如 `ST20260617-001`, `ST20260617-002`

### 3.6 distribution_commissions（佣金结算记录）

```sql
CREATE TABLE distribution_commissions (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    conversion_id TEXT NOT NULL,
    earner_id TEXT NOT NULL,               -- 获佣用户
    level INTEGER NOT NULL,                -- 1=一级, 2=二级
    amount INTEGER NOT NULL,              -- 佣金（分）
    status TEXT DEFAULT 'earned',           -- earned / settled / paid / cancelled
    batch_id TEXT,                          -- 关联结算批次（null = 未归入任何批次）
    batch_settled_at TEXT,                  -- 归入批次时间
    paid_at TEXT,                           -- 实际到账时间
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (conversion_id) REFERENCES referral_conversions(id),
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id)
);

CREATE INDEX idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX idx_commission_batch ON distribution_commissions(batch_id);
```

**状态流转**:

```
earned (待结算) ──→ settled (已结待付) ──→ paid (已打款)
                         │                      │
                    归入结算批次              上传凭证完成
```

### 3.6 distribution_withdrawals（提现申请）

```sql
CREATE TABLE distribution_withdrawals (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    amount INTEGER NOT NULL,               -- 提现金额（分）
    fee INTEGER DEFAULT 0,                 -- 手续费
    actual_amount INTEGER,                 -- 实际到账
    status TEXT DEFAULT 'pending',          -- pending / approved / rejected / paid
    note TEXT,                              -- 驳回原因或备注
    batch_id TEXT,                          -- 归入的结算批次（打款时关联）
    created_at TEXT NOT NULL,
    handled_at TEXT,
    handled_by TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_withdrawal_status ON distribution_withdrawals(status);
```

### 3.7 user_notifications（站内通知表）

用于推送营销活动到用户端。

```sql
CREATE TABLE user_notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    notification_type TEXT NOT NULL,        -- marketing_campaign / reward_earned / withdrawal_status
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    action_url TEXT,                        -- 点击跳转链接
    related_id TEXT,                        -- 关联 ID（如 campaign_id）
    read INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_notifications_user ON user_notifications(user_id, read, created_at);
```

### 3.9 角色过滤逻辑

活动配置 `target_roles` 字段控制**哪些角色可以参与分享**。注意：无论分享者是什么角色，推广目标始终是学生用户。

```
target_roles = '["student"]'                → 仅学生端看到, 学生分享给学生
target_roles = '["teacher","guardian"]'     → 教师和家长端看到, 他们分享给学生
target_roles = '[]' 或 NULL                 → 全部角色可见
```

后端查询时按角色过滤:

```sql
SELECT * FROM marketing_campaigns
WHERE status = 'active'
  AND (target_roles IS NULL OR target_roles = '[]' OR target_roles LIKE '%"student"%')
  AND valid_from <= datetime('now')
  AND valid_until > datetime('now')
```

---

## 四、归因规则

### 4.1 分销链路归属机制

```
用户 A 分享链接 → 用户 B 点击 → 浏览器 localStorage 记录 "ref_by=A"
  → B 未注册离开 → 3 天后 B 再次打开
  → 浏览器读取 localStorage → "ref_by=A" (还在归因窗口内)
  → B 注册 → user_referral_codes 写入 parent_id = A
  → B 购买 → referral_conversions 写入 referrer_id = A
```

### 4.2 归因规则

| 场景 | 规则 |
|:----|:-----|
| **首次点击归属** | 同一个设备第一点击的分享者获得归属权，后续点击不覆盖 |
| **归因窗口** | 从首次点击起 30 天内有效，超期后点击不归因 |
| **自链接排除** | 用户点击自己的分享链接不计入 |
| **二级归因** | B 购买 → 一级佣金归 A；同时查 A 的 parent_id → 二级佣金归上级 |
| **多活动互斥** | 同一笔订单只归属最近一次点击的活动，不重复计算 |

### 4.3 前端追踪逻辑

```javascript
// 用户点击分享链接时，URL 参数携带: ref=CoEvo_A1B2&campaign=camp_xxx
// 前端立即存入 localStorage:
localStorage.setItem('coevo_ref', JSON.stringify({
  code: 'CoEvo_A1B2',
  campaign_id: 'camp_xxx',
  timestamp: Date.now(),
  clicked_by: device_id,  // 匿名设备ID
}))

// 用户注册时, 前端将 localStorage 中的 ref 信息提交给后端
POST /api/auth/register { ..., referral: { code: 'CoEvo_A1B2', campaign_id: 'camp_xxx' } }
```

---

## 五、全链路流程详解

### 5.1 活动创建 → 前端推送链路

```
管理端操作                    后端                          前端
─────────                    ────                          ────
创建活动 (填写表单) ──→ marketing_campaigns.insert()
                              │
                              ├── 活动调度器检查 push_trigger
                              │    ├── registration → 新用户注册时触发推送
                              │    ├── login → 用户登录时检查
                              │    ├── cron → 定时任务批量推送
                              │    └── manual → 管理端手动点"推送"
                              │
                              ├── user_notifications.insert()
                              │    └── 前端轮询 GET /api/notifications
                              │         └── 收到 → 弹窗展示活动
                              │              └── 用户点击"立即分享"
                              │                   └── 生成分享链接
                              ▼
                          referral_clicks 追踪开始
```

### 5.2 分享 → 转化 → 结算链路

```
用户分享                    后端                          管理端
────────                    ────                          ────
A 点击"立即分享" ──→ 生成链接: /app/?ref=CoEvo_A1B2
  │                           &campaign=camp_xxx
  ├── 发微信给 B
  │
  ▼
B 点击链接 ──→ referral_clicks.insert()
  │              (记录 referrer_id = A, clicker = B 的设备)
  │
  ▼
B 注册 ──→ user_referral_codes.insert()
  │         referral_conversions.insert()
  │          (记录 click_id, referrer_id = A, buyer_id = B)
  │         前端展示: "你被 {A} 邀请, 可获得首单优惠"
  │
  ▼
B 购买 ──→ pay_notify_handler
  │         ├── 查 referral_conversions WHERE buyer_id = B
  │         ├── 查 marketing_campaigns 获取佣金规则
  │         ├── distribution_commissions.insert()   ← 一级佣金给 A
  │         ├── 查 A 的 parent_id → C
  │         ├── distribution_commissions.insert()   ← 二级佣金给 C
  │         ├── user_notifications.insert()         ← 通知 A "你获得 ¥XX 佣金"
  │         └── marketing_campaigns 统计更新
  │
  ▼
A 查看面板              ──→           管理端统计: 总佣金 / 转化率 / 团队树
```

### 5.3 完整分销链路示例

```
【可追溯的完整链路】

用户 A (root)
  ├── referral_code: CoEvo_A1B2
  ├── 分享了给 → B
  ├── B 注册, parent_id = A
  │   ├── referral_code: CoEvo_C3D4
  │   ├── B 购买了 ¥200 月卡
  │   ├── ★ 一级佣金 ¥20 → A
  │   ├── 分享了给 → D
  │   └── D 购买了 ¥1280 终身
  │       ├── ★ 一级佣金 ¥128 → B
  │       └── ★ 二级佣金 ¥64  → A
  └── 分享了给 → C
      └── C 购买了 ¥200 月卡
          └── ★ 一级佣金 ¥20 → A

管理端看到:
  A 的团队: 3 人 (B, C, D)
  A 的总佣金: ¥20 + ¥20 + ¥64 = ¥104
  每笔订单均可追溯: 订单 OE123456 → B 购买 → A 分享 → 活动 xxx
```

---

## 六、管理端界面设计

### 6.1 页面结构

```
营销管理中心
│
├── 📊 数据总览（默认首页）
│   ├── 顶部指标卡: 进行中活动 / 参与用户数 / 本月分销成交 / 待审核提现
│   ├── 趋势图: 新增分享 / 新增注册 / 成交金额 (7天/30天)
│   └── 分销排行: Top 10 分销员（累计佣金 / 团队规模 / 转化率）
│
├── 📋 活动管理
│   ├── 活动列表（表格）
│   │   名称 | 类型 | 状态 | 推送触发 | 参与人数 | 转化率 | 操作
│   ├── 新建活动（表单弹窗）
│   │   ├── 基本信息: 名称 / 描述 / 类型
│   │   ├── 时间控制: 开始 / 结束
│   │   ├── 推送规则: 触发条件 / 推送文案
│   │   ├── 奖励设置: 邀请者 / 被邀请者 / 佣金比例
│   │   └── 限制: 参与上限 / 每人限次 / 归因窗口
│   └── 活动详情（查看 / 编辑 / 启停 / 手动推送按钮）
│
├── 👥 分销团队
│   ├── 搜索: 用户 ID / 昵称 / referral_code
│   ├── 团队列表（树形可展开）
│   │   A (root, 分享 3 次, 收入 ¥104)
│   │   ├── B (上级 A, 分享 1 次, 收入 ¥128)
│   │   │   └── D (上级 B, 购买 ¥1280)
│   │   └── C (上级 A, 购买 ¥200)
│   └── 用户详情弹窗: 分享记录 / 佣金明细 / 团队结构
│
├── 💰 佣金结算（批次管理）
│   ├── 待结算佣金列表（earned 状态）
│   │   用户 | 金额 | 来源订单 | 时间 | 操作(勾选加入批次)
│   ├── 创建结算批次: 勾选佣金 → 生成批次号 ST20260617-001 → 确认总金额
│   ├── 已结待付（settled 状态, 按批次展示）
│   │   批次号 | 条数 | 总金额 | 时间 | 状态 | 操作
│   │   ├── 查看批次明细（该批次包含的所有佣金）
│   │   ├── 下载批次汇总（CSV, 方便对照打款）
│   │   └── 标记已打款 + 上传转账截图
│   └── 已打款记录（paid 状态）
│       批次号 | 总金额 | 凭证(缩略图) | 打款时间 | 操作(查看大图)
│
├── 📊 按月统计
│   ├── 月份选择器
│   ├── 本月新增佣金 / 本月已结 / 本月打款 / 待结算
│   └── 按月导出报表
│
└── 📈 活动与财务数据
    ├── 按活动查看: 曝光 → 点击 → 注册 → 支付 漏斗
    ├── **按月统计: 月份选择器 → 总佣金 / 已提现 / 待提现 / 提现人数 / 打款明细列表**
    ├── 按用户查看: 某用户的所有分享行为
    ├── 导出 CSV
    └── 转账凭证管理: 按月份/用户搜索截图
```

### 6.2 新建活动表单完整字段

| 分组 | 字段 | 类型 | 说明 |
|:----|:-----|:-----|:-----|
| **基本信息** | 活动名称 | text | 用户端展示的名称 |
| | 活动描述 | text | 内部备注 |
| | 活动类型 | select | invite_award / commission / discount_pct / discount_fix |
| **目标角色** | **适用角色** | **checkbox 多选** | **student / teacher / guardian, 控制谁可以看到并分享此活动** |
| | 分享文案 | text | 分享给他人时展示的推荐语 |
| **时间控制** | 开始时间 | datetime | 在此时间之前活动不生效 |
| | 结束时间 | datetime | 在此时间之后活动自动结束 |
| **推送规则** | 推送触发 | select | registration / first_payment / login / manual / cron |
| | 推送文案 | text | 支持 {name} 变量替换 |
| **奖励规则** | 邀请者奖励类型 | select | days / discount_coupon / commission_pct / none |
| | 邀请者奖励值 | text | 数值 |
| | 被邀请者奖励类型 | select | days / discount_fix / discount_pct |
| | 被邀请者奖励值 | text | 数值 |
| | 一级佣金比例 | number | 0.00 - 1.00 |
| | 二级佣金比例 | number | 0.00 - 1.00 |
| **归因设置** | 归因窗口(天) | number | 默认 30 |
| **限制** | 参与人数上限 | number | 空 = 不限 |
| | 每人参与上限 | number | 空 = 不限 |

---

## 七、API 接口完整清单

### 7.1 营销活动（管理员）

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/campaigns` | 活动列表 |
| POST | `/api/admin/campaigns` | 创建活动 |
| GET | `/api/admin/campaigns/{id}` | 活动详情 |
| PUT | `/api/admin/campaigns/{id}` | 编辑活动 |
| DELETE | `/api/admin/campaigns/{id}` | 删除活动（仅 draft 状态） |
| PATCH | `/api/admin/campaigns/{id}/status` | 启停活动 (active/paused/ended) |
| POST | `/api/admin/campaigns/{id}/push` | 手动推送活动到用户 |
| GET | `/api/admin/campaigns/{id}/stats` | 活动统计数据 |

### 7.2 推广码（用户端 + 管理员）

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/referral/my-code` | 查看自己的推广码 |
| GET | `/api/referral/my-stats` | 查看自己的分享数据 |
| GET | `/api/referral/my-team` | 查看团队（树形）|
| GET | `/api/referral/my-commissions` | 查看佣金记录 |

### 7.3 通知推送

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/notifications` | 获取未读通知 |
| PATCH | `/api/notifications/{id}/read` | 标记已读 |

### 7.4 结算批次（管理员）

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/settlement/pending-commissions` | 待结算佣金列表（earned）|
| POST | `/api/admin/settlement/create-batch` | 创建结算批次（传入佣金ID列表）|
| GET | `/api/admin/settlement/batches` | 结算批次列表（含状态/凭证）|
| GET | `/api/admin/settlement/batches/{id}` | 批次明细（所有佣金 + 用户信息）|
| GET | `/api/admin/settlement/batches/{id}/export` | 下载批次汇总 CSV（方便打款对照）|
| POST | `/api/admin/settlement/batches/{id}/mark-paid` | 标记已打款 + 上传转账截图 |
| GET | `/api/admin/settlement/proof/{filename}` | 查看转账截图 |

### 7.5 数据统计

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/distribution/summary` | 分销总览（指标卡）|
| GET | `/api/admin/distribution/monthly-stats` | **按月统计报表**（含总佣金 / 已提现 / 待提现 / 提现人数）|
| GET | `/api/admin/distribution/funnel` | 转化漏斗数据 |
| GET | `/api/admin/distribution/ranking` | 分销员排行 |
| GET | `/api/admin/distribution/export` | 导出 CSV |

### 7.6 凭证上传

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/admin/upload/proof` | 上传转账截图，返回 URL，存储在 `data/proofs/{date}/` 目录 |
| GET | `/api/admin/proof/{filename}` | 查看转账截图（需管理员权限） |

---

## 八、前端用户端界面补充

### 8.1 个人页新增

1. **我的推广码**（个人页信息栏下方）
   - 显示 `CoEvo_A1B2` + 复制按钮
   - 点击弹出分享弹窗

2. **分享弹窗**
   - 当前活动标题 + 奖励说明
   - 分享链接（可复制）
   - 保存海报（二维码 + 推广码）
   - 一键复制文案: "我在用 CoEvo AI 学英语, 扫码一起学, 双方都得 7 天!"

3. **我的收益**（新页面或弹窗）
   - 累计收益
   - 佣金明细列表（订单 / 金额 / 状态）
   - 提现入口

4. **我的团队**（新页面）
   - 树形展示下级用户
   - 点击用户查看其下级（递归）

### 8.2 全角色覆盖

分销推广码按用户绑定，**不区分角色**。学生、教师、家长各自登录后都可以看到自己的推广入口。

| 角色 | 能否分享 | 推广目标 | 分享文案 |
|:----|:---------|:---------|:---------|
| **学生端** | ✅ | 其他学生 | 广告文案统一 |
| **教师端** | ✅ (若活动开放) | 学生 | 广告文案统一 |
| **家长端** | ✅ (若活动开放) | 学生(及其他家长) | 广告文案统一 |

**实现方式**: 将分享组件抽离为独立 Widget `ShareWidget`, 三端各自引用：

```
lib/
  widgets/
    share_widget.dart          ← ShareWidget 组件（含推广码显示 + 分享弹窗）
  screens/
    profile_screen.dart        ← 学生端引用 ShareWidget
    guardian_screen.dart       ← 家长/教师端引用 ShareWidget
```

后端无需任何修改, `user_referral_codes` 表按 `user_id` 关联，各角色共用同一套推广码和佣金系统。

---

## 九、v1.0 到 v2.0 的变更对比

| 维度 | v1.0 | v2.0（当前版本） |
|:----|:-----|:----------------|
| 分销员覆盖 | 需手动开通 | **所有用户自动拥有** referral_code |
| 归属追踪 | 仅 parent_id | 完整的 click → conversion → commission 链路 |
| 归因规则 | 无 | 首次点击归因 + 30 天窗口 + 自链接排除 |
| 推送链路 | 无 | 活动调度器 → user_notifications → 前端弹窗 |
| 活动配置 | 简单 | 完整表单（类型 / 奖励 / 推送 / 限制 / 归因）|
| 团队查看 | 仅管理员 | 管理员 + 用户自己可看团队树 |
| 数据统计 | 无 | 总览 / 漏斗 / 排行 / 导出 CSV |

---

## 十、实施计划

### P0：基础设施 + 全民推广码（3-4 天）

| 任务 | 涉及文件 |
|:----|:---------|
| 6 张新表 + schema 迁移 | schema.rs, main.rs |
| 用户注册时自动生成 referral_code + 记录 parent_id | auth.rs |
| 分享链接点击追踪（referral_clicks） | referral_handler.rs |
| 转化归因 + 结算引擎 | referral_handler.rs |
| 管理端活动 CRUD | campaign_handler.rs |
| 管理端活动管理页面 | admin_campaign_page.dart |
| 前端: 推广码展示 + 分享弹窗 | profile_screen.dart (新增) |

### P1：奖励结算 + 提现（4-5 天）

| 任务 | 涉及文件 |
|:----|:---------|
| 支付回调接入归因引擎 | pay_handlers.rs |
| 佣金/时长奖励结算 | distribution_handler.rs |
| 提现审核 | distribution_handler.rs |
| 用户端收益面板 | distribution_page.dart |
| 管理端提现审核页面 | admin_withdrawal_page.dart |
| 管理端分销团队页面 | admin_team_page.dart |
| 站内通知推送 | notification_handler.rs |

### P2：推送 + 数据（2-3 天）

| 任务 | 涉及文件 |
|:----|:---------|
| 活动调度器（定时/条件触发） | campaign_scheduler.rs |
| 前端通知中心 | notification_panel.dart |
| 管理端数据统计面板 | admin_stats_page.dart |
| 分享海报生成 | qrcode_handler.rs |
| 分享文案 + 一键复制 | share_utils.dart |

---

## 附录B：落脚页移动端适配

### B.1 问题

落脚页（`keyievolution.fun`）原版 CSS 无移动端媒体查询，在手机浏览器上存在以下问题：

- 对比区 3 列网格堆叠过窄
- Hero 区标题字号过大（50px）导致换行溢出
- 动画 iframe 固定 520px 高度超出屏幕
- 按钮在大屏上合适但在小屏上溢出
- 导航菜单在移动端缺少汉堡菜单交互
- 卡片内边距偏大，信息密度低

### B.2 改动

在 `landing/css/style.css` 尾部新增 `@media(max-width:480px)` 断点：

| 区域 | PC (默认) | 移动端 (≤480px) |
|:----|:---------|:----------------|
| Hero 标题 | clamp(28px,5vw,50px) | 24px |
| Hero 问题 | clamp(32px,5.8vw,58px) | 28px |
| 操作按钮 | 横向排列 | 全宽纵向堆叠 |
| 对比卡片 | 3 列 | 1 列 |
| iframe 高度 | 520px | 360px |
| 卡片内边距 | 36px 32px | 24px 20px |
| CTA 卡片 | 方向 row | 方向 column |
| 导航 | 水平链接 | 汉堡菜单（640px 断点已有）|
| Hero 最小高度 | 100svh | 90svh, 顶部对齐 |

### B.3 涉及文件

- `landing/css/style.css` — 新增 `@media(max-width:480px)` 块
- `landing/index.html` — 对比区 grid 添加 class `compare-cards` 以便 CSS 选择器覆盖

### B.4 备注

仅修改了 CSS 和一行 HTML class 名，未改动 HTML 内容结构。改动已在 2026-06-17 部署到 VPS `/var/www/coevo-landing/`。

---

## 十一、合规说明

1. **分销层级**: 严格限制 2 级，超过 2 级属传销
2. **佣金披露**: 用户协议中明确说明推广佣金规则
3. **提现审核**: 所有提现需人工审核，防止洗钱
4. **数据留存**: 完整的点击/转化/佣金流水，可审计
5. **防刷机制**: 同一设备/同一 IP 多账号注册需风控
6. **未成年人**: 不向未满 18 岁用户开放分销功能
