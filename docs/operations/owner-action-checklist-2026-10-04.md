# 上架前置 · 操作手册（**给白哥**）

> 2026-10-04 ｜ 按**时间顺序**排，每条都带「在哪做 / 填什么 / 怎么算做完」。
> 🔴 本文件只列**只有你能做**的事（我做不了 —— 需要你的账号、身份证、付款、Mac）。
> 📌 我这边在做的事见文末 §八。

---

## ✅ Apple Developer Program 会员 —— **已生效**（白哥 2026-10-05 确认）

| 项 | 状态 |
|---|---|
| Apple Developer Program 会员 | ✅ **已注册完成**（2026-10-05 白哥确认）|
| 判定标准（自查） | `developer.apple.com` → Account → **Membership** 显示 **Team ID**（10 位），不再显示 Enroll |

> 🔑 会员生效后，下面 §一~§三 就能一次做完（约 40 分钟）。
> ⏳ **但 §一 两件（SBP / 810 号令）建议排在最前**：前者越早生效越早拿 15%，
> 后者**不填会影响打款**（钱收了拿不到）。

---

## 一、立刻做（各约 10 分钟）

### 1.1 申请 Small Business Program ✅ **已完成（白哥 2026-10-05）**

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **商务**（Business）→ **Small Business Program** |
| 做什么 | 填「上一年度收入 < $1M」申报 |
| 收益 | 🔴 **佣金 30% → 15%**（同样收入**多得 21%**）|
| 状态 | ✅ **已申请** |

#### 🔑 官方三条要点（Apple 原文核实，2026-10-05）

**① 🔴 生效时间不是「申请当天」，也不是「批准当天」**

> 官方原文：proceeds are adjusted **fifteen (15) days after the end of the fiscal
> calendar month in which your enrollment is approved**.
> 例：2022-02-10 批准 ⇒ **2022-03-14 起**调整。

⇒ 批准后还要等「**该财月结束 + 15 天**」才真正生效（约 **1–1.5 个月**）。
✅ **对我们零损失**：现在**还没上架、没有销售** —— 这正说明「提前申请」是对的。
📌 若将来有人「上架后才想起来申请」，**已产生的收入不会追溯**（官方明确 nothing clawed back）。

**② ✅ 订阅「首年即享 85%」—— 这条是真收益**

> 官方原文：Enrolled developers receive **85% of an auto-renewing subscription price
> from the first billing cycle**, instead of waiting out a subscriber's first year.

标准费率下订阅首年是 **30%**（满一年后才降到 15%）⇒ SBP 让我们**从第一笔订阅就是 15%**。

**③ ⚠️ 两个容易「申请了但没生效」的卡点**（值得回头确认一眼）

| 卡点 | 说明 |
|---|---|
| **须先同意「付费 App 协议」（Schedule 2）** | 官方要求：enroll 前需 *Review and accept the latest Paid Apps agreement*。<br>⚠️ 没同意的话**申请会卡住**（而界面不一定醒目提示） |
| **须申报「关联开发者账号」** | 官方要求列出所有「你拥有/控制的、或控制你的」Apple Developer 账号。<br>📌 **需要确认**：你是否还有其他 Apple Developer 账号？（个人开发者通常没有，但若有过就该申报） |

**④ 资格延续**：官方口径是「**carry over year to year**（只要仍低于 $1M）」。

> ⚠️ **修正一处**：本节原写「每年需要重新确认资格」——
> 官方页面的表述是「**资格逐年延续**」；第三方解读也是 carry over。
> ⇒ 我原来那句**不够准确**，已改。但仍建议留意 Apple 的资格相关邮件通知
> （阈值是**跨所有关联账号的合计 proceeds**，不是单账号）。

### 1.2 810 号令合规填报 ✅ **已完成（白哥 2026-10-05）**

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **商务**（Business）→ **协议** → **合规** |
| 填什么 | 🔴 **身份证号 + 姓名**（须与 Apple 账号主体一致）|
| 不填的后果 | 🔴 **影响打款**（钱收了拿不到）|
| 状态 | ✅ **已填报** |

> 💡 **建议顺手确认一眼**：ASC 里该协议应显示为**已提交/已生效**状态
> （而不是「待处理」）。若有异常，Apple 通常会邮件通知。

### 1.3 填写 W-8BEN 税务表（**能省 20% 预扣税**）

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **商务** → **协议** → **报税表** → 「添加税务信息」 |
| 关联协议 | 付费 App |
| 📄 **完整逐行指南** | **`docs/operations/w8ben-filling-guide-2026-10-05.md`** |

