# 复习评分按钮的作用 · 与 FSRS 调度审计报告

> 2026-09-26 ｜ 起因：白哥问「忘了/困难/一般/熟练这四个按钮是用来干什么的？」
> 调查方式：读代码 + **把 `fsrs5.rs` 原样编译运行**（`rustc`，非推测）
> 🔴 **本报告只调查，未修改任何代码。** 生产环境 `coevo.db` 时间戳未变。

---

## 一、直接回答：这四个按钮是 FSRS 自评

**它们决定「这张卡下次什么时候再出现」。** 不是「记录一下对错」，而是**直接改变复习排期**。

| 按钮 | 内部值 | 用户的意思 | 系统据此做什么 |
|---|---|---|---|
| **忘了** `again` | `Rating::Again = 1` | 完全没想起来 | **稳定性下降**，标记进 Relearning，**很快重来** |
| **困难** `hard` | `Rating::Hard = 2` | 想起来了，但很吃力 | 稳定性小幅增长 × 惩罚系数 `w15` |
| **一般** `good` | `Rating::Good = 3` | 正常想起来了 | 稳定性按公式增长 |
| **熟练** `easy` | `Rating::Easy = 4` | 毫不费力 | 稳定性增长 × 奖励系数 `w16` |

**理论效果**（四档应严格单调）：间隔 `忘了 < 困难 < 一般 < 熟练`。

**交互模式**：已在 `ui-ux-refactor-assessment-2026-09-25.md` §6.2 决策 ——
「点任意词条 → 进入翻卡模式（**翻卡 → 自评四档 → 自动下一张**），做完回到列表」。

---

## 二、🔴 但实测发现：**四档在算法上不成立，「熟练」反而最快重来**

**实测方法**：把 `backend/crates/card_engine/src/fsrs5.rs` 原样复制、加 `main`、`rustc -O` 编译运行。
**这不是推算，是代码的真实输出。**

### 2.1 成熟卡（已复习过，S=9 天）按下四个按钮

```
R1 忘了 → 下次 4.5 天
R2 困难 → 下次 1.1 个月
R3 一般 → 下次 1.8 个月      ← 最长
R4 熟练 → 下次 23.5 天       ← 🔴 比「困难」还短
```

**单调性检验（4 个测试点全部反了）**：

| 卡的状态 S_old | 困难 | 一般 | **熟练** | 结果 |
|---:|---:|---:|---:|---|
| 2 天 | 9.0 天 | 14.8 天 | **5.2 天** | 🔴 反 |
| 9 天 | 33.3 天 | 55.7 天 | **23.5 天** | 🔴 反 |
| 30 天 | 95.0 天 | 161.4 天 | **78.3 天** | 🔴 反 |
| 100 天 | 272.1 天 | 470.1 天 | **261.0 天** | 🔴 反（甚至比「困难」还短） |

**→ 用户点「熟练」，系统理解为「尽快再来考他」** —— 与设计意图完全相反。

### 2.2 更根本的问题：**间隔与「距上次多久」完全无关**

同一张卡（S=9, D=5），只改 `elapsed_days`（距上次复习的天数）：

| elapsed | 评「一般」得到的下次间隔 |
|---:|---|
| 0 天（同一天） | 1.8 个月 |
| 1 天 | 1.8 个月 |
| 9 天 | 1.8 个月 |
| 30 天 | 1.8 个月 |
| **365 天** | **1.8 个月** ← 一模一样 |

**→ FSRS 的核心机制失效了。** FSRS 的全部价值在于「**在快要忘的时候复习，收益最大**」——
而这里不管隔多久、忘得多干净，得到的间隔完全相同。

### 2.3 连带：同一天连续复习会把间隔推到 480 天

```
同日第 1 次「一般」→ 下次 57 小时
同日第 2 次        → 421 小时（17.5 天）
同日第 3 次        → 2433 小时（101 天）
同日第 4 次        → 11526 小时（480 天）  🔴
```

用户半天内点 4 次「一般」，这张卡就 480 天后才出现 —— **明显不合理**。
（官方 FSRS-5 有专门处理 24 小时内复习的分支，参数 `w17`/`w18`。）

---

## 三、根因（三处，均已定位到具体行）

### 🔴 根因 1：公式把 **rating** 当成了 **retrievability**（最严重）

`fsrs5.rs:128-136`：

