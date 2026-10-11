# 真机反馈：划线卡「没记录译文」+ 复习「没有译文提示」（2026-10-11）

> 白哥：「我重新出了安卓包，但是**划线后笔记中没有记录译文**，同时**复习时也没有译文提示**。」
>
> 本文只做**调查**，未改任何代码。

---

## 〇、结论先行

| 问题 | 判断 |
|---|---|
| 是「包没带上改动」吗 | ❌ **不是**。当前 HEAD `2f64d1a` 工作区干净，v12 迁移代码齐备（见 §二.0） |
| 真正根因 | 🔴🔴 **译文从来没有写入路径** —— 全仓库只有**一处**会写 `highlight.translation`，就是「我的 → 记忆 → 批量补译」按钮 |
| 定性 | **上一轮实施漏做了方案 B 的一半**。B 写的是「**划线时 / 复习时按需写入**」，我只做了「批量补译写入」，**没做「划线时写入」** |
| 修法 | 补上「翻译浮层 → 划线」携带译文（**零成本**，译文已在手）+ 笔记页加译文展示位 |
| 是否要改 schema | ❌ **不用** —— 列已存在，只补写入与展示两个消费点 |

---

## 一、现象与复现路径

| # | 白哥的观察 | 我的复现路径（读码得出） |
|---|---|---|
| 1 | 划线后**笔记**中没有记录译文 | 长按选段 → 划线 → 笔记页（复习 tab「笔记」）展开该条 → **只有原文 + 笔记，没有译文** |
| 2 | 复习时**没有译文提示** | 进复习 → 划线卡考核态 → **只有首字母骨架**，`translation` 恒为 `NULL` |

---

## 二、根因（三层，全部指向「无写入者」）

### 0️⃣ 先排除「包的问题」

| 检查 | 结果 |
|---|---|
| `git status` | ✅ 干净，HEAD = `2f64d1a`（即 v12 那笔） |
| `user_db.dart` | ✅ `kUserDbVersion = 12`，`oldVersion < 12` 分支在（:353-360） |
| `user_db_schema.sql` | ✅ `highlight.translation TEXT` 在末尾（:605），列顺序与 ALTER 一致 |
| 复习页读取 | ✅ `_HighlightPrompt` 有完整译文渲染逻辑（:668-725） |

⇒ **代码全对，问题在「没有人往里写」。**

### 1️⃣ 🔴 主因：`highlight.translation` **没有生产者**

全仓 grep `setTranslation`，**只有一个调用方**：

```
app/lib/providers/highlight_translate_provider.dart:96:  await repo.setTranslation(h.id, text);
```

而它是「批量补译」按钮的实现。也就是说：

| 写入路径 | 存在吗 |
|---|---|
| 翻译浮层 →「划线记住这段」 | ❌ **不写**（译文被丢弃，见下） |
| 划词菜单 →「划线」（未翻译） | ❌ **不写** |
| 我的 → 记忆 → 批量补译 | ✅ **唯一写入者** |
| 跨设备同步拉回 | ⚠️ 能写，但**云端的值本身也是空的** |

### 2️⃣ 🔴 译文在「翻译浮层 → 划线」这一步被**明确丢弃**

`word_lookup_selection.dart:251-261`：

```dart
Future<void> _translate(String text) async {
  await showTranslationSheet(
    context,
    text: text,
    sourceLabel: widget.highlightSource?.title,
    onRemember: widget.highlightSource == null ? null : () => _enqueueHighlight(text),
    //                                                            ^^^^^^^^^^^^^^^^^^^^^^
    //                            闭包只捕获 text —— 浮层里刚翻译出来的译文**根本没传出来**
  );
}
```

`translation_sheet.dart:44` 的签名是 `VoidCallback? onRemember` —— **不带参数**，所以
浮层即使手上有 `_result.segments`（`translation_sheet.dart:271`），也**没法交给调用方**。
`translation_sheet.dart:318-322` 点「划线记住这段」时只 `Navigator.pop()` + `onRemember!()`。

⇒ 用户**花了额度**翻译出整段（`translation_sheet.dart:102` `translateWithCache`），
点「划线记住这段」后，**译文当场被丢掉**。这既是功能缺口，也是**纯浪费**。

### 3️⃣ 即使写了值，**笔记页也没有展示位**

`highlights_screen.dart` 的 `_HighlightTile`（:286-405）展开态只渲染两样东西：

- `highlight.text`（原文，:299-310）
- `highlight.note`（笔记，:366-380）

**没有任何 `translation` 渲染**。

⇒ 后果放大：**即使白哥点了「批量补译」且成功**，他到笔记页**依然看不到译文**
（只在复习页能看到）⇒ 会误判「补译也失败了」。
📌 这正是本项目判据「**「写了 A 端」≠「B 端会显示」**」的又一实例。

### 4️⃣ 复习页逻辑本身是对的

