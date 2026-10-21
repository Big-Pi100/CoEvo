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

---

## 九、skill 已抽象完成（2026-10-21 12:1x 实测 review）

白哥已把 vibedollar 的实战经验抽象为**用户级 skill**：
`~/.workbuddy/skills/aoci-cognition-maintenance/SKILL.md`（16.8 KB）

### 9.1 技术准确性：实测 5 条，全部正确

| skill 的说法 | 实测 |
|---|---|
| 版本以 `aoci --version` 为准 | ✅ `0.1.0-rc21 (commit cfa8e93…, built 2026-10-14)` |
| `init --agent` 支持 claude/codex/cursor/opencode/qoder/all | ✅ `init --help` 逐字一致 |
| **CLI 没有 `maintain` / `overview`** | ✅ 两者均报 `unknown command` |
| `doctor` 查四组、默认不联网 | ✅ 实测输出四节，`--net` 才探端点 |
| `init` 写项目级 `.mcp.json` / AGENTS.md 块 | ✅（`doctor` 明确列 `.mcp.json: not configured`）|

⇒ **skill 可以放心用**，不是凭印象写的。

### 9.2 🔴 三个 skill 未覆盖的坑（实测发现，建议补进 skill）

#### ~~坑 1：`guide` 失败时 exit code 是 0~~ —— 🔴 **本节原判断有误，已更正**

**我报错了。** 当时用的是 `... guide 2>&1 | head -12; echo "exit=$?"` ——
`$?` 取到的是 **`head` 的退出码**（永远是 0），不是 aoci 的。**典型的管道取码陷阱。**

2026-10-21 14:5x 复测：

```console
# 方法 A：带管道（我上次的写法 —— 错的）
$ aoci ... guide 2>&1 | head -3; echo "exit=$?"
Error: open E:/CoEvo/aoci.txt: ...
exit=0                        ← 这是 head 的码

# 方法 B：直接取码（正确的写法）
$ aoci ... guide > /tmp/aoci_g.out 2>&1; echo "exit=$?"
真实 exit=3                   ← ✅ aoci 的码是可靠的（与 skill 的记载一致）
```

⇒ **`aoci` 的退出码一开始就是对的**（未初始化仓库跑 `guide` → **3**），
skill §九 后来也补了这条：**别写 `cmd | head; echo $?`**。

📌 教训：项目判据里明明有「`main` 返回值 ≠ 退出码」，我却没联想到**管道**这一层。
**「测量工具本身出错」比"被测对象出错"更难发现** —— 因为错误方向恰好符合预期（都是 0）。


#### 坑 2：WorkBuddy 的 MCP 是**全局**配置，`init --agent` 写的项目级配置**不会被读**

| | Claude Code / Codex / Cursor | **WorkBuddy** |
|---|---|---|
| MCP 落点 | 项目级 `.mcp.json` / `.codex/config.toml` | **全局 `~/.workbuddy/mcp.json`** |
| 多项目共存 | `init --agent` 天然隔离 | 🔴 **要手工加多条**（每条 `--repo` 指一个仓库）|

实测现有条目：`aoci → E:/AOCI-CODE/build/aoci.exe mcp --repo E:/vibedollar`（**写死一个仓库**）。
`doctor` 也只检测 `claude codex` 两类环境，**不认识 WorkBuddy**。

⇒ 对 WorkBuddy 的正确做法：
1. `init --agent <任意>` 仍可跑（它会建 `.aoci/` 与 AGENTS.md 块），但**别指望它写 MCP**
2. 手工往 `~/.workbuddy/mcp.json` 加独立条目，**server 名要区分仓库**：

```json
"aoci-coevo": { "command": "E:/AOCI-CODE/build/aoci.exe", "args": ["--repo", "E:/CoEvo", "mcp"] }
```

3. ⚠️ 多条目后工具名变成 `mcp__aoci-coevo__aoci_maintain` 这种带前缀的形式
   ⇒ **模型可能选错 server**，而 `--repo` 指错就是 skill 自己警告的「静默改到别的仓库」。
   ⇒ 建议：**同一时间只启用一个 aoci server**，切项目时改配置而不是并存。

#### 坑 3：gitnexus **索引过期**时返回的是「错答案」而不是「空」

skill §三 写「没建过索引 ⇒ 四个工具全返回空」——那只是最轻的情形。实测更糟的一种：

```json
{ "symbol": { "filePath": ".../subscription.rs", "startLine": 116 },
  "epistemic": "lower-bound",
  "incoming": {},                    // 🔴 空 —— 但该函数实际被 sync/translation/电子书多处调用
  "staleness": { "status": "diverged" } }
```

⇒ **`incoming: {}` 会被读成"没人调用"，实际是索引坏了。**
建议 skill 加：**读结果必须同时看 `staleness.status` 与 `epistemic`；
`epistemic: lower-bound` 不得当作 exact；`diverged`/`behind` 一律先 `analyze` 重建。**

### 9.3 🟠 三处可以补强