```rust
fn stability_after_success(d: f64, s: f64, r: f64, _elapsed: f64) -> f64 {
    s * (1.0 + (W[8]).exp() * (11.0 - d) * s.powf(-W[9])
        * (((W[10]) * (1.0 - r / 4.0)).exp() - 1.0))    // ← r 是 rating，但这里要的是 R
        * hard_penalty * easy_bonus
}
```

**官方 FSRS-5 公式**（已核实，见文末来源）：

```
S' = S × (1 + e^{w8} · (11 − D) · S^{−w9} · (e^{w10·(1 − R)} − 1) · hard_penalty · easy_bonus)
```

**这里的 `R` 是 retrievability（当前保留概率，0~1），不是 rating（1~4）。**

官方文档明确表述：**「If R = 1 (100% recall) then `e^{w10(1-R)} − 1` = 0 … The lower R is, the higher the growth」**
—— 意思是 **R 越低（越接近遗忘），复习收益越大**。
而实现里 `r = rating as f64`，于是：

| 传入 | `1 − r/4` | `e^{w10·(1−r/4)} − 1` |
|---|---:|---:|
| Again(1) | 0.75 | **0.71**（增长最多） |
| Hard(2) | 0.50 | 0.44 |
| Good(3) | 0.25 | 0.27 |
| **Easy(4)** | **0.00** | **0.00** ← **增长项归零** |

**→ 评「熟练」时，公式的增长项变成 0，只能靠 `easy_bonus`（×2.61）线性放大。**
而评「忘了」反而涨得最多 —— **恰好把语义颠倒过来**。

### 🔴 根因 2：`elapsed_days` 被彻底忽略（两个函数都不用它）

```rust
fn stability_after_success(d: f64, s: f64, r: f64, _elapsed: f64) -> f64 {
                                                      // ↑ 下划线前缀 = 刻意标记"不用"
fn stability_after_failure(d: f64, s: f64, _elapsed: f64) -> f64 {
```

`schedule()` 收下了 `elapsed_days` 并传了进去，但两个函数都**没用**。
**没有 elapsed 就算不出 R**（`R = (1 + t/S · 19/81)^(-0.5)`）——
这也是根因 1 之所以「只能拿 rating 冒充 R」的原因。**两个问题是同一个。**

编译器自己也在提示：

```
warning: fields `lapses` and `last_review` are never read
```

### 🔴 根因 3：`submit_review` 遮蔽入参 rating → `review_log` 记的评分不可信

`fsrs_scheduler.rs:319-348`：

```rust
pub fn submit_review(conn, card_id,
    rating: i32,                    // ← HTTP 传进来的真实评分
    verification_type, verification_result, user_id, details_json) -> ... {

    // 1. 写入 review_log
    ... params![log_id, card_id, rating, ...]      // ← 用的是【入参】

    // 2. FSRS-5 scheduling
    let passed = verification_result == "pass";
    let rating = Rating::from_pass(passed, false); // ← 🔴 遮蔽了入参！重新推导
    let new_state = compute_next_state(conn, card_id, rating);
```

**后果**：`review_log.rating` 存的是**前端传来的值**，实际调度用的是**从 pass/fail 推导的值** ——
**两者可以不一致，且日志不会体现这一点**。数据分析和问题排查都会得出错误结论。

### 附：其余偏差（共 4 处，均已定位）

| # | 项 | 现状 | 官方 |
|---|---|---|---|
| 4 | `stability_after_failure` 的指数项 | `exp(w14 · (1 − D/10))` —— **用 difficulty 冒充 `(1−R)`** | `exp(w14 · (1 − R))` |
| 5 | 失败后的稳定性约束 | 只有下限 `.max(0.01)` | `S_new = min(S_forget, S_old / e^{w17·w18})` —— 保证失败后**必定下降且不超过一定幅度**（实测当前参数下 4 个测试点都正常下降，属**潜在**风险） |
| 6 | 🔴 **间隔的直接换算** | `interval_seconds = stability × 86400` —— **把「稳定性」直接当成「间隔」** | `interval = S / factor · (desired_retention^{1/decay} − 1)`，`factor = e^{ln(0.9)/decay} − 1` |
| 7 | `W` 参数版本 | **17 个参数**（FSRS-4.5 结构） | FSRS-5/6 是 **19 / 21 个**（多出 `w17`/`w18` = same-day 分支，`w19`/`w20` = decay/factor） |
| 8 | 目标保留率 | ❌ **无此配置** | `desired_retention`（默认 0.9）—— 用户可调「复习强度」（0.8 少复习 / 0.95 多复习） |

