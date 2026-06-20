# 分销营销系统 — 改进建议

> 基于增长活动方案分析现有系统 `distribution-marketing-design.md` v2.0 的能力缺口  
> 版本: v1.0 · 2026-06-19

---

## 总览

现有系统是扎实的**分销结算基础设施**（归因、佣金、提现、结算）。但基于我设计的 7 个增长活动，系统有以下**能力缺口**：

| 层级 | 当前状态 | 需要改进 |
|:-----|:---------|:---------|
| 活动模型 | 线性活动（邀请→注册→支付→结算） | 非线性活动（拼团、排行榜、同桌） |
| 奖励时效 | 30 天锁定统一 | 即时奖励 / 阶梯奖励 / 条件奖励并存 |
| 用户分层 | 无 | 标签系统 + 分层运营 |
| 实验能力 | 无 | A/B 测试基础设施 |
| 成本控制 | 无 | LLM 预算上限 + 自动降级 |
| 实时信号 | 无 | 推广者实时反馈（有人点开了你的链接）|

---

## P0 — 必须改（否则活动跑不起来）

### P0-1：奖励时效模型扩展

**现状**：`distribution_commissions` 所有金额奖励统一走 `locked → available → settled → paid` 的 30 天锁定期。`reward_fulfillments.trigger_event` 只有 `registration / click / payment / order_creation`。

**问题**：增长活动需要不同时效的奖励——

| 活动 | 需要什么奖励 | 当前能处理吗 |
|:-----|:------------|:------------|
| 创始会员 | 推广佣金永久 15%（非常规比例） | ❌ `rate_applied` 是每笔固定值 |
| 每日进化 | 对方注册后**立即**给 3 天会员 | ❌ 没有"即时"路径 |
| 学霸周榜 | 每周结算排行榜奖励（非佣金） | ❌ 无此概念 |
| 同桌计划 | 7 天连续学习后给 7 天会员（条件触发） | ❌ 无条件奖励 |

**改进方案**：

在 `marketing_campaigns` 的 `rewards` JSON 中增加 `fulfill_mode` 字段：

```json
{
  "type": "days",
  "party": "inviter",
  "value": 3,
  "trigger": "registration",
  "fulfill_mode": "immediate"    // 新增：可选 locked / immediate / conditional
}
```

同时在 `reward_fulfillments` 表加字段支持条件奖励：

```sql
-- reward_fulfillments 加字段
ALTER TABLE reward_fulfillments ADD COLUMN fulfill_mode TEXT DEFAULT 'locked';
  -- immediate / locked / conditional
ALTER TABLE reward_fulfillments ADD COLUMN condition_type TEXT;
  -- 条件奖励：streak_days / orders_count / days_active 等
ALTER TABLE reward_fulfillments ADD COLUMN condition_value INTEGER;
  -- 达标值：7天 / 3单 等
```

**一键安装命令**（无数据迁移风险）：

```sql
-- 加字段（已有数据 rows 会得到 NULL，不影响现有逻辑）
ALTER TABLE reward_fulfillments ADD COLUMN fulfill_mode TEXT DEFAULT 'locked';
ALTER TABLE reward_fulfillments ADD COLUMN condition_type TEXT;
ALTER TABLE reward_fulfillments ADD COLUMN condition_value INTEGER;
```

### P0-2：用户标签与分层系统

**现状**：当前用户分层只有 `target_roles` 枚举（student / teacher / guardian），且是活动级别的过滤，不是用户级别的属性。

**问题**：几乎所有增长活动都需要按用户属性做条件判断——

| 活动 | 需要什么属性 |
|:-----|:------------|
| 创始会员 | `is_founder: true` |
| 学霸周榜 | `last_week_rank: 5` |
| 每日进化 | `days_active_streak: 7` |
| 老师推荐码 | `is_teacher: true` |

**改进方案**：新建 `user_tags` 表

