# HN 弃用 + 库维护 + skill 分层（2026-10-03）

> **给白哥** · 四项指令的落地情况：① 放弃 HN ✅ ② VACUUM ✅ ③ skill 分层 ✅ ④ App 重新构建 ⛔ **被环境阻塞**
> 提交 `82bddc8`（HN 清理）· **未部署**

---

## 一、结论速览

| # | 指令 | 状态 | 结果 |
|---|---|---|---|
| ① | 放弃 HN | ✅ 代码完成 | 6 文件 + 1 迁移 · 163 passed · 证伪 2/2 · **未部署** |
| ② | VACUUM | ✅ **已执行** | **21.47 MB → 6.75 MB（回收 69%）** · integrity ok · 行数一致 |
| ③ | skill 分层 | ✅ 完成 | `verifiable-core-logic` 主文件 **46.2 → 24.7 KB** · 锚点 0 丢失 |
| ④ | App 重新构建 | ⛔ **阻塞** | 本机 Dart **创建不了子进程**（环境级）→ 需你在普通终端跑 |

---

## 二、① 放弃 HN

### 2.1 🔴 先纠正一处前提（它影响决策质量）

白哥说「**HN 好像不是主力源**」—— 实测**不准确**：

| 指标 | 实测 |
|---|---|
| 条数 | **196 条 · 全库第 2**（仅次 arXiv 269）|
| 正文字符 | **122 万 · 全库第 1**（arXiv 的 body 是 0）|

**但「麻烦远比收益多」成立**，且真正的理由是**可替代**：

| 维度 | 事实 |
|---|---|
| 分类贡献 | 全部是 `tech` ⇒ **零独有分类**（tech 另有 Dev.to 169 / Ars 33 / NPR Tech 6）|
| 🔴 唯一独有价值 | **唯一提供 `score`/`comments` 的源** ⇒ 放弃它 = **「热帖」这条产品线结束** |
| 真实麻烦 | 间歇失败（同机 curl 通 / reqwest 失败）· 唯一产 PDF 的源 · 技术文密集（LaTeX/代码转义残留集中在此）|

⇒ 「放弃」可行（**零分类损失**），代价是「热帖」消失 —— 白哥已明确接受。

### 2.2 做法：照 **Ars Technica 先例**（禁用而非删行）

seed 里 HN 行改 `enabled = 0`，**保留行**。本项目已有完全同类先例（Ars）：
> `删源会让它们变成孤儿；保留行 + enabled = 0 可随时改回 1。`
> `📌 「禁用」≠「删除」—— 前者可逆、保留追溯性`

⚠️ 但适配器已删 ⇒ 若改回 `enabled = 1`，抓取会报「未知的源类型 `hn`」
（**有意的**：去掉能力要让「重新启用」**立刻可见地失败**）。

### 2.3 清理范围

| 文件 | 改动 |
|---|---|
| `content_hn.rs` | **整个删除**（239 行）|
| `lib.rs` | 去模块声明 |
| `content_fetch.rs` | 去 `use` / `"hn"` 分支 / `fetch_hn` / INSERT 两列 / 断言 **23 → 22** |
| `content_rss.rs` | `ParsedItem` 去 `score` / `comments` |
| `content_handler.rs` | 去 `SORT_BY_SCORE` + `FeedQuery.sort` + 三处 SQL 两列 + **`r.get(N)` 索引重排** |
| `schema.rs` | DDL 去两列 + `idx_cpool_score`；迁移加 `DROP INDEX` + 两个 `drop_column_if_exists` |
| `feed_item.dart`（端侧）| 去 `score` / `comments` 字段 |

**三处关键判断**：

1. 🔴 **三处 SELECT 里的列名是字符串** —— 删列**不报编译错**，**运行时才炸**。
   这是「静默失效」的教科书形态（编译器帮不上忙）。
2. 🔴 **迁移的顺序硬约束：先删索引再删列** —— SQLite 拒绝删被索引引用的列。
   证伪实测：不先删索引 → `no such column`。
