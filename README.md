# CoEvo 刻意进化 · 英语学习 App

> **更新**：2026-09-27 ｜ **产品**：RSS 英语阅读流 + 划词查词 + FSRS 复习（**仅 iOS** · 中国区 · 个人主体 · 订阅制）
>
> **本文件是项目的单一入口** —— 既是文档地图，也说明「现在做什么、到哪一步」。

## 🚀 三条最快路径

| 我想… | 看这里 |
|---|---|
| **知道整个计划 / 现在到哪一步** | `docs/plan-and-progress-2026-09-26.md` ← **进度唯一入口** |
| **读产品权威设计（最高权威）** | `docs/design/v1-final-design-authoritative-2026-09-25.md` ← **L0，冲突以它为准** |
| **搞清各文档的层级与用途** | 本文件下方「一、核心文档」 |

> 🗂️ **旧文档说明**：K12 时代的 4 份根目录文档（`API.md` / `CoEvo_DataFlow.md` / `CoEvo_Devplan.md` / `DEVELOPMENT.md`）
> 已于 2026-09-27 **归档到 `docs/_archive/k12-era/`**（附失效说明）。**不要把它们当实现依据。**

---

> # 🎯 进度看哪份：`docs/plan-and-progress-2026-09-26.md`
> **「整个计划是什么、现在到哪一步」的唯一入口。** 含 Phase 0–7 + UI Step 1–5 全貌、逐项状态、**关键路径与阻塞链**、风险与已知偏差。
> 🔑 **口径：所有状态以实测产物为准，不靠文档推断** —— 文档说「已完成」不算，有产物才算。
> ⚠️ 主方案 §八「当前状态」与 §七 Phase 1 状态列**均已过期**，已在其原位加指针 → **以进度文档为准**。

> # 🔴 第 0 步：先读权威原文
> **`docs/design/v1-final-design-authoritative-2026-09-25.md`**（白哥原文《完整技术方案（最终版）》）
> **它是最高权威。任何实现与它冲突 → 以它为准。禁止用转述文档做实现依据。**
> 为什么单列：2026-09-26 核查发现卡片设计**偏离 v1 达 8 项**（记忆法被丢弃 53.7%），
> 根因就是**原文一直未落盘，实现一直按二手解读做**。已新建该文件并标注为权威。

**先读哪份？** → 权威原文（第 0 步）→ 再看下方「核心文档」第 1 行（主方案，全案索引）。

---

## 一、核心文档（现行 · 直接依据）

> # 🔴 文档有层级 —— 冲突时按层级裁决，不按「谁更详细」
>
> | 层 | 文档 | 地位 | 能不能被推翻 |
> |---|---|---|---|
> | **L0** | `docs/design/v1-final-design-authoritative-2026-09-25.md` | **白哥原文《完整技术方案（最终版）》** | ❌ **最高权威**，助手不得修改 |
> | **L1** | `docs/design/visual-word-card-target-2026-09-26.html` ★ | **最终目标的界面**（界面锚点） | ❌ 目标层 —— **文档与实现都要向它对齐** |
> | **L2** | `docs/design/word-db-schema-frozen-2026-09-26.md` | 数据层契约（词库 18 表冻结） | ⚠️ 需请示，且不得违反 L0 |
> | **L3** | `english-app-implementation-plan-v2-*.md` | 全案索引 / 实施方案 | ✅ 可改 —— ⚠️ **卡片结构处已偏离 L0，见 §四** |
>
> **为什么必须有 L1**：2026-09-26 核查发现卡片设计**偏离 L0 达 8 项**（记忆法被丢弃 53.7%）。
> 根因是**只有文字、没有可看的目标** —— 文档之间互相引用，偏离无人能发现。
> **有了界面锚点，任何偏离渲染出来就能看出来。**

### 📖 主方案与进度（全案索引）

