# 🔴 Android 构建失败 1h26m —— 根因：`dart:js`/`dart:html` 阻断原生编译

> 日期：2026-09-27 19:50
> 触发：白哥「`flutter build apk --debug` 运行超过 1 个小时，正常吗」
> 状态：✅ **已实施「删掉 web 录音代码」**（白哥 2026-09-27 19:55 批准）—— 见 §七 执行记录
> 相关：`word-db-readiness-gap-2026-09-27.md` §八（验证方案）· 进度 §3.33

---

## 一、直接回答：**不正常，而且它不是「慢」，是已经失败了**

从 Gradle daemon 日志（`D:\gradle-cache\daemon\8.12\daemon-27408.out.log`）原文：

```
lib/screens/chat/chat_input.dart:221:10: Error: Undefined name 'context'.
lib/widgets/review_card_widget.dart:142:14: Error: Undefined name 'context'.
lib/widgets/review_card_widget.dart:155:10: Error: Undefined name 'context'.
lib/widgets/review_card_widget.dart:181:25: Error: Undefined name 'JsFunction'.
lib/widgets/review_card_widget.dart:184:14: Error: Undefined name 'context'.
Unhandled exception:
FileSystemException(uri=org-dartlang-untranslatable-uri:dart%3Ajs; message=...)
Target kernel_snapshot_program failed: Exception
FAILURE: Build failed with an exception.
Execution failed for task ':app:compileFlutterBuildDebug'.
BUILD FAILED in 1h 26m 4s
```

🔴 **`BUILD FAILED`** —— 失败点在 `:app:compileFlutterBuildDebug`（Dart → kernel 编译阶段）。
那 1h26m 里，绝大部分是首次 Gradle 配置 + 依赖解析（正常），**最后在编译 Dart 时报错终止**。

⚠️ 两个更正我上一轮的说法：
| 我上轮说 | 实际 |
|---|---|
| 「Gradle 8.12 从未下载」 | ❌ **错了** —— `GRADLE_USER_HOME=D:\gradle-cache`（被重定向到 D 盘），我看的是 `~/.gradle`。实际 `gradle-8.12-all.zip.ok` **存在 → 已下完** |
| 「`-Xmx8G` 可能 OOM」 | ⚠️ **不是本次原因** —— daemon 请求 2.46 GB，日志无 OOM；机器跑得下来 |

---

## 二、🔴 根因：`dart:js` / `dart:html` 在非 web 平台是**编译期不可用**

| 文件 | 导入 | 用法 | 性质 |
|---|---|---|---|
| `lib/screens/chat/chat_input.dart` | `import 'dart:js' as js;`（第 3 行） | **7 处** `js.context.callMethod(...)` | 🔴 阻断 |
| `lib/widgets/review_card_widget.dart` | `import 'dart:html' as html;`（第 3 行） | 🔴 **0 处** —— **纯冗余导入** | 🔴 阻断（只需删一行） |
| 同上 | `import 'dart:js' as js;`（第 4 行） | **4 处** | 🔴 阻断 |

### 这些代码是干什么的：**浏览器端录音**

```dart
// chat_input.dart:60 —— 注入一段 JS 到浏览器全局
js.context.callMethod('eval', ['''...__coeStart / __coeStop...''']);
// 之后靠 callMethod 控制录音，回调拿 WAV base64
js.context.callMethod('__coeStart');               // 开始
js.context.callMethod('__coeStop', [callback]);    // 停止 → base64
final callback = js.JsFunction.withThis((self, b64) { _sendBase64(b64 as String); });
```

→ 靠**浏览器 MediaRecorder API** 录音 → base64 → POST 到 `/api/stt/transcribe`（腾讯云 ASR）。

🔑 **关键判断：这段代码在 iOS/Android 上「原理上就不可能工作」** ——
它依赖浏览器的 MediaRecorder，而 iOS 上根本没有这个东西。

### 引用链（活代码，但**用户不可达**）

```
app.dart:10 → chat_screen.dart ─┬→ chat_input.dart                    ← 出错 1
                                └→ review_dialog.dart → review_card_widget.dart  ← 出错 2
```

⚠️ `chat_screen` 是 **v1「AI 考核」预留**（白哥 2026-09-27 定「保留」），
**但首页入口已在 3.1 移除** → 当前**用户无法到达**。

---

## 三、🔴🔴 为什么我没早发现（这是本轮最值得记的）

**`analyze_inproc` 一直在报这三条**，而且**我自己写的规则里就明写了后果**：

```
ERROR  web_only_library  app/lib/screens/chat/chat_input.dart:3:1
       `dart:js` 原生平台不可用（web-only）→ iOS/Android 编不过
ERROR  web_only_library  app/lib/widgets/review_card_widget.dart:3:1
       `dart:html` 原生平台不可用（web-only）→ iOS/Android 编不过
ERROR  web_only_library  app/lib/widgets/review_card_widget.dart:4:1
       `dart:js` 原生平台不可用（web-only）→ iOS/Android 编不过
```