3. 🔑 **断言从「应有 hn 源」反转为「不得有启用的 hn 源」** —— 防以后有人顺手改回。
   顺手清掉 `SORT_BY_TIME`（**定义但从未被消费** = 死代码）。
4. `test_normalize_sort_whitelist` 改写为 `test_normalize_order_is_constant` ——
   功能没了，但「order 不得含用户输入」这个**注入面关切仍要守**（改后更强）。

### 2.4 验证

- `cargo test --workspace` **163 passed** · fmt ✅ · clippy ✅
- 新增 `test_migration_drops_score_and_comments`（**副本演练** 7 项断言：
  两列没了 / **索引也没了** / 行还在且内容未变 / 幂等）
- **证伪 2/2 如期失败**（A 不先删索引 → `no such column`；B 只删索引 → 列断言报红）

### 2.5 🔴 造测试用例时踩的两个坑（值得记）

1. 第一版**手写两张 `CREATE TABLE`** ⇒ `content_source` 列不全 ⇒
   `rebuild_content_source_with_check` 判定「没 CHECK」→ 触发重建 → 列名对不上 ⇒
   **用例自己跑不起来**（差点误判成「迁移有 bug」）。
   ⇒ 改成「先用真实流程建库，再手工**只回退要验的那部分特征**」。
2. 忘了 `content_pool.source_id` 有**外键**（实测报 787）⇒ 插入失败。

---

## 三、② VACUUM（已执行）

### 3.1 结果

| | 前 | 后 |
|---|---|---|
| 库文件 | **21,467,136 B** | **6,746,112 B**（**-69%**）|
| 空闲页 | `freelist 3567 / page_count 5241`（**68% 是空闲页**）| 0 |
| 数据 | 950 行 · 正文 379 万字符 | **完全一致** ✅ |
| `integrity_check` | — | **ok** ✅ |

**为什么有这么多空闲页**：上一轮删了 5 条大正文（占正文 68.6%）——
SQLite 的 `DELETE` 只把页**标记为空闲**，文件不缩。

### 3.2 执行方案（为何不是就地 `VACUUM`）

```
① 记录基线（行数 / page_count / freelist）
② 停服（VACUUM INTO 要一致快照；顺便让 WAL checkpoint）
③ VACUUM INTO 新文件        ← 不在原库上操作，可随时放弃
④ 校验新库（integrity_check + 逐表行数比对 + 列结构 + 正文总字符）
⑤ 🔴 原库**三件套整体移走**（.db + -wal + -shm）
   → 少了 -wal/-shm 会让新库被误认为「有未应用的 WAL」⇒ 数据错乱
⑥ cp 新库就位 → 启服 → 验证（服务自己读新库）
```

**停机窗口**：约 10 秒（②到⑥）。

### 3.3 回滚点（都留着）

| 文件 | 说明 |
|---|---|
| `pre-vacuum-20261003-130848.db` | **21.5 MB · VACUUM 前完整快照** ← 首选回滚点 |
| `vacuumed-20261003-130837.db` | 6.7 MB · 替换用的源 |
| `deleted-content-quality-20261003.json.gz` | 上轮 5 条删除行的完整记录 |

⚠️ `coevo-before-content-quality-20261003-123105.db`（21 MB）是**上轮那个不完整的 `cp` 备份**
（WAL 模式 `cp` 会丢未 checkpoint 数据）⇒ **不要拿它当回滚点**，
它是「部署前状态」的历史记录（含已删的 5 条）。

**磁盘**：备份目录合计约 56 MB（`/` 有 31 G 可用，无压力）。

---

## 四、③ `verifiable-core-logic` skill 分层

### 4.1 问题（比「太大」严重）

- 主文件 **46.2 KB / 611 行**
- 🔴 **铁律编号倒挂**：正文顺序是 `十五→十六→…→二十` **然后**才 `十二→十三→十四`
- 「遇到这些情况，去看哪份」这个**索引段夹在中间**
- 速览表里**自己写着**「⚠️ 已 45 KB … 计划把十二~二十 也移入 references。**待办**」

