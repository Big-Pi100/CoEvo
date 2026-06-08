# CoEvo 成就体系 — 重新规划与扩展性架构

> 版本: V2.2 | 日期: 2026-06-06 | 状态: ✅ 全阶段完成 (Phase 0-7) | 事件总线 + confetti 已实现

---

## 一、现状问题

| # | 问题 | 影响 |
|---|------|------|
| 1 | 仅 11 个成就，全部是数量累积型 | 单调，没有学习行为多样性 |
| 2 | 成就定义硬编码在 `growth.rs` 的 `HashMap` 里 | 加一个成就 = 改 Rust 源码 + 重新编译 + 重新部署 |
| 3 | 条件引擎极简（只支持 `>=`） | 无法做复杂条件（如 AND 组合、百分比、连续行为） |
| 4 | 只在「复习提交」时触发检测 | 对话结束、制卡、计划完成都不会触发 |
| 5 | `AchievementContext` 只有 4 个字段 | 新增 metric 需要改 struct + 改所有调用点 |
| 6 | 无分类、无进度展示 | 用户不知道成就体系全貌，不知道离下一个还差多少 |
| 7 | 图标用 emoji 存 DB，前端 `Text()` 渲染 | 某些平台/字体下 emoji 失去颜色；彩色图标需要前后端各维护一份 |
| 8 | DB 有 `tier`/`source` 列但从未使用 | 设计浪费 |

**一句话总结**：每加一个成就要动 5 个地方，完全硬编码，不面向扩展。

---

## 二、成就内容重新规划

### 2.1 六大分类

| 分类 | 标识 | 含义 | 代表成就 |
|------|------|------|----------|
| 🌱 启程 | `seed` | 首次行为里程碑 | 初识、首测、破冰 |
| 🔥 坚持 | `consistency` | 连续学习 | 坚持3天、30天、365天 |
| 📚 博学 | `knowledge` | 知识积累量 | 50张卡、500张卡、5000张卡 |
| 🎯 精进 | `mastery` | 复习质量 | 准确率90%、完美复习、困难卡大师 |
| 🗺️ 探索 | `exploration` | 领域广度 | 覆盖3个领域、5个学科 |
| ⭐ 特殊 | `special` | 隐藏/季节性 | 深夜学习者、周末战士、闪电学神 |

### 2.2 五级分级

```
Bronze 青铜 → Silver 白银 → Gold 黄金 → Platinum 铂金 → Diamond 钻石
```

### 2.3 完整成就列表（共 41 个）

#### 🌱 启程（6个）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `first_card` | 初识 | 创建第1张卡片 | Bronze | auto_stories |
| `first_review` | 首测 | 完成第1次复习 | Bronze | check_circle |
| `first_conversation` | 破冰 | 完成第1次对话 | Bronze | chat |
| `first_plan` | 完赛 | 完成第1个学习计划 | Silver | task_alt |
| `first_hard_card` | 迎难 | 创建第1张困难卡片 | Silver | keyboard_double_arrow_up |
| `ten_conversations` | 话痨 | 完成10次对话 | Gold | forum |

#### 🔥 坚持（8个）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `streak_3` | 坚持3天 | 连续3天学习 | Bronze | whatshot |
| `streak_7` | 一周达人 | 连续7天学习 | Silver | local_fire_department |
| `streak_30` | 月学霸 | 连续30天学习 | Gold | self_improvement |
| `streak_100` | 百日毅力 | 连续100天学习 | Platinum | trending_up |
| `streak_365` | 年轮学者 | 连续365天学习 | Diamond | emoji_events |
| `weekend_warrior` | 周末战士 | 连续4个周末学习 | Gold | weekend |
| `night_owl` | 深夜灯 | 22:00-02:00 学习5次 | Silver | nightlight |
| `early_bird` | 早起鸟 | 06:00-08:00 学习5次 | Silver | wb_sunny |

