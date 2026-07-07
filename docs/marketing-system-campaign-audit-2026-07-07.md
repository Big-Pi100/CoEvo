# 四个营销活动全面排查报告

> 排查日期：2026-07-07  
> 排查方法：DB 配置 → 代码逐行跟踪四个活动在三层模型（推送/发放/核销）中的完整路径  
> 当前测试：68 passed, 0 failed, 0 warning

---

## 一、四活动概览

| 活动 | ID | 类型 | party | 奖励 | 人数限制 | push_trigger |
|:-----|:----|:-----|:------|:-----|:---------|:------------|
| 注册有礼 | ef05faa2 | distribution | self | subscription_days 3天 | 无 | registration |
| 协同进化 | 8fb65ce5 | team_discount | all | subscription_days 7天 | min=3 | registration |
| 同学有礼 | 9a12f617 | team_discount | all | subscription_days 30天 | min=1 | registration |
| 推广返现 | c82f800e | distribution | inviter+invitee | commission 15% + discount 1折 | 无 | **plan_update** |

---

## 二、逐活动代码路径跟踪

### 1. 注册有礼 ✅

**配置**: `subscription_days | party=self | trigger=registration | value=3`

| 阶段 | 触发 | 路径 | 结果 |
|:-----|:-----|:-----|:-----|
| 推送 | 注册 | push 循环: push_trigger=registration ✓ | campaign_push 通知 ✅ |
| 发放 | 注册 | reward: trigger=registration ✓ → scope check: party=self → 跳过 | subscription_days 发放 ✅ |
| 核销 | N/A | subscription_days 直接兑现，无需核销 | — |

**无问题** ✅

---

### 2. 协同进化 ✅

**配置**: `subscription_days | party=all | trigger=registration | value=7 | min_member=3 | campaign_type=team_discount`

| 阶段 | 触发 | 路径 | 结果 |
|:-----|:-----|:-----|:-----|
| 推送 | 注册 | push 循环: push_trigger=registration ✓ | 通知 ✅ |
| 发放 | 注册 | reward: trigger ✓ → scope check: [campaign_id 匹配?] → party=all: 查 campaign_members(排除 trial_%) → team_discount: unfulfilled≥3? | 成团发奖 ✅ |
| 核销 | N/A | subscription_days，无需核销 | — |

**关键检查点**:
- `referred_campaign_id=8fb65ce5` → scope check 通过 ✅
- `campaign_type=team_discount` → 走 unfulfilled 计数 ✅
- `username NOT LIKE 'trial_%'` → 临时账户排除 ✅
- `referred_by` 仅在 trial/claim 有真实姓名+手机号时设置 ✅

**无问题** ✅

---

### 3. 同学有礼 ✅

**配置**: `subscription_days | party=all | trigger=registration | value=30 | min_member=1 | campaign_type=team_discount`

与协同进化完全同路径，仅 `min_member=1` 不同。逐人发放（成团门槛=1）。

**无问题** ✅

---

### 4. 推广返现 ⚠️ 需注意

**配置**: 两条奖励规则

**奖励 1**: `commission_pct 15% | party=inviter | trigger=payment`  
**奖励 2**: `discount_pct 1折 | party=invitee | trigger=registration`

#### 4a. 注册触发

| 阶段 | 路径 | 结果 |
|:-----|:-----|:-----|
| 推送 | push_trigger=**plan_update** ≠ registration → **不推送** | ⚠️ 注册时无通知 |
| 发放(discount) | reward trigger=registration ✓ → scope check [campaign_id 匹配?] → party=invitee → discount_pct 发放 | ✅ |
| 发放(commission) | reward trigger=payment ≠ registration → 跳过 | 正确（支付时才发） |

#### 4b. 支付触发

| 阶段 | 路径 | 结果 |
|:-----|:-----|:-----|
| 推送 | push_trigger=plan_update ≠ payment → **不推送** | ⚠️ 支付时也无通知 |
| 发放(commission) | reward trigger=payment ✓ → scope check → party=inviter → commission 发放 | ✅ |
| 折扣核销(invitee) | pay_handlers: 查 buyer.referred_campaign_id → 匹配 discount 活动 → UPDATE | ✅ |
| 折扣核销(inviter) | pay_handlers: 查 buyer 的 inviter discount → UPDATE | ✅ |

