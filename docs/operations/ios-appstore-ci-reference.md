# iOS 归档与 App Store 上传 · CI 参考（从 `app_user` 抢救）

> **来源**：`app_user/.github/workflows/build.yml`（216 行）+ `app_user/.github/export-options.plist`
> **抢救时间**：2026-09-26 —— `app_user` 旧项目被删除，但这份 **iOS 归档 → 导出 IPA → 上传 App Store** 的完整流程是
> 全项目**唯一**的参考实现，故在此保留。
>
> ⚠️ **它从未运行过**：原文件放在 `app_user/.github/workflows/`（子目录），
> **GitHub Actions 只读仓库根的 `.github/workflows/`** → 从未执行。

---

## 一、为什么保留

排查发现：全项目**只有这一份**配置覆盖了 iOS 上架的完整链路：

```
pod install → flutter build ios → xcodebuild archive → xcodebuild -exportArchive → 上传
```

而当前 `app/` 项目里：
- `.github/workflows/ci.yml` 有 `ios-build` job，但**只做 `flutter build ios --no-codesign`**（验证能编过）
- **归档 / 签名 / 导出 IPA / 上传** 这几步**没有任何实现** —— 而它们正是上架必需的

---

## 二、🔴 已知问题（照抄会失败）

| # | 问题 | 说明 |
|---|---|---|
| 1 | **`xcrun altool --upload-app` 已被 Apple 弃用** | 2023-11 起停用，2024 年后完全不可用 → **必须改用 App Store Connect API**（`xcrun altool` 的替代是 `xcodebuild -exportArchive` + `altool` 已删，推荐 **fastlane** / **`xcrun notarytool`（那是 macOS）** / **App Store Connect API key + `xcrun altool` 的继任者**） |
| 2 | **`teamID: YOUR_TEAM_ID` 是占位符** | `export-options.plist` 里未填真实值 |
| 3 | **依赖 `match`（fastlane）的 provisioning profile 命名** | 原配置写 `PROVISIONING_PROFILE_SPECIFIER="match AppStore ${{ secrets.APPLE_APP_ID }}"` —— 这要求已用 fastlane match 管理证书；**若不用 match，要改成手动证书或 App Store Connect API 自动签名** |
| 4 | ~~**Flutter 版本固定 `3.27.x`**~~ ✅ **已定案：3.41.1** | 2026-10-01 白哥定 —— 与项目 SDK（`D:\flutter` = 3.41.1 stable / Dart 3.11.0）**一致**。兼容性已核验：`pubspec.lock` 综合约束为 `dart >=3.10.0` + `flutter >=3.38.0` → 满足。CI 已同步钉死（`.github/workflows/ci.yml` 两处）。 |
| 5 | **`--dart-define=API_HOST=keyievolution.fun`** | 这是旧项目的注入方式，`app/` 需确认是否沿用 |
| 6 | **`uploadBitcode: false` + `compileBitcode: true`** | Bitcode 自 Xcode 14 起已废弃 → 这两项**可以删除** |

---

## 三、修正后的参考流程（🆕 2026-10-04 **已实施**）

> **启用前提**（Phase 0）：Apple Developer 账号办好 · Bundle ID 确定 · Team ID 拿到 ·
> App Store Connect API Key（`.p8` + Key ID + Issuer ID）配进 GitHub Secrets
>
> 🆕 **2026-10-04：已按本节建成 `.github/workflows/ios-archive.yml`**（白哥确认）。
> ⚠️ 实施时发现本节参考实现有 **5 处会失败或静默出错**，实际实现已修正 ——
> 逐条见 §3.2 的表格。**以 `.github/workflows/ios-archive.yml` 为准**，本节文字作依据留档。

