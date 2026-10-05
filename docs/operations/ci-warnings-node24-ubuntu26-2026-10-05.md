# CI 警告处置报告：Node.js 20 弃用 + ubuntu-latest 迁移

> **日期**：2026-10-05
> **触发**：白哥反馈「全绿了，但是有一些警告 —— 8 warnings and 8 notices」
> **状态**：✅ **已实施并验证**（白哥 2026-10-05 批准「两件都选 A」· CI 复跑确认**警告已清零**）

---

## 一、结论摘要

| 警告族 | 条数 | 性质 | 建议 |
|---|---|---|---|
| **Node.js 20 弃用** | 8 | 现在被「**强制代跑**」所以仍绿；一旦 Node 20 从 runner 移除，这些 action **无处可跑** | ✅ **要处理**：升 action 版本 |
| **ubuntu-latest → Ubuntu 26** | 8 | GitHub 的**迁移预告**（纯通知，不是错误） | 🟡 **建议处理**：锁定 `ubuntu-24.04` 换确定性 |

两类都**不是我们代码的问题**，而是**依赖的生命周期**问题（第三方 action 的运行时 / runner 的基础镜像）。

---

## 二、Node.js 20 弃用（8 条）

### 根因

action **自身**的运行时声明是 `runs.using: node20`。GitHub 已把 runner 的默认运行时切到 Node 24，目前处于「**强制代跑**」阶段（所以仍然绿），并给出过渡期提示。

📌 **这和我们项目里用的 Node 版本无关**（本项目根本不装 Node）—— 说的是 **action 内部**跑的运行时。

### 各 action 的现状与目标版本（已用 `action.yml` 的 `runs.using` 逐条核实）

| Action | 现版本 | 现运行时 | **建议目标** | 依据（实测 `action.yml`） | 最新稳定 |
|---|---|---|---|---|---|
| `actions/checkout` | `@v4` | node20 ⚠️ | **`@v5`** | v5 → `using: node24` | v7.0.1 |
| `actions/cache` | `@v4` | node20 ⚠️ | **`@v5`** | v5 → `using: 'node24'` | v6.1.0 |
| `actions/setup-python` | `@v5` | node20 ⚠️ | **`@v6`** | v6 → `using: 'node24'` | v7.0.0 |
| `actions/upload-artifact` | `@v4` | node20 ⚠️ | **`@v6`** | v6 → `using: 'node24'` | v6 |
| `actions/download-artifact` | `@v4` | node20 ⚠️ | **`@v7`** | v7 → `using: 'node24'` | v7 |

> 🔴 **关键坑：`upload-artifact` / `download-artifact` 的 v5 **不算数**。**
> 官方 release note 明确写着「v5 只是**初步**支持 Node 24，**默认仍在 Node 20 上跑**」
> ⇒ 必须升到 **v6 / v7** 才真正消警。
> （这条若按「最小 major +1」的直觉去做，会**升级完照样报警**。）

### 未报警的（已兼容 Node 24，无需动）

`actions-rust-lang/setup-rust-toolchain@v1` · `dart-lang/setup-dart@v1` · `subosito/flutter-action@v2.23.0`

### Breaking change 影响面（逐条核对我们用法）

| 升级 | 官方 breaking 内容 | 我们是否受影响 | 依据 |
|---|---|---|---|
| checkout v4→v5 | v5.1+ 起 `allow-unsafe-pr-checkout` 默认 `false`（针对 `pull_request_target` / `workflow_run` 触发的检出） | **否** | 我们的触发只有 `push`(branches+tags) / `pull_request` / `workflow_dispatch`，**没有** `pull_request_target` / `workflow_run` |
| cache v4→v5 | 「只读缓存访问」的处理方式（`cache-hit` 语义不变） | **否** | 我们只用 `path` + `key` |
| setup-python v5→v6 | 升 Node24 + 新增 `pip-version` 等能力；`python-version` 用法不变 | **否** | 我们只用 `python-version: '3.13'`（且该 job 是 advisory） |
| upload-artifact v4→v6 | v4→v5 起后端架构变更（性能与行为改进） | **否** | 我们只用 `name` / `path` / `retention-days` |
| download-artifact v4→v7 | v5 改了「按 **ID** 下载」的落盘层级（按 name 不变） | **否** | 我们按 `name` 下载单件 ⇒ 仍直接解到 `path` |