```sql
CREATE TABLE user_tags (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    tag_key TEXT NOT NULL,         -- is_founder / activity_level / last_week_rank
    tag_value TEXT,                -- true / high / "3"
    expires_at TEXT,               -- 标签过期时间（成就类标签永不过期）
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE UNIQUE INDEX idx_tag_unique ON user_tags(user_id, tag_key);
CREATE INDEX idx_tag_key_value ON user_tags(tag_key, tag_value);
```

**使用场景**：

```sql
-- 筛选创始会员来推送专属活动
SELECT u.* FROM users u
JOIN user_tags t ON t.user_id = u.id
WHERE t.tag_key = 'is_founder' AND t.tag_value = 'true';

-- 筛选上周排行榜前 10 的用户
SELECT u.* FROM users u
JOIN user_tags t ON t.user_id = u.id
WHERE t.tag_key = 'last_week_rank'
  AND CAST(t.tag_value AS INTEGER) <= 10;
```

然后在 `marketing_campaigns` 中加一个过滤字段：

```sql
ALTER TABLE marketing_campaigns ADD COLUMN tag_filter TEXT;
  -- JSON: {"activity_level": ["high", "medium"]}
  -- 或 {"is_founder": "true"}
```

### P0-3：拼团/团体折扣活动类型

**现状**：`campaign_type` 没有 `team_discount` / `group_buy`。

**问题**：「3人拼团7折」是学期冲刺的核心活动，但系统完全没有这个能力。

**改进方案**：新增 `team_purchases` 表

```sql
CREATE TABLE team_purchases (
    id TEXT PRIMARY KEY,
    campaign_id TEXT NOT NULL,
    team_leader_id TEXT NOT NULL,         -- 团长
    team_size INTEGER DEFAULT 1,          -- 当前人数
    target_size INTEGER NOT NULL,         -- 目标人数（如 3）
    discount_pct INTEGER NOT NULL,        -- 折扣百分比（如 30 = 7折）
    status TEXT DEFAULT 'pending',        -- pending / completed / timeout / cancelled
    created_at TEXT NOT NULL,
    completed_at TEXT,
    timeout_at TEXT,                      -- 超时时间（72小时后） 
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id),
    FOREIGN KEY (team_leader_id) REFERENCES users(id)
);

CREATE TABLE team_members (
    id TEXT PRIMARY KEY,
    team_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    order_id TEXT,                        -- 支付成功的订单ID，成团前可为NULL
    joined_at TEXT NOT NULL,
    FOREIGN KEY (team_id) REFERENCES team_purchases(id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (order_id) REFERENCES payment_orders(id)
);
```

**新增 campaign_type**：
```sql
-- campaign_type 新增值: team_discount / group_buy
-- rewards JSON 新增字段:
{
  "team_size": 3,
  "discount_pct": 30,
  "team_leader_bonus_days": 7,
  "team_timeout_hours": 72,
  "refund_immediately": true
}
```

### P0-4：排行榜引擎

**现状**：系统没有任何排名计算、排行缓存、percentile 统计能力。

**问题**：「学霸周榜」「AI进化周报」都依赖排行统计，但系统没有。

**改进方案**：新建 `leaderboard_cache` 表 + cron 任务

```sql
CREATE TABLE leaderboard_cache (
    id TEXT PRIMARY KEY,
    metric TEXT NOT NULL,              -- total_cards / streak_days / accuracy
    period TEXT NOT NULL,              -- weekly / monthly / alltime
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    user_id TEXT NOT NULL,
    rank INTEGER NOT NULL,
    score REAL NOT NULL,
    percentile REAL,                   -- 百分比排位
    created_at TEXT NOT NULL,
    UNIQUE(metric, period, user_id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX idx_lb_metric_period ON leaderboard_cache(metric, period, rank);
```

**cron 任务**：

```rust
// 每周一 00:30 执行
async fn calculate_weekly_leaderboard() {
    // 1. 聚合 card_memory 的复习数据（本周内）
    // 2. 按 total_cards DESC 排序
    // 3. 写 leaderboard_cache (period='weekly')
    // 4. 计算 percentile: rank / total_users * 100
    // 5. 更新 user_tags: last_week_rank
}
```

