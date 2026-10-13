# 出包产物丢自定义 entitlements —— 「通过 Apple 继续」静默无反应

> **触发**：2026-10-13 白哥真机（build 8）点「通过 Apple 继续」**没有任何反应**。
> **结论**：**根因已铁证** —— 2026-10-11 的 CI 改动（归档阶段不签名）导致
> **所有自定义 entitlement 在导出时丢失**，其中就包括 `com.apple.developer.applesignin`。
> **状态**：⚠️ **未修**（待白哥定方案）。本文只调查，不改代码。

---

## 一、现象与第一层定位

| 观察 | 结论 |
|---|---|
| 点「通过 Apple 继续」无任何界面变化 | 不是「登录失败弹错误」—— 是**连 Apple 的系统授权界面都没出现** |
| **服务端 nginx 从未收到 `/api/auth/apple`** | ⇒ 请求**根本没离开设备** |
| 应用日志里唯一一条 `auth_apple` 是 **17:49 我的冒烟测试** | ⇒ 不是后端问题 |

⇒ 失败点在**端侧**，且发生在 `SignInWithApple.getAppleIDCredential` 这一层。

### 1.1 为什么"看不见"任何错误（代码缺陷，独立于根因）

`app/lib/widgets/auth_dialog.dart` 的 `_submitApple()`：

```dart
} on SignInWithAppleAuthorizationException catch (e) {
  if (e.code == AuthorizationErrorCode.canceled) { ... return; }   // 用户取消 —— 静默正确
  debugPrint('auth_dialog: Apple 授权失败 code=${e.code} msg=${e.message}');  // 🔴 仅日志
  if (mounted) setState(() => _isSubmitting = false);
} catch (e) {
  debugPrint('auth_dialog: Apple 登录失败: $e');                    // 🔴 仅日志
  if (mounted) setState(() => _isSubmitting = false);
}
```

**非「用户取消」类的失败，界面上**没有任何**反馈** —— 用户看到的就是「点了没反应」。
📌 这正是本项目反复警惕的 **「静默失败 + 无出口」**。
⚠️ 它也让**这次排查变难**：真机上拿不到那个 `code`。

---

## 二、根因：归档不签名 ⇒ 导出时无从保留 entitlements

### 2.1 直接证据（A/B 对照，解析真 IPA）

方法：下载 CI 的 IPA 产物，解析 **Runner 可执行文件的代码签名 Entitlements blob**
（大端 magic `0xfade7171`），并做**阳性对照**（`SuperBlob 0xfade0cc0` 命中 ⇒ 证明包确实签过名、
不是「没签名所以扫不到」）。

| 包 | 构建时间 | `application-identifier` | `team-identifier` | `get-task-allow` | **`applesignin`** |
|---|---|---|---|---|---|
| **改动前**（run `38066732694`）| 2026-10-10 | ✅ | ✅ | ✅ | ✅ **`['Default']`** |
| **改动后**（run `38138109612`）| 2026-10-11 | ✅ | ✅ | ✅ | ❌ **无** |

- 其余三项**完全一致** ⇒ 变的**就是**这一个 entitlement
- 描述文件（`embedded.mobileprovision`）**两边都授予了** `com.apple.developer.applesignin = ['Default']`
  ⇒ **不是账号配置问题，是签名时没写进去**

### 2.2 引入点

```
commit 6575f35 · 2026-10-11T12:48:34+08:00
ci(ios): 归档阶段不签名 ⇒ 根治「Development 证书随 CI 堆积」
```

该提交把 Archive 改成：

```
CODE_SIGNING_ALLOWED=NO  CODE_SIGNING_REQUIRED=NO
```

**动机是正当的**（10-11 因 Development 证书撞上限连续两次出包失败），
但它有一个**未被发现的副作用**。

### 2.3 机制（Apple 官方原话）

> "Keep in mind that exporting from the archive tries to preserve entitlements.
> **But entitlements are carried by the code signature, so if the app in the archive
> isn't signed then there's nothing to preserve.**"
> —— Apple Developer Forums, DTS Engineer（thread 720887）

- Archive 不签名 ⇒ archive 里的 `.app` **没有任何 entitlements 载体**
- 导出阶段重签时，能补的只有 **base entitlements**
  （`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES` 从描述文件注入
  ⇒ 这也正是为什么 `application-identifier` / `team-identifier` **在**、而自定义项**不在**）
- 自定义项（来自 `CODE_SIGN_ENTITLEMENTS` 文件）**无处可来** ⇒ 丢失

🔴 **当时没发现，是因为那次只验了「CI 成功」**：
提交说明自己写着「本机无法验证 ⇒ 只能靠这次 CI 判定」——
判的是**「包出来了」**，不是**「包带对了能力」**。
📌 判据**跟错了意图**（同族：2026-10-09 部署包 sha256 相同那次）。

---

## 三、影响范围（比这一个功能大）

### 3.1 已确认受影响

