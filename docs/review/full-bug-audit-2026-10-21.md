# 全项目 Bug 排查报告（基于 AOCI 认知层 + gitnexus 调用图）

> 日期：2026-10-21 18:3x
> 范围：`app/lib`（185 文件）+ `backend/crates`（34 文件）
> 性质：**只调查，不改代码**。每条给证据、影响面、至少两个修复选项，等白哥拍板。
> 索引基线：`aoci.code.txt` 166 条（commit `1c75bc4`）· gitnexus 索引覆盖 1366 文件 / 21,329 节点

---

## 一、方法与覆盖率（先说清「查了什么」和「没查什么」）

| 手段 | 命令 | 结果 |
|---|---|---|
| 后端静态检查 | `cargo +1.98.0 clippy --workspace --all-targets` | ✅ 0 error（3 条 warning 全在 `#[cfg(test)]` 里：`assertions_on_constants`）|
| 端侧类型检查 | `scripts/analyze_inproc`（进程内分析器，绕开本机 spawn 231）| ✅ **185 文件 · error=0 · warning=0** · info=7 |
| 端侧断言套件 | 遍历 `scripts/*/bin/verify*.dart` 共 **72 个脚本** | ✅ **72/72 全通过**（含 `verify_sync` 221 项、`verify_iap_plan` 289 项等）|
| AOCI 断言核对 | 从 166 条条目的 S 栏筛出 **28 条**「可机械核对」的断言逐条回代码验证 | 26 条成立 · **1 条指向真 bug** · 1 条为推断待实证 |
| 调用图核对 | 对「零调用方」「唯一权威」「必须同值」类条目做全仓 grep + gitnexus 结构核对 | 发现 4 处死代码 + **1 处端/服常量漂移** |
| 迁移完整性 | 端侧 `user_db` v1→v12 分支 vs schema 列 | ✅ 6/8/10/12 四个分支齐备，`addColumnIfMissing` 幂等正确 |

**没做到的**（如实标注）：
- 没跑真机 / 没连生产库 —— 所有结论来自静态阅读与断言，**未在运行时复现**。
- 没做 `flutter build`（iOS 只能走 CI）。
- 前端 `app/test/` 下无测试（既有约定：防线在 `scripts/`）。

**这与「断言全绿」并不矛盾**：下面两个 P1 都落在**断言覆盖不到的地方** ——
「端/服两个常量是否相等」和「同一个语义是否有第二个判据点」，都不在现有 72 个脚本的断言范围内。

---

## 二、结论摘要

| # | 级别 | 一句话 | 位置 |
|---|---|---|---|
| B1 | **P1** | 单本电子书上限**端侧 50 MB / 后端 32 MB**，且超限被误判成「配额满」⇒ **整个上传队列停摆** | `book_blob_parse.dart:33` ↔ `book_storage.rs:304` |
| B2 | **P1** | 「订阅已到期」有**第二个判据权威**（后端手写归一 + NULL→expired），端侧覆盖层没走已写好的正确判据 ⇒ 免费用户可能被弹「已到期」 | `routes.rs:1189-1220` · `app.dart:778` |
| B3 | P2 | `GET /api/user/{user_id}/subscription` **无鉴权**，可读任意用户订阅状态与精确到期日 | `routes.rs:212` |
| B4 | P2 | 4 处死代码（零调用方但看起来在跑）：`app_config_cache` 的 6 个 API、`needs_auth`、`subject_router`、`tencent_tts` | 见 §六 |
| B5 | P3 | 通知中心**永无内容**（`write_notification` 生产零调用方）—— 条目已标注「有意」，确认是否仍成立 | `notification_handler.rs` |
| B6 | P3 | 下载路径**无体积上限**，一次性读入内存；若历史数据里有 >32 MB 的书会 OOM | `book_blob_client.dart:87` |

---

## 三、B1（P1）单本上限三处不一致 ⇒ 上传失败被当成「配额满」⇒ 整队停摆

