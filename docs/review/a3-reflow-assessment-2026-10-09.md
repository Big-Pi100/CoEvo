# A3 · LLM 制卡回流 — 调查报告 + 方案 + **实施记录**（2026-10-09）

> 来源：`docs/design/llm-card-online-path-2026-09-29.md` §11.7 的任务表
> 状态：🔴 **只出方案，未改任何代码**（按项目铁律：代码变更须先报告 → 请示 → 实施）
> 触发：待办清单里**唯一剩下**的产品功能项（`docs/review/pending-todos-2026-10-09.md` §一.2）

---

## 〇、先说结论（两条，都重要）

1. ✅ **该做** —— 它是**通道缺失**：没有它，「用户高频查 + LLM 已生成」的卡**永远进不了词库**
   （`word.db` 是离线层，只能靠**版本发布**更新 ⇒ 没有回流脚本，这条链就是断的）。
2. 🔴 **但要清楚：现在做出来的是「通道」，不是「数据」** —— 实测线上**没有任何词够热**：

| 实测（2026-10-09 · 线上只读） | 值 |
|---|---|
| `generated_card_cache` 行数 | **10** |
| `hit_count` 最大值 | **1** |
| `distinct_user_count` 最大值 | **1** |
| `generated_card_hit`（去重明细）行数 | **2** |
| 任意门槛（K≥3 / 5 / 10 / 20 / 50）下够热的词数 | 🔴 **全部 0** |

⇒ 结合「**当前零真实用户**」：`distinct_user_count` **不会自己长**。
所以 A3 上线后的**真实产出 = 通道就绪 + 门槛固化**，等有用户量时它**自动开始工作**。
📌 这也是为什么它排在最后 —— 不是不重要，而是**它的价值要等数据**。

---

## 一、A3 是什么（规格原文，不改一字）

> `llm-card-online-path-2026-09-29.md:1689`
> | **A3** | **回流脚本**（`hit_count ≥ K` 快照 → **过闸门** → 合并进 `word.db`） | ✅ 我（本地跑） | A1（要有 cache 数据）|

链条位置：**三层缓存**里 `word.db` 是**离线层**；① 端侧 `external_word_cache`、② 服务端 `generated_card_cache` 都只是**临时层** ⇒ A3 是 ②→③ 的唯一通道。

---

## 二、现状取证（逐项实测，不是引文档）

| 项 | 实测结论 | 对 A3 的意义 |
|---|---|---|
| **A1 前置** | ✅ `generated_card_cache` 表在、`/api/generate-card` 在（线上 400/422 实证）、写入链路在（10 行数据）| 数据源可用 |
| **端侧收敛** | ✅ **已接线**：`word_db_provider.dart:159` `_convergeExternalWordIds` 在**词库就绪时**跑，把 `ext:<拼写>` 收敛成正式 `word.id`（`word_id_convergence.dart`）| 🔑 **A3 的关键前置已具备** —— 回流的词一进 `word.db`，用户端的 `ext:` 会自动收敛（**不需要额外做什么**）|
| **版本发布** | ✅ `gen_word_db_version.py`（从 `word.db` 生成指纹）+ `sync_word_db_asset.py`（同步到 `app/assets` 并校验）| 回流后**收尾**直接复用，不新写 |
| **端侧更新判据** | `word_db_bootstrap.dart:27-44`：「**版本号 或 大小**」——版本不同就复制；版本相同再比大小兜底 | 🔴 **回流必须更新版本指纹**，否则「同大小不同内容」会**静默不更新**（这正是当年从「只看大小」升级的原因）|
| **现成写库管线** | `llm_match_cards.py` / `fill_card_content_llm.py`（预制词库的制卡与落库）、`coevo_wordlib_contract.py`（契约 + LLM 调用）、`audit_generated_card_cache.py`（缓存合规审计）| 可复用它们的**写库惯用法**（但**不能**复用其转换逻辑，见 §三①）|
| **`word.db` 规模** | 19 表 / **11523 词**；`word(id PK, sort_seq UNIQUE, spelling UNIQUE, …)` · `card(word_id PK, content, content_hash, template_code)` | 回流要分配 `id`（`w0%06d`，现最大 `w011523`）与 `sort_seq`（`UNIQUE NOT NULL`）|

