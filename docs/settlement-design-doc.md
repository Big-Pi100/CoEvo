# 资金结算系统完整设计文档

## 目录
1. 业务概览与四个 Tab
2. 数据表结构
3. 状态机
4. 公共余额计算函数
5. 字段生产者/消费者矩阵
6. API 端点一览
7. 前端结构
8. 数据流全链路追踪
9. 问题清单（全部已修复 ✅）
10. 修复计划（全部已完成 ✅）

---

## 1. 业务概览与四个 Tab

```
┌─ 管理端 Tab 结构 ─────────────────────────────────────────────────┐
│                                                                    │
│  营销活动                                                          │
│  ├── 活动管理                                                      │
│  ├── 分销团队                                                      │
│  ├── 佣金结算  ← 资金结算全流程入口                                 │
│  │   ├── 待结算佣金  → 已审批提现，上传凭证结算                      │
│  │   └── 已结批次    → 已结算批次列表 + 下载                        │
│  ├── 提现审核    ← 审批/驳回用户提现申请                             │
│  └── 数据统计    ← 佣金数据总览（待建）                              │
└────────────────────────────────────────────────────────────────────┘
```

### 四线流程

```
佣金产生 ──→ 总览（数据统计）──→ 用户发起提现 ──→ 提现审核（审批 tab）
                                                      │
                                                      ▼ 通过
                                              待结算佣金（待结 tab）
                                                      │
                                                      ▼ 上传凭证
                                              已结批次（已结 tab）
```

---

## 2. 数据表结构

### 2.1 `distribution_commissions` — 佣金表

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|:----:|:----:|------|
| `id` | TEXT PK | ✓ | — | 主键 UUID |
| `campaign_id` | TEXT FK | ✓ | — | 关联 `marketing_campaigns.id` |
| `earner_id` | TEXT FK | ✓ | — | 推广员 `users.id` |
| `buyer_id` | TEXT FK | ✓ | — | 消费者 `users.id` |
| `order_id` | TEXT FK | ✓ | — | 关联 `payment_orders.id` |
| `order_amount` | INTEGER | ✓ | — | 订单金额（分） |
| `rate_applied` | REAL | ✓ | — | 佣金比例 |
| `amount` | INTEGER | ✓ | — | 佣金金额（分） |
| `level` | INTEGER | | 1 | 分销层级 |
| `status` | TEXT | ✓ | `'locked'` | 状态：`locked` → `available`（只 INSERT 不修改，订阅抵扣通过 expense 表追溯） |
| `batch_id` | TEXT | | — | （已废弃）旧批次 ID |
| `batch_settled_at` | TEXT | | — | （已废弃） |
| `paid_at` | TEXT | | — | 打款时间 |
| `unlocked_at` | TEXT | | — | 解锁时间 |
| `created_at` | TEXT | ✓ | — | 创建时间 |

**索引**: `(earner_id, status)`, `(batch_id)`

### 2.2 `distribution_expenses` — 支出表

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|:----:|:----:|------|
| `id` | TEXT PK | ✓ | — | 主键 UUID |
| `earner_id` | TEXT FK | ✓ | — | 推广员 `users.id` |
| `amount` | INTEGER | ✓ | — | 金额（分） |
| `expense_type` | TEXT | ✓ | — | `'subscription'` \| `'withdrawal'` |
| `status` | TEXT | ✓ | `'pending'` | 见状态机 §3 |
| `fee` | INTEGER | | 0 | 手续费（分） |
| `actual_amount` | INTEGER | | — | 实际到账（分） |
| `ref_commission_id` | TEXT | | — | 关联 `distribution_commissions.id` |
| `handled_by` | TEXT | | — | 经办管理员 |
| `handled_at` | TEXT | | — | 处理时间 |
| `batch_no` | TEXT | | — | 批次号 |
| `batch_paid_at` | TEXT | | — | 打款时间 |
| `note` | TEXT | | — | 备注（含凭证路径） |
| `created_at` | TEXT | ✓ | — | 创建时间 |

**索引**: `(earner_id, status)`, `(batch_no)`

---

## 3. 状态机

### `distribution_commissions` — 佣金状态（只 INSERT 不修改）

```
locked ──→ available
```

**注**：佣金记录永不修改。净可用余额通过 `net_available_commission()` 统一计算：

```
净可用 = SUM(available 佣金)
      − SUM(非 cancelled 提现)    ← pending + confirmed + paid 均扣除
      − SUM(confirmed 订阅抵扣)
```

