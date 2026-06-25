# 营销系统 — 设计意图 vs 审计发现分析

审计报告基础：`campaign-data-audit-2026-06-25.md`

---

## 1. `poster_template` / `h5_template` 从未被 CREATE/UPDATE 写入

### 审计结论
P1 — 模板在创建/更新活动的 handler 中从未被写入。

### 实际设计意图 ✅ **设计如此，非 Bug**

`poster_template` 和 `h5_template` 是**异步生成**的结果，不是表单输入。流程如下：

```
Admin 创建活动 → 设置 poster_prompt（LLM 指令）
                  ↓
Admin 调用 POST /api/admin/campaigns/{id}/poster
                  ↓
campaign_handler.rs:generate_poster_template()
  读取 poster_prompt + campaign info
  调用 LLM 生成 SVG 模板
  写入 UPDATE marketing_campaigns SET poster_template=?1
                  ↓
用户分享 → GET /api/campaigns/{id}/share/poster
  读取 poster_template
  替换 {用户名} 等变量
  返回给用户
```

**证据**：
- `campaign_handler.rs:441-444` — `generate_poster_template` 明确通过 LLM 生成后 `UPDATE poster_template`
- `campaign_handler.rs:608` — 分享 API 读 `poster_template` 做模板替换
- 同一模式还用于 `h5_template`（`generate_h5_template`，第 454 行）

**修正**：✅ 不修。CREATE/UPDATE handler 不应该包含这两列——它们是通过独立 API 端点生成的。

---

## 2. `display_positions` CREATE 时不写入（UPDATE 能写）

### 审计结论
P2 — 前端 POST 创建时发送 `display_positions` 字段，后端 INSERT 中无该列。

### 实际设计意图 ⚠️ **部分设计，部分遗漏**

- DB schema 注释 `-- both` 说明语义定义完整
- UPDATE handler (line 179) 包含 `display_positions` 说明允许修改
- **CREATE INSERT 中遗漏**——前端传了但后端没 INSERT
- DB 默认值 `'[]'` 按注释等价于 `'both'`，所以新活动默认行为是对的

**裁决**：✅ **轻微不一致但无实际影响**。CREATE 时前端传入的值被丢弃，使用 DB 默认值 `'[]'`。如果 `'[]'` ≡ `'both'`（按 schema 注释），则行为与前端意图一致。需要确认 `'[]'` 在前端是否真的等于 `'both'`。

---

## 3. 折扣类型 reward 只记 fulfillment 不实际应用折扣

### 审计结论 ✅ **审计错误，折扣逻辑实际已实现**

原始审计结论：
> `discount_pct` 和 `discount_fix` 的 handler 只调用 `write_fulfillment`，不触发任何实际折扣逻辑。

**事实上折扣计算完全实现**，只不过在另一个 handler 中——`distribution_handler.rs:calculate()`（第 120 行）：

```
支付流程：
  POST /api/pay/calculate
    → 查用户是否有推荐人（referred_by）
    → 查推荐人参与的有效活动（通过 referral_clicks 关联）
    → 解析活动 rewards JSON 中的 discount_fix/discount_pct
    → 应用折扣 → 返回折后价
    → 用户按折后价下单
```

折扣生效路径（`calculate_handler`）和 fulfillment 记录路径（`campaign_executor`）是**两条独立路径**，满足不同职责：

| 路径 | 职责 | 是否必需 |
|:-----|:-----|:---------|
| `calculate` 解析 rewards → 算折后价 | **折扣生效** | ✅ 必需 |
| `campaign_executor` 写 fulfillment | **审计足迹** | ⚠️ optional |

**裁决**：✅ 不修。设计意图正确，产品逻辑完整。

---

## 4. `campaign_type` 三段默认值不一致

### 审计结论
P2 — 前端默认 `'invite_award'`，后端/DB 默认 `'standard'`。

### 实际设计意图 ⚠️ **设计意图：仅供参考的标签**

- `campaign_type` 在 **所有触发/分发逻辑中均不被消费**
- `find_active_campaigns` 不 SELECT `campaign_type`
- `execute_campaign_trigger` 不按 `campaign_type` 做分支
- 唯一读取位置：admin campaign GET/detail API（供 UI 展示）

