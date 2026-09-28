# `word.db` 查询「不可用」—— 三个独立成因（含我的一个真 bug）

> 日期：2026-09-27 15:55
> 触发：白哥反馈「弹窗显示**词库正在整备**」
> 状态：✅ **已实施「修 B + C」**（白哥 15:58 批准）—— 见 §七 执行记录
> 相关：`step3-reader-plan-2026-09-27.md` §十一（3.4b 落盘与浮层）

---

## 一、结论（先说结果）

白哥看到的这一句，**不是单一原因**，而是**三个独立成因叠加** ——
而且其中**一个是我的真 bug（B）**，**它被平台限制（A）掩盖了**：

| # | 成因 | 性质 | 影响范围 |
|---|---|---|---|
| **A** | **web 上永久不可用**（三项依赖都没有 web 实现） | ⚠️ 平台限制（**非 bug**） | 仅 web（开发预览） |
| **B** | 🔴 **provider 从未预热** —— 全项目只有 `ref.read`，**没有任何 `ref.watch`** | 🔴 **我的 bug** | **真机也会「第一次查词必失败」** |
| **C** | 「正在准备」把 A 与 B **表达成同一句** | 文案缺陷 | 两者都会误导 |

🔑 **为什么我之前在 web 上测时没发现 B** —— 因为 web 上 provider **本来就必然失败**（A），
`service` 恒为 `null`，于是 B 的症状（「第一次点词拿不到」）被 A 完全遮蔽。
**这正是「在错误的平台上验证」的又一类形态：错误平台的错误，会掩盖真平台的错误。**

---

## 二、逐项证据

### A. web 上永久不可用 —— 三个依赖全缺（实测插件声明）

| 依赖 | 声明的平台 | web？ |
|---|---|---|
| `sqflite 2.4.1` | `android` · `ios` · `macos` | 🔴 **无** |
| `path_provider 2.1.5` | `android` · `ios` · `linux` · `macos` · `windows` | 🔴 **无** |
| `dart:io`（`File`） | — | 🔴 web 上是 **stub**（调用即抛） |

> 证据（pub 缓存里的 `pubspec.yaml` → `flutter: plugin: platforms:`），非推测。

**推论**：web 上 `getApplicationSupportDirectory()` →
`MissingPluginException`；即便通过，`sqflite.databaseFactory` 也无实现；
且 `File(targetPath).existsSync()` 会抛 → **整条链路在 web 上不可能成立**。

⚠️ **这是「永久不可用」，不是「等一会就好」。** 而当前文案是「请稍候再试」——
**它在制造一个永远不会兑现的期待。**

### B. 🔴 provider 从未预热（我的 bug）

**全项目只有一处引用，且是 `ref.read`：**

```
lib/screens/reader_screen.dart:257   final service = ref.read(wordQueryProvider).serviceOrNull;
```

**而两处注释都声称是 `ref.watch`：**

| 位置 | 注释原文 |
|---|---|
| `word_db_provider.dart:24` | 「进阅读器时由 `reader_screen` 触发（**`ref.watch`**）」 |
| `reader_screen.dart:259` | 「落盘**通常**在进入阅读器时就开始了（**`ref.watch`** 触发）→ 所以这个分支只在『刚进来就划词』时出现」 |

**对照同类 provider（证明是漏做，不是有意设计）：**

| provider | 消费方式 |
|---|---|
| `bookmarkProvider` | ✅ `ref.watch`（`reader_screen:161` · `home_screen:232`） |
| `wordQueryProvider` | 🔴 **仅 `ref.read`**（`reader_screen:257`） |

**后果（真机同样发生）：**

```
进阅读器            → 🚫 不启动落盘（31.4 MB 的复制根本没开始）
用户读一会，长按     → ref.read → 那一刻 future **刚启动**
                    → .valueOrNull == null
                    → 必然「词库正在准备，请稍候再试」   ← 第一次点词 100% 失败
（future 继续跑完，因 provider 非 autoDispose）
第二次点词          → 能成功
```

→ **真机上「第一次查词必失败」**，而文案说「请稍候再试」——
用户以为是自己点太快，**看不出这是「没预热」**。

### C. 文案把三种语义糊成一句

`null` 同时表示：

| 实际语义 | 可等？ | 当前文案 |
|---|---|---|
| 还在落盘/打开（真机首次） | ✅ 可等 | 「词库正在准备，请稍候再试」 |
| **这个平台没有 SQLite**（web） | ❌ **不可等** | 同上 ← 🔴 **误导** |
| 真机上落盘/打开失败 | ❌ **不可等**（需重启/上报） | 同上 ← 🔴 **误导** |

---

## 三、修复方案（三个选项，请白哥定）

### 选项 1（我建议）：修 **B + C**

