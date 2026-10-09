# CI 两个 job 红 · 根因与修复方案（2026-10-09）

> 触发：白哥问「CI 全绿了吗」
> 结论：**未全绿** —— 11 个 job 里 **6 ✅ / 2 🔴 / 3 ⏭️**
> 🔴 **本报告同时纠正我自己的一个错误判断**：我上一条把这两处红称作「存量基线」——**不对**。

## 一、实测状态（commit `f40715af`）

| job | | 失败 step |
|---|---|---|
| Frontend (Flutter) | ✅ | |
| IAP Verify | ✅ | |
| **Backend (Rust)** | ✅ | **已由 `f40715a` 修复**（`fmt --check` + `clippy -D warnings` 两道）|
| **Query/DB Verify (sqflite ffi)** | 🔴 | step 45 `书架上云端侧` = `verify_book_cloud.dart`（step 1–44 全过）|
| **Pure Dart Verify (trace + wiring)** | 🔴 | step 12 `tokens_verify` = `verify_tokens.dart`（该 job 的最后一步）|
| Ebook / FSRS / Native Readiness | ✅ | |
| Backend Release / iOS Build / Deploy | ⏭️ | **条件 job**（10-07 那次同样 skipped，非本次引入）|

## 二、🔴 先纠正我自己的判断：这**不是**「存量基线」

| | 10-07 那次（`e3cf235b`） | 现在 |
|---|---|---|
| 全绿情况 | **11 个 job 全绿** | 2 红 |
| `tokens_verify` step | **存在且 success（688 项）** | **707 项 / 8 红** |
| `Query/DB Verify` 的 step 数 | **39 步，没有「书架上云端侧」** | **51 步**，含该步且红 |

⇒ 两处红都是 **10-07 之后**出现的：`verify_book_cloud` 这个 **step 本身是后加的**；
`tokens_verify` 是**断言被重构甩下了**。

> 🔑 **判据：判断「是不是存量」，必须找到上一次全绿的那个 commit 逐项比对**，
> 不能凭「我记得它一直红」。我这次就是凭印象下的结论 —— 被实测推翻。

## 三、`tokens_verify` 8 红：断言跟「文件 / 字面量」走，没跟**意图**走

根因：**2026-10-08 白哥定案的「复习 tab 双段结构」重构**
（`review_screen.dart` → 拆出 `review_tab_screen.dart`（容器：双标题 + 两段切换）+ `review_section.dart`），
外加把 SQL 抽成**共享常量**。逐条落地（**9 条断言，8 红**）：

| # | 失败断言 | 现在的实址 | 意图 |
|---|---|---|---|
| 1 | `list/count/dueCount 三条都 LEFT JOIN user_word（应 ≥3）` | `review_list_query.dart:77` `static const String _joins`（共享常量 ⇒ 字面量 1 处）| ✅ **仍在**（形态更好）|
| 2 | `三条都过滤「已暂停」（应 ≥3）` | 同文件 `_visibilityWheres` L91-92（共享常量）| ✅ 同上 |
| 3 | `🔴 筛选用公共组件 HeaderChip` | `review_tab_screen.dart:135` | ✅ |
| 4 | `暂停走仓储的 pause（软删）` | `review_screen.dart:208` → 改为 `(await ref.read(userWordProvider.future)).pause(id)` | ✅（改走 provider）|
| 5 | `🔴 复习页传了 active:` | `review_tab_screen.dart:137` `active: ref.watch(reviewDueOnlyProvider)` | ✅ |
| 6 | `🔴 复习页传了 labelReserve: _filterChipReserveLabel` | `review_tab_screen.dart:141` | ✅ |
| 7 | `🔴 参照文案 = '已到期'` | `review_tab_screen.dart:151` | ✅ |
| 8 | `🔑 暂停：bump 在 repo.pause 之后` | pause@208 → `revision.bump()`@220 | ✅ **顺序仍对** |

两类口径问题：

- **#3–#8 读的是单文件**：`src()` 只读 `app/lib/<一个文件>`，而代码被拆到**三个文件** ⇒ **集体变红**。
- **#1/#2 要求「字面量 ≥3 处」**：🔴 **这条方向本身就是错的** —— 它要求**三份重复的 SQL**，
  而「抽成共享常量」正是我们一直提倡的「**一处定义**」。
  ⇒ 这条断言**会反向驱动实现**（为了让它变绿，把常量展开回三份），属「**断言保护错误**」的家族。