| # | 现状 | 建议 |
|---|---|---|
| 1 | §〇「能不能用」是 4 步手查（`--version` / `ls .aoci/` / `scan` / `guide`）| 实测 **`aoci doctor` 一条命令就给全**（仓库发现 / 索引文件 / baseline / Agent 集成 / 各 host MCP 状态 / AI 层）⇒ 建议把它放在 §〇 第 0 步 |
| 2 | 只讲 scope **怎么改**，没讲 **index 范围怎么定** | 加一条判据：**index 只放「契约层」**（入口/持久化/集成/编排/断言骨架）；**UI 层、纯样式、一次性脚本一律 observe**。依据：vibedollar 117 条 index 里**没有一条 UI 页面** |
| 3 | 是通用 skill，没有「与项目既有记忆体系共存」的边界 | 加通用判据：**文件级事实 → AOCI `S`；跨文件方法论 / 判断规则 → 留在原体系**。否则必然双写漂移 |

### 9.4 结论

- **skill 可以按现状用**（技术准确，链路完整）
- 上述 **坑 1/2/3** 建议补进 skill（通用性都够：exit code、WorkBuddy 是 host 之一、stale 索引是通病）
- **§9.3-3 的边界**建议写进 skill（通用），具体到 CoEvo 的划分见本文 §4.2

---

## 十、skill 第二次更新 review（2026-10-21 14:5x）

`SKILL.md`：**224 行 / 14,299 B → 337 行 / 21,335 B**（+113 行）

### 10.1 变化总览

| 位置 | 变化 | 来源 |
|---|---|---|
| §〇 | 🆕 **⓿ `aoci doctor` 一眼看全**（并标注它两个局限：不做漂移比对、不认识全局配置型 host）| 我的建议 1 |
| §〇 | 🆕 **「项目级 host vs 全局级 host」对照表** + 全局级的三个连带事实 | 我的坑 2（**被抽象成通用形态**）|
| §三 | 🆕 **`⚠️ 空集合 / 小集合 ≠ 安全`**（三种"没人调用"的含义 + `causes` 六字段机读表）| 我的坑 3 |
| §五 | 🆕 **`与项目既有记忆体系共存（防双写漂移）`** | 我的建议 3 |
| §六 | 改名 `Scope：index 放什么 + 怎么改`，🆕 **`划范围：index 只放契约层`** | 我的建议 2 |
| §九 | 🆕 **「判断成败」**：别写 `cmd \| head; echo $?`；`aoci` 自身码可靠（未初始化 `guide` → 3）| **纠正我的误判** |

### 10.2 🎯 三处比我提的更好（值得记下来）

| 项 | 我提的 | skill 改成 |
|---|---|---|
| 记忆边界判据 | 「能装进某个文件的 S ⇒ AOCI；换文件也成立 ⇒ 判据库」 | **「它会不会随这单个文件的改动而失效？」** 会 → AOCI；不会 → 原体系。**更可判定**（问"失效性"比问"空间归属"明确）|
| index 范围判据 | 「index 只放契约层，UI 一律 observe」，依据是 vibedollar 117 条没 UI | **「改了它，别人要不要跟着改」**：契约层变更**传导**，UI 变更不传导。**这个判据可推广**，不依赖个案 |
| 全局 MCP host | 我写死了「WorkBuddy 的 MCP 是全局配置」 | **抽象成「全局配置型 host」一类**，并补了第 ③ 条我没想到的：**多条目后工具名带前缀（`mcp__<name>__aoci_maintain`），skill 里的裸工具名就对不上了** |

> 📌 第 3 条那个细节（**文档里的裸名与实际带前缀的名字对不上**）比"模型可能选错"更准确 ——
> 它是**文档与实际的命名错位**，不是概率问题。

### 10.3 🔴 我的误判：原「坑 1」不成立

见 §9.2 已更正为：**`aoci` 的退出码一开始就是对的**（`guide` 未初始化 → **3**），
我上次取到 0 是因为 **`| head` 之后 `$?` 拿到的是 head 的码**。

📌 这条比原来那个"坑"更有价值：**「测量工具本身出错」比"被测对象出错"更难发现**，
因为它错的方向恰好符合预期（都以为是 0）。已在 §9.2 保留错误痕迹 + 更正说明。

### 10.4 唯一还想补的一条（CoEvo 落地时会用到）

§六 说「UI 页面即使很复杂也不进 index」。判据（传导性）是对的，但**按目录判会误伤**：

> 我们的 `app/lib/screens/subscribe_screen.dart` 是 **UI 文件却承担支付契约**
> （购买按钮状态、恢复购买文案、自动续费披露），它的变更**会传导**到
> `iap_plan.dart` / `iap_service.dart` 的断言与法务口径。

⇒ 落地时按 **「是否传导」** 判，不按「在哪个目录」判。
（这与 skill 的判据不冲突，只是提醒别把目录当判据。）

### 10.5 结论

**skill 现在可以按现状用了**，三条建议全部落地，且两处比原建议更严谨。
剩下只有 §10.4 那条属于**落地时的注意事项**，不必改 skill。

---

## 十一、skill 第三次更新：反馈闭环情况（2026-10-21 15:0x）

`SKILL.md`：**21,335 B → 22,424 B**（+1,089，15:09 修改）

### 11.1 逐条核对我的 4 条反馈

