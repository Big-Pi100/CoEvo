# 立项：`subscription_expires` 格式统一（隐式契约收口）

*2026-10-21 · 状态：**待批**（本文只立项，不改代码）*
*前置：`docs/review/iap-expiry-rollback-2026-10-20.md` §8.7 遗留项*

---

## 一、摘要

`users.subscription_expires` 是一个 **TEXT** 列，当前有**两套写法**、**三种规避手法**、
**三处原样透传**，但**没有任何地方强制格式**。

**关键事实（先说清楚，避免夸大）**：

> 🔑 **生产库现在没有混用** —— 3 个非空值**全部是 RFC3339**，纯日期 **0 个**。
> 写纯日期的那条路径（`extend_subscription`）**零调用点 = 死代码**。

⇒ 所以这不是"正在出错的 bug"，而是**一颗未爆的雷**：
契约是隐式的，靠三处手工规避维持；谁按模块头注释启用那条死路径，立刻混入纯日期。

**建议**：做，但**优先级低于上架**。理由见 §七。

---

## 二、现状核验（实测，非转述）

### 2.1 生产库数据分布（2026-10-21 实测）

| 格式 | 数量 | 账号 |
|---|---|---|
| **RFC3339**（`2026-10-21T14:04:22Z`）| **3** | `1133f074`（无邮箱）· `4046c168`（无邮箱）· `62731265`（mr.bigpi）|
| **纯日期**（`2026-10-21`）| **0** | — |
| 其它格式 | **0** | — |
| NULL / 空 | 6 | 其余账号 |

### 2.2 写入方（2 条路径）

| # | 路径 | 写出格式 | 状态 |
|---|---|---|---|
| 1 | `iap_handlers.rs` → `set_expires_if_later` | **RFC3339** | ✅ **唯一活跃**（IAP 上报）|
| 2 | `extend_subscription` → `set_expires` | **纯日期** `%Y-%m-%d` | 🔴 **死代码：全网零调用点** |

⚠️ **一处更正**：我在 10-20 的注释里把路径 2 写成了 `activate_subscription`——
**函数真名是 `extend_subscription`**（`subscription.rs:239`）。本轮一并修正注释。

### 2.3 读取方（5 处，**三种不同的规避手法**）

| # | 位置 | 手法 | 是否有隐患 |
|---|---|---|---|
| 1 | `is_subscription_active`（`subscription.rs:119`）| 手写：`len==10 && [4]=='-'` ⇒ 补 `T00:00:00Z` | 🟠 只认「10 字符且第 5 位是 `-`」，其它形态（如带 `+08:00` 偏移）落进 RFC3339 分支后 parse 失败 ⇒ **静默判 false** |
| 2 | `set_expires_if_later`（`:182`）| SQL `datetime()` 归一 | ✅ 稳 |
| 3 | `maintenance.rs:166` | `date(substr(v,1,10))` | ✅ 对两种格式都有效，但**只取日期** |
| 4 | `profile_handler`（`routes.rs:1101`）| **原样透传**给端侧 | 🟠 端侧拿到什么取决于写入方 |
| 5 | `user_subscription_handler`（`:1195`）· `preferences_get_handler`（`:1299`）| 同上 | 🟠 同上 |

### 2.4 端侧影响（比预想小）

端侧的 `isExpired` 读的是**服务端算好的 `status`**（`SubscriptionStatus.expired`），
**不在本地 parse 时间** ⇒ 格式不会导致端侧判错。

但 `expiresAt` 是**原样字符串展示**（「到期日 2026-10-21」）⇒ 若混入纯日期，
界面会显示 `2026-10-21`（无时刻），而 IAP 的显示 `2026-10-21T14:04:22Z` 需要端侧格式化。
📌 **同一个界面会因写入方不同而显示不同形态** —— 这是"用户可见"的那一层不一致。

### 2.5 注释已经过时

`maintenance.rs:152` 写着：

> ⚠️ `subscription_expires` 有**两种格式**（**正常订阅 `YYYY-MM-DD`** / 试用遗留带时刻）

**方向反了**：现在**正常订阅（IAP）是 RFC3339**，纯日期才是那条死路径。
这种"注释与现实相反"比没注释更危险 —— 它会让下一个人照错的写。

---

## 三、风险清单（按严重度）

