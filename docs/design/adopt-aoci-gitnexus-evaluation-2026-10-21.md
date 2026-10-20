# 评估：CoEvo 是否采纳 vibedollar 的 gitnexus + AOCI 管理方式

*2026-10-21 · 依赖：读 vibedollar 实况（资产/配置/操作手册/产物）+ 实测 CoEvo 规模与 gitnexus 索引质量*
*⭐ 本文只评估与给路径，**未改动任何项目配置***

---

## 一、结论（先说判断）

| 工具 | 建议 | 一句话理由 |
|---|---|---|
| **AOCI** | ✅ **值得上，但范围收窄** | 它解决我们的**真实瓶颈**：`MEMORY.md` 已顶到 16 KB，而里面混着大量「文件级事实」，正好可以搬出去 |
| **gitnexus** | 🟠 **先重建索引验证，暂不加 MUST 规则** | 我们的 88 个断言 + 证伪纪律在「行为契约」维度更强；图谱只在「调用关系」上有增量，且现有索引已不能用 |

**不要一次全量铺开**：vibedollar 是 117 条 index，CoEvo 如果按文件全量是 **233 条 ≈ 25K tokens**，
初始化成本比 vibedollar 还大一倍。建议按 §五 分三步，每步可独立停。

---

## 二、vibedollar 实际怎么做的（读到的，不是听说的）

### 2.1 三件产物

| 文件 | 作用 | 规模 |
|---|---|---|
| `aoci.txt` | **根清单**（`#AOCI-ROOT-MANIFEST`）：声明有哪几个卷、各自路径与格式 | 299 字节 |
| `aoci.meta.txt` | **标签字典**（A 层 / B 模块 / C 重要度 / E 规模）+ 配额 + 示例 | 2 KB |
| `aoci.code.txt` | **条目正文**：按目录分段，每个源文件一条 | 36 KB / **117 条** |

### 2.2 条目形态（一个文件一行）

```
subscription.rs[PD9S]: F:职责一句话 | R:code:xxx,code:yyy | A:锚点/常量 | S:不可推论且能防错的事实
```
- `[PD9S]` = A 层(P 持久化) + B 模块(D 数据状态) + C 重要度(9) + E 规模(S 100–200 行)
- **S 字段的准入门槛最严**：只写「不可推论 + 能防止错误」的事实
  - ✅ 真实踩过的坑（带日期/实测数字最有说服力）
  - ✅ 反直觉约束（"水位是 `>=` 语义，重取边界那条是刻意的"）
  - ✅ 双真源（"真值在 `site/deploy/`，本文件已废弃"）
  - ❌ 从 F/R/A 能推出来的、泛泛的"注意质量"

### 2.3 作用域三档（这是成本控制的关键）

| 档 | vibedollar 数量 | 含义 |
|---|---|---|
| **index** | **117** | 写条目、进 overview |
| **observe** | 2,516 | 只跟踪指纹，**不写条目** |
| **exclude** | 2,143 | 完全不纳入 |

📌 **117 条 ≈ 12.6K tokens**（2 块 @ chunk 7000）。这是"每次恢复系统认知"的读取成本。

### 2.4 维护闭环（有强制校验，不是随便写）

```bash
aoci maintain            # 拿漂移候选（改完代码、到稳定态后调一次）
aoci update-entry ...    # 整批作者化后一次提交（带 candidate_id + source_sha256）
aoci verify && aoci check    # 证明对齐（"五净"才算干净）
```

实测拦下过 4 类真实错误（candidate_id 抄错、条目写了目录前缀、S 超配额、E 规模档位错配）。

### 2.5 🔴 一个必须先知道的约束

AOCI 的 MCP 配置是 **`aoci mcp --repo E:/vibedollar`** —— **固定绑在 vibedollar**。
⇒ CoEvo 要用，必须**新增一个 MCP 条目**（如 `aoci-coevo`，`--repo E:/CoEvo`），
不能改现有那条（会抢 vibedollar）。

---

## 三、CoEvo 现状实测

### 3.1 代码规模（决定 AOCI 条目数）

| 区域 | 文件数 | 行数 |
|---|---|---|
| `app/lib`（Dart）| **185** | 56,178 |
| `backend/crates`（Rust）| **48** | 30,133 |
| `scripts`（Dart 断言 + Python）| 88 + 132 | — |

按 AOCI 的 E 档（L>400 / M 200–400 / S 100–200 / T<100）分：**L 65 · M 57 · S 56 · T 55**（共 233 个 dart+rs）。

### 3.2 gitnexus 索引状态（已实测）

CoEvo **已经被索引过**（2026-06-26）：

| 项 | 值 |
|---|---|
| files / nodes / edges | 1,159 / **22,269** / **32,470** |
| communities / processes | 457 / 300 |
| 状态 | 🔴 **`diverged`** —— "索引不在 HEAD，且 commit 差距无法计算（记录的 commit 可能已不在历史里）" |