### 3.1 事实

| 位置 | 值 | 声明 |
|---|---|---|
| `app/lib/services/ebook/book_blob_parse.dart:32-33` | `kMaxBookBytes = 50 MB` | 注释：**「与后端 `MAX_BOOK_BYTES` 同值 —— 改一处必须改两处」** |
| `app/lib/services/ebook/book_text.dart:111` | `kMaxEbookBytes = 50 MB` | 导入/解析阶段的上限 |
| `backend/crates/api_server/src/book_storage.rs:304` | `MAX_BOOK_BYTES = 32 MB` | 注释给了取值依据：VPS 约 460 MB 可用 ⇒ 32 MB × 10 并发仍在界内 |

⇒ **那条注释本身是错的**：两处早就不相等了（`git log -S` 显示二者分别由 `3874735` 与 `86bb0ce` 引入，后写的端侧直接按 50 假设）。

### 3.2 失败链路（三步，每步都在放大）

```
用户导入 40 MB 的 epub
  └─ ① 端侧校验 40 ≤ kMaxEbookBytes(50)  ✅ 通过 → 解析、落库、进上传队列
       └─ ② 上传：后端 DefaultBodyLimit = MAX_BOOK_BYTES + 1 MB = 33 MB
            └─ 40 MB > 33 MB ⇒ axum **直接回 413**（根本没进 handler）
                 └─ ③ 端侧 parseUploadResponse 把 413 解释成 BlobQuotaExceeded
                      └─ book_upload_queue: `case BlobQuotaExceeded(): _cancelled = true;`
                           ⇒ **整个队列停下**，其余所有正常的书也不再上传
```

⚠️ 关于 ②，两种可能都存在，**结论相同**：
- `http` 的 `MultipartRequest` 会带 `Content-Length`，hyper 在**读 body 之前**就回 **413**
  ⇒ 走上面这条链（误判成「配额满」+ 队列停摆）。
- 若连接被提前重置，Dart 侧抛异常 → `BlobFailed('上传失败：$e')` ⇒ 这一本计一次失败重试，
  队列**继续**（表现是「这本书永远传不上去、日志里反复失败」）。
两种都不报真实原因，且都不会让用户知道「是体积问题」。

三个错叠加：

1. **阈值不一致**：32~50 MB 的书，端侧认为合法。
2. **错误语义错**：413（体积超限）被当成「云端空间不足」—— 用户可能 2 GB 配额一点没用，却被告知空间不足。
   - 只有 32~33 MB 这一窄带才会进到 handler 拿到友好文案「这本书超过单本上限（32 MB）」，但那句同样被归类成 `BlobQuotaExceeded`。
3. **失败放大**：单本书失败 ⇒ 队列 `_cancelled = true` ⇒ **其它所有书永久传不上去**，直到用户手动删掉那本大书（而他并不知道是哪本）。

### 3.3 影响面

- 触发需要「单本 > 32 MB」。正常英文小说 < 5 MB，但**图片版 epub / 扫描版 / 漫画**很容易 30~80 MB。
- 一旦触发：该用户的**云端书架功能整体不可用**（不是一本书的问题），且 UI 提示指向错误方向（「删书或订阅」）。
- 属于「静默降级 + 错误归因」，正是本项目最忌的一类。

### 3.4 修复选项

**选项 A（推荐 · 对齐到后端）**：端侧两个常量都改成 **32 MB**，并把注释改成指向真值的判据（见下）。
- 代价：用户导入 >32 MB 的书会在**导入阶段**就被拒（早失败、文案准确），不再产生「导入成功但永远传不上去」的死书。
- 需要同时改：`kMaxBookBytes`、`kMaxEbookBytes`、`book_blob_client.dart:87` 那句「单本上限 50 MB」的注释。