| 包 | 出的时间 | 在 `6575f35` 之后？ | Apple 登录 |
|---|---|---|---|
| build 6 | 10-12 13:51 | ✅ | ❌ 不工作 |
| build 7 | 10-12 14:57 | ✅ | ❌ 不工作 |
| build 8 | 10-13 09:51 | ✅ | ❌ 不工作（白哥本次实测）|
| 10-11 的 ad-hoc 包 | 10-11 20:07 | ✅ | ❌ 工件已证实缺 entitlement |

⚠️ **build 1–5（10-11 之前）不受影响** —— 那时 Archive 正常签名。
✅ **与白哥 2026-10-07 反馈「Apple 登录 ✅」自洽**：那时用的是改动前的包。

### 3.2 更大的影响：**今后任何新加的自定义 entitlement 都会同样静默丢失**

目前只有 `applesignin` 一个，所以只表现成 Apple 登录坏掉。
但一旦将来加：推送（`aps-environment`）、关联域（`associated-domains`）、App Groups、
钥匙串共享……**全都会静默丢失**，且症状各不相同、都难查。

### 3.3 不影响

- 邮箱注册 / 登录 / 改密码 / 找回密码 ✅（不依赖 entitlement）
- IAP 订阅 ✅（走 `IAP_*` 服务端校验，不依赖 entitlement）
- 同步 / 复习 / 信息流 ✅

### 3.4 对本次 C 项（注销撤销 Apple 授权）的影响

`authorizationCode` 链路**从未被真实触发过**（服务端 0 请求，与症状吻合）。
⇒ 修好这个之后，那条链路才有机会在真实登录中落地。

---

## 四、修复方案

### 方案 ①（**推荐**）archive 用 **ad-hoc identity** 签名

```diff
-            CODE_SIGNING_ALLOWED=NO \
-            CODE_SIGNING_REQUIRED=NO \
+            CODE_SIGN_IDENTITY=- \
+            AD_HOC_CODE_SIGNING_ALLOWED=YES \
+            CODE_SIGN_STYLE=Automatic \
             DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
             archive
```

- `CODE_SIGN_IDENTITY=-` = **ad-hoc 签名**：**不需要任何证书/profile**，但**会写入 entitlements**
- ⇒ **同时满足两个目标**：entitlements 保住了、Development 证书**依然不消耗**
- 📌 依据：Apple Developer Forums thread 756119（提问者用这套参数解决了同一问题，
  并由 Apple DTS 工程师参与讨论）
- ⚠️ **待实测的一个不确定点**：`pbxproj` 里是
  `"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer"`（**带 sdk 条件**），
  可能覆盖命令行传的无条件 `CODE_SIGN_IDENTITY=-`。
  ⇒ 若被覆盖，退回方案 ②。

### 方案 ②archive 后手动 `codesign` 注入 entitlements

```bash
codesign -f -s - --entitlements app/ios/Runner/Runner.entitlements \
  "$ARCHIVE/Products/Applications/Runner.app"
```
- `-s -` = ad-hoc 签名；`--entitlements` 显式给文件
- 更**显式可控**（不依赖 Xcode 的自动行为），但需要额外生成**合并了 base 项的** entitlements 文件
- 📌 依据：同 thread 756119、thread 686345（多方实测）

### 方案 ③（兜底）`git revert 6575f35`

- 立刻回到 10-10 的可用状态（已验证那种包 entitlements 正常）
- 代价：**Development 证书继续堆积**（就是当初要解决的问题）
  ⇒ 需要定期去 ASC 清理「Created via API」的孤儿证书

### 4.4 无论选哪个，**都必须补两条判据**（否则同类问题还会静默复发）

| # | 拦门 | 位置 |
|---|---|---|
| **a** | **出包后校验 IPA 的 entitlements**（解析签名 blob，断言目标项都在）| `export` 模式下一律跑；**不过就红** |
| **b** | 端侧 `_submitApple()` 的**非取消类失败必须有可见提示**（不再是只 debugPrint）| 随 build 9 出包 |

📌 (a) 的思路就是本文用的那个解析器，可直接落成 `scripts/deploy/verify_ipa_entitlements.py`。
⚠️ 但 `upload` 模式**没有本地 IPA**（产物在 ASC）⇒ 拦门只能覆盖 `export` 模式。
**折中**：archive 后立即断言 `archived-expanded-entitlements.xcent` 存在且含目标项
（两模式都能跑），作为第一道闸。

---

## 五、需要白哥定的

1. **选哪个修复方案**（我推荐 ①，不成退 ②，兜底 ③）
2. 是否同意**补 (a)(b) 两条判据**
3. 修法确定后要**再出一轮包**验证 —— 建议**先用 `export` 模式**跑（能拿到 IPA 让我在本地
   逐项验签名），**验证通过再 `upload`**，避免又往 ASC 推一个坏包

---

*2026-10-13 · 方法：解析真 IPA 的代码签名 blob（A/B 对照 + 阳性对照）·
git 定位引入点 · Apple Developer Forums 官方机制说明 · SSH 直查服务端日志*
