# 阶段一执行方案：退役后端「旧学习链」

> 2026-09-29 ｜ 触发：白哥「同意」（现在做减法）+ 成就方向取「**甲：端侧算**」
> 前置：`backend-db-refactor-assessment-2026-09-29.md`（路线评估）
> **本文只调查出方案，未改动任何数据/代码**
> 口径：对 `backend/data/coevo.db` · `data/coevo.db` · `backend/**/*.rs` · `app/lib/**` 的实测

---

## 〇、结论：工作量比报告预估**深一个量级**

评估报告 §五 写的是「阶段一 = 删 13 张表 + 清死路由」。
**实测依赖图后修正**：表不是孤立的 —— 它们背后是**后端一整套旧学习链**（2 个 crate + 7 个模块）。

| 旧链模块 | 规模 | 被谁用 |
|---|---|---|
| **`card_engine` crate**（FSRS 调度） | 5 文件 · `fsrs_scheduler.rs` **42 KB** | `routes.rs` 的 `/api/cards/*` · `ws.rs` |
| **`growth_engine` crate**（成就引擎） | `achievements.rs` **18 KB** | `achievement_engine` |
| `achievement_engine.rs` | API 层单例封装 | `profile`/`achievements` 接口 · `referral_handler` |
| `plan_handler.rs` | K12 学习计划（XML 解析） | `ws.rs` · `routes.rs` `/api/plans` |
| `review_handler.rs` | `/api/review/status` + `/api/review/defer` | `review_dialog`（chat 链） |
| `ws.rs` | WebSocket chat（Hot/ColdPath） | app `chat_client`（**无 UI 入口**） |
| `curriculum_admin.rs` | K12 课程后台 | admin 路由 |

→ 🔑 **删表 ⇒ 必须同时退役这些模块**。否则代码继续查已删表 → **静默降级**（本项目判据里的「主要敌人」）。

---

## 一、逐表依赖图（实测）

| 表 | 行数(`backend/data`) | 消费者 | 现役？ |
|---|---:|---|---|
| `conversations` | 16 | chat 链 · `ws.rs` · admin（guardian 学生对话） | ❌ 死（chat 无入口；guardian 属 K12） |
| `conversation_turns` | 154 | 同上 | ❌ 死 |
| `defer_queue` | 1 | `review_handler`（`/api/review/defer`） | ❌ 死 |
| `card_relations` | 0 | `curriculum_admin`（K12） | ❌ 死 |
| `user_language_cards` | 37 | `fsrs_scheduler` · `ws` · `routes` | ❌ 死链 |
| `user_science_cards` / `literature` / `humanities` | 0 / 2 / 11 | 同上 | ❌ 死链 |
| `debug_logs` | 0 | `config_admin`（admin 调试面板）· `debug_logger` · `ws` | ⚠️ 非用户功能 |
| `debug_trackers` | 0 | `config_admin` · `debug_trackers_cache` | ⚠️ 非用户功能 |
| **`user_cards`** | **4,998** | **`referral`（my_stats/portrait）· admin（用户面板）· `profile`（cefr_stats）** · `card_engine` · `achievement_engine` | 🔴 **有现役消费者** |
| **`card_memory`** | **4,998** | 同上 | 🔴 |
| **`review_log`** | **41** | **`referral` · admin · `share_data` · `achievement_engine`** | 🔴 |
| **`achievements`** | **92** | **`referral`（my_stats/portrait）· admin · `growth_engine` · `achievement_engine` · `profile`** | 🔴 |

**合计 10,350 行**（`data/coevo.db` 那份仅 3 行，是空骨架）。

---

## 二、🔑 三个关键事实（决定风险等级）

### 2.1 这些表在当前架构下**不会被写入**

- app 侧**无上报逻辑**：`grep '/api/review/sync'` → **0 命中**；端侧 `review_log.synced` 字段**只有定义、无使用**（`fsrs_service.dart:184/199/236`）
- 唯一写入口是后端自己的 `/api/review/submit` 等 —— 只被 `chat_client` 调，而 **chat 无 UI 入口**

→ 这些表是 **7 月内测留下的「冻结数据」**，不会随新用户增长。

### 2.2 所以「删表会破坏现役功能」这个担心**方向是反的**

