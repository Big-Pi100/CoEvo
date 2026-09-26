# Git 历史清理方案（filter-repo）

> 日期：2026-09-27 03:15
> 触发：白哥「仓库太不干净……PNG 图片都可以删除」
> 状态：🔴 **待批准**（破坏性操作 —— 改写全部 205 个提交的 SHA，需 force push）

---

## 〇、先说两个意料之外的发现

### 🔴 发现 1：**隐私数据进了版本历史**（比「仓库不干净」严重）

`backend/data/` 曾被跟踪 **167 个文件**，内含：

| 内容 | 规模 |
|---|---|
| `avatars/` | 7 个**用户头像** |
| `payment_proofs/` | 2 张**支付凭证截图**（含订单号） |
| `deleted_users.ndjson` | **已删除用户**的数据 |
| `logs/` · `debug_logs/` | 151 个运行日志 |
| `coevo.db` | **数据库快照**（历史 **105 个版本**） |
| `crawler.html` · `db_schema_dump.txt` · `*_weixin.jpg` | 抓取内容 / schema / 微信图 |

**为什么严重**：隐私数据一旦提交就**永久留在历史里** —— 改文件、删文件都没用。
即便仓库是 private，只要将来转公开/加协作者，这些数据就跟着走。

**已止血（本次已提交 `7f4cc06`）**：
① `git rm -r --cached backend/data/`（**工作区 167 文件保留**，本地开发不受影响）
② `.gitignore` 加 `/backend/data/`（防止再次混入）

**但历史里还在** → 需要本方案的 filter-repo 才能真删。

### 🔴 发现 2：**体积主因不是 PNG，是数据库快照**

| 历史内容（未压缩） | 体积 | 占比 |
|---|---:|---:|
| 🔴 **`backend/data/`** | **1,752 MB** | **55%** ← 其中 `coevo.db` 105 版 = **1,419 MB** |
| `data/curriculum/raw/`（K12 课标 PDF） | 350 MB | 11% |
| `marketing/`（营销素材） | 136 MB | 4% |
| `sherpa-models/`（onnx） | 125 MB | 4% |
| 根目录压缩包 | 34 MB | 1% |
| `app_user`/`app_admin`/`coevo_shared` | 26 MB | 1% |
| `docs/marketing` + `docs/redbook` | 25.5 MB | 1% |
| `remotion-videos/` | 22 MB | 1% |
| **PNG（分散在上述目录）** | **143 MB** | **4.5%** |
| **合计可清** | **≈2,471 MB** | |

> **白哥以为 PNG 是大头，实际它只占 4.5%。** 真正撑大 `.git`（945 MB）的是
> **`coevo.db` 的 105 个历史版本** —— 每提交一次数据库，就永久存一份快照。

---

## 一、建议清理的 9 类路径

| # | 路径 | 历史体积 | 为什么可清 |
|---|---|---:|---|
| 1 | `backend/data/**` | 1,752 MB | 🔴 **含隐私数据 + DB 快照**；已移出跟踪 |
| 2 | `data/curriculum/raw/**` | 350 MB | K12 义务教育课标 PDF（项目不做 K12） |
| 3 | `marketing/**` | 136 MB | 营销素材（已定「不进仓库」，含 1,061 个 blob） |
| 4 | `sherpa-models/**` | 125 MB | onnx 模型（TTS 端侧化后废弃） |
| 5 | `app_user/**` `app_admin/**` `coevo_shared/**` | 26 MB | 已删除的旧项目 |
| 6 | `docs/marketing/**` `docs/redbook/**` | 25.5 MB | 营销内容 |
| 7 | `remotion-videos/**` | 22 MB | 视频工程（已移到 marketing/） |
| 8 | `miniprogram/**` | ~0 | 微信小程序（已删） |
| 9 | 根目录 `*.tar.gz` / `*.bak` | 34 MB | 垃圾 |

### ✅ 明确**保留**

| 内容 | 原因 |
|---|---|
| **`data/word.db`**（31.4 MB） | 🔴 **词库核心资产** —— 已核实**只有 1 个历史版本**，不会被误删 |
| 所有代码 / 脚本 / 文档 | 现行内容 |
| **App 图标 PNG**（iOS/macOS/Web/Android 共 30 张） | 🔴 构建必需 —— 清理范围**不含**这些路径 |
| `data/curriculum/prebuilt/**` | 英语词库产出 |

---

## 二、预期收益

| 项 | 现在 | 预期 |
|---|---|---|
| **`.git` 体积** | **945 MB** | **≈100–200 MB**（降 80% 左右） |
| clone 时间 | 慢 | 显著变快 |
| 历史里的隐私数据 | 🔴 仍在 | ✅ **彻底不存在** |