### 4.2 做法与结果

| | 前 | 后 |
|---|---|---|
| 主文件 | 46,208 B / 611 行 | **24,689 B / 199 行** |
| references | 4 份 | **5 份**（新增 `assertion-rules-12-20.md` 22 KB）|

- 新建 `references/assertion-rules-12-20.md`：**十二~二十 的展开正文，按编号重排**
- 主文件只留：速览表（全 20 条）+ 文本断言导航表 + 「去看哪份」+ 检查清单
- 顺带修：`assertion-rules.md` 标题「完整版 · **十条**」→「**一 ~ 十一**（实为 11 条）」

### 4.3 核对（全量）

- 🔑 **逐行锚点核对 0 未命中** —— 原 611 行 **100% 逐字保留**（含按编号重排后）
- 检查清单 **51 项一致** · 47 个原文标题全保留 · 5 份 references 双向指针齐备
- 链接全有效（提到 5 份 / 实际 5 份 / 无悬空 / 无遗漏）

### 4.4 🔴 顺手修了一个**既有问题**：references 的行尾是乱的

| 文件 | 原本 | 现在 |
|---|---|---|
| `text-assertion-scope.md` | **全 CRLF**（802 处）| LF |
| `toolchain-failures.md` | **混合**（380 CRLF）| LF |
| `assertion-rules.md` | **混合**（338 CRLF）| LF |
| `verification-workflow.md` | 全 LF | LF |

⇒ 现在整个 skill 目录 **全部 LF**。
📌 教训：**最初只检查了 `SKILL.md` 就以为「全 LF」** —— 检查行尾要对**目标目录的所有文件**做。

---

## 五、④ App 重新构建 —— ⛔ 被环境阻塞（不是代码问题）

### 5.1 现象与根因

```
$ flutter build apk --release
ProcessException: 231（所有的管道范例都在使用中）
  at ../../runtime/bin/process_win.cc:742
  Command: git.EXE -c log.showSignature=false log HEAD -n 1 ...
```

逐层排查（**用最小复现脚本一次判定**）：

| 检查 | 结果 |
|---|---|
| 那个 git 路径是否存在 | ✅ 存在 |
| 手动跑那条 git 命令 | ✅ **成功**（exit 0）|
| `flutter --version` | 🔴 **也崩** |
| **Dart 能否创建子进程**（`scripts/troubleshoot/dart_subprocess_check.dart`）| 🔴 **`cmd /c echo hi` 都失败** |

⇒ **根因：本机 Dart runtime 创建子进程失败**（`CreateNamedPipe` 被拒），
与项目代码、git、Flutter 版本**全无关**。

**影响范围**：
- ❌ `flutter build` / `analyze` / `test` 全部不可用（都要 spawn 子进程）
- ✅ **纯 Dart 逻辑脚本仍能跑**（`dart run` 本身能启动）⇒ 逻辑断言不受影响
- ✅ **Rust / cargo 不受影响**

**替代路径也不通**：CI **没有 Android 出包 job**（只有 tag 触发的 `ios-build`）。

### 5.2 请你在普通终端跑（不受这个限制）

🔴 **更正（2026-10-03 · 白哥指出）**：本节初版给的是 `build apk --release`（**光秃秃的**）——
**漏了两个关键参数**，打出来的包**连不上后端**、且**体积大一倍**。原因是我**没去读项目里已有的
权威清单**（`a2-device-verification-checklist-2026-10-02.md` §〇 早就把命令写全了）。

```bat
cd E:\CoEvo\app
:: 🔴 全路径（裸调 = 鸿蒙分支 3.27.5 → BUILD FAILED in 59s）
:: 🔴 --dart-define 必加（否则默认 localhost:8080 ⇒ 连不上）
:: --target-platform → 只打 arm64 ⇒ 体积 82.6 → 43.9 MB
D:\flutter\bin\flutter.bat build apk --release ^
  --target-platform android-arm64 ^
  --dart-define=API_HOST=api.keyievolution.fun
```