| 改动 | 位置 | 内容 |
|---|---|---|
| **B** | `reader_screen.build` | 加 `ref.watch(wordQueryProvider)` → **进阅读器即开始落盘**（与 `bookmarkProvider` 一致） |
| **C** | `word_db_provider` + `reader_screen` | 让「不可用」**带原因**，三句话分开 |

C 的文案设计（`switch` 穷尽，编译器强制覆盖）：

| 原因 | 文案 |
|---|---|
| **平台不支持**（web） | 「查词需在手机上使用（Web 端无本地词库）」 |
| **失败**（真机） | 「词库打开失败，请重启 App 后再试」 |
| **加载中**（真机首次） | 「词库正在准备，请稍候再试」（**原句，此时才正确**） |

**收益**：真机第一次查词即可用；web 上不再看到「请稍候」这种空头承诺。
**代价**：约 40 行改动（provider 返回结构 + UI 分支）。

### 选项 2：**B + C + 让 web 也能查词**

额外引入 `sqflite_common_ffi_web` + `sqlite3.wasm`（≈ 1–2 MB）。

- ✅ **收益**：你能在 **Chrome 上直接看到真实词卡** —— 不必等 Android 的 Gradle 首次构建（10–30 min）
- ⚠️ **代价**：新增依赖 + 多一套平台分支；**产品不做 web** → 属**纯开发便利**，不是产品需求
- 📌 我的看法：**唯一值得的理由是「省你的验证时间」**。若你觉得 Android 模拟器路径可接受，选 1 更干净。

### 选项 3（最小）：**只修 B**

只补预热，文案不动。
- ⚠️ 代价：web 上你**仍**会看到「正在准备」（且永远不会好）；真机失败时也**分不清原因**

---

## 四、另外：与「Web 端限制」的完整清单

这两轮在 web 上撞到的限制，已可归成一张表（**都不是 bug，都是「产品不做 web」的后果**）：

| 层 | 限制 | 已处置 |
|---|---|---|
| **手势** | 长按不认鼠标（`_kLongPressSelectionDevices` 无 mouse） | ✅ Chrome 设备模拟绕开（已确认可行） |
| **系统菜单** | web 显示浏览器原生菜单，不显示 Flutter 工具栏 | ✅ debug-only `disableContextMenu()` |
| **数据层** | **无本地 SQLite**（sqflite / path_provider / dart:io 三缺） | 🔴 **本报告（待定）** |

→ **结论：web 只能验证「UI 与手势链路」，验证不了「数据层」。**
真实查词必须在 **Android 模拟器**（AVD `coeo_phone` 已建）或 **iPhone 真机**。

---

## 五、自证据（请白哥协助确认）

provider 的 catch 分支里有日志：

```dart
debugPrint('[word_db] 词库不可用：$e\n$st');
```

→ **请把控制台里 `[word_db]` 开头的那几行发我**（若有）。
它能直接显示 web 上抛的是哪个异常，可用来验证上面的推断。

---

## 六、如果白哥批「选项 1」，执行清单

| # | 步骤 | 文件 |
|---|---|---|
| 1 | provider 返回**带原因**的结构（web 提前返回「不支持」，不浪费一次注定失败的尝试） | `lib/providers/word_db_provider.dart` |
| 2 | `build` 里加 `ref.watch` 预热 | `lib/screens/reader_screen.dart` |
| 3 | `_lookupWord` 按原因给文案（`switch` 穷尽） | 同上 |
| 4 | 同步两处**已失效的注释**（现在它们写着不存在的 `ref.watch`） | 两个文件 |
| 5 | 跑 `analyze_inproc` 对齐基线 + 全套回归 | — |
| 6 | 真机验证：Android 模拟器长按查词 | — |

> ⚠️ 本报告**未改任何代码**。等白哥审批。

---

## 七、✅ 执行记录（白哥 15:58 批准「修 B + C」）

### 7.1 改动清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `lib/providers/word_db_provider.dart` | **重写**：返回 `WordDbLoad`（sealed class）替代 `WordQueryService?`；**web 上提前返回 `WordDbUnsupported`**（不做注定失败的尝试）；失败转 `WordDbFailed`；删掉旧的 `serviceOrNull`/`isReady` 扩展 |
| 2 | `lib/screens/reader_screen.dart` | **build 里加 `ref.watch(wordQueryProvider)`**（预热）+ `_lookupWord` 按原因给三种文案 |
| 3 | `lib/screens/reader_screen.dart` | 文档表格「三种查不到」→ **四种**（补「平台不支持」与「打开失败」，并标出**能不能等**） |
| 4 | `scripts/tokens_verify/bin/verify_tokens.dart` | §12 追加 **4 条断言**（含「必须 watch」这条易回归约束） |

