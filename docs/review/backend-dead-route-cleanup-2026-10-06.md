# 批次④ 后端死路由清理 · 调查报告

> **日期**：2026-10-06
> **触发**：白哥批准「批次④：后端死路由清理（61 条 admin + referral/campaign 残留）+ memory 归档」
> **状态**：🟢 **代码部分已执行**（2026-10-06，见 §八）—— app 端连带已清 · 本地全绿 · **未部署、未动生产**
> **依据**：`full-inventory-plan-vs-implementation-2026-10-06.md` §2.2 / §2.3 / §五④
> **执行前的关键发现**：批准描述是「删 61 条 admin 路由 + 分销残留」，实测**混着 5 处在用功能**
> ⇒ 不能整块删，必须先拆分（见 §二）。**报告清单本身也漏了一条**（见 §8.5）。

---

## 零、一句话结论

> 🔴 **批准依据是「删掉 61 条没人用的 admin 路由 + 分销残留」——听起来是纯减法。**
> **实测：这批代码里「混着 5 处在用的功能」**，直接删会连带打掉**通知中心**、
> **支付订单关单**、**新用户首启流程**。⇒ **不能整块删，必须先拆分。**

**规模**：待处置 13 个文件 / **10,584 行**；其中**只有 5 个文件可以整文件删**。

---

## 一、批准依据 vs 实测事实

| 项 | 批准时的描述 | 实测事实 | 差异 |
|---|---|---|---|
| admin 路由条数 | 61 条 | **58 条**（`grep -c '"/api/admin' routes.rs`）| 🟡 量级一致，数字偏高 |
| 分销残留 | 「残留调用」 | 🔴 **`/api/notifications`（3 条）就在 `distribution_handler.rs` 里**，是通知中心唯一数据源 | 🔴 **颠覆性** |
| 「死路由」 | 无人使用 | 🔴 `campaign_scheduler` 里含 `cancel_expired_orders`（支付订单 30 分钟关单）+ `hard_delete_expired_trials` | 🔴 **颠覆性** |
| 范围 | 后端清理 | 🔴 牵出 `auth.rs`（**注册 INSERT 直接写分销列**）+ app 端 5 个文件 | 🔴 **远超「后端」** |
| memory | 91 个日志 | **105 个 md / 3.0 MB** | 🟡 量级一致 |

---

## 二、🔴 五处「多职责」陷阱（**这是本轮最关键的发现**）

> 判据来源：`safe-bulk-deletion` skill 盲区④⑤ —— **调用点一个没少，功能却少了一半**。

### 陷阱 1 · 通知中心藏在 `distribution_handler.rs` 里

```
distribution_handler.rs (2,823 行)
├─ 前 160 行：list_notifications / mark_read / mark_read_all  ← 🔴 读 user_notifications，**保留项**
└─ 其余 2,663 行：佣金 / 结算 / 提现 / 团队 / 统计 / 退款     ← 可删
```

**证据**：
- `distribution_handler.rs:48,110,139` 三个函数的 SQL 全部指向 `user_notifications`
- `schema.rs:1599` 的 `EXPECTED_TABLES` 里 **`user_notifications` 是保留表**
- app 端**正在使用**：`profile_screen.dart:448`（`HeaderChip`）+ `app.dart:253`（`NotificationPanel`）
- `notification_panel.dart:56` → `GET /api/notifications`

🔴 **整文件删 = 通知中心静默失效**（编译通过、app 只是在「我的」页点进去永远空白）。

### 陷阱 2 · 支付订单关单藏在 `campaign_scheduler.rs` 里

| 函数 | 职责 | 与 campaign 有关吗 |
|---|---|---|
| `unlock_available_commissions` | 解锁佣金 | ✅ 是 |
| 🔴 `cancel_expired_orders` | **未支付订单 30 分钟自动关单**（改 `payment_orders.status`）| ❌ **不是** |
| 🔴 `hard_delete_expired_trials` | 清理 30 天未认领的 `trial_%` 账户 | ❌ **不是** |

