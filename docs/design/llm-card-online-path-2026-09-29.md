# 接 LLM 制卡 —— 现状核实与方案（含 4 项待裁决）

> 2026-09-29 ｜ 触发：白哥「接 LLM 制卡」（待办 ② · 前一轮定的新重心）
> **本文只调查，未改动任何代码/数据。**
> 口径：对 `docs/design/v1-final-design-authoritative-2026-09-25.md`（L0）· `scripts/coevo_wordlib_contract.py` ·
> `backend/**/*.rs` · `app/lib/**` 的**本机实测**
> 前置背景：后端旧学习链已于 09-29 退役（净删 ~16k 行）；VPS「曾部署已停」且已释放

---

## 〇、一句话结论

| 项 | 结论 |
|---|---|
| **规格** | ✅ **L0 v1 早已写定完整设计**（含表结构、接口、流程、实施阶段）→ 不是新设计，是**回归原文** |
| **现状** | 🔴 **四条链路全缺**：端侧缓存表 · 服务端全局缓存 · 接口 · 客户端未命中分支 |
| **地基** | ✅ **四块可复用**：契约 v5 · `tencent_asr.rs`（后端代理调三方 API 的现成模式）· `.env` 已有 `DEEPSEEK_API_KEY` · 校验器 |
| 🔴 **最大缺口** | **契约 v5 不产 `ipa` / `definition` / `context`** —— 这三个字段原本来自 `coevo.db`（**已被清库**）→ **契约必须扩 v6** |
| 🔴 **架构前提** | **「全局缓存」需要服务端** —— 端侧直连会打破零边际成本（成本 ∝ 用户数） |
| 🔴 **需裁决** | ① 写哪（`external_word_cache` vs `word.db`）② 服务端是否随之上（VPS 已释放）③ 失败路径（L0 说「降级卡」，白哥说「报错」）④ 是否与 P0 的 196 条合并做 |

---

## 一、规格溯源：L0 早已写定（这是第 4 次「规格早就有」）

`v1-final-design-authoritative-2026-09-25.md`（**L0 · 白哥原文 · 最高权威**）：

| v1 位置 | 原文 |
|---|---|
| 第 26 行（架构图） | 「预制卡片直接展示 ↓ **词库外生词 → LLM 兜底制卡**」 |
| 第 40 行（决策表） | 联网场景 = 登录/同步 + **词库外生词制卡** + 语音包下载 |
| 第 74 行（云端职责） | **「LLM 制卡服务 + 全局缓存」** |
| 第 352 行（端侧表） | `CREATE TABLE external_word_cache (spelling UNIQUE, card_content, fetched_at, pending_push)` |
| 第 470 行（服务端表） | `external_word_cache`（`PRIMARY KEY (user_id, spelling)`） |
| 第 479 行（服务端表） | **`generated_card_cache`（`spelling` PK · `hit_count`）** ← 跨用户复用的核心 |
| 第 837 行（接口） | **`POST /generate-card  # 词库外生词兜底`** |
| 第 1103–1119 行（§九 查词流程） | 未命中 → 查 `external_word_cache` → 仍无 → **联网 LLM 制卡 → 写缓存 → 显示** |
| 第 1177 行（边界情况） | `LLM 制卡失败` → **「返回降级卡片（仅释义），标记可重试」** ← ⚠️ 见 §五③ |
| 第 1178 行 | 词库外生词 → **先查本地缓存，再查服务端全局缓存，最后 LLM** |
| 第 1199–1204 行（实施路线） | **Phase 3「兜底与增强」**：① LLM 制卡服务 + 全局缓存 ② 词库外生词 TTS 兜底 |

**配套的顶层原则**（09-26 记录，白哥确认）：
> 「即时生成**不是另一套流程**，而是「**同一套流程 + 词表未命中分支**」」

→ 即：**契约 / 校验 / 落库口径必须与预制卡一致**（与白哥 09-28 的第 ① 条决定完全吻合）。

---

## 二、现状核实：四条链路全缺

| 环节 | 状态 | 证据 |
|---|---|---|
| 端侧 `external_word_cache` | 🔴 **不存在** | `word.db` / `user.db` 均无此表（`user_db_schema.sql` 5 表已确认） |
| 服务端 `generated_card_cache` | 🔴 **不存在** | `coevo.db` 45 表清理后无此表 |
| `POST /generate-card` | 🔴 **不存在** | `routes.rs` 107 个路由中无此路径 |
| 客户端未命中分支 | 🔴 **不存在** | `word_query_service.dart:89` `return null` → 调用方只弹「词库里没有「X」」→ **结束** |
| 后端调 LLM 的能力 | 🔴 **无** | `grep -i llm backend/**/*.rs` → 0 命中 |

⚠️ **顺带纠正一个我此前的错误**：我曾在报告里把「LLM 兜底」写成**已存在的成本项**，
实际它是**要新建的路径**（依据只有 `word_query_service.dart:65` 的一行注释）。
→ 已入判据：「**注释里的能力声明必须 grep 一遍才算数**」。

---

## 三、可复用的地基（四块，这是好消息）

### 3.1 契约 v5 —— `scripts/coevo_wordlib_contract.py`（404 行）

| 项 | 内容 |
|---|---|
| 模型 | `deepseek-flash`（`COEVO_LLM_MODEL` 可覆盖） |
| 版本 | `CONTRACT_VERSION = 'v5'`（v1→v5 演进：+entry_type / +etyma[].parent / +「信任自身词汇知识」反制规则） |
| 单条入口 | **`call_llm(key, word, retries=4, definition=None, timeout=120)`** ← 在线路径可直接用 |
| 价格常量 | `P_IN, P_OUT = 1.5, 4.5`（¥/1M token） |
| 可观测性 | `STATS`（`retried_calls` / `retries` / `http_429`）—— 🔑 没有它就看不出限流（09-26 实测教训） |

🔴 **契约第 122 行已内建 P0 污染的防护**（原文）：
> `If the given word's OWN definition (shown to you) is unrelated to its spelling — e.g. a function word whose gloss describes an emotion — TRUST YOUR OWN LEXICAL KNOWLEDGE over the supplied definition, and set is_own_entry=true with a correct reason.`

→ 说明当时**已经预见**「传入释义与拼写不符」（`a` ← happy 那类）。这个规则**在线路径必须保留**。

### 3.2 「后端代理调第三方 API」有**现成模式**：`tencent_asr.rs`（186 行）

```
backend/.env  ──env::var("TENCENT_SECRET_ID")──►  secret（key 只在服务端）
                                                        │
POST /api/stt/transcribe  ──►  tencent_asr::recognize()  ──►  腾讯云 ASR
      ↑ 参数校验失败 → 400          · reqwest                  │
      ↑ 上游失败 → 500 + 日志        · Duration::from_secs(10) │
```

🔑 **这正是 LLM 制卡服务该抄的骨架**：key 在服务端 · 超时明确 · 错误分「参数错 400 / 上游错 500」· 有 `tracing` 日志。

### 3.3 后端 `.env` **已有 `DEEPSEEK_API_KEY`** ✅

实测 `backend/.env` 的键名（值未读、不记录）：
`DEEPSEEK_API_KEY` · `COEVO_ADMIN_KEY` · `COEVO_PII_KEY` · `TENCENT_*` · `WECHAT_*` · `PUBLIC_BASE_URL`
→ 🔑 **key 已在服务端环境，不在客户端**（app 侧实测 0 处 LLM key 痕迹 ✅ 这是对的方向）

`reqwest` 已在 `api_server/Cargo.toml` 依赖中 ✅。

### 3.4 校验器已就绪：`scripts/verify_card_field_consistency.py`

前一轮交付（196 条全库扫描用）。`--word X` 可作**生成后闸门**——正是「统一校验」的落点。

---

## 四、🔴🔴 最大缺口：契约 v5 **不产三个关键字段**

这是本次调查**最重要**的技术结论，它决定了工作量。

### 4.1 `card.content` 的实际结构（实测 `london`）

```
card.content = { front, ipa, entry_type, sections[] }
                                   │
     ┌─────────────────────────────┴──────────────────────────────┐
     │ sections 段类型：definition / context / collocation /       │
     │                  etymology / root / image …                 │
     └────────────────────────────────────────────────────────────┘
```

### 4.2 各字段的**来源**（读 `load_llm_results.py`）

| 字段 | 来源 | **现状** |
|---|---|---|
| `front` | 词表 | ✅ |
| **`ipa`** | `src_pron` ← `coevo.db` 的 `prebuilt_language_cards.pronunciation` | 🔴 **该表已清**（09-29） |
| **`definition` 段** | `src_defs` ← `coevo.db` 的 `prebuilt_language_cards.definitions` | 🔴 **该表已清** |
| **`context` 段** | `definitions[].ex`（同一来源） | 🔴 **该表已清** |
| `collocation` / `etymology` / `root` 段 | ✅ **LLM 契约产出** | ✅ |
| `entry_type` | ✅ 契约产出（v4 新增） | ✅ |

**契约 v5 的 PROMPT 输出字段**（逐条核对）：
`word` · `entry_type` · `is_own_entry` · `derived_from` · `reason` · `morphology` · `etymology` · `collocations` · `mnemonic` · `confidence`
→ **没有 `ipa` / `definition` / `context`** 🔴

### 4.3 结论：**契约必须扩 v6**

| 要新增 | 说明 |
|---|---|
| `ipa` | 音标（英美可并存） |
| `definition` | 英文释义 + 中文释义 + 词性（`pos`） |
| `context` | 例句（**须含该词或其变形** —— 正是 P0 的 S4 信号判据） |

🔑 **而且这恰好把两件事合并了**：
- `a`（ipa/def/ctx 三段是 happy 的）· `with`（ipa 是 it 的）· `health care`（整卡是 heal 的）
  → **全部来自 `coevo.db` 这个不洁数据源**
- 契约自产这三个字段后 → **该数据源被彻底绕开** → **P0 的根因也被绕开**

> ⚠️ 但**存量 196 条仍要单独修**（已批的方案 A）—— 扩契约只保证**以后**不再产生。

---

## 五、🔴 四个必须裁决的点

### ① 写入目标：`external_word_cache` 还是 `word.db`？

| | L0 v1 §九 原文 | 白哥 09-28 口径 |
|---|---|---|
| 写入 | **`external_word_cache`**（独立缓存表） | 「走 LLM 生词 → **进入词库**」 |

🔴 **这不是措辞差异，技术后果完全不同**：

| 若写 `word.db` | 后果 |
|---|---|
| 打开方式 | 🔴 现在 **`readOnly: true`**（`word_query_service.dart:44`）→ 必须改可写 |
| **与 bootstrap 冲突** | 🔴🔴 `word_db_bootstrap.dart` 靠「**文件大小**」判断是否覆盖 —— 用户写入后大小变了 → 下次启动**覆盖回官方词库 → 用户生成的卡全丢** |
| 补救 | 需引入版本号文件（该文件注释第 29 行**已预告**此改法：「若将来真出现，应改为 `word_db.version`」） |
| 词库语义 | 词库从「随 App 发布的静态资产」变成「用户可变的混合体」→ **同步/回滚/体积都变复杂** |

| 若写 `external_word_cache`（L0 原文） | 后果 |
|---|---|
| 落点 | `user.db` 加一张表（走已有 v3 迁移机制） |
| `word.db` | ✅ **完全不动**（保持只读 + bootstrap 不变） |
| 查词链路 | 加一步「查缓存」（L0 §九 已定义） |
| 语义 | 干净：**「官方词库」与「按需生成的缓存」分离** |

**我建议 L0 原文（写缓存表）** —— 它回避了 bootstrap 冲突，且 `pending_push` 字段本就为将来同步设计。

### ② 服务端是否随之上？（VPS 已释放）

🔴 **成本模型的关键在「全局缓存」**：

- L0 设计：`generated_card_cache`（**服务端 · 跨用户** · `hit_count`）
- 09-25 实测：**10,000 用户规模下，缓存未命中仅 ~13,500 次 LLM/月** → 成本随「**唯一词数**」增长，英文常用词 2–5 万 → **天然收敛**
- 🔴 **端侧直连 LLM 会打破这一点**：无全局缓存 → 同一新词**每个用户各付一次** → **成本 ∝ 用户数**

**而且后端终究要重新部署** —— app 现役仍在调 `auth` / `pay` / `notifications` / `referral` / `trial` / `user`
（订阅制变现完全依赖它）。「VPS 已释放」≠「不需要服务端」，只是**当前没跑**。

→ **建议**：**LLM 制卡服务跟随后端一起重建**（照 `tencent_asr.rs` 模式加 `llm_card.rs` + `POST /api/generate-card`）。

### ③ 失败路径：L0 与白哥最新指令**冲突**

| 出处 | 处理 |
|---|---|
| **L0 v1 第 1177 行** | 「返回**降级卡片（仅释义）**，标记可重试」 |
| **白哥 2026-09-28** | 「失败路径 —— **直接报错，让用户稍后重试**」 |

🔴 按文档分层规则 L0 最高权威；但白哥是 L0 的作者，他后来的话**等于改 L0**。
→ **需你一句话裁决**（我倾向：**报错 + 可重试**，理由见下）。

> 🔑 两个方案的差别其实在**「降级卡能不能看」**：
> · L0 的降级卡 = 「仅释义」→ 但**释义正是要 LLM 生成的那个字段** → 失败时**没有释义可给**
>   → L0 这个设计**在「契约自产释义」的新前提下已不成立**（它假设释义来自本地词表）
> · 所以**报错更诚实** —— 这正好符合本项目既有判据：
>   「**「静默失败 + 无出口」比「报错」更糟**」

### ④ 是否与已批的「P0 方案 A（196 条 LLM 复核+重生成）」**合并做**？

| | 关系 |
|---|---|
| P0 方案 A | 196 条**存量**错数据修正（已批待开工） |
| LLM 制卡 | **新建在线路径** |
| **重合点** | ① 都要跑 LLM ② 都要过同一道校验闸门 ③ **都要扩契约**（v6 加三个字段） |

→ **建议合并**：先用 196 条（+ 缺口样本集）当**契约 v6 的实测集**，验证质量后再建管道。
这符合「**先验证质量再建管道**」的顺序（避免建完发现质量不达标）。

---

## 六、成本估算

