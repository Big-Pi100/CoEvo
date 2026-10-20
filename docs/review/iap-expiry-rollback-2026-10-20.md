# 【调查报告 · 未修】订阅显示「明天到期」却同步失败 —— 服务端到期日被**旧交易回退**

*2026-10-20 23:00 · 依赖：SSH 直查生产库 + 服务端日志 + nginx access.log + SQLite 实测*
*⭐ 未修改任何代码。等白哥审批。*

---

## 一、结论（一句话）

**这不是三个 bug，是一个 bug 的三个面**：服务端 `subscription_expires` 被**旧交易的到期日覆盖回退**了，
于是服务端认为"已过期"（同步 403 + 提醒），而端侧 StoreKit 仍认为"有效到 10-21"（显示订阅中）。

| 你看到的 | 真实来源 | 状态 |
|---|---|---|
| 「订阅中 · 到期日 **2026-10-21**」| **端侧 StoreKit**（Apple 沙盒自动续期，最新一笔是 10-21）| ✅ 正确 |
| **同步失败** | **服务端** `subscription_expires = 2026-10-18`（已过期）⇒ push 403 | 🔴 **被回退** |
| 订阅提醒弹窗 | 下游判据（服务端侧不认订阅）| 🔴 同一根因 |

⇒ 两个数字**都不是编的**，它们只是**两层的真实状态不一致**。用户视角："我付了钱，显示订阅中，却不同步。"

---

## 二、证据链（逐笔对照，完全闭环）

### 2.1 生产库现状

```
users.62731265 (mr.bigpi@foxmail.com)
  subscription_expires = 2026-10-18T13:57:39Z   ← 已过期（现在 2026-10-20T15:00Z）
```

但 `iap_transactions` 里**明明有一笔到 10-21 的**：

| txn | 到期 | 写入时间 |
|---|---|---|
| `…253873060` | **10-20** 13:59:12Z | 10-20 14:36:26 |
| `…254482343` | **10-21** 14:04:22Z | 10-20 14:36:26 |

### 2.2 服务端日志（同一次请求里，9 笔交易连续上报）

| 时刻 | 交易 | 到期 | 服务端判定 | 结果 |
|---|---|---|---|---|
| 14:36:26.606 | `…53873060` | 10-20 | `active=false` | 写 10-20 |
| 14:36:26.617 | **`…54482343`** | **10-21** | **`active=true`** | **写 10-21** ← 正确值 |
| 14:36:26.623 | `…54482343` | 10-21 | `active=true` | SameOwner，写 10-21 |
| 14:36:26.825 | `…52961713` | **10-18** | `active=false` | 🔴 **覆盖成 10-18** |
| 14:36:26.839 | `…53873060` | 10-20 | `active=false` | 覆盖成 10-20 |
| 14:36:27.520 | `…53298634` | 10-19 | `active=false` | 覆盖成 10-19 |
| 14:36:28.000 | `…53298634` | 10-19 | `active=false` | 覆盖成 10-19 |
| **14:36:29.535** | `…52961713` | **10-18** | `active=false` | 🔴 **最终值 = 10-18** |

**DB 实际值 `2026-10-18T13:57:39Z` 与最后一条日志逐字吻合** ✅

### 2.3 nginx（7 秒后同步就被拒）

```
22:36:26（+0800）  POST /api/iap/verify  → 200 ×9
22:36:33           POST /api/sync/push   → 403   ← 此时 DB 已是 10-18
```

---

## 三、🔴 根因：`set_expires` 是**无条件覆盖**（last-write-wins）

```rust
// backend/crates/api_server/src/subscription.rs:136
pub fn set_expires(conn: &Connection, user_id: &str, expires: &str) -> Result<()> {
    conn.execute(
        "UPDATE users SET subscription_expires = ?1 WHERE id = ?2",   // ← 无单调性
        params![expires, user_id],
    )?;
```

调用点只有一处是 IAP（`iap_handlers.rs:827`）：