## 四、`verify_book_cloud` 1 红：**夹具没跟上 2026-10-09 的口径变更**

```
L173  await CloudBookRepository.mergeCloudBooks(db, [cb('h-cloud-only', '只在云端')]);  // ← 没传 blob ⇒ blobSize = 0
L175  check('只有云端 ⇒ cloudOnly', p2['h-cloud-only'] == CloudPresence.cloudOnly);
```

而 `presenceByHash` **2026-10-09 有意改成只认 `blob_size > 0`**
（`cloud_book_repository.dart:192-223`，配套后端「订阅到期满 30 天清文件**但保留行**」）
⇒ `blob_size = 0` 的行**不再算「云端有」**。

夹具签名 `CloudBook cb(String h, String t, {int blob = 0})` —— **默认 0**。
同段其它用例都显式传了 `blob:`（`h1`=100 / `h2`=200），**只有这一条漏传**。

⇒ **不是功能回归，是夹具漏参数。**

## 五、🆕 顺带发现一个真实缺口（比修红更重要）

`blob_size > 0` 这个 2026-10-09 的新口径，**目前在断言里没有任何正向用例**：

> 「云端文件被清理（`blob_size = 0`、行还在）⇒ **不该显示云图标**、且**应重新进入待上传**」

—— 这条**静默失败防线**正是那次改动的**唯一目的**（否则：书架显示「云备份」→ 点下载 → 404，全程无报错），
但**没有断言守着**。⇒ 修复时必须**补上**，否则那次改动等于**没有防线**。

## 六、修复方案

### 方案 A ⭐（推荐）—— 断言跟**意图**走；**不改** `app/lib` / `backend`

1. **`verify_tokens`**：把 `page` / `review` 的**读取面**从单文件改为**同族文件集合**
   （`review_screen.dart` + `review_tab_screen.dart` + `review_section.dart`）
   —— **断言名与判据一字不改**，只改「读哪些文件」（正是既有判据「断言跟意图走、不跟文件走」的修法）。
2. **#1/#2 判据反转**为「**一处定义 + 三条查询都引用**」：
   锁 `_joins` / `_visibilityWheres` **各定义 1 处**，且 list / count / dueCount **三条 SQL 都拼它**。
   （方向从「要求重复」反转为「要求复用」。）
3. **#4/#8**：pause 的定位**不再依赖字面量 `repo.pause(`**，改为锁「pause 调用 → `revision.bump()`」的**数据依赖**
   —— ⚠️ 遵守既有判据「**文本顺序 ≠ 求值顺序**」，不比位置字符串。
4. **`verify_book_cloud`**：L173 夹具补 `blob: 300`（**原断言保留**）
   **＋ 新增**一条锁新口径：`blob_size = 0` ⇒ 不算云端有（不进 `presence`，**且进 `pendingUploadHashes`**）。

### 方案 B：删掉/降级这 9 条 ❌
会丢掉「暂停过滤三条一致」「筛选药丸共用同一组件」「云图标三态」这些**真实防线** —— 不采纳。

### 边界与硬要求
- 改的全是**验收脚本**（`scripts/`），**不动 `app/lib` / `backend`** ⇒ **不影响出包、不需重新部署**。
- 🔴 必须**逐条证伪**（注入回归 ⇒ 必须变红 ⇒ 逐字节还原），否则就是「**为了让 CI 变绿而改断言**」——
  这正是项目明令禁止的反模式。本次正当性来自 **§三 已逐条实测「代码侧意图仍满足」**，**不是**「红了就改」。

## 七、请示

**要我按方案 A 修吗？**（改 2 个脚本 + 补 1 条新断言；本地全验 + 逐条证伪后 push，再看 CI 结果）

---

*2026-10-09 · 方法：GitHub API 逐 job/step 比对（含 10-07 全绿那次）→ 本地复现（8 红 / 1 红，与 CI **逐条一致**）→ 逐条 grep 目标串的现址*
