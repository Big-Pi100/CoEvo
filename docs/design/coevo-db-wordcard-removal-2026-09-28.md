# 清除 coevo.db 词卡库 —— 方案与风险评估

> 2026-09-28 ｜ 触发：白哥「coevo.db 里的**词卡库**应该清除，**只保留 VPS 在用的表**，维护两个词库既没有意义又容易互相污染」
> **本文只调查，未改动任何数据**（删表不可逆，待批）
> 口径：对 `data/coevo.db` · `backend/data/coevo.db` · 仓库全部 `.rs`/`.py` 的**本机实测**

---

## 〇、🔴 先纠正我上一轮的一个判断错误

我上一轮说「`data/coevo.db` 是**生产库**」—— **这是错的**，依据是 `.gitignore:102` 的注释。
实测两个库的用户数据后，真相相反：

| 库 | 大小 | 时间 | `users` | `user_cards` | `card_memory` | `payment_orders` | **身份** |
|---|---|---|---|---|---|---|---|
| **`backend/data/coevo.db`** | 20.1 MB | **07-15** | **91** | **4,998** | **4,998** | **8** | 🔴 **生产数据快照**（部署文档 scp 的就是这个） |
| `data/coevo.db` | 17.6 MB | 09-25 | 2 | 0 | 0 | 0 | 开发骨架（脚本读它） |

🔑 **教训（同既有判据）**：**注释/文档不是事实** ——
`.gitignore` 写「`/data/coevo.db` 是生产库」，但**真正有 91 个用户、4,998 张学习卡的是 `backend/data/`**。
→ 又一次「**读到的描述必须实测一遍才算数**」。

**顺带确认：两个 coevo.db 都「不在 git 里」**（`.gitignore:105` 与 `:153`）
→ 🔴 **没有版本回滚保护 → 删表前必须手工备份**。

---

## 一、三个 coevo.db（第三个在 VPS 上）

| # | 位置 | 用途 | 谁读它 |
|---|---|---|---|
| 1 | `backend/data/coevo.db` | 生产数据快照（部署源） | 部署脚本 `scp` |
| 2 | `data/coevo.db` | 开发骨架 | **所有 Python 脚本**（`load_llm_results.py` 等） |
| 3 | VPS `/opt/coevo/data/coevo.db` | **真实生产库** | 线上后端 |

⚠️ **所以「清除」需要明确「清哪个」** —— 三处影响完全不同（见 §五）。

---

## 二、「词卡库」的精确范围

按**数据性质**分四组（这是分类的核心，不是按表名）：

### A. 词卡**内容**数据（prebuilt 一族）—— 37,968 行

| 表 | `data/` 行数 | `backend/data/` 行数 |
|---|---:|---:|
| `prebuilt_cards` | 18,984 | 18,274 |
| `prebuilt_language_cards` | 16,564 | 15,364 |
| `prebuilt_science_cards` | 1,390 | ? |
| `prebuilt_literature_cards` | 836 | ? |
| `prebuilt_humanities_cards` | 194 | ? |

🔑 **这五张表才是「词库」**（＝ word.db 的**上游副本**）→ **白哥说的「两个词库互相污染」指的就是它**。
🔴 两库行数**不同**（18,984 vs 18,274）→ **确实已经是两份不一致的词库**，白哥的担心成立。

### B. 用户学习状态（名字像"词卡"，但**属用户数据**）

`user_cards`(4,998) · `card_memory`(4,998) · `user_language_cards`(37) · `review_log`(41) · `card_relations` · `user_science/literature/humanities_cards`

⚠️ **这些不能当"词库"删**：
- 它们是**用户的复习状态**（FSRS），删了 = **丢用户数据**
- 后端引用密集（`user_cards` 143 次 · `card_memory` 101 次 · `review_log` 69 次）
- 🔴 **待办清单里有「成就体系重新规划」** → 成就体系正要用 `user_cards` + `card_memory`

### C. K12 课程体系（不是"词库"，但也已清退）

`prebuilt_plans`(16) · `prebuilt_stages`(297) · `prebuilt_tasks`(1,241) · `plan_runs` · `user_plan_progress` · `k12_quiz_attempts` · `k12_quiz_bank` · `guardian_assignments`

### D. 现役业务（登录/支付/订阅/推荐/通知）—— **必须保留**

`users` · `tokens` · `payment_orders` · `subscription_plans/requests/audit_log` · `user_notifications` · `user_preferences` · `referral_clicks` · `marketing_campaigns` · `distribution_*` · `reward_fulfillments` · `settlement_batches` · `achievements` · `admin_users` · `admin_audit_log` · `app_config` · `conversations` · `conversation_turns` · `trial_ip_log` · `debug_*`

---

## 三、🔴🔴 只 DROP TABLE 会「清了又回来」

**这是本方案最容易被漏掉的一步。**

`backend/crates/api_server/src/schema.rs:145`
```rust
CREATE TABLE IF NOT EXISTS prebuilt_cards ( ... )
```

后端**启动时会执行建表语句**（`IF NOT EXISTS`）。
→ 只在数据库里 `DROP TABLE`、**不改 `schema.rs`** → **后端下次重启就把空表建回来**。

🔑 **这是「存量修复 ≠ 根治」的又一实例**：
「删了数据」与「让数据不再产生」是**两件事**（同 `word_form` 补漏时「改存量 vs 改写端」那条判据）。