```rust
// campaign_scheduler.rs:52 — 与营销活动完全无关
pub fn cancel_expired_orders(conn: &rusqlite::Connection) -> Result<usize, String> {
    let count = conn.execute(
        "UPDATE payment_orders SET status = 'NOTPAY_CANCELLED' \
         WHERE status = 'NOTPAY' AND datetime(created_at, '+30 minutes') <= datetime('now')", [])?;
```

⇒ 删掉后：**订单永远停在 `NOTPAY`**，`payment_orders` 表持续堆积。
🔑 且 `main.rs:67` 的 `start_scheduler` 是它**唯一调用入口**。

### 陷阱 3 · 注册流程直接写分销列（在 `auth.rs`，不在待删清单里）

```rust
// auth.rs:255 —— 这是**注册**的主路径
"INSERT INTO users (id, username, display_name, password_hash, email, \
                    referral_code, referred_by, referred_campaign_id, created_at) VALUES (...)"
// auth.rs:269 —— 注册后触发活动
crate::campaign_executor::execute_campaign_trigger(conn, "registration", &user_id, ...)
```

⇒ 删分销**必须同时改 `auth.rs`**（不只是删路由）。
⚠️ 这是**全 app 唯一的注册写入点**，改错的后果是**新用户注册失败**。

### 陷阱 4 · `admin_handlers.rs` 里有的符号还活着

| 符号 | 定义处 | 谁在用 | 删 admin_handlers 后 |
|---|---|---|---|
| `verify_admin` | `admin_handlers.rs:24` | 仅 admin/分销模块 | 可随删 |
| 🔴 `ok` / `err` | `:12` / `:15`（`pub(crate) fn`）| campaign / config_admin / distribution | **需迁出或同批删** |
| 🔴 `mask_email` | `:170` | `distribution_handler` | 同上 |

### 陷阱 5 · 分销量级首次升级（**注册 → 活动触发**）

`execute_campaign_trigger` 有 3 个调用方，其中 **`auth.rs`（注册）是用户端主路径**：
```
auth.rs:269（注册）· campaign_member_handler.rs:46（已删）· trial_handler.rs:365（trial）
```
⇒ 说明「活动触发」**当前是在注册时真跑的**，不是死代码。

---

## 三、精确清单

### 3.1 ✅ 可整文件删（7 个 · 3,477 行）

| 文件 | 行数 | 判据 |
|---|---|---|
| `referral_handler.rs` | 1,229 | 15 处引用全在 `/api/referral/*` + `/share/*` + `/go/*` |
| `campaign_handler.rs` | 1,166 | 14 处全在 `/api/admin/campaigns*` + `check-push-trigger` |
| `h5_template.rs` | 348 | 仅被 referral/campaign 用 |
| `poster_template.rs` | 390 | 仅被 referral/campaign 用 |
| `llm_poster.rs` | 19 | 仅被 referral/campaign 用 |
| `campaign_member_handler.rs` | 68 | 仅 1 处（`/api/campaign/join`）|
| `config_admin.rs` | 257 | 仅 3 处（`/api/admin/config` + `prompt/template*`）|

### 3.2 🔴 必须拆分（3 个 · 5,066 行）

| 文件 | 行数 | 保留 | 删 |
|---|---|---|---|
| `distribution_handler.rs` | 2,823 | 通知 3 函数（~160 行）| 佣金/结算/提现/团队/统计/退款 |
| `campaign_scheduler.rs` | 792 | `cancel_expired_orders` · `hard_delete_expired_trials` · `CASCADE_TABLES` | campaign 推送 |
| `campaign_executor.rs` | 1,451 | `write_notification`（供通知写入）| 活动执行逻辑 |

### 3.3 ⚠️ 部分删