| # | 我的反馈 | 状态 | 依据 |
|---|---|---|---|
| **P0** | `repo` 从启动参数 → **工具参数**（多项目根本解）| 🔴 **未动** | 二进制仍是 `0.1.0-rc21 (built 2026-10-14)`，`aoci mcp --help` 与之前**逐字一致**，只有全局 `--repo` |
| **P1** | `init` 对未知 host 应**省略 `--agent`**，skill 没写 | ✅ **完全采纳** | 新增三条路对照表（见 11.2），并**修正了 skill 原有的一句错话** |
| **P2** | `doctor` 对未知 host 报 `not configured` 会误导 | 🟠 **文字缓解** | skill 加了「它报 `not configured` 的意思是"**我看不见**"，不是"**你没配**"」；但 `doctor` 输出本身未变（需二进制）|
| **P3** | `init --agent claude` 写 `.gitattributes` 的覆盖风险 | ✅ **已解答** | skill 补实测：**已有自己的行尾策略时，`不覆盖也不追加`** ⇒ 非破坏性；但 aoci 的 LF 要求**不会自动生效**，需自己决定是否补 |

### 11.2 P1 采纳得比我写的更好：给了三条路的实测对照

skill 现在写成：

| 写法 | 实测结果 |
|---|---|
| `init --agent workbuddy`（未知名字）| `Error: unknown Agent`，**报错即退出，连 `.aoci/` 都不会建** |
| `init --agent claude`（硬借一个）| 写一份**没人读的 `.mcp.json`**，还被 init 加进 `.gitignore` —— `git status` 都看不见它，**形似配好、实际不生效** |
| ✅ `init`（**省略 `--agent`**）| 只建 `.aoci/` + `AGENTS.md` + `.gitattributes`，**不写任何 host 配置** |

**这比我反馈里写的更好**：我只说了"省略才对"，它把**三条路的后果**都列了，
尤其第二条「`git status` 都看不见它」——这正是用户会踩的那个坑。

### 11.3 🎯 并且修正了 skill 自己原来的一句错话

原文（上一版 §〇）：
> ① `init --agent` **照样能建 `.aoci/` 和 `AGENTS.md`**，但不会写 MCP

现在：
> ① `init --agent <未知名字>` **直接报错退出，骨架都不会建**（**不是"能建但不写 MCP"**）—— 务必省略 `--agent`

**我复测确认新说法正确**（空目录 + `git init`）：

```console
$ aoci --repo <空目录> init --agent workbuddy
Error: unknown Agent "workbuddy" (...; omit it to create the skeleton ...)
真实 exit=3
$ ls -a
.  ..  .git          ← 只有 .git，.aoci/ 确实没建

$ aoci --repo <空目录> init          # 省略
exit=0
.  ..  .aoci  .git  .gitattributes  AGENTS.md  aoci.code.txt  aoci.meta.txt  aoci.txt
```

### 11.4 P3 的实测结论（补一个我要注意的点）

skill 说 `.gitattributes` **不覆盖也不追加** —— 也就是**非破坏性**，这点比我担心的情况好。
但反过来：**aoci 的 LF 要求不会自动落地**，需要我们**自己决定**要不要按它的写法补。

⚠️ 我们项目的 `.gitattributes` 是**已经 pin 了 LF** 的（`*.dart` / `*.rs` / `*.md` 等），
所以这条对我们**实质无影响**。落地时只需确认「已有内容不被改动」即可（skill 已答：不覆盖不追加）。

### 11.5 结论：现在可以按 skill 走，P0 等二进制

**可落地的路径**（P0 未解决时的正确姿势）：

1. `aoci --repo E:/CoEvo init`（**省略 `--agent`**）→ 只建骨架
2. 手工往 `~/.workbuddy/mcp.json` 加**一条** `aoci-coevo`（`--repo E:/CoEvo`）
3. **不要并存** vibedollar 那条 —— 要切项目就改那一条的 `--repo`（这正是 P0 要解决的痛点）
4. `doctor` 报 `not configured` 时**不必理会**（skill 已说明那是"看不见"不是"没配"）

**P0 一旦解决**（`repo` 成为工具参数），就能一条 MCP 服务两个仓库，无需改配置重启。

---

## 十二、一个 MCP 服务不了两个项目时怎么办（隔离性实测）

### 12.1 🔑 先回答「会不会互相影响」：**数据和进程层面不会**

实测依据：

| 检查 | 结果 |
|---|---|
| `~/.aoci` | ❌ 不存在 |
| `~/.config/aoci` | ❌ 不存在 |
| `%LOCALAPPDATA%\aoci` | ❌ 不存在 |
| `%APPDATA%\aoci` | ❌ 不存在 |
| `doctor` 的 AI 增强层 | `disabled (fully offline and deterministic)`，**无 endpoint** |

⇒ **AOCI 没有全局状态目录，所有状态都在项目内**：

| 资产 | 位置 | 进 git？ |
|---|---|---|
| `aoci.txt` / `aoci.meta.txt` / `aoci.code.txt` | 项目根 | ✅ |
| `.aoci/baseline.json` / `config.json` / `.gitignore` | 项目内 | ✅ |
| `.aoci/ledger.jsonl` / `transactions/` / `drafts/` | 项目内 | ❌（运行时，被 `.aoci/.gitignore` 挡住）|

⇒ **两个仓库各有一套完全独立的资产**，物理隔离。
再加上 MCP 是 **stdio 独立子进程**、`--repo` 在启动时固定 ⇒ **两个 server 之间不会串数据**。

### 12.2 ⚠️ 唯一的真实风险：**操作了错的项目**（不是数据串，是意图串）

两个 server 会暴露两套同名工具：

```
mcp__aoci__aoci_maintain          → --repo E:/vibedollar
mcp__aoci-coevo__aoci_maintain    → --repo E:/CoEvo
```

