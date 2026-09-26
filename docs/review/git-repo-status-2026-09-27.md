# Git 仓库现状与提交风险报告

> 日期：2026-09-27 01:50
> 触发：白哥指出「你好像从来没有提交 git，没有 push 过」
> 状态：🔴 **待批准**（涉及 `git reset` + 分批提交 + push，未动手）

---

## 〇、结论先行

| # | 结论 |
|---|---|
| **1** | 🔴 **最后一次提交是 2026-07-26** —— 之后**两个月的工作全部堆在暂存区，从未提交**；`origin/main` 停在 `abbe160` |
| **2** | 暂存区有 **1,689 个文件**（+843,654 / −419,203 行），**混着「该提交的」和「绝对不该提交的」** → 🔴 **不能直接 commit** |
| **3** | 🔴 其中 **`.git-corrupt-xiaohei-20260805/`（33 文件）是「另一个项目的 .git 内部数据」**被误放进本仓库并已暂存 |
| **4** | 🔴 `data/coevo.db-wal` / `-shm`（SQLite 运行时文件）被暂存 → 提交会让 clone 出的库**可能损坏** |
| **5** | ⚠️ 密钥泄漏**已在远程**（3 个文件在 `origin/main` 里）—— 这是既有问题，本轮未新增 |
| **6** | ✅ **仓库是 private**（匿名 GitHub API 返回 404）→ 密钥风险等级可控，但**轮换仍应做** |

---

## 一、时间线：两个月没提交

| 项 | 值 |
|---|---|
| 当前分支 | `main` |
| `origin/main` 最后提交 | **`abbe160` · 2026-07-26** · `chore: remove blog - moved to separate coevo-blog repo` |
| 本地 vs 远程 | **完全同步（0 / 0）** → 本地没有领先提交，**说明这两个月的活一个 commit 都没有** |
| 远程仓库 | `git@github.com:Big-Pi100/CoEvo.git` · 🔒 **private** |

> 🔑 注意：**不是我这几轮会话没提交** —— 而是**从 7 月 26 日起就没提交过**。
> 我这几轮的改动只是混在这个大暂存区里的一部分。

---

## 二、暂存区构成（1,689 文件）

### 状态分布

| 状态 | 数量 | 含义 |
|---|---:|---|
| **A** 新增 | **922** | 新文件 |
| **D** 删除 | **707** | 删除记录 |
| **M** 修改 | **54** | 内容变更 |
| **R** 重命名 | **6** | 移动到别处 |

### 按目录 × 状态

| 目录 | A 新增 | D 删除 | M 修改 | 判定 |
|---|---:|---:|---:|---|
| `marketing/` | **637** | 78 | 7 | 🔴 **不该全提交**（188 MB · 含 **320 个 PNG**） |
| `app/` | 16 | **417** | 35 | ✅ **该提交**（417 D 里 **391 是 `app/packages/flutter_math_fork`** = 本轮正当删除） |
| `app_user/` | 0 | **152** | 0 | ✅ 该提交（项目已删，正当） |
| `scripts/` | **117** | 0 | 0 | ✅ 该提交（CI 需要，见 `.gitignore` 注释） |
| `docs/` | 77 | 0 | 5 | ⚠️ **需决策**（38 MB · `docs/marketing` 19M + `docs/redbook` 5.7M） |
| `data/` | 36 | 0 | 1 | 🔴 **部分不该**（见 §三） |
| 🆕 `.git-corrupt-xiaohei-20260805/` | **33** | 0 | 0 | 🔴🔴 **绝对不该**（别的项目的 .git） |
| `coevo_shared/` | 0 | 29 | 0 | ✅ 该提交（项目已删） |
| `app_admin/` | 0 | 27 | 0 | ✅ 该提交（项目已删） |
| `sherpa-models/` | 0 | 4 | 0 | ✅ 该提交（TTS 端侧化后删除） |
| `backend/` | 0 | 0 | 4 | ✅ 该提交 |
| `generated-images/` | 2 | 0 | 0 | 🔴 不该 |
| 根目录散文件 | 3 | 0 | 0 | 🔴 不该（见 §三） |
| `.gitignore` · `.github` | 0 | 0 | 2 | ✅ 该提交 |

---

## 三、风险清单（分三类）

