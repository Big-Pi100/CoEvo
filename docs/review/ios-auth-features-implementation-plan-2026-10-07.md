# 实施记录：Apple 登录 · 修改邮箱（2026-10-07）

> ✅ **2026-10-07 已执行完毕**（提交 `c1fa1c4`，**未部署**）——
> 本文档因此从「实施计划」升级为「实施记录」：保留原计划 + 追加实际结果与更正。
> **触发**：白哥定「都做吧」（此前评估结论：两项都**不阻塞上架**，属产品增强）。
> 🔴 **§〇 有一条重要更正**（关于 `.p8`）—— 我原以为登录需要它，
>    查 Apple 官方文档后确认**不需要**，详见该节。

---

## 〇、外部依赖（含一条**执行时的更正**）

| 功能 | 外部依赖 | 状态 |
|---|---|---|
| **Apple 登录** | ① App ID 勾 **Sign in with Apple** capability（**必需**）<br>② ~~生成 Key（`.p8`）~~ ← **见下方更正** | ✅ 白哥已完成 |
| **修改邮箱** | 腾讯云 SES：把模板**正文**改成中性文案 | ⏳ 待白哥在控制台改 |

### 🔴 更正：`.p8` **不是「登录」所需**

原文把「生成 Key（`.p8`）」列为 Apple 登录的必要条件 —— **那是错的**。
查 Apple 官方文档（`signinwithapple/verifying-a-user`）后确认：

| 事项 | 需要什么 | `.p8` 用得上吗 |
|---|---|---|
| **验证 `identityToken`**（= 登录本身）| **只需 Apple 公钥（JWKS）** | ❌ **不需要** |
| 用 `authorizationCode` 换 refresh token | `client_secret`（`.p8` + Team ID + Key ID 生成）| ✅ 需要 |
| 注销时向 Apple **撤销授权** | 同上（且先要有 token 可撤）| ✅ 需要 |

⇒ 白哥生成的 `.p8` **没有浪费**，但它的用途是**「注销时撤销 Apple 授权」**，不是登录。
⚠️ 而真要用它时**必须重新实现登录那一步** —— 因为 `authorizationCode`
**只在登录那一刻存在**，事后补不了（详见 `apple_auth.rs` 文件头的「有意不做」表）。

### 为什么「修改邮箱」也有外部依赖（原以为没有）

`tencent_ses.rs` 里主题原为**硬编码**：

```rust
const SUBJECT: &str = "CoEvo 密码重置验证码";   // 已改为 "CoEvo 验证码"
```

⇒ 复用同一条发送通道会让「改邮箱」的邮件**标题写着「密码重置」** ⇒ 严重误导
（用户会以为账号被盗）。
📌 判据：**发信类功能复用时，「收件人看到什么」必须一并中性化或区分** ——
**代码这半我已改**（主题 + 函数改名），**控制台那半（模板正文）需要白哥改**。

---

## 一、已完成（本轮）

### 1.1 数据库：新增 `email_change` 表 ✅ 已验证

`backend/crates/api_server/src/schema.rs`：

```sql
CREATE TABLE IF NOT EXISTS email_change (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, new_email TEXT NOT NULL,
    code_hash TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
    expires_at INTEGER NOT NULL, used_at INTEGER, created_at INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
-- + idx_email_change_user · idx_email_change_new_email
```

**为什么不能复用 `password_reset`**（两条理由）：
1. **验证对象不同** —— 那张表按 `user_id` 关联（给本账号重置密码）；
   改邮箱要证明的是「**新**邮箱属于你」，发信目标是**新邮箱**。
2. **用途必须隔离** —— 共用一张表 ⇒ 用户能拿「找回密码」的码去改邮箱
   （或反向）⇒ 低风险动作的凭据被**升级**成高风险动作的凭据。

**验证方式**（不是"看起来对"）：把 `SCHEMA_SQL` 抽出来在内存 SQLite 里**完整执行**一遍
（等价于 `init_database`），再 `PRAGMA table_info` 反查列与索引 —— 全部通过。

---

## 二、实现内容（2026-10-07 已完成）

### 2.1 修改邮箱（不需新依赖，除 SES 模板）

| 层 | 内容 |
|---|---|
| 后端 | `auth::issue_email_change_code(conn, user_id, new_email)` —— 校验格式 + **查新邮箱是否已被占用** + 发码 |
| 后端 | `auth::confirm_email_change(conn, user_id, new_email, code)` —— 校验码（复用 `password_reset` 那套：attempts 封顶 / 过期 / 恒定时长比对）+ **事务内**改绑 + 二次查重 |
| 后端 | `POST /api/auth/change-email/request` · `POST /api/auth/change-email/confirm`（**均需 token**）|
| 发信 | `tencent_ses` 加一个按用途传主题/模板的入口（见 §〇 的依赖）|
| 前端 | 修改邮箱弹窗（**复用 `forgot_password_dialog` 的验证码版式**）+ 替换 `profile_screen.dart:699` 的 `_comingSoon` |

⚠️ **必须处理的边界**：
- 新邮箱**已被占用** ⇒ 明确报错（不能静默失败 —— 本项目大忌）
- 新邮箱 == 当前邮箱 ⇒ 明确提示（不做无意义操作）
- 改绑成功后的**会话处理**：沿用当前 token（与"重置密码"不同 —— 那个会踢掉所有旧会话）

### 2.2 Apple 登录