**三个要点**（细节见指南）：
1. **第 5 行（美国税号）留空**；**第 6a 行填 18 位身份证号**
2. **第 10 行填 `Article 11` / `paragraph 2` / `10%`**，收入类型选 `Income from the sale of applications`
   （⚠️ 网上教程常把条款号写错位成 12 —— 依据是国家税务总局协定原文，**第十一条**才是特许权使用费）
3. 🔴 **提交后 Apple 不允许修改**（官方明确）⇒ 提交前逐字核对

> ⚠️ 还有一条时间敏感风险（协定被提出「暂停或中止」，目前仍有效）→ 见指南 §八。

### 1.4 DSA（欧盟《数字服务法》）交易商声明 —— **必填，且要与销售范围一致**

| 项 | 内容 |
|---|---|
| 在哪 | ASC → **商务** → **协议** → **合规** → Digital Services Act → 「完成合规性要求」 |
| 选哪个 | ✅ **「我不是 DSA 所定义的交易商，或者我没有在欧盟地区进行分发的计划」** |
| 为什么 | 🔴 我们的分发范围 = **中国大陆**（产品是中文界面 + 中英对照词卡，EU 无用户）⇒ 不在 EU 分发 |

**🔴 选第二项的同时，必须核实「销售范围」——否则声明与实际不一致**

Apple 官方明确：**无论是否在 EU 分发 App，都需要声明交易商身份**（所以这一项**不能不填**）。
而 Apple 的 DSA 提示里还写着：**默认会把 App 设成「所有地区分发（含 EU）」**
⇒ 若声明「不在 EU 分发」却让销售范围保持默认，**两者矛盾**。

| 步骤 | 怎么做 |
|---|---|
| 1 | ASC → **价格与销售范围** → **App 供应情况** → 「设置供应情况」 |
| 2 | 选 ✅ **「特定国家或地区」**（**不要**选「所有国家或地区」）|
| 3 | 只勾 ✅ **中国大陆** ← 最省事的做法：不逐个排查 EU 27 国 |
| 4 | ❌ **不要勾**底部「将来 App Store 开通更多国家或地区时自动上架」<br>（勾了 = 未来新增地区自动上架 ⇒ 声明会被动失效）|

> 💡 **为什么「只勾中国大陆」而不是「全选后去掉 EU」**：后者要逐个排查 27 个成员国，
> 且未来可能新增，容易漏；前者一次到位，语义也最清楚。
>
> ⚠️ 代价（如实说）：选「特定国家或地区」后**不会自动上架未来新增地区**。
> 对「只做中国区」的产品不是问题；若将来要上其他区，手动加即可。
>
> 📌 判据：**「声明」与「配置」必须一致** —— 声明「不在 EU 分发」是**配置层的承诺**，
> 必须在销售范围里真的兑现，否则是「声明失实」。
> （同族：「一处定义」「口径一致」—— 凡有两处描述同一事实，就必须对齐。）
>
> 🔑 好消息：DSA 声明**可以改**（Apple 支持随时改，且能按 App 单独设置）——
> 所以现在选 B 不是不可逆的决定。

---

## 二、ASC 建订阅产品

> 📄 **详细步骤 + 参数表** → `docs/review/payment-iap-assessment-2026-10-03.md` **§十一**
> （含：前置检查 / 群组 / 两产品参数 / 等级规则 / 提交时机）

**30 秒版**：

```
ASC(appstoreconnect.apple.com) →「我的 App」→ **点进「记忆之书」这个 App**
  └─ 左侧边栏「**订阅**」（在「功能 / Features」分组下）
       └─ ① 先「**创建订阅群组**」：参考名称 = 记忆之书 专业版
          └─ ② 群组内点「+」加两个产品：
               · com.coevo.coevoApp.pro.monthly  ¥9.9   1 个月  等级 1
               · com.coevo.coevoApp.pro.yearly   ¥78    1 年    等级 1
```

> 🔴 **不在 Apps 列表页建** —— 订阅是 **App 级资源**，必须**先进到那个 App 里**。
> 🔴 **看不到「订阅」入口** = 前置没满足：ASC → 商务 → 必须
> ① 付费 App 协议 **Active** ② 税务表已签 ③ 银行账户状态 **Clear**（三个缺一入口就不显示）。

