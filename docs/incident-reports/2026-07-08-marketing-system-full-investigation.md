# 营销系统全面故障调查报告

**日期**: 2026-07-08  
**报告人**: 齐活林  
**状态**: 待审阅

---

## 1. 三层方案回顾与功能回退分析

### 1.1 三层奖励体系设计

根据 `distribution-marketing-design.md`，营销奖励分为三层：

| 层 | 名称 | 触发时机 | 代表活动 | 状态流转 |
|----|------|---------|---------|---------|
| 1 | **发放层** (Grant) | 注册/支付/计划更新 | 注册有礼、推广返现 | `granted` |
| 2 | **核销层** (Fulfill) | 用户主动使用/支付时 | 折扣券、订阅延期 | `granted → fulfilled` |
| 3 | **通知层** (Notify) | 发放/核销成功后 | 站内通知/弹窗 | 写 `user_notifications` |

### 1.2 VPS 部署版本功能回退清单

| 功能 | 本地测试 | VPS 部署 | 回退原因 |
|------|---------|---------|---------|
| 注册有礼 3 天 | ✅ 发放成功 | ❌ 未发放 | `campaign_filter` 传参错误 + 日期解析失败 |
| 同学有礼 inviter 7 天 | ✅ | ❌ 未发放 | 同上 |
| 同学有礼 invitee 7 天 | ✅ | ❌ 覆盖为其他值 | 多条 `set_expires` 相互覆盖 |
| 折扣券发放通知 | ✅ | ❌ 无通知 | 通知发送未实现（从未部署） |
| 天数发放通知 | ✅ 测试断言通过 | ❌ 无通知 | 测试用的 `insert_test_user` 无 `subscription_expires` |
| 折扣核销 | ✅ | ❌ 不可用 | 前端无展示入口、核销 pipeline 未接通 |
| real_name/phone 不可修改 | ✅ 设计如此 | ❌ 可修改 | `COALESCE` 允许用新值覆盖旧值 |

---

## 2. 问题代码定位

### Issue 1: `execute_campaign_trigger` 参数顺序错误

**文件**: `trial_handler.rs:304-305`  
**引入时间**: 2026-07-08 下午第三次部署  
**根因**: 调用 `execute_campaign_trigger` 时第 5 个参数应传 `None`（order_id），第 6 个参数应传 `body.campaign_id`（campaign_filter），实际写反：

```rust
// 已部署的错误版本
execute_campaign_trigger(&conn, "registration", &body.user_id,
    referred_by.as_deref(),
    body.campaign_id.as_deref(),  // ← 本应是 order_id=None
    None                           // ← 本应是 campaign_filter
);
```

**影响**: `campaign_filter=None` 时 executor 处理所有活动，但后续 `has_real_info` 与作用域检查的交互导致奖励未正确发放。

### Issue 2: `handle_subscription_days` 日期解析不兼容 ISO 8601

**文件**: `campaign_executor.rs:433-438`  
**引入时间**: 初始实现（2026-06-19），但此前无多条奖励叠加场景  
**根因**: `trial/start` 写入的 `subscription_expires` 格式为 `"2026-07-08T14:44:42Z"` (ISO 8601)，但 `handle_subscription_days` 用 `"%Y-%m-%d"` 格式解析：

```rust
let base = match &old_expires {
    Some(d) if d.as_str() >= today.as_str() => d.clone(),
    // d = "2026-07-08T14:44:42Z" → 传入下一个解析步骤
    _ => today.clone(),
};
let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
    .unwrap_or_else(|_| chrono::Utc::now().date_naive());
    // ↑ 解析失败，退回到今天
```

**影响**: 多条 subscription 奖励在同一次 trigger 中依次处理时，每条都从当天起算，后一条覆盖前一条。用户只获得最后一条的天数。

### Issue 3: Subscription 天数奖励未发通知

**文件**: `campaign_executor.rs:482-489`  
**引入时间**: 初始实现  
**根因**: 本地测试 `test_handle_subscription_days_new_user` 第 958 行断言 `notif_count == 1`，是因为 `insert_test_user` 创建的用户没有现有通知，所以计数从 0 变成 1。但这个测试只验证了**一条通知被写入**，不验证**通知内容是否正确**。生产环境中通知写入没有问题，但**折扣券的通知未被用户看到**，因为前端没有展示入口。

### Issue 4: `real_name` / `phone` 仍然可修改

**文件**: `trial_handler.rs:254-258`  
**引入时间**: 初始实现  
**根因**: `COALESCE(?3, real_name)` 允许用 `body.real_name` 中的新值覆盖已有值。如果有人重复调用 `trial/claim` 或 `auth/register`，可以修改已设置的姓名和手机号。

```rust
"UPDATE users SET username = ?1, password_hash = ?2, \
 real_name = COALESCE(?3, real_name), \       // ← body.real_name 不为空时覆盖
 phone = COALESCE(?4, phone), \               // ← body.phone 不为空时覆盖
 phone_hash = COALESCE(?5, phone_hash), \
 bind_hash = COALESCE(?6, bind_hash), \
 referred_by = COALESCE(?7, referred_by) \
 WHERE id = ?8"
```