**必须同步改的**（`schema.rs` 里 prebuilt 一族的建表语句）：
- `prebuilt_cards`（:145）
- 4 张域子表（`prebuilt_language_cards` / `_science_` / `_literature_` / `_humanities_`）
- ⚠️ 还有引用它们的外键（`:164/:174/:182/:191/:223` 的 `FOREIGN KEY ... REFERENCES prebuilt_cards(id)`）

---

## 四、影响面（🔴 全部是**静默降级**，不会崩）

实测所有 `prebuilt_cards` 查询都包在 `if let Ok(...)` 里
→ **`prepare` 失败只会跳过该块，不会 panic** → 删表后后端**照样启动**，但功能**静默失效**。

| 位置 | 功能 | 是否 app 现役 | 删表后果 |
|---|---|---|---|
| `routes.rs:1604`（`profile_handler`） | **CEFR 词汇统计** | ✅ **是**（`/api/user/{uid}/profile`） | 🔴 **统计恒为空**（不报错，用户看不出是坏了） |
| `ws.rs:43/113/412` | AI 聊天词汇激活 | ❌ app 不调（`chat_client` 是死代码） | 词汇激活失效 |
| `routes.rs:710` | `/api/review/cards-by-progress` | ❓ 待确认 | 接口返回空 |
| `routes.rs:904/1085/1210/1230` | `/api/cards/all`·`by-plan`·`search` | ❌ 死代码 | 同上 |
| `achievement_engine.rs:372/428` | 学科统计 | ✅ 接口现役 | 学科数恒为 0 |
| `curriculum_admin.rs`（多处） | K12 课程后台 | ❌ 已清退 | 后台不可用 |

🔑 **判据：静默降级比报错更危险** ——
「CEFR 统计恒为空」用户**看不出异常**，只会觉得"这个功能没什么用"。

→ **所以正确做法不是"让它静默降级"，而是把依赖 `prebuilt_cards` 的代码一并清理/改写。**

---

## 五、🔴 依赖链：清了会断掉「重建 word.db」

`scripts/load_llm_results.py:845`
```python
content = {'front': wl, 'ipa': src_pron.get(wl), ...}   # src_pron 来自 data/coevo.db
```

→ **`data/coevo.db` 的 `pronunciation` 是重建 word.db 时的 IPA 来源**。
→ 清掉它 = **重建路径失去 IPA 来源**（且现在已知这份数据**本身是脏的**）。

🔑 **但这与白哥的新方向一致**：
「**不再补库，改调整 LLM 制卡**」→ 将来 IPA 也该由 **LLM 生成**，而不是从 coevo.db 搬。
→ **清理 coevo.db 的词卡，反而正好推动这条路线。**

⚠️ 但**要同时改** `load_llm_results.py`（否则下次重建会拿到 `None`，静默产出无 IPA 的卡）。

---

## 六、建议的执行方案（待批 · 分三步）

| 步 | 内容 | 说明 |
|---|---|---|
| **1** | **备份** | 三个库各存一份（**不在 git，必须手工备份**） |
| **2** | **改代码**（先改，后删） | ① `schema.rs` 去掉 prebuilt 一族建表语句 ② 清理依赖 `prebuilt_cards` 的查询（或改写为不依赖）③ `load_llm_results.py` 去掉对 coevo.db 的 IPA 依赖 |
| **3** | **删表** | 按白哥确认的范围，对三个库分别 `DROP TABLE`（含域子表与外键） |

**验收**：① 后端能启动 ② `/api/user/{uid}/profile` 正常返回 ③ 三个库 `sqlite_master` 里查不到 prebuilt 一族
④ 重建脚本跑通（不依赖 coevo.db）

**回滚**：三个备份文件 + git（代码改动）

---

## 七、🔴 必须白哥确认的四件事

| # | 问题 | 为什么必须问 |
|---|---|---|
| **1** | **清哪个库**：本地两个？还是**连 VPS 生产库一起清**？ | 三处影响完全不同；VPS 涉及线上 |
| **2** | **`user_cards`/`card_memory`/`review_log` 要不要一起清？** | 🔴 **它们是「用户学习状态」不是「词库」**，删了丢数据；且「成就体系重新规划」要用 |
| **3** | **`prebuilt_plans/stages/tasks`（K12 课程）要不要一起清？** | 不是"词库"，但同属已清退的 K12 |
| **4** | **`schema.rs` 是否一并改？**（否则重启建空表） | 不改 = **清了又回来**，白做 |

---

## 八、附：本次调查的附带发现

1. 🔴 **本地 `data/coevo.db` 的 schema 落后于代码**：
   代码已用 `defer_queue`（`schema.rs:691` **V5 迁移**），但本地库**没有这张表** →
   `/api/review/defer`（app 现役接口）在本地**跑不通** →
   🔑 **「本地库 ≠ 生产库」不只是数据差异，还有 schema 差异**
2. 🔴 **`.gitignore:102` 的注释是错的**（说 `data/coevo.db` 是生产库，实际 `backend/data/` 才是）
3. 🔑 **两库的 `prebuilt_cards` 行数不同**（18,984 vs 18,274）→ 白哥「两份词库会互相污染」的判断**有实测支持**
4. 🔑 **两个 coevo.db 都不在 git** → **删表前的手工备份是唯一保护**

---

*本文为调查产出，**未改动任何数据**。*
