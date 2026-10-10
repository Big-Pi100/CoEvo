# 「我的」页学习记录 + 成就 不同步 · 根因（2026-10-10）

> 触发：白哥「书库同步已经OK。但是**在我的页面的学习记录和成就没有同步**」
> 状态：🔴 **只调查，未改任何代码**

---

## 〇、一句话

**两个根因叠加**：

1. 🔴 **主因（明确的 bug）**：成就/统计的**快照 provider 没订阅修订号** ⇒
   同步拉回的数据**确实落库了**，但**快照永不重算** ⇒ 显示的是「进入 App 那一刻」的旧值
   ⇒ 在新设备上就是**全 0**。
2. 🔴 **次因（数据源缺失）**：`lookup_event`（查词事件）是**纯端侧表**（服务端**没有**）⇒
   「查词次数 / 1 小时峰值」在新设备**永远 0**（涉及 **4 个成就**）。

⚠️ 根因 1 与**上一轮修的「收藏要重开才刷」是完全同类的 bug** ——
而那次我**只看了「6 类同步数据」的读端，没有穷举**（本报告 §四 已补上穷举）。

---

## 一、两者是什么、数据从哪来

### 都是**端侧计算**（服务端接口 2026-09-29 已退役）

`routes.rs` 原文：

```
// 🔴 2026-09-29 已退役：/api/user/*/achievements-all · plan-achievements
//    （表 achievements 已删；**成就改为「端侧计算」**）
// 🔴 2026-09-29 已退役：学习报表（learning-report / activity / weekly-report）
```

⇒ 「我的」页顶部**统计卡**（连续天数 / 掌握词数 / 阅读篇数）与**成就墙**，
**共用同一次采集**：`achievementSnapshotProvider` → `AchievementService.collectMetrics()`。

### 采集的 9 个指标分别依赖哪张表（这是关键）

| 指标 | 依赖表 | 云端有吗 | 新设备应当 |
|---|---|---|---|
| `totalWords`（掌握词数）| `user_word` | ✅ 46 行 | ✅ 正确 |
| `totalReviews`（复习次数）| `review_log` | ✅ 139 行 | ✅ 正确 |
| `articlesRead`（阅读篇数）| `article_read` | ✅ 46 行 | ✅ 正确 |
| `recentAccuracy50` | `review_log` | ✅ | ✅ 正确 |
| `streakDays` / `maxGapDays` / `nightSessions` / `earlySessions` | `review_log` | ✅ 10 天 | ✅ 正确 |
| `matureCards`（成熟卡）| `card_review_state` | ❌ 无（**派生态**，靠 `review_log` 重放重建）| ⚠️ 重放后**可恢复** |
| `lookupCount`（查词次数）| **`lookup_event`** | ❌ **无** | ❌ **永远 0** |
| `lookupsIn1h`（1h 峰值）| **`lookup_event`** | ❌ **无** | ❌ **永远 0** |

**线上实测**（该账号）：

```
sync_review_log   139 行（10 个不同日期）· sync_user_word 46 · sync_article_read 46
sync_bookmark       3 · sync_highlight 1
服务端**没有** lookup_event / achievement_unlock / card_review_state   ← 全是纯端侧表
```

⇒ **大部分指标依赖的表都已同步** —— 所以它们**本该是正确**的。

---

## 二、根因 1（主因）：快照**永不重算**

```dart
// providers/achievement_provider.dart
final achievementSnapshotProvider =
    FutureProvider<AchievementSnapshot>((ref) async {
  final db = await ref.watch(userDbProvider.future);   // ← 🔴 只 watch「库实例」
  return AchievementService(db).snapshot(now: DateTime.now());
});
```

| 事实 | 后果 |
|---|---|
| 它是 `FutureProvider`（注释明确写「**不 autoDispose**」）| 求值一次后**长期缓存** |
| 它 watch 的是 `userDbProvider`（**库实例**）| 库实例在 App 生命周期内**不变** ⇒ **永不重建** |
| **没有** `ref.watch(userDbRevisionProvider)` | 同步 `bump()` 后**它不会重算** |

⇒ **同步数据落库了，但快照不动** ⇒ 界面显示「进入 App 那一刻」的值。
⇒ 在一台**新装的设备**上，那一刻本地几乎什么都没有 ⇒ **看起来就是「完全没同步」**。

📌 这与**上一轮修的 `bookmark_provider`（收藏要重开才刷）是同一个 bug**：
**「`bump` 只在读端也订阅时才有效」** —— 而这里连订阅都没有。

---

## 三、根因 2（次因）：`lookup_event` **不在同步清单里**

`lookup_event` 是「**划词查词**」写下的行为记录（`article_read_repository.dart` 明确：
「**划词查词**时写 `lookup_event`，打开/读完文章不产生任何记录」）。