---

## 三、风险与前置条件（**必读**）

| # | 风险/条件 | 说明 |
|---|---|---|
| 1 | 🔴 **破坏性** | **改写全部 205 个提交的 SHA** —— 所有 commit id 都会变 |
| 2 | 🔴 **必须 force push** | `git push --force` 覆盖远程 |
| 3 | ⚠️ **需先备份** | 方案里会先 `tar` 打包整个 `.git`（约 900 MB） |
| 4 | ⚠️ 若已有他人 clone | 需重新 clone（**本项目单人，无此风险**） |
| 5 | ✅ **工作区文件不受影响** | filter-repo 只改历史，磁盘文件不动 |
| 6 | ✅ **可回滚** | 有备份 + 记录了当前 SHA |
| 7 | ⚠️ 后续 `git gc` | 清理后需 `git reflog expire` + `gc --prune=now` 才真正释放空间 |

---

## 四、执行步骤（6 步）

```bash
# ① 备份（不可省）
tar czf ../CoEvo_git_backup_20260927.tar.gz .git

# ② 记录回滚锚点
git rev-parse HEAD > .git/_rollback_sha.txt

# ③ 执行清理（filter-repo，9 类路径）
python .git/_gfr_pkg/git_filter_repo.py --force \
  --invert-paths \
  --path backend/data \
  --path data/curriculum/raw \
  --path marketing \
  --path sherpa-models \
  --path app_user --path app_admin --path coevo_shared \
  --path docs/marketing --path docs/redbook \
  --path remotion-videos --path miniprogram

# ④ 重新添加 remote（filter-repo 会移除它）
git remote add origin git@github.com:Big-Pi100/CoEvo.git

# ⑤ 彻底回收空间
git reflog expire --expire=now --all && git gc --prune=now --aggressive

# ⑥ force push
git push --force origin main
```

### 执行后的验证（必做）

| 验证 | 期望 |
|---|---|
| `git log --oneline | head` | 提交次数不变（205）· message 不变 |
| **`git diff HEAD --stat` 对比清理前后** | 🔑 **工作区内容完全一致**（唯一差别应是 commit SHA） |
| `git cat-file -e HEAD:data/word.db` | ✅ 存在（词库未被误删） |
| `git ls-tree -r HEAD -- app/ios/Runner/Assets.xcassets` | ✅ 30 张 App 图标仍在 |
| `python -m git_filter_repo --analyze` | 确认目标路径已无 blob |
| `du -sh .git` | ≈100–200 MB |
| `git fsck` | 无错误 |

> 🔑 **最关键的一条是「清理前后 HEAD 内容必须一致」** —— 如果内容变了，说明误删了还在用的文件。
> 我会在**执行前**导出 `git ls-tree -r HEAD` 快照，执行后**逐行 diff**。

---

## 五、选型：为什么用 filter-repo 而不是 filter-branch

| | `git filter-repo` | `git filter-branch` |
|---|---|---|
| 速度 | 快 | 慢（205 提交可接受，但 10 倍以上差距） |
| 安全性 | ✅ 官方推荐，先做安全检查 | ⚠️ 官方**明确不推荐**，易误操作 |
| 安装 | ✅ **已装到 `.git/_gfr_pkg`**（隔离，不污染环境） | 内置 |
| 自动化 | ✅ 自动重写 + 提示后续步骤 | 需手动清 `refs/original/` |

**已就绪**：`git-filter-repo` 版本 `a40bce5` 已装到 `.git/_gfr_pkg`（隔离目录）。

---

## 六、可选的「保守方案」

若不想改写历史：

| 方案 | 效果 |
|---|---|
| **B（保守）** | 只做已完成的「止血」（移出跟踪 + ignore）。**历史仍含隐私数据，`.git` 仍 945 MB** |
| **C（中间）** | 把仓库**归档重建**：新建一个空仓库，只提交当前 HEAD 内容 → `.git` 从零开始（**约 100 MB**），旧仓库保留为只读归档。<br>⚠️ 代价：**丢失全部提交历史**（无法 `git log` 回溯） |

> 🔑 **我的建议：A（filter-repo）** —— 它保留了提交历史（205 个提交的 message 与时序都在），
> 只把指定路径从历史中抹掉。这是「既清隐私又留历史」的唯一方式。

---

## 七、待白哥定

