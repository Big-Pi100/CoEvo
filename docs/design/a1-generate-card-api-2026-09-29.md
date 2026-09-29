# A1 交付：`POST /api/generate-card`（在线制卡全链路 · 本地已验证）

> 2026-09-29 12:4x~13:0x ｜ 触发：白哥「甲，开始」（批 A1 + 主域占位页方案）
> **本步纯本地** —— 未部署、未碰生产服务器（白哥的机子仍是零改动状态）。
> 前置规格：`on-demand-generation-server-side-2026-09-26.md`（九步流）· `llm-card-online-path-2026-09-29.md` §二十一

---

## 一、一句话结论

🔴 **能跑通了，但还「不能上线」** —— 差一件事：**合规扫描**（见 §六）。

全链路已实测打通：**查缓存 → 未命中调 LLM → 客观闸门 → 写全局缓存 → 返回**，
且 **并发去重真实生效**（3 个并发请求只触发 1 次 LLM 调用）。

---

## 二、范围：做了什么 / 明确没做

| | 内容 |
|---|---|
| ✅ **做了** | 2 张表 · LLM 调用器扩展 · `llm_card.rs` 核心模块 · handler + 路由 · 本地端到端验证 |
| 🔴 **没做（阻塞上线）** | **合规扫描**（涉主权/涉政/涉黄暴/涉歧视）—— 见 §六 |
| ⏳ **没做（属 A2）** | 端侧 `external_word_cache` + 未命中分支 + 转圈 UI + 失败重试 |
| ⏳ **没做（属 A3）** | 回流脚本（`hit_count ≥ K` 快照 → 过闸门 → 并入 `word.db`） |

---

## 三、🔑🔴 关键发现：**「复用现成调用器」≠「同一套」**

白哥第 ① 条要求「在线生成与预制**同一套** prompt / 契约 / 校验」。
我原以为「复用 `chat_engine::llm_caller` 就够了」—— **实测发现两边参数根本不一致**：

| 参数 | Python（预制 `call_llm`） | `LlmCaller` 默认 | 差在哪 |
|---|---|---|---|
| `model` | **`deepseek-flash`** | `deepseek-v4-flash` | 🔴 **名字不同**（且前者才是实测有效的） |
| `max_tokens` | **900** | **65536** | 🔴 **73 倍** |
| `temperature` | **0.1** | **0.7** | 🔴 词卡要**确定性**，0.7 随机性大 |
| `response_format` | `{"type":"json_object"}` | **无** | 🔴 可能返回非 JSON（prompt 只写 "Output JSON only"，**无强制**） |
| `thinking` | `{"type":"disabled"}` | **无** | 🔴 **成本可能差数倍**（见 skill `llm-batch-content-fill`） |
| `messages` | 单条 `user`（prompt 全文） | `system` + `user` | ⚠️ 同形但语义不同 |

🔑 **直接复用 = 产出与预制「不同的一套」** —— 表面上「用同一个调用器」，实际上**参数全不一样**。

### 解决（三处对齐）

1. **prompt** → 抽成**单一文件** `backend/prompts/wordlib_contract.md`，**Python 与 Rust 都读它**
   （Python 侧 `coevo_wordlib_contract.py` 改为读文件；**逐字节验证相同**，见 §五①）
2. **参数** → 在 `llm_card.rs` 里**显式写死**与 Python 一致的常量（`MODEL`/`MAX_TOKENS`/`TEMPERATURE`）
3. **缺失字段** → 给 `LlmCaller` **新增** `generate_with_extra()`（**不改现有方法**），可 merge 额外请求体字段
4. **messages 形状** → 传**空 system** `generate_with_extra("", prompt, extra)` →
   产出 `[{role:user, content:prompt}]`，**与 Python 完全一致**

> 🔑 **这条判据值得记住**：**「复用同一个组件」不等于「同一套行为」** ——
> 组件的**默认参数**可能与被对齐的对象**完全不同**。
> 要对齐的是**最终发出的请求**（含参数），不是「用了哪个函数」。

---

## 四、交付物（逐文件）