- **端侧**：它是 `user.db` 的一张表（`local_data_owner.dart:98` 把它列为「换账号要清」= 行为数据）
- **服务端**：🔴 **根本没有这张表**（`grep lookup_event backend/` 0 命中）
- **同步清单**（`sync_handlers.rs` 只有 7 类）：`review_events` · `user_words` · `article_reads` ·
  `bookmarks` · `highlights` · `book_progress` · `books` —— **没有 lookup_event**

⇒ 「查词次数」与「1 小时查词峰值」在**任何新设备上永远是 0**（**除非那个记录在新设备上重新产生**）。

**影响面**：`achievement_rules.dart` 里 **3 个成就**直接由 `lookupCount` 驱动（L333/343/353）
＋ 1 个由 `lookupsIn1h` 驱动 ⇒ 共 **4 个成就**在新设备上**解锁不了**。

---

## 四、🔑 穷举检查（补上上一轮的遗漏）

上一轮修 `bookmark_provider` 时，我只看了「6 类同步数据的读端」——
**这次按判据穷举**：`读了 user.db 但没订阅 revision` 的文件共 7 个，逐个判：

| 文件 | 读什么 | 需要订阅吗 | 判定 |
|---|---|---|---|
| **`providers/achievement_provider.dart`** | `review_log` / `user_word` / `lookup_event` / `card_review_state` 做展示 | ✅ **需要** | 🔴 **确认为 bug** |
| `providers/book_provider.dart` | `book` 表（**book.db**）| — | ✅ 它订阅的是 `bookDbRevisionProvider`，正常 |
| `providers/review_session_provider.dart` | 经 Repository 读（`cardBundleProvider` 是 **autoDispose**，逐卡重算）| ❌ 不需要 | ✅ 正常 |
| `providers/user_word_provider.dart` | 返回**仓储实例**（不是数据）| ❌ 不需要 | ✅ 正常 |
| `providers/auth_provider.dart` | `local_meta.owner_user_id`（归属判定）| ❌ 不需要 | ✅ 正常 |
| `providers/translate_provider.dart` | 翻译缓存（本地读写）| ❌ 不需要 | ✅ 正常 |
| `services/sync_service.dart` | **写入方**（同步自己）| ❌ 不需要 | ✅ 正常 |

⇒ **只有 `achievement_provider` 一处是真 bug** ✅（不是「还有一批」）。

---

## 五、修法

### P0（主因 · 1 行 · 立刻有效）

`achievementSnapshotProvider` 加 `ref.watch(userDbRevisionProvider);`
—— 与 `bookmark_provider` / `review_list_provider` 同款接法，**同一判据**。

⇒ 修完立刻恢复：**掌握词数 = 46 · 复习次数 = 139 · 阅读篇数 = 46 · 连续天数**（按 10 天数据算）
· 成熟卡（`review_log` 重放后）。

### P1（次因 · 「查词次数」怎么办 · **需要你定**）

| | 做法 | 代价 |
|---|---|---|
| **A** ⭐ | **同步 `lookup_event`**（新增第 8 类同步数据：端侧 merge/push/pull + 服务端新表）| 改动最大，但**语义完整**（「查词次数」是真实学习行为）|
| **B** | **用已有数据近似**：用 `user_word` 的 **首次查词时间**（`MIN(looked_up_at)`）或行数代替 | 小改动，但**口径不同**（生词本行数 ≠ 查词次数）⇒ 会显示**不准的数** |
| **C** | 接受它在新设备归零，**界面上如实说明**（如「查词统计仅本机」）| 最小，但用户会看到**解锁不了的成就**（等于坏体验）|

📌 我倾向 **A**（与其他 7 类是同一件事，且它确实是「学习记录」的一部分）；
但它是**新增一类同步数据**，改动面与风险都明显更大 —— **你定**。

---

## 六、请示

1. **P0 修吗？**（1 行，与收藏那处同款）—— 我建议**做**，它能让绝大部分数字立刻正确。
2. **P1 的「查词次数」选 A / B / C？**（我推荐 A，但要你拍板投入）

批准后我按老流程走：**先写断言并逐条证伪 → 改码 → 本地全验 → 报出包**。
（两处都是端侧改动，**不涉及服务端**；P1 若选 A 才会涉及服务端新表。）

---

*2026-10-10 · 方法：`routes.rs` 查退役记录（确认「端侧计算」）→ 读 `achievement_service` 的
9 个指标逐一定位依赖表 → 与 `sync_handlers.rs` 的 7 类同步清单**逐条比对** →
线上只读实测云端行数 → **穷举**「读 user.db 但未订阅 revision」的 7 处并逐个判定*
