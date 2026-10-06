# Git 历史清理执行记录（2026-10-06）

> **目的**：为「仓库改公开」扫清障碍 —— 公开仓库会把**整个历史**一次性公开，
> 而 `git rm` 只是「新提交里不再有它」，历史 blob 永久存在。
> **依据**：`git-history-secret-audit-2026-10-05.md` §六 第 3 步
> **状态**：✅ 已完成并推送（本地 + 远程均验证干净）· ⏳ 改公开待白哥操作

---

## 一、做了什么

### 1.1 清理动作

```bash
git filter-repo --force \
  --invert-paths --path backend/.env \
  --replace-text .git/_replace.txt
```

| 目标 | 方式 | 结果 |
|---|---|---|
| `backend/.env`（first commit 引入，2026-05-13 删除）| `--invert-paths --path` | ✅ 已从全部历史中消失 |
| 历史里所有 DeepSeek key 明文 | `--replace-text` 正则<br>`regex:sk-[A-Za-z0-9]{20,}==>sk-***REDACTED***` | ✅ 零命中 |

**为什么用「正则替换」而不是「逐值替换」**：逐值替换要求先把每个 key 抄出来
（多一次泄漏面），而正则覆盖**所有变体**，包括我没发现的。

### 1.2 执行结果

| 项 | 值 |
|---|---|
| commit 数 | **619 → 619**（未减少 —— 没有任何提交因清理而变空）|
| 用时 | 14.4 秒 |
| `.git` 体积 | **111 MB → 98 MB**（gc 后见 §四）|
| tag | **5 个自动重写指向**（`v0.1.0`~`v0.1.4`），**无需手工重建** |

---

## 二、🔴 本次审计推翻了原报告的 2 个结论

> 判据：**归零型操作必须自己重扫**，不能信「报告说扫过了」。

### 2.1 报告说「B 未跟踪 ⇒ 不会被公开」—— **错的**

| | 报告（§二 B） | 实测 |
|---|---|---|
| 位置 | `marketing/scripts/v3/*.py` | 🔴 **`tmp/compare_real.py` · `tmp/full_context_test.py` · `tmp/llm_compare.py`** |
| 是否进过 git | ✅ **未跟踪 ⇒ 不会被公开** | 🔴 **进过历史** ⇒ **改公开后会暴露** |

🔑 **根因**：报告只看了**当前工作区**的跟踪状态，**没查历史**。
「当前未跟踪」≠「从未跟踪」—— 文件在 `tmp/` 下曾被提交，后来删掉了。

### 2.2 报告漏了 5 个文件

用 A（`bf3d6552a2d5`）的文件，报告只列了 3 个 `docs/`，实际还有：

| 文件 | 报告 |
|---|---|
| `backend/tests/cp2_accuracy_test.py` | ❌ 漏 |
| `backend/tests/prod_cn_stage.py` | ❌ 漏 |
| `backend/tests/prod_dual_agent_g1-2.py` | ❌ 漏 |
| `backend/tests/prod_plan_e2e_test.py` | ❌ 漏 |
| `backend/tests/prod_stage_complete.py` | ❌ 漏 |

⇒ 共 **11 个路径 / 15 处**（报告只写了 3 个）。

🔑 好在**用的是正则替换** ⇒ 即使报告漏了，也一并清掉 ✅
（若用「逐值替换」，这 8 处就会被漏掉。）

### 2.3 结论：两份报告的两个层次都漏过