### 🔴 A 类：**绝对不该进版本控制**（必须排除）

| # | 对象 | 规模 | 为什么危险 |
|---|---|---|---|
| 1 | **`.git-corrupt-xiaohei-20260805/`** | **33 文件** | 🔴 它是**另一个项目的 `.git` 内部目录**（含 `index` 410 KB、`logs/HEAD`、`hooks/*.sample`、`objects/`、`refs/`）。**证据**：其 `logs/HEAD` 记录的是 **Godot 场景 / vulkan 渲染 / 小黑跳马 / TTS 多音色** —— 与 CoEvo 无关<br>→ 提交后会把**别人的仓库历史**塞进 CoEvo，且 `index` 二进制文件污染仓库 |
| 2 | **`data/coevo.db-wal` · `data/coevo.db-shm`** | 2 文件 | 🔴 SQLite **WAL 模式的运行时文件** —— 数据库未正常关闭时存在。提交它们会让别人 clone 后**库状态不一致甚至损坏**（正确做法：只提交 `.db`，WAL 由 SQLite 自行管理） |
| 3 | `data/coevo.db` | 1 | 🟠 **生产库**（45 表 · `users` 2 条）—— 是否该进代码仓库需白哥定（见 §五 决策 3） |
| 4 | `generated-images/` | 2 文件 · 2.1 MB | 🟠 生成产物，可重建 |
| 5 | 根目录 `r2_details.txt` | 176 B | 🔴 内容是几条 `grep` 命令的输出（**临时垃圾**） |
| 6 | 根目录 `indiehackers_latest_post.json` · `indiehackers_posts_translated.json` · **`.bak`** | 3 文件 | 🟠 临时数据 + 备份文件 |
| 7 | `data/curriculum/raw/**`（12 个 K12 课标 PDF，单个 20–38 MB） | 469 MB | 🔴 **K12 义务教育课程标准** —— 项目已明确**不做 K12**；且总体积近 0.5 GB |

### ⚠️ B 类：**需要白哥决策**（体积 vs 备份价值）

| # | 对象 | 规模 | 问题 |
|---|---|---|---|
| 1 | `marketing/`（新增 637） | **188 MB** · 含 **320 PNG** | 营销素材要不要进代码仓库？<br>→ 若不进：`gitignore` + 换网盘/对象存储<br>→ 若进：仓库会显著膨胀（GitHub 对 >1 GB 仓库会警告） |
| 2 | `docs/marketing/` · `docs/redbook/` | 19 MB + 5.7 MB | 同上（文档里嵌的图） |
| 3 | `data/curriculum/prebuilt/*.json` | 最大 **30.8 万行**（`word_form_chained.json`） | 🟠 是**中间产物**还是**核心资产**？（若是可重建的中间产物 → 不该进；若是词库权威数据 → 该进） |

### ✅ C 类：**正当的项目演进**（应该提交）

- 删除已完成的项目：`app_admin`(27) · `app_user`(152) · `coevo_shared`(29) · `sherpa-models`(4)
- 删除 `app/packages/flutter_math_fork`（391，本轮方案 A）
- `scripts/` 入库 117（CI 依赖）
- `app/lib` 本轮改动（主题换代 + TTS 端侧化 + 公式摘除）
- `backend/` 4 处修改
- `.gitignore` 更新（已含 `/data/backups/`、Python、Flutter 段）

> ⚠️ **`.gitignore` 已更新但暂存区仍有产物** —— 因为 **`.gitignore` 不会自动取消已暂存的文件**。
> 这解释了 `app_user/android/.gradle/` 那 22 个产物为何还在暂存区。

---

## 四、另一个独立问题：密钥已在远程

| 项 | 内容 |
|---|---|
| 泄露位置 | `origin/main` 的 3 个文件：`docs/deploy/deployment-checklist.md` · `docs/review/python_script_inventory_2026-06-08.md` · `docs/review/python_script_security_audit_2026-06-08.md` |
| 探测方式 | `git grep -E "sk-[A-Za-z0-9]{20,}\|AKIA[0-9A-Z]{16}\|ghp_[A-Za-z0-9]{30,}\|-----BEGIN.*PRIVATE KEY" origin/main` |
| 现状 | 🔴 **2026-07-26 之前就已推上 GitHub** → **改文件无用，必须轮换密钥** |
| 风险缓解 | ✅ 仓库是 **private**（匿名 API 404）→ 未公开暴露 |
| 与本次提交的关系 | **无关** —— 是既有问题，本轮提交既不会加剧、也不能靠提交修复 |

