# Plan 成就体系重构方案

> 日期：2026-06-27
> 目标：将错误的「固定静态成就 first_stage」改造为「按 plan 名称动态生成成就」

---

## 一、背景与问题

### 1.1 当前现状

已实现的是**错误的固定成就路线**：

```toml
[achievements.first_stage]
category = "seed"
tier = "bronze"
name = "初段"
conditions = [{ metric = "stages_completed", op = "gte", value = 1 }]
triggers = ["stage_completed"]
```

配套的代码改动：

| 文件 | 改动内容 | 状态 |
|:-----|:---------|:----:|
| `achievements.toml` | 新增 `[achievements.first_stage]` 固定成就节 | ❌ 需删除 |
| `achievement_icons.dart` | 新增 `'first_stage'` 图标和颜色映射 | ❌ 需删除 |
| `growth.rs` | 新增 `stages_completed: u32` 字段 + 两次初始化 | ❌ 需删除 |
| `achievement_engine.rs` | 新增 `AppEvent::StageCompleted` variant + SQL 查询 + 上下文填充 | ❌ 需删除 |
| `plan_handler.rs` | 新增 `publish(StageCompleted{...})` 调用 | ❌ 需删除 |

### 1.2 问题根因

`first_stage` 是一个固定成就 key，存在于静态 TOML 定义中。但 Plan 由 LLM 动态生成（名称、stage 数量都不固定），**固定成就的名称和数量无法匹配动态 plan 的多样性**。用户希望按 plan_name + stage_name + 通用后缀生成成就名——例如完成「向量与矩阵基础」计划的第一个 stage「向量的几何与代数表示」时，解锁成就「向量与矩阵基础·入门」。

---

## 二、新设计方案

### 2.1 核心原则

1. **不碰现有 35 个固定成就**，它们继续用 TOML 引擎检测
2. **动态 plan 成就单独处理**，不走 TOML，不走 `achievement_engine` 事件总线
3. **PLAN / STAGE 完成时直接写专用表**，不依赖静态成就定义
4. **成就名 = plan_name + 后缀**：
   - stage 完成：`{plan_name}·{stage_name}·入门`
   - plan 完成：`{plan_name}·进修`
5. **前端展示独立于固定成就页**，按 plan 分组显示

### 2.2 复用现有 `achievements` 表

不建新表，直接利用现有的 `achievements` 表，通过 `source` 字段区分：

```sql
-- achievements 表现有结构（不变）
id TEXT PRIMARY KEY,           -- "{user_id}-plan_stage_{plan_id}_{idx}"
user_id TEXT,
achievement_key TEXT,          -- "plan_stage_{plan_id}_{idx}"
name TEXT,                     -- "向量与矩阵基础·入门"
icon TEXT,                     -- 统一 "flag" (不同 tier 前端自动配色)
color TEXT,                    -- 统一空
tier TEXT,                     -- bronze/silver/gold/platinum/diamond/special
category TEXT,                 -- "plan_achievement"
source TEXT,                   -- "plan_achievement"（区分与 TOML 定义的成就）
unlocked_at TEXT
```

**写入示例**（stage 完成时）：
```rust
conn.execute(
    "INSERT OR IGNORE INTO achievements
     (id, user_id, achievement_key, name, icon, tier, category, source, unlocked_at)
     VALUES (?1, ?2, ?3, ?4, 'flag', ?5, 'plan_achievement', 'plan_achievement', ?6)",
    rusqlite::params![
        format!("{}-plan_stage_{}_{}", user_id, plan_id, stage_idx),
        user_id,
        format!("plan_stage_{}_{}", plan_id, stage_idx),
        format!("{}·{}", plan_name, suffix),
        tier,
        chrono::Utc::now().to_rfc3339()
    ],
)?;
```

**查询 API**：
```sql
SELECT * FROM achievements
WHERE user_id = ? AND source = 'plan_achievement'
ORDER BY unlocked_at DESC;
```

优点：
- 零 migration，零新表
- 自动复用现有成就通知系统（`user_notifications` 表）
- 前端成就 API 兼容（加 `source` 过滤即可）

