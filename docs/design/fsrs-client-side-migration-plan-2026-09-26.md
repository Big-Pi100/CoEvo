# FSRS 调度移至端侧 · 设计方案

> 2026-09-26 ｜ 依据白哥 6 项决策 | 配套审计 `fsrs-rating-and-scheduler-audit-2026-09-26.md`
> **✅ 本方案已全部批准（2026-09-26 白哥「同意」）** —— 含 §五 同步方案与 §十 全部待定项，见文末「§十一 决策记录」。

---

## 一、白哥决策（2026-09-26）

| # | 决策 | 落地影响 |
|---|---|---|
| 1 | **调度放端侧** | 回到 v1 §10.1「本地计算」；后端退为同步/存储 |
| 2 | **端侧用 Dart 包** | 依赖 `fsrs: ^2.0.1`（pub.dev） |
| 3 | **按钮显示「下次 X 天」** | 界面稿 v6 已加；**列表页也要显示到期时间**（白哥指出：按 FSRS 排序却没有时间，排序无依据） |
| 4 | `Good` 译名「一般」→「**记得**」 | 界面稿 v6 已改 |
| 5 | 按钮英文副标题**保留** | `again/hard/good/easy` 保留 |
| 6 | **四档单调性单测强制** | 见 §七 |

---

## 二、技术验证（已实测，非推测）

### 2.1 依赖可用 ✅

```
> dart pub get          （Dart 3.6.2）
Resolving dependencies...
+ fsrs 2.0.1
+ meta 1.19.0
Changed 2 dependencies!
```

| 对比 | 依赖数量 |
|---|---|
| 官方 Rust crate `fsrs`（fsrs-rs） | 🔴 **474 个包**（含 `burn` 深度学习框架） |
| **Dart 包 `fsrs`** | ✅ **2 个**（fsrs + meta） |

**与项目 SDK 约束兼容**：`app/pubspec.yaml` 声明 `sdk: ">=3.6.0 <4.0.0"`，本机 Dart 3.6.2 → ✅ 解析通过。

### 2.2 API 确认（2.0.1 实际签名）

```dart
enum State   { learning(1), review(2), relearning(3) }
enum Rating  { again(1), hard(2), good(3), easy(4) }   // ← 与界面稿按钮一致

class Scheduler {
  Scheduler({
    List<double> parameters = <21 个权重>,
    double desiredRetention = 0.9,
    List<Duration> learningSteps   = [1min, 10min],
    List<Duration> relearningSteps = [10min],
    int  maximumInterval = 36500,
    bool enableFuzzing = true,
  });
  ({Card card, ReviewLog reviewLog}) reviewCard(Card card, Rating rating, {DateTime? reviewDateTime, int? reviewDuration});
  double getCardRetrievability(Card card, {DateTime? currentDateTime});
  Map<String, dynamic> toMap();  static Scheduler fromMap(...);
}

class Card {
  int cardId; State state; int? step; double? stability; double? difficulty;
  DateTime due; DateTime? lastReview;
  Map<String, dynamic> toMap();  static Card fromMap(...);  Card copyWith({...});
}
```

🔴 **两条硬约束**：
1. **只支持 UTC** —— README 明确「Dart-FSRS uses UTC only」，非 UTC 的 `reviewDateTime` 会 **throw ArgumentError**
2. **`reviewCard()` 内部先 `copyWith()`，不改原卡** → ✅ **这正是「四档预览」的实现基础**

### 2.3 预览四档 = 对四个 rating 各调一次（无需额外 API）

```dart
// 按钮上的「下次 X 天」这样算 —— 纯函数式，不动原卡
Map<Rating, Duration> previewIntervals(Card card, DateTime nowUtc) => {
  for (final r in Rating.values)
    r: scheduler.reviewCard(card, r, reviewDateTime: nowUtc)
                .card.due.difference(nowUtc),
};
```

### 2.4 ✅ 实测：两个 bug 在 Dart 包中都不存在

**单调性**（原实现 4 个测试点全反）：

```
毕业后的成熟卡    again=10 分钟   hard=2.2 月   good=5.3 月   easy=11.6 月   ✅ 单调
复习 3 次的卡     again=10 分钟   hard=21 天    good=1.5 月   easy=3.5 月    ✅ 单调
全新卡            again=1 分钟    hard=5 分钟   good=10 分钟  easy=19 天     ✅ 单调
```