---

## 三、🔴 三个必须先定的设计点（本次调查的主要产出）

### ① 形状转换只能有**一处**权威 —— 否则必然分叉

| 层 | 存的是什么 |
|---|---|
| 服务端 `generated_card_cache.card_content` | 🔴 **LLM 的原始输出**（平铺字段：`collocations` / `definition` / `etymology` / `ipa` / `morphology` …）|
| 端侧 `external_word_cache.card_content` | ✅ **转换后**的形状（`{front, ipa, entry_type, sections:[…]}`）= `word.db.card.content` 的形状 |
| 那个转换的**唯一实现** | `app/lib/services/generated_card_adapter.dart::toCardContent`（**Dart**）|

⇒ A3 若用 **Python** 写，就必须**照抄一份转换** ⇒ **第二份实现**（Dart / Python 分叉，
而项目的 `sync-implementation-assessment` 明确写过：**同一件事的口径只能一处权威**，分叉是静默的）。

✅ **落法：A3 用 Dart 写**（放 `scripts/` 下），直接 `import` 那个适配器 ⇒ **转换永远只有一份**。
   项目已有大量 Dart 脚本先例（`scripts/query_verify/*`），且能用 `sqflite_common_ffi` 直接读写 `word.db` ✅。
   ⚠️ 代价如实标注：**Dart 脚本本机不能 spawn 子进程**（`Process.start` 必崩 231）⇒ **不能在脚本里调 `ssh`** ⇒ 见 §四方案 A 的两段式。

### ② 「过闸门」不必在脚本里复刻 —— 因为**缓存里的行都已经过闸门了**

服务端写缓存**之前**的顺序是：`LLM → 合规闸门（compliance::check_card）→ 格式闸门（gate）→ 写缓存`
（且**闸门失败不写缓存**，见 `llm_card.rs:501-511` 的注释）⇒ **凡是能在缓存里读到的行，都过了闸门**。

⇒ A3 只需补两件**很轻**的事：
- **契约版本核对**：`contract_version != 'v6'` ⇒ **跳过**（与端侧同策略，不猜字段）
- **结构校验**：复用**同一个** `toCardContent`（它的失败路径本来就是严格的：缺 `definition` → 显式抛错）
  ⇒ 转换失败 ⇒ **不写库**（绝不留半张卡）

### ③ 回流只能补「**一张卡**」，补不了关系型数据（如实标注）

| `word.db` 表（行数） | 回流能不能产 | 为什么 |
|---|---|---|
| `word`（11523）· `card`（11523）| ✅ **能** | LLM 输出直接够（spelling / entry_type / content）|
| `word_mnemonic_profile`（11523）| ⚠️ 可选 | 需要「记忆法槽位」映射；**缺也不影响复习**（端侧 `profile == null` ⇒ 只渲染 ③④，见 `review_session_provider` 的注释）|
| `aggregate_page`（1777）· `cognate_group`（2650）· `etymon`（8384）· `collocation`（30174）· `word_form`（24140）| ❌ **不能** | 这些来自**全量语料分析**（同源词/词根族/搭配网络），**单张卡推不出来** |

⇒ **A3 的最小正确范围 = `word` + `card` 两表**（+ 分配 `id` / `sort_seq`）。
🔑 **后果要写在脸上**：回流词**没有聚合页 / 同源词 / 词根族 / 搭配表 / 词形链**
（用户查它的变形也命中不了 ⇒ 只能精确拼写命中）。
📌 若将来要补齐这些，那是**另一件事**（「关系补齐」），不要混进 A3。

