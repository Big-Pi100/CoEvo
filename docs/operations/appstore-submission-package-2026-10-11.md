# App Store 上架材料包（2026-10-11）

> **用途**：白哥照此在 ASC 逐项填写即可。
> **口径**：文中每个「值」都**核实过来源**（代码 / 隐私政策 / 实测），
> 我起草的文案标了 `【草稿】`，**需要决策**的标了 `⚠️ 待定`。
>
> ## 现状（实测，非文档转述）
> | # | 硬阻塞 | 状态 |
> |---|---|---|
> | **A** | App 门面（图标 / 名称）| ✅ **已完成**（图标全套 + `CFBundleDisplayName = 记忆之书` 已进包）|
> | **B** | IAP 后端配置 | 🔴 **零配置** —— 实测 `.env` 共 10 个键，**无任何 `IAP_*`** |
> | **C** | 注销时撤销 Apple 授权 | 🟠 **未实现**（`grep revoke` 只命中验签注释）· 有时效性 |

---

## 一、ASC 元数据（大部分可直接复制）

| 字段 | 值 | 来源 |
|---|---|---|
| **App 名称** | `记忆之书` | 白哥 10-11 定案 |
| **副标题** | `阅读英语原文 · 自动规划记忆曲线` | 同上 |
| **Bundle ID** | `com.coevo.coevoApp` | `iap_plan.dart:19` |
| **主要语言** | 简体中文 | 中国区 |
| **隐私政策 URL** | `https://api.keyievolution.fun/privacy` | `iap_plan.dart:519` · **已上线** |
| **服务条款 URL** | `https://api.keyievolution.fun/terms` | `:522` · **已上线** |
| **支持 URL** | ⚠️ **待定** —— 可暂用隐私政策 URL，或建一个 `…/support` | — |
| **联系邮箱** | `support@keyievolution.fun` | 项目既有 |
| **版权** | ⚠️ **待定**（如 `© 2026 白哥`）| — |
| **主类别** | ⚠️ **待定** —— 建议「教育」，次类别「图书」| 待你定 |
| **年龄分级** | ⚠️ 按问卷如实答（无暴力/色情/赌博 ⇒ 通常 **4+**）| — |

### 1.1 描述【草稿 · 请过目】

```
记忆之书 — 读英文原文，把遇到的词与句变成长期记忆。

■ 读得下去
· 每日英文文章（订阅源），原文呈现，不做中文替换
· 长按查词，划词即记
· 内置朗读，可听原文
· 电子书导入：你自己的 EPUB / TXT 也能读

■ 记得住
· 划词、划线、生词自动进入记忆队列
· 基于 FSRS 的间隔重复，按你真实的记忆强度安排复习
· 复习与阅读同一个动作：看提示 → 默写原文 → 即时判定
· 数据默认只存本机；登录后可跨设备同步

■ 看得懂
· 整段翻译（按需触发，不打断阅读）
· 译文与原文对照，读完接着读

■ 关于订阅
· 阅读、查词、复习、朗读 **免费**
· 「记忆之书 专业版」提供：跨设备云端同步 · 翻译不限次数
· 1 个月 ¥6 / 1 年 ¥58，自动续期，可在系统设置中随时取消

隐私：不接第三方统计 SDK、不含广告、不做用户画像。
隐私政策：https://api.keyievolution.fun/privacy
```

> ⚠️ **核对过的点**：①「阅读/查词/复习/朗读免费」= 实态（生词上限已取消）
> ②「订阅 = 云端同步 + 翻译不限次」= 实态（翻译是订阅权益，免费 10 次/月）
> ③ **没有**「免费无限翻译」这类夸大。

### 1.2 关键词【草稿】（上限 100 字符，当前约 50）

```
英语阅读,背单词,记忆曲线,生词本,英语学习,原文阅读,划词翻译,单词卡,间隔重复,英语听力,单词记忆,英文文章
```

### 1.3 推广文本【草稿】（上限 170 字符）