| 项 | 数值 | 依据 |
|---|---|---|
| 单条生成 | **约 ¥0.007–0.011** | 契约 v5 实测 ¥2.21 / 210 条 × 2 轮 |
| 增量（10k 用户） | **~13,500 条/月** | 09-25 实测（**含全局缓存**） |
| **月成本（10k 用户）** | **约 ¥100–150/月** | 上面两项相乘 |
| 🔴 **无全局缓存时** | **∝ 用户数**（线性增长） | —— 这是端侧直连不可取的核心原因 |

> 注：`deepseek-flash` 价格 `P_IN=1.5 / P_OUT=4.5`（¥/1M token）已写在契约里。

---

## 七、方案选项

| # | 方案 | 服务端 | 全局缓存 | key 安全 | 成本 | 评价 |
|---|---|---|---|---|---|---|
| **甲** ⭐ | **后端加 `POST /api/generate-card`**（照 `tencent_asr.rs`）+ 全局缓存 + 端侧缓存表 | 需要 | ✅ | ✅ key 在服务端 | 固定 | **L0 原文**；与现役后端同源 |
| 乙 | 端侧直连 DeepSeek | 不需要 | ❌ | 🔴 **key 打进 IPA 会泄漏** | **∝ 用户数** | ❌ 不可取 |
| 丙 | 端侧直连 + 轻量代理（仅转发） | 需要 | ✅ | ✅ | 固定 | ≈ 甲但多一层，无收益 |

**建议：甲。** 且分两步走（见 §八），第 1 步**不需要服务端**即可先验证质量。

---

## 八、建议实施步骤（分两步，第 1 步与部署解耦）

### 第 1 步：契约 v6 + 质量实测（**不需要服务端，我可以独立完成**）

1. **扩契约 v5 → v6**：`PROMPT` 增加 `ipa` / `definition`（`pos`+`en`+`zh`）/ `context`（例句）
   - 🔴 例句**必须含该词或其变形**（这条要写进 HARD RULE —— 正是 P0 的 S4 判据）
2. **用两批真实样本跑**：
   - **P0 的 196 条**（已批的方案 A · 现成的「已知错」样本）
   - **词库缺口样本**（`hong kong` / `behavior` / `cannot` / `herring` / `flying pan` …）
3. **过校验闸门**（`verify_card_field_consistency.py`）+ **人眼复核**（我看，你抽验）
4. 产出**质量报告 + 成本实测** → 再决定第 2 步

> 🔑 这一步的价值：**在不部署任何东西的前提下，先回答「LLM 生成的卡到底能不能用」**。

### 第 2 步：在线路径（**需要服务端**，只能你部署）

5. `user.db` 加 `external_word_cache`（v3 → v4 迁移，走已有幂等机制）
6. 端侧：查词未命中 → 查缓存 → 未命中 → **转圈** → 调 `POST /api/generate-card` → 写缓存 → 显示
7. 后端：**重建部署** + `llm_card.rs` + `generated_card_cache` 表 + 落库前过校验闸门
8. 失败路径按 §五③ 的裁决实现
9. **不落盘的会话内缓存**（避免同一页反复问同一个词）

---

## 九、风险清单

| # | 风险 | 缓解 |
|---|---|---|
| 1 | 🔴 **端侧直连会让 key 泄漏** | 明确走服务端（甲） |
| 2 | 🔴 **写 `word.db` 会与 bootstrap 冲突** → 覆盖丢数据 | 写 `user.db` 缓存表（L0 原文） |
| 3 | **卡面两种水准** | 白哥已定：预制卡**本就是 LLM 生成** → 统一 prompt/契约/校验即可（≠ 同一脚本） |
| 4 | **在线生成质量未经实测** | 第 1 步先实测（这是不部署就能做的） |
| 5 | **限流被掩盖成「慢但成功」** | 契约已有 `STATS`（`http_429` / `retries`）→ 在线路径也须上报 |
| 6 | **无全局缓存时成本失控** | 必须有 `generated_card_cache` |

---

## 十、待白哥裁决（4 项）

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | **写入目标**：`external_word_cache`（L0）还是 `word.db`（09-28 口径）？ | ⭐ **`external_word_cache`** —— 写 `word.db` 会与 bootstrap 的大小判断冲突（**会覆盖丢用户数据**） |
| 2 | **服务端**：LLM 制卡是否随后端重建？ | ⭐ **是** —— 全局缓存是成本模型的基石；且后端本就必需（支付/登录） |
| 3 | **失败路径**：L0 的「降级卡」还是你说的「直接报错」？ | ⭐ **报错 + 稍后重试**（L0 的降级卡在新前提下已不成立：失败时**没有释义可给**） |
| 4 | **是否先做第 1 步（契约 v6 + 质量实测）**？ | ⭐ **先做** —— 不需要任何部署，先回答「质量能不能用」 |

---

---

## 十一、🆕 三层缓存 + 词库回流（回答白哥的疑问）

> 白哥问：「写 `external_word_cache` 缓存，**如何更新 `word.db` 完善词表**，
> 以便达成**随着用户查询词库不断完善，直到查词 LLM 调用趋近于 0**？」

### 11.1 先纠正一个因果：这两件事**由不同机制达成**

白哥的直觉在**单机视角**下是对的（查过的词就有卡了），但在**多用户视角**下，
「成本趋近于 0」**在全局缓存那一层就已经达成了**，不需要等 `word.db` 更新。

| 目标 | 真正的机制 | 何时生效 |
|---|---|---|
| **LLM 调用趋近于 0** | 🔑 **服务端 `generated_card_cache`**（跨用户复用） | **即时**（第 2 个人查就不再调 LLM） |
| **词库不断完善 / 离线可用** | `word.db` 回流 + 版本发布 | **批次**（每次发版） |

**「趋近于 0」的数学形式**（可验证）：

```
设 W = 该产品用户可能查到的「唯一词数」（英文常用词 ≈ 2–5 万）
    U = 用户数

累计 LLM 调用总量  →  收敛于 W（与 U 无关）
人均 LLM 调用      =   W / U      →  U 越大越趋近于 0  ✅
```

🔑 **关键**：上界是 **W（唯一词数）**，**不是**「U × 查询次数」——
所以白哥说的「趋近于 0」**成立**，而且**靠全局缓存就够了**（09-25 实测：10k 用户仅 ~13,500 次/月）。

⚠️ **但它是「趋近」而不是「等于」** —— 长尾永远有残余：
新闻里的新词 / 罕见词 / 专有名词是**持续产生**的（`hong kong` 这类第一次永远要 LLM）。
→ 收敛的是**人均**，不是**绝对量**。

### 11.2 三层分工（各管一段，互不替代）

| 层 | 存什么 | 谁复用 | 生效时机 | 解决 |
|---|---|---|---|---|
| **① 端侧 `external_word_cache`**（`user.db`） | 本机查过的词卡 | 只本机 | 即时 | 本机重复查（离线也能看） |
| **② 服务端 `generated_card_cache`**（`coevo.db` · L0 §479） | 全体生成过的（含 `hit_count`） | **全体用户** | **即时** | 🔑 **成本趋近 0 的主力** |
| **③ `word.db`（assets）** | 已验证的高频词 | 全体（**离线**） | **版本发布** | **离线可用 + 免网络往返** |

🔑 **① 与 ② 的区别就是白哥问题的起点**：
- 只写 ① → 上面那位用户下次不用调，但**别人**还要调 → 成本 ∝ 用户数
- 加了 ② → **跨用户复用** → 成本 ∝ 唯一词数 ✅
- 加了 ③ → 连网络往返都省了（划词是高频动作，**转圈 vs 瞬时**差别很大）

### 11.3 回流流水线（四阶段 —— **不是「实时同步」**）

```
① 用户划词未命中
      ↓
② 查 服务端全局缓存 ──命中──► 返回（0 次 LLM）
      ↓ 未命中
③ 调 LLM 制卡 ──► 写 全局缓存(②) + 写 端侧缓存(①) ──► 返回
      │                     · hit_count 累加
      ↓
④ 【定期 · 离线】快照脚本：全局缓存里 hit_count ≥ 门槛 的词
      → 生成完整词条血缘 → 过校验闸门 → 合并进 word.db
      → 随下次 App 发布带上（端侧 bootstrap 检测到大小变化 → 自动覆盖）
```

🔴 **为什么必须是「批次快照」而不是「实时写 `word.db`」**（三个独立理由）：

| # | 理由 |
|---|---|
| 1 | **端侧 `word.db` 是 assets**（只读 + 靠**文件大小**判断覆盖）→ 运行期写入必然与 bootstrap 冲突（**会覆盖丢数据**） |
| 2 | **「完善」需要跨用户聚合**（`hit_count` 是全体用户的信号）→ 单机算不出来 |
| 3 | **质量把关需要批次过闸门** —— 单条塞进去无法审，也无法回滚 |

> 🔑 **心智模型**：「用户查询 → 全局缓存（**即时**）→ 定期回流 → 版本发布（**固化**）」
> 是一条**流水线**。白哥要的「词库不断完善」**就是这个流水线**，只是「完善」发生在
> **服务端 + 版本发布**层，**不在端侧**。

### 11.4 回流的三个门槛（各有理由，不能省）

| 门槛 | 取值建议 | 🔑 为什么必须有 |
|---|---|---|
| **`hit_count >= K`** | K = 3~5 | **真需求信号**（被 N 个**不同用户**查过）。L0 §479 的 `hit_count` 就是为此设计的 |
| **过校验闸门** | `verify_card_field_consistency.py` | 🔴 **防「把 LLM 的错误固化」** —— 一批 LLM 输出直接进官方库 = 错误变成权威 |
| **单批上限 + 体积预算** | 每次 ≤ N 条 | 🔴 **控制包体积** —— 实测 `word.db` **31.5 MB / 11,523 词 ≈ 2.87 KB/词**；回流 2 万词 ≈ **+57 MB** → 直接影响 App 商店下载量 |

### 11.5 技术前提：回流**复用 `load_llm_results.py`**（不重写）

一条词卡的落库要写 **14 张表**（实测 `INSERT/UPDATE` 目标）：
`word` · `card` · `word_morpheme` · `etymon` · `word_etymon` · `collocation` · `word_collocation` ·
`word_mnemonic_profile` · `mnemonic_type` · `affix` · `word_root` · `cognate_group` · `cognate_group_member` ·
`aggregate_page` · `aggregate_page_word` · `card_extra`（含 `word_form`）

→ 🔑 **回流 = 换一个「输入源」喂给同一套落库链**：
```
现在：LLM 批量结果 (json)  → load_llm_results.py → word.db
回流：generated_card_cache → （同一套落库函数）    → word.db
```
🔑 **而且这与已批的 P0 修复（196 条重生成）共用同一条链 + 同一道闸门** → **一次设计，两处复用**。

### 11.6 🆕 顺带建议：引入 `word_db.version`（把启发式换成确定判断）

现状（`word_db_bootstrap.dart` 第 27–30 行**自己预告过**）：
> 「判断依据是**文件大小** —— 这是**启发式**……若将来真出现〔同大小不同内容〕，
> 应改为「随词库生成的**版本号文件**」（`word_db.version`）。**现在不预先加**（不为假设的复杂度付费）」

🔑 **『现在』这个前提变了**：一旦有回流机制，**词库更新会从「罕见」变成「常态」**
→ 「大小恰好相同」的概率虽仍低，但**每次发版都要赌一次** → 建议**随回流机制一起**加上版本号文件。
（判据：「**判据的前提变了 → 结论要重算**」，同本次 §十③ 的失败路径问题。）

### 11.7 诚实边界（交付时会如实标注）

- ⏳ **回流脚本本次不做**（属第 2 步之后）—— 本报告只把它设计清楚
- ⚠️ **`generated_card_cache` 的 `source` 字段**（L0 已有）建议用于**区分来源**：
  回流进 `word.db` 的卡应能识别出「这批来自 LLM 提升」→ 出问题时能定位
- 🔴 **回流不是「成本必须」** —— 成本靠 ② 全局缓存就够了；③ 的价值是**离线能力 + 延迟**。
  两者的收益要分开评估，不要把它当成「不做成本就压不下去」


---

## 十二、✅ 第 1 步（前半）：契约 v5 → **v6** + 冒烟实测（2026-09-29 02:0x）

### 12.1 契约改动

| 项 | 内容 |
|---|---|
| 版本 | `CONTRACT_VERSION = 'v5'` → **`'v6'`** |
| 新增字段 | **`ipa`**（字符串）· **`definition`**（`{pos, en, zh}`）· **`context`**（单句） |
| 新增规则 | FIELD RULES 追加 **10) ipa** · **11) definition** · **12) context** |
| 长度 | prompt 19,195 → 21,896 字符（**+2,701**）→ 输入 token **2519 → 3221（+28%）** |

**三条 HARD RULE 都直接对应 P0 的真实 bug**（写进 prompt 时附了例子）：
```
10) ipa — 必须完整 /.../，禁止截断
    · 实例：「frying pan 曾得到 /fraɪ/ —— 那是 fry 的音标」
11) definition — en/zh 必须描述**这个**词
    · 实例：「a 的卡曾带着 happy 的释义」
    · 若给的外部释义与拼写无关 → 完全忽略它，自己写
12) context — 必须含该词或其规则变形
    · 实例：「a 的卡曾显示 "I am happy to see you." —— 里面没有 a」
```

### 12.2 冒烟实测（10 条 · 每条对应一个已知 bug）

**10/10 成功 · 0 自动告警 · 成本 ¥0.0644（单条 ¥0.0064）**

| 词 | 现状（错值） | **v6 产出** | 结果 |
|---|---|---|---|
| **`a`** | ipa `/ˈhæpi/` · def 是 happy 的 | `/ə/ (weak) or /eɪ/ (strong)` · `[det] one, any; used before a singular noun` · "She bought **a** book…" | ✅ **完全纠正** |
| **`health care`** | 整卡是 `heal` 的 | `/ˈhelθ keə(r)/` · "the organized provision of medical services" | ✅ **完全纠正** |
| `with` | ipa `/ɪt/` | `/wɪð/ (UK) or /wɪθ/ (US)` | ✅ |
| `first lady` | ipa 是 `first person` 的 | `/ˌfɜːst ˈleɪdi/ (UK) or …(US)` | ✅ |
| `frying pan` | ipa `/fraɪ/`（截断） | `/ˈfraɪɪŋ pæn/` | ✅ |
| `hong kong` | 库里不存在 | `/ˌhɒŋ ˈkɒŋ/` · "a special administrative region of **China**" | ✅ 含主权表述正确 |
| `behavior` · `cannot` | 缺口 | 正常 | ✅ |
| `incredible` · `building` | 对照组 | 正常（**没把好的做坏**） | ✅ |