| # | 风险 | 触发条件 | 后果 | 严重度 |
|---|---|---|---|---|
| **R1** | 启用 `extend_subscription`（它自称"所有延期操作统一走此函数"）| 任何人做「后台开通/赠送/补偿」| 该用户变纯日期；`is_subscription_active` 还能兜住，但**透传给端侧的展示形态变了**；后续任何字符串比较都可能错向 | 🔴 **高**（最可能发生）|
| **R2** | 新增第 4 种读法时忘记归一 | 加一个新判据（如「剩余天数 ≤3 天提醒」）| **静默算错**，不报错（本项目最痛的一类）| 🔴 高 |
| **R3** | 未来出现带时区偏移的格式（`+08:00`）| 换支付渠道 / 换 Apple 环境 / 手填 | `is_subscription_active` 的 `len==10` 分支漏掉，RFC3339 parse 失败 ⇒ **静默判「未订阅」** | 🟠 中 |
| **R4** | 注释与现实相反（§2.5）| 下一个人读代码 | 照着错的方向写 | 🟠 中 |
| **R5** | 函数名引用错误（`activate_subscription`）| 排查时搜不到 | 浪费排查时间 | 🟡 低 |

**当前实际损失：0**（生产 3 个值全 RFC3339，无判错、无展示异常）。
以上全部是**未发生的**风险。

---

## 四、方案对比

### ✅ 方案 A：统一 RFC3339，并把「写」和「读」各收口到一处（推荐）

**契约**：`users.subscription_expires` **只允许存 RFC3339（UTC，秒级）**。

| 动作 | 具体 |
|---|---|
| 写入口收口 | 只保留 `set_expires_if_later`（IAP）+ `set_expires`（管理端，**也改成要求 RFC3339**）；`extend_subscription` 内部改为输出 RFC3339 |
| 读入口收口 | 新增 `parsed_expires(conn, user_id) -> Option<DateTime<Utc>>`；`is_subscription_active` / 任何新判据**一律用它**，不再各写归一 |
| 数据迁移 | `UPDATE users SET subscription_expires = substr(v,1,10)||'T00:00:00Z' WHERE length(v)=10`（当前 **0 行受影响**，但保证幂等可重放）|
| 注释更正 | `maintenance.rs:152` 的"正常订阅 YYYY-MM-DD"反过来写；`subscription.rs` 两处 `activate_subscription` → `extend_subscription` |
| 断言 | ① 写入口只有 2 个（`set_expires*`），且都要求 RFC3339 ② `is_subscription_active` 不再自己归一（走统一解析）③ `extend_subscription` 输出含 `T` |

**优点**：一次收口，后续任何新读法都拿不到裸字符串；迁移 0 风险（0 行数据）。
**缺点**：`is_subscription_active` 要改调用形态（内部改为调统一解析），有回归面。
**工作量**：后端 ~120 行改动 + 3 条断言 + 1 次部署。**端侧零改动**。

### 方案 B：统一为「日期」粒度（`YYYY-MM-DD`）

❌ **不推荐**：IAP 的到期日是**秒级**，砍成日期会丢掉一天内的精度。
沙盒续期周期短（几分钟一次），按日粒度会让「刚过期 3 小时」判成「今天仍有效」。

### 方案 C：维持混用，只加一个解析函数

🟠 **可接受但不彻底**：解决 R2/R3，但 R1（有人写纯日期）仍在。
且"两种格式都合法"这个契约会一直传下去，每新增一处都得想一遍。

---

## 五、推荐方案 A 的实施清单（可逐条验收）

| # | 步骤 | 验收判据 |
|---|---|---|
| 1 | 新增 `parsed_expires()`，返回 `Option<DateTime<Utc>>` | 单测：RFC3339 / 纯日期 / 空 / 非法 各 1 条 |
| 2 | `is_subscription_active` 改为调它 | 行为不变：现有 314 项测试全绿 |
| 3 | `extend_subscription` 输出改 RFC3339（`…T00:00:00Z`）| 单测断言写入值含 `T` |
| 4 | `set_expires` 入口校验格式（非法 ⇒ Err）| 单测：传 `2026-10-18` 应 **Err**（强制契约） |
| 5 | 数据迁移（幂等）| 重放两次，第二次影响 0 行 |
| 6 | 修正两处注释（§2.5）| grep `activate_subscription` 零命中 |
| 7 | 断言：写入口只 2 个 · 读入口统一 · 旧注释不复活 | 新增 4 条，证伪各红 1 条 |

⚠️ **顺序约束**：先做 1–2（不改行为），再做 3–4（改契约），最后 5（迁移）。
反过来会有一段时间「代码要求 RFC3339，但库里还有纯日期」。

---

## 六、验收标准（做完怎么算成功）