### 2.3 数据流

```
用户完成 stage
    ↓
plan_handler.rs: apply_plan_mutations()
    → stage["status"] = "done"
    → INSERT INTO achievements (source='plan_achievement', name='向量与矩阵基础·入门', ...)
    → 推送通知（复用现有 WS 成就通知机制，无需改）

用户完成 plan (所有 stage done)
    ↓
plan_handler.rs: 此时 plan_completed（已有 PlanCompleted 事件）
    → INSERT INTO achievements (source='plan_achievement', name='向量与矩阵基础·修成', tier='special', ...)
    → 通知
```

### 2.4 后缀表

每个 plan 的 stage 数量和名称由 LLM 动态生成，所以后缀按**已完成的 stage 序号**映射，不依赖 stage 总数。

| 等级 | 触发 | 后缀 | tier | 适用 plan 示例 |
|:----:|:-----|::----:|:----:|:--------------|
| 1 | 第 1 个 stage 完成 | `·入门` | 🥉 bronze | 任意 plan |
| 2 | 第 2 个 stage 完成 | `·初窥` | 🥈 silver | 任意 plan |
| 3 | 第 3 个 stage 完成 | `·进阶` | 🏅 gold | 任意 plan |
| 4 | 第 4 个 stage 完成 | `·精研` | 💎 platinum | 任意 plan |
| 5 | 第 5 个 stage 完成 | `·达人` | 💠 diamond | 任意 plan |
| 6+ | 第 6+ 个 stage 完成 | `·精通`（只有一个，不重复） | — | LLM 生成了超多 stage |
| **最终** | **全部 stage 完成** | `·修成` | 🌟 special | 不计 stage 数，覆盖之前所有 |

**关键规则**：

- **独立计数，不覆盖**：完成第 1 个 stage 出 "入门"，完成第 2 个出 "初窥"，两者共存于同 plan 的记录中。用户在该 plan 下有 N 个 stage 成就（N ≤ 5）+ 1 个 plan 成就。
- **stage 数量 < 5 的 plan**：也能拿到对应数量的成就，不会因为总数不够而遗漏。
  - 例：plan 只有 3 个 stage → 用户获得：·入门、·初窥、·进阶 + ·修成 = 共 4 个成就
- **「修成」是 plan 级别**：所有 stage 完成后触发，tier 为 special，独立于 stage 级成就之上。
- **长 plan（6+ stage）**：达到·达人后不再新增，但完成后同样获得·修成。

### 2.5 新 API

```
GET /api/user/{uid}/plan-achievements
→ {
    "plans": [
      {
        "plan_id": "plan_xxx",
        "plan_name": "向量与矩阵基础",
        "domain": "science",
        "achievements": [
          { "name": "向量与矩阵基础·入门", "tier": "bronze", "completed_at": "..." },
          { "name": "向量与矩阵基础·进阶", "tier": "silver", "completed_at": "..." },
        ]
      },
      ...
    ]
  }
```

### 2.6 前端展示

`achievements_screen.dart` 当前已有 7 个分类 tab：启程、坚持、博学、精进、探索、特殊、社交。

新增 **plan 成就 tab** — 用户每完成一个 plan 的某个 stage，就在 tab 栏多一个 tab：

```
┌─────────────────────────────────┐
│  启程 坚持 博学 精进 探索 特殊 社交   │  ← 7 个固定 tab（不变）
│  向量与矩阵基础  时态与语态  │  ← plan tab（动态新增）
└─────────────────────────────────┘
```

**画风逻辑**：

| 场景 | 表现 |
|:-----|:-----|
| 用户有 0 个 plan 成就 | tab 栏完全不变（7 tab） |
| 用户完成一个 plan 的第 1 个 stage | tab 栏新增「向量与矩阵基础」tab |
| 用户同 plan 再完成第 2 个 stage | tab 内容更新（新增 ·初窥 卡片），tab 不增不减 |
| 用户完成另一个 plan 的 stage | tab 栏再新增「时态与语态」 |

**tab 内展示**（以「向量与矩阵基础」为例）：

