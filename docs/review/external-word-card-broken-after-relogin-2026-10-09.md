# 词库外词卡（LLM 生词）「重新登录后打不开」—— 根因与修复方案

> 白哥报告（2026-10-09 20:30，真机截图）：
> 「之前 LLM 生词的卡片在重新登录后显示如图」——
> 复习页 `复习 · 1 / 32`，卡片区显示
> **「这张卡暂时打不开。若一直这样，可能是词库还在准备 —— 返回列表稍后再试。」**
>
> 状态：🔴 **仅调查，未改任何代码**（按项目铁律：先出报告 → 请示 → 审批通过才实施）

---

## 一、直接原因（代码链，逐跳有据）

| # | 位置 | 事实 |
|---|---|---|
| 1 | `screens/review_session_screen.dart:962` | 截图那句文案 = `_CardUnavailable`，**唯一触发条件**是 `cardBundleProvider` 返回 `null` |
| 2 | `providers/review_session_provider.dart:209-252` | 返回 `null` 的四种情形：① 无当前卡 ② `hl:` 解析失败/查不到 ③ **词库未就绪（`load is! WordDbReady`）** ④ **`reviewCardOf(wordId)` 返回 `null`** |
| 3 | `services/word_query_service.dart:293-309` | `cardById()`：先查 `word.db`；查不到 **且** id 以 `ext:` 开头 → 调注入的 `externalCardLoader(spelling)` |
| 4 | `providers/word_db_provider.dart:328-340` | 该 loader **只读端侧 `user.db.external_word_cache`** → 读不到就返回 `null`（**没有任何服务端回落**） |
| 5 | `services/external_word_cache_repository.dart:164-181` | `remove()` / `clear()` **全库没有生产调用者**（grep 已确认）；A3 收敛尚未实施 |

⇒ **`ext:`（词库外）词卡的唯一内容来源，是端侧 `user.db` 里那一行缓存。**

## 二、缓存是怎么没的 —— 🔴 **已确认：重装**（不是换账号）

**白哥 2026-10-09 20:41 确认**：**没换账号**，只是「退出过再重新登录」，**并且重装过**。

⇒ 触发是 **③ 卸载重装**（整个 `user.db` 重建 ⇒ 端侧缓存天然为空）——
**是存量缺口，不是本批「换账号清空」引入的**。这一点很重要：

- 我在初版报告里把 ①「换账号」列为「最可能」，**是错的**（我根据时间线猜的）——
  已按白哥的确认改正。📌 教训：**「最近改了什么」不等于「这次故障的原因」**。
- 本批的「换账号清空」**确实也会**产生同样后果（清单里有这张表），
  只是**这次没走到那条路**。两条路**收敛到同一个修法**（见 §七 A）。

| # | 触发 | 是否本次 | 依据 |
|---|---|---|---|
| ① 换账号 | ❌ 没发生 | `local_data_owner.dart:74-87` 判 `switched` ⇒ 清空清单含本表 |
| ② 注销后重注册 | ❌ 没发生 | 同上（`users.id` 变 ⇒ 视为换账号） |
| ③ **卸载重装 / 清应用数据** | ✅ **就是这个** | 整个 `user.db` 重建 ⇒ 缓存为空；**与任何清空清单无关** |

⚠️ 但清空清单里**仍然**列着 `external_word_cache`（`services/local_data_owner.dart:94-105`），
所以 ①② 那两条路**随时会**复现同一现象 —— 修法必须同时兜住三者（A 做到了）。

## 三、🔴 真正的设计层根因：**「可按需再取」这个前提从来没落地**

已定文档 `docs/design/sync-implementation-assessment-2026-10-04.md:152` 原文：

> | **`external_word_cache`** | ⛔ **不同步** | — | 它是**缓存**不是资产：**词卡可按需向服务端再取**（`/api/generate-card` + 服务端全局缓存）…… |

🔴 **「不同步」的正当性完全建立在「可按需再取」之上 —— 而这半句只在「划词」路径实现了，复习取卡路径没有。**

| 路径 | 端侧缓存未命中时 | 依据 |
|---|---|---|
| **划词**（阅读器里划一个词） | ✅ 会调 `/api/generate-card` → 写缓存 | `services/word_lookup.dart:200-201、264-283` |
| **复习取卡**（复习页打开 `ext:` 卡） | ❌ 直接 `null` → 「打不开」 | `word_db_provider.dart:332` |