---

## 四、方案（3 个，推荐 A）

### 方案 A ⭐ **两段式离线脚本**（导出 → 回流）

```
① 导出（bash + ssh，一条命令）：
   ssh -i ~/.ssh/coevo_key ubuntu@<VPS> "python3 - 3" < scripts/reflow/export_candidates.py \
     > /tmp/reflow_candidates.json
   🔑 已**实测验证**该命令形态：K=3 → {"count": 0}；K=0 → 10 行，raw_card 是合法平铺 JSON

② 回流（Dart 脚本，本机跑）：
   dart run scripts/reflow/reflow_into_word_db.dart /tmp/reflow_candidates.json \
     --word-db data/word.db（→ 先拷副本干跑）
   做四件事：toCardContent（**唯一转换**）→ 契约/结构校验 → **幂等**写 word+card → 生成版本指纹
```

- ✅ 转换唯一权威（Dart import）· **零凭据硬编码**（主机走环境变量/命令行，不写进脚本）· 可重复
- ⚠️ 不能一键端到端 —— 但**导出那条本来就需要 SSH 凭据**，让它留在命令行反而更干净
- ⚠️ 本机跑 Dart 脚本**不能** spawn 子进程 ⇒ 只能这样两段（如实标注，这不是偷懒）

### 方案 B **加服务端内部接口**（`GET /api/internal/reflow-candidates`）

- 脚本直接 HTTPS 拉候选，无需 ssh
- ❌ 代价：**再加一条对外路由**（而 `admin/*` 路由**刚刚全删干净**）+ 要设计鉴权 ⇒ **攻击面与维护面都变大**
- ⇒ 只有「将来要**定时自动**回流」时才划算；**现在不建议**

### 方案 C ❌ Python 重写转换 —— **不做**

第二份转换实现 ⇒ 与 Dart 必然分叉（且分叉是静默的：字段少一个 → 卡片少一段，只有用户看得见）。

---

## 五、门槛 K（**需要你定**，定完写进脚本常量 + 断言）

| 候选 | 含义 | 评价 |
|---|---|---|
| **`distinct_user_count ≥ 3`** ⭐ | **3 个不同设备**查过 | 记忆里的既定口径：**`hit_count` 只管回流门槛，去重看 `distinct_user_count`** ⇒ 用 distinct 才不会被「一个人刷 100 次」骗到 |
| `hit_count ≥ 5` | 总次数 ≥ 5 | 更松，但**单人可刷出来** ⇒ 会把噪声当需求 |
| `distinct_user_count ≥ 5` | 更严 | 更保守；考虑到**零真实用户**，会更晚开张 |

⚠️ **共同事实**：现在**任何门槛下都是 0** ⇒ 门槛取得松一点**不会**造成误回流，只会让它更早开张。
⇒ 我建议 **`distinct_user_count ≥ 3`**（= 口径最正的那个），并把 K 做成脚本参数（默认 3）。

---

## 六、改动面与验证计划

| 项 | 内容 |
|---|---|
| 🆕 新增 | `scripts/reflow/export_candidates.py`（只读导出 · 运维用）<br>`scripts/reflow/reflow_into_word_db.dart`（**转换 + 校验 + 写库**）<br>`scripts/query_verify/bin/verify_a3_reflow.dart`（断言）|
| 改动 | **零**：不碰 `app/lib`（转换器只 `import`）· 不碰 `backend/`（不加路由）|
| 断言（每条都要**证伪**）| ① **幂等**：同输入跑两次 ⇒ 行数不变（`UNIQUE(spelling)` 不该炸）<br>② **只写 `word`+`card`**（不误写关系表 —— 用**表级行数差**核对）<br>③ `id`/`sort_seq` **不冲突**（从 max 续号）<br>④ 契约版本 ≠ v6 ⇒ **跳过**（不猜字段）<br>⑤ 转换失败 ⇒ **不写库**（不留半张卡）<br>⑥ 已在 `word` 表的词 ⇒ **跳过**（不重复插）<br>⑦ 版本指纹**真的变了**（否则端侧静默不更新）|
| 真跑 | **先拷 `data/word.db` 副本干跑**（绝不直接改仓库源库）· 拿 `K=0` 的 10 个词做样本 · 对照 `card.content` 与端侧渲染形状 |
| 风险 | ① 词库体积：每词约 1.2 KB ⇒ **即便回流 1000 个也只 +1.2 MB**（可忽略）<br>② 发版成本：端侧按**版本号**判断 ⇒ 只在**真的回流了词**时才需要发版（现在 0 个 ⇒ **不必发版**）|

