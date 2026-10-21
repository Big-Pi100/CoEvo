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
