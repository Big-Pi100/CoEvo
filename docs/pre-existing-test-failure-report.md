# 预存测试失败调查报告

> 日期: 2026-07-04
> 范围: 14 个测试失败（均在 git stash 回退至原版后复现）

---

## 第一组: auth::tests — 5 个失败

### 错误
```
called `Result::unwrap()` on an `Err` value:
  "Insert error: table users has no column named referred_campaign_id"
```

### 失败测试
- `test_register_and_login`
- `test_register_duplicate_username`
- `test_login_wrong_password`
- `test_login_by_phone`
- `test_token_verification_with_db`

### 根因
auth.rs 有自己的 `setup_db()`（行 265），创建**最小化**的 `users` 表:

```rust
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    ...
    referred_by TEXT REFERENCES users(id),
    created_at TEXT NOT NULL
);
/* 没有 referred_campaign_id 列 */
```

但生产代码 `auth.rs:register()` 的 INSERT 使用 `referred_campaign_id` 列:

```sql
INSERT INTO users (...) VALUES (..., ?10, ?11)
-- ?10 = referred_campaign_id  ← 测试表里没有这列
```

### 设计意图
`referred_campaign_id` 是 `75ea857` 提交（重新梳理营销中的角色）新增的列，用于追踪用户注册来源的活动 ID（如"三人成团"）。auth 的测试 `setup_db()` 在列添加后未同步更新。

### 修复方案
在 auth.rs 的 `setup_db()` 的 `CREATE TABLE users` 中追加 `referred_campaign_id TEXT REFERENCES marketing_campaigns(id)` 列。

---

## 第二组: campaign_executor::tests — 7 个失败

### 错误模式 A — 期望 1 个 fulfillment 但得到 0
```
assertion failed: 应有 1 个 fulfillment
  left: 0
  right: 1
```

### 错误模式 B — 推荐人 subscription_expires 未被设置
```
thread panicked: 推荐人的 subscription_expires 应被设置
```

### 失败测试

| 测试 | 失败点 | root cause |
|:-----|:-------|:-----------|
| `test_execute_campaign_trigger_registration_subscription_days` | 期望 1 个 fulfillment | party=inviter, referrer=None → continue 跳过 |
| `test_execute_campaign_trigger_idempotent_skip` | 期望第 2 次调用 0 个 | 第 1 次调用已返回 0 |
| `test_execute_campaign_trigger_referrer_not_provided` | 期望 1 个 fulfillment | 同上 |
| `test_execute_campaign_trigger_with_referrer` | 推荐人 expires 未被设置 | party=self 奖励发给 user_id（触发者），不是 referrer |
| `test_execute_campaign_trigger_multiple_campaigns` | 期望 fulfillment 数量不对 | 同上 |
| `test_execute_campaign_trigger_unknown_reward_type` | 同上 | 同上 |
| `test_execute_campaign_trigger_commission_skipped_on_registration` | 同上 | 同上 |

### 根因
`75ea857` 提交（2026-07-02 23:49 "重新梳理营销中的角色"）更改了 party 语义:

| party | 修改前含义（测试期望） | 修改后含义（代码实现） |
|:------|:----------------------|:----------------------|
| `self` | 推广员/推荐人（上级） | 触发者本人（user_id） |
| `inviter` | —（新加）| 推荐人（referrer_id） |
| `invitee` | 被邀请人（下线） | 被邀请人（需有 referred_by） |
| `all` | 全员 | 活动 member（查 campaign_members） |

测试是在旧语义下编写的，新语义下：
- `party=self` → 奖励发给触发者 `user_id`，不是推荐人
- `party=inviter, referrer=None` → 无推荐人则跳过
- 幂等检查基于 `(campaign_id, user_id, trigger_event, party, reward_type)` → 两次 `party=self` 触发同 user 认为是重复

### 设计意图
新语义更准确：
- `self` = "本人"（触发事件的用户）
- `inviter` = "邀请人"（推荐关系中的上级）
- 当需要奖励推荐人时，应用配置 `party=inviter`
- `party=self` 的幂等保护：同用户同一活动只发一次同一类型

### 修复方案
同步更新 7 个测试的期望值：
- 无 referrer 时 `party=inviter` 返回 0 fulfillment
- `party=self` 时奖励发给 `user_id`（不是 referrer）
- `party=self` 两次同类型 → 1 个 fulfillment（幂等跳过第二次）

---

## 第三组: distribution_handler::tests — 2 个失败

### 错误
```
called `Result::unwrap()` on an `Err` value:
  SqliteFailure(Error { code: ConstraintViolation,
    extended_code: 787 },
    Some("FOREIGN KEY constraint failed"))
```

### 失败测试
- `test_mark_paid`
- `test_mark_paid_idempotent`

### 根因
`distribution_expenses` 表有外键约束:

```sql
CREATE TABLE distribution_expenses (
    ...
    earner_id TEXT NOT NULL,
    ...
    FOREIGN KEY (earner_id) REFERENCES users(id)
);
```

测试插入 `earner_id = 'earner-test'`，但 users 表中没有对应 ID 的用户。`db_pool.rs` 设置了 `PRAGMA foreign_keys = ON`，但测试使用 `Connection::open_in_memory()` + `init_database()`，正常情况下 SQLite 默认不强制外键。但当前运行时环境（或 rusqlite 版本）使外键约束生效。

### 设计意图
外键约束确保佣金发放记录始终指向真实用户，避免数据不一致。

### 修复方案
在测试中先插入对应 earner_id 的用户：

```rust
let earner_id = insert_test_user(&conn);  // 使用已有的辅助函数
// 然后用 earner_id 替代 'earner-test'
```

---

## 汇总

| 组 | 失败数 | 根因 | 修复难度 |
|:---|:------:|:-----|:--------:|
| auth | 5 | 测试 DB 缺少 referred_campaign_id 列 | 低（加一列） |
| campaign_executor | 7 | party 语义变更后测试未同步 | 中（改 7 个测试断言） |
| distribution_handler | 2 | 外键约束 + earner_id 不存在 | 低（用真实 user_id） |
| **合计** | **14** | | **已修复（76 pass, 0 fail）** |

---

## 修复结果

2026-07-04: 全部 14 个测试已修复，`cargo test -p api_server` 76 passed, 0 failed。