**选项 B（提高后端上限）**：把 `MAX_BOOK_BYTES` 提到 50 MB。
- ⚠️ 与后端注释的取值依据冲突：50 MB × 10 并发 = 500 MB > VPS 可用 460 MB ⇒ **会 OOM**。
- 除非同时把上传改成流式落盘（不进内存），否则不建议。

**无论选哪个，都建议加两件事**（这是让 bug 不再复发的部分）：
1. `parseUploadResponse` 里 413 与「超过单本上限」不要归一成 `BlobQuotaExceeded`，新加一个 `BlobTooLarge`；队列对 `BlobTooLarge` 的行为是**跳过这一本、继续传下一本**（`continue` 而不是 `_cancelled = true`）。
2. 加一条断言：从 `book_storage.rs` 与两个 Dart 常量里各自正则抠出数值，断言三者相等。
   —— 这类「跨语言同值」目前**一条断言都没有**，是本次唯一漏网的常量漂移。

---

## 四、B2（P1）「订阅已到期」的第二个判据权威

### 4.1 现状：同一个问题，三处判据

| # | 位置 | 判据 | NULL 时 | 空格分隔 | 解析失败 |
|---|---|---|---|---|---|
| ① | `subscription.rs::parse_expires`（**自称唯一权威**）| RFC3339 / 纯日期 / **空格分隔** | None | ✅ 接受（按 UTC）| None |
| ② | `routes.rs::user_subscription_handler:1191-1220` | **只认 RFC3339 + 10 位纯日期** | `expired: true` | ❌ **拒绝** | **`unwrap_or(true)` ⇒ 已过期** |
| ③ | 端侧 `subscription_provider.isExpired` | 直接用 ② 的 `expired` 字段 | true | — | — |

②自己手写了归一：

```rust
let normalized = if e.len() == 10 && e.as_bytes().get(4) == Some(&b'-') {
    format!("{}T00:00:00Z", e)          // 只补纯日期
} else { e.clone() };                    // 空格分隔原样送进 parse_from_rfc3339 ⇒ 失败
chrono::DateTime::parse_from_rfc3339(&normalized)
    .map(|dt| dt.timestamp() < now_ts)
    .unwrap_or(true)                     // ← 解析失败当「已过期」（fail-closed）
```

**这正是 AOCI 条目 `routes.rs[EG9L]` 的 S 栏记下的那条**：*「user_subscription_handler 手写归一与 parse_expires 口径不一致」*。条目写对了，但问题本身没修。

### 4.2 更关键的一半：端侧覆盖层用的是被**明确否定**的判据

`app/lib/providers/iap_provider.dart:202-206` 已经写好了正确判据，并且**明确警告不要用另一个**：

> 🔴 它**不是** `!subscriptionActiveNow(ref)` —— 那是把「从未订阅」也算进「已到期」，
>    会给所有免费用户显示「你的会员已到期」。

`subscriptionLapsedNow()` 的实现要求 `backendHasRecord = expiresAt 非空`（NULL 才算「从未订阅」）。

但覆盖层 `app/lib/app.dart:776-781` 用的是：

```dart
if (iap.availability == IapAvailability.unavailable) {
  _applyExpired(
    expired: ref.read(subscriptionProvider).isExpired,   // ← ②的直接映射，NULL ⇒ true
    isAnonymous: isAnonymous,
  );
}
```

`isExpired == (status == expired)`，而 ② 对 NULL 返回 `expired: true`
⇒ **一个注册了但从未订阅的用户，`isExpired` 是 `true`**。

于是走 `_applyExpired(expired: true, isAnonymous: false)` ⇒ 弹「订阅已到期」。

**这与代码里那句警告完全一致**：它正是「给从未订阅的人显示已到期」的实现。

### 4.3 可达性（如实说明，别夸大）

弹窗只在 `iap.availability == unavailable` 时走这条路。iOS 上 `isAvailable()` 为 false 的真实场景：
- 系统「屏幕使用时间 → 内容和隐私访问限制 → App 内购买项目 = 不允许」；
- StoreKit 初始化失败 / 越狱环境 / 非商店分发的构建。

