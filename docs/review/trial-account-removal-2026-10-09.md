# 试用账号机制 · 整体退役（2026-10-09）

> 白哥指令：「**不需要试用账号，未登录状态不是可以直接用吗？试用账号没有任何存在意义**」
> 前置调查：「重装后自动登录一个**已订阅**的临时账号？」→
> `docs/review/trial-auto-login-and-trial-subscription-2026-10-09.md`（四个发现）
> 本篇 = 按该调查的结论**整体删除**。

---

## 一、先核实那句话：未登录**到底**能用什么

删之前必须确认「未登录可以直接用」是不是真的 —— 因为**试用账号是唯一的匿名 `user_id` 来源**，
凡是「按账号计」的功能都靠它。实测（读代码，非推断）：

| 能力 | 未登录 | 依据 |
|---|---|---|
| 阅读信息流 / 打开文章 | ✅ 可用 | 端侧纯本地 |
| 划词查词 | ✅ 可用 | 端侧 `word.db` |
| 生词本（**已无上限**）| ✅ 可用 | 端侧 `user.db` |
| 词卡朗读 / 复习 / 收藏 / 书进度 | ✅ 可用 | 端侧 |
| 导入电子书（本地解析）| ✅ 可用 | 端侧 |
| 生成词卡 | ✅ 可用 | `/api/generate-card` **不验证登录态**（`device_id` 仅作统计）|
| **整段翻译** | 🔴 **不可用** | `translate_handler` → `authorize_login_only(&headers)`（`translation.rs:526`）|
| 跨设备同步 / 云端书架 | ❌ | 订阅权益（且需登录）|
| 通知中心 | ❌ | 按 `user_id` |

⇒ **那句话基本成立，只有一个例外**：**整段翻译**要求登录，因为它的免费额度（10 次/月）
按 `user_id` 记（`translation_usage` 表 + 原子占额）。

### 🔑 这就是试用账号**唯一**的实质价值，也是它被删后唯一的取舍

删掉试用账号后，**新用户点「翻译」会看到已有的提示**（这段提示早就写好、且写得挺好）：

> **登录后可翻译** — 翻译需要账号来记录额度（免费每月 10 次）。登录后即可使用；也可以先关掉，继续读。

📌 取舍记录：**这个提示从「少数人偶尔看到」变成「新用户第一次点翻译必看到」**。
按产品原则「登录 = **能力**开关，不是**可见性**开关」，一个**有边际成本**（LLM 调用）
且需要**配额**的功能要求登录，是可辩护的；如果白哥认为翻译也必须匿名可用，
那是**另一件事**（要把额度改成按 `device_id` 记 + 服务端限流防滥用）—— **本批没做**。

---

## 二、删了什么（端 + 后端 + 数据）

### 端侧

| 文件 | 删除 |
|---|---|
| `providers/auth_provider.dart` | `trialStart()` · `trialClaim()` · `_setTrialUsedFlag()` · `hasUsedTrial()` · `isClaimed()` · `_kTrialUsedKey` · `_clearTrialStorageFlags()`；`tryRestore` 的 `else` 分支不再清标记 |
| `api/auth_client.dart` | `trialStart()` · `trialClaim()`（两个端点调用）|
| `services/auth_session_policy.dart` | `shouldPromptLoginOnLaunch()`（**启动不再弹任何窗**）；只留 `emailFromStoredLoginId` |
| `screens/home_screen.dart` | `_initAuth()` 整块（含那个「等 `isRestored` 最多 20×300ms」的重试循环）· `_showAuthDialog()` · `initState` 里的 `addPostFrameCallback` · 不再 import `authProvider` |
| `screens/profile_screen.dart` | 下拉区里 `if (trial)` 那个补丁项（登录 / 注册）；副标题不再有「试用账号」 |
| `widgets/claim_dialog.dart` → **`auth_dialog.dart`** | 改类名 `ClaimDialog` → `AuthDialog`；删「已登录 ⇒ `trialClaim`（认领）」那条分支 |

