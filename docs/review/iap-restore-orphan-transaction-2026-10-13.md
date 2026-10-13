# 【调查报告】「恢复购买」显示已恢复但权益未生效 —— 注销后的「孤儿交易」

*2026-10-13 22:40 出报告 · 23:00 白哥定案「**跟**」并实施（见 §九）*
*依赖：SSH 直查生产库 + 服务端日志 + nginx access.log + 读端侧/服务端代码*

---

## 一、白哥报告的现象

> 「注销账号重新登录，点恢复购买**显示已恢复**，但订阅状态**并未改变**（还是未订阅）；
>  但点**购买**又显示**已订阅**。订阅状态的一致性一直有点乱。」

三个观察同时为真，而且**各有各的原因** —— 详见 §三。

---

## 二、恢复购买的完整原理（读代码得到，非转述）

### 2.1 它「恢复」的其实是 **Apple ID 名下的交易**，不是我们的账号资产

```
点「恢复购买」
  └─ IapService.restore()
       └─ InAppPurchase.instance.restorePurchases()      ← StoreKit API
            └─ Apple 把该 Apple ID 名下所有 订阅/非消耗型 交易
               **重新投递**到 purchaseStream
                 └─ IapService._deliver(pd)  逐笔处理
```

🔑 **关键**：StoreKit 恢复的是 **Apple ID 层面的购买历史**。它**完全不知道**我们有几个 app 账号。

### 2.2 `_deliver` 每一步做了什么（`iap_service.dart`）

| 步 | 动作 | 关键点 |
|---|---|---|
| ① | 解析到期日 `_parseExpiry(pd)` | 读 `SK2PurchaseDetails.expirationDate` |
| ①' | 解析归属 `_parseOwnerUserId(pd)` | 🔴 读**交易自带**的 `appAccountToken` —— **不是**「当前登录 userId」 |
| ①'' | `_snapshot.entitlement = resolveEntitlement(...)` | 🔴 **只看有效期，不看归属** |
| ② | `_complete(pd)` 完成事务 | 必须 |
| ③ | `_report(pd)` 上报服务端 | **无条件上报**（不因归属不符而跳过）|

### 2.3 `restore()` 的「成功」是怎么判的

```dart
await Future<void>.delayed(const Duration(milliseconds: 1200));
_emit(_snapshot.copyWith(purchasing: false));
return _snapshot.entitlement == IapEntitlementStatus.active   // 🔴 只看这一项
    ? RestoreOutcome.restored
    : RestoreOutcome.notFound;
```

### 2.4 而 UI 的「订阅中」是另**一个**判据（`iap_provider.dart`）

```dart
bool subscriptionActiveNow(WidgetRef ref) {
  final snap = iapSnapshotOf(ref);
  return subscriptionActive(
    iapActive: snap.isActive &&
        iapEntitlementBelongsToAccount(          // 🔴 这里**多了一层归属过滤**
          ownerUserId: snap.ownerUserId,
          currentUserId: ref.watch(authProvider).userId),
    backendActive: ref.watch(subscriptionProvider).isActive,   // 服务端也算
  );
}
```

⇒ **同一个 `_snapshot`，两个判据** ⇒ 「恢复成功」与「有订阅」可以同时不成立/成立 —— 这就是矛盾的**形式来源**。

---

## 三、把三个现象逐一钉到证据上

### 3.1 「点购买显示已订阅」= **Apple 的正常行为**（不是 bug）

该 Apple ID 名下**确实有有效订阅**：`iap_transactions` 最新一笔
`tx=2000001250547911`（`pro.monthly`）`expires_date = 2026-10-14T13:57:30Z`（**尚未过期**）。

Apple 规则：同一 Apple ID 对同一订阅产品**同一时间只能有一份活跃订阅** ⇒ 不允许重复购买 ⇒ 弹「你目前已订阅」。

### 3.2 「点恢复购买显示已恢复，但状态没变」= **两处口径不一致 + 服务端 409**

**服务端日志（铁证，共 6 次）**：

```
14:39:48Z WARN iap_handlers: IAP 账号绑定不匹配 ⇒ 拒绝
           tx=2000001250547911 绑定=5391ad37-8043-4d8e-91ec-01ea3286d9c5
           上报者=7ccd6274-e2bd-49d5-9ebd-299f16917a13
（14:40:03 · 14:40:18 ×3 · 14:41:26 共 6 条）
```