| 文档 | 用途 |
|---|---|
| 🎯 **`docs/plan-and-progress-2026-09-26.md`** | **【进度单一入口】** —— 「整个计划是什么、现在到哪一步」。Phase 0–7 + UI Step 1–5 全貌 + 逐项状态（✅/🟠/⏳/❌）+ **关键路径与阻塞链** + 风险清单 + 已知偏差。🔑 **口径：状态以实测产物为准，不靠文档推断** |
| **`docs/design/english-app-implementation-plan-v2-2026-09-25.md`** | **全案设计单一事实源** —— 决策索引（§九「35 项决策」）、合规路径、词库评估、语音包、阅读器、变现、UI/UX、路线图、证据索引。<br>⚠️ **两处自相矛盾/已过期**：① §3.2 原则 1 与 §3.3 卡片结构冲突（按 L0 修正，见 §四）② **§八「当前状态」与 §七 Phase 1 状态列已过期** → 已加指针，**进度以 `plan-and-progress` 为准** |

### 💰 变现与合规

| 文档 | 用途 |
|---|---|
| `docs/design/subscription-model-assessment-2026-09-25.md` | **现行变现**（第 4 版 · 订阅制）—— 价格档位核实、分成规则、**TTS 成本红线**、降级策略、LTV 模型、自动续费合规 |
| `docs/operations/qualification-startup-2026-09-25.md` | **资质启动包** —— 要办哪些证、个人主体能不能做、逐周行动清单 |
| `docs/operations/ios-filing-and-adsdk-package-2026-09-25.md` | **备案实操 + App Store 卖家实证**（iTunes API 扫 1342 个中国区 App） |
| `docs/design/ios-only-personal-entity-reassessment-2026-09-25.md` | **个人主体可行性** —— 「个人 + 中国区 + 变现」三层论证（主方案 §1.5.3 的依据） |

### 🎨 视觉与 UI/UX

| 文档 | 用途 |
|---|---|
| `docs/design/design-system-spec-2026-09-25.md` | **视觉单一事实源** —— 三档主题（墨/格/夜）× 粘土质感、痕迹签名、字体、动效 |
| `docs/design/ui-ux-refactor-assessment-2026-09-25.md` | **UI/UX 规格** —— 现有资产复用/重写/删除清单、界面要求、导航结构、实施步骤 |
| `docs/design/visual-clay-spec-2026-09-25.html` ★ | **粘土质感原型**（可直接看） |
| `docs/design/visual-theme-system-2026-09-25.html` ★ | 三档主题原型 |
| `docs/design/visual-feed-bookmark-2026-09-25.html` ★ | 信息流 + 收藏 + 阅读界面原型 |
| `docs/design/font-comparison.html` ★ | 13 款字体对比工具（含 IPA 音标区） |
| 🔴 **`docs/design/visual-word-card-target-2026-09-26.html`** ★ | **L1 界面锚点** —— 单词卡片的**目标形态**（记忆法为主）、对照当前实现、配套界面（划词浮层/聚合页）、**验收清单** |

### 📚 内容与数据

| 文档 | 用途 |
|---|---|
| `docs/design/word-database-design-2026-09-25.md` | **词表数据库定位**（「词形还原是地基」的完整论证） |
| `docs/design/cefrj-license-and-lemmatization-2026-09-25.md` | CEFR-J 许可核实 + 词形还原实现（34,724 条 / 覆盖 97.6%） |
| `docs/design/content-source-strategy-evaluation-2026-09-25.md` | 内容源策略（RSS 为主、Reddit 为何放弃、共享内容池成本核算） |
| `docs/design/ebook-import-assessment-2026-09-25.md` | **电子书导入**（EPUB/TXT）—— NPPA 边界、商店实证、DRM、「用 CoEvo 打开」已实施 |
| `docs/design/ugc-comments-feasibility-2026-09-25.md` | UGC 决策依据（不做自由文本 UGC，改用结构化交互） |

### 🔍 词库查询与索引

