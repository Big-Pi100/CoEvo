// CoEvo · App 元信息（版本号等）
//
// 🔴 **版本号出现在两处，必须一致**
// | 位置 | 用途 |
// |---|---|
// | `pubspec.yaml` 的 `version:` | **构建系统用**（iOS `CFBundleShortVersionString` / Android `versionName` 的来源） |
// | 本文件的 [kCoEvoVersion] | **界面显示用**（「关于」页 / 「我的」页副标题） |
//
// ⚠️ **为什么不直接读 pubspec**：那需要 `package_info_plus`（一个新的第三方依赖），
//    而这里只需要一个字符串 → 为它引入依赖不划算。
// 🔑 代价是**两处会漂** → 用
//    `scripts/query_verify/bin/verify_app_version.dart` 做守护断言
//    （解析 pubspec 与本文件，要求一致）。**"注释里提醒"不算防线，脚本才算。**
//
// 口径（本项目既有约定）：**`x.y.z` 是界面唯一可见的版本号**；
// `pubspec` 里 `+` 之后的 `N`（build number）只给构建系统用，**不在界面显示**
// （两段含义不同，混着显示会让用户困惑「为什么有两个版本」）。

/// 界面显示的版本号（= `pubspec.yaml` 的 `version:` 中 `+` **之前**的部分）。
///
/// ⚠️ 改这里必须同步改 `pubspec.yaml`（反之亦然）—— 有脚本守着，漂了会红。
const String kCoEvoVersion = '1.0.0';

/// App 显示名（「关于」页用）。
///
/// 🔴 2026-10-11 白哥定案：**产品名从 `CoEvo` 改为「记忆之书」**。
/// ⚠️ 改这里不够 —— **同一事实有 4 处载体，必须一起改**（本次已全改）：
/// | # | 载体 | 值 |
/// |---|---|---|
/// | 1 | 本常量（「关于」页「应用名称」那行）| `记忆之书` |
/// | 2 | iOS `Info.plist` 的 `CFBundleDisplayName` | `记忆之书` |
/// | 3 | Android `AndroidManifest.xml` 的 `android:label` | `记忆之书` |
/// | 4 | **ASC 里的 App 名称 + 订阅产品本地化名** | ⏳ 白哥在网页改 |
/// 🔑 判据：**改名是一组动作，不是一处字符串** —— 漏一处就会出现
///    「App 叫记忆之书、订阅叫 CoEvo 专业版」这种割裂（Apple 审核也会挑）。
/// 📌 `Bundle ID`（`com.coevo.coevoApp`）与 `Product ID` **不改** —— 它们是技术标识，
///    改了要重建证书/描述文件/IAP 产品，且与显示名无关。
const String kCoEvoName = '记忆之书';