### 7.2 设计：让「不可用」在类型上必须带原因

```dart
sealed class WordDbLoad { }
final class WordDbReady extends WordDbLoad { final WordQueryService service; }
final class WordDbUnsupported extends WordDbLoad { }        // web：永久
final class WordDbFailed extends WordDbLoad { final Object error; }
```

🔑 **为什么是 sealed class 而不是 `WordQueryService? + reason 字段`**：
- `WordDbReady` **保证 `service` 非 null** → **类型层面消除了「有结果但没 service」的非法状态**
- `switch` 在 sealed class 下**编译器强制穷尽** → 新增一种原因时，所有消费方会**编译报错**（而不是静默落到 default）
- ⚠️ **加载中不放在这里** —— 那是 `AsyncLoading`（`valueOrNull == null`）。
  本类型只表达「future 已结束」的三种结局，避免「用同一个值表达『过程』与『结局』」

### 7.3 文案分层（四种，各自准确）

| 情况 | 文案 | 能等？ |
|---|---|---|
| `WordDbUnsupported`（web） | 查词需在手机上使用（Web 端无本地词库） | ❌ **永久** |
| `WordDbFailed`（真机） | 词库打开失败，请重启 App 后再试 | ❌ 需重启 |
| `valueOrNull == null`（首次落盘中） | 词库正在准备，请稍候再试 | ✅ 约 0.5–2 s |
| 查不到（未命中） | 词库里没有「X」 | — |

### 7.4 🔒 新增的 4 条断言（`tokens_verify` §12）

```
✅ 阅读器 watch 了 wordQueryProvider（预热，不能只 read）
✅ 词库「不可用」带原因（sealed class，非裸 null）
✅ web 上提前返回「不支持」（不做注定失败的尝试）
✅ 失败转成结果类型（不产生 AsyncError，防 when(error:) 把整页变报错）
```

🔑 **第一条是「防回归锁」** —— 它极易回归（有人为了「省一次 rebuild」把 `watch` 改回 `read`），
而后果是「第一次查词 100% 失败」，且**在 web 上看不出来**（web 本来就失败）。
→ **凡「改坏了在开发环境看不出来」的约束，都该用断言锁住。**

✅ **并已验证断言真会红**：故意把 `watch` 改回 `read` → 精确报
「实现类失败 1 项 · 🔴 阅读器 watch 了 wordQueryProvider」→ 恢复后 308 项全过。
（按既定做法：**新增的防漂移断言必须故意破坏一次，否则可能是「永远绿」的假保护**。）

### 7.5 ✅ 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（与基线逐项一致） |
| `tokens_verify` | ✅ **308 项**（304 → 308） |
| `query_verify` 六脚本 | ✅ **6 / 22 / 31 / 42 / 37 / 49** |
| `trace_verify` | ✅ **97 项** |
| 断言有效性 | ✅ 故意回归验证过**真会红** |
| 旧 API 残留 | ✅ `serviceOrNull` / `WordQueryStateX` 引用 **0** |

### 7.6 ⏳ 仍需真机验证（脚本查不出）

| 项 | 说明 |
|---|---|
| **「第一次查词就能成功」** | 本轮的修复目标。需在 **Android 模拟器 / iPhone** 上：进阅读器 → 立刻长按一个词 → 应弹**词卡**（而非「正在准备」） |
| **首次落盘耗时** | 31.4 MB；预热后用户读正文的几秒是否足够 |
| `assets/word.db` 是否真被 `rootBundle` 找到 | 本地脚本不过打包链路 |

### 7.7 一句话总结

**A 不是 bug 而是「产品不做 web」的必然后果；B 是真 bug（我的）；C 让 A 与 B 都变得不可诊断。**
本轮修掉 B 与 C，并给 A 一个**准确的**（而非安慰性的）表达。

---

## 八、如何验证（含两个已查明的坑 · 2026-09-27 16:10）

### 8.1 🔴 先说三个「不需要」

| 白哥的问法 | 答案 | 理由 |
|---|---|---|
| 「构建完整的 APK 包」？ | ❌ **不需要** | `flutter run -d android` = **构建 + 安装 + 启动 + 挂日志**一步到位。手动 `build apk` 再装：**多一步、少一个日志**，无任何优势 |
| 「在手机上测试」？ | ❌ **不需要手机** | **Android 模拟器已全部就绪** —— AVD `coeo_phone` 已建 · WHPX 加速器实测可用 · SDK/platforms(34/35/36)/build-tools/NDK(26/28)/licenses/JDK 全齐。⚠️ 真机反而更麻烦（USB 调试 + Windows 驱动 + 首次授权） |
| 需要配签名吗？ | ❌ **不需要** | `app/build.gradle.kts` 里 **release 也用 debug key**（Flutter 模板默认）→ `flutter run` **零签名配置** |