而我在**过去 5 轮报告里都写着**：

> 「`analyze_inproc` ✅ **error=3 / warning=13 / info=7** —— 与基线**逐项一致**」

🔑🔑 **我的流程缺陷：**
> 我把 `error=3` 纳入「基线」，然后用「**与基线一致**」当作「**没问题**」的证明。
>
> 但「与基线一致」的真实含义只是「**和上次一样**」——
> 当基线里装着 **error** 时，这句话等价于「**故障依旧**」，而不是「通过」。

**正确做法**：基线必须**分层**——
| 层 | 含义 | 能否接受 |
|---|---|---|
| `error` | **已知故障** | ❌ **不能**（应记为待修，不该长期留在基线里） |
| `warning` / `info` | 可接受噪音 | ✅ 可作基线 |

→ 本轮之后：**`error` 数从「基线 3」改为「阻断项必须是 0」**。

---

## 四、修复方案（三个选项，请白哥定）

### 方案 A（我建议）：**删掉这段录音代码**

| 文件 | 改动 |
|---|---|
| `review_card_widget.dart` | 删 `dart:html`（**0 使用，一行**）+ `dart:js` + 4 处调用 + 语音模式相关字段/UI |
| `chat_input.dart` | 删 `dart:js` + 7 处调用 + 语音模式相关字段/UI |

**为什么我认为这不是「删功能」而是「卸包袱」**：
1. 它在 **iOS 上原理上不可能工作**（依赖浏览器 MediaRecorder）→ **目标平台上从来没有过这个能力**
2. 它当前**用户不可达**（chat 入口已移除）
3. 它与已定案的方案冲突：音频方案是 **`flutter_tts` 全量端侧**（TTS），ASR 只保留服务端接口
4. 产品**只做 iOS**、**不做 web** → 保留 web 录音**没有产品价值**

✅ 解阻最快、最彻底｜⚠️ 但「AI 考核要不要语音输入」需白哥拍板

### 方案 B：**条件导入**（保留 web 录音，原生用 stub）

```dart
// 抽到独立文件，用条件导入隔离
import 'voice_recorder_web.dart' if (dart.library.io) 'voice_recorder_stub.dart';
```

✅ 保留 web 开发预览的录音能力 + 原生可编译
⚠️ 要拆文件、改调用方（2 个文件的录音相关方法）
⚠️ 保留的是**没有产品价值**的能力（web 本来就不做）

> 🔑 **技术要点**：**不能用 `kIsWeb` 守卫解决** —— `import 'dart:js'` 是**编译期**错误，
> 不是运行期错误，所以 `if (kIsWeb) { js.context... }` 一样编不过。
> **必须**条件导入或删除。这是本轮最容易走错的一步。

### 方案 C：**换跨平台录音插件**（如 `record` 包）

✅ 录音在 iOS 上**真能用**（若 AI 考核要语音输入，这是正路）
⚠️ 新依赖 + 重写录音逻辑 + 真机验证权限/音频格式 + ASR 链路要打通
⚠️ 属**新功能开发**，不是修 bug

---

## 五、我建议的路径

**① 立刻做方案 A 解阻**（让白哥能跑起来测试）→ **② 把「AI 考核是否需要语音输入」记为 3.7 的待办**
→ 若到 3.7 确认需要，那时用**方案 C 正经实现**（iOS 用原生录音，而不是浏览器 MediaRecorder）。

---

## 六、执行清单（若批方案 A）

| # | 步骤 | 文件 |
|---|---|---|
| 1 | 删 `dart:html` 冗余导入（一行） | `review_card_widget.dart` |
| 2 | 删 `dart:js` + 录音相关方法/字段/UI（语音模式） | `review_card_widget.dart` |
| 3 | 删 `dart:js` + 录音相关方法/字段/UI | `chat_input.dart` |
| 4 | 处理 `chat_screen` / `review_dialog` 里对语音模式的调用点 | 两处 |
| 5 | 🔴 **`analyze_inproc` 的 `error` 必须归零**（不再当基线） | — |
| 6 | 重跑全套验收 + 再次 `flutter build apk --debug` | — |
| 7 | 装包前先 `unzip -l` 查 `word.db` 是否进包（§八 ②） | — |

> ⚠️ 本报告**未改任何代码**。等白哥审批。
> 📌 另：本轮还查明**上一轮报告 §8.2 的两条推断有一条是错的**（Gradle 缓存位置），已在 §一 更正。

---

## 七、✅ 执行记录（白哥 19:55 批准两项）

| 白哥决策 | 内容 |
|---|---|
| ① 修复方案 | **删掉 web 录音代码** |
| ② 流程改进 | **静态分析的 error 从此必须为 0** |

### 7.1 改动清单

