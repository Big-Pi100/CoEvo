# 阅读进度坐标迁移：`scroll_ratio` → `char_offset`（2026-10-23）

> 白哥 2026-10-23 问答：**「3（进度迁移）不能不做，要做」**。
> 本文只列**改动面与步骤**，未改任何代码。

---

## 一、为什么必须做（一句话）

`scroll_ratio` 是**像素比例**，翻页器的「第 N 页」是**字符切分**的结果 ——
两者不是线性关系，**字号一变、页数就变**，比例会指向完全不同的内容。
翻页阅读器要准确定位，必须存**字符偏移**。

---

## 二、改动面（端侧 7 处 + 后端 3 处）

### 2.1 端侧

| # | 文件 / 位置 | 改什么 |
|---|---|---|
| 1 | `app/assets/sql/book_db_schema.sql` | **4 张表**加列：`book_progress`、`book_progress_pending`、`book_marker`、`book_marker_pending` → `char_offset INTEGER`（**可空**，老数据为 NULL）|
| 2 | `app/lib/services/book_db.dart` | `kBookDbVersion` 5 → **6**；`onUpgrade` 加分支：`if (oldVersion < 6)` 四条 `ALTER TABLE … ADD COLUMN char_offset INTEGER`。🔴 **ALTER 必须在「重跑全量脚本」之前**（v2 踩过：脚本里的索引会引用新列）|
| 3 | `app/lib/providers/book_provider.dart` | 读进度时：优先 `char_offset`，为 NULL 则 `round(scroll_ratio × 本章字符数)` 兜底 |
| 4 | `app/lib/screens/book_reader_screen.dart` | 写入时**两列都写**：`char_offset`（精确）+ `scroll_ratio`（兼容旧读端）|
| 5 | `app/lib/services/ebook/book_marker.dart` + `_repository.dart` | 书签同上；`excerpt` 可以按 `char_offset` 精确截取（现在是按比例估算，会差几十字）|
| 6 | `app/lib/services/ebook/book_progress_sync.dart` | push 带 `char_offset`；pull 认它（缺失则 NULL）|
| 7 | `app/lib/services/sync_merge.dart` | 白名单两处加 `char_offset`：`'book_progress'`（786 行那片）与 `'book_marker'`（808 行那片）|

### 2.2 后端（**需要重新部署**）

| # | 文件 | 改什么 |
|---|---|---|
| 8 | `backend/crates/api_server/src/schema.rs` | `sync_book_progress`（1168 行）与 `sync_book_marker`（约 1275 行）加 `char_offset INTEGER`；配 `ALTER` 兼容老库 |
| 9 | `backend/crates/api_server/src/sync_handlers.rs` | 4 个 struct（147/206/341/383 行）加 `char_offset: Option<i64>`；两处 INSERT 的列清单与 `ON CONFLICT DO UPDATE` 加该列 |
| 10 | 部署 | `cargo build --release` → 传 VPS → 重启（**按项目铁律：先本地验证，再请示部署**）|

---

## 三、兼容策略（关键，决定能不能平滑升级）

| 场景 | 处理 |
|---|---|
| **老库**（`char_offset` 尚不存在）| `onUpgrade` 加列，值 NULL |
| **老数据**（列存在但 NULL）| 读时用 `round(scroll_ratio × 本章字符数)` 换算 —— 近似值，够「跳回大概位置」|
| **首次在新版打开某本书** | 读到 NULL ⇒ 用换算值，**并把换算值写回**（渐进补齐，无需一次性迁移脚本）|
| **老客户端** push 不带 `char_offset` | 后端存 NULL，不报错 |
| **新客户端** pull 到 NULL | 走同一个兜底 |

📌 判据：**加列 + 读时兜底 + 写时双写** = 不需要一次性数据迁移，也不会中途「丢进度」。

---

## 四、翻页器怎么拿 `char_offset`

foliate 的 `relocate` 事件带 **`range`**（当前页的 DOM Range）。取「本页第一个字符」在
该章纯文本里的偏移即可：

```js
// 思路（实现时用一个预置的 Text 节点偏移映射，或 Range.toString() 累计）
const offset = charOffsetOfRangeStart(range, sectionPlainText);
```

⚠️ 这条要在实现时验证：**分页器给的 range 是否跨页稳定**。若不稳定，退而求其次
用 `fraction × 本章字符数`（误差比 `scroll_ratio` 小得多，因为 `fraction` 是**页级**的）。

---

## 五、工程顺序（我建议）

| 步 | 内容 | 可独立验证 |
|---|---|---|
| 1 | 端侧 schema + `onUpgrade` + 断言（4 表加列，老库能升级）| ✅ 单测/断言可验 |
| 2 | 后端 schema + handler + 本地 `cargo test` | ✅ 本地可验 |
| 3 | 端侧读写双写 + 兜底换算 | ✅ 断言可验 |
| 4 | 翻页器接 `char_offset`（真机）| 需真机 |
| 5 | 让白哥批准后部署后端 | 需请示 |

**第 1、3 步不动阅读器也能做完并验证** —— 建议先做这两步，把地基打好，
再接翻页器（否则翻页器一改，进度数据两边都不可信）。

---

## 六、风险

| 风险 | 说明 |
|---|---|
| **后端要重新部署** | 加列是 `ADD COLUMN`（SQLite 支持、无需重建表），但必须重启进程 |
| 老数据精度 | 换算值只在「第一次用新版打开」时用一次，之后被精确值覆盖 |
| 同步协议 | 加字段向后兼容，但**两个版本同时在线**时，老版本 pull 会忽略该字段（无影响）|
| 工作量 | 端侧 ~半天，后端 ~半天，翻页器接入 ~半天（不含真机调试）|