| 文档 | 用途 |
|---|---|
| 🔴🔴 **`docs/design/tts-unified-client-side-2026-09-26.md`** | **TTS 方案唯一权威（2026-09-26 白哥定案）** —— **全量端侧 `flutter_tts`**（文章朗读 + 词卡都是）· **腾讯云语音包取消**（63,048 条 / ¥48.7 / 290 MB）· 🔑 **「音色统一」口径 = 当前用户/当前设备内一致**（**非**跨设备）· 单卡成本 ¥0.0092→**¥0.0058** · App 体积 **−290 MB** · 含 iOS 音色三层现实约束与 4 条应对 · **§七 5 项定案**（`card_audio` 留 DDL 待收费扩展 / `sort_seq` 保留 / **后端 TTS 全链保留**（后续 chat·AI 考核）/ ~~`sherpa_tts.dart`~~ **已删** / Phase 2 留槽位）· 🔴 **推翻本行下方「词卡走服务端腾讯云 TTS」的建议** |
| 🔴 **`docs/design/on-demand-generation-server-side-2026-09-26.md`** | **按需生成的服务端方案 + 合规扫描结果** —— ✅ 合规扫描器建成（**P0 已归零**：`taiwan` / `tibet` 释义已改为符合官方立场的表述，2026-09-26）· **5 条判据铁律**（首版误报 97 → **P0=0 / P1=6 / P2=2**；🆕 **铁律 5「官方行政区划名 ≠ 主权主张」** —— 「自治区」是官方区划名、原被误判为 P1 后移除）· 🔴 **`confidence` 实测 98% 都是 0.9 → 无区分度，不能当闸门** · ⛔ **§三「词卡走服务端腾讯云 TTS」已作废** → 见上一条 ｜📌 详见 `plan-and-progress` **§3.10 / §3.11** |
| 🔄 **`docs/design/wordlib-on-demand-growth-2026-09-26.md`** | **词库策略转向（预先建满 → 按需生长）** —— 白哥定「划线查不到就 LLM 生成 + 走完整表结构 + 更新聚类」；🔑 **这是回归 v1 原文**（`external_word_cache`/`generated_card_cache`/`POST /generate-card`）；✅ 增量聚类**已验证可行**（**34 项断言**：门槛跨越 size 2→3 自动建页 · 同形异源不混 · 删词回退）；含架构取舍（服务端 vs 端侧，成本差 ≈ 用户数倍）与**缺失三环节**（合规扫描 / `confidence` 门槛 / ~~新词音频~~→✅ 2026-09-26 已定：端侧 `flutter_tts`） |
| 🔴 **`docs/design/word-list-diff-cefr-catalog-vs-worddb-2026-09-26.md`** | **两代词表差异核查** —— `cefr_catalog.json` **41,574**（旧·表面词形）vs `word.db` **11,523**（新·词元）：差集 30,464 = 变形 7,858（已归一）+ 语料长尾 22,606（未达标准）· 🔴 **但查出 `word_form` 真缺口：高频词可达率前 2000 仅 96.0%，1,233 个词查不到**（`things`/`activities`/`opened`）· 含判据方法（用 `brown_freq` 当真实性过滤器）· 核查脚本 `scripts/audit_wordlist_diff.py` |
| ✅ **`docs/design/word-query-indexing-audit-2026-09-26.md`** | **Phase 1 #11 报告 + 实施记录** —— 原定性不成立（`match_text()` **死代码** / 索引已齐 27 个 / 划词不走后端）；**§九** 含实施方案（`WordQueryService` + 冗余 `spelling`）、**79 项验收**、两项自我更正（后端**可**本地验证 / capture 入口各自独立） |

### 🧠 记忆与制卡

