# 账号注销（用户自助）· 设计与实施（2026-10-04）

> 白哥 2026-10-04：「账号注销**本批做**」。
> 🔴 这是**不可逆操作** ⇒ 本文档先定清「删什么 / 留什么 / 依据是什么」，再动手。

---

## 一、合规要求（**Apple 官方原文**，不靠记忆）

来源：Apple 5.1.1(v) 拒审信原文（开发者在 Apple 官方论坛贴出）

> Apps that support account creation **must also offer account deletion**...
> - **Only offering to temporarily deactivate or disable an account is insufficient.**
> - If users need to visit a website to finish deleting their account, include a link directly to the website page
> - Apps **may include confirmation steps** to prevent users from accidentally deleting their account
> - only apps in highly-regulated industries may require users to use customer service resources,
>   such as making a phone call or **sending an email**, to complete account deletion

| # | 约束 | 对我们的影响 |
|---|---|---|
| 1 | **停用/禁用不够** | 🔴 **必须硬删** ⇒ 现有的 `admin_delete_user`（软删 `deleted_at`）**不能**用于用户自助注销 |
| 2 | 可加确认步骤 | ✅ 二次确认**允许**（且推荐）|
| 3 | 🔴 **不得要求发邮件** | 🔴 **隐私政策 §六 现写「通过【注销入口或联系邮箱】提交申请」⇒ 不合规，必须改为 App 内自助** |

> 📌 第 3 条是本次的**实质性发现**：不只是「填个占位符」，
>    而是要把「**申请制**」改成「**自助制**」。

## 二、法律文本已有的承诺（**必须兑现，不是可选**）

| 出处 | 原文 |
|---|---|
| 隐私政策 §五 | 「你注销后：我们会在合理期限内**删除或匿名化**（法律法规另有要求的除外）」|
| 用户协议 §三.5 | 「注销后，服务端保存的账号数据将被**删除或匿名化**（**注意**：你设备上的学习数据不会因注销而删除）」|

⇒ ✅ **政策已覆盖「删除或匿名化」两种处理** ⇒ 本设计**不需要改法律文本的实体内容**
（只需把 §六 的入口描述从「申请」改为「自助」）。

---

## 三、🔴 数据引用图（**实测，不靠列名猜**）

「含 `user_id`」是**不完整**的判据 —— 分销表用了**换名列**：

| 表 | 关联列 | 备注 |
|---|---|---|
| `tokens` | `user_id` | |
| `user_preferences` | `user_id` | |
| `user_notifications` | `user_id` | |
| `payment_orders` | `user_id` | |
| `iap_transactions` | `user_id` | 🆕 本批新增 |
| `subscription_audit_log` | `target_user_id` | 🔴 **换名** |
| `admin_audit_log` | `target_user_id` | 🔴 **换名** |
| `subscription_requests` | `target_user_id` | 🔴 **换名** |
| `reward_fulfillments` | `user_id` | |
| `campaign_members` | `user_id` | |
| `referral_clicks` | `referrer_id` | 🔴 **换名** |
| `distribution_commissions` | `earner_id` + `buyer_id` | 🔴 **换名 ×2** |
| `distribution_expenses` | `earner_id` | 🔴 **换名** |
| `trial_ip_log` | ❌ **不含用户标识** | 只有 `ip` + `created_at` ⇒ **与注销无关** |

其他表（`content_pool` / `content_source` / `app_config` / `subscription_plans` /
`generated_card_cache` / `generated_card_hit` / `marketing_campaigns` / `admin_users`）
**与普通用户无关** ⇒ 不动。

> 🔑 判据：**「引用图」必须实测** —— 只按一个列名 grep 会**漏掉 7 张表**。
> （同族：项目已记「**判据有洞时先问『还有哪些地方有』再一次性改全**」。）

---

## 四、逐表策略（🔴 不是「一律删」）

分两类：**个人数据 → 删**；**交易/审计 → 匿名化**（法定保存义务）。

