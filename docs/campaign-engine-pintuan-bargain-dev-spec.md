# 拼团与砍价 — 最小改动方案（定稿）

> v3 · 2026-06-23 · 经讨论确定最终方案

---

## 一、核心决策

| 决策 | 结论 |
|------|------|
| **关系模型** | 拼团和砍价是**共同关系**（所有人平等参与），非上下级关系 |
| **统计方式** | 现有 `referral_clicks` / `distribution_commissions` 按 campaign_id + user_id 聚合即可统计 |
| **折扣方式** | 不覆盖 `plan.price`。拼团 = discount 变体，砍价 = 多次 discount_fix 累积，都走现有 `rewards` JSON |
| **新表** | 1 张：`campaign_members`（记录谁在哪个活动中） |
| **新 handler** | 0 个。复用活动 CRUD + 推广/分享链路 |

---

## 二、为什么不需要大改

### 2.1 拼团 - 本质就是 referral + discount 活动

```
管理员配置：3 人团，月度会员 ¥200 → 每人 ¥99
→ 用户 A 发起拼团（分享活动链接）
→ 用户 B、C 通过链接加入
→ 人数达标（3人）→ 每人按 rewards 配置获得折扣 → 下单支付
→ 可选的：团长（发起人）额外获佣金
```

**现有体系已覆盖的部分：**

| 能力 | 现有机制 |
|------|----------|
| 分享链接 | `referral_handler::share_landing` + campaign H5 模板 |
| 入团追踪 | `referral_clicks` 记录谁点了活动链接 |
| 折扣 | `rewards` JSON 配置 `discount_pct`/`discount_fix` |
| 支付 | `native_pay_handler` 接收 `actual_price` |
| 佣金 | `campaign_executor` 按 `commission_pct` 发 |
| 限人数 | `marketing_campaigns.per_user_limit` |

### 2.2 砍价 - 本质就是多次 discount 累积

```
管理员配置：砍一刀减 ¥5，地板价 ¥10
→ 用户 A 发起砍价（分享活动链接）
→ 每次好友点击 → referral_clicks +1
→ 砍后价 = plan.price - (clicks × 5)，最低到地板价
→ 用户 A 以折后价下单
```

**现有体系已覆盖的部分：**

| 能力 | 现有机制 |
|------|----------|
| 发起砍价 | 分享活动链接（复用 `share_landing`） |
| 帮砍追踪 | `referral_clicks` 每次点击即一次帮助 |
| 折扣计算 | `rewards` JSON 配置 `discount_fix` = 单次砍价额 |
| 支付折后价 | `native_pay_handler` 接受 `actual_price` |

---

## 三、唯一新增：campaign_members 表

```sql
CREATE TABLE IF NOT EXISTS campaign_members (
    campaign_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    role TEXT DEFAULT 'member',             -- 'leader' | 'member'
    created_at TEXT NOT NULL,
    PRIMARY KEY (campaign_id, user_id),
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 3.1 解决的核心问题：共同关系

现有 `referral_clicks` 记录的是上下级（谁推荐了谁），拼团/砍价需要的是**共同参与**（谁和我在一个活动里）。

每次用户通过活动链接进入 → `INSERT INTO campaign_members (campaign_id, user_id, role, created_at)`。

### 3.2 role 的两种用法

| 模式 | role 分配 | 权益发放 |
|------|----------|----------|
| **人人平等**（砍价默认） | 全填 `member` | 人数达标 → 全员按 `rewards` 发相同的 discount |
| **团长有额外权益**（拼团可选） | 发起人 `leader`，其余 `member` | 达标 → 全员发基础 discount + `leader` 额外发 commission/subscription_days |

团长 = 第一个通过该活动链接进来的人，或分享链接的分享者。

### 3.3 典型查询

```sql
-- 某活动当前参与人数
SELECT COUNT(*) FROM campaign_members WHERE campaign_id = 'xxx';