| 文档 | 用途 |
|---|---|
| 🔴 **`docs/design/word-db-migration-to-v1-design-2026-09-25.md`** | **词库迁移到 v1 设计的完整方案**（2026-09-25 决策：**按 v1 设计**）—— **3 条 DDL 修正**（`UNIQUE(lemma)` 冲突 1,375 张卡 · 缺 `word_form` · `content_hash` 阻断降级卡）+ **逐表逐字段迁移矩阵** + 三层可用性（直接迁移 / 机械转换 / LLM 新建）+ 4 阶段路线 + 风险回滚 |
| 🔴 **`docs/design/v1-final-vs-v2-authoritative-mapping-2026-09-25.md`** | **v1《最终版》→ v2 权威逐项对照** —— **四类判定：A 明确修改 11 项 / B 真丢失 10 项 / C 已保留 12 项 / D 从未决策 1 大类**。含 **27 张表逐张落地情况** + **字段级缺口**。🔴 **D 类已决策：按 v1 设计** |
| 🔴 **`docs/design/mnemonic-layer-separation-2026-09-26.md`** | **记忆法的库级 vs 渲染层职责划分** —— 白哥纠正：**库级只问「可不可以」，优先级是渲染层的事**；`word_mnemonic_profile.primary/secondary` 应废弃；含「可以」的质量门槛（collocation/cognate/etymology 三处判据修正）+ **§2.0 分母与口径**（所有覆盖率分母统一 = 11,523；「87」是假差）+ **§3.0 段的显示名 vs 内部 code** + **§3.5 聚合页门槛 ≥3** + **§6.2 116/117/30 三个数的关系** + **§九 与 v1 原文的三处取代关系** |
| 🔴 **`docs/design/no-mnemonic-116-words-audit-2026-09-26.md`** | **「记忆法全不可用」116 词的核查报告** —— 结论：**③ 释义 / ④ 例句 100% 完整，不补数据**；**41 条是口径问题**（词组 13 / 缩写 15 / 专名 13，天然不适用）；**副产品：「记忆法全不可用」是词表质量探针**（噪声密度 ≈30%） |
| 🔴 **`docs/design/mnemonic-implementation-audit-2026-09-26.md`** | **六种记忆法的数据实现状态审计** —— 逐项核实「哪些实现了、哪些没实现」：**4 种已实现 · 1 种判定错（cognate）· 1 种完全没做（image）**；含 `primary` 判定未按 priority 顺序的根因 |
| 🔴 **`docs/design/card-design-deviation-from-v1-2026-09-26.md`** | **卡片设计偏离 v1 的核查报告**（8 项偏离 + 记忆法丢弃 53.7% + 三层偏离因果链 L0→v2→实现 + 修复方案） |
| 🔴 **`docs/design/fsrs-rating-and-scheduler-audit-2026-09-26.md`** | **复习评分按钮的作用 + FSRS 调度审计** —— 四档自评实测**单调性全反**（「熟练」比「一般」更早重来）· **elapsed 被忽略**（间隔与"隔了多久"无关）· 根因 = 公式拿 **rating 冒充 retrievability** · `submit_review` **遮蔽入参**致 `review_log` 不可信 · **8 项偏差**含缺 `desired_retention` · 🔴 **方案：端侧改用 pub.dev `fsrs` 纯 Dart 包**（官方 `fsrs` crate 拖进 `burn` 474 个包，不可用） |
| 🔴 **`docs/design/fsrs-client-side-migration-plan-2026-09-26.md`** | **FSRS 调度移至端侧的设计方案**（白哥已批准方向）—— 依赖实测（**Dart 包仅 2 个依赖 vs Rust crate 474 个**）· API 确认（含 **UTC-only** 硬约束）· ✅ **实测两个 bug 在 Dart 包中都不存在** · 参数取值（`learningSteps` 是唯一体验陷阱）· **🔴 多端同步 3 方案**（推荐「事件日志 + 重放」）· 后端 `fsrs5.rs` 处置 · **8 项强制单测** · 实施步骤 |
| 🔴 **`docs/design/mnemonic-card-design-gap-assessment-2026-09-25.md`** | **「记忆法与制卡」的缺失评估** —— v1 §四 在 v2 中的状态。⚠️ 已有两处判定被上面第一份修正 |
| `docs/review/english-app-simplification-plan-review-2026-09-25.md` | **v1《最终版》的官方技术评审报告** —— **6 个阻塞 + §十「值得保留 10 条」+ B1–B6 + C1–C10**。🔑 **「哪些要完整实现」的权威来源**；⚠️ 历史快照，结论已落地，**数据与清单仍有引用价值** |

---

## 二、归档文档（`docs/design/_archive/` · 历史快照，勿作依据）

**为什么保留**：它们含有**当时的实测数据与推理过程**（如 iTunes API 扫描、成本核算、判例检索），删掉会丢失可复查性。

