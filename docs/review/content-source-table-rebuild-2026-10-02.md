# 重建 `content_source` 表（让生产库也获得 CHECK）· 2026-10-02

> **给白哥** · 起因：白哥决定「**重建 `content_source` 表**」（上轮报告的遗留项 2）。
>
> 背景：`category` 的 `CHECK` 是**二轮**（`456a72b`）才加进建表语句的，
> 而 `content_source` 表是**一轮**（`6c7d60d`，2026-09-29）建的。
> `CREATE TABLE IF NOT EXISTS` **不重建已存在的表** ⇒ **生产库根本没有那个 CHECK**。
>
> 🔴 SQLite **不支持 `ALTER TABLE ADD CONSTRAINT`** ⇒ 想让旧库拿到 CHECK，**只能重建表**。

---

## 一、结论

| 项 | 结果 |
|---|---|
| 重建动作 | 「建新表 → 拷数据 → 删旧表 → 改名 → 建索引」，在**单个事务**内 |
| 幂等 | ✅ 判据 = 「DDL 里的类别集合 **≡** `CONTENT_CATEGORIES`」⇒ 相同就跳过 |
| 数据 | ✅ **一行不丢**（含 seed 里没有的手工源 + 运行时状态 `last_fetch_at`/`fail_count`）|
| 附带改动 | seed 从 `INSERT OR IGNORE` → **`ON CONFLICT DO NOTHING`**（见 §三，**关键**）|
| 测试 | `cargo test -p api_server` **160 passed** · 证伪 **4/4** |
| 部署 | ❌ **未部署** |

---

## 二、🔴 演练中发现：不关外键，生产**必炸**

`content_pool.source_id REFERENCES content_source(id)`，而生产连接的
`PRAGMA foreign_keys = ON`（`db_pool.rs` 建连接时设）。

**副本演练实测**（临时不关外键）：

```
删旧表失败: FOREIGN KEY constraint failed（事务已回滚，旧表未受影响）
```

⇒ 两件事被证实：
1. **不关外键，`DROP TABLE content_source` 直接失败** —— 生产上会导致 `init_database` 抛错
2. **事务回滚生效** —— 失败时旧表原封不动（数据安全）

**所以重建的顺序是**：

```
PRAGMA foreign_keys = OFF          ← ⚠️ 必须在 BEGIN **之前**（SQLite 规定事务内改无效）
BEGIN IMMEDIATE
  CREATE TABLE content_source_rebuild (...)      ← 复用同一份 DDL，只换表名
  INSERT INTO ..._rebuild (15 列) SELECT 15 列 FROM content_source
  行数校验（不等则报错）
  DROP TABLE content_source
  ALTER TABLE ..._rebuild RENAME TO content_source
  建索引（**必须在这时**，见 §四）
  悬空引用校验（不得比重建前多）
COMMIT
PRAGMA foreign_keys = ON            ← 🔴 无论成败都要恢复
```

⚠️ **一个容易漏的点**：`PRAGMA foreign_keys` 是**连接级**设置，而生产用的是
**连接池**。若失败路径上没恢复 `ON`，那条连接会**永久**不校验外键 ——
故障是**静默的**（不报错、不告警），只能等数据出问题才发现。
⇒ 实现里把「恢复」放在**无条件执行**的位置，并在测试里断言
`PRAGMA foreign_keys == 1`。证伪确认：注释掉恢复 ⇒ 断言报红（`left: 0, right: 1`）。

---

## 三、🔴 关键配合：seed 必须改用 `ON CONFLICT DO NOTHING`

**只重建表、不改 seed，收益有限** —— 因为 seed 用的是 `INSERT OR IGNORE`，
而它**会静默吞掉 CHECK 违规**（不只是重复冲突）。

| 写法 | 已存在同 url | category 写错 |
|---|---|---|
| `INSERT OR IGNORE` | 跳过 ✅ | 🔴 **静默丢弃**（源少一个，无任何报错）|
| `ON CONFLICT DO NOTHING` | 跳过 ✅ | ✅ **报错**（立刻发现）|

⇒ 两者是**一对**：重建让约束存在，改 seed 让约束**真的能报错**。
📌 判据：**要「忽略重复」就只忽略重复，别用「忽略一切」的语法。**

**连带发现一个顺序陷阱**：seed 原本在 `run_migrations_inner` **之前**执行。
现在 `content_source` 的 CHECK 可能在**迁移里被重建更新**（如从 8 类扩到 12 类），
若 seed 先跑，新分类的行会撞上**旧 CHECK** 而**报错**（`ON CONFLICT` 不忽略 CHECK）。
⇒ **已把 seed 移到迁移之后**。