**nginx 对照**：`POST /api/iap/verify → 409`（同一时刻，同样是 6 次）。

**完整链路**：

| # | 环节 | 实际发生 |
|---|---|---|
| 1 | Apple 层 | 该 Apple ID 有有效订阅 ⇒ StoreKit 重放 `2000001250547911` |
| 2 | 该交易自带 | `appAccountToken = 5391ad37…` ← **白哥 21:57 登录的那个账号** |
| 3 | 端侧 | 读 token ⇒ 归属 `5391ad37` ⇒ **≠ 当前 `7ccd6274`** ⇒ UI 归属过滤掉 |
| 4 | 端侧上报 | `_report` 无条件上报 ⇒ 发了 **6 次** |
| 5 | 服务端 | `account_binding_conflict(token=5391ad37…, user_id=7ccd6274…)` ⇒ 不符 ⇒ **409，不写库** |
| 6 | `restore()` | 判 `_snapshot.entitlement == active`（**没做归属过滤**）⇒ 返回 `restored` ⇒ 提示「已恢复」|
| 7 | UI | `iapActive` 被归属过滤成 false · `backendActive` 也是 false ⇒ **显示未订阅** |

⇒ 白哥看到的「已恢复 + 未订阅」是 **第 6 步与第 7 步用了两套口径** 的直接产物。

---

## 四、根因：两个独立缺陷

### 🔴 缺陷 A（严重）：注销后重登 ⇒ 交易成「**孤儿**」⇒ 付了钱拿不到权益

**机制**：

1. 注销时，`purge_user` 把 `iap_transactions.user_id` **匿名化**（→ `deleted:xxx`）——
   设计上是对的（保留对账、断开身份）。
2. 🔴 但交易的 **`appAccountToken` 是 Apple 签在 JWS 里的** ⇒ **我们改不掉、也删不掉**。
3. 服务端 `account_binding_conflict(app_account_token, user_id)`
   **只比对「token 是否等于当前账号」** ⇒ **从不检查那个 token 指向的账号是否还存在**。
4. ⇒ 用户注销 → 重新 Apple 登录（新 userId）⇒ 重放的交易 token 指向**已注销的账号**
   ⇒ **永远 409** ⇒ **用自己的 Apple ID、订阅还有效，却拿不到权益**。

**为什么严重**：
- 用户视角是「**我付了钱，你说已恢复，但功能没给我**」—— 本项目最忌的「静默失败 + 无出口」。
- ⚠️ **同样撞 Apple 审核 3.1.1**：恢复购买必须能恢复。

### 🟠 缺陷 B（次要，但直接制造了这次看到的矛盾）

`restore()` 的「成功」判据（`_snapshot.entitlement == active`）**与 UI 的判据不是同一个**
（UI 那个带归属过滤）。
⇒ 只要「收到了交易但归属不符」，就必然出现「**提示已恢复 + 显示未订阅**」。

📌 判据：**同一件事的口径只能有一处权威**。此处有两处。

---

## 五、（顺带）历史日志印证了今晚修的串号

```
04:16:11Z WARN iap_handlers: IAP 归属冲突 ⇒ 拒绝 tx=2000001249787368
          上报者=b5b3a29d（=690861018）实际归属=c96e3b62（=baixu100）
```

⇒ **真买家 `690861018` 当时确实来上报过，被串号者 `baixu100` 挡住了** ——
这为今晚「把归属改回 `690861018`」的修复提供了**独立的日志证据**（此前只有时间戳推理）。

---

## 六、修法（**等白哥审批，未动代码**）

### 6.1 缺陷 A —— 需要先做一个**产品决策**

> **注销后重新登录，订阅该不该跟过来？**

| 选择 | 含义 | 后果 |
|---|---|---|
| **跟**（推荐）| 订阅跟 **Apple ID**；token 指向的账号**已不存在** ⇒ 视为可重新绑定 | 需改服务端；符合 Apple 现实；**审核安全** |
| **不跟** | 现状即"正确" | **必须**① 修掉「已恢复」的谎报 ② 在注销页**明确告知**「注销后订阅不再恢复」否则用户投诉 + 审核风险 |