| 文档 | 状态 |
|---|---|
| `docs/design/_archive/ad-monetization-and-flutter-assessment-2026-09-25.md` | ⛔ **整份作废**（取消费广告变现） |
| `docs/design/_archive/membership-benefits-plan-2026-09-25.md` | ⛔ **整份作废**（第 2 版：广告 + 会员去广告） |
| `docs/design/_archive/paid-app-model-assessment-2026-09-25.md` | ⛔ **整份作废**（第 3 版：¥38 一次性买断） |
| `docs/design/_archive/overseas-ad-platform-assessment-2026-09-25.md` | ⛔ 路径 C 作废（**产品与市场不匹配**） |
| `docs/design/_archive/article-vocab-count-design-2026-09-25.md` | ⛔ 功能已否决（「N 个生词」）；词形还原部分已并入 word-database-design |
| `docs/design/_archive/visual-direction-exploration-2026-09-25.md` + `.html` | ⚠️ 框架被修正（「三选一」→「三档全做」）；定稿见 design-system-spec |
| `docs/design/_archive/visual-clay-direction-2026-09-25.html` | ⚠️ 早期方向稿 |
| `docs/design/_archive/android-platform-impact-2026-09-25.md` | ⚠️ Android 已放弃；保留供未来重启 |

> **归档文档的单向规则**：核心文档可以引用归档文档（路径带 `docs/design/_archive/`）；**归档文档内部的引用保持历史原貌，不做同步**。

---

## 三、⚠️ 四条使用约定（避免踩坑）

### 0. 🔴 `app_user` 有**两个含义**（同名不同物，先分清再读）

| 含义 | 出处示例 | 状态 |
|---|---|---|
| **v1 设计的用户表名** | `CREATE TABLE app_user (…)` · `app_user(email, password_hash)` · `user_id BIGINT REFERENCES app_user(id)` | ✅ **有效** —— v1 是 L0 权威原文；v2 把它缩写成 `users` |
| ~~旧 Flutter 项目目录~~ | `app_user/lib` · `app_user/.github/workflows` · `app_user`（`coevao_app`，**`app` 的前身**） | 🗑️ **2026-09-26 已删除** |

**→ 区分方法**：出现在 **DDL / 字段列表 / `REFERENCES`** 里的是**表**；
出现在 **路径 / workflow / 目录** 语境里的是**已删目录**。
**→ 遗留影响**：主方案与评审文档里「现网 `app_user` 已有 `email` 可复用」那句**是错的反面教材**
（真实现网 `users` 表用 `username`，`email` 全后端 0 命中）—— 那句里的 `app_user` 指的是**表**。

### 1. 「决策编号」有**两套**，不要混用

| 文档 | 编号 | 说明 |
|---|---|---|
| **主方案 §九** | **1–35 项** | ✅ **全案索引** —— 引用决策时以此为准 |
| `ui-ux-refactor-assessment` §7.2 | 1–33 项 | ⚠️ **UI/UX 视角的子集**，编号与主方案**不同** |

**→ 引用决策时请用「内容描述」而非编号**，或明确写「主方案决策 N」。

### 2. 词库有多个数字，口径不同（都正确）

详见主方案 **§2.0 词库数字口径表**。**⚠️ 已于 2026-09-25 执行清洗（两轮共删 876 条）→ 以清洗后数字为准**：

| 数字（清洗后） | 清洗前 | 口径 |
|---|---|---|
| **11,997** | 12,871 | 词条总数 → 说「词库规模」用这个 |
| **11,917** | 12,791 | `card_type='vocabulary'` 词表词条 → **词形映射分母** |
| — | 12,839 | 有词卡详情（清洗前口径，影响率类指标待重算） |
| ~~11,900~~ | — | ⚪ 规划值**已达成**（实测 11,917） |

### 3. 被推翻的决策清单（搜索残留时用）