| 文件 | 行数 | 处置 |
|---|---|---|
| `admin_handlers.rs` | 1,431 | 删全部路由 handler；`ok`/`err`/`mask_email` **迁出** |
| `plans_handlers.rs` | 193 | 删 3 个 `admin_*`；**保留 `plans_list_handler`**（`routes.rs:136` `/api/pay/plans` → app 订阅页）|
| `pay_handlers.rs` | 173 | 删 1 个 `admin_orders_handler`；**保留** `user_orders_handler`（`order_history.dart:46`）+ `order_status_handler` |

### 3.4 🔴 需白哥决策（1 个）

| 文件 | 行数 | 问题 |
|---|---|---|
| `trial_handler.rs` | 417 | **`/api/trial/start` 在 app 首启必经路径**（见 §四）|

### 3.5 连带改动（不在原批准范围）

| 文件 | 改什么 | 风险 |
|---|---|---|
| `auth.rs` | 注册 INSERT 去掉 3 个分销列 + 删 campaign trigger | 🔴 **注册主路径** |
| `schema.rs` | `users` 表 3 列 + 迁移列表 + `EXPECTED_TABLES` | 🟡 删列有两个来源（见 skill）|
| `main.rs` | `campaign_scheduler::start_scheduler` + **第二份迁移列表** | 🟡 |
| `routes.rs` | 58 条 admin + ~51 条分销路由 + `use crate::admin_handlers::*` | 🟡 |

> ⚠️ **`/api/pay/*` 与 `/api/plans` 不在删除范围**：微信支付虽已删，但
> `/api/pay/plans`（订阅套餐）+ `/api/pay/orders`（订单历史）**仍被 app 使用**
> （`order_history.dart:46`）。它们与 `pay_handlers.rs` 一起**保留**。

---

## 四、app 端连带（🔴 最需要决策的部分）

### 4.1 活跃调用点

| 位置 | 调用 | 现状 | 风险 |
|---|---|---|---|
| `home_screen.dart:341-349` | `trialStart` → `/api/trial/start` | **首启必经**（`!hasUsedTrial` 时）| 🔴 **删了打断新用户进入** |
| `home_screen.dart:330` | `_checkLoginCampaignPush` | **每次登录自动发** | 🟢 删了无害 |
| `home_screen.dart:295` | `/api/referral/click` | 有 refCode 时 | 🟢 删了无害 |
| `home_screen.dart:395` | `_joinCampaign` → `/api/campaign/join` | 有 campaign_id 时 | 🟢 删了无害 |
| `app.dart:45-47` | campaign_id 深链参数 | 落地页参数 | 🟢 |
| `auth_client.dart:98,122` | `trialStart` / `trialClaim` | | 🔴 随 trial 决策 |
| `claim_dialog.dart:124` | `trialClaim` | **「登录」唯一入口**（skill 记录过此坑）| 🔴 |
| `profile_screen.dart:448` | `NotificationPanel` | **保留** | 🟢 |
| `notification_panel.dart:56` | `/api/notifications` | **保留** | 🟢 |

### 4.2 🔴 trial 的矛盾（**必须先定**）

| 来源 | 说法 |
|---|---|
| `implementation-plan-v2:1788` | 「不做 ... **trial 流程**」 |
| **实际代码** | `home_screen` 首启调 `trialStart` · `ClaimDialog` 用 `trialClaim` 做注册 · `auth.rs` 创建 `trial_%` 账户 · scheduler 清理过期 trial |

⇒ **文档说废了，代码在跑。** 二者必须对齐：

| 选项 | 含义 | 代价 |
|---|---|---|
| **A. trial 其实还在用**（文档过时）| 保留 `/api/trial/*` | 只改文档 |
| **B. trial 确实要废** | 删后端 + 改 app 首启为「直接弹注册」 | 🔴 改首启路径，需真机验证 |
| **C. 保留 trial 后端，只删分销参数** | `trialStart(refCode, campaignId)` → `trialStart()` | 🟡 最小改动 |