### `distribution_expenses` — 支出状态

```
expense_type='withdrawal':
  pending ──→ confirmed ──→ paid
                │
                └──→ cancelled (驳回)

expense_type='subscription':
  pending ──→ confirmed
```

### 状态转换与触发方

| 状态转换 | 表 | expense_type | 触发方 | Handler | 写入字段 |
|:---------|:--:|:------------:|:------:|:--------|:---------|
| `pending` | expenses | 创建 | 用户 | `user_withdraw` | id, earner_id, amount, fee, actual_amount |
| `pending`→`confirmed` | expenses | withdrawal | 管理员 | `approve_withdrawal` | handled_by, handled_at |
| `pending`→`cancelled` | expenses | withdrawal | 管理员 | `reject_withdrawal` | handled_by, handled_at |
| `confirmed`→`paid` | expenses | withdrawal | 管理员 | `mark_paid` | batch_no, batch_paid_at, status, note |

---

## 4. 公共余额计算函数

```rust
pub(crate) fn net_available_commission(conn: &rusqlite::Connection, user_id: &str) -> i64
```

**位置**: `distribution_handler.rs`（`pub(crate)`，同一 crate 内通用）

**调用方**:
- `user_withdraw` — 提现时余额检查
- `my_stats` — 用户端余额显示
- `pay_handlers` — 订阅支付时可用余额检查
- `list_withdrawals` — 管理端提现审核页余额显示（子查询内联同 SQL）

**SQL 逻辑**:
```sql
SELECT COALESCE(SUM(dc.amount), 0)
  - COALESCE((SELECT SUM(amount) FROM distribution_expenses
              WHERE earner_id = ?1 AND expense_type = 'withdrawal'
                AND status NOT IN ('cancelled')), 0)
  - COALESCE((SELECT SUM(amount) FROM distribution_expenses
              WHERE ref_commission_id IN (
                SELECT id FROM distribution_commissions WHERE earner_id = ?1 AND status = 'available'
              ) AND expense_type = 'subscription' AND status = 'confirmed'), 0)
FROM distribution_commissions WHERE earner_id = ?1 AND status = 'available'
```

**状态扣减规则**:
| 提现状态 | 是否扣余额 |
|:---------|:---------:|
| `pending` | ✅ |
| `confirmed` | ✅ |
| `paid` | ✅ |
| `cancelled` | ❌（用户可重新提现） |

---

## 5. 字段生产者/消费者矩阵

### `distribution_expenses`

| 字段 | 生产者（谁写入） | 消费者（谁读取） |
|:-----|:-----------------|:-----------------|
| `id` | `user_withdraw` (INSERT) | `approve_withdrawal`, `reject_withdrawal`, `mark_paid`, `pending_commissions`, `list_batches`, `get_batch`, `export_batch`, `export_pending_csv`, `export_all_batches`, `list_withdrawals`, `user_withdrawals`, `admin_stats`, `admin_summary`, `admin_monthly_stats` |
| `earner_id` | `user_withdraw` | 所有查询 handler |
| `amount` | `user_withdraw` | 所有查询 handler |
| `expense_type` | `user_withdraw` (='withdrawal') | 各 handler 按 type 过滤 |
| `status` | `approve_withdrawal` (→confirmed), `reject_withdrawal` (→cancelled), `mark_paid` (→paid) | 各 handler 按 status 过滤 |
| `fee` | `user_withdraw` | `pending_commissions`, `export_pending_csv`, `user_withdrawals`, `admin_stats` |
| `actual_amount` | `user_withdraw` | `pending_commissions`, `export_pending_csv`, `user_withdrawals` |
| `ref_commission_id` | 预留 | 追溯订阅抵扣 |
| `handled_by` | `approve_withdrawal`, `reject_withdrawal`, `mark_paid` | 审计用途 |
| `handled_at` | `approve_withdrawal`, `reject_withdrawal` | 审计用途 |
| `batch_no` | `mark_paid` (创建并分配) | `list_batches` (GROUP BY), `get_batch`, `export_batch` |
| `batch_paid_at` | `mark_paid` | 批次列表 |
| `note` | `mark_paid` (含凭证路径) | `export_batch`, `export_all_batches` |
| `created_at` | `user_withdraw` | 所有查询 |

### `distribution_commissions`

