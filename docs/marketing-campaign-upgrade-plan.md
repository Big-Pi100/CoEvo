# 营销活动系统升级方案

> 日期: 2026-07-04

## 背景

当前系统中存在三个活动："注册有礼"、"三人成团"、"同学有礼"。经调查发现以下问题：
- 推送（push）、发放（grant）、核销（redeem）三层概念混淆
- discount_pct 奖励缺少发放通知
- 三人成团的 party=all 逻辑不完整
- 各 reward type 的通知行为不一致

## 风险分析（GitNexus 影响链追溯）

升级涉及的核心函数 `execute_campaign_trigger` 和 `write_notification` 均被标记为 **CRITICAL 风险**，修改前必须审慎。

> ⚠️ 以下数据为本次升级后的实际状态，与 GitNexus 原始分析（升级前基线）存在出入：
> - `execute_campaign_trigger` 新增 1 个生产调用方（`campaign_member_handler::join`）
> - `write_notification` 新增 2 个生产调用方（discount_pct 发放通知 + reward_redeem 核销通知）

| 函数 | 风险 | 直接调用方 | 影响执行流 | 影响模块 |
|:-----|:----:|:----------:|:----------:|:--------:|
| `execute_campaign_trigger` | CRITICAL | 12 (5生产+7测试) | 4 | 7 |
| `write_notification` | CRITICAL | 8 (6生产+2测试) | 2 | 7 |
| `handle_subscription_days` | CRITICAL | 5 (1生产+4测试) | 1 | 5 |
| `campaign_member_handler`（模块） | LOW | 0 | 0 | 0 |

### 5 个生产代码调用 `execute_campaign_trigger`（d=1，修改即断）

| 调用方 | 文件 | 触发事件 |
|:-------|:-----|:---------|
| `register` | auth.rs | registration |
| `join` | campaign_member_handler.rs | registration（升级新增） |
| `distribute_commission_on_payment` | pay_handlers.rs | payment |
| `handle_plan_update` | plan_handler.rs | plan_update |
| `claim` | trial_handler.rs | registration |

### 7 个测试函数调用 `execute_campaign_trigger`（已同步修复）

全部在 campaign_executor.rs 中，更新测试断言后已通过。

### 现有通知类型分布（升级前状态）

| 通知类型 | 写入位置 | 触发时机 |
|:---------|:---------|:---------|
| `"reward"`（旧） | handle_subscription_days / handle_commission_pct/fix | 奖励发放 |
| `"campaign"`（旧） | campaign_scheduler.rs | cron 定时推送 |
| `"marketing_campaign"`（旧） | campaign_handler.rs | 管理员手动推送 |

> 以上三种旧类型已统一为 `reward_grant` / `campaign_push`，见升级方案。

## 核心概念定义

### 三层模型

```
┌─ 推送（push）─────────────────────────┐
│  告知用户有活动可参与                    │
│  触发：push_trigger / admin手动 / cron   │
│  输出：user_notifications(campaign_push) │
├─ 发放（grant）─────────────────────────┤
│  满足条件时把奖励分配给用户               │
│  触发：executor(trigger_event)           │
│        匹配 reward.trigger               │
│  动作：写 fulfillment + reward_grant 通知 │
├─ 核销（redeem）────────────────────────┤
│  奖励被实际消费                          │
│  discount: 支付时使用折扣                │
│  commission: 管理员结算提现              │
│  subscription_days: ❌ 无核销            │
└─────────────────────────────────────────┘
```

### 各概念与代码映射

| 概念 | 对应代码 | 说明 |
|:-----|:---------|:-----|
| **推送 push** | `push_trigger` / 手动推送 / cron | 何时推通知给用户 |
| **发放 grant** | `execute_campaign_trigger` + `reward.trigger` | **唯一**的奖励执行入口，匹配每个 reward 的 `trigger` 字段 |
| **发放记录 fulfillment** | `reward_fulfillments` 表 | 发放后写入的记录，用于幂等和防复用判断 |
| **发放通知 grant_notification** | `write_notification("reward_grant")` | 告知用户已获得奖励 |
| **核销 redeem** | 各奖励类型各自决定 | discount=支付时消耗，commission=提现时结算 |
| **核销通知 redeem_notification** | `write_notification("reward_redeem")` | 告知用户奖励已使用 |

