# 端侧翻译 · 实施方案（2026-10-09）

> 来源：白哥「**做端侧翻译**，词典那条路放弃还是用我们现有的查词+LLM制卡方法——**方案A**，
> **订阅权益不变，端侧翻译替代 LLM 翻译作为订阅权益，文案都不用改**」
> 前置核查：📄 `system-dictionary-and-translation-feasibility-2026-10-09.md`（能力事实与证据）
> 状态：🟡 **方案 + 一个必须你拍板的岔路**（拍板后立即实施）

---

## 〇、先把「权益不变」这句话落到实现上（取证结果）

白哥的约束是：**权益不变 + 文案不改**。核实后发现两边情形**不同**：

| 位置 | 现状 | 结论 |
|---|---|---|
| **订阅页**「订阅权益」对照表（`subscribe_screen.dart::_benefitsSection`）| 🔑 **里面根本没有「翻译」二字**（该函数只负责「画」，条目由别处的判断驱动）| ✅ **订阅页确实一个字都不用改** —— 与白哥说的完全一致 |
| **登录弹窗**（`auth_dialog.dart:281-289`）| 文案是「阅读、划词、生词本与复习都不需要账号」（**如实列举，刻意不含翻译**）；注释写明：翻译之所以要登录，**唯一理由是「要记免费额度」** | ⚠️ 这句话的**事实前提**会变：端侧翻译零成本 ⇒「要记额度」这个理由**消失**了 |

服务端记账现状（`translation.rs`）：

| 项 | 值 |
|---|---|
| 表 | `translation_usage (user_id, period, used_count, chars_sum, updated_at)` |
| 免费额度 | `FREE_MONTHLY_LIMIT = 10`（按**月**，`period`）|
| 扣减 | `try_consume_quota` —— 原子 SQL（`WHERE used_count + 1 <= limit`），防并发双花 |
| 失败退额 | `refund_quota`（只有**成功给译文才计费**）|
| 文案 | 「本月翻译额度已用完（10 次），下月 1 日重置」 |

### 🔴 于是「权益不变」引出一个白哥可能没预见的问题

> **端侧翻译零成本，那额度还扣不扣？**

- 若**不扣**：免费用户从「10 次/月」变成**事实上无限** ⇒ **权益变了**（与白哥的约束矛盾）
- 若**扣**：端侧翻译也得先向服务端「记一次账」⇒ **仍然需要联网 + 登录**（离线优势丢失）

⇒ 这是本方案**唯一必须你拍板**的岔路（见 §三「请白哥定」）。

---

## 一、能力事实（复核，不重复展开，详见前置核查文档）

| 项 | 结论 |
|---|---|
| 框架 | `Translation.framework`（iOS **18.0+** 可用 `TranslationSession` 拿文本；**26+** 才有无界面入口）|
| 位置 | **完全端侧**（语言包与 Apple 翻译 App 共用）|
| 费用 | **0**（Apple 不收费、无额度）|
| 语言 | 英语 / 中文（简体）✅ |
| 数据 | **正文不出设备**（Apple 只收集 Bundle ID + 语言对统计）|
| 语言包 | 首次需**用户同意下载**（几十 MB）；此后**完全离线** |
| 🔴 实现约束 | **iOS 18–25 无法在无 UI 场景建 session** ⇒ 必须贴**不可见 SwiftUI 视图**、从 `.translationTask` 取 session |
| 🔴 测试约束 | **模拟器不支持** ⇒ **只能真机** |
| 中国区 | Apple 服务**不被墙**，简中在支持列表 ✅ |

---

## 二、实现方案（方案 A：端侧优先 + 服务端兜底）

### 分层（谁负责什么）

```
划词浮层「翻译」（word_lookup_selection.dart）
   └─ TranslationService          ← 🆕 唯一编排点（决定走谁、失败怎么回落）
        ├─ ① 权益闸门             ← 现有语义（登录 + 额度）；落点见 §三
        ├─ ② 端侧可用？
        │     iOS 18+ 且 LanguageAvailability == installed/可下载
        │       ├─ 可用 →  OnDeviceTranslateClient  ← 🆕 MethodChannel → Swift
        │       └─ 不可用/失败 → ③ 回落
        ├─ ③ 服务端 LLM（现有 TranslateClient，一字不改）
        └─ ④ 失败 → 退额（沿用现有 refund 语义）
```

### 端侧侧（Dart + Swift）

