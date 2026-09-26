# 仓库清理盘点报告

> 日期：2026-09-27 02:15
> 触发：白哥「对本地目录做一次清理，有太多废弃的历史文件在仓库里了，仓库太不干净。K12相关脚本都清理掉」
> 状态：🟡 **A 类已授权执行** · B/C/D/E 待拍板

---

## 〇、先说三个「差点删错」的发现

调查里最值钱的不是「能删什么」，而是**看起来该删、其实不能删**的东西：

| # | 对象 | 看起来 | 实际 |
|---|---|---|---|
| **1** | `scripts/split_inline_chinese.py` | 名字含 `chinese` → 像 K12 中文科 | 🔴 **是英语词库清洗脚本**（修「乙型空壳卡」：把英文释义里的括号中文提取到 `chinese` 字段，实测修 **230 条**）。**必须保留** |
| **2** | `data/curriculum/prebuilt/` | 整个目录像 K12 数据 | ⚠️ **混着英语词库产出**（`cefr_j/` · `word_form*` · `etymon*` · `affix*` · `collocation*`）—— 记忆明确「`word_form.json`（36,856）**不能删**」 |
| **3** | `backend/crates/api_server/src/k12_quiz*.rs` | 名字含 k12 → 像废弃代码 | 🔴 **是活代码**：在 `lib.rs` 声明、`routes.rs` 注册 **5 个 API 路由**、`plan_handler.rs` 调用、前端 `home_screen` 引用 → **删了会编不过** |

> 🔑 **教训：不能按「目录名 / 文件名含 K12」来定范围**（skill `safe-bulk-deletion` 铁律 1：范围按**引用图**界定）。

---

## A 类：K12 脚本 ✅ **已授权 · 引用图验证通过**

**引用图结果**：全部 **0 处代码引用**（只在自己内部或已归档文档里被提及）

| 文件 | 行数 | 说明 |
|---|---:|---|
| `scripts/card_generators/`（**11 个**） | — | 多学科制卡：`chinese_lang` `japanese_lang` `russian_lang` `geography` `history` `politics` `science` `english_lang` `it` + `base` `__init__` |
| `scripts/audit_all_subjects.py` | — | 全学科审计（多学科口径） |
| `scripts/check_chinese_gb.py` · `fix_chinese_gb.py` | — | K12 中文科 GB 编码检查/修复 |
| `scripts/migrate_nursery_to_literature.py` | — | 幼儿园 → 文学（K12 学段迁移） |
| `scripts/retry_k12.cmd` | — | K12 跑批重试 |

**🔴 排除在外的**：`split_inline_chinese.py`（见 §〇 发现 1，**是英语词库工具**）

---

## B 类：K12 数据 —— **221 个文件**（待拍板）

| 目录/文件 | 文件数 | 内容示例 | 判定依据 |
|---|---:|---|---|
| `data/curriculum/cleaned/` | **98** | `compulsory/art.md` `biology.md` `chemistry.md`… · `senior/…` | 义务教育 + 高中 = K12；md 是课标清洗产物 |
| `data/curriculum/gold/` | **45** | `compulsory/biology.json` `chemistry.json` `chinese.json`… | K12「黄金数据集」 |
| `data/curriculum/v3/` | **31** | `plans/biology.json` `cards/…` | K12 plan 体系 v3（多学科） |
| `data/curriculum/v4/` | **20** | `plans/art.json` `biology.json`… | K12 plan 体系 v4 |
| `data/curriculum/prebuilt/plans_merged/` | **14** | `biology` `chemistry` `chinese` `geography` `math` `physics` `pe`… | K12 合并 plan |
| `data/curriculum/prebuilt/vocab_enriched/` | **5** | `chinese_enriched` `japanese_enriched` `russian_enriched` + `english_compulsory/senior_enriched` | 多学科词表（英文那两个也是 K12 学段命名） |
| `data/curriculum/templates/` | **5** | `cards_humanities/language/literature/science_template.json` | K12 多学科模板 |
| `data/curriculum/backups/` | **3** | `backup_20260608_011849/{english,english_compulsory,english_senior}.json` | K12 备份 |
| **合计** | **221** | | |

**✅ 同目录下必须保留的**（英语词库产出）：
`prebuilt/` 下的 `cefr_j/`（CEFR-J 权威词表）· `word_form*`（词形链 36,856）· `etymon_canonical/chained` · `affix_normalized` · `collocation_parsed` · `group_c_resolution` · `root_feasibility_verify` · `spelling_variant` · `vocab_noise` · `word_family_candidates` · `senses_supplement` · `fullrun/` `intermediate/` `bench/`（LLM 跑批）· `word_form.db`

---

## C 类：K12 后端 + 前端代码 —— 🔴 **活代码**（待拍板，风险最高）

