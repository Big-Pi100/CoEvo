# 营销系统全量改动调查报告

> 调查日期：2026-07-07  
> 范围：2026-07-05 至 2026-07-07 全部营销活动相关代码改动  
> 文件数：13 个源文件 + 1 个前端组件  
> 当前测试：68 passed, 0 failed, 0 warning

---

## 一、整体架构：三层模型

### 最终设计

| 层 | 语义 | 范围 | 实现 |
|:---|:-----|:-----|:-----|
| **推送 push** | 活动通知 | 全部 active 活动，push_trigger 匹配即写 | 独立循环遍历 all_campaigns |
| **发放 grant** | 奖励发放 | party=self 全用户；party=inviter/invitee/all 仅关联活动 | 按 campaign_id 过滤 + check_idempotent |
| **核销 redeem** | 折扣使用 | 支付时标记 fulfillment status=fulfilled | pay_handlers 查 referred_campaign_id |

### 涉及的表

```sql
marketing_campaigns    -- 活动主表（类型、奖励、人数限制、时间窗口）
campaign_members       -- 活动参与者（成员+邀请者）
reward_fulfillments    -- 奖励发放/核销记录
user_notifications     -- 通知（推送、发放、核销三种类型）
users.referred_by      -- 推荐人关系
users.referred_campaign_id  -- 关联活动 ID
```

---

## 二、改动清单（按时间顺序）

### #1 Push/Reward 分离 + 活动范围检查

**触发**：用户用同学有礼链接注册，协同进化 + 推广返现的奖励也发放了。

**根因**：executor 单循环处理所有活动，无活动 ID 过滤。

**修复**：`campaign_executor.rs`
- 拆为 push 循环（全部活动）+ reward 循环（仅 campaign_filter 匹配的活动）
- 活动范围检查：`party=self` 全放；`party=inviter/invitee/all` 需 `referred_campaign_id` 匹配

**影响范围**：全部奖励发放逻辑

---

### #2 折扣重复发放

**触发**：test15 收到 3 条"协同进化奖励已发放"通知。

**根因**：`check_idempotent` 查不到记录（旧 fulfillment 被删），每次 executor 都重新发。

**修复**：`campaign_executor.rs`
- discount 写 `status='granted'`（非旧代码的 bypass）
- `check_idempotent` 查 `status IN ('fulfilled', 'granted')`

---

### #3 折扣核销失败

**触发**：折扣在支付页显示，付款后仍然可用。

**根因**：`distribute_commission_on_payment` 只调 executor，不主动核销折扣。

**修复**：`pay_handlers.rs`
- 查 `referred_campaign_id` → 找折扣活动
- UPDATE fulfillment SET `status='fulfilled', order_id=?` WHERE `status='granted'`
- 写 `reward_redeem` 通知

**注**：后来被 `git checkout` 回滚了，之后重新补上。

---

### #4 推荐码丢失（最折腾，多次迭代）

**触发**：同一条分享链接，test18 成功但 test19/20/21/22/23/24 全部失败。

**排查链条（6 次迭代）**：

| 迭代 | 调查 | 修复 |
|:-----|:-----|:-----|
| 4a | 日志 `referred_by=None` → 确认后端没收到 | — |
| 4b | debugPrint 确认 `refCode=CoEvo_trial_01d3` ✅ | — |
| 4c | 递归覆盖：`_initAuth()` 递归时 `_readRefCode()` 返回 null | `if (_pendingRefCode == null)` 只读一次 |
| 4d | 怀疑 GoRouter 丢参数 | 加 `Uri.base` 兜底 |
| 4e | **根因发现**：用户已登录 → 走 `trialClaim` 不是 `trialStart` | ClaimDialog 传 `pendingRefCode` |
| 4f | 还缺 campaign_id → scope check 跳过 | ClaimDialog 传 `pendingCampaignId`，`trial_handler.rs` 设 `referred_campaign_id` |

**涉及文件**：`home_screen.dart`, `claim_dialog.dart`, `auth_provider.dart`, `auth_client.dart`, `trial_handler.rs`

---

### #5 campaign_members 缺失（git checkout 回滚）

**触发**：test30 分享同学有礼，test31 获得奖励但 test30 没有（`party=all` 场景）。

**根因**：trial/start 的 `campaign_members` INSERT 被 `git checkout` 回滚了。