| 文件 | 改动 | 说明 |
|---|---|---|
| 📝 `scripts/coevo_wordlib_contract.py` | −135/+23 行 | 内联 `PROMPT` 改为**读单一文件**（带「文件不存在/为空」的显式报错） |
| 🆕 `backend/prompts/wordlib_contract.md` | 134 行 / 11,580 B | **契约 prompt 的唯一来源**（Python + Rust 共用） |
| 📝 `backend/crates/api_server/src/schema.rs` | +63 行 | 🆕 `WORDLIB_SCHEMA_SQL`（2 张表）+ `init_database` 里执行 |
| 📝 `backend/crates/chat_engine/src/llm_caller.rs` | +85 行 | 🆕 `generate_with_extra()` + 抽私有 `post_with_retry()`（**`generate` 行为不变**） |
| 🆕 `backend/crates/api_server/src/llm_card.rs` | ~460 行 | **核心模块**：闸门 / 缓存读写 / in-flight 去重 / 主流程 / 5 个单测 |
| 📝 `backend/crates/api_server/src/lib.rs` | +2 行 | `pub mod llm_card;` |
| 📝 `backend/crates/api_server/src/routes.rs` | +100 行 | `POST /api/generate-card` 路由 + handler |

### 表设计（2 张）

```sql
CREATE TABLE generated_card_cache (
    spelling            TEXT PRIMARY KEY COLLATE NOCASE,  -- 去重靠 PK（不靠 hit_count）
    card_content        TEXT NOT NULL,                    -- 与 word.db 的 card.content 同构 → 回流可复用落库链
    contract_version    TEXT NOT NULL,                    -- 🔴 契约升级后可识别/失效陈旧缓存
    source              TEXT NOT NULL DEFAULT 'llm-online',
    hit_count           INTEGER NOT NULL DEFAULT 0,       -- 只管回流门槛
    distinct_user_count INTEGER NOT NULL DEFAULT 0,       -- 🆕 真需求信号（避免同一人刷）
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE generated_card_hit (                          -- 只为算 distinct
    spelling TEXT NOT NULL COLLATE NOCASE,
    device_id TEXT NOT NULL,                               -- 🔑 匿名设备标识（不涉登录）
    first_hit_at TEXT NOT NULL, hit_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (spelling, device_id)                      -- PK → 天然去重
);
```

---

## 五、验证（三层 · 全部可复跑）

### ① prompt 抽取：**逐字节相同**（这是最强的判据）

```
提取长度 11216 字符
交叉验证：import 出来的 PROMPT == 抽出的文本 → True
文件 rstrip 后长度 == 11216                        ← 逐字节相同
→ 冒烟 smoke_contract.py：10/10 · ¥0.0651 · 0 告警   ← 证明改动没影响契约
```

### ② 单元测试（Rust）**5/5**

```
test llm_card::tests::gate_rejects_bad_cards ... ok     ← 闸门（ipa 残缺 / 例句不含该词）
test llm_card::tests::ipa_full_detection ... ok         ← S1 那类残缺能被挡
test llm_card::tests::context_word_check ... ok         ← 规则变形（run→runs / make→making）
test llm_card::tests::spelling_validation ... ok
test llm_card::tests::prompt_placeholder_replace ... ok
```

### ③ 端到端（`cargo run` + HTTP · 独立测试库 `data/test-llm-card.db`）

| 场景 | 结果 |
|---|---|
| 空 `spelling` | **400** `spelling 不能为空` ✅ |
| 非法字符 `bad!word` | **400** `含不支持字符` ✅ |
| **首次生成** `brainstorm` | **200 · `from_cache=false` · 1.90s** ✅ |
| 产出质量 | `ipa='/ˈbreɪnstɔːm/'` · `def[v] en='to generate ideas…' zh='头脑风暴，集思广益'` · `context="Let's brainstorm some ideas for the new project."` |
| **字段完整性** | `collocations · confidence · context · definition · derived_from · entry_type · etymology · ipa · is_own_entry · mnemonic · morphology · reason · word` ← **13 个字段，与预制同一契约** ✅ |
| **再查（缓存）** | **200 · `from_cache=true` · 0.01s**（**190 倍加速**）✅ |
| 第三个请求（另一 device） | `hit_count=2` ✅ |
| **库内容** | `contract_version=v6` · `source=llm-online` · `hit=2` · `distinct=2` · `card_bytes=979` ✅ |
| **hit 表** | 2 行（`dev-test-A` / `dev-test-B`）✅ |

### ④ 🔑 并发去重（L0 §4.3 的硬要求）

同一新词 **同时发 3 个请求**：