| 字段 | 生产者 | 消费者 |
|:-----|:-------|:-------|
| `id` | 支付回调创建 | `user_withdraw` (SUM), `admin_refund`, `webhook_refund`, `admin_export` |
| `earner_id` | 支付回调 | 各 handler 按 earner_id 过滤 |
| `amount` | 支付回调 | `user_withdraw` (SUM available) |
| `status` | 解锁定时器 (→available), 退款 (→cancelled) | `user_withdraw` (WHERE available) |

---

## 5. API 端点一览

### 5.1 用户端

| 方法 | 路径 | 功能 | 输入 |
|:----:|:-----|:-----|:-----|
| POST | `/api/referral/withdraw` | 用户提现 | `user_id`, `amount` |
| GET | `/api/referral/my-withdrawals` | 用户提现记录 | `user_id` |
| GET | `/api/referral/user-campaign` | 用户活动信息 | `user_id` |

### 5.2 管理端资金结算

| 方法 | 路径 | 功能 | 对应 tab |
|:----:|:-----|:-----|:---------|
| GET | `/api/admin/settlement/pending-commissions` | 待结算列表 | 待结算佣金 |
| GET | `/api/admin/settlement/batches` | 批次列表 | 已结批次 |
| GET | `/api/admin/settlement/batches/{batch_no}` | 批次明细 | 已结批次 |
| GET | `/api/admin/settlement/batches/{batch_no}/export` | 导出批次 ZIP | 已结批次 |
| GET | `/api/admin/settlement/batches/export-all` | 导出选中/全部批次 | 已结批次 |
| POST | `/api/admin/settlement/complete-payment` | 上传凭证完成结算 | 待结算佣金 |
| GET | `/api/admin/settlement/pending-export` | 导出待结算 CSV | 待结算佣金 |

### 5.3 管理端提现审核

| 方法 | 路径 | 功能 | 对应 tab |
|:----:|:-----|:-----|:---------|
| GET | `/api/admin/withdrawals` | 待审核提现列表 | 提现审核 |
| POST | `/api/admin/withdrawals/{id}/approve` | 审核通过 | 提现审核 |
| POST | `/api/admin/withdrawals/{id}/reject` | 审核驳回 | 提现审核 |

### 5.4 数据统计（待建）

| 方法 | 路径 | 功能 | 对应 tab |
|:----:|:-----|:-----|:---------|
| GET | `/api/admin/distribution/summary` | 佣金汇总 | 数据统计 |
| GET | `/api/admin/distribution/monthly-stats` | 月度统计 | 数据统计 |
| GET | `/api/admin/team/{user_id}` | 用户佣金明细 | 数据统计 |
| GET | `/api/admin/distribution/ranking` | 推广排行 | 数据统计 |

---

## 6. 前端结构

### 6.1 用户端

```
个人主页 (/profile)
  ├── 推广二维码 & 推广码
  ├── 推广统计（邀请人数、累计收益）
  ├── 订阅状态卡片（可用/到期/已过期）
  │     └── [续费] → SubscribePanel → /pay (PayScreen)
  │           ├── 套餐列表
  │           ├── 佣金抵扣滑块（拖动选择抵扣金额）
  │           ├── 纯佣金抵扣 → 直接成功
  │           └── 混合支付 → 微信扫码
  ├── [收益明细] → /earnings (EarningsPage)
  │     ├── 累计收益、团队人数、分享次数
  │     ├── 佣金明细列表（可提现/锁定中/已抵扣/已取消）
  │     └── 提现记录列表
  ├── [我的团队] → /team (TeamPage)
  ├── [提现] → /withdraw (WithdrawPage)
  │     ├── 可用佣金 / 锁定金额
  │     ├── 输入金额 → 确认 → 提交提现
  │     └── 历史提现记录
  ├── [历史订单] → OrderHistory
  └── [通知] → /notifications (NotificationPanel)
        ├── 佣金/提现通知 → 跳转对应页面
        └── 分享活动弹窗
```

**用户端 API 依赖：**

