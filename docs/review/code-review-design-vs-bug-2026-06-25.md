# 审查发现 vs 设计意图分析 — 2026-06-25

逐项验证审查发现是否真正违背设计意图，确认哪些需要修、哪些是期望行为。

---

## 🔴 P0 — 真 Bug，必须修

### P0-1：SQL 注入 admin_handlers:166 ❌ 真 Bug

`format!()` 内插用户输入到 SQL，无参数化。设计上管理员搜索应该安全，但用了错误实现方式。**修**。

### P0-2：SQL 注入 curriculum_admin:568 ❌ 真 Bug

用户控制 `domain` 值构建表名。虽然 `find_card_domain()` 有白名单验证（4 个硬编码 domain），但 `patch_card_handler` 的 `input.fields` 可能覆盖 domain。设计意图是安全写入，但白名单覆盖不完全。**修**。

### P0-3：密码哈希当 token ✅ 设计如此

管理员系统有意用 bcrypt 哈希作为 session token。`verify_admin()` 直接 `WHERE password_hash=?1` 查 DB。设计意图：简化 admin 会话管理（无独立 token 表）。bcrypt 是单向的，不能反解密码。

**风险**: 哈希泄露 = token 泄露 = 永久访问权限（直到改密码）。哈希在日志中明文记录。
**建议**: 如果保留此设计，应至少对日志做哈希脱敏（`token = hash[..8] + "..."`）。

### P0-4：认证缺失 8 端点 — 逐项分析

| 端点 | 设计意图 | 判定 |
|:-----|:---------|:-----|
| `update_display_name_handler` | 用户改自己昵称 → 应鉴权当前用户 | ❌ Bug |
| `user_subscription_handler` | 公开查询他人到期日（非敏感信息） | ✅ 可公开 |
| `avatar_upload_handler` | 上传头像 → 应鉴权当前用户 | ❌ Bug |
| `avatar_get_handler` | 公开读取头像（CDN 模式） | ✅ 可公开 |
| `plans_list_handler` | 读取他人学习计划 → 隐私问题 | ❌ Bug |
| `learning_report_handler` | 读取他人学习统计 → 隐私问题 | ❌ Bug |
| `activity_handler` | 读取他人活动数据 → 隐私问题 | ❌ Bug |
| `weekly_report_handler` | 读取他人周报 → 隐私问题 | ❌ Bug |

**avatar_get / subscription 可保留公开**，其余 6 个应加鉴权。

### P0-5：payment_orders 缺 referred_by 列 ❌ 真 Bug

```rust
"SELECT user_id, referred_by FROM payment_orders"
```

表 schema 无此列，查询永远失败，所有微信支付佣金分配静默丢失。设计意图是分配佣金，但 SQL 写错了表。**必须修**。

---

## ⚠️ P1 — 逐项评估

### P1-1：大量 `.unwrap()` ❌ 部分是真 Bug

- DB `prepare()` 硬编码 SQL → 理论上安全（模式固定），但 schema 版本变更时可导致意外崩溃。建议改为 `.expect("描述")` 提供上下文。
- DB `query_row()` 等用户数据查询 → 必须处理错误，`unwrap` 会使服务器崩溃。**必须修**。
- 定时任务 `.unwrap()` → 使整个调度器崩溃停止。**必须修**。

### P1-2：Campaign party 映射 ✅ 设计如此，但测试不符

```rust
"self" => referrer_id,  // 自购佣金给推荐人
"inviter" => user_id,   // 邀请奖励给被邀请人
```

设计意图：在推广活动中，"self" 指"推广者自己"（即推荐人），"inviter" 指"被邀请的新用户"。语义上说得通。

但**测试代码**（campaign_executor.rs:637）使用 `"self"` + `user_id`，与生产代码的 `"self" → referrer_id` 矛盾。这会导致测试不可靠而非生产 bug。

**建议**: 测试数据应匹配生产语义，或重构命名消除歧义。生产行为暂不需要修。

### P1-3：支付回调与轮询竞态 ❌ 真 Bug

两个异步路径可能同时处理同一 NOTPAY→SUCCESS 订单，订阅时长翻倍。**加分布式锁或幂等键**。

