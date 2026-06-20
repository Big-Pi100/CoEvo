# CoEvo 微信营销与分销体系设计方案

> 版本: v2.1 · 2026-06-19  
> 状态: 实现中（持续更新）

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
│                  │ 用户收到推送   │────────────┘      │ 写入佣金记录   │    │
│                  └──────────────┘                     └──────────────┘    │
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

**设计原则**：优先扩展已有表，分销体系是用户系统的自然延伸，而非独立子系统。

```
扩展已有表:         新建表（无法避免）:
users               marketing_campaigns
  ├─ referral_code  referral_clicks
  ├─ referred_by    settlement_batches
  └─ subscription_expires (从 user_preferences 迁入)
                    distribution_commissions
payment_orders      distribution_withdrawals
  （无需扩展）      reward_fulfillments
                    user_notifications

消灭的中间表:
  user_referral_codes → users.referral_code
  referral_bindings   → users.referred_by
  referral_conversions → distribution_commissions（通过 order_id 关联）
```

---

### 3.1 marketing_campaigns（营销活动定义）

保持独立，完整保留。

```sql
CREATE TABLE marketing_campaigns (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    campaign_type TEXT NOT NULL,          -- invite_award / commission / discount_pct / discount_fix / mixed
    status TEXT DEFAULT 'draft',          -- draft / active / paused / ended

    -- 时间控制（活动有效期）
    valid_from TEXT,                       -- 活动开始时间（ISO 8601），NULL = 不限制
    valid_until TEXT,                      -- 活动结束时间（ISO 8601），NULL = 不限制

    -- 推送规则
    push_trigger TEXT,                    -- manual / registration / after_complete_review / plan_completed / login / cron
    push_cron TEXT,                       -- cron 表达式（push_trigger='cron' 时生效）
    push_content TEXT,                    -- 推送文案 ({name} 会被替换)

    -- 目标角色（JSON 数组, 空 = 全部角色）
    target_roles TEXT DEFAULT '[]',

    -- LLM 提示语（控制生成内容侧重点）
    poster_prompt TEXT,                     -- 自定义海报系统提示（留空使用默认 prompt）

    -- 奖励规则（JSON 数组，支持组合奖励）
    -- 示例: [{"type":"subscription_days","party":"self","value":3,"trigger":"registration"}]
    -- type: subscription_days（送天数）/ commission_pct（佣金比例）/ commission_fix（固定佣金）/ discount_pct（折扣比例）/ discount_fix（固定折扣）
    -- trigger: registration / referral_signup / click / payment / order_creation / plan_completed
    -- party: self（自己）/ inviter（推广方）/ invitee（被推广方）/ referrer（推荐人）
    rewards TEXT NOT NULL DEFAULT '[]',

    -- 归因窗口（天）
    attribution_window INTEGER DEFAULT 30,

    -- 参与限制
    max_participants INTEGER,
    per_user_limit INTEGER,

    created_by TEXT,                        -- 创建人 admin_id
    created_at TEXT NOT NULL,
    updated_by TEXT,                        -- 最后修改人 admin_id
    updated_at TEXT,
    FOREIGN KEY (created_by) REFERENCES admin_users(id),
    FOREIGN KEY (updated_by) REFERENCES admin_users(id)
);

CREATE INDEX idx_campaigns_status ON marketing_campaigns(status, valid_from, valid_until);
```

---

### 3.2 现有表扩展

#### users 表（新增 3 个字段）

```sql
-- 扩展现有 users 表
ALTER TABLE users ADD COLUMN referral_code TEXT UNIQUE;
ALTER TABLE users ADD COLUMN referred_by TEXT REFERENCES users(id);
ALTER TABLE users ADD COLUMN subscription_expires TEXT;
```

| 新增字段 | 类型 | 来源 | 说明 |
|:---------|:-----|:-----|:------|
| `referral_code` | TEXT UNIQUE | 原 `user_referral_codes` 表 | 每个用户唯一推广码，注册时自动生成 |
| `referred_by` | TEXT FK→users(id) | 原 `referral_bindings` 表 | 谁推广了我（直接上级），NULL = 自然注册 |
| `subscription_expires` | TEXT | 原 `user_preferences` 键值对 | 订阅到期日（ISO 8601），从 KV 表迁入正式字段 |

**`subscription_expires` 迁移说明**：

当前系统使用 `user_preferences` 键值表存储订阅到期日（`key='subscription_expires'`），这是一个历史遗留设计。键值表存在以下问题：

| 问题 | 说明 |
|:-----|:------|
| ❌ 无类型约束 | 所有值都是 TEXT，无法做 NOT NULL / CHECK |
| ❌ 无外键约束 | 不能直接关联 `payment_orders`、`subscription_audit_log` |
| ❌ 查询效率低 | 每次查到期日需要 `WHERE key='subscription_expires'`，无法走覆盖索引 |
| ❌ 无持久化保障 | 任何人都可以写入任意 key，数据完整性靠代码自觉 |

迁移为 `users.subscription_expires` 字段后**影响范围**：

| 模块 | 文件 | 改动量 |
|:-----|:-----|:-------|
| 订阅查询 | `subscription.rs:get_current_expires()` | 改 SQL：`user_preferences` → `users.subscription_expires` |
| 订阅设置 | `subscription.rs:set_expires()` | 改 SQL：INSERT/UPDATE 键值对 → `UPDATE users SET subscription_expires=` |
| 管理员用户列表 | `admin_handlers.rs` | 去掉 `LEFT JOIN user_preferences`，直接读 `users.subscription_expires` |
| 管理员设置订阅 | `admin_handlers.rs:SetSubInput` | 直接 `UPDATE users` |
| 前端查询 | 各 handler | `user_preferences` → `users.subscription_expires` |
| 数据迁移（一次性） | `scripts/migrate_subscription_expires.py` | 新脚本：从 `user_preferences` 批量迁到 `users.subscription_expires` |

**迁移步骤**（一次性，部署前执行）：

```sql
-- 第一步: 新增字段（已通过 ALTER TABLE 添加）
-- 第二步: 回填已有数据
UPDATE users SET subscription_expires = (
    SELECT value FROM user_preferences
    WHERE user_preferences.user_id = users.id
    AND key = 'subscription_expires'
);
-- 第三步: 验证数据一致性
SELECT COUNT(*) FROM users
WHERE subscription_expires IS NOT NULL
  AND subscription_expires != (
    SELECT value FROM user_preferences
    WHERE user_preferences.user_id = users.id
    AND key = 'subscription_expires'
  );
-- 第四步: 代码发布后，旧 KV 数据可保留不动（代码不再读它），
--         确认稳定后清理：DELETE FROM user_preferences WHERE key = 'subscription_expires';
```

**迁移后 `user_preferences` 表还剩什么**：

`subscription_expires` 是 `user_preferences` 目前最主要的用途。迁移后该表仅剩少量真实用户偏好：

| key | 用途 | 说明 |
|:----|:-----|:------|
| `tts_voice_type` | TTS 语音类型 | 用户偏好 |
| `tts_speed` | TTS 语速 | 用户偏好 |
| (其他任意 key) | 通用 KV 存储 | `routes.rs` 提供通用读写 API |

`user_preferences` 本身设计正确——它是供用户偏好的通用 KV 表。问题是把系统关键数据（`subscription_expires`）和琐碎偏好（`tts_voice_type`）混在了一起。迁移后分工清晰：

```
users（有约束的表）           user_preferences（自由的 KV）
┌──────────────────────┐     ┌──────────────────────┐
│ subscription_expires │     │ tts_voice_type       │
│ referral_code        │     │ tts_speed            │
│ referred_by          │     │ (其他任意偏好)       │
│ deleted_at           │     └──────────────────────┘
│ ...核心字段          │
└──────────────────────┘
  系统关键字段                   用户自定义偏好
  有 FK / UNIQUE / CHECK        无约束，任意读写
  适合 JOIN / 索引查询           适合随意扩展
```

**层级关系通过 `referred_by` 自关联实现**：

```sql
-- 查 A 的一级下线（直接推广）
SELECT * FROM users WHERE referred_by = 'A';

-- 查 A 的二级下线（下级推广的下级）
SELECT * FROM users WHERE referred_by IN (SELECT id FROM users WHERE referred_by = 'A');

-- 查我是谁推广进来的
SELECT u.referred_by FROM users u WHERE u.id = 'B';

-- 查 A 的完整团队树（递归查询，上限 2 级）
WITH RECURSIVE team AS (
    SELECT id, 1 AS level FROM users WHERE referred_by = 'A'
    UNION ALL
    SELECT u.id, t.level + 1 FROM users u
    JOIN team t ON u.referred_by = t.id
    WHERE t.level < 2
)
SELECT * FROM team;
```

#### payment_orders 表（无需扩展）

`payment_orders` 不需要新增字段。订单归因通过 `distribution_commissions.order_id` 关联查询：

```sql
-- 查 A 推广带来了哪些订单（通过 distribution_commissions 查）
SELECT po.* FROM payment_orders po
JOIN distribution_commissions dc ON dc.order_id = po.id
WHERE dc.earner_id = 'A' AND po.status = 'SUCCESS';

-- 查某个订单归因到谁
SELECT po.id, po.amount, dc.earner_id AS promoter_id
FROM payment_orders po
LEFT JOIN distribution_commissions dc ON dc.order_id = po.id
WHERE po.id = 'order_123';
```

**逻辑关系**：

```
users.referred_by = A        ← 注册时写入（绑定上级）
       │
       ▼
B 支付 → distribution_commissions(earner_id=A, order_id=order_123)
         → 通过 order_id JOIN payment_orders 查订单详情
         → 不需要 payment_orders.referred_by
```

---

### 3.3 referral_clicks（分享点击追踪）

独立表，无法合并——点击发生在用户注册之前，没有 `users.id`。**这是归因的起点，referral_clicks.referrer_id 是后续所有绑定关系的源头。**

```sql
CREATE TABLE referral_clicks (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,             -- 关联活动
    referrer_id TEXT NOT NULL,             -- 分享者 user_id（A）
    clicker_anonymous_id TEXT,             -- 点击者匿名标识
    share_channel TEXT,                    -- 分享渠道: profile / share_dialog / course_page / banner（前端传入）
    landed_page TEXT,                      -- 落地页
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (referrer_id) REFERENCES users(id)
);

CREATE INDEX idx_clicks_campaign ON referral_clicks(campaign_id);
CREATE INDEX idx_clicks_referrer ON referral_clicks(referrer_id);
CREATE INDEX idx_clicks_anonymous ON referral_clicks(clicker_anonymous_id);
```

**绑定流程**（两条独立路径）：

```
                  URL 携带 ?ref=CoEvo_A1B2&camp=camp_xxx
                             │
              ┌──────────────┴──────────────┐
              ▼                              ▼
     binding（注册时，必须做）      analytics（点击时，独立统计）
              │                              │
              ▼                              ▼
     B 注册提交 ref 参数          POST /api/referral/click
              │                   → referral_clicks { referrer_id=A }
              ▼                   用于: 点击率 / 归因窗口 / 渠道分析
     users.referred_by = A       不影响 binding，丢失不影响绑定
```

**注册绑定**（从 URL `ref` 参数直接写入 `referred_by`，不依赖 `referral_clicks`）：

