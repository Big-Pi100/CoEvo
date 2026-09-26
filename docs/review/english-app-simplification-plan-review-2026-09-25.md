# 英语学习 App 简化方案 — 技术评审报告

> ## 📌 这是首版评审的历史快照 —— 结论已全部落地（2026-09-25 同日）
>
> 本文档是对**原 14 章方案**的评审，当时结论是「方向成立，但不能开工，有 6 个阻塞」。
> **6 个阻塞现已全部解决**，方案也已重写。**要看现行方案请读下面这些：**
>
> | 现行文档 | 内容 |
> |---|---|
> | `docs/design/english-app-implementation-plan-v2-2026-09-25.md` | **主方案**（词库 / 语音包 / 内容流 / 合规 / 变现 / 路线图） |
> | `docs/design/design-system-spec-2026-09-25.md` | **视觉系统定稿规格** |
> | `docs/design/word-database-design-2026-09-25.md` | 词表数据库定位 |
>
> ### 6 个阻塞的解决情况
>
> | # | 首版评审的结论 | 现状 |
> |---|---|---|
> | 1 | **分发渠道未定义**（决定整个技术路线） | ✅ 已定：**原生 App，走 App Store**；不做 Web / 微信 |
> | 2 | 词库外生词进不了生词本与复习队列 | ✅ 已定：词形映射表 + `suspended` 状态；详见词表数据库文档 |
> | 3 | DDL 自相矛盾（`ON CONFLICT` 无唯一约束、`content_hash UNIQUE` 阻断降级卡） | ✅ 方案已重写，新表设计见主方案 §5.6 |
> | 4 | `word_id` 永久稳定只有断言没有机制 | ✅ 已定：沿用现网 UUID 风格 + `word_form` 映射表 |
> | 5 | PostgreSQL 对 2C1G VPS 过度设计 | ✅ 已定：服务端继续用 SQLite（与现网一致） |
> | 6 | 缺合规章节与支付表 | ✅ 已定：**内容源改为 RSS**（绕开 NPPA 出版许可）；支付复用现有 `payment_orders` + `subscription.rs` |
>
> ### 另外两处「重复造轮子」的处置
> - **语音包 360 MB 自建 CDN 分发** → 已改为全量腾讯云 TTS 一次性预生成（290 MB，成本 ¥48.7）
> - **词根/同源排在 priority 1 但数据为 0** → 已后置；改为从现成的搭配 + 语境做起
>
> **本文档的价值在于「当时的实测数据」**（词库缺陷量化、生产库存量、成本核算），
> 这些数据仍有效，且被后续文档引用。**但其中的问题清单与建议不要当作现行结论。**

---

- 评审对象：《阅读器 + 单词学习 App 完整技术方案（最终版）》14 章
- 评审日期：2026-09-25
- 评审人：WorkBuddy
- 依据：实测 `E:\CoEvo` 代码 + `data/coevo.db` 生产库 + `data/curriculum/` 数据资产
- 当时结论：**方案方向成立，但现在不能开工。有 6 个阻塞级问题，其中 1 个（分发渠道）会决定整个技术路线；另有 2 处「重复造轮子」，会让项目白做 4~6 周。**（**→ 已全部解决，见上方横幅**）

---

## 〇、结论摘要（TL;DR）

### 三条最重要的结论

**1. 时机非常好，几乎没有迁移成本。**
现网 `data/coevo.db` 共 45 张表，**29 张全空**。核心用户表 `users` 只有 2 条记录（都是 2026-06-25 的 `trial_xxxx`，此后零活动），`card_memory` / `user_cards` / `user_plan_progress` / `payment_orders` / `review_log` **全部为 0 行**。
→ 现在做简化，**没有存量用户数据要迁移、要兼容、要灰度**。这个窗口过几个月就没了。

**2. 方案第三章（数据层）有相当一部分是「重复造轮子」。**
项目里已经有了方案想要的大部分东西，只是没被告知：

| 方案需要 | 项目已有的 | 状态 |
|---|---|---|
| 英文释义（中英双语） | `prebuilt_language_cards.definitions`（JSON：pos + 英文meaning + chinese + example） | ✅ 12,839 词 |
| 音标 IPA | `prebuilt_language_cards.pronunciation`（**真实 IPA**，如 `/ɪnˈkrɛdɪbl/`） | ✅ 12,839 词 |
| 语境例句 | 同上 `definitions[].example` | ✅ 11,997/12,839（93.4%） |
| 搭配整记 | `prebuilt_language_cards.related_phrases`（含中文注释，如 `receive an award, receive treatment, receive guests（获奖，接受治疗，接待客人）`） | ✅ 12,539/12,839（97.7%） |
| CEFR 分级 | `prebuilt_cards.grade_band` + `prebuilt_language_cards.level` | ⚠️ 12,839 有，其中 1,885 条 `level` 为空 |
| 分级阅读课文 | `english_rebuild/phase3_passages.json` — **80 篇 A1–C1 课文**（含 translation / key_sentence_patterns / key_grammar / vocabulary_focus / common_mistakes） | ✅ 已完成 |
| 课文驱动 plan | `english_rebuild/english_rebuilt_plan.json` — stages→tasks（task_key `01-01`…） + prompt_mode `english/reading-primary` + card_ids | ✅ 已完成 |
| 词根词缀 | 全仓库 0 处 | ❌ 从零建设 |
| 同源词群 | 全仓库 0 处 | ❌ 从零建设 |
| 词源故事 | 全仓库 0 处 | ❌ 从零建设 |
| 联想图像 | 0 处 | ❌ 从零建设 |

**关键推论**：方案的记忆法优先级阶梯是 `词根(1) → 同源(2) → 搭配(3) → 词源(4) → 联想(5) → 语境(6)`。但实测结果是 **priority 3 和 6 已经现成可用（今天就能上线），priority 1/2/4/5 是从零开始的重活**。方案把「已经有的」排在后面、把「还没有的」排在前面 —— 优先级需要整个反过来。

**3. 方案第六章（语音包）可能是 360 MB 的无效复杂度。**
项目里**已经有三套 TTS 在工作**：

