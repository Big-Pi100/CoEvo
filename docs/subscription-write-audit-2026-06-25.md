# Subscription Expires 写入审计 — 2026-06-25

## 概述

审计 `subscription_expires` 列的全部写入操作，检查是否统一采用**增量累加**（增加天数）而非**覆盖**（直接设值）模式。

涉及文件：`backend/crates/api_server/src/` + `app/lib/screens/admin_screen.dart`

---

## 写入点清单

### ✅ 安全的增量操作

| 位置 | 行号 | SQL | 逻辑 |
|:-----|:-----|:-----|:-----|
| `subscription.rs:extend_subscription` | 218 | `UPDATE SET=?1` (via `set_expires`) | `max(原值, 今天) + N天` |
| `campaign_executor.rs:handle_subscription_days` | 289 | `UPDATE SET=?1` (via `set_expires`) | `max(原值, 今天) + N天` |
| `admin_handlers.rs:review_subscription` | 531 | `UPDATE SET=?1` | `原值 + N天` (NaiveDate) ✅ |
| `trial_handler.rs` | 74 | INSERT | 新行 `now+5min` |

### ❌ 有问题的覆盖操作

| 位置 | 行号 | 问题 | 风险等级 |
|:-----|:-----|:-----|:---------|
| `routes.rs:preferences_put_handler` | 2083 | **P0 安全漏洞**：任意认证用户可自设过期时间 | 🔴 |
| `admin_handlers.rs:admin_batch_subscription` | 472-473 | **P1 格式崩溃**：用 `parse_from_rfc3339` 解析 `YYYY-MM-DD` | ⚠️ |
| `admin_handlers.rs:admin_set_subscription` | 404 | **P1 覆盖风险**：客户端直接设值，无格式校验 | ⚠️ |
| `admin_handlers.rs:admin_quick_extend` | 429,446 | **P1 覆盖风险**：同上 | ⚠️ |
| `admin_screen.dart:_quickExtend` | 329-332 | **P2 前端计算**：前端用 `DateTime.tryParse` 算到期日，后端不做校验 | ℹ️ |

---

## P0 安全漏洞详情

### `routes.rs:2083` — 用户可自设过期时间

```rust
// 任何有 token 的用户通过 PUT /api/user/{id}/preferences 可自设 subscription_expires
if key == "subscription_expires" {
    let _ = conn.execute(
        "UPDATE users SET subscription_expires = ?1 WHERE id = ?2", ...
    );
}
```

**影响**：持有真实用户 token 的攻击者可自设 `subscription_expires=2099-01-01` 白嫖订阅。
**修复方案**：在 `preferences_put_handler` 中拒绝 `subscription_expires` 键的写入，或要求管理员权限。

---

## P1 格式崩溃详情

### `admin_handlers.rs:472` — rfc3339 解析 YYYY-MM-DD

```rust
// ❌ YYYY-MM-DD 不是有效 RFC 3339，unwrap() 将 panic
chrono::DateTime::parse_from_rfc3339(&current).unwrap()
// ✅ 应该用：
chrono::NaiveDate::parse_from_str(&current, "%Y-%m-%d")
```

**影响**：`admin_batch_subscription` 对已有到期日的用户调用时会 panic。`review_subscription`（同文件 527 行）已正确使用 `NaiveDate`。

---

## P1 覆盖风险详情

### `admin_handlers.rs:404, 429, 446` — 管理员直接设值

三个端点接收客户端提供的 `subscription_expires` 字符串，直接 `UPDATE SET`，不做格式校验、不做增量累加、不验证新值是否晚于原值。

**`admin_set_subscription` (404)** 与 **`admin_quick_extend` (429/446)** 的行为不一致：
- `set_subscription` 对无权限的 `service` 返回 403
- `quick_extend` 对无权限的 `service` 优雅降级为创建待审批请求

### `admin_screen.dart:329-332` 前端日期计算

```dart
final base = (currentExpiry != null && currentExpiry.isNotEmpty)
    ? (DateTime.tryParse(currentExpiry) ?? now)
    : now;
```

前端先算好到期日再传给后端，后端直接 `UPDATE SET`。如果前端算错或中途篡改，后端无校验。应改为后端统一做日期运算。

---

## 权限矩阵

| 函数 | super | service (有权限) | service (无权限) |
|------|-------|-----------------|-----------------|
| `admin_set_subscription` | 直接写入 | 直接写入（需 `set_expiry`） | **403** ❌ |
| `admin_quick_extend` | 直接写入 | 直接写入（需 `extend_7d`/`30d`/`365d`） | 创建待审批请求 ✅ |
| `admin_batch_subscription` | 直接写入 | 403 | 403 |
| `admin_approve_request` | 审批 | 审批（需 `can_approve`） | 403 |
| `admin_create_subscription_request` | 创建请求 | 创建请求 | 创建请求 |

`admin_set_subscription` 的 403 行为与 `admin_quick_extend` 不一致，应该统一为降级创建待审批请求。

---

## 其他发现

| 问题 | 文件 | 详情 |
|:-----|:-----|:------|
| 无用户存在性检查 | `admin_create_subscription_request` | `target_user_id` 可指向不存在用户 |
| `days` 字段未使用 | `admin_set_subscription` | 结构体中定义了但函数内忽略 |
| 审计日志 action 不统一 | `admin_handlers.rs` | `set_subscription` / `quick_extend` / `batch_set_subscription` / `approved_subscription` |
| `DateTime.tryParse` 静默回退 | `admin_screen.dart:331` | 如果 `currentExpiry` 格式异常，悄悄用 `now` 代替 |

---

## 总结

| 类型 | 数量 | 说明 |
|:-----|:-----|:------|
| 🔴 P0 安全漏洞 | 1 | `preferences_put_handler` 无权限检查 |
| ⚠️ P1 格式崩溃 | 1 | `batch_subscription` 用 rfc3339 解析 date-only |
| ⚠️ P1 覆盖风险 | 3 | 管理员直接设值无校验 |
| ℹ️ P2 前端计算 | 1 | 到期日在前端算而非后端统一算 |

核心问题：所有覆盖写入都应改为 `extend_subscription`（增量累加）或增加格式校验 + 新值晚于原值验证。