`review_session_screen.dart:668-725`：有译文 → 中文（`uiSans`·主）+ 骨架（`latinSerif`·次）同显；
无译文 → 只显示骨架，**不占位**。

⇒ 因 1️⃣，`translation` 恒 `NULL` ⇒ 永远走「只显示骨架」分支。
**白哥的观察与代码行为完全一致。**

---

## 三、影响范围

| 面 | 影响 |
|---|---|
| 功能 | 「译文提示」这个能力**对新用户也永不生效**（不是只有老划线没译文） |
| 成本 | 用户为「翻译 → 划线」这一流程**白付了额度**（译文被丢） |
| 数据 | 云端 `sync_highlight.translation` 也全是 NULL ⇒ 多端都是空 |
| 界面 | 笔记页看不到译文；复习页看不到译文提示 |
| 同步/迁移 | ✅ **不受影响**，列与同步链路都已就绪 |

---

## 四、修复方案

### 🟢 方案 ①（推荐 · 补齐缺口 · 零新增成本）

**主路径闭环 —— 让「翻译浮层 → 划线」带上译文。**

| # | 改动 | 文件 |
|---|---|---|
| 1 | `onRemember` 由 `VoidCallback` 改为 `ValueChanged<String?> onRemember`（译文可空）| `widgets/translation_sheet.dart` |
| 2 | 点「划线记住这段」时把 `segments` 拼成译文传出（去空、换行连接，**与补译同一口径**）| 同上 |
| 3 | 调用方 `_translate()` 接收译文 → `_enqueueHighlight(text, translation: t)` | `widgets/word_lookup_selection.dart` |
| 4 | `enqueueHighlight()` 加可选 `translation` 并透传 | `services/highlight_enqueue.dart` |
| 5 | `HighlightRepository.add()` 加可选 `translation`（INSERT 带列 + `ON CONFLICT` 分支**只在有值时覆盖**）| `services/highlight_repository.dart` |
| 6 | 笔记页展开态加译文行（**有值才显示**，退为 `ink2` 以示「提示」性质）| `screens/highlights_screen.dart` |

- **成本**：**零**（译文在点划线之前就已经拿到，且 `translateWithCache` 还可能命中缓存）
- **不违背上一轮的取舍**：这条正是「用户显式翻译过」的动作，**不是**「划线即自动翻译」
- **保留兜底**：直接划线（未翻译）+ 历史划线 → 仍走「批量补译」

### 🟡 方案 ②（方案 ① + 缓存兜底 · 覆盖面更广）

在 ① 之外，**划线时先查本地 `translation_cache`**（`translation_cache.dart:104` `get(rawSource)`）：

```
划线时：
  translation = 显式传入的译文（浮层路径）
             ?? translation_cache.get(normalize(text))   ← 命中则零成本带上
             ?? null                                     ← 留给批量补译
```

- **成本**：仍然**零**（只查本机缓存，不调 LLM、不扣额度）
- **收益**：覆盖「先划线、后又翻译了同一段」这一顺序
- **风险**：低 —— 只是「有就带上」

### 🔴 方案 ③（不建议）：划线时**自动调 LLM 翻译**

- ✅ 任何划线都必有译文
- 🔴 **成本随划线量线性增长**；翻译是订阅权益、**免费 10 次/月** ⇒ 免费用户划 10 条就烧光，
  且**他会以为额度被别的东西吃了**（静默的体验事故）
- 🔴 划线本来是**离线可完成**的动作，加自动翻译后变成「需要网络 + 需要额度」
- ⇒ 与上一轮 `highlight_translate_provider.dart` 文件头写下的理由（「成本可见可控」）**直接冲突**

---

## 五、验证计划（批准后执行）

| 层 | 断言 |
|---|---|
| 纯 Dart | 新增 `verify_highlight_enqueue.dart`：`add(translation:)` 落库正确；`ON CONFLICT` **不覆盖已有译文**（软删恢复场景）；空串/空白 ⇒ 存 `NULL` |
| 纯 Dart | 扩展 `verify_highlight_translation.dart`：浮层路径传入译文后，`byId()` 能读回 |
| 迁移 | `verify_userdb_migration.dart` 不变（不改 schema） |
| 界面 | 笔记页展开态：无译文 → **不渲染**译文行（不占位） |
| 回归 | 跑「引用了改动函数的全部断言」（`mergeHighlight` / `sync_service` / `enqueue`） |
| 证伪 | 人为改坏 3 处（漏传译文 / 覆盖已有译文 / 笔记页无条件渲染）⇒ 必须**精确红 3 项** |

---

## 六、待白哥确认

1. **是否批准方案 ①+②**（推荐）？还是只做 ① ？
2. 你划的那条线，是**从翻译浮层点「划线记住这段」**，还是**直接在菜单点「划线」**？
   —— 前者修 ① 就够；后者才需要 ② / ③。