| 🔴 三个「一次填对」的点 | 说明 |
|---|---|
| **Product ID 保存后不可改** | 就填上表那两个，**大小写敏感** |
| **只建一个群组** | 只有一档服务；多群组会让用户被重复扣费 |
| **月/年同为等级 1** | 权益相同 ⇒ 同级转换（**不会重复扣费**）|

⏳ **审核截图可以晚点补** —— 它必须是「App 内的订阅页」，而订阅页我正在做。

---

## 三、🔴 生成 API Key —— **要两把，不是一把**

> ⚠️ **2026-10-05 补正**：本文件初版把这两把 key 分写在 §三 与 §7.1.1 两处，
> **没说清它们是两把不同的 key、且两把都要** —— 极易只生成一把。
> Apple 官方明确：**App Store Connect API Key 不能用来验单**
> （原文：*cannot send push notifications **or check purchases***）⇒ 后端会 401。
> 📌 判据：**同一个页面上、名字相近的两种凭据，必须显式说明「各用在哪」** ——
> 否则「生成过 key 了」会让人以为事情做完了。

**两把都在** ASC → **Users and Access** → **Integrations**，但是**两个不同的 tab**：

| | ① **In-App Purchase**（tab）| ② **App Store Connect API**（tab）|
|---|---|---|
| **给谁用** | **后端验单**（`iap_handlers.rs`）| **CI 上传 IPA**（`ios-archive.yml`）|
| **我调什么** | App Store Server API（`api.storekit.itunes.apple.com`）| App Store Connect API（上传构建 / TestFlight）|
| **放到哪** | 服务器环境变量（4 个，见 §5.2）| GitHub Secrets（4 个，见 §7.1.1）|
| **角色要求** | 🔴 **Account Holder 或 Admin**（**App Manager 不够**）| Account Holder / Admin（**选 Team Key**）|
| **数量上限** | 10 个 | 50 个 |

**两者共用**：· **Issuer ID 是同一个**（Integrations 页面顶部，UUID 形式，**账号级**）
· 都产出 `.p8` 文件，**都只能下载一次**（Apple 不留副本）
**两者不同**：· **Key ID 各自独立**（各 10 位）
· 🔴 **不要混用**：curl 时 `.p8` 与 Key ID 必须**同属一把**

### 3.1 ① In-App Purchase Key（后端用）

| 项 | 内容 |
|---|---|
| 路径 | Users and Access → Integrations → **In-App Purchase** → Generate In-App Purchase Key |
| 产出 | `.p8`（文件名形如 `SubscriptionKey_XXXXXXXXXX.p8`，**别改名**）+ **Key ID** + **Issuer ID** |

**拿到后给我**（我配到服务器）：
- `IAP_KEY_ID` = Key ID
- `IAP_ISSUER_ID` = Issuer ID
- `IAP_PRIVATE_KEY` = **`.p8` 文件的全部内容**（含 `-----BEGIN PRIVATE KEY-----` 那几行）
- `IAP_ENVIRONMENT` = `Sandbox`（联调期）/ `Production`（上线）

### 3.2 ② App Store Connect API Key（CI 上传用）

| 项 | 内容 |
|---|---|
| 路径 | Users and Access → Integrations → **App Store Connect API** → **Team Keys** → Generate |
| 角色 | 选 **App Manager** 或 **Admin**（上传构建够用；Admin 权限过大，非必要）|
| 产出 | `.p8` + **Key ID** + **Issuer ID**（同上，账号级）|

**拿到后配到 GitHub**（4 个 Secrets，见 §7.1.1）：`ASC_KEY_ID` · `ASC_ISSUER_ID` · `ASC_KEY_P8` · `APPLE_TEAM_ID`

> ⚠️ `.p8` 是**密钥** —— 按项目隐私铁律，**不要贴到外部对话/群里**。
> 后端那把我会给命令让你直接写到服务器；GitHub 那把由你在网页上填入（值不会经过我）。
>
> 💡 **`APPLE_TEAM_ID` 是第三样东西**，别与 Issuer ID 混：
> Team ID 在 `developer.apple.com` → Account → **Membership**（10 位）；
> **ASC API 的 token 里不用 Team ID**，但 iOS 签名需要它。

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

#### 🔴 7.1.0 【2026-10-05 更新】**额度已耗尽 ⇒ 出包走「临时改公开」**