技术上**前缀不同、不会串**。但 agent（我）**可能选错 server** —— 后果不是"改坏文件"，
而是**以为在改 CoEvo，其实改了 vibedollar**。

📌 这比数据串更难发现，因为两边都是合法操作、都返回成功。

### 12.3 三个方案

| 方案 | 做法 | 适合 | 代价 |
|---|---|---|---|
| **A：单条 + 切换** | 只留一条，切项目时改 `--repo` | 一段时间只做一个项目 | 每次切换**改配置 + 重连/重启会话** |
| **B：两条并存** ⭐ | 加 `aoci-coevo`，server 名带项目后缀 | **频繁来回切**（我们的实际情况）| 模型可能选错项目；多一个进程 |
| **C：等 P0** | `repo` 成为工具参数，一条服务多仓 | 终极解 | 等 release |

**我推荐 B**，理由：CoEvo 是主线、vibedollar 也在推进，**每天都会切**；
而方案 A 每次切换要重启会话，成本太高（这个项目的工作节奏是连续推进）。

### 12.4 方案 B 的配置与风险缓解

```jsonc
// ~/.workbuddy/mcp.json
"aoci-coevo": {
  "command": "E:/AOCI-CODE/build/aoci.exe",
  "args": ["mcp", "--repo", "E:/CoEvo"]
},
"aoci": {                       // 保持原名，vibedollar 的既有条目不动的
  "command": "E:/AOCI-CODE/build/aoci.exe",
  "args": ["mcp", "--repo", "E:/vibedollar"]
}
```

**四条缓解措施**（针对"选错项目"）：

1. **server 名必须带项目名**（`aoci-coevo` / `aoci` 这样仍歧义，建议同时把 vibedollar 那条也改名成 `aoci-vibedollar`）
2. **每次 `maintain` / `update_entry` 之后核对返回体里的仓库路径** —— 不一致就是选错了
3. **同一时间只对当前项目做 `aoci_overview`**：vibedollar 的 overview 是 12.6K tokens，
   两个都加载会直接挤爆 context
4. 如果一个项目暂时不动，**把它的条目注释掉**（而不是留着让 agent 有机会选错）

### 12.5 还有一个前置：CoEvo 还没 init

```
$ aoci --repo E:/CoEvo doctor
[✗] Index file: could not read aoci.txt (the project may not be initialized)
[✗] Baseline file: missing; run aoci scan
Error: Doctor found a problem (exit code 1)
```

⇒ 顺序是：**先 `init`（省略 `--agent`）→ 再配 MCP → 再 `scan`**。

📌 附一个实测细节（skill 没写）：`doctor` 的退出码是 **1**（"发现问题"），
而 `init` 未知 agent / `guide` 未初始化是 **3**（"用法/状态错误"）—— **有分级**，
所以脚本里不能只判"非 0 即失败"，得看码。

### 12.6 结论

- **技术上安全**：无全局状态、独立进程、独立资产 ⇒ 两个项目可以并存
- **风险在"选错"而不是"串数据"** ⇒ 用命名区分 + 事后核对路径来兜
- **P0 落地后**这两个 server 可以合成一条，风险自然消失

---

## 十三、skill 第四次更新：补上了「重建索引」的两个前置（正好是我漏的）

`SKILL.md`：**22,424 B / 337 行 → 25,850 B / 406 行**（+69 行，15:59 修改）

### 13.1 三处变化

| 位置 | 新增 |
|---|---|
| §三 | 🆕 **`重建索引前：先停掉用它的 MCP 进程`** |
| §三 | 🆕 **`解析缓存也可能拦住重建`** |
| §九 | 🆕 **`退出码有分级`**：`doctor` → **1**（发现问题）· `init` 未知 agent / `guide` 未初始化 → **3**（用法/状态）|

第三条是我上一轮报的发现（`doctor` 退出码 1 而非 3），已采纳。

### 13.2 🔴 前两条正好打中我三次建议里的漏洞

我在前几轮反复说「要不要现在就做 Step 1 重建 gitnexus」，**一次都没有想到 MCP 进程会占着索引**。

skill 补的事实：

> `lbug`（图数据库文件）被占用时，`analyze` 会**重试 5 次后放弃** ——
> **图重建了但换不上，旧索引继续生效**（`indexedAt` 不变，而输出里只留一句 warning）。
> gitnexus 自己的提示（"stop any GitNexus MCP or serve process using this repository"）
> **只在失败之后才打印**，等你看到它已经白跑了一轮。
> ⇒ **先停 MCP 进程，再 analyze。**

**实测 CoEvo 的真实状态**（所以我按原计划做会踩）：

| 障碍 | 实测 |
|---|---|
| `lbug` 被占用 | 🔴 **确实存在** —— 查到 **2 个** gitnexus 进程（PID `11496` / `760`），`lbug` **190 MB**、整个 `.gitnexus/` **204 MB** |
| `parse-cache` 批删超阈值（>50 文件）| 🟢 **当前不适用** —— CoEvo 的 `parse-cache` 只有 **3 个文件** |

⇒ 障碍 1 是真的；如果我不查进程直接 `analyze`，大概率是「重试 5 次 → 放弃 → 一句 warning → 我误以为重建成功」。

### 13.3 第二条（解析缓存）在这个环境里也值得防