**我推荐「跟」**，理由：用户没换 Apple ID，订阅是 Apple 认的、还在有效期内；
且我们**本来也无法**阻止 Apple 向新账号发续期交易（见 §7）。

### 6.2 若选「跟」，具体改法

1. **服务端**（`iap_handlers.rs::account_binding_conflict`）：
   比对前先查 `SELECT 1 FROM users WHERE id = token` ——
   **不存在**（已注销）⇒ 不冲突，允许当前账号认领并重新绑定。
   ⚠️ 必须保留「token 指向**另一个活跃**账号 ⇒ 409」这条（那才是防串号）。
2. **端侧**：归属判定同理 —— token 指向的账号**在当前登录账号看来不是自己**且
   **服务端已认领给当前账号**时，应以**服务端结果**为权威。
   （`subscriptionActiveNow` 已经是 `iapActive || backendActive` ⇒ 服务端认了 UI 就绿，
   所以**主要改服务端即可**。）

### 6.3 缺陷 B 的修法（无论选哪个都要改）

`restore()` 的返回判定**改走与 UI 同一个函数**（或至少在判定里加入归属过滤），
⇒ 不再出现「提示已恢复 / 显示未订阅」。

### 6.4 附带建议（防复发）

- 加断言：`restore()` 的成功判定**必须**与 `subscriptionActiveNow` 同源（防两套口径复活）。
- 加断言：`account_binding_conflict` 对「token 指向已注销账号」的行为写死（正反两例）。

---

## 七、附带确认的一条边界（已在沙盒实测到）

同一 Apple ID 换 app 账号时，**Apple 会把订阅续给「当前登录的那个账号」**：

```
tx=2000001250547911 · orig=2000001249787368（同一订阅链）
appAccountToken = 5391ad37…（= 当下登录的账号自己）· PURCHASE（续期）
```

⇒ **Apple 的订阅永远跟 Apple ID 走**，我们挡不住它给新账号发续期交易。
⇒ 「订阅与账号一一绑定」的**可实现边界**是：**一笔交易只归一个账号**；
   而**不是**「订阅锁死在某账号上」（那在 Apple 层做不到）。

---

## 八、待白哥定

1. **产品决策**：注销后重新登录，订阅**跟**还是**不跟**？（§6.1，我推荐跟）
2. 批准后我改：服务端孤儿处理（A）+ `restore()` 口径统一（B）+ 两条断言。
3. ⚠️ 若最终**不跟**，则**必须**改注销页文案（明确告知权益不恢复）—— 这条是审核风险，优先级高于功能本身。

---

## 九、✅ 实施记录（2026-10-13 23:00 · 白哥定案「**跟**」）

### 9.1 服务端（主修）：孤儿绑定归一化

`iap_handlers.rs`
- 🆕 纯函数 `effective_binding(app_account_token, user_id, bound_exists)` ——
  「绑定指向**已注销账号**」⇒ 归一化成 `None`（视为无绑定）
- 🆕 `bound_account_exists(conn, bound)` —— 只在**必要时**查一次库
- 调用点：**B1' 在 B1 之前**（先归一化、再比对）。顺序不可反 —— 反了孤儿仍会 409
- 🔴 **必须保留**「绑定指向另一个**活跃**账号 ⇒ 拒绝」（防串号防线，有反向断言守着）
- 新增 `test_effective_binding`（含端到端组合：归一化 → `account_binding_conflict` 的最终结论）

### 9.2 端侧（次修）：`restore()` 判定与 UI 同源

- 🆕 `iap_plan.judgeRestoreOutcome({entitlement, ownerUserId, currentUserId})` —— 唯一判据（带归属过滤）
- `iap_service.restore()` 改走它；旧的 `_snapshot.entitlement == active` 内联判定**已删**
- 🔑 端侧**不需要**知道服务端状态：服务端认领后会回传权威到期日 ⇒
  `applyServerExpiry(..., ownerUserId: 当前账号)` 把归属**改写成本账号** ⇒ 自愈

### 9.3 验证

| 项 | 结果 |
|---|---|
| `cargo test -p api_server` | **307 passed / 0 failed**（+1）|
| `cargo fmt --check` / clippy `--workspace -- -D warnings` | ✅ / **exit 0** |
| `analyze_inproc` | **error=0 / warning=0** |
| `iap_verify` | **267 项**（258 → +9，新增 ⑱ 组）|
| `verify_app_version` | 12 项 |