| 文件 | 内容 |
|---|---|
| 🆕 `app/lib/services/ondevice_translate.dart` | **纯 Dart** 契约：`OnDeviceAvailability { available, downloading, unsupported }` + 结果 sealed（`Ready(text)` / `Unavailable(reason)`），**零 Flutter 依赖** ⇒ 可被断言脚本直接跑 |
| 🆕 `app/lib/api/ondevice_translate_client.dart` | `MethodChannel('coevo/ondevice_translate')`：`availability()` / `translate(text, source, target)` |
| 🆕 `app/lib/services/translation_service.dart` | **编排**：闸门 → 端侧 → 回落 → 退额（唯一决定「走谁」的地方）|
| 🆕 `app/ios/Runner/OnDeviceTranslator.swift` | **桥接**（照 `AppDelegate.swift` 的 `open_with` 先例）：临时贴不可见 SwiftUI 视图 → `.translationTask` → 批量翻译 → 移除视图 |

### 服务端（**只有 §三 选 A1 时才动**）

| 改动 | 内容 |
|---|---|
| 🆕 `POST /api/translate/quota` | **只扣额、不翻译**（复用 `try_consume_quota`），返回 `{ok, remaining}`；端侧翻完若失败，仍可调现有退额路径 |

⚠️ 服务端**不加**任何对外新路由以外的东西；不碰 `admin/*`。
📌 若白哥选 A2/A3，则**服务端零改动**。

### 有意**不做**的

- ❌ 不引入第三方包 `apple_native_translate`（0.1.x / 36 天前发布 / README 自述用同样的「不可见视图」绕法）——**自写 40–60 行 Swift 更可控**
- ❌ 不提升 iOS 最低版本（现 **13.0**）—— 用 `if #available(iOS 18)` 分支，低版本走服务端回落
- ❌ 不改订阅页一个字（白哥定）· ❌ 不改 `translation_sheet.dart`（译文浮层形态不变）

---

## 三、白哥裁决（2026-10-09）

> **「同意 A1」**

⇒ 额度仍由**服务端**记账：端侧翻译**先预扣**、扣成功才翻、失败**带凭据回落**（不重复扣）。
**10 次/月这条门槛一字不变**，订阅页与登录弹窗文案**一个字不改**。

---

## 四、实施结果（同日完成）

### 服务端（Rust · `backend/crates/api_server/src/`）

| 改动 | 内容 |
|---|---|
| 🆕 `POST /api/translate/quota` | **只扣额、不调模型**（复用 `try_consume_quota` —— 与 `/api/translate` **同一条原子 SQL**）|
| 🆕 一次性凭据 | 预扣成功发 `ticket`（内存 Map · TTL 5 分钟）；回落时带回 ⇒ `take_ticket` **消费即删** + **校验归属** |
| `translate_text` → `translate_text_inner(text, uid, ticket)` | 带有效凭据 ⇒ **跳过扣额**；`translate_text` 保留原签名（老调用不受影响）|
| `TranslateRequest.ticket` | **可选 + 缺省即现状** ⇒ 老客户端行为一字不变 |
| `routes.rs` | 注册新路由 |

🔑 **凭据为什么必须有**（不是过度设计）：
- 没有它 ⇒ 回落会**再扣一次**（用户为一次翻译付两次）
- 没有「消费即删 + 归属校验」⇒ 一张凭据能被**反复用**（= 免费无限）或**被别人用**

### 端侧（Dart）

| 文件 | 内容 |
|---|---|
| 🆕 `services/ondevice_translate.dart` | **纯契约**（零 Flutter）：可用性枚举 + **分句器** `splitSentences` |
| 🆕 `api/ondevice_translate_client.dart` | MethodChannel（一切失败**吞成不可用 / null** ⇒ 交编排回落）|
| 🆕 `services/translation_service.dart` | **唯一编排点** —— 四个能力都做成参数 ⇒ **可注入、可断言** |
| `api/translate_parse.dart` | 🆕 `PrepayResult` sealed + `parsePrepayBody`（纯函数）|
| `api/translate_client.dart` | 🆕 `prepayQuota()`；`translate()` 加可选 `ticket` |
| `providers/translate_provider.dart` | 接到编排上（**译文浮层的调用点一行未改**）|

### 端侧（iOS Swift）

| 文件 | 内容 |
|---|---|
| 🆕 `ios/Runner/OnDeviceTranslator.swift` | 照 `open_with` 先例：**不可见 1×1 SwiftUI 视图** + `.translationTask` 取 session；用 `translations(from:)`（**保序**，不流式）|
| `ios/Runner/AppDelegate.swift` | 🆕 `setupTranslateChannel()`，**只在 iOS 18+ 注册**（低版本 ⇒ Dart 侧 `MissingPluginException` ⇒ 吞成 `unavailable` ⇒ 回落服务端）|
| `ios/Runner.xcodeproj/project.pbxproj` | 注册新 Swift 文件（**4 处**：BuildFile · FileReference · group · Sources）|

### 验证