**实测事实**（白哥提供 billing 页）：`Actions minutes: 2,000 / 2,000 used`，
**27 天后才重置**（≈ 11-01）。官方机制：**无付款方式时额度用尽 ⇒ 用量被 blocked**
⇒ 所有 job 立即失败且**日志页空白**（只显示 `This job failed`）。

| 可选路径 | 评估 |
|---|---|
| ⏳ **等到 11-01** | ✅ 零成本，但要等 |
| ✅ **出包时临时改公开**（**白哥已定**） | 公开仓库的标准 runner（**含 macOS**）**免费无限**；凭据在 Secrets 里不受影响 |
| ❌ 借 Mac 跑 Xcode Cloud | 官方要「configure a workflow **in Xcode**」⇒ 首次配置需 Mac（借不到） |
| ❌ Codemagic | 纯按量付费（$0.095/分），无免费层 |
| ❌ 自托管 runner | iOS 必须 macOS，需 Mac 硬件 |

##### 🔴 改公开之前**必须先做**的事（顺序不能反）

1. **吊销历史里泄漏的 key** —— 见 📄 `docs/review/git-history-secret-audit-2026-10-05.md`
   （`backend/.env` 里那个 `DEEPSEEK_API_KEY`；**哈希比对确认它不是服务器在用的那个**，
   但 key 不会自动过期 ⇒ 仍需吊销）
2. **清 git 历史**（`filter-repo`）—— ⚠️ 会**重写全部 commit hash**
   ⇒ **5 个 tag（v0.1.0~v0.1.4）需重建** + 所有克隆需重新 clone
   ✅ 部署链路不受影响（CI 靠 **tag 名**触发，不靠 hash）
3. 改公开 → 跑 `iOS Archive & Upload` → 出包完成后**改回私有**

> 📌 **为什么必须先吊销再改公开**：清历史只防「未来公开时可见」，
> **防不了「过去 5 个月里已经看过的人」** ⇒ 只有轮换凭据能根治。

**⇒ 真正的卡点不是「有没有 Mac」，而是 Phase 0（账号链路）：**

| 需要 | 状态 |
|---|---|
| Apple Developer 账号审批 | ✅ **已生效**（2026-10-05 白哥确认）|
| **Team ID**（签名必需）| ✅ **现在可取** —— `developer.apple.com` → Account → **Membership**（10 位）|
| **App Store Connect API Key**（`.p8` + Key ID + Issuer ID）| ⏳ **现在可生成**（§3.2）→ 配进 GitHub Secrets |
| **In-App Purchase Key**（后端验单用 ⚠️ 另一把）| ⏳ **现在可生成**（§3.1）→ 配进服务器环境变量 |
| ~~`ios-build` 的 `continue-on-error`~~ | ✅ **已移除**（2026-10-04）—— 实测证明 `--no-codesign` **不需要 Team ID**，那条「必然失败」的旧断言是错的 |
| **iOS 能否编过** | ✅ **已实测通过**（`Build iOS` 绿 · 含 11 个原生插件）|
| 归档/签名/导出/上传四步 | ✅ **已实现**（2026-10-04）→ `.github/workflows/ios-archive.yml` |

> 🔑 **所以：iOS 出包不需要你额外决策** —— 等 ASC 账号下来、配好 API Key，
> 就能在 CI 上跑通「构建 → 归档 → 上传 ASC」。你唯一要做的仍是 §一~§三 那些账号动作。

#### 🆕 7.1.1 API Key 拿到后，在 GitHub 配 4 个 Secrets

> 🔴 **注意**：这里用的是 **App Store Connect API Key**（§3.2）——
> 与后端验单用的 **In-App Purchase Key**（§3.1）是**两把不同的 key**，别混。
> （Apple 官方：ASC API Key **不能**用来查购买。）

**位置**：GitHub 仓库 → `Settings` → `Secrets and variables` → `Actions` → `New repository secret`

| Secret 名 | 值从哪来 |
|---|---|
| `ASC_KEY_ID` | ASC → Users and Access → Integrations → **App Store Connect API** → Key ID |
| `ASC_ISSUER_ID` | 同页顶部的 **Issuer ID**（UUID 形式）|
| `ASC_KEY_P8` | 🔴 **`.p8` 文件的完整文本内容**（含 `BEGIN PRIVATE KEY` / `END PRIVATE KEY` 两行）。<br>⚠️ 最常见的错误是只贴了中间的主体 ⇒ workflow 会**显式报错**（已加格式校验）|
| `APPLE_TEAM_ID` | ASC → Membership → **Team ID**（10 位）|

