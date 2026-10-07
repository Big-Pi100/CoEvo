# 实施计划：Apple 登录 · 修改邮箱（2026-10-07）

> **触发**：白哥定「都做吧」（此前评估结论：两项都**不阻塞上架**，属产品增强）。
> **本文档**：实现方案 + **外部依赖清单**（需要白哥在第三方后台操作的部分）。

---

## 〇、先说要紧的：两项**各有一个外部依赖**

| 功能 | 🔴 外部依赖（白哥做）| 不做的后果 |
|---|---|---|
| **Apple 登录** | Apple Developer 后台：① App ID 勾选 **Sign in with Apple** capability ② 生成 **Key**（`.p8`）| 代码写完也**跑不起来**：iOS 端 `ASAuthorizationAppleIDProvider` 会直接报错，CI 签名也会失败（profile 不含该 capability）|
| **修改邮箱** | 腾讯云 SES：确认/新建一个**中性**邮件模板 | 用户改邮箱时，收到的邮件**标题写着「密码重置验证码」** ⇒ 严重误导（用户会以为账号被盗）|

⚠️ **第二个是我这轮新查出来的**（原以为改邮箱无外部依赖）：
`auth.rs` / `tencent_ses.rs` 里主题是**硬编码**的：

```rust
const SUBJECT: &str = "CoEvo 密码重置验证码";
```

⇒ 复用同一模板/主题会让「改邮箱」与「重置密码」的邮件**无法区分**。
📌 判据：**发信类功能复用时，「收件人看到什么」也要一起复用或区分** ——
只复用发送通道、不复用文案，等于两种业务共用一个语义标签。

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

## 二、待实现

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

## 四、需要白哥操作的两件事

### ① Apple Developer 后台（为 Apple 登录）

1. https://developer.apple.com/account → **Certificates, Identifiers & Profiles**
2. **Identifiers** → 找到 `com.coevo.coevoApp` → 勾选 **Sign in with Apple** → Save
3. 建一个 **Key**（Keys → `+`）→ 勾 **Sign in with Apple** → 下载 `.p8`（**只有一次**）
4. 记下 **Key ID** 与 **Team ID**（Team ID 我们已有 → `APPLE_TEAM_ID`）

⚠️ 第 2 步不做的话：CI 自动签名**创建不出含该 capability 的 profile** ⇒ 构建/归档会失败。

### ② 腾讯云 SES（为修改邮箱）

现状：主题硬编码为「CoEvo 密码重置验证码」，且**模板正文**可能也写死了"重置密码"。

**两个选项**（建议 A）：
- **A（省事）**：把模板正文改成**中性文案**（如「你的验证码是 {code}，5 分钟内有效。
  如非本人操作请忽略本邮件。」）⇒ 两个场景共用，主题按用途传
- **B（更清晰）**：**新建一个模板**给"修改邮箱"专用 ⇒ 两套文案互不干扰

⇒ 请白哥在腾讯云控制台确认模板正文，并告知选 A 还是 B。

---

## 五、本文未做

- ❌ 未写业务代码（本轮只落了**已充分论证**的 DB 表 + 验证）
- ❌ 未改 Apple 后台 / 腾讯云（也不该由我改）
- ⚠️ **顺带发现（不在本任务内）**：`schema.rs` 里还留着
  `DISTRIBUTION_SCHEMA_SQL` / `ADMIN_SCHEMA_SQL` 两个**分销与 admin 时代的残留常量** ——
  属另一个清理项，未动。
