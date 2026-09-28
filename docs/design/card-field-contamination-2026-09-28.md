# 卡片「字段级串位」污染 —— 全库扫描结果 + 校验器交付

> 2026-09-28 ｜ 触发：白哥指示「**词在库但内容错要修 —— 这个要全库扫描，排查错误并重新修正**」
> 起点：发现 `a` 的 ipa/definition/context **三段是 `happy` 的**
> **本文只调查，未改动 `word.db`**（修正方案待批）
> 可复跑：`python3 scripts/verify_card_field_consistency.py [--list] [--json out.json]`
> 口径：对 `data/word.db`（09-28 23:02 · md5 `a0097f19…`）的**本机实测**

---

## 〇、四句话结论

1. ✅ **校验器已交付**：`scripts/verify_card_field_consistency.py` —— 可复跑、有退出码、**可作生成后闸门**。
2. 🔴 **全库命中 196 条（1.7%）**，分 5 类信号；其中 **53 条高置信**（精确率实测 100%）。
3. 🔴 **不是一个 bug，是两族**：① **整卡串位**（`a`←happy · `health care`←heal）② **仅 IPA 串位**（`first lady`←first person · `frying pan`←fry）。根因假设见 §三。
4. ✅ **这正是「不补库」救不了的那一类** —— 词在库里、直查就命中，**永远走不到 LLM**。

---

## 一、回答「你说是什么兜底」—— 没有兜底，我错了

| 位置 | 内容 |
|---|---|
| `word_query_service.dart:65` | **唯一**出现「LLM」的地方，是**文档注释** |
| `grep "external_word_cache\|llm" app/lib/{services,providers}` | **0 处实现** |
| `reader_screen.dart:312` | 实际行为：`result == null` → 弹「词库里没有「X」」→ **结束** |

🔑 **我把注释当成了实现**，还把它当作**已存在的成本项**写进「路线转向的 4 项代价」
（「划词要等」—— 实际压根没有那次调用，所以「等」也不存在）。
→ **虚构的能力会顺着推理链污染后续所有结论。** 教训已入档 `references/verification-rules.md` §〇。

> ✅ 白哥已确认定义：**兜底 = LLM 生词路径**（待新建）。

---

## 二、全库扫描结果

```
检查 11,523 张卡 → 命中 196 条（1.7%）
```

| 信号 | 判据 | 条数 | 精确率（实测） | 性质 |
|---|---|---:|---|---|
| **S1** `ipa` 残缺 | 无任何**完整** `/…/` 段 | **7** | 高 | 只剩 `/ˈ` `/` `/ˌ` |
| **S2** `ipa` 截断 | 实质字符 / 拼写字母 `< 0.45` | **18** | **100%**（18/18） | `/kæp/`←cap |
| **S3a** 短语 `ipa` 撞车 | 两个**不同短语**同 ipa | **42** | **100%** | 组内共用 |
| **S3b** 单词 `ipa` 撞车 | 与「字形不相似」的词同 ipa | **98** | 中（含真同音词） | 须逐条判 |
| **S4** `context` 不含该词 | 还原后仍找不到 | **72** | 中（不规则变形会误报） | — |

> 同一词可命中多信号（如 `health care` = S2+S3b+S4）→ 去重后 **196**。

### 2.1 S1 —— IPA 残缺（7 条，一目了然）

| 词 | ipa |
|---|---|
| `fact` | `/fækt`（缺结尾） |
| `literally` | `/ˈlɪtər` |
| `penniless` | `/ˈ` |
| `tethered` | `/ˈ` |
| `unification` | `/ˌ` |
| `india` / `simulated` | `/` |

### 2.2 S2 —— IPA 截断（18 条，**全部是真错**）

模式极清晰：**IPA 是该词「首部分对应的另一个短词」的音标**