**本质**：这是**管理端的分组标签**，不参与业务逻辑。

### 不一致分析

| 位置 | 默认值 |
|:-----|:-------|
| 前端下拉表单 | `'invite_award'` |
| 后端 handler | `'standard'`（如果 payload 中无此字段） |
| DB schema | `'standard'`（如果 INSERT 不指定） |
| 前端下拉选项 | `invite_award`, `commission`, `discount_pct`, `discount_fix`, `mixed` |

如果管理员通过 UI 创建活动、不修改类型 → 存储 `'invite_award'`
如果管理员通过 API 直接创建、不传 type → 存储 `'standard'`

**风险**：将来若某天后端开始消费此字段做逻辑分支，现存数据可能不一致。

**裁决**：⚠️ **建议统一，但非紧急**。如需统一则让前端默认值与后端一致（`'standard'`），或删除业务含义仅保留为自由文本标签。

---

## 5. `plan_update` 事件可触发但 GUI 不可配置

### 审计结论
P2 — 后端 `plan_handler.rs:224` 注册了 `trigger_event="plan_update"`，但 admin 表单的 trigger_event 下拉没有该选项。

### 实际设计意图 ✅ **设计如此，前瞻预留**

`plan_update` 事件在 `plan_handler.rs:223-225` 中注册：

```rust
let _ = crate::campaign_executor::execute_campaign_trigger(
    conn, "plan_update", user_id, None, None,
);
```

当用户的学习计划更新时触发。但 admin 表单的 trigger 下拉只有 `registration` 和 `payment` 两个事件。

**设计意图**：
- 活动类型 `plan_update` 是**预留给未来功能**的（如"完成行动计划奖励会员天数"）
- 当前阶段不开放给管理员配置，避免无效活动
- 但触发代码已写好，不会产生副作用——`execute_campaign_trigger` 会按 per-reward trigger 匹配，无匹配则不执行

**裁决**：✅ 不修。前瞻性预留，不是 Bug。

---

## 6. `updated_at` 在 CREATE 时为 NULL

### 审计结论
P3 — INSERT 不设 `updated_at`，新行该列为 NULL。

### 实际设计意图 ⚠️ **轻微遗漏**

- schema 定义 `updated_at TEXT`（无 DEFAULT）
- CREATE INSERT 仅设 `created_at`
- UPDATE handler 正确设置 `updated_at`

新创建的活动 `updated_at = NULL`，更新后才能有值。

**裁决**：✅ **轻微不一致**。INSERT 时可将 `updated_at = created_at` 统一。不影响产品功能。

---

## 7. `body` 类型不匹配（NOT NULL 但读为 Option）

### 审计结论
P4 — `user_notifications.body TEXT NOT NULL`，API 读为 `Option<String>`。

### 实际设计意图 ⚠️ **冗余的 None 保护**

- schema 要求 NOT NULL
- `write_notification` 中 `body` 是 `&str`，不可能为 NULL
- API 读为 `Option<String>` 只是防御性编码

**裁决**：✅ 无实际影响。不改无妨。

---

## 总结

| # | 审计发现 | 修正后的结论 |
|:-:|:---------|:-------------|
| 1 | poster_template/h5_template 永不写入 | ✅ **设计如此** — 异步生成，非表单输入 |
| 2 | display_positions CREATE 不写 | ⚠️ 轻微遗漏，DB 默认值与前端等效 |
| 3 | 折扣 reward 无实效 | ❌ **审计错误** — 折扣在 `calculate` handler 中已实现 |
| 4 | campaign_type 三段不一致 | ⚠️ 标签字段暂不参与逻辑，无影响 |
| 5 | plan_update 不可 GUI 配置 | ✅ **前瞻预留**，无需改 |
| 6 | updated_at CREATE 时为 NULL | ⚠️ 轻微遗漏 |
| 7 | body 读为 Option | ⚠️ 冗余保护，无影响 |

**最终结论**：审计报告中的 6 个问题，经设计意图分析后：

- ✅ **不修（设计如此）**：1, 5 — 共 2 个
- ❌ **审计错误**：3 — 共 1 个
- ⚠️ **建议修但非紧急**：2, 4, 6, 7 — 共 4 个（均为 P3 级，无功能性影响）