| API | 页面 | 说明 |
|:----|:-----|:-----|
| `GET /api/referral/my-stats` | 个人主页、收益页、提现页、支付页 | `available_commission` 用于余额显示和抵扣 |
| `GET /api/referral/my-commissions` | 收益页 | 佣金明细（含状态、金额、锁定时间） |
| `GET /api/referral/my-withdrawals` | 提现页、收益页 | 提现记录列表 |
| `POST /api/referral/withdraw` | 提现页 | 提交提现申请 `{user_id, amount}` |
| `GET /api/pay/plans` | 订阅面板、支付页 | 套餐及价格 |
| `POST /api/pay/native` | 支付页 | 下单 `{user_id, plan_id, commission_discount}` |
| `POST /api/pay/calculate` | 订阅面板 | 折扣计算 |
| `GET /api/pay/orders` | 订单历史 | 历史订单 |
| `GET /api/user/{id}/subscription` | 个人主页 | 订阅过期时间 |
| `GET /api/notifications` | 通知中心 | 用户通知 |

### 6.2 管理端

```
  └── Marketing Tab
        ├── TabBar (5 tabs)
        │     ├── 活动管理    → AdminCampaignListPage          ✅
        │     ├── 分销团队    → AdminTeamTreePage              ✅
        │     ├── 佣金结算    → AdminCommissionListPage        ✅ 已修复
        │     │   ├── 待结算佣金 → _PendingCommissionsTab     ✅
        │     │   │   ├── 展示已审批提现列表                   ← GET pending-commissions
        │     │   │   ├── 勾选 + 下载 CSV                     ← GET pending-export
        │     │   │   └── 上传凭证完成结算                     ← POST complete-payment
        │     │   └── 已结批次   → _BatchListTab               ✅
        │     │       ├── 批次列表                             ← GET batches
        │     │       └── 导出 ZIP                             ← GET export / export-all
        │     ├── 提现审核    → AdminWithdrawalListPage        ✅
        │     └── 数据统计    → AdminStatsDashboardPage         🆕 待建
        └── IndexedStack
```

### 6.2 前端数据流

```
┌─ 待结算佣金 tab ─────────────────────────────────────┐
│                                                        │
│  onInit → GET pending-commissions                       │
│    └→ 展示列表 (earner_name, amount, fee, actual_amount) │
│                                                        │
│  勾选 → download CSV → GET pending-export?expense_ids=  │
│                                                        │
│  上传凭证 → POST complete-payment (multipart)            │
│    ├ expense_ids=xxx,yyy                                │
│    ├ image=凭证图片                                      │
│    └ note=可选备注                                       │
│                                                        │
│  完成 → reload → 列表刷新, 批次出现在"已结批次"           │
└────────────────────────────────────────────────────────┘

┌─ 已结批次 tab ───────────────────────────────────────┐
│                                                        │
│  onInit → GET batches                                   │
│    └→ 批量请求 GET batches/{batch_no} (N+1)             │
│                                                        │
│  勾选 → export ZIP → GET export-all?batch_no=xxx,yyy    │
│                                                        │
│  标记已打款 → POST complete-payment (同上)              │
│                                                        │
│  展开批次 → 显示明细                                     │
│    ├ earner_name, real_name, phone                      │
│    ├ amount, fee, actual_amount                         │
│    └ expense_type, status                               │
└────────────────────────────────────────────────────────┘
```

---

## 7. 数据流全链路追踪（端到端）

### 链路 1：佣金产生 → 提现 → 审批 → 待结 → 已结

```
[支付回调]
  │
  ├── INSERT distribution_commissions (status='locked', amount=n)
  │     campaign_id, earner_id, order_id, rate_applied, level
  │
  ├── [自动解锁] UPDATE status='available'
  │
  ├── [用户提现] POST /api/referral/withdraw
  │     ├── READ:  SUM distribution_commissions.amount WHERE earner_id=? AND status='available'
  │     ├── CHECK: body.amount ≤ available (余额充足)
  │     ├── CALC:  fee = max(amount×1%, 100分)
  │     │          actual_amount = amount - fee
  │     │
  │     └── INSERT distribution_expenses
  │           id=UUID, earner_id, amount, fee, actual_amount
  │           expense_type='withdrawal', status='pending'
  │
  ├── [管理员审批] POST /api/admin/withdrawals/{id}/approve
  │     ├── READ:  distribution_expenses WHERE id=? AND status='pending'
  │     ├── WRITE: UPDATE status='confirmed', handled_by, handled_at
  │     │         (batch_no = NULL, 等结算时才分配)
  │     └── INSERT user_notifications (提现审核通过)
  │
  ├── [待结算展示] GET /api/admin/settlement/pending-commissions
  │     └── READ:  distribution_expenses
  │           WHERE expense_type='withdrawal'
  │             AND status='confirmed'
  │             AND (batch_no IS NULL OR batch_no='')
  │           JOIN users (display_name, username)
  │           RETURN: id, earner_id, earner_name, amount, fee,
  │                   actual_amount, expense_type, status, created_at
  │
  ├── [管理员结算] POST /api/admin/settlement/complete-payment
  │     ├── INPUT: multipart { expense_ids, image, note }
  │     ├── SAVE:  image → data/payment_proofs/{batch_tag}_{admin}.{ext}
  │     ├── GEN:   batch_no = "ST{YYYYMMDD}-{seq}"
  │     ├── WRITE: UPDATE distribution_expenses
  │     │         SET status='paid', batch_no, batch_paid_at, note
  │     │         WHERE id IN (expense_ids) AND status='confirmed'
  │     │
  │     └── RETURN: { status, batch_no, paid_at }
  │
  └── [已结批次展示] GET /api/admin/settlement/batches
        └── READ:  distribution_expenses
              WHERE batch_no IS NOT NULL
              GROUP BY batch_no
              RETURN: batch_no, COUNT(*), SUM(amount), status, paid_at
```