```
┌── 向量与矩阵基础 ────────────┐
│ 🥉 向量与矩阵基础·入门         │
│ 🥈 向量与矩阵基础·初窥         │
│ 🏅 向量与矩阵基础·进阶         │
│ (plan 状态: 3/6 阶段完成)      │
│ 全部完成→ 🌟 向量与矩阵基础·修成│
└──────────────────────────────┘
```

和复习页面的语言 tab 一致——每个 tab 由 `Tab` widget 动态创建，标题来自 `plan_name`，内容来自 API 返回的 `source='plan_achievement'` 记录。
```

---

## 三、清理清单（必须执行）

### 3.1 后端代码

| # | 文件 | 行 | 操作 |
|:-:|:-----|:--:|:-----|
| 1 | `backend/achievements.toml` | 71-79 | 删除 `[achievements.first_stage]` 整节 |
| 2 | `backend/crates/shared_types/src/growth.rs` | 99 | 删除 `pub stages_completed: u32` |
| 3 | `backend/crates/shared_types/src/growth.rs` | 141 | 删除 `stages_completed: 0`（minimal 初始化） |
| 4 | `backend/crates/shared_types/src/growth.rs` | 177 | 删除 `stages_completed: 0`（Default 初始化） |
| 5 | `backend/crates/api_server/src/achievement_engine.rs` | 62 | 删除 `StageCompleted { user_id: String },` variant |
| 6 | `backend/crates/api_server/src/achievement_engine.rs` | 76 | 删除 `AppEvent::StageCompleted { .. } => "stage_completed",` |
| 7 | `backend/crates/api_server/src/achievement_engine.rs` | 89 | 删除 `\| AppEvent::StageCompleted { user_id } => user_id,` |
| 8 | `backend/crates/api_server/src/achievement_engine.rs` | 166-173 | 删除 `stages_completed` SQL 查询块 |
| 9 | `backend/crates/api_server/src/achievement_engine.rs` | 477 | 删除 `stages_completed,`（context 填充） |
| 10 | `backend/crates/api_server/src/plan_handler.rs` | 583-584 | 删除 publish(`StageCompleted`) 调用 |

### 3.2 前端代码

| # | 文件 | 行 | 操作 |
|:-:|:-----|:--:|:-----|
| 11 | `app/lib/shared/achievement_icons.dart` | 15 | 删除 `'first_stage': Icons.flag,` |
| 12 | `app/lib/shared/achievement_icons.dart` | 69 | 删除 `'first_stage': const Color(0xFFCD7F32),` |

### 3.3 新增代码（清理后实施）

| # | 文件 | 操作 |
|:-:|:-----|:-----|
| 13 | `backend/plan_handler.rs` | `apply_plan_mutations` 中 stage done 时 INSERT INTO achievements |
| 14 | `backend/plan_handler.rs` | plan 全部完成时 INSERT INTO achievements（修成） |
| 15 | `backend/routes.rs` | 新增 `GET /api/user/{uid}/plan-achievements` handler（查 achievements WHERE source='plan_achievement'） |
| 16 | `app/lib/api/chat_client.dart` | 新增 `getPlanAchievements()` |
| 17 | `app/lib/screens/achievements_screen.dart` | 新增 plan 成就区域（按 plan 分组的卡片列表） |

---

## 四、实现顺序

```
Step 1: 执行清理清单 1-12（删除全部废代码）
Step 2: 编译验证 + 测试，确保现有固定成就不受影响
Step 3: plan_handler.rs 写入逻辑（stage_done / plan_completed 时 INSERT INTO achievements）
Step 4: 后端 API handler
Step 5: 前端 API + 展示
Step 6: 端到端测试
```

---

## 五、附：清完不影响什么

- **35 个静态成就**：不受影响，继续使用现有的 `achievement_engine` TOML 事件总线
- **成就页面**：渲染逻辑不变，新增 plan 区域是追加不是替换
- **成就海报/弹窗**：`AchievementOverlay` 走不同的通知通道，需要单独接入或直接用现有 WS 通知
