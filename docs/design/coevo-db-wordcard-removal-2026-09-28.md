# 清除 coevo.db 词卡库 —— 方案、风险评估与执行记录

> 2026-09-28 起 ｜ 触发：白哥「coevo.db 里的**词卡库**应该清除，**只保留 VPS 在用的表**，维护两个词库既没有意义又容易互相污染」
> **状态**：本地两个库 ✅ **已清除** · `schema.rs` ✅ **已改** · VPS ⏳ **待执行**（方案见 §六）
> 口径：对 `data/coevo.db` · `backend/data/coevo.db` · 仓库全部 `.rs`/`.py` 的**本机实测**

---

## 〇、执行摘要（2026-09-29 00:0x 完成）

| 步骤 | 结果 |
|---|---|
| 备份三个库 | ✅ 本地两个已备份到 `E:/CoEvo-backups/`（**不在 git，这是唯一保护**） |
| 清 `backend/data/coevo.db` | ✅ 13 表删除 · `user_cards` 4,998 行完整搬运 · **20.1 MB → 3.3 MB** |
| 清 `data/coevo.db` | ✅ 同上 · **17.6 MB → 426 KB** |
| 改 `schema.rs` | ✅ 移除全部待删表建表语句 + `user_cards` 的 `prebuilt_cards` 外键 |
| 编译验证 | ✅ `cargo check -p api_server` 通过 |
| **「防复发」验证** | ✅ 在**全新空库**上跑 `init_database` → 11 张待删表**一张都没建出来** |
| 反向验证 | ✅ 故意注入 `prebuilt_cards` 建表 → 验证脚本**正确报红**（退出码 1） |
| VPS | ⏳ 待执行（§六） |

### 🔴 执行中发现的 3 个关键问题（都会让「照直觉做」失败）

**① 不能直接 `DROP TABLE prebuilt_cards`**
后端启用 `PRAGMA foreign_keys = ON`（`db_pool.rs:29`），而 `user_cards` 有 **4,998 行**
引用 `prebuilt_cards` → 实测直接报 **`FOREIGN KEY constraint failed`**。
→ **必须先重建 `user_cards` 去掉该外键**（SQLite 不支持 `ALTER TABLE ... DROP CONSTRAINT`）。
✅ 已排除其他风险：全库 44 条跨表外键里，**只有这 1 条**是「保留表 → 待删表」（`check_fk_before_drop.py`）。

**② `DROP TABLE` 后文件反而变大，必须 `VACUUM`**
```
backend/data/coevo.db   20,135,936 →DROP→ 21,397,504 →VACUUM→ 3,305,472   （省 17.3 MB）
data/coevo.db           17,608,704 →DROP→ 17,616,896 →VACUUM→   425,984   （省 16.4 MB）
```
→ 删表只把页**标记为空闲**，不回收空间。**没有 VACUUM 等于白做一半。**
（此项已加进 `purge_coevo_wordcards.py` 的第 5 步）

**③ `schema.rs` 不改 = 清了又回来**
`init_database`（`schema.rs:613`）会在**新建库**时执行建表语句。
守卫在 `main.rs:98-106`：
```rust
let table_count = ... name IN ('users','user_cards','card_memory');
if table_count < 3 { init_database(...).unwrap_or_else(|e| panic!(...)); }
```
→ 现有库因这三张表存在而**不会**重建；但**全新部署**（`table_count = 0`）**会** →
待删表以**空表**形式回来。**必须改 `schema.rs`。**

---

## 一、🔴 先纠正我上一轮的一个判断错误

我上一轮说「`data/coevo.db` 是**生产库**」—— **这是错的**，依据是 `.gitignore:102` 的注释。
实测两个库的用户数据后，真相相反：

| 库 | 大小 | 时间 | `users` | `user_cards` | `card_memory` | `payment_orders` | **身份** |
|---|---|---|---|---|---|---|---|
| **`backend/data/coevo.db`** | 20.1 MB | **07-15** | **91** | **4,998** | **4,998** | **8** | 🔴 **生产数据快照**（部署文档 scp 的就是这个） |
| `data/coevo.db` | 17.6 MB | 09-25 | 2 | 0 | 0 | 0 | 开发骨架（脚本读它） |

🔑 **教训**：**注释/文档不是事实** ——
`.gitignore` 写「`/data/coevo.db` 是生产库」，但**真正有 91 个用户、4,998 张学习卡的是 `backend/data/`**。
→ 「**读到的描述必须实测一遍才算数**」。

**顺带确认：两个 coevo.db 都「不在 git 里」**（`.gitignore:105` 与 `:153`）
→ 🔴 **没有版本回滚保护 → 删表前必须手工备份**。