```
B 注册 ──→ POST /api/auth/register { ..., referral: { code: 'CoEvo_A1B2', campaign_id: 'camp_xxx' } }
  │
  ▼
后端:
  1. 查 users WHERE referral_code = 'CoEvo_A1B2' → 找到推广员 A 的 user_id
     ├── 未找到 → 跳过绑定（非法 code）
     ├── A 已被删除（deleted_at IS NOT NULL）→ 跳过绑定
     └── 找到且正常 → 继续
  2. 查 marketing_campaigns WHERE id = campaign_id → 获取 rewards（用于后续核销）
     ├── 未找到或已过期 → 仍绑定 referred_by，但不触发注册奖励
     └── 找到且有效 → 记录 campaign 上下文
  3. 设置 users.referred_by = A    ←── 唯一绑定入口，只写一次
  3. 自动生成 B 自己的 users.referral_code
     ├── 规则: 'CoEvo_' + 4位随机字母数字大写
     ├── UNIQUE 冲突 → 重新随机（最多 3 次）
     └── 3 次仍冲突 → 跳过（不影响注册）
  │
  ▼
B 支付 ──→ pay_notify_handler
  │
  ▼
后端:
  1. 查 users WHERE id = B → 拿到 B.referred_by = A
  2. 查 campaign 的 rewards 规则 → 计算佣金
  3. 生成 distribution_commissions(earner_id=A, buyer_id=B, order_id=...)  ←── 通过 order_id 关联订单
```

**点击统计**（纯分析，不参与绑定）：

```
B 扫描/点击链接 → POST /api/referral/click { ref, camp, device_id }
  │
  ▼
后端:
  1. 查 referral_code = 'CoEvo_A1B2' → referrer_id = A
  2. 写入 referral_clicks { campaign_id, referrer_id=A, clicker_anonymous_id=device_id }
  3. 返回 click_id（仅用于前端统计追踪）
```

**关键规则**：
- `users.referred_by` **只在注册时写入一次**，不可更改
- 注册时**只认 `ref` 参数**（推广码），不需要 `click_id`
- 如果推广码无效（伪造/过期/推广员已删除），**静默跳过绑定**，不影响注册流程
- `referral_clicks` 用于漏斗分析，即使丢失也不影响绑定关系
- 推广码生成碰撞（极小概率）自动重试 3 次，3 次仍失败则跳过（不影响注册）
- **推广码大小写**：生成时统一大写（如 `CoEvo_A1B2`），查询时忽略大小写（`UPPER(code)` 对比）。防止用户输入小写字母导致不匹配
- **推广码输入不做长度/格式校验**（仅后端 `UNIQUE` 约束）。URL 参数 `ref` 传错时静默跳过
- 分销相关的 `FOREIGN KEY` 均不含 `ON DELETE CASCADE`——这意味着有佣金记录的用户无法硬删除。这是刻意设计（财务数据不可丢失）。如需删除用户，必须先处理其佣金和提现记录
- **SQLite 外键约束**：SQLite 默认不启用 `PRAGMA foreign_keys = ON`，所有 FK 约束仅在启用后生效。代码中应确保 `init_database()` 后执行 `PRAGMA foreign_keys = ON`
- **审计日志**：所有管理端操作（活动启停/提现审核/结算打款）均写入 `admin_audit_log`。核销失败告警也通过 `admin_audit_log` 记录

---

### 3.4 settlement_batches（结算批次）

**统一打款通道**——不论用户提现还是管理员直接结算，最终都通过结算批次打款。

```sql
CREATE TABLE settlement_batches (
    id TEXT PRIMARY KEY,
    batch_no TEXT NOT NULL UNIQUE,           -- 批次号, 如 "ST20260617-001"
    total_amount INTEGER NOT NULL DEFAULT 0, -- 本批总金额（分）
    item_count INTEGER NOT NULL DEFAULT 0,   -- 本批佣金条数
    status TEXT DEFAULT 'pending',           -- pending / paid
    note TEXT,                               -- 备注说明（含转账信息）
    source TEXT DEFAULT 'admin',             -- 来源: admin / withdrawal
    created_at TEXT NOT NULL,
    paid_at TEXT,
    handled_by TEXT,                          -- 操作管理员 ID
    FOREIGN KEY (handled_by) REFERENCES admin_users(id)
);
```

**批次号规则**: `ST{日期}-{当日序号}`, 如 `ST20260617-001`

---

### 3.5 distribution_commissions（佣金结算记录）

直接关联 `payment_orders`，不经过中间表。

```sql
CREATE TABLE distribution_commissions (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    earner_id TEXT NOT NULL,               -- 获佣用户（推广员A）
    level INTEGER NOT NULL,                -- 1=一级, 2=二级
    amount INTEGER NOT NULL,              -- 佣金（分）

    -- 直接关联 payment_orders（不经过 referral_conversions）
    order_id TEXT NOT NULL,                -- 关联 payment_orders
    buyer_id TEXT NOT NULL,                -- 买家 user_id（B）
    order_amount INTEGER NOT NULL,         -- 买家实际支付金额（分）
    rate_applied REAL NOT NULL,            -- 本次应用的佣金比例

    status TEXT DEFAULT 'locked',           -- locked / available / settled / paid / cancelled
    batch_id TEXT,                          -- 关联结算批次
    unlocked_at TEXT,                       -- 锁定期结束时间
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (buyer_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id)
);

CREATE INDEX idx_commission_earner ON distribution_commissions(earner_id, status);
CREATE INDEX idx_commission_order ON distribution_commissions(order_id);
CREATE INDEX idx_commission_batch ON distribution_commissions(batch_id);
```

**与 payment_orders 的关系**：

```
distribution_commissions       payment_orders（已有）
┌─────────────────────┐       ┌──────────────────────┐
│ earner_id = A       │       │ id = order_123       │
│ buyer_id = B        │──┐    │ user_id = B          │
│ order_id = order_123│  └──→ │ amount = 128000      │
│ order_amount = 128000│       │ plan_id = lifetime   │
│ rate_applied = 0.10  │       │ status = SUCCESS     │
│ amount = 12800      │       │ paid_at = 2026-06-17 │
└─────────────────────┘       └──────────────────────┘
```

**状态流转**：

```
支付成功 ──→ locked（30天锁定期）
                │
                ├── 退款 ──→ cancelled
                │
                └── 超30天 ──→ available
                                │
                                └── 归入批次 ──→ settled ──→ paid
```

---

### 3.6 distribution_withdrawals（用户提现申请）

用户主动发起的提现。审核通过后归入 `settlement_batches` 统一打款。

```sql
CREATE TABLE distribution_withdrawals (
    id TEXT PRIMARY KEY,
    earner_id TEXT NOT NULL,                -- 提现申请人（推广员）
    amount INTEGER NOT NULL,               -- 提现金额（分）
    fee INTEGER DEFAULT 0,                 -- 手续费
    actual_amount INTEGER,                 -- 实际到账
    status TEXT DEFAULT 'pending',          -- pending / approved / rejected / paid
    note TEXT,                              -- 驳回原因或备注
    batch_id TEXT,                          -- 审核通过后归入的结算批次
    created_at TEXT NOT NULL,
    handled_at TEXT,
    handled_by TEXT,
    FOREIGN KEY (earner_id) REFERENCES users(id),
    FOREIGN KEY (batch_id) REFERENCES settlement_batches(id),
    FOREIGN KEY (handled_by) REFERENCES admin_users(id)
);

CREATE INDEX idx_withdrawals_status ON distribution_withdrawals(status);
```

---

### 3.7 user_notifications（站内通知表）

用于向用户推送营销活动通知、奖励到账提醒、提现状态变更等。

```sql
CREATE TABLE user_notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,               -- 通知接收者
    notification_type TEXT NOT NULL,     -- reward / share_poster / share_h5 / commission / withdrawal / marketing_campaign / system
    title TEXT NOT NULL,                 -- 通知标题，如 "您有新的活动邀请"
    body TEXT NOT NULL,                  -- 通知内容（支持 {name} 变量替换）
    read INTEGER DEFAULT 0,             -- 0=未读, 1=已读
    action_url TEXT,                     -- 点击后跳转路径，如 /app/activity/camp_xxx
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_notifications_user ON user_notifications(user_id, read, created_at);
```

| 字段 | 类型 | 说明 |
|:-----|:-----|:------|
| `id` | TEXT PK | 通知唯一 ID |
| `user_id` | TEXT FK | 接收通知的用户 |
| `notification_type` | TEXT | 通知类型。`reward`=奖励到账(🎁), `commission`=佣金(💰), `share_poster`=海报(📤), `share_h5`=分享页(📤), `withdrawal`=提现(💳), `marketing_campaign`=营销(📢), `system`=系统(ℹ️) |
| `title` | TEXT | 标题，如"您获得了 7 天会员奖励" |
| `body` | TEXT | 正文 |
| `read` | INTEGER | 已读标记，用于前端小红点计数 |
| `action_url` | TEXT | 点击通知后跳转的页面路径 |

**通知类型与前端展示**：

| 类型 | 触发场景 | 标题示例 | 前端图标 | 点击跳转 |
|:-----|:---------|:---------|:---------|:---------|
| `marketing_campaign` | 活动推送触发 | "限时邀请好友，双方得 7 天" | 🎉 | 活动详情页 `/app/activity/{id}` |
| `reward_earned` | 奖励核销成功后 | "你获得了 ¥2 佣金" | 💰 | 收益面板 `/app/earnings` |
| `withdrawal_status` | 提现审核通过/驳回 | "提现 ¥10 已到账" | 📋 | 提现记录 `/app/withdrawals` |

**前端展现**：

```
AppBar 右上角铃铛图标 + 未读小红点（实时轮询）

通知中心列表:
┌──────────────────────────────────┐
│  🎉 限时邀请好友，双方得 7 天     │  ← 未读（加粗）
│     邀请 3 位好友即可领取         │
│     2 分钟前                     │
├──────────────────────────────────┤
│  💰 你获得了 ¥2 佣金             │  ← 已读（正常粗细）
│     用户小明购买了月卡            │
│     1 小时前                     │
├──────────────────────────────────┤
│  📋 提现 ¥10 已到账              │
│     2026-06-17                  │
└──────────────────────────────────┘
```

**轮询**：前端每 60 秒 `GET /api/notifications?unread_only=true`，更新小红点计数。