| 表 | 策略 | 依据 |
|---|---|---|
| `tokens` | 🔴 **删** | 登录凭据 —— 注销后必须立刻失效 |
| `user_preferences` | 🔴 **删** | 个人设置，无保留义务 |
| `user_notifications` | 🔴 **删** | 个人通知 |
| `users` | 🔴 **删（硬删）** | Apple：「仅停用不够」|
| `subscription_requests` | 🔴 **删** | 个人的申请记录，无保留价值 |
| `campaign_members` | 🔴 **删** | 个人的活动参与记录 |
| `payment_orders` | 🟡 **匿名化 `user_id`** | 交易记录 —— 法定保存义务 + Apple 对账 |
| `iap_transactions` | 🟡 **匿名化 `user_id`** | Apple 交易凭据 |
| `subscription_audit_log` | 🟡 **匿名化 `target_user_id`** | 订阅审计留档 |
| `admin_audit_log` | 🟡 **匿名化 `target_user_id`** | 管理操作审计留档 |
| `reward_fulfillments` | 🟡 **匿名化 `user_id`** | 与订单关联的分销记录 |
| `referral_clicks` | 🟡 **匿名化 `referrer_id`** | 分销统计 |
| `distribution_commissions` | 🟡 **匿名化 `earner_id` + `buyer_id`** | 分销对账（两个列都要）|
| `distribution_expenses` | 🟡 **匿名化 `earner_id`** | 分销对账 |
| `trial_ip_log` | ⚪ **不动** | 不含用户标识；反滥用用途（隐私政策已披露）|

**匿名化方式**：`"deleted:" + <新生成的 uuid>`

| 为什么这样 | |
|---|---|
| 不可反查 | 新 uuid 与用户无任何数学关联（**不用 `hash(uid)`** —— 哈希可被撞库对照）|
| 一眼可辨 | 前缀 `deleted:` 让运维/日后查数据时立刻知道「这是已注销用户」|
| 满足审计 | 一条交易记录仍可追溯「有一笔交易」，但**追不到人** |

---

## 五、🔴 顺带发现的两个真 bug（`admin_hard_delete_user`）

> ⚠️ 这两个 bug **不在「账号注销」的字面范围内**，但属**同一功能族**（都是「彻底删用户」）。
> 不一起修 ⇒ **两个入口删出不同结果**（更糟）。
> 📌 判据：「**补丁 ≠ 修法** —— 判据有洞时先问『还有哪些地方有』再一次性改全」。
> 🔴 **若白哥认为该另立项，请否决这一节**（我会只做用户自助注销，不动 admin）。

### Bug 1：删除列表**漏 7+ 张表** ⇒ 静默留孤儿

`admin_handlers.rs:528` 现为：

```rust
let tables = [
    "DELETE FROM user_preferences WHERE user_id=?1",
    "DELETE FROM tokens WHERE user_id=?1",
    "DELETE FROM users WHERE id=?1",
];
```

🔴 **漏掉**：`user_notifications` · `iap_transactions` · `payment_orders` ·
`subscription_audit_log` · `campaign_members` · `subscription_requests` ·
`reward_fulfillments` · `referral_clicks` · `distribution_*` · `admin_audit_log`

⚠️ **且不会报错**：SQLite 的 `PRAGMA foreign_keys` **默认 OFF**
⇒ 删 `users` 行不触发约束检查 ⇒ **孤儿数据静默留下**。
这正是本项目反复警惕的「**静默失效**」。

### Bug 2：归档文件**被覆盖**（不是追加）

```rust
let _ = std::fs::write(          // 🔴 write = 覆盖整个文件
    std::path::Path::new("data").join("deleted_users.ndjson"),
    format!("{}\n", ...)
);
```

注释说「归档记录写入 `data/deleted_users.ndjson`」，
但 `std::fs::write` 会**截断覆盖** ⇒ **第二次硬删把第一次的归档冲掉**。

⇒ 修：改用 **append**（`OpenOptions::append(true)`）。

---

## 六、接口设计

### 6.1 `POST /api/user/me/delete`（🆕 用户自助注销）

| 项 | 值 |
|---|---|
| 方法 | `POST`（不是 `DELETE`）——⚠️ 因为要在**事务里做多步**，且 WebView/代理对 DELETE 带 body 支持不一 |
| 鉴权 | 🔴 **必须登录**；**只能注销自己**（从 token 解析 uid，**不接受 body 传 uid**）|
| 幂等 | 用户已不存在 ⇒ 返回 **200**（已注销视为成功），不报 404 |
| 事务 | `BEGIN IMMEDIATE` → 全部成功才 `COMMIT`，任一失败 `ROLLBACK` |
| 响应 | `{"status":"deleted"}` |

**⚠️ 不接受 body 传 uid** 是**安全要点**：
若接口接受 body 里的 uid，一个已登录用户就能**注销别人**。
⇒ uid **只能**来自 token。