🔴 **证伪 ×3，全部精确命中**：
- `judgeRestoreOutcome` 去掉归属过滤 ⇒ 红 **4 条**（⑱-2/3/6/7）
- `restore()` 真改回内联判定 ⇒ 红 **2 条**（⑱-8/9）
- `effective_binding` 不再归一化 ⇒ Rust **只** `test_effective_binding` 红

⚠️ 首版断言差点写**假绿**：「无绑定 + 未登录」我按直觉写成 `restored`，
独立核对 `iapEntitlementBelongsToAccount` 实现（`ownerUserId == null ⇒ false`）后才改回 `notFound`。
📌 判据：**期望值必须独立核实**，不能凭印象。

### 9.4 部署

- 后端：**待白哥跑 WSL 构建**（`wsl.exe` 在 agent 沙箱被封禁）→ 之后由 agent 上传/替换/重启/验证
- 端侧：随 **build 12**（`1.0.0+12`）出包

---

## 十、🔴🔴 部署后**端到端验证抓出第二处**（B2'）—— 「补丁 ≠ 修法」

### 10.1 第一次部署后：仍然 409，但**错误文案变了**

```
HTTP 409 · {"error":"该交易已归属其他账号，无法重复开通"}
```

对照两处 409 的文案：
| 层 | 文案 | 位置 |
|---|---|---|
| B1（绑定层）| 「该交易**绑定的账号**与当前登录账号不一致」| `account_binding_conflict` |
| **B2（归属层）** | 「该交易**已归属其他账号**，无法重复开通」| `upsert_transaction` |

⇒ 文案是 B2 的 ⇒ **B1' 生效了，但 B2 那一层还有同一个洞**。

**而我本地 307 项单测全绿** —— 因为它们只覆盖了「我改的那一处」。

📌 **判据（两条，都值得长期记）**：
1. **补丁 ≠ 修法** —— 找到一个洞，必须先问「**还有哪些地方有同样的问题**」。
2. **单测覆盖「改的地方」≠ 覆盖「完整链路」** ⇒ 这次是**端到端验证**（不是单测）抓出来的。

### 10.2 B2' 修法

`upsert_transaction` 里的原归属判定原本只比字符串（`owner != user_id`）：
- 🆕 改成：`account_id_exists(conn, owner)` 为 false（**账号已注销**）⇒
  不返 `Conflict`，而是**允许重新认领**（判 `Claimed`）
- 🔴 并且**显式改写** `user_id` —— UPSERT 的 `SET` 里**故意没有** `user_id`
  （归属一旦确定不再改，是防串号核心）；此处是它**唯一的例外**
- 🔴 **保留**「活跃账号 ⇒ Conflict」

`bound_account_exists` → 改名 **`account_id_exists`**（B1' / B2' 共用同一判据）。

**新增测试** `test_upsert_transaction_reclaims_orphan_owner`（含「活跃⇒Conflict」反向断言）。
⚠️ 测试里写 `deleted:` 形态**必须先关外键** —— `iap_transactions.user_id` 有
`FOREIGN KEY REFERENCES users(id)`（**无 CASCADE**，有意为之：支付记录必须留库对账），
真实注销（`purge_user`）也是用 `with_foreign_keys_off` 包的。

### 10.3 防止再漏：⑲ 组断言（3 条）

把「两处都用同一判据」变成**断言**（`iap_verify` 直接读 Rust 源码）：
- ⑲-1 `account_id_exists` 至少出现 3 次（定义 1 + 调用 2）—— **删任一处即红**
- ⑲-2 孤儿重新认领必须**显式** `UPDATE iap_transactions SET user_id`
- ⑲-3 防串号防线仍在（`return Ok(Ownership::Conflict` 不得被删）

### 10.4 验证

`cargo test` **308 passed**（+1）· fmt ✅ · clippy `-D warnings` **exit 0** ·
`iap_verify` **270 项**（+3，⑲ 组）

🔴 **证伪 ×2 精确命中**：
- B2' 退回旧行为 ⇒ Rust **只** `test_upsert_transaction_reclaims_orphan_owner` 红
- 删掉 B1' 的一处 `account_id_exists` 调用 ⇒ ⑲-1 红（「实际 2 次」）