```rust
// ── 6. 更新订阅到期日（🔴 直接写 Apple 的值，不是「加 N 天」）──
if let Some(ref exp) = expires_at {
    crate::subscription::set_expires(&conn, &body.user_id, exp)   // ← 谁最后到，谁说了算
```

### 为什么一次会有 9 笔？

Apple 沙盒月度订阅**自动续期**（约每 5 分钟一个周期），已经产生 10-15 ~ 10-21 多笔。
这次打开 App 时 **StoreKit 重放了全部历史交易**（9 笔），端侧 `_report` 是 `await` 串行，
但**顺序是 StoreKit 投递顺序，不是按到期日**。

⇒ **乱序 + 无条件覆盖 = 订阅被回退。**

### 🔑 为什么它是"随机"的，且更值得修

回退到哪个日期，**取决于最后投递的是哪一笔**。10-15 / 10-16 那几次没炸，只是"最后恰好是最新那笔"。
⇒ **同一用户今天能同步、明天不能**；换设备、重装、点一次「恢复购买」都可能重新触发。
这不是"沙盒才有的怪现象"——生产环境月度续期、用户一年多的历史交易，**同样会重放**。

---

## 四、影响范围

| 面 | 影响 |
|---|---|
| **付费用户** | 🔴 随机失去云端同步（pull 仍可，**push 403**）；界面却显示"订阅中" ⇒ 感知为"骗钱" |
| **服务端所有依赖订阅的判据** | 全部读到被回退的值：`is_subscription_active` · 翻译额度 · 云端书架上传 |
| **数据副作用** | `subscription_expires` **格式混用**（见下），使"字符串比较"这一常见写法**静默出错** |
| 免费用户 | 无影响 |

### 生产库全量扫描（只读，2026-10-20 23:0x）

判据：`users.subscription_expires < 他自己的 MAX(iap_transactions.expires_date)` ⇒ 被回退过

| 账号 | 当前值 | 交易最新值 | 判定 |
|---|---|---|---|
| `62731265` mr.bigpi | 10-18T13:57:39Z | **10-21T14:04:22Z** | 🔴 **被回退（本次）** |
| `b5b3a29d` 690861018 | `NULL` | 10-13T10:37:35Z | 🟡 非回退 —— 是 **10-13 我们主动清掉的串号脏数据**，且那笔已过期，不影响权益 |

⇒ **实际受影响只有你 1 个账号**（目前）。原因是这个 bug 需要"续期多笔 + 乱序投递"才触发，
而真实用户大多只有 1–2 笔交易。
⚠️ 但**上线后用户会积累交易**（每月续期一笔），触发概率随时间上升 ⇒ 仍必须修。

### ⚠️ 附带的第二处隐患：格式混用

| 写入方 | 格式 |
|---|---|
| IAP（`iap_handlers.rs:827`）| `2026-10-18T13:57:39Z`（RFC3339）|
| 后台/其他（`subscription.rs:244` `activate_subscription`）| `2026-10-18`（纯日期）|

实测：`'2026-10-18' < '2026-10-18T13:57:39Z'` 在 SQLite 里返回 **1**（因为短的在前）——
**看起来"对"，纯粹是因为日期恰好相同**。跨天时会出错的方向不固定。
⇒ 任何按字符串比较到期日的写法都**不可靠**，必须走 `datetime()` 归一。

---

## 五、修复方案（三选一，我推荐 A）

### ✅ 方案 A：`set_expires` 改为**只向前推进**（推荐）

```rust
/// 只允许**向后**推进到期日（IAP 上报专用）。
/// 乱序重放是常态（StoreKit 不保证顺序）⇒「最后写赢」必然导致回退。
pub fn set_expires_if_later(conn, user_id, expires) -> Result<bool> {
    let n = conn.execute(
        "UPDATE users SET subscription_expires = ?1
         WHERE id = ?2
           AND (subscription_expires IS NULL
                OR datetime(subscription_expires) < datetime(?1))",
        params![expires, user_id],
    )?;
    Ok(n > 0)
}
```

**已本地实测（SQLite）**：