> `analyze` 每次都会清 `.gitnexus/parsedfile-store`。若宿主沙箱限制批量删除
> （例如 `SAFE_DELETE_BULK_CONFIRM_REQUIRED`，阈值 50 文件），清理会被拦，parse 阶段直接失败。
> **而且是死循环**：重建缓存几百文件 → 下次又要清 → 又超阈值。
> 稳妥做法：**重建前把障碍移走（`mv` 而不是删）**。

📌 我们的沙箱**确实有这层批量删除确认**（本会话里就触发过）。
虽然 CoEvo 现在只有 3 个缓存文件，但 **analyze 之后会变成几百个** ⇒ 第二次重建就会撞上。

### 13.4 🎯 顺带一条最有价值的验收判据

skill 新增：

> **验收不能只看 "success"**：要核对 `meta.json` 的 `indexedAt` 变成刚才、
> `lastCommit` 等于当前 HEAD，再用 `gitnexus impact <symbol>` 或 `context <symbol>` 实查一次
> —— 否则可能只是"**跑完了但没换上**"。

📌 这与项目既有判据**同族**：
「产物看着是新的、其实是旧件」·「`Upload succeeded` ≠ ASC 处理完成」·
「`gitpush` 成功 ≠ 部署成功」。**"命令成功"永远不等于"效果达成"。**

### 13.5 Step 1 的正确执行顺序（按新 skill 修订）

```
1. 查进程：Get-CimInstance Win32_Process → 找 gitnexus（本次查到 2 个：11496 / 760）
2. 停掉它们          ⚠️ 代价：mcp__gitnexus__* 工具立刻不可用，重建完要重连 connector
3. mv .gitnexus/lbug .gitnexus/lbug.bak
   mv .gitnexus/parsedfile-store .gitnexus/parsedfile-store.bak   （若存在）
4. gitnexus analyze
5. 🔴 验收（不能只看 success）：
   · meta.json 的 indexedAt = 刚才、lastCommit = 当前 HEAD
   · 再实查一个符号能返回结果
6. 重连 gitnexus connector（或重启会话）
7. 确认无误后才删 .bak
```

⚠️ **第 2 步的代价要提前知道**：停掉 MCP 后本会话就没有 `mcp__gitnexus__*` 工具了，
而**重建必须在"没有工具可用"的状态下完成** —— 这是个"自锁"结构：
要用工具重建，就得先停掉工具。

⇒ 所以更稳的做法：**`gitnexus analyze` 走 CLI（`node .gitnexus/run.cjs analyze`），
不依赖 MCP** —— CLI 和 MCP 都只是客户端，真正独占 `lbug` 的是 MCP 进程。
停 MCP → CLI 重建 → 重连 MCP，整条链不需要"边用工具边重建"。

### 13.6 结论

- skill 这次补的两节**都是"失败后才知道"的坑**（gitnexus 失败后才打印提示；
  批删被拦导致 parse 直接失败），属于典型的**沉默失败**
- 我之前三次提议「重建」，**都没提这两个前置** ⇒ 感谢这两节，否则真会白跑一轮
- **可以开始 Step 1 了**，但顺序必须按 13.5，且要接受「停 MCP → 工具暂不可用」这个代价

---

## 十四、✅ Step 1 已执行：gitnexus 索引重建（2026-10-21 16:08–16:19）

### 14.1 执行过程（600 秒）

```bash
# ① 备份 meta.json（记录旧 indexedAt 用于验收）
cp .gitnexus/meta.json .gitnexus/meta.json.pre-rebuild
# ② 移走障碍（mv，不是删 —— 可回滚）
mv .gitnexus/lbug .gitnexus/lbug.bak            # 190 MB
mv .gitnexus/parse-cache .gitnexus/parse-cache.bak
# ③ 重建
node .../gitnexus/dist/cli/index.js analyze --force --index-only
```

**✅ 关键实测结论：不需要停 MCP 进程。**

- 先用 `open(..., 'r+b')` 试写 `lbug` ⇒ **可写，未被独占**
- `mv` 走的是**路径**而非删除 ⇒ 绕开了「文件被占用」这条
- MCP 进程虽然还持着旧句柄，但**下次查询时会重新打开新文件**（实测 MCP 工具立刻返回新索引结果）

⇒ skill §三 的「先停 MCP」是**保守建议**；在「`mv` 移走 + 不停进程」这条路上不必要。
（停 MCP 的代价是 `mcp__gitnexus__*` 立即可用不了 —— 能避免就避免。）

### 14.2 🎯 验收：三条判据全过

| 判据 | 结果 |
|---|---|
| `meta.json` 的 `indexedAt` 是刚才 | ✅ `2026-10-21T08:19:14Z`（旧值 `2026-06-26T04:33:37Z`）|
| `lastCommit` = 当前 HEAD | ✅ `a5292eae…` = `git rev-parse HEAD` |
| 实查一个符号能返回正确结果 | ✅ 见 14.3 |

### 14.3 🔴 新旧索引的**决定性对比**（同一个符号）

查 `is_subscription_active`：

| 项 | 旧索引（6 月）| 新索引 |
|---|---|---|
| `startLine` | 116（旧代码位置）| **200**（当前代码）|
| `epistemic` | **`lower-bound`** | **`exact`** ✅ |
| `incoming.calls` | **`{}` 空** | **5 个**：`authorize_blob_write` · `iap_verify_handler` · `authorize_with_subscription` · `consume_quota_on_conn` · `translate_text_inner` ✅ |
| `outgoing.calls` | `get_current_expires`（旧）| **`parsed_expires`**（今天刚加的）✅ |
| `processes` | `[]` | **6 条执行流**（`sync_push` / `translate_text_inner` / `upload_blob_handler`）✅ |
| 规模 | 22,269 nodes / 32,470 edges / 300 flows | 21,329 / 31,673 / **400** flows |