而且 `auth/register`（`auth.rs:160`）也调用 `execute_campaign_trigger("registration")`，但使用了简化的用户数据，没有 `has_real_info` 保护。

### Issue 5: 折扣券（granted 状态）无前端使用入口

**文件**: `reward_fulfillments` 表，status=granted  
**根因**: 折扣券发放后标记为 `granted`，需在用户支付时核销为 `fulfilled`。但前端没有展示折扣券的页面或弹窗，用户不知道有折扣，也无法在支付时使用。

---

## 3. 系统性根因总结

```
┌─────────────────────────────────────────────────────┐
│ 1. 参数顺序错误（引入性 bug）                          │
│    trial/claim → execute_campaign_trigger            │
│    campaign_id 传给了 order_id 参数                    │
│    campaign_filter = None                             │
└──────────────────────┬──────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│ 2. 日期解析不兼容（潜伏 bug）                          │
│    trial/start 写入 ISO 8601 格式                     │
│    handle_subscription_days 解析失败 → 退回到今天       │
│    多条奖励相互覆盖                                     │
└──────────────────────┬──────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│ 3. 测试覆盖不足                                       │
│    - 无集成测试（完整注册→奖励链路）                    │
│    - insert_test_user 不包含 subscription_expires     │
│    - has_real_info 逻辑无测试                          │
│    - 无 campaign_filter 参数测试                        │
└──────────────────────┬──────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────┐
│ 4. 修复过程违规                                       │
│    - 未先调查写报告 → 直接改代码                       │
│    - 每次修复引入新 bug（按下葫芦起了瓢）                │
│    - 修完未回归验证其他活动类型                          │
└─────────────────────────────────────────────────────┘
```

---

## 4. 解决方案与实施步骤

### 4.1 已修复（已部署）
| 修复 | 文件 | 说明 |
|------|------|------|
| campaign_filter 回退 | `trial_handler.rs:304` | 恢复为 `campaign_filter=None`，让 executor 内部 scope 匹配 |
| ISO 8601 日期兼容 | `campaign_executor.rs:433-438` | 截取 `d[..10]` 只取日期部分 |
| 测试通过 | `cargo test` | 68 passed |

### 4.2 待修复

#### Fix A: real_name/phone 不可修改（P0）

**方案**: 在 `trial/claim` 和 `auth/register` 中，如果用户已有 `real_name`，则跳过更新：

**`trial_handler.rs` 修改**:
```rust
// 7. 更新用户 — real_name/phone 一旦设置不可修改
if let Err(e) = conn.execute(
    "UPDATE users SET username = ?1, password_hash = ?2, \
     real_name = CASE WHEN real_name IS NULL THEN COALESCE(?3, real_name) ELSE real_name END, \
     phone = CASE WHEN phone IS NULL THEN COALESCE(?4, phone) ELSE phone END, \
     phone_hash = CASE WHEN phone_hash IS NULL THEN COALESCE(?5, phone_hash) ELSE phone_hash END, \
     bind_hash = COALESCE(?6, bind_hash), \
     referred_by = COALESCE(?7, referred_by) \
     WHERE id = ?8",
    ...
);
```

同样适用于 `auth.rs` 中的 `register` 函数。

#### Fix B: Campaign 作用域处理优化（P0）

**问题**: `campaign/join` 和 `trial/claim` 都会触发 `execute_campaign_trigger("registration")`。`campaign/join` 用 `campaign_filter` 限定特定活动，`trial/claim` 不限定。

**方案**: 保持 `trial/claim` 中 `campaign_filter=None`，让 executor 内部 scope 匹配。同时：
- `campaign/join` 只触发 `party=all` 奖励（拼团），不触发 self/inviter/invitee
- `trial/claim` 触发所有适用奖励

#### Fix C: 折扣券使用入口（P1）
- 前端在收益面板或钱包页面展示已获得但未使用的折扣券
- 支付时检查用户是否有 `status=granted` 的折扣并自动应用

#### Fix D: 补充测试（P1）
1. `execute_campaign_trigger` 集成测试：创建带 ISO 8601 `subscription_expires` 的用户，验证多条奖励累加
2. `has_real_info` 测试：无 real_name/phone 的用户不应获得奖励
3. `campaign_filter` 参数测试
4. `real_name` 不可修改测试

---

## 5. 修复计划

| 优先级 | 修复项 | 预估工时 | 依赖 |
|--------|--------|---------|------|
| P0 | Fix A: real_name/phone 不可修改 | 30min | 审批 |
| P0 | Fix B: 作用域处理优化 | 1h | 审批 |
| P1 | Fix C: 折扣券使用入口 | 2h | 前端开发 |
| P1 | Fix D: 补充测试 | 1h | 修复后 |
