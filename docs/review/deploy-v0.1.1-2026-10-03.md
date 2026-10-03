# 部署 v0.1.1 + 内容质量闸门验证 + 存量清理（2026-10-03）

> **给白哥** · 一次部署收口三件事：① 三道入库闸门上线 ② 存量 5 篇删除 ③ 闸门**运行时直接证据**
> 提交 `a213d54`（tag `v0.1.1`）· 报告本文件

---

## 一、结论速览

| 项 | 结果 |
|---|---|
| 部署 | tag `v0.1.1` → CI 构建 → **生产二进制 `Oct 3 12:24`** ✅ |
| 三道闸门 | ✅ **运行时验证通过**（日志实测拦截 3 个 PDF） |
| 存量删除 | ✅ 5 条（4 PDF + 1 俄语）已删 · 库 938→933 · `.pdf` 归零 |
| 回滚素材 | ✅ `backups/deleted-content-quality-20261003.json.gz`（6.6 MB） |
| 服务 | `active` · health `200` · feed 正常（50 条 · `.pdf` **0**） |
| 🆕 新发现 | 🔴 **HN 源间歇性抓取失败**（阻塞过验证，见 §四） |

---

## 二、🔑 闸门的运行时直接证据（本轮最关键）

### 2.1 证据

重启后首轮抓取，日志实录：

```
04:36:42 INFO content_fetch: 跳过条目（非 HTML 文档（.pdf））· Hacker News — NTSB Preliminary Report: Prime Air 767 Runway Overrun [pdf]
04:36:42 INFO content_fetch: 跳过条目（非 HTML 文档（.pdf））· Hacker News — The Legend of von Neumann (1973) [pdf]
04:36:42 INFO content_fetch: 跳过条目（非 HTML 文档（.pdf））· Hacker News — Electrification Special Report 2026 [pdf]
04:36:42 INFO content_fetch: Hacker News 拿到 60 条 · 新增 15 条
```

**为什么这是最强证据**：这 3 个 PDF 里有 **2 个正是刚被删掉的**（`The Legend of von Neumann (1973)` = 原 id 2041 ·
`Electrification Special Report 2026` = 原 id 2692）。它们**回到了 HN 榜**，被本轮抓取拿到，
**但闸门挡在入库之前** ⇒ 库里 `.pdf` 仍为 **0**。

⇒ 同时验证了两件事：
1. **闸门接线正确**（不是「写得对但没人调用」）
2. **「删了会被重抓」这个顺序判断是对的**（若没闸门，删了真会回来）

### 2.2 🔴 差点得出错误结论（如实记录）

第一次重启验证时，日志里**没有**「跳过条目」⇒ 我一度怀疑闸门没生效。
查下去才发现：**HN 本轮抓取失败**（`error sending request`）⇒ **PDF 压根没到闸门面前**。

📌 **判据（已入 skill）：「没看到拦截」≠「拦截没生效」—— 要先确认「输入到达了」。**
这与「假绿」是**对称**的一类错误：**假红**（功能正常，但因上游没喂数据而看不到证据）。

---

## 三、部署过程

| 步骤 | 结果 |
|---|---|
| 预检：`fmt --check` | ✅ 空 |
| 预检：`clippy --workspace -D warnings` | ✅ 无输出 |
| 预检：`cargo test --workspace` | ✅ **168 + 20 passed**（9 行 `test result: ok`，0 failed）|
| 安全检查：敏感文件 / 大文件 | ✅ 无（最大是 `content_fetch.rs` 68 KB）|
| push main | ✅ `8579ecf..a213d54`（10 个提交）|
| tag `v0.1.1` | ✅ 指向 `a213d54` |
| CI 构建 + 部署 | ✅ 约 **8 分钟**（12:16 推 tag → 12:24 二进制更新）|
| 落地验证 | 二进制 `12:24` · 服务 `12:25:28` 重启 · 首轮抓取正常 |