### 3.1 `app/.github/export-options.plist`（已随本文档创建）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>   <!-- 原写法 app-store 已被取代 -->
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>        <!-- 🔴 待填 -->
    <key>uploadSymbols</key>
    <true/>
    <!-- uploadBitcode / compileBitcode 已随 Xcode 14 废弃，删除 -->
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
```

### 3.2 归档 + 导出 + 上传（修正版）

> ## 🔴 实施时修正的 5 处（2026-10-04）
>
> 下面的参考实现**不能照抄** —— 实测发现 5 处问题。实际实现见
> `.github/workflows/ios-archive.yml`（**以它为准**）。
>
> | # | 参考实现 | 问题 | 实际实现 |
> |---|---|---|---|
> | 1 | `flutter build ios --release`（**带签名**） | `DEVELOPMENT_TEAM` 在 `ios/Runner.xcodeproj` 里**根本不存在**（实测 `grep` 0 命中）⇒ 必然在「Select a Development Team」处失败 | 改为 `--no-codesign`（本步只生成 Flutter 产物），签名交给 xcodebuild |
> | 2 | `xcodebuild archive` **无** `DEVELOPMENT_TEAM` | 自动签名拿不到团队 ⇒ 会**交互式询问**（CI 无终端 ⇒ 卡死/失败）。<br>📌 `flutter build ipa` **不暴露** Team ID 参数（实测读 `flutter_tools` 源码：`BuildIOSArchiveCommand` 只有 `--export-method` / `--export-options-plist`）| xcodebuild 命令行加 `DEVELOPMENT_TEAM=...`（标准 build setting 覆盖，**不需改 pbxproj**）|
> | 3 | 无 `--dart-define` | 产物连 `localhost`（`api_config.dart` 默认值）⇒ 真机全网络失败 | 补 `API_HOST` + `PUBLIC_BASE_URL` |
> | 4 | plist 的 `teamID` 是 `YOUR_TEAM_ID` 占位，**没人替换** | exportArchive 会失败或导出不可用包 | 用 `/usr/libexec/PlistBuddy` 注入（**不用 sed** —— 见 §3.1 plist 注释里的理由）|
> | 5 | 🔴 plist 写 `destination: export`，注释却说「destination=upload 时会直接上传」 | **静默陷阱**：勾了「上传」也**不会真上传**，而日志看起来一切正常 | 按 `workflow_dispatch` 的 input **动态切** `:destination` |
>
> 🔑 第 5 条是最值得记的一类：**「配置与意图矛盾」不会报错，只会静静地不做那件事**。

```yaml
# 放在仓库根的 .github/workflows/ 下才会执行（不要在子目录）
# ⚠️ 仅 workflow_dispatch（手动）触发 —— macOS runner 私有仓库按 10x 计费
name: iOS App Store Release

on:
  workflow_dispatch:
    inputs:
      upload:
        description: '上传到 App Store Connect'
        type: boolean
        default: false

jobs:
  archive:
    name: Archive & Upload
    runs-on: macos-latest
    defaults:
      run:
        working-directory: app          # 🔴 注意是 app，不是 app_user
    steps:
      - uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2.23.0   # 🔴 必须钉具体版本，见 §六.7
        with:
          channel: stable
          # ✅ 固定 3.41.1（2026-10-01 定）—— 与项目 SDK 一致；
          #    理由与兼容性核验见本文件 §二 第 4 条
          flutter-version: 3.41.1
          cache: true

      - name: Install dependencies
        run: flutter pub get

      - name: Install CocoaPods
        run: pod install --repo-update
        working-directory: app/ios

      # 用 App Store Connect API Key 自动签名（替代已弃用的手动证书/match）
      - name: Configure signing
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
        run: |
          mkdir -p ~/private_keys
          echo "$ASC_KEY_P8" > ~/private_keys/AuthKey_$ASC_KEY_ID.p8
          xcodebuild -workspace ios/Runner.xcworkspace \
            -scheme Runner \
            -resolvePackageDependencies \
            -authenticationKeyPath ~/private_keys/AuthKey_$ASC_KEY_ID.p8 \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" || true

      - name: Build & Archive
        run: |
          flutter build ios --release
          xcodebuild -workspace ios/Runner.xcworkspace \
            -scheme Runner \
            -configuration Release \
            -archivePath build/ios/archive/Runner.xcarchive \
            -sdk iphoneos \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID "${{ secrets.ASC_KEY_ID }}" \
            -authenticationKeyIssuerID "${{ secrets.ASC_ISSUER_ID }}" \
            archive

      # destination=upload 时，exportArchive 会直接上传到 App Store Connect
      - name: Export & Upload
        if: ${{ inputs.upload }}
        run: |
          xcodebuild -exportArchive \
            -archivePath build/ios/archive/Runner.xcarchive \
            -exportPath build/ios/ipa \
            -exportOptionsPlist .github/export-options.plist \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID "${{ secrets.ASC_KEY_ID }}" \
            -authenticationKeyIssuerID "${{ secrets.ASC_ISSUER_ID }}"

      - name: Export IPA only（不上传时）
        if: ${{ !inputs.upload }}
        run: |
          xcodebuild -exportArchive \
            -archivePath build/ios/archive/Runner.xcarchive \
            -exportPath build/ios/ipa \
            -exportOptionsPlist .github/export-options.plist \
            -allowProvisioningUpdates

      - name: Upload IPA as artifact
        uses: actions/upload-artifact@v4
        with:
          name: coevo-ios-ipa
          path: app/build/ios/ipa/Runner.ipa
          if-no-files-found: warn
