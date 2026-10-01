# A2 落地方案（端侧接 LLM 制卡）+ 词库外生词「能进生词本」的实现路径

> **状态**：待白哥审批（数据模型部分）
> **日期**：2026-10-01
> **上游依据**：L0 `v1-final-design-authoritative-2026-09-25.md` §九 ·
> `docs/design/llm-card-online-path-2026-09-29.md` §21（A1/A2/A3 切分与五条已定裁决）

---

## 〇、结论先行

| # | 结论 |
|---|---|
| 1 | **§21.3 的五条裁决我已复核，全部沿用，不再问**（服务端生成 · 写 `external_word_cache` · 失败=报错+重试 · 同一套契约 · **转圈**）|
| 2 | 白哥要的「词库外的词能进生词本」，**真正的堵点不是 `word_id` NOT NULL，而是「复习队列的卡片内容从哪取」** |
| 3 | 🔑 **有一个不改表结构的路径能达成同一目标**（称「路径 A：合成 id」），代价比「改表结构」**低一个数量级** |
| 4 | **建议走路径 A** —— 目标不变、风险骤降。若仍要路径 B，我另出迁移方案 |

---

## 一、复核 §21.3（白哥已裁决 · 本次沿用）

| # | 事项 | 已定 | 本次做法 |
|---|---|---|---|
| 1 | 生成放哪 | 服务端 | 沿用（A1 已完成并**已部署**到 `<VPS_IP>:8300`）|
| 2 | 写哪个表 | **`external_word_cache`** | 端侧新建该表（`user.db` v3→v4）|
| 3 | 失败路径 | **直接报错 + 稍后重试** | 按此实现（**不做** L0 的「降级卡」）|
| 4 | 一致性口径 | 同一套 prompt/契约/校验 | 服务端已如此 |
| 5 | 等待 UI | **转圈** | 按此实现 |

---

## 二、🔴 真正的堵点（实测 · 不是推断）

### 2.1 链条

```
词库外生词 → 想在生词本/复习页里被看到
   ↓
复习页取卡片走 review_session_provider.dart:189
   → WordQueryService.reviewCardOf(wordId)
       ├── cardById(wordId)   → 查 word.db 的 `word` + `card` 两张表
       └── profileOf(wordId)  → 查 word_mnemonic_profile
   ↓
词库外的词**不在 word.db** → 两张表都查不到 → 返回 null
```

⇒ 🔑 **`word_id` 可不可空只是「能不能写进 user_word」的表层问题**；
   **深层问题是「这张卡的释义/例句/词根从哪来」** —— 词库外的词在 `word.db` 里没有行。

### 2.2 顺带查到的事实（都可复验）

| 事实 | 数据 | 意义 |
|---|---|---|
| `word.db` 里「同 spelling 不同 word_id」 | **0 组**（11,523 词）| `spelling` 与 `word_id` **当前一一对应** |
| `word.id` 形态 | `w000001`（TEXT）| 可用**前缀**区分合成 id |
| `card_review_state` ↔ `user_word` 关联 | `LEFT JOIN ON uw.word_id = crs.word_id` | 只要两侧写**同一个值**，JOIN 不变 |
| `lookup_event.word_id` | **本就可空**（未命中写 NULL）| 已有先例 |
| `WordQueryService._cardBySpelling()` | **已存在** | 「按拼写取卡」的路径已有 |

---

## 三、两条路径对比

### 路径 A ⭐ **合成 id**（不改表结构）

`word_id` 写 **`ext:<spelling>`**（如 `ext:brainstorm`），并在取卡处加 fallback。

| 项 | 做法 |
|---|---|
| **写库** | `user_word.word_id = 'ext:brainstorm'` · `card_review_state.word_id` 同值 |
| **表结构** | 🔴 **完全不动** —— 不加列、不改约束、不改主键 |
| **取卡** | `cardById()` 加一层：word.db 查不到 **且** id 以 `ext:` 开头 → 读 `external_word_cache` |
| **200 上限** | 自动工作（`COUNT(*) WHERE deleted=0`，它只看行数）|
| **成就统计** | 自动工作（同上）|
| **复习队列** | 自动工作（`card_review_state` 有行就会被排进去）|
| **JOIN** | 不变（两侧同值）|
| **唯一性** | `UNIQUE(word_id)` 继续生效，且 `ext:` 前缀与 `w…` 天然隔离 |
| 迁移 | 🟢 **无需改已有表** → 只加一张新表（`onUpgrade` 现有机制已支持）|
| 回滚 | 🟢 删表 + 删 `ext:%` 行即可 |

### 路径 B 改表结构（白哥原选）

`user_word.word_id` 改可空 + `UNIQUE(word_id)` 改 `UNIQUE(spelling)` + `card_review_state.word_id` 改主键策略。

