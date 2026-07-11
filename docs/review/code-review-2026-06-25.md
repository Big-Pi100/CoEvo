# CoEvo 全量代码审查报告 — 2026-06-25

审查范围：`backend/crates/` + `app/lib/`

---

## 🔴 P0 — 崩溃/数据丢失/安全漏洞

### P0-1：SQL 注入 — admin_handlers.rs:166

`format!()` 内插用户输入到 SQL LIKE 子句，无参数化。

```rust
let p = format!("%{}%", query.q);
where_parts.push(format!("(u.id LIKE '{}' OR u.username LIKE '{}' OR u.display_name LIKE '{}')", p, p, p));
```

**风险**: 任意管理员可读取所有用户 PII 或篡改数据。

### P0-2：SQL 注入 — curriculum_admin.rs:568

用户控制的 `domain` 值构建表名后内插 SQL。

```rust
let sub_tbl = format!("prebuilt_{}_cards", domain);
conn.execute(&format!("UPDATE {} SET {}=?1 WHERE id=?2", sub_tbl, key), ...)
```

**风险**: 跨表写入，提权或数据篡改。

### P0-3：密码哈希作为会话令牌 — admin_handlers.rs:121

管理员登录返回 bcrypt 哈希作为 API token。

```rust
ok(serde_json::json!({"token":hash,"role":role,"admin_id":id}))
```

**风险**: 哈希明文传输+日志记录；哈希泄露即密码泄露；无法单独吊销 token。

### P0-4：认证完全缺失 — 8 个端点

| 处理函数 | 行号 | 操作 |
|:---------|:-----|:-----|
| `update_display_name_handler` | 1839 | 修改任意用户 display_name |
| `user_subscription_handler` | 1866 | 查询任意用户订阅到期日 |
| `avatar_upload_handler` | 2100 | 为任意用户上传头像 |
| `plans_list_handler` | 2145 | 读取任意用户完整学习计划 |
| `learning_report_handler` | 2241 | 读取学习统计/成就/进度 |
| `activity_handler` | 2393 | 读取热力图活动数据 |
| `weekly_report_handler` | 2464 | 读取每周统计数据 |

`update_display_name_handler` 甚至没有 `headers` 参数——完全无认证。

### P0-5：支付分销佣金查询错误列 — pay_handlers.rs:278

```rust
"SELECT user_id, referred_by FROM payment_orders WHERE id = ?1"
```

`payment_orders` 表无 `referred_by` 列，查询每次都会运行时崩溃（返回 `Err`）。**所有微信支付回调的佣金分配静默失败**。

---

## ⚠️ P1 — 高危逻辑错误

### P1-1：生产代码大量 `.unwrap()` 导致 DoS

关键位置（均可触发服务器崩溃）：

| 文件 | 行号 | 触发条件 |
|:-----|:-----|:---------|
| `admin_handlers.rs` | 224, 565, 628+ | DB 准备/查询失败 |
| `routes.rs` | 1120, 1253, 1341+ | DB 操作失败 |
| `campaign_scheduler.rs` | 257, 335, 337+ | 定时任务崩溃 → 调度器停止 |

### P1-2：Campaign party 映射语义倒置 — campaign_executor.rs:49-56

```rust
// "self" → 给了推荐人（应该是自己）
// "inviter" → 给了自己（应该是推荐人）
let target_user_id = match party {
    "self" => match referrer_id { Some(rid) => rid, ... },
    "inviter" => user_id.to_string(),
};
```

**风险**: 自购奖励错误发给推荐人，邀请奖励错误发给被邀请人。

### P1-3：微信支付回调与轮询竞态导致订阅翻倍 — pay_handlers.rs:428-451

`pay_notify_handler`（回调）和 `order_status_handler`（轮询）可能同时处理同一 NOTPAY→SUCCESS 订单，`extend_subscription` 被调用两次，订阅时长翻倍。

### P1-4：`extend_subscription` 无幂等性 — subscription.rs:221

```rust
increment_used_count(conn, plan_id)?;  // 每次调用都自增
```

对同一订单调用两次，套餐已售数重复计算。应使用 `INSERT OR IGNORE` 或唯一标识。

### P1-5：`reward_fulfillments` 无唯一约束 — campaign_executor.rs:179-198

幂等性检查是 TOCTOU 竞态，并发请求可绕过。表缺少 `UNIQUE(campaign_id, user_id, trigger_event, party, reward_type)` 约束。

