# A1b 交付：在线合规闸门 + 退役残留清扫（本地已验证）

> 2026-09-29 15:1x~15:5x ｜ 触发：白哥「A1b->清理」
> 前置：`a1-generate-card-api-2026-09-29.md`（A1 · §六「阻塞上线的一件事：合规扫描」· §七「退役残留」）
> **本步纯本地** —— 未部署、未碰生产服务器（服务器仍是零改动状态）。

---

## 一、一句话结论

1. **A1b 做完** → A1 的「不能上线」拦路石搬掉了：在线制卡现在**先过合规闸门**才可能写缓存/返回。
2. **顺带把基线 3 个失败测试清干净** → `cargo test -p api_server` **78 passed / 0 failed**（原 60/3）。

---

## 二、A1b：合规闸门

### 2.1 架构：**词表共用，逻辑各写，用例对齐**

| 层 | 做法 |
|---|---|
| **词表 / 规则** | 抽成 **`backend/prompts/compliance_terms.json`**（11 组词表 + 2 组正则），Python 与 Rust **都读它** |
| **判定逻辑** | Rust 另写一份（`api_server/src/compliance.rs::scan_parts`），对齐 Python 的 `scan_parts` |
| **一致性证据** | **共享用例** `backend/prompts/compliance_cases.json` —— 两边跑**同一份** |
| **位置** | `llm_card.rs` 的 **④**，在**客观格式闸门 `gate()`（⑤）之前** |

> 放在了 `prompts/` 而不是 `backend/data/`：后者被 `.gitignore` 忽略 → **不进仓库、部署会漏**。
> `prompts/` 已是「Python 与 Rust 共用文件」目录（契约 prompt 就在那儿），且
> `prompt_loader` 只扫 `{category}/{subject}/` 子目录 → **不会误加载**本文件（已核实）。

### 2.2 🔑🔴 关键发现：**「词表一样」≠「判据一样」**

A1 的教训是「复用同一个组件 ≠ 同一套行为」。这次是它的**同族第二次**：

| 可能漂移的点 | Python | Rust |
|---|---|---|
| 单词词边界 | `(?<![a-z])term(?![a-z])` | 🔴 **手写**（Rust `regex` **不支持 lookaround**）→ `find_bounded` |
| 多词词条 | `\b` + `\s+` | `regex` + `\b`/`\s+`（一致） |
| 「第一个命中」 | 按**词表顺序**（不是位置顺序） | 同（`first_hit`） |
| 去重键 | `(类别, 字段)` + 取最严重级别 | 同 |
| 扫哪些字段 | `card.sections[]` 的 `en/zh/text/source` | 🔴 **递归收集全部字符串**（**有意不同**，见 §2.4） |

→ 光「共用词表」只能保证**词表**一致，**判据**仍可能漂。
  所以补了**共享用例**这一层：**两边都过 = 一致，由构造保证**（不是靠人工比对）。

### 2.3 分层返回：**「内容违规」与「配置故障」必须分开**

`compliance::check_card` 返回 `Result<Verdict, String>`：

```rust
Ok(Verdict::Violation(why))  // 内容违规 → 422，**不可重试**
Err(e)                       // 词表读不到 → 500 **服务故障**
```

🔴 **为什么不能合并**：若把 `Err` 也当「违规」，那么**一次部署漏了词表文件**
会让**每个词**都返回「该词暂不支持生成（内容未通过合规检查）」——
**把配置故障伪装成内容问题**，排查时完全看不出真相。这正是「静默失效」的教科书形态。
（已端到端实测，见 §2.5 表第 3 行。）

### 2.4 在线卡的字段范围：**宁可多扫不可漏扫**

离线扫描器只把 `card.sections[]` 的 `en/zh/text/source` 当正文（那是对 word.db 的**卡结构**）。
在线卡的字段**随契约演进**（v6 就新增了 `ipa`/`definition`/`context`），且**整张都给用户看** →
Rust 侧**递归收集卡里所有字符串**，未知字段一律补 `.text` 后缀进规则 ④ 的扫描面。

| | |
|---|---|
| **漏扫**的代价 | 🔴 **违规内容直出用户**（不可逆） |
| **多扫**的代价 | 最多多一条 P1（不阻断，只记录） |
| → 所以 | 选**多扫** |

### 2.5 验证（五层 · 全绿）

**① 词表抽取：逐项核对** —— 11 组词表 + 2 组正则，Python 内联值 vs JSON **ALL MATCH**（含正则 pattern 与 why 文案逐字符）。

**② Python 侧行为不变** —— 改造前后对 `data/word.db`（11,523 词条）**逐行一致**：
`P0=0 · P1=6 · P2=2`。