#### 4c. 潜在问题

| 问题 | 影响 | 判定 |
|:-----|:-----|:-----|
| `push_trigger=plan_update`，注册/支付均不触发推送 | 用户可能不知道推广返现活动 | ⚠️ 设计决定，非 Bug |
| `distribute_commission_on_payment` 在 `notify_payment` (406行) 和 `get_calculate` (692行) 两处调用 | 可能重复核销，但 `check_idempotent` 防重 | ✅ 有保护 |
| commission 检查 `already_used` 用 `party=self` 过滤 | 推广返现是 party=inviter → 不过滤此条件 | ✅ 不对应 |
| 折扣核销的 `discount_campaign` 查询需要 `rewards LIKE '%discount_pct%'` | 确保只核销有 discount 的活动 | ✅ |

---

## 三、跨活动交互验证

### 场景：用户 A 通过协同进化链接注册

```
referred_campaign_id = 8fb65ce5

活动循环：
  注册有礼(ef05faa2)：scope check SKIP(party=self) → 发放 ✅
  协同进化(8fb65ce5)：scope check 8fb6 match → 成团检查 → 发放 ✅
  同学有礼(9a12f617)：scope check 8fb6 ≠ 9a12f6 → SKIP ✅
  推广返现(c82f800e)：scope check 8fb6 ≠ c82f8 → SKIP ✅
```

### 场景：用户 B 通过同学有礼链接注册

```
referred_campaign_id = 9a12f617

活动循环：
  注册有礼(ef05faa2)：scope check SKIP(party=self) → 发放 ✅
  协同进化(8fb65ce5)：scope check 9a12f6 ≠ 8fb65c → SKIP ✅
  同学有礼(9a12f617)：scope check match → 发放 ✅
  推广返现(c82f800e)：scope check 9a12f6 ≠ c82f8 → SKIP ✅
```

### 场景：用户 C 通过推广返现链接注册

```
referred_campaign_id = c82f800e

活动循环：
  注册有礼(ef05faa2)：scope check SKIP(party=self) → 发放 ✅
  协同进化(8fb65ce5)：scope check c82f8 ≠ 8fb65c → SKIP ✅
  同学有礼(9a12f617)：scope check c82f8 ≠ 9a12f6 → SKIP ✅
  推广返现(c82f800e)：scope check match → invitee discount 发放 ✅
```

### 场景：注册有礼始终发放

**注册有礼使用 `party=self`**，scope check 的条件是 `if campaign_filter.is_none() && party != "self"` → party=self 时直接跳过检查 → **无论用户通过哪个活动链接注册，注册有礼都发放** ✅

---

## 四、现有问题汇总

| # | 问题 | 优先级 | 状态 |
|:--|:-----|:-------|:-----|
| 1 | `campaign_filter` 传参错误砍掉注册有礼 | P0 | ✅ 已修复 (trial_handler.rs 改为 None) |
| 2 | 推广返现 push_trigger=plan_update 注册/支付均不推送 | P2 | 设计决定，非 Bug |
| 3 | `min_member_count` admin 不保存 | P1 | ✅ 已修复 (campaign_handler.rs 加字段) |

---

## 五、修复建议

### P1: 推广返现增加注册推送

当前 `push_trigger=plan_update`，用户注册/支付后看不到推广返现活动通知。建议改为 `registration`。

**影响**：
- 注册时：所有用户收到 4 条 campaign_push（含推广返现）
- 之前改过：push_title 统一为"新活动: 推广返现" → 与 scope check 无关，推送不限活动范围

### P2: 增加E2E测试

当前 68 个单元测试覆盖了 `check_idempotent`、`find_active_campaigns`、`handle_subscription_days`、`handle_commission_pct` 等，但缺少完整的注册→ 发放 → 核销全链路测试。