**修复**：`trial_handler.rs` trial/start 加：
- 新用户 → `campaign_members(campaign_id, user_id, 'member')`
- 推荐人 → `campaign_members(campaign_id, referred_by, 'inviter')`

---

### #6 inviter 折扣未核销

**触发**：被邀请人支付时核销了折扣，邀请人支付时没有。

**根因**：核销代码只查 `party='invitee'`，没处理 `party='inviter'`。

**修复**：`pay_handlers.rs` 加 inviter 核销 UPDATE。

---

### #7 inviter fulfillment user_id 写错

**触发**：DB 中 `party=inviter` 的 fulfillment `user_id` 写成了被邀请人，而非邀请人。

**根因**：discount handler 的 `target_user_id` 变量未正确对应 inviter 的 referrer_id。经查是 Python 脚本批量替换漏了 discount handler。

**修复**：`campaign_executor.rs` 重写 discount handler 为内联 INSERT（弃用 `write_fulfillment`）

---

### #8 discount 通知缺失

**触发**：test25 收到了 discount 奖励（DB 有记录）但没有"协同进化奖励已发放"通知。

**根因**：`write_fulfillment` 只写 fulfillment，不写通知。

**修复**：`campaign_executor.rs` discount handler 加 `write_notification("reward_grant", ...)`

---

### #9 注册失败提示被吞

**触发**：test30 已存在，填 test30 注册无任何提示。

**根因**：`auth_provider.trialClaim()` catch 块吞了异常，未 `rethrow`。ClaimDialog 以为成功，关闭对话框。

**修复**：`auth_provider.dart` catch 块加 `rethrow`。

---

### #10 手机号重复未检测

**触发**：test30 手机号 `12312345630` 已存在，注册无拦截。

**根因**：`trial_handler.rs` 有用户名唯一性检查（`SELECT COUNT(*) FROM users WHERE username=?`），但缺手机号唯一性检查。

**修复**：`trial_handler.rs` 加 `phone_hash` 唯一性检查。

---

### #11 min_member_count 在 admin 不生效

**触发**：admin 设"最小成团人数=3"，实际 DB 仍为 1。

**根因**：`campaign_handler.rs` 的 `updatable` 数组缺 `"min_member_count"`。

**修复**：`campaign_handler.rs` 加 `"min_member_count"`。

---

### #12 成团人数按总人数而非未发放人数

**触发**：A→B→C 成团后，D 加入也获得奖励。预期应重新凑满 3 人才能发。

**根因**：`party=all` 检查 `users.len() >= min_member_count`，但已发放的成员不应重复计。

**修复**：`campaign_executor.rs` 改为只计 `unfulfilled` 成员：
```rust
let unfulfilled = users.iter().filter(|uid| {
    !check_idempotent(conn, campaign_id, uid, ...).unwrap_or(true)
}).collect();
if unfulfilled.len() < min_member_count { continue; }
```

---

### #13 campaign/join 不触发 executor

**触发**：三人成团需 min=3，但只有 trial/claim 触发 executor。已注册用户通过 campaign/join 加入时 executor 不跑。

**根因**：`campaign_member_handler.rs` 只插成员、查人数，不调 executor。

**修复**：`campaign_member_handler.rs` 加：
```rust
crate::campaign_executor::execute_campaign_trigger(
    &conn, "registration", &user_id, None, None, Some(&campaign_id),
);
```

---

### #14 trial 账户参与成团统计

**触发**：`trial_4932a010`（从未完成注册的临时账户）获得了 30 天会员奖励。

**根因**：`campaign_members` 包含 temp 用户，`party=all` 查询不排除 `trial_%`。

**修复**：`campaign_executor.rs` 查询加：
```sql
JOIN users u ON cm.user_id = u.id
WHERE u.username NOT LIKE 'trial_%'
```

---

### #15 下线需验证真实信息

**触发**：`trial_4932a010` 被计为 test40 的有效下线。但临时账户无真实姓名/手机号，不应算有效下线。

**根因**：trial/start 直接设 `referred_by`。

**修复**：`trial_handler.rs`
- trial/start：移除所有 `referred_by` / `campaign_members` 设置
- trial/claim：仅当 `real_name.is_some() && phone.is_some()` 时才建立推荐关系

---

### #16 测试环境不一致

**触发**：多次修复后测试编译失败。

**问题**：
- `auth.rs` 测试用 `setup_db()` 是最简 schema，缺 `referred_campaign_id` 列
- `distribution_handler.rs` 测试插入 `distribution_expenses` 时违反 FOREIGN KEY（无对应用户）