---

## P1 — 强烈建议改（提升运营效率）

### P1-1：A/B 测试基础设施

**现状**：零实验能力。每次活动只能全量上线，无法做对比测试。

**问题**：增长方案的核心是"每两周一个实验"，但系统不支持——

- 怎么给 50% 用户推 LLM 海报、另外 50% 推模板？
- 怎么知道 LLM 海报的转化率是否显著高于模板？
- 实验结束后怎么自动裁定胜负？

**改进方案**：新建 `experiments` 表

```sql
CREATE TABLE experiments (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,                 -- "海报生成方式 A/B 测试"
    campaign_id TEXT NOT NULL,          -- 关联的活动
    status TEXT DEFAULT 'running',      -- running / concluded / cancelled
    control_pct INTEGER DEFAULT 50,     -- 控制组占比
    target_metric TEXT NOT NULL,        -- 核心指标: click_rate / conversion_rate
    min_sample_size INTEGER,            -- 最小样本量（提前计算）
    started_at TEXT NOT NULL,
    concluded_at TEXT,
    winner TEXT,                        -- control / variant / inconclusive
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id)
);

CREATE TABLE experiment_variants (
    id TEXT PRIMARY KEY,
    experiment_id TEXT NOT NULL,
    variant_name TEXT NOT NULL,          -- "control" / "llm_poster" / "template_poster"
    config_override TEXT NOT NULL,       -- 覆盖的活动配置（JSON diff）
    traffic_pct INTEGER NOT NULL,        -- 流量占比
    FOREIGN KEY (experiment_id) REFERENCES experiments(id)
);
```

**流量分配**：

```rust
// 用户进入活动时的分流逻辑
async fn assign_variant(user_id: &str, campaign_id: &str) -> &str {
    let experiment = get_active_experiment(campaign_id).await?;

    // 确定性哈希分配（同一用户始终进入同一组）
    let slot = hash(user_id) % 100;
    if slot < experiment.control_pct {
        "control"
    } else {
        "variant"
    }
}
```

**胜负裁定**（简化版，MVP 够用）：

```rust
async fn conclude_experiment(experiment_id: &str) {
    let control_rate = get_metric(experiment_id, "control");
    let variant_rate = get_metric(experiment_id, "variant");

    // 简单提升率判定（精确统计需要 Bayesian，MVP 先用这个）
    let lift = (variant_rate - control_rate) / control_rate;
    let result = if lift.abs() < 0.05 {
        "inconclusive"
    } else if lift > 0 {
        "variant"
    } else {
        "control"
    };
    // 自动切换活动配置到胜出一方的配置
    switch_to_winner_config(experiment_id, result);
}
```

### P1-2：推广者实时反馈信号

**现状**：`user_notifications` 是站内轮询（60 秒间隔），且仅支持系统→用户单向通知。

**问题**：「每日进化1%」需要"有人看了你的海报"这种**用户A→用户B**的实时信号，60 秒轮询太慢。

**改进方案**：在现有 WebSocket 连接基础上增加事件通道

```rust
// 用户 A 的分享链接被点击时
async fn on_referral_click(click: ReferralClick) {
    // 1. 写入 referral_clicks（现有逻辑）
    // 2. 立即写入 user_notifications（小红点）
    user_notifications.insert(
        user_id: click.referrer_id,  // 发给推广者 A
        notification_type: "referral_click",
        title: "有人正在看你的海报",
        body: "你的朋友正在查看分享页面",
        action_url: "/app/referral/stats",
    );
    // 3. 如果用户 WebSocket 在线，推送实时事件
    ws_push(click.referrer_id, "referral_click", Event {
        title: "有人正在看你的海报 👀",
        body: "你的朋友正在查看你的分享页面！",
    });
}
```

**WebSocket 事件类型扩展**：

