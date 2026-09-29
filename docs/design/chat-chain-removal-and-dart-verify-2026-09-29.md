# 端侧 chat 链清理 + 抽出 `UserApiClient`（含「本机可用的 Dart 验证方法」）

> 2026-09-29 16:3x~17:0x ｜ 触发：白哥「同意你的建议」（承接 `legacy-cleanup-round2-2026-09-29.md` §六 的 3 个决策）
> **纯本地** —— 未部署、未碰生产服务器。

---

## 一、一句话结论

**删掉 4,463 行不可达代码（16 个文件），把 719 行的 `chat_client` 收敛成 ~95 行的 `UserApiClient`，
并用 analyzer 做了 resolution 级验证：我的改动 0 error。**

🔑 过程中有 **1 个重要突破**（本机可用的 Dart 验证方法）和 **1 个我的错误**（路径解析口径算错，产生 7 处假警报）。

---

## 二、做了什么

### 1. 删除 chat 整链（16 个文件 · 4,463 行）

| 文件 | 行数 |
|---|---:|
| `screens/chat_screen.dart` | 998 |
| `screens/chat/`（5 文件） | 882 |
| `widgets/review_card_widget.dart` | 691 |
| `widgets/review_dialog.dart` | 433 |
| `providers/plan_provider.dart` | 149 |
| `pipelines/`（6 文件） | 591 |
| `api/chat_client.dart` | 719 |
| **合计** | **4,463** |

同时改 `app.dart`：删 `/chat` 路由 + `ChatScreen` import（附注释说明「有路由、无入口」）。

### 2. 🔑 删除前先验证「闭包」（用 import 反向图）

16 个文件不能盲删 —— 必须确认「删掉它们后，剩下的代码不再引用它们」。
用脚本解析**全部 import 边**，并**标注每个 referrer 是否也在删除集合内**：

```
screens/chat_screen.dart      ← app.dart（要改路由）
widgets/review_dialog.dart    ← chat_screen ★随删
widgets/review_card_widget.dart ← review_dialog ★随删
providers/plan_provider.dart  ← chat_concept_dialog ★ / chat_reading_passage ★ / chat_screen ★ / review_card_widget ★ / review_dialog ★
pipelines/**                  ← 均在集合内 ★
screens/chat/**               ← chat_screen ★
api/chat_client.dart          ← 12 处在集合内 ★ + 🔴 profile_screen（**保留**）
```

→ **16 个里 15 个是闭包**；唯一例外 `chat_client.dart` 被现役 `profile_screen` 引用 → 需先抽小客户端。

### 3. 抽出 `UserApiClient`（719 → 95 行）

**核实「现役消费者用到哪几个方法」**（只查到文件级只能得出「不能删」，查到**方法级**才给得出方案）：

- `chat_client.dart` = 719 行 / **33 个公开方法**
- 现役消费者**只有 `profile_screen`**，且**真实只用 2 个**：`getProfile()` · `updateDisplayName()`

→ 🆕 `api/user_api_client.dart`（95 行）：保留这 2 个方法 + `_authHeaders`；**去掉** WebSocket /
`conversationId` / 其余 31 个方法。

🔴 **抽取原则：方法体与 `chat_client` 逐字一致** —— 抽取是**搬迁**不是重写。
顺手「改进」会让「删除」变成「改功能」，而本次改动**无法靠完整编译验证** → 必须让改动**可预测**。

### 4. 顺带修掉一个**多余的网络请求**

`profile_screen` 原本：

```dart
final results = await Future.wait([client.getProfile(), client.getPreferences()]);
final data = results[0];   // 🗑 results[1]（偏好）**从未被使用**
```

原注释称「请求暂留（`review_screen` 仍在用）」—— 🔴 **该理由已失效**：
`review_screen` 已于 09-28 整体重写（数据源全走端侧 `user.db`、**不联网**），不再使用 chat_client。
→ 删掉 `getPreferences()` 调用（每次进个人页少一次后端调用）。