不是高频，但**一旦发生，对免费用户说的是假话**，且与「我的」页显示的状态矛盾
（我的页用 `subscriptionActiveNow`，会说「未订阅」）。

### 4.4 修复选项

**选项 A（推荐 · 端侧改用已有判据）**：
```dart
_applyExpired(
  expired: subscriptionLapsedNow(ref, iapSnapshotOf(ref)),   // 已存在、已带归属过滤
  isAnonymous: isAnonymous,
);
```
- 改动 1 行，语义与「我的」页统一，复用现成判据（不新增概念）。
- 代价：`subscriptionLapsedNow` 内部 `ref.watch`，需确认在 `.then()` 回调里调用是否安全
  （该回调不是 build 期）⇒ 若要 `read` 版本，应把 `subscriptionLapsed` 的**纯函数**直接拿来算。

**选项 B（后端修 ②）**：让 ② 直接调 `subscription::parsed_expires`，并区分三态
（`no_record` / `active` / `expired`），响应改成 `{"state": "..."}`。
- 更彻底（消灭第二权威），但**要改协议** ⇒ 端侧得同步发版，存在新旧不兼容窗口。
- 若走 B，建议响应里**同时**保留旧的 `expired` 字段（老版本仍可解析），新端读 `state`。

**不管选哪个，③ 的 `unwrap_or(true)` 都该改**：解析失败应该显式区分「格式不认识」，
而不是默默判成「已过期」—— 这正是本项目 `subscription_expires` 那次事故的同族错误。

---

## 五、B3（P2）订阅状态端点无鉴权

`routes.rs:211-214` 注册 `GET /api/user/{user_id}/subscription`，
handler 签名是 `Path(user_id)` —— **没有 `HeaderMap`，没有任何 `verify_auth`**。

对比同一个 `{user_id}` 形状的邻居：

| 端点 | 鉴权 |
|---|---|
| `GET/PUT /api/user/{user_id}/preferences` | ✅ `auth_middleware::verify_auth(&user_id, &headers)`（routes.rs:1085 / 1163）|
| `GET /api/user/{user_id}/subscription` | ❌ 无 |

⇒ 任何人知道 `user_id` 就能读到该用户的**订阅状态与精确到期时间**。

**风险被什么抵消了**：`user_id` 是 `Uuid::new_v4()`（auth.rs:178），不可枚举。所以这是**信息泄露**而非批量爬取。
但「同一形状的兄弟端点鉴权不一致」通常是疏忽，不是设计。

**修复**：加 `verify_auth`（与 preferences 同款）。⚠️ 需确认端侧调用时**确实带了 Bearer**
（`subscription_provider.dart:71` 有条件地加 `Authorization`，`token == null` 时不带）
⇒ 若登录态下 token 为空，加了鉴权会让对账 401。**这是修之前必须先验的一件事**。

---

## 六、B4（P2）四处死代码：看起来在跑，其实没人调

AOCI 条目里已标注 3 处，本次全仓 grep 复核（`grep -v` 掉定义文件自身）：

| 模块 | 现状 | 后果 |
|---|---|---|
| `app_config_cache.rs` | `init_cache` 由 `backend/src/main.rs:412` 调（✅ 起服时跑）；但 `get` / `get_sync` / `set` / `set_with_desc` / `list` / `batch_update` **全仓零调用** | 每次起服**写一遍** `app_config` 表（`INSERT OR REPLACE` 覆盖手工改过的值），而**没有任何代码读它** ⇒ 既无收益又有覆盖风险 |
| `auth_middleware::needs_auth` | 只有定义（`routes.rs` 零引用）| 注释自称「dead_code 的 TODO，没有全局白名单」|
| `subject_router` | 只有 `lib.rs:69` 的 `pub mod` | `pub mod` 使 `dead_code` 不报警 ⇒ 静默腐烂（`grade_to_band` 里「初三→g3-4」的映射错误因此没人发现）|
| `tencent_tts` | 只有 `lib.rs:78` 的 `pub mod`（唯一的 `tencent_tts::` 出现在自己的文档注释里）| 同上 |