```
#   HTTP  ok   from_cache  耗时
0   200   True  False      1.93s   ← 只这一个真生成
1   200   True  True       1.96s   ← 等到缓存
2   200   True  True       1.98s   ← 等到缓存

生成=1 · 命中缓存=2 · 失败=0        ✅
```

**日志是最终证据**：`MISS→LLM = 2`（= `brainstorm` + `serendipity` 两个不同的词）
→ **3 个并发请求只产生 1 次 LLM 调用** ✅

---

## 六、🔴 阻塞上线的一件事：**合规扫描**

`scan_compliance.py`（涉主权 / 涉政 / 涉黄暴 / 涉歧视 · P0 闸门）**目前只在 Python 侧**（离线全库扫描）。

在线路径**缺这一步** → **生成的内容未经合规检查就返回给用户**。
按 `wordlib-on-demand-growth-2026-09-26.md` §4.1：**动态生成无人工环节，合规风险直接暴露** ——
「涉主权」是最硬的（`taiwan`/`tibet` 曾出过错，已修；新生成的词**没有任何人工审核**）。

### 建议做法（同 prompt 的思路：**数据共用，逻辑各写**）

| 层 | 做法 |
|---|---|
| **词表/规则** | 抽成**数据文件**（JSON/TOML），Python 与 Rust **都读它** → 避免判据分叉 |
| **判定逻辑** | Rust 侧实现**核心组合判定**（敏感主体 × 主权措辞同现等 5 条铁律） |
| **位置** | 在 `gate()` **之前**（合规不过 → **拒绝 + 告警 + 不写缓存**） |

⚠️ 这是**独立的一块工作**（Python 扫描器有 5 条铁律 + 29 项验收），
建议作为 **A1b** 单独做 → 完成后 A1 才能算「可上线」。

---

## 七、🔴 顺带查出的**基线问题**（**非本轮引入**，需请示）

`cargo test -p api_server` 实测：**60 passed / 3 failed** —— 3 个失败**全是「退役工作的残留**」：

| 失败测试 | 报错 | 根因 |
|---|---|---|
| `campaign_scheduler::tests::test_trial_hard_delete` | `no such table: conversations` | `conversations` 已退役（09-29） |
| `schema::tests::test_core_table_columns` | `user_cards 缺 plan_run_id` | `user_cards` 已退役 |
| `schema::tests::test_full_schema_all_tables_present` | `新表 achievements 不存在` | `achievements` 已退役（改端侧计算） |

**另有两处同源残留**（静态查出，未实测）：

| 位置 | 内容 | 风险 |
|---|---|---|
| `schema.rs` 的 `run_migrations_inner` | **42 处**对退役表的 `ALTER`（`card_memory` / `user_cards` / `prebuilt_*` …） | 🟠 被容错**静默跳过**（忽略 `no such table`）→ 现在无害，但**掩盖真错**（表名写错也不报） |
| `schema.rs` 的 `EXPECTED_NEW_TABLES`（测试常量） | 列了 `card_memory` / `conversations` / `prebuilt_*` / `user_cards` … | 🔴 **就是上表 3 个失败的根因** |

🔑 **判据命中**：**「删数据」≠「让它不再产生」**（建表语句要一并改）——
这里是它的**第三个面**：**删了表定义，但测试断言 / 迁移列表没清**。
（前两面：① 建表语句没改 → 新库重建 ② 迁移列表没清 → 静默跳过）

**我的建议**：**不在 A1 里改**（属独立议题）→ 单独立一项「退役残留清扫」，
需要白哥批（会动测试断言 + 迁移列表）。

---

## 八、下一步

| 步 | 内容 | 阻塞 |
|---|---|---|
| **A1b** | **合规扫描（Rust 侧 + 共用词表）** | 🔴 **上线硬前提** |
| **A2** | 端侧：`external_word_cache` + 未命中分支（转圈）+ 失败重试 | 需 A1b（否则线上内容不合规） |
| **A3** | 回流脚本 | 需 A1 有真实缓存数据 |
| **部署** | 步骤 1（起服务 · **不碰 nginx**） | 需 A1b + 白哥批 |
| **主域占位页**（甲） | 并入 nginx 那批操作 | 白哥已批方案，等执行时单独报告 |
| **退役残留清扫** | 3 个测试 + 42 处迁移 + `EXPECTED_NEW_TABLES` | 需白哥批（§七） |

---

*本步**未部署、未碰生产服务器**。改动全部在本地仓库，已跑通 `cargo check` / `cargo test`（新测试 5/5）/ 端到端。*