⇒ 于是链条变成：**缓存一丢 ⇒ 没有任何路径把它取回来 ⇒ 永久打不开**。
而**服务端其实有内容**（见下节实测），所以这不是"没有数据"，是**「有数据但拿不回来」**。

📌 附带的自相矛盾：`external_word_cache_repository.dart:28` 自己写着
「**硬删** —— 缓存是**可再生**的（重新调一次接口就有）」；
而清空清单把它当**资产**删掉 —— **同一张表在仓库里有两套相反的定性**，谁都没错，因为「再生」那半句没实现。

## 四、实测证据（直查线上库，只读）

`ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4` · `python3 -c 'sqlite3'`（该机**无 `sqlite3` CLI**）

测试号 `690861018@qq.com`（`users.id = b5b3a29d-151f-4330-b293-ee2c9b7b90d5`）：

| 检查项 | 实测 |
|---|---|
| `sync_user_word` 共 45 行，其中 **`ext:` 8 个** | `html` · `AuditReady` · `tokviewer` · `fixtures` · `signup` · `Alice` · `PFEIFFER` · `SACHA`（后 4 个 `deleted=1`） |
| `sync_review_log` 共 136 条，其中 **`ext:` 24 条** | ⇒ 这些词**确实在复习队列里** |
| 服务端全局 `generated_card_cache` | **共 10 行**，`html` / `auditready` / `tokviewer` / `fixtures` / `signup` / `zeppelin` / `apache` / `alice` / `sacha` / `pfeiffer` |
| **该账号 8 个 `ext:` 词的拼写 → 服务端缓存命中** | **8 / 8 全部命中** |
| **`external_word_cache` 是否参与同步** | ❌ 否（`sync_service.dart` 只有 userWords / reviewEvents / articleReads / bookmarks / books / highlights 六类，无此项） |
| `/api/generate-card` 是否需要登录 | ❌ **不需要**（`routes.rs:1394-1397` 明确「除生词表上限外不验证登录态」） |
| `/api/generate-card` 命中缓存时的成本 | **0 次 LLM** —— `llm_card.rs:443-451` ①查全局缓存，命中即 `hit_count++` 返回；`try_cache` 全程不持连接 |

⇒ 🔑 **只要复习页的取卡回落一次服务端，这 8 张卡立刻全部恢复，且不花一分 LLM 钱、不产生新生成。**

## 五、影响范围

**受损**：所有 `ext:` 词卡（`user_word.word_id LIKE 'ext:%'`）。
在端侧缓存丢失后 —— **复习页**永久打不开；**生词本**里「看得见、点不开」；
用户**唯一**的再生手段是回到文章里**重新划同一个词**（`word_lookup` 那条路），而他不会知道要这么做。

**不受损（对照组，正好解释为什么白哥只看到「LLM 生词」这一种卡坏了）**：

| 数据 | 为什么没事 |
|---|---|
| 划线卡（`hl:`） | `highlight` **在同步清单里**（本批新加 `sync_highlight`）⇒ 换账号后能从云端拉回 |
| 词库内词卡（`w…`） | 内容在 `word.db`（App 自带，**只有版本发布才变**）⇒ 清空清单不含它 |
| `translation_cache` | 虽同样被清空，但**有 UI 再生路径**（再点一次翻译就重算）⇒ 自愈 |
| `achievement_unlock` | 清空后由重放状态**重新算**出来（纯函数）|

🔴 **唯一「被清 + 无再生路径 + 云端有内容却拿不回来」的就是它** —— 这正是「换账号清空」引入的新缺口。

## 六、附带发现（顺手记下，都在同一条链上）

1. **文案错误归因**：`ext:` 卡取不到时说的是「可能是**词库还在准备**」——
   可 `ext:` 的语义就是**词库外**，词库再准备一万年也不会有这个词。
   ⇒ 用户按提示「返回列表稍后再试」**永远不会好**。属「**静默失败 + 无出口**」的同族。
2. **`ext:` 词卡被词库就绪门槛挡住**：`review_session_provider.dart:234-236` 的
   `if (load is! WordDbReady) return null;` 在 `ext:` 分支**之后**，
   于是词库首次落盘（31.4 MB / 0.5–2 s）期间，`ext:` 卡也会显示「打不开」而不是转圈
   （对照：划线卡 `hl:` 被**刻意**放在门槛之前，见 `:184-185` 的注释）。