**注意 `pub mod` 的共性**：这四处都是「因为 `pub` 所以编译器不报死代码」。
🔑 判据：**`pub` 是给外部 crate 用的**；本 crate 内部零调用 + 无外部消费者 ⇒ `pub mod` 只是把死代码的警报关掉了。

**修复选项**：
- A（推荐）：给这 4 个模块加一条「显式保留」的说明 + 在断言里锁住「零调用」这一事实（避免以为在跑）；
- B：删掉（`app_config_cache` 尤其该考虑：它每次起服覆盖配置表却没人读）。
- ⚠️ 决策前需确认：`tencent_tts` 条目说「定案全链保留给 AI 考核」—— 若那是产品决定，选 A。

---

## 七、B5/B6（P3）两条观察

**B5 通知中心永无内容**：`write_notification` 生产零调用（只有 `#[cfg(test)]` 用例）。
端侧「我的」页保留了通知入口（白哥 2026-09-29 要求保留），点开是空列表。
AOCI 条目标注「无写入方是有意的」—— 请确认这个「有意」现在是否还成立（是「暂时没有业务事件」还是「忘了接」）。

**B6 下载无体积上限**：`book_blob_client.download` 一次性 `bodyBytes` 读入内存，没有上限检查
（注释里按 50 MB 论证）。正常数据都 ≤32 MB，所以现在不咬人；但若历史数据或将来放宽上限，这是 OOM 入口。
建议：下载前看 `content-length`，超 `kMaxBookBytes` 直接判失败。

---

## 八、确认**没有问题**的部分（省得下次重复查）

| 项 | 结论 |
|---|---|
| 同步分批（1000/表）| ✅ 端 `kMaxItemsPerTable=1000` == 服 `MAX_ITEMS_PER_TABLE=1000`；全量表只在第一轮带（避免永不终止）|
| 同步 11 类表 | ✅ 服 `push_changes` 的 11 次 `check_batch_size` 与端侧字段表一一对应 |
| 时间戳比较 | ✅ `parseSyncTs` 要求尾随 `Z` 后按 `DateTime` 比；三处写入形态（`strftime …SZ` / `toIso8601String` / `%fZ`）都带 `Z` |
| 端侧 DB 迁移 | ✅ v6/v8/v10/v12 四个 `oldVersion <` 分支齐备；`addColumnIfMissing` 幂等；ALTER 排在「重跑全量脚本」之前 |
| 主题「跟随系统」 | ✅ 手动选档必关 `followSystem`，且早退条件同时判档位与开关 |
| 验证码位数 | ✅ 端 `kCodeBoxCount=6` == 服 `format!("{:06}")` |
| 翻译三常量同比例 | ✅ `MAX_TEXT_CHARS(800)/MAX_TOKENS(2400)/MAX_SEGMENTS(140)` 有编译期断言锁 |
| 订阅价格 | ✅ 端 `fallbackFen` 600/5800 == 服 seed 600/5800，且老库有 `UPDATE … WHERE price <> 600` 兜底 |
| `content_fetch` 跨 await 持连接 | ✅ 全部用显式 block 收窄 guard 作用域（模块头 ① 的规则真的执行了）|
| 编译/类型 | ✅ clippy 0 error；Flutter 进程内分析器 185 文件 0 error 0 warning |

---

## 九、建议的处理顺序（等白哥定）

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | B1 选项 A + 加断言 | 门槛最低、改动最小，且**顺手补上「跨语言同值无断言」这个结构性缺口** |
| 2 | B2 选项 A | 1 行改动，把覆盖层拉回项目自己写好的判据 |
| 3 | B3 | 修之前先验「登录态下 token 是否一定非空」，否则会引入 401 |
| 4 | B4/B5/B6 | 需要产品判断（保留还是删），不阻塞前三条 |