#### 📚 博学（8个）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `cards_10` | 小有收获 | 10张卡片 | Bronze | collections_bookmark |
| `cards_50` | 收藏家 | 50张卡片 | Silver | library_books |
| `cards_200` | 图书馆 | 200张卡片 | Gold | account_balance |
| `cards_500` | 学者 | 500张卡片 | Platinum | school |
| `cards_2000` | 知识王者 | 2000张卡片 | Diamond | castle |
| `reviews_100` | 百炼 | 100次复习 | Bronze | replay_100 |
| `reviews_1000` | 千锤 | 1000次复习 | Gold | replay_circle_filled |
| `reviews_10000` | 万法归一 | 10000次复习 | Diamond | all_inclusive |

#### 🎯 精进（8个）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `accuracy_80` | 准确新手 | 最近20次复习准确率≥80% | Silver | track_changes |
| `accuracy_90` | 精准达人 | 最近50次复习准确率≥90% | Gold | verified |
| `accuracy_95` | 完美主义 | 最近100次复习准确率≥95% | Platinum | fact_check |
| `hard_master` | 困难克星 | 困难卡片复习10次全对 | Gold | gavel |
| `perfect_session` | 完美回合 | 单次复习会话(≥10张)全对 | Silver | star |
| `fsrs_mature` | 成熟学者 | 50张卡片进入 FSRS Mature 状态 | Gold | nature |
| `fsrs_learning` | 学习进行时 | 同时20张卡片在 Learning 状态 | Silver | science |
| `no_skip_7` | 不跳过 | 连续7天不跳过任何卡片 | Gold | block |

#### 🗺️ 探索（7个）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `domains_2` | 跨界新手 | 覆盖2个领域 | Bronze | explore |
| `explorer_3` | 探索者 | 覆盖3个领域 | Bronze | explore |
| `domains_5` | 领域达人 | 覆盖5个领域 | Silver | travel_explore |
| `domains_10` | 博学家 | 覆盖10个领域 | Gold | public |
| `subjects_3` | 三科通 | 覆盖3个学科(K12) | Silver | menu_book |
| `languages_2` | 双语者 | 学习2种语言 | Gold | translate |
| `all_subjects` | 全科状元 | 覆盖所有K12学科 | Diamond | bolt |

#### ⭐ 特殊（4个，隐藏成就）

| Key | 名称 | 条件 | 分级 | 图标 |
|-----|------|------|------|------|
| `secret_speed` | 闪电学神 | 1小时内创建20张卡片 | Platinum | flash_on |
| `secret_comeback` | 王者归来 | 中断30天后回归学习 | Gold | restart_alt |
| `secret_daily` | 日不落 | 一天内完成100次复习 | Platinum | dark_mode |
| `secret_early` | 元祖用户 | 注册后30天内完成1000次复习 | Diamond | child_care |

### 2.4 触发点扩展

| 当前 | 扩展后 |
|------|--------|
| `review_submit` 后 | ✅ `review_submit` — 复习提交后 |
| — | ✅ `card_created` — 制卡后 |
| — | ✅ `conversation_ended` — 对话结束后 |
| — | ✅ `plan_completed` — 计划完成后 |
| — | ✅ `daily_tick` — 每日定时任务（检测 streak/特殊时间） |

### 2.5 进度 API

实际路由：`GET /api/user/{user_id}/achievements-all`

返回按 category 分组的所有成就列表，每个成就含进度百分比与标签：

```json
{
  "categories": [
    {
      "category": "seed",
      "label": {"zh": "种子", "en": "Seed"},
      "icon": "auto_stories",
      "color": "#66BB6A",
      "achievements": [
        {
          "id": "first_card",
          "name": {"zh": "初识", "en": "First Card"},
          "description": {"zh": "创建第一张卡片", "en": "Create your first card"},
          "icon": "auto_stories",
          "tier": "bronze",
          "category": "seed",
          "unlocked": true,
          "unlocked_at": "2026-05-20T10:00:00Z",
          "progress_pct": 100,
          "progress_label": "1/1"
        }
      ]
    }
  ]
}
```