**两个额外收获**：
1. **`a` 的 ipa 给了 weak/strong 两种形式**（`/ə/ (weak) or /eɪ/ (strong)`）——
   语言上比单一 `/ə/` 更准确，说明模型理解「冠词有弱读强读」这件事
2. 🔑 **「传入坏释义 → LLM 忽略它」机制已验证**：`a` / `health care` 两条
   都传入了**完全错的现状释义**，输出**未被污染** —— 这正是契约第 122 行 + 规则 11 的效果

### 12.3 🔴 发现的联动：落库链**必须同步改**（否则 v6 白跑）

`load_llm_results.py` 现在构造 `card.content` 时：

```python
sections.append({'type': 'definition', 'order': 1, 'pos': s0.get('pos'), ...})   # ← 来自 src_defs
sections.append({'type': 'context', 'text': ex})                                  # ← 来自 src_defs
content = {'front': wl, 'ipa': src_pron.get(wl), ...}                             # ← 来自 coevo.db
```

而 `src_defs` / `src_pron` 的**唯一来源是 `coevo.db`**（**09-29 已清库**，且我上一步已把它改成「明确报错」）。
→ **必须改成从 v6 结果读**：`d['ipa']` / `d['definition']` / `d['context']`。

| 项 | 状态 |
|---|---|
| 改动 | 小（三行取值来源） |
| 但 | 🔴 **不改它 → v6 产出无处落地**（跑完全量也只能干看） |
| 顺带 | 这也**永久绕开了那个不洁数据源** —— P0 根因随之消失 |

### 12.4 第 1 步剩余工作（下一步）

| # | 内容 | 成本 |
|---|---|---|
| 1 | 改 `load_llm_results.py`：`ipa`/`definition`/`context` 改从 v6 结果读 | 0 |
| 2 | 跑**全量 196 条**（`card_field_candidates.json`）→ 出「现状 vs v6」差异报告 | **≈ ¥1.3** |
| 3 | 人眼复核差异（我看 + 抽验给白哥） | 0 |
| 4 | 复核通过 → 写库（**需单独批准**，属改生产资产） | 0 |

🔑 **第 2 步只生成、不写库** —— 写库前必须过人工复核（LLM 产出直接进官方库 = 把错误变权威）。

### 12.5 交付物

| 文件 | 说明 |
|---|---|
| `scripts/coevo_wordlib_contract.py` | **契约 v6**（已备份 v5 到 `E:/CoEvo-backups/`） |
| 🆕 `scripts/smoke_contract.py` | **契约回归测试** —— 每次改 prompt 都该跑（10 条 · ¥0.07） |


---

## 十三、🆕 回答白哥两问：`hit_count` 的边界 + 聚合页能否更新（2026-09-29 02:1x）

> 白哥问：「`hit_count` 能负担去重机制吗？聚合页能更新吗？」
> 🔑 查证时**又搜到一份完整规格**（我此前漏了）：
> **`docs/design/on-demand-generation-server-side-2026-09-26.md`** —— 含 §4.1 **完整九步数据流**、
> §4.3 **竞态处理**、§4.4 版本分发。**这是「LLM 制卡」的正牌规格**，本报告 §十一/§十二 与它高度一致。

### 13.1 Q1：`hit_count` **不管去重**，它管的是「需求信号」

先分层 —— **「去重」其实是四件不同的事**，各有各的承担者：

| 去重场景 | 谁承担 | `hit_count` 的角色 |
|---|---|---|
| ① 不产生重复行（同一词多行） | 🔑 **PK = `spelling`**（L0 §480） | ❌ 不管 |
| ② **并发去重**（10 人同时查同一新词） | 🔑 **词级互斥锁 / in-flight 去重**（规格 §4.3） | ❌ 不管 |
| ③ 跨时间复用 | 🔑 **缓存存在即命中**（`generated_card_cache`） | ❌ 不管 |
| ④ **回流门槛**（该不该进 `word.db`） | ✅ **`hit_count`** | ✅ **这才是它的职责** |

> 📌 规格 §4.3 原文已写：「🔑 这也是「服务端生成」相对「端侧生成」的一个额外收益：
> **去重天然可行**」—— 但它靠的是**互斥锁**，不是 `hit_count`。
> **别把两件事混在一个字段上**（本项目判据：「同一件事的『口径』只能有一处权威」）。

#### 🔴 但 `hit_count` 单独当门槛有**三个缺陷**

| # | 缺陷 | 后果 | 修法 |
|---|---|---|---|
| **1** | 🔴 **没有 user 维度**（L0 §479 只有 `spelling` + `hit_count`） | 同一用户查 100 次 → `hit_count=100` → **被当成「真需求」** | 加 **`distinct_user_count`**（或 `(spelling, user_id)` 去重表）· 门槛用**它**而非 `hit_count` |
| **2** | 🔴 **不区分 `is_own_entry`** | `things` / `thing` 是**两个 spelling** → 各自累加；但 `things` 应作**变形**进 `word_form`，**不是**独立词条 | 用 **v6 的 `is_own_entry` + `derived_from`** 分流（这正是 v6 已有的字段） |
| **3** | 🟠 **不区分「谁贡献的」** | 同一用户的 100 次掩盖了「只有 1 个人需要它」 | 同 ① |

**结论**：`hit_count` **能负担门槛**（它确实反映热度），但**不能负担「去重」**；
且**单独用它做门槛会误判**（缺 user 维度）→ **建议补 `distinct_user_count`**，两个数一起看。

> 🔑 **「去重」的第 5 层（词形归一）也已经有了** ——
> 就是 v6 新增的 `is_own_entry` / `derived_from`。
> 例：用户查 `things` → LLM 输出 `is_own_entry=false, derived_from='thing'`
> → 回流时**只把 `thing` 当词条**，`things` 进 `word_form` 映射。

### 13.2 Q2：聚合页**能更新** —— 机制已实现，但有 **3 个缺口**

#### ✅ 已经有的（`scripts/incremental_clustering.py` · 34 项验收全过）

| 能力 | 位置 | 说明 |
|---|---|---|
| **门槛跨越三情形** | `_sync_root_page:253-266` | `size≥3 且无页` → **新建** · `size<3 且有页` → **删除** · 否则 → **更新成员+计数** |
| 词根按**三元组**匹配 | `match_or_create_root` | `(form,type,origin)` —— 🔴 实测 **116 个同形异源词根**（`man` = 「人」OE 与「停留」Latin 是两条）；只用 `form` 会污染 110 个族（批量版踩过） |
| 成员重建 | `_rebuild_page_members` | `DELETE` + 按序重新 `INSERT` |
| 备份/恢复 | `remove_word` + `_prune_empty_groups` | 含 10 张引用表的级联清理 |

#### 🟢 而且端侧的**成员列表是动态的**（好消息）

实测 `word_query_service.dart`：

| 端侧读什么 | 来源 | 新词回流后 |
|---|---|---|
| **成员列表**（谁在这个族） | `JOIN aggregate_page_word`（:147） | ✅ **自动出现** |
| **卡片入口 / 计数** | `JOIN aggregate_page`（:126） | ✅ **自动更新**（运行时查，不是快照） |

→ 🔑 **老词的卡片不需要改** —— 入口是**运行时 JOIN**，新页/新计数**自动可见**。
（这与 v1 §八「卡片内容固化」并不冲突：固化的是**卡面内容**，入口是**索引**。）

#### 🔴 缺口 A：**content 格式不兼容**（最严重，静默失效）

| 写入方 | content 结构 |
|---|---|
| **`load_llm_results.py:703`**（现网库） | `{'front': label, 'sections': [{'type':'cognate_list', 'source': {...}, 'items': [{word, word_id, gloss}]}]}` |
| **`incremental_clustering.py:316`** | `{'members': [{word, gloss, word_id}]}` 🔴 **完全不同** |

端侧读的是前者（`d['sections'][0]['source']` + `items[].gloss`，:286-299）→
**用增量聚类建的新页，端侧读出来是：`source=null`（大字/语种/含义全空）+ 所有成员无释义**。
⚠️ 而且**不报错** —— 端侧那段有 `try/catch`，坏 JSON **故意静默**（注释：「一条坏数据不该让整个界面渲染不出来」）→ **典型的静默失效**。

#### 🔴 缺口 B：只更新关联表，**不更新 content**

`_rebuild_page_members` 只改 `aggregate_page_word`。
→ 成员**能出现**（JOIN ✅），但 **gloss（成员释义）不会** —— 它存在 `content.sections[0].items[].gloss` 里，而 content **没被重建**。

#### 🟡 缺口 C：**排序口径不同** → 两条路产出不同的库

| 来源 | 排序 |
|---|---|
| `load_llm_results.py:702` | `items.sort(key=lambda x: x['word'])` ← **字母序** |
| `incremental_clustering._rebuild_page_members` | `ORDER BY w.sort_seq` ← **词库序** |

→ 即使格式修好，**成员顺序也不一致** → 产出**不同的库**。
🔑 而这**正是该脚本头部自己担心的事**：「聚类逻辑必须与批量版完全一致，否则**两条路会产出不同的库**」——
**担心对了，但只在「聚类逻辑」上对齐了，没对齐「content 格式与排序」。**

#### 🟡 缺口 D：**只写没接线**

```
grep -rn "incremental_clustering" → 只有：它自己 + 它的验收脚本 + 记忆/文档
```
→ **零生产调用方**。而 `on-demand-generation-server-side` §4.1 步骤 ⑧ 写「已就绪 34 项验收」，
**把「自测通过」当成了「可以直接接」**。

🔑 **新判据（本轮最有价值的一条）**：
> **「组件自测通过」≠「与下游能对接」。**
> 34 项验收验的是**它自己的逻辑**（在真库副本上跑、源库指纹未变）；
> **没有一项验「它写出的内容，下游（端侧）能不能读出来」** ——
> 而这次的两个缺口（格式 / 排序）**全都在这个交界面上**。
> → **验收清单里必须有「下游读取」这一项**（跨端契约）· 与既有判据「**只写不读 = 功能等于没做**」同族。

### 13.3 修订建议（累加到执行计划）

| # | 动作 | 优先级 |
|---|---|---|
| 1 | 🔴 `incremental_clustering` 的 content 生成**改为与 `load_llm_results` 同构**（抽成共享函数，避免第三次分叉） | **高**（不改则新页对端侧不可用） |
| 2 | 🔴 `_rebuild_page_members` 之后**同步重建 content.items**（含 gloss） | **高** |
| 3 | 🟠 成员排序统一（建议**跟随 `load_llm_results` 的定义**，它就是现网口径） | 中 |
| 4 | 🔴 `generated_card_cache` 加 **`distinct_user_count`**（门槛用它，`hit_count` 只作参考） | 中 |
| 5 | 回流时用 **`is_own_entry` / `derived_from`** 做词形归一（own_entry=false → 进 `word_form`） | 中 |
| 6 | ✅ **复用既有的两个验收过的组件**：`scan_compliance.py`（合规 · 29 项）+ `incremental_clustering.py`（聚类 · 34 项） | — |

> ⚠️ **第 1 项的做法**：把「content 结构生成」抽成一个**共享函数**（放 `coevo_wordlib_contract.py` 或新模块），
> **两个脚本都调它** —— 而不是「把 incremental 的格式改成 load 的样子」（那只是把分叉挪了个位置，下次还会分）。
> 🔑 这与「**同一件事的口径只能有一处权威**」是同一条判据。


---

## 十四、✅ 第 1 步（后半）+ 196 条实测（2026-09-29 02:2x ~ 03:2x）

### 14.1 消灭聚合页 content 分叉（§十三 的 4 个缺口）

| 缺口 | 修法 |
|---|---|
| **A** content 格式不兼容 | 🆕 `scripts/aggregate_page_content.py` = **唯一产出点**，两个脚本都调它 |
| **B** 不重建 content | `_rebuild_page_members` 改为**同时重建 content**（含 `items[].gloss`） |
| **C** 排序口径不同 | 统一为**字母序**（现网 1,777 页实测 100% 是字母序） |
| **D** 只写没接线 | 接线（+ 加 `verify_aggregate_page_parity.py` 验收） |
| 🆕 **第 4 个分叉** | `aggregate_page_word.ord` —— 一个用字母序、一个用 `sort_seq` → 统一 |

**修法是「消灭分叉」而不是「挪分叉」**：
⚠️ 不是「把 incremental 的格式改成 load 的样子」（那只是把分叉重写一次，下次还会分）；
正解是**双方都调同一模块**。

**验证（这是「两条路产出同一个库」的最强证据）**：

| 验证 | 结果 |
|---|---|
| 全量 **1,777 页重建后与现网逐字节一致** | ✅ |
| 下游完整可读（`front`/`source`/`glosses`） | ✅ 1777/1777 |
| `ord` 顺序 == `content.items` 顺序 | ✅ 每页 |
| 既有 `verify_incremental_clustering`（34 项） | ✅ 全过（未破坏） |
| **证伪 2 次**（逐条实测报红） | ✅ 改回旧格式 → 红 30/30 · 去掉排序 → 红 40/40 |

🔑 顺带修一个**验证脚本自身的 bug**：**同一 cursor 嵌套查询会打断外层游标** ——
第一次测 `etymon_label` 只跑 1 行就结束，误得「一致 1/1」；换 cursor 后 **1181/1181**。

### 14.2 落库链三字段改由契约 v6 自产

`load_llm_results.py` 的 `ipa` / `definition` / `context` 原先从 `coevo.db` 读（该库已退役）→
**改为优先取契约 v6 产出**，保留回退链：
```
v6 结果  →  现网释义（若库仍在）  →  缺失
```
🔑 **三种结局都进 `src_stats` 并在结尾打印** —— 不然只看到「卡建好了」，
看不出**有多少张是降级的**（＝静默失败）。

### 14.3 196 条实测（契约 v6 · `scripts/gen_card_field_fixes.py`）