| 依次写入 | 影响行数 | 现值 |
|---|---|---|
| 10-21（先）| 1 | 10-21 ✅ |
| 10-18（旧，乱序）| **0** | 10-21 ✅ 未被回退 |
| 10-19（旧）| **0** | 10-21 ✅ |

且 `datetime()` 对两种格式都能解析（`2026-10-18` → `2026-10-18 00:00:00`；带 `Z` 正常）⇒ **顺带兼容格式混用**。

- ✅ 根治乱序，与客户端顺序无关
- ✅ 一处改动影响全部依赖订阅的判据
- ⚠️ **退款/撤销需要能回退** ⇒ **保留原 `set_expires`** 给管理端/退款流程用；IAP 只用新函数
- ⚠️ 顺序约束：先改 schema/函数再改调用点，**不能反过来**（否则编译过但行为没变）

### 方案 B：端侧按到期日降序上报

- ❌ **不推荐**：只治一条路径。换客户端（Web/未来 Android）、并发上报、重试补报都可能再次乱序。
- 📌 记忆里已有同族判据：**「写端通知每个读端」= 必漏结构 ⇒ 应反转依赖**。
  这里同理：**顺序不该由客户端保证**。

### 方案 C：`iap_verify` 响应里让端侧修正

- ❌ 不够：端侧 `applyServerExpiry` **本来**就只向前推进（已实现，端侧显示是对的）。
  问题在**服务端自己**的值错了 ⇒ 同步仍 403。

---

## 六、需要你批的三件事

### ① 后端修复（方案 A —— 治「到期日被回退」）

改动清单：
| 文件 | 改动 |
|---|---|
| `subscription.rs` | 新增 `set_expires_if_later`（含单测：正序/乱序/空值/两格式）|
| `iap_handlers.rs:827` | 改调新函数；返回体 `expiresAt` 改为读**写入后**的实际值 |
| `verify_iap_plan.dart` | 断言：IAP 路径**不得**再调无条件版 `set_expires`（反向断言）|
| 无需出包 | 纯后端改动 ⇒ **只部署后端**，端侧不动 |

### ② 端侧修复（治「误弹窗」—— 独立缺陷，与 A 互补）

改动清单：
| 文件 | 改动 |
|---|---|
| `app.dart` `_applyExpired` 的调用点 | `availability != available` → **`availability == unavailable`**（`unknown` 不判定）|
| `verify_*` 断言 | 锁住「`unknown` 不得触发到期判定」+ 反向断言 |
| ⚠️ **需要出包** | 端侧改动 ⇒ 走 build 13 |

> 🔑 为何两个都要：A 让**服务端不再错**；② 让**服务端暂时没对上时也不误伤**。
> 只做 A：续费刚发生、服务端还没收到的那几秒仍可能误弹。
> 只做 ②：同步仍会 403（服务端真的过期了）。**必须两个都做。**

### ③ 数据修复（一条 SQL，需你点头才动生产）

把当前账号的到期日修正回真实最新值：

```sql
UPDATE users SET subscription_expires = '2026-10-21T14:04:22Z'
WHERE id = '62731265-edca-4fc9-8110-1877499e18fe';
```

- 更稳的做法：**从 `iap_transactions` 取该用户所有交易的 MAX(expires_date)** 反写
  （避免我手工填错，也能顺手核对其他账号有没有同样被回退）
- 会先备份（`coevo.db.bak-expiryfix-20261020`）
- 📌 这条**只影响当前这个账号**；其他用户要等 A 上线后才不会再被回退
  （可以先跑一次全量扫描：谁的 `users.subscription_expires` < 他自己的
  `MAX(iap_transactions.expires_date)` ⇒ 就是受害者）

### ③ ✅ 弹窗已定位（白哥给了线索：两个按钮 · 跳转订阅 + 取消 · 从 CoEvo 时代就有）

**就是 `app.dart:803 _buildSubExpiredOverlay()`** —— 标题「**订阅已到期**」的全局覆盖层
（挂在 `MaterialApp.builder` 顶层 Stack，任何页面都会盖住）。