**为什么连类名一起改**：「Claim（认领）」是这个已删功能的名字。
留着它，那个概念会从命名里**渗回来**（同族判据：**删掉一个功能后要清理它的语义残留**）。
改名的代价已在上一轮记过（那时判断「留待登录页一并处理」）—— 现在前提没了，正好一起做。

### 后端

| 项 | 处理 |
|---|---|
| `/api/trial/start` · `/api/trial/claim` 两条路由 | 🔴 删除（`routes.rs`）|
| `trial_handler.rs`（整个模块，含 `start` / `claim` 与测试）| 🔴 删除（`git rm`）|
| `lib.rs` 的 `pub mod trial_handler;` | 🔴 删除 |
| `routers` 的 `put` import | 顺手删（它只被 trial/claim 用过 → 编译警告暴露的）|
| `maintenance::hard_delete_expired_trials` | ✅ **保留** —— 它清**存量**账号，不保留就永远占库 |
| `trial_ip_log` 表 + 索引 | ✅ **保留**（**已无写入方**，是历史表）。删它要动 schema 迁移，而它对用户无害；已在 `maintenance.rs` 标注「将来做 schema 清理时可评估删除」|
| `auth.rs` 的 `pub(crate)` 注释 | 更新（原先写「`trial_handler::claim` 也用它」）|

### 🔴 顺带清掉的两个真问题（都是调查里发现的）

1. **「重装即可再白嫖试用」**：`tryRestore` 读不到凭据时会**主动清掉「已用过试用」标记**
   ⇒ 重装后必然又建一个新账号（后端只有「同 IP 每日 3 个」兜着）。**标记本身已删，这条路消失。**
2. **试用账号被写了 1 小时的 `subscription_expires`** ⇒ 界面显示「订阅中」，
   而且**真的**放开了云同步 / 云端书架 / 翻译额度（都读同一个字段）。
   **不再建这类账号，问题从源头消失。**

---

## 三、存量数据（不动）

线上还有 2 个历史试用账号（`trial_1133f074` · `trial_4046c168`），**本次不删**：

- 它们由 `maintenance` 在**创建满 30 天且未认领**后硬删（这是既有机制，保留）
- 端侧**保留兼容**：`AuthState.isRegistered`（= 邮箱非空）与 `emailFromStoredLoginId`
  仍能正确处理「`email` 为 NULL 的存量账号」；`app.dart` 的订阅覆盖层仍放行它们
  （注释已注明：这一支是**存量兼容**，清干净后可一起删）

---

## 四、验证

| 项 | 结果 |
|---|---|
| 端侧静态分析 `analyze_inproc` | **error=0 · warning=0**（170 文件）|
| 后端编译 `cargo check --all-targets` | **0 warning**（先暴露了 `unused import: put`，已修）|
| **后端测试** `cargo test -p api_server` | **270 passed / 0 failed** |
| `verify_auth_entry` | 重写第 ③ 组后 **96 项全绿** |
| 其余断言 | auth 96 · feed 71 · share 87 · sync 62 · review 23 · reading 60 · forgot 60 · iap 165 · reading_tab 78 —— 全绿 |
| `tokens_verify` | 690 通过 / 8 失败 —— **与基线逐条一致**（存量红）|
| **逐条证伪** | **11 条注入全部变红、恢复后零红** |

### 新增/改写的断言（`verify_auth_entry`）

- 🔴 端侧**全库扫描**「没有任何文件再碰 `/api/trial/` · `trialStart(` · `trialClaim(` · `hasUsedTrial(`」
- 🔴 后端不再注册 `/api/trial/` 路由 · 注册入口只剩 `auth/register`
- 🔴 `home_screen` 不再调 `AuthDialog.show` / 无 `_initAuth` / 不再引用 `authProvider`
- 🔴 登录入口**全库恰好一处**（未登录时账号组那一行）—— 这条是本脚本存在的理由
- 🔴 反向：`if (trial)` 补丁、「已登录 · 试用账号」文案、`coevo_trial_used` 均不得复活

