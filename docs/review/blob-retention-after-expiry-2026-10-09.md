# 云端备份保留策略：订阅到期满 30 天清理（2026-10-09）

> 白哥：「**云端备份应该在订阅到期后一个月后清除释放**」
> 前置：真机测试已 OK（试用账号退役那批）。
> ⚠️ **代码已完成并本地验证；后端尚未部署**（按铁律需单独批准）。

---

## 一、做了什么

订阅**到期满 30 天**后，清掉该账号占用的云端电子书文件（释放磁盘），
并把服务端的 `blob_size` 归零（配额随之退还）。

| 层 | 改动 |
|---|---|
| 后端 | 🆕 `maintenance::purge_expired_blobs`（每 5 分钟随调度器跑）· 常量 `BLOB_RETENTION_DAYS_AFTER_EXPIRY = 30` · 5 条单元测试 |
| 端侧 | `cloud_book_repository` 的**两处**「云端有没有这本书」判据改为 `blob_size > 0`（见 §三）|

---

## 二、🔴 三个必须守住的点（每一个写错都**不会报错**，只会错得很安静）

| # | 约束 | 写错的后果 |
|---|---|---|
| 1 | **不动 `sync_book.deleted`** | 端侧 `mergeCloudBooks` 把 `deleted` 读成「别端删了书」⇒ **把用户本地的书删掉**（真·数据丢失）|
| 2 | **只把 `blob_size` 置 0，不删 `sync_book` 行** | 行是「云端记录」，端侧还要靠它认书；删行等于这本书凭空消失 |
| 3 | **先删文件，再置 `blob_size = 0`** | 反过来的话：中途失败会留下「`blob_size = 0` + 文件还在」，而筛选条件是 `blob_size > 0` ⇒ **永远不再命中它** ⇒ **文件永久残留**，而配额看着是空的 |

🔑 顺序 3 的收益是**幂等可自愈**：先删文件、归零失败 ⇒ 下轮仍被选中 ⇒ 重新 `purge_user`
（返回 0 字节，文件已没了）⇒ 再归零 ⇒ 收敛。已有一条测试专门模拟这个中间态。

### 安全边界（都有测试）

- 到期 **29 天**：不删（保留期是**反悔窗口**，不是「到期就删」）
- **从未订阅**（`subscription_expires IS NULL`）：不删 —— 「取反」不能当「到期」的判据
- 订阅**仍有**效（未来日期）：不删
- 日期**解析不出来**：不删（`date()` 返回 NULL ⇒ 比较为假 ⇒ 安全侧）
- 起算点 = **`subscription_expires` 那天**，不是「我们发现他到期那天」；第 31 天起清

---

## 三、🔴 连带发现：口径在两处文档里都写着了，实现两处都没跟上

后端 `sync_handlers.rs` 的 `BookOut` 文档：

> 「**`blob_size` 是端侧判断「云端有没有这本书」的**唯一依据**：`> 0` ⇒ 云端有
>  ⇒ 本地没有时可显示「云端」并允许下载。**」

端侧本地表 `cloud_book.blob_size` 的列注释：

> 「云端**实际存储**的字节数。⚠️ **`0` = 服务端没有这个文件**（只有元数据）」

**但实现两处都不是这么判的** —— `presenceByHash` 与 `pendingUploadHashes` 用的是
「`cloud_book` **有行**」。此前看不出差别，因为「有行」与「有文件」一直同步。
**2026-10-09 起不同步了**（清理只把 `blob_size` 归零、行留着）⇒ 若不改，会出现两个**静默失败**：

| 不改的后果 | 用户看到什么 |
|---|---|
| 书架仍显示「云端有」 | 点下载 → `404 这本书在云端没有文件`（没有任何地方报错）|
| 待上传判据仍按「有行」 | 云端被清后本地书**永远不再重传** ⇒ 用户重新订阅了，备份也**再也回不来** |

⇒ 两处**必须一起改**（同一件事的口径只能一处权威；只改一处 = 两处判断分叉且都不报错）。

---

## 四、验证