> 🔑 `-p api_server` **不含 `examples/`**，所以预检用了 `--workspace`（CI 同款）—— 这是上一轮踩过的坑。

---

## 四、🔴 新发现：HN 源**间歇性**抓取失败

### 4.1 现象

| 时间 | 结果 |
|---|---|
| 10-02 22:36Z | ✅ 成功（HN 最后 120 条中当日部分）|
| 10-03 04:26Z（部署后首轮）| 🔴 **失败** `error sending request for url (.../topstories.json)` |
| 10-03 04:33Z（我手动重启）| 🔴 **失败** |
| 10-03 04:36Z（再重启）| ✅ **成功**（拿到 60 条 · 新增 15 条）|

### 4.2 已排除的原因

| 假设 | 实测 |
|---|---|
| 源不可达 | ❌ 排除 —— `curl` 三次均 **200**（首次 7.3 s，之后 ~1 s）|
| 超时太短 | ❌ 排除 —— 配置是 **20 s**（`HTTP_TIMEOUT_SECS`），远大于 7.3 s |
| IPv6 问题 | ❌ 排除 —— HN 域名**只有 A 记录**（无 AAAA）· VPS 本无 IPv6 · `curl -4` → 200 |
| 我这次部署引入 | ❌ 不太可能 —— 本次改动**没碰 HN 逻辑**（只加了 `content_quality` 的调用）|

### 4.3 判断

**HN（Firebase / Google 基础设施）在国内 VPS 上不稳定** —— 同一台机器、同一时刻，
`curl` 能通而 app 的 `reqwest` 失败；且**同一天内交替成功/失败**。

⚠️ 这**不是本轮引入的问题**，但它是**产品级问题**：HN 承载「热帖」定位，
且它是**唯一产出 PDF 的源**（也是唯一同时命中「非英语 / 长正文 / 外链」的源）。

### 4.4 建议（**未做，等白哥定**）

1. **加重试**（同一轮内失败重试 1–2 次）—— 成本最低，可能覆盖大部分瞬时失败
2. **暴露原始错误链**（`reqwest` 的 `e.source()`）—— 现在日志只有「error sending request」，
   看不出是 DNS / TLS / 连接重置，**排查方向全靠猜**
3. 若确认是链路干扰 → 考虑换 HN 的镜像 API（如 Algolia）或降低该源权重

> 📌 按项目铁律：**代码变更须先报告后请示**，故本轮**只调查、不改**。

---

## 五、存量 5 篇删除（已完成）

### 5.1 清单

| id | URL | 类型 |
|---|---|---|
| 195 | `tomandmaria.com/Tom/Writing/LosAlamosBetsOnENIAC.pdf` | PDF（body 为空）|
| 1495 | `openid.net/wp-content/uploads/2025/10/Identity-Management-...pdf` | PDF（body 为空）|
| 2041 | `gwern.net/doc/math/1973-halmos.pdf` | PDF（3.56 M 字符乱码）|
| 2692 | `iea.blob.core.windows.net/.../Electrification...pdf` | PDF（4.31 M 字符乱码）|
| 2658 | `dev.to/omdigital_ru/telegram-bot-...` | **俄语** |

### 5.2 执行（按 `safe-bulk-deletion`）

1. **引用图实测**：`content_pool` 被 **0 张表**引用（23 张表全查）· 无视图/触发器 ✅
2. **备份**：`backups/coevo-before-content-quality-20261003-123105.db`
3. **删除**：单语句原子 `DELETE ... WHERE id IN (...)` → 受影响 **5 行**
4. **正向验证**：5 条残留 = **无** ✅ · `.pdf` = **0** ✅
5. **反向验证**：全量逐行比对非删除行（**933 行完全一致**，无副作用）✅
6. **回滚素材**：`deleted-content-quality-20261003.json.gz`（含 5 条 14 列完整记录）

