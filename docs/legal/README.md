# 法律文件 · 部署与待填说明

> 2026-10-03 ｜ 为 **Apple 上架**准备的两份必需文件。
> 🔴 **这是上架硬要求**（App Store Connect 必填 + **订阅页法定必填**）—— 见 `payment-iap-assessment` §障碍 3。

## 文件

| 文件 | 用途 | 对应 |
|---|---|---|
| `privacy-policy.md` | 隐私政策 | ASC「隐私政策 URL」+ 应用内「关于」页 + **订阅页** |
| `terms-of-service.md` | 用户协议 | 应用内「关于」页 + **订阅页**（Apple 对订阅额外要求）|

## 🔴 部署前必须替换的占位符（**共 10 处标记 · 5 类**）

> ⚠️ **2026-10-04 更正**：本节原写「共 4 处」—— **实测 grep 是 10 处标记**。
> 按原文只改 4 处，上线后政策里会留着「【待填：联系邮箱】」字样。
> 📌 教训：**「文档里的数字」也要 grep 才算数** —— 它只是当初的估算，不是实测。

用 `grep -n '【待填' docs/legal/*.md` 可一次列出全部。逐项：

| # | 占位符 | 出现位置 | 谁定 |
|---|---|---|---|
| 1 | **运营者姓名** | `privacy-policy.md:6` · `terms-of-service.md:5` | 白哥（须与 ASC 主体一致）|
| 2 | **联系邮箱** | `privacy-policy.md:7 / 153 / 183` · `terms-of-service.md:6 / 172` | 白哥 |
| 3 | **注销账号入口** | `privacy-policy.md:151` | 做完注销功能后回填 |
| 4 | **隐私政策链接** | `terms-of-service.md:176` | 部署后回填 |
| 5 | **历史版本链接** | `privacy-policy.md:188` | 可选（无历史版本可删掉该句）|

⚠️ **另外两处需你确认**（影响合规表述）：

| 项 | 当前写法 | 需确认 |
|---|---|---|
| **AI 服务商** | 写明「境内 AI 服务商（DeepSeek）」 | 若未来换服务商，**必须同步改这里** |
| **IP 记录** | 写明「仅用于试用防滥用，有限期保留」 | 与后端 `trial_ip_log` 的实现一致 ✅ |

## 🔴 部署前提：**目前没有可挂载的网页**（2026-10-04 实测）

SSH 直查生产机：

| 实况 | 值 |
|---|---|
| 现有站点 | `api.keyievolution.fun`（API 反代）· `pay.keyievolution.fun`（vibedollar，**不属本项目**）|
| 已签发证书 | 只有上述两个 |
| **Web 落地页** | ❌ **不存在**（`/var/www/coevo-landing/` 不存在）|

⚠️ 原因：产品已定「**仅 iOS 原生 App，不做 Web**」⇒ 没有网站来挂这两份文件。
⚠️ 🔴 **`docs/deploy/web-deploy-guide.md` 的架构图已过时** —— 它描述的
   `/var/www/coevo-landing/` + Flutter Web 是「Web 时代」的方案，与当前架构不符。

**两个方案**（详见 `docs/operations/owner-action-checklist-2026-10-04.md` §4.2）：

| | A ⭐ 挂 api 域下 | B 用根域建站 |
|---|---|---|
| URL | `https://api.keyievolution.fun/privacy` | `https://keyievolution.fun/privacy` |
| 成本 | ✅ 证书已有 · 改一处 nginx · 5 分钟 | 需签新证书 + 建站 |

> 🔑 Apple 审核只要求 URL **可访问、能点开**，不要求域名好看。

## 部署（建议）

> ⚠️ 下面这段是**原方案（假设有 Web 站点）**，实际需先解决上面的「无网页」问题。

放到你自己域名下，**用静态页**最省事：

```
https://keyievolution.fun/privacy   →  privacy-policy.md 渲染成 HTML
https://keyievolution.fun/terms     →  terms-of-service.md 渲染成 HTML
```

### 做法 A：我帮你转成 HTML（推荐）

两份 Markdown 我可以生成**配好主题的单页 HTML**（无外部依赖、手机可读），
你只需把两个文件放到 nginx 的静态目录。⇒ **告诉我一声即可**。

### 做法 B：你自己用现成工具

任何 Markdown → HTML 都行（如 GitHub Pages、Vercel、或本地 `pandoc`）。

## 部署后要做的三件事

1. **回填 URL**：
   - `app/lib/screens/about_screen.dart`（「关于」页 —— 现在写的是「即将上线」占位）
   - **订阅页**（待实现）—— Apple 要求订阅页必须能点开这两个链接
   - ASC 的「App 隐私」与「隐私政策 URL」字段
2. **在 ASC 填隐私详情**：Apple 要求逐项声明收集的数据类型（本政策 §二 可逐条对应）
3. 🔴 **810 号令**：在 ASC 填**身份证号**（规格里已记）

## 写作依据（**为什么这么写**）

本政策**只写实际做的事** —— 逐项都核对过代码与数据库：

| 政策里的说法 | 核实来源 |
|---|---|
| 「生词本/复习记录只存设备」| 端侧 `user.db` / `word.db` |
| 「IP 仅用于试用防滥用」| 后端 `trial_ip_log` 表（**确实记录 IP**）|
| 「无第三方埋点/广告」| 全 `app/lib` grep `analytics` / `umeng` / `firebase` **零命中** |
| 「AI 服务在境内」| `DEEPSEEK_API_KEY` + `api.deepseek.com`（境内）|
| 「支付由 Apple 处理」| 即将接入的 IAP（**当前微信支付将一并移除**）|
| 「收集邮箱/密码哈希」| `users` 表 `email` / `password_hash`（**已删实名/手机号 5 列**）|

> 📌 判据：**隐私政策不能写未实现的能力**（会构成虚假陈述），
> 也不能漏写已收集的项（如 IP）。⇒ 逐条对回代码/DB。

## 待补（本轮未做）

- ⬜ Markdown → HTML 转换（等白哥说一声）
- ⬜ 后端数据导出接口（政策里承诺了「注销账号」，**目前前后端都零实现** —— 属上架前待办）
- ⬜ 应用内「关于」页把占位文案换成真实链接