**elapsed 敏感性**（原实现完全无关）：

| 距上次复习 | Good → 下次 | 稳定性 S |
|---:|---|---:|
| 1 天 | 12 天 | 11.94 |
| 9 天 | 1.1 个月 | 29.81 |
| 30 天 | 1.9 个月 | 56.01 |
| **365 天** | **4.5 个月** | **134.75** |

**retrievability**：距上次 1 天 R=0.985 · 9 天 **R=0.900**（正好 = `desiredRetention`）· 30 天 0.787 · 90 天 0.661 ✅

### 2.5 完整演进序列（连续评 Good，关 fuzz 取确定值）

| 第几次 | S | 忘了 | 困难 | 记得 | 熟练 |
|---:|---:|---|---|---|---|
| 新卡 | — | 1 分钟 | 5 分钟 | 10 分钟 | 19 天 |
| 1 | 3.26 | 1 分钟 | 10 分钟 | 4 天 | 8 天 |
| 2 | 3.54 | 10 分钟 | 6 天 | 14 天 | 1.1 个月 |
| 3 | 13.73 | 10 分钟 | 21 天 | 1.5 个月 | 3.5 个月 |
| 4 | 45.23 | 10 分钟 | 2.1 个月 | 4.4 个月 | 10.3 个月 |
| 5 | 134.55 | 10 分钟 | 6.1 个月 | 1.0 年 | 2.3 年 |
| 6 | 371.88 | 10 分钟 | 1.4 年 | 2.6 年 | 5.8 年 |

**界面稿 v6 用的数字来自这张表**（`disorganized` = 第 3 次那行，`laser` = 第 2 次那行）—— 不是编的。

---

## 三、参数取值

| 参数 | 建议值 | 理由 |
|---|---|---|
| `desiredRetention` | **0.9** | 官方默认；Anki 推荐 0.9 对多数人合适。可作**订阅权益**（「复习强度」可调 0.8–0.95）→ 见 §八 |
| `parameters` | **21 个默认值** | 不自行调参。将来有用户复习数据后，可在端侧用 `fsrs_dart`（另一包，含 `computeParameters`）做个性化优化 |
| `maximumInterval` | **365 天** ✅ **已定** | 官方默认 36500（100 年）。但实测连续评 Good **第 6 次就 5.8 年** —— 对「英语学习」场景等于「不再复习」。压到 1 年，用户一年后还会再见一次，符合学习产品预期 |
| `enableFuzzing` | **true** | 官方默认；避免复习堆积在同一天。⚠️ 但**界面稿显示间隔时应关掉 fuzz**（否则同一张卡两次显示不同数字，用户会困惑）→ 见下 |
| `learningSteps` | 🟠 **待定** —— 见 §3.1 | |
| `relearningSteps` | 🟠 同上 | |

### 3.1 🔴 `learningSteps` 是本方案唯一的体验陷阱

实测（点「忘了」后多久重来）：

| `learningSteps` | 新卡点「忘了」→ 下次 |
|---|---|
| `[1 分钟, 10 分钟]`（默认） | **1 分钟** ← 同一次复习会话内马上重现 |
| `[10 分钟]` | 10 分钟 |
| `[15 分钟]` | 15 分钟 |
| `[]`（禁用） | 🔴 **1 天** ← 用户以为「待会儿再考」，结果明天才来 |

**取舍**：

| 选项 | 同会话内重现？ | 体验 | 记忆效果 |
|---|---|---|---|
| A `[1分钟, 10分钟]` | ✅ 是（1 分钟后） | 🟠 打断「刷 23 张」的节奏，但卡会当场再考 | ✅ 好（Anki 哲学） |
| B `[10 分钟]` | 视会话长度而定 | 🟢 流畅 | 🟠 会话短则不会重现（10 分钟后用户可能已离开） |
| C `[]` | ❌ 否 | 🔴 「忘了」变 1 天，语义断裂 | 🔴 差 |

**我的建议：A + 一个前端规则** —— 保持 `[1分钟, 10分钟]`，并在复习会话内实现
**「评『忘了』的卡重新排入本次队列」**（Anki 标准行为）。
这样 1 分钟的 learning step 被会话队列自然消费，用户既能看到刚错的卡再考一次，也不至于突然闪回。