| 引擎 | 位置 | 能力 | 体积成本 |
|---|---|---|---|
| 端侧神经网络 TTS | `app/lib/services/sherpa_tts.dart`（sherpa-onnx Matcha zh-en） | **离线合成任意英文**，已实现「模型下载 → 引擎初始化 → 合成 → 播放」全链路 | 模型 125 MB（`model-steps-3.onnx` 72.2 MB + `vocos-16khz-univ.onnx` 51.4 MB） |
| 系统 TTS | `app/lib/services/tts_service.dart`（`flutter_tts`） | 离线可用，音质取决于设备 | 0 |
| 服务端腾讯云 TTS | `backend/crates/api_server/src/tencent_tts.rs`（10.3 KB） | 在线，按量计费 | 0 |

方案设计的「360 MB Opus 预生成音频包 + CDN + manifest + chunk 分片 + 断点续传 + 优先下载 + 版本对齐」是一整套自建分发体系。**在决定背这个包袱之前，应该先花两天做三方音质 A/B 测试。** 如果端侧 sherpa 的英语单词语音可用，第六章可以整体消失（连带 §6.5、§6.6、§7.5 的语音包时序、以及 §14 关键约束里的 3 条）。

> 注意，这里有一个真实的不确定性：`matcha-zh-en` 是**中英双语**模型，英语音质对「单词发音」这种最需要音素清晰度的场景可能不够。这必须实测，不能拍脑袋。
> 折中方案见 §七：**单词音频预生成（约 40 MB），例句/搭配音频端侧实时合成** —— 把 360 MB 砍到 40 MB，同时保住最关键的单词音质。

---

## 一、评审方法

不凭设计文档，直接读代码与数据：

| 类别 | 实际读取 |
|---|---|
| 数据库 | `data/coevo.db` 逐表 `count(*)`、`users`/`card_memory`/`user_cards`/`subscription_plans` schema |
| 后端 | `backend/crates/**/*.rs` 72 文件 1.34 MB；`routes.rs` 路由注册；`schema.rs` 建表语句；`word_bank.rs`；`fsrs5.rs`；`tencent_tts.rs` |
| 前端 | `app/lib/**/*.dart` 74 文件 1.11 MB；`pubspec.yaml`；`tts_service.dart`；`sherpa_tts.dart`；`chat_reading_passage.dart` |
| 数据资产 | `data/curriculum/` 429 MB 全量枚举；`backend/cefr_catalog.json`（11.55 MB / 41,574 条）；`english_rebuild/` 全部文件 |
| 其他 | `marketing/` 1,635 文件 183.8 MB；`miniprogram/` 8.15 KB；`sherpa-models/` |

---

## 二、现状资产盘点

### 2.1 生产库（`data/coevo.db`）

45 张表，**有数据的只有 15 张**。非空表：

| 表 | 行数 | 说明 |
|---|---:|---|
| `prebuilt_cards` | 19,858 | 预制卡主表 |
| `prebuilt_language_cards` | 17,438 | 语言卡详情（english 12,839 / chinese 2,714 / japanese 1,787 / russian 98） |
| `prebuilt_science_cards` | 1,390 | 理科 —— 简化时要处理 |
| `prebuilt_literature_cards` | 836 | 文学 —— 简化时要处理 |
| `prebuilt_humanities_cards` | 194 | 文科 —— 简化时要处理 |
| `prebuilt_tasks` / `prebuilt_stages` / `prebuilt_plans` | 1,241 / 297 / 16 | 课程结构 |
| `app_config` | 5 | 运行时配置 |
| `subscription_plans` | 3 | 月度 ¥120 / 季度 ¥350 / 年度 ¥1280 |
| `users` | 2 | 均为 2026-06-25 注册的 `trial_xxxx`，无后续活动 |
| `conversations` / `conversation_turns` | 1 / 2 | 测试残留 |
| `tokens` / `admin_users` | 2 / 1 | — |

**全空的 29 张表**：`achievements, admin_audit_log, card_memory, card_relations, debug_logs, debug_trackers, distribution_commissions, distribution_withdrawals, guardian_assignments, k12_quiz_attempts, k12_quiz_bank, marketing_campaigns, payment_orders, plan_runs, referral_clicks, review_log, reward_fulfillments, settlement_batches, subscription_audit_log, subscription_requests, trial_ip_log, user_cards, user_humanities_cards, user_language_cards, user_literature_cards, user_notifications, user_plan_progress, user_preferences, user_science_cards`

> **这意味着：`card_memory`（FSRS 状态）、`user_cards`（用户卡）、`review_log`（复习日志）、`payment_orders`（支付订单）都是零。整个「用户学习数据」和「收入数据」层面是全新的。**

### 2.2 两个关键 schema 事实

**(a) `users` 表没有 `email` 字段**，用 `username`（并自动生成 `trial_<uuid前缀>`）。方案 §3.3 的 `app_user(email, password_hash)` 是全新设计 —— 可行，但用户体系要重建。

同时 `users` 表还挂着一整串 K12 家长实名 PII 字段，简化时应整块删除：
`real_name / phone / phone_hash / id_number / bind_hash / guardian_declarations`（配套 `encryption.rs` 5.7 KB AES-256-GCM 加密 + `bind-lookup` 限流 + 双步揭看 + 独立审计日志）

**(b) `card_memory` 与方案的 `card_review_state` 字段不一致**，不能直接复用：

```sql
-- 现状（7 个状态字段，时间是 epoch 整数）
CREATE TABLE card_memory (
  card_id TEXT PRIMARY KEY,
  user_card_id TEXT REFERENCES user_cards(id) ON DELETE CASCADE,
  state INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','pending','skipped','archived')),
  difficulty REAL DEFAULT 5.0,
  stability REAL DEFAULT 0.0,
  due INTEGER DEFAULT 0,          -- ← epoch 整数，非 ISO 文本
  last_review INTEGER,
  reps INTEGER DEFAULT 0,
  lapses INTEGER DEFAULT 0
);
```

方案 §3.2 的 `card_review_state` 有 12 个字段（`fsrs_stability` / `fsrs_difficulty` / `fsrs_elapsed_days` / `fsrs_scheduled_days` / `next_review_at` IS0 文本 / `pending_push` …）。
且 `difficulty` 现值域是 **5.0**（FSRS-4.5 风格），方案沿用 FSRS-5 —— 默认值应当不同。

