# iOS 出包失败：Apple 账号证书达上限（2026-10-11 12:11）

> 触发：白哥「IOS 可以出包了」→ run **38110797295** → `Archive` 步骤 **exit 65**。
> **结论：不是代码问题**，是 **Apple 开发者账号侧的证书上限**。
> ⚠️ 仓库**已立刻改回 private**（复核 `isPrivate: true` ✅）。

---

## 一、失败现象（CI 原文）

```
Archive & Export IPA   Archive   ** ARCHIVE FAILED **

app/ios/Runner.xcodeproj: error: Choose a certificate to revoke.
    Your account has reached the maximum number of certificates.
    To create a new one, you must choose a certificate to revoke.
    (in target 'Runner' from project 'Runner')

app/ios/Runner.xcodeproj: error: No profiles for 'com.coevo.coevoApp' were found:
    Xcode couldn't find any iOS App Development provisioning profiles
    matching 'com.coevo.coevoApp'. (in target 'Runner' from project 'Runner')

The following build commands failed:
    Archiving workspace Runner with scheme Runner
(1 failure)
##[error]Process completed with exit code 65.
```

## 二、为什么可以断定**与代码无关**（三条独立证据）

| # | 证据 |
|---|---|
| 1 | 失败发生在 **`Archive` 的签名阶段**（`Choose a certificate to revoke`），**不是编译阶段** |
| 2 | **同一 run 里 `Build Flutter artifacts` ✓ 通过** ⇒ Dart 编译没问题；本机 `analyze_inproc` 也 **error = 0** |
| 3 | **前 4 次出包（09:54 / 21:13 / 22:40 / 00:20）走的是同一条 workflow、同样的密钥** —— 这条路径本身是通的 |

> 🔑 判据：**「失败在签名/部署阶段」优先怀疑环境与凭据，而不是被测代码** ——
>    否则会去改一个根本没错的文件。

## 三、根因

workflow 用 **`-allowProvisioningUpdates`**（**自动签名管理**）：

```yaml
xcodebuild ... -allowProvisioningUpdates \
  -authenticationKeyPath ~/private_keys/AuthKey_$ASC_KEY_ID.p8 ...
```

⇒ Xcode 会用 App Store Connect API 去**查找/创建**证书与 profile。
当账号的**证书数量达上限**时，它既**不能新建**、又**找不到可用的 profile**
⇒ 上面两条错误**同时出现**（它们是同一个原因的两面）。

⚠️ workflow 里**没有**「清理旧证书」的步骤（`✓ 清理私钥` 只删**本地**的 `~/private_keys/*.p8`，
不碰 Apple 账号里的证书）⇒ 证书是**只增不减**的。

## 四、要白哥做的事（agent 无法代做 —— 需 Apple 账号登录）

### 🔴 方案 A（最快 · 约 5 分钟，出完这次包）

1. 打开 <https://developer.apple.com/account/resources/certificates/list>
2. 看 **Certificates** 里 **iOS Distribution** 证书有几张
3. **Revoke（撤销）多余的** —— ⚠️ **保留最新的一张**
   （撤销**不影响**已上架的版本；但没有可用证书就**无法**再出包）
4. 再看 <https://developer.apple.com/account/resources/profiles/list>，
   删掉 `com.coevo.coevoApp` 相关的**旧/多余** profile
5. 回来说一声，我重跑出包（**改公开 → CI → 下载 → 改回**，全流程我能自动做）

### 🟢 方案 B（一劳永逸 · 建议下一次迭代做）

改用**固定证书 + 手动签名**，彻底摆脱自动管理：

1. 在 Apple 网站**导出 1 份** iOS Distribution 证书（`.p12`，设密码）
2. 下载对应的 `.mobileprovision`
3. 两者存成 GitHub Secrets（`BUILD_CERTIFICATE_BASE64` / `PROVISIONING_PROFILE_BASE64` / `P12_PASSWORD`）
4. workflow 改为：落盘证书 → `security import` → 装 profile →
   `CODE_SIGN_IDENTITY` + `PROVISIONING_PROFILE_SPECIFIER` 指定，
   **去掉** `-allowProvisioningUpdates`
5. ⇒ 不再自动创建证书 ⇒ **不再有上限问题**，且出包更稳

> 📌 代价对比：A 是「每次到上限就手动清一次」；B 是「一次配置，长期不用管」。
>    建议 **A 先解眼前**、**B 排进下次迭代**。

## 五、本轮已做的（agent 侧）

| 动作 | 结果 |
|---|---|
| 改公开前置审计 | ✅ 工作区干净 · HEAD == origin/main · 密钥检查通过 |
| 临时改 public → 触发 run 38110797295 | ✅ |
| **失败后立刻改回 private** | ✅ 复核 `isPrivate: true` |
| 判定「非代码问题」 | ✅ 三条证据（见 §二）|
| 未产出 IPA | ⛔ 本次**无产物**（`Export IPA` 步骤被跳过）|