3. 目前唯一的写入者是「我的 → 记忆 → 批量补译」，你**试过它吗**？
   （若试过且成功，笔记页仍看不到 —— 那是 §二.3 的展示位缺失，一并修）

---

## 附：关键代码位置

| # | 位置 | 现状 |
|---|---|---|
| 1 | `services/highlight_repository.dart:203` `add()` | 🔴 无 `translation` 参数 |
| 2 | `services/highlight_enqueue.dart:44` `enqueueHighlight()` | 🔴 不传 `translation` |
| 3 | `widgets/word_lookup_selection.dart:251` `_translate()` | 🔴 `onRemember` 丢译文 |
| 4 | `widgets/translation_sheet.dart:44,80,318` | 🔴 `VoidCallback` 签名导致译文传不出去 |
| 5 | `screens/highlights_screen.dart:286` `_HighlightTile` | 🔴 无译文展示位 |
| 6 | `screens/review_session_screen.dart:668` | ✅ 逻辑正确（无数据可显示） |
| 7 | `providers/highlight_translate_provider.dart:96` | ⚠️ **唯一**写入者（批量补译） |

---

## 八、实施记录（白哥批「按方案一修」）

### 改动（6 个文件 + 1 处一致性收口）

| 层 | 文件 | 改动 |
|---|---|---|
| **口径** | `services/translate_parse.dart` | 🆕 `translationTextOf(segments)` —— **全仓唯一的拼接口径**（trim + 丢空段 + `\n` 连接；全空 ⇒ `null`） |
| **数据链** | `services/highlight_repository.dart` | `add()` 加 `translation`；**归一化在 Dart 侧**（`trim().isEmpty` ⇒ `null`）；`ON CONFLICT` 用 `COALESCE(excluded.translation, highlight.translation)` —— **只在有值时覆盖** |
| **数据链** | `services/highlight_enqueue.dart` | `enqueueHighlight(translation:)` 透传 |
| **UI 链** | `widgets/translation_sheet.dart` | `onRemember` 由 `VoidCallback?` ⇒ **`ValueChanged<String?>?`**；点「划线记住这段」时把译文算出来传出；`_copyAll` 也改用 `translationTextOf` |
| **UI 链** | `widgets/word_lookup_selection.dart` | `_translate` 接收译文 ⇒ `_enqueueHighlight(text, translation:)` |
| **UI** | `screens/highlights_screen.dart` | 笔记页展开态加译文行（`expanded && hasTranslation`，收起态不塞） |
| **一致性** | `providers/highlight_translate_provider.dart` | 批量补译改用同一个 `translationTextOf` |

### 验证

| 项 | 结果 |
|---|---|
| `verify_highlight_translation.dart` | 45 → **69 项**（新增 §7 UI 链 + §8 真库真调用） |
| `query_verify` **全套 52 个脚本** | ✅ **fail = 0** |
| `analyze_inproc --errors-only` | ✅ **0 error** |
| 人为证伪（改坏 3 处） | ✅ **精确红 4 项**（「ON CONFLICT 覆盖」被**文本 + 行为**两条断言各抓一次），复原后回到 69 绿 · 无残留 |

### 🔴 过程中抓到的三件事（都是「断言/实现写错」，不是猜测）

1. **实现侧真的漏了第三处口径** —— `_copyAll`（复制译文）也在自己 `.map((s) => s.dst)`。
   ⇒ 同一段文字会存出/复制出**两种文本**。**是断言把它抓出来的**（若只做「划线那条路径」的检查，这一处永远发现不了）。
2. **切片锚点写错 ⇒ 假红** —— `between(repo, 'Future<void> add({', '\n  }')`：方法头的 `  }) async {`
   **本身就含 `\n  }`** ⇒ 切片在**参数表结束处**截断、压根不含方法体 ⇒ 3 项假红。
   ✅ 改用「下一个方法的签名」当锚点，并**显式断言切片含 `rawInsert`** ——
   否则锚点一失配，后面的断言会静默变成「永远为假」，而报告上看不出是锚点问题。
3. **注释里的字面量 ⇒ 假红** —— 我在注释里写了 `.map((s) => s.dst` 来解释「为什么不能自己拼」，
   计数断言被**自己的注释**触发。✅ 改为**剥掉整行注释后**再计数（判据：「剥注释只能按整行」）。

### 有意**没做**

- ❌ **不接住「直接划线（没翻过）」的译文** —— 那条路要**自动翻译**，成本随划线量线性增长。
  它仍由「我的 → 记忆 → 批量补译」兜底（成本口径与白哥上轮批的 B+C 一致）。
- ❌ 不改 schema / 不改同步协议（列与链路上一批已就绪）· ❌ 不动服务端。

*2026-10-11 · 调查：读代码 + 读 DDL（未采信文档转述）；实施后：69 项断言 + 全套 52 脚本 + 类型检查 + 证伪*