> 🔑 记忆里这条待办（「轮换 3 把泄漏 key」）**仍未做**，本次一并提请注意。

---

## 五、建议方案

### 第 0 步（**必做，且无风险**）：补 `.gitignore`

追加排除（都是**明确不该进仓库**的）：

```gitignore
# 别的项目的 .git 备份（误放，2026-08-05 抢救时产生）
/.git-corrupt-*/

# SQLite WAL 运行时文件（提交会导致 clone 出的库不一致）
*.db-wal
*.db-shm

# 临时/生成产物
/generated-images/
/r2_details.txt
/indiehackers_*.json
/indiehackers_*.json.bak

# K12 课标 PDF（项目不做 K12；469 MB）
/data/curriculum/raw/

# Android 构建缓存（.gitignore 原有 **/build/ 未覆盖 .gradle）
**/.gradle/
```

### 第 1 步：`git reset`（**取消暂存，保留工作区**）

```bash
git reset          # --mixed：只清空暂存区，文件一个都不动
```

- 🔑 **为什么必须做**：`.gitignore` 只管「未跟踪」的文件；**已暂存的不会被自动剔除**
- ✅ **安全性**：`git reset`（不带 `--hard`）**不修改任何文件**，只把「已暂存」变回「未暂存」
- ⚠️ 唯一影响：暂存区清空 → 需要重新 `git add`（这本来就是我们要做的）

### 第 2 步：分批提交（按逻辑分组，便于回溯）

| 批次 | 内容 | 约文件数 |
|---|---|---:|
| **①** | `chore: 清理废弃项目`（删 app_admin/app_user/coevo_shared/sherpa-models/admin） | ~630 |
| **②** | `chore: 移除鸿蒙改写版 flutter_math_fork + 摘除公式渲染（方案 A）` | ~400 |
| **③** | `feat(theme): 三档主题落地 + 删除旧主题`（`app/lib/theme/*` + `app.dart` + `profile_screen`） | ~15 |
| **④** | `feat(tts): 全量端侧 flutter_tts`（`tts_service` 等） | ~10 |
| **⑤** | `feat(scripts): 词库/合规/字体/验收脚本入库` | ~117 |
| **⑥** | `docs: 设计文档与调查报告`（**排除含密钥的 3 个文件**） | ~80 |
| **⑦** | `chore: .gitignore 更新` | 1 |

> ⚠️ 批次划分**基于暂存区状态推断**，未逐文件核对语义。实际执行时我会逐批 `git add` 后**先 show 给你确认**再 commit。

### 第 3 步：push

```bash
git push origin main
```

---

## 六、待白哥决策

| # | 决策 | 选项 |
|---|---|---|
| **1** | **是否执行本方案**（补 ignore → reset → 分批提交 → push）？ | A 全部执行 / B 只到「提交」不 push / C 先只看不动 |
| **2** | `marketing/`（**188 MB · 637 文件**）与 `docs/marketing`、`docs/redbook` 的图 —— **进仓库还是移走**？ | A 全部进 / B 排除图片只进文本 / C 整个目录不进（改用网盘） |
| **3** | `data/coevo.db`（生产库 · 31 MB）进仓库吗？ | A 进（便于复现）/ B 不进（应由脚本重建） |
| **4** | `data/curriculum/prebuilt/*.json`（30 万行）是**可重建中间产物**还是**核心资产**？ | 需白哥告知 |
| **5** | 密钥轮换（3 把，已泄漏到 private 仓库）—— **现在做还是单独排期**？ | — |

---

## 七、一句话总结

**仓库从 2026-07-26 起两个月没有提交**，1689 个文件（含**别的项目的 `.git` 备份**、
**SQLite WAL 文件**、**469 MB K12 课标 PDF**、**320 张营销 PNG**）混在暂存区里。
**直接 commit 会污染仓库**；正确做法是 **补 `.gitignore` → `git reset` 取消暂存 → 按逻辑分批重新提交 → push**。
其中 `marketing/` 与 `data/` 的体积取舍**需要白哥拍板**。