> 🔑 判据命中：**代码注释里的理由也要验证** —— 过期注释会让「已无用的代码」伪装成「有理由的保留」。

---

## 三、🔴 本轮最重要的产出：**本机可用的 Dart 验证方法**

### 问题

本机 `flutter` / `dart analyze` **必崩**：
```
CreateFile failed 231 (所有的管道范例都在使用中)
ProcessException: ... (at ../../runtime/bin/process_win.cc:742)
```
→ 根因是**无法创建子进程**（管道耗尽，环境级限制）。两者都要拉子进程（dartdev → analysis_server）→ 必崩。

### ✅ 解法（实测可用）

```
D:\flutter\bin\cache\dart-sdk\bin\dart.exe        ← flutter 自带的 dart，可直接跑脚本（不拉子进程）
```
+ **`package:analyzer`**（纯 Dart 库，可在**同一进程内**完成 resolution）
→ 绕开「无法创建子进程」，拿到**编译级的 error 清单**。

**已固化为** 🆕 `app/tool/verify_resolution.dart`：

```bash
cd app
DART="/d/flutter/bin/cache/dart-sdk/bin/dart.exe"
"$DART" tool/verify_resolution.dart          # 检查 lib/
"$DART" tool/verify_resolution.dart lib/api  # 只查子目录
```
退出码：有 error → 1（可挂 CI）。

### ⚠️ 覆盖边界（必须如实标注）

| 覆盖 | 不覆盖 |
|---|---|
| import 能否解析（URI 存在性）✅ | 完整编译（const 求值 / tree-shaking / 平台通道）❌ |
| 类型错误 / 未定义符号 ✅ | 运行时行为 ❌ |

→ **结论只能说「resolution 通过」，不能说「构建通过」**。

---

## 四、🔴 我犯的错误：**路径解析口径算错，产生 7 处假警报**

### 现象

我用脚本（**文件系统路径**语义）检查 import，报出 **7 处「断链」**：
```
lib/screens/pay_screen.dart: import '../../api/api_config.dart' → app/api/api_config.dart（不存在）
```

### 差点酿成的后果

我一度准备报告「**项目当前编译不过**」。但项目在 09-27 构建成功过（`build/...cache.dill` 存在）→ **与证据矛盾** → 我决定先做**受控实验**而不是下结论。

### 受控实验（三步）

| 实验 | 结果 |
|---|---|
| ① 造一个**真的**指向不存在文件的 import | 🔴 analyzer **报了** `Target of URI doesn't exist` → 证明 analyzer 确实检查 URI |
| ② 把 `pay_screen` 两条 import **原样复制**到同目录的临时文件 | ✅ **一句错都不报** |
| ③ 横向对比同目录其它文件 | `home_screen` / `profile_screen` 都用 `'../api/'`，只有 `pay_screen` 用 `'../../api/'` |

### 🔑 真因：**两种路径语义不一样**

| 语义 | `lib/screens/x.dart` 里的 `'../../api/y.dart'` |
|---|---|
| **文件系统路径**（我的脚本） | `app/api/y.dart` → 不存在 → **误报断链** |
| **Dart 的 URI 语义**（analyzer/编译器） | 基于 `package:coevo_app/screens/` → **超出包根的 `..` 被忽略** → `lib/api/y.dart` ✅ **有效** |

🔑 **判据：「判据口径差一层」的新维度 —— 文件路径语义 vs URI 语义。**
  → **别用脚本手算 import 路径判断断链**，交给 analyzer（它按 Dart 语义解析）。
  → 配套：**受控实验能一举证伪自己的判据**（比反复推理有效）。

---

## 五、验证（analyzer 级 · 77 文件）

```
$ dart tool/verify_resolution.dart
🔴 /lib/providers/bookmark_provider.dart:124  The return type 'Object' isn't a 'Future<List<Bookmark>>', as required by the closure's context.
====================================
文件 77 · 🔴 ERROR 1 · 🟠 WARNING 2
```

