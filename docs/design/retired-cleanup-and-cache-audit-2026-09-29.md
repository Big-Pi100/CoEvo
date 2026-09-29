# 退役残留清扫（遗留 5 项）+ 缓存合规审计工具

> 2026-09-29 15:4x~16:0x ｜ 触发：白哥「遗留项同意你的建议」
> 前置：`a1b-compliance-gate-and-retired-cleanup-2026-09-29.md` §四（遗留 5 项）
> **本步纯本地** —— 未部署、未碰生产服务器（服务器仍是零改动状态）。

---

## 一、一句话结论

**5 项遗留全部按建议处理完**；过程中另查出 **2 个真问题**（其中一个是我上一轮判断错误）。

```
cargo test -p api_server   81 passed / 0 failed   （上轮 78 → +3）
cargo check / clippy      0 error
```

---

## 二、5 项遗留的处理

### ① 两张「无 `user_id` 列」的表 → **保持不删**（并把决策固化成断言）

`distribution_commissions`（财务记录）与 `trial_ip_log`（反试用滥用日志）**故意不纳入级联删除**。
上轮只做了「移出列表 + 加注释」；本轮把决策**写成测试**，否则下一个人只会看到「列表里没有这两张表」，
不知道是**忘了**还是**有意**：

| 新增断言 | 作用 |
|---|---|
| `two_tables_have_no_user_id_column` | 断言这两张表**没有 `user_id` 列** —— 这才是「不能纳入级联」的**依据**。若将来有人加了该列，测试失败 → 提醒「现在可以重新评估了」 |
| `cascade_list_matches_real_schema` | 断言级联列表里**每张表都真实存在且带 `user_id` 列** → 再写进幽灵表名或不带 `user_id` 的表，**当场失败**（原来靠 `let _ =` 静默吞掉，写错了也没人知道） |

配套：级联列表从函数内局部数组提为模块级 **`CASCADE_TABLES`** 常量（测试直接读它 → 一处权威）。

> 🔑 断言选「**没有 `user_id` 列**」而不是「表还在」：
> 后者只说明「没被删」，前者才说明「**为什么不能删**」。判据的**倾向性**决定了它能防住什么。

### ② `backend/schema.sql` → **删除**

| 事实 | 值 |
|---|---|
| 内容 | **45 张表**，其中 **16 张是已退役**的旧学习链 |
| 大小 | 567 行 / 20 KB |
| 引用 | `backend/`（含 `tools/` `scripts/`）0 处 · `.github/` 0 处 · **总 0 处代码引用** |

🟠 危害是「**存量不清理 → 持续产生新依赖**」：后人照它建库 → 建出一堆退役表；
或误以为「改 sql 就能加表」（实际改了没用）。
→ 按判据选**删除**（而非加过时抬头）。**git 历史保留，可回滚。**

**同步更新了 2 份活文档**（否则会留下指向不存在文件的指令）：
- `coevo-vps-deployment-assessment-2026-09-29.md` §四「不要传 schema.sql」→ 改为「已删除」
- `llm-card-online-path-2026-09-29.md` §21.2 约束 3 + §21.7 请示第 4 项 → 标注已执行

> 归档/历史类文档（`docs/_archive/k12-era/*`、`docs/architecture/k12-dataflow-analysis.md`、
> `docs/review/audit-doc-vs-code-2026-05.md`）**不动** —— 它们是当时的快照，改了反而失真。

### ③ `shared_types` 三个死模块 → **删除**

| 已删 | 原属 | 为什么可删 |
|---|---|---|
| `src/review.rs`（110 行） | 后端 FSRS 复习类型 | 学习状态整体迁端侧 `user.db`；`card_engine` 已退役 |
| `src/growth.rs`（401 行） | 后端成就引擎 | 成就改为**端侧计算** |
| `src/conversation.rs`（48 行） | 对话链类型 | 对话链整体退役 |
| `CardState`（`lib.rs` 根） | 后端 FSRS 卡片状态 | 端侧自实现，后端无消费者 |