> 注：原设计文档中的 `GET /api/achievements/progress`（分 unlocked/locked 两个数组）未实现，当前实现为上述按分类分组格式，前端无需自行分拣。

---

## 三、可扩展性架构方案

### 3.1 核心理念：数据驱动 + 事件驱动 + 插件化

```
                        ┌──────────────────────┐
                        │  成就定义文件          │
                        │  achievements.toml    │
                        │  (唯一真理源)          │
                        └──────┬───────────────┘
                               │ 启动时加载
                               ▼
┌──────────┐   发布事件    ┌──────────────┐   匹配成就   ┌──────────────┐
│ 各业务点  │ ──────────▶ │  事件总线     │ ──────────▶ │  成就引擎     │
│ (制卡/    │  Event       │  EventBus    │             │  Engine      │
│  复习/    │              │              │             │  ┌─────────┐ │
│  对话/    │              │              │             │  │条件求值器│ │
│  定时)   │              │              │             │  │(插件化)  │ │
└──────────┘              └──────────────┘             │  └─────────┘ │
                                                       └──────┬───────┘
                                                              │ 新解锁
                                                              ▼
                                                       ┌──────────────┐
                                                       │  DB 持久化    │
                                                       │  + 返回前端   │
                                                       └──────────────┘
```

### 3.2 成就定义：TOML 配置驱动

```toml
# backend/achievements.toml

[achievements.first_card]
category = "seed"
tier = "bronze"
name = { zh = "初识", en = "First Step" }
description = { zh = "创建第一张卡片", en = "Create your first card" }
icon = "auto_stories"
color = "#FFC107"
conditions = [
  { metric = "total_cards", op = "gte", value = 1 }
]
triggers = ["card_created"]

[achievements.hard_master]
category = "mastery"
tier = "gold"
name = { zh = "困难克星", en = "Hard Card Slayer" }
icon = "gavel"
color = "#F44336"
conditions = [
  { metric = "hard_card_perfect_streak", op = "gte", value = 10 },
  { metric = "hard_card_count", op = "gte", value = 3 }
]
condition_logic = "AND"
triggers = ["review_completed"]
```

**扩展方式**：新成就 = 编辑 TOML + 部署，不改代码、不重新编译。

### 3.3 条件引擎：插件化求值器

```rust
// trait — 新增条件类型只需实现此 trait
trait ConditionEvaluator: Send + Sync {
    fn evaluate(&self, metric: &str, op: &str, target: f64, ctx: &AchievementContext) -> bool;
}

// 内置求值器
struct ComparisonEvaluator;    // >=, <=, ==, !=
struct PercentageEvaluator;   // percentage >= X
struct StreakEvaluator;       // 连续天数、连续行为
struct TimeWindowEvaluator;   // 时间段内行为计数（深夜/早起/1小时内）
struct ComboEvaluator;        // AND / OR 组合条件

// 引擎注册
struct AchievementEngine {
    evaluators: HashMap<String, Box<dyn ConditionEvaluator>>,
    achievements: Vec<AchievementDef>,  // 从 TOML 加载
}
```

**扩展方式**：新条件类型 = 实现一个 Evaluator + 注册，不改现有引擎。

### 3.4 事件总线

```rust
// 事件定义
enum AppEvent {
    CardCreated { user_id: i64, card_id: i64, difficulty: String },
    ReviewCompleted { user_id: i64, card_id: i64, correct: bool, duration_secs: f64 },
    ConversationEnded { user_id: i64, turn_count: i32, domain: String },
    PlanCompleted { user_id: i64, plan_id: i64, plan_type: String },
    DailyTick { user_id: i64, date: NaiveDate },
}

// 各业务 API 只需发事件，引擎自动匹配检测
// 例：制卡 API 尾部加一行
event_bus.publish(AppEvent::CardCreated { user_id, card_id, difficulty });
```