---

## 七、白哥裁决（2026-10-09）

> **「A3 制卡回流还是要做 —— 方案 A」**

| 待定项 | 裁决 |
|---|---|
| 做不做 | ✅ **做** |
| 方案 | ✅ **A**（两段式离线脚本）；未采用 B（加对外路由 —— 与「`admin/*` 路由刚删干净」相悖）|
| 门槛 K | 脚本参数，**默认 `distinct_user_count >= 3`**（可命令行覆盖；本次为验证用 K=0）|

---

## 八、实施结果（同日完成）

### 新增文件（**改动面为零**：`app/lib` / `backend/` 一字未改）

| 文件 | 作用 |
|---|---|
| `scripts/reflow/export_candidates.py` | 只读导出候选（走 `ssh "python3 - K"` stdin；参数：K、库路径）|
| `scripts/reflow/lib/reflow.dart` | **核心**：`toCardContent`（唯一形状转换）→ `pyJsonEncode` → `contentHashOf` → 幂等写 `word`+`card` |
| `scripts/reflow/bin/reflow_into_word_db.dart` | CLI（**两道安全闸**：默认干跑 + 默认拒写源库）|
| `scripts/reflow/bin/verify_reflow.dart` | **55 项**断言 |
| `scripts/reflow/pubspec.yaml` | 子项目（精确 pin `sqflite_common_ffi 2.3.4+4` + `sqlite3 2.9.4` —— 原因见 §九坑①）|

### 验证

| 项 | 结果 |
|---|---|
| 🆕 `verify_reflow` | **55 通过 / 0 失败** |
| **证伪 6 条** | 全部：注入 ⇒ 变红 ⇒ **逐字节还原**（其中 1 条**重做**过，见 §九坑②）|
| `analyze_inproc` | **error=0 warning=0** |
| `tokens_verify` | **699 通过 / 8 失败 = 存量基线，无新增** |
| `verify_script_portability` · `verify_generated_card_adapter` · `verify_external_word_card` | **19** · **75·0** · **79·0** 全绿 |

### 🔑 最强的一条断言（值得单独说）

> `pyJsonEncode` 与**既有 `word.db` 的全部 11523 行** `card.content` **逐字节一致**。

它做两件事：
1. **把「跨实现序列化一致」从「我觉得一样」变成可验证** —— 而且是**全量覆盖**，不是抽样；
2. 成为**回归防线** —— 谁改了这个序列化器（比如"优化"成紧凑格式），先在这里炸。

📌 同族判据：**跨实现「保持一致」必须落到每个共享定义上**，而且要**可执行**。

### 端到端干跑（真实线上数据）

```
导出（K=0，只读线上）→ 拷 word.db 副本 → 干跑 → 真写 → 幂等复跑 → 库内校验
```