| # | 决策 |
|---|---|
| **1** | 选 **A**（filter-repo）/ **B**（不做，只保留止血）/ **C**（重建仓库，丢历史）？ |
| **2** | 清理范围：**9 类全清**（推荐）/ 只清隐私相关的 `backend/data` / 其它取舍？ |
| **3** | 是否包含 `marketing/**`（136 MB 营销素材）与 `docs/marketing`+`docs/redbook`（25.5 MB）？<br>⚠️ 注意：这些素材在工作区**仍然保留**（只是从历史里清掉），已确认「不进仓库」 |

---

## 八、✅ 执行记录（2026-09-27 03:25）

### 白哥决策
**A（filter-repo 全清）+ 9 类全清**

### 前置动作（强制）

| 步骤 | 结果 |
|---|---|
| 备份 `.git` | `E:/CoEvo_git_backup_20260927.tar`（**945 MB** · 318 条目 · 含 packed-refs 与 HEAD）✅ 验证可读 |
| 回滚锚点 | 第一轮前 `f769c84` · 第二轮前 `fdb3609`（存于 `.git/_rollback_sha*.txt`） |
| HEAD 快照 | `git ls-tree -r HEAD` → **1,097 条**（用于事后逐行 diff） |

### 执行（两轮）

| 轮次 | 清理路径 | 结果 |
|---|---|---|
| **第一轮** | `backend/data` · `data/curriculum/raw` · `marketing` · `sherpa-models` · `app_user` `app_admin` `coevo_shared` · `docs/marketing` `docs/redbook` · `remotion-videos` · `miniprogram` | 209 提交重写 · 946 → **532 MB** |
| **第二轮** | 🆕 **补清漏网**：`docs/curriculum`（K12 PDF **副本** 468 MB）· `data/curriculum/{cleaned,gold,v3,v4,backups,english_rebuild,templates}` · `data/coevo.db{,-wal,-shm}`（117 MB）· `backend/docs`（33 MB）· 根目录 3 个 `*.tar.gz`（35 MB） | 206 提交重写 · 532 → **86 MB** |

> 🔑 **第二轮为什么存在**：第一轮只清了 `data/curriculum/raw`，
> 但同一批 K12 课标 PDF 在 **`docs/curriculum/raw`** 还有一份副本（468 MB）；
> 且第一轮删除的 K12 数据（cleaned/gold/v3/v4）**其历史 blob 仍在**。
> → **教训：清理时要按「内容」找全所有副本，不能只按一条路径。**

### 🎯 最终结果

| 项 | 清理前 | 清理后 | 降幅 |
|---|---|---|---|
| **`.git` 体积** | **946 MB** | **86 MB** | 🔥 **−90.9%** |
| HEAD 条目数 | 1,097 | **1,097** | ✅ 不变 |
| 提交数 | 207 | 195 | 少了 12 个「只改动被清文件」的空提交 |

### ✅ 验证（8 项全过）

| # | 验证 | 结果 |
|---|---|---|
| 1 | 🔑 **清理前后 HEAD 逐行 diff** | ✅ **完全一致**（1097 → 1097，两轮都验） |
| 2 | `data/word.db` 在 HEAD | ✅ |
| 3 | `README.md` / `backend/cefr_catalog.json`（后端在用） | ✅ |
| 4 | App 图标（iOS/macOS/Web/Android） | ✅ 52 个 |
| 5 | 现用字体 8 个 · 词库产出 29 个 · K12 归档文档 16 个 | ✅ |
| 6 | `git fsck` | ✅ 无错误 |
| 7 | `tokens_verify` | ✅ **267 项全过**（工作区代码未受影响） |
| 8 | 本地 = 远程 · 工作区干净 | ✅ `1403479` |

### force push

```
+ f769c84...1403479 main -> main (forced update)
```

### 回滚方式（万一需要）

```bash
# 从备份恢复
tar xf E:/CoEvo_git_backup_20260927.tar -C <目标目录>
# 或从 reflog（清理前 reflog 已 expire，故必须用 tar 备份）
```

> ⚠️ 备份 `E:/CoEvo_git_backup_20260927.tar`（945 MB）**建议保留一段时间**再删。

### 🔑 三条可复用教训（已写入 skill）

1. **隐私数据进 git 历史 = 改文件无用，只能改写历史** —— 止血（移出跟踪 + ignore）与根治（filter-repo）是两步，不能只做前者。
2. **清理要按「内容」找全所有副本** —— 同一批文件可能在多个路径各有一份（本例 `data/curriculum/raw` 与 `docs/curriculum/raw` 重复 468 MB）。
3. 🔴 **`--path` 会删该路径的全部历史包括 HEAD** → 清历史前必须逐一核实「目标路径在 HEAD 上还有没有文件」；
   对「混装目录」（如 `data/curriculum` 同时含 K12 数据与英语词库产出）**绝不能整目录清**。