**结论**：说「复用现有 FSRS」是可以的（算法实现 `fsrs5.rs` + `fsrs_scheduler.rs` 共 45.8 KB 是资产），但**状态表是重写而不是复用**，方案需明确给出字段映射，否则实现时会出现两套状态各行其是。

### 2.3 后端 API 面

`routes.rs` 注册 **177 条路由**：

| 前缀 | 条数 |
|---|---:|
| `/api/**` | 168 |
| `/share/**` `/go/**` | 3 + 3 |
| `/ws` `/health` `/app` | 1 + 1 + 1 |

其中 **`/api/admin/**` 有 99 条（占 56%）**，`/api/auth/**` 只有 5 条。

→ 简化后「认证 + 同步 + 词库外制卡 + 语音包」大约对应 **10~15 条路由**。**API 面从 177 条砍到 15 条**，这是简化的主要收益之一。

### 2.4 语料/内容资产

| 资产 | 规模 | 可用性 |
|---|---|---|
| `data/curriculum/english_rebuild/` | 12,791 vocab 卡 + 74 阅读型卡（dialogue / narrative / poem / letter / report / speech / play / biography / opinion / instruction / review / nursery_rhyme）+ **80 篇分级课文** A1–C1 | ✅ 可直接用 |
| `english_rebuilt_plan.json` | 684 KB，stages→tasks + `prompt_mode: english/reading-primary` + card_ids | ✅ 可直接用 |
| `backend/cefr_catalog.json` | 11.55 MB / **41,574 条**，其中 **20,886 条（50.2%）无 `cefr_level`** | ⚠️ 一半没分级 |
| CEFR 分布（english_rebuilt，12,791 词） | A1 1,416 (11%) / A2 1,817 (14%) / B1 3,594 (28%) / **B2 4,917 (38%)** / **C1 1,127 (9%)** | ⚠️ 见 §五-B1 |
| 词根 / 词源 / 同源数据 | **0** | ❌ 从零 |
| `marketing/` | 1,635 文件 / 183.8 MB | 待决策 |
| `miniprogram/` | 8.15 KB / 13 文件（占位） | 非有效渠道 |

### 2.5 客户端平台

`app/` 下 `android` / `ios` / `web` / `windows` / `linux` / `macos` **六个平台目录齐全**，另有 `.hvigor`（鸿蒙）。原生 App 路线技术上可行。
`pubspec.yaml` 已含 `sherpa_onnx ^1.13.2`、`flutter_tts ^4.2.2`、`audioplayers ^6.1.0`、`path_provider`。

---

## 三、方案逐章评估

| 章 | 内容 | 评级 | 说明 |
|---|---|:--:|---|
| 一 | 产品概述 | 🟡 | 定位清晰，但「目标用户是谁」未定义，直接影响词表与记忆法选择（见 §五-B1） |
| 二 | 整体架构 | 🟢 | 离线优先 + 云兜底的边界划分正确 |
| 三 | 数据层 | 🔴 | 有 3 处 DDL 自相矛盾；与现有 `prebuilt_cards` 体系重叠未处理；`word_id` 分配机制缺定义 |
| 四 | 记忆法与制卡 | 🔴 | 优先级阶梯与实测词表分布**完全错配**；priority 1/2 数据从零 |
| 五 | 一页容量控制 | 🟢 | 合理。与项目既有卡片质量评估结论一致 |
| 六 | 语音包 | 🟠 | 技术方案完整，但**可能是无效复杂度** —— 现有 3 套 TTS 未评估 |
| 七 | 离线优先与同步 | 🔴 | 「服务器权威 / updated_at 合并 / 用户选择」三种语义叠加；`review_log` 无幂等键；被踢出后离线数据归属未定义 |
| 八 | 制卡与语音生成流程 | 🟡 | 流程清晰，§8.4 有 SQL 语法级 bug |
| 九 | 用户查词流程 | 🔴 | **词库外生词无法进入生词本和复习队列**（数据结构不支持） |
| 十 | FSRS 调度 | 🟡 | 算法可复用，状态表要重写（见 §2.2b） |
| 十一 | 技术选型 | 🟠 | PostgreSQL 对 2C1G VPS 是过度设计；词源数据授权未评估 |
| 十二 | 边界情况 | 🟡 | 覆盖了大部分场景，遗漏「被踢出期间离线数据」等关键项 |
| 十三 | 实施路线 | 🟡 | Phase 划分合理，但 Phase 1 其实不需要后端，可进一步前置 |
| 十四 | 关键约束汇总 | 🟡 | 约束 1（id 永久稳定）只有断言、没有机制 |

---

## 四、阻塞级问题（6 条）

### 🔴 阻塞 1：词库外生词**无法进入生词本，也无法进入复习队列**

**证据**（方案自身 DDL 互相冲突）：

```sql
-- §3.2 生词本
CREATE TABLE user_word (
  word_id INTEGER NOT NULL,   -- ← NOT NULL，且是 word 表外键
  ...
  UNIQUE (word_id)
);

-- §3.2 复习状态
CREATE TABLE card_review_state (
  card_id INTEGER NOT NULL,   -- ← NOT NULL
  ...
  UNIQUE (card_id)
);
```

而 §9 的流程是：

```
未命中 → 查 external_word_cache → 命中则显示缓存卡片
        └ 未命中 → 联网 LLM 制卡 → 写入 external_word_cache → 显示
```

**词库外生词既没有 `word_id`，也没有 `card_id`** —— 它只存在于 `external_word_cache(spelling, card_content)`。
结果：查完一个词库外的词，**它进不了生词本，也排不进复习队列，下一个复习周期就消失了**。
这与 §1.2 核心流程图「词库外生词 → LLM 兜底制卡」暗示的「进入学习闭环」直接矛盾。

**影响**：核心流程断链。用户读到一篇有生词的文章，最需要记的恰恰是词库外那些词。

**修复选项**：