-- 某人参与的所有进行中活动
SELECT cm.campaign_id, mc.name, cm.role, mc.valid_until
FROM campaign_members cm
JOIN marketing_campaigns mc ON mc.id = cm.campaign_id
WHERE cm.user_id = 'user_A' AND mc.valid_until > datetime('now');
```

---

## 四、所有改动清单

### 4.1 后端改动

| 改动 | 文件 | 行数 | 说明 |
|------|------|------|------|
| 建表 DDL | `schema.rs` | 10 行 | `campaign_members` 表 |
| 入会 API | 新增 `campaign_handler.rs` 或 `referral_handler.rs` | ~30 行 | 用户通过链接进入时 INSERT campaign_members |
| 支付传折后价 | `pay_handlers.rs` | +2 行 | `native_pay_handler` 接受 `actual_price` 参数 |
| campaign 统计 | `campaign_handler.rs::stats` | +10 行 | 查询成员数、已支付人数 |
| **后端合计** | | **~50 行** | |

### 4.2 管理端配置

拼团活动的 `campaign_type` = `team_discount`，砍价活动的 `campaign_type` = `bargain`，配置参数通过 `rewards` JSON 控制：

**拼团活动示例：**
```json
{
  "name": "3 人拼团 — 月度会员",
  "campaign_type": "team_discount",
  "rewards": [
    {"type": "discount_pct", "party": "self", "trigger": "payment", "value": 50},
    {"type": "commission_pct", "party": "self", "trigger": "payment", "value": 0.08}
  ],
  "trigger_event": "payment",
  "per_user_limit": 3,
  "valid_from": "2026-07-01",
  "valid_until": "2026-07-31"
}
```

`discount_pct: 50` = 5 折。团长额外佣金通过 `commission_pct` 拿。

**砍价活动示例：**
```json
{
  "name": "砍价 — 月度会员体验",
  "campaign_type": "bargain",
  "rewards": [
    {"type": "discount_fix", "party": "self", "trigger": "payment", "value": 500}
  ],
  "trigger_event": "payment",
  "per_user_limit": 10,
  "valid_from": "2026-07-01",
  "valid_until": "2026-07-31"
}
```

砍价逻辑：前端展示时根据 `referral_clicks` 查当前帮助次数 × 每次折扣（value），算出现价。每次帮砍 = referral_clicks +1，累计 discount_fix 叠加。

### 4.3 不需改动的文件

| 文件 | 原因 |
|------|------|
| `campaign_executor.rs` | `discount_pct`/`discount_fix`/`commission_pct` 路由已存在 |
| `distribution_handler.rs` | 折扣计算和佣金分发已完整 |
| `referral_handler.rs` | 分享 H5/海报/链接已完整 |
| `campaign_manager.rs` | 活动 CRUD 完整 |
| `payment_orders` 表 | 不关联新表，不新增字段 |
| `subscription_plans` | 不受影响 |
| prompt | 一行不改 |

---

## 五、数据统计方式

### 拼团：查 campaign_members 人数

```sql
-- 某人在某活动中已拉了多少人
SELECT COUNT(*) FROM campaign_members
WHERE campaign_id = 'xxx' AND role = 'member';

-- 某活动累计支付人数（通过 distribution_commissions）
SELECT COUNT(DISTINCT buyer_id) FROM distribution_commissions
WHERE campaign_id = 'xxx' AND status NOT IN ('cancelled');
```

### 砍价：查 referral_clicks 次数

```sql
-- 某人砍价被帮助次数
SELECT COUNT(*) FROM referral_clicks
WHERE campaign_id = 'xxx' AND referrer_id = 'user_A';

-- 当前砍后价（前端或后端计算）
-- current_price = plan.price - click_count × discount_fix_value
```

---

## 六、开发路线

| 阶段 | 内容 | 工时 |
|------|------|------|
| 1 | `campaign_members` 表 + 入会 API | 半天 |
| 2 | `native_pay_handler` 接受 `actual_price` | 0.5h |
| 3 | 管理端 campaign 配置示例 + 统计数据 | 0.5h |
| 4 | 前端 H5 模板适配（进度/倒计时/按钮） | 1 天 |
| 5 | 端到端测试 | 半天 |
| **总计** | | **2-3 天** |

---

## 七、风险与控制

| 风险 | 缓解 |
|------|------|
| 同一人多次入同一个拼团 | `campaign_members` 主键 (campaign_id, user_id) 防重 |
| 砍价刷点击 | 同 IP 限流 + per_user_limit |
| 恶意刷折扣 | 砍价每人每活动限参与一次 |