**配完就能跑**：Actions → 左侧 `iOS Archive & Upload` → `Run workflow`
- 不勾「上传」⇒ 只产出 IPA 供下载（可先这样验一遍）
- 勾「上传」⇒ 直接推到 App Store Connect，之后在 **TestFlight** 里装到 iPhone

> 🔑 **这就是你「不用 Mac 也能真机测」的路** —— 见 §7.1.2。

#### 🆕 7.1.2 为什么要走这条路（你之前只能用安卓测）

| | 安卓（你现在的方式）| iOS（这条新路）|
|---|---|---|
| 构建机 | 你的 Windows ✅ | GitHub `macos-latest`（**不需要买 Mac**）|
| 装到手机 | `adb install` / 直接装 APK | **TestFlight** |
| 能测什么 | 信息流 / 划词 / 复习 / **账号注销** / 朗读 | 同上 **＋ 🔴 订阅（IAP）** |

⚠️ **一个必须知道的限制**：**安卓包测不了订阅** ——
它走 Google Play Billing，而我们只有 Apple 的 Product ID（`com.coevo.coevoApp.pro.*`），
Play Console 里也没有对应商品 ⇒ 点订阅**必然失败**。
**订阅只能在 iOS（TestFlight 或沙盒）上验。**


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
| 订阅页重做（法律要件 + 两处恢复购买入口）| ✅ **已完成**（2026-10-04/05：文案已改 · 按原型重排 · 权益改「跨设备同步」）|
| **账号注销功能** | ✅ **已完成**（§7.2）|
| **电子书导入** | ✅ **已完成**（解析 + 落库 + UI `book_library_screen` · 入口为平级标题「书库」）|
| 云端同步（订阅的新权益）| 🟠 **设计已完备 · 卡在 3 个待拍板项** → `docs/design/sync-implementation-assessment-2026-10-04.md` §六 |
| iOS archive → TestFlight workflow | ✅ 已建（`.github/workflows/ios-archive.yml`，缺 Secrets）|
| 法律文本 → HTML + 部署 | ✅ 已完成（`api.keyievolution.fun/privacy` · `/terms`）|
| IAP / 注销 / 法定要件的验收断言 | ✅ 已接 CI（CI 覆盖 ≈2200 项）|

> ✅ **订阅页的三个问题都已处理**（2026-10-05）：① 作废的「200 词上限」文案已删
> ② 已按原型重排 ③ 权益改为「生词与复习进度跨设备同步」。
> ⇒ **可以截审核截图了**（≥640×920，须是 App 内的订阅页）。
>
> ⚠️ **唯一遗留**：权益所承诺的**云端同步尚未实现** ⇒ 上线前需完成，否则是空头承诺。
>
> 🔑 **2026-10-05 更正现状**（此前写「待设计实现」，**不准确**）：
> 同步的**设计早已完备** → `docs/design/sync-implementation-assessment-2026-10-04.md`（493 行）。
> 关键事实：
> · 🔑 **三块基础设施早已就位**（端侧 schema 早按同步设计 · 核心算法已实现 · `device_id` 已就位）
> · 只差两块：**后端 `push`/`pull` 接口** + **端侧同步调度**
> · ✅ 白哥已定范围（5 项：生词 / 复习进度 / 收藏 / 阅读进度 / 电子书进度）
> · 🔴 **卡在 3 个待拍板项**（该文档 §六 #1/#2/#6）：
>   ① 改隐私政策以允许同步（§2.1 现写「不上传服务器」—— 与同步**直接冲突**）
>   ② **多端登录** vs L0 的「单端登录踢旧」（**L0 条款，须白哥裁决**）
>   ③ 同步是否要求**有效订阅**（建议后端校验）
>
> 🔑 我这边**已无「阻塞你」的待做**；剩下的都卡在 ASC（§一~§三）与你的真机验证。

---

## 📋 勾选清单（打印/复制用）

