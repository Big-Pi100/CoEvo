# 端侧查询层验收（`scripts/query_verify/`）

## 为什么存在

**Phase 1 #11** 的原定性（「替代 `word_bank.rs` 全表扫」）经调查**不成立** ——
`match_text()` 是死代码、`word.db` 索引早已齐备、划词也不走后端。
真实缺口是 **端侧完全没有 DB 能力**（详见 `docs/design/word-query-indexing-audit-2026-09-26.md`）。

白哥 2026-09-26 定案：**方案 A**（拆出可验证的查询层）+ **跨库方案「冗余 spelling」**。
本目录是该查询层的**验收套件**。

## 怎么跑

```bash
cd scripts/query_verify
DART=/d/flutter/bin/cache/dart-sdk/bin/dart.exe

$DART pub get --offline              # 必须 --offline（联网版会卡到超时）

$DART run bin/verify_word_query.dart    # word.db 侧（42 项）
$DART run bin/verify_review_list.dart   # user.db 侧（37 项）
$DART run bin/query_probe.dart          # 可行性探针（最小验证，便于排查）
$DART run bin/bench.dart                # 稳态性能基线
```

- **退出码 0 = 全通过；1 = 有失败** → 可挂 CI
- **`verify_review_list.dart` 会直接执行 `app/assets/sql/user_db_schema.sql`** ——
  所以「schema 文件写错了」会在这里暴露，而不是等到真机运行时
- 两个 `verify_*` 都**相对导入 app 的真实源码**：
  `import '../../../app/lib/services/word_query_service.dart';`
  → 验证的是**实际要发布的实现**，不是副本

## 🔑 为什么能在本地跑（这是设计的核心收益）

`app/lib/services/word_query_service.dart` 与 `review_list_query.dart`
**只 import `package:sqflite_common/sqlite_api.dart`（纯 Dart 接口）**，
**不 import 任何 Flutter 包** → 可以注入 `databaseFactoryFfi` 在纯 Dart 下跑**真库**。

```dart
// 生产（App 内）：注入 Flutter 的 databaseFactory
final svc = await WordQueryService.open(databaseFactory, wordDbPath);

// 验收（纯 Dart）：注入 ffi 实现
sqfliteFfiInit();
final svc = await WordQueryService.open(databaseFactoryFfi, r'E:\CoEvo\data\word.db');
```

厂商相关性只落在**工厂注入**这一个点上，查询逻辑本身零框架依赖。

## 验收覆盖

### `verify_word_query.dart`（word.db · 42 项）

| # | 组 | 覆盖 |
|---|---|---|
| 1 | 库结构与规模 | `word` 表 11,523 条 |
| 2 | **查词** | 命中 · spelling/cefr/ipa · 段存在性 |
| 3 | 大小写 | `COLLATE NOCASE`：`RECEIVE` / `ReCeIvE` 均命中且同 id |
| 4 | **★ 词形还原** | `received → receive` · `isLemmatized` · `query` 保留原输入 |
| 5 | 未命中 | 未命中 / 空串 / 空白串 / `analyzeForm` 未命中 |
| 6 | **防注入** | `' OR '1'='1` · `'; DROP TABLE` → 均返回 null，表未损 |
| 7 | **卡片段** | 段类型白名单 · `definition` ≤1 · **无 `sense`** · `root` 排第一 · `root` 段可点击 |
| 8 | **聚合页入口** | 有入口 · 成员带**分拆法** · 「有内容但无入口」不报错 |
| 9 | **只读约束** | `INSERT` 被 `readOnly: true` 拒 · 词条数不变 |
| 10 | **性能** | 首查 vs 稳态 · 未命中不退化 |
| 11 | 词组 | `traffic jam`（含空格）· 多余空白规范化 |

### `verify_review_list.dart`（user.db · 37 项）