| 对象 | 规模 | 牵连 |
|---|---|---|
| `backend/.../k12_quiz.rs` · `k12_quiz_api.rs` · `k12_quiz_loader.rs` | **297 行** | 在 `lib.rs:41-43` 声明为 `pub mod` |
| `backend/.../tests/e2e_k12_extra_lifecycle.rs` | 207 行 | 集成测试 |
| `backend/.../routes.rs` | **17 处** k12 引用 | 注册 **5 个路由**：`/api/k12/init` · `/subjects` · `/progress` · `/reading/{conv_id}/current-card` · `/quiz/submit` |
| `backend/.../curriculum_loader.rs` | **767 行** | 提供 `k12_data_dir()`，「供 /k12/init 路由直接使用」 |
| `backend/.../plan_handler.rs` | 1 处调用 | `k12_quiz::should_mark_task_complete(...)` |
| `app/lib/config/k12_subjects.dart` | 161 行 | 被 **`app/lib/screens/home_screen.dart`**（首页！）import |

**为什么风险最高**：这不是「删孤儿文件」，而是**删一个仍在服务中的子系统**。
按项目已定方向（**不做 plan · 不做 K12**），它**应该删** —— 但会牵出：
后端路由表 + 模块声明 + `curriculum_loader` 重写 + `plan_handler` 改逻辑 + **前端首页改造**。

> 🔑 按 skill 铁律 1：**「被核心页面引用」→ 会牵出重写，应合并到那次重写里做，不要单独做**。
> → 建议**并入 Step 3 首页/信息流重写**，而不是现在单独删。

---

## D 类：其它废弃（非 K12，但「仓库不干净」的主要来源）

| # | 对象 | 规模 | 判定 |
|---|---|---|---|
| 1 | **`miniprogram/`** | 13 文件（git 跟踪） | 🔴 **微信小程序**（`app.wxml` `project.config.json`）—— 项目明确 **「不做微信」** → 删 |
| 2 | **`remotion-videos/`** | **683 MB**（git 18，含 `output/coevo-intro.mp4`） | 🟠 产品介绍视频工程（React/Remotion）—— 营销素材，且**视频 mp4 在 git 里** → 建议按「营销素材不进仓库」移出 |
| 3 | `blog_deploy.tar.gz` | 8 KB（git 跟踪） | 🔴 压缩包垃圾（`chore: remove blog` 时的残留）→ 删 |
| 4 | **`flutter_01~05.log`**（5 个） | — | 🔴 **我上轮排查时产生的崩溃日志**（`CreateFile failed 231`）→ 删 |
| 5 | `r2_details.txt` · `indiehackers_*.json`（3 个） | ~264 KB | 临时垃圾（已 ignore，但仍在磁盘）→ 删磁盘 |
| 6 | `AGENTS.md` · `CLAUDE.md` · `NUL` | — | 已 ignore；`NUL` 是 Windows 保留名（git 无法索引）→ 删磁盘 |
| 7 | `backups/seo` | 1 KB | 空备份目录 |
| 8 | **`backend/target/`** | **2.0 GB** | ⚠️ Rust 构建产物（**已 ignore**）—— 不占 git，但占本地磁盘 → 可 `cargo clean` |
| 9 | `backend/certs/` | 38 KB | 🔴 微信支付证书目录（`.gitignore` 已排除）→ **确认是否仍需要** |

---

## E 类：待白哥判定

| # | 对象 | 情况 | 问题 |
|---|---|---|---|
| 1 | `data/curriculum/english_rebuild/`（8 文件 · 15 MB） | 含 **12,791 词的 CEFR 分级** + `grade_band: g1-2/g3-4/g7-9/g10-12`（**年级字段**）+ Phase3「分级阅读课文」 | 名字是英语，但**含年级字段 → 属 K12 管道**。<br>⚠️ 12,791 词分级数据是否有价值？（现 `word.db` 是 11,523 词） |
| 2 | `docs/` 里的 K12 文档（14 个） | `architecture/k12-*.md` · `research/k12-*.md` · `_archive/test-files/*k12*` | 删 / 移到 `_archive` / 保留？ |
| 3 | `docs/_archive/`（47 文件） | 已归档的旧文档 | 保持现状 / 清空？ |
| 4 | `docs/research/papers/ai-literacy/genai-k12-risks/` | 文献笔记（**不是项目 K12 功能**） | 建议**保留**（内容研究） |
| 5 | `backend/data/` | 41 MB | 是否可清？ |

---

## 建议的执行顺序

| 批次 | 内容 | 风险 |
|---|---|---|
| **①** | **A 类 K12 脚本（17 文件）** + D 类第 3–7 项（垃圾文件） | ✅ 低 —— 引用图已验证 |
| **②** | D 类第 1 项 `miniprogram/`（微信） | ✅ 低 —— 独立目录 |
| **③** | **B 类 K12 数据（221 文件）** | ⚠️ 中 —— 纯数据，但量大 |
| **④** | D 类第 2 项 `remotion-videos/`（683 MB） | ⚠️ 中 —— 移出 git 跟踪，磁盘可留或删 |
| **⑤** | **C 类 K12 后端 + 前端** | 🔴 **高 —— 建议并入 Step 3 首页重写** |
| **⑥** | E 类逐项定 | — |

---

## 一句话总结