### ⚠️ 注意：`campaign.trigger_event` 是冗余字段

代码中 `find_active_campaigns` 不按 `campaign.trigger_event` 过滤（见 `campaign_executor.rs:285` 注释），实际过滤条件只有 `reward.trigger == trigger_event`。`campaign.trigger_event` 仅作 admin 表单的提示，executor 从不读取。

## 当前问题清单

| # | 问题 | 文件 | 优先级 | 说明 |
|:-:|:-----|:-----|:------|:-----|
| 1 | discount_pct/fix 完全缺少发放通知 | campaign_executor.rs | **P0** | 只写 fulfillment 不写 notification，用户不知道领了折扣 |
| 2 | 三种通知类型混乱 | 全局 | P1 | 全用 notification_type="reward"，前端无法区分展示 |
| 3 | cron 推送用 "campaign"，手动推用 "marketing_campaign" 不一致 | campaign_handler.rs | P1 | 通知类型不统一 |
| 4 | party=all 没有成团人数检查 | campaign_executor.rs | P1 | 需要 campaign_members 数据，但无 join 机制时始终为空 |
| 5 | 活动推送（push_trigger）有字段但未落地 | 全局 | P2 | 无独立推送机制 |
| 6 | campaign.trigger_event 冗余 | campaign_executor.rs / admin_campaign_form.dart | P2 | executor 不读此字段，admin 表单显示误导管理员 |

## 升级方案

### 一、通知类型标准化

`user_notifications.notification_type` 统一为三种：

```yaml
campaign_push:    # 活动推送 — 管理员手动或 cron 定时推送
reward_grant:     # 发放通知 — reward handler 发放时写入
reward_redeem:    # 核销通知 — 折扣使用时写入（commission 暂未实现）
```

### 二、Admin 表单新增字段

**活动级**（admin_campaign_form.dart）：

| 现有字段 | 是否保留 | 说明 |
|:---------|:---------|:-----|
| trigger_event | ⚠️ 保留但建议隐藏 | executor 不读此字段，由 reward.trigger 决定触发时机。保留仅为向后兼容 |
| push_trigger | ✅ | 推送触发时机 |
| display_positions | ✅ | 展示位置 |
| push_cron | ✅ | cron 表达式 |

**新增活动级字段**：

```yaml
min_member_count:
  type: integer
  default: 1
  description: party=all 时的最小成团人数（用于三人成团）
```

**奖励级新增字段**（每个 reward 独立配置）：

```yaml
grant_title:
  type: string
  description: 发放通知标题，空则用默认公式 "{campaign_name}奖励已发放"
  
grant_body:
  type: string
  description: 发放通知内容，空则用默认公式 "{reward_type}已发放"
  
redeem_title:
  type: string
  description: 核销通知标题，空则用默认 "折扣已使用"

redeem_body:
  type: string
  description: 核销通知文案，空则用默认文案
```

### 三、后端改动明细

#### P0: discount_pct/fix 补发放通知

**文件**: `backend/crates/api_server/src/campaign_executor.rs`

在 `discount_pct` / `discount_fix` 处理块（约第 183-191 行）中，`write_fulfillment` 之后补 `write_notification`：

```rust
"discount_pct" | "discount_fix" => {
    let val_str = reward["value"].to_string();
    if let Ok(fid) = write_fulfillment(
        conn, campaign_id, target_user_id, party, rtype,
        &val_str, trigger_event, order_id,
    ) {
        fulfillment_ids.push(fid);
        // 补发放通知
        let title = format!("🎉 获得折扣");
        let pct = (reward["value"].as_f64().unwrap_or(1.0) * 100.0) as i64;
        let body = format!("你通过「{}」获得了 {} 折优惠！", campaign_name, pct);
        let action_url = format!("share?campaign_id={}", campaign_id);
        let _ = write_notification(conn, target_user_id, "reward_grant", &title, &body, Some(&action_url));
    }
}
```

#### P1: discount 核销通知