| 项 | 代价 |
|---|---|
| 🔴 SQLite 改列/改约束 | **不支持直接 ALTER** → 必须「建新表 → 搬数据 → 删旧表 → 改名」四步重建 |
| 🔴 老库升级 | 白哥真机已有 `user.db`（v1/v2/v3 都可能有）→ 每步都要**数据迁移 + 验证** |
| 🔴 连带面 | `review_list_query` 的 3 处 `LEFT JOIN uw.word_id = crs.word_id`、同步（`pending_push`）、成就统计 |
| 🔴 语义 | `word_id` 不再是「词库的 word.id」→ 列名与含义脱钩，需全局改注释与理解 |
| **收益** | 与路径 A **完全相同**（目标一致）|

### 🔑 对比小结

| | 路径 A | 路径 B |
|---|---|---|
| 达成目标 | ✅ | ✅ |
| 改已有表 | **否** | **是（重建两表）** |
| 老库迁移风险 | 🟢 低（只加表）| 🔴 高（搬数据）|
| 回滚 | 🟢 一行 SQL | 🔴 要反向重建 |
| 实施量 | 1 张新表 + 1 处 fallback | 2 表重建 + 3 处 JOIN + 同步 + 统计 |

**⇒ 路径 A 用更小的代价拿到同样的结果。**

> ⚠️ 路径 A 的**代价（如实说）**：`word_id` 字段里会出现 `ext:` 前缀的值，
> 含义不再是纯粹的「词库主键」。缓解：① 前缀自带语义、一眼可辨 ②
> `lookup_event` 本来就有「未命中留 NULL」的先例，对「非词库值」已有处理传统
> ③ 在 schema 注释与代码里明确写清两者关系。
> 🔑 而且它**天然是回流的钩子**：A3 回流后这些词会拿到真 `w…` id，届时可做一次性重映射。

---

## 四、影响面清单（路径 A）

| 文件/表 | 改动 | 说明 |
|---|---|---|
| `assets/sql/user_db_schema.sql` | 🆕 加 `external_word_cache` | 照 L0 定义，但适配现库规格（时间列用 `strftime(...'Z')`，见下）|
| `user_db.dart` | version 3 → **4** + `onUpgrade` 分支 | 现有机制已支持「重跑幂等脚本」|
| `word_query_service.dart` | `cardById` 加 fallback | 查不到且 `ext:` 前缀 → 读端侧缓存 |
| `api/generate_card_client.dart` | 🆕 | 照 `content_client` 惯例，**不带 token** |
| `services/generated_card_adapter.dart` | 🆕 **纯函数** | 契约 v6 → `WordCard`（可独立断言）|
| `reader_screen.dart` | 未命中分支改造 | 转圈 → 调接口 → 写缓存 → 展示 |
| 会话内缓存 | 🆕 | 内存 Map（L0 的 A2 清单已列）|
| **不动** | `user_word` · `card_review_state` · `review_list_query` · 同步 · 成就 | 路径 A 的收益 |

### 4.1 L0 的 DDL 需要三处适配（照既有 `bookmark` / `user_word` 的处理）

```sql
CREATE TABLE IF NOT EXISTS external_word_cache (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  spelling     TEXT UNIQUE NOT NULL COLLATE NOCASE,   -- ① 补 NOT NULL + COLLATE
  card_content TEXT NOT NULL,
  fetched_at   TEXT NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),  -- ② 现库硬约束 1
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0,1))            -- ③ 补 NOT NULL + CHECK
);
```

---

## 五、验收与回滚

### 5.1 断言（新增/扩展）
1. **纯函数断言**：`generated_card_adapter` 的契约 v6 → `WordCard` 映射（含 5 种 section）
2. **老库升级演练**：拿真机同构的 v3 库 → 跑迁移 → 断言新表存在且旧数据零丢失
3. **接线断言**：未命中分支不再只 `_hint`
4. **`ext:` 前缀一致性**：写库与取卡两侧用同一常量（防两处漂移）

### 5.2 回滚
- 删 `external_word_cache` 表 + `DELETE FROM user_word/card_review_state WHERE word_id LIKE 'ext:%'`
- 代码回滚到上一提交（表多一个不影响旧代码运行）

---

## 六、待批事项

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **改走路径 A（合成 id）？** | ⭐ **是** —— 目标相同、不动表结构、回滚简单 |
| 2 | 若仍要走路径 B | 我再出**独立迁移方案**（含四步重建 + 老库演练），不直接改 |
| 3 | `ext:` 前缀 | 建议就用 `ext:`（短、一眼可辨、与 `w` 不冲突）|
| 4 | 词库外的词是否计入 **200 上限** | 建议**计入**（它就是生词）—— 与「200 = 唯一 lemma 数」一致 |