#### ✅ 参数来源已查清（原报告列为"待核实"，现已确认）

```rust
const W: [f64; 17] = [0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01,
                      1.49, 0.14, 0.94, 2.18, 0.05, 0.34, 1.26, 0.29, 2.61];
```

**这组值 = FSRS4Anki v4.3.0 的默认参数**（即 **FSRS-4.5** 的 17 参数），
来源是 `open-spaced-repetition/fsrs4anki` 的默认配置，被多个 FSRS 实现沿用为默认值。
文件头注释称「Source: fsrs-rs DEFAULT_PARAMETERS」—— 但**官方 `fsrs` crate 的 `DEFAULT_PARAMETERS` 是 19 个**。

**→ 结论：项目用的是「FSRS-4.5 的参数 + 自称 FSRS-5 的公式」，版本不匹配。**
`w17`/`w18`（same-day）与 `w19`/`w20`（decay）都**不存在**，所以 §2.3 的同日复习异常**在参数层面就无法修复**，必须先补参数。

---

## 四、🔴 硬编码：四档在实现里**只有两档在跑**

即使算法修好了，现在的代码路径**也产生不出 Hard / Easy**：

| 位置 | 代码 | 后果 |
|---|---|---|
| `fsrs5.rs:28` | `from_pass(passed, is_easy)` | 接口支持四档 |
| `fsrs_scheduler.rs:348` | `from_pass(passed, **false**)` | 🔴 `is_easy` **硬编码 false** → 永远不可能返回 Easy |
| `fsrs_scheduler.rs:463` | `from_pass(**true**, **false**)` | 🔴 隐式复习固定判 Good |
| `app/lib/screens/review_screen.dart:646` | `finalRating = finalResult == 'pass' ? 3 : 1` | 🔴 前端**只上报两档**（3=Good / 1=Again） |
| `app/lib/widgets/review_card_widget.dart:351,407` | 同上 | 🔴 同上 |

**→ 界面稿（L1）画了四个按钮，但端到端只有两个。** 界面稿是「目标形态」，实现是两档 —— 这个差距是**已知的、待实现的**，不是新问题。

---

## 五、影响评估

### ✅ 影响面比看起来小得多 —— **零迁移成本**

| 表 | 行数 |
|---|---:|
| `review_log` | **0** |
| `user_cards` | **0** |
| `card_memory` | **0** |

**→ 没有任何真实用户的复习历史被错误算法污染。** 现在修，代价只是改代码；上线后再修就要迁移数据。

### 什么时候会变成真问题

| 场景 | 后果 |
|---|---|
| 上线后用户点「熟练」 | 🔴 卡片**比点「一般」更早**回来 → 用户觉得"这软件乱排" |
| 用户每天复习（elapsed 小） | 🔴 间隔仍按同一公式暴涨 → 第 4 次同日复习就 480 天 |
| 连续评「一般」 | 🔴 8 次后间隔 **156 年**（实测）→ 卡片事实上永久消失 |
| 分析 `review_log` 做运营决策 | 🔴 rating 字段与实际调度不一致 |

---

## 六、修复方案（请白哥选）

### 🔴 先说一个改变方案形状的发现

我原本要推荐「引入官方 `fsrs` crate」，**核实后推翻**：

| crate | 依赖 | 结论 |
|---|---|---|
| **`fsrs`**（官方 fsrs-rs） | 🔴 **依赖 `burn` 深度学习框架，Cargo.lock 共 474 个包**，且 **burn 不是 optional**（唯一 feature 是 `experimental_cost_adr`） | ❌ **不适合** —— 2C1G VPS 装不下这个量级；这也正是当初写 `self-contained` 自研实现的原因 |
| **`rs-fsrs`** | ✅ 只依赖 `chrono`，**源码 62.8 kB** | 🟢 轻量，但以 git 依赖分发 |

**更关键的是下面这条** —— 官方 README 自己写着：

> **「If you only want to schedule cards, use `[lang]-fsrs` or the bindings. If you need to optimize, use this crate.」**

而 **`[lang]-fsrs` 里的 `dart` 版本，是纯 Dart 包，`pub get` 即可用，零原生依赖**：