### P1-6：CP1 与 HotPath 创建重复 plan_run — ws.rs:949-959

HotPath `handle_plan_update` 创建 plan_run 的同时，CP1 也创建临时 plan_run，同一 conversation 下两个 plan_run，`resolve_plan_id` 可能返回错误的一个。

### P1-7：`apply_plan_mutations` 仅在 task_complete 时持久化 — plan_handler.rs:698-699

```rust
if plan_id != "placeholder" && task_complete {
    // 更新 plan_runs.plan_content
}
// completed_concepts 等变更被丢弃
```

CP2 更新 `completed_concepts` 而未完成任务时，变更在下一轮 LLM 丢失。

### P1-8：SSE 最后一个不完整帧被静默丢弃 — llm_caller.rs:360-378

缓冲区中不以 `\n\n` 结尾的剩余数据被丢弃，LLM 输出的最后部分可能丢失。

### P1-9：PII 在 profile 响应中泄露 — routes.rs:1577-1583

```rust
"real_name": decrypted_real_name,
"phone": decrypted_phone,
```

任何有 token 的用户可读取自己完整的解密 PII。

### P1-10：管理员用户列表暴露监护人 PII — admin_handlers.rs:200-224

```rust
"guardian_name": decrypt_maybe(g_name),
"guardian_phone_masked": mask_phone(g_phone),
```

有 service 权限即可枚举所有学生并查看监护人信息。

---

## 📋 P2 — 中危/最佳实践

### P2-1：设置到期前端计算 — admin_screen.dart:329-332

```dart
final base = (currentExpiry != null && currentExpiry.isNotEmpty)
    ? (DateTime.tryParse(currentExpiry) ?? now)
    : now;
```

`DateTime.tryParse` 静默回退，不报错。

### P2-2：Trial 账户创建无事务 — trial_handler.rs:73-99

INSERT users / tokens / trial_ip_log 三个独立语句，无显式事务。token 写入失败时留下孤立用户。

### P2-3：Trial IP 日限存在 TOCTOU 竞态 — trial_handler.rs:42-55

```rust
let today_count: i64 = conn.query_row(...).unwrap_or(0);
if today_count >= 3 { return TOO_MANY_REQUESTS; }
```

并发请求可绕过日限。

### P2-4：Trial 文档与实际不一致 — trial_handler.rs:68

模块文档写"1 天试用"，实际代码给 5 分钟（`minutes(5)`）。

### P2-5：`repair_json_backslashes` 状态跟踪不完善 — plan_handler.rs:1646-1647

```rust
'"' if i == 0 || chars[i - 1] != '\\' => { ... }
```

`\\"` 序列应结束字符串（`\\` 是转义反斜杠，`"` 是结束引号），但当前逻辑错误地认为 `"` 被转义。

### P2-6：`resolve_plan_id` 60 秒缓存 — plan_handler.rs:1547-1572

如果 plan_run 被删除或替换，缓存返回旧 ID。

### P2-7：`hard_delete_expired_trials` 级联表列表手工维护 — campaign_scheduler.rs:73-86

新增引用 `users.id` 的表若未加入列表，硬删除时产生孤立数据。

### P2-8：SSE `[DONE]` 后数据被忽略 — llm_caller.rs:368

`[DONE]` 帧中后续 `data:` 行被静默丢弃。

### P2-9：Campaign cron 推送无幂等性 — campaign_scheduler.rs:125-239

调度器两次运行重叠时推送触发两次。

---

## 总结

| 等级 | 数量 | 关键风险 |
|:-----|:-----|:---------|
| 🔴 P0 | 5 | SQL 注入×2、密码当 token、认证缺失×8 端点、支付佣金静默失败 |
| ⚠️ P1 | 10 | 大量 unwrap、party 倒置、订阅翻倍、奖励重复、SSE 截断、PII 泄露 |
| 📋 P2 | 9 | 事务缺失、竞态、缓存陈旧、文档不一致 |

**最紧急修复优先级**：
1. SQL 注入 (admin_handlers:166, curriculum_admin:568)
2. 支付佣金 `referred_by` 列不存在 (pay_handlers:278)
3. 认证缺失的 8 个端点加 `verify_auth`
4. 管理员密码哈希当 token 用
5. 生产代码 `.unwrap()` 替换为错误处理