**成本 ¥1.2807**（196 条 · 单条 ¥0.0065）· 耗时 **29s** · **0 失败** · 0 限流迹象

| 档位 | 条数 |
|---|---:|
| **🔴 建议要修（并集）** | **136** |
| — 其中 ipa 与 v6 不同 | 108 |
| — 其中例句不含该词 | 64 |
| — 其中 ipa 残缺/截断（硬证据） | 17 |
| ✅ 完全无问题（信号**误报**） | **60** |

**按信号看（命中率 = 判据精确率）**：

| 信号 | 命中率 |
|---|---|
| `S1` · `S2` · `S2+S4` · `S3b+S4` · `S2+S3b` · `S2+S3b+S4` | **100%** |
| `S4`（例句不含该词） | **95%** |
| `S3a`（短语 ipa 撞车） | **93%** |
| `S3b`（单词 ipa 撞车） | 🟠 **30%** ← 因为它抓的同 ipa 里有很多**真同音词** |

### 14.4 🔑 三个判据教训（都是「判据比实现更危险」）

**① 「与原值不同」不能判「错」—— 要先看字段是「封闭」还是「开放式」**

第一版用「与现状不同」判错 → 得到 **196/196 全部不同** 的**假象**。
`context`（例句）是**开放式生成**：同一个词有无穷多个正确例句，
**换个说法不等于原句错**（实测 151 条的现状例句与 v6 例句**都含该词、都正确**）。

| 字段 | 性质 | 「现状错」的判据 |
|---|---|---|
| `ipa` | **封闭** | 格式残缺 / 多词未覆盖全 / 与 v6 不同（有一方错） |
| `pos` | **近似封闭** | 与 v6 不同（归一化去方括号后） |
| `definition` | **开放式** | 现状**为空**才是硬证据 |
| `context` | **开放式** | **不含该词**（词形还原后）才是硬证据 |

**② 「例句是否含该词」必须用 `word_form` 表还原，不能用「词干截断」**
后者会把 `brought`(bring) · `leaves`(leaf) · `shrank`(shrink) · `t-shirt`（连字符被分词切开）
**全部误判为「不含」** → 第一版因此把 v6 的 52 条合法 ipa、8 条正确例句**误报为违规**。

**③ 机械判据对 `S3a`/`S3b` 是「盲」的 —— 这不是「信号错了」**
`air conditioning` 的现状 ipa 是 `/ˈɛr fɔːrs/`（= `air force` 的）——
**两段、格式合法**，机械判据（段数 ≥ 词数）**完全通过**。
要知道它是**另一个词的音标**，必须**懂语义** —— 这正是 LLM 复核不可替代之处。

> 📌 抽验 S3a 的 8 条：**8/8 全部被 v6 纠正**（`air conditioning`→`/ˈeə kənˌdɪʃənɪŋ/` ·
> `carbon footprint`→`/ˈkɑːbən ˈfʊtprɪnt/` · `first lady`→`/ˌfɜːst ˈleɪdi/` · `bus station`→`/ˈbʌs ˌsteɪʃn/` …）
> → **S3a 判据完全正确**，只是本表的硬证据判据抓不到那一类。

### 14.5 v6 产出质量自查

| 检查 | 结果 |
|---|---|
| v6 产出的 `ipa` 残缺 / 未覆盖全词组 | **0** ✅ |
| v6 产出的例句「不含该词」 | 少量（**全为判据残余误差**：缩写带点 `a.m.`/`Dr.` · 不规则变形） |

### 14.6 🆕 P0 修复的关键样本（v6 实测纠正）

| 词 | 现状（错） | **v6** |
|---|---|---|
| `a` | ipa `/ˈhæpi/` · def 是 happy 的 · 例句 "I am happy…" | `/ə/ (weak) or /eɪ/ (strong)` · `[det] one, some, any` · "She bought a new car yesterday." |
| `health care` | ipa `/hiːl/` · def 是 heal 的 | `/ˈhelθ keər/ (UK) or /ˈhelθ ker/ (US)` · "the organized provision of medical services" |
| `with` | ipa `/ɪt/` | `/wɪð/ (UK) or /wɪθ/ (US)` |
| `frying pan` | ipa `/fraɪ/` · def 是 fry 的 | `/ˈfraɪɪŋ pæn/` · "a shallow pan used for frying food" |
| `first lady` | ipa 是 `first person` 的 | `/ˌfɜːst ˈleɪdi/ (UK) or /ˌfɜːrst ˈleɪdi/ (US)` |
| `carbon footprint` | ipa 是 `carbon monoxide` 的 | `/ˈkɑːbən ˈfʊtprɪnt/` |

### 14.7 交付物

| 文件 | 说明 |
|---|---|
| 🆕 `scripts/aggregate_page_content.py` | 聚合页 content/label 的**唯一产出点**（含 `read_back` = 端侧读取逻辑） |
| 🆕 `scripts/verify_aggregate_page_parity.py` | 跨路一致性 + **下游可读性**验收（12 项） |
| 🆕 `scripts/gen_card_field_fixes.py` | 196 条 LLM 复核（`--report-only` 可重出报告，不重跑） |
| 🆕 `data/reports/card_field_fixes-2026-09-29.md` | 人眼可读的差异报告（159 行） |
| 🆕 `data/curriculum/prebuilt/card_field_fixes.json` | 完整结果（供后续写库） |
| 📝 `scripts/load_llm_results.py` | 三字段改从 v6 读（+ 来源统计 + 回退链） |
| 📝 `scripts/incremental_clustering.py` | content/label/排序全部改调共享模块 |

### 14.8 待白哥定

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | **136 条是否写库**（`word.db`）？ | 建议**先看报告 §四的明细**（或抽验）再定；写库属改生产资产，需单独批准 |
| 2 | `S3b` 里那 55 条「疑似无误报」怎么处理？ | 建议**一起修**（它们与真错同 ipa，人眼难分；LLM 已给新值） |
| 3 | 是否**先修 17 条硬错**（ipa 残缺/截断）再评估其余？ | 可 —— 成本极低、收益明确（这是**确定错**的那批） |


*本文为调查产出，**未改动任何代码/数据**。跑法：本报告的每条数字均可由 `grep`/`sqlite3` 在本机复现。*

---

## 十五、✅ 修卡片字段（2026-09-29 03:0x）—— 白哥三条指令的执行 + 一次**判据修正**

> 白哥：「1、136 条写库；2、55 条疑似（同 ipa 但可能是真同音词）一起修；3、先修 17 条硬错、再评估其余」

### 15.1 🔴 先说结论：**「136」经不起复核，实际写 68**

动手前我把「该写哪些字段」逐条复核了一遍，发现**判据本身有两处系统性误差**，
而且 `word_form` 表的作用被高估了。修正后：

| | 原口径 | 复核后 |
|---|---:|---:|
| 建议写入 | 136 条 | **68 条卡 / 79 个字段** |
| — `ipa` | 108 | **60** |
| — `context`（例句） | 64（含硬证据） | **18** |
| — `definition`（释义） | 不写（开放式） | **1**（唯一整卡污染） |

> 🔑 **56 条的差不是「少做」，是「原先判错了」** —— 它们的现状**本来就是对的**。

### 15.2 复核发现的三处问题（都带证据）

**① `word_form` 表只收「规则变形」 —— 拿它判「例句是否含该词」会大面积误报**

| base | 表里有的 | **表里没有的**（实测） |
|---|---|---|
| `bury` | burial / buries / burying | 🔴 **buried** |
| `leaf` | leafed / leafing / leafs | 🔴 **leaves** |
| `shrink` | shrinked / shrinking / shrinks | 🔴 **shrank** |

→ 「64 条例句不含该词」里，**55 条其实是合法的**（`buried`(bury) · `leaves`(leaf) ·
`shrank`(shrink) · `leapt`(leap) · `freshmen` · `grandchildren` · `civilisation` ·
`crystallized` · `outgrew` · `underwent` · `withdrew` · `handloom`(loom) ·
`watchmaker`(maker) · `chemotherapy`(therapy) …）。
最刺眼的一条：`dissatisfy` 现状与 v6 给的是**同一句** —— 原判据说它「不含该词」。

**② `definition` 是开放式字段 —— 「与 v6 不同」绝大多数是措辞差异，不是错**

实测 `bulletin`：
- 现状 `A short official notice or report giving news or information to many people.`
- v6 　`a short official notice or news report`
→ **现状更详细**。按「不同就写」会**净损失信息**（原口径有 92 条属此类）。

**③ v6 也会错 —— 不能无脑照抄**

`ms.`（Ms.，女士）现状 `/mɪz/` **是对的**，v6 给了 `/ˌem ˈes/`（那是 **M.S.** 理学硕士）。
→ 已进 `IPA_V6_WRONG` 例外表。同类的还有 `lied`（现状 `(noun) /liːd/; (verb) /laɪd/`
比 v6 的 `'/liːd/'` **更全**）。

### 15.3 修正后的写库判据（已固化在 `gen_card_field_fixes.py`）

| 字段 | 性质 | 允许覆盖的前提 |
|---|---|---|
| `ipa` | **封闭** | ① 格式硬证据（残缺 / 未覆盖全词组 / 疑截断 S2）② **归一化后读法确实不同**（截断 / 是别的词的音标） |
| `context` | 开放式 | 例句**不含该词**（自造变形 + 不规则/变体补充 + 复合词判定） |
| `definition` | 开放式 | **仅**：现状为空，或已证实**整卡污染** |

🔑 **`ipa` 为什么要「归一化后比读法」**：`/ˈmeɪkər/` vs `/ˈmeɪkə/ (UK) or /ˈmeɪkər/ (US)`
只是**标注差异**；34 条「现状完整、无撞车」的差异里绝大多数属此类，写了纯属churn。

### 15.4 整卡污染：只有 1 条，但它最严重

| 词 | 内容来自 | 现状 ipa | 现状例句 |
|---|---|---|---|
| `a` | **`happy`** | `/ˈhæpi/` | `I am happy to see you.` |

🔑 **怎么机械判出来**的：**例句不含本词，却含它的撞车对端词**。
（`a` 的 ipa 撞上 `happy` → 查它的例句含 `happy` 而不含 `a` → 内容来自 happy）
→ `a` 的 ipa / 释义 / 例句**三段一起换**（否则会留下别人的释义）。

### 15.5 三批执行与验证

| 批次 | 内容 | 结果 |
|---|---|---|
| 第 1 批 | **26 条 ipa 硬错**（残缺 7 + 未覆盖 10 + 疑截断 9） | ✅ 写库 + 读回断言通过 |
| 第 2 批 | **68 条**（含上批，幂等） | ✅ 写库 + 读回断言通过 |
| 收尾 | **刷新受影响聚合页 1 张**（页 733 的 `a` 释义） | ✅ 刷新 + `read_back` 通过 |

**复跑验证（全部可复现）**：

| 校验 | 修复前 | 修复后 |
|---|---|---|
| `verify_card_field_consistency` S1 / S2 | 7 / 18 | **0 / 0** |
| 同上 S3a（短语撞车） | 42 | **0** |
| 同上命中合计 | 175（1.5%） | **111（1.0%）** |
| `verify_card_structure` | 13/13 | **13/13** |
| `verify_aggregate_page_parity` | 12/12 | **12/12**（1777/1777 可读） |
| `PRAGMA integrity_check` / 卡数 | ok / 11,523 | **ok / 11,523**（未增未减） |

🔑 **`S3a → 0` 是关键证据**：它说明「撞车」的对端词（`white` `with` `meet` `diffusion`
`police officer` `swimming costume` …）**正是被修的那一方**，修完撞车自然消失。

### 15.6 ✅ 55 条 S3b 的结论：**不需要改**（白哥问的就是这个）

55 条 = 信号 `S3b`、且**不在**建议修并集里的那些。逐条看下来：

| 类型 | 例 | 处理 |
|---|---|---|
| **真同音词**（两边都対） | `right`/`write`/`rite`/`wright` · `check`/`cheque` · `gene`/`jean` · `sail`/`sale` · `wait`/`weight` | **不改**（v6 给的 ipa 与现状**完全一致**） |
| **假撞车**（对端词是坏的） | `i`/`eye` ←`white` · `it` ←`with` · `mi` ←`meet` · `die`/`dye` ←`diffusion` · `heel` ←`health care` · `pah` ←`pasha` | **随第 2 批自动解决**（坏的是对端，已在写入清单里） |

📌 所以「55 条一起修」的执行结果是：**该修的对端已修完；它们本身一个字都不用动**。
证据：复跑后 S3a = 0，剩余同-ipa 组（266 组）全是**真同音词 / 英美拼写对 / 缩写对**
（`organise`-`organize` · `mr`-`mr.` · `police`-…见下）。

### 15.7 🔴🔴 新发现：信号有一处**结构性盲区** —— 「基词拿到了自己词组的音标」

复核时发现 **20 对**这一类，**全部没进 196 候选**：

| 基词 | 拿到的 ipa 其实是 | | 基词 | 拿到的 ipa 其实是 |
|---|---|---|---|---|
| `police` | `police station` 的 | | `stock` | `stock market` 的 |
| `bus` | `bus stop` 的 | | `swimming` | `swimming pool` 的 |
| `credit` | `credit card` 的 | | `chat` | `chat show` 的 |
| `primary` | `primary school` 的 | | `web` | `web page` 的 |
| `exchange` | `exchange rate` 的 | | `text` | `text message` 的 |
| `identity` | `identity card` 的 | | `traffic` | `traffic light` 的 |
| `definite` | `definite article` 的 | | `navy` | `navy blue` 的 |
| `modal` | `modal verb` 的 | | `prime` | `prime minister` 的 |
| `rush` | `rush hour` 的 | | `vice` | `vice president` 的 |
| `owing` | `owing to` 的 | | `virtual` | `virtual reality` 的 |

**为什么漏了**：`S3a/S3b` 有一道「字形相似就放过」的守卫（为 `en`/`ellen` 加的），
而「基词 ⊂ 词组」正好整类踩在守卫上。**这是盲区，不是信号错。**
同类盲区另有约 6 条（`bullet` `tape` `logo` `tart` `tropical` `consideration` …）。

> 🔑 **反直觉之处**：这一类的**危害比 S3a 更大** —— 它把**词组的长音标**挂在**基词**上，
> 用户查 `police` 会看到 `/pəˈliːs ˌsteɪʃən/`。**且当前信号完全看不见它。**