### ⚠️ `actions/cache` 升级的特殊考量（本项目有**现场证据**）

🔴 **本项目历史上就因 `actions/cache@v5` 出过一次事故** ⇒ 不能当普通升级处理：

- **事故**（2026-10-04）：`ios-build`（**macOS**）解压 Flutter SDK 缓存时崩
  `Error: spawn EIO at actions/cache/v5/dist/restore/index.js:5069`（`Node.js v24.19.0`）
- **根因**：`subosito/flutter-action@v2` 浮动标签被上游静默升到 v2.22.0，
  其**内部**实现换成了 `actions/cache@v5`
- **当时应对**：flutter-action 钉 `v2.23.0` + **macOS 两个 job 设 `cache: false`**

**但证据是「按环境分区」的**（正是当时的判据「按证据分区处理，不搞一刀切」）：

| 环境 | 是否已跑 `actions/cache@v5` | 结果 |
|---|---|---|
| **ubuntu** —— `frontend` job 用 `flutter-action` 默认 `cache: true` ⇒ 内部就是 cache@v5 | ✅ 跑了，**每次 push 都跑** | **一直绿** |
| **macOS** —— `ios-build` / `ios-archive` | 已关（`cache: false`） | 崩过（`/opt/homebrew/bin/gtar` 解压） |

⇒ 我们要升的 `actions/cache@v4` → `v5` **只在 ubuntu**（`backend` / `backend-release`，
缓存 `~/.cargo/*` + `backend/target`）。
而 `frontend` job **已经在本仓库的 ubuntu 上跑着 cache@v5 并全绿** ——
这是**同环境、同版本**的直接证据。

📌 **结论**：ubuntu 上升 v5 **风险低**；macOS 那条已知故障路径**本来就没用**我们的
`actions/cache`（它走 flutter-action 且已 `cache: false`）⇒ 本次升级**不触碰它**。
⚠️ 仍须在推 main 后**确认 `backend` / `backend-release` 两个 job 的缓存步骤绿**。

### 那处注释：判定为「**描述**」⇒ ⛔ **不能动**（我先前判错，此处订正）

`grep -c "actions/cache@v4" ci.yml` 返回 **3**，而真实 `uses:` 只有 **2** 处。
第 3 处（`ci.yml:997`）我**起初**判为「旧版本号残留、须一并更新」—— **这是错的**。

上下文（995–998 行）说的是「**旧版 `flutter-action` v2.21.0 内部**使用的
`actions/cache@v4` 是否仍被 cache 服务支持」。而 v2.21.0 正是「最后一个未用 v5 的版本」
⇒ 它内部**就是 v4** ⇒ 这处是**准确的描述**，改成 v5 反而会变成**错误陈述**。

📌 判据：**「出现过某字符串」≠「它是残留」** —— 先判它是**描述**还是**引用**：

| 位置 | 性质 | 处理 |
|---|---|---|
| `ci.yml:62 / 107` | **引用**（我们 `uses:` 的） | ✅ 升级到 v5 |
| `ci.yml:997` | **描述**（第三方旧版的内部依赖） | ⛔ **保持 v4** |
| `ci.yml:985 / 986 / 995` · `ios-archive.yml:87` | **描述**（历史事故留档） | ⛔ **不动** |

### 需改站点（共 **17 处代码 / 2 个文件**）

> ⚠️ 下表行号是**改动前**的位置；实施时在 `ci.yml` 顶部插了说明块 ⇒ 改后整体下移约 30 行。
> 自查请用 `grep -n "uses: actions/" .github/workflows/*.yml`，**不要依赖行号**。

