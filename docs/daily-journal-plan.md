# 学习日志（Daily Journal）设计文档

> 替代当前"本周学习报告"功能，从数据面板升级为 AI 学习教练反馈。

---

## 一、设计目标

| 维度 | 目标 |
|:--|:--|
| **用户感受** | 每天收到一个了解你、关心你进步的学习教练的真诚反馈 |
| **具体夸奖** | 点名具体卡片内容，让用户感觉 AI 真的知道他学了什么 |
| **发现问题** | 从复习错误中定位薄弱点，而非笼统提醒 |
| **改善建议** | 给出可操作的下一步行动 |
| **计划进度** | 体现整体学习计划的推进程度，给用户看到"我又往前推了一步" |

## 二、LLM 输入

### 2.1 数据来源

| 数据 | 查询 | 量级 |
|:--|:--|:-:|
| 今日对话（用户消息） | `SELECT content FROM conversation_turns WHERE role='user' AND created_at>=today ORDER BY created_at DESC LIMIT 10` | ≤10 条 |
| 今日新增卡片 | `SELECT front, back, domain FROM cards WHERE created_at>=today LIMIT 5` | ≤5 条 |
| 今日复习详情 | `SELECT front, reps, lapses FROM review_log JOIN cards ON card_id=cards.id WHERE quality<3 AND reviewed_at>=today` | ≤5 条 |
| 今日成就 | `SELECT name, tier FROM achievements WHERE unlocked_at>=today` | ≤3 条 |
| 计划进度增量 | 今日 vs 昨日的 `done_tasks` 差值 + 当前阶段名 | 1 条 |
| 全局统计 | 连续天数、今日复习总数、今日对话轮数 | 3 个数字 |

### 2.2 LLM 输入模板

```
今日是 2026年5月11日（周三）。

📝 用户今天在对话中问了这些：
1. "Je voudrais un café, s'il vous plaît"
2. "Où est la gare?"
3. "这个语法点我不太明白..."
4. "désolé 和 pardon 有什么区别？"

📄 今天新学的概念：
- 法语: Où est la gare? → 火车站在哪里？
- 法语: Je voudrais un café → 我想要一杯咖啡

🔁 今日复习：15 次（正确 12，错误 3）
薄弱卡片：désolé（已遗忘 3 次）

🏆 新成就：知识猎人

📈 学习计划进度：
计划：法语入门
今日推进：口语练习阶段，完成 2/5 个任务（昨日 0 → 今日 2）
整体进度：5/21 任务完成

🔥 连续学习：7 天
```

### 2.3 LLM 输出要求

返回纯文本，3-5 句中文，包含四个层次：

```
1. 🎯 具体进步：点出今天学了什么（引用卡片内容）
2. 👍 具体夸奖：结合内容夸奖，避免笼统
3. 🔍 发现问题：从复习错误中分析（可提多轮挣扎的卡片）
4. 💡 改善建议：可操作的下一步
   + 可选: 📈 计划推进: 体现整体进度感
```

## 三、系统设计

### 3.1 数据库

```sql
CREATE TABLE IF NOT EXISTS daily_journals (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    date TEXT NOT NULL,
    content TEXT NOT NULL,         -- AI 生成的日志正文
    stats_json TEXT NOT NULL,      -- 当日原始 JSON 数据
    plan_progress TEXT,            -- 计划进度快照（JSON）
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, date)
);
```

### 3.2 API

| 方法 | 路径 | 说明 |
|:--|:--|:--|
| `GET` | `/api/user/{user_id}/daily-journal?date=2026-05-11` | 获取指定日期日志。不存在则生成 |

**时间判定**（后端 UTC+8）：
- 当前 ≤ 22:29 → "今日"为昨日（昨天完整日 → 生成昨日日志）
- 当前 ≥ 22:30 → "今日"为今天（今日数据 → 生成今日日志）

### 3.3 生成流程

```
GET /daily-journal?date=2026-05-11
  │
  ├─ DB 中已存在该日期 → 直接返回
  │
  └─ 不存在：
       ├─ 1. 查用户消息 (LIMIT 10)
       ├─ 2. 查新增卡片 (LIMIT 5)
       ├─ 3. 查今日复习 (错误项 LIMIT 5)
       ├─ 4. 查今日成就
       ├─ 5. 查计划进度增量（今日 vs history）
       ├─ 6. 组装 prompt → 调 LLM（复用 chat_engine）
       ├─ 7. 写入 daily_journals 表
       └─ 8. 返回 {date, content, stats_json}
```

