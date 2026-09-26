# 词库字段设计 · P1/P2 建议清单（2026-09-26）

> **触发（白哥）**：「P1-P2 这些你的建议是什么」
> **前置**：P0 三项已处置（见 `word-db-field-audit` 顶部 + `word-db-schema-frozen` §1.1/§1.2/§1.5）
> **方法**：每一项都给**实测依据 + 明确建议 + 成本 + 是否阻塞**；核实中**修正了审计时的 3 处判断**（其中 P2-12 我连错两轮，已改正）

---

## 〇、速查（按「是否阻塞」排序）

| # | 问题 | 建议 | 阻塞 | 成本 |
|---|---|---|---|---|
| **P1-8** | `card_extra` 是否计入 `content_hash` | ✅ **计入**（`hash(content + 全部 extra)`） | 🔴 **Phase 2 语音包** | 定义 |
| **P1-7** | `card_audio.section_index` 指代 | ✅ 加 `scope`（`section`/`extra`）+ 统一编号 | 🔴 **Phase 2 语音包** | 一行 DDL |
| **P1-11** | 垃圾搭配 | ✅ 过滤（**实测 563 段 = 2.1%**，原估 275 条偏少） | 搭配导入 | 小脚本 |
| **P1-9** | `etymology` 双存 | ✅ **只存 `word.etymology_text`**，卡片渲染时插入，**不占 `sections` 位** | 卡片渲染 | 删一处 |
| **P1-10** | 契约缺 `primary=root ⟹ analyzable` | ✅ 加硬约束 | 全量重跑前 | 契约 |
| **P2-14** | `cognate_group` 规模 | ✅ **全量后验证**再决定聚合页去留 | **聚合页** | 验证 |
| **P2-13** | `etymology` 生成率 91.9% | 🟠 **不必收紧**（见下，理由有变） | 成本 | — |
| **P2-12** | 解析器只支持 1 种格式 | 🔴 **两种格式并存**，错位 **14.1%（2,021 行）** | **搭配正确性** | 修脚本 |
| **P1-6** | `relation` 词级/行级 | ✅ 上移 `card.content` JSON | 无 | 结构 |
| **P1-5** | `spelling` 大小写 | 🟡 **风险降级**（词表实测 100% 小写） | 补词期 | 一行 DDL |
| **P2-15** | `cognate` 判据 | ✅ 收紧（同源 ≠ 谐音） | 质量 | 契约 |
| **P2-16** | `secondary_codes` JSON | 🟢 **可接受**（全表扫 11,917 行成本低） | 无 | — |
| **P2-17** | `aggregate_page_word.sort_seq` | ✅ 改名 `ord`（**不是冗余，是重名**） | 无 | 一行 |
| **P2-18** | 幻觉词素入库 | ✅ 规则校验拦（已有方法论） | 质量 | 脚本 |
| **P2-19** | ~~`origin` 不稳定~~ | ✅ **已推翻**（`origin` 必须进唯一键） | — | 已处置 |

---

## 一、🔴 必须现在定的（阻塞后续阶段）

### P1-8 `card_extra` 是否计入 `content_hash` → ✅ **必须计入**

**新实测（修正审计判断）**：`definitions` 义项数分布——

| 义项数 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7+ |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 词数 | 48 | 5,802 | 5,669 | 3,237 | 1,128 | 414 | 171 | 68 |

**🔴 义项 > 1 的有 10,714 / 16,564 = 65%** → **`card_extra` 不是边缘表，是主路径。**

**→ 若 `content_hash` 只算 `card.content`，则 65% 的词的 extra 变更都不会触发音频重生成** —— 这不是边角问题，是主干失效。

**✅ 建议**：
```
content_hash = SHA256(card.content + concat(该词全部 card_extra.section, 按 ord))
```
**成本**：定义一句话。**阻塞**：Phase 2 语音包（63,048 条音频）。

### P1-7 `card_audio.section_index` 指代 → ✅ **加 `scope` 列**

**问题**：「section」有两个来源（`sections[]` / `card_extra`），`section_index` 指哪组未定义。

**✅ 建议**（两选一）：
- **A**（推荐）：加 `scope TEXT CHECK(scope IN ('section','extra'))` + `section_index`
- **B**：统一编号空间 —— `extra` 的序号接在 `sections` 之后（`sections` 有 N 个，`extra` 从 N+1 开始）
  - 优点：无需新列；缺点：`sections` 数量变化会影响 extra 编号

**→ 推荐 A**（显式、稳定）。**阻塞**：Phase 2。

### P1-11 275 条垃圾搭配 → ✅ **导入前过滤**