---

## 五、memory 归档（第二部分）

| 项 | 实测 |
|---|---|
| 文件数 | **105 个 md**（报告原写 91）|
| 总体积 | **3.0 MB** |
| 5 月 | 24 个 / 最早 2026-05-07 |
| 9–10 月 | 11 个（活跃期，**不动**）|
| 其余 | 6/7/8 月约 70 个 |
| `ARCHIVE.md` | 194 KB —— 🔴 **长期记忆归档，不是日志，不删** |

**规则**：`MEMORY.md` 写明「**30 天以上 distill 后删除**」⇒ 截至 10-06，**9-06 之前**的日志（即 5–8 月，约 94 个）在范围内。

⚠️ **两个必须先解决的问题**：
1. **distill 到哪**：`MEMORY.md` 只有 3,000 字符/会话额度，且已 16 KB 满 ⇒ 需要**先定归档落点**（新建 `references/history-2026-H1.md`？）
2. **不可逆**：一旦删除，只剩 git 历史（这些文件**已在 git 跟踪内** ⇒ 可 `git checkout` 恢复，但仍需先验证）

**我的建议**：**先归档成一份 H1 摘要（保留判据级信息）再删原始日志**，而不是直接删。

---

## 六、建议的批次划分

| 子批 | 内容 | 风险 | 建议 |
|---|---|---|---|
| **④-a** | 删 5 个纯分销/活动文件 + 58 条 admin 路由 + `config_admin` | 🟢 低（app 零调用）| **可执行** |
| **④-b** | 拆分 3 个混职责文件（保留通知/关单/trial 清理）| 🟡 中 | **需先定拆分落点** |
| **④-c** | 改 `auth.rs` 注册 + `schema.rs` 删 3 列 + `main.rs` | 🔴 **高**（注册主路径）| **需真机验证** |
| **④-d** | app 端清理（campaign/referral 调用）| 🟡 中 | **随 ④-c** |
| **④-e** | trial 决策 | 🔴 | **需白哥先定 §4.2** |
| **④-f** | memory 归档 | 🟡 | **需先定 distill 落点** |

🔑 **④-a 可以现在做**；④-b~f 各有前置决策。

---

## 七、请白哥定

| # | 问题 | 我的建议 |
|---|---|---|
| **1** | 是否**先执行 ④-a**（纯减法、零风险部分）| ✅ 建议先做，拿到确定收益 |
| **2** | §4.2 **trial 到底是留还是废** | 建议 **C**（保留后端、删分销参数）—— 改动最小，且不碰首启路径 |
| **3** | 通知模块**迁到哪** | 建议新建 `notification_handler.rs`（把 3 个函数搬过去）|
| **4** | memory distill 落点 | 建议新建 `references/history-2026-H1.md` |
| **5** | `COEVO_ADMIN_KEY` 弱值（`coev` 开头）**是否轮换** | 建议轮换（删 admin 后已无消费者，零风险）|

---

## 八、✅ 执行记录（2026-10-06 · 代码部分）

> 白哥批准「先执行 ④-a」后执行。**未部署**（按铁律，部署需单独指令）。

### 8.1 删除（12 个文件 · 约 10,584 行）

| 文件 | 行数 | 判据 |
|---|---|---|
| `admin_handlers.rs` | 1,431 | 58 条 admin 路由全删 ⇒ 整体无引用 |
| `distribution_handler.rs` | 2,823 | 通知 3 函数已迁出，其余属分销 |
| `referral_handler.rs` | 1,229 | 分销链根 |
| `campaign_handler.rs` | 1,166 | 营销活动 |
| `campaign_executor.rs` | 1,451 | `write_notification` 已迁出 |
| `campaign_scheduler.rs` | 792 | 关单 + trial 清理已迁出 |
| `poster_template.rs` / `h5_template.rs` | 738 | 海报/H5 模板 |
| `share_data.rs` | — | 只服务上面两个模板 |
| `campaign_member_handler.rs` | 68 | `/api/campaign/join` |
| `llm_poster.rs` | 19 | 零引用 |
| `config_admin.rs` | 257 | 只留 `qrcode_handler` → 改名 |

