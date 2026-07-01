# 资金结算流程 Bug 分析报告

## 前置：两张表，三个概念

### distribution_commissions — 佣金表
佣金是营销推广产生的**收益**。用户通过推广链接下单 → 系统记录一笔佣金。

| 字段 | 含义 |
|------|------|
| `id` | 佣金 ID |
| `earner_id` | 推广员 |
| `amount` | 佣金金额（分） |
| `status` | `locked`(锁定) → `available`(可用) |
| `level` | 1=直推, 2=间推 |

### distribution_expenses — 支出表
支出是平台的**实际资金流出**。有三个类型：

| expense_type | 含义 | 来源 |
|:---:|:---|:---|
| `settlement` | 结算支出 | 管理员批量打包佣金时生成 |
| `withdrawal` | 提现支出 | 推广员申请提现时生成 |
| `subscription` | 订阅返佣 | 用户购买套餐时生成 |

### 三条资金流

```
┌─ 佣金流 ───────────────────────────────────┐
│ 下单 → commission(lostatus'locked')            │
│      → unlock → commission(status='available')  │
│      → 管理员选佣金 → 创建批次                    │
│      → INSERT expense(expense_type='settlement') │
└────────────────────────────────────────────────┘

┌─ 提现流 ───────────────────────────────────┐
│ 申请 → expense(expense_type='withdrawal', pending)  │
│      → 管理员审核 → status='confirmed'              │
│      → 管理员选提现+佣金 → 创建批次                 │
│      → UPDATE expense.batch_no = xxx                │
└────────────────────────────────────────────────┘

┌─ 订阅返佣流 ────────────────────────────────┐
│ 购套餐 → expense(expense_type='subscription')       │
│      → 自动/手动确认                               │
└────────────────────────────────────────────────┘
```

## Bug 1：`pending_commissions` 查询条件断裂

**文件**: `distribution_handler.rs:309-334`

```rust
WHERE de.batch_no = ?1     // ← 要求传 batch_no
```
但执行时：
```rust
stmt.query_map([], |row| ...)   // ← 传空参数
```

`?1` 未绑定 → SQLite 视为 `NULL` → `WHERE batch_no = NULL` 永远为 false → **永远返回 0 条**。

这应该是早期设计"按批次查看待处理"的残留代码，后来改为全部展现但忘记改 SQL。

**修复目标**: 改成查所有待入批次的 expense，而非查某个批次的内容。

## Bug 2：提现审核直接分配 batch_no

**文件**: `distribution_handler.rs:1032-1033`

```rust
UPDATE distribution_expenses 
SET status = 'confirmed', handled_by = ?1, handled_at = ?2, 
    batch_no = ?3         // ← 不应该设 batch_no！
WHERE id = ?4 AND status = 'pending'
```

审核通过时给单笔提现分配了一个独立的 batch_no。后果：
- 这笔提现有了 batch_no → `pending_commissions` 查不到它（即使修复 Bug 1）
- 生成了一个单人单笔的孤立批次 → 浪费时间手工操作

**修复目标**: 审核只改 `status='confirmed'`，不留 `batch_no`。等管理员统一创建批次时再分配。

## Bug 3：`create_batch` 只处理佣金，不接受提现

**文件**: `distribution_handler.rs:339-341`

```rust
pub struct CreateBatchRequest {
    pub commission_ids: Vec<String>,   // ← 只接受佣金 ID
}
```

`create_batch` 只从 `distribution_commissions` INSERT 新 expense 记录。已审核的提现（已在 `distribution_expenses` 中）无法被纳入批次。

**修复目标**: 增加 `expense_ids` 字段，把选中已审核的提现 UPDATE 到同一批次。

## 修复方案

### 1. 提现审核（改最少的方案）

```diff
- UPDATE ... SET status = 'confirmed', batch_no = ?3 WHERE id = ?4
+ UPDATE ... SET status = 'confirmed' WHERE id = ?4
```

保留 `handled_by`、`handled_at` 正常写入。

### 2. `pending_commissions` 查询

```diff
- WHERE de.batch_no = ?1
+ WHERE de.batch_no IS NULL 
+   AND de.batch_no != ''
+   AND de.status IN ('confirmed')
+   AND de.expense_type IN ('withdrawal', 'subscription')
```

只查已确认但未入批次的支出（提现、订阅返佣）。

### 3. `CreateBatchRequest` + `create_batch` 逻辑

```rust
pub struct CreateBatchRequest {
    pub commission_ids: Vec<String>,  // 佣金 ID → INSERT
    pub expense_ids: Vec<String>,     // 提现/返佣 expense ID → UPDATE batch_no
}
```

在事务中：
- 1️⃣ 按原有逻辑 INSERT 选中的佣金 → 新 expense（expense_type='settlement'）
- 2️⃣ UPDATE 选中的 expense：`SET batch_no = ?1 WHERE id IN (...)`  
- 3️⃣ 事务提交

### 影响范围

| 改动 | 涉及文件 |
|:-----|:--------|
| 修改提现审核 handler | `distribution_handler.rs` ~1032 |
| 修改 `pending_commissions` | `distribution_handler.rs` ~314 |
| 修改 `CreateBatchRequest` | `distribution_handler.rs` ~339 |
| 修改 `create_batch` | `distribution_handler.rs` ~380-393 |
| 前端发送 `expense_ids` | `admin_commission_list.dart` ~130 |