**扩展方式**：新触发点 = 定义新 Event variant + 业务点发事件 + TOML 配置 triggers。

### 3.5 Context 收集：按需查询

```rust
impl AchievementEngine {
    async fn collect_metric(&self, user_id: i64, metric: &str) -> f64 {
        match metric {
            "total_cards" => db.count_cards(user_id).await,
            "current_streak" => db.current_streak(user_id).await,
            "recent_accuracy_50" => db.recent_accuracy(user_id, 50).await,
            "hard_card_perfect_streak" => db.hard_perfect_streak(user_id).await,
            _ => 0.0,
        }
    }
}
```

**扩展方式**：新 metric = 加一个 `match` arm + SQL 查询，不改 struct。

### 3.6 前端数据驱动

```json
// API 返回的 JSON 自带 icon 和 color，前端不再硬编码 Map
{
  "key": "first_card",
  "name": "初识",
  "icon": "auto_stories",
  "color": "#FFC107",
  "tier": "bronze",
  "category": "seed"
}

// 前端渲染
Icon(_nameToIconData(json['icon']), color: _hexToColor(json['color']), size: 28)
```

### 3.7 扩展性对比

| 需求 | 旧架构（硬编码） | 新架构（数据驱动） |
|------|-----------------|-------------------|
| 加一个新成就 | 改 5 个文件 + 编译 + 部署 | 改 1 行 TOML + 部署 |
| 加一种条件类型 | 重写 condition_parser | 实现新 Evaluator trait |
| 加一个触发点 | 找所有调用点 + 改代码 | 定义 Event + 发事件 + TOML |
| 加一个 metric | 改 struct + 改检测逻辑 | 加 1 个 match arm |
| 改成就图标颜色 | 前后端各改一份 | 改 TOML 一处 |
| 多语言支持 | DB 字段存死值 | TOML 配置 i18n keys |

---

## 四、前端成就展示架构

### 4.1 双层展示模型：图标（正面） + 特效卡（详情）

这是本次设计的核心创意。成就的视觉表达分为两层：

```
┌──────────────────────────────────────────────────────┐
│                    成就展示双层模型                    │
│                                                      │
│  ┌─────────────────────┐    ┌───────────────────┐   │
│  │  图标（卡片正面）     │    │  特效卡（卡片详情）  │   │
│  │                     │    │                   │   │
│  │  ┌───────┐          │    │  ┌─────────────┐  │   │
│  │  │  🎯   │  初识     │    │  │   🎆  🏆    │  │   │
│  │  └───────┘          │    │  │  ─────────  │  │   │
│  │                     │    │  │  初识        │  │   │
│  │  小尺寸图标          │    │  │  青铜成就    │  │   │
│  │  + 名称             │    │  │  创建了第一   │  │   │
│  │  + 分级色环          │    │  │  张卡片！    │  │   │
│  │                     │    │  │              │  │   │
│  │  出现场景：成就页     │    │  │  [分享] [✕] │  │   │
│  │  排列方式：网格/列表  │    │  └─────────────┘  │   │
│  └─────────────────────┘    │                   │   │
│                             │  出现场景：弹窗通知  │   │
│                             │  排列方式：居中卡片  │   │
│                             └───────────────────┘   │
└──────────────────────────────────────────────────────┘
```

**对比表**：

| 维度 | 图标（成就页面） | 特效卡（弹窗通知） |
|------|-----------------|-------------------|
| 尺寸 | 小（40-48px 图标） | 大（完整卡片，~280x200dp） |
| 内容 | 图标 + 名称 + 分级色 | 图标动画 + 名称 + 分级缎带 + 描述 + 获得时间 |
| 动效 | 无/轻微（hover 放大） | 入场缩放弹跳 + 粒子撒花 + 分级光效 |
| 交互 | 点击→进度详情 | 自动弹出 → 3s 后消失 或 手动关闭 |
| 触发 | 进入成就页即渲染 | **任何页面**解锁成就时弹出 |

### 4.2 全局成就通知模块（Global Achievement Overlay）