### P1-4：extend_subscription 无幂等性 ❌ 真 Bug

`increment_used_count` 无条件自增。应用 `INSERT OR IGNORE` 到 fulfillment 表防止重复。**修**。

### P1-5：reward_fulfillments 无唯一约束 ❌ 真 Bug

幂等性检查有 TOCTOU 竞态。**加 UNIQUE(campaign_id, user_id, trigger_event, party, reward_type)**。

### P1-6：CP1 与 HotPath 创建重复 plan_run ❌ 真 Bug

```rust
// 无 plan_run 时创建临时记录 → 同一 conversation 两个 plan_run
INSERT INTO plan_runs (id, user_id, conversation_id, ...)
```

**修**: CP1 应先检查 conversation_id 是否已有 plan_run。

### P1-7：apply_plan_mutations 仅 task_complete 时持久化 ✅ 设计如此

`completed_concepts` 仅在 `task_complete=true` 时被持久化到 `plan_content`。CP2 在非完成任务时更新 `completed_concepts`，变更在当前 session 中有效，重启后丢失。

设计意图：减少 DB 写入频率。`completed_concepts` 主要用作本轮 LLM 上下文，暂不持久化是可接受的折中。

**建议**: 可以保留当前设计，在 CP2 退出时主动 flush 一次。

### P1-8：SSE 最后一个不完整帧被丢弃 ❌ 真 Bug

缓冲区不以 `\n\n` 结尾的剩余数据被静默丢弃。LLM 输出的最后 token 可能丢失。**修**：在流结束后处理缓冲区残余数据。

### P1-9：PII 在 profile 响应中泄露 ✅ 设计如此

`/api/user/{id}/profile` 返回解密后的 `real_name` 和 `phone`。设计意图：用户个人中心查看自己的注册信息。已鉴权（仅自己可访问），风险在 token 泄露场景下。

**建议**: 可加"仅在注册 7 天内可见"或"脱敏显示"降低风险，但当前设计不算 bug。

### P1-10：管理员列表暴露监护人 PII ✅ 设计如此

管理员查看用户详情时需要知道监护人联系方式。设计意图：客服/教务场景需要。已限制 service/super 权限。

**建议**: 当前设计合理，只需确保 `mask_phone()` 正确脱敏即可。

---

## 📋 P2 — 逐项评估

| 编号 | 发现 | 设计意图 | 判定 |
|:-----|:-----|:---------|:-----|
| P2-1 | 前端 DateTime.tryParse 静默回退 | fallback 合理 | ✅ 可接受 |
| P2-2 | Trial 无事务 | 设计缺失 | ❌ 应加 |
| P2-3 | IP 日限 TOCTOU | 设计缺失 | ❌ 应加唯一约束 |
| P2-4 | 文档写 1 天实际 5 分钟 | 开发期调短未更新 doc | ❌ 文档更新 |
| P2-5 | repair_json 边界 | 测试覆盖率问题 | ❌ 应修 |
| P2-6 | resolve_plan_id 60s 缓存 | 设计权衡 | ✅ 可接受 |
| P2-7 | 硬删除级联表手工维护 | 设计限制 | ✅ 需文档约束 |
| P2-8 | SSE [DONE] 后数据忽略 | 符合 SSE 规范 | ✅ 不修 |
| P2-9 | Cron 无幂等性 | 调度器约束 | ❌ 应加 |

---

## 最终 : 需要修的真 Bug

| 优先级 | 数量 | 说明 |
|:-------|:-----|:------|
| 🔴 P0 必须修 | 10 | SQL 注入×2、认证缺失×6 端点、payment_orders 列不存在、password token 日志脱敏 |
| ⚠️ P1 逻辑 | 5 | 支付竞态、幂等性×2、CP1 重复 plan_run、SSE 尾帧丢弃 |
| 📋 P2 完善 | 4 | Trial 事务+竞态、repair_json 边界、cron 幂等 |

**设计意图明确不修的**: campaign party 映射（语义自洽但测试不匹配）、PII 响应、`.unwrap()` 中针对硬编码 SQL 的部分、SSE [DONE] 后数据、resolve_plan_id 缓存。