- **选项 A（推荐）**：复用项目已验证的 `user_cards` 模式。现状 `user_cards` 已有 `prebuilt_card_id` 外键 + `id TEXT PRIMARY KEY` + 域子表（`user_language_cards`）的设计，天然支持「用户自己的卡」。让词库外词也生成一条 `user_cards` 记录（`prebuilt_card_id = NULL`），`card_review_state.card_id` 指向它即可。
  - 优点：复用已验证结构；一个复习队列统一处理两种来源；现网 `user_cards` / `user_language_cards` 表已存在且为空，零成本改造。
  - 代价：`word_id` 需允许 NULL，或引入 `word_id = NULL` 语义。
- **选项 B**：给 `word` 表预留高位 id 段（如 `id >= 900000000`）给词库外词，联网时在本地 `word` 表补一条记录。
  - 优点：`user_word` / `card_review_state` 的 NOT NULL 约束全部不用改；统一走一套 id。
  - 代价：需定义高位段与官方增量 id 的冲突规则；离线包升级时必须保证永不复用该段。
- **选项 C**：接受现状，词库外词**只查询不记录**。
  - 优点：零改动，方案最小。
  - 代价：必须把 §1.2 的核心流程图改掉，并接受「词库外词用完即忘」；LLM 兜底制卡的价值大幅降低。

---

### 🔴 阻塞 2：DDL 自相矛盾，按方案原文建表会直接报错

**(a) `ON CONFLICT (word_id)` 没有对应的 UNIQUE 约束**

```sql
-- §3.1.2 建表：word_id 上只有普通索引
CREATE INDEX idx_card_word ON card (word_id);

-- §8.4 更新：却按 word_id 做冲突处理
INSERT INTO card (word_id, template_code, content, content_hash)
VALUES ($1, $2, $3, $4)
ON CONFLICT (word_id)   -- ← SQLite: "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint"
DO UPDATE SET ...
```

**(b) `content_hash TEXT UNIQUE` 过于严格**

`content_hash` 全局唯一意味着：两个不同单词如果生成了**内容相同的卡片**（例如都退化成「仅释义」的降级卡，§12 明确有这个场景），第二条插入会失败。
应改为 `UNIQUE (word_id, content_hash)` 或去掉 UNIQUE 只留索引。

**修复选项**：
- **选项 A**：`card.word_id` 加 `UNIQUE`（严格一词一卡，与 §1.3「一词一卡」一致）+ `content_hash` 去掉 UNIQUE。改动最小，语义最清晰。
- **选项 B**：保留 `ON CONFLICT` 改为按 `card.id` 处理，`word_id` 只留索引。适合未来可能一词多卡的演化。

---

### 🔴 阻塞 3：`word_id` / `card_id`「永久稳定」只有断言，没有机制

§14 约束 1 和 §3.1.1 都强调 `word_id` 一旦分配永久不变、预制库升级只追加不删改。但方案**没有定义分配机制**：

- 谁分配 id？离线批处理脚本？多人/多次运行如何避免撞号？
- 「新词追加」如何保证不与已有 id 冲突？
- 卡片 `card` 表的 id 与 `word` 表的 id 是否同源？
- 如果一次批处理失败重跑，id 是否重排？（这会立刻破坏稳定性）

**这是整个离线包体系的地基** —— 地基没有设计，上面 14 章都会晃。

**修复选项**：
- **选项 A（推荐）**：维护一张冻结的 **id 分配台账**（`word_id_ledger`：`lemma → word_id`，随包发布、只增不改），批处理只能「查台账 → 命中则复用 → 未命中则取 `max(id)+1` 并立即写回台账」。台账进 Git，可审计、可 diff。
- **选项 B**：改用方案现有的**稳定字符串 id**。项目现网 `prebuilt_cards.id` 就是 UUID（如 `29bb1285-887d-4901-a835-0c6ba1d54cca`）。UUID 天然稳定、天然无撞号、离线包增量合并零冲突。
  - 优点：不需要台账机制，**直接沿用现网风格**；`card.content_hash` 也不需要承担唯一性职责。
  - 代价：id 不连续，不利于「按 word_id 分片」（§6.5.1 的 `chunk_0000 = word_id 1–2000`）。可另加一个 `sort_seq` 整数列专供分片排序。
- **选项 C**：混合 —— 内部仍用 INTEGER 自增，但以 `lemma` 为业务主键（已是 `UNIQUE (lemma)`），任何跨包引用都走 `lemma` 而非 id。

> 附带提醒：§3.1.1 说「预制库升级时新词追加，**旧词不删不改 id**」—— 但「旧词不删」与 §14 约束 1 是重复表述；真正要明确的是**旧词的 `cefr_level` / 释义能否修订**。如果能，那 `card` 覆盖更新（§8.4）逻辑要能算出「哪些用户的卡需要重新生成」。

---

### 🔴 阻塞 4：技术栈冲突 —— PostgreSQL 对 2C1G VPS 是过度设计

§11 技术选型写「服务端数据库：PostgreSQL」。但：

- 现网后端是 **Rust + rusqlite（SQLite）**，`db_pool.rs` 是 SQLite 连接池
- 部署环境是 **2 核 1 GB 内存**的腾讯云 VPS，1 GB RAM 下编译都要 `-j 1` 防 OOM
- 方案里服务端**只存 4 类数据**：用户/会话（小）、用户学习数据（小）、LLM 制卡全局缓存（中）、语音包版本元数据（极小）

让 PostgreSQL 与 Rust 后端在同一台 1 GB 机器上共存，内存压力是实际风险（PostgreSQL 默认配置就会尝试占用数百 MB 共享缓冲）。而方案的数据量根本用不到 PostgreSQL 的任何特性。

**修复选项**：
- **选项 A（推荐）**：服务端继续用 **SQLite**，与现网一致，零运维新增。方案里所有 `JSONB` 改成 `TEXT` + JSON 序列化即可（现网 `prebuilt_language_cards.definitions` 就是这么存的，已跑通）。
- **选项 B**：若未来确有多写并发需求，升级 VPS 到 2C2G 再引入 PostgreSQL —— 但这是**独立的扩容决策**，不应该捆绑在简化项目里。

---

### 🔴 阻塞 5：完全没有合规章节

方案 14 章没有任何合规讨论，但产品形态触发了至少 4 项：