| 项 | 结果 |
|---|---|
| 后端 `cargo test -p api_server` | **270 → 275 通过 / 0 失败**（新增 5 条：窗口边界 / NULL 与未来 / 行与 `deleted` 不变 / 幂等 / 自愈中间态）|
| 后端 `cargo fmt --check` | ✅（先挂了一次 —— 我的新代码没按 rustfmt 排，已 `cargo fmt -p api_server` 修好）|
| 端侧 `analyze_inproc` | **error=0 / warning=0**（170 文件）|
| `verify_reading_tab`（ebook_verify）| **78 → 94 项全绿**（新增 16 条）|
| 其余断言 | auth 96 · feed 71 · share 87 · sync 62 · review 23 · reading 60 · forgot 60 · iap 165 —— 全绿 |
| `tokens_verify` | 690/8（存量红，与基线一致）|
| **逐条证伪** | **8 条注入全部变红、恢复后零红** |

### 🔴 证伪抓到**两条假绿**（都改掉了，值得记）

1. **「不得改 `deleted`」那条**：初版写 `!purgeFn.contains('deleted')` ⇒
   **假红**（筛选 SQL 里的 `deleted_at IS NULL` 含子串 `deleted`）。
   📌 又一次「**子串断言要考虑被撞的车牌**」（同族：`token`/`tokens`、`title:`/`subtitle:`）。
   ⇒ 改成精确到赋值形态（`SET deleted` / `deleted = 1`）。
2. **「任务已接进调度器」那条**：初版写 `maint.contains('purge_expired_blobs(&conn')` ⇒
   **假绿**（同文件的**单元测试里还有 7 处** `purge_expired_blobs(&conn` 调用）。
   ⇒ 改成「切出 `run_scheduler_inner` 函数体，在**切片内**断言」。
   📌 判据原样复用：**子串断言锁不到「接线」**（`contains` 只证明「文件某处有」）。

### 🔴 还有一个更根本的坑：**切片锚点不能落在文档注释上**

`_stripComments` 会把 **`///` 文档注释整行删掉** ⇒ 拿文档注释当切片终点，
`_between` 会**静默退化成「切到文件尾」**，于是下游的 `contains` 断言把
**测试代码**也算了进去（那正是假绿 #2 的成因）。
⇒ 现在所有新切片锚点都用**代码行**（`fn run_scheduler_inner(` / `pendingUploadHashes(` + `}`），
并且每个切片都配了**越界哨兵**：`check(!slice.contains('mod tests'))`。

---

## 五、🔴🔴 部署**之后**才发现的致命缺口（已修，待重新部署）

部署完成、逐条验收通过之后，我在做「端侧能不能感知到这次清理」的连带核查时，
发现**功能其实不会生效** —— 而当时所有验收项都是绿的。

### 缺口

`sync_handlers::pull_changes` 的书单查询是**增量**的：

```sql
SELECT content_hash, title, ... , blob_size, ...
  FROM sync_book
 WHERE user_id = ?1 AND received_at > ?2
```

时间轴是 **`received_at`**（服务端收货时刻），**不是** `updated_at`。

而 `purge_expired_blobs` 第一版只写了：

```sql
UPDATE sync_book SET blob_size = 0 WHERE user_id = ?1 AND blob_size > 0
```

**没有推进 `received_at`** ⇒ 端侧的 pull（`received_at > since`）**永远拉不到这次归零**
⇒ 本地 `cloud_book.blob_size` 仍是旧值 ⇒ 书架仍显示「云端有」⇒ 点下载 **404**。

### 为什么验收没抓到它

| 验收项 | 为什么它抓不到 |
|---|---|
| 路由探针 / 二进制特征串 | 只证明「代码在二进制里」 |
| `cargo test`（当时 275 项） | 测试造的数据 `received_at` 固定，**没有从 pull 的角度验** |
| 端侧断言（`blob_size > 0`） | 只锁了「判据怎么写」，**没锁「端侧能不能拿到新值」** |
| 只读 SQL 预演 | 验的是**筛选**（谁该被清），不是**传播**（清完之后别人知不知道） |

⇒ 📌 判据：**「改了 A 端」≠「B 端会看到」** —— 必须**跟完整个数据流**，
不能停在「我的函数把它写进库了」。

### 既有代码里其实早有正确先例