**问题**：当前成就弹窗只在 `review_screen.dart` 里实现，对话、制卡、计划等页面即使触发了成就也看不到。

**方案**：把成就通知提升为**全局能力**，通过 Riverpod + Overlay 实现跨页面复用的弹窗系统。

```
                    ┌──────────────────────────┐
                    │   app.dart (最外层)        │
                    │   ┌────────────────────┐  │
                    │   │ AchievementOverlay │  │  ← 全局 Overlay，监听队列
                    │   │   (特效卡渲染)      │  │
                    │   └────────┬───────────┘  │
                    │            │ 监听         │
                    │   ┌────────▼───────────┐  │
                    │   │ achievementNotifier │  │  ← Riverpod StateNotifier
                    │   │   pending: Queue    │  │     维护待展示队列
                    │   │   push() / dismiss()│  │
                    │   └────────▲───────────┘  │
                    └────────────┼──────────────┘
                                 │
        ┌────────┬───────────────┼───────────────┬────────┐
        │        │               │               │        │
   review    chat          card_create        plan     home
  _submit   _submit        _submit           _done    _init
    │          │               │               │        │
    └──────────┴─────── 任何 API 返回 new_achievements ──┘
                        → push 到全局队列
                        → Overlay 自动弹出特效卡
                        → 3s 后自动消失（支持多成就排队）
```

**技术要点**：

| 组件 | 职责 | 关键实现 |
|------|------|----------|
| `achievement_notifier.dart` | 队列管理 | `pending: Queue<Achievement>`，支持排队逐个展示 |
| `achievement_overlay.dart` | 特效卡渲染 | 入场动画（缩放弹跳）+ 分级光效 + 粒子撒花 + 自动消失 |
| `app.dart` | 挂载 Overlay | 在最外层 `MaterialApp` 的 `builder` 中插入 |
| 各业务页面 | 发数据 | API 返回 `new_achievements: [...]` → `notifier.push()` |

**特效卡动画设计**：

```
时间轴: 0ms        300ms        800ms       2500ms      3000ms
        │           │            │           │           │
        ├─ 入场动画 ─┤            │           │           │
        │  缩放0→1  │  卡片就位   │           │           │
        │  弹跳曲线  │            ├─ 分级光效 ─┤           │
        │           │            │  青铜绿光  │           │
        │           │            │  黄金金光  │           │
        │           │            │  钻石彩虹  │           │
        │           │            │           ├─ 自动消失 ─┤
        │           │            │           │  fadeOut   │
        └───────────┴────────────┴───────────┴───────────┘
         ┌─ 粒子撒花 (confetti) ─┐
         同步触发，持续 ~1500ms
```

### 4.3 前端改动汇总

| 模块 | 文件 | 改动 |
|------|------|------|
| 全局通知 | **新建** `achievement_notifier.dart` | Riverpod StateNotifier，维护成就展示队列 |
| 全局通知 | **新建** `achievement_overlay.dart` | 特效卡 Overlay widget（入场动画 + 粒子 + 自动消失）|
| 全局通知 | `app.dart` | 在 MaterialApp builder 中挂载 AchievementOverlay |
| 图标映射 | **新建** `shared/achievement_icons.dart` | `achievementIcon()` + `achievementColor()` 函数（不用 const Map） |
| 成就页面 | `achievements_screen.dart` | 数据驱动图标渲染 + 分类 Tab + 进度条 + 分级显示 |
| 复习页面 | `review_screen.dart` | `_showAchievementDialog` → 改为调用 `notifier.push()` |
| 对话页面 | `chat_screen.dart` | **新增** 对话结束返回 `new_achievements` 时调用 `notifier.push()` |
| 成就 API | `api/chat_client.dart` | `getAchievementsAll()` 接口客户端（GET /api/user/{user_id}/achievements-all） |

### 4.4 特效卡可行性分析

**Flutter 技术可行性**：✅ **完全可以实现**