| 词 | 现值 | 来源词 | 应为（约） |
|---|---|---|---|
| `capital letter` | `/kæp/` | cap | /ˈkæpɪtl ˈletə/ |
| `bank account` | `/bæn/` | ban | /bæŋk əˈkaʊnt/ |
| `message board` | `/mɛs/` | mess | /ˈmesɪdʒ bɔːd/ |
| `hysterical` | `/hɪs/` | hiss | /hɪˈsterɪkl/ |
| `steering wheel` | `/stɪə/` | steer | /ˈstɪərɪŋ wiːl/ |
| `frying pan` | `/fraɪ/` | fry | /ˈfraɪɪŋ pæn/ |
| `chewing gum` | `/tʃuː/` | chew | /ˈtʃuːɪŋ ɡʌm/ |
| `mixing bowl` | `/mɪks/` | mix | /ˈmɪksɪŋ bəʊl/ |
| `health care` | `/hiːl/` | heal | /helθ keə/ |
| `classical music` | `/klɑːs/` | class | /ˈklæsɪkl ˈmjuːzɪk/ |
| `bulletin` | `/bʊl/` | bull | /ˈbʊlətɪn/ |
| `rigorous` | `/rɪɡ/` | rig | /ˈrɪɡərəs/ |
| `minneapolis` | `/mɪn/` | min | /ˌmɪniˈæpəlɪs/ |
| `subsection` | `/sʌb/` | sub | /ˈsʌbsekʃn/ |
| `abortive` | `/viː/` | ? | /əˈbɔːtɪv/ |
| `eugene` / `enver` | `/ɛn/` | en | /juːˈdʒiːn/ · /ˈenvə/ |
| `white` | `/aɪ/` | i | /waɪt/ |

### 2.3 S3a —— 多词短语组内共用 IPA（42 条）★ 最整齐的一类

同一组的短语被赋了**组内某一个**的音标：

| 组 | 共有 ipa | 实际来自 |
|---|---|---|
| `air force` · `air conditioning` | `/ˈɛr fɔːrs/` | air **force** |
| `bus stop` · `bus station` | `/ˈbʌs ˌstɒp/` | bus **stop** |
| `carbon monoxide` · `dioxide` · `footprint` | `/ˈkɑːbən məˈnɒksaɪd/` | carbon **monoxide** |
| `first person` · `lady` · `floor` · `language` | `/fɜːst ˈpɜːsən/` | first **person** |
| `good night` · `morning` · `afternoon` | `/ɡʊd ˈnaɪt/` | good **night** |
| `fire station` · `fire brigade` | `/ˈfaɪə ˌsteɪʃən/` | fire **station** |
| `police station` · `police officer` | `/pəˈliːs ˌsteɪʃən/` | police **station** |
| `ice skating` · `ice hockey` | `/ˈaɪs skeɪtɪŋ/` | ice **skating** |
| `swimming pool` · `swimming costume` | `/ˈswɪmɪŋ puːl/` | swimming **pool** |
| `second person` · `secondary school` | `/ˈsɛkənd ˈpɜːrsən/` | second **person** |
| `check-in desk` · `check-in counter` | `/ˌtʃekɪn ˈdɛsk/` | check-in **desk** |
| `de facto` · `debit card` | `/diː ˈfæktoʊ/` | de **facto** |

> 🔑 **「不同短语不可能同音」→ 这类**机械上就能确认是错**（精确率 100%）。**
> ✅ 已排除「同一个词的两种写法」：`face to face`≡`face-to-face` · `disc jockey`≡`disk jockey` ·
> `sports center`≡`sports centre` —— 它们同音是**正常的**（判据：归一化后相同或编辑距离 ≤2）。

### 2.4 S3b —— 单词撞车（98 条，**须逐条判**）

🔴 **机械上无法区分这两种同 ipa**：

| 类型 | 例 | 判定 |
|---|---|---|
| **真同音词** | `right`/`rite`/`write`/`wright` · `queue`/`cue` · `gene`/`jean` · `suite`/`sweet` · `strait`/`straight` · `i`/`eye` | ✅ **合理，不动** |
| **字段错位** | `a`←`happy` · `with`←`it` · `health care`←`heel` | 🔴 **错误，要修** |