**实测查 `is_subscription_active`**：

```json
{ "symbol": { "filePath": "backend/crates/api_server/src/subscription.rs", "startLine": 116 },
  "epistemic": "lower-bound",
  "incoming": {},                          // ← 🔴 空
  "outgoing": { "calls": ["get_current_expires"] },
  "staleness": { "status": "diverged" } }
```

🔴 **`incoming` 是空的，但这个函数实际被 `sync_handlers` / `translation` / 电子书上传等多处调用。**

⇒ 结论：**旧索引不可信**（既缺今天的改动，也缺完整性元数据）。要用它，必须先 `analyze --force` 重建。
⚠️ 这也提醒一点：**「图谱说没人调用」不等于没人调用**（与 vibedollar AGENTS.md 里那条
"`risk: UNKNOWN` 不等于低风险"是同一个坑）。

### 3.3 现有管理体系

| 层 | 内容 | 体积 |
|---|---|---|
| `MEMORY.md` | 四层索引（L0→L3）+ 判据速查 | **≤16 KB（已顶满）** |
| `references/criteria-index.md` | 判据完整索引（V/D/P 三类） | — |
| skills | 方法论（可验证核心逻辑、SQLite 迁移等） | — |
| `ARCHIVE.md` | 已完成细节/历史 | — |
| **88 个 Dart 断言脚本** | 行为契约 + 证伪纪律 | — |
| `docs/` | review / design / operations（601 md）| — |

---

## 四、重叠与冲突分析（最关键的一节）

### 4.1 谁补谁

| 维度 | CoEvo 现有 | AOCI | gitnexus |
|---|---|---|---|
| **每个文件的职责/关系** | 🟠 散落在 MEMORY 各行 | ✅ **一文件一条** | ❌ |
| **文件级踩过的坑** | 🟠 与跨文件方法论混在判据库 | ✅ **S 字段** | ❌ |
| **跨文件方法论（V/D/P 判据）** | ✅ **强** | ❌ 不覆盖 | ❌ |
| **行为契约（断言 + 证伪）** | ✅ **强（88 个套件）** | ❌ | ❌ |
| **调用关系 / 爆炸半径** | 🟠 靠 grep + 手工追链 | ❌ | ✅ **图谱** |
| **防漂移（改了代码没更新认知）** | 🔴 **靠人记** | ✅ `verify`/`check` | ✅ `detect_changes` |
| **占 MEMORY 额度** | 🔴 **占（已满）** | ✅ 独立文件 | — |

### 4.2 🔴 最大的风险：S 字段 与 判据库 **双写漂移**

这正是本项目最痛的病（"两处口径必然漂移"）。

**必须一开始就划死边界**：

| 归属 | 写什么 | 例子 |
|---|---|---|
| **AOCI `S` 字段** | **改这个文件时必须知道的事实** | 「`schema.rs` 的 `init_database` 无条件跑，新表只写这里」「`iap_handlers` 的 UPSERT 的 SET 里故意没有 `user_id`」 |
| **判据库（MEMORY/criteria-index）** | **做事的方式（跨文件）** | 「证伪必须真能红」「幂等写入 ≠ 可以乱序到达」「同一口径只能一处权威」 |

判据：**能装进某一个文件的 S 里 → 进 AOCI；换了文件也照样成立 → 留判据库。**

### 4.3 两者都不覆盖的（必须继续靠现有体系）

- 我们那 88 个断言脚本 —— **这是 CoEvo 比 vibedollar 强的地方，AOCI/gitnexus 都不替代它**
- 上架/合规/法务那条线（`docs/operations/`）
- 判据的证伪纪律

---

## 五、建议路径（三步，每步可独立停）

### Step 1：先让 gitnexus 能用（成本：一次重建 + 半小时验证）

```bash
# 在 E:/CoEvo 下重建（旧索引 diverged，必须 --force）
node .gitnexus/run.cjs analyze --index-only
# 或按 AGENTS.md 的提示用 npx/bunx 引导
```

**验证三件事**（不通过就别往下走）：
1. `is_subscription_active` 的 `incoming` 是否恢复（现在是空）
2. **Flutter/Riverpod 的动态分发解析率** —— 我们有大量 `ref.read(xxxProvider)`，
   这类跨对象调用在图谱里很可能是 `UNKNOWN`
3. Rust ↔ Dart **不通图**（中间是 HTTP）⇒ 跨语言链路永远要人补

**⚠️ 此阶段不要往 AGENTS.md 写任何 MUST 规则** —— 先当查询工具用，验证价值。

### Step 2：AOCI 试点（成本：5 条条目，约 1 小时）

照 vibedollar 的做法**先试水 5 条**，只挑「MEMORY 里已经写了文件级事实」的那几个：

