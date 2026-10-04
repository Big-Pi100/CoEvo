# 断言脚本普查 —— 谁在 CI 里、谁不在、谁红了

> **2026-10-04** · 起因：`tokens_verify`（688 项）**在 CI 之外**红了 4 项而无人知晓
> （改「阅读 tab 标题栏」时，CI 只报 2 项，另 4 项在它那里）⇒ 白哥「同意普查」。
>
> **一句话结论**：**45 个脚本，0 个红的断言** —— 但 **30 个不在 CI 里**（占 2/3），
> 其中 **19 个是可以接进去的**（合计 **849** 项断言目前**没有门禁保护**）。

---

## 一、普查方法（**先写清口径，否则数字没意义**）

```bash
# 枚举（含所有子目录 bin/*.dart）
scripts/*/bin/*.dart                       → 45 个

# 判定「在不在 CI」：读 ci.yml，**含 step 级 working-directory 覆盖**
#   ⚠️ 不能只看 job 级 wd —— 本仓库有两个 step 用 step 级 wd 跑到 query_verify
#      （见 ci.yml 的 verify_feed_wiring / verify_auth_entry）

# 逐个执行：cwd = **包根**（scripts/<pkg>），命令 dart run bin/<name>.dart，超时 60–90s
```

### 🔴 口径坑（第一次跑就踩，值得写下来）

| # | 踩到的 | 后果 | 修法 |
|---|---|---|---|
| ① | `cwd` 写成 **`bin/`** 而非**包根** | **12 个脚本报 255「文件找不到」** —— 看起来像「脚本全坏了」，实际是**我的错** | cwd = `scripts/<pkg>`（脚本里用 `../../app/lib/...` 相对路径） |
| ② | `subprocess` 的 `timeout` **杀不掉 dart 的孙进程** | 父进程被杀但读管道仍阻塞 ⇒ **整体挂死 22 分钟** | 用 `timeout` 命令包一层，或只跑「快脚本」，长脚本单独处理 |

📌 判据：**「工具/写法错 → 静默假结论」** —— ①正是本项目记过的那一族：
**检测器本身错了，输出了看起来很像结论的东西**（12 个 255）。
⇒ 报「N 个脚本坏了」之前，先确认**是我的调用方式对**。

---

## 二、在 CI 里的（15 个 · 已覆盖 **1340** 项）

| job | 脚本 | 项数 |
|---|---|---|
| `fsrs-verify` | verify.dart / verify_service.dart | 19 / 39 |
| `trace-verify` | verify_unescape | 71 |
| | verify_trace_markdown | 43 |
| | verify_feed_pager | 54 |
| | verify_interest_selection | 38 |
| | verify_feed_wiring（`wd=scripts/query_verify`）| 71 |
| | verify_auth_entry（同上）| 49 |
| | **verify_tokens（本轮新增）** | **688** |
| `iap-verify` | verify_iap_plan | 106 |
| `ebook-verify` | verify_txt_parser / verify_epub_parser | 35 / 30 |
| | verify_book_import_plan / verify_book_importer_sql | 34 / 9 |
| | verify_reading_tab | 54 |

---

## 三、不在 CI 的（30 个 · 分三类）

### A. 🟢 **CI 候补 —— 建议立即接入：7 个（184 项）**

**判据（逐条核实，不是「看着像纯 Dart」）**：`pubspec` 零依赖 + 只 `import dart:io`（或 `dart:math`）
+ 只 import **零 Flutter 依赖**的 `app/lib` 源文件。

| 脚本 | 项数 | 它 import 的 app 源 | 该源是否零 Flutter |
|---|---|---|---|
| `verify_achievement_rules` | 55 | `services/achievement_rules.dart` | ✅ 无 import |
| `verify_app_version` | 6 | （无） | — |
| `verify_article_text` | 19 | `services/article_text.dart` | ✅ 无 import |
| `verify_device_id` | 47 | `services/device_id.dart` | ✅ 仅 `dart:math` |
| `verify_reading_completion` | 13 | `services/reading_completion.dart` | ✅ 无 import |
| `verify_worddb_bootstrap` | 38 | `services/word_db_bootstrap.dart` | ✅ 仅 `dart:typed_data` |
| `verify_worddb_sync` | 6 | （无 · 读两个 `word.db` 比 hash）| — |

**实测：7 个全绿**（本机，cwd=包根）。
⚠️ `verify_worddb_sync` / `verify_worddb_bootstrap` 需要 `data/word.db` 与 `app/assets/word.db`
—— **两者都已入库**（各 33 MB）⇒ CI 上有文件 ✅。

### B. 🟡 **需 `sqflite_common_ffi` —— 但库是「自建临时库」或「仓内文件」：12 个（665 项）**