→ **必须外部知识（LLM / 词典）判定。** 这正是 §四修正方案要处理的部分。

### 2.5 S4 —— 例句不含该词（72 条，降噪后）

降噪过程（每一步都用实测驱动）：
```
429 → 修 tokenizer 大小写 bug → 修「子串误判相似」→ 修变音符（Phèdre）→ 198 → 72
```
残留误报源已认清：**不规则变形**（`outgrown`/`underwent`/`seventieth`）· 缩写（`Esq.`）· 库里词本身有误（`calenda`）。

---

## 三、根因（**假设，待查生成脚本验证**）

### 3.1 两族症状

| 族 | 表现 | 实例 |
|---|---|---|
| **A. 整卡串位** | ipa + definition + context **三段全错**，而 collocation/etymology 对 | `a`←happy · `health care`←heal |
| **B. 仅 IPA 串位** | def/ctx/col 全对，**只有 ipa 错** | `first lady`←first person · `frying pan`←fry |

🔑 **两族的共同点：错的那部分「来自另一个词」，且另一个词与该词共享首部分/前缀。**
→ 指向**生成时按前缀/首词做 key 的复用**（缓存或循环变量未更新）。

### 3.2 待验证项（修脚本时要做的）

1. `scripts/llm_full_rerun.py` / `coevo_wordlib_contract.py` 里 **ipa 是怎么取的** ——
   是 LLM 直接生成，还是从某张表按词查？（`grep ipa` 在这两个文件里**都没有命中** → 说明 ipa 可能来自
   更早的批次或另一条链路，**须先定位**）
2. 是否按「首词/前缀」分组处理（`.groupby` / cache dict）
3. `load_llm_results.py` 落库时是否会串行复用变量

⚠️ **在定位到写端之前，任何"修数据"都只是止血** —— 再生成一次可能重现
（既有判据：「**存量修复 ≠ 根治：必须同时改「写端」**」）。

---

## 四、修正方案（待白哥定）

| # | 方案 | 覆盖 | 成本 | 风险 |
|---|---|---|---|---|
| **A** ⭐ | **LLM 逐条复核 + 重生成错字段** | 196 条全量 | **低**（196 次调用 ≈ ¥2，参照 09-26 的 ¥2.21/210 条） | 低 —— 顺带产出「是否真错」的判定 |
| **B** | 只修 53 条高置信，其余手工过 | 53 条 | 中（要人工） | 🟠 S3b/S4 的 143 条**留着不修** |
| **C** | 改生成脚本后**全库重跑** | 11,523 条 | 高 | 高 —— §三 根因未定位前会重现 |

**我建议 A + 后续追加 C 的「写端修复」**：

1. **A**：用 LLM 对 196 条逐条判定「哪些字段错」+ 生成正确内容 → 回填
   - 🔑 **顺带完成第 1 条以外的价值**：这是「LLM 制卡」路径的**首次实战**（白哥的新方向），
     196 条正好是**现成的评测集**
2. **写端**：定位 §三 根因 → 修生成脚本 → **把本校验器接为生成后闸门**（见 §五）
3. **验收**：修完重跑校验器 —— **S1/S2/S3a 必须清零**；S3b 只剩「已确认的真同音词」（登记进允许列表）

### 4.1 ⚠️ 一个必须配套的设计：**允许列表（allowlist）**

`right`/`rite`/`write` 的 ipa **永远**会相同 —— 若不登记白名单，校验器每次都会报，最终被无视
（「狼来了」效应）。
→ 校验器需支持 `allowlist.json`：登记**已人工确认合理**的撞车对 + 理由 + 确认日期。
→ **未登记的命中共才报红** —— 这样它才能长期留在 CI/生成闸门里。

### 4.2 附带发现（不属本次范围，记一笔）

- **S3a 里那 6 条「变体对」暴露库里存在重复条目**：`disc jockey`/`disk jockey` ·
  `sports center`/`sports centre` · `face to face`/`face-to-face`（两条都入库）。
  英美变体都保留**是合理的**（白哥 09-26 已定「专名全部保留」的同理逻辑），
  但会让统计/聚合重复计算 → **建议单独核一次**。