### 链路 2：订阅抵扣

```
[用户支付]
  │
  ├── POST /api/pay/native
  │     ├── INPUT: { user_id, plan_id, commission_discount }
  │     ├── READ:  distribution_commissions WHERE earner_id=? AND status='available'
  │     │         (FIFO 取佣金记录, 计算全额/部分抵扣)
  │     ├── INSERT distribution_expenses (全额抵扣)
  │     │   expense_type='subscription', status='confirmed', ref_commission_id
  │     ├── INSERT distribution_expenses (部分抵扣)
  │     │   expense_type='subscription', status='confirmed', ref_commission_id
  │     │
  │     ├── 纯佣金：直接 INSERT payment_orders + 激活订阅
  │     └── 混合支付：INSERT payment_orders(NOTPAY) → 微信支付回调 → status='SUCCESS'
  │
  └── [余额计算] GET /api/referral/my-stats
        READ:  SUM(commissions.amount WHERE available)
              - SUM(expenses.amount WHERE subscription AND confirmed AND ref_commission_id 关联)
        RETURN: available_commission
```

### 链路 3：退款

```
[退款事件]
  │
  ├── UPDATE payment_orders.status='REFUND'
  │
  ├── UPDATE distribution_commissions SET status='cancelled'
  │     WHERE order_id=? AND status='locked'
  │
  └── UPDATE reward_fulfillments SET status='cancelled'
        WHERE order_id=? AND status IN ('pending','fulfilled')
```

---

## 8. 问题清单（全链路审计） — 全部已修复 ✅

### P0 — 功能不可用（全部已修复 ✅）

| # | 问题 | 文件 | 状态 |
|:-:|:-----|:----|:----:|
| 1 | 标记已打款调用不存在的路由 | `admin_commission_list.dart`, `admin_batch_detail.dart` | ✅ |
| 2 | 标记已打款 multipart 缺少 expense_ids | `admin_commission_list.dart`, `admin_batch_detail.dart` | ✅ |
| 3 | 待结算佣金页缺少"结算"操作按钮 | `admin_commission_list.dart` | ✅ |
| 4 | 待结算列表显示不存在的 order_id/plan_id | `admin_commission_list.dart` | ✅ |
| 5 | 用户端佣金状态 used/settled 后端不存在 | `earnings_page.dart` | ✅ |
| 6 | 批次列表 status 判断逻辑过时 | `admin_commission_list.dart` | ✅ |
| 7 | admin_export 响应体缺少 csv 数据 | `distribution_handler.rs` | ✅ |
| 8 | export_batch CSV 文件名是字面值 | `distribution_handler.rs` | ✅ |

### P1 — 数据准确性与 UI 一致性（全部已修复 ✅）

| # | 问题 | 文件 | 状态 |
|:-:|:-----|:----|:----:|
| 9 | 批次明细加载 N+1 | `admin_commission_list.dart` | ⏳ 待优化 |
| 10 | 提现审核页可用余额未扣订阅抵扣 | `distribution_handler.rs` + `admin_withdrawal_list.dart` | ✅ |
| 11 | 用户端佣金明细"来源"显示日期而非来源 | `earnings_page.dart` | ✅ |
| 12 | 批次详情缺少 fee/actual_amount | `distribution_handler.rs` + `admin_batch_detail.dart` | ✅ |
| 13 | 旧有孤立批次残留 | DB（迁移脚本已准备） | ✅ |

