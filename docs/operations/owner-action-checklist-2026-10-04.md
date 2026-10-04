# 上架前置 · 操作手册（**给白哥**）

> 2026-10-04 ｜ 按**时间顺序**排，每条都带「在哪做 / 填什么 / 怎么算做完」。
> 🔴 本文件只列**只有你能做**的事（我做不了 —— 需要你的账号、身份证、付款、Mac）。
> 📌 我这边在做的事见文末 §八。

---

## ⏳ 进行中：等 Apple 审批（1–2 天）

| 项 | 状态 |
|---|---|
| Apple Developer Program 会员 | ✅ **已付款** · ⏳ **等 Apple 审批**（≤48 小时）|
| 判定「审批通过」 | `developer.apple.com` → Account → Membership 显示 **Team ID**（不再是 Enroll）|

> 审批期间**不用等** —— 下面 §三 之后的步骤有些现在就能做。

---

## 一、审批通过后立刻做（各约 10 分钟）

### 1.1 申请 Small Business Program

| 项 | 内容 |
|---|---|
| 在哪 | [developer.apple.com/app-store/small-business-program](https://developer.apple.com/app-store/small-business-program/) |
| 做什么 | 填「过去 12 个月总收入 < $1M」申报 |
| 收益 | 🔴 **佣金 30% → 15%**（收入 +21%）· 订阅**首年即享 85%**（不用等满一年）|
| 记住 | 每年**需要重新确认**资格 |

### 1.2 810 号令合规填报

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **商务**（Business）→ **协议** → **合规** |
| 填什么 | 🔴 **身份证号 + 姓名**（须与 Apple 账号主体一致）|
| 不填的后果 | 🔴 **影响打款**（钱收了拿不到）|

---

## 二、ASC 建订阅产品

> 📄 **详细步骤 + 参数表** → `docs/review/payment-iap-assessment-2026-10-03.md` **§十一**
> （含：前置检查 / 群组 / 两产品参数 / 等级规则 / 提交时机）

**30 秒版**：

```
ASC → 我的 App → 选 CoEvo → 侧边栏「营利」→「订阅」
  └─ ① 新建群组：参考名称 = CoEvo Pro
     └─ ② 加两个产品：
          · com.coevo.coevoApp.pro.monthly  ¥9.9   1 个月  等级 1
          · com.coevo.coevoApp.pro.yearly   ¥78    1 年    等级 1
```

| 🔴 三个「一次填对」的点 | 说明 |
|---|---|
| **Product ID 保存后不可改** | 就填上表那两个，**大小写敏感** |
| **只建一个群组** | 只有一档服务；多群组会让用户被重复扣费 |
| **月/年同为等级 1** | 权益相同 ⇒ 同级转换（**不会重复扣费**）|

⏳ **审核截图可以晚点补** —— 它必须是「App 内的订阅页」，而订阅页我正在做。

---

## 三、生成 In-App Purchase Key（`.p8` + Key ID + Issuer ID）

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **Users and Access** → **Integrations** → **In-App Purchase** |
| 产出 | ① **`.p8` 文件**（只能下载**一次**！）② **Key ID** ③ **Issuer ID**（页面上方）|
| 🔴 注意 | 下载的 `.p8` **别丢**，Apple **不提供二次下载** |

**拿到后给我**（我会配到后端）：
- `IAP_KEY_ID` = Key ID
- `IAP_ISSUER_ID` = Issuer ID
- `IAP_PRIVATE_KEY` = **`.p8` 文件的全部内容**（含 `-----BEGIN PRIVATE KEY-----` 那几行）
- `IAP_ENVIRONMENT` = `Sandbox`（联调期）/ `Production`（上线）

> ⚠️ `.p8` 是**密钥** —— 按项目隐私铁律，**不要贴到外部对话/群里**，
> 直接放进服务器的环境变量配置即可（我给命令）。

---

## 四、🔴 隐私政策 / 用户协议（**上架硬要求**）

### 4.1 先看一个纠正：占位符是 **10 处**，不是 4 处

`docs/legal/README.md` 原写「共 4 处」—— **实测是 10 处标记**；
应用内注销上线后又减到 **8 处**（见下表）。
按原文只改 4 处，上线后政策里会留着「【待填：联系邮箱】」这种字样。
📌 **「文档里的数字」也要 grep 才算数**。

| # | 占位符内容 | 出现位置 | 谁定 |
|---|---|---|---|
| 1 | **运营者姓名** | `privacy-policy.md:6` · `terms-of-service.md:5` | ✅ 已给（白旭）|
| 2 | **联系邮箱** | `privacy-policy.md:7 / 153 / 183` · `terms-of-service.md:6 / 172` | ✅ 已给（`support@keyievolution.fun`）|
| 3 | ~~**注销账号入口**~~ | ~~`privacy-policy.md:151`~~ | ✅ **已改为「应用内直接注销」**（不再是占位符）|
| 4 | **隐私政策链接** | `terms-of-service.md:176` | ✅ 已由脚本注入 |
| 5 | **历史版本链接** | `privacy-policy.md:188` | ✅ 脚本整行删除（无历史版本）|

> 一次性列出：`grep -n '【待填' docs/legal/*.md`

### 4.2 🔴 新发现：隐私政策**需要一个可公开访问的网页**，而现在没有

实测生产环境（SSH 直查）：

| 实况 | 值 |
|---|---|
| 现有站点 | `api.keyievolution.fun`（API 反代）· `pay.keyievolution.fun`（vibedollar，**不属本项目**）|
| 已签发证书 | 只有上述两个 |
| **Web 落地页** | ❌ **不存在**（`/var/www/coevo-landing/` 不存在）|

⚠️ 原因：产品已定「**仅 iOS 原生 App，不做 Web**」⇒ 没有网站来挂这两个页面。
⚠️ `docs/deploy/web-deploy-guide.md` 里画的架构图（`/var/www/coevo-landing/`）**已过时**。

**两个方案 → ✅ 已采用方案 A 并完成部署（2026-10-04）**：

| | 方案 A ✅ **已采用** | 方案 B（未用） |
|---|---|---|
| URL | https://api.keyievolution.fun/privacy · /terms | https://keyievolution.fun/privacy |
| 做法 | 在现有 `zz-coevo` 加两条 `location =` | 给根域签证书 + 新建站点 |
| 状态 | 🟢 **已上线且公网验证通过** | 上线后可升级（两件事不冲突）|

> 🔑 Apple 审核**不要求**域名好看，只要求**可访问、能点开**。
> 📌 我的建议：**先 A 满足上架**，上线后再升级 B（两件事不冲突）。

#### ✅ 2026-10-04 14:23 —— **端到端验证通过**

白哥确认：**测试邮件已在 QQ 邮箱收到** ⇒ Cloudflare Email Routing 的
「DNS + 目标地址验证 + 路由规则」三件**全部生效**。

| 层 | 状态 |
|---|---|
| DNS（MX / SPF）| ✅ 实测 |
| 目标地址验证 | ✅ 收到邮件即证明 |
| 路由规则 | ✅ 同上 |

⇒ `support@keyievolution.fun` **可用**，将作为法律文本的「联系邮箱」。

> 📌 记录一条判据：**「配置好了」要落到「真跑一次」** ——
>    本次 DNS 早已就绪，但**只有真发一封**才能证明整条链路通。
>    （同族教训：`cargo test` 不重编 bin ⇒ 未执行路径必须真跑。）

#### 已收到的部署参数

| 参数 | 值 |
|---|---|
| `--operator` | ✅ 白哥已提供（**真实姓名**，作为部署参数注入，**不入 git**）|
| `--email` | ✅ `support@keyievolution.fun` |

> 🔑 为什么这两个值**不写进 md 文件**：它们是**部署参数** —
>    git 历史会永久保留，而法律文本的运营者信息会随主体变化。
>    脚本设计上就走命令行参数（见 `build_legal_pages.py` 的说明）。

### 4.3 🆕 联系邮箱：建议用 `support@keyievolution.fun`（而非 QQ 邮箱）

> 白哥 2026-10-04 问：「像 vibedollar 那样建一个 CoEvo 域名的 support 邮箱、转发到 QQ 如何？」

**先澄清一个前提**（实测，SSH 直查）—— **vibedollar 没有域名邮箱**：

| 项 | 实测值 |
|---|---|
| mailproxy 的作用 | **发信代理**（`smtp.qq.com` → 国内 VPS → 发出，避开海外 IP 被拒）|
| `MAIL_FROM` | 一个 **QQ 邮箱地址**（`<你的账号>@qq.com`）—— **发件人就是 QQ 邮箱本身** |
| 收信配置 | 🔴 **0 条**（无 IMAP / POP3 / 入站规则）|
| 它能否支持「support@ 发信」 | ❌ 不能 —— QQ SMTP **强制发件人 = 授权账号**，换个 From 会被拒 |

⇒ 所以「照 vibedollar 那样建」这条路**不存在**；但**你的需求本身完全合理**，而且有更简单的做法。

#### 现状（用 `dig` 实测；已用 `qq.com` 对照证明查询方式正确）

| 项 | 值 |
|---|---|
| `keyievolution.fun` 的 NS | `*.ns.cloudflare.com` ⇒ **DNS 已在 Cloudflare** ✅ |
| `keyievolution.fun` 的 MX | 🔴 **空 ⇒ 当前一个邮件都收不到** |

#### ⭐ 方案：Cloudflare Email Routing（免费）

| 项 | 说明 |
|---|---|
| 费用 | **永久免费**（Cloudflare 标准服务，非试用）|
| 前提 | 域名 DNS 在 Cloudflare ✅ **已满足** |
| 能做 | 收 `support@keyievolution.fun` → 转发到你的 QQ 邮箱 · 无限地址 · 支持 catch-all（任意前缀都收）|
| 🔴 **不能做** | **发信**（它不是邮箱服务，是**转发器**：不能登录、不发信、不存邮件）|
| 限制 | 单封 ≤ **25 MB**（含附件）；转发数量无限制 |

**你要点的 5 步**（约 5 分钟，需你的 Cloudflare 账号）：

```
1. Cloudflare Dashboard → 选 keyievolution.fun
2. 左侧 Email → Email Routing → Get Started
   → 点「Add records and enable」（**MX/SPF 自动加**，不用手填）
3. Destination addresses → 添加你的 QQ 邮箱 → 收验证邮件 → **点确认**
   🔴 不验证 = 转发完全不生效（最常被漏的一步）
4. Routing rules → Create address
   → Custom address 填 `support` → 目标选刚验证的 QQ 邮箱 → Save
5.（可选）开 Catch-all → 任意前缀都能收（如 contact@ / 拼错的地址）
```

#### ⚠️ 两条边界（先说清，避免以后返工）

| # | 边界 | 影响 |
|---|---|---|
| 1 | **不能发信** | 若将来要用 `support@` 主动发邮件（验证码、通知），需**另接 SMTP 服务**（Resend / SMTP2Go 免费额度）。⚠️ 且换 SMTP 后 **vibedollar 的 mailproxy 也用不上**（它的授权账号是 QQ 邮箱）|
| 2 | **在 QQ 里回复时，对方看到的发件人是 QQ 邮箱** | 要「以 support@ 名义回复」需要 SMTP 代发（同上）。**一期不必解决** —— 用户收到回复即可 |

> 📌 **建议**：一期用 CF Email Routing 拿到**专业地址 + 隐私保护**（公开的是 `support@` 而非个人 QQ 邮箱）；
> 发信能力等到真需要时再接。
> 🔑 **隐私政策的「联系邮箱」建议填 `support@keyievolution.fun`** —— 这是它的主要价值之一：
> **不把个人邮箱暴露给所有 App 用户**。

#### ⏳ 所以「联系邮箱」这个占位符有两条路

| 选项 | 填什么 | 何时可用 |
|---|---|---|
| **A** ⭐ | `support@keyievolution.fun` | 先在 Cloudflare 配好 Email Routing（上面 5 步）|
| **B** | 直接填 QQ 邮箱 | 立刻可用，但**个人邮箱会公开在政策里** |

> ⚠️ 无论选哪个，**都需要你先在 Cloudflare 建好**（选 A）或**告诉我要填哪个**（选 B）。

#### ⛔ 为什么不推荐「腾讯企业邮 / 网易企业邮」

CSDN 实测记录（2026）：**腾讯企业邮免费版强制绑定企业微信**、**网易免费版「全域通」是付费功能**。
且白哥是**个人主体**，企业邮通常需要企业资质 ⇒ **不合用**。

#### 🔑 为什么不自建邮件服务器

MX + Postfix 看似可行，但**要维护 IP 信誉、反垃圾、DKIM/DMARC、退信处理** ——
而且**国内新 IP 发信极易被判垃圾**。判据：**能用托管服务就别自建**（成本远低于收益）。
> ⚠️ 根域 `keyievolution.fun` / `www` **已解析**到本机 ✅（实测 nslookup），所以 B 也可行。

### 4.3 你只需给我两个值

1. **运营者姓名**（= Apple 开发者主体姓名）
2. **联系邮箱**

其余（注销入口、链接回填）我来补。

---

## 五、部署 + 配环境变量

> 🔑 **2026-10-04 更新**：部署已**固化成脚本**，不再需要我手写命令逐条给你。

### 5.1 法律文本页（一条命令）

```bash
bash scripts/legal/publish_legal_pages.sh \
    --operator "你的法定姓名" --email "对外联系邮箱"
```

| 它会做 | 说明 |
|---|---|
| ① 生成 HTML | pandoc + 本项目模板（朱砂主题 · 手机可读 · 深色模式）|
| ② 上传 | → `/var/www/coevo-legal/` |
| ③ 配 nginx | **幂等**（重复跑不会重复插入）· 只加不改 |
| ④ 校验 + reload | `nginx -t` 失败**自动回滚**（不连累同机其它站点）|
| ⑤ 公网验证 | HTTP 200 + 内容检查 + 🔴 **无残留占位符** |

**URL**（默认方案 A，证书已有）：
- `https://api.keyievolution.fun/privacy`
- `https://api.keyievolution.fun/terms`

**预览**（不部署、不连服务器）：`python scripts/legal/build_legal_pages.py --dry-run`
→ 产物在 `build/legal/`，浏览器直接打开就能看效果。

⚠️ 按项目铁律：**没你批准不进生产**（含静态文件）。

### 5.2 后端环境变量（IAP）

后端加 4 个环境变量（§三）→ 重启 `coevo.service` → 验证：
```
IAP_KEY_ID / IAP_ISSUER_ID / IAP_PRIVATE_KEY / IAP_ENVIRONMENT
```
> ⏳ 这步依赖你先在 ASC 生成 IAP Key（§三）。

---

## 六、沙盒测试准备

| # | 项 | 在哪 |
|---|---|---|
| 1 | 建**沙盒测试账号** | ASC → Users and Access → **Sandbox Testers** |
| 2 | 真机登录该账号 | iPhone → 设置 → App Store → **沙盒账户**（**不是在顶部 Apple 账户里**）|
| 3 | 联调 | 用 Xcode 装 Debug 包（**沙盒支付不扣真钱**）|

> 🔴 沙盒账号与真实 Apple ID **分开**（不要用你的主账号测）。

---

## 七、🔴 两个必须先解决的阻塞

### 7.1 iOS 出包：✅ **无 Mac 链路已规划，不需要你选方案**

> ⚠️ **2026-10-04 更正**：本文件初版把这条列为「需要你确认走哪条路（A 有 Mac / B 云 Mac / C 买 Mac）」
> —— **那是错的**。项目**早已规划好无 Mac 链路**，我把「本机构建不了」（真话）
> 外推成了「项目做不到」（错误推论），中间漏了「查项目是否已有替代路径」这一步。
> 📌 教训：**「本机做不到」≠「项目做不到」** —— 先查有没有已规划/替代路径。

| 事实 | 出处 |
|---|---|
| **无 Mac 的 iOS 开发闭环（今天就能搭）** | `qualification-startup-2026-09-25.md` **§一** |
| 🔴 **不需要 Codemagic** —— GHA 自带 `macos-latest`，且已有基础设施 | `plan-and-progress-2026-09-26.md:309` |
| ✅ **CI 已有 `ios-build` job**（`flutter build ios --release --no-codesign`）| `.github/workflows/ci.yml` |
| archive → 导出 IPA → 上传 ASC 的**完整参考实现** | `ios-appstore-ci-reference.md` |
| iOS 构建额度 | macOS runner 私有仓库按 **10x** 计费（2,000 分钟/月 → 实际 200）⇒ 已改为**手动/tag 触发** |

**⇒ 真正的卡点不是「有没有 Mac」，而是 Phase 0（账号链路）：**

| 需要 | 状态 |
|---|---|
| Apple Developer 账号审批 | ⏳ **进行中**（你在办）|
| **Team ID**（签名必需）| ⏳ 审批通过后可得 |
| **App Store Connect API Key**（`.p8` + Key ID + Issuer ID）| ⏳ 待生成 → 配进 GitHub Secrets |
| `ios-build` job 的 `continue-on-error` | 🔴 **Phase 0 完成后要删掉那一行**（CI 里已写明「何时移除」）|
| 归档/签名/导出/上传四步 | ⏳ 尚未实现（`ios-appstore-ci-reference.md` 有参考，待 Phase 0 后启用）|

> 🔑 **所以：iOS 出包不需要你额外决策** —— 等 ASC 账号下来、配好 API Key，
> 就能在 CI 上跑通「构建 → 归档 → 上传 ASC」。你唯一要做的仍是 §一~§三 那些账号动作。

### 7.2 ✅ 账号注销功能 —— **已完成**（2026-10-04）

| 事实 | 状态 |
|---|---|
| Apple 5.1.1(v)：有账号体系的 App **必须**能在 App 内注销 | ✅ **已满足** |
| 后端 `POST /api/user/me/delete` | ✅ **已实现**（硬删 + 事务 + 幂等 + 匿名化，11 个单测）|
| 「我的」页入口 + 二次确认 | ✅ **已实现** |
| 隐私政策 §六 | ✅ 已改为「应用内**直接注销**（无需联系客服）」并重新部署 |

🔴 **一个关键更正**：政策原文写的是「通过**邮箱提交申请**」——
这**本身就违反 5.1.1(v)**（Apple 明确：除高度监管行业，不得要求用户发邮件才能注销）。
⇒ 本次不只是「填个占位符」，而是**申请制 → 自助制**。

📄 设计/实施细节：`docs/design/account-deletion-2026-10-04.md`

⏳ **待你真机验一遍**（§ 见该文档 §11.6）：点注销 → 确认 → 回首页 → 再登录提示不存在；
🔑 重点确认**生词本仍在**（端侧学习数据不该被删）。

---

## 八、我这边在做 / 待做（**你不用管**）

| 项 | 状态 |
|---|---|
| 后端 `iap_transactions` 表 + `/api/iap/verify` | ✅ 已完成（**220** 测试全绿）|
| 前端接 `in_app_purchase` + 订阅服务层 | ✅ 已完成 |
| 订阅页重做（法律要件 + 两处恢复购买入口）| ✅ 已完成 |
| **账号注销功能** | ✅ **已完成**（§7.2）|
| 法律文本 → HTML + 部署 | ✅ 已完成（`api.keyievolution.fun/privacy` · `/terms`）|
| IAP / 注销 / 法定要件的验收断言 | ✅ 99 项（已接 CI）|

> 🔑 我这边**已无待做**；剩下的都卡在 ASC（§一~§三）与你的真机验证。

---

## 📋 勾选清单（打印/复制用）

```
□ 等 Apple 审批通过（Membership 出现 Team ID）
□ 申请 Small Business Program
□ 810 号令填报（身份证号 + 姓名）
□ ASC 建群组 CoEvo Pro
□ ASC 建 2 个产品（monthly ¥9.9 / yearly ¥78 · 均等级 1）
□ ASC 生成 IAP Key（.p8 + Key ID + Issuer ID）
✅ 告知：运营者姓名 + 联系邮箱            → 已完成（白旭 / support@）
✅ 隐私政策页：方案 A 选定 + 已部署 + 公网验证  → 已完成
✅ Cloudflare Email Routing（support@）    → 已完成（端到端验证通过）
✅ iOS 出包：无 Mac 链路已规划（GHA macos-latest）→ **不需你决策**
□ 等 ASC 审批后拿 Team ID + 生成 ASC API Key → 配进 GitHub Secrets
✅ 账号注销（Apple 5.1.1(v)）→ 已完成（前后端 + 法律文本 + 断言）
□ **真机验注销流程**（点注销 → 确认 → 回首页 → 再登录提示不存在；生词本仍在）
□ 建沙盒测试账号
□ 审批通过后补审核截图（订阅页已完成，可截）
```