**这直接证实了 skill §三 那条「空集合 ≠ 安全」**：
旧索引说「没人调用」，实际有 **5 个**；而且它连今天的改动（`parsed_expires`）都看不见。

⇒ 如果我们基于旧索引做过任何「这个函数没人用，可以删/改」的判断，**全是错的**。

### 14.4 ⚠️ 索引自身的三条局限（analyze 日志里的 warning，必须记）

| # | 日志 | 含义 |
|---|---|---|
| 1 | `[scope-resolution] 274 property read/write site(s) name a field that IS defined in this workspace, but only in another language … Queries for these fields return an empty result that does NOT mean "unused"` | **Dart/Rust 跨语言字段解析有盲区** —— 查 `code` / `message` / `path` / `style` 这类同名属性会拿到空结果，**那不是"未使用"** |
| 2 | `[processes] 400 flows reported, but MISSING: 1429 of 1629 candidate entry point(s) never ranked in` | **process 覆盖只有 ~12%**（1629 个候选入口只排进 200 个）⇒ 「没有这条 flow」≠「这条路不存在」|
| 3 | `name-fallback resolution: 65 call sites, 41 refused as impossible (rust 50/41, dart 13/0)` | **Rust 名称解析失败 41/50（82%）**；Dart 0/13 全成功 |
| 4 | `Warning: could not save parse cache ([safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"count":311,"threshold":50,...}); continuing.` | 🔴 **解析缓存没能保存** —— 结束时要删 311 个文件，超沙箱阈值 50 ⇒ **下次 analyze 无法复用缓存**（只能全量重解析）|

📌 #4 就是 skill §三 第二条说的那个坑，**首次重建就撞上了**：
`parse-cache` 从原来 **3 个文件** 变成 **262 个** ⇒ 清理超阈值。

**后果**：下次 analyze 一定又是 600 秒（无缓存可复用）。
**缓解**：重建前手动 `mv .gitnexus/parse-cache .gitnexus/parse-cache.bak-<日期>`（而不是靠它自己清）。

### 14.5 🆕 顺带发现：gitnexus **有全局 registry**（与 AOCI 不同）

stderr 里出现：

```json
{"name":"pi-mono","storagePath":"D://pi-mono//.gitnexus","state":"owned",
 "hasCodeIndexDB":false,"msg":"Skipping registry entry during validation..."}
```

⇒ gitnexus 在 `~/.gitnexus/registry.json` 维护**全局的「名字 → 路径」注册表**。
这与 AOCI（**无全局状态**，全在项目内）是**不同的设计**。

| 工具 | 全局状态 | 影响 |
|---|---|---|
| AOCI | ❌ 无（`.aoci/` + `aoci.*.txt` 全在项目内）| 多项目天然隔离 |
| **gitnexus** | ✅ **有** `~/.gitnexus/registry.json` | 多个 repo 条目共存（`list_repos` 返回 2 个），只要**不同名**就不冲突；同名需 `--allow-duplicate-name` |

### 14.6 当前状态

| 项 | 值 |
|---|---|
| `lbug` | **291 MB**（新，旧 190 MB）；`.gitnexus/` 总计约 **480 MB**（含 `.bak`）|
| 备份 | `.gitnexus/lbug.bak`（190 MB）· `parse-cache.bak` · `meta.json.pre-rebuild` |
| MCP 工具 | ✅ **已生效**（无需重连，`context` 直接返回新索引结果）|
| AGENTS.md / skills | ✅ **未生成**（用了 `--index-only`），仓库里没多出任何文件 |
| 仓库 | `git status` 干净（`.gitnexus/` 被 `.gitignore` 忽略）|

**备份何时删**：`lbug.bak` 建议留到**下一次重建成功**再删（回滚点是它）；
`parse-cache.bak`（3 个小文件）可以随时删。

---

## 十五、✅ Step 2 已执行：AOCI 落地 + 5 条试点条目

### 15.1 实际执行链路（含 4 个踩坑）

```bash
aoci --repo E:/CoEvo init                  # 省略 --agent（全局 host 的正确路径）
# 改 .aoci/config.json 的 managed_scope.rules（收窄 scope）
aoci --repo E:/CoEvo scan                  # 建 baseline（必须先于 activate）
aoci --repo E:/CoEvo scope activate        # 生成审批单 → 真人 approve + apply
# 用 update-entry 逐条写入
```

**四个坑（全部踩过）**：

| # | 现象 | 真因 | 正确做法 |
|---|---|---|---|
| 1 | `managed_scope_rule_contract_invalid: coevo-infra-gitnexus` | `source` 必须是 **`"user"`**（我写 `"project"`）；且 `rule_id` 必须**四段式**（`coevo-top-gitnexus-exclude`）| 照 vibedollar 的 user 规则结构抄 |
| 2 | `managed_scope_baseline_preimage_unavailable` | **先改了 scope 才 scan** | 顺序：**scan → activate**，不能反 |
| 3 | `impact_candidate_tag_dictionary_violation`（4 条全灭）| 我用了 `[DF9L]`/`[AF9L]` —— **`F-财务计费` 只在 `database` 字典里，`code` 字典的 B 没有 F** | 查 `aoci_header` 的字典；改 `[DB9L]`/`[DD9L]`/`[AB9L]` |
| 4 | `Every candidate must include a valid source_sha256` | 连 `--preview` 都要（help 说不用，实测不符）| 见 15.2 —— **baseline 里就有** |