### 15.8 交付

| 文件 | 说明 |
|---|---|
| 🆕 `scripts/apply_card_field_fixes.py` | 写库脚本：`--tier/--fields/--only` · **默认 dry-run** · 自动备份 · 事务 · **读回断言** · 断言「非目标字段逐字节未变」 |
| 🆕 `scripts/refresh_aggregate_pages.py` | 刷新受影响聚合页的 `items[].gloss`；断言「差异只在 gloss」 |
| 📝 `scripts/gen_card_field_fixes.py` | 判据修正：自造变形 + 不规则/变体补充 + 复合词判定 · `ipa_core` 归一化 · `write_fields` · `IPA_V6_WRONG` · 整卡污染识别 |
| 📝 `data/reports/card_field_fixes-2026-09-29.md` | 重出（§四 变「建议写入 68 条」+ 新增判据误差与污染章节） |
| 📝 `data/word.db` | 68 条卡 · 79 个字段 · 1 张聚合页（体积**未变**，33,083,392 B） |
| 备份 | `data/backups/word.db.bak-cardfix-20260929-024818`（第 1 批）· `…-024832`（第 2 批） |

### 15.9 下一批（建议，未做）

| # | 事项 | 量 |
|---|---|---|
| 1 | **「基词拿到词组音标」盲区扫描**（§15.7）—— 需新信号：*ipa 与该词的某个词组条目完全相同* | 20 + ~6 |
| 2 | `S4` 剩余 55 条：逐条看是否还有真错（判据已升级，需要人眼/LLM 复核一次） | 55 |
| 3 | 把 `word_form` 表补齐不规则变形（**它同时影响端侧划词查词**） | 待估 |
| 4 | 剩余的 `pos` 差异（近似封闭，需人眼定谁错） | 待估 |

---

## 十六、🔴 信号盲区扫描：`similar_word` 的守卫整类放过了什么（2026-09-29 03:4x）

> 白哥：「扫描」—— 即 §15.7 留的第 1 项。**本轮只扫不改**。

### 16.1 根因：守卫用「前缀/后缀」当「字形相似」，而真错正好全踩在这两个分支上

```python
# scripts/verify_card_field_consistency.py · similar_word()
if x.startswith(y) or y.startswith(x):  return True   # ← 整类放过「基词 ⊂ 词组」
if x.endswith(y)   or y.endswith(x):    return True   # ← 整类放过「派生词 ⊂ 词干」
```

这两个分支本意是放过 `be`/`bee` 这类**真同音近形词**（`it`/`with` 那次的教训）——
但它们同时**整类放过**了两种**真错**。实测：**103 对，全部没进 196 候选**。

### 16.2 三种形态与规模

| 档 | 判据 | 对数 | 条数 | 强度 |
|---|---|---:|---:|---|
| **S5a** | 一 word 一 phrase · word ⊂ phrase 的**词段** · 读音相同 | 25 | **25** | 🔴 **硬证据** |
| **S5b** | 两 word · 互为前缀/后缀 · 长度差 ≥ 2 · 读音相同 | 14 | 27 | 🟠 需复核 |
| **S5c** | 两 word · 互为前缀/后缀 · 长度差 = 1 · 读音相同 | 64 | 124 | 🟡 需复核 |

### 16.3 🔴 S5a 25 条：**不依赖 LLM，逻辑上必然错**

| 基词（**错**） | 现状 ipa = 哪个词组的 | | 基词（**错**） | 现状 ipa = 哪个词组的 |
|---|---|---|---|---|
| `bus` | `bus stop` | | `primary` | `primary school` |
| `capital` 🆕 | `capital letter` | | `prime` | `prime minister` |
| `chat` | `chat show` | | `rush` | `rush hour` |
| `credit` | `credit card` | | `secondary` 🆕 | `secondary school` |
| `debit` 🆕 | `debit card` | | `stock` | `stock market` |
| `definite` | `definite article` | | `swimming` | `swimming pool` |
| `exchange` | `exchange rate` | | `text` | `text message` |
| `identity` | `identity card` | | `traffic` | `traffic light` |
| `modal` | `modal verb` | | `vice` | `vice president` |
| `navy` | `navy blue` | | `virtual` | `virtual reality` |
| `owing` | `owing to` | | `web` | `web page` |
| `police` | `police station` | | `cd` | `cd player` |
| `id` | `id card` | | | |

（🆕 = 本次新发现，上一轮没进 196 —— 因为它们的词组**已被修好**，导致不再「撞车」：
`capital` 还挂着 `capital letter` 的**旧**音标，而 `capital letter` 自己已被修成 `/ˌkæpɪtl ˈletə/ (UK)...`，
**读音相同但字符串不同** → 用原始字符串分组就配不上对。）

🔑 **为什么是硬证据而非启发式**：设 `w ⊂ p`（`bus` ⊂ `bus stop`），则 `p` 的完整音标
**必然包含** `w` 的音标（`/ˈbʌs ˌstɒp/` ⊃ `/bʌs/`）。所以「`w` 的 ipa 与 `p` 的 ipa
**完全相同**」在数学上不可能同时成立 → **必有 `w` 错**。
→ 25 条**不需要跑 LLM**，只需让 v6 给一次正确 ipa（≈ ¥0.16）。

**交叉验证**：另用一条**独立**判据（*单词却有多段音标 + 音标外无解释文字*）扫得 145 条，
剥掉合法形态（连字符词 28 · 缩写/专名 43 · 多读法 48）后剩 26 条 ——
与 S5a 的 25 条**只差 3 条**，且这 3 条（`armchair` `/ˈɑːm tʃɛər/` · `sonofabitch` ·
`ne`）都是**合法**的复合词/逐字母读 → **S5a 无漏报**。

### 16.4 🟠🟡 S5b/S5c：88 对，需 LLM（≈ ¥0.73）

| 信号 | 需复核 | 已知正确（已标「大概率本就正确」） |
|---|---:|---:|
| S5b | 24 条 | 3 条（`gram`/`gramme` 等英美变体） |
| S5c | 92 条 | 32 条（`nazi`/`nazis` 屈折 · `dr`/`dr.` 缩写点 · `enrol`/`enroll` 变体） |
| **合计** | **113 条** | 35 条 |

**S5b 里的真错样本**（人工核过）：
- `bullet` `/bʊl/` ← `bull` 的（应 `/ˈbʊlɪt/`）
- `consider` `/kənˌsɪdəˈreɪʃən/` ← `consideration` 的（应 `/kənˈsɪdə(r)/`）
- `tropical` `/ˈtrɒpɪk/` ← `tropic` 的（应 `/ˈtrɒpɪkl/`）
- `marvel` `/mɑː/` ← `ma` 的 · `tartuffe` `/tɑːr/` ← `tar` 的 · `yugoslavia` `/ˈjuːɡəʊslɑːv/` ← `yugoslav` 的

**S5c 里的真错样本**：`eat` `/æt/` ← `at` 的（应 `/iːt/`）· `tape` `/tap/` ← `tap` 的（应 `/teɪp/`）
· `logo` `/lɒɡ/` ← `log` 的 · `israeli` `/ˈɪzreɪl/` ← `israel` 的

🔴 **S5b 不能预设「长词错」**（实测反例）：`bullet` 错（长词错），但
`consider` **也错**（**短词**拿到了长词的音标）—— 方向相反。所以 S5b/S5c 只报「这一对可疑」，方向留给人眼/LLM。

### 16.5 🔴 本轮连踩四个判据坑（每个都导致一次错数）

| # | 坑 | 后果 | 正解 |
|---|---|---|---|
| 1 | `len(ipa_segments(...))` 当「覆盖了几个词」 | `/pəˈliːs ˌsteɪʃən/` 只是**一段**（一对斜杠）→ 判「只覆盖 1 词」→ **S5a 全漏，报 0**（应 25） | 新增 `ipa_spoken_segments()`：**按空白分词** |
| 2 | 把 `+'e'` 当 benign（「词尾差异」） | 词尾 `e` 是 **magic e** —— `tap` `/tæp/` → `tape` `/teɪp/`（元音**变了**）→ `tap`/`tape` 被误标「大概率本就正确」，**正好放过真错** | 移除该规则；`blond`/`blonde` 与 `tape` 机械分不开 → **统一归「需复核」**，宁可多花几毛 |
| 3 | 分组键用**原始字符串** | `capital` 的 `/ˈkæpɪtl ˈlɛtər/` 与已修的 `capital letter` `/ˌkæpɪtl ˈletə/ (UK)...` **读音同、字符串不同** → 配不上对 → **漏 3 条** | S5a 改用 `ipa_core_set()` 归一化分组 |
| 4 | 同一套归一化也用在 word-word 上 | 过度配对 → S5b/S5c **28/128 → 312/338**（`ipa_core_set` 删弱读 `ə`、去词尾 `r`，把本该不同的读音并到一起） | **各取所需**：跨「已修/未修」的写法差异用归一化；同类型词之间用原始串 |

🔑 四个坑的共同模式：**判据「看起来对」但口径差一层** ——
段数 vs 词数 · 拼写 vs 读音 · 原始串 vs 归一化 · 一个信号 vs 两种用途。
**都是靠「与实际数据对不上」才暴露的**（`S5a=0` 是第一个信号，与人工探测的 22 条矛盾）。

### 16.6 交付与下一批

| 项 | 内容 |
|---|---|
| 📝 `scripts/verify_card_field_consistency.py` | 🆕 信号 **S5a/S5b/S5c** + `ipa_core_set` / `ipa_spoken_segments` / `_s5_tier` / `_benign_pair`；头部信号表更新为 8 类；**如实标注 S5b/S5c 是已知边界** |
| 🆕 `data/curriculum/prebuilt/card_field_candidates_s5.json` | 275 条候选（含 S5 + 其余信号） |
| 规模 | S5 共 **103 对 / 176 条**（S5a 25 · S5b 27 · S5c 124） |

| # | 下一批 | 量 | 成本 |
|---|---|---|---|
| 1 | **S5a 25 条直接修**（硬证据，无需 LLM 判定，只需 v6 出正确 ipa） | 25 | ≈ ¥0.16 |
| 2 | **S5b/S5c 跑 LLM 复核**（113 条） | 113 | ≈ ¥0.73 |
| 3 | `S3b` 剩余 62 条 + `S4` 剩余 55 条复核 | 117 | ≈ ¥0.76 |
| 4 | `word_form` 补不规则变形（**同时影响端侧划词查词**） | 待估 | — |

*本轮**只扫描、未改任何数据**。`word.db` 未触碰。*

---

## 十七、✅ 执行 §十六 的四项（2026-09-29 08:0x）

> 白哥：「执行」

### 17.1 实际执行方式（与预案的一处不同）

| # | 原计划 | 实际做法 | 成本 |
|---|---|---|---|
| ① | S5a 25 条「直接修」（硬证据，不需 LLM 判定） | ❌ 但仍**需要 v6 出正确 ipa** → 与 ② **合并成一次调用**（161 条） | — |
| ② | S5b/S5c 113 条跑 LLM | ✅ 同上 | **¥1.0412**（161 条 · 34s · 0 失败） |
| ③ | `S3b` 62 + `S4` 55 复核 | ✅ **已在 196 条那批里**（无需重跑）→ 只做「用升级后的判据重判」 | ¥0 |
| ④ | `word_form` 补不规则变形 | ✅ 新增 `fill_word_form_irregular.py` | ¥0 |

🔑 **去重先行**：S5 候选 172 条里 **11 条已在 196 内**（`dr.` `il` `mr.` `mrs.` `ms.` `pah` `par` `right` `rite` `wright` `write`）
→ 实跑 **161 条**。**但不采用**「跳过已标『大概率本就正确』的 29 条」——
`_benign_pair` 用了较激进的归一化折叠，多花 **¥0.19** 把启发式依赖换掉。

### 17.2 结果：S5a **25/25 全部命中**，写库 47 条

| 档 | 条数 | 写入 |
|---|---:|---:|
| S5a（基词 ⊂ 词组） | 25 | **25**（100%） |
| S5b/S5c（需复核） | 136 | 21 |
| **合计** | **161** | **47**（ipa 46 + context 1） |

**未写的 115 条全部是「v6 与现状读音一致」**（真同音词/英美变体）→ **0 条需要解释的例外** ✓

**S5a 逐条（现状 → 写入）**：

| 词 | 现状（错的） | 改为 | | 词 | 现状 | 改为 |
|---|---|---|---|---|---|---|
| `bus` | `/ˈbʌs ˌstɒp/` | `/bʌs/` | | `primary` | `/ˈpraɪməri skuːl/` | `/ˈpraɪməri/ (UK)...` |
| `capital` | `/ˈkæpɪtl ˈlɛtər/` | `/ˈkæpɪtl/` | | `prime` | `/ˌpraɪm ˈmɪnɪstə(r)/` | `/praɪm/` |
| `cd` | `/siː ˈdiː ˌpleɪər/` | `/ˌsiː ˈdiː/` | | `rush` | `/ˈrʌʃ ˌaʊə/` | `/rʌʃ/` |
| `chat` | `/ˈtʃæt ʃəʊ/` | `/tʃæt/` | | `secondary` | `/ˈsɛkəndɛri skuːl/` | `/ˈsekəndri/ (UK)...` |
| `credit` | `/ˈkred.ɪt ˌkɑːrd/` | `/ˈkredɪt/` | | `stock` | `/ˈstɒk ˌmɑːkɪt/` | `/stɒk/ (UK)...` |
| `debit` | `/ˈdebɪt kɑːrd/` | `/ˈdebɪt/` | | `swimming` | `/ˈswɪmɪŋ puːl/` | `/ˈswɪmɪŋ/` |
| `definite` | `/ˈdɛfɪnɪt ˈɑːrtɪkl/` | `/ˈdefɪnət/` | | `text` | `/ˈtekst ˌmesɪdʒ/` | `/tekst/` |
| `exchange` | `/ɪksˈtʃeɪndʒ reɪt/` | `/ɪksˈtʃeɪndʒ/` | | `traffic` | `/ˈtræfɪk ˌlaɪt/` | `/ˈtræfɪk/` |
| `id` | `/ˌaɪ ˈdiː ˌkɑːd/` | `/ˌaɪ ˈdiː/` | | `vice` | `/ˌvaɪs ˈprezɪdənt/` | `/vaɪs/` |
| `identity` | `/aɪˈdentəti kɑːd/` | `/aɪˈdentəti/` | | `virtual` | `/ˌvɜːtʃuəl riˈæləti/` | `/ˈvɜːtʃuəl/` |
| `modal` | `/ˈməʊdəl vɜːb/` | `/ˈməʊdl/ (UK)...` | | `web` | `/ˈwɛb peɪdʒ/` | `/web/` |
| `navy` | `/ˌneɪvi ˈbluː/` | `/ˈneɪvi/` | | `owing` | `/ˈəʊɪŋ tuː/` | `/ˈəʊɪŋ/ (UK)...` |