**保留 `card`** —— 它**真有消费者**：`chat_engine::concept_extractor` 用
`shared_types::card::{ConceptCandidate, ExtractionResult}`。
`lib.rs` 重写为「说明为什么只剩 card + 每项为什么可删」的索引（而不是留下沉默的 `pub mod card;`）。

### ④ `main.rs` 迁移容错 → **收紧**（且**必须先修顺序**，见 §三.2）

| 改动 | 内容 |
|---|---|
| 容错 | 🔴 **不再吞 `no such table` / `no such index`** —— 只放行 `duplicate column` / `already exists`（真的已应用过） |
| 依据 | 列表里每条 `ALTER` 的目标表都由**本块之前的 `CREATE`**（或守卫星的 users/tokens/payment_orders）保证存在 → `no such table` = **真 bug**，应让启动**立刻失败**（fail fast），而不是带着坏 schema 继续服务 |
| 第二处 | `app_config` 建表块同样收紧（该块只跑 `CREATE TABLE IF NOT EXISTS`，不可能报 `no such table`） |
| 🆕 标注 | 给 `if table_count < 3` 守卫加说明：**它恒不成立，不是建表入口**（见 §三.1） |

### ⑤ 缓存命中不复检合规 → 🆕 **`scripts/audit_generated_card_cache.py`**

**补的是这个窗口**：
```
T0  某词生成 → 过闸门 → 写进 generated_card_cache
T1  词表被改宽 → 这条老缓存在新规则下其实违规
T2  用户查该词 → 命中缓存直出 → 违规内容发给用户      ← 闸门管不到（它只管「生成时」）
```

| 设计 | 为什么 |
|---|---|
| 词表 / 规则引擎**复用**（读同一份 JSON + import `scan_compliance.py::scan_parts`） | 不产生第二份词表、第二份规则 |
| 🔑 **启动先跑 `card_cases` 适配层自检**，不过就**拒绝出报告**（退出码 2） | 适配层（卡 JSON → 字段名+文本）错了 → 报告里「合规/违规」**都不可信** |
| 默认**只报告**；`--purge` 只**预览**；`--purge --yes` 才真删 | 「静默失败 + 无出口」与「误删」两头都避开 |
| 库里没有该表 → 友好提示 + 退出 0 | 老库 / 还没跑过新版后端时不是错误 |
| 退出码：有 P0 → 1 | 可挂 CI |

**顺带把运维闭环补上**：词表变更的必跑清单从 3 步 → **4 步**（第 4 步就是本脚本），
写在 `compliance_terms.json` 的 `_comment` 与 `scan_compliance.py` 的 docstring 里（两处都指向同一份口径）。

---

## 三、🔴 过程中的关键发现

### 1. 「建表入口」不在 `main.rs` —— **我上一轮的判断被证伪**

我上轮在 main.rs 里看到 `if table_count < 3 { init_database() }`，据此担心
「生产库 table_count 恒 3 → **A1 的两张表永远建不出来**」。

**实测证伪**：`db_pool.rs:46` 在 `init()` 里**无条件**调用 `schema::init_database()` ——
而 `db_pool::init()` 在 `main.rs:61` 就跑过了。所以：

- **真正的建表入口是 `db_pool::init()` → `schema::init_database()`**（总跑）
- `main.rs` 的守卫**恒不成立**（`db_pool` 已经建好表）→ **死逻辑**
- 实测：空库启动 → **20 张表全建好**，但那条 `tracing::info!("Schema initialized")` **从不打印**

🔑 **判据：查「谁在建表」要跟完整调用链，不能只看一个文件。**
  这和「注释里的能力声明必须 grep 才算数」同族 —— 都是**只看到一处就下结论**。
  （我如果没做副本演练，就会拿一个**不存在的问题**去请示白哥。）