**文件**: `backend/crates/api_server/src/pay_handlers.rs`

支付时如果用户使用了折扣，写 `reward_redeem` 通知：

```rust
// 在折扣被应用后
write_notification(conn, user_id, "reward_redeem", 
    "折扣已使用", 
    "你在本次支付中使用了推荐折扣优惠！",
    None);
```

> commission 的核销通过管理员结算提现完成，暂未实现 `reward_redeem` 通知。

#### P1: 成团人数检查

**文件**: `backend/crates/api_server/src/campaign_executor.rs`

在 `party=all` 处理块（约第 69-82 行），从活动配置读取 `min_member_count`：

```rust
"all" => {
    // 查活动所有参与者
    let mut stmt = match conn.prepare(
        "SELECT user_id FROM campaign_members WHERE campaign_id = ?1"
    ) {
        Ok(s) => s,
        Err(_) => continue,
    };
    let users: Vec<String> = stmt.query_map(
        rusqlite::params![campaign_id], |row| row.get(0)
    ).ok().map(|rows| rows.filter_map(|r| r.ok()).collect()).unwrap_or_default();
    if users.is_empty() { continue; }
    // 检查是否达到最小成团人数
    // 需要从活动的 rewards JSON 或新字段中读取 min_member_count
    users
}
```

#### P1: 通知类型统一

**文件**: `backend/crates/api_server/src/campaign_handler.rs`（cron 推送）
**文件**: `backend/crates/api_server/src/...`（手动推送）

将 cron 推送的 `notification_type` 从 `"campaign"` 改为 `"campaign_push"`，与手动推送的 `"marketing_campaign"` 统一。

#### P2: 活动推送落地

在 `campaign_handler.rs` 的 `POST /api/admin/campaigns/{id}/push` handler 中，读取活动的 `display_positions`、`push_trigger` 等配置，写入 `user_notifications` 表：

```rust
write_notification(conn, user_id, "campaign_push", 
    &push_title, &push_body, 
    Some(&format!("share?campaign_id={}", campaign_id)));
```

### 四、前端展示改动

**文件**: `app/lib/pages/user/distribution/notification_panel.dart`

当前用 `_typeIcon()` 按 `notification_type` 渲染图标。升级后：

| notification_type | 图标 | 点击行为 |
|:------------------|:-----|:---------|
| `campaign_push` | `Icons.campaign` | 调 `_navigateByType` → 弹活动 H5 |
| `reward_grant` | `Icons.card_giftcard` | 展示奖励详情 |
| `reward_redeem` | `Icons.discount` | 展示核销详情 |

### 五、数据流（完整链路）

```
触发事件发生（registration / payment / cron）
  │
  ▼
campaign_executor 遍历所有活动（不按 trigger_event 过滤）
  │
  ├─ 对每个活动的 rewards 列表，匹配 reward.trigger == trigger_event
  │   │
  │   ├─ subscription_days → handle_subscription_days
  │   │   ├─ 发放: extend_subscription + write_fulfillment
  │   │   └─ 通知: write_notification(reward_grant)
  │   │
  │   ├─ discount_pct/fix → inline handler
  │   │   ├─ 发放: write_fulfillment
  │   │   ├─ 通知: write_notification(reward_grant)  ← P0 补
  │   │   └─ 核销: pay时 → write_notification(reward_redeem)  ← P1 加
  │   │
  │   ├─ commission_pct/fix → handle_commission
  │   │   ├─ 发放: write_fulfillment + 写佣金表
  │   │   ├─ 通知: write_notification(reward_grant)
  │   │   └─ 核销: 管理员结算提现（非自动，暂无 reward_redeem）
  │   │
  │   └─ party=all 额外检查 → campaign_members 人数
  │       └─ 未达 min_member_count → continue（跳过）
  │
  └─ 活动推送（push_trigger / cron / 手动）
      └─ write_notification(campaign_push)
```

### 六、三层模型代码审计

#### 已修复