| 项 | 触发原因 | 方案状态 |
|---|---|---|
| **ICP 备案 / 应用市场软著** | 有云端服务 + 要上应用商店 | ❌ 未提 |
| **个人信息保护法** | 收集邮箱 + 密码 | ❌ 未提（现网 `users` 表还存 real_name/phone/id_number，简化时应删除并说明） |
| **未成年人模式** | 英语学习类 App 的常规要求；现网有 `guardian_assignments` + `guardian_declaration` 字段说明历史上做过 | ❌ 未提 |
| **用户上传内容审核** | §3.2 `article` 表允许用户存 `source_url` + `content`（用户可粘贴任意文章） | ❌ 未提。用户导入的文章是 UGC，平台有审核义务 |
| **付费订阅合规** | 现网已有微信支付 Native + 订单 + 结算体系 | ❌ 方案里**完全没有支付相关表** |

**修复选项**：
- **选项 A**：补一章《合规与分发》，明确：备案主体、目标商店、未成年人策略、用户上传内容是否只存本地（若 `article` 仅存本地不上传，UGC 审核义务大幅降低 —— 这是最优解，且与「离线优先」天然契合）。
- **选项 B**：把合规拆成独立前置项目，在本方案里只标注「依赖项 + 阻塞关系」。

> 顺带一个**必须由你决定**的业务问题：现网 `subscription_plans` 有 3 档（¥120/¥350/¥1280），配套 `marketing_campaigns` / `distribution_commissions` / `settlement_batches` / `referral_*` 一整套分销结算，加上 `marketing/` 目录 **183.8 MB / 1,635 个文件**的素材。方案的 schema 里**一张支付表都没有** —— 即简化后**没有收入模型**。这是有意的（先做产品）还是遗漏？见 §八。

---

### 🔴 阻塞 6：分发渠道未定义 —— **这条决定整个技术路线**

方案的每一章都假设「用户安装 App」：初装 50–80 MB、后台异步下载 360 MB 语音包、端侧 SQLite、后台下载管理器、断点续传。**这是一套原生移动 App 的假设**，但方案从未说明：

- 分发到哪个渠道？App Store / 各安卓商店 / 自有下载页？
- 现有 Flutter Web 版（部署在 `http://<OLD_VPS_IP>/app/`，Nginx `/app/` location）**保留还是废弃**？
- iOS 是否要支持？（`app/ios` 目录存在，但 iOS 上架需要开发者账号 + 审核）
- 是否仍要走微信生态？

**为什么这条最致命**：不同渠道对「全量词库打包」的容忍度天差地别。

| 渠道 | 主包限制 | 「50–80 MB 内置词库 + 360 MB 音频」是否可行 |
|---|---|---|
| 原生 App（App Store / 安卓商店） | 无硬限制（iOS 蜂窝下载提示阈值 ~200 MB） | ✅ 可行 |
| 微信小程序 | 主包 **2 MB**，总包 **20 MB** | ❌ **完全不可行** |
| Flutter Web | 首屏加载即下载 | ❌ 50 MB 首屏不可接受 |

方案 §14 约束 8「不分档下载：全量词库打包进 App」是一条**只有在原生 App 路线下才成立**的约束。

**修复选项**：
- **选项 A（推荐）**：明确**原生 App 优先**（Android 先行，iOS 后置），Flutter Web 版**冻结**（停止维护，保留线上可用），小程序/微信生态**放弃**。方案其余章节按此前提成立，无需改动。
- **选项 B**：若必须保留微信生态 → 词库必须**分包 + 按需下载**（首包只带 A1–B1 的 3,527 词 ≈ 15 MB，其余按 CEFR 级别增量拉取）。这会推翻 §1.3「词库不分档」和 §14 约束 8，需要重写数据处理与分发章节。
- **选项 C**：只做 Flutter Web（沿用现有部署） → **离线优先整个卖点不成立**，方案需要重写。

> 补充事实：`miniprogram/` 目录只有 **8.15 KB / 13 个文件**，是占位骨架，不构成有效渠道。

---

## 五、重要设计问题（6 条）

### 🟠 B1：记忆法优先级与实测词表分布**完全错配**

方案 §4.1 的阶梯：`1 词根词缀 → 2 同源串记 → 3 搭配整记 → 4 词源故事 → 5 联想图像 → 6 语境原句`。

两个实测事实打破了这个排序：

**(a) priority 1 和 2 的数据是零。** 全仓库搜索 `etymology` / `word_root` / `cognate` / `root_family` → **0 个文件命中**。而 priority 3（`related_phrases`，97.7% 覆盖）和 6（`example`，93.4% 覆盖）**已经现成**。

**(b) 词根词缀对低级别词几乎不适用。** 英语基础词大量是日耳曼语源单音节词（be / happy / in / get / make），没有可分解的拉丁词根。实测词表分布：

| CEFR | 词数 | 占比 |
|---|---:|---:|
| A1 | 1,416 | 11.1% |
| A2 | 1,817 | 14.2% |
| B1 | 3,594 | 28.1% |
| B2 | 4,917 | 38.4% |
| C1 | 1,127 | 8.8% |

→ **A1+A2 只占 25%，B2+C1 占 47%。**

**这里有一个需要你回答的产品问题**：目标用户是谁？
- 若是**成人零基础 / 兴趣学英语** → 现有词表 B2-C1 占 47%，**前 3 个月几乎全是「不需要学」的词**，产品会劝退新手。
- 若是**高考 / 四六级 / 考研 / 雅思** → B2-C1 主导正合适，词根词缀也确实是这部分词的记忆主力。

**建议**：
- 短期（立刻可做）：制卡优先级改为 **`搭配(3) → 语境(6) → 释义`**，今天就能上线 12,839 张可用卡；
- 中期：补词根/同源数据后再把 priority 1/2 插到前面；
- 若面向零基础：需要**重新补 A1/A2 词表**（现有 A1 1,416 词明显不足，CEFR-J A1 词表实际约 1,500–2,000 词，加上 Oxford 3000 的 A1 段应更厚）。

---

### 🟠 B2：同步模型内部有三种互相冲突的语义