**S5b/S5c 抓到的真错**（人工核过）：`bullet`←`bull` · `consider`←`consideration`（**短词**错，方向与 `bullet` 相反）
· `tropical`←`tropic` · `eat`←`at` · `tape`←`tap` · `logo`←`log` · `israeli`←`israel`
· `marvel`←`ma` · `tartuffe`←`tar` · `yugoslavia`←`yugoslav` · `shall`←`hall` · `th`←`path`
· `nazis`/`bristles`/`whigs`（复数拿了单数音标）· `paso`←`pa` · `tart`←`tar` · `en`←`ellen`

### 17.3 🔴🔴 本轮最重要的发现：**交付物同步遗漏**（上一轮的漏做）

排查时发现 **`app/assets/word.db` 是打包进 App 的独立副本**，
而**历史上每次改 `data/word.db` 都会同步它**（`d419fce` · `ccefb6a` · `b495718` · `7e88b84` 均如此）
—— **但我上一轮（`93e2016`）漏了**。

**实测证据**：两份库 `card.content_hash` 差异 **恰好 115 条** = 68（上轮）+ 47（本轮）✓

→ 后果：**上一轮修的 68 条卡片，用户在 App 里看不到**（只有开发库是好的）。
→ 已同步，两份库 `PRAGMA integrity_check` = ok · `content_hash` 集合完全相同 ✓

🔑 **判据**：**「改了源数据」≠「交付物已更新」** ——
   一份数据若存在「源 + 打包副本」两处，改完源必须问一句 **「现在还有谁拿着它的旧拷贝」**。
   （同 `MEMORY.md` 的「『写了 A 端』≠『B 端会显示』」，但这次是**文件级**的副本。）

### 17.4 `word_form` 补不规则变形：+78 行

🆕 `scripts/fill_word_form_irregular.py` —— 自建**人工核对的不规则表**（235 词）。

**为什么不能用现成的**：
- `build_word_form.py` 的 `IRREGULAR` 只有 **130 词**，且 **`bury`/`leaf`/`shrink` 都不在**
- 旧 `word_form.json`（36,856 条）是**纯规则穷举** → ① **不含任何不规则变形**（`shrank`/`underwent`/`withdrew` 都不在，正是要补的那批）② 大量规则误加（`abandoneded` · `abilitying`）

**四条判据**：`base` 在 word 表 · `form` 不在 word 表（否则端侧第一步就命中，是死数据）
· `form` 不在 word_form 表 · `form != base`

🔴 **去掉了「form 在 cefr_catalog 里」这层过滤**（第一版用了，是错的）：
CEFR-J 是**学习词表**，既不收英式变体（`learnt` `spelt` `spilt` `labelling`）也不收常见变形（`overthrew` `woken` `shrunk`）
—— **而我们的内容源含 BBC（英式拼写）**。按它过滤会**挡掉真变形**（实测挡 46 条）。
（`fill_word_form_gap.py` 当年需要它，是因为那个源是规则穷举会造垃圾；本脚本的源是人工表，无此风险。）

**结果**：24,062 → **24,140 行**（+78）· 幂等（重跑 0 条）· `integrity_check` ok

**实测收益**（33 个样本）：**0/33 → 12/33** 命中。
另有 **S4 从 55 → 43** —— 补了不规则变形后，12 条「例句不含该词」的**误判自动消失**（交叉验证 ✓）。

### 17.5 🔴 两个如实报告的遗留（未动）

**① `word_form` 里已有可疑映射**（本轮范围外，`form` 已在表中故被跳过）：

| form | 现有映射 | 问题 |
|---|---|---|
| `buried` | → **`buri`**（rule=past） | `buri` 是独立词条；`buried` 更常是 `bury` 的过去式 |
| `leaves` | → **`leave`**（rule=plural） | 口径不一致：`leave` 是**动词**，其复数不该叫 plural；`leaf` 的复数无人映射 |

⚠️ 且端侧 `LIMIT 1` 无序 → 一个 form 有多个 base 时**取哪个不确定**（架构限制）。

**② 规则变形缺口 199 条 —— 建议不做**：
按词性生成规则屈折 + 语料实证后仍有 199 条缺口，但含 **`bester`**（`best` 的比较级 —— 错）、
**`acoustics`**（`acoustic` 的复数 —— 错，它是独立名词「声学」）等**误判** →
要补就得再写一套规则 + 门控 + 人工核验，而收益只是「199 个词形少走一次 LLM 兜底」。
**性价比低，建议不补**（不规则变形才是用户真的猜不出来的那批，已补完）。

### 17.6 全量验证（全部可复跑）

| 校验 | 修复前 | 修复后 |
|---|---|---|
| S1 / S2 / S3a | 0 / 0 / 0 | **0 / 0 / 0** |
| **S5a**（基词 ⊂ 词组） | **22** | **0** ✅ |
| S5b / S5c | 28 / 128 | **6 / 106**（余者全为真同音词） |
| S4 | 55 | **43** |
| 命中合计 | 275（2.4%） | **200（1.7%）** |
| 结构 13 项 / 聚合页 12 项 | 13/13 · 12/12 | **13/13 · 12/12** |
| 聚合页连带刷新 | — | **0 页**（本次未改 `definition`，符合预期） |
| `word.db` / `app/assets/word.db` | 不一致（差 115 条） | **完全一致** ✓ |
| integrity / fk / 卡数 | ok / [] / 11,523 | **ok / [] / 11,523** |

### 17.7 交付

| 文件 | 说明 |
|---|---|
| 📝 `scripts/gen_card_field_fixes.py` | 🆕 `--candidates` / `--out` / `--out-report`（让**任意候选清单**走同一条链）；标注 `_IRREGULAR` 与 `word_form` 表的关系（**是兜底不是分叉**） |
| 📝 `scripts/apply_card_field_fixes.py` | 🆕 `--fixes`（多结果文件合并去重）；🔴 **改用「库里的当前值」重算**（而非文件里的过时快照）→ 天然幂等，且报出的数字就是真实待办量 |
| 🆕 `scripts/fill_word_form_irregular.py` | 不规则表 235 词 · 四判据 · 备份 · 事务 · 读回断言 |
| 🆕 `data/curriculum/prebuilt/card_field_candidates_s5_todo.json` | 去重后的待跑清单（161 条） |
| 🆕 `data/curriculum/prebuilt/card_field_fixes_s5.json` | S5 批的 v6 结果（161 条） |
| 🆕 `data/reports/card_field_fixes_s5-2026-09-29.md` | S5 批报告 |
| 📝 `data/word.db` · `app/assets/word.db` | 47 条卡 · 78 条 word_form · **两份已同步** |
| 备份 | `data/backups/word.db.bak-cardfix-20260929-080255` · `word.db.bak-wordform-20260929-080639` |

### 17.8 下一批（建议）

| # | 事项 | 判断 |
|---|---|---|
| 1 | `S3b` 62 条 + `S5c` 106 条「真同音词」的最终确认 | 已有 v6 结果，可用升级判据重判（¥0）—— 预期全为「两边都对」 |
| 2 | `buried→buri` · `leaves→leave` 等**已有可疑映射**的排查 | 🟠 建议做（属「静默给错 base」，比查不到更糟） |
| 3 | 端侧 `LIMIT 1` 无序取映射的架构限制 | 🟠 需产品决策（多映射时按优先级取，还是结合上下文） |
| 4 | 规则变形缺口 199 条 | ❌ 建议不做（§17.5②） |
| 5 | 🆕 **把「同步 app/assets」写进流程**（或做成脚本） | 🟠 本轮踩到，建议固化 |

---

## 十八、排查「已有可疑映射」+ 固化同步 + S3b/S5c 确认（2026-09-29 08:2x）

> 白哥：「1、排查 buried→buri 这类已有可疑映射；3、把『同步 app/assets』固化成脚本/流程；4、S3b 62 + S5c 106 真同音词最终确认。——确认。但 2、端侧 LIMIT 1 无序的架构限制——是什么？」

### 18.1 先答第 2 问：**「LIMIT 1 无序」到底是什么**

**机制**（三段）：
```dart
// ① app/lib/services/word_query_service.dart · analyzeForm()
SELECT ... FROM word_form WHERE form = ? LIMIT 1     // ← 没有 ORDER BY
// ② 拿到 base 后，直接查该 base 的卡片
final card = await _cardBySpelling(lemma.base);       // ← lookup() 第二步
// ③ word_form 的主键是 **(form, base)** —— 设计上允许一个 form 映射多个 base
```

所以「无序」指的是：**当一个 form 对应多个 base 时，取哪一个没有定义**。

**实测：比"随机"更精确** —— 查询走 PK 索引 `(form, base)`（`EXPLAIN` 证实），
索引按 `(form, base)` 排序 → `LIMIT 1` **实际返回 `base` 字母序最小的那个**。

| 插入顺序 | `LIMIT 1` 返回 |
|---|---|
| `zulu` → `alpha` | **`alpha`** |
| `alpha` → `zulu` | **`alpha`** |
| `mike` → `alpha` → `zulu` | **`alpha`** |

→ **与插入顺序无关**。⚠️ 但**SQL 层面无任何保证** —— `ORDER BY` 缺席时，
查询计划一变（如优化器改走全表扫描）顺序就变。

**🔑 关键：当前实测「0 个 form 有多映射」→ 这个限制当前不造成任何实际问题。**
（`SELECT form FROM word_form GROUP BY form HAVING COUNT(DISTINCT base)>1` → 0）
原因：所有写入脚本都是「form 已存在就跳过」→ 隐式保证了一对一。

**但这个保护有副作用，那才是真问题**：
> **现有映射若是错的，后续脚本永远没机会修正**（因为「已存在」就被跳过）
→ 这正是 §18.2 的 `buried→buri` 能存活至今的原因。

**真实的架构缺口在「歧义」而非「无序」**：
`leaves` **同时是** `leaf`（树叶）和 `leave`（离开/假期）的复数/第三人称单数 ——
端侧只能取一个 → 用户划 "The leaves turn brown" 会拿到 `leave` 的卡片。
这类**真歧义**（本次审计 C 档 330 条，含反推噪声）→ 需产品决策：
按优先级取？还是结合上下文消歧？

### 18.2 第 1 项：已有可疑映射排查 —— 判据**改了四次**才收敛

🔑 **先说结论：`buried → buri` 确凿为错，但「映射对错」纯机械判不了**（同 ipa 的 S3a/S3b 一样）。

**`buried → buri` 为什么是错的**（证据）：

| | 词条 | 等级 | 词性 | 释义 |
|---|---|---|---|---|
| 当前 base | **`buri`** | B2 | n | 「贝叶棕，巴里棕榈」（一种热带树） |
| 应为 | **`bury`** | **A2** | v | 「埋葬」 |

→ 用户划 `buried`（bury 的过去式，A2 高频）→ **看到「贝叶棕」的卡片**。
（同一批里 `burying → bury` **是对的** → 说明是生成时按某种规则误配，不是整体崩坏）

**判据演进（四次修正，每次都因「与实际数据对不上」才暴露）**：

| # | 判据 | 结果 | 问题 |
|---|---|---:|---|
| 1 | `rule` × `base` 词性不匹配 | 12,859 | 太粗 —— 绝大多数是**旧规则表垃圾**（`aaroned`/`abbeying`），不是映射错 |
| 2 | 反推 form 的候选 base，当前 base 是否在其中 | — | 🔴 **漏报 `buried`** —— `buri`+`ed`=`buried` 拼写合法 ⇒ `buri` **也在候选里** ⇒ 判「自洽」 |
| 3 | 拼写反推 **+ 词性约束**（`-ed` 要求动词） | 174 | 🟠 仍大量误报 —— **卡片词性标注不全**（`taped→tape` 被判错，但 tape 明明可作动词「贴胶带」） |
| 4 | **+ CEFR 等级**（当前 base 要比候选**更冷僻**） | **48** | ✅ 收敛（`buri` B2 > `bury` A2 ✓；`view` A2 < `vie` B2 ✗ 不报） |

🔑 **第 4 条的直觉**：**高频词的变形更常见** —— 若一个「冷僻词」声称自己是某个
「常见构词形」的原形，多半映射错了（真正的原形应该是那个更常见的词）。

**结果（48 条里 23 条 form 在真实语料 = 用户真可能划到）**，人工过一遍后：

| 判定 | 例 |
|---|---|
| ✅ **真错**（约 5-8 条） | `buried→buri`(应 bury) · `breathed`/`breathing→breath`(应 breathe) · `passed`/`passing→pas`(应 pass) · `pasted`/`pasting→past`(应 paste) · `beded`/`beding→bede`(应 be) |
| 🟠 **误报**（多数） | `taped→tape` · `viewed→view` · `banded→band` · `bearded→beard` · `seeded→seed` · `joined→joint` —— 这些 base **本身就能作动词**，只是卡片没标 |

**顺带发现两件事**（同一批扫描的副产物）：

| 档 | 量 | 说明 |
|---|---:|---|
| **B 垃圾/口径错** | **12,796** | 旧规则表残留：`aaroned`(aaron+n) · `abbeying` · `abdomened` —— `action='keep'`，**占全表 53%**。危害有限（用户不会输入 `aaroned`）但**稀释词库质量** |
| **C 多候选（歧义）** | 330 | 含真歧义（`leaves`：`leaf`/`leave`）+ 反推噪声（`added`：`ad` 是名词，不支持 past） |
| **弱可疑** | 582 | 「base 不在候选但词性说不出话」—— 含 `hatred`(hate+red) · `his`(he 的所有格) 这类反推器覆盖不到的真构词，**不作为确凿** |

### 18.3 第 3 项：固化「同步 app/assets」