```

---

## 四、🔑 三个关键差异（相对原配置）

| 项 | 原配置（app_user） | 修正版 |
|---|---|---|
| **上传方式** | `xcrun altool --upload-app -u -p`（**邮箱 + 密码，已弃用**） | **App Store Connect API Key**（`.p8`），或 `-exportOptionsPlist` 里 `destination: upload` |
| **签名方式** | `CODE_SIGN_IDENTITY` + `PROVISIONING_PROFILE_SPECIFIER="match AppStore …"`（依赖 fastlane match） | **自动签名**（`-allowProvisioningUpdates` + API Key）→ 无证书管理负担 |
| **Bitcode** | `uploadBitcode` / `compileBitcode` | **已删除**（Xcode 14 起废弃） |

---

## 五、⏱ 为什么**当时**没建（🆕 2026-10-04 已建）

> 🆕 **2026-10-04：白哥确认「建」** ⇒ 已建成 `.github/workflows/ios-archive.yml`。
> 下面四条是**当时的判断依据**（保留作决策史 —— 不是错的，只是条件变了）。

| # | 当时理由 |
|---|---|
| 1 | **Phase 0 未完成** —— Apple Developer 账号还没办，Team ID / API Key 都不存在 |
| 2 | **配了也跑不了** —— 缺 secrets，每次触发都失败 |
| 3 | **macOS runner 贵** —— 私有仓库按 **10x** 计费（2,000 分钟/月 → 实际 200 macOS 分钟）|
| 4 | **已有替代** —— `ci.yml` 的 `ios-build` job 已能验证「iOS 能编过」（`--no-codesign`，手动触发）|

### 5.1 为什么"条件变了"就可以建

| 变化 | 说明 |
|---|---|
| ✅ workflow **不占额度** | 只在 `workflow_dispatch` 下跑 ⇒ **不触发就不花钱**（理由 3 被规避）|
| ✅ **不阻塞现在** | 缺 secrets 时它只在**有人手动点**的情况下失败 ⇒ 不影响 `push main` 的 CI（理由 2 被规避）|
| ✅ **省掉将来的来回** | 账号一批下来就能直接跑，不必再等一轮「写 → 审 → 改」 |
| ⚠️ 理由 1 **仍然成立** | 所以它建好了也**暂时跑不了** —— 这是预期，不是缺陷 |

⚠️ **它现在无法通过**（缺 4 个 Secrets）。要它真能跑，先完成：
`owner-action-checklist` 里的 ASC 建产品 + 生成 API Key + 配 Secrets。

---

## 六、🆕 「我要在 iOS 上测」——现在能做什么（2026-10-04 补）

> 触发：白哥问「`ios-build` 命令是什么，我一直在安卓上测试」
> 📌 本节回答的是**使用方式**，不涉及代码改动。

### 6.1 那条命令是什么

`ci.yml` 的 `ios-build` job（`runs-on: macos-latest`）：

```bash
flutter pub get
flutter build ios --release --no-codesign
```

对比白哥的安卓命令：

```bash
# 安卓（白哥在用 · 本机 Windows 可跑）
D:\flutter\bin\flutter.bat build apk --release \
    --target-platform android-arm64 \
    --dart-define=API_HOST=api.keyievolution.fun