| 层 | 结果 |
|---|---|
| 服务端 Rust | **21/21 通过**（🆕 6 个用例：凭据一次性 / 绑定归属 / 过期 / 不存在 / 预扣发凭据 / 到上限拒绝 / 订阅不发凭据 / 预扣不碰 LLM）|
| 端侧 Dart | 🆕 `verify_translation_service`：**68 项全过** |
| **证伪** | **5 条**（Dart 4 + Rust 1）：注入 ⇒ 变红 ⇒ **逐字节还原** |
| `analyze_inproc` | **error=0 warning=0** |
| `tokens_verify` | **699 通过 / 8 失败 = 存量基线，无新增** |
| `query_verify` 全量（55 个脚本）| 除 **`verify_book_cloud` 存量 1 项红**（书架云端 · 与本次无关）外**全绿** |
| 🔴 **iOS Swift** | **本机无法编译 / 运行** ⇒ 见 §五 真机清单 |

### 有意的取舍（写在这里，免得以后被当成 bug）

1. **`supported`（语言包未下载）不算「可用」** —— 首次翻会弹系统下载确认（几十 MB），
   而「划词翻译」这个场景等下载不可接受 ⇒ 直接走服务端 LLM。
2. **分句器有已知局限**：缩写后的点会被当句末（`The U.S. is large.` → 2 段）。
   完美分句需要 NLP，端侧只是加速层 ⇒ **断言里如实锁住了这条**（将来若加白名单，请连带改断言）。
3. **端侧失败一律回落服务端**，且**带凭据**（不重复扣）。
4. 🔑 **预扣「失败」也回落服务端**（而不是直接报错）—— 见下面第 4 条自我纠正。

### ✅ 实施中修掉的四处「我的错」（都值得记）

1. 🔴 **全角标点断不开中文**（真 bug）：规则要求「标点后是空白才断」⇒ `你好。你好吗？` 整段成一句。
   ⇒ 全角标点（`。！？`）**直接断**（中文不用空格）。
2. 🔴 **`eq` 比 `List` 是引用相等** ⇒ 两个内容相同的列表**必然假红**
   （`实得 [One., Two.] · 期望 [One., Two.]` 看着一样却不通过）⇒ 必须深度比较。
3. 🔴 **切片把文档注释一起框了进来** ⇒ 「翻译走 `/api/translate`」假红
   （prepayQuota 的注释里也写着 `/api/translate/quota`）⇒ 切片前先**剥注释**。
4. 🔴🔴 **「预扣失败 ⇒ 不翻」是我一开始的判断，它是错的**：
   - 后果：「**新 App + 旧服务端**」（没有 `quota` 路由 ⇒ 404）会让
     **iOS 18+ 且语言包已下好**的用户**连翻译都用不了**，而其他用户反而正常
     —— 一个典型的**上线顺序敏感**故障。
   - 正解：**回落服务端**。因为 `/api/translate` **自己就会扣额、并守着同一个上限**
     ⇒ 回落**不构成「绕过闸门」**（我此前把「不预扣就翻」与「回落」混为一谈了）。
   - 📌 判据：**能靠代码消解的顺序依赖，就不要留给流程去保证**。

---

## 四、🔴 先说清能力边界（避免做完才发现验不了）

| 层 | 本机能否验证 | 说明 |
|---|---|---|
| **Dart 侧** | ✅ 能 | `analyze_inproc`（进程内静态分析）+ 断言脚本 |
| **服务端 Rust** | ✅ 能 | 本机可 `cargo +1.98.0` |
| 🔴 **iOS Swift** | ❌ **不能** | 本机**没有 macOS/Xcode**，无法编译、无法运行；**模拟器也不支持端侧翻译** ⇒ **只能真机验证** |

⇒ 所以 iOS 侧我会：**写码 + 逐行静态审读 + 出一份真机验证清单**（§五），
代码能不能跑**必须由你在 Mac 上构建后真机确认** —— 这一条我不可能在本机替你验。

---

## 五、真机验证清单（构建后逐条过）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 首次翻译（语言包未装）| 弹 Apple 的**下载确认**；同意后开始下载（进度可见）|
| 2 | 语言包就绪后再翻 | **无 UI 弹出**，直接出译文 |
| 3 | 断网后翻译 | ✅ **仍能翻**（离线）|
| 4 | iOS 17 及以下机型 | 走**服务端回落**，功能不缺失（不崩、不空白）|
| 5 | 端侧抛错（如语言包被删）| 自动**回落服务端**，用户无感 |
| 6 | 免费账号翻 10 次后 | 第 11 次提示额度用尽（按 §三 所选口径）|
| 7 | 订阅账号 | 无额度提示 |
| 8 | 未登录点击翻译 | 按现有行为提示登录（A1）|
| 9 | 中文区实际下载速度 | 记录耗时（语言包约几十 MB）|