```
━━ 会员已生效（2026-10-05）⇒ 下面按顺序做 ━━

【第 1 步 · 两件 10 分钟的事，建议最先做】
✅ 1.1 申请 Small Business Program —— **已完成（2026-10-05）**
      ℹ️ 官方：生效 =「**批准所在财月结束 + 15 天**」，约 1–1.5 个月
      ⚠️ 两个易卡点（建议回头确认）：① 是否已先同意「付费 App 协议」
         ② 是否有「关联开发者账号」需申报
✅ 1.2 810 号令填报 —— **已完成（2026-10-05）**
      ℹ️ 顺手确认 ASC 里该协议显示为「已提交/已生效」而非「待处理」
□ 1.3 填 W-8BEN 税务表（省 20% 预扣税）→ 逐行指南 `w8ben-filling-guide-2026-10-05.md`
      ⚠️ 第10行是 Article 11 / paragraph 2 / 10% · 🔴 提交后**不能改**
□ 1.4 DSA 交易商声明（**必填**）→ 选第二项「不是交易商 / 无 EU 分发计划」
      🔴 **同时**把「价格与销售范围」改成「特定国家或地区 → 只勾中国大陆」
      （默认是「所有地区含 EU」⇒ 不改就与声明矛盾）

【第 2 步 · 前置检查（不做完，产品建了也不生效）】见 §11.1
□ 2.1 付费 App 协议处于「生效」状态（ASC → 商务 → 协议）
□ 2.2 税务 + 银行信息完整
□ 2.3 App 已用 Bundle ID `com.coevo.coevoApp` 创建（ASC → 我的 App）
□ 2.4 810 号令（同 1.2，此处复核状态）

【第 3 步 · 建订阅产品】§二
□ 3.1 建群组 `记忆之书 专业版`（只建一个）
□ 3.2 建 2 个产品：monthly ¥9.9 / yearly ¥78 · 均等级 1
      ⚠️ Product ID 保存后不可改 · 简体中文本地化为必填
□ 3.3 审核截图 —— ✅ 订阅页已重做完，可以截了（≥640×920，须是 App 内订阅页）

【第 4 步 · 生成 Key（🔴 两把！见 §三）】
□ 4.1 In-App Purchase Key（Integrations → In-App Purchase）→ 给我（配服务器）
□ 4.2 App Store Connect API Key（Integrations → App Store Connect API → Team Keys）
      → 配 GitHub Secrets：ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 / APPLE_TEAM_ID
□ 4.3 Team ID（developer.apple.com → Membership，10 位）→ 同上第 4 个 Secret

【第 5 步 · 建沙盒测试账号】§六
□ 5.1 ASC → Users and Access → Sandbox Testers
      🔴 与真实 Apple ID 分开，别用主账号

【第 6 步 · 真机验证（可在拿到 TestFlight 后做）】
□ 6.1 用 TestFlight 装 iOS 包
□ 6.2 真机验注销流程（点注销 → 确认 → 回首页 → 再登录提示不存在；生词本仍在）
□ 6.3 沙盒验订阅（⚠️ 安卓包装不了订阅 —— 只能 iOS）

✅ 已完成（留档，不必再做）
✅ 运营者姓名 + 联系邮箱            → 白旭 / support@keyievolution.fun
✅ 隐私政策页部署 + 公网验证        → api.keyievolution.fun/privacy · /terms
✅ Cloudflare Email Routing（support@）
✅ iOS 出包：无 Mac 链路已规划（GHA macos-latest）→ **不需你决策**
✅ 账号注销（Apple 5.1.1(v)）→ 前后端 + 法律文本 + 断言
✅ archive→TestFlight workflow → 已建（缺 Secrets，暂时跑不了 = 预期）

━━ 🔴 【2026-10-05 新增 · 出包前置（顺序不能反）】━━
□ 7.1.0-A 吊销「git 历史里泄漏的 DEEPSEEK key」（DeepSeek 控制台 → API Keys）
      ⚠️ 别吊销服务器在用的那个（哈希 e63bb04…，见 §7.1.0）
□ 7.1.0-B 我清 git 历史（filter-repo）→ 重建 5 个 tag（v0.1.0~v0.1.4）
      ⚠️ 会重写全部 commit hash ⇒ 你的本地克隆需重新 clone
□ 7.1.0-C 出包时：仓库临时改 Public → 跑 `iOS Archive & Upload` → 出包完成后改回 Private
      ℹ️ 为什么：Actions 额度已耗尽（2,000/2,000，≈11-01 重置）；
         公开仓库的标准 runner（含 macOS）**免费无限**
```

> ⚠️ **订阅页待重做**（2026-10-04 白哥指出）：① 文案错（免费版已无 200 词上限）
> ② 排版要重新设计 ③ 订阅权益已改为**「云端同步」**（原三项都不成立）。
> ④ 且「云端同步」本身要实现 —— 否则订阅页仍是「承诺未实现」。
> 📄 依据：`docs/review/online-ebook-subscription-compliance-2026-10-04.md`
