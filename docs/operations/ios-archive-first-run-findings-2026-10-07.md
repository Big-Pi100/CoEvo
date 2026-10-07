# iOS 归档 workflow 首跑发现与修复（2026-10-07）

> **背景**：白哥首次想在 iPhone 真机上验证（此前**一次都没验证过**），
> 触发 `iOS Archive & Upload`（`method=ad-hoc`）。
> **产物**：本文 + 3 处修复（其中 1 处是本轮新增的 `Podfile`）。

---

## 一、首跑结果：第 5 步 `Install CocoaPods` 失败

```
✅ 发现 Podfile ⇒ pod install
Adding spec repo `trunk` with CDN `https://cdn.cocoapods.org/`
Analyzing dependencies
[!] CocoaPods could not find compatible versions for pod "url_launcher_ios":
[!] Automatically assigning platform `iOS` with version `12.0` on target `Runner`
    because no platform was specified. Please specify a platform for this target
    in your Podfile.
In Podfile:
url_launcher_ios (from `.symlinks/plugins/url_launcher_ios/ios`)
Specs satisfying the `url_launcher_ios ...` dependency were found, but they
required a higher minimum deployment target.
```

---

## 二、根因

**主工程 iOS 部署目标 = 12.0，而插件要求更高。**

**全量扫描**（按 `pubspec.lock` 锁定的版本，逐个读其 `podspec` —— **不是只查报错的那一个**）：

| 插件（lock 版本） | iOS 要求 |
|---|---|
| `url_launcher_ios` 6.4.1 | **13.0** ← 报错的那个 |
| `in_app_purchase_storekit` 0.4.13 | **13.0** |
| `file_selector_ios` 0.5.3+6 | **13.0** |
| `audioplayers_darwin` 6.4.0 | **13.0** |
| `sqflite_darwin` 2.4.1+1 · `shared_preferences_foundation` 2.5.4 · `share_plus` 10.1.4 · `record_ios` 1.2.1 · `path_provider_foundation` 2.4.1 · `image_picker_ios` 0.8.13 | 12.0 |
| `flutter_secure_storage` 9.2.4 | 9.0 |

⇒ **最高要求 = 13.0**。

🔑 **为什么必须「全量」而不是只查报错的那个** ——
`pod install` 一次只报**第一个**冲突，修完它下一轮会报第二个。
每轮都是一次完整的 macOS 构建（约 15 分钟）。
⇒ 判据：**这类「逐个报错」的校验，必须一次取全集的最大值**，否则等于把一次排查拆成 N 次 CI。

### 为什么是「现在」才暴露

`flutter pub get` 会在 CI 上**自动生成** `Podfile`（本仓库此前没有这个文件）。
而生成出来的 `platform` 行是**注释状态**：

```ruby
# Uncomment this line to define a global platform for your project
# platform :ios, '13.0'
```

⇒ CocoaPods 转而读 `project.pbxproj` 的 `IPHONEOS_DEPLOYMENT_TARGET`（= 12.0）⇒ 与插件冲突。

⚠️ **注意最后那行注释里的默认值 `'13.0'`** ——
Flutter 3.41.1 自己的模板就认为 13.0 是标准值。
⇒ **12.0 是本项目 `ios/` 目录的历史遗留**（该目录生成于更早的 Flutter 版本，`ls` 显示为 2025-05-07）。

---

## 三、修法：三处保持一致

| 文件 | 改动 |
|---|---|
| `app/ios/Podfile` | **新增**（此前不在版本控制里）；显式 `platform :ios, '13.0'` |
| `app/ios/Runner.xcodeproj/project.pbxproj` | `IPHONEOS_DEPLOYMENT_TARGET` 12.0 → 13.0（**恰 3 处**）|
| `app/ios/Flutter/AppFrameworkInfo.plist` | `MinimumOSVersion` 12.0 → 13.0 |

### 为什么三处都要改

📌 **判据：同一件事的口径只能一处权威** ——
这里却天然有三处「权威」：CocoaPods 读 `Podfile`、Xcode 读 `pbxproj`、
Flutter 读 `AppFrameworkInfo.plist`。三处不一致时**报错信息会互相矛盾**，
排查成本远高于一次性对齐。

### 为什么把 Podfile 提交进 git

Flutter 官方的 `ios/.gitignore` **只忽略 `Pods/`，不忽略 `Podfile`** ⇒ 它本该在版本控制里。
不提交就只能靠「隐式推导」，**插件升级时不受控**（正是本次事故的成因）。
本仓库 `app/ios/.gitignore` 与根 `.gitignore` 都**没有** Podfile 规则 ⇒ 可正常提交。

### Podfile 的写法安全性

**不自己臆造结构** —— 直接取 `Flutter 3.41.1` 的官方模板
（`packages/flutter_tools/templates/cocoapods/Podfile-ios`），
只把 `platform` 行从注释改为生效。已逐字比对验证（见下）。

---

## 四、验证

| 项 | 结果 |
|---|---|
| `pbxproj` 三处 | ✅ 全部 `13.0`；`git diff --numstat` = **3 insertions / 3 deletions**（只改数字，结构未动）|
| `AppFrameworkInfo.plist` | ✅ `plistlib` 解析通过，`MinimumOSVersion = 13.0` |
| `Podfile` vs 官方模板 | ✅ 主体 **39 行逐字一致**；唯一差异是 `platform` 由注释变生效 |
| `Podfile` 行尾/编码 | ✅ LF / UTF-8（仓库 pin 了 LF）|
| 本机 Flutter 版本 | ✅ **3.41.1**，与 `ci.yml` 钉的版本一致 ⇒ 读到的模板就是 CI 上会生成的那个 |
| **部署目标覆盖面** | ✅ 扫描 `pubspec.lock` 里**全部** iOS 依赖的 `podspec` ⇒ 最高要求 **13.0**，与当前设置一致 |

⚠️ **本机无法跑 `pod install`**（需要 macOS + CocoaPods）⇒ 最终仍需 CI 复核。

---

## 五、连带风险（供后续观察）

### 5.1 `ci.yml` 的 `ios-build` 是**同源**问题

它跑 `flutter build ios --release --no-codesign`，同样会触发 pod install ⇒ **修前也会失败**。

⚠️ 但 `ios-build` 的 `if` 含 `workflow_dispatch` ⇒ **`push main` 时它一直是 `skipped`**。
⇒ 文档/记忆里那句「`ci.yml` 的 `ios-build` 已验证可过」**缺乏近期证据** ——
很可能是**插件升级之前**的旧结论（当时 `url_launcher_ios` 的要求还是 12.0）。

📌 **本条已收录进判据库**：「该 workflow 从未跑过」⇒ 里面大概率有必然失败点。

### 5.2 插件升级会推高部署目标要求

本次是 `url_launcher_ios` **6.4.1** 把要求从 12.0 提到 13.0（连同 `audioplayers_darwin` 等）。

📌 **判据**：`pod install` 报「compatible versions not found / higher minimum deployment target」时，
**先查各插件的 `podspec` 实际要求**（`grep -E "s\.platform|deployment_target" .../*.podspec`），
**不要先怀疑 Podfile 语法** —— 这类错误信息很容易被误读成「Podfile 写错了」。

---

## 六、同批次附带修复（首跑前的静态检查发现）

| 提交 | 问题 | 修法 |
|---|---|---|
| `4e4e510` | `pod install` 在无 Podfile 时必然失败（`[!] No Podfile found in the project directory.`）| 改成「有则跑、无则跳过」|
| `33fe3fc` | `.p8` 落盘用 `printf '%s'` —— 缺末尾换行时 PEM 无效，且报错信息**不会指向换行** | 改 `printf '%s\n'`（两种情况都可用，幂等）|
| `00ab65d` | 原配置只有 `app-store` 导出（**装不了真机**）| 新增 `method` input（app-store / **ad-hoc** / development）|

⚠️ 注：`4e4e510` 的容错**实际没有生效**（`flutter pub get` 会生成 Podfile ⇒ 走了「有」分支），
但它仍有价值（将来 Podfile 真缺失时不至于硬失败）。

---

## 七、第二轮：`Export IPA` 失败 → **API Key 角色必须是 `Admin`**

第一轮的部署目标修复**生效了** —— `pod install` ✅ / `Build Flutter artifacts` ✅ / `Archive` ✅
全部通过，卡在**最后一步** `Export IPA`：

```
[MT] IDEDistribution: Command line name "ad-hoc" is deprecated. Use "release-testing" instead.
error: exportArchive Cloud signing permission error
error: exportArchive No signing certificate "iOS Distribution" found
error: exportArchive No profiles for 'com.coevo.coevoApp' were found
** EXPORT FAILED **
```

### 7.1 根因

**App Store Connect API Key 的角色必须是 `Admin`** —— cloud signing 的硬性要求。

Apple 官方论坛里的**原始错误详情**（与本项目完全一致）：

> `Error Domain=DeveloperAPIServiceErrorDomain Code=5 "Cloud signing permission error"`
> `NSLocalizedRecoverySuggestion=You haven't been given access to cloud-managed
> distribution certificates. Please contact your team's Account Holder or an Admin to give you access.`

多个实测帖的一致结论：

> 「传给 xcodebuild 的 API Key 是**有角色权限的，创建时就定死了**。坑在：
> **Developer 或 App Manager 角色的 Key，身份认证能通过、上传也能用，
> 唯独云签名这一步会死**，只甩一句语焉不详的 `Cloud signing permission error`。
> 按实测，**云签名要求 Key 必须是 Admin 角色**。**角色创建时固定、后续改不了**
> ⇒ 唯一办法是重新生成一个。」

🔑 **现象特征（很有辨识度）**：**`Archive` 成功、只有 `Export IPA` 失败** ——
- `archive` 走 **Development** 证书 ⇒ cloud signing 够用（它会创建
  `Apple Development: Created via API (TEAM ID)`）
- `exportArchive` 需要 **Distribution** 证书 ⇒ cloud signing 被拒

⇒ 之前把角色写成「App Manager 以上」**是错的**，已在 workflow 顶部更正为 **Admin**。

### 7.2 修法

1. ASC → Users and Access → Integrations → **App Store Connect API** → **Team Keys** → `+`
2. 角色选 **`Admin`**（⚠️ 角色**创建时固定、之后不可改** ⇒ 只能新建）
3. 下载 `.p8`（**只有一次下载机会**）
4. 更新 GitHub Secrets：
   - `ASC_KEY_ID` ← 新 Key 的 ID
   - `ASC_KEY_P8` ← 新 `.p8` 全文
   - `ASC_ISSUER_ID` **不用改**（它是**账号级**的，所有 Key 共用）
5. 重跑

⚠️ **Admin 角色的 `.p8` 是整套流程里唯一的真机密** ——
`issuer id` / `key id` / `team id` 都不是机密，`.p8` 和 `.p12` 才是。

### 7.3 连带隐患：证书会堆积

论坛实测：同一个 API Key 在 CI 上**第二次**跑 archive 时会报

> `Revoke certificate: Your account already has an Apple Development signing certificate
> for this machine, but its private key is not installed in your keychain.`

因为**每次 CI 都是全新 runner** ⇒ 每次都创建一个新证书 ⇒ 而 Development 证书有**数量上限**。

⇒ **对策**：定期去 `developer.apple.com` → Certificates 里清理**找不到对应私钥**的孤儿证书
（名字形如 `Apple Development: Created via API (TEAM ID)`）。
若将来频繁出包，应改为「**预先创建证书 → 导出 `.p12` → 存 secrets → CI 导入**」的固定凭据模式
（那样就不再有创建/堆积）。

### 7.4 顺带记录：`ad-hoc` 已废弃

Xcode 26 起，export method 的命名改了（本项目用的 `ad-hoc` 仍可用，只是 deprecated）：

| 旧名 | 新名（Xcode 26+） |
|---|---|
| `ad-hoc` | `release-testing` |
| `app-store` | `app-store-connect` |
| `development` | `debugging` |

⏳ 暂不改（现在能用），等实际不支持时再切。

---

## 八、✅ 出包成功（第三轮）+ 真机安装

第三次跑**全绿**，并且**复核了产物**（不是只看 job 颜色 —— 见 §8.4 的假绿口子）：

```
job: Archive & Export IPA → success
  ✅ Export IPA（upload 时同时上传 ASC）
  ✅ Upload IPA as artifact
📦 artifact: coevo-ios-ipa  31.8 MB  (expired=False)
```

### 8.1 完整修复链（三轮）

| 轮次 | 失败点 | 根因 | 修法 |
|---|---|---|---|
| 1 | `Install CocoaPods` | 部署目标 12.0 < 插件要求 13.0 | `Podfile` + `pbxproj` + `AppFrameworkInfo` **三处对齐** |
| 2 | `Export IPA` | API Key 角色是 App Manager，而 cloud signing 要 **Admin** | 新建 Admin Key，换 `ASC_KEY_ID` / `ASC_KEY_P8` |
| 3 | — | — | ✅ **通过** |

### 8.2 下载 IPA

GitHub → **Actions** → 该 run → 页面**最底部** **Artifacts** → `coevo-ios-ipa` → 下载 zip → 解压得 `.ipa`

### 8.3 真机安装（Windows · **iOS 16+ 必读**）

1. 用 **爱思助手**（i4Tools）连上 iPhone → 「应用游戏」→ 导入安装 → 选那个 `.ipa`
2. 🔴 **装完先点开一次 App** —— iOS 16+ 会提示「需要启用开发者模式」
3. **设置 → 隐私与安全性** → 拉到底 → **开发者模式** → 打开 → **重启设备**
4. 重启后确认（输设备密码）→ 再打开 App

⚠️ **「开发者模式」这个入口默认可能不显示** —— 它**只在设备上装过「需要开发者模式的应用」之后才出现**。
⇒ 所以**必须先装一次 ad-hoc 包**，入口才会冒出来。（来源：蒲公英《iOS 安装失败原因排查》）

🔑 注意适用范围：**只有 `ad-hoc` / `development` 分发的包需要开发者模式**；
**TestFlight 和 App Store 分发的包不需要**。

### 8.4 顺带堵掉一个「假绿」口子（提交 `66ddced`）

本次虽然真成功了，但复核时发现 workflow 的**产物校验形同虚设**：

| 原实现 | 问题 |
|---|---|
| 「列出产物」= `ls -la ... \|\| true` | **永远成功**，不构成校验 |
| `upload-artifact` 的 `if-no-files-found: warn` | **一个文件都没有也判成功** |

⇒ 典型假绿：**job 全绿、却没有包可下载**（而 `exportArchive` 返回 0 并不代表真产出了 `.ipa`）。

**改法**：`列出产物` → **`校验 IPA 产物（缺失即失败）`**（断言「存在 + 大于 1 MB」）；
`if-no-files-found`: `warn` → **`error`**。

📌 **判据：校验要断言「产物」，不是断言「命令退出码」。**

---

## 九、下一步

- ⚠️ **证书堆积**：CI 每次都是全新 runner ⇒ 每次 archive 创建一个
  `Apple Development: Created via API` 证书 ⇒ 撞账号上限时会报 revoke 错误。
  定期去 Certificates 清理**找不到对应私钥**的那些。
- ⏳ `ad-hoc` 已 deprecated（Xcode 26 起叫 `release-testing`）—— 暂不改，等不支持时再切。