| 项 | 结论 |
|---|---|
| **我的改动** | ✅ **0 error**（删 16 文件 + 改 2 文件 + 新增 2 文件全部 resolution 通过） |
| 唯一 1 个 error | 🔴 在 `providers/bookmark_provider.dart` —— **不在我的改动列表里**（最后改于 `0e9410f` Step 3 核心界面重写）→ **既有问题**，见 §六 |
| 闭包验证 | 16 个被删文件的 referrer 已逐一核对（见 §二.2） |
| 残留复核 | 全 app/ grep `ChatClient` / 被删文件名 → **只剩注释**，无代码引用 |

### ⚠️ 两个副作用（已处理）

| 副作用 | 原因 | 处理 |
|---|---|---|
| `pubspec.lock` 被改（44 行**版本降级**） | `dart analyze`（崩之前）用 **Dart SDK 3.11** 触发 pub get → 解析出不同版本 | ✅ 已 `git checkout` **还原** |
| `.dart_tool/` 被改（`package_config.json` 等） | 同上 | ✅ 已被 gitignore（不入库）；flutter 构建时会**自动重建**，无需手动 |

🔑 **教训：用「另一个 SDK」跑工具会改项目状态** —— 事前没料到，事后已还原。
🔴 另外发现 `.dart_tool/version` = **`3.27.5-ohos-1.0.5`（鸿蒙版 Flutter）** ——
   说明之前的 pub get 是**鸿蒙 SDK**跑的（与「应使用 `D:\flutter` 3.41.1」的约定不符）→ **待你确认**。

---

## 六、🔴 发现的既有问题（**未改** · 需你决定）

| # | 问题 | 说明 |
|---|---|---|
| 1 | `providers/bookmark_provider.dart:124` 有一个 **error** | `The return type 'Object' isn't a 'Future<List<Bookmark>>'` —— 类型错误，**与本次改动无关**（该文件最后改于 `0e9410f`）。🔴 如果它真是 error，说明**项目当前编译不过** → 需你确认（可能是我用的 Dart 3.11 比项目 SDK 新，判定更严） |
| 2 | `test/math_streaming_test.dart` · `test/math_e2e_pipeline_test.dart` | 注释写着「模拟 `chat_screen.dart` 的 `_handleWsEvent` / `_buildRichContent`」→ **测的是已删除的 chat 链行为**。它们**不 import** 被删文件（能编译 ✅），但已是**僵尸测试**（测不存在的功能）→ 建议一并删 |
| 3 | `.dart_tool/version` = 鸿蒙 SDK | 与「全路径用 `D:\flutter` 3.41.1」的约定不一致 → 待确认当前用哪个 SDK 构建 |

---

## 七、产物清单

| 类型 | 文件 |
|---|---|
| 🗑 删除（16） | `chat_screen` · `screens/chat/{5}` · `review_dialog` · `review_card_widget` · `plan_provider` · `pipelines/{6}` · `chat_client` —— 共 **4,463 行** |
| 🆕 | `app/lib/api/user_api_client.dart`（95 行 · 含逐字搬迁说明） |
| 🆕 | `app/tool/verify_resolution.dart`（**本机可用的 Dart 验证工具** · 含副作用与边界说明） |
| 📝 | `app/lib/app.dart`（删 `/chat` 路由 + import）· `app/lib/screens/profile_screen.dart`（换客户端 + 删多余请求） |

---

## 八、下一步

| 步 | 内容 | 阻塞 |
|---|---|---|
| **你确认** | §六 的 3 项（尤其 `bookmark_provider` 是否真 error） | 需你（我无法跑完整编译） |
| **你编译一次** | `flutter analyze` + 真机跑一下个人页（改昵称 / 看资料） | 我本机编译不了 |
| 僵尸测试 | 是否删 `test/math_*_test.dart` | 等你批 |
| **A2** | 端侧接在线制卡（`external_word_cache` + 转圈 + 重试） | 无（合规闸门已就绪） |

---

*本步**未部署、未碰生产服务器**。`pubspec.lock` 已还原；`.dart_tool/` 属构建缓存（已被 gitignore，flutter 构建时自动重建）。*