| # | 问题 | 文件 | 严重度 | 三层归属 |
|:-:|:-----|:-----|:------:|:---------|
| 1 | cron scheduler action_url 带前导 `/`，前端不解析 | `campaign_scheduler.rs:229,243` | P1 | push |
| 2 | executor push_trigger action_url 带前导 `/` | `campaign_executor.rs:39` | P1 | push |
| 3 | `check_push_trigger` INSERT 缺 `action_url` 列 | `campaign_handler.rs:600` | P1 | push |
| 4 | 手动推送 `campaign_handler.rs:push` 缺幂等 | `campaign_handler.rs:430-441` | P1 | push |
| 5 | `generate_h5` 无日志，调试困难 | `referral_handler.rs:876-891` | P2 | push |

#### 已知未修复

| # | 问题 | 文件 | 严重度 | 三层归属 | 说明 |
|:-:|:-----|:-----|:------:|:---------|:-----|
| 6 | commission 结算/提现无 `reward_redeem` | `distribution_handler.rs` | P2 | redeem | 提现审批通过后未写核销通知 |
| 7 | `{value}` 变量从未实现 | `campaign_executor.rs` | P2 | grant | grant_title/grant_body 只支持纯字符串，不支持模板变量 |
| 8 | `campaign.trigger_event` 仍存 admin 表单 | `admin_campaign_form.dart` | P2 | 通用 | executor 不读此字段，存在表单里误导管理员 |

### 七、工作量评估

| 阶段 | 内容 | 涉及文件 | 人天 |
|:-----|:-----|:---------|:----:|
| **Phase 1** | discount_pct 补发放通知 | campaign_executor.rs | 0.3 |
| **Phase 2** | 通知类型拆分 + 核销通知 | campaign_executor.rs, pay_handlers.rs, 前端 notification_panel.dart | 2 |
| **Phase 3** | Admin 表单扩展 + 成团检查 + 活动推送 | admin_campaign_form.dart, campaign_handler.rs, campaign_executor.rs | 5 |
| **合计** | | | **7.3** |

### 八、实施状态

| 阶段 | 状态 | 内容 |
|:-----|:----:|:-----|
| **Phase 1** | ✅ 完成 | discount_pct 补发放通知（campaign_executor.rs） |
| **Phase 2a** | ✅ 完成 | 通知类型统一（reward→reward_grant, campaign→campaign_push, marketing_campaign→campaign_push） |
| **Phase 2b** | ✅ 完成 | 前端 notification_panel.dart 适配新通知类型 |
| **Phase 2c** | ✅ 完成 （仅 discount） | reward_redeem 核销通知（pay_handlers.rs），仅 discount 场景已实现；commission 提现核销尚未实现 |
| **Phase 3a** | ✅ 完成 | party=all 成团人数检查 min_member_count（campaign_executor.rs） |
| **Phase 3b** | ✅ 完成 | Admin 表单扩展 min_member_count + grant_title/grant_body/redeem_title/redeem_body |
| **Phase 3c** | ✅ 完成 | 活动推送落地（cron/手动/executor push_trigger 均已使用 campaign_push 类型） |
| **补充 1** | ✅ 完成 | campaign_member_handler 加入活动时触发 executor |
| **补充 2** | ✅ 完成 | trial_handler StartRequest 加 campaign_id，start 时写入 campaign_members |
| **补充 3** | ✅ 完成 | 前端 home_screen/auth_client/auth_provider 传递 campaign_id、已登录用户调 campaign/join |

### 九、实施建议

1. **Phase 1 立即执行** — 0.3 人天，先修掉用户可见的 discount_pct bug
2. **Phase 2 紧接 Phase 1** — 2 人天，通知类型拆分是前端改造的前提
3. **Phase 3 按需决定** — 5 人天，活动推送和成团检查可以平行开发

---

## 迁移方案

### 向后兼容

- `marketing_campaigns` 表的已有字段不变，新增字段通过 `ALTER TABLE` 添加
- 已有 `user_notifications` 中 `notification_type="reward"` 的记录不需要迁移（前端兼容两种值）
- 新的 `reward_grant` / `reward_redeem` / `campaign_push` 与旧值共存

### rollback 方案

- Phase 1 可逆：删除 discount_pct handler 中的 `write_notification` 调用即可
- Phase 2 的前端改动可逆：恢复旧的 `_typeIcon` 分支