- **`ci.yml`**：
  - `actions/checkout@v4` × **10**（行 43 / 98 / 327 / 428 / 490 / 647 / 768 / 819 / 894 / 948）
  - `actions/cache@v4` × **2**（行 62 / 107）
  - `actions/setup-python@v5` × **1**（行 896）
  - `actions/upload-artifact@v4` × **1**（行 137）
  - `actions/download-artifact@v4` × **1**（行 170）
  - 📝 **注释 × 1**（行 997，`actions/cache@v4` → `@v5`）
- **`ios-archive.yml`**：`actions/checkout@v4` × 1（行 52）· `actions/upload-artifact@v4` × 1（行 225）

> **为什么 `ios-archive.yml` 也要改**：它只在**手动触发**时跑，所以**这次没报警**；
> 但版本面必须一致，否则下次手动归档会冒同样的警告。
> 📌 判据：「没报警」≠「没问题」—— 只是**没跑到**（与「顺次门禁只报第一个」同源）。

---

## 三、ubuntu-latest → Ubuntu 26（8 条通知）

### 是什么

GitHub 通知：`ubuntu-latest` 标签**自 2026-10-19 起**开始迁移到 Ubuntu 26。

🔴 **实际有 10 个 job 用 `ubuntu-latest`，却只收到 8 条通知** ——
因为 `push main` 时只有 8 个 job 会跑（`backend-release` / `backend-deploy` 要推 tag 才跑）。
📌 又一次「**没报警 ≠ 没问题，只是没跑到**」（同「顺次门禁只报第一个」）。
⇒ **要改的是 10 处，不是 8 处。**

### 为什么要重视

- **`query-verify`** job 依赖 `sqflite_common_ffi` 加载系统 sqlite3（我们已显式 `apt-get install libsqlite3-0` 缓解）
- **`backend` / `frontend`** job 依赖 apt 装的构建链（rust / flutter 的宿主依赖）

**基础镜像换代 = 这些底层依赖换代**，属于「可能静默换行为」的一类。
⚠️ 通知里说的日期是 **10-19**（距今约两周），而项目正处于**上架窗口**。

### 三个选项

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A（建议）** | 锁定 `ubuntu-24.04` | **确定性**：发版窗口内基础镜像不变，升级时机自己选 | 需要**偶尔主动**迁移（不锁就自动跟） |
| **B** | 保持 `ubuntu-latest` | 永远最新、免维护 | 会在**你不选的时间点**换代（可能正落在上架窗口） |
| **C** | 保持 `ubuntu-latest`，另加一条「底层依赖体检」步骤 | 兼顾最新与安全 | 多一件要维护的东西 |

> **建议 A**：项目在发版窗口附近，把「基础镜像」这个变量**钉住**，比省一次迁移更值。
> 迁移到 26 可以等上架之后，**自己挑时间**做。

---

## 四、建议方案（待批）

1. **action 升到「最小 Node24 版本」**（**不是**最新 major）—— 最小化 breaking 面：
   `checkout→v5` · `cache→v5` · `setup-python→v6` · `upload-artifact→v6` · `download-artifact→v7`
2. **8 个 job 的 `runs-on` 锁到 `ubuntu-24.04`**
3. 实施后**推 main 看 CI**（本机 flutter 崩 ⇒ 渲染与 lint 本机验不了，CI 是唯一权威）；
   确认两点：**8 warnings 清零** + **8 notices 里 ubuntu 的 8 条消失**（Node 那 8 条随之消失）

### 备选

- **升到最新 major**（`checkout v7` / `cache v6` / `setup-python v7`）：一次到位，但 breaking 面更大、收益不明确 ⇒ 不推荐。
- **ubuntu 选 B（不动）**：可接受，但要有「迁移可能落在上架窗口」的心理准备。

---

## 五、核实方法（可复现）

`runs.using` 是**权威判据**（不看 release 标题、不猜「+1 major」）：