3. **我自己的上一份报告就是共犯**：`docs/review/local-data-ownership-and-cloud-badge-2026-10-09.md:96-97`
   把 `external_word_cache` 列进清空清单时，**没有过「它能不能再生」这一问**。
   `verify_local_owner.dart` 的 55 项断言里，「schema 里的每张用户表都在清单里」这条**通过了** ——
   📌 判据教训：**「schema 完整性断言」保证不了「分类正确」**（它只问"漏没漏"，不问"该不该"）。

## 七、修复方案（4 个，可组合）

| # | 方案 | 改动 | 解决 | 代价 / 风险 |
|---|---|---|---|---|
| **A** ⭐ | **`ext:` 取卡加服务端回落**：`_externalCardLoader` 端侧未命中 → 调 `/api/generate-card`（缓存命中 ≈ 毫秒）→ 转形状 → **写回端侧缓存** → 返回 | 1 处（`word_db_provider.dart:328-340`）+ 1 条断言 | ①②③ **全部**（任何缓存丢失都自愈） | 复习取卡**引入一次网络依赖**：离线时仍打不开（须配 D 的出口）；须设**超时**（2–3 s）避免"取卡卡住"；须防「服务端会现场生成」时把复习页拖 3–5 s |
| **B** | **清空清单里移除可再生缓存**：`external_word_cache`（及 `translation_cache`）**不参与换账号清空** | 1 行（`local_data_owner.dart`）+ 断言/文档同步 | **仅①**（换账号） | 换账号后 B 能看到 A 的「词库外词卡内容」（**只是词典内容，不含行为**）；重装（③）仍失效；**与 §三 的设计前提仍然脱节** |
| **C** | **把 `external_word_cache` 纳入同步**（新增 `sync_external_word`） | 🔴 后端新表 + 端侧 merge/push/pull + 版本协商（六类→七类） | ①②③ + **跨设备可用** | 改动最大；**同步一个"缓存"不是常规做法**，而服务端本就有一份（方案 A 更省）；且它存的是**转换后的形状**，与服务端形状不同（已定文档专门警告过"别混"） |
| **D** | **修文案 + 给出口**：把「打不开」按**真实原因**分流（词库未就绪 →「词库正在准备」并**转圈**；取不到 →「这张卡需要联网重新获取」+ **重试按钮**） | 1 个 widget + `cardBundleProvider` 区分两种 `null` | 不修数据，但**消灭"错误归因 + 无出口"** | 需要一个「重试」的触发点（re-invalidate `cardBundleProvider`）|

### 我的建议：**A + D（必修）**，B **可做可不做**

- **A 是让已定设计（§三「可按需再取」）真正落地**，不是新发明 —— 它一次性把 ①②③ 三条路径全兜住，
  且实测 8/8 命中服务端缓存 ⇒ **零 LLM 成本、零新生成**。
- **D 是安全网**：A 依赖网络，离线时仍取不到；那时必须给**准确的话 + 一个出口**，
  而不是让用户对着「词库还在准备」白等。**无论 A 做不做，D 都该做。**
- **B 可做可不做**：A 落地后"清了也能自愈"，B 就只剩「少一次网络往返」的收益；
  而保留清空能维持「换账号不留痕」的干净语义。**若不做 A，则 B 变成必做。**

---

## 八、裁决与实施（白哥 2026-10-09 20:41 批准）

| 项 | 裁决 |
|---|---|
| **A + D** | ✅ **同意** |
| A 的边界 | ✅ **允许服务端现场 LLM 生成**。白哥问「这个条件是服务端缓存未命中对吧？」—— **对**：① 服务端全局缓存命中 ⇒ 毫秒返回、**0 次 LLM**；② 未命中 ⇒ 才调 LLM（数秒）。实测该账号 8/8 都走 ①，所以 ② 只是**安全网**，日常不会触发 |
| **B** | ❌ **不做**（A 落地后「清了也能自愈」，保留清空能维持「换账号不留痕」的干净语义） |

### 改动清单

