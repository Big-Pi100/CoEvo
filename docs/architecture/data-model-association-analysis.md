# 数据模型关联性分析报告

> 日期: 2026-06-02
> 范围: 用户场景 × 生产代码 × DB Schema 全链路对照

---

## 一、用户场景拆解

### 场景 A: K12 入口（数学/语文...）

```
用户点"数学" → K12Init → 创建/恢复会话 → 加载预生成计划 → 写入 learning_plans
                → 批量导入预生成 cards → ws.rs 对话 → CP1 提取概念 → 写 cards
```

### 场景 B: 自由对话入口

```
用户新建对话 → ws.rs 对话 → CP2 创建 conversation_plans → CP1 提取概念 → 写 cards
```

---

## 二、当前生产链路的关联对照

### 2.1 K12 入口 → 会话绑定

```
[前] home_screen.dart: subject="数学" → k12_init_handler
     → 查 conversations.subject + grade_band (重复检测)
     → 创建 conversations 表带 subject, grade_band 列
```

**✅ 正常。** `conversations` 表有 `subject TEXT, grade_band TEXT` 列。

### 2.2 K12 入口 → 计划模板绑定

```
k12_init_handler → curriculum_loader::get_plan("math", "chu_zhong")
     → 从 plan_templates 加载 plan_content (JSON)
     → 写入 learning_plans 表
```

**⚠️ 间接关联。** `plan_templates` 没有 FK 指向 conversation，通过 `subject_key` 逻辑匹配。

### 2.3 K12 预生成卡片 → 会话绑定

```sql
-- routes.rs:1963
INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence,
                   conversation_id, created_at, subject, grade_band, k12_card_id, origin)
```

**✅ 有 `conversation_id`、`subject`、`grade_band`**。前端可通过 `subject` 字段筛选。

### 2.4 CP1 概念提取卡片 → 会话绑定

```sql
-- ws.rs:528 (ColdPath)
INSERT INTO cards (id, user_id, domain, card_type, front, back, source_sentence,
                   created_at, status)
```

**❌ 没有 `conversation_id`！❌ 没有 `subject`！**

CP1 卡片是**彻底断开**的——只有 `user_id` 和 `domain` 可关联。无法定位到具体会话或计划。

### 2.5 前端复习筛选

```sql
-- routes.rs:733 cards_all_handler
WHERE c.user_id = ?1 AND c.status = 'active'
-- 可选: AND c.domain = ?  AND c.subject = ?
```

前端只能按 `user_id + domain + subject` 筛选卡片。**没有 `plan_id` 筛选能力。**

---

## 三、完整关联链现状

```
conversations (id, user_id, subject, grade_band)
    ↑ FK                               ↑ 无FK (逻辑复用)
    |                                  |
learning_plans (id, conversation_id)   plan_templates (subject_key = conversations.subject)
  plan_content JSON (stages → tasks)
    |
    ↓ plan_id (逻辑引用，无FK)
user_plan_progress (plan_id, task_key, status)
    |
    ↓ (无关联)
cards (conversation_id?, subject?, domain?)
  ├── K12预生成: 有 conversation_id, subject, grade_band ✅
  ├── 阅读模式: 有 conversation_id, plan_task_id(但已从DDL移除) ⚠️
  └── CP1提取: 仅 user_id + domain ❌
```

### 关键断裂点

| 关联 | 状态 | 影响 |
|------|------|------|
| `cards → conversation_plans` | ❌ 无 FK，无列 | CP1 卡片无法关联到计划 |
| `cards → plan`（任意粒度的 plan_id） | ❌ 无 | 不能按计划筛选复习 |
| `CP1 cards → conversation` | ❌ 不为空 | 无法追溯来源会话 |
| `user_plan_progress → conversation_plans` | ⚠️ 逻辑引 FK | 无 DDL 约束 |

---

## 四、生产代码不一致性

1. **`reading` 模式写 `plan_task_id`**（routes.rs:2184），但 V2.0 Phase 4 已从 DDL 中移除此列
2. **`ws.rs` CP1 写 `status` 列**（ws.rs:529），但测试 SCHEMA_SQL 中无此列
3. **`k12_init` 不写 `status`**（routes.rs:1963），但 `ws.rs` 写 `status = 'pending'`
4. DD 的 `cards` 重建中丢弃了 `status` 和 `plan_task_id`（V2.0 Phase 4），但后续代码仍在使用

---

## 五、建议

1. **加 `plan_id TEXT REFERENCES conversation_plans(id)` 到 `cards` 表**
   - K12 预生成卡片：INSERT 时写入当前 `learning_plans.conversation_id` 对应的 `conversation_plans.id`
   - CP1 卡片：同上，从 `build_plan_context` 获取
   - 前端：`SELECT * FROM cards WHERE plan_id = ?` 直接筛选

2. **CP1 卡片加 `conversation_id`**
   - `ws.rs` ColdPath INSERT 时已持有 `conv_id`，写入即可

3. **清理 DDL 不一致**
   - 确定 `plan_task_id` 的去留（当前生产已无，但 reading 代码仍在写入）
   - 测试 SCHEMA_SQL 追上生产 DDL 的全貌