实测：24,624 条搭配中 **275 条（1.1%）** 是占位符：
`(none common)` 43 · `(none)` 21 · `none` 18 · `(none specific)` 11 · `(rare` 5 · `(none common enough to list separately)` 3 · `(none additional)` 3 · `(no common collocations)` 2 · `(see evoke)` 2 等

**✅ 建议**：过滤规则 —— 命中以下任一则丢弃，并**输出丢弃清单人工抽检**：
- 以 `(` 开头
- 完全等于 `none` / `none common` / `rare`（忽略大小写）
- 长度 < 3 且无空格（散落碎片如 `(in) di`）

**成本**：10 行脚本。**阻塞**：搭配导入。

---

## 二、🟠 结构性建议（建议改，但可稍后）

### P1-9 `etymology` 双存 → ✅ **只存 `word.etymology_text`，且不占 `sections` 位**

**新实测（修正审计判断）**：预估 sections 数分布 ——

| sections 数 | 1 | 2 | 3 | 4 |
|---:|---:|---:|---:|---:|
| 词数 | 2 | 7 | 49 | **102** |

**→ 0% 超 4 个**（v1 容量上限）→ **容量没压力**，我审计时说「词源占 1 位是压力来源」**判断有误**。

**但双存问题依然成立**，且现在有了更好的解法：

**✅ 建议：词源只存 `word.etymology_text`，卡片渲染时插入，但不算 `sections` 数**
- **理由**：词源是**参考资料**性质，不是**记忆锚点** —— 与聚合页「不进复习队列」的同一思路
- **收益**：① 消除双存分叉 ② 词源可独立检索 ③ 不占容量位
- **代价**：卡片渲染逻辑需特殊处理（把词源渲染在 sections 之后）

> **备选**：若坚持词源是「一个记忆 section」，则删 `word.etymology_text`，只留 `sections[type=etymology]` —— **但会失去独立检索能力**。

### P1-10 契约硬约束 → ✅ **加 `primary=root ⟹ analyzable=true`**

实测违反 **6 条**（`feet`·`native`·`moderate`·`notion`·`unite`·`analyses`）—— 不可分析却选了「词根法」。

**✅ 建议**：契约加一条 —— `mnemonic.primary=root` 时 `morphology.analyzable` 必须为 `true`；否则改选 `etymology`/`context`。
**成本**：契约一行。**阻塞**：全量重跑前（否则要重跑）。

### P1-6 `relation` 落点 → ✅ **上移 `card.content` JSON**

**核实**：它的两个用途（① 决定 `word_form` 映射去留 ② 排除 `inflection` 出 `cognate_group`）**都是迁移期一次性**，**运行时不查**。

**✅ 建议**：从 `word_morpheme` 移到 `card.content.morphology_relation`（JSON 内），不建列。
- `word_morpheme` 保持纯净（只放「哪几个词素、什么顺序、什么表面形式、什么细义」）
- ⚠️ 代价：构建期「排除 inflection」需先解析 JSON —— 可行（脚本内解析）

### P1-5 `spelling` 大小写 → 🟡 **风险降级（修正审计判断）**

**新实测**：词表 **11,917 条 100% 全小写，首字母大写 0 条**。
→ 我审计时说「词表含 `Isaac`/`India`/`Sunday` 等专名，未来补词易撞」——**那些专名在词表里本来就是小写**（`isaac`/`india`/`sunday`）。

**→ 现行风险不存在**，只剩**补词期**风险。

**✅ 建议**：
- **现在不动**（加 `COLLATE NOCASE` 会引入行为差异，而当前无必要）
- 但在**构库校验**里加一条断言：`SELECT count(*) FROM word WHERE spelling != lower(spelling)` 必须为 0
- 若未来词表引入大写拼写 → 再评估

---

## 三、🔴 修正两处判断：P2-12 的真问题是**解析器不支持混合格式**

**审计时我写**：「`collocation.phrase UNIQUE` + 单 `chinese` 列 → 同短语异义会丢」
**我第一轮修正写**：「括号嵌套未处理」
**🔴 两轮都错。真相是：`related_phrases` 有**两种格式并存**，解析器只支持其中一种。**

### 真相：两种格式

| 格式 | 样例 | 特征 |
|---|---|---|
| **A**（旧） | `let it be, be that as it may, be yourself（顺其自然，尽管如此，做你自己）` | **共享一对尾部括号**，中文按序对应 |
| **B**（新） | `blue sky（蓝天）, out of the blue（出乎意料）` | **每段自带括号** |

**旧解析器**（整行切分 + 括号内按序配对）在**格式 B 上完全错位**：

