# 营销系统故障调查报告

**日期**: 2026-07-08  
**报告人**: 齐活林  
**状态**: 调查完成（待审阅）

---

## 1. 问题概述

用户报告：test1 通过活动分享链接邀请 test2 注册后：
- test1 未获得「同学有礼」邀请人 7 天奖励
- test2 未获得「注册有礼」3 天奖励
- test2 获得的折扣券无法使用、无通知
- 系统整体表现为营销活动奖励发放全面失效

---

## 2. 根因分析

### 2.1 参数传序错误（trial/claim → execute_campaign_trigger）

**文件**: `backend/crates/api_server/src/trial_handler.rs:304-305`

最后一次对 `execute_campaign_trigger` 的调用中，`body.campaign_id` 被错误地传给了第 5 个参数 `order_id`，而非第 6 个参数 `campaign_filter`：

```rust
// 函数签名: (conn, trigger_event, user_id, referrer_id, order_id, campaign_filter)

// 错误（已部署版本）:
execute_campaign_trigger(&conn, "registration", &body.user_id, 
    referred_by.as_deref(), 
    body.campaign_id.as_deref(),  // ← 传给了 order_id
    None                          // ← campaign_filter = None
);

// 正确:
execute_campaign_trigger(&conn, "registration", &body.user_id,
    referred_by.as_deref(),
    None,                          // ← order_id = None
    body.campaign_id.as_deref()    // ← 传给了 campaign_filter
);
```

**影响**: 虽然 `campaign_filter=None` 时 executor 会处理所有活动，self 类奖励不受 scope 限制，理论上应正常工作——但后续的 `has_real_info` 检查与竞选期处理组合下，实际奖励并未完全发出。该 bug 属于引入性错误（由 2026-07-08 下午的补丁引入）。

### 2.2 Subscription 日期解析失败（handle_subscription_days）

**文件**: `backend/crates/api_server/src/campaign_executor.rs:433-438`

`subscription_expires` 存储格式为 ISO 8601（如 `2026-07-08T14:44:42Z`），但 `handle_subscription_days` 使用 `%Y-%m-%d` 格式解析：

```rust
let base_date = chrono::NaiveDate::parse_from_str(&base, "%Y-%m-%d")
    .unwrap_or_else(|_| chrono::Utc::now().date_naive());
```

当 `base = "2026-07-08T14:44:42Z"` 时，解析失败，退回到当天日期。结果：
- 多条 subscription 奖励在同一次 trigger 中依次处理时，每条都从当天起算
- 后一条覆盖前一条的结果
- 用户实际只获得最后一条奖励的天数

**影响范围**: 所有 `subscription_days` 类型的奖励（注册有礼 3 天、同学有礼 7 天等），只要用户之前有非 YYYY-MM-DD 格式的过期时间（如 trial 创建的 ISO 8601），就会触发该 bug。

**引入时间**: 该 bug 存在于最初的实现中，并非本次引入。但之前测试可能未覆盖多条奖励叠加的场景。

### 2.3 通知未发送

**文件**: `backend/crates/api_server/src/campaign_executor.rs`

`handle_subscription_days` 中没有调用 `write_notification`。只有 `discount_pct`/`discount_fix` 类型的奖励会发送通知。

**影响**: 用户获得 subscription_days 奖励后不会收到任何通知。

### 2.4 折扣券状态为 "granted" 而非 "fulfilled"

**文件**: `backend/crates/api_server/src/campaign_executor.rs:270-271`

折扣券的 fulfillment 写入时 status 为 `granted`，需要在用户实际支付时核销为 `fulfilled`。当前支付流程中有核销逻辑（`pay_handlers.rs:432-440`），但折扣券可能因为以下原因无法使用：
- 核销时未找到用户的 `referred_campaign_id`
- 折扣券在前端没有展示入口

---

## 3. 影响范围

| 影响项 | 严重度 | 涉及用户 |
|--------|--------|---------|
| Subscription 奖励被覆盖 | P0 | 所有有多个活动 subscription_days 奖励的新注册用户 |
| 奖励通知缺失 | P1 | 所有获得 subscription_days 奖励的用户 |
| 折扣券无法使用 | P1 | 获得折扣奖励的用户 |
| 参数传序错误 | P0 | 仅本次部署受影响 |

---

## 4. 修复建议

### 4.1 立即修复（已实施）
1. **回滚 `trial/claim` 参数顺序**：将 `body.campaign_id` 改回 `campaign_filter` 参数的原始位置（即 `campaign_filter=None`），由 executor 内部 scope 匹配决定活动范围
2. **修复日期解析**：在 `handle_subscription_days` 中截取 `d[..10]` 仅取日期部分，兼容 ISO 8601 格式

### 4.2 建议修复
3. **添加 subscription 通知**：在 `handle_subscription_days` 中调用 `write_notification`
4. **折扣使用入口**：在前端增加折扣券展示和核销功能
5. **单元测试补充**：为 `handle_subscription_days` 添加 ISO 8601 输入格式的测试用例

---

## 5. 待明确问题

- Q1: `campaign_filter` 在 trial/claim 中是否应该传具体 campaign_id？传 None 则所有活动的 self 奖励都会触发（包括其他不相关的活动），这是否符合业务预期？
- Q2: 折扣券的核销流程是否完整？支付时是否能正确匹配用户的折扣资格？
- Q3: 是否需要为 subscription_days 奖励发送通知？