| 事件 | 触发 | 效果 |
|:-----|:-----|:-----|
| `referral_click` | 有人点击了 A 的链接 | 即时推送 + 小红点 |
| `reward_earned` | A 获得了即时奖励（非 locked） | 即时推送 + 弹窗 |
| `registration_from_my_link` | 有人通过 A 的链接注册 | 即时推送 |
| `team_member_joined` | 拼团有人加入 | 推送给团长 |

### P1-3：活动级 LLM 预算控制

**现状**：LLM 生成海报没有成本上限。

**问题**：如果 DAU 从 1000 涨到 10000，日成本从 ¥10 涨到 ¥100——但你可能在盈利之前就因为云账单爆了。

**改进方案**：`app_config` 加预算配置 + `marketing_campaigns` 加成本控制

```sql
-- app_config 新增
INSERT INTO app_config (key, value) VALUES ('llm_daily_budget_cents', '2000');  -- 日预算 ¥20
INSERT INTO app_config (key, value) VALUES ('llm_monthly_budget_cents', '50000');  -- 月预算 ¥500
```

```sql
-- marketing_campaigns 加字段
ALTER TABLE marketing_campaigns ADD COLUMN llm_budget_cents INTEGER;
  -- 每个活动的独立预算上限（NULL = 用全局预算）
ALTER TABLE marketing_campaigns ADD COLUMN degrade_policy TEXT DEFAULT 'template_only';
  -- template_only / skip_posters / no_llm
```

```rust
// 自动降级逻辑
async fn should_generate_llm_poster(user_id: &str, campaign_id: &str) -> bool {
    let today_cost = get_today_llm_cost().await;
    let daily_budget = get_app_config("llm_daily_budget_cents").await;

    if today_cost >= daily_budget {
        log_warn!("LLM 日预算已超¥{}/日，降级为模板", daily_budget / 100);
        return false;  // 超预算 → 用默认模板
    }

    // 非活跃用户（7天内无学习行为）也不调 LLM
    let is_active = check_user_activity(user_id, 7).await;
    if !is_active {
        return false;
    }

    true
}
```

---

## P2 — 值得做（优化用户体验和运营效率）

### P2-1：同桌/学习伙伴关系

**现状**：`users.referred_by` 只有单向的推广者→被邀请者关系。用户之间没有双向关系。

**需要新建** `learning_buddies` 表：

```sql
CREATE TABLE learning_buddies (
    id TEXT PRIMARY KEY,
    user_a TEXT NOT NULL,
    user_b TEXT NOT NULL,
    status TEXT DEFAULT 'pending',     -- pending / active / ended
    current_streak INTEGER DEFAULT 0,  -- 连续共同学习天数
    max_streak INTEGER DEFAULT 0,
    campaign_id TEXT,                  -- 关联的活动（如果通过活动结成的同桌）
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_a) REFERENCES users(id),
    FOREIGN KEY (user_b) REFERENCES users(id),
    FOREIGN KEY (campaign_id) REFERENCES marketing_campaigns(id)
);

CREATE INDEX idx_buddies_user ON learning_buddies(user_a, status);
CREATE INDEX idx_buddies_user_b ON learning_buddies(user_b, status);
```

**cron 任务**：每天凌晨更新共同学习天数

```rust
async fn update_buddy_streaks() {
    // 1. 查昨天哪些同桌两人都完成了学习
    // 2. 更新 learning_buddies.current_streak
    // 3. 如果 streak >= 7 → 触发 reward_fulfillments（同桌挑战奖励）
}
```

### P2-2：活动类型 handler 可扩展模式

**现状**：活动调度器是硬编码的 switch-case，新增活动类型需要改代码。

**建议**：改为注册式 handler 模式——