**API**：

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/notifications` | 通知列表（?unread_only=true 筛选未读）|
| PATCH | `/api/notifications/{id}/read` | 标记已读 |
| POST | `/api/notifications/read-all` | 全部已读 |

---

### 3.8 reward_fulfillments（奖励核销记录表）

所有奖励的发放追踪。天数奖励发放后同时在 `subscription_audit_log` 中落审计记录。

```sql
CREATE TABLE reward_fulfillments (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    referral_click_id TEXT,                -- 关联 referral_clicks（trigger=click 用）
    order_id TEXT,                         -- 关联 payment_orders（trigger=payment 用）
    user_id TEXT NOT NULL,                 -- 获奖励用户
    party TEXT NOT NULL,                   -- self / inviter / invitee / referrer
    level INTEGER DEFAULT 1,               -- 1=一级, 2=二级（commission 专用）
    reward_type TEXT NOT NULL,             -- subscription_days / commission_pct / commission_fix / discount_fix / discount_pct
    reward_value TEXT NOT NULL,            -- 奖励值 JSON
    trigger_event TEXT NOT NULL,           -- registration / referral_signup / click / payment / order_creation / plan_completed
    status TEXT DEFAULT 'pending',         -- pending / fulfilled / failed / cancelled
    fulfilled_at TEXT,
    error_msg TEXT,                        -- 失败原因（status=failed 时必填）
    created_at TEXT NOT NULL,
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_fulfillment_user ON reward_fulfillments(user_id, status);
CREATE INDEX idx_fulfillment_campaign ON reward_fulfillments(campaign_id, trigger_event);
```

**核销动作与审计**：

| reward_type | 核销动作 | 审计记录 |
|:-----------|:---------|:---------|
| `subscription_days` | 直接计算到期日 + `set_expires()` | `reward_fulfillments` + `user_notifications` |
| `commission_pct` | 生成 `distribution_commissions(locked)` | 本表 status=fulfilled |
| `discount_fix/pct` | 订单创建时已应用 | 本表 status=fulfilled |

---

### 3.9 角色过滤逻辑

活动配置 `target_roles` 字段控制哪些角色可以参与分享。推广目标始终是学生用户。

```sql
target_roles = '["student"]'                → 仅学生端看到
target_roles = '["teacher","guardian"]'     → 教师和家长端看到
target_roles = '[]' 或 NULL                 → 全部角色可见
```
## 四、归因规则

### 4.1 分销链路归属机制

```
用户 A 分享链接 → 用户 B 点击 → 浏览器 localStorage 记录 "ref_by=A"
  → B 未注册离开 → 3 天后 B 再次打开
  → 浏览器读取 localStorage → "ref_by=A" (还在归因窗口内)
  → B 注册 → users.referral_code（B 自己的推广码生成）
  →         → users.referred_by = A（绑定上级）
  → B 购买 → distribution_commissions(earner_id=A, order_id=pay_123)（佣金与订单关联）
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

**两条独立路径**：点击统计和注册绑定互不依赖。

```
点击统计（分析用，失败不影响绑定）:
  B 打开链接 → POST /api/referral/click { ref, camp, device_id }
               → referral_clicks.insert()（用于漏斗分析）
               
注册绑定（从 ref 参数直接写入）:
  B 注册 → POST /api/auth/register { ..., referral: { code: 'CoEvo_A1B2', campaign_id: 'camp_xxx' } }
             → 查 users WHERE referral_code = ... → 找到推广员 A
             → 查 marketing_campaigns WHERE id = campaign_id → 获取 rewards 规则
             → users.referred_by = A
             → 检查 rewards 中 trigger=registration 的规则并核销
```

```javascript
// 页面加载时（扫码/H5 CTA 进入时）：立即记录点击
async function trackClick() {
  const params = new URLSearchParams(window.location.search);
  const ref = params.get('ref');
  const camp = params.get('camp');
  if (!ref) return;
  
  const deviceId = getDeviceId(); // 匿名设备指纹
  const resp = await fetch('/api/referral/click', {
    method: 'POST',
    body: JSON.stringify({ ref, camp, device_id: deviceId }),
  });
  const data = await resp.json();
  
  // 存 localStorage，注册时用
  localStorage.setItem('coevo_ref', JSON.stringify({
    click_id: data.click_id,
    code: ref,
    campaign_id: camp,
    timestamp: Date.now(),
  }));
}

// 用户注册时, 前端提交推广码 + 活动 ID 给后端
// POST /api/auth/register { ..., referral: { code: 'CoEvo_A1B2', campaign_id: 'camp_xxx' } }
// 后端用 referral_code 查 users → 找到推广员 A → 写入 users.referred_by = A
// 用 campaign_id 查活动 → 获取 rewards 规则 → 核销 trigger=registration 的奖励

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
                              │                   ├── 调 LLM 生成 SVG 海报（含二维码）
                              │                   └── 前端渲染海报，用户保存或分享
                              ▼
                          referral_clicks 追踪开始
```

### 5.2 分享 → 转化 → 结算链路

```
用户分享                    后端                          管理端
────────                    ────                          ────
A 点击"立即分享" ──→ 调 LLM 生成 SVG 海报（含个人数据 + 推广码 + 二维码）
  │                           └── 二维码内容: /app/auth?ref=CoEvo_A1B2&camp=camp_xxx
  ├── 用户保存海报 → 发微信给 B
  │
  ▼
B 扫码/点击链接 ──→ POST /api/referral/click { ref, camp, device_id }
  │                    ├── referral_clicks.insert() → 返回 click_id
  │                    ├── 查 campaign.rewards trigger=click
  │                    │   └── subscription_days → extend_subscription(A, 1) + reward_fulfillments
  │                    └── localStorage 存 { click_id, code, campaign_id, timestamp }
  │
  ▼
B 注册 ──→ POST /api/auth/register { ..., referral: { code: 'CoEvo_A1B2', campaign_id: 'camp_xxx' } }
  │         ├── 查 users WHERE referral_code = ... → 找到推广员 A
  │         ├── users.referral_code = 自动生成(B的推广码)
  │         ├── users.referred_by = A（从 ref 参数直接写入）
  │         ├── 查 marketing_campaigns WHERE id = campaign_id → 获取 rewards 规则:
  │         │   ├── trigger=registration → subscription_days → extend_subscription(A, 7)
  │         │   ├── trigger=registration → subscription_days → extend_subscription(B, 3)
  │         │   └── 每条 -> reward_fulfillments.insert()（幂等保护）
  │         └── 前端通知: "你被 {A} 邀请, 获得 3 天会员!"
  │
  ▼
B 进入支付页 ──→ GET /api/pay/plans（加载套餐列表 + 折扣信息）
  │
  │  前端展示:
  │  ┌──────────────────────────────────────┐
  │  │  🎉 好友邀请专属优惠                   │
  │  │  被 {A} 邀请，首单享优惠！             │
  │  │                                      │
  │  │  📦 月度会员    ¥200 → ¥160  (8折)    │
  │  │  📦 年度会员    ¥1,280 → ¥1,024       │
  │  │  📦 终身会员    ¥1,280 → ¥1,024       │
  │  │                      [选择套餐]       │
  │  └──────────────────────────────────────┘
  │
  ▼
B 选择套餐 ──→ POST /api/pay/calculate { plan_id }
  │         ├── 查 users.referred_by = A
  │         │   ├── A 已删除（deleted_at IS NOT NULL）→ 跳过，返回原价
  │         │   └── 正常 → 继续
  │         ├── 查 active campaign: WHERE status=active AND valid_from<=now AND valid_until>=now
  │         │   ├── 取最新一条含 discount 奖励的活动（按 created_at DESC）
  │         │   ├── 检查 rewards 中是否有 trigger=order_creation + discount_fix/pct
  │         │   ├── 检查 campaign.valid_until > now（活动是否已过期）
  │         │   │   ├── 已过期 → 跳过折扣，返回原价
  │         │   │   └── 有效 → 继续
  │         │   ├── 检查 attribution_window 是否超期
  │         │   │   ├── click_time + window < now → 归因过期，返回原价
  │         │   │   └── 有效 → 继续
  │         │   ├── 找到 → 计算折后价（原价 20000 → 折后 16000）
  │         │   │   → reward_fulfillments.insert(trigger=order_creation, type=discount, status=fulfilled)
  │         │   └── 没找到 → 原价
  │         ├── 创建 payment_orders { amount: 折后价, status: NOTPAY }
  │         ├── 生成微信支付二维码（折后价）
  │         └── 返回二维码 + 订单信息
  │
  ⚠️ NOTPAY 超时处理:
     ┌── cron 定时任务: 扫描超时未支付订单
     ├── 超时时间从 app_config 读取（key='order_timeout_minutes', 默认 30）
     ├── payment_orders.status = NOTPAY AND created_at < now - timeout → 关单（status = CLOSED）
     ├── payment_orders.status = NOTPAY → 关单（status = CLOSED）
     ├── 如果该订单应用了折扣:
     │   ├── reward_fulfillments(trigger=order_creation) → status = cancelled
     │   └── 折扣回收，下次重新下单需重新计算
     └── 微信侧同步调用 closeOrder API
  │
  ▼
B 支付成功 ──→ pay_notify_handler
  │         ├── 查 users.referred_by WHERE id = B
  │         ├── 查 marketing_campaigns 获取 rewards 规则
  │         ├── 按 rewards[].trigger 逐条核销:
  │         │   ├── trigger=payment → subscription_days → 直接计算到期日 + set_expires()
  │         │   ├── trigger=payment → commission_pct → distribution_commissions(earner_id=A, order_id=...)
  │         │   └── 每条 -> reward_fulfillments.insert()（幂等）
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

### 5.4 奖励分发与核销链路

**核销引擎入口**: `campaign_executor.rs` 中的 `execute_campaign_trigger()` 函数，统一在各触发点调用。按 `campaign.rewards[].trigger` 匹配后分发。

```
注册 / 支付 / 计划完成 / 复习完成 等触发点
  │
  └── execute_campaign_trigger(conn, trigger_event, user_id, referrer_id, order_id)
        │
        ├── 查 campaign_rewards WHERE status='active' AND trigger_event=?
        │
        ├── for each campaign:
        │     ├── 解析 rewards JSON
        │     │
        │     ├── for each reward:
        │     │     ├── 检查 trigger 是否匹配当前 trigger_event
        │     │     │   ├── registration → 只处理 trigger=registration
        │     │     │   ├── payment → 只处理 trigger=payment（佣金/天数）
        │     │     │   ├── plan_completed → 只处理 trigger=plan_completed
        │     │     │   └── 不匹配 → 跳过
        │     │     │
        │     │     ├── 确定目标用户（self / inviter / referrer / invitee）
        │     │     │   └── party=self → 当前用户
        │     │     │   └── party=inviter/referrer → 推荐人（无推荐人则跳过）
        │     │     │
        │     │     ├── 幂等检查: reward_fulfillments 五元组去重
        │     │     │
        │     │     ├── 分发:
        │     │     │   ├── subscription_days → 直接计算到期日 + set_expires()
        │     │     │   ├── commission_pct/fix → 写 distribution_commissions(locked)
        │     │     │   └── commission 在无 order_id 时跳过
        │     │     │
        │     │     ├── 写 reward_fulfillments(status=fulfilled) + user_notifications
        │     │     │
        │     │     └── 所有错误只记 warning，不阻塞主流程
  │     │   │
  │     │   ├── commission_pct → 计算金额, 生成 distribution_commissions(locked)
  │     │   │   └── 失败 → 标记 status=failed, 入重试队列
  │     │   │
  │     │   ├── discount_fix/pct → 已在订单中应用, 标记 status=fulfilled
  │     │   └── 其他 → 按具体实现扩展
  │     │
  │     ├── 更新 reward_fulfillments(status=fulfilled)
  │     │
  │     └── 发站内通知: "恭喜你获得 X 天会员 / ¥XX 佣金"
  │
  └── 全部完成后 → campaign 统计更新
```

### 5.5 已实现的触发点与文件清单

| 触发点 | 调用位置 | 文件 |
|--------|---------|------|
| `registration` | 注册成功末尾 | `auth.rs` |
| `payment` | 支付回调成功后 | `pay_handlers.rs` → `campaign_executor.rs` |
| `plan_completed` | 计划完成后 | `plan_handler.rs` |
| `after_complete_review` | 前端 `check-push-trigger` 查询（复习完成弹分享） | `campaign_handler.rs:check_push_trigger()` |

### 5.6 campaign_executor.rs 文件结构

```
backend/crates/api_server/src/campaign_executor.rs

pub fn execute_campaign_trigger(conn, trigger_event, user_id, referrer_id, order_id) -> Result<Vec<String>, String>
fn find_active_campaigns(conn, trigger_event) -> Vec<CampaignRow>
fn check_idempotent(conn, campaign_id, user_id, trigger_event, party, reward_type) -> bool
fn handle_subscription_days(conn, campaign_id, campaign_name, user_id, party, value, ...)
fn handle_commission_pct(conn, campaign_id, ..., order_id, ...)
fn handle_commission_fix(conn, campaign_id, ..., order_id, ...)
pub fn write_fulfillment(conn, campaign_id, user_id, party, reward_type, ...) -> String
pub fn write_notification(conn, user_id, notification_type, title, body, action_url) -> String
```

**设计原则**:
- 所有错误只记 warning，**永不阻塞主流程**
- 幂等保护：五元组 `(campaign, user, trigger, party, type)` 唯一性
- `subscription_days` 不调 `extend_subscription()`（需要 plan_id），直接计算到期日 + `set_expires()`
- commission 类型在无 `order_id` 时跳过（注册触发场景）

---

**去重与防重复规则**:

| 规则 | 说明 | 实现 |
|:-----|:-----|:-----|
| 消费端绑定唯一性 | 一个消费者只能被一个推广者绑定 | `users.referred_by` 首次写入后不可变更 |
| 关系不可逆 | 一旦绑定，不能解绑或改绑 | 业务规则：不提供解绑 API |
| 奖励幂等 | 同 campaign + 同 user + 同 trigger_event + 同 party + 同 reward_type 不会重复发放 | `reward_fulfillments` 核销前五元组查重（status='fulfilled'）|
| 同一活动多次触发 | 用户可多次分享、多次获奖励（如每次点击送 1 天）| 不同 referral_click 视为不同触发，各自独立核销 |
| 自链接排除 | 用户点击自己的链接不触发任何奖励 | `referral_clicks` 中 `referrer_id = clicker_id` 时跳过 |

**失败与重试策略**:

```
核销失败流程:
  1. 标记 reward_fulfillments.status = 'failed'
  2. 写入 error_msg（如 "extend_subscription DB error: ..."）
  3. 处理失败：
     ├── DB 瞬断 → 自动重试 1 次（间隔 3 秒）
     └── 其他失败（配置错误/数据异常）→ 标记最终失败, 通知运维：
            ├── 站内通知：写入 `admin_audit_log`，超管登录后可见
            └── 邮件：发送至超管邮箱（邮箱地址从 `app_config` 读取 `alert_email`）

回滚策略:
  - subscription_days 已发放 → 调用 reduce_subscription(天数) 回滚
  - commission 已锁定 → 标记为 cancelled
  - discount 已应用 → 订单已支付, 不能回滚（退款走微信退款流程）
```

**佣金生成与解锁提示**:

佣金在购买时即生成 `distribution_commissions(status=locked)`，同时在用户端清晰告知：

```
用户 A 的佣金面板:
┌────────────────────────────────────────────┐
│  📋 佣金记录                               │
│                                            │
│  ● ¥20  来自 B · 月卡 ¥200 × 10%          │
│    🔒 30天锁定期 · 预计 7月17日解锁        │
│    解锁条件: B 超过 30 天无退款            │
│                                            │
│  ○ ¥64  来自 D · 终身 ¥1280 × 5%          │
│    🔒 30天锁定期 · 预计 7月17日解锁        │
│    解锁条件: D 超过 30 天无退款            │
│                                            │
│  ✅ 已解锁可结算 ¥12                       │
│  🔒 锁定期内 ¥84                          │
│  ✅ 已到账 ¥0                              │
└────────────────────────────────────────────┘
```

提示文案: "佣金在购买时已生成，但需要等待 30 天退款期结束后才能结算 / 提现。这是为了保护消费者权益，如果对方在 30 天内申请退款，相应佣金将自动取消。"

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
├── 💰 佣金结算（统一打款通道）
│   ├── 锁定中佣金列表（locked 状态）
│   │   用户 | 金额 | 来源订单 | 时间 | 操作(勾选加入批次)
│   ├── 创建结算批次: 勾选佣金 → 生成批次号 ST20260617-001 → 确认总金额
│   ├── 已结待付（settled 状态, 按批次展示）
│   │   批次号 | 条数 | 总金额 | 来源(管理员/提现) | 时间 | 状态 | 操作
│   │   ├── 查看批次明细（该批次包含的所有佣金）
│   │   ├── 下载批次汇总（CSV, 方便对照打款）
│   │   └── 标记已打款 + 填写备注
│   └── 已打款记录（paid 状态）
│       批次号 | 总金额 | 来源 | 备注 | 打款时间 | 操作(查看大图)
│
├── 📋 待审核提现（管理员待办列表）
│   ├── 用户 | 金额 | 申请时间 | 操作
│   ├── 审核通过 → 自动归入结算批次（跳转到结算批次页）
│   └── 审核驳回 → 填写驳回原因
│
├── 📊 按月统计
│   ├── 月份选择器
│   ├── 本月新增佣金 / 本月解锁 / 本月打款 / 锁定中
│   └── 按月导出报表
│
└── 📈 活动与财务数据
    ├── 按活动查看: 曝光 → 点击 → 注册 → 支付 漏斗
    ├── **按月统计: 月份选择器 → 总佣金 / 已提现 / 待提现 / 提现人数 / 打款明细列表**
    ├── 按用户查看: 某用户的所有分享行为
    ├── 导出 CSV
    └── 打款备注查询: 按月份/用户搜索打款记录
```

### 6.2 新建活动表单完整字段

| 分组 | 字段 | 类型 | 说明 |
|:----|:-----|:-----|:-----|
| **基本信息** | 活动名称 | text | 用户端展示的名称 |
| | 活动描述 | text | 内部备注 |
| | 活动类型 | select | invite_award / commission / discount_pct / discount_fix |
| **目标角色** | **适用角色** | **checkbox 多选** | **student / teacher / guardian, 控制谁可以看到并分享此活动** |
| | LLM 提示语 | text | 控制生成内容侧重点, 如"突出学习天数" |
| **时间控制** | 开始时间 | datetime | 在此时间之前活动不生效 |
| | 结束时间 | datetime | 在此时间之后活动自动结束 |
| **推送规则** | 推送触发 | select | registration / first_payment / login / manual / cron |
| | 推送文案 | text | 支持 {name} 变量替换 |
| **奖励规则** | 邀请者奖励类型 | select | subscription_days / commission_pct / commission_fix / discount_pct / discount_fix |
| | 邀请者奖励值 | text | 数值 |
| | 被邀请者奖励类型 | select | subscription_days / discount_fix / discount_pct |
| | 被邀请者奖励值 | text | 数值 |
| | 一级佣金比例 | number | 0.00 - 1.00 |
| | 二级佣金比例 | number | 0.00 - 1.00 |
| **归因设置** | 归因窗口(天) | number | 默认 30 |
| **限制** | 参与人数上限 | number | 空 = 不限 |
| | 每人参与上限 | number | 空 = 不限 |

---

## 六、管理端界面设计

### 6.1 页面结构

```
营销管理中心
├── 📢 活动管理
│   ├── 活动列表（卡片视图）
│   │   活动名称 | 类型 | 状态(badge) | 时间 | 参与/转化 | 操作
│   ├── 创建活动弹窗
│   │   ├── 基本信息: 名称 / 描述 / 类型 / 状态
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
├── 💰 佣金结算（统一打款通道）
│   ├── 锁定中佣金列表（locked 状态）
│   │   用户 | 金额 | 来源订单 | 时间 | 操作(勾选加入批次)
│   ├── 创建结算批次: 勾选佣金 → 生成批次号 → 确认总金额
│   ├── 已结待付（settled 状态, 按批次展示）
│   │   批次号 | 条数 | 总金额 | 来源(管理员/提现) | 时间 | 状态 | 操作
│   │   ├── 查看批次明细
│   │   ├── 下载批次汇总（CSV, 方便对照打款）
│   │   └── 标记已打款 + 填写备注
│   └── 已打款记录（paid 状态）
│       批次号 | 总金额 | 来源 | 备注 | 打款时间 | 操作
│
├── 📋 待审核提现（管理员待办列表）
│   ├── 用户 | 金额 | 申请时间 | 操作
│   ├── 审核通过 → 自动归入结算批次
│   └── 审核驳回 → 填写驳回原因
│
├── 📊 按月统计
│   ├── 月份选择器
│   ├── 本月新增佣金 / 本月解锁 / 本月打款 / 锁定中
│   └── 按月导出报表
│
└── 📈 活动与财务数据
    ├── 核心指标: 活动总数 / 进行中 / 总参与 / 总转化 / 总佣金
    └── 趋势图: 日/周/月 新增分享 / 注册 / 转化 / 佣金
```

### 6.2 活动配置表单字段

| 分组 | 字段 | 类型 | 说明 |
|:----|:-----|:-----|:------|
| **基本信息** | 活动名称 | text | 用户端展示的名称 |
| | 活动描述 | text | 内部备注 |
| | 活动类型 | select | invite_award / commission / discount_pct / discount_fix / mixed |
| **时间控制** | 开始时间 | datetime | 活动开始时间 |
| | 结束时间 | datetime | 活动结束时间 |
| **推送规则** | 触发条件 | select | registration / first_payment / login / manual / cron |
| | 推送文案 | textarea | 支持 {name} 变量 |
| **目标角色** | 适用角色 | checkbox | student / teacher / guardian |
| **奖励规则** | 邀请者奖励 | JSON 编辑器 | type/party/value/trigger 数组 |
| | 被邀请者奖励 | JSON 编辑器 | type/party/value/trigger 数组 |
| **归因设置** | 归因窗口(天) | number | 默认 30 |
| **LLM 提示** | LLM 提示语 | text | 控制生成内容侧重点 |
| **限制** | 参与人数上限 | number | 空 = 不限 |
| | 每人参与上限 | number | 空 = 不限 |

### 6.3 管理端 Tab 导航与页面清单

管理端的"营销中心"作为现有管理后台的一个独立 tab，通过侧边栏展开子菜单：

```
管理后台侧边栏（新增部分）
┌─────────────────────┐
│  ...现有菜单        │
├─────────────────────┤
│ 📢 营销中心         │ ← 新增，可展开
│   ├─ 活动管理       │
│   ├─ 分销团队       │
│   ├─ 佣金结算       │
│   ├─ 待审核提现     │
│   └─ 数据统计       │
├─────────────────────┤
│  ...其他菜单        │
└─────────────────────┘
```

#### 页面路由与文件映射

| Tab | 路由 | 文件 | 功能 |
|:----|:-----|:-----|:------|
| 📢 活动管理 | `/admin/campaigns` | `admin_campaign_list.dart` | 卡片视图 + 筛选 |
| | `/admin/campaigns/new` | `admin_campaign_form.dart` | 创建表单弹窗 |
| | `/admin/campaigns/{id}` | `admin_campaign_detail.dart` | 详情 + 启停/推送 |
| 👥 分销团队 | `/admin/team` | `admin_team_tree.dart` | 搜索 + 树形展开 |
| | — | `admin_user_detail_sheet.dart` | 用户详情底部弹窗 |
| 💰 佣金结算 | `/admin/settlement` | `admin_commission_list.dart` | 锁定中佣金表格 |
| | `/admin/batches` | `admin_batch_list.dart` | 批次列表 |
| | `/admin/batches/{id}` | `admin_batch_detail.dart` | 批次明细 + CSV |
| 📋 待审核提现 | `/admin/withdrawals` | `admin_withdrawal_list.dart` | 审核列表 |
| 📊 数据统计 | `/admin/stats` | `admin_stats_dashboard.dart` | 指标卡 + 趋势图 |

#### 现有侧边栏适配

```dart
// admin_dashboard.dart 新增菜单项
NavSection(
  title: '营销中心',
  items: [
    NavItem(icon: Icons.list,     label: '活动管理',   route: '/admin/campaigns'),
    NavItem(icon: Icons.group,    label: '分销团队',   route: '/admin/team'),
    NavItem(icon: Icons.payments, label: '佣金结算',   route: '/admin/settlement'),
    NavItem(icon: Icons.pending,  label: '待审核提现', route: '/admin/withdrawals'),
    NavItem(icon: Icons.bar_chart,label: '数据统计',   route: '/admin/stats'),
  ],
);
```

#### 新增页面文件清单

| 文件 | 说明 |
|:-----|:------|
| `admin_campaign_list.dart` | 活动列表卡片视图 + 创建入口 |
| `admin_campaign_form.dart` | 创建/编辑活动表单（6.2 字段）|
| `admin_campaign_detail.dart` | 活动详情 + 参与数据 + 启停/推送 |
| `admin_team_tree.dart` | 分销团队搜索 + 树形展开 |
| `admin_user_detail_sheet.dart` | 用户详情弹窗（分享/佣金/团队）|
| `admin_commission_list.dart` | 锁定中佣金表格 + 勾选加入批次 |
| `admin_batch_list.dart` | 结算批次列表 + 状态标签 |
| `admin_batch_detail.dart` | 批次明细 + 下载 CSV |
| `admin_withdrawal_list.dart` | 待审核提现列表 + 通过/驳回 |
| `admin_stats_dashboard.dart` | 数据指标卡 + 趋势图 + 漏斗 |

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

### 7.2 注册接口变更（现有 auth.rs 修改）

| 方法 | 路径 | 变更说明 |
|:----|:-----|:---------|
| POST | `/api/auth/register` | 请求体新增可选字段 `referral: { code, campaign_id }` |

**请求体示例**：
```json
{
  "username": "B",
  "password": "***",
  "referral": {
    "code": "CoEvo_A1B2",
    "campaign_id": "camp_xxx"
  }
}
```

后端处理逻辑：
1. `code` → 查 `users.referral_code` → 找到推广员 A
2. 推广员无效（不存在/已删除）→ 静默跳过
3. `campaign_id` → 查活动 → 获取 `rewards` 规则 → 核销 `trigger=registration` 的奖励
4. 设置 `users.referred_by = A`
5. 生成 B 自己的 `users.referral_code`

### 7.3 推广码（用户端 + 管理员）

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/referral/my-code` | 查看自己的推广码 |
| GET | `/api/referral/my-stats` | 查看自己的分享数据 |
| GET | `/api/referral/my-team` | 查看团队（树形）|
| GET | `/api/referral/my-commissions` | 查看佣金记录 |

### 7.4 点击追踪（用户端）

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/referral/click` | 用户B打开分享链接时调用，记录 `referral_clicks`，返回 `click_id` |

**请求体**：
```json
{"ref": "CoEvo_A1B2", "camp": "camp_xxx", "device_id": "匿名设备指纹"}
```

**返回**：
```json
{"click_id": "uuid", "referrer_id": "A的用户ID"}
```

前端收到 `click_id` 后存入 localStorage，注册时提交给 `/api/auth/register`。

**频率限制**：

| 接口 | 限流策略 | 说明 |
|:-----|:---------|:-----|
| `POST /api/referral/click` | 每 IP 60 次/分钟 | 防刷，但允许真实的快速多次点击 |
| `GET /api/referral/my-code` | 每用户 30 次/分钟 | 正常展示无需高频请求 |
| `GET /api/referral/my-team` | 每用户 10 次/分钟 | 团队树查询相对重 |
| `POST /api/referral/generate-poster` | 每用户 5 次/分钟 | LLM 生成成本高，限制严格 |

限流实现复用现有 `rate_limiter.rs` 中的滑动窗口方案，与 `bind-lookup` 的 5/min 策略一致。

### 7.5 退款联动

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/admin/refund/{order_id}` | 管理员退款操作，同步取消关联佣金和奖励核销 |
| POST | `/api/webhook/refund` | 微信退款回调，同步取消关联佣金和奖励核销 |

退款时自动执行（事务内）：
1. 查 `distribution_commissions.order_id` 找到关联该订单的佣金
2. 如果佣金状态为 `locked` → 改为 `cancelled`
3. 查 `reward_fulfillments.order_id` 找到关联该订单的奖励核销
4. 如果核销状态为 `fulfilled` → 改为 `cancelled`（commission 奖励回滚）
5. 天数奖励不回滚（已发放的天数无法扣回，风险可控）
3. 写审计日志

### 7.6 通知推送

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/notifications` | 获取未读通知 |
| PATCH | `/api/notifications/{id}/read` | 标记已读 |

### 7.7 提现审核（管理员）

管理员审核用户发起的提现申请。审核通过后归入结算批次统一打款。

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/distribution/withdrawals` | 提现列表（默认 pending 待审核）|
| POST | `/api/admin/distribution/withdrawals/{id}/approve` | 审核通过 → 自动加入新结算批次 |
| POST | `/api/admin/distribution/withdrawals/{id}/reject` | 审核驳回（需填写驳回原因）|

### 7.8 结算批次（管理员）

**统一打款通道**。不论是管理员主动批量结算还是用户提现审核通过，都通过此接口创建/管理批次。

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/settlement/pending-commissions` | 待结算佣金列表（available）|
| POST | `/api/admin/settlement/create-batch` | 创建结算批次 |
| GET | `/api/admin/settlement/batches` | 结算批次列表（含状态/来源/备注）|
| GET | `/api/admin/settlement/batches/{id}` | 批次明细（所有佣金 + 用户信息）|
| GET | `/api/admin/settlement/batches/{id}/export` | 下载批次汇总 CSV（方便打款对照）|
| POST | `/api/admin/settlement/batches/{id}/mark-paid` | 标记已打款 + 填写转账备注 |

### 7.9 数据统计

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/admin/distribution/summary` | 分销总览（指标卡）|
| GET | `/api/admin/distribution/monthly-stats` | **按月统计报表**（含总佣金 / 已提现 / 待提现 / 提现人数）|
| GET | `/api/admin/distribution/funnel` | 转化漏斗数据 |
| GET | `/api/admin/distribution/ranking` | 分销员排行 |
| GET | `/api/admin/distribution/export` | 导出 CSV |

### 7.10 折扣计算

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/pay/calculate` | 计算套餐折后价。参数 `{plan_id}`，返回 `{original_price, discounted_price, reason}`。依次检查：用户有无 `referred_by`、推广员是否有效、活动是否有效、归因窗口是否超期 |
| GET | `/api/pay/plans` | 返回套餐列表，每项含 `original_price` + `discounted_price`。内部调用 `POST /api/pay/calculate` |

### 7.11 转账备注

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/admin/settlement/batches/{id}/mark-paid` | 标记已打款并填写备注（替代旧上传截图功能）|

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

| 角色 | 能否分享 | 推广目标 | 生成策略 |
|:----|:---------|:---------|:---------|
| **学生端** | ✅ | 其他学生 | LLM 基于个人数据 + campaign.poster_prompt 生成 |
| **教师端** | ✅ (若活动开放) | 学生 | 同上 |
| **家长端** | ✅ (若活动开放) | 学生(及其他家长) | 同上 |

**实现方式**: 将分享组件抽离为独立 Widget `ShareWidget`, 三端各自引用：

```
lib/
  widgets/
    share_widget.dart          ← ShareWidget 组件（含推广码显示 + 分享弹窗）
  screens/
    profile_screen.dart        ← 学生端引用 ShareWidget
    guardian_screen.dart       ← 家长/教师端引用 ShareWidget
```

后端无需任何修改，推广码按 `users.referral_code` 关联，角色无关。

### 8.3 支付页折扣展示（方案 B）

有邀请关系的用户进入支付页时，套餐列表直接展示折后价。

**页面加载**：`GET /api/pay/plans` 返回所有套餐，已附带折后价（由 `POST /api/pay/calculate` 并行计算）。

```
┌──────────────────────────────────────────┐
│ 🎉  好友邀请专属优惠                       │
│  被 {A} 邀请，首单享优惠！                │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │  📦 月度会员                          │ │
│ │  原价 ¥200    折后 ¥160  (省 ¥40)    │ │
│ │              [立即开通]                │ │
│ └──────────────────────────────────────┘ │
│ ┌──────────────────────────────────────┐ │
│ │  📦 年度会员                          │ │
│ │  原价 ¥1,280  折后 ¥1,024 (省 ¥256) │ │
│ │              [立即开通]                │ │
│ └──────────────────────────────────────┘ │
│ ┌──────────────────────────────────────┐ │
│ │  📦 终身会员                          │ │
│ │  原价 ¥1,280  折后 ¥1,024 (省 ¥256) │ │
│ │              [立即开通]                │ │
│ └──────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

**优惠到期信息**：

横幅同时展示优惠剩余时间，让用户感知紧迫感：

```
🎉 好友邀请专属优惠
被 A 邀请，首单享优惠！
⏰ 优惠还剩 23 天 14 小时（超出归因窗口后自动失效）
```

到期时间根据 **首次点击时间 + attribution_window 天数** 计算：

```sql
-- 后端计算剩余时间
SELECT datetime(referral_clicks.created_at, '+' || campaign.attribution_window || ' days') AS expires_at
FROM referral_clicks
JOIN marketing_campaigns ON marketing_campaigns.id = referral_clicks.campaign_id
WHERE ...;
```

**三种情况**：

| 情况 | 横幅显示 | 折扣是否可用 |
|:-----|:---------|:------------|
| 在归因窗口内 | ✅ "优惠还剩 X 天" | ✅ 可享受 |
| 超出归因窗口 | ❌ "优惠已过期" | ❌ 不可享受（返回原价）|
| `campaign.valid_until` 早于归因窗口 | 取较早者 | ❌ 活动已结束 |
```

**无邀请关系时**（`users.referred_by = NULL`）：正常显示原价，没有顶部优惠横幅。

**接口变更**：

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| GET | `/api/pay/plans` | 返回套餐列表，每项含 `original_price` + `discounted_price`（无优惠时两者相等）。内部调用 `POST /api/pay/calculate` 按每个套餐分别计算 |

### 8.4 前端设计缺口

当前文档对前端界面的设计还不够完整，以下场景缺少详细设计：

| 场景 | 现有设计 | 缺口 |
|:-----|:---------|:------|
| 🔔 **通知中心** | 轮询 + 未读小红点 + 列表样式 | 缺少：通知设置页（开关各类通知）、通知分类 tab（活动/收益/系统） |
| 🎉 **活动弹窗** | 描述为"弹窗展示活动" | 缺少：弹窗触发时机（首次登录？每天一次？）、关闭后是否可找回、未读活动 badge |
| 💰 **收益面板** | 佣金明细列表 | 缺少：图表展示（收益趋势图）、筛选（按时间/状态）、提现表单设计（金额输入/确认）|
| 🛒 **支付页折扣** | ✅ 已设计（§8.4） | 方案 B：列表直接展示折后价 + 好友邀请横幅 |
| 👥 **团队管理** | 树形展示 | 缺少：按层级折叠/展开、搜索团队成员、团队成员最新消费动态 |
| 📋 **提现流程** | 提现入口 + 审核 | 缺少：提现页面字段（金额/手续费/到账）/ 确认弹窗 / 到账通知 |
| 🔗 **分享落地页** | LLM 生成 H5/SVG | 缺少：未登录态引导（提示下载/注册）、断网降级方案 |
| 🖼 **SVG 海报** | 示例图 | 缺少：海报设计稿（尺寸/配色/信息层级）|
| 🎨 **空状态** | 无 | 缺少：无活动时、无收益时、无团队时的空态页面 |

这些前端设计需要产品/设计同学补充 wireframe 或 Figma 原型后，再进入开发。

---

## 九、LLM 内容生成策略

### 9.1 为什么需要 LLM 生成

固定文案和静态海报的分享转化率很低，因为"谁都没区别"。LLM 生成可以做到：

- **个性化**: 结合真实学习数据，生成"我"的推荐而不是"广告"的推荐
- **场景化**: 根据触发时机自动匹配文案和视觉风格
- **多版本 A/B**: 一次生成 3 种风格，取打开率最高的
- **角色自适应**: 对学生/老师/家长用不同的语气和视觉风格

### 9.2 输出格式对比

| 格式 | 生成成本 | 交互性 | 微信兼容 | 适用场景 |
|:----|:--------|:------|:--------|:---------|
| **SVG 海报** | 低 | 无 | ✅ 保存图片发朋友圈 | 朋友圈晒数据 |
| **海报+文案** | 低 | 无 | ✅ 图片+文字一起发 | 朋友圈/群聊推荐 |
| **HTML 分享页** | 中 | 有点击按钮 | 🤔 待调研（微信卡片预览兼容性未验证）| 深链接引流 |
| **HTML 动效页** | 高 | 动画+交互 | 🤔 同上 | 限时活动引爆 |

### 9.3 SVG 海报生成（模板架构）

**核心原则**: LLM 只生成一次模板，用户查看时只做变量替换，不重复调 LLM。

#### 架构对比

| 维度 | 旧架构（错的） | 新架构（对的） |
|------|--------------|--------------|
| LLM 调用时机 | 每次用户点"生成海报" | 管理端创建活动时 + 每日定时刷新 |
| LLM 调用频率 | 1 次/用户/点击 × 人数 | 1 次/活动 + 1 次/天（定时任务） |
| 输出 | 完整的用户个性化 SVG | SVG 模板 + `{变量占位符}` |
| 存储 | 不存，用户每次重来 | 存 `marketing_campaigns.poster_template` |
| 响应速度 | 10-30 秒（等 LLM） | 毫秒级（替换 + SVG→PNG） |

#### 模板格式

LLM 生成的 SVG 模板包含 `{变量占位符}`，运行时替换为用户数据：

```xml
<svg viewBox="0 0 800 1200">
  <text x="400" y="100" text-anchor="middle" font-size="36" font-weight="bold">
    {display_name} 的学习报告
  </text>
  <text x="50" y="200" font-size="24">
    🔥 连续学习 {streak_days} 天
  </text>
  <text x="50" y="250" font-size="24">
    📚 已学 {total_cards} 张卡片
  </text>
  <text x="50" y="300" font-size="24">
    📈 今日复习 {today_reviews} 张
  </text>
  <!-- 变量由后端运行时替换 -->
  <image x="300" y="900" width="200" height="200" href="{qr_code_url}"/>
</svg>
```

**支持替换的变量**:

| 变量 | 来源 | 示例值 |
|------|------|--------|
| `{display_name}` | `users.display_name` | `小明` |
| `{streak_days}` | `users.streak_days` | `47` |
| `{total_cards}` | `user_cards` COUNT | `156` |
| `{today_reviews}` | 今日 `review_log` COUNT | `12` |
| `{referral_code}` | `users.referral_code` | `CoEvo_ABC1` |
| `{qr_code_url}` | 推广落地页 URL | `https://...` |

#### 时序图

```

活动创建 / 定时刷新
       │
       ├── 1. 加载 prompts/signal/poster-template.md（模板生成指令）
       ├── 2. 注入活动信息（campaign name, rewards 等）
       ├── 3. LLM → 生成含 `{变量}` 的 SVG 模板
       └── 4. 存入 marketing_campaigns.poster_template

用户查看海报（零 LLM）
       │
       ├── 1. 查用户数据（display_name, streak_days 等）
       ├── 2. 加载活动 poster_template
       ├── 3. 替换所有 `{变量}` 为实际值
       ├── 4. SVG → PNG 转换
       └── 5. 返回给前端
```

#### 所需变更

| 变更 | 文件 | 说明 |
|------|------|------|
| 新增列 | `marketing_campaigns.poster_template TEXT` | 存储 SVG 模板 |
| 新增 prompt | `prompts/share/signal/poster-template.md` | "生成含 {变量} 的 SVG 模板，不含用户数据" |
| 新建端点 | `POST /api/admin/campaigns/{id}/generate-poster-template` | 管理端手动生成模板 |
| 修改端点 | `POST /api/referral/generate-poster` | 加载模板→替换→SVG→PNG，不调 LLM |
| 新增定时 | `campaign_scheduler.rs` | 每天凌晨重新生成活动模板 |

```json
{
  "user": {
    "name": "小明",
    "role": "student"
  },
  "learning_today": {
    "streak_days": 47,
    "new_cards": 12,
    "total_cards": 156,
    "total_reviews": 380,
    "overall_mastery": 85,
    "review_accuracy": 88
  },
  "learning_yesterday": {
    "new_cards": 8,
    "total_cards": 144,
    "total_reviews": 320,
    "overall_mastery": 83,
    "review_accuracy": 84
  },
  "current_plan": {
    "goal": "通过系统练习，掌握一元二次方程的配方法、公式法和因式分解法",
    "subject": "数学",
    "grade_band": "g7-9",
    "task_name": "配方法",
    "task_progress": "3/5"
  },
  "recent_completed_tasks": ["因式分解基础", "完全平方公式", "平方差公式"],
  "subject_mastery_today": [
    {"subject": "数学", "mastery": 92},
    {"subject": "英语", "mastery": 78}
  ],
  "subject_mastery_yesterday": [
    {"subject": "数学", "mastery": 89},
    {"subject": "英语", "mastery": 76}
  ],
  "vocabulary": {
    "total_words": 320,
    "mastered_today": 256,
    "mastered_yesterday": 250,
    "new_today": 6,
    "recent_mastered": ["abandon→放弃", "brilliant→杰出的", "circumstance→环境"]
  },
  "recent_reviews": {
    "today": {"correct": 25, "wrong": 3, "accuracy": 89},
    "yesterday": {"correct": 20, "wrong": 5, "accuracy": 80}
  },
  "achievements": [
    {"name": "连续学习 30 天", "icon": "🔥", "detail": "连续学习 30 天"},
    {"name": "百词斩", "icon": "📖", "detail": "已掌握 256 个单词"},
    {"name": "数学之星", "icon": "⭐", "detail": "数学掌握率 92%"},
    {"name": "复习达人", "icon": "🔄", "detail": "累计复习 380 次"}
  ],
  "campaign": {
    "name": "邀新送 7 天",
    "reward": "双方各得 7 天会员"
  },
  "referral_code": "CoEvo_A1B2"
}
```

**关键设计**：不给 LLM 算好差值，而是同时给「今天」和「昨天」两份原始数据，LLM 自己对比：

```
"learning_today":      {"mastery": 85, "reviews": 380}
"learning_yesterday":  {"mastery": 83, "reviews": 320}
→ LLM 自己算出 "掌握率提升 2%，复习次数多了 60 次"
```

**好处**：不需要后端新增任何字段或计算逻辑，所有数据在 DB 中本就存在，按时间戳查两次即可。只有今日和昨日两天的数据，简单直接。

**前后对比如何影响 LLM 输出**：

```
只有今天数据:
  → "掌握率 85%，连续学习 47 天"           ← 静态，缺乏叙事

今天 + 昨天数据:
  → "掌握率从 83% 到 85%，一天涨了 2%"     ← 有进步感，更真实
  → "今天复习正确率 89%，比昨天高了 5%"     ← 有即时动态感

有成就:
  → "已解锁🔥连续学习30天 ✓ 📖百词斩 ✓"    ← 有层次，像游戏成就展示
```

#### Prompt：只有需求描述，没有数据分析

后端把 JSON 直接嵌入 Prompt 发给 LLM。Prompt 不预设任何营销方向，只告诉 LLM 做什么、不做分析框架限制。

**完整的 Prompt 模板**：

```markdown
你是一个教育产品的分享海报设计师 + 文案写手。以下是一个用户的真实学习数据，请你：
1. 自己分析哪些数据最有营销价值
2. 生成一张 SVG 分享海报（600×900px）
3. 同步生成 1 条配合海报发布的推荐文案（60 字以内）

用户数据：
{user_data_json}

### 9.4 SVG 海报设计规范
- 尺寸：600×900px，深蓝色渐变背景（#1A237E → #0D1457）
- 文字浅色（#ffffff / #9DA0F0），数据卡片用 rgba(255,255,255,0.08)
- 推广码区域亮色高亮突出显示
- 圆角卡片分块展示数据（border-radius: 12px）
- 品牌标识 "⟐ CoEvo" 放在海报底部
- 风格克制干净，适合发微信朋友圈
- 输出纯 SVG 代码，不要 markdown 包裹标签

### 9.5 文案要求
- 与海报内容呼应，不要重复海报上已有的信息
- 包含推广码
- 口语自然，像用户自己在说话
- 60 字以内

### 9.6 输出格式
请严格按照以下 JSON 格式输出，不要增加其他内容：

{
  "svg": "<svg>...</svg>",
  "copy": "推荐文案文字"
}
```

**实际调用示例**（后端发给 LLM 的完整请求）：

```text
你是一个教育产品的分享海报设计师 + 文案写手。以下是一个用户的真实学习数据，请你：
1. 自己分析哪些数据最有营销价值
2. 生成一张 SVG 分享海报（600×900px）
3. 同步生成 1 条配合海报发布的推荐文案（60 字以内）

用户数据：
{
  "learning_today": {"streak_days": 47, "new_cards": 12, "total_cards": 156, "total_reviews": 380, "overall_mastery": 85, "review_accuracy": 88},
  "learning_yesterday": {"new_cards": 8, "total_cards": 144, "total_reviews": 320, "overall_mastery": 83, "review_accuracy": 84},
  "current_plan": {"goal": "掌握一元二次方程的配方法、公式法和因式分解法", "subject": "数学", "task_name": "配方法", "task_progress": "3/5"},
  "vocabulary": {"total_words": 320, "mastered_today": 256, "mastered_yesterday": 250, "recent_mastered": ["abandon→放弃", "brilliant→杰出的"]},
  "achievements": [{"name": "连续学习 30 天", "icon": "🔥"}, {"name": "百词斩", "icon": "📖"}, {"name": "数学之星", "icon": "⭐"}],
  "referral_code": "CoEvo_A1B2"
}

[SVG 海报设计规范...]
[文案要求...]
[输出格式...]
```

**LLM 可能输出的回复示例**：

```json
{
  "svg": "<svg width=\"600\" height=\"900\" viewBox=\"0 0 600 900\">...（海报SVG代码）</svg>",
  "copy": "今天数学掌握率到 85% 了！配方法 3/5 进度，一起扫码学双方得 7 天 → CoEvo_A1B2"
}
```

**不需要后端解析**：LLM 输出已是 JSON 格式，后端直接透传给前端。前端取 `svg` 字段渲染海报，`copy` 字段展示配文。

#### 关键问题：给 LLM 看什么数据最有效？

同样是真实数据，给不同的数据组合，LLM 得出的营销点完全不同：

| 给 LLM 看 | LLM 会怎么营销 | 效果 |
|:----------|:--------------|:-----|
| 只给 overall_mastery | "掌握率 85%" | 空洞，谁都可以说 |
| + current_plan.goal | "在学习一元二次方程的配方法，掌握率 85%" | 有具体内容，更可信 |
| + streak_days | "连续 47 天学数学，掌握率 85%" | 有坚持的叙事感 |
| + completed_tasks | "已搞定因式分解、完全平方公式，现在在攻克配方法" | 有进步路线图 |
| + subject_mastery[] | "数学 92%、英语 78%、物理 65%" | 多维度，显得全面 |
| + today_new_cards | "今天新学了 12 张卡片" | 即时感，像是在"今天" |

#### 数据优先级（按营销价值排序）

后端组装 JSON 时，按以下字段顺序排列（LLM 会更注意前面的数据）：

```
1. learning_today + learning_yesterday   ← 前后两天对比让 LLM 发现"进步"叙事
2. current_plan.goal                    ← 最具体的学习内容
3. achievements                         ← 荣誉感
4. vocabulary                           ← 英语生词的具体成果
5. recent_reviews.today/yesterday       ← 今昨复习对比
6. subject_mastery_today/7d_ago         ← 学科掌握率 + 趋势
7. streak_days                          ← 连续性社交货币
```

**数据示例 vs 营销点对照**：

```
数据: {"current_plan": {"goal": "掌握一元二次方程的配方法、公式法和因式分解法"}, "comparison": {"mastery_change_7d": "+5"}}
→ LLM 标题: "一周数学掌握率提升了 5%，我在攻克配方法！"

数据: {"recent_reviews": {"today": {"accuracy": 89}, "yesterday": {"accuracy": 80}}}
→ LLM 标题: "今天复习正确率 89%，比昨天进步了 9%，继续加油！"

数据: {"vocabulary": {"total_words": 320, "mastered_words": 256}, "achievements": [{"name": "百词斩"}]}
→ LLM 海报: "已掌握 256/320 个单词，达成🔥百词斩成就！"

数据: {"streak_days": 47, "comparison": {"streak_change_7d": "+7"}}
→ LLM 海报: "连续学习 47 天，这周又坚持了 7 天！"

数据: {"achievements": [{"name": "连续学习 30 天"}, {"name": "百词斩"}, {"name": "数学之星"}]}
→ LLM 海报: "已解锁 3 个成就：🔥连续学习30天 · 📖百词斩 · ⭐数学之星"

数据: {"recent_reviews": {"today": {"correct": 25, "wrong": 3}}, "vocabulary": {"recent_mastered": ["abandon→放弃", "brilliant→杰出的"]}}
→ LLM 文案: "今天复习了 28 个单词，新掌握了 abandon、brilliant，一起扫码来学！"
```

**后端 JSON 拼接逻辑（最小代码量）**

```python
def build_user_data_for_llm(user_id):
    data = {}
    data["learning_today"] = query_learning_snapshot(user_id, today)       # 当前数据
    data["learning_yesterday"] = query_learning_snapshot(user_id, yesterday)  # 昨天数据
    data["subject_mastery_today"] = query_mastery(user_id, today)
    data["subject_mastery_yesterday"] = query_mastery(user_id, yesterday)
    data["vocabulary"] = query_vocabulary(user_id)
    data["achievements"] = query_achievements(user_id)
    data["current_plan"] = query_current_plan(user_id)
    data["recent_reviews"] = query_recent_reviews(user_id)
    return data
```

**核心原则**：不新增字段，不预计算差值。所有数据在 DB 中已存在，按时间戳查两次即可。

**实际输出示例**（基于上述数据，LLM 可能会选择"连续学习 47 天 + 数学 92%"作为核心卖点）：

```
┌──────────────────────────────┐
│       小明 邀请你一起学       │
│                              │
│  ┌─── 数学 92% 掌握率 ────┐  │
│  │  ████████████████░░ 92% │  │
│  └─────────────────────────┘  │
│                              │
│  🔥 连续学习 47 天           │
│  📚 一元二次方程·配方法      │
│                              │
│  ┌─── CoEvo_A1B2 ─────────┐ │
│  │  复制推广码              │ │
│  └─────────────────────────┘ │
│  扫二维码一起学              │
└──────────────────────────────┘
```

#### 两条分享链路：两种 Prompt，两种解析

用户分享弹窗中有两个按钮，决定走哪条链路：

```
┌─────────────────────────────────┐
│     分享到                      │
│                                 │
│  ┌────────────┐  ┌────────────┐ │
│  │ 📷 朋友圈    │  │ 💬 会话     │ │
│  │ 保存海报图片  │  │ 复制H5链接  │ │
│  └────────────┘  └────────────┘ │
└─────────────────────────────────┘
```

两条链路共用同一份用户数据 JSON，但 Prompt 和输出格式不同：

| 链路 | 按钮文案 | 输出格式 | 前端处理 | 用户操作 |
|:-----|:---------|:---------|:---------|:---------|
| 朋友圈 | "📷 朋友圈" | SVG 代码 | flutter_svg 渲染 → RepaintBoundary 截取为 PNG → 保存相册 | 发朋友圈 |
| 会话 | "💬 会话" | 完整 HTML 文件 | 后端保存到 `/share/{code}/index.html` → 返回 URL | 复制链接发微信 |

**后端 Prompt 路由**：

```python
def generate_share(user_id, output_type):
    data = build_user_data(user_id)  # 共用同一份数据
    if data is empty:
        return default_template(output_type)  # 新用户兜底
    
    if output_type == 'poster':
        prompt = POSTER_PROMPT_TEMPLATE.format(data=data)
        result = call_llm(prompt)
        # result = {"svg": "<svg>...</svg>", "copy": "..."}
        return result["svg"], result["copy"]
    
    elif output_type == 'h5':
        prompt = H5_PROMPT_TEMPLATE.format(data=data, code=data["referral_code"])
        html = call_llm(prompt)
        # result = 完整 HTML 字符串
        save_to_disk(f"/share/{data['referral_code']}/index.html", html)
        return f"https://keyievolution.fun/share/{data['referral_code']}"
```

#### 二维码生成（后端执行，非 LLM）

海报上的二维码**不由 LLM 生成**，LLM 画不出一致可扫的二维码。流程如下：

```
LLM 生成的 SVG 中预留一个白色矩形占位区，标注 "QR_PLACEHOLDER"
  │
后端收到 SVG 后：
  1. 用 qrcode crate 生成二维码 SVG
     └── 二维码内容: https://keyievolution.fun/app/auth?ref=CoEvo_A1B2&camp=camp_xxx
  2. 查找 SVG 中的 "QR_PLACEHOLDER" 标签
  3. 替换为二维码 SVG 代码
  4. 返回完整 SVG 给前端
```

**二维码参数**：

| 属性 | 值 |
|:-----|:----|
| 内容 | `https://keyievolution.fun/app/auth?ref={referral_code}&camp={campaign_id}` |
| 尺寸 | 180×180px（与 LLM 预留的占位区一致）|
| 纠错级别 | M（7% 纠错，平衡尺寸和可扫性）|
| 颜色 | CoEvo Deep Blue `#1A237E` |
| 背景 | 白色 |
| 样式 | 圆角方块，CoEvo logo 居中覆盖 |

**追踪参数说明**：

| 参数 | 含义 | 示例 | 用途 |
|:-----|:-----|:-----|:-----|
| `ref` | 推广员 referral_code | `CoEvo_A1B2` | 归因：谁分享的 |
| `camp` | 活动 ID | `camp_001` | 归因：哪个活动的分享 |

用户扫码或点击链接进入 `/app/auth`，Flutter 前端读取 URL 参数存入 localStorage，注册时携带到后端写入 `referral_clicks` 表并设置 `users.referred_by`。

**为什么不在 H5 页面上放二维码？**

H5 页面本身就是通过链接分享的，用户打开 H5 后不需要再扫码。二维码只出现在 SVG 海报上，因为海报是静态图片，需要二维码引导用户访问链接。

#### SVG Prompt（朋友圈海报）

重点关注**视觉设计**和**截图友好**：

```markdown
你是一个教育产品海报设计师。根据以下用户数据生成一张 SVG 分享海报。

用户数据：
{user_data_json}

要求：
1. 分析数据中哪些是营销亮点，自行决定展示什么
2. SVG 尺寸 600×900px，深蓝色渐变背景
3. 推广码区域亮色高亮
4. 配色克制干净，适合朋友圈
5. 输出纯 SVG 代码，不要 markdown 包裹

同时生成 1 条配文（60 字以内），和海报内容呼应，包含推广码。

输出 JSON 格式：
{"svg": "<svg>...</svg>", "copy": "文案文字"}
```

#### H5 Prompt（会话分享卡片）

重点关注 **OG meta 标签**和**动效呈现**：

```markdown
你是一个前端开发工程师。根据以下用户数据生成一个完整的 HTML 分享页面。

用户数据：
{user_data_json}

技术要求：
1. 包含完整的 OG meta 标签（og:title, og:description, og:image, og:url）
2. 单页 HTML，所有 CSS 内联在 <style> 中，无外部依赖
3. 手机端竖屏适配，白色背景，深蓝色品牌色
4. 数据用 CSS @keyframes 动画呈现（数字滚动、进度条填充）
5. 底部有 CTA 按钮 + 推广码
6. OG:image 缩略图用 base64 内联 SVG（轻量且实时生成）

输出完整的 HTML 代码，不要 markdown 包裹。
```

H5 返回的是文件路径 + URL，不是 JSON。后端保存后直接返回 URL。

### 9.7 HTML 分享页（H5 动效页）—— 推荐方案

由 LLM 生成单张 H5 页面，结合 CSS 动效，作为链接分享的落地页。**不需要微信公众号**，纯前端技术即可实现。

#### 微信分享卡片原理（为什么不需要公众号）

微信聊天中分享链接时显示的"卡片"（标题 + 描述 + 缩略图），由目标页面的 **OG meta 标签**控制，**不需要公众号**，任何网页只需在 `<head>` 中加入以下标签即可：

```html
<meta property="og:title" content="小明 邀请你一起学数学">
<meta property="og:description" content="掌握率一周提升 5%，连续学习 47 天">
<meta property="og:image" content="https://keyievolution.fun/share/og/CoEvo_A1B2.png">
<meta property="og:url" content="https://keyievolution.fun/share/CoEvo_A1B2?ref=CoEvo_A1B2&camp=camp_xxx">
<meta property="og:url" content="https://keyievolution.fun/share/CoEvo_A1B2?t=1718612345&ref=CoEvo_A1B2&camp=camp_xxx">
```

| 功能 | 需要什么 | 你有吗 |
|:-----|:---------|:-------|
| 微信聊天分享卡片 | OG meta 标签 + 公网可访问页面 | ✅ 已有服务器和域名 |
| 微信朋友圈缩略图 | OG meta 标签（但朋友圈链接不展示卡片）| ⚠️ 朋友圈只显示文本+小图 |
| 微信 JS-SDK 自定义分享 | 认证服务号 + 备案域名 | ❌ 订阅号不行 |
| 推送消息给粉丝 | 订阅号可以（但一天只能群发 1 条） | ✅ 但与本功能无关 |

**结论：分享卡片不需要公众号。** 订阅号对此功能没有帮助，也不构成限制。

#### H5 页面结构（LLM 输出要求）

LLM 生成的 HTML 必须包含以下三部分：

**1. `<head>` — OG meta 标签**

```html
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <!-- OG 标签：控制在微信聊天中显示的卡片内容 -->
  <meta property="og:title" content="{LLM生成的标题}">
  <meta property="og:description" content="{LLM生成的描述}">
  <meta property="og:image" content="https://keyievolution.fun/share/og/{code}.png">
  <meta property="og:url" content="https://keyievolution.fun/share/{code}">
  <meta property="og:type" content="website">
  <title>{LLM生成的标题}</title>
</head>
```

**注意**：LLM 生成时，`og:image` 的 URL 指向 `/share/og/{code}.png`，这个图片**不是 LLM 生成的**，而是由后端在 H5 页面部署后，用 SVG 海报转 PNG 存放的（见下文）。

**2. `<body>` — 页面内容**

用户打开链接后看到的完整页面，包含：
- 品牌 header（⟐ CoEvo）
- 用户数据展示（数字滚动 CSS 动画）
- 当前学习进度（进度条动画）
- 推广码 + CTA 按钮（脉冲动画）
- 信任数据（如"12000+ 学生在用"）

**3. `<style>` — 所有 CSS 内联**

所有样式内联在 `<style>` 中，无外部依赖。CSS 动画用 `@keyframes` 实现。

#### OG 图片生成（固定模板，不调 LLM）

OG 缩略图在微信聊天卡片中只显示约 80×80px，生成个性化内容没有意义。因此**不额外调 LLM**，用固定品牌模板 + 推广码水印。

**固定模板 SVG**（后端代码内预置，非 LLM 生成）：

```svg
<svg width="300" height="300" viewBox="0 0 300 300" xmlns="http://www.w3.org/2000/svg">
  <rect width="300" height="300" fill="#1A237E" rx="16"/>
  <text x="150" y="100" fill="#9DA0F0" font-size="40" text-anchor="middle" font-family="sans-serif">⟐ CoEvo</text>
  <text x="150" y="150" fill="#ffffff" font-size="18" text-anchor="middle">邀请你一起学习</text>
  <rect x="60" y="190" width="180" height="40" rx="20" fill="rgba(255,255,255,0.1)"/>
  <text x="150" y="216" fill="#9DA0F0" font-size="14" font-weight="700" text-anchor="middle">{code}</text>
</svg>
```

**生成流程**：

```
部署 H5 时：
  1. 后端读取固定 OG 模板 SVG
  2. 替换 {code} 为实际推广码（如 CoEvo_A1B2）
  3. resvg 渲染为 300×300 PNG
  4. 保存到 /var/www/coevo-landing/share/og/{code}.png
```

**H5 页面的 og:image 指向此文件**：

```html
<meta property="og:image" content="https://keyievolution.fun/share/og/CoEvo_A1B2.png">
```

零额外 LLM 成本，零 API 调用。

#### 生成与部署流程

```
用户点击"💬 会话"
  → POST /api/referral/generate-h5
  → 后端:
      1. 查用户数据
      2. 调 LLM（H5 Prompt）→ 返回完整 HTML
      3. 写入 /var/www/coevo-landing/share/{code}/index.html
      4. 生成 OG 图片
      5. 返回 URL（含 ref + camp 参数）

  → 前端复制的 URL:
      https://keyievolution.fun/share/CoEvo_A1B2?t=1718612345&ref=CoEvo_A1B2&camp=camp_xxx

  → 好友点击链接:
      1. 打开 H5 页面（URL 携带 ref + camp）
      2. H5 页面 JS 读取 URL 参数
      3. POST /api/referral/click → 记录 referral_clicks → 返回 click_id
      4. 存入 localStorage
      5. 注册时复用 click_id → 写入 conversion

  → 微信卡片预览: 同上 URL + OG meta
```

**H5 URL 携带的追踪参数**:

```
https://keyievolution.fun/share/CoEvo_A1B2?t=1718612345&ref=CoEvo_A1B2&camp=camp_xxx
                                  ↑推广码   ↑缓存时间戳  ↑谁分享  ↑哪个活动
```

与 QR 码的追踪参数结构一致：`ref=CoEvo_A1B2&camp=camp_xxx`，不依赖 CTA 按钮。

#### 微信卡片缓存说明

微信会缓存 OG 卡片信息（标题/描述/缩略图），**首次抓取后缓存很久**。这意味着：

- 用户 A 生成分享链接 → 第一次发微信 → 微信抓取 OG → 缓存
- 如果用户 A 第二天学习数据变了 → 重新生成 H5 → 部署新文件 → **但微信展示的还是旧的**（因为 URL 没变）

**解决方案**：在 URL 后加时间戳参数，让微信认为每次都是新链接：

```html
<meta property="og:url" content="https://keyievolution.fun/share/{code}?t={timestamp}">
```

用户每次"生成分享链接"时，URL 都带新的 `t` 参数，微信会重新抓取 OG 信息。

#### 前端复制链接时的实际内容

```
https://keyievolution.fun/share/CoEvo_A1B2?t=1718612345&ref=CoEvo_A1B2&camp=camp_xxx
```

用户看到的是这个 URL，发到微信后展示卡片。下次重新生成，`t` 变了，卡片内容更新。
| 展示动效/数据 | ❌ 静态图片 | ✅ 数字滚动 + 动画 |

两者互补：**朋友圈用海报，群聊用 H5 链接**。

### 9.8 预生成 + 重试 + 频率控制

#### 预生成（用户不等待）

分享内容**每天主动生成一次**，用户打开分享弹窗时直接展示，无需等待 LLM。

```
每日首次登录 / App 启动时：
  → 后端检查今日是否已生成
  → 若未生成: 后台调 LLM（先 SVG 海报，再 H5 页面），缓存到服务器
  → 若已生成: 跳过

用户点击"分享"时：
  → 直接从缓存取，毫秒级展示
  → 底部显示"换一批"按钮 → 重新调 LLM → 更新缓存

次日再次打开：
  → 用户数据已更新 → LLM 生成新内容 → 覆盖旧缓存
```

#### LLM 重试机制

```
首次 LLM 调用:
  ├── 成功 → 缓存，标记今日已生成
  └── 失败（超时/格式错误/服务不可用）
       ├── 等待 3 秒后重试（最多 2 次）
       ├── 仍失败 → 使用昨日缓存（如果有）
       └── 无缓存可用 → 降级到默认模板（品牌图 + 推广码）
```

#### 生成频率限制

| 限制项 | 值 |
|:-------|:----|
| 自动预生成 | 每天 1 次（随首次启动触发）|
| 用户手动"换一批" | **不限次数** |
| 两次生成最小间隔 | 60 秒 |
| 海报 + H5 是否一次 LLM 调用 | **否，各自独立调用**。不同 Prompt 和输出格式（SVG vs HTML），混用会导致格式相互污染 |

**为什么不合并成一次调用？**
- SVG Prompt 要求输出 JSON（`{"svg": "...", "copy": "..."}`），H5 Prompt 要求输出完整 HTML
- 如果让 LLM 一次输出两种格式，Output 会相互污染（HTML 里混入 JSON 结构，或 SVG 被看成 HTML）
- 分开调用虽然多一次 LLM 费用，但输出质量稳定，且各自缓存互不影响

**成本估算**：一次 SVG 约 500-800 tokens，一次 H5 约 800-1200 tokens。两次合计约 ¥0.02/用户/天。DAU 1000 人时日均约 ¥20。用户手动换一批按不限次数计，但缓存机制确保大部分用户每日只看一次。

### 9.9 成就化分享激励

把"推广分享"融入现有成就系统（见 `docs/deliverables/achievement-system-redesign.md`），让分享行为本身成为游戏化的一部分。

#### 新增推广类成就

| 成就名称 | 解锁条件 | 奖励 |
|:---------|:---------|:-----|
| 📢 初次分享 | 首次生成分享海报 | 引导弹窗（教会用户如何分享）|
| 📢 分享达人 | 累计分享 7 天 | 7 天会员赠送 |
| 📢 社交之星 | 累计分享 30 天 | 社区勋章 + 推广佣金加成 5% |
| 📢 裂变之王 | 通过分享带来 3 个有效注册 | 专属推广员徽章 |

#### 成就页布局

现有成就页面增加"推广"分类 Tab，核心展示**今天的 SVG 分享海报本身**——用户看到的就是一张每日更新的成就卡。

```
成就页面
├── 📚 学习（现有: 连续学习/卡片数/掌握率）
└── 📢 推广（新增）
   ├── ┌──────────────────────┐
   │   │                      │
   │   │   今日成就海报         │  ← SVG 海报直接渲染在成就页
   │   │   （LLM 预生成）       │     用户能看到自己今天的学习成果
   │   │                      │     以海报形式展示，本身就是成就
   │   └──────────────────────┘
   │
   ├── 📊 推广数据
   │   ├── 累计分享天数: 7 天
   │   ├── 带来注册用户数: 3 人
   │   └── 累计佣金: ¥128
   │
   └── 操作区
       ├── [📷 发朋友圈]   ← 保存海报图片
       └── [💬 发会话]     ← 复制 H5 分享链接
```

**设计核心**：SVG 海报本身就是每日成就的一种视觉呈现。用户打开成就页，第一眼看到的是"我今天的学习成果被变成了一张好看的海报"，而不是冷冰冰的数据。分享行为不再是一个独立操作，而是成就展示的自然延伸——"这张图真好看，分享给朋友看看"。

#### 每日分享提醒

用户连续 2 天未生成分享内容时（没有新的 SVG 海报），在成就页海报区域显示灰色占位 + 提示：

```
┌──────────────────────┐
│                      │
│  今天还没有生成海报    │
│  点击生成今日学习成就卡 │  ← 灰色占位，点击触发预生成
│                      │
└──────────────────────┘
```

点击后触发 LLM 生成，完成后自动替换为彩色海报。

### 9.10 缓存与成本控制

| 内容类型 | 生成策略 | 缓存 |
|:--------|:---------|:-----|
| SVG 海报 | 每日首次启动预生成 | 当天缓存，次日刷新 |
| H5 分享页 | 每日首次启动预生成 | 永久缓存，数据变化时更新 |
| 默认模板 | 代码内预置，零 LLM 调用 | 永久 |

**经济性**: 一张 SVG 海报的 token 消耗约 500-800 tokens，按当前模型价格不到 ¥0.01/次。每个用户每天仅生成 1 次（自动预生成），假设 DAU 1000 人，日均成本约 ¥10。

### 9.11 API

| 方法 | 路径 | 说明 |
|:----|:-----|:-----|
| POST | `/api/referral/generate-poster` | 生成 SVG 海报（返回 SVG + 配文）|
| POST | `/api/referral/generate-h5` | 生成 H5 分享页（保存到 /share/{code}/，返回 URL）|
| GET | `/api/referral/user-portrait` | 获取用户学习画像数据（供 LLM 使用）|

---

## 十、v1.0 到 v2.0 的变更对比

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

## 十一、实施计划

### 前置：subscription_expires 迁移（1 天，代码 + 数据迁移）

将订阅到期日从 `user_preferences` 键值表迁入 `users.subscription_expires` 正式字段。

| 任务 | 涉及文件 | 改动 |
|:----|:---------|:------|
| schema 加字段 | `schema.rs` | `users.subscription_expires TEXT DEFAULT NULL`（已加）|
| 读到期日改 SQL | `subscription.rs:106` | `SELECT FROM user_preferences` → `SELECT users.subscription_expires` |
| 写到期日改 SQL | `subscription.rs:121` | `INSERT INTO user_preferences` → `UPDATE users SET subscription_expires=` |
| 管理端列表改 SQL | `admin_handlers.rs:176,186,234,283` | 去掉 `LEFT JOIN user_preferences`，直接读字段 |
| 管理端设置改 SQL | `admin_handlers.rs:399` | `INSERT INTO user_preferences` → `UPDATE users SET subscription_expires=` |
| VPS 数据回填 | `scripts/migrate_subscription_expires.py` | 一次性：从 `user_preferences` 批量迁到 `users.subscription_expires` |
| app_config 初始化 | 迁移脚本 | `INSERT INTO app_config (key, value) VALUES ('order_timeout_minutes', '30')` |

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
| 退款回调取消佣金（locked→cancelled） | pay_handlers.rs |
| 30天锁定期到期自动解锁（cron任务） | distribution_handler.rs |
| NOTPAY 超时关单 + 折扣回收（cron任务） | order_timeout_handler.rs |
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
| LLM 海报生成 + 配文 | qrcode_handler.rs, llm_poster.rs |
| API 频率限制: click 60/min, poster 5/min | rate_limiter.rs |

### P3：测试 + 上线（2 天）

| 任务 | 涉及文件 | 说明 |
|:-----|:---------|:------|
| 单元测试：点击追踪 | `referral_clicks` | 匿名设备去重、归因窗口 |
| 单元测试：绑定逻辑 | `users.referred_by` | 不可逆、一人一绑、非法 code 静默跳过、推广员已删除处理 |
| 单元测试：佣金计算 | `distribution_commissions` | 各级比例、30天解锁、退款取消、已删除 earner 处理 |
| 单元测试：折扣应用 | `payment_orders` | `order_creation` 触发折扣、折后价计算、NOTPAY 超时回收 |
| 单元测试：推广码生成 | `users.referral_code` | UNIQUE 冲突重试、最多 3 次跳过 |
| 集成测试：注册 → 绑定 → 支付 → 佣金 | 全链路 | mock 支付回调，验证完整数据流 |
| VPS 数据迁移 | 脚本 | `subscription_expires` 回填 + `referred_by` 初始化 |
| 回归测试 | 全量 | 确保 subscription_expires 迁移不破坏现有订阅查询 |

---

## 十二、合规说明

1. **分销层级**: 严格限制 2 级，超过 2 级属传销
2. **佣金披露**: 用户协议中明确说明推广佣金规则
3. **提现审核**: 所有提现需人工审核，防止洗钱
4. **数据留存**: 完整的点击/转化/佣金流水，可审计
5. **防刷机制**: 同一设备/同一 IP 多账号注册需风控
6. **未成年人**: 不向未满 18 岁用户开放分销功能
7. **用户删除**: 财务相关的 FOREIGN KEY 无级联删除，有佣金/提现记录的用户无法硬删除。软删除（deleted_at）不影响已有数据。如需完全清除用户，必须先结清佣金和提现

---



## 附录B：落地页移动端适配（已废弃）

> 落地页已于 2026-06-17 全面改版为 `mobile.html` + `mobile.css`（Duolingo 风格），
> 原 `index.html` 已被替换，`style.css` 中追加 `@media` 的补丁方案不再适用。
> 此处保留记录仅作历史参考。

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
