# 根因定位报告：卡片 IPA 大面积串位

> 2026-09-28 ｜ 触发：白哥「**先定位根因再动手**」
> **本文只调查，未改动任何数据**
> 前置报告：`card-field-contamination-2026-09-28.md`（校验器 + 196 条候选清单）

---

## 〇、三句话结论

1. 🔴 **污染位置**：`data/coevo.db` 的 `prebuilt_language_cards.pronunciation`
   —— **不是** word.db 本身的问题，`load_llm_results.py` 只是原样搬运。
2. 🔴🔴 **污染时点**：**早于仓库里所有备份**。拿 **6 个历史备份逐一对比**，全部数值**完全一致、从未变化**
   → **不是** `llm_fill` / `inline_chinese` / `vocab_cleanup` / `residual_cjk` 等任何一次操作引入的。
3. 🔴🔴 **写端不可修** —— 建库时的 V4 源目录**已删除**、源 JSON 不在仓库、现存脚本逻辑经查**均干净**。
   → **无法通过「修脚本」根治**；「防再发」只能靠**生成后闸门**（校验器已具备该能力）。

---

## 一、证据链

### 1.1 第一跳：word.db 的 ipa 从哪来？

`scripts/load_llm_results.py:845`
```python
content = {'front': wl, 'ipa': src_pron.get(wl), 'entry_type': d.get('entry_type'), ...
```

`src_pron` 的定义（同文件 266-289 行）：
```python
SRC_DB = cwc.DB                      # = data/coevo.db
for w, pron, d in con_src.execute("""
        SELECT c.front, l.pronunciation, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id=c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'"""):
    src_pron[w.lower()] = pron       # ← IPA 来自现网库，**原样搬运**
```

→ **`load_llm_results.py` 无嫌疑**：它是精确匹配 `src_pron[w.lower()]`，不是模糊查询。

### 1.2 第二跳：现网库里就已经是错的

| 词 | 现网库 `pronunciation` | 对照 |
|---|---|---|
| `a` | `/ˈhæpi/` | `happy` 也是 `/ˈhæpi/` |
| `with` | `/ɪt/` | `it` 也是 `/ɪt/` |
| `frying pan` | `/fraɪ/` | |
| `first lady` | `/fɜːst ˈpɜːsən/` | `first person` 同值 |
| `bus` | `/ˈbʌs ˌstɒp/` | `bus stop` 同值 |

→ **污染在 `coevo.db`，word.db 无辜。**

### 1.3 第三跳（决定性）：**早于所有备份**

对 `data/backups/` 里 6 个历史备份 + 现行库，逐一比对 20 个探针词的 `pronunciation`：

```
词              inline_chinese×3   llm_fill×3      residual   vocab_cleanup×2   👉 现行
bus            /ˈbʌs ˌstɒp/ ×3    /ˈbʌs ˌstɒp/ ×3  ／同上     ／同上            /ˈbʌs ˌstɒp/
a              /ˈhæpi/     ×3    /ˈhæpi/     ×3   ／同上     ／同上            /ˈhæpi/
health care    /hiːl/      ×3    /hiːl/      ×3   ／同上     ／同上            /hiːl/
…（20 个探针词全部一致，**无一处变化**）
```

🔑 **6 个备份横跨 09-25 22:20 → 22:48，污染值一字未变。**
→ **污染发生在最早备份（09-25 22:20）之前**，即**最初建库**时，与仓库里的任何脚本无关。

### 1.4 排除过的嫌疑（逐个查证，都干净）

| 脚本 | 查证结果 |
|---|---|
| `load_llm_results.py` | 精确匹配搬运，**无嫌疑** |
| `llm_fill_missing_card_content.py` | `llm_call` **无缓存**、循环内正确取 `front`、逐条真实调用 → **干净** |
| `fill_card_content_llm.py` | 只写 `definitions`，**不碰 pronunciation** |
| `migrate_v3_to_v4.py` | 逐条读源 JSON 的 `pronunciation` → 逻辑正确 |
| `migrate_missing_fields.py` | 逐条 `back.phonetic → pronunciation` → 正确 |
| `senses_supplement.json`（982 条补录） | **不含**任何一条出错词（`a`/`frying pan`/`first lady`… 全不在） |

---

## 二、污染的模式（有预测价值）

扫描 `coevo.db` 全库：**「连续 rowid 且 pronunciation 完全相同」的段 = 97 段 / 209 张**。

### 2.1 形态：**相邻条目共用同一值**

| rowid 区间 | 组 | 共用值 |
|---|---|---|
| 4783-4785 | `bus` · `bus station` · `bus stop` | `/ˈbʌs ˌstɒp/` |
| 5056-5058 | `good afternoon` · `morning` · `night` | `/ɡʊd ˈnaɪt/` |
| 5488-5490 | `swimming` · `costume` · `pool` | `/ˈswɪmɪŋ puːl/` |
| 9612-9615 | `first floor` · `lady` · `language` · `person` | `/fɜːst ˈpɜːsən/` |
| 8757-8759 | `carbon dioxide` · `footprint` · `monoxide` | `/ˈkɑːbən məˈnɒksaɪd/` |
| 8364-8365 | `air conditioning` · `air force` | `/ˈɛr fɔːrs/` |
| 9950-9951 | `ice hockey` · `ice skating` | `/ˈaɪs skeɪtɪŋ/` |

🔑 **组内「基础词 + 其核心短语」混在一起**（`bus`+`bus stop`、`class`+`classical music`）
→ 与「**按首词/前缀做 key 时取错行**」的批处理特征一致。

### 2.2 ⚠️ 被证伪的一个假说（如实记录）

