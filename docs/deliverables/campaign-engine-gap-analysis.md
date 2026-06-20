# 营销活动引擎 — 能力缺口与实施计划

> 版本: v1.0 · 2026-06-19
> 基于完整代码审计

---

## 当前能力矩阵

| 维度 | 已就绪 | 缺口（P0） | 缺口（P1） | 缺口（P2） |
|------|--------|-----------|-----------|-----------|
| 活动配置 CRUD | ✅ 完整 | — | — | — |
| 支付触发执行 | ✅ `pay_handlers.rs:300-408` | — | — | — |
| 注册触发执行 | ❌ | **无引擎触发 registration** | — | — |
| 其他触发(click/review) | ❌ | **无通用执行器** | — | — |
| subscription_days 奖励 | ❌ | **执行器不识别此类型** | — | — |
| commission_pct/fix 奖励 | ✅ 支付回调中实现 | — | — | — |
| discount_pct/fix 奖励 | ✅ calculate API 有 | — | — | — |
| 用户端活动可见性 | ❌ | — | **用户看不到活动+奖励** | — |
| 主动分享触发 | ❌ | — | **学习完成不会自动弹海报** | — |
| 实时通知 | ❌ | — | **无 WebSocket/轮询推送** | — |
| A/B 测试 | ❌ | — | — | **无实验框架** |
| 活动预算上限 | ❌ | — | — | **无 budget_cap/daily_cap** |
| ROI 分析 | ❌ | — | — | **无法按活动追踪 LTV** |
| 多级裂变(>2级) | ❌ | — | — | **level 字段未用到 2+** |

---

## P0 实施计划 — 让活动能跑

### P0.1 活动执行引擎

**文件**: `backend/crates/api_server/src/campaign_executor.rs`（新建）

```
execute_campaign_trigger(conn, trigger_event, user_id, referrer_id, order_id)
  → 查 marketing_campaigns WHERE status='active' AND trigger_event=?
  → 解析 rewards JSON
  → 幂等检查（按 campaign + user + trigger + party 去重）
  → 分发：
       subscription_days → extend_subscription()
       commission_pct/fix → 写 distribution_commissions
  → 写 reward_fulfillments
```

### P0.2 插入触发点

| 触发点 | 文件 | 插入位置 |
|--------|------|---------|
| `registration` | `auth.rs:register()` | 用户创建成功后、返回前 |
| `payment` | `pay_handlers.rs` | 改用 execute_campaign_trigger，消灭重复代码 |
| `click` | `referral_handler.rs:click` | 点击追踪时触发（可选） |

### P0.3 幂等保护

按 `(campaign_id, user_id, trigger_event, party, reward_type)` 查 `reward_fulfillments`，已发放的跳过。

---

## P1 实施计划 — 让活动体验好

### P1.1 用户端显示奖励

完成复习/注册/分享后，前端通过 `/api/notifications` 展示：
- "你通过每天进化1%活动获得了3天会员！"
- 通知类型 `reward`，带 `action_url` 跳转到活动/会员页

### P1.2 学习完成后自动弹分享海报

复习完成 → 查是否有 active campaign 且 `push_trigger='after_complete_review'` → 是则弹出分享弹窗（复用 `share_widget.dart`）

### P1.3 通知实时性

短期：前端每30秒轮询 `/api/notifications?unread_only=true`  
长期：切换 WebSocket

---

## 文件变更清单

| 文件 | 操作 | 估计行数 |
|------|------|---------|
| `backend/crates/api_server/src/campaign_executor.rs` | 新建 | ~100 |
| `backend/crates/api_server/src/auth.rs` | 加1行 | +1 |
| `backend/crates/api_server/src/pay_handlers.rs` | 重构 payment 触发 | -50/+30 |
| `backend/crates/api_server/src/lib.rs` 或 `mod.rs` | 加 mod 声明 | +2 |
| `backend/crates/api_server/src/routes.rs` | 无变更（无新路由） | — |
| `app/lib/screens/review_screen.dart` | 复习完成弹分享 | +20 |
| `app/lib/widgets/share_widget.dart` | 微调 | +10 |
| `app/lib/screens/chat_screen.dart` | 注册引导弹窗 | +10 |

**总计**: ~8 个文件, ~170 行新增/修改
