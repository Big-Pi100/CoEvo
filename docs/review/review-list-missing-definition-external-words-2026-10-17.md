# 【调查报告】复习列表里 LLM 生成的词没有中文释义

*2026-10-17 · 白哥真机截图（`weighin` / `papacy` 无释义，而 `rest` / `lung` / `prognosis` 有）*
*依赖：读端侧代码 · ✅ 2026-10-17 已实施并验证（见 §六）*

---

## 一、根因：**同一个需求有两个实现，其中一个是漏的**

| 场景 | 走哪个方法 | 有没有 `ext:` 回落 |
|---|---|---|
| **卡片页 / 复习会话** | `WordQueryService.cardById` | ✅ **有** |
| **复习列表** | `WordQueryService.firstDefinitionsOf` | ❌ **没有** |

**`cardById`（`word_query_service.dart:293`）**：

```dart
// 先查 word.db（word JOIN card）
if (rows.isNotEmpty) return _cardFromRow(rows.first);

// ── 词库外（合成 id）→ 端侧缓存 ──        ← 🔑 这一段
final spelling = externalSpellingOf(wordId);
final loader = _externalCardLoader;
if (spelling == null || loader == null) return null;
final raw = await loader(spelling);
...
// 🔑 复用**同一个**解析器（`parseCardContent`）—— 别在这里另写一份 JSON 解析
```

**`firstDefinitionsOf`（`word_query_service.dart:504`）**：

```dart
final rows = await _db.rawQuery(
  'SELECT word_id, content FROM card WHERE word_id IN ($ph)',   // ← 只查 word.db
  wordIds,
);
...
final zh = _firstDefinitionZh(raw);     // ← 另一份 JSON 解析
```

⇒ **`ext:` 开头的 id 在 `word.db.card` 里根本不存在** ⇒ 查空 ⇒ 无释义。

---

## 二、机制：LLM 词的内容不在 `word.db`

| | 词库词（`rest`/`lung`）| **LLM 生成的词（`weighin`/`papacy`）** |
|---|---|---|
| `word_id` 形态 | `w…`（真 id）| **`ext:<spelling>`**（`kExternalWordIdPrefix`）|
| 卡片内容存哪 | **`word.db` → `card.content`** | **`user.db` → `external_word_cache.card_content`** |
| 复习列表查得到吗 | ✅ | ❌ **查不到** |

🔑 两处 `content` 的**形状刻意一致**（`generated_card_adapter` 转换时就照 `word.db.card.content` 的
`{front, ipa, entry_type, sections:[…]}` 构造）—— 所以**只差"换个数据源"**，不缺数据。

**白哥说"库里的词是有的"** 也对：卡片页/复习会话走 `cardById`，那条路有 `ext:` 回落。
⇒ 数据在，只是**列表那条取用路径漏了一个分支**。

**为什么表现是"没有这一行"而不是"空白"**：`review_screen.dart:803` 有明确设计——
`if ((row.definition ?? '').trim().isNotEmpty) ...` ⇒ 取不到就**整行不渲染**
（避免"空行读成加载失败 / 占位符读成这个词没释义"）。所以症状是**释义行消失**。

---

## 三、影响范围

| 受影响的词 | 是否受影响 |
|---|---|
| **LLM 生成/词库外词**（`ext:…`）| 🔴 **全部**受影响（复习列表无释义）|
| 词库词（`w…`）| ✅ 正常 |
| 划线卡（`hl:<uuid>`）| ⚠️ **需确认**（`cardById` 也没有 `hl:` 分支；但划线卡的内容来源另有一套，未查证 —— **不猜**）|

其他界面（卡片页、复习会话、划词结果）**不受影响**（走 `cardById`）。

---

## 四、修法（三个选项）

### ⭐ 方案 A（推荐）：给 `firstDefinitionsOf` 补 `ext:` 回落

- 给方法加一个**可选回调** `readExternalContent: Future<String?> Function(String spelling)`，
  由 provider 注入（走 `ExternalWordCacheRepository.contentOf`）
- 命中 `isExternalWordId(wordId)` 时用 `externalSpellingOf` 取拼写 → 读缓存 → 解析首义
- ✅ 仍是**一个方法**（"取释义"保持单入口）；✅ 不动 `cardById`
- ⚠️ 必须**复用同一份 JSON 解析**（见方案 B）

### 方案 B（配套，必做）：把「取首义」下沉成纯函数

现在 `_firstDefinitionZh` 是**另一份** JSON 解析，与 `parseCardContent` 并行 ——
而 `cardById` 的注释自己就写着「**别在这里另写一份 JSON 解析**」。

⇒ 抽 `firstDefinitionZhOf(List<Map> sections)`（纯函数，可断言），两处共用。
📌 判据：**同一件事的口径只能有一处权威**（本项目第 N 次踩到这条）。

### 方案 C（不推荐）：列表改用 `cardById` 逐条取