⚠️ **iOS 侧在 Windows 上无法验证**（构建需 Xcode/macOS）→ 本轮以 **Android 模拟器**为准。

### 8.2 🔴 两个会白折腾的坑（已查证）

#### 坑 1：Gradle 8.12 必须下载（约 200 MB）

| 查证项 | 实测结果 |
|---|---|
| `~/.gradle/wrapper/dists/` | 🔴 有一个 `gradle-8.10.2-all` 目录，但 **0 个文件**（空壳）→ 从未真下载过 |
| 8.10.2 能用吗 | 🔴 **不能** —— AGP 8.9.1 要求 Gradle **≥ 8.11.1**（`flutter_tools/.../gradle_utils.dart:804` 原文） |
| 项目要的版本 | `gradle-8.12-**all**.zip`（**-all 含源码/文档 → 约 200 MB**） |

🔑 **可优化**：Flutter 构建**不需要** Gradle 的源码与文档 → 把 `-all` 改为 `-bin`（**约 130 MB，省 70 MB**）。
`gradle-wrapper.properties:6` → `distributionUrl=...gradle-8.12-bin.zip`

⚠️ 若下载慢，镜像（**须确认该版本在镜像上存在**，-bin/-all 可能不同步）：

| 镜像 | 地址格式 |
|---|---|
| 腾讯云 | `https://mirrors.cloud.tencent.com/gradle/gradle-8.12-bin.zip` |
| 阿里云 | `https://mirrors.aliyun.com/gradle/gradle-8.12-bin.zip` |
| 华为云 | `https://repo.huaweicloud.com/gradle/distributions/gradle-8.12-bin.zip` |

#### 坑 2：`-Xmx8G` 在 16 GB 机器上偏大

| 查证项 | 实测 |
|---|---|
| 物理内存 | **15.8 GB**（当前**空闲仅 5.1 GB**） |
| `app/android/gradle.properties` | `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G ...` |
| 来源 | 🔑 **Flutter 官方模板默认值**（已核对 `templates/app/android.tmpl/gradle.properties.tmpl`，**不是项目改的**） |

**风险**：Gradle daemon（最多 8 G）+ Kotlin daemon → 在 16 GB 机器上可能 **OOM 或疯狂 swap**。
→ 建议降为 `-Xmx4G -XX:MaxMetaspaceSize=1G`。

⚠️ 两个文件（`gradle.properties` · `gradle-wrapper.properties`）**都被 git 跟踪** → 改动属代码变更，**需白哥批准**。

### 8.3 ✅ 推荐路径（一条链，含「不需设备」的前置验证）

```bash
cd E:/CoEvo/app

# ① 构建（首次含 Gradle 下载，10–30 min）
D:/flutter/bin/flutter.bat build apk --debug

# ② 【不需设备】验证「打包链路」—— 这正是项目踩过的坑
#    （assets 未声明 → 不打包，且**编译不报错**），必须显式查一次
unzip -l build\app\outputs\flutter-apk\app-debug.apk | grep word.db
#    预期看到：assets/flutter_assets/assets/word.db   （约 31.4 MB）

# ③ 启动模拟器（或直接用 Android Studio 的 Device Manager，更简单）
C:/Users/Lenovo/AppData/Local/Android/Sdk/emulator/emulator.exe -avd coeo_phone

# ④ 确认设备可见（应列出 emulator-5554）
D:/flutter/bin/flutter.bat devices

# ⑤ 跑（复用 ① 的 Gradle 缓存 → 快）
D:/flutter/bin/flutter.bat run -d android
```

> 🔑 **② 是关键**：`flutter run` 或 `build` **都不会**在 assets 未声明时报错 ——
> 只有「解压看包」或「运行时找不到文件」才知道。而后者要等到真机上。
> → **先查包，再上设备**，能把「打包问题」与「运行时问题」分开定位。

### 8.4 ⏳ 验证清单（4 项 —— 脚本查不出，只能真机看）

| # | 操作 | 预期 |
|---|---|---|
| 1 | 进阅读器 → **立刻**长按一个词 | 🔴 应弹**词卡**（而非「词库正在准备」）← **本轮的修复目标** |
| 2 | 长按 `vertical` | 音标 / 词性 **`n.`**（不是 `[n]`）/ 释义 / 例句 |
| 3 | 长按词库里没有的词 | 「词库里没有「X」」 |
| 4 | 看控制台 | 应打印 `[word_db]` 开头的日志（落盘判断依据：路径 + 两侧大小） |

⚠️ 第 4 项特别重要 —— 它是「落盘到底有没有发生、为什么」的唯一线索。