| 原文 | 旧解析结果（🔴 错位） |
|---|---|
| `blue sky（蓝天）, out of the blue（出乎意料）` | EN=`blue sky` → ZH=`蓝天）, out of the blue（出乎意料` |
| `rose garden（玫瑰园）, rose-colored（玫瑰色的）` | EN=`rose garden` → ZH=`玫瑰园）, rose-colored（玫瑰色的` |
| `the same（同样的）, the more... the more...（越…越…）` | EN=`the same` → ZH=`同样的）, the more... the more...（越…越…` |

### 量化（全库实测）

| 指标 | 值 |
|---|---|
| 总行数 | **14,352** |
| 解析出总段数 | **26,871** |
| 旧解析器**错位行数** | 🔴 **2,021 行 = 14.1%** |
| 按段解析后：有配对中文 | **13,224 段 = 49.2%** |
| 纯英文（格式 A 的前几段，无配对中文） | 13,084 段 = 48.7% |
| 🔴 **垃圾/占位符段** | **563 段 = 2.1%**（比原估 275 条更多） |

**→ 错位率 14.1% 意味着：会向用户显示 2,021 条张冠李戴的搭配释义。** 这比「丢义」严重。

### ✅ 正确的解析策略（双格式）

```python
def parse_related_phrases(t):
    segs = [s.strip() for s in t.split(',') if s.strip()]     # 半角逗号切段
    # ① 逐段尝试 `phrase（zh）`
    per_seg = [(m.group(1), m.group(2)) if (m := RE.match(s)) else (s, '') for s in segs]
    # ② 判定格式
    has_zh = sum(1 for _, zh in per_seg if zh)
    if has_zh >= 2 or (has_zh == 1 and per_seg[-1][1] and not per_seg[0][1]):
        # 格式 B：每段自带括号 → 直接采用
        return per_seg
    # ③ 格式 A：仅尾部一段有括号 → 整行顺序配对
    ens = [s.strip('（）()') for s, _ in per_seg]
    zhs = split_zh(per_seg[-1][1])            # 按「，」(全角) 或「,」拆分
    return pair_in_order(ens, zhs)            # 条目数不等 → 整条丢弃并记清单
```

**配套三条**：
1. **切段只用半角 `,`** —— 中文用全角 `，`，不会误切（中文区的 `,` 需先归一化为 `，`）
2. **条目数不等时整条丢弃并记清单**（不做错位配对）
3. **560+ 条垃圾段过滤**（见 P1-11）

**✅ 建议**：
1. **修解析脚本**（双格式支持）—— **优先级最高**
2. **表结构不变**（单 `chinese` 列对当前数据够用）—— **本轮把「表设计缺陷」降级为「解析脚本缺陷」**
3. 修正后重新统计真·同短语异义（预计极少）

**⚠️ 影响面**：这是**数据正确性 bug**，会让用户看到错配的搭配释义 → **建议第一个做**。

---

## 四、🟢 可以接受 / 不必改

### P2-16 `secondary_codes` JSON 数组 → 🟢 **可接受**

**实测**：SQLite 的 JSON 数组「**可查但不可索引**」——
- `codes = 'cognate'` ❌ 不命中
- `codes LIKE '%cognate%'` ⚠️ 能命中但会误伤
- `json_each` ✅ 能查，但只能全表扫

**→ 全量 11,917 行全表扫的成本可接受**（毫秒级）→ **不必拆表**。
**建议**：在 DDL 注释里**明示「此字段只能通过 `json_each` 查询，无索引」**。

### P2-13 `etymology` 生成率 91.9% → 🟠 **建议不收紧（理由有变）**

**审计时**：我建议收紧为「仅不可拆的外来词」（v1 意图 16.8%）。

**但现在看**：① sections 0% 超限（容量不是问题）② 词源**不进 sections 位**后，成本只剩 token
→ **词源本身对记忆有帮助**，且不挤占容量 → **不必为了符合 v1 的数字而砍掉它**。

**⚠️ 但有一个前提**：若采纳 P1-9（词源独立于 sections），则 91.9% 可接受；
若词源仍占 section 位，则需收紧。

### P2-17 `aggregate_page_word.sort_seq` → ✅ **改名 `ord`（不是冗余）**

**核实**：两者**语义不同** ——
- `aggregate_page_word.sort_seq` = **页内展示顺序**（每页从 1 开始）
- `word.sort_seq` = **全局唯一序号**（音频命名，只增不改）

**→ 不是冗余，是「重名」** → 建议改 `ord` 避免误解（`card_extra` 已用 `ord`，保持一致）。

---

## 五、⏳ 必须等全量跑完才能定的

### P2-14 `cognate_group` 规模 → ✅ **全量后验证，再决定聚合页去留**

**抽样数据（有偏差）**：107 个可拆词 → 109 个不同词根，仅 **3 个共享**、**≥3 词共享的族 = 0**

**⚠️ 抽样天然低估**（跨 CEFR 随机 → `receive`/`perceive` 极难同时抽中）→ **不能据此下结论**。