### 3.4 计划进度增量

```sql
-- 今日计划快照
SELECT plan_json FROM learning_plans
WHERE user_id = ? AND mode NOT IN ('deleted')
ORDER BY updated_at DESC;
```

对比昨日快照（从最近一次 `daily_journals` 的 `plan_progress` 字段提取），计算：
- `done_tasks` 增量
- 当前阶段变化
- 新完成子任务名

如果首次生成无对比基准，则输出"当前阶段 + 已有进度"。

## 四、难点跟踪（未来扩展）

### 4.1 当前难点：对话中即时标记

在对话中，当 LLM 识别到用户对某概念理解困难，可以：

```
用户: "这个语法点我不太明白..."
AI: 解释后 →
→ 将"语法点X"标记为 difficulty_point
→ 同时创建 or 关联一张卡片，extra field: difficulty=true
→ 在 daily_journal 的生成中查询 difficulty_point 是否已被攻克
```

**数据库扩展**：

```sql
ALTER TABLE cards ADD COLUMN difficulty INTEGER DEFAULT 0;
-- 0=普通, 1=有难度, 2=已攻克
```

### 4.2 挂起-召回-再攻克

```
发现难点 → 标记 difficulty=1
          ↓
复习时遇到 → 正确 3 次连续 → 标记 difficulty=2（已攻克）
          ↓
复习时反复错误 → 不降级，保持 difficulty=1
          ↓
用户主动跳过或忽略 → 仍保持，每天日志提醒"这个知识点你一直卡着"
```

日报中体现：

```
🔍 发现问题：
"pouvoir 这个动词变位你已经挣扎 5 次了仍会混淆，
建议专门花 5 分钟用变位表跑一遍，比零散复习效果好。"
```

### 4.3 子任务栈（与学习计划的联动）

```
学习计划: 法语入门
├─ 阶段1: 基础词汇 (5/5 完成 ✅)
├─ 阶段2: 旅行会话 (3/5 完成 ← 当前)
│   ├─ 任务1: 问路对话 ✅
│   ├─ 任务2: 点餐对话 ✅
│   ├─ 任务3: 酒店预订 ✅
│   ├─ 任务4: 购物用语 ⏳ ← 被"钱数表达"知识点卡住
│   │                     （difficulty=1, 已挂起 2 天）
│   └─ 任务5: 紧急用语 ❌
└─ 阶段3: 语法进阶 (0/4)
```

日志中体现：

```
📈 计划推进：
旅行会话阶段 3/5 → 购物用语被"钱数表达"卡住 2 天了，
可以试试在 AI 对话中专门模拟去市场买水果的场景来突破。
```

## 五、前端改动

| 文件 | 操作 |
|:--|:--|
| `chat_client.dart` | 删除 `getWeeklyReport`，新增 `getDailyJournal(date)` |
| `profile_screen.dart` | 替换 `_buildWeeklyReport` → `_buildDailyJournal` |

### 5.1 前端卡片样式

```
┌──────────────────────────────────────────┐
│ 📖 学习日志       2026年5月11日           │
│                                          │
│ 今天你在法语旅行会话上迈出了一大步！      │
│ "Où est la gare"（火车站在哪里）和       │
│ "Je voudrais un café"（我想要一杯咖啡）  │
│ 这两个句子非常实用 👍                     │
│                                          │
│ 不过我发现 "désolé" 已经反复遗忘 3 次了， │
│ 建议和其他道歉用语放在一起对比记忆。      │
│                                          │
│ 📈 法语入门计划 · 旅行会话阶段 3/5 →    │
│                                          │
│ 🔥 连续学习 7 天                         │
└──────────────────────────────────────────┘
```

### 5.2 空状态处理

当天无学习活动时，生成一条"今日无学习记录"的日志，语气温和鼓励而非责备：

```
今天你还没有开始学习哦。
不过没关系，休息也是学习的一部分。
明天再开始吧，我在这里等你 🌟
```

## 六、阶段规划

| 阶段 | 内容 | 优先级 |
|:--|:--|:-:|
| **MVP** | 懒加载生成：用户访问"我的"页面时触发 LLM 生成，数据源含消息/卡片/复习/计划增量 | P0 |
| **V2** | 难点跟踪：对话中标记 `difficulty`，日志引用具体难点卡片 | P1 |
| **V3** | 子任务栈：被难点卡住的任务显示在日志中，直到用户攻克才推进 | P2 |
| **V4** | 定时调度：22:30 后台批量生成所有活跃用户日志，用户访问零延迟 | P3 |
