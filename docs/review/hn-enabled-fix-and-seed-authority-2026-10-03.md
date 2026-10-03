# 🔧 修复 HN `enabled` 残留 + 根治「存量库配置静默失效」（2026-10-03）

> **白哥指令**：「做」（批准修 HN `enabled` 残留）
> **结果**：✅ 已实施 + ✅ 已本地验证（五层）· 🔴 **未部署**（等你指令）
> ⚠️ **我改了实现方式** —— 与上一条建议的「加迁移」不同，原因见 §二（**上一条的建议有缺陷**）

---

## 一、结论速览

| 项 | 结果 |
|---|---|
| 问题 | HN 弃用后，**生产库 `enabled` 仍是 1** ⇒ 每 6 小时一条 `WARN 未知的源类型 hn` |
| 根因 | seed 用 `ON CONFLICT DO NOTHING` ⇒ **只对新库生效，不管存量库** |
| 修法 | seed 改为**条件 UPSERT**（`DO UPDATE ... WHERE 有变化`）⇒ 老库的配置**会被对齐** |
| 实测（生产真实数据）| 启用数 **23 → 22** · **只改 1 行 2 列** · 运行时状态**逐行完好** · 幂等 ✅ |
| 验证 | 单测 3 条新增（含 2 条守门人）· **证伪 2 项**（故意破坏=确认会红）· 真实库演练 · fmt/clippy/test 全绿 |

---

## 二、🔴 为什么我**没有**按上一条建议的「加迁移」做

上一条我给的选项是：

| 方案 | 我当时说的 | 现在的实测结论 |
|---|---|---|
| **🅰 迁移**（我当时推荐） | 「新库老库都对」 | 🔴 **有死锁缺陷**（见下）|
| 🅱 手工 UPDATE 生产库 | 「最小」 | 仍要手工，且下次换一个源又要手工 |
| 🅲 seed 改 `DO UPDATE` | 🔴 **「危险 —— 会覆盖所有人工改动」** | ✅ **实测推翻了「危险」** —— 我当时**没核实前提** |

### 2.1 🅰 的死锁缺陷（我上一条没发现）

迁移列表**每次启动都执行**。若写 `UPDATE ... SET enabled=0 WHERE url LIKE '%hacker-news%'`：

- **将来要重新启用 HN**：改 seed 常量为 1 ⇒ 但 seed 是 `DO NOTHING` ⇒ **不生效**；
  迁移又把它改回 0 ⇒ **代码改了也启不回来**
- ⇒ 必须先**删掉迁移条目**才能启用 —— 极其反直觉，且没有任何地方提示这件事

📌 **判据**：**「每次启动都跑的一次性修正」与「期望可逆的配置」是矛盾的** ——
前者会让后者的「改回」路径消失。这类修正**不能**用无条件迁移写。

### 2.2 🅲 的「危险」判断**被实测推翻**（这是我上一条的失误）

我当时写「会覆盖所有人工改动」，但**没有核实两件事**：

**① seed 到底碰哪些列？**（实测）

`content_source` 共 **15 列**，seed 只列 **12 列**。差的是：

| 列 | 性质 | 谁写 |
|---|---|---|
| `fetch_interval_min` | 配置（但 seed 从不设置）| — |
| `last_fetch_at` | 🔴 **运行时状态** | 抓取循环 |
| `fail_count` | 🔴 **运行时状态** | 抓取循环 |

⇒ 🔑 **seed 的列集合 = 「配置列」，运行时状态列根本不在语句里** ⇒ 结构上**不可能**覆盖它们。

**② 有没有「人工改配置」的入口？**（实测）

grep 全后端：**只有 2 处** UPDATE `content_source`（`content_fetch.rs:330/332`），
都只写 `last_fetch_at` / `fail_count` / `updated_at`。
⇒ **没有任何代码、也没有任何后台接口能改 `enabled`**（无 admin 路由）。

⇒ 「人工改动」在实践中**只发生过一次**（Ars Technica），而且那一次**正是因为 `DO NOTHING` 没有别的办法**。
⇒ 它不是「需要保护的资产」，而是**要根治的临时手段**。

### 2.3 🔑 教训（比这次修复更值钱）