1. 生产库 `SELECT` 出的每个非空 `subscription_expires` 都匹配 `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`
2. `grep -rn "subscription_expires" backend/` 里，**只有** `set_expires*` / `parsed_expires` / 迁移脚本 / 测试 出现裸 SQL
3. 新增第 4 种读法时，代码里**没有**任何手写归一的可能（因为只有 `parsed_expires` 返回已解析值）
4. `extend_subscription` 要么被启用且写 RFC3339，要么被**显式标注为未启用**（不能保持"自称统一入口但零调用"）

---

## 七、什么时候做（优先级判断）

| 场景 | 建议 |
|---|---|
| **现在（准备提审）** | ❌ **先不做** —— 它当前**零实际损失**，而改动会碰 `is_subscription_active`（**订阅闸门**，同步/翻译/云端书架全依赖它）。提审前动闸门，收益/风险不划算 |
| 做「后台开通 / 赠送 / 手动补偿」之前 | 🔴 **必须先做**（R1 的直接触发点）|
| 新增任何「按到期日算」的功能之前 | 🔴 必须先做（R2）|
| 接入第二个支付渠道之前 | 🔴 必须先做（R3）|
| 顺手清理死代码时 | ✅ 可以带上（只做 3–4 + 6，不动 1–2）|

📌 **一句话**：**这是一颗需要按计划拆的雷，不是需要现在救的火。**

---

## 八、本文不做什么（边界）

- ❌ 不改 schema（不加 CHECK 约束）—— SQLite 给已有表加约束要重建表，代价远大于收益
- ❌ 不动端侧（`expiresAt` 只做展示，不 parse，格式不影响判定）
- ❌ 不动 IAP 的三层缓存与归属校验（那是 `iap-expiry-rollback-2026-10-20` 的范围，已完成）
- ✅ 只做：**契约显式化 + 读写入各收口一处 + 注释更正**

---

## 九、参考

- 前置事故：`docs/review/iap-expiry-rollback-2026-10-20.md`（到期日被旧交易回退，已修）
- 同族判据：**「同一件事的口径只能有一处权威」** —— 本次立项就是给这个字段建那一处

---

## 十、✅ 实施记录（2026-10-21 00:5x · 白哥批「按 A 方案修复」）

### 10.1 代码改动

`subscription.rs`
- 🆕 `parse_expires(&str) -> Option<DateTime<Utc>>` —— **纯函数、全库唯一解析入口**
  接受：RFC3339（含 `+08:00` 偏移）· 纯日期（当日 00:00 UTC）· SQLite 空格分隔
- 🆕 `parsed_expires(conn, user_id)` —— 读库 + 解析（比较/计算一律走它）
- 🆕 `canonicalize_expires(&str) -> Option<String>` —— 落库前的唯一形态
- `is_subscription_active` → 改走 `parsed_expires`（**删掉手写的 `len==10` 补 `T00:00:00Z`**）
- `set_expires` / `set_expires_if_later` → **写入时规范化**：
  能理解的值一律收敛成 RFC3339；**无法解析的返回 Err**（不再静默不写）

`schema.rs`（迁移，启动时跑）
```sql
UPDATE users SET subscription_expires = strftime('%Y-%m-%dT%H:%M:%SZ', subscription_expires)
 WHERE subscription_expires IS NOT NULL
   AND trim(subscription_expires) <> ''
   AND datetime(subscription_expires) IS NOT NULL
   AND subscription_expires <> strftime('%Y-%m-%dT%H:%M:%SZ', subscription_expires)
```

### 10.2 🔴 实施中发现并修掉一个**隐藏的数据丢失 bug**

`extend_subscription` 旧实现：

```rust
let base = match &old_expires {
    Some(d) if d.as_str() >= today.as_str() => d.clone(),   // ① 字符串比较
    _ => today.clone(),
};
let base_date = NaiveDate::parse_from_str(&base, "%Y-%m-%d")
    .unwrap_or_else(|_| Utc::now().date_naive());           // ② 失败 ⇒ 静默用今天
```

对 IAP 用户（值是 RFC3339）：

| 步 | 结果 |
|---|---|
| ① `"2026-10-21T…Z" >= "2026-10-21"` | **true**（前缀相同、更长）|
| ② `parse_from_str("%Y-%m-%d")` | **失败**（尾部有多余字符）|
| ③ `unwrap_or_else(今天)` | **静默退回今天** |
| ④ `new = 今天 + days` | 🔴 **用户已付费的剩余时长被清零** |

⇒ 一旦有人启用「后台赠送 / 补偿 / 手动延期」，对 IAP 用户操作就是**扣掉他的剩余权益**。

**修法**：`base` 改用 `parse_expires`（比较 `DateTime`），输出 RFC3339。
**单测**：`test_extend_subscription_preserves_remaining_days`。
**证伪实测**（把旧写法放回）：`got=2026-11-19 00:00` vs 期望 `2026-11-20 14:04` —— 差 **1 天 14 小时**，正好是「今日本地 00:00 起算」的偏移。