⚠️ 按项目铁律：**以上均为调查结论，未改任何代码**。批准哪几条、选 A 还是 B，我再动手。

---

## 十、✅ 实施记录：B1 / B2 按 **B 方案** 修复（2026-10-21 18:5x–19:2x）

白哥裁定「走 B」⇒ 两条 P1 都取报告里的 **B 方案**（而非 A 的「改端侧对齐」）。
下面记录**实际改了什么、为什么这么改、以及怎么证伪的**。**未部署、未出包。**

### 10.1 B1：单本上限 32 → 50 MB，**前提是把上传改成流式**

| 位置 | 改动 |
|---|---|
| `book_storage.rs` | `MAX_BOOK_BYTES` 32 → **50 MB**；trait 新增 `put_from_file`（原子 rename 接管临时文件）+ `staging_dir`（与目标同目录，避免 `EXDEV`）|
| `book_blob_handler.rs` | 上传从「`Vec<u8>` 攒整本」改为「**边收边写临时文件**」，内存占用恒为一块 chunk；新增 `TempFileGuard`（`Drop` 兜住 6 条提前返回路径，不漏垃圾文件）；`usage` 修正为 `used - existing + size` |
| `book_blob_client.dart` | 下载改用 `send()` 拿 `StreamedResponse`，**先看 `Content-Length` 再收**（超限直接 `BlobTooLarge`，不耗尽内存）|
| `book_blob_parse.dart` | 新增 `BlobTooLarge`；`413` 与「超过单本上限」**不再**归成 `BlobQuotaExceeded` |
| `book_upload_queue.dart` | `BlobTooLarge` ⇒ **只跳过该本、继续传下一本**（并记 `attempts` 防每轮重传）；新增 `tooLargeThisRun` 单独计数 |

🔴 **为什么 B1 的 B 方案必须连流式一起做**（这是报告里那句「否则不建议」的落地）：
原注释的取值依据是「32 MB × 10 并发 = 320 MB，VPS 460 MB 够用」——
那只对「整块进内存」成立。**不改成流式而直接把常量抬到 50 MB，就是 500 MB > 460 MB ⇒ OOM。**
⇒ 两者是同一件事的两半，已写进 `MAX_BOOK_BYTES` 的注释与断言里（见 10.3）。

### 10.2 B2：订阅判据收口为**唯一权威** + 四态协议

| 位置 | 改动 |
|---|---|
| `subscription.rs` | 新增**纯函数** `expires_state(raw, now) -> none/active/expired/invalid`；4 个单测（含「空格分隔不能被判过期」）|
| `routes.rs` | `user_subscription_handler` 删掉手写归一（`format!("{}T00:00:00Z")` + `unwrap_or(true)`），改调 `expires_state`；响应新增 `state`，`expired` **逐值等价于旧实现**（旧端行为不变）|
| `subscription_provider.dart` | 读 `state` 四态：`none`/`invalid` → `required`（**不再** → `expired`）；无 `state` 时退回旧布尔（兼容「新端 + 旧服务端」）|
| `app.dart` | 覆盖层改用 `subscriptionLapsed(...)`（要求 `backendHasRecord`），不再拿裸 `isExpired` 当结论 |

🔑 **四态的关键在 `none`**：`subscription_expires IS NULL` = **从未订阅**，
这与「买过但过期」在旧协议里是同一个 `true` —— 那正是「给所有免费用户说已到期」的根源。
`invalid` 单独一态的理由：既不白送权益（不能算 active），也不诬告欠费（不能算 expired）。

### 10.3 断言：新增 2 条，改 1 条（原断言在**保护旧行为**）

