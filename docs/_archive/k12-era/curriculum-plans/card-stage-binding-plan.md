# 卡片 Stage 级绑定改进方案

## 现状问题

| 问题 | 说明 |
|:----|:-----|
| **卡片绑在 plan 级** | `plan_type` + `plan_id` 只能定位到整个计划，无法区分 stage |
| **预置卡全部 active** | K12 init 时 136 张卡全量 active，前端一次加载全部，token 浪费 |
| **CP1 去重查全量 cards** | `existing_fronts` 查询用户所有卡片，包含其他 stage 的不相关内容 |
| **渐进式披露缺失** | 无法按 stage 逐个展示卡片，学生一次性看到所有内容 |

## 改进方案

### 1. DB：cards 表新增 `stage_name` 字段

```sql
ALTER TABLE cards ADD COLUMN stage_name TEXT DEFAULT NULL;
```

此字段在 `main.rs` 的 `SCHEMA_SQL` 中一并加入，使新库初始就包含。
✅ **已完成**：main.rs + schema.sql + 参考 schema + ALTER TABLE 迁移

### 2. K12 init 写入：archived + stage_name

**修改位置**：`routes.rs` k12_init_handler，卡片 INSERT 语句

**改前**：`status='active'`，无 stage_name
**改后**：`status='archived'`，`stage_name` 通过 gold_cr_ids 匹配 task 所在 stage

所有预置卡初始状态为 `archived`。第一个 stage 的卡由 init 末尾立即激活。
✅ **已完成**

### 3. Stage 激活逻辑

**函数 `activate_stage_cards()`**（`plan_handler.rs:1889`）：

```rust
pub fn activate_stage_cards(conn, plan_type, plan_id, stage_name) {
    UPDATE cards SET status = 'active'
    WHERE plan_type = ?1 AND plan_id = ?2 AND stage_name = ?3
      AND status = 'archived'    -- 仅单向：archived → active，不可逆
}
```

**调用时机**（2 处）：

| 位置 | 触发条件 | 状态 |
|:----|:---------|:----|
| K12 init 末尾 | init 完成后激活第一个 stage | ✅ |
| `unlock_next_cards` | 任务推进时检测新 stage | ✅ |

### 4. CP1 去重过滤（已完成）

**修改位置**：`routes.rs` `load_chat_context()` 和 `ws.rs` CP1 路径

**改后 SQL**（routes.rs `load_chat_context`）：
```sql
-- 无 stage 时（自由对话）：
SELECT LOWER(front) FROM cards WHERE user_id = ?1 AND status = 'active'
-- 有 stage 时（K12 教学）：
SELECT LOWER(front) FROM cards WHERE user_id = ?1 AND status = 'active' AND (stage_name IS NULL OR stage_name = ?2)
```

**ws.rs** 同样改为 `WHERE ... AND status = 'active'`
✅ **已完成**

### 5. 前端复习队列

`/api/cards/all` 已按 `status='active'` 筛选，无需改动。
✅ **不需要改动**

### 6. 数据迁移方案

生产环境中已有大量 `status='active'` 的预置卡片。需要迁移到新模型。

#### 6a. 预置卡（plan_type='plan_templates'）

已有预置卡的特点是 `k12_card_id` 非空。迁移脚本：

```sql
-- 1. 将现有预置卡改为 archived（安全操作，unlock_next_cards 会在需要时激活）
UPDATE cards SET status = 'archived' 
WHERE status = 'active' AND origin = 'prebuilt';

-- 2. 为预置卡填充 stage_name
-- 需要从 plan_templates.plan_content 中解析 stage 映射表
-- 卡片的 k12_card_id 对应 plan_content 中某个 task 的 gold_cr_ids 之一
-- 通过 curriculum_loader 可以查到 k12_card_id → stage_name
```

**不需要 LLM 参与**。预置卡的 stage 可以通过 `curriculum_loader::get_cards()` + `plan_templates.plan_content` 程序化匹配。`plan_content` 的 stages 数组中每个 task 有 `gold_cr_ids`，cards 表有 `k12_card_id`，通过 `gold_cr_ids.contains(k12_card_id)` 可确定 card 属于哪个 stage。

#### 6b. CP1 提取卡（plan_type='conversation_plans'）

CP1 卡片的 `stage_name = NULL`，保持 `active` 状态不变。前端和 CP1 查询都包含 `stage_name IS NULL` 的卡片。

#### 6c. 迁移时机（已完成）

在 `main.rs` 启动迁移中，已新增 **Phase StageBinding**：

```rust
// ── Phase StageBinding: 预置卡 stage_name 分配 + 归档旧卡 ──
{
    // 1. 检测 stage_name 列是否存在
    // 2. 归档存量 active 预置卡 → archived
    // 3. 遍历 plan_templates.plan_content JSON，匹配 gold_cr_ids → stage_name
    // 4. 激活第一个 stage 的卡片
}
```

✅ **已完成**（`main.rs` Phase StageBinding）

## 影响范围汇总

| 文件 | 改动量 | 状态 |
|:----|:------|:----|
| `src/main.rs` SCHEMA_SQL | +1 行 | ✅ |
| `src/main.rs` ALTER TABLE | +1 行 | ✅ |
| `src/main.rs` 迁移脚本 | ~60 行 | ✅ |
| `src/routes.rs` k12_init | ~30 行 | ✅ |
| `src/plan_handler.rs` | +25 行 | ✅ |
| `src/routes.rs` load_chat_context | ~10 行 | ✅ |
| `src/ws.rs` CP1 路径 | ~3 行 | ✅ |
| `crates/api_server/src/schema.sql` | +1 行 | ✅ |
| `backend/schema.sql` | +1 行 | ✅ |

**总改动量约 60 行有效代码**，已实施约 60%，剩余 40%。