### 10.3 🔴 迁移第一版有漏（预演抓到的）

第一版写成 `length(trim(x)) = 10`（只认纯日期）—— 预演时发现 **`2026-10-21 14:04:22` 这种空格形态会被漏掉**。
📌 「只处理我想到的那一种」正是本项目的典型失效模式。
改成 `datetime(x) IS NOT NULL + strftime` ⇒ **能解析就归一**，覆盖所有历史形态，且天然幂等。

**副本预演结果**（生产库副本，未触碰真实数据）：

| 场景 | 结果 |
|---|---|
| 生产现状（3 个 RFC3339）| 首次 **0 行** · 复跑 **0 行** |
| 造 `2026-10-21`（纯日期）| → `2026-10-21T00:00:00Z` ✅ |
| 造 `2026-10-21 14:04:22`（空格）| → `2026-10-21T14:04:22Z` ✅ |
| 造 `2026-10-21T14:04:22Z`（已是目标）| **不动** ✅ |
| 造 `garbage-value`（脏值）| **不动** ✅（留给上层报错，不静默改写）|

### 10.4 验证

| 项 | 结果 |
|---|---|
| `cargo test` | **321 passed**（314 → **+7**）|
| `cargo fmt --check` / clippy `--workspace -- -D warnings` | ✅ / **exit 0** |
| `iap_verify` | **289 项**（281 → +8，新增 ㉑ 组）|
| 迁移副本预演 | 见 10.3 ✅ |

🔴 **证伪 ×3，全部精确命中**：

| 注入 | 红的条目 |
|---|---|
| `extend_subscription` 用回旧 base 计算 | `test_extend_subscription_preserves_remaining_days`（含具体丢多少）|
| `set_expires` 不规范化 | `test_set_expires_normalizes_to_rfc3339` + `test_set_expires_rejects_garbage`（恰好 2 条）|
| `parse_expires` 拒绝带偏移 | `test_parse_expires_accepts_all_legacy_shapes` + `test_is_active_handles_legacy_shapes`（恰好 2 条）|

### 10.5 落地后的契约

| 层 | 约束 | 由谁保证 |
|---|---|---|
| 写入 | 只能落 RFC3339 | `set_expires*` 内部 `canonicalize_expires` |
| 存量 | 任何可解析形态都被拉齐 | `schema.rs` 迁移（幂等）|
| 读取 | 只有一个入口返回已解析值 | `parsed_expires` |
| 断言 | 上述三条都不许退化 | ㉑ 组 8 条 |

### 10.6 ⏳ 待部署

纯后端改动 ⇒ **只部署后端**，**端侧无需出包**。

### 10.7 ✅ 部署与验证（2026-10-21 00:5x）

| 项 | 值 |
|---|---|
| 二进制 sha256 | `96406d123dfcbadc…` —— 与构建产物**逐字节一致** |
| 回滚点 | `.prev` = `4c5d7332…`（10-21 到期日单调写入版）|
| 部署前备份 | `coevo.db.bak-preformat-20261021`（32 MB · 600）|
| health / 探针 / ERROR | OK · **35/35** · 重启窗 **0 条 ERROR** |

#### 🎯 迁移验证（生产库，实测）

| 检查 | 结果 |
|---|---|
| 迁移前 3 个非空值 | `2026-10-02T04:09:11Z` · `2026-10-09T05:54:27Z` · `2026-10-21T14:04:22Z` |
| 迁移后 | **完全一致**（本来就是目标形态 ⇒ 条件 `x <> strftime(...)` 不成立 ⇒ **影响 0 行**）|
| 全库格式合规扫描 | **0 个不合规**（每个非空值都匹配 `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`）|

#### 🚪 订阅闸门回归（最关键 —— 它后面挂着同步/翻译/云端书架）

| 账号 | `POST /api/sync/push` | 判读 |
|---|---|---|
| `mr.bigpi`（有订阅）| **200** | ✅ 闸门正常放行 |
| `appreview`（无订阅）| **403** | ✅ 正常判「未订阅」，**不是崩溃** |

📌 特意测了**两类账号**：只测其中一个方向无法区分「判据正确」与「一律放行/一律拒绝」。

#### 结论

- 本次是**零行为变化**的收口（数据 0 行、闸门行为不变）⇒ 风险按预期落空
- 后续任何新增的「按到期日算」的逻辑，**只有一个入口可用**（`parsed_expires`），
  不会再出现第四种规避手法