> 我上一轮搜不到是因为按「订阅提醒 / 即将到期 / renew」搜文案，
> 而它的标题是「**订阅已到期**」、按钮走 `FilledButton` + `goRouter` 跳转
> —— **关键词选错了对象**。📌 判据：查 UI 组件要按**它自己的文案**搜，不是按我脑内的命名。

#### 🔴🔴 而它的值来自**服务端** —— 这就是第三处口径

```dart
// app.dart:786-799  _applyExpired
if (iap.availability == IapAvailability.available) {
  // ② 端侧权威：用 StoreKit 的 entitlement
  _applyExpired(expired: iap.entitlement == IapEntitlementStatus.expired, ...);
}

// ⚠️ 回退路径：`availability != available` ⇒ 用**服务端** isExpired
if (iap.availability != IapAvailability.available) {
  _applyExpired(expired: ref.read(subscriptionProvider).isExpired, ...);
}
```

而 `_checkSubscription()` 的**首次执行是启动后 3 秒**（`app.dart:674`）：

```dart
Future.delayed(const Duration(seconds: 3), _checkSubscription);
_subTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkSubscription());
```

`IapAvailability` 的初值是 **`unknown`**（`iap_service.dart:114`）：
```dart
enum IapAvailability { unknown /* 还没查 */, available, unavailable /* 真不可用 */ }
```

⇒ **启动 3 秒时 StoreKit 往往还没就绪 ⇒ `unknown` ⇒ 走服务端分支 ⇒
读到被回退的 10-18 ⇒ `isExpired = true` ⇒ 弹「订阅已到期」**
⇒ 而屏幕上 StoreKit 已给出 10-21 ⇒「订阅中」⇒ **自相矛盾正是这么来的**。

---

## 六·补、🔴 第二处独立缺陷：`unknown` 被当成 `unavailable`

| 状态 | 语义 | 应该怎么做 |
|---|---|---|
| `unknown` | **还没查** | ⏳ **等**（不要拿另一层的数据冒充） |
| `unavailable` | 端侧**真没有**这个能力 | ✅ 退回服务端才是对的 |
| `available` | 已就绪 | 用端侧 |

现在的判据 `availability != available` 把前两者混成一类 ⇒
**"端侧还没就绪"被当成了"端侧不可用"** ⇒ 服务端一旦滞后（新购未上报 / 被回退 / 对账未完成），
启动瞬间就会**误弹「订阅已到期」**。

⚠️ 注意：这条**独立于回退 bug**。即使到期日永远不被回退，
只要「用户刚续费、服务端还没收到」那几秒被 `_checkSubscription` 撞上，同样会误弹。

### 修法（建议与 A 同批）

1. **`unknown` 不判定**：只在 `unavailable` 时用服务端值；
   `unknown` ⇒ 本轮跳过（5 分钟后的轮询会补上，端侧就绪后也会立刻判）
2. 或者：`unknown` 时若服务端说"已过期"，**再等 5 秒**重取端侧状态，仍 unknown 才用服务端
3. 断言：`_applyExpired` 的两个分支条件必须显式区分 `unknown` / `unavailable`
   （现在是 `!= available`，改成 `== unavailable` 即可，一行）

📌 修好后行为：**服务端被回退时不再误弹窗**（同步仍会 403，那由方案 A 治）。
两者互补，缺一个都还会看到"界面矛盾"。

---

## 六·补2、弹窗全清单（白哥问「有哪些弹窗」）

全应用只有 **8 处**弹层，其中**自动弹的只有 2 个**：

| # | 弹层 | 位置 | 何时出现 | 自动？ |
|---|---|---|---|---|
| **1** | **「订阅已到期」覆盖层** | `app.dart:803` | 订阅判定为 expired（**本次问题**）| 🔴 自动 |
| **2** | 成就解锁 | `widgets/achievement_unlock_overlay.dart` | 达成成就 | 🔴 自动 |
| 3 | 同步进度转圈 | `widgets/sync_progress_dialog.dart` | 手动/触发同步时 | 用户动作 |
| 4 | 通用确认框 `CoDialog` | `widgets/co_dialog.dart` | 各处确认/危险操作 | 用户动作 |
| 5 | 分享图预览 | `widgets/share_card_preview.dart` | 点「分享」后 | 用户动作 |
| 6 | 电子书导入流程 | `services/ebook/book_import_flow.dart` | 选文件后 | 用户动作 |
| 7 | 划词生成等待（转圈）| `services/word_lookup.dart` | 查词触发 LLM 生成 | 用户动作 |
| 8 | 登录对话框 | `widgets/auth_dialog.dart` | 需登录的操作 | 用户动作 |