我最初假设「IPA = 该词**最长前缀词**的音标」（`frying pan`←fry）。
**预测-验证实验否定了它**：
```
可比对 5,203 对 → IPA 相同仅 90 对（1.7%）
```
→ 最长前缀假说**不成立**（1.7% 属噪声级别）。**记录在此，避免后人重复走这条死路。**

### 2.3 209 张的构成（初筛，**非最终判定**）

| 类 | 段数 | 张数 | 例 |
|---|---:|---:|---|
| **互为变体拼写**（同音合理） | 57 | 115 | `apologise`/`apologize` · `chili`/`chilli` · `gram`/`gramme` · `liter`/`litre` · `mrs`/`mrs.` · `face to face`/`face-to-face` · `sports center`/`sports centre` |
| **非变体对**（含真错） | 40 | 94 | `bus`(词1 却拿 2 组音标) · `classical music`(词2 却拿 1 组) · `subsection`→`/sʌb/`(截断) |

🔴 **警告：上表只是「初筛」，不是判定结果。**
我的机械判据在「变体对」这一侧**过度宽容** —— 把 `tap`/`tape`、`doc`/`dock`、`jail`/`jails`
这类**真同音词或复数**也算成了"变体"（编辑距离 ≤2）。
→ **「合理 vs 真错」的最终判定必须交给 LLM**（正是方案 A 要做的事）。

---

## 三、🔴🔴 最重要的结论：**写端不可修**

| 想修的东西 | 状态 |
|---|---|
| 建库脚本本身 | ⚠️ 逻辑经查**干净**（见 §1.4）—— 没有可改的 bug |
| V4 源目录（`data/curriculum/v4`） | 🔴 **不存在**（`ls` 报 No such file） |
| `prebuilt_language_cards.json`（源数据） | 🔴 **仓库里没有**（`find` 0 命中） |
| 污染的真实写端 | 🔴 **不可考** —— 存在于**仓库历史之外**的一步操作 |

🔑 **因此「先定位根因再动手」的结论是：根因已定位到「位置 + 时点 + 模式」，
但它是一个已不可达的历史环节 —— 没有"脚本"可修。**

这**推翻了我上一版报告的建议**（「A 修数据 + 同时定位写端」）：
不是"并行做两件事"，而是**只剩一件事 + 一道闸门**。

---

## 四、修正后的执行方案（原方案 A 不变，防再发部分改为闸门）

| 步 | 内容 | 与原方案的区别 |
|---|---|---|
| **1** | **方案 A 照旧**：196 条走 LLM 复核 + 重生成（白哥已批） | 不变 |
| **2** | ~~定位并修生成脚本~~ | 🔴 **取消**（无可修之物，见 §三） |
| **3** | 🆕 **把校验器接为生成后闸门** | ⭐ **替代原「修写端」** —— 这是唯一能防再发的机制 |

### 4.1 闸门为什么必须现在做（而不是"以后再说"）

因为**根因不可达**，所以同类污染**可能再次从任何一次新批次进入**（无论是 LLM 生成还是导入）。
→ 闸门不是锦上添花，**它是当前唯一的防线**。

实现方式（校验器已具备）：
```bash
python3 scripts/verify_card_field_consistency.py --db <新生成的库> --json report.json
# 退出码 1 = 有可疑 → 阻止入库
```
⚠️ **配套必需**：`allowlist.json` 登记「已确认合理」的撞车对（`right`/`rite`/`write` 等真同音词），
否则闸门每次报同一批 → 被无视（狼来了效应）→ 形同虚设。

### 4.2 顺带：coevo.db 的 209 张要不要处理？

- **app 不读 coevo.db**（端侧只读 word.db）→ **不影响当前产品**
- ⚠️ 但若将来**再从 coevo.db 导入**，会把污染带回来 → 建议：**要么不动它、并标注"此库发音字段已知不洁"；
  要么与 word.db 一并修**

---

## 五、待白哥决策

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | 根因结论（位置/时点/不可修）是否认可？ | — |
| 2 | **方案 A 是否现在开工**（196 条 LLM 复核+重生成）？ | ⭐ 建议开工 |
| 3 | **闸门 + allowlist 是否一并做**？（原「定位写端」已取消） | ⭐ 建议一并 —— 这是唯一防线 |
| 4 | coevo.db 的 209 张怎么处理？ | 建议先不动 + 建库文档里标注「发音字段已知不洁」 |
| 5 | §2.3 的 94 张非变体对是否并入 A 的清单？ | ⭐ 建议并入（同因同修，一次性做完） |

---

## 六、附：本次定位的方法学（可复用）

- 🔑🔑 **「用备份库做时间切片」= 定位污染时点的最快方法**
  本次 6 个备份一比，「是否某次操作引入」当场定性 —— 比读代码快得多，且结论更硬
- 🔑🔑 **假说要用「预测-验证」跑一遍，不能只看几个样例顺眼就采信**
  我的「最长前缀」假说在 7 个样例上**全部吻合**，但全库验证只有 **1.7%** 符合 → **假说被证伪**。
  **若只看着 7 个样例，会一路错下去。**
- 🔑 **字段名不一致会让人搜不到**（本项目：coevo.db 叫 `pronunciation`，word.db 叫 `ipa`）
  → 我最初 `grep ipa` 在生成脚本里 **0 命中**，因此误以为「ipa 不在这条链路」→ **换成 `pronunciation` 才找到**
  · **判据：搜不到时，先怀疑「搜的词不对」，而不是「不存在」**（同既有判据「我没找到 ≠ 不存在」）
- 🔑 **「排除法」也要留证据**：本次逐个查了 5 个嫌疑脚本并记录「为什么干净」——
  否则下次有人会重新怀疑一遍

---

*本文为调查产出，**未改动任何数据**。*