- **`en` 会被 S3b 漏报**（`en` 是 `ellen` 的后缀，被「字形相似」规则放过）——
  它已在 §2.3 人工识别，ipa `/ˈɛlən/` 实为 `ellen` 的（应为 `/ɛn/`）。

---

## 五、✅ 校验器已交付

**`scripts/verify_card_field_consistency.py`**

| 能力 | 说明 |
|---|---|
| 全库扫描 | `python3 scripts/verify_card_field_consistency.py [--list]` |
| 导出清单 | `--json out.json`（供 LLM 复核） |
| **单卡校验** | `--word a` —— **生成后闸门的入口** |
| 退出码 | `0` 无命中 / `1` 有命中 → **可直接接 CI 与生成流程** |

🔑 **与 `verify_card_structure.py` 的分工**（互补，都要跑）：

| 脚本 | 管什么 | 能抓 `a` 的 `/ˈhæpi/` 吗 |
|---|---|---|
| `verify_card_structure.py` | **结构**（段类型/顺序/数量） | ❌ 结构完全合法 |
| **本脚本** | **字段内容自洽** | ✅ |

✅ **正例验证已做**（判据必须抓到否则无效）：`a` ✅ · `with` ✅ · `health care` ✅ · `first lady` ✅

> 🔬 **开发中修掉 3 个自身 bug**（都是"先验正例"才暴露的，记入判据）：
> ① `similar()` 用「互为子串」→ `'it' in 'with'` / `'a' in 'happy'` 巧合命中 → **两条真污染被放过**
> ② `levenshtein ≤ 2` 无长度约束 → `with`(4)/`it`(2) 被判相似 → 改为「距离≤2 **且** 长度差≤1」
> ③ `tokens()` 未 lower/fold → `Alsop` 被切成 `lsop`、`Phèdre` 被 `è` 切断 → **大范围误报**

---

## 六、待白哥决策

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | **修正方案取 A / B / C？** | ⭐ **A + 写端修复**（A 成本 ~¥2，且顺带评测 LLM 制卡质量） |
| 2 | **196 条是否全部走 LLM 复核**（含 S3b 的真同音词）？ | ⭐ 建议全部走 —— 真同音词的 LLM 判定结果**正好进允许列表**，一次做完 |
| 3 | **是否先定位 §三 根因（查生成脚本）再动手？** | ⭐ 建议**并行**：A 修数据止血，同时定位写端（否则会重现） |
| 4 | **允许列表机制是否现在加？** | ⭐ 建议现在加（否则校验器无法长期留在闸门里） |
| 5 | **§4.2 重复条目是否单独核？** | 建议开独立待办 |
| 6 | **`en` 这类「S3b 漏报」是否接受？** | 建议接受（已人工识别，写进报告），不为极少数扩大判据复杂度 |

---

## 七、附：本次方法学（可复用）

- 🔑 **「注释 ≠ 实现」要真的 grep 一遍** —— 我这次是被反问才查，**本该在写报告时就查**
- 🔑 **校验器的第一条测试是「正例必须被抓到」** —— 本次 3 个自身 bug **全靠这一步暴露**；
  若直接跑全库，会得到 429 条噪声并误判"判据有效"
- 🔑 **判据的降噪要「看残留的假阳性长什么样」再改** ——
  429 → 198 → 72 的每一步都是先人工看 20 条、认出误报模式（大小写/变音符/不规则变形）才动手
- 🔑 **「相似」不能用子串判定** —— 真实形态关系只发生在**首尾**（前缀/后缀），
  中间巧合命中会把真问题放过去
- 🔑 **同一信号可能「合理」与「错误」同形** —— `right`/`rite` 与 `a`/`happy` 在机械层面完全一样
  → **必须承认判据的边界，不能假装它能裁决**（这也是允许列表存在的原因）

---

*本文为调查产出，**未改动 `word.db`**。候选清单：`data/curriculum/prebuilt/card_field_candidates.json`（196 条）。*