### 证伪注入（每条都制造一个真回归）

启动加回弹窗 · 启动加回建号 · `home_screen` 重新引用 `authProvider` ·
删掉未登录行入口 · `if (trial)` 复活 · 「试用账号」文案复活 · 弹窗改回 `trialClaim` ·
端侧加回 `/api/trial/start` · 后端路由复活 · `emailFromStoredLoginId` 不判 `@` ·
`tryRestore` 不再兜底

⚠️ **证伪顺手抓到一条假红**：断言 `!profile.contains('title: auth.email')`
被**正确代码** `subtitle: auth.email ?? '已登录'` 触发（`subtitle:` 里含子串 `title:`）。
已改成**按行首**判定。📌 判据：**子串断言要考虑「被撞的车牌」**（同族：`token`/`tokens`）。

---

## 五、✅ 已部署（2026-10-09 14:26 · 路径 A）

本机侧门禁全绿 → **白哥在 WSL 里构建**（agent 沙箱封禁 `wsl.exe`，文档 §6）→ 我上传 + 原子替换 + 重启。

| 项 | 值 |
|---|---|
| 新二进制 sha256 | `97230edcdbb49476b0f9c554412078eec34fcb41df6ac6524681c64bd5fd8bd3` |
| 回滚点 `.prev` | 旧件 `06869880e03e87495c15f0d53656fa4c8200eaec6e56836fd17ade07f6939c5b` |
| 重启时刻 | `2026-10-09 14:26:47 CST` · 服务 `active` |

### 验收：部署**前**记基线，部署后逐条对上（可证伪）

| 探针 | 部署前 | 部署后 |
|---|---|---|
| `POST /api/trial/start`（无 body）| 415 | **404** ✅ |
| `PUT /api/trial/claim` | 415 | **404** ✅ |
| 阴性对照 `/api/definitely-not-exists` | 404 | 404 ✅（证明 404 判据有效）|
| 阳性对照 `/api/auth/register` / `login` | 415 | 415 ✅（证明探针未被改写）|
| 二进制 `daily_limit_reached` / `api/trial/claim` | 1 / 1 | **0 / 0** ✅ |
| 二进制阳性对照 `api/auth/register` | 1 | 1 ✅（证明 grep 有效）|
| 对外域名 `https://api.keyievolution.fun/api/trial/*` | — | **404** ✅ |
| `/health` · `/api/feed`（对外）| 200 | 200 ✅ |
| 新进程日志 | — | 06:26:47Z：词库 41574 词 · LLM warmup OK · `CoEvo ready` ✅ |
| 重启窗口内 ERROR / panic | — | **无** ✅ |

⚠️ 过程中踩到一个坑并已写入 `docs/deploy/README.md` §7：
**`grep -c` 无匹配时退出码是 1** ⇒ 在 `set -e` 的部署脚本里会**静默中断**
（中断点恰在「打印了个 0、看着正常」处）。首次执行即如此 ——
✅ 好在中断是干净的（**先查状态再重跑**：服务未重启、`.prev` 未覆盖、运行中二进制特征串仍 = 1）。

---

## 六、剩余待办

- ⏳ **端侧**：下次出安卓包时生效（`docs/deploy/README.md` §3）。
- ⏳ **存量试用账号**（线上 2 个）：由 `maintenance` 在创建满 30 天后自动硬删。
  测试机若还登录着 `trial_4046c168`，**退出即可**（现在退出就是「未登录」，不会再自动建号）。
- 🟠 **整段翻译是否要匿名可用**：见 §一末尾的取舍 —— 需要你的判断（本批没动）。
- ⚠️ 文档语义残留已标注 4 处：`design/email-registration-2026-09-29.md` ·
  `features/auth-dialog-unification-plan.md` · `design/profile-redesign-plan-2026-09-29.md` ·
  `design/profile-redesign-2026-09-29.html`