---

## 六、下一步（**全部需要你做 —— 我本机做不了任何 iOS 构建**）

> 🔴 **本节初稿写的是 `flutter build ipa …` —— 那条命令是错的**，我凭记忆编的。
>    项目文档 `docs/deploy/README.md` §4 写得很清楚：
>    **「iOS 只能走 CI（没有 Mac；Windows 上 Flutter 出不了 iOS 包）⇒ 必须公开仓库」**。
>    下面是**照抄文档**的正确流程。

### 🔴 先分清一件容易搞错的事：**安卓包测不了端侧翻译**

| 验证载体 | 能测什么 | 不能测什么 |
|---|---|---|
| **安卓包**（`docs/deploy/README.md` §3 · 本机可构建 · 不依赖 CI）| 不崩 · **回落服务端** · 额度扣减 · 文案 | 🔴 **端侧翻译本身**（`Translation.framework` 是 iOS 独有）|
| **iOS 包**（§4 · **只能走 CI** · 需公开仓库）| 端侧翻译的**全部**路径 | — |

⇒ 本次改动的**核心功能（端侧翻译）安卓包根本测不到** ⇒ **必须出 iOS 包**。

### ① ✅ 服务端**已部署**（2026-10-09 23:13）

新增 `POST /api/translate/quota` 已上线。部署与验证记录：

| 检查 | 结果 |
|---|---|
| 产物新鲜度（**用文档给的工具**）| ✅ 比源码新 · **且产物含新路由字符串**（旧产物 **0 命中**）|
| sha256 本地 / 上传 / 就位 | ✅ **三者一致** `33130e77…` ⇒ 换的确实是这个包 |
| 执行位 / 动态库 | ✅ `test -x` + `ldd` 无 `not found` |
| 服务重启 | ✅ `ActiveEnterTimestamp = 23:13:30 CST` · 监听 `127.0.0.1:8300` |
| 启动日志 | ✅ `Word bank 41574 words` · `LLM warmup: OK` · **0 panic / 0 ERROR** |
| 🔑 **路由判据** | `POST /api/translate/quota` **404 → 401**（body `{}` 合法 ⇒ 进 handler ⇒ 无 token）|
| 老路由没坏 | `POST /api/translate` 仍 **422** |
| 阴性对照 | `POST /api/nope` 仍 **404** |

📌 **回滚点**：`.prev` = 部署前那版（`b34da8bb…`）。
回滚也必须用 **`mv`**（同 §2.1 的警告：`cp` 会 `Text file busy`）。

⚠️ 部署中踩到：服务日志文件名是 `coevo.log.$(date +%F)`（**不带 `.log` 后缀**）⇒ 用 `*.log` 的 glob **读不到**。

### ② 出 iOS 包（**走 CI** · 照 `docs/deploy/README.md` §4）

1. **临时把仓库改公开** —— GitHub 对**私有仓库**的 macOS runner **按 10 倍计费**
   （2,000 分钟/月 → 实际仅 **200** macOS 分钟）。
   ⚠️ 改公开**前先清 git 历史**。
2. GitHub 网页 → **Actions** → **`iOS Archive & Upload`** → *Run workflow*：
   - **`method` = `ad-hoc`** ⇒ 产出可装**指定 UDID 真机**的 IPA（首次运行用的就是它）
   - `upload` **不勾**（只产 IPA artifact；ad-hoc 本来也不能上传 ASC）
3. 下载 artifact 里的 IPA，装到你的 iPhone。
4. **验证完把仓库改回私有。**
5. ⚠️ 若编译报 `cannot find 'OnDeviceTranslator' in scope` ⇒ 说明 pbxproj 没生效；
   在 Xcode 里把 `ios/Runner/OnDeviceTranslator.swift` 手动 **Add Files** 到 target
   （我已在 `project.pbxproj` 注册 4 处，但**本机无法验证 Xcode 认不认**）。

### ③ 真机逐条过 §五 清单（9 条）

### ④ 安卓包（**可选** · 先做本批的低风险验证）

```bash
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
```

产物 `app/build/app/outputs/flutter-apk/app-release.apk`（以上**照抄** `§3`）。
🔑 它能先证明「**新增的翻译编排没有把原来的翻译搞坏**」（回落路径 + 额度扣减 + 文案）——
   那部分对**全平台**生效，而**不依赖 CI、不依赖仓库公开**。

---

*2026-10-09 · 依据：Apple 官方文档 + WWDC24 + 本仓库代码实测（`translation.rs` / `translate_client.dart` / `auth_dialog.dart` / `subscribe_screen.dart`）*