| 效果 | Flutter 实现方式 | 依赖 |
|------|-----------------|------|
| 缩放弹跳入场 | `AnimationController` + `Tween(begin: 0.0, end: 1.0)` + `Curves.elasticOut` | 无额外依赖 |
| 分级光效（青铜绿/黄金金/钻石彩虹） | `BoxDecoration` + `Border` + `BoxShadow` 不同颜色 | 无额外依赖 |
| 粒子撒花 | `confetti` 包 或 自绘 `CustomPainter` | `confetti: ^0.7.0`（可选） |
| 自动消失 + 下一个 | `Timer` + `Queue` 轮转 | 无额外依赖 |
| 图标动画（旋转/脉冲） | `AnimationController` + `Transform.rotate` / `ScaleTransition` | 无额外依赖 |

**性能考量**：
- 特效卡只在弹窗时渲染，无持续开销
- 粒子效果限制在 50 个以内，避免 GPU 负担
- 弹窗期间底层页面不重建（Overlay 机制保证）

---

## 五、实施路径（修订后）

```
Phase 0: 全局通知模块（前端先行，用户立刻可感知）
  ── 新建 achievement_notifier.dart + achievement_overlay.dart
  ── app.dart 挂载全局 Overlay
  ── 新建 shared/achievement_icons.dart（函数式图标映射，避免 const Map 跨文件崩溃）
  ── 改 review_screen.dart 接入全局通知
  ── 改 chat_screen.dart 接入全局通知
  ── 成就图标彩色渲染（Icon widget 替代 Text emoji）
  状态：✅ 已完成 (2026-06-06)

Phase 1: 数据驱动底座（后端）
  ── 建 backend/achievements.toml（先平移现有 11 个成就）
  ── 建 AchievementEngine（TOML 加载 + 条件求值）
  ── API 从 TOML 读取 icon/color/name 并返回
  ── DB 不变（仍用现有 achievements 表，tier/source 列开始使用）
  状态：✅ 已完成 (2026-06-06)

Phase 2: 事件总线
  ── 定义事件类型枚举（card_created/conversation_ended/plan_completed/daily_tick/review_completed）
  ── 在各触发点加 achievement_engine::check(conn, event_type, user_id)
  ── Engine 改为事件驱动（check_on_event 按 triggers 过滤）
  状态：✅ 已完成 (2026-06-06)

Phase 3: 前端成就页面改版
  ── 6 大分类 Tab 布局
  ── 进度条展示（调用 /api/user/{user_id}/achievements-all）
  ── 分级色彩系统（青铜→钻石）
  ── 隐藏成就红点提示
  状态：✅ 已完成 (2026-06-06)，Phase 6 清理了重复图标/颜色映射

Phase 4: 40+ 成就扩展
  ── 在 TOML 里批量添加新成就
  ── 加新 metric 查询（recent_accuracy_50 等）
  ── 前端分类 Tab + 进度条走通全链路
  状态：✅ 已完成 (2026-06-06)

Phase 5: DB 查询实现
  ── build_context() 新增 17 个 SQL 查询
  ── ComparisonEvaluator 扩展至 23 个 metric
  ── compute_progress() 全量进度计算
  状态：✅ 已完成 (2026-06-06)

Phase 6: WS 成就通知 + 前端清理
  ── ws.rs 每轮 done 后推送新成就到前端
  ── WsEvent 模型扩展 achievements 字段
  ── chat_screen 接入全局成就通知
  ── 前端成就页面清理重复映射，统一使用 shared 模块
  状态：✅ 已完成 (2026-06-06)

Phase 7: 事件总线规范化 + Confetti 粒子特效
  ── 定义 AppEvent enum（5 个 variant：CardCreated/ReviewCompleted/ConversationEnded/PlanCompleted/DailyTick）
  ── 实现 publish() 入口替代直接字符串调用
  ── 更新 3 个调用点（ws.rs, plan_handler.rs）使用 AppEvent
  ── 前端 achievement_overlay.dart 实现 CustomPainter confetti 粒子撒花（40 粒子，1.5s 生命周期）
  状态：✅ 已完成 (2026-06-06)
```

