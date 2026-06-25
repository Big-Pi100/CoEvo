# 营销系统完整性与数据一致性审计 — 2026-06-25

## 审计范围

- 营销系统端到端完整性：活动创建 → 计划排期 → 事件触发 → 奖励分发 → 通知 → 用户消费
- 数据生产与消费一致性：所有写入的字段是否都被读取，JSON/API 字段名是否对齐

---

## 一、营销系统端到端完整性

### 1.1 总体流程

```
管理端创建 → 后端存入 DB → cron 定时推送
    ↑                                  ↓
    |                           ┌─ 注册触发 → campaign_executor
    |                           ├─ 支付触发 → campaign_executor
    |                           └─ plan_update → campaign_executor
    │                                  ↓
    │                          ┌─ subscription_days → 延长订阅 + 通知
    │                          ├─ commission_pct → 写入待结算佣金 + 通知
    │                          ├─ commission_fix → 写入待结算佣金 + 通知
    │                          ├─ discount_pct/fix → 记录 fulfillment
    │                          └─ 通知 → 通知面板 → 用户点击
    │                                  ↓
    │                          ┌─ 弹出海报分享对话框
    │                          └─ 跳转佣金/提现页面
    └──── 数据统计 ←──────────────
```

### 1.2 各环节覆盖

| 环节 | 状态 | 涉及文件 |
|:-----|:-----|:---------|
| 管理端创建活动 | ✅ | `admin_campaign_form.dart` (CREATE+UPDATE表单) |
| 管理端活动列表 | ✅ | `admin_campaign_list.dart` (列表+筛选+分页) |
| 管理端活动详情 | ✅ | `admin_campaign_detail.dart` (统计+奖励概览) |
| 后端 CRUD API | ✅ | `campaign_handler.rs` (create/get/list/update/stats/toggle) |
| 活动有效性判断 | ✅ | `find_active_campaigns` (status=active + 时间窗口) |
| 事件触发 | ✅ | auth.rs(registration), pay_handlers.rs(payment), plan_handler.rs(plan_update) |
| 奖励分发引擎 | ✅ | `execute_campaign_trigger` → 按 reward.type 分发 |
| 幂等性检查 | ✅ | `check_idempotent` + UNIQUE INDEX (新增) |
| 频率限制 | ✅ | `freq` 字段支持 always/daily/hourly/weekly/monthly |
| 订阅延期 | ✅ | `handle_subscription_days` 直接计算到期日 |
| 佣金写入 | ✅ | `handle_commission_pct/fix` 写入 `distribution_commissions` |
| 折扣处理 | ⚠️ | 仅记录 fulfillment，无折扣应用逻辑 |
| 通知写入 | ✅ | `write_notification` → `user_notifications` 表 |
| cron 定时推送 | ✅ | `campaign_scheduler.rs` → `push_campaign` |
| 通知面板消费 | ✅ | `notification_panel.dart` → 展示+点击导航 |
| 统计展示 | ✅ | `campaign_handler.rs` 统计 API (点击/注册/收入) |

### 1.3 缺口分析

#### ⚠️ 折扣类型 reward 无实际应用逻辑 (P2)

`discount_pct` 和 `discount_fix` 的 handler 只调用 `write_fulfillment` 记录 fulfillment，不触发任何实际折扣逻辑。后续支付流程中没有一个环节去读 reward_fulfillments 表来判断是否有折扣。**折扣活动被创建后没有任何实际效果。**

```rust
// campaign_executor.rs:129-136
"discount_pct" | "discount_fix" => {
    let val_str = reward["value"].to_string();
    if let Ok(fid) = write_fulfillment(conn, ...) {
        fulfillment_ids.push(fid);
    }
}
// └─ 只记录，不做任何事
```

#### ⚠️ campaign_type 字段被存储但从未被执行逻辑使用 (P2)

`campaign_type` 被写入 DB，被管理员 UI 展示和编辑，但 `find_active_campaigns` 不选择该字段，`execute_campaign_trigger` 也不根据它做分支。所有事件触发的逻辑只依赖 `rewards` JSON 中的每个 reward 的 `trigger` 字段。

#### ⚠️ `plan_update` 触发事件被注册但无对应 GUI