| 检查 | 结果 |
|---|---|
| 候选 | **10 条**（`fixtures`…`zeppelin`）|
| 插入 | **10 条**：`w011524`–`w011533`（从源库末号 `w011523` **正确续号**）|
| **幂等复跑** | **0 插入 / 10 跳过**（"词库已有"）|
| `hash == sha256(content)[:32]` | **10/10** |
| content 可被 Python `json.dumps` 复现（格式对齐）| **10/10** |
| `spelling` 已归一化（小写）| **10/10** |
| 其余 **7 张表**行数 | **一字未变** ✅（`aggregate_page` / `cognate_group` / `etymon` / `collocation` / `word_form` / `card_extra` / `word_mnemonic_profile`）|

### ⚠️ 用的时候的顺序（缺一不可）

```bash
# ① 导出
ssh -i ~/.ssh/coevo_key ubuntu@111.230.197.4 "python3 - 3" \
  < scripts/reflow/export_candidates.py > /tmp/reflow_candidates.json

# ② 回流（先拷贝副本干跑；确认后再写源库）
cp data/word.db /tmp/word_copy.db
cd scripts/reflow && dart run bin/reflow_into_word_db.dart /tmp/reflow_candidates.json --db /tmp/word_copy.db

# ③ 🔴 写源库后**必须**跑这两步，否则端侧**静默不更新**词库
python scripts/gen_word_db_version.py     # 刷新版本指纹
python scripts/sync_word_db_asset.py      # 同步到 app/assets
```

🔴 **注意**：③ 的两步**只在真的写了词**的时候才需要 —— 而**现在 0 个词够热** ⇒ 本次**没有**执行 ③，也**不需要发版**。

## 九、实施中踩到的两个坑（都已记入判据）

### 坑① 「本机不能 spawn 子进程」还会**从依赖层**冒出来

新建 `scripts/reflow` 子项目、写 `sqflite_common_ffi: ^2.3.4` ⇒ pub 解析到 **2.4.0+3**
⇒ 它依赖 **`sqlite3 3.7.0`**，而后者带 **native assets build hook**（`hook/build.dart`）
⇒ `dart run` 会 spawn `cmd.exe /c dart compile kernel` 编译它 ⇒ **本机管道限制直接崩**：

```
CreateFile failed 231
ProcessException: 所有的管道范例都在使用中。
  at ../../runtime/bin/process_win.cc:742
```

🔑 **为什么 `scripts/query_verify` 却没事**：不是它版本选得好，而是它 9 月生成的
`pubspec.lock` 恰好**冻结**在 `sqlite3 2.9.4`（无 hook）—— 是**运气**，不是设计。
✅ 修法：`sqflite_common_ffi: 2.3.4+4`（去掉 `^`）**并且显式 pin `sqlite3: 2.9.4`**
（后者必需：前者对 `sqlite3` 的约束是 `>=2.4.0 <4.0.0`，光 pin 前者不够）。

📌 **判据**：**「本机不能 spawn 子进程」不只是「别在脚本里调外部命令」** ——
连**依赖自带的 build hook** 都会触发。新加依赖时，**必须看解析到的版本有没有 `hook/`**。

### 坑② 证伪时「注入导致崩溃」**不等于**「断言生效」

证伪「回流偷偷多写一张表」时，我把注入写成插入 `aggregate_page(id='zzz')` ——
结果它撞上哨兵行的主键 ⇒ **第 ③ 段就崩了**（EXIT=255），而我要验的那条断言（在 ④ 段）
**根本没跑到** ⇒ 等于**没验证**。

✅ 重做：改成插入 `word_form`（无唯一约束）⇒ 得到**干净的断言红**：
`🔴 word_form 不变（词形链来自全量语料） 实得 2 · 期望 1`。

📌 **判据**：证伪不能只看「退出码非 0」 —— 必须**核对是哪一条断言的输出**。
崩溃会让「没跑到」伪装成「抓到了」。（同族：**「红灯」要看清是谁点的**。）

*2026-10-09 · 方法：读规格原文 → 线上只读实测 → 读 word.db schema 与端侧更新判据 → 出方案 → 实施 + 55 项断言 + 6 条证伪 + 真实数据端到端干跑*