| 出处 | 语义 |
|---|---|
| §7.1 | 「单写者 + **服务器权威**」；本地是工作副本 |
| §7.5 离线恢复时序 | 「`GET /sync/pull` → **按 updated_at 合并**」 |
| §12 | 「首次登录本地已有数据 → **提示用户选择**：上传到云端 / 以云端为准」 |

「服务器权威（pull 直接覆盖）」和「按 updated_at 合并（双向归并）」是两种不同的同步模型，不能同时成立 —— 实现时必须二选一，否则会出现「合并后又被告知以云端为准」的矛盾行为。

配套的三个具体缺陷：

1. **`review_log` 缺幂等键**。本地 `id INTEGER PRIMARY KEY AUTOINCREMENT`，服务端 `id BIGSERIAL`。离线期间本地产生 id 1..500，推送后服务端再分配 1..500，若重试推送就会**重复插入**。需要 `(user_id, client_id)` 或 `(user_id, card_id, reviewed_at)` 级别的去重键。
2. **`lookup_event` 只有本地表**，服务端 §3.3 没有对应表。是「刻意不上传」还是遗漏？需明确（如果是刻意，应在此注明并说明统计口径）。
3. **`article` 软删同步语义缺失**。本地和远端都有 `deleted` 标志，但 pull 时无法区分「远端删了」和「本地新增未推送」—— 缺少 `updated_at` 的比较规则与时钟偏差处理。

**建议**：MVP 只做**单向覆盖 + 只推不合并**：登录 → 全量 pull（覆盖本地）→ 之后本地写入以 `pending_push` 批量推送、服务端 UPSERT 按 `updated_at` 取新。**不做双向归并、不做冲突提示**。这三种语义里选最简单的一种，其余两处措辞全改。

---

### 🟠 B3：单端登录「踢旧」破坏了离线优先的核心卖点

§7.2 单端登录：新设备登录踢掉所有旧会话。§12：「离线时被踢出 → 恢复网络后 401，提示用户，保留本地数据」。

问题是：**离线优先产品的用户会离线好几天**。用户出差一周，在地铁上做了 300 次复习、查了 80 个词，全部只写了本地 `user.db`。回家联网 → 401 → 方案只说「停止写入，提示」。
**这 300 条复习记录和 80 个生词怎么办？** 方案没有定义。可能的后果：一周学习记录作废、FSRS 状态倒退一周、用户直接流失。

**修复选项**：
- **选项 A（推荐）**：放宽为**多会话共存**（允许 N 个活跃 session 或仅踢同平台同设备模型），把「单端」从登录策略降级为「展示提示」（例如「检测到其他设备登录，是否继续？」）。
- **选项 B**：保留单端踢旧，但定义**被踢设备的离线数据合并协议**：恢复网络后允许一次「只读 + 上报」窗口，把离线期间的 `card_review_state` / `review_log` 按 `updated_at` UPSERT 上去，之后再锁定。
- **选项 C**：保留单端踢旧且不合并，但**本地弹窗 + 导出**：允许用户导出本地复习记录为文件，客服侧手工恢复。

> 附带：现网 `docs/research/multi-device-login-analysis.md` 已有过这个专题分析，建议先读。

---

### 🟠 B4：聚合页「无容量上限」需要分页设计

§3.1.6 / §5.1 说聚合页无容量约束。但 §4.3 的 `cognate_list.items` 是无界数组 —— 一个高产词根（如 `-ceive` / `-ject` / `pre-`）的家族可能上百词。作为一页 JSON 直接渲染会卡。

**建议**：`aggregate_page.content` 的 `items` 需带 `total` 与分段策略，UI 侧按需展开。或者约定单页最多 50 条 + 「查看全部」二级页。**「无容量上限」应改为「无 section 数上限，但单次渲染条目有上限」。**

---

### 🟠 B5：容量估算偏乐观，且只算了体积没算体验代价

§6.4 按 Opus 24 kbps 估算：

| 项 | 方案估算 | 复核 |
|---|---|---|
| 单词（~3 KB） | 2 万 → 60 MB | ✅ 合理（1 秒 ≈ 3 KB） |
| 例句（~12 KB） | 2 万 → 240 MB | ⚠️ 12 KB ÷ 24 kbps ≈ **4 秒**。多数例句朗读超过 4 秒，实际应约 15–20 KB → **300–400 MB** |
| 搭配（~6 KB） | 1 万 → 60 MB | ⚠️ 同上，偏乐观 |
| 合计 | ~360 MB | **实际可能 450–550 MB** |

另外，24 kbps 单声道对**语音教学**偏保守 —— 学习者最需要的是音素清晰度。建议 32–48 kbps（单词音频体积代价很小：2 万 × 4 KB = 80 MB）。

**方案还漏算了三项体验代价**：
1. 卸载重装需重下 400+ MB
2. 移动网络下用户是否愿意等（§6.5.2 有 Wi-Fi only 选项 ✅，但未说明移动网络下的降级体验）
3. **iOS 蜂窝下载 200 MB 提示阈值** → 360+ MB 必然触发系统警告，用户拒绝率会很高

---

### 🟠 B6：词源/构词数据的**授权未评估**（潜在法律阻塞）

§11 技术选型列了 `WordNet / MorphoLex`（构词分析）和 `Etymonline / Wiktionary`（词源数据），但没有做授权分析。这几项性质差异很大：

| 数据源 | 授权性质 | 商业化风险 |
|---|---|---|
| WordNet | 类 BSD 宽松许可 | 🟢 低 |
| Wiktionary | CC BY-SA | 🟡 需署名 + 传染性（衍生作品需同许可） |
| MorphoLex | 学术授权，通常需引用 + 申请 | 🟠 需核实商用条款 |
| **Etymonline** | 由 Douglas Harper 个人编纂，**有版权的原创作品**，商用再分发需取得许可 | 🔴 **高风险，必须核实** |

**建议**：在决定「priority 1 = 词根词缀」之前，**先确认数据来源与授权**。否则可能出现「批处理跑了 3 周、卡片已生成、法务说不能用」的最坏情况。
替代路径：用 LLM 生成构词分析（成本可控、无授权问题、但要处理幻觉）—— 这也是现有 `english_rebuild` 的既有做法（Phase 2 用 LLM 给 6,066 个词做 CEFR 分级，成功率 99.4%）。