---

## 二、三个 coevo.db（第三个在 VPS 上）

| # | 位置 | 用途 | 谁读它 | 状态 |
|---|---|---|---|---|
| 1 | `backend/data/coevo.db` | 生产数据快照（部署源） | 部署脚本 `scp` | ✅ 已清 |
| 2 | `data/coevo.db` | 开发骨架 | **所有 Python 脚本** | ✅ 已清 |
| 3 | VPS `/opt/coevo/data/coevo.db` | **真实生产库** | 线上后端 | ⏳ 待清 |

---

## 三、「词卡库」的精确范围与最终处置

| 组 | 表 | 行数（backend/data） | 处置 |
|---|---|---:|---|
| **A 词卡内容** | `prebuilt_cards` + 4 域子表 | **36,548** | 🔴 **删**（＝白哥说的"词库"） |
| **B 用户学习状态** | `user_cards`(4,998) · `card_memory`(4,998) · `review_log`(41) · `card_relations` · `user_*_cards` | 10,087 | ✅ **留**（用户数据；且成就体系要用） |
| **C K12 课程** | `prebuilt_plans`(16) · `prebuilt_stages`(297) · `prebuilt_tasks`(1,241) · `plan_runs`(7) · `user_plan_progress`(534) · `k12_quiz_*` · `guardian_assignments` | 1,554 | 🔴 **删**（白哥确认，含 534 行学习进度） |
| **D 现役业务** | `users` · `tokens` · `payment_orders` · `subscription_*` · `referral_clicks` · `user_notifications` … | — | ✅ **留** |

🔴 两库 `prebuilt_cards` 行数**不同**（18,984 vs 18,274）→ 白哥「两份词库会互相污染」**有实测支持**。

---

## 四、影响面（🔴 全部是**静默降级**，不会崩）

实测所有 `prebuilt_cards` / `plan_runs` 查询都包在 `if let Ok(...)` 里 → `prepare` 失败只跳过。

| 位置 | 功能 | app 现役 | 删表后果 |
|---|---|---|---|
| `routes.rs:1604`（`profile_handler`） | CEFR 词汇统计 | ✅ 接口现役 | 🔴 统计恒空 · **但 app 不读 `cefr_stats`**（实测 grep 0 命中）→ 无实际影响 |
| `achievement_engine.rs:372/428` | 学科统计 | ✅ 接口现役 | 学科数恒 0 |
| `review_handler.rs:29` | `/api/review/status` 到期数 | ⚠️ 只被 `chat_screen` 调 | 恒 0（`chat_screen` 是**死代码**，无 UI 入口） |
| `ws.rs:43/113/412` | AI 聊天词汇激活 | ❌（`chat_client` 死代码） | 失效 |
| `routes.rs:710/904/1085/1210/1230` | `/api/cards/*` 等 | ❌ 死代码 | 同上 |
| `plan_handler.rs` / `curriculum_admin.rs` | K12 计划与后台 | ❌ 已清退 | 不可用 |

🔑 **判据：静默降级比报错更危险** → 正解不是"接受它静默降级"，
而是**把依赖这些表的查询一并清理**（见 §七 待办）。

---

## 五、依赖链：清了会断「重建 word.db」（✅ 已处理）

`scripts/load_llm_results.py:267` 原本从 `data/coevo.db` 读 `pronunciation`。
清表后该路径失效 → **已改为「明确报错」而非静默跳过**：

```
🔴 data/coevo.db 里已没有 `prebuilt_cards` 表 —— 本脚本的「现网 IPA/释义来源」已失效。
   重建前请先决定 IPA 与释义的新来源（推荐：改由 LLM 生成）。
   ⚠️ 不要为了让它跑通而静默跳过 —— 那会产出 11,523 张无音标的卡且不报错。
```
🔑 **为什么选择报错**：若静默跳过，重建出的卡 `ipa` 全为 `None`，
**11,523 张无音标的卡且无任何报错** —— 属于最危险的一类失败。
且这份数据**本身已知不洁**（见 `card-ipa-rootcause-2026-09-28.md`）→ 正好推动「IPA 改由 LLM 生成」。

---

## 六、VPS 生产库执行方案（⏳ 待白哥执行）

⚠️ **顺序很重要：先部署带新 schema 的代码，再删表。**
（先删表的话，旧代码在窗口期查询会静默降级；先部署则新 schema 已不再建表，无窗口。）