🆕 `scripts/sync_word_db_asset.py`

| 模式 | 行为 |
|---|---|
| `--check` | 只比对，退出码 0/1（**可用于 CI / 提交前**） |
| （默认） | 同步 + **读回校验**（同步后必须一致，否则退出码 2） |

🔑 **关键设计：不能比行数**（第一版就栽在这）——
`SELECT COUNT(*)` 只能发现 `word_form` 差异，而 **`card` 表行数完全相同、内容却不同** → 漏判。
✅ 正解：比 **`card.content_hash` / `aggregate_page.content` 的集合**。

**证伪测试**（用 68 条修正前的备份当「副本」，验证它真能发现问题）：
```
🔴 不一致（3 项）
   · word_form: 行数 24140 → 24062
   · aggregate_page: **2 行的内容不同**（行数相同也查得出）
   · card: **230 行的内容不同**（行数相同也查得出）   ← 230 = 115 条 × 双向
```
（230 与 2 正是 §17.3 那批 115 条卡 + 1 个聚合页 ✓ **精确定位**）

另在两个写库脚本（`apply_card_field_fixes.py` · `fill_word_form_irregular.py`）末尾加了同步提示。

### 18.4 第 4 项：S3b / S5c 真同音词确认

**201 条（S3b 62 + S5c 106 去重后）** —— 用升级后的归一化读音判据重判：

| 判定 | 条数 |
|---|---:|
| ✅ **现状与 v6 读音一致**（真同音词 / 仅记法差异 → 两边都对） | **201** |
| 🟠 读音不同（v6 认为现状错） | **0** |

→ **确认：全部为「两边都对」的真同音词，无需任何修改**。¥0（复用已有 v6 结果）。

### 18.5 本轮交付

| 文件 | 说明 |
|---|---|
| 🆕 `scripts/audit_word_form_mappings.py` | 映射审计（拼写反推 + 词性 + 等级 三判据）· `--list` / `--json` |
| 🆕 `scripts/sync_word_db_asset.py` | 副本同步 + 校验（`--check` / 同步+读回） |
| 🆕 `data/curriculum/prebuilt/word_form_audit.json` | 审计结果（A 48 / B 12,796 / C 330 / weak 582） |
| 📝 `scripts/apply_card_field_fixes.py` · `fill_word_form_irregular.py` | 末尾加「交付物同步」提示 |

🔴 **本轮 `word.db` 未触碰**（排查 + 新增脚本，纯只读）。

### 18.6 下一批（建议，均需批准）

| # | 事项 | 量 | 成本 | 判断 |
|---|---|---|---:|---|
| 1 | **A 档 48 条跑 LLM 复核后修 base**（机械判据只到「候选」，精确判定需 LLM） | 48 | ≈¥0.31 | 🟠 建议做（「静默给错答案」） |
| 2 | **B 档 12,796 条垃圾清理**（旧规则表残留，占全表 53%） | 12,796 | ¥0 | 🟠 建议做（需先查「谁在读这些行」） |
| 3 | **C 档歧义消解**（`leaves` 类）——需产品决策：按优先级 or 结合上下文 | 330 | — | ⚠️ 产品定 |
| 4 | 弱可疑 582 条抽查 | 582 | — | 🟡 可选 |

---

## 十九、🔴 修正：B 档「12,796 条垃圾」的判断**被实测推翻**（2026-09-29 08:4x）

> 白哥：「要我批准什么？」→ 说明我上一条的待批清单讲得太笼统。
> **补齐 B 档缺的那次调查后，结论反了** —— 特此更正。

### 19.1 我上一条说了什么，为什么错了

上一条我写：

> 「B 档 12,796 条垃圾清理（旧规则表残留，占全表 53%）… 🟠 建议做（需先查『谁在读这些行』）」

**「需先查谁在读」这句我还没做，就先把「垃圾」定性了** —— 顺序错了：
> 🔑 **「看起来像垃圾」≠「是垃圾」**。定性之前必须先验**判据本身可不可靠**。

### 19.2 查「谁在读」——影响面（已完成）

| 消费者 | 怎么用 | 删了会怎样 |
|---|---|---|
| 端侧 `word_query_service.analyzeForm()` | `WHERE form=? LIMIT 1` → 拿 base 查卡片 | 🟠 **可能影响用户** |
| `gen_card_field_fixes.py` · `verify_card_field_consistency.py` | 读 `(form, base)` 判「例句是否含该词」 | ✅ 无影响 —— 两者**都自带 `_IRREGULAR` 兜底** |
| `incremental_clustering.remove_word()` | `DELETE FROM word_form WHERE anchor_id=?`（词下线时联动） | ✅ 无影响 —— 它是**写端**，且清不到 B 档（B 档的 anchor 指向**还在库**的词） |
| 其余 12 个脚本 | 只是 `grep` 到字符串，不真读表 | ✅ 无影响 |

**副本演练**（`cp` 到 `data/backups/` 再删）：12,796 行删除后 24,140 → **11,344 行**，
`integrity_check` ok · 孤儿 `anchor_id` = 0 · 真变形全保留（`leapt`/`retold`/`shrank`/`went`/`children`）
· **下游判定逐项相同**（S1 0 / S2 0 / S3a 0 / S3b 62 / S4 43 / S5a 0 / S5b 6 / S5c 106 —— **与基线完全一致**）。

### 19.3 🔴🔴 但演练「零影响」**不能**推出「可以删」—— 两处关键漏洞

**漏洞 A：「下游零影响」只证明「脚本不依赖」，不证明「用户不受影响」**

我读的是 `verify_card_field_consistency`（一个**脚本**）。但 B 档的真实下游是**用户划词** ——
用户划 `accounting` 时，端侧 `LIMIT 1` 拿到 `account` 的卡片。**删了这行，用户就查不到了。**
> 🔑 **判据：分清「下游是脚本」还是「下游是用户」** —— 前者零影响 ≠ 后者零影响。

**漏洞 B：B 档里混着大量「真变形」，不是垃圾**

开箱看样本，全是**常用动词的屈折形**，只是**卡片没标动词词性**：

| form → base | base 卡片词性 | 实际 |
|---|---|---|
| `accounting` / `accounted` → `account` | `n` | 🔴 `account` **能作动词**（「解释」） |
| `addressed` / `addressing` → `address` | `n` | 🔴 能作动词（「处理/致辞」） |
| `absented` → `absent` | `adj` | 🔴 能作动词（「缺席」） |
| `ached` / `aching` → `ache` | `n` | 🔴 能作动词 |
| `abstracted` / `abstracting` → `abstract` | `adj` | 🔴 能作动词 |

→ **这批不是垃圾，是真变形。删了 `accounting`/`addressed`/`ached`，用户就查不到了。**

### 19.4 换「更可靠的词性来源」——试了，**也不行**

假设：卡片的 `pos` 是 LLM 生成（只写主要义项）→ 换**词典来源**的 `cefr_j` 词性。

实测 `cefr_catalog.json`（CEFR-J）的词性：

| 词 | cefr_j 给的词性 | 实际 |
|---|---|---|
| `account` | **`n`** | 也能作动词 |
| `address` | **`n`** | 也能作动词 |
| `tape` | **`n`** | 也能作动词（贴胶带） |
| `view` | **`n`** | 也能作动词 |
| `band` / `beard` / `seed` | **`n`** | 都能作动词 |

→ **CEFR-J 只标「主要词性」**，用它重判 B 档反而**涨到 16,244 行**（更差）。
**两个来源都不可靠 → 没有可靠数据源可用来判「这个 rule 适不适用」。**

**再试「form 不在语料 = 垃圾」——同样不可靠**：

| form | 在 `cefr_catalog`？ |
|---|---|
| `learnt` `spelt` `spilt` `labelling` | ❌ **不在** |
| `overthrew` `woken` `shrunk` | ❌ **不在** |
| `abandoneded` `aaroned` | ❌ 不在 |

🔴 前六个**正是我上一轮专门补进去的真变形**（英式变体 + 常见不规则形）——
拿这个信号筛垃圾，会**把真变形一起删掉**。

### 19.5 ✅ 修正后的结论

| 档 | 上一条的建议 | **修正后** |
|---|---|---|
| A 档 48 条 | 🟠 建议做 | ✅ **仍然建议做**（判据靠的是**CEFR 等级对比**，那个信号可靠） |
| **B 档 12,796 条** | 🟠 建议做（「垃圾清理」） | ❌ **建议不做** —— 判据不可靠，**混着大量真变形**，删了会误伤用户 |
| C 档 330 条 | ⚠️ 产品定 | ⚠️ 仍产品定（但可先做「加 ORDER BY」的健壮性修复） |

🔑 **A 档为什么仍然可信**：它的三层判据里，「词性」只是**第一层粗筛**，
**决定性的是第三层「当前 base 的 CEFR 等级更冷僻」**（`buri` B2 vs `bury` A2）——
CEFR 等级是**真实测量数据**，不是标注产物。

### 19.6 🆕 两条新判据

**① 「下游零影响」≠「可以删」** —— 必须分清**下游是脚本还是用户**。
脚本不依赖 ≠ 用户不受影响。（本例：脚本零影响，但用户会「查不到」）

**② 「看起来像垃圾」≠「是垃圾」** —— 定性之前先验**判据的数据源可不可靠**。
本例：判据依赖「词性」，而**两个词性来源都不全**（卡片只写主要义项 · CEFR-J 只标主要词性）
→ 🔑 **上游数据质量不足时，基于它的「删除」决策一律不可执行**。
   （同 `MEMORY.md` 的「『算法是真的』与『输入是好的』是两层」）

### 19.7 顺带：本轮又踩了一次自己的判据

演练时写 `sqlite3.connect('/tmp/probe.db')` —— Python 用 Windows 路径语义，
`/tmp` **不是** Git Bash 的 `/tmp` → **静默建了个空库** → 报错变成「**no such table: word**」。
**正是 `MEMORY.md` 里那条「`sqlite3.connect()` 静默建空库 → 路径写错伪装成表不存在」**。
✅ 修正：用项目内路径 + **连上前断言文件存在且非空** + **连上后断言 `word` 表在**。

---

## 二十、✅ 执行已批两项（2026-09-29 08:5x）

> 白哥：「同意」→ 批了 ① A 档 48 条 LLM 复核后修 base + ②(a) 端侧加 ORDER BY

### 20.1 ① 复核结果：48 → **7**（机械判据误报 **79%**）

**用的工具就是契约 v6 的 `derived_from` 字段**（规则 2 明文：`used→use` · `ran→run` · `taught→teach`）
—— 正是「这个词形从哪个词来」，**不另造 prompt**。48 条 → **¥0.3115** · 8s · 0 失败。

| 判定 | 条数 | 说明 |
|---|---:|---|
| 🔴 **LLM 认同我的候选** → 确认真错 | **7** | 见下表 |
| ✅ **LLM 不认同**（现状是对的） | **38** | 我的 A 档**误报** |
| ⚫ LLM 说「无来源」（信 0.3） | 3 | `lieued`/`lieuing`/`stingying` —— 本身是垃圾形，两边都不可信 → **不动** |

**误报率 38/48 = 79%** —— 与我上一条预告的「~85%」基本吻合。
误报样本：`amped→amp`（`amp` 能作动词）· `bearded→beard` · `seeded→seed` · `singled→single`
· `jointed→joint` · `mines→mine` · `pales→pale` —— **这些 base 本身就能作动词**，只是卡片只标了主要词性。

**7 条真错（全部已写库）**：

| form | 现状（错） | 应为 | LLM 信度 | 病根 |
|---|---|---|---:|---|
| `buried` | `buri` 「贝叶棕」B2 n | **`bury`「埋葬」A2 v** | 0.95 | 同形近亲 |
| `breathed` | `breath`「呼吸」n | **`breathe` v A1** | 0.95 | 同形近亲 |
| `breathing` | `breath` n | **`breathe` v A1** | 0.95 | 同上 |
| `passed` | `pas` n C1 | **`pass` v A2** | 0.95 | 同形近亲 |
| `passing` | `pas` n | **`pass` v A2** | 0.90 | 同上 |
| `pasted` | `past`「过去的」adj | **`paste`「粘贴」v A2** | 0.95 | 同形近亲 |
| `pasting` | `past` adj | **`paste` v A2** | 0.90 | 同上 |

🔑 **7/7 是同一个病根**：**`form` 被配到了「同形的另一个词」**（不是「配错了原形」）——
`breathe` vs `breath` · `pass` vs `pas` · `paste` vs `past`，全是 **A1/A2 高频动词被配成更冷僻的同形词**。
与 §17 的卡片字段污染、`S3a/S3b` 的音标污染是**同一类病**。

**端侧视角验证**（模拟 `analyzeForm` 的 `LIMIT 1`）：
```
breathed → breathe「呼吸」· buried → bury「埋葬」· passed → pass「经过」· pasted → paste「粘贴」
```

### 20.2 写库：7 行（三列一起改）

🆕 `scripts/fix_word_form_mapping.py` —— **固化修正表在脚本里**（只有 7 行，逐行带 LLM 信度）。

🔑 **必须改三列**：`base` + `anchor` + `anchor_id`
—— `anchor == base` 是常态（23,525/24,140），`anchor_id → anchor 所指词条`。
只改 `base` 会让三者互相矛盾，且 `incremental_clustering.remove_word()` 靠 `anchor_id` 联动删行
→ **指错会误删别的词的映射**。

**脚本带的守卫**（缺一不可）：三断言连库 · 逐行验「现状与记录相符」· 验「目标在 word 表」
· 验「无 PK 冲突」· 事务 · 读回断言 · **断言其它列逐字段未变** · 幂等（重跑 0 行）· 备份。

**演练 → 真库**：先在副本上跑通（发现并修了我自己写错的终检断言，见 §20.4），再写 7 行。

| 验证 | 结果 |
|---|---|
| 映射审计 A 档 | 48 → **41（−7）** |
| 自洽 | 10,714 → **10,721（+7）** |
| C 档歧义 | 330 → **337（+7）** —— `buried` 仍有 2 个拼写候选，只是现在**取对了**那个 |
| 字段自洽 S4 | 43 → **42** |
| 结构 / 聚合页 / 两份库 | 13/13 · 12/12 · **一致** |

（A −7、自洽 +7、C +7 三个数字**精确对上** —— 同一行可同时计入「自洽」与「歧义」，与脚本逻辑一致）