**影响**：行数 938 → 933 · 正文 **11,491,199 → 3,610,251 字符（-68.6%）**

### 5.3 🔴 我在这一步犯的错（重要）

**用 `cp coevo.db` 做备份是错的** —— 该库是 **WAL 模式**，且 WAL 文件有 **18 MB 未 checkpoint**：

```
备份库 924 行 · 当时主库 938 行（差 14 条 = 本轮新抓的 id 3178/3188/3288-3299）
id=2484 当前 body=2316 · 备份里 body=0（正文补抓发生在备份之后）
```

⇒ `cp` **只复制主文件，丢掉 WAL 里的全部新数据**。备份实际是「**部署前最后一次 checkpoint**」的状态。

**好在**：备份**仍含那 5 条待删行**（它们是更早写入的）⇒ **回滚这个目的仍成立**。
但作为通用备份方法是错的。

**补救**：
- 导出 5 条**完整记录**为 JSON（真正的回滚素材，不依赖备份完整性）
- 用 **`VACUUM INTO`** 重做正确备份：`backups/coevo-after-content-quality-20261003-123600.db`
  —— 生成 **6.5 MB**（对比 cp 备份的 21 MB）· 校验 933 行 / `.pdf` 0 / 5 条已无 ✅

📌 **判据（已入 skill）：WAL 模式的 SQLite 备份必须用 `VACUUM INTO` 或 `.backup`，不能用 `cp`。**
（`cp` 出来的文件「能打开、行数也对得上（是旧值）」⇒ **静默失真**，不报错。）

### 5.4 空间回收

主库文件仍 **21.5 MB** + WAL **18 MB**（删除后空间进 freelist，但文件未缩小）。

**建议做一次 `VACUUM`**（`VACUUM INTO` 已证明可压到 **6.5 MB**）—— 但 VACUUM 需**独占锁**
+ 重写整个文件，属较大操作，**等白哥定**。

---

## 六、判据提炼（已入 skill）

| # | 判据 | 来源 |
|---|---|---|
| 1 | 🔴 **「没看到拦截」≠「拦截没生效」** —— 先确认**输入到达了**（HN 失败 ⇒ PDF 没到闸门）| §2.2 |
| 2 | 🔴 **WAL 模式的 SQLite 不能用 `cp` 备份** —— 会丢掉未 checkpoint 的数据，且**行数看着对**（是旧值）⇒ 静默失真 | §5.3 |
| 3 | 🔑 **对比两个数据库时，两侧连接必须同类型**（`row_factory=Row` vs `tuple` ⇒ 永远不等 ⇒ **假红**）| §5.3 |
| 4 | 🔑 **「删了会被重抓」这类顺序判断，可用「构造场景」实证**（删完重启 → 观察它是否回来）| §2.1 |

---

## 七、⏳ 待白哥定

| # | 事项 | 说明 |
|---|---|---|
| 1 | 🔴 **HN 间歇性失败** | 加重试？暴露错误链？换 API？（§4.4，**未做**）|
| 2 | 🟡 **是否 `VACUUM` 回收空间** | 21.5 MB → 约 6.5 MB（§5.4）|
| 3 | 🟡 **`verifiable-core-logic` skill 已 45.8 KB** | 该分层（上轮已提）|
| 4 | ⏳ **端侧扩白名单需重新构建 App** | 属 App 改动，**不在本次后端部署范围** |

---

## 八、产出

| 文件 | 内容 |
|---|---|
| 本报告 | 完整证据链 |
| `.workbuddy/memory/2026-10-03.md` | 工作日志 |
| skill `safe-bulk-deletion` | 新增「WAL 备份」判据 |
| skill `content-source-integration` | 新增「假红」判据 |
| VPS `backups/deleted-content-quality-20261003.json.gz` | 回滚素材（5 条完整记录）|
| VPS `backups/coevo-after-content-quality-20261003-123600.db` | `VACUUM INTO` 正确备份 |