```
读英文原文，把遇到的词自动变成长期记忆。阅读、划词、复习、朗读全部免费；订阅解锁跨设备同步与不限次翻译。
```

---

## 二、订阅产品（B1）—— **Product ID 必须逐字一致**

| 项 | 值 |
|---|---|
| 订阅群组名称 | `记忆之书 专业版` |
| **产品 1 ID** | `com.coevo.coevoApp.pro.monthly` |
| 产品 1 时长 / 价格 | **1 个月** · **¥6** |
| **产品 2 ID** | `com.coevo.coevoApp.pro.yearly` |
| 产品 2 时长 / 价格 | **1 年** · **¥58** |
| 群组内等级 | 两条都 **等级 1**（同群组同等级 ⇒ 可升降级）|
| 显示名称 | `记忆之书 专业版` |
| 产品描述【草稿】 | `解锁跨设备云端同步与不限次整段翻译。` |

🔴 **ID 写错的后果是静默的**：端侧拉不到商品 ⇒ 订阅页只显示占位价，**不报错**。
依据：`iap_plan.dart:22` `kProductMonthly` / `:23` `kProductYearly`（已核实）。

⚠️ 两条都必须在 **「App 内购买项目」→ 订阅** 下建，并**挂到这个 App 上**。

---

## 三、In-App Purchase Key（B2）—— **最容易搞错的一步**

🔴 **ASC 里有「两把不同的 Key」，分属两个 tab**：

| Key | 用途 | 现状 |
|---|---|---|
| **App Store Connect API Key** | CI 出包 / 上传 ASC | ✅ **已配**（GitHub Secrets，出包在用）|
| **In-App Purchase Key** | **后端验单（就是我们缺的）** | 🔴 **没配** |

Apple 官方明确：**ASC API Key 不能用来查购买** ⇒ 必须**另外生成**一把。

**步骤**：ASC → *Users and Access* → *Integrations* → 切到 **In-App Purchase** 那个 tab → 生成 Key
**拿到**：`Key ID` + 下载 `.p8`（**只能下一次**）

**给我这 4 条**（我配到 `/opt/coevo/.env` 并重启）：
```
IAP_KEY_ID        = <Key ID>
IAP_ISSUER_ID     = <Issuer ID>（UUID 形式，同页顶部）
IAP_PRIVATE_KEY   = <.p8 文件全部内容，含 BEGIN/END 行>
IAP_ENVIRONMENT   = Sandbox        # 联调期；上线改 Production
```

⚠️ `.p8` 全文要**含首尾两行**（`-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`）——
代码里有一条 `pem_to_der` 会显式校验，缺了会报「格式错误」。

---

## 四、沙盒测试账号（B3）

ASC → *Users and Access* → **Sandbox** → *Testers* → 新建。
⚠️ 邮箱**不能**是已注册的真实 Apple ID（用一个从没用过的邮箱）。
⚠️ 真机上购买时会弹**沙盒登录**，输入这个账号即可（**不用**退出真实 Apple ID）。

---

## 五、App 隐私标签（逐项答案——已与隐私政策逐条对齐）

**代码事实（已核）**：`pubspec.yaml` 与全仓 grep **无任何**埋点/崩溃上报 SDK
（sentry / crashlytics / firebase_analytics / umeng / bugly / amplitude / mixpanel **全 0**）。
隐私政策 §2.5 也明写「不做行为埋点 · 不含广告 SDK」。

⇒ 在 ASC 的 *App Privacy* 里这样答：

| 类别 | 具体项 | 是否收集 | 关联到你 | 用途 |
|---|---|---|---|---|
| **Contact Info** | **Email Address** | ✅ | ✅ | App Functionality |
| **User Content** | **Other User Content**（划线 / 笔记 / 生词 / 阅读记录 / **导入的电子书文件**）| ✅ | ✅ | App Functionality |
| **Identifiers** | **User ID** | ✅ | ✅ | App Functionality |
| **Purchases** | **Purchase History** | ✅ | ✅ | App Functionality |
| **Usage Data** | **Product Interaction** | ✅ | ✅ | App Functionality |
| Usage Data → Advertising Data / Other Usage | — | ❌ | — | 无广告 SDK、无埋点 |
| Diagnostics | — | ❌ **不收集** | — | 无崩溃上报 SDK |
| Location / Contacts / Photos … | — | ❌ | — | 隐私政策 §2.5 |