| 文件 | 改动 | 行数 |
|---|---|---|
| `lib/screens/chat/chat_input.dart` | **重写**：删 `dart:js` + 7 处 `js.` 调用 + 语音字段/方法/UI；`ConsumerStatefulWidget` → **`StatelessWidget`**（删后无状态、也不用 ref） | 348 → **85**（−263） |
| `lib/widgets/review_card_widget.dart` | 删 `dart:html`（**0 使用，纯冗余**）+ `dart:js` + `dart:async`（仅 Timer 用）+ `http`（仅语音用）+ 6 个语音字段 + 4 个语音方法 + `_resetState` 的重置 + build 的语音 UI + `with TickerProviderStateMixin`（**0 个 AnimationController**，语音时代遗留） | 846 → **692**（−154） |

**净减 −417 行**（含两个文件从 web-only 包袱中解脱）。

### 7.2 🔑 一个关键判断：**这不是「删功能」，是「卸包袱」**

| 论点 | 依据 |
|---|---|
| 它在 iOS 上**原理上不可能工作** | 依赖浏览器 `MediaRecorder` + `ScriptProcessor`，iOS 上没有 |
| 它当前**用户不可达** | `chat_screen` 是 v1「AI 考核」预留，首页入口已在 3.1 移除 |
| 它与已定案的音频方案冲突 | 音频方案 = **`flutter_tts` 全量端侧**（TTS）；ASR 只保留服务端接口 |
| 产品**只做 iOS、不做 web** | 保留 web 录音**没有产品价值** |

→ ∴ 删除它**不损失任何现有能力** —— 它在目标平台上**从未生效过**。

⚠️ 若将来「AI 考核」需要语音输入 → 在 iOS 上用**原生录音插件**（如 `record`）实现，**不是恢复这段代码**。

### 7.3 🔴 教训：`kIsWeb` 守卫**解决不了**这个问题

本轮最容易走错的一步 —— 值得写进知识库：

```dart
// ❌ 不管用：import 本身就炸（编译期错误，不是运行期）
import 'dart:js' as js;
if (kIsWeb) { js.context.callMethod('__coeStart'); }

// ✅ 只有两条路：
//   (a) 删掉
//   (b) 条件导入，把 dart:js 隔离到独立文件
//   import 'x.dart' if (dart.library.io) 'stub.dart';
```

> 🔑 **判据**：**「这个错误是编译期还是运行期？」**
> 编译期错误（缺符号、平台不支持的库）→ `if` 守卫**无效**，必须改**结构**（删 / 条件导入 / 换实现）。
> 运行期错误（平台行为差异）→ `if` 守卫可能有效。

### 7.4 🔴🔴 本轮最重要的教训：把 `error` 当「基线」= 把故障当正常

`analyze_inproc` **过去 5 轮都在报**这三条，而且**规则文本里就写了后果**：

```
ERROR  web_only_library  chat_input.dart:3:1
       `dart:js` 原生平台不可用（web-only）→ iOS/Android 编不过
```

我却在每轮报告里写「**error=3 / warning=13 / info=7 —— 与基线逐项一致**」。

> 🔑 **「与基线一致」的真实含义只是「和上次一样」。**
> 当基线里装着 **error** 时，它等价于「**故障依旧**」，**不是**「通过」。
>
> **∴ 基线必须分层**：
> | 层 | 含义 | 能否接受 |
> |---|---|---|
> | `error` | **已知故障** | ❌ 不能（必须修，不该长期留在基线） |
> | `warning` / `info` | 可接受噪音 | ✅ 可作基线 |

**已按白哥批准改为：`error` 必须为 0，不为 0 就当场排查。**

### 7.5 ✅ 验证

| 项 | 改前 | 改后 |
|---|---|---|
| **`analyze_inproc`** | error=**3** / warning=13 / info=7 | ✅ **error=0** / warning=13 / **info=4** |
| 残留扫描 | — | `js.` · `html.` · `_voiceMode` · `Timer` · `http.` **全 0** ✅ |
| `tokens_verify` | 308 | ✅ **308** |
| `query_verify` 六脚本 | 6/22/31/42/37/49 | ✅ **6/22/31/42/37/49** |
| `trace_verify` | 97 | ✅ **97** |
| 调用点 | — | ✅ `ChatInput(构造参数未变)` · `review_dialog` 无语音调用 · `chat_screen` 无语音 UI |

### 7.6 ⏳ 请白哥重新构建

```bash
cd E:/CoEvo/app
D:/flutter/bin/flutter.bat build apk --debug
```

**预期比上次快很多** —— 那 1h26m 里绝大部分是**首次** Gradle 下载 + 依赖解析 + 配置，
这些现在**已全部缓存**（`D:/gradle-cache`）。这次实际只做「重新编译 Dart + 打包」。

⚠️ 若仍报错，**先看清是不是 `kernel_snapshot` 之外的新错误** ——
本轮的修复只针对 `dart:js`/`dart:html` 这一类；若出现别的错，那是**另一个问题**，别当成「没修好」。

✅ 构建成功后**务必先做这一步**（不需要设备）：
```bash
python -c "import zipfile; print([n for n in zipfile.ZipFile(r'build/app/outputs/flutter-apk/app-debug.apk').namelist() if 'word.db' in n])"
# 预期：['assets/flutter_assets/assets/word.db']
```