「K12 清理」的真实范围比名字大得多：**脚本 17 个 ✅ 可直接删**；
**数据 221 文件**（同目录混着英语词库核心资产，必须逐项分）·
**后端+前端是活代码**（删了编不过，建议并入首页重写）·
另有 **miniprogram（微信）/ remotion-videos（683 MB）/ 根目录垃圾** 是「仓库不干净」的另一半来源。
⚠️ 且有 **1 个名字像 K12 实际是英语词库工具**（`split_inline_chinese.py`）**必须保留**。

---

## 九、✅ 执行记录（2026-09-27 02:40）

### 白哥决策

| # | 决策 | 选择 |
|---|---|---|
| 1 | K12 数据 221 文件 | ✅ **全删** |
| 2 | K12 后端活代码 | ✅ **并入 Step 3 首页重写**（本次不动） |
| 3 | 其它废弃 | ✅ **全选**：miniprogram + remotion-videos + 根目录垃圾 + backend/target |
| 4 | english_rebuild | ✅ **删**（属 K12 管道） |

### 执行结果

| 批次 | 内容 | 规模 | SHA |
|---|---|---|---|
| **A** | K12 脚本 | **16 文件** | `d9ffe02` |
| **B** | K12 数据（229） | cleaned 98 · gold 45 · v3 31 · v4 20 · plans_merged 14 · vocab_enriched 5 · templates 5 · backups 3 · english_rebuild 8 | `06e2769` |
| **C** | miniprogram + remotion-videos | **32 文件**（+ overview.md 移出） | `19e6247` |
| **D** | 根目录垃圾 | flutter_01~05.log ×5 · blog_deploy.tar.gz · r2_details.txt · indiehackers_*.json ×3 · AGENTS.md · CLAUDE.md · backups/seo | 本批 |

### 本地空间释放

| 对象 | 前 | 后 | 释放 |
|---|---|---|---|
| `backend/target`（Cargo 构建产物） | **2.0 GB** | 0 | **≈1.95 GB** |
| `remotion-videos`（含 680MB node_modules） | **683 MB** | 移出 git（磁盘留 2.9MB 精编版） | **≈680 MB** |
| K12 数据 + miniprogram + 其它 | — | — | 数 MB |
| **合计** | | | **≈2.6 GB** |

### 🔑 抢救的唯一价值（铁律 2 的实践）

删 `remotion-videos/` 前发现 **`output/coevo-intro.mp4` 是唯一的产品介绍视频成品** →
连同 `src/` 源码复制到 `marketing/remotion-videos/`（已 gitignore）**再删原目录**：
- git 干净 ✅ · 素材不丢 ✅ · 体积从 683MB 降到 2.9MB ✅（node_modules 可 `npm ci` 重建）
- 并加了 `README.md` 说明「为什么在这里 + 如何重建 + 如何恢复跟踪」

### 安全验证

| 验证 | 结果 |
|---|---|
| **英语词库资产** | ✅ **11 个关键文件全在** + `word.db` md5 `e7495c549b84` **与删除前完全一致** |
| `tokens_verify` | ✅ **267 项全过 / 0 实现失败** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致 |
| 引用图（A 类脚本） | ✅ **0 处代码引用**（删前验证） |
| CI 引用完整性 | ✅ CI 只引用 `scripts/fsrs_verify` 与 `check_native_readiness.py`，均存在 |
| git 变更对账 | ✅ 261 D + 1 R 与预期分布 **完全一致**（229 data + 18 remotion + 13 miniprogram + 1 移出 + 1 tarball） |

### 🔴 一处执行瑕疵（已修正）

首批提交时**忘了「暂存区里已積累全部 git rm 的删除」** → 一次 commit 把
229 data + 18 remotion + 13 miniprogram 全提交了，**message 却只写了 K12 数据**
（message 与内容不符 → 违背「按语义分批」）。

→ **修正方式**：`git reset --soft HEAD~1`（保留暂存区）→ `git reset`（清空）
→ 重新分批 `git add` 三次提交。

> 🔑 **教训**：`git rm` 会**立即暂存**删除记录。批量删除后分批提交时，
> 每批 commit 前必须 `git diff --cached --name-only` **确认本批范围**，
> 不能假设「只有我刚 add 的那些」。

### 未处理（本次范围外）

| # | 事项 | 原因 |
|---|---|---|
| 1 | **C 类 K12 后端 + 前端** | 按决策**并入 Step 3 首页重写**（删了编不过） |
| 2 | `NUL` | Windows 保留设备名，`rm`/`find -delete`/`git rm` 全部失败（0 字节，**已 gitignore**，对仓库零影响） |
| 3 | 根目录 4 个文档 | `API.md`（1936 行，含已删的 admin 内容）· `CoEvo_DataFlow.md`（同步于 2026-06-08）· `CoEvo_Devplan.md`（**用户铁律指定的必读**）· `DEVELOPMENT.md` → **待白哥判** |
| 4 | `app/build`（204 MB）· `app/.dart_tool/` | Flutter 构建产物（已 ignore）—— 与 backend/target 同类，可一并清 |
| 5 | `docs/_archive/`（47 文件） | E 类第 3 项，未拍板 |