```rust
// 活动类型注册表
lazy_static! {
    static ref CAMPAIGN_HANDLERS: HashMap<&'static str, Box<dyn CampaignHandler>> = {
        let mut m = HashMap::new();
        m.insert("invite_award", Box::new(InviteAwardHandler));
        m.insert("commission", Box::new(CommissionHandler));
        m.insert("team_discount", Box::new(TeamDiscountHandler));  // 可扩展
        m.insert("leaderboard", Box::new(LeaderboardHandler));     // 可扩展
        m
    };
}

trait CampaignHandler {
    fn on_registration(&self, ctx: &CampaignContext) -> Result<()>;
    fn on_payment(&self, ctx: &CampaignContext) -> Result<()>;
    fn on_cron(&self, ctx: &CampaignContext) -> Result<()>;
    // 新增活动类型只需实现这个 trait
}
```

这样新增「拼团」「排行榜」等活动类型时，只需要加一个新的 handler 实现，不需要改调度器的核心逻辑。

### P2-3：管理端实验看板

**现状**：管理端（§6）没有实验数据面板。

**建议**：在管理端新增"实验管理"板块——

```
├── 🧪 实验管理（新增）
│   ├── 进行中实验
│   │   名称 | 关联活动 | 控制组 vs 实验组 | 样本量 | 当前胜率 | 操作
│   ├── 已完成的实验
│   │   名称 | 结论 | 提升率 | 生效时间
│   └── 新建实验（表单）
│       关联活动 | 变体配置 | 流量比例 | 目标指标
```

---

## 改进优先级汇总

| 编号 | 改进项 | 改动量 | 影响活动 | 优先级 |
|:-----|:-------|:-------|:---------|:-------|
| P0-1 | 奖励时效模型扩展 | reward_fulfillments 加 3 个字段 | 所有活动 | 🔴 必须 |
| P0-2 | 用户标签系统 | 新建 user_tags 表 | 创始会员、学霸周榜、老师推荐码 | 🔴 必须 |
| P0-3 | 拼团表结构 | 新建 2 张表 + 1 个 campaign_type | 学期冲刺 | 🔴 必须 |
| P0-4 | 排行榜引擎 | 新建 leaderboard_cache 表 + cron | 学霸周榜、AI 进化周报 | 🔴 必须 |
| P1-1 | A/B 测试系统 | 新建 2 张表 + 分流逻辑 | 增长实验框架 | 🟡 强烈 |
| P1-2 | 实时反馈信号 | WebSocket 事件扩展 | 每日进化、同桌计划 | 🟡 强烈 |
| P1-3 | LLM 预算控制 | app_config + 降级逻辑 + campaign 字段 | 所有 LLM 相关 | 🟡 强烈 |
| P2-1 | 同桌关系 | 新建 learning_buddies 表 + cron | 同桌计划 | 值得做 |
| P2-2 | Handler 注册模式 | 重构活动调度器 | 所有未来活动 | 值得做 |
| P2-3 | 实验管理看板 | 前端新页面 | 运营效率 | 值得做 |

---

## 实施建议

### 分批实施策略

```
第一批（MVP 必备，上线前完成）:
  P0-1: 奖励时效模型 (0.5天)
  P0-2: 用户标签系统 (1天)

第二批（紧跟 MVP，上线后 1-2 周）:
  P0-3: 拼团表结构 (1天)  
  P0-4: 排行榜引擎 (2天)

第三批（上线后 2-4 周）:
  P1-1: A/B 测试系统 (2天)
  P1-2: 实时反馈信号 (1天)  
  P1-3: LLM 预算控制 (0.5天)

第四批（持续迭代）:
  P2-1: 同桌关系 (1天)
  P2-2: Handler 注册模式 (1天)
  P2-3: 实验管理看板 (1天)
```

### 不推荐的改动

- ❌ **把 `rewards` 从 JSON 拆成独立表**：当前 JSON 设计足以支持动态活动配置，拆表只会增加复杂性，不改
- ❌ **把 commission 比例做成阶梯表**：虽然增长方案建议阶梯佣金，但这属于活动配置层面（`rewards` JSON），不需要改表结构
- ❌ **新建 permission 体系**：当前 `target_roles` + `user_tags` 配合足够
- ❌ **独立"活动引擎"微服务**：CoEvo 是单体架构，不需要拆服务增加部署复杂度