### 6.2 共享实现（口径单点）

新建 `user_purge.rs`：

```rust
pub enum PurgeMode {
    /// 用户自助注销 —— 不写 PII 归档
    SelfService,
    /// 管理员硬删 —— 写运维归档（含 email，便于运维辨识）
    AdminArchive,
}

pub fn purge_user(conn: &Connection, uid: &str, mode: PurgeMode, actor: &str)
    -> Result<PurgeReport, String>;
```

**为什么抽共享函数**：`admin_hard_delete_user` 与用户自助注销是**同一件事**
（彻底删一个用户）。各写一份 ⇒ 删除列表会**漂**（现在已经漂了 —— admin 那份漏 7 张表）。
📌 判据：**同一件事的口径只能一处权威**。

---

## 七、前端设计

| 项 | 做法 |
|---|---|
| 位置 | 「我的」页 → 「其他」分组（低頻操作，与「关于」同族）—— 依据已入 skill 的「控件放哪」两维度 |
| 入口文案 | 「注销账号」·副标题「永久删除账号与云端数据」 |
| 二次确认 | 🔴 **必须**（Apple 明确允许）；用既有 `CoDialog` |
| 确认弹层文案 | ① 不可恢复 ② **端侧学习数据不受影响**（🔴 与用户协议 §三.5 一致 —— 不写清会被误解）③ 订阅不因此退款（由 Apple 处理）|
| 操作后 | 清本地登录态 → 回首页 → 提示已注销 |

---

## 八、法律文本要改的一处

隐私政策 §六 现为：

> \| **注销账号 / 删除个人信息** \| 通过【待填：注销入口或联系邮箱】提交申请 \|

🔴 **改为**：

> \| **注销账号 / 删除个人信息** \| 在应用内「我的」页面直接注销（**无需联系客服**）\|

依据：Apple 5.1.1(v) 明确**不允许**要求用户发邮件/打电话才给注销
（除高度监管行业 —— 我们不是）。

---

## 九、实施顺序

| # | 步骤 |
|---|---|
| 1 | 后端 `user_purge.rs`（共享实现 + 逐表策略 + 事务）|
| 2 | 后端 `POST /api/user/me/delete` handler + 路由 |
| 3 | 改造 `admin_hard_delete_user` 调用共享函数（修 Bug 1/2）|
| 4 | 前端：「我的」页入口 + 二次确认弹层 |
| 5 | 法律文本 §六 改「自助」+ 回填 → 重新部署法律页 |
| 6 | 验证：真断言 + **副本演练** + 正反双验证 + 证伪 |
| 7 | 文档 + 记忆 + 提交 |

---

## 十、🔴 已知风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| **误删不可恢复** | 🟠 中 | 二次确认（文案写清「不可恢复」）· 不做冷静期（Apple 允许，但会让「注销」语义模糊）|
| 漏删某张表 | 🔴 高 | **副本演练 + 正反双验证**（该删的删了 / 不该删的还在）|
| 匿名化不彻底（留了可反查字段）| 🟠 中 | 断言：注销后**全库不得再出现**该 uid 字符串 |
| 事务中途失败留半删状态 | 🟠 中 | `BEGIN IMMEDIATE` + ROLLBACK；失败返回 500 且状态不变 |
| 生产库误操作 | 🟡 低 | 生产库仅 1 条用户、**零交易** ⇒ 演练在**本地副本**做 |

---

## 十一、✅ 实施记录（2026-10-04 当天完成）

### 11.1 交付清单

| # | 文件 | 动作 |
|---|---|---|
| 1 | `backend/crates/api_server/src/user_purge.rs` 🆕 | **服务层 + handler**：逐表策略 · 事务 · 幂等 · FK 关/恢复 · 匿名化 · 归档（append）· **11 个单测** |
| 2 | `backend/crates/api_server/src/lib.rs` | 注册 `pub mod user_purge;` |
| 3 | `backend/crates/api_server/src/routes.rs` | `POST /api/user/me/delete` |
| 4 | `backend/crates/api_server/src/admin_handlers.rs` | `admin_hard_delete_user` **改用共享函数**（90 行 → 55 行）|
| 5 | `app/lib/screens/profile_screen.dart` | 注销入口 + 二次确认弹层 + `_doDeleteAccount` |
| 6 | `docs/legal/privacy-policy.md` | §六 「通过邮箱提交申请」→「**应用内直接注销（无需联系客服）**」|
| 7 | `scripts/legal/build_legal_pages.py` | 删掉「注销入口」占位符映射（不再需要）|
| 8 | `scripts/iap_verify/bin/verify_iap_plan.dart` | §⑨ 新增 **14 项**注销断言（85 → 99 项）|