**③ 共享用例：Python 24/24 + Rust 24/24**（同一份 `compliance_cases.json`）。
覆盖：铁律 1 词边界（`grape`/`scraped`/`schooner`/`drapery` 全不报）· 铁律 2（标注冒犯性则跳过 / 未标注 P1 / 另有正常义 P2）·
铁律 3 组合判定 · 铁律 4（`India became an independent nation` 史实不报）· 铁律 5（`autonomous region` 官方名不报）·
字段级去重 · 规则 ④ 字段过滤。

> 🔑 用例价值当场兑现：初版有 **1 条用例被写错**（「主体」没放进同字段 → 期望 P1、实际空）→
> 一次性暴露了「主体必须与文本**同字段**才触发」这条我理解错的规则。

**④ 随机差分：400/400** —— 用 400 条随机拼装文本（含直接拼接以考词边界），
**Python 算期望值 → Rust 实算比对**（同一批输入、逐条比 `级别|类别|字段`）。
期望分布覆盖全部级别×类别，且含 82 条「应一条都不报」（专门抓误报）。
为防「假绿」（怕测试根本没读到这批用例），临时把断言改成 `assert_eq!(len, 400)` 跑过一次 → 确认读到了。

**⑤ 真机端到端（本地服务 · 独立测试库 · 端口 8399）**

| 场景 | 结果 |
|---|---|
| 正常词 `serendipity` | **200 · from_cache=false · 1.87s** · 13 字段完整 ✅ |
| 正常词 `resilience` → 再查 | 200（1.89s）→ **from_cache=true · hit_count=1** ✅ |
| **受控违规卡**（临时 prompt 目录让模型吐「disputed territory」） | **422** · 客户端消息 `该词暂不支持生成（内容未通过合规检查）`（**不含细节**）· 服务端日志含完整细节（`[涉主权]` ×2 字段）✅ |
| **拒绝后是否写缓存** | 🔴 `zzprobey` **不在缓存**（拒绝 → 不写缓存）✅ |
| **词表文件缺失**（受控） | **500** + `ERROR ... 合规词表不可用（服务配置问题）` —— **不是 422** ✅ |

**⑥ 静态分析**：`cargo check --workspace --all-targets` 与 `cargo clippy -p api_server --all-targets` → **0 error**。

### 2.6 🔴 过程中抓到的两个「假绿」

| 陷阱 | 现象 | 教训 |
|---|---|---|
| **旧二进制** | 先用 `cargo test` 验证（全绿）就去跑端到端 → 受控违规卡**反而 200**。查 mtime：二进制 `12:57`、源码 `15:25` → **跑的是 A1 时的旧 bin** | 🔴 `cargo test` **只编测试目标，不重编 bin**。端到端必须 `cargo build` 后跑，并**核对二进制 mtime** |
| **上游模型没照抄** | 第一次受控 prompt 让模型输出「Tibet was historically an independent kingdom.」→ 实际返回的卡**不是那句**（疑似上游自身审核改写）→ 表现为「闸门没拦住」 | 🔴 用 LLM 做受控实验时，**先确认它真的照做了**；否则会把「实验没生效」误读成「防线失效」 |

> 第一条正是「**未执行的代码路径必须真跑一次**」的同族：`cargo test` 绿 ≠ 你要验的那条路跑过了。

---

## 三、清理：退役残留（原 §七的三个面）

🔑 判据：**「删数据」≠「让它不再产生」** —— 要一起清的是 **①建表语句 ②迁移列表 ③测试断言**。
09-28/29 前两轮清了 ①，本轮清 ②③。

### 3.1 `schema.rs`

| 项 | 改动 |
|---|---|
| `run_migrations_inner` | 删 **9 条对退役表的 ALTER**（`card_memory`×1 · `user_cards`×2 · `prebuilt_plans`×6）→ 剩 12 条**全指向现役表** |
| 同上 · 容错 | 🔴 **不再吞 `no such table`** —— 既然列表已只剩现役表（且目标表由调用方 `init_database` 先行建好），`no such table` = **真 bug**，必须炸出来。**这就是「掩盖真错」的修法** |
| 测试常量 | `EXPECTED_NEW_TABLES`（38 项，含退役表）→ **`EXPECTED_TABLES`（20 项 = 实际建的表）** + 🆕 **`RETIRED_TABLES`（28 项）** |
| 断言方式 | 「包含断言 + `>= 30` 数量下限」→ **集合相等**（多表/缺表两头都卡） |
| `test_full_schema_all_tables_present` | 改集合相等 + 退役表逐张断言**不存在** |
| `test_core_table_columns` | 原断言 `user_cards`/`plan_runs`/`card_memory`/`card_relations`/`prebuilt_plans`/`review_log` → **全部重写为现役表**（users / admin_users / payment_orders / marketing_campaigns / reward_fulfillments / 🆕 generated_card_*） |