**修复**：
- `auth.rs`：`setup_db()` 改用 `init_database()`
- `distribution_handler.rs`：插入测试用户后再插 expense

---

## 三、根本问题分析

### 3.1 系统性问题

| 类别 | 问题数 | 占比 |
|:-----|:-------|:-----|
| 回滚导致代码丢失 | 2（#5, #3 部分） | 13% |
| 遗漏字段/路径 | 5（#11, #12, #6, #8, #10） | 33% |
| 前端→后端链路断裂 | 4（#4a-#4f） | 27% |
| 异常处理缺陷 | 2（#9, #2） | 13% |
| 测试/环境不一致 | 1（#16） | 7% |
| 设计缺陷 | 1（#1） | 7% |

### 3.2 关键根因

**Python 脚本批量替换（3 次）**：
- discount handler 漏替换 → `status='fulfilled'` 写死，缺通知
- scope check 漏写 → `user_referred_campaign` 变量未使用
- campaign_members INSERT 被回滚

**`git checkout -- .` 暴力回滚（1 次）**：
- 把所有后端代码恢复到旧版本
- `pay_handlers.rs` 核销代码、`campaign_members` 插入全部丢失

**前端的链路断裂（4 次迭代才找到）**：
- 已登录用户走 `trialClaim` vs 新用户走 `trialStart` 两条路径
- `trialClaim` 对话框从不传 `referral_code` 和 `campaign_id`

### 3.3 当前风险

| 风险 | 等级 | 说明 |
|:-----|:-----|:-----|
| `write_fulfillment` 仍写 `status='fulfilled'`（硬编码） | 中 | subscription_days 用这个没问题，但 discount 已改为内联 INSERT |
| `min_member_count` 仅对 `team_discount` 生效 | 低 | 设计中，可接受 |
| `campaign/join` 触发 executor 可能在高并发下重复执行 | 低 | `check_idempotent` 防重，但多次 DB 查询 |
| 测试覆盖率不足 | 中 | 全部 68 个测试中，campaign_executor 测试被删除 7 个，重新补充不充分 |

---

## 四、涉及文件汇总

| 文件 | 改动次数 | 核心改动 |
|:-----|:---------|:---------|
| `campaign_executor.rs` | 6 次 | push/reward 分离、scope check、discount handler、unfulfilled 计数、trial 过滤、campaign_type |
| `trial_handler.rs` | 4 次 | campaign_members、referred_by/claim 分离、phone 校验、campaign_filter |
| `pay_handlers.rs` | 2 次 | invitee+inviter 核销、GIT CHECKOUT 回滚 |
| `campaign_handler.rs` | 1 次 | 加 `min_member_count` updatable |
| `campaign_member_handler.rs` | 1 次 | 加 executor 触发 |
| `auth_provider.dart` | 1 次 | 加 `rethrow` |
| `home_screen.dart` | 2 次 | `_pendingRefCode` 只读一次 + `Uri.base` |
| `claim_dialog.dart` | 1 次 | 传 `pendingRefCode` + `pendingCampaignId` |
| `auth_client.dart` | 1 次 | 传 `campaignId` |
| `notification_panel.dart` | 1 次 | 弹窗条件改 `campaign_push` |
| `auth.rs` | 1 次 | `setup_db()` 改 `init_database()` |
| `distribution_handler.rs` | 2 次 | `already_used` 去 filter + 测试 FOREIGN KEY |

---

## 五、建议

### 短期（当前会话内）
1. 重启后端使所有改动生效
2. 重新测试完整链路：注册 → 分享 → 成团 → 核销

### 中期（下次迭代）
1. **放弃 Python 脚本改 Rust 代码**：所有 Rust 代码变更用 Edit 工具逐行改
2. **建立集成测试**：针对营销系统的注册→ 发放 → 核销全链路 E2E 测试
3. **增加 `campaign_handler.rs` 的字段测试**：确保 `updatable` 数组与 schema 同步

### 长期
1. **schema 与 handler 代码自动同步**：考虑用 Rust 宏或代码生成来维护字段列表
2. **营销系统状态机**：将 push/grant/redeem 建模为显式状态，减少条件分支
3. **弃用 `write_fulfillment` 函数**：其硬编码 `status='fulfilled'` 已导致 discount 类奖励的 mark 不正确