```bash
# 逐个 action 查它声明的运行时
curl -sL https://raw.githubusercontent.com/actions/checkout/v5/action.yml        | grep -A1 '^runs:'
curl -sL https://raw.githubusercontent.com/actions/cache/v5/action.yml            | grep -A1 '^runs:'
curl -sL https://raw.githubusercontent.com/actions/setup-python/v6/action.yml     | grep -A1 '^runs:'
curl -sL https://raw.githubusercontent.com/actions/upload-artifact/v6/action.yml  | grep -A1 '^runs:'
curl -sL https://raw.githubusercontent.com/actions/download-artifact/v7/action.yml| grep -A1 '^runs:'
```

📌 判据：**「版本号更大」≠「已升 Node24」** —— 同上 artifact 的 v5 陷阱。
本仓库已有的同族教训：**「声明」须实测才算数**。

---

## 六、附：为什么两类都「不是我们代码的问题」

| | 谁的生命周期 | 谁负责修 | 多久会真的坏 |
|---|---|---|---|
| Node 20 弃用 | 第三方 action 的运行时 | **我们**（升版本） | Node 20 从 runner 移除后（现在被强制代跑） |
| ubuntu 迁移 | GitHub 的 runner 镜像 | **我们**（锁或跟） | 2026-10-19 起开始迁移 |

两者共同点：**「现在是绿的」不代表「以后是绿的」** —— 绿色只说明「当前这次跑通了」。
📌 与既有判据同族：**「全绿」≠「通过」**（一个是「这次跑通」，一个是「长期正确」）。

---

## 七、实施记录（2026-10-05）

白哥批准 **① 升最小 Node24 版本** 与 **② 锁 `ubuntu-24.04`** 两项都选 A。

### 实际改动（脚本精确替换 + 计数自校验）

| 文件 | 改动 | 处数 |
|---|---|---|
| `ci.yml` | `actions/checkout@v4` → **`@v5`** | 10 |
| `ci.yml` | `actions/cache@v4` → **`@v5`** | 2 |
| `ci.yml` | `actions/setup-python@v5` → **`@v6`** | 1 |
| `ci.yml` | `actions/upload-artifact@v4` → **`@v6`** | 1 |
| `ci.yml` | `actions/download-artifact@v4` → **`@v7`** | 1 |
| `ci.yml` | `runs-on: ubuntu-latest` → **`ubuntu-24.04`** | **10** |
| `ios-archive.yml` | `checkout@v4` → `@v5` · `upload-artifact@v4` → `@v6` | 2 |
| `ci.yml` 顶部 | 🆕 加「别改回去」约定块（含 macOS 暂不动的理由） | — |

**合计 27 处替换 / 2 个文件**（`git diff --stat`：+49 / −27 行，含新增说明）。

### 🔴 替换方式的一个刻意选择

只替换 **`uses: actions/…@vN`**（带 `uses: ` 前缀），**不是**裸替换 `actions/cache@v4`：
⇒ 注释里那处（`ci.yml:997`）**自动被排除**，不会被我误改（见 §二 的「描述 vs 引用」）。
📌 判据：**「要改什么」的判据写在替换式里，比写在注释里可靠** ——
   注释会被忽略，替换式**每次都会执行**。

### 校验

- ✅ 两个 workflow 的 **YAML 解析成功**（11 jobs / 1 job）
- ✅ `runs-on` 全 11 个 job 逐个核对：10 × `ubuntu-24.04` + 1 × `macos-latest`
- ✅ 替换后计数自校验：旧版本引用全部 **0**，新版本引用数量与预期一致
- ✅ 那处「描述」按预期**未被改动**（`actions/cache@v4` 全文件 = 1）
- ✅ **CI 已验证**（2026-10-05，白哥复跑确认）：「**警告已清零**」——
  8 条 Node.js 20 警告 + 8 条 ubuntu 迁移通知**全部消失**，且各 job 全绿

### 顺带发现的两处「我自己的口径错误」（已订正）

1. 报告初稿把 `ci.yml:997` 判为「须一并更新的旧版本号」—— 实际是**描述**（见 §二）⇒ 订正
2. 报告初稿写「8 个 job 用 ubuntu-latest」—— 实际 **10 个**，8 条通知只因另外 2 个没跑
   ⇒ 订正，且它本身就是「**没报警 ≠ 没问题**」的又一实例