📌 判据：**「先保证结构正确，再灌数据」** —— 迁移属于「结构」，seed 属于「数据」。

---

## 四、🔴 另一个静默陷阱：索引名被旧表占着

若把**建表 + 建索引**写成同一批 SQL 用在重建里：

1. 旧表还占着 `idx_csrc_url` 这个名字
2. `CREATE UNIQUE INDEX IF NOT EXISTS idx_csrc_url` ⇒ **静默跳过**（名字已存在）
3. 新表**没有唯一索引**
4. ⇒ seed 的 `ON CONFLICT (url)` 语义失效

⇒ **已把索引拆成独立常量**，重建时**必须在新表改名之后**建
（那时旧表刚被 DROP，它的同名索引才消失）。

📌 判据：**`IF NOT EXISTS` 遇到「名字被别的表占着」时会假装成功。**

---

## 五、改动清单

| 文件 | 改动 |
|---|---|
| `schema.rs` | 🔑 原 `CONTENT_SCHEMA_SQL` **拆成 4 段常量**（建表 / 索引 / 池 / seed）—— 因为重建必须**复用同一份建表 DDL**，不能有两份 |
| `schema.rs` | 🆕 `rebuild_content_source_with_check()` + `rebuild_content_source_body()` + `content_source_check_categories()`（解析函数，迁移与断言**共用**）|
| `schema.rs` | `init_database`：拆段执行；**seed 移到 `run_migrations_inner` 之后** |
| `schema.rs` | seed：`INSERT OR IGNORE` → `INSERT ... ON CONFLICT DO NOTHING` |
| `schema.rs` | 表定义上方的注释：删掉已过时的「要让旧库也拿到它…本项目暂未做」 |
| `schema.rs`（测试） | 🆕 `test_rebuild_content_source_gains_check_and_keeps_data`（副本演练 9 步）· `test_content_source_check_matches_categories` 改为**复用同一个解析函数**（集合相等）|
| `content_rss.rs` | 注释里的常量名同步 |

### 5.1 为什么「拆常量」是必要的（而不是复制一份 DDL）

重建**必须**用与建库**完全相同**的 DDL —— 否则「新库的表」与「重建出的表」是两份定义，
**必然漂移**。但建表语句在 `const` 里（不能 `format!` 拼接），所以把它**拆出来单独成常量**，
重建时只做**表名替换**（并**显式校验替换成功**，失败则报错而不是静默建错表）。

📌 判据：**同一件事的口径只能有一处权威。**

---

## 六、验证

### 6.1 副本演练（`test_rebuild_content_source_gains_check_and_keeps_data`）

**为什么必须造「旧库」**：用 `init_database` 建初始状态的话，库**已经是新结构**
（CHECK 就在建表语句里）⇒ 重建逻辑**根本不会执行** = 测了个空。

**为什么显式 `PRAGMA foreign_keys = ON`**：生产连接是 ON，而 `open_in_memory()` 默认 **OFF**。
不显式打开的话，「`DROP TABLE` 被外键挡住」这个最危险的点**根本不会暴露**
⇒ 就是「测试全绿但生产起不来」。

演练步骤与断言（**9 项**）：

| # | 验什么 |
|---|---|
| 1 | 前提：旧表**确实没有** CHECK（否则测不到重建）|
| 2 | 重建后 CHECK **集合相等**于 `CONTENT_CATEGORIES` |
| 3 | 🔴 CHECK **真的生效**（插入 `category='bogus'` 必须报错）—— 这才是重建的目的 |
| 4 | 🔴 **手工源 `id=99` 原样保留** —— 它在 seed 里**不存在**，丢了没人补（比验 id=1 更硬，id=1 丢了 seed 会重插而掩盖问题）|
| 5 | 运行时状态保住：`fail_count=7` · `last_fetch_at=NULL` · 另一行的 `last_fetch_at` 时间戳 |
| 6 | seed 的新源（id 15–24）已补插 |
| 7 | 🔴 **唯一索引仍在**（再插一个重复 url 必须报错，否则 `ON CONFLICT` 语义失效）|
| 8 | 🔴 `content_pool` 悬空引用 = 0 + `PRAGMA foreign_keys` 已恢复为 1 |
| 9 | 幂等：再跑一遍 `init_database`，**DDL 不变**（不该再重建）|

### 6.2 证伪（**4/4**，确认断言真会红）