⚠️ **`[]` 绝对不能用** —— 它会让「忘了」变成「明天再来」，与按钮语义直接矛盾。

### 3.2 fuzz 与「显示间隔」的矛盾（需注意）

`enableFuzzing: true` 会让同一次计算的间隔带随机扰动。
**但四档预览必须在同一基准上比较** —— 若每次都 fuzz，用户会看到「困难 21 天」下次刷新变成「22 天」。

**建议**：
- **预览时用 `enableFuzzing: false` 的 scheduler 实例**（或固定种子 `Scheduler.customRandom` 看包是否支持）→ 数字稳定
- **实际提交时用 `enableFuzzing: true`** → 保留分散效果
- 后果：用户看到的「1.5 个月」与实际写入的 due 可能差 ±1 天。**可接受**（Anki 也这样）

🟠 **待核实**：2.0.1 的 `customRandom` 是否可用于预览确定性（工厂 `Scheduler.customRandom` 存在，签名待查）。

---

## 四、数据模型

### 4.1 端侧（`user.db`）

`Card.toMap()` 的字段直接落表：

| 字段 | 类型 | 说明 |
|---|---|---|
| `card_id` | TEXT PK | = 词库 `word_id` |
| `state` | INT | 0 未学 / 1 learning / 2 review / 3 relearning ← 映射 fsrs 包的 `State`（1/2/3）+ 本地 0 |
| `step` | INT NULL | learning/relearning 步 |
| `stability` / `difficulty` | REAL NULL | FSRS 状态 |
| `due` | TEXT | **UTC ISO8601**（🔴 必须 UTC） |
| `last_review` | TEXT NULL | UTC ISO8601 |
| `reps` / `lapses` | INT | 统计 |
| `pending_push` | INT | 待同步标记（v1 §10.1 原有设计） |

**另需本地 `review_log`**：`(id, card_id, rating, reviewed_at, device_id, synced)` ——
🟠 这是 §五 多端同步的基础，**不是可选的**。

### 4.2 服务端（`coevo.db`）

现有 `card_memory` 表字段基本够用（`state/due/difficulty/stability/reps/lapses/last_review`）。
🟠 **建议加 `last_device_id`**，用于冲突判定（见 §五）。

---

## 五、🔴 多端同步设计（本方案唯一新增设计点）

### 5.1 问题

v1 原本「**单端登录，踢旧**」，后来改为**多端登录**。
端侧算 FSRS 后出现了新问题：**两台设备各自算，状态会分叉。**

FSRS 的状态是**复习序列的函数** —— 同样的卡片，设备 A 评「记得」、设备 B 评「困难」，两边算出的 `(S, D, due)` 都不同。

### 5.2 三个选项

| # | 方案 | 做法 | 一致性 | 复杂度 |
|---|---|---|---|---|
| **1** | **事件日志 + 重放**（推荐） | 只同步**评分事件**（`card_id, rating, reviewed_at, device_id`）；任一设备拉取后**按时间序重放**得到权威状态 | ✅ **精确一致** | 🟠 高（需重放逻辑） |
| **2** | 最后写入胜出 | 同步**结果快照**（`S/D/due/...` + 时间戳），冲突时取新 | 🟠 会丢一次复习 | 🟢 低 |
| **3** | 取「最早到期」 | 冲突时取 `min(due)` —— 保守（宁可多复习） | 🟠 保守但不对 | 🟢 低 |

**我推荐方案 1**，理由：

- **重放是纯函数、零成本**：`fsrs` 包的 `reviewCard` 是确定性的（关 fuzz 时），从初始卡重放 N 次即可
- **对单词卡场景，序列很短**（实测第 6 次就 5.8 年 → 单卡历史通常 < 10 条）
- **离线是一等公民**：v1 要求离线优先，事件日志天然支持「离线累积 → 联网合并」
- 方案 2/3 的「丢一次复习」在记忆算法里会**永久影响 `S`**（该次复习的稳定性增益消失）

**但方案 1 有一个必须解决的点**：**「同一天两台设备都复习了同一张卡」** ——
时间序合并后会出现「一天内两次复习」，导致 §3.1 提到的间隔暴涨（官方 same-day 分支正是为此）。
**处置**：合并时**同一天（UTC 日期）只保留最后一次**（或按 `desiredRetention` 重算当天净效果）。

