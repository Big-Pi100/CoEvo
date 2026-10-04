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

`docs/legal/README.md` 原写「共 4 处」—— **实测 grep 是 10 处标记**（见下表）。
按原文只改 4 处，上线后政策里会留着「【待填：联系邮箱】」这种字样。

| # | 占位符内容 | 出现位置 | 谁定 |
|---|---|---|---|
| 1 | **运营者姓名** | `privacy-policy.md:6` · `terms-of-service.md:5` | 你（须与 ASC 主体一致）|
| 2 | **联系邮箱** | `privacy-policy.md:7 / 153 / 183` · `terms-of-service.md:6 / 172` | 你（建议专门邮箱，别用主邮箱）|
| 3 | **注销账号入口** | `privacy-policy.md:151` | 我（做账号注销功能后回填）|
| 4 | **隐私政策链接** | `terms-of-service.md:176` | 部署后回填 |
| 5 | **历史版本链接** | `privacy-policy.md:188` | 可选（没历史版本可删掉这句）|

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

**两个方案（需你选）**：

| | 方案 A ⭐ 挂在 api 域下 | 方案 B 用根域建站 |
|---|---|---|
| URL | `https://api.keyievolution.fun/privacy` | `https://keyievolution.fun/privacy` |
| 做法 | 在现有 `zz-coevo` 加两条静态 location | 给根域签证书 + 新建站点 |
| 优势 | ✅ **证书已有** · 改一处配置 · 5 分钟 · 不动邻居站点 | URL 更「像官网」· 观感专业 |
| 代价 | URL 带 `api.` 前缀，观感一般 | 需签新证书 + 改 nginx（多一步）|

> 🔑 Apple 审核**不要求**域名好看，只要求**可访问、能点开**。
> 📌 我的建议：**先 A 满足上架**，上线后再升级 B（两件事不冲突）。

### 4.3 🆕 联系邮箱：建议用 `support@keyievolution.fun`（而非 QQ 邮箱）

> 白哥 2026-10-04 问：「像 vibedollar 那样建一个 CoEvo 域名的 support 邮箱、转发到 QQ 如何？」

**先澄清一个前提**（实测，SSH 直查）—— **vibedollar 没有域名邮箱**：

| 项 | 实测值 |
|---|---|
| mailproxy 的作用 | **发信代理**（`smtp.qq.com` → 国内 VPS → 发出，避开海外 IP 被拒）|
| `MAIL_FROM` | `mr.bigpi100@qq.com` —— **发件人就是 QQ 邮箱本身** |
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

### 7.1 iOS 出包需要 macOS（**当前最大风险**）

| 事实 | 来源 |
|---|---|
| iOS 构建需要 **Xcode / macOS** | `docs/review/step3-reader-plan-2026-09-27.md:738` |
| Windows **构建不了** iOS | `docs/review/a2-device-verification-checklist-2026-10-02.md:151` |

**⇒ 你的开发机是 Windows ⇒ 现在无法产出 iOS 包。**

三条路（**需要你确认走哪条**）：

| | 方案 | 说明 |
|---|---|---|
| **A** | 你**有** Mac → 直接用 | 最省事 |
| **B** | 租**云 Mac**（MacinCloud / MacStadium）| 按月付费，可远程构建 |
| **C** | 借/买一台 Mac | 一次性投入 |

⚠️ 这是**上架链路的必经环节** —— 无论代码多完整，没有 macOS 就产不出 `.ipa`。
我要在清单里明确写出来，避免做到最后才发现。

### 7.2 账号注销功能 —— 前后端**零实现**

| 事实 | 说明 |
|---|---|
| 隐私政策**承诺**了「可申请注销账号」 | `privacy-policy.md:151` |
| 实际实现 | 🔴 **零** —— 没有注销接口，App 里也没有入口 |
| Apple 要求 | 🔴 **5.1.1(v)**：有账号体系的 App **必须**能在 App 内注销 |

**⇒ 这会卡审核**（政策承诺了但做不到，属虚假陈述 + 违反 5.1.1(v)）。

**我的建议**：排进**本批**（和订阅页一起做）—— 工作量不大（一个接口 + 一个入口 + 二次确认）。

---

## 八、我这边在做 / 待做（**你不用管**）

| 项 | 状态 |
|---|---|
| 后端 `iap_transactions` 表 + `/api/iap/verify` | ✅ **已完成**（209 测试全绿）|
| 前端接 `in_app_purchase` | ⏳ 进行中 |
| 订阅页重做（法律要件 + 两处恢复购买入口）| ⏳ 进行中 |
| 账号注销功能 | ⏳ 待你确认是否本批做（§7.2）|
| 法律文本 → HTML + 部署命令 | ⏳ 待你给 §4.3 的两个值 |
| 隐私政策页部署 | ⏳ 待你选 §4.2 的方案 |

---

## 📋 勾选清单（打印/复制用）

```
□ 等 Apple 审批通过（Membership 出现 Team ID）
□ 申请 Small Business Program
□ 810 号令填报（身份证号 + 姓名）
□ ASC 建群组 CoEvo Pro
□ ASC 建 2 个产品（monthly ¥9.9 / yearly ¥78 · 均等级 1）
□ ASC 生成 IAP Key（.p8 + Key ID + Issuer ID）
□ 告知：运营者姓名 + 联系邮箱          → 我填法律文本
□ 选定：隐私政策页方案（A api 域 / B 根域）→ 我做部署
□ 确认：iOS 出包走哪条路（A 有 Mac / B 云 Mac / C 买 Mac）
□ 确认：账号注销是否本批做
□ 建沙盒测试账号
□ 审批通过后补审核截图（等订阅页做完）
```