### 20.3 ②(a) 端侧加 `ORDER BY base`

`app/lib/services/word_query_service.dart` —— **1 行 SQL + 注释**：

```dart
- 'FROM word_form WHERE form = ? LIMIT 1',
+ 'FROM word_form WHERE form = ? ORDER BY base LIMIT 1',
```

🔑 **这是「确定化」，不是「消歧」** —— 多映射时稳定取**字母序最小**的 base；
「该取哪个」仍需语义判断（未决）。当前实测 **0 个 form 有多映射** → 本条纯**健壮性保障**。

⚠️ **改完需白哥编译验证** —— 我这边 `flutter`/`dart analyze` 都起不来
（`dart analyze` 报 `CreateFile failed 231` 管道错误）。
我做了能做的静态自查：括号平衡（89/89 · 236/236 · 110/110）· 单引号成对（292，偶数）
· `?` 占位符 1 个对 1 个参数；并用真 SQLite 验证了新 SQL 语法有效。

### 20.4 🔴🔴 顺带抓到我自己的工具一个 bug（同一判据没泛化）

**症状**：同步脚本报「✅ 两份库一致」，但 `git status` 只显示 `data/word.db` 变了。

**根因**：`sync_word_db_asset.py` 第二版只对 `card`/`aggregate_page` 比**内容哈希**，
**其余表只比 `COUNT(*)`**。修完 `word_form` 的 7 行后**行数不变、内容变了** → **漏判**。

> 🔑 **教训的形态是「我只在被发现的那张表上修，没泛化」** ——
> 第一次发现「`card` 行数相同、内容不同」（§17.3）时，我只把 `card` 加进哈希比对，
> **没有把同一条判据推广到所有表**。**补丁 ≠ 修法。**

✅ 修法：**每张表都比「全内容摘要」**（逐行哈希 → **排序** → 串起来哈希，与行序无关）。
· 重新检测 → 抓到 `word_form: 内容不同（行数都是 24140）` ✓
· 同步后两份库逐条对齐 ✓
· 证伪测试（用改前备份当副本）→ 准确报出 ✓ · 退出码 1 ✓（可进 CI）

### 20.5 交付

| 文件 | 说明 |
|---|---|
| 🆕 `scripts/fix_word_form_mapping.py` | 7 行修正表 · 六重守卫 · 幂等 · 备份 |
| 📝 `scripts/sync_word_db_asset.py` | 🔴 **改为所有表都比全内容摘要**（修掉 §20.4 的漏判） |
| 🆕 `data/curriculum/prebuilt/wf_mapping_{candidates,fixes,verdict}.json` | 候选 / LLM 原始输出 / 判定表（**均带 `_note` 防误用**） |
| 🆕 `data/reports/wf_mapping_fixes-2026-09-29.md` | LLM 复核报告 |
| 📝 `app/lib/services/word_query_service.dart` | `ORDER BY base`（**待白哥编译**） |
| 📝 `data/word.db` + `app/assets/word.db` | 7 行 · **两份已同步** |
| 备份 | `data/backups/word.db.bak-wfmapping-20260929-085752` |

🔴 **一个陷阱值得记下**：`wf_mapping_fixes.json` 里 `建议写入 48 条` 是**假的** ——
这些 spelling 是**词形**（不是词条），`word` 表里没有 → `load_current` 全返回空
→ 判据把「现状为空」当硬证据。**绝不能把它喂给 `apply_card_field_fixes.py`**（已在 JSON 里加 `_note` 自证）。

### 20.6 未做 / 待办

| # | 事项 | 状态 |
|---|---|---|
| 1 | C 档歧义消解（`leaves` 类） | ⚠️ 产品决策，未做 |
| 2 | 3 条「LLM 说无来源」（`lieued` 等垃圾形） | ⏸️ 两边都不可信，不动 |
| 3 | B 档 12,796 行 | ❌ 建议不做（§19） |
| 4 | **白哥编译** `word_query_service.dart` | ⏳ 待办 |
---

## 二十一、🔴 「未命中路径」补齐方案（2026-09-29 11:1x · 白哥选第 1 项）

> 白哥：「1、」→ LLM 制卡「未命中路径」。
> **本轮只核实现状 + 出方案，未改任何代码/数据。**

### 21.1 现状核实：第 1 步 ✅ 全完成，第 2 步 🔴 六项全缺

**第 1 步（质量与地基 · 已全部交付）**

| # | 项 | 状态 |
|---|---|---|
| 1 | 契约 v5 → **v6**（+`ipa`/`definition`/`context`） | ✅ |
| 2 | `smoke_contract.py`（**改 prompt 必跑**的回归） | ✅ 10/10 |
| 3 | 196 条质量实测 | ✅ ¥1.28（写库 115 条卡） |
| 4 | 闸门 `verify_card_field_consistency.py`（S1–S5） | ✅ |
| 5 | 合规扫描 `scan_compliance.py` | ✅ 29 项验收 · P0=0 |
| 6 | 增量聚类 `incremental_clustering.py` | ✅ 34 项验收 |
| 7 | content 分叉消灭（`aggregate_page_content.py` 唯一产出点） | ✅ |

**第 2 步（在线路径 · 六项全缺）**

| # | 环节 | 现状（实测证据） |
|---|---|---|
| 1 | 端侧 `external_word_cache` | 🔴 **不存在** —— `user_db_schema.sql` 6 表无此表 |
| 2 | 服务端 `generated_card_cache` | 🔴 **不存在** —— `schema.rs` 现役 **18 表**无此表 |
| 3 | `POST /api/generate-card` | 🔴 **不存在** —— `routes.rs` 107 条路由无此路径 |
| 4 | 端侧未命中分支 + **转圈** | 🔴 **不存在** —— `word_query_service.dart:89` `return null` → 调用方只弹「词库里没有「X」」→ 结束 |
| 5 | 失败路径（报错 + 重试） | 🔴 未实现（**裁决已定**，见 21.3） |
| 6 | 会话内缓存 | 🔴 未实现 |

### 21.2 🔴🔴 三条硬约束（出方案前实测，逐条都影响路径选择）

#### 约束 1：**VPS 已释放 → 当前没有可用的服务端**

| 探测 | 结果 |
|---|---|
| `keyievolution.fun` DNS | 解析到 **`<DOMAIN_OLD_IP>`**（⚠️ **不是**记忆里的 `<OLD_VPS_IP>`） |
| `https://keyievolution.fun/health` | 🔴 **不可达**（直连超时 / 走代理 502） |
| 白哥已确认（09-29） | 「**VPS 曾部署已停且已释放**」 |

→ **后果**：服务端代码**可以写、可以本机跑通**，但**不能部署到生产**。

#### 约束 2：**「后端跑在 APK 里」是注释声明 —— 未实现**（又命中我库里的判据）

`backend/src/main.rs` 第 3 行写着：
> `//! Runs as a localhost API server inside the Android APK,`

**按判据「注释里的能力声明必须 grep 一遍才算数」实测**：

| 检查 | 结果 |
|---|---|
| App 内有无 native rust（`flutter_rust_bridge` / jni / ffi） | 🔴 **无**（`pubspec.yaml` 仅有 `sqflite_common_ffi`，那是**测试**用的） |
| `app/android/app/src/main/` 有无 native 集成 | 🔴 只有 `java`/`kotlin`，**无 rust** |
| `backend/src/bin/` | **空目录**（单入口 `main.rs`） |
| 端侧 `api_config.dart` 默认 host | `String.fromEnvironment('API_HOST', defaultValue: 'localhost')` → **默认 localhost:8080** |

→ 🔑 **准确结论**：**原设计意在「后端与本机同机」（localhost），但 APK 内嵌从未实现**；
   端侧靠 `--dart-define=API_HOST=...` 指向真实服务器。
→ **不能靠「内嵌进 APK」绕开 VPS** —— 要走服务端就得有台服务器（或本机开发时起一个）。

#### 约束 3：**`backend/schema.sql` 是过时死文件**

| 文件 | 表数 | 状态 |
|---|---|---|
| `backend/schema.sql` | **45 表**（含 `conversations` / `prebuilt_*` / `plan_*` 等**已退役**的旧学习链） | 🔴 **过时**（0 处代码引用） |
| `backend/crates/api_server/src/schema.rs` | **18 表**（商业能力：users/tokens/pay/subscription/admin/…） | ✅ **权威**（`main.rs` 启动时 `init`） |

→ 🔴 **加表必须改 `schema.rs`** —— 这正是我库里那条
   「**「删数据」≠「让它不再产生」**（建表语句要一并改，否则**新库**会重建）」的反向版本：
   **只改 `schema.sql` → 新库不会建该表 → 运行时报「表不存在」。**

### 21.3 已定裁决（**无需再问**，白哥 09-28/09-29 已定）

| # | 事项 | 已定 |
|---|---|---|
| 1 | 生成放哪 | ✅ **服务端**（全局缓存是成本基石；端侧直连会泄漏 key） |
| 2 | 写哪个表 | ✅ **`external_word_cache`**（不是 `word.db` —— 写 `word.db` 会与 bootstrap 覆盖逻辑冲突） |
| 3 | 失败路径 | ✅ **直接报错 + 稍后重试**（白哥第 4 条 · L0 的「降级卡」在新前提下不成立：失败时没有释义可给） |
| 4 | 一致性口径 | ✅ 与预制**同一套 prompt / 契约 / 校验**（**≠ 同一个脚本**——预制是批量含续跑，在线是单条） |
| 5 | 等待 UI | ✅ **转圈**（白哥第 2 条 · 明确「转圈 UI 也是要新建的」） |

### 21.4 方案选项

| # | 方案 | 可本地验证 | 风险 | 评价 |
|---|---|---|---|---|
| **甲** ⭐ | **服务端先行**（表 + 接口 + 全链路）→ 再端侧 | ✅ **100%**（本机 `cargo run` + curl 端到端） | 🟢 低 | **推荐**：见下 |
| 乙 | 端侧先行（缓存表 + UI），服务端留空 | 🟠 仅表可验 | 🔴 **端侧调接口的分支是死代码**（无服务器）→ 犯「未执行路径 = 静默失效」 | ❌ |
| 丙 | 两者同时做，端到端用本机后端 | 🟠 需 Android 真机/模拟器连本机 | 🟠 我这边 `flutter` 必崩 → 端侧只能白哥跑 | ⭐ 次选 |

**为什么推荐「甲」**（三条理由，都可验证）：

1. 🔑 **它能 100% 本地端到端验证** —— 后端 `cargo check` 实测通过（13.8s），
   可 `cargo run` 起本机服务，用 `curl` 打接口走完整链路
   （**契约 v6 → 合规扫描 → 客观闸门 → 写缓存**）→ **不依赖任何部署**
2. 🔑 **它是「已建地基」的汇合点** —— 契约 v6 / 合规扫描 / 闸门 / 增量聚类**都已经建好了**，
   本轮做的是**把它们串成一条真实链路**（这正是「同一套 prompt/契约/校验」的落点）
3. 🔑 **不产生死代码** —— 端侧最后做，做的时候**已经有可调的真接口**
   （乙 的方案会让端侧「调接口」分支在没服务器时永远不执行）

### 21.5 建议的实施切分（甲方案 · 3 个子步）

| 步 | 内容 | 谁能验 | 依赖 |
|---|---|---|---|
| **A1** | 服务端：`generated_card_cache` 表（改 `schema.rs`）+ `POST /api/generate-card`（照 `tencent_asr.rs` 模式：key 在服务端 · 超时明确 · 错误分 400/500 · `tracing` 日志）+ **全链路**（契约 v6 → 合规扫描 → 闸门 → 写缓存 → 读回） | ✅ **我**（本机 `cargo run` + curl） | **无** |
| **A2** | 端侧：`external_word_cache` 表（`user.db` v3→v4 迁移）+ 未命中分支（**转圈** → 调接口 → 写缓存）+ **失败路径**（报错 + 重试）+ 会话内缓存 | 🟠 **白哥编译**（我这边 flutter 必崩） | A1（要有可调接口） |
| **A3** | 回流脚本（`hit_count ≥ K` 快照 → 过闸门 → 合并进 `word.db`） | ✅ 我（本地跑） | A1（要有 cache 数据）· ⏳ **§11.7 已标「第 2 步之后」** |

**A1 的三个关键设计点**（会在实施前再确认）：

| # | 点 | 建议 |
|---|---|---|
| 1 | **并发竞态**（多用户同时查同一新词） | 词级互斥锁（in-flight 去重）· 等待超时 8s · 超时返「正在生成，请稍后重试」（§4.3 已设计） |
| 2 | **`hit_count` 的语义** | 只管**回流门槛**（去重靠 PK / 并发靠互斥锁）· 🔴 **缺 user 维度** → 补 `distinct_user_count`（§13 已定） |
| 3 | **闸门失败怎么办** | 合规 P0 → **拒绝返回 + 告警**；客观闸门失败 → **不写缓存**（避免把错固化）+ 返回错误 |

### 21.6 🔴 一件必须白哥定的事：**服务端什么时候部署**

| 选项 | 说明 |
|---|---|
| **甲** | **现在只做代码 + 本机验证，部署推到「iOS 上架前」** —— 因为现在还在开发期，且上架前本来就要恢复服务端（登录/支付都要它） |
| 乙 | **现在就恢复 VPS** —— 可以真机端到端，但要花钱 + 属「部署」（需单独指令） |
| 丙 | 先不做服务端，等上架前一起做 |

**我的建议：甲。** 理由：① 现在是开发期，服务端**不影响任何当前进度** ② 登录/支付等商业能力**本来就在等上架前** ③ A1 的代码**不会因为暂时不部署而失效**（`cargo check` 就能保证它可编译）

### 21.7 请示

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **按甲方案（服务端先行）做 A1？** | ⭐ **是** —— 唯一能 100% 本地验证、且不产生死代码的路径 |
| 2 | A1 完成后紧接 A2（端侧）？ | ⭐ 是（A2 需白哥编译） |
| 3 | **服务端部署时机** | ⭐ **甲：推到 iOS 上架前** |
| 4 | `backend/schema.sql`（过时 45 表）要不要顺手清理 | 🟠 建议**先不动**（本次只改 `schema.rs`）—— 它是死文件，清理属独立议题 |