| 文件 | 改动 |
|---|---|
| 🆕 `app/lib/services/external_word_card.dart` | **共享取卡器**（纯 Dart）：`resolveExternalWordCard()` = 读端侧缓存 → 服务端（缓存优先）→ 转形状 → **写回端侧缓存**；`ExternalCardUnavailable(message, retryable)`；重试判据 `_retryable(statusCode)`。**转形状 + 文案 + 重试判据的唯一来源** |
| `app/lib/providers/generate_card_provider.dart` | 🆕 `externalCardReplyOf()` —— HTTP 结局 → 共享层的 sealed 类型（**唯一一处映射**，只搬字段不判断） |
| `app/lib/providers/word_db_provider.dart` | `_externalCardLoader`：端侧未命中 → **回落服务端 + 写回缓存**；取不到时**抛** `ExternalCardUnavailable`（带原因） |
| `app/lib/services/word_lookup.dart` | 划词路径改用**同一个**取卡器（消重；UI 的转圈/提示留在原处）|
| `app/lib/providers/review_session_provider.dart` | **D**：`cardBundleProvider` 返回 sealed `CardLoad{CardPreparing / CardMissing(message, retryable) / CardReady}`；接住 `ExternalCardUnavailable`；「词库**打不开**」与「**还在准备**」分开 |
| `app/lib/screens/review_session_screen.dart` | **D**：三态渲染（未就绪 → **转圈**；取不到 → **准确的话** + 可重试时才给「重试」按钮）|
| 🆕 `scripts/query_verify/bin/verify_external_word_card.dart` | **79 项**断言（含「模拟重装」的行为断言）|
| `scripts/tokens_verify/bin/verify_tokens.dart` | 修 **2 条**受影响断言：① `toCardContent` 从 word_lookup 搬走后**假红**（改跟意图走 + 用「扣掉私有助手」的计数法防子串陷阱）② ⑦ 的「读取器吞异常返回 null」**语义已被有意改掉却仍绿**（整文件 `contains('return null;')` ⇒ **假绿**；改为按切片 + 判据与决定一致）|

### 验证（本机实测）

| 项 | 结果 |
|---|---|
| `analyze_inproc`（app/lib） | **error=0 · warning=0** · info=7（全是存量） |
| 🆕 `verify_external_word_card` | **79 项全过** |
| `verify_external_word_cache` / `_generated_card_adapter` / `_word_query` / `_review_list` / `_local_owner` / `_userdb_migration` / `_word_id_convergence` | 全部 EXIT=0（33 / 75 / ✅ / ✅ / 55 / 448 / 46 项） |
| `verify_tokens` | **699 通过 · 8 失败**（= **存量基线，无新增**） |
| **证伪**（4 条，逐条断言了「变红 + 逐字节还原」） | ① 去掉写回缓存 ⇒ 5 条红 ② 回落前插 `return null;` ⇒ 「不能提前 return null」红 ③ 不单独接住 `ExternalCardUnavailable` ⇒ 2 条红 ④ 无条件给「重试」按钮 ⇒ 1 条红 |
| **证伪**（tokens 侧 2 条） | ⑤ 删掉真正的适配器调用 ⇒ 2 条红（**修掉子串陷阱前它不红**）⑥ 读取器又静默 `return null` ⇒ ⑦ 红 |

🔑 **最有力的一条**：新脚本【3】直接**模拟白哥的场景** ——
「端侧缓存空（= 重装后）→ 取卡 ⇒ 联网 1 次 → 第二次 0 次网络 →
**再清空一次 ⇒ 仍能取到卡**」。旧实现在这条上会红（永久打不开）。

### ⚠️ 能力边界的如实标注

- `_externalCardLoader` 在 **Flutter 文件**里 ⇒ 本机跑不了它本身。
  覆盖方式是**两层**：① 新脚本用**与它同形**的接线（真 word.db + 真 user.db + 假生成器）
  做**行为**断言；② 对它的**文本**断言（含「不能提前 `return null`」这条防短路）。
  「文本 + 行为配对」是本项目既定的处理方式（`verify_generated_card_adapter` §5 的注释）。
- 「允许现场 LLM 生成」⇒ 复习页打开一张**两个缓存都没有**的卡时，可能等数秒
  （端侧 HTTP 超时是 60 s）。**实际不会发生**：进了生词本的词必然在服务端缓存里（8/8）。

### ⏳ 下一步

端侧改动 ⇒ **需出包**（不自行部署）：

```
D:\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --dart-define=API_HOST=api.keyievolution.fun
```

*2026-10-09 · 调查：白哥真机报告 → 静态代码链 + 线上库只读实测 → 批准 A+D → 实施 + 79 项断言 + 6 条证伪*