🔴 **这组推翻了此前的假设**「要连真库的不能进 CI」。逐条核实**库从哪来**：

| 脚本 | 项数 | 库来源 | 能否进 CI |
|---|---|---|---|
| `verify_userdb_migration` | 157 | `systemTemp` **自建** | ✅ |
| `verify_generated_card_adapter` | 75 | `data/word.db`（**已入库**）| ✅ |
| `verify_word_query` | 64 | `data/word.db`（**已入库**）| ✅ |
| `verify_review_list` | 60 | `createTempSync` **自建** | ✅ |
| `verify_user_word` | 54 | `systemTemp` **自建** | ✅ |
| `verify_bookmark` | 52 | `createTempSync` **自建** | ✅ |
| `verify_word_id_convergence` | 46 | `systemTemp` **自建** | ✅ |
| `verify_achievement_service` | 37 | `systemTemp` **自建** | ✅ |
| `verify_external_word_cache` | 33 | `systemTemp` **自建** | ✅ |
| `verify_spelling_grader` | 32 | `app/assets/word.db`（**已入库**）| ✅ |
| `verify_pos_display` | 31 | `data/word.db`（**已入库**）| ✅ |
| `verify_article_read` | 24 | `systemTemp` **自建** | ✅ |

**实测：12 个全绿。**

🔑 为什么此前被当成「不能进 CI」：判据写的是「**要连真库的那些**（`sqflite_common_ffi` + 端侧 `user.db`）才不能进 CI」
—— 但**「用 sqflite_common_ffi」≠「依赖我本机的库」**：它们自己 `createTempSync` 造库。
**按「是否需要本机数据」来分**，这 12 个全部满足「不需要」。

⚠️ **唯一未验证点（如实标注）**：`ubuntu-latest` 上 `sqflite_common_ffi` 能否加载 sqlite3 原生库。
本机是 Windows（跑通）；CI 是 Linux。**我不能在本机验证 Linux 行为**。
⇒ 建议：接入时在 step 里显式 `sudo apt-get install -y libsqlite3-0`（去掉这个不确定性），
或**先接 1 个**看 CI 是否绿，再批量接。

### C. ⛔ **探针 / 工具 —— 不该进门禁：11 个**

| 类别 | 脚本 | 为什么不接 |
|---|---|---|
| 探针（需 fixture / 参数 / SSH）| `probe_all` · `probe_dot` · `probe_effect` · `probe_gate` · `probe_prod_bodies` | `probe_gate`/`probe_prod_bodies` 需**从生产导出的 fixture**；`probe_all` 实测**超时**（疑似走 SSH/大数据）；**探针输出不是判据** |
| 基准 / 探针 | `bench` · `query_probe` | 打印 p50/p95 或探测可用性，**无通过/失败语义** |
| 调试工具 | `fsrs_verify/debug_replay` | 打印两种口径的对比，供人看 |
| 本地分析工具 | `analyze_inproc/analyze` · `codestatic/check` · `static_check/check` | **与 CI 的 `flutter analyze` 重复**（且 `codestatic` 自己写明「不接 CI，收益为零」）；`analyze`/`check` 需传路径参数（无参时退出码 2 = 用法错，不是失败）|

📌 判据：**能进 CI 的只有「自带全部输入 + 不重复既有门禁」的**（本仓库已写过这条）。
C 组两类都不满足。

---

## 四、红的脚本：**0 个**

45 个里，凡**有通过/失败语义**的断言脚本**全部绿**。非零退出的只有：
- `analyze_inproc/analyze` → **2**（用法：需传文件/目录参数）= 我在普查里没传参
- `probe_gate` / `probe_prod_bodies` → **1**（缺 `fixtures/prod_*.json`，按设计如此）
- `probe_all` → **超时**（探针，非断言）

---

## 五、建议（**待批准后实施**）

| 优先 | 动作 | 规模 | 风险 |
|---|---|---|---|
| 🟢 高 | **A 组 7 个接入 `trace-verify` job**（step 级 `wd`；零依赖、零新增 runner） | +184 项 | 极低（纯 `dart:io`，实测全绿）|
| 🟡 中 | **B 组 12 个接入新 job `db-verify`**，step 里先 `apt-get install -y libsqlite3-0` | +665 项 | 低（自建临时库 ⇒ 与仓库状态无关）；⚠️ 唯一不确定点是 Linux 上 sqlite3 的加载 |
| ⛔ — | C 组 11 个**保持现状** | — | — |

**若两组都接**：CI 覆盖从 **1340** 项 → **2189** 项，
「无门禁保护的断言」从 **849** 项 → **0**。

---

## 六、附：本轮已做的改动

- ✅ `tokens_verify`（688 项）已接入 `trace-verify` job（白哥定）
- ⚠️ 本报告**只出结论，不改代码** —— A / B 两组待批准