| # | 注入 | 结果 |
|---|---|---|
| 1 | 禁用重建调用 | ✅ 报红：`left: {}`（空集 = 没重建）vs 期望的 12 类 |
| 2 | 拷贝时漏掉 `fail_count` 列 | ✅ 报红：`fail_count` 期望 7、实得 0 |
| 3 | 不恢复 `PRAGMA foreign_keys = ON` | ✅ 报红：`left: 0, right: 1` |
| 4 | **不关外键** | ✅ 报红：`删旧表失败: FOREIGN KEY constraint failed（事务已回滚，旧表未受影响）` |

**证伪 2 的价值**：`INSERT ... SELECT` 用了同一个列变量，所以「漏一列」**不会报错**，
行数也照样相等 —— 只有**逐行内容比对**能发现。
📌 印证判据：**「数字对上」≠「成员对上」**。

**证伪 4 的价值**：这是**副本演练的核心产出** —— 在本地就把「生产会炸的点」找出来了。

### 6.3 全量

```
cargo test -p api_server   →   160 passed; 0 failed
cargo clippy -p api_server --tests   →   无 unused / error
```

---

## 七、风险与回滚

| 项 | 说明 |
|---|---|
| **数据丢失风险** | 🟢 低。全程单事务；拷贝后校验行数；失败自动 `ROLLBACK`；`DROP` 前**先确认新表行数一致** |
| **外键失效风险** | 🟢 低。失败路径也恢复 `ON`；测试断言值 |
| **既有悬空引用** | 🟢 不影响。重建**前后都测悬空数**，只要「不变多」就通过（不把历史问题算成本次重建的错）|
| **回滚方式** | 代码回滚（`git revert`）+ 数据本来就在（重建不做破坏性删改）。⚠️ 回滚后旧库**会退回没有 CHECK** 的状态（不报错，只是约束没了）|
| **未做 `VACUUM`** | 理由：24 行的小表，重建留下的空闲页可忽略；而 `VACUUM` 会**长时间持写锁**，不适合放在启动迁移里 |
| **未留备份表** | 理由：留 `content_source_backup_*` 会**破坏 `test_full_schema_all_tables_present`** 的「表集合恰好相等」断言。改用「**DROP 前置校验**」替代事后备份 —— 事前验证比事后补救更有效 |

🔴 **部署须知**：这次改动会让**下一次启动**就执行重建（生产库当前无 CHECK ⇒ 必然触发）。
重建是**幂等**的，之后每次启动都跳过。

---

## 八、🆕 本轮判据

| 判据 | 触发它的事实 |
|---|---|
| 🔴🔴 **`PRAGMA foreign_keys = OFF` 必须在 `BEGIN` 之前**（SQLite 规定事务内改无效），且**无论成败都要恢复** | 生产用连接池 ⇒ 不恢复会让**那条连接永久**不校验外键（静默故障）|
| 🔴🔴 **重建表要「先关外键」** —— 否则 `DROP TABLE` 被引用它的外键挡死 | 实测 `FOREIGN KEY constraint failed` |
| 🔴 **`IF NOT EXISTS` 遇到「名字被别的表占着」会假装成功** | 旧表的索引占着名字 ⇒ 新表**静默没有唯一索引** |
| 🔴 **「改约束」要问「旧库会不会拿到」** —— `CREATE TABLE IF NOT EXISTS` 不重建表，而 SQLite 不能 ALTER 加 CHECK | 生产库**从来没有**过那个 CHECK |
| 🔴 **`INSERT OR IGNORE` 与「约束校验」互斥** —— 要幂等就用 `ON CONFLICT DO NOTHING`（只忽略重复） | 否则 CHECK 违规被静默吞掉 |
| 🔑 **seed（数据）必须排在 migration（结构）之后** | 新分类的行会撞旧 CHECK |
| 🔴 **测迁移必须造「迁移前」的状态**，用目标函数建初始状态 = 绕开要验的路径 | 同 `test_migrate_from_legacy_users_table` |
| 🔴 **测试环境必须与生产一致**（`foreign_keys` 默认 OFF，生产 ON） | 否则最危险的点测不出来 |
| 🔑 **「数据没丢」要用 seed 里不存在的行来验** | id=1 丢了 seed 会重插，掩盖问题 |
| 🔑 **重建的 DDL 必须复用同一份**（拆常量，不复制） | 两份定义必然漂移 |

---

## 九、复现

```bash
cd backend
cargo test -p api_server test_rebuild_content_source   # 副本演练
cargo test -p api_server                               # 全量（160）
```