### 11.2 关键设计落点

| 点 | 做法 |
|---|---|
| **只能删自己** | uid **从 token 反查**（`resolve_uid_from_token`）⇒ 协议上无法指定他人 |
| **硬删** | `DELETE FROM users`（Apple：「仅停用不够」）|
| **交易保留** | 9 个「匿名化」目标（含 `referrer_id` / `earner_id` / `buyer_id` 等**换名列**）+ `users.referred_by` |
| **FK 处理** | `PRAGMA foreign_keys = OFF`（**BEGIN 之前**，事务内是 no-op）→ 操作 → **无条件恢复 ON** |
| **幂等** | 用户不存在 ⇒ 返回成功（`already_deleted`），不报错 |
| **事务** | `BEGIN IMMEDIATE` + 失败 `ROLLBACK`（含「回滚也失败」的二次报错）|
| **归档** | 仅管理员模式写；**append**（不是覆盖）；快照在**删除前**取 |
| **自助注销不写归档** | 用户已要求删除 ⇒ 不在磁盘留含 email 的副本 |

### 11.3 验证结果

| 层 | 结果 |
|---|---|
| `cargo check` / `fmt` / `clippy --all-targets -D warnings` | ✅ 全过 |
| `cargo test --workspace` | ✅ **api_server 200 + chat_engine 20 = 220 passed / 0 failed** |
| `scripts/iap_verify` | ✅ **99 项全过**（85 → 99）|
| `codestatic`（前端符号解析）| ✅ warning 0 |
| **证伪** | ✅ 注入「路由改名 + 政策改回申请」→ **3 项变红、退出码 1** |
| 法律页重新部署 | ✅ 幂等自检通过 · 公网 200 |

### 11.4 🔴 过程中踩到的 5 个坑（都值得记）

| # | 坑 | 教训 |
|---|---|---|
| 1 | **测试 fixture 列名凭印象写**（`user_preferences` 漏了 NOT NULL 的 `updated_at`）⇒ **10 个测试全红** | **fixture 也是「实现」，要与真实结构对齐** —— 不能猜 |
| 2 | `contains("user_id")` 把 `target_user_id` 也匹配上 ⇒ 静态断言**假红**（报了 3 张不含该列的表）| **断言的匹配粒度必须等于它的语义粒度** —— 问「有没有这一**列**」，不是「有没有这段字符」 |
| 3 | 模块文档里的 SQL 代码块**被当 doctest 编译** ⇒ `cargo test` 失败 | ` ```text ` 标注非 Rust 代码块 |
| 4 | 在 **Python** 文件里写 `//` 注释 ⇒ `SyntaxError` | **改了脚本必须跑语法检查**（比「读一遍」可靠） |
| 5 | 用了**不存在**的 token 字段 `t.danger` | 组件/常量的字段名**不能凭印象** —— 先 grep 再用 |

### 11.5 与「本机无法验证 UI」的关系

| 项 | 状态 |
|---|---|
| 后端（含 11 个单测）| ✅ **本机完整验证** |
| 前端符号解析 | ✅ 通过（唯一 error 集中在 `iap_service.dart` —— 本地缺 `in_app_purchase` 的**假红**）|
| **UI 渲染 / 交互** | 🔴 **本机不可验证**（`flutter` 建不了子进程）⇒ 靠 CI 编译 + 白哥真机 |

### 11.6 ⏳ 待白哥真机验证（做完 logout 后）

| 步骤 | 期望 |
|---|---|
| 「我的」页（已登录）→ 底部 | 看到「注销账号」（在「退出账号」上方）|
| 点它 | 弹层出现，三条说明（不可恢复 / 端侧数据不受影响 / 不自动退订）|
| 点「取消」 | 无事发生，账号仍在 |
| 点「确认注销」 | 提示「账号已注销」→ 自动登出 → 回首页 |
| 再登录同一邮箱 | 应提示账号不存在（**已被删除**）|
| 🔴 **生词本** | 注销后重装/重新登录，**生词与复习记录仍在**（端侧数据未被删）|