---

## 七、实施完成总结

| 原问题 | 状态 | 实现方式 |
|---|--------|----------|
| 1 仅 11 个成就 | ✅ | TOML 扩展至 41 个 |
| 2 硬编码 HashMap | ✅ | achievements.toml 数据驱动 |
| 3 条件引擎只支持 >= | ✅ | gte/lte/eq/gt/lt + AND/OR |
| 4 只复习提交触发 | ✅ | 5 触发点 + WS done 推送 |
| 5 Context 只有 4 字段 | ✅ | 24 字段 + 按需 SQL 查询 |
| 6 无分类/进度 | ✅ | 7 分类 Tab + 进度条 + 分级色彩 |
| 7 emoji 图标 | ✅ | Material Icons + TOML 配置 |
| 8 tier/source 未使用 | ✅ | tier 用于分级展示，source→category |

### 最终实现架构

```
backend/achievements.toml    ← 41 个成就定义（唯一真理源）
backend/crates/api_server/src/achievement_engine.rs  ← AppEvent 事件总线
backend/crates/growth_engine/src/achievements.rs        ← 条件求值引擎
app/lib/providers/achievement_notifier.dart      ← Riverpod 队列管理
app/lib/widgets/achievement_overlay.dart        ← 特效卡 + confetti 粒子
app/lib/screens/achievements_screen.dart       ← 7 分类 Tab + 进度展示
```

### 触发点覆盖

| 触发点 | 实现位置 | 事件类型 |
|---------|-----------|----------|
| 制卡后 | ws.rs:585 | `AppEvent::CardCreated` |
| 对话结束后 | ws.rs:687 | `AppEvent::ConversationEnded` |
| 计划完成后 | plan_handler.rs:215 | `AppEvent::PlanCompleted` |
| 复习提交后 | routes.rs:290 | `check_daily` (DailyTick) |
| 每日定时 | routes.rs:1152 | `check_daily` (DailyTick) |
| WS done 轮次后 | ws.rs:408 | `engine.check_and_persist()` (全量检测) |

---

## 七、参考：TOML 与 API 约定

### TOML 成就定义规范

```toml
[achievements.first_card]
category = "seed"          # 六大分类之一
tier = "bronze"           # bronze/silver/gold/platinum/diamond
name = { zh = "初识", en = "First Step" }
description = { zh = "...", en = "..." }
icon = "auto_stories"       # Material Icons 名称
color = "#FFC107"           # 分级/分类主色
conditions = [              # 条件列表（默认 AND）
  { metric = "total_cards", op = "gte", value = 1 }
]
condition_logic = "OR"       # 可选，默认 AND
triggers = ["card_created", "review_completed"]
```

### triggers 与事件总线对应关系

| triggers 值 | AppEvent variant | 触发位置 |
|-------------|----------------|-----------|
| `card_created` | `AppEvent::CardCreated` | ws.rs（制卡后） |
| `review_completed` | `AppEvent::ReviewCompleted` | routes.rs（复习提交后，通过 check_daily 间接触发） |
| `conversation_ended` | `AppEvent::ConversationEnded` | ws.rs（对话结束后） |
| `plan_completed` | `AppEvent::PlanCompleted` | plan_handler.rs（计划完成后） |
| `daily_tick` | `AppEvent::DailyTick` | routes.rs（每日定时，带 24h 冷却） |

### 新增成就步骤

1. 在 `achievements.toml` 添加 `[achievements.XXX]` 段落
2. 若使用新 metric → `build_context()` 加 SQL 查询，`ComparisonEvaluator` 加 arm
3. 若新触发点 → 定义新 `AppEvent` variant，`publish()` 加 match arm，`TOML` 配置 `triggers`
4. `cargo check` + `cargo test -p growth_engine`
5. 部署：上传 `achievements.toml` + 重启服务