`book_blob_handler::set_blob_size` 的文档写着：

> 「上传成功后记账：写入 `blob_size` 并**推进 `received_at`**。」
> 「🔑 为什么必须推进 `received_at`：它是 pull 的时间轴。」

删除端点归零时也走它（注释：「其他设备据此知道『云端没有了』」），
并且有测试 `test_set_blob_size_advances_received_at`。

⇒ 我在 `purge_expired_blobs` 里**自写了一条裸 UPDATE，绕过了这个既有权威函数** ——
这正是「同一件事的口径只能一处权威」的反例：约束在两处重复，漏掉的那一处**不会红**。

### 修法（把口径收回一处）

- `book_blob_handler` 新增 `zero_blob_sizes_for_user(conn, uid, received_at)`（按用户批量），
  与 `set_blob_size`（按 `content_hash` 单条）**并列在同一模块** ⇒
  「写 `blob_size` 必须一并推进 `received_at`」这条约束改一处时另一处就在眼前
- `now_ms()` 提为 `pub(crate)`（格式 `%Y-%m-%dT%H:%M:%S%.3fZ`，与上传/删除**逐字节一致**）
- `purge_expired_blobs` 改为调用它；本轮统一用**一个**时间戳

### 新增两条防线（都已证伪）

1. **`test_blob_purge_advances_received_at_for_pull`** —— **直接模拟 pull**：
   拿清理前的时刻当 `since` 查一次，必须能看到那一行。
   ⚠️ 断言刻意**不是**「`received_at` 变了吗」—— 那只证明字段被写了；
   若格式写错（比如退化成 `YYYY-MM-DD`），字符串比较下 pull 仍会漏 ⇒ 只查「变了」会**假绿**。
2. **`test_purge_does_not_write_blob_size_directly`** + **`ebook_verify` ③ 组**
   —— 锁「本函数体内不得自写 `SET blob_size`」。

### 顺带又一次「文本断言」教训

第 2 条测试**第一次是假红**：`purge_expired_blobs` 的**注释**里为了说明这段历史，
写了「自写的裸 `UPDATE ... SET blob_size = 0`」⇒ 被文本判据命中。
⇒ 修法：**先剥整行注释再判**（项目判据「剥注释只能按整行」）。
📌 **「解释这件事的文字」会被当成「这件事本身」** —— 这就是文本断言必须先剥注释的原因。

---

## 六、🔴🔴 第二个缺口（同一层：端侧能不能**看到**）

修完上一条、复核端侧整条链路时又发现一处 —— 而且**它会让上一条的修复也白做**。

### 链路逐层核实

| # | 环节 | 状态 |
|---|---|---|
| 1 | 后端清理：`blob_size = 0` **且** `received_at` 推进 | ✅ 上一条已修 |
| 2 | pull 按 `received_at` 增量取到该行（含 `blob_size`） | ✅ 既有实现正确 |
| 3 | 端侧 `mergeCloudBooks`（`ConflictAlgorithm.replace`）写本地 | ✅ |
| 4 | `presenceByHash` 按 `blob_size > 0` 判 | ✅ 本批已改 |
| 5 | **界面重算** | 🔴 **断了** |

### 断在哪

`cloudPresenceProvider` 是 `FutureProvider`（**非 autoDispose**），只在
`bookDbRevisionProvider` 变化时重算。而全库 `bump()` 的调用点只有：

> 书架页（下载完成 / 删书）· 阅读器（进度）· 导入流程 · 划线 / 查词

—— **没有一处是「同步之后」**。`sync_service` 落库后不 bump，`_runSync` 也只更新同步状态。

⇒ 后台同步拉回的变更**写进了库，界面不刷新**。用户打开 App → 自动同步 →
进书架页 → 读到的仍是缓存里的旧 presence ⇒ **书架仍显示「云端有」⇒ 点下载 404**。
要等一个**与同步无关的动作**（下载一本书 / 划一条线 / 查一个词）才碰巧刷新。

### 修

`_runSync` 在 pull 之后 bump 两个 revision：

```dart
if (!pushOnly && report.pulledTotal > 0) {
  ref.read(userDbRevisionProvider.notifier).bump();
  ref.read(bookDbRevisionProvider.notifier).bump();
}
```