**✅ 验证 SQL（全量后立即跑）**：
```sql
-- 族规模分布
SELECT size, count(*) FROM (
  SELECT group_id, count(*) AS size FROM cognate_group_member GROUP BY group_id
) GROUP BY size ORDER BY size;

-- 决策线
SELECT count(*) FROM (
  SELECT group_id FROM cognate_group_member GROUP BY group_id HAVING count(*) >= 3
);
```

**决策规则**：
- ≥3 词的族占比 **≥ 10%** → 聚合页**值得做**
- **< 10%** → 🔴 **聚合页（v1 §4.3）实际不可用** → 需重新评估（可能退化为「词根提示」而非独立页）

### P2-18 幻觉词素 → ✅ **用规则校验拦（已有方法论）**

抽样第 1 轮幻觉：`st`(`stable`) · `-e`(`resolute`/`retrieve`/`resemble`) · `a-`(`awoke`) · `e-`(`eroded`)

**✅ 建议**（§2.1 已确立「规则做校验」合法）：入库前断言 ——
- 词素 `form` 去连字符后**长度 ≤ 1** 的 `prefix`/`suffix` → 标记可疑（白名单：`-s`/`-y`/`-a`）
- ⚠️ **但要在全量跑完后**用白名单+人工抽检确认，避免误杀真后缀

### P2-15 `cognate` 判据 → ✅ **收紧**

实测：`primary=cognate` 的 5 条中，`papa` 的理由是「与中文『爸爸』发音相似」= **谐音联想，不是同源**。

**✅ 建议**：`mnemonic_type.applicable_when` 明确写：
- `cognate` = 「**与另一个英语词共享同一词根/词源**」（如 `receive`/`perceive`）
- 谐音相似 → 归 `image`

---

## 六、建议的执行顺序

| 序 | 事项 | 何时做 | 为什么这个顺序 |
|---|---|---|---|
| **1** | **P2-12** 修搭配解析脚本 | **现在** | 🔴 数据正确性 bug，会显示**张冠李戴的释义**；且影响 24,624 条 |
| **2** | **P1-11** 过滤 275 条垃圾搭配 | 与 1 同批 | 同属搭配清洗 |
| **3** | **P1-8 / P1-7** 定义 `content_hash` 与 `section_index` | **Phase 2 前** | 63,048 条音频依赖 |
| **4** | **P1-9 / P1-6 / P1-10** 结构微调 + 契约约束 | **全量重跑前** | 否则要重跑 |
| **5** | **P2-15 / P2-18** 判据与校验 | 全量重跑前 | 契约与入库断言 |
| **6** | **P2-14** 验证 `cognate_group` 规模 | **全量跑完后** | **决定聚合页去留** |
| **7** | P1-5 / P2-16 / P2-17 | 随手 | 不阻塞 |

---

## 七、待白哥拍板（10 项）

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | `content_hash` 覆盖 `card_extra` | ✅ 计入 |
| 2 | `card_audio` 加 `scope` 列 | ✅ 加（方案 A） |
| 3 | 过滤垃圾搭配（**563 段**） | ✅ 过滤 + 出清单 |
| 4 | `etymology` 只存 `word` 表且不占 section 位 | ✅ 采纳（否则删 `word` 那列） |
| 5 | 契约加 `primary=root ⟹ analyzable` | ✅ 加 |
| 6 | `relation` 上移 `card.content` JSON | ✅ 上移 |
| 7 | **修搭配解析脚本**（支持双格式，P2-12 真问题） | ✅ **优先级最高 —— 影响 2,021 行释义正确性** |
| 8 | `etymology` 生成率不收紧 | 🟠 建议不收紧（前提是第 4 项采纳） |
| 9 | `cognate` 判据收紧（同源 ≠ 谐音） | ✅ 收紧 |
| 10 | `aggregate_page_word.sort_seq` 改 `ord` | ✅ 改名 |

---

## 附：本次核实修正的 3 处审计判断

| # | 审计时的判断 | 核实后修正 |
|---|---|---|
| 1 | P1-9「词源占 1 位是容量压力来源」 | ❌ **错** —— sections 实测 **0% 超 4 个**，容量无压力 |
| 2 | P1-5「词表含 `Isaac`/`India` 等专名，易撞」 | ❌ **不准确** —— 词表 **100% 全小写**（那些专名在词表里就是 `isaac`/`india`）→ 风险降级为补词期 |
| 3 | P2-12「同短语异义会丢」（表设计缺陷） | 🔴 **两轮都判断不准** → 真因是**两种格式并存而解析器只支持一种**；错位 **2,021 行（14.1%）**，会给用户显示错配释义 |

*本文档为审计产出，未修改任何代码或生产环境。*