**处理**：给死守卫加醒目标注（指明真正入口 + 建议后续删除），**不删逻辑**（删启动逻辑属独立决策）。

### 2. `main.rs` 里 `ALTER ... subscription_plans` **排在它的 `CREATE` 之前**

```rust
"ALTER TABLE subscription_plans ADD COLUMN once_per_user ...",   // ← 原位置
// ...
"CREATE TABLE IF NOT EXISTS subscription_plans ( ... once_per_user ... )",
```

后果：老库若缺 `subscription_plans`（守卫只保证 users/tokens/payment_orders 存在），
这条 `ALTER` 会报 `no such table` → **被容错静默吞掉** → 靠紧随其后的 `CREATE` 兜住。

🔑 **判据：容错吞掉的错里，有一部分不是「可以忽略」，而是「顺序/写法本身就是错的」。**
  → 所以**收紧容错之前必须先修顺序**，否则收紧的那一刻，老库启动会直接 panic。

**处理**：把 `ALTER` 挪到 `CREATE` 之后，并注明原因（这条注释本身就是「为什么不能盲目收紧容错」的证据）。

> 🔑 顺带澄清一个**被我否掉的担心**：`payment_orders` 的 `refund_reason` / `refund_id`
> 只在 `schema.rs` 的迁移里有、`main.rs` 没有 —— 我一度以为是「老库缺列」。
> 但 `init_database` **总跑** → 老库也会加上 ✅ **不是问题**（同一个「没跟调用链」的错误）。

### 3. 🔴 演练**不可重复**，且我把「工具用错」当成了「实验失败」

两个坑，都踩了：

| 坑 | 现象 | 教训 |
|---|---|---|
| **输入状态没重置** | 第一次演练（当时 glob 写错）**已经把 fresh / partial 库建好了** → 第二次跑时「演练前」显示的已是**上一次的结果**，结论失去意义 | 🔑 演练/验收必须**显式重置输入状态**，并**打印重置后的状态**作为证据（本次补了「演练前 N 表 / 演练后 N 表」） |
| **glob 写错 → 静默给「不存在」** | 日志文件名是 `coevo.log.2026-09-29`，而我 grep `"$LD"/*.log` → **匹配不到** → 三场景全报「🔴 启动失败」，**实际全都成功了** | 🔑 工具/模式写错时，**「找不到」会被当成「不存在」** → 排查前先**确认工具真的能读到东西** |

---

## 四、验证

### ① 副本演练（**重置输入后** · 3 场景 × 真实库形态）

| 场景 | 演练前 | 演练后 | 启动 | 致命错误 | 迁移跳过 |
|---|---|---|---|---|---|
| `existing`（生产库副本） | 18 表 | 20 表 | ✅ | 无 | 全 `duplicate column` |
| `fresh`（库不存在） | 不存在 | **20 表** | ✅ | 无 | 全 `duplicate column` |
| `partial`（只有 3 张核心表） | 3 表 | 20 表 | ✅ | 无 | 全 `duplicate column` |

→ 收紧容错后**三种真实形态都不炸**，且最终都收敛到 20 表（= `EXPECTED_TABLES`）。
→ ✅ 生产库 `coevo.db` **全程未被碰过**（仍是 18 表）—— 演练只操作副本。

### ② 受控实验：审计脚本真的抓得出来吗

造 3 条缓存（正常 / P0 违规 / 损坏 JSON）：

| 步骤 | 结果 |
|---|---|
| 只报告 | 抓出 **1 条 P0（涉主权 `disputed territory`）** + **1 条损坏 JSON**；**正常卡不误报**；退出 1 ✅ |
| `--purge`（无 `--yes`） | **只预览**，库里仍是 3 条 ✅ |
| `--purge --yes` | 删 2 行（含 `generated_card_hit` 登记），**正常卡 `brainstorm` 保留** ✅ |
| 再跑 | 0 P0 / 0 损坏 ✅ |