---

## 六、遗漏与优化（10 条）

| # | 项 | 说明 | 建议 |
|---|---|---|---|
| C1 | **现有 `prebuilt_*` 体系的去留** | 方案 §3.1 的 `word`/`card` 建模与现网 `prebuilt_cards` + `prebuilt_language_cards` **功能重叠**。不明确处理会留下两套词库 | 明确选「演进现有」或「新建并删除旧的」，二选一，不要并存 |
| C2 | **`level` 空值 1,885 条** | `prebuilt_language_cards.level` 有 1,885 条为空，CEFR 分级/难度排序有洞 | 用 LLM 回填（`english_rebuild` 已有成熟做法） |
| C3 | **`definitions` 空数组 786 条** | 786 张英语卡 `definitions = []`，是无内容卡 | 补齐或从词表剔除 |
| C4 | **`word_bank.rs` 是全表扫** | `match_text()` 每次调用遍历全部 41,574 词条（`for (id, entry) in catalog.iter()`）。方案要做「画线查词」高频交互，这个实现撑不住 | 方案 §3.1 有 `idx_word_spelling` 索引，方向对；但需明确**废弃 `word_bank.rs` 的全表扫描路径**，改为 SQL 索引查询 |
| C5 | **`cefr_catalog.json` 一半没分级** | 41,574 条中 20,886 条（50.2%）无 `cefr_level`；方案假设「CEFR 全量 1.5–2 万词族 / 3–5 万词形」 | 明确词表口径：是 12,839（已分级、已有卡）还是 41,574（有词无卡） |
| C6 | **`word.db` 增量更新缺失** | 预制库只在端侧（服务端无 `word`/`card` 表）→ 改一张卡就要发版。§8.4 的「按 id 直接覆盖、全用户同步新版本」实际上做不到 | 若要热更新，需增加「`word.db` 差分包下载」机制（复用语音包的 manifest 框架即可）；若接受发版，需在 §14 明确写「卡片内容更新需发版」 |
| C7 | **可观测性全砍** | 现网有 `debug_logs` / `debug_trackers`（配套 `debug_logger.rs` / `debug_trackers_cache.rs`）+ `admin_audit_log` + `app_config`（5 条运行时配置）。方案全砍 | 至少保留 `app_config`（远端开关）和一份最小日志上报，否则线上问题无法定位。与既有的防御性/可观测习惯冲突 |
| C8 | **Phase 1 其实不需要后端** | §13 Phase 1「单机可用，无联网」—— 那 MVP 完全不需要部署后端 | 建议把整个后端后置到 Phase 2，MVP 只发端侧。2C1G VPS 也不用动 |
| C9 | **多语言数据残留** | 现库还有 chinese 2,714 / japanese 1,787 / russian 98 / literature 836 / science 1,390 / humanities 194 | 若确定只做英语，这些数据应清出离线包 —— **直接减小 `word.db` 体积约 30%**（19,858 → 12,839 卡） |
| C10 | **PII 加密体系可整块删除** | `encryption.rs`（AES-256-GCM）+ `bind-lookup` 限流 + 双步揭看 + `bind_hash` 匹配 + `guardian_assignments`，全部服务于 K12 家长实名 | 这是**净减法**，简化时可整块删除，同时减少合规表面积 |

---

## 七、简化收益清单（按节省量排序）

| # | 可砍模块 | 规模 | 节省 | 前提/风险 |
|---|---|---|---|---|
| 1 | **语音包 CDN 自建体系** | §6 全部 + §6.5/6.6 + §7.5 时序 + §14 约束 10/11/12 | 省掉最大一块工程 + 400 MB 分发成本 | ⚠️ 依赖三方 TTS 音质 A/B 测试结果 |
| 2 | **PostgreSQL** | §11 | 省运维 + 保护 1 GB RAM | 服务端继续 SQLite（与现网一致） |
| 3 | **营销/分销/结算体系** | 约 20 张表 + `marketing/` 183.8 MB + 大量 admin 路由 | 极大 | ⚠️ **这是收入引擎**，砍掉 = 放弃变现，需你决策 |
| 4 | **K12 多学科** | science 1,390 + literature 836 + humanities 194 + chinese/japanese/russian 4,697 卡；`subject_router` / `k12_quiz*` / `guardian_assignments` | 中 | 需确认无 K12 付费用户（实测：0 用户数据） |
| 5 | **管理员后台** | 99 / 177 条 admin 路由 | 中 | 需保留最小运维入口（配置 + 用户查询） |
| 6 | **多设备同步复杂语义** | §7.5 全部时序 + §12 部分 | 中 | MVP 用「只推不合并」替代 |
| 7 | **PII 加密 + 实名体系** | `encryption.rs` + `bind_hash` + 审计 | 小但清净 | 合规表面积同时减小 |

**API 面**：177 → 约 15 条
**数据库表**：45 → 约 12–15 张

### 关于音频的推荐折中方案

在不做 A/B 测试的前提下，建议采用**分级策略**，把 360 MB 砍到约 40 MB：

| 音频类型 | 数量 | 方案 | 体积 |
|---|---:|---|---|
| **单词发音** | 12,839 | **预生成**，较高码率（32–48 kbps）—— 最需要音素清晰度 | ~50 MB（可接受） |
| 例句朗读 | ~12,000 | **端侧 sherpa 实时合成**（已有实现） | 0 |
| 搭配朗读 | ~12,000 | **端侧 sherpa 实时合成** | 0 |
| 词库外生词 | 无限 | 端侧合成 / 在线 TTS 兜底 | 0 |

这样：保住最关键音质、消掉 CDN + manifest + chunk + 断点续传 + 版本对齐整套机制、安装体积从 420 MB 降到约 130 MB（含 125 MB sherpa 模型 —— 若用系统 TTS 则再降）。

---

## 八、需要你决定的四个 gating 决策

这四项不定，下面所有实施细节都会返工。

### 决策 1：分发渠道（**最高优先级**）
- **A（推荐）** 原生 App 优先（Android 先行，iOS 后置），Flutter Web 冻结，放弃微信生态 → 方案现有假设成立，无需改动
- **B** 必须保留微信生态 → 词库必须分包按需下载，需重写 §1.3 / §三 / §六
- **C** 只做 Flutter Web → 离线优先不成立，方案需重写