后端 `plan_handler.rs:224` 调用 `execute_campaign_trigger(conn, "plan_update", ...)`，但 admin UI 的 trigger_event 下拉只提供 `registration` 和 `payment`。管理员无法创建 `trigger_event="plan_update"` 的活动。

---

## 二、数据生产与消费一致性

### 2.1 `marketing_campaigns` 表

| 列名 | INSERT(CREATE) | INSERT(UPDATE) | SELECT(GET/LIST) | 执行器读取 | 一致性 |
|:-----|:--------------:|:---------------:|:----------------:|:----------:|:------:|
| id | ✅ | — | ✅ | — | ✅ |
| name | ✅ | ✅ | ✅ | `find_active_campaigns` | ✅ |
| campaign_type | ✅ | ✅ | ✅ | **❌ 从不消费** | ⚠️ P2 |
| description | ✅ | ✅ | ✅ | — | ✅ |
| status | ✅ | ✅ | ✅ | `status='active'` in WHERE | ✅ |
| rewards | ✅ | ✅ | ✅ | `rewards_json` parsed | ✅ |
| trigger_event | ✅ | ✅ | ✅ | — (per-reward trigger) | ✅ |
| target_roles | ✅ | ✅ | ✅ | push_campaign reads | ✅ |
| push_trigger | ✅ | ✅ | ✅ | scheduler reads | ✅ |
| push_cron | ✅ | ✅ | ✅ | scheduler parses | ✅ |
| attribution_window | ✅ | ✅ | ✅ | `find_active_campaigns` | ✅ |
| valid_from | ✅ | ✅ | ✅ | `WHERE valid_from <= datetime('now')` | ✅ |
| valid_until | ✅ | ✅ | ✅ | `WHERE valid_until > datetime('now')` | ✅ |
| participant_limit | ✅ | ✅ | ✅ | — | ✅ |
| per_user_limit | ✅ | ✅ | ✅ | — | ✅ |
| qr_code_url | ✅ | ✅ | ✅ | admin UI | ✅ |
| created_by | ✅ | — | ✅ | — | ✅ |
| created_at | ✅ | — | ✅ | — | ✅ |
| updated_by | — | ✅ | — | — | ✅ |
| updated_at | **❌ CREATE 不写** | ✅ | — | — | ⚠️ P3 |
| **poster_prompt** | ✅ | ✅ | ✅ | poster generation | ✅ |
| **poster_template** | **❌ 永不写入** | **❌ 永不写入** | — | poster generation | ❌ **P2** |
| **h5_template** | **❌ 永不写入** | **❌ 永不写入** | — | H5 generation | ❌ **P2** |
| **h5_prompt** | **❌ CREATE 不写** | ✅ | — | — | ⚠️ P3 |
| **display_positions** | **❌ CREATE 不写** | ✅ | ✅ | — | ⚠️ P3 |

### 2.2 关键不一致问题

#### 🔴 P1 — `poster_template` 和 `h5_template` 从未被写入

Schema 定义了两列但 INSERT/UPDATE handler 都不包含它们。海报/H5 生成后只能给 API 返回，无法持久化到活动记录中。如果有生成后重用的需求，这个功能缺失。

```rust
// campaign_handler.rs:117 (CREATE INSERT)
// 缺少 poster_template, h5_template, h5_prompt

// campaign_handler.rs:175-180 (UPDATE)
// 包含 poster_prompt, h5_prompt, display_positions
// 但不包含 poster_template, h5_template
```

#### ⚠️ P2 — `campaign_type` 选择不一致

| 位置 | 值 |
|:-----|:---|
| 前端表单默认值 | `'invite_award'` |
| 后端 handler 默认值 | `'standard'` |
| DB schema 默认值 | `'standard'` |
| 前端下拉选项 | `invite_award`, `commission`, `discount_pct`, `discount_fix`, `mixed` |

管理员在 UI 创建活动时，如果不修改类型，保存的是 `invite_award`。以后如果后端开始消费这个字段做分支判断，所有现存活动可能走错分支。

#### ⚠️ P2 — `display_positions` 在 CREATE 时不写入