> 🔑 **一处容易搞错**：Apple 官方说「App **无需声明仅由 Apple 收集**的信息，例如**用于 App 内购买的付款信息**」——
> 但我们**自己后端也存了**交易（`iap_handlers` 记账步：`iap_transactions` / `payment_orders`）
> ⇒ **不属于「仅由 Apple 收集」** ⇒ **必须申报 Purchase History**。

- **Data Used to Track You**：**无** ✅
- **Data Linked to You**（**5 项**）：Email Address · Other User Content · User ID · Purchase History · **Product Interaction**
- **Data Not Linked to You**：**无**

> 🆕 **2026-10-11 复核**：`User Content` 那一行原本写「划线 / 笔记 / 生词 / 阅读记录」，
> **漏了「用户导入的电子书文件本身会上传（云端书架）」** ⇒ 已补上。
> 依据：`privacy-policy.md` §2.1(二) 现在明写「电子书文件本身会备份到云端」；
> 后端 `user_purge.rs` 有 `blob_bytes_freed`（注销时释放云端文件字节数）。

### ✅ 两处边界项 —— 已定案（2026-10-12 白哥同意）

> 📌 **Apple 官方定义**（`developer.apple.com/app-store/app-privacy-details`，2026-10-12 复核）：
> · **Device ID** = 「the device's advertising identifier, or **other device-level ID**」→ 关键词是 **device-level**
> · **Product Interaction** = 「app launches, taps, clicks, scrolling information, … or **other information about how the user interacts with the app**」→ 定义**很宽**

| # | 项 | ✅ 结论 | 依据 |
|---|---|---|---|
| 1 | **Device ID**（Identifiers 下）| **不申报** | 我们的标识是 `dev_` + 32 位 hex 随机串，**存在 `SharedPreferences`**（`device_id.dart:22` 注释原文：「卸载重装 → 新 id」）⇒ **应用实例级、重装即变** ⇒ **不构成 device-level ID**（Apple 指的是 IDFA / IDFV 那类系统级、跨重装稳定的）。且不做追踪 |
| 2 | **Usage Data → Product Interaction** | **申报**<br>用途 **App Functionality** · **Linked = ✅** · Track = **否** | 标识 + 词（`spelling`）上报 → `generated_card_hit(spelling, device_id)` → `distinct_user_count`（决定给词库补哪些词）；**且「划词历史」本身随账号同步** ⇒ 属「**information about how the user interacts with the app**」 |

> ✅ **隐私政策无需改动、也无需重新部署** —— §2.1 / §2.3 已**如实**写了这个标识的
> 存在、性质与用途；本次只是选了其中一侧，**两种答法都不与政策冲突**。
>
> 📌 判据：**平台声明（ASC 标签）与法务文本是「同一事实的两处描述」** ——
> 两处都必须与实现一致；**不一致的任一侧都是失实**。

---

## 六、税务 / DSA / 销售范围

| # | 事项 | 要点 |
|---|---|---|
| 1 | **W-8BEN** 税务表 | 填了可省 **20%** 预扣税；逐行指南见 `w8ben-filling-guide-2026-10-05.md` |
| 2 | **DSA 交易商声明** | 必填（不填不能上架）|
| 3 | 🔴 **销售范围** | 改成「**特定国家或地区 → 只勾中国大陆**」|
| 4 | **SBP**（小企业计划 30%→15%）| ✅ 已申请（10-05）；生效 = 批准当财月结束 + 15 天 |

---

## 七、审核备注（App Review Information）

提审时填，建议如下【草稿】：