# iOS（本机 Windows **跑不了** —— 需要 Xcode/macOS）
flutter build ios --release --no-codesign
```

### 6.2 🔴 它跑在哪 —— 以及为什么**不需要买 Mac**

| | 安卓 | iOS |
|---|---|---|
| 构建机 | 你的 Windows（`D:\flutter`）✅ | 🔴 **必须 macOS**（Xcode） |
| 项目方案 | 本机直接构建 | ✅ **GitHub Actions `macos-latest`**（已规划，见 `qualification-startup` §一）|

**⇒ iOS 不需要本地 Mac**，靠 CI 的 macOS runner。

### 6.3 🔴 两个必须先知道的陷阱

**陷阱 ①：`ios-build` 平时**不跑** —— 「CI 绿」里没有它**

```yaml
if: ${{ github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/v') }}
```

⇒ push `main` 时它**被跳过**（不是失败，是没运行）。
要让它跑，二选一：
- GitHub → Actions → 选 `CI` → **Run workflow**（手动，`workflow_dispatch`）
- push 一个 `v*` tag（⚠️ 会**连带触发部署** job，别随便推）

**陷阱 ②：🔴 CI 的命令**没有**传 `--dart-define=API_HOST`**

实测 `grep 'API_HOST\|dart-define' .github/workflows/ci.yml` ⇒ **0 命中**。

而 `api_config.dart` 的默认值是：

```dart
static const String _host = String.fromEnvironment('API_HOST', defaultValue: 'localhost');
```

⇒ 若直接用 CI 的 iOS 产物去测，**它连的是 `localhost`（必然连不上）**。

| 当前危害 | 说明 |
|---|---|
| 🟢 **现在无害** | `ios-build` 只做「能否编过」的就绪度探测，**产物不用于测试**（且 `--no-codesign` 的 `.app` 也装不进真机） |
| 🔴 **建真机测试/上架流程时必须补** | 否则打出来的包连不上后端，会误判成「App 坏了」 |

📌 判据：**「构建成功」≠「包可用」** —— 编译期注入的参数（`--dart-define`）缺失**不会报错**，
只会在运行时表现为「网络请求全失败」。

### 6.4 命令的两个层次（白哥最需要区分的一点）

| 命令 | 产物 | 能装真机？ | 前置 |
|---|---|---|---|
| `flutter build ios --release --no-codesign` | `.app`（**未签名**） | ❌ **不能** | 无（纯编译验证）|
| `xcodebuild archive` + `-exportArchive` | `.ipa`（**已签名**） | ✅ 能（含 TestFlight）| 🔴 **Team ID + ASC API Key** |

**⇒ 你的目标（真机测试）需要第二层，而它卡在 Phase 0。**

### 6.5 完整路径（🔑 全程不需要 Mac）

```
Windows 开发机（写代码）
      │  git push
      ▼
GitHub Actions · macos-latest
      │  ① flutter build ios --no-codesign     ← ✅ 现在就能跑（只验编译）
      │  ② xcodebuild archive + exportArchive  ← ⏳ 需 Team ID + API Key
      ▼
App Store Connect → TestFlight
      │
      ▼
iPhone 装 TestFlight → 真机测试（含 IAP！）
```

### 6.6 当前状态与下一步

| 项 | 状态 |
|---|---|
| ① iOS **能否编过** | ✅ 现在就能验 —— 手动触发 `ios-build` 即可 |
| ② iOS **真机测试** | ⏳ 需 Team ID + ASC API Key（你账号审批完成后）|
| ③ 「archive + TestFlight」workflow | ⏳ **未建**（§五 说明了当时不建的四条理由）|

⚠️ **一处如实交代**：`ios-build` 的注释写着「现在**必然失败**（缺 Development Team /
Provisioning Profile）」，且据此设了 `continue-on-error: true`。
但 —— **那是预期，不是实测**，且 `--no-codesign` 理论上**不要求** Team ID。
⇒ **建议手动触发一次看真实结果**；若它其实能过，那条注释与 `continue-on-error` 都该更新。

### 6.7 🔴 实测事故：缓存解压 `spawn EIO`（2026-10-04 第一次手动触发）

> 白哥手动触发 `ios-build` 后遇到的真实故障。**已修**（`ci.yml` / `ios-archive.yml`）。

#### 现象

```
Cache hit for: flutter-macos-stable-3.41.1-arm64-...
gtar -xf .../cache.tzst --use-compress-program unzstd
Error: spawn EIO
    at ToolRunner (actions/cache/v5/dist/restore/index.js:5069)
Node.js v24.19.0
```

缓存**下载完成**（2.0 GB @ 200 MB/s），崩在**解压**这一步。

#### 根因：**上游静默换了实现，我们一行没改**

| 事实 | 来源 |
|---|---|
| `subosito/flutter-action` **现在内部用 `actions/cache@v5`** | 该 action 官方 README |
| `actions/cache@v5` = 迁到 **Node.js 24** + ESM 重写 | actions/cache 官方 README |
| **v2.22.0**（2026-03-17）的 PR #385 引入 v5 | 该仓库 release 记录（实测）|
| 我们写的是**浮动标签** `@v2` ⇒ 被静默升级 | `ci.yml` |

⇒ 日志里的 `Node.js v24.19.0` 正是 v5 的运行时特征。

📌 **判据：「钉版本」要钉到整条链**（SDK + action + 工具）。
项目早已钉了 `flutter-version: 3.41.1`，却漏了 **action 自己的版本**。

#### 🔴 比 EIO 更严重的问题：它制造了一个「假绿」

```
Setup Flutter 崩  ⇒  pub get / build ios 被【跳过】
                 ⇒  job 级 continue-on-error 让它仍显示【绿】
                 ⇒  你以为 iOS 编过了，其实一步都没跑
```

📌 **判据：「优化类步骤」失败会掩盖「真正的验证」** ——
「**没能执行**」在面板上与「**通过**」难以区分。
⇒ 关键验证步骤**不得排在「可能失败的非关键步骤」之后**；
且容错**必须精确到步骤，不能罩住整个 job**。

#### 修法（三处）

| # | 改动 | 理由 |
|---|---|---|
| 1 | macOS 两个 job 加 **`cache: false`** | 直接绕开出错的 `actions/cache@v5`。<br>⚠️ **不回退到 v2.21.0**（最后一个未用 v5 的版本）—— 那要押一个我**无法验证**的前提（旧版内部 `actions/cache@v4` 是否仍被 GitHub cache 服务支持）。<br>🔑 对**手动触发**的 job，**重下 SDK 的代价远小于押错版本的代价**。 |
| 2 | 三处 `@v2` → **`@v2.23.0`** | 防将来的静默漂移。✅ **零行为变化** —— `@v2` 当前解析到的就是 v2.23.0。 |
| 3 | `continue-on-error` **从 job 级移到 `Build iOS` 步骤级** | ⇒ `Setup`/`pub get` 失败会**真红**；`Build iOS` 失败仍标黄不刷红灯。 |

⚠️ **`frontend` job（ubuntu）的 `cache: true` 刻意**不动**：
· 报错发生在 macOS 的 `/opt/homebrew/bin/gtar`
· 它一直绿 —— 无证据表明 ubuntu 受影响
· 且它**每次 push 都跑** ⇒ 关缓存代价高得多
📌 判据：**按证据分区处理，不搞一刀切** —— 只改已出现问题的环境。

#### ⏳ 下次要做的判断

`--no-codesign` **理论上不需要** Team ID ⇒
**若 `Build iOS` 这一步绿了**，说明 `ci.yml` 那条「必然失败」注释是**错的**：
应删掉该步骤的 `continue-on-error`，让它变回严格门禁。

---

*本文档为从已删除的 `app_user` 抢救的参考实现，非现行配置。全文经修正标注（原配置有 6 处会直接失败）。*