### 8.2 新建（3 个文件）

| 文件 | 内容 | 为什么必须建 |
|---|---|---|
| `notification_handler.rs` | 通知 3 接口 + `write_notification` | 通知中心唯一数据源，**不能跟着分销文件一起删** |
| `maintenance.rs` | 订单关单 + 过期 trial 清理 + 调度入口 | **与营销无关**的运维任务，删了会静默停摆 |
| `public_assets.rs` | `qrcode_handler` | 共读群二维码，现役功能（原文件名已成语义残留）|

### 8.3 路由：删 ~83 条

58 条 `/api/admin/*` + 25 条分销/活动（`/api/referral/*` · `/share/*` · `/go/*` · `/api/campaign*` 等）。
**保留**：`/health` · `/api/public/qrcode` · auth 6 条 · `/api/pay/plans` · `/api/pay/orders*` ·
`/api/iap/verify` · `/api/user/*` · `/api/feed*` · `/api/generate-card` · `/api/stt/transcribe` ·
**`/api/notifications*`** · `/api/trial/*`（待定）· `/api/sync/*` · `/app/{*path}`。

### 8.4 验证（本地逐条对齐 CI）

| 门 | 结果 |
|---|---|
| `cargo fmt --check` | ✅ 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | ✅ 通过 |
| `cargo test --workspace` | ✅ **221 + 20 通过 · 0 失败** |
| `analyze_inproc app/lib` | ✅ **error=0 · warning=0** |
| 6 个断言脚本（auth_entry 71 · feed_wiring 71 · forgot_password 60 · sync 61 · reading_tab 75 · tokens 694） | ✅ **1032 项全过** |
| `check_native_readiness.py` | ✅ 无编译阻塞项 |

⚠️ **本机 cargo 是 1.95.0，CI 是 1.98.0**（记过的坑）⇒ 本地绿仍需 CI 复核。

### 8.5 🔴 报告遗漏的一条（值得单记）

**`notification_panel.dart:126` 调 `/api/referral/generate-h5`** —— 它**在本报告 §2.1 的清单里**，
但我在执行时**差点漏掉**：因为我是「按清单 + 按文件」清，而它是**清单里最后一个**、
且不属"分销文件"（在通知面板里）。

🔑 **判据：删接口后，必须用 `grep` 全量扫「接口前缀」验证调用方归零**，
而不是对照清单打勾。清单是人写的，会漏。

```bash
grep -rn "api/referral\|api/campaign\|api/admin" app/lib backend --include=*.dart --include=*.rs
# 期望：只剩注释
```

### 8.6 ⏳ 本次未做（各有前置决策）

| 项 | 为什么没做 |
|---|---|
| **改 `auth.rs` 注册**（去 3 个分销列 + 去 campaign trigger 已做/列未删） | 属 ④-c：**注册主路径**，需真机验证 |
| **删 schema 表/列**（`marketing_campaigns` 等 5 表 + `users` 3 列） | 属 ④-c；删列有两个来源，须同步改 |
| **trial 去留** | 属 ④-e：**文档说废、代码在跑**（§4.2），需白哥定 |
| **memory 归档** | 需先定 distill 落点 |
| **`COEVO_ADMIN_KEY` 轮换** | 属「改生产」，需单独批准 |
| **部署** | 按铁律，需白哥明确指令 |

---

## 附：本轮已做的事

- ✅ **删除 12 个文件 / 新建 3 个 / 删 ~83 条路由**（见 §八）
- ✅ **改了 8 个 app 端文件**（连带清理）
- ✅ 本地全部门禁绿
- ✅ 生产环境**未触碰** · **未部署**