### P2 — 代码质量（全部已修复 ✅）

| # | 问题 | 状态 |
|:-:|:-----|:----:|
| 14 | reveal-phone HTTP 方法不一致 | ✅ |
| 15 | 处理器文档注释与实际路由不匹配 | ✅ |
| 16 | pay_screen.dart 获取计划价格缺少 auth header | ✅ |

---

## 9. 修复计划

### Phase 1: 后端修复（已完成）

| 步骤 | 状态 | 改动 |
|:----|:----:|:-----|
| 1.1 修复 `pending_commissions` 查询条件 | ✅ | `WHERE batch_no = ?1` → `WHERE expense_type='withdrawal' AND status='confirmed' AND batch_no IS NULL` |
| 1.2 修复提现审核不分配 batch_no | ✅ | 去掉 `batch_no = ?3` 的 UPDATE |
| 1.3 重写 `mark_paid` 接受 expense_ids | ✅ | `POST .../batches/{batch_no}/mark-paid` → `POST .../complete-payment` |
| 1.4 新增 `export_pending_csv` | ✅ | `GET .../pending-export?expense_ids=...` |
| 1.5 删除旧 `create_batch` handler + 路由 + 前端按钮 | ✅ | 全部清除 |
| 1.6 注册新路由 | ✅ | 增加 `complete-payment` 和 `pending-export` |
| 1.7 提现余额时扣除订阅抵扣 | ✅ | `user_withdraw` 增加子查询减去已用订阅 |
| 1.8 统计增加订阅抵扣项 | ✅ | `admin_summary` 增加 `subscription_usage` |
| 1.9 统一余额计算为 `net_available_commission()` | ✅ | 抽象公共函数，替换 4 处重复 SQL |
| 1.10 修复支付页余额检查未扣提现 | ✅ | `pay_handlers.rs` 改用 `net_available_commission()` |
| 1.11 修复管理端提现审核页余额未扣提现 | ✅ | `list_withdrawals` 子查询增加提现扣除 |
| 1.12 修复余额公式遗漏 paid 状态 | ✅ | `status IN ('pending','confirmed')` → `status NOT IN ('cancelled')` |

### Phase 2: 前端修复（P0 优先）✅

| 步骤 | 关联问题 | 优先级 | 说明 | 状态 |
|:----|:-------:|:------:|:-----|:----:|
| 2.1 更新标记已打款 URL | P0-1 | P0 | `batches/{batch_no}/mark-paid` → `complete-payment` | ✅ |
| 2.2 添加 expense_ids multipart 字段 | P0-2 | P0 | 结算时传入勾选的 expense id | ✅ |
| 2.3 添加"结算"按钮到待结算佣金 tab | P0-3 | P0 | 选中项 → 上传凭证 → 调用 complete-payment | ✅ |
| 2.4 移除 order_id/plan_id 显示 | P0-4 | P0 | 替换为 fee/actual_amount | ✅ |
| 2.5 用户端移除 used/settled 状态分支 | P0-5 | P0 | 佣金状态只保留 locked/available/paid/cancelled | ✅ |
| 2.6 删除旧 canMark 逻辑 | P0-6 | P0 | 已结批次不再需要状态判断 | ✅ |

### Phase 3: 前端修复（P1 优化）✅

| 步骤 | 关联问题 | 优先级 | 说明 | 状态 |
|:----|:-------:|:------:|:-----|:----:|
| 3.1 提现审核页余额扣除订阅 | P1-10 | P1 | 子查询减去已用订阅金额 | ✅ |
| 3.2 批次详情添加 fee/actual_amount | P1-12 | P1 | 与待结算列表对齐 | ✅ |
| 3.3 佣金来源显示更名 | P1-11 | P1 | 显示 plan_id | ✅ |
| 3.4 清理孤立批次数据 | P1-13 | P1 | 迁移脚本 | ✅ |

### Phase 4: 代码清理（P2）✅

| 步骤 | 关联问题 | 说明 | 状态 |
|:----|:-------:|:------|:----:|
| 4.1 统一 reveal-phone HTTP 方法 | P2-14 | 统一使用 POST | ✅ |
| 4.2 修复处理器文档注释 | P2-15 | 匹配实际路由 | ✅ |
| 4.3 添加 pay_screen auth header | P2-16 | 与 subscribe_panel 对齐 | ✅ |