| 版本 | 漏了什么 | 已记判据 |
|---|---|---|
| 第一版（10-05） | 漏了**当前工作区**的明文（只扫历史）| 「审计历史」≠「审计当前」|
| 第二版（10-06） | 漏了**历史里的 tmp/ 与 tests/**（只扫了部分路径）| 🔴 **「扫过历史」≠「扫全历史」** |

---

## 三、验证（8 项，全部通过）

| # | 项 | 结果 |
|---|---|---|
| ① | `ls-tree -r HEAD` 逐行 diff | ✅ **一致**（唯一差异 = 本次新增的审计脚本，见下）|
| ② | 历史里还有明文 `sk-` 吗 | ✅ **零命中**（本地）|
| ③ | `backend/.env` 在历史里还存在吗 | ✅ **0 个提交**（已消失）|
| ④ | commit 数是否异常减少 | ✅ 619 → 619 |
| ⑤ | `git fsck` | ✅ 无 error |
| ⑥ | `.git` 体积 | ✅ 111 MB → 98 MB |
| ⑦ | 工作区状态 | ✅ 干净 |
| ⑧ | **远程历史重扫**（mirror clone）| ✅ `deepseek_key` / `tencent_akid` / `github_pat` / `aws_key` / `slack_token` **全部零命中** |

### ① 的唯一差异说明

快照是在**提交审计脚本之前**做的，之后新增了 `scripts/audit_git_history_secrets.py`
⇒ 差异恰好是这一行，**不是误删**。

### 假阳性（已确认，无需处理）

| 模式 | 命中 | 实际内容 | 判定 |
|---|---|---|---|
| `private_key` | 46 处 | `ci.yml` 的格式校验 · `iap_handlers.rs` 注释 · 文档说明 | ✅ 假阳性 |
| `password_assign` | 326 处 | 测试假值（`"correct1"` / `"whatever1"` / `"newpass1"`）| ✅ 假阳性 |

> 🔑 判据沿用报告 §四：**「出现过某字符串」≠「它是真值」**。

---

## 四、已推送

| 操作 | 结果 |
|---|---|
| `git push --force origin main` | ✅ `392ce1c → 7dc9945` |
| `git push --force origin --tags` | ✅ 5 个 tag 全部更新 |

**push 前核对了远程 HEAD**（`392ce1c` = 我当天的记忆更新提交）⇒ 确认是**自己的提交**，
单人项目，force 覆盖无丢失风险。

---

## 五、回滚方式（**保留一周**）

| 素材 | 位置 |
|---|---|
| 完整 `.git` 备份 | `/e/CoEvo_backups/coevo_git_backup_20261006_2131.tar`（110 MB）|
| HEAD 逐行快照（前/后）| `.git/_snapshot_before.txt` · `.git/_snapshot_after.txt` |
| 回滚锚点 SHA | `.git/_rollback_sha.txt`（= `f8dae54c…`，filter-repo 前的 HEAD）|
| 远程镜像（验证用）| `/e/CoEvo_backups/remote_mirror` |

**回滚步骤**：解压 tar 覆盖 `.git/` → `git reset --hard <锚点>` → `git push --force`。

⚠️ **旧 clone 无法直接 pull**（历史无共同祖先）⇒ 其它设备需**重新 clone**。
✅ **部署链路不受影响** —— CI 靠 **tag 名**触发，不依赖 commit hash。

---

## 六、⏳ 剩下的第 4 步：改公开（**需要凭据**）

> 🔴 **本机无法执行** —— `gh` 未登录，也没有 `GH_TOKEN` / `GITHUB_TOKEN` 环境变量。

### 为什么顺序是「先 push 再改公开」

改公开会把**远程历史**公开。若先改公开再 push，会出现「远程历史还含 key」的窗口
⇒ **必须先 push 干净的历史，再改公开** ✅（本记录已完成 push）

### 操作方式（二选一）

**A · 网页（最简单，两步）**
1. https://github.com/Big-Pi100/CoEvo/settings
2. 拉到底 **Danger Zone** → **Change repository visibility** → **Make public**

**B · 命令行**（需先 `gh auth login`）
```bash
gh auth login                       # 交互式，白哥操作
gh repo edit Big-Pi100/CoEvo --visibility public --accept-visibility-change-consequences
```

### 改公开后

1. 触发 CI（push 已触发过一次，那次因额度耗尽会失败）
   → 在 Actions 页面 **Re-run failed jobs**，或再推一个提交
2. **出包完成后改回 private**（改回时无需再清历史）

### ⚠️ 出包后改回 private 时注意

改回私有**不会**重新引入已清理的内容（历史已永久重写）✅
但**新产生的提交**仍需遵守「不写明文凭据」—— 已由
`scripts/check_no_secrets.py` 接入 CI `query-verify` 把关 ✅

---

## 七、判据沉淀

- 🔴🔴 **「扫过历史」≠「扫全历史」** —— 本次实测：报告用 `git log -S` 扫了部分路径，
  漏了 `tmp/`（曾跟踪）与 `backend/tests/`。
  ⇒ **正解**：扫**全部 blob**（`git rev-list --objects --all` + `cat-file --batch`），
  而不是「对着记忆中的路径逐个查」。
- 🔴 **「当前未跟踪」≠「从未跟踪」** —— 判「某文件会不会被公开」必须查历史
  （与「`.gitignore` 拦不住先提交后加规则的文件」同源）。
- 🔑 **用「正则替换」而非「逐值替换」** —— 后者要求先把每个密钥抄出来（多一次泄漏面），
  且**会因清单不全而漏清**。本次报告漏了 8 处，靠正则兜住了。
- 🔑 **filter-repo 会连 tag 一起重写** —— 不需要手工重建
  （与原预估「5 个 tag 需重建」不同，实测自动完成）。
- 🔴 **破坏性操作必须后台执行** —— 首次前台跑被 SIGTERM 掐断（进度 211/619）。
  ⚠️ **中断后必须核对 `commit-map` 行数 vs 总 commit 数**，才能判定「refs 是否已被改写」。
- 🔑 **验证远程**要用 **mirror clone 重扫**，不能只看本地 ——
  「本地干净」不代表「远程干净」（推送可能不完整）。