现役接口读这些表，**对新用户早就返回空**（真实数据在端侧，后端没有）。
→ 功能**已经处于「静默降级」状态**。删表不是"弄坏它"，而是**把隐藏的失效变成显性**。

### 2.3 现役依赖只有 **3 处**（都不能只删表，必须改）

| 位置 | 读什么 | 给谁 |
|---|---|---|
| `referral_handler::my_stats` / `user_portrait` | `review_log × user_cards` · `achievements` | profile 页战绩 · 海报 · 分享卡 |
| `admin_handlers` 用户详情面板 | `user_cards × card_memory` · `review_log` | 运营后台 |
| `routes::profile_handler` | `user_cards × card_memory`（`cefr_stats`）· `achievements` | app `AchievementOverlay` |

✅ **注意（好消息）**：`my_stats` 里的 `available_commission`（支付页佣金抵扣）来自 **`distribution_commissions`**，
**不在这批表里** → **完全不受影响**。

---

## 三、分两批执行

### 批 1：零现役用户功能依赖 —— **建议立即做**

| 项 | 内容 |
|---|---|
| **表 10 张** | `conversations` · `conversation_turns` · `defer_queue` · `card_relations` · `user_{language,science,literature,humanities}_cards` ×4 · `debug_logs` · `debug_trackers` |
| **退役模块** | `card_engine`(crate) · `plan_handler.rs` · `review_handler.rs` · `ws.rs` · `curriculum_admin.rs` · `debug_logger.rs` · `debug_trackers_cache.rs` · `routes.rs` 的 `/api/cards/*`·`/api/review/*`·`/api/conversations/*`·`/api/plans` 接口 |
| **app 侧退役** | `chat_client.dart` · `chat_screen.dart` · `review_dialog.dart` · `pipelines/`（K12 遗留）· `/chat` 路由 |
| **同步** | `schema.rs`（建表/索引）· `main.rs`（init 调用）· `lib.rs`（路由注册） |

### 批 2：牵动 3 处现役 —— **需先定 1 个决策**

| 项 | 内容 |
|---|---|
| **表 4 张** | `user_cards` · `card_memory` · `review_log` · `achievements` |
| **决策** | 那 3 处现役消费者怎么办？ |

三个选项：

| # | 做法 | 代价 |
|---|---|---|
| **①** | **端侧算 + 上报**（与「甲」一致）：战绩/海报/成就都读端侧上报的摘要 | 需新表 + 新接口 → **属阶段二** |
| **②** | **直接删字段**：战绩/成就相关 UI 一并去掉，等「成就体系重新规划」重做 | 短期功能缺失（但本来就没数据） |
| **③** | **保留这 4 张不动**：数据冻结，不影响 | 留下"看起来像现役"的死表（违背减法初衷） |

---

## 四、我的建议

1. **批 1 立即执行** —— 方向无争议（chat 无入口 · K12 已清退 · 成就已定甲），**零现役影响**，且已备份可回滚
2. **批 2 暂缓** —— 它与待办「**成就体系重新规划**」是同一件事；且 `user_cards` 一族的 UI 影响面需先设计

---

## 五、待白哥决策

| # | 问题 | 我的建议 |
|---|---|---|
| **1** | **批 1 是否现在执行？**（10 表 + 模块退役，我分步做并逐步验证） | ⭐ 建议执行 |
| **2** | **批 2 的 3 处现役消费者选 ①②③？** | ⭐ 建议归入「成就体系重新规划」（阶段二） |
| **3** | **VPS 上是否留有旧库**（若曾部署过 7 月 MVP） | 需确认；本地删表不受影响 |

---

---

## 六、✅ 执行记录（2026-09-29 00:3x ~ 01:xx）

白哥决定：**批 1 + 批 2 一起做**（批 2 取 **②直接删字段**，战绩/成就 UI 去掉等重规划）·
**VPS「曾部署已停」且已释放** → 无 VPS 侧动作。

### 6.1 数据层：两库共删 **14 张表 / 10,350 行**

| 库 | 变化 | 自检 |
|---|---|---|
| `backend/data/coevo.db` | 3.31 MB → **614 KB** | 14/14 清除 · `foreign_key_check` 净 · `integrity_check` ok · 12 张保留表行数不变 |
| `data/coevo.db` | 426 KB → **274 KB** | 13/13（无 `defer_queue`）· 同上 |

