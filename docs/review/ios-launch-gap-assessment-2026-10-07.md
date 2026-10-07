# 上架缺口评估：Apple 登录 · 修改邮箱（2026-10-07）

> **触发**：白哥在真机验证后指出「Apple 登录和修改邮箱都没有做」。
> **本文回答两个问题**：① 是否**阻塞上架**？ ② 若要做，各自要什么？

---

## 一、现状（已实测确认，非推测）

| 项 | 前端 | 后端 | 设计文档 |
|---|---|---|---|
| **Apple 登录** | 🔴 **无**（全库无 `sign_in_with_apple` 依赖，`grep` 0 命中）| 🔴 **无**（`routes.rs` / `schema.rs` 无 `apple` 相关）| ✅ **有**：`profile-redesign-2026-09-29.html` 第 ⑤ 屏画过；`profile-redesign-plan-2026-09-29.md:837` 明确「Apple 登录 / 邮箱绑定**后端与 SDK 全未做**」|
| **修改邮箱** | 🔴 只有入口：`profile_screen.dart:699` = `_comingSoon('修改邮箱')` | 🔴 **无端点**（`email-registration-2026-09-29.md:211` 亲笔记着「后端无端点」）| ✅ **有**：`profile-redesign-plan §6.4` 列了落地依赖清单 |

⇒ **两项都不是「漏做」，而是「明确排期未到」** ——
`claim_dialog.dart` 顶部注释写着：原型第 ⑤ 屏「**依赖尚未就绪的后端**，原型里自己标着『**本批不做**』」。

---

## 二、🔑 Apple 登录：**不阻塞上架**

### 2.1 规则原文（App Store Review Guidelines **4.8 登录服务**）

> 「App 若使用**第三方或社群登入服务**（例如 Facebook 登入、Google 登入、使用 X 登入、
> 使用 LinkedIn 登入、使用 Amazon 登入，或**微信登入**）来设定或验证 app 的主要使用者帐号，
> **也须提供**备有下列功能的其他登入服务……」
>
> **在下列情况下，不一定要提供其他帐号服务：**
> · **你的 app 只會使用公司擁有的帳號設定和登入系統。**

⇒ **CoEvo 只有「邮箱 + 密码」这一套自家登录**（已核实：全库无任何第三方登录 SDK，
微信相关的全是**共读群二维码**（运营），不是登录入口）⇒ **不触发 4.8** ✅

### 2.2 第三方评测的一致表述

> 「**Sign in with Apple — only if you have other social logins**」
> 「**Email-and-password-only apps don't trigger this rule.**」
> 「The cheapest path for many small apps: **stay email-only on launch and skip
> Sign in with Apple entirely** until you add social login.」

⇒ **结论：上架不阻塞。可以不做。**

### 2.3 ⚠️ 但有一个「将来会踩」的陷阱

**一旦将来加任何一种第三方登录**（微信登录、Google 登录…），**就必须同时提供 Apple 登录**，
且**视觉上不能埋在子菜单里**。⇒ 那时 Apple 登录从「可选」变成「必需」。

📌 所以决策不是「做不做」，而是「**什么时候做**」：
- **现在不做**：上架不受影响
- **将来加第三方登录时**：必须先做 Apple 登录（或同时做）

### 2.4 若要做，涉及什么

| 层 | 内容 | 需要白哥 |
|---|---|---|
| Apple 后台 | 开通 **Sign in with Apple** capability + 配 **Service ID / Key** | 🔴 **需要**（后台操作）|
| 前端 | `sign_in_with_apple` 依赖 + 按钮（原型第 ⑤ 屏已有版式）| — |
| 后端 | `/api/auth/apple` 端点：验 Apple identityToken → 建号/登录 → 发 token | — |
| 数据 | `users` 表加 `apple_user_id`（**ALTER 加列**，按项目规矩只进 `main.rs` 那份）| — |

⚠️ **它的产品价值**：Apple 登录比"填邮箱+密码"**快得多** ⇒ 对**注册转化率**有实际帮助。
⇒ 这不只是"合规项"，也是**增长项**。

---

## 三、修改邮箱：**非必需**（nice to have）

### 3.1 规则层面的实际要求

审核前清单（第三方整理，与 5.1.1(v) 一致）：

> 「If your app has account creation, you **must** ship all of these:
> · **Account deletion** in-app ✅ 已做（注销）
> · **Forgot password / reset password flow** ✅ 已做
> · **Change password** in settings ✅ 已做
> · **Change email is nice to have but not required**」← ⚠️ **明确：非必需**

⇒ **结论：不阻塞上架。**

### 3.2 若要做，涉及什么

**好消息**：可以**大量复用**已有的「找回密码」链路 ——
两者本质相同（**验证邮箱归属 → 允许修改**）：

| 步骤 | 可复用 |
|---|---|
| 发验证码到**新**邮箱 | `auth_forgot_password` 的签发 + 腾讯云 SES 发信 |
| 校验验证码 | `auth::issue_reset_code` / `reset_password` 的校验逻辑 |
| 换绑 | 新增：`UPDATE users SET email = ? WHERE id = ?`（需处理**唯一性冲突**）|

⚠️ **一个必须处理的边界**：换到**已被占用**的邮箱要**明确报错**，
不能静默失败（本项目大忌「静默失败 + 无出口」）。

---

## 四、建议

| 项 | 建议 | 理由 |
|---|---|---|
| **Apple 登录** | **上架前不做**，但**列为下一个功能批次的头号候选** | 不阻塞审核；但它是**转化率**功能（比邮箱注册快），且将来加任何第三方登录都绕不开它 |
| **修改邮箱** | **上架前不做**，可延后 | 明确「非必需」；且体验上属于低频操作 |

⇒ **两者都不影响本次上架**。当前真正阻塞上架的仍是：
两把 Key（`VPS_HOST` ✅ / IAP Key）· 沙盒验证 · SBP 申请 · iOS 出包（进行中）。

⚠️ **但请白哥确认一件事**：
**上架版本是否需要「Apple 登录」这个卖点？**
（比如面向的用户群是否更认 Apple ID 登录）——
若答案是「是」，它就该提到**本次上架前**；若「不是」，按上面的建议延后。

---

## 五、本文未做

- ❌ 未写任何代码（这是**功能开发**，不是 bug 修复 ⇒ 按铁律先评估请示）
- ❌ 未改 Apple 后台（也不该由我改）