| 项 | 内容 |
|---|---|
| 包名 | `fsrs`（pub.dev） |
| 平台 | **Android / iOS / Linux / macOS / web / Windows** |
| 四档 API | `Rating.again / hard / good / easy` —— **与界面稿完全一致** |
| 参数 | **21 个**（FSRS-6）· `desiredRetention: 0.9` · `learningSteps` · `relearningSteps` · `maximumInterval: 36500` |
| 额外能力 | `getRetrievability()` · `rollback()` · `computeParameters()`（端侧参数优化）· `reschedule()` |
| 本地环境 | ✅ 项目当前的 Flutter 是**鸿蒙定制版**，社区已有鸿蒙适配实践（pub 包，无需原生配置） |

**→ 而 v1 的设计要求本来就是「复习 ✅ 本地 FSRS」**（`v1-final-design-authoritative` 第 86 行）：

```
| 复习 | ✅ 本地 FSRS |
```

**→ 复习调度本来就该跑在端侧，不是后端。** 现在后端跑自研实现，既算错、又违背离线优先的设计。

---

### 方案 A（🟢 新首选）：**端侧改用 pub.dev 的 `fsrs` 纯 Dart 包**

| 项 | 说明 |
|---|---|
| 做法 | Flutter 端引入 `fsrs` 包，复习在**端侧**算；后端 `fsrs5.rs` 降级为「无端侧上报时的兜底」或直接移除 |
| 优点 | ✅ **算法由官方维护**，21 参数 FSRS-6 完整实现 ✅ **天然满足 v1 的「离线优先」** —— 断网也能复习 ✅ 零原生依赖、零 VPS 负担 ✅ 白拿 `desired_retention` / learning steps / fuzzing ✅ 顺带补上 §三 的全部 8 项偏差 |
| 要设计 | ⚠️ **多端同步**：v1 原本「单端登录踢旧」，现已改多端登录 → 端侧算出来的 `card_memory` 要上报，多设备如何收敛？（**这是唯一需要新设计的部分**，也是本方案的真实成本） |
| 预计 | 接入 **1 天**；多端同步设计 **另需 1–2 天** |

### 方案 B：**后端按官方公式修正自研实现**（保持端侧不算）

| # | 改动 | 行数 |
|---|---|---|
| 1 | 新增 `retrievability(elapsed, stability, decay)`：`R = (1 + t/S · factor)^decay` | ~10 |
| 2 | `stability_after_success` 改为接收 `R` 而非 `rating` | ~10 |
| 3 | `stability_after_failure` 的 `(1−D/10)` → `(1−R)` | ~3 |
| 4 | 失败后加 `min(S_forget, S_old / e^{w17·w18})` | ~3 |
| 5 | 补 `w17`/`w18`（same-day）、`w19`/`w20`（decay）→ **参数从 17 扩到 21** | ~20 |
| 6 | 间隔换算改用 `desired_retention` 反推，不再 `S × 86400` | ~12 |
| 7 | 打通四档：`submit_review` 用入参 rating、去掉硬编码 `false`、前端上报真实评分 | ~30 |
| 8 | 单测：**四档单调性**（`Again < Hard < Good < Easy`）+ elapsed 敏感性 + 同日复习不暴涨 | ~50 |
| 优点 | ✅ 不改架构 ✅ 离线时… | |
| 缺点 | 🔴 **仍然不符合「本地 FSRS」的 v1 设计**（断网无法复习） 🔴 算法正确性仍由我们承担 🔴 约 **1.5–2 天** | |

### 方案 C：**最小修复**（只修根因 1+2 + 打通四档）

先把「四档单调」和「elapsed 敏感」修对，同日复习靠前端限制（同一天不重复出同一张卡）绕过。
**约半天**。适合「想先让功能可用、架构问题另议」。

### 我的建议

**🟢 走方案 A**，理由：

1. **它同时解决三个问题**（算法正确性 + 离线优先 + 8 项偏差），而 B 只解决第一个
2. **v1 原文本来就要求本地 FSRS** —— 方案 A 是**回到设计**，不是改设计
3. **零 VPS 成本**（`burn` 那 474 个包不进生产）
4. 唯一新增的设计量是**多端同步**，而这是**无论选哪个方案都要面对的**（多端登录已定）

**唯一需要白哥先拍板的**：**复习调度到底在端侧还是服务端？**
- 若**端侧** → 方案 A（推荐）
- 若**服务端** → 方案 B（但需接受「断网不能复习」与 v1 设计冲突）