⇒ 你的判断对：**没几个**。而且「自动弹」的只有 #1 和 #2，所以这次要查的必然是 #1 —— 确实就是它。

---

## 七、判据沉淀（这条值得长期记）

> 📌 **幂等写入 ≠ 可以乱序到达。**
> 「同一实体被多次写入」时，必须先问：**这些写入有先后语义吗？**
> · 有（到期日、余额、计数器）⇒ 写入必须是 **max / 累加 / 带版本号**，不能 last-write-wins
> · 无（覆盖式配置）⇒ 才可以直接写

> 📌 **「显示订阅中 + 同步失败」不是矛盾，是两层各自说了真话。**
> 这一类"看起来自相矛盾"的现象，正确切法是**分层列出每层的值**，而不是找"哪个界面写错了"。

---

## 八、✅ 实施记录（2026-10-20 23:2x · 白哥批「1、2、3 都做」）

### 8.1 ① 后端：到期日**只向前推进**

`subscription.rs`
- 🆕 `set_expires_if_later(conn, user_id, expires) -> Result<bool>`
  ```sql
  UPDATE users SET subscription_expires = ?1
   WHERE id = ?2
     AND (subscription_expires IS NULL
          OR datetime(subscription_expires) < datetime(?1))
  ```
  返回 `Ok(false)` = 本次比库里旧、**已忽略**（不是错误）
- 🔴 **`set_expires` 原封不动保留** —— 退款 / 人工撤销**需要**能回退
- 🆕 单测 **6 条**（`subscription::tests`）：
  空值写入 · 正序推进 · **乱序不回退** · 相等不动 · **两种日期格式混用** · **反向对照（无条件版仍能回退）**

`iap_handlers.rs`
- 调用点改 `set_expires_if_later`；**入口先校验 RFC3339**（格式坏 ⇒ 500 + error，
  而不是被 SQL 静默忽略 —— 那是「静默失效」的入口）
- 未推进时打 INFO（不是 WARN：每次重放都会出现，WARN 会淹没真问题）
- 🔴 响应 `expiresAt` / `isActive` 改为**库里实际生效值**（`effective_expires`），
  不再是本次交易值 —— 乱序时两者不同，客户端拿错会把权益判错
- 日志增加 `expires(本次)` / `expires(生效)` 两个字段

### 8.2 ② 端侧：`unknown` 不再触发到期判定

`app.dart` `_checkSubscription` 的回退判据：

```diff
- if (iap.availability != IapAvailability.available) {   // unknown 也算「端侧不行」
+ if (iap.availability == IapAvailability.unavailable) { // 只有「真不可用」才退回服务端
```

`unknown`（还没查）⇒ 本轮跳过。端侧就绪后 `iap` 变化会触发 rebuild ⇒
`build()` 里的 microtask 立刻补判，**不会漏判**。

### 8.3 🎨「订阅已到期」弹窗重做（白哥：「丑陋的很，不符合设计规范」）

**根因**：它不能用 `showDialog`（上下文在 Navigator 之上），于是当年**手搓了一整套外观** ——
`Colors.white` 硬编码 + `Icons.lock` + `FilledButton`/`TextButton`
⇒ 三档主题（墨/格/夜）里它**永远是白板**，与粘土/朱砂体系完全脱节。