```
本 App 的核心功能（阅读、查词、复习、朗读）无需登录即可使用。

订阅（记忆之书 专业版）需要登录后才能购买，请使用以下演示账号：
  邮箱：<待你提供或我创建>
  密码：<同上>

订阅解锁：跨设备云端同步 + 不限次整段翻译。
订阅入口：底部「我的」→ 订阅卡片。
恢复购买：订阅页与「我的」页均有入口。

若需查看划词/翻译：打开任意文章 → 长按选中一段文字。
```

⚠️ **演示账号**：需要一个**已注册**的账号（且最好已订阅，方便审核员看订阅态）。
需要我做的话说一声——我可以给你在后端建一个，或你自行注册后告我。

---

## 八、截图（**只能真机/模拟器截**，我做不了）

需要的尺寸（Apple 现要求）：

| 尺寸 | 数量 | 备注 |
|---|---|---|
| **6.9"（1320×2868）** | 3–5 张 | iPhone 16 Pro Max，**必填** |
| 6.5" | 可选 | 若 6.9" 已提供，现代 ASC 可只交一组 |

建议展示的 5 屏（按产品价值排序）：
1. **阅读页**（英文原文，有划线痕迹）
2. **划词查词卡片**（长按后的词卡）
3. **复习卡**（划线的「默写」考核态，译文 + 骨架同屏 —— 这是产品最有特色的一屏）
4. **笔记列表**（划过的都在）
5. **订阅页**（要**含价格与自动续期说明** —— 审核会看这一屏）

⚠️ 订阅页截图要求：**≥640×920**，且必须是 **App 内的订阅页**（不是网页）。

---

## 九、执行顺序（谁做什么）

```
① 【你】ASC 建 App 记录 + 填元数据（§一）
② 【你】ASC 建 2 个订阅产品（§二）—— ⚠️ ID 逐字照抄
③ 【你】ASC 生成 In-App Purchase Key → 把 4 条给我（§三）
④ 【我】配 .env 4 项 + 重启 + 只读验证（503 应消失）   ← 不需要你
⑤ 【你】建沙盒账号（§四）
⑥ 【我】出 **app-store 方式**的包并上传 ASC（当前包是 ad-hoc，不能上架）
⑦ 【你】沙盒真机跑通：购买 → 权益生效 → 恢复购买
⑧ 【你】隐私标签（§五）· 税务/DSA/销售范围（§六）· 审核备注（§七）· 截图（§八）
⑨ 【你/我】C 项决策（§十）→ 然后提审
```

📌 **②③ 与 ④ 之间是并行不了的**（④ 依赖 ③ 的凭据），但 ①⑤⑧ 可以随时做。

---

## 十、🟠 C 项：注销时撤销 Apple 授权（**需要你决策**）

**现状**：未实现。`grep revoke` 只命中 `apple_auth.rs` 的**验签**注释。

**为什么是风险**：Apple 对 Sign in with Apple 的要求 —— 账号注销时须调 REST API 撤销该用户的 Apple token。我们已上线 Apple 登录 ⇒ 这条适用。

**🔴 时效性（关键）**：`authorizationCode → refresh_token` **只在「登录那一刻」由 Apple 返回**：

| 选择 | 后果 |
|---|---|
| **现在做** | 之后登录的用户都能被正确撤销；**今天之前**已登录过的用户仍然撤不了 |
| **先上线** | 所有已登录用户**永久无法撤销**（Apple 可能因此在审核中提问）|

**改动范围**：登录接口（存 refresh_token）+ 注销流程（调 revoke）—— **两处 + 要出包**。

📌 **我的建议：现在做**。理由是它**越晚做越没有意义**（时效性），而现在做只多一次出包
（反正 §九⑥ 还要出 **app-store 包**，可以一起带上）。

---

*2026-10-11 · 方法：读代码核实参数（`iap_plan.dart`）+ SSH 实测 `.env`/路由 + 全仓 grep 埋点；文案标【草稿】待过目*