能得到完整卡，但 200 词 = **N+1 次查询 + 全量解析**，只为拿一行释义 ⇒ 得不偿失。

---

## 五、待白哥定

1. 是否按 **A + B** 修？（我推荐，改动小、口径收敛）
2. 顺手确认 `hl:`（划线卡）在复习列表里**有没有同样问题** —— 要我把这条也查到底吗？

**未改任何代码。** 批准后我实施 + 补断言（正反两例：`ext:` 词能取到、词库词不受影响）+ 证伪。

---

## 六、✅ 实施记录（2026-10-17 · 白哥批「同意（A+B）」+「hl: 也查」）

### 6.1 `hl:`（划线卡）的排查结论：**不属于同一个洞，无需修**

依据三条（都是查到的，不是推断）：

| 证据 | 内容 |
|---|---|
| `Highlight` 模型字段 | `id / sourceType / sourceId / chapterIdx / startOffset / endOffset / **text** / note / createdAt` —— **没有 definition / 释义字段** |
| 复习会话的 `HighlightCardBundle` | 只带 `Highlight` ⇒ 划线卡的**卡面内容 = 原文片段**，复习时是「回忆那段话」 |
| `review_list_query` 的 JOIN | `LEFT JOIN highlight h` 只为拿 `h.deleted` / `h.paused` **两个可见性判据**，不取内容 |

⇒ 划线卡**本来就没有「释义」这个概念**，列表不显示释义是**正常**，不是缺失。
📌 这与 `ext:` 的洞**性质不同**：`ext:` 是「**该有却没有**」，`hl:` 是「**本来就没有**」——
   别为了「看起来一致」给划线卡硬塞一个释义。

### 6.2 B：首义解析下沉为纯函数

`generated_card_adapter.dart`（纯 Dart，零 flutter）新增：

```dart
String? firstDefinitionZhOf(List<Map<String, Object?>> sections)
```

- 取 `type == 'definition'` 中 **`order` 最小**那条的 `zh`（不是数组第一条）
- 缺段 / 缺字段 / 类型不对 / 空串 ⇒ **`null`**（让调用方能区分「没有」与「空」）
- 🔴 `WordQueryService._firstDefinitionZh` **已删** —— 它是与 `cardById` 并行的**第二份 JSON 解析**
  （而 `cardById` 的注释早就写着「别在这里另写一份 JSON 解析」）
- 现在：**解析只有 `parseCardContent` 一处，取首义只有 `firstDefinitionZhOf` 一处**

### 6.3 A：`firstDefinitionsOf` 补 `ext:` 回落

```dart
Future<Map<String,String>> firstDefinitionsOf(
  List<String> wordIds, {
  Future<String?> Function(String spelling)? readExternalContent,   // 🆕
})
```

- ① 词库词（`w…`）→ `word.db.card`（原逻辑）
- ② 词库外词（`ext:<spelling>`）→ **注入的读取器**（`user.db.external_word_cache`）
- 单条失败**不影响其它词**；传 `null` ⇒ 退回修复前行为（渐进）
- `review_list_provider` 注入：
  `readExternalContent: (sp) => ExternalWordCacheRepository(db).contentOf(sp)`

### 6.4 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | **error=0 / warning=0** |
| `verify_review_list` | **84 项**（71 → +13，新增 ⑨ 行为断言 + ⑩ 真值表/接线）|
| `verify_generated_card_adapter` | 75 项 |
| `verify_external_word_card` | 79 项 |
| `verify_word_query` | ✅ |
| `tokens_verify` | ✅ |

**⑨ 组是行为断言**（不是源码断言）：造**真实最小 `word.db`**（`card` 表）+ 注入假 `external_word_cache`，
用 `WordQueryService.open(factoryFfi, path, externalCardLoader: …)` 真跑一遍：
- ⑨-1 词库词取到**首义**（按 `order` 最小）
- ⑨-2 🔴 `ext:` 词也能取到（本次修复的核心）
- ⑨-3 缓存里没有的词 ⇒ 不出现（不是空串）
- ⑨-5 不传回调 ⇒ 退回修复前行为

🔴 **证伪 ×3，全部精确命中**：
- 砍掉 `ext:` 分支 ⇒ ⑨-2 红
- 首义判定改成「取数组最后一条」⇒ ⑨-1/2/5 红
- provider 不注入读取器 ⇒ ⑩-8 红

⚠️ **证伪第一次跑时 B「没红」** —— 因为我的测试数据里「order 最小的那条」恰好也是**数组最后一条**
⇒ 「取最后一条」这个错误实现**也能拿到正确值**。是真·假绿。
已改成**三条 definition 的顺序与 order 全不一致**（正确值夹中间），
使「取第一条」「取最后一条」各自拿到不同错值 ⇒ 只有真按 `order` 比较才绿。
📌 判据：**证伪必须真能红** —— 不红时先怀疑「测试数据的区分度」，而不是「顺手放过」。