| 已作废 | 现行替代 |
|---|---|
| 广告变现（含聚合平台路径） | 取消费广告变现（个人主体平台层走不通） |
| 海外区（AdMob） | 只上中国区（产品与市场不匹配） |
| 一次性买断 ¥38 | 订阅制（产品有内容更新与长期服务） |
| ¥99 年付 | **¥78/年**（折扣 34%，压 churn） |
| 语音包作为订阅权益 | 语音包**全免费**；订阅权益改为「无限生词本 + 文章朗读」 |
| 「N 个生词」统计 | 去掉（痕迹成为唯一进度表达） |
| 自由文本 UGC | 结构化交互（有用/有点难 + 群体统计） |
| Android | 暂时放弃，仅 iOS |
| plan / 精读课程 | 取消（与「每日新鲜」定位冲突） |
| Admin 后台 | ✅ **已整块删除（2026-09-26）** —— `app/lib/pages/admin` + `admin_screen.dart` + **`app_admin` 整项目**（累计 **17,205 行**） |
| ~~旧项目 `app_user` + `coevo_shared`~~ | ✅ **已删除（2026-09-26）** —— **19,794 行**（旧 Flutter 项目 + 共享库，`app` 完全不用）；⚠️ 其中 **iOS 归档/上传参考已抢救** → `docs/operations/ios-appstore-ci-reference.md` |
| **单端登录踢旧**（v1 §7.2 的 `user_session` + `is_active`） | ✅ **多端同步**（复用 `tokens`，不建 `user_session`）—— 评审 B3「单端踢旧破坏离线优先」→ 白哥确认。**⚠️ 这是明确修改，不是现状差异** |
| **服务端 PostgreSQL** | ✅ **SQLite**（与现网一致）—— 评审阻塞 4 |
| **`word_id` INTEGER 自增** | ✅ **沿用现网 UUID**（`prebuilt_cards.id` 是 TEXT） |
| **语音包 360 MB 自建 CDN** | ✅ **腾讯云 TTS 一次性预生成**（290 MB / ¥48.7）—— 评审 §七 |
| **词根/同源 priority 1** | ✅ **后置**（改用现成的搭配+语境起步）；⚠️ **评审要求「中期补回 priority 1/2」** —— 见 `v1-final-vs-v2-authoritative-mapping` A6/B8 |
| 🔄 **v1「记忆法与制卡」§四**（记忆法优先级 / 卡片内容结构 / 聚合页 / 聚合页关联） | ⚠️ **分两种性质**：**记忆法优先级 = 明确后置**（评审 B1，有决策）；**聚合页 + 词根拆分结构 = 真丢失**（评审 §十 第 4 条明确说「不要动」，v2 却删了）→ **2026-09-25 已出两份评估，待决策** —— `v1-final-vs-v2-authoritative-mapping` / `mnemonic-card-design-gap-assessment` |
| 🔴 **v1 数据层的 27 张表** | ✅ **已决策（2026-09-25）：按 v1 设计** —— 现网仅 `review_log` 一张存在。**迁移方案见 `word-db-migration-to-v1-design`**（含 3 条 DDL 修正 + 逐字段矩阵）。⚠️ **前置：Phase 1 #5 词形聚合必须先做**（否则 `UNIQUE(lemma)` 冲突 1,375 张卡） |

---

## 四、🔴 已知文档级冲突（2026-09-26 核查）

### 4.1 卡片结构：L0 与 L3 冲突 —— 以 L0 为准

同一件事，三份文档三种说法：

| 层 | 出处 | 卡片 sections | 记忆法地位 |
|---|---|---|---|
| **L0** | v1 §4.2 | `[root, definition, context]` | ✅ **主体（排第 1）** |
| L3 | v2 §3.3 | `[sense, collocation, family]` | 🔴 **完全丢失**（连 root 都没有） |
| — | 实际实现 | `[sense × 4, root]` | 🔴 排最后 |

**更严重的是 L3 内部自相矛盾**：
- v2 **§3.2 原则 1** 说「一次只能稳固建立 **1 个**『词 → 义』连接。多义项并列会导致**语义干扰**」→ 方向正确
- 但 v2 **§3.3 结构**让 `sense` 打头、且**没有 `root`**

**→ 裁决：按 L0 §4.2 重建卡片结构** ——
`[记忆法(root/cognate/collocation/etymology/imagery)] → [definition：**只 1 条**] → [context：**只 1 条**] → [aggregate_link]`
，`definitions[1..]` 进 `card_extra`（这一点 L3 的 §3.2/§4.2 与 L0 §5.2 **一致**，可直接沿用）。

### 4.2 已对齐项

| 项 | 状态 |
|---|---|
| 词库 18 表 DDL | ✅ 已按 L0 + 修正冻结（`word-db-schema-frozen`） |
| 字幕/精读课程 / plan / 词表分级 | ✅ 已按 L0 取消 |
| 订阅制 · 免费层 · 降级策略 | ✅ 已定 |
| **卡片结构** | 🔴 **待修**（按 §4.1 裁决） |
| `word_mnemonic_profile` 的使用 | 🔴 **待修**（表已建、数据已算，制卡时未读 → 需在制卡段消费它） |

---

## 五、文档维护工具