| 参数 | 不加会怎样 |
|---|---|
| `--dart-define=API_HOST=api.keyievolution.fun` | 🔴 **`ApiConfig` 默认 `localhost:8080`**（`app/lib/api/api_config.dart`）⇒ 真机上**首页空、划词提示连不上服务** |
| `--target-platform android-arm64` | 打全架构 ⇒ **体积 82.6 → 43.9 MB**（实测）|
| （全路径 `D:\flutter\bin\flutter.bat`）| 裸调 `flutter` 解析到**鸿蒙分支** ⇒ `BUILD FAILED in 59s` |

📌 **两条按需追加**（默认不用加）：
- 报 `ProcessException: 231`（本机 Dart 创建不了子进程，§5.1）→ 追加 `--no-version-check`
  （⚠️ 实测**只跳过 `checkFlutterVersionFreshness` 那一次 git 调用**，后续仍崩 ⇒
  「绕行一步」而非「修好」；**普通终端不需要它**）
- 要验「分享 / 二维码」→ 追加 `--dart-define=PUBLIC_BASE_URL=https://keyievolution.fun`

⚠️ 注意 `ApiConfig` 的自动推断：**域名 → `https://host`（不追加端口）**；
IP/localhost → `http://host:port`。所以传 `api.keyievolution.fun` 会得到 `https://api.keyievolution.fun` ✅

📄 **这份命令现已双向登记**（白哥 2026-10-03 同意）：
- `app/lib/api/api_config.dart` 类注释 —— **开发者入口**（含 Android + iOS + 按需追加项）
- 本清单 §〇 —— **流程与「为什么」**
- 📌 改命令要**两处同步**

🔴 **另一处同类问题**（CI）：`ci.yml` 的 `ios-build` job 是全仓库**唯一**的出包 job，
它的命令是 `flutter build ios --release --no-codesign` —— **没有 `--dart-define`**
（全 `ci.yml` 里 `dart-define` 出现 **0 次**）。
它只做「**能编译**」验证（`--no-codesign`）⇒ **影响有限，但绝不能拿它当发布源**。
将来若要 CI 出正式包，**必须补上 `--dart-define`**。

产物：`app\build\app\outputs\flutter-apk\app-release.apk`

**这个包会包含的端侧改动**（都已提交）：
- **扩转义白名单**（`beaef63`）—— 这是你最初要验的那个
- 正文**链接禁用点击**（`d3a6996`）
- `FeedItem` 去 `score`/`comments`（`82bddc8`）

📌 已归档诊断脚本 `scripts/troubleshoot/dart_subprocess_check.dart`（下次遇到能秒判）。

---

## 六、⏳ 待你定

| # | 事项 | 说明 |
|---|---|---|
| 1 | 🔴 **HN 清理要部署才生效** | 代码已就绪（163 passed）。当前生产**仍在抓 HN**（每 6h 一轮）|
| 2 | 🟡 **备份目录 56 MB** | 是否清理旧回滚点（`pre-vacuum` 21 MB 建议留几天）|
| 3 | ✅ VACUUM 已完成 | 无需再操作 |
| 4 | ✅ skill 分层已完成 | 无需再操作 |

> 📌 按铁律「未经明确指令不部署」⇒ **本轮未部署**。
> 要部署的话说一声，我走：CI 同款预检 → push main → tag `v0.1.2` → SSH 直查验证。

---

## 七、产出

| 文件 | 内容 |
|---|---|
| 本报告 | 四项指令的完整记录 |
| 提交 `82bddc8` | HN 清理（6 文件 + 迁移 + 演练 + 证伪）|
| `scripts/troubleshoot/dart_subprocess_check.dart` | 🆕 环境诊断最小复现 |
| skill `verifiable-core-logic` | 主文件瘦身 46% + 新增 `references/assertion-rules-12-20.md` |
| VPS `backups/pre-vacuum-20261003-130848.db` | VACUUM 回滚点（21.5 MB）|