**修法（不是"再手搓一版更好看的"）**：
- 🆕 从 `CoDialog` **抽出 `CoDialogSurface`** —— 弹层的**内容外壳**（card 底 + 圆角 20 + 外阴影 + `title` + `actions` 行）
- `CoDialog` 改为 `Dialog(child: CoDialogSurface(...))`（行为不变）
- 覆盖层改为 `Center → CoDialogSurface(...)` —— **两条路径共用同一处外观定义**
- 内容：标题「订阅已到期」（20px/w600，同其它弹窗）+ 正文走 **`downgradeNotice()`**（唯一文案源）
- 按钮：`ClayButton` 主（查看订阅）+ 次（稍后再说），`expanded: true`
- 遮罩沿用 `showDialog` 默认的 54% 黑（不另发明浓度）

📌 判据：**「不能用 Dialog 路由」≠「可以另写一套外观」** —— 该拆的是**外壳**，不是让它分叉。

### 8.4 ③ 数据修复（生产库）

| 项 | 值 |
|---|---|
| 备份 | `coevo.db.bak-expiryfix-20261020`（31.7 MB · 600）|
| 反写来源 | `MAX(iap_transactions.expires_date)` = `2000001254482343` → `2026-10-21T14:04:22Z` |
| UPDATE | `10-18 → 10-21`（**1 行**，与后端新逻辑同口径：`WHERE datetime(...) < datetime(?)`）|
| 审计 | `data_repair_iap_expiry_rollback`（含 from/to/evidence）|
| 🔴 **同步验证** | `POST /api/sync/push` → **200**（修复前 403）· `GET /pull` → 200 · 21844 bytes |
| 全库复扫 | ✅ 无残留（`b5b3a29d` 的 `NULL` 是 10-13 主动清的串号数据，且其交易已过期，**不修**）|

### 8.5 断言（`verify_iap_plan` ⑳ 组 +11，共 **281 项**）

| # | 守什么 |
|---|---|
| ⑳-1/2 | IAP 必须用 `set_expires_if_later`；**无条件版不得再出现在 handler**（反向）|
| ⑳-3 | 单调条件必须在 **SQL 里**（不在 Rust 里读-改-写，避免并发窗口）|
| ⑳-4 | 响应 `expiresAt` 必须是**库里生效值** |
| ⑳-5 | 无条件版**仍须存在**（退款依赖它 —— 防"顺手也改成单调"）|
| ⑳-6/7 | `unknown` 不得触发判定；`!= available` 反向断言 |
| ⑳-8 | **先证明切片有效**（否则 ⑳-9~11 会因空串**假绿**）|
| ⑳-9/10/11 | 弹窗必须用 `CoDialogSurface`；不得出现 `Colors.white`/`Icons.lock`/`FilledButton`；按钮 ≥2 个 `ClayButton` |

### 8.6 验证（全绿）

| 项 | 结果 |
|---|---|
| `cargo test` | **314 passed**（308 → +6）|
| `cargo fmt --check` / clippy `--workspace -- -D warnings` | ✅ / **exit 0** |
| `analyze_inproc` | **error=0 / warning=0** |
| `iap_verify` | **281 项**（270 → +11）|
| verify_auth_entry / review_pause / local_owner / sync | 118 / 49 / 59 / 221 |
| tokens_verify / ebook reading_tab | 732 / 99(fail=0) |

🔴 **证伪 ×3，全部精确命中**：
- 后端去掉 SQL 单调条件 ⇒ **恰好** `test_if_later_ignores_older` + `test_if_later_equal_is_noop` 红
- 端侧判据退回 `!= available` ⇒ **恰好** ⑳-6、⑳-7 红
- 弹窗还原成旧的手搓白板（`git show HEAD` 的原文）⇒ **恰好** ⑳-9、⑳-10、⑳-11 红

### 8.7 ⏳ 遗留（本次未做，如实记录）

1. **`subscription_expires` 格式混用仍在**（IAP 写 RFC3339 / `activate_subscription` 写纯日期）
   —— 本次用 `datetime()` 规避了比较问题，但**没统一格式**。建议后续单独立项。
2. **后端需重新构建部署**（新逻辑才生效）；**端侧需出 build 13**（弹窗 + 判据）。
3. 其它账号若也被回退过，本次不批量修（扫描已证明目前只有 1 个）；
   ① 上线后不会再产生新的回退。
