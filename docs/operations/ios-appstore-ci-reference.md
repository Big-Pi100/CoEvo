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
| 4 | **Flutter 版本固定 `3.27.x`** | 与 `app/` 的 `sdk: ">=3.6.0 <4.0.0"` 匹配，但当前本地已用 **3.41.1** → 需重新评估 |
| 5 | **`--dart-define=API_HOST=keyievolution.fun`** | 这是旧项目的注入方式，`app/` 需确认是否沿用 |
| 6 | **`uploadBitcode: false` + `compileBitcode: true`** | Bitcode 自 Xcode 14 起已废弃 → 这两项**可以删除** |

---

## 三、修正后的参考流程（占位，待 Phase 0 完成后启用）

> **启用前提**（Phase 0）：Apple Developer 账号办好 · Bundle ID 确定 · Team ID 拿到 ·
> App Store Connect API Key（`.p8` + Key ID + Issuer ID）配进 GitHub Secrets

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
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          # 🔴 版本待定：原为 3.27.x，本地已用 3.41.1
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

## 五、为什么现在不建这个 workflow

1. **Phase 0 未完成** —— Apple Developer 账号还没办，Team ID / Bundle ID / API Key 都不存在
2. **配了也跑不了** —— 缺 secrets，每次触发都失败
3. **macOS runner 贵** —— 私有仓库按 **10x** 计费（2,000 分钟/月 → 实际 200 macOS 分钟）
4. **已有替代** —— `.github/workflows/ci.yml` 的 `ios-build` job 已能验证「iOS 能编过」（`--no-codesign`，手动触发）

**→ 待 Phase 0 完成、要真正上架时，再按 §3.2 建这份 workflow。**

---

*本文档为从已删除的 `app_user` 抢救的参考实现，非现行配置。全文经修正标注（原配置有 6 处会直接失败）。*