- 脚本 `scripts/purge_coevo_legacy_chain.py`（幂等 · 自动备份 · 五项自检 · `--dry-run`/`--verify`）
- ✅ **与上一轮的关键差异**：实测**无「保留表 → 待删表」外键** → **可直接倒序 DROP，无需重建表**
  （上一轮因 `user_cards.prebuilt_card_id → prebuilt_cards` 必须先重建表）
- ⚠️ **脚本自身一个测量 bug（已修）**：VACUUM 后立即 `os.path.getsize` 读到**旧值** →
  误报「省 0.0 MB」（真实 3.3 MB → 614 KB）→ 改为 **`con.close()` 之后**测量

### 6.2 代码层：退役 **2 个 crate + 9 个模块 + 16 个函数/族**

| 项 | 规模 |
|---|---|
| 删 crate `card_engine`（后端 FSRS） | 1,317 行 |
| 删 crate `growth_engine`（成就引擎） | 528 行 |
| 删模块 `achievement_engine` / `plan_handler` / `review_handler` / `curriculum_admin` / `curriculum_loader` / `debug_logger` / `debug_trackers_cache` / `ws` / `e2e_runner` | 7,235 行 |
| 删 `routes.rs` 25 个旧链 handler | 1,548 行 |
| 删 `admin_handlers.rs` K12 guardian 一族 + assignment 管理 | 约 400 行 |
| 删 bin `e2e_pipeline_test` + 7 个 e2e 测试文件 | 2,959 行 |
| **后端合计** | **约 14,000 行** |
| app 侧：删成就 UI（`achievement_overlay` / `achievement_share_card` / `achievement_notifier`）+ 接线 | 778 行 |

**保留但改为恒 0 / null（结构兼容，数据诚实）**：
`admin_users_handler` · `admin_user_detail` · `admin_dashboard` · `admin_users_export` ·
`referral_handler::my_stats`（战绩部分）· `get_user_portrait_data` · `user_portrait` ·
`share_data::build_user_plan_stats` · `campaign_scheduler` 级联清理表清单（12 → 5 张）。

### 6.3 🔴 执行中发现的 3 个「静默陷阱」

| # | 陷阱 | 若不处理会怎样 |
|---|---|---|
| **1** | `main.rs` 启动守卫查 `users`/`user_cards`/`card_memory` —— 后两者退役后**守卫恒成立** | 每次启动都跑 `init_database` |
| **2** | `main.rs` 有**第二处内联 DDL**（`debug_trackers`/`debug_logs`），不在 `schema.rs` | 只改 `schema.rs` 仍会建回 |
| **3** | `admin_handlers.rs` 的 `guard_user!` 宏 / `BindLookupInput` 定义**紧邻** guardian 一族 | 按函数边界删除会**连带删掉**，编译才暴露 |

### 6.4 验证（全部通过）

| 验证 | 结果 |
|---|---|
| `cargo check --offline`（全 workspace） | ✅ **error 0 / warning 0** |
| `cargo check --tests` | ✅ 通过 |
| `verify_schema_no_wordcards.py`（25 张待删表） | ✅ 一张都不会被建出 · 12 张保留表全在 |
| **反向测试**（把 `review_log` 建表插回副本） | ✅ **正确报红**（退出码 1） |
| app `static_check`（`package:analyzer`） | ✅ **error = 0**（12 warning，多为既有 unused） |
| 两库数据自检 | ✅ 保留表行数不变 · 外键净 · 完整性 ok |

### 6.5 待办与遗留

- ⏳ **构建验证只能白哥跑**（`D://flutter//bin//flutter.bat`）—— 我这边 `flutter` 必崩
- ⚠️ **schema.rs 里已删表的注释记录保留**（决策史有价值），但**不要再照着它建表**
- ⏳ app 侧 `chat_client` / `chat_screen` / `review_dialog` / `pipelines/`（K12 遗留）**未删** ——
  ⚠️ `profile_screen.dart` 仍 import `chat_client`，删除会牵连**现役页面** → 需单独评估
- ⏳ `shared_types::growth`（成就类型定义）**保留**（现无消费者，待一并清理）
- 📌 **成就体系重新规划**（端侧实现）= 下一步工作项

*本文为调查产出，**未改动任何数据/代码**。*