| 脚本 | 作用 |
|---|---|
| 🆕 `scripts/ebook_verify/bin/verify_book_limits.dart`（10 项）| 从**两端源码**抠出 `MAX_BOOK_BYTES` / `CLOUD_BOOK_QUOTA_BYTES` 与 Dart 常量做比对；并锁「50 MB 的前提」——上传仍是 `put_from_file`、**没有** `buf.extend_from_slice`、`DefaultBodyLimit` 由常量推导、413 归 `BlobTooLarge` |
| 🆕 `scripts/iap_verify/bin/verify_subscription_state.dart`（19 项）| 后端四态判据 + 路由不再手写归一 + 端侧四分支映射 + 覆盖层用 `subscriptionLapsed` |
| ✏️ `scripts/query_verify/bin/verify_book_cloud.dart` | 原两条断言写的是「413/超单本上限 ⇒ 归到配额」——**它们锁的是有害行为**（队列会整队停摆）。改成新契约，并新增队列级断言：「第一本太大，第二本仍被尝试」 |

🔴 **两条新断言都做了证伪**（否则不知道它是不是假绿）：
- 把 `kMaxBookBytes` 临时改成 40 MB ⇒ `verify_book_limits` **红灯**（退出码非 0），还原后绿。
- 把 `'none' || 'invalid' => required` 改成 `=> expired` ⇒ `verify_subscription_state` **红灯**，还原后绿。

### 10.4 验证结果（本地全绿）

| 项 | 结果 |
|---|---|
| `cargo clippy --workspace --all-targets` | ✅ 0 error（仅 2 条既有 `assertions_on_constants` 警告，在 `#[cfg(test)]` 里）|
| `cargo test --workspace --lib` | ✅ **327 + 20 通过**、0 失败（新增 6 个：4 个 `expires_state` + 2 个存储层）|
| `scripts/analyze_inproc` | ✅ 185 文件 · **error=0 / warning=0** |
| `scripts/*/bin/verify*.dart` | ✅ **74/74 全过**（含新增 2 个）|
| `aoci check` | ✅ **✓ ready to commit**（Entries 漂移 / 策展 / 字典 / 格式 / 草稿 五净）|
| `aoci index agent guide` | ✅ `stage=aligned complete=true next_action=none` |

⚠️ 本机 `cargo test --workspace`（不带 `--lib`）会因**沙箱拒绝写** `target/debug/examples/body_diag.exe` 而失败 —— 那是环境限制，不是代码问题；CI（ubuntu）不受影响。

### 10.5 上线顺序与回滚（**还没做，等白哥指令**）

1. **后端先发**：新增的 `state` 字段是**向后兼容**的（旧 App 只读 `expired`，语义未变）。
   ⚠️ **不要反过来**（App 先发）→ 旧后端没有 `state`，端侧会走「退回旧布尔」兜底 ⇒ 回到旧行为，不崩但也不修好。
2. **App 后发**（需 iOS 出包 ⇒ CI）：
   - B1 的端侧部分（`BlobTooLarge`、队列跳过）**与后端无强依赖**：新端 + 旧后端时，413 也会被正确归成 `BlobTooLarge`（后端旧版同样回 413）。
   - 但**上限一致性要靠后端先发**：端 50 / 服 32 的组合下，32–50 MB 的书仍会被拒（只是现在会「跳过该本」而不是「整队停摆」）。
3. **回滚**：后端二进制 `.prev` 保留（部署脚本已有）；`.aoci` 与索引改动无运行时影响。

### 10.6 本次**没有**做的（仍待定）

- **B3**（`/api/user/{id}/subscription` 无鉴权）：没动。修之前必须先确认「登录态下 token 一定非空」，否则加鉴权会引入 401。
- **B4**（4 处 `pub mod` 掩盖的死代码）、**B5**（通知零写入方）：需要产品判断（保留还是删），不阻塞。
- **B6**：已顺手修掉（下载加 `Content-Length` 上限），因为 B1 把上限抬到 50 MB 后它从 P3 变成「必须一起处理」。