**「我上一条给出的风险判断」也是「记忆/文档里的声明」的一种** ——
同样需要**先核实前提再采信**。我标 🅲 为「危险」时，凭的是「`DO UPDATE` 会覆盖」这个**直觉**，
没有去查「它到底更新哪些列」和「有没有人工入口」。

📌 判据：**评估方案风险时，「覆盖人工改动」这类判断必须落到两个具体核实上** ——
① **它实际写哪些列**（读 SQL 原文）② **谁有权限写这些列**（grep 全代码 + 查有无后台入口）。
两者都没查 ⇒ 该风险判断**不可用**。

---

## 三、改了什么（一处 SQL + 五处注释 + 三条测试）

| # | 位置 | 改动 |
|---|---|---|
| 1 | `CONTENT_SEED_SQL` 末尾 | `ON CONFLICT DO NOTHING` → **`ON CONFLICT (url) DO UPDATE SET <8 个配置列> ... WHERE <任一列不同>`** |
| 2 | `CONTENT_SEED_SQL` 文档注释 | 重写：为什么改、为什么不用迁移、为什么不碰运行时状态、`IS NOT` vs `<>`、与重建表的顺序、**明知的取舍** |
| 3 | DDL 里 `content_source` 的注释 | 同步（并加一条「若改回 `DO NOTHING`，存量库配置静默失效会回来」）|
| 4 | `init_database` 的顺序注释 | 补「重建后才对齐配置」的分工说明 |
| 5 | `rebuild_content_source_with_check` 注释 | 补「**重建管结构，seed 管配置**」|
| 6 | 测试注释 | 同步（并注明 10-03 由 `DO NOTHING` 进一步改为条件 UPSERT）|

### 3.1 SQL 的关键点（4 条，每条都有测试守）

```sql
ON CONFLICT (url) DO UPDATE SET
    name = excluded.name,  kind = excluded.kind,  category = excluded.category,
    cefr_hint = excluded.cefr_hint,  license = excluded.license,
    redistributable = excluded.redistributable,  tz_offset_min = excluded.tz_offset_min,
    enabled = excluded.enabled,
    updated_at = excluded.updated_at
WHERE content_source.name IS NOT excluded.name
   OR ... OR content_source.enabled IS NOT excluded.enabled;
```

| # | 要点 | 不做会怎样 |
|---|---|---|
| 1 | **SET 里没有运行时状态列** | 覆盖 `last_fetch_at`/`fail_count` ⇒ 退避策略失真、抓取节奏错乱 |
| 2 | **`created_at` 不在 SET** | 「原始创建时间」被每次启动改写 |
| 3 | 🔴 **`WHERE 任一列不同`** | 每次启动无条件写 ⇒ ① `updated_at` 永久失真（「上次配置变更时间」没意义）② 24 行无谓写 |
| 4 | 🔴 **`IS NOT` 而不是 `<>`** | `NULL <> 'x'` 在 SQLite 求值为 **NULL** ⇒ 整条 OR 链不为真 ⇒ **该行永不更新（静默失效）** |

---

## 四、验证（五层 · 含 2 项证伪）

### 4.1 新增单测 3 条（`api_server::schema::tests`）

| 测试 | 守什么 |
|---|---|
| `test_seed_upsert_realigns_existing_source_config` | **主目的**：造生产状态（HN `enabled=1`）→ 跑 seed → 变 0；且 `last_fetch_at`/`fail_count`/`created_at` **不变**；`updated_at` 在配置变时更新；**无变化时不写** |
| `test_seed_upsert_handles_null_columns` | 🔴 **守门人**：`cefr_hint` 为 NULL 时也必须被对齐（`<>` 会静默失效）|
| `test_seed_upsert_does_not_touch_other_sources` | **不误伤**：seed 里没有的「手工源」不删不改；其他源的运行时状态不动 |

> ⚠️ 写第二条时踩到一个坑值得记：最初我读 `last_fetch_at` 用 `(String, i64)`，
> 而新库那列是 **NULL** ⇒ 报 `InvalidColumnType`。
> 更深的问题是**断言太弱**：`NULL → NULL` **无法区分**「seed 没写」与「seed 写了 NULL」⇒ **假绿**。
> 🔑 改成「先设一个非 NULL 值，再断言它还在」—— 这样两个方向都可区分。

### 4.2 🔴 证伪两项（确认测试**不是假绿**）

「新增的防漂移断言，故意破坏一次，确认它真会红」：