> 🔑 为什么把「数量下限」换成「集合相等」：**`>= 30` 只能发现缺表，发现不了多表** ——
> 退役表留在常量里会一直「通过」，直到有人误以为它还在用。

### 3.2 `campaign_scheduler.rs`

| 项 | 改动 |
|---|---|
| `hard_delete_expired_trials` 级联表列表 | 删 **7 个已退役 / 从未存在**的表名：`card_memory`·`user_cards`·`user_plan_progress`·`cp1_plans`·`plan_runs`·`conversation_turns`·`conversations` |
| `test_trial_hard_delete` | 删掉对 `conversations` 的 INSERT（**就是它导致测试失败**）；级联验证由现役表 `tokens` 承担 |

> `cp1_plans` 尤其可疑：**全库仅此一处出现**，不是任何 `CREATE TABLE` 的产物 = 幽灵表名。

### 3.3 结果

```
cargo test -p api_server     78 passed / 0 failed     （原 60 passed / 3 failed）
```

原 3 个失败（`test_trial_hard_delete` · `test_core_table_columns` · `test_full_schema_all_tables_present`）**全部转绿**。

---

## 四、🔴 遗留发现（**本次只记录，未改** · 需白哥定）

| # | 发现 | 影响 | 建议 |
|---|---|---|---|
| 1 | `hard_delete_expired_trials` 原列表里的 `distribution_commissions` 列名是 `earner_id`/`buyer_id`、`trial_ip_log` **只有 `ip`** —— 两者**都没有 `user_id` 列** ⇒ 原 `DELETE ... WHERE user_id=?1` **必然报错**，被 `let _ =` **静默吞掉**（**一行也没删过**）。本次已把两者移出列表（**行为等价**）+ 写明注释 | 🟠 财务/反滥用日志的清理语义**从未生效** | ① `distribution_commissions`：删不删是**财务决策**；② `trial_ip_log`：**建议保持不删**（删掉等于让同 IP 再次白嫖试用） |
| 2 | `backend/schema.sql` 是**过时的旧 dump** —— 仍含 `conversations`/`card_memory`/`achievements`/`prebuilt_*` 等全部退役表，且**无任何代码/脚本引用**（已 grep 核实） | 🟠 「存量不清理 → 持续产生新依赖」：后人可能照它建库 | 删除，或加醒目「⚠️ 已过时，schema 权威在 `schema.rs`」抬头 |
| 3 | `shared_types` 的 `conversation` / `growth` / `review` 三个模块 **0 外部引用**（`card` 仍在用） | 🟡 死代码（随旧学习链退役的残留） | 可删（属独立清障议题） |
| 4 | `main.rs` 的迁移块仍保留 `no such table` 容错（其列表只含现役表） | 🟠 与 §3.1 同源 —— 会掩盖真错 | 建议按 `schema.rs` 同样收紧 |
| 5 | 在线制卡的**缓存命中路径不复检合规** | 🟠 词表**大改**后，陈旧 `generated_card_cache` 里可能留违规内容并继续命中 | 词表有实质变更时，跑一次离线重扫 + 清对应缓存（可做成小脚本） |

---

## 五、产物清单

| 类型 | 文件 |
|---|---|
| 🆕 Rust 模块 | `backend/crates/api_server/src/compliance.rs`（~700 行 · 含 8 测试） |
| 🆕 共用词表 | `backend/prompts/compliance_terms.json` |
| 🆕 共享用例 | `backend/prompts/compliance_cases.json`（24 条） |
| 🆕 校验脚本 | `scripts/verify_compliance_parity.py` |
| 📝 Python 扫描器 | `scripts/scan_compliance.py`（内联词表 → 读共用文件；抽出 `scan_parts`） |
| 📝 接入 + 清理 | `llm_card.rs`（④合规闸门 + `CardError::Compliance`）· `schema.rs` · `campaign_scheduler.rs` · `lib.rs` · `Cargo.toml`（+`regex`）· `Cargo.lock` |

---

## 六、下一步

| 步 | 内容 | 阻塞 |
|---|---|---|
| **A2** | 端侧：`external_word_cache` + 未命中分支（转圈）+ 失败重试 | ✅ A1b 已解除合规阻塞 |
| **A3** | 回流脚本（`distinct_user_count ≥ K` → 过闸门 → 并入 `word.db`） | 需 A1 有真实缓存数据 |
| **部署** | 步骤 1（起服务 · **不碰 nginx**） | 需白哥批 |
| **主域占位页** | 并入 nginx 那批操作 | 已批方案，等执行 |
| **§四 遗留 1~5** | 见上表 | 需白哥定 |

---

*本步**未部署、未碰生产服务器**。改动全部在本地仓库；Rust 侧 `cargo test`（78/0）· `check` · `clippy` 全绿；Python 侧扫描与用例全绿；端到端已用**重编后的二进制**实测（含拒绝路径与故障路径）。*