| 候选文件 | 为什么选它 |
|---|---|
| `backend/crates/api_server/src/schema.rs` | MEMORY 里有「新表/索引只写 `schema.rs`」这类事实 |
| `backend/crates/api_server/src/iap_handlers.rs` | 归属校验、孤儿绑定、UPSERT 例外 |
| `backend/crates/api_server/src/subscription.rs` | 刚刚收口的格式契约 + 单调写入 |
| `app/lib/services/iap_service.dart` | 端侧权威 + 三层缓存 + 归属过滤 |
| `app/lib/services/iap_plan.dart` | 可断言层（`judgeRestoreOutcome` / `purchaseButtonState`）|

**试点要回答的只有一个问题**：把这 5 条从 MEMORY 搬进 AOCI 后，
**MEMORY 是否真的能瘦下来、且读起来不缺东西**。

**scope 建议（不要 233 条全量）**：

| 档 | CoEvo 建议范围 | 估算条数 |
|---|---|---|
| **index** | `backend/crates/api_server/src/*.rs`（48）+ `app/lib/services/*.dart` 里核心几个 + `scripts/*/bin/verify_*.dart` 里核心几个 | **~60–80** |
| **observe** | `app/lib/screens/*`、`app/lib/widgets/*`（UI 变动频繁，认知价值低）| 其余 |
| **exclude** | `backend/target/`、`build/`、`docs/`、`marketing/`、`generated-images/` | — |

📌 理由：vibedollar 的 117 条里**没有一条是 UI 页面**。认知价值在「契约层」，不在「像素层」。

### Step 3：框架落地（试点验证后再做）

1. 新增 MCP 条目 `aoci-coevo`（`--repo E:/CoEvo`，**不动** vibedollar 那条）
2. 生成 `AGENTS.md`（两段：gitnexus 段 + AOCI 段），但**规则按我们的实际形态改写**：
   - 不照抄 vibedollar 的 "MUST run impact before editing"（`UNKNOWN` 太多会变成噪音）
   - 改成：**"改高危文件前跑 impact；`UNKNOWN` 时回落到 grep + 断言"**
3. 定维护节奏：**只在功能收口时 `maintain`**，不在每次小改后（vibedollar 手册也这么说）
4. 划死 §4.2 的边界，并写进 `AGENTS.md` + `criteria-index`

---

## 六、风险清单

| # | 风险 | 触发条件 | 后果 | 缓解 |
|---|---|---|---|---|
| R1 | **S 与判据库双写漂移** | 边界没划死 | 两处说法不一致，比不写更糟 | §4.2 的判据 + 断言守着 |
| R2 | **gitnexus 对 Flutter 解析率低** | Riverpod 动态分发多 | `impact` 大量 `UNKNOWN` ⇒ 形同虚设 | Step 1 先验证；不行就只用于 Rust 侧 |
| R3 | **AOCI 初始化工程量大** | 全量 233 条 | 几天时间 + 25K tokens 常驻读取 | **只 index 契约层 ~60–80 条** |
| R4 | **每轮维护增加流程负担** | 每次改代码都 maintain | 挤占实际开发 | 只在功能收口时做 |
| R5 | AOCI 的 `attestation/challenge` 流程复杂 | 每次 context 压缩后 | 认知重载成本高 | 我们的改动是小步高频，可只用 `check_only` |
| R6 | MCP 配置抢用 | 复用 vibedollar 那条 | 两边互相覆盖 | 新增独立条目 |

---

## 七、我的明确判断（不含糊）

**AOCI：该上。** 理由不是"vibedollar 用了所以好"，而是：
> 我们的 `MEMORY.md` **已经顶到 16 KB 上限**，而里面塞着大量「某个文件里有什么坑」的事实 ——
> 那类内容**天生属于文件、不属于全局记忆**。继续往里塞只会触发我自己定的「再涨就搬」规则，
> 而 `references/` 只是换个地方堆，仍然没有"跟着文件走"的结构。

AOCI 的 `S` 字段正好是那个结构：**改这个文件时，它自己会把该知道的坑递到你面前**。

**gitnexus：先别急着信。** 理由：
> 我们最痛的 bug（到期日被回退、孤儿交易、弹窗判据错）**没有一个能靠调用图发现** ——
> 它们都是「语义/契约」问题，靠的是断言 + 证伪 + 端到端。图谱帮的是另一类问题（改 A 影响谁），
> 价值真实但**优先级低于**把 AOCI 这层建起来。
> 而且现有索引的 `incoming` 是空的 —— 在它重建并验证之前，任何"MUST run impact"规则都是形式主义。

---

## 八、需要白哥拍板

1. **是否按 Step 1 → 2 → 3 推进？**（我建议：先做 Step 1 + Step 2 的 5 条试点，验证后再谈框架）
2. **AOCI 的 index 范围**是否同意"只覆盖契约层（~60–80 条），UI 层一律 observe"？
3. **边界划分**是否认可 §4.2（AOCI-S = 文件级；判据库 = 做事方式）？

批了我按 Step 1 先重建 gitnexus，跑那三项验证，把结果给你再决定往下走。