```bash
# ── ⓪ 前置：VPS 库的表可能与本地不同，先看清 ──
sudo sqlite3 /opt/coevo/data/coevo.db \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tee /tmp/vps_tables_before.txt

# ── ① 备份（必做 · VPS 库无版本保护）──
sudo sqlite3 /opt/coevo/data/coevo.db "VACUUM INTO '/tmp/coevo.db.bak-$(date +%Y%m%d_%H%M%S)';"
ls -la /tmp/coevo.db.bak-*          # 确认备份存在且非空
sudo sqlite3 /tmp/coevo.db.bak-* "PRAGMA integrity_check;"   # 应为 ok

# ── ② 停服务（避免写入冲突）──
sudo systemctl stop coevo
sudo cp /tmp/coevo.db.bak-* /opt/coevo/data/coevo.db.rollback   # 就地回滚点

# ── ③ 执行清除（把脚本传到 VPS）──
scp -i ~/.ssh/coevo_key scripts/purge_coevo_wordcards.py ubuntu@<OLD_VPS_IP>:/tmp/
sudo python3 /tmp/purge_coevo_wordcards.py --db /opt/coevo/data/coevo.db --dry-run   # 先看
sudo python3 /tmp/purge_coevo_wordcards.py --db /opt/coevo/data/coevo.db             # 执行

# ── ④ 验收 ──
sudo python3 /tmp/purge_coevo_wordcards.py --db /opt/coevo/data/coevo.db --verify
sudo sqlite3 /opt/coevo/data/coevo.db \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tee /tmp/vps_tables_after.txt
diff /tmp/vps_tables_before.txt /tmp/vps_tables_after.txt    # 应只少那 13 张表

# ── ⑤ 启服务并验证 ──
sudo systemctl start coevo && sleep 3
sudo systemctl status coevo --no-pager | head -5
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/auth/login -X POST  # 应非 5xx
```

**回滚**（任一步骤失败）：
```bash
sudo systemctl stop coevo
sudo cp /opt/coevo/data/coevo.db.rollback /opt/coevo/data/coevo.db
sudo systemctl start coevo
```

---

## 七、⏳ 后续待办（本报告未做，需另行批准）

**改依赖查询**（消除对已删表的引用）——这是**代码改动**，有风险，建议独立进行：

| 文件 | 引用数 | 建议 |
|---|---:|---|
| `routes.rs` | 6 处 JOIN | 改用 `user_cards` 自带字段（它有 `domain`/`front`/`language`/`level`）|
| `achievement_engine.rs` | 2 处 JOIN | 同上（学科统计）|
| `review_handler.rs` | 1 处 JOIN `plan_runs` | `chat_screen` 死代码 → 可整块删 |
| `ws.rs` · `routes.rs`(`/api/cards/*`) · `plan_handler.rs` · `curriculum_admin.rs` | 多处 | **死代码/K12 遗留** → 建议整体清理 |

🔑 **当前中间状态是安全的**（表已删、查询未改）：
那些查询会静默降级，但**受影响的都是"无消费者"或"app 不读"的路径**（§四已逐条核实）。

---

## 八、附：本次调查的附带发现

1. 🔴 **本地 `data/coevo.db` 的 schema 落后于代码**：
   代码已用 `defer_queue`（`schema.rs` V5 迁移），但本地库**没有这张表** →
   `/api/review/defer`（app 现役接口）在本地**跑不通** →
   🔑 **「本地库 ≠ 生产库」不只是数据差异，还有 schema 差异**
2. 🔴 **`.gitignore:102` 的注释是错的**（说 `data/coevo.db` 是生产库，实际 `backend/data/` 才是）
3. 🔑 **两库的 `prebuilt_cards` 行数不同**（18,984 vs 18,274）→ 「两份词库会互相污染」有实测支持
4. 🔑 **两个 coevo.db 都不在 git** → **删表前的手工备份是唯一保护**

---

## 九、本次交付的脚本

| 脚本 | 用途 |
|---|---|
| `scripts/purge_coevo_wordcards.py` | **执行清除**（幂等 · 自动备份 · 七步 · 五项自检 · `--dry-run`/`--verify`） |
| `scripts/check_fk_before_drop.py` | **删前查外键**（列出「保留表 → 待删表」的危险引用） |
| `scripts/verify_schema_no_wordcards.py` | **防复发验证**（提取 `schema.rs` 的 SQL 在空库上跑，确认待删表不出现） |

> 🔬 **反向验证已做**（判据：反向断言必须实测报红）：
> 故意把 `prebuilt_cards` 建表语句插回 schema 副本 → 验证脚本**报红**（表数 32→33，退出码 1）✅

*本地执行已完成；VPS 待执行。*


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