### 15.2 🔑 重大发现：**写条目不需要 MCP**

skill 说「`source_sha256` 只能来自 `aoci_maintain`」。**实测：`.aoci/baseline.json` 里每个文件都存了 sha256**：

```json
".files.backend/crates/api_server/src/schema.rs":
  { "role": "index", "sha256": "af941843...", "size": 166907,
    "normalized_sha256": "af941843..." }
```

⇒ 直接取来喂给 `aoci update-entry --source-sha256`，**正式写入成功**（766 个文件全有）。

**这省掉了「配 MCP + 重启会话」一整圈** —— 全局配置型 host（WorkBuddy）的痛点被绕开了。

📌 判据：**「文档说只能从 X 拿」时，先查 X 存的东西有没有副本** —— baseline 就是那份副本。

### 15.3 scope 收窄：390 → 171

**默认 scope 不可用**：`index=1559 文件 / 173K tokens`（含 `.gitnexus` 缓存 1118、`.workbuddy` 157、`docs` 867…）。

**第一版规则仍漏了三块**（收窄后 390）：

| 被误算进 index | 数量 |
|---|---|
| `backend/prompts/**`（提示词模板）| **111** |
| `app/macos|windows|linux|web/**`（Flutter 平台壳）| **63** |
| `app/assets/**` + `app/docs/**` | 17 |

补上后 **index 390 → 171**（审批单原文：「**219 files losing Index coverage**」）。

**最终 scope**：`index 171 / observe 421 / exclude 1070`

| 档 | 内容 |
|---|---|
| **index** | `backend/crates/api_server/src/**`（37）· `app/lib/services|providers|api/**`（112）· 根配置 6 · workflows 2 · 其余 14 |
| observe | `app/lib/screens|widgets|theme|models`（UI 层）· `scripts/**`（断言脚本：**它们验证契约，本身不是被改的业务代码**）· 其余 |
| exclude | `.gitnexus` · `.workbuddy` · `docs` · `backend/prompts` · 平台壳 · `backend/target` · `marketing` · `data` 等 |

📌 **判据落地**：按「**改了它，别人要不要跟着改**」划，不按目录名划。
`scripts/` 虽然有 220 个文件，但改断言不需要改业务代码 ⇒ **observe**。

### 15.4 5 条试点条目（已写入 `aoci.code.txt`）

| 文件 | 标签 | 选它的理由 |
|---|---|---|
| `schema.rs` | `[PD9L]` | MEMORY 里有「新表/索引只写 `schema.rs`」这类**文件级**事实 |
| `iap_handlers.rs` | `[DB9L]` | 归属两层判定 + UPSERT 例外 |
| `subscription.rs` | `[DD9L]` | 今天刚收口的格式契约 + 单调写入 |
| `iap_service.dart` | `[AB9L]` | 端侧权威 + unknown 判据 |
| `iap_plan.dart` | `[DB9L]` | 可断言层（纯逻辑下沉的理由）|

**质量验收**（`aoci verify` / `check`）：

```
Volumes v1 candidate structure is valid
S coverage: C7+ Entries 5/5 have S (0% absent) | by band: C9 5/5      ← S 全有
E scale: 0 of 5 Code Entries carry a scale letter the source line count contradicts   ← E 档全对
```

`check` 报 **163 findings** = 「其余 166 个 index 文件未写条目」—— **试点阶段的预期状态**，不是错误。

### 15.5 成本核算（决定后续写多少条）

| 项 | 数值 |
|---|---|
| 5 条产物大小 | 3.4 KB ⇒ **约 680 B/条** |
| 若写满 171 条 | ≈ **116 KB ≈ 29K tokens** |
| 对照 vibedollar | 117 条 = 36 KB ≈ 12.6K tokens |

⇒ 我们**每条的 S 写得更详细**（680 vs 308 B）。**171 条全写完约 29K tokens**，
是 vibedollar 的 2.3 倍 —— 对 56K 行 Dart + 30K 行 Rust 的项目算合理比例，但**不必一次写完**。

### 15.6 当前状态与后续

| 项 | 值 |
|---|---|
| `scope` | ✅ `policy aligned true` |
| `index` | 171（已写 5 · 待写 163 + 3 无法读取）|
| `baseline.json` | 766 文件（index 171 + observe 421 + 其它）|
| AGENTS.md | 已生成（103 行，**英文** —— init 默认 `en-US`；语义准确，未改）|
| 进 git 的 `.aoci` 资产 | `.gitignore` · `baseline.json` · `config.json`（`ledger`/`transactions`/`scope-change` 被忽略）|

**建议的后续节奏**：**不追求写满 171 条**，而是「**改到哪个文件，就补哪个文件的条目**」——
这符合 skill 的维护闭环（改完 → `maintain` → 更新），也避免一次性投入 29K tokens。

---

## 十六、✅ 全量构建完成（2026-10-21 17:0x–18:2x）

### 16.1 决策变更：§15.6 的「不追求写满」已作废