| 注入 | 结果 |
|---|---|
| ① 把 `IS NOT` 改回 `<>` | ✅ **只有** `test_seed_upsert_handles_null_columns` 红（其余 8 条绿）⇒ 该测试**只由它决定** |
| ② 把 `DO UPDATE ... WHERE` 改回 `DO NOTHING` | ✅ `test_seed_upsert_realigns_existing_source_config` + `handles_null_columns` **两条红** |

两次注入**均已字节级还原**（`md5` 前后一致：`5f7fbfa8…`）⇒ 无残留。

### 4.3 真实库副本演练（`examples/migration_drill.rs`，用**生产导出**的 24 行）

```
fixture: prod_sources.json（从生产只读导出 · 24 行 · 23 个启用 · HN enabled=1）

── ① 复刻出的「生产状态」（启动前）──  行数 24 · 启用 23 个（已禁用: id=3 Ars）
── ② 跑完真实启动路径 ──              行数 24 · 启用 22 个
── ③ 逐行 diff ──
   id=5   Hacker News    改动: enabled, updated_at
        enabled: 1 → 0   （代码里的值）
── ④ 判定 ──
   ① 该改的改了: HN enabled 1 → 0            ✅
   ② 运行时状态未被碰: ✅ 全部完好
   ③ 幂等（第二次跑零改动）: ✅
   ④ 启用数 23 → 22
```

🔑 **逐行 diff 是关键证据**：**只改了 1 行、只改了 2 列**（`enabled` + `updated_at`）
⇒ 「精准」不是靠推理，是**逐列比对**出来的。而这 24 行**全是生产真实数据**。

### 4.4 预检

| 项 | 结果 |
|---|---|
| `cargo fmt --check` | ✅ 通过 |
| `cargo clippy --workspace --all-targets -D warnings` | ✅ 通过 |
| `cargo test --workspace` | ✅ **172 + 20 passed**（原 169 + 新增 3）|

---

## 五、⚠️ 一个**明知的取舍**（需要你确认接受）

改完之后：**不能靠手工改库来临时调整源配置了** —— 下次启动会被 seed 冲掉。

- ✅ **好处**：配置只有一处权威（代码），不再出现「代码说弃用、库说还在用」这种漂移
- ⚠️ **代价**：想临时禁用某源，得**改代码 + 重启**（而不是一条 UPDATE）
- 📌 我认为这个取舍是**对的**：本次事故的根因正是「配置有两处来源，且库那处不会自动收敛」。
  而且「手工改库」在实践中只发生过一次（Ars），是为了**绕过** `DO NOTHING` 的无奈之举。

**若你不接受这个取舍**，替代方案是：只把 HN 一行手工改掉（🅱），
不动 seed —— 但那就**保留了下次再踩的可能**（下次换一个源弃用，又会忘记改库）。

---

## 六、⏳ 待你定：**是否部署**

生产跑的还是 v0.1.2 的二进制 ⇒ **HN 的 `WARN 未知的源类型 hn` 仍会每 6 小时出现一次**。

| 项 | 说明 |
|---|---|
| 影响 | ⚠️ **仅日志噪音 + `enabled` 列语义失真** —— HN **已不再产生内容**（适配器已删，未发网络请求）|
| 改动面 | 1 处 SQL + 注释 + 测试（**不涉及内容、不涉及 API**）|
| 风险 | 低 —— 已用**生产真实数据**演练过；且 `WHERE` 保证无变化时零写入 |
| 回滚 | 二进制层面回滚（`.prev`）；数据层面**无需回滚**（唯一改动是 HN 的 `enabled` 1→0，本就该是 0）|

**要部署吗？**（部署后我会再核一次：HN 变 0、启用数 22、日志不再出现 `未知的源类型`）

---

## 七、产出

| 文件 | 说明 |
|---|---|
| `backend/crates/api_server/src/schema.rs` | seed 改条件 UPSERT + 注释 + 3 条测试 |
| `backend/examples/migration_drill.rs` | 🆕 真实数据演练工具（可复跑）|
| `scripts/trace_verify/bin/dump_prod_sources.py` | 🆕 只读导出生产 `content_source` |
| `scripts/trace_verify/fixtures/prod_sources.json` | 🆕 生产快照（24 行 · 仅源配置，无内容/用户数据）|
| 本报告 | 完整证据链 |