前端发送 `display_positions` 字段，UPDATE handler 也接受它 (line 179)，但 CREATE INSERT 不包含该列。新创建的活动 `display_positions` 为 DB 默认值 `'[]'`，等效于 `'both'`（按 schema 注释），但已有的活动通过 UPDATE 后这个字段有值，新旧行为不一致。

#### ⚠️ P3 — `updated_at` 在 CREATE 时为 NULL

Schema 有 `updated_at TEXT` 但没有 DEFAULT。CREATE 不写它（只写 `created_at`），所以新行 `updated_at` 为 NULL。UPDATE 时正确设置。

---

## 三、数据生产者-消费者映射

### 3.1 Reward Fulfillment 链

```
管理员在 UI 配置 rewards JSON
  → JSON 存入 marketing_campaigns.rewards
    → campaign_executor 解析 rewards JSON
      → 按 per-reward trigger 匹配事件
        → write_fulfillment (reward_fulfillments 表)
          → write_notification
            → notification_panel 消费
```

✅ **一致** — admin UI 的 rewards 格式和 executor 的解析格式一致。

### 3.2 通知链

```
campaign_executor:
  write_notification(notification_type="reward")

distribution_handler::list_notifications:
  SELECT id, notification_type, title, body, read, action_url, created_at

notification_panel.dart:
  consumes notification_type, id, read, action_url
```

✅ **一致** — 生产者写 7 个字段，消费者读 6 个字段（`body` 被 JSON row_mapper 读取但前端可能不展示），字段名表对齐。

⚠️ `body TEXT NOT NULL` 但 API 读为 `Option<String>` — 无实际影响。

### 3.3 佣金链

```
campaign_executor:
  INSERT INTO distribution_commissions (id, campaign_id, earner_id, buyer_id, order_id, order_amount, rate_applied, amount, level, status, created_at)

distribution_handler:
  SELECT commissions by earner → 提现申请 → 结算
```

✅ **大致一致** — 但佣金结算（`settlement_batches` 和 `distribution_withdrawals`）的完整流程需进一步审计，超出了本次范围。

### 3.4 Referral Click 链

```
用户分享 → referral_link → 点击 → INSERT referral_clicks → 统计 API 读取
```

✅ **一致** — `referral_handler.rs:537` 写入，`campaign_handler.rs` 和 `distribution_handler.rs` 读取统计。

---

## 四、其他数据一致性问题

### 4.1 `users` 表 — `referred_by` 外键完整性

`referred_by` 列在 `users` 表 (schema.rs:22) 创建时就指定，`auth.rs:271` 注册时写入，`distribution_handler.rs:144` 查询读取。修复后的 `pay_handlers.rs:278` 正确通过 JOIN 读取。✅

### 4.2 `body` 字段类型不匹配

`user_notifications.body TEXT NOT NULL` — 但 API (distribution_handler.rs:49) 读为 `Option<String>`. ⚠️ P4 无实际影响。

### 4.3 前端 campaign_type 默认值不匹配后端

见 2.2 节。⚠️ P2

---

## 五、建议修复

| 优先级 | 问题 | 修复方案 |
|:-------|:-----|:---------|
| **P1** | `poster_template`/`h5_template` 从未写入 | 在 CREATE/UPDATE handler 中添加这两列的可选写入 |
| **P2** | `display_positions` CREATE 不写 | 在 INSERT 中添加该列 (或与 `h5_prompt` 一起补上) |
| **P2** | 折扣类型 reward 无实效 | 在 payment flow 中添加折扣计算逻辑 |
| **P2** | `campaign_type` 默认值三方不一致 | 统一为 `'standard'`，或由后端主导消费 |
| **P3** | `updated_at` 在 CREATE 时为 NULL | INSERT 中设置 `updated_at = now` |
| **P3** | `body` 读为 Option 与 NOT NULL 矛盾 | 改为 `row.get::<_, String>` 或 schema 改为 Nullable |

---

## 六、结论

**营销系统端到端完整性**：✅ 主线流程完整（创建→触发→分发→通知→消费），折扣类型的 reward 无实际效果。测试覆盖 9 个单元测试覆盖主要场景。

**数据一致性**：⚠️ 发现 6 个不一致问题（1 个 P1、4 个 P2、1 个 P3），主要是 CREATE/UPDATE handler 未覆盖所有 schema 列，以及 `campaign_type` 三端默认值不一致。