- **两个都 bump**：pull 同时写 `user.db`（生词/复习/划线/阅读记录）与 `book.db`（书单/书进度）
- **`!pushOnly`**：登出前 flush / 进后台**只推不拉** ⇒ 不必刷
- **`pulledTotal > 0`**：没拉回东西就不白刷

📌 判据：**「写端逐个通知读端」是必漏结构** —— 要让读端 watch 一个 revision
（`bump()` 早就存在，只是一直没人调）。

### 顺带揪出：`pulledTotal` 漏了两项（**会让本次修复静默失效**）

`pulledTotal` 是「本轮本地库变了没有」的**唯一依据**（`isEmpty` / bump 判据 / 状态面板都靠它），
但它**漏了 `pulledBooks` 与 `claimedBooks`**（「书架上云」之后新加的两项，getter 没跟）。

后果**恰好落在本功能上**：清理只产生 `pulledBooks` 一项变更 ⇒ `pulledTotal == 0`
⇒ `isEmpty == true`（日志不打）⇒ **bump 判据为假**（界面不刷）。
⇒ 若只加 bump 而不修 `pulledTotal`，**修复会静默失效** —— 这正是「判据口径差一层，不报错只给错数」。

同时发现 `sync_status_provider` 里写着 `pulledTotal + claimedBooks` ——
那是**调用方自己打的补丁**（说明作者当时也发现漏了，但只在用到的那个地方补）。
⇒ 按判据「**补丁 ≠ 修法**」：补全 `pulledTotal` 本体，并**撤掉补丁**（否则双计）。

### 验证

- `verify_sync_service`：**59 → 69**（新增【9】组，**直接调 getter** 逐项验 ——
  7 个字段各 +1，以及「只拉回书单变更 ⇒ `isEmpty` 必须为 false」）
- `verify_sync`：**62 → 65**（新增 3 条**接线**断言，锁到具体表达式）
- **三组注入逐条证伪**：删两行 bump / 去掉 `!pushOnly &&` / `pulledTotal` 去掉两项
  ⇒ 对应断言全部变红，恢复后零红

---

## 七、未做的 / 待你定

- 🔴 **后端需重新部署**：本次修复（`zero_blob_sizes_for_user`）必须重走路径 A
  才生效 —— 当前线上跑的是**不会传播变更**的版本。
- 🔴 **端侧需重新出安卓包**：本批端侧有 3 处改动都要它才生效 ——
  ① `presenceByHash` / `pendingUploadHashes` 改判据 ② `_runSync` 补 bump
  ③ `pulledTotal` 补两项（②③ 属「同步后界面不刷新」这条既有缺陷的修复）。
  ⚠️ 在端侧更新前，被清过备份的书在旧客户端上仍显示「云端有」并下载失败
  （老客户端的既有行为，非本次引入）。
- 🟠 **要不要提前通知用户？** 目前是**静默清理**（到期当天不清、只在第 31 天清一次）。
  可选做法：到期时 / 清理前 7 天各发一条 `user_notifications`
  （「你的云端备份将于 X 天后释放，续订可保留」）。
  📌 我的判断：**本地那份不受影响**（用户不会丢书），所以「静默」目前可接受；
  但**若能提前提醒，转换率与信任度都会更好** —— 这条要你拍。**本批没做。**
- ⚠️ **端侧改动要下次出安卓包才生效**。在端侧更新前，被清过备份的书在旧版客户端上
  仍会显示「云端有」并下载失败（老客户端的既有行为，非本次引入）。
- 🟠 **静默任务无「心跳」日志**（可观测性）：`run_scheduler_inner` 只在
  「有动作」时打 INFO ⇒ 从日志**无法区分**「跑了但没事干」与「根本没跑」。
  可选：加一条 debug 级心跳，或让首轮无条件打一次。
- ✅ **端到端演练未做**（线上 `sync_book` 为 0 行、无 blob 目录 ⇒ 没有真实清理对象）。
  若要真跑一次，需要造「到期满 30 天 + 有 blob」的账号 —— 涉及写生产数据，**需你批准**。