### 5.3 ✅ 已定

| 项 | 决策 |
|---|---|
| 同步方案 | ✅ **方案 1：事件日志 + 重放** |
| 同日多端复习的合并规则 | ✅ **同一天（UTC 日期）只保留最后一次** |

**为什么「只保留最后一次」**：时间序全保留会出现「一天内两次复习」，使稳定性按两次增益叠加
→ 间隔虚高（这正是官方 `w17`/`w18` same-day 分支要处理的问题）。
取当天最后一次 = 「当天净效果」，语义清晰且与单端体验一致。

**实现要点**（重放）：
```
合并：按 (card_id, reviewed_at) 排序 → 同 UTC 日期去重（取最后）→ 逐条 replay
replay(card, events):
  for e in events:                       # 纯函数，无副作用
    card = scheduler.reviewCard(card, Rating.fromValue(e.rating),
                                reviewDateTime: e.reviewed_at).card
  return card                            # ← 权威状态
```
🔑 **重放是纯函数** → 任一端算出同一结果，**不需要「权威端」**，也不需要手写冲突合并。

---

## 六、后端 `fsrs5.rs` 的处置

| 选项 | 说明 | 建议 |
|---|---|---|
| **A. 删除** | 端侧权威，后端不算。`submit_review` 改为「只写 review_log + 更新状态快照」 | ✅ **已定：删除** —— 零数据（`card_memory` 0 行），删了最干净；避免「两处实现不一致」这个我们已经踩过的坑 |
| B. 保留但修正 | 修 §三 的 8 项偏差，作为「无端侧上报时的兜底」 | ❌ 双实现 = 双维护 + 长期会再次分叉 |
| C. 保留不动 | 后端继续算（但端侧不用） | ❌ 死代码 + 仍算错 |

**若选 A**，连带改动：
- `routes.rs` 的 `review_submit_handler`：不再调 `compute_next_state`
- `fsrs_scheduler.rs`：`submit_review` 的 FSRS 段移除；`record_implicit_review`（B2 隐式复习）也移到端侧
- `e2e_runner.rs` 的 `call_submit_review`：改为校验「状态写入」而非「FSRS 算出什么」
- 现有单测（`test_submit_review_updates_streak` 等）：改为不依赖 FSRS 数值

---

## 七、单测清单（白哥同意「强制」）

**为什么这条是强制的**：这个 bug 能存在，就是因为**没有任何测试断言过「四档单调」**。

| # | 断言 | 位置 | 强制 |
|---|---|---|---|
| 1 | **四档严格单调**：`again < hard < good < easy`（对 3 种状态：全新/学习中/成熟） | Flutter（Dart） | ✅ |
| 2 | **elapsed 敏感性**：距上次 1 天 vs 365 天，Good 的间隔**必须不同**（且 365 天 > 1 天） | Flutter | ✅ |
| 3 | **同日不暴涨**：同一天连续评 Good 4 次，第 4 次间隔 < 第 1 次的 10 倍 | Flutter | ✅ |
| 4 | **「忘了」语义**：评 again 后 `due - now < 1 天`（不能是 1 天以上） | Flutter | ✅ |
| 5 | **UTC 断言**：传入非 UTC 的 `reviewDateTime` 必须抛错（防线上踩坑） | Flutter | ✅ |
| 6 | **R 值**：刚复习完 `getCardRetrievability ≈ 1.0`；距 = S 天时 ≈ `desiredRetention` | Flutter | ✅ |
| 7 | 预览不改原卡：调用 `previewIntervals` 后原 `Card` 的 `due/stability` 不变 | Flutter | ✅ |
| 8 | 同步幂等：同一批事件重放两次，结果一致 | 后端/端侧 | 🟠 |

**关键**：1–4 是**回归防线** —— 它们能直接拦住本次审计发现的两个 bug。

---

## 八、连带发现与决策