白哥裁定：**「还是要全量构建，不然对项目的整体性会差很多，这本来就是要整体才有效」**。
⇒ §15.6 那条「改到哪补到哪」的增量策略**不再执行**，改为一次写满。
本节记录执行结果与过程中踩到的硬约束。

### 16.2 最终结果

| 项 | 值 |
|---|---|
| 索引条目 | **166 条**（覆盖全部可读 index 文件）|
| index 范围 | 171 ⇒ 166 条 + **2 个超限跳过** + **3 个卷文件不许有条目** |
| `aoci verify` | ✅ `Volumes v1 candidate structure is valid`；E 档 **0/166 不符** |
| `aoci check` | ✅ **✓ ready to commit**（Entries 漂移 / 策展 / 字典 / 格式 / 草稿 五净）|
| `index agent guide` | ✅ `stage=aligned complete=true next_action=none` |
| S 覆盖率 | **C7+ 110/110 全有 S**（C8 45/45、C9 21/21）|
| 卷体积 | **37,880 tokens / 上限 400,000**（target 200,000）⇒ `budget healthy` |
| 产物大小 | `aoci.code.txt` 112 KB |

**3 个卷文件不许有条目**（我一开始给它们写了，被 guide 判 `code_orphan` / `volume_ownership_conflict`，已用 `remove-entry` 撤掉）：
`aoci.txt`（root 卷）· `aoci.meta.txt`（meta 卷）· `aoci.code.txt`（code 卷自身）。
🔑 **认知卷不能给自己或兄弟卷写条目** —— 卷的归属由 manifest 决定，不由「这个文件也在仓库里」决定。

**2 个超限跳过**：`backend/cefr_catalog.json`（11.8 MB）· `backend/gen_hash.pdb`（1.3 MB）。
`check`/`guide` 会各报一条 `code_skipped`（**非阻塞**，`stage` 仍 aligned）。有意保留这条可见告警，
不做 scope 排除——排除了就再也不会有人提醒「这两个文件没有被认知层覆盖」。

### 16.3 🔴🔴 最重要的发现：AOCI 的 S 配额是 **token**，不是字数

`aoci.meta.txt` 里写的是 `#S配额: C9-8≤600 C7-4≤200 C3-1≤50`（看似「字」），
但**实际校验器按 token 计**，实测（用 `update-entry --preview` 二分探测出来的）：

| C | R 上限 | S 上限 | 折成中文字数（≈×1.35）|
|---|---|---|---|
| 9 | 180 tok | **200 tok** | S ≤ 270 字 |
| 8 | 140 tok | **140 tok** | S ≤ 190 字 |
| 7 / 6 / 5 | 90 tok | **80 tok** | S ≤ 108 字 |
| 4 / 3 / 2 / 1 | 50 tok | **40 tok** | S ≤ 54 字 |

F 栏：160 字能过、200 字必拒 ⇒ **≤180 字**。A 栏很宽松（400 字实测能过）。

**踩坑经过**：按 meta 的「600 字」写的 164 条里，**94 条被拒**（`entry_field_budget_exceeded`），
错误信息给的是 `{"field":"S","importance":8,"actual_tokens":251,"max_tokens":140}` ——
**`importance` 就是 tag 里的 C 位**，`max_tokens` 才是真上限。
🔑 修法不是截断（校验器明确写着 *do not truncate or retag it programmatically*），
而是**整句重写**：把最要命的一条放最前，其余果断取舍。

⇒ **给 meta 文件本身的问题反馈**：`#S配额` 那行应写明单位是 token，并给出 C 分档表；
否则任何按字面理解的作者都会一次性写出一大批必被拒的条目（我这次 57% 命中率）。

### 16.4 执行方式（下次照抄）

1. `aoci baseline.json` 里每个 index 文件都带 `sha256` ⇒ **写条目根本不需要 MCP**，
   `update-entry --source-sha256 <baseline 里的 sha>` 就够（`--preview` 也需要 sha，help 没说）。
2. 分 9 批并行写（后端 2 批 · 端侧 services 4 批 · providers+api 2 批 · 配置/根 1 批），
   每批产出 `{path: entry}` 的 JSON。
3. **两道机械校验**（都必须过）：
   - 自写的 `_validate_entries.py`：格式 / tag 字典 / E 档与行数一致 / A 锚点能 grep 到 / R 路径存在 / 项数上限；
   - **真实校验器** `_check_only.py`：逐条跑 `update-entry --preview`，按 token 判超限。
4. 超限条目回给原批次作者**重写 S**，再复检。
5. 批量写入（`_apply_entries.py`）。
6. `remove-entry` 清掉 3 个卷文件条目 → `verify` → `check` → `guide`。

### 16.5 又踩了一次「收据未结清」

批量写入时有一条（`aoci.code.txt` 自身）写成功但报 `Baseline is incomplete`，
留下 `.aoci/transactions/entries-*.json` 未完成收据，**之后所有写命令被拒**：
`An unfinished MCP write receipt or a foreign file exists under .aoci/transactions`。

判据：看收据里的 `post_index_sha256` **是否等于当前卷文件的 sha** ——
相等就说明**写已生效、只是收尾没跑完**，把该文件 `mv` 到 `.aoci/transactions/history/` 即可（guide 允许「by hand」）。
🔑 **不要删它、也不要重放**：重放会真的重复写一次。