### 决策 2：目标用户
- **A** 成人零基础 / 兴趣学英语 → **现有词表不合格**（B2-C1 占 47%，A1 仅 1,416 词），需补 A1/A2 词表，且记忆法应以联想/语境为主
- **B** 高考 / 四六级 / 考研 / 雅思 → 现有 12,839 词表正好，词根词缀路线成立
- **C** 两者都要 → 需要词表分层 + 两套默认记忆法排序

### 决策 3：变现去留
- **A** 暂时不要收入，先把产品做出来（方案现状）
- **B** 保留订阅（¥120/¥350/¥1280 三档 + 微信支付 Native）→ 需在方案里补回支付表与流程
- **C** 保留订阅 + 分销 → 需保留大部分营销表与 admin 后台，简化幅度大幅降低

### 决策 4：音频方案
- **A（推荐）** 三方音质 A/B 测试（端侧 sherpa / 系统 TTS / 预生成包）→ 再定，约 2 天
- **B** 直接采用「单词预生成 + 例句端侧合成」折中方案（约 40 MB）
- **C** 按方案原样做 360 MB 语音包（保留最高音质，但接受 420 MB 安装体积与 CDN 成本）

---

## 九、建议的修正后实施路线

```
Phase 0（决策 + 验证，约 1 周）
  ├── 决策 1~4 拍板
  ├── 音频三方 A/B 测试（决定 Phase 1 是否包含预生成音频）
  ├── 词源数据授权核实（决定 priority 1/2 是否可行）
  └── 复用决策：prebuilt_cards 演进 or 新建 word.db（二选一）

Phase 1（MVP，纯端侧，不碰后端）
  ├── 现有 12,839 词的卡片按 搭配 → 语境 → 释义 重排上线（数据已就绪）
  ├── 阅读器 + 画线查词（SQL 索引查询，废弃 word_bank.rs 全表扫）
  ├── 生词本 + 端侧 FSRS（重写状态表，字段按方案 §3.2）
  ├── 80 篇分级课文接入（数据已就绪）
  ├── 音频：按决策 4 落地
  └── 目标：单机可用，零后端依赖

Phase 2（云端）
  ├── 认证 + 会话（先用「只推不合并」，同步语义收敛为一种）
  ├── 增量 pull/push + review_log 幂等键
  ├── 词库外生词：走 user_cards 模式接入复习队列（阻塞 1 的修复）
  └── 可观测性最小集（app_config 远端开关 + 日志上报）

Phase 3（兜底与增强）
  ├── LLM 制卡 + 全局缓存
  ├── 词根/同源/词源数据（授权确认后）
  ├── 聚合页
  └── word.db 增量更新（如需热更卡片）

Phase 4（优化）
  └── 阅读-复习联动 / 难度自适应 / 错误类型分析
```

**与原方案 §13 的主要差异**：① 增加 Phase 0 决策与验证；② Phase 1 明确「不碰后端」并**优先上线已有数据**（而非等词根数据齐备）；③ 把「词库外生词接入复习队列」提前到 Phase 2（原方案未处理）；④ 把词根/同源数据后移到 Phase 3（原方案列为 priority 1，但实际上还没有数据）。

---

## 十、方案中明确值得保留的部分

这些设计是对的，简化时不要动：

1. **离线优先 + 端侧 FSRS 调度** —— 与「复习必须随时可用」的产品本质匹配
2. **预制卡为主 + LLM 兜底** —— 成本可控、体验确定
3. **一页容量上限（4 sections / 300 字 / 单 section 100 字）** —— 与项目既有卡片质量评估结论一致
4. **聚合页不进复习队列** —— 正确的信息架构（查询 vs 记忆分离）
5. **只朗读纯英文文本**（`is_english_only` 判据）—— 对
6. **一词一卡（UI 层原则）** —— 对，降低了认知负荷
7. **卡片内容固化** —— 对，消除了「每次复习卡片都不一样」的不确定性
8. **卡片覆盖更新时用 `content_hash` 判断是否重新生成音频** —— 对，是正确的增量策略
9. **`ON CONFLICT ... DO UPDATE` 的幂等 upsert 思路** —— 对（只需修 DDL 约束）
10. **§7.4 的 API 面** —— `/auth/*` + `/sync/pull|push` + `/generate-card` + `/audio/*` 八个端点，克制且合理

---

## 附：评审证据索引

| 结论 | 证据位置 |
|---|---|
| 45 表 / 29 空 / 用户数据为 0 | `data/coevo.db` 逐表计数 |
| `users` 无 email、含 K12 PII 字段 | `users` 建表语句 |
| `card_memory` 字段与方案不一致 | `card_memory` 建表语句 |
| 177 路由 / 99 admin | `backend/crates/api_server/src/routes.rs` |
| 英语 12,839 卡内容完整度 | `prebuilt_cards` × `prebuilt_language_cards` 联接统计 |
| 词根/同源/词源数据为 0 | `data/curriculum/**/*.json` 关键字搜索 |
| 80 篇分级课文已就绪 | `data/curriculum/english_rebuild/phase3_passages.json`（257,675 字符，metadata 显示 80/80） |
| 端侧 TTS 已实现 | `app/lib/services/sherpa_tts.dart` + `app/pubspec.yaml`（`sherpa_onnx ^1.13.2`） |
| 三套 TTS 并存 | `sherpa_tts.dart` / `tts_service.dart` / `backend/crates/api_server/src/tencent_tts.rs` |
| `word_bank.rs` 全表扫描 | `backend/crates/chat_engine/src/word_bank.rs:111` |
| sherpa 模型 125 MB | `sherpa-models/model-steps-3.onnx` 72.21 MB + `vocos-16khz-univ.onnx` 51.39 MB |
| 六平台目录齐全 | `app/{android,ios,web,windows,linux,macos}` |
| 小程序为占位 | `miniprogram/` 总 8.15 KB / 13 文件 |
| 营销资产 183.8 MB | `marketing/` 目录统计 |

---

*报告完。本报告只做评审与方案建议，未修改任何代码或生产环境。*