| 层 | 内容 |
|---|---|
| 后端 | `POST /api/auth/apple`：收 `identityToken` → 验签（取 Apple JWKS）→ 取 `sub`/`email` → 按 `apple_user_id` 查号，无则建号 → 发 token |
| 后端 | `users` 加 `apple_user_id`（⚠️ 按项目规矩：**ALTER 加列进 `main.rs`**，`schema.rs` 只放新表）|
| 依赖 | 后端需加 JWT 验签库（`jsonwebtoken`）+ JWKS 获取 |
| 前端 | `sign_in_with_apple` 依赖 + 登录弹窗加 Apple 按钮（**原型第 ⑤ 屏有版式**）|
| iOS | 新增 `Runner.entitlements`（`com.apple.developer.applesignin`）+ pbxproj 引用 |

⚠️ **架构决策（需白哥确认）**：Apple 账号**没有邮箱**（用户可选隐藏）⇒
`users.email` 可能为空，而 `isRegistered` 的判据是「邮箱非空」
（见 `AuthState.isRegistered`）。
⇒ 若 Apple 用户也勾了隐藏邮箱：该账号**永远 `isRegistered == false`** ⇒
会**反复弹注册引导**。
📌 需要定：Apple 登录后算不算"已注册"？（建议：**算**，判据改为「有 email **或** 有 apple_user_id」）

---

## 三、建议的顺序

1. **先做修改邮箱**（不依赖新库；只需 SES 模板）—— 一轮可交付
2. **再做 Apple 登录** —— 但**白哥先配 Apple 后台**（有前置周期，可并行）

⚠️ **但注意**：这两项**都不阻塞上架**。当前真正的上线路径仍是
「出包 → 真机验证 → 提审」，建议**并行**：
白哥配后台 / 出包验证，我这边写代码。

---

## 四、白哥需要做的（2026-10-07 更新）

### ① Apple Developer 后台 ✅ 已完成

白哥已走完：App ID 勾选 **Sign in with Apple** + 生成 Key 并下载 `.p8`。

🔴 **更正**：其中**只有「勾 capability」是登录必需的**；
「生成 Key / `.p8`」登录**用不到**（见 §〇 的更正表）——
它服务于「注销时撤销 Apple 授权」。

⚠️ 若**未**勾 capability：CI 自动签名创建不出含该能力的 profile ⇒ 构建 / 归档失败。

### ② 腾讯云 SES：改模板**正文** ⏳ 待办

**代码侧已完成**：主题 `CoEvo 验证码` + 函数改名 `send_verification_code`（两场景共用）。

✅ **模板正文也已改好**（2026-10-07）：
`docs/operations/email-templates/verification-code.html` + `.txt`
（原 `password-reset.*` ⇒ **已改名并中性化**，两个场景共用一条模板）。

⚠️ **剩下一步只能你做**：把这份新正文**粘回腾讯云 SES 控制台**并**重新提交审核**
（模板是「审核通过才能用」的 ⇒ **要等约 1 个工作日**）。

🔴 **变量是 `{{code}}`（双花括号）** —— 腾讯云的变量语法。
（⚠️ 我在上一版对话里写成了 `{code}`，**那是错的**；仓库里的模板文件一直是对的。
写成单括号 ⇒ 用户会收到**字面的 `{code}`** 而不是验证码。）
后端 `tencent_ses::build_body` 传的是 `TemplateData: {"code": "..."}` ⇒ 与 `{{code}}` 对应。

---

## 五、执行结果汇总

### ✅ 已做（提交 `c1fa1c4` · **未部署**）

| 层 | 内容 |
|---|---|
| **后端** | `apple_auth.rs`（新 · 739 行）· `auth.rs` +562 行（改邮箱两个函数）<br>`routes.rs` +3 端点 · `schema.rs` / `main.rs` / `user_purge.rs` · SES 中性化 |
| **前端** | `claim_dialog`（Apple 按钮 + 「或」分隔线）· `change_email_dialog`（新 · 两步）<br>`profile_screen` 接线（并删除已成死代码的 `_comingSoon`）<br>`auth_client` / `auth_provider` +3 方法 · `pubspec` + `sign_in_with_apple 8.1.0` |
| **iOS** | `Runner.entitlements`（新）+ `project.pbxproj` 三处 `CODE_SIGN_ENTITLEMENTS` |
| **断言** | `verify_auth_entry` 反转一条（`_comingSoon` 不该再存在）|

### 验证（全绿）

- 后端：`cargo fmt` ✅ · `clippy -D warnings` ✅ · `cargo test` **242 + 20 全过** ✅
- 前端：`analyze_inproc` **error=0 warning=0** ✅
- 12 个相关断言脚本全过（`forgot_password` 60 · `auth_entry` 71 · `sync` 61 ·
  `feed_wiring` 71 · `tokens` 696 · `iap_plan` 109 · `reading_settings` 60 ·
  `script_portability` 19 · `app_version` 6 · `worddb_sync` 6 ·
  `native_readiness` · `no_secrets`）

### ⏳ 未做

- **部署**（按铁律需白哥单独批准）
- **`authorizationCode → refresh_token`** —— 只为「注销时向 Apple 撤销授权」服务。
  ⚠️ 要做就**必须与登录同一轮**实现：`authorizationCode` **只在登录那一刻存在**，
  事后补不了（那时已登录的用户将无法撤销）。
- **`nonce` 校验** —— 当前 nonce 面较小（token 约 10 分钟有效 + HTTPS 传输）；
  若将来接入 Web 端（重放面变大）应补。

### ⚠️ 顺带发现（不在本任务内）

`schema.rs` 里还留着 `DISTRIBUTION_SCHEMA_SQL` / `ADMIN_SCHEMA_SQL`
两个**分销与 admin 时代的残留常量** —— 属另一个清理项，未动。