| # | 项 | 决策 |
|---|---|---|
| 1 | **`maximumInterval` 压到 365 天** | ✅ **已定：压到 365 天** —— 实测第 6 次复习就排到 5.8 年，对「英语学习」等于「不再复习」。Anki 默认 100 年，但语言词卡常压到 1 年 |
| 2 | **「复习强度」是否作订阅权益** | ✅ **已定：不作权益**，`desiredRetention` 固定 0.9 —— 它是**基础体验**，且与「免费层完整闭环」的定位冲突 |
| 3 | **端侧参数优化** | 🟠 **将来可做**（`fsrs_dart` 含 `computeParameters()`，可用用户自己的复习日志训练个性化参数）—— 需先有真实复习数据 |
| 4 | **列表页排序的另外两个因子** | 🟠 **尚未设计** —— v1 §10.2 说「综合考虑 FSRS 到期时间 + **阅读中出现频率** + **错误类型权重**」，当前只实现到期时间。**不阻塞**，但要在文档里标为未实现（避免又被当成"已实现"） |

---

## 九、实施步骤

**✅ 已批准按序执行（2026-09-26）。** 步 1–6 与 7/8 的同步决策无依赖 → **先做 1–6**。

| 步 | 内容 | 依赖 | 状态 |
|---|---|---|---|
| 1 | `app/pubspec.yaml` 加 `fsrs: ^2.0.1` | — | ✅ 已做 |
| 2 | 写 `FsrsService`：封装 `Scheduler` + `previewIntervals` + UTC 强制 | 步 1 | ✅ 已做 |
| 3 | 端侧 `user.db` 表结构（`card_review_state` + `review_log`） | — | ✅ 已做 |
| 4 | 复习页：按钮显示预览间隔、评分后更新本地 | 步 2,3 | 🔴 **实际是「重写」不是「接入」** —— 见 §十一 |
| 5 | 列表页：到期时间 + 排序 + 分组 | 步 3 | 🔴 同上 |
| 6 | **单测（§七 1–7）** | 步 2 | ✅ 已做（`scripts/fsrs_verify/`） |
| 7 | 同步协议（事件日志 + 重放） | 步 2 | ⏳ 待做 |
| 8 | 后端 `fsrs5.rs` 删除 | — | ⏳ 待做 |
| 9 | 阅读器 B2 隐式复习移到端侧 | 步 2 | ⏳ 待做 |

---

## 十、决策记录（2026-09-26 白哥「同意」）

| # | 事项 | 决策 |
|---|---|---|
| 1 | **多端同步方案** | ✅ **方案 1：事件日志 + 重放** |
| 2 | **同日多端复习合并规则** | ✅ **同一天（UTC）只保留最后一次** |
| 3 | `learningSteps` | ✅ **`[1 分钟, 10 分钟]` + 前端「again 的卡重排入本次队列」** |
| 4 | `maximumInterval` | ✅ **365 天** |
| 5 | 后端 `fsrs5.rs` | ✅ **删除** |
| 6 | 实施顺序 | ✅ **先做步 1–6** |
| 7 | 「复习强度」作订阅权益 | ✅ **不作** —— 固定 `desiredRetention = 0.9` |
| 8 | 按钮译名 / 英文副标题 | ✅ 「记得」· **英文保留** |
| 9 | 四档单调性单测 | ✅ **强制** |

---

## 十一、🔴 实施中发现的关键偏差（工作量会偏，必须报告）

**原方案步 4/5 写的是「复习页接入」「列表页接入」，暗示是增量改造。实施前核实发现：实际是「重写」。**

### 11.1 实测现状

| 文件 | 行数/大小 | 当前是什么 | 与 v1 目标的关系 |
|---|---:|---|---|
| `app/lib/screens/review_screen.dart` | 61 KB | **旧的 K12 概念卡 + AI 验证** —— 含 `_preloadAiQuestions` / `_startInlineAiQuiz` / `_judgeInlineAnswers` / `_checkAndShowCampaign` / `_loadPlans` | ❌ **毫无关系** —— 没有翻卡、没有自评四档、没有到期时间、没有单词卡 |
| `app/lib/widgets/review_card_widget.dart` | 30 KB | **Web Speech API（`__coeStart/__coeStop`）+ `dart:html`** 的翻转卡 | ❌ 需重写 |
| 端侧本地 DB 层 | — | **不存在** —— `pubspec.yaml` **无 sqflite / sqlite 依赖** | ❌ 从零建 |

**两个文件都 `import 'dart:html'`** → **原生 App 无法编译**（这是 v2 §19 已列出的既有技术债）。

### 11.2 为什么这是「重写」而非「接入」