```bash
# 一致性检查（跨文档事实比对 + 悬空引用 + 被推翻决策残留 + 盲区扫描）
python3 scripts/doc-consistency-check-english-app.py
```

### 🔧 验证工具（本地可跑 · 2026-09-26 补齐）

| 工具 | 命令 | 查什么 |
|---|---|---|
| **结构检查** | `python3 scripts/check_native_readiness.py` | 清障进度：`dart:html`/`dart:js` 残留 · admin 残留 · 代码量（**退出码 1 = 仍有阻塞**） |
| **进程内静态分析** | `cd scripts/analyze_inproc && dart run bin/analyze.dart ../app/lib` | 类型 / 引用 / 未解析 import / 未使用（**`app/lib` 76 文件 → error=0**） |
| **卡片结构验收** | `python3 scripts/verify_card_structure.py` | v1 §4.2 段类型 · `sense` 归零 · `context` 覆盖 · 渲染后 ≤ 4 段（**13 项断言**） |
| **FSRS 调度验收** | `cd scripts/fsrs_verify && dart run bin/verify.dart && dart run bin/verify_service.dart` | 四档单调 · elapsed 敏感 · 同日去重（**19 + 39 项断言**） |
| **查词层验收** | `cd scripts/query_verify && dart run bin/verify_word_query.dart && dart run bin/verify_review_list.dart` | 查词 / 词形还原 / 聚合页入口 / 复习列表排序（**42 + 37 项断言**） |
| **增量聚类验收** | `python3 scripts/verify_incremental_clustering.py` | 新词并入已有族 · **门槛跨越自动建页/删页** · 全库不变量（**34 项断言**） |
| **合规扫描** | `python3 scripts/scan_compliance.py` | 涉主权 / 涉政 / 黄暴 / 歧视（**有 P0 → 退出码 1**）｜验收 `python3 scripts/verify_compliance_scan.py`（**29 项**：9 正例 + 17 负例） |

> 🔑 **为什么需要「进程内静态分析」**：本机**无法 fork 任何子进程**（Windows 命名管道耗尽），
> 而 `dart analyze`/`flutter analyze` **架构上必须拉起 `analysis_server` 子进程** → 必崩
> （**与 Flutter 是官方版还是鸿蒙版无关**，实测两个 SDK 崩在同一行）。
> 详见 `scripts/analyze_inproc/README.md`。
> ⚠️ 分析前**必须先** `FLUTTER_ROOT='D:\flutter' dart pub get --offline`（联网版会卡到超时）。

**`doc-consistency-check` 输出四部分**：
1. **跨文档事实比对** —— 同一事实的多处表述（多值并存 = 可疑）
2. **悬空引用** —— 文件路径 + 章节引用是否指向存在的位置
3. **被推翻决策残留** —— 是否还有把它们当现行方案描述的地方
4. **零命中盲区** —— 应该有但从未写下的话题

> 🔴 **词库结构变更提醒（2026-09-25 决策）**：已决定**按 v1 设计**（14 表 + `word_form`），
> **迁移方案见 `word-db-migration-to-v1-design`**。⚠️ 该文档列出的 **DDL 修正**（`UNIQUE(lemma)` 冲突 1,375 张卡等）
> 是**建表前的必做项** —— 未修正会直接插入失败。

> ⚠️ **脚本的「多值并存」不等于「矛盾」** —— 很多是**合法的口径差异**（如汇总值 vs 部分值）。
> 判断标准：**同一个东西在同一口径下出现两个值 = 真矛盾**；不同口径 = 加注说明即可。

### 当前已知盲区（截至 2026-09-25 · 归档后重扫）