### ③ 跨语言 parity（把「卡适配层」也纳入共享用例）

新增 8 条 `card_cases`（覆盖：契约内字段 / 契约外字段补 `.text` / `word`→`spelling` 归一 /
嵌套对象 + 数组下标 / 数字布尔 null 不进扫描面 / `ipa` 补 `.text` / 铁律 2a 在卡形状下同样成立）。

| 侧 | 入口 | 结果 |
|---|---|---|
| Python | `audit_generated_card_cache.py` 启动自检 | ✅ 8/8 |
| Rust | `cargo test -p api_server compliance_card_cases_parity` | ✅ 8/8 |

→ **两侧适配层一致**，由构造保证。

### ④ 全量回归

```
cargo test -p api_server             81 passed / 0 failed   （上轮 78 → +3）
cargo check --workspace --all-targets     0 error
cargo clippy --workspace --all-targets    0 error（既有 warning 未增）
python scripts/scan_compliance.py          P0=0（11,523 词条）
python scripts/verify_compliance_parity.py 24/24
python scripts/audit_generated_card_cache.py  自检通过 + 边界正确
```

---

## 五、产物清单

| 类型 | 文件 |
|---|---|
| 🗑 **删除** | `backend/schema.sql`（45 表过时 dump）· `shared_types/src/{conversation,growth,review}.rs` |
| 🆕 脚本 | `scripts/audit_generated_card_cache.py` |
| 📝 Rust | `main.rs`（修 ALTER 顺序 + 收紧容错 + 标注死守卫）· `campaign_scheduler.rs`（`CASCADE_TABLES` 常量 + 2 断言）· `shared_types/src/lib.rs`（重写） |
| 📝 用例 | `compliance_cases.json`（+8 条 `card_cases`）· `compliance.rs`（+`compliance_card_cases_parity`） |
| 📝 文档 | 本文件 · `coevo-vps-deployment-assessment-*` · `llm-card-online-path-*` · A1b 报告 §四 |
| 📝 口径 | `compliance_terms.json` + `scan_compliance.py` 的「改词表后必跑 **4 步**」清单 |

---

## 六、本轮新发现的遗留 → ✅ **已全部处理**（白哥「清理遗留」）

> 📄 **处理结果 + 一项我判断错误的纠正 + 端侧 chat 链评估 →
> `legacy-cleanup-round2-2026-09-29.md`**

| # | 发现 | 处理 |
|---|---|---|
| 1 | `main.rs` 的 `if table_count < 3` 守卫是**死逻辑** | ✅ **已删**（+ 那条永不打印的 `info!`）· 注明「唯一建表入口是 `db_pool::init`」 |
| 2 | `api_server` / 根 bin 的 `shared_types` 依赖**未使用** | ✅ **已删声明**（`chat_engine` 保留 —— 它真在用）· 依赖图实测只剩一个消费者 |
| 3 | `backend/achievements.toml` 成**孤儿** | ✅ **已删**（内容已固化进 `achievement-redesign` 文档 §二）· 🆕 连带删掉 **0 使用**的 `toml` 依赖 |
| 4 | 仓库根 0 字节 **`NUL`**（Windows 保留名） | 🔴 **确认删不掉**（6 种方式全被 Windows 拒绝）→ ✅ **已验证规避方案**（`glob: "!NUL"`）· 全部写进 `.gitignore` 注释 · **需人工删** |

⚠️ 另撤销一条**我上一轮的错误结论**：我说「端侧 `chat_*`/`pipelines` 是遗留死代码」——
核实后发现 **`chat_client.dart` 正被 `profile_screen` 使用**，且 `/chat` 是「有路由、无入口」的孤儿页。
详见 `legacy-cleanup-round2-2026-09-29.md` §六。

---

*本步**未部署、未碰生产服务器**。所有演练均在**副本**上进行，已清理；生产库 `coevo.db` 全程零改动。*
