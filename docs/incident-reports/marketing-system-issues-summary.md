# 营销系统开发测试问题总结

> 整理时间: 2026-07-09  
> 背景: 2026-07-08 一天内从本地测试到 VPS 部署发现的所有问题

---

## 问题清单

| # | 问题 | 类型 | 严重度 | 文件 | 状态 |
|---|------|------|--------|------|------|
| 1 | `trial/claim` 调用 `execute_campaign_trigger` 参数顺序错误（`campaign_id` 传给了 `order_id`） | 引入性 Bug | P0 | `trial_handler.rs:304` | ✅ 已修复 |
| 2 | `handle_subscription_days` 解析 ISO 8601 日期失败（`T14:44:42Z`），多条天数奖励相互覆盖 | 潜伏 Bug | P0 | `campaign_executor.rs:433` | ✅ 已修复 |
| 3 | 新加的 `has_real_info` 检查无测试覆盖 | 测试缺失 | P1 | `campaign_executor.rs` | ✅ 已补充测试 |
| 4 | 推广返现折扣类型配错：`discount_fix` + `value=0.85`（应使用 `discount_pct`） | 配置错误 | P1 | 营销活动配置 | ✅ 已修复 |
| 5 | 推广返现折扣 `party=self`，导致所有注册用户都获得折扣（应改为 `party=invitee`） | 配置错误 | P1 | 营销活动配置 | ✅ 已修复 |
| 6 | 折扣通知文案错误：`0.85 * 10 = 8 → "8折"`，应为 `0.85 * 100 = 85 → "85折"` | 计算 Bug | P2 | `campaign_executor.rs:275` | ✅ 已修复 |
| 7 | `calculate` handler 文案 `"推荐折扣: 85%"` 表述不清，改为 `"推荐折扣: 85折"` | 显示问题 | P2 | `distribution_handler.rs:337` | ✅ 已修复 |
| 8 | `real_name`/`phone` 仍可被覆盖（`COALESCE` 允许新值覆盖） | 设计漏洞 | P0 | `trial_handler.rs:255` | ✅ 已修复（CASE WHEN） |
| 9 | 备份脚本无错误检查，`sqlite3 .backup` 静默写空文件，38 字节 gz 被巡检遗漏 | 运维缺陷 | P1 | `backup-db.sh` | ✅ 已修复 |
| 10 | 巡检未检查备份文件有效性（仅 `ls -lt` 列文件名） | 监控缺失 | P2 | 巡检技能 | ✅ 已补充 |
| 11 | 无营销系统监控指标 | 监控缺失 | P1 | 巡检技能 | ✅ 已补充 Step 4 |

---

## 分类统计

| 类别 | 数量 | 占比 |
|------|:----:|:----:|
| 代码 Bug | 3 | 27% |
| 配置错误 | 2 | 18% |
| 测试缺失 | 1 | 9% |
| 设计漏洞 | 1 | 9% |
| 运维缺陷 | 1 | 9% |
| 监控缺失 | 2 | 18% |
| 显示问题 | 1 | 9% |

---

## 每日营销监控检查项

新增到每日巡检 Step 4 中的监控指标：

1. **活动状态**: 所有 campaign 应为 active，过期活动标记告警
2. **24h 奖励发放量**: 按 campaign/reward_type/party/status 分组统计
3. **折扣健康度**: granted vs fulfilled 对比，长期未核销的折扣告警
4. **推荐关系异常**: `referred_campaign_id` 有但 `referred_by` 无（或反之）
5. **奖励通知**: check reward_grant 类型通知最近 24h 是否正常发出
6. **活动成员**: 各活动的 member/inviter 分布
7. **佣金发放**: 最近 7 天 commission 统计

---

## 后续优化方向

- `calculate` handler 增加优惠券自动抵扣逻辑（支付时自动查询可用折扣）
- 前端展示折扣券列表（用户可查看已获得但未使用的折扣）
- subscription_days 奖励增加发放通知（当前已有）
- 端到端集成测试（trial/start → campaign/join → trial/claim → verify rewards）
- `campaign_filter` 作用域的单元测试（已补充）