| 话题 | 状态 | 为什么重要 |
|---|---|---|
| 🔴 **日志上报 / 崩溃监控** | **全案 0 命中** | 生产 App 必需 —— 没有它上线后出问题无法定位 |
| 🔴 **性能指标** | **全案 0 命中**（无量化目标） | 「毫秒级查词」「启动时间」等从未定过数字 |
| 🟡 **界面语言 / i18n** | 仅 1 份提及 | 隐含定位是「中文母语者」，但从未**正式写下并验证** —— 若实际目标是全球用户，词卡结构/字体/内容源难度都要重做 |
| 🟡 **测试策略** | 仅 1 份提及 | 无测试计划 |
| 🔴 **记忆法设计** | ⚠️ **曾为盲区（v1 有、v2 丢失且无人发现）** —— 2026-09-25 已出两份评估；**「聚合页/容量控制/卡片固化」待补回** | 卡片是产品的核心交付物，「按什么记忆法组卡」直接决定记忆效率 |
| 🔴 **词库的数据结构** | ✅ **已决策（2026-09-25）：按 v1 设计** —— 方案见 `word-db-migration-to-v1-design`。⚠️ **`UNIQUE(lemma)` 需先做 #5 词形聚合**（冲突 1,375 张卡） |
| 🟡 **无障碍** | 仅 1 份提及 | Apple 审核渐严（VoiceOver） |
| 🟡 **存量数据处置** | 仅 1 份提及 | 生产库 45 表 29 空、users 仅 2 条 → 零迁移成本，但仍需一句结论 |
| 🟡 **版本节奏** | 仅 2 份提及 | 无发版/灰度/TestFlight 计划 |

> **规律**：零命中的话题里，**产品定位类**（如界面语言）比技术类更危险 —— 技术话题通常会被某个开发任务自然带出来，定位类不会。

---

## 六、相关目录

| 目录 | 内容 |
|---|---|
| `design/Duolingo/` | 竞品设计系统参考（DESIGN.md + tokens.json） |
| `design/fonts/` | 字体子集产物（Literata / Charis SIL / 阿里普惠体） |
| `design/_archive/` | 归档文档（本文档第二节） |
| `docs/operations/` | 资质、备案、运维 · **`docs/operations/ios-appstore-ci-reference.md`** = iOS 归档/上传 CI 参考（从已删的 `app_user` 抢救，含 6 处修正） |
| `docs/plan-and-progress-2026-09-26.md` | **进度单一入口**（Phase 0–7 + UI Step 1–5 全貌与逐项状态，见 `## 三` 开头的横幅） |
| `docs/_archive/` | 更早的项目归档（bug 报告、评估统计、旧版本） |

**代码侧新增（2026-09-26）**：

| 位置 | 用途 |
|---|---|
| `app/.github/export-options.plist` | iOS 导出配置（`teamID` 待填，见 operations 参考文档） |
| `app/lib/services/fsrs_service.dart` | 端侧 FSRS 调度服务（**不 import Flutter**，可本地验证） |
| `app/assets/sql/user_db_schema.sql` | 端侧 `user.db` 表结构（复习状态 + 复习日志） |
| `app/lib/utils/image_export.dart` | PNG 导出（替代 web-only 的 Blob+AnchorElement 下载） |
| `app/lib/utils/math_expr.dart` | 纯 Dart 数学表达式求值器（替代 `js.context.eval`） |
| `scripts/analyze_inproc/` | **进程内静态分析**（绕开 `analysis_server` fork 限制）+ 自建平台可用性判据 |
| `scripts/query_verify/` | **端侧查询层验收**（纯 Dart + 真库）：`verify_word_query.dart` **42 项** + `verify_review_list.dart` **37 项** |
| `app/lib/services/word_query_service.dart` | 查词 / 词形还原 / 卡片段 / 聚合页入口（**不 import Flutter**） |
| `app/lib/services/review_list_query.dart` | 复习列表 / 前缀搜索 / 三档排序 / 到期分组（**不 import Flutter**） |
| `scripts/check_native_readiness.py` | 清障进度度量（web-only 残留 / admin 残留 / 代码量） |
| `scripts/verify_card_structure.py` | 卡片结构验收（13 项断言） |
| `scripts/fsrs_verify/` | FSRS 调度验收（19 + 39 项断言，纯 Dart） |
| `scripts/query_verify/` | 端侧查词层验收（42 + 37 项断言，纯 Dart + 真库） |
| `scripts/incremental_clustering.py` + `verify_incremental_clustering.py` | 增量聚类引擎与验收（34 项） |
| `scripts/scan_compliance.py` + `verify_compliance_scan.py` | 内容合规扫描与验收（29 项） |
| `scripts/audit_wordlist_diff.py` | 两代词表差异核查（41,574 vs 11,523） |

---

*本文档是导航，不含设计内容 —— 设计内容一律以「核心文档」为准。*