v1 目标的复习页是：**单一列表（搜索 + 三档排序 + 熟度三点）→ 点入翻卡 → 四段卡片 → 自评四档 → 自动下一张**。
其数据来源（词库 `word.db` + `FsrsService`）、交互模型（翻卡自评）、UI 结构（四段卡片）**与现有 61 KB 页面没有可复用的部分** ——
现有页面是「K12 学习计划 + 概念卡 + AI 问答判分」，**业务模型完全不同**。

`ui-ux-refactor-assessment` §6.2 也这样定性：`review_screen.dart` 1,537 行 → **「改造为单一列表页」**，
`review_card_widget.dart` 847 行 → **「大幅简化」**（移除 AI 验证链路）。

### 11.3 工作量重新估算

| 项 | 方案原写法 | **实际** |
|---|---|---|
| 步 4 复习页 | 「接入」（未估时） | 🔴 **重写** ≈ 800–1,200 行（列表页 + 翻卡 + 四段卡 + 四档按钮含间隔） |
| 步 5 列表页 | 「接入」 | 🔴 同上（含在步 4 内） |
| 本地 DB 层 | 未单列 | 🔴 **新建** ≈ 200–300 行（sqflite + 迁移 + 查询） |
| 去掉 `dart:html` | 未单列 | 🟠 复习两文件必须一并处理 |

**→ 结论：端侧实施的真实交付量 ≈ 1,000–1,500 行新代码 + 两个文件重写**，不是原方案读起来的那种「接两根线」。

### 11.4 🔴 两个验证障碍（需白哥知晓）

#### （1）本地无法验证 Flutter 代码

- 本地 Flutter 是**鸿蒙定制版**，`flutter analyze` 因 **Windows 管道耗尽崩溃**（已在多轮会话中反复出现）
- → 复习页重写这类 UI 代码**改完无法本地编译/跑测试**

#### （2）🔴 而且云端验证链路**也还不存在**

| 检查 | 结果 |
|---|---|
| `codemagic.yaml`（仓库根 / `app/`） | 🔴 **不存在** |
| 其他 CI 配置 | 🔴 **未发现** |

**→ 结论：「UI 重写后走 Codemagic 验证」这条路目前是断的** —— 需要**先建 Codemagic 配置**，
否则重写的 UI 代码**既不能本地验证、也不能云端验证**，等于盲改。

**按铁律「本地验证通过前禁止部署」**：在验证链路打通之前，**不应开始 UI 重写**。
（顺序应调整为：**建 Codemagic → 打通验证 → 再重写 UI**）

#### （3）现有测试会失效

`app/test/review_widget_test.dart`（32 行）测的是**旧** `ReviewScreen`
（断言「找到『复习』文字」+「有 AppBar」）→ **重写后必然失败**，需一并重写。

✅ **对比：本轮已完成的三项刻意做成纯 Dart，因此本地可验证** ——
依赖 / `FsrsService`（39 项断言）/ `user.db` schema（sqlite3 实测约束）。

---

## 十二、本轮已完成 vs 待做

| 步 | 内容 | 状态 | 证据 |
|---|---|---|---|
| 1 | `app/pubspec.yaml` 加 `fsrs: ^2.0.1` | ✅ | 已在 Dart 3.6.2 实测解析通过 |
| 2 | `app/lib/services/fsrs_service.dart`（纯 Dart） | ✅ | `verify_service.dart` **39 项全过** |
| 3 | `app/assets/sql/user_db_schema.sql` | ✅ | **sqlite3 实测**：建表 + CHECK + 幂等键 + 排序 |
| 6 | 单测 | ✅ | `scripts/fsrs_verify/`：`verify.dart` 19 项 + `verify_service.dart` 39 项 |
| 4/5 | 复习页 + 列表页 | 🔴 **受阻** —— 实际是「重写」，且**验证链路未通**（见 §11.4） |
| 7 | 同步协议（事件日志 + 重放） | ⏳ 服务层已实现 `replay()` / `merge()`，**网络协议未做** |
| 8 | 后端 `fsrs5.rs` 删除 | ⏳ 待做（已定决策） |
| 9 | B2 隐式复习移到端侧 | ⏳ 待做 |

---

*本文档为设计产出。步 1–3、6 已实施（均为纯 Dart，本地已跑通）；步 4/5 的重写方案待白哥确认后执行。*
*技术验证部分为实测（`dart pub get` + `dart run` 真实输出），非文档推算。*