| # | 组 | 覆盖 |
|---|---|---|
| 1 | **schema 可执行** | 执行 `user_db_schema.sql` · `spelling` 列 + NOT NULL · `idx_crs_spelling` |
| 2 | 写入/读回 | `upsertState` · `stateOf` · `count` |
| 3 | **三档排序** | 记忆曲线 / **最近** / A–Z |
| 4 | **排序白名单** | 非法 `order` 回退（不执行注入） |
| 5 | **按单词搜索** | 前缀匹配 · NOCASE · trim · 空搜不筛 |
| 6 | **`LIKE` 转义** | 搜 `%` / `_` 按字面匹配（不当通配符） |
| 7 | 计数与分组一致 | `dueCount` == 分组 due 数 · 总和不丢项 |
| 8 | **约束** | 缺 `spelling` 被拦 · `rating=9` 被 CHECK 拦 · `review_log` 幂等键 |
| 9 | 分页 | `limit`/`offset` · 两页无重复 |
| 10 | 性能 | 5,004 条下的四类查询 |

## 性能基线（Windows 桌面 FFI，**不代表 iOS 真机**）

### word.db（11,523 词 / 31 MB）

| 指标 | 数值 |
|---|---|
| 打开（含冷启动） | 40 ms |
| **首查（冷）** | **~2 ms** |
| 查词（稳态）p50 | **937 µs** |
| 未命中 p50 | 317 µs（**不退化** → O(log n)） |
| 完整链路（Python 口径） | 43 µs |

### user.db（5,004 条）

| 指标 | 数值 |
|---|---|
| 到期计数 p50 | **103 µs** |
| 列表（记忆曲线）p50 | 278 µs |
| 列表（A–Z）p50 | 247 µs |
| 搜索 p50 | 295 µs |

> ⚠️ **解读三点**：① **必须区分「首查 vs 稳态」**（首查含 FFI 初始化）；
> ② **这是桌面 FFI 数值，不是 iOS 性能承诺**；③ Dart/FFI 比 Python `sqlite3` 慢 3–8 倍
> （FFI 调用与数据编解码开销），**绝对值仍远低于 100 ms 感知阈值**。

## ⚠️ 本轮验收抓到的两个真问题（都靠断言发现）

### 1. 「最近」排序用 `COALESCE` 是错的

原实现 `ORDER BY COALESCE(last_review_at, updated_at) DESC`。
**反例**：一个**刚加入但上次复习较早**的词 → `last_review_at` 非空 →
`COALESCE` 取到那个较早时间 → 被排到很后面，**与「最近加入」语义相反**。

✅ 已改为 `ORDER BY updated_at DESC`（`updated_at` 在插入与更新时都刷新，
正好同时覆盖「加入」与「复习」两种事件）。
**验收里专门留了一条断言锁住它**（`🔑 刚更新但上次复习很早的词排第一`）。

### 2. `sqflite` 的 `singleInstance` 默认 `true`（隐蔽陷阱）

同一路径二次 `openDatabase` 会返回**同一个 `Database` 实例** →
此处的 `close()` 会**连带关掉别处持有的连接**（实测报 `database_closed`）。

```dart
// 需要独立连接时必须显式关掉单例
factory.openDatabase(path, options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
```

**对生产的意义**：`word.db` 与 `user.db` 应各自**只打开一次**并复用
（本层用「注入工厂 + 持有单个连接」的形态，天然规避）。

## 相关文档

| 文档 | 内容 |
|---|---|
| `docs/design/word-query-indexing-audit-2026-09-26.md` | #11 调查报告（原定性错在哪 / 真实需求 / 性能实测） |
| `app/lib/services/word_query_service.dart` | 查词 / 词形还原 / 卡片 / 聚合页入口 |
| `app/lib/services/review_list_query.dart` | 复习列表 / 搜索 / 三档排序 / 分组 |
| `app/assets/sql/user_db_schema.sql` | user.db schema（v1.1 含冗余 `spelling`） |