**无论哪个方案，第 7 项（打通四档）和第 8 项（单调性单测）都必须做** ——
**这个 bug 之所以能存在，就是因为没有任何测试断言过「四档单调」。**

---

## 七、请示

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | 🔴 **复习调度在端侧还是服务端？** | 🟠 **建议端侧** —— v1 原文即「本地 FSRS」，且断网可用是产品的离线优先定位 |
| 2 | 是否按方案 A / B / C 修复 | 🟠 端侧 → **A**；服务端 → **B**；只求先可用 → C |
| 3 | **界面稿是否要显示「下次 X 天」** | ✅ **建议加** —— 这一问的真正来源：**四个按钮看不出按了会怎样**。Anki 新版就是这样做的（按钮上直接标间隔）。改界面稿，不动代码 |
| 4 | 按钮中文译名 | 🟠 现为「忘了/困难/**一般**/熟练」。`Good` 译「一般」偏弱（它不是"一般般"，是"正常记住"）→ 建议「忘了 / 困难 / **记得** / 熟练」；**若按 #3 显示了间隔，中文可再简化** |
| 5 | 是否保留按钮英文（`again/hard/good/easy`） | 🟠 建议**去掉** —— 目标用户是中文母语者，英文副标题只是占位（这行是我加在界面稿里的） |
| 6 | 单测（四档单调性）是否作为强制项 | ✅ **建议强制** —— 这是本 bug 未被发现的直接原因 |

**⚠️ 遵照铁律：本报告只做调查，未改任何代码。等白哥批准后再实施。**

---

## 附：核实来源

| 事项 | 来源 | 类型 |
|---|---|---|
| FSRS-5 官方公式（含 `R` 是 retrievability，非 rating） | `open-spaced-repetition/fsrs-optimizer` 参数解释；`models/fsrs_v5.py` | 官方 |
| 官方原话「If R = 1 (100% recall) then `e^{w10(1-R)} − 1` = 0 … The lower R is, the higher α will be」 | `borretti.me/article/implementing-fsrs-in-100-lines`（逐项拆解官方公式） | 第三方逐项解读 |
| `R = (1 + t/S · factor)^decay` | FSRS 幂律遗忘曲线定义 | 官方 |
| `S_new = min(S_new, S_old / e^{w17·w18})`、`stability_short_term`（同日）、`w19`/`w20` | `docs.rs/crate/fsrs/4.1.1/source/src/model.rs` 源码 | **官方 crate 源码** |
| 🔴 **`fsrs` crate 依赖 `burn`，474 个包，无 feature 可关** | `github.com/open-spaced-repetition/fsrs-rs/Cargo.toml` + `deepwiki` 构建系统分析 | 官方仓库 |
| 官方推荐「只排程用 `[lang]-fsrs`，需优化才用 `fsrs`」 | `github.com/chrislongros/fsrs-rs` README 的 Q&A（摘自官方） | 官方仓库 |
| 🔑 **`fsrs` Dart 包（纯 Dart，21 参数，四档 API）** | `pub.dev/packages/fsrs` v2.0.1 | pub.dev |
| 纯 Dart 包无需原生配置（含鸿蒙实践） | 社区 Flutter/鸿蒙适配文章 | 社区实践 |
| **参数来源 = FSRS4Anki v4.3.0 默认（FSRS-4.5 的 17 参数）** | `l-m-sherlock.github.io/ZhiHuArchive/636564830.html`（FSRS4Anki 使用指北原文含该数组） | 官方作者文档 |
| 本项目代码行号 | `backend/crates/card_engine/src/fsrs5.rs` · `fsrs_scheduler.rs` · `shared_types/src/review.rs` · `app/lib/screens/review_screen.dart` · `app/lib/widgets/review_card_widget.dart` | 本仓库 |
| 四档实测数据 | **`fsrs5.rs` 原样编译运行**（`rustc -O`，非推算） | 本次实测 |

**⚠️ 未做的核实**（若采方案 A 需补）：
- `rs-fsrs` 是否已发布到 crates.io（官方 README 用 git 依赖，可能未发布）
- pub.dev `fsrs` 包与我方 Flutter（鸿蒙定制版）的 Dart 版本兼容性 —— **需实测 `flutter pub add fsrs`**

---

*本报告为调查产出，未修改代码或生产环境。`coevo.db` 时间戳未变。*
